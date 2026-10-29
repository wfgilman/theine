# 05 — Eviction policy: W-TinyLFU

One topic: `Theine.Policy`, Window TinyLFU as Caffeine implements it: a
small admission window (LRU), a main region split into probation and
protected (segmented LRU), and the frequency sketch (specs/02) as the
admission filter between them. Runs only inside the maintenance process.

## Regions and sizes

Given `max_size` (total weight):

- `window_max = max(1, trunc(max_size * 0.01))`
- `main_max = max_size - window_max`
- `protected_max = trunc(main_max * 0.80)`
- probation has no fixed cap; it is what remains of main.

These are Caffeine's defaults (1% window, 80/20 main split). The window
percentage is a `start_link` option `window_percent` (default 1), so the
hit-rate bench can sweep it, and it is the starting size for the adaptive
window (§Adaptive window), which is on by default and moves it from there.

## State (private ETS, owned by maintenance)

```
policy  :set          {key, id, segment, seq, weight, expires_at}
order   :ordered_set  {{segment, seq}, key}
ids     :set          {id, key}
```

- `segment` ∈ `:window | :probation | :protected`.
- `seq` is from a monotonically increasing integer in the maintenance state,
  starting at 1. Larger `seq` means more recently used. The LRU end of a
  segment is `:ets.next(order, {segment, 0})` when the returned key's
  segment matches (`{segment, 0}` sorts before every `{segment, positive}`).
  The MRU end is `:ets.prev(order, {segment, @max_seq})` with
  `@max_seq = 1 <<< 62`; `seq` must never reach it (it would take centuries
  at a billion writes per second, but assert it in a test anyway). Atoms
  sort after integers in Erlang term order, so `:infinity` would not work as
  an upper sentinel; that is why the integer sentinel exists.
- `window_weight`, `probation_weight`, `protected_weight` are integers in
  the maintenance state.

Moving an entry to a segment's MRU is one `:ets.delete` and one
`:ets.insert` on `order` plus an `update_element` on `policy`. O(log n),
off the hot path. This replaces Caffeine's intrusive doubly-linked lists; it
is the main structural concession to the BEAM.

## Events

### `on_write(key, id, weight, expires_at)`

- If `key` is unknown: insert into `policy` and `ids`, place at window MRU,
  `window_weight += weight`, `Sketch.increment(key)`.
- If `key` is known with an older id: update `ids` (delete old id, insert
  new), update the `policy` row's id, weight and expires_at, adjust the
  segment weight by the delta, move to MRU of its current segment,
  `Sketch.increment(key)`. Caffeine treats an update as an access.
- If `key` is known with the **same** id (an `expire/3` or `persist/2`
  update, or a queued event replayed after a restart rebuild): update
  `expires_at` and weight only. No sketch increment, no MRU move. Changing
  an entry's expiry is not an access.
- In both known-key cases, a protected key that grew heavier must still
  fit: if its new weight exceeds `protected_max` it moves to probation MRU
  (as `on_access` would refuse to promote it), else protected LRU entries
  are demoted to probation MRU until `protected_weight <= protected_max`
  (§Decisions M2.6).
- Admission of oversized entries never happens here; `put/4` rejected them
  (specs/01).

### `on_remove(key, id)`

If `ids` maps `id` to `key` and `policy` holds that id: delete from all three
tables and subtract the weight. Otherwise the removal is stale (for a
version already replaced): if the entries table still holds `key`, ignore
it, since a newer version's `:put` is in flight or already applied; if the
table lacks `key`, drop the key's rows anyway, because the row's id can be
one the table never kept (§Decisions 2026-10-27 M1.5).

### `on_access(id)`

Look up `ids`; if `id` is not the key's current id in `policy`, skip. Else
`Sketch.increment(key)` and:

- `:window` → move to window MRU.
- `:probation` → move to protected MRU; `probation_weight -= w`,
  `protected_weight += w`; if `protected_weight > protected_max`, demote
  protected LRU entries to probation MRU until it fits. An entry with
  `w > protected_max` moves to probation MRU instead (§Decisions M2.5).
- `:protected` → move to protected MRU.

### `restore(key, id, weight, expires_at)`

The maintenance restart rebuild (specs/04 §Restart semantics step 3) feeds
every entry it finds in the entries table through this instead of
`on_write`: insert into `policy` and `ids` under the table's id, place at
the **probation** MRU, `probation_weight += weight`, and no
`Sketch.increment`, so the rebuilt policy is cold and every restored entry
is a candidate for direct eviction (`candidates` is 0) until reads promote
it. A key the policy already holds is left alone. Without a bound it is a
plain row, as `on_write` of an unknown key would make (§Decisions M2.9).

### `evict()`

Called after every applied `:put` event and once in every maintenance pass
(specs/04 §The pass; §Decisions M2.11c); step 1 always runs, step 2 while
`window_weight + probation_weight + protected_weight > max_size`, at most
`evict_batch` removals per call (§Decisions M2.6):

1. While `window_weight > window_max`: take the window LRU entry, move it
   to probation MRU (`window_weight -= w`, `probation_weight += w`) and
   increment `candidates`, the count of window overflows in this pass.
   (Caffeine's `evictFromWindow` returns exactly this count.)
2. While total weight > `max_size`, mirroring Caffeine's `evictFromMain`:
   - `victim` = probation LRU. If probation is empty: evict the protected
     LRU; if that is empty too, evict the window LRU (degenerate tiny
     caches). Continue the loop.
   - If `candidates == 0`: evict `victim` directly, with no admission test.
     Every remaining probation entry already passed admission once, and
     there is no fresh candidate to compare it against. Continue the loop.
   - `candidate` = the **cursor**, which starts at probation MRU (the most
     recent window overflow, since step 1 appended them at the MRU end and
     nothing else has touched probation since) and walks toward the LRU end
     with `:ets.prev(order, {:probation, cursor_seq})`, one step per
     decision. Each window overflow is therefore tested exactly once, as in
     Caffeine, where the candidate pointer advances after both outcomes.
   - If `candidate == victim` (probation holds one entry): evict it,
     `candidates -= 1`. Continue the loop.
   - **Admit** if `freq(candidate) > freq(victim)`; else if
     `freq(candidate) >= 6` and `:rand.uniform(128) == 1`, admit (Caffeine's
     hash-DoS guard: a flood of fresh keys can still occasionally displace a
     victim); else reject.
   - Admit → remove `victim` from the entries table and policy; the
     candidate stays in probation. Reject → remove `candidate` from the
     entries table and policy. In both cases `candidates -= 1` and the
     cursor steps to the previous probation entry (computed before any
     deletion).
   - Removal from the entries table follows specs/04 §Removing an entry.

   `candidates` and the cursor are cleared whenever a call returns `:done`.
   A call that stops at `evict_batch` while candidates remain returns
   `:more` and carries both into the follow-up pass that specs/04
   schedules, so that leftover window overflows are still admission-tested
   rather than treated as settled.

   `:rand` is seeded once in the maintenance process's `init/1` from
   `:erlang.phash2(cache_name)` (via `:rand.seed(:exsss, {h, h, h})`), so a
   trace replayed through `mix bench hitrate` with synchronous maintenance
   produces identical results run to run.

Frequencies come from `Sketch.frequency/2` at the moment of comparison.

## Adaptive window

Caffeine's hill climber: every `10 * max_size` reads, compare the hit rate
of the sample with the previous sample; if it improved, keep moving the
window size in the same direction, else reverse; step size starts at 6.25%
of `max_size` and decays by 0.98 per step; restart with the full step when
the hit-rate delta exceeds 5 percentage points. Resizing moves entries
between window and probation at their LRU ends.

On by default: `adaptive: true` (specs/08). `adaptive: false` keeps the
window fixed at `window_percent` and must reproduce every fixed-window test
result unchanged; the hit-rate bench runs both (specs/09).

The climber runs in the maintenance pass (specs/04 step 7) and never on the
hit path. Its sample is counted inside the maintenance process: a hit is an
access drained from the read buffer, and a miss is a `:put` event for a key
the policy does not hold (in a cache, an insert of a new key follows a
miss). It therefore works with `stats: false` and never reads the stats
counters. The read buffer drops accesses under load, so the sample
under-counts hits when the cache is busiest; that biases the absolute rate
but not the direction of a change between consecutive samples, which is all
the climber compares. A sample is `10 * max_size` requests (hits plus
misses as counted here).

## Acceptance

- Invariant (property test over random put/access/remove sequences,
  checked after every operation): every key in `policy` has exactly one row
  in `order` and one in `ids`; segment weights equal the sums over `policy`;
  `protected_weight <= protected_max` after every event; no `order` row has
  a key absent from `policy`.
- Bounded: after `evict/0` returns `:done`, total weight ≤ `max_size`.
- Admission: with a victim of frequency 3 and a candidate of frequency 5, the
  victim is evicted; with 5 vs 3 the candidate is; with 2 vs 2 the candidate
  is (ties reject, below the guard threshold).
- Scan resistance (the reason for all this): with `max_size = 1000`, access a
  working set of 800 keys 10 times each, then stream 100,000 distinct keys
  once each; at least 90% of the working set is still present. Plain LRU
  retains 0%.
- Stale access: `on_access(old_id)` after the key was rewritten has no effect.
- Hit-rate bench (specs/09): ≥ LRU on all traces, ≥ +10 points on the
  looping/scan traces.
- Oversized weights never reach the policy (specs/01 test), so
  `window_weight` never exceeds `max_size` from a single entry.

## Decisions

- 2026-10-27 (M1.5): a stale `on_remove` consults the entries table. `put/4`
  allocates the id before the insert and sends the event after it, so two
  writers racing on one key can insert in one order and send in the other:
  the table keeps the lower id while the policy applies the higher id's
  `:put` last, or the reverse. The row's id then matches nothing in the
  table. In a bounded cache the eviction re-lookup (specs/04 §Removing an
  entry) drops such a row eventually; in an unbounded cache nothing did,
  so `size/1` drifted by one per race and `delete/2` could never clear the
  row (its `{:removed, key, id}` carries the table's id, which the policy
  called stale). The fix is one `:ets.member/2` on the entries table in the
  stale branch only: key absent means the removal was for the last version
  the table held, so the row goes; key present means a third version's
  `:put` is in flight or applied, so the row stays and that event corrects
  the id. Off the hot path, and `clear/1`'s synchronous `reset/1` heals the
  same way.
- 2026-10-27 (M1.2): the policy state is a `%Theine.Policy{}` struct (the
  two or three tables, the `sizes` atomics, `max_size`, the next `seq`) that
  the maintenance process threads through every call, so the functions
  above take it first: `on_write(state, key, id, weight, expires_at)`,
  `on_remove(state, key, id)`, `on_access(state, id)`, `evict(state)`. No
  process dictionary. In unbounded mode (`max_size: :infinity`, specs/08)
  only `policy` and `ids` exist and `segment` is `nil`; `seq` is still
  assigned so the row shape is the same in both modes. `size` and
  `weighted_size` are published to a two-field `sizes` atomics as each event
  is applied, which is what `Theine.size/1` and `weighted_size/1` read.
- 2026-10-28 (M2.4): the bounded struct carries `order`, the sketch, the
  region limits (`window_max`, `protected_max`), the three segment weights
  and `sketch_size`, the number of `Sketch.increment/2` calls since the
  last completed reset. specs/04 §Responsibilities puts the sketch's size
  with the maintenance process; the policy struct is that process's state
  and the only place that increments, so the count lives there and the
  reset cursor (M2.7) stays in the maintenance state. The limits use
  integer arithmetic, `max(1, div(max_size * window_percent, 100))` and
  `div(main_max * 80, 100)`, which equal the `trunc` forms above for every
  integer input without a float on the way. `Policy.new/1` clears the
  sketch it is handed, so a maintenance restart starts cold (specs/04
  §Restart semantics step 2) and `reset/1` clears it for `clear/1`. The
  `seq` sentinel is enforced in the policy: the write that would be given
  `max_seq()` raises before touching any table, which crashes the
  maintenance process into a rebuild rather than corrupting the order
  table; `lru/2` and `mru/2` expose the segment ends for the later tasks
  and the tests. An overwrite in a non-window segment stays in that segment
  (the "current segment" rule above) and moves to its MRU.
- 2026-10-28 (M2.5): `on_access` of a probation entry heavier than
  `protected_max` reorders it to the probation MRU instead of promoting it.
  Promoting it would demote every other protected entry and then the entry
  itself (alone, it is the LRU and still over the limit), emptying the
  protected segment for nothing; Caffeine's `reorderProbation` has the same
  guard. With it, the accessed key always ends at the MRU of the segment
  the rule names, and demotion never touches it, since once the others are
  gone its weight alone fits. Demotion is immediate, inside `on_access`, as
  the rule says; Caffeine defers it to the end of the pass, which makes no
  observable difference with a fixed window. The task that adds the
adaptive window (§Adaptive window) checks whether it still makes none once
the window moves, and records the answer in §Decisions. Unbounded
  policies return the state unchanged (no order, no sketch, no read buffer
  to drain), and an access whose fresh `seq` would be the sentinel raises
  as a write does.
- 2026-10-28 (M2.6): `Policy.evict(state)` returns `{:done | :more,
  evicted, state}`, with `evicted` the number of entries removed from the
  entries table in this call, so that the pass (specs/04 step 8) reports it
  without reading the counter back. Step 1 runs on every call, not only
  when the cache is over `max_size`: Caffeine's `evictFromWindow` runs on
  every maintenance, and an under-capacity cache whose window never
  overflowed would hold everything in the window until it filled, so that
  no read could promote anything to protected before the first eviction;
  the pass therefore calls `evict/1` unconditionally (it costs two
  comparisons when there is nothing to do). The removal count that
  `evict_batch` caps includes the rows dropped on a stale re-lookup; the
  returned `evicted` and the `evictions` counter count table deletions
  only. The re-lookup drops the policy rows of a key the table holds under
  another id or not at all, without touching the table: the `:put` or
  `:removed` event already in flight re-adds or settles the key, and
  keeping the row would leave the victim at the LRU forever. The
  carried-over cursor is the `seq` of the next candidate, resolved on use
  to the probation entry at that `seq` or the nearest below it, since
  events applied between passes may have moved or removed it; a follow-up
  pass whose step 1 appended new overflows restarts the cursor at the
  probation MRU (they are the freshest candidates, and the paragraph
  above's "starts at probation MRU" stays true whenever step 1 moved
  anything). The walk stops at the `seq` of the batch's first overflow
  (kept as `candidate_floor` while a batch is open): a probation entry
  below it was there before the batch and has been tested, so reaching
  one, or the LRU end, sets `candidates` to 0. Without the floor a count
  left over after a carried candidate was promoted or removed between
  passes would retest, and on a tie evict, the probation MRU. A window
  overflow heavier than `protected_max` is not special here; it is tested
  like any candidate. The `:rand` seed is `{h, h, h}` with
  `h = :erlang.phash2(name)`, exposed as `Theine.Maintenance.rand_seed/1`
  and applied in `init/1`. The policy struct carries `evict_batch` and the
  stats counters (for `evictions`) from the config, and `candidates`,
  `cursor` and `candidate_floor` between calls; `reset/1` clears them.
  The eviction property (random puts, accesses, removals and evictions
  with `evict_batch` 2 against `max_size` 20) also found that `on_write`
  of a protected key with a larger weight left `protected_weight` above
  `protected_max`, since only `on_access` demoted: a rewrite of a 7-weight
  protected key to 9 at `protected_max` 15 with another protected key
  present. Caffeine keeps the segment within its limit with
  `demoteFromMainProtected` at the end of every maintenance; here, where
  demotion is immediate (M2.5), `on_write` now applies the `on_access`
  rule after a weight increase, so the §Acceptance invariant holds after
  every event, not only after `on_access`.
- 2026-10-29 (M2.9): `Policy.restore(state, key, id, weight, expires_at)`
  is the rebuild's entry point (§Events `restore`), separate from
  `on_write` because the two differ in every bounded branch: probation
  instead of the window, no sketch count, and a known key skipped rather
  than updated. The skip is an `:ets.insert_new/2` on the `policy` table,
  so a key restored twice costs one failed insert and changes nothing;
  the maintenance process scans a fixed table (specs/04 §Decisions M2.9)
  and handles no event between chunks, so it never happens there. The
  events that arrive after the rebuild settle the rows as §Events say: the
  entry's own `:put`, replayed from a writer that straddled the restart,
  is a same-id update (no move, no count); a newer version's `:put` moves
  the key to the probation MRU; a `:removed` with the table's id drops it.
  A rebuilt probation may exceed `main_max`, which `evict` handles like
  any over-capacity state: with `candidates` 0 the probation LRU goes
  first, oldest in scan order.
- 2026-10-29 (M2.11c): `evict/1` runs after every applied `:put`, not only
  in the pass. The A5 bound of specs/00 needs a `:put` to count as
  consumed only once the cache fits again (specs/03 §Decisions M2.11c), so
  the maintenance process calls `on_write/5` then `evict/1` and only then
  decrements `pending`; the pass's own call (step 5) stays and finds work
  only after a restart rebuild or a `:more`. Nothing in this section's
  algorithm changes: step 1 moves the overflow the new entry caused (one
  entry, or several for a heavy one), step 2 admits or rejects it against
  the probation LRU at once, and `candidates`, the cursor and the floor
  are per call, cleared on `:done`, which is now the usual outcome of
  every call. What changes is *when* an entry is tested relative to the
  reads around it: before, a batch of up to `write_batch` writes was
  applied, the pass drained the reads recorded in between, and then the
  batch's overflows were tested together, so a read of a just-inserted
  key counted in its favour; now each insert is tested before the next
  event and the reads of the batch land afterwards. With one access per
  pass (Caffeine's simulator order, `mix bench hitrate --accesses-per-pass
  1`) the two are identical, and the full `mix bench hitrate` run after
  the change (IMPLEMENTATION_PLAN.md §Benchmark log M2.11c) is the record
  of what the default 32-access batches lose or gain.
- 2026-10-29 (after M2.10, human decision): the adaptive window moved from M6
  into M2 and is on by default (`adaptive: true`), so that `theine ≥ lru`
  holds on recency-driven traces such as OLTP (specs/00 §Decisions). Its
  sample is counted from drained accesses and new-key `:put` events inside
  the maintenance process (§Adaptive window), so it adds nothing to the hit
  path and works with `stats: false`.

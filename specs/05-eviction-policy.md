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
hit-rate bench can sweep it; adaptive sizing (§Adaptive) is M6.

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
  protected LRU entries to probation MRU until it fits.
- `:protected` → move to protected MRU.

### `evict()`

Called in the maintenance pass while `window_weight + probation_weight +
protected_weight > max_size`, at most `evict_batch` removals per pass:

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

   `candidates` and the cursor are reset at the start of every pass. An
   eviction that stops at `evict_batch` while candidates remain carries both
   into the follow-up pass that specs/04 schedules, so that leftover window
   overflows are still admission-tested rather than treated as settled.

   `:rand` is seeded once in the maintenance process's `init/1` from
   `:erlang.phash2(cache_name)` (via `:rand.seed(:exsss, {h, h, h})`), so a
   trace replayed through `mix bench hitrate` with synchronous maintenance
   produces identical results run to run.

Frequencies come from `Sketch.frequency/2` at the moment of comparison.

## Adaptive window (M6, optional)

Caffeine's hill climber: every `10 * max_size` reads, compare the hit rate
of the sample with the previous sample; if it improved, keep moving the
window size in the same direction, else reverse; step size starts at 6.25%
of `max_size` and decays by 0.98 per step; restart with the full step when
the hit-rate delta exceeds 5 percentage points. Resizing moves entries
between window and probation at their LRU ends. Behind `adaptive: true`,
default false, and must not change any non-adaptive test result.

## Acceptance

- Invariant (property test over random put/access/remove sequences,
  checked after every operation): every key in `policy` has exactly one row
  in `order` and one in `ids`; segment weights equal the sums over `policy`;
  `protected_weight <= protected_max` after `on_access`; no `order` row has
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

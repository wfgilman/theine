# 11 — Expire-after-access (design note, draft)

Status: a draft for v2. Nothing in `lib/` implements it, and no other spec
depends on it. Expire-after-access is a v1 non-goal (specs/00 §Non-goals).
This note says how it could be built inside the rules of specs/01, 03 and
06, what it would cost the hit path, and which decisions a human has to make
before a build task can start.

## What is asked

`expire_after_access: ms | :infinity` on `start_link`, default `:infinity`,
is Caffeine's `expireAfterAccess`. An entry expires once `ms` have passed
since its last **access**. A hit is an access: `get/2`, `get/3`, and the hit
branches of `fetch/4`, `fetch_async/4` and `fetch_all/4`. A write is one too:
`put/4`, `put_new/4` and a loader's `:commit`. These are not accesses: a
miss, `ttl/2`, `expire/3`, `persist/2`, `size/1`, and `put_new/4` finding the
key present. The option works alongside expire-after-write (specs/06
§Semantics), and an entry expires at whichever deadline comes first.

The invariant of specs/06 §Semantics holds unchanged. An expired entry is
never returned by any read, and that guarantee must not depend on the
maintenance process being alive or caught up. So the reader has to be able
to tell, from what it can see, that an entry has been idle for `ms`.

## Constraints from the other specs

- **Reads never write to ETS** (specs/00 §Why pure BEAM, goal 2; specs/01
  §Expired read). Caffeine stamps the node's access time on every read
  (`setAccessTime` in its read path). The equivalent here, rewriting
  element 5 or 6 of the entry tuple on a hit, is forbidden. The last access
  time has to live somewhere other than the entries table.
- **The hit budget** (specs/00 goal 1, specs/01 §Read path Budget, specs/03
  §`record/2` Budget) allows at most one `persistent_term` read, one ETS
  lookup, one clock read, one scheduler-id read and three `:atomics` ops.
  Today the bounded hit uses two ops (add_get, put), and three on every
  `drain_threshold`-th read of a stripe (plus a compare_exchange).
- **The read buffer is lossy by design** (specs/03 §Read buffer). A stripe
  keeps its newest `slots` reads, and under load the drain is deferred
  (specs/04 §The pass, `drain_backoff`). The policy is meant to see a
  sample of accesses.
- **The expiry index** (specs/06 §Index) is an ordered_set
  `{{expires_at, key}, id}` owned by the maintenance process. The sweep
  re-reads the entries table for each due row and follows the table when
  the two disagree (specs/06 §Decisions M3.1).

## Option A: the read buffer carries access time

This is the route specs/00 originally named. The ring would tell the policy
when each id was read. The policy would keep `accessed_at` on the policy row
(specs/05 §State), move the key's index row to
`min(write deadline, accessed_at + ms)` on every drained read, and rewrite
the entry's element 6 to that deadline so that the reader's existing check
(specs/01 §Read path step 3) enforces it.

The time can travel two ways:

- **Implicitly, as the drain time.** An id drained at time `T` was read
  after its stripe's previous drain, so `T` over-estimates the access time
  by at most the gap between two drains of that stripe. That gap is at most
  `maintenance_interval` (1000 ms) on a stripe with fewer than
  `drain_threshold` reads since its last trigger. The ring does not change.
- **Explicitly, packed into the slot word.** A coarse timestamp goes in the
  high bits and the id in the low bits. This buys accuracy only on quiet
  stripes, where the drain-time error is largest. It also narrows ids below
  the 64 bits of specs/00 §Glossary. At 16 bits of time, 2^48 ids last
  about 19 years at 469_000 writes/s, the best rate one cache sustained
  (README §Benchmarks), but the narrowing would still need a decision.

Hit-path cost: no new `:atomics` op either way. Every entry in an
access-expiring cache would hold an integer element 6, so every hit reads
the clock (about 30 ns, specs/01 §Decisions M1.2), which the budget already
allows. Packing adds a shift and an `or`, about 2 ns.

**Why not.** First, dropped reads become early expiries. Under
four saturating readers, M2.8c's probe drained 33_796 reads/s out of
6_544_614 (IMPLEMENTATION_PLAN.md §Benchmark log M2.8c), so about 0.5%
of reads. With one saturating reader it is about 3% (64 reads a stripe
about once a millisecond). Treat each read as surviving independently
with probability `p`. A key read `k` times in one `ms` window is then
expired by mistake with probability `(1 - p)^k`. At 0.5% that is 59% for
`k = 100` and 0.6% for `k = 1000`. So under load, a moderately warm key
would be expired while in use, and the next reader would pay a miss and a
reload. That is the
wrong direction for an error: expire-after-access exists to keep the keys
in use. The ring's drops were made safe for a frequency sample (specs/03
§Read buffer), and a deadline is not a sample.

Second, the maintenance process would start writing to the entries table.
It deletes from it today but never rewrites a live entry. A rewrite of
element 6 races `put/4`, and a compare-and-swap on the id needs
`:ets.select_replace/2` with the key bound in the match head. A key that
holds `:_`, a `:"$1"`-style atom or a map does not bind the head, and the
call becomes a scan of the whole table (specs/07 §Decisions M4.4b met this
in the far smaller `refreshing` table). An `update_element/3` followed by a
check opens a window in which a new version takes the old version's
deadline.

Third, every drained read of such an entry would add an ordered_set delete
and insert, plus an entries-table update, to an `on_access` that already
costs 1.8–2.1 µs (specs/04 §Decisions M2.11b). This has not been measured.
Rewriting only when the deadline moves by more than some granularity would
cut it.

## Option B (recommended): an access word beside the read buffer

The read buffer keeps carrying ids only, for the policy's frequency and
recency (specs/03 unchanged; specs/05 `on_access` unchanged). The access
time goes into a second `:atomics` array that every hit writes. This is the
closest equivalent of Caffeine's per-node access time that does not write
to ETS.

**Layout.** `access` is one signed `:atomics` array per cache, because
monotonic milliseconds can be negative. It has `words` entries, a power of
two of at least `2 * max_size`. The entry with id `id` owns the word
`Bitwise.band(id, words - 1) + 1`. No slot is allocated and nothing is
added to the entry tuple (specs/01 §Entry layout unchanged). `Theine.Owner`
allocates the array, as it does the read buffer, and only when the option
is set. So the array survives a Maintenance restart (specs/08 §Supervision
tree), and an Owner restart starts it over along with the table. An
unbounded cache needs its size from an option (open question 4).

**Writers.** `put/4`, `put_new/4` and a loader's commit
`:atomics.put(access, word, written_at)` after the id allocation and
*before* the insert (specs/01 §Write path between steps 2 and 4). A reader
that finds the new tuple then finds a word no older than its write.
Putting the word after the insert would let a reader see the new tuple
beside a stale word and expire a fresh entry. That costs one `:atomics` op
on the write path, which has no op budget. The put burst check of specs/09
measured 5.6–7.4× an insert against its 10× limit (README §Benchmarks), so
there is room for it.

**The hit.** The hit is specs/01 §Read path with one step between 3 and 5.
After the write-deadline check passes,
`last = :atomics.exchange(access, word, now)`. If `now - last >= ms`, the
entry is idle. The reader takes specs/01 §Expired read unchanged (delete
by exact object, `{:removed, key, id}`, `misses` and `expirations`) and
records nothing. Otherwise the hit continues to `record/2` as today.
`exchange` both reads and stamps the word in one op. A `get` followed by a
`put` would be two.

**Reads that are not accesses.** `ttl/2` (which reports the nearer
deadline), `put_new/4`'s present-key check and `expire/3` read the word
with `:atomics.get/2` and never stamp it.

**The sweep.** In an access-expiring cache every entry is indexed, at
`min(write deadline, last access seen + ms)`, where the last access seen is
the word when the row is written. Drained reads never move the index. This
is the saving over Option A: index churn is once per `ms` per live entry,
not once per sampled read. When a row comes due, the sweep re-reads the
table as specs/06 §Decisions M3.1 says, then reads the word. If the write
deadline is still ahead and `last + ms > now`, the entry was read after it
was indexed. The row moves to `min(write deadline, last + ms)` and the entry
stays. A moved row counts against `expire_batch`, so the pass stays
bounded. Otherwise the entry is removed as in M3.1, with
`expirations` counted and the `[:theine, :eviction]` cause `:expired`
(specs/08 §Decisions M6.2). Caffeine's `expireAfterAccessEntries` walks its
access-order queues and stops at the first entry that has not expired. A
row that moves instead of stopping the walk is the ordered-index version of
the same idea. (The Caffeine details here are from knowledge of its source.
The loop has no network, so they have not been checked against it.)

**Restart.** `Policy.restore/5` (specs/05 §Events `restore`) indexes a
restored entry at `min(write deadline, word + ms)`. The word is still
there, because Owner holds it.

**Collisions.** Two live entries whose ids are equal modulo `words` share a
word, so the reads and writes of one refresh the other. That error is
always late, never early. A word moves backwards only when a slow reader's
`exchange` overwrites a newer `now` with its own, and then only by that
reader's delay. With `words >= 2 * max_size` most live entries own their
word. An idle entry that shares a word with a hot one lives until its write
deadline or its eviction. In a bounded cache eviction removes it in the
end. In an unbounded cache nothing does, so its array has to be sized for
the entry count.

### Cost on the hit path

| | bounded hit today | Option B, common hit | Option B, trigger hit |
|---|---|---|---|
| `:atomics` ops | 2 | 3 (add_get, put, exchange) | 4 (+ compare_exchange) |
| clock reads | 0, or 1 with a write deadline | 1 | 1 |
| `persistent_term` reads | 1 | 1 | 1 |
| other | — | one `band`, one config clause | same |

An unbounded access-expiring hit is the counters op plus the exchange.

Each `:atomics` op costs 18–25 ns with one reader, and about 65 ns when the
SMT sibling is busy on the reference laptop (AGENTS.md). The clock costs
about 30 ns (specs/01 §Decisions M1.2) and is new only for an entry with no
write deadline. A `band` is about 1 ns. As `get/2` is written today
(`lib/theine.ex`), the clock read in the write-deadline check is not kept.
The refresh clause already reads the clock a second time for the same
reason (specs/07 §Decisions M4.4). Binding `now` once in an
access-expiring cache keeps the path to one read. The estimate is 20–55 ns
over today's bounded hit with one reader, and 65–95 ns at four readers on
the laptop. It has not been measured. That laptop's bounded hit already
sits at the A1 edge (IMPLEMENTATION_PLAN.md open question 4), so an
access-expiring cache would not meet A1 there.

The trigger hit's four ops break specs/00 goal 1 and specs/01 §Budget as
written. The break is limited to caches started with the option. Every
other cache keeps today's hit, because the option selects its own `hit`
shape in the config (specs/08 §Decisions M2.8). That shape must be one no
existing clause of `get/2` matches, placed ahead of the catch-all counters
clause, as the refresh wrapper's 3-tuple is (specs/07 §Decisions M4.4). This
is open question 1.

## What a build would change

- specs/00: goal 1 and §Non-goals, after open question 1 is answered.
- specs/01: the new hit step, the writer's word stamp before the insert,
  and `put_new/4`'s expired branch, which checks the word as well as
  element 6.
- specs/06: the §Semantics bullets for the option and for `ttl/2` (the
  nearer deadline), §Index (every entry indexed, and the sweep's move
  outcome next to the three of M3.1), and §Acceptance.
- specs/05: `restore` reads the word. The policy row keeps the write
  deadline in `expires_at`, as today, and the index row carries the
  effective deadline.
- specs/08: the option row, its `hit` shape, how it combines with
  `refresh_after_write` (both wrap the inner hit), the array-size option
  for unbounded caches, and the docs.
- specs/09 and 10: a bench subject with the option, and the tracing
  multisets for the access-expiring hit, trigger hit and idle read.
- specs/03 and 04 are unchanged. The ring, the drain and the pass order
  stay as they are. The sweep's extra outcome lives inside step 4.

## Acceptance (for the build task, not for this note)

- With `expire_after_access: 10` and an injected clock: written at 0 and
  read at 5, the entry is readable at 14 and `:error` at 15. This holds
  with maintenance paused and no pass run.
- With maintenance paused and the read buffer flooded so that it drops
  almost every read, a key read once per millisecond for 100 ms never
  expires. This is the test Option A fails.
- With maintenance running and no reads, an idle entry leaves the table
  within one `maintenance_interval` of its deadline. An entry read after
  it was indexed has its row moved, not removed.
- Forced collisions (a 2-word array): no entry is ever reported idle
  earlier than its own last access allows.
- `ttl/2`, `expire/3` and `put_new/4` on a present key do not extend the
  idle deadline.
- tracing_test pins the three multisets of the table above. A cache
  without the option keeps today's multisets exactly.

## Open questions (for a human)

1. **Four `:atomics` ops on a trigger hit in an access-expiring cache.**
   specs/00 goal 1 says three, "nothing else, ever". **Recommended:** allow
   one more op (the access word's `exchange`) in caches started with the
   option, and keep the three-op budget for every other cache. The
   alternative that fits the budget is Option A, which expires keys in use
   under load.
2. **A1/A2 for an access-expiring cache.** **Recommended:** report it as a
   `mix bench get` subject without thresholds, as `theine_nostats` is
   (specs/09). A1/A2 stay defined on the default cache.
3. **Per-entry idle times** (Caffeine's `Expiry.expireAfterRead`) are out
   of scope. A cache-wide `ms` is what lets `word + ms` decide
   expiry without reading anything per entry beyond the word.
4. **The array size for an unbounded cache.** **Recommended:** a
   `start_link` option, a power of two like the read-buffer sizes (specs/03
   §Layout), required when `max_size` is `:infinity` and the option is set.

## Decisions

- 2026-11-03 (M6.4): this note drafted. It recommends Option B, an access
  word beside the read buffer. specs/00 had planned the feature "via the
  read buffer". The ring's drops, sampled at about 0.5% of reads under
  four saturating readers (M2.8c), would turn a lost read into an early
  expiry of a key in use. A frequency sample tolerates that. A deadline
  does not. The read buffer keeps carrying ids for the policy. No code
  changed.

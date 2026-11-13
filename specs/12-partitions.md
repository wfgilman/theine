# 12 — Partitioned maintenance (design, settled for v2)

Status: settled for v2 on 2026-11-12 (§Settled questions), not yet
planned. Nothing in `lib/` implements it, and no other spec depends on it.
It is the follow-on to milestone M7: M7 lowers the cost of a write event
inside one maintenance process, and this note lets one cache run several
of them. It says how a cache splits its policy across `partitions`
maintenance processes while readers keep one entries table, and what that
costs. Build tasks start after M7 is checked, because M7.1's per-event
measurement is the throughput baseline here.

## Why

One maintenance process applies every write event of a cache (specs/03
§Write events, specs/04). Its cost per event sets the cache's sustained
write ceiling. On the development machine (IMPLEMENTATION_PLAN.md §M7,
2026-11-12 profile) an overwrite costs that process about 4.2 µs and a new
key that evicts about 10.5 µs, which is about 240_000 and 95_000 writes/s.
More writers do not raise the ceiling: four writers sustained less than one
(README §Benchmarks). M7 can take perhaps 15–25% off the cost per event.
Nothing inside one process can multiply it. Splitting the policy can.

Users can shard by hand today: start `n` caches and pick one with
`:erlang.phash2(key, n)` on every call. A built-in split adds three things
that hand sharding cannot:

- One name, one configuration, one `size/1` and one `stats/1`.
- One entries table, so single-flight loading, `clear/1` and the loader
  tables span every key.
- No hashing on the read path. Hand sharding hashes the key on every `get`.
  The design below routes a hit by its id, which the reader already holds.

Guava's `CacheBuilder`, Caffeine's predecessor, worked this way: its
`concurrencyLevel` segments each kept their own LRU over
`maximumSize / segments`. Caffeine dropped segments because the JVM gave it
cheap shared writes through its lock-free write buffer. A BEAM process
cannot share its policy, so the trade comes out the other way here. (The
Guava and Caffeine details are from knowledge of their sources. The loop
has no network, so they have not been checked against them.)

## What is asked

`partitions: n` on `start_link`, a power of two from 1 to 64, default 1.

- **`n = 1` is today's cache, exactly.** Same hit path, same `put/4`, same
  supervision tree, same ids, same telemetry, same bench results. Every
  test and bench row that exists before the build holds unchanged after it.
  The tracing multisets of specs/10 are unchanged for `n = 1`.
- **`n > 1`** runs `n` maintenance processes. Each owns the keys that hash
  to it and runs specs/04's pass and specs/05's W-TinyLFU over its own
  share of `max_size`.

## Constraints from the other specs

- **The hit budget** (specs/00 goal 1, specs/01 §Read path Budget, specs/03
  §`record/2` Budget): at most one `persistent_term` read, one ETS lookup,
  one clock read, one scheduler-id read and three `:atomics` ops. A
  partitioned hit may add integer arithmetic. It may not add a BIF call, a
  hash or an `:atomics` op.
- **Reads never write to ETS** (specs/00 goal 2). Unchanged.
- **A key's versions are ordered by id.** The policy compares ids of one
  key (`id < row_id`, `id <= restored_id`, specs/05 §Decisions M3.2 and
  M2.12), and removers delete by exact object (specs/04 §Removing an
  entry). Ids only have to be ordered *within a key*, and every version of
  a key lives in one partition, so ordering within a partition is enough.
- **Write events are never lost** (specs/03), and the A5 bound holds by
  construction from `pending` (specs/03 §Delivery with backpressure).
- **The maintenance process owns its private tables** (specs/05 §State).
  The id-to-key table in particular cannot be shared between processes.

## Design

```
                       ┌──────────── entries table (one public ETS set, shared) ────────────┐
   get ───lookup──────►│  {key, value, id, weight, written_at, expires_at}                  │
     │                 └────────────────────────────────────────────────────────────────────┘
     │ record id in the rings of partition (id &&& (n-1))     ▲ insert / delete_object
     ▼                                                        │
  ┌─ rings of P0 ───┐ ┌─ rings of P1 ───┐ ...          put ───┤  p = top bits of phash2(key)
  └───────┬─────────┘ └───────┬─────────┘                     │  event to maintenance p
          ▼                   ▼                               ▼
  ┌─ maintenance P0 ─┐ ┌─ maintenance P1 ─┐ ...  ◄── write events, own `pending` and backpressure
  │ policy, ids,      │ │ policy, ids,      │
  │ order, expiry     │ │ order, expiry     │   each: W-TinyLFU over its share of max_size,
  │ sketch, climber   │ │ sketch, climber   │         own window, climber and expiry sweep
  └───────────────────┘ └───────────────────┘
```

### The partition of a key

`h = :erlang.phash2(key, 4_294_967_296)` and `p = h >>> (32 - log2(n))`:
the top `log2(n)` bits of the same 32-bit hash the sketch starts from
(specs/02 §Hashing). Every version of a key, from `put/4`, `put_new/4` or
a loader's commit, goes to partition `p`.

Taking the top bits keeps the partition independent enough of the sketch's
block index. Within a partition those bits are constant, and `spread/1` is
a bijection on 32 bits that mixes the remaining `32 - log2(n)` bits across
the whole word, so blocks should still fill evenly. That is an argument,
not a measurement. The acceptance below tests it.

Only the writers that allocate an id hash the key. Every later step finds
the partition in the id.

### Ids carry the partition

Today every write takes `id = :atomics.add_get(ids, 1, 1)` from one
counter per cache (specs/01 §Write path). With `n > 1`, `ids` has `n`
counters and partition `p`'s ids are

```
id = :atomics.add_get(ids, p + 1, 1) * n + p      # so id &&& (n - 1) == p
```

At `n = 1` this is today's id. Ids are increasing within a partition, which
is the only order the specs rely on (§Constraints). With `n ≤ 64` the
counters reach 2^53 before an id reaches the 2^59 small-integer limit
(specs/00 §Glossary). Splitting the counter also removes the one `:atomics`
word that every writer of a cache contends on today.

So `delete/2`, `expire/3`, `persist/2` and the expired read (specs/01
§Expired read) find the partition of their event as `id &&& (n - 1)`. They
already read the id, so they do no hashing. A restart rebuild selects its
partition's entries the same way (§Restart).

### The read buffer is split by partition

The read buffer (specs/03 §Layout) holds `n` groups of `stripes` stripes.
A hit records into the stripe of its scheduler *within its id's
partition*:

```
base = ((id &&& pmask) * stripes + (scheduler_id - 1 &&& stripe_mask)) * width + 1
```

That is one `band`, one multiply and one add over today's base, all on
integers the reader already holds: no BIF, no hash, no `:atomics` op. Each
partition drains only its own stripes, so ids never travel between
processes, and each id-to-key table stays private.

To keep `n = 1` exact, a partitioned cache gets its own `hit` shape in the
config (specs/08 §Decisions M2.8), handled in the local `record` function
or a sibling of it, and an unpartitioned cache keeps today's 5-tuple and
clause. specs/07 §Decisions M4.4 measured about 10 ns on the unbounded hit
from a bigger `get/2` body. The new clause must be placed so that the
`n = 1` bounded and unbounded hits are unchanged in `mix bench get`.

The drain flag (specs/03 `schedule_drain/1`) becomes one flag per
partition, and a trigger sends `:drain` to that partition's process. Hits
are still the sum of every stripe tail (specs/03 §Hits from the tails).

Memory: `n` times today's rings, which is `n * stripes * (2 + slots)`
words. At `n = 8` with 4 stripes and 64 slots that is 2_112 words, about
17 KB.

### Each partition is a whole policy

Partition `p` gets the capacity share
`div(max_size, n) + (if p < rem(max_size, n), do: 1, else: 0)`, so the
shares add up to `max_size`. Within its share it runs everything specs/04,
05 and 06 describe, unchanged: window, probation and protected segments,
its own sketch sized for its share (specs/02 §Layout, so the total sketch
memory is about today's), its own hill climber, its own expiry index and
sweep, and its own `pending` counter with backpressure at `write_hwm`.

An entry heavier than its partition's share is never stored, as an entry
heavier than `max_size` is never stored today (specs/08 `put/4`). With
`n > 1` that limit is lower, and the docs must say so.

### A5 with partitions

Each partition keeps specs/03's invariant: the entries it holds beyond its
share are counted by its `pending` or in flight between insert and
`add_get`. Summed over the partitions, the table holds at most

```
max_size + n * write_hwm + writers
```

entries' weight. At `n = 1` this is today's bound. The alternative, giving
each partition `div(write_hwm, n)`, keeps today's bound but lowers the
burst each partition absorbs before its writers block. That is open
question 2, settled for per-partition `write_hwm`.

### Supervision

`n = 1` keeps specs/08's tree. With `n > 1`, the last child is a
`one_for_one` supervisor of the `n` maintenance processes:

```
Theine.Supervisor (rest_for_one)
├── Theine.Owner          also allocates n id counters, n pending counters, n drain flags,
│                         n groups of read-buffer stripes, n sketches, 2n size fields
├── Task.Supervisor
└── Theine.Partitions     one_for_one
    ├── Theine.Maintenance partition 0   registered under today's name
    ├── Theine.Maintenance partition 1   registered under a per-partition name
    └── ...
```

An Owner crash still restarts everything after it. A crash in partition
`p` restarts only partition `p`. Under a flat `rest_for_one` a crash in
partition 1 would also restart partitions 2 and up, which is why they need
their own supervisor. Config holds the `n` registered names, so a restart
still needs no `persistent_term` write (specs/08 §Supervision tree).

### Restart

A restarted partition runs specs/04 §Restart semantics on its own share:

- It moves the heads of its own stripes to their tails, and zeroes its own
  `pending` and drain flag.
- It clears its own sketch.
- It rebuilds from the entries table with a match spec that keeps rows
  whose id satisfies `{'==', {'band', '$3', pmask}, p}`. That is still one
  chunked scan of the whole table per restart, but it restores only
  partition `p`'s entries.

The other partitions do not notice.

### Calls that span partitions

| call | with `n > 1` |
|---|---|
| `size/1`, `weighted_size/1` | the sum of the `n` partitions' fields in the `sizes` atomics (`2n` fields; each partition publishes its own, specs/05 §Decisions M1.2) |
| `stats/1` | unchanged: `:counters` are shared and commutative, and `hits` sums every stripe tail |
| `clear/1` | `:ets.delete_all_objects/1`, then the synchronous `reset/1` of each partition in turn (specs/01, 04). Discovered issue 3 applies per partition, as today |
| `run_maintenance/1` | one full pass of each partition in order, returning after the last |
| `Maintenance.info/1` | partition 0's info, so existing tests read the same thing. `info/2` takes a partition |
| telemetry | `[:theine, :maintenance, :pass]` and `:rebuild` gain `partition: p` in their metadata, for `n = 1` too (an added key, not a changed one). `[:theine, :eviction]` is unchanged |
| loading | unchanged: claims, waiters and refreshes are per key in shared tables (specs/07), and a commit is a `put` |

## Costs

| | `n = 1` | `n > 1` |
|---|---|---|
| `get/2` hit | unchanged | one `band`, one multiply, one add (estimate under 3 ns, not measured) |
| `put/4`, `put_new/4`, a commit | unchanged | `phash2/2` and a shift, about 20 ns (measured 2026-11-12), and the id arithmetic |
| `delete/2`, `expire/3`, expired read | unchanged | one `band` on the id |
| processes | 1 maintenance | `n` maintenance and one supervisor |
| memory | unchanged | `n` × the rings and policy-table overhead; sketches about the same in total |
| sustained writes | one process's ceiling | up to `n` × that, limited by cores (below) |

**Throughput is a guess until measured.** Writers and maintenance
processes share the schedulers. On the 4-scheduler development machine,
four writers and four partitions compete for four cores, so 2–3× one
partition is a more honest expectation than 4×. Writes concentrated on a
few hot keys also concentrate on their partitions: partitioning raises the
ceiling for writes spread over many keys, not for one hot key.

**Hit rate may drop a little.** Admission compares a candidate only with a
victim in its own partition, and each hill climber samples a `1/n` share
of the accesses. Over a share of many thousand entries that should be
statistically close to one global policy. Small shares are where it breaks
down. At `max_size: 1_000` with `n = 8`, each partition has 125 entries and
a window of one or two, and the climber's samples are noisy. That is why
there is a minimum share (settled question 1). Uneven weights can also leave
one partition evicting while another has room: the hash spreads keys
evenly, not weight.

## What a build would change

- specs/00: goal 1 is unchanged. Add the option, and give A5's slack as
  `n * write_hwm`.
- specs/01: §Write path (hash and the per-partition id for `n > 1`), §Read
  path (the partitioned `hit` shape), §Expired read (the event's
  partition comes from the id).
- specs/02: one sketch per partition, sized for its share.
- specs/03: §Layout (`n` groups of stripes), `schedule_drain/1` (a flag
  per partition), §Delivery with backpressure (`pending` per partition and
  the A5 slack).
- specs/04: the pass and restart run per partition, the rebuild's
  partition filter, and the `partition` telemetry metadata.
- specs/05: capacity shares. Nothing inside the policy changes.
- specs/08: the option row, the `n > 1` tree, the calls table above, and
  the documented limit on entry weight.
- specs/09: the new bench subjects and thresholds below.
- specs/10: tracing multisets for the partitioned hit, the partitioned
  put and the partitioned delete.

## Acceptance (for the build tasks, not for this note)

- **`n = 1` is unchanged.** The whole test suite passes untouched, and
  `mix bench hitrate` reproduces every row to the exact hit. `mix bench
  get`'s `n = 1` rows are within run-to-run noise of the M7 final gate.
- **Routing.** For random keys and every `n` in {2, 4, 8}, every entry's
  `id &&& (n - 1)` equals the top bits of its key's hash, and every
  version of one key has ids that increase.
- **Sketch independence.** At `n = 8`, inserting 100_000 random keys into
  one partition's sketch fills its blocks evenly (a chi-square test at the
  1% level), as the same keys do in an unpartitioned sketch.
- **Bound.** `mix bench maintenance`'s overshoot run with `partitions: 4`
  never samples more than `max_size + 4 * write_hwm + schedulers`, and is
  back at `max_size` within one `maintenance_interval` of the writers
  stopping.
- **Isolation.** Killing partition 1 under load restarts partition 1 only.
  The other partitions' pids, pass counts and policy rows are unchanged,
  and specs/04 §Acceptance Restart holds for partition 1's keys.
- **Hit rate.** A `theine_p4` subject in `mix bench hitrate` (`partitions:
  4`) on every row whose share is at least the minimum: DS1, S3, P3 and
  zipf 100_000. It is within 1 point of `theine` on each of those rows
  (settled question 3). The bench drives every partition through
  `run_maintenance/1`, and each partition's `:rand` is seeded from the
  cache name and `p`, so the rows stay deterministic.
- **Throughput.** M7.1's per-event scenario, run with `partitions` in
  {1, 2, 4} and one writer per scheduler, reports writes/s for each. On
  the reference machine `partitions: 4` reaches at least 2 × `partitions:
  1` (settled question 4); on the development machine it is reported
  only.
- **Hot path.** `mix bench get` gains a `theine_p4` subject. Its hit is
  measured as `theine`'s is, and its p50 is at most 1.10 × `theine`'s on
  every shape (settled question 5). tracing_test pins the partitioned
  hit's multiset, which is the same as `theine`'s.

## Build order

1. Ids and routing with `n = 1` exact: per-partition id counters, the
   partition function and the id-derived partition of every event, all
   unused while `n = 1`. Gate: everything unchanged.
2. Per-partition read rings and drain flags, the partitioned `hit` shape,
   and the `partitions` option accepted for unbounded caches only, which
   have no read buffer. Gate: `mix bench get` `n = 1` unchanged.
3. `n` maintenance processes under `Theine.Partitions`, with shares,
   `pending` and backpressure per partition, and restart by partition.
   Bounded caches accepted, with the minimum share. Gate: the A5 and
   isolation tests.
4. The calls that span partitions (`size`, `clear`, `run_maintenance`,
   `info/2`, telemetry metadata).
5. Bench subjects: `theine_p4` in `hitrate` and `get`, and the throughput
   scenario. README and docs, including the entry-weight limit.

## Settled questions

Settled 2026-11-12. The owner delegated these to the assistant that
drafted the note, and each answer is the recommendation the draft made,
except where noted.

1. **The minimum share.** With `n > 1` and a finite `max_size`,
   `start_link` raises `ArgumentError` when `div(max_size, n) < 10_000`. A
   window of 1% is then at least 100 entries. Unbounded caches have no
   minimum, since they have no policy to dilute, and they still gain the
   write ceiling. The build does not move the figure. If `theine_p4`
   misses the hit-rate margin on a qualifying row, that is a discovered
   issue for a human.
2. **The A5 slack.** `write_hwm` applies per partition, and the bound is
   `max_size + n * write_hwm + writers`. Each partition then behaves as
   today's cache does, and the burst check of specs/09 keeps its meaning.
   At `n = 64` the extra slack is 64 × 1_024 = 65_536 entries, about 10%
   of the 640_000-entry minimum cache that `n = 64` requires under
   question 1. At `n = 1` the bound is today's. This restates the A5
   threshold for `n > 1` only, as a human decision (specs/09 says never to
   relax a threshold in the loop).
3. **The hit-rate margin.** `theine_p4` is within 1 point of `theine` on
   every qualifying row, the same tolerance A3 gives the Caffeine
   cross-check.
4. **Throughput.** Reported on the development machine. On the reference
   machine (specs/09 §Reference machine) `partitions: 4` must reach at
   least 2 × `partitions: 1` with one writer per scheduler, judged by a
   person as A1/A2 are. That holds the feature to its purpose without
   gating a 2-core laptop on a four-process speedup.
5. **The partitioned hit and A1/A2.** A1/A2 stay defined on the default
   cache (`n = 1`). `theine_p4`'s p50 is at most **1.10×** `theine`'s on
   every shape. The draft proposed 1.05×. The development machine's
   ratios move by several percent from run to run (three runs put the
   bounded p99 at 1.5–2.0× `ets`, README §Benchmarks, and discovered
   issue 4 is the same noise). The p50 spread between two subjects has not
   been measured, and 1.05× leaves too little room for it. An added hash or BIF is caught by the tracing multiset, not by
   this limit, so the limit only needs to catch gross growth.
6. **The default.** `partitions: 1`, opt-in. Choosing a default from
   `schedulers_online` and `max_size` can come later, after the reference
   machine has measured both hit rate and throughput.

## Decisions

- 2026-11-12: this note drafted, after the M7 profile showed that no
  single cost dominates a write event and that tuning one process can
  gain perhaps 15–25%. The design keeps one entries table and moves the
  partition into the id, so a hit routes its read without hashing the key
  and an unpartitioned cache keeps today's paths exactly. No code changed.
- 2026-11-12: the six open questions settled (§Settled questions). The
  owner delegated them. Five take the draft's recommendation; the limit on
  the partitioned hit is 1.10× `theine`'s p50, not 1.05×, to leave room
  for the development machine's run-to-run noise. The tracing multiset,
  not the bench, guards against an added hash or BIF.

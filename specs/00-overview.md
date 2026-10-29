# 00 — Overview, goals, acceptance criteria, milestones

## What theine is

A bounded, in-process key/value cache for the BEAM, written in Elixir with no
native code, that reproduces the architecture of Java's Caffeine:

- an unordered, concurrent entry store (ETS here, ConcurrentHashMap there);
- a W-TinyLFU admission and eviction policy driven by a count-min frequency
  sketch, so the hit rate is near-optimal on the standard traces;
- lossy, striped read buffers so a cache hit never takes a lock, never writes
  to the store, and never contends on a shared cache line;
- a single maintenance process that drains the buffers and applies policy,
  expiration and eviction in amortized O(1) batches, off the request path;
- a loading layer with single-flight coalescing, asynchronous loads, and
  refresh-after-write (stale-while-revalidate) for values sourced from a
  slower L2 such as Redis, Postgres or a remote service.

## Why pure BEAM, and what "faster than ETS" means here

Every shared-memory store the VM offers has a disqualifying gap for a cache:
`persistent_term` reads copy nothing but every write triggers a global GC;
`:atomics` hold only 64-bit integers; NIF resources copy terms out exactly as
ETS does. Any Elixir cache therefore sits on ETS, and cannot beat the thing it
is built on for a raw lookup. Caffeine itself runs at about a third of
ConcurrentHashMap's read throughput and calls that a win.

So the performance goal is stated relative to raw ETS and to the existing
Elixir caches, not as "beats ETS":

1. A hit on `Theine.get/2` costs one ETS lookup plus a bounded constant: at
   most one `persistent_term` read, one monotonic clock read, one scheduler-id
   read, and three `:atomics` operations. Nothing else, ever.
2. Reads never write to ETS. The entry store sees writes only from `put`,
   `delete`, expiry cleanup and eviction.
3. The policy (frequency sketch, access order, expiry index) is owned by one
   process and lives in `:atomics` and private ETS, so it costs no GC in the
   caller and no locks.

## Acceptance criteria (the project is done when all hold)

These are measured by `mix bench get`, `mix bench hitrate`,
`mix bench maintenance` and `mix test --include stress`, as specified in
specs/09-benchmarks.md and specs/10-testing.md. Thresholds live there; this
list is the contract.

- **A1 Latency.** `Theine.get/2` hit latency, p50 and p99, is within 1.5× of a
  raw `:ets.lookup/2` on a table with identical options, identical key and
  value shapes, at 1 scheduler and at all schedulers.
- **A2 Throughput.** Aggregate `get` hit throughput at all schedulers is at
  least 0.65× raw ETS, and at least 2× both Cachex and Nebulex local `get` on
  the same harness.
- **A3 Hit rate.** On every trace in the hit-rate suite, theine's hit rate
  with its default policy (W-TinyLFU with the adaptive window) is at least
  that of the reference LRU, and on the looping trace it is at least 10
  percentage points above LRU. On no row is the adaptive window more than 1
  percentage point below the fixed 1% window. When the Caffeine simulator is
  run on the same trace with the same maximum size, theine is within 1
  percentage point of the matching Caffeine policy (human-verified gate, see
  specs/09).
- **A4 Single-flight.** For any key, concurrent `fetch` callers invoke the
  loader exactly once per miss, and every waiter receives the loaded value or
  the loader's error. Refresh-after-write never blocks a reader.
- **A5 Bounded.** Under a sustained 100% write workload at any scheduler
  count, the entry count never exceeds `max_size` plus the write-buffer slack
  defined in specs/03, and returns to at most `max_size` within one
  maintenance interval of the writes stopping.
- **A6 No native code.** `mix.exs` has no NIF, port or `make` dependency, and
  the release contains no `.so`.

## Non-goals for v1

- Expire-after-access (needs the policy's view of access time on the read
  path; planned for v2 via the read buffer).
- Removal/eviction listeners and bulk `fetch_all`. These are M6 optional
  tasks, after the gate above is green.
- Distribution, replication, persistence, or an L2 adapter library. The
  loader is a function; what it calls is the user's business.
- Weak/soft references, cache-wide locks, transactions.

## Mapping to Caffeine (for anyone who knows it)

| Caffeine | theine |
|---|---|
| `Cache.getIfPresent` | `Theine.get/2` |
| `Cache.get(key, mappingFn)` | `Theine.fetch/3` |
| `LoadingCache.get` with `CacheLoader` | `Theine.fetch/2` with the cache-level `:loader` |
| `AsyncLoadingCache.get` returning a future | `Theine.fetch_async/3` returning a `Task` |
| `LoadingCache.refresh` | `Theine.refresh/2` |
| `refreshAfterWrite` | `:refresh_after_write` |
| `expireAfterWrite` | `:expire_after_write` and per-entry `ttl:` |
| `maximumSize` / `maximumWeight` + `Weigher` | `:max_size` + `:weigher` |
| `Cache.put`, `invalidate`, `invalidateAll` | `put/4`, `delete/2`, `clear/1` |
| `estimatedSize`, `stats` | `size/1`, `stats/1` |
| `FrequencySketch` | `Theine.Sketch` (specs/02) |
| `StripedBuffer` / `BoundedBuffer` read buffer | `Theine.ReadBuffer` (specs/03) |
| write buffer (MPSC queue) | write events to the maintenance process (specs/03) |
| `BoundedLocalCache.maintenance` | `Theine.Maintenance` (specs/04) |
| window + probation + protected LRUs | `Theine.Policy` (specs/05) |
| `TimerWheel` | `Theine.Expiry` ordered index (specs/06) |

## Glossary

- **entry**: a tuple in the public entries table (specs/01).
- **id**: a 64-bit integer assigned to each *write* of a key; identifies that
  version of the entry in the read buffer and the policy. Never 0.
- **stripe**: one of N independent read-buffer rings, picked by scheduler id.
- **drain**: one pass of the maintenance process over the buffers.
- **window / probation / protected**: the three LRU segments of W-TinyLFU.
- **candidate / victim**: the window's LRU entry and the probation's LRU
  entry at eviction time; the sketch decides which survives.
- **claimant / waiter**: in a coalesced load, the process running the loader
  and the processes waiting for its result.

## Milestones (the planner orders tasks by these)

- **M0 Scaffold.** `mix new theine --sup`; pin toolchain; CI gate commands in
  `mix.exs` aliases; `bench/get.exs` with the raw-ETS baseline only; trace
  downloader for `bench/traces/`. Done when `mix test` and `mix bench get`
  run green on an empty library.
- **M1 Store and API without a bound.** specs/01 and specs/08 minus policy:
  `start_link`, `get`, `put`, `put_new`, `delete`, `clear`, `size`, per-entry
  TTL with lazy expiry on read, stats counters. Done when A1 and A2 hold with
  policy disabled (the bound is `:infinity`).
- **M2 Policy.** specs/02, 03, 04, 05: sketch, read buffer, write events,
  maintenance process, W-TinyLFU with the adaptive window (on by default).
  Done when A3 (LRU comparison part) and A5 hold, and A1/A2 still hold with
  policy enabled.
- **M3 Expiration.** specs/06: expiry index and sweep, `expire_after_write`
  default, `expire`/`persist`. Done when the expiry tests and
  `mix bench maintenance` pass.
- **M4 Loading.** specs/07: `fetch`, `fetch_async`, `refresh`,
  `refresh_after_write`. Done when A4 holds under the stress suite.
- **M5 Gate.** specs/09 and specs/10 in full: Cachex and Nebulex comparison,
  Caffeine simulator cross-check instructions, docs, `mix hex.build` clean.
- **M6 Optional.** Eviction listener, `fetch_all`, expire-after-access
  design note. Only after M5 is green.

## Decisions

- 2026-10-27: pure BEAM only. A Rust NIF backend for zero-copy binary values
  was considered and deferred; it is not part of this spec set.
- 2026-10-27: write events reach the maintenance process by message send
  with call-based backpressure, not by a second public ETS table. One copy of
  the key per write; see specs/03.
- 2026-10-27: every write gets a fresh id rather than reusing the key's
  current id, so `put` needs no prior lookup. Stale ids in the read buffer are
  dropped at drain time.
- 2026-10-27: the first planning pass raised 15 questions; all were resolved
  in the specs the same day rather than left to build iterations. The
  substantive ones: read-buffer `record/2` is add_get, get, put (three
  atomics ops, specs/03); sketch reset uses Caffeine's
  `(size - (odd >>> 2)) >>> 1` (specs/02); eviction walks a candidate cursor
  from probation MRU toward LRU with a window-overflow count and evicts
  victims outright once candidates run out (specs/05); `delete/2` always
  looks up the id (specs/01); a same-id `:put` is an expiry update, not an
  access (specs/05); `:rand` is seeded from the cache name (specs/05); write
  events apply on arrival and a pass flushes the remainder (specs/04);
  `deliver/2` never crashes a writer during a restart (specs/03); the clock
  is a `compile_env` (specs/06); `clear/1` never touches persistent_term
  (specs/01); `ex_doc` is an allowed dev dependency (AGENTS.md).
- 2026-10-27 (after M1.2, human decision): A1 and A2 reset from 1.3×/0.75× to
  1.5×/0.65× of raw ETS. Measured in isolation on the reference laptop
  (OTP 28.5, 4 schedulers), a named-table `:ets.lookup/2` costs about
  205 ns, so 1.3× left about 60 ns for everything else on a hit. The
  bounded hit path needs the config read, a scheduler-id read and two
  atomic read-modify-writes for the read buffer, about 80 ns, before any
  stats work: 1.41× with no counter op at all, 1.61× with one. The
  unbounded path with its one counter op measured 1.29× in isolation and
  1.25–1.38× under Benchee. The design cannot be made cheaper on this
  machine (dropping the read buffer's head read saved nothing), and
  Caffeine itself reads at about a third of a raw map's throughput, so the
  original figures were the error, not the implementation. To keep the
  hot path as lean as it can be, hits in a bounded cache are no longer
  counted with `:counters`; they are derived from the read-buffer tails
  (specs/01, 03, 08). The 2× margin over Cachex and Nebulex is unchanged.
- 2026-10-29 (after M2.10, human decision): A3 restated. The +10-point margin
  applies to the looping trace only. It was also written onto the OLTP rows,
  which was an error in the original spec: OLTP is a recency-driven
  database trace on which LRU is already near the best a policy can do, and
  the ARC paper's own ARC reaches only +6.1 points over LRU at size 1_000.
  The `theine ≥ lru` clause still applies to every row, OLTP included,
  because losing to LRU on a recency-heavy workload is a real weakness for
  a cache in front of a database. M2.10 measured the fixed 1% window at
  +3.61, +0.18 and −1.01 points against LRU on OLTP at 1_000, 2_000 and
  5_000, and a 20% window at +8.5, +4.6 and +1.7, so the remedy is the
  adaptive window: it moved from M6 into M2 (IMPLEMENTATION_PLAN.md M2.13)
  and is on by default, as in Caffeine (specs/05, 08). A new clause keeps
  the climber honest on the frequency traces: it may not fall more than 1
  point below the fixed window on any row (specs/09). The human gate
  compares the default policy with Caffeine's hill-climber policy and the
  fixed window with Caffeine's `WindowTinyLfu`.

# theine

A Caffeine-style in-memory cache for the BEAM, in pure Elixir. W-TinyLFU
admission with Caffeine's adaptive window, lossy striped read buffers,
amortized maintenance in one process (or in `n` with `partitions: n`, for
write-heavy caches), expiration, and single-flight loading
from an L2. ETS holds the entries and `:atomics` the access buffers and the
frequency sketch. No NIFs, ports or C; the one runtime dependency is
`telemetry`.

The name is a placeholder (theine is caffeine's other name).

## Usage

```elixir
children = [
  {Theine, name: :sessions, max_size: 100_000, expire_after_write: :timer.minutes(10)}
]

Theine.put(:sessions, id, session)
Theine.get(:sessions, id)
#=> {:ok, session}

# Single-flight: concurrent misses on one key run the loader once.
Theine.fetch(:sessions, id, fn id -> {:commit, Repo.get!(Session, id)} end)
#=> {:ok, session}
```

`Theine.start_link/1` documents every option; the `Theine` module documents
every call with an example.

| call | returns |
|---|---|
| `get(cache, key)` | `{:ok, value} \| :error` |
| `get(cache, key, default)` | `value \| default` |
| `fetch(cache, key)` | `{:ok, value} \| {:error, reason}` with the cache's `:loader` |
| `fetch(cache, key, loader, opts \\ [])` | the same with a per-call loader; `timeout:` |
| `fetch_async(cache, key, loader \\ nil, opts \\ [])` | `Task.t()` |
| `fetch_all(cache, keys, loader \\ nil, opts \\ [])` | `%{key => {:ok, value} \| {:error, reason}}` |
| `put(cache, key, value, opts \\ [])` | `:ok`; `ttl:`, `weight:` |
| `put_new(cache, key, value, opts \\ [])` | `:ok \| {:error, :exists}` |
| `delete(cache, key)` | `:ok` |
| `clear(cache)` | `:ok` |
| `expire(cache, key, ms)` / `persist(cache, key)` | `boolean` |
| `ttl(cache, key)` | `{:ok, ms \| :infinity} \| :error` |
| `refresh(cache, key)` | `:ok \| {:error, :refreshing \| :no_loader}` |
| `size(cache)` / `weighted_size(cache)` | `non_neg_integer` |
| `stats(cache)` | `%Theine.Stats{}` |

## Mapping to Caffeine

| Caffeine | theine |
|---|---|
| `Cache.getIfPresent` | `Theine.get/2` |
| `Cache.get(key, mappingFn)` | `Theine.fetch/3` |
| `LoadingCache.get` with `CacheLoader` | `Theine.fetch/2` with the cache-level `:loader` |
| `AsyncLoadingCache.get` returning a future | `Theine.fetch_async/3` returning a `Task` |
| `LoadingCache.getAll` without `loadAll` | `Theine.fetch_all/2`, a per-key result map |
| `LoadingCache.refresh` | `Theine.refresh/2` |
| `refreshAfterWrite` | `:refresh_after_write` |
| `expireAfterWrite` | `:expire_after_write` and per-entry `ttl:` |
| `maximumSize` / `maximumWeight` + `Weigher` | `:max_size` + `:weigher` |
| `Cache.put`, `invalidate`, `invalidateAll` | `put/4`, `delete/2`, `clear/1` |
| `estimatedSize`, `stats` | `size/1`, `stats/1` |
| `FrequencySketch` | `Theine.Sketch` |
| `StripedBuffer` / `BoundedBuffer` read buffer | `Theine.ReadBuffer` |
| write buffer (MPSC queue) | write events to the maintenance process |
| `BoundedLocalCache.maintenance` | `Theine.Maintenance` |
| window + probation + protected LRUs | `Theine.Policy` |
| `TimerWheel` | `Theine.Expiry` ordered index |

Caffeine's `evictionListener` is the `[:theine, :eviction]` telemetry event,
emitted only with `eviction_listener: true` (see `Theine.start_link/1`).

Not in v1: expire-after-access, explicit-removal listeners, a bulk loader
(`fetch_all/4` calls the loader once per missing key), distribution.

## Benchmarks

Three bench tasks, `mix bench get`, `mix bench hitrate` and
`mix bench maintenance`, turn the acceptance criteria into ratios measured in
one run on one machine. The thresholds and their history are in
`specs/09-benchmarks.md`. The figures below are the final gate's
(2026-11-13), recorded in full under `IMPLEMENTATION_PLAN.md` §Final gate.
They come from the development machine: an Intel i5-5257U with two cores
and two threads each, Linux, OTP 28, four schedulers,
`ERL_FLAGS="+sbt db +sbwt very_long"`.

The latency and throughput targets (A1, A2) are judged on a reference
machine with at least four physical cores. Its run is still pending, so
the A1/A2 figures here are the development machine's. They will be
replaced by the reference machine's once that run is recorded. On the
development machine the bounded cache sits at a recorded floor, just past
the targets. At `parallel: 4` that machine runs two readers per physical
core.

**`mix bench get`**: Zipf(1.0) reads of integer keys with 3-tuple values,
against `:ets.lookup/2` on a table with the same options. `theine` is
bounded at `max_size: n`, `theine_unbounded` runs with
`max_size: :infinity`.

| n | parallel | subject | p50 ns | p99 ns | ips | p50/ets | ips/ets |
|---|---|---|---|---|---|---|---|
| 1_000 | 4 | ets | 399 | 589 | 2_422_501 | 1.00 | 1.00 |
| 1_000 | 4 | theine | 597 | 876 | 1_496_485 | 1.50 | 0.62 |
| 1_000 | 4 | theine_unbounded | 542 | 757 | 1_689_917 | 1.36 | 0.70 |
| 1_000 | 4 | cachex | 1_307 | 2_049 | 718_350 | 3.28 | 0.30 |
| 1_000 | 4 | nebulex | 3_891 | 6_536 | 223_432 | 9.75 | 0.09 |
| 1_000_000 | 4 | ets | 470 | 798 | 2_023_172 | 1.00 | 1.00 |
| 1_000_000 | 4 | theine | 679 | 1_077 | 1_288_764 | 1.44 | 0.64 |
| 1_000_000 | 4 | theine_unbounded | 603 | 973 | 1_511_127 | 1.28 | 0.75 |
| 1_000_000 | 4 | cachex | 1_362 | 2_139 | 687_451 | 2.90 | 0.34 |
| 1_000_000 | 4 | nebulex | 3_954 | 7_030 | 217_566 | 8.41 | 0.11 |

At four readers a bounded hit has 1.86–2.08× Cachex's throughput and
5.5–6.7× Nebulex's. The targets of 1.5× `ets` latency, 0.65× `ets`
throughput and 2× Cachex are met by the unbounded cache on most shapes. A
bounded hit also records its read in an `:atomics` ring for the policy.
That puts the bounded cache at 1.34–1.50× `ets` latency at p50 and at
0.62–0.76× its throughput. At one reader on 1_000 keys, the bounded p99
was 1.42–1.55× `ets`'s in this run, and 1.5–2.0× in earlier runs of the
same hit path.

Writes: each `put` sends one message to the cache's maintenance process.
In bursts of 1_000 a `put` costs 5.8–8.0× an ETS insert (the target is at
most 10×). Sustained writes are a limit of the design. A writer that
outruns that one process waits for it (backpressure keeps the table
bounded), so one cache absorbs about as many writes per second as its
maintenance process can apply. Measured here, one cache sustained
330_000–509_000 overwrites/s from one writer, 208_000–259_000/s in total
from four writers, and about 104_000/s of new keys that each evict an
entry. That is 0.04–0.23× the rate of an ETS insert. If you need more
write throughput than that, start the cache with `partitions: n`: `n`
maintenance processes, each applying the writes of the keys that hash to
it under its own share of `max_size` (`Theine.start_link/1` documents the
costs: a share of at least 10_000 entries, an entry-weight limit of about
`max_size / n`, and up to `n * write_hwm` of slack above `max_size`). With
one writer per scheduler, measured by `mix bench maintenance` on the same
machine (overwrite rewrites existing keys, new evicts one entry per
write):

| partitions | scenario | puts/s | × partitions 1 |
|---|---|---|---|
| 1 | overwrite | 193_872 | 1.00 |
| 1 | new | 102_780 | 1.00 |
| 2 | overwrite | 332_299 | 1.71 |
| 2 | new | 154_493 | 1.50 |
| 4 | overwrite | 435_088 | 2.24 |
| 4 | new | 217_471 | 2.12 |

The gain is bounded by the cores the writers leave free; on a machine
with four physical cores `partitions: 4` must reach 2× (a human step of
the final gate, still pending). Writes to one hot key all go to one
partition, so partitions raise the ceiling for writes spread over many
keys only. A partitioned hit costs what the default hit costs, but each
partition runs its own drain passes, so under one reader on this
two-core machine `partitions: 4` read at 1.04–1.33× the default cache's
p50 on 100_000 keys (1.13–1.26× in an earlier run), at most 1.07× on
1_000_000 keys, and at most 1.01× with four readers.

**`mix bench hitrate`**: hit rate (%) on the ARC traces and two synthetic
ones. `theine_static` is the same cache with `adaptive: false`. Caffeine's
columns come from its own simulator on the same traces. That comparison is
a human step of the final gate, still pending.

| trace | size | lru | theine | Caffeine `HillClimberWindowTinyLfu` | theine_static | Caffeine `WindowTinyLfu` |
|---|---|---|---|---|---|---|
| OLTP | 1_000 | 32.83 | 39.77 | pending | 35.50 | pending |
| OLTP | 2_000 | 42.47 | 45.44 | pending | 41.89 | pending |
| OLTP | 5_000 | 53.65 | 55.16 | pending | 52.40 | pending |
| DS1 | 1_000_000 | 3.09 | 14.14 | pending | 14.59 | pending |
| DS1 | 4_000_000 | 20.24 | 45.88 | pending | 45.91 | pending |
| DS1 | 8_000_000 | 43.03 | 70.45 | pending | 70.45 | pending |
| S3 | 100_000 | 2.33 | 11.73 | pending | 11.99 | pending |
| S3 | 400_000 | 12.04 | 42.60 | pending | 42.32 | pending |
| P3 | 50_000 | 6.86 | 25.73 | pending | 26.44 | pending |
| loop | 1_000 | 0.00 | 58.67 | pending | 59.29 | pending |
| zipf | 10_000 | 56.61 | 64.03 | pending | 64.46 | pending |
| zipf | 100_000 | 76.41 | 79.71 | pending | 79.74 | pending |

With `partitions: 4` (`theine_p4`, run on the rows where each partition's
share is at least 10_000 entries: DS1, S3, P3 and zipf 100_000) the hit
rate was within 0.4 points of `theine` on every row, from −0.24 on P3 to
+0.36 on zipf 100_000 (M8.5b).

**`mix bench maintenance`**: a cache bounded at 1_000_000 entries under one
writer per scheduler. In a 30 s run of distinct-key writes the table never
held more than 1_001_028 entries, the `max_size + write_hwm + schedulers`
bound, and it was back at 1_000_000 a second after the writers stopped.
With `partitions: 4` the same run never held more than 1_004_023 entries,
under its `max_size + 4 * write_hwm + schedulers` bound of 1_004_100, and
settled at 1_000_000 too. In
the mixed run (75% Zipf reads, 25% writes, half of them with a 100 ms TTL)
a maintenance pass took 2.0 ms at p50, 3.9 ms at p99 and 7.7 ms at most,
against a 5 ms budget for the p99.

## Developing

- `specs/` is the source of truth for what to build, one topic per file.
  Start with `specs/00-overview.md`.
- `AGENTS.md` says how to build, test and benchmark in this repo; `mix gate`
  runs format, compile, test with coverage and dialyzer.
- `bench/README.md` documents the bench harness and its result files.
- `IMPLEMENTATION_PLAN.md` is the task list the build loop consumes.
  `loop.sh` runs that loop: `./loop.sh plan` once, then `./loop.sh [n]`.

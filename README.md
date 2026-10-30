# theine

A Caffeine-style in-memory cache for the BEAM, in pure Elixir. W-TinyLFU
admission with Caffeine's adaptive window, lossy striped read buffers,
amortized maintenance in one process, expiration, and single-flight loading
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

Not in v1: expire-after-access, removal listeners, bulk loads, distribution.

## Benchmarks

Three bench tasks, `mix bench get`, `mix bench hitrate` and
`mix bench maintenance`, turn the acceptance criteria into ratios measured in
one run on one machine (a 2-core, 4-thread i5-5257U, `ERL_FLAGS="+sbt db
+sbwt very_long"`). The thresholds and their history are in
`specs/09-benchmarks.md`; every recorded run is in `IMPLEMENTATION_PLAN.md`
§Benchmark log, and the final gate replaces the tables below.

**`mix bench get`** (2026-10-29, M5.1): Zipf(1.0) reads of integer keys with
3-tuple values, against `:ets.lookup/2` on a table with the same options.
`theine` is bounded at `max_size: n`, `theine_unbounded` runs with
`max_size: :infinity`.

| n | parallel | subject | p50 ns | p99 ns | ips | p50/ets | ips/ets |
|---|---|---|---|---|---|---|---|
| 1_000 | 4 | ets | 398 | 600 | 2_410_180 | 1.00 | 1.00 |
| 1_000 | 4 | theine | 628 | 905 | 1_327_624 | 1.58 | 0.55 |
| 1_000 | 4 | theine_unbounded | 568 | 804 | 1_554_386 | 1.43 | 0.64 |
| 1_000 | 4 | cachex | 1_308 | 2_088 | 697_310 | 3.29 | 0.29 |
| 1_000 | 4 | nebulex | 3_885 | 6_204 | 224_294 | 9.76 | 0.09 |
| 1_000_000 | 4 | ets | 475 | 825 | 1_977_693 | 1.00 | 1.00 |
| 1_000_000 | 4 | theine | 718 | 1_125 | 1_182_504 | 1.51 | 0.60 |
| 1_000_000 | 4 | theine_unbounded | 634 | 1_004 | 1_393_513 | 1.33 | 0.70 |
| 1_000_000 | 4 | cachex | 1_370 | 2_237 | 665_327 | 2.88 | 0.34 |
| 1_000_000 | 4 | nebulex | 3_960 | 6_931 | 216_884 | 8.34 | 0.11 |

At four readers a bounded hit has 1.8–1.9× Cachex's throughput and 5–7×
Nebulex's. The targets of 1.5× `ets` latency, 0.65× `ets` throughput and 2×
Cachex are met by the unbounded cache on most shapes. A bounded hit also
records its read in an `:atomics` ring for the policy, which costs 60–85 ns
more here, and that puts the bounded cache just past the targets on
several shapes. A `put` runs at
0.03–0.19× an ETS insert, because each write sends one message to the
maintenance process. That threshold is an open question.

**`mix bench hitrate`** (2026-10-29, M2.13): hit rate (%) on the ARC traces
and two synthetic ones. `theine_static` is the same cache with `adaptive:
false`.

| trace | size | lru | theine | theine_static |
|---|---|---|---|---|
| OLTP | 1_000 | 32.83 | 39.77 | 35.50 |
| OLTP | 2_000 | 42.47 | 45.44 | 41.89 |
| OLTP | 5_000 | 53.65 | 55.16 | 52.40 |
| S3 | 100_000 | 2.33 | 11.73 | 11.99 |
| S3 | 400_000 | 12.04 | 42.60 | 42.32 |
| P3 | 50_000 | 6.86 | 25.73 | 26.44 |
| loop | 1_000 | 0.00 | 58.67 | 59.29 |
| zipf | 10_000 | 56.61 | 64.03 | 64.46 |
| zipf | 100_000 | 76.41 | 79.71 | 79.74 |
| DS1 | 1_000_000 | 3.09 | 14.14 | 14.59 |
| DS1 | 4_000_000 | 20.24 | 45.88 | 45.91 |
| DS1 | 8_000_000 | 43.03 | 70.45 | 70.45 |

The comparison with Caffeine's own simulator on the same traces is a human
gate, still pending.

**`mix bench maintenance`** (2026-10-29, M3.2): a cache bounded at 1_000_000
entries under one writer per scheduler. In a 30 s run of distinct-key
writes the table never held more than 1_001_028 entries, the
`max_size + write_hwm + schedulers` bound, and it was back at 1_000_000 a
second after the writers stopped. In the mixed run (75% Zipf reads, 25%
writes, half of them with a 100 ms TTL) a maintenance pass took 1.7 ms at
p50, 3.7 ms at p99 and 10.8 ms at most, against a 5 ms budget for the p99.

## Developing

- `specs/` is the source of truth for what to build, one topic per file.
  Start with `specs/00-overview.md`.
- `AGENTS.md` says how to build, test and benchmark in this repo; `mix gate`
  runs format, compile, test with coverage and dialyzer.
- `bench/README.md` documents the bench harness and its result files.
- `IMPLEMENTATION_PLAN.md` is the task list the build loop consumes.
  `loop.sh` runs that loop: `./loop.sh plan` once, then `./loop.sh [n]`.

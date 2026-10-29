# bench/

Benchmarks that turn the acceptance criteria into numbers (specs/09). Ratios
are the gate, not absolute values: every subject is compared with a baseline
measured on the same machine in the same run.

```bash
ERL_FLAGS="+sbt db +sbwt very_long" mix bench get
mix bench get --sizes 1000 --warmup 0.5 --time 1   # quick smoke run, not a gate
```

`mix bench <name>` evaluates `bench/<name>.exs`. The task and its helpers live
in `bench/lib/`, which `mix.exs` compiles in `:dev` only, so none of it ships
in the hex package. A script evaluates to the list of failed thresholds; the
task exits non-zero when that list is not empty. Without the `ERL_FLAGS`
above the run still happens, with a warning on stderr and the missing flags
recorded in the result.

Each run writes `bench/results/<name>-<git-sha>.json` (gitignored) and prints
a markdown summary on stdout. Hot-path commits paste that summary into the
commit body (AGENTS.md).

## Result envelope (all benches)

Stable across commits so results can be diffed. `schema_version` changes
whenever a field is renamed, removed or changes meaning.

| field | type | meaning |
|---|---|---|
| `bench` | string | `"get"`, `"hitrate"`, `"maintenance"` |
| `schema_version` | integer | currently `1` |
| `git_sha` | string | `git rev-parse --short HEAD`, `"nogit"` outside a work tree |
| `git_dirty` | boolean | uncommitted changes were present |
| `timestamp` | string | ISO 8601 UTC, second precision |
| `system` | object | run environment, below |
| `results` | array | bench-specific rows |
| `thresholds` | array | one object per evaluated check, below |
| `passed` | boolean | every threshold passed (true when none were evaluated) |

`system` always has `otp`, `elixir`, `schedulers_online`, `erl_flags` (the
raw environment variable), `scheduler_bind_type` (as inspected by
`:erlang.system_info/1`). Benches add their own parameters.

Each `thresholds` entry:

| field | type | meaning |
|---|---|---|
| `id` | string | acceptance criterion, e.g. `"A1"` |
| `description` | string | what was compared, including the shape |
| `actual` | number | the measured ratio or value |
| `limit` | string | operator and bound, e.g. `"<= 1.5"` |
| `passed` | boolean | |

## `get` (A1, A2)

Each subject is populated with keys `1..n` and read with keys drawn from
Zipf(1.0) over `n` (`Theine.Bench.Zipf`, rejection-inversion, fixed seed).
65 536 keys are pre-drawn per `n`. Benchee's `before_each` hook picks one per
call, so the hook's cost stays outside the measured time. The `ets` subject is
`:ets.lookup/2` on a table created with theine's entries-table options
(specs/01) and holding `{key, value}`.

Values: `tuple3` is `{key, :value, 42}`; `binary_1kb` is a 1 KB binary from a
pool of 1 024. The pool keeps 1M entries from costing 1 GB and stops parallel
readers from contending on one refcount.

Shapes: `n` in 1 000, 100 000, 1 000 000; both value kinds; `parallel` 1 and
`System.schedulers_online()`. Warm-up 2 s, measurement 10 s per scenario.

Extra `system` fields: `warmup_s`, `time_s`, `sizes`, `parallel` (list),
`zipf_s`, `missing_erl_flags` (list).

Each `results` row:

| field | type | meaning |
|---|---|---|
| `scenario` | string | `"get"` (M5.1 adds `"put"`) |
| `subject` | string | `ets`, `theine`, `theine_unbounded`, `theine_nostats`, `cachex`, `nebulex` |
| `n` | integer | entries pre-populated |
| `value` | string | `"tuple3"` or `"binary_1kb"` |
| `parallel` | integer | concurrent Benchee processes |
| `p50_ns`, `p99_ns` | number | latency percentiles over all processes' samples, ns |
| `average_ns` | number | mean latency, ns |
| `ips` | number | Benchee ips: 1 / mean latency, i.e. **per process**; multiply by `parallel` for aggregate throughput. Ratios are unaffected |
| `sample_size` | integer | samples behind the statistics (Benchee caps at 1M per process) |
| `ratio_to_ets` | object | `p50`, `p99`, `ips` divided by the `ets` row of the same shape |

Subjects: `ets` is the floor; `theine` is bounded at `max_size: n` with
the policy on (every hit records into the read buffer, which the
maintenance process drains while the readers run); `theine_unbounded` is
`max_size: :infinity`; `theine_nostats` is bounded with `stats: false` and
is reported for information only. `cachex` and `nebulex` arrive in M5.1.

Thresholds (specs/09). They are evaluated for `theine` and `theine_unbounded`.

- A1: `p50/ets <= 1.5` and `p99/ets <= 1.5`, every shape.
- A2: `ips/ets >= 0.65` at full parallelism; `ips / cachex ips >= 2` and
  `ips / nebulex ips >= 2` at full parallelism when those subjects exist.

## `hitrate` (A3)

```bash
mix bench hitrate                          # every trace in bench/traces.exs
mix bench hitrate --traces loop,zipf       # a subset, by name
mix bench hitrate --window-percent 1,5,20  # sweep the window size (specs/05)
mix bench hitrate --memory-gb 2            # smaller replay passes
```

A replay harness, not Benchee. Each trace in the manifest is replayed at each
of its `sizes` through every policy. Every entry has weight 1; a hit is a key
present in the policy at the time of its access. Traces are not downloaded
or generated here: each must already be in `bench/traces/` with its recorded
SHA-256 (`mix bench.traces`). A trace that is missing, has no recorded hash,
or does not match fails one A3 threshold per size instead of being skipped.
`--manifest` and `--dir` select another manifest and trace directory.

The (size, policy) instances of a trace are packed, in order, into replay
passes over the file whose estimated ETS footprint (size × the policy's
bytes per entry: 160 for `lru`, 400 for `theine`) stays within
`--memory-gb` (default 4); an instance over the budget by itself gets a pass
of its own. DS1 at 8 M entries alone is about 3 GB of theine. Every
instance of a pass sees every key of the trace, in order.

Policies:

- `lru` (`Theine.Bench.LRU`): two private ETS tables, a baseline and not a
  product.
- `theine` (`Theine.Bench.Cache`): a real bounded cache at `max_size: size`
  and the specs/05 default window (`window_percent` 1), replayed
  synchronously. Every access is a `Theine.get/2`, a miss is followed by a
  `Theine.put/3`, and after every 32 accesses (the specs/08 default
  `drain_threshold`) the harness runs one pass with
  `Theine.run_maintenance/1`. Those are the only passes that run: the cache
  is started with `drain_threshold` 2^30 (above any trace length, so no
  reader sends `:drain`), `maintenance_interval` a day and a single ring
  stripe (so a batch's reads are drained in access order wherever the
  replaying process ran), and `close/1`
  raises if the maintenance process's pass count differs from the number
  of calls, if the cache's own hit count (specs/03 §Hits from the tails)
  differs from the replay's, if write events are still pending, or if the
  cache is over its bound after the last pass (specs/09 §Decisions M2.10).
  The admission guard's `:rand` is seeded from the cache name, which is
  derived from the trace, the size and the window percentage, so a run is
  reproducible to the hit.
- `theine_w<p>`: the same cache at `window_percent` `p`, one per extra value
  of `--window-percent`, reported with no threshold. The value 1 is always
  the `theine` row; if it is left out, no threshold is evaluated.

Extra `system` fields: `traces` (names replayed), `policies` (names),
`window_percents` (the list replayed), `accesses_per_pass` (32),
`memory_budget_bytes`.

Each `results` row:

| field | type | meaning |
|---|---|---|
| `trace` | string | manifest name |
| `size` | integer | cache capacity in entries |
| `policy` | string | `lru`, `theine`, `theine_w<p>` |
| `status` | string | `"ok"`, or `"error"` when the trace could not be replayed |
| `error` | string or null | why the trace could not be replayed |
| `requests` | integer or null | keys replayed (an ARC line counts once per block) |
| `hits` | integer or null | |
| `hit_rate` | number or null | `100 * hits / requests`, in percent |
| `seconds` | number or null | wall time of the replay pass the row ran in, shared by the rows of that pass |

Thresholds (specs/09):

- A3 `trace available, <trace> at <size>`: actual `0`, limit `== 1`, for
  every row whose trace could not be replayed.
- A3 `theine - lru hit rate (points), <trace> at <size>`: `>= 0.0` on every
  row; also `>= 10.0` on `loop` 1 000 and `OLTP` 1 000 and 2 000. Evaluated
  only where both `theine` and `lru` ran; otherwise the summary says "none
  evaluated".

## `maintenance` (A5, specs/04 budget)

```bash
ERL_FLAGS="+sbt db +sbwt very_long" mix bench maintenance
mix bench maintenance --max-size 10000 --duration 1   # quick smoke run, not a gate
```

Not Benchee. The drivers are in `Theine.Bench.Load` (`bench/lib`) and know
nothing about theine. A subject is a map of callbacks (`start`, `put`, `get`,
`size`, `call_writes`, `stop`; see the moduledoc), and the drivers can be
checked against a plain ETS table. Each subject is started fresh with
`max_size` and `write_hwm` 1 024 (the specs/08 default) for each of two runs:

- **write run**: `schedulers_online` writers put distinct keys for
  `--duration` seconds (default 30). One process samples the entries-table
  size every 10 ms. 1 s after the writers stop, the size is sampled once more.
- **mixed run**: keys `1..max_size` are put first. Then `schedulers_online`
  workers run for `--duration` seconds, each operation a `get` with
  probability 0.75, otherwise a `put`. Half of the puts carry a 100 ms TTL.
  Keys are Zipf(1.0) over `2 * max_size` (65 536 pre-drawn, seed 11), so
  writes keep evicting. Every `[:theine, :maintenance, :pass]` event during
  the run is collected.

`--max-size` defaults to 1 000 000. M2.11 adds the `theine` subject. Until
then every section says "no theine subject yet" and the bench exits 0.

Extra `system` fields: `max_size`, `duration_s`, `sample_ms`, `settle_ms`,
`write_hwm`, `pass_budget_ms`, `read_fraction`, `ttl_ms`, `zipf_s`,
`key_space`, `subjects` (names), `missing_erl_flags` (list).

Each `results` row is one subject:

| field | type | meaning |
|---|---|---|
| `subject` | string | `theine` |
| `max_size` | integer | cache bound |
| `overshoot.limit` | integer | `max_size + write_hwm + schedulers_online` |
| `overshoot.max_sample` | integer | largest sampled table size during the write run |
| `overshoot.samples` | integer | number of samples taken |
| `overshoot.writes` | integer | puts completed in the write run |
| `overshoot.settled_size` | integer | table size 1 s after the writers stopped |
| `pass.count` | integer | pass events in the mixed run |
| `pass.p50_us`, `pass.p99_us`, `pass.max_us` | number or null | pass `duration`, µs, nearest rank; null with no passes |
| `backpressure.reads`, `backpressure.writes` | integer | operations in the mixed run |
| `backpressure.call_writes` | integer or null | writes that took the call path (specs/03), null when the subject cannot tell |
| `backpressure.fraction` | number or null | `call_writes / writes` |

Thresholds (specs/09):

- A5 `max sampled size <= max_size + write_hwm + schedulers`: actual
  `max_sample`, limit `overshoot.limit`.
- A5 `size 1000 ms after writers stop`: actual `settled_size`, limit
  `<= max_size`.
- budget `pass p99 (us)`: `<= 5000`; budget `pass max (us)`: `<= 20000`.
  A run with no pass events fails `maintenance pass events observed`
  (actual `0`, limit `>= 1`) rather than passing vacuously.
- Backpressure is reported only.

## Traces (`mix bench.traces`)

```bash
mix bench.traces                  # every trace in bench/traces.exs
mix bench.traces --only loop,zipf # a subset, by name
```

`bench/traces.exs` is the manifest. It holds one map per trace with `name`,
`file`, `format`, `sizes` (the cache sizes `mix bench hitrate` runs it at) and
`sha256`, plus either `url` (and `compression`: `:none`, `:gzip` or `:zstd`)
or `generator`. The task writes each trace to `bench/traces/<file>`
(gitignored). It writes to a `.part` file first and renames it into place
only when its SHA-256 matches. `sha256` is the hash of the stored file, after
decompression, so an existing file can be checked without the archive. A file
already present with the right hash is left alone, so re-running is a no-op.
Synthetic traces are hashed too, which catches a generator that stops being
deterministic.

The task exits non-zero and names every trace that has no URL, fails to
download, or does not match its hash. With `sha256: nil` the failure message
prints the hash of the file it produced. To record a new trace: set `url`, run
`mix bench.traces --only NAME`, copy the printed hash in. `file://` URLs
install a trace that is already on disk. `--manifest` and `--dir` select
another manifest and output directory.

Formats on disk:

- `arc`: the ARC `.lis` format, one request per line,
  `start_block block_count ignored request_id`. A request touches keys
  `start_block .. start_block + block_count - 1`.
- `keys`: one non-negative decimal key per line.

Synthetic traces:

- `loop`: keys `0..1499` in order, 100 cycles (150 000 requests). It runs at
  `max_size` 1 000, so LRU never hits.
- `zipf`: 10 000 000 draws from Zipf(0.99) over `1..1_000_000`
  (`Theine.Bench.Zipf`, seed 2026).

The ARC traces (`OLTP`, `DS1`, `S3`, `P3`) have no URL or hash recorded yet.
See `IMPLEMENTATION_PLAN.md` M0.4b.

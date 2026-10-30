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

Extra `system` fields: `warmup_s`, `time_s`, `sizes`, `scenarios` (list), `parallel` (list),
`zipf_s`, `missing_erl_flags` (list).

Each `results` row:

| field | type | meaning |
|---|---|---|
| `scenario` | string | `"get"` or `"put"` |
| `subject` | string | `ets`, `theine`, `theine_unbounded`, `theine_nostats`, `cachex`, `nebulex` |
| `n` | integer | entries pre-populated |
| `value` | string | `"tuple3"` or `"binary_1kb"` |
| `parallel` | integer | concurrent Benchee processes |
| `p50_ns`, `p99_ns` | number | latency percentiles over all processes' samples, ns |
| `average_ns` | number | mean latency, ns |
| `ips` | number | Benchee ips: 1 / mean latency, i.e. **per process**; multiply by `parallel` for aggregate throughput. Ratios are unaffected |
| `sample_size` | integer | samples behind the statistics (Benchee caps at 1M per process) |
| `ratio_to_ets` | object | `p50`, `p99`, `ips` divided by the `ets` row of the same scenario and shape |

Subjects: `ets` is the floor; `theine` is bounded at `max_size: n` with
the policy on (every hit records into the read buffer, which the
maintenance process drains while the readers run); `theine_unbounded` is
`max_size: :infinity`; `theine_nostats` is bounded with `stats: false` and
is reported for information only. `cachex` is Cachex 4 bounded by the
`Cachex.Limit.Scheduled` hook at `n` with default options (least recently
written, pruned every 3 s once over `n`). `nebulex` is Nebulex 3's local
adapter (`Theine.Bench.NebulexCache`, in `bench/lib`) with `max_size: n`
and its defaults otherwise; it rotates generations when a size check
(every 10 s) finds `size >= n`, so it rotates during the run.

Each subject is populated, measured and torn down before the next one
starts (one Benchee job per suite), so no subject's background work runs
while another is measured; ratios still compare rows of the same run.

The `put` scenario runs after the subject's `get` runs, on the same
populated subject: `ets` (`:ets.insert/2`), `theine`, `cachex`,
`nebulex`. `--scenarios get` (or `put`) runs one of the two. Its inputs are `{key, value}` pairs pre-drawn like the `get`
keys, each key's value the one it already holds, so every subject stays at
`n` entries. The puts are sustained for the whole measurement, so the
`theine` figure includes the time writers spend blocked above `write_hwm`
(specs/03 §Delivery with backpressure).

Thresholds (specs/09). The `get` ones are evaluated for `theine` and
`theine_unbounded`.

- A1: `p50/ets <= 1.5` and `p99/ets <= 1.5`, every shape.
- A2: `ips/ets >= 0.65` at full parallelism; `ips / cachex ips >= 2` and
  `ips / nebulex ips >= 2` at full parallelism.
- put (id `"put"`): `theine` put `ips/ets >= 0.5`, every shape and both
  parallelisms.

## `hitrate` (A3)

```bash
mix bench hitrate                          # every trace in bench/traces.exs
mix bench hitrate --traces loop,zipf       # a subset, by name
mix bench hitrate --window-percent 1,5,20  # sweep the window size (specs/05)
mix bench hitrate --memory-gb 2            # smaller replay passes
mix bench hitrate --accesses-per-pass 1    # one access per pass, like Caffeine's simulator
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
  in its default configuration, the adaptive window (`adaptive: true`)
  starting at the specs/05 default of `window_percent` 1, replayed
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
  derived from the trace, the size, the window percentage and, for an
  adaptive cache, an `_adaptive` suffix, so a run is reproducible to the
  hit. Fixed-window caches keep the names they had before the adaptive
  window existed, so their hits compare with earlier results.
- `theine_w<p>`: the same adaptive cache starting at `window_percent` `p`,
  one per extra value of `--window-percent`, reported with no threshold.
  The value 1 is always the `theine` row; if it is left out, no `theine`
  threshold is evaluated.
- `theine_static`: the same cache with `adaptive: false` at `window_percent`
  1, the fixed-window W-TinyLFU, on every row whatever `--window-percent`
  says.

Extra `system` fields: `traces` (names replayed), `policies` (names),
`window_percents` (the list replayed), `accesses_per_pass` (32),
`memory_budget_bytes`.

Each `results` row:

| field | type | meaning |
|---|---|---|
| `trace` | string | manifest name |
| `size` | integer | cache capacity in entries |
| `policy` | string | `lru`, `theine`, `theine_w<p>`, `theine_static` |
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
  row; also `>= 10.0` on `loop` 1 000. Evaluated only where both `theine`
  and `lru` ran; otherwise the summary says "none evaluated".
- A3 `theine - theine_static hit rate (points), <trace> at <size>`: `>= -1.0`
  on every row where both ran: the climber may cost at most a point
  against the fixed window.

## Caffeine simulator cross-check (A3 human gate)

specs/09 asks a person, not the loop, to replay the same traces through
Caffeine's simulator and check, on every row of the hit-rate table, that
`theine` is within 1 percentage point of `HillClimberWindowTinyLfu` with the
`simple` strategy and `theine_static` within 1 point of `WindowTinyLfu`. It
needs a JDK and a checkout of `github.com/ben-manes/caffeine`; nothing here
runs it.

### Configuration

One `./gradlew simulator:run` per (trace, size) row, with three policies:
`linked.Lru` as the self-check, and the two counterparts. The `run` task
passes only `caffeine.*` system properties through to the simulator, so
every setting is a `-Dcaffeine.simulator.…` flag. The simulator's config
library ignores keys it does not know, and these keys were written without
access to the source, so check each one against
`simulator/src/main/resources/reference.conf` at the tag you build. The
self-check below catches a wrong trace path or size, not a wrong
policy setting.

| theine (specs/02, specs/05) | simulator setting |
|---|---|
| `max_size: size`, every entry of weight 1 | `maximum-size = size` |
| the trace file in `bench/traces/` | `trace.source = files`, `trace.files.paths.0 = <format>:<absolute path>` |
| `window_percent: 1` | `window-tiny-lfu.percent-main.0 = 0.99`, `hill-climber-window-tiny-lfu.percent-main.0 = 0.99` |
| protected 80% of main | `percent-main-protected = 0.80` in both sections |
| the climber: sample `10 * max_size`, first step 6.25% toward a smaller window, step × 0.98 per sample, restart at a 5-point change | `hill-climber-window-tiny-lfu.strategy.0 = simple`, `simple.percent-sample = 10`, `simple.percent-pivot = 0.0625`, `simple.step-decay-rate = 0.98`, `simple.sample-decay-rate = 1.0`, `simple.restart-threshold = 0.05`, `simple.tolerance = 0.0` |
| the 4-bit count-min sketch, halved every `10 * max_size` increments | `tiny-lfu.sketch = count-min-4`, `tiny-lfu.count-min-4.reset = periodic` |
| no admission filter on the baseline | `admission.0 = Always` (so `linked.Lru` stays plain LRU) |

Trace path mapping: an `arc` trace in `bench/traces.exs` is the simulator's
`arc` format (`start_block block_count ignored request_id`, one key per
block, which is how the harness reads it), and a `keys` trace is the
simulator's `lirs` format (one decimal key per line). Use the files that
`mix bench.traces` installed and verified, not the simulator's own copies,
so both sides replay the same bytes.

From the theine checkout, with the traces installed:

```bash
THEINE=$PWD
CAFFEINE=$HOME/src/caffeine   # a checkout of github.com/ben-manes/caffeine
S=caffeine.simulator
cd "$CAFFEINE"
while read -r trace format file size; do
  ./gradlew simulator:run -q </dev/null \
    -D$S.maximum-size="$size" \
    -D$S.trace.source=files \
    -D$S.trace.files.paths.0="$format:$THEINE/bench/traces/$file" \
    -D$S.policies.0=linked.Lru \
    -D$S.policies.1=sketch.WindowTinyLfu \
    -D$S.policies.2=sketch.HillClimberWindowTinyLfu \
    -D$S.admission.0=Always \
    -D$S.window-tiny-lfu.percent-main.0=0.99 \
    -D$S.window-tiny-lfu.percent-main-protected=0.80 \
    -D$S.hill-climber-window-tiny-lfu.percent-main.0=0.99 \
    -D$S.hill-climber-window-tiny-lfu.percent-main-protected=0.80 \
    -D$S.hill-climber-window-tiny-lfu.strategy.0=simple \
    -D$S.hill-climber-window-tiny-lfu.simple.percent-sample=10 \
    -D$S.hill-climber-window-tiny-lfu.simple.percent-pivot=0.0625 \
    -D$S.hill-climber-window-tiny-lfu.simple.step-decay-rate=0.98 \
    -D$S.hill-climber-window-tiny-lfu.simple.sample-decay-rate=1.0 \
    -D$S.hill-climber-window-tiny-lfu.simple.restart-threshold=0.05 \
    -D$S.hill-climber-window-tiny-lfu.simple.tolerance=0.0 \
    -D$S.tiny-lfu.sketch=count-min-4 \
    -D$S.tiny-lfu.count-min-4.reset=periodic \
    > "$THEINE/bench/results/caffeine-$trace-$size.txt"
done <<'ROWS'
OLTP    arc  OLTP.lis   1000
OLTP    arc  OLTP.lis   2000
OLTP    arc  OLTP.lis   5000
DS1     arc  DS1.lis    1000000
DS1     arc  DS1.lis    4000000
DS1     arc  DS1.lis    8000000
S3      arc  S3.lis     100000
S3      arc  S3.lis     400000
P3      arc  P3.lis     50000
loop    lirs loop.keys  1000
zipf    lirs zipf.keys  10000
zipf    lirs zipf.keys  100000
ROWS
```

The rows are the `sizes` of `bench/traces.exs`; test/theine/bench_docs_test.exs
fails when the two disagree. `</dev/null` keeps Gradle from reading the row
list from stdin. DS1 at 8 M entries needs several GB of heap; if
the simulator runs out of memory, raise the `run` task's heap in the
simulator's Gradle build and re-run that row.

### Self-check

The harness's `lru` is exact LRU, so `linked.Lru` must print the same
hit rate, to the hundredth, as these rows (and the same request count where
the report shows one). A row where it does not was read differently, by
trace, format or size, and its other two policies mean nothing until that is
fixed:

| trace | size | requests | lru hits | lru hit rate |
|---|---|---|---|---|
| OLTP | 1000 | 914145 | 300122 | 32.83 |
| OLTP | 2000 | 914145 | 388235 | 42.47 |
| OLTP | 5000 | 914145 | 490443 | 53.65 |
| DS1 | 1000000 | 43704979 | 1348689 | 3.09 |
| DS1 | 4000000 | 43704979 | 8847982 | 20.24 |
| DS1 | 8000000 | 43704979 | 18808317 | 43.03 |
| S3 | 100000 | 16407702 | 381872 | 2.33 |
| S3 | 400000 | 16407702 | 1975298 | 12.04 |
| P3 | 50000 | 3912296 | 268386 | 6.86 |
| loop | 1000 | 150000 | 0 | 0.00 |
| zipf | 10000 | 10000000 | 5661385 | 56.61 |
| zipf | 100000 | 10000000 | 7641405 | 76.41 |

### Comparison table

Take `theine` and `theine_static` from the final gate's `mix bench hitrate`
run (`IMPLEMENTATION_PLAN.md` §Final gate), and the two Caffeine columns
from the simulator's hit-rate column for `sketch.HillClimberWindowTinyLfu`
(the `simple` row) and `sketch.WindowTinyLfu` (the 99% main row). Δ is theine
minus Caffeine in percentage points; the row passes when both |Δ| ≤ 1.00.
The template is the one under `IMPLEMENTATION_PLAN.md` §Final gate; fill it
there and copy it into the README's §Benchmarks.

Three differences are known and are what to look at first when a row misses:

- The harness drains reads in batches of 32 accesses per pass; the simulator
  applies each access before the next. `mix bench hitrate
  --accesses-per-pass 1` replays the simulator's way. It is a diagnostic, not
  the gated row: the gate compares the default configuration.
- theine's sketch is the block layout of Caffeine's cache (`FrequencySketch`,
  specs/02 §Decisions M2.1). The simulator's `count-min-4` sketch may not be,
  so the same keys can collide differently.
- The admission guard (a candidate of frequency ≥ 6 admitted 1 time in 128)
  draws from a different random source on each side.

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

`--max-size` defaults to 1 000 000. The one subject is `theine`: a real
cache started with `max_size`, `write_hwm` and otherwise the specs/08
defaults, whose `size` is the entries table's count and whose
`call_writes` is `Theine.Maintenance.info/1`'s field of that name (the
backpressure calls the maintenance process consumed; specs/03 §Decisions
M2.11), read before and after the mixed run.

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

The ARC traces (`OLTP`, `DS1`, `S3`, `P3`) come from the `moka-rs/cache-trace`
mirror, zstd-compressed, with the hashes recorded in M0.4b.

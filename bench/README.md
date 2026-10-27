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
| `limit` | string | operator and bound, e.g. `"<= 1.3"` |
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

Thresholds (specs/09). They are evaluated for `theine` and `theine_unbounded`
when those subjects exist. Until then the summary says "none evaluated".

- A1: `p50/ets <= 1.3` and `p99/ets <= 1.3`, every shape.
- A2: `ips/ets >= 0.75` at full parallelism; `ips / cachex ips >= 2` and
  `ips / nebulex ips >= 2` at full parallelism when those subjects exist.

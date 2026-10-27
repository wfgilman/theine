# 09 — Benchmarks and the numeric gate

One topic: the harness that turns acceptance criteria A1, A2, A3 and A5 into
numbers, the baselines it compares against, and the thresholds. The
thresholds here are the contract; the build prompt forbids relaxing them.

## Reference machine

Numbers are compared on the same machine in the same run; absolute values
are not the gate, ratios are. Every bench writes a JSON result to
`bench/results/<name>-<git-sha>.json` plus a markdown summary to stdout.
`bench/results/` is gitignored; the summary table goes into commit bodies
for hot-path changes (AGENTS.md) and the final gate goes into
`IMPLEMENTATION_PLAN.md`.

The bench runs with `ERL_FLAGS="+sbt db +sbwt very_long"` where supported
(scheduler binding and busy-wait reduce noise) and with a warm-up of 2 s and
a measurement of 10 s per scenario (Benchee `warmup:`/`time:`). Use
`Benchee`'s `parallel:` option for the multi-scheduler scenarios.

## `mix bench get` (A1, A2)

Subjects, each pre-populated with `n` entries and read with a Zipf(1.0)
key distribution over `n` so that the working set is skewed like a real
cache:

| subject | notes |
|---|---|
| `ets` | `:ets.lookup/2` on a table created with theine's exact options; the floor |
| `theine` | `Theine.get/2`, `max_size: n` (bounded, policy on) |
| `theine_unbounded` | `Theine.get/2`, `max_size: :infinity` |
| `theine_nostats` | bounded, `stats: false` |
| `cachex` | `Cachex.get/2`, limit `n`, default policy |
| `nebulex` | `Nebulex.Adapters.Local` `get/2`, `max_size: n` |

Shapes: `n ∈ {1_000, 100_000, 1_000_000}`; keys are integers; values are
(a) a 3-tuple of small terms and (b) a 1 KB binary. Scenarios at
`parallel: 1` and `parallel: System.schedulers_online()`.

Reported per subject and shape: p50, p99 latency (Benchee's percentiles),
ips, and the ratio to `ets`.

**Thresholds** (every shape, both parallelisms):

- `theine` p50 ≤ 1.3 × `ets` p50 and p99 ≤ 1.3 × `ets` p99. (A1)
- `theine` ips ≥ 0.75 × `ets` ips at full parallelism. (A2)
- `theine` ips ≥ 2 × `cachex` ips and ≥ 2 × `nebulex` ips at full
  parallelism. (A2)

A hot-path task fails its gate if any threshold that previously passed now
fails.

Until M2 adds the bounded subject, the same three thresholds apply to
`theine_unbounded`, the only theine subject that exists at the end of M1
(specs/00 M1 says A1 and A2 hold "with policy disabled"). After M2 they
apply to both.

Also report a `put` scenario (`theine` vs `ets` insert vs Cachex vs Nebulex)
for information; its only threshold is that `theine` put ips is at least
0.5 × `ets` insert ips (a write is an insert, an id allocation and a message
send).

## `mix bench hitrate` (A3)

A replay harness, not Benchee: read a trace of keys, run it through a policy,
count hits.

Policies in the harness:

- `lru`: a reference LRU in the harness itself (any correct implementation;
  it is a baseline, not a product).
- `theine`: a real cache, driven synchronously by calling
  `run_maintenance/1` every `drain_threshold` accesses so results are
  deterministic and independent of scheduler timing.

Traces in `bench/traces/` (gitignored; `mix bench.traces` downloads them and
verifies a SHA-256 recorded in `bench/traces.exs`):

| trace | type | source | sizes |
|---|---|---|---|
| ARC `OLTP` | database | the ARC paper traces (Megiddo & Modha) | 1_000, 2_000, 5_000 |
| ARC `DS1` | database | same | 1M, 4M, 8M |
| ARC `S3` | search | same | 100_000, 400_000 |
| ARC `P3` | workstation | same | 50_000 |
| `loop` | synthetic looping scan | generated: cycle over 1.5 × max distinct keys | 1_000 |
| `zipf` | synthetic Zipf(0.99) | generated, 10M requests over 1M keys | 10_000, 100_000 |

The ARC trace files are public and are what Caffeine's simulator uses, so a
cross-check is apples to apples. The task that writes `bench/traces.exs`
records the URLs and hashes it actually downloaded.

**Thresholds**:

- On every trace and size, `theine` hit rate ≥ `lru` hit rate.
- On `loop` at 1_000 and on `OLTP` at 1_000 and 2_000, `theine` ≥ `lru` + 10
  percentage points.
- Human gate (M5, not run by the loop): run Caffeine's simulator
  (`./gradlew simulator:run` with the trace and `maximum-size` set) on the
  same traces; `theine` must be within 1 percentage point of its
  `WindowTinyLfu` policy on every row. Record the comparison table in
  `IMPLEMENTATION_PLAN.md` §Final gate and in the README.

## `mix bench maintenance` (A5, specs/04 budget)

A Benchee-free script that drives a bounded cache (`max_size` 1_000_000)
with `schedulers_online` writer processes and reports:

- **Overshoot**: sample `:ets.info(table, :size)` every 10 ms during a 30 s
  100% write run with distinct keys. Threshold: every sample ≤ `max_size +
  write_hwm + schedulers_online`; 1 s after writers stop, size ≤ `max_size`.
- **Pass duration**: from the `[:theine, :maintenance, :pass]` events during
  a mixed run (75% read Zipf, 25% write, 50% of writes with a 100 ms TTL).
  Threshold: p99 ≤ `pass_budget` (5 ms); max ≤ 4 × `pass_budget`.
- **Write backpressure**: fraction of writes that took the call path.
  Reported, no threshold; it should be near zero in the mixed run.

## Running in the loop

The build prompt runs `mix bench get` for hot-path tasks only, because the
full suite takes minutes. `mix bench hitrate` is run by the policy tasks in
M2 and by the final gate. `mix bench maintenance` is run by M2 and M3 tasks
that touch the maintenance process and by the final gate. Each bench script
exits non-zero when a threshold fails so the loop sees it as a failed gate.

## Acceptance

- Each `mix bench *` task exists, runs on an empty library in M0 (reporting
  only the baselines), and exits non-zero on a failed threshold.
- The JSON result schema is documented in `bench/README.md` and stable
  across commits so results can be diffed.
- The final gate in M5 records all three summaries plus the simulator
  comparison in `IMPLEMENTATION_PLAN.md`.

## Decisions

(Add dated entries when the implementation forces a change.)

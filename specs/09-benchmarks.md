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

- `theine` p50 ≤ 1.5 × `ets` p50 and p99 ≤ 1.5 × `ets` p99. (A1)
- `theine` ips ≥ 0.65 × `ets` ips at full parallelism. (A2)
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

`theine` is the default configuration, which has the adaptive window
(specs/05). `theine_static` is the same cache with `adaptive: false` and
the 1% window; the harness reports it on every row.

- On every trace and size, `theine` hit rate ≥ `lru` hit rate.
- On `loop` at 1_000, `theine` ≥ `lru` + 10 percentage points.
- On every trace and size, `theine` ≥ `theine_static` − 1 percentage point.
- Human gate (M5, not run by the loop): run Caffeine's simulator
  (`./gradlew simulator:run` with the trace and `maximum-size` set) on the
  same traces. On every row, `theine` must be within 1 percentage point of
  `HillClimberWindowTinyLfu` with the `simple` strategy (the climber
  Caffeine's cache itself uses), and `theine_static` within 1 point of
  `WindowTinyLfu`. Record the comparison table in `IMPLEMENTATION_PLAN.md`
  §Final gate and in the README.

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

- 2026-10-27 (M0.3): how `mix bench get` measures, where the text above left
  it open. Keys are pre-drawn (65 536 per `n`) and picked in Benchee's
  `before_each` hook, so sampling cost is outside the measured time for every
  subject. Otherwise a Zipf draw per call would dilute every ratio towards 1.
  The 1 KB values come from a pool of 1 024 binaries rather than one per key.
  1M distinct values would need 1 GB, and a single shared binary would make
  parallel readers contend on its refcount. `ips` is Benchee's per-process
  figure; ratios are the same as with aggregate throughput. The task and its
  helpers live in `bench/lib`, compiled in `:dev` only.
- 2026-10-27 (M0.4): trace details the table above left open. `loop` is keys
  `0..1499` cycled 100 times (150 000 requests); the table fixes only the
  1.5 × key count. `zipf` uses seed 2026. Synthetic traces are stored as one
  decimal key per line. Like the ARC traces they carry a SHA-256 in
  `bench/traces.exs`, so a generator that stops being deterministic fails the
  task. The recorded hash is of the file as stored in `bench/traces/`, after
  decompression, so re-runs can verify without the archive.
  `mix bench.traces` downloads with OTP's `:httpc` (no new dependency) and
  also accepts `file://` URLs. The ARC URLs and hashes are not recorded yet.
  The build loop that wrote the task had no network access, and this spec
  allows only URLs and hashes that were actually downloaded. Until they are
  recorded, the task fails and names each ARC trace (IMPLEMENTATION_PLAN.md
  M0.4b).
- 2026-10-27 (M0.5): how `mix bench hitrate` replays, where the text above
  left it open. Every access has weight 1, and an ARC line requests each of
  its blocks as one key, as Caffeine's simulator reads them. The harness
  only verifies traces and never downloads or generates them. A trace that
  is missing or does not match its hash counts as one failed A3 threshold
  per size ("trace available"), so the bench exits non-zero rather than
  skipping the row. `--traces` selects a subset by name. Hit rates are
  reported in percent, so the A3 margin compares percentage points directly.
- 2026-10-27 (M0.6): how `mix bench maintenance` drives load, where the text
  above left it open. Each of the two runs starts a fresh cache with the
  specs/08 defaults. The mixed run lasts as long as the write run (30 s) and
  first puts keys `1..max_size`. Its keys are Zipf(1.0) over
  `2 * max_size`, so writes keep forcing evictions and the pass is measured
  under eviction load, not just under policy updates. The keys are pre-drawn
  as in `mix bench get`. Pass durations are nearest-rank percentiles. A run
  with no pass events fails a threshold rather than passing with nothing
  measured. The backpressure fraction needs a count of call-path writes.
  The harness takes it from a subject callback, so M2.11 decides where
  theine exposes it.
- 2026-10-27 (after M1.2, human decision): A1 and A2 reset to 1.5× and 0.65×.
  The full `mix bench get` on the finished M1.2 tree passed 20 of 30
  checks at the old 1.3×/0.75×, the failures all between 1.30× and 1.50×
  (table in IMPLEMENTATION_PLAN.md §Benchmark log). Isolated measurement
  of the primitives (specs/00 §Decisions) showed that the bounded hit path
  of M2.8 cannot get under about 1.4× on the reference laptop even with no
  stats work, so 1.3× was never reachable by this design. 1.5× leaves the
  bounded path roughly 20 ns of headroom; the loop may not relax these
  figures further. `bench/get.exs` and `bench/README.md` carry the new
  limits.
- 2026-10-27 (M1.6): how a hot-path task reads a single failed check in
  the full `mix bench get`. The p99 of the `ets` floor at n=1000 tuple3
  parallel=1 wanders by about ±0.1× between full runs of one tree (338 to
  433 ns on the same day; the earlier logs show 384 to 677 ns) and has
  crossed the A1 limit for `theine_unbounded` three times with no change to
  the hit path (M1.5 once, M1.6 twice). The thresholds stand. A task whose
  full run fails only that check re-runs `mix bench get --sizes 1000` on
  the same tree, with the `ERL_FLAGS` above; if every n=1000 check passes
  there, the task records both tables in IMPLEMENTATION_PLAN.md and is not
  failed by the noisy run. A second failure in the targeted run, or a
  failure at any other shape, is a regression.
- 2026-10-28 (M2.8d): the measured floor of the bounded hit on the
  reference machine, recorded because the levers the plan listed do not
  reach the nine A1/A2 checks the bounded subject still fails (A2 on the
  three tuple3 shapes at parallel 4, A1 p50 at n=100000 parallel 1, and
  the discovered-issue-4 p99 row; M2.8c's table). The thresholds stand.
  What a compiled probe (one reader pinned per row, Zipf keys as the
  bench draws them, 2 M hits per row, `+sbt db +sbwt very_long`; tables in
  IMPLEMENTATION_PLAN.md §Benchmark log) measured, in ns over the
  unbounded hit:

  | n | bounded, maintenance paused | bounded, maintenance running | running, 2 schedulers on separate cores |
  | --- | --- | --- | --- |
  | 1_000 | 48–56 | 67–82 | 65 |
  | 100_000 | 51–52 | 93–102 | 102 |
  | 1_000_000 | 44–47 | 91–98 | 102 |

  With no passes running the bounded hit costs the same 44–56 ns at every
  n: the two atomics ops of specs/03 (a replica of the path in the probe
  module puts the claim at 23–30 ns and the slot write at 22–25 ns, both
  flat in n). The growth with n that M2.8d was to explain is therefore not
  the ring's cache lines, not the `tail`/`head` line, and not the id
  write; it is the maintenance process running passes at the same time,
  and it survives moving that process to the other physical core (`+S 2`),
  so it is not the SMT sibling either but the pass's own memory traffic
  through the private policy tables and the sketch, which grow with n and
  share the 3 MB L3 with the reader (the reference laptop is an i5-5257U:
  two cores, two threads each, so `parallel: 4` runs two readers per
  core). A replica drainer that reads the stripe and writes `head` once
  per millisecond from another scheduler costs the reader 1–5 ns at
  n ≤ 100_000, so the layout levers have nothing to recover at one reader:
  `head` on its own line (`16 + slots`, the plan's first lever) measured
  0 ns at one reader and 0–3 ns at four, because the array's alignment is
  not known and the tail then shares a line with the previous stripe's
  last slots exactly as before; a slots-first layout (`slots + 16`, tail
  and head each padded after the ring, alignment-proof) 0 ns at one
  reader and 8–16 ns at four; 32 slots 0 ns; the put on even sequences
  only 0 ns at one reader and 10–25 ns at four. All of those are inside
  the bench's ±0.1× wander, so none is adopted and the layout of specs/03
  stays. `drain_backoff` 7 halves the running-minus-paused gap at four
  schedulers (82→72, 102→80, 91→77 at the three n) and removes most of it
  at two, which would put n=100000 parallel 1 at about 1.50×, on the
  line; the default stays 3 (specs/04 §Decisions M2.8c) and the pass's
  footprint is the lever left (IMPLEMENTATION_PLAN.md M2.11b). At four
  readers the two ops cost about 65 ns each instead of 23, since a locked
  read-modify-write stalls the thread while its SMT sibling runs, so the
  bounded hit sits 87–91 ns over the unbounded one with maintenance
  paused and 130–150 with it running; A2 at 0.65× `ets` asks the bounded
  subject to be within 3–7% of `theine_unbounded` on the tuple3 shapes,
  which two atomics ops on this machine cannot be. The bounded subject's
  floor on this machine is thus: p50 about 1.45–1.55× at parallel 1 and
  ips about 0.57–0.62× `ets` at parallel 4 on tuple3, 0.71–0.72× on
  binary_1kb (where the longer `ets` lookup dilutes the constant). A
  machine with four physical cores would show the two-op cost at about 48
  ns at full parallelism and the A2 rows nearer 0.65; the final gate (M5)
  records which machine it ran on.
- 2026-10-29 (M2.10): how the `theine` policy of `mix bench hitrate` is
  driven, where the text above says "synchronously by calling
  `run_maintenance/1` every `drain_threshold` accesses". The harness
  (`Theine.Bench.Cache`, `bench/lib`) replays every access as a
  `Theine.get/2` with a `Theine.put/3` after a miss, and runs one pass with
  `Theine.run_maintenance/1` after every 32 accesses (the specs/08 default
  `drain_threshold`; `--accesses-per-pass` sets it, 1 being the fully
  synchronous replay of Caffeine's simulator, 64 the ring's capacity). For
  those to be the only passes, the cache is started with its own
  `drain_threshold` at 2^30, above the length of every trace, so no
  reader's `:drain` ever fires, `maintenance_interval` a day away, and
  `stripes: 1`; the `write_batch` (256) and follow-up triggers (a full
  stripe at 64 slots, a capped eviction at 1024) cannot fire within a
  batch of at most 64. A reader-triggered pass would run at a
  scheduler-dependent point of the batch and change which reads and
  writes it sees, and a second pass in a batch advances a sketch reset by
  an extra chunk, so a run would not be reproducible to the hit. The
  single stripe is for the same reason: with one stripe per scheduler the
  reads of a batch land in the stripes of whichever schedulers the
  replaying process ran on, and the pass, which drains stripe by stripe,
  applies them in an order that changes from run to run (the first two
  OLTP runs of M2.10, with the default stripes, differed by 59, 351 and
  577 hits at the three sizes). The writes of a batch are applied as they
  arrive, each followed by the eviction it forces (specs/04 §The pass,
  M2.11c), and the harness waits for each one: a miss's put is followed
  by a `Theine.Maintenance.info/1` round trip, so the put and its eviction
  are done before the next access (M2.11e, below). The reads sit in the
  one stripe until the pass drains them, so each pass sees the batch's
  writes with their evictions, then its reads in access order, then its
  own step 5, which has nothing left to do. `close/1`
  raises when the maintenance process's pass count differs from the
  harness's call count, when the cache's own hit count (specs/03 §Hits from
  the tails) differs from the replay's, when events are still pending, or
  when the cache is over its bound after the last pass, so a run that was
  not the synchronous one fails instead of reporting a number. The `:rand`
  seed comes from the cache name, which is built from the trace, the size
  and the window percentage, so two runs admit the same keys; a run is
  checked to the exact hit count (IMPLEMENTATION_PLAN.md §Benchmark log,
  M2.10). `window_percent` is swept with `--window-percent 1,5,20`: the
  row at the specs/05 default 1 is `theine` and carries the thresholds,
  every other value is reported as `theine_w<p>` with none. Instances are
  packed into replay passes within `--memory-gb` (default 4) from each
  policy's measured ETS bytes per entry (theine 378, rounded to 400, lru
  144, rounded to 160), because DS1's three theine instances alone would
  need about 5 GB and the reference laptop has 8; the `seconds` column is
  per pass. What the first run measured, and what it leaves open: `loop`
  1_000 at 58.84% against LRU's 0 meets its margin; OLTP does not. The
  harness's `lru` reproduces the ARC paper's LRU figures for OLTP exactly
  (32.83, 42.47, 53.65 at 1_000, 2_000, 5_000), and `theine` with the
  specs/05 default window sits at +3.61, +0.18 and −1.01 points
  (+2.61, −0.52, −1.24 replayed one access per pass as Caffeine's
  simulator does), which is where a static-window W-TinyLFU is known to
  sit on this recency-biased trace; Caffeine's authors use OLTP to
  motivate the adaptive window (§Adaptive window of specs/05, M6.1). The
  +10 margin at 1_000 would need 42.8%, above the ARC paper's own 38.93
  for ARC. specs/00 A3 puts the margin on "the looping and scan traces"
  and the table above types OLTP as "database", so the two specs disagree
  about OLTP; the thresholds here are not changed by the loop, the bench
  exits non-zero on the three OLTP checks, and the question is recorded
  for a human in IMPLEMENTATION_PLAN.md §Open questions (1) with a
  recommended resolution.
- 2026-10-29 (after M2.10, human decision): open question 1 resolved. The +10
  margin is on `loop` 1_000 only; `theine ≥ lru` stays on every row,
  OLTP included, and is met by the adaptive window, now the default
  (specs/00 §Decisions). A `theine_static` subject (`adaptive: false`) is
  added with the check `theine ≥ theine_static − 1` on every row, and the
  human gate compares each subject with its Caffeine counterpart.
  `bench/hitrate.exs` `@margin_rows` drops the OLTP rows; the
  `theine_static` subject and its check arrive with the adaptive window
  (IMPLEMENTATION_PLAN.md M2.13). Until then the bench still fails
  `theine ≥ lru` on OLTP, as it should.
- 2026-10-29 (M2.11e): the replay waits for each miss's put to be applied.
  Since M2.11c a `:put` evicts when the maintenance process receives it,
  so whether that eviction lands before or after the replaying process's
  next gets depended on when the scheduler ran the maintenance process: a
  key it removed hit in one run and missed in the next. theine_test's
  replay test failed about once in 120 full-suite runs that way. Measured
  on that test's key sequence: 15_298 hits with every eviction before the
  next get, 15_279 with every eviction after the batch's gets (maintenance
  paused), and 15_279 in 60 unsynchronised runs, quiet and under a
  spinner per scheduler. The unsynchronised replay mostly sat at the
  "after" end only because the replayer rarely yields within a 32-access
  batch. `Theine.Bench.Cache` and the test now follow a miss's put with a
  `Theine.Maintenance.info/1` round trip (the mailbox is FIFO per sender,
  so the reply comes after the put and its eviction). `write_hwm` cannot
  force the call path, since it must be at least 1. The "before" order is
  the one taken: it is Caffeine's simulator order (the eviction runs
  inside the access that missed), and it is what a cache whose
  maintenance keeps up serves. The "after" order counted as hits reads of
  entries the policy had already evicted. The OLTP rows move to within
  0.06 points of the one-access-per-pass figures of M2.10 (35.50, 41.89,
  52.40 against 35.44, 41.95, 52.41). Two OLTP runs agree to the hit, both
  under a concurrent `mix test --repeat-until-failure` load, and the
  replay test passed 300 full-suite repeats. The full run's rows and cost
  are in IMPLEMENTATION_PLAN.md §Benchmark log M2.11e.
- 2026-10-29 (M2.11b): a correction to the M2.8d entry above. Its "running,
  2 schedulers on separate cores" column did not measure separate cores.
  In probes of this kind, which pin the reader and leave the maintenance
  process unpinned, every pass with four schedulers and 73–100% of them
  with two ran on the reader's own scheduler. M2.11b counted that with a
  telemetry handler. So the growth with n that M2.8d attributed to L3
  traffic is the pass's CPU time on the reader's scheduler. It grows with
  n because each drained read costs more in larger tables (specs/04
  §Decisions M2.11b). The rest of the M2.8d entry stands: the paused rows,
  the ring levers, the SMT cost of the atomics ops, and the bounded
  subject's floor. A probe that means to put the two on separate schedulers
  must check where the passes ran, with `:erlang.system_info(:scheduler_id)`
  in a `[:theine, :maintenance, :pass]` handler; `+S` alone does not place
  them.

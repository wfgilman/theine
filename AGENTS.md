# theine — agent quick-start

Read this, then `specs/00-overview.md`, then `IMPLEMENTATION_PLAN.md`.
Specs are the source of truth. The plan is derived from them and is disposable.

## What this is

A bounded in-memory cache for the BEAM in pure Elixir, modelled on Java's
Caffeine: ETS for entries, `:atomics` for the access buffers and frequency
sketch, one maintenance process for policy, single-flight loaders for L2.
No NIFs, no ports, no C. That is a hard rule (specs/00-overview.md).

## Toolchain

Elixir 1.20 on Erlang/OTP 28, managed with mise (`.mise.toml`). OTP 27 is the
floor: `write_concurrency: :auto` and `:ets.lookup_element/4` are required.

## Commands (the backpressure)

```bash
mise install                              # once
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test                                  # unit + property + concurrency; must stay under 60 s
mix test --include stress                 # soak tests; run before touching a hot path
mix dialyzer                              # warnings are errors
mix bench get                             # bench/get.exs: theine vs raw ETS vs Cachex vs Nebulex
mix bench hitrate                         # bench/hitrate.exs: W-TinyLFU vs LRU on bench/traces/
mix bench maintenance                     # bench/maintenance.exs: pass duration, overshoot under writes
```

Every commit must pass format, compile, test, dialyzer. A task that touches a
hot path (`Theine.get/2`, `Theine.put/4`, `Theine.ReadBuffer`, `Theine.Entry`)
must also run `mix bench get` and paste the summary table into the commit body.

## Layout

```
lib/theine.ex                 public API (specs/08)
lib/theine/config.ex          resolved config struct, stored in persistent_term once at start
lib/theine/entry.ex           entries table layout + read/write primitives (specs/01)
lib/theine/sketch.ex          count-min sketch over :atomics (specs/02)
lib/theine/read_buffer.ex     striped lossy ring buffers over :atomics (specs/03)
lib/theine/write_events.ex    write-event delivery + backpressure (specs/03)
lib/theine/maintenance.ex     the one policy process (specs/04)
lib/theine/policy.ex          W-TinyLFU over private ETS (specs/05)
lib/theine/expiry.ex          expiration index + sweep (specs/06)
lib/theine/loader.ex          single-flight fetch, fetch_async, refresh (specs/07)
lib/theine/supervisor.ex      per-cache supervision tree (specs/08)
lib/theine/stats.ex           counters + stats/1 (specs/08)
bench/                        benchee scripts + trace loader; results/ and traces/ are gitignored
test/                         mirrors lib/; test/support for shared helpers
```

## Rules that keep the hot path hot

- `get/2` on a hit does exactly: one persistent_term read, one ETS lookup, one
  monotonic time read, one scheduler-id read, at most three atomics ops.
  No Logger, no telemetry, no process dictionary, no message send on a hit.
- Reads never write to ETS, except deleting an entry found expired, by exact object.
- Policy state is touched by the maintenance process only.
- Dependencies allowed in `mix.exs`: `telemetry`. Dev/test/bench only:
  `benchee`, `stream_data`, `dialyxir`, `ex_doc`, `cachex`, `nebulex`,
  `nebulex_local`.
  Anything else needs a Decisions note in `specs/00-overview.md`.

## Operational learnings

(A few lines at most. Status goes in IMPLEMENTATION_PLAN.md, not here.)

- Prefix every command with `mise exec --` when the shell has no mise activation.
- `mix gate` runs in `MIX_ENV=test` (`cli/0` preferred_envs). It runs dialyzer on
  `lib/` + `test/support`. PLTs are in `priv/plts/` (gitignored). The first
  build takes about 2.5 min per env.
- `mix bench` and its helpers live in `bench/lib`, compiled in `:dev` only. Use
  `mix bench get --sizes 1000 --warmup 0.2 --time 0.5` for a quick smoke run.
- Run the gating `mix bench get` as
  `mise exec -- env ERL_FLAGS="+sbt db +sbwt very_long" mix bench get`. The
  p99 at n=1000 tuple3 parallel=1 wanders by ±0.1× between runs of the same
  tree, flags or not, and has crossed the A1 limit three times (M1.5, M1.6).
  If that is the only failed check, re-run `--sizes 1000` on the same tree;
  a pass there clears it (specs/09 §Decisions M1.6). The full run takes
  about 12 minutes, the `--sizes 1000` run about 3.
- To cost a hit-path change before the 12-minute bench, time `Theine.get/2`
  in a compiled module (a `defmodule` in an `.exs` run with
  `mise exec -- env ERL_FLAGS=... mix run script.exs`; anonymous funs in
  `mix run -e` are interpreted). Measured there (M2.8): `:erlang.system_info(:scheduler_id)`
  7 ns, each `:atomics` op 18–25 ns, `:counters.add` 22 ns, `:persistent_term.get`
  13 ns plus ~8 ns per extra map key matched; ets lookup 220 ns; `rem/2` on
  small integers about 11 ns each (a division), `Bitwise.band/2` about 1 ns,
  so size options on a hot path should be powers of two (M2.8b). Summing
  `[:theine, :maintenance, :pass]` durations in a telemetry handler shows
  whether the maintenance process is saturated. Under readers on every
  scheduler a pass's `duration` is wall time on a shared scheduler and runs
  about 4× longer per read than with one reader (M2.8c), so compare the
  duty cycle (sum of durations / wall), not pass lengths, across loads; the
  `drain_backoff` option sets the drain-pass gap (0 = back to back).
- The reference laptop is an i5-5257U: 2 cores × 2 SMT threads, 3 MB L3.
  With `+sbt db` schedulers 1 and 3 share a core, as do 2 and 4, so
  `parallel: 4` is two readers per core and an `:atomics` op there costs
  about 65 ns, not 23. To take the SMT sibling out of a measurement run the
  probe with `ERL_FLAGS="+S 2 +sbt db +sbwt very_long"` (the two schedulers
  land on separate cores). `Theine.Maintenance.pause/1` (with `test_hooks:
  true`) is the way to measure a bounded hit with no passes running (M2.8d).
- `mix test --include stress test/stress` runs only the soak tier (about
  35 s; the whole suite with it about 41 s). Those modules are
  `async: false` because they pin a writer to every scheduler.
- Probe scripts under `bench/results/` are gitignored but still formatted
  by `mix format --check-formatted`; run `mix format` on them before the gate.
- `mix bench hitrate --traces OLTP` (about 3 min) is the quick policy check;
  `--traces loop` takes seconds. `--accesses-per-pass 1` replays like
  Caffeine's simulator, `--window-percent 1,5,20` sweeps the window. The
  full run replays DS1 at 8 M entries (about 3 GB of ETS) and, with
  `theine_static` beside `theine` (M2.13), outlasts the 2-hour cap on a
  background command: run `--traces OLTP,S3,P3,loop,zipf` (about 44 min)
  and then `--traces DS1` (about 79 min), one after the other, since each
  overwrites `hitrate-<sha>.json`. Compare hits before starting the second. Two runs must agree to the hit: compare the
  `hits` fields in the JSON, not the percentages (the harness raises if a
  pass it did not request ran).
- `mix bench maintenance` takes about 2 min at the default 1 M entries
  (two 30 s runs plus 1 M puts); `--max-size 10000 --duration 1` smokes it
  in seconds and shows the same overshoot structure. To attribute an
  overshoot, `bench/results/overshoot-m211.exs` (gitignored) samples the
  table size, the policy's `sizes` atomics and `pending` together: table =
  policy + pending + in flight tells which side the excess is on.
- A probe that pins a reader does not separate it from the maintenance
  process. The unpinned process ran every pass on the reader's scheduler at
  `+S 4` and 73–100% at `+S 2` (M2.11b). Count
  `:erlang.system_info(:scheduler_id)` in a pass telemetry handler before
  reading a "maintenance running" row. To A/B a `Policy` change in one VM,
  `bench/results/gap-m211b.exs` compiles a revision's modules from
  `git show` and runs them through `policy_module` (`GAP_BASE=HEAD`).
- Off the hit path, two costs measured in M2.11b: `%{struct | k: v}` on the
  20-field `%Theine.Policy{}` costs 55–145 ns, so fold updates into one;
  and integer arithmetic past 2^59 allocates bignums (a 32×32-bit product
  does).
- A bare `mix dialyzer` (`:dev`) also checks `bench/lib` and reports unknown
  `Mix`/`:httpc` functions there because the dev PLT lacks those apps. That
  is noise; the gate is `mix gate`, whose dialyzer run is clean.

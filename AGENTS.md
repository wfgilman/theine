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

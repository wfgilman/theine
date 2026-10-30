# 10 — Testing and quality gates

One topic: the backpressure that keeps a fresh-context build iteration
honest. The build prompt runs these; this spec says what they must contain.

## Tiers

| tier | tag | runs in | budget | purpose |
|---|---|---|---|---|
| unit | none | `mix test` | < 60 s total | one module, deterministic |
| property | none | `mix test` | included above | StreamData over data structures: sketch, read buffer, policy invariants |
| concurrency | none | `mix test` | included above | many processes, short, deterministic outcomes (exactly-once, no leaks) |
| stress | `:stress` | `mix test --include stress` | < 10 min | soak: millions of ops, kills, restarts, backpressure |
| tracing | none | `mix test` | included above | asserts the exact BIF multiset on the hot path (specs/01) |

Tests that need time use the injected clock (specs/06 §Clock), never
`Process.sleep` for correctness; `Process.sleep` is allowed only to give a
background task time to run, bounded by an `assert_eventually` helper with a
timeout in `test/support`.

Every test that starts a cache uses a unique name (`:"cache_#{System.unique_integer([:positive])}"`)
and `start_supervised!` so caches are torn down and persistent_term entries
removed.

## Required helpers (`test/support`)

- `Theine.Test.Clock`: an Agent-backed clock per cache name, with
  `now(cache)` and `advance(cache, ms)`.
- `Theine.Test.Trace`: run a function under `:erlang.trace/3` for the
  listed modules and return the multiset of `{module, function, arity}`
  calls (specs/01 tracing test).
- `Theine.Test.Policy`: an instrumented policy that records call order
  (specs/04 order test), injected via a test-only config field.
- `Theine.Test.LoaderHook`: pause points between the steps of the
  single-flight algorithm, armed per fetching process with
  `pause_at(point, notify)` and released with `resume(pid)`; compiled into
  `Theine.Loader` by the test build only (specs/07 §Decisions M4.2). Two
  refresh points; `:refresh_task` is armed in the starter, fires in its
  tasks and stays armed until `disarm(point)` (specs/07 §Decisions M4.4b).
- `assert_eventually(fun, timeout \\ 1000)`.
- `spawn_on_scheduler(n, fun)` using `spawn_opt` with `{:scheduler, n}`.

## Gates in order

1. `mix format --check-formatted`
2. `mix compile --warnings-as-errors`
3. `mix test` (with `--seed` random, as default; a flaky test is a bug, not
   a retry)
4. `mix dialyzer` (warnings are errors; the plt is cached in CI)
5. For hot-path tasks: `mix bench get` thresholds (specs/09)
6. For maintenance/policy tasks: `mix bench maintenance`, `mix bench hitrate`
7. Final gate: `mix test --include stress`, all three benches, `mix docs`
   without warnings, `mix hex.build` clean.

`mix.exs` defines the alias `gate` running 1–4 so an iteration has one
command to run before committing.

## Flakiness policy

A test that fails intermittently is fixed in the same iteration it is
observed or, if the cause is in another task, recorded in the plan as a
discovered issue with the seed that reproduces it. Never retried, never
tagged `:skip`, never loosened with a larger sleep.

## Coverage

`mix test --cover` is reported, not gated, except that `Theine.Loader` and
`Theine.Policy` must each stay at 100% line coverage because their
correctness is in the branches (claim races, admission ties, stale ids).

## Acceptance

- All helpers above exist and are used by at least one test each.
- `mix gate` exists and passes.
- The stress suite exists with at least: the exactly-once loader soak
  (specs/07), the write-event no-loss test and backpressure test (specs/03),
  the maintenance restart test (specs/04), and the overshoot test (specs/09),
  and completes under 10 minutes on the reference machine.

## Decisions

- 2026-10-27: `Theine.Test.Clock.advance/1` became `advance(cache, ms)`.
  specs/06 §Clock keys the test clock by cache name (`now/1` takes the
  cache), so advancing needs the cache too; one global clock would couple
  async tests. Caches with no registered clock fall back to real time.
- 2026-10-28 (M2.7): `Theine.Test.Policy` is injected with the
  `start_link` option `policy_module`, accepted only with `test_hooks:
  true` (specs/08 §Decisions M2.7). It records by sending each call's name
  to the process that called `listen(cache)`; `calls(cache)` drains them
  from the caller's mailbox in order.
- 2026-10-29 (M2.9): `Theine.Test.Policy` also forwards `restore/5` and
  offers `gate(cache, call)` / `release(cache, pid)`: the maintenance
  process stops inside its next call of that name, tells the gate process
  `{Theine.Test.Policy, cache, :gated, call, pid}`, and waits for the
  release. The gate is removed before the process is told, so exactly one
  call is held. This is what makes "a put during the rebuild is not lost"
  (specs/04 §Restart semantics) deterministic.
- 2026-10-27: `Theine.Test.Trace` uses an OTP 27 `:trace` session instead
  of global `:erlang.trace/3` + `trace_pattern/3`, so concurrent async
  tracing tests cannot see or reset each other's patterns. The call
  messages are the same; the result is `%{{m, f, a} => count}`.

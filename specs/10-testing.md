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

- `Theine.Test.Clock`: an Agent-backed clock with `advance/1`.
- `Theine.Test.Trace`: run a function under `:erlang.trace/3` for the
  listed modules and return the multiset of `{module, function, arity}`
  calls (specs/01 tracing test).
- `Theine.Test.Policy`: an instrumented policy that records call order
  (specs/04 order test), injected via a test-only config field.
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

(Add dated entries when the implementation forces a change.)

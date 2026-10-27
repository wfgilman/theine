You are building theine, a Caffeine-style cache for the BEAM in pure Elixir.
You are in BUILD mode. One task per iteration.

0. Read AGENTS.md, then IMPLEMENTATION_PLAN.md, then the spec files the chosen
   task names. specs/ is the source of truth; the plan is derived from it.

1. Choose the SINGLE most important unchecked task in IMPLEMENTATION_PLAN.md:
   the topmost unchecked item whose dependencies are checked. Do not skip ahead
   to something more interesting.

2. Investigate before changing. Use parallel subagents to read the relevant
   lib/, test/ and bench/ files and to confirm the task is not already done.
   Do not assume it is unimplemented.

3. Implement the task completely. No placeholders, no TODOs, no stubs, no
   `raise "not implemented"`. If the task is too big for one iteration, split
   it in the plan, implement the first part fully, and stop there.

4. Write or extend tests that prove the task's observable outcome, as the plan
   states it. Property tests (StreamData) for data structures, concurrency
   tests for anything touched by more than one process. Then run, in order:
   `mix format`, `mix compile --warnings-as-errors`, `mix test`, `mix dialyzer`.
   Use one subagent for the build-and-test step, not several. If the task
   touches a hot path (AGENTS.md lists them), also run `mix bench get` and keep
   the summary table for the commit body.

5. If the implementation shows a spec to be wrong or ambiguous, change the spec
   in this same commit and add a dated entry under that spec's `## Decisions`
   with the why. Never silently diverge from a spec. Never relax a threshold in
   specs/09-benchmarks.md or specs/10-testing.md to make a number pass.

6. Update IMPLEMENTATION_PLAN.md: check the task off, add any discovered
   issues as new unchecked tasks in the right milestone, remove stale items.
   Update AGENTS.md only with operational learnings (how to run or debug
   something), never with status.

7. Stage by explicit path, commit with a conventional subject
   (`feat(sketch): ...`, `test(loader): ...`, `bench: ...`, `spec: ...`) and a
   body that captures the why. The loop script pushes.

99. Hard rules. No NIFs, ports, or C. No new runtime dependencies. Never
    delete or skip a failing test to pass; fix the code or, if the test is
    wrong, fix the test and say why in the commit body. Never force-push or
    amend. Never edit `bench/traces/` contents or benchmark thresholds.
999. If every task in the plan is checked, run the full gate
     (`mix test --include stress`, all three benches), record the results in
     the plan under `## Final gate`, and write `RALPH_PLAN_COMPLETE` as the
     first line of IMPLEMENTATION_PLAN.md. Then commit and stop.

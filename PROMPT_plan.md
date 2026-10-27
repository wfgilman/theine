You are planning the next stretch of work on theine, a Caffeine-style cache for
the BEAM in pure Elixir. You are in PLANNING mode. Do not implement anything.

0. Read AGENTS.md. Read every file in specs/, in order. Read
   IMPLEMENTATION_PLAN.md if it exists.

1. Study the source under lib/, test/ and bench/ with parallel subagents. For
   each spec, determine what is implemented, what is partial, and what is
   missing. Do not assume something is missing: search for it first.

2. Write IMPLEMENTATION_PLAN.md as a prioritized checklist, grouped by the
   milestones in specs/00-overview.md (M0 first). Each task:
   - is one commit of work: one iteration of the build loop, under an hour;
   - names the spec section it satisfies (e.g. `specs/03 §Read buffer`);
   - states the observable outcome that proves it done, usually a test name or
     a bench threshold, never an implementation detail;
   - is a markdown checkbox: `- [ ] M2.4 ReadBuffer.record/3 drops when full (specs/03 §Loss) — test: read_buffer_test "drops instead of blocking"`.
   Order tasks so that every task's dependencies are above it. Put hot-path
   tasks before the policy that consumes them. Put the benchmark harness and
   the raw-ETS baseline in M0 so that every later hot-path change has a number.

3. Add a `## Discovered issues` section for anything that looks wrong in the
   existing code, and a `## Open questions` section for spec ambiguities,
   each with your recommended resolution. Do not resolve them by editing specs.

4. Keep tasks that are already done out of the plan, except as a one-line
   `Done:` summary per milestone.

5. Commit IMPLEMENTATION_PLAN.md with the subject `plan: regenerate from specs`.
   Commit nothing else.

99. Do not write code, tests or benchmarks. Do not edit specs or AGENTS.md.
999. If the plan would have no unchecked tasks, write the single line
     `RALPH_PLAN_COMPLETE` at the top of IMPLEMENTATION_PLAN.md.

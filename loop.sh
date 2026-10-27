#!/usr/bin/env bash
# Ralph loop for theine.
#
#   ./loop.sh plan [max_iterations]   regenerate IMPLEMENTATION_PLAN.md from specs/ and src/
#   ./loop.sh [max_iterations]        build: one task per iteration until the plan is done
#
# Each iteration is a fresh `claude -p` session. State between iterations lives
# only in the filesystem: git history, IMPLEMENTATION_PLAN.md, AGENTS.md, specs/.
#
# Permissions: `claude -p` is non-interactive, so any tool call that would
# prompt is DENIED, and an iteration that cannot write or commit spins until
# it gives up. The allowlist in .claude/settings.json grants exactly what the
# prompts need (file edits inside the repo, mix, git add/commit, read-only
# shell). Anything beyond that is your call: wrap this in a sandbox (as
# prospector-loop does with sandbox-exec) or pass flags through CLAUDE_FLAGS.
#   CLAUDE_FLAGS="--dangerously-skip-permissions" ./loop.sh 20   # sandboxed hosts only
set -euo pipefail
cd "$(dirname "$0")"

MODE=build
MAX=0
if [[ "${1:-}" == "plan" ]]; then MODE=plan; MAX=1; shift; fi   # plan mode runs once unless told otherwise
if [[ -n "${1:-}" ]]; then MAX="$1"; fi

PROMPT_FILE="PROMPT_build.md"
[[ "$MODE" == "plan" ]] && PROMPT_FILE="PROMPT_plan.md"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:-}"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

i=0
while :; do
  i=$((i + 1))
  echo "=== theine $MODE iteration $i ($(date -u +%FT%TZ)) ==="
  # shellcheck disable=SC2086
  cat "$PROMPT_FILE" | "$CLAUDE_BIN" -p $CLAUDE_FLAGS --output-format text \
    || echo "iteration $i exited non-zero; continuing"

  if git remote get-url origin >/dev/null 2>&1; then
    git push origin "$BRANCH" 2>/dev/null || git push -u origin "$BRANCH" || true
  fi

  if [[ "$MODE" == "build" ]] && grep -q "RALPH_PLAN_COMPLETE" IMPLEMENTATION_PLAN.md 2>/dev/null; then
    echo "plan complete; stopping"; break
  fi
  if [[ "$MAX" -gt 0 && "$i" -ge "$MAX" ]]; then echo "max iterations reached"; break; fi
done

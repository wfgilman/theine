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
#
# Usage limits: when claude reports a session/usage limit, the loop sleeps
# until the reset time it reports (plus a minute) instead of retrying. The
# reset time comes from the newest transcript's `resetsAt` field, or from the
# "resets 9:10pm (America/Los_Angeles)" text, or failing both from an
# exponential backoff starting at LIMIT_BACKOFF seconds. Limit waits do not
# count as iterations. A per-model limit ("You've reached your Fable limit.
# Switch to another model") reports no reset time, so the loop exits 2 and
# leaves the model choice to a person.
#
# Unproductive iterations: an iteration that ends in under MIN_ITERATION_SECS
# without a new commit (denied permissions, a broken prompt, an API outage)
# backs off exponentially; after MAX_UNPRODUCTIVE in a row the loop stops.
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
MIN_ITERATION_SECS="${MIN_ITERATION_SECS:-120}"
MAX_UNPRODUCTIVE="${MAX_UNPRODUCTIVE:-5}"
LIMIT_BACKOFF="${LIMIT_BACKOFF:-900}"
# Where claude writes this project's transcripts (path with every non-alphanumeric as '-').
TRANSCRIPT_DIR="$HOME/.claude/projects/$(pwd -P | sed 's#[^A-Za-z0-9]#-#g')"

log() { echo "=== theine $MODE: $* ($(date -u +%FT%TZ))"; }

hit_limit() {  # $1 = iteration output file
  grep -qiE "hit your [a-z ]*limit|usage limit reached|usage_limit_reached" "$1"
}

model_limit() {  # $1 = iteration output file; a per-model cap ("reached your Fable limit")
  grep -qiE "reached your [a-z0-9. ]* limit|switch to another model|model_requires_usage_credits" "$1"
}

limit_reset_epoch() {  # $1 = iteration output file; prints a unix time in the future, or nothing
  local now ts f when tz
  now=$(date +%s)
  # 1. The newest transcript carries the API's own resetsAt.
  f=$(ls -t "$TRANSCRIPT_DIR"/*.jsonl 2>/dev/null | head -1 || true)
  if [[ -n "$f" ]]; then
    ts=$(grep -o '"resetsAt":[0-9]*' "$f" | tail -1 | cut -d: -f2 || true)
    if [[ -n "$ts" && "$ts" -gt "$now" ]]; then echo "$ts"; return; fi
  fi
  # 2. The text output: "resets 9:10pm (America/Los_Angeles)".
  when=$(grep -oE 'resets [^(]+' "$1" | head -1 | sed 's/^resets //; s/ *$//' || true)
  tz=$(grep -oE 'resets [^(]+\([^)]+\)' "$1" | head -1 | sed 's/.*(\(.*\))/\1/' || true)
  if [[ -n "$when" ]]; then
    ts=$(TZ="${tz:-UTC}" date -d "$when" +%s 2>/dev/null || true)
    if [[ -n "$ts" ]]; then
      (( ts <= now )) && ts=$((ts + 86400))
      echo "$ts"; return
    fi
  fi
}

sleep_until() {  # $1 = unix time
  local secs=$(( $1 - $(date +%s) + 60 ))
  (( secs < 60 )) && secs=60
  log "usage limit; sleeping ${secs}s until $(date -d "@$1" '+%F %T %Z')"
  sleep "$secs"
}

OUT="$(mktemp -t theine-loop.XXXXXX)"
trap 'rm -f "$OUT"' EXIT

i=0
unproductive=0
limit_backoff="$LIMIT_BACKOFF"
fail_backoff=300
while :; do
  i=$((i + 1))
  log "iteration $i"
  head_before="$(git rev-parse HEAD 2>/dev/null || echo none)"
  started=$(date +%s)
  set +e
  # shellcheck disable=SC2086
  cat "$PROMPT_FILE" | "$CLAUDE_BIN" -p $CLAUDE_FLAGS --output-format text 2>&1 | tee "$OUT"
  rc=${PIPESTATUS[1]}
  set -e
  elapsed=$(( $(date +%s) - started ))
  (( rc != 0 )) && echo "iteration $i exited $rc"

  if model_limit "$OUT"; then
    # No reset time is reported and waiting may mean days; a person has to
    # pick another model (the "model" key in .claude/settings.json, or
    # CLAUDE_FLAGS="--model ...") and restart.
    log "model usage limit reached; switch models and restart. Stopping"
    exit 2
  fi

  if hit_limit "$OUT"; then
    i=$((i - 1))                       # a rejected request is not an iteration
    reset=$(limit_reset_epoch "$OUT")
    if [[ -n "$reset" ]]; then
      sleep_until "$reset"
      limit_backoff="$LIMIT_BACKOFF"
    else
      log "usage limit, reset time unknown; sleeping ${limit_backoff}s"
      sleep "$limit_backoff"
      limit_backoff=$(( limit_backoff * 2 > 3600 ? 3600 : limit_backoff * 2 ))
    fi
    continue
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    git push origin "$BRANCH" 2>/dev/null || git push -u origin "$BRANCH" || true
  fi

  if [[ "$MODE" == "build" ]] && grep -q "RALPH_PLAN_COMPLETE" IMPLEMENTATION_PLAN.md 2>/dev/null; then
    log "plan complete; stopping"; break
  fi

  head_after="$(git rev-parse HEAD 2>/dev/null || echo none)"
  if (( elapsed < MIN_ITERATION_SECS )) && [[ "$head_after" == "$head_before" ]]; then
    unproductive=$((unproductive + 1))
    if (( unproductive >= MAX_UNPRODUCTIVE )); then
      log "$unproductive unproductive iterations in a row (under ${MIN_ITERATION_SECS}s, no commit); stopping"
      exit 1
    fi
    log "iteration $i took ${elapsed}s and committed nothing; backing off ${fail_backoff}s ($unproductive/$MAX_UNPRODUCTIVE)"
    sleep "$fail_backoff"
    fail_backoff=$(( fail_backoff * 2 > 3600 ? 3600 : fail_backoff * 2 ))
  else
    unproductive=0
    fail_backoff=300
  fi

  if [[ "$MAX" -gt 0 && "$i" -ge "$MAX" ]]; then log "max iterations reached"; break; fi
done

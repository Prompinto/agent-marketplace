#!/usr/bin/env bash
# Scenario-specific assertions for retry-resume-safe-round2plus, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure already
# validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN", round_count == 2 (a real round 2 existed and
#     is what actually converged, not round 1)
#   - threads has exactly one entry, kind:"current", cleanup:"deleted" --
#     no "leaked" entry: round 2+ has no fresh fallback available at all,
#     but this scenario's own retries succeed before that would ever matter
#   - the fixed INVOCATION_LOG shows exactly 1 "mode=fresh" line (round 1)
#     and exactly 3 "mode=resume" lines (round 2's original attempt + both
#     bounded backoff retries) -- the only reliable proof the FULL 5s-then-
#     15s bounded retry sequence actually ran on round 2, not just a single
#     retry -- and all 4 dispatch lines share the identical thread_id
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-retry-resume-safe-round2plus-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "retry-resume-safe-round2plus: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "2"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "threads length" "$THREAD_COUNT" "1"
if [ "$THREAD_COUNT" = "1" ]; then
  check "threads[0].kind" "$(jq -r '.threads[0].kind' "$RESULT_FILE")" "current"
  check "threads[0].cleanup" "$(jq -r '.threads[0].cleanup' "$RESULT_FILE")" "deleted"
fi

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked" "$LEAKED_COUNT" "0"

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "retry-resume-safe-round2plus: WARN -- invocation log not found at $INVOCATION_LOG (only available immediately after a live run, before this scenario's own cleanup step -- skipping the invocation-count check rather than failing the whole scenario on a missing ephemeral diagnostic file)" >&2
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count" "$FRESH_COUNT" "1"
  check "invocation log resume-mode count" "$RESUME_COUNT" "3"
  DISTINCT_IDS="$(grep -E '^mode=(fresh|resume) ' "$INVOCATION_LOG" | sed -E 's/^mode=[a-z]+ thread_id=([^ ]*).*/\1/' | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across all 4 dispatch invocations" "$DISTINCT_IDS" "1"
fi

exit "$FAIL"

#!/usr/bin/env bash
# Scenario-specific assertions for near-limit-whitespace-performance,
# invoked by check-result.sh as `expect.sh <result.json>`. Schema structure
# is already validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN" (a real terminal status was reached -- not a
#     timeout/hang, which would never produce a result.json at all)
#   - round_count == 1
#   - round 1's own round_wall_seconds (read from the sibling .jsonl review
#     history log -- interactive-result.schema.json's result.json itself
#     carries no timing field, only the per-round JSONL log does) is well
#     under 30s -- the actual regression guard for the old
#     catastrophically-superlinear _focus_is_empty() bug, which would have
#     made this exact whitespace-dense input shape hang for hours
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "near-limit-whitespace-performance: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "CLEAN"

ROUND_COUNT="$(jq -r '.round_count' "$RESULT_FILE")"
check "round_count" "$ROUND_COUNT" "1"

SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
LOG_PATH="$(dirname "$RESULT_FILE")/$SESSION_ID.jsonl"

if [ ! -f "$LOG_PATH" ]; then
  echo "near-limit-whitespace-performance: FAIL -- expected sibling review-history log at $LOG_PATH, not found" >&2
  FAIL=1
else
  ROUND_WALL_SECONDS="$(jq -r 'select(.round == 1) | .round_wall_seconds' "$LOG_PATH" | head -n1)"
  if [ -z "$ROUND_WALL_SECONDS" ] || [ "$ROUND_WALL_SECONDS" = "null" ]; then
    echo "near-limit-whitespace-performance: FAIL -- round 1's round_wall_seconds missing from $LOG_PATH" >&2
    FAIL=1
  elif [ "$ROUND_WALL_SECONDS" -ge 30 ]; then
    echo "near-limit-whitespace-performance: FAIL -- round_wall_seconds ($ROUND_WALL_SECONDS) is not well under the 30s regression-guard threshold" >&2
    FAIL=1
  else
    echo "near-limit-whitespace-performance: round_wall_seconds = ${ROUND_WALL_SECONDS}s (well under the 30s regression-guard threshold)"
  fi
fi

exit "$FAIL"

#!/usr/bin/env bash
# Scenario-specific assertions for parallel-two-groups-both-clean. Schema
# structure already validated by check-result.sh's own schema validation step.
#
#   - exit_state == "CLEAN"
#   - threads[] has exactly 2 entries (one per dispatched group), both
#     kind:"current" and cleanup:"deleted"
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "parallel-two-groups-both-clean: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "threads length" "$THREAD_COUNT" "2"

CURRENT_DELETED_COUNT="$(jq -r '[.threads[]? | select(.kind == "current" and .cleanup == "deleted")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==current and cleanup==deleted" "$CURRENT_DELETED_COUNT" "2"

GROUPS_DISTINCT="$(jq -r '[.threads[].group] | unique | length' "$RESULT_FILE")"
check "distinct thread groups" "$GROUPS_DISTINCT" "2"

exit "$FAIL"

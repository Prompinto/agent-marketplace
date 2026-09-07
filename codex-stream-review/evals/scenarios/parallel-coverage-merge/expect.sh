#!/usr/bin/env bash
# Scenario-specific assertions for parallel-coverage-merge. Schema structure
# (target.scope=="uncommitted" requires coverage to be an object) already
# validated by check-result.sh's schema-check.jq.
#
#   - exit_state == "PARTIAL_COVERAGE" (worst-case-wins: one group's real
#     "partial" outcome forces the merged coverage below CLEAN eligibility
#     even though both groups' own verdicts were individually clean)
#   - coverage.status == "partial"
#   - threads[] has exactly 2 entries, both cleanup:"deleted"
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "parallel-coverage-merge: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "PARTIAL_COVERAGE"
check "coverage.status" "$(jq -r '.coverage.status' "$RESULT_FILE")" "partial"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "threads length" "$THREAD_COUNT" "2"

NOT_DELETED_COUNT="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
check "count of threads[] not cleanup==deleted" "$NOT_DELETED_COUNT" "0"

exit "$FAIL"

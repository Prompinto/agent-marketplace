#!/usr/bin/env bash
# Scenario-specific assertions for partial-coverage, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure (coverage
# must be an object for target.scope:"uncommitted") is already validated by
# check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "PARTIAL_COVERAGE"
#   - round_count == 1 (the coverage gap is detected on round 1's own
#     dispatch -- no retry loop is needed to reach this outcome)
#   - coverage.status == "partial"
#   - coverage.omitted is non-empty and names the deliberately oversized
#     untracked file with the real collector-reported reason (confirms the
#     omission was genuinely derived by collect_untracked_files.py /
#     run-ccs-review.sh, not asserted by this scenario itself)
#   - claims == [] (no findings were ever raised this run)
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "partial-coverage: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "PARTIAL_COVERAGE"

ROUND_COUNT="$(jq -r '.round_count' "$RESULT_FILE")"
check "round_count" "$ROUND_COUNT" "1"

COVERAGE_STATUS="$(jq -r '.coverage.status' "$RESULT_FILE")"
check "coverage.status" "$COVERAGE_STATUS" "partial"

OMITTED_COUNT="$(jq -r '.coverage.omitted | length' "$RESULT_FILE")"
if [ "$OMITTED_COUNT" -lt 1 ]; then
  echo "partial-coverage: FAIL -- coverage.omitted: expected a non-empty array, got length $OMITTED_COUNT" >&2
  FAIL=1
fi

OMITTED_MATCH="$(jq -r '[.coverage.omitted[]? | select(.path == "oversized-untracked.bin")] | length' "$RESULT_FILE")"
if [ "$OMITTED_MATCH" -lt 1 ]; then
  echo "partial-coverage: FAIL -- expected coverage.omitted to name oversized-untracked.bin, got:" >&2
  jq -c '.coverage.omitted' "$RESULT_FILE" >&2
  FAIL=1
fi

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "0"

exit "$FAIL"

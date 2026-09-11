#!/usr/bin/env bash
# Scenario-specific assertions for claim-oscillation-nonconsecutive. Schema
# structure already validated by check-result.sh's own schema validation step.
#
#   - exit_state == "NOT_CONVERGED" (the oscillation guard fired at round 3,
#     catching a non-consecutive recurrence -- round 1 raise, silent round
#     2, reasserted-with-no-new-evidence round 3 -- that the OLD
#     adjacent-rounds-only guard this replaced would have missed)
#   - round_count == 3
#   - claims[] has exactly one entry: claim_id "f1", disposition "open"
#     (never closed -- no DISPOSITION marker was ever answered in this
#     transcript)
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "claim-oscillation-nonconsecutive: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "NOT_CONVERGED"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "3"

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "1"

if [ "$CLAIMS_COUNT" = "1" ]; then
  check "claims[0].claim_id" "$(jq -r '.claims[0].claim_id' "$RESULT_FILE")" "f1"
  check "claims[0].disposition" "$(jq -r '.claims[0].disposition' "$RESULT_FILE")" "open"
fi

exit "$FAIL"

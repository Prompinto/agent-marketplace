#!/usr/bin/env bash
# Scenario-specific assertions for claim-clean-resolution. Schema structure
# (claims must be an array; each claim entry's required keys) is already
# validated by check-result.sh's own schema validation step before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN"
#   - round_count == 2 (round 1 raises f1, round 2's DISPOSITION marker
#     resolves it -- no third round ever needed)
#   - claims[] has exactly one entry: claim_id "f1", disposition "resolved",
#     source_round 2 (the round whose own DISPOSITION marker closed it)
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "claim-clean-resolution: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "2"

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "1"

if [ "$CLAIMS_COUNT" = "1" ]; then
  check "claims[0].claim_id" "$(jq -r '.claims[0].claim_id' "$RESULT_FILE")" "f1"
  check "claims[0].disposition" "$(jq -r '.claims[0].disposition' "$RESULT_FILE")" "resolved"
  check "claims[0].source_round" "$(jq -r '.claims[0].source_round' "$RESULT_FILE")" "2"
fi

exit "$FAIL"

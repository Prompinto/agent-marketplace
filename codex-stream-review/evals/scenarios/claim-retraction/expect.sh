#!/usr/bin/env bash
# Scenario-specific assertions for claim-retraction. Schema structure already
# validated by check-result.sh's schema-check.jq before this runs.
#
#   - exit_state == "CLEAN"
#   - round_count == 3 (see setup.sh's header comment for why this is 3
#     rounds, not 2 -- claim-ledger.md's "When to ask" rule cannot justify a
#     disposition request until round 3's own focus construction)
#   - claims[] has exactly one entry: claim_id "f1", disposition "retracted",
#     source_round 3
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "claim-retraction: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "3"

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "1"

if [ "$CLAIMS_COUNT" = "1" ]; then
  check "claims[0].claim_id" "$(jq -r '.claims[0].claim_id' "$RESULT_FILE")" "f1"
  check "claims[0].disposition" "$(jq -r '.claims[0].disposition' "$RESULT_FILE")" "retracted"
  check "claims[0].source_round" "$(jq -r '.claims[0].source_round' "$RESULT_FILE")" "3"
fi

exit "$FAIL"

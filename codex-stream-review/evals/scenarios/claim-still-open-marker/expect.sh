#!/usr/bin/env bash
# Scenario-specific assertions for claim-still-open-marker. Schema structure
# already validated by check-result.sh's own schema validation step.
#
#   - exit_state != "CLEAN" (a STILL OPEN marker never converges a claim to
#     CLEAN on its own)
#   - claims[] has exactly one entry: claim_id "f1", disposition "open"
#     (never "resolved" -- confirms STILL OPEN produces no claim_closures[]
#     entry, per claim-ledger.md section 4)
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "claim-still-open-marker: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
if [ "$EXIT_STATE" = "CLEAN" ]; then
  echo "claim-still-open-marker: FAIL -- exit_state: expected anything but CLEAN, got CLEAN" >&2
  FAIL=1
fi

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "1"

if [ "$CLAIMS_COUNT" = "1" ]; then
  check "claims[0].claim_id" "$(jq -r '.claims[0].claim_id' "$RESULT_FILE")" "f1"
  check "claims[0].disposition" "$(jq -r '.claims[0].disposition' "$RESULT_FILE")" "open"
fi

exit "$FAIL"

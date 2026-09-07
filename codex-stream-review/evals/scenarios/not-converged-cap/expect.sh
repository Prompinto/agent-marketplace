#!/usr/bin/env bash
# Scenario-specific assertions for not-converged-cap, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure (claims
# must be an array for this exit_state) is already validated by
# check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "NOT_CONVERGED"
#   - round_count == 20 (the cap was genuinely hit, not an early oscillation-
#     guard stop, which would report the same exit_state at a LOWER round
#     count -- this is the one assertion that structurally distinguishes
#     "ran the full 20 rounds" from "gave up early for the same reason")
#   - exactly one claim, claim_id "f1", disposition "open" (never closed --
#     no DISPOSITION marker was ever requested for an actively-disputed,
#     currently-appearing finding)
#   - at least one thread, every thread cleanup == "deleted"
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "not-converged-cap: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "NOT_CONVERGED"

ROUND_COUNT="$(jq -r '.round_count' "$RESULT_FILE")"
check "round_count" "$ROUND_COUNT" "20"

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "1"

if [ "$CLAIMS_COUNT" = "1" ]; then
  check "claims[0].claim_id" "$(jq -r '.claims[0].claim_id' "$RESULT_FILE")" "f1"
  check "claims[0].disposition" "$(jq -r '.claims[0].disposition' "$RESULT_FILE")" "open"
fi

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
if [ "$THREAD_COUNT" -lt 1 ]; then
  echo "not-converged-cap: FAIL -- expected at least one thread, got $THREAD_COUNT" >&2
  FAIL=1
fi

NOT_DELETED_COUNT="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED_COUNT" -ne 0 ]; then
  echo "not-converged-cap: FAIL -- expected every threads[] entry to have cleanup==deleted, found $NOT_DELETED_COUNT that don't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

exit "$FAIL"

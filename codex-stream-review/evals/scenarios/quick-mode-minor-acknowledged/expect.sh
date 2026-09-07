#!/usr/bin/env bash
# Scenario-specific assertions for quick-mode-minor-acknowledged, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure (claims must be an
# array for this exit_state) is already validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "MINOR_ISSUES_ACKNOWLEDGED"
#   - round_count == 5 (the quick-mode cap, reached without ever escalating)
#   - exactly one claim, claim_id "f1", disposition "open" (never closed -- no DISPOSITION
#     marker was ever requested for an actively-disputed, currently-appearing finding)
#   - at least one thread, every thread cleanup == "deleted"
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "quick-mode-minor-acknowledged: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "MINOR_ISSUES_ACKNOWLEDGED"

ROUND_COUNT="$(jq -r '.round_count' "$RESULT_FILE")"
check "round_count" "$ROUND_COUNT" "5"

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "1"

if [ "$CLAIMS_COUNT" = "1" ]; then
  check "claims[0].claim_id" "$(jq -r '.claims[0].claim_id' "$RESULT_FILE")" "f1"
  check "claims[0].disposition" "$(jq -r '.claims[0].disposition' "$RESULT_FILE")" "open"
  check "claims[0].severity" "$(jq -r '.claims[0].severity' "$RESULT_FILE")" "medium"
fi

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
if [ "$THREAD_COUNT" -lt 1 ]; then
  echo "quick-mode-minor-acknowledged: FAIL -- expected at least one thread, got $THREAD_COUNT" >&2
  FAIL=1
fi

NOT_DELETED_COUNT="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED_COUNT" -ne 0 ]; then
  echo "quick-mode-minor-acknowledged: FAIL -- expected every threads[] entry to have cleanup==deleted, found $NOT_DELETED_COUNT that don't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

exit "$FAIL"

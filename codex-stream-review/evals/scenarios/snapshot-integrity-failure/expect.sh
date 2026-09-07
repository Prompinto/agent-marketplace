#!/usr/bin/env bash
# Scenario-specific assertions for snapshot-integrity-failure, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure (claims
# must be null, input_errors must be null, for this exit_state) is already
# validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "SNAPSHOT_INTEGRITY_FAILURE"
#   - claims == null (re-asserted here even though schema-check.jq already
#     enforces it, so this file fails loudly and specifically on its own)
#   - round_count == 1 (only round 1 ever completed and was durably logged;
#     round 2 was short-circuited before it could ever append anything)
#   - at least one thread, every thread cleanup == "deleted" -- confirms the
#     unconditional Phase 3 cleanup rule ran even though --keep-evidence was
#     never used this session
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "snapshot-integrity-failure: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "SNAPSHOT_INTEGRITY_FAILURE"

CLAIMS="$(jq -r '.claims' "$RESULT_FILE")"
check "claims" "$CLAIMS" "null"

ROUND_COUNT="$(jq -r '.round_count' "$RESULT_FILE")"
check "round_count" "$ROUND_COUNT" "1"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
if [ "$THREAD_COUNT" -lt 1 ]; then
  echo "snapshot-integrity-failure: FAIL -- expected at least one thread, got $THREAD_COUNT" >&2
  FAIL=1
fi

NOT_DELETED_COUNT="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED_COUNT" -ne 0 ]; then
  echo "snapshot-integrity-failure: FAIL -- expected every threads[] entry to have cleanup==deleted, found $NOT_DELETED_COUNT that don't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

exit "$FAIL"

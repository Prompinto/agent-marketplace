#!/usr/bin/env bash
# Scenario-specific assertions for parallel-live-acceptance. Schema structure already validated
# by check-result.sh's own schema validation step.
#
# This is a REAL Codex judgment scenario -- no exact round count or wording is asserted (per this
# task's own instructions). Asserts only:
#   - exit_state is a genuine SEMANTIC terminal state (CLEAN or NOT_CONVERGED) -- explicitly FAILS
#     if exit_state is COULD_NOT_VERIFY, PARTIAL_COVERAGE, or either integrity-failure state
#     (those mean the scenario itself broke operationally, not that it validated real judgment)
#   - threads[] has exactly 2 entries (both groups actually dispatched), all cleanup:"deleted"
#     (real Codex threads were genuinely created and genuinely deleted)
#   - claims[] is non-empty (the two real, deliberately-planted defects were genuinely found and
#     tracked -- an empty claims array here would mean Codex never engaged with the material at
#     all, which is itself a failure for this scenario's purpose)
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"

case "$EXIT_STATE" in
  CLEAN|NOT_CONVERGED)
    echo "parallel-live-acceptance: exit_state=$EXIT_STATE -- a genuine semantic terminal state, OK"
    ;;
  *)
    echo "parallel-live-acceptance: FAIL -- exit_state=$EXIT_STATE is an operational-failure state (or unexpected), not a real semantic judgment outcome" >&2
    FAIL=1
    ;;
esac

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
if [ "$THREAD_COUNT" -ne 2 ]; then
  echo "parallel-live-acceptance: FAIL -- expected exactly 2 threads (one per group), got $THREAD_COUNT" >&2
  FAIL=1
fi

NOT_DELETED_COUNT="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED_COUNT" -ne 0 ]; then
  echo "parallel-live-acceptance: FAIL -- expected every real Codex thread cleaned up (cleanup==deleted), found $NOT_DELETED_COUNT that aren't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
if [ "$CLAIMS_COUNT" -lt 1 ]; then
  echo "parallel-live-acceptance: FAIL -- expected at least one real claim tracked (the two planted defects), got $CLAIMS_COUNT" >&2
  FAIL=1
fi

exit "$FAIL"

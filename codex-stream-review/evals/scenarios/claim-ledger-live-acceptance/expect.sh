#!/usr/bin/env bash
# Scenario-specific assertions for claim-ledger-live-acceptance. Schema structure already
# validated by check-result.sh's own schema validation step.
#
# This is a REAL Codex judgment scenario -- no exact round count or wording is asserted. Asserts:
#   - exit_state is a genuine SEMANTIC terminal state (CLEAN or NOT_CONVERGED) -- explicitly FAILS
#     on COULD_NOT_VERIFY, PARTIAL_COVERAGE, or either integrity-failure state
#   - threads[] has exactly 1 entry (single-reviewer), cleanup:"deleted" (a real thread, really
#     cleaned up)
#   - claims[] is non-empty (the one planted defect was genuinely found and tracked)
#   - if exit_state is CLEAN, the claim reached a real terminal disposition (resolved/retracted)
#     -- CLEAN with an unresolved claim would be a contradiction the schema itself guards against
#     less directly, so this is re-asserted here explicitly for this scenario's own purpose
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"

case "$EXIT_STATE" in
  CLEAN|NOT_CONVERGED)
    echo "claim-ledger-live-acceptance: exit_state=$EXIT_STATE -- a genuine semantic terminal state, OK"
    ;;
  *)
    echo "claim-ledger-live-acceptance: FAIL -- exit_state=$EXIT_STATE is an operational-failure state (or unexpected), not a real semantic judgment outcome" >&2
    FAIL=1
    ;;
esac

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
if [ "$THREAD_COUNT" -ne 1 ]; then
  echo "claim-ledger-live-acceptance: FAIL -- expected exactly 1 thread (single-reviewer), got $THREAD_COUNT" >&2
  FAIL=1
fi

NOT_DELETED_COUNT="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED_COUNT" -ne 0 ]; then
  echo "claim-ledger-live-acceptance: FAIL -- expected the real Codex thread cleaned up (cleanup==deleted), found $NOT_DELETED_COUNT that aren't" >&2
  FAIL=1
fi

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
if [ "$CLAIMS_COUNT" -lt 1 ]; then
  echo "claim-ledger-live-acceptance: FAIL -- expected at least one real claim tracked (the planted defect), got $CLAIMS_COUNT" >&2
  FAIL=1
fi

if [ "$EXIT_STATE" = "CLEAN" ]; then
  UNRESOLVED_COUNT="$(jq -r '[.claims[]? | select(.disposition != "resolved" and .disposition != "retracted")] | length' "$RESULT_FILE")"
  if [ "$UNRESOLVED_COUNT" -ne 0 ]; then
    echo "claim-ledger-live-acceptance: FAIL -- exit_state CLEAN but $UNRESOLVED_COUNT claim(s) never reached a terminal disposition" >&2
    FAIL=1
  fi
fi

exit "$FAIL"

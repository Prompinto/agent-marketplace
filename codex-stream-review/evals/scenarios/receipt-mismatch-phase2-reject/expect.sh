#!/usr/bin/env bash
# Scenario-specific assertions for receipt-mismatch-phase2-reject, invoked
# by check-result.sh as `expect.sh <result.json>`. Schema structure already
# validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN", round_count == 1 (the restart occupies round 1's own single slot --
#     the hollow attempt never produced a valid round-1 result)
#   - threads contains exactly one "leaked" entry (the abandoned hollow thread) AND exactly one
#     "current" entry (the fresh restart's own new thread) -- BOTH cleanup=="deleted"
#   - the leaked and current thread_id values are DIFFERENT (the restart genuinely obtained a NEW
#     threadId, never reused the abandoned one)
#   - claims == [] (the hollow response's own fabricated finding never entered the claim ledger --
#     the whole response was rejected wholesale by Phase 2 step 1's receipt check before ever being
#     processed, never parsed as a real verdict)
#   - the fixed INVOCATION_LOG shows exactly 2 "mode=fresh" lines (two DIFFERENT thread_id values)
#     and exactly ZERO "mode=resume" lines -- proof the abandoned thread was never --resume'd
#     (a missing log FAILS this scenario -- it exists specifically to prove this)
#   - the invocation log's two "mode=fresh" lines both carry scenario=normal, never
#     scenario=schema_mismatch -- proof BOTH dispatches were accepted ok:true at the wrapper level
#     (this scenario's central distinction from material-reviewed-false-never-resumed, whose round
#     1 was instead rejected as schema_mismatch by the wrapper itself)
#   - the FIRST "mode=fresh" thread_id equals the artifact's "leaked" thread_id, and the SECOND
#     equals the "current" thread_id (same linkage convention as
#     material-reviewed-false-never-resumed/expect.sh)
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-receipt-mismatch-phase2-reject-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "receipt-mismatch-phase2-reject: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "1"
check "claims" "$(jq -c '.claims' "$RESULT_FILE")" "[]"

CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==current" "$CURRENT_COUNT" "1"

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked" "$LEAKED_COUNT" "1"

NOT_DELETED="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED" != "0" ]; then
  echo "receipt-mismatch-phase2-reject: FAIL -- expected every threads[] entry cleanup==deleted, found $NOT_DELETED that aren't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

CURRENT_ID="$(jq -r '[.threads[]? | select(.kind == "current")][0].thread_id // ""' "$RESULT_FILE")"
LEAKED_ID="$(jq -r '[.threads[]? | select(.kind == "leaked")][0].thread_id // ""' "$RESULT_FILE")"
if [ -n "$CURRENT_ID" ] && [ -n "$LEAKED_ID" ] && [ "$CURRENT_ID" = "$LEAKED_ID" ]; then
  echo "receipt-mismatch-phase2-reject: FAIL -- current and leaked thread_id must differ, both are [$CURRENT_ID]" >&2
  FAIL=1
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "receipt-mismatch-phase2-reject: FAIL -- invocation log not found at $INVOCATION_LOG (this scenario exists to prove the abandoned thread is never --resume'd -- a missing log means that cannot be checked, so it must fail, not silently pass)" >&2
  FAIL=1
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count" "$FRESH_COUNT" "2"
  check "invocation log resume-mode count" "$RESUME_COUNT" "0"

  FRESH_LINES="$(grep '^mode=fresh ' "$INVOCATION_LOG")"
  NON_NORMAL_FRESH_COUNT="$(printf '%s\n' "$FRESH_LINES" | grep -vc 'scenario=normal$' || true)"
  check "both mode=fresh lines carry scenario=normal (never schema_mismatch)" "$NON_NORMAL_FRESH_COUNT" "0"

  FRESH_IDS_ORDERED="$(printf '%s\n' "$FRESH_LINES" | sed -E 's/^mode=fresh thread_id=([^ ]*).*/\1/')"
  FRESH_DISTINCT_IDS="$(echo "$FRESH_IDS_ORDERED" | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across the 2 fresh invocations" "$FRESH_DISTINCT_IDS" "2"

  FIRST_FRESH_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '1p')"
  SECOND_FRESH_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '2p')"
  check "leaked thread_id matches the FIRST fresh dispatch (the abandoned hollow thread)" "$LEAKED_ID" "$FIRST_FRESH_ID"
  check "current thread_id matches the SECOND fresh dispatch (the restart's own thread)" "$CURRENT_ID" "$SECOND_FRESH_ID"
fi

exit "$FAIL"

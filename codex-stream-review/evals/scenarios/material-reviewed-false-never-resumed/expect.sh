#!/usr/bin/env bash
# Scenario-specific assertions for material-reviewed-false-never-resumed,
# invoked by check-result.sh as `expect.sh <result.json>`. Schema structure
# already validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN", round_count == 1 (the restart occupies round 1's own single slot --
#     the hollow attempt never produced a valid round-1 result)
#   - threads contains exactly one "leaked" entry (the abandoned hollow thread) AND exactly one
#     "current" entry (the fresh restart's own new thread) -- BOTH cleanup=="deleted"
#   - the leaked and current thread_id values are DIFFERENT (the restart genuinely obtained a NEW
#     threadId, never reused the abandoned one)
#   - claims == [] (the hollow response's own finding never entered the claim ledger -- the whole
#     response was rejected wholesale, never parsed as a verdict)
#   - the fixed INVOCATION_LOG shows exactly 2 "mode=fresh" lines (two DIFFERENT thread_id values)
#     and exactly ZERO "mode=resume" lines -- proof the abandoned thread was never --resume'd
#     (a missing log FAILS this scenario -- it exists specifically to prove this)
#   - the FIRST "mode=fresh" thread_id equals the artifact's "leaked" thread_id, and the SECOND
#     equals the "current" thread_id (same linkage convention as
#     compact-trigger-uncommitted-success/expect.sh)
#   - the session's own durable JSONL log has exactly ONE round==1 record (the hollow round-1
#     response is never separately persisted, under the leaked thread id or any other), that
#     record's thread_id matches the artifact's current thread, and its codex_review carries
#     material_reviewed==true (the JSON boolean, not a string), a non-null 24-char lowercase-hex
#     material_receipt (the JSON string type, never a number that happens to stringify to
#     something hex-looking), material_receipt_index==1 (the JSON number, never a string), and
#     findings==[] -- the restart's own genuinely-verified material-verification fields, matching
#     the sibling receipt-mismatch-phase2-reject/receipt-null-pair-reject scenarios' own
#     equivalent checks (a whole-branch review found this scenario's own checker had never
#     actually asserted these fields, despite the underlying live evidence always having been
#     correct; a second whole-branch review then found the first fix's own `jq -r` checks were
#     type-loose, so a wrong-TYPE value could still incorrectly pass -- fixed with the same
#     has()+type strictness receipt-null-pair-reject/expect.sh already uses)
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-material-reviewed-false-never-resumed-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "material-reviewed-false-never-resumed: FAIL -- $desc: expected [$expected], got [$actual]" >&2
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
  echo "material-reviewed-false-never-resumed: FAIL -- expected every threads[] entry cleanup==deleted, found $NOT_DELETED that aren't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

CURRENT_ID="$(jq -r '[.threads[]? | select(.kind == "current")][0].thread_id // ""' "$RESULT_FILE")"
LEAKED_ID="$(jq -r '[.threads[]? | select(.kind == "leaked")][0].thread_id // ""' "$RESULT_FILE")"
if [ -n "$CURRENT_ID" ] && [ -n "$LEAKED_ID" ] && [ "$CURRENT_ID" = "$LEAKED_ID" ]; then
  echo "material-reviewed-false-never-resumed: FAIL -- current and leaked thread_id must differ, both are [$CURRENT_ID]" >&2
  FAIL=1
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "material-reviewed-false-never-resumed: FAIL -- invocation log not found at $INVOCATION_LOG (this scenario exists to prove the abandoned thread is never --resume'd -- a missing log means that cannot be checked, so it must fail, not silently pass)" >&2
  FAIL=1
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count" "$FRESH_COUNT" "2"
  check "invocation log resume-mode count" "$RESUME_COUNT" "0"

  FRESH_IDS_ORDERED="$(grep '^mode=fresh ' "$INVOCATION_LOG" | sed -E 's/^mode=fresh thread_id=([^ ]*).*/\1/')"
  FRESH_DISTINCT_IDS="$(echo "$FRESH_IDS_ORDERED" | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across the 2 fresh invocations" "$FRESH_DISTINCT_IDS" "2"

  FIRST_FRESH_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '1p')"
  SECOND_FRESH_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '2p')"
  check "leaked thread_id matches the FIRST fresh dispatch (the abandoned hollow thread)" "$LEAKED_ID" "$FIRST_FRESH_ID"
  check "current thread_id matches the SECOND fresh dispatch (the restart's own thread)" "$CURRENT_ID" "$SECOND_FRESH_ID"
fi

RESULT_DIR="$(dirname "$RESULT_FILE")"
SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
JSONL_FILE="$RESULT_DIR/$SESSION_ID.jsonl"

if [ ! -f "$JSONL_FILE" ]; then
  echo "material-reviewed-false-never-resumed: FAIL -- expected sibling JSONL log at $JSONL_FILE, not found (this scenario exists to prove material_reviewed/material_receipt were genuinely recorded on the restart's own round -- a missing log means that cannot be checked, so it must fail, not silently pass)" >&2
  FAIL=1
else
  ROUND1_TOTAL_COUNT="$(jq -c 'select(.round == 1)' "$JSONL_FILE" | wc -l | tr -d ' ')"
  check "total count of round==1 records anywhere in the JSONL (the hollow response must never be separately persisted, under the leaked thread id or any other)" "$ROUND1_TOTAL_COUNT" "1"

  ROUND1_CURRENT_LINE="$(jq -c --arg tid "$CURRENT_ID" 'select(.round == 1) | select(.thread_id == $tid)' "$JSONL_FILE" | head -n 1)"
  if [ -z "$ROUND1_CURRENT_LINE" ]; then
    echo "material-reviewed-false-never-resumed: FAIL -- no round==1 JSONL record found with thread_id matching the artifact's current thread [$CURRENT_ID]" >&2
    FAIL=1
  else
    # Type-strict per-field checks (mirrors receipt-null-pair-reject/expect.sh's own
    # has()+type pattern): a JSON string "true", a numeric receipt that happens to
    # stringify to something hex-looking, or a string "1" index must NOT be conflated
    # with the genuine JSON boolean/string/number these fields require.
    MATERIAL_REVIEWED="$(echo "$ROUND1_CURRENT_LINE" | jq -r 'if (.codex_review | has("material_reviewed")) and ((.codex_review.material_reviewed | type) == "boolean") and (.codex_review.material_reviewed == true) then "true" else "false" end')"
    check "round-1 current-thread record: codex_review.material_reviewed (must be the JSON boolean true, not a string or other value)" "$MATERIAL_REVIEWED" "true"

    MATERIAL_RECEIPT_TYPE="$(echo "$ROUND1_CURRENT_LINE" | jq -r 'if (.codex_review | has("material_receipt")) then (.codex_review.material_receipt | type) else "missing" end')"
    if [ "$MATERIAL_RECEIPT_TYPE" != "string" ]; then
      echo "material-reviewed-false-never-resumed: FAIL -- round-1 current-thread record: codex_review.material_receipt must be a JSON string, got type [$MATERIAL_RECEIPT_TYPE]" >&2
      FAIL=1
    else
      MATERIAL_RECEIPT="$(echo "$ROUND1_CURRENT_LINE" | jq -r '.codex_review.material_receipt')"
      check "round-1 current-thread record: codex_review.material_receipt length" "${#MATERIAL_RECEIPT}" "24"
      MATERIAL_RECEIPT_IS_HEX="no"
      [[ "$MATERIAL_RECEIPT" =~ ^[0-9a-f]{24}$ ]] && MATERIAL_RECEIPT_IS_HEX="yes"
      check "round-1 current-thread record: codex_review.material_receipt is a well-formed lowercase-hex token" "$MATERIAL_RECEIPT_IS_HEX" "yes"
    fi

    MATERIAL_RECEIPT_INDEX_CHECK="$(echo "$ROUND1_CURRENT_LINE" | jq -r 'if (.codex_review | has("material_receipt_index")) and ((.codex_review.material_receipt_index | type) == "number") and (.codex_review.material_receipt_index == 1) then "ok" else "fail" end')"
    check "round-1 current-thread record: codex_review.material_receipt_index (must be the JSON number 1, not a string or other value)" "$MATERIAL_RECEIPT_INDEX_CHECK" "ok"

    JSONL_FINDINGS="$(echo "$ROUND1_CURRENT_LINE" | jq -c '.codex_review.findings')"
    check "round-1 current-thread record: codex_review.findings (the hollow round-1 finding must never leak in)" "$JSONL_FINDINGS" "[]"
  fi
fi

exit "$FAIL"

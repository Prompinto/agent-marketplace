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
#   - the session's own durable JSONL log (sibling of RESULT_FILE, same session_id basename, per
#     compact-byte-budget-exceeded/expect.sh's own derivation convention) has a round==1 record
#     whose thread_id is the artifact's "current" thread, and that record's codex_review carries
#     material_reviewed==true, a non-null 24-character material_receipt, material_receipt_index==1,
#     and findings==[] (the hollow round 1 response's fabricated finding never leaked in) -- a
#     missing JSONL FAILS this scenario, same philosophy as the invocation log check above
#   - the JSONL has exactly 2 receipt_issued records with a PENDING:... thread_id, and exactly 2
#     receipt_issued records that reconcile a PENDING value to a real thread id, and those two real
#     thread ids are exactly {leaked, current} -- no more, no fewer, no mismatch
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

RESULT_DIR="$(dirname "$RESULT_FILE")"
SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
JSONL_FILE="$RESULT_DIR/$SESSION_ID.jsonl"

# Known, deliberate limitation: the checks below can only re-verify STRUCTURAL/mechanical
# consequences of a correct Phase 2 step 1 receipt comparison (round 1 never separately
# persisted, exactly one leaked + one current thread, exact reconciliation pairing, a
# genuinely persisted receipt on the accepted round). They CANNOT re-verify that the
# comparison itself (round 1's receipt vs its schedule's slot-1 token; the restart's receipt
# vs its own schedule's slot-1 token) actually happened, because SKILL.md's "Receipt schedule
# generation" section deliberately guarantees RECEIPT_SCHEDULE_FILE content is never included
# in any FOCUS_FILE, never excerpted into JSONL History text, and never part of any JSONL line
# -- a confidentiality property, not an oversight, so no durable artifact ever holds the
# schedule value a checker could compare against after the fact. That evidence exists only in
# the one-time live-verification narrative in this scenario's own README.md ("Live
# verification actually performed" section, steps 4 and 7). See README.md's "Known limitation"
# note for the full disclosure.
if [ ! -f "$JSONL_FILE" ]; then
  echo "receipt-mismatch-phase2-reject: FAIL -- expected sibling JSONL log at $JSONL_FILE, not found (this scenario exists to prove material_reviewed/material_receipt and receipt reconciliation were genuinely recorded -- a missing log means that cannot be checked, so it must fail, not silently pass)" >&2
  FAIL=1
else
  ROUND1_TOTAL_COUNT="$(jq -c 'select(.round == 1)' "$JSONL_FILE" | wc -l | tr -d ' ')"
  check "total count of round==1 records anywhere in the JSONL (a hollow round-1 response must never be separately persisted, under the leaked thread id or any other)" "$ROUND1_TOTAL_COUNT" "1"

  ROUND1_CURRENT_LINE="$(jq -c --arg tid "$CURRENT_ID" 'select(.round == 1) | select(.thread_id == $tid)' "$JSONL_FILE" | head -n 1)"
  if [ -z "$ROUND1_CURRENT_LINE" ]; then
    echo "receipt-mismatch-phase2-reject: FAIL -- no round==1 JSONL record found with thread_id matching the artifact's current thread [$CURRENT_ID]" >&2
    FAIL=1
  else
    MATERIAL_REVIEWED="$(echo "$ROUND1_CURRENT_LINE" | jq -r '.codex_review.material_reviewed')"
    check "round-1 current-thread record: codex_review.material_reviewed" "$MATERIAL_REVIEWED" "true"

    MATERIAL_RECEIPT="$(echo "$ROUND1_CURRENT_LINE" | jq -r '.codex_review.material_receipt // "null"')"
    if [ "$MATERIAL_RECEIPT" = "null" ]; then
      echo "receipt-mismatch-phase2-reject: FAIL -- round-1 current-thread record: codex_review.material_receipt is null" >&2
      FAIL=1
    else
      check "round-1 current-thread record: codex_review.material_receipt length" "${#MATERIAL_RECEIPT}" "24"
    fi

    MATERIAL_RECEIPT_INDEX="$(echo "$ROUND1_CURRENT_LINE" | jq -r '.codex_review.material_receipt_index')"
    check "round-1 current-thread record: codex_review.material_receipt_index" "$MATERIAL_RECEIPT_INDEX" "1"

    JSONL_FINDINGS="$(echo "$ROUND1_CURRENT_LINE" | jq -c '.codex_review.findings')"
    check "round-1 current-thread record: codex_review.findings (fabricated round-1 finding must never leak in)" "$JSONL_FINDINGS" "[]"
  fi

  # Whole-file scan (every line, any round, any thread_id) for a leaked finding -- the
  # round-1/current-thread check above only inspects ONE record, so a non-round-1 record (or a
  # round-1 record under a different thread_id) smuggling a non-empty codex_review.findings would
  # pass that check unnoticed. This assertion is format-agnostic: it doesn't depend on the
  # fabricated finding's exact text, just that NO line in the whole file ever carries one.
  WHOLE_FILE_FINDINGS_LEAK_COUNT="$(jq -c 'select((.codex_review.findings // []) | length > 0)' "$JSONL_FILE" | wc -l | tr -d ' ')"
  check "whole-file scan: count of JSONL lines (any round, any thread_id) with non-empty codex_review.findings" "$WHOLE_FILE_FINDINGS_LEAK_COUNT" "0"

  PENDING_THREAD_IDS="$(jq -r 'select(.receipt_issued != null) | select(.receipt_issued.thread_id | startswith("PENDING:")) | .receipt_issued.thread_id' "$JSONL_FILE")"
  PENDING_COUNT="$(printf '%s\n' "$PENDING_THREAD_IDS" | grep -c . || true)"
  check "count of receipt_issued records with a PENDING:... thread_id" "$PENDING_COUNT" "2"

  PENDING_DISTINCT_COUNT="$(printf '%s\n' "$PENDING_THREAD_IDS" | sort -u | grep -c . || true)"
  check "the PENDING:... thread_id values are distinct from each other (no duplicate placeholder reused across schedules)" "$PENDING_DISTINCT_COUNT" "2"

  RECONCILED_IDS="$(jq -r 'select(.receipt_issued != null) | select(.receipt_issued.reconciles != null) | .receipt_issued.thread_id' "$JSONL_FILE" | sort)"
  RECONCILED_COUNT="$(printf '%s\n' "$RECONCILED_IDS" | grep -c . || true)"
  check "count of receipt_issued records reconciling a PENDING value to a real thread id" "$RECONCILED_COUNT" "2"

  EXPECTED_RECONCILED_IDS="$(printf '%s\n' "$LEAKED_ID" "$CURRENT_ID" | sort)"
  check "receipt_issued reconciliations cover exactly the artifact's leaked+current thread ids" "$RECONCILED_IDS" "$EXPECTED_RECONCILED_IDS"

  # A genuine reconciliation's "reconciles" value must be one of THIS file's own real
  # PENDING:... thread_ids (not just any string), and its index must match that specific
  # PENDING record's own index -- not merely the right thread-id SET (guards against garbage
  # reconciles/index values paired with an otherwise-correct thread-id set).
  PENDING_RECORDS="$(jq -c 'select(.receipt_issued != null) | select(.receipt_issued.thread_id | startswith("PENDING:")) | {tid: .receipt_issued.thread_id, idx: .receipt_issued.index}' "$JSONL_FILE")"
  RECONCILE_RECORDS="$(jq -c 'select(.receipt_issued != null) | select(.receipt_issued.reconciles != null) | {tid: .receipt_issued.thread_id, idx: .receipt_issued.index, reconciles: .receipt_issued.reconciles}' "$JSONL_FILE")"

  while IFS= read -r REC; do
    [ -z "$REC" ] && continue
    REC_TID="$(echo "$REC" | jq -r '.tid')"
    REC_IDX="$(echo "$REC" | jq -r '.idx')"
    REC_RECONCILES="$(echo "$REC" | jq -r '.reconciles')"
    PENDING_MATCH="$(printf '%s\n' "$PENDING_RECORDS" | jq -c --arg tid "$REC_RECONCILES" 'select(.tid == $tid)' | head -n 1)"
    if [ -z "$PENDING_MATCH" ]; then
      echo "receipt-mismatch-phase2-reject: FAIL -- reconciliation record for thread [$REC_TID] reconciles [$REC_RECONCILES], which is not one of this JSONL's own real PENDING:... records" >&2
      FAIL=1
      continue
    fi
    PENDING_IDX="$(echo "$PENDING_MATCH" | jq -r '.idx')"
    check "reconciliation record for thread [$REC_TID]: index matches the PENDING record it claims to reconcile ([$REC_RECONCILES])" "$REC_IDX" "$PENDING_IDX"
  done < <(printf '%s\n' "$RECONCILE_RECORDS")

  RECONCILES_VALUES_SORTED="$(printf '%s\n' "$RECONCILE_RECORDS" | jq -r '.reconciles' | sort)"
  PENDING_TIDS_SORTED="$(printf '%s\n' "$PENDING_RECORDS" | jq -r '.tid' | sort)"
  check "reconciliation values form an exact 1:1 pairing with this JSONL's own real PENDING:... records (no PENDING value reconciled twice, none left unreconciled)" "$RECONCILES_VALUES_SORTED" "$PENDING_TIDS_SORTED"
fi

exit "$FAIL"

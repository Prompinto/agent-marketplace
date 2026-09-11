#!/usr/bin/env bash
# Scenario-specific assertions for no-material-reviewed-second-hollow, invoked by check-result.sh
# as `expect.sh <result.json>`. Schema structure (threads[].kind in {current,leaked}, claims must
# be an array for a non-integrity-failure exit_state, coverage must be an object for
# target.scope=="uncommitted") is already validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "COULD_NOT_VERIFY", round_count == 0 (no round's own JSONL line was ever
#     appended -- neither the original hollow attempt A nor the restart's own hollow attempt B was
#     ever accepted past the no_material_reviewed diversion, so round 1 never produced a real
#     outcome to log; see README.md's "Round-line accounting" section)
#   - threads contains EXACTLY TWO "leaked" entries (A and B) and ZERO "current" entries -- neither
#     thread ever becomes the session's own current thread, unlike the ordinary
#     could-not-verify-exhausted precedent (whose own final fresh-fallback thread stays "current"
#     even on failure) -- both cleanup=="deleted"; the two thread_id values are DIFFERENT
#   - claims == [] -- no round ever produced a real verdict to raise a claim from
#   - coverage.status == "complete" (both hollow attempts' own coverage.source reported complete
#     for this 1-file fixture; the schema also permits partial/unknown, so this must be checked
#     directly, not merely assumed from a CLEAN-shaped result)
#   - the fixed INVOCATION_LOG shows exactly 2 "mode=fresh" lines (A then B, two DIFFERENT
#     thread_id values), exactly ZERO "mode=resume" lines (proof no thread was ever --resume'd),
#     and exactly 2 "mode=delete" lines targeting exactly {A, B} (independent, invocation-log-based
#     proof that Phase 3 cleanup reached the fake Codex binary for both threads -- the result.json's
#     own threads[].cleanup=="deleted" fields alone are self-reported, not independent evidence;
#     same convention as no-material-reviewed-fresh-restart/expect.sh) -- a missing log FAILS this
#     scenario, never a silent skip, since proving "no third thread was ever dispatched" is this
#     scenario's own central point
#   - the session's own durable JSONL log (sibling of RESULT_FILE, same session_id basename)
#     contains ZERO round-bearing records (no "round" key on any line at all) -- confirms neither
#     hollow attempt was ever separately persisted as a round, and no successful round ever existed
#     to log either
#   - the JSONL has exactly 2 receipt_issued records with a PENDING:... thread_id, exactly 2
#     records that reconcile a PENDING value to a real thread id, and those two real thread ids are
#     exactly {A, B} -- no more, no fewer, no mismatch, with reconciliation index-pairing validated
#     against each PENDING record's own index (not merely the right thread-id set) -- same
#     convention as receipt-mismatch-phase2-reject/expect.sh and
#     no-material-reviewed-fresh-restart/expect.sh
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-no-material-reviewed-second-hollow-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "no-material-reviewed-second-hollow: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "COULD_NOT_VERIFY"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "0"
check "claims" "$(jq -c '.claims' "$RESULT_FILE")" "[]"
check "coverage.status" "$(jq -r '.coverage.status // ""' "$RESULT_FILE")" "complete"

CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==current (neither hollow thread ever becomes current)" "$CURRENT_COUNT" "0"

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked (both A and B)" "$LEAKED_COUNT" "2"

NOT_DELETED="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED" != "0" ]; then
  echo "no-material-reviewed-second-hollow: FAIL -- expected every threads[] entry cleanup==deleted, found $NOT_DELETED that aren't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

LEAKED_IDS_SORTED="$(jq -r '[.threads[]? | select(.kind == "leaked") | .thread_id] | sort | .[]' "$RESULT_FILE")"
LEAKED_DISTINCT_COUNT="$(printf '%s\n' "$LEAKED_IDS_SORTED" | sort -u | grep -c . || true)"
check "the two leaked thread_id values are distinct" "$LEAKED_DISTINCT_COUNT" "2"

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "no-material-reviewed-second-hollow: FAIL -- invocation log not found at $INVOCATION_LOG (this scenario exists to prove no third thread was ever dispatched -- a missing log means that cannot be checked, so it must fail, not silently pass)" >&2
  FAIL=1
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count (exactly 2 -- A and B, never a third thread C)" "$FRESH_COUNT" "2"
  check "invocation log resume-mode count (zero -- neither hollow thread is ever resumed)" "$RESUME_COUNT" "0"

  FRESH_IDS_ORDERED="$(grep '^mode=fresh ' "$INVOCATION_LOG" | sed -E 's/^mode=fresh thread_id=([^ ]*).*/\1/')"
  FRESH_DISTINCT_IDS="$(echo "$FRESH_IDS_ORDERED" | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across the 2 fresh invocations" "$FRESH_DISTINCT_IDS" "2"

  FRESH_IDS_SORTED="$(printf '%s\n' "$FRESH_IDS_ORDERED" | sort)"
  check "the 2 fresh-dispatch thread ids match exactly the artifact's 2 leaked thread ids (A and B, no other thread ever dispatched)" "$FRESH_IDS_SORTED" "$LEAKED_IDS_SORTED"

  # The result.json's own threads[].cleanup=="deleted" fields are self-reported, not independent
  # proof cleanup actually reached the fake Codex binary -- the invocation log's own mode=delete
  # lines are that independent evidence, matching the established convention in
  # no-material-reviewed-fresh-restart/expect.sh.
  DELETE_COUNT="$(grep -c '^mode=delete ' "$INVOCATION_LOG" || true)"
  check "invocation log delete-mode count" "$DELETE_COUNT" "2"

  DELETE_IDS_SORTED="$(grep '^mode=delete ' "$INVOCATION_LOG" | sed -E 's/^mode=delete thread_id=([^ ]*).*/\1/' | sort)"
  check "the two mode=delete lines target exactly the two leaked thread ids (A and B)" "$DELETE_IDS_SORTED" "$LEAKED_IDS_SORTED"
fi

RESULT_DIR="$(dirname "$RESULT_FILE")"
SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
JSONL_FILE="$RESULT_DIR/$SESSION_ID.jsonl"

if [ ! -f "$JSONL_FILE" ]; then
  echo "no-material-reviewed-second-hollow: FAIL -- expected sibling JSONL log at $JSONL_FILE, not found (this scenario exists to prove no round was ever durably logged and both receipt schedules were genuinely issued/reconciled -- a missing log means that cannot be checked, so it must fail, not silently pass)" >&2
  FAIL=1
else
  ROUND_RECORD_COUNT="$(jq -c 'select(has("round"))' "$JSONL_FILE" | wc -l | tr -d ' ')"
  check "total count of round-bearing JSONL records (neither hollow attempt is ever persisted as a round; no successful round ever existed either)" "$ROUND_RECORD_COUNT" "0"

  # receipt_issued bookkeeping: exactly 2 PENDING placeholders (A's round-1 establishment, B's
  # restart establishment) and exactly 2 reconciliations, forming a 1:1 pairing with {A, B} --
  # same convention as receipt-mismatch-phase2-reject/expect.sh and
  # no-material-reviewed-fresh-restart/expect.sh.
  PENDING_THREAD_IDS="$(jq -r 'select(.receipt_issued != null) | select(.receipt_issued.thread_id | startswith("PENDING:")) | .receipt_issued.thread_id' "$JSONL_FILE")"
  PENDING_COUNT="$(printf '%s\n' "$PENDING_THREAD_IDS" | grep -c . || true)"
  check "count of receipt_issued records with a PENDING:... thread_id" "$PENDING_COUNT" "2"

  PENDING_DISTINCT_COUNT="$(printf '%s\n' "$PENDING_THREAD_IDS" | sort -u | grep -c . || true)"
  check "the PENDING:... thread_id values are distinct from each other (no duplicate placeholder reused across schedules)" "$PENDING_DISTINCT_COUNT" "2"

  RECONCILED_IDS="$(jq -r 'select(.receipt_issued != null) | select(.receipt_issued.reconciles != null) | .receipt_issued.thread_id' "$JSONL_FILE" | sort)"
  RECONCILED_COUNT="$(printf '%s\n' "$RECONCILED_IDS" | grep -c . || true)"
  check "count of receipt_issued records reconciling a PENDING value to a real thread id" "$RECONCILED_COUNT" "2"

  check "receipt_issued reconciliations cover exactly the artifact's two leaked thread ids (A and B)" "$RECONCILED_IDS" "$LEAKED_IDS_SORTED"

  # A genuine reconciliation's "reconciles" value must be one of THIS file's own real PENDING:...
  # thread_ids (not just any string), and its index must match that specific PENDING record's own
  # index -- not merely the right thread-id SET. Single self-contained jq invocation reading
  # $JSONL_FILE directly (no bash `while read` loop fed by a here-string/pipe/process
  # substitution), same pattern as receipt-mismatch-phase2-reject/expect.sh and
  # no-material-reviewed-fresh-restart/expect.sh's own reconciliation-pairing check.
  RECONCILE_MISMATCHES="$(jq -s -c '
    . as $lines
    | ($lines | map(select(.receipt_issued != null) | select(.receipt_issued.thread_id | startswith("PENDING:")) | {tid: .receipt_issued.thread_id, idx: .receipt_issued.index})) as $pending
    | ($lines | map(select(.receipt_issued != null) | select(.receipt_issued.reconciles != null) | {tid: .receipt_issued.thread_id, idx: .receipt_issued.index, reconciles: .receipt_issued.reconciles})) as $reconcile
    | [ $reconcile[] | . as $r
        | ($pending | map(select(.tid == $r.reconciles)) | first) as $p
        | if $p == null then
            {tid: $r.tid, reconciles: $r.reconciles, reason: "reconciles value is not one of this JSONL own real PENDING records"}
          elif $p.idx != $r.idx then
            {tid: $r.tid, reconciles: $r.reconciles, expected_idx: $p.idx, actual_idx: $r.idx, reason: "index does not match the matching PENDING record index"}
          else empty
          end
      ]
  ' "$JSONL_FILE")"
  check "reconciliation records with an invalid reconciles target or a mismatched index" "$RECONCILE_MISMATCHES" "[]"

  PENDING_TIDS_SORTED="$(printf '%s\n' "$PENDING_THREAD_IDS" | sort)"
  RECONCILES_VALUES_SORTED="$(jq -r 'select(.receipt_issued != null) | select(.receipt_issued.reconciles != null) | .receipt_issued.reconciles' "$JSONL_FILE" | sort)"
  check "reconciliation values form an exact 1:1 pairing with this JSONL's own real PENDING:... records (no PENDING value reconciled twice, none left unreconciled)" "$RECONCILES_VALUES_SORTED" "$PENDING_TIDS_SORTED"

  # Each thread's own receipt_issued sequence is exactly slot 1 (its own single, hollow dispatch
  # attempt) -- never more, since a wrapper-level material_reviewed:false rejection never proceeds
  # far enough to earn a second slot on the SAME thread within this scenario. One self-contained jq
  # call over both leaked thread ids (never a bash loop re-invoking jq per id).
  NON_SLOT1_THREADS="$(jq -s -c --argjson ids "$(printf '%s\n' "$LEAKED_IDS_SORTED" | jq -R . | jq -s .)" '
    . as $lines
    | $ids[] as $tid
    | ($lines | map(select(.receipt_issued != null) | select(.receipt_issued.thread_id == $tid) | .receipt_issued.index)) as $slots
    | select($slots != [1])
    | {thread_id: $tid, slots: $slots}
  ' "$JSONL_FILE")"
  check "every leaked thread's own receipt_issued records span only slot 1 (violations listed if any)" "$NON_SLOT1_THREADS" ""
fi

exit "$FAIL"

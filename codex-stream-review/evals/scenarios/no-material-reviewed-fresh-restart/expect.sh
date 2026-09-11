#!/usr/bin/env bash
# Scenario-specific assertions for no-material-reviewed-fresh-restart, invoked by check-result.sh
# as `expect.sh <result.json>`. Schema structure already validated by check-result.sh itself
# before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN", round_count == 3 (the restart occupies round 3's own slot -- rounds
#     1-2 already produced valid results before thread A went hollow, unlike
#     material-reviewed-false-never-resumed's round-1-only case)
#   - threads contains exactly one "leaked" entry (thread A, abandoned after rounds 1-2) AND
#     exactly one "current" entry (thread B, the restart's own new thread) -- BOTH
#     cleanup=="deleted"; the two thread_id values are DIFFERENT
#   - claims has exactly two entries: f1 resolved at round 2, f2 resolved at round 3 -- both
#     claims reached a terminal disposition (this is what makes round 3 genuinely CLEAN despite
#     the intervening hollow attempt)
#   - the fixed INVOCATION_LOG shows exactly 2 "mode=fresh" lines (A then B, two DIFFERENT
#     thread_id values) and exactly 2 "mode=resume" lines (BOTH to thread A, never to B -- proof
#     the abandoned thread was resumed twice before going hollow, and the restart's own new thread
#     is never itself resumed within this session)
#   - the session's own durable JSONL log (sibling of RESULT_FILE, same session_id basename) has
#     EXACTLY 3 round-bearing records (rounds 1, 2, 3) -- round 3's own hollow attempt is never
#     separately persisted, only the eventual restart's own successful round is
#   - round 1's JSONL record's thread_id equals the leaked thread; round 3's JSONL record's
#     thread_id equals the current thread (the restart IS round 3's real dispatch)
#   - round 3's own target.focus field genuinely carries the compaction-style digest forward:
#     f1's own one-line closed-claim reason text (byte-exact against round 2's own
#     claim_closures[0].marker_reason) AND f2's own full verbatim summary/evidence text (byte-exact
#     against round 1's own codex_review.findings[] entry for f2) -- never a blank/reset digest.
#     This is the one property this scenario exists to prove: the restart's own seed is not merely
#     "a new thread happens to get created," it genuinely contains the carried-forward claim state.
#   - round 3's own target.focus also contains the actual literal structural markers
#     references/compaction.md's digest-construction procedure produces (COMPACT_DIGEST,
#     CLOSED CLAIMS:, OPEN CLAIM f2:) -- not merely the same substrings inside unrelated prose
#   - round 3's own JSONL record has target.scope == "uncommitted" (never "resume") and its own
#     coverage_source object, per references/retry-guards.md's "two known exceptions to the
#     general round-2+ resume rule" section
#   - the receipt_issued reconciliation records each pair a real "reconciles" value against ITS
#     OWN matching PENDING:... record's index (not merely the right thread-id set), and thread A
#     (leaked)'s own receipt_issued records span slots 1, 2, and 3 (one per round it was
#     dispatched to before being abandoned)
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-no-material-reviewed-fresh-restart-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "no-material-reviewed-fresh-restart: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "3"

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "2"

F1_DISPOSITION="$(jq -r '[.claims[]? | select(.claim_id == "f1")][0].disposition // ""' "$RESULT_FILE")"
check "claims: f1 disposition" "$F1_DISPOSITION" "resolved"
F1_SOURCE_ROUND="$(jq -r '[.claims[]? | select(.claim_id == "f1")][0].source_round // ""' "$RESULT_FILE")"
check "claims: f1 source_round" "$F1_SOURCE_ROUND" "2"

F2_DISPOSITION="$(jq -r '[.claims[]? | select(.claim_id == "f2")][0].disposition // ""' "$RESULT_FILE")"
check "claims: f2 disposition" "$F2_DISPOSITION" "resolved"
F2_SOURCE_ROUND="$(jq -r '[.claims[]? | select(.claim_id == "f2")][0].source_round // ""' "$RESULT_FILE")"
check "claims: f2 source_round" "$F2_SOURCE_ROUND" "3"

CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==current" "$CURRENT_COUNT" "1"

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked" "$LEAKED_COUNT" "1"

NOT_DELETED="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED" != "0" ]; then
  echo "no-material-reviewed-fresh-restart: FAIL -- expected every threads[] entry cleanup==deleted, found $NOT_DELETED that aren't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

CURRENT_ID="$(jq -r '[.threads[]? | select(.kind == "current")][0].thread_id // ""' "$RESULT_FILE")"
LEAKED_ID="$(jq -r '[.threads[]? | select(.kind == "leaked")][0].thread_id // ""' "$RESULT_FILE")"
if [ -n "$CURRENT_ID" ] && [ -n "$LEAKED_ID" ] && [ "$CURRENT_ID" = "$LEAKED_ID" ]; then
  echo "no-material-reviewed-fresh-restart: FAIL -- current and leaked thread_id must differ, both are [$CURRENT_ID]" >&2
  FAIL=1
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "no-material-reviewed-fresh-restart: FAIL -- invocation log not found at $INVOCATION_LOG (this scenario exists to prove the abandoned thread was resumed twice, then never again after going hollow -- a missing log means that cannot be checked, so it must fail, not silently pass)" >&2
  FAIL=1
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count" "$FRESH_COUNT" "2"
  check "invocation log resume-mode count" "$RESUME_COUNT" "2"

  FRESH_IDS_ORDERED="$(grep '^mode=fresh ' "$INVOCATION_LOG" | sed -E 's/^mode=fresh thread_id=([^ ]*).*/\1/')"
  FRESH_DISTINCT_IDS="$(echo "$FRESH_IDS_ORDERED" | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across the 2 fresh invocations" "$FRESH_DISTINCT_IDS" "2"

  FIRST_FRESH_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '1p')"
  SECOND_FRESH_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '2p')"
  check "leaked thread_id matches the FIRST fresh dispatch (thread A, rounds 1-2)" "$LEAKED_ID" "$FIRST_FRESH_ID"
  check "current thread_id matches the SECOND fresh dispatch (thread B, the restart)" "$CURRENT_ID" "$SECOND_FRESH_ID"

  RESUME_IDS="$(grep '^mode=resume ' "$INVOCATION_LOG" | sed -E 's/^mode=resume thread_id=([^ ]*).*/\1/' | sort -u)"
  EXPECTED_RESUME_IDS="$LEAKED_ID"
  RESUME_DISTINCT_COUNT="$(echo "$RESUME_IDS" | grep -c . || true)"
  check "both mode=resume lines target exactly one distinct thread_id" "$RESUME_DISTINCT_COUNT" "1"
  check "the resumed thread_id is the leaked thread (thread A) -- never the current thread (thread B)" "$RESUME_IDS" "$EXPECTED_RESUME_IDS"
fi

RESULT_DIR="$(dirname "$RESULT_FILE")"
SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
JSONL_FILE="$RESULT_DIR/$SESSION_ID.jsonl"

if [ ! -f "$JSONL_FILE" ]; then
  echo "no-material-reviewed-fresh-restart: FAIL -- expected sibling JSONL log at $JSONL_FILE, not found (this scenario exists to prove the restart's own focus text genuinely carries the digest forward -- a missing log means that cannot be checked, so it must fail, not silently pass)" >&2
  FAIL=1
else
  ROUND_RECORD_COUNT="$(jq -c 'select(.round != null)' "$JSONL_FILE" | wc -l | tr -d ' ')"
  check "total count of round-bearing JSONL records (round 3's own hollow attempt must never be separately persisted)" "$ROUND_RECORD_COUNT" "3"

  ROUND1_THREAD="$(jq -r 'select(.round == 1) | .thread_id // ""' "$JSONL_FILE" | head -n 1)"
  check "round 1 JSONL record thread_id matches the leaked thread (thread A)" "$ROUND1_THREAD" "$LEAKED_ID"

  ROUND3_EXISTS="$(jq -r 'select(.round == 3)' "$JSONL_FILE" | head -n 1)"
  if [ -z "$ROUND3_EXISTS" ]; then
    echo "no-material-reviewed-fresh-restart: FAIL -- no round==3 JSONL record found" >&2
    FAIL=1
  else
    ROUND3_THREAD="$(jq -r 'select(.round == 3) | .thread_id // ""' "$JSONL_FILE" | head -n 1)"
    check "round 3 JSONL record thread_id matches the current thread (thread B, the restart)" "$ROUND3_THREAD" "$CURRENT_ID"

    ROUND3_MATERIAL_REVIEWED="$(jq -r 'select(.round == 3) | .codex_review.material_reviewed' "$JSONL_FILE" | head -n 1)"
    check "round 3 JSONL record: codex_review.material_reviewed" "$ROUND3_MATERIAL_REVIEWED" "true"

    # references/retry-guards.md's "two known exceptions to the general round-2+ resume rule"
    # section: a no_material_reviewed restart at round 2+ logs its OWN actual fresh scope, never
    # "resume", and (for --uncommitted scope specifically) its own coverage_source as a genuine
    # second, independent coverage-establishing event -- never folded into round 1's.
    ROUND3_SCOPE="$(jq -r 'select(.round == 3) | .target.scope // ""' "$JSONL_FILE" | head -n 1)"
    check "round 3 JSONL record: target.scope is its own actual fresh scope (never \"resume\")" "$ROUND3_SCOPE" "uncommitted"

    ROUND3_COVERAGE_SOURCE_TYPE="$(jq -r 'select(.round == 3) | .coverage_source | type' "$JSONL_FILE" | head -n 1)"
    check "round 3 JSONL record: coverage_source is present as its own object (a genuine second coverage-establishing event, not a resume)" "$ROUND3_COVERAGE_SOURCE_TYPE" "object"

    ROUND3_COVERAGE_SOURCE_STATUS="$(jq -r 'select(.round == 3) | .coverage_source.status // ""' "$JSONL_FILE" | head -n 1)"
    check "round 3 JSONL record: coverage_source.status is complete (SKILL.md requires every successful fresh --uncommitted coverage event to be explicitly complete for convergence)" "$ROUND3_COVERAGE_SOURCE_STATUS" "complete"

    # The digest-carryforward check itself: round 3's own target.focus must be a non-empty string
    # (present, well-typed -- a missing/empty focus can never contain the digest at all) that
    # contains BOTH the closed claim's one-line reason (byte-exact against round 2's own
    # claim_closures[0].marker_reason) AND the open claim's own verbatim summary/evidence text
    # (byte-exact against round 1's own codex_review.findings[] entry for f2). Every comparison
    # below reads BOTH sides directly from this SAME JSONL file via jq (never a bash re-pipe of a
    # captured JSON line, and never a hardcoded copy of the expected text) -- so this check tracks
    # whatever this scenario's own live run actually recorded, rather than silently drifting from
    # a duplicated literal.
    ROUND3_FOCUS_TYPE="$(jq -r 'select(.round == 3) | .target.focus | type' "$JSONL_FILE" | head -n 1)"
    check "round 3 JSONL record: target.focus is present as a string" "$ROUND3_FOCUS_TYPE" "string"

    F1_MARKER_REASON="$(jq -r 'select(.round == 2) | .claim_closures[]? | select(.claim_id == "f1") | .marker_reason // ""' "$JSONL_FILE" | head -n 1)"
    if [ -z "$F1_MARKER_REASON" ]; then
      echo "no-material-reviewed-fresh-restart: FAIL -- round 2 JSONL record has no claim_closures entry for f1 to compare the digest against" >&2
      FAIL=1
    else
      F1_IN_ROUND3_FOCUS="$(jq -r --arg needle "$F1_MARKER_REASON" 'select(.round == 3) | .target.focus | contains($needle)' "$JSONL_FILE" | head -n 1)"
      check "round 3 target.focus contains f1's own one-line closed-claim reason verbatim (byte-exact against round 2's own marker_reason)" "$F1_IN_ROUND3_FOCUS" "true"
    fi

    F2_SUMMARY="$(jq -r 'select(.round == 1) | .codex_review.findings[]? | select(.id == "f2") | .summary // ""' "$JSONL_FILE" | head -n 1)"
    F2_EVIDENCE="$(jq -r 'select(.round == 1) | .codex_review.findings[]? | select(.id == "f2") | .evidence // ""' "$JSONL_FILE" | head -n 1)"
    if [ -z "$F2_SUMMARY" ] || [ -z "$F2_EVIDENCE" ]; then
      echo "no-material-reviewed-fresh-restart: FAIL -- round 1 JSONL record has no findings[] entry for f2 to compare the digest against" >&2
      FAIL=1
    else
      F2_SUMMARY_IN_ROUND3_FOCUS="$(jq -r --arg needle "$F2_SUMMARY" 'select(.round == 3) | .target.focus | contains($needle)' "$JSONL_FILE" | head -n 1)"
      check "round 3 target.focus contains f2's own summary text verbatim (byte-exact against round 1's own finding, unabridged)" "$F2_SUMMARY_IN_ROUND3_FOCUS" "true"
      F2_EVIDENCE_IN_ROUND3_FOCUS="$(jq -r --arg needle "$F2_EVIDENCE" 'select(.round == 3) | .target.focus | contains($needle)' "$JSONL_FILE" | head -n 1)"
      check "round 3 target.focus contains f2's own evidence text verbatim (byte-exact against round 1's own finding, unabridged)" "$F2_EVIDENCE_IN_ROUND3_FOCUS" "true"
    fi

    # Structural-marker check: the content-substring checks above can be satisfied by unrelated
    # prose that merely happens to contain the same substrings -- they never require the actual
    # digest-construction markers references/compaction.md's "Digest construction and verification"
    # procedure produces (COMPACT_DIGEST heading, the CLOSED CLAIMS: section, and the per-claim
    # "OPEN CLAIM <claim_id>:" template), each anchored at the start of its own line, in the
    # correct relative order. Without the line-start anchor and order check, an adversarial focus
    # that merely NAMES all three headings somewhere in unstructured prose would still pass.
    # jq/oniguruma's "^" only becomes a per-line anchor inside an inline (?m) modifier group here
    # (confirmed against the real captured artifact -- neither the bare "^" nor the "m" test()
    # flag anchors per-line in this jq build). Each pattern is ALSO end-anchored with "$" (also
    # only a per-line anchor inside the same (?m) group) -- a start anchor alone would let a
    # heading-prefixed non-canonical line (e.g. "COMPACT_DIGEST_not_a_heading") pass; the real
    # captured digest has each marker as its own complete, standalone line.
    ROUND3_FOCUS_HAS_DIGEST_MARKER="$(jq -r 'select(.round == 3) | .target.focus | test("(?m)^COMPACT_DIGEST$")' "$JSONL_FILE" | head -n 1)"
    check "round 3 target.focus contains the literal COMPACT_DIGEST marker anchored at a line start" "$ROUND3_FOCUS_HAS_DIGEST_MARKER" "true"

    ROUND3_FOCUS_HAS_CLOSED_HEADING="$(jq -r 'select(.round == 3) | .target.focus | test("(?m)^CLOSED CLAIMS:$")' "$JSONL_FILE" | head -n 1)"
    check "round 3 target.focus contains the literal CLOSED CLAIMS: section heading anchored at a line start" "$ROUND3_FOCUS_HAS_CLOSED_HEADING" "true"

    ROUND3_FOCUS_HAS_OPEN_CLAIM_MARKER="$(jq -r 'select(.round == 3) | .target.focus | test("(?m)^OPEN CLAIM f2:$")' "$JSONL_FILE" | head -n 1)"
    check "round 3 target.focus contains the literal OPEN CLAIM f2: per-claim heading anchored at a line start" "$ROUND3_FOCUS_HAS_OPEN_CLAIM_MARKER" "true"

    # The order check must derive its offsets from the SAME line-start-anchored match the 3
    # checks above validate -- using unanchored indices() here would let an out-of-order (or
    # missing) set of anchored markers still "pass" ordering via an earlier, coincidental,
    # non-anchored mention of the same substrings elsewhere in the prose. match(...).offset with
    # the identical "(?m)^..." pattern ties the order check to the exact same anchored match.
    ROUND3_FOCUS_MARKER_ORDER="$(jq -r 'select(.round == 3) | .target.focus as $f
      | (try ($f | match("(?m)^COMPACT_DIGEST$").offset) catch null) as $p1
      | (try ($f | match("(?m)^CLOSED CLAIMS:$").offset) catch null) as $p2
      | (try ($f | match("(?m)^OPEN CLAIM f2:$").offset) catch null) as $p3
      | if ($p1 != null and $p2 != null and $p3 != null and $p1 < $p2 and $p2 < $p3) then "true" else "false" end' "$JSONL_FILE" | head -n 1)"
    check "round 3 target.focus markers appear in the correct relative order (COMPACT_DIGEST before CLOSED CLAIMS: before OPEN CLAIM f2:)" "$ROUND3_FOCUS_MARKER_ORDER" "true"
  fi

  # receipt_issued bookkeeping: exactly 2 PENDING placeholders (thread A's round-1 establishment,
  # thread B's restart establishment) and exactly 2 reconciliations, forming a 1:1 pairing with
  # {leaked, current} -- same convention as receipt-mismatch-phase2-reject/expect.sh.
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

  # A genuine reconciliation's "reconciles" value must be one of THIS file's own real PENDING:...
  # thread_ids (not just any string), and its index must match that specific PENDING record's own
  # index -- not merely the right thread-id SET. Single self-contained jq invocation reading
  # $JSONL_FILE directly (no bash `while read` loop), same pattern as
  # receipt-mismatch-phase2-reject/expect.sh's own reconciliation-pairing check.
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

  PENDING_TIDS_SORTED="$(jq -r 'select(.receipt_issued != null) | select(.receipt_issued.thread_id | startswith("PENDING:")) | .receipt_issued.thread_id' "$JSONL_FILE" | sort)"
  RECONCILES_VALUES_SORTED="$(jq -r 'select(.receipt_issued != null) | select(.receipt_issued.reconciles != null) | .receipt_issued.reconciles' "$JSONL_FILE" | sort)"
  check "reconciliation values form an exact 1:1 pairing with this JSONL's own real PENDING:... records (no PENDING value reconciled twice, none left unreconciled)" "$RECONCILES_VALUES_SORTED" "$PENDING_TIDS_SORTED"

  # Thread A's own full multi-round receipt-slot sequence: it was dispatched to slots 1 (round 1),
  # 2 (round 2), and 3 (the hollow round-3 attempt that triggered the restart) before being
  # abandoned -- removing the slot-2/slot-3 records would still leave the pending/reconciled
  # counts and thread-id sets above looking correct, so they must be checked directly.
  THREAD_A_RECEIPT_SLOTS="$(jq -r --arg tid "$LEAKED_ID" 'select(.receipt_issued != null) | select(.receipt_issued.thread_id == $tid) | .receipt_issued.index' "$JSONL_FILE" | sort -n | paste -sd, -)"
  check "thread A (leaked)'s own receipt_issued records span slots 1, 2, and 3" "$THREAD_A_RECEIPT_SLOTS" "1,2,3"
fi

exit "$FAIL"

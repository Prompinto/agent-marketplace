#!/usr/bin/env bash
# Scenario-specific assertions for compact-fresh-b-escalation, invoked by check-result.sh as
# `expect.sh <result.json>`. Schema structure already validated by check-result.sh itself before
# this runs.
#
# Applies the lessons from Tasks 23-25's own fix rounds, from the start:
#   - causal linkage of specific thread ids to specific dispatch attempts, IN ORDER (never just
#     "3 distinct ids exist somewhere")
#   - mechanical verification of the actual JSONL-recorded facts, not just downstream
#     dispatch-pattern effects -- compaction_attempt_failed_thread must be EXACTLY the
#     one-element array [A], on round 2's own line specifically
#   - ORDER (A's own 3 failed attempts genuinely happen and exhaust BEFORE B is ever dispatched)
#     and EXCLUSIVITY (exactly 2 JSONL records, exactly the expected thread/mode counts) -- never
#     just "eventually A and B both appear"
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-compact-fresh-b-escalation-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "compact-fresh-b-escalation: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "2"

CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==current" "$CURRENT_COUNT" "1"
LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked (OLD + candidate A)" "$LEAKED_COUNT" "2"

NOT_DELETED="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED" != "0" ]; then
  echo "compact-fresh-b-escalation: FAIL -- expected every threads[] entry cleanup==deleted, found $NOT_DELETED that aren't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

ALL_DISTINCT="$(jq -r '[.threads[].thread_id] | unique | length' "$RESULT_FILE")"
check "all three thread_id values distinct (OLD, A, B never collapse into fewer than 3)" "$ALL_DISTINCT" "3"

CURRENT_ID="$(jq -r '[.threads[]? | select(.kind == "current")][0].thread_id // ""' "$RESULT_FILE")"

# This is a controlled synthetic run (setup.sh creates this log deterministically), never a
# live/flaky dispatch -- unlike a real production /ccs run, a missing log here means the fixture
# harness itself is broken, so it must FAIL, not WARN-and-skip (the convention
# compact-baseline-still-over-threshold's and compact-byte-budget-exceeded's own fix rounds
# already established for scenarios whose own JSONL-linkage checks NEED this log to identify
# which real thread_id is which). This scenario needs it even more than either of those: without
# it, OLD/A/B can never be told apart, and every value-level JSONL check below would have to be
# skipped entirely -- silently downgrading this scenario's whole reason for existing to a
# presence/shape check.
if [ ! -f "$INVOCATION_LOG" ]; then
  echo "compact-fresh-b-escalation: FAIL -- invocation log not found at $INVOCATION_LOG (setup.sh should always create this for this scenario)" >&2
  FAIL=1
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count (OLD, A, B)" "$FRESH_COUNT" "3"
  check "invocation log resume-mode count (both against A)" "$RESUME_COUNT" "2"

  # Causal linkage, in ORDER (Task 23's/24's lesson): the 3 fresh dispatches, in the order they
  # actually happened, are OLD (round 1), then A (candidate A's own original attempt), then B
  # (the fresh-B escalation) -- never merely "3 distinct ids exist somewhere".
  FRESH_IDS_ORDERED="$(grep '^mode=fresh ' "$INVOCATION_LOG" | sed -E 's/^mode=fresh thread_id=([^ ]*).*/\1/')"
  FRESH_DISTINCT_IDS="$(echo "$FRESH_IDS_ORDERED" | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across the 3 fresh invocations" "$FRESH_DISTINCT_IDS" "3"

  OLD_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '1p')"
  A_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '2p')"
  B_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '3p')"

  check "current thread_id matches the THIRD fresh dispatch (thread B, the fresh-B escalation)" "$CURRENT_ID" "$B_ID"

  LEAKED_IDS_SORTED="$(jq -r '[.threads[]? | select(.kind == "leaked") | .thread_id] | sort | join(",")' "$RESULT_FILE")"
  EXPECTED_LEAKED_SORTED="$(printf '%s\n%s\n' "$OLD_ID" "$A_ID" | sort | tr '\n' ',' | sed 's/,$//')"
  check "leaked thread_ids are EXACTLY {OLD, A} (the pre-existing thread AND exhausted candidate A -- never B, never a wrong pairing)" "$LEAKED_IDS_SORTED" "$EXPECTED_LEAKED_SORTED"

  RESUME_IDS="$(grep '^mode=resume ' "$INVOCATION_LOG" | sed -E 's/^mode=resume thread_id=([^ ]*).*/\1/')"
  RESUME_DISTINCT_IDS="$(echo "$RESUME_IDS" | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across the 2 resume invocations (both A)" "$RESUME_DISTINCT_IDS" "1"
  RESUME_TARGET="$(echo "$RESUME_IDS" | sed -n '1p')"
  check "both resume invocations target candidate A specifically (never OLD, never B)" "$RESUME_TARGET" "$A_ID"

  # ORDER, not just counts (Task 25's lesson): A's own fresh dispatch and both of its resume
  # retries must all appear BEFORE B's fresh dispatch in the log -- proving A's retries genuinely
  # happened and exhausted BEFORE B was ever dispatched, not merely "A and B both eventually
  # appear somewhere in the log".
  OLD_LINE="$(grep -n '^mode=fresh ' "$INVOCATION_LOG" | sed -n '1p' | cut -d: -f1)"
  A_FRESH_LINE="$(grep -n '^mode=fresh ' "$INVOCATION_LOG" | sed -n '2p' | cut -d: -f1)"
  B_FRESH_LINE="$(grep -n '^mode=fresh ' "$INVOCATION_LOG" | sed -n '3p' | cut -d: -f1)"
  RESUME_LINES="$(grep -n '^mode=resume ' "$INVOCATION_LOG" | cut -d: -f1)"
  RESUME_LINE_1="$(echo "$RESUME_LINES" | sed -n '1p')"
  RESUME_LINE_2="$(echo "$RESUME_LINES" | sed -n '2p')"

  if [ -n "$OLD_LINE" ] && [ -n "$A_FRESH_LINE" ] && [ -n "$RESUME_LINE_1" ] && [ -n "$RESUME_LINE_2" ] && [ -n "$B_FRESH_LINE" ]; then
    if ! { [ "$OLD_LINE" -lt "$A_FRESH_LINE" ] && [ "$A_FRESH_LINE" -lt "$RESUME_LINE_1" ] && [ "$RESUME_LINE_1" -lt "$RESUME_LINE_2" ] && [ "$RESUME_LINE_2" -lt "$B_FRESH_LINE" ]; }; then
      echo "compact-fresh-b-escalation: FAIL -- expected log order OLD($OLD_LINE) < A-fresh($A_FRESH_LINE) < resume#1($RESUME_LINE_1) < resume#2($RESUME_LINE_2) < B-fresh($B_FRESH_LINE), but order was violated" >&2
      FAIL=1
    fi
  else
    echo "compact-fresh-b-escalation: FAIL -- could not locate all 5 expected log lines to verify order" >&2
    FAIL=1
  fi
fi

# Verify the actual CAUSE, not just the downstream dispatch-pattern effect (Task 24's lesson):
# thread continuity/counts alone can't rule out a buggy implementation that mislabels which
# thread was abandoned. Read the session's own JSONL log (sibling of RESULT_FILE, same
# <session-id> basename) and confirm round 2's OWN line -- not round 1's -- carries
# compaction_attempt_failed_thread as EXACTLY the one-element array [A], never [B], never
# including OLD, never a 2-element array.
RESULT_DIR="$(dirname "$RESULT_FILE")"
SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
JSONL_FILE="$RESULT_DIR/$SESSION_ID.jsonl"

if [ ! -f "$JSONL_FILE" ]; then
  echo "compact-fresh-b-escalation: FAIL -- expected sibling JSONL log at $JSONL_FILE, not found" >&2
  FAIL=1
else
  # Exclusivity, not just presence (Task 25's lesson): exactly 2 records total -- no hidden third
  # round that a round-scoped select alone would never see.
  TOTAL_JSONL_LINES="$(jq -s 'length' "$JSONL_FILE")"
  check "JSONL log total record count (exactly rounds 1 and 2 -- no hidden third record)" "$TOTAL_JSONL_LINES" "2"

  ROUND1_LINE="$(jq -c 'select(.round == 1)' "$JSONL_FILE" | head -n 1)"
  ROUND2_LINE="$(jq -c 'select(.round == 2)' "$JSONL_FILE" | head -n 1)"

  if [ -z "$ROUND1_LINE" ] || [ -z "$ROUND2_LINE" ]; then
    echo "compact-fresh-b-escalation: FAIL -- expected round 1 and round 2 lines both present in $JSONL_FILE" >&2
    FAIL=1
  else
    check "round 1's line does NOT carry compacted_from_thread (never mis-attributed to the TRIGGERING round)" \
      "$(jq -r 'has("compacted_from_thread")' <<<"$ROUND1_LINE")" "false"
    check "round 1's line does NOT carry compaction_attempt_failed_thread" \
      "$(jq -r 'has("compaction_attempt_failed_thread")' <<<"$ROUND1_LINE")" "false"

    check "round 2's line HAS compacted_from_thread" \
      "$(jq -r 'has("compacted_from_thread")' <<<"$ROUND2_LINE")" "true"

    if [ -n "${OLD_ID:-}" ]; then
      check "round 2's compacted_from_thread equals the pre-existing OLD thread's own id" \
        "$(jq -r '.compacted_from_thread // ""' <<<"$ROUND2_LINE")" "$OLD_ID"
    fi

    check "round 2's line HAS compaction_attempt_failed_thread" \
      "$(jq -r 'has("compaction_attempt_failed_thread")' <<<"$ROUND2_LINE")" "true"
    # Mechanical value check, not just presence (Task 24's lesson): the array must be EXACTLY
    # one element -- candidate A's own id -- never B's, never OLD's, never a 2-element array.
    FAILED_THREAD_LEN="$(jq -r '.compaction_attempt_failed_thread | length' <<<"$ROUND2_LINE")"
    check "round 2's compaction_attempt_failed_thread array has EXACTLY 1 element" "$FAILED_THREAD_LEN" "1"
    if [ -n "${A_ID:-}" ]; then
      check "round 2's compaction_attempt_failed_thread[0] equals candidate A's own id" \
        "$(jq -r '.compaction_attempt_failed_thread[0] // ""' <<<"$ROUND2_LINE")" "$A_ID"
    fi
    if [ -n "${B_ID:-}" ]; then
      FAILED_CONTAINS_B="$(jq -r --arg b "$B_ID" '.compaction_attempt_failed_thread | contains([$b])' <<<"$ROUND2_LINE")"
      check "round 2's compaction_attempt_failed_thread does NOT contain B's own (successful) id" "$FAILED_CONTAINS_B" "false"
    fi

    check "round 2's line HAS compaction_attempt_execution (A's own 3 failed attempts' telemetry)" \
      "$(jq -r 'has("compaction_attempt_execution")' <<<"$ROUND2_LINE")" "true"
    EXECUTION_LEN="$(jq -r '.compaction_attempt_execution | length' <<<"$ROUND2_LINE")"
    check "round 2's compaction_attempt_execution array has exactly 3 entries (A's fresh attempt + 2 resume retries)" "$EXECUTION_LEN" "3"

    check "round 2's line HAS compaction_attempt_failure_count (reset to 0 on this round's own success)" \
      "$(jq -r 'has("compaction_attempt_failure_count")' <<<"$ROUND2_LINE")" "true"
    check "round 2's compaction_attempt_failure_count value" \
      "$(jq -r '.compaction_attempt_failure_count // -1' <<<"$ROUND2_LINE")" "0"

    check "round 2's line HAS candidate_snapshot_path" \
      "$(jq -r 'has("candidate_snapshot_path")' <<<"$ROUND2_LINE")" "true"
    check "round 2's line HAS snapshot_digest_before" \
      "$(jq -r 'has("snapshot_digest_before")' <<<"$ROUND2_LINE")" "true"
    check "round 2's line HAS snapshot_digest_after" \
      "$(jq -r 'has("snapshot_digest_after")' <<<"$ROUND2_LINE")" "true"
  fi
fi

exit "$FAIL"

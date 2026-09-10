#!/usr/bin/env bash
# Scenario-specific assertions for compact-baseline-still-over-threshold, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure already validated by
# check-result.sh itself before this runs.
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-compact-baseline-still-over-threshold-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "compact-baseline-still-over-threshold: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "3"

CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==current" "$CURRENT_COUNT" "1"
LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked" "$LEAKED_COUNT" "1"

NOT_DELETED="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED" != "0" ]; then
  echo "compact-baseline-still-over-threshold: FAIL -- expected every threads[] entry cleanup==deleted, found $NOT_DELETED that aren't" >&2
  FAIL=1
fi

CURRENT_ID="$(jq -r '[.threads[]? | select(.kind == "current")][0].thread_id // ""' "$RESULT_FILE")"
LEAKED_ID="$(jq -r '[.threads[]? | select(.kind == "leaked")][0].thread_id // ""' "$RESULT_FILE")"
if [ -n "$CURRENT_ID" ] && [ -n "$LEAKED_ID" ] && [ "$CURRENT_ID" = "$LEAKED_ID" ]; then
  echo "compact-baseline-still-over-threshold: FAIL -- current and leaked thread_id must differ, both are [$CURRENT_ID]" >&2
  FAIL=1
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  # This is a controlled synthetic run (setup.sh creates this log deterministically), never a
  # live/flaky dispatch -- unlike a real production /ccs run, a missing log here means the
  # fixture harness itself is broken, so it must FAIL, not WARN-and-skip. Skipping would let a
  # result.json with plausible thread metadata pass this whole scenario without ever proving the
  # actual dispatch-mode/no-second-compaction-attempt behavior.
  echo "compact-baseline-still-over-threshold: FAIL -- invocation log not found at $INVOCATION_LOG (setup.sh should always create this for this scenario)" >&2
  FAIL=1
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count" "$FRESH_COUNT" "2"
  check "invocation log resume-mode count (round 3 only -- no second compaction attempt)" "$RESUME_COUNT" "1"

  # Causal linkage, not just aggregate counts: tie round 1's/round 2's fresh thread_ids to
  # current/leaked in ORDER (the same lesson Task 23's own fix round applied), THEN tie round 3's
  # single resume dispatch to the SAME thread the compaction round promoted -- the specific,
  # observable proof that round 3 continued off the compaction round's own thread rather than
  # merely "some resume happened, against some thread, somewhere."
  FRESH_IDS_ORDERED="$(grep '^mode=fresh ' "$INVOCATION_LOG" | sed -E 's/^mode=fresh thread_id=([^ ]*).*/\1/')"
  FRESH_DISTINCT_IDS="$(echo "$FRESH_IDS_ORDERED" | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across the 2 fresh invocations" "$FRESH_DISTINCT_IDS" "2"

  FIRST_FRESH_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '1p')"
  SECOND_FRESH_ID="$(echo "$FRESH_IDS_ORDERED" | sed -n '2p')"
  check "leaked thread_id matches the FIRST fresh dispatch (round 1's abandoned thread A)" "$LEAKED_ID" "$FIRST_FRESH_ID"
  check "current thread_id matches the SECOND fresh dispatch (round 2's compaction thread B, the one whose own baseline latched the guard)" "$CURRENT_ID" "$SECOND_FRESH_ID"

  RESUME_ID="$(grep '^mode=resume ' "$INVOCATION_LOG" | sed -E 's/^mode=resume thread_id=([^ ]*).*/\1/' | sed -n '1p')"
  check "round 3's resume dispatch targets thread B specifically (current), not A, and not a third fresh thread" "$RESUME_ID" "$CURRENT_ID"
fi

# Verify the actual CAUSE, not just the downstream dispatch-pattern effect: thread
# continuity/counts alone can't rule out a buggy implementation that unconditionally disables
# compaction after ANY successful restart -- read the session's own JSONL log (sibling of
# RESULT_FILE, same <session-id> basename, per the same convention flags-capture-only/expect.sh
# already uses) and confirm round 2's OWN line -- not round 1's, not round 3's -- is the one
# that recorded the latch, with the correct reason.
RESULT_DIR="$(dirname "$RESULT_FILE")"
SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
JSONL_FILE="$RESULT_DIR/$SESSION_ID.jsonl"

if [ ! -f "$JSONL_FILE" ]; then
  echo "compact-baseline-still-over-threshold: FAIL -- expected sibling JSONL log at $JSONL_FILE, not found" >&2
  FAIL=1
else
  ROUND1_LINE="$(jq -c 'select(.round == 1)' "$JSONL_FILE" | head -n 1)"
  ROUND2_LINE="$(jq -c 'select(.round == 2)' "$JSONL_FILE" | head -n 1)"
  ROUND3_LINE="$(jq -c 'select(.round == 3)' "$JSONL_FILE" | head -n 1)"

  if [ -z "$ROUND1_LINE" ] || [ -z "$ROUND2_LINE" ] || [ -z "$ROUND3_LINE" ]; then
    echo "compact-baseline-still-over-threshold: FAIL -- expected round 1, 2, and 3 lines all present in $JSONL_FILE" >&2
    FAIL=1
  else
    check "round 1's line does NOT carry compaction_disabled_reason (never mis-attributed to the TRIGGERING round)" \
      "$(jq -r 'has("compaction_disabled_reason")' <<<"$ROUND1_LINE")" "false"

    check "round 2's line HAS compaction_disabled_reason (the compaction round's OWN baseline latched it)" \
      "$(jq -r 'has("compaction_disabled_reason")' <<<"$ROUND2_LINE")" "true"
    check "round 2's compaction_disabled_reason value" \
      "$(jq -r '.compaction_disabled_reason // ""' <<<"$ROUND2_LINE")" "baseline_at_or_above_threshold"

    check "round 3's line does NOT re-carry compaction_disabled_reason (latch is read forward, not re-recorded)" \
      "$(jq -r 'has("compaction_disabled_reason")' <<<"$ROUND3_LINE")" "false"
    check "round 3's line has no compacted_from_thread (no second compaction attempt, local re-collection included)" \
      "$(jq -r 'has("compacted_from_thread")' <<<"$ROUND3_LINE")" "false"
    check "round 3's line has no candidate_snapshot_path (no second compaction attempt, local re-collection included)" \
      "$(jq -r 'has("candidate_snapshot_path")' <<<"$ROUND3_LINE")" "false"
  fi
fi

exit "$FAIL"

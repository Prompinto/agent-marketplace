#!/usr/bin/env bash
# Scenario-specific assertions for compact-byte-budget-exceeded, invoked by check-result.sh as
# `expect.sh <result.json>`. Schema structure already validated by check-result.sh itself before
# this runs.
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-compact-byte-budget-exceeded-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "compact-byte-budget-exceeded: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "2"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "total threads[] count (never a second thread for a byte-budget-only failure)" "$THREAD_COUNT" "1"

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked (must be zero)" "$LEAKED_COUNT" "0"

CURRENT_ID="$(jq -r '.threads[0].thread_id // ""' "$RESULT_FILE")"
CLEANUP="$(jq -r '.threads[0].cleanup' "$RESULT_FILE")"
check "the one thread's cleanup" "$CLEANUP" "deleted"

# This is a controlled synthetic run (setup.sh creates this log deterministically), never a
# live/flaky dispatch -- unlike a real production /ccs run, a missing log here means the fixture
# harness itself is broken, so it must FAIL, not WARN-and-skip (the lesson
# compact-baseline-still-over-threshold's own fix round already applied). Skipping would let a
# result.json with plausible thread metadata pass this whole scenario without ever proving the
# actual "no real dispatch for the compaction attempt" behavior this scenario exists to check.
if [ ! -f "$INVOCATION_LOG" ]; then
  echo "compact-byte-budget-exceeded: FAIL -- invocation log not found at $INVOCATION_LOG (setup.sh should always create this for this scenario)" >&2
  FAIL=1
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count (round 1 only -- compaction attempt never dispatched)" "$FRESH_COUNT" "1"
  check "invocation log resume-mode count (round 2's fallback)" "$RESUME_COUNT" "1"

  # Causal linkage, not just aggregate counts (the lesson both prior scenarios' own fix rounds
  # applied): tie the single fresh dispatch's thread_id to the single resume dispatch's
  # thread_id AND to the final result's own current thread -- the specific, observable proof
  # that round 2's fallback resumed the SAME thread A that round 1 opened, never a different or
  # newly-minted thread.
  FRESH_ID="$(grep '^mode=fresh ' "$INVOCATION_LOG" | sed -E 's/^mode=fresh thread_id=([^ ]*).*/\1/' | sed -n '1p')"
  RESUME_ID="$(grep '^mode=resume ' "$INVOCATION_LOG" | sed -E 's/^mode=resume thread_id=([^ ]*).*/\1/' | sed -n '1p')"
  check "round 2's resume dispatch targets the SAME thread round 1 opened (A), not a different one" "$RESUME_ID" "$FRESH_ID"
  check "the result's own current thread_id matches the single fresh dispatch (A) -- never replaced" "$CURRENT_ID" "$FRESH_ID"
fi

# Verify the actual CAUSE and its NEGATIVE claim, not just the downstream dispatch-pattern
# effect: thread continuity/counts alone can't rule out a buggy implementation that happens to
# fall back to --resume for some unrelated reason while never actually latching
# byte_budget_exceeded, or one that incorrectly increments compaction_attempt_failure_count for
# this specific cause. Read the session's own JSONL log (sibling of RESULT_FILE, same
# <session-id> basename, per the same convention flags-capture-only/expect.sh and
# compact-baseline-still-over-threshold/expect.sh already use) and confirm round 2's OWN line --
# not round 1's -- is the one that recorded the latch, with the correct reason, and without the
# fields a real compaction attempt/promotion would have left behind.
RESULT_DIR="$(dirname "$RESULT_FILE")"
SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
JSONL_FILE="$RESULT_DIR/$SESSION_ID.jsonl"

if [ ! -f "$JSONL_FILE" ]; then
  echo "compact-byte-budget-exceeded: FAIL -- expected sibling JSONL log at $JSONL_FILE, not found" >&2
  FAIL=1
else
  ROUND1_LINE="$(jq -c 'select(.round == 1)' "$JSONL_FILE" | head -n 1)"
  ROUND2_LINE="$(jq -c 'select(.round == 2)' "$JSONL_FILE" | head -n 1)"

  if [ -z "$ROUND1_LINE" ] || [ -z "$ROUND2_LINE" ]; then
    echo "compact-byte-budget-exceeded: FAIL -- expected round 1 and round 2 lines both present in $JSONL_FILE" >&2
    FAIL=1
  else
    check "round 1's line does NOT carry compaction_disabled_reason (never mis-attributed to the TRIGGERING round)" \
      "$(jq -r 'has("compaction_disabled_reason")' <<<"$ROUND1_LINE")" "false"

    check "round 2's line HAS compaction_disabled_reason (the byte-budget preflight latched it)" \
      "$(jq -r 'has("compaction_disabled_reason")' <<<"$ROUND2_LINE")" "true"
    check "round 2's compaction_disabled_reason value" \
      "$(jq -r '.compaction_disabled_reason // ""' <<<"$ROUND2_LINE")" "byte_budget_exceeded"

    check "round 2's line has NO compaction_attempt_failure_count (byte-budget latch never increments this counter)" \
      "$(jq -r 'has("compaction_attempt_failure_count")' <<<"$ROUND2_LINE")" "false"
    check "round 2's line has NO compacted_from_thread (no candidate was ever promoted -- the attempt never dispatched)" \
      "$(jq -r 'has("compacted_from_thread")' <<<"$ROUND2_LINE")" "false"
  fi
fi

exit "$FAIL"

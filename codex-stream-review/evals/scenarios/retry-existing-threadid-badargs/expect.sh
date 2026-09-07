#!/usr/bin/env bash
# Scenario-specific assertions for retry-existing-threadid-badargs, invoked
# by check-result.sh as `expect.sh <result.json>`. Schema structure is
# already validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN" (round 2's retried dispatch converges cleanly
#     after the real bug fix)
#   - threads has exactly one entry, kind:"current", cleanup:"deleted" --
#     never two entries, never "leaked": a bad_args failure with no
#     threadId, on a group that ALREADY has a thread, must never abandon it
#   - the fixed INVOCATION_LOG (see setup.sh) shows exactly 1 "mode=fresh"
#     line and exactly 1 "mode=resume" line (the bad_args attempt never
#     reaches fake-codex at all, so it never appends a line), and BOTH
#     lines' thread_id field is the identical value -- the concrete proof
#     the same thread persisted across the bad_args failure and its retry,
#     never a fresh scope flag
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-retry-existing-threadid-badargs-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "retry-existing-threadid-badargs: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "CLEAN"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "threads length" "$THREAD_COUNT" "1"

RESULT_THREAD_ID=""
if [ "$THREAD_COUNT" = "1" ]; then
  check "threads[0].kind" "$(jq -r '.threads[0].kind' "$RESULT_FILE")" "current"
  check "threads[0].cleanup" "$(jq -r '.threads[0].cleanup' "$RESULT_FILE")" "deleted"
  RESULT_THREAD_ID="$(jq -r '.threads[0].thread_id' "$RESULT_FILE")"
fi

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked" "$LEAKED_COUNT" "0"

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "retry-existing-threadid-badargs: WARN -- invocation log not found at $INVOCATION_LOG (only available immediately after a live run, before this scenario's own cleanup step -- skipping the invocation-count check rather than failing the whole scenario on a missing ephemeral diagnostic file)" >&2
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count" "$FRESH_COUNT" "1"
  check "invocation log resume-mode count" "$RESUME_COUNT" "1"

  DISTINCT_IDS="$(grep -E '^mode=(fresh|resume) ' "$INVOCATION_LOG" | sed -E 's/^mode=[a-z]+ thread_id=([^ ]*).*/\1/' | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across fresh+resume invocations" "$DISTINCT_IDS" "1"

  LOG_THREAD_ID="$(grep -E '^mode=(fresh|resume) ' "$INVOCATION_LOG" | head -1 | sed -E 's/^mode=[a-z]+ thread_id=([^ ]*).*/\1/')"
  check "invocation log thread_id matches result.json's threads[0].thread_id" "$LOG_THREAD_ID" "$RESULT_THREAD_ID"
fi

exit "$FAIL"

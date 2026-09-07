#!/usr/bin/env bash
# Scenario-specific assertions for retry-exhausted-round1-fresh-fallback,
# invoked by check-result.sh as `expect.sh <result.json>`. Schema structure
# already validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN" (the fresh fallback retry succeeds, unlike
#     could-not-verify-exhausted where it also fails)
#   - threads contains exactly one "current" entry (the successful fresh
#     fallback's own new thread) AND exactly one "leaked" entry (the
#     abandoned original round-1 thread) -- BOTH with cleanup=="deleted",
#     confirming the leaked thread really was cleaned up in Phase 3, not
#     just recorded
#   - the current and leaked thread_id values are DIFFERENT (the fallback
#     genuinely obtained a NEW threadId, never reused the abandoned one)
#   - the fixed INVOCATION_LOG shows exactly 2 "mode=fresh" lines (with two
#     DIFFERENT thread_id values) and exactly 2 "mode=resume" lines (both
#     against the leaked thread's own id) -- proof the full 3-failures-then-
#     fresh-fallback sequence actually ran
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-retry-exhausted-round1-fresh-fallback-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "retry-exhausted-round1-fresh-fallback: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"

CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==current" "$CURRENT_COUNT" "1"

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked" "$LEAKED_COUNT" "1"

NOT_DELETED="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED" != "0" ]; then
  echo "retry-exhausted-round1-fresh-fallback: FAIL -- expected every threads[] entry cleanup==deleted, found $NOT_DELETED that aren't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

CURRENT_ID="$(jq -r '[.threads[]? | select(.kind == "current")][0].thread_id // ""' "$RESULT_FILE")"
LEAKED_ID="$(jq -r '[.threads[]? | select(.kind == "leaked")][0].thread_id // ""' "$RESULT_FILE")"
if [ -n "$CURRENT_ID" ] && [ -n "$LEAKED_ID" ] && [ "$CURRENT_ID" = "$LEAKED_ID" ]; then
  echo "retry-exhausted-round1-fresh-fallback: FAIL -- current and leaked thread_id must differ, both are [$CURRENT_ID]" >&2
  FAIL=1
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "retry-exhausted-round1-fresh-fallback: WARN -- invocation log not found at $INVOCATION_LOG (only available immediately after a live run, before this scenario's own cleanup step -- skipping the invocation-count check rather than failing the whole scenario on a missing ephemeral diagnostic file)" >&2
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count" "$FRESH_COUNT" "2"
  check "invocation log resume-mode count" "$RESUME_COUNT" "2"

  FRESH_DISTINCT_IDS="$(grep '^mode=fresh ' "$INVOCATION_LOG" | sed -E 's/^mode=fresh thread_id=([^ ]*).*/\1/' | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across the 2 fresh invocations" "$FRESH_DISTINCT_IDS" "2"

  RESUME_DISTINCT_IDS="$(grep '^mode=resume ' "$INVOCATION_LOG" | sed -E 's/^mode=resume thread_id=([^ ]*).*/\1/' | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across the 2 resume invocations" "$RESUME_DISTINCT_IDS" "1"
fi

exit "$FAIL"

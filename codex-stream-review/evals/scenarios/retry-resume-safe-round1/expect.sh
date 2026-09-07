#!/usr/bin/env bash
# Scenario-specific assertions for retry-resume-safe-round1, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure (coverage
# must be an object for target.scope=uncommitted) is already validated by
# check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN", round_count == 1
#   - threads has exactly one entry, kind:"current", cleanup:"deleted" --
#     no "leaked" entry (the bounded resume retry succeeded first try)
#   - coverage is NOT the {"status":"unknown"} sentinel -- real coverage
#     data was genuinely captured from the FAILED round-1 attempt before its
#     retry, per retry-guards.md's "Round 1 only -- capture coverage from
#     the failing attempt BEFORE retrying" note (this is the whole point of
#     this scenario: the eventual successful response is a --resume, which
#     never reports coverage itself, so this is the only place it could have
#     come from)
#   - the fixed INVOCATION_LOG shows exactly 1 "mode=fresh" and exactly 1
#     "mode=resume" line, sharing the same thread_id
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-retry-resume-safe-round1-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "retry-resume-safe-round1: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "1"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "threads length" "$THREAD_COUNT" "1"
if [ "$THREAD_COUNT" = "1" ]; then
  check "threads[0].kind" "$(jq -r '.threads[0].kind' "$RESULT_FILE")" "current"
  check "threads[0].cleanup" "$(jq -r '.threads[0].cleanup' "$RESULT_FILE")" "deleted"
fi

COVERAGE_IS_SENTINEL="$(jq -r '(.coverage.status == "unknown" and (.coverage.omitted // []) == [] and (.coverage | keys_unsorted | length) <= 2)' "$RESULT_FILE")"
if [ "$COVERAGE_IS_SENTINEL" = "true" ]; then
  echo "retry-resume-safe-round1: FAIL -- coverage looks like the {status:unknown} sentinel; expected real coverage captured from the failed round-1 attempt" >&2
  FAIL=1
fi
COVERAGE_STATUS="$(jq -r '.coverage.status' "$RESULT_FILE")"
if [ "$COVERAGE_STATUS" = "unknown" ] || [ "$COVERAGE_STATUS" = "null" ] || [ -z "$COVERAGE_STATUS" ]; then
  echo "retry-resume-safe-round1: FAIL -- coverage.status expected a real value (e.g. complete), got [$COVERAGE_STATUS]" >&2
  FAIL=1
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "retry-resume-safe-round1: WARN -- invocation log not found at $INVOCATION_LOG (only available immediately after a live run, before this scenario's own cleanup step -- skipping the invocation-count check rather than failing the whole scenario on a missing ephemeral diagnostic file)" >&2
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count" "$FRESH_COUNT" "1"
  check "invocation log resume-mode count" "$RESUME_COUNT" "1"
  DISTINCT_IDS="$(grep -E '^mode=(fresh|resume) ' "$INVOCATION_LOG" | sed -E 's/^mode=[a-z]+ thread_id=([^ ]*).*/\1/' | sort -u | wc -l | tr -d ' ')"
  check "distinct thread_id values across fresh+resume invocations" "$DISTINCT_IDS" "1"
fi

exit "$FAIL"

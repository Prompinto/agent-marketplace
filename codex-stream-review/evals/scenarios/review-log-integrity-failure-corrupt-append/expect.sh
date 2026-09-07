#!/usr/bin/env bash
# Scenario-specific assertions for
# review-log-integrity-failure-corrupt-append, invoked by check-result.sh as
# `expect.sh <result.json>`. Schema structure (claims must be null,
# input_errors must be null, for this exit_state) is already validated by
# check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "REVIEW_LOG_INTEGRITY_FAILURE"
#   - claims == null
#   - round_count == 0 (no round's own line was ever durably logged this
#     run -- distinct from snapshot-integrity-failure's round_count 1, and
#     from review-log-integrity-failure-stale-schema's round_count 1 too --
#     this is the one concrete signature that THIS specific trigger, a
#     round's own append genuinely failing, is what actually fired, not the
#     other stale-schema trigger which fails before any append is even
#     attempted this run but against a session with a real prior round)
#   - at least one thread, every thread cleanup == "deleted"
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "review-log-integrity-failure-corrupt-append: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "REVIEW_LOG_INTEGRITY_FAILURE"

CLAIMS="$(jq -r '.claims' "$RESULT_FILE")"
check "claims" "$CLAIMS" "null"

ROUND_COUNT="$(jq -r '.round_count' "$RESULT_FILE")"
check "round_count" "$ROUND_COUNT" "0"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
if [ "$THREAD_COUNT" -lt 1 ]; then
  echo "review-log-integrity-failure-corrupt-append: FAIL -- expected at least one thread, got $THREAD_COUNT" >&2
  FAIL=1
fi

NOT_DELETED_COUNT="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED_COUNT" -ne 0 ]; then
  echo "review-log-integrity-failure-corrupt-append: FAIL -- expected every threads[] entry to have cleanup==deleted, found $NOT_DELETED_COUNT that don't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

exit "$FAIL"

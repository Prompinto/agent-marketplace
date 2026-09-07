#!/usr/bin/env bash
# Scenario-specific assertions for could-not-verify-exhausted, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure (claims must
# be an array, not null, for this exit_state) is already validated by
# check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "COULD_NOT_VERIFY"
#   - claims is an empty array (no round ever completed a real review, so
#     nothing was ever raised to track)
#   - at least one thread is marked "leaked" (the original round-1 thread,
#     abandoned once both bounded resume-retries were exhausted) and at
#     least one is marked "current" (the final fresh-fallback retry's own
#     thread) -- confirms the retry sequence genuinely ran its full course
#     rather than stopping after the very first failure
#   - every thread's cleanup == "deleted" -- confirms Phase 3's
#     unconditional cleanup-even-on-failure rule actually ran, for both the
#     current AND the leaked thread, not just left them dangling
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "could-not-verify-exhausted: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "COULD_NOT_VERIFY"

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "0"

CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
if [ "$CURRENT_COUNT" -lt 1 ]; then
  echo "could-not-verify-exhausted: FAIL -- expected at least one threads[] entry with kind==current, got $CURRENT_COUNT" >&2
  FAIL=1
fi

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
if [ "$LEAKED_COUNT" -lt 1 ]; then
  echo "could-not-verify-exhausted: FAIL -- expected at least one threads[] entry with kind==leaked (the abandoned round-1 thread), got $LEAKED_COUNT" >&2
  FAIL=1
fi

NOT_DELETED_COUNT="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED_COUNT" -ne 0 ]; then
  echo "could-not-verify-exhausted: FAIL -- expected every threads[] entry to have cleanup==deleted, found $NOT_DELETED_COUNT that don't" >&2
  jq -c '.threads[]? | select(.cleanup != "deleted")' "$RESULT_FILE" >&2
  FAIL=1
fi

exit "$FAIL"

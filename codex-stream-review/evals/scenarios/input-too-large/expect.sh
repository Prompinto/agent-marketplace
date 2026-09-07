#!/usr/bin/env bash
# Scenario-specific assertions for input-too-large, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure (including
# the INPUT_TOO_LARGE conditional -- input_errors must be a non-empty array)
# is already validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "INPUT_TOO_LARGE"
#   - input_errors is non-empty (schema-check.jq already enforces this, but
#     re-asserted here so this file fails loudly and specifically even if
#     schema-check.jq's own conditional were ever loosened)
#   - no thread is ever marked "leaked" -- a fresh round-1 artifact_too_large
#     failure never obtains a threadId at all (see setup.sh's header comment),
#     so LEAKED_THREAD_IDS must stay empty; this is the one concrete,
#     checkable signature that the wrapper's preflight really did fire before
#     any dispatch/thread-abandonment logic ever ran
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "input-too-large: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "INPUT_TOO_LARGE"

INPUT_ERRORS_COUNT="$(jq -r '.input_errors | length' "$RESULT_FILE")"
if [ "$INPUT_ERRORS_COUNT" -lt 1 ]; then
  echo "input-too-large: FAIL -- input_errors: expected a non-empty array, got length $INPUT_ERRORS_COUNT" >&2
  FAIL=1
fi

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked" "$LEAKED_COUNT" "0"

exit "$FAIL"

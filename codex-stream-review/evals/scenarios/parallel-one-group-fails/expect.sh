#!/usr/bin/env bash
# Scenario-specific assertions for parallel-one-group-fails. Schema
# structure already validated by check-result.sh's schema-check.jq.
#
#   - exit_state == "COULD_NOT_VERIFY" (worst-case-wins: g1's exhausted
#     retries force this even though g2 individually converged clean)
#   - at least one thread marked "leaked" (g1's abandoned round-1 thread)
#     and at least two marked "current" (g1's fresh-fallback thread + g2's
#     own successful thread)
#   - every thread's cleanup == "deleted"
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "parallel-one-group-fails: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
if [ "$EXIT_STATE" = "CLEAN" ]; then
  echo "parallel-one-group-fails: FAIL -- exit_state: expected anything but CLEAN, got CLEAN" >&2
  FAIL=1
fi
check "exit_state" "$EXIT_STATE" "COULD_NOT_VERIFY"

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
if [ "$LEAKED_COUNT" -lt 1 ]; then
  echo "parallel-one-group-fails: FAIL -- expected at least one threads[] entry with kind==leaked, got $LEAKED_COUNT" >&2
  FAIL=1
fi

CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
if [ "$CURRENT_COUNT" -lt 2 ]; then
  echo "parallel-one-group-fails: FAIL -- expected at least two threads[] entries with kind==current (g1's fresh-fallback + g2's own), got $CURRENT_COUNT" >&2
  FAIL=1
fi

NOT_DELETED_COUNT="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
if [ "$NOT_DELETED_COUNT" -ne 0 ]; then
  echo "parallel-one-group-fails: FAIL -- expected every threads[] entry to have cleanup==deleted, found $NOT_DELETED_COUNT that don't" >&2
  FAIL=1
fi

exit "$FAIL"

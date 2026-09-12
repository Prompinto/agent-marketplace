#!/usr/bin/env bash
# Scenario-specific assertions for retry-no-threadid-fresh, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure is already
# validated by check-result.sh's own schema validation step before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state is a real terminal status (CLEAN, since fake-codex's
#     default scripted verdict has no findings) -- never COULD_NOT_VERIFY or
#     an integrity-failure status, any of which would mean the retry path
#     was never actually exercised successfully
#   - threads has exactly one entry, kind:"current", cleanup:"deleted" --
#     no "leaked" entry, since the failing first attempt never obtained a
#     threadId at all (no_thread_started never carries one)
#   - the fixed INVOCATION_LOG (see setup.sh) shows exactly 2 "mode=fresh"
#     lines for this run and zero "mode=resume" lines -- the only reliable
#     proof that the retry path actually fired twice, not once
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-retry-no-threadid-fresh-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "retry-no-threadid-fresh: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
if [ "$EXIT_STATE" = "COULD_NOT_VERIFY" ] || [ "$EXIT_STATE" = "SNAPSHOT_INTEGRITY_FAILURE" ] || [ "$EXIT_STATE" = "REVIEW_LOG_INTEGRITY_FAILURE" ]; then
  echo "retry-no-threadid-fresh: FAIL -- exit_state [$EXIT_STATE] means the retry path never reached a real reviewed verdict" >&2
  FAIL=1
fi

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "threads length" "$THREAD_COUNT" "1"
if [ "$THREAD_COUNT" = "1" ]; then
  check "threads[0].kind" "$(jq -r '.threads[0].kind' "$RESULT_FILE")" "current"
  check "threads[0].cleanup" "$(jq -r '.threads[0].cleanup' "$RESULT_FILE")" "deleted"
fi

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked" "$LEAKED_COUNT" "0"

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "retry-no-threadid-fresh: WARN -- invocation log not found at $INVOCATION_LOG (only available immediately after a live run, before this scenario's own cleanup step -- skipping the invocation-count check rather than failing the whole scenario on a missing ephemeral diagnostic file)" >&2
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count" "$FRESH_COUNT" "2"
  check "invocation log resume-mode count" "$RESUME_COUNT" "0"
fi

exit "$FAIL"

#!/usr/bin/env bash
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-compact-clean-repo-dir-polluted-invocation.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "compact-clean-repo-dir-polluted: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "2"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "total threads[] count (compaction attempt never dispatched, never created a thread)" "$THREAD_COUNT" "1"

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
check "count of threads[] with kind==leaked (must be zero)" "$LEAKED_COUNT" "0"

CLEANUP="$(jq -r '.threads[0].cleanup' "$RESULT_FILE")"
check "the one thread's cleanup" "$CLEANUP" "deleted"

# target.scope for a non-repo-artifact session is still "uncommitted" (it dispatches AS
# --uncommitted against CLEAN_REPO_DIR under the hood, per references/non-repo-artifact.md).
check "target.scope" "$(jq -r '.target.scope' "$RESULT_FILE")" "uncommitted"

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "compact-clean-repo-dir-polluted: WARN -- invocation log not found at $INVOCATION_LOG (ephemeral, skipping)" >&2
else
  FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
  RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
  check "invocation log fresh-mode count (round 1 only -- compaction never dispatched)" "$FRESH_COUNT" "1"
  check "invocation log resume-mode count (round 2's fallback)" "$RESUME_COUNT" "1"
fi

exit "$FAIL"

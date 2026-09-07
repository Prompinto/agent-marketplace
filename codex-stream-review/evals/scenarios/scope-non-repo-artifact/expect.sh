#!/usr/bin/env bash
# Scenario-specific assertions for scope-non-repo-artifact, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure is already
# validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN", round_count == 1, one thread (current/deleted)
#   - target.scope == "uncommitted" -- a non-repo-artifact round always
#     dispatches --uncommitted against CLEAN_REPO_DIR, never --base/--commit
#     (references/non-repo-artifact.md; there is no commit to diff against)
#   - coverage.status == "complete" with coverage.reviewed_file_count == 0
#     -- the documented zero-file-but-still-complete CLEAN_REPO_DIR case
#   - FAKE_CODEX_INVOCATION_LOG recorded exactly 2 invocations: fresh then
#     delete (this round is always single-group, never parallel)
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-scope-non-repo-artifact-invocations.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "scope-non-repo-artifact: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "CLEAN"

ROUND_COUNT="$(jq -r '.round_count' "$RESULT_FILE")"
check "round_count" "$ROUND_COUNT" "1"

check "target.scope" "$(jq -r '.target.scope' "$RESULT_FILE")" "uncommitted"

COVERAGE_TYPE="$(jq -r '.coverage | type' "$RESULT_FILE")"
check "coverage type" "$COVERAGE_TYPE" "object"
if [ "$COVERAGE_TYPE" = "object" ]; then
  check "coverage.status" "$(jq -r '.coverage.status' "$RESULT_FILE")" "complete"
  check "coverage.reviewed_file_count" "$(jq -r '.coverage.reviewed_file_count' "$RESULT_FILE")" "0"
fi

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "threads length" "$THREAD_COUNT" "1"
if [ "$THREAD_COUNT" = "1" ]; then
  check "threads[0].kind" "$(jq -r '.threads[0].kind' "$RESULT_FILE")" "current"
  check "threads[0].cleanup" "$(jq -r '.threads[0].cleanup' "$RESULT_FILE")" "deleted"
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "scope-non-repo-artifact: FAIL -- expected fake-codex invocation log at $INVOCATION_LOG, not found" >&2
  FAIL=1
else
  INVOCATION_COUNT="$(wc -l < "$INVOCATION_LOG" | tr -d ' ')"
  check "fake-codex invocation count" "$INVOCATION_COUNT" "2"
  SEQUENCE="$(cut -d' ' -f1 "$INVOCATION_LOG" | paste -sd, -)"
  check "fake-codex invocation sequence" "$SEQUENCE" "mode=fresh,mode=delete"
fi

exit "$FAIL"

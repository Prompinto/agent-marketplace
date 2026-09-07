#!/usr/bin/env bash
# Scenario-specific assertions for scope-base-ref, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure (including
# the target.scope==base => coverage-must-be-null conditional) is already
# validated by check-result.sh itself before this runs -- re-asserted here
# so this file fails loudly and specifically.
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-scope-base-ref-invocations.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "scope-base-ref: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "CLEAN"

check "target.scope" "$(jq -r '.target.scope' "$RESULT_FILE")" "base"

COVERAGE="$(jq -c '.coverage' "$RESULT_FILE")"
check "coverage" "$COVERAGE" "null"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "threads length" "$THREAD_COUNT" "1"
if [ "$THREAD_COUNT" = "1" ]; then
  check "threads[0].kind" "$(jq -r '.threads[0].kind' "$RESULT_FILE")" "current"
  check "threads[0].cleanup" "$(jq -r '.threads[0].cleanup' "$RESULT_FILE")" "deleted"
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "scope-base-ref: FAIL -- expected fake-codex invocation log at $INVOCATION_LOG, not found" >&2
  FAIL=1
else
  INVOCATION_COUNT="$(wc -l < "$INVOCATION_LOG" | tr -d ' ')"
  check "fake-codex invocation count" "$INVOCATION_COUNT" "2"
  SEQUENCE="$(cut -d' ' -f1 "$INVOCATION_LOG" | paste -sd, -)"
  check "fake-codex invocation sequence" "$SEQUENCE" "mode=fresh,mode=delete"
fi

exit "$FAIL"

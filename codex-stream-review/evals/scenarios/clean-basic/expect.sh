#!/usr/bin/env bash
# Scenario-specific assertions for clean-basic, invoked by check-result.sh as
# `expect.sh <result.json>`. Schema structure is already validated by
# check-result.sh's own schema validation step before this runs -- this file
# only asserts the things specific to THIS scenario's expected outcome.
#
# clean-basic targets exit_state=CLEAN on the simplest possible real /ccs
# dispatch: one round, fake-codex's default "normal" scenario (an
# always-CLEAN, no-findings verdict), single-reviewer mode, thread cleanup
# succeeding. Asserts:
#   - exit_state == "CLEAN"
#   - round_count == 1 (fake-codex's scripted CLEAN verdict converges on the
#     very first try, no retry/second round ever needed)
#   - threads[] has exactly one entry, kind:"current" (never "leaked" --
#     nothing here should ever abandon a thread), cleanup:"deleted" (the
#     wrapper's real --cleanup call against fake-codex, with
#     FAKE_CODEX_CLEANUP_OK set for this scenario's cleanup step, actually
#     succeeded)
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "clean-basic: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "CLEAN"

ROUND_COUNT="$(jq -r '.round_count' "$RESULT_FILE")"
check "round_count" "$ROUND_COUNT" "1"

THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
check "threads length" "$THREAD_COUNT" "1"

if [ "$THREAD_COUNT" = "1" ]; then
  check "threads[0].kind" "$(jq -r '.threads[0].kind' "$RESULT_FILE")" "current"
  check "threads[0].cleanup" "$(jq -r '.threads[0].cleanup' "$RESULT_FILE")" "deleted"
fi

exit "$FAIL"

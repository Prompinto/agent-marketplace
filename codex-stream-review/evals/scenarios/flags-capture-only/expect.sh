#!/usr/bin/env bash
# Scenario-specific assertions for flags-capture-only, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure is already
# validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN", round_count == 1, one thread (current/deleted)
#     -- same baseline shape as clean-basic, since this scenario is a CLEAN
#     run with capture-evidence layered on top, not a different control-flow
#     path
#   - the session's own JSONL log (sibling of the .result.json, same
#     directory, `<session-id>.jsonl`) has round 1's investigation_evidence
#     field populated with command_count == 2 and the two exact scripted
#     commands -- this is a JSONL-log-only field, never part of the durable
#     .result.json schema, so it must be checked by reading the log file
#     directly, not the result artifact
#   - FAKE_CODEX_INVOCATION_LOG recorded exactly 2 real invocations of the
#     fake binary, in sequence: fresh (round 1 dispatch), then delete
#     (Phase 3 cleanup) -- confirms the fake binary was actually invoked the
#     expected number of times, catching a silent PATH-injection failure
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-flags-capture-only-invocations.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "flags-capture-only: FAIL -- $desc: expected [$expected], got [$actual]" >&2
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

# Locate the sibling JSONL log: same directory as the .result.json, same
# <session-id> basename, .jsonl extension instead of .result.json.
RESULT_DIR="$(dirname "$RESULT_FILE")"
SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
JSONL_FILE="$RESULT_DIR/$SESSION_ID.jsonl"

if [ ! -f "$JSONL_FILE" ]; then
  echo "flags-capture-only: FAIL -- expected sibling JSONL log at $JSONL_FILE, not found" >&2
  FAIL=1
else
  ROUND1_LINE="$(jq -c 'select(.round == 1)' "$JSONL_FILE" | head -n 1)"
  if [ -z "$ROUND1_LINE" ]; then
    echo "flags-capture-only: FAIL -- no round-1 line found in $JSONL_FILE" >&2
    FAIL=1
  else
    HAS_FIELD="$(jq -r 'has("investigation_evidence")' <<<"$ROUND1_LINE")"
    check "round 1 has investigation_evidence" "$HAS_FIELD" "true"
    if [ "$HAS_FIELD" = "true" ]; then
      CMD_COUNT="$(jq -r '.investigation_evidence.command_count' <<<"$ROUND1_LINE")"
      check "investigation_evidence.command_count" "$CMD_COUNT" "2"
      COMMANDS_JSON="$(jq -c '.investigation_evidence.commands' <<<"$ROUND1_LINE")"
      EXPECTED_COMMANDS_JSON='["grep -rn \"def add\" lib.py","cat lib.py"]'
      check "investigation_evidence.commands" "$COMMANDS_JSON" "$EXPECTED_COMMANDS_JSON"
    fi
  fi
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "flags-capture-only: FAIL -- expected fake-codex invocation log at $INVOCATION_LOG, not found" >&2
  FAIL=1
else
  INVOCATION_COUNT="$(wc -l < "$INVOCATION_LOG" | tr -d ' ')"
  check "fake-codex invocation count" "$INVOCATION_COUNT" "2"
  SEQUENCE="$(cut -d' ' -f1 "$INVOCATION_LOG" | paste -sd, -)"
  check "fake-codex invocation sequence" "$SEQUENCE" "mode=fresh,mode=delete"
fi

exit "$FAIL"

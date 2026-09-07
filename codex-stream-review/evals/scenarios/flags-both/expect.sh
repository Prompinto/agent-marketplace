#!/usr/bin/env bash
# Scenario-specific assertions for flags-both, invoked by check-result.sh as
# `expect.sh <result.json>`. Schema structure is already validated by
# check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "CLEAN", round_count == 1, one thread (current/deleted)
#     -- keep-evidence's gate never applies to a CLEAN outcome, so normal
#     cleanup happens exactly like flags-capture-only/clean-basic
#   - the session's own JSONL log has round 1's investigation_evidence
#     populated -- same capture-evidence check as flags-capture-only,
#     confirming both flags' mechanics compose without interfering
#   - NO kept-evidence directory was created (round 1 succeeded, so its own
#     kept last-message file is simply deleted, never moved) -- the concrete
#     signature that keep-evidence's gate correctly stayed inert for a CLEAN
#     outcome, not merely that this scenario forgot to check
#   - FAKE_CODEX_INVOCATION_LOG recorded exactly 2 invocations: fresh then
#     delete
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-flags-both-invocations.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "flags-both: FAIL -- $desc: expected [$expected], got [$actual]" >&2
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

RESULT_DIR="$(dirname "$RESULT_FILE")"
SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
JSONL_FILE="$RESULT_DIR/$SESSION_ID.jsonl"

if [ ! -f "$JSONL_FILE" ]; then
  echo "flags-both: FAIL -- expected sibling JSONL log at $JSONL_FILE, not found" >&2
  FAIL=1
else
  ROUND1_LINE="$(jq -c 'select(.round == 1)' "$JSONL_FILE" | head -n 1)"
  if [ -z "$ROUND1_LINE" ]; then
    echo "flags-both: FAIL -- no round-1 line found in $JSONL_FILE" >&2
    FAIL=1
  else
    HAS_FIELD="$(jq -r 'has("investigation_evidence")' <<<"$ROUND1_LINE")"
    check "round 1 has investigation_evidence" "$HAS_FIELD" "true"
    if [ "$HAS_FIELD" = "true" ]; then
      CMD_COUNT="$(jq -r '.investigation_evidence.command_count' <<<"$ROUND1_LINE")"
      check "investigation_evidence.command_count" "$CMD_COUNT" "2"
    fi
  fi
fi

KEPT_DIR="$RESULT_DIR/$SESSION_ID-kept-evidence"
if [ -e "$KEPT_DIR" ]; then
  echo "flags-both: FAIL -- expected NO kept-evidence directory for a CLEAN outcome, found $KEPT_DIR" >&2
  FAIL=1
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "flags-both: FAIL -- expected fake-codex invocation log at $INVOCATION_LOG, not found" >&2
  FAIL=1
else
  INVOCATION_COUNT="$(wc -l < "$INVOCATION_LOG" | tr -d ' ')"
  check "fake-codex invocation count" "$INVOCATION_COUNT" "2"
  SEQUENCE="$(cut -d' ' -f1 "$INVOCATION_LOG" | paste -sd, -)"
  check "fake-codex invocation sequence" "$SEQUENCE" "mode=fresh,mode=delete"
fi

exit "$FAIL"

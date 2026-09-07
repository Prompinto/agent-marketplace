#!/usr/bin/env bash
# Scenario-specific assertions for flags-keep-only, invoked by
# check-result.sh as `expect.sh <result.json>`. Schema structure is already
# validated by check-result.sh itself before this runs.
#
# Asserts, per this scenario's README:
#   - exit_state == "COULD_NOT_VERIFY" (same forced-exhaustion outcome as
#     could-not-verify-exhausted, but with --keep-evidence ON)
#   - the keep-evidence Phase-3 gate actually fired: BOTH threads read
#     cleanup:"retained" (never "deleted") -- confirms Phase 3 steps 1-2
#     (the --cleanup loops) were genuinely skipped, not merely that
#     fake-codex's delete subcommand happened not to be called
#   - one thread is kind:"current" (B, the fresh fallback) and one is
#     kind:"leaked" (A, abandoned after both resume-retries exhausted) --
#     confirms the retry sequence still ran its full course under
#     --keep-evidence, same as the non-keep-evidence variant
#   - a kept last-message file exists at the durable
#     <session-id>-kept-evidence/round-1-main-lastmsg.txt path
#   - FAKE_CODEX_INVOCATION_LOG recorded exactly 4 real invocations, all
#     exec (fresh, resume, resume, fresh) and ZERO delete invocations --
#     confirms no --cleanup call was ever made, the concrete signature that
#     the keep-evidence gate suppressed Phase 3 steps 1-2 rather than the
#     gate silently not applying and cleanup just happening not to be logged
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"
INVOCATION_LOG="/tmp/ccs-eval-flags-keep-only-invocations.log"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "flags-keep-only: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

EXIT_STATE="$(jq -r '.exit_state' "$RESULT_FILE")"
check "exit_state" "$EXIT_STATE" "COULD_NOT_VERIFY"

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "0"

CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
if [ "$CURRENT_COUNT" -lt 1 ]; then
  echo "flags-keep-only: FAIL -- expected at least one threads[] entry with kind==current, got $CURRENT_COUNT" >&2
  FAIL=1
fi

LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
if [ "$LEAKED_COUNT" -lt 1 ]; then
  echo "flags-keep-only: FAIL -- expected at least one threads[] entry with kind==leaked, got $LEAKED_COUNT" >&2
  FAIL=1
fi

NOT_RETAINED_COUNT="$(jq -r '[.threads[]? | select(.cleanup != "retained")] | length' "$RESULT_FILE")"
if [ "$NOT_RETAINED_COUNT" -ne 0 ]; then
  echo "flags-keep-only: FAIL -- expected every threads[] entry to have cleanup==retained, found $NOT_RETAINED_COUNT that don't" >&2
  jq -c '.threads[]? | select(.cleanup != "retained")' "$RESULT_FILE" >&2
  FAIL=1
fi

# Kept last-message file: derive the durable kept-evidence directory from
# this session's own repo-slug + session_id, same naming as the .result.json
# itself (see references/keep-evidence.md's "Directory and file naming").
RESULT_DIR="$(dirname "$RESULT_FILE")"
SESSION_ID="$(jq -r '.session_id' "$RESULT_FILE")"
KEPT_FILE="$RESULT_DIR/$SESSION_ID-kept-evidence/round-1-main-lastmsg.txt"
if [ ! -e "$KEPT_FILE" ]; then
  echo "flags-keep-only: FAIL -- expected a kept last-message file at $KEPT_FILE, not found" >&2
  FAIL=1
fi

if [ ! -f "$INVOCATION_LOG" ]; then
  echo "flags-keep-only: FAIL -- expected fake-codex invocation log at $INVOCATION_LOG, not found" >&2
  FAIL=1
else
  INVOCATION_COUNT="$(wc -l < "$INVOCATION_LOG" | tr -d ' ')"
  check "fake-codex invocation count" "$INVOCATION_COUNT" "4"
  SEQUENCE="$(cut -d' ' -f1 "$INVOCATION_LOG" | paste -sd, -)"
  check "fake-codex invocation sequence" "$SEQUENCE" "mode=fresh,mode=resume,mode=resume,mode=fresh"
  DELETE_COUNT="$(grep -c '^mode=delete' "$INVOCATION_LOG" || true)"
  check "fake-codex delete invocation count" "$DELETE_COUNT" "0"
fi

exit "$FAIL"

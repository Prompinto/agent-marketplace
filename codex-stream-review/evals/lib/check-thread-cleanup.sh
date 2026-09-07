#!/usr/bin/env bash
# Confirm every thread a .result.json claims was cleaned up (cleanup:"deleted")
# has genuinely left no trace under ~/.codex/sessions/ -- an independent check
# on top of the wrapper's own self-reported cleanup:"deleted" value.
#
# Only meaningful for a scenario that dispatched to a REAL codex CLI
# (currently: parallel-live-acceptance, claim-ledger-live-acceptance).
# threads[] entries produced by a fake-codex-driven scenario never
# correspond to a real ~/.codex/sessions/ file at all, so this check is
# trivially a no-op pass for those, by design -- not a gap.
#
# Usage: check-thread-cleanup.sh <result.json>
#
# For every threads[] entry with cleanup=="deleted", searches
# ~/.codex/sessions/ recursively for any filename containing that entry's
# thread_id. A match is a genuine leak: the thread was reported deleted but a
# session file for it still exists. Entries with cleanup=="failed" or
# "retained" are reported informationally only -- already known-not-deleted
# by design, never counted as leaks.
#
# Exit 0 if no leak is found among the "deleted" entries; exit 1 otherwise
# (every leak found is printed before exiting, not just the first).
set -euo pipefail
RESULT_FILE="${1:?usage: check-thread-cleanup.sh <result.json>}"
SESSIONS_DIR="${HOME}/.codex/sessions"

if [ ! -f "$RESULT_FILE" ]; then
  echo "check-thread-cleanup.sh: no such file: $RESULT_FILE" >&2
  exit 1
fi

if ! jq -e . "$RESULT_FILE" >/dev/null 2>&1; then
  echo "check-thread-cleanup.sh: $RESULT_FILE is not valid JSON" >&2
  exit 1
fi

LEAK_FOUND=0

while IFS=$'\t' read -r GROUP THREAD_ID CLEANUP; do
  [ -z "$THREAD_ID" ] && continue
  if [ "$CLEANUP" != "deleted" ]; then
    echo "check-thread-cleanup.sh: informational -- group=$GROUP thread_id=$THREAD_ID cleanup=$CLEANUP (not deleted by design, not checked for a leak)"
    continue
  fi
  MATCH=""
  ERROR_DETAIL=""
  if [ -d "$SESSIONS_DIR" ]; then
    FIND_ERR_FILE="$(mktemp)"
    FIND_STATUS_FILE="$(mktemp)"
    while IFS= read -r -d '' CANDIDATE; do
      if [ -z "$MATCH" ]; then
        BN="${CANDIDATE##*/}"
        case "$BN" in
          *"$THREAD_ID"*) MATCH="$CANDIDATE" ;;
        esac
      fi
    done < <(
      set +e
      find "$SESSIONS_DIR" -type f -print0 2>"$FIND_ERR_FILE"
      printf '%d' "$?" >"$FIND_STATUS_FILE"
    )
    FIND_ERR="$(cat "$FIND_ERR_FILE")"
    FIND_STATUS="$(cat "$FIND_STATUS_FILE" 2>/dev/null || true)"
    rm -f "$FIND_ERR_FILE" "$FIND_STATUS_FILE"
    [ -n "$FIND_ERR" ] && ERROR_DETAIL="${ERROR_DETAIL:+$ERROR_DETAIL; }$FIND_ERR"
    [ "$FIND_STATUS" != "0" ] && ERROR_DETAIL="${ERROR_DETAIL:+$ERROR_DETAIL; }find exited with status ${FIND_STATUS:-unknown}"
  fi
  if [ -n "$MATCH" ]; then
    echo "check-thread-cleanup.sh: LEAK -- group=$GROUP thread_id=$THREAD_ID cleanup=deleted but found: $MATCH" >&2
    LEAK_FOUND=1
  elif [ -n "$ERROR_DETAIL" ]; then
    echo "check-thread-cleanup.sh: WARNING -- could not fully search for thread_id=$THREAD_ID (some paths were inaccessible, results may be incomplete): $ERROR_DETAIL" >&2
    LEAK_FOUND=1
  else
    echo "check-thread-cleanup.sh: OK -- group=$GROUP thread_id=$THREAD_ID cleanup=deleted, no session file found"
  fi
done < <(jq -r '.threads[]? | [.group, .thread_id, .cleanup] | @tsv' "$RESULT_FILE")

exit "$LEAK_FOUND"

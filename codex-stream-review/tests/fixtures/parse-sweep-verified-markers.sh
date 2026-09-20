#!/usr/bin/env bash
# Implements the SWEEP_VERIFIED marker grammar and parsing rules documented in
# codex-stream-review/skills/ccs/references/defect-class-sweep.md section 4:
#   SWEEP_VERIFIED <sweep_id>: CONFIRMED -- <non-empty reason>
#   SWEEP_VERIFIED <sweep_id>: DISPUTED -- <non-empty reason>
# with EXACTLY two ASCII hyphens as separator (never a Unicode em dash), plus
# the same fail-closed parsing rules run-ccs-review.sh's trusted-zone
# obligation and claim-ledger.md's own DISPOSITION marker already use: exactly
# one marker per requested sweep_id (zero or duplicate both fail closed); an
# unrecognized/not-requested sweep_id in a marker is ignored, never invented
# into a new reverify_status; an empty or missing reason fails closed.
#
# Grammar is byte-for-byte identical to parse-disposition-markers.sh's own
# fence-exclusion / column-zero-anchoring / known-id-first-matching rules --
# see that fixture's own header comment for the full negotiated rationale.
# Duplicated here (not sourced) because the two marker keywords/state-name
# sets differ (RESOLVED/RETRACTED/STILL OPEN vs. CONFIRMED/DISPUTED) and each
# fixture is meant to be readable standalone, matching this project's
# existing one-fixture-per-marker-family convention.
#
# Usage: parse-sweep-verified-markers.sh <text-file> <sweep_id> [<sweep_id> ...]
# For each requested sweep_id (in the given order), prints one line:
#   "<sweep_id> CONFIRMED <reason>"
#   "<sweep_id> DISPUTED <reason>"
#   "<sweep_id> FAIL_CLOSED <missing|duplicate|empty_reason|unclosed_fence>"

set -u
TEXT_FILE="$1"; shift
SWEEP_IDS=("$@")

OPENER_BACKTICK_RE='^ {0,3}(`{3,})'
OPENER_TILDE_RE='^ {0,3}(~{3,})'
CLOSER_BACKTICK_RE='^(`{3,})[[:space:]]*$'
CLOSER_TILDE_RE='^(~{3,})[[:space:]]*$'
STATE_RE='^(CONFIRMED|DISPUTED) --[[:space:]]*(.*)$'

NUM_IDS=${#SWEEP_IDS[@]}
MATCH_COUNT=()
MATCH_DISP=()
MATCH_REASON=()
i=0
while [ "$i" -lt "$NUM_IDS" ]; do
  MATCH_COUNT[$i]=0
  MATCH_DISP[$i]=""
  MATCH_REASON[$i]=""
  i=$((i + 1))
done

IN_FENCE=0
FENCE_CHAR=""
FENCE_LEN=0

while IFS= read -r LINE || [ -n "$LINE" ]; do
  if [ "$IN_FENCE" -eq 1 ]; then
    if [ "$FENCE_CHAR" = '`' ]; then
      CLOSER_RE="$CLOSER_BACKTICK_RE"
    else
      CLOSER_RE="$CLOSER_TILDE_RE"
    fi
    if [[ "$LINE" =~ $CLOSER_RE ]] && [ "${#BASH_REMATCH[1]}" -ge "$FENCE_LEN" ]; then
      IN_FENCE=0
    fi
    continue
  fi

  if [[ "$LINE" =~ $OPENER_BACKTICK_RE ]]; then
    IN_FENCE=1
    FENCE_CHAR='`'
    FENCE_LEN=${#BASH_REMATCH[1]}
    continue
  fi
  if [[ "$LINE" =~ $OPENER_TILDE_RE ]]; then
    IN_FENCE=1
    FENCE_CHAR='~'
    FENCE_LEN=${#BASH_REMATCH[1]}
    continue
  fi

  i=0
  while [ "$i" -lt "$NUM_IDS" ]; do
    ID="${SWEEP_IDS[$i]}"
    PREFIX="SWEEP_VERIFIED ${ID}: "
    PLEN=${#PREFIX}
    if [ "${LINE:0:PLEN}" = "$PREFIX" ]; then
      REST="${LINE:PLEN}"
      if [[ "$REST" =~ $STATE_RE ]]; then
        MATCH_COUNT[$i]=$((MATCH_COUNT[i] + 1))
        MATCH_DISP[$i]="${BASH_REMATCH[1]}"
        MATCH_REASON[$i]="${BASH_REMATCH[2]}"
      fi
    fi
    i=$((i + 1))
  done
done < "$TEXT_FILE"

UNCLOSED_FENCE=0
[ "$IN_FENCE" -eq 1 ] && UNCLOSED_FENCE=1

i=0
while [ "$i" -lt "$NUM_IDS" ]; do
  ID="${SWEEP_IDS[$i]}"
  if [ "$UNCLOSED_FENCE" -eq 1 ]; then
    echo "$ID FAIL_CLOSED unclosed_fence"
  else
    COUNT="${MATCH_COUNT[$i]}"
    if [ "$COUNT" -eq 0 ]; then
      echo "$ID FAIL_CLOSED missing"
    elif [ "$COUNT" -gt 1 ]; then
      echo "$ID FAIL_CLOSED duplicate"
    else
      REASON="${MATCH_REASON[$i]}"
      if [ -z "$REASON" ]; then
        echo "$ID FAIL_CLOSED empty_reason"
      else
        echo "$ID ${MATCH_DISP[$i]} $REASON"
      fi
    fi
  fi
  i=$((i + 1))
done

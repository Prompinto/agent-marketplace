#!/usr/bin/env bash
# Implements the DISPOSITION marker grammar and parsing rules documented in
# codex-stream-review/skills/ccs/references/claim-ledger.md section 4:
#   DISPOSITION <claim_id>: RESOLVED -- <non-empty one-sentence reason>
#   DISPOSITION <claim_id>: RETRACTED -- <non-empty one-sentence reason>
#   DISPOSITION <claim_id>: STILL OPEN -- <non-empty one-sentence reason>
# with EXACTLY two ASCII hyphens as separator (never a Unicode em dash), plus
# the "Parsing rules" bullet list: exactly one marker per requested claim_id
# (zero or duplicate both fail closed); an unrecognized/not-requested
# claim_id in a marker is ignored, never invented into a new closure; an
# empty or missing reason fails closed.
#
# Grammar (line-by-line, not whole-text search -- see claim-ledger.md section
# 4 for the full negotiated rationale):
#
# 1. Fence exclusion. A first pass tracks Markdown fences: a line is a fence
#    OPENER if, ignoring up to 3 leading spaces (CommonMark's own tolerance),
#    it is 3-or-more of the same character (all backticks or all tildes)
#    optionally followed by any trailing text (an info string, or anything
#    else). This is DELIBERATELY CONSERVATIVE, NOT LITERAL COMMONMARK: real
#    CommonMark forbids backticks inside a backtick-opener's own info
#    string, but this parser accepts any trailing text unconditionally.
#    Being over-inclusive here can only ever cause MORE text to be treated
#    as fenced, which can only cause a real marker to be missed (fail
#    closed) -- never cause a spoofed marker to be wrongly accepted. A line
#    CLOSES that fence only if it is the same character, length >= the
#    opening length, AT COLUMN ZERO, with nothing but optional trailing
#    whitespace -- no leading-space tolerance on the closer, the same
#    conservative bias applied in the other direction (harder to close
#    means more text stays fenced, never less). While inside a fence, no
#    line is checked for a marker at all, not even a line that looks like a
#    fence of the wrong character or insufficient length (matching real
#    fenced-code-block semantics: it does not close the block). If the text
#    ends while a fence is still open, the whole response is malformed for
#    marker-parsing purposes: every requested claim_id fails closed, not
#    just the ones inside the fence.
# 2. Column-zero anchoring. Outside any fence, a line is a marker candidate
#    only if the grammar matches starting at column zero -- no leading
#    whitespace at all. This alone excludes both mid-sentence/mid-prose
#    placement and Markdown's own indented-code-block convention (which
#    needs >=4 leading spaces): a marker requiring column zero can never
#    appear inside one.
# 3. Known-id-first matching. <claim_id> is matched by LITERAL comparison
#    against the finite set of claim_ids actually requested this round --
#    never a generic/unbounded regex trying to guess where the id ends.
#    This is required because a parallel-mode claim_id itself contains a
#    colon (e.g. "g1:f3", claim-ledger.md section 1), so a naive
#    "split on some colon" regex is inherently ambiguous; testing each
#    known, requested claim_id as a literal prefix has no such ambiguity
#    regardless of what characters the id contains.
#
# Usage: parse-disposition-markers.sh <text-file> <claim_id> [<claim_id> ...]
# For each requested claim_id (in the given order), prints one line:
#   "<claim_id> RESOLVED <reason>"
#   "<claim_id> RETRACTED <reason>"
#   "<claim_id> STILL_OPEN <reason>"
#   "<claim_id> FAIL_CLOSED <missing|duplicate|empty_reason|unclosed_fence>"

set -u
TEXT_FILE="$1"; shift
CLAIM_IDS=("$@")

# Fixed regexes -- single-quoted literals, no interpolation, so backticks
# and "$" inside them are never touched by the shell.
OPENER_BACKTICK_RE='^ {0,3}(`{3,})'
OPENER_TILDE_RE='^ {0,3}(~{3,})'
CLOSER_BACKTICK_RE='^(`{3,})[[:space:]]*$'
CLOSER_TILDE_RE='^(~{3,})[[:space:]]*$'
STATE_RE='^(RESOLVED|RETRACTED|STILL OPEN) --[[:space:]]*(.*)$'

# Parallel indexed arrays, keyed by the same index as CLAIM_IDS -- plain
# indexed arrays rather than an associative array, since this project's
# scripts target bash 3.2 (macOS system bash), which has no `declare -A`.
NUM_IDS=${#CLAIM_IDS[@]}
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

  # Not fenced, not a fence line itself -- check it as a marker candidate,
  # once per requested claim_id, via known-id-first literal prefix matching.
  i=0
  while [ "$i" -lt "$NUM_IDS" ]; do
    ID="${CLAIM_IDS[$i]}"
    PREFIX="DISPOSITION ${ID}: "
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

# Unclosed fence at EOF: the whole response is malformed for marker-parsing
# purposes. Fail closed for EVERY requested claim_id this round, not just
# whichever one(s) sit inside the still-open fence.
UNCLOSED_FENCE=0
[ "$IN_FENCE" -eq 1 ] && UNCLOSED_FENCE=1

i=0
while [ "$i" -lt "$NUM_IDS" ]; do
  ID="${CLAIM_IDS[$i]}"
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
        DISP="${MATCH_DISP[$i]}"
        [ "$DISP" = "STILL OPEN" ] && DISP="STILL_OPEN"
        echo "$ID $DISP $REASON"
      fi
    fi
  fi
  i=$((i + 1))
done

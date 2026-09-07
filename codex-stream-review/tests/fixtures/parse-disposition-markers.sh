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
# Judgment call (not spelled out by claim-ledger.md's grammar): claim_id
# itself can contain a colon in parallel mode (e.g. "g1:f3", per that file's
# section 1), so this parser cannot split on the FIRST colon after
# "DISPOSITION ". It captures claim_id with a greedy match up to a literal
# ": " immediately followed by one of the three known disposition words,
# relying on regex backtracking to find the LAST such split point in the
# line -- correct for the one-marker-per-line grammar this file documents.
#
# Usage: parse-disposition-markers.sh <text-file> <claim_id> [<claim_id> ...]
# For each requested claim_id (in the given order), prints one line:
#   "<claim_id> RESOLVED <reason>"
#   "<claim_id> RETRACTED <reason>"
#   "<claim_id> STILL_OPEN <reason>"
#   "<claim_id> FAIL_CLOSED <missing|duplicate|empty_reason>"

set -u
TEXT_FILE="$1"; shift

# Every syntactically-valid marker line in the text, regardless of whether
# its claim_id was ever requested -- filtering to requested/unrecognized
# happens below, per the "ignored, never invented" rule.
MARKERS_JSON="$(jq -Rn -c '
  [inputs
   | capture("^DISPOSITION (?<id>.+): (?<disp>RESOLVED|RETRACTED|STILL OPEN) --\\s*(?<reason>.*)$")]
' "$TEXT_FILE")"

for CLAIM_ID in "$@"; do
  MATCHES="$(printf '%s' "$MARKERS_JSON" | jq -c --arg id "$CLAIM_ID" '[.[] | select(.id == $id)]')"
  COUNT="$(printf '%s' "$MATCHES" | jq 'length')"
  if [ "$COUNT" -eq 0 ]; then
    echo "$CLAIM_ID FAIL_CLOSED missing"
  elif [ "$COUNT" -gt 1 ]; then
    echo "$CLAIM_ID FAIL_CLOSED duplicate"
  else
    REASON="$(printf '%s' "$MATCHES" | jq -r '.[0].reason')"
    if [ -z "$REASON" ]; then
      echo "$CLAIM_ID FAIL_CLOSED empty_reason"
    else
      DISP="$(printf '%s' "$MATCHES" | jq -r '.[0].disp')"
      if [ "$DISP" = "STILL OPEN" ]; then
        DISP="STILL_OPEN"
      fi
      echo "$CLAIM_ID $DISP $REASON"
    fi
  fi
done

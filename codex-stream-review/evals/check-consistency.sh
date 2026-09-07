#!/usr/bin/env bash
# Aggregate consistency across N already-produced .result.json files for one
# eval scenario, run via repeated manual/live codex-stream-review:ccs
# sessions -- wraps check-result.sh's own schema + expect.sh validation per
# file (never duplicating that logic here).
#
# This matters for a scenario driven by a genuine, unscripted LLM judgment
# call (the Secondary tier's parallel-live-acceptance and
# claim-ledger-live-acceptance) where repeated real runs can land on
# different -- but each individually valid -- semantic terminal states, so a
# bare per-file pass/fail isn't the whole picture. For any of the other 30
# scripted (fake-codex-driven) scenarios in this harness, the outcome is
# structurally forced to exactly one shape every time, so this tool has
# nothing to add there.
#
# Usage: check-consistency.sh <scenario-name> <result1.json> [result2.json ...]
#
# For each result file, runs `check-result.sh <result> <scenario-name>`
# (unmodified, as a subprocess) and buckets every file by outcome:
#   - a file that PASSED check-result.sh is bucketed by its own exit_state
#   - a file that FAILED check-result.sh is bucketed into a distinct
#     pseudo-state "FAILED" -- never merged into a real exit_state bucket,
#     never silently excluded from N
#
# Always prints: N/P/F, the full per-bucket breakdown (sorted by count
# descending), and a consistency_rate (largest bucket / N). A tie for the
# largest bucket names every tied bucket explicitly rather than picking one.
#
# Exit 0 only if every file passed its own check-result.sh call (F == 0);
# exit 1 otherwise, additionally printing each failing file's check-result.sh
# output.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -lt 2 ]; then
  echo "usage: check-consistency.sh <scenario-name> <result1.json> [result2.json ...]" >&2
  exit 1
fi

SCENARIO="$1"
shift

BUCKETS_FILE="$(mktemp)"
FAILURES_LOG="$(mktemp)"
SUMMARY_FILE="$(mktemp)"
trap 'rm -f "$BUCKETS_FILE" "$FAILURES_LOG" "$SUMMARY_FILE"' EXIT

N=0
P=0
for RESULT_FILE in "$@"; do
  N=$((N + 1))
  if CHECK_OUT="$(bash "$SCRIPT_DIR/check-result.sh" "$RESULT_FILE" "$SCENARIO" 2>&1)"; then
    P=$((P + 1))
    STATE="$(jq -r '.exit_state // "UNKNOWN"' "$RESULT_FILE" 2>/dev/null || echo "UNKNOWN")"
    echo "$STATE" >> "$BUCKETS_FILE"
  else
    echo "FAILED" >> "$BUCKETS_FILE"
    {
      echo "--- $RESULT_FILE ---"
      echo "$CHECK_OUT"
    } >> "$FAILURES_LOG"
  fi
done
F=$((N - P))

label_for() {
  if [ "$1" = "FAILED" ]; then echo "FAILED"; else echo "exit_state=$1"; fi
}

sort "$BUCKETS_FILE" | uniq -c | sort -rn > "$SUMMARY_FILE"

echo "check-consistency.sh: scenario=$SCENARIO N=$N P=$P F=$F"
echo ""
echo "Bucket breakdown (sorted by count descending):"
while read -r COUNT STATE; do
  echo "  $(label_for "$STATE"): $COUNT"
done < "$SUMMARY_FILE"
echo ""

MAX_COUNT="$(head -1 "$SUMMARY_FILE" | awk '{print $1}')"
TIED_STATES=()
while read -r COUNT STATE; do
  if [ "$COUNT" = "$MAX_COUNT" ]; then
    TIED_STATES+=("$STATE")
  fi
done < "$SUMMARY_FILE"

PCT=$(( (MAX_COUNT * 100 + N / 2) / N ))

if [ "${#TIED_STATES[@]}" -eq 1 ]; then
  echo "consistency_rate: ${PCT}% (${MAX_COUNT}/${N}, $(label_for "${TIED_STATES[0]}"))"
else
  TIE_DESC=""
  LAST_IDX=$((${#TIED_STATES[@]} - 1))
  for i in "${!TIED_STATES[@]}"; do
    LBL="$(label_for "${TIED_STATES[$i]}")"
    if [ "$i" -eq 0 ]; then
      TIE_DESC="$LBL"
    elif [ "$i" -eq "$LAST_IDX" ]; then
      TIE_DESC="$TIE_DESC and $LBL"
    else
      TIE_DESC="$TIE_DESC, $LBL"
    fi
  done
  echo "consistency_rate: ${PCT}% (${MAX_COUNT}/${N}, TIE between ${TIE_DESC})"
fi

if [ "$F" -gt 0 ]; then
  echo ""
  echo "check-consistency.sh: $F of $N file(s) failed their own check-result.sh call:"
  cat "$FAILURES_LOG"
  exit 1
fi

exit 0

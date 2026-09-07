#!/usr/bin/env bash
# Scenario-specific assertions for parallel-group-namespaced-claims. Schema
# structure already validated by check-result.sh's schema-check.jq.
#
#   - exit_state == "CLEAN"
#   - claims[] has exactly two entries: "g1:f1" and "g2:f1", both
#     disposition "resolved", both source_round 2 -- confirming
#     group-namespaced claim_ids never collide despite identical raw
#     per-group numbering
set -euo pipefail
RESULT_FILE="${1:?usage: expect.sh <result.json>}"

FAIL=0
check() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    echo "parallel-group-namespaced-claims: FAIL -- $desc: expected [$expected], got [$actual]" >&2
    FAIL=1
  fi
}

check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"

CLAIMS_COUNT="$(jq -r '.claims | length' "$RESULT_FILE")"
check "claims length" "$CLAIMS_COUNT" "2"

CLAIM_IDS="$(jq -r '[.claims[].claim_id] | sort | join(",")' "$RESULT_FILE")"
check "claim_ids" "$CLAIM_IDS" "g1:f1,g2:f1"

RESOLVED_COUNT="$(jq -r '[.claims[] | select(.disposition == "resolved" and .source_round == 2)] | length' "$RESULT_FILE")"
check "count of claims resolved at source_round 2" "$RESOLVED_COUNT" "2"

exit "$FAIL"

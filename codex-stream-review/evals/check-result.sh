#!/usr/bin/env bash
# Validate a codex-stream-review:ccs durable result artifact
# (<session-id>.result.json) against schemas/interactive-result.schema.json,
# plus any scenario-specific assertions declared for the named scenario.
#
# Usage: check-result.sh <result.json> [scenario-name]
#
# Exit 0: passes structural schema check (and scenario check, if named).
# Exit 1: fails one or more checks -- every violation is printed to stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_FILE="${1:?usage: check-result.sh <result.json> [scenario-name]}"
SCENARIO="${2:-}"

if [ ! -f "$RESULT_FILE" ]; then
  echo "check-result.sh: no such file: $RESULT_FILE" >&2
  exit 1
fi

if ! jq -e . "$RESULT_FILE" >/dev/null 2>&1; then
  echo "check-result.sh: $RESULT_FILE is not valid JSON" >&2
  exit 1
fi

FAILED=0

SCHEMA_FILE="$SCRIPT_DIR/../schemas/interactive-result.schema.json"
if VALIDATOR_OUTPUT="$(python3 "$SCRIPT_DIR/lib/validate_interactive_result.py" "$SCHEMA_FILE" "$RESULT_FILE" 2>&1)"; then
  echo "check-result.sh: schema OK ($RESULT_FILE)"
else
  echo "check-result.sh: schema violations in $RESULT_FILE:" >&2
  echo "$VALIDATOR_OUTPUT" | sed 's/^/  - /' >&2
  FAILED=1
fi

if [ -n "$SCENARIO" ]; then
  EXPECT_SCRIPT="$SCRIPT_DIR/scenarios/$SCENARIO/expect.sh"
  if [ -f "$EXPECT_SCRIPT" ]; then
    if bash "$EXPECT_SCRIPT" "$RESULT_FILE"; then
      echo "check-result.sh: scenario '$SCENARIO' assertions OK"
    else
      echo "check-result.sh: scenario '$SCENARIO' assertions FAILED" >&2
      FAILED=1
    fi
  else
    echo "check-result.sh: no scenarios/$SCENARIO/expect.sh -- schema-only check" >&2
  fi
fi

exit "$FAILED"

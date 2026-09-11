#!/usr/bin/env bash
# Regression fixtures for run-ccs-ci.sh -- there was no behavioral test
# coverage for this script before this file (see the remediation ledger,
# CSR-002 / L-004). Covers CSR-002 (write_result_atomic() silently
# succeeding when the fixed result path is already a directory, because
# `mv -f` onto a directory moves the file INSIDE it and reports success)
# plus a positive control confirming a normal run still writes a real
# result file.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../scripts/run-ccs-ci.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# --- fake `claude` CLI: a full drop-in for the one way run-ccs-ci.sh
# invokes a real `claude` binary (`claude -p --output-format json ...
# --json-schema ... -- PROMPT`). Ignores every argument (this script
# controls its own argv, not the caller of this fixture) and always emits a
# fixed, schema-conformant CLEAN envelope whose workflow_run_id/head_sha/
# pr_number match the literal constants this test file also passes to
# run-ccs-ci.sh below -- enough to satisfy the wrapper's own provenance
# validator and reach write_result_atomic(), which is what these fixtures
# actually test.
FAKE_BIN_DIR="$(mktemp -d)"
WRID="test-run-42"
SHA="0000000000000000000000000000000000000001"
PRN="7"
cat > "$FAKE_BIN_DIR/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
cat <<'JSON_EOF'
{"is_error":false,"subtype":"success","structured_output":{"exit_state":"CLEAN","exit_code":0,"verdict":"CLEAN","findings":[],"coverage":{"status":"complete","reviewed_file_count":1,"omitted":[]},"infrastructure_error":null,"input_errors":null,"workflow_run_id":"test-run-42","head_sha":"0000000000000000000000000000000000000001","pr_number":7}}
JSON_EOF
CLAUDE_EOF
chmod +x "$FAKE_BIN_DIR/claude"
PATH="$FAKE_BIN_DIR:$PATH"

ci_run() {
  # Invoked via `bash "$WRAPPER"`, matching .github/workflows/ccs-ci-review.yml's
  # own `bash ./trusted-tooling/.../run-ccs-ci.sh ...` invocation -- this
  # script is not tracked with the executable bit set (git mode 100644),
  # same as it's actually run in CI, so tests must not rely on it either.
  local repo="$1"
  bash "$WRAPPER" --cwd "$repo" --base-ref main --workflow-run-id "$WRID" --head-sha "$SHA" --pr-number "$PRN"
}

# 1. CSR-002: a pre-existing DIRECTORY at the result path must make the
# script fail loudly, never silently succeed with `mv` moving the temp file
# inside that directory.
REPO1="$(mktemp -d)"
mkdir -p "$REPO1/.ccs-ci-result.json"
OUT1="$(ci_run "$REPO1" 2>&1)"
STATUS1=$?
if [ "$STATUS1" -ne 0 ] \
  && printf '%s' "$OUT1" | grep -q "result path exists and is not a regular file" \
  && [ -d "$REPO1/.ccs-ci-result.json" ] && [ -z "$(ls -A "$REPO1/.ccs-ci-result.json" 2>/dev/null)" ]; then
  pass "CSR-002: pre-existing directory at result path -> loud failure, nothing written inside it"
else
  fail "CSR-002: expected a loud nonzero-exit failure naming the directory conflict and an untouched empty directory, got status=$STATUS1 dir-contents=$(ls -A "$REPO1/.ccs-ci-result.json" 2>&1); output: $OUT1"
fi
rm -rf "$REPO1"

# 2. Positive control: a normal run with no pre-existing directory still
# produces a real regular file at the result path -- confirms CSR-002's fix
# didn't break the ordinary success path.
REPO2="$(mktemp -d)"
OUT2="$(ci_run "$REPO2" 2>&1)"
STATUS2=$?
if [ "$STATUS2" -eq 0 ] && [ -f "$REPO2/.ccs-ci-result.json" ] \
  && [ "$(jq -r '.verdict' "$REPO2/.ccs-ci-result.json" 2>/dev/null)" = "CLEAN" ]; then
  pass "positive control: normal run (no pre-existing directory) writes a genuine CLEAN result file, exit 0"
else
  fail "positive control: expected exit 0 and a regular file with verdict=CLEAN at $REPO2/.ccs-ci-result.json, got status=$STATUS2 content=$(cat "$REPO2/.ccs-ci-result.json" 2>&1) output=$OUT2"
fi
rm -rf "$REPO2"

# 3. CSR-008: validate_ci_result.py used to print a raw Python traceback
# (an uncaught json.JSONDecodeError) instead of a clean INVALID diagnostic
# when the result file it's given is malformed JSON. Same file family as
# CSR-002 (both are part of the CI validation path), tested here rather
# than in a third file.
VALIDATE_PY="$SCRIPT_DIR/../scripts/validate_ci_result.py"
SCHEMA_FILE="$SCRIPT_DIR/../schemas/ci-result.schema.json"

BAD_JSON_FILE="$(mktemp)"
printf '{not-json' > "$BAD_JSON_FILE"
VALIDATE_OUT="$(python3 "$VALIDATE_PY" "$SCHEMA_FILE" "$BAD_JSON_FILE" 2>&1)"
VALIDATE_STATUS=$?
if [ "$VALIDATE_STATUS" -eq 1 ] \
  && printf '%s' "$VALIDATE_OUT" | grep -q '^INVALID: malformed JSON' \
  && ! printf '%s' "$VALIDATE_OUT" | grep -q "Traceback (most recent call last)"; then
  pass "CSR-008: malformed JSON result file -> clean INVALID diagnostic, exit 1, no traceback"
else
  fail "CSR-008: expected exit 1 with 'INVALID: malformed JSON' and no traceback, got status=$VALIDATE_STATUS output=$VALIDATE_OUT"
fi
rm -f "$BAD_JSON_FILE"

# 4. CSR-008 (UTF-8 variant): a result file containing invalid UTF-8 bytes
# raises UnicodeDecodeError during open()'s implicit text-mode decoding --
# distinct from json.JSONDecodeError, so it bypassed the first fix's except
# clause entirely and still tracebacked.
BAD_UTF8_FILE="$(mktemp)"
printf '\xff' > "$BAD_UTF8_FILE"
VALIDATE_UTF8_OUT="$(python3 "$VALIDATE_PY" "$SCHEMA_FILE" "$BAD_UTF8_FILE" 2>&1)"
VALIDATE_UTF8_STATUS=$?
if [ "$VALIDATE_UTF8_STATUS" -eq 1 ] \
  && printf '%s' "$VALIDATE_UTF8_OUT" | grep -q '^INVALID: malformed JSON' \
  && ! printf '%s' "$VALIDATE_UTF8_OUT" | grep -q "Traceback (most recent call last)"; then
  pass "CSR-008: invalid UTF-8 bytes in result file -> clean INVALID diagnostic, exit 1, no traceback"
else
  fail "CSR-008: expected exit 1 with 'INVALID: malformed JSON' and no traceback for invalid UTF-8, got status=$VALIDATE_UTF8_STATUS output=$VALIDATE_UTF8_OUT"
fi
rm -f "$BAD_UTF8_FILE"

rm -rf "$FAKE_BIN_DIR"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All fixtures passed."
  exit 0
else
  echo "$FAILURES fixture(s) failed."
  exit 1
fi

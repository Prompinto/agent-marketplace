#!/usr/bin/env bash
# Scenario: scope-uncommitted
# Targets: a plain --uncommitted fresh dispatch. This is largely what
# clean-basic already does -- built as explicit confirmation that
# target.scope == "uncommitted" is correctly recorded and coverage is a
# real object, not null, per schemas/interactive-result.schema.json's own
# conditional rule (already schema-checked by check-result.sh itself, but
# re-asserted here so this file fails loudly and specifically).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo scope-uncommitted)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

INVOCATION_LOG="/tmp/ccs-eval-scope-uncommitted-invocations.log"
rm -f "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "FAKE_CODEX_SCENARIO=normal"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call, and FAKE_CODEX_INVOCATION_LOG=<INVOCATION_LOG printed above>
set on every dispatch/cleanup call, FAKE_CODEX_CLEANUP_OK=1 on the
--cleanup call.

Task text to give the skill: "review the uncommitted change in this fixture
repo" (no scope flag prefix exists in this skill's own task-text grammar --
Phase 0 step 4 falls through to a real --uncommitted dispatch against
REPO_ROOT whenever the task names an existing diff with no base ref/commit
mentioned, which is exactly this case).

Expected: exit_state CLEAN, round_count 1, one thread (kind:current,
cleanup:deleted), target.scope == "uncommitted", coverage a real object
(status:"complete"). INVOCATION_LOG: exactly 2 lines, "mode=fresh ..." then
"mode=delete ...".
EOF

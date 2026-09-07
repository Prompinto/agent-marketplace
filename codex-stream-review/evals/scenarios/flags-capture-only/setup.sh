#!/usr/bin/env bash
# Scenario: flags-capture-only
# Targets: --capture-evidence ON, --keep-evidence OFF, on a CLEAN fake-codex
# run. Confirms the JSONL review-history log (never the durable .result.json
# itself -- investigation_evidence is a log-only field per
# references/capture-evidence.md) carries a populated investigation_evidence
# object reflecting the scripted FAKE_CODEX_COMMANDS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo flags-capture-only)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

INVOCATION_LOG="/tmp/ccs-eval-flags-capture-only-invocations.log"
rm -f "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "FAKE_CODEX_SCENARIO=normal"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call made during this run, and on every dispatch/cleanup call also
set FAKE_CODEX_INVOCATION_LOG=<INVOCATION_LOG printed above>. On the round-1
dispatch call ONLY, additionally set:

  FAKE_CODEX_COMMANDS='grep -rn "def add" lib.py
cat lib.py'

(a real, newline-separated, two-command scripted "investigation" -- see
fake-codex's own header comment for this var's exact behavior: it emits one
item.completed/command_execution event per line).

Task text to give the skill: "--capture-evidence review the uncommitted
change in this fixture repo".

Expected: exit_state CLEAN, round_count 1, one thread (kind:current,
cleanup:deleted, needs FAKE_CODEX_CLEANUP_OK=1 on the --cleanup call).
INVOCATION_LOG should end up with exactly 2 lines: "mode=fresh ..." then
"mode=delete ...". The session's own .jsonl log (same directory as the
.result.json, just a .jsonl extension instead) should have exactly one line
(round 1) whose investigation_evidence field is
{"command_count":2,"commands":["grep -rn \"def add\" lib.py","cat lib.py"]}
-- NOT present at all in the durable .result.json itself, which has no such
field in its schema.
EOF

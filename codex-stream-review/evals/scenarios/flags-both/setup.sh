#!/usr/bin/env bash
# Scenario: flags-both
# Targets: --capture-evidence AND --keep-evidence both ON together, on a
# CLEAN run. Confirms capture-evidence's effect still shows up in the JSONL
# log (same check as flags-capture-only) AND that keep-evidence's Phase-3
# gate correctly does NOT retain anything, since the outcome IS CLEAN --
# normal cleanup (cleanup:"deleted") still happens.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo flags-both)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

INVOCATION_LOG="/tmp/ccs-eval-flags-both-invocations.log"
rm -f "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "FAKE_CODEX_SCENARIO=normal"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call, and FAKE_CODEX_INVOCATION_LOG=<INVOCATION_LOG printed above>
set on every dispatch/cleanup call. On the round-1 dispatch call ONLY, also
set:

  FAKE_CODEX_COMMANDS='grep -rn "def add" lib.py
cat lib.py'

Task text to give the skill: "--capture-evidence --keep-evidence review the
uncommitted change in this fixture repo" (both prefixes, either order is
valid per Phase 0 Step 0's parsing loop -- this scenario picks
capture-evidence first, keep-evidence second, exercising the other order
from flags-keep-only, which never combines with capture-evidence at all).

Expected: exit_state CLEAN, round_count 1, one thread (kind:current,
cleanup:deleted -- keep-evidence's gate only skips cleanup on a non-CLEAN
outcome, and this run is CLEAN, so normal cleanup happens; set
FAKE_CODEX_CLEANUP_OK=1 on the --cleanup call). INVOCATION_LOG should end up
with exactly 2 lines: "mode=fresh ..." then "mode=delete ...". The session's
own .jsonl log should have exactly one line (round 1) whose
investigation_evidence field is
{"command_count":2,"commands":["grep -rn \"def add\" lib.py","cat lib.py"]}
-- capture-evidence's own effect, unaffected by keep-evidence also being ON.
No kept-evidence directory should ever be created this run (round 1
succeeded, so its own --keep-last-message file is simply deleted, never
moved anywhere).
EOF

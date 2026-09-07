#!/usr/bin/env bash
# Scenario: clean-basic
# Targets: exit_state = CLEAN (the baseline terminal-status matrix entry).
# Uses the fake-codex fixture (FAKE_CODEX_SCENARIO=normal, its own default)
# -- this scenario is about whether the ORCHESTRATOR (Claude following
# SKILL.md) correctly reaches and reports CLEAN on the simplest possible
# real dispatch, not about Codex's own review judgment, so a scripted
# always-clean responder is the right, deterministic choice here.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo clean-basic)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "FAKE_CODEX_SCENARIO=normal"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call the skill makes during this run (same "remember literal
values, reconstruct every call" discipline the skill's own Phase 0 already
requires for REPO_ROOT/INSTALL_PATH -- fresh shell per call, so PATH must be
re-prepended each time too). Task text to give the skill: "review the
uncommitted change in this fixture repo" (empty/default focus is fine, but
being explicit avoids the skill falling into its own "review the work just
done in this session" branch, which has no meaning for a fresh eval run).

Expected: exit_state CLEAN, round_count 1 (the fake codex always returns a
CLEAN verdict with no findings on its first try), one thread with
kind:current, cleanup:deleted.
EOF

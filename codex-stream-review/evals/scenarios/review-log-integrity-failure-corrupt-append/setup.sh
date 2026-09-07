#!/usr/bin/env bash
# Scenario: review-log-integrity-failure-corrupt-append
# Targets: exit_state = REVIEW_LOG_INTEGRITY_FAILURE, via the JSONL-append-
# verify failure path specifically (SKILL.md's "Review history log" ->
# "Write": append via `jq -nc >>`, then verify with
# `tail -n 1 <log> | jq -e '.round == <N>'` -- a hard stop on failure, per
# the Guards section: "never fall back to 'note it once and continue' for
# this specific failure").
#
# This is round 1's OWN append that fails -- there is no need for a round 2
# at all here (distinct from snapshot-integrity-failure, which structurally
# needs round 2 to ever run its own check). setup.sh pre-creates the
# session's own JSONL log path (matching SKILL.md's real "Location"
# convention exactly) and chmods it read-only BEFORE the driving agent ever
# attempts round 1's append -- so the real `jq -nc ... >> log` redirect
# genuinely fails (permission denied), and the real verify step genuinely
# finds nothing there, for real, not simulated.
#
# The literal repo-slug/session-id this scenario uses must be picked by the
# driving agent itself (SESSION_ID is only known once Phase 0 step 1 mints
# it live) -- this setup.sh only prints the repo path and the exact
# repo-slug transform to apply, plus the general mechanism, since it cannot
# pre-know the session id.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo review-log-integrity-corrupt-append)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="$(mktemp "/tmp/ccs-eval-review-log-corrupt-append-invocations.XXXXXX")"

REPO_SLUG="$(basename "$REPO_DIR" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g')"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG"
echo "FAKE_CODEX_SCENARIO=normal"
echo "REPO_SLUG=$REPO_SLUG (basename of REPO_DIR, lowercased, non-alnum runs collapsed to '-' -- matches SKILL.md's own <repo-slug> transform)"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH and FAKE_CODEX_SCENARIO=normal, FAKE_CODEX_INVOCATION_LOG
set, on round 1's dispatch call. Task text: "review the uncommitted change
in this fixture repo".

Right after Phase 0 mints the literal SESSION_ID, but BEFORE round 1's own
append-then-verify step runs, the driving agent must itself create the
session's real log path and make it unwritable, e.g.:
  umask 077 && mkdir -p ~/.claude/plugins/data/codex-stream-review/ccs-logs/<REPO_SLUG>
  : > ~/.claude/plugins/data/codex-stream-review/ccs-logs/<REPO_SLUG>/<SESSION_ID>.jsonl
  chmod 444 ~/.claude/plugins/data/codex-stream-review/ccs-logs/<REPO_SLUG>/<SESSION_ID>.jsonl
Then run round 1's real dispatch (a normal CLEAN or ISSUES verdict, doesn't
matter which -- the append fails before convergence is ever evaluated) and
attempt the real append: `jq -nc ... >> <that path>` genuinely fails
(permission denied, the file has no write bit for anyone including its
owner), and the real verify step (`tail -n 1 <path> | jq -e '.round == 1'`)
genuinely finds nothing to match, since the append never landed. This is a
hard stop -- report 🛑 REVIEW LOG INTEGRITY FAILURE per SKILL.md's own rule,
never "note it once and continue."

Expected: exit_state REVIEW_LOG_INTEGRITY_FAILURE, claims null, round_count
0 (no round's line was EVER durably logged this run -- the schema's own
degenerate-case allowance), threads: one entry kind:current cleanup:deleted
(FAKE_CODEX_CLEANUP_OK=1 on the unconditional Phase 3 --cleanup call -- round
1's own dispatch DID obtain a real threadId before the append ever failed).
FAKE_CODEX_INVOCATION_LOG should show exactly 2 lines (mode=fresh for round
1's dispatch, mode=delete for Phase 3 cleanup).
EOF

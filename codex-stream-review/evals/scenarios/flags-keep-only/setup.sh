#!/usr/bin/env bash
# Scenario: flags-keep-only
# Targets: --keep-evidence ON, --capture-evidence OFF, on a NON-CLEAN run.
# This flag's keep-vs-delete gate only does anything interesting on a
# non-CLEAN outcome, so this reuses could-not-verify-exhausted's own forced
# exit_nonzero retry-exhaustion sequence (FAKE_CODEX_SCENARIO=exit_nonzero
# on EVERY dispatch call) rather than a clean run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo flags-keep-only)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

INVOCATION_LOG="/tmp/ccs-eval-flags-keep-only-invocations.log"
rm -f "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "FAKE_CODEX_SCENARIO=exit_nonzero (set on EVERY dispatch call, fresh and every retry)"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call, FAKE_CODEX_SCENARIO=exit_nonzero and
FAKE_CODEX_INVOCATION_LOG=<INVOCATION_LOG printed above> set on every
dispatch call. Task text: "--keep-evidence review the uncommitted change in
this fixture repo".

Follow references/retry-guards.md's "A threadId WAS captured, and the reason
is resume-safe" branch exactly, same sequence as could-not-verify-exhausted:
  1. Fresh round-1 dispatch (--uncommitted) -- thread A captured, fails.
     Since --keep-evidence is ON, this attempt also carries
     --keep-last-message "<a freshly-mktemp'd LAST_MESSAGE_KEEP_FILE>".
  2. Wait 5s, --resume A --timeout 300 -- fails again. Own fresh
     --keep-last-message file (per retry-guards.md's multi-attempt
     kept-evidence rule -- never reuse attempt 1's already-consumed file).
  3. Wait 15s, --resume A --timeout 300 -- fails again. Own fresh
     --keep-last-message file. Both bounded resume-retries now exhausted.
  4. Fresh fallback retry of --uncommitted (thread B), abandoning A into
     LEAKED_THREAD_IDS. Own fresh --keep-last-message file. Fails too.
  5. Stop -- report COULD NOT VERIFY for group main.

Per retry-guards.md's "Multi-attempt kept-evidence handling": only the LAST
attempt's (step 4's, thread B's) own --keep-last-message file is a candidate
for keeping -- rm -f the earlier 3 attempts' own files without moving them.
Since --keep-evidence is ON and this round's outcome is ok:false, move
step 4's own kept file into the durable
`<session-id>-kept-evidence/round-1-main-lastmsg.txt` path (see
references/keep-evidence.md's "Directory and file naming") and record
kept_last_message_path on round 1's own JSONL line.

Phase 3's keep-evidence gate: --keep-evidence is ON AND the outcome is
COULD_NOT_VERIFY (non-CLEAN, and neither of the two integrity-failure
statuses) -- skip Phase 3 steps 1 and 2 (the GROUP_THREADS/LEAKED_THREAD_IDS
--cleanup loops) ENTIRELY. No --cleanup call is ever made this run -- do NOT
set FAKE_CODEX_CLEANUP_OK, it is never needed.

Expected exit_state: COULD_NOT_VERIFY. claims: []. threads: two entries --
{group:"main", thread_id:B, kind:"current", cleanup:"retained"} and
{group:"main", thread_id:A, kind:"leaked", cleanup:"retained"} (per
references/keep-evidence.md's Phase-3-gate-skip: "retained" for every thread
left alive by the gate). A kept last-message file should exist at
~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>-kept-evidence/round-1-main-lastmsg.txt.
EOF

#!/usr/bin/env bash
# Scenario: could-not-verify-exhausted
# Targets: exit_state = COULD_NOT_VERIFY (terminal-status matrix), reached
# via references/retry-guards.md's full bounded-retry sequence genuinely
# exhausting, not just a single failed dispatch.
#
# FAKE_CODEX_SCENARIO=exit_nonzero must be set on EVERY dispatch call made
# during this run -- fresh round-1 attempt AND both resume retries AND the
# final round-1 fresh-fallback retry -- so every attempt fails the same way
# (nonzero_exit, resume-safe per SKILL.md's "Resume-safety by failure
# reason" table) and the retry sequence genuinely runs out rather than
# succeeding on some attempt by accident. This is a plain env var set by the
# driving agent on each Bash call (same PATH-per-call discipline, see
# eval_inject_fake_codex's own doc comment) -- nothing in this setup script
# can pin it across separate Bash tool calls.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo could-not-verify-exhausted)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "FAKE_CODEX_SCENARIO=exit_nonzero (set on EVERY dispatch call, fresh and every retry)"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call made during this run, and FAKE_CODEX_SCENARIO=exit_nonzero
set on every dispatch call (fresh round-1 attempt, both resume retries, and
the final round-1 fresh-fallback retry). Task text: "review the uncommitted
change in this fixture repo".

Expected sequence, per skills/ccs/references/retry-guards.md's "A `threadId`
WAS captured, and the reason is resume-safe" branch:
  1. Fresh round-1 dispatch (--uncommitted) -- fake-codex still emits
     thread.started before failing (exit_nonzero happens after that line),
     so a real threadId (call it A) IS captured despite the failure.
     nonzero_exit is resume-safe -> proceed to retry, not an immediate stop.
  2. Wait 5s, --resume A --timeout 300 -- fails the same way (still
     FAKE_CODEX_SCENARIO=exit_nonzero).
  3. Wait 15s, --resume A --timeout 300 -- fails the same way. Both bounded
     resume-retries now exhausted.
  4. This was round 1, so: fall back to ONE fresh retry of the original
     --uncommitted scope, abandoning thread A -- append (main, A) to
     LEAKED_THREAD_IDS. This fresh dispatch obtains a NEW real threadId
     (call it B), and also fails (still exit_nonzero).
  5. That fresh retry failing too means: stop. Report COULD NOT VERIFY for
     group main -- no automatic further retry beyond this bounded sequence.

Phase 3 terminal path still runs cleanup UNCONDITIONALLY here (this session
never uses --keep-evidence, and COULD_NOT_VERIFY is not one of the two
integrity-failure statuses that bypass the keep-evidence gate, but that gate
only matters when --keep-evidence is ON in the first place -- see SKILL.md's
Guards section: "Still run the terminal-path cleanup ... using whatever
threadIds are known for every group, even from a failed response"). Set
FAKE_CODEX_CLEANUP_OK=1 on both --cleanup calls (thread B via GROUP_THREADS,
thread A via LEAKED_THREAD_IDS) so cleanup genuinely succeeds and
threads[].cleanup reads "deleted" for both, rather than fake-codex's default
always-fails delete behavior masking whether the ORCHESTRATOR's own cleanup
logic actually ran.

Expected exit_state: COULD_NOT_VERIFY. claims: [] (no round ever completed a
real review). threads: two entries -- {group:"main", thread_id:B,
kind:"current", cleanup:"deleted"} and {group:"main", thread_id:A,
kind:"leaked", cleanup:"deleted"}.
EOF

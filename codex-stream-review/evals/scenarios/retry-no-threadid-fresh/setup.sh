#!/usr/bin/env bash
# Scenario: retry-no-threadid-fresh
# Targets: references/retry-guards.md's "This group has NO entry in
# GROUP_THREADS yet" branch -- a group's true first-ever dispatch attempt
# fails BEFORE a thread ever starts (no threadId in the response at all),
# handled by retrying the SAME scope flag fresh, exactly once.
#
# Mechanism: FAKE_CODEX_NO_THREAD_STARTED=1 (NOT a FAKE_CODEX_SCENARIO
# value -- see tests/fixtures/fake-codex's own header comment) makes a
# FRESH dispatch skip emitting thread.started, then sleep past the
# wrapper's own hardcoded THREAD_WAIT_SECS=10s poll, so the wrapper kills
# the process and reports {"ok":false,"reason":"no_thread_started",...}
# with NO threadId. Since the driving agent issues each dispatch as its own
# separate Bash call anyway, "first call fails this way, second call
# succeeds" is scripted simply by NOT setting FAKE_CODEX_NO_THREAD_STARTED
# on the second (retry) call -- no FAKE_CODEX_GROUP_STATE needed.
#
# FAKE_CODEX_INVOCATION_LOG is set to a FIXED (not mktemp'd) path so this
# scenario's own expect.sh can find it deterministically from just the
# result.json path check-result.sh hands it -- see expect.sh for how the
# invocation-log assertion (exactly 2 fresh-mode invocations for group
# "main") is done.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo retry-no-threadid-fresh)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-retry-no-threadid-fresh-invocation.log"
: > "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call made during this run, and FAKE_CODEX_INVOCATION_LOG set to
the printed INVOCATION_LOG path on every dispatch/cleanup call. Task text:
"review the uncommitted change in this fixture repo".

Expected sequence, per skills/ccs/references/retry-guards.md's "This group
has NO entry in GROUP_THREADS yet" branch:
  1. Fresh round-1 dispatch (--uncommitted), with
     FAKE_CODEX_NO_THREAD_STARTED=1 (and FAKE_CODEX_SLEEP_SECS=11, comfortably
     past the wrapper's own hardcoded 10s thread.started poll) -- fails with
     {"ok":false,"reason":"no_thread_started",...}, NO threadId. This is the
     group's true first-ever attempt (GROUP_THREADS has no entry for "main"
     yet), so per retry-guards.md: "nothing exists to resume -- retry the
     same scope flag fresh, exactly once." Also: no_thread_started is one of
     the 7 reasons that unconditionally carries coverage.source on a fresh
     --uncommitted dispatch (collection already completed before this
     failure) -- capture that coverage value now, before dispatching the
     retry below (it is this whole session's round-1 coverage_source
     determination).
  2. Fresh round-1 RETRY (--uncommitted again, same scope, no --resume --
     there is no thread to resume yet) -- this time WITHOUT
     FAKE_CODEX_NO_THREAD_STARTED (plain FAKE_CODEX_SCENARIO=normal), so
     fake-codex emits a real thread.started line and a real CLEAN verdict.
     This obtains a genuine new threadId and completes round 1 successfully.
  3. Round 1 converges CLEAN (fake-codex's default verdict, no findings).
  4. Phase 3: --cleanup on the one real thread obtained in step 2, with
     FAKE_CODEX_CLEANUP_OK=1 so cleanup genuinely succeeds.

Expected exit_state: a real terminal status reached via the retry path (CLEAN,
since fake-codex's default verdict has no findings). threads: one entry,
kind:"current", cleanup:"deleted" (the retry's own thread -- the first,
failed attempt never obtained a threadId at all, so there is nothing to mark
"leaked" here, unlike the exhausted-retry scenarios). The invocation log at
INVOCATION_LOG must show exactly 2 lines starting with "mode=fresh " (the
failing attempt, with an empty thread_id, and the succeeding retry) and zero
"mode=resume " lines.
EOF

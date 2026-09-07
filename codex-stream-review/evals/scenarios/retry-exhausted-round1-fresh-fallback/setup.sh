#!/usr/bin/env bash
# Scenario: retry-exhausted-round1-fresh-fallback
# Targets: references/retry-guards.md's "If both resume-retries are
# exhausted and this was round 1" branch -- a round-1 group's initial
# dispatch gets a real threadId, then BOTH bounded --resume retries fail
# too (3 consecutive nonzero_exit failures: the original fresh dispatch,
# then both bounded resume retries). Per retry-guards.md: fall back to ONE
# fresh retry of the original scope flag, abandoning the now-unrecoverable
# thread -- append that (GROUP, threadId) pair to LEAKED_THREAD_IDS.
#
# UNLIKE could-not-verify-exhausted (which forces this fresh fallback retry
# to ALSO fail, reaching COULD_NOT_VERIFY), this scenario's fresh fallback
# SUCCEEDS -- confirming the leaked thread from the abandoned first attempt
# is genuinely cleaned up (Phase 3 step 2) ALONGSIDE the new current thread
# from the successful fallback, not just recorded and forgotten.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo retry-exhausted-round1-fresh-fallback)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-retry-exhausted-round1-fresh-fallback-invocation.log"
: > "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call made during this run, and FAKE_CODEX_INVOCATION_LOG set to
the printed INVOCATION_LOG path on every dispatch/cleanup call.
FAKE_CODEX_SCENARIO=exit_nonzero must be set on the first 3 dispatch calls
(fresh, resume retry #1, resume retry #2); FAKE_CODEX_SCENARIO=normal on the
4th (fresh fallback) and both --cleanup calls need
FAKE_CODEX_CLEANUP_OK=1. Task text: "review the uncommitted change in this
fixture repo".

Expected sequence, per skills/ccs/references/retry-guards.md's round-1
exhausted-retries fresh-fallback branch:
  1. Fresh round-1 dispatch (--uncommitted), FAKE_CODEX_SCENARIO=exit_nonzero
     -- fake-codex emits thread.started before failing, so a real threadId
     (call it A) IS captured. Capture coverage.source from this failing
     attempt now (nonzero_exit is one of the 7 always-eligible reasons).
  2. Wait 5s, --resume A --timeout 300, FAKE_CODEX_SCENARIO=exit_nonzero --
     fails the same way.
  3. Wait 15s, --resume A --timeout 300, FAKE_CODEX_SCENARIO=exit_nonzero --
     fails the same way. Both bounded resume retries now exhausted (3
     consecutive failures total: fresh + 2 resumes).
  4. This was round 1: fall back to ONE fresh retry of the original
     --uncommitted scope, abandoning thread A -- append (main, A) to
     LEAKED_THREAD_IDS. Dispatch fresh --uncommitted again,
     FAKE_CODEX_SCENARIO=normal -- this time it SUCCEEDS, obtaining a NEW
     real threadId (call it B), CLEAN verdict. (This differs from
     could-not-verify-exhausted, whose own fresh fallback ALSO fails --
     here it succeeds.)
  5. Round 1 converges CLEAN using B's own successful response (this is
     round 1's own single successful attempt -- its own coverage.source is
     used directly, no need to fall back to step 1's captured value, per
     "Coverage is a Round-1-only property": "captured from whichever of
     round 1's dispatch attempts for that group actually carried it,
     ordinarily its one successful attempt").
  6. Phase 3: --cleanup B (GROUP_THREADS, kind current) AND --cleanup A
     (LEAKED_THREAD_IDS, kind leaked) -- BOTH with FAKE_CODEX_CLEANUP_OK=1
     so both genuinely succeed.

Expected exit_state: CLEAN, round_count 1. threads: two entries --
{"group":"main","thread_id":B,"kind":"current","cleanup":"deleted"} and
{"group":"main","thread_id":A,"kind":"leaked","cleanup":"deleted"} -- the
leaked thread A really was cleaned up (Phase 3 step 2), not just recorded.
Invocation log: exactly 2 "mode=fresh" lines (the original failing attempt
and the successful fallback -- two DIFFERENT thread_id values, A then B)
and exactly 2 "mode=resume" lines (both against A).
EOF

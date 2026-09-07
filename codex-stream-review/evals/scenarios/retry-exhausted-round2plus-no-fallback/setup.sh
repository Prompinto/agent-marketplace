#!/usr/bin/env bash
# Scenario: retry-exhausted-round2plus-no-fallback
# Targets: references/retry-guards.md's "If both resume-retries are
# exhausted and this was round 2+" branch -- same "both resume-retries
# fail" shape as retry-exhausted-round1-fresh-fallback, but on a round-2+
# group (round 1 succeeded normally first). Per retry-guards.md: there is
# NO fresh-scope fallback available once a group has ever been resumed --
# stop directly, report COULD NOT VERIFY for that group. No new threadId is
# ever created on this path, so nothing is added to LEAKED_THREAD_IDS.
#
# Round 1 must legitimately NOT converge for a round 2 to exist at all --
# uses the fixture's own deliberate off-by-one bug (lib.py's add() returns
# a+b+1) as round 1's real, scripted finding; the driving agent fixes it for
# real before round 2 ever dispatches.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo retry-exhausted-round2plus-no-fallback)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-retry-exhausted-round2plus-no-fallback-invocation.log"
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

Expected sequence:
  1. Fresh round-1 dispatch (--uncommitted). FAKE_CODEX_FINAL_ANSWER scripted
     to a real ISSUES verdict naming lib.py:3's actual off-by-one bug. Real
     threadId (call it A) captured, round succeeds (ok:true).
  2. Fix the bug for real: edit REPO_DIR/lib.py, remove the "+ 1".
  3. Round 2 dispatch attempt 1: --resume A --timeout 300, FAKE_CODEX_
     SCENARIO=exit_nonzero -- fails, resume-safe reason, thread A untouched
     (GROUP_THREADS already has it from round 1).
  4. Wait 5s, --resume A --timeout 300 retry #1, FAKE_CODEX_SCENARIO=
     exit_nonzero -- fails again, same reason.
  5. Wait 15s, --resume A --timeout 300 retry #2 (the second and final
     bounded resume retry), FAKE_CODEX_SCENARIO=exit_nonzero -- fails a
     THIRD time. Both bounded resume retries are now exhausted.
  6. Per retry-guards.md's round-2+ branch: there is NO fresh scope left to
     fall back to on an already-resumed group -- stop directly, report
     COULD NOT VERIFY for group main. No new threadId is created on this
     path (unlike the round-1 case), so LEAKED_THREAD_IDS stays empty --
     thread A is simply this group's own still-current, never-abandoned
     thread, which still gets NORMAL terminal-path cleanup like any other
     outcome's thread.
  7. Phase 3: --cleanup A once (from GROUP_THREADS, kind current -- NOT
     leaked), FAKE_CODEX_CLEANUP_OK=1.

Expected exit_state: COULD_NOT_VERIFY, round_count 2. threads: exactly one
entry -- {"group":"main","thread_id":A,"kind":"current","cleanup":"deleted"}
-- NO "leaked" entry anywhere (the defining difference from
retry-exhausted-round1-fresh-fallback and could-not-verify-exhausted, both
of which DO produce a leaked entry). claims: one still-open entry for the
round-1 finding (round 1 DID complete a real review and raise it; round 2,
the re-check, never completed, so it never reaches a terminal disposition).
Invocation log: exactly 1 "mode=fresh" line (round 1) and
exactly 3 "mode=resume" lines (round 2's original attempt plus both bounded
retries), all sharing the identical thread_id A -- proving no fresh scope
flag was ever attempted for this group after round 1.
EOF

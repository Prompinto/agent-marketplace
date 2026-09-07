#!/usr/bin/env bash
# Scenario: retry-resume-safe-round2plus
# Targets: references/retry-guards.md's "A threadId WAS captured, and the
# reason is resume-safe" branch, on a ROUND 2+ dispatch instead of round 1
# (see retry-resume-safe-round1 for the round-1 case, including its
# coverage-capture-before-retry note, which does NOT apply here -- coverage
# is a round-1-only property; round 2's own --resume attempts never carry
# it, success or failure alike, so there is nothing to capture regardless of
# how many of round 2's attempts fail first). This scenario purely confirms
# the bounded resume-retry-with-backoff sequence (5s wait, retry; if that
# fails, 15s wait, retry once more) works correctly on a LATER round,
# exhausting BOTH bounded backoff waits before the eventual successful
# retry (the third total attempt for round 2), converging to a real result.
#
# Round 1 must legitimately NOT converge for a round 2 to exist at all --
# uses the fixture's own deliberate off-by-one bug (lib.py's add() returns
# a+b+1) as round 1's real, scripted finding; the driving agent fixes it for
# real before round 2 ever dispatches.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo retry-resume-safe-round2plus)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-retry-resume-safe-round2plus-invocation.log"
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
     threadId (call it A) captured, round-1 coverage_source recorded
     normally (this attempt succeeded -- ok:true -- nothing exotic here).
  2. Fix the bug for real: edit REPO_DIR/lib.py, remove the "+ 1".
  3. Round 2 dispatch attempt 1: --resume A --timeout 300 (genuine
     History+Scope focus text recapping the fix), FAKE_CODEX_SCENARIO=
     exit_nonzero -- fails, resume-safe reason, thread A untouched (already
     in GROUP_THREADS from round 1 -- nothing to capture coverage-wise,
     round 2+ never reports coverage.source at all regardless of ok:true or
     ok:false).
  4. Wait 5s, --resume A --timeout 300 retry #1, FAKE_CODEX_SCENARIO=
     exit_nonzero -- fails again, same resume-safe reason.
  5. Wait 15s, --resume A --timeout 300 retry #2 (the second and final
     bounded resume retry), FAKE_CODEX_SCENARIO=normal with
     FAKE_CODEX_FINAL_ANSWER set to a CLEAN verdict -- succeeds this time,
     SAME threadId A.
  6. Round 2 converges CLEAN using this successful retry's own result.
  7. Phase 3: --cleanup A once, FAKE_CODEX_CLEANUP_OK=1.

Expected exit_state: CLEAN, round_count 2. threads: exactly one entry --
{"group":"main","thread_id":A,"kind":"current","cleanup":"deleted"} -- no
"leaked" entry (round 2, once resumed, has no fresh scope to fall back to at
all -- but this scenario never needs that fallback anyway, since the second
bounded retry succeeds). Invocation log: exactly 1 "mode=fresh" line (round
1) and exactly 3 "mode=resume" lines (round 2's original attempt plus both
bounded retries), all four dispatch lines sharing the identical thread_id A.
EOF

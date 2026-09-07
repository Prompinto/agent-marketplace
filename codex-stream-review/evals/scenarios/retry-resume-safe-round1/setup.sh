#!/usr/bin/env bash
# Scenario: retry-resume-safe-round1
# Targets: references/retry-guards.md's "A threadId WAS captured, and the
# reason is resume-safe" branch, specifically its "Round 1 only -- capture
# coverage from the failing attempt BEFORE retrying" note. Round 1's fresh
# dispatch fails with a resume-safe reason (nonzero_exit) AFTER a thread
# already started (a real threadId IS captured despite the failure).
# Confirms coverage.source is captured from THIS failed attempt before the
# bounded --resume retry runs -- since a --resume call never reports
# coverage itself, this failed round-1 response is the ONLY place this
# session's real coverage data can come from once the eventual successful
# response is a --resume, not a fresh dispatch.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo retry-resume-safe-round1)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-retry-resume-safe-round1-invocation.log"
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

Expected sequence, per skills/ccs/references/retry-guards.md's "A threadId
WAS captured, and the reason is resume-safe" branch:
  1. Fresh round-1 dispatch (--uncommitted), FAKE_CODEX_SCENARIO=exit_nonzero
     -- fake-codex still emits thread.started before failing, so a real
     threadId (call it A) IS captured despite the failure. nonzero_exit is
     resume-safe. This response ALSO carries a spliced-in coverage.source
     object (nonzero_exit is one of the 7 reasons that unconditionally carry
     it on a fresh --uncommitted dispatch that got far enough to collect the
     diff) -- CAPTURE this coverage.source value NOW, before dispatching the
     retry below. Record it as this session's round-1 coverage_source
     determination.
  2. Wait 5s, --resume A --timeout 300, FAKE_CODEX_SCENARIO=normal (the
     bounded resume retry succeeds on its first attempt) -- CLEAN verdict.
     This --resume response never carries coverage.source itself (no
     --resume call ever does) -- the value captured in step 1 is the ONLY
     source of this round's real coverage data.
  3. Round 1 converges CLEAN, using: the SUCCESSFUL --resume response's
     verdict/findings, but the coverage_source CAPTURED FROM STEP 1's FAILED
     attempt (never re-derived, never left as the {"status":"unknown"}
     sentinel -- that sentinel is only for a round 1 where NONE of its
     attempts ever carried coverage.source at all, which is not the case
     here).
  4. Phase 3: --cleanup A once, FAKE_CODEX_CLEANUP_OK=1.

Expected exit_state: CLEAN, round_count 1. threads: exactly one entry --
{"group":"main","thread_id":A,"kind":"current","cleanup":"deleted"} -- no
"leaked" entry (the bounded resume retry succeeded on its first attempt, so
thread A was never abandoned). coverage: a real object (status:"complete",
reviewed_file_count:1, omitted:[]) -- NOT the {"status":"unknown"} sentinel,
proving the round-1 coverage capture-before-retry step actually ran and its
value was actually carried forward to the final result, even though round
1's own dispatch technically failed on its first attempt. Invocation log:
exactly 1 "mode=fresh" line and exactly 1 "mode=resume" line, same
thread_id A on both.
EOF

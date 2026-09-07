#!/usr/bin/env bash
# Scenario: retry-existing-threadid-badargs
# Targets: references/retry-guards.md's "This group ALREADY has an entry in
# GROUP_THREADS" branch, specifically the bad_args-from-empty-focus example
# named in that section: a --resume call fails with NO threadId in ITS OWN
# failure response, even though a real thread already exists for this group
# -- confirms this does NOT abandon the existing thread (no fresh scope
# flag, nothing added to LEAKED_THREAD_IDS), it just retries the exact same
# --resume <threadId> call again with corrected (non-empty) stdin.
#
# This bad_args failure is produced by the REAL run-ccs-review.sh itself
# (empty/whitespace-only stdin focus text), not simulated by fake-codex --
# per retry-guards.md, this is "caught right after the wrapper reads its own
# stdin *before* it ever touches the resumed thread", confirmed directly
# from the wrapper's own dispatch order (`_focus_is_empty` check runs before
# any `codex` invocation). So the fake-codex PATH injection is still needed
# for round 1's real dispatch and the eventual successful resume, but NOT
# for the bad_args attempt itself, which never invokes `codex` at all --
# that attempt therefore never appends to FAKE_CODEX_INVOCATION_LOG either.
#
# A genuine round 2 needs a real reason to exist (round 1 must not converge
# immediately) -- this fixture's own uncommitted change is the SAME
# deliberate off-by-one bug eval_make_fixture_repo always creates
# (lib.py's add() returns a+b+1). Round 1's scripted verdict names that
# exact bug as a finding; the driving agent fixes it for real (edit lib.py,
# remove the "+ 1"); round 2 is the legitimate --resume re-check dispatch --
# and it is THIS dispatch that the driving agent deliberately sends
# empty/whitespace-only stdin on once, to reproduce a real bad_args
# response, before correcting it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo retry-existing-threadid-badargs)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-retry-existing-threadid-badargs-invocation.log"
: > "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call made during this run, and FAKE_CODEX_INVOCATION_LOG set to
the printed INVOCATION_LOG path on every dispatch/cleanup call that reaches
the codex binary (the bad_args attempt below never does, so it never appends
a line).

Expected sequence, per skills/ccs/references/retry-guards.md's "This group
ALREADY has an entry in GROUP_THREADS" branch:
  1. Fresh round-1 dispatch (--uncommitted). Set
     FAKE_CODEX_FINAL_ANSWER to a real, schema-conformant verdict naming
     lib.py's actual off-by-one bug (verdict "ISSUES", one finding at
     lib.py:3, e.g. "add() returns a+b+1 instead of a+b"). Real threadId
     (call it T) is captured.
  2. Claude fixes the real bug for real: edit REPO_DIR/lib.py, remove the
     "+ 1" so add() returns a+b again. Whole-flow re-check: the fix is
     minimal and correct.
  3. Round 2 dispatch attempt 1: --resume T --timeout 300, but with
     EMPTY/whitespace-only stdin (a genuine mistake, not a simulated
     failure) -- the REAL run-ccs-review.sh rejects this itself, before ever
     touching thread T: {"ok":false,"reason":"bad_args","detail":"require
     non-empty focus text on stdin..."}, no threadId in this response. Per
     retry-guards.md: GROUP_THREADS already has an entry for "main" (T) --
     that existing thread is untouched, not abandoned. Retry the EXACT SAME
     --resume T call again, never a fresh scope flag, nothing added to
     LEAKED_THREAD_IDS.
  4. Round 2 dispatch attempt 2 (the retry): --resume T --timeout 300, this
     time with genuine non-empty focus text (History: fixed the off-by-one;
     Scope: re-check), FAKE_CODEX_SCENARIO=normal (or
     FAKE_CODEX_FINAL_ANSWER set to a CLEAN verdict) -- succeeds, using the
     SAME threadId T.
  5. Round 2 converges CLEAN.
  6. Phase 3: --cleanup T once, FAKE_CODEX_CLEANUP_OK=1.

Expected exit_state: CLEAN, round_count 2. threads: exactly one entry --
{"group":"main","thread_id":T,"kind":"current","cleanup":"deleted"} -- the
SAME T obtained in round 1, never replaced or duplicated, never marked
"leaked". The invocation log must show exactly 1 "mode=fresh" line (round
1's own dispatch) and exactly 1 "mode=resume" line (the retry that actually
reached fake-codex -- the bad_args attempt never invokes codex at all, so it
contributes no line), and both lines' thread_id field must read the
identical value T.
EOF

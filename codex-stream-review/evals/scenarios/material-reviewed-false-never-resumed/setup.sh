#!/usr/bin/env bash
# Scenario: material-reviewed-false-never-resumed
# Targets: run-ccs-review.sh's schema_mismatch extension (Task 5/7 of
# docs/superpowers/plans/2026-09-10-ccs-material-verification.md) -- a response setting
# material_reviewed:false, even with a nonempty ISSUES findings array (not just CLEAN), is
# rejected with a detail carrying the literal substring "no_material_reviewed", which
# references/retry-guards.md's dedicated recovery routes to: abandon the thread, one bounded
# fresh restart (this session's own round 1 recurring, since the hollow attempt never produced a
# valid round-1 result), never a --resume.
#
# The restart establishes a brand-new thread, so per SKILL.md's "Receipt schedule generation"
# section it gets its own fresh RECEIPT_SCHEDULE_FILE -- and the LIVE driving agent (not this
# script) constructs a GENUINELY matching material_receipt/material_receipt_index pair for it
# (slot 1's own real token from that schedule, read off the file at the moment it's needed), so a
# live orchestrating agent's Phase 2 step 1 receipt check actually ACCEPTS the restart's response
# as CLEAN, rather than rejecting it as another null-pair no_material_reviewed. Round 1's own
# hollow dispatch also gets its own schedule (every brand-new-thread dispatch does, per that same
# section) but the token value there never matters -- it's rejected by the wrapper's
# material_reviewed:false check before Phase 2 receipt validation is ever reached.
#
# This script deliberately does NOT pre-generate either receipt schedule (an earlier revision
# did) -- both schedules must be generated live by whatever agent is actually driving the /ccs
# session, at the exact point SKILL.md's own Phase 1 Step 0 calls for it, so the evidence this
# scenario produces reflects a real orchestrating agent's own procedure rather than a
# pre-baked-by-the-test-harness illustration of one. See README.md's "Live verification actually
# performed" section for a genuinely-live run's real captured evidence.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo material-reviewed-false-never-resumed)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-material-reviewed-false-never-resumed-invocation.log"
: > "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
cat <<EOF

Next step: invoke codex-stream-review:ccs (the real Skill tool, or -- if that does not run inline
in your own tool-call loop -- a faithful manual walkthrough of SKILL.md's own Phase 0-3 procedure
in the real order) against REPO_DIR, with BIN_DIR prepended to PATH on EVERY Bash call made during
this run, and FAKE_CODEX_INVOCATION_LOG set to the printed INVOCATION_LOG path on every
dispatch/cleanup call. Task text: "review the uncommitted change in this fixture repo".

This setup.sh deliberately does NOT pre-generate either receipt schedule. Both of this scenario's
brand-new-thread dispatches (round 1's hollow attempt, and the restart) get their own independent
RECEIPT_SCHEDULE_FILE, but each one must be generated LIVE by the actual driving agent, using
SKILL.md's own exact procedure ("Receipt schedule generation": mktemp + a 70-iteration
shasum -a 256-derived token loop), at the exact point in the real run where Phase 1 Step 0 calls
for it -- immediately before the dispatch that establishes that thread, never earlier and never by
this script. A schedule pre-baked by setup.sh (an earlier revision of this scenario did exactly
that) is illustrative-instructions authorship, not evidence that a live orchestrating agent's own
real Phase 1 Step 0 procedure produced it -- see this scenario's README for why that distinction
is the entire point of this scenario's own evidence chain.

Round 1's own fresh dispatch establishes a brand-new thread, so per SKILL.md's receipt schedule
rules it passes --receipt-schedule-file <the schedule YOU just generated live> --receipt-slot 1.
For that ONE call only, set:
  export FAKE_CODEX_SCENARIO=schema_mismatch
  export FAKE_CODEX_FINAL_ANSWER='{"verdict":"ISSUES","findings":[{"file":"lib.py","line":2,"severity":"low","summary":"s","evidence":"e","verification":"v"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":false,"material_receipt":null,"material_receipt_index":null}'

Expected: round 1's fresh dispatch is rejected as schema_mismatch (material_reviewed:false despite
a nonempty findings array), detail carries the literal substring "no_material_reviewed", the
thread is abandoned (added to LEAKED_THREAD_IDS, never --resume'd), and exactly ONE fresh restart
is attempted -- still round 1 (the hollow attempt never produced a valid round-1 result, so the
restart occupies round 1's own single slot, per retry-guards.md's round-1-vs-round-2+
disambiguation). The specific receipt values on THIS rejected response never matter -- Phase 2
receipt validation is never reached for an ok:false response.

The restart also establishes a brand-new thread (never reusing round 1's abandoned schedule), so
per retry-guards.md's own recovery procedure, generate a SECOND, independent receipt schedule live
at that point -- your own fresh mktemp + 70-iteration loop, never a reuse of round 1's file -- then
read slot 1's own real token off THAT file (e.g. \`sed -n '2p' "\$RESTART_SCHEDULE_FILE" | awk -F': ' '{print \$2}'\`;
verify the extracted value is exactly 24 raw characters before using it -- a stray extra token like
an inlined "VAR=" prefix silently breaks the match). Pass --receipt-schedule-file
<the restart's own live-generated schedule> --receipt-slot 1 on the restart's dispatch. For this
dispatch, unset FAKE_CODEX_FINAL_ANSWER's ISSUES override and set FAKE_CODEX_SCENARIO=normal with a
FAKE_CODEX_FINAL_ANSWER carrying material_reviewed:true, material_receipt_index:1, and
material_receipt set to slot 1's own real token you just read off the restart's own schedule --
construct this JSON with a tool that cannot mangle the token (e.g.
\`jq -nc --arg tok "\$RESTART_SLOT1_TOKEN" '{...,"material_receipt":\$tok,...}'\`), never hand-interpolated
into a literal string.

Because this material_receipt value genuinely matches slot 1 of the schedule actually passed on
this dispatch, a live orchestrating agent applying SKILL.md's Phase 2 step 1 receipt check to the
restart's own response finds a real match and accepts it as CLEAN -- this is NOT another
null-pair no_material_reviewed. This confirms the session reaches CLEAN via the restart, on a NEW
thread id, never the original one.

Set FAKE_CODEX_CLEANUP_OK=1 on both Phase 3 --cleanup calls.
EOF

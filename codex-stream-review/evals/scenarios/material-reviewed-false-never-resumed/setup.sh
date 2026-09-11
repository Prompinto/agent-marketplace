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
# section it gets its own fresh RECEIPT_SCHEDULE_FILE -- and this scenario constructs a
# GENUINELY matching material_receipt/material_receipt_index pair for it (slot 1's own real
# token from that schedule), so a live orchestrating agent's Phase 2 step 1 receipt check
# actually ACCEPTS the restart's response as CLEAN, rather than rejecting it as another
# null-pair no_material_reviewed. Round 1's own hollow dispatch also gets its own schedule
# (every brand-new-thread dispatch does, per that same section) but the token value there
# never matters -- it's rejected by the wrapper's material_reviewed:false check before Phase 2
# receipt validation is ever reached.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo material-reviewed-false-never-resumed)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-material-reviewed-false-never-resumed-invocation.log"
: > "$INVOCATION_LOG"

# Two SEPARATE receipt schedules -- one per brand-new thread this scenario dispatches (round 1's
# hollow attempt, and the restart) -- generated with SKILL.md's own exact procedure ("Receipt
# schedule generation", the mktemp/shasum -a 256/70-line loop). Slot 1's real token from the
# RESTART's schedule is embedded, verbatim, into the restart's own FAKE_CODEX_FINAL_ANSWER below --
# this is what makes the restart's response a genuinely Phase-2-valid receipt, not a null/null pair.
gen_receipt_schedule() {
  local out="$1"
  local block="REVIEW_RECEIPT_SCHEDULE"
  local i token
  for i in $(seq 1 70); do
    token="$(head -c 32 /dev/urandom | shasum -a 256 | head -c 24)"
    block="$block
$i: $token"
  done
  printf '%s\n' "$block" > "$out"
}

SCHEDULE_FILE_ROUND1="$(mktemp /tmp/ccs-eval-material-reviewed-false-never-resumed-schedule-round1.XXXXXX)"
gen_receipt_schedule "$SCHEDULE_FILE_ROUND1"

SCHEDULE_FILE_RESTART="$(mktemp /tmp/ccs-eval-material-reviewed-false-never-resumed-schedule-restart.XXXXXX)"
gen_receipt_schedule "$SCHEDULE_FILE_RESTART"
RESTART_SLOT1_TOKEN="$(sed -n '2p' "$SCHEDULE_FILE_RESTART" | cut -d' ' -f2)"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "SCHEDULE_FILE_ROUND1=$SCHEDULE_FILE_ROUND1"
echo "SCHEDULE_FILE_RESTART=$SCHEDULE_FILE_RESTART"
echo "RESTART_SLOT1_TOKEN=$RESTART_SLOT1_TOKEN"
cat <<EOF

Next step (run by hand or have a Claude Code agent do it): invoke codex-stream-review:ccs against
REPO_DIR, with BIN_DIR prepended to PATH on EVERY Bash call made during this run, and
FAKE_CODEX_INVOCATION_LOG set to the printed INVOCATION_LOG path on every dispatch/cleanup call.
Task text: "review the uncommitted change in this fixture repo".

Round 1's own fresh dispatch establishes a brand-new thread, so per SKILL.md's receipt schedule
rules it passes --receipt-schedule-file $SCHEDULE_FILE_ROUND1 --receipt-slot 1. Before that ONE
call only, set:
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
it passes --receipt-schedule-file $SCHEDULE_FILE_RESTART --receipt-slot 1. For this dispatch,
unset FAKE_CODEX_FINAL_ANSWER's ISSUES override and set FAKE_CODEX_SCENARIO=normal with a
FAKE_CODEX_FINAL_ANSWER carrying material_reviewed:true, material_receipt_index:1, and
material_receipt set to slot 1's own real token from the RESTART schedule printed above
($RESTART_SLOT1_TOKEN), e.g.:
  export FAKE_CODEX_SCENARIO=normal
  export FAKE_CODEX_FINAL_ANSWER='{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":true,"material_receipt":"$RESTART_SLOT1_TOKEN","material_receipt_index":1}'

Because this material_receipt value genuinely matches slot 1 of the schedule actually passed on
this dispatch, a live orchestrating agent applying SKILL.md's Phase 2 step 1 receipt check to the
restart's own response finds a real match and accepts it as CLEAN -- this is NOT another
null-pair no_material_reviewed. This confirms the session reaches CLEAN via the restart, on a NEW
thread id, never the original one.

Set FAKE_CODEX_CLEANUP_OK=1 on both Phase 3 --cleanup calls.
EOF

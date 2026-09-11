#!/usr/bin/env bash
# Scenario: no-material-reviewed-second-hollow
# Targets: references/retry-guards.md's one-fresh-restart-then-give-up bound (Task 9 of
# docs/superpowers/plans/2026-09-10-ccs-material-verification.md) -- when the ONE bounded fresh
# restart's own brand-new thread (B) ALSO returns material_reviewed:false, the session does NOT
# attempt a third thread. It stops immediately and reports ⚠️ COULD NOT VERIFY, with BOTH thread A
# (the original hollow attempt) and thread B (the restart's own hollow attempt) ending up
# "kind":"leaked" in the final artifact -- neither ever becomes the session's "current" thread,
# since retry-guards.md's own wording for this exhaustion path is explicit: "this restart's own
# new thread is abandoned too, exactly like the original hollow thread was" (never "becomes the new
# current thread the way an ordinary resume-exhausted fresh-fallback would").
#
# This is structurally simpler than material-reviewed-false-never-resumed (Task 12) or
# receipt-mismatch-phase2-reject (Task 13): BOTH dispatches are scripted via the same
# WRAPPER-level material_reviewed:false route (the schema_mismatch check in run-ccs-review.sh,
# which fires before Phase 2 receipt validation is ever reached), so neither dispatch's own
# material_receipt/material_receipt_index value is ever load-bearing -- unlike
# material-reviewed-false-never-resumed's restart, which must carry a GENUINELY matching receipt
# to reach real CLEAN, this scenario's restart is never meant to succeed at all.
#
# This script deliberately does NOT pre-generate either receipt schedule -- both of this
# scenario's brand-new-thread dispatches (round 1's hollow attempt A, and the restart's hollow
# attempt B) must be generated LIVE by whatever agent is actually driving the /ccs session, at the
# exact point SKILL.md's own Phase 1 Step 0 / references/retry-guards.md's restart recovery call
# for it -- exactly like material-reviewed-false-never-resumed's own setup.sh. See that scenario's
# README for why a schedule pre-baked by setup.sh would not be evidence that a live orchestrating
# agent's own procedure produced it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo no-material-reviewed-second-hollow)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-no-material-reviewed-second-hollow-invocation.log"
: > "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
cat <<EOF

Next step: invoke codex-stream-review:ccs (the real Skill tool, or -- if that does not run inline
in your own tool-call loop -- a faithful manual walkthrough of SKILL.md's own Phase 0-3 procedure
in the real order) against REPO_DIR, with BIN_DIR prepended to PATH on EVERY Bash call made during
this run, and FAKE_CODEX_INVOCATION_LOG set to the printed INVOCATION_LOG path on every dispatch/
cleanup call. Task text: "review the uncommitted change in this fixture repo".

Round 1's own fresh dispatch establishes a brand-new thread, so per SKILL.md's receipt schedule
rules it passes --receipt-schedule-file <the schedule YOU just generated live, via SKILL.md's own
mktemp + 70-iteration shasum -a 256 loop> --receipt-slot 1. For that ONE call only, set:
  export FAKE_CODEX_SCENARIO=schema_mismatch
  export FAKE_CODEX_FINAL_ANSWER='{"verdict":"ISSUES","findings":[{"file":"lib.py","line":2,"severity":"low","summary":"s","evidence":"e","verification":"v"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":false,"material_receipt":null,"material_receipt_index":null}'

Expected: round 1's fresh dispatch is rejected as schema_mismatch (material_reviewed:false), detail
carries the literal substring "no_material_reviewed", a real threadId (A) is captured despite the
rejection, and the thread is abandoned (added to LEAKED_THREAD_IDS, never --resume'd) -- exactly
like material-reviewed-false-never-resumed's round 1. references/retry-guards.md's recovery then
calls for exactly ONE fresh restart, still round 1's own single slot (the hollow attempt never
produced a valid round-1 result).

The restart establishes ANOTHER brand-new thread, so generate a SECOND, independent receipt
schedule live at that point -- your own fresh mktemp + 70-iteration loop, never reusing round 1's
abandoned schedule. Pass --receipt-schedule-file <the restart's own live-generated schedule>
--receipt-slot 1 on the restart's own dispatch. For THIS scenario -- unlike
material-reviewed-false-never-resumed -- do NOT switch to FAKE_CODEX_SCENARIO=normal for the
restart. Instead, keep the SAME hollow scenario active for the restart's own dispatch too:
  export FAKE_CODEX_SCENARIO=schema_mismatch
  export FAKE_CODEX_FINAL_ANSWER='{"verdict":"ISSUES","findings":[{"file":"lib.py","line":2,"severity":"low","summary":"s","evidence":"e","verification":"v"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":false,"material_receipt":null,"material_receipt_index":null}'

Expected: the restart's own dispatch is ALSO rejected as schema_mismatch/no_material_reviewed, on
a genuinely NEW threadId (B), distinct from A. references/retry-guards.md's own "If the ONE fresh
restart fails for ANY reason" rule fires: B is added to LEAKED_THREAD_IDS immediately too --
"this restart's own new thread is abandoned too, exactly like the original hollow thread was" --
and the session stops here, unconditionally. Report ⚠️ COULD NOT VERIFY. Never attempt a third
thread (C). Neither A nor B ever becomes the session's own "current" thread -- both end up
"kind":"leaked" in the final artifact.

Set FAKE_CODEX_CLEANUP_OK=1 on both Phase 3 --cleanup calls (thread A from LEAKED_THREAD_IDS,
thread B from LEAKED_THREAD_IDS -- GROUP_THREADS never holds an entry for "main" in this scenario,
since no thread here ever became the group's real current thread).
EOF

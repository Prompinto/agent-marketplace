#!/usr/bin/env bash
# Scenario: receipt-mismatch-phase2-reject
# Targets: SKILL.md's Phase 2 step 1 receipt-validation check (Task 8 of
# docs/superpowers/plans/2026-09-10-ccs-material-verification.md) -- a schema-valid ok:true
# response whose material_receipt/material_receipt_index are both well-typed and correctly paired
# (so run-ccs-review.sh's own schema_mismatch check, Task 5, has nothing to reject) but whose
# material_receipt VALUE does not match what THIS thread's own RECEIPT_SCHEDULE_FILE says slot 1
# should be, must still be caught -- by Claude's own stateful Phase 2 step 1 check, which is the
# only place that ever has both the schedule file's real content and the JSONL receipt_issued
# cursor. This is structurally different from material-reviewed-false-never-resumed (Task 12),
# whose round 1 was rejected by the WRAPPER itself as schema_mismatch; this scenario's round 1 is
# accepted by the wrapper as ok:true, and the rejection instead happens one layer up, in the live
# orchestrating agent's own Phase 2 processing.
#
# Recovery is the SAME no_material_reviewed treatment as Task 12: abandon the hollow thread, one
# bounded fresh restart (never a --resume), reusing references/compaction.md's own restart
# mechanism per references/retry-guards.md.
#
# This script deliberately does NOT pre-generate either receipt schedule -- both of this
# scenario's brand-new-thread dispatches (round 1's hollow attempt, and the restart) must be
# generated LIVE by whatever agent is actually driving the /ccs session, at the exact point
# SKILL.md's own Phase 1 Step 0 calls for it, exactly like material-reviewed-false-never-resumed's
# own setup.sh. See that scenario's README for why a schedule pre-baked by setup.sh would not be
# evidence that a live orchestrating agent's own procedure produced it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo receipt-mismatch-phase2-reject)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-receipt-mismatch-phase2-reject-invocation.log"
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

Round 1's own fresh dispatch establishes a brand-new thread, so per SKILL.md's receipt schedule
rules it passes --receipt-schedule-file <the schedule YOU just generated live, via SKILL.md's own
mktemp + 70-iteration shasum -a 256 loop> --receipt-slot 1. Read slot 1's own REAL token off that
file (e.g. \`sed -n '2p' "\$SCHEDULE_FILE" | awk -F': ' '{print \$2}'\`) -- you need it to
deliberately AVOID using it. For that ONE call, set:
  export FAKE_CODEX_SCENARIO=normal
  export FAKE_CODEX_FINAL_ANSWER='<a schema-valid JSON verdict, constructed with jq -- never
    hand-interpolated -- carrying material_reviewed:true, material_receipt_index:1, and
    material_receipt set to any 24-character value that is NOT the real slot-1 token you just read
    (e.g. "deadbeefdeadbeefdeadbeef"), plus one fabricated ISSUES finding to prove it never leaks
    into the session JSONL>'

Expected: the wrapper accepts this as ok:true (schema-valid: material_reviewed is true, the receipt
pair is well-typed and correctly paired at index 1 -- run-ccs-review.sh's own schema_mismatch check,
Task 5, has nothing to reject here). YOU must then perform SKILL.md's Phase 2 step 1 receipt
validation yourself: extract slot 1's real token from the schedule file, extract
verdict.material_receipt/verdict.material_receipt_index from the response, and compare with a real
shell \`if\` test. They will NOT match. Per Phase 2 step 1's own rule, treat this response
IMMEDIATELY -- before ever receiving its findings, re-verifying them, or running any convergence
check -- as equivalent to this group's response being ok:false with reason no_material_reviewed.
The fabricated finding in this response must NEVER be recorded to the session's own JSONL
codex_review.findings[] anywhere.

references/retry-guards.md's no_material_reviewed recovery then fires exactly as in
material-reviewed-false-never-resumed (Task 12): add this thread to LEAKED_THREAD_IDS, never
--resume it, and issue exactly ONE fresh restart -- still round 1's own single slot, since the
hollow attempt never produced a valid round-1 result. The restart establishes ANOTHER brand-new
thread, so generate a SECOND, independent receipt schedule live at that point (never reusing round
1's), read slot 1's own real token off THAT file, and construct the restart's own
FAKE_CODEX_FINAL_ANSWER (FAKE_CODEX_SCENARIO=normal, material_reviewed:true,
material_receipt_index:1, material_receipt set to that real token, constructed with jq) so it
GENUINELY matches. Re-run Phase 2 step 1's own check against the restart's response: it will match,
so accept it as genuine CLEAN and proceed to convergence. This confirms the session reaches real,
Phase-2-compliant CLEAN via the restart, on a NEW thread id, never the original one.

Set FAKE_CODEX_CLEANUP_OK=1 on both Phase 3 --cleanup calls.
EOF

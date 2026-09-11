#!/usr/bin/env bash
# Scenario: receipt-null-pair-reject
# Targets: SKILL.md's Phase 2 step 1 receipt-validation check (Task 8 of
# docs/superpowers/plans/2026-09-10-ccs-material-verification.md) -- a schema-valid ok:true
# response that genuinely reports material_receipt:null, material_receipt_index:null (Codex
# honestly saying "I cannot locate the schedule") from a thread that DOES have an active
# RECEIPT_SCHEDULE_FILE must still be routed to no_material_reviewed, via the SAME Phase 2 step 1
# check as receipt-mismatch-phase2-reject (Task 13) -- "OR both fields are null despite this
# thread genuinely having an active schedule" -- never treated as a softer or differently-handled
# case than a wrong-value mismatch. This is structurally different from
# material-reviewed-false-never-resumed (Task 12), whose round 1 was rejected by the WRAPPER
# itself as schema_mismatch (material_reviewed:false); a genuine null-null pair with
# material_reviewed:true is schema-valid (the wrapper's own schema_mismatch check, Task 5, treats
# a paired null-null receipt as legitimate -- it's the correct shape for a session with NO active
# schedule) so the wrapper accepts this as ok:true, and the rejection instead happens one layer
# up, in the live orchestrating agent's own Phase 2 step 1 check, which alone knows this
# particular thread's schedule is actually active.
#
# Recovery is the SAME no_material_reviewed treatment as Tasks 12/13: abandon the hollow thread,
# one bounded fresh restart (never a --resume), reusing references/compaction.md's own restart
# mechanism per references/retry-guards.md.
#
# This script deliberately does NOT pre-generate either receipt schedule -- both of this
# scenario's brand-new-thread dispatches (round 1's hollow attempt, the restart) must be
# generated LIVE by whatever agent is actually driving the /ccs session, at the exact point
# SKILL.md's own Phase 1 Step 0 calls for it, exactly like Tasks 12/13's own setup.sh scripts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo receipt-null-pair-reject)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-receipt-null-pair-reject-invocation.log"
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
mktemp + 70-iteration shasum -a 256 loop> --receipt-slot 1 -- this thread genuinely HAS an active
schedule. For that ONE call, set:
  export FAKE_CODEX_SCENARIO=normal
  export FAKE_CODEX_FINAL_ANSWER='<a schema-valid JSON verdict, constructed with jq -- never
    hand-interpolated -- carrying material_reviewed:true (this scenario is specifically testing
    the null-pair path, not the material_reviewed:false path already covered by
    material-reviewed-false-never-resumed), material_receipt:null, material_receipt_index:null
    (a genuine, honest "I cannot locate the schedule" report -- not a wrong value, an absent one),
    plus one fabricated ISSUES finding to prove it never leaks into the session JSONL>'

Expected: the wrapper accepts this as ok:true (schema-valid: material_reviewed is true, and a
paired null-null receipt is a legitimate shape per run-ccs-review.sh's own schema_mismatch check,
Task 5 -- that check alone cannot know whether THIS thread's schedule is active, so it has nothing
to reject here). YOU must then perform SKILL.md's Phase 2 step 1 receipt validation yourself: this
thread DOES have an active schedule (you just generated and passed one), yet the response reports
both material_receipt and material_receipt_index as null. Per Phase 2 step 1's own rule ("OR both
fields are null despite this thread genuinely having an active schedule"), treat this response
IMMEDIATELY -- before ever receiving its findings, re-verifying them, or running any convergence
check -- as equivalent to this group's response being ok:false with reason no_material_reviewed,
identically to a wrong-value mismatch, never as a softer or separately-handled case. The
fabricated finding in this response must NEVER be recorded to the session's own JSONL
codex_review.findings[] anywhere.

references/retry-guards.md's no_material_reviewed recovery then fires exactly as in
material-reviewed-false-never-resumed (Task 12) and receipt-mismatch-phase2-reject (Task 13): add
this thread to LEAKED_THREAD_IDS, never --resume it, and issue exactly ONE fresh restart -- still
round 1's own single slot, since the hollow attempt never produced a valid round-1 result. The
restart establishes ANOTHER brand-new thread, so generate a SECOND, independent receipt schedule
live at that point (never reusing round 1's), read slot 1's own real token off THAT file, and
construct the restart's own FAKE_CODEX_FINAL_ANSWER (FAKE_CODEX_SCENARIO=normal,
material_reviewed:true, material_receipt_index:1, material_receipt set to that real token,
constructed with jq) so it GENUINELY matches. Re-run Phase 2 step 1's own check against the
restart's response: it will match (a real, non-null pair equal to the schedule's slot 1), so
accept it as genuine CLEAN and proceed to convergence. This confirms the session reaches real,
Phase-2-compliant CLEAN via the restart, on a NEW thread id, never the original one.

Set FAKE_CODEX_CLEANUP_OK=1 on both Phase 3 --cleanup calls.
EOF

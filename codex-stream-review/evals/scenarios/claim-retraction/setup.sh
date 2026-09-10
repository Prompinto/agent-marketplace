#!/usr/bin/env bash
# Scenario: claim-retraction
# Targets: raise (round 1) -> rebut, no fix (round 2) -> Codex goes quiet on
# it -> Claude explicitly asks for a disposition (round 3) ->
# DISPOSITION <id>: RETRACTED marker -> exit_state CLEAN.
#
# THREE rounds, not two -- a deliberate departure from this scenario's
# original one-line plan description ("same shape" as claim-clean-
# resolution). Read claim-ledger.md section 4's "When to ask" rule
# carefully: a disposition request is only justified when, relative to the
# MOST RECENTLY COMPLETED round, the claim either (a) did NOT appear in that
# round's own findings, or (b) Claude just applied a FIX in direct response
# to it. A pure rebuttal (no code fix) does not satisfy (b), and the claim
# DID appear in round 1 (the round immediately before), so (a) cannot fire
# for round 2's own focus either -- round 2 is a normal rebuttal round with
# no disposition request yet. Only once round 2 completes WITHOUT
# re-mentioning the claim does condition (a) become true for round 3's own
# focus construction, which is the first round allowed to actually ask for
# (and receive) a DISPOSITION marker. Forcing this into 2 rounds instead
# would mean the orchestrator requesting (and fake-codex answering) a
# disposition it was never actually entitled to ask for yet under the
# current grammar -- this scenario is built to match the CURRENT rule
# exactly, not the plan's older, looser wording.
#
# Fixture: a bespoke repo (not eval_make_fixture_repo, whose only uncommitted
# change is a real, genuine bug -- this scenario needs a FALSE-POSITIVE
# finding Claude can legitimately reject with real evidence) whose
# uncommitted change is a small, CORRECT clamp() helper appended to lib.py.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-claim-retraction.XXXXXX")"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "eval@example.com"
git -C "$REPO_DIR" config user.name "ccs-eval"
printf 'def add(a, b):\n    return a + b\n' > "$REPO_DIR/lib.py"
git -C "$REPO_DIR" add lib.py
git -C "$REPO_DIR" commit -q -m "initial"
cat >> "$REPO_DIR/lib.py" <<'PYEOF'


def clamp(x, lo, hi):
    return max(lo, min(x, hi))
PYEOF

BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
GROUP_STATE_DIR="$(mktemp -d)"

cat > "$GROUP_STATE_DIR/round-0-final-answer.json" <<'EOF'
{"verdict":"ISSUES","findings":[{"file":"lib.py","line":5,"severity":"low","summary":"clamp() does not validate lo <= hi","evidence":"if a caller passes lo > hi, clamp() returns an implementation-defined result with no documented precondition","verification":"read the new clamp() function; no precondition check or docstring"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"clamp() has no lo<=hi precondition check"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic"},"contracts":{"status":"checked","evidence":"clamp()'s contract does not state what happens when lo>hi"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"not_applicable","evidence":"n/a"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF

cat > "$GROUP_STATE_DIR/round-1-final-answer.json" <<'EOF'
{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"no other issues found in this diff this round"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic"},"contracts":{"status":"not_applicable","evidence":"n/a"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"not_applicable","evidence":"n/a"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF

cat > "$GROUP_STATE_DIR/round-2-final-answer.json" <<'EOF'
{"verdict":"CLEAN","findings":[],"summary":"DISPOSITION f1: RETRACTED -- Claude's rebuttal is correct: clamp() is only called internally with statically-validated lo<=hi values, matching add()'s own no-input-validation convention elsewhere in this file; withdrawing this finding.","dimensions":{"correctness":{"status":"checked","evidence":"re-confirmed no callers pass lo>hi; withdrawing f1"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic"},"contracts":{"status":"not_applicable","evidence":"n/a"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"not_applicable","evidence":"n/a"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "GROUP_STATE_DIR=$GROUP_STATE_DIR"
echo "FAKE_CODEX_SCENARIO=normal (set on EVERY dispatch call)"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH, FAKE_CODEX_SCENARIO=normal, and
FAKE_CODEX_GROUP_STATE=<GROUP_STATE_DIR literal> set on EVERY dispatch call
(fresh round 1, round-2 resume, round-3 resume). Task text: "review the
uncommitted change in this fixture repo".

Expected sequence:
  1. Round 1 (fresh --uncommitted): round-0's ISSUES verdict, finding f1
     claiming clamp() needs a lo<=hi precondition check. Claude
     re-verifies: clamp() is a private two-line helper with no external
     callers in this fixture and matches add()'s own zero-validation
     convention -- REJECT_WITH_RATIONALE, no code change.
  2. Round 2's own focus recaps the rebuttal as normal History (per-claim
     accept/reject cycle) -- per claim-ledger.md's "When to ask" rule,
     f1 DID appear in round 1's own findings and no fix was applied, so
     round 2's focus does NOT yet request a disposition marker.
  3. Round 2 (--resume): round-1's CLEAN verdict, findings:[], f1 not
     mentioned at all (Codex has gone quiet on it).
  4. Per "When to ask" condition (a) (f1 is still open and did NOT appear in
     round 2's own findings, the most recently completed round), round 3's
     own focus must now explicitly name claim_id f1 and request a
     DISPOSITION marker.
  5. Round 3 (--resume): round-2's CLEAN verdict carries
     "DISPOSITION f1: RETRACTED -- ..." in its summary. Claude's parser
     validates it -> claim_closures: [{"claim_id":"f1",
     "disposition":"retracted","source_round":3,...}].
  6. Convergence: round 3's own findings are empty and f1 now has a
     terminal disposition -> exit_state CLEAN.

Set FAKE_CODEX_CLEANUP_OK=1 on the Phase 3 --cleanup call.

Expected result: exit_state CLEAN, round_count 3, threads: one entry
kind:current cleanup:deleted, claims: one entry {"claim_id":"f1",
"disposition":"retracted","source_round":3}.
EOF

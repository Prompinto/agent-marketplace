#!/usr/bin/env bash
# Scenario: quick-mode-escalation-high
# Targets: under --quick, a HIGH-severity finding in round 1 permanently escalates
# MAX_ROUNDS from 5 to 20 (SKILL.md's Phase 2 "Escalation (one-way, permanent)" rule) --
# proven by the loop genuinely reaching round 6, which is only possible once MAX_ROUNDS is no
# longer 5. Never reaches MINOR_ISSUES_ACKNOWLEDGED (severity is HIGH throughout, never
# LOW/MEDIUM, so that branch is never eligible even at round 5).
#
# Same false-positive-disagreement technique as not-converged-cap/quick-mode-minor-acknowledged:
# a correct, benign uncommitted addition; Codex's scripted responses falsely claim a defect in it,
# with a DIFFERENT evidence string each round through round 5 (evidence_delta:"new" every time, no
# early oscillation stop) -- then round 6 DELIBERATELY repeats round 5's own evidence string
# VERBATIM (evidence_delta:"none" since its own most recent prior occurrence), which is the
# per-claim oscillation guard's own trigger condition (claim-ledger.md section 7), producing a
# clean, deterministic NOT_CONVERGED at round_count 6 -- proving the loop really did run a 6th
# round (impossible if MAX_ROUNDS had stayed 5), without needing a real 20-round session.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-quick-esc-high.XXXXXX")"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "eval@example.com"
git -C "$REPO_DIR" config user.name "ccs-eval"
printf 'def add(a, b):\n    return a + b\n' > "$REPO_DIR/lib.py"
git -C "$REPO_DIR" add lib.py
git -C "$REPO_DIR" commit -q -m "initial"
cat >> "$REPO_DIR/lib.py" <<'PYEOF'


def sub(a, b):
    return a - b
PYEOF

BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

GROUP_STATE="$(mktemp -d "/tmp/ccs-eval-quick-esc-high-state.XXXXXX")"
INVOCATION_LOG="$(mktemp "/tmp/ccs-eval-quick-esc-high-invocations.XXXXXX")"

DIMENSIONS='{"correctness":{"status":"checked","evidence":"reviewed the new sub() function"},"security":{"status":"not_applicable","evidence":"no security-relevant surface in this diff"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic, no performance concern"},"reuse":{"status":"not_applicable","evidence":"a small standalone helper, no reuse concern"},"contracts":{"status":"not_applicable","evidence":"no public contract change"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource/concurrency surface"},"intent":{"status":"checked","evidence":"matches the stated intent of adding a subtraction helper"}}'

mk_round() {
  # $1 = round index N, $2 = evidence string
  jq -nc --arg ev "$2" --argjson dims "$DIMENSIONS" '
    {
      verdict: "ISSUES",
      findings: [
        {
          file: "lib.py",
          line: 4,
          severity: "high",
          summary: "sub(a, b) has an off-by-one: should return a - b - 1, not a - b",
          evidence: $ev,
          verification: "static reasoning about the arithmetic in sub()"
        }
      ],
      summary: "one open finding in sub()",
      dimensions: $dims,
      material_reviewed: true,
      material_receipt: null,
      material_receipt_index: null
    }' > "$GROUP_STATE/round-${1}-final-answer.json"
}

for N in $(seq 0 4); do
  mk_round "$N" "observed in round $N's own re-read of line 4"
done
# Round 5 (the 6th dispatch) DELIBERATELY repeats round-4's own evidence string verbatim --
# evidence_delta:"none" since its own most recent prior occurrence, the per-claim oscillation
# guard's own trigger -- producing a clean, deterministic stop at round_count 6.
mk_round 5 "observed in round 4's own re-read of line 4"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "FAKE_CODEX_GROUP_STATE=$GROUP_STATE"
echo "FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG"
echo "FAKE_CODEX_SCENARIO=normal (set on every dispatch call -- FAKE_CODEX_GROUP_STATE's own per-round override takes priority over FAKE_CODEX_FINAL_ANSWER, so 'normal' is just what makes fake-codex actually emit a final answer at all)"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs, WITH THE --quick PREFIX, against REPO_DIR, with
BIN_DIR prepended to PATH, and FAKE_CODEX_GROUP_STATE/FAKE_CODEX_INVOCATION_LOG/
FAKE_CODEX_SCENARIO=normal set, on every dispatch call this run makes (see
codex-stream-review/evals/README.md's "Mechanical caveat"). Task text:
"--quick review the uncommitted change in this fixture repo".

The agent actually driving this session must genuinely judge finding f1's severity as HIGH every
round (triggering ESCALATED=true, MAX_ROUNDS -> 20, at round 1's own step 3 verification pass),
genuinely rebut it as a false positive with evidence_delta:"new" through round 5 (the evidence
text really does differ round to round through round 5, by construction), then at round 6
genuinely judge evidence_delta:"none" (round 6's evidence text is textually IDENTICAL to round
5's own), which is the per-claim oscillation guard's real trigger condition -- stopping the loop
as NOT CONVERGED at round_count 6, never MINOR ISSUES ACKNOWLEDGED (severity was never
LOW/MEDIUM), and never stopping early at round 5 (which would only happen if MAX_ROUNDS had
incorrectly stayed 5 despite the round-1 HIGH-severity escalation).

Expected: exit_state NOT_CONVERGED, round_count 6 (NOT 5 -- the whole point of this scenario is
that MAX_ROUNDS was really lifted to 20 by round 1's escalation, so round 6 actually dispatches),
FAKE_CODEX_INVOCATION_LOG shows exactly 7 lines (6 dispatches -- 1 fresh + 5 resume -- plus 1
delete for Phase 3 cleanup), claims: one entry, claim_id "f1", disposition "open" (never closed),
threads: one entry kind:current cleanup:deleted (set FAKE_CODEX_CLEANUP_OK=1 on the Phase 3
--cleanup call).
EOF

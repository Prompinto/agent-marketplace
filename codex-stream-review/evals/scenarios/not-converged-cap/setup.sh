#!/usr/bin/env bash
# Scenario: not-converged-cap
# Targets: exit_state = NOT_CONVERGED, reached only by genuinely hitting the
# 20-round cap (SKILL.md's Guards: "Cap: R = 20 without convergence -> stop,
# report NOT CONVERGED"), never the oscillation guard short-circuiting early
# (that guard fires on evidence_delta:"none" -- this scenario's whole point
# is that a genuinely-differing evidence string each round gives a
# correctly-behaving orchestrator real grounds to judge evidence_delta:"new"
# every single round, so the loop must run its full course).
#
# Fixture repo is deliberately NOT eval_make_fixture_repo's off-by-one diff
# (that diff is a REAL bug -- a correctly-behaving Claude would just fix it
# and converge quickly, which is the opposite of what this scenario needs).
# Instead: a correct, benign uncommitted addition (a new sub() function) that
# Codex's scripted responses falsely claim has an "off-by-one" -- a genuine,
# sustained, evidence-unresolved FALSE-POSITIVE disagreement Claude should
# keep rebutting every round, never accepting/fixing anything (SKILL.md's
# Core Principles: "Never fake-clean. A genuine, evidence-unresolved
# disagreement is not convergence").
#
# Uses FAKE_CODEX_GROUP_STATE (see tests/fixtures/fake-codex's own header
# comment) to pre-populate 20 distinct round-N-final-answer.json files
# (N=0..19, played back in order across 20 separate real dispatch
# invocations -- round 1 is the fresh dispatch consuming round-0, rounds
# 2-20 are 19 --resume dispatches consuming round-1..round-19). Every file
# is schema-valid ISSUES verdict with the SAME finding_id "f1" (Claude's own
# claim_id, assigned identically every round since this is judged a
# re-raise of the same open claim -- see claim-ledger.md section 1) but a
# DIFFERENT "evidence" string literally naming the round number, per this
# scenario's own spec.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-not-converged-cap.XXXXXX")"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "eval@example.com"
git -C "$REPO_DIR" config user.name "ccs-eval"
printf 'def add(a, b):\n    return a + b\n' > "$REPO_DIR/lib.py"
git -C "$REPO_DIR" add lib.py
git -C "$REPO_DIR" commit -q -m "initial"
# A correct, benign uncommitted addition -- no real bug. Any "off-by-one"
# claim Codex's scripted responses make about this is objectively a false
# positive, so a correctly-behaving Claude has genuine grounds to keep
# rebutting it every round rather than ever wanting to "fix" it.
cat >> "$REPO_DIR/lib.py" <<'PYEOF'


def sub(a, b):
    return a - b
PYEOF

BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

GROUP_STATE="$(mktemp -d "/tmp/ccs-eval-not-converged-cap-state.XXXXXX")"
INVOCATION_LOG="$(mktemp "/tmp/ccs-eval-not-converged-cap-invocations.XXXXXX")"

DIMENSIONS='{"correctness":{"status":"checked","evidence":"reviewed the new sub() function"},"security":{"status":"not_applicable","evidence":"no security-relevant surface in this diff"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic, no performance concern"},"reuse":{"status":"not_applicable","evidence":"a small standalone helper, no reuse concern"},"contracts":{"status":"not_applicable","evidence":"no public contract change"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource/concurrency surface"},"intent":{"status":"checked","evidence":"matches the stated intent of adding a subtraction helper"}}'

for N in $(seq 0 19); do
  jq -nc --arg ev "observed in round $N's own re-read of line 42" --argjson dims "$DIMENSIONS" '
    {
      verdict: "ISSUES",
      findings: [
        {
          file: "lib.py",
          line: 4,
          severity: "medium",
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
    }' > "$GROUP_STATE/round-${N}-final-answer.json"
done

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "FAKE_CODEX_GROUP_STATE=$GROUP_STATE"
echo "FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG"
echo "FAKE_CODEX_SCENARIO=normal (set on every dispatch call -- FAKE_CODEX_GROUP_STATE's own per-round override takes priority over FAKE_CODEX_FINAL_ANSWER, so 'normal' is just what makes fake-codex actually emit a final answer at all)"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH, and FAKE_CODEX_GROUP_STATE/FAKE_CODEX_INVOCATION_LOG/
FAKE_CODEX_SCENARIO=normal set, on every dispatch call this run makes (see
codex-stream-review/evals/README.md's "Mechanical caveat"). Task text:
"review the uncommitted change in this fixture repo".

The agent actually driving this session must genuinely judge each round's
reassertion of finding f1 as evidence_delta:"new" (the evidence text really
does differ every round, by construction) and genuinely rebut it as a false
positive every round (the sub() diff has no real bug) -- never accept/fix
anything, never let the oscillation guard's evidence_delta:"none" condition
apply. This makes the loop run its full, real 20 rounds before hitting the
cap.

Expected: exit_state NOT_CONVERGED, round_count 20, FAKE_CODEX_INVOCATION_LOG
shows exactly 21 lines (20 dispatches -- 1 fresh + 19 resume -- plus 1
delete for Phase 3 cleanup), claims: one entry, claim_id "f1",
disposition "open" (never closed -- no DISPOSITION marker was ever
requested, since f1 was an actively-disputed, currently-appearing finding
every single round), threads: one entry kind:current cleanup:deleted (set
FAKE_CODEX_CLEANUP_OK=1 on the Phase 3 --cleanup call).
EOF

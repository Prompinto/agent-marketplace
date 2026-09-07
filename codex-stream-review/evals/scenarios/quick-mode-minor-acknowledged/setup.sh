#!/usr/bin/env bash
# Scenario: quick-mode-minor-acknowledged
# Targets: exit_state = MINOR_ISSUES_ACKNOWLEDGED, reached only under --quick, at exactly
# round_count 5 (the quick cap), with the sole open claim's own CANONICAL CURRENT SEVERITY
# cleanly "medium" (SKILL.md's Guards: "Quick-mode early stop -- MINOR ISSUES ACKNOWLEDGED").
#
# Same false-positive-disagreement technique as evals/scenarios/not-converged-cap (a correct,
# benign uncommitted addition; Codex's scripted responses falsely claim a defect in it every
# round, with a DIFFERENT evidence string each round so a correctly-behaving orchestrator has
# genuine grounds to judge evidence_delta:"new" every round and never trip the oscillation
# guard) -- just 5 scripted rounds instead of 20, under --quick, with severity "medium" (never
# "high"/"critical", so ESCALATED never flips and MAX_ROUNDS stays 5 for the whole run).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-quick-minor-ack.XXXXXX")"
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

GROUP_STATE="$(mktemp -d "/tmp/ccs-eval-quick-minor-ack-state.XXXXXX")"
INVOCATION_LOG="$(mktemp "/tmp/ccs-eval-quick-minor-ack-invocations.XXXXXX")"

DIMENSIONS='{"correctness":{"status":"checked","evidence":"reviewed the new sub() function"},"security":{"status":"not_applicable","evidence":"no security-relevant surface in this diff"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic, no performance concern"},"reuse":{"status":"not_applicable","evidence":"a small standalone helper, no reuse concern"},"contracts":{"status":"not_applicable","evidence":"no public contract change"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource/concurrency surface"},"intent":{"status":"checked","evidence":"matches the stated intent of adding a subtraction helper"}}'

for N in $(seq 0 4); do
  jq -nc --arg ev "observed in round $N's own re-read of line 4" --argjson dims "$DIMENSIONS" '
    {
      verdict: "ISSUES",
      findings: [
        {
          file: "lib.py",
          line: 4,
          severity: "medium",
          summary: "sub(a, b) has a minor style nit: missing a docstring",
          evidence: $ev,
          verification: "static reasoning about the style of sub()"
        }
      ],
      summary: "one open minor finding in sub()",
      dimensions: $dims
    }' > "$GROUP_STATE/round-${N}-final-answer.json"
done

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

The agent actually driving this session must genuinely judge each round's reassertion of
finding f1 as evidence_delta:"new" (the evidence text really does differ every round, by
construction) and genuinely rebut it as a minor style nit every round -- never accept/fix
anything, never let the oscillation guard's evidence_delta:"none" condition apply, and never let
severity be anything other than "medium" (no escalation should ever be judged). This makes the
loop run its real 5 quick-mode rounds, hit MAX_ROUNDS=5 while ESCALATED is still false, find K=1
open claim whose canonical current severity is cleanly "medium", and stop as MINOR ISSUES
ACKNOWLEDGED rather than NOT CONVERGED.

Expected: exit_state MINOR_ISSUES_ACKNOWLEDGED, round_count 5, FAKE_CODEX_INVOCATION_LOG shows
exactly 6 lines (5 dispatches -- 1 fresh + 4 resume -- plus 1 delete for Phase 3 cleanup),
claims: one entry, claim_id "f1", disposition "open" (never closed -- no DISPOSITION marker was
ever requested, since f1 was an actively-disputed, currently-appearing finding every single
round), threads: one entry kind:current cleanup:deleted (set FAKE_CODEX_CLEANUP_OK=1 on the
Phase 3 --cleanup call).
EOF

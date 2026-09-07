#!/usr/bin/env bash
# Scenario: quick-mode-missing-severity-fail-closed
# Targets: under --quick, hitting round 5 (MAX_ROUNDS, never escalated) with the sole open
# claim's severity MISSING (null) on every occurrence -- SKILL.md's Guards section's "Quick-mode
# early stop" bullet's own MISSING fail-closed subcase: "treat exactly like a value that fails
# the LOW/MEDIUM test, never as 'no data, so pass'". Confirms this correctly falls through to
# the NORMAL NOT CONVERGED cap handling, never MINOR_ISSUES_ACKNOWLEDGED.
#
# severity:null is schema-legal (schemas/review-verdict.schema.json's severity enum is
# low|medium|high|null) -- unlike an UNPARSEABLE string value, this is genuinely reachable via a
# real (or faithfully-scripted-fake) dispatch response, so this scenario drives a real live
# session exactly like its siblings, never bypassing the wrapper's own schema check.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-quick-missing-sev.XXXXXX")"
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

GROUP_STATE="$(mktemp -d "/tmp/ccs-eval-quick-missing-sev-state.XXXXXX")"
INVOCATION_LOG="$(mktemp "/tmp/ccs-eval-quick-missing-sev-invocations.XXXXXX")"

DIMENSIONS='{"correctness":{"status":"checked","evidence":"reviewed the new sub() function"},"security":{"status":"not_applicable","evidence":"no security-relevant surface in this diff"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic, no performance concern"},"reuse":{"status":"not_applicable","evidence":"a small standalone helper, no reuse concern"},"contracts":{"status":"not_applicable","evidence":"no public contract change"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource/concurrency surface"},"intent":{"status":"checked","evidence":"matches the stated intent of adding a subtraction helper"}}'

for N in $(seq 0 4); do
  jq -nc --arg ev "observed in round $N's own re-read of line 4" --argjson dims "$DIMENSIONS" '
    {
      verdict: "ISSUES",
      findings: [
        {
          file: "lib.py",
          line: 4,
          severity: null,
          summary: "sub(a, b) may have an off-by-one, severity not yet triaged",
          evidence: $ev,
          verification: "static reasoning about the arithmetic in sub()"
        }
      ],
      summary: "one open finding in sub(), severity not yet triaged",
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

The agent actually driving this session must genuinely judge each round's reassertion of finding
f1 as evidence_delta:"new" (the evidence text really does differ every round) and genuinely
rebut/investigate it every round without ever fixing it or requesting a disposition -- severity
is null (never triaged) every round, by construction. This makes the loop run its real 5
quick-mode rounds, hit MAX_ROUNDS=5 while ESCALATED is still false, find K=1 open claim whose
canonical current severity is MISSING (null) -- which fails the LOW/MEDIUM test per SKILL.md's
own fail-closed rule -- and fall through to NOT CONVERGED rather than MINOR ISSUES ACKNOWLEDGED.

Expected: exit_state NOT_CONVERGED, round_count 5, FAKE_CODEX_INVOCATION_LOG shows exactly 6
lines (5 dispatches -- 1 fresh + 4 resume -- plus 1 delete for Phase 3 cleanup), claims: one
entry, claim_id "f1", severity null, disposition "open" (never closed), threads: one entry
kind:current cleanup:deleted (set FAKE_CODEX_CLEANUP_OK=1 on the Phase 3 --cleanup call).
EOF

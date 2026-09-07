#!/usr/bin/env bash
# Scenario: claim-clean-resolution
# Targets: the claim ledger's happy path -- raise (round 1) -> real fix ->
# DISPOSITION <id>: RESOLVED marker (round 2) -> exit_state CLEAN.
# Single-reviewer (GROUP="main"). Uses FAKE_CODEX_GROUP_STATE to script a
# per-round transcript played back across two SEPARATE real dispatch
# invocations (fresh round 1, then --resume round 2) -- see
# tests/fixtures/fake-codex's own header comment for the exact mechanics:
# round-<N>-final-answer.json (N = the fixture's own 0-based invocation
# counter) overrides FAKE_CODEX_FINAL_ANSWER for that invocation only.
#
# round-0-final-answer.json (round 1's response): ISSUES, one finding f1 --
# the fixture repo's real off-by-one bug in lib.py (eval_make_fixture_repo's
# own standard uncommitted change: "return a + b + 1").
# round-1-final-answer.json (round 2's response): CLEAN, findings:[], and a
# summary containing a byte-exact "DISPOSITION f1: RESOLVED -- <reason>"
# marker (claim-ledger.md section 4's current grammar: column-zero, "--"
# separator, non-empty reason) -- requested because the driving agent
# applies a REAL fix to lib.py between round 1 and round 2 and asks for
# live re-confirmation (claim-ledger.md's "When to ask" condition (b)).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo claim-clean-resolution)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
GROUP_STATE_DIR="$(mktemp -d)"

cat > "$GROUP_STATE_DIR/round-0-final-answer.json" <<'EOF'
{"verdict":"ISSUES","findings":[{"file":"lib.py","line":2,"severity":"medium","summary":"add() returns a+b+1, an off-by-one error","evidence":"lib.py line 2 reads 'return a + b + 1' -- a function named add should return a+b, not a+b+1","verification":"read lib.py directly; the +1 term has no accompanying comment or test justifying it"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"found the off-by-one return value in add()"},"security":{"status":"not_applicable","evidence":"no security-relevant surface in this two-line diff"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic, no performance concern"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic introduced"},"contracts":{"status":"checked","evidence":"add()'s implicit contract (return the sum) is violated by the +1"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"checked","evidence":"the function name does not match the +1 behavior"}}}
EOF

cat > "$GROUP_STATE_DIR/round-1-final-answer.json" <<'EOF'
{"verdict":"CLEAN","findings":[],"summary":"DISPOSITION f1: RESOLVED -- lib.py now reads 'return a + b', the extra +1 has been removed and add() matches its intended contract.","dimensions":{"correctness":{"status":"checked","evidence":"re-read lib.py: add() now returns a + b with no offset"},"security":{"status":"not_applicable","evidence":"no security-relevant surface in this diff"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic, no performance concern"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic"},"contracts":{"status":"checked","evidence":"add()'s contract is now satisfied"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"checked","evidence":"behavior now matches the function's intended purpose"}}}
EOF

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "GROUP_STATE_DIR=$GROUP_STATE_DIR"
echo "FAKE_CODEX_SCENARIO=normal (set on EVERY dispatch call, so GROUP_STATE overrides are actually used)"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH, FAKE_CODEX_SCENARIO=normal, and
FAKE_CODEX_GROUP_STATE=<GROUP_STATE_DIR literal> set on EVERY dispatch call
this run makes (fresh round 1 AND the round-2 --resume call). Task text:
"review the uncommitted change in this fixture repo".

Expected sequence:
  1. Round 1 (fresh --uncommitted): fake-codex plays back round-0's ISSUES
     verdict (finding f1, the real off-by-one in lib.py). Claude verifies
     against the real file, judges it VALID, and ACTUALLY EDITS
     REPO_DIR/lib.py to remove the "+ 1" (a real fix, not simulated).
  2. Per claim-ledger.md's "When to ask" condition (b) (a fix was just
     applied in direct response to round 1's finding), round 2's own History
     text must explicitly name claim_id "f1" and request a
     "DISPOSITION f1: RESOLVED|RETRACTED|STILL OPEN -- <reason>" marker.
  3. Round 2 (--resume): fake-codex plays back round-1's CLEAN verdict
     carrying the "DISPOSITION f1: RESOLVED -- ..." marker in its summary.
     Claude's parser (claim-ledger.md section 4 grammar) validates it:
     column-zero, exactly one marker for the one requested claim_id, "--"
     separator, non-empty reason -> claim_closures: [{"claim_id":"f1",
     "disposition":"resolved","source_round":2,"marker_reason":"..."}].
  4. Convergence: round 2's own findings are empty, and the only claim ever
     raised (f1) now has a terminal disposition -> exit_state CLEAN.

Set FAKE_CODEX_CLEANUP_OK=1 on the Phase 3 --cleanup call.

Expected result: exit_state CLEAN, round_count 2, threads: one entry
kind:current cleanup:deleted, claims: one entry {"claim_id":"f1",
"disposition":"resolved","source_round":2}.
EOF

#!/usr/bin/env bash
# Scenario: claim-still-open-marker
# Targets: a valid "DISPOSITION <id>: STILL OPEN -- <reason>" marker
# (claim-ledger.md section 4) produces NO claim_closures[] entry -- the
# claim stays "open", never silently treated as resolved just because a
# marker line existed. This is the one marker state that intentionally does
# NOT terminate the claim.
#
# Round 1 raises f1 (the fixture's real off-by-one). Claude applies a real
# but GENUINELY INSUFFICIENT fix (adds a clarifying comment, does not
# remove the actual "+ 1") -- a real code edit in direct response to round
# 1's finding, which per claim-ledger.md's "When to ask" condition (b)
# justifies round 2's focus requesting a disposition confirmation. Round 2's
# scripted response reasserts f1 (the underlying defect and evidence are
# UNCHANGED -- only a comment was added) and answers with
# "DISPOSITION f1: STILL OPEN -- <reason>". Claude's verification pass
# judges this a re-raise of the same open claim with evidence_delta "none"
# (the actual defect/evidence is identical to round 1's) -- this
# simultaneously (a) fires the oscillation guard (adjacent-round
# reassertion with no new evidence -- NOT_CONVERGED) and (b) the STILL OPEN
# marker itself produces no claim_closures[] entry either way. Both facts
# are independently true and jointly asserted by expect.sh: the run does
# not reach CLEAN, and the claim's own disposition is "open", never
# "resolved".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo claim-still-open-marker)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
GROUP_STATE_DIR="$(mktemp -d)"

cat > "$GROUP_STATE_DIR/round-0-final-answer.json" <<'EOF'
{"verdict":"ISSUES","findings":[{"file":"lib.py","line":2,"severity":"medium","summary":"add() returns a+b+1, an off-by-one error","evidence":"lib.py line 2 reads 'return a + b + 1' -- a function named add should return a+b, not a+b+1","verification":"read lib.py directly; the +1 term has no accompanying comment or test justifying it"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"found the off-by-one return value in add()"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic"},"contracts":{"status":"checked","evidence":"add()'s implicit contract is violated by the +1"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"checked","evidence":"the function name does not match the +1 behavior"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF

cat > "$GROUP_STATE_DIR/round-1-final-answer.json" <<'EOF'
{"verdict":"ISSUES","findings":[{"file":"lib.py","line":3,"severity":"medium","summary":"add() still returns a+b+1, an off-by-one error","evidence":"lib.py's return statement still reads 'return a + b + 1' -- a clarifying comment was added but the return value itself is unchanged","verification":"re-read lib.py; the +1 term is still present, only a comment was added above it"}],"summary":"DISPOSITION f1: STILL OPEN -- the return statement still adds +1; the added comment does not fix the underlying defect.","dimensions":{"correctness":{"status":"checked","evidence":"the off-by-one from round 1 is still present, unchanged"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic"},"contracts":{"status":"checked","evidence":"add()'s implicit contract is still violated"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"checked","evidence":"still does not match the function's intent"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "GROUP_STATE_DIR=$GROUP_STATE_DIR"
echo "FAKE_CODEX_SCENARIO=normal (set on EVERY dispatch call)"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH, FAKE_CODEX_SCENARIO=normal, and
FAKE_CODEX_GROUP_STATE=<GROUP_STATE_DIR literal> set on EVERY dispatch call
(fresh round 1, round-2 resume). Task text: "review the uncommitted change
in this fixture repo".

Expected sequence:
  1. Round 1 (fresh --uncommitted): ISSUES, finding f1 (the real off-by-one
     in lib.py). Claude applies a REAL but insufficient fix -- adds a
     clarifying comment above the return statement, does NOT remove the
     "+ 1" -- and, per claim-ledger.md's "When to ask" condition (b) (a fix
     was just applied in direct response to round 1's finding), round 2's
     own focus explicitly names f1 and requests a DISPOSITION confirmation.
  2. Round 2 (--resume): ISSUES, reasserting f1 with evidence unchanged from
     round 1 (the actual defect is untouched -- only a comment was added),
     plus "DISPOSITION f1: STILL OPEN -- ..." in the summary.
  3. Claude's verification pass: same claim (f1), evidence identical to its
     own most recent prior occurrence -> evidence_delta "none". This BOTH
     fires the oscillation guard (adjacent-round reassertion with no new
     evidence -> NOT_CONVERGED) AND the STILL OPEN marker parses validly
     but produces no claim_closures[] entry either way (STILL OPEN never
     closes a claim, per claim-ledger.md section 4) -- the claim's own
     disposition stays "open" for both independent reasons.

Set FAKE_CODEX_CLEANUP_OK=1 on the Phase 3 --cleanup call.

Expected result: exit_state NOT_CONVERGED (never CLEAN off this alone),
round_count 2, threads: one entry kind:current cleanup:deleted, claims: one
entry {"claim_id":"f1","disposition":"open","source_round":null,
"marker_reason":null}.
EOF

#!/usr/bin/env bash
# Scenario: claim-oscillation-nonconsecutive
# Targets: references/claim-ledger.md section 7's oscillation guard, scoped
# PER-CLAIM (not "the last two rounds") -- a claim raised in round 1, silent
# in round 2, reasserted with NO NEW EVIDENCE in round 3 must be caught. The
# OLD "zero progress twice in a row" guard this section replaced only ever
# compared adjacent rounds and would have missed this exact pattern (round 2
# looks like "progress" since the claim vanished; round 3's reassertion is
# two rounds away from round 1, not adjacent to it).
#
# No DISPOSITION marker is needed anywhere in this transcript -- per
# claim-ledger.md's "When to ask" rule, round 2's own focus construction (no
# fix applied, claim DID appear in round 1) does not yet justify a
# disposition request; round 3's WOULD (claim absent from round 2), so
# round 3's own focus does request one, but the fake-codex round-3 response
# below deliberately does NOT answer with a marker -- it just silently
# reasserts the same finding as an ordinary ISSUES finding instead. This is
# realistic (Codex is not obligated to always comply) and demonstrates the
# oscillation guard fires independently of marker compliance: the guard is
# gated purely on Claude's own evidence_delta judgment during the normal
# per-finding verification pass, not on whether a marker was ever received.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo claim-oscillation-nonconsecutive)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
GROUP_STATE_DIR="$(mktemp -d)"

cat > "$GROUP_STATE_DIR/round-0-final-answer.json" <<'EOF'
{"verdict":"ISSUES","findings":[{"file":"lib.py","line":2,"severity":"medium","summary":"add() returns a+b+1, an off-by-one error","evidence":"lib.py line 2 reads 'return a + b + 1' -- a function named add should return a+b, not a+b+1","verification":"read lib.py directly; the +1 term has no accompanying comment or test justifying it"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"found the off-by-one return value in add()"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic"},"contracts":{"status":"checked","evidence":"add()'s implicit contract is violated by the +1"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"checked","evidence":"the function name does not match the +1 behavior"}}}
EOF

cat > "$GROUP_STATE_DIR/round-1-final-answer.json" <<'EOF'
{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"no other issues found this round"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic"},"contracts":{"status":"not_applicable","evidence":"n/a"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"not_applicable","evidence":"n/a"}}}
EOF

cat > "$GROUP_STATE_DIR/round-2-final-answer.json" <<'EOF'
{"verdict":"ISSUES","findings":[{"file":"lib.py","line":2,"severity":"medium","summary":"add() returns a+b+1, an off-by-one error","evidence":"lib.py line 2 reads 'return a + b + 1' -- a function named add should return a+b, not a+b+1","verification":"read lib.py directly; the +1 term has no accompanying comment or test justifying it"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"the same off-by-one from earlier is still present"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic"},"contracts":{"status":"checked","evidence":"add()'s implicit contract is still violated"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"checked","evidence":"still does not match the function's intent"}}}
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
uncommitted change in this fixture repo". Do NOT fix lib.py's real
off-by-one at any point in this run -- the whole point is that Codex's own
evidence about it never changes across its three appearances.

Expected sequence:
  1. Round 1 (fresh --uncommitted): ISSUES, finding f1 (the real off-by-one
     in lib.py). Claude judges it valid but, for this scenario, defers the
     fix (action: parked/accept-fix-pending) rather than fixing immediately
     -- no code change this round.
  2. Round 2's own focus recaps "f1 acknowledged, addressing separately" as
     normal History -- per "When to ask," no disposition is requested (f1
     DID appear in round 1, no fix was applied).
  3. Round 2 (--resume): CLEAN, findings:[] -- Codex goes silent on f1 this
     round (no marker, no reassertion).
  4. Per "When to ask" condition (a) (f1 is open and absent from round 2's
     own findings, the most recently completed round), round 3's own focus
     DOES explicitly name f1 and request a DISPOSITION marker.
  5. Round 3 (--resume): ISSUES, reasserting the IDENTICAL f1 finding
     (same file/line/summary/evidence as round 1, verbatim) -- Codex does
     NOT answer with a DISPOSITION marker, it just silently re-raises the
     same finding as an ordinary finding instead.
  6. Claude's verification pass on round 3: this is the SAME claim as f1
     (same file/line/evidence), an open claim with no closure yet ->
     claim_id "f1". Compare this occurrence's evidence to f1's own most
     recent prior occurrence (round 1's) -- identical wording/evidence ->
     evidence_delta "none".
  7. Per claim-ledger.md section 7 (and SKILL.md's Guards): the moment an
     open claim is reasserted with evidence_delta "none" since its own most
     recent PRIOR occurrence, REGARDLESS of how many other rounds
     intervened -- stop early, report NOT CONVERGED. This is exactly the
     non-consecutive case (round 1 -> silent round 2 -> reasserted round 3)
     the OLD adjacent-rounds-only guard would have missed.

Set FAKE_CODEX_CLEANUP_OK=1 on the Phase 3 --cleanup call.

Expected result: exit_state NOT_CONVERGED, round_count 3, threads: one
entry kind:current cleanup:deleted, claims: one entry {"claim_id":"f1",
"disposition":"open","source_round":null,"marker_reason":null}.
EOF

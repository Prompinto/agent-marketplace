#!/usr/bin/env bash
# Scenario: parallel-group-namespaced-claims
# Targets: two groups each raise their OWN finding numbered "f1" (each
# group's own resumable Codex thread has its own independent, thread-local
# finding-numbering scheme -- there is no reason two different threads'
# numbering would ever coordinate) -- confirms Claude's own claim_id
# bookkeeping group-prefixes them ("g1:f1", "g2:f1") so they never collide,
# both independently reaching disposition:"resolved" via their own
# DISPOSITION marker in round 2.
#
# g1's finding: the fixture's real off-by-one bug in lib.py (correctness
# dimension). g2's finding: a fabricated-but-plausible reuse/intent finding
# about stub_1.py lacking a docstring -- independently, trivially fixable,
# so both groups can get a REAL fix applied without touching the same file.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo_sized parallel-group-namespaced-claims 23)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
G1_STATE="$(mktemp -d)"
G2_STATE="$(mktemp -d)"

cat > "$G1_STATE/round-0-final-answer.json" <<'EOF'
{"verdict":"ISSUES","findings":[{"file":"lib.py","line":2,"severity":"medium","summary":"add() returns a+b+1, an off-by-one error","evidence":"lib.py line 2 reads 'return a + b + 1' -- a function named add should return a+b, not a+b+1","verification":"read lib.py directly; the +1 term has no accompanying comment or test justifying it"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"found the off-by-one return value in add()"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic beyond this diff's own scope"},"contracts":{"status":"checked","evidence":"add()'s implicit contract is violated by the +1"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"checked","evidence":"the function name does not match the +1 behavior"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF
cat > "$G1_STATE/round-1-final-answer.json" <<'EOF'
{"verdict":"CLEAN","findings":[],"summary":"DISPOSITION g1:f1: RESOLVED -- lib.py now reads 'return a + b', the extra +1 has been removed.","dimensions":{"correctness":{"status":"checked","evidence":"re-read lib.py: add() now returns a + b"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial arithmetic"},"reuse":{"status":"not_applicable","evidence":"no duplicated logic"},"contracts":{"status":"checked","evidence":"add()'s contract is now satisfied"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"checked","evidence":"behavior now matches intent"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF

cat > "$G2_STATE/round-0-final-answer.json" <<'EOF'
{"verdict":"ISSUES","findings":[{"file":"stub_1.py","line":1,"severity":"low","summary":"stub_1() has no docstring explaining why it returns the literal 1","evidence":"stub_1.py's only function has no docstring or comment; a reader cannot tell whether the literal return value is meaningful or arbitrary","verification":"read stub_1.py directly; no docstring present"}],"summary":null,"dimensions":{"correctness":{"status":"not_applicable","evidence":"the returned value itself is not wrong, just undocumented"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial function"},"reuse":{"status":"checked","evidence":"every stub_N() in this diff shares this same undocumented pattern"},"contracts":{"status":"not_applicable","evidence":"n/a"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"checked","evidence":"intent of the literal return value is unclear without documentation"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF
cat > "$G2_STATE/round-1-final-answer.json" <<'EOF'
{"verdict":"CLEAN","findings":[],"summary":"DISPOSITION g2:f1: RESOLVED -- stub_1.py now has a docstring explaining the return value.","dimensions":{"correctness":{"status":"not_applicable","evidence":"n/a"},"security":{"status":"not_applicable","evidence":"no security-relevant surface"},"performance":{"status":"not_applicable","evidence":"trivial function"},"reuse":{"status":"checked","evidence":"re-read stub_1.py: a docstring is now present"},"contracts":{"status":"not_applicable","evidence":"n/a"},"resources_concurrency":{"status":"not_applicable","evidence":"no resource or concurrency surface"},"intent":{"status":"checked","evidence":"intent is now documented"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF

G1_LOG="$(mktemp -u /tmp/ccs-eval-g1-invocations.XXXXXX)"
G2_LOG="$(mktemp -u /tmp/ccs-eval-g2-invocations.XXXXXX)"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "G1_STATE=$G1_STATE"
echo "G2_STATE=$G2_STATE"
echo "G1_INVOCATION_LOG=$G1_LOG"
echo "G2_INVOCATION_LOG=$G2_LOG"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH on EVERY Bash call. Task text: "review the uncommitted
change in this fixture repo". Dispatch 2 parallel groups (g1 correctness,
g2 reuse/intent).

CRITICAL: bind FAKE_CODEX_GROUP_STATE inline, per-command, to G1_STATE on
g1's own dispatch lines and to G2_STATE on g2's own dispatch lines --
NEVER a shared `export` mutated between the two concurrent background
dispatch launches (tests/fixtures/fake-codex's own doc comment). Same for
FAKE_CODEX_INVOCATION_LOG (G1_LOG / G2_LOG respectively) and
FAKE_CODEX_SCENARIO=normal (needed on every dispatch call so the
GROUP_STATE override is actually consulted).

Expected sequence:
  1. Round 1 (both groups concurrently): g1 gets ISSUES with a finding it
     numbers "f1" internally (the real lib.py off-by-one); g2 gets ISSUES
     with its OWN, independently-numbered "f1" (stub_1.py's missing
     docstring) -- same raw id, different groups, different underlying
     defects. Claude assigns claim_id "g1:f1" and "g2:f1" respectively
     (group-prefixed, per claim-ledger.md section 1/9) -- verify these
     never collide despite the identical raw numbering.
  2. Claude applies a REAL fix for each: removes lib.py's "+ 1", adds a
     one-line docstring to stub_1.py.
  3. Per claim-ledger.md's "When to ask" condition (b), each group's own
     round-2 focus explicitly names ITS OWN full claim_id ("g1:f1" for
     g1's own thread, "g2:f1" for g2's own thread -- a group's own Codex
     thread only ever sees requests/markers framed in ITS OWN focus text)
     and requests a DISPOSITION confirmation.
  4. Round 2 (both groups' --resume, concurrently): g1 responds CLEAN with
     "DISPOSITION g1:f1: RESOLVED -- ..."; g2 responds CLEAN with
     "DISPOSITION g2:f1: RESOLVED -- ...". Both parse validly (per
     claim-ledger.md section 4's known-id-first matching, required
     specifically because a parallel-mode claim_id itself contains a colon).
  5. Convergence: both groups' round-2 findings are empty and both claims
     (g1:f1, g2:f1) now have a terminal disposition -> exit_state CLEAN.

Set FAKE_CODEX_CLEANUP_OK=1 on both Phase 3 --cleanup calls.

Expected result: exit_state CLEAN, round_count 2, threads: two entries
(one per group), both kind:current cleanup:deleted, claims: two entries --
{"claim_id":"g1:f1","disposition":"resolved","source_round":2} and
{"claim_id":"g2:f1","disposition":"resolved","source_round":2} -- confirm
these two claim_ids never collide.
EOF

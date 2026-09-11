#!/usr/bin/env bash
# Scenario: snapshot-integrity-failure
# Targets: exit_state = SNAPSHOT_INTEGRITY_FAILURE (terminal-status matrix).
# See skills/ccs/references/snapshot-integrity.md for the full mechanism: a
# SHA-256 hash of the reviewed subject (the repo diff), taken once at round
# 1, revalidated before every round 2+ dispatch. A round 2 must genuinely be
# reached for this check to ever run at all (round 1 never runs it -- "there
# is nothing yet to revalidate against"), so round 1 must NOT converge:
# fake-codex's round-1 response is a real ISSUES finding Claude genuinely
# accepts and fixes, leaving the claim open (accept-only, no closure yet --
# per claim-ledger.md section 6, an accept-only claim does not satisfy
# CLEAN), which forces a real round 2 dispatch attempt.
#
# The actual corruption (deleting SNAPSHOT_FILE) is NOT done by this
# setup.sh -- SNAPSHOT_FILE is allocated live, mid-run, by the driving agent
# itself (per SKILL.md's own allocation timing: right after Phase 1's
# sizing step, using the session's own literal SNAPSHOT_FILE path, which
# setup.sh cannot know in advance). The driving agent must delete/corrupt it
# itself, live, between round 1 completing and round 2's revalidation check.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo snapshot-integrity-failure)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="$(mktemp "/tmp/ccs-eval-snapshot-integrity-invocations.XXXXXX")"

FINAL_ANSWER='{"verdict":"ISSUES","findings":[{"file":"lib.py","line":3,"severity":"medium","summary":"off-by-one: add(a, b) returns a + b + 1, should return a + b","evidence":"re-read lib.py directly: the return statement adds an extra + 1 with no justification","verification":"static reasoning about the arithmetic"}],"summary":"one open finding","dimensions":{"correctness":{"status":"checked","evidence":"reviewed add()"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"checked","evidence":"e"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}'

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG"
echo "FAKE_CODEX_SCENARIO=normal"
echo "FAKE_CODEX_FINAL_ANSWER=$FINAL_ANSWER"
cat <<EOF

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH and FAKE_CODEX_SCENARIO=normal, FAKE_CODEX_FINAL_ANSWER
(the literal JSON above), FAKE_CODEX_INVOCATION_LOG set, on round 1's
dispatch call (see codex-stream-review/evals/README.md's "Mechanical
caveat"). Task text: "review the uncommitted change in this fixture repo".

Round 1: the fixture's diff genuinely has this off-by-one (eval_make_fixture_repo's own deliberate
bug), so Claude should genuinely ACCEPT this finding and apply the real fix (remove the extraneous
"+ 1" from lib.py's add()) -- this is a real code edit the driving agent must actually make. The
claim (f1) stays open (accept-only, no DISPOSITION closure yet -- Claude would only request one on
round 2's own focus text, which never gets to dispatch). This forces a genuine round 2 attempt.

Immediately before round 2's own snapshot-revalidation check (skills/ccs/references/snapshot-integrity.md
-- runs BEFORE any --resume dispatch that round), the driving agent must itself delete (or
truncate/corrupt) the session's own SNAPSHOT_FILE (the literal mktemp'd path it allocated right
after Phase 1's sizing step) -- e.g. \`rm -f "\$SNAPSHOT_FILE"\`. Do NOT set FAKE_CODEX_SCENARIO for
round 2 at all -- round 2 must never reach a codex dispatch, so no fake-codex invocation should ever
be logged for it. Confirm the revalidation check (missing file, or hash mismatch if truncated
instead) reports SNAPSHOT_INTEGRITY_FAILURE for real.

Expected: exit_state SNAPSHOT_INTEGRITY_FAILURE, claims null, round_count 1 (only round 1 ever
completed and was durably logged), threads: one entry kind:current cleanup:deleted
(FAKE_CODEX_CLEANUP_OK=1 on the unconditional Phase 3 --cleanup call -- runs even though this
session never used --keep-evidence, since this exception applies regardless). FAKE_CODEX_INVOCATION_LOG
must show exactly 2 lines total: one "mode=fresh" (round 1) and one "mode=delete" (Phase 3 cleanup)
-- confirming round 2 never actually invoked codex, real or fake.
EOF

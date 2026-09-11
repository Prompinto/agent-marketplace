#!/usr/bin/env bash
# Scenario: material-reviewed-false-never-resumed
# Targets: run-ccs-review.sh's schema_mismatch extension (Task 5/7 of
# docs/superpowers/plans/2026-09-10-ccs-material-verification.md) -- a response setting
# material_reviewed:false, even with a nonempty ISSUES findings array (not just CLEAN), is
# rejected with a detail carrying the literal substring "no_material_reviewed", which
# references/retry-guards.md's dedicated recovery routes to: abandon the thread, one bounded
# fresh restart (this session's own round 1 recurring, since the hollow attempt never produced a
# valid round-1 result), never a --resume.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo material-reviewed-false-never-resumed)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-material-reviewed-false-never-resumed-invocation.log"
: > "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
cat <<'EOF'

NOTE: this scenario's real evidence comes from dispatching run-ccs-review.sh directly against
REPO_DIR (bypassing full skill orchestration), not from a live /ccs session end-to-end -- a live
session applying SKILL.md's Phase 2 step 1 to the restart's own active receipt schedule would hit
a null-pair no_material_reviewed instead of CLEAN. See this scenario's own README.md ("Scope of
what this scenario actually proves") for the full explanation.

Next step (run by hand or have a Claude Code agent do it): dispatch run-ccs-review.sh directly
against REPO_DIR, with BIN_DIR prepended to PATH on EVERY Bash call made during this run, and
FAKE_CODEX_INVOCATION_LOG set to the printed INVOCATION_LOG path on every dispatch/cleanup call
(reproducing what /ccs's own Phase 1 Step 1 would run). Task framing: "review the uncommitted
change in this fixture repo".

Before dispatching round 1, set on that ONE call only:
  export FAKE_CODEX_SCENARIO=schema_mismatch
  export FAKE_CODEX_FINAL_ANSWER='{"verdict":"ISSUES","findings":[{"file":"lib.py","line":2,"severity":"low","summary":"s","evidence":"e","verification":"v"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":false,"material_receipt":null,"material_receipt_index":null}'

Expected: round 1's fresh dispatch is rejected as schema_mismatch (material_reviewed:false despite
a nonempty findings array), detail carries the literal substring "no_material_reviewed", the
thread is abandoned (added to LEAKED_THREAD_IDS, never --resume'd), and exactly ONE fresh restart
is attempted -- still round 1 (the hollow attempt never produced a valid round-1 result, so the
restart occupies round 1's own single slot, per retry-guards.md's round-1-vs-round-2+
disambiguation).

For the restart's own dispatch, unset FAKE_CODEX_FINAL_ANSWER and set FAKE_CODEX_SCENARIO=normal
so it returns a genuine CLEAN response -- confirming the session reaches CLEAN via the restart, on
a NEW thread id, never the original one. No --receipt-slot/--receipt-schedule-file flags are
needed for either dispatch -- the wrapper's material_reviewed:false check fires unconditionally,
before any receipt-schedule-dependent logic.
EOF

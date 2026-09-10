#!/usr/bin/env bash
# Scenario: compact-byte-budget-exceeded
# Targets: references/compaction.md's "Byte-budget preflight" -- the assembled focus text
# (COMPACT_DIGEST + Why/Scope/SCOPE-CONSTRAINT) exceeds COMPACT_BYTE_BUDGET (120,000 bytes)
# BEFORE any real dispatch is attempted for the compaction candidate -- this is a LOCAL,
# pre-dispatch latch (compaction_disabled_reason="byte_budget_exceeded"), never a wrapper
# ok:false response. The round falls straight through to an ordinary --resume fallback on the
# OLD thread, with ZERO extra fresh dispatches for the failed compaction attempt itself.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo compact-byte-budget-exceeded)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-compact-byte-budget-exceeded-invocation.log"
: > "$INVOCATION_LOG"

# A single finding whose own "evidence" field is ~130,000 bytes of repeated text -- large enough
# on its own that the open-claim section of COMPACT_DIGEST alone exceeds COMPACT_BYTE_BUDGET
# (120,000 bytes), regardless of anything else in the assembled focus text.
HUGE_EVIDENCE_JSON="$(python3 -c "
import json
print(json.dumps('x' * 130000))
")"
ROUND1_ANSWER_FILE="$(mktemp)"
python3 -c "
import json
print(json.dumps({
  'verdict': 'ISSUES',
  'findings': [{'file':'lib.py','line':2,'severity':'low','summary':'huge finding for byte-budget test','evidence': $HUGE_EVIDENCE_JSON,'verification':'v'}],
  'summary': None,
  'dimensions': {d: {'status':'checked','evidence':'e'} for d in ['correctness','security','performance','reuse','contracts','resources_concurrency','intent']},
  'material_reviewed': True,
  'material_receipt': None,
  'material_receipt_index': None
}))
" > "$ROUND1_ANSWER_FILE"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "ROUND1_ANSWER_FILE=$ROUND1_ANSWER_FILE"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs --compact against REPO_DIR, with BIN_DIR prepended to PATH on EVERY
Bash call made during this run, and FAKE_CODEX_INVOCATION_LOG set to the printed INVOCATION_LOG
path on every dispatch/cleanup call. Task text: "--compact review the uncommitted change in this
fixture repo".

Expected sequence:
  1. Round 1: fresh --uncommitted, FAKE_CODEX_SCENARIO=normal,
     FAKE_CODEX_FINAL_ANSWER="$(cat "$ROUND1_ANSWER_FILE")" (the huge-evidence finding above),
     FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}' -- threadId A,
     triggers compaction for round 2.
  2. Round 2 (compaction ATTEMPT, not a real dispatch): build COMPACT_DIGEST -- the one open
     claim's own evidence text (~130,000 bytes) is included verbatim (open claims are never
     truncated). Measure the assembled focus text (digest + Why/Scope/SCOPE-CONSTRAINT) exactly
     via `wc -c`: comfortably over COMPACT_BYTE_BUDGET (120,000 bytes) from the evidence text
     alone. This is a LOCAL preflight failure -- NO fresh dispatch is ever attempted for the
     compaction candidate. Record compaction_disabled_reason="byte_budget_exceeded" on round 2's
     own JSONL line (compaction_attempt_failure_count is NOT incremented for this specific
     cause). Fall through to an ORDINARY --resume dispatch against thread A (the still-alive old
     thread) as round 2's real outcome -- FAKE_CODEX_SCENARIO=normal,
     FAKE_CODEX_USAGE_JSON='{"input_tokens":200000,"output_tokens":10000}', with a DISPOSITION
     marker resolving round 1's own huge finding (RETRACTED or RESOLVED -- pick RESOLVED, "fixed
     the underlying issue"). Session converges CLEAN at round 2, still using thread A throughout
     (compaction never actually replaced it).
  3. Phase 3: --cleanup A only (GROUP_THREADS -- there was never a second thread B, since the
     compaction attempt never dispatched at all) -- FAKE_CODEX_CLEANUP_OK=1.

Expected exit_state: CLEAN, round_count: 2. threads: exactly ONE entry --
{"group":"main","thread_id":A,"kind":"current","cleanup":"deleted"} -- NO "leaked" entry at all,
since no new thread was ever created for the failed compaction attempt.
Invocation log: exactly 1 "mode=fresh" line (round 1 only) and exactly 1 "mode=resume" line
(round 2's fallback, against A) -- proof the compaction ATTEMPT itself never reached a real
dispatch call at all.
EOF

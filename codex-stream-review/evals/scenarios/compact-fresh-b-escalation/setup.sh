#!/usr/bin/env bash
# Scenario: compact-fresh-b-escalation
# Targets: references/compaction.md's "Retry topology" fresh-B escalation -- candidate A's own
# fresh dispatch gets a real threadId, then BOTH bounded --resume retries fail too (3
# consecutive nonzero_exit failures total), exhausting A per bullet 3's ordinary escalation.
# Falls back to ONE fresh retry with a brand NEW thread B, abandoning A --
# compaction_attempt_failed_thread becomes [A]. B's own dispatch SUCCEEDS, becoming the new
# active thread. The pre-existing OLD thread from round 1 is untouched throughout (it is never
# part of the compaction attempt's own retry sequence at all) and is separately moved to
# LEAKED_THREAD_IDS once B's success promotes the snapshot.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo compact-fresh-b-escalation)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-compact-fresh-b-escalation-invocation.log"
: > "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs --compact against REPO_DIR, with BIN_DIR prepended to PATH on EVERY
Bash call made during this run, and FAKE_CODEX_INVOCATION_LOG set to the printed INVOCATION_LOG
path on every dispatch/cleanup call. Task text: "--compact review the uncommitted change in this
fixture repo".

Expected sequence:
  1. Round 1: fresh --uncommitted, FAKE_CODEX_SCENARIO=normal,
     FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}' -- CLEAN verdict,
     threadId OLD captured. Triggers compaction for round 2.
  2. Round 2 (COMPACTION round) -- candidate A's own attempt sequence:
     a. Fresh --uncommitted dispatch (candidate A), FAKE_CODEX_SCENARIO=exit_nonzero -- real
        threadId (call it A) captured despite the failure (fake-codex emits thread.started
        before failing).
     b. Wait 5s, --resume A --timeout 300, FAKE_CODEX_SCENARIO=exit_nonzero -- fails the same
        way.
     c. Wait 15s, --resume A --timeout 300, FAKE_CODEX_SCENARIO=exit_nonzero -- fails the same
        way. Both bounded resume retries now exhausted (bullet 3's ordinary escalation: 3
        consecutive failures for candidate A).
     d. Fresh-B escalation: dispatch thread B fresh (--uncommitted), abandoning A --
        compaction_attempt_failed_thread=[A]. FAKE_CODEX_SCENARIO=normal,
        FAKE_CODEX_USAGE_JSON='{"input_tokens":400000,"output_tokens":20000}' -- SUCCEEDS, CLEAN
        verdict, new real threadId B. COMPACTION_BASELINE_TOKENS=400000 (comfortably under
        threshold).
  3. Ordering on success: B is added to LEAKED_THREAD_IDS provisionally, round 2's JSONL line is
     appended (compacted_from_thread=OLD, compaction_attempt_failed_thread=[A],
     compaction_attempt_execution=[<A's 3 failed attempts' own execution objects, in order>],
     candidate_snapshot_path, snapshot_digest_before/after, compaction_attempt_failure_count=0,
     coverage_source), append-verify passes, promotion succeeds. B becomes the new
     GROUP_THREADS entry; OLD moves to LEAKED_THREAD_IDS.
  4. Session converges CLEAN at round 2.
  5. Phase 3: --cleanup B (current), --cleanup OLD (leaked), --cleanup A (leaked) -- ALL THREE
     with FAKE_CODEX_CLEANUP_OK=1.

Expected exit_state: CLEAN, round_count: 2. threads: THREE entries --
{"group":"main","thread_id":B,"kind":"current","cleanup":"deleted"},
{"group":"main","thread_id":OLD,"kind":"leaked","cleanup":"deleted"}, and
{"group":"main","thread_id":A,"kind":"leaked","cleanup":"deleted"} -- BOTH abandoned threads
(the pre-compaction OLD thread AND the exhausted candidate A) really were cleaned up, not just
recorded.
Invocation log: exactly 3 "mode=fresh" lines (round 1's OLD, candidate A's original attempt,
thread B's fresh dispatch -- three DIFFERENT thread_id values, in that ORDER) and exactly 2
"mode=resume" lines (both against A, both appearing AFTER A's own fresh line and BEFORE B's own
fresh line in the log).
EOF

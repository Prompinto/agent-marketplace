#!/usr/bin/env bash
# Scenario: compact-trigger-uncommitted-success
# Targets: references/compaction.md's basic trigger-and-restart path for --uncommitted scope --
# round 1's own execution.usage.input_tokens crosses COMPACT_THRESHOLD (8,000,000), so round 2
# becomes a genuine fresh --uncommitted COMPACTION round (never --resume) instead of an ordinary
# resume. The compaction dispatch succeeds on its first attempt with a comfortably-under-threshold
# baseline, so no circuit breaker engages and the session converges CLEAN at round 2.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo compact-trigger-uncommitted-success)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-compact-trigger-uncommitted-success-invocation.log"
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

Expected sequence, per skills/ccs/references/compaction.md's Trigger + Restart mechanism:
  1. Round 1: fresh --uncommitted dispatch, FAKE_CODEX_SCENARIO=normal,
     FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}' -- CLEAN verdict, a
     real threadId (call it A) is captured. execution.usage.input_tokens (9,000,000) is >=
     COMPACT_THRESHOLD (8,000,000) -- this triggers compaction for round 2.
  2. Between round 1's own append and round 2's dispatch: the existing round-2+ snapshot
     revalidation runs first (it passes, nothing has touched SNAPSHOT_FILE), THEN the threshold
     check fires and compaction is attempted for round 2.
  3. Round 2 (the COMPACTION round): build and verify COMPACT_DIGEST (round 1 had zero open
     claims, since round 1 was itself CLEAN with no findings -- the digest's own open-claim
     section is empty, closed-claim section is empty too). Dispatch a FRESH --uncommitted call
     (never --resume) against the SAME REPO_DIR, focus text = COMPACT_DIGEST + the original Why/
     Scope (from target.original_scope_framing) + the SCOPE CONSTRAINT/collaboration frame (no
     DISPOSITION requests needed, since there are no open claims to ask about).
     FAKE_CODEX_SCENARIO=normal, FAKE_CODEX_USAGE_JSON='{"input_tokens":500000,
     "output_tokens":30000}' -- CLEAN verdict, a NEW real threadId (call it B) is captured. This
     becomes COMPACTION_BASELINE_TOKENS=500000, comfortably under COMPACT_THRESHOLD -- no circuit
     breaker engages.
  4. Ordering on success: the new thread B is added to LEAKED_THREAD_IDS provisionally, round 2's
     JSONL line is appended (target.scope="uncommitted", compacted_from_thread=A,
     candidate_snapshot_path=<mktemp path>, snapshot_digest_before=<round 1's digest>,
     snapshot_digest_after=<round 2's candidate digest>, compaction_attempt_failure_count=0,
     coverage_source={"status":"complete",...}), append-verify passes. THEN promotion: re-hash
     both the active SNAPSHOT_FILE (against snapshot_digest_before) and the candidate (against
     snapshot_digest_after) -- both pass -- then `mv` the candidate onto SNAPSHOT_FILE, advance
     the remembered SNAPSHOT_DIGEST. Thread B becomes the new GROUP_THREADS entry; thread A moves
     to LEAKED_THREAD_IDS in its place.
  5. Session converges CLEAN at round 2 (zero open claims either round, both rounds' own
     findings were CLEAN).
  6. Phase 3: --cleanup B (GROUP_THREADS, kind current) AND --cleanup A (LEAKED_THREAD_IDS, kind
     leaked) -- both FAKE_CODEX_CLEANUP_OK=1 so both genuinely succeed.

Expected exit_state: CLEAN, round_count: 2. threads: two entries --
{"group":"main","thread_id":B,"kind":"current","cleanup":"deleted"} and
{"group":"main","thread_id":A,"kind":"leaked","cleanup":"deleted"}.
Invocation log: exactly 2 "mode=fresh" lines (round 1's dispatch and round 2's compaction
dispatch -- two DIFFERENT thread_id values, A then B) and ZERO "mode=resume" lines (round 2 is a
FRESH dispatch, never a --resume, which is the whole point this scenario proves).
EOF

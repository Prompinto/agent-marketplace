#!/usr/bin/env bash
# Scenario: compact-baseline-still-over-threshold
# Targets: references/compaction.md's "Benefit-free-restart-loop guard" -- a compaction round's
# OWN freshly-restarted execution.usage.input_tokens is ALSO >= COMPACT_THRESHOLD, so
# compaction_disabled_reason is set to "baseline_at_or_above_threshold" and compaction is
# permanently disabled for the rest of THIS session -- round 3's own high usage must NOT trigger
# a second compaction attempt.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo compact-baseline-still-over-threshold)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-compact-baseline-still-over-threshold-invocation.log"
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
  1. Round 1: fresh --uncommitted, FAKE_CODEX_SCENARIO=normal, one real finding of severity
     "low" so the session does NOT converge CLEAN immediately (keeps the loop running past round
     1), FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}' -- threadId A,
     triggers compaction for round 2.
  2. Round 2 (COMPACTION round): fresh --uncommitted (never --resume), digest carries the one
     open claim from round 1 verbatim. FAKE_CODEX_SCENARIO=normal,
     FAKE_CODEX_USAGE_JSON='{"input_tokens":8500000,"output_tokens":50000}' (this compaction
     round's OWN freshly-restarted usage is ITSELF >= COMPACT_THRESHOLD) -- threadId B, a
     DISPOSITION marker resolving the one open claim (so no claim stays open). Round 2's own
     dispatch SUCCEEDS (ok:true) -- but because COMPACTION_BASELINE_TOKENS (8,500,000) is itself
     >= COMPACT_THRESHOLD (8,000,000), record compaction_disabled_reason=
     "baseline_at_or_above_threshold" on round 2's own JSONL line, alongside the normal success
     fields (compacted_from_thread=A, candidate_snapshot_path, snapshot_digest_before/after,
     compaction_attempt_failure_count=0). Session converges CLEAN at round 2 (the one claim was
     just resolved).
  3. Because this fixture needs to prove compaction stays DISABLED, extend to a THIRD round
     instead of converging at round 2: have round 2 raise a NEW low-severity finding (not
     resolved) so the loop continues to round 3, with FAKE_CODEX_USAGE_JSON on round 2 still
     >=COMPACT_THRESHOLD as above. Round 3: an ordinary --resume dispatch (never a second
     compaction attempt, since compaction_disabled_reason is already latched) --
     FAKE_CODEX_SCENARIO=normal, FAKE_CODEX_USAGE_JSON='{"input_tokens":8700000,
     "output_tokens":40000}' (deliberately ALSO over COMPACT_THRESHOLD, to prove the trigger
     check no-ops immediately once disabled rather than attempting a second compaction) -- a
     DISPOSITION marker resolves round 2's new claim. Session converges CLEAN at round 3, using
     thread B throughout (never touched again after round 2's promotion).
  4. Phase 3: --cleanup B (current) AND --cleanup A (leaked) -- both FAKE_CODEX_CLEANUP_OK=1.

Expected exit_state: CLEAN, round_count: 3. threads: current=B, leaked=A, both cleanup=deleted.
Invocation log: exactly 2 "mode=fresh" lines (round 1, round 2) and exactly 1 "mode=resume" line
(round 3, against B) -- proof round 3 did NOT attempt a second fresh compaction dispatch despite
its own usage also exceeding COMPACT_THRESHOLD. Round 3's own resume thread_id must equal B (the
SAME thread the compaction round promoted), never A and never a third, newly-minted thread --
that is the specific, observable link proving round 3 genuinely continued off the post-compaction
thread rather than merely "some resume happened somewhere."
EOF

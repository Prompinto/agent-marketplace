#!/usr/bin/env bash
# Scenario: compact-clean-repo-dir-polluted
# Targets: references/compaction.md's "Restart mechanism" step 2 -- the eight-check
# CLEAN_REPO_DIR cleanliness recheck that runs before EVERY compaction fresh dispatch for a
# non-repo-artifact session. A stray file is deliberately planted into CLEAN_REPO_DIR (check 1:
# "no entries other than .git") between round 1 completing and round 2's compaction attempt --
# the recheck must detect this and fail CLOSED (fall through to the ordinary --resume fallback
# on the OLD thread), NEVER dispatch a fresh --uncommitted call against the polluted directory.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-compact-clean-repo-dir-polluted-invocation.log"
: > "$INVOCATION_LOG"

ARTIFACT_TEXT_FILE="$(mktemp)"
cat > "$ARTIFACT_TEXT_FILE" <<'ARTIFACT'
# Fixture design note

This is a short, deliberately unremarkable design paragraph used purely as the pasted,
non-repo-artifact review subject for this eval scenario. It has no git diff of its own -- it
exists only in --focus text, which is exactly the shape references/non-repo-artifact.md's
CLEAN_REPO_DIR mechanism exists to isolate.
ARTIFACT

echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "ARTIFACT_TEXT_FILE=$ARTIFACT_TEXT_FILE"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs --compact against the CONTENT of ARTIFACT_TEXT_FILE (a non-repo-artifact
review -- paste its content as the task, prefixed with --compact), with BIN_DIR prepended to
PATH on every Bash call, FAKE_CODEX_INVOCATION_LOG set to INVOCATION_LOG on every dispatch/
cleanup call.

Expected sequence:
  1. Phase 0 step 4 determines this is a non-repo-artifact review, allocates CLEAN_REPO_DIR and
     FAKE_GIT_HOME (per references/non-repo-artifact.md), prints CLEAN_REPO_DIR=<path> -- NOTE
     THIS PATH, it is needed for step 3 below.
  2. Round 1: fresh --uncommitted against CLEAN_REPO_DIR (empty diff, falls back to reviewing
     --focus, which contains the pasted artifact text), FAKE_CODEX_SCENARIO=normal,
     FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}' -- CLEAN verdict,
     threadId OLD captured. Triggers compaction for round 2.
  3. BEFORE round 2's compaction attempt dispatches (i.e. immediately after round 1's own JSONL
     append, before the threshold-triggered restart mechanism ever runs its own step-2
     CLEAN_REPO_DIR recheck): pollute CLEAN_REPO_DIR by planting a stray file --
     `touch "<the printed CLEAN_REPO_DIR path>/stray-file.txt"`. This violates check 1 ("no
     entries other than .git") of the eight-check cleanliness predicate.
  4. Round 2 (compaction ATTEMPT): step 0's ordinary snapshot revalidation passes (unrelated to
     CLEAN_REPO_DIR's own cleanliness). Step 1 builds and verifies COMPACT_DIGEST successfully
     (round 1 had zero open claims). Step 2's non-repo-artifact CLEAN_REPO_DIR cleanliness
     recheck runs BEFORE the fresh dispatch -- check 1 FAILS (a stray file is present). This is
     treated exactly like any other compaction failure: log the narration, fall through to
     step 6's fallback WITHOUT EVER DISPATCHING a fresh call for the compaction candidate. No
     thread is ever created for this failed attempt (nothing was ever captured to abandon), so
     compaction_attempt_failed_thread is correctly ABSENT from round 2's own line.
  5. Round 2's real outcome: an ORDINARY --resume dispatch against the STILL-ALIVE OLD thread
     (never touched by the failed compaction attempt) -- FAKE_CODEX_SCENARIO=normal,
     FAKE_CODEX_USAGE_JSON='{"input_tokens":300000,"output_tokens":20000}'. Session converges
     CLEAN at round 2, still using thread OLD throughout.
  6. Phase 3: --cleanup OLD only (GROUP_THREADS -- no second thread was ever created) --
     FAKE_CODEX_CLEANUP_OK=1. CLEAN_REPO_DIR/FAKE_GIT_HOME are removed as usual (the stray file
     inside CLEAN_REPO_DIR is removed along with it via `rm -rf`).

Expected exit_state: CLEAN, round_count: 2. threads: exactly ONE entry --
{"group":"main","thread_id":OLD,"kind":"current","cleanup":"deleted"} -- no "leaked" entry at
all, since the compaction attempt never created a second thread.
Invocation log: exactly 1 "mode=fresh" line (round 1 only -- the compaction attempt's own fresh
dispatch never happened) and exactly 1 "mode=resume" line (round 2's fallback, against OLD).
EOF

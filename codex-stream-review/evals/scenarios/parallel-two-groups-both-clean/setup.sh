#!/usr/bin/env bash
# Scenario: parallel-two-groups-both-clean
# Targets: the baseline parallel-mode dispatch -- a diff sized to trigger
# references/parallel-mode.md's own scope-sizing table's "Medium (20-50
# files, or multiple concerns) -> 2-3 parallel groups" tier, both groups
# converge CLEAN on round 1.
#
# Fixture sizing judgment call: parallel-mode.md's table gives ranges, not a
# single hard number (<20 single; 20-50 medium/2-3 groups; >50 large/3+
# groups) -- there is no exact byte-for-byte threshold constant in the
# skill or the wrapper to grep for (the sizing decision is Claude's own
# judgment call at Phase 1's "Determine review mode" step, not a hardcoded
# script constant). This fixture uses 24 total changed files (1 tracked
# modification + 23 new untracked files, via
# eval_make_fixture_repo_sized's own default), comfortably inside the
# 20-50 medium band and far from the 50-file large-tier boundary, then the
# driving agent picks 2 groups (the low end of "2-3" for a medium-sized,
# single-concern diff).
#
# Both groups' fake-codex transcripts use FAKE_CODEX_SCENARIO=normal's own
# DEFAULT verdict (CLEAN, findings:[]) -- no FAKE_CODEX_GROUP_STATE
# scripting needed for a one-round, both-clean scenario.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo_sized parallel-two-groups-both-clean 23)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
G1_LOG="$(mktemp -u /tmp/ccs-eval-g1-invocations.XXXXXX)"
G2_LOG="$(mktemp -u /tmp/ccs-eval-g2-invocations.XXXXXX)"

FILE_COUNT="$( (cd "$REPO_DIR" && git diff --name-only HEAD; cd "$REPO_DIR" && git ls-files --others --exclude-standard) | sort -u | wc -l | tr -d ' ')"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "changed file count (tracked + untracked, deduplicated): $FILE_COUNT"
echo "G1_INVOCATION_LOG=$G1_LOG"
echo "G2_INVOCATION_LOG=$G2_LOG"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH on EVERY Bash call this run makes. Task text: "review the
uncommitted change in this fixture repo".

Expected sizing: SKILL.md's Phase 1 "Determine review mode" sizing count
lands in parallel-mode.md's "Medium (20-50 files)" tier -> dispatch 2
parallel groups this round (g1, g2), e.g. g1 focused on correctness, g2 on
security/reuse (the two groups' Round-1 --focus texts differ ONLY in this
dimension sub-bullet, per parallel-mode.md's own "Round-1 focus text"
section -- both review the IDENTICAL full diff).

CRITICAL -- per tests/fixtures/fake-codex's own FAKE_CODEX_GROUP_STATE doc
comment: for a parallel round, EACH group's dispatch line needs its OWN
INLINE env-var prefix (FAKE_CODEX_INVOCATION_LOG bound per-command to that
group's own literal G1_INVOCATION_LOG/G2_INVOCATION_LOG value above), never
a shared `export` mutated between the two concurrent background dispatch
launches. Both groups' dispatches should be issued as separate,
concurrently-backgrounded Bash calls within the same turn (Phase 1 Step 1's
"one Bash run_in_background:true invocation per group" instruction).

Expected: both g1 and g2 return {"ok":true,"verdict":{"verdict":"CLEAN",
"findings":[],...}} on round 1 (fake-codex's own default response, no
GROUP_STATE scripting needed). Convergence: both groups clean, coverage
merged complete (no oversized/omitted files in this fixture), no claims
ever raised. exit_state CLEAN, round_count 1, threads: two entries (one per
group), both kind:current cleanup:deleted -- set FAKE_CODEX_CLEANUP_OK=1 on
both Phase 3 --cleanup calls.
EOF

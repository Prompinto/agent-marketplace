#!/usr/bin/env bash
# Scenario: parallel-coverage-merge
# Targets: references/parallel-mode.md's round-1 N-group coverage merge --
# "complete" only if EVERY dispatched group's own status was "complete",
# else "partial" -- forced for REAL (never fabricated) so one group
# genuinely reports "partial" and the other genuinely reports "complete".
#
# JUDGMENT CALL, disclosed here and in the final report (the task
# explicitly asked for this to be flagged): run-ccs-review.sh has no
# file-filter flag, and every group in a parallel round reviews the
# IDENTICAL full diff/untracked-file state of the SAME REPO_ROOT at
# dispatch time (parallel-mode.md's own "What parallel mode actually is"
# section) -- there is structurally no way for two groups dispatched
# against a genuinely IDENTICAL, simultaneous repo state to observe
# different real coverage.source outcomes; the wrapper's own coverage
# splice is deterministic given the same on-disk state
# (collect_untracked_files.py's own omitted-file accounting). The sibling
# `partial-coverage` scenario (Group A) forces a real "partial" outcome via
# one untracked file over collect_untracked_files.py's own 1MiB
# DEFAULT_MAX_BYTES cap (coverage reason "over_size_limit", confirmed
# directly from that script and from a live run) -- this scenario reuses
# THE SAME real mechanism, but must additionally desynchronize the two
# groups' own observed repo state to get one "partial" and one "complete"
# reading: g1 is dispatched FIRST, while the oversized untracked file is
# still present (real "partial"); once g1's own round-1 attempt has
# returned and its coverage.source is captured, the oversized file is
# deleted, and ONLY THEN is g2 dispatched (real "complete"). This is a
# genuine divergence from parallel-mode.md's own "every group reviews the
# identical diff" description of ordinary parallel-mode USE -- it is
# deliberately non-representative of how a real /ccs parallel round is
# meant to run, constructed here purely to exercise the ORCHESTRATOR's own
# merge-computation logic with two REAL (not synthesized) coverage_source
# values that happen to differ. Sequential, not concurrent, dispatch is
# therefore CORRECT for this one scenario only -- do not use this as a
# template for any other parallel-mode scenario in this suite.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo_sized parallel-coverage-merge 23)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

python3 -c "
with open('$REPO_DIR/oversized-untracked.bin', 'wb') as f:
    f.write(b'x' * (1024 * 1024 + 4096))
"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "oversized untracked file: $REPO_DIR/oversized-untracked.bin ($(wc -c < "$REPO_DIR/oversized-untracked.bin") bytes, cap is 1048576)"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH on EVERY Bash call. Task text: "review the uncommitted
change in this fixture repo". Dispatch 2 parallel groups (g1, g2), per the
sizing judgment already established by parallel-two-groups-both-clean --
but see this file's own header comment: dispatch them SEQUENTIALLY, not
concurrently, for this one scenario only.

Expected sequence:
  1. Dispatch g1 first (--uncommitted, FAKE_CODEX_SCENARIO=normal), with
     REPO_DIR/oversized-untracked.bin still present. g1 returns
     {"ok":true,"verdict":{"verdict":"CLEAN","findings":[],...},"coverage":
     {"source":{"reviewed_file_count":<n>,"omitted":[{"path":
     "oversized-untracked.bin","reason":"over_size_limit"}],
     "status":"partial"}}}. Capture g1's own round-1 coverage_source now.
  2. Once g1's dispatch has returned, delete
     REPO_DIR/oversized-untracked.bin.
  3. Dispatch g2 (--uncommitted, FAKE_CODEX_SCENARIO=normal) only now, with
     the oversized file already gone. g2 returns
     {"ok":true,"verdict":{"verdict":"CLEAN","findings":[],...},"coverage":
     {"source":{"reviewed_file_count":<n>,"omitted":[],
     "status":"complete"}}}. Capture g2's own round-1 coverage_source.
  4. Round-1 N-group merge (parallel-mode.md): "complete" only if EVERY
     dispatched group's own status was "complete" -- g1's was "partial", so
     the merged coverage_source.status is "partial", with omitted set to
     g1's own omitted list.
  5. Per SKILL.md's Guards ("Partial or unknown source coverage != CLEAN"),
     even though both groups' own verdicts were individually CLEAN with no
     findings, this round is NOT eligible for CLEAN: stop and report
     exit_state PARTIAL_COVERAGE.

Set FAKE_CODEX_CLEANUP_OK=1 on both Phase 3 --cleanup calls.

Expected result: exit_state PARTIAL_COVERAGE, round_count 1, threads: two
entries (one per group), both kind:current cleanup:deleted, claims: [],
coverage: {"status":"partial","omitted":[{"path":"oversized-untracked.bin",
"reason":"over_size_limit"}], ...} (worst-case-wins merge).
EOF

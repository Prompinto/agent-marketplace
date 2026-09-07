#!/usr/bin/env bash
# Scenario: partial-coverage
# Targets: exit_state = PARTIAL_COVERAGE (terminal-status matrix).
# Uses eval_make_fixture_repo's normal tiny tracked-file diff PLUS one extra
# untracked file deliberately sized over collect_untracked_files.py's own
# DEFAULT_MAX_BYTES (1024*1024 = 1MiB) -- confirmed directly from that
# script (and live, via an actual run): a file over this cap is omitted from
# the collected untracked-file content with coverage reason code
# "over_size_limit" (the short code recorded in the coverage JSON's own
# "omitted[].reason" field -- distinct from the longer human-readable
# "(over 1MB cap or unreadable; contents omitted)" marker text
# format_entry() inlines into the rendered diff-like output itself, around
# line 311). This makes
# run-ccs-review.sh's own real coverage-splicing logic (never
# self-reported/simulated -- see run-ccs-review.sh's own comment: "status
# (partial/complete) is derived here from $SOURCE_COVERAGE_JSON.omitted, not
# self-reported by the collector") report coverage.source.status:"partial"
# for real on round 1's own --uncommitted dispatch.
# Uses the fake-codex fixture (FAKE_CODEX_SCENARIO=normal) -- like
# clean-basic, this is about whether the ORCHESTRATOR correctly reports
# PARTIAL COVERAGE (never CLEAN) when real coverage is incomplete, not about
# Codex's own review judgment.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo partial-coverage)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

# One untracked file, deliberately over the 1MiB collector cap -- this file
# is never added to git, so it shows up via `git ls-files --others
# --exclude-standard`, exactly the untracked-file path the collector walks.
python3 -c "
with open('$REPO_DIR/oversized-untracked.bin', 'wb') as f:
    f.write(b'x' * (1024 * 1024 + 4096))
"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "FAKE_CODEX_SCENARIO=normal"
echo "oversized untracked file size: $(wc -c < "$REPO_DIR/oversized-untracked.bin") bytes (cap is 1048576)"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call the skill makes during this run (see
codex-stream-review/evals/README.md's "Mechanical caveat"). Task text to
give the skill: "review the uncommitted change in this fixture repo".

Expected: round 1's own --uncommitted dispatch reports
coverage.source == {"reviewed_file_count":1,"omitted":[{"path":"oversized-untracked.bin","reason":"over_size_limit"}],"status":"partial"}
(derived for real by run-ccs-review.sh from collect_untracked_files.py's own
output, not simulated). Codex's verdict itself is CLEAN (fake-codex's
default) with no findings, and Claude has no open items either, but per
SKILL.md's Guards -- "Partial or unknown source coverage != CLEAN, and is
not the same failure as NOT CONVERGED/COULD NOT VERIFY" -- this round is NOT
eligible for CLEAN: stop and report exit_state PARTIAL_COVERAGE, round_count
1, one thread kind:current cleanup:deleted (set FAKE_CODEX_CLEANUP_OK=1 on
the Phase 3 --cleanup call), claims:[] (no findings were ever raised).
EOF

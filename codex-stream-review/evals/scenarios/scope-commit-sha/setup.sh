#!/usr/bin/env bash
# Scenario: scope-commit-sha
# Targets: a --commit <sha> dispatch against a real commit in a fixture
# repo. Same coverage-null assertion as scope-base-ref, target.scope ==
# "commit" instead.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-scope-commit-sha.XXXXXX")"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "eval@example.com"
git -C "$REPO_DIR" config user.name "ccs-eval"
printf 'def add(a, b):\n    return a + b\n' > "$REPO_DIR/lib.py"
git -C "$REPO_DIR" add lib.py
git -C "$REPO_DIR" commit -q -m "initial"
printf 'def add(a, b):\n    # deliberate off-by-one for eval fixtures\n    return a + b + 1\n' > "$REPO_DIR/lib.py"
git -C "$REPO_DIR" add lib.py
git -C "$REPO_DIR" commit -q -m "introduce off-by-one"
COMMIT_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"

BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

INVOCATION_LOG="/tmp/ccs-eval-scope-commit-sha-invocations.log"
rm -f "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "COMMIT_SHA=$COMMIT_SHA (a single-parent, non-merge commit)"
echo "FAKE_CODEX_SCENARIO=normal"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call, FAKE_CODEX_INVOCATION_LOG=<INVOCATION_LOG printed above> set
on every dispatch/cleanup call, FAKE_CODEX_CLEANUP_OK=1 on the --cleanup
call.

Task text to give the skill: "review commit <COMMIT_SHA> in this fixture
repo". Dispatch round 1 with `--commit "<COMMIT_SHA>"` in place of
--uncommitted -- this commit has exactly one parent, so
scripts/run-ccs-review.sh's own collection is `git show <sha>` (the
non-merge branch of its merge-vs-non-merge split, per SKILL.md's "Determine
review mode" section), not a two-ref diff.

Expected: exit_state CLEAN, round_count 1, one thread (kind:current,
cleanup:deleted), target.scope == "commit", coverage == null (same rule as
scope-base-ref: --base/--commit scope never populates coverage).
INVOCATION_LOG: exactly 2 lines, "mode=fresh ..." then "mode=delete ...".
EOF

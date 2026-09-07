#!/usr/bin/env bash
# Scenario: scope-base-ref
# Targets: a --base <ref> dispatch. Needs a fixture repo with at least 2
# real commits so there is a real ref to diff against -- unlike
# eval_make_fixture_repo (whose one change is deliberately left uncommitted,
# for --uncommitted scenarios), this repo commits both revisions and leaves
# nothing uncommitted at all.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-scope-base-ref.XXXXXX")"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "eval@example.com"
git -C "$REPO_DIR" config user.name "ccs-eval"
printf 'def add(a, b):\n    return a + b\n' > "$REPO_DIR/lib.py"
git -C "$REPO_DIR" add lib.py
git -C "$REPO_DIR" commit -q -m "initial"
git -C "$REPO_DIR" branch base-ref
printf 'def add(a, b):\n    # deliberate off-by-one for eval fixtures\n    return a + b + 1\n' > "$REPO_DIR/lib.py"
git -C "$REPO_DIR" add lib.py
git -C "$REPO_DIR" commit -q -m "introduce off-by-one"

BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

INVOCATION_LOG="/tmp/ccs-eval-scope-base-ref-invocations.log"
rm -f "$INVOCATION_LOG"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "base ref: base-ref (points at the 'initial' commit; HEAD is one commit ahead)"
echo "FAKE_CODEX_SCENARIO=normal"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR, with BIN_DIR prepended to PATH on
EVERY Bash call, FAKE_CODEX_INVOCATION_LOG=<INVOCATION_LOG printed above> set
on every dispatch/cleanup call, FAKE_CODEX_CLEANUP_OK=1 on the --cleanup
call.

Task text to give the skill: "review the diff from the base-ref branch to
HEAD in this fixture repo". Since this is explicitly a named-ref diff, not a
review of the current working tree, dispatch round 1 with
`--base "base-ref"` in place of `--uncommitted` (mirroring
scripts/run-ccs-review.sh's own three-dot `base-ref...HEAD` collection, per
SKILL.md's "Determine review mode" section) -- REPO_DIR itself has NO
uncommitted changes at all, so a plain --uncommitted dispatch here would
produce an empty diff and defeat the point of this scenario.

Expected: exit_state CLEAN, round_count 1, one thread (kind:current,
cleanup:deleted), target.scope == "base", coverage == null (per the schema's
own rule: --base/--commit scope never populates coverage). INVOCATION_LOG:
exactly 2 lines, "mode=fresh ..." then "mode=delete ...".
EOF

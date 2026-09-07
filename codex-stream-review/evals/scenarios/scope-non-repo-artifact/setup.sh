#!/usr/bin/env bash
# Scenario: scope-non-repo-artifact
# Targets: the CLEAN_REPO_DIR path (references/non-repo-artifact.md) --
# review pasted analysis/plan text, not a real diff. Confirms
# target.scope == "uncommitted" (a non-repo-artifact round always dispatches
# --uncommitted against the empty CLEAN_REPO_DIR, never --base/--commit,
# per SKILL.md's Phase 0 step 4 + non-repo-artifact.md) and
# coverage.status == "complete" with reviewed_file_count == 0 (per SKILL.md's
# "Coverage is a Round-1-only property" section's own documented reasoning
# for why a zero-file CLEAN_REPO_DIR round reports complete, not unknown).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

ARTIFACT_FILE="$(mktemp "/tmp/ccs-eval-scope-non-repo-artifact.XXXXXX")"
cat > "$ARTIFACT_FILE" <<'ARTIFACT'
Plan: add a --retry-delay-secs flag to run-ccs-review.sh that lets callers
override the bounded resume-retry backoff (currently hardcoded to 5s then
15s in references/retry-guards.md) via a comma-separated pair of integers,
e.g. --retry-delay-secs 5,15. Default stays 5,15 when the flag is omitted,
so no existing caller's behavior changes. Validate both values are positive
integers; reject with bad_args otherwise.
ARTIFACT

BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

INVOCATION_LOG="/tmp/ccs-eval-scope-non-repo-artifact-invocations.log"
rm -f "$INVOCATION_LOG"

echo "ARTIFACT_FILE=$ARTIFACT_FILE"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "FAKE_CODEX_SCENARIO=normal"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs with the task text: "review this plan for
correctness and completeness:" followed by the exact contents of
ARTIFACT_FILE (read and paste it verbatim -- there is no repo diff behind
this text at all, it is pasted analysis/plan content).

Per SKILL.md's Phase 0 step 4, this has real content to review but is not a
repo diff -- a genuine non-repo-artifact review. Read
skills/ccs/references/non-repo-artifact.md in full (if not already read this
session) and follow its CLEAN_REPO_DIR/FAKE_GIT_HOME mechanism exactly:
create a throwaway git-init'd (zero-commit) CLEAN_REPO_DIR and a separate
FAKE_GIT_HOME, then dispatch round 1 with
`--cwd "<CLEAN_REPO_DIR>" --uncommitted` (never $REPO_ROOT, never --base/
--commit) -- with BIN_DIR prepended to PATH on EVERY Bash call,
FAKE_CODEX_INVOCATION_LOG=<INVOCATION_LOG printed above> set on every
dispatch/cleanup call, FAKE_CODEX_CLEANUP_OK=1 on the --cleanup call. This
round is always single-group "main", never parallel (see
non-repo-artifact.md's own note: there is nothing to size/partition against
a zero-file CLEAN_REPO_DIR).

Expected: exit_state CLEAN, round_count 1, one thread (kind:current,
cleanup:deleted), target.scope == "uncommitted" (never "base"/"commit" --
CLEAN_REPO_DIR has no commits to diff against), coverage.status ==
"complete" with coverage.reviewed_file_count == 0 (the wrapper's own
untracked-file collector still runs against a zero-file repo and reports an
empty omitted list, which yields status:"complete" regardless of the
zero file count -- see SKILL.md's "A round-1 CLEAN_REPO_DIR round needs no
special-casing here" note). INVOCATION_LOG: exactly 2 lines, "mode=fresh
..." then "mode=delete ...". Clean up CLEAN_REPO_DIR/FAKE_GIT_HOME (rm -rf)
at Phase 3 alongside the usual session temp files, and rm -f ARTIFACT_FILE
once its content has been pasted into the task text (this eval script's own
throwaway file, not part of the skill's own state).
EOF

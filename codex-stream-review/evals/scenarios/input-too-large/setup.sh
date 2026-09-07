#!/usr/bin/env bash
# Scenario: input-too-large
# Targets: exit_state = INPUT_TOO_LARGE (terminal-status matrix).
# Builds its own fixture repo (NOT eval_make_fixture_repo, whose diff is
# deliberately tiny) with a large TRACKED-file modification, so `git diff`
# itself reports a real, oversized diff -- comfortably past
# run-ccs-review.sh's own PROMPT_SIZE_LIMIT_BYTES (131072 bytes) -- while the
# focus/briefing text piped on stdin stays short and ordinary.
#
# IMPORTANT -- an oversized FOCUS text, not an oversized diff, was the
# original design here (matching the plan's own "--focus/pasted task text"
# phrasing) but was abandoned after live testing found a genuine,
# independent performance bug in run-ccs-review.sh: `_focus_is_empty()`
# (around line 139) strips whitespace from the ENTIRE focus text via a bash
# `${var//[[:space:]]/}` global substitution, which is catastrophically
# superlinear for large inputs -- confirmed directly: stripping a ~5.6KB
# string took ~11s, a ~22.5KB string took ~590s. A focus text anywhere near
# the 131072-byte limit would make the wrapper hang for a wildly impractical
# time on this ONE early check, long before ever reaching the size-limit
# check this scenario is actually trying to exercise. This is a real
# production bug worth its own fix/report -- out of scope for this eval
# harness to patch, but the reason this scenario now inflates the DIFF
# instead: `_focus_is_empty()` only ever touches $FOCUS_RECEIVED_FILE (the
# stdin focus text), never the diff, so a large diff reaches the same
# PROMPT_SIZE_LIMIT_BYTES check without ever passing through the slow path.
#
# Confirmed by reading scripts/run-ccs-review.sh directly: the size check
# (PROMPT_SIZE_BYTES -gt PROMPT_SIZE_LIMIT_BYTES, around line 830) fires
# strictly BEFORE `codex exec`/`codex exec resume` is ever invoked (those
# calls are ~100 lines further down, at lines 934/937). The only other place
# the wrapper ever shells out to a `codex` binary at all is `codex delete
# --force` in --cleanup mode (line 325), and a fresh round-1
# artifact_too_large failure never even obtains a threadId (see SKILL.md's
# reason table: "Fresh round 1: No"), so Phase 3 never has anything to
# --cleanup here either. Net result: this scenario's dispatch AND its
# terminal path never invoke the `codex` binary at all, for real or fake --
# the fake-codex PATH injection every other scenario in this harness needs
# is NOT required here. Confirm this stays true if run-ccs-review.sh's
# preflight ordering (or `_focus_is_empty()`'s own implementation) ever
# changes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-input-too-large.XXXXXX")"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "eval@example.com"
git -C "$REPO_DIR" config user.name "ccs-eval"
printf 'def add(a, b):\n    return a + b\n' > "$REPO_DIR/lib.py"
git -C "$REPO_DIR" add lib.py
git -C "$REPO_DIR" commit -q -m "initial"
# Append ~150000 bytes of new tracked-file content as an UNCOMMITTED change
# -- git diff renders each added line with a leading "+ ", so the rendered
# diff comfortably exceeds PROMPT_SIZE_LIMIT_BYTES (131072) on its own, with
# no need for any oversized focus text.
python3 -c "
with open('$REPO_DIR/lib.py', 'a') as f:
    for i in range(4000):
        f.write(f'# padding line {i} exists only to make this diff exceed the wrapper size limit\n')
"

echo "REPO_DIR=$REPO_DIR"
echo "diff size: $(git -C "$REPO_DIR" diff --no-ext-diff --no-textconv HEAD | wc -c) bytes"
cat <<'EOF'

Next step (run by hand or have a Claude Code agent do it): invoke
codex-stream-review:ccs against REPO_DIR. No fake-codex/PATH injection is
needed for this scenario (see this script's own header comment for why --
the real `codex` CLI on PATH is never invoked either way).

Task text to give the skill: "review the uncommitted change in this fixture
repo". Write this round's FOCUS_FILE as an ORDINARY, short Why/Scope focus
text (see clean-basic's own README for the template) -- do NOT inflate the
focus text itself; the oversized input here is REPO_DIR's own diff, already
comfortably past 131072 bytes on disk.

Expected: the dispatch call itself returns
{"ok":false,"reason":"artifact_too_large",...} with no threadId (fresh round
1) -- SKILL.md's Guards section says this is never retried, the round-level
status is immediately INPUT_TOO_LARGE, and there is nothing to --cleanup
(GROUP_THREADS stays empty). exit_state INPUT_TOO_LARGE, input_errors a
non-empty array with one entry (group "main", actual_bytes read out of the
failure response's own detail text, limit_bytes 131072), threads: [] (no
thread was ever obtained, so none can be "leaked" either), claims: [].
EOF

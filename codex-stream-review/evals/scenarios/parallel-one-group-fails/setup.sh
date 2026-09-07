#!/usr/bin/env bash
# Scenario: parallel-one-group-fails
# Targets: worst-case-wins across groups -- g1's every dispatch attempt
# fails (FAKE_CODEX_SCENARIO=exit_nonzero, genuinely exhausting
# references/retry-guards.md's full bounded-retry sequence, mirroring
# could-not-verify-exhausted but scoped to ONE group of a parallel round)
# while g2 converges CLEAN immediately -- the round-level (and here,
# session-level, since retry-guards.md's own "Whenever a group ends in
# COULD NOT VERIFY, the round-level status is COULD NOT VERIFY, regardless
# of how clean every other group's own findings turned out to be" fires
# immediately) exit_state must be COULD_NOT_VERIFY, never CLEAN, even
# though g2 individually did everything right.
#
# Same 24-file fixture as parallel-two-groups-both-clean, for consistency
# across Group E.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo_sized parallel-one-group-fails 23)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
G1_LOG="$(mktemp -u /tmp/ccs-eval-g1-invocations.XXXXXX)"
G2_LOG="$(mktemp -u /tmp/ccs-eval-g2-invocations.XXXXXX)"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "G1_INVOCATION_LOG=$G1_LOG"
echo "G2_INVOCATION_LOG=$G2_LOG"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH on EVERY Bash call. Task text: "review the uncommitted
change in this fixture repo". Dispatch 2 parallel groups (g1, g2) per the
sizing judgment already established by parallel-two-groups-both-clean.

g1's EVERY dispatch attempt this run (fresh round 1, both bounded
--resume retries, the round-1 fresh-fallback retry) must set
FAKE_CODEX_SCENARIO=exit_nonzero (inline, on that command only -- see
tests/fixtures/fake-codex's own FAKE_CODEX_GROUP_STATE doc comment on why
concurrent groups must never share a mutated `export`). g2's dispatch uses
the default FAKE_CODEX_SCENARIO=normal (CLEAN immediately).

Expected sequence (mirrors could-not-verify-exhausted, scoped to g1 only,
concurrently with g2's own immediate success):
  1. Round 1, both groups dispatched concurrently. g2 returns
     {"ok":true,"verdict":{"verdict":"CLEAN","findings":[],...}} immediately
     (threadId C). g1's fresh dispatch still emits thread.started before
     exit_nonzero fires, so a real threadId (A) IS captured; the response
     also carries a real coverage.source (collection completed before the
     fake binary's own exit) -- capture g1's round-1 coverage_source from
     THIS failing attempt now, per retry-guards.md's own capture-before-
     retrying note.
  2. Per retry-guards.md: since ANY dispatched group returned ok:false, the
     round overall is not eligible for CLEAN -- retry JUST g1, g2's real
     CLEAN result is kept, not re-dispatched.
  3. Wait 5s, --resume A --timeout 300 (FAKE_CODEX_SCENARIO=exit_nonzero) --
     fails the same way.
  4. Wait 15s, --resume A --timeout 300 (same) -- fails the same way. Both
     bounded resume-retries now exhausted.
  5. This was round 1, so: fall back to ONE fresh retry of g1's original
     --uncommitted scope, abandoning thread A -- append (g1, A) to
     LEAKED_THREAD_IDS. This fresh dispatch obtains a NEW real threadId
     (B), and also fails (still exit_nonzero).
  6. That fresh retry failing too means: stop -- report COULD NOT VERIFY
     for group g1. Per retry-guards.md, the round-level (here,
     session-level) status is COULD NOT VERIFY regardless of g2's own
     clean result.

Phase 3 terminal path still runs cleanup unconditionally for every group's
every known thread. Set FAKE_CODEX_CLEANUP_OK=1 on all three --cleanup
calls (g1's B via GROUP_THREADS, g1's A via LEAKED_THREAD_IDS, g2's C via
GROUP_THREADS).

Expected result: exit_state COULD_NOT_VERIFY, round_count 1, claims: []
(g1 never completed a real review; g2's CLEAN had none), threads: three
entries -- {group:"g1",thread_id:B,kind:"current",cleanup:"deleted"},
{group:"g1",thread_id:A,kind:"leaked",cleanup:"deleted"},
{group:"g2",thread_id:C,kind:"current",cleanup:"deleted"}.
EOF

#!/usr/bin/env bash
# Scenario: review-log-integrity-failure-stale-schema
# Targets: exit_state = REVIEW_LOG_INTEGRITY_FAILURE, via the OTHER trigger
# from review-log-integrity-failure-corrupt-append: a --resume-shaped
# continuation of a pre-existing session whose JSONL log's FIRST line has a
# missing or older schema_version than this skill's current version
# (references/claim-ledger.md section 10's legacy-session policy; SKILL.md's
# "Review history log" -> "Read (continuity)": "if it's missing or older
# than this skill's current version ... this is a hard stop").
#
# Unlike every other scenario in this harness, this one does NOT drive a
# live round 1 through fake-codex at all -- it hand-constructs a legacy
# session's JSONL log directly, under the real path convention, simulating
# a session that began before this skill's schema-versioning feature
# shipped (or under an older schema_version integer). The check this
# scenario targets (SKILL.md's "Read (continuity)") fires BEFORE round 2
# ever dispatches, so a real round 1 dispatch was never going to be
# exercised by this trigger anyway -- constructing the "prior round"
# directly, by hand, is the direct way to exercise this exact check.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-legacy-resume.XXXXXX")"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "eval@example.com"
git -C "$REPO_DIR" config user.name "ccs-eval"
printf 'def add(a, b):\n    return a + b\n' > "$REPO_DIR/lib.py"
git -C "$REPO_DIR" add lib.py
git -C "$REPO_DIR" commit -q -m "initial"
printf 'def add(a, b):\n    return a + b  # still under review\n' > "$REPO_DIR/lib.py"

BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="$(mktemp "/tmp/ccs-eval-legacy-resume-invocations.XXXXXX")"

REPO_SLUG="$(basename "$REPO_DIR" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g')"
LEGACY_SESSION_ID="2026-01-01T000000-11111"
LEGACY_THREAD_ID="legacy-thread-0001"
LOG_DIR=~/.claude/plugins/data/codex-stream-review/ccs-logs/"$REPO_SLUG"
LOG_PATH="$LOG_DIR/$LEGACY_SESSION_ID.jsonl"

umask 077
mkdir -p "$LOG_DIR"
# Hand-built round-1 line for a session that predates (or predates the
# current version of) schema_version -- NO "schema_version" key at all on
# this first line, simulating exactly the legacy-session case
# claim-ledger.md section 10 documents. A real, still-open finding is
# included so "resuming to continue the review" is a coherent thing for a
# caller to actually want to do.
jq -nc --arg repo "$REPO_DIR" --arg tid "$LEGACY_THREAD_ID" '
  {
    session_id: "'"$LEGACY_SESSION_ID"'",
    round: 1,
    ts: "2026-01-01T00:01:00+09:00",
    thread_id: $tid,
    target: {repo: $repo, scope: "uncommitted", focus: "review the uncommitted change in this fixture repo"},
    codex_review: {ok: true, verdict: "ISSUES", findings: [
      {id: "f1", file: "lib.py", line: 2, severity: "low", summary: "trailing comment should be removed before merge", evidence: "e", linked_finding_id: null}
    ]},
    coverage_source: {status: "complete"},
    claude_verification: [
      {finding_id: "f1", claim_id: "f1", action: "accept", rationale: "agreed, will clean up the comment"}
    ],
    round_outcome: "continue"
  }' > "$LOG_PATH"
chmod 600 "$LOG_PATH"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG"
echo "REPO_SLUG=$REPO_SLUG"
echo "LEGACY_SESSION_ID=$LEGACY_SESSION_ID"
echo "LEGACY_THREAD_ID=$LEGACY_THREAD_ID"
echo "LOG_PATH=$LOG_PATH"
echo "log's first line has NO schema_version key -- $(jq -c 'has("schema_version")' "$LOG_PATH")"
cat <<EOF

Next step: invoke codex-stream-review:ccs with a task that explicitly asks
to CONTINUE/RESUME the existing session $LEGACY_SESSION_ID for REPO_DIR --
e.g. "resume the previous codex-stream-review:ccs session $LEGACY_SESSION_ID
for the fixture repo at REPO_DIR and continue the review (round 2); the
prior round already found one open issue in lib.py". No BIN_DIR/PATH
injection is needed for the review-dispatch path at all here -- per
SKILL.md's "Read (continuity)" section, this check runs at the very start of
round R>1, before any --resume dispatch. Confirm ZERO dispatch invocations
are ever logged to FAKE_CODEX_INVOCATION_LOG for this run.

The driving agent must genuinely read \$LOG_PATH's first line and its
schema_version field (per references/claim-ledger.md section 10 and
SKILL.md's "Read (continuity)" section, both already required reading) --
finding it absent, this is a hard stop: report 🛑 REVIEW LOG INTEGRITY
FAILURE, never attempt to reduce a mixed old/new-format claim ledger.
Rehydrate GROUP_THREADS.main from the log's own thread_id field
($LEGACY_THREAD_ID) and run Phase 3's unconditional cleanup on it -- set
FAKE_CODEX_CLEANUP_OK=1 and BIN_DIR on PATH for that ONE --cleanup call only
(this is the only codex invocation this whole scenario should ever make: one
mode=delete line in FAKE_CODEX_INVOCATION_LOG, zero mode=fresh/resume
lines).

Expected: exit_state REVIEW_LOG_INTEGRITY_FAILURE, claims null, round_count
1 (this session's own log already shows a real completed round 1, from
before this run -- distinct from review-log-integrity-failure-corrupt-append's
round_count 0, which never durably logged anything at all), threads: one
entry {group:"main", thread_id:"$LEGACY_THREAD_ID", kind:"current",
cleanup:"deleted"}.
EOF

# Scenario: review-log-integrity-failure-stale-schema

**Group:** A (terminal-status matrix)
**Targets:** `exit_state == "REVIEW_LOG_INTEGRITY_FAILURE"`, via the legacy-session
`schema_version` trigger (`references/claim-ledger.md` section 10; `SKILL.md`'s "Review history
log" -> "Read (continuity)": a missing or older `schema_version` on a resumed session's first line
is a hard stop).

Sibling to `review-log-integrity-failure-corrupt-append` -- same `exit_state`, a genuinely different
trigger, distinguished in the produced `.result.json` by `round_count` (`1` here, since this
session's own log already had a real completed round before this run started; `0` there, since
that scenario's own round 1 never durably logged anything at all).

## No live round 1 through fake-codex

`SKILL.md` has no literal caller-facing "resume an old session" CLI flag -- `/ccs` always mints a
fresh `SESSION_ID` at Phase 0 step 1. What `references/claim-ledger.md` section 10 documents is a
POLICY for the case where a caller's task text explicitly asks to continue a specific prior
session's review. `setup.sh` hand-constructs that prior session's own JSONL log directly, under the
real path convention (`~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/
<session-id>.jsonl`), with a real, still-open finding on its first line and NO `schema_version`
key at all -- simulating a session that predates this skill's schema-versioning feature. This is
the direct way to exercise `SKILL.md`'s "Read (continuity)" check itself, which is what this
scenario targets -- that check fires before any dispatch happens either way, so a live round 1
was never going to touch it.

## How to run

```bash
bash codex-stream-review/evals/scenarios/review-log-integrity-failure-stale-schema/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `FAKE_CODEX_INVOCATION_LOG`, `REPO_SLUG`, `LEGACY_SESSION_ID`,
`LEGACY_THREAD_ID`, and `LOG_PATH` (the hand-built legacy log, confirmed missing
`schema_version`). Invoke `codex-stream-review:ccs` with a task explicitly asking to continue that
specific existing session for `REPO_DIR`, e.g.:

> resume the previous codex-stream-review:ccs session `<LEGACY_SESSION_ID>` for the fixture repo at
> `REPO_DIR` and continue the review (round 2); the prior round already found one open issue in
> lib.py

The driving agent reads `LOG_PATH`'s first line, finds no `schema_version`, and hard-stops per
`references/claim-ledger.md` section 10 -- no round 2 dispatch is ever attempted. Rehydrate
`GROUP_THREADS.main` from the log's own `thread_id` field and run Phase 3's unconditional cleanup
on it (the only codex invocation this scenario ever makes -- one `mode=delete` line, set
`FAKE_CODEX_CLEANUP_OK=1` and `BIN_DIR` on `PATH` for that one call).

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> review-log-integrity-failure-stale-schema
```

## Expected result

- `exit_state`: `"REVIEW_LOG_INTEGRITY_FAILURE"`
- `claims`: `null`
- `round_count`: `1` (the prior session's own log already shows a real completed round 1)
- `threads`: one entry, `thread_id:"<LEGACY_THREAD_ID>"`, `kind:"current"`, `cleanup:"deleted"`
- `input_errors`: `null`
- `FAKE_CODEX_INVOCATION_LOG`: exactly 1 line (`mode=delete`) -- zero dispatch invocations, real or
  fake, confirming the hard stop fired before round 2 ever reached a dispatch

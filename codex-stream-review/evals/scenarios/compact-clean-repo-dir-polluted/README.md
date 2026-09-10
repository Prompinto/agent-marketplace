# Scenario: compact-clean-repo-dir-polluted

**Group:** F (`compaction.md` opt-in-feature coverage) — the one scenario in this suite covering
`references/compaction.md`'s "Restart mechanism" step 2 `CLEAN_REPO_DIR` cleanliness recheck,
for a genuine non-repo-artifact session.

**Targets:** the eight-check `CLEAN_REPO_DIR` cleanliness predicate's check 1 ("no entries other
than `.git`"), and the "Fail CLOSED wherever a real alternative still exists" rule — a detected
pollution must fall through to the ordinary `--resume` fallback on the STILL-ALIVE old thread,
never dispatch a fresh call against a known-polluted directory, and never create a second thread
for an attempt that was never actually dispatched.

## Mechanical setup

This is the one scenario in this suite requiring MANUAL intervention mid-session (unlike Tasks
23-26, which fully script every dispatch's own env vars in advance): whoever drives this
scenario must note the `CLEAN_REPO_DIR=<path>` line `/ccs`'s own Phase 0 prints, then, after
round 1 completes but before round 2's compaction attempt runs, `touch` a stray file inside that
exact directory. Round 1: `FAKE_CODEX_SCENARIO=normal`, `FAKE_CODEX_USAGE_JSON` over threshold.
Round 2's real (fallback) dispatch: `FAKE_CODEX_SCENARIO=normal`,
`FAKE_CODEX_USAGE_JSON` under threshold. `--cleanup` needs `FAKE_CODEX_CLEANUP_OK=1`.
`FAKE_CODEX_INVOCATION_LOG` set on every call.

## How to run

```bash
bash codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/setup.sh
```

Then invoke `codex-stream-review:ccs --compact` with the CONTENT of `ARTIFACT_TEXT_FILE` as the
task text (a non-repo-artifact review — no `REPO_DIR` fixture for this scenario, unlike Tasks
23-26).

```bash
bash codex-stream-review/evals/check-result.sh <result.json> compact-clean-repo-dir-polluted
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `2`
- `threads`: exactly ONE entry, `kind: "current"`, `cleanup: "deleted"` — no `"leaked"` entry.
- Invocation log: exactly 1 `mode=fresh` line (round 1 only), exactly 1 `mode=resume` line
  (round 2's fallback) — proving the compaction attempt's own fresh dispatch never happened.
- The session's own `.jsonl` log: round 2's own line carries a narration note about the failed
  `CLEAN_REPO_DIR` recheck and correctly has NO `compaction_attempt_failed_thread` field at all
  (manual check — not mechanically asserted by `expect.sh`).

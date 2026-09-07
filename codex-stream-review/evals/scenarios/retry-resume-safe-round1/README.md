# Scenario: retry-resume-safe-round1

**Group:** B (`retry-guards.md` retry-decision-tree coverage)
**Targets:** `references/retry-guards.md`'s "A `threadId` WAS captured, and the reason is
resume-safe" branch, specifically its "Round 1 only -- capture coverage from the failing attempt
BEFORE retrying" note. Round 1's fresh dispatch fails with a resume-safe reason (`nonzero_exit`)
AFTER a thread already started (so a real `threadId` IS captured despite the failure). Confirms
`coverage.source` is captured from THAT failed attempt before the bounded `--resume` retry runs --
since a `--resume` call never reports `coverage.source` itself, this failed round-1 response is the
ONLY place this session's real coverage data can come from once the eventual successful response is
a `--resume`, not a fresh dispatch.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_SCENARIO=exit_nonzero`
must be set explicitly on the round-1 fresh dispatch call; `FAKE_CODEX_SCENARIO=normal` (or unset,
its own default) on the `--resume` retry. `FAKE_CODEX_INVOCATION_LOG` must be set to the fixed path
`setup.sh` prints (`/tmp/ccs-eval-retry-resume-safe-round1-invocation.log`) on every call.

This invocation-count check is best-effort: if the invocation log has already been cleaned up by
the time `expect.sh` runs later (it is an ephemeral `/tmp` diagnostic file, not a durable artifact
like the `.jsonl` log or `.result.json`), that one check is skipped with a WARN instead of failing
the whole scenario -- the schema and field-based assertions remain the authoritative,
always-checkable ones.

## How to run

```bash
bash codex-stream-review/evals/scenarios/retry-resume-safe-round1/setup.sh
```

Then invoke `codex-stream-review:ccs` against `REPO_DIR` with the task text:

> review the uncommitted change in this fixture repo

Sequence:

1. **Fresh round-1 dispatch** (`--uncommitted`), `FAKE_CODEX_SCENARIO=exit_nonzero` --
   `fake-codex` still emits `thread.started` before failing, so a real `threadId` (`A`) IS captured.
   `nonzero_exit` is resume-safe. This response ALSO carries a spliced-in `coverage.source` object
   (one of the 7 reasons that unconditionally carry it on a fresh `--uncommitted` dispatch that got
   far enough to collect the diff) -- **capture this value now**, before dispatching the retry.
2. **Wait 5s**, `--resume A --timeout 300`, `FAKE_CODEX_SCENARIO=normal` -- succeeds on this first
   bounded resume retry, CLEAN verdict. This `--resume` response never carries `coverage.source`
   itself.
3. Round 1 converges `✅ CLEAN`, using the successful `--resume` response's verdict, but the
   `coverage_source` **captured from step 1's failed attempt** -- never re-derived, never left as
   the `{"status":"unknown"}` sentinel.
4. Phase 3: `--cleanup A`, `FAKE_CODEX_CLEANUP_OK=1`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> retry-resume-safe-round1
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `1`
- `threads`: exactly one entry, `{"group":"main","thread_id":A,"kind":"current","cleanup":"deleted"}`
  -- no `"leaked"` entry (the bounded resume retry succeeded on its first attempt, so thread `A` was
  never abandoned)
- `coverage`: a real object (`{"status":"complete","reviewed_file_count":1,"omitted":[]}`) -- NOT
  the `{"status":"unknown"}` sentinel. This is the whole point of the scenario: real coverage data
  was captured from the failed round-1 attempt and survived into the final artifact even though
  round 1's own dispatch technically failed on its first try.
- The fixed invocation log shows exactly 1 `mode=fresh ` line and exactly 1 `mode=resume ` line,
  both sharing the same `thread_id` (`A`).

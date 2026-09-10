# Scenario: compact-trigger-uncommitted-success

**Group:** H (`compaction.md` opt-in-feature coverage) -- the FIRST and most basic compaction
scenario: a single trigger, a single successful fresh restart, no retries, no circuit breakers.
Every other compaction scenario in this suite builds on this one's basic shape. (Groups A-G are
already taken by existing suites -- see `codex-stream-review/evals/README.md`'s scenario index --
so compaction coverage starts a new group letter.)

**Targets:** `references/compaction.md`'s "Trigger" section (the threshold check firing after
round 1) and "Restart mechanism" section (a genuinely FRESH `--uncommitted` dispatch for round 2,
never `--resume`) for the ordinary, nothing-goes-wrong path -- confirms the old thread ends up
`"kind":"leaked"`/`"cleanup":"deleted"` in the final result (never silently dropped), and that
`round_count` still increments normally (compaction consumes an ordinary round-counter
increment, per "Scope (v1)").

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run. Round 1's dispatch
needs `FAKE_CODEX_SCENARIO=normal` and `FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,
"output_tokens":50000}'` (over `COMPACT_THRESHOLD`, triggering compaction for round 2). Round 2's
(compaction) dispatch needs `FAKE_CODEX_SCENARIO=normal` and `FAKE_CODEX_USAGE_JSON=
'{"input_tokens":500000,"output_tokens":30000}'` (comfortably under threshold, so
`COMPACTION_BASELINE_TOKENS` never re-triggers anything). Both `--cleanup` calls need
`FAKE_CODEX_CLEANUP_OK=1`. `FAKE_CODEX_INVOCATION_LOG` must be set to the fixed path `setup.sh`
prints on every call.

This invocation-count check is best-effort, matching every other scenario in this suite: if the
invocation log has already been cleaned up by the time `expect.sh` runs, that one check is
skipped with a WARN instead of failing the whole scenario.

## How to run

```bash
bash codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/setup.sh
```

Then invoke `codex-stream-review:ccs --compact` against `REPO_DIR` with the task text:

> --compact review the uncommitted change in this fixture repo

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> compact-trigger-uncommitted-success
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `2`
- `threads`: two entries -- `{"group":"main","thread_id":B,"kind":"current","cleanup":"deleted"}`
  and `{"group":"main","thread_id":A,"kind":"leaked","cleanup":"deleted"}`
- The fixed invocation log shows exactly 2 `mode=fresh ` lines (two DIFFERENT `thread_id` values
  -- A then B) and ZERO `mode=resume ` lines. `expect.sh` also cross-references the specific IDs:
  `leaked` must equal the FIRST fresh dispatch's `thread_id` (A) and `current` must equal the
  SECOND (B) -- not merely "two distinct IDs exist in each of two places".

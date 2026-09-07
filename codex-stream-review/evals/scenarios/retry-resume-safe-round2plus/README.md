# Scenario: retry-resume-safe-round2plus

**Group:** B (`retry-guards.md` retry-decision-tree coverage)
**Targets:** `references/retry-guards.md`'s "A `threadId` WAS captured, and the reason is
resume-safe" branch, on a **ROUND 2+** dispatch instead of round 1 (compare
`retry-resume-safe-round1`, which covers the round-1 case, including its coverage-capture-before-
retry note -- that note does NOT apply here: coverage is a round-1-only property, and round 2's own
`--resume` attempts never carry it, success or failure alike). This scenario purely confirms the
bounded resume-retry-with-backoff sequence (5s wait, retry; if that fails, 15s wait, retry once
more) works correctly on a LATER round, exhausting BOTH bounded backoff waits before the eventual
successful retry converges to a real result.

## Why a real round 2 exists here

Round 1 must legitimately NOT converge for a round 2 to exist at all. This fixture's uncommitted
change is the same deliberate off-by-one bug `eval_make_fixture_repo` always creates (`lib.py`'s
`add()` returns `a+b+1`). Round 1's scripted verdict names that exact bug as a real finding; the
driving agent fixes it for real before round 2 ever dispatches.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_INVOCATION_LOG` must be
set to the fixed path `setup.sh` prints
(`/tmp/ccs-eval-retry-resume-safe-round2plus-invocation.log`) on every call.

This invocation-count check is best-effort: if the invocation log has already been cleaned up by
the time `expect.sh` runs later (it is an ephemeral `/tmp` diagnostic file, not a durable artifact
like the `.jsonl` log or `.result.json`), that one check is skipped with a WARN instead of failing
the whole scenario -- the schema and field-based assertions remain the authoritative,
always-checkable ones.

## How to run

```bash
bash codex-stream-review/evals/scenarios/retry-resume-safe-round2plus/setup.sh
```

Then invoke `codex-stream-review:ccs` against `REPO_DIR` with the task text:

> review the uncommitted change in this fixture repo

Sequence:

1. **Fresh round-1 dispatch** (`--uncommitted`), scripted to a real `ISSUES` verdict naming
   `lib.py:3`'s off-by-one bug. Real `threadId` (`A`) captured.
2. **Fix the bug for real** -- edit `REPO_DIR/lib.py`, remove the `+ 1`.
3. **Round 2 dispatch attempt 1**: `--resume A --timeout 300` (genuine History+Scope focus text
   recapping the fix), `FAKE_CODEX_SCENARIO=exit_nonzero` -- fails, resume-safe reason.
4. **Wait 5s**, `--resume A --timeout 300` retry #1, `FAKE_CODEX_SCENARIO=exit_nonzero` -- fails
   again.
5. **Wait 15s**, `--resume A --timeout 300` retry #2 (the second and final bounded resume retry),
   `FAKE_CODEX_SCENARIO=normal` with a CLEAN `FAKE_CODEX_FINAL_ANSWER` -- succeeds, SAME `A`.
6. Round 2 converges `✅ CLEAN` using this successful retry's own result.
7. Phase 3: `--cleanup A`, `FAKE_CODEX_CLEANUP_OK=1`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> retry-resume-safe-round2plus
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `2` (a real round 2 existed and is what actually
  converged)
- `threads`: exactly one entry, `{"group":"main","thread_id":A,"kind":"current","cleanup":"deleted"}`
  -- no `"leaked"` entry
- The fixed invocation log shows exactly 1 `mode=fresh ` line (round 1) and exactly 3
  `mode=resume ` lines (round 2's original attempt plus both bounded backoff retries) -- the only
  reliable proof the FULL 5s-then-15s bounded retry sequence actually ran, not just a single retry
  -- and all 4 dispatch lines share the identical `thread_id` (`A`).

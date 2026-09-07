# Scenario: retry-exhausted-round2plus-no-fallback

**Group:** B (`retry-guards.md` retry-decision-tree coverage)
**Targets:** `references/retry-guards.md`'s "If both resume-retries are exhausted and this was
round 2+" branch -- the same "both resume-retries fail" shape as
`retry-exhausted-round1-fresh-fallback`, but on a round-2+ group (round 1 succeeded normally
first). There is NO fresh-scope fallback available once a group has ever been resumed -- stop
directly, report `⚠️ COULD NOT VERIFY` for that group. No new `threadId` is ever created on this
path, so nothing is added to `LEAKED_THREAD_IDS`.

## Why a real round 2 exists here

Round 1 must legitimately NOT converge for a round 2 to exist at all. This fixture's uncommitted
change is the same deliberate off-by-one bug `eval_make_fixture_repo` always creates (`lib.py`'s
`add()` returns `a+b+1`). Round 1's scripted verdict names that exact bug as a real finding; the
driving agent fixes it for real before round 2 ever dispatches.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_INVOCATION_LOG` must be
set to the fixed path `setup.sh` prints
(`/tmp/ccs-eval-retry-exhausted-round2plus-no-fallback-invocation.log`) on every call.

This invocation-count check is best-effort: if the invocation log has already been cleaned up by
the time `expect.sh` runs later (it is an ephemeral `/tmp` diagnostic file, not a durable artifact
like the `.jsonl` log or `.result.json`), that one check is skipped with a WARN instead of failing
the whole scenario -- the schema and field-based assertions remain the authoritative,
always-checkable ones.

## How to run

```bash
bash codex-stream-review/evals/scenarios/retry-exhausted-round2plus-no-fallback/setup.sh
```

Then invoke `codex-stream-review:ccs` against `REPO_DIR` with the task text:

> review the uncommitted change in this fixture repo

Sequence:

1. **Fresh round-1 dispatch** (`--uncommitted`), scripted to a real `ISSUES` verdict naming
   `lib.py:3`'s off-by-one bug. Real `threadId` (`A`) captured.
2. **Fix the bug for real** -- edit `REPO_DIR/lib.py`, remove the `+ 1`.
3. **Round 2 dispatch attempt 1**: `--resume A --timeout 300`, `exit_nonzero` -- fails.
4. **Wait 5s**, `--resume A --timeout 300` retry #1, `exit_nonzero` -- fails again.
5. **Wait 15s**, `--resume A --timeout 300` retry #2 (the second and final bounded resume retry),
   `exit_nonzero` -- fails a THIRD time. Both bounded resume retries now exhausted.
6. Per `retry-guards.md`'s round-2+ branch: there is no fresh scope left to fall back to on an
   already-resumed group -- **stop directly, report `⚠️ COULD NOT VERIFY`** for group `main`. No
   new `threadId` is created on this path, so `LEAKED_THREAD_IDS` stays empty -- thread `A` is
   simply this group's own still-current, never-abandoned thread.
7. Phase 3: `--cleanup A` (from `GROUP_THREADS`, kind `current` -- NOT leaked),
   `FAKE_CODEX_CLEANUP_OK=1`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> retry-exhausted-round2plus-no-fallback
```

## Expected result

- `exit_state`: `"COULD_NOT_VERIFY"`, `round_count`: `2`
- `threads`: exactly one entry, `{"group":"main","thread_id":A,"kind":"current","cleanup":"deleted"}`
  -- NO `"leaked"` entry anywhere. This is the defining difference from
  `retry-exhausted-round1-fresh-fallback` and `could-not-verify-exhausted`, both of which DO
  produce a leaked entry.
- `claims`: one still-`open` entry for the round-1 finding (`disposition`/`source_round`/
  `marker_reason` all `null`) -- round 1 DID complete a real review and raise a real finding before
  the fix; round 2 (the re-check dispatch) is what never completed, so that claim never reaches a
  terminal disposition
- The fixed invocation log shows exactly 1 `mode=fresh ` line (round 1) and exactly 3
  `mode=resume ` lines (round 2's original attempt plus both bounded retries), all sharing the
  identical `thread_id` (`A`) -- proving no fresh scope flag was ever attempted for this group
  after round 1.

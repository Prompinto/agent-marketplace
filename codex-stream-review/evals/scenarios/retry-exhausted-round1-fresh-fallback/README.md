# Scenario: retry-exhausted-round1-fresh-fallback

**Group:** B (`retry-guards.md` retry-decision-tree coverage) -- built FIRST among the two
exhausted-retry scenarios, per this suite's own priority (the highest-risk branch-specific safety
behaviors: does the leaked thread actually get cleaned up, and does a group with no fresh fallback
correctly stop instead of leaking).

**Targets:** `references/retry-guards.md`'s "If both resume-retries are exhausted and this was
round 1" branch -- a round-1 group's initial dispatch gets a real `threadId`, then BOTH bounded
`--resume` retries fail too (3 consecutive `nonzero_exit` failures: the original fresh dispatch,
then both bounded resume retries). Falls back to ONE fresh retry of the original scope flag,
abandoning the now-unrecoverable thread -- appends `(GROUP, threadId)` to `LEAKED_THREAD_IDS`.

## How this differs from `could-not-verify-exhausted`

`could-not-verify-exhausted` forces the fresh fallback retry to ALSO fail, reaching
`⚠️ COULD NOT VERIFY`. **This scenario's fresh fallback SUCCEEDS** -- confirming the leaked thread
from the abandoned first attempt is genuinely cleaned up (Phase 3 step 2) ALONGSIDE the new current
thread from the successful fallback, not merely recorded into `LEAKED_THREAD_IDS` and forgotten.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_SCENARIO=exit_nonzero`
must be set on the first 3 dispatch calls (fresh, resume retry #1, resume retry #2);
`FAKE_CODEX_SCENARIO=normal` on the 4th (fresh fallback); both `--cleanup` calls need
`FAKE_CODEX_CLEANUP_OK=1`. `FAKE_CODEX_INVOCATION_LOG` must be set to the fixed path `setup.sh`
prints (`/tmp/ccs-eval-retry-exhausted-round1-fresh-fallback-invocation.log`) on every call.

This invocation-count check is best-effort: if the invocation log has already been cleaned up by
the time `expect.sh` runs later (it is an ephemeral `/tmp` diagnostic file, not a durable artifact
like the `.jsonl` log or `.result.json`), that one check is skipped with a WARN instead of failing
the whole scenario -- the schema and field-based assertions remain the authoritative,
always-checkable ones.

## How to run

```bash
bash codex-stream-review/evals/scenarios/retry-exhausted-round1-fresh-fallback/setup.sh
```

Then invoke `codex-stream-review:ccs` against `REPO_DIR` with the task text:

> review the uncommitted change in this fixture repo

Sequence:

1. **Fresh round-1 dispatch** (`--uncommitted`), `exit_nonzero` -- real `threadId` (`A`) captured
   despite the failure. Capture `coverage.source` from this failing attempt now.
2. **Wait 5s**, `--resume A --timeout 300`, `exit_nonzero` -- fails the same way.
3. **Wait 15s**, `--resume A --timeout 300`, `exit_nonzero` -- fails the same way. Both bounded
   resume retries now exhausted (3 consecutive failures total).
4. **Fall back**: fresh `--uncommitted` dispatch again, abandoning `A` -- append `(main, A)` to
   `LEAKED_THREAD_IDS`. `FAKE_CODEX_SCENARIO=normal` this time -- SUCCEEDS, new real `threadId`
   (`B`), CLEAN verdict.
5. Round 1 converges `✅ CLEAN` using `B`'s own successful response (its own `coverage.source` is
   used directly -- "ordinarily its one successful attempt", per "Coverage is a Round-1-only
   property").
6. Phase 3: `--cleanup B` (current) AND `--cleanup A` (leaked) -- both `FAKE_CODEX_CLEANUP_OK=1`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> retry-exhausted-round1-fresh-fallback
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `1`
- `threads`: two entries -- `{"group":"main","thread_id":B,"kind":"current","cleanup":"deleted"}`
  and `{"group":"main","thread_id":A,"kind":"leaked","cleanup":"deleted"}` -- the leaked thread `A`
  really was cleaned up (Phase 3 step 2), not just recorded
- The fixed invocation log shows exactly 2 `mode=fresh ` lines (with two DIFFERENT `thread_id`
  values -- `A` then `B`) and exactly 2 `mode=resume ` lines (both against `A`).

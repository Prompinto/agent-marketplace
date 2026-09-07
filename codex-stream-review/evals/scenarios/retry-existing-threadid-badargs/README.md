# Scenario: retry-existing-threadid-badargs

**Group:** B (`retry-guards.md` retry-decision-tree coverage)
**Targets:** `references/retry-guards.md`'s "This group ALREADY has an entry in `GROUP_THREADS`"
branch, specifically its own named example: a `--resume` call fails with **no `threadId`** in its
own failure response, even though a real thread already exists for this group. Confirms this does
NOT abandon the existing thread -- no fresh scope flag, nothing added to `LEAKED_THREAD_IDS` -- it
just retries the exact same `--resume <threadId>` call again with the mistake corrected.

## A REAL bad_args, not a simulated one

Per `retry-guards.md`: "a `--resume` call CAN still fail with no `threadId` in its own failure JSON
(e.g. `bad_args` from empty/whitespace-only focus text on stdin, caught right after the wrapper
reads its own stdin *before* it ever touches the resumed thread)". This scenario reproduces that
literally: the driving agent deliberately sends empty/whitespace-only stdin on one `--resume` call,
which the REAL (unmodified) `run-ccs-review.sh` rejects itself -- confirmed directly from its own
dispatch order (`_focus_is_empty` runs before any `codex` invocation, `scripts/run-ccs-review.sh`
around line 603). This means that one failing call never invokes `codex` (real or fake) at all, so
it never appends a line to `FAKE_CODEX_INVOCATION_LOG` either -- only round 1's fresh dispatch and
the retried, corrected `--resume` call actually reach fake-codex.

## Why a real round 2 exists here

`retry-guards.md`'s own framing is "a LATER `--resume` call fails" -- this requires a genuine round
2 to exist, which in turn requires round 1 to NOT converge immediately. This fixture's uncommitted
change is the same deliberate off-by-one bug `eval_make_fixture_repo` always creates (`lib.py`'s
`add()` returns `a+b+1`). Round 1's scripted verdict (`FAKE_CODEX_FINAL_ANSWER`) names that exact
bug as a real finding; the driving agent fixes it for real (removes the `+ 1`); round 2 is the
legitimate re-check `--resume` dispatch -- and it is exactly THIS dispatch the driving agent sends
blank stdin on once, before correcting it.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call that DOES reach `codex` (round 1's
dispatch, and the corrected retry) -- see `codex-stream-review/evals/README.md`'s "Mechanical
caveat". `FAKE_CODEX_INVOCATION_LOG` must be set to the fixed path `setup.sh` prints
(`/tmp/ccs-eval-retry-existing-threadid-badargs-invocation.log`) on those calls -- `expect.sh` reads
that same fixed path directly.

This invocation-count check is best-effort: if the invocation log has already been cleaned up by
the time `expect.sh` runs later (it is an ephemeral `/tmp` diagnostic file, not a durable artifact
like the `.jsonl` log or `.result.json`), that one check is skipped with a WARN instead of failing
the whole scenario -- the schema and field-based assertions remain the authoritative,
always-checkable ones.

## How to run

```bash
bash codex-stream-review/evals/scenarios/retry-existing-threadid-badargs/setup.sh
```

Then invoke `codex-stream-review:ccs` against `REPO_DIR` with the task text:

> review the uncommitted change in this fixture repo

Sequence:

1. **Fresh round-1 dispatch** (`--uncommitted`), `FAKE_CODEX_FINAL_ANSWER` scripted to a real
   `ISSUES` verdict naming `lib.py:3`'s actual off-by-one bug. Real `threadId` (`T`) captured.
2. **Fix the bug for real** -- edit `REPO_DIR/lib.py`, remove the `+ 1`.
3. **Round 2 dispatch attempt 1**: `--resume T --timeout 300` with EMPTY/whitespace-only stdin (a
   genuine mistake) -- the real wrapper itself rejects it: `{"ok":false,"reason":"bad_args",...}`,
   no `threadId`. Thread `T` is untouched (`GROUP_THREADS` already has it).
4. **Retry**: `--resume T --timeout 300` again, this time genuine non-empty focus text
   (History: fixed the off-by-one; Scope: re-check), `FAKE_CODEX_SCENARIO=normal` -- succeeds, SAME
   `T`.
5. Round 2 converges `✅ CLEAN`.
6. Phase 3: `--cleanup T`, `FAKE_CODEX_CLEANUP_OK=1`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> retry-existing-threadid-badargs
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `2`
- `threads`: exactly one entry, `{"group":"main","thread_id":T,"kind":"current","cleanup":"deleted"}`
  -- the SAME `T` from round 1, never replaced, never marked `"leaked"`
- The fixed invocation log shows exactly 1 `mode=fresh ` line and exactly 1 `mode=resume ` line (the
  bad_args attempt contributes none), and both lines' own `thread_id` field is the identical value
  `T` -- the concrete proof the same thread persisted across the failure and its retry, never a
  fresh scope flag.

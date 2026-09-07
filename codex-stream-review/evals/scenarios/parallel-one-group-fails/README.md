# Scenario: parallel-one-group-fails

**Group:** E (parallel-mode)
**Targets:** worst-case-wins across groups. `g1`'s every dispatch attempt fails
(`FAKE_CODEX_SCENARIO=exit_nonzero`), genuinely exhausting `references/retry-guards.md`'s full
bounded-retry sequence (mirroring `could-not-verify-exhausted`, scoped to one group of a parallel
round) while `g2` converges `CLEAN` immediately. Per `retry-guards.md`: "Whenever a group ends in
`COULD NOT VERIFY`, the round-level status is `COULD NOT VERIFY`, regardless of how clean every
other group's own findings turned out to be" -- so the session's `exit_state` must be
`COULD_NOT_VERIFY`, never `CLEAN`, even though `g2` individually did everything right.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call. `g1`'s EVERY dispatch attempt this
run (fresh round 1, both bounded `--resume` retries, the round-1 fresh-fallback retry) must set
`FAKE_CODEX_SCENARIO=exit_nonzero` inline on that command only -- never a shared `export` mutated
between the two concurrent group dispatches (see `tests/fixtures/fake-codex`'s own
`FAKE_CODEX_GROUP_STATE` doc comment for why). `g2`'s dispatch uses the default
`FAKE_CODEX_SCENARIO=normal`.

## How to run

```bash
bash codex-stream-review/evals/scenarios/parallel-one-group-fails/setup.sh
```

Then invoke `codex-stream-review:ccs` against the printed `REPO_DIR` with:

> review the uncommitted change in this fixture repo

Dispatch 2 parallel groups. Expected sequence (mirrors `could-not-verify-exhausted`, scoped to
`g1` only, concurrently with `g2`'s own immediate success):

1. Round 1, both groups dispatched concurrently. `g2` returns `CLEAN`/`findings:[]` immediately
   (threadId `C`). `g1`'s fresh dispatch still emits `thread.started` before `exit_nonzero` fires,
   so a real threadId (`A`) is captured, with a real `coverage.source` (collection completed before
   the fake binary exits) -- capture `g1`'s round-1 coverage from this failing attempt now.
2. Since `g1` returned `ok:false`, the round is not eligible for `CLEAN` -- retry JUST `g1`; `g2`'s
   real result is kept, not re-dispatched.
3. Wait 5s, `--resume A --timeout 300` (still `exit_nonzero`) -- fails.
4. Wait 15s, `--resume A --timeout 300` (same) -- fails. Both bounded resume-retries exhausted.
5. Round-1 fresh fallback: one fresh retry of `g1`'s original `--uncommitted` scope, abandoning
   thread `A` (append `(g1, A)` to `LEAKED_THREAD_IDS`). Obtains a new threadId `B`, also fails.
6. Stop -- report `COULD NOT VERIFY` for `g1`. The session-level status is `COULD NOT VERIFY`
   regardless of `g2`'s own clean result.

Phase 3 cleanup runs unconditionally for every group's every known thread. Set
`FAKE_CODEX_CLEANUP_OK=1` on all three `--cleanup` calls (`g1`'s `B` via `GROUP_THREADS`, `g1`'s
`A` via `LEAKED_THREAD_IDS`, `g2`'s `C` via `GROUP_THREADS`).

```bash
bash codex-stream-review/evals/check-result.sh <result.json> parallel-one-group-fails
```

## Expected result

- `exit_state`: `"COULD_NOT_VERIFY"`
- `round_count`: `1`
- `claims`: `[]`
- `threads`: three entries -- `{"group":"g1","thread_id":"<B>","kind":"current","cleanup":"deleted"}`,
  `{"group":"g1","thread_id":"<A>","kind":"leaked","cleanup":"deleted"}`,
  `{"group":"g2","thread_id":"<C>","kind":"current","cleanup":"deleted"}`
- `coverage`: an object, `status:"complete"` (round-1 N-group merge: `g1`'s failing-attempt
  coverage and `g2`'s successful coverage were both complete in this fixture)
- `input_errors`: `null`

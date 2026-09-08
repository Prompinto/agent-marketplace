# Scenario: could-not-verify-exhausted

**Group:** A (terminal-status matrix)
**Targets:** `exit_state == "COULD_NOT_VERIFY"`, reached only once
`references/retry-guards.md`'s full bounded-retry sequence genuinely exhausts -- not a single
failed dispatch reported prematurely as unverifiable.

Forces `FAKE_CODEX_SCENARIO=exit_nonzero` on every single dispatch attempt this run makes (the
original round-1 attempt, both bounded `--resume` retries, and the final round-1 fresh-fallback
retry), so every attempt fails identically (`nonzero_exit`, a resume-safe reason per `SKILL.md`'s
"Resume-safety by failure reason" table) and the retry machinery genuinely runs to its documented
end rather than the scenario accidentally succeeding on some attempt.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). Additionally, `FAKE_CODEX_SCENARIO=
exit_nonzero` must be set explicitly on EVERY dispatch call in the sequence below -- it is not a
one-time session setting, since each dispatch is its own separate `codex` process invocation
(fresh shell, fresh env) per Claude Code's own Bash tool semantics.

## How to run

```bash
bash codex-stream-review/evals/scenarios/could-not-verify-exhausted/setup.sh
```

Prints `REPO_DIR` and `BIN_DIR`. Then invoke `codex-stream-review:ccs` against `REPO_DIR` with:

> review the uncommitted change in this fixture repo

and follow `references/retry-guards.md`'s "A `threadId` WAS captured, and the reason is
resume-safe" branch exactly as it's written -- do not shortcut it. The expected sequence:

1. **Fresh round-1 dispatch** (`--uncommitted`). `fake-codex` still emits `thread.started` before
   failing (the scenario's `exit_nonzero` branch runs after that line), so a real threadId
   (`A`) IS captured despite the failure. `nonzero_exit` is resume-safe, so this is not an
   immediate stop.
2. **Wait 5s**, `--resume A --timeout 300` -- fails the same way.
3. **Wait 15s**, `--resume A --timeout 300` -- fails the same way. Both bounded resume-retries
   are now exhausted.
4. This was round 1, so: **fall back to one fresh retry** of the original `--uncommitted` scope,
   abandoning thread `A` -- append `(main, A)` to `LEAKED_THREAD_IDS`. This fresh dispatch obtains
   a NEW real threadId (`B`), and also fails.
5. That fresh retry failing too means: **stop, report `⚠️ COULD NOT VERIFY`** for group `main`.

At Phase 3, cleanup runs unconditionally (this session never sets `--keep-evidence`, so the
keep-evidence gate never applies in the first place): `--cleanup B` (from `GROUP_THREADS`) and
`--cleanup A` (from `LEAKED_THREAD_IDS`), both with `FAKE_CODEX_CLEANUP_OK=1` set so the fake
`delete` subcommand actually succeeds, letting the resulting artifact show genuine
`cleanup:"deleted"` rather than `fake-codex`'s always-fails-by-default `delete` behavior masking
whether the orchestrator's own cleanup logic ran correctly.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> could-not-verify-exhausted
```

## Expected result

- `exit_state`: `"COULD_NOT_VERIFY"`
- `claims`: `[]` -- no round ever completed a real review, so nothing was ever raised to track
- `threads`: two entries --
  `{"group":"main","thread_id":"<B>","kind":"current","cleanup":"deleted"}` and
  `{"group":"main","thread_id":"<A>","kind":"leaked","cleanup":"deleted"}`
- `coverage`: an object (this is `target.scope:"uncommitted"`) -- the round-1 attempt's own
  `coverage.source`, captured from the FIRST failing attempt before any retry, per
  `references/retry-guards.md`'s "Round 1 only -- capture coverage from the failing attempt
  BEFORE retrying" note (`nonzero_exit` is one of the 7 reasons that unconditionally carries
  `coverage.source` on a fresh `--uncommitted` dispatch)
- `input_errors`: `null` (always null -- no outcome ever populates it)

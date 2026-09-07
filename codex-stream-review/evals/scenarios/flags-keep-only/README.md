# Scenario: flags-keep-only

**Group:** C (feature-flag matrix)
**Targets:** `--keep-evidence` ON, `--capture-evidence` OFF -- needs a NON-CLEAN outcome to
actually exercise the keep-vs-delete gate, since it only changes behavior for a non-CLEAN terminal
status.

Reuses `could-not-verify-exhausted`'s own forced `FAKE_CODEX_SCENARIO=exit_nonzero` retry-
exhaustion sequence (fresh round-1 dispatch -> 2 bounded `--resume` retries -> 1 fresh fallback
retry -> `COULD NOT VERIFY`), with `--keep-evidence` layered on top. Confirms
`references/keep-evidence.md`'s Phase-3 gate actually fires: `threads[]` reads `cleanup:"retained"`
for every thread (never `"deleted"`), and a kept last-message file exists at the documented durable
path.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"), `FAKE_CODEX_SCENARIO=exit_nonzero` on
EVERY dispatch call, and `FAKE_CODEX_INVOCATION_LOG=<the fixed path setup.sh prints>` on every
dispatch call too. **Never set `FAKE_CODEX_CLEANUP_OK`** -- this scenario's whole point is that no
`--cleanup` call is ever made, so the fake binary's default always-fails `delete` behavior is never
exercised either way.

## How to run

```bash
bash codex-stream-review/evals/scenarios/flags-keep-only/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `INVOCATION_LOG`. Then invoke `codex-stream-review:ccs` against
`REPO_DIR` with the task text:

> --keep-evidence review the uncommitted change in this fixture repo

and follow `references/retry-guards.md`'s resume-safe exhaustion branch exactly (see `setup.sh` for
the full expected sequence, including the per-attempt `--keep-last-message` mechanics and which
attempt's kept file actually survives).

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> flags-keep-only
```

## Expected result

- `exit_state`: `"COULD_NOT_VERIFY"`, `claims`: `[]`
- `threads`: two entries -- `{"group":"main","thread_id":"<B>","kind":"current","cleanup":"retained"}`
  and `{"group":"main","thread_id":"<A>","kind":"leaked","cleanup":"retained"}` -- `"retained"`
  because Phase 3's keep-evidence gate skipped both `--cleanup` loops entirely (the outcome is
  non-CLEAN and neither integrity-failure status)
- A kept last-message file exists at
  `~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>-kept-evidence/round-1-main-lastmsg.txt`
  -- the LAST attempt's (thread B's) own output, per `references/retry-guards.md`'s multi-attempt
  kept-evidence rule; the three earlier attempts' own kept files are deleted without being moved
- `FAKE_CODEX_INVOCATION_LOG` recorded exactly 4 real invocations (`fresh, resume, resume, fresh`)
  and **zero** `delete` invocations -- the concrete signature that the keep-evidence gate actually
  suppressed cleanup, not merely that cleanup happened not to be logged

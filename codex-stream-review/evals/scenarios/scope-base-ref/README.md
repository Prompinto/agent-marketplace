# Scenario: scope-base-ref

**Group:** D (scope/artifact-shape coverage)
**Targets:** a `--base <ref>` dispatch: confirm `target.scope == "base"` and `coverage == null`
(per `schemas/interactive-result.schema.json`'s own rule: `--base`/`--commit` scope never
populates coverage).

The fixture repo has two real commits (`initial`, then `introduce off-by-one`) plus a `base-ref`
branch pinned to the first commit -- unlike `eval_make_fixture_repo` (whose one change is
deliberately left uncommitted, for `--uncommitted` scenarios), this repo commits both revisions and
leaves nothing uncommitted, so a `--base base-ref` dispatch has a real three-dot diff
(`base-ref...HEAD`) to collect.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"), plus
`FAKE_CODEX_INVOCATION_LOG=<the fixed path setup.sh prints>` on every dispatch/cleanup call, plus
`FAKE_CODEX_CLEANUP_OK=1` on the `--cleanup` call.

## How to run

```bash
bash codex-stream-review/evals/scenarios/scope-base-ref/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `INVOCATION_LOG`. Then invoke `codex-stream-review:ccs` against
`REPO_DIR` with the task text:

> review the diff from the base-ref branch to HEAD in this fixture repo

and dispatch round 1 with `--base "base-ref"` instead of `--uncommitted` -- `REPO_DIR` has no
uncommitted changes at all, so `--uncommitted` here would collect an empty diff.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> scope-base-ref
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `1`
- `target.scope`: `"base"`
- `coverage`: `null`
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `FAKE_CODEX_INVOCATION_LOG`: exactly 2 invocations, `mode=fresh` then `mode=delete`

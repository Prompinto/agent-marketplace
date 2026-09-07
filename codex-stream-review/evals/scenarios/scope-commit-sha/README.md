# Scenario: scope-commit-sha

**Group:** D (scope/artifact-shape coverage)
**Targets:** a `--commit <sha>` dispatch against a real commit in a fixture repo. Same
coverage-null assertion as `scope-base-ref`, `target.scope == "commit"` instead of `"base"`.

The fixture repo has two real commits; the second (`introduce off-by-one`) is a normal, one-parent
commit, so `scripts/run-ccs-review.sh`'s own `--commit` collection takes its non-merge branch
(`git show <sha>`), not the two-parent `diff <sha>^1 <sha>` branch.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"), plus
`FAKE_CODEX_INVOCATION_LOG=<the fixed path setup.sh prints>` on every dispatch/cleanup call, plus
`FAKE_CODEX_CLEANUP_OK=1` on the `--cleanup` call.

## How to run

```bash
bash codex-stream-review/evals/scenarios/scope-commit-sha/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `INVOCATION_LOG`, and `COMMIT_SHA`. Then invoke
`codex-stream-review:ccs` against `REPO_DIR` with the task text:

> review commit <COMMIT_SHA> in this fixture repo

and dispatch round 1 with `--commit "<COMMIT_SHA>"` instead of `--uncommitted`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> scope-commit-sha
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `1`
- `target.scope`: `"commit"`
- `coverage`: `null`
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `FAKE_CODEX_INVOCATION_LOG`: exactly 2 invocations, `mode=fresh` then `mode=delete`

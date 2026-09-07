# Scenario: scope-uncommitted

**Group:** D (scope/artifact-shape coverage)
**Targets:** a plain `--uncommitted` fresh dispatch: confirm `target.scope == "uncommitted"` is
recorded correctly and `coverage` is a real object, not `null`, per
`schemas/interactive-result.schema.json`'s own conditional rule.

This is largely what `clean-basic` already does -- built as its own named scenario, alongside
`scope-base-ref`/`scope-commit-sha`/`scope-non-repo-artifact`, for discoverability as the "scope"
matrix's baseline member, and to add the `FAKE_CODEX_INVOCATION_LOG` invocation-count/sequence
assertion those three sibling scenarios also carry.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"), plus
`FAKE_CODEX_INVOCATION_LOG=<the fixed path setup.sh prints>` on every dispatch/cleanup call, plus
`FAKE_CODEX_CLEANUP_OK=1` on the `--cleanup` call.

## How to run

```bash
bash codex-stream-review/evals/scenarios/scope-uncommitted/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `INVOCATION_LOG`. Then invoke `codex-stream-review:ccs` against
`REPO_DIR` with the task text:

> review the uncommitted change in this fixture repo

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> scope-uncommitted
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `1`
- `target.scope`: `"uncommitted"`
- `coverage`: an object, `status:"complete"` (never `null` for this scope)
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `FAKE_CODEX_INVOCATION_LOG`: exactly 2 invocations, `mode=fresh` then `mode=delete`

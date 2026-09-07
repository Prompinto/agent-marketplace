# Scenario: scope-non-repo-artifact

**Group:** D (scope/artifact-shape coverage)
**Targets:** the `CLEAN_REPO_DIR` path (`references/non-repo-artifact.md`) -- review pasted
analysis/plan text, not a real diff.

Confirms `target.scope == "uncommitted"` (per `SKILL.md`'s own Phase 0 step 4 +
`non-repo-artifact.md`: a non-repo-artifact round always dispatches `--uncommitted` against the
empty `CLEAN_REPO_DIR`, never `--base`/`--commit`) and `coverage.status == "complete"` with
`reviewed_file_count == 0` (per `SKILL.md`'s "Coverage is a Round-1-only property" section's own
documented reasoning for why a zero-file `CLEAN_REPO_DIR` round reports `complete`, not
`unknown`).

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"), plus
`FAKE_CODEX_INVOCATION_LOG=<the fixed path setup.sh prints>` on every dispatch/cleanup call, plus
`FAKE_CODEX_CLEANUP_OK=1` on the `--cleanup` call. Unlike every other scenario in this harness,
there is no fixture git repo to review at all -- `setup.sh` instead writes a plain text file
(`ARTIFACT_FILE`) holding a short plan/analysis paragraph, with no git repo behind it.

## How to run

```bash
bash codex-stream-review/evals/scenarios/scope-non-repo-artifact/setup.sh
```

Prints `ARTIFACT_FILE`, `BIN_DIR`, `INVOCATION_LOG`. Then invoke `codex-stream-review:ccs` with the
task text: "review this plan for correctness and completeness:" followed by `ARTIFACT_FILE`'s exact
contents pasted verbatim. Read `skills/ccs/references/non-repo-artifact.md` in full and follow its
`CLEAN_REPO_DIR`/`FAKE_GIT_HOME` mechanism exactly -- dispatch round 1 with
`--cwd "<CLEAN_REPO_DIR>" --uncommitted`, never `$REPO_ROOT`, never `--base`/`--commit`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> scope-non-repo-artifact
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `1`
- `target.scope`: `"uncommitted"` (never `"base"`/`"commit"` -- `CLEAN_REPO_DIR` has no commits)
- `coverage`: an object, `status:"complete"`, `reviewed_file_count:0` -- the wrapper's own
  untracked-file collector still runs against a zero-file repo and reports an empty `omitted`
  list, which yields `status:"complete"` regardless of the zero file count.
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `FAKE_CODEX_INVOCATION_LOG`: exactly 2 invocations, `mode=fresh` then `mode=delete` (this round
  is always single-group, never parallel)

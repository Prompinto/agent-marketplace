# Scenario: clean-basic

**Group:** A (terminal-status matrix)
**Targets:** `exit_state == "CLEAN"`, the baseline happy-path terminal status.

Confirms the orchestrator (Claude following `skills/ccs/SKILL.md`) correctly reaches and reports
`CLEAN` on the simplest possible real `/ccs` dispatch: one fresh `--uncommitted` round, a
scripted always-CLEAN Codex responder, single-reviewer mode, normal thread cleanup. This is
about the ORCHESTRATOR's own control flow (does it correctly recognize a CLEAN verdict and
terminate after round 1, does it write a schema-correct `.result.json`), not about Codex's real
review judgment -- so `fake-codex`'s scripted `FAKE_CODEX_SCENARIO=normal` responder (its own
default) is the right, deterministic choice here, not a real Codex call.

## Mechanical setup

Like every scenario in this harness, a live run needs the fake-`codex` binary
(`codex-stream-review/tests/fixtures/fake-codex`) ahead of the REAL `codex` CLI on `$PATH` for
every single Bash call made during the run -- Claude Code's Bash tool gives a fresh shell per
call, so nothing exported in one call (a `PATH` override, an env var) persists into the next.
There is no way to set this once; it must be re-prepended on every call. See
`codex-stream-review/evals/README.md`'s "Mechanical caveat" section for why.

This scenario's cleanup step also needs `FAKE_CODEX_CLEANUP_OK=1` set on the `--cleanup` call in
Phase 3 -- `fake-codex`'s `delete` subcommand fails by default (matching
`tests/test-run-ccs-review.sh`'s own convention of cleaning up deliberately nonexistent
threadIds), so without this var, `threads[].cleanup` would read `"failed"`, not `"deleted"`, even
though this scenario's dispatch itself succeeded cleanly.

## How to run

```bash
bash codex-stream-review/evals/scenarios/clean-basic/setup.sh
```

This prints `REPO_DIR` (a throwaway fixture git repo with one uncommitted change) and `BIN_DIR`
(a directory holding a `codex` symlink to the fake binary). Then, as a Claude Code agent (or by
hand), invoke `codex-stream-review:ccs` against `REPO_DIR` with the task text:

> review the uncommitted change in this fixture repo

On every Bash call made while following `SKILL.md`'s phases for this run, prepend
`PATH="<BIN_DIR>:$PATH"` and set `FAKE_CODEX_SCENARIO=normal` (fake-codex's own default, so this
is technically optional, but explicit is clearer than relying on a default) on every dispatch
call, and `FAKE_CODEX_CLEANUP_OK=1` on the Phase 3 `--cleanup` call.

Once the run completes, locate the result artifact:

```
~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>.result.json
```

(`<repo-slug>` is `REPO_DIR`'s own basename, lowercased, non-alphanumeric runs collapsed to `-`.)

Then validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> clean-basic
```

## Expected result

- `exit_state`: `"CLEAN"`
- `round_count`: `1` (fake-codex's scripted verdict is CLEAN with no findings on the very first
  try -- no second round is ever needed)
- `threads`: exactly one entry, `kind:"current"`, `cleanup:"deleted"`
- `claims`: `[]` (no findings were ever raised, so nothing to track)
- `coverage`: an object with `status:"complete"` (this is an `--uncommitted` scope; a real,
  non-empty diff was fully collected and reviewed)
- `input_errors`: `null`

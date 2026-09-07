# Scenario: flags-both

**Group:** C (feature-flag matrix)
**Targets:** `--capture-evidence` AND `--keep-evidence` both ON together, on a CLEAN run.

Confirms the two independent flags compose without interfering: capture-evidence's effect shows up
in the JSONL log exactly as it does alone (`flags-capture-only`), and keep-evidence's Phase-3 gate
correctly does NOT retain anything, since the outcome IS CLEAN -- normal cleanup
(`cleanup:"deleted"`) still happens, and no kept-evidence directory is ever created.

`flags-neither` was explicitly dropped from this matrix (see
`codex-stream-review/evals/README.md`'s Group C note) since `clean-basic` already covers the
default-both-off case; this scenario, together with `flags-capture-only` and `flags-keep-only`,
completes the remaining three cells.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"), plus
`FAKE_CODEX_INVOCATION_LOG=<the fixed path setup.sh prints>` on every dispatch/cleanup call, plus
`FAKE_CODEX_COMMANDS` (a two-line scripted command list, same as `flags-capture-only`) on the
round-1 dispatch call only, plus `FAKE_CODEX_CLEANUP_OK=1` on the `--cleanup` call.

## How to run

```bash
bash codex-stream-review/evals/scenarios/flags-both/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `INVOCATION_LOG`. Then invoke `codex-stream-review:ccs` against
`REPO_DIR` with the task text:

> --capture-evidence --keep-evidence review the uncommitted change in this fixture repo

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> flags-both
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `1`, one thread (`kind:"current"`, `cleanup:"deleted"`)
- The session's own `<session-id>.jsonl` log has a round-1 line with `investigation_evidence`
  populated (`command_count: 2`) -- capture-evidence's own effect, unaffected by keep-evidence
  also being ON.
- No `<session-id>-kept-evidence/` directory is ever created this run -- round 1 succeeded, so its
  own `--keep-last-message` file is simply deleted, never moved anywhere.
- `FAKE_CODEX_INVOCATION_LOG` recorded exactly 2 invocations: `mode=fresh` then `mode=delete`.

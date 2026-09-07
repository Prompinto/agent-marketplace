# Scenario: flags-capture-only

**Group:** C (feature-flag matrix)
**Targets:** `--capture-evidence` ON, `--keep-evidence` OFF, on a CLEAN run.

Confirms `--capture-evidence`'s mechanics (`references/capture-evidence.md`) actually fire on a
real dispatch: `--capture-eventlog` is passed on the round-1 call, the fake binary's scripted
`FAKE_CODEX_COMMANDS` output is captured into that round's eventlog, and the orchestrator extracts
it into a populated `investigation_evidence` object on that round's own JSONL log line -- a
JSONL-log-only field, never part of the durable `.result.json` schema (see
`schemas/interactive-result.schema.json`; it has no such key), so this scenario checks the log
file directly, not the result artifact.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). On EVERY dispatch/cleanup call, also
set `FAKE_CODEX_INVOCATION_LOG=<the fixed path setup.sh prints>` so this scenario can assert the
fake binary was invoked the expected number of times, in the expected mode sequence. On the
round-1 dispatch call ONLY, additionally set `FAKE_CODEX_COMMANDS` to a two-line scripted command
list (see `setup.sh` for the exact text) -- `fake-codex` emits one
`item.completed`/`command_execution` event per line into stdout, which `run-ccs-review.sh` mirrors
into that round's `--capture-eventlog` file.

## How to run

```bash
bash codex-stream-review/evals/scenarios/flags-capture-only/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `INVOCATION_LOG`. Then invoke `codex-stream-review:ccs` against
`REPO_DIR` with the task text:

> --capture-evidence review the uncommitted change in this fixture repo

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> flags-capture-only
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `1`, one thread (`kind:"current"`, `cleanup:"deleted"`)
  -- the same baseline shape as `clean-basic`, since capture-evidence adds a log-only field and
  changes no control flow.
- The session's own `<session-id>.jsonl` log (sibling of the `.result.json`, same directory) has a
  round-1 line with `investigation_evidence: {"command_count": 2, "commands": ["grep -rn \"def
  add\" lib.py", "cat lib.py"]}`.
- `FAKE_CODEX_INVOCATION_LOG` recorded exactly 2 real invocations: `mode=fresh` (round-1 dispatch),
  then `mode=delete` (Phase 3 cleanup) -- confirming the fake binary, not a real `codex`, actually
  ran both times.

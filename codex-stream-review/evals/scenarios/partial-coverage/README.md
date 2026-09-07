# Scenario: partial-coverage

**Group:** A (terminal-status matrix)
**Targets:** `exit_state == "PARTIAL_COVERAGE"`.

Confirms `/ccs` never reports `CLEAN` when round 1's real source-coverage collection was
incomplete -- even when Codex's own verdict is CLEAN and Claude has no open items -- per
`SKILL.md`'s Guards section: "Partial or unknown source coverage != CLEAN, and is not the same
failure as NOT CONVERGED/COULD NOT VERIFY."

## A real omission, not a simulated one

`setup.sh` adds one untracked file sized just over `collect_untracked_files.py`'s own
`DEFAULT_MAX_BYTES` cap (1MiB) to the fixture repo. That script's own `format_entry()` genuinely
omits an untracked file over this cap, tagging it in its own coverage JSON with the short reason
code `"over_size_limit"` (confirmed live -- distinct from the longer human-readable "(over 1MB cap
or unreadable; contents omitted)" marker text the same script inlines into its rendered
diff-like output, which is a separate string for a separate purpose). `run-ccs-review.sh` then
derives `coverage.source.status`
from that real `omitted` array's length (`"partial"` when non-empty) -- confirmed from the
wrapper's own comment: "status (partial/complete) is derived here from
`$SOURCE_COVERAGE_JSON.omitted`, not self-reported by the collector." Nothing in this scenario
asserts or injects `"partial"` directly -- it is produced by the real collector/wrapper pipeline
reacting to a real oversized file.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat").

## How to run

```bash
bash codex-stream-review/evals/scenarios/partial-coverage/setup.sh
```

Prints `REPO_DIR` (a fixture repo with a normal tiny tracked-file diff, PLUS one untracked file
just over 1MiB) and `BIN_DIR`. Invoke `codex-stream-review:ccs` against `REPO_DIR` with:

> review the uncommitted change in this fixture repo

`FAKE_CODEX_SCENARIO=normal` (fake-codex's own default) on the dispatch call, and
`FAKE_CODEX_CLEANUP_OK=1` on the Phase 3 `--cleanup` call.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> partial-coverage
```

## Expected result

- Round 1's own `--uncommitted` dispatch reports
  `coverage.source == {"reviewed_file_count":1,"omitted":[{"path":"oversized-untracked.bin","reason":"over_size_limit"}],"status":"partial"}`
- Codex's verdict is CLEAN, no findings -- but the round is NOT eligible for `✅ CLEAN` per the
  coverage guard above.
- `exit_state`: `"PARTIAL_COVERAGE"`
- `round_count`: `1`
- `coverage.status`: `"partial"`, `coverage.omitted`: non-empty, names `oversized-untracked.bin`
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `claims`: `[]`
- `input_errors`: `null`

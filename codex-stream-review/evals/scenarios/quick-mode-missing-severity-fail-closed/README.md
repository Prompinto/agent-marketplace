# Scenario: quick-mode-missing-severity-fail-closed

**Group:** G (quick mode)
**Targets:** the MISSING fail-closed subcase of `SKILL.md`'s "Quick-mode early stop -- MINOR
ISSUES ACKNOWLEDGED" bullet -- a still-open claim whose severity was NEVER recorded (`null` on
every occurrence) must fail the LOW/MEDIUM canonical-severity test and fall through to the normal
`⚠️ NOT CONVERGED` cap handling, never `🟡 MINOR ISSUES ACKNOWLEDGED`.

## Why `severity:null`, not an invalid string

`severity:null` is schema-legal: `schemas/review-verdict.schema.json`'s severity enum is exactly
`low`/`medium`/`high`/`null`. A genuinely invalid severity string (e.g. `"SEV-2"`) is a DIFFERENT,
structurally unreachable case -- see `quick-mode-unparseable-severity-fail-closed`'s own README for
why that one cannot be driven through a real (or faithfully-scripted) dispatch at all. This
scenario is the one MISSING-severity case that genuinely IS reachable this way, and is driven as a
normal live Tier 2 scenario for exactly that reason.

## Why a false-positive claim, not a real bug

Same technique as `not-converged-cap`/`quick-mode-minor-acknowledged` (see those READMEs): a
correct, benign uncommitted addition (`sub(a, b): return a - b`), with `FAKE_CODEX_GROUP_STATE`
scripting 5 distinct final answers, each an `ISSUES` verdict with the SAME `finding_id`/`claim_id`
(`f1`), each with a DIFFERENT `evidence` string (so `evidence_delta:"new"` every round, no
oscillation-guard interference) -- but `severity: null` on every single occurrence, so the claim's
own CANONICAL CURRENT SEVERITY (its most-recent-occurrence severity) is `null` at round 5.

## Mechanics: `--quick` + `FAKE_CODEX_GROUP_STATE`

Identical to `quick-mode-minor-acknowledged` except every scripted round's finding carries
`"severity": null` instead of `"medium"`.

## How to run

```bash
bash codex-stream-review/evals/scenarios/quick-mode-missing-severity-fail-closed/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `FAKE_CODEX_GROUP_STATE`, `FAKE_CODEX_INVOCATION_LOG`. Invoke
`codex-stream-review:ccs` against `REPO_DIR` with:

> --quick review the uncommitted change in this fixture repo

setting `BIN_DIR` on `$PATH` and all three `FAKE_CODEX_*` vars on every dispatch call.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> quick-mode-missing-severity-fail-closed
```

## Expected result

- `exit_state`: `"NOT_CONVERGED"` (never `"MINOR_ISSUES_ACKNOWLEDGED"`)
- `round_count`: `5`
- `FAKE_CODEX_INVOCATION_LOG`: 6 lines (5 dispatches + 1 cleanup delete)
- `claims`: one entry, `claim_id:"f1"`, `severity: null`, `disposition:"open"`
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `coverage`: an object, `status:"complete"`
- `input_errors`: `null`

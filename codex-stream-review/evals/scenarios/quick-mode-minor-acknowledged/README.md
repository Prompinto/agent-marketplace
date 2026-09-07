# Scenario: quick-mode-minor-acknowledged

**Group:** G (quick mode)
**Targets:** `exit_state == "MINOR_ISSUES_ACKNOWLEDGED"`, reached only under `--quick`, at exactly
`round_count == 5` -- the new terminal status added alongside `--quick` (`SKILL.md`'s Guards:
"Quick-mode early stop -- MINOR ISSUES ACKNOWLEDGED").

## Why a false-positive claim, not a real bug

Same technique as `evals/scenarios/not-converged-cap` (see that scenario's own README for the full
rationale): a correct, benign uncommitted addition (`sub(a, b): return a - b`), with
`FAKE_CODEX_GROUP_STATE` scripting 5 distinct final answers (`round-0..round-4-final-answer.json`),
each an `ISSUES` verdict with the SAME `finding_id`/`claim_id` (`f1`) claiming a minor style nit in
`sub()`, each with a DIFFERENT `evidence` string (so a correctly-behaving orchestrator judges
`evidence_delta:"new"` every round and the oscillation guard never fires) -- just 5 rounds instead
of 20, under `--quick`, and severity `"medium"` throughout (never `"high"`/`"critical"`, so
`ESCALATED` never flips and `MAX_ROUNDS` stays `5` for the whole run).

## Mechanics: `--quick` + `FAKE_CODEX_GROUP_STATE`

`FAKE_CODEX_GROUP_STATE` mechanics are identical to `not-converged-cap` -- see
`tests/fixtures/fake-codex`'s own header comment. The only two differences: 5 scripted rounds
instead of 20, and the task text carries the `--quick` prefix (`"--quick review the uncommitted
change in this fixture repo"`), which `SKILL.md` Phase 0 Step 0 strips before treating the
remainder as the TASK, setting `QUICK_MODE` ON and `MAX_ROUNDS = 5` for the whole run.

At round 5 (`R == MAX_ROUNDS`, `ESCALATED` still `false` since severity was never `HIGH`/`CRITICAL`),
`SKILL.md`'s Guards section checks: `K` (still-open claim_ids) `== 1 > 0`, and that claim's own
CANONICAL CURRENT SEVERITY (the `severity` value from its own MOST RECENT occurrence, i.e. round 5's
own finding) is cleanly `"medium"` -- both hold, so the loop stops as
`🟡 MINOR ISSUES ACKNOWLEDGED` rather than falling through to `⚠️ NOT CONVERGED`.

## How to run

```bash
bash codex-stream-review/evals/scenarios/quick-mode-minor-acknowledged/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `FAKE_CODEX_GROUP_STATE`, `FAKE_CODEX_INVOCATION_LOG`. Invoke
`codex-stream-review:ccs` against `REPO_DIR` with:

> --quick review the uncommitted change in this fixture repo

setting `BIN_DIR` on `$PATH` and all three `FAKE_CODEX_*` vars on every dispatch call. The driving
agent must genuinely judge each round's reassertion as `evidence_delta:"new"` and rebut it as a
minor style nit every round (this is real, not scripted, judgment on the driving agent's part).

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> quick-mode-minor-acknowledged
```

## Expected result

- `exit_state`: `"MINOR_ISSUES_ACKNOWLEDGED"`
- `round_count`: `5` (the quick-mode cap, reached without ever escalating)
- `FAKE_CODEX_INVOCATION_LOG`: 6 lines (5 dispatches + 1 cleanup delete)
- `claims`: one entry, `claim_id:"f1"`, `disposition:"open"`, `severity:"medium"` (never closed --
  no `DISPOSITION` marker was ever requested, since `f1` was an actively-disputed,
  currently-appearing finding every round, never silently quiet)
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"` (`FAKE_CODEX_CLEANUP_OK=1` on the
  Phase 3 `--cleanup` call)
- `coverage`: an object, `status:"complete"` (this is `--uncommitted` scope with a tiny, fully
  collected diff)
- `input_errors`: `null`

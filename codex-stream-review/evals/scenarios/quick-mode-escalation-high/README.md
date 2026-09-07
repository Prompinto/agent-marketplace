# Scenario: quick-mode-escalation-high

**Group:** G (quick mode)
**Targets:** a `HIGH`-severity finding under `--quick` permanently escalates `MAX_ROUNDS` from `5`
to `20` (`SKILL.md`'s Phase 2 "Escalation (one-way, permanent)" rule) -- proven structurally by the
loop genuinely dispatching a 6th round, which is only reachable once `MAX_ROUNDS` is no longer `5`.
Also confirms `exit_state` is never `MINOR_ISSUES_ACKNOWLEDGED` for a session where the open claim's
severity is `HIGH` throughout (that branch requires cleanly `LOW`/`MEDIUM`).

## Why round 6, not a real 20-round run

Escalating `MAX_ROUNDS` to `20` doesn't itself force running all 20 rounds -- it only means the
5-round quick cap no longer applies. The cheapest deterministic way to PROVE the escalation
happened, without paying for a real (slow) 20-round session, is to make the loop stop for an
UNRELATED, independently-verifiable reason at round 6 specifically -- one round past where an
un-escalated `--quick` run would have been forced to stop. This scenario uses the per-claim
oscillation guard (`references/claim-ledger.md` section 7) for that: rounds 1-5 script a genuine,
evidence-differing false-positive disagreement (same technique as `not-converged-cap`/
`quick-mode-minor-acknowledged`), then round 6's own scripted evidence string is made IDENTICAL,
byte-for-byte, to round 5's -- `evidence_delta:"none"` since the claim's own most recent prior
occurrence, which is exactly the oscillation guard's trigger. A correctly-behaving orchestrator
therefore stops at round_count 6 with `NOT_CONVERGED`, never reaching round 7 and never needing to.

If `MAX_ROUNDS` had incorrectly stayed `5` (i.e. escalation silently failed to fire off round 1's
`HIGH`-severity finding), the loop would have stopped at round 5 already -- either
`⚠️ NOT CONVERGED` (round_count 5, since severity `"high"` fails the
`MINOR_ISSUES_ACKNOWLEDGED` LOW/MEDIUM test) or, less likely, some other round-5 stop -- but never a
round 6 dispatch at all. `round_count == 6` is therefore the one assertion that structurally
distinguishes "escalation worked" from "escalation silently never fired."

## Mechanics: `--quick` + `FAKE_CODEX_GROUP_STATE`

Same fixture/technique as `not-converged-cap`/`quick-mode-minor-acknowledged` -- see those
scenarios' own READMEs and `tests/fixtures/fake-codex`'s header comment. Task text carries the
`--quick` prefix. 6 rounds are scripted (`round-0..round-5-final-answer.json`); round 5's file
(the 6th dispatch) is the only one with evidence text repeated verbatim from the immediately
preceding round.

## How to run

```bash
bash codex-stream-review/evals/scenarios/quick-mode-escalation-high/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `FAKE_CODEX_GROUP_STATE`, `FAKE_CODEX_INVOCATION_LOG`. Invoke
`codex-stream-review:ccs` against `REPO_DIR` with:

> --quick review the uncommitted change in this fixture repo

setting `BIN_DIR` on `$PATH` and all three `FAKE_CODEX_*` vars on every dispatch call.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> quick-mode-escalation-high
```

## Expected result

- `exit_state`: `"NOT_CONVERGED"` (never `"MINOR_ISSUES_ACKNOWLEDGED"`)
- `round_count`: `6`, strictly greater than `5`
- `FAKE_CODEX_INVOCATION_LOG`: 7 lines (6 dispatches + 1 cleanup delete)
- `claims`: one entry, `claim_id:"f1"`, `disposition:"open"`, `severity:"high"`
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `coverage`: an object, `status:"complete"`
- `input_errors`: `null`

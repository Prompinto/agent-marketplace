# Scenario: not-converged-cap

**Group:** A (terminal-status matrix)
**Targets:** `exit_state == "NOT_CONVERGED"`, reached only by genuinely exhausting all 20 rounds --
never the per-claim oscillation guard (`references/claim-ledger.md` section 7) stopping early for
the same exit_state at a lower round count.

## Why a false-positive claim, not a real bug

The fixture's uncommitted diff is a correct, benign addition (a new `sub(a, b): return a - b`
function) -- deliberately NOT a real bug. `FAKE_CODEX_GROUP_STATE` scripts 20 distinct final
answers (`round-0..round-19-final-answer.json`), each an `ISSUES` verdict with the SAME
`finding_id`/`claim_id` (`f1`) claiming a fake off-by-one in `sub()`, but each with a DIFFERENT
`evidence` string that literally names its own round number (`"observed in round N's own re-read
of line 42"`). This gives a correctly-behaving orchestrator genuine, honest grounds to:

- Judge `evidence_delta:"new"` every single round (the evidence text really is textually different
  each time -- see `references/claim-ledger.md` section 2's definition: "whether this reassertion
  presents any new factual basis versus the claim's own most recent prior occurrence").
- Genuinely rebut the claim as a false positive every round (the diff has no real bug) -- never
  accept/fix anything, which would either converge early (if Codex's script somehow "noticed" the
  fix, which it never does) or, worse, make this scenario's whole premise incoherent.

Because `evidence_delta` is never `"none"`, the oscillation guard (`references/claim-ledger.md`
section 7) never fires -- the loop is forced to run its real, full course to the 20-round cap
(`SKILL.md`'s Guards: "Cap: R = 20 without convergence -> stop, report NOT CONVERGED").

## Mechanics: `FAKE_CODEX_GROUP_STATE`

See `tests/fixtures/fake-codex`'s own header comment for the full mechanism. In short: each
invocation reads a round counter from `$FAKE_CODEX_GROUP_STATE/round` (default 0), uses
`round-<N>-final-answer.json`'s content as this invocation's final answer if present, then
increments the counter for the next invocation. Round 1 (the fresh `--uncommitted` dispatch)
consumes `round-0`; rounds 2-20 (19 `--resume` dispatches) consume `round-1` through `round-19` in
order. `FAKE_CODEX_INVOCATION_LOG` must be set on every one of these 20 dispatch calls, plus the
Phase 3 `--cleanup` call (21 total invocations logged).

## Genuinely long-running

This is a real 20-round conversation against fake-codex -- the ORCHESTRATOR logic between rounds
(snapshot revalidation, claim-ledger judgment, JSONL append+verify) is fully real every round, even
though the reviewer's own responses are scripted. Budget real time accordingly.

## How to run

```bash
bash codex-stream-review/evals/scenarios/not-converged-cap/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `FAKE_CODEX_GROUP_STATE`, `FAKE_CODEX_INVOCATION_LOG`. Invoke
`codex-stream-review:ccs` against `REPO_DIR` with:

> review the uncommitted change in this fixture repo

setting `BIN_DIR` on `$PATH` and all three `FAKE_CODEX_*` vars on every dispatch call. The driving
agent must genuinely judge each round's reassertion as `evidence_delta:"new"` and rebut it as a
false positive every round (this is real, not scripted, judgment on the driving agent's part --
the text really is new every round and the claim really is false).

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> not-converged-cap
```

## Expected result

- `exit_state`: `"NOT_CONVERGED"`
- `round_count`: `20` (the genuine cap, not an early oscillation-guard stop)
- `FAKE_CODEX_INVOCATION_LOG`: 21 lines (20 dispatches + 1 cleanup delete)
- `claims`: one entry, `claim_id:"f1"`, `disposition:"open"` (never closed -- no `DISPOSITION`
  marker was ever requested, since `f1` was an actively-disputed, currently-appearing finding every
  round, never silently quiet)
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"` (`FAKE_CODEX_CLEANUP_OK=1` on the
  Phase 3 `--cleanup` call)
- `coverage`: an object, `status:"complete"` (this is `--uncommitted` scope with a tiny, fully
  collected diff)
- `input_errors`: `null`

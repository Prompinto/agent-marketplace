# Scenario: parallel-live-acceptance

**Group:** Secondary tier (live-Codex acceptance)
**Targets:** a REAL Codex judgment, real parallel dispatch -- not a scripted fake-codex transcript.
Uses the REAL `codex` CLI (no fake-codex PATH injection) and costs real API time.

A tiny 2-file fixture, one file per dimensional group, each with ONE independently-verifiable,
objective defect stated as a documented local requirement in a comment immediately above the code
that violates it:

- `file_a.py`: `clamp_nonnegative()` has a comment requiring it to raise `ValueError` for negative
  input; it actually returns `abs(x)` instead.
- `file_b.py`: `authenticate()` has a comment requiring it to never log the raw password; it
  actually logs it directly via `logging.info(...)`.

## Sizing judgment call (flagged per this task's own instructions)

A 2-file diff is well inside `parallel-mode.md`'s own "<20 files -> single reviewer" tier by raw
file count. Parallel dispatch is used here anyway under that same reference's "flexible judgment"
carve-out (distinct concerns worth distinct reviewer attention) specifically to exercise real
concurrent multi-group dispatch and convergence against a real Codex backend -- this is not
evidence that a 2-file diff should normally trigger parallel mode.

## How to run

```bash
bash codex-stream-review/evals/scenarios/parallel-live-acceptance/setup.sh
```

Then invoke `codex-stream-review:ccs` against the printed `REPO_DIR` with the REAL `codex` CLI on
`$PATH` (no fake-codex injection):

> review the uncommitted change in this fixture repo

Dispatch 2 parallel groups: `g1`'s `--focus` emphasizes correctness (should find `file_a.py`'s
violated requirement), `g2`'s emphasizes security (should find `file_b.py`'s). Both groups review
the identical full 2-file diff. This is a genuine, unscripted Codex judgment call -- follow
SKILL.md's real Phase 1/2/3 procedure: verify each real finding by reading the file, fix each real
defect for real, request disposition confirmations per `references/claim-ledger.md`, and let the
session converge (or genuinely fail to) on its own. Do not assume in advance which round it
converges on or the exact wording of any finding.

```bash
bash codex-stream-review/evals/check-result.sh <result.json> parallel-live-acceptance
```

## Expected result

A genuine semantic terminal state -- `CLEAN` (both real defects found, fixed, confirmed resolved)
or `NOT_CONVERGED` (a real, evidence-based disagreement survives) are both acceptable outcomes.
`COULD_NOT_VERIFY`, `PARTIAL_COVERAGE`, or either integrity-failure state are explicit scenario
FAILURES to debug -- they mean the scenario broke operationally, not that it validated real
judgment. No exact round count or finding wording is ever asserted. `threads`: exactly 2 entries
(one per group), all `cleanup:"deleted"` (real threads, really cleaned up). `claims`: non-empty
(the two planted defects were genuinely found and tracked).

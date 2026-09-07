# Scenario: parallel-group-namespaced-claims

**Group:** E (parallel-mode)
**Targets:** two groups each raise their own, independently-numbered finding `"f1"` -- confirms
Claude's own claim_id bookkeeping group-prefixes them (`g1:f1`, `g2:f1`, per
`references/claim-ledger.md` sections 1/9) so identical raw per-group numbering never collides,
both independently reaching `disposition:"resolved"` via their own `DISPOSITION` marker in round 2.

`g1`'s finding is the fixture's real off-by-one bug in `lib.py` (correctness). `g2`'s finding is a
fabricated-but-plausible reuse/intent finding about `stub_1.py` lacking a docstring --
independently, trivially fixable, so both groups get a real fix without touching the same file.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH`. Bind `FAKE_CODEX_GROUP_STATE` inline, per-command, to
`G1_STATE` on `g1`'s own dispatch lines and `G2_STATE` on `g2`'s own dispatch lines -- never a
shared `export` mutated between the two concurrent background dispatches (see
`tests/fixtures/fake-codex`'s own doc comment). Same discipline for `FAKE_CODEX_INVOCATION_LOG`.
`FAKE_CODEX_SCENARIO=normal` must also be set on every dispatch call.

## How to run

```bash
bash codex-stream-review/evals/scenarios/parallel-group-namespaced-claims/setup.sh
```

Then invoke `codex-stream-review:ccs` against the printed `REPO_DIR` with:

> review the uncommitted change in this fixture repo

Dispatch 2 parallel groups (`g1` correctness, `g2` reuse/intent).

1. **Round 1** (both concurrently): `g1` gets `ISSUES` with a finding it numbers `"f1"` internally
   (the real `lib.py` off-by-one); `g2` gets `ISSUES` with its OWN, independently-numbered `"f1"`
   (`stub_1.py`'s missing docstring) -- same raw id, different groups, different defects. Claude
   assigns `claim_id "g1:f1"` and `"g2:f1"` respectively.
2. Claude applies a real fix for each: removes `lib.py`'s `+ 1`, adds a one-line docstring to
   `stub_1.py`.
3. Per "When to ask" condition (b), each group's own round-2 focus names ITS OWN full claim_id
   (`"g1:f1"` within g1's own thread, `"g2:f1"` within g2's own) and requests a disposition
   confirmation -- a group's own Codex thread only ever sees requests framed in its own focus text.
4. **Round 2** (both `--resume`, concurrently): `g1` responds `CLEAN` with `DISPOSITION g1:f1:
   RESOLVED -- ...`; `g2` responds `CLEAN` with `DISPOSITION g2:f1: RESOLVED -- ...`. Both parse
   validly via known-id-first matching (required specifically because a parallel-mode `claim_id`
   itself contains a colon).
5. Convergence: both groups' round-2 findings are empty and both claims now have a terminal
   disposition -> `exit_state CLEAN`.

Set `FAKE_CODEX_CLEANUP_OK=1` on both Phase 3 `--cleanup` calls.

```bash
bash codex-stream-review/evals/check-result.sh <result.json> parallel-group-namespaced-claims
```

## Expected result

- `exit_state`: `"CLEAN"`
- `round_count`: `2`
- `threads`: two entries (one per group), both `kind:"current"`, `cleanup:"deleted"`
- `claims`: two entries -- `{"claim_id":"g1:f1","disposition":"resolved","source_round":2,...}` and
  `{"claim_id":"g2:f1","disposition":"resolved","source_round":2,...}` -- never colliding
- `coverage`: an object, `status:"complete"`
- `input_errors`: `null`

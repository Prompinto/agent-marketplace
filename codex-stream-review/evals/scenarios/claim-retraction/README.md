# Scenario: claim-retraction

**Group:** F (claim-ledger end-to-end)
**Targets:** raise (round 1) -> rebut with no code fix (round 2) -> Codex goes quiet on it ->
Claude explicitly requests a disposition (round 3) -> `DISPOSITION <id>: RETRACTED` -> `exit_state
CLEAN`.

**Three rounds, not two.** See `setup.sh`'s own header comment for the full reasoning:
`references/claim-ledger.md` section 4's "When to ask" rule only permits a disposition request
when, relative to the MOST RECENTLY COMPLETED round, a claim either (a) did not appear in that
round's own findings, or (b) Claude just applied a fix in direct response to it. A pure rebuttal
satisfies neither at round 2 (the claim just appeared in round 1, and no fix was applied) -- only
once round 2 completes without re-mentioning the claim does condition (a) become true for round 3.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"), plus
`FAKE_CODEX_GROUP_STATE=<the directory setup.sh printed>` and `FAKE_CODEX_SCENARIO=normal` set on
every dispatch call (fresh round 1, and both `--resume` calls for rounds 2 and 3).

## How to run

```bash
bash codex-stream-review/evals/scenarios/claim-retraction/setup.sh
```

Prints `REPO_DIR` (a fixture whose uncommitted change appends a small, CORRECT `clamp()` helper to
`lib.py` -- deliberately not `eval_make_fixture_repo`'s own real-bug fixture, since this scenario
needs a FALSE-POSITIVE finding Claude can legitimately reject), `BIN_DIR`, `GROUP_STATE_DIR`. Then
invoke `codex-stream-review:ccs` against `REPO_DIR` with:

> review the uncommitted change in this fixture repo

1. **Round 1**: `ISSUES`, finding `f1` claims `clamp()` needs a `lo<=hi` precondition check. Claude
   re-verifies: `clamp()` is a private two-line helper with no external callers in this fixture and
   matches `add()`'s own zero-input-validation convention -- `REJECT_WITH_RATIONALE`, no code
   change.
2. Round 2's own focus recaps the rebuttal as normal History -- per "When to ask," no disposition
   is requested yet (the claim did appear in round 1, no fix was applied).
3. **Round 2**: `CLEAN`, `findings:[]`, `f1` not mentioned at all.
4. Per "When to ask" condition (a) (`f1` is open and absent from round 2's own findings), round 3's
   own focus must now explicitly name `f1` and request a `DISPOSITION` marker.
5. **Round 3**: `CLEAN` whose `summary` carries `DISPOSITION f1: RETRACTED -- ...`. Claude's parser
   validates it -> `claim_closures: [{"claim_id":"f1","disposition":"retracted","source_round":3,...}]`.
6. Convergence: round 3's findings are empty and `f1` now has a terminal disposition -> `exit_state
   CLEAN`.

Set `FAKE_CODEX_CLEANUP_OK=1` on the Phase 3 `--cleanup` call.

```bash
bash codex-stream-review/evals/check-result.sh <result.json> claim-retraction
```

## Expected result

- `exit_state`: `"CLEAN"`
- `round_count`: `3`
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `claims`: one entry -- `{"claim_id":"f1","disposition":"retracted","source_round":3,...}`
- `coverage`: an object, `status:"complete"`
- `input_errors`: `null`

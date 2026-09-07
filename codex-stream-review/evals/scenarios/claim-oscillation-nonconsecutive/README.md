# Scenario: claim-oscillation-nonconsecutive

**Group:** F (claim-ledger end-to-end)
**Targets:** `references/claim-ledger.md` section 7's oscillation guard, scoped PER-CLAIM (not
"the last two rounds"). A claim raised in round 1, silent in round 2, reasserted with NO NEW
EVIDENCE in round 3 must be caught -- the OLD "zero progress twice in a row" guard this section
replaced only ever compared adjacent rounds and would have missed this exact non-consecutive
pattern.

No `DISPOSITION` marker appears anywhere in this transcript. Round 3's own focus DOES request one
(per the "When to ask" rule, once the claim goes absent from round 2), but the scripted round-3
response deliberately reasserts the finding as an ordinary finding instead of answering with a
marker -- demonstrating the oscillation guard fires purely off Claude's own `evidence_delta`
judgment during the normal per-finding verification pass, independent of marker compliance.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call, plus
`FAKE_CODEX_GROUP_STATE=<the directory setup.sh printed>` and `FAKE_CODEX_SCENARIO=normal` set on
every dispatch call (fresh round 1, `--resume` rounds 2 and 3).

## How to run

```bash
bash codex-stream-review/evals/scenarios/claim-oscillation-nonconsecutive/setup.sh
```

Then invoke `codex-stream-review:ccs` against the printed `REPO_DIR` with:

> review the uncommitted change in this fixture repo

Do **not** fix `lib.py`'s real off-by-one at any point in this run -- the whole point is that
Codex's own evidence about it never changes across its three appearances.

1. **Round 1**: `ISSUES`, finding `f1` (the fixture's real off-by-one). Claude judges it valid but
   defers the fix (`parked`/accept-fix-pending) -- no code change this round.
2. Round 2's own focus recaps "`f1` acknowledged, addressing separately" as normal History -- no
   disposition requested (`f1` appeared in round 1, no fix applied).
3. **Round 2**: `CLEAN`, `findings:[]` -- Codex goes silent on `f1`.
4. Per "When to ask" condition (a) (`f1` absent from round 2's own findings), round 3's own focus
   DOES request a `DISPOSITION` marker for `f1`.
5. **Round 3**: `ISSUES`, reasserting the IDENTICAL `f1` finding (same file/line/summary/evidence,
   verbatim) -- no `DISPOSITION` marker in the response.
6. Claude's verification pass: same claim (`claim_id "f1"`), evidence identical to its own most
   recent prior occurrence (round 1's) -> `evidence_delta: "none"`.
7. The moment an open claim is reasserted with `evidence_delta: "none"` since its own most recent
   prior occurrence -- regardless of how many other rounds intervened -- the run stops early:
   `NOT CONVERGED`.

Set `FAKE_CODEX_CLEANUP_OK=1` on the Phase 3 `--cleanup` call.

```bash
bash codex-stream-review/evals/check-result.sh <result.json> claim-oscillation-nonconsecutive
```

## Expected result

- `exit_state`: `"NOT_CONVERGED"`
- `round_count`: `3`
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `claims`: one entry -- `{"claim_id":"f1","disposition":"open","source_round":null,"marker_reason":null}`
- `coverage`: an object, `status:"complete"`
- `input_errors`: `null`

# Scenario: claim-still-open-marker

**Group:** F (claim-ledger end-to-end)
**Targets:** a valid `DISPOSITION <id>: STILL OPEN -- <reason>` marker (`references/claim-ledger.md`
section 4) produces **no** `claim_closures[]` entry -- the claim stays `open`, never silently
treated as resolved just because a marker line existed.

Round 1 raises `f1` (the fixture's real off-by-one). Claude applies a real but **genuinely
insufficient** fix (adds a clarifying comment, does not remove the actual `+ 1`) -- a real code
edit in direct response to round 1's finding, which justifies round 2's focus requesting a
disposition confirmation (claim-ledger.md's "When to ask" condition (b)). Round 2's scripted
response reasserts `f1` (the underlying defect/evidence is unchanged) and answers with `DISPOSITION
f1: STILL OPEN -- ...`. This simultaneously fires the oscillation guard (adjacent-round reassertion
with `evidence_delta: "none"`) AND demonstrates `STILL OPEN`'s own no-closure rule -- both
independently keep the claim `open`.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call, plus
`FAKE_CODEX_GROUP_STATE=<the directory setup.sh printed>` and `FAKE_CODEX_SCENARIO=normal` set on
every dispatch call (fresh round 1, `--resume` round 2).

## How to run

```bash
bash codex-stream-review/evals/scenarios/claim-still-open-marker/setup.sh
```

Then invoke `codex-stream-review:ccs` against the printed `REPO_DIR` with:

> review the uncommitted change in this fixture repo

1. **Round 1**: `ISSUES`, finding `f1` (the real off-by-one). Claude applies a real but
   insufficient fix -- adds a clarifying comment above the return statement, does NOT remove the
   `+ 1` -- and round 2's own focus explicitly names `f1` and requests a disposition confirmation.
2. **Round 2**: `ISSUES`, reasserting `f1` with evidence unchanged from round 1 (only a comment was
   added), plus `DISPOSITION f1: STILL OPEN -- ...` in the summary.
3. Claude's verification pass: same claim (`f1`), evidence identical to its own most recent prior
   occurrence -> `evidence_delta: "none"`. This both fires the oscillation guard (adjacent-round
   reassertion, no new evidence -> `NOT_CONVERGED`) and demonstrates `STILL OPEN` produces no
   `claim_closures[]` entry either way -- the claim's `disposition` stays `"open"`.

Set `FAKE_CODEX_CLEANUP_OK=1` on the Phase 3 `--cleanup` call.

```bash
bash codex-stream-review/evals/check-result.sh <result.json> claim-still-open-marker
```

## Expected result

- `exit_state`: NOT `"CLEAN"` (expected `"NOT_CONVERGED"`)
- `round_count`: `2`
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `claims`: one entry -- `{"claim_id":"f1","disposition":"open","source_round":null,"marker_reason":null}`
- `coverage`: an object, `status:"complete"`
- `input_errors`: `null`

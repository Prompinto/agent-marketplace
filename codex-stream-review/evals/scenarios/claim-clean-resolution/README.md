# Scenario: claim-clean-resolution

**Group:** F (claim-ledger end-to-end)
**Targets:** the claim ledger's happy path -- raise (round 1) -> Claude applies a real fix ->
`DISPOSITION <id>: RESOLVED` marker (round 2) -> `exit_state CLEAN`.

Single-reviewer (`GROUP="main"`). Uses `FAKE_CODEX_GROUP_STATE` (see
`tests/fixtures/fake-codex`'s own header comment) to script a two-round transcript played back
across two separate real dispatch invocations: round 1 raises a real finding (the fixture's own
off-by-one bug), round 2 confirms it resolved via a `DISPOSITION` marker matching
`references/claim-ledger.md` section 4's CURRENT grammar (column-zero, `--` separator, non-empty
reason).

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). Additionally,
`FAKE_CODEX_GROUP_STATE=<the directory setup.sh printed>` must be set on EVERY dispatch call
(fresh round 1 and the round-2 `--resume` call) -- each is its own separate process invocation, and
this directory (holding an auto-incrementing counter file plus `round-0-final-answer.json`/
`round-1-final-answer.json`) is the only persistence mechanism across them.
`FAKE_CODEX_SCENARIO=normal` (fake-codex's own default) must also be set explicitly on every
dispatch call -- the `GROUP_STATE` override is only consulted inside that scenario's own branch.

## How to run

```bash
bash codex-stream-review/evals/scenarios/claim-clean-resolution/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `GROUP_STATE_DIR`. Then invoke `codex-stream-review:ccs` against
`REPO_DIR` with:

> review the uncommitted change in this fixture repo

1. **Round 1** (fresh `--uncommitted`): fake-codex plays back `round-0-final-answer.json` -- an
   `ISSUES` verdict with one finding `f1` describing the fixture's real off-by-one bug in `lib.py`
   (`return a + b + 1`). Claude re-verifies against the real file, judges it VALID, and **actually
   edits `REPO_DIR/lib.py`** to remove the `+ 1` -- a real fix, not simulated.
2. Per `references/claim-ledger.md`'s "When to ask" condition (b) (a fix was just applied in direct
   response to round 1's finding), round 2's own History text must explicitly name claim_id `f1`
   and request a `DISPOSITION f1: RESOLVED|RETRACTED|STILL OPEN -- <reason>` marker for THIS
   round's response.
3. **Round 2** (`--resume`): fake-codex plays back `round-1-final-answer.json` -- a `CLEAN` verdict
   whose `summary` carries `DISPOSITION f1: RESOLVED -- lib.py now reads 'return a + b', ...`.
   Claude's parser validates it (column-zero, exactly one marker for the one requested claim_id,
   `--` separator, non-empty reason) and records
   `claim_closures: [{"claim_id":"f1","disposition":"resolved","source_round":2,"marker_reason":"..."}]`.
4. Convergence: round 2's own findings are empty, and the only claim ever raised (`f1`) now has a
   terminal disposition -> `exit_state CLEAN`.

Set `FAKE_CODEX_CLEANUP_OK=1` on the Phase 3 `--cleanup` call.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> claim-clean-resolution
```

## Expected result

- `exit_state`: `"CLEAN"`
- `round_count`: `2`
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `claims`: one entry -- `{"claim_id":"f1","disposition":"resolved","source_round":2,...}`
- `coverage`: an object, `status:"complete"` (this is `--uncommitted` scope, no omissions in this
  fixture)
- `input_errors`: `null`

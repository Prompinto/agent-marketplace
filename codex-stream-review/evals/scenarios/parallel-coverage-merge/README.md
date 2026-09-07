# Scenario: parallel-coverage-merge

**Group:** E (parallel-mode)
**Targets:** `references/parallel-mode.md`'s round-1 N-group coverage merge -- `"complete"` only if
EVERY dispatched group's own status was `"complete"`, else `"partial"` -- forced for real (never
fabricated) so one group genuinely reports `"partial"` and the other genuinely reports
`"complete"`.

## Judgment call (flagged per this task's own instructions)

`run-ccs-review.sh` has no file-filter flag, and every group in a parallel round reviews the
IDENTICAL full diff/untracked-file state of the SAME `REPO_ROOT` at dispatch time -- there is
structurally no way for two groups dispatched against a genuinely identical, *simultaneous* repo
state to observe different real `coverage.source` outcomes; the splice is deterministic given the
same on-disk state. The sibling `partial-coverage` scenario (Group A) forces a real `"partial"`
outcome via one untracked file over `collect_untracked_files.py`'s own 1MiB `DEFAULT_MAX_BYTES` cap
(coverage reason `"over_size_limit"`) -- this scenario reuses that SAME real mechanism, but must
additionally desynchronize the two groups' observed repo state to get one `"partial"` and one
`"complete"` reading: **`g1` is dispatched first**, while the oversized untracked file is still
present (real `"partial"`); once `g1`'s own round-1 attempt has returned, the oversized file is
deleted, and only then is `g2` dispatched (real `"complete"`). This is a deliberate divergence from
`parallel-mode.md`'s own "every group reviews the identical diff" description of ordinary
parallel-mode use -- constructed here purely to exercise the orchestrator's own merge-computation
logic with two REAL (not synthesized) `coverage_source` values that happen to differ. Sequential,
not concurrent, dispatch is therefore correct for this one scenario only.

## How to run

```bash
bash codex-stream-review/evals/scenarios/parallel-coverage-merge/setup.sh
```

Then invoke `codex-stream-review:ccs` against the printed `REPO_DIR` with:

> review the uncommitted change in this fixture repo

Dispatch 2 parallel groups, but **sequentially, not concurrently, for this one scenario only**:

1. Dispatch `g1` first (`--uncommitted`), with `oversized-untracked.bin` still present. `g1`
   returns `CLEAN`/`findings:[]` with `coverage.source.status:"partial"`
   (`omitted:[{"path":"oversized-untracked.bin","reason":"over_size_limit"}]`). Capture it.
2. Once `g1` has returned, delete `REPO_DIR/oversized-untracked.bin`.
3. Dispatch `g2` only now, with the oversized file already gone. `g2` returns
   `CLEAN`/`findings:[]` with `coverage.source.status:"complete"`. Capture it.
4. Round-1 N-group merge: `g1`'s was `"partial"`, so the merged `coverage_source.status` is
   `"partial"`, with `omitted` set to `g1`'s own omitted list.
5. Per SKILL.md's Guards, even though both groups' own verdicts were individually clean, this round
   is NOT eligible for `CLEAN`: stop and report `exit_state PARTIAL_COVERAGE`.

Set `FAKE_CODEX_CLEANUP_OK=1` on both Phase 3 `--cleanup` calls.

```bash
bash codex-stream-review/evals/check-result.sh <result.json> parallel-coverage-merge
```

## Expected result

- `exit_state`: `"PARTIAL_COVERAGE"`
- `round_count`: `1`
- `threads`: two entries (one per group), both `kind:"current"`, `cleanup:"deleted"`
- `claims`: `[]`
- `coverage`: `{"status":"partial","omitted":[{"path":"oversized-untracked.bin","reason":"over_size_limit"}],...}`
  (worst-case-wins merge)
- `input_errors`: `null`

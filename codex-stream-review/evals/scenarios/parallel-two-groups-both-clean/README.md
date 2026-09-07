# Scenario: parallel-two-groups-both-clean

**Group:** E (parallel-mode)
**Targets:** the baseline parallel-mode dispatch -- a diff sized to trigger
`references/parallel-mode.md`'s "Medium (20-50 files) -> 2-3 parallel groups" tier, both groups
converge `CLEAN` on round 1.

**Sizing judgment call (flagged per this task's own instructions):** `parallel-mode.md`'s table
gives ranges, not one exact byte/file-count constant to grep for -- the sizing decision is Claude's
own judgment call at Phase 1's "Determine review mode" step, not a hardcoded script constant. This
fixture uses 24 total changed files (`eval_make_fixture_repo_sized`'s own default: 1 tracked
modification + 23 new untracked files), comfortably inside the 20-50 "medium" band; the driving
agent then picks 2 groups (the low end of "2-3" for a single-concern diff).

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call. **Parallel-mode-specific:** per
`tests/fixtures/fake-codex`'s own `FAKE_CODEX_GROUP_STATE`/`FAKE_CODEX_INVOCATION_LOG` doc
comments, each group's own dispatch line needs its own INLINE env-var prefix, never a shared
`export` mutated between the two concurrent background dispatch launches. This scenario needs no
`FAKE_CODEX_GROUP_STATE` scripting at all (both groups converge clean on fake-codex's own default
response), but still gives each group its own `FAKE_CODEX_INVOCATION_LOG` file for the driving
agent's own sanity-check that each group's dispatch actually went through the fake binary the
expected number of times.

## How to run

```bash
bash codex-stream-review/evals/scenarios/parallel-two-groups-both-clean/setup.sh
```

Then invoke `codex-stream-review:ccs` against the printed `REPO_DIR` with:

> review the uncommitted change in this fixture repo

SKILL.md's Phase 1 sizing count lands in the "medium" tier -> dispatch 2 parallel groups (`g1`,
`g2`) this round, each with its own dimensional `--focus` (e.g. correctness vs. security/reuse) but
reviewing the IDENTICAL full diff, both issued as concurrently-backgrounded Bash calls in the same
turn. Both return fake-codex's own default `CLEAN`/`findings:[]` verdict on round 1.

Set `FAKE_CODEX_CLEANUP_OK=1` on both Phase 3 `--cleanup` calls.

```bash
bash codex-stream-review/evals/check-result.sh <result.json> parallel-two-groups-both-clean
```

## Expected result

- `exit_state`: `"CLEAN"`
- `round_count`: `1`
- `threads`: exactly 2 entries (one per group), both `kind:"current"`, `cleanup:"deleted"`
- `claims`: `[]`
- `coverage`: an object, `status:"complete"` (round-1 N-group merge, both groups complete)
- `input_errors`: `null`

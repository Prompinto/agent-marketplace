# Scenario: compact-byte-budget-exceeded

**Group:** H (`compaction.md` opt-in-feature coverage, same group as
`compact-trigger-uncommitted-success` and `compact-baseline-still-over-threshold` -- Groups A-G
are already taken by other suites, see `codex-stream-review/evals/README.md`'s scenario index).

**Targets:** `references/compaction.md`'s "Byte-budget preflight" — the ONLY compaction-failure
path that is a purely LOCAL, pre-dispatch check with no real wrapper call for the failed attempt
at all. Confirms: (1) `compaction_disabled_reason: "byte_budget_exceeded"` is latched without a
fresh dispatch ever occurring; (2) `compaction_attempt_failure_count` is NOT incremented for this
specific cause (it has its own dedicated, immediate latch — see "Trigger"'s circuit-breaker
section); (3) the final `threads[]` array has exactly ONE entry (the original thread, never
replaced) with no `"kind":"leaked"` entry at all, since no second thread was ever created.

## Mechanical setup

Round 1's own finding carries a deliberately huge (~130,000-byte) `evidence` field so the open-
claim section of `COMPACT_DIGEST` alone exceeds `COMPACT_BYTE_BUDGET` (120,000 bytes) —
`FAKE_CODEX_FINAL_ANSWER` is set to a pre-built JSON verdict string containing this finding,
`FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,...}'` (over threshold, triggering compaction).
Round 2's real (fallback) dispatch is an ordinary `--resume` with
`FAKE_CODEX_USAGE_JSON='{"input_tokens":200000,...}'` and a `DISPOSITION ... RESOLVED` marker
closing round 1's huge finding. `--cleanup` needs `FAKE_CODEX_CLEANUP_OK=1`.
`FAKE_CODEX_INVOCATION_LOG` set on every call.

## How to run

```bash
bash codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/setup.sh
```

Then invoke `codex-stream-review:ccs --compact` against `REPO_DIR`, task text:

> --compact review the uncommitted change in this fixture repo

```bash
bash codex-stream-review/evals/check-result.sh <result.json> compact-byte-budget-exceeded
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `2`
- `threads`: exactly ONE entry, `kind: "current"`, `cleanup: "deleted"` — no `"leaked"` entry.
- Invocation log: exactly 1 `mode=fresh` line (round 1), exactly 1 `mode=resume` line (round 2's
  fallback) — proving the compaction ATTEMPT itself never reached a real dispatch. `expect.sh`
  also cross-references the specific IDs, not merely "the right counts exist": the single
  `mode=resume` line's own `thread_id` must equal the single `mode=fresh` line's own `thread_id`,
  which must ALSO equal the one `threads[0].thread_id` — proving round 2's fallback genuinely
  resumed the SAME thread A that round 1 opened, never a different or newly-minted thread.
- The session's own `.jsonl` log (located as `<result.json>`'s sibling, same `<session-id>`
  basename — the same lookup `compact-baseline-still-over-threshold/expect.sh` already uses):
  `expect.sh` mechanically asserts round 1's own line does NOT carry `compaction_disabled_reason`
  (never mis-attributed to the triggering round), round 2's own line carries
  `"compaction_disabled_reason":"byte_budget_exceeded"`, and round 2's own line carries NEITHER
  `compaction_attempt_failure_count` (this cause has its own dedicated, immediate latch and
  deliberately never increments that counter) NOR `compacted_from_thread` (no candidate was ever
  promoted — the compaction attempt never dispatched at all). This is the mechanically-checked
  proof of the actual CAUSE and its NEGATIVE claim (no real dispatch, no candidate promotion), not
  just the downstream dispatch-pattern effect the invocation-log/thread checks above establish.

# Scenario: compact-baseline-still-over-threshold

**Group:** H (`compaction.md` opt-in-feature coverage, same group as
`compact-trigger-uncommitted-success` -- Groups A-G are already taken by other suites, see
`codex-stream-review/evals/README.md`'s scenario index).

**Targets:** `references/compaction.md`'s "Benefit-free-restart-loop guard" — a compaction
round's own freshly-restarted `execution.usage.input_tokens` is ALSO `>= COMPACT_THRESHOLD`,
proving the underlying content itself (not accumulated resumed-thread history) is intrinsically
large. Confirms `compaction_disabled_reason: "baseline_at_or_above_threshold"` is latched on the
compaction round's own line, AND that a LATER round's own high usage (round 3, also over
threshold) does NOT trigger a second compaction attempt — the trigger check must no-op
immediately once disabled, per the durable-latch contract.

## Mechanical setup

Round 1: `FAKE_CODEX_SCENARIO=normal`, one low-severity finding,
`FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}'`. Round 2 (compaction):
`FAKE_CODEX_SCENARIO=normal`, a `DISPOSITION ... RESOLVED` marker for round 1's claim plus one
NEW low-severity finding, `FAKE_CODEX_USAGE_JSON='{"input_tokens":8500000,
"output_tokens":50000}'` (itself over threshold). Round 3 (ordinary resume, never a second
compaction): `FAKE_CODEX_SCENARIO=normal`, a `DISPOSITION ... RESOLVED` marker for round 2's new
claim, `FAKE_CODEX_USAGE_JSON='{"input_tokens":8700000,"output_tokens":40000}'` (also over
threshold, deliberately, to prove no second attempt happens). Both `--cleanup` calls need
`FAKE_CODEX_CLEANUP_OK=1`. `FAKE_CODEX_INVOCATION_LOG` set on every call.

## How to run

```bash
bash codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/setup.sh
```

Then invoke `codex-stream-review:ccs --compact` against `REPO_DIR`, task text:

> --compact review the uncommitted change in this fixture repo

```bash
bash codex-stream-review/evals/check-result.sh <result.json> compact-baseline-still-over-threshold
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `3`
- `threads`: current = B (round 2's new thread), leaked = A (round 1's abandoned thread), both
  `cleanup: "deleted"`
- Invocation log: exactly 2 `mode=fresh` lines, exactly 1 `mode=resume` line (round 3, against
  B) — proving round 3 never attempted a second compaction dispatch.
- `expect.sh` also cross-references the specific IDs, not merely "the right counts exist":
  `leaked` must equal the FIRST fresh dispatch's `thread_id` (A) and `current` must equal the
  SECOND (B); AND the single `mode=resume` line's own `thread_id` must ALSO equal `current` (B)
  — proving round 3 genuinely resumed the SAME thread the compaction round promoted, not thread
  A, and not some third, newly-minted thread. This is the specific causal link the guard claims:
  the round whose own baseline latched the guard (round 2, thread B) is the SAME thread every
  later round keeps resuming, never a fresh restart again.
- The session's own `.jsonl` log (located as `<result.json>`'s sibling, same `<session-id>`
  basename — the same lookup `flags-capture-only/expect.sh` already uses): `expect.sh`
  mechanically asserts round 1's own line does NOT carry `compaction_disabled_reason` (never
  mis-attributed to the TRIGGERING round), round 2's own line carries
  `"compaction_disabled_reason":"baseline_at_or_above_threshold"` (the compaction round's OWN
  baseline is what latched it), and round 3's own line carries neither
  `compaction_disabled_reason` (read forward, never re-recorded) nor
  `compacted_from_thread`/`candidate_snapshot_path` (no second compaction attempt was made, local
  re-collection included, not merely no second network dispatch). This is the mechanically-checked
  proof of the actual CAUSE (round 2's own over-threshold baseline), not just the downstream
  dispatch-pattern effect the invocation-log/thread checks above establish.

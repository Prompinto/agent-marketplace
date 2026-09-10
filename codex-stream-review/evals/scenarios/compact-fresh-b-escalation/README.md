# Scenario: compact-fresh-b-escalation

**Group:** H (`compaction.md` opt-in-feature coverage) -- the MOST COMPLEX of the compaction
scenarios: the compaction analogue of `retry-exhausted-round1-fresh-fallback`, extended to
compaction's own three-thread shape (the pre-compaction OLD thread, exhausted candidate A,
successful candidate B) instead of that scenario's two.

**Targets:** `references/compaction.md`'s "Retry topology" section's bullet-3 ordinary
escalation -- candidate A's own fresh dispatch captures a real threadId, both of its bounded
`--resume` retries are exhausted (3 consecutive failures total), then the fresh-B escalation
dispatches ONE new, single, unretried attempt as thread B, which succeeds. Confirms
`compaction_attempt_failed_thread` is recorded as the array `[A]` (never `[B]`, never `[A, B]`,
never including the pre-existing OLD thread), `compaction_attempt_execution` preserves A's own 3
failed attempts' telemetry, and Phase 3 cleanup reaches BOTH abandoned threads -- OLD (via
`compacted_from_thread`) AND A (via `compaction_attempt_failed_thread`) -- never leaving either
permanently unaccounted-for.

## How this differs from `retry-exhausted-round1-fresh-fallback`

That scenario has ONE pre-existing thread that itself exhausts its own retries and falls back to
a fresh retry. Here, the thread that exhausts its retries (candidate A) is itself a NEW thread
created for a compaction attempt -- the pre-existing OLD thread (round 1's own thread) is never
touched by A's retry sequence at all; it sits untouched until B's eventual success promotes the
snapshot and OLD is separately moved to `LEAKED_THREAD_IDS` via `compacted_from_thread`. Three
distinct threads (OLD, A, B) must each be individually accounted for, not just "two distinct IDs
somewhere."

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run. Round 1's dispatch
needs `FAKE_CODEX_SCENARIO=normal` and `FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,
"output_tokens":50000}'` (over `COMPACT_THRESHOLD`, triggering compaction for round 2).
Candidate A's fresh dispatch and both of its bounded resume retries all need
`FAKE_CODEX_SCENARIO=exit_nonzero` (3 consecutive failures, exhausting A). Thread B's fresh
dispatch needs `FAKE_CODEX_SCENARIO=normal` and `FAKE_CODEX_USAGE_JSON='{"input_tokens":400000,
"output_tokens":20000}'` (comfortably under threshold, so no circuit breaker engages). All three
`--cleanup` calls (B, OLD, A) need `FAKE_CODEX_CLEANUP_OK=1`. `FAKE_CODEX_INVOCATION_LOG` must be
set to the fixed path `setup.sh` prints on every call.

Unlike the simplest compaction scenarios, this invocation-log check is NOT best-effort here: this
is a controlled synthetic run (`setup.sh` creates the log deterministically), so a missing log
means the fixture harness itself is broken and `expect.sh` FAILS outright, matching the
convention `compact-baseline-still-over-threshold` and `compact-byte-budget-exceeded` already
established for scenarios whose own JSONL-linkage checks need this log to identify which real
`thread_id` is which -- this scenario needs it even more than either of those, since without it
OLD/A/B can never be told apart at all.

## How to run

```bash
bash codex-stream-review/evals/scenarios/compact-fresh-b-escalation/setup.sh
```

Then invoke `codex-stream-review:ccs --compact` against `REPO_DIR` with the task text:

> --compact review the uncommitted change in this fixture repo

Sequence:

1. **Round 1**: fresh `--uncommitted`, `normal` -- CLEAN verdict, real `threadId` (`OLD`)
   captured. `input_tokens` (9,000,000) is `>= COMPACT_THRESHOLD` -- triggers compaction for
   round 2.
2. **Round 2 (COMPACTION round), candidate A's own attempt sequence**:
   a. Fresh `--uncommitted` dispatch (candidate A), `exit_nonzero` -- real `threadId` (`A`)
      captured despite the failure.
   b. **Wait 5s**, `--resume A --timeout 300`, `exit_nonzero` -- fails the same way.
   c. **Wait 15s**, `--resume A --timeout 300`, `exit_nonzero` -- fails the same way. Both
      bounded resume retries now exhausted (bullet 3's ordinary escalation).
   d. **Fresh-B escalation**: dispatch thread B fresh (`--uncommitted`), abandoning A --
      `compaction_attempt_failed_thread=[A]`. `normal`, `input_tokens=400000` -- SUCCEEDS, CLEAN
      verdict, new real `threadId` (`B`).
3. **Ordering on success**: B is added to `LEAKED_THREAD_IDS` provisionally, round 2's JSONL line
   is appended (`compacted_from_thread=OLD`, `compaction_attempt_failed_thread=[A]`,
   `compaction_attempt_execution`=A's 3 failed attempts, `compaction_attempt_failure_count=0`),
   append-verify passes, promotion succeeds. B becomes the new `GROUP_THREADS` entry; OLD moves
   to `LEAKED_THREAD_IDS`.
4. Session converges `CLEAN` at round 2.
5. Phase 3: `--cleanup B` (current), `--cleanup OLD` (leaked), `--cleanup A` (leaked) -- all three
   `FAKE_CODEX_CLEANUP_OK=1`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> compact-fresh-b-escalation
```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `2`
- `threads`: THREE entries -- one `current` (B), TWO `leaked` (OLD and A), all `cleanup:
  "deleted"` -- BOTH abandoned threads really were cleaned up, not just recorded.
- Invocation log: exactly 3 `mode=fresh ` lines, in ORDER (OLD, then A, then B -- three distinct
  `thread_id` values), and exactly 2 `mode=resume ` lines (both against A, both appearing AFTER
  A's own fresh line and BEFORE B's own fresh line).
- The session's own JSONL log: round 1's line carries neither `compacted_from_thread` nor
  `compaction_attempt_failed_thread`; round 2's line carries `compacted_from_thread` equal to
  OLD's `thread_id` and `compaction_attempt_failed_thread` equal to the exact one-element array
  `[A]` (never `[B]`, never including OLD, never a 2-element array), plus
  `compaction_attempt_execution` (A's 3 failed attempts) and `compaction_attempt_failure_count:
  0`. Exactly 2 records total in the JSONL log (rounds 1 and 2, no hidden third round).

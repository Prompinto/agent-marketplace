# Scenario: no-material-reviewed-second-hollow

**Group:** I (material verification / `no_material_reviewed` coverage).

**Targets:** `references/retry-guards.md`'s one-fresh-restart-then-give-up bound (Task 9 of
`docs/superpowers/plans/2026-09-10-ccs-material-verification.md`) — confirms that when the ONE
bounded fresh restart's own brand-new thread (`B`) ALSO returns `material_reviewed:false`, the
session does not attempt a third thread. It stops immediately and reports `⚠️ COULD NOT VERIFY`,
matching this file's own existing round-1-fresh-fallback-then-give-up precedent and
`--compact`'s own candidate-A-to-thread-B single-shot-escalation-then-give-up pattern.

## Thread-kind resolution — both `A` and `B` end up `"leaked"`, neither `"current"`

This scenario's terminal `exit_state` is `COULD_NOT_VERIFY` — the one other scenario sharing that
`exit_state`, `could-not-verify-exhausted`, ends with ONE `"current"` thread (the exhausted
fresh-fallback retry `B`) and ONE `"leaked"` thread (the abandoned round-1 thread `A`). This
scenario is **deliberately different**: both `A` and `B` end up `"kind":"leaked"`, and
`GROUP_THREADS` never holds a `"main"` entry at all. This was verified against the actual
documented mechanics, not assumed from the task brief:

- `references/retry-guards.md`'s ordinary round-1 fresh-fallback rule (the mechanism
  `could-not-verify-exhausted` exercises) never reclassifies its own final fresh-fallback thread
  `B` into `LEAKED_THREAD_IDS` on failure — `B` simply IS the group's thread, `GROUP_THREADS["main"]
  = B`, and the round terminates with `B` still the group's one and only (failed) thread. That is
  why `could-not-verify-exhausted`'s own `expect.sh` asserts "at least one `current`" and "at least
  one `leaked`".
- `references/retry-guards.md`'s `no_material_reviewed` section (`## no_material_reviewed — never
  resume-safe, one bounded fresh restart`) uses different, explicit wording for this specific
  exhaustion path: **"If the ONE fresh restart fails for ANY reason... add it [the restart's own
  threadId] to `LEAKED_THREAD_IDS` immediately — this restart's own new thread is abandoned too,
  **exactly like the original hollow thread was**, so `SKILL.md`'s Phase 3 terminal path can clean
  it up alongside the run's other final threads."** ("exactly like the original hollow thread was"
  is the load-bearing phrase — thread `A` was added to `LEAKED_THREAD_IDS`, never `GROUP_THREADS`,
  the moment it was abandoned; this sentence says `B` gets the identical treatment on its own
  failure, not the ordinary ambient-ok-current status `could-not-verify-exhausted`'s fresh-fallback
  thread keeps.)
- `SKILL.md`'s Phase 3 `threads` computation (`"threads": one entry per (GROUP, threadId) pair...
  every GROUP_THREADS entry with "kind":"current", plus every LEAKED_THREAD_IDS entry with
  "kind":"leaked"`) only ever produces a `"current"` entry from a live `GROUP_THREADS` mapping.
  Since `no_material_reviewed`'s own restart (unlike an ordinary round-1 fresh-fallback, and unlike
  a successful `no_material_reviewed` restart per `material-reviewed-false-never-resumed`) is
  documented as being abandoned into `LEAKED_THREAD_IDS` on its own failure rather than ever being
  promoted into `GROUP_THREADS`, the group's `GROUP_THREADS["main"]` entry is never populated in
  this failure path at all — there is nothing for the `"current"` half of the union to draw from.
  A single thread appearing as both `"current"` (from `GROUP_THREADS`) and `"leaked"` (from
  `LEAKED_THREAD_IDS`) at once would be a duplicated, self-contradictory row; the design's own text
  above resolves that by never letting a permanently-exhausted `no_material_reviewed` restart reach
  `GROUP_THREADS` in the first place.

This distinction is real, not cosmetic: it reflects that `no_material_reviewed`'s entire premise is
"this thread's context is proven hollow, so it can never again be treated as this group's live,
authoritative thread" — and that premise applies equally to the restart's own thread if it, too,
proves hollow. An ordinary resume-exhausted failure (nonzero_exit, timeout, etc.) never makes that
claim about the thread itself; it only says repeated attempts didn't succeed, so the thread stays
the group's legitimate (if unlucky) `"current"` record.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_SCENARIO=schema_mismatch`
with the SAME `material_reviewed:false` answer on BOTH dispatches (round 1's hollow attempt AND the
restart's hollow attempt) — the central structural difference from every other Group I scenario
built so far, none of which ever scripts BOTH attempts to fail the same way. `FAKE_CODEX_CLEANUP_OK=1`
for both `--cleanup` calls. `FAKE_CODEX_INVOCATION_LOG` set to the fixed path `setup.sh` prints
(`/tmp/ccs-eval-no-material-reviewed-second-hollow-invocation.log`) on every call. Both dispatches
pass `--receipt-schedule-file`/`--receipt-slot 1`, per the unconditional "every brand-new-thread
dispatch gets one" rule in `SKILL.md`'s "Receipt schedule generation" section — but, per the design
doc's §3 route 1 (the wrapper's own `material_reviewed == false` check firing before Phase 2
receipt validation is ever reached), NEITHER dispatch's own schedule/receipt VALUE is ever
load-bearing for this scenario's outcome — both are rejected at the wrapper level regardless of
what the schedule contains, exactly like round 1 of `material-reviewed-false-never-resumed`.

## How to run

Invoke `codex-stream-review:ccs` against `REPO_DIR` (task text: "review the uncommitted change in
this fixture repo"):

```bash
bash codex-stream-review/evals/scenarios/no-material-reviewed-second-hollow/setup.sh
```

```bash
bash codex-stream-review/evals/check-result.sh <result.json> no-material-reviewed-second-hollow
```

## Manual walkthrough

1. **Round 1**: fresh `--uncommitted` dispatch, `--receipt-schedule-file <round-1 schedule>
   --receipt-slot 1`, `FAKE_CODEX_SCENARIO=schema_mismatch` with the `material_reviewed:false`
   answer above — real `threadId` (`A`) captured despite the rejection.
2. `references/retry-guards.md`'s `no_material_reviewed` rule fires (`detail` carries the literal
   substring `no_material_reviewed`): thread `A` is added to `LEAKED_THREAD_IDS`, never resumed.
3. Fresh restart (thread `B`, still round 1 — the hollow attempt never produced a valid round-1
   result), its own new `--receipt-schedule-file <restart schedule> --receipt-slot 1`, ALSO
   `FAKE_CODEX_SCENARIO=schema_mismatch` with the identical `material_reviewed:false` answer —
   real, genuinely NEW `threadId` (`B`) captured, ALSO rejected as `no_material_reviewed`.
4. `references/retry-guards.md`'s "If the ONE fresh restart fails for ANY reason" rule fires: `B`
   is added to `LEAKED_THREAD_IDS` immediately too. The session stops here, unconditionally —
   never a third thread (`C`).
5. Confirm: `⚠️ COULD NOT VERIFY` is the session's terminal status; the final `.result.json` names
   BOTH `A` and `B` as `"kind":"leaked"`/`"cleanup":"deleted"` — neither is `"current"`; `claims`
   is `[]` (no round ever produced a real verdict to raise a claim from); the fixed invocation log
   shows exactly 2 `mode=fresh` lines (two distinct thread ids) and exactly 0 `mode=resume` lines,
   confirming no third thread was ever dispatched and neither hollow thread was ever `--resume`d.

### Round-line accounting — why `round_count` is `0`, not `1`

Every prior Group I scenario whose restart eventually SUCCEEDS (`material-reviewed-false-never-resumed`,
`receipt-mismatch-phase2-reject`, `receipt-null-pair-reject`) reports `round_count: 1` — the
restart's own eventual accepted response is what gets logged as round 1's real, final outcome
(`SKILL.md`'s "append this round's line ... after step 1's parsing" only runs once a dispatch is
accepted past the `no_material_reviewed` diversion, per Phase 2 step 1's own explicit ordering
rule: a hollow response is diverted "before step 2/3/convergence ever process it", and per
`receipt-mismatch-phase2-reject`'s own confirmed `expect.sh` finding, a hollow round-1 attempt is
**never separately persisted as its own JSONL round line under any thread id, at any point** — only
the eventually-ACCEPTED attempt ever gets logged as round 1).

In this scenario, NEITHER attempt is ever accepted — both `A` and `B` are diverted at the
`no_material_reviewed` check, before round 1's own real outcome is ever established. There is
therefore no successful attempt left to log a `"round":1` JSONL line for, and none is written —
this is exactly the degenerate case `SKILL.md`'s own Phase 3 `round_count` field description names:
**"the final round number `R` reached (0 only for the degenerate case where a terminal status was
reached before any round's JSONL line was ever appended)"**. The session's durable JSONL log
therefore contains only `receipt_issued` records (one `PENDING:...` + one reconciliation, per
thread, four lines total) — no `"round"`-bearing line at all. `coverage` is still a real object in
the final artifact: both hollow attempts are fresh `--uncommitted` dispatches whose failure reason
(`schema_mismatch`) is one of the 7 unconditionally-coverage-eligible reasons, so `coverage.source`
is available from each in-memory, independent of whether either was ever durably logged as a round.

## Live verification actually performed

This scenario was driven as a real, faithful manual walkthrough of `SKILL.md`'s Phase 0-3
procedure (matching every prior Group I scenario's own precedent for driving `/ccs` without the
Skill tool's own harness, since that harness resolves `INSTALL_PATH` from the marketplace-cached
plugin install, confirmed stale in every prior task) — `INSTALL_PATH` pointed at this repo's own
`codex-stream-review/scripts/run-ccs-review.sh` directly, never the cached install.

**Fixture:** a real throwaway git repo (`eval_make_fixture_repo`), `/tmp/ccs-eval-no-material-reviewed-second-hollow.fKYCiy`,
with one committed line and one uncommitted appended line in `lib.py`, the fake-`codex` fixture
prepended onto `PATH` on every Bash call, `FAKE_CODEX_INVOCATION_LOG` re-exported on every call.

1. **Session identity** — `SESSION_ID=2026-09-11T170639-35107`, repo-slug
   `ccs-eval-no-material-reviewed-second-hollow-fkyciy-`.
2. **Round 1's own receipt schedule generated live** (`mktemp` + 70-iteration `shasum -a 256`
   loop, verified 71 lines), durably recorded as a `receipt_issued` JSONL line
   (`PENDING:ccs-2026-09-11T170639-35107-main-receipt-schedule.txt.wCCHe0`, index 1) BEFORE the
   dispatch was ever constructed.
3. **Round 1 dispatch** (`--receipt-schedule-file <round-1 schedule> --receipt-slot 1`,
   `FAKE_CODEX_SCENARIO=schema_mismatch`, the `material_reviewed:false` answer): real response
   observed —
   ```json
   {"ok":false,"reason":"schema_mismatch","threadId":"e3665ea0-4ef6-4d37-a9b6-bb515f2ad113","detail":"no_material_reviewed: material_reviewed is false","coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":0}}
   ```
   Thread `A` = `e3665ea0-4ef6-4d37-a9b6-bb515f2ad113`. The `PENDING:...` receipt record was
   reconciled to this real thread id via a second JSONL line
   (`{"receipt_issued":{"thread_id":"e3665ea0-4ef6-4d37-a9b6-bb515f2ad113","index":1,"reconciles":"PENDING:ccs-2026-09-11T170639-35107-main-receipt-schedule.txt.wCCHe0"}}`),
   and `A` was recorded as leaked.
4. **The restart's own real receipt schedule generated live**, as its own separate freshly-`mktemp`'d
   file (`ccs-2026-09-11T170639-35107-main-restart-receipt-schedule.txt.zqGgnk`, verified 71 lines)
   — never reusing round 1's schedule. Its own `PENDING` `receipt_issued` line
   (`{"receipt_issued":{"thread_id":"PENDING:ccs-2026-09-11T170639-35107-main-restart-receipt-schedule.txt.zqGgnk","index":1}}`)
   was durably recorded before this dispatch was constructed.
5. **Restart dispatch** (`--receipt-schedule-file <restart schedule> --receipt-slot 1`, ALSO
   `FAKE_CODEX_SCENARIO=schema_mismatch` with the identical `material_reviewed:false` answer): real
   response observed —
   ```json
   {"ok":false,"reason":"schema_mismatch","threadId":"d48d4132-69cc-4055-b7f8-36bbf2eea84d","detail":"no_material_reviewed: material_reviewed is false","coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":1}}
   ```
   Genuine new thread `B` = `d48d4132-69cc-4055-b7f8-36bbf2eea84d`, distinct from `A`, ALSO
   `no_material_reviewed`. The restart's own `PENDING` receipt record was then reconciled to this
   real thread id
   (`{"receipt_issued":{"thread_id":"d48d4132-69cc-4055-b7f8-36bbf2eea84d","index":1,"reconciles":"PENDING:ccs-2026-09-11T170639-35107-main-restart-receipt-schedule.txt.zqGgnk"}}`),
   and `B` was ALSO recorded as leaked, per `references/retry-guards.md`'s exhaustion rule — never
   promoted to `GROUP_THREADS`.
6. **Session terminated: `⚠️ COULD NOT VERIFY`.** No third thread was ever dispatched.
7. **The real, durable JSONL log** at
   `~/.claude/plugins/data/codex-stream-review/ccs-logs/ccs-eval-no-material-reviewed-second-hollow-fkyciy-/2026-09-11T170639-35107.jsonl`,
   read back in full to confirm its actual content — exactly 4 lines, all `receipt_issued`, no
   `"round"`-bearing line at all (per "Round-line accounting" above):
   ```json
   {"receipt_issued":{"thread_id":"PENDING:ccs-2026-09-11T170639-35107-main-receipt-schedule.txt.wCCHe0","index":1}}
   {"receipt_issued":{"thread_id":"e3665ea0-4ef6-4d37-a9b6-bb515f2ad113","index":1,"reconciles":"PENDING:ccs-2026-09-11T170639-35107-main-receipt-schedule.txt.wCCHe0"}}
   {"receipt_issued":{"thread_id":"PENDING:ccs-2026-09-11T170639-35107-main-restart-receipt-schedule.txt.zqGgnk","index":1}}
   {"receipt_issued":{"thread_id":"d48d4132-69cc-4055-b7f8-36bbf2eea84d","index":1,"reconciles":"PENDING:ccs-2026-09-11T170639-35107-main-restart-receipt-schedule.txt.zqGgnk"}}
   ```
8. **`FAKE_CODEX_INVOCATION_LOG`** (`/tmp/ccs-eval-no-material-reviewed-second-hollow-invocation.log`),
   real contents observed after both dispatches plus both cleanups:
   ```
   mode=fresh thread_id=e3665ea0-4ef6-4d37-a9b6-bb515f2ad113 scenario=schema_mismatch
   mode=fresh thread_id=d48d4132-69cc-4055-b7f8-36bbf2eea84d scenario=schema_mismatch
   mode=delete thread_id=e3665ea0-4ef6-4d37-a9b6-bb515f2ad113 scenario=normal
   mode=delete thread_id=d48d4132-69cc-4055-b7f8-36bbf2eea84d scenario=normal
   ```
   Exactly 2 `mode=fresh` lines (two distinct thread ids), **zero** `mode=resume` lines, **exactly
   2** `mode=fresh` lines total (never a third) — direct, mechanical proof no third thread was ever
   dispatched.
9. **Cleanup** — `run-ccs-review.sh --cleanup <A>` and `--cleanup <B>` (`FAKE_CODEX_CLEANUP_OK=1`)
   both returned `{"ok":true,"threadId":"...","deleted":true}`.
10. **Resulting `.result.json`**, the actual file written at
    `~/.claude/plugins/data/codex-stream-review/ccs-logs/ccs-eval-no-material-reviewed-second-hollow-fkyciy-/2026-09-11T170639-35107.result.json`,
    read back in full, schema-validated via `check-result.sh` against this scenario's own real,
    UNMODIFIED `expect.sh` (`schema OK` / `assertions OK` / exit code 0):
    ```json
    {
      "session_id": "2026-09-11T170639-35107",
      "target": { "repo": "/tmp/ccs-eval-no-material-reviewed-second-hollow.fKYCiy", "scope": "uncommitted" },
      "exit_state": "COULD_NOT_VERIFY",
      "round_count": 0,
      "threads": [
        { "group": "main", "thread_id": "e3665ea0-4ef6-4d37-a9b6-bb515f2ad113", "kind": "leaked", "cleanup": "deleted" },
        { "group": "main", "thread_id": "d48d4132-69cc-4055-b7f8-36bbf2eea84d", "kind": "leaked", "cleanup": "deleted" }
      ],
      "claims": [],
      "coverage": { "status": "complete", "reviewed_file_count": 1, "omitted": [] },
      "input_errors": null
    }
    ```

## Expected result

- `exit_state`: `"COULD_NOT_VERIFY"`, `round_count`: `0` (no round's own JSONL line was ever
  appended — see "Round-line accounting" above).
- `threads`: exactly TWO `"leaked"` entries (`A` and `B`), ZERO `"current"` entries — both
  `cleanup: "deleted"`; `A` and `B` are different thread ids.
- `claims`: `[]` — no round ever produced a real verdict to raise a claim from.
- `coverage`: an object (`target.scope: "uncommitted"`), `status: "complete"` (both hollow
  attempts' own `coverage.source` reported `"complete"` for this 1-file fixture).
- The fixed invocation log shows exactly 2 `mode=fresh` lines (two DIFFERENT `thread_id` values)
  and exactly **zero** `mode=resume` lines — mechanical proof no third thread was ever dispatched
  and neither hollow thread was ever resumed.
- The session's own durable JSONL log contains only `receipt_issued` records (one `PENDING:...` +
  one reconciliation, per thread — four lines total), and no `"round"`-bearing line at all.

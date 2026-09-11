# Scenario: receipt-mismatch-phase2-reject

**Group:** I (material verification / `no_material_reviewed` coverage).

**Targets:** `SKILL.md`'s Phase 2 step 1 receipt-validation check (Task 8 of
`docs/superpowers/plans/2026-09-10-ccs-material-verification.md`) — confirms that a schema-valid
`ok:true` response (`material_reviewed:true`, `material_receipt`/`material_receipt_index` both
well-typed and correctly paired at the right index — `run-ccs-review.sh`'s own `schema_mismatch`
check, Task 5, has NOTHING to reject here, since it only validates TYPE/pairing, never the actual
VALUE against session state) is STILL caught when the receipt VALUE itself doesn't match what
Claude's own session state (`RECEIPT_SCHEDULE_FILE` + the JSONL `receipt_issued` cursor) says it
should be. This is the half of `no_material_reviewed` detection that structurally CANNOT live in
the stateless wrapper — only in Claude's own Phase 2 processing, which alone has both the
schedule's real content and the cursor.

This is the direct structural counterpart to `material-reviewed-false-never-resumed` (Task 12):
that scenario's round 1 was rejected by the WRAPPER itself (`material_reviewed:false`,
`schema_mismatch`); this scenario's round 1 is accepted by the wrapper as `ok:true`, and the
rejection instead happens one layer up, in the live orchestrating agent's own Phase 2 step 1 check.
Recovery is identical in both: abandon the hollow thread, one bounded fresh restart (never
`--resume`), reusing `references/compaction.md`'s own restart mechanism per
`references/retry-guards.md`.

## Receipt schedule construction

Both of this scenario's brand-new-thread dispatches (round 1's hollow attempt, and the restart) get
their own independent `RECEIPT_SCHEDULE_FILE` — generated LIVE, by whatever agent is actually
driving the `/ccs` session, using `SKILL.md`'s own exact procedure (`mktemp` + a 70-iteration
`shasum -a 256`-derived token loop), at the exact point Phase 1 Step 0 calls for it. `setup.sh`
deliberately does NOT pre-generate either schedule, exactly like `material-reviewed-false-never-resumed`'s
own `setup.sh` — see that scenario's README for why a schedule pre-baked by `setup.sh` would not be
evidence that a live orchestrating agent's own real procedure produced it.

- **Round 1's schedule:** generated live, immediately before round 1's own fresh dispatch, and
  passed (`--receipt-schedule-file ... --receipt-slot 1`). The live driving agent reads slot 1's
  own real token off this file — needed specifically so it can construct a response that
  DELIBERATELY avoids that value (schema-valid shape, wrong content). The wrapper's own
  `schema_mismatch` check never compares the response's `material_receipt` against the schedule
  file's content at all — it only validates the schedule file's own 71-line shape and the
  response's type/pairing — so this round 1 response is accepted as `ok:true` regardless of
  whether its receipt value is right or wrong.
- **The restart's schedule:** generated live, as its own separate, freshly-`mktemp`'d file, at the
  point `references/retry-guards.md`'s `no_material_reviewed` recovery calls for a fresh restart —
  never reusing round 1's abandoned schedule. The live driving agent reads slot 1's own real token
  off THIS file and bakes it into the restart's own `FAKE_CODEX_FINAL_ANSWER` as
  `material_receipt:"<that token>"` with `material_receipt_index:1`, constructed with `jq`, never
  hand-interpolated.

A note on where "genuinely matching"/"genuinely mismatching" was verified: the live run documented
below performs `SKILL.md`'s own Phase 2 step 1 check PROGRAMMATICALLY, on BOTH responses —
extracting slot 1's token from each schedule file with `awk`/`sed`, extracting
`verdict.material_receipt`/`verdict.material_receipt_index` from each response with `jq`, and
comparing the two values with a real shell `if` test — not by eyeballing a side-by-side printout.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_SCENARIO=normal` for
BOTH dispatches (never `schema_mismatch` — this scenario's whole point is that the wrapper's own
`schema_mismatch` check has nothing to reject here): round 1's `FAKE_CODEX_FINAL_ANSWER` carries a
deliberately WRONG `material_receipt` (schema-valid shape, plus one fabricated `ISSUES` finding to
prove it never leaks); the restart's `FAKE_CODEX_FINAL_ANSWER` carries a genuinely matching
`material_receipt`/`material_receipt_index` pair for its own fresh schedule.
`FAKE_CODEX_CLEANUP_OK=1` for both `--cleanup` calls. `FAKE_CODEX_INVOCATION_LOG` set to the fixed
path `setup.sh` prints (`/tmp/ccs-eval-receipt-mismatch-phase2-reject-invocation.log`) on every
call. Both dispatches pass `--receipt-schedule-file`/`--receipt-slot 1`, per the unconditional
"every brand-new-thread dispatch gets one" rule in `SKILL.md`'s "Receipt schedule generation"
section.

## How to run

Invoke `codex-stream-review:ccs` against `REPO_DIR` (task text: "review the uncommitted change in
this fixture repo"), matching every other scenario's convention (a real, multi-round
Claude+Codex-style conversation, not a scripted harness):

```bash
bash codex-stream-review/evals/scenarios/receipt-mismatch-phase2-reject/setup.sh
```

```bash
bash codex-stream-review/evals/check-result.sh <result.json> receipt-mismatch-phase2-reject
```

## Manual walkthrough

1. **Round 1**: fresh `--uncommitted` dispatch, `--receipt-schedule-file <round-1 schedule>
   --receipt-slot 1`, `FAKE_CODEX_SCENARIO=normal` with `material_reviewed:true`,
   `material_receipt_index:1`, and `material_receipt` set to a WRONG 24-character value (not the
   real slot-1 token) plus one fabricated `ISSUES` finding — real `threadId` (`A`) captured; the
   wrapper returns `ok:true` (schema-valid: nothing for `schema_mismatch` to reject).
2. A live orchestrating agent applying `SKILL.md`'s Phase 2 step 1 check to this response
   programmatically compares the response's `material_receipt`/`material_receipt_index` against
   the round-1 schedule's own slot-1 entry: they do NOT match. This response is treated
   IMMEDIATELY — before its findings are ever received, re-verified, or considered for
   convergence — as equivalent to `ok:false` with reason `no_material_reviewed`.
3. `references/retry-guards.md`'s `no_material_reviewed` rule fires: thread `A` is added to
   `LEAKED_THREAD_IDS`, never resumed.
4. Fresh restart (thread `B`, still round 1 — the hollow attempt never produced a valid round-1
   result), its own new `--receipt-schedule-file <restart schedule> --receipt-slot 1`,
   `FAKE_CODEX_SCENARIO=normal` with `material_reviewed:true` and a `material_receipt`/
   `material_receipt_index` pair that genuinely matches slot 1 of the restart's own schedule —
   succeeds, CLEAN, and Phase 2 step 1's programmatic check on this response finds a real match.
5. Confirm: `A` never appears in any `--resume` call in `FAKE_CODEX_INVOCATION_LOG`; the final
   `.result.json` names `A` as `"kind":"leaked"`/`"cleanup":"deleted"`; `B` is the session's own
   final, live thread (`"kind":"current"`/`"cleanup":"deleted"`); `claims` is `[]`; the fabricated
   finding from round 1's hollow response never appears anywhere in the session's own JSONL
   `codex_review.findings[]`.

### Live verification actually performed (genuinely live, via the real Skill tool)

This section documents a run where `codex-stream-review:ccs` was invoked through the actual `Skill`
tool — `Skill({skill: "codex-stream-review:ccs", args: "review the uncommitted change in
<fixture repo path>"})` — which loaded `SKILL.md`'s real, full procedure inline into the driving
agent's own tool-call loop. Every Bash call below was then made by hand, by that same agent,
following the loaded procedure step by step in the real order a live session hits them —
generating BOTH receipt schedules live, at the exact point Phase 1 Step 0 and
`references/retry-guards.md`'s restart recovery respectively call for them, never pre-baked by
`setup.sh`.

**Fixture:** a real throwaway git repo (`eval_make_fixture_repo`) with one committed line and one
uncommitted appended line in `lib.py`, the fake-`codex` fixture prepended onto `PATH` on every Bash
call, `FAKE_CODEX_INVOCATION_LOG` re-exported on every call.

1. **Phase 0/1 setup** — session id `2026-09-11T130914-38571`, repo root
   `/tmp/ccs-eval-receipt-mismatch-phase2-reject.VICLVv`, a real sizing pass (1 changed file →
   single-reviewer `GROUP="main"`), and a real snapshot hash of the diff (`SNAPSHOT_DIGEST`
   `f979c239deaba024486421eb2527249e8acf6a99b1844c8e8b4dce795ed4bd99`, a genuine 64-hex-char
   `shasum -a 256` value). `INSTALL_PATH` was pointed at this repo's own
   `codex-stream-review/scripts/run-ccs-review.sh` rather than the marketplace-cached plugin
   install, because that cached install (v1.0.6) predates the `material_reviewed`/`material_receipt`
   feature entirely (confirmed by `grep -c material_reviewed` against it returning `0`) — using it
   would have silently exercised the OLD wrapper, not the code this scenario exists to verify.
2. **Round 1's own receipt schedule generated live**, right before round 1's dispatch, via
   `SKILL.md`'s exact `mktemp` + 70-iteration `shasum -a 256` loop
   (`/tmp/ccs-2026-09-11T130914-38571-main-receipt-schedule.txt.xzcMtc`), then durably recorded as
   a `receipt_issued` JSONL line (`PENDING:ccs-2026-09-11T130914-38571-main-receipt-schedule.txt.xzcMtc`,
   index 1) BEFORE the dispatch was ever constructed. Slot 1's own real token on this schedule:
   `f3b216f49d9fd0655236d292`.
3. **Round 1 dispatch** (`--receipt-schedule-file <live-generated round-1 schedule>
   --receipt-slot 1`, `FAKE_CODEX_SCENARIO=normal`, a JSON verdict constructed with `jq` carrying
   `material_reviewed:true`, `material_receipt_index:1`, `material_receipt:"deadbeefdeadbeefdeadbeef"`
   — deliberately NOT the real slot-1 token `f3b216f49d9fd0655236d292` — plus one fabricated
   `ISSUES` finding `{"file":"lib.py","line":3,"severity":"low","summary":"fabricated finding that
   must never leak into the session JSONL",...}`): real response observed —
   ```json
   {"ok":true,"threadId":"2659bcf9-6827-41fe-9f13-e0a9516e0b08","verdict":{"verdict":"ISSUES","findings":[{"file":"lib.py","line":3,"severity":"low","summary":"fabricated finding that must never leak into the session JSONL","evidence":"e","verification":"v"}],"summary":null,"dimensions":{...},"material_reviewed":true,"material_receipt":"deadbeefdeadbeefdeadbeef","material_receipt_index":1},"coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":1}}
   ```
   `ok:true` confirms the exact distinction this scenario targets: the wrapper's own
   `schema_mismatch` check (which only validates TYPE/pairing, never VALUE) had nothing to reject
   — `material_reviewed` is `true`, and `material_receipt`/`material_receipt_index` are a
   well-typed, correctly-paired, non-null pair at the right index. Thread
   `A` = `2659bcf9-6827-41fe-9f13-e0a9516e0b08`.
4. **Programmatic Phase 2 step 1 check on round 1's response** — not a by-eye comparison: extracted
   slot 1's token from the round-1 schedule file with `sed`/`awk`, extracted
   `verdict.material_receipt`/`verdict.material_receipt_index` from the response with `jq`, and
   compared both with a real shell `if` test:
   ```
   expected slot=1 token=f3b216f49d9fd0655236d292
   response   index=1 receipt=deadbeefdeadbeefdeadbeef
   PHASE_2_STEP_1_RECEIPT_CHECK: MISMATCH -- treat as synthetic ok:false/no_material_reviewed, BEFORE step 2/3/convergence
   ```
   This is the concrete evidence that this rejection happens via a real value comparison performed
   by the LIVE ORCHESTRATING AGENT itself — never something the wrapper's own response already
   flagged (its `"ok"` field is `true`) and never a by-eye assertion. The `PENDING:...` receipt
   record was then reconciled to this real thread id via a second JSONL line
   (`{"receipt_issued":{"thread_id":"2659bcf9-6827-41fe-9f13-e0a9516e0b08","index":1,"reconciles":"PENDING:ccs-2026-09-11T130914-38571-main-receipt-schedule.txt.xzcMtc"}}`),
   and `A` was recorded as leaked. Per `references/retry-guards.md`'s recovery, `A` is never
   `--resume`d.
5. **Restart's own real receipt schedule generated live**, as its own separate freshly-`mktemp`'d
   file (`ccs-2026-09-11T130914-38571-main-restart-receipt-schedule.txt.ojK34K`), never reusing
   round 1's schedule. Slot 1's real token was read off this file at that moment:
   `f127c0283bfbe5e78e8ca739` (verified as exactly 24 raw bytes via `wc -c` before use). Its own
   PENDING `receipt_issued` line
   (`{"receipt_issued":{"thread_id":"PENDING:ccs-2026-09-11T130914-38571-main-restart-receipt-schedule.txt.ojK34K","index":1}}`)
   was durably recorded before this dispatch was constructed.
6. **Restart dispatch** (`--receipt-schedule-file <live-generated restart schedule>
   --receipt-slot 1`, `FAKE_CODEX_SCENARIO=normal`, `FAKE_CODEX_FINAL_ANSWER` constructed with `jq`
   carrying `material_receipt:"f127c0283bfbe5e78e8ca739"` and `material_receipt_index:1`): real
   response observed —
   ```json
   {"ok":true,"threadId":"005c88b8-b845-42df-9d79-df688919f6df","verdict":{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{...all not_applicable/checked...},"material_reviewed":true,"material_receipt":"f127c0283bfbe5e78e8ca739","material_receipt_index":1},"coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":0}}
   ```
   Genuine new thread `B` = `005c88b8-b845-42df-9d79-df688919f6df`, distinct from `A`, CLEAN. The
   restart's own PENDING receipt record from step 5 was then reconciled to this real thread id via
   a second JSONL line
   (`{"receipt_issued":{"thread_id":"005c88b8-b845-42df-9d79-df688919f6df","index":1,"reconciles":"PENDING:ccs-2026-09-11T130914-38571-main-restart-receipt-schedule.txt.ojK34K"}}`).
7. **Programmatic Phase 2 step 1 check on the restart's response** — same mechanism as step 4,
   applied to the restart:
   ```
   expected slot=1 token=f127c0283bfbe5e78e8ca739
   response   index=1 receipt=f127c0283bfbe5e78e8ca739
   PHASE_2_STEP_1_RECEIPT_CHECK: MATCH -- accept as genuine CLEAN, proceed to convergence
   ```
   Concrete evidence that a fully live-orchestrated `/ccs` session — one that actually applies
   Phase 2 step 1 to the restart's response with a real comparison, not an assertion of success —
   reaches real, Phase-2-compliant `CLEAN` here, not just wrapper-level `ok:true`.
8. **Round 1's own JSONL line appended and verified** (`tail -n 1 <log> | jq -e '.round == 1'`
   returned `true`) to the real review-history log at
   `~/.claude/plugins/data/codex-stream-review/ccs-logs/ccs-eval-receipt-mismatch-phase2-reject-viclvv-/2026-09-11T130914-38571.jsonl`,
   carrying `schema_version: 3`, `thread_id: "005c88b8-b845-42df-9d79-df688919f6df"` (the
   RESTART's real thread — never the abandoned hollow thread's), `coverage_source:
   {"status":"complete"}`, `round_outcome: "converged"`, `codex_review.findings: []` (the
   fabricated finding from round 1's hollow response — which DID exist in the raw wrapper
   response, per step 3 above — never appears here: it was rejected wholesale before ever being
   received/processed, per Phase 2 step 1's own ordering rule), and — carried verbatim from the
   restart's own real response — `"material_reviewed":true,"material_receipt":"f127c0283bfbe5e78e8ca739","material_receipt_index":1`.
9. **`FAKE_CODEX_INVOCATION_LOG`** (`/tmp/ccs-eval-receipt-mismatch-phase2-reject-invocation.log`),
   real contents observed after both dispatches plus both cleanups:
   ```
   mode=fresh thread_id=2659bcf9-6827-41fe-9f13-e0a9516e0b08 scenario=normal
   mode=fresh thread_id=005c88b8-b845-42df-9d79-df688919f6df scenario=normal
   mode=delete thread_id=005c88b8-b845-42df-9d79-df688919f6df scenario=normal
   mode=delete thread_id=2659bcf9-6827-41fe-9f13-e0a9516e0b08 scenario=normal
   ```
   Exactly 2 `mode=fresh` lines (two distinct thread ids), **zero** `mode=resume` lines — direct,
   mechanical proof `A` was never `--resume`d, and both dispatches were genuinely `ok:true` at the
   wrapper level (`scenario=normal` on both, never `schema_mismatch` — confirming this scenario's
   central distinction from Task 12).
10. **Cleanup** — `run-ccs-review.sh --cleanup <B>` and `--cleanup <A>` (`FAKE_CODEX_CLEANUP_OK=1`)
    both returned `{"ok":true,"threadId":"...","deleted":true}`.
11. **Resulting `.result.json`**, the actual file written at
    `~/.claude/plugins/data/codex-stream-review/ccs-logs/ccs-eval-receipt-mismatch-phase2-reject-viclvv-/2026-09-11T130914-38571.result.json`
    (session-level fields assembled per `SKILL.md`'s Phase 3, from the real values above;
    schema-validated via `check-result.sh` against this scenario's own real, UNMODIFIED `expect.sh`,
    which reported `schema OK` / `assertions OK` / exit code 0):
    ```json
    {
      "session_id": "2026-09-11T130914-38571",
      "target": { "repo": "/tmp/ccs-eval-receipt-mismatch-phase2-reject.VICLVv", "scope": "uncommitted" },
      "exit_state": "CLEAN",
      "round_count": 1,
      "threads": [
        { "group": "main", "thread_id": "2659bcf9-6827-41fe-9f13-e0a9516e0b08", "kind": "leaked", "cleanup": "deleted" },
        { "group": "main", "thread_id": "005c88b8-b845-42df-9d79-df688919f6df", "kind": "current", "cleanup": "deleted" }
      ],
      "claims": [],
      "coverage": { "status": "complete", "reviewed_file_count": 1, "omitted": [] },
      "input_errors": null
    }
    ```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `1` (the restart occupies round 1's own single slot —
  the hollow attempt never produced a valid round-1 result).
- `threads`: exactly one `"leaked"` entry (the abandoned hollow thread `A`) and exactly one
  `"current"` entry (the fresh restart's own new thread `B`) — both `cleanup: "deleted"`; `A` and
  `B` are different thread ids.
- `claims`: `[]` — the hollow response's own fabricated finding never entered the claim ledger, and
  never appears anywhere in the session's own JSONL `codex_review.findings[]`.
- The fixed invocation log shows exactly 2 `mode=fresh` lines (two DIFFERENT `thread_id` values)
  and exactly **zero** `mode=resume` lines — mechanical proof the abandoned thread is never
  resumed, and both dispatches were genuine `scenario=normal` `ok:true` wrapper responses (never
  `schema_mismatch`) — confirming the rejection happened at the Phase 2 (Claude) layer, not the
  wrapper layer.
- The restart's own `material_receipt`/`material_receipt_index` genuinely match slot 1 of its own
  fresh receipt schedule — a live orchestrating agent must remember to construct a genuinely
  matching receipt for the restart's own schedule, generated live at the point `SKILL.md`'s own
  Phase 1 Step 0 / `references/retry-guards.md` call for it (never pre-baked by `setup.sh`).

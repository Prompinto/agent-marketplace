# Scenario: material-reviewed-false-never-resumed

**Group:** I (material verification / `no_material_reviewed` coverage).

**Targets:** `run-ccs-review.sh`'s `schema_mismatch` extension (Task 5/7 of
`docs/superpowers/plans/2026-09-10-ccs-material-verification.md`) — confirms `material_reviewed:false`
combined with a NONEMPTY `ISSUES` findings array is rejected exactly like the `CLEAN` case, closing
the specific gap an earlier design draft left open (checking only `material_reviewed:false` +
`CLEAN`, never `material_reviewed:false` + a real findings array). Also confirms the mechanical
fact that the resulting `no_material_reviewed` failure's thread is never `--resume`d, and the one
fresh restart lands on a distinct new thread id — still occupying round 1's own single slot, since
the hollow attempt never produced a valid round-1 result (see `references/retry-guards.md`'s
round-1-vs-round-2+ disambiguation).

The restart's response also carries a GENUINELY matching `material_receipt`/`material_receipt_index`
pair for its own fresh receipt schedule (see "Receipt schedule construction" below), so this
scenario proves the session reaches real, Phase-2-compliant `CLEAN` under full live orchestration —
not merely `ok:true` at the wrapper-dispatch level.

## Receipt schedule construction

Both of this scenario's brand-new-thread dispatches (round 1's hollow attempt, and the restart) get
their own independent `RECEIPT_SCHEDULE_FILE` — generated LIVE, by whatever agent is actually
driving the `/ccs` session, using `SKILL.md`'s own exact procedure ("Receipt schedule generation":
`mktemp` + a 70-iteration `shasum -a 256`-derived token loop), at the exact point Phase 1 Step 0
calls for it. `setup.sh` deliberately does NOT pre-generate either schedule (an earlier revision of
this scenario did) — see "Live verification actually performed" below for why that distinction
matters and how the schedules were actually produced in the run this file now documents.

- **Round 1's schedule:** generated live, immediately before round 1's own fresh dispatch, and
  passed (`--receipt-schedule-file ... --receipt-slot 1`) for procedural fidelity — but its token
  value never matters for this scenario's outcome, since the wrapper's `material_reviewed:false`
  check (`run-ccs-review.sh`'s dedicated `elif` right after the `invalid_json` check) rejects the
  response before Phase 2 receipt validation is ever reached (Phase 2 only runs on `ok:true`
  responses).
- **The restart's schedule:** generated live, as its own separate, freshly-`mktemp`'d file, at the
  point `references/retry-guards.md`'s `no_material_reviewed` recovery calls for a fresh restart —
  never reusing round 1's abandoned schedule. The live driving agent reads slot 1's own real token
  off THIS file, right then, and bakes it into the restart's own `FAKE_CODEX_FINAL_ANSWER` as
  `material_receipt:"<that token>"` with `material_receipt_index:1`. Because the entity constructing
  the scripted response is the same entity that generated the schedule — exactly like a live
  orchestrating agent, which writes its own `RECEIPT_SCHEDULE_FILE` via `mktemp` before ever
  dispatching, and a real Codex would read that schedule out of its own prompt and echo the correct
  token back — this is a real, checkable match, not a guess and not `fake-codex` reading its own
  prompt (it never does; see its header comment). `fake-codex`'s inability to read its own prompt is
  irrelevant here: the DRIVER is what needs to know the schedule, and it does, because it wrote it.

A note on where "genuinely matching" was verified: the live run documented below performs
`SKILL.md`'s own Phase 2 step 1 check PROGRAMMATICALLY against the restart's real response —
extracting slot 1's token from the schedule file with `awk`/`sed`, extracting
`verdict.material_receipt`/`verdict.material_receipt_index` from the response with `jq`, and
comparing the two values with a real shell `if` test — not by eyeballing a side-by-side printout.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_SCENARIO=schema_mismatch`
with the `material_reviewed:false`+`ISSUES` answer below on round 1's dispatch only; unset that
`FAKE_CODEX_FINAL_ANSWER` override and set `FAKE_CODEX_SCENARIO=normal` with a fresh
`FAKE_CODEX_FINAL_ANSWER` carrying the restart's own genuine receipt pair for the restart's own
dispatch. `FAKE_CODEX_CLEANUP_OK=1` for both `--cleanup` calls. `FAKE_CODEX_INVOCATION_LOG` set to
the fixed path `setup.sh` prints (`/tmp/ccs-eval-material-reviewed-false-never-resumed-invocation.log`)
on every call. Both dispatches pass `--receipt-schedule-file`/`--receipt-slot 1`, per the
unconditional "every brand-new-thread dispatch gets one" rule in `SKILL.md`'s "Receipt schedule
generation" section — see "Receipt schedule construction" above for why only the restart's token
value is load-bearing.

## How to run

Invoke `codex-stream-review:ccs` against `REPO_DIR` (task text: "review the uncommitted change in
this fixture repo"), matching every other scenario's convention and `evals/run-evals.sh`'s own
expected flow (a real, multi-round Claude+Codex-style conversation, not a scripted harness):

```bash
bash codex-stream-review/evals/scenarios/material-reviewed-false-never-resumed/setup.sh
```

```bash
bash codex-stream-review/evals/check-result.sh <result.json> material-reviewed-false-never-resumed
```

## Manual walkthrough

1. **Round 1**: fresh `--uncommitted` dispatch, `--receipt-schedule-file <round-1 schedule>
   --receipt-slot 1`, `FAKE_CODEX_SCENARIO=schema_mismatch` with the `material_reviewed:false`+
   `ISSUES` answer above — real `threadId` (`A`) captured (a `schema_mismatch` failure still carries
   a `threadId`, per the existing reason table).
2. `references/retry-guards.md`'s `no_material_reviewed` rule fires (`detail` carries the literal
   substring `no_material_reviewed`): thread `A` is added to `LEAKED_THREAD_IDS`, never resumed.
3. Fresh restart (thread `B`, still round 1 — see "Targets" above), its own new
   `--receipt-schedule-file <restart schedule> --receipt-slot 1`, `FAKE_CODEX_SCENARIO=normal` with
   `material_reviewed:true` and a `material_receipt`/`material_receipt_index` pair that genuinely
   matches slot 1 of the restart's own schedule — succeeds, CLEAN, and a live agent's Phase 2 step 1
   check on this response finds a real match (not a null-pair rejection).
4. Confirm: `A` never appears in any `--resume` call in `FAKE_CODEX_INVOCATION_LOG`; the final
   `.result.json` names `A` as `"kind":"leaked"`/`"cleanup":"deleted"`; `B` is the session's own
   final, live thread (`"kind":"current"`/`"cleanup":"deleted"`); `claims` is `[]` (the hollow
   response's own finding was rejected wholesale before ever reaching the claim ledger — it never
   existed as a parsed verdict).

### Live verification actually performed (genuinely live, via the real Skill tool)

This section documents a run where `codex-stream-review:ccs` was invoked through the actual `Skill`
tool — `Skill({skill: "codex-stream-review:ccs", args: "review the uncommitted change in
<fixture repo path>"})` — which loaded `SKILL.md`'s real, full procedure inline into the driving
agent's own tool-call loop (not a separate subagent the driving agent couldn't control). Every Bash
call below was then made by hand, by that same agent, following the loaded procedure step by step,
in the real order a live session hits them — including generating BOTH receipt schedules live, at
the exact point Phase 1 Step 0 and `references/retry-guards.md`'s restart recovery respectively call
for them, never pre-baked by `setup.sh` (see "Receipt schedule construction" above for why that
distinction matters). This closes the gap a prior fix round left open: that round used a direct
`run-ccs-review.sh` dispatch (bypassing `/ccs` itself) plus a by-eye comparison; this run drove the
skill for real and checked the receipt programmatically.

**This is a redo of an earlier live run whose own JSONL evidence turned out to be non-compliant
with this file's own canonical JSONL shape** (`SKILL.md`'s example around its "Review history log"
section) — that earlier run's round-outcome line omitted `material_reviewed`/`material_receipt`/
`material_receipt_index` from `codex_review` despite the real wrapper response carrying them, and
its restart's own `PENDING:...` receipt record was never reconciled to the restart's real thread id
the way round 1's hollow-thread record correctly was. Both gaps were in how the driving agent wrote
the JSONL by hand, never in `run-ccs-review.sh`/`fake-codex`/`SKILL.md` themselves — this redo fixes
only the JSONL-construction discipline, keeping everything else (fixture shape, receipt-schedule
construction, `setup.sh`'s live-generation design) unchanged from the version described above.

**Fixture:** a real throwaway git repo (`eval_make_fixture_repo`) with one committed line and one
uncommitted appended line in `lib.py`, the fake-`codex` fixture prepended onto `PATH` on every Bash
call, `FAKE_CODEX_INVOCATION_LOG` re-exported on every call per the mechanical caveat.

1. **Phase 0/1 setup** — session id `2026-09-11T125428-10175`, repo root
   `/tmp/ccs-eval-material-reviewed-false-never-resumed.u7OxeT`, a real sizing pass (1 changed file
   → single-reviewer `GROUP="main"`), and a real snapshot hash of the diff (`SNAPSHOT_DIGEST`
   `f979c239deaba024486421eb2527249e8acf6a99b1844c8e8b4dce795ed4bd99`, a genuine 64-hex-char
   `shasum -a 256` value). `INSTALL_PATH` was pointed at this repo's own
   `codex-stream-review/scripts/run-ccs-review.sh` rather than the marketplace-cached plugin
   install, because that cached install (v1.0.6) predates the `material_reviewed`/`material_receipt`
   feature entirely (confirmed by `grep -n material_reviewed` against it returning nothing) — using
   it would have silently exercised the OLD wrapper, not the code this scenario exists to verify.
2. **Round 1's own receipt schedule generated live**, right before round 1's dispatch, via
   `SKILL.md`'s exact `mktemp` + 70-iteration `shasum -a 256` loop, then durably recorded as a
   `receipt_issued` JSONL line (`PENDING:ccs-2026-09-11T125428-10175-main-receipt-schedule.txt.94tLgP`,
   index 1) BEFORE the dispatch was ever constructed, per "Receipt slot issuance"'s own ordering
   requirement.
3. **Round 1 dispatch** (`--receipt-schedule-file <live-generated round-1 schedule>
   --receipt-slot 1`, `FAKE_CODEX_SCENARIO=schema_mismatch`, the `material_reviewed:false`+`ISSUES`
   answer): real response observed —
   ```json
   {"ok":false,"reason":"schema_mismatch","threadId":"b5678cce-46ae-4b73-9150-cbb6c6ff20eb","detail":"no_material_reviewed: material_reviewed is false","coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":1}}
   ```
   `detail` matches this scenario's own target exactly: the wrapper's dedicated
   `material_reviewed == false` check fires first, before the combined semantic check. Thread
   `A` = `b5678cce-46ae-4b73-9150-cbb6c6ff20eb`. The `PENDING:...` receipt record was then
   reconciled to this real thread id via a second JSONL line
   (`{"receipt_issued":{"thread_id":"b5678cce-46ae-4b73-9150-cbb6c6ff20eb","index":1,"reconciles":"PENDING:ccs-2026-09-11T125428-10175-main-receipt-schedule.txt.94tLgP"}}`),
   and `A` was recorded as leaked.
4. **Restart's own real receipt schedule generated live**, as its own separate freshly-`mktemp`'d
   file (`ccs-2026-09-11T125428-10175-main-restart-receipt-schedule.txt.FdNrT6`), per
   `references/retry-guards.md`'s recovery — never reusing round 1's schedule. Slot 1's real token
   was read off this file at that moment: `7f358ee934b448a0a1b3c4b4` (verified as exactly 24 raw
   bytes via `wc -c` before use). Its own PENDING `receipt_issued` line
   (`{"receipt_issued":{"thread_id":"PENDING:ccs-2026-09-11T125428-10175-main-restart-receipt-schedule.txt.FdNrT6","index":1}}`)
   was durably recorded before this dispatch was constructed, exactly mirroring round 1's own hollow
   thread's issuance pattern in step 2 above.
5. **Restart dispatch** (`--receipt-schedule-file <live-generated restart schedule>
   --receipt-slot 1`, `FAKE_CODEX_SCENARIO=normal`, `FAKE_CODEX_FINAL_ANSWER` constructed with `jq`
   (never hand-interpolated) carrying `material_receipt:"7f358ee934b448a0a1b3c4b4"` and
   `material_receipt_index:1`): real response observed —
   ```json
   {"ok":true,"threadId":"98d80a5b-381f-42a6-af43-e6656133202e","verdict":{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{...all not_applicable/checked...},"material_reviewed":true,"material_receipt":"7f358ee934b448a0a1b3c4b4","material_receipt_index":1},"coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":0}}
   ```
   Genuine new thread `B` = `98d80a5b-381f-42a6-af43-e6656133202e`, distinct from `A`, CLEAN. The
   restart's own PENDING receipt record from step 4 was then reconciled to this real thread id via a
   second JSONL line
   (`{"receipt_issued":{"thread_id":"98d80a5b-381f-42a6-af43-e6656133202e","index":1,"reconciles":"PENDING:ccs-2026-09-11T125428-10175-main-restart-receipt-schedule.txt.FdNrT6"}}`)
   — the reconciliation this scenario's earlier run left missing, now present and following the
   identical `(thread_id, index)` matching pattern as thread `A`'s own reconciliation in step 3.
6. **Programmatic Phase 2 step 1 check** (the check a live orchestrating agent performs on this
   response before ever accepting it) — not a by-eye comparison: extracted slot 1's token from the
   restart's own schedule file with `awk`, extracted `verdict.material_receipt`/
   `verdict.material_receipt_index` from the response with `jq`, and compared both with a real shell
   `if` test:
   ```
   expected slot=1 token=7f358ee934b448a0a1b3c4b4
   response   index=1 receipt=7f358ee934b448a0a1b3c4b4
   PHASE_2_STEP_1_RECEIPT_CHECK: MATCH -- accept as genuine CLEAN, proceed to convergence
   ```
   This is the concrete evidence that a fully live-orchestrated `/ccs` session — one that actually
   applies Phase 2 step 1 to the restart's response with a real comparison, not an assertion of
   success — reaches real, Phase-2-compliant `CLEAN` here, not just wrapper-level `ok:true`.
7. **Round 1's own JSONL line appended and verified** (`tail -n 1 <log> | jq -e '.round == 1'`
   returned `true`) to the real review-history log at
   `~/.claude/plugins/data/codex-stream-review/ccs-logs/ccs-eval-material-reviewed-false-never-resumed-u7oxet/2026-09-11T125428-10175.jsonl`,
   carrying `schema_version: 3`, `thread_id: "98d80a5b-381f-42a6-af43-e6656133202e"`,
   `coverage_source: {"status":"complete"}`, `round_outcome: "converged"`, and — carried verbatim
   into `codex_review` from the restart's own real response in step 5, closing the gap the earlier
   run left open — `"material_reviewed":true,"material_receipt":"7f358ee934b448a0a1b3c4b4","material_receipt_index":1`.
8. **`FAKE_CODEX_INVOCATION_LOG`** (`/tmp/ccs-eval-material-reviewed-false-never-resumed-invocation.log`),
   real contents observed after both dispatches plus both cleanups:
   ```
   mode=fresh thread_id=b5678cce-46ae-4b73-9150-cbb6c6ff20eb scenario=schema_mismatch
   mode=fresh thread_id=98d80a5b-381f-42a6-af43-e6656133202e scenario=normal
   mode=delete thread_id=98d80a5b-381f-42a6-af43-e6656133202e scenario=normal
   mode=delete thread_id=b5678cce-46ae-4b73-9150-cbb6c6ff20eb scenario=normal
   ```
   Exactly 2 `mode=fresh` lines (two distinct thread ids), **zero** `mode=resume` lines — direct,
   mechanical proof `A` was never `--resume`d.
9. **Cleanup** — `run-ccs-review.sh --cleanup <A>` and `--cleanup <B>` (`FAKE_CODEX_CLEANUP_OK=1`)
   both returned `{"ok":true,"threadId":"...","deleted":true}`.
10. **Resulting `.result.json`**, the actual file written at
    `~/.claude/plugins/data/codex-stream-review/ccs-logs/ccs-eval-material-reviewed-false-never-resumed-u7oxet/2026-09-11T125428-10175.result.json`
    (session-level fields assembled per `SKILL.md`'s Phase 3, from the real values above;
    schema-validated via `check-result.sh` against this scenario's own real, UNMODIFIED `expect.sh`,
    which reported `schema OK` / `assertions OK` / exit code 0):
    ```json
    {
      "session_id": "2026-09-11T125428-10175",
      "target": { "repo": "/tmp/ccs-eval-material-reviewed-false-never-resumed.u7OxeT", "scope": "uncommitted" },
      "exit_state": "CLEAN",
      "round_count": 1,
      "threads": [
        { "group": "main", "thread_id": "b5678cce-46ae-4b73-9150-cbb6c6ff20eb", "kind": "leaked", "cleanup": "deleted" },
        { "group": "main", "thread_id": "98d80a5b-381f-42a6-af43-e6656133202e", "kind": "current", "cleanup": "deleted" }
      ],
      "claims": [],
      "coverage": { "status": "complete", "reviewed_file_count": 1, "omitted": [] },
      "input_errors": null
    }
    ```

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `1` (the restart occupies round 1's own single slot —
  the hollow attempt never produced a valid round-1 result, so this is not a second round).
- `threads`: exactly one `"leaked"` entry (the abandoned hollow thread `A`) and exactly one
  `"current"` entry (the fresh restart's own new thread `B`) — both `cleanup: "deleted"`; `A` and
  `B` are different thread ids.
- `claims`: `[]` — the hollow response's own finding never entered the claim ledger.
- The fixed invocation log shows exactly 2 `mode=fresh` lines (two DIFFERENT `thread_id` values)
  and exactly **zero** `mode=resume` lines — mechanical proof the abandoned thread is never
  resumed, the one property this scenario exists to demonstrate.
- The restart's own `material_receipt`/`material_receipt_index` genuinely match slot 1 of its own
  fresh receipt schedule — a live orchestrating agent must remember to construct a genuinely
  matching receipt for the restart's own schedule, generated live at the point `SKILL.md`'s own
  Phase 1 Step 0 / `references/retry-guards.md` call for it (never pre-baked by `setup.sh` — see
  "Receipt schedule construction" above).

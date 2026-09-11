# Scenario: material-reviewed-false-never-resumed

**Group:** I (material verification / `no_material_reviewed` coverage).

**Targets:** `run-ccs-review.sh`'s `schema_mismatch` extension (Task 5/7 of
`docs/superpowers/plans/2026-09-10-ccs-material-verification.md`) — confirms `material_reviewed:false`
combined with a NONEMPTY `ISSUES` findings array is rejected exactly like the `CLEAN` case, closing
the specific gap an earlier design draft left open (checking only `material_reviewed:false` +
`CLEAN`, never `material_reviewed:false` + a real findings array). Confirms the resulting
`no_material_reviewed` failure is never resumed and instead triggers exactly one fresh restart on
a brand-new thread id, which still occupies round 1's own single slot (the hollow attempt never
produced a valid round-1 result — see `references/retry-guards.md`'s round-1-vs-round-2+
disambiguation).

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_SCENARIO=schema_mismatch`
with the `material_reviewed:false`+`ISSUES` answer below on round 1's dispatch only; unset
`FAKE_CODEX_FINAL_ANSWER` and set `FAKE_CODEX_SCENARIO=normal` for the restart's own dispatch.
`FAKE_CODEX_CLEANUP_OK=1` for both `--cleanup` calls. `FAKE_CODEX_INVOCATION_LOG` set to the fixed
path `setup.sh` prints (`/tmp/ccs-eval-material-reviewed-false-never-resumed-invocation.log`) on
every call. No `--receipt-slot`/`--receipt-schedule-file` flags are needed — the wrapper's
`material_reviewed:false` check (`run-ccs-review.sh` around line 1143) fires unconditionally, before
any receipt-schedule-dependent logic, confirmed directly against the wrapper's own source (see
"Live verification" below).

## How to run

```bash
bash codex-stream-review/evals/scenarios/material-reviewed-false-never-resumed/setup.sh
```

Then invoke `codex-stream-review:ccs` against `REPO_DIR`, task text:

> review the uncommitted change in this fixture repo

```bash
bash codex-stream-review/evals/check-result.sh <result.json> material-reviewed-false-never-resumed
```

## Manual walkthrough (live-verified, real evidence below)

1. **Round 1**: fresh `--uncommitted` dispatch, `FAKE_CODEX_SCENARIO=schema_mismatch` with the
   `material_reviewed:false`+`ISSUES` answer above — real `threadId` (`A`) captured (a
   `schema_mismatch` failure still carries a `threadId`, per the existing reason table).
2. `references/retry-guards.md`'s `no_material_reviewed` rule fires (`detail` carries the literal
   substring `no_material_reviewed`): thread `A` is added to `LEAKED_THREAD_IDS`, never resumed.
3. Fresh restart (thread `B`, still round 1 — see "Targets" above), `FAKE_CODEX_SCENARIO=normal` —
   succeeds, CLEAN.
4. Confirm: `A` never appears in any `--resume` call in `FAKE_CODEX_INVOCATION_LOG`; the final
   `.result.json` names `A` as `"kind":"leaked"`/`"cleanup":"deleted"`; `B` is the session's own
   final, live thread (`"kind":"current"`/`"cleanup":"deleted"`); `claims` is `[]` (the hollow
   response's own finding was rejected wholesale before ever reaching the claim ledger — it never
   existed as a parsed verdict).

### Live verification actually performed

Dispatched `run-ccs-review.sh` directly against a real throwaway git fixture (one committed line,
one uncommitted appended line), with the fake-`codex` fixture on `PATH`, exactly reproducing what
`/ccs`'s own Phase 1 Step 1 would run:

1. **Round 1** (`FAKE_CODEX_SCENARIO=schema_mismatch`, the `material_reviewed:false`+`ISSUES`
   answer): real response observed —
   ```json
   {"ok":false,"reason":"schema_mismatch","threadId":"ed673f1a-d09b-469b-8627-8823608a4b58","detail":"no_material_reviewed: material_reviewed is false","coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":0}}
   ```
   `detail` matches this scenario's own target exactly: the wrapper's dedicated
   `material_reviewed == false` check (`scripts/run-ccs-review.sh`, the `elif` immediately after the
   `invalid_json` check and before the big combined semantic check) fires first, distinguishing this
   case from an ordinary `schema_mismatch` — confirmed by reading that check's own ordering in the
   source before running it live. Thread `A` = `ed673f1a-d09b-469b-8627-8823608a4b58`.
2. **Restart** (`FAKE_CODEX_FINAL_ANSWER` unset, `FAKE_CODEX_SCENARIO=normal`, bare `--uncommitted`,
   no `--receipt-slot`/`--receipt-schedule-file`): real response observed —
   ```json
   {"ok":true,"threadId":"71c9a9aa-6285-45be-8c68-60d0f5e217c6","verdict":{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{...all not_applicable...},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null},"coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":0}}
   ```
   Genuine new thread `B` = `71c9a9aa-6285-45be-8c68-60d0f5e217c6`, distinct from `A`, CLEAN.
3. **`FAKE_CODEX_INVOCATION_LOG`** (`/tmp/ccs-eval-material-reviewed-false-never-resumed-invocation.log`),
   real contents observed after both dispatches plus both cleanups:
   ```
   mode=fresh thread_id=ed673f1a-d09b-469b-8627-8823608a4b58 scenario=schema_mismatch
   mode=fresh thread_id=71c9a9aa-6285-45be-8c68-60d0f5e217c6 scenario=normal
   mode=delete thread_id=ed673f1a-d09b-469b-8627-8823608a4b58 scenario=normal
   mode=delete thread_id=71c9a9aa-6285-45be-8c68-60d0f5e217c6 scenario=normal
   ```
   Exactly 2 `mode=fresh` lines (two distinct thread ids), **zero** `mode=resume` lines — direct,
   mechanical proof `A` was never `--resume`d.
4. **Cleanup** — `run-ccs-review.sh --cleanup <A>` and `--cleanup <B>` (`FAKE_CODEX_CLEANUP_OK=1`)
   both returned `{"ok":true,"threadId":"...","deleted":true}`.
5. **Resulting `.result.json`** (session-level fields assembled per `SKILL.md`'s Phase 3, from the
   real values above; schema-validated via `check-result.sh`, which reported `schema OK`, and this
   scenario's own `expect.sh`, which reported `assertions OK`):
   ```json
   {
     "session_id": "2026-09-11T000000-99999",
     "target": { "repo": "<fixture repo path>", "scope": "uncommitted" },
     "exit_state": "CLEAN",
     "round_count": 1,
     "threads": [
       { "group": "main", "thread_id": "ed673f1a-d09b-469b-8627-8823608a4b58", "kind": "leaked", "cleanup": "deleted" },
       { "group": "main", "thread_id": "71c9a9aa-6285-45be-8c68-60d0f5e217c6", "kind": "current", "cleanup": "deleted" }
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

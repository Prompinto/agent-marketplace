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

Both properties are verified at the **direct wrapper-dispatch level** — calling
`run-ccs-review.sh` directly, bypassing full `/ccs` skill orchestration — not via a live,
fully-orchestrated skill session. See "Scope of what this scenario actually proves" below for why
that distinction is load-bearing here, not incidental.

## Scope of what this scenario actually proves

This scenario's evidence was captured by dispatching `run-ccs-review.sh` directly, not by running
a live `codex-stream-review:ccs` skill session end-to-end.

- **Proven, mechanically, by the direct-dispatch evidence below:** the wrapper's own Task-5
  `material_reviewed:false` check rejects a NONEMPTY `ISSUES` findings array (not just `CLEAN`) as
  `schema_mismatch` with a `no_material_reviewed`-bearing `detail`; the abandoned thread never
  appears in a `--resume` call in the invocation log; the one fresh restart obtains a distinct new
  thread id.
- **NOT proven by this scenario, and not provable with the existing `fake-codex` fixture as-is:**
  that a FULLY live-orchestrated restart — one where a real Claude session applies `SKILL.md`'s
  Phase 2 step 1 receipt validation to the restart's own response — actually reaches `CLEAN`. Per
  `references/retry-guards.md`'s `no_material_reviewed` recovery section, the restart's fresh
  thread "gets its own fresh receipt schedule ... never reusing the abandoned thread's schedule" —
  i.e. it has an active schedule. Per `SKILL.md`'s Phase 2 step 1, an `ok:true` response from a
  thread with an active schedule whose `verdict.material_receipt`/`verdict.material_receipt_index`
  are BOTH `null` must be treated as ANOTHER `no_material_reviewed`, not accepted as `CLEAN`.
  `fake-codex`'s `normal` scenario never reads its own prompt/stdin (see its header comment), so it
  can only ever return the static `material_receipt:null, material_receipt_index:null` pair baked
  into `DEFAULT_VERDICT` — it can never dynamically echo a token matching a live
  `RECEIPT_SCHEDULE_FILE`. So a genuinely live-orchestrated run of this exact scripted sequence
  would NOT reach `CLEAN` on the restart: it would hit the null-pair rejection (the case the
  not-yet-built `receipt-null-pair-reject`, Task 14, is meant to cover) and, per
  `retry-guards.md`'s "restart fails for any reason" rule, the session would report
  `⚠️ COULD NOT VERIFY`, not `CLEAN`.
- This scenario's "restart reaches CLEAN" demonstration is therefore verified ONLY at the
  direct-wrapper-dispatch level (as actually performed below), not via full skill orchestration.
  Task 15 (`no-material-reviewed-fresh-restart`, not yet built) will need to independently resolve
  this same `fake-codex` limitation before it can claim a genuinely successful live-orchestrated
  restart to `CLEAN`.

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

**As actually verified** (see "Scope" above): dispatch `run-ccs-review.sh` directly against
`REPO_DIR`, reproducing what `/ccs`'s own Phase 1 Step 1 would run, per the sequence in "Direct
wrapper-dispatch walkthrough" below — this is a direct-dispatch scenario, not a live-skill one.

```bash
bash codex-stream-review/evals/scenarios/material-reviewed-false-never-resumed/setup.sh
```

If instead invoking `codex-stream-review:ccs` live against `REPO_DIR` (task text: "review the
uncommitted change in this fixture repo"), be aware the restart is expected to hit
`⚠️ COULD NOT VERIFY` rather than `CLEAN` under full Phase 2 orchestration — see "Scope" above.
This scenario's own `expect.sh`/`.result.json` evidence reflects the direct-dispatch run only.

```bash
bash codex-stream-review/evals/check-result.sh <result.json> material-reviewed-false-never-resumed
```

## Direct wrapper-dispatch walkthrough (live-verified, real evidence below; see "Scope" above)

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

At the direct-wrapper-dispatch level (see "Scope" above — not a claim about full live orchestration):

- `exit_state`: `"CLEAN"`, `round_count`: `1` (the restart occupies round 1's own single slot —
  the hollow attempt never produced a valid round-1 result, so this is not a second round).
- `threads`: exactly one `"leaked"` entry (the abandoned hollow thread `A`) and exactly one
  `"current"` entry (the fresh restart's own new thread `B`) — both `cleanup: "deleted"`; `A` and
  `B` are different thread ids.
- `claims`: `[]` — the hollow response's own finding never entered the claim ledger.
- The fixed invocation log shows exactly 2 `mode=fresh` lines (two DIFFERENT `thread_id` values)
  and exactly **zero** `mode=resume` lines — mechanical proof the abandoned thread is never
  resumed, the one property this scenario exists to demonstrate.

# Scenario: receipt-null-pair-reject

**Group:** I (material verification / `no_material_reviewed` coverage).

**Targets:** `SKILL.md`'s Phase 2 step 1 receipt-validation check (Task 8 of
`docs/superpowers/plans/2026-09-10-ccs-material-verification.md`) — confirms that a genuine
`material_receipt: null, material_receipt_index: null` response (Codex honestly reporting "I
cannot locate the schedule") from a thread that DOES have an active `RECEIPT_SCHEDULE_FILE` is
routed to `no_material_reviewed` via the SAME check as a value mismatch — "OR both fields are null
despite this thread genuinely having an active schedule" — never treated as a softer or separately
handled case. This closes out the third and final distinct trigger of the `no_material_reviewed`
mechanism: Task 12 covers the wrapper-level `material_reviewed:false` route,
`receipt-mismatch-phase2-reject` (Task 13) covers a Phase-2 value mismatch, and this scenario
covers a Phase-2 genuine null-pair.

This scenario's round 1 is structurally closer to `receipt-mismatch-phase2-reject` than to
`material-reviewed-false-never-resumed`: `material_reviewed:true` here (this is specifically
testing the null-pair path, not the `material_reviewed:false` path Task 12 already covers), and a
paired null-null receipt is schema-valid shape per `run-ccs-review.sh`'s own `schema_mismatch`
check (Task 5) — that check has no way to know whether THIS particular thread's schedule is
active, so it accepts the response as `ok:true` regardless. The rejection instead happens one
layer up, in the live orchestrating agent's own Phase 2 step 1 check, which alone knows (from its
own `RECEIPT_SCHEDULE_FILE` allocation and JSONL `receipt_issued` cursor) that this specific thread
genuinely has an active schedule and a null-pair response is therefore not a legitimate
"no schedule active" report but an honest miss that must still be treated as evidence of exactly
the failure mode this whole mechanism exists to catch.

Recovery is the SAME `no_material_reviewed` treatment as Tasks 12/13: abandon the hollow thread,
one bounded fresh restart (never `--resume`), reusing `references/compaction.md`'s own restart
mechanism per `references/retry-guards.md`.

## Receipt schedule construction

Both of this scenario's brand-new-thread dispatches (round 1's hollow attempt, and the restart) get
their own independent `RECEIPT_SCHEDULE_FILE` — generated LIVE, by whatever agent is actually
driving the `/ccs` session, using `SKILL.md`'s own exact procedure (`mktemp` + a 70-iteration
`shasum -a 256`-derived token loop), at the exact point Phase 1 Step 0 calls for it. `setup.sh`
deliberately does NOT pre-generate either schedule, exactly like `material-reviewed-false-never-resumed`'s
and `receipt-mismatch-phase2-reject`'s own `setup.sh` scripts — see those scenarios' READMEs for
why a schedule pre-baked by `setup.sh` would not be evidence that a live orchestrating agent's own
real procedure produced it.

- **Round 1's schedule:** generated live, immediately before round 1's own fresh dispatch, and
  passed (`--receipt-schedule-file ... --receipt-slot 1`) — this thread genuinely HAS an active
  schedule. The scripted response deliberately reports `material_receipt`/`material_receipt_index`
  as both `null` anyway — not a wrong value (Task 13's case), an ABSENT one — exactly the shape
  Codex would produce if it honestly failed to locate the schedule in its own context.
- **The restart's schedule:** generated live, as its own separate, freshly-`mktemp`'d file, at the
  point `references/retry-guards.md`'s `no_material_reviewed` recovery calls for a fresh restart —
  never reusing round 1's abandoned schedule. The live driving agent reads slot 1's own real token
  off THIS file and bakes it into the restart's own `FAKE_CODEX_FINAL_ANSWER` as
  `material_receipt:"<that token>"` with `material_receipt_index:1`, constructed with `jq`, never
  hand-interpolated.

The `DEFAULT_VERDICT` shortcut in `tests/fixtures/fake-codex` (confirmed independently, see below)
already sets `material_reviewed:true, material_receipt:null, material_receipt_index:null` — i.e. a
bare `FAKE_CODEX_SCENARIO=normal` dispatch with NO `FAKE_CODEX_FINAL_ANSWER` override would already
produce exactly the null-pair shape this scenario needs. This scenario deliberately still
constructs an explicit `FAKE_CODEX_FINAL_ANSWER` (via `jq`) instead of relying on that default,
because (a) it also needs to carry a fabricated `ISSUES` finding to prove that finding never leaks
into the session JSONL — a property the bare `DEFAULT_VERDICT` (`verdict:"CLEAN", findings:[]`)
cannot exercise — and (b) an explicit construction makes the test's own intent self-evident in the
script rather than depending on a fixture-internal default that could silently change later. Both
approaches are schema/behaviorally equivalent for the null-pair fields themselves; see "Mechanical
setup" below for the exact JSON actually used in the live run.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_SCENARIO=normal` for
BOTH dispatches (never `schema_mismatch` — this scenario's whole point is that the wrapper's own
`schema_mismatch` check has nothing to reject here, since a paired null-null receipt with
`material_reviewed:true` is a legitimate shape at the wrapper's level): round 1's
`FAKE_CODEX_FINAL_ANSWER` carries `material_reviewed:true`, `material_receipt:null`,
`material_receipt_index:null`, plus one fabricated `ISSUES` finding to prove it never leaks; the
restart's `FAKE_CODEX_FINAL_ANSWER` carries a genuinely matching `material_receipt`/
`material_receipt_index` pair for its own fresh schedule. `FAKE_CODEX_CLEANUP_OK=1` for both
`--cleanup` calls. `FAKE_CODEX_INVOCATION_LOG` set to the fixed path `setup.sh` prints
(`/tmp/ccs-eval-receipt-null-pair-reject-invocation.log`) on every call. Both dispatches pass
`--receipt-schedule-file`/`--receipt-slot 1`, per the unconditional "every brand-new-thread
dispatch gets one" rule in `SKILL.md`'s "Receipt schedule generation" section.

Round 1's dispatch ALSO passes `--keep-last-message "$ROUND1_LAST_MESSAGE_FILE"` (the fixed path
`setup.sh` prints, `/tmp/ccs-eval-receipt-null-pair-reject-round1-last-message.txt`) — `run-ccs-review.sh`'s
own `--keep-last-message <path>` flag is unconditionally available in its argument parser
(`scripts/run-ccs-review.sh`'s `--keep-last-message)` case), a best-effort copy of the round's raw
dispatched final-answer text made regardless of success/failure, and is entirely independent of the
skill's own session-level `--keep-evidence` gating — `SKILL.md`'s "only when `--keep-evidence` was
given" language describes a policy the skill's own automatic Phase 0 Step 0 decision imposes on
itself for a live `/ccs` session, not a restriction `run-ccs-review.sh` enforces. Since this
scenario's dispatches are driven manually (per "Manual walkthrough" below), this run does NOT turn
`--keep-evidence` on — doing so would additionally change cleanup-on-failure retention behavior
this scenario has no need for. The captured file lets `expect.sh` mechanically confirm round 1's
real content was the null-pair route (not Task 12's or Task 13's) — see "Known limitation" below.

## How to run

Invoke `codex-stream-review:ccs` against `REPO_DIR` (task text: "review the uncommitted change in
this fixture repo"), matching every other scenario's convention (a real, multi-round
Claude+Codex-style conversation, not a scripted harness):

```bash
bash codex-stream-review/evals/scenarios/receipt-null-pair-reject/setup.sh
```

```bash
bash codex-stream-review/evals/check-result.sh <result.json> receipt-null-pair-reject
```

## Manual walkthrough

1. **Round 1**: fresh `--uncommitted` dispatch, `--receipt-schedule-file <round-1 schedule>
   --receipt-slot 1 --keep-last-message "$ROUND1_LAST_MESSAGE_FILE"`, `FAKE_CODEX_SCENARIO=normal`
   with `material_reviewed:true`, `material_receipt:null`, `material_receipt_index:null`, plus one
   fabricated `ISSUES` finding — real `threadId` (`A`) captured; the wrapper returns `ok:true`
   (schema-valid: a paired null-null receipt with `material_reviewed:true` is a legitimate shape,
   so `schema_mismatch`, Task 5, has nothing to reject). `--keep-last-message` durably copies this
   dispatch's own raw final-answer content to `$ROUND1_LAST_MESSAGE_FILE` before the wrapper
   deletes its private copy — this is what lets `expect.sh` later prove which route genuinely
   fired.
2. A live orchestrating agent applying `SKILL.md`'s Phase 2 step 1 check to this response
   recognizes this thread genuinely has an active schedule (it just generated and passed one), yet
   the response reports both `material_receipt`/`material_receipt_index` as null. Per Phase 2 step
   1's own rule ("OR both fields are null despite this thread genuinely having an active
   schedule"), this response is treated IMMEDIATELY — before its findings are ever received,
   re-verified, or considered for convergence — as equivalent to `ok:false` with reason
   `no_material_reviewed`, identically to a wrong-value mismatch.
3. `references/retry-guards.md`'s `no_material_reviewed` rule fires: thread `A` is added to
   `LEAKED_THREAD_IDS`, never resumed.
4. Fresh restart (thread `B`, still round 1 — the hollow attempt never produced a valid round-1
   result), its own new `--receipt-schedule-file <restart schedule> --receipt-slot 1`,
   `FAKE_CODEX_SCENARIO=normal` with `material_reviewed:true` and a `material_receipt`/
   `material_receipt_index` pair that genuinely matches slot 1 of the restart's own schedule —
   succeeds, CLEAN, and Phase 2 step 1's check on this response finds a real, non-null match.
5. Confirm: `A` never appears in any `--resume` call in `FAKE_CODEX_INVOCATION_LOG`; the final
   `.result.json` names `A` as `"kind":"leaked"`/`"cleanup":"deleted"`; `B` is the session's own
   final, live thread (`"kind":"current"`/`"cleanup":"deleted"`); `claims` is `[]`; the fabricated
   finding from round 1's hollow response never appears anywhere in the session's own JSONL
   `codex_review.findings[]`.

### Live verification actually performed (genuinely live, via the real Skill tool)

**This replaces an earlier run (session `2026-09-11T141050-91272`) that predated the
`--keep-last-message` fix below** — that prior run's own round-1 dispatch never actually passed
`--keep-last-message` (a review round caught the bug: `setup.sh`'s printed dispatch instructions
had the flag's value backslash-escaped, `\$ROUND1_LAST_MESSAGE_FILE`, so a driver following them
literally would have interpolated nothing and passed an empty path), so its "Known limitation"
closure claim was itself unproven end to end. This section documents a fresh run, performed AFTER
fixing that escaping bug in `setup.sh` and tightening `expect.sh`'s type-strict checks (see this
scenario's own git history), that genuinely exercises the corrected mechanism.

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

0. **`DEFAULT_VERDICT` shortcut confirmed independently before relying on any decision about it**
   (see brief point 2): `grep -n "DEFAULT_VERDICT=" codex-stream-review/tests/fixtures/fake-codex`
   (line 263) showed
   `'{"verdict":"CLEAN","findings":[],...,"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}'`
   — confirmed the shortcut is real (a bare `FAKE_CODEX_SCENARIO=normal` dispatch with no override
   already produces the null-pair shape). This run still constructs an explicit
   `FAKE_CODEX_FINAL_ANSWER` (see "Receipt schedule construction" above for why: the fabricated
   finding needed for the leak-guard check isn't present in the bare default).
1. **Phase 0/1 setup** — session id `2026-09-11T143709-18808`, repo root
   `/tmp/ccs-eval-receipt-null-pair-reject.qlF1Rg`, a real sizing pass (1 changed file →
   single-reviewer `GROUP="main"`), and a real snapshot hash of the diff (`SNAPSHOT_DIGEST`
   `f979c239deaba024486421eb2527249e8acf6a99b1844c8e8b4dce795ed4bd99`, a genuine 64-hex-char
   `shasum -a 256` value — identical to the prior run's, since the fixture repo and its diff were
   reused unchanged from `setup.sh`'s own output). `INSTALL_PATH` was pointed at this repo's own
   `codex-stream-review/scripts/run-ccs-review.sh` rather than the marketplace-cached plugin
   install, because that cached install (v1.0.6) predates the `material_reviewed`/`material_receipt`
   feature entirely (confirmed by `grep -c material_reviewed` against it returning `0`, versus `9`
   against this repo's own script) — using it would have silently exercised the OLD wrapper, not
   the code this scenario exists to verify.
2. **Round 1's own receipt schedule generated live**, right before round 1's dispatch, via
   `SKILL.md`'s exact `mktemp` + 70-iteration `shasum -a 256` loop
   (`/tmp/ccs-2026-09-11T143709-18808-main-receipt-schedule.txt.zbdcZP`), then durably recorded as
   a `receipt_issued` JSONL line
   (`PENDING:ccs-2026-09-11T143709-18808-main-receipt-schedule.txt.zbdcZP`, index 1) BEFORE the
   dispatch was ever constructed. Slot 1's own real token on this schedule (never used — this
   scenario deliberately reports null instead): `efaacb7b878e324423b8ef77`.
3. **Round 1 dispatch** (`--receipt-schedule-file <live-generated round-1 schedule>
   --receipt-slot 1 --keep-last-message "/tmp/ccs-eval-receipt-null-pair-reject-round1-last-message.txt"`,
   `FAKE_CODEX_SCENARIO=normal`, a JSON verdict constructed with `jq` carrying
   `material_reviewed:true`, `material_receipt:null`, `material_receipt_index:null`, plus one
   fabricated `ISSUES` finding `{"file":"lib.py","line":3,"severity":"low","summary":"fabricated
   finding that must never leak into the session JSONL",...}`): real response observed —
   ```json
   {"ok":true,"threadId":"83924fd7-af2f-4246-9e53-e732025c0c6b","verdict":{"verdict":"ISSUES","findings":[{"file":"lib.py","line":3,"severity":"low","summary":"fabricated finding that must never leak into the session JSONL","evidence":"e","verification":"v"}],"summary":null,"dimensions":{...},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null},"coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":1}}
   ```
   `ok:true` confirms the exact distinction this scenario targets: the wrapper's own
   `schema_mismatch` check (Task 5) had nothing to reject — `material_reviewed` is `true`, and a
   paired null-null receipt is a legitimate shape at the wrapper's level, which cannot know
   whether THIS thread's schedule is active. Thread `A` = `83924fd7-af2f-4246-9e53-e732025c0c6b`.
   **This dispatch's own `--keep-last-message` flag genuinely fired this time** (the prior run's
   own dispatch never passed it at all — see the note above this section): the file
   `/tmp/ccs-eval-receipt-null-pair-reject-round1-last-message.txt` was read back directly from
   disk afterward and its real byte content is —
   ```json
   {"verdict":"ISSUES","findings":[{"file":"lib.py","line":3,"severity":"low","summary":"fabricated finding that must never leak into the session JSONL","evidence":"e","verification":"v"}],"summary":null,"dimensions":{"contracts":{"status":"not_applicable","evidence":"n/a"},"correctness":{"status":"checked","evidence":"reviewed add()"},"intent":{"status":"checked","evidence":"reviewed comment"},"performance":{"status":"not_applicable","evidence":"n/a"},"resources_concurrency":{"status":"not_applicable","evidence":"n/a"},"reuse":{"status":"not_applicable","evidence":"n/a"},"security":{"status":"not_applicable","evidence":"n/a"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
   ```
   — byte-identical (for the fields this scenario cares about) to the raw dispatched verdict above,
   confirming the corrected `setup.sh` heredoc genuinely produces a working dispatch instruction
   AND that `--keep-last-message` genuinely captures the round's own real content when actually
   used, not merely when hand-built as a synthetic fixture.
4. **Phase 2 step 1 check on round 1's response** — not a by-eye judgment call: the live
   orchestrating agent recorded that this thread genuinely has an active schedule (it just
   generated and durably issued one for slot 1), then read the response's own
   `verdict.material_receipt`/`verdict.material_receipt_index`, both `null`:
   ```
   thread A: active schedule confirmed (schedule file generated + receipt_issued index=1 recorded pre-dispatch)
   response   material_receipt=null material_receipt_index=null
   PHASE_2_STEP_1_RECEIPT_CHECK: NULL-PAIR despite active schedule -- treat as synthetic ok:false/no_material_reviewed, BEFORE step 2/3/convergence
   ```
   This is the concrete evidence that this rejection happens via a real check performed by the
   LIVE ORCHESTRATING AGENT itself — never something the wrapper's own response already flagged
   (its `"ok"` field is `true`) and never a by-eye assertion. The `PENDING:...` receipt record was
   then reconciled to this real thread id via a second JSONL line
   (`{"receipt_issued":{"thread_id":"83924fd7-af2f-4246-9e53-e732025c0c6b","index":1,"reconciles":"PENDING:ccs-2026-09-11T143709-18808-main-receipt-schedule.txt.zbdcZP"}}`),
   and `A` was recorded as leaked. Per `references/retry-guards.md`'s recovery, `A` is never
   `--resume`d.
5. **Restart's own real receipt schedule generated live**, as its own separate freshly-`mktemp`'d
   file (`ccs-2026-09-11T143709-18808-main-restart-receipt-schedule.txt.e6vmwL`), never reusing
   round 1's schedule. Slot 1's real token was read off this file at that moment:
   `be2277ebd060bb1565922e33`. Its own PENDING `receipt_issued` line
   (`{"receipt_issued":{"thread_id":"PENDING:ccs-2026-09-11T143709-18808-main-restart-receipt-schedule.txt.e6vmwL","index":1}}`)
   was durably recorded before this dispatch was constructed.
6. **Restart dispatch** (`--receipt-schedule-file <live-generated restart schedule>
   --receipt-slot 1`, `FAKE_CODEX_SCENARIO=normal`, `FAKE_CODEX_FINAL_ANSWER` constructed with `jq`
   carrying `material_receipt:"be2277ebd060bb1565922e33"` and `material_receipt_index:1`): real
   response observed —
   ```json
   {"ok":true,"threadId":"e22b9970-4a11-4bd2-9b6f-ac06337f14ba","verdict":{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{...all not_applicable/checked...},"material_reviewed":true,"material_receipt":"be2277ebd060bb1565922e33","material_receipt_index":1},"coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":1}}
   ```
   Genuine new thread `B` = `e22b9970-4a11-4bd2-9b6f-ac06337f14ba`, distinct from `A`, CLEAN. The
   restart's own PENDING receipt record from step 5 was then reconciled to this real thread id via
   a second JSONL line
   (`{"receipt_issued":{"thread_id":"e22b9970-4a11-4bd2-9b6f-ac06337f14ba","index":1,"reconciles":"PENDING:ccs-2026-09-11T143709-18808-main-restart-receipt-schedule.txt.e6vmwL"}}`).
7. **Phase 2 step 1 check on the restart's response** — same mechanism as step 4, applied to the
   restart:
   ```
   thread B: active schedule confirmed, expected slot=1 token=be2277ebd060bb1565922e33
   response   index=1 receipt=be2277ebd060bb1565922e33
   PHASE_2_STEP_1_RECEIPT_CHECK: MATCH -- accept as genuine CLEAN, proceed to convergence
   ```
   Concrete evidence that a fully live-orchestrated `/ccs` session — one that actually applies
   Phase 2 step 1 to the restart's response with a real comparison, not an assertion of success —
   reaches real, Phase-2-compliant `CLEAN` here, not just wrapper-level `ok:true`.
8. **Round 1's own JSONL line appended and verified** (`tail -n 1 <log> | jq -e '.round == 1'`
   returned `true`) to the real review-history log at
   `~/.claude/plugins/data/codex-stream-review/ccs-logs/ccs-eval-receipt-null-pair-reject-qlf1rg/2026-09-11T143709-18808.jsonl`,
   carrying `schema_version: 3`, `thread_id: "e22b9970-4a11-4bd2-9b6f-ac06337f14ba"` (the
   RESTART's real thread — never the abandoned hollow thread's), `coverage_source:
   {"status":"complete"}`, `round_outcome: "converged"`, `codex_review.findings: []` (the
   fabricated finding from round 1's hollow response — which DID exist in the raw wrapper
   response, per step 3 above — never appears here: it was rejected wholesale before ever being
   received/processed, per Phase 2 step 1's own ordering rule), and — carried verbatim from the
   restart's own real response — `"material_reviewed":true,"material_receipt":"be2277ebd060bb1565922e33","material_receipt_index":1`.
9. **`FAKE_CODEX_INVOCATION_LOG`** (`/tmp/ccs-eval-receipt-null-pair-reject-invocation.log`),
   real contents observed after both dispatches plus both cleanups:
   ```
   mode=fresh thread_id=83924fd7-af2f-4246-9e53-e732025c0c6b scenario=normal
   mode=fresh thread_id=e22b9970-4a11-4bd2-9b6f-ac06337f14ba scenario=normal
   mode=delete thread_id=e22b9970-4a11-4bd2-9b6f-ac06337f14ba scenario=normal
   mode=delete thread_id=83924fd7-af2f-4246-9e53-e732025c0c6b scenario=normal
   ```
   Exactly 2 `mode=fresh` lines (two distinct thread ids), **zero** `mode=resume` lines — direct,
   mechanical proof `A` was never `--resume`d, and both dispatches were genuinely `ok:true` at the
   wrapper level (`scenario=normal` on both, never `schema_mismatch` — confirming this scenario's
   central distinction from Task 12).
10. **Cleanup** — `run-ccs-review.sh --cleanup <B>` and `--cleanup <A>` (`FAKE_CODEX_CLEANUP_OK=1`)
    both returned `{"ok":true,"threadId":"...","deleted":true}`.
11. **Resulting `.result.json`**, the actual file written at
    `~/.claude/plugins/data/codex-stream-review/ccs-logs/ccs-eval-receipt-null-pair-reject-qlf1rg/2026-09-11T143709-18808.result.json`
    (session-level fields assembled per `SKILL.md`'s Phase 3, from the real values above;
    schema-validated via `check-result.sh` against this scenario's own real, UNMODIFIED `expect.sh`,
    which reported `schema OK` / `assertions OK` / exit code 0):
    ```json
    {
      "session_id": "2026-09-11T143709-18808",
      "target": { "repo": "/tmp/ccs-eval-receipt-null-pair-reject.qlF1Rg", "scope": "uncommitted" },
      "exit_state": "CLEAN",
      "round_count": 1,
      "threads": [
        { "group": "main", "thread_id": "83924fd7-af2f-4246-9e53-e732025c0c6b", "kind": "leaked", "cleanup": "deleted" },
        { "group": "main", "thread_id": "e22b9970-4a11-4bd2-9b6f-ac06337f14ba", "kind": "current", "cleanup": "deleted" }
      ],
      "claims": [],
      "coverage": { "status": "complete", "reviewed_file_count": 1, "omitted": [] },
      "input_errors": null
    }
    ```

12. **Finding-2 malformed-input sanity checks re-run against the tightened, type-strict
    `expect.sh`** (see "Mechanical fixes" below): with the genuine kept last-message file above
    temporarily mutated to `material_receipt: false` (a JSON boolean, not `null`),
    `check-result.sh` correctly **FAILED** — `"round 1's own kept dispatched content: material_receipt
    (must be the JSON null...): expected [null], got [not_null_or_missing]"`. With
    `material_reviewed` deleted from that same file entirely, `check-result.sh` also correctly
    **FAILED** — `"...material_reviewed (must be the JSON boolean true...): expected [true], got
    [false]"`. The genuine file was then restored and `check-result.sh` passed again
    (`schema OK` / `assertions OK`, exit 0), confirming these checks now discriminate malformed
    input rather than vacuously passing it (the exact gap a review round found in the prior,
    loosely-typed `// "null"`-fallback checks).

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
  resumed, and both dispatches were genuine `scenario=normal` `ok:true` wrapper responses.
- The restart's own `material_receipt`/`material_receipt_index` genuinely match slot 1 of its own
  fresh receipt schedule — a live orchestrating agent must remember to construct a genuinely
  matching receipt for the restart's own schedule, generated live at the point `SKILL.md`'s own
  Phase 1 Step 0 / `references/retry-guards.md` call for it (never pre-baked by `setup.sh`).
- Round 1's own kept last-message file (`$ROUND1_LAST_MESSAGE_FILE`) carries
  `material_reviewed:true`, `material_receipt:null`, `material_receipt_index:null` — round 1's real
  dispatched content, proving this route (not Task 12's `material_reviewed:false` or Task 13's
  non-null wrong-value mismatch) genuinely fired.

## Known limitation

A prior review round raised a real gap: without inspecting round 1's own dispatched content, the
JSONL/invocation-log artifacts alone (one leaked + one current thread, both cleaned up, a matching
restart receipt) are structurally IDENTICAL across all three `no_material_reviewed` trigger routes
— Task 12's wrapper-level `material_reviewed:false` rejection, Task 13's Phase-2 value mismatch,
and this scenario's own genuine null-pair — so nothing durable could mechanically prove which of
the three actually fired. This is now closed: round 1's dispatch passes `run-ccs-review.sh`'s own
standalone `--keep-last-message` flag (see "Mechanical setup" above), and `expect.sh` asserts that
captured file's content is exactly this scenario's own null-pair shape, via type-strict `has()` +
`type` checks (mirroring `run-ccs-review.sh`'s own semantic-validation pattern) rather than a
loosely-typed `// "null"` fallback that would conflate a missing field, a `false` boolean, and a
genuine `null` — confirmed to actually discriminate malformed input, not merely pass it vacuously
(see step 12 above). A second review round separately caught (and this fixed) a heredoc
variable-interpolation bug in `setup.sh` itself: the printed dispatch instructions had
`--keep-last-message`'s own path backslash-escaped, so a driver following them literally would
never have passed the flag at all — the "Live verification actually performed" run above was
entirely redone from scratch after that fix, genuinely exercising the corrected instructions (see
the note at the top of that section). Combined with the
structural checks (exactly one leaked + one current thread, the fabricated finding never
persisted, exact receipt reconciliation), `expect.sh` now mechanically proves both WHAT structural
outcome resulted AND WHICH route produced it.

What remains a genuine, deliberate limitation (identical to what `receipt-mismatch-phase2-reject`'s
own README discloses for its value-mismatch case): `expect.sh` still cannot re-verify that round
1's own thread genuinely HAD an active schedule at the moment the live orchestrating agent
recognized the null-null pair as a rejection rather than a legitimate no-schedule-active report.
This is narrower than "no durable artifact ever holds a schedule-derived value at all" — that
claim would be FALSE: the restart's own real, non-null `material_receipt` token (e.g.
`be2277ebd060bb1565922e33` in the live run above) IS durably persisted in the JSONL, per
`SKILL.md`'s documented `codex_review` schema, and this scenario's own checks above verify it
landed there intact. The actual, narrower gap is twofold: (1) there is no INDEPENDENTLY COMMITTED
*expected* value recorded at issuance time (e.g. alongside the `PENDING:...` `receipt_issued`
line) to compare a response's receipt against after the fact — so nothing proves the ACCEPTED
round's persisted receipt genuinely matches what the schedule actually demanded, as opposed to
some other coincidentally-valid-looking value — and (2) round 1's own null-pair response is never
separately persisted in the JSONL at all (a hollow response is never given its own `codex_review`
record, by this scenario's own established design — see the `round==1` count check above), so
there is no durable JSONL record of round 1's OWN receipt fields to inspect either way; that is
exactly what `--keep-last-message`'s capture (added by an earlier fix round to this scenario,
see this file's own git history) exists to substitute for, mechanically, going forward. `SKILL.md`'s "Receipt schedule generation" section deliberately
guarantees `RECEIPT_SCHEDULE_FILE` content itself (the raw candidate tokens for every slot, not
just whichever one a response reports back) is never included in any `FOCUS_FILE`, never excerpted
into JSONL History text, and never part of any JSONL line — a confidentiality property of the
schedule's own raw contents, not of receipt VALUES a response actually echoes back (those ARE
meant to be persisted, as ordinary `material_receipt` data). So a checker reading the JSONL after
the fact can confirm the accepted round's receipt value is present and well-formed, and (via
`--keep-last-message`) can now confirm round 1's own dispatched content was genuinely this
scenario's null-pair shape — but cannot independently confirm the accepted receipt was actually the
value the live schedule demanded (no separately-committed expected value exists to compare
against), since `SKILL.md`'s confidentiality guarantee excludes the schedule's own raw candidate
tokens from any LIVE-SESSION artifact (`FOCUS_FILE`, JSONL History text, any JSONL line) that a
future automated checker could inspect after the fact. This scenario's own build-time narrative
below is a separate, one-time, hand-written disclosure — not a live-session artifact `expect.sh`
itself could ever re-derive or check against — so it does not weaken or contradict that guarantee;
it simply means a human reader has one-time evidence a future automated run cannot reconstruct.
Absent
a future commitment-based scheme (see `receipt-mismatch-phase2-reject`'s own "Known limitation"
section for the fuller discussion, and this session's own persistent memory tracking a related open
idea — `ccs_backlog_from_real_usage_feedback.md`'s "Candidate 5"), that narrower gap's only evidence
is the one-time, hand-written build-time narrative in "Live verification actually performed" above
(steps 4 and 7), which recorded the real schedule tokens and the real check output at the time this
scenario was built — a separate, deliberate disclosure for human readers, not a session artifact,
and recording it there does not contradict or weaken the production feature's own confidentiality
guarantee for a live session's own ongoing operation.

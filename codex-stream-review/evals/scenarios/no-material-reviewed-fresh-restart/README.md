# Scenario: no-material-reviewed-fresh-restart

**Group:** I (material verification / `no_material_reviewed` coverage).

**Targets:** confirms `references/retry-guards.md`'s `no_material_reviewed` recovery genuinely
reuses `references/compaction.md`'s COMPLETE restart mechanism — not merely "a new thread gets
created" — by establishing one real RESOLVED claim and one real still-OPEN claim across a real
multi-round session, THEN triggering `no_material_reviewed`, THEN confirming the fresh restart's
own new-thread seed genuinely carries that digest forward (the open claim verbatim, the resolved
claim collapsed to its one-line `DISPOSITION` reason) and that snapshot-integrity revalidation
runs identically to an ordinary round.

This is the structural complement to `material-reviewed-false-never-resumed` (Task 12): that
scenario's hollow attempt fires on the group's very first-ever dispatch, so the restart occupies
round 1's own single slot and there is no prior claim-ledger state to carry forward at all. This
scenario instead lets TWO real rounds complete successfully first — one claim gets genuinely
resolved, one stays genuinely open — before the THIRD round goes hollow, so the restart's own
`COMPACT_DIGEST` construction (`references/compaction.md`'s "Digest construction and
verification" section, reused as-is per `references/retry-guards.md`) has real, non-trivial state
to prove it actually carried forward, and the restart occupies round 3's own slot, never round 1's
(`references/retry-guards.md`: "REGARDLESS of what session round number it occurs at").

## Fixture

A real throwaway git repo (`git init` + one committed line) whose uncommitted diff carries TWO
genuine bugs in `lib.py`:

```python
def add(a, b):
    # deliberate off-by-one for eval fixtures
    return a + b + 1


def sub(a, b):
    # deliberate off-by-one for eval fixtures
    return a - b - 1
```

against a committed baseline of just `def add(a, b): return a + b`. `f1` = `add()`'s `+ 1` (line
3), `f2` = `sub()`'s `- 1` (line 8 — `sub()` does not exist in the committed baseline at all, so
this is a genuinely new, genuinely buggy function introduced by the diff).

## Receipt schedule construction

Both of this scenario's brand-new-thread dispatches (round 1's fresh dispatch establishing thread
A, and the restart establishing thread B) get their own independent `RECEIPT_SCHEDULE_FILE` —
generated LIVE, by whatever agent is actually driving the `/ccs` session, using `SKILL.md`'s own
exact procedure (`mktemp` + a 70-iteration `shasum -a 256`-derived token loop), at the exact point
Phase 1 Step 0 / `references/retry-guards.md`'s restart recovery call for it. `setup.sh`
deliberately does NOT pre-generate either schedule or pre-populate any `FAKE_CODEX_GROUP_STATE`
round-N-final-answer.json file, exactly like `material-reviewed-false-never-resumed`'s own
`setup.sh` — see that scenario's README for why a schedule or answer pre-baked by `setup.sh` would
not be evidence that a live orchestrating agent's own real procedure produced it. Thread A's
schedule is reused, unmodified, across rounds 1, 2, and round 3's own hollow attempt (slots 1, 2,
3 respectively) — the ordinary "one schedule per thread, incrementing slot per dispatch" rule; only
a brand-new thread ever gets a brand-new schedule.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_GROUP_STATE` must be set
on every dispatch call sharing the SAME directory (all four dispatches — round 1, round 2, round
3's hollow attempt, and the restart — advance the same counter, exactly like
`claim-clean-resolution`'s own multi-round mechanism). `FAKE_CODEX_SCENARIO` is set explicitly on
every dispatch call: `normal` for rounds 1, 2, and the restart; `schema_mismatch` for round 3's own
hollow attempt only. `FAKE_CODEX_CLEANUP_OK=1` for both `--cleanup` calls.
`FAKE_CODEX_INVOCATION_LOG` set to the fixed path `setup.sh` prints
(`/tmp/ccs-eval-no-material-reviewed-fresh-restart-invocation.log`) on every call. Round 1 and the
restart each pass `--receipt-schedule-file`/`--receipt-slot 1` (brand-new threads); rounds 2 and
3's hollow attempt pass only `--receipt-slot <N>` (continuing thread A's existing schedule, per the
unconditional "every dispatch to a thread with an active schedule carries `--receipt-slot`, but
`--receipt-schedule-file` only on the dispatch that first establishes it" rule).

## How to run

```bash
bash codex-stream-review/evals/scenarios/no-material-reviewed-fresh-restart/setup.sh
```

```bash
bash codex-stream-review/evals/check-result.sh <result.json> no-material-reviewed-fresh-restart
```

## Manual walkthrough

1. **Round 1** (fresh `--uncommitted`, thread A): `ISSUES` with two real findings, `f1` (`add()`
   off-by-one) and `f2` (`sub()` off-by-one) — both genuinely present in the fixture's real diff.
2. Between round 1 and round 2: `f1` is fixed for real (`add()`'s `+ 1` removed); `f2`/`sub()` is
   left broken. Per `references/claim-ledger.md`'s "When to ask" condition (b) (a fix was just
   applied in direct response to round 1's finding), round 2's own focus text explicitly names
   `f1` and requests a `DISPOSITION` marker. `f2` is NOT asked about yet — condition (a) does not
   fire for it: it was still an actively-disputed, currently-appearing finding in round 1, the
   round evaluated at this construction point.
3. **Round 2** (`--resume`, thread A): `CLEAN`, `findings: []`, summary carries
   `DISPOSITION f1: RESOLVED -- ...`. This closes `f1`. Because `f2` has no `claim_closures` entry,
   the claim-ledger-closure convergence condition still fails even though Codex's own verdict says
   `CLEAN` — the session continues to round 3. This is an ordinary "keep going" continuation, never
   a `⚠️ NOT CONVERGED` oscillation stop (no open claim was ever reasserted with
   `evidence_delta:"none"`).
4. Round 3's own original focus text (before it goes hollow), evaluated against round 2 (the most
   recently completed round): `f2` did NOT appear in round 2's findings, so condition (a) now
   fires — this round's focus explicitly names `f2` and requests its own `DISPOSITION` marker too.
5. **Round 3 attempt** (`--resume`, thread A): the same round-2+ snapshot revalidation that always
   runs first passes (nothing has touched `SNAPSHOT_FILE`). The dispatch is scripted to return
   `material_reviewed:false` with a nonempty `ISSUES` finding (the wrapper-level route, mirroring
   `material-reviewed-false-never-resumed`'s own Task-12 design) — `detail` carries the literal
   substring `no_material_reviewed`. `references/retry-guards.md`'s recovery fires: thread A is
   added to `LEAKED_THREAD_IDS`, never resumed again. This hollow attempt is never separately
   persisted to the session's own JSONL log.
6. **Restart** (fresh `--uncommitted`, thread B — never `--resume`): `f2` is fixed for real too
   (`sub()`'s `- 1` removed) before dispatching. The live driving agent builds `COMPACT_DIGEST` via
   `references/compaction.md`'s own "Digest construction and verification" procedure (structured
   data first: the reducer's open-claim-id set is `{f2}`, since `f1` has a `claim_closures` entry
   and `f2` does not; resolve `f2`'s most-recent-occurrence fields — its only occurrence is round
   1's own finding; verify structurally BEFORE rendering any prose), then constructs the restart's
   own focus text in `references/compaction.md`'s own Step-4 order: (1) `COMPACT_DIGEST`, (2) the
   original Why/Scope read from `target.original_scope_framing` (never `target.focus`), (3) the
   standard `⚠️ SCOPE CONSTRAINT` block, (4) the same fixed collaboration-frame sentence, (5) a
   `DISPOSITION` request for `f2` (evaluated against thread A's own most recently completed
   round — round 2). Dispatched fresh, with its own new, independent
   `RECEIPT_SCHEDULE_FILE`, to a brand-new thread B. Scripted response: `CLEAN`,
   `findings: []`, `DISPOSITION f2: RESOLVED -- ...`. This closes `f2`. Both `f1` and `f2` now have
   terminal dispositions, and this round genuinely re-collects `--uncommitted` coverage
   (`coverage_source: {"status":"complete"}`) — convergence holds. Session reaches `CLEAN` at round
   3 (the restart occupies round 3's own slot, never round 1's).
7. Confirm: thread A (rounds 1-2, plus round 3's own hollow attempt) is abandoned
   (`"kind":"leaked"`); thread B (the restart) is the session's own final, live thread
   (`"kind":"current"`); both `"cleanup":"deleted"`; round 3's own `target.focus` (read back from
   the durable JSONL log) contains BOTH `f1`'s one-line `RESOLVED` reason AND `f2`'s own full
   verbatim `summary`/`evidence` text — never a blank/reset digest; thread B's id is distinct from
   thread A's.

### Live verification actually performed (genuinely live, via direct `run-ccs-review.sh` dispatch)

This section documents a real run driven by hand, following `SKILL.md`'s own Phase 0-3 procedure
step by step, in the real order a live session hits them, against this repo's own
`codex-stream-review/scripts/run-ccs-review.sh` (never a marketplace-cached install) with the
fake-`codex` fixture prepended onto `PATH`. Every schedule, digest, and focus text below was
constructed live, at the exact point the real procedure calls for it — never pre-baked.

1. **Phase 0/1 setup** — session id `2026-09-11T152517-8899`, repo root
   `/tmp/ccs-eval-no-material-reviewed-fresh-restart.3hpLOe`, single-reviewer `GROUP="main"`, a
   real snapshot hash of round 1's own diff (`SNAPSHOT_DIGEST`
   `1bddd0324b6eb9d4d3eea86cc1effcf03339d706f8182cce78fcc2f895564824`, a genuine 64-hex-char
   `shasum -a 256` value over the real `git diff --no-ext-diff --no-textconv HEAD` output plus the
   (empty) untracked-file listing). `target.original_scope_framing` captured once, unconditionally,
   at round 1:
   ```
   Why: review the uncommitted change in this fixture repo for correctness issues before it lands.
   Scope: this diff touches lib.py's two arithmetic helper functions (add, sub) -- verify each
   function's return value actually matches its own name/contract, and flag any off-by-one or
   sign error introduced by this change.
   ```
2. **Thread A's receipt schedule generated live** (`/tmp/ccs-2026-09-11T152517-8899-main-receipt-schedule.txt.zgAFc5`,
   71 lines, `REVIEW_RECEIPT_SCHEDULE` header + 70 tokens), its `PENDING:...` `receipt_issued` line
   durably recorded (index 1) BEFORE round 1's own dispatch was ever constructed. Slot 1's real
   token: `dfe0f24140c198724759d752`.
3. **Round 1 dispatch** (`--receipt-schedule-file <thread A's schedule> --receipt-slot 1`,
   `FAKE_CODEX_SCENARIO=normal`, findings for both `f1` and `f2`, `material_receipt` set to slot
   1's real token): real response observed —
   ```json
   {"ok":true,"threadId":"28ceee32-2f20-41b5-b48f-b0f1810acdba","verdict":{"verdict":"ISSUES","findings":[{"file":"lib.py","line":3,"severity":"medium","summary":"add() returns a+b+1, an off-by-one error", ...},{"file":"lib.py","line":8,"severity":"medium","summary":"sub() returns a-b-1, an off-by-one error", ...}],"material_reviewed":true,"material_receipt":"dfe0f24140c198724759d752","material_receipt_index":1},"coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":0}}
   ```
   Thread `A` = `28ceee32-2f20-41b5-b48f-b0f1810acdba`. The `PENDING:...` receipt record was
   reconciled to this real thread id via a second JSONL line. Round 1's own JSONL round-outcome
   line was appended (`schema_version: 3`, `round_outcome: "continue"`, `codex_review.findings`
   carrying both `f1`/`f2` verbatim, `claude_verification` accepting both).
4. **Real fix for `f1` applied** — `lib.py`'s `add()` edited from `return a + b + 1` to
   `return a + b`; `sub()` left untouched (still `return a - b - 1`).
5. **Round 2's own receipt slot issued live** (slot 2 of thread A's SAME schedule — no new
   schedule; thread A already has one), token `f650aaca684e8cce8e407f00`, durably recorded before
   dispatch. **Round 2 dispatch** (`--resume 28ceee32-... --receipt-slot 2`,
   `FAKE_CODEX_SCENARIO=normal`, `findings: []`, `summary` carrying
   `DISPOSITION f1: RESOLVED -- ...`): real response observed —
   ```json
   {"ok":true,"threadId":"28ceee32-2f20-41b5-b48f-b0f1810acdba","verdict":{"verdict":"CLEAN","findings":[],"summary":"DISPOSITION f1: RESOLVED -- lib.py now reads 'return a + b', the extra +1 has been removed and add() matches its intended contract.","material_reviewed":true,"material_receipt":"f650aaca684e8cce8e407f00","material_receipt_index":2},"execution":{"elapsed_seconds":2}}
   ```
   Round 2's own JSONL line appended: `claim_closures: [{"claim_id":"f1","disposition":"resolved","source_round":2,"marker_reason":"lib.py now reads 'return a + b', the extra +1 has been removed and add() matches its intended contract."}]`, `round_outcome: "continue"` (Codex's own `CLEAN` verdict is NOT
   enough — `f2` is still open with no closure, so the claim-ledger-closure convergence condition
   fails and the loop continues).
6. **Round-2+ snapshot revalidation for round 3** — re-hashed the live `SNAPSHOT_FILE` against the
   remembered `SNAPSHOT_DIGEST`: `SNAPSHOT_INTEGRITY_OK` (nothing had touched it).
7. **Round 3's own receipt slot issued live** (slot 3 of thread A's SAME schedule), durably
   recorded before dispatch. **Round 3 attempt** (`--resume 28ceee32-... --receipt-slot 3`,
   `FAKE_CODEX_SCENARIO=schema_mismatch`, `material_reviewed:false` with one fabricated `ISSUES`
   finding): real response observed —
   ```json
   {"ok":false,"reason":"schema_mismatch","threadId":"28ceee32-2f20-41b5-b48f-b0f1810acdba","detail":"no_material_reviewed: material_reviewed is false","execution":{"elapsed_seconds":1}}
   ```
   `detail` matches this scenario's own target exactly. Thread `A` added to `LEAKED_THREAD_IDS`,
   never resumed again. No JSONL line was ever written for this hollow attempt.
8. **`COMPACT_DIGEST` built live**, per `references/compaction.md`'s own procedure, from the
   durable JSONL log's own reducer state (a real `jq` query over the log, not a hand-written
   guess): open-claim-id set = `{"f2"}` (structured data — `claude_verification[].claim_id`
   values minus `claim_closures[].claim_id` values), resolved to
   `{"claim_id":"f2","file":"lib.py","line":8,"severity":"medium","summary":"sub() returns a-b-1, an off-by-one error","evidence":"lib.py line 8 reads *** return a - b - 1 *** -- a function named sub should return a-b, not a-b-1"}`
   (round 1's own finding — `f2`'s only occurrence). Both the key check (1 resolved object == 1
   open id, `{"f2"}` == `{"f2"}`) and the content-completeness check (all fields present as the
   right types) passed before any prose was rendered. Closed-claim section: `f1`'s own
   `claim_closures[0].marker_reason` collapsed to one line. Rendered digest (byte-exact, read back
   from the real JSONL log after the restart's own line was appended):
   ```
   COMPACT_DIGEST

   CLOSED CLAIMS:
   f1 -- RESOLVED (round 2): lib.py now reads 'return a + b', the extra +1 has been removed and add() matches its intended contract.

   OPEN CLAIMS:
   OPEN CLAIM f2:
   file: lib.py
   line: 8
   severity: medium
   summary: sub() returns a-b-1, an off-by-one error
   evidence: lib.py line 8 reads *** return a - b - 1 *** -- a function named sub should return a-b, not a-b-1
   Most recent action: accept -- confirmed live: lib.py line 8 reads return a - b - 1, sub() should return a - b.
   ```
9. **Real fix for `f2` applied** — `lib.py`'s `sub()` edited from `return a - b - 1` to
   `return a - b`.
10. **Restart's own receipt schedule generated live**, as its own separate, freshly-`mktemp`'d
    file (`/tmp/ccs-2026-09-11T152517-8899-main-restart-receipt-schedule.txt.cvbsTS`), never
    reusing thread A's. Slot 1's real token: `88a30e2e18b2d4efc3702955`. Its own `PENDING:...`
    `receipt_issued` line durably recorded before dispatch. **Restart dispatch** (fresh
    `--uncommitted`, `--receipt-schedule-file <restart schedule> --receipt-slot 1`,
    `FAKE_CODEX_SCENARIO=normal`, `findings: []`, `summary` carrying
    `DISPOSITION f2: RESOLVED -- ...`, `material_receipt` set to slot 1's real token, focus text =
    `COMPACT_DIGEST` (step 8) + the original Why/Scope (step 1) + the SCOPE CONSTRAINT block + the
    collaboration-frame sentence + a `DISPOSITION` request for `f2`): real response observed —
    ```json
    {"ok":true,"threadId":"963608c2-3bf8-45d1-8c32-d2d5a94e7f48","verdict":{"verdict":"CLEAN","findings":[],"summary":"DISPOSITION f2: RESOLVED -- lib.py now reads 'return a - b', the extra -1 has been removed and sub() matches its intended contract.","material_reviewed":true,"material_receipt":"88a30e2e18b2d4efc3702955","material_receipt_index":1},"coverage":{"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}},"execution":{"elapsed_seconds":1}}
    ```
    Genuine new thread `B` = `963608c2-3bf8-45d1-8c32-d2d5a94e7f48`, distinct from `A`, `CLEAN`.
    The `PENDING:...` receipt record was reconciled to this real thread id. Round 3's own JSONL
    line appended: `thread_id: B`, `target.scope: "uncommitted"` (never `"resume"` — this restart
    is a genuinely fresh dispatch, per `references/retry-guards.md`), `target.focus` = the full
    digest+framing text above, `coverage_source: {"status":"complete"}`,
    `claim_closures: [{"claim_id":"f2","disposition":"resolved","source_round":3,"marker_reason":"lib.py now reads 'return a - b', the extra -1 has been removed and sub() matches its intended contract."}]`,
    `round_outcome: "converged"` (both `f1` and `f2` now terminal, Codex's own verdict `CLEAN`, a
    genuinely fresh `--uncommitted` coverage report).
11. **`FAKE_CODEX_INVOCATION_LOG`**
    (`/tmp/ccs-eval-no-material-reviewed-fresh-restart-invocation.log`), real contents observed
    after all four dispatches plus both cleanups:
    ```
    mode=fresh thread_id=28ceee32-2f20-41b5-b48f-b0f1810acdba scenario=normal
    mode=resume thread_id=28ceee32-2f20-41b5-b48f-b0f1810acdba scenario=normal
    mode=resume thread_id=28ceee32-2f20-41b5-b48f-b0f1810acdba scenario=schema_mismatch
    mode=fresh thread_id=963608c2-3bf8-45d1-8c32-d2d5a94e7f48 scenario=normal
    mode=delete thread_id=963608c2-3bf8-45d1-8c32-d2d5a94e7f48 scenario=normal
    mode=delete thread_id=28ceee32-2f20-41b5-b48f-b0f1810acdba scenario=normal
    ```
    Exactly 2 `mode=fresh` lines (two distinct thread ids, A then B), exactly 2 `mode=resume`
    lines (BOTH to thread A — direct, mechanical proof the abandoned thread was resumed twice
    before going hollow, and thread B is never itself resumed within this session).
12. **Cleanup** — `run-ccs-review.sh --cleanup <B>` then `--cleanup <A>`
    (`FAKE_CODEX_CLEANUP_OK=1`), both returned `{"ok":true,"threadId":"...","deleted":true}`.
13. **Resulting `.result.json`**, the actual file written (schema-validated via `check-result.sh`
    against this scenario's own real, UNMODIFIED `expect.sh`, which reported `schema OK` /
    `assertions OK` / exit code 0):
    ```json
    {
      "session_id": "2026-09-11T152517-8899",
      "target": { "repo": "/tmp/ccs-eval-no-material-reviewed-fresh-restart.3hpLOe", "scope": "uncommitted" },
      "exit_state": "CLEAN",
      "round_count": 3,
      "threads": [
        { "group": "main", "thread_id": "28ceee32-2f20-41b5-b48f-b0f1810acdba", "kind": "leaked", "cleanup": "deleted" },
        { "group": "main", "thread_id": "963608c2-3bf8-45d1-8c32-d2d5a94e7f48", "kind": "current", "cleanup": "deleted" }
      ],
      "claims": [
        { "claim_id": "f1", "file": "lib.py", "line": 3, "severity": "medium", "summary": "add() returns a+b+1, an off-by-one error", "evidence": "...", "disposition": "resolved", "source_round": 2, "marker_reason": "lib.py now reads 'return a + b', the extra +1 has been removed and add() matches its intended contract." },
        { "claim_id": "f2", "file": "lib.py", "line": 8, "severity": "medium", "summary": "sub() returns a-b-1, an off-by-one error", "evidence": "...", "disposition": "resolved", "source_round": 3, "marker_reason": "lib.py now reads 'return a - b', the extra -1 has been removed and sub() matches its intended contract." }
      ],
      "coverage": { "status": "complete", "reviewed_file_count": 1, "omitted": [] },
      "input_errors": null
    }
    ```

**A genuine, unplanned illustration of a documented limitation.** By the time the restart's digest
was built, `f1`'s own fix had already changed `lib.py`'s line count (removing a comment line), so
`f2`'s real current line in the file is 6, not 8 — but the digest still cites line 8, `f2`'s most
recent recorded occurrence (round 1, its only occurrence). This is exactly
`references/compaction.md`'s own disclosed "Disclosed limitation" under "What gets preserved":
open-claim text reflects where the claim was most recently raised, which may now be stale if the
file has changed shape since — not treated as an enforcement problem, since Codex is instructed,
every round, to re-read the actual current file rather than trust the digest text as-is. This
scenario did not construct that staleness deliberately; it fell out naturally from real fixes
applied in real order, which is itself further evidence the digest mechanism being exercised here
is the real one, not a simplified stand-in.

## Expected result

- `exit_state`: `"CLEAN"`, `round_count`: `3` (the restart occupies round 3's own slot — rounds 1-2
  already produced valid results before thread A went hollow).
- `threads`: exactly one `"leaked"` entry (thread A) and exactly one `"current"` entry (thread B)
  — both `cleanup: "deleted"`; distinct thread ids.
- `claims`: exactly two entries — `f1` resolved at round 2, `f2` resolved at round 3 — both
  reaching a terminal disposition (this is what makes round 3 genuinely `CLEAN` despite the
  intervening hollow attempt).
- The fixed invocation log shows exactly 2 `mode=fresh` lines (A then B) and exactly 2
  `mode=resume` lines (both to A, never to B).
- The session's own durable JSONL log has exactly 3 round-bearing records (round 3's own hollow
  attempt is never separately persisted); round 1's record's `thread_id` is the leaked thread;
  round 3's record's `thread_id` is the current thread.
- Round 3's own `target.focus`, read back from that durable JSONL record, genuinely carries the
  digest forward with content bound to its OWN structural section, not merely present somewhere in
  the document: `COMPACT_DIGEST`/`CLOSED CLAIMS:`/`OPEN CLAIMS:`/`OPEN CLAIM f2:` each appear
  exactly once, anchored at their own line start, in the correct relative order; `f1`'s own
  one-line closed-claim reason (byte-exact against round 2's own `claim_closures[0].marker_reason`)
  is found specifically WITHIN the `CLOSED CLAIMS:` section; and `f2`'s own full verbatim
  `summary`/`evidence` text (byte-exact against round 1's own `codex_review.findings[]` entry) is
  found specifically WITHIN its own `OPEN CLAIM f2:` block — never a blank or reset digest, and
  never content merely coexisting with the right headings elsewhere in unrelated prose. This is the
  one property this scenario exists to prove.

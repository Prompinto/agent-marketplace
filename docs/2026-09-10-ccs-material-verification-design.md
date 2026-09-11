# `codex-stream-review:ccs` — material verification design (the "fake-clean trap" fix)

## Problem

`/ccs` keeps one resumable Codex thread per reviewer alive for a whole run, `--resume`ing it after
a failure rather than re-sending the diff, on the documented assumption that "the original
diff-bearing prompt is already present in the thread's own rollout"
(`references/retry-guards.md`'s "Resume-safety by failure reason" section). That assumption is
currently justified by ONE empirical crash-simulation test plus 4 real production `nonzero_exit`
occurrences, and applies uniformly to every resume-safe failure reason (`interrupted`/`timeout`/
`nonzero_exit`/`missing_task_complete`/`no_final_answer`/`invalid_json`/`schema_mismatch`).

**Real incident (GitLab MR !6166, external session, pre-`--compact`-merge version of `/ccs`).**
Round 1's fresh dispatch failed `nonzero_exit`. Per the documented protocol, the SAME thread was
retried via `--resume` (never re-sending the diff). The retry returned:

```json
{"ok": true, "verdict": "CLEAN", "findings": []}
```

Schema-valid. It passed every existing `schema_mismatch` cross-field check in `run-ccs-review.sh`
(CLEAN ⇔ empty findings, dimension enum values, non-blank evidence strings). But the `summary`
field read: *"No reviewable code or artifact was supplied in this retry... it does not contain a
defect."* Codex was not reviewing the diff and finding it clean — it was reporting it saw NO diff
at all, because in this specific occurrence the original `nonzero_exit` happened before the diff
was ever actually ingested into the thread's context, contradicting the one-empirical-test
assumption `retry-guards.md` currently generalizes from (the SAME failure reason, `nonzero_exit`,
had already held safely in 5 other observed occurrences before this one). The human operator only
caught this by manually reading `summary` — not part of any automated check — re-requested
confirmation (which itself then timed out), abandoned the thread, and dispatched a genuinely fresh
one, which then surfaced the real findings.

**Why this is structurally dangerous.** `ok:true` + `verdict:CLEAN` + `findings:[]` is
schema-identical whether Codex (a) actually reviewed real content and found nothing wrong, or (b)
saw no reviewable content at all and defaulted to reporting nothing wrong. Nothing in the current
schema, `schema_mismatch`'s semantic checks, or `/ccs`'s own Phase 2 convergence logic
distinguishes (a) from (b) for a REAL Codex dispatch response. (`run-ccs-review.sh`'s own line-778
CANNED shortcut for a genuinely-empty diff-and-focus case is a separate, already-correctly-labeled
path — it never calls Codex at all, so it is not the bug here.) A caller trusting
`ok:true`/`verdict:CLEAN` alone — the natural, schema-sanctioned thing to do — could report a
completely unreviewed MR as "verified CLEAN."

## Rejected alternatives

- **Telemetry-based confidence heuristic** (infer "did the model start real processing" from
  `execution.usage.input_tokens`/`elapsed_seconds` on the FAILED response before deciding whether
  `--resume` is safe to attempt). Rejected: that telemetry is explicitly documented as best-effort
  and may be entirely absent, so it cannot be a reliable primary mechanism — and it only prevents
  an *attempt*; it does nothing to catch a hollow response that already came back `ok:true`.
- **Mandatory extra confirmation round** every time a `--resume` returns CLEAN+empty-findings (ask
  Codex to quote a specific diff line/hash back before trusting it). Rejected: doubles round cost
  for every genuinely-clean `--resume` round, directly conflicting with this project's own recent
  `--compact` work (built specifically to reduce per-round cost), and it is still trusting
  free-text Codex output rather than a structural guarantee.

## Design overview

Two complementary, independently-checked signals, neither claimed to make the other airtight:

1. **`material_reviewed`** — Codex's own tightened self-assessment of whether it genuinely
   examined the specific material this round's own request refers to.
2. **`material_receipt` / `material_receipt_index`** — an objective, wrapper/Claude-verifiable
   delivery sentinel: a single-use token from a pre-generated schedule embedded once in the
   original material payload, proving (probabilistically, not with a mathematical guarantee) that
   at least part of that payload is still reachable in the thread's own context.

Either signal failing routes to a new dedicated failure reason, `no_material_reviewed`, which is
**never** treated as resume-safe and instead triggers exactly one fresh-restart recovery attempt
(reusing `--compact`'s own full restart mechanism) before giving up as `⚠️ COULD NOT VERIFY`.

This design reached this shape through 8 rounds of adversarial `codex-stream-review:ccs` review
(non-repo-artifact, design-only) on 2026-09-10 — every mechanic below, and the specific
vulnerabilities it closes, came from that process, not from a single up-front design pass. The
`## What each round actually caught` section at the end of this document records that trail.

## 1. `material_reviewed` — tightened self-assessment

New required boolean field on `schemas/review-verdict.schema.json`'s top-level verdict object.

**Canonical-manifest semantics** (tightened from an initial, too-broad draft — see the round
trail): `true` requires that the specific diff/artifact snapshot AND this round's own freshly-sent
Why/Scope/History focus text — together, "the canonical manifest for this exact round" — were both
genuinely present and examined. `false` covers absent, partial, truncated, stale, or
unknown-coverage material for either component — not only literal total absence. The ordinary case
of examining real, complete material and finding zero defects is `true`; there is no third state a
boolean cannot express, since every insufficient-coverage case takes the identical recovery path.

Because `--focus`/Context text is freshly sent on every round (never relying on old context the
way the diff/artifact is), `material_reviewed` mostly narrows to catching "read the fresh
follow-up text but didn't actually reconcile it with earlier persisted material" — a distinct
failure mode from "the material was never delivered at all," which `material_receipt` below
catches independently.

**Where the obligation lives.** The instruction to set this field honestly is added to
`build_review_prompt()`'s own trusted-zone text (the fixed paragraph living OUTSIDE the untrusted
`<$BOUNDARY>...</$BOUNDARY>` block that already carries the `DISPOSITION` marker obligation) —
never inside caller-supplied `--focus`/Context content, matching this project's own established
lesson (`mem:ccs-backlog-from-real-usage-feedback` candidate 2): an instruction meant to bind
Codex's own behavior has no real force placed inside the untrusted zone.

**Disclosed, accepted limitation.** This remains a model self-assessment — it cannot be made
independently verifiable on its own. It is documented as such, not oversold.

## 2. `material_receipt` / `material_receipt_index` — a single-use delivery schedule

New required-but-nullable fields (`"type": ["string", "null"]` / `["integer", "null"]`
respectively) on the same schema.

### 2.1 What it proves, and what it does not

A delivery sentinel for the original material-bearing payload's continued reachability in
context — proof that at least one specific token embedded once in that payload is still visible.
It does **not** prove the diff content itself is intact, untruncated, or was actually examined —
that remains `material_reviewed`'s own separate, complementary, still-inherently-imperfect
self-assessment. Neither field is claimed to make the other airtight.

**Disclosed, permanent ceiling — this is a probabilistic signal, not a deterministic guarantee.**
A maximally adversarial or unlucky scenario (an unused future token leaking into a retained field
like `summary`/`evidence` of an earlier response — including via adversarial content in the
reviewed material itself — and later being replayed from that leak rather than from genuine
continued access to the schedule) remains theoretically possible. Closing this completely would
require a real cryptographic challenge-response protocol, which is disproportionate to the actual
risk this design addresses (an occasional silent hollow-review incident, not a targeted attacker).
This mechanism converts a previously **completely unchecked** failure mode — caught only by a
human manually reading free-text `summary` — into one requiring either `material_reviewed` to
independently also fail closed, or an actual leaked-token replay. That is a large, real
improvement over the status quo; it is not being presented as a perfect one.

### 2.2 Schedule generation and embedding

- Whenever a material-bearing seed is dispatched (round 1's own fresh dispatch, or a
  `no_material_reviewed` fresh restart's brand-new thread — see §3 below; each restart's own new
  thread gets its own fresh schedule, never reusing the old thread's), Claude generates **N = 70**
  distinct high-entropy tokens.
  - **N derivation, not an arbitrary round number**: the true upper bound is dispatch *attempts*
    per thread lifetime, not rounds. `references/retry-guards.md`'s own bounded resume-retry rule
    allows up to 2 additional bounded retries per ordinary resume-safe failure, so one round can
    consume up to 3 attempts worst-case. With `MAX_ROUNDS = 20` as the true ceiling (quick mode's
    `5` is smaller; escalation only ever raises toward 20, never past it), the worst-case attempt
    count for one thread's lifetime is `20 × 3 = 60`. N = 70 is a comfortable margin above that
    derived bound.
  - **Exhaustion (a thread somehow needing a 71st distinct attempt)**: fails CLOSED, per this
    project's own established "fail CLOSED wherever a real alternative still exists" principle
    (already used verbatim in `references/compaction.md`) — treated identically to a receipt
    mismatch, never silently accepted as CLEAN just because the bookkeeping ran out. In practice
    this should never actually occur, since 70 already comfortably exceeds the worst case bound
    above.
- All N tokens are embedded **once**, as a numbered list, inside that seed's own payload text —
  positioned immediately after the actual diff/artifact content ends (representative of the
  payload having been transmitted in full, not before it) — e.g. `1: <token1> 2: <token2> ...
  70: <token70>`, under a labeled block, `REVIEW_RECEIPT_SCHEDULE`. Never repeated in any later
  prompt, fresh or resumed.
- The mapping is written **once**, immutably, to a new local-only file, `RECEIPT_SCHEDULE_FILE` —
  mirroring `SNAPSHOT_FILE`'s own existing treatment exactly: a locally-held artifact Claude
  reads/writes directly, remembered as a session-scoped literal path fact the same way
  `SNAPSHOT_FILE`/`SESSION_ID` already are, **never** included in any `FOCUS_FILE` construction,
  never excerpted into round 2+'s own History text, and never part of the JSONL log's own line
  schema. This file is written once at creation and never touched again for that thread's
  lifetime — it holds ONLY the private token mapping, never a cursor (see §2.3 for why).

### 2.3 Issuing a slot — Claude decides, not the model; one sole cursor authority

An earlier draft let the model itself pick "the lowest index I haven't echoed yet" from its own
visible thread history. This was found unsound in review (see the round trail): a response that
reaches the model's own thread history but is never durably recorded on Claude's side (a crash, a
discarded response, a lost append) leaves the model believing a slot was consumed while Claude's
own reconstructed state still expects it — a real divergence with no clean resolution once both
sides are allowed to decide independently.

**Fix — Claude is the sole, pre-committed authority for which slot is next, decided BEFORE
dispatch, never after a response is received:**

- Before every dispatch to a thread that has an active schedule (round 1's own fresh dispatch
  establishes it; every later dispatch against that thread — a resumed round, or a bounded resume
  retry — consumes the next slot), Claude durably appends a `receipt_issued` fact to the
  review-history JSONL log — via the exact same append-then-verify hard-stop mechanism already
  used for every round's own line — **before** constructing that dispatch's own focus text or
  prompt arguments, never after receiving its response.
- That dispatch is issued with a new wrapper CLI argument, `--receipt-slot <N>`, naming the
  non-secret slot NUMBER Claude has just committed to. `run-ccs-review.sh`'s own
  `build_review_prompt()` — its own script-generated TRUSTED prompt text, never caller-supplied
  `--focus`/stdin content — renders, as a fixed template parameterized by `<N>` (placed OUTSIDE
  the untrusted `<$BOUNDARY>` block, exactly like the existing `DISPOSITION` marker obligation):
  *"Your context may contain a block labeled `REVIEW_RECEIPT_SCHEDULE` with numbered tokens.
  Report `material_receipt_index: <N>` and the exact token value at position `<N>` in that
  schedule, in the `material_receipt` field. If you cannot locate that schedule, or cannot find
  entry `<N>` in it, set both fields to `null` instead of guessing."* This instruction text is
  otherwise identical, word-for-word, on every dispatch — only `<N>` changes, and it is never a
  secret (knowing "report index 3" gives a context-losing model no way to fabricate the correct
  VALUE at index 3, which exists only in the original schedule block).
- **The model is given no state-tracking responsibility at all** — it never decides which slot is
  "next." It only looks up the ONE index it is explicitly told, in the schedule block it should
  still be able to see, and reports that slot's own value (or null-pair if it cannot).
- **Sole cursor authority: the JSONL log, reconstructed by scanning the whole session log for the
  highest `receipt_issued` record for that thread** — exactly the same "reconstruct from the whole
  log, most-recent-wins" pattern already used for
  `COMPACTION_CONSECUTIVE_FRESH_FAILURES`/`compaction_disabled_reason` recovery. `RECEIPT_SCHEDULE_FILE`
  itself holds no cursor of its own (see §2.2 — immutable, mapping only). This removes any
  split-brain risk between two durable stores: there is exactly one durable write governing "what
  slot is next" (the JSONL append), and the schedule file's own content never changes after
  creation, so there is nothing in it to desynchronize.
- A lost/discarded/timed-out response after a slot was issued simply means that slot's own value
  is never validated against anything (no round ever claims success off it) — the NEXT dispatch
  still correctly proceeds from the next JSONL-recorded index, independent of whether the prior
  slot's own response was ever successfully received or parsed.

**Standing assumption, to preserve explicitly**: dispatches to a single thread are always
serialized (never two concurrent dispatches to the same thread) — already true throughout `/ccs`'s
existing architecture (parallel mode gives each group its own separate thread; bounded resume
retries are sequential with backoff delays). This design does not need to handle concurrent
issuance to the same thread because that case cannot occur today.

### 2.4 Validation and its cross-field contract

- `material_receipt` and `material_receipt_index` must be **both null or both non-null** —
  one-null-one-populated is itself an invalid combination.
- A genuine null pair (the model reports it cannot locate the schedule at all) is itself direct
  evidence of exactly the failure mode this whole mechanism exists to catch, and is routed to
  `no_material_reviewed` identically to a value mismatch — never treated as a separate, softer
  case.
- **Where the check runs — this is inherently stateful, so it does NOT belong in
  `run-ccs-review.sh`'s existing stateless `schema_mismatch` mechanism.** `run-ccs-review.sh` is a
  stateless-between-invocations bash script with no natural place to persist cross-call state.
  Receipt validation instead lives entirely in Claude's own Phase 2 processing — exactly where the
  claim ledger's own `DISPOSITION` marker parsing already lives (Codex emits structured output,
  Claude parses/validates it against session-scoped state Claude already tracks, per §2.3's JSONL
  reconstruction).
- **Explicit ordering rule, to prevent silent bypass**: the MOMENT Phase 2 step 1 parses a response
  whose `material_receipt`/`material_receipt_index` does not exactly match Claude's own
  JSONL-reconstructed expected value for that slot (or is a null pair when a schedule genuinely
  exists for this thread), this is treated IMMEDIATELY — before step 2 (receiving findings), step
  3 (re-verification/claim-ledger judgments), or any convergence check — as equivalent to that
  group's response being `ok:false` with reason `no_material_reviewed`. That response's own
  verdict/findings content is never processed or acted on even if it looks internally coherent,
  and it never participates in the convergence check under any circumstance.

## 3. The `no_material_reviewed` failure reason and its recovery path

**Two distinct routes into this one failure reason:**
1. **Wrapper-level, stateless** (`run-ccs-review.sh`'s existing `schema_mismatch` mechanism,
   extended): `material_reviewed:false` combined with ANY verdict — `CLEAN` or `ISSUES` — is
   rejected. If no material was present, findings cannot legitimately exist either (they would have
   to be fabricated or leftover from stale context); a false-material response is always routed
   here regardless of what verdict/findings shape happened to accompany it. `threadId` is present
   (a real dispatch happened).
2. **Claude/Phase-2-level, stateful** (§2.4 above): a receipt mismatch or invalid null pair.

**Recovery, identical for both routes — never resume-safe:**
`references/retry-guards.md` gains an explicit new rule: `no_material_reviewed` is **never**
treated as resume-safe, unlike every other threadId-bearing reason in that file's existing table —
resuming a thread that has just proven its own context is hollow would only reproduce the identical
failure. Instead: abandon that thread immediately (add to `LEAKED_THREAD_IDS`) and issue exactly
**one** fresh restart, reusing `references/compaction.md`'s own **complete** "Restart mechanism"
section verbatim — not a separately-invented lighter-weight version:
- The claim ledger digest is carried forward into the fresh thread's own seed, built from the
  durable JSONL log's own reducer state (open claims verbatim, closed claims collapsed) — never
  from the abandoned thread's own internal state — so round-specific convergence history is not
  dropped.
- The same snapshot-integrity revalidation/promotion machinery compaction's own restart already
  uses applies here too. `--compact`'s own restart mechanism is already a deliberate,
  previously-adversarially-reviewed, narrow exception to this project's snapshot-integrity
  invariant ("one canonical subject, never changed per round") specifically for a mid-session fresh
  restart — accepting that a restart may review the CURRENT state of a possibly-since-changed
  working tree, which was already judged an acceptable tradeoff (arguably more correct than
  reviewing a stale, possibly-already-fixed diff) when `--compact` shipped. `no_material_reviewed`'s
  restart inherits this exact, already-accepted tradeoff rather than requiring a new one.
- The fresh restart's own new thread gets its own fresh receipt schedule (§2.2).
- **If the ONE fresh restart is ALSO `no_material_reviewed`** (either route): stop and report
  `⚠️ COULD NOT VERIFY`, never attempt a third thread — matching the existing precedent in
  `retry-guards.md` (round-1's own one-fresh-retry-then-give-up rule) and `--compact`'s own
  candidate-A-to-thread-B single-shot-escalation-then-give-up pattern.

## Schema changes summary (`schemas/review-verdict.schema.json`)

Add to `properties` and `required`:
- `material_reviewed`: `{"type": "boolean"}`
- `material_receipt`: `{"type": ["string", "null"]}`
- `material_receipt_index`: `{"type": ["integer", "null"], "minimum": 1}`

`additionalProperties: false` at the top level means every existing consumer (fixtures, eval
scenarios, `validate_ci_result.py` if it ever inspects verdict shape directly) needs updating to
include these three fields on every canned/scripted `ok:true` response — flagged as a known,
mechanical implementation cost, not a design blocker (see the writing-plans handoff below for
where this lands as concrete tasks).

## New wrapper interface surface

- `run-ccs-review.sh` gains one new optional CLI argument, `--receipt-slot <N>` — parallel in
  spirit to `--capture-eventlog`/`--keep-last-message`, passed by Claude on every dispatch to a
  thread with an active schedule. `N` must be a positive integer; a leading-dash value is rejected
  as `bad_args`, matching the existing guard already applied to `--base`/`--commit`/`--resume`
  values.
- `build_review_prompt()` renders the `<N>`-parameterized receipt-slot instruction as described in
  §2.3, outside the untrusted boundary.

No other change to `run-ccs-review.sh`'s existing dispatch modes, argument shape, or output
contract for `ok:false`/`ok:true` beyond the new `no_material_reviewed` reason value and the three
new schema fields.

## Eval scenario coverage needed (flagged for the implementation plan)

Following this project's own established per-outcome eval-scenario convention (matching how
`--compact`'s own Group H was built — one scenario per distinct terminal/latch outcome, never a
bare fixture-schema patch):
- `material_reviewed:false` (any verdict) triggering `no_material_reviewed`, confirmed never
  resumed.
- A receipt value mismatch on an otherwise schema-valid `ok:true` response, confirmed routed to
  `no_material_reviewed` via the Phase-2 path before any finding/claim processing.
- A genuine null-pair response, confirmed routed identically to a value mismatch.
- The fresh-restart recovery actually using a NEW thread id, with the claim ledger digest and
  snapshot-integrity handling both actually exercised (not merely asserted).
- The ONE-fresh-restart-then-give-up bound: a second `no_material_reviewed` on the restart's own
  new thread, confirmed terminating at `⚠️ COULD NOT VERIFY` rather than attempting a third thread.

## What each round of the `/ccs` design consultation actually caught

Recorded for anyone extending this design later — every one of these was a real, distinct defect
in an earlier draft, not stylistic feedback:

1. **Round 1** (first pass at the whole proposal): the `schema_mismatch` rule as drafted only
   rejected `material_reviewed:false` combined with `CLEAN`, silently accepting it combined with
   `ISSUES`/nonempty findings; self-attestation alone is not independently verifiable; the
   boolean's initial definition ("any prior thread history present") was too broad; a round-2+
   fresh-restart needed to be shown to preserve convergence context, not just discard a hollow
   thread; the plan needed explicit eval coverage and a defined outcome for a second hollow
   restart.
2. **Round 2**: proposed the receipt mechanism itself as an objective, wrapper-verifiable delivery
   signal to complement self-attestation.
3. **Round 3**: the receipt instruction, if it ever interpolated the live expected value into a
   RESUME prompt, would make the check vacuous; a single thread-lifetime receipt is replayable from
   the model's own earlier successful response once the original payload has scrolled out of
   context; the receipt's own claimed scope was initially overstated as proving full-snapshot
   delivery.
4. **Round 4**: even a fixed schedule of future tokens can leak through a retained field
   (`summary`/`evidence`) and be replayed later — the mechanism is a strong probabilistic signal,
   never a deterministic proof; the schedule size (N) needed to be derived from the true worst-case
   dispatch-attempt count, not chosen arbitrarily, with an explicit fail-closed exhaustion rule.
5. **Round 5**: allowing the MODEL to self-select "the next slot I haven't used" creates a
   divergence risk against Claude's own separately-reconstructed state whenever a response reaches
   the model's thread history without being durably recorded on Claude's side.
6. **Round 6**: the fix above was misdiagnosed — the real fix is removing the model's own
   slot-selection responsibility entirely, replacing it with a Claude-issued, pre-dispatch-committed
   slot number; the schema needed `material_receipt`/`material_receipt_index` to be nullable, not
   required non-null strings, with a paired-null cross-field rule.
7. **Round 7**: the schedule's own N-to-token mapping needed a durable, PRIVATE store, explicitly
   excluded from anything ever rendered back into a Codex-bound prompt (the JSONL log itself is the
   wrong place, since round 2+ History text is built from it); the per-round "report index N"
   directive needed to live in `build_review_prompt()`'s trusted zone via a new wrapper flag, not
   in caller-supplied focus text.
8. **Round 8**: the split between a durable JSONL issuance record and a separately-mutable schedule
   file cursor was itself a new split-brain risk — consolidated to one sole cursor authority (the
   JSONL log), with the schedule file made strictly immutable. Converged **CLEAN**.

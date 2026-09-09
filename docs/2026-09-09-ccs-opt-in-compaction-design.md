# `codex-stream-review:ccs` — opt-in thread compaction design

## Problem

`run-ccs-review.sh` keeps one resumable Codex thread per reviewer alive for a whole `/ccs` run,
`--resume`ing it every round after the first rather than re-sending the diff. This avoids
re-ingestion cost per round, but nothing ever prunes the thread's own accumulated history — every
round's own `execution.usage.input_tokens` (the real per-turn size Codex actually processes,
reported by `run-ccs-review.sh` from the round's own `turn.completed` event) grows monotonically,
round after round, for the life of the thread.

Real measured data, from the longest `/ccs` run observed to date (the `visual-verify`
auth-stub-config feature, 2026-09-08/09, 17 rounds to CLEAN):

| Round | `input_tokens` | `cached_input_tokens` | `elapsed_seconds` |
|---|---|---|---|
| 1 (approx, external report) | ~520,000 | — | ~300 |
| 10 (approx, external report) | ~31,600,000 | — | — |
| 14 | 52,310,561 | 48,435,129 | 774 |
| 15 | 55,057,986 | 51,138,352 | 339 |
| 16 | 58,451,225 | 54,197,383 | 524 |
| 17 (CLEAN) | 60,032,215 | 55,625,250 | 235 |

Growth is front-loaded (round 1→10 is ~60x; round 10→17 is ~1.9x over 7 more rounds), and elapsed
wall time does **not** track token count monotonically (round 17 was both the largest-token and
fastest round measured) — cache hit rate, not raw size, appears to dominate latency once a thread
is this large, though this is a small sample, not a trend line. The concrete, structural problem
this design solves is **unbounded token growth with no pruning mechanism**, not latency
specifically.

## What was ruled out, and why (real research, not assumption)

- **`codex exec fork`.** Already evaluated in this repo for a *different* cost problem (parallel
  mode's N-way redundant diff-ingestion) and rejected with real measured evidence: forking used
  2.14x the tokens of independent dispatch, because a fork inherits the parent thread's *entire*
  history — it does not prune anything. See `docs/2026-09-05-codex-stream-review-improvement-
  roadmap-design.md`, "Phase 4 Item 1 canary results." Since a fork carries the same bloat forward,
  it cannot serve a compaction goal either — ruled out without needing a second canary.
- **Asking the same resumed thread to "forget" via `--focus` text.** There is no Codex CLI
  primitive that shrinks a thread's own stored server-side context (confirmed: `codex exec`,
  `codex exec resume`, `codex queue`, `codex resume` — none expose a compact/prune/forget verb).
  Asking Codex, in plain text, to disregard earlier content does not reduce what the backend
  actually re-processes on the next `--resume` turn — the billed/processed size stays exactly what
  it already was. This does not solve the problem at all, so it isn't a real alternative.
- **Codex's own native automatic compaction.** Real, directly observed: local session rollout logs
  (`~/.codex/sessions/**/*.jsonl`) contain genuine `"type":"compacted"` events — an LLM-generated
  handoff-style summary (current task, constraints, project state) replacing prior context, not
  naive truncation. Confirmed in both an interactive `codex` session (12 occurrences in one long
  session) and at least one `codex_exec`-originated rollout. **However, it did not fire even once**
  during the real 17-round `/ccs` review measured above, despite that thread growing far larger
  than the session where it fired 12 times. Working hypothesis (not confirmed): the trigger may be
  evaluated only within one continuously-running process/turn, which a short-lived
  `codex exec resume` process (one turn, then exit) may never satisfy — but this is not something
  `/ccs` can rely on or control either way, so a plugin-side mechanism is needed regardless of the
  true reason.

## Design

### Opt-in flag: `--compact`

A fourth independent, optional `/ccs` prefix flag, alongside the existing `--capture-evidence`,
`--keep-evidence`, and `--quick` — parsed by the same Phase 0 Step 0 prefix-stripping loop, its own
independent boolean (`COMPACT_MODE`), any subset of the four may be ON in any order. **No changes
to `run-ccs-review.sh` itself are required** — compaction is entirely a `SKILL.md`-level
orchestration technique built from primitives the wrapper already exposes (a fresh dispatch, a
`--cleanup` call), the same relationship `--quick`/`--keep-evidence` already have to the wrapper.

Starting as opt-in (not always-on, unlike snapshot integrity/claim ledger) is deliberate: this is a
genuinely new failure surface (see "Restart mechanism" and "Digest construction and verification"
below) that has not yet been validated against real reviews the way the always-on mechanisms have.

### Trigger

After EVERY completed round — **including round 1 itself (corrected — closes a real gap found
during design review: an earlier revision restricted this check to "round 2+ only," reasoning
"round 1 has nothing to compact." That reasoning conflated two different things — round 1 has no
PRIOR thread to compact away, which is true, but round 1's OWN resulting thread is already a real,
resumable thread the moment round 1 completes, and its usage is already known then. Restricting the
check to round 2+ would force at least one wasted `--resume` turn against an ALREADY-oversized
round-1 thread whenever round 1 alone exceeds the threshold, before compaction could ever apply —
missing the earliest point where enforcement is actually possible)** — if `COMPACT_MODE` is ON:
check that just-completed round's own `execution.usage.input_tokens` (already reported by
`run-ccs-review.sh`, no new telemetry needed) against a fixed threshold, `COMPACT_THRESHOLD =
8,000,000`. If exceeded, compact before building the next round's dispatch — if round 1 itself
triggers this, round 2 becomes the compaction round immediately (running the existing mandatory
round-2+ active-snapshot revalidation first, per "Restart mechanism" step 0 below, then the fresh
compaction path), never a wasted ordinary `--resume` first. The threshold is a starting point
calibrated against the one real dataset available (roughly the midpoint of the round-1→round-10
steep-growth zone above) — not user-configurable in v1 (YAGNI; a `--compact-threshold <N>` override
can be added later if real usage shows 8M is wrong for other review shapes).

**Guard against a repeated, benefit-free restart loop for intrinsically large reviews (new — closes
a real gap found during design review: the trigger as stated has no guard against compacting again
immediately after a compaction that didn't actually help. A successful COMPACTION round is, itself,
just another completed round — its own usage gets checked by this same trigger. If the underlying
diff/claims content is simply large enough that even a FRESH restart's own single-turn usage is
already at or above `COMPACT_THRESHOLD` — not because of accumulated resumed-thread history, but
because the content itself is that big — then the very next round would trigger compaction again,
and again, every round, each one paying the full fresh-restart cost with ZERO benefit: no future
compaction can ever bring a review's OWN intrinsic content size below a threshold its own baseline
already exceeds. This turns the intended occasional, bounded-cost operation into a full
re-ingestion on every non-CLEAN round for the largest reviews — worse than never compacting at
all.)** Fixed: record `COMPACTION_BASELINE_TOKENS` — the COMPACTION round's OWN
`execution.usage.input_tokens` (its own freshly-restarted usage, NOT the triggering round's — a real
bug in an earlier revision of this very fix confused the two: the triggering round's usage is, BY
DEFINITION, already `>= COMPACT_THRESHOLD` — that is what triggered it — so recording that value as
the baseline would make the check below true unconditionally, disabling compaction after every
single first successful restart, exactly the opposite of the intended behavior) — every time a
compaction round's OWN dispatch succeeds. If THAT (the compaction round's own, freshly-restarted)
baseline is itself already `>= COMPACT_THRESHOLD`, compaction is disabled for the remainder of the
session (narrated once, clearly, the same way the byte-budget exhaustion limitation already is) —
repeating it can only ever cost more, never less, once even a maximally-compacted round can't get
under the bar. If the fresh baseline IS comfortably under threshold (the common, intended case —
compaction genuinely reset accumulated growth), ordinary accumulation-based triggering simply
resumes for future rounds exactly as designed, no special-casing needed.

**Fail closed when the compaction round's OWN telemetry is unusable — never assume the restart
helped (new — closes a real gap found during design review: "Handling missing OR malformed usage
data" above already establishes that a round's `input_tokens` can legitimately be absent or
malformed even on a genuine success. An earlier revision of this guard never said what happens to
`COMPACTION_BASELINE_TOKENS` in exactly that case for the COMPACTION round itself — if left simply
unset/skipped, a LATER resumed round reporting a high value would trigger another fresh compaction
without ever having confirmed whether the ORIGINAL restart's own baseline was actually fine,
reopening the identical benefit-free-restart-loop risk this guard exists to close, just via a
different path.)** Fixed: if the compaction round's own `input_tokens` is unusable (per the existing
missing/malformed rule above), `COMPACTION_BASELINE_TOKENS` is NOT left unset — it is treated
IDENTICALLY to a baseline that IS `>= COMPACT_THRESHOLD`, disabling compaction for the remainder of
the session. This mirrors the same fail-closed philosophy "Handling missing OR malformed usage data"
already applies to the ordinary trigger check: never assume a restart helped just because its own
usage couldn't be confirmed — an unverifiable baseline is treated as a failed one, not a free pass.

**A SEPARATE circuit breaker is also needed for repeated FAILED fresh-dispatch attempts, not only
for a successful-but-still-too-large one (new — closes a real gap found during design review: the
baseline guard above only ever engages after a compaction dispatch SUCCEEDS. Every `ok:false`
compaction attempt — including `timeout`, which the wrapper's own default fresh-dispatch deadline of
1800 seconds makes a real possibility for a genuinely large diff, and `nonzero_exit` — instead falls
straight through to the fallback `--resume` on the (still oversized) old thread, per "On failure"
below, with the threshold check simply running again next round. Nothing bounds how many times THIS
can repeat: a diff large/slow enough to reliably time out the fresh dispatch would trigger another
identical, doomed fresh attempt every single subsequent round, each paying a nearly-full round-1-
sized cost for zero benefit — a second, distinct flavor of the same benefit-free-restart-loop risk
the baseline guard was built to close, this time via repeated FAILURE rather than a too-high
success.)** Fixed: a second session-scoped counter, `COMPACTION_CONSECUTIVE_FRESH_FAILURES`,
increments by one every time a compaction attempt's own fresh dispatch (after exhausting whatever
bounded retry `references/retry-guards.md` already applies to that one round's own attempt) still
ends up `ok:false` and falls through to step 6's fallback — and resets to `0` every time a compaction
attempt succeeds. Once this counter reaches `COMPACTION_MAX_CONSECUTIVE_FAILURES = 2`, compaction is
disabled for the remainder of the session — via the SAME `compaction_disabled_reason` mechanism
below, with the value `"repeated_fresh_dispatch_failure"` — a small, deliberately conservative bound

**This counter must ALSO increment on a purely LOCAL pre-dispatch failure, not only a wrapper
`ok:false` (corrected — closes a real gap found during design review: a persistent LOCAL failure —
the candidate's own `git diff`/`shasum` collection failing per "Collection/hash failure itself"
above, or the byte preflight's own authoritative untracked-file collector invocation failing per
its own failure path — falls straight through to step 6's fallback WITHOUT ever reaching a real
wrapper dispatch at all, so the counter as originally scoped ("after a compaction attempt's own
fresh dispatch... ends up ok:false") never increments for either case. A persistent local problem —
a broken collector script, a corrupted git state — would repeat that same free local collection cost
on every single triggering round forever, with no circuit breaker, exactly the same "repeated cost
for zero benefit" pattern this counter exists to close for wrapper failures.)** Fixed: broadened to
increment on ANY compaction attempt that falls through to step 6's fallback without completing a
real successful compaction — local collection/hash failure, local preflight-collector failure, OR a
wrapper `ok:false` alike — the one exception being `byte_budget_exceeded`, which already gets its
own dedicated, immediate latch (see "A real latch, not merely an implicit..." below) precisely
because a successful measurement over budget is a distinct, already-fully-diagnosed cause that
doesn't need this counter's slower two-strikes bound.
consistent with this design's other fixed, non-configurable limits (`COMPACT_THRESHOLD`,
`CLOSED_CLAIM_LIMIT`, `COMPACT_BYTE_BUDGET`).

**This counter's own intermediate value must ALSO be durably recorded, not only the final "disabled"
decision (new — closes a real gap found during design review: an earlier revision durably logged
`compaction_disabled_reason` only once the counter actually REACHES its bound, but never the
counter's own value on the way there. A session recovering from a lost in-memory state after exactly
ONE fresh-dispatch failure — not yet two — would reconstruct the counter as `0`, silently doubling
the effective failure budget across that recovery event and undermining the two-attempt bound this
guard exists to enforce.)** Fixed: every round whose own compaction attempt fails (falls through to
step 6's fallback) durably records the counter's CURRENT value (after incrementing) as a new field,
`compaction_attempt_failure_count`, on that round's own line — this is a genuinely pre-append case,
exactly like `compaction_attempt_failed_thread`, since the failure is known before that round's own
real (fallback) result is ever logged.

**A successful compaction's own reset must be durably recorded too, or recovery can silently replay
a STALE failure count from before the reset (new — closes a real gap found during design review,
confirmed by direct simulation: a failure records `compaction_attempt_failure_count: 1`, a later
compaction SUCCEEDS and resets the in-memory counter to `0`, but that success round's own line never
recorded anything for this field — so a subsequent state-loss recovery, reading only the latest
recorded value across the log, finds the OLDER `1` from before the reset and restores it as if no
reset had ever happened. The very next fresh-dispatch failure after that recovery then reaches `2`
and disables compaction, even though it is really only the FIRST consecutive failure since the last
success.)** Fixed: a successful compaction round (this is the same round already appending
`compacted_from_thread` and the `snapshot_digest_*` pair — see "Ordering on success" step 5.3 below,
itself pre-append since the reset is already decided the moment dispatch returns `ok:true`, before
that same append) ALSO durably records `compaction_attempt_failure_count: 0` on that SAME line,
explicitly representing the reset rather than leaving it implicit. Continuity recovery reconstructs
`COMPACTION_CONSECUTIVE_FRESH_FAILURES` from whichever of these two fields — a failure's incremented
value or a success's explicit `0` — was recorded MOST RECENTLY across the whole session log (by
round order, not by which field name it is), defaulting to `0` only when neither has ever been
recorded at all.

**The "disabled for the rest of the session" decision must be durably logged and recoverable — never
in-memory-only (new — closes a real gap found during design review, and corrects an overclaim an
earlier revision made in the process of fixing it: that revision asserted `PROVISIONAL_SNAPSHOT_FILE`
and `RETIRED_SNAPSHOT_FILES` already had a "durable JSONL-backed recovery path" as precedent for this
same fix — they did not; see "Retired- and provisional-snapshot durability" below, which closes that
separate, real gap on its own terms rather than retroactively pretending it was already closed).**
This guard's own "disabled for the rest of the session" latch (from EITHER circuit breaker above)
was left as an in-memory-only fact with no durable path at all — if that memory is lost (an
interruption, a context compaction of the CONVERSATION itself, anything the existing
continuity-recovery mechanism already exists to handle for `GROUP_THREADS`/`LEAKED_THREAD_IDS`/claim
state), a later round reporting high usage could re-trigger the exact benefit-free restart loop
either guard was built to permanently close. Fixed: the compaction round that sets this latch
(because its own baseline was `>= COMPACT_THRESHOLD`, its own telemetry was unusable,
`COMPACTION_CONSECUTIVE_FRESH_FAILURES` reached its bound, OR the byte preflight below found the
exact assembled payload over `COMPACT_BYTE_BUDGET`) durably records a new field,
`compaction_disabled_reason` (a short string — `"baseline_at_or_above_threshold"`,
`"baseline_unusable"`, `"repeated_fresh_dispatch_failure"`, or `"byte_budget_exceeded"`), on that
SAME round's own JSONL line — never a separate append. Continuity
recovery is extended, alongside its existing reconstruction of `GROUP_THREADS`/`LEAKED_THREAD_IDS`/
claim state, to also check whether ANY prior round in the session's log ever recorded this field —
if so, compaction is reconstructed as disabled for the rest of the session, exactly matching
whatever the original in-memory decision would have been, never silently forgotten and re-enabled.

**Round-ownership terminology, made explicit (new — closes a real ambiguity found during design
review: the rest of this document says "round R" for BOTH the round whose usage was just checked
AND the round that performs the compaction dispatch — these can never be the same round number,
since a round's own dispatch has already happened by the time its usage is checked.)** Call the
round whose completed usage triggers this check the TRIGGERING round. Compaction, when triggered,
is attempted for the VERY NEXT round dispatched afterward — call it the COMPACTION round. **Every
later use of "round R" in "Restart mechanism" below, and everywhere else in this document
discussing the compaction attempt itself, means the COMPACTION round — never the triggering round
the decision was based on.** The triggering round was already processed and logged normally,
before this check ever ran; nothing about it is retroactively changed.

### What gets preserved — full fidelity for open claims, one line for closed ones

Reuses the claim ledger's existing reducer (`references/claim-ledger.md` section 8) over the
session's own JSONL log — no new data structure. For every claim_id that has ever appeared this
session:
- **Still open** (no `claim_closures[]` entry): included **verbatim**, using the claim's MOST
  RECENT occurrence, not necessarily its origin (revised — see "Most-recent, not origin" below) —
  `file`/`line`/`severity`/`summary`/`evidence`, unabridged. This is deliberately the highest-
  fidelity case, mirroring how Claude Code's own context compaction keeps the most
  currently-relevant material closest to full fidelity rather than summarizing everything
  uniformly. **Disclosed limitation:** this text (including its `file`/`line`) reflects where the
  claim was most recently raised, which may now be stale if the file has changed shape since — this
  is not treated as an enforcement problem (Codex is already instructed, in every round, to
  re-read the actual current file rather than trust diff/context text as-is; a compaction restart
  changes nothing about that existing discipline).
- **Resolved or retracted**: collapsed to **one line**, built directly and deterministically from
  its own `claim_closures[].marker_reason` (already exactly one sentence, by the existing
  `DISPOSITION` marker grammar) — no new LLM call, no summarization step, zero added cost or
  design surface. Example: `claim_id g1:f3 — RESOLVED (round 5): the null check now covers the
  empty-array case, confirmed by re-reading the current file.` **Bounded — see "Closed-claim
  section has its own ceiling" below.**

**Most-recent, not origin (new — closes a real context-loss gap found during design review).** An
earlier draft used each open claim's ORIGIN finding text only. This loses exactly the context a
normal round-2+ History section would already carry forward: a later re-raise's own updated
evidence, its `evidence_delta` judgment, and Claude's own most recent `action`/`rationale` for it.
Fixed: for each open claim_id, use the SAME "most recent occurrence" lookup the quick-mode
severity check already performs (`SKILL.md`'s own Guards section) — find that claim_id's latest
`claude_verification[]` entry, read its own `finding_id`, and use THAT finding's
`file`/`line`/`severity`/`summary`/`evidence` (falling back to the origin finding only for a claim
that has never been re-raised, where origin IS the most recent). Additionally append one line
noting the most recent `evidence_delta` (when present) and Claude's own most recent
`action`/`rationale` for it, so the fresh thread sees "here is where this stood," not just the
opening complaint.

**Digest construction and verification — structured data first, prose rendering last (redesigned —
closes a real spoofing gap found during design review).** An earlier draft built the digest as
prose directly, then re-PARSED that same prose back out (looking for `OPEN CLAIM <id>:` lines) to
verify nothing was dropped. This is unsound: a claim's own verbatim `evidence` text can legitimately
contain a quoted example, a code block, or prose that itself contains a column-zero-anchored string
shaped exactly like another claim's marker (confirmed directly: a Python regex scan of a hand-built
example where one claim's own evidence text quotes what looks like a second claim's marker line
returns a phantom match for an ID that has no real record) — the exact class of ambiguity the
existing DISPOSITION marker parser avoids via fencing/cardinality rules that this simpler use case
does not need to reinvent, because there is a simpler fix available here specifically: **never
re-parse the rendered prose at all.**
1. Compute the reducer's own open-claim-id list (`references/claim-ledger.md` section 8) as
   structured data (e.g. a `jq` array), not prose.
2. For each element of that array, resolve its `{claim_id, file, line, severity, summary,
   evidence}` fields (via the same most-recent-occurrence lookup — see "Most-recent, not origin"
   above) — **do not render `block_text` yet.**
3. **Verification is a structural check on this data, BEFORE any prose is ever rendered — both a
   KEY check and a CONTENT-COMPLETENESS check (the latter added — closes a real gap found during
   design review):**
   - **Key check:** the number of resolved objects equals the reducer's own open count, and their
     `claim_id` keys are exactly the reducer's own open-id set (set equality).
   - **Content-completeness check — TYPE/PRESENCE, not non-emptiness (corrected — closes a real
     over-strict gap found during design review): every one of those objects has `summary`,
     `evidence`, and `file` present as strings (per the review-verdict schema's own field types),
     and `severity` is one of the schema's own legal values — but an empty string is a legal value
     for `summary`/`evidence`/`file` under that same schema (confirmed directly: the wrapper's own
     semantic validator checks only JSON type for these three fields, never non-emptiness, unlike
     `verification`, which it does check for non-emptiness) and is NOT rejected here.** **`line` must
     ALSO be checked here, not just resolved and rendered (new — closes a real gap found during
     design review: step 2 above already resolves `line` as one of the fields, and step 4's own
     canonical template renders it, but this completeness check never validated it at all — the
     actual verdict schema requires `line` and constrains it to either `null` or an integer `>= 1`,
     so a resolver/transformation bug that drops or corrupts this ONE field would silently pass this
     check and send an incomplete or malformed digest, undetected.)** Fixed: `line` is additionally
     checked here — present, and either `null` or an integer `>= 1`, matching the schema's own exact
     constraint — never merely resolved-and-trusted. An earlier
     revision required non-empty, which would have let one legitimately (if unusually) blank-field
     finding — accepted by the wrapper as schema-valid — permanently fail this check for as long as
     that claim stays open, disabling compaction for the whole rest of that session over a case that
     was never actually a formatter bug. Given `block_text` is now DERIVED from these exact fields
     (step 4 below), a check on TYPE (did the resolved object have the right shape at all) is what
     actually matters for spoofing-resistance — a check on CONTENT (is the review data itself
     interesting) is a different, unrelated concern this step was never meant to enforce.
   - Neither check can be spoofed by anything a rendering step might later produce, because neither
     ever inspects rendered prose — both read only the resolved fields, sourced directly from the
     finding record the reducer already resolved.
4. **Only once step 3 passes (both checks) is `block_text` computed — as a pure, canonical function
   of the ALREADY-VALIDATED fields from step 2, in the same step, never a separately/independently
   rendered value (closes a real divergence gap found during design review: the previous revision
   validated sidecar fields but rendered `block_text` through a separate path that could still
   diverge from them — confirmed directly with a counterexample object whose sidecars were valid
   but whose `block_text` was a heading-only string; the fix removes the second path entirely by
   deriving `block_text` from the checked values themselves, e.g. a fixed template `"OPEN CLAIM
   <claim_id>:\nfile: <file>\nline: <line>\nseverity: <severity>\nsummary: <summary>\nevidence:
   <evidence>"` — there is no way for the sent text to omit content the check already confirmed
   present, because the sent text IS built from that exact, already-validated content).** The final
   flattening (one deterministic concatenation, a 1:1 map with nothing filtered) produces the prose
   sent to Codex. `OPEN CLAIM <claim_id>:` remains as a heading purely for Codex's own readability —
   it is never re-parsed by `/ccs`'s own code again after this point.
5. On any structural or content-completeness mismatch in step 3: log a one-line narration note, and
   skip straight to the normal `--resume` fallback (see "On failure" below) — never attempt to
   dispatch an unverified or incomplete digest.

### Restart mechanism

There is no way to shrink an existing thread's own context, so compaction means **abandoning the
old thread and starting a genuinely fresh one**. A compaction attempt is entirely self-contained —
its own success or failure is never itself reported as this round's terminal outcome; see "Failure
isolation from the round loop" below.

0. **The EXISTING mandatory round-2+ active-snapshot revalidation always runs first, unconditionally
   — never bypassed or reordered by compaction (closes a real ordering gap found during design
   review).** Round R's own pre-dispatch snapshot check (`references/snapshot-integrity.md`) —
   validating the CURRENTLY ACTIVE `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST`, unrelated to anything
   compaction is about to do — runs exactly as it does for every other round, BEFORE the threshold
   check that decides whether to attempt compaction at all. If that existing check fails, the
   EXISTING `🛑 SNAPSHOT INTEGRITY FAILURE` hard stop fires immediately, exactly as today — a
   corrupted active snapshot is never silently "fixed" by proceeding into a compaction attempt that
   would replace it with a fresh candidate; that would hide a real integrity failure rather than
   report it.

   **This "always runs first" is about ORDINARY per-round dispatch, not about reconstructing the
   remembered facts it checks against — those two are sequenced the other way around during
   continuity recovery (clarifying — closes a real ordering gap found during design review: this
   step's own "always runs first, unconditionally" wording, read literally, would have this base
   check fire — and hard-stop — on the intentional, EXPECTED digest change a successful compaction
   just made, before the separate post-append recovery logic (see "PROVISIONAL_SNAPSHOT_FILE... Post-
   append window" above, and its `SNAPSHOT_DIGEST`-advancement fix) ever gets a chance to reconcile
   the remembered `SNAPSHOT_DIGEST` with what the log says actually happened.)** The two checks
   answer different questions and run at different times: THIS step's job is "does the ACTIVE file
   still match what Claude currently remembers," and it assumes that remembered value is already
   correct going in. Reconstructing what that remembered value SHOULD be, after an interruption, is
   the job of the post-append recovery logic instead — **triggered by searching the WHOLE session log
   for the most recent round that ever recorded compaction lineage, never by checking only whether
   the LATEST completed line happens to be one (corrected here to match the recovery algorithm's own
   later fix — closes a real internal contradiction found during design review: an earlier revision
   of THIS clarifying note still said "an interruption whose latest completed line shows a successful
   compaction," while the recovery algorithm itself was separately corrected to search the whole log
   instead — once even one ordinary round completes after a successful compaction, "the latest line"
   is no longer that compaction's own line, so this note's own narrower trigger would incorrectly
   skip reconstruction exactly where the algorithm's own broader trigger says it must still run)** —
   which is a one-time, continuity-recovery-only step, run once, BEFORE this step's own check is ever
   invoked for the first round dispatched after that recovery (whether completing an interrupted
   promotion or merely confirming one already finished, per that section's own 3-way branch). Once
   that recovery step has updated the remembered `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` (or confirmed no
   update was needed), THIS step proceeds exactly as already described, now correctly informed.
   Outside of continuity recovery — the ordinary case, no interruption having occurred — there is
   nothing to reconcile and this step simply runs first as originally stated.
1. Build `COMPACT_DIGEST` via the structured-data-first construction above; abort to the normal
   `--resume` fallback (step 6) immediately if its own structural verification fails.
2. **Non-repo-artifact sessions are a SEPARATE case, handled BEFORE the scope branches below (closes
   a real gap found during design review: an earlier draft never considered this case at all, and
   would have silently lost the reviewed content entirely on restart).** A non-repo-artifact
   session (`references/non-repo-artifact.md`) dispatches `--uncommitted` against an intentionally
   EMPTY `CLEAN_REPO_DIR` — the actual reviewed material lives only in `--focus` text, never in the
   diff. If compaction naively re-collected "the diff" here, it would recollect an empty diff and
   the fresh thread would never see the artifact at all. **Fixed:** for a non-repo-artifact session,
   compaction (a) allocates NO new snapshot — like `--commit` scope, the ORIGINAL round-1 snapshot
   (which, per `references/snapshot-integrity.md`, already holds the exact pasted artifact bytes for
   this session type) remains active and untouched throughout; (b) the fresh restart's focus text
   includes the ORIGINAL ARTIFACT TEXT in addition to `COMPACT_DIGEST` — exactly mirroring how round
   1 itself had to paste the artifact into focus text for this session type (see `SKILL.md`'s own
   Phase 1 Step 0 non-repo-artifact rule).

   **Bind the dispatched bytes to the SAME verified copy the hash-check ran against — never a
   separate re-read (new — closes a real check-then-use race found during design review): an
   earlier revision validated `SNAPSHOT_FILE` against `SNAPSHOT_DIGEST` in step 0's existing
   revalidation, then, LATER, separately re-opened and read that same (mutable) file's content to
   embed in focus text. Between those two operations, the file could be modified, so a CLEAN
   compaction restart could end up reviewing altered bytes despite the earlier check having passed.**
   Fixed: read `SNAPSHOT_FILE`'s content into a captured copy exactly ONCE, at this step — hash that
   SAME captured copy and confirm it equals `SNAPSHOT_DIGEST` before using it for anything. If it
   matches, embed that verified copy's content into the fresh restart's focus text (never re-open or
   re-read the original file a second time for this purpose). If it does NOT match, this is the
   EXISTING `🛑 SNAPSHOT INTEGRITY FAILURE` hard stop, exactly as an ordinary round's own pre-dispatch
   revalidation already handles — never a silently-accepted mismatch.

   **Revalidate `CLEAN_REPO_DIR`'s own cleanliness before trusting it — never simply assumed (new —
   closes a real isolation gap found during design review: an earlier revision assumed the
   `--uncommitted` dispatch against `CLEAN_REPO_DIR` "still produces an empty diff, as always,"
   without ever re-checking that assumption at compaction-restart time. `CLEAN_REPO_DIR` is created
   once and reused for the whole session — if anything unexpected polluted it since round 1 (a stray
   file, an unrelated bug elsewhere touching the path), a fresh dispatch against it would collect
   REAL tracked/untracked content and silently mix it into what is supposed to be a strictly
   artifact-only review, breaking the isolation this whole mechanism exists to guarantee).** Fixed:
   immediately before this dispatch, verify `CLEAN_REPO_DIR` is (still) clean — see the fully-specified
   check below (this opening statement intentionally does not repeat the exact check here, to avoid
   the SAME "two contradictory descriptions of one check" gap already found and fixed once in this
   exact spot during design review: an earlier revision left THIS sentence describing the original,
   since-abandoned `git status`-based test even after the real check was replaced below).

   **This check must ALSO cover git-ignored content, not just tracked/untracked-unignored files (new
   — closes a real gap found during design review, confirmed live: `git status --short
   --untracked-files=all` genuinely omits ignored paths — running it against this very repository
   shows nothing, while adding `--ignored=matching` additionally reveals real, present files like
   `.DS_Store` and a worktrees directory. Since Codex's own investigation during a turn can see
   whatever actually sits in its CWD regardless of what git status flags, an ignored-but-present file
   would silently defeat this whole cleanliness guarantee even though the check reports success.)**

   **`git status`, in ANY combination of flags, can never prove the directory holds nothing —
   committed content is invisible to it entirely (corrected — closes a real, more fundamental gap
   found during design review, confirmed live: `git status --short --untracked-files=all
   --ignored=matching` reports changes RELATIVE TO `HEAD` — it says nothing whatsoever about content
   that is already fully committed with a clean working tree. Run against an ordinary clean repo with
   real committed files and a valid `HEAD`, this command produces EXACTLY ZERO bytes of output —
   confirmed directly — while `git ls-files` and `git rev-parse --verify -q HEAD` both show real,
   substantial content is present. If `CLEAN_REPO_DIR` ever accumulated an actual commit through any
   bug or unexpected process, every `git status`-based cleanliness check, however many flags it
   carries, would report "clean" while real files sit there for Codex's own investigation to find.)**
   Fixed: replace the `git status`-based check entirely with THREE direct facts `git status` cannot
   provide: (1) the directory contains NO entries at all other than `.git` itself (a literal
   directory listing — e.g. `find "$CLEAN_REPO_DIR" -mindepth 1 -maxdepth 1 ! -name .git`, through the
   same anchored/sanitized invocation pattern, expected to produce no output); (2) `CLEAN_REPO_DIR` IS
   genuinely a git working tree (`git rev-parse --is-inside-work-tree` expected to output EXACTLY
   `true`); and (3) that repository's own HEAD has NEVER been given a commit (`git rev-parse --verify
   -q HEAD` expected to FAIL/exit nonzero). **Check (2) is required, not redundant with (3) alone
   (new — closes a real gap found during design review, confirmed live: a directory that is NOT a git
   repository at all — or even a plain regular file in place of a directory — ALSO satisfies "`find`
   produces no output" (if empty) AND "`git rev-parse --verify -q HEAD` fails" (exit 128, "not a git
   repository," a COMPLETELY DIFFERENT failure than the desired "unborn HEAD" case) — so checks (1)
   and (3) alone cannot actually distinguish the intended state (a real, empty, commit-less git repo)
   from `CLEAN_REPO_DIR` having been deleted, replaced, or never properly initialized at all, letting
   a broken CWD silently reach the wrapper's own later git/`cd` operations instead of being caught
   here.)**

   **Two further gaps in the SAME spirit, both closing "properties, not identity" holes (new —
   closes real gaps found during design review, confirmed live against this very repository): (4)
   NOTHING checked whether `CLEAN_REPO_DIR`'s own literal path had been replaced by a SYMLINK to some
   OTHER, unrelated location — both `git -C` and the wrapper's own `cd "$CWD"` transparently follow
   symlinks, so if `CLEAN_REPO_DIR` were swapped for a symlink pointing at a DIFFERENT, ALSO-empty,
   ALSO-commit-less git repo, checks (1)-(3) would all report "clean" while every dispatch actually
   operated against a completely different directory than the one Claude originally created. (5)
   `--is-inside-work-tree` only confirms a path lives SOMEWHERE inside SOME git working tree — it does
   NOT confirm that path is the ROOT of its own independent repository: confirmed live that a nested
   subdirectory of an unrelated repository (`.worktrees`, in this repo) ALSO reports
   `--is-inside-work-tree=true`, while its own `--show-toplevel` correctly resolves to the PARENT
   repository, not itself — proving check (2) alone cannot rule out `CLEAN_REPO_DIR` having become
   merely a subdirectory nested inside some other, unrelated repository rather than its own
   independent one.)** Fixed: two more checks, for five total: (4) `CLEAN_REPO_DIR`'s own literal path
   is NOT itself a symlink (`[ ! -L "$CLEAN_REPO_DIR" ]` — this targets only whether the LEAF path
   itself was replaced, never whether some ANCESTOR directory happens to resolve through a symlink at
   the OS level, e.g. macOS's own ordinary `/tmp` → `/private/tmp`, which is normal and not a
   pollution signal); and (5) `git rev-parse --show-toplevel` output EQUALS `CLEAN_REPO_DIR`'s own
   canonical path exactly, confirming it is the genuine ROOT of its own independent repository, never
   merely nested inside something else.

   **A SIXTH check is still needed — `.git` itself must be a genuine, self-contained directory, never
   a gitfile/symlink borrowing metadata from elsewhere (new — closes a real gap found during design
   review, confirmed live via TWO separate reproductions: (a) a linked git WORKTREE's own
   `--show-toplevel` returns that worktree's OWN local root — satisfying check (5) — even though its
   `--git-dir`/`--git-common-dir` point OUTSIDE it, into a completely different repository's shared
   metadata; (b) an ordinary empty, non-symlink directory, paired via `--git-dir=`/`--work-tree=` with
   a DIFFERENT, already-existing unborn git directory, was independently confirmed to satisfy ALL
   FIVE checks above simultaneously — `is-inside-work-tree=true`, its own correct top-level path, a
   failing/unborn `HEAD` lookup, no symlink, and (trivially) no stray entries. In BOTH cases, the
   directory's identity checks all pass while the git METADATA governing what `--uncommitted` actually
   collects is silently borrowed from somewhere else entirely — check (1)'s own exemption for an entry
   literally named `.git` never verified what that entry actually IS.)** Fixed: `CLEAN_REPO_DIR/.git`
   must itself be a real, ordinary DIRECTORY — never a plain file (the standard git-worktree gitfile
   format, `gitdir: <path>`) and never a symlink (`[ -d "$CLEAN_REPO_DIR/.git" ] && [ ! -L
   "$CLEAN_REPO_DIR/.git" ]`).

   **This alone is STILL insufficient — an ordinary, non-symlink `.git` directory can itself contain a
   `commondir` file redirecting shared metadata elsewhere, an entirely different indirection mechanism
   than the gitfile/symlink form just closed (new — closes a real gap found during design review,
   confirmed live: per git's own `gitrepository-layout(5)` documentation, a `commondir` file inside a
   Git directory sets the effective `GIT_COMMON_DIR` to its own target — reproduced directly: with a
   local, genuinely-a-directory, non-symlink `.git` whose own `commondir` file points at an unrelated
   repository, EVERY check up through the ordinary-directory check above still passes — including
   `is-inside-work-tree=true`, the correct own toplevel, and a failing/unborn `HEAD` lookup — while
   `git rev-parse --git-common-dir` reveals the borrowed external path. The gitfile/symlink check
   above closes ONE indirection mechanism; `commondir` is a SEPARATE one, operating from INSIDE an
   otherwise entirely ordinary `.git` directory.)** Fixed with a single, more general check that
   SUBSUMES both indirection mechanisms rather than chasing a third, fourth, or fifth: `git rev-parse
   --git-dir` AND `git rev-parse --git-common-dir`, each resolved to its own canonical absolute path,
   must BOTH equal `CLEAN_REPO_DIR/.git`'s own canonical absolute path — verifying the actual GIT-LEVEL
   fact that matters (no metadata is borrowed from anywhere, by any mechanism) rather than continuing
   to enumerate every possible filesystem-level trick that could produce that same effect.

   **This claim of "closes the class of gap... by any mechanism" was itself proven wrong one round
   later — `git-dir`/`common-dir` identity says nothing about OBJECT borrowing, a THIRD, independent
   indirection mechanism (new — closes a real gap found during design review, confirmed live: per
   git's own `gitrepository-layout(5)` documentation, an `objects/info/alternates` file — nested
   INSIDE the already-permitted `.git` directory, at `.git/objects/info/alternates` — lets git borrow
   OBJECTS from a listed external repository's own object store, entirely independent of `--git-dir`/
   `--git-common-dir`, which stay pointed at the local `.git` throughout. Reproduced directly: with
   such a file present, ALL SEVEN checks above still pass (empty entry listing, correct
   `is-inside-work-tree`, correct own toplevel, correct `git-dir`/`common-dir` identity, unborn `HEAD`)
   while `git cat-file -p` successfully reads real content from the FOREIGN repository's own object
   store.)** Fixed: an eighth check — `.git/objects/info/alternates` (relative to the local `.git`
   directory just confirmed above) must NOT exist (or, if present, must be empty) — closing this
   specific, now-confirmed mechanism the same way every other confirmed one in this section has been
   closed.

   **A candid scope statement, after three consecutive rounds each surfacing a DIFFERENT git
   indirection mechanism (gitfile/symlink, `commondir`, now `alternates`): this checklist-based
   approach cannot claim to be an EXHAUSTIVE, adversarially-hardened defense against every conceivable
   git extension point (hooks, submodules, custom refs, sparse-checkout redirection, and others not
   yet enumerated here could each be its own future mechanism) — closing each CONFIRMED gap as it is
   found is the practical, honest bar this design holds itself to, not a claim that no further
   mechanism could ever exist.** This is a defensible scope, not merely a shortcut: `CLEAN_REPO_DIR`
   is created once by this skill's own trusted Phase 0 setup, and these checks exist to catch
   UNEXPECTED, ACCIDENTAL drift (a stray file, an unrelated bug elsewhere touching the path) — not to
   defend against a sophisticated, deliberately adversarial actor with enough local write access to
   plant a crafted `.git` directory in the first place, since that same actor would already have
   comparable access to sabotage the session through many OTHER paths this design has no power to
   close either. **Corrected citation (closes a real gap found during design review: an earlier
   revision here cited `references/git-safe.sh` as if it were a reference document with its own
   "Non-goals" section — but the actual file, `codex-stream-review/scripts/lib/git-safe.sh`, is a
   SCRIPT, not a reference doc, and contains no such section at all; the citation was fabricated,
   leaving this scope justification unverifiable from where it claimed to point.)** This same
   "not a defense against a deliberately changed source" trust-boundary framing is the one already
   established and used repeatedly elsewhere in THIS document (see, e.g., `--base` scope's own
   merge-base drift disclosure, and `references/snapshot-integrity.md`'s own identically-worded
   non-goal) — reused here by the SAME reasoning, not by any claim that `git-safe.sh` itself
   documents non-goals of its own. Cleanliness means ALL EIGHT checks
   pass — a bare, freshly-`git init`'d, genuinely-independent, non-symlinked, self-contained git repo
   directory with no files, no commits, no borrowed metadata, and no borrowed objects — never inferred
   from the absence of DIFFS, never from a `git rev-parse` failure whose EXACT cause was never actually
   confirmed, never from mere membership in SOME working tree, and never from filesystem-level or
   git-dir/common-dir identity checks alone without also confirming no object-level borrowing is
   configured. **A
   residual, disclosed risk this does not close (citation corrected — closes a sibling gap to the one
   found and fixed in this same section elsewhere: this note previously misattributed
   `scripts/lib/git-safe.sh` to `references/snapshot-integrity.md`, which does not mention that
   script at all — `git-safe.sh` is the wrapper's own separate helper script, not something
   `snapshot-integrity.md` owns or references):** `codex-stream-review/scripts/lib/git-safe.sh`'s own
   sanitization (e.g. neutralizing a repo-local `core.fsmonitor` hook that could otherwise execute a
   command) protects the WRAPPER's own git invocations specifically — it
   says nothing about whatever Codex itself might independently choose to read or execute from
   `.git/config` during its own investigation of this same CWD. Hardening Codex's own sandboxed
   behavior against a hypothetically malicious `.git` directory is a base-sandbox-model concern well
   beyond this design's own scope — disclosed, not solved, here.**

   **A second residual, disclosed risk: a check-then-use race remains between these eight checks
   completing and the wrapper's own LATER, separate use of the same `$CWD` pathname (new — closes a
   real gap found during design review: these checks all resolve the pathname locally, then dispatch
   happens afterward — the wrapper itself independently re-resolves `$CWD` twice more, once for its
   own `git -C "$CWD"` calls and once for its `cd "$CWD"` launch step. If `CLEAN_REPO_DIR` were
   replaced or swapped for a symlink in the narrow window between these checks finishing and either of
   those later resolutions, none of the eight checks would have observed it.)** This is inherent to any
   "verify a pathname locally, then hand it to a separately-invoked process" pattern and cannot be
   fully closed without a mechanism this design does not have available (e.g. resolving to a file
   descriptor and passing THAT to the wrapper, rather than a re-resolvable pathname — a change to the
   wrapper's own invocation contract, out of scope here). Accepted as a narrow, low-probability,
   disclosed residual window — the eight checks close every gap that persists BETWEEN separate,
   independent uses of the same session-lived pathname (the realistic threat this design addresses),
   not a race against a change happening in the same instant as dispatch itself.

   **Corrects a false claim made while fixing this: there is no "original round-1 creation-time
   check" for this addition to also apply to (new — closes a real gap found during design review: an
   earlier revision asserted this `--ignored=matching` fix "applies everywhere else this design or
   the base `references/non-repo-artifact.md` mechanism performs this identical check... the original
   round-1 creation-time check included" — but the base mechanism's own actual setup, per that
   reference in full, only ever `mkdir`s `CLEAN_REPO_DIR` and runs `git init` in it, then dispatches
   directly; it never runs ANY cleanliness check of its own, at creation time or otherwise. The
   phrasing this fix's own OPENING sentence used — "re-run the same cleanliness check `CLEAN_REPO_DIR`
   was created to satisfy" — repeated the identical false premise.)** Corrected: this compaction-owned
   recheck (in its current, fully-corrected form above) is the ONLY point at which `CLEAN_REPO_DIR`'s
   cleanliness is EVER verified in this whole mechanism — starting from the FIRST compaction attempt
   onward. Round 1's own very first artifact dispatch against `CLEAN_REPO_DIR`, and any session that
   never triggers compaction at all, remain fully exposed to exactly this same pollution risk with NO
   check of any kind — a real, disclosed, PRE-EXISTING gap in the base mechanism itself, not
   introduced or widened by compaction, and out of scope for this design document to close (doing so
   would mean adding a new check to the base skill's own Phase 0/Phase 1 setup, which this document
   does not own).

   If any of the eight checks is not clean, this is
   treated exactly like any other compaction failure (log the narration, fall through to the normal
   `--resume` fallback) — never dispatch against a `CLEAN_REPO_DIR` whose emptiness wasn't just
   reconfirmed. Only once this check passes does the `--uncommitted` dispatch against `CLEAN_REPO_DIR`
   proceed, producing an empty diff as designed, with the wrapper's own no-diff branch falling back
   to reviewing the focus text — now containing both the artifact and the digest. **This is a
   genuinely separate branch from the scope-dependent handling below, not an extra step layered on
   top of it.**

   **This recheck runs before EVERY separate fresh dispatch for a non-repo-artifact session, not only
   the very first one (new — closes a real gap found during design review: the no-threadId fresh
   retry and the fresh-B escalation — see "Reconciling with `references/retry-guards.md`'s OWN full
   escalation topology" above — are each their OWN separate fresh dispatch attempts, dispatched at a
   LATER moment than the original attempt this check was originally written for; neither repeated
   this recheck, leaving a real window in which `CLEAN_REPO_DIR` could become polluted between the
   original attempt and a later retry, going undetected).** Fixed: this cleanliness recheck is a
   mandatory precondition of ANY fresh dispatch under a non-repo-artifact session — the original
   attempt, the no-threadId fresh retry, and thread B's own fresh dispatch alike — never assumed
   still valid from an earlier check moments (or minutes, across resume-retry cycles) in the past.

   **Also required immediately before compaction's own step 6 fallback dispatch, for a non-repo-
   artifact session specifically (new — closes a real gap found during design review: the wrapper
   changes into `--cwd CLEAN_REPO_DIR` for a `--resume` launch exactly as it does for a fresh one —
   confirmed directly against the wrapper's own source — and `references/non-repo-artifact.md`
   documents that this working directory governs Codex's own investigation context for the WHOLE
   turn, even though `--resume` itself skips diff re-collection; a compaction attempt that just
   touched/considered `CLEAN_REPO_DIR`'s cleanliness this same round, then falls through to a
   fallback dispatch sharing that identical directory, should not let that fallback proceed on a
   stale, unrenewed cleanliness assumption).** Fixed: the SAME recheck also runs immediately before
   step 6's own fallback dispatch, whenever this session is non-repo-artifact — if it fails, this is
   treated exactly like any other narration-only compaction-adjacent issue, never blocking the
   fallback itself from proceeding (the fallback is this round's own real, required outcome; a
   polluted `CLEAN_REPO_DIR` at this point is logged as a disclosed risk, not a hard stop, since
   there is no further fallback beneath the fallback). **Ordinary, non-compaction `--resume` rounds
   sharing this identical base-skill property (no round is otherwise ever forced to recheck
   `CLEAN_REPO_DIR`'s cleanliness before an ordinary resume) are an inherited, pre-existing
   limitation this feature does not newly introduce and is out of scope to fix here** — closing it
   fully would mean changing the base skill's own ordinary per-round dispatch behavior, a change this
   design document does not own.

   **Every `--resume` call that is part of COMPACTION'S OWN internal retry machinery gets this SAME
   recheck too, not only the two "boundary" dispatches named above (new — closes a real gap found
   during design review: an earlier revision covered only the very first fresh dispatch and the
   first fallback attempt — but candidate A's own bounded resume-retries, the bullet-3 "resume the
   same existing thread once" retry, and a retried fallback dispatch (per this design's own reuse of
   `references/retry-guards.md`'s bounded-retry conventions for a resume-safe fallback failure) are
   ALL separate `--resume` calls of their own, each changing into the SAME `CLEAN_REPO_DIR` CWD, and
   none of the intermediate ones were covered — only the first and last of a potentially longer
   chain).** Fixed: this recheck is a mandatory precondition of EVERY dispatch — fresh or resumed —
   that is part of compaction's own attempt sequence for a non-repo-artifact session: candidate A's
   own dispatch and every one of its resume-retries, the no-threadId fresh retry, thread B's own
   dispatch, the fallback dispatch, and any retry of the fallback itself.

   **Fail CLOSED wherever a real alternative still exists — the earlier "log and continue" framing
   for intermediate resumes overclaimed "nowhere further to fall back to" when a real fallback WAS
   available (corrected — closes a real gap found during design review: candidate A's own
   resume-retries, and the bullet-3 same-thread retry, are NOT actually out of options on a failed
   cleanliness recheck — this design already has a well-defined "abandon this compaction attempt" path,
   step 6's fallback, available to them exactly as it is to any other compaction failure; treating a
   KNOWN-polluted CWD as an acceptable, merely-logged risk here — rather than simply routing to the
   fallback that already exists for this exact purpose — let a detected problem reach Codex anyway
   when a safe alternative was sitting right there.)** Fixed: candidate A's own resume-retries and the
   bullet-3 same-thread retry treat a failed recheck exactly like any other compaction failure —
   abandon this compaction attempt, fall through to step 6's fallback, never dispatch into a
   KNOWN-polluted directory. **This abandonment must durably record candidate A's OWN already-known
   thread id before falling through, exactly like bullet 3's own exhaustion fix above — this is a
   LOCAL, pre-dispatch check failure, never a wrapper response, so nothing about "checking the
   response for a threadId" applies here at all (new — closes a real gap found during design review:
   this fail-closed path was added specifically to correct the earlier fail-open version, but never
   itself said to add A's id to `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` — candidate A
   ALREADY has a known thread id by the time any of ITS OWN resume-retries are even attempted
   (exactly the same precondition bullet 3's own exhaustion fix relies on), and this check failing
   BEFORE the resume dispatch is attempted at all means there is no response to inspect — the
   abandonment is entirely local knowledge, not something a wrapper response could confirm or deny.)**
   Fixed: this abandonment unconditionally adds A's own already-known thread id to
   `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` before falling through — the exact same
   "always record the already-known id, never contingent on a response" principle as bullet 3's own
   exhaustion fix, applied here for the identical underlying reason (the id is already known; nothing
   new needs discovering). The "log and continue, disclosed risk" treatment is reserved ONLY for the
   step 6 fallback dispatch itself and any retry OF that fallback — these are the true last resort,
   genuinely having nowhere further to fall back to, since they ARE this round's own final, required
   outcome. The ORIGINAL fresh dispatches (candidate A's first attempt, the no-threadId retry, thread
   B) already had, and keep, their existing hard "fall through to the normal compaction failure path"
   behavior when this recheck fails.
3. **Repo-diff sessions — snapshot candidate lifecycle, fully specified (closes a real ownership/
   leak gap found during design review: the original draft allocated a new snapshot but never said
   who deletes it on failure, or exactly when the pointer swaps on success).** Re-collection
   handling depends on round 1's original scope, as before.

   **Disclosed limitation, inherited from round 1's own identical property, not new to compaction
   (new — closes a real gap found during design review: the candidate below is collected and hashed
   by Claude's OWN local git invocation, BEFORE the wrapper is ever dispatched; the wrapper then
   independently re-collects its own `DIFF_TEXT` internally, at its own later moment, since it
   accepts no snapshot/payload argument at all — if the source changes in that gap, the candidate
   Claude hashed and the content the fresh thread actually reviewed can diverge, and every later
   verification of the candidate — including the live pre-promotion checks above — only proves the
   candidate itself wasn't corrupted AFTER Claude collected it, never that it equals what the
   dispatch truly reviewed. This is especially pronounced for untracked files, whose CONTENT is
   collected by the wrapper but whose entry in this design's own snapshot may only track their
   names.)** This is the SAME accepted non-goal `references/snapshot-integrity.md` already documents
   for round 1's own original collect-then-dispatch gap ("not a defense against a deliberately
   changed source") — round 1 has the identical timing window between its own local collection and
   the wrapper's own internal one, and this design has never claimed to close it there either.
   Compaction inherits this exact property unchanged; it is not a new or widened gap this feature
   introduces, and closing it for either case would require the wrapper itself to accept a pinned
   payload rather than always re-collecting live — out of scope for this design.
   - **`--uncommitted`:** re-collect the diff into a NEW candidate `SNAPSHOT_FILE`, hash it into a
     candidate `SNAPSHOT_DIGEST` (same mechanism as Phase 0 step 5 / Phase 1's post-sizing step) —
     the working tree may genuinely have changed since round 1, so this is the one case
     re-collection is meaningful for.
   - **`--base <ref>`:** re-collect `${ref}...HEAD` again into a new candidate the same way — this
     DOES pick up any new commits landed on `HEAD` since round 1, but does **not** reflect
     uncommitted working-tree changes (disclosed limitation: a fix applied but not yet committed
     will not appear in this re-collection).
   - **`--commit <value>`:** re-collecting this scope's diff is byte-identical every time **ONLY
     WHEN `<value>` is itself an immutable, already-resolved commit SHA — corrected here (closes a
     real assumption error found during design review): an earlier draft treated EVERY accepted
     `--commit` value as inherently immutable, but the wrapper's own argument parser accepts any git
     revision expression (confirmed directly against the wrapper's source — it rejects only a
     leading-dash value, never validates or resolves the value to a fixed SHA), so `--commit HEAD`
     or `--commit main` is legal and can resolve to a genuinely different commit by the time a
     compaction restart happens, if that ref moved since round 1.** Fixed: resolve `git rev-parse
     <value>` — through the SAME anchored, sanitized `env -i`/isolated-`HOME` invocation this file
     already uses for every direct git call outside the wrapper (see "Determine review mode" in
     `SKILL.md`'s Phase 1 for the canonical pattern) — into `target.resolved_commit_sha`, and use
     THAT resolved SHA, not the original literal `<value>`, for round 1's OWN scope-dependent
     sizing/snapshot-collection/dispatch, in addition to every later compaction restart.

     **Verify the resolution is a single, clean commit SHA before ever pinning to it (new — closes a
     real regression found during design review, confirmed live: plain `git rev-parse <value>` does
     NOT always emit one commit object. For a range-shaped value the wrapper's own `--commit` branch
     already handles successfully today — e.g. `HEAD^..HEAD` — `rev-parse` emits the positive commit
     PLUS a separate `^<parent>` exclusion line; feeding that two-line output back in as a single
     `--commit` argument fails git resolution outright (confirmed: exit 128), which would make
     compaction (and, with the round-1 pinning fix above, even round 1 itself) newly BREAK a scope
     value the wrapper currently accepts and handles fine unpinned.)** After resolving, verify the
     output is EXACTLY one line matching a bare commit-SHA shape (`^[0-9a-f]{7,64}$`). **If it
     matches:** pin to it as designed. **If it does NOT** (multiple lines, a range, or anything else
     non-SHA-shaped): do NOT pin at all — round 1 dispatches with the ORIGINAL literal `<value>`
     exactly as the wrapper already does today (zero behavior change for this narrow case), no
     `target.resolved_commit_sha` is recorded, and compaction is simply never attempted for the rest
     of THIS session under this scope (every later threshold check no-ops immediately, falling
     through as if compaction were never enabled) — disclosed as an accepted, narrow limitation:
     ref-drift protection and compaction restart are both unavailable specifically for a `--commit`
     value that isn't a single resolvable commit, since `--commit` scope's own intent (review one
     commit's own patch) makes a multi-revision expression an edge case of the accepted grammar, not
     the common path this design needs to optimize for.

     **Round 1 itself must be pinned too, not only the compaction restart (closes a real gap found
     during design review: an earlier revision pinned only the COMPACTION round to the resolved SHA,
     leaving round 1's own dispatch still using the raw, potentially-movable literal value — the
     wrapper resolves that literal independently, at its own moment, during its own collection. If
     the ref moves between OUR round-1 resolution and the WRAPPER's own separate round-1 resolution,
     round 1 could review a DIFFERENT commit than the one durably recorded — and a later compaction
     restart would then "correctly" pin back to the ORIGINAL resolution, reviewing yet a THIRD state
     relative to what round 1 actually saw). Fixed: the resolve-once-then-pin discipline applies
     from round 1 onward, uniformly — resolution happens exactly once, before ANY scope-dependent
     collection for this session (round 1's own sizing/snapshot/dispatch included), and the
     resulting SHA is the ONLY value ever used for a real git operation under `--commit` scope for
     the rest of the session. The original literal `<value>` the user typed is retained purely as
     `target.scope_value`, for audit/display, never used for a git operation again after this one
     resolution. This closes the loop completely: from round 1 through every possible compaction
     restart, `--commit` scope operates on one single, immutable commit for the whole session.** A
     resolved SHA is immutable by git's own guarantee (barring history rewriting, already covered by
     `references/snapshot-integrity.md`'s existing "not a defense against a deliberately changed
     source" non-goal), so pinning once, this early, closes the race entirely rather than narrowing
     it, and is MORE consistent with `--commit` scope's own intent (review one specific, fixed
     commit's patch) than ever re-resolving a movable name a second time. No candidate snapshot is
     ever allocated for `--commit` scope; the ORIGINAL round-1 `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST`
     remains the active snapshot, untouched, through every subsequent round including any
     compaction restart.
   - **Durably persisting the original scope ARGUMENT, not just its category (new — closes a real
     recovery gap found during design review).** An earlier draft recorded only `target.scope`
     (`"base"`/`"commit"`/`"uncommitted"` as a category), never the actual `<ref>`/`<value>` VALUE —
     without that value durably logged, continuity recovery (or a later compaction restart) has no
     way to know what to re-dispatch against for `--base`/`--commit`. Fixed: round 1's own JSONL
     line (not only a compaction round's) gains a new field, `target.scope_value` — the literal
     `<ref>`/`<value>` string for `--base`/`--commit` scope, omitted for `--uncommitted` (which has
     no such argument) — plus, for `--commit` specifically, `target.resolved_commit_sha` (see
     above). A compaction restart under `--base` scope reuses the EXACT durably-recorded
     `scope_value`, never a freshly-typed or re-derived one; a compaction restart under `--commit`
     scope uses the durably-recorded `resolved_commit_sha` instead (see above — pinned directly, not
     the original literal value). **Disclosed limitation, inherent to `--base <ref>` where `<ref>`
     names a movable branch:** re-dispatching
     with the same literal `<ref>` string can still resolve to a different merge-base if that branch
     has advanced since round 1 — this is the same class of "not a defense against a deliberately
     changed source" non-goal `references/snapshot-integrity.md` already accepts elsewhere, not a
     new gap compaction introduces (unlike `--commit`, `--base`'s own resolved merge-base is not
     separately pinned/verified here — its scope is defined relative to the CURRENT `HEAD` by
     design, so "the merge base may have moved" is expected scope behavior, not drift); pinning
     `--base` further would change what `--base` scope actually MEANS,
     which is out of scope for this feature to alter.
   - **Ownership, for `--uncommitted`/`--base` (where a real candidate exists):** the candidate
     file is a NEW, separate temp file — the ACTIVE (old) `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` used
     for round-2+ revalidation is left completely untouched while the candidate merely sits on
     disk. **On compaction failure (step 6 below): delete the candidate file immediately** (it was
     never used for anything) **and continue revalidating rounds against the untouched original
     active snapshot** — the fallback `--resume` round's own snapshot check has an unchanged
     baseline to validate against, exactly as if compaction had never been attempted.

     **On success, promotion is ONE atomic rename onto the fixed `SNAPSHOT_FILE` path, never a
     separate delete-then-move (corrected — closes a real gap found during design review: an
     earlier revision described this as two sequential steps, "delete the OLD active snapshot file,
     AND promote the candidate" — which (a) creates a real window where the active path is
     genuinely missing (old deleted, new not yet in place) that a later recovery step then wrongly
     treated as unrecoverable corruption, since it never distinguished "missing because promotion is
     mid-flight" from "missing because something is actually broken," and (b) left "promote the
     candidate" itself ambiguous between two incompatible readings — reassigning which literal path
     Claude calls `SNAPSHOT_FILE` (a pointer change, no physical file operation) versus physically
     moving bytes into the ORIGINAL fixed path (keeping the path itself constant) — each of which
     breaks a different part of the recovery logic below if assumed silently.)** Fixed: `SNAPSHOT_FILE`
     is, and remains, ONE fixed literal path for the entire session, exactly like `REPO_ROOT`/
     `SESSION_ID` (see "Recoverable without giving up `mktemp`'s own symlink-attack protection" just
     below) — promotion NEVER reassigns which path Claude calls `SNAPSHOT_FILE`; it always physically
     replaces that fixed path's own content. Concretely, only after this round's JSONL append is
     verified (step 5 below): `mv "$candidate_snapshot_path" "$SNAPSHOT_FILE"` — a single `rename(2)`
     syscall (both paths are guaranteed to be on the same filesystem, both living under the same
     session-scoped `/tmp` area), which POSIX guarantees ATOMICALLY replaces the destination,
     unlinking its previous content as part of the SAME operation — there is no OS-visible
     intermediate state where the active path is empty, and no separate "delete the old file, which
     might itself fail" step exists at all anymore: a single successful `mv` both installs the new
     content and reclaims the old content's space in one indivisible step.

     **`SNAPSHOT_DIGEST`, the OTHER literal fact remembered alongside `SNAPSHOT_FILE`, must ALSO be
     advanced on a successful rename — the path alone is not the whole picture (new — closes a real
     bug found during design review: only `SNAPSHOT_FILE`'s own CONTENT was described as changing on
     promotion; the paired remembered fact `SNAPSHOT_DIGEST` — which every round 2+'s own mandatory
     pre-dispatch check, per `SKILL.md`/`references/snapshot-integrity.md`, compares the active
     file's real hash against — was never updated to match. The very next round's ordinary
     revalidation would then hash the newly-promoted file, get `snapshot_digest_after`, compare it
     against the STILL-remembered `snapshot_digest_before`, and incorrectly raise
     `🛑 SNAPSHOT INTEGRITY FAILURE` on a perfectly successful, intended promotion.)** Fixed: the
     instant the `mv` above completes successfully, Claude's own remembered `SNAPSHOT_DIGEST` literal
     is updated to `snapshot_digest_after` — both remembered facts (`SNAPSHOT_FILE`'s path staying
     constant, `SNAPSHOT_DIGEST` advancing to the new value) change together, in the same step, never
     one without the other. The post-append recovery algorithm's own "if it matches
     `snapshot_digest_after`... proceed normally" step above is understood to include this same
     update — recovery reconstructing that promotion already completed must ALSO set its own
     remembered `SNAPSHOT_DIGEST` to `snapshot_digest_after` before proceeding, not merely confirm
     the file's bytes look right.

     **A failed `mv` occurring LIVE, in the same round, after this round's own success line is
     ALREADY committed, cannot use the ordinary pre-append compaction-failure path — that path
     structurally assumes no success has been claimed yet (corrected — closes a real gap found
     during design review: "treated like any other compaction failure — see 'On failure' below" was
     wrong for exactly this timing. "On failure" deletes the candidate and dispatches the OLD
     thread's own fallback, appending ITS OWN result as round R's outcome — but round R's own JSONL
     line, by this point, has ALREADY been durably committed as a SUCCESS naming the NEW thread and
     the new digest lineage. Running the ordinary fallback here would either produce a second,
     contradictory outcome for the same round number — violating the one-object-per-round append-
     only contract — or silently leave the durable log claiming a promotion that never actually
     happened on disk.)** Fixed: once this round's own append is verified, completing the `mv` is
     MANDATORY, not optional — there is no fallback path available anymore, because the durable
     record has already committed to this outcome. If the initial `mv` fails, retry it up to 2 more
     times with a brief pause (matching this design's other bounded-retry conventions), RE-RUNNING
     the live active-file and candidate integrity checks (see step 4(b) below) before each retry
     attempt, not only the first — a failure here is expected to be transient (a momentary filesystem
     error), since the source and destination were both already confirmed to exist moments earlier by
     the append-verify's own value checks. If ALL retries are exhausted and the `mv` still fails, this
     is now a genuinely
     broken state the design cannot recover from live: treat it exactly like the post-append
     recovery algorithm's own unrecoverable case above — hard stop, `🛑 SNAPSHOT INTEGRITY FAILURE`
     — since the durable log's own claim can no longer be honored on disk, and continuing under
     either the old (already-superseded) or new (unpromoted) snapshot state would review against a
     state the log does not accurately describe. The OLD content is guaranteed untouched by a failed
     rename (rename either fully happens or doesn't, never partially), so this hard stop is at least
     never compounded by additional data loss.

     **Recoverable without giving up `mktemp`'s own symlink-attack protection (corrected — reverses
     a wrong turn taken during design review and closes the two problems it caused: (a) a prior
     revision made this path deterministic — the ACTIVE `SNAPSHOT_FILE`'s own path with a fixed
     `.candidate` suffix appended — specifically so the post-append/pre-promotion crash window
     (below) could be recovered without a new durable field; but this reintroduced exactly the
     symlink/predictable-path attack `mktemp`'s existing atomic, random allocation exists to prevent
     (`/tmp` resolves to the world-writable sticky `/private/tmp` on this platform — confirmed live
     via `stat -f '%Sp %N'` — so a local process could pre-plant a symlink at the predictable
     `.candidate` path and have the collection redirect follow it); (b) separately, deriving
     anything from "the ACTIVE `SNAPSHOT_FILE`'s own path" assumed that path itself is durably
     reconstructable, but it is not — `SNAPSHOT_FILE` is, and always has been, only a literal fact
     Claude remembers for the running session (see `SKILL.md`'s own "Remember both `SNAPSHOT_FILE`
     and `SNAPSHOT_DIGEST` as literal facts for the rest of the run... never re-collected" — the
     exact same category as `REPO_ROOT`/`SESSION_ID`), never JSONL-backed, so a recovery mechanism
     that depends on deriving a NEW path from it is no more durable than depending on the literal
     fact directly.)** Fixed by reverting to the ORIGINAL, safe allocation and closing the real gap
     a different way: the candidate file keeps using `mktemp` for a fresh, unpredictable, atomically-
     created path exactly like every other snapshot allocation in this design (no behavior change to
     allocation) — but the resulting random path is now ALSO durably recorded, as a new field,
     `candidate_snapshot_path`, on this SAME round's own JSONL line at the moment of the append in
     step 5 below (a genuinely pre-append-decided value, known the instant the candidate is
     collected — see "Logging" below). Continuity recovery for the post-append/pre-promotion window
     (see "PROVISIONAL_SNAPSHOT_FILE" below) reads this field directly instead of deriving anything.
     **This still depends on one pre-existing, inherited assumption, not a new one this design
     introduces:** identifying whether promotion ALREADY completed still requires hashing the
     CURRENTLY ACTIVE snapshot file, which — like literally every other round's own step-0
     revalidation in this entire skill, compaction or not — assumes `SNAPSHOT_FILE`'s own path is
     still known to the running Claude session. If that specific literal fact is ALSO lost, this is
     the identical total-memory-loss scenario the base skill already requires a fresh session for
     (see its own `schema_version` mismatch hard stop) — not a gap this design adds.
   - **Collection/hash failure itself (new — closes a real gap found during design review: the
     original draft only ever discussed a WRAPPER `ok:false` result, never a failure in the LOCAL
     re-collection/hashing step that happens before any dispatch is even attempted).** Mirrors
     Phase 0 step 5 / Phase 1's own post-sizing snapshot allocation, which already checks every
     collection command's own exit status and the resulting digest's shape before trusting it:
     if the candidate's own `git diff`/`shasum` collection fails, or the resulting digest fails the
     64-hex-character validation, this is treated exactly like any other compaction failure — delete
     whatever partial candidate file may exist (on a failed deletion here, add its path to
     `RETIRED_SNAPSHOT_FILES` — see "Retired-snapshot tracking is general-purpose" above), log the
     narration note, and go straight to step 6's normal `--resume` fallback. No dispatch is even
     attempted with an uncollectible candidate.
   - **Concrete provisional-resource tracking (new — closes a real gap found during design review:
     the original draft asserted "an existing candidate-snapshot cleanup sweep" without one actually
     existing — Phase 3's current terminal cleanup only ever removes the ONE active `SNAPSHOT_FILE`,
     with no concept of a candidate to also check).** A new session-scoped fact,
     `PROVISIONAL_SNAPSHOT_FILE` (analogous to `LEAKED_THREAD_IDS`), is set the moment a candidate
     is successfully collected and hashed, and cleared the moment that candidate is either promoted
     (success) or deleted (failure/collection error) — never left ambiguous in between. Phase 3's
     terminal cleanup (every terminal path, including `🛑 REVIEW LOG INTEGRITY FAILURE`) is extended
     to also remove `PROVISIONAL_SNAPSHOT_FILE` whenever one is currently set, exactly like it
     already removes the active `SNAPSHOT_FILE` — this is the concrete mechanism the earlier "already
     tracked as provisional" language in "Ordering on success" step 5.2 actually relies on.
   - **Snapshot lineage:** the one JSONL line that performs a compaction restart records both
     `snapshot_digest_before` and `snapshot_digest_after` (identical for `--commit` scope, by
     construction) — pure audit trail; the existing "one canonical subject, no external-drift
     detection" contract (`references/snapshot-integrity.md`) is deliberately, narrowly overridden
     only by this Claude-orchestrated, fully-disclosed re-snapshot event, never by anything
     auto-detected.

     **This override needs the SAME "shipping this feature requires a companion amendment" treatment
     already given to `references/execution-telemetry.md`, not merely a one-line "deliberately
     overridden" declaration (new — closes a real gap found during design review: this design
     directly conflicts with `references/snapshot-integrity.md`'s own explicit, EXISTING contract —
     that reference requires the snapshot allocated ONCE before round 1, session-scoped and NEVER
     changed per round, with a changed source requiring a WHOLLY NEW invocation rather than a
     running review pivoting mid-session. Compaction's entire restart mechanism does exactly the
     pivot that reference says should never happen. "The 'One shared reducer'... Schema version bump
     required" section above already treats an analogous conflict — round-1-only signals becoming
     legitimately repeatable — as requiring a real, explicit versioning response; this contract
     conflict is at least as central, yet was left with only a passing "narrowly overridden" note,
     never named as something shipping this feature actually requires resolving.)** Fixed: shipping
     this feature requires the SAME kind of companion amendment to `references/snapshot-integrity.md`
     as `references/execution-telemetry.md` already requires above — carving out an explicit, narrow
     exception: the "one canonical subject, never changed per round" invariant holds UNCHANGED for
     every ordinary session; it is relaxed ONLY when `--compact` triggers this specific,
     fully-specified, Claude-orchestrated, fully-disclosed re-snapshot-and-promote event (never by
     anything auto-detected, and never for any other reason) — the base skill's own ordinary,
     non-compaction behavior remains governed by that reference's existing, unmodified invariant. Same
     category of required change as the `schema_version` bump and the `execution-telemetry.md`
     amendment above, not a new one.
4. Dispatch a **fresh** `run-ccs-review.sh` call (same scope flag as round 1, not `--resume` — or,
   for a non-repo-artifact session per step 2 above, `--uncommitted` against `CLEAN_REPO_DIR` with
   the original artifact text included in focus) with focus text = `COMPACT_DIGEST` (+ the original
   artifact text, for a non-repo-artifact session) + the original Why **AND task-specific Scope**
   framing (new — closes a real gap found during design review: an earlier revision carried forward
   only "the original Why framing," dropping round 1's own task-specific Scope text entirely — the
   part of round-1's focus that narrows WHAT to verify, e.g. "only check the auth logic," which is
   NOT the same thing as the generic `⚠️ SCOPE CONSTRAINT` block below (that one is about excluding
   `node_modules`/vendor directories, never about the task's own narrowing). Since a fresh dispatch
   is a genuinely NEW thread with no memory of round 1's own framing, omitting this would silently
   turn a narrowly-scoped review into a whole-diff review after compaction.

   **A dedicated field is required — `target.focus` is NOT a stable source for this, corrected here
   (closes a real gap found during design review, confirmed against actual real durable logs from
   past sessions): `target.focus` records whatever focus text was sent for round 1's own FINAL
   logged dispatch ATTEMPT — not a stable "original task framing" fact.** Two real, confirmed ways
   this diverges from the true original framing:
   1. If round 1's own dispatch initially failed and needed a resume-safe retry
      (`references/retry-guards.md`), the retry's own focus text is just a short "Retrying after
      a `<reason>` failure..." note plus the generic scope constraint — NOT the original Why/Scope.
      Confirmed directly against a real `retry-resume-safe-round1` session log: its round-1
      `target.focus` contains neither a `Why:` nor a `Scope:` line at all. Reading `target.focus`
      back after exactly this (valid, supported) recovery path would restore a retry note, not the
      real task framing.
   2. For a non-repo-artifact session, `target.focus` ALREADY embeds the full original artifact text
      (per the existing non-repo-artifact rule). Confirmed directly against a real artifact-session
      log. Reading `target.focus` back AND separately re-embedding the artifact (per step 2 above)
      would duplicate the artifact in the fresh prompt — wasting bytes and risking an unnecessary
      byte-preflight failure for an artifact that would have fit with one copy.

   **Fixed: a new, dedicated, write-once field — `target.original_scope_framing` — captured exactly
   ONCE, at the moment round 1's OWN focus text is first constructed (Phase 1 Step 0, BEFORE the
   very first dispatch attempt of any kind, retry or not), holding ONLY the Why + task-specific Scope
   text.** For a non-repo-artifact session, this field explicitly EXCLUDES the pasted artifact text
   (which stays available separately, via the unchanged snapshot, per step 2 above) — never
   double-embedded. This field is written once to round 1's own JSONL line and is NEVER overwritten
   by a later retry — a retry only ever changes what is actually dispatched for that attempt
   (`target.focus`, serving its existing, unchanged diagnostic/continuity purpose), never this
   separately-recorded original-framing fact. Compaction's fresh dispatch sources its Why+Scope
   component from `target.original_scope_framing`, never from `target.focus`.) + the standard
   `⚠️ SCOPE CONSTRAINT` block **+ the SAME fixed collaboration-frame sentence every round-1 focus
   already includes (new — closes a real gap found during design review: `SKILL.md`'s own round-1
   rule requires stating, in that same focus text, that Claude and Codex are equal peers, findings
   must be evidence-based, and the goal is 100% clean mutual agreement — confirmed directly against
   a real round-1 JSONL log that this frame is genuinely present there. This is fixed, static
   boilerplate, not task-specific content — unlike Why/Scope, it does not need to be captured into
   `target.original_scope_framing` at all; it is simply appended to the compaction restart's own
   focus text directly, exactly like the `⚠️ SCOPE CONSTRAINT` block immediately before it, since
   both are the same kind of fixed framing every fresh dispatch already carries.)** + the SAME
   `DISPOSITION` request block
   an ordinary round 2+ would
   include (new — closes a real convergence gap found during design review: without this, a claim
   that this fresh reviewer would happily confirm fixed has no mechanism to actually close, since
   the marker parser only recognizes a `DISPOSITION` for a claim_id the SAME round's focus text
   explicitly requested — omitting the request here would strand every qualifying open claim,
   eventually producing a false `⚠️ NOT CONVERGED` at the round cap purely because compaction never
   asked).** This block is constructed by the EXISTING rule (`references/claim-ledger.md` section 4
   and `SKILL.md`'s own round-2+ History construction), evaluated against the pre-compaction
   thread's own most recently completed round exactly as it would be for an ordinary resumed round
   — compaction changes WHICH thread receives the request, never whether or how the request itself
   is built. **This dispatch IS round R's real dispatch** — its own findings are processed through
   Phase 2 steps 2-6 exactly like any other round's; no separate follow-up dispatch happens in the
   success case. **Coverage epoch (new — closes a real false-CLEAN gap found during design
   review):** for a `--uncommitted` compaction dispatch specifically, this call can report its own
   `coverage.source` exactly like any fresh `--uncommitted` dispatch can — this is a SECOND fresh
   `--uncommitted` epoch within the same session, not only round 1's. The existing "coverage is a
   round-1-only property" rule is revised to "coverage is a property of every fresh `--uncommitted`
   dispatch this session, round 1 or a compaction restart" — the CLEAN convergence gate merges
   EVERY such dispatch's own coverage outcome (worst-of-all: `"complete"` only if every one of them
   was `"complete"`, else the existing `"partial"`/`"unknown"` precedence, `omitted` lists unioned
   and deduplicated by `(path, reason)`), never round 1's alone once a compaction has occurred.
   `--base`/`--commit` compaction dispatches report no coverage, exactly like round 1 in those
   scopes — nothing changes for them.

   **A successful restart can ALSO lack real coverage — fail-open gap closed (new — closes a real
   gap found during design review, confirmed against the actual collector's own source): the
   untracked-file collector deliberately treats a failure to write its own `--coverage-out` sidecar
   as non-fatal (catches the error, still exits successfully), and the wrapper deliberately degrades
   a missing/malformed sidecar to reporting no coverage metadata at all — so an `ok:true` fresh
   `--uncommitted` compaction dispatch can genuinely lack `coverage.source` too, not only a failed
   one.** The "always record coverage — real value when present, the `"unknown"` sentinel when
   absent" rule (see "On failure" below for the failure-side statement of this same rule) therefore
   applies symmetrically to a SUCCESSFUL fresh `--uncommitted` compaction restart as well: if this
   dispatch's own response is `ok:true` but carries no `coverage.source`, the round's `coverage_source`
   field is still recorded, as the `"unknown"` sentinel — never silently omitted just because the
   dispatch itself otherwise succeeded. `--base`/`--commit` compaction dispatches report no coverage,
   exactly like round 1 in those scopes — nothing changes for them.

   **A retry-then-succeed candidate must reuse its OWN pre-retry coverage, never treat itself as
   coverage-less (new — closes a real gap found during design review: a fresh `--uncommitted`
   dispatch that first returns `ok:false` with `coverage.source` already present — per the interface
   reference, several of the reasons eligible for this, e.g. `timeout`, occur only after collection
   has already completed — and is then retried per `references/retry-guards.md`'s own existing
   bounded-retry rule via `--resume` on that SAME new candidate thread (not the step-6 fallback to
   the OLD thread) until it succeeds, ends up with a final `ok:true` response that itself carries NO
   `coverage.source` at all, because a `--resume` call never re-collects anything — the wrapper only
   ever populates `SOURCE_COVERAGE_JSON` inside its `--uncommitted` FRESH-dispatch branch. Reading
   coverage only from this final response would wrongly record `"unknown"` for a candidate whose real
   collected content is already known.).** Fixed: this is exactly the same situation
   `references/retry-guards.md` already solves for actual round 1's own retry-then-succeed case —
   generalized here from "round 1" to "whichever round performs a fresh `--uncommitted` dispatch"
   (a compaction restart's dispatch is, by construction, also a fresh dispatch, per "Dispatch a
   fresh `run-ccs-review.sh` call" above) — carry forward the EARLIER failed attempt's own
   `coverage.source` as this round's real coverage once the retry succeeds, rather than treating the
   final successful (but coverage-silent) `--resume` response as evidence of "unknown." If the
   earlier failed attempt itself carried no `coverage.source` either, the existing `"unknown"`
   sentinel rule above still applies unchanged.

   **The SAME retry-then-succeed situation applies to `COMPACTION_BASELINE_TOKENS` too, not only
   coverage (new — closes a real gap found during design review: the baseline guard above records
   `execution.usage.input_tokens` from "the compaction round's OWN, freshly-restarted" dispatch —
   but when that fresh dispatch first fails and is retried via `--resume` on the SAME candidate
   thread per `references/retry-guards.md` until it succeeds, the final response's own
   `execution.usage` describes only the RESUMED turn's marginal usage, not the original fresh
   dispatch's true size — using it as the baseline would read as artificially small, wrongly passing
   a review that was actually large enough to warrant disabling compaction, or conversely (if that
   marginal usage happens to be unusable/malformed) forcing an unnecessary permanent disable when a
   perfectly good number was already available from the FIRST attempt.)** Fixed, reusing the exact
   same principle as the coverage fix immediately above: `COMPACTION_BASELINE_TOKENS` is read from
   the EARLIER failed fresh attempt's own `execution.usage.input_tokens` when one exists (the fresh
   dispatch's real, original size, before any retry), never from a subsequent `--resume` retry's own
   response. Only when the fresh attempt's own first response carried no usable telemetry at all
   does the existing "fail closed when telemetry is unusable" rule above apply.

   **Reconciling with `references/retry-guards.md`'s OWN full escalation topology, not just its
   2-resume bound (corrected — closes a real gap found during design review: "This dispatch IS
   round R's real dispatch... no separate follow-up dispatch happens in the success case" above,
   and "Failure isolation from the round loop" below, both asserted a compaction attempt is exactly
   ONE dispatch (plus, elsewhere, its 2 bounded resume-retries) — but `references/retry-guards.md`'s
   own tested, EXISTING behavior for a "no pre-existing thread" failure — which is exactly what a
   compaction attempt's brand-new candidate thread structurally is, having never appeared in
   `GROUP_THREADS` before this attempt — is fresh A → resume A → resume A → if BOTH resumes are
   STILL exhausted, one further FULL fresh retry with a brand NEW thread B, abandoning A to
   `LEAKED_THREAD_IDS`, before ever giving up. An actual eval fixture
   (`evals/scenarios/retry-exhausted-round1-fresh-fallback`) exercises exactly this sequence.
   Compaction's design never modeled thread B at all — its own candidate/coverage/baseline
   ownership, or how reaching this point interacts with step 6's own fallback.)** Fixed, by
   deliberately reusing this EXACT existing topology rather than inventing a compaction-specific
   variant (consistent with this design's own "reuse existing mechanisms" principle elsewhere): if
   thread A's own 2 bounded resume-retries are both exhausted, dispatch ONE further fresh attempt
   under thread B, exactly as `references/retry-guards.md` already prescribes for this shape of
   failure — with the following compaction-specific bookkeeping, since compaction has state
   `retry-guards.md` itself has no concept of:
   - Before dispatching B: thread A is added to `LEAKED_THREAD_IDS` (per the existing rule); if A's
     own dispatch had allocated a candidate snapshot file, that candidate is deleted immediately —
     it belongs to A's now-abandoned attempt — following the SAME "abandoned fully-hashed candidate"
     rule as any other ordinary compaction failure (fold a failed deletion into
     `retired_snapshot_files`, per the existing rule).
   - **Thread B's OWN dispatch reconstructs the COMPLETE compaction focus text, identically to step 4
     above — never a partial or abbreviated one (new — closes a real gap found during design review:
     this bullet, and the no-threadId fresh retry bullet below, only ever specified snapshot
     RE-COLLECTION, never focus-text CONSTRUCTION — but B's dispatch is a genuinely fresh `codex exec`
     call, not a `--resume`, so it has NO prior turn to inherit anything from; the wrapper copies each
     invocation's own stdin into a fresh `FOCUS_RECEIVED_FILE` and launches a plain `codex exec` for
     every non-resume call, meaning whatever focus text this dispatch sends IS the entirety of what
     the new thread ever sees. A literal implementation following only "re-collect the snapshot" could
     dispatch B with nothing more than that snapshot, omitting `COMPACT_DIGEST`, the original Why and
     task-specific Scope, the verified non-repo-artifact text when applicable, the collaboration frame,
     and the pre-compaction `DISPOSITION` request block step 4 already requires — silently stranding
     open claims and losing the task's own original framing.)** Fixed: B's dispatch reconstructs the
     EXACT SAME complete focus text step 4 specifies for the original candidate — `COMPACT_DIGEST` (+
     the verified original artifact text, for a non-repo-artifact session) + the original Why AND
     task-specific Scope (from `target.original_scope_framing`) + the SCOPE CONSTRAINT/collaboration
     frame + the SAME `DISPOSITION` request block — never anything less, regardless of which candidate
     (A originally, or B now) is doing the re-collecting. Thread B's OWN dispatch is a genuinely fresh
     one: for `--uncommitted`/`--base` scope
     specifically (the only scopes with a candidate lifecycle at all), a fresh candidate snapshot is
     re-collected (a new `candidate_snapshot_path`, new digest) exactly as thread A's original
     dispatch was — never a reuse of A's now-deleted candidate. **For non-repo-artifact/`--commit`
     scope (new — closes a real gap found during design review: an earlier revision stated candidate
     re-collection unconditionally here, contradicting those two scopes' own existing "no candidate
     is ever allocated" definitions above): B's dispatch involves no candidate file at all, exactly
     like A's did not — B's eventual success correctly omits `candidate_snapshot_path`, matching the
     existing non-repo-artifact/`--commit` success branch.** Coverage and `COMPACTION_BASELINE_TOKENS`
     carry-forward (both fixes just above) apply to WHICHEVER thread (A or B) ultimately produces the
     round's real outcome — A's own attempt is entirely superseded, not merged, once B is dispatched
     (B itself is never retried — see its own single-shot treatment below — so there is no
     retry-then-succeed sub-case for B specifically, only for A). **This carry-forward principle
     applies to A's OWN `--resume` retry-then-succeed — BOTH bullet 3's no-ID-hiccup retry AND bullet
     4's ordinary threadId-bearing bounded resume retry, the two genuinely different ways A can
     succeed via `--resume` — NEVER to A's bullet-2 no-threadId FRESH retry, which needs the OPPOSITE
     treatment (new — closes a real gap found during design review: bullet 4 (the ordinary case) was
     introduced in a LATER revision than this carry-forward rule, which had only ever named bullet 3
     — but bullet 4 is, if anything, the MORE common of the two `--resume` retry-then-succeed paths,
     and needs the identical carry-forward treatment for the identical reason: neither bullet 3's nor
     bullet 4's own successful `--resume` response ever re-collects anything, so in BOTH cases the
     ONLY real coverage/baseline data available is the earlier failed fresh dispatch's own. Bullet 2's
     own retry is the polar opposite — it is itself a genuinely NEW, independent re-collection, exactly
     like the A→B transition already is, with its OWN fresh coverage and baseline. Applying
     carry-forward there would use STALE data from an attempt whose own collected content this retry
     has already deleted and superseded, exactly the same class of error the A→B transition already
     avoids by using B's own data, never A's.)** For bullet 2's own retry-then-succeed specifically,
     the RETRY's own response is the sole authoritative source for coverage and
     `COMPACTION_BASELINE_TOKENS` — never the earlier, now-superseded failed attempt's — mechanically
     identical in principle to how B's own data is used, never A's, after the A→B transition.
   - `compaction_attempt_failed_thread` (see "Durable backstop for abandoned threads" below) becomes
     an ARRAY of 1 or 2 thread ids — just `[A]` when B was never reached, `[A, B]` when both were
     abandoned — rather than a single value; every consumer of this field (Phase 3 cleanup, the
     final-report thread enumeration, the append-verify field checks) is extended to accept and
     union in either shape.
   - **A candidate's OWN no-threadId-at-all failure needs its own predicate, separate from
     `GROUP_THREADS` (new — closes a real gap found during design review: `references/retry-guards.md`'s
     own selection between "no entry yet → one fresh retry" and "entry already exists → resume
     retry" is keyed on whether `GROUP_THREADS` has an entry for the group — but for compaction,
     `GROUP_THREADS` ALWAYS already has an entry throughout the whole attempt, since it still names
     the OLD thread until promotion (per "Failure isolation from the round loop" below) — so a
     literal, unmodified application of that predicate would always select "resume retry" for
     candidate A too, even on A's OWN first dispatch, when `no_thread_started` (or `bad_args`/
     `git_error`/`incomplete_collection`) means no candidate thread was EVER captured to resume in
     the first place — there is nothing to `--resume`.)** **Corrected once more (closes a real gap
     found during design review): the fix above still keyed its own predicate on "a reason that
     never carries a threadId" — a fixed CATEGORY — but `references/retry-guards.md`'s own actual
     rule keys on whether THIS SPECIFIC RESPONSE captured a threadId, per-occurrence, not by reason
     category (it explicitly notes `interrupted`/`timeout` can occasionally lack a threadId too, "on
     the rare occasion," despite usually carrying one). Worse, `artifact_too_large` ALSO structurally
     never carries a threadId on a fresh dispatch (confirmed directly against the wrapper), so a
     category-based "no threadId → retry" rule would have WRONGLY retried a fresh
     `artifact_too_large` failure — directly contradicting `references/retry-guards.md`'s own
     higher-priority, unconditional "never retried, ever, for that group, fresh or resumed" rule for
     exactly that reason.** **Scoped to candidate A specifically, never B (corrected once more —
     closes a real gap found during design review: an earlier revision applied these bullets "to the
     CURRENT candidate attempt (A, or later B)," implying B gets the SAME retry machinery A does —
     but `references/retry-guards.md`'s own actual topology gives B exactly ONE fresh attempt with NO
     retry logic of its own at all; its own "round 2+" language ("having just used its one
     fresh-retry chance, further failure has no further fresh fallback of its own") already says
     this, and the `could-not-verify-exhausted` eval fixture confirms processing stops the moment
     that ONE fresh fallback fails, never spawning a further no-ID retry, bounded resume, or a THIRD
     candidate "C." Recursively applying the SAME three-bullet machinery to B would have allowed
     exactly that unsupported escalation.)** Fixed: apply `references/retry-guards.md`'s own THREE
     bullets, in the SAME priority order it already uses, to candidate A ONLY — tracked as its own
     fact, independent of `GROUP_THREADS` (which keeps meaning "the old thread" throughout, per its
     own existing definition). Thread B's own, deliberately simpler treatment is described separately
     below, after these three bullets.
     1. **`artifact_too_large` first, regardless of threadId presence:** never retried. This
        candidate attempt is immediately exhausted — fall straight through to step 6's fallback (this
        design's own failure-isolation principle already means this is never surfaced as its own
        distinct outcome, unlike the base skill's `🛑 INPUT TOO LARGE` for an ordinary round).
     2. **Else, if THIS SPECIFIC response captured no threadId AND the current candidate has NEVER
        previously captured one either, across any earlier response in this same attempt sequence
        (corrected — closes a real gap found during design review: checking only "did THIS response
        lack a threadId" wrongly treats a `--resume` call's own no-threadId failure — e.g.
        `bad_args` from a stdin mistake — as proof the candidate thread never existed. But
        `references/retry-guards.md`'s own explicit rule for exactly this case is "that existing
        thread is untouched, not abandoned... retry the exact same `--resume` call again... never
        anything added to `LEAKED_THREAD_IDS`" — the candidate's own thread history must be checked,
        never inferred from this one response alone).** apply `references/retry-guards.md`'s "no
        entry yet" bullet to THIS candidate specifically: one fresh retry. **This retry ALSO
        re-collects a genuinely FRESH candidate — reversing a wrong turn from an earlier revision,
        which instead reused the already-collected `candidate_snapshot_path`/digest to avoid
        redundant local work (closes a real correctness gap found during design review: that reuse
        assumed Claude's OWN earlier local collection is what the retry dispatch reviews — but the
        wrapper accepts no snapshot input at all; EVERY fresh dispatch, retry included, independently
        re-collects `DIFF_TEXT` live from the repository at ITS OWN moment (`run-ccs-review.sh`'s own
        `--uncommitted`/`--base` collection branches). A real, meaningful amount of wall-clock time
        elapses between the original failed attempt and this retry — enough for the worktree or
        `HEAD` to have moved — so promoting the OLD, earlier-collected candidate would durably record
        a digest for content that is NOT what this retry's own dispatch actually reviewed. The
        efficiency motivation for reuse was real, but traded away correctness for a modest local-cost
        saving — the wrong tradeoff.)** Fixed, for `--uncommitted`/`--base` scope specifically (the
        only scopes with a candidate lifecycle at all — for non-repo-artifact/`--commit` scope, this
        retry involves no candidate file, exactly like the original failed attempt did not): this
        retry re-collects and re-hashes a brand new candidate (new `candidate_snapshot_path`, new
        digest) exactly like the original attempt did, the OLD (now-superseded) candidate is deleted
        immediately (folding a failed deletion into `retired_snapshot_files`, per the existing rule)
        — mechanically identical to how the A→B escalation already handles this, just without a
        distinct "B" thread identity, since no thread was ever captured for either attempt. **This
        retry ALSO reconstructs the COMPLETE compaction focus text identically to step 4 above, for
        the identical reason thread B's own dispatch must (see "Thread B's OWN dispatch reconstructs
        the COMPLETE compaction focus text" above) — this is likewise a genuinely fresh `codex exec`
        call with no prior turn of its own to inherit anything from, so whatever focus text it sends
        is the entirety of what this new dispatch ever sees.** If this
        retry fails AGAIN, for ANY reason — not only "the same no-ID way" (corrected — closes a real
        gap found during design review, the identical class of bug already fixed once for bullet 3's
        own one-retry rule: an earlier revision here exhausted only on a repeat of the SAME no-ID
        failure, implicitly leaving a door open for a threadId-bearing second failure to feed into the
        ordinary bounded-resume/fresh-B escalation instead — but `references/retry-guards.md`'s own
        literal rule for "no entry yet, one fresh retry" describes exactly two outcomes: it succeeds,
        or it fails and processing stops, with no reason-based exception carved out for a SECOND
        failure that happens to look different from the first)** — (excluding `artifact_too_large`,
        handled by bullet 1 above regardless, which as always takes priority over any other
        classification): this candidate is exhausted. **Check whether THIS retry's own response
        captured a threadId before assuming nothing needs tracking (corrected — closes a real gap
        found during design review: an earlier revision asserted "nothing to add to
        `LEAKED_THREAD_IDS`... nothing was ever captured" unconditionally — but this retry is itself
        a genuinely fresh dispatch, and a fresh dispatch can fail with a reason that DOES carry a
        threadId even when the ORIGINAL attempt's own failure did not — e.g. the original fails
        `no_thread_started` [no ID], this retry then fails `timeout` or `nonzero_exit` [captures a
        real, live `THREAD_ID` before failing]. Assuming "nothing was ever captured" for the whole
        attempt sequence based only on the FIRST failure would leave a real, newly-created thread
        completely untracked.)** Fixed: if this retry's own response DID capture a threadId, add it
        to `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` exactly like any other abandoned
        thread; only when this retry's response ALSO captured no threadId is there genuinely nothing
        to add. Delete this retry's own candidate too, when one exists (same rule) — and fall
        straight through to step 6's fallback. The fresh-B escalation is never reached from this
        bullet, regardless of what the retry's own second failure looks like.
     3. **Else (a threadId WAS captured for the current candidate, either by this response or an
        earlier one in the same sequence): if THIS specific response itself lacks a threadId despite
        the candidate already having one** (a `--resume`-style no-ID failure per the corrected bullet
        2 above) **— retry the SAME already-captured thread EXACTLY ONCE, never more, and never
        re-entering the ordinary bounded-resume/fresh-B escalation on ANY outcome of this one retry
        besides success (corrected once more — closes a real gap found during design review: an
        earlier revision of this same fix let a threadId-bearing failure on this ONE retry feed back
        into the ordinary 2-retry/fresh-B topology "counting as consuming none of its own allowance"
        — but `references/retry-guards.md`'s own literal rule for this EXACT case describes only two
        outcomes for this one retry: it succeeds, or "the retry ALSO fails, stop — report
        `⚠️ COULD NOT VERIFY`" — with no carve-out for re-entering a different escalation path based
        on what the SECOND failure's own reason happens to be. Treating a threadId-bearing second
        failure as an exemption from that stop instruction was an unwarranted generalization beyond
        what the reference rule actually states.)** If that one retry fails AGAIN, for ANY reason
        (whether or not it happens to carry a threadId this time): exhausted. **Always record the
        ALREADY-KNOWN thread id on exhaustion here — this bullet's own precondition guarantees one
        exists, unlike bullet 2's own genuinely-uncertain case (corrected — closes a real gap found
        during design review: an earlier revision's exhaustion language never explicitly said to add
        anything to `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` here, leaving room to
        wrongly assume — by analogy with bullet 2's OWN "check whether THIS retry captured an id"
        language — that "no id" is possible here too. It is not: bullet 3 only ever runs BECAUSE "a
        threadId WAS captured for the current candidate" is already true, established before this
        retry is even attempted — so the id to record is simply the one already known from earlier in
        this sequence, never contingent on whether the FINAL failing response itself happens to
        repeat it.)** Fixed: on exhaustion here, add the candidate's own already-known thread id to
        `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` unconditionally, then fall straight
        through to step 6's fallback (never `⚠️ COULD NOT VERIFY`, per this design's own
        failure-isolation principle substituting for the reference's own generic stop instruction),
        the SAME as bullet 2's own exhaustion. Only if this one retry SUCCEEDS does the candidate
        continue as this round's own live, active attempt, exactly as if no no-ID hiccup had ever
        occurred.
     4. **Else (THIS response DOES carry a threadId — the ordinary, most common case, whether this is
        the candidate's own first-ever captured id or a later response that continues to carry one)
        — a genuinely missing branch, not merely an implied one (new — closes a real gap found during
        design review: bullets 1-3 above only ever enumerate `artifact_too_large`, "no threadId at
        all yet," and "no threadId on THIS response despite one already being known" — none of those
        three literally covers the single MOST ORDINARY failure this whole design's own "2 bounded
        resume-retries then fresh-B" language elsewhere assumes exists: a ordinary resume-safe
        failure — `timeout`, `nonzero_exit`, etc. — that DOES carry a threadId. A prior revision left
        this case to be inferred only from a closing summary sentence after the enumerated bullets,
        never as its own executable branch within the list itself.)**: this is the ordinary case —
        apply the standard bounded-resume-retry-then-fresh-B escalation directly, exactly as already
        specified in "Reconciling with `references/retry-guards.md`'s OWN full escalation topology"
        above (2 bounded `--resume` retries against this SAME thread; if both are exhausted, the
        fresh-B escalation).
     The fresh-B escalation is reached ONLY via bullet 4's own ordinary path — a genuinely NEW
     resume-safe failure that carries a
     threadId on its OWN first occurrence for this candidate (never via a no-ID recovery scenario per
     bullet 3 above) — never via bullet 1 or bullet 2's own exhaustion either, all of which fall
     straight to step 6's fallback without ever creating a second candidate thread.
   - **Thread B's own single dispatch gets NONE of bullets 1-4's retry machinery — it either
     succeeds, or the whole compaction attempt is immediately exhausted, matching
     `references/retry-guards.md`'s own "round 2+"/one-fresh-fallback rule exactly.** If B's own
     dispatch fails, for ANY reason whatsoever (`artifact_too_large`, no threadId at all, a
     threadId-bearing resume-safe reason — none of these are distinguished here, unlike A's own
     treatment above): this is immediate exhaustion, with no retry of B, no no-threadId recovery
     attempt for B, and absolutely no further escalation to a third candidate/thread. If B's own
     failed response captured a threadId, add it to `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread`
     (alongside A's own, per the array shape above); if not, there is genuinely nothing further to
     add for B. Delete B's own candidate, when one exists (same rule as any other abandoned
     candidate). Fall straight through to step 6's fallback.
   - "This dispatch IS round R's real dispatch" above, and "round R has exactly ONE real dispatch"
     in "Failure isolation from the round loop" below, both mean exactly ONE real OUTCOME/RESULT for
     round R — success via A or B, or the old-thread fallback — never a literal single network call;
     the underlying attempt sequence (fresh A, its bounded resumes, and possibly fresh B) is an
     internal implementation detail of reaching that one outcome, identical in spirit to how round
     1's own bounded retries already work without round 1 itself being called "multiple rounds."

   **One shared reducer, not three ad hoc implementations (new — closes a real durable-contract gap
   found during design review).** The original draft only described a live, in-session merge rule
   and never addressed two other places coverage is read: continuity recovery (reconstructing state
   from the JSONL log, e.g. after an interruption), the final-verdict artifact's own `coverage`
   field (Phase 3 step 4), AND the user-facing **Final Report's own "Source coverage" narration**
   (new — closes a real reporting gap found during design review: that section's EXISTING rule
   reports coverage only when ROUND 1's own `coverage_source` is partial/unknown — confirmed
   directly against the base skill's own text. A session where round 1 is `"complete"` but a LATER
   successful compaction restart's own coverage is partial/unknown would correctly still end at
   `⚠️ PARTIAL COVERAGE` — the underlying gate already accounts for every epoch — but the report
   text a user actually reads would look only at round 1's now-irrelevant `"complete"` value and
   fail to explain why the run actually ended that way) — all FOUR of which currently read (or, for
   the Final Report, would read) ONLY round 1's stored value. Fixed: a successful `--uncommitted`
   compaction restart's own `coverage_source` (real or the `"unknown"` sentinel per above) is
   PERSISTED on that round's JSONL line (not merged only transiently in memory), and exactly ONE
   reducer definition is used for all FOUR consumers (the live per-round convergence check, a
   from-scratch continuity-recovery read, the final artifact's own `coverage` construction, AND the
   Final Report's own Source coverage section — which must name WHICH epoch(s), round 1 and/or
   which specific compaction round, actually contributed any partial/unknown status, never assume
   it was necessarily round 1) — no separate re-implementation for any of the four:
   - `status`: `"complete"` only if every epoch's own status was `"complete"`, else the existing
     `"partial"`/`"unknown"` precedence, exactly as before.
   - `omitted`: the union of every epoch's own `omitted` list, deduplicated by `(path, reason)`,
     exactly as before.
   - **`reviewed_file_count` (new — closes a real schema-completeness gap found during design
     review): the LATEST epoch's own count, never a sum.** The durable result schema
     (`schemas/interactive-result.schema.json`) requires this field alongside `status`/`omitted`,
     and the existing coverage-merge fixture only ever produced the first two — confirmed directly
     that feeding it two epochs (counts 2 and 3) omits `reviewed_file_count` from its output
     entirely. Summing would double-count files re-scanned by a later epoch that already covered
     ground round 1 did; using the latest epoch's own count is both simpler and more accurate,
     since a later `--uncommitted` epoch's scan supersedes an earlier one's as the more current
     picture of the codebase. **When the latest epoch is itself the `"unknown"` sentinel below
     (closes a real gap found during design review: that sentinel carries no count at all, yet the
     schema requires an integer here) — use the most recent PRECEDING epoch's own real count
     instead** (the most defensible available number, pending the currently-unknown state — the
     accompanying `status: "unknown"` is what actually gates CLEAN, not this count, so it is
     informational once status is already unknown). In the edge case where no epoch has ever
     reported a real count at all, use `0`, explicitly non-authoritative given the unknown status.
   - **A failed fresh `--uncommitted` compaction attempt's own coverage is durably LOGGED, but
     deliberately EXCLUDED from this shared reducer (revised — an earlier revision here folded it
     into the reducer like a successful epoch; "On failure" above explains, with a live-traced
     example, why that was itself a false-CLEAN bug: the candidate diff a failed attempt collected
     is abandoned when the round falls back to `--resume` on the OLD thread, which never sees that
     candidate's content at all — so that candidate's own "complete" collection status describes
     content nobody ever actually reviewed, and folding it in would misrepresent the session's real
     reviewed completeness).** When a failed compaction attempt's own response carries
     `coverage.source` (or lacks one entirely), it is still recorded — as `compaction_attempt_coverage`
     (alongside `compaction_attempt_failed_thread`/`compaction_attempt_execution` on the SAME round R
     own line — but, unlike those two, ONLY for a failed sub-attempt that was itself a fresh
     `--uncommitted` dispatch, never a failed `--resume`/`--base`/`--commit` call, which never carries
     coverage at all (repeatedly corrected in this document — see "Scoped to a failed FRESH
     `--uncommitted` dispatch specifically" below for the full reasoning; `compaction_attempt_failed_thread`/
     `compaction_attempt_execution` keep the broader "any real dispatch attempted" scope, coverage does
     not)) — purely as a durable, best-effort AUDIT trail of what that abandoned attempt's own
     collection situation was.
     **This field is an ARRAY, one entry per failed fresh `--uncommitted` sub-attempt, in attempt
     order (new — closes a real gap found during design review: unlike
     `compaction_attempt_failed_thread`/`compaction_attempt_execution`, both explicitly made arrays
     to cover the fresh-A/fresh-B topology, this field was left singular despite BOTH A and B being
     independent fresh `--uncommitted` dispatches each capable of carrying its OWN distinct
     coverage — a real audit record would otherwise be silently lost whenever both failed, rather
     than merged, per "Coverage and `COMPACTION_BASELINE_TOKENS` carry-forward... apply to WHICHEVER
     thread... A's own attempt is entirely superseded, not merged" above, which already establishes
     that A's and B's data are DISTINCT records, never merged into one).** This reducer folds in ONLY
     a successful compaction restart's `coverage_source`, never a failed attempt's
     `compaction_attempt_coverage` — see "On failure" above for the full reasoning.

   **Schema version bump required (new — closes a real contract-versioning gap found during design
   review).** This changes how EXISTING lines must be interpreted — before this feature, `scope`
   other than `"resume"` and a present `coverage_source` were both round-1-only signals; after it,
   either can legitimately appear again at any round that performed a compaction restart. Per the
   EXISTING legacy-session policy (`references/claim-ledger.md` section 10), this is exactly the
   kind of change that requires bumping the session's own `schema_version` (introduced at whatever
   the next available integer is when this ships) — reusing the mechanism already in place, not a
   new one: a session started before this feature shipped is refused for `--resume` under the new
   skill version, exactly as an old-claim-ledger session already is today, rather than attempting a
   mixed-interpretation reduce.

   **`references/execution-telemetry.md` itself needs a scoped amendment before this feature can ship
   — a genuine contract conflict, not merely a documentation gap (new — closes a real cross-reference
   contradiction found during design review: that EXISTING reference states, as a general invariant,
   that execution/usage telemetry is "purely additive reporting... never load-bearing for
   convergence, retry, or integrity decisions." This design directly violates that invariant by
   design — `execution.usage.input_tokens` is explicitly used as a CONTROL INPUT: it triggers the
   compaction threshold check, establishes `COMPACTION_BASELINE_TOKENS` for the benefit-free-restart
   circuit breaker, and governs the disable-latch decision. Shipping this feature with that reference
   left unchanged would leave a standing, false claim about the whole skill's own telemetry
   contract.)** Fixed: shipping this feature requires a companion amendment to
   `references/execution-telemetry.md` carving out an explicit, narrowly-scoped exception — telemetry
   becomes load-bearing ONLY when `--compact` is enabled for the session, and ONLY for the specific
   compaction-owned decisions this design already names (the threshold check, the baseline circuit
   breaker, the disable latch) — the base skill's own ordinary convergence/retry/integrity decisions,
   with `--compact` OFF or absent, remain governed by that reference's existing, unmodified invariant.
   This is the same "shipping this feature requires touching an existing shared contract" pattern as
   the `schema_version` bump immediately above, not a new category of change.
5. **Ordering on success — durability before any thread or snapshot file is touched, with immediate
   provisional tracking to close the intermediate-window leak an earlier draft left open (closes a
   real gap found during design review: between "dispatch returns ok:true" and "JSONL append
   verified," the new thread and candidate snapshot were tracked NOWHERE — not yet `GROUP_THREADS`/
   `LEAKED_THREAD_IDS`, not yet the active snapshot — so a `🛑 REVIEW LOG INTEGRITY FAILURE` in that
   window would leak both, since that failure's own cleanup only ever sweeps `GROUP_THREADS`/
   `LEAKED_THREAD_IDS` and the currently-active snapshot):**
   1. This dispatch returns `ok:true` (never inferred from "a threadId exists" — several `ok:false`
      failure reasons also carry a `threadId`, see the interface reference's own reason table).
   2. **Immediately** (before doing anything else with this result): add the new thread id to
      `LEAKED_THREAD_IDS` provisionally (the candidate snapshot, when one exists, is ALREADY tracked
      as `PROVISIONAL_SNAPSHOT_FILE` from the moment it was collected in step 3 above — nothing new
      to do for it here). Both are now covered by every existing terminal cleanup sweep (including a
      `🛑 REVIEW LOG INTEGRITY FAILURE` that might fire in step 3 below), even though neither has
      been "promoted" yet.
   3. Process this round's findings normally (Phase 2 steps 2-6, including the coverage merge
      above), then append this round's JSONL line — `target.scope` = the scope flag actually used
      (never `"resume"`), plus `compacted_from_thread: <old thread id>` and the snapshot-lineage
      fields from step 3 above — and run the EXISTING append-verify hard stop exactly as any other
      round does. **The append-verify check itself must be extended for a compaction round,
      never left as the bare `.round == R` check alone (new — closes a real gap found during design
      review: the base skill's own verifier only confirms the appended line carries the expected
      round NUMBER — it says nothing about which FIELDS that line carries. A partial or buggy write
      that lands the correct round number but drops, say, `candidate_snapshot_path` or
      `compaction_attempt_failure_count` would pass that check unnoticed, silently breaking exactly
      the durability guarantees this whole design depends on those fields for.)** **This extension
      must be BRANCH-AWARE, not one fixed field list (corrected — closes a real gap found during
      design review: a first revision required `candidate_snapshot_path` on EVERY successful
      compaction and `compaction_attempt_failed_thread` on EVERY attempted-and-failed one — but a
      non-repo-artifact session and `--commit` scope never allocate a candidate at all (see the
      snapshot-candidate-lifecycle bullet above: "No candidate snapshot is ever allocated for
      `--commit` scope"), and several `ok:false` reasons — `no_thread_started`, `bad_args`,
      `git_error`, `incomplete_collection` — structurally never carry a `threadId` at all, per the
      interface reference's own per-reason table. Both are legitimate, expected outcomes that the
      original fixed field list would have wrongly failed.)** Fixed: for any round whose own line
      records a compaction outcome, the verify step confirms exactly the fields THAT SPECIFIC
      outcome requires, never a one-size-fits-all list:
      - **Success, `--uncommitted`/`--base` scope (a real candidate was allocated):**
        `compacted_from_thread`, `candidate_snapshot_path`, `snapshot_digest_before`,
        `snapshot_digest_after`, `compaction_attempt_failure_count` (must be `0`).
      - **Success, non-repo-artifact or `--commit` scope (no candidate ever allocated):** the same
        set MINUS `candidate_snapshot_path`, whose absence here is the CORRECT state, not a defect.
      - **Success, whenever the ROUND's OWN scope is `--uncommitted` — including a non-repo-artifact
        session, which dispatches AS `--uncommitted` under the hood — regardless of whether the
        SPECIFIC call that ultimately produced success was itself a fresh `--uncommitted` dispatch
        or a later `--resume` retry of it: `coverage_source` additionally required (new — closes a
        real gap found during design review, and corrects an overcorrection caught in the same pass:
        a first fix here excluded non-repo-artifact scope entirely, alongside `--base`/`--commit` —
        but non-repo-artifact sessions dispatch `--uncommitted` against an intentionally empty
        `CLEAN_REPO_DIR` per "Non-repo-artifact sessions are a SEPARATE case" above, so the wrapper's
        `--uncommitted` collection branch — and therefore `SOURCE_COVERAGE_JSON` — runs for them too,
        exactly as it already does for round 1 of a non-repo-artifact session, per the earlier-
        established correction "confirmed non-repo-artifact rounds DO report coverage." A SEPARATE
        overcorrection found in the same pass: keying this requirement on "the dispatch that PRODUCED
        success" rather than the round's own scope broke the retry-then-succeed carry-forward case
        entirely — "A retry-then-succeed candidate must reuse its OWN pre-retry coverage" above
        establishes that when a fresh `--uncommitted` attempt first fails then succeeds via
        `--resume`, the FINAL (successful) call is itself a `--resume`, which the wrapper never
        combines with a scope flag and never populates `SOURCE_COVERAGE_JSON` for — so "the dispatch
        that produced success used `--uncommitted`" is literally FALSE for exactly this case, even
        though its carried-forward coverage is exactly what this requirement exists to verify. "Coverage
        epoch" above already establishes that a successful fresh `--uncommitted` compaction restart's
        own coverage — real value OR the `"unknown"` sentinel — is durably persisted and feeds the
        shared convergence/final-artifact reducer, but this verify branch never actually required it,
        so a partial/unknown epoch could be silently dropped by an otherwise round-valid append,
        letting later consumers miss it entirely).** Required: `coverage_source`, either a real value
        or the `"unknown"` sentinel, never simply absent — checked against the round's own recorded
        `target.scope`, never against which specific call within that round happened to succeed.
        **Never for `--base`/`--commit` scope
        specifically (never non-repo-artifact) — even though `--base` also allocates a candidate,
        both `--base` and `--commit` use their OWN distinct wrapper flags, never `--uncommitted`, so
        neither ever emits `coverage.source` at all (confirmed directly against the wrapper:
        `SOURCE_COVERAGE_JSON` is populated only inside the `--uncommitted` collection branch),
        matching round 1's own identical scope-dependent coverage rule.**
      - **Success reached after ANY earlier failed sub-attempt, not only via the fresh-B retry
        topology (new — closes a real gap found during design review, and widened once more in a
        later pass: the success branches above never required `compaction_attempt_failed_thread` at
        all, so a round whose success came only after abandoning thread A — per "Reconciling with
        `references/retry-guards.md`'s OWN full escalation topology" above — could omit A's own id and
        still pass verification, leaving that abandoned thread durably unaccounted for despite
        "Durable backstop for abandoned threads" depending on exactly this field to reconstruct it.
        This branch's own name and framing then stayed narrowly "fresh-B" even after a THIRD success
        sub-case was established — candidate A's own bullet-2 no-threadId fresh-retry success, which
        has a real earlier failed response worth preserving via `compaction_attempt_execution`/
        `compaction_attempt_coverage` but genuinely no abandoned thread to record via
        `compaction_attempt_failed_thread` at all, since nothing was ever captured to abandon.)**
        Whichever success branch above applies, and for ANY of the three sub-cases in "Applies to a
        retry-then-succeed round too" above (A's own resume retry-then-succeed, A's own no-threadId
        fresh-retry success, or A-exhausted-then-B-succeeds): ADD `compaction_attempt_failed_thread`
        (the array covering whichever earlier sub-attempt(s) were GENUINELY abandoned before this
        round's real success — correctly EMPTY/absent for BOTH the resume-retry-then-succeed AND the
        no-threadId-fresh-retry-success sub-cases, since in EITHER, the SAME thread that had the
        earlier failed response is what goes on to succeed — nothing was ever abandoned in either
        case, only in the A-exhausted-then-B-succeeds sub-case),
        `compaction_attempt_execution` whenever the underlying earlier failed response(s) actually
        carried it, and `compaction_attempt_coverage` ONLY for whichever of those earlier failed
        response(s) was itself a fresh `--uncommitted` dispatch — never for a failed `--resume` call
        among them, which carries no coverage at all (see "Scoped to a failed FRESH `--uncommitted`
        dispatch specifically" below for the full reasoning) — exactly mirroring "Applies to a retry-then-succeed
        round too" above.
      - **Attempted-and-failed, falling through to the fallback:** `compaction_attempt_failure_count`
        — EXCEPT when the failure was `byte_budget_exceeded` (see "A real latch, not merely an
        implicit..." below), which deliberately never increments this counter, so its absence here
        is likewise the correct state, not a defect. `compaction_attempt_failed_thread` is required
        additionally (an array of 1 or 2 ids — see "Reconciling with `references/retry-guards.md`'s
        OWN full escalation topology" above), **keyed on whether a threadId was ACTUALLY captured for
        each abandoned attempt, never on a fixed reason-category exclusion list (corrected — closes a
        real gap found during design review: an earlier revision excluded only `no_thread_started`/
        `bad_args`/`git_error`/`incomplete_collection` as always-no-ID reasons — but `interrupted` can
        ALSO occasionally lack a threadId, per this same design's own corrected candidate-retry
        predicate above ("`references/retry-guards.md`'s own actual rule keys on whether THIS
        SPECIFIC RESPONSE captured a threadId... it explicitly notes `interrupted`/`timeout` can
        occasionally lack a threadId too"). Since `interrupted` was NOT in that exclusion list, a
        candidate whose only failure was a no-ID `interrupted` occurrence — exhausted per bullet 2's
        own no-ID handling, with no thread ever captured — would leave this verify branch requiring
        an id to record when none genuinely exists, an impossible-to-satisfy requirement that would
        wrongly hard-stop a legitimate fallback append.)** Fixed: required whenever at least one
        abandoned sub-attempt's OWN specific response actually captured a threadId — checked
        per-occurrence, exactly like the candidate-retry predicate itself, never inferred from a
        fixed list of reasons. When every abandoned sub-attempt's own response genuinely captured no
        threadId at all, this field is correctly absent, matching the fact that nothing was ever
        created for `LEAKED_THREAD_IDS` to track.
      - **Any round that newly sets `compaction_disabled_reason` this round (baseline over
        threshold, baseline unusable, failure count reaching its bound, or byte budget exceeded):**
        that field is additionally required whenever the round's own processing actually reached
        that decision this round — closes a related gap found in the same review pass, where the
        original extension checked candidate/thread/count fields but never the disable-latch field
        itself, despite the design elsewhere calling it a one-shot durable latch exactly as
        load-bearing as the others.
      - **Any round whose own processing discovers a genuinely pre-append snapshot-deletion failure
        this round (a partial-candidate or abandoned-candidate deletion failure, per "Retired-
        snapshot tracking is general-purpose" above — the two LIVE, within-a-round cases; promotion
        itself is a single atomic rename with no separate post-append deletion step of its own — see
        "On success, promotion is ONE atomic rename..." above):** `retired_snapshot_files` is
        additionally required, non-empty. **Also required, additionally non-empty, on whichever round
        actually carries a DEFERRED backfill from an earlier recovery-discovered candidate deletion
        failure (new — closes a related gap found in the same review pass: the recovery-triggered
        deferred-backfill case — see "PROVISIONAL_SNAPSHOT_FILE"'s post-append-window recovery step 2
        above — attaches to whichever round NEXT actually dispatches and appends its own line, but
        this verify extension never covered that case at all, leaving it with no matching verification
        branch despite being just as durability-critical as the two live cases).**
      - **Round 1's own line, whenever `--compact` was given for this session (new — closes a real
        gap found during design review: every branch above applies only to a round that itself
        records a compaction OUTCOME, R > 1 — but round 1's own `target.scope_value`
        (`--base`/`--commit` only) and `target.original_scope_framing` (always) are exactly as
        durability-critical, since a LATER compaction restart has no other durable source for either
        — yet nothing verified round 1's own line for them at all, so a partial-but-parseable round-1
        append could pass the existing round-number check while silently losing the only safe source
        a later restart depends on).** `target.original_scope_framing` is required on round 1's own
        line whenever `--compact` was given for the session (regardless of scope); `target.scope_value`
        is additionally required specifically for `--base`/`--commit` scope (never for
        `--uncommitted`, which has no such argument, per its own existing definition above). **A
        further durability-critical round-1 field this same branch had also missed:
        `target.resolved_commit_sha` (new — closes a related gap found in the same review pass: the
        pinned SHA every later `--commit`-scope compaction restart is REQUIRED to redispatch against,
        per "Round 1 itself must be pinned too" above, was durably logged but never covered by this
        verify branch either).** Required additionally, specifically for `--commit` scope, WHENEVER
        resolution succeeded per that section's own single-clean-SHA verification (never required
        when resolution itself failed verification and round 1 deliberately fell back to the
        original unpinned literal value instead, per that section's own accepted, disclosed
        limitation — that case correctly has no `resolved_commit_sha` to check).
      **Presence and type are not enough on their own — the durability-critical fields must also
      match the VALUE Claude itself already computed for this transition (new — closes a real gap
      found during design review: a first revision of this whole extension checked only that
      `compaction_attempt_failure_count` was "an integer," for instance — so a bug or corruption
      that appended `0` on an actual FAILURE round would still pass verification, and a later
      continuity recovery reading that `0` would grant two MORE failures than the two-strike bound
      actually allows, silently defeating the circuit breaker's entire purpose. The same blind spot
      applies to every other durable field here.)** Fixed: wherever this round's own processing
      already computed an authoritative value BEFORE the append (every field on this list qualifies
      — that is precisely why each is being appended in the first place), the verify step compares
      the appended value against that already-known value, not merely its shape:
      `compaction_attempt_failure_count` must equal the just-incremented (or, on success, `0`) value
      Claude itself computed this round, never merely "any integer"; `snapshot_digest_before`/
      `snapshot_digest_after` must equal the digests Claude itself hashed; `candidate_snapshot_path`
      must equal the literal `mktemp` path Claude itself allocated this round;
      `compaction_disabled_reason` must equal the SPECIFIC cause that actually triggered it this
      round, not merely be one of the 4 valid strings; `compaction_attempt_execution`, when the
      underlying failed response(s) actually carried it, must be present and non-empty, never
      silently dropped. **`compaction_attempt_coverage` follows a STRICTER rule than
      `compaction_attempt_execution`, but ONLY for `--uncommitted`-scope sub-attempts — required
      whenever a real wrapper dispatch was attempted under THAT scope, not merely when a response
      happened to carry a real value (corrected — closes a real gap found during design review, and
      a related overcorrection caught in the same pass: the established coverage philosophy
      elsewhere in this design is "always record — the real value when present, the `\"unknown\"`
      sentinel when absent" for `--uncommitted` — e.g. an `interrupted` failure can legitimately fire
      before collection ever completes, per the base skill's own documented timing, in which case
      the CORRECT durable state is the `\"unknown\"` sentinel, not an absent field entirely. But a
      first attempt at this fix stated the rule as "whenever a real wrapper dispatch was attempted"
      with no scope qualifier at all — which is actually IMPOSSIBLE to satisfy for `--base`/`--commit`
      sub-attempts: the wrapper never populates `SOURCE_COVERAGE_JSON` outside its `--uncommitted`
      collection branch, so a `--base`/`--commit` sub-attempt can never carry a "real value" NOR
      legitimately produce an `\"unknown\"` sentinel to satisfy an unqualified "always required"
      rule — for those two scopes, `compaction_attempt_coverage` correctly has NO entry at all for
      that sub-attempt, exactly matching how round 1 itself never reports coverage under those
      scopes either.)** **Also scoped to a FAILED sub-attempt specifically, never a direct,
      first-attempt success (corrected once more — closes a related gap found in the same review
      pass: this field is defined, from its very first introduction above, as "one entry per FAILED
      fresh `--uncommitted` sub-attempt" — but the wording just fixed still said "for every
      `--uncommitted`-scope sub-attempt... a real wrapper dispatch was attempted," with no exclusion
      for a round that succeeds on its OWN first fresh attempt, with no failed sub-attempt at all to
      report. Requiring this field there would force either an append-verification failure or
      fabricating a nonexistent failed-attempt record.)** **Scoped to a failed FRESH `--uncommitted`
      dispatch specifically, never a failed `--resume` call within an `--uncommitted`-scoped round
      (further corrected — closes a related gap found in the same review pass: "for every
      `--uncommitted`-scope sub-attempt that actually FAILED" was still ambiguous about a failed
      `--resume` call occurring WITHIN an `--uncommitted`-scoped round's own retry machinery —
      candidate A's own bounded resume-retry, or the bullet-3 same-thread retry, can each fail on
      their own; neither is a fresh `--uncommitted` dispatch, and the wrapper never combines
      `--resume` with a scope flag nor populates `SOURCE_COVERAGE_JSON` for one, so requiring an
      entry for a failed resume-retry would be exactly as impossible to satisfy as requiring one for
      a `--base`/`--commit` sub-attempt.)** Fixed: `compaction_attempt_coverage`'s array entries
      correspond ONLY to a failed FRESH `--uncommitted` dispatch — candidate A's own original
      attempt, the no-threadId fresh retry, or thread B's own dispatch, each only when it uses
      `--uncommitted` scope and itself fails — either the real `coverage.source` value or the
      `\"unknown\"` sentinel for that entry, never simply absent. A failed `--resume` call is never a
      fresh `--uncommitted` dispatch and correctly gets NO entry here, regardless of the round's own
      overall scope. A round whose FIRST fresh `--uncommitted` attempt succeeds directly has no
      failed sub-attempt at all, and correctly has no `compaction_attempt_coverage` entry — its own
      coverage is reported via `coverage_source` instead (see above), never this field. For a
      `--base`/`--commit`-scope sub-attempt, no entry is ever required or expected. A missing,
      malformed, OR
      value-mismatched required field for whichever of these branches actually applies is treated
      with the SAME severity as a wrong round number — a hard stop,
      `🛑 REVIEW LOG INTEGRITY FAILURE`, never a soft warning — since these fields are exactly as
      durability-load-bearing as the round number itself; a field this round's own outcome does NOT
      require is correctly absent and must never be flagged as missing. **If this append fails
      verification: the new thread and candidate snapshot are ALREADY tracked as provisional/leaked
      (step 2 above) and get cleaned up by the existing `🛑 REVIEW LOG INTEGRITY FAILURE` path
      exactly like any other leaked resource — nothing extra to do here, and nothing new leaks.**
   4. **Only after that append is verified**: (a) promote — remove the NEW thread id from its
      provisional `LEAKED_THREAD_IDS` entry and make it the active `GROUP_THREADS` entry instead;
      add the OLD thread id to `LEAKED_THREAD_IDS` in its place (never an immediate `--cleanup` —
      see "Interaction with `--keep-evidence`" below); (b) **only for `--uncommitted`/`--base` scope,
      where a real candidate exists — corrected here (closes a real gap found during design review:
      an earlier revision ran this sub-step unconditionally, but non-repo-artifact and `--commit`
      scope both deliberately allocate NO candidate at all, per their own existing definitions above
      — "the ORIGINAL round-1 snapshot... remains active and untouched throughout" — so there is
      nothing to rename for either, and this whole sub-step (b) is simply skipped entirely for those
      two scopes; `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` are already correct, having never changed):**
      immediately before the rename, re-verify BOTH sides of the transition, not only the
      destination (extended — closes a related gap found during design review: checking only the
      OLD active file leaves the CANDIDATE itself unverified at this late point, even though it was
      collected and hashed much earlier, before the fresh dispatch and append — if it was corrupted
      in that window, promoting it would advance `SNAPSHOT_DIGEST` to a value that no longer
      describes the file's real bytes, and the known-good old content would already be gone by the
      time next round's ordinary check catches the mismatch one round too late):
      - Re-hash whatever currently exists at the active `SNAPSHOT_FILE` path and confirm it still
        matches `snapshot_digest_before`.
      - Re-hash `candidate_snapshot_path` and confirm it still matches `snapshot_digest_after`.
      If EITHER check fails: hard stop, `🛑 SNAPSHOT INTEGRITY FAILURE` — this is genuine,
      newly-discovered corruption unrelated to compaction itself, and promoting over it (or
      promoting a corrupted candidate) would erase or misrepresent the only evidence of it. Only
      once BOTH pass: promote the candidate snapshot via the single atomic
      `mv "$candidate_snapshot_path" "$SNAPSHOT_FILE"` rename described above — no separate old-file
      deletion step exists anymore (an earlier revision described this as "promote the candidate...
      and delete the OLD active snapshot file," treating that deletion as its own fallible step
      tracked via `RETIRED_SNAPSHOT_FILES` — but a single atomic rename cannot fail "after
      succeeding," so there is nothing left to add to that set here). On success, ALSO advance the
      remembered `SNAPSHOT_DIGEST` to `snapshot_digest_after` in this same step (see "`SNAPSHOT_DIGEST`,
      the OTHER literal fact..." above — both remembered facts change together). **A failure of this
      `mv` itself is handled per "A failed `mv` occurring LIVE, in the same round..." above — retried
      up to 2 more times, then `🛑 SNAPSHOT INTEGRITY FAILURE` if still failing — never the ordinary
      "On failure" compaction-fallback path below, which structurally cannot apply once this round's
      own success line is already committed. Each retry attempt REPEATS both live checks above
      first, immediately before that specific attempt's own `mv` (new — closes a real gap found
      during design review: only the FIRST attempt had a live pre-check in an earlier revision — if
      either file were corrupted specifically during the pause between retries, a later retry would
      silently overwrite it without ever re-detecting that corruption, defeating the whole purpose of
      the check this same round already added).**

   **Retired-snapshot tracking is general-purpose, covering the two deletion points that remain
   fallible on their own (revised — closes a real gap found during design review: an earlier
   revision listed THREE deletion points sharing this mechanism, including "old active snapshot
   after promotion" — that third case no longer exists as a separate fallible step now that
   promotion is one atomic rename (see "On success, promotion is ONE atomic rename..." above), so
   `RETIRED_SNAPSHOT_FILES` now covers exactly the two REMAINING cases below, both genuinely
   independent `rm` calls on a candidate being ABANDONED, not promoted):

   The two cases are: a failed deletion of a PARTIAL candidate, per step 3's own collection/hash-
   failure handling above, before it ever became a fully-hashed candidate at all; and a failed
   deletion of a fully-hashed candidate on ordinary compaction failure, per "On failure" step 2
   below — in EITHER case, if a LATER compaction attempt's own single `PROVISIONAL_SNAPSHOT_FILE`
   slot then gets reassigned to a new candidate, the earlier failed-to-delete file is referenced by
   nothing at all, tracked by neither the active/provisional slots nor anything else. Both route
   through the exact same set on their own deletion failure, never two separate ad hoc mechanisms.
   Phase 3's terminal cleanup (every terminal path) attempts `rm -f` on every path ever added to
   this one set, giving each a final retry at session end.

   **Retired- and provisional-snapshot durability — real fix for one, honest disclosure for the
   other (new — closes a real gap found during design review, and corrects an overclaim: an earlier
   revision, while fixing the SEPARATE `compaction_disabled_reason` durability gap above, asserted
   `PROVISIONAL_SNAPSHOT_FILE`/`RETIRED_SNAPSHOT_FILES` already had "a durable JSONL-backed recovery
   path" as existing precedent — confirmed, on inspection, that neither ever actually did; both were
   only ever described as in-memory session-scoped facts, "analogous in spirit to
   `LEAKED_THREAD_IDS`" without ever receiving the SAME durable-field treatment that name actually
   has.**
   - **`RETIRED_SNAPSHOT_FILES` — made genuinely durable for both of its now-two deletion points
     (simplified — the post-append "old-snapshot deletion after promotion" case this earlier
     revision handled separately no longer exists as a distinct fallible step now that promotion is
     a single atomic rename — see "On success, promotion is ONE atomic rename..." above — so there
     is no longer a post-append case to give separate, deferred treatment to here).** Both of the
     two remaining cases — a failed deletion of a PARTIAL candidate (step 3) and a failed deletion of
     an abandoned fully-hashed candidate (step 6 below) — are discovered strictly BEFORE that round's
     own JSONL line is ever written, so the fix is uniform and immediate for both: the path is added
     to a new array field, `retired_snapshot_files`, on that SAME round's own line (present only
     when non-empty), and Phase 3's terminal cleanup plus continuity recovery are both extended to
     union in every path ever recorded in this field across the session's log — the same "durable
     backstop, in-memory set is not the sole source of truth" pattern already established for
     `LEAKED_THREAD_IDS`. **No deferred, next-round backfill is needed for EITHER of these two LIVE
     cases** — corrected below: a THIRD case, discovered later during continuity recovery rather than
     live within a round, still needs exactly this kind of deferred treatment (see
     "PROVISIONAL_SNAPSHOT_FILE"'s own post-append-window recovery step 2 above, and its own
     dedicated deferred-backfill explanation there) — this claim of "no deferred backfill needed at
     all" applies only to the two live, pre-append cases described in this bullet, not to recovery's
     own separate, later-discovered case.
   - **`PROVISIONAL_SNAPSHOT_FILE` — two genuinely different windows, not one (corrected — closes a
     real gap found during design review: an earlier revision described this window as "ENTIRELY
     within one round's own processing, before that round's own JSONL line is ever appended at all,"
     which is true only for the FAILURE-path window below — the SUCCESS path's own promotion (step
     5.4) happens strictly AFTER that same round's own append already verified (step 5.3), so its
     provisional window genuinely spans the append boundary, contradicting the "entirely pre-append"
     framing for that case).**
     - **Pre-append window (failure path, or success path before its own append) — disclosed,
       accepted residual gap, not fully closed. Impact corrected (closes a real overclaim found
       during design review): this window's impact is NOT limited to "at most one small temp file,
       never a thread" as an earlier revision claimed — on the SUCCESS sub-case specifically, the
       newly-created thread is ALSO only tracked in-memory (`LEAKED_THREAD_IDS`, step 5.2 above)
       until that SAME append lands, so a crash in this exact window can orphan that new thread too,
       not only the candidate file. This is not a NEW risk compaction introduces, though: it is the
       identical, already-accepted gap every ordinary round's own thread creation already has before
       ITS OWN first append (the standard per-round `threadId` field is what makes any round's own
       thread durable, and that field, like everything else on a line, only exists once the line is
       appended) — "Durable backstop for abandoned threads" above durably covers the OLD thread (on
       success) and the failed attempt's thread (on failure) specifically because those are
       genuinely NEW durability needs this feature adds; the NEW thread's OWN pre-append window on
       the success path was already covered by nothing more than every other round's thread already
       is, and is accepted on the same terms.** "Provisional" here describes a file mid-transit,
       between successful candidate creation and either its own deletion on failure (step 6 below)
       or this round's own JSONL append on the way to success — in both cases, entirely before any
       line for this round has been written. A session interrupted in exactly that narrow window has
       no completed line yet to attach a durability marker to; true crash-safety for this specific
       window would need a different mechanism (e.g. a pre-round, write-ahead marker file, committed
       before candidate creation even begins) — a larger design escalation than this narrow,
       low-probability window warrants for v1. This gap is accepted and disclosed, not silently left
       implicit: an interruption in this exact window can leave one orphaned candidate file (and, on
       the success sub-case, one orphaned thread, on the same accepted terms as any other round's own
       pre-append thread) behind with no recorded path to retry its cleanup, and not addressed
       further in this design. **This same window can span MORE than one candidate/thread pair when
       the fresh-B escalation is reached (new — closes a real gap found during design review: A is
       added to `LEAKED_THREAD_IDS` in-memory-only before B is ever dispatched, per "Reconciling
       with `references/retry-guards.md`'s OWN full escalation topology" above — an interruption
       after that point but before the round's own final line (B's success, or the ultimate
       fallback) is appended loses A's own record too, in addition to whatever of B's own resources
       are themselves still pre-append at that moment).** This does not change the category of the
       gap — it remains the same accepted, disclosed, bounded-impact residual window described
       above, just capable of covering up to two candidate/thread pairs (A and B) instead of always
       exactly one, for the same underlying reason and with the same deliberately-not-addressed
       resolution.
     - **Post-append window (success path only, between step 5.3's verified append and step 5.4's
       promotion) — genuinely closed, not merely disclosed, via durably recording the candidate's
       own random path (see "Recoverable without giving up `mktemp`'s own symlink-attack protection"
       in the snapshot-candidate-lifecycle bullet above).** **Never skip the mandatory
       verify-before-trust step snapshot-integrity.md already requires, even inside this recovery
       (corrected — closes a real gap found during design review: an earlier revision's recovery
       algorithm branched directly on `candidate_snapshot_path`'s own existence without ever
       independently verifying what is CURRENTLY at the active path first — so (a) if the active
       file had been separately corrupted or deleted during the same interruption (unrelated to
       promotion itself — e.g. stray `/tmp` cleanup), the "candidate exists" branch would silently
       overwrite it with the verified candidate, never raising the same
       `🛑 SNAPSHOT INTEGRITY FAILURE` the base mechanism requires for exactly this kind of
       unexplained state; and (b) the "candidate absent" branch declared promotion complete purely
       from absence, without ever confirming the active file actually matches `snapshot_digest_after`
       — absence could equally mean the candidate was lost some OTHER way before ever being moved,
       leaving the active file still at its PRE-promotion state, silently treated as done.)** Fixed:

       **Search the WHOLE log for the most recent compaction event, never just the latest line (new
       — closes a real gap found during design review: an earlier revision scoped this whole
       recovery algorithm to "a session whose LATEST completed line shows a successful compaction" —
       but once even ONE ordinary, non-compaction round R+1 completes after a successful compaction
       at round R, the latest line no longer carries `compacted_from_thread` at all, so this
       precondition goes permanently false for the rest of the session — even though the active file
       on disk still holds round R's promoted content/digest, which a LATER interruption's own
       recovery would then have no path to reconstruct, since the algorithm below would simply never
       run.)** Fixed: this recovery algorithm's own trigger is not "the latest line," but whether ANY
       round in the ENTIRE session log ever recorded a successful compaction — reduce backward
       through the log for the MOST RECENT round carrying `compacted_from_thread`/
       `snapshot_digest_after`/(when applicable) `candidate_snapshot_path`, and reconstruct the
       remembered `SNAPSHOT_DIGEST` from THAT round's own recorded values, regardless of how many
       ordinary rounds have completed since. Once reconstructed, this performs an explicit
       verify-before-trust of the CURRENT active file FIRST, before consulting
       `candidate_snapshot_path` at all:
       1. Hash whatever currently exists at the active path. If it is missing, or its hash matches
          NEITHER `snapshot_digest_before` NOR `snapshot_digest_after` — this is genuine, unexplained
          corruption or loss, unrelated to anything this recovery can resolve on its own — hard stop,
          `🛑 SNAPSHOT INTEGRITY FAILURE`, exactly as the base mechanism already requires, never
          silently proceeded past.
       2. If it matches `snapshot_digest_after`: the observable bytes are already correct either way.
          **Still check `candidate_snapshot_path` before concluding nothing remains to do — do not
          assume the rename ran just because the digests already agree (corrected — closes a real
          gap found during design review: "the mv cannot still exist once it succeeds" is only true
          when the mv actually RAN — but in the before/after-identical edge case specifically
          (`snapshot_digest_before == snapshot_digest_after`), a crash after this round's own success
          append but BEFORE the `mv` ever executed leaves the OLD, unpromoted file already
          "matching" `snapshot_digest_after` purely because the two digests happen to be equal — the
          candidate is then still sitting, unrenamed, at `candidate_snapshot_path`, and since
          `PROVISIONAL_SNAPSHOT_FILE` is only ever an in-memory fact, that same interruption erases
          the only other record of it, permanently orphaning a real file with nothing left to clean
          it up.)** If `candidate_snapshot_path` still exists on disk (whether or not the `mv` for it
          actually ran — in the normal case it will already be gone, since a completed move can't
          leave its source behind): it is no longer needed either way — delete it. **A failed
          deletion here cannot fold into `retired_snapshot_files` the same way the two ordinary
          pre-append cases do (corrected — closes a real gap found during design review: that field
          can only be added to a round's OWN line AT APPEND TIME, but recovery runs LATER — often in
          a completely separate, later invocation — long after this round's own line was already
          committed, with no line of its own being appended right now to attach anything to).**
          Instead, apply the SAME deferred-backfill treatment already established for the post-append
          old-snapshot case before atomic rename replaced it: attach this failed path to the NEXT
          round that actually dispatches and appends its own line (best-effort backfill). If no
          further round is ever dispatched after this recovery (an immediately terminal outcome) —
          this shares the exact same accepted, disclosed, bounded-impact residual gap as
          `PROVISIONAL_SNAPSHOT_FILE`'s own pre-append window above, for the identical underlying
          reason (no later completed line exists to attach a durability marker to). Proceed normally.
       3. If it matches `snapshot_digest_before` (still the OLD file — the atomic rename has NOT yet
          run): check `candidate_snapshot_path`. If it exists and verifies against
          `snapshot_digest_after`, the crash landed in exactly this window — run the SAME
          `mv "$candidate_snapshot_path" "$SNAPSHOT_FILE"` now to complete it, with the IDENTICAL
          retry-then-hard-stop treatment as the live promotion case (new — closes a real gap found
          during design review: an earlier revision left this recovery-triggered `mv` completely
          unspecified beyond "either fully succeeds or fully fails," never stating whether it gets
          retries, what happens on exhaustion, or whether `SNAPSHOT_DIGEST` advances afterward — all
          three of which "A failed `mv` occurring LIVE..." above already answers for the live case,
          and there is no reason recovery's OWN `mv` should behave any differently, since it is
          mechanically the identical operation): retry up to 2 more times on failure (re-verifying
          both the active file against `snapshot_digest_before` and the candidate against
          `snapshot_digest_after` before each attempt, exactly as the live case does); on success,
          advance the remembered `SNAPSHOT_DIGEST` to `snapshot_digest_after` in this same step,
          exactly as the live case does; if all retries are exhausted and the `mv` still fails, hard
          stop, `🛑 SNAPSHOT INTEGRITY FAILURE` (no partial state to fold into `retired_snapshot_files`
          either way, per the same atomicity guarantee). If the candidate is missing, or present but
          fails to verify BEFORE any `mv` is even attempted, neither the promoted state nor a valid
          pre-promotion candidate can be produced — hard stop, `🛑 SNAPSHOT INTEGRITY FAILURE`, never
          silently continued.
6. **On failure (any `ok:false` reason, including `artifact_too_large`) — self-contained fallback,
   never this round's own terminal outcome, and NEVER a separate JSONL append (closes a real
   one-object-per-round contract violation found during design review — an earlier draft implied
   a standalone append for the failed attempt, which conflicts with the append-verify contract
   requiring exactly one JSONL object per round number):**
   1. **Three independent checks on the failed attempt's own response — each captured whenever
      present, none gated on whether another is present (closes a real gap found during design
      review: an earlier draft nested `execution`/`coverage` capture inside "if a threadId exists,"
      but `no_thread_started` — no `threadId`, since the wrapper's own reason table shows that
      branch requires an empty `THREAD_ID` — still carries a genuine `execution` object, since Codex
      was already launched and timed before that failure was detected; nesting would have silently
      dropped exactly this real telemetry):**
      - If a `threadId` is present (several reasons carry one), remember it in-memory in
        `LEAKED_THREAD_IDS` immediately — it must not linger untracked, and this is a REQUIRED step
        whenever a threadId exists, not best-effort (see "Durable backstop for abandoned threads"
        below for why).
      - If an `execution` object is present (several failure reasons launch Codex and so still
        report real elapsed time/usage, independent of whether a `threadId` ever got assigned — see
        "Preserving failed-attempt telemetry" below), remember it.
      - **A failed compaction attempt's coverage is DURABLY LOGGED for audit, but NEVER folded into
        the shared convergence-gating reducer (corrected here — closes a real false-CLEAN gap found
        during design review, and reverses part of an earlier revision's own fix). The earlier
        revision treated a failed attempt's coverage symmetrically with a successful one — recording
        `coverage.source` when present or the `"unknown"` sentinel when absent, then folding it into
        the shared reducer either way. This is wrong specifically for the FAILURE case: `coverage`
        describes whether file COLLECTION completed for the CANDIDATE diff — it says nothing about
        whether a real Codex VERDICT was ever produced for that candidate. When the attempt fails,
        the candidate is discarded and the round falls back to `--resume` on the OLD thread, which
        only ever continues reviewing the OLD thread's own original diff context — confirmed
        directly against the wrapper's own source: `--resume` cannot be combined with a scope flag
        and never re-collects a diff, so the fallback thread has no knowledge of whatever changes
        the candidate alone captured. Folding the candidate's own "complete" collection status into
        the session's overall coverage would therefore claim the codebase was fully reviewed when
        the specific content that triggered this compaction attempt was, in fact, reviewed by
        NOBODY. This differs from the existing `references/retry-guards.md` precedent for an
        ordinary failed round-1 dispatch, which this design's earlier revision incorrectly treated
        as identical: that precedent works because retrying preserves and eventually resumes the
        SAME thread that will itself go on to produce a real verdict for that SAME collected diff —
        the coverage information stays meaningful because the epoch it describes is still part of
        what the session ultimately reviews. A failed COMPACTION attempt's fallback explicitly does
        NOT do this — it abandons the candidate thread and diff entirely, falling back to a
        DIFFERENT thread reviewing DIFFERENT (older) content.** Fixed: `compaction_attempt_coverage`
        is still recorded on the round's own JSONL line whenever a real FRESH `--uncommitted` wrapper
        dispatch specifically was attempted and returned `ok:false` — `coverage.source` when present,
        or the `"unknown"` sentinel when absent, exactly as before — but purely as a durable,
        best-effort AUDIT record of what that abandoned attempt's own collection situation was. **This
        is scoped to a failed FRESH `--uncommitted` dispatch alone — never a failed `--resume` call
        within the same round's own retry machinery, which never carries coverage at all and
        correctly gets no entry here regardless of the round's overall scope (see "Scoped to a failed
        FRESH `--uncommitted` dispatch specifically, never a failed `--resume` call" in the
        append-verify section below for the full reasoning — an earlier revision here left this
        broader "whenever a real wrapper dispatch was attempted" phrasing unqualified, contradicting
        that later, more precise scoping).** It is explicitly EXCLUDED
        from the shared reducer's convergence-gating computation** — the CLEAN gate, continuity
        recovery, and the final artifact's own `coverage` field all consider ONLY successful fresh
        `--uncommitted` dispatches' coverage (round 1, or a compaction restart that actually
        succeeded), never a failed attempt's. A LOCAL pre-dispatch failure (step 1's digest
        verification, step 3's candidate collection/hash failure, or the byte-size preflight
        rejection) records no coverage field at all, for the same underlying reason plus the
        additional fact that no real dispatch was ever attempted — coverage-wise, both kinds of
        compaction failure are, and remain, exactly as if compaction had never been attempted this
        round, from the reducer's point of view. For `--base`/`--commit` scope, no coverage field is
        ever recorded — that scope never reports coverage, exactly like round 1 in that case. **A
        non-repo-artifact session is NOT exempt from the general rule that a SUCCESSFUL restart's
        coverage DOES fold into the reducer** (corrected — an earlier revision incorrectly claimed it
        never reports coverage at all): its `--uncommitted` dispatch against `CLEAN_REPO_DIR` DOES
        report coverage on success, exactly as round 1 already does for this session type (per the
        base skill's own documented behavior, ordinarily `{"status":"complete",
        "reviewed_file_count":0,"omitted":[]}` against the always-empty clean repo) — but a FAILED
        non-repo-artifact compaction attempt's coverage is excluded from the reducer for the exact
        same reason as any other scope's failed attempt.**
   2. Delete the candidate snapshot file (if one was allocated this attempt — never for `--commit`
      scope or a non-repo-artifact session, neither of which allocates one) — it was never used for
      anything. On a failed deletion here, add its path to `RETIRED_SNAPSHOT_FILES` — see
      "Retired-snapshot tracking is general-purpose" above.
   3. Log one narration line noting the compaction attempt failed and why.
   4. Fall through to a NORMAL `--resume` dispatch against the STILL-ALIVE old thread (still the
      active `GROUP_THREADS` entry — never touched by a failed attempt), validated against the
      STILL-ACTIVE, untouched original snapshot, using this round's real History/Scope focus text
      exactly as an ordinary round would — this IS round R's real dispatch in the failure case.
      **This fallback dispatch is subject to the EXISTING retry-by-failure-reason procedure
      (`references/retry-guards.md`) exactly like any other round's own dispatch would be (closes a
      real gap found during design review: an earlier draft never addressed what happens if the
      fallback ITSELF initially fails)** — the compaction-attempt fields from steps 1 and 3 above
      are carried through that entire retry sequence in memory, and attached only once, to whatever
      single result eventually gets appended for round R (its own eventual accepted success, or its
      own eventual terminal non-CLEAN outcome if retries are exhausted) — never an intermediate
      failed fallback attempt logged as if it were round R's final result. The compaction threshold
      check runs again next round if still exceeded.
   5. **This round's own single JSONL line — written once, after step 4's fallback dispatch (and any
      of its own retries) reaches its final result, exactly like any other round — additionally
      carries the failed attempt's own `compaction_attempt_failed_thread` (and
      `compaction_attempt_execution`, when available) as REQUIRED fields on THAT SAME line whenever
      step 1 applies.** There is no separate append for the failed attempt at any point — round R
      still produces exactly one JSONL object, satisfying the existing one-object-per-round
      append-verify contract unchanged; the failed attempt is recorded only as additional fields
      riding on round R's own real (fallback) result, and — because that line's append already goes
      through the EXISTING mandatory append-verify hard stop — these fields inherit that same
      mandatory (never best-effort) guarantee.

### Interaction with `--keep-evidence` (new — closes a real contract violation in the original draft)

The original draft's "delete the old thread immediately on successful restart" step was wrong: it
is not yet known, at compaction time, whether this SESSION will end CLEAN or not — and the
`--keep-evidence` contract requires every thread in `GROUP_THREADS`/`LEAKED_THREAD_IDS` to survive
an eligible non-CLEAN outcome for later inspection. **Fixed: the old thread is never eagerly
deleted.** Step 5.4 above always routes it through the EXISTING `LEAKED_THREAD_IDS` mechanism
instead of a direct `--cleanup` call — Phase 3's already-keep-evidence-gated terminal cleanup then
handles it with zero special-casing: deleted normally on `✅ CLEAN` (or any outcome with
`--keep-evidence` OFF), preserved alongside the new thread on an eligible non-CLEAN outcome with
`--keep-evidence` ON. This reuses machinery that already exists for exactly this "an earlier thread
was abandoned mid-session" shape (see `SKILL.md`'s own Guards → "Empty / failed review" handling
for round-1 retries), rather than inventing a second cleanup path with its own edge cases.

### Durable backstop for abandoned threads (new — closes a real durability gap found during design review)

`LEAKED_THREAD_IDS` (and `GROUP_THREADS`) are in-memory facts Claude carries across separately-
dispatched tool calls for the rest of the run — the existing design already relies on this for
ordinary round-1 retries. Compaction adds more state of this shape (an abandoned old thread on
every successful restart; a dead-end thread on every failed attempt), so the existing durable-
backstop principle `GROUP_THREADS` already documents ("each round's log line also records the
thread id... so `jq` on the latest round's log line re-derives the mapping if memory is ever in
doubt") is extended to cover both here too, rather than leaving compaction as the one mechanism
relying on memory alone:
- A successful compaction's `compacted_from_thread` field (already logged, see "Logging" below) is
  itself sufficient to reconstruct that the named thread is abandoned and needs the same treatment
  as a `LEAKED_THREAD_IDS` entry, purely by reading the JSONL log.
- A FAILED compaction attempt's own threadId(s) (when any exist) are additionally recorded as a
  REQUIRED field **on that same round's own single JSONL line** (never a separate append, and never
  best-effort — see "On failure" step 6 above) — `compaction_attempt_failed_thread`, an ARRAY of 1
  or 2 thread ids (see "Reconciling with `references/retry-guards.md`'s OWN full escalation
  topology" above — `[A]` alone when the fresh-B escalation was never reached, `[A, B]` when both
  threads were abandoned). This is deliberately NOT treated like `kept_last_message_path`'s
  best-effort convention: since this field is what makes the "never permanently unaccounted-for"
  guarantee actually true, making it skippable would silently contradict that guarantee the moment
  in-memory `LEAKED_THREAD_IDS` state is lost — it inherits the SAME mandatory append-verify
  guarantee as the rest of that round's line.
- Phase 3 and the final-verdict artifact's own thread enumeration (`references/keep-evidence.md`'s
  retention rules; the `threads[]` array in the durable result artifact) are both extended to union
  in every `compacted_from_thread` and `compaction_attempt_failed_thread` value found anywhere in
  the session's own JSONL log, in addition to whatever `GROUP_THREADS`/`LEAKED_THREAD_IDS` memory
  currently holds — so a thread is never permanently unaccounted-for purely because in-memory state
  did not survive to the end of a long run.

### Failure isolation from the round loop (new — closes a real conflation in the original draft)

A compaction attempt's own dispatch (steps 4-6 above) must never be confused with, or reported as,
a SEPARATE round from the loop's perspective. **Concretely, round R has exactly ONE real OUTCOME, not
one literal network call — "never both" describes the RESULT, never the dispatch count (corrected
here to match "This dispatch IS round R's real dispatch... mean exactly ONE real OUTCOME/RESULT...
never a literal single network call" above, which this section's own original wording had drifted out
of sync with: a failed fresh compaction attempt IS explicitly followed by a real, required, SEPARATE
fallback `--resume` dispatch — two genuine network calls for that one round, not one. The literal
"exactly ONE real dispatch... never both" phrasing, read at face value, contradicts that mandated
two-dispatch failure path.)** Round R's own real, reportable OUTCOME is either the compaction
fresh-dispatch's own success or the fallback `--resume`'s own result — never both simultaneously
claimed as round R's terminal status — and a compaction attempt's own failure reason (e.g.
`artifact_too_large`) is NEVER surfaced as round R's own terminal status regardless of how many
underlying dispatches it took to get there; it is purely an internal detail of "how round R's real
outcome was reached," logged as one narration line (plus the durable `compaction_attempt_*` fields
above), nothing more.

**A THIRD base-skill contract this design conflicts with, needing the SAME companion-amendment
treatment as `references/snapshot-integrity.md` and `references/execution-telemetry.md` above — never
left as an implicit substitution (new — closes a real gap found during design review: this whole
"Failure isolation" principle — absorbing a candidate's own `artifact_too_large`/exhausted-retry
failure into "fall through to the fallback" — directly CONTRADICTS `references/retry-guards.md`'s own
MANDATORY terminal-outcome rules for those exact reasons: `artifact_too_large` is required to end the
group/round as `🛑 INPUT TOO LARGE`, and exhausted retries are required to end as
`⚠️ COULD NOT VERIFY`. `SKILL.md`'s own Phase 2 requires reading `retry-guards.md` before doing
anything with ANY group's `ok:false` response, and says its rules are never to be skipped. This
design substitutes different behavior for the SAME failure reasons without ever formally scoping that
substitution as an amendment the way the OTHER two base-skill conflicts already are above — leaving
retry-guards.md's own mandatory contract and this design's own override mutually incompatible on
paper.)** Fixed: shipping this feature requires the SAME kind of companion amendment to
`references/retry-guards.md` as the other two references already require above — carving out an
explicit, narrow exception: `references/retry-guards.md`'s own `artifact_too_large`/exhausted-retry
terminal-outcome rules continue to apply UNCHANGED to the round's own REAL, reportable outcome (the
existing/OLD thread's own group) exactly as they always have; they do NOT apply to failures occurring
WITHIN a self-contained compaction ATTEMPT on the NEW candidate thread specifically, whose own failure
this design deliberately absorbs into "fall through to the fallback" rather than surfacing as the
round's own terminal status — a compaction attempt is not "a group" in `retry-guards.md`'s own sense,
it is an internal sub-step of producing round R's one real outcome. The base skill's own ordinary,
non-compaction failure handling for a REAL group's `ok:false` response remains governed by
`retry-guards.md`'s existing, unmodified rules. Same category of required change as the
`schema_version` bump and the other two companion amendments above, not a new one.

**This amendment must ALSO cover a SECOND, separate piece of `retry-guards.md`'s own contract — the
no-threadId-fresh-retry and fresh-B escalation rules are explicitly scoped to a group's OWN true
first-ever attempt, "only possible on round 1" — not merely the terminal-outcome substitution just
described (new — closes a real gap found during design review: a compaction restart's own candidate
dispatch is STRUCTURALLY always at session round 2 or later — even the earliest possible trigger,
round 1 itself exceeding threshold per "checking after EVERY completed round including round 1"
above, produces a COMPACTION round that is itself round 2 — yet the candidate's own bullets 2-4 rely
directly on `retry-guards.md`'s own "no entry yet → one fresh retry" and "exhausted resumes → one
fresh fallback" mechanics, which that reference's own literal text scopes to a group's genuine first
attempt, explicitly calling that "only possible on round 1." The terminal-outcome amendment above
never addressed this SEPARATE round-1-only scoping restriction at all.)** **Scoped to candidate A
ONLY, never to thread B — a broader "any compaction candidate" wording would silently re-enable
exactly the B-gets-retry-machinery bug already closed once (new — closes a real gap found in the
same review pass: an initial phrasing of this fix said "for a compaction candidate specifically" with
no A/B distinction — but B is ALSO, literally, a compaction candidate (a second fresh dispatch), and
"Thread B's own single dispatch gets NONE of bullets 1-4's retry machinery" above already
deliberately excludes B from every one of these exact mechanics, precisely to prevent B's own failure
from ever escalating to a third candidate "C." An unscoped "every candidate gets its own first-attempt
lifecycle" exception would directly reopen that already-closed door for B specifically.)** Fixed: the
SAME companion amendment additionally clarifies that, for candidate A specifically (never B),
`retry-guards.md`'s own "no entry yet" / "true first-ever attempt" language is keyed on the
CANDIDATE's own independent thread-history tracking (see "A candidate's OWN no-threadId-at-all
failure needs its own predicate, separate from `GROUP_THREADS`" above) — NOT on the session's own
round-index, and NOT on `GROUP_THREADS` (which keeps meaning the OLD, pre-existing thread throughout a
compaction attempt, per "Failure isolation from the round loop" above). Candidate A is its own
independent "first attempt" lifecycle for these SPECIFIC mechanics, by construction, REGARDLESS of
what round number in the session it actually occurs at — the base skill's own ordinary round-1 groups
keep `retry-guards.md`'s literal round-1 scoping exactly as written; this is a scoped exception for
candidate A only, never B, and never a change to what "round 1" means for an ordinary group. B's own
single-shot rule above governs B completely, unaffected by this amendment.

### Preserving failed-attempt telemetry (new — closes a real cost-accounting gap found during design review)

Several `ok:false` reasons (`timeout`, `nonzero_exit`, `missing_task_complete`, `invalid_json`, and
others — see the interface reference's own reason table) still launch `codex exec` and so still
carry a genuine `execution` object (elapsed time, and usage when available) even on failure. An
earlier draft discarded this — recording only a threadId and a narration line — understating the
real cost of the exact recovery path compaction itself introduces. Fixed: when a failed compaction
attempt's own response carries an `execution` object, it is preserved on round R's own JSONL line
(alongside `compaction_attempt_failed_thread`, per "On failure" step 6 above — never a separate
line) as `compaction_attempt_execution` — **always an array, one `execution` object per failed
sub-attempt that carried one, in attempt order, even when there is only ever a single entry (fixed
here for consistency — closes a real gap found during design review: this field's shape was left
ambiguous between "a single object" and "an array" across different parts of this document; there
is exactly ONE shape, always, established once here and never varying by how many sub-attempts
actually occurred).** **`round_wall_seconds` for a round that included a
failed compaction attempt covers the WHOLE round timeline** — from immediately before the
compaction attempt's own dispatch through the fallback dispatch's own completion — consistent with
its existing definition as coordinator-measured wall time for the entire round, not per-dispatch.

**Applies to a retry-then-succeed round too, not only a round that falls all the way through to the
fallback (new — closes a real gap found during design review: the coverage and
`COMPACTION_BASELINE_TOKENS` carry-forward fixes above already establish that an EARLIER failed
fresh sub-attempt's own data is real and worth keeping even once a LATER retry on the same thread
succeeds — but this field was specified only for the case where the round's overall outcome is
itself a failure falling through to step 6, so a retry-then-succeed round's earlier failed
sub-attempt's own elapsed time, output tokens, and any other non-baseline usage fields were silently
dropped, understating that successful round's real total cost the same way the original gap did for
an all-the-way-failed round.)** Fixed: whenever a compaction round's PATH TO SUCCESS included one or
more earlier failed sub-attempts that each carried an `execution` object, those are ALSO preserved —
as `compaction_attempt_execution`, the SAME always-an-array shape established above, one entry per
failed sub-attempt, in attempt order — on this SAME successful round's own line, alongside
`compacted_from_thread` and the snapshot-lineage fields. **Concretely, exactly THREE sub-cases can
produce this, never a "B retries" case (corrected — closes a real gap found during design review,
and a related gap found in the same pass — an earlier revision said this could include "thread A's
own first response, and/or thread B's" — but per "Thread B's own single dispatch gets NONE of
bullets 1-4's retry machinery" above, B is single-shot by construction: it either succeeds on its one
attempt or is immediately exhausted, so there is no possible "B's own first response failed, then B
itself went on to succeed" scenario for this field to preserve telemetry from. A LATER revision then
narrowed this to just TWO sub-cases, omitting a third, equally real one: candidate A's own bullet-2
no-threadId FRESH retry succeeding — a completely different mechanism from a resume retry, still
carried under the SAME name "A" since no new thread B is ever created for it, but still leaving a
real, genuine earlier failed response of its own worth preserving.)**: (a) candidate A's own
retry-then-succeed via `--resume` (A's first response failed WITH a captured threadId, A itself — the
SAME thread — succeeded on a later ordinary bounded resume retry, per bullet 4 above, or on the
one allowed retry after a no-ID hiccup, per bullet 3 above); (b) candidate A's own bullet-2
no-threadId fresh retry succeeding (A's first response failed with NO threadId at all, the ONE
allowed fresh re-collection then succeeded — still "A," never a new thread identity, per bullet 2
above); or (c) candidate A was exhausted entirely (its own failed attempt(s) via ANY of bullets 1-4)
and thread B then succeeded on its own single, unretried attempt — in case (c) specifically, the
preserved `execution` entries belong to A's own failed attempt(s), never to B (B's own successful
attempt has no failed response of its own to preserve). (On a round that instead falls all the way
through to the fallback, this field is populated the identical way, covering whichever sub-attempts
failed there — one shape, used uniformly on every round that has anything to record in it.)

**Surfaced in the final report, not just durably logged (new — closes a real gap found during
design review: an earlier draft made this field durable in the JSONL log but never extended the
Final Report's own execution-telemetry bullet to actually mention it, silently omitting a failed
attempt's real cost from the user-facing accounting the design otherwise claims to preserve).** The
Final Report's existing execution-telemetry section is extended to also list, for any round that
carries a `compaction_attempt_execution` value, a clearly labeled separate line — distinct from that
round's own real `execution`/`usage` reporting, never merged into it. **The wording must branch on
this round's own real outcome, never assume "before falling back" unconditionally (corrected — closes
a real gap found during design review: an earlier revision's example line — "Round R also attempted a
compaction restart that failed after using `<input>`/`<output>` tokens (`<elapsed>`s) before falling
back" — hardcoded a fallback outcome, but per "Applies to a retry-then-succeed round too" above, this
same field also appears on a round whose real outcome is SUCCESS, where nothing ever "fell back" at
all.)**: for a round whose real outcome is the fallback, "Round R also attempted a compaction restart
that failed after using `<input>`/`<output>` tokens (`<elapsed>`s) before falling back"; for a round
whose real outcome is a success (any of the three sub-cases above — A's own resume-based
retry-then-succeed, A's own bullet-2 no-threadId fresh-retry success, or A exhausted then B
succeeded), "Round R's compaction restart succeeded after an earlier attempt used
`<input>`/`<output>` tokens (`<elapsed>`s)" — in both cases reporting each preserved sub-attempt's own
figures, never conflated with the round's own real dispatch numbers. **Both templates must also
handle a preserved `execution` entry that has NO `usage` object at all, not just no tokens (new —
closes a real gap found during design review: `references/execution-telemetry.md`'s own established
contract allows an `execution` object to legitimately carry only `elapsed_seconds` with `usage`
entirely absent when usage is unavailable — that same reference's own required final-report fallback
for this exact situation is the literal wording "usage unavailable." Both templates above
unconditionally interpolate `<input>`/`<output>`, which cannot be satisfied for such an entry without
fabricating numbers or leaving a broken placeholder.)** Fixed: whenever a preserved
`compaction_attempt_execution` entry lacks a `usage` object, both templates substitute
`references/execution-telemetry.md`'s own established "usage unavailable" wording in place of the
`<input>`/`<output>` tokens portion, reusing that EXACT existing fallback rather than inventing a
new one — e.g. "Round R also attempted a compaction restart that failed after `<elapsed>`s (usage
unavailable) before falling back."

**This still leaves a partial `usage` object unhandled — the wrapper preserves whatever member shape
a `turn.completed` event happens to carry, with no guarantee both `input_tokens` and `output_tokens`
are present together (new — closes a real gap found during design review, confirmed live: the
wrapper's own `build_execution_json()` retains a non-empty `usage` object exactly as received, with
no member validation — a real, valid response carrying only `{"input_tokens": 12}` (no
`output_tokens` key at all) is preserved as-is per `references/execution-telemetry.md`'s own
documented behavior, reproduced directly against the wrapper's own extraction logic. The template
above only branches on "is `usage` present or absent" — a PRESENT-but-partial object still forces the
same unconditional `<input>`/`<output>` interpolation, which cannot be satisfied when only one of the
two actually exists.)** Fixed: report each of `<input>`/`<output>` independently — whichever value is
actually present in `usage` is reported normally; whichever is absent (whether because `usage` itself
is completely missing, or present but missing just that one member) is reported with its own
"unavailable" wording rather than the whole object being treated as all-or-nothing — e.g. "Round R
also attempted a compaction restart that failed after using 12 input tokens (output tokens
unavailable) (`<elapsed>`s) before falling back." This one rule uniformly covers all three shapes: full
usage (both values reported), partial usage (one reported, one marked unavailable), and no usage at
all (both marked unavailable, collapsing to the simpler "usage unavailable" wording as a natural
special case rather than a separately-maintained one).

**"Present" must mean "present AND valid," reusing the EXISTING malformed-usage validation, never a
bare key-existence check (new — closes a real gap found during design review, confirmed live: this
design already established, for `COMPACTION_BASELINE_TOKENS`, that `input_tokens` can be present but
UNUSABLE — a string, `null`, negative, or otherwise non-integer value, per "Handling missing OR
malformed usage data" above — and the wrapper preserves such a value completely unvalidated,
confirmed directly: a `turn.completed` event carrying `{"input_tokens":"not-a-number",
"output_tokens":null}` is retained byte-for-byte. The rule just fixed only checked whether each KEY
exists in the object, so it would render these malformed values LITERALLY — "not-a-number input
tokens," "null output tokens" — as if they were usable counts, precisely the failure mode the
existing validation elsewhere in this design exists to prevent.)** Fixed: apply the SAME existing
non-negative-integer validation this design already uses for `COMPACTION_BASELINE_TOKENS` to each
token value independently here too — a present key whose value fails that validation is treated
IDENTICALLY to an absent key (its own "unavailable" wording), never rendered as a literal malformed
value. One validation rule, reused everywhere a preserved token value is ever reported or acted on,
never a second, looser one invented just for this report line.

### A failed compaction attempt is a superseded attempt, not a novel evidence-lifecycle case (new — closes a real gap found during design review)

A round with a failed compaction attempt followed by its own fallback `--resume` has TWO physical
dispatches, and an earlier draft never addressed how `--capture-evidence`/`--keep-evidence` — which
already allocate a per-dispatch event-log file and last-message scratch file, per
`references/capture-evidence.md`/`references/keep-evidence.md` — apply here. **Fixed: this is
exactly the EXISTING "superseded attempt within a round" case `references/retry-guards.md` already
defines for an ordinary round's own retries — apply it unchanged, inventing nothing new.** The
failed compaction attempt's own raw event-log file (when `--capture-evidence` is ON) is deleted, not
retained, exactly like any other superseded attempt's; its own last-message file (when
`--keep-evidence` is ON) is never kept, exactly like any other superseded attempt's — only the
round's FINAL attempt (the fallback dispatch) participates normally in whichever of the two flags is
ON. This also avoids any path collision: the compaction attempt and the fallback each get their own
temp files under the existing per-attempt allocation scheme, exactly as two retries of the same
round already would.

### Handling missing OR malformed usage data (expanded — closes a real gap in the original draft, plus a further gap found during design review)

`execution.usage` (and, within it, `input_tokens`) is documented as best-effort and may be entirely
absent even on a genuinely successful round. If the most recently completed round's response has no
`execution.usage.input_tokens` to check: **skip the threshold check for this round** (never treat
missing data as "under threshold," which would make an opt-in `--compact` session silently never
compact at all, and never as "over threshold" either) — log one narration line noting the check was
skipped, and re-attempt the check normally at the next round where usage data is available.

**A PRESENT value must also be validated before comparison — never trusted as-is (new — closes a
real gap found during design review, confirmed live: `execution.usage` is deliberately untyped at
the wrapper boundary, with no validation on its member types, so `input_tokens` can legitimately be
a string, `null`, or negative. Directly running a numeric comparison against such a value is
unsafe — confirmed live that both `{"input_tokens":"not-a-number"}` and a plain string value
compare as GREATER than `8,000,000` under `jq`'s own type-ordering rules, which rank any string
above any number — so malformed telemetry could spuriously trigger an unnecessary, expensive fresh
restart instead of being safely ignored).** Fixed: `input_tokens`, when present, must additionally
be validated as a non-negative integer before ever being compared to `COMPACT_THRESHOLD`. Any other
shape — a string, `null`, a negative number, an object, anything non-integer — is treated exactly
like the ABSENT case above: skip the threshold check for this round, narrate, and re-attempt
normally next round. This check never trusts `execution.usage`'s own reported shape without
verifying it first.

### Closed-claim section has its own ceiling (new — closes a real unbounded-growth gap found during design review)

The closed-claim one-line summaries have no bound in the original draft, and the count of closed
claims only ever grows across a session — in a claims-heavy review, this section could itself
eventually threaten the wrapper's 131,072-byte combined-prompt cap, at which point compaction would
permanently fail via `artifact_too_large` (self-contained per "Failure isolation" above, so it
would not break the review, but it WOULD mean the core goal — capping growth — silently stops being
achievable for exactly the sessions most likely to need it). Fixed with a small, bounded rule
consistent with this design's existing YAGNI stance (no LLM summarization): include the
`CLOSED_CLAIM_LIMIT = 20` most-recently-closed claims' one-line summaries verbatim (ordered by
`source_round` descending), and collapse everything older into a single line: `<N> additional
claims resolved/retracted before round <R>; see the session's own JSONL log for full detail.` This
bounds the closed-claim section's own contribution to a small, fixed COUNT regardless of how many
rounds a session eventually runs — see the disclosed limitation immediately below for why this is a
count bound, not yet a byte bound.

**Disclosed, accepted residual limitation (does not fully close finding — capping closed-claim
COUNT bounds one growth vector, not overall byte size, and not the whole prompt).** Two things this
design does NOT fully bound, corrected here after design review:
- The closed-claim cap bounds COUNT (20 entries), not bytes — the marker-reason grammar requires
  only a non-empty sentence, with no length limit, so 20 valid-but-long closure reasons are not
  actually "small" in the way the earlier text implied. Corrected: the count cap is a coarse
  guard, not a byte guarantee by itself.
- Open claims remain fully unabridged with no count or byte bound, and no schema field limits a
  finding's own `summary`/`evidence` length.

So a session with a large number of open/closed claims, one exceptionally large finding, OR a
large re-collected diff/artifact can still produce a rendered prompt exceeding the wrapper's
131,072-byte cap. **Mitigation, corrected to measure via the AUTHORITATIVE collection path, not an
approximation (closes a real undercount gap found during design review): an earlier revision
estimated the diff/artifact component from the CANDIDATE SNAPSHOT — but for `--uncommitted` scope,
the snapshot deliberately records untracked files by NAME ONLY, never their content (this is
`references/snapshot-integrity.md`'s own documented, deliberate design — the snapshot exists to
detect corruption of Claude's local record, not to serve as the real payload). The wrapper's actual
dispatch, however, DOES include eligible untracked files' real content via its own
`collect_untracked_files.py`. A name-only estimate therefore silently undercounts by however large
those files' real content is — confirmed directly against the wrapper's own source that untracked
content collection and prompt rendering are separate, later steps the snapshot's own bytes cannot
stand in for.** Fixed: the preflight estimate reuses the SAME authoritative collection the wrapper
itself performs (the actual `collect_untracked_files.py`-equivalent content collection for
`--uncommitted` scope, not the name-only snapshot) to measure the diff/untracked-content component.

**`--commit` scope ALSO needs a real diff-content component here, not just focus text (new — closes
a real gap found during design review: an earlier revision treated `--commit` restarts as
"focus-only" for this preflight, on the reasoning that no CANDIDATE FILE is ever allocated for that
scope — but that conflates candidate-file ownership (a Claude-side bookkeeping choice) with what the
WRAPPER actually sends: every fresh `--commit` dispatch collects the pinned commit's own patch via
`git show`/`git diff` and embeds it in the prompt exactly like `--uncommitted`/`--base` embed their
own diffs. Treating this component as absent let a large pinned commit pass the 120,000-byte
preflight, then hit the wrapper's OWN `artifact_too_large` failure after a wasted real dispatch —
precisely the outcome this preflight exists to prevent.)** Fixed: for `--commit` scope specifically,
the preflight ALSO measures the commit's own patch content authoritatively — re-running the SAME
`git show`/`git diff` invocation (through the SAME anchored, sanitized pattern used elsewhere) the
wrapper itself will use for `target.resolved_commit_sha` — and includes that real byte count in the
total checked against `COMPACT_BYTE_BUDGET`, exactly as `--uncommitted`/`--base` already do for
their own diff/untracked component. Only non-repo-artifact scope remains genuinely focus-text-only
for this preflight, since `CLEAN_REPO_DIR`'s guaranteed-empty diff means there is no separate
diff-content component to measure at all for that case.

**This `--commit`-scope measurement command can itself fail too — the existing collector-failure
path below covers only `collect_untracked_files.py`, never this one (new — closes a real gap found
during design review, confirmed live: `git show` on a bad/unreachable commit SHA exits 128, and the
wrapper's own `--commit` branch converts exactly this into `git_error`).** Fixed: a nonzero exit from
this `git show`/`git diff` measurement is never treated as "zero bytes" either — same principle as
the untracked-collector's own fix below — it is treated exactly like any other compaction failure
(log the narration, fall through to the normal `--resume` fallback) immediately, without ever
attempting the real dispatch that would only hit the identical `git_error` failure.

**This authoritative collector invocation can itself fail — that has an explicit failure path too
(new — closes a real gap found during design review: the real `collect_untracked_files.py` exits
nonzero — status 1 or 2 — before ever reaching its normal output loop in exactly the same
`git_error`/`incomplete_collection` cases the wrapper's own real dispatch would later hit for the
identical reason. An earlier revision only branched on the computed byte total, implicitly treating
a failed collector invocation as "zero bytes collected" — silently UNDER-counting rather than
failing, which could pass the preflight and then immediately re-hit the exact same collector failure
during the real dispatch, wasting precisely the dispatch this preflight exists to avoid).** Fixed: a
nonzero exit from this preflight's own collector invocation is never treated as "zero bytes" — it is
treated exactly like any other compaction failure (log the narration, fall through to the normal
`--resume` fallback below) immediately, without ever attempting the real dispatch that would only
fail the identical way.

**Measure the focus text EXACTLY, never estimate it (further corrected — closes a real gap found
during design review: "a conservative fixed estimate for framing overhead" is itself wrong, because
the Why/Scope/SCOPE-CONSTRAINT text is CALLER-SUPPLIED prose Claude writes fresh each time, not a
small fixed template — and for a non-repo-artifact session, the full original artifact text is ALSO
part of focus, already large by definition).** Since Claude constructs the exact, complete focus
text (digest + Why/Scope/SCOPE-CONSTRAINT + original artifact text, when applicable) before ever
dispatching it, the preflight measures its REAL byte length directly (e.g. `wc -c` on the assembled
focus content) — an exact count, not an estimate, for this entire component. The total checked
against `COMPACT_BYTE_BUDGET` is: this exact focus-text byte count, PLUS the diff/untracked-content
byte count from the authoritative collection above. If that combined, now-exact total exceeds
`COMPACT_BYTE_BUDGET = 120,000` (tighter headroom now that it covers the true total, versus the
wrapper's real 131,072-byte cap — the remaining ~11,000-byte margin absorbs the wrapper's own fixed
prompt scaffolding text outside the caller-supplied focus, which this estimate still does not
measure directly), treat this exactly like any other compaction failure — fall through to the
normal `--resume` fallback (see "On failure" above) without ever wasting a real dispatch on a
payload already known to be too large.
This still does not solve the underlying
problem (per this design's own YAGNI stance, no LLM summarization is in scope for v1) — it only
prevents a wasted network round-trip on a doomed dispatch.

**Re-run before EVERY re-collected candidate, not only the original attempt (new — closes a real gap
found during design review: the no-threadId fresh retry and thread B's own dispatch — see
"Reconciling with `references/retry-guards.md`'s OWN full escalation topology" above — each
re-collect a genuinely FRESH candidate, per the correctness fix establishing that reuse is unsafe
above; a newly re-collected candidate's own byte size can legitimately differ from the ORIGINAL
measurement — the source may have grown in the meantime — so a candidate that passed the original
preflight is not guaranteed to still pass it after a later re-collection. Without re-running this
check, an oversized later re-collection would bypass the graceful, latched `byte_budget_exceeded`
path entirely and instead hit the wrapper's OWN separate `artifact_too_large` failure at dispatch
time — a real dispatch cost this preflight exists specifically to avoid.)** Fixed: this exact-byte
preflight re-runs before EVERY fresh dispatch that re-collects a candidate — the original attempt,
the no-threadId fresh retry, and thread B's own dispatch alike, for `--uncommitted`/`--base` scope
(re-measuring the re-collected diff/untracked component fresh each time) and for `--commit` scope
(re-measuring its own patch-content component per "`--commit` scope ALSO needs a real diff-content
component here" above — though `--commit` never actually re-dispatches under a NEW candidate, since
its own single pinned `target.resolved_commit_sha` is reused for the whole session; this re-run
still applies to `--commit`'s own no-threadId/fresh-B retry ATTEMPTS, which re-measure the same
unchanged pinned commit's content each time, not a new one). Only non-repo-artifact scope has no
diff-content component to re-measure at all (per that same section above) — its own focus-text-only
preflight simply re-measures the unchanged digest-plus-framing combination each time — never trusted
from an earlier, now-stale measurement.

**A real latch, not merely an implicit "it'll fail the same way again" claim (corrected — closes a
real inconsistency found during design review: an earlier revision asserted compaction is
"effectively disabled for the remainder of that session" purely because the SAME estimate will
exceed budget every subsequent round — true for avoiding a wasted network dispatch, but this claim
glossed over the fact that nothing actually SKIPS the preflight itself, so every later triggering
round still pays the real local cost of re-collecting the diff/untracked files and re-measuring the
exact focus text, only to reach the identical doomed conclusion — the exact "repeated cost for zero
benefit" pattern `COMPACTION_BASELINE_TOKENS` and `COMPACTION_CONSECUTIVE_FRESH_FAILURES` above were
each built to close, left unclosed here for a third, equally real trigger).** Fixed: exceeding
`COMPACT_BYTE_BUDGET` sets `compaction_disabled_reason` to a third value,
`"byte_budget_exceeded"` — the SAME durable latch mechanism as the other two triggers, naming WHICH
component (claims vs. diff/artifact) drove the estimate over budget where determinable. Once set,
every later triggering round's threshold check no-ops immediately, per the existing latch contract
— skipping the local re-collection and re-measurement entirely, not merely skipping the network
dispatch — so the growth-capping goal's absence is visible (narrated once, the first time it
happens) rather than silently unmet, AND its ongoing local cost is actually eliminated, not just its
network cost. A future revision could address the root cause (e.g. capping open-claim evidence
length, or reintroducing LLM summarization) — explicitly out of scope for v1.

### Logging

The compaction round is logged like any other round, with four additions: a top-level
`compacted_from_thread` field naming the abandoned thread's id, an optional
`compaction_attempt_failed_thread`/`compaction_attempt_execution`/`compaction_attempt_coverage`
trio (see "Durable backstop for abandoned threads", "Preserving failed-attempt telemetry", and "One
shared reducer" above), and `snapshot_digest_before`/`snapshot_digest_after` fields (see "Snapshot
candidate lifecycle" above) — each present only on the round(s) they actually apply to (a round can
carry the `compaction_attempt_*` trio alone, if compaction failed and this round proceeded via the
fallback `--resume`, with none of the other three fields; or the other three together, on an actual
compaction restart round; a round now regularly carries BOTH groups together — not merely "in
principle" — in any of THREE sub-cases (corrected here to match the fuller three-case enumeration in
"Applies to a retry-then-succeed round too" above, which this Logging-section summary had drifted out
of sync with by only ever naming two): (i) an EARLIER response for the eventually-successful thread A
failed before that SAME thread went on to succeed via its own `--resume` retry (bullet 3's no-ID
hiccup, or bullet 4's ordinary threadId-bearing bounded resume — both are this same sub-case); (ii) A's
own first response failed with no threadId, and its ONE allowed no-threadId fresh retry then
succeeded — still "A," no abandoned thread, but a real earlier failed response to preserve (bullet
2); or (iii) a genuinely abandoned thread (thread A, exhausted, per "Reconciling with
`references/retry-guards.md`'s OWN full escalation topology" above) preceded thread B's own eventual
success within that SAME round. **ONLY sub-case (iii) ever populates `compaction_attempt_failed_thread`
— corrected here (closes a real, direct self-contradiction found during design review: an earlier
revision of this exact summary said "sub-cases (i) and (iii)" populate this field — but that directly
contradicts the very correction stated immediately below in this same paragraph, that a thread
succeeding via its own resume is NOT abandoned. Sub-case (i) IS exactly "a resume retry succeeding
for that same thread" — so it can NEVER populate `compaction_attempt_failed_thread` either, for the
identical reason sub-case (ii) does not.)** Neither sub-case (i) NOR sub-case (ii) ever populates
`compaction_attempt_failed_thread` — in both, the SAME thread that had an earlier failed response is
what goes on to succeed, so nothing was ever abandoned. Only sub-case (iii) populates it (a real
thread, A, was genuinely abandoned before B succeeded). **All three sub-cases MAY populate
`compaction_attempt_execution`/`compaction_attempt_coverage` — conditionally, never unconditionally
(corrected — closes a related overstatement in the same pass: "all three populate" overstates it;
`compaction_attempt_execution` is present only when the earlier failed response actually carried an
`execution` object, and `compaction_attempt_coverage` only when that earlier failed response was
itself a fresh `--uncommitted` dispatch — see immediately below).** These populate DIFFERENT fields,
never conflated (corrected — closes a real gap found during design review: an
earlier revision here said a "resume retry" succeeding populates `compaction_attempt_failed_thread`
for that SAME thread — but a thread that itself goes on to succeed via its own resume is NOT
abandoned at all, per `references/retry-guards.md`'s own explicit "that existing thread is untouched,
not abandoned" language — recording it here would cause it to be double-cleaned, or falsely reported
as leaked, despite being the round's own real, live, active thread).**
`compaction_attempt_execution` records ANY earlier failed RESPONSE's own telemetry regardless of
whose thread it belongs to, WHEN that response actually carried one (pure audit of real cost
incurred, per "Preserving failed-attempt telemetry" and "Applies to a retry-then-succeed round too"
above); `compaction_attempt_coverage`
records the SAME, but ONLY for whichever of those earlier failed responses was itself a fresh
`--uncommitted` dispatch — never for a failed `--resume` call, which never carries coverage at all
regardless of the round's overall scope (see "Scoped to a failed FRESH `--uncommitted` dispatch
specifically" below) —
`compaction_attempt_failed_thread` records ONLY a thread that was genuinely ABANDONED (its own
retries exhausted, superseded by a DIFFERENT thread), alongside `compacted_from_thread`/the
snapshot-lineage fields for the eventual success). A compaction
restart round's `target.scope` is whatever scope flag was actually used (not `"resume"`) —
consistent with how round 1 already records its own scope. `finding_id`/`claim_id` numbering
continues incrementing globally across the compaction boundary — never reset — so the existing
reducer keeps working over the whole log unmodified. **Three further additions apply to round 1 as
well, not only compaction rounds:** `target.scope_value` (see "Durably persisting the original
scope argument" above) — the literal `--base`/`--commit` argument value, omitted for
`--uncommitted` — `target.resolved_commit_sha` (see "Round 1 itself must be pinned too" above) — the
pinned SHA, `--commit` scope only, whenever resolution succeeded — and `target.original_scope_framing`
(see the dispatch step above) — the Why + task-specific Scope text captured once, before round 1's
own first dispatch attempt, excluding any pasted artifact text, never overwritten by a later retry's
own different focus. **A sixth addition,
`compaction_disabled_reason`** (see "The 'disabled for the rest of the session' decision must be
durably logged" above) — present only on the one round that ever sets this latch, never repeated on
later rounds once set. **A seventh, `retired_snapshot_files`** (see "Retired- and provisional-
snapshot durability" above) — an array, present only when non-empty, on whichever round's own line
is being written when a snapshot-file deletion failure is discovered. **An eighth,
`compaction_attempt_failure_count`** (see "This counter's own intermediate value must ALSO be
durably recorded" and "A successful compaction's own reset must be durably recorded too" above) —
present on TWO kinds of rounds: a round whose own compaction attempt fell through to step 6's
fallback (the counter's current value after incrementing), and a round whose own compaction attempt
SUCCEEDED (the explicit value `0`, representing the reset); continuity recovery reconstructs the
live `COMPACTION_CONSECUTIVE_FRESH_FAILURES` counter from whichever of the two was recorded most
recently across the session's log, by round order, defaulting to `0` only when neither has ever been
recorded. **A ninth, `candidate_snapshot_path`** (see "Recoverable without giving up `mktemp`'s own
symlink-attack protection" above) — the candidate's own `mktemp`-allocated path, present only on a
round whose own compaction attempt SUCCEEDED, alongside `snapshot_digest_after`; continuity recovery
uses it to locate and complete an interrupted post-append/pre-promotion transition (see
"PROVISIONAL_SNAPSHOT_FILE" above). **Shipping this feature requires bumping `schema_version`** —
see "Schema version bump required" above.

### Scope (v1)

- **Single-reviewer only** (`GROUP="main"`). Parallel mode is explicitly out of scope for v1 — each
  group could cross its own threshold at a different round, meaningfully increasing design/testing
  surface for a first pass. Documented as a follow-up, not silently dropped.
- **Operationally enforced, not merely stated (new — closes a real ambiguity found during design
  review): when `COMPACT_MODE` is ON, "Determine review mode" (`SKILL.md`'s Phase 1, run once before
  round 1) is forced to single-group `main`, regardless of what the normal file-count sizing
  heuristic would otherwise select.** This is a hard override, not a rejection of the `--compact`
  request — a review that would otherwise size as parallel still runs, just without parallel mode,
  for the whole session, whenever `--compact` was given. Removing this restriction (making
  compaction parallel-aware) is future work, not a v1 goal.
- **`MAX_ROUNDS` unaffected in meaning** — a compaction round consumes one increment of the round
  counter like any other round; no separate cap or exemption.

### Cost tradeoff, stated plainly

A compaction restart costs roughly as much as an ordinary round-1 dispatch (diff re-collection +
full framing), and Codex must re-establish its own understanding of the current code via its
read-only shell access rather than relying on a rich internal reasoning trail it no longer has —
this is a real, one-time cost per compaction event, not free. The tradeoff being made is: pay that
bounded, one-time cost periodically, in exchange for capping the otherwise-unbounded linear growth
observed above. This is disclosed as a deliberate exchange, not a pure win.

## Explicitly out of scope for v1

- Parallel mode (see above).
- User-configurable threshold (fixed constant for now).
- Any LLM-authored (as opposed to deterministic, JSONL-derived) summarization of closed claims.
- A true byte-bound on open-claim content (each kept fully unabridged) or on closed-claim
  marker-reason length (only count-bounded, at 20) — a session whose claim payload, or whose
  re-collected diff/artifact, exceeds `COMPACT_BYTE_BUDGET` has compaction effectively disabled for
  the rest of that session (see "Closed-claim section has its own ceiling" above); addressing this
  would need either bounding evidence/reason length or LLM summarization, both deferred.
- Recovering from an intrinsically-large review whose freshly-compacted baseline is itself over
  threshold (see "Guard against a repeated, benefit-free restart loop" above) — compaction is simply
  disabled for the rest of that session once this is detected; no attempt is made to shrink the
  underlying content itself (again, deferred to a possible future LLM-summarization revision).
- True crash-safety for a candidate snapshot file (and, on the success sub-case, the newly-created
  Codex thread alongside it) in the narrow pre-append window between its own creation and this
  round's own JSONL append (see "Retired- and provisional-snapshot durability" above) — corrected
  here to match that section (an earlier revision of this same disclosure understated the impact as
  "at most one small temp file"): an interruption in exactly that window can leave one orphaned
  candidate file, and on the success sub-case one orphaned thread, with no durably-recorded path to
  retry cleanup for either; not addressed further in v1.

# Opt-in thread compaction (`--compact`) — reference

> Read this file in full because Phase 0 Step 0 determined `--compact` is ON for this session.
> A session where `--compact` is OFF (the default) never triggers anything in this file — zero
> added behavior, zero added JSONL fields, exactly the existing resumable-thread behavior
> documented everywhere else in this skill.

## What this fixes

`run-ccs-review.sh` keeps one resumable Codex thread per reviewer alive for a whole `/ccs` run,
`--resume`ing it every round after the first rather than re-sending the diff. This avoids
re-ingestion cost per round, but nothing prunes the thread's own accumulated history — every
round's own `execution.usage.input_tokens` grows monotonically, round after round, for the life
of the thread. Real measured data from the longest `/ccs` run observed to date (17 rounds to
CLEAN) showed growth from ~520,000 tokens at round 1 to over 60,000,000 by round 17 — front-loaded
(round 1→10 is ~60x), with elapsed wall time NOT tracking token count monotonically (cache hit
rate, not raw size, appears to dominate latency once a thread is this large). The concrete,
structural problem this feature solves is **unbounded token growth with no pruning mechanism**,
not latency specifically.

**What was ruled out, and why:** `codex exec fork` (inherits the parent thread's ENTIRE history —
already measured at 2.14x the tokens of independent dispatch for a different cost problem, see
`docs/2026-09-05-codex-stream-review-improvement-roadmap-design.md`'s "Phase 4 Item 1 canary
results" — carries the same bloat forward, so it cannot serve a compaction goal either); asking
the same resumed thread to "forget" via plain `--focus` text (no Codex CLI primitive shrinks a
thread's own stored server-side context — confirmed against `codex exec`/`codex exec resume`/
`codex queue`/`codex resume`); Codex's own native automatic compaction (real `"type":"compacted"`
events exist in local session rollout logs, but did NOT fire even once during the real 17-round
run measured above, despite that thread growing far larger than a session where it fired 12
times — not something `/ccs` can rely on or control either way).

## The `--compact` flag

A fourth independent, optional `/ccs` prefix flag, alongside `--capture-evidence`,
`--keep-evidence`, and `--quick` — parsed by the SAME Phase 0 Step 0 prefix-stripping loop in
`SKILL.md`, its own independent boolean (`COMPACT_MODE`); any subset of the four may be ON in any
order (see `SKILL.md`'s Phase 0 Step 0 for the exact updated parsing rule — Task 20 of this plan
amends it to include `--compact`). **No changes to `run-ccs-review.sh` itself are required** —
compaction is entirely a `SKILL.md`/reference-file-level orchestration technique built from
primitives the wrapper already exposes (a fresh dispatch, a `--cleanup` call) — the same
relationship `--quick`/`--keep-evidence` already have to the wrapper.

Starting as opt-in (not always-on, unlike snapshot integrity/the claim ledger) is deliberate:
this is a genuinely new failure surface (see "Restart mechanism" and "Digest construction" below)
that has not yet been validated against real reviews the way the always-on mechanisms have.

## Trigger

**Round-ownership terminology.** Call the round whose completed usage triggers this check the
TRIGGERING round. Compaction, when triggered, is attempted for the VERY NEXT round dispatched
afterward — call it the COMPACTION round. Every later use of "round R" in this file's "Restart
mechanism" section, and everywhere else in this file discussing the compaction attempt itself,
means the COMPACTION round — never the triggering round the decision was based on. The triggering
round was already processed and logged normally, before this check ever runs; nothing about it is
retroactively changed.

**When this check runs.** After EVERY completed round — including round 1 itself: round 1's OWN
resulting thread is already a real, resumable thread the moment round 1 completes, and its usage
is already known then, so restricting the check to round 2+ would force at least one wasted
`--resume` turn against an already-oversized round-1 thread whenever round 1 alone exceeds the
threshold. If `COMPACT_MODE` is ON: check that just-completed round's own
`execution.usage.input_tokens` against `COMPACT_THRESHOLD = 8,000,000` (a fixed constant, not
user-configurable in v1 — see "Scope (v1)" below). If exceeded, compact before building the next
round's dispatch — if round 1 itself triggers this, round 2 becomes the COMPACTION round
immediately (running the existing mandatory round-2+ active-snapshot revalidation first, per
"Restart mechanism" step 0 below, then the fresh compaction path), never a wasted ordinary
`--resume` first.

**Handling missing OR malformed usage data.** `execution.usage.input_tokens` is documented as
best-effort and may be entirely absent even on a genuinely successful round (see
`references/execution-telemetry.md`). If the most recently completed round's response has no
`execution.usage.input_tokens` to check: skip the threshold check for this round (never treat
missing data as "under threshold," which would make an opt-in `--compact` session silently never
compact at all, and never as "over threshold" either) — log one narration line noting the check
was skipped, and re-attempt the check normally at the next round where usage data is available.
A PRESENT value must also be validated before comparison, never trusted as-is: `input_tokens`,
when present, must additionally be validated as a non-negative integer before ever being compared
to `COMPACT_THRESHOLD` — a string, `null`, a negative number, or any other non-integer shape is
treated exactly like the ABSENT case (skip, narrate, re-attempt next round). This matters because
`jq`'s own type-ordering ranks any string above any number, so a raw comparison against a
malformed value like `"not-a-number"` would otherwise spuriously compare GREATER than
8,000,000 and trigger an unnecessary, expensive fresh restart.

**Benefit-free-restart-loop guard (the `COMPACTION_BASELINE_TOKENS` circuit breaker).** A
successful COMPACTION round is, itself, just another completed round — its own usage gets
checked by this same trigger. If the underlying diff/claims content is simply large enough that
even a FRESH restart's own single-turn usage is already at or above `COMPACT_THRESHOLD` — not
because of accumulated resumed-thread history, but because the content itself is that big — then
the very next round would trigger compaction again, and again, every round, each one paying the
full fresh-restart cost with ZERO benefit. Fixed: record `COMPACTION_BASELINE_TOKENS` — the
COMPACTION round's OWN, freshly-restarted `execution.usage.input_tokens` (never the TRIGGERING
round's own usage — the triggering round's usage is, by definition, already `>=
COMPACT_THRESHOLD`, since that is what triggered it; recording that value as the baseline would
make the check below true unconditionally, disabling compaction after every single first
successful restart) — every time a compaction round's OWN dispatch succeeds.

If THAT (the compaction round's own, freshly-restarted) baseline is itself already `>=
COMPACT_THRESHOLD`, compaction is disabled for the remainder of the session (narrated once,
clearly, the same way the byte-budget exhaustion limitation is — see "Byte-budget preflight"
below) — record `compaction_disabled_reason: "baseline_at_or_above_threshold"` on that same
round's own JSONL line (see "Logging" below for the full durability rule). If the fresh baseline
IS comfortably under threshold (the common, intended case), ordinary accumulation-based
triggering simply resumes for future rounds exactly as designed, no special-casing needed.

**Fail closed when the compaction round's OWN telemetry is unusable — never assume the restart
helped.** If the compaction round's own `input_tokens` is unusable (per the missing/malformed
rule above), `COMPACTION_BASELINE_TOKENS` is NOT left unset — it is treated IDENTICALLY to a
baseline that IS `>= COMPACT_THRESHOLD`: record `compaction_disabled_reason: "baseline_unusable"`
and disable compaction for the remainder of the session. An unverifiable baseline is treated as a
failed one, not a free pass.

**A second circuit breaker for repeated FAILED fresh-dispatch attempts.** The baseline guard
above only ever engages after a compaction dispatch SUCCEEDS. Every `ok:false` compaction
attempt — including `timeout` (a real possibility for a genuinely large diff, given the
wrapper's own default fresh-dispatch deadline of 1800 seconds) and `nonzero_exit` — instead falls
through to the normal fallback `--resume` (see "On failure" below), with the threshold check
simply running again next round. A diff large/slow enough to reliably time out the fresh dispatch
would otherwise trigger another identical, doomed fresh attempt every single subsequent round.

Fixed: a second session-scoped counter, `COMPACTION_CONSECUTIVE_FRESH_FAILURES`, increments by
one every time a compaction attempt's own fresh dispatch (after exhausting whatever bounded retry
the retry topology below already applies to that one round's own attempt) still ends up
`ok:false` and falls through to the fallback — and resets to `0` every time a compaction attempt
succeeds. This counter must ALSO increment on a purely LOCAL pre-dispatch failure, not only a
wrapper `ok:false` — a persistent local problem (the candidate's own `git diff`/`shasum`
collection failing, or the byte preflight's own authoritative untracked-file collector invocation
failing) falls straight through to the fallback WITHOUT ever reaching a real wrapper dispatch at
all, so this counter is broadened to increment on ANY compaction attempt that falls through to
the fallback without completing a real successful compaction — local collection/hash failure,
local preflight-collector failure, OR a wrapper `ok:false` alike — the one exception being
`byte_budget_exceeded`, which gets its own dedicated, immediate latch (see "Byte-budget
preflight" below) precisely because a successful measurement over budget is a distinct,
already-fully-diagnosed cause that doesn't need this counter's slower two-strikes bound.

Once this counter reaches `COMPACTION_MAX_CONSECUTIVE_FRESH_FAILURES = 2`, compaction is disabled
for the remainder of the session — via the same `compaction_disabled_reason` mechanism below,
with the value `"repeated_fresh_dispatch_failure"` — a small, deliberately conservative bound
consistent with this design's other fixed, non-configurable limits (`COMPACT_THRESHOLD`,
`CLOSED_CLAIM_LIMIT`, `COMPACT_BYTE_BUDGET`).

**Durable recording — the counter's own intermediate value, not only the final "disabled"
decision.** Every round whose own compaction attempt fails (falls through to the fallback)
durably records the counter's CURRENT value (after incrementing) as a new field,
`compaction_attempt_failure_count`, on that round's own line — this is a pre-append-decided
value, exactly like `compaction_attempt_failed_thread` (see "Retry topology" and "Ordering on
success" below), since the failure is known before that round's own real (fallback) result is
ever logged. Without this, a session recovering from a lost in-memory state after exactly ONE
fresh-dispatch failure — not yet two — would reconstruct the counter as `0`, silently doubling
the effective failure budget across that recovery event.

**A successful compaction's own reset must be durably recorded too.** A successful compaction
round (the same round already appending `compacted_from_thread` and the `snapshot_digest_*` pair
— see "Restart mechanism" below) ALSO durably records `compaction_attempt_failure_count: 0` on
that SAME line, explicitly representing the reset rather than leaving it implicit. Without this,
a state-loss recovery reading only the latest recorded value across the log could find an OLDER
nonzero count from before a since-succeeded reset and restore it as if no reset had ever
happened — the very next fresh-dispatch failure after that recovery would then reach `2` and
wrongly disable compaction, even though it is really only the first consecutive failure since the
last success. Continuity recovery reconstructs `COMPACTION_CONSECUTIVE_FRESH_FAILURES` from
whichever of these two fields — a failure's incremented value or a success's explicit `0` — was
recorded MOST RECENTLY across the whole session log (by round order, not by which field name it
is), defaulting to `0` only when neither has ever been recorded at all.

**The "disabled for the rest of the session" decision must be durably logged and recoverable —
never in-memory-only.** The compaction round that sets this latch (because its own baseline was
`>= COMPACT_THRESHOLD`, its own telemetry was unusable, `COMPACTION_CONSECUTIVE_FRESH_FAILURES`
reached its bound, OR the byte preflight below found the exact assembled payload over
`COMPACT_BYTE_BUDGET`) durably records a new field, `compaction_disabled_reason` (a short
string — exactly one of `"baseline_at_or_above_threshold"`, `"baseline_unusable"`,
`"repeated_fresh_dispatch_failure"`, or `"byte_budget_exceeded"`), on that SAME round's own JSONL
line — never a separate append. `SKILL.md`'s continuity recovery (see "Review history log" →
"Read (continuity)") is extended, alongside its existing reconstruction of
`GROUP_THREADS`/`LEAKED_THREAD_IDS`/claim state, to also check whether ANY prior round in the
session's log ever recorded this field — if so, compaction is reconstructed as disabled for the
rest of the session, exactly matching whatever the original in-memory decision would have been,
never silently forgotten and re-enabled.

## Scope (v1)

- **Single-reviewer only (`GROUP="main"`).** Parallel mode is explicitly out of scope for v1 —
  each group could cross its own threshold at a different round, meaningfully increasing
  design/testing surface for a first pass. **Operationally enforced, not merely stated:** when
  `COMPACT_MODE` is ON, `SKILL.md`'s Phase 1 "Determine review mode" (run once before round 1) is
  forced to single-group `main`, regardless of what the normal file-count sizing heuristic would
  otherwise select — a hard override, not a rejection of the `--compact` request (see Task 20 for
  the exact `SKILL.md` edit). Removing this restriction is future work, not a v1 goal.
- **`MAX_ROUNDS` unaffected in meaning** — a compaction round consumes one increment of the round
  counter like any other round; no separate cap or exemption.

## Cost tradeoff, stated plainly

A compaction restart costs roughly as much as an ordinary round-1 dispatch (diff re-collection +
full framing), and Codex must re-establish its own understanding of the current code via its
read-only shell access rather than relying on a rich internal reasoning trail it no longer has —
this is a real, one-time cost per compaction event, not free. The tradeoff being made is: pay
that bounded, one-time cost periodically, in exchange for capping the otherwise-unbounded linear
growth described above. This is disclosed as a deliberate exchange, not a pure win.

## Explicitly out of scope for v1

- Parallel mode (see "Scope (v1)" above).
- User-configurable threshold (fixed constant, `COMPACT_THRESHOLD = 8,000,000`, for now).
- Any LLM-authored (as opposed to deterministic, JSONL-derived) summarization of closed claims.
- A true byte-bound on open-claim content (each kept fully unabridged) or on closed-claim
  marker-reason length (only count-bounded, at `CLOSED_CLAIM_LIMIT = 20`) — a session whose claim
  payload, or whose re-collected diff/artifact, exceeds `COMPACT_BYTE_BUDGET` has compaction
  effectively disabled for the rest of that session (see "Byte-budget preflight" below);
  addressing this would need either bounding evidence/reason length or LLM summarization, both
  deferred.
- Recovering from an intrinsically-large review whose freshly-compacted baseline is itself over
  threshold — compaction is simply disabled for the rest of that session once this is detected
  (see "Benefit-free-restart-loop guard" below); no attempt is made to shrink the underlying
  content itself.
- True crash-safety for a candidate snapshot file (and, on the success sub-case, the newly-created
  Codex thread alongside it) in the narrow pre-append window between its own creation and that
  round's own JSONL append (see "Retired- and provisional-snapshot durability" below): an
  interruption in exactly that window can leave one orphaned candidate file, and on the success
  sub-case one orphaned thread, with no durably-recorded path to retry cleanup for either; not
  addressed further in v1.

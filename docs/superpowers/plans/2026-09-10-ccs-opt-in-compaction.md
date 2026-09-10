# `codex-stream-review:ccs` Opt-In Thread Compaction (`--compact`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fourth, independent, opt-in `/ccs` prefix flag, `--compact`, that caps a
long-running resumable-Codex-thread review's otherwise-unbounded per-round token growth by
abandoning the old thread and starting a fresh one — seeded with a compact digest of the claim
ledger instead of the old thread's full accumulated history — whenever a round's own token usage
crosses a fixed threshold.

**Architecture:** This is a `SKILL.md`-level orchestration technique built entirely from wrapper
primitives that already exist (a fresh `run-ccs-review.sh` dispatch, its `--cleanup` mode) — **no
changes to `scripts/run-ccs-review.sh` itself**. The bulk of the new mechanics (trigger, digest
construction, restart mechanism, retry topology, logging) live in a new reference file,
`codex-stream-review/skills/ccs/references/compaction.md`, read only when `--compact` is ON —
matching the existing pattern of `capture-evidence.md`/`keep-evidence.md` (opt-in reference files
with a thin pointer from `SKILL.md`). Three existing reference files each need a small, narrowly
scoped companion amendment carving out a `--compact`-only exception to an invariant they currently
state unconditionally: `references/snapshot-integrity.md` ("one canonical subject, never changed
per round"), `references/execution-telemetry.md` ("purely additive, never load-bearing"), and
`references/retry-guards.md` (`artifact_too_large`/exhausted-retry terminal-outcome rules, and the
round-1-only scoping of the no-threadId-fresh-retry/fresh-B escalation). `SKILL.md` itself gains:
the fourth flag in Phase 0 Step 0's parsing loop, a new "read in full" entry, a forced
single-group-`main` override in "Determine review mode", the trigger-check integration point
between Phase 2's per-round JSONL append and Phase 1 Step 1's next dispatch, a `schema_version`
bump, new JSONL field documentation, and new Final Report content.

**Tech Stack:** Markdown (skill/reference authoring), Bash (`run-ccs-review.sh`'s existing
interface, eval scenario `setup.sh`/`expect.sh` scripts), `jq` (JSONL construction/reduction),
this project's existing `tests/fixtures/fake-codex` fixture (env-var-driven fake `codex` CLI) for
eval scenarios.

**Spec:** `/Users/hmc7279235/Work/Develop/plugins/docs/2026-09-09-ccs-opt-in-compaction-design.md`
(the approved, 54-round-adversarially-reviewed design — this plan argues from it; every task below
names the exact section(s) of that document an implementer must transcribe/adapt from, verbatim,
never paraphrased or summarized. **Read the cited section(s) directly from that file before writing
the corresponding reference-file content — this plan gives you the constants, field names, and
structure to get right, but the design doc's own prose is the actual copy source.**)

## Global Constraints

- `COMPACT_THRESHOLD = 8,000,000` (fixed, not user-configurable in v1) — checked against a round's
  own `execution.usage.input_tokens`.
- `COMPACTION_MAX_CONSECUTIVE_FRESH_FAILURES = 2` (session-scoped counter
  `COMPACTION_CONSECUTIVE_FRESH_FAILURES`, resets to `0` on any compaction success).
- `CLOSED_CLAIM_LIMIT = 20` most-recently-closed claims kept verbatim in the digest; older ones
  collapse to one summary line.
- `COMPACT_BYTE_BUDGET = 120,000` (the compaction-restart preflight's own budget — tighter than the
  wrapper's real `PROMPT_SIZE_LIMIT_BYTES = 131072`, which is never changed).
- **No changes to `scripts/run-ccs-review.sh`, `scripts/lib/git-safe.sh`, or any other script are
  in scope** — every mechanic is built from the wrapper's existing fresh-dispatch/`--resume`/
  `--cleanup` primitives, orchestrated entirely from `SKILL.md`/`references/*.md`.
- `--compact` forces single-group `main` for the WHOLE session the moment it is ON — parallel mode
  is explicitly out of scope for v1 (see design doc "Scope (v1)").
- `MAX_ROUNDS` is unaffected in meaning — a compaction round consumes one ordinary round-counter
  increment, no separate cap or exemption.
- Every new durable JSONL field name, every new `compaction_disabled_reason` string value
  (`"baseline_at_or_above_threshold"`, `"baseline_unusable"`, `"repeated_fresh_dispatch_failure"`,
  `"byte_budget_exceeded"`), and every constant above must appear byte-for-byte identically
  everywhere it is referenced across `SKILL.md` and every `references/*.md` file touched — Task 23
  (self-consistency pass) greps for exactly this.
- Shipping this feature requires bumping the session JSONL `schema_version` marker (see
  `references/claim-ledger.md` section 10) from its current value (`2`, per `SKILL.md`'s own
  worked JSONL example) to `3` — every place that value is illustrated must be updated together.
- Follow every existing per-file convention exactly: the sentinel-file safe-read idiom for any
  value Claude does not fully control character-by-character (`SKILL.md`'s own "Sentinel-file
  safe-read idiom" section), the `env -i`/`-c core.fsmonitor=`/sanitization-loop pattern for every
  direct git invocation outside the wrapper, and `mktemp`-based allocation (never a predictable
  path) for any new temp file.

---

## Task Index

1. Create `references/compaction.md` skeleton + "What this fixes" / opt-in flag / Scope (v1) / Cost tradeoff / Out-of-scope sections
2. `references/compaction.md` — Trigger mechanics: threshold check, round-ownership terminology, benefit-free-restart-loop guard (baseline), fail-closed telemetry handling
3. `references/compaction.md` — Trigger mechanics continued: consecutive-fresh-failure circuit breaker, durable latch recording (`compaction_disabled_reason`, `compaction_attempt_failure_count`)
4. `references/compaction.md` — Digest construction: claim preservation rules (open verbatim/most-recent, closed one-line + `CLOSED_CLAIM_LIMIT`), structured-data-first verification
5. `references/compaction.md` — Restart mechanism step 0: mandatory pre-existing snapshot revalidation ordering, recovery-vs-ordinary-check sequencing
6. `references/compaction.md` — Restart mechanism step 1-2: digest-verification abort path, non-repo-artifact special case (CLEAN_REPO_DIR 8-check cleanliness, bound copy-verify-embed)
7. `references/compaction.md` — Restart mechanism step 3: `--uncommitted`/`--base` candidate snapshot lifecycle (allocation, ownership, disclosed collect-then-dispatch gap)
8. `references/compaction.md` — Restart mechanism step 3 continued: `--commit` scope SHA-pinning (round 1 and compaction alike), `target.scope_value`/`target.resolved_commit_sha` durable fields
9. `references/compaction.md` — Restart mechanism step 3 continued: atomic promotion (single `mv`, retry-then-hard-stop), `SNAPSHOT_DIGEST` advancement, retired/provisional-snapshot durability
10. `references/compaction.md` — Restart mechanism step 4: fresh dispatch focus-text construction (`target.original_scope_framing`, coverage epoch, `DISPOSITION` request block)
11. `references/compaction.md` — Retry topology: candidate A's four-bullet decision tree (reusing `retry-guards.md`, never `GROUP_THREADS`-keyed)
12. `references/compaction.md` — Retry topology continued: thread B's single-shot dispatch, coverage/baseline/telemetry carry-forward rules
13. `references/compaction.md` — Ordering on success: provisional tracking before append, append-verify extension (branch-aware required-field table)
14. `references/compaction.md` — On failure (step 6): self-contained fallback, one-JSONL-object-per-round contract, preserved telemetry/coverage audit fields
15. `references/compaction.md` — Failure isolation from the round loop, interaction with `--keep-evidence`, durable backstop for abandoned threads
16. `references/compaction.md` — Logging section: full field-by-field summary + Final Report content (preserved-telemetry reporting templates)
17. Amend `references/snapshot-integrity.md` — companion exception for the compaction re-snapshot event
18. Amend `references/execution-telemetry.md` — companion exception making telemetry load-bearing under `--compact`
19. Amend `references/retry-guards.md` — companion exception for failure-isolation substitution + candidate-A-only round-1 scoping
20. Amend `SKILL.md` — Phase 0 Step 0 flag parsing, Scope section, "Reference files ... read in full" entry, Phase 1 "Determine review mode" single-group override
21. Amend `SKILL.md` — Phase 2 trigger-check integration point, Review history log section (`schema_version` bump, new field list), Final Report bullet
22. Self-consistency pass (grep-based field/constant/name audit across every file touched)
23. Eval scenario: `compact-trigger-uncommitted-success` (basic threshold trigger + successful `--uncommitted` restart)
24. Eval scenario: `compact-baseline-still-over-threshold` (benefit-free-restart-loop guard latches `compaction_disabled_reason`)
25. Eval scenario: `compact-byte-budget-exceeded` (preflight latches before any dispatch)
26. Eval scenario: `compact-fresh-b-escalation` (candidate A exhausted, thread B succeeds, old thread + A both leaked/cleaned)
27. Eval scenario: `compact-clean-repo-dir-polluted` (non-repo-artifact `CLEAN_REPO_DIR` cleanliness recheck fails closed)

---

### Task 1: Create `references/compaction.md` skeleton + framing sections

**Files:**
- Create: `codex-stream-review/skills/ccs/references/compaction.md`

**Interfaces:**
- Consumes: nothing yet — this task only lays down the file's framing sections. Later tasks append
  the mechanics sections in order.
- Produces: the file itself, and its top-of-file "read this because" banner convention that every
  other reference file in this skill already uses (see `references/retry-guards.md`'s opening
  blockquote for the pattern) — later tasks assume this file exists and append to its end.

- [ ] **Step 1: Read the design doc's framing sections**

  Open `/Users/hmc7279235/Work/Develop/plugins/docs/2026-09-09-ccs-opt-in-compaction-design.md` and
  read, in full: the `## Problem` section (lines ~1-55, including the real measured-data table),
  the `### Opt-in flag: --compact` section, the `### Scope (v1)` section, the `### Cost tradeoff,
  stated plainly` section, and the final `## Explicitly out of scope for v1` section.

- [ ] **Step 2: Write the file's opening banner and "What this fixes" section**

  Create `codex-stream-review/skills/ccs/references/compaction.md` with this exact opening
  (matching the existing opt-in-reference-file convention from `references/capture-evidence.md`'s
  own opening blockquote style):

  ```markdown
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
  ```

- [ ] **Step 3: Write the `### Opt-in flag: --compact` section**

  Append directly after the section from Step 2:

  ```markdown
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
  ```

- [ ] **Step 4: Write the `## Scope (v1)` section**

  Append:

  ```markdown
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
  ```

- [ ] **Step 5: Write the `## Cost tradeoff, stated plainly` section**

  Append:

  ```markdown
  ## Cost tradeoff, stated plainly

  A compaction restart costs roughly as much as an ordinary round-1 dispatch (diff re-collection +
  full framing), and Codex must re-establish its own understanding of the current code via its
  read-only shell access rather than relying on a rich internal reasoning trail it no longer has —
  this is a real, one-time cost per compaction event, not free. The tradeoff being made is: pay
  that bounded, one-time cost periodically, in exchange for capping the otherwise-unbounded linear
  growth described above. This is disclosed as a deliberate exchange, not a pure win.
  ```

- [ ] **Step 6: Write the `## Explicitly out of scope for v1` section**

  Append verbatim (this is the design doc's own closing section — transcribe it exactly, it is
  short and fully specified):

  ```markdown
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
  ```

- [ ] **Step 7: Verify the file parses as valid Markdown and has no dangling references**

  Run:
  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  wc -l codex-stream-review/skills/ccs/references/compaction.md
  grep -n "^## \|^### " codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: the file exists, non-empty, and the heading list shows exactly `# Opt-in thread
  compaction...`, `## What this fixes`, `## The --compact flag`, `## Scope (v1)`, `## Cost
  tradeoff, stated plainly`, `## Explicitly out of scope for v1` in that order — later tasks insert
  the mechanics sections BETWEEN "The `--compact` flag" and "Scope (v1)" (Tasks 2-16 each specify
  exactly where their section is inserted).

- [ ] **Step 8: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): scaffold compaction.md reference file with framing sections"
  ```

### Task 2: Trigger mechanics — threshold check, round-ownership terms, benefit-free-restart-loop baseline guard

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (insert a new `## Trigger`
  section between `## The --compact flag` and `## Scope (v1)`)

**Interfaces:**
- Consumes: `COMPACT_MODE` (Task 20's Phase 0 Step 0 boolean), a round's own
  `execution.usage.input_tokens` (already reported by `run-ccs-review.sh`, per
  `references/execution-telemetry.md` — no new telemetry).
- Produces: `COMPACT_THRESHOLD` (8,000,000, fixed), `COMPACTION_BASELINE_TOKENS` (session-scoped
  literal fact), the TRIGGERING-round/COMPACTION-round terminology used by every later section of
  this file, and `compaction_disabled_reason = "baseline_at_or_above_threshold"` /
  `"baseline_unusable"` (two of the four legal latch values — the other two,
  `"repeated_fresh_dispatch_failure"` and `"byte_budget_exceeded"`, are Task 3's).

- [ ] **Step 1: Read the design doc's trigger section**

  Read, in full, the design doc's `### Trigger` section — from "After EVERY completed round" down
  through "**Round-ownership terminology, made explicit**" (this spans the threshold check itself,
  the "Guard against a repeated, benefit-free restart loop" block establishing
  `COMPACTION_BASELINE_TOKENS`, and the round-ownership terminology block). Do NOT yet read past
  "Round-ownership terminology" — the consecutive-fresh-failure circuit breaker and its durability
  fixes are Task 3.

- [ ] **Step 2: Write the round-ownership terminology paragraph first**

  Insert, as the FIRST paragraph of the new `## Trigger` section (placing this first, ahead of the
  mechanics, avoids ever having to say "round R" ambiguously below it):

  ```markdown
  ## Trigger

  **Round-ownership terminology.** Call the round whose completed usage triggers this check the
  TRIGGERING round. Compaction, when triggered, is attempted for the VERY NEXT round dispatched
  afterward — call it the COMPACTION round. Every later use of "round R" in this file's "Restart
  mechanism" section, and everywhere else in this file discussing the compaction attempt itself,
  means the COMPACTION round — never the triggering round the decision was based on. The triggering
  round was already processed and logged normally, before this check ever runs; nothing about it is
  retroactively changed.
  ```

- [ ] **Step 3: Write the threshold-check paragraph**

  Append directly after Step 2's paragraph:

  ```markdown
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
  ```

- [ ] **Step 4: Write the benefit-free-restart-loop baseline guard**

  Append directly after Step 3's paragraphs:

  ```markdown
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
  ```

- [ ] **Step 5: Verify heading order and that no forward reference is left dangling this task**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "^## \|^### " codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: `## Trigger` now appears immediately after `## The --compact flag` and before
  `## Scope (v1)`. The two forward references this task's text makes ("Byte-budget preflight
  below", "Logging below") are resolved by Task 3 and Task 16 respectively — leave them as plain
  prose section-name references (no markdown link needed, matching this file's own convention of
  bare `"see ... below"` phrases throughout `SKILL.md` and every other `references/*.md` file).

- [ ] **Step 6: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md trigger mechanics (threshold check + baseline guard)"
  ```

### Task 3: Trigger mechanics — consecutive-fresh-failure circuit breaker + durable latch recording

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (append to the end of the
  `## Trigger` section created in Task 2, still before `## Scope (v1)`)

**Interfaces:**
- Consumes: whether a compaction attempt's own fresh dispatch (after exhausting Task 11/12's
  bounded retry) ends up `ok:false` and falls through to the fallback (Task 14's step 6).
- Produces: `COMPACTION_CONSECUTIVE_FRESH_FAILURES` (session-scoped counter),
  `COMPACTION_MAX_CONSECUTIVE_FRESH_FAILURES = 2`, `compaction_attempt_failure_count` (durable
  per-round field), `compaction_disabled_reason = "repeated_fresh_dispatch_failure"` (the third of
  the four legal latch values), and the general "disabled-latch is durably recoverable" rule every
  later section of this file (and `SKILL.md`'s continuity recovery, Task 21) depends on.

- [ ] **Step 1: Read the design doc's remaining trigger-section fixes**

  Read, in full, from "**A SEPARATE circuit breaker is also needed for repeated FAILED
  fresh-dispatch attempts**" through the end of the `### Trigger` section (ending at, but not
  including, `### What gets preserved`). This covers: the second circuit breaker itself; the
  "must ALSO increment on a purely LOCAL pre-dispatch failure" broadening fix; the
  "counter's own intermediate value must ALSO be durably recorded" fix; the "successful
  compaction's own reset must be durably recorded too" fix; and the "disabled for the rest of the
  session decision must be durably logged and recoverable" fix.

- [ ] **Step 2: Write the circuit-breaker counter mechanics**

  Append to the end of the `## Trigger` section:

  ```markdown
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
  ```

- [ ] **Step 3: Write the durable-recording rules for the counter and the reset**

  Append directly after Step 2:

  ```markdown
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
  ```

- [ ] **Step 4: Verify the four `compaction_disabled_reason` values are each introduced exactly once with matching spelling**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -no '"baseline_at_or_above_threshold"\|"baseline_unusable"\|"repeated_fresh_dispatch_failure"\|"byte_budget_exceeded"' codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: all four strings present (byte_budget_exceeded is introduced by name here but its own
  full mechanics are Task 5's "Byte-budget preflight" section — confirm it is not yet defined
  there, only forward-referenced by name, which Task 5 must match exactly).

- [ ] **Step 5: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md consecutive-failure circuit breaker + durable latch recording"
  ```

### Task 4: Digest construction — claim preservation, structured-data-first verification, closed-claim ceiling, byte-budget preflight

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (insert a new `## What gets
  preserved` section between `## Trigger` (Task 2-3) and `## Scope (v1)`)

**Interfaces:**
- Consumes: `references/claim-ledger.md` section 8's reducer (already existing, unmodified),
  `references/claim-ledger.md` section 1's most-recent-occurrence lookup convention.
- Produces: `COMPACT_DIGEST` (the structured-then-rendered focus-text component Task 10's dispatch
  step embeds), `CLOSED_CLAIM_LIMIT = 20`, `COMPACT_BYTE_BUDGET = 120,000`,
  `compaction_disabled_reason = "byte_budget_exceeded"` (the fourth and last legal latch value —
  now all four are defined across Tasks 2-4).

- [ ] **Step 1: Read the design doc's "What gets preserved" section**

  Read, in full, the design doc's `### What gets preserved — full fidelity for open claims, one
  line for closed ones` section through its `**Digest construction and verification**` subsection
  (ending just before `### Restart mechanism`).

- [ ] **Step 2: Read the design doc's closed-claim ceiling and byte-budget preflight sections**

  Read, in full, the design doc's `### Closed-claim section has its own ceiling` section (near the
  end of the document) — this covers `CLOSED_CLAIM_LIMIT`, the disclosed residual limitation, the
  authoritative-collector-based byte measurement fix, the `--commit`-scope patch-content
  measurement fix, the exact-vs-estimate focus-text measurement fix, the re-run-before-every-
  re-collected-candidate fix, and the real latch (`byte_budget_exceeded`) fix. This section is
  physically located near the end of the design doc (after "Handling missing OR malformed usage
  data") but belongs here thematically, since it bounds the SAME digest this task constructs.

- [ ] **Step 3: Write the claim preservation rules**

  Insert, as a new section between `## Trigger` and `## Scope (v1)`:

  ```markdown
  ## What gets preserved — full fidelity for open claims, one line for closed ones

  Reuses the claim ledger's existing reducer (`references/claim-ledger.md` section 8) over the
  session's own JSONL log — no new data structure. For every claim_id that has ever appeared this
  session:
  - **Still open** (no `claim_closures[]` entry): included verbatim, using the claim's MOST RECENT
    occurrence, not necessarily its origin — `file`/`line`/`severity`/`summary`/`evidence`,
    unabridged. This mirrors how Claude Code's own context compaction keeps the most
    currently-relevant material closest to full fidelity rather than summarizing everything
    uniformly. **Disclosed limitation:** this text (including its `file`/`line`) reflects where the
    claim was most recently raised, which may now be stale if the file has changed shape since —
    not treated as an enforcement problem, since Codex is already instructed, in every round, to
    re-read the actual current file rather than trust diff/context text as-is.
  - **Resolved or retracted:** collapsed to one line, built directly and deterministically from its
    own `claim_closures[].marker_reason` (already exactly one sentence, by the existing
    `DISPOSITION` marker grammar — see `references/claim-ledger.md` section 4) — no new LLM call,
    no summarization step, zero added cost or design surface. Example: `claim_id g1:f3 — RESOLVED
    (round 5): the null check now covers the empty-array case, confirmed by re-reading the current
    file.` Bounded — see "Closed-claim section has its own ceiling" below.

  **Most-recent, not origin.** For each open claim_id, use the SAME "most recent occurrence" lookup
  the quick-mode severity check already performs (`SKILL.md`'s own Guards section) — find that
  claim_id's latest `claude_verification[]` entry, read its own `finding_id`, and use THAT
  finding's `file`/`line`/`severity`/`summary`/`evidence` (falling back to the origin finding only
  for a claim that has never been re-raised, where origin IS the most recent). Additionally append
  one line noting the most recent `evidence_delta` (when present) and Claude's own most recent
  `action`/`rationale` for it, so the fresh thread sees "here is where this stood," not just the
  opening complaint.
  ```

- [ ] **Step 4: Write the digest-construction-and-verification subsection**

  Append directly after Step 3:

  ```markdown
  ## Digest construction and verification — structured data first, prose rendering last

  **Never re-parse the rendered prose.** Building the digest as prose directly, then re-parsing
  that same prose to verify nothing was dropped, is unsound: a claim's own verbatim `evidence` text
  can legitimately contain a quoted example, a code block, or prose that itself contains a
  column-zero-anchored string shaped exactly like another claim's `DISPOSITION` marker — the exact
  class of ambiguity the existing marker parser avoids via fencing/cardinality rules that this
  simpler use case does not need to reinvent. Instead:

  1. Compute the reducer's own open-claim-id list (`references/claim-ledger.md` section 8) as
     structured data (e.g. a `jq` array), not prose.
  2. For each element of that array, resolve its `{claim_id, file, line, severity, summary,
     evidence}` fields (via the same most-recent-occurrence lookup above) — do NOT render
     `block_text` yet.
  3. **Verification is a structural check on this data, BEFORE any prose is ever rendered** — both
     a KEY check and a CONTENT-COMPLETENESS check:
     - **Key check:** the number of resolved objects equals the reducer's own open count, and their
       `claim_id` keys are exactly the reducer's own open-id set (set equality).
     - **Content-completeness check — TYPE/PRESENCE, not non-emptiness:** every one of those
       objects has `summary`, `evidence`, and `file` present as strings (per
       `schemas/review-verdict.schema.json`'s own field types) — an empty string IS a legal value
       for these three and is NOT rejected here. `severity` must be one of the schema's own legal
       values (`"low"`/`"medium"`/`"high"`/`null`). `line` must ALSO be checked — present, and
       either `null` or an integer `>= 1`, matching `schemas/review-verdict.schema.json`'s own exact
       constraint on that field.
     - Neither check can be spoofed by anything a rendering step might later produce, because
       neither ever inspects rendered prose — both read only the resolved fields, sourced directly
       from the finding record the reducer already resolved.
  4. **Only once step 3 passes (both checks) is `block_text` computed** — as a pure, canonical
     function of the ALREADY-VALIDATED fields from step 2, in the same step, never a separately/
     independently rendered value: a fixed template, `"OPEN CLAIM <claim_id>:\nfile:
     <file>\nline: <line>\nseverity: <severity>\nsummary: <summary>\nevidence: <evidence>"`. The
     final flattening (one deterministic concatenation, a 1:1 map with nothing filtered) produces
     the prose sent to Codex. `OPEN CLAIM <claim_id>:` remains as a heading purely for Codex's own
     readability — it is never re-parsed by `/ccs`'s own code again after this point.
  5. On any structural or content-completeness mismatch in step 3: log a one-line narration note,
     and skip straight to the normal `--resume` fallback (see "On failure" below) — never attempt
     to dispatch an unverified or incomplete digest.
  ```

- [ ] **Step 5: Write the closed-claim ceiling and byte-budget preflight subsection**

  Append directly after Step 4:

  ```markdown
  ## Closed-claim section has its own ceiling

  The closed-claim one-line summaries have no bound by default, and the count of closed claims only
  ever grows across a session — in a claims-heavy review, this section could itself eventually
  threaten the wrapper's 131,072-byte combined-prompt cap, at which point compaction would
  permanently fail via `artifact_too_large`. Fixed with a small, bounded rule (no LLM
  summarization): include the `CLOSED_CLAIM_LIMIT = 20` most-recently-closed claims' one-line
  summaries verbatim (ordered by `source_round` descending), and collapse everything older into a
  single line: `<N> additional claims resolved/retracted before round <R>; see the session's own
  JSONL log for full detail.` This bounds the closed-claim section's own contribution to a small,
  fixed COUNT regardless of how many rounds a session eventually runs.

  **Disclosed, accepted residual limitation.** The closed-claim cap bounds COUNT (20 entries), not
  bytes — the marker-reason grammar requires only a non-empty sentence, with no length limit, so 20
  valid-but-long closure reasons are not actually "small." Open claims remain fully unabridged with
  no count or byte bound. So a session with a large number of open/closed claims, one exceptionally
  large finding, OR a large re-collected diff/artifact can still produce a rendered prompt exceeding
  the wrapper's 131,072-byte cap.

  ## Byte-budget preflight

  **Measure via the authoritative collection path, never an approximation.** For `--uncommitted`
  scope, the diff/untracked-content component is measured by reusing the SAME authoritative
  collection the wrapper itself performs (the actual `collect_untracked_files.py`-equivalent
  content collection), never the candidate snapshot file — that file deliberately records
  untracked files by NAME ONLY (see `references/snapshot-integrity.md`), never their real content,
  so a name-only estimate would silently undercount. For `--commit` scope specifically, ALSO
  measure the commit's own patch content authoritatively — re-running the SAME `git show`/`git
  diff` invocation (through the SAME anchored, sanitized pattern used elsewhere in this skill) the
  wrapper itself will use for `target.resolved_commit_sha` (see "Restart mechanism" below) — since
  every fresh `--commit` dispatch embeds that patch in the prompt exactly like `--uncommitted`/
  `--base` embed their own diffs. Only non-repo-artifact scope is genuinely focus-text-only for
  this preflight, since `CLEAN_REPO_DIR`'s guaranteed-empty diff means there is no separate
  diff-content component to measure at all.

  A nonzero exit from either the `--commit`-scope `git show`/`git diff` measurement OR the
  authoritative untracked-content collector invocation is never treated as "zero bytes" — either
  is treated exactly like any other compaction failure (log the narration, fall through to the
  normal `--resume` fallback) immediately, without ever attempting the real dispatch that would
  only hit the identical failure.

  **Measure the focus text exactly, never estimate it.** Since Claude constructs the exact,
  complete focus text (digest + Why/Scope/SCOPE-CONSTRAINT + original artifact text, when
  applicable — see "Restart mechanism" step 4 below) before ever dispatching it, the preflight
  measures its REAL byte length directly (e.g. `wc -c` on the assembled focus content) — an exact
  count, not an estimate. The total checked against `COMPACT_BYTE_BUDGET = 120,000` is: this exact
  focus-text byte count, PLUS the diff/untracked-content (or `--commit` patch) byte count from the
  authoritative collection above. `120,000` is tighter than the wrapper's real 131,072-byte cap —
  the remaining ~11,000-byte margin absorbs the wrapper's own fixed prompt scaffolding text outside
  the caller-supplied focus, which this estimate does not measure directly.

  **Re-run before EVERY re-collected candidate, not only the original attempt.** The no-threadId
  fresh retry and thread B's own dispatch (see "Retry topology" below) each re-collect a genuinely
  fresh candidate — a newly re-collected candidate's own byte size can legitimately differ from the
  original measurement (the source may have grown in the meantime). This preflight therefore
  re-runs before EVERY fresh dispatch that re-collects a candidate — the original attempt, the
  no-threadId fresh retry, and thread B's own dispatch alike.

  **A real latch, not merely an implicit "it'll fail the same way again" claim.** Exceeding
  `COMPACT_BYTE_BUDGET` sets `compaction_disabled_reason` to `"byte_budget_exceeded"` — the SAME
  durable latch mechanism as the other two triggers (see "Trigger" above), naming WHICH component
  (claims vs. diff/artifact) drove the estimate over budget where determinable. Once set, every
  later triggering round's threshold check no-ops immediately, per the existing latch contract —
  skipping the local re-collection and re-measurement entirely, not merely skipping the network
  dispatch. This exceeding-budget failure does NOT increment `COMPACTION_CONSECUTIVE_FRESH_FAILURES`
  (see "Trigger" above) — it is a distinct, already-fully-diagnosed cause with its own immediate
  latch, not the slower two-strikes bound. A future revision could address the root cause (e.g.
  capping open-claim evidence length, or reintroducing LLM summarization) — explicitly out of scope
  for v1 (see "Explicitly out of scope for v1" above).
  ```

- [ ] **Step 6: Verify all four `compaction_disabled_reason` values are now fully defined, and constants match Global Constraints**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "COMPACT_THRESHOLD\|COMPACTION_MAX_CONSECUTIVE_FRESH_FAILURES\|CLOSED_CLAIM_LIMIT\|COMPACT_BYTE_BUDGET" codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: `COMPACT_THRESHOLD = 8,000,000`, `COMPACTION_MAX_CONSECUTIVE_FRESH_FAILURES = 2`,
  `CLOSED_CLAIM_LIMIT = 20`, `COMPACT_BYTE_BUDGET = 120,000` each appear with these exact numeric
  values, matching this plan's own Global Constraints section verbatim.

- [ ] **Step 7: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md digest construction, claim ceiling, byte-budget preflight"
  ```

### Task 5: Restart mechanism step 0 — mandatory pre-existing snapshot revalidation ordering

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (insert a new `## Restart
  mechanism` section between `## Byte-budget preflight` (Task 4) and `## Scope (v1)`)

**Interfaces:**
- Consumes: the existing round-2+ pre-dispatch snapshot check (`references/snapshot-integrity.md`,
  unmodified by this feature except for the narrow companion amendment in Task 17).
- Produces: the numbered step-0-through-6 structure every later task in this plan (Tasks 6-14)
  appends to, in order — this task writes ONLY step 0.

- [ ] **Step 1: Read the design doc's restart-mechanism opening and step 0**

  Read, in full, the design doc's `### Restart mechanism` section from its opening paragraph
  ("There is no way to shrink an existing thread's own context...") through the end of its
  numbered "0." item (ending just before the numbered "1." item, "Build `COMPACT_DIGEST`...").

- [ ] **Step 2: Write the restart-mechanism opening and step 0**

  Insert, as a new section between `## Byte-budget preflight` and `## Scope (v1)`:

  ```markdown
  ## Restart mechanism

  There is no way to shrink an existing thread's own context, so compaction means **abandoning the
  old thread and starting a genuinely fresh one**. A compaction attempt is entirely self-contained —
  its own success or failure is never itself reported as this round's terminal outcome (see
  "Failure isolation from the round loop" below).

  ### Step 0 — the existing snapshot revalidation always runs first, unconditionally

  Round R's own pre-dispatch snapshot check (`references/snapshot-integrity.md`) — validating the
  CURRENTLY ACTIVE `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST`, unrelated to anything compaction is about to
  do — runs exactly as it does for every other round, BEFORE the threshold check that decides
  whether to attempt compaction at all. If that existing check fails, the existing
  `🛑 SNAPSHOT INTEGRITY FAILURE` hard stop fires immediately, exactly as today — a corrupted active
  snapshot is never silently "fixed" by proceeding into a compaction attempt that would replace it
  with a fresh candidate; that would hide a real integrity failure rather than report it.

  **This "always runs first" is about ORDINARY per-round dispatch, not about reconstructing the
  remembered facts it checks against — those two are sequenced the other way around during
  continuity recovery.** This step's job is "does the ACTIVE file still match what Claude currently
  remembers," and it assumes that remembered value is already correct going in. Reconstructing what
  that remembered value SHOULD be, after an interruption, is the job of the post-append recovery
  logic instead (see "Retired- and provisional-snapshot durability" below) — a one-time,
  continuity-recovery-only step, run once, BEFORE this step's own check is ever invoked for the
  first round dispatched after that recovery, triggered by searching the WHOLE session log for the
  most recent round that ever recorded compaction lineage, never by checking only whether the
  LATEST completed line happens to be one (once even one ordinary round completes after a
  successful compaction, "the latest line" is no longer that compaction's own line). Once that
  recovery step has updated the remembered `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` (or confirmed no
  update was needed), this step proceeds exactly as already described, now correctly informed.
  Outside of continuity recovery — the ordinary case, no interruption having occurred — there is
  nothing to reconcile and this step simply runs first as originally stated.
  ```

- [ ] **Step 3: Verify the heading hierarchy is consistent (a new `##`-level "Restart mechanism"
  section containing `###`-level numbered steps, not a flat list)**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "^## \|^### " codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: `## Restart mechanism` appears once, followed by `### Step 0 — ...` — later tasks
  (6-10) each append `### Step 1 ...` through `### Step 6 ...` as siblings of `### Step 0` under
  the SAME `## Restart mechanism` parent, never as their own separate `##`-level sections.

- [ ] **Step 4: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md restart mechanism step 0 (snapshot revalidation ordering)"
  ```

### Task 6: Restart mechanism steps 1-2 — digest-verification abort, non-repo-artifact special case (`CLEAN_REPO_DIR` 8-check cleanliness)

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (append `### Step 1` and
  `### Step 2` under the `## Restart mechanism` section from Task 5)

**Interfaces:**
- Consumes: Task 4's `COMPACT_DIGEST` structural verification; `references/non-repo-artifact.md`'s
  existing `CLEAN_REPO_DIR`/`FAKE_GIT_HOME` allocation (unmodified — this task only ADDS a
  cleanliness recheck before compaction's own dispatches into it, never changes how
  `CLEAN_REPO_DIR` itself is created).
- Produces: the exact eight-check `CLEAN_REPO_DIR` cleanliness predicate this task defines, reused
  verbatim by Tasks 11-12 (retry topology) and Task 27 (eval scenario).

- [ ] **Step 1: Read the design doc's restart-mechanism steps 1 and 2**

  Read, in full, the design doc's numbered "1." item ("Build `COMPACT_DIGEST` via the structured-
  data-first construction above...") and numbered "2." item ("Non-repo-artifact sessions are a
  SEPARATE case...") — this is the longest single block in the entire design doc (roughly 380
  lines) because it accumulates EIGHT independently-confirmed git-metadata-borrowing checks, each
  closing a real, live-reproduced gap the previous seven did not close. Read every one of the eight
  checks and their own justifying live-reproduction text before writing this task's content — do
  not skip ahead once you recognize the pattern; check 7 ("commondir") and check 8 ("alternates")
  are each independently real and NOT implied by checks 1-6.

- [ ] **Step 2: Write step 1 (digest-verification abort)**

  Append under `## Restart mechanism`, as a sibling of `### Step 0`:

  ```markdown
  ### Step 1 — build and verify `COMPACT_DIGEST`

  Build `COMPACT_DIGEST` via the structured-data-first construction in "Digest construction and
  verification" above; abort to the normal `--resume` fallback (step 6 below) immediately if its
  own structural verification fails.
  ```

- [ ] **Step 3: Write step 2's opening (why `CLEAN_REPO_DIR` needs special handling) and the bound-copy-verify-embed rule**

  Append directly after step 1:

  ```markdown
  ### Step 2 — non-repo-artifact sessions are a SEPARATE case, handled BEFORE the scope branches below

  A non-repo-artifact session (`references/non-repo-artifact.md`) dispatches `--uncommitted`
  against an intentionally EMPTY `CLEAN_REPO_DIR` — the actual reviewed material lives only in
  `--focus` text, never in the diff. If compaction naively re-collected "the diff" here, it would
  recollect an empty diff and the fresh thread would never see the artifact at all. Fixed: for a
  non-repo-artifact session, compaction (a) allocates NO new snapshot — like `--commit` scope, the
  ORIGINAL round-1 snapshot (which already holds the exact pasted artifact bytes for this session
  type, per `references/snapshot-integrity.md`) remains active and untouched throughout; (b) the
  fresh restart's focus text includes the ORIGINAL ARTIFACT TEXT in addition to `COMPACT_DIGEST` —
  exactly mirroring how round 1 itself had to paste the artifact into focus text for this session
  type.

  **Bind the dispatched bytes to the SAME verified copy the hash-check ran against — never a
  separate re-read.** Read `SNAPSHOT_FILE`'s content into a captured copy exactly ONCE, at this
  step — hash that SAME captured copy and confirm it equals `SNAPSHOT_DIGEST` before using it for
  anything. If it matches, embed that verified copy's content into the fresh restart's focus text
  (never re-open or re-read the original file a second time for this purpose). If it does NOT
  match, this is the EXISTING `🛑 SNAPSHOT INTEGRITY FAILURE` hard stop, exactly as an ordinary
  round's own pre-dispatch revalidation already handles.
  ```

- [ ] **Step 4: Write the eight-check `CLEAN_REPO_DIR` cleanliness predicate**

  Append directly after step 3's content:

  ```markdown
  **Revalidate `CLEAN_REPO_DIR`'s own cleanliness before trusting it — never simply assumed.**
  `CLEAN_REPO_DIR` is created once and reused for the whole session — if anything unexpected
  polluted it since round 1, a fresh dispatch against it would collect REAL tracked/untracked
  content and silently mix it into what is supposed to be a strictly artifact-only review.
  `git status`, in ANY combination of flags, can never prove the directory holds nothing —
  committed content is invisible to it entirely (confirmed live: `git status --short
  --untracked-files=all --ignored=matching` reports changes RELATIVE TO `HEAD` and produces EXACTLY
  ZERO bytes of output against an ordinary clean repo with real committed files, while
  `git ls-files`/`git rev-parse --verify -q HEAD` both show real content is present).

  Cleanliness means ALL EIGHT of the following checks pass — a bare, freshly-`git init`'d,
  genuinely-independent, non-symlinked, self-contained git repo directory with no files, no
  commits, no borrowed metadata, and no borrowed objects:

  1. **No stray entries.** The directory contains NO entries at all other than `.git` itself — a
     literal directory listing, e.g. `find "$CLEAN_REPO_DIR" -mindepth 1 -maxdepth 1 ! -name .git`,
     through the same anchored/sanitized invocation pattern as every other direct git-adjacent call
     in this skill, expected to produce no output.
  2. **Genuinely inside a work tree.** `git rev-parse --is-inside-work-tree` expected to output
     EXACTLY `true`.
  3. **HEAD has never been given a commit.** `git rev-parse --verify -q HEAD` expected to FAIL/exit
     nonzero (an unborn HEAD).
  4. **`CLEAN_REPO_DIR`'s own literal path is NOT a symlink.** `[ ! -L "$CLEAN_REPO_DIR" ]` —
     otherwise `CLEAN_REPO_DIR` could be swapped for a symlink pointing at a DIFFERENT, also-empty,
     also-commit-less git repo, and checks 1-3 would still report clean while every dispatch
     actually operated against a completely different directory.
  5. **`CLEAN_REPO_DIR` is the ROOT of its own independent repository, not merely nested inside
     one.** `git rev-parse --show-toplevel` output EQUALS `CLEAN_REPO_DIR`'s own canonical path
     exactly — `--is-inside-work-tree` alone only confirms the path lives SOMEWHERE inside SOME
     working tree (confirmed live: a nested subdirectory of an unrelated repository also reports
     `--is-inside-work-tree=true`, while its own `--show-toplevel` correctly resolves to the PARENT
     repository, not itself).
  6. **`.git` itself is a genuine, self-contained directory.** `[ -d "$CLEAN_REPO_DIR/.git" ] && [
     ! -L "$CLEAN_REPO_DIR/.git" ]` — never a plain file (the standard git-worktree gitfile format,
     `gitdir: <path>`) and never a symlink; both would let a linked git WORKTREE's own
     `--show-toplevel` return its own local root (satisfying check 5) while its `--git-dir`/
     `--git-common-dir` point OUTSIDE it, into a completely different repository's shared metadata.
  7. **No `git-dir`/`common-dir` metadata borrowing.** `git rev-parse --git-dir` AND
     `git rev-parse --git-common-dir`, each resolved to its own canonical absolute path, must BOTH
     equal `CLEAN_REPO_DIR/.git`'s own canonical absolute path — this subsumes both the
     gitfile/symlink indirection (check 6) and a separate, independent `commondir`-file indirection
     (per git's own `gitrepository-layout(5)`: a `commondir` file inside an otherwise entirely
     ordinary, non-symlink `.git` directory sets the effective `GIT_COMMON_DIR` to its own target,
     confirmed live to pass every check through check 6 while `git rev-parse --git-common-dir`
     reveals the borrowed external path).
  8. **No object-store borrowing.** `CLEAN_REPO_DIR/.git/objects/info/alternates` must NOT exist
     (or, if present, must be empty) — per git's own `gitrepository-layout(5)` documentation, this
     file lets git borrow OBJECTS from a listed external repository's own object store, entirely
     independent of `--git-dir`/`--git-common-dir` (confirmed live: with such a file present, all
     seven checks above still pass while `git cat-file -p` successfully reads real content from the
     foreign repository's own object store).

  **A candid scope statement.** This checklist cannot claim to be an EXHAUSTIVE, adversarially-
  hardened defense against every conceivable git extension point (hooks, submodules, custom refs,
  sparse-checkout redirection, and others not yet enumerated) — closing each CONFIRMED gap as it is
  found is the practical, honest bar this design holds itself to. `CLEAN_REPO_DIR` is created once
  by this skill's own trusted Phase 0 setup; these checks exist to catch UNEXPECTED, ACCIDENTAL
  drift, not to defend against a deliberately adversarial actor with enough local access to plant a
  crafted `.git` directory in the first place (that same actor would have comparable access to
  sabotage the session through many other paths this design has no power to close either). A
  residual, disclosed risk this does not close: `scripts/lib/git-safe.sh`'s own sanitization
  protects the WRAPPER's own git invocations specifically — it says nothing about whatever Codex
  itself might independently choose to read or execute from `.git/config` during its own
  investigation of this same CWD; hardening Codex's own sandboxed behavior against a hypothetically
  malicious `.git` directory is a base-sandbox-model concern beyond this design's own scope. A
  second residual, disclosed risk: a check-then-use race remains between these eight checks
  completing and the wrapper's own LATER, separate re-resolution of the same `$CWD` pathname (once
  for its own `git -C "$CWD"` calls, once for its `cd "$CWD"` launch step) — inherent to any
  "verify a pathname locally, then hand it to a separately-invoked process" pattern, accepted as a
  narrow, low-probability window. This compaction-owned recheck is the ONLY point at which
  `CLEAN_REPO_DIR`'s cleanliness is EVER verified anywhere in this whole mechanism — round 1's own
  very first artifact dispatch, and any session that never triggers compaction at all, remain fully
  exposed to this same pollution risk with NO check of any kind, a real, disclosed, PRE-EXISTING
  gap in the base mechanism itself, not introduced or widened by compaction, and out of scope for
  this feature to close (doing so would mean adding a new check to the base skill's own Phase 0/
  Phase 1 setup, which this file does not own).

  If any of the eight checks is not clean, this is treated exactly like any other compaction
  failure (log the narration, fall through to the normal `--resume` fallback in step 6 below) —
  never dispatch against a `CLEAN_REPO_DIR` whose emptiness wasn't just reconfirmed. Only once this
  check passes does the `--uncommitted` dispatch against `CLEAN_REPO_DIR` proceed, producing an
  empty diff as designed, with the wrapper's own no-diff branch falling back to reviewing the focus
  text — now containing both the artifact and the digest.

  **This recheck runs before EVERY separate fresh dispatch for a non-repo-artifact session** — the
  original attempt, the no-threadId fresh retry (see "Retry topology" below), and thread B's own
  fresh dispatch alike — never assumed still valid from an earlier check moments or minutes in the
  past. **Also required immediately before the step-6 fallback dispatch**, whenever this session is
  non-repo-artifact: if it fails there, this is logged as a disclosed risk, never a hard stop, since
  the fallback is this round's own real, required outcome with no further fallback beneath it.
  Ordinary, non-compaction `--resume` rounds sharing this identical base-skill property (no round
  is otherwise ever forced to recheck `CLEAN_REPO_DIR`'s cleanliness before an ordinary resume) are
  an inherited, pre-existing limitation this feature does not newly introduce.

  **Fail CLOSED wherever a real alternative still exists.** Candidate A's own resume-retries and
  the bullet-3 same-thread retry (see "Retry topology" below) treat a failed recheck exactly like
  any other compaction failure — abandon this compaction attempt, fall through to step 6's
  fallback, never dispatch into a KNOWN-polluted directory. This abandonment unconditionally adds
  A's own already-known thread id to `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` before
  falling through — this is a LOCAL, pre-dispatch check failure, never a wrapper response, so the
  abandonment is entirely local knowledge, nothing to discover from a response. The "log and
  continue, disclosed risk" treatment is reserved ONLY for the step-6 fallback dispatch itself and
  any retry OF that fallback — the true last resort, genuinely having nowhere further to fall back
  to. The ORIGINAL fresh dispatches (candidate A's first attempt, the no-threadId retry, thread B)
  keep their existing hard "fall through to the normal compaction failure path" behavior when this
  recheck fails.

  **A non-repo-artifact round is always single-group `main` anyway** (see "Scope (v1)" above and
  `references/non-repo-artifact.md`), so this recheck never interacts with any group-count merge
  logic.
  ```

- [ ] **Step 5: Verify the eight checks are numbered 1-8 with no gap or duplicate, and that all four `git rev-parse` sub-checks (2, 3, 5, 7) name the exact flag each uses**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "^  [0-9]\. \*\*" codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: exactly 8 numbered items under "Cleanliness means ALL EIGHT", each with a distinct
  bolded title, in the same order as this task's Step 4 content.

- [ ] **Step 6: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md restart mechanism steps 1-2 (digest verify + CLEAN_REPO_DIR 8-check)"
  ```

### Task 7: Restart mechanism step 3 — `--uncommitted`/`--base` candidate snapshot lifecycle

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (append `### Step 3` — part 1
  of 3 — under `## Restart mechanism`, immediately after `### Step 2` from Task 6)

**Interfaces:**
- Consumes: `references/snapshot-integrity.md`'s existing "one canonical subject" allocation
  pattern (Phase 0 step 5 / Phase 1's post-sizing step) as the template for candidate collection.
- Produces: `candidate_snapshot_path` (durable field, finalized in Task 9), the
  disclosed collect-then-dispatch timing gap statement reused by Tasks 8-9.

- [ ] **Step 1: Read the design doc's step 3 opening and the `--uncommitted`/`--base` sub-bullets**

  Read, in full, the design doc's numbered "3." item from "Repo-diff sessions — snapshot candidate
  lifecycle, fully specified" through the end of the `--base <ref>` sub-bullet (stop before the
  `--commit <sha>` sub-bullet, which is Task 8).

- [ ] **Step 2: Write step 3's opening and the disclosed collect-then-dispatch gap**

  Append under `## Restart mechanism`, as a sibling of `### Step 2`:

  ```markdown
  ### Step 3 — repo-diff sessions: snapshot candidate lifecycle

  Re-collection handling depends on round 1's original scope, as before.

  **Disclosed limitation, inherited from round 1's own identical property, not new to
  compaction.** The candidate below is collected and hashed by Claude's OWN local git invocation,
  BEFORE the wrapper is ever dispatched; the wrapper then independently re-collects its own
  `DIFF_TEXT` internally, at its own later moment, since it accepts no snapshot/payload argument at
  all — if the source changes in that gap, the candidate Claude hashed and the content the fresh
  thread actually reviewed can diverge, and every later verification of the candidate (including
  the live pre-promotion checks in "Ordering on success" below) only proves the candidate itself
  wasn't corrupted AFTER Claude collected it, never that it equals what the dispatch truly
  reviewed. This is especially pronounced for untracked files, whose CONTENT is collected by the
  wrapper but whose entry in this design's own snapshot may only track their names. This is the
  SAME accepted non-goal `references/snapshot-integrity.md` already documents for round 1's own
  original collect-then-dispatch gap ("not a defense against a deliberately changed source") —
  compaction inherits this exact property unchanged.
  ```

- [ ] **Step 3: Write the `--uncommitted` and `--base` sub-bullets**

  Append directly after step 2:

  ```markdown
  - **`--uncommitted`:** re-collect the diff into a NEW candidate `SNAPSHOT_FILE`, hash it into a
    candidate `SNAPSHOT_DIGEST` (same mechanism as `references/snapshot-integrity.md`'s own Phase 0
    step 5 / Phase 1 post-sizing allocation) — the working tree may genuinely have changed since
    round 1, so this is the one case re-collection is meaningful for.
  - **`--base <ref>`:** re-collect `${ref}...HEAD` again into a new candidate the same way — this
    DOES pick up any new commits landed on `HEAD` since round 1, but does **not** reflect
    uncommitted working-tree changes (disclosed limitation: a fix applied but not yet committed
    will not appear in this re-collection).
  ```

- [ ] **Step 4: Verify the section is a direct sibling of `### Step 2`, not nested under it**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "^### Step" codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: `### Step 0`, `### Step 1`, `### Step 2`, `### Step 3` each appear at the same heading
  depth, in order — Task 8 appends MORE content under this same `### Step 3` heading (the
  `--commit` sub-bullet), not a new `### Step 3b` heading.

- [ ] **Step 5: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md restart mechanism step 3 (uncommitted/base candidate lifecycle)"
  ```

### Task 8: Restart mechanism step 3 continued — `--commit` scope SHA-pinning + durable scope-value fields

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (append to the END of `###
  Step 3`, still under `## Restart mechanism`)

**Interfaces:**
- Consumes: the wrapper's own `--commit <value>` argument parser (accepts any git revision
  expression, never resolves/validates it — confirmed against `scripts/run-ccs-review.sh`).
- Produces: `target.resolved_commit_sha` (durable, round-1 AND every later round), `target.scope`
  (unchanged existing field, category only), `target.scope_value` (durable, round-1 own line, new
  field carrying the literal `--base`/`--commit` argument).

- [ ] **Step 1: Read the design doc's `--commit <sha>` sub-bullet in full**

  Read, in full, the design doc's `--commit <value>` sub-bullet under step 3 — this covers: the
  "not every accepted `--commit` value is immutable" correction, the `git rev-parse` resolution
  and single-clean-SHA verification (including the `HEAD^..HEAD` two-line-output regression case),
  the "round 1 itself must be pinned too" fix, and the "durably persisting the original scope
  ARGUMENT" fix (`target.scope_value`).

- [ ] **Step 2: Write the `--commit` SHA-pinning sub-bullet**

  Append to the end of `### Step 3` (directly after the `--base <ref>` sub-bullet from Task 7):

  ```markdown
  - **`--commit <value>`:** re-collecting this scope's diff is byte-identical every time ONLY WHEN
    `<value>` is itself an immutable, already-resolved commit SHA — the wrapper's own argument
    parser accepts any git revision expression (confirmed directly: it rejects only a
    leading-dash value, never validates or resolves the value to a fixed SHA), so `--commit HEAD`
    or `--commit main` is legal and can resolve to a genuinely different commit by the time a
    compaction restart happens, if that ref moved since round 1. Fixed: resolve `git rev-parse
    <value>` — through the SAME anchored, sanitized `env -i`/isolated-`HOME` invocation this skill
    already uses for every direct git call outside the wrapper (see `SKILL.md`'s "Determine review
    mode" for the canonical pattern) — into `target.resolved_commit_sha`, and use THAT resolved
    SHA, not the original literal `<value>`, for round 1's OWN scope-dependent
    sizing/snapshot-collection/dispatch, in addition to every later compaction restart.

    **Verify the resolution is a single, clean commit SHA before ever pinning to it.** Plain
    `git rev-parse <value>` does NOT always emit one commit object — for a range-shaped value the
    wrapper's own `--commit` branch already handles successfully today (e.g. `HEAD^..HEAD`),
    `rev-parse` emits the positive commit PLUS a separate `^<parent>` exclusion line; feeding that
    two-line output back in as a single `--commit` argument fails git resolution outright (exit
    128). After resolving, verify the output is EXACTLY one line matching a bare commit-SHA shape
    (`^[0-9a-f]{7,64}$`). **If it matches:** pin to it as designed. **If it does NOT** (multiple
    lines, a range, or anything else non-SHA-shaped): do NOT pin at all — round 1 dispatches with
    the ORIGINAL literal `<value>` exactly as the wrapper already does today (zero behavior change
    for this narrow case), no `target.resolved_commit_sha` is recorded, and compaction is simply
    never attempted for the rest of THIS session under this scope (every later threshold check
    no-ops immediately, falling through as if compaction were never enabled) — disclosed as an
    accepted, narrow limitation: ref-drift protection and compaction restart are both unavailable
    specifically for a `--commit` value that isn't a single resolvable commit.

    **Round 1 itself must be pinned too, not only the compaction restart.** The resolve-once-
    then-pin discipline applies from round 1 onward, uniformly — resolution happens exactly once,
    before ANY scope-dependent collection for this session (round 1's own sizing/snapshot/dispatch
    included), and the resulting SHA is the ONLY value ever used for a real git operation under
    `--commit` scope for the rest of the session. The original literal `<value>` the user typed is
    retained purely as `target.scope_value`, for audit/display, never used for a git operation
    again after this one resolution. This closes the loop completely: from round 1 through every
    possible compaction restart, `--commit` scope operates on one single, immutable commit for the
    whole session. No candidate snapshot is ever allocated for `--commit` scope; the ORIGINAL
    round-1 `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` remains the active snapshot, untouched, through every
    subsequent round including any compaction restart.
  - **Durably persisting the original scope ARGUMENT, not just its category.** Round 1's own
    JSONL line (not only a compaction round's) gains a new field, `target.scope_value` — the
    literal `<ref>`/`<value>` string for `--base`/`--commit` scope, omitted for `--uncommitted`
    (which has no such argument) — plus, for `--commit` specifically, `target.resolved_commit_sha`
    as above. A compaction restart under `--base` scope reuses the EXACT durably-recorded
    `scope_value`, never a freshly-typed or re-derived one; a compaction restart under `--commit`
    scope uses the durably-recorded `resolved_commit_sha` instead. **Disclosed limitation,
    inherent to `--base <ref>` where `<ref>` names a movable branch:** re-dispatching with the same
    literal `<ref>` string can still resolve to a different merge-base if that branch has advanced
    since round 1 — the same "not a defense against a deliberately changed source" non-goal
    `references/snapshot-integrity.md` already accepts elsewhere; `--base`'s own resolved
    merge-base is NOT separately pinned/verified here, since its scope is defined relative to the
    CURRENT `HEAD` by design — pinning `--base` further would change what `--base` scope actually
    MEANS, out of scope for this feature to alter.
  - **Ownership, for `--uncommitted`/`--base` (where a real candidate exists):** the candidate file
    is a NEW, separate temp file — the ACTIVE (old) `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` used for
    round-2+ revalidation is left completely untouched while the candidate merely sits on disk. On
    compaction failure (step 6 below): delete the candidate file immediately (it was never used for
    anything) and continue revalidating rounds against the untouched original active snapshot.
  ```

- [ ] **Step 3: Verify `target.resolved_commit_sha` and `target.scope_value` are each introduced with the exact field names used consistently (no `target.commit_sha` or `target.scopeValue` variant anywhere)**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "target\.resolved_commit_sha\|target\.scope_value\|target\.scope\b" codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: both new field names appear with the exact `target.` prefix and exact snake_case
  spelling shown above — Task 21 must use these identical spellings when documenting them in
  `SKILL.md`'s "Review history log" section.

- [ ] **Step 4: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md restart mechanism step 3 (--commit SHA pinning)"
  ```

### Task 9: Restart mechanism step 3 continued — atomic promotion, collection failure, retired/provisional-snapshot durability

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (append to the end of `###
  Step 3`, still under `## Restart mechanism` — this is the last piece of Step 3, before Task 10's
  `### Step 4`)

**Interfaces:**
- Consumes: `mktemp`'s own symlink-attack-resistant allocation (already used everywhere else in
  this skill).
- Produces: `PROVISIONAL_SNAPSHOT_FILE`, `RETIRED_SNAPSHOT_FILES`/`retired_snapshot_files`,
  `snapshot_digest_before`/`snapshot_digest_after`, the promotion `mv` retry-then-hard-stop rule
  reused by Task 13 ("Ordering on success").

- [ ] **Step 1: Read the design doc's promotion, collection-failure, and durability sections**

  Read, in full: the "Collection/hash failure itself" bullet under step 3; the "Concrete
  provisional-resource tracking" bullet; the "On success, promotion is ONE atomic rename onto the
  fixed `SNAPSHOT_FILE` path" bullet (including its `SNAPSHOT_DIGEST` advancement fix and its
  "failed `mv` occurring LIVE" fix); the "Recoverable without giving up `mktemp`'s own
  symlink-attack protection" bullet; the "Snapshot lineage" bullet and its "shipping this feature
  requires the SAME kind of companion amendment" note (this note itself becomes Task 17); and,
  separately (near the end of the document), the "Retired-snapshot tracking is general-purpose"
  section and the "Retired- and provisional-snapshot durability" section in full (both its
  `RETIRED_SNAPSHOT_FILES` and `PROVISIONAL_SNAPSHOT_FILE` subsections, including the
  pre-append-window and post-append-window distinction).

- [ ] **Step 2: Write the collection/hash-failure and provisional-tracking bullets**

  Append to the end of `### Step 3`:

  ```markdown
  - **Collection/hash failure itself.** Mirrors `references/snapshot-integrity.md`'s own Phase 0
    step 5 / Phase 1 post-sizing allocation, which already checks every collection command's own
    exit status and the resulting digest's shape before trusting it: if the candidate's own `git
    diff`/`shasum` collection fails, or the resulting digest fails the 64-hex-character validation,
    this is treated exactly like any other compaction failure — delete whatever partial candidate
    file may exist (on a failed deletion here, add its path to `retired_snapshot_files` — see
    "Retired-snapshot tracking" below), log the narration note, and go straight to step 6's normal
    `--resume` fallback. No dispatch is even attempted with an uncollectible candidate.
  - **Concrete provisional-resource tracking.** A new session-scoped fact,
    `PROVISIONAL_SNAPSHOT_FILE` (analogous to `LEAKED_THREAD_IDS`), is set the moment a candidate
    is successfully collected and hashed, and cleared the moment that candidate is either promoted
    (success) or deleted (failure/collection error) — never left ambiguous in between.
    `SKILL.md`'s Phase 3 terminal cleanup (every terminal path, including
    `🛑 REVIEW LOG INTEGRITY FAILURE`) is extended to also remove `PROVISIONAL_SNAPSHOT_FILE`
    whenever one is currently set, exactly like it already removes the active `SNAPSHOT_FILE` (see
    Task 21 for the exact `SKILL.md` edit).
  - **Snapshot lineage.** The one JSONL line that performs a compaction restart records both
    `snapshot_digest_before` and `snapshot_digest_after` (identical for `--commit` scope, by
    construction) — pure audit trail. This deliberately, narrowly overrides
    `references/snapshot-integrity.md`'s existing "one canonical subject, no external-drift
    detection" contract, only for this Claude-orchestrated, fully-disclosed re-snapshot event,
    never by anything auto-detected — shipping this feature requires a companion amendment to that
    reference file (see Task 17).
  ```

- [ ] **Step 3: Write the atomic-promotion mechanics and `mktemp`-based candidate path durability**

  Append directly after step 2's content:

  ```markdown
  **On success, promotion is ONE atomic rename onto the fixed `SNAPSHOT_FILE` path, never a
  separate delete-then-move.** `SNAPSHOT_FILE` is, and remains, ONE fixed literal path for the
  entire session, exactly like `REPO_ROOT`/`SESSION_ID` — promotion NEVER reassigns which path
  Claude calls `SNAPSHOT_FILE`; it always physically replaces that fixed path's own content.
  Concretely, only after this round's JSONL append is verified (see "Ordering on success" below):
  `mv "$candidate_snapshot_path" "$SNAPSHOT_FILE"` — a single `rename(2)` syscall (both paths
  guaranteed on the same filesystem, both under the same session-scoped `/tmp` area), which POSIX
  guarantees ATOMICALLY replaces the destination, unlinking its previous content as part of the
  SAME operation — there is no OS-visible intermediate state where the active path is empty.

  **`SNAPSHOT_DIGEST` must ALSO be advanced on a successful rename.** The instant the `mv` above
  completes successfully, Claude's own remembered `SNAPSHOT_DIGEST` literal is updated to
  `snapshot_digest_after` — both remembered facts (`SNAPSHOT_FILE`'s path staying constant,
  `SNAPSHOT_DIGEST` advancing to the new value) change together, in the same step, never one
  without the other. Otherwise the very next round's ordinary revalidation would hash the
  newly-promoted file, get a digest that no longer matches the STILL-remembered old
  `SNAPSHOT_DIGEST`, and incorrectly raise `🛑 SNAPSHOT INTEGRITY FAILURE` on a perfectly
  successful, intended promotion.

  **A failed `mv` occurring LIVE, after this round's own success line is ALREADY committed, is
  MANDATORY to retry, not optional — there is no fallback path available anymore, because the
  durable record has already committed to this outcome.** Retry it up to 2 more times with a brief
  pause (matching this skill's other bounded-retry conventions), RE-RUNNING the live active-file
  and candidate integrity checks (see "Ordering on success" below) before each retry attempt, not
  only the first. If ALL retries are exhausted and the `mv` still fails, this is a genuinely broken
  state — hard stop, `🛑 SNAPSHOT INTEGRITY FAILURE`, since the durable log's own claim can no
  longer be honored on disk. The OLD content is guaranteed untouched by a failed rename (rename
  either fully happens or doesn't, never partially), so this hard stop is at least never compounded
  by additional data loss.

  **The candidate file keeps using `mktemp` for a fresh, unpredictable, atomically-created path**
  exactly like every other snapshot allocation in this design (never a deterministic,
  `.candidate`-suffixed path derived from the active `SNAPSHOT_FILE`'s own name — that would
  reintroduce a symlink/predictable-path attack `mktemp`'s existing random allocation exists to
  prevent, since `/tmp` resolves to the world-writable sticky `/private/tmp` on macOS). The
  resulting random path is durably recorded, as a new field, `candidate_snapshot_path`, on that
  same round's own JSONL line at the moment of the append (a pre-append-decided value, known the
  instant the candidate is collected) — see "Ordering on success" below for continuity recovery's
  use of this field.
  ```

- [ ] **Step 4: Write the retired-snapshot tracking and provisional-window durability rules**

  Append directly after step 3's content:

  ```markdown
  **Retired-snapshot tracking is general-purpose, covering two deletion points that remain
  fallible on their own.** Both cases are genuinely independent `rm` calls on a candidate being
  ABANDONED, not promoted (promotion, above, is a single atomic rename with no separate old-file
  deletion step): a failed deletion of a PARTIAL candidate (per "Collection/hash failure itself"
  above), and a failed deletion of a fully-hashed candidate on ordinary compaction failure (per "On
  failure" below). In EITHER case, if a LATER compaction attempt's own single
  `PROVISIONAL_SNAPSHOT_FILE` slot then gets reassigned to a new candidate, the earlier
  failed-to-delete file is referenced by nothing at all. Both route through the exact same set —
  the path is added to a new array field, `retired_snapshot_files`, on that SAME round's own line
  (present only when non-empty), since both cases are discovered strictly BEFORE that round's own
  JSONL line is ever written. `SKILL.md`'s Phase 3 terminal cleanup plus continuity recovery are
  both extended to union in every path ever recorded in this field across the session's log — the
  same durable-backstop pattern already established for `LEAKED_THREAD_IDS` (see Task 21).

  **`PROVISIONAL_SNAPSHOT_FILE` has TWO genuinely different windows.** The FAILURE-path window (and
  the SUCCESS path before its own append) is entirely pre-append: disclosed, accepted as a residual
  gap, not fully closed — an interruption in this narrow window can leave one orphaned candidate
  file (and, on the success sub-case specifically, one orphaned thread — the newly-created thread
  is ALSO only tracked in-memory via `LEAKED_THREAD_IDS` until that same append lands, the identical,
  already-accepted gap every ordinary round's own thread creation already has before ITS OWN first
  append) with no recorded path to retry its cleanup. This window can span up to TWO
  candidate/thread pairs when the fresh-B escalation is reached (see "Retry topology" below), since
  A is added to `LEAKED_THREAD_IDS` in-memory-only before B is ever dispatched.

  The POST-append window (success path only, between the verified append and the promotion `mv`) is
  genuinely CLOSED, not merely disclosed, via the durably-recorded `candidate_snapshot_path` above.
  Recovery for this window (part of continuity recovery, see `SKILL.md`'s "Review history log" →
  "Read (continuity)") never skips the mandatory verify-before-trust step
  `references/snapshot-integrity.md` already requires: search the WHOLE log for the most recent
  round carrying `compacted_from_thread`/`snapshot_digest_after`/`candidate_snapshot_path` (never
  just the latest line — once even one ordinary round completes after a successful compaction, the
  latest line no longer carries these fields), reconstruct the remembered `SNAPSHOT_DIGEST` from
  THAT round's own recorded values, then:
  1. Hash whatever currently exists at the active path. If it is missing, or matches NEITHER
     `snapshot_digest_before` NOR `snapshot_digest_after` — genuine, unexplained corruption — hard
     stop, `🛑 SNAPSHOT INTEGRITY FAILURE`.
  2. If it matches `snapshot_digest_after`: still check `candidate_snapshot_path` before concluding
     nothing remains to do — in the before/after-identical edge case (`snapshot_digest_before ==
     snapshot_digest_after`), a crash after the success append but BEFORE the `mv` ever executed
     leaves the OLD, unpromoted file already "matching" `snapshot_digest_after` purely because the
     two digests happen to be equal, with the candidate still sitting, unrenamed, on disk. If
     `candidate_snapshot_path` still exists on disk: delete it (it is no longer needed either way).
     A failed deletion here cannot fold into `retired_snapshot_files` (that field can only be added
     AT APPEND TIME, but recovery runs later) — instead, attach this failed path to the NEXT round
     that actually dispatches and appends its own line (best-effort backfill); if no further round
     is ever dispatched, this shares the same accepted, disclosed, bounded-impact residual gap as
     the pre-append window above.
  3. If it matches `snapshot_digest_before` (the rename has NOT yet run): check
     `candidate_snapshot_path`. If it exists and verifies against `snapshot_digest_after`, run the
     SAME `mv` now to complete it, with the IDENTICAL retry-then-hard-stop treatment as the live
     promotion case above (re-verifying both files before each retry attempt); on success, advance
     `SNAPSHOT_DIGEST` the same way. If the candidate is missing, or present but fails to verify
     BEFORE any `mv` is even attempted: hard stop, `🛑 SNAPSHOT INTEGRITY FAILURE`.
  ```

- [ ] **Step 5: Verify every field name introduced in this task matches the Global Constraints/prior-task spelling exactly**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -no "PROVISIONAL_SNAPSHOT_FILE\|RETIRED_SNAPSHOT_FILES\|retired_snapshot_files\|candidate_snapshot_path\|snapshot_digest_before\|snapshot_digest_after" codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: all six identifiers present with exactly this spelling (note the deliberate case split:
  `RETIRED_SNAPSHOT_FILES` for the in-memory session fact, `retired_snapshot_files` for the durable
  JSONL field — never confuse the two casings when this same identifier is used in Task 13 or
  Task 21).

- [ ] **Step 6: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md restart mechanism step 3 (atomic promotion + retired/provisional durability)"
  ```

### Task 10: Restart mechanism step 4 — fresh dispatch focus-text construction

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (append `### Step 4` under
  `## Restart mechanism`, immediately after `### Step 3` from Tasks 7-9)

**Interfaces:**
- Consumes: `target.original_scope_framing` (this task's own new field), `references/claim-
  ledger.md` section 4's existing `DISPOSITION` request-block construction.
- Produces: `target.original_scope_framing` (durable, round-1 own line, write-once), the coverage-
  epoch generalization rule Task 13's append-verify table depends on.

- [ ] **Step 1: Read the design doc's step 4 in full**

  Read, in full, the design doc's numbered "4." item ("Dispatch a fresh `run-ccs-review.sh`
  call...") through to (but not including) "One shared reducer, not three ad hoc implementations"
  (that subsection, plus "Schema version bump required" and the two companion-amendment notes, are
  covered by Task 13's append-verify work and Tasks 17-19's companion amendments respectively — this
  task covers only the dispatch/focus-text-construction mechanics themselves).

- [ ] **Step 2: Write the fresh-dispatch mechanics and `target.original_scope_framing` field**

  Append under `## Restart mechanism`, as a sibling of `### Step 3`:

  ```markdown
  ### Step 4 — dispatch a fresh `run-ccs-review.sh` call

  Dispatch a **fresh** `run-ccs-review.sh` call (same scope flag as round 1, not `--resume` — or,
  for a non-repo-artifact session per step 2 above, `--uncommitted` against `CLEAN_REPO_DIR` with
  the original artifact text included in focus) with focus text composed of, in order:
  1. `COMPACT_DIGEST` (see "Digest construction and verification" above)
  2. The original artifact text, for a non-repo-artifact session only (per step 2 above)
  3. The original Why AND task-specific Scope framing, read from `target.original_scope_framing`
     (never from `target.focus` — see below for why)
  4. The standard `⚠️ SCOPE CONSTRAINT` block
  5. The SAME fixed collaboration-frame sentence every round-1 focus already includes (Claude and
     Codex are equal peers, findings must be evidence-based, the goal is 100% clean mutual
     agreement) — this is fixed, static boilerplate, not task-specific content, so it needs no
     separate durable field
  6. The SAME `DISPOSITION` request block an ordinary round 2+ would include, constructed by the
     EXISTING rule (`references/claim-ledger.md` section 4 and `SKILL.md`'s own round-2+ History
     construction), evaluated against the pre-compaction thread's own most recently completed
     round exactly as it would be for an ordinary resumed round — without this, a claim this fresh
     reviewer would happily confirm fixed has no mechanism to actually close, eventually producing
     a false `⚠️ NOT CONVERGED` at the round cap purely because compaction never asked.

  **This dispatch IS round R's real dispatch** — its own findings are processed through the
  ordinary Phase 2 steps exactly like any other round's; no separate follow-up dispatch happens in
  the success case.

  **A dedicated field is required for the Why/Scope component — `target.focus` is NOT a stable
  source for this.** `target.focus` records whatever focus text was sent for round 1's own FINAL
  logged dispatch ATTEMPT, not a stable "original task framing" fact — it diverges in two confirmed
  real ways: (1) if round 1's own dispatch initially failed and needed a resume-safe retry, the
  retry's own focus text is just a short "Retrying after a `<reason>` failure..." note plus the
  generic scope constraint, NOT the original Why/Scope; (2) for a non-repo-artifact session,
  `target.focus` ALREADY embeds the full original artifact text, so reading it back AND separately
  re-embedding the artifact (per step 2 above) would duplicate the artifact in the fresh prompt.
  Fixed: a new, dedicated, write-once field — `target.original_scope_framing` — captured exactly
  ONCE, at the moment round 1's OWN focus text is first constructed (`SKILL.md`'s Phase 1 Step 0,
  BEFORE the very first dispatch attempt of any kind, retry or not), holding ONLY the Why +
  task-specific Scope text. For a non-repo-artifact session, this field explicitly EXCLUDES the
  pasted artifact text (which stays available separately, via the unchanged snapshot). This field
  is written once to round 1's own JSONL line and is NEVER overwritten by a later retry — a retry
  only ever changes what is actually dispatched for that attempt (`target.focus`, serving its
  existing, unchanged diagnostic/continuity purpose), never this separately-recorded
  original-framing fact.
  ```

- [ ] **Step 3: Write the coverage-epoch generalization**

  Append directly after step 2:

  ```markdown
  **Coverage epoch.** For a `--uncommitted` compaction dispatch specifically, this call can report
  its own `coverage.source` exactly like any fresh `--uncommitted` dispatch can — this is a SECOND
  fresh `--uncommitted` epoch within the same session, not only round 1's. The existing "coverage
  is a round-1-only property" rule (`SKILL.md`'s own "Coverage is a Round-1-only property" section)
  is generalized to "coverage is a property of every fresh `--uncommitted` dispatch this session,
  round 1 or a compaction restart" — the CLEAN convergence gate merges EVERY such dispatch's own
  coverage outcome (worst-of-all: `"complete"` only if every one of them was `"complete"`, else the
  existing `"partial"`/`"unknown"` precedence, `omitted` lists unioned and deduplicated by `(path,
  reason)`), never round 1's alone once a compaction has occurred. `--base`/`--commit` compaction
  dispatches report no coverage, exactly like round 1 in those scopes.

  **A successful restart can ALSO lack real coverage.** The untracked-file collector deliberately
  treats a failure to write its own `--coverage-out` sidecar as non-fatal, and the wrapper
  deliberately degrades a missing/malformed sidecar to reporting no coverage metadata at all — so
  an `ok:true` fresh `--uncommitted` compaction dispatch can genuinely lack `coverage.source` too.
  The existing "always record coverage — real value when present, the `"unknown"` sentinel when
  absent" rule therefore applies symmetrically here: if this dispatch's own response is `ok:true`
  but carries no `coverage.source`, the round's `coverage_source` field is still recorded as the
  `"unknown"` sentinel — never silently omitted.

  **A retry-then-succeed candidate must reuse its OWN pre-retry coverage, never treat itself as
  coverage-less.** A fresh `--uncommitted` dispatch that first returns `ok:false` WITH
  `coverage.source` already present (several failure reasons, e.g. `timeout`, occur only after
  collection has already completed), and is then retried via `--resume` on that SAME new candidate
  thread until it succeeds, ends up with a final `ok:true` response that itself carries NO
  `coverage.source` at all — because a `--resume` call never re-collects anything. Fixed
  (generalizing `references/retry-guards.md`'s existing round-1 retry-then-succeed rule from
  "round 1" to "whichever round performs a fresh `--uncommitted` dispatch"): carry forward the
  EARLIER failed attempt's own `coverage.source` as this round's real coverage once the retry
  succeeds. If the earlier failed attempt itself carried no `coverage.source` either, the
  `"unknown"` sentinel rule above still applies.

  **The SAME retry-then-succeed situation applies to `COMPACTION_BASELINE_TOKENS` too, not only
  coverage.** `COMPACTION_BASELINE_TOKENS` is read from the EARLIER failed fresh attempt's own
  `execution.usage.input_tokens` when one exists (the fresh dispatch's real, original size, before
  any retry), never from a subsequent `--resume` retry's own response, whose `execution.usage`
  describes only the resumed turn's marginal usage. Only when the fresh attempt's own first
  response carried no usable telemetry at all does the existing "fail closed when telemetry is
  unusable" rule (see "Trigger" above) apply.
  ```

- [ ] **Step 4: Verify `target.original_scope_framing` is spelled identically everywhere, and that
  it is documented as write-once (never mutated by a retry)**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "target\.original_scope_framing" codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: the field name appears with this exact spelling in both step 2's field-order list and
  step 2's own dedicated-field justification paragraph — Task 21 must use this identical spelling.

- [ ] **Step 5: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md restart mechanism step 4 (fresh dispatch focus-text construction)"
  ```

### Task 11: Retry topology — candidate A's four-bullet decision tree

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (insert a new `## Retry
  topology` section between `## Restart mechanism` (Tasks 5-10) and `## Scope (v1)`)

**Interfaces:**
- Consumes: `references/retry-guards.md`'s existing three-way "no entry yet / existing entry,
  no-ID failure / existing entry, resume-safe failure" decision structure (unmodified — this task
  documents how compaction REUSES it for candidate A, keyed on the candidate's OWN independent
  thread-history tracking, never `GROUP_THREADS`).
- Produces: the four-bullet (`artifact_too_large` / no-ID-yet / no-ID-despite-one-known /
  ordinary-resume-safe) classification for candidate A, reused by Task 12 (thread B) and Task 13
  (append-verify).

- [ ] **Step 1: Read the design doc's retry-topology introduction and bullets 1-2**

  Read, in full, the design doc's "Reconciling with `references/retry-guards.md`'s OWN full
  escalation topology" block down through the end of bullet 2 (the no-threadId-at-all fresh retry)
  — stop before bullet 3 (the no-ID-despite-one-known case), which is written in Step 3 below.

- [ ] **Step 2: Write the retry-topology introduction and bullet 1 (`artifact_too_large`)**

  Insert a new section between `## Restart mechanism` and `## Scope (v1)`:

  ```markdown
  ## Retry topology

  A compaction attempt's brand-new candidate thread structurally has "no pre-existing thread" —
  it has never appeared in `GROUP_THREADS` before this attempt. `references/retry-guards.md`'s own
  tested, EXISTING behavior for exactly this shape of failure is: fresh A → resume A → resume A →
  if BOTH resumes are STILL exhausted, one further FULL fresh retry with a brand NEW thread B,
  abandoning A to `LEAKED_THREAD_IDS`, before ever giving up (see
  `evals/scenarios/retry-exhausted-round1-fresh-fallback` for a live-exercised example of this exact
  sequence). Compaction reuses this EXACT existing topology rather than inventing a
  compaction-specific variant — consistent with this design's own "reuse existing mechanisms"
  principle elsewhere.

  Apply `references/retry-guards.md`'s own THREE bullets, in the SAME priority order it already
  uses, to candidate A ONLY — tracked as its own fact, independent of `GROUP_THREADS` (which keeps
  meaning "the old thread" throughout, per "Failure isolation from the round loop" below). Thread
  B's own, deliberately simpler treatment is Task 12.

  1. **`artifact_too_large` first, regardless of threadId presence:** never retried. This candidate
     attempt is immediately exhausted — fall straight through to step 6's fallback (this design's
     own failure-isolation principle means this is never surfaced as its own distinct outcome,
     unlike the base skill's `🛑 INPUT TOO LARGE` for an ordinary round).
  ```

- [ ] **Step 3: Write bullet 2 (no threadId captured yet)**

  Append directly after bullet 1:

  ```markdown
  2. **Else, if THIS SPECIFIC response captured no threadId AND the current candidate has NEVER
     previously captured one either, across any earlier response in this same attempt sequence:**
     apply `references/retry-guards.md`'s "no entry yet" bullet to THIS candidate specifically: one
     fresh retry. Checking only "did THIS response lack a threadId" would wrongly treat a
     `--resume` call's own no-threadId failure (e.g. `bad_args` from a stdin mistake) as proof the
     candidate thread never existed — `references/retry-guards.md`'s own explicit rule for exactly
     that case is "that existing thread is untouched, not abandoned... retry the exact same
     `--resume` call again," so the candidate's own thread history must be checked, never inferred
     from this one response alone.

     **This retry ALSO re-collects a genuinely FRESH candidate — never reuse the already-collected
     `candidate_snapshot_path`/digest.** The wrapper accepts no snapshot input at all; EVERY fresh
     dispatch, retry included, independently re-collects `DIFF_TEXT` live from the repository at
     ITS OWN moment. A real, meaningful amount of wall-clock time elapses between the original
     failed attempt and this retry — enough for the worktree or `HEAD` to have moved — so promoting
     the OLD, earlier-collected candidate would durably record a digest for content that is NOT
     what this retry's own dispatch actually reviewed. Fixed, for `--uncommitted`/`--base` scope
     specifically (for non-repo-artifact/`--commit` scope, this retry involves no candidate file,
     exactly like the original failed attempt did not): this retry re-collects and re-hashes a
     brand new candidate (new `candidate_snapshot_path`, new digest) exactly like the original
     attempt did; the OLD (now-superseded) candidate is deleted immediately (folding a failed
     deletion into `retired_snapshot_files`, per "Restart mechanism" step 3 above).

     **This retry ALSO reconstructs the COMPLETE compaction focus text identically to "Restart
     mechanism" step 4 above** — this is a genuinely fresh `codex exec` call with no prior turn of
     its own to inherit anything from, so whatever focus text it sends is the entirety of what this
     new dispatch ever sees.

     If this retry fails AGAIN, for ANY reason (excluding `artifact_too_large`, which bullet 1
     above always takes priority over): this candidate is exhausted. **Check whether THIS retry's
     own response captured a threadId before assuming nothing needs tracking** — this retry is
     itself a genuinely fresh dispatch, and can fail with a reason that DOES carry a threadId even
     when the ORIGINAL attempt's own failure did not (e.g. the original fails `no_thread_started`
     [no ID], this retry then fails `timeout` or `nonzero_exit` [captures a real, live threadId
     before failing]). If this retry's own response DID capture a threadId, add it to
     `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` exactly like any other abandoned
     thread; only when this retry's response ALSO captured no threadId is there genuinely nothing
     to add. Delete this retry's own candidate too, when one exists. Fall straight through to step
     6's fallback. **The fresh-B escalation (Task 12) is never reached from this bullet**,
     regardless of what the retry's own second failure looks like.
  ```

- [ ] **Step 4: Write bullets 3 and 4**

  Read, in full, the design doc's bullet 3 (the no-ID-despite-one-known case) and bullet 4 (the
  ordinary resume-safe case) before writing this step, then append directly after bullet 2:

  ```markdown
  3. **Else (a threadId WAS captured for the current candidate, either by this response or an
     earlier one in the same sequence): if THIS specific response itself lacks a threadId despite
     the candidate already having one** — retry the SAME already-captured thread EXACTLY ONCE,
     never more, and never re-entering the ordinary bounded-resume/fresh-B escalation on ANY
     outcome of this one retry besides success (`references/retry-guards.md`'s own literal rule
     for this exact case describes only two outcomes: it succeeds, or "the retry ALSO fails, stop
     — report `⚠️ COULD NOT VERIFY`," with no carve-out for a different escalation path based on
     what the second failure's own reason happens to be). If that one retry fails AGAIN, for ANY
     reason: exhausted. **Always record the ALREADY-KNOWN thread id on exhaustion here** — this
     bullet's own precondition guarantees one exists, unlike bullet 2's genuinely-uncertain case —
     add it to `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` unconditionally, then fall
     straight through to step 6's fallback (never `⚠️ COULD NOT VERIFY`, per this design's own
     failure-isolation principle — see below). Only if this one retry SUCCEEDS does the candidate
     continue as this round's own live, active attempt, exactly as if no no-ID hiccup had ever
     occurred.
  4. **Else (THIS response DOES carry a threadId — the ordinary, most common case, whether this is
     the candidate's own first-ever captured id or a later response that continues to carry one):**
     this is the ordinary case — apply the standard bounded-resume-retry-then-fresh-B escalation
     directly: 2 bounded `--resume` retries against this SAME thread; if both are exhausted, the
     fresh-B escalation (Task 12).

  The fresh-B escalation is reached ONLY via bullet 4's own ordinary path — a genuinely NEW
  resume-safe failure that carries a threadId on its OWN first occurrence for this candidate (never
  via a no-ID recovery scenario per bullet 3) — never via bullet 1 or bullet 2's own exhaustion
  either, both of which fall straight to step 6's fallback without ever creating a second candidate
  thread.
  ```

- [ ] **Step 5: Verify the four bullets are numbered 1-4 with no gap, and that bullet ordering
  matches the design doc's own stated priority (artifact_too_large always checked first)**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "^  [0-9]\. \*\*" codex-stream-review/skills/ccs/references/compaction.md | grep -A3 "artifact_too_large first"
  ```
  Expected: exactly 4 numbered bullets under `## Retry topology`, bullet 1 naming
  `artifact_too_large`.

- [ ] **Step 6: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md retry topology (candidate A's four-bullet decision tree)"
  ```

### Task 12: Retry topology continued — thread B's single-shot dispatch + carry-forward rules

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (append to the end of `##
  Retry topology`, after Task 11's four bullets)

**Interfaces:**
- Consumes: candidate A's exhaustion state from Task 11 bullet 4.
- Produces: `compaction_attempt_failed_thread` (array shape, `[A]` or `[A, B]`), the "one shared
  reducer" carry-forward rules Task 16's Logging section cross-references.

- [ ] **Step 1: Read the design doc's thread-B section and the two carry-forward corrections**

  Read, in full: the "Thread B's OWN dispatch reconstructs the COMPLETE compaction focus text"
  bullet; the "Thread B's own single dispatch gets NONE of bullets 1-4's retry machinery" bullet;
  the `compaction_attempt_failed_thread` array-shape bullet; and the "This carry-forward principle
  applies to A's OWN `--resume` retry-then-succeed" correction (both the bullet-3 and bullet-4
  sub-cases, and why bullet 2's own retry needs the OPPOSITE treatment).

- [ ] **Step 2: Write thread B's dispatch and single-shot failure rules**

  Append to the end of `## Retry topology`:

  ```markdown
  **Thread B's OWN dispatch reconstructs the COMPLETE compaction focus text, identically to
  "Restart mechanism" step 4 above — never a partial or abbreviated one.** B's dispatch is a
  genuinely fresh `codex exec` call, not a `--resume`, so it has NO prior turn to inherit anything
  from — the wrapper copies each invocation's own stdin into a fresh focus-received file and
  launches a plain `codex exec` for every non-resume call, meaning whatever focus text this
  dispatch sends IS the entirety of what the new thread ever sees. Before dispatching B: thread A
  is added to `LEAKED_THREAD_IDS`; if A's own dispatch had allocated a candidate snapshot file,
  that candidate is deleted immediately (folding a failed deletion into `retired_snapshot_files`).
  For `--uncommitted`/`--base` scope, B's dispatch re-collects a fresh candidate (new
  `candidate_snapshot_path`, new digest) exactly as A's original dispatch was — never a reuse of
  A's now-deleted candidate. For non-repo-artifact/`--commit` scope, B's dispatch involves no
  candidate file at all, exactly like A's did not.

  **Thread B's own single dispatch gets NONE of bullets 1-4's retry machinery — it either
  succeeds, or the whole compaction attempt is immediately exhausted**, matching
  `references/retry-guards.md`'s own "round 2+"/one-fresh-fallback rule exactly. If B's own
  dispatch fails, for ANY reason whatsoever (`artifact_too_large`, no threadId at all, a
  threadId-bearing resume-safe reason — none of these are distinguished for B): immediate
  exhaustion, with no retry of B, no no-threadId recovery attempt for B, and absolutely no further
  escalation to a third candidate/thread. If B's own failed response captured a threadId, add it to
  `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` (alongside A's own); if not, there is
  genuinely nothing further to add for B. Delete B's own candidate, when one exists. Fall straight
  through to step 6's fallback.

  `compaction_attempt_failed_thread` becomes an ARRAY of 1 or 2 thread ids — just `[A]` when B was
  never reached, `[A, B]` when both were abandoned — rather than a single value; every consumer of
  this field (Phase 3 cleanup, the final-report thread enumeration, the append-verify field checks
  — see Task 13) is extended to accept and union in either shape.
  ```

- [ ] **Step 3: Write the coverage/telemetry/baseline carry-forward rules for A's own retry-then-succeed cases**

  Append directly after step 2:

  ```markdown
  **Carry-forward applies to A's OWN `--resume` retry-then-succeed too — BOTH bullet-3's no-ID-
  hiccup retry AND bullet-4's ordinary threadId-bearing bounded resume retry, the two genuinely
  different ways A can succeed via `--resume` — NEVER to A's bullet-2 no-threadId FRESH retry,
  which needs the OPPOSITE treatment.** Neither bullet 3's nor bullet 4's own successful `--resume`
  response ever re-collects anything, so in BOTH cases the ONLY real coverage/baseline/telemetry
  data available is the earlier failed response's own — carry it forward (see "Restart mechanism"
  step 4's coverage-epoch rules above, and "Preserving failed-attempt telemetry" below for
  `execution`). Bullet 2's own retry is the polar opposite — it is itself a genuinely NEW,
  independent re-collection, exactly like the A→B transition already is, with its OWN fresh
  coverage and baseline; applying carry-forward there would use STALE data from an attempt whose
  own collected content this retry has already deleted and superseded. For bullet 2's own
  retry-then-succeed specifically, the RETRY's own response is the sole authoritative source for
  coverage and `COMPACTION_BASELINE_TOKENS` — never the earlier, now-superseded failed attempt's —
  mechanically identical in principle to how B's own data is used, never A's, after the A→B
  transition.

  **Exactly THREE sub-cases can produce a round that carries BOTH a success AND preserved
  earlier-failure telemetry, never a "B retries" case (B is single-shot by construction, so there
  is no possible "B's own first response failed, then B itself went on to succeed" scenario):**
  (i) an EARLIER response for the eventually-successful thread A failed before that SAME thread
  went on to succeed via its own `--resume` retry (bullet 3's no-ID hiccup, or bullet 4's ordinary
  threadId-bearing bounded resume — both are this same sub-case); (ii) A's own first response
  failed with no threadId, and its ONE allowed no-threadId fresh retry then succeeded (still "A,"
  no abandoned thread, per bullet 2); or (iii) a genuinely abandoned thread A, exhausted, preceded
  thread B's own eventual success within that SAME round. **ONLY sub-case (iii) ever populates
  `compaction_attempt_failed_thread`** — in sub-cases (i) and (ii), the SAME thread that had an
  earlier failed response is what goes on to succeed, so nothing was ever abandoned; recording it
  there would cause it to be double-cleaned, or falsely reported as leaked, despite being the
  round's own real, live, active thread. All three sub-cases MAY (conditionally, never
  unconditionally) populate `compaction_attempt_execution`/`compaction_attempt_coverage` — see
  "Preserving failed-attempt telemetry" below.
  ```

- [ ] **Step 4: Verify the array-shape rule for `compaction_attempt_failed_thread` and the
  three-sub-case enumeration are internally consistent (no fourth sub-case accidentally implied)**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "sub-case (i)\|sub-case (ii)\|sub-case (iii)" codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: exactly three sub-cases named, matching this task's Step 3 text — Task 16's Logging
  section must reference these same three sub-cases by the same roman-numeral labels, never
  renumber or rename them.

- [ ] **Step 5: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md retry topology (thread B single-shot + carry-forward rules)"
  ```

### Task 13: Ordering on success — provisional tracking, atomic promotion trigger, branch-aware append-verify

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (insert a new `## Ordering on
  success` section between `## Retry topology` (Tasks 11-12) and `## Scope (v1)`)

**Interfaces:**
- Consumes: `SKILL.md`'s existing append-verify hard stop (`🛑 REVIEW LOG INTEGRITY FAILURE`,
  unmodified base mechanism — this task documents compaction's own EXTENSION of it).
- Produces: the complete, branch-aware required-field table every implementer/reviewer of this
  feature checks a compaction round's own JSONL line against — this is the single most
  durability-load-bearing piece of the whole feature.

- [ ] **Step 1: Read the design doc's "Ordering on success" section in full**

  Read, in full, the design doc's numbered "5." item ("Ordering on success — durability before any
  thread or snapshot file is touched...") through the end of its sub-item "4." (the promotion
  re-verify-both-sides step) — this is the second-longest block in the design doc after the
  `CLEAN_REPO_DIR` checks (Task 6); it defines the exact required-field table for every possible
  compaction-round outcome. Read every branch of the table before writing any of it — the branches
  are NOT independent short paragraphs, several correct each other (e.g. the coverage requirement
  branch is corrected twice in the same document for scope and for retry-then-succeed).

- [ ] **Step 2: Write the provisional-tracking-before-append steps (5.1-5.3)**

  Insert a new section between `## Retry topology` and `## Scope (v1)`:

  ```markdown
  ## Ordering on success

  Durability before any thread or snapshot file is touched, with immediate provisional tracking to
  close the intermediate-window leak an unprotected implementation would leave open (between
  "dispatch returns ok:true" and "JSONL append verified," the new thread and candidate snapshot
  must NOT be tracked nowhere — a `🛑 REVIEW LOG INTEGRITY FAILURE` in that window would otherwise
  leak both, since that failure's own cleanup only ever sweeps `GROUP_THREADS`/`LEAKED_THREAD_IDS`
  and the currently-active snapshot):

  1. This dispatch returns `ok:true` (never inferred from "a threadId exists" — several `ok:false`
     failure reasons also carry a `threadId`).
  2. **Immediately** (before doing anything else with this result): add the new thread id to
     `LEAKED_THREAD_IDS` provisionally (the candidate snapshot, when one exists, is ALREADY tracked
     as `PROVISIONAL_SNAPSHOT_FILE` from the moment it was collected — see "Restart mechanism" step
     3 above — nothing new to do for it here). Both are now covered by every existing terminal
     cleanup sweep (including a `🛑 REVIEW LOG INTEGRITY FAILURE` that might fire in step 3 below),
     even though neither has been "promoted" yet.
  3. Process this round's findings normally (`SKILL.md`'s Phase 2 steps 2-6, including the
     coverage merge from "Restart mechanism" step 4 above), then append this round's JSONL line —
     `target.scope` = the scope flag actually used (never `"resume"`), plus
     `compacted_from_thread: <old thread id>` and the snapshot-lineage fields from "Restart
     mechanism" step 3 above — and run the EXISTING append-verify hard stop exactly as any other
     round does, EXTENDED per the branch-aware table below.
  ```

- [ ] **Step 3: Write the branch-aware append-verify field table**

  Append directly after step 2:

  ```markdown
  ### The append-verify extension — branch-aware, never one fixed field list

  The base skill's own verifier only confirms the appended line carries the expected round NUMBER —
  it says nothing about which FIELDS that line carries. This extension confirms exactly the fields
  THAT SPECIFIC outcome requires, never a one-size-fits-all list (a non-repo-artifact session and
  `--commit` scope never allocate a candidate at all; several `ok:false` reasons structurally never
  carry a `threadId` at all):

  - **Success, `--uncommitted`/`--base` scope (a real candidate was allocated):** REQUIRE
    `compacted_from_thread`, `candidate_snapshot_path`, `snapshot_digest_before`,
    `snapshot_digest_after`, `compaction_attempt_failure_count` (must equal `0`).
  - **Success, non-repo-artifact or `--commit` scope (no candidate ever allocated):** the same set
    MINUS `candidate_snapshot_path`, whose absence here is the CORRECT state, not a defect.
  - **Success, whenever the ROUND's OWN scope is `--uncommitted`** (including a non-repo-artifact
    session, which dispatches AS `--uncommitted` under the hood) — **regardless of whether the
    SPECIFIC call that ultimately produced success was itself a fresh `--uncommitted` dispatch or a
    later `--resume` retry of it:** ALSO REQUIRE `coverage_source`, either a real value or the
    `"unknown"` sentinel, never simply absent — checked against the round's own recorded
    `target.scope`, never against which specific call within that round happened to succeed (this
    is what makes the retry-then-succeed carry-forward case, whose FINAL successful call is itself
    a `--resume`, correctly still require this field). Never for `--base`/`--commit` scope
    specifically (never non-repo-artifact) — neither ever emits `coverage.source` at all.
  - **Success reached after ANY earlier failed sub-attempt** (A's own resume retry-then-succeed,
    A's own no-threadId fresh-retry success, or A-exhausted-then-B-succeeds — the same three
    sub-cases from "Retry topology" above): ALSO REQUIRE `compaction_attempt_failed_thread` (the
    array covering whichever earlier sub-attempt(s) were GENUINELY abandoned before this round's
    real success — correctly EMPTY/absent for sub-cases (i) and (ii), since in EITHER, the SAME
    thread that had the earlier failed response is what goes on to succeed), `compaction_attempt_
    execution` whenever the underlying earlier failed response(s) actually carried it, and
    `compaction_attempt_coverage` ONLY for whichever of those earlier failed response(s) was itself
    a fresh `--uncommitted` dispatch — never for a failed `--resume` call among them (see
    "Preserving failed-attempt telemetry" below).
  - **Attempted-and-failed, falling through to the fallback:** REQUIRE
    `compaction_attempt_failure_count` — EXCEPT when the failure was `byte_budget_exceeded` (see
    "Byte-budget preflight" above), which deliberately never increments this counter, so its
    absence here is likewise the correct state. REQUIRE `compaction_attempt_failed_thread`
    ADDITIONALLY, **keyed on whether a threadId was ACTUALLY captured for each abandoned attempt,
    never on a fixed reason-category exclusion list** (`interrupted` can ALSO occasionally lack a
    threadId, per "Retry topology" above's own corrected candidate-retry predicate — checked
    per-occurrence, exactly like that predicate itself). When every abandoned sub-attempt's own
    response genuinely captured no threadId at all, this field is correctly absent.
  - **Any round that newly sets `compaction_disabled_reason` this round** (baseline over threshold,
    baseline unusable, failure count reaching its bound, or byte budget exceeded): that field is
    ADDITIONALLY REQUIRED whenever the round's own processing actually reached that decision this
    round.
  - **Any round whose own processing discovers a genuinely pre-append snapshot-deletion failure
    this round** (a partial-candidate or abandoned-candidate deletion failure — the two LIVE,
    within-a-round cases; promotion itself is a single atomic rename with no separate post-append
    deletion step): `retired_snapshot_files` is ADDITIONALLY REQUIRED, non-empty. **Also required,
    additionally non-empty, on whichever round actually carries a DEFERRED backfill from an earlier
    recovery-discovered candidate deletion failure** (see "Restart mechanism" step 3's own
    post-append-window recovery step 2 above).
  - **Round 1's own line, whenever `--compact` was given for this session:** `target.
    original_scope_framing` is REQUIRED on round 1's own line whenever `--compact` was given for
    the session (regardless of scope); `target.scope_value` is ADDITIONALLY REQUIRED specifically
    for `--base`/`--commit` scope (never for `--uncommitted`). `target.resolved_commit_sha` is
    REQUIRED additionally, specifically for `--commit` scope, WHENEVER resolution succeeded (never
    required when resolution itself failed verification and round 1 deliberately fell back to the
    original unpinned literal value instead — see "Restart mechanism" step 3 above).

  **Presence and type are not enough on their own — every durability-critical field must also
  match the VALUE Claude itself already computed for this transition, not merely its shape.**
  Wherever this round's own processing already computed an authoritative value BEFORE the append
  (every field on the list above qualifies — that is precisely why each is being appended in the
  first place), the verify step compares the appended value against that already-known value:
  `compaction_attempt_failure_count` must equal the just-incremented (or, on success, `0`) value
  Claude itself computed this round, never merely "any integer"; `snapshot_digest_before`/
  `snapshot_digest_after` must equal the digests Claude itself hashed; `candidate_snapshot_path`
  must equal the literal `mktemp` path Claude itself allocated this round; `compaction_disabled_
  reason` must equal the SPECIFIC cause that actually triggered it this round, not merely be one of
  the 4 valid strings; `compaction_attempt_execution`, when the underlying failed response(s)
  actually carried it, must be present and non-empty, never silently dropped.

  **`compaction_attempt_coverage` follows a STRICTER rule than `compaction_attempt_execution`, but
  ONLY for `--uncommitted`-scope sub-attempts.** Required whenever a real fresh `--uncommitted`
  wrapper dispatch was attempted and itself FAILED — candidate A's own original attempt, the
  no-threadId fresh retry, or thread B's own dispatch, each only when it uses `--uncommitted` scope
  and itself fails — either the real `coverage.source` value or the `"unknown"` sentinel for that
  entry, never simply absent. A failed `--resume` call is never a fresh `--uncommitted` dispatch
  and correctly gets NO entry here, regardless of the round's overall scope. A round whose FIRST
  fresh `--uncommitted` attempt succeeds directly has no failed sub-attempt at all, and correctly
  has no `compaction_attempt_coverage` entry — its own coverage is reported via `coverage_source`
  instead, never this field. For a `--base`/`--commit`-scope sub-attempt, no entry is ever required
  or expected.

  A missing, malformed, OR value-mismatched required field for whichever of these branches actually
  applies is treated with the SAME severity as a wrong round number — a hard stop,
  `🛑 REVIEW LOG INTEGRITY FAILURE`, never a soft warning. A field this round's own outcome does NOT
  require is correctly absent and must never be flagged as missing. If this append fails
  verification: the new thread and candidate snapshot are ALREADY tracked as provisional/leaked
  (step 2 above) and get cleaned up by the existing `🛑 REVIEW LOG INTEGRITY FAILURE` path exactly
  like any other leaked resource — nothing extra to do here, and nothing new leaks.
  ```

- [ ] **Step 4: Write the promotion trigger (step 5.4) and its re-verify-both-sides rule**

  Append directly after step 3:

  ```markdown
  ### Promotion — only after the append is verified

  **Only after that append is verified**: (a) promote — remove the NEW thread id from its
  provisional `LEAKED_THREAD_IDS` entry and make it the active `GROUP_THREADS` entry instead; add
  the OLD thread id to `LEAKED_THREAD_IDS` in its place (never an immediate `--cleanup` — see
  "Interaction with `--keep-evidence`" below); (b) **only for `--uncommitted`/`--base` scope, where
  a real candidate exists** (non-repo-artifact and `--commit` scope allocate NO candidate at all —
  `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` are already correct, having never changed, so this whole
  sub-step is simply skipped for those two scopes): immediately before the rename, re-verify BOTH
  sides of the transition, not only the destination — checking only the OLD active file would leave
  the CANDIDATE itself unverified at this late point, even though it was collected and hashed much
  earlier:
  - Re-hash whatever currently exists at the active `SNAPSHOT_FILE` path and confirm it still
    matches `snapshot_digest_before`.
  - Re-hash `candidate_snapshot_path` and confirm it still matches `snapshot_digest_after`.

  If EITHER check fails: hard stop, `🛑 SNAPSHOT INTEGRITY FAILURE` — this is genuine,
  newly-discovered corruption unrelated to compaction itself, and promoting over it (or promoting a
  corrupted candidate) would erase or misrepresent the only evidence of it. Only once BOTH pass:
  promote the candidate snapshot via the single atomic `mv "$candidate_snapshot_path"
  "$SNAPSHOT_FILE"` rename described in "Restart mechanism" step 3 above. On success, ALSO advance
  the remembered `SNAPSHOT_DIGEST` to `snapshot_digest_after` in this same step. A failure of this
  `mv` itself is handled per "Restart mechanism" step 3's own "failed `mv` occurring LIVE" rule —
  retried up to 2 more times, then `🛑 SNAPSHOT INTEGRITY FAILURE` if still failing — never the
  ordinary "On failure" compaction-fallback path below, which structurally cannot apply once this
  round's own success line is already committed. Each retry attempt REPEATS both live checks above
  first, immediately before that specific attempt's own `mv`.
  ```

- [ ] **Step 5: Verify every required-field branch names fields already introduced by Tasks 2-12
  with matching spelling, and that the two-tier "presence" vs. "value-match" distinction is stated
  explicitly**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -c "REQUIRE\|REQUIRED" codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: a nonzero count — every branch in this task's field table uses the word "REQUIRE"/
  "REQUIRED" (capitalized, matching this task's own text) so a later grep-based self-consistency
  pass (Task 22) can enumerate every durability requirement this feature imposes in one pass.

- [ ] **Step 6: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md ordering on success (provisional tracking + append-verify table)"
  ```

### Task 14: On failure (step 6) — self-contained fallback, one-JSONL-object-per-round contract

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (insert a new `## On failure`
  section between `## Ordering on success` (Task 13) and `## Scope (v1)`)

**Interfaces:**
- Consumes: candidate A/B's exhaustion state from Tasks 11-12.
- Produces: the "self-contained fallback, never a separate JSONL append" contract every other
  section of this file (and `SKILL.md`'s own append-verify hard stop) depends on;
  `compaction_attempt_coverage` (the failure-audit-only variant, distinct from `coverage_source`).

- [ ] **Step 1: Read the design doc's "On failure" section in full**

  Read, in full, the design doc's numbered "6." item ("On failure — self-contained fallback...")
  through its end — this covers: the three independent, ungated captures (threadId, `execution`,
  `compaction_attempt_coverage`); the correction distinguishing a failed attempt's coverage
  (audit-only, never folded into the convergence-gating reducer) from a successful one's; the
  candidate-deletion step; the mandatory fallback dispatch through the EXISTING retry-by-
  failure-reason procedure; and the single-JSONL-line closing rule.

- [ ] **Step 2: Write the three independent captures and the coverage audit-vs-reducer distinction**

  Insert a new section between `## Ordering on success` and `## Scope (v1)`:

  ```markdown
  ## On failure

  On any `ok:false` reason (including `artifact_too_large`) — self-contained fallback, never this
  round's own terminal outcome, and NEVER a separate JSONL append (a standalone append for the
  failed attempt would conflict with the append-verify contract requiring exactly one JSONL object
  per round number):

  1. **Three independent checks on the failed attempt's own response — each captured whenever
     present, none gated on whether another is present** (`no_thread_started` carries no
     `threadId`, since the wrapper's own reason table shows that branch requires an empty
     `THREAD_ID`, but still carries a genuine `execution` object, since Codex was already launched
     and timed before that failure was detected — nesting the captures would silently drop real
     telemetry):
     - If a `threadId` is present, remember it in-memory in `LEAKED_THREAD_IDS` immediately — this
       is a REQUIRED step whenever a threadId exists, not best-effort (see "Durable backstop for
       abandoned threads" below).
     - If an `execution` object is present, remember it (see "Preserving failed-attempt telemetry"
       below).
     - **A failed compaction attempt's coverage is DURABLY LOGGED for audit, but NEVER folded into
       the shared convergence-gating reducer.** `coverage` describes whether file COLLECTION
       completed for the CANDIDATE diff — it says nothing about whether a real Codex VERDICT was
       ever produced for that candidate. When the attempt fails, the candidate is discarded and the
       round falls back to `--resume` on the OLD thread, which only ever continues reviewing the
       OLD thread's own original diff context (`--resume` cannot be combined with a scope flag and
       never re-collects a diff). Folding the candidate's own "complete" collection status into the
       session's overall coverage would therefore claim the codebase was fully reviewed when the
       specific content that triggered this compaction attempt was, in fact, reviewed by NOBODY.
       This DIFFERS from `references/retry-guards.md`'s existing round-1 retry precedent, which
       works because retrying preserves and eventually resumes the SAME thread that will itself go
       on to produce a real verdict for that SAME collected diff — a failed COMPACTION attempt's
       fallback explicitly does NOT do this.

       Fixed: `compaction_attempt_coverage` is still recorded on the round's own JSONL line
       whenever a real FRESH `--uncommitted` wrapper dispatch specifically was attempted and
       returned `ok:false` — `coverage.source` when present, or the `"unknown"` sentinel when
       absent — but purely as a durable, best-effort AUDIT record. This is scoped to a failed FRESH
       `--uncommitted` dispatch alone — never a failed `--resume` call within the same round's own
       retry machinery, which never carries coverage at all. It is explicitly EXCLUDED from the
       shared reducer's convergence-gating computation — the CLEAN gate, continuity recovery, and
       the final artifact's own `coverage` field all consider ONLY successful fresh `--uncommitted`
       dispatches' coverage (round 1, or a compaction restart that actually succeeded), never a
       failed attempt's. A LOCAL pre-dispatch failure (digest verification, candidate collection/
       hash failure, or the byte-size preflight rejection) records no coverage field at all, for
       the same underlying reason plus the additional fact that no real dispatch was ever
       attempted. For `--base`/`--commit` scope, no coverage field is ever recorded. A non-repo-
       artifact session is NOT exempt from the general rule that a SUCCESSFUL restart's coverage
       DOES fold into the reducer — its `--uncommitted` dispatch against `CLEAN_REPO_DIR` DOES
       report coverage on success, ordinarily `{"status":"complete","reviewed_file_count":0,
       "omitted":[]}` against the always-empty clean repo — but a FAILED non-repo-artifact
       compaction attempt's coverage is excluded from the reducer for the exact same reason as any
       other scope's failed attempt.
  ```

- [ ] **Step 3: Write the candidate-deletion, fallback-dispatch, and single-JSONL-line rules**

  Append directly after step 2:

  ```markdown
  2. Delete the candidate snapshot file (if one was allocated this attempt — never for `--commit`
     scope or a non-repo-artifact session, neither of which allocates one) — it was never used for
     anything. On a failed deletion here, add its path to `retired_snapshot_files` (see "Restart
     mechanism" step 3 above).
  3. Log one narration line noting the compaction attempt failed and why.
  4. Fall through to a NORMAL `--resume` dispatch against the STILL-ALIVE old thread (still the
     active `GROUP_THREADS` entry — never touched by a failed attempt), validated against the
     STILL-ACTIVE, untouched original snapshot, using this round's real History/Scope focus text
     exactly as an ordinary round would — this IS round R's real dispatch in the failure case.
     **This fallback dispatch is subject to the EXISTING retry-by-failure-reason procedure
     (`references/retry-guards.md`) exactly like any other round's own dispatch would be** — the
     compaction-attempt fields from steps 1 and 3 above are carried through that entire retry
     sequence in memory, and attached only once, to whatever single result eventually gets
     appended for round R (its own eventual accepted success, or its own eventual terminal
     non-CLEAN outcome if retries are exhausted) — never an intermediate failed fallback attempt
     logged as if it were round R's final result. The compaction threshold check runs again next
     round if still exceeded.
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
  ```

- [ ] **Step 4: Verify "On failure" and "Ordering on success" agree on the exact same field set for
  the failure branch (no drift between the two sections)**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "^## On failure\|^## Ordering on success" codex-stream-review/skills/ccs/references/compaction.md
  awk '/^## Ordering on success/,/^## On failure/' codex-stream-review/skills/ccs/references/compaction.md | grep -o "compaction_attempt_[a-z_]*" | sort -u
  awk '/^## On failure/,/^## Scope/' codex-stream-review/skills/ccs/references/compaction.md | grep -o "compaction_attempt_[a-z_]*" | sort -u
  ```
  Expected: both field-name sets overlap on `compaction_attempt_failure_count`,
  `compaction_attempt_failed_thread`, `compaction_attempt_execution`, and
  `compaction_attempt_coverage` — no field name appears in only one section with a different
  spelling in the other.

- [ ] **Step 5: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md on-failure fallback (self-contained, single JSONL line)"
  ```

### Task 15: Failure isolation from the round loop, `--keep-evidence` interaction, durable thread backstop

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (insert three new sections —
  `## Failure isolation from the round loop`, `## Interaction with --keep-evidence`, `## Durable
  backstop for abandoned threads` — between `## On failure` (Task 14) and `## Scope (v1)`)

**Interfaces:**
- Consumes: `references/retry-guards.md`'s existing `artifact_too_large`/exhausted-retry
  terminal-outcome rules (unmodified base contract — this section documents the narrow, named
  exception Task 19's companion amendment formalizes) and `SKILL.md`'s existing keep-evidence gate.
- Produces: the "round R has exactly ONE real outcome, never one literal dispatch count"
  clarification other tasks (2, 3, 14) already assume; the reused `LEAKED_THREAD_IDS` treatment for
  the abandoned old thread on a successful restart.

- [ ] **Step 1: Read the design doc's three remaining structural sections**

  Read, in full: `### Failure isolation from the round loop` (including its two companion-
  amendment notes — for `references/retry-guards.md`'s terminal-outcome rules, and separately for
  its round-1-only scoping of the no-threadId-fresh-retry/fresh-B mechanics); `### Interaction with
  --keep-evidence`; and `### Durable backstop for abandoned threads`.

- [ ] **Step 2: Write "Failure isolation from the round loop"**

  Insert between `## On failure` and `## Scope (v1)`:

  ```markdown
  ## Failure isolation from the round loop

  A compaction attempt's own dispatch (steps 4-6 of "Restart mechanism"/"On failure" above) must
  never be confused with, or reported as, a SEPARATE round from the loop's perspective.
  Concretely, round R has exactly ONE real OUTCOME, not one literal network call — "never both"
  describes the RESULT, never the dispatch count: a failed fresh compaction attempt IS explicitly
  followed by a real, required, SEPARATE fallback `--resume` dispatch — two genuine network calls
  for that one round, not one. Round R's own real, reportable OUTCOME is either the compaction
  fresh-dispatch's own success or the fallback `--resume`'s own result — never both simultaneously
  claimed as round R's terminal status — and a compaction attempt's own failure reason (e.g.
  `artifact_too_large`) is NEVER surfaced as round R's own terminal status regardless of how many
  underlying dispatches it took to get there; it is purely an internal detail of "how round R's
  real outcome was reached," logged as one narration line plus the durable `compaction_attempt_*`
  fields above.

  **This directly conflicts with two of `references/retry-guards.md`'s own contracts — shipping
  this feature requires a companion amendment to that file (see Task 19):**
  1. `references/retry-guards.md`'s own MANDATORY terminal-outcome rules for `artifact_too_large`
     (required to end the group/round as `🛑 INPUT TOO LARGE`) and exhausted retries (required to
     end as `⚠️ COULD NOT VERIFY`) do NOT apply to a failure occurring WITHIN a self-contained
     compaction ATTEMPT on the NEW candidate thread specifically — this design deliberately absorbs
     that failure into "fall through to the fallback" rather than surfacing it as the round's own
     terminal status. A compaction attempt is not "a group" in `retry-guards.md`'s own sense; it is
     an internal sub-step of producing round R's one real outcome. The base skill's own ordinary,
     non-compaction failure handling for a REAL group's `ok:false` response remains governed by
     `retry-guards.md`'s existing, unmodified rules.
  2. `references/retry-guards.md`'s own no-threadId-fresh-retry and fresh-B escalation rules are
     explicitly scoped to a group's OWN true first-ever attempt, "only possible on round 1" — but a
     compaction restart's own candidate dispatch is STRUCTURALLY always at session round 2 or
     later. For candidate A specifically (never B — B already gets NONE of bullets 1-4's retry
     machinery, per "Retry topology" above, and a broader "any compaction candidate" wording would
     silently re-enable exactly the bug that exclusion closes), `retry-guards.md`'s own "no entry
     yet"/"true first-ever attempt" language is keyed on the CANDIDATE's own independent
     thread-history tracking (see "Retry topology" above), NOT on the session's own round-index,
     and NOT on `GROUP_THREADS` (which keeps meaning the OLD, pre-existing thread throughout a
     compaction attempt, per this section above). Candidate A is its own independent "first
     attempt" lifecycle for these SPECIFIC mechanics, by construction, REGARDLESS of what round
     number in the session it actually occurs at — the base skill's own ordinary round-1 groups
     keep `retry-guards.md`'s literal round-1 scoping exactly as written; this is a scoped
     exception for candidate A only, never B, and never a change to what "round 1" means for an
     ordinary group.
  ```

- [ ] **Step 3: Write "Interaction with --keep-evidence" and "Durable backstop for abandoned threads"**

  Append directly after step 2:

  ```markdown
  ## Interaction with `--keep-evidence`

  It is not yet known, at compaction time, whether this SESSION will end CLEAN or not — and the
  `--keep-evidence` contract requires every thread in `GROUP_THREADS`/`LEAKED_THREAD_IDS` to
  survive an eligible non-CLEAN outcome for later inspection. **The old thread is never eagerly
  deleted.** "Ordering on success"'s own promotion step above always routes it through the EXISTING
  `LEAKED_THREAD_IDS` mechanism instead of a direct `--cleanup` call — `SKILL.md`'s Phase 3's
  already-keep-evidence-gated terminal cleanup then handles it with zero special-casing: deleted
  normally on `✅ CLEAN` (or any outcome with `--keep-evidence` OFF), preserved alongside the new
  thread on an eligible non-CLEAN outcome with `--keep-evidence` ON. This reuses machinery that
  already exists for exactly this "an earlier thread was abandoned mid-session" shape (see
  `SKILL.md`'s own Guards → "Empty / failed review" handling for round-1 retries), rather than
  inventing a second cleanup path with its own edge cases.

  ## Durable backstop for abandoned threads

  `LEAKED_THREAD_IDS`/`GROUP_THREADS` are in-memory facts Claude carries across separately-
  dispatched tool calls for the rest of the run — the existing design already relies on this for
  ordinary round-1 retries. Compaction adds more state of this shape (an abandoned old thread on
  every successful restart; a dead-end thread on every failed attempt), extended to cover both here
  too, rather than leaving compaction as the one mechanism relying on memory alone:
  - A successful compaction's `compacted_from_thread` field (already logged — see "Logging" below)
    is itself sufficient to reconstruct that the named thread is abandoned and needs the same
    treatment as a `LEAKED_THREAD_IDS` entry, purely by reading the JSONL log.
  - A FAILED compaction attempt's own threadId(s) (when any exist) are additionally recorded as a
    REQUIRED field on that same round's own single JSONL line (never a separate append, and never
    best-effort — see "On failure" above) — `compaction_attempt_failed_thread`, an ARRAY of 1 or 2
    thread ids (see "Retry topology" above). This field is what makes the "never permanently
    unaccounted-for" guarantee actually true, so it inherits the SAME mandatory append-verify
    guarantee as the rest of that round's line.
  - `SKILL.md`'s Phase 3 and the final-verdict artifact's own thread enumeration
    (`references/keep-evidence.md`'s retention rules; the `threads[]` array in the durable result
    artifact) are both extended to union in every `compacted_from_thread` and
    `compaction_attempt_failed_thread` value found anywhere in the session's own JSONL log, in
    addition to whatever `GROUP_THREADS`/`LEAKED_THREAD_IDS` memory currently holds (see Task 21
    for the exact `SKILL.md` edit).
  ```

- [ ] **Step 4: Verify the two companion-amendment forward references point to the correct later task**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "companion amendment" codex-stream-review/skills/ccs/references/compaction.md
  ```
  Expected: this task's own two `retry-guards.md` companion-amendment mentions, plus Task 9's
  `snapshot-integrity.md` mention and Task 13/16's `execution-telemetry.md` mentions — cross-check
  each against the actual amendment tasks (17 = snapshot-integrity, 18 = execution-telemetry, 19 =
  retry-guards) and fix any mismatched task reference before moving on.

- [ ] **Step 5: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md failure isolation, keep-evidence interaction, thread backstop"
  ```

### Task 16: Preserving failed-attempt telemetry, evidence-lifecycle reuse, Logging summary, Final Report content

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/compaction.md` (insert `## Preserving
  failed-attempt telemetry`, `## A failed compaction attempt is a superseded attempt`, and `##
  Logging` sections between `## Durable backstop for abandoned threads` (Task 15) and `## Scope
  (v1)`; this is the LAST content task for this file before Task 17 moves on to the companion
  amendments)
- Modify: nothing else yet — the actual `SKILL.md` Final Report bullet is Task 21; this task only
  writes the CONTENT that bullet must include, inside `compaction.md` itself, for Task 21 to
  reference.

**Interfaces:**
- Consumes: every field name introduced by Tasks 2-15.
- Produces: `compaction_attempt_execution` (array shape, always — never a bare object), the two
  Final Report template sentences (fallback-outcome wording, success-outcome wording) Task 21
  points to.

- [ ] **Step 1: Read the design doc's remaining sections**

  Read, in full: `### Preserving failed-attempt telemetry` (including its "Applies to a
  retry-then-succeed round too" correction, its "Surfaced in the final report" fix with both
  wording templates, its "no `usage` object at all" fix, and its "partial `usage` object" fix);
  `### A failed compaction attempt is a superseded attempt, not a novel evidence-lifecycle case`;
  and `### Logging` (the full field-by-field summary near the end of the design doc, including its
  three-sub-case cross-reference correction).

- [ ] **Step 2: Write "Preserving failed-attempt telemetry"**

  Insert between `## Durable backstop for abandoned threads` and `## Scope (v1)`:

  ```markdown
  ## Preserving failed-attempt telemetry

  Several `ok:false` reasons (`timeout`, `nonzero_exit`, `missing_task_complete`, `invalid_json`,
  and others) still launch `codex exec` and so still carry a genuine `execution` object (elapsed
  time, and usage when available) even on failure. Fixed: when a failed compaction attempt's own
  response carries an `execution` object, it is preserved on round R's own JSONL line (alongside
  `compaction_attempt_failed_thread`, per "On failure" above — never a separate line) as
  `compaction_attempt_execution` — **always an array, one `execution` object per failed sub-attempt
  that carried one, in attempt order, even when there is only ever a single entry** — there is
  exactly ONE shape, always, never varying by how many sub-attempts actually occurred.
  `round_wall_seconds` for a round that included a failed compaction attempt covers the WHOLE round
  timeline — from immediately before the compaction attempt's own dispatch through the fallback
  dispatch's own completion — consistent with its existing definition as coordinator-measured wall
  time for the entire round, not per-dispatch.

  **Applies to a retry-then-succeed round too, not only a round that falls all the way through to
  the fallback.** Whenever a compaction round's PATH TO SUCCESS included one or more earlier failed
  sub-attempts that each carried an `execution` object, those are ALSO preserved — as
  `compaction_attempt_execution`, the SAME always-an-array shape — on this SAME successful round's
  own line, alongside `compacted_from_thread` and the snapshot-lineage fields. Exactly the THREE
  sub-cases from "Retry topology" above can produce this (never a "B retries" case, since B is
  single-shot by construction): (a) candidate A's own retry-then-succeed via `--resume`; (b)
  candidate A's own bullet-2 no-threadId fresh retry succeeding; or (c) candidate A was exhausted
  entirely and thread B then succeeded on its own single, unretried attempt — in case (c)
  specifically, the preserved `execution` entries belong to A's own failed attempt(s), never to B.

  **Surfaced in the final report, not just durably logged.** The Final Report's existing
  execution-telemetry section (`references/execution-telemetry.md` section 6) is extended to also
  list, for any round that carries a `compaction_attempt_execution` value, a clearly labeled
  separate line — distinct from that round's own real `execution`/`usage` reporting, never merged
  into it. The wording branches on this round's own real outcome, never assumes "before falling
  back" unconditionally:
  - For a round whose real outcome is the fallback: *"Round R also attempted a compaction restart
    that failed after using `<input>`/`<output>` tokens (`<elapsed>`s) before falling back."*
  - For a round whose real outcome is a success (any of the three sub-cases above): *"Round R's
    compaction restart succeeded after an earlier attempt used `<input>`/`<output>` tokens
    (`<elapsed>`s)."*

  Both templates report each preserved sub-attempt's own figures, never conflated with the round's
  own real dispatch numbers. **Both templates must also handle a preserved `execution` entry that
  has NO `usage` object at all** — `references/execution-telemetry.md`'s own established contract
  allows an `execution` object to legitimately carry only `elapsed_seconds` with `usage` entirely
  absent; whenever a preserved entry lacks a `usage` object, both templates substitute that
  reference's own established "usage unavailable" wording in place of the `<input>`/`<output>`
  tokens portion — e.g. *"Round R also attempted a compaction restart that failed after
  `<elapsed>`s (usage unavailable) before falling back."*

  **A partial `usage` object (only one of `input_tokens`/`output_tokens` present) is handled
  independently per-value, not all-or-nothing.** The wrapper's own `build_execution_json()`
  retains a non-empty `usage` object exactly as received with no member validation — a real, valid
  response carrying only `{"input_tokens": 12}` (no `output_tokens` key at all) is preserved as-is.
  Report each of `<input>`/`<output>` independently — whichever value is actually present in
  `usage` is reported normally; whichever is absent (whether because `usage` itself is completely
  missing, or present but missing just that one member) is reported with its own "unavailable"
  wording — e.g. *"Round R also attempted a compaction restart that failed after using 12 input
  tokens (output tokens unavailable) (`<elapsed>`s) before falling back."* This one rule uniformly
  covers all three shapes: full usage (both values reported), partial usage (one reported, one
  marked unavailable), and no usage at all (both marked unavailable, collapsing to the simpler
  "usage unavailable" wording as a natural special case).

  **"Present" must mean "present AND valid," reusing the EXISTING malformed-usage validation, never
  a bare key-existence check.** `input_tokens`/`output_tokens` can be present but UNUSABLE (a
  string, `null`, negative, or otherwise non-integer value) — apply the SAME non-negative-integer
  validation this file already uses for `COMPACTION_BASELINE_TOKENS` (see "Trigger" above) to each
  token value independently here too; a present key whose value fails that validation is treated
  IDENTICALLY to an absent key (its own "unavailable" wording), never rendered as a literal
  malformed value.
  ```

- [ ] **Step 3: Write "A failed compaction attempt is a superseded attempt"**

  Append directly after step 2:

  ```markdown
  ## A failed compaction attempt is a superseded attempt, not a novel evidence-lifecycle case

  A round with a failed compaction attempt followed by its own fallback `--resume` has TWO physical
  dispatches. This is exactly the EXISTING "superseded attempt within a round" case
  `references/retry-guards.md` already defines for an ordinary round's own retries — apply it
  unchanged, inventing nothing new. The failed compaction attempt's own raw event-log file (when
  `--capture-evidence` is ON) is deleted, not retained, exactly like any other superseded attempt's;
  its own last-message file (when `--keep-evidence` is ON) is never kept, exactly like any other
  superseded attempt's — only the round's FINAL attempt (the fallback dispatch) participates
  normally in whichever of the two flags is ON. This also avoids any path collision: the compaction
  attempt and the fallback each get their own temp files under the existing per-attempt allocation
  scheme, exactly as two retries of the same round already would.
  ```

- [ ] **Step 4: Write the `## Logging` field-by-field summary**

  Append directly after step 3 (this is the LAST section of `compaction.md`, and serves as the
  canonical single-page reference for every durable field this feature introduces — cross-check
  every field name against Tasks 2-15's own introductions for spelling before writing this):

  ```markdown
  ## Logging

  The compaction round is logged like any other round, with these additions, each present only on
  the round(s) they actually apply to:
  - `compacted_from_thread` — top-level, the abandoned thread's id, on a successful compaction
    round.
  - `compaction_attempt_failed_thread` / `compaction_attempt_execution` /
    `compaction_attempt_coverage` — an optional trio, present when a compaction attempt failed
    (falling through to the fallback) OR when the round's own path to success included an earlier
    failed sub-attempt (see "Retry topology" above's three sub-cases). **ONLY sub-case (iii)
    (candidate A genuinely abandoned, thread B succeeds) ever populates
    `compaction_attempt_failed_thread`** — sub-cases (i) and (ii) both involve the SAME thread
    succeeding after an earlier failure of its own, so nothing was ever abandoned; recording it
    there would cause it to be double-cleaned, or falsely reported as leaked. All three sub-cases
    MAY (conditionally, never unconditionally) populate `compaction_attempt_execution` (present
    only when the earlier failed response actually carried an `execution` object) and
    `compaction_attempt_coverage` (present only when that earlier failed response was itself a
    fresh `--uncommitted` dispatch). A round can carry the `compaction_attempt_*` trio ALONE (a
    failed attempt, fallback succeeded or not), the OTHER three (`compacted_from_thread` +
    `snapshot_digest_before`/`snapshot_digest_after`) alone (a clean first-attempt success), or
    BOTH groups together (any of the three sub-cases above).
  - `snapshot_digest_before` / `snapshot_digest_after` — top-level, on a successful compaction
    round (identical values for `--commit` scope, by construction — see "Restart mechanism" step 3
    above).
  - `candidate_snapshot_path` — top-level, present only on a round whose own compaction attempt
    SUCCEEDED under `--uncommitted`/`--base` scope, alongside `snapshot_digest_after`.
  - `coverage_source` — generalized (see "Restart mechanism" step 4 above) to also cover a
    successful `--uncommitted` compaction restart, not only round 1.
  - `compaction_attempt_failure_count` — present on TWO kinds of rounds: a round whose own
    compaction attempt fell through to the fallback (the counter's current value after
    incrementing), and a round whose own compaction attempt SUCCEEDED (the explicit value `0`,
    representing the reset).
  - `compaction_disabled_reason` — present only on the ONE round that ever sets this latch, never
    repeated on later rounds once set. Exactly one of `"baseline_at_or_above_threshold"`,
    `"baseline_unusable"`, `"repeated_fresh_dispatch_failure"`, `"byte_budget_exceeded"`.
  - `retired_snapshot_files` — an array, present only when non-empty, on whichever round's own line
    is being written when a snapshot-file deletion failure is discovered (or a deferred backfill
    from continuity recovery attaches to it).
  - `target.scope_value` — round 1's own line only, whenever `--compact` was given: the literal
    `--base`/`--commit` argument value, omitted for `--uncommitted`.
  - `target.resolved_commit_sha` — round 1's own line only, `--commit` scope, whenever resolution
    succeeded.
  - `target.original_scope_framing` — round 1's own line only, whenever `--compact` was given
    (regardless of scope): the Why + task-specific Scope text captured once, before round 1's own
    first dispatch attempt, excluding any pasted artifact text, never overwritten by a later
    retry's own different focus.

  `finding_id`/`claim_id` numbering continues incrementing globally across the compaction boundary —
  never reset — so the existing claim-ledger reducer keeps working over the whole log unmodified.

  **Shipping this feature requires bumping `schema_version`** — see Task 21 for the exact
  `SKILL.md` edit (from `2` to `3`, per this plan's own Global Constraints).
  ```

- [ ] **Step 5: Full-file re-read and final internal consistency check**

  Read the entire `codex-stream-review/skills/ccs/references/compaction.md` file top to bottom in
  one pass (it should now be roughly 700-900 lines). Confirm: every `## `-level heading from Task 1
  through this task appears exactly once, in the order Tasks 1-16 created them; every field name
  used in this task's `## Logging` summary was actually introduced with identical spelling in an
  earlier task (cross-reference each bullet above against Tasks 2-15); and every
  `compaction_disabled_reason` string value matches this plan's Global Constraints exactly.

- [ ] **Step 6: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/compaction.md
  git commit -m "docs(ccs): compaction.md preserved telemetry, evidence-lifecycle reuse, logging summary"
  ```

### Task 17: Companion amendment — `references/snapshot-integrity.md`

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/snapshot-integrity.md`

**Interfaces:**
- Consumes: nothing new — this is a narrow textual amendment to an existing, otherwise-unmodified
  file.
- Produces: the documented, narrow `--compact`-only exception to this file's own "one canonical
  subject, never changed per round" invariant that `compaction.md`'s "Restart mechanism" step 3
  (Task 9) and "Ordering on success" (Task 13) both already assume exists.

- [ ] **Step 1: Read the current file and the design doc's own justification for this amendment**

  Read `codex-stream-review/skills/ccs/references/snapshot-integrity.md` in full (already read
  once during this plan's own research phase — re-read now with an editor's eye for exactly where
  the new paragraph belongs). Then read the design doc's own paragraph beginning "This override
  needs the SAME 'shipping this feature requires a companion amendment' treatment already given to
  `references/execution-telemetry.md`" (inside step 3 of "Restart mechanism," the `--commit`-scope
  candidate-lifecycle discussion) — this is the ONLY place the design doc states what this
  amendment must say.

- [ ] **Step 2: Insert the amendment**

  Using the Edit tool, insert a new section immediately before the existing `## Not a defense
  against a deliberately changed source` heading (i.e., directly after the `## Revalidation` section
  ends, so the amendment sits right before the file's own existing non-goals discussion — the most
  natural place for a scoped exception to a section that otherwise reads as an absolute rule):

  ```markdown
  ## Compaction-only exception (`--compact`, opt-in — see `references/compaction.md`)

  The "one canonical subject, session-scoped, NEVER changed per round" invariant stated everywhere
  above holds UNCHANGED for every ordinary session. It is relaxed ONLY when `--compact` is ON for
  this session AND triggers a fully-specified, Claude-orchestrated, fully-disclosed re-snapshot-
  and-promote event — never by anything auto-detected, and never for any other reason. In that one
  case: a NEW candidate `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` is collected, verified, and atomically
  promoted onto the SAME fixed `SNAPSHOT_FILE` path (the path itself never changes — only its
  content, and the remembered `SNAPSHOT_DIGEST`, advance together), and the round that performs
  this promotion durably records `snapshot_digest_before`/`snapshot_digest_after` as an audit
  trail. See `references/compaction.md`'s "Restart mechanism" and "Ordering on success" sections
  for the complete, fully-specified mechanics — this file's own revalidation logic (above) and
  hard-stop-on-mismatch behavior are otherwise entirely unaffected: a session with `--compact` OFF,
  or one where `--compact` is ON but never actually triggers, behaves exactly as documented
  everywhere else in this file, with zero difference from before this exception existed.
  ```

- [ ] **Step 3: Verify the amendment is scoped narrowly and does not alter any existing sentence**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  git diff --stat codex-stream-review/skills/ccs/references/snapshot-integrity.md
  git diff codex-stream-review/skills/ccs/references/snapshot-integrity.md
  ```
  Expected: the diff shows ONLY an insertion (no existing line removed or reworded) — confirming
  this is additive-only, matching the design doc's own "narrowly overridden... never widened"
  framing.

- [ ] **Step 4: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/snapshot-integrity.md
  git commit -m "docs(ccs): snapshot-integrity.md companion amendment for --compact re-snapshot exception"
  ```

### Task 18: Companion amendment — `references/execution-telemetry.md`

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/execution-telemetry.md`

**Interfaces:**
- Consumes: nothing new.
- Produces: the documented, narrow `--compact`-only exception to section 8's "purely additive
  reporting... never load-bearing for convergence, retry, or integrity decisions" invariant that
  `compaction.md`'s "Trigger" section (Tasks 2-3) already depends on (it uses
  `execution.usage.input_tokens` as a genuine control input).

- [ ] **Step 1: Read the current file's section 8 and the design doc's justification**

  Read `codex-stream-review/skills/ccs/references/execution-telemetry.md` section 8 ("Interaction
  with `--capture-evidence` / `--keep-evidence` / snapshot integrity / claim ledger") — the exact
  sentence being amended is its closing clause, "this feature's own JSON is purely additive
  reporting, never load-bearing for any convergence, retry, or integrity decision elsewhere in this
  skill." Then read the design doc's own paragraph beginning "`references/execution-telemetry.md`
  itself needs a scoped amendment before this feature can ship" (inside "Restart mechanism" step 4's
  "One shared reducer" subsection).

- [ ] **Step 2: Insert the amendment as a new section 9**

  Using the Edit tool, append a new numbered section AFTER the existing section 8 (renumbering
  nothing — section 8 keeps its own number and text unchanged; this is purely additive):

  ```markdown
  ## 9. Compaction-only exception (`--compact`, opt-in — see `references/compaction.md`)

  Section 8's own "purely additive reporting... never load-bearing for convergence, retry, or
  integrity decisions" statement is a general invariant for every ordinary session. Shipping
  opt-in thread compaction requires a narrowly-scoped exception: telemetry becomes load-bearing
  ONLY when `--compact` is enabled for the session, and ONLY for the specific compaction-owned
  decisions `references/compaction.md` names — the threshold check (comparing a round's own
  `execution.usage.input_tokens` against `COMPACT_THRESHOLD`), the `COMPACTION_BASELINE_TOKENS`
  circuit breaker, and the `compaction_disabled_reason` latch. The base skill's own ordinary
  convergence/retry/integrity decisions — for every session, `--compact` ON or OFF — remain
  governed by section 8's existing, unmodified invariant: this feature never makes `execution`
  load-bearing for anything OTHER than the three compaction-owned decisions just named, and never
  for a session where `--compact` is OFF at all.
  ```

- [ ] **Step 3: Verify the amendment is additive-only and does not alter section 8's own text**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  git diff --stat codex-stream-review/skills/ccs/references/execution-telemetry.md
  git diff codex-stream-review/skills/ccs/references/execution-telemetry.md
  ```
  Expected: the diff shows ONLY a new section 9 appended after the existing section 8 — no line
  inside section 8 (or any earlier section) is changed.

- [ ] **Step 4: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/execution-telemetry.md
  git commit -m "docs(ccs): execution-telemetry.md companion amendment making telemetry load-bearing under --compact"
  ```

### Task 19: Companion amendment — `references/retry-guards.md`

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/retry-guards.md`

**Interfaces:**
- Consumes: nothing new — restates, from `retry-guards.md`'s own side, the exact two exceptions
  Task 15 already wrote (from `compaction.md`'s own side) into "Failure isolation from the round
  loop".
- Produces: the documented, narrow exceptions to (1) the `artifact_too_large`/exhausted-retry
  mandatory terminal-outcome rules, and (2) the round-1-only scoping of the no-threadId-fresh-retry/
  fresh-B escalation mechanics — both needed for `compaction.md`'s "Retry topology" (Tasks 11-12)
  and "Failure isolation from the round loop" (Task 15) to be internally consistent with this file.

- [ ] **Step 1: Read the current file's relevant sections and the design doc's two justifications**

  Read `codex-stream-review/skills/ccs/references/retry-guards.md` in full (already read once
  during this plan's research phase) — pay particular attention to the `artifact_too_large` bullet
  ("never retried, ever... round-level status is immediately 🛑 INPUT TOO LARGE"), the "No
  `threadId` was ever captured" bullet's own "only possible on round 1" framing, and the closing
  "Whenever a group ends in ⚠️ COULD NOT VERIFY.../Whenever a group ends in artifact_too_large..."
  bullets. Then re-read the design doc's own two justification paragraphs already summarized in
  this plan's Task 15 (the "A THIRD base-skill contract" paragraph, and its immediately-following
  "This amendment must ALSO cover a SECOND, separate piece" paragraph).

- [ ] **Step 2: Insert the amendment as a new closing section**

  Using the Edit tool, append a new section at the END of the file (after its existing final
  bullet about `artifact_too_large`'s round-level status):

  ```markdown
  ## Compaction-only exception (`--compact`, opt-in — see `references/compaction.md`)

  Two narrow, explicitly-scoped exceptions apply ONLY when `--compact` is ON for this session AND
  the failure in question occurs on a compaction attempt's own candidate thread specifically —
  every rule in this file continues to apply completely unmodified to the round's own REAL group
  (the existing/OLD thread), and to every session where `--compact` is OFF:

  1. **The `artifact_too_large`/exhausted-retry MANDATORY terminal-outcome rules above (`🛑 INPUT
     TOO LARGE`, `⚠️ COULD NOT VERIFY`) do NOT apply to a failure occurring WITHIN a self-contained
     compaction attempt on a NEW candidate thread.** `references/compaction.md`'s own "Restart
     mechanism"/"On failure" sections deliberately absorb such a failure into "fall through to the
     fallback dispatch on the OLD, still-alive thread" rather than surfacing it as the round's own
     terminal status — a compaction attempt is not "a group" in this file's own sense; it is an
     internal sub-step of producing that round's one real outcome. This file's own existing rules
     for a REAL group's `ok:false` response (every bullet above) are otherwise entirely unaffected.
  2. **This file's own no-threadId-fresh-retry and fresh-B escalation rules — scoped above to a
     group's OWN true first-ever attempt, "only possible on round 1" — are keyed on CANDIDATE-level
     thread history for a compaction attempt's candidate A specifically, never on the session's own
     round-index.** A compaction restart's own candidate dispatch is structurally always at session
     round 2 or later, yet candidate A is its own independent "first attempt" lifecycle for these
     specific mechanics, by construction, regardless of what round number in the session it
     actually occurs at — see `references/compaction.md`'s "Retry topology" section for candidate
     A's full four-bullet decision tree. This exception is scoped to candidate A ONLY, never to a
     compaction attempt's thread B, which gets NONE of this file's retry machinery at all (single-
     shot: it either succeeds, or the whole compaction attempt is immediately exhausted) — and never
     to an ordinary group's own genuine round-1 attempt, which keeps this file's literal round-1
     scoping exactly as written.
  ```

- [ ] **Step 3: Verify the amendment is additive-only and both exceptions match `compaction.md`'s own "Failure isolation from the round loop" wording**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  git diff --stat codex-stream-review/skills/ccs/references/retry-guards.md
  diff <(grep -A8 "artifact_too_large.*MANDATORY terminal-outcome" codex-stream-review/skills/ccs/references/retry-guards.md) <(grep -A8 "own MANDATORY terminal-outcome rules for" codex-stream-review/skills/ccs/references/compaction.md) || true
  ```
  Expected: `retry-guards.md`'s diff is additive-only (a new trailing section, nothing existing
  changed); the two exception statements in `retry-guards.md` and `compaction.md` describe the
  identical two exceptions (candidate A vs. B scoping, `artifact_too_large`/exhausted-retry
  absorption) even though their exact prose need not match word-for-word (one file states it from
  the "what changes in `retry-guards.md`" angle, the other from the "what `compaction.md` relies
  on" angle) — read both by eye to confirm no contradiction, the `diff` command above is a rough
  sanity aid, not an exact-match requirement.

- [ ] **Step 4: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/references/retry-guards.md
  git commit -m "docs(ccs): retry-guards.md companion amendment for compaction candidate-A failure isolation"
  ```

### Task 20: Amend `SKILL.md` — flag parsing, Scope section, mandatory-read entry, forced single-group override

**Files:**
- Modify: `codex-stream-review/skills/ccs/SKILL.md`

**Interfaces:**
- Consumes: `codex-stream-review/skills/ccs/references/compaction.md` (Tasks 1-16, now complete).
- Produces: `COMPACT_MODE` (the fourth Phase 0 Step 0 boolean), the updated "Usage:" line at the
  top of the file, the new "Reference files this skill must read in full" entry, and the forced
  single-group override inside "Determine review mode".

- [ ] **Step 1: Read the four exact locations in `SKILL.md` this task edits**

  Re-read, in the current file: the top-of-file "Usage:" paragraph (lines ~8-28, listing the three
  existing prefixes); the `## Scope` section (lines ~56-93); Phase 0 Step 0's flag-parsing loop
  (lines ~512-547, "Capture-evidence / keep-evidence / quick-mode decision"); the "Reference files
  this skill must read in full" section (lines ~379-427); and Phase 1's "Determine review mode"
  opening (lines ~672-680, "Non-repo artifact round? Skip this entirely" through "Genuine
  repo/code-diff round").

- [ ] **Step 2: Add `--compact` to the top-of-file Usage paragraph**

  Using the Edit tool on `codex-stream-review/skills/ccs/SKILL.md`, find the sentence "Three
  independent, optional prefixes — each may appear alone, together in any combination and order,
  or neither (see Phase 0 Step 0 for the exact parsing rule):" and change "Three" to "Four". Then,
  immediately after the existing `--quick` prefix's own description (ending "...becomes reachable
  for stopping early once every still-open claim is cleanly `LOW`/`MEDIUM` severity..."), insert a
  new sentence for the fourth prefix, before the closing "Omit all three and..." sentence (which
  itself must become "Omit all four and..."):

  ```
  `codex-stream-review:ccs --compact <task description>` — opt-in thread compaction: after any
  round whose own `execution.usage.input_tokens` crosses `COMPACT_THRESHOLD` (8,000,000), abandon
  the old Codex thread and start a fresh one seeded with a compact digest of the claim ledger
  instead of the old thread's full accumulated history (see `references/compaction.md`, read only
  when this flag is used, for the complete mechanics — forces single-group `main` for the whole
  session, per "Determine review mode" below).
  ```

  Update "Omit all three" to "Omit all four" in the same paragraph.

- [ ] **Step 3: Add a `--compact` bullet to the `## Scope` section**

  In the `## Scope` section, immediately after the existing "**Execution telemetry is also always
  on, no opt-in**" paragraph and before "**Parallel multi-reviewer mode is supported**", insert:

  ```markdown
  **Opt-in thread compaction is supported** (`--compact`) — see `references/compaction.md` for its
  full mechanics, read only when this flag is used. Independent of `--capture-evidence`/
  `--keep-evidence`/`--quick` — any subset of the four flags may be ON for a session, in any order
  (see Phase 0 Step 0 for the exact parsing rule). Forces single-group `main` for the whole
  session — see "Determine review mode" below.
  ```

- [ ] **Step 4: Extend Phase 0 Step 0's flag-parsing loop to a fourth flag**

  In Phase 0 Step 0's "Capture-evidence / keep-evidence / quick-mode decision" bullet, change
  "three independent, optional prefixes" to "four independent, optional prefixes", add
  `--compact` to the listed prefix set ("`--capture-evidence`, `--keep-evidence`, `--quick`, and
  `--compact`"), and extend the strip loop's own described mechanics to include: "each time it
  starts with `--compact ` (or is exactly that string), record **compact-mode is ON** and remove
  the prefix." Change "The three decisions are independent booleans — `CAPTURE_EVIDENCE`,
  `KEEP_EVIDENCE`, and `QUICK_MODE`" to "The four decisions are independent booleans —
  `CAPTURE_EVIDENCE`, `KEEP_EVIDENCE`, `QUICK_MODE`, and `COMPACT_MODE`" and update every other
  "three"/"three flags"/"all three" phrase in that same bullet (there are several — "any subset of
  the three", "Whichever ends up OFF", "For a session that gave all three flags") to "four"/"all
  four" consistently. Add `COMPACT_MODE` to the closing sentence's list of per-run literal facts
  Claude must write concrete branches for (alongside the existing `MAX_ROUNDS`/eventlog/
  last-message examples).

- [ ] **Step 5: Add the new "Opt-in thread compaction" entry to "Reference files this skill must read in full"**

  In the `## Reference files this skill must read in full — when and why` section, immediately
  after the existing `### Kept evidence on failure (opt-in via --keep-evidence)` subsection and
  before `### Snapshot integrity (always on, no opt-in)`, insert:

  ```markdown
  ### Opt-in thread compaction (opt-in via `--compact`)
  Once Phase 0 Step 0 determines `--compact` is ON for this session, read
  `codex-stream-review/skills/ccs/references/compaction.md` in full before doing anything else in
  this run (order relative to the other conditional/always-on files above doesn't matter — all
  files this section lists must be read before Phase 1 ever dispatches). Required at every later
  point that reference file itself names: the threshold check after every completed round (before
  building the next round's dispatch), the restart mechanism (when triggered), the retry topology
  (when a compaction attempt's own dispatch fails), and the Logging/Final-Report additions.
  ```

  Update this section's own opening paragraph ("Two of the five below are conditional... Three
  apply unconditionally... Every one of the five is read once") to "Three of the six below are
  conditional... Three apply unconditionally... Every one of the six is read once", since this adds
  a fourth conditional file alongside `--capture-evidence`/`--keep-evidence`.

- [ ] **Step 6: Force single-group `main` in "Determine review mode" when `COMPACT_MODE` is ON**

  In Phase 1's `### Determine review mode (parallel vs single) — decided once, before round 1`
  section, immediately after the existing "**Non-repo artifact round? Skip this entirely — always
  single-group `main`, never parallel.**" bullet and before "**Genuine repo/code-diff round —
  before round 1 ever dispatches, assess the review scope**", insert:

  ```markdown
  **`--compact` session? Also skip this entirely — always single-group `main`, never parallel,
  for the WHOLE session.** When `COMPACT_MODE` is ON (Phase 0 Step 0's decision), this is a hard
  override, not a rejection of the `--compact` request — a review that would otherwise size as
  parallel still runs, just without parallel mode, for the whole session, whenever `--compact` was
  given (see `references/compaction.md`'s "Scope (v1)" section). Parallel mode is explicitly out
  of scope for v1 of thread compaction.
  ```

- [ ] **Step 7: Verify every edit lands and the file still has internally consistent flag counts**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "COMPACT_MODE\|--compact" codex-stream-review/skills/ccs/SKILL.md
  grep -n "four independent\|Four independent\|three independent\|Three independent" codex-stream-review/skills/ccs/SKILL.md
  ```
  Expected: every remaining "three independent"/"Three independent" phrase in the file (if any) is
  now genuinely describing something else — re-check by reading each match; the flag-parsing loop
  and the top-of-file Usage paragraph must both say "four", never a leftover "three".

- [ ] **Step 8: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/SKILL.md
  git commit -m "docs(ccs): SKILL.md --compact flag wiring (parsing, scope, mandatory-read, single-group override)"
  ```

### Task 21: Amend `SKILL.md` — trigger-check integration point, Review history log fields, Final Report bullet

**Files:**
- Modify: `codex-stream-review/skills/ccs/SKILL.md`

**Interfaces:**
- Consumes: `codex-stream-review/skills/ccs/references/compaction.md`'s "Trigger" (Tasks 2-3),
  "Logging" (Task 16), and Final-Report-content sections (Task 16 step 2).
- Produces: the actual call-out in `SKILL.md`'s own round loop that makes `references/
  compaction.md` ever get consulted at runtime; the `schema_version: 3` bump; the durable-field
  list and continuity-recovery extension in "Review history log"; the new Final Report bullet.

- [ ] **Step 1: Read the three exact locations in `SKILL.md` this task edits**

  Re-read: the end of Phase 2 step 6 (the JSONL-append paragraph, immediately after "Clean up this
  round's now-unneeded... temp files"), which is where the trigger-check call-out is inserted,
  since the design doc's own trigger fires "before building the next round's dispatch" — i.e.
  between one round's own append (end of Phase 2) and the next round's Step 1 dispatch (start of
  Phase 1); the `## Review history log (JSONL)` section's field list and its "Read (continuity)"
  subsection; and the `### Final report` section's existing "Execution telemetry" and "Thread
  cleanup results" bullets.

- [ ] **Step 2: Insert the trigger-check call-out at the round-loop integration point**

  In Phase 2, immediately after the sentence "Clean up this round's now-unneeded `.pid`/
  `-out.json`/`-err.log`/`-focus.txt` temp files for EVERY dispatched group..." (the last sentence
  of Phase 2 step 6, before the `### Coverage is a Round-1-only property` subsection), insert a new
  paragraph:

  ```markdown
  **If `COMPACT_MODE` is ON for this session (Phase 0 Step 0's decision): before dispatching the
  NEXT round's Step 1 below, run `references/compaction.md`'s "Trigger" check now against the
  round just appended above.** This is a check-and-possibly-restart step interposed between this
  round's own completed append and the next round's own dispatch — never inside this round's own
  processing, and never before round 1's own dispatch (round 1 has no prior round's usage to check
  yet; the very first opportunity this check ever runs is immediately after round 1's own line is
  appended, deciding whether ROUND 2 becomes a compaction round). If the check triggers, follow
  `references/compaction.md`'s "Restart mechanism"/"Retry topology"/"On failure"/"Ordering on
  success" sections in full for that next round instead of an ordinary `--resume` dispatch — the
  resulting round still counts as one ordinary increment of the round loop (see
  `references/compaction.md`'s "Scope (v1)" section: `MAX_ROUNDS` is unaffected in meaning). When
  `COMPACT_MODE` is OFF, this paragraph is a complete no-op — proceed directly to the next round's
  Step 1 exactly as documented everywhere else in this file.
  ```

- [ ] **Step 3: Bump `schema_version` and extend the durable-field list in "Review history log"**

  In the `## Review history log (JSONL)` section's worked JSON example, change `"schema_version":
  2,` to `"schema_version": 3,` — this is the ONLY place a literal schema_version integer appears
  in `SKILL.md`. In the same section's prose immediately before that example (the paragraph
  starting "**Line schema (one JSON object per round)**"), add, after the existing sentence listing
  what execution telemetry adds: "**Opt-in thread compaction (see `references/compaction.md`,
  read only when `--compact` is ON for this session) adds the full field set that reference file's
  own "Logging" section documents** — `compacted_from_thread`, the `compaction_attempt_*` trio,
  `snapshot_digest_before`/`snapshot_digest_after`, `candidate_snapshot_path`,
  `compaction_attempt_failure_count`, `compaction_disabled_reason`, `retired_snapshot_files`, and
  round-1's own `target.scope_value`/`target.resolved_commit_sha`/`target.original_scope_framing` —
  never present at all for a session where `--compact` was OFF." Add one bullet to this section's
  own per-field explanation list (alongside the existing `execution`/`round_wall_seconds` bullet):
  "`compacted_from_thread`/the `compaction_attempt_*` trio/the snapshot-lineage fields/
  `retired_snapshot_files`/`target.scope_value`/`target.resolved_commit_sha`/
  `target.original_scope_framing`: see `references/compaction.md` (read only when `--compact` is
  ON) for the full construction, retry-topology, and fail-closed rules."

- [ ] **Step 4: Extend continuity recovery for the compaction-disabled latch and the post-append/pre-promotion window**

  In "Review history log"'s `**Read (continuity):**` subsection, immediately after the existing
  `schema_version` mismatch hard-stop paragraph, add: "**When `--compact` was used for this
  session** (any prior round in the log carries a compaction-related field), also run
  `references/compaction.md`'s own continuity-recovery extensions at this same point: reconstruct
  `COMPACTION_CONSECUTIVE_FRESH_FAILURES` and whether `compaction_disabled_reason` was ever set
  (searching the WHOLE log, never only the latest line), and — if the log's own most recent
  compaction event shows a promotion that may not have completed — run the post-append/
  pre-promotion recovery algorithm that reference file's 'Restart mechanism' step 3 describes,
  BEFORE this step's own ordinary per-round snapshot revalidation is ever invoked for the first
  round dispatched after this recovery."

- [ ] **Step 5: Extend Phase 3's terminal cleanup for `PROVISIONAL_SNAPSHOT_FILE`/`retired_snapshot_files`, and the thread enumeration**

  In Phase 3 step 3 ("Clean up session-level temp files"), add `PROVISIONAL_SNAPSHOT_FILE` and
  every path ever recorded in any round's own `retired_snapshot_files` array to the `rm -f` list —
  "only if `--compact` was used this session and either was ever set/recorded." In Phase 3 step 1's
  `GROUP_THREADS` cleanup loop description and the final-verdict artifact's `threads[]`
  construction (step 4), add: "**When `--compact` was used for this session**, also union in every
  `compacted_from_thread` and `compaction_attempt_failed_thread` value found anywhere in the
  session's own JSONL log (see `references/compaction.md`'s 'Durable backstop for abandoned
  threads') — a thread is never permanently unaccounted-for purely because in-memory
  `GROUP_THREADS`/`LEAKED_THREAD_IDS` state did not survive to the end of a long run."

- [ ] **Step 6: Add the Final Report bullet for preserved compaction telemetry**

  In the `### Final report` section's existing "**Execution telemetry (always on)**" bullet,
  append a new sentence at its end: "**When `--compact` was used for this session, also apply
  `references/compaction.md`'s own two Final-Report wording templates** (one for a round whose
  real outcome was the fallback, one for a round whose real outcome was a compaction success that
  followed an earlier failed sub-attempt) for any round carrying a preserved
  `compaction_attempt_execution` value — reported as its own clearly labeled line, distinct from
  that round's own real `execution`/`usage` reporting, never merged into it." In the "**Thread
  cleanup results (per group)**" bullet, add: "When `--compact` was used, also name every
  `compacted_from_thread`/`compaction_attempt_failed_thread` value found in the JSONL log (per
  Phase 3's own extension above), not only `GROUP_THREADS`/`LEAKED_THREAD_IDS` memory."

- [ ] **Step 7: Verify the trigger-check paragraph sits at the correct point in the round loop and every new bullet references `compaction.md` (never inlines its mechanics into `SKILL.md` itself)**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "COMPACT_MODE\|references/compaction.md" codex-stream-review/skills/ccs/SKILL.md
  grep -n "schema_version" codex-stream-review/skills/ccs/SKILL.md
  ```
  Expected: the trigger-check paragraph from Step 2 appears once, between the end of Phase 2 step
  6 and `### Coverage is a Round-1-only property`; `schema_version` now shows `3` everywhere it is
  illustrated (the worked JSON example) — confirm no OTHER place in `SKILL.md` still shows `2`.

- [ ] **Step 8: Commit**

  ```bash
  git add codex-stream-review/skills/ccs/SKILL.md
  git commit -m "docs(ccs): SKILL.md compaction trigger integration, schema_version bump, final report"
  ```

### Task 22: Self-consistency pass — grep-based field/constant/name audit across every touched file

**Files:**
- Modify (if any drift is found): any of `codex-stream-review/skills/ccs/SKILL.md`,
  `codex-stream-review/skills/ccs/references/compaction.md`,
  `codex-stream-review/skills/ccs/references/snapshot-integrity.md`,
  `codex-stream-review/skills/ccs/references/execution-telemetry.md`,
  `codex-stream-review/skills/ccs/references/retry-guards.md`

**Interfaces:**
- Consumes: every field name, constant, and string literal introduced by Tasks 1-21.
- Produces: a corrected, internally-consistent set of files — this task is the plan's own
  Self-Review discipline made explicit as a task, per the design doc's own repeatedly-demonstrated
  pattern (54 rounds of adversarial review, several of which found EXACTLY this class of "same
  concept, two spellings" bug).

- [ ] **Step 1: Grep every durable field name across all five files and confirm one spelling each**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  FILES="codex-stream-review/skills/ccs/SKILL.md codex-stream-review/skills/ccs/references/compaction.md codex-stream-review/skills/ccs/references/snapshot-integrity.md codex-stream-review/skills/ccs/references/execution-telemetry.md codex-stream-review/skills/ccs/references/retry-guards.md"
  for field in compacted_from_thread compaction_attempt_failed_thread compaction_attempt_execution compaction_attempt_coverage compaction_attempt_failure_count compaction_disabled_reason snapshot_digest_before snapshot_digest_after candidate_snapshot_path retired_snapshot_files "target.scope_value" "target.resolved_commit_sha" "target.original_scope_framing" COMPACTION_BASELINE_TOKENS COMPACTION_CONSECUTIVE_FRESH_FAILURES PROVISIONAL_SNAPSHOT_FILE RETIRED_SNAPSHOT_FILES COMPACT_DIGEST COMPACT_THRESHOLD COMPACT_BYTE_BUDGET CLOSED_CLAIM_LIMIT COMPACTION_MAX_CONSECUTIVE_FRESH_FAILURES COMPACT_MODE; do
    echo "=== $field ==="
    grep -rn -- "$field" $FILES | wc -l
  done
  ```
  Expected: every field/constant appears at least once (a zero count means a task above failed to
  actually introduce it — go back and fix that task); manually scan for any near-miss spelling
  (e.g. `compaction_attempt_failedThread`, `COMPACT_Threshold`, `retired_snapshot_file` singular)
  by re-running the same greps with looser patterns (`grep -rni "compact.*threshold"`,
  `grep -rni "retired.snapshot"`) and comparing hit counts — any hit found by the loose pattern but
  NOT the exact one above is a spelling bug; fix it via Edit in whichever file has it wrong,
  matching this plan's own Global Constraints section as the source of truth.

- [ ] **Step 2: Grep every `compaction_disabled_reason` string value and confirm exactly four, spelled identically everywhere**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -rno '"baseline_at_or_above_threshold"\|"baseline_unusable"\|"repeated_fresh_dispatch_failure"\|"byte_budget_exceeded"' codex-stream-review/skills/ccs/references/compaction.md codex-stream-review/skills/ccs/SKILL.md | sort | uniq -c
  ```
  Expected: each of the four strings appears one or more times, always spelled identically — fix
  any variant spelling found.

- [ ] **Step 3: Check every "see Task N" / "see X above/below" cross-reference this plan itself made resolves to real content**

  Since this plan's own tasks used forward/backward references between `compaction.md` sections
  (e.g. Task 2's "see Byte-budget preflight below" resolving to Task 4's actual section), confirm
  by heading-name search that every section name referenced in prose actually exists as a heading:

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  grep -n "^## \|^### " codex-stream-review/skills/ccs/references/compaction.md
  ```
  Cross-check this full heading list against every `"see ... above"`/`"see ... below"` phrase
  inside `compaction.md` itself (manual read — there is no mechanical way to verify prose-name
  cross-references beyond a heading-list comparison) — fix any reference to a heading name that
  doesn't literally exist (e.g. a task above might have written "see 'Snapshot candidate lifecycle'
  above" when the actual heading Task 7 created was "Step 3 — repo-diff sessions: snapshot
  candidate lifecycle" — normalize to match).

  **Known heading-name normalization to apply during this step:** Task 9's own prose says "see
  'Retired-snapshot tracking' below" and "see 'Retired- and provisional-snapshot durability'
  section" — but Task 9 folded BOTH of those design-doc section titles into ONE `compaction.md`
  passage with no heading of its own (it lives inside `### Step 3`, not under a separate `##`/`###`
  heading). Fix these two cross-references (in Tasks 9, 14, 15's OWN resulting `compaction.md`
  text — search for the literal strings `"Retired-snapshot tracking"` and `"Retired- and
  provisional-snapshot durability"` inside `compaction.md`) to instead read "see 'Restart mechanism'
  step 3 above", matching where that content actually lives.

- [ ] **Step 4: Run a full read-through of `compaction.md` end to end, checking against the design doc's own Self-Review criteria**

  Read the complete, final `codex-stream-review/skills/ccs/references/compaction.md` file. Check,
  section by section, against the original design doc
  (`/Users/hmc7279235/Work/Develop/plugins/docs/2026-09-09-ccs-opt-in-compaction-design.md`): does
  every numbered fix/correction in the design doc (identifiable by its own "new — closes a real gap
  found during design review" / "corrected — closes a real gap" framing) have a corresponding
  sentence in `compaction.md`? The design doc's own density means this is the single highest-risk
  step for an accidentally-dropped rule — if you find a design-doc paragraph with no corresponding
  `compaction.md` text, add it now via Edit, in the section it thematically belongs to (matching
  the section-mapping this plan's own Tasks 1-16 already established), never as prose in this
  plan document.

- [ ] **Step 5: Commit any fixes found**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  git add -A codex-stream-review/skills/ccs/
  git commit -m "docs(ccs): self-consistency fixes across compaction feature docs" --allow-empty
  ```
  (`--allow-empty` only matters if Steps 1-4 found nothing to fix — do not rely on it; if fixes
  were made, the commit is non-empty and this flag is harmless either way.)

### Task 23: Eval scenario `compact-trigger-uncommitted-success`

**Files:**
- Create: `codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/setup.sh`
- Create: `codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/README.md`
- Create: `codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/expect.sh`

**Interfaces:**
- Consumes: `codex-stream-review/evals/lib/common.sh`'s `eval_make_fixture_repo` helper,
  `tests/fixtures/fake-codex`'s `FAKE_CODEX_USAGE_JSON`/`FAKE_CODEX_INVOCATION_LOG`/
  `FAKE_CODEX_CLEANUP_OK` env vars, `codex-stream-review/evals/check-result.sh`.
- Produces: the first eval scenario proving the basic case end to end — a round whose own usage
  crosses `COMPACT_THRESHOLD` causes the VERY NEXT round to be a genuine fresh restart (never
  `--resume`), the old thread ends up `"kind":"leaked"`/`"cleanup":"deleted"` in the final
  `.result.json`, and the session still reaches `CLEAN`.

- [ ] **Step 1: Write `setup.sh`**

  Follow the exact structure of `codex-stream-review/evals/scenarios/retry-exhausted-round1-fresh-
  fallback/setup.sh` (already read during this plan's research phase) — a fixture repo, a symlinked
  fake `codex`, a fixed invocation-log path, and a `cat <<'EOF'` block spelling out the exact
  expected sequence for whoever (human or agent) drives the live `/ccs` invocation:

  ```bash
  #!/usr/bin/env bash
  # Scenario: compact-trigger-uncommitted-success
  # Targets: references/compaction.md's basic trigger-and-restart path for --uncommitted scope --
  # round 1's own execution.usage.input_tokens crosses COMPACT_THRESHOLD (8,000,000), so round 2
  # becomes a genuine fresh --uncommitted COMPACTION round (never --resume) instead of an ordinary
  # resume. The compaction dispatch succeeds on its first attempt with a comfortably-under-threshold
  # baseline, so no circuit breaker engages and the session converges CLEAN at round 2.
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../../lib/common.sh"

  REPO_DIR="$(eval_make_fixture_repo compact-trigger-uncommitted-success)"
  BIN_DIR="$(mktemp -d)"
  ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
  INVOCATION_LOG="/tmp/ccs-eval-compact-trigger-uncommitted-success-invocation.log"
  : > "$INVOCATION_LOG"

  echo "REPO_DIR=$REPO_DIR"
  echo "BIN_DIR=$BIN_DIR"
  echo "INVOCATION_LOG=$INVOCATION_LOG"
  cat <<'EOF'

  Next step (run by hand or have a Claude Code agent do it): invoke
  codex-stream-review:ccs --compact against REPO_DIR, with BIN_DIR prepended to PATH on EVERY
  Bash call made during this run, and FAKE_CODEX_INVOCATION_LOG set to the printed INVOCATION_LOG
  path on every dispatch/cleanup call. Task text: "--compact review the uncommitted change in this
  fixture repo".

  Expected sequence, per skills/ccs/references/compaction.md's Trigger + Restart mechanism:
    1. Round 1: fresh --uncommitted dispatch, FAKE_CODEX_SCENARIO=normal,
       FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}' -- CLEAN verdict, a
       real threadId (call it A) is captured. execution.usage.input_tokens (9,000,000) is >=
       COMPACT_THRESHOLD (8,000,000) -- this triggers compaction for round 2.
    2. Between round 1's own append and round 2's dispatch: the existing round-2+ snapshot
       revalidation runs first (it passes, nothing has touched SNAPSHOT_FILE), THEN the threshold
       check fires and compaction is attempted for round 2.
    3. Round 2 (the COMPACTION round): build and verify COMPACT_DIGEST (round 1 had zero open
       claims, since round 1 was itself CLEAN with no findings -- the digest's own open-claim
       section is empty, closed-claim section is empty too). Dispatch a FRESH --uncommitted call
       (never --resume) against the SAME REPO_DIR, focus text = COMPACT_DIGEST + the original Why/
       Scope (from target.original_scope_framing) + the SCOPE CONSTRAINT/collaboration frame (no
       DISPOSITION requests needed, since there are no open claims to ask about).
       FAKE_CODEX_SCENARIO=normal, FAKE_CODEX_USAGE_JSON='{"input_tokens":500000,
       "output_tokens":30000}' -- CLEAN verdict, a NEW real threadId (call it B) is captured. This
       becomes COMPACTION_BASELINE_TOKENS=500000, comfortably under COMPACT_THRESHOLD -- no circuit
       breaker engages.
    4. Ordering on success: the new thread B is added to LEAKED_THREAD_IDS provisionally, round 2's
       JSONL line is appended (target.scope="uncommitted", compacted_from_thread=A,
       candidate_snapshot_path=<mktemp path>, snapshot_digest_before=<round 1's digest>,
       snapshot_digest_after=<round 2's candidate digest>, compaction_attempt_failure_count=0,
       coverage_source={"status":"complete",...}), append-verify passes. THEN promotion: re-hash
       both the active SNAPSHOT_FILE (against snapshot_digest_before) and the candidate (against
       snapshot_digest_after) -- both pass -- then `mv` the candidate onto SNAPSHOT_FILE, advance
       the remembered SNAPSHOT_DIGEST. Thread B becomes the new GROUP_THREADS entry; thread A moves
       to LEAKED_THREAD_IDS in its place.
    5. Session converges CLEAN at round 2 (zero open claims either round, both rounds' own
       findings were CLEAN).
    6. Phase 3: --cleanup B (GROUP_THREADS, kind current) AND --cleanup A (LEAKED_THREAD_IDS, kind
       leaked) -- both FAKE_CODEX_CLEANUP_OK=1 so both genuinely succeed.

  Expected exit_state: CLEAN, round_count: 2. threads: two entries --
  {"group":"main","thread_id":B,"kind":"current","cleanup":"deleted"} and
  {"group":"main","thread_id":A,"kind":"leaked","cleanup":"deleted"}.
  Invocation log: exactly 2 "mode=fresh" lines (round 1's dispatch and round 2's compaction
  dispatch -- two DIFFERENT thread_id values, A then B) and ZERO "mode=resume" lines (round 2 is a
  FRESH dispatch, never a --resume, which is the whole point this scenario proves).
  EOF
  ```

- [ ] **Step 2: Write `README.md`**

  Follow the exact structure of the `retry-exhausted-round1-fresh-fallback/README.md` already
  read during this plan's research phase — a **Group**/**Targets** header, a short "How this
  differs from..." comparison (there is no sibling scenario yet, so instead state what this
  scenario is the FIRST to exercise), a "Mechanical setup" section naming the exact env vars per
  step, "How to run", and "Expected result":

  ```markdown
  # Scenario: compact-trigger-uncommitted-success

  **Group:** F (`compaction.md` opt-in-feature coverage) -- the FIRST and most basic compaction
  scenario: a single trigger, a single successful fresh restart, no retries, no circuit breakers.
  Every other compaction scenario in this suite builds on this one's basic shape.

  **Targets:** `references/compaction.md`'s "Trigger" section (the threshold check firing after
  round 1) and "Restart mechanism" section (a genuinely FRESH `--uncommitted` dispatch for round 2,
  never `--resume`) for the ordinary, nothing-goes-wrong path -- confirms the old thread ends up
  `"kind":"leaked"`/`"cleanup":"deleted"` in the final result (never silently dropped), and that
  `round_count` still increments normally (compaction consumes an ordinary round-counter
  increment, per "Scope (v1)").

  ## Mechanical setup

  Needs the fake-`codex` binary on `$PATH` for every Bash call during this run. Round 1's dispatch
  needs `FAKE_CODEX_SCENARIO=normal` and `FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,
  "output_tokens":50000}'` (over `COMPACT_THRESHOLD`, triggering compaction for round 2). Round 2's
  (compaction) dispatch needs `FAKE_CODEX_SCENARIO=normal` and `FAKE_CODEX_USAGE_JSON=
  '{"input_tokens":500000,"output_tokens":30000}'` (comfortably under threshold, so
  `COMPACTION_BASELINE_TOKENS` never re-triggers anything). Both `--cleanup` calls need
  `FAKE_CODEX_CLEANUP_OK=1`. `FAKE_CODEX_INVOCATION_LOG` must be set to the fixed path `setup.sh`
  prints on every call.

  This invocation-count check is best-effort, matching every other scenario in this suite: if the
  invocation log has already been cleaned up by the time `expect.sh` runs, that one check is
  skipped with a WARN instead of failing the whole scenario.

  ## How to run

  ```bash
  bash codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/setup.sh
  ```

  Then invoke `codex-stream-review:ccs --compact` against `REPO_DIR` with the task text:

  > --compact review the uncommitted change in this fixture repo

  Locate the resulting `.result.json` and validate it:

  ```bash
  bash codex-stream-review/evals/check-result.sh <result.json> compact-trigger-uncommitted-success
  ```

  ## Expected result

  - `exit_state`: `"CLEAN"`, `round_count`: `2`
  - `threads`: two entries -- `{"group":"main","thread_id":B,"kind":"current","cleanup":"deleted"}`
    and `{"group":"main","thread_id":A,"kind":"leaked","cleanup":"deleted"}`
  - The fixed invocation log shows exactly 2 `mode=fresh ` lines (two DIFFERENT `thread_id` values
    -- A then B) and ZERO `mode=resume ` lines.
  ```

- [ ] **Step 3: Write `expect.sh`**

  Follow the exact structure of `retry-exhausted-round1-fresh-fallback/expect.sh` (schema
  validation already run by `check-result.sh` before this script runs):

  ```bash
  #!/usr/bin/env bash
  # Scenario-specific assertions for compact-trigger-uncommitted-success, invoked by
  # check-result.sh as `expect.sh <result.json>`. Schema structure already validated by
  # check-result.sh itself before this runs.
  set -euo pipefail
  RESULT_FILE="${1:?usage: expect.sh <result.json>}"
  INVOCATION_LOG="/tmp/ccs-eval-compact-trigger-uncommitted-success-invocation.log"

  FAIL=0
  check() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" != "$expected" ]; then
      echo "compact-trigger-uncommitted-success: FAIL -- $desc: expected [$expected], got [$actual]" >&2
      FAIL=1
    fi
  }

  check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
  check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "2"

  CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
  check "count of threads[] with kind==current" "$CURRENT_COUNT" "1"

  LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
  check "count of threads[] with kind==leaked" "$LEAKED_COUNT" "1"

  NOT_DELETED="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
  if [ "$NOT_DELETED" != "0" ]; then
    echo "compact-trigger-uncommitted-success: FAIL -- expected every threads[] entry cleanup==deleted, found $NOT_DELETED that aren't" >&2
    FAIL=1
  fi

  CURRENT_ID="$(jq -r '[.threads[]? | select(.kind == "current")][0].thread_id // ""' "$RESULT_FILE")"
  LEAKED_ID="$(jq -r '[.threads[]? | select(.kind == "leaked")][0].thread_id // ""' "$RESULT_FILE")"
  if [ -n "$CURRENT_ID" ] && [ -n "$LEAKED_ID" ] && [ "$CURRENT_ID" = "$LEAKED_ID" ]; then
    echo "compact-trigger-uncommitted-success: FAIL -- current and leaked thread_id must differ, both are [$CURRENT_ID]" >&2
    FAIL=1
  fi

  if [ ! -f "$INVOCATION_LOG" ]; then
    echo "compact-trigger-uncommitted-success: WARN -- invocation log not found at $INVOCATION_LOG (ephemeral /tmp diagnostic, not durable -- skipping invocation-count check)" >&2
  else
    FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
    RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
    check "invocation log fresh-mode count" "$FRESH_COUNT" "2"
    check "invocation log resume-mode count" "$RESUME_COUNT" "0"

    FRESH_DISTINCT_IDS="$(grep '^mode=fresh ' "$INVOCATION_LOG" | sed -E 's/^mode=fresh thread_id=([^ ]*).*/\1/' | sort -u | wc -l | tr -d ' ')"
    check "distinct thread_id values across the 2 fresh invocations" "$FRESH_DISTINCT_IDS" "2"
  fi

  exit "$FAIL"
  ```

- [ ] **Step 4: Make the two shell scripts executable and verify they at least parse**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  chmod +x codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/setup.sh
  chmod +x codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/expect.sh
  bash -n codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/setup.sh
  bash -n codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/expect.sh
  ```
  Expected: both `bash -n` syntax checks exit 0 with no output.

- [ ] **Step 5: Run `setup.sh` once to confirm the fixture repo and fake-codex symlink are created without error**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  bash codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/setup.sh
  ```
  Expected: prints `REPO_DIR=...`, `BIN_DIR=...`, `INVOCATION_LOG=...` followed by the instructions
  block, with no error. (Actually driving a live `/ccs --compact` session against this fixture and
  validating the resulting `.result.json` is a separate, later verification step — this task's own
  scope is authoring a correct, runnable scenario harness, matching how every existing scenario in
  this suite was itself authored and is later exercised by a human or agent driving a real session.)

- [ ] **Step 6: Commit**

  ```bash
  git add codex-stream-review/evals/scenarios/compact-trigger-uncommitted-success/
  git commit -m "test(ccs): add compact-trigger-uncommitted-success eval scenario"
  ```

### Task 24: Eval scenario `compact-baseline-still-over-threshold`

**Files:**
- Create: `codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/setup.sh`
- Create: `codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/README.md`
- Create: `codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/expect.sh`

**Interfaces:**
- Consumes: the same helpers as Task 23.
- Produces: the eval scenario proving the benefit-free-restart-loop guard — a compaction round
  whose OWN fresh-restart usage is ALSO `>= COMPACT_THRESHOLD` latches
  `compaction_disabled_reason: "baseline_at_or_above_threshold"` and never attempts compaction
  again for the rest of the session.

- [ ] **Step 1: Write `setup.sh`**

  Same structure as Task 23's, adapted:

  ```bash
  #!/usr/bin/env bash
  # Scenario: compact-baseline-still-over-threshold
  # Targets: references/compaction.md's "Benefit-free-restart-loop guard" -- a compaction round's
  # OWN freshly-restarted execution.usage.input_tokens is ALSO >= COMPACT_THRESHOLD, so
  # compaction_disabled_reason is set to "baseline_at_or_above_threshold" and compaction is
  # permanently disabled for the rest of THIS session -- round 3's own high usage must NOT trigger
  # a second compaction attempt.
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../../lib/common.sh"

  REPO_DIR="$(eval_make_fixture_repo compact-baseline-still-over-threshold)"
  BIN_DIR="$(mktemp -d)"
  ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
  INVOCATION_LOG="/tmp/ccs-eval-compact-baseline-still-over-threshold-invocation.log"
  : > "$INVOCATION_LOG"

  echo "REPO_DIR=$REPO_DIR"
  echo "BIN_DIR=$BIN_DIR"
  echo "INVOCATION_LOG=$INVOCATION_LOG"
  cat <<'EOF'

  Next step (run by hand or have a Claude Code agent do it): invoke
  codex-stream-review:ccs --compact against REPO_DIR, task text:
  "--compact review the uncommitted change in this fixture repo".

  Expected sequence:
    1. Round 1: fresh --uncommitted, FAKE_CODEX_SCENARIO=normal, one real finding of severity
       "low" so the session does NOT converge CLEAN immediately (keeps the loop running past round
       1), FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}' -- threadId A,
       triggers compaction for round 2.
    2. Round 2 (COMPACTION round): fresh --uncommitted (never --resume), digest carries the one
       open claim from round 1 verbatim. FAKE_CODEX_SCENARIO=normal,
       FAKE_CODEX_USAGE_JSON='{"input_tokens":8500000,"output_tokens":50000}' (this compaction
       round's OWN freshly-restarted usage is ITSELF >= COMPACT_THRESHOLD) -- threadId B, a
       DISPOSITION marker resolving the one open claim (so no claim stays open). Round 2's own
       dispatch SUCCEEDS (ok:true) -- but because COMPACTION_BASELINE_TOKENS (8,500,000) is itself
       >= COMPACT_THRESHOLD (8,000,000), record compaction_disabled_reason=
       "baseline_at_or_above_threshold" on round 2's own JSONL line, alongside the normal success
       fields (compacted_from_thread=A, candidate_snapshot_path, snapshot_digest_before/after,
       compaction_attempt_failure_count=0). Session converges CLEAN at round 2 (the one claim was
       just resolved).
    3. Because this fixture needs to prove compaction stays DISABLED, extend to a THIRD round
       instead of converging at round 2: have round 2 raise a NEW low-severity finding (not
       resolved) so the loop continues to round 3, with FAKE_CODEX_USAGE_JSON on round 2 still
       >=COMPACT_THRESHOLD as above. Round 3: an ordinary --resume dispatch (never a second
       compaction attempt, since compaction_disabled_reason is already latched) --
       FAKE_CODEX_SCENARIO=normal, FAKE_CODEX_USAGE_JSON='{"input_tokens":8700000,
       "output_tokens":40000}' (deliberately ALSO over COMPACT_THRESHOLD, to prove the trigger
       check no-ops immediately once disabled rather than attempting a second compaction) -- a
       DISPOSITION marker resolves round 2's new claim. Session converges CLEAN at round 3, using
       thread B throughout (never touched again after round 2's promotion).
    4. Phase 3: --cleanup B (current) AND --cleanup A (leaked) -- both FAKE_CODEX_CLEANUP_OK=1.

  Expected exit_state: CLEAN, round_count: 3. threads: current=B, leaked=A, both cleanup=deleted.
  Invocation log: exactly 2 "mode=fresh" lines (round 1, round 2) and exactly 1 "mode=resume" line
  (round 3, against B) -- proof round 3 did NOT attempt a second fresh compaction dispatch despite
  its own usage also exceeding COMPACT_THRESHOLD.
  EOF
  ```

- [ ] **Step 2: Write `README.md`**

  ```markdown
  # Scenario: compact-baseline-still-over-threshold

  **Group:** F (`compaction.md` opt-in-feature coverage).

  **Targets:** `references/compaction.md`'s "Benefit-free-restart-loop guard" — a compaction
  round's own freshly-restarted `execution.usage.input_tokens` is ALSO `>= COMPACT_THRESHOLD`,
  proving the underlying content itself (not accumulated resumed-thread history) is intrinsically
  large. Confirms `compaction_disabled_reason: "baseline_at_or_above_threshold"` is latched on the
  compaction round's own line, AND that a LATER round's own high usage (round 3, also over
  threshold) does NOT trigger a second compaction attempt — the trigger check must no-op
  immediately once disabled, per the durable-latch contract.

  ## Mechanical setup

  Round 1: `FAKE_CODEX_SCENARIO=normal`, one low-severity finding,
  `FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}'`. Round 2 (compaction):
  `FAKE_CODEX_SCENARIO=normal`, a `DISPOSITION ... RESOLVED` marker for round 1's claim plus one
  NEW low-severity finding, `FAKE_CODEX_USAGE_JSON='{"input_tokens":8500000,
  "output_tokens":50000}'` (itself over threshold). Round 3 (ordinary resume, never a second
  compaction): `FAKE_CODEX_SCENARIO=normal`, a `DISPOSITION ... RESOLVED` marker for round 2's new
  claim, `FAKE_CODEX_USAGE_JSON='{"input_tokens":8700000,"output_tokens":40000}'` (also over
  threshold, deliberately, to prove no second attempt happens). Both `--cleanup` calls need
  `FAKE_CODEX_CLEANUP_OK=1`. `FAKE_CODEX_INVOCATION_LOG` set on every call.

  ## How to run

  ```bash
  bash codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/setup.sh
  ```

  Then invoke `codex-stream-review:ccs --compact` against `REPO_DIR`, task text:

  > --compact review the uncommitted change in this fixture repo

  ```bash
  bash codex-stream-review/evals/check-result.sh <result.json> compact-baseline-still-over-threshold
  ```

  ## Expected result

  - `exit_state`: `"CLEAN"`, `round_count`: `3`
  - `threads`: current = B (round 2's new thread), leaked = A (round 1's abandoned thread), both
    `cleanup: "deleted"`
  - Invocation log: exactly 2 `mode=fresh` lines, exactly 1 `mode=resume` line (round 3, against
    B) — proving round 3 never attempted a second compaction dispatch.
  ```

- [ ] **Step 3: Write `expect.sh`**

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  RESULT_FILE="${1:?usage: expect.sh <result.json>}"
  INVOCATION_LOG="/tmp/ccs-eval-compact-baseline-still-over-threshold-invocation.log"

  FAIL=0
  check() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" != "$expected" ]; then
      echo "compact-baseline-still-over-threshold: FAIL -- $desc: expected [$expected], got [$actual]" >&2
      FAIL=1
    fi
  }

  check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
  check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "3"

  CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
  check "count of threads[] with kind==current" "$CURRENT_COUNT" "1"
  LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
  check "count of threads[] with kind==leaked" "$LEAKED_COUNT" "1"

  if [ ! -f "$INVOCATION_LOG" ]; then
    echo "compact-baseline-still-over-threshold: WARN -- invocation log not found at $INVOCATION_LOG (ephemeral, skipping)" >&2
  else
    FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
    RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
    check "invocation log fresh-mode count" "$FRESH_COUNT" "2"
    check "invocation log resume-mode count (round 3 only -- no second compaction attempt)" "$RESUME_COUNT" "1"
  fi

  exit "$FAIL"
  ```

  **Note on `compaction_disabled_reason` verification:** `schemas/interactive-result.schema.json`
  does not carry per-round JSONL fields (it is the SESSION-level durable result, not the JSONL
  log), so `compaction_disabled_reason` cannot be asserted from `<result.json>` alone. This
  scenario's own `expect.sh` therefore only verifies the OBSERVABLE, end-to-end consequence (round
  3 dispatches via `--resume`, not a second fresh compaction attempt) rather than the internal
  latch value directly — a human or agent driving this scenario live should additionally inspect
  the session's own `.jsonl` log (`~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-
  slug>/<session-id>.jsonl`) and confirm round 2's own line carries
  `"compaction_disabled_reason":"baseline_at_or_above_threshold"` and round 3's own line carries no
  `compacted_from_thread`/candidate fields at all — this manual check is documented in the
  scenario's own `README.md` "Expected result" section (add one bullet there noting it) but is not
  mechanically asserted by `expect.sh`, matching how other JSONL-log-only facts (e.g. exact retry
  counts within a single round) are documented, not asserted, elsewhere in this eval suite.

- [ ] **Step 4: Add the JSONL-log manual-check bullet to `README.md`'s "Expected result" section**

  Append to the `## Expected result` list in `README.md`: "- The session's own `.jsonl` log: round
  2's own line carries `\"compaction_disabled_reason\":\"baseline_at_or_above_threshold\"`; round
  3's own line carries no `compacted_from_thread`/`candidate_snapshot_path` fields at all (manual
  check — not mechanically asserted by `expect.sh`, since `<result.json>` has no per-round JSONL
  content)."

- [ ] **Step 5: Make scripts executable, syntax-check, and dry-run `setup.sh`**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  chmod +x codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/setup.sh
  chmod +x codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/expect.sh
  bash -n codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/setup.sh
  bash -n codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/expect.sh
  bash codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/setup.sh
  ```
  Expected: both syntax checks pass; the dry run prints `REPO_DIR=...`/`BIN_DIR=...`/
  `INVOCATION_LOG=...` plus the instructions block with no error.

- [ ] **Step 6: Commit**

  ```bash
  git add codex-stream-review/evals/scenarios/compact-baseline-still-over-threshold/
  git commit -m "test(ccs): add compact-baseline-still-over-threshold eval scenario"
  ```

### Task 25: Eval scenario `compact-byte-budget-exceeded`

**Files:**
- Create: `codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/setup.sh`
- Create: `codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/README.md`
- Create: `codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/expect.sh`

**Interfaces:**
- Consumes: the same helpers as Tasks 23-24.
- Produces: the eval scenario proving the byte-budget preflight — an assembled focus text (digest +
  framing) that itself exceeds `COMPACT_BYTE_BUDGET` latches
  `compaction_disabled_reason: "byte_budget_exceeded"` WITHOUT ever dispatching a real fresh call
  for that attempt, falling straight through to the ordinary `--resume` fallback.

- [ ] **Step 1: Write `setup.sh`**

  This scenario's own distinguishing mechanic (unlike Tasks 23-24) is that the byte-budget
  preflight is a LOCAL, pre-dispatch check — no real wrapper call happens for the compaction
  attempt itself, only the fallback `--resume`. Drive this by giving round 1 a finding whose own
  `evidence` text is deliberately enormous (well over 120,000 bytes on its own), so the assembled
  digest's open-claim section alone blows the budget:

  ```bash
  #!/usr/bin/env bash
  # Scenario: compact-byte-budget-exceeded
  # Targets: references/compaction.md's "Byte-budget preflight" -- the assembled focus text
  # (COMPACT_DIGEST + Why/Scope/SCOPE-CONSTRAINT) exceeds COMPACT_BYTE_BUDGET (120,000 bytes)
  # BEFORE any real dispatch is attempted for the compaction candidate -- this is a LOCAL,
  # pre-dispatch latch (compaction_disabled_reason="byte_budget_exceeded"), never a wrapper
  # ok:false response. The round falls straight through to an ordinary --resume fallback on the
  # OLD thread, with ZERO extra fresh dispatches for the failed compaction attempt itself.
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../../lib/common.sh"

  REPO_DIR="$(eval_make_fixture_repo compact-byte-budget-exceeded)"
  BIN_DIR="$(mktemp -d)"
  ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
  INVOCATION_LOG="/tmp/ccs-eval-compact-byte-budget-exceeded-invocation.log"
  : > "$INVOCATION_LOG"

  # A single finding whose own "evidence" field is ~130,000 bytes of repeated text -- large enough
  # on its own that the open-claim section of COMPACT_DIGEST alone exceeds COMPACT_BYTE_BUDGET
  # (120,000 bytes), regardless of anything else in the assembled focus text.
  HUGE_EVIDENCE_JSON="$(python3 -c "
  import json
  print(json.dumps('x' * 130000))
  ")"
  ROUND1_ANSWER_FILE="$(mktemp)"
  python3 -c "
  import json
  print(json.dumps({
    'verdict': 'ISSUES',
    'findings': [{'file':'lib.py','line':2,'severity':'low','summary':'huge finding for byte-budget test','evidence': $HUGE_EVIDENCE_JSON,'verification':'v'}],
    'summary': None,
    'dimensions': {d: {'status':'checked','evidence':'e'} for d in ['correctness','security','performance','reuse','contracts','resources_concurrency','intent']}
  }))
  " > "$ROUND1_ANSWER_FILE"

  echo "REPO_DIR=$REPO_DIR"
  echo "BIN_DIR=$BIN_DIR"
  echo "INVOCATION_LOG=$INVOCATION_LOG"
  echo "ROUND1_ANSWER_FILE=$ROUND1_ANSWER_FILE"
  cat <<'EOF'

  Next step (run by hand or have a Claude Code agent do it): invoke
  codex-stream-review:ccs --compact against REPO_DIR, task text:
  "--compact review the uncommitted change in this fixture repo".

  Expected sequence:
    1. Round 1: fresh --uncommitted, FAKE_CODEX_SCENARIO=normal,
       FAKE_CODEX_FINAL_ANSWER="$(cat "$ROUND1_ANSWER_FILE")" (the huge-evidence finding above),
       FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}' -- threadId A,
       triggers compaction for round 2 (over COMPACT_THRESHOLD).
    2. Round 2 (compaction ATTEMPT, not a real dispatch): build COMPACT_DIGEST -- the one open
       claim's own evidence text (~130,000 bytes) is included verbatim (open claims are never
       truncated). Measure the assembled focus text (digest + Why/Scope/SCOPE-CONSTRAINT) exactly
       via `wc -c`: comfortably over COMPACT_BYTE_BUDGET (120,000 bytes) from the evidence text
       alone. This is a LOCAL preflight failure -- NO fresh dispatch is ever attempted for the
       compaction candidate. Record compaction_disabled_reason="byte_budget_exceeded" on round 2's
       own JSONL line (compaction_attempt_failure_count is NOT incremented for this specific
       cause). Fall through to an ORDINARY --resume dispatch against thread A (the still-alive old
       thread) as round 2's real outcome -- FAKE_CODEX_SCENARIO=normal,
       FAKE_CODEX_USAGE_JSON='{"input_tokens":200000,"output_tokens":10000}', with a DISPOSITION
       marker resolving round 1's own huge finding (RETRACTED or RESOLVED -- pick RESOLVED, "fixed
       the underlying issue"). Session converges CLEAN at round 2, still using thread A throughout
       (compaction never actually replaced it).
    3. Phase 3: --cleanup A only (GROUP_THREADS -- there was never a second thread B, since the
       compaction attempt never dispatched at all) -- FAKE_CODEX_CLEANUP_OK=1.

  Expected exit_state: CLEAN, round_count: 2. threads: exactly ONE entry --
  {"group":"main","thread_id":A,"kind":"current","cleanup":"deleted"} -- NO "leaked" entry at all,
  since no new thread was ever created for the failed compaction attempt.
  Invocation log: exactly 1 "mode=fresh" line (round 1 only) and exactly 1 "mode=resume" line
  (round 2's fallback, against A) -- proof the compaction ATTEMPT itself never reached a real
  dispatch call at all.
  EOF
  ```

- [ ] **Step 2: Write `README.md`**

  ```markdown
  # Scenario: compact-byte-budget-exceeded

  **Group:** F (`compaction.md` opt-in-feature coverage).

  **Targets:** `references/compaction.md`'s "Byte-budget preflight" — the ONLY compaction-failure
  path that is a purely LOCAL, pre-dispatch check with no real wrapper call for the failed attempt
  at all. Confirms: (1) `compaction_disabled_reason: "byte_budget_exceeded"` is latched without a
  fresh dispatch ever occurring; (2) `compaction_attempt_failure_count` is NOT incremented for this
  specific cause (it has its own dedicated, immediate latch — see "Trigger"'s circuit-breaker
  section); (3) the final `threads[]` array has exactly ONE entry (the original thread, never
  replaced) with no `"kind":"leaked"` entry at all, since no second thread was ever created.

  ## Mechanical setup

  Round 1's own finding carries a deliberately huge (~130,000-byte) `evidence` field so the open-
  claim section of `COMPACT_DIGEST` alone exceeds `COMPACT_BYTE_BUDGET` (120,000 bytes) —
  `FAKE_CODEX_FINAL_ANSWER` is set to a pre-built JSON verdict string containing this finding,
  `FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,...}'` (over threshold, triggering compaction).
  Round 2's real (fallback) dispatch is an ordinary `--resume` with
  `FAKE_CODEX_USAGE_JSON='{"input_tokens":200000,...}'` and a `DISPOSITION ... RESOLVED` marker
  closing round 1's huge finding. `--cleanup` needs `FAKE_CODEX_CLEANUP_OK=1`.
  `FAKE_CODEX_INVOCATION_LOG` set on every call.

  ## How to run

  ```bash
  bash codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/setup.sh
  ```

  Then invoke `codex-stream-review:ccs --compact` against `REPO_DIR`, task text:

  > --compact review the uncommitted change in this fixture repo

  ```bash
  bash codex-stream-review/evals/check-result.sh <result.json> compact-byte-budget-exceeded
  ```

  ## Expected result

  - `exit_state`: `"CLEAN"`, `round_count`: `2`
  - `threads`: exactly ONE entry, `kind: "current"`, `cleanup: "deleted"` — no `"leaked"` entry.
  - Invocation log: exactly 1 `mode=fresh` line (round 1), exactly 1 `mode=resume` line (round 2's
    fallback) — proving the compaction ATTEMPT itself never reached a real dispatch.
  - The session's own `.jsonl` log: round 2's own line carries
    `"compaction_disabled_reason":"byte_budget_exceeded"` and NO `compaction_attempt_failure_count`
    field at all (manual check — not mechanically asserted by `expect.sh`, since `<result.json>`
    has no per-round JSONL content).
  ```

- [ ] **Step 3: Write `expect.sh`**

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  RESULT_FILE="${1:?usage: expect.sh <result.json>}"
  INVOCATION_LOG="/tmp/ccs-eval-compact-byte-budget-exceeded-invocation.log"

  FAIL=0
  check() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" != "$expected" ]; then
      echo "compact-byte-budget-exceeded: FAIL -- $desc: expected [$expected], got [$actual]" >&2
      FAIL=1
    fi
  }

  check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
  check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "2"

  THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
  check "total threads[] count (never a second thread for a byte-budget-only failure)" "$THREAD_COUNT" "1"

  LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
  check "count of threads[] with kind==leaked (must be zero)" "$LEAKED_COUNT" "0"

  CLEANUP="$(jq -r '.threads[0].cleanup' "$RESULT_FILE")"
  check "the one thread's cleanup" "$CLEANUP" "deleted"

  if [ ! -f "$INVOCATION_LOG" ]; then
    echo "compact-byte-budget-exceeded: WARN -- invocation log not found at $INVOCATION_LOG (ephemeral, skipping)" >&2
  else
    FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
    RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
    check "invocation log fresh-mode count (round 1 only -- compaction attempt never dispatched)" "$FRESH_COUNT" "1"
    check "invocation log resume-mode count (round 2's fallback)" "$RESUME_COUNT" "1"
  fi

  exit "$FAIL"
  ```

- [ ] **Step 4: Make scripts executable, syntax-check, and dry-run `setup.sh`**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  chmod +x codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/setup.sh
  chmod +x codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/expect.sh
  bash -n codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/setup.sh
  bash -n codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/expect.sh
  bash codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/setup.sh
  ```
  Expected: both syntax checks pass; the dry run prints the expected variables and instructions
  block, and `ROUND1_ANSWER_FILE`'s content (`cat "$ROUND1_ANSWER_FILE" | wc -c`) is confirmed to
  be well over 120,000 bytes on its own.

- [ ] **Step 5: Commit**

  ```bash
  git add codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/
  git commit -m "test(ccs): add compact-byte-budget-exceeded eval scenario"
  ```

### Task 26: Eval scenario `compact-fresh-b-escalation`

**Files:**
- Create: `codex-stream-review/evals/scenarios/compact-fresh-b-escalation/setup.sh`
- Create: `codex-stream-review/evals/scenarios/compact-fresh-b-escalation/README.md`
- Create: `codex-stream-review/evals/scenarios/compact-fresh-b-escalation/expect.sh`

**Interfaces:**
- Consumes: the same helpers as Tasks 23-25.
- Produces: the eval scenario proving `references/compaction.md`'s "Retry topology" fresh-B
  escalation — candidate A's own bounded resume-retries are exhausted (bullet 4), thread B then
  succeeds on its own single, unretried attempt — confirming `compaction_attempt_failed_thread:
  [A]` and BOTH the pre-existing old thread AND candidate A end up leaked/cleaned, while B becomes
  the new current thread.

- [ ] **Step 1: Write `setup.sh`**

  This is the compaction analogue of `retry-exhausted-round1-fresh-fallback` — but here, the
  THING exhausting its retries is the compaction candidate (round 2's fresh attempt), not round
  1's own dispatch, and there are THREE threads involved total (the old thread from round 1, the
  exhausted compaction candidate A, and the eventually-successful compaction candidate B):

  ```bash
  #!/usr/bin/env bash
  # Scenario: compact-fresh-b-escalation
  # Targets: references/compaction.md's "Retry topology" fresh-B escalation -- candidate A's own
  # fresh dispatch gets a real threadId, then BOTH bounded --resume retries fail too (3
  # consecutive nonzero_exit failures total), exhausting A per bullet 4's ordinary escalation.
  # Falls back to ONE fresh retry with a brand NEW thread B, abandoning A --
  # compaction_attempt_failed_thread becomes [A]. B's own dispatch SUCCEEDS, becoming the new
  # active thread. The pre-existing OLD thread from round 1 is untouched throughout (it is never
  # part of the compaction attempt's own retry sequence at all) and is separately moved to
  # LEAKED_THREAD_IDS once B's success promotes the snapshot.
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../../lib/common.sh"

  REPO_DIR="$(eval_make_fixture_repo compact-fresh-b-escalation)"
  BIN_DIR="$(mktemp -d)"
  ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
  INVOCATION_LOG="/tmp/ccs-eval-compact-fresh-b-escalation-invocation.log"
  : > "$INVOCATION_LOG"

  echo "REPO_DIR=$REPO_DIR"
  echo "BIN_DIR=$BIN_DIR"
  echo "INVOCATION_LOG=$INVOCATION_LOG"
  cat <<'EOF'

  Next step (run by hand or have a Claude Code agent do it): invoke
  codex-stream-review:ccs --compact against REPO_DIR, task text:
  "--compact review the uncommitted change in this fixture repo".

  Expected sequence:
    1. Round 1: fresh --uncommitted, FAKE_CODEX_SCENARIO=normal,
       FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}' -- CLEAN verdict,
       threadId OLD captured. Triggers compaction for round 2.
    2. Round 2 (COMPACTION round) -- candidate A's own attempt sequence:
       a. Fresh --uncommitted dispatch (candidate A), FAKE_CODEX_SCENARIO=exit_nonzero -- real
          threadId (call it A) captured despite the failure (fake-codex emits thread.started
          before failing).
       b. Wait 5s, --resume A --timeout 300, FAKE_CODEX_SCENARIO=exit_nonzero -- fails the same
          way.
       c. Wait 15s, --resume A --timeout 300, FAKE_CODEX_SCENARIO=exit_nonzero -- fails the same
          way. Both bounded resume retries now exhausted (bullet 4's ordinary escalation: 3
          consecutive failures for candidate A).
       d. Fresh-B escalation: dispatch thread B fresh (--uncommitted), abandoning A --
          compaction_attempt_failed_thread=[A]. FAKE_CODEX_SCENARIO=normal,
          FAKE_CODEX_USAGE_JSON='{"input_tokens":400000,"output_tokens":20000}' -- SUCCEEDS, CLEAN
          verdict, new real threadId B. COMPACTION_BASELINE_TOKENS=400000 (comfortably under
          threshold).
    3. Ordering on success: B is added to LEAKED_THREAD_IDS provisionally, round 2's JSONL line is
       appended (compacted_from_thread=OLD, compaction_attempt_failed_thread=[A],
       compaction_attempt_execution=[<A's 3 failed attempts' own execution objects, in order>],
       candidate_snapshot_path, snapshot_digest_before/after, compaction_attempt_failure_count=0,
       coverage_source), append-verify passes, promotion succeeds. B becomes the new
       GROUP_THREADS entry; OLD moves to LEAKED_THREAD_IDS.
    4. Session converges CLEAN at round 2.
    5. Phase 3: --cleanup B (current), --cleanup OLD (leaked), --cleanup A (leaked) -- ALL THREE
       with FAKE_CODEX_CLEANUP_OK=1.

  Expected exit_state: CLEAN, round_count: 2. threads: THREE entries --
  {"group":"main","thread_id":B,"kind":"current","cleanup":"deleted"},
  {"group":"main","thread_id":OLD,"kind":"leaked","cleanup":"deleted"}, and
  {"group":"main","thread_id":A,"kind":"leaked","cleanup":"deleted"} -- BOTH abandoned threads
  (the pre-compaction OLD thread AND the exhausted candidate A) really were cleaned up, not just
  recorded.
  Invocation log: exactly 3 "mode=fresh" lines (round 1's OLD, candidate A's original attempt,
  thread B's fresh dispatch -- three DIFFERENT thread_id values) and exactly 2 "mode=resume" lines
  (both against A).
  EOF
  ```

- [ ] **Step 2: Write `README.md`**

  ```markdown
  # Scenario: compact-fresh-b-escalation

  **Group:** F (`compaction.md` opt-in-feature coverage) — the compaction analogue of
  `retry-exhausted-round1-fresh-fallback`, extended to compaction's own three-thread shape (the
  pre-compaction OLD thread, exhausted candidate A, successful candidate B).

  **Targets:** `references/compaction.md`'s "Retry topology" section's bullet-4 ordinary
  escalation (candidate A's 2 bounded resume-retries exhausted, then ONE fresh retry as thread B)
  and "Durable backstop for abandoned threads" — confirms `compaction_attempt_failed_thread` is
  recorded as the array `[A]`, `compaction_attempt_execution` preserves A's own 3 failed attempts'
  telemetry, and Phase 3 cleanup reaches BOTH abandoned threads (OLD via `compacted_from_thread`,
  A via `compaction_attempt_failed_thread`) — never leaving either permanently unaccounted-for.

  ## Mechanical setup

  Round 1: `FAKE_CODEX_SCENARIO=normal`, `FAKE_CODEX_USAGE_JSON` over threshold. Candidate A's
  fresh dispatch, then both bounded resume retries: `FAKE_CODEX_SCENARIO=exit_nonzero` on all 3.
  Thread B's fresh dispatch: `FAKE_CODEX_SCENARIO=normal`, `FAKE_CODEX_USAGE_JSON` comfortably
  under threshold. All three `--cleanup` calls need `FAKE_CODEX_CLEANUP_OK=1`.
  `FAKE_CODEX_INVOCATION_LOG` set on every call.

  ## How to run

  ```bash
  bash codex-stream-review/evals/scenarios/compact-fresh-b-escalation/setup.sh
  ```

  Then invoke `codex-stream-review:ccs --compact` against `REPO_DIR`, task text:

  > --compact review the uncommitted change in this fixture repo

  ```bash
  bash codex-stream-review/evals/check-result.sh <result.json> compact-fresh-b-escalation
  ```

  ## Expected result

  - `exit_state`: `"CLEAN"`, `round_count`: `2`
  - `threads`: THREE entries — one `current` (B), TWO `leaked` (OLD and A), all `cleanup:
    "deleted"`.
  - Invocation log: exactly 3 `mode=fresh` lines (three distinct thread ids), exactly 2
    `mode=resume` lines (both against A).
  ```

- [ ] **Step 3: Write `expect.sh`**

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  RESULT_FILE="${1:?usage: expect.sh <result.json>}"
  INVOCATION_LOG="/tmp/ccs-eval-compact-fresh-b-escalation-invocation.log"

  FAIL=0
  check() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" != "$expected" ]; then
      echo "compact-fresh-b-escalation: FAIL -- $desc: expected [$expected], got [$actual]" >&2
      FAIL=1
    fi
  }

  check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
  check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "2"

  CURRENT_COUNT="$(jq -r '[.threads[]? | select(.kind == "current")] | length' "$RESULT_FILE")"
  check "count of threads[] with kind==current" "$CURRENT_COUNT" "1"
  LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
  check "count of threads[] with kind==leaked (OLD + candidate A)" "$LEAKED_COUNT" "2"

  NOT_DELETED="$(jq -r '[.threads[]? | select(.cleanup != "deleted")] | length' "$RESULT_FILE")"
  if [ "$NOT_DELETED" != "0" ]; then
    echo "compact-fresh-b-escalation: FAIL -- expected every threads[] entry cleanup==deleted, found $NOT_DELETED that aren't" >&2
    FAIL=1
  fi

  ALL_DISTINCT="$(jq -r '[.threads[].thread_id] | unique | length' "$RESULT_FILE")"
  check "all three thread_id values distinct" "$ALL_DISTINCT" "3"

  if [ ! -f "$INVOCATION_LOG" ]; then
    echo "compact-fresh-b-escalation: WARN -- invocation log not found at $INVOCATION_LOG (ephemeral, skipping)" >&2
  else
    FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
    RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
    check "invocation log fresh-mode count (OLD, A, B)" "$FRESH_COUNT" "3"
    check "invocation log resume-mode count (both against A)" "$RESUME_COUNT" "2"

    FRESH_DISTINCT_IDS="$(grep '^mode=fresh ' "$INVOCATION_LOG" | sed -E 's/^mode=fresh thread_id=([^ ]*).*/\1/' | sort -u | wc -l | tr -d ' ')"
    check "distinct thread_id values across the 3 fresh invocations" "$FRESH_DISTINCT_IDS" "3"
    RESUME_DISTINCT_IDS="$(grep '^mode=resume ' "$INVOCATION_LOG" | sed -E 's/^mode=resume thread_id=([^ ]*).*/\1/' | sort -u | wc -l | tr -d ' ')"
    check "distinct thread_id values across the 2 resume invocations (both A)" "$RESUME_DISTINCT_IDS" "1"
  fi

  exit "$FAIL"
  ```

- [ ] **Step 4: Make scripts executable, syntax-check, and dry-run `setup.sh`**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  chmod +x codex-stream-review/evals/scenarios/compact-fresh-b-escalation/setup.sh
  chmod +x codex-stream-review/evals/scenarios/compact-fresh-b-escalation/expect.sh
  bash -n codex-stream-review/evals/scenarios/compact-fresh-b-escalation/setup.sh
  bash -n codex-stream-review/evals/scenarios/compact-fresh-b-escalation/expect.sh
  bash codex-stream-review/evals/scenarios/compact-fresh-b-escalation/setup.sh
  ```
  Expected: both syntax checks pass; the dry run prints the expected variables and instructions.

- [ ] **Step 5: Commit**

  ```bash
  git add codex-stream-review/evals/scenarios/compact-fresh-b-escalation/
  git commit -m "test(ccs): add compact-fresh-b-escalation eval scenario"
  ```

### Task 27: Eval scenario `compact-clean-repo-dir-polluted`

**Files:**
- Create: `codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/setup.sh`
- Create: `codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/README.md`
- Create: `codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/expect.sh`

**Interfaces:**
- Consumes: `references/non-repo-artifact.md`'s existing `CLEAN_REPO_DIR` mechanism, Task 6's
  eight-check cleanliness predicate.
- Produces: the eval scenario proving compaction's own `CLEAN_REPO_DIR` cleanliness recheck fails
  CLOSED (never dispatches into a known-polluted directory) — this is the one design-doc-cited
  "CLEAN_REPO_DIR checks" coverage this plan's dispatch explicitly asked for.

- [ ] **Step 1: Write `setup.sh`**

  Unlike Tasks 23-26, `CLEAN_REPO_DIR`'s own path is allocated INSIDE the live `/ccs` session
  (Phase 0 step 4, printed as `CLEAN_REPO_DIR=<path>` per `SKILL.md`'s own convention) — this
  scenario's setup.sh cannot pre-create it. Instead, this scenario's own driving instructions tell
  whoever runs it (human or agent) to inject a stray file into the PRINTED `CLEAN_REPO_DIR` path
  between round 1 completing and round 2 (the compaction attempt) dispatching — the exact accepted
  gap `references/compaction.md`'s "Restart mechanism" step 2 documents ("round 1's own very first
  artifact dispatch... remain fully exposed to this pollution risk with no check of any kind").
  This is a non-repo-artifact session (a pasted analysis paragraph, no git diff at all):

  ```bash
  #!/usr/bin/env bash
  # Scenario: compact-clean-repo-dir-polluted
  # Targets: references/compaction.md's "Restart mechanism" step 2 -- the eight-check
  # CLEAN_REPO_DIR cleanliness recheck that runs before EVERY compaction fresh dispatch for a
  # non-repo-artifact session. A stray file is deliberately planted into CLEAN_REPO_DIR (check 1:
  # "no entries other than .git") between round 1 completing and round 2's compaction attempt --
  # the recheck must detect this and fail CLOSED (fall through to the ordinary --resume fallback
  # on the OLD thread), NEVER dispatch a fresh --uncommitted call against the polluted directory.
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../../lib/common.sh"

  BIN_DIR="$(mktemp -d)"
  ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
  INVOCATION_LOG="/tmp/ccs-eval-compact-clean-repo-dir-polluted-invocation.log"
  : > "$INVOCATION_LOG"

  ARTIFACT_TEXT_FILE="$(mktemp)"
  cat > "$ARTIFACT_TEXT_FILE" <<'ARTIFACT'
  # Fixture design note

  This is a short, deliberately unremarkable design paragraph used purely as the pasted,
  non-repo-artifact review subject for this eval scenario. It has no git diff of its own -- it
  exists only in --focus text, which is exactly the shape references/non-repo-artifact.md's
  CLEAN_REPO_DIR mechanism exists to isolate.
  ARTIFACT

  echo "BIN_DIR=$BIN_DIR"
  echo "INVOCATION_LOG=$INVOCATION_LOG"
  echo "ARTIFACT_TEXT_FILE=$ARTIFACT_TEXT_FILE"
  cat <<'EOF'

  Next step (run by hand or have a Claude Code agent do it): invoke
  codex-stream-review:ccs --compact against the CONTENT of ARTIFACT_TEXT_FILE (a non-repo-artifact
  review -- paste its content as the task, prefixed with --compact), with BIN_DIR prepended to
  PATH on every Bash call, FAKE_CODEX_INVOCATION_LOG set to INVOCATION_LOG on every dispatch/
  cleanup call.

  Expected sequence:
    1. Phase 0 step 4 determines this is a non-repo-artifact review, allocates CLEAN_REPO_DIR and
       FAKE_GIT_HOME (per references/non-repo-artifact.md), prints CLEAN_REPO_DIR=<path> -- NOTE
       THIS PATH, it is needed for step 3 below.
    2. Round 1: fresh --uncommitted against CLEAN_REPO_DIR (empty diff, falls back to reviewing
       --focus, which contains the pasted artifact text), FAKE_CODEX_SCENARIO=normal,
       FAKE_CODEX_USAGE_JSON='{"input_tokens":9000000,"output_tokens":50000}' -- CLEAN verdict,
       threadId OLD captured. Triggers compaction for round 2.
    3. BEFORE round 2's compaction attempt dispatches (i.e. immediately after round 1's own JSONL
       append, before the threshold-triggered restart mechanism ever runs its own step-2
       CLEAN_REPO_DIR recheck): pollute CLEAN_REPO_DIR by planting a stray file --
       `touch "<the printed CLEAN_REPO_DIR path>/stray-file.txt"`. This violates check 1 ("no
       entries other than .git") of the eight-check cleanliness predicate.
    4. Round 2 (compaction ATTEMPT): step 0's ordinary snapshot revalidation passes (unrelated to
       CLEAN_REPO_DIR's own cleanliness). Step 1 builds and verifies COMPACT_DIGEST successfully
       (round 1 had zero open claims). Step 2's non-repo-artifact CLEAN_REPO_DIR cleanliness
       recheck runs BEFORE the fresh dispatch -- check 1 FAILS (a stray file is present). This is
       treated exactly like any other compaction failure: log the narration, fall through to
       step 6's fallback WITHOUT EVER DISPATCHING a fresh call for the compaction candidate. No
       thread is ever created for this failed attempt (nothing was ever captured to abandon), so
       compaction_attempt_failed_thread is correctly ABSENT from round 2's own line.
    5. Round 2's real outcome: an ORDINARY --resume dispatch against the STILL-ALIVE OLD thread
       (never touched by the failed compaction attempt) -- FAKE_CODEX_SCENARIO=normal,
       FAKE_CODEX_USAGE_JSON='{"input_tokens":300000,"output_tokens":20000}'. Session converges
       CLEAN at round 2, still using thread OLD throughout.
    6. Phase 3: --cleanup OLD only (GROUP_THREADS -- no second thread was ever created) --
       FAKE_CODEX_CLEANUP_OK=1. CLEAN_REPO_DIR/FAKE_GIT_HOME are removed as usual (the stray file
       inside CLEAN_REPO_DIR is removed along with it via `rm -rf`).

  Expected exit_state: CLEAN, round_count: 2. threads: exactly ONE entry --
  {"group":"main","thread_id":OLD,"kind":"current","cleanup":"deleted"} -- no "leaked" entry at
  all, since the compaction attempt never created a second thread.
  Invocation log: exactly 1 "mode=fresh" line (round 1 only -- the compaction attempt's own fresh
  dispatch never happened) and exactly 1 "mode=resume" line (round 2's fallback, against OLD).
  EOF
  ```

- [ ] **Step 2: Write `README.md`**

  ```markdown
  # Scenario: compact-clean-repo-dir-polluted

  **Group:** F (`compaction.md` opt-in-feature coverage) — the one scenario in this suite covering
  `references/compaction.md`'s "Restart mechanism" step 2 `CLEAN_REPO_DIR` cleanliness recheck,
  for a genuine non-repo-artifact session.

  **Targets:** the eight-check `CLEAN_REPO_DIR` cleanliness predicate's check 1 ("no entries other
  than `.git`"), and the "Fail CLOSED wherever a real alternative still exists" rule — a detected
  pollution must fall through to the ordinary `--resume` fallback on the STILL-ALIVE old thread,
  never dispatch a fresh call against a known-polluted directory, and never create a second thread
  for an attempt that was never actually dispatched.

  ## Mechanical setup

  This is the one scenario in this suite requiring MANUAL intervention mid-session (unlike Tasks
  23-26, which fully script every dispatch's own env vars in advance): whoever drives this
  scenario must note the `CLEAN_REPO_DIR=<path>` line `/ccs`'s own Phase 0 prints, then, after
  round 1 completes but before round 2's compaction attempt runs, `touch` a stray file inside that
  exact directory. Round 1: `FAKE_CODEX_SCENARIO=normal`, `FAKE_CODEX_USAGE_JSON` over threshold.
  Round 2's real (fallback) dispatch: `FAKE_CODEX_SCENARIO=normal`,
  `FAKE_CODEX_USAGE_JSON` under threshold. `--cleanup` needs `FAKE_CODEX_CLEANUP_OK=1`.
  `FAKE_CODEX_INVOCATION_LOG` set on every call.

  ## How to run

  ```bash
  bash codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/setup.sh
  ```

  Then invoke `codex-stream-review:ccs --compact` with the CONTENT of `ARTIFACT_TEXT_FILE` as the
  task text (a non-repo-artifact review — no `REPO_DIR` fixture for this scenario, unlike Tasks
  23-26).

  ```bash
  bash codex-stream-review/evals/check-result.sh <result.json> compact-clean-repo-dir-polluted
  ```

  ## Expected result

  - `exit_state`: `"CLEAN"`, `round_count`: `2`
  - `threads`: exactly ONE entry, `kind: "current"`, `cleanup: "deleted"` — no `"leaked"` entry.
  - Invocation log: exactly 1 `mode=fresh` line (round 1 only), exactly 1 `mode=resume` line
    (round 2's fallback) — proving the compaction attempt's own fresh dispatch never happened.
  - The session's own `.jsonl` log: round 2's own line carries a narration note about the failed
    `CLEAN_REPO_DIR` recheck and correctly has NO `compaction_attempt_failed_thread` field at all
    (manual check — not mechanically asserted by `expect.sh`).
  ```

- [ ] **Step 3: Write `expect.sh`**

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  RESULT_FILE="${1:?usage: expect.sh <result.json>}"
  INVOCATION_LOG="/tmp/ccs-eval-compact-clean-repo-dir-polluted-invocation.log"

  FAIL=0
  check() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" != "$expected" ]; then
      echo "compact-clean-repo-dir-polluted: FAIL -- $desc: expected [$expected], got [$actual]" >&2
      FAIL=1
    fi
  }

  check "exit_state" "$(jq -r '.exit_state' "$RESULT_FILE")" "CLEAN"
  check "round_count" "$(jq -r '.round_count' "$RESULT_FILE")" "2"

  THREAD_COUNT="$(jq -r '.threads | length' "$RESULT_FILE")"
  check "total threads[] count (compaction attempt never dispatched, never created a thread)" "$THREAD_COUNT" "1"

  LEAKED_COUNT="$(jq -r '[.threads[]? | select(.kind == "leaked")] | length' "$RESULT_FILE")"
  check "count of threads[] with kind==leaked (must be zero)" "$LEAKED_COUNT" "0"

  CLEANUP="$(jq -r '.threads[0].cleanup' "$RESULT_FILE")"
  check "the one thread's cleanup" "$CLEANUP" "deleted"

  # target.scope for a non-repo-artifact session is still "uncommitted" (it dispatches AS
  # --uncommitted against CLEAN_REPO_DIR under the hood, per references/non-repo-artifact.md).
  check "target.scope" "$(jq -r '.target.scope' "$RESULT_FILE")" "uncommitted"

  if [ ! -f "$INVOCATION_LOG" ]; then
    echo "compact-clean-repo-dir-polluted: WARN -- invocation log not found at $INVOCATION_LOG (ephemeral, skipping)" >&2
  else
    FRESH_COUNT="$(grep -c '^mode=fresh ' "$INVOCATION_LOG" || true)"
    RESUME_COUNT="$(grep -c '^mode=resume ' "$INVOCATION_LOG" || true)"
    check "invocation log fresh-mode count (round 1 only -- compaction never dispatched)" "$FRESH_COUNT" "1"
    check "invocation log resume-mode count (round 2's fallback)" "$RESUME_COUNT" "1"
  fi

  exit "$FAIL"
  ```

- [ ] **Step 4: Make scripts executable, syntax-check, and dry-run `setup.sh`**

  ```bash
  cd /Users/hmc7279235/Work/Develop/plugins
  chmod +x codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/setup.sh
  chmod +x codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/expect.sh
  bash -n codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/setup.sh
  bash -n codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/expect.sh
  bash codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/setup.sh
  ```
  Expected: both syntax checks pass; the dry run prints `BIN_DIR=...`/`INVOCATION_LOG=...`/
  `ARTIFACT_TEXT_FILE=...` plus the instructions block, and `cat "$ARTIFACT_TEXT_FILE"` shows the
  short fixture design note.

- [ ] **Step 5: Commit**

  ```bash
  git add codex-stream-review/evals/scenarios/compact-clean-repo-dir-polluted/
  git commit -m "test(ccs): add compact-clean-repo-dir-polluted eval scenario"
  ```

---

## Final Self-Review (performed by the plan author, not a task for the implementer)

**Spec coverage** — every major design-doc section maps to a task: Problem/opt-in-flag/Scope/cost-
tradeoff/out-of-scope → Task 1; Trigger (threshold, round-ownership terms, both circuit breakers,
durable-latch recording) → Tasks 2-3; What-gets-preserved/digest-construction/closed-claim-ceiling/
byte-budget-preflight → Task 4; Restart-mechanism step 0 → Task 5; steps 1-2 (digest abort,
non-repo-artifact + 8-check CLEAN_REPO_DIR) → Task 6; step 3 (`--uncommitted`/`--base` lifecycle) →
Task 7; step 3 continued (`--commit` SHA-pinning) → Task 8; step 3 continued (atomic promotion,
retired/provisional durability) → Task 9; step 4 (dispatch/focus-text/coverage-epoch) → Task 10;
Retry topology (candidate A's 4 bullets) → Task 11; (thread B, carry-forward) → Task 12; Ordering
on success (provisional tracking, branch-aware append-verify, promotion re-verify) → Task 13; On
failure → Task 14; Failure isolation/keep-evidence/durable backstop → Task 15; Preserving
failed-attempt telemetry/superseded-attempt reuse/Logging summary → Task 16; the three named
companion amendments (`snapshot-integrity.md`, `execution-telemetry.md`, `retry-guards.md`) → Tasks
17-19; the `SKILL.md`-side wiring (flag parsing, mandatory-read entry, single-group override,
trigger-check integration point, schema_version bump, JSONL field documentation, Final Report) →
Tasks 20-21; self-consistency → Task 22; eval scenarios covering the basic path, the benefit-free-
restart-loop guard, the byte-budget latch, the fresh-B retry-topology escalation, and the
`CLEAN_REPO_DIR` checks (exactly the two categories this plan's own dispatch explicitly named) →
Tasks 23-27.

**Placeholder scan** — every task's Steps contain either real markdown/shell content to write
verbatim-or-adapted, or a specific, named design-doc section to read before writing (never "handle
appropriately"); no task says "similar to Task N" without also giving the actual differing content
inline.

**Judgment calls made where the design doc is silent on pure implementation mechanics (not
covered by the design doc itself, decided here):**
1. **File structure** — one new reference file (`references/compaction.md`) rather than inlining
   into `SKILL.md`, matching the existing `capture-evidence.md`/`keep-evidence.md`/
   `snapshot-integrity.md`/`claim-ledger.md`/`execution-telemetry.md`/`parallel-mode.md`/
   `non-repo-artifact.md` pattern of one reference file per opt-in-or-always-on mechanism with a
   thin `SKILL.md` pointer — this is by far the closest-fitting existing convention, given
   `compaction.md`'s own content volume (comparable to or larger than any existing reference file).
2. **Section ordering within `compaction.md`** — followed the design doc's own top-to-bottom
   ordering (Trigger → What gets preserved → Restart mechanism → Retry topology → Ordering on
   success → On failure → Failure isolation → keep-evidence → durable backstop → preserved
   telemetry → superseded-attempt reuse → Logging), except for relocating "Closed-claim
   ceiling"/"Byte-budget preflight" (physically near the END of the design doc) next to "What gets
   preserved" (Task 4) and "Handling missing/malformed usage data" next to "Trigger" (Task 2) —
   both relocations follow the design doc's OWN thematic grouping (both sections are refinements of
   mechanics introduced earlier in the document) rather than its physical, accumulated-via-54-rounds
   ordering, which is not itself meaningful as a reading order.
3. **The exact `SKILL.md` integration point for the trigger check** (Task 21, Step 2) — the design
   doc states the check runs "before building the next round's dispatch" but does not name an exact
   line in `SKILL.md` to anchor it to; this plan places it at the end of Phase 2 step 6 (immediately
   after that round's own temp-file cleanup, before "Coverage is a Round-1-only property"), since
   that is the literal last action of the round-just-completed's own processing and the literal
   first opportunity before the next round's Phase 1 Step 1 ever runs.
4. **Eval scenario naming and count** — the design doc names three existing scenarios as
   precedent (`retry-exhausted-round1-fresh-fallback`, `could-not-verify-exhausted`,
   `retry-no-threadid-fresh`) without prescribing how many NEW scenarios this feature needs; five
   were chosen to cover, at minimum, one scenario per distinct terminal/latch outcome this feature
   introduces (successful basic restart, the baseline circuit breaker, the byte-budget latch, the
   fresh-B retry-topology escalation, and the `CLEAN_REPO_DIR` cleanliness check) — the
   `COMPACTION_CONSECUTIVE_FRESH_FAILURES` repeated-failure circuit breaker and the digest
   structural-verification-failure path are NOT separately covered by a dedicated eval scenario in
   this plan (both are straightforward compositions of mechanics the five scenarios above already
   exercise individually — repeated `exit_nonzero`-style fresh-dispatch failures, and a
   malformed/incomplete `FAKE_CODEX_FINAL_ANSWER` shape — and can be added later following the exact
   same pattern Tasks 23-27 establish, without needing new fixture infrastructure).
5. **Manual vs. fully-scripted eval mechanics** — Task 27's `CLEAN_REPO_DIR` pollution step requires
   mid-session manual intervention (touching a file into a path only known once the live session
   prints it), since no `setup.sh` can pre-create a path the SKILL only allocates at runtime; this
   matches this project's own existing eval convention (every scenario in this suite is already
   "run by hand or have a Claude Code agent do it," not a fully automated CI test) rather than
   introducing a new, more automated mechanism this codebase does not otherwise use.

**Type/name consistency** — every durable field name, session-scoped fact name, and constant is
introduced exactly once (in the task named in the Spec Coverage list above) and referenced with
identical spelling by every later task; Task 22 exists specifically to mechanically re-verify this
after all content-writing tasks (1-21) are complete, closing the loop the same way the design doc's
own 54 rounds of review repeatedly closed this exact class of gap.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-10-ccs-opt-in-compaction.md`. Two
execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks,
   fast iteration. Use `superpowers:subagent-driven-development`.
2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch
   execution with checkpoints for review.

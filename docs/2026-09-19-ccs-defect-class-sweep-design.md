# `codex-stream-review:ccs` — defect-class sweep design

## Problem

Real production usage of `/ccs` shows a recurring pattern: a round finds a real defect, Claude
fixes it, and the *fix itself* — or an unfixed sibling occurrence of the same defect elsewhere in
the repository — becomes the next round's finding. Rounds keep converging (each is a real, novel
finding, not oscillation — see `references/claim-ledger.md`'s `evidence_delta` gate, which already
catches true repetition), so this is not a bug in the existing convergence machinery. But the user
observed a real, recurring shape to it worth designing around: a confirmed defect is often not a
one-off, it's an instance of a **class** (the same missing-null-check, the same off-by-one, the same
copy-pasted anti-pattern) that recurs elsewhere in the repository outside the current diff/focus —
and neither side is currently instructed to check for that class-wide recurrence, only for the
specific reported instance and its immediate siblings.

Two existing mechanisms already push in this direction but stop short of a repo-wide class check:

- `scripts/run-ccs-review.sh`'s `build_review_prompt()` (the trusted prompt zone) already instructs
  Codex to widen from the changed lines to "the whole file/module, its callers/callees, and sibling
  code paths" before narrowing back in, and requires a non-empty `verification` field stating the
  concrete action taken to check each finding.
- `SKILL.md`'s Phase 2 step 4 ("Whole-flow re-check") already requires Claude, after applying a fix,
  to check "does a sibling path need the identical fix" — but this is scoped to siblings of the
  specific file/function just touched, not the whole repository.

Neither instruction currently asks either side to treat a confirmed defect as a **class** and grep
the rest of the repository for other instances of it. This document designs that extension.

## Research grounding

A structured survey of Anthropic, OpenAI, and Google/academic sources (2026-09-19) converged on a
consistent pattern directly applicable here — see full source notes in this session's record;
summarized:

- **Ground breadth in executed evidence, never inference.** Google's Mantis harness treats a
  finding as unconfirmed until backed by AST/call-graph verification or sandboxed reproduction —
  "pair lightweight AI scans with deterministic, structural validation." OpenAI's Codex prompting
  guide: "base findings only on the [material] below" — an explicit anti-speculation clause paired
  with "search first" before assuming something is/isn't present elsewhere.
- **Widen the investigation surface, narrow the claims surface.** The consistent shape across all
  three sources is a *paired* constraint: investigate broadly, but only claim what was actually
  verified this round. Never "investigate more" as an unpaired instruction — that invites
  unverified breadth claims (the fabrication risk this design must avoid).
- **Separate the agent that fixes from the agent that re-verifies the fix's blast radius.** Google's
  own explicit principle: "keep the harnesses, rules, and context for each of your development,
  scanning, triage agents separate" — an anti-collusion measure. Directly applicable: Claude fixing
  a defect class and *also* being the sole judge of how far that class extends is exactly the
  self-grading risk this principle warns against — Codex's own independent re-grep in the next round
  is the check.
- **Architect for the cost of breadth rather than skip breadth for cost reasons.** Mantis's
  hierarchical file→directory→root summarization cut token overhead ~85% while preserving
  cross-file context — the lesson is "solve the cost problem structurally," not "avoid looking
  broadly to save tokens." This document takes the cheaper structural path available here: trigger
  the widened grep only when a defect is judged class-like, not on every finding.

## What was ruled out

- **Pre-built architecture/call-graph context maintained across the whole run** (Mantis-style
  hierarchical summarization). Rejected for v1: it requires new JSONL state, a maintenance/staleness
  mechanism, and per-round cost regardless of whether any given round's findings are even
  pattern-like. `--compact` already established the precedent that a new cost lever ships opt-in and
  narrowly scoped until real review data justifies broadening it (see
  `docs/2026-09-09-ccs-opt-in-compaction-design.md`) — this document follows the same discipline by
  triggering the repo-wide grep only per-finding, only when judged class-like, not as a standing
  per-round tax.
- **Formalizing the existing accept/rebut cycle as an explicit "debate protocol."** The existing
  Core-Principles equal-partnership design (Codex asserts, Claude verifies-or-rebuts, Codex responds
  next round) already implements the substance of multi-agent debate; documenting it under a new
  name adds no mechanism. Not part of this change.
- **A new Codex-side JSON schema field** (e.g. `defect_class: "pattern"|"one_off"`) for Codex's own
  output. Rejected for the same reason `references/claim-ledger.md` rejected a new field for
  `DISPOSITION` markers: `schemas/review-verdict.schema.json`'s strict-structured-output mode already
  rejects `allOf`/`if-then`, so a new enum field would need its own separate semantic-check branch in
  `run-ccs-review.sh`'s existing `jq` cross-field validation, for a distinction that free-text
  `evidence`/`verification` content can already carry. Prompt-level instruction is enough, exactly as
  it already is for the `dimensions` ledger and `verification` field.

## Design

### 1. Codex-side prompt expansion (trusted zone, `build_review_prompt()`)

Extend the existing narrow→wide→narrow paragraph (`run-ccs-review.sh` lines ~213-233) with one more
concrete verification action, in the same bulleted list that already contains "grep the repository
for every caller/usage" and "check the real access pattern for an actual nested scan":

> - If a finding looks like an instance of a repeatable defect *class* (the same anti-pattern,
>   missing check, or copy-pasted logic error, not a one-off), grep the rest of the repository for
>   other occurrences of that same pattern before reporting — state in the finding's `verification`
>   field exactly what you grepped for and what you found (including "grepped for `<pattern>`, found
>   no other occurrences" as a valid, complete answer). Never state or imply that a pattern is
>   "likely present elsewhere" without having actually grepped for it — an unconfirmed guess about
>   further occurrences is exactly the kind of claim this review's evidence discipline forbids.

This is additive text in an already-trusted zone; no new obligation-anchoring problem (per the
`claim-ledger.md`-established lesson that a Codex-binding rule must live in `build_review_prompt()`,
never only in caller-supplied `--focus` text) since it's added directly there, not via `--focus`.

### 2. Claude-side whole-flow re-check expansion (`SKILL.md` Phase 2 step 4)

Extend the existing "Whole-flow re-check" bullet from sibling-path scope to repo-wide, gated on the
same class-like judgment, and require the grep to have actually run before the classification is
made:

> For any fix applied this round, after the existing sibling-path check: if this finding reads as an
> instance of a repeatable defect class rather than a one-off, actually grep the repository for the
> same pattern (function/anti-pattern signature, not a vague description) before deciding whether it
> is class-like — the grep result is what makes the classification, never a hunch. If the grep finds
> other real occurrences within the current review's scope (see "Scope-expansion guard" below), fix
> them in this same round and record them via `defect_class_sweeps[]` (below). If the grep finds
> nothing, record that too — a completed, empty sweep is a valid, informative outcome, not a skipped
> step.

### 3. Scope-expansion guard

A repo-wide grep can turn up occurrences far outside the diff/focus that triggered the review. Reuse
the existing, already-validated pattern from `[[ccs_reconciliation_verification_lessons]]`'s
"Scope discipline for pre-existing staleness" — never silently expand scope on unilateral judgment:

- A small number of additional occurrences, clearly within the spirit of the current task (e.g. the
  same missing-null-check pattern in 2-3 sibling functions in the same module) — fix them in the same
  round, same as any other whole-flow re-check finding.
- A large or clearly out-of-task-scope set of occurrences (e.g. the same anti-pattern in a dozen
  unrelated files across the codebase) — do not silently expand the review's scope. Disclose the
  finding to the user directly (what pattern, how many occurrences, where) and ask whether fixing
  them all now is in scope for this review, exactly as the existing partial-coverage disclosure rule
  already requires for an unrelated swept-in file. Record the occurrences found and the
  expansion-flagged decision in `defect_class_sweeps[]` regardless of the user's answer.

### 4. Cross-round independent re-verification (anti-collusion)

Per the "separate the fixer from the verifier of blast radius" principle above: when Claude's
History text for the next round reports a defect-class sweep and its fix, it must not present
Claude's own grep result as the final word. Extend the existing Round-2+ History-construction
instruction (`SKILL.md` Phase 1 Step 0) with:

> When History reports a defect-class sweep from the prior round (pattern grepped, occurrences fixed
> count), explicitly invite Codex to independently re-grep for the same pattern on its own next
> `--resume` turn — do not present Claude's own sweep as authoritative. This is ordinary scope
> guidance inside `--focus`/Context text (Codex already has full read-only repo access and is
> already instructed to verify rather than trust reported context), not a new obligation requiring
> trusted-zone anchoring.

### 5. JSONL field: `defect_class_sweeps[]`

A new, always-optional, additive round-level field — present only on a round where at least one
finding was judged class-like and swept, top-level even in parallel mode (matching
`claim_closures[]`'s existing precedent, since `finding_id`s are already group-namespaced):

```json
"defect_class_sweeps": [
  {
    "finding_id": "g1:f3",
    "pattern_grepped": "missing null-check before .value access on parsed config",
    "occurrences_found": 4,
    "sites_fixed_this_round": 4,
    "expansion_flagged_to_user": false
  }
]
```

- `pattern_grepped`: what was actually searched for — not a description of the bug, the literal
  pattern/grep target, so the record is independently re-checkable.
- `occurrences_found`: total matches, including the original finding's own site.
- `sites_fixed_this_round`: how many were actually fixed this round (may be less than
  `occurrences_found` if the scope-expansion guard above deferred some to a user decision).
- `expansion_flagged_to_user`: `true` only when the scope-expansion guard's disclosure step actually
  fired.

No `schema_version` bump — purely additive, same policy `claim-ledger.md` section 10 already
establishes for fields that don't change how existing lines are interpreted.

### 6. Non-goals

- This is not a blanket "always grep the whole repo" instruction. It fires only when a *specific,
  already-confirmed* finding is judged to be class-like — never as a standing per-round tax on every
  finding, matching the cost-discipline lesson from the research survey above.
- This does not change convergence logic, the claim ledger, receipt validation, or `--compact`. A
  defect-class sweep's fixes and findings flow through the existing verification/claim-ledger
  machinery unchanged — this document only adds the trigger and the record of having swept.
- This does not add a new opt-in flag. Unlike `--compact` (a genuinely new failure surface not yet
  validated), this is a bounded prompt-instruction extension to two already-always-on mechanisms
  (narrow→wide→narrow, whole-flow re-check) — no new failure mode is introduced beyond "the grep
  takes some extra time," which the scope-expansion guard already bounds.

## Open questions for review

1. Is `defect_class_sweeps[]`'s per-entry shape sufficient, or does the scope-expansion guard need a
   harder gate (e.g. a numeric threshold for "small" vs. "large" occurrence count) rather than
   judgment-based?
2. Should the Codex-side independent re-grep (section 4) be a *requirement* checked by Claude's own
   verification pass (i.e. treat a resumed round that doesn't re-grep as incomplete verification),
   or is inviting it via `--focus` text sufficient given Codex already has standing instructions to
   verify rather than trust reported context?

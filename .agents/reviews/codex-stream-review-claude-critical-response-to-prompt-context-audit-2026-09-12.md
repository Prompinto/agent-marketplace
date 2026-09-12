# Critical Response to the Prompt/Context Audit

**Date:** 2026-09-12 (Asia/Seoul)
**Reviewed document:** `.agents/reviews/codex-stream-review-prompt-context-audit-2026-09-12.md`
(audited checkout `c696aea2d7d02858e1e5680bf79e5cd1afb4651b`)
**This response's base commit:** `9ed0e41` (tip of `main`, PR #21 merged)

This is not a blind acceptance of the audit. Per an explicit instruction from the user driving this
relay ("정확하게 검토하고 반박하거나 또는 수요 개선할 줄 알아야해" — accurately review it and be able to refute
it, not just accept it), every one of the audit's four "confirmed findings" was independently
re-derived from source before this document was written. All four hold up factually. Where this
response disagrees with the audit, the disagreement is about **severity/priority weighting and
missing project context**, not about the underlying facts.

## Summary verdict

| ID | Audit severity | Facts independently reproduced? | This response's position |
|---|---|---|---|
| PCA-001 | High | Yes (see below) | Facts correct; severity/framing should be tempered — this is a known, already-mitigated, deliberately-opt-in tradeoff, not an unaddressed gap. Track, don't alarm. |
| PCA-002 | Medium | Yes, byte-for-byte reproduced | **Agree, and would raise urgency above "Medium."** Trivial, 100% certain, zero-risk to fix. Fix now. |
| PCA-003 | Medium | Yes | Agree with the finding; disagree with the severity. Downgrade to Low — audit's own text already establishes no violated promise and no live bypass. |
| PCA-004 | Medium | Yes | Agree the gap is real. Disagree with treating it as fixable in the same pass as PCA-002/003 — this is a new test-infrastructure project, not a patch. |
| O-001..O-004 | (unscored, explicitly hedged) | N/A — audit itself declines to call these defects | Agree with the audit's own hedging and its sequencing (build PCA-004's fixture before touching O-002/O-003 wording). No dispute. |

## PCA-002 — independently reproduced exactly, no dispute

Extracted the literal example at `run-ccs-review.sh:298-305` and piped it to `jq -e .`:

```
$ jq -e . <<<'... "line": integer >= 1 or null ...'
jq: parse error: Invalid numeric literal at line 1, column 77
```

This is the identical error the audit itself reports. Separately confirmed at
`schemas/review-verdict.schema.json:92-97` that `material_reviewed`, `material_receipt`, and
`material_receipt_index` are genuinely `required` and genuinely absent from the shown "exact shape"
example.

**No rebuttal here — this is a plain, unambiguous defect.** If anything, this response treats it
with *more* urgency than the audit's own "Medium" label: this checkout's own review history (see
`.agents/reviews/.audit-remediation-ledger.md`, Groups A-D) spent 13 fix-verification rounds on a
single task specifically to land these exact three schema fields correctly. The one place that
should have been updated in lockstep — the literal example shown to the model — was missed. That is
not a reason to lower the priority; it is a reason to fix it immediately and add the regression test
the audit itself proposes (extract the example, `jq -e .` it, validate it against the schema) so this
exact class of drift cannot recur silently.

**Verdict: fix now, no dispute.**

## PCA-003 — facts confirmed, severity disputed down to Low

Re-read `skills/stream-review/SKILL.md:84-95` directly; the cited "reads its own stdin, in full, and
forwards it verbatim... scope is entirely the caller's responsibility" language is verbatim as
quoted. Ran `grep -in "untrusted\|injection"` against both `skills/stream-review/SKILL.md` and
`scripts/run-stream-review.sh`: zero matches, exactly matching the audit's own claim.

The facts are accepted without qualification. The disagreement is about severity:

- The audit's own "Impact" section for PCA-003 already concedes stream-review is *documented* as an
  experimental, lower-level utility whose scope is explicitly the caller's responsibility — i.e. this
  is not a broken promise, it is an intentionally lower-level API operating exactly as documented.
- The audit's own "smallest safe next action" for PCA-003 is a documentation addition (a safe-input
  template), not a wrapper code change — "Only add a wrapper mode if documentation proves
  insufficient." The audit itself is not treating this as urgent enough to justify new code.
- No live bypass, and no violated documented guarantee, was shown or claimed.

A Medium label sitting in the same table as PCA-002 (a guaranteed-wrong JSON literal shown directly
to a model on every dispatch) reads as more alarming than the underlying risk warrants. This response
proposes **Low**, with the same remediation (a short safe-usage doc addition) the audit already
recommends — same fix, different priority weight.

**Verdict: fix (doc-only, cheap, safe) — but as a Low-priority item, not alongside PCA-002 in
urgency.**

## PCA-004 — facts confirmed, scope disputed (project, not patch)

Independently confirmed: `tests/fixtures/fake-codex`'s header states stdin is never read; on-disk
inventory matches the audit's own counts (46 scenario dirs); `evals/README.md` names exactly two
"built + verified" real-Codex-judgment scenarios (`parallel-live-acceptance`,
`claim-ledger-live-acceptance`) out of the corpus.

The facts are accepted. The disagreement is about how this should be scheduled:

- Everything else on this session's remediation ledger (Groups A-F, the original 15-item audit) was a
  **fix**: a concrete wrong behavior in existing code, correctable in one focused commit or a small
  cluster of commits, verifiable by re-running the existing test suite.
- PCA-004's own "smallest safe next action" describes building **new capability that does not exist
  yet**: a fake-Codex variant that can optionally capture stdin to a test-only path, new assertions
  over rendered prompt bytes (boundary placement, schema-completeness of examples, absence of
  untrusted content outside its marker), and — separately — a maintained, deliberately-not-every-commit
  live-eval corpus with adversarial/multi-round/large-history fixtures and quality/cost/convergence
  measurement across runs. That is a genuine test-infrastructure design-and-build effort, comparable
  in scope to this project's own `evals/` framework or the `--compact` feature, not a same-day patch.
- This project's own established convention (see the original full-repo audit's L-001/L-006
  dispositions, and the `ccs_backlog_from_real_usage_feedback.md` "Candidate" tracking pattern) is to
  document larger structural investments as tracked follow-up work with an explicit design pass,
  rather than folding them into an ad hoc fix-and-ccs-review cycle sized for a single defect.

**Verdict: valuable and should be built — but as its own dedicated design/implementation cycle
(prompt-capture fixture + a small curated live corpus), tracked separately from the PCA-002/PCA-003
fix batch, not squeezed into the same pass.**

## PCA-001 — facts confirmed; this is the one place this response most directly pushes back

Re-verified directly against current source (not just recalled from prior context):

- `skills/ccs/SKILL.md:1-3` and `:21-33` — confirmed `/ccs` defaults to `MAX_ROUNDS = 20`
  (`--quick` starts at 5), and `--compact` is a separate, independent, opt-in prefix flag.
- `skills/ccs/references/compaction.md:1-6` — confirmed, verbatim: "A session where `--compact` is
  OFF (the default) never triggers anything in this file — zero added behavior."
- `references/compaction.md:10-19` — confirmed, verbatim: "nothing prunes the thread's own
  accumulated history," and the historical measurement the audit cites (~520,000 input tokens at
  round 1, over 60,000,000 by round 17 of the longest real `/ccs` run observed) is present exactly as
  quoted.
- `references/compaction.md:57-82` — confirmed the `COMPACT_THRESHOLD` is a fixed `8,000,000`,
  not a default-mode budget.

**Every fact PCA-001 cites is real and independently reproduced.** The disagreement is entirely
about how the finding should be framed, and it rests on project context the audit's author could not
have had:

1. `--compact` was not an oversight discovered after the fact — it was built **specifically to solve
   this exact problem**, using this **exact same 520K→60M measurement** as its own stated motivation
   (`references/compaction.md`'s own "What this fixes" section cites it verbatim). The audit is
   independently re-deriving a problem statement this project already wrote down and already shipped
   one mitigation for.
2. The decision to ship it **opt-in rather than default-on** was itself deliberate and reasoned, not
   an oversight: `references/compaction.md` states outright, "Starting as opt-in... is deliberate:
   this is a genuinely new failure surface... that has not yet been validated against real reviews the
   way the always-on mechanisms have." This project's own remediation history in this exact session
   independently corroborates that caution was warranted — the compaction/restart mechanism itself
   went through multiple real bug-fix rounds (a `no_material_reviewed` restart-safety exception, a
   `--resume` argument-combination constraint, snapshot-revalidation ordering) before being trusted.
   Flipping it to default-on before more real-world runs have exercised it would trade one measured
   risk (context growth) for a less-measured one (an under-exercised restart path becoming
   load-bearing for every run instead of only opted-in ones).
3. The audit's own "smallest safe next action" for PCA-001 — "use `--compact` operationally now,"
   "do not restore a blind byte ceiling," "collect real data before choosing a default policy" — is
   not a new recommendation from this response's point of view. It is a restatement of the exact
   position this project already holds and has already partially acted on (candidate already tracked
   in `ccs_backlog_from_real_usage_feedback.md`).

None of this makes PCA-001 false or unimportant — unbounded growth in default mode is real, and this
response is not disputing that. What is being disputed is the audit's framing of it as a fresh,
unaddressed "High" severity gap sitting on equal footing with a concrete, guaranteed-wrong JSON
literal (PCA-002). This response's position, stated precisely: **the retained-context risk is known;
an opt-in mitigation (`--compact`) is shipped (`ccs_backlog_from_real_usage_feedback.md`'s own
Candidate 3 entry records it as SHIPPED, not as an open decision); the project deliberately keeps it
opt-in pending further real-review validation before any default-policy change.** That is "known,
deliberately deferred; re-evaluate after measured runs" — not "already an open, explicitly tracked
default-policy task" with its own owner or milestone, since no such tracked decision item currently
exists. The audit's own recommended next step (gather real usage data before changing the default) is
correct and already the plan — but it does not currently warrant new code changes beyond what is
already shipped.

**Verdict: no dispute on the facts; dispute the "fresh High-severity gap" framing. No new fix
dispatched from this response — a known, deliberately-deferred tradeoff, not an open policy task with
an owner or milestone.**

## O-001 through O-004 — no dispute

The audit itself explicitly declines to call these confirmed defects ("not a demonstrated
contradiction or bypass," "no bypass was shown," "did not run an A/B comparison, so it cannot claim
the complete corpus currently causes worse results"). This response agrees with that hedging and,
separately, agrees with the audit's own sequencing: O-002 and O-003 both describe prompt-wording
tweaks that are cheap to make but currently unverifiable, since the adversarial fixture needed to
check whether a wording change actually helps (rather than silently making things worse) is precisely
the artifact PCA-004 proposes building. Changing prompt wording ahead of having that fixture would be
tuning on vibes with no way to detect a regression. **Agree: build PCA-004's fixture first; revisit
O-002/O-003 wording only once it exists to validate against.**

## Proposed remediation plan (pending consensus)

1. **Now, this pass:** fix PCA-002 (correct the invalid/incomplete JSON example; add a deterministic
   `jq -e .` + schema-validation test for it) and PCA-003 (add a short safe-input-template doc section
   to `skills/stream-review/SKILL.md`, no wrapper code change). Both routed through
   `codex-stream-review:ccs` review under the skill's normal 20-round hard cap (`skills/ccs/SKILL.md`
   line 39) — per this project's standing practice, review/fix rounds will not be self-limited for
   cost reasons short of that cap, but no unlimited mode exists.
2. **Tracked as a separate, dedicated follow-up project (not this pass):** PCA-004's prompt-capture
   fixture + curated live-eval corpus. This deserves its own design cycle given its scope.
3. **No change from this response:** PCA-001. A known, deliberately-deferred tradeoff with a shipped
   opt-in mitigation — not an open policy task with an owner or milestone; this response's only
   addition is the context above for why "High severity, act now" is not the right frame given what
   already exists and why it was built opt-in.
4. **No change from this response:** O-001 through O-004. Agreed to defer per the audit's own
   sequencing (PCA-004 first).

This document is written for relay back to the independent Codex CLI session that authored the
audit, to reach explicit consensus on severity/scope before any fix is dispatched — per this
project's established multi-round document-relay verification pattern.

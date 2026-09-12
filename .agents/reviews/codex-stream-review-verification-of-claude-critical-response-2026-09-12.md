# Verification of Claude's Critical Response to the Prompt/Context Audit

- **Date:** 2026-09-12 (Asia/Seoul)
- **Document reviewed:** .agents/reviews/codex-stream-review-claude-critical-response-to-prompt-context-audit-2026-09-12.md
- **Source audit:** .agents/reviews/codex-stream-review-prompt-context-audit-2026-09-12.md
- **Checkout verified:** docs/ccs-prompt-context-audit-critical-response at 806c91d
- **Scope:** Verify the response's factual claims, its severity/scheduling rebuttals, and whether its proposed work split follows from the current source. This report does not change production code or invoke a live Claude/Codex backend.

## Overall result

The critical response is substantively accurate on all four underlying source facts. Its strongest
correction is PCA-001: the unbounded default-history behavior is real, but it was already known,
documented, and deliberately mitigated by an opt-in compaction design. That changes the remediation
framing from “new, unaddressed defect” to “known operational risk that needs measured policy data.”
It does not make the default-mode behavior disappear.

PCA-002 should be fixed immediately. PCA-003 should remain a confirmed interface gap but be
prioritized Low rather than Medium. PCA-004 must be split: a deterministic rendered-prompt capture
test is a bounded extension of the existing fake-Codex fixture, while a curated paid/live model
corpus is correctly a separate design and evaluation project. Treating both as one indivisible,
large infrastructure project would defer the inexpensive deterministic protection without source
evidence that it requires such a delay.

Two wording corrections are required in the response document itself:

1. Its proposed plan says the work will be reviewed through ccs “with no round limit.” The current
   skill has a hard cap of 20 rounds; no unlimited mode was found.
2. Its cited Candidate 3 record proves that the opt-in feature shipped, not that a future
   default-policy decision is an open, explicitly tracked item. “Known and deliberately deferred”
   is supported; “already an open tracked default-policy task” needs a specific tracker if retained.

## Verified disposition matrix

| Item | Disposition | Evidence-based conclusion |
|---|---|---|
| PCA-001 | **Partially accepted / reframed** | Retain the confirmed default-mode retained-context risk. Accept that it is not a newly discovered or neglected problem, and do not make compaction default-on without real-evaluation data. Keep “High” as an impact description only if it is explicitly separated from immediate implementation priority. |
| PCA-002 | **Accepted** | The displayed “exact” example is invalid JSON and omits schema-required top-level fields. Correct it and add a deterministic regression check now. |
| PCA-003 | **Accepted with severity change** | The verbatim raw-stdin interface and lack of an instruction/data marker are confirmed. Because this is documented as an experimental, lower-level caller-owned interface and no live bypass was demonstrated, Low is the proportionate priority. |
| PCA-004 | **Partially accepted / split** | The coverage gap is confirmed. Defer the paid/live corpus as its own project, but do not conflate it with the small deterministic prompt-capture fixture. |
| O-001 through O-004 | **Accepted** | They remain observations/hypotheses rather than demonstrated defects. Do not tune wording based only on intuition; use the future live corpus for quality claims. |
| Response-plan wording | **Two documentation corrections required** | “No round limit” contradicts the current ccs hard cap. The cited shipped Candidate 3 record does not itself establish an open default-policy tracking item. |

## Verification method and checkout state

Before this report was added, the branch comparison against origin/main showed only three added
review documents:

    A  .agents/reviews/codex-stream-review-claude-critical-response-to-prompt-context-audit-2026-09-12.md
    A  .agents/reviews/codex-stream-review-prompt-context-audit-2026-09-12.md
    A  .agents/reviews/codex-stream-review-second-response-verification-2026-09-12.md

Therefore the response is a proposal and analysis, not evidence that any PCA-002/PCA-003/PCA-004
source or test remediation has already landed.

The verification directly re-read the response, the source audit, current skill/reference files,
both wrapper paths, the verdict schema, the fake-Codex fixture, the deterministic test harness, the
eval documentation/workflow, and the cited project-memory/design records. It also ran the focused
commands recorded below. No live model call, paid evaluation, or model-quality A/B experiment was
performed.

## PCA-001 — known opt-in mitigation changes framing, not the current default behavior

### Facts confirmed from current source

1. skills/ccs/SKILL.md:21-33 sets the normal ccs maximum at 20 rounds and documents
   --compact as an independent opt-in flag. The flag triggers only after a round reports at least
   8,000,000 input tokens.
2. skills/ccs/references/compaction.md:4-6 explicitly says an OFF session is the default and has
   zero compaction behavior.
3. The same reference, lines 10-19, explicitly says nothing prunes accumulated resumable-thread
   history and records the project's historical approximately-520,000-to-more-than-60,000,000-token
   measurement. This verifies that the measurement is documented by the project; it does not
   independently reproduce the historical live run.
4. compaction.md:43-45 says the opt-in choice is deliberate because restart/compaction is a new
   failure surface not yet validated against real reviews.
5. .serena/memories/ccs_backlog_from_real_usage_feedback.md:87 and :125-135 label Candidate 3 as
   **SHIPPED** and describe the implemented opt-in feature, its threshold, and its circuit breakers.
6. docs/2026-09-09-ccs-opt-in-compaction-design.md:3-13 identifies itself as superseded and names
   the current compaction reference as authoritative.

These facts support the response's central rebuttal at response lines 103-154: the original audit
rediscovered a documented problem for which a deliberately conservative opt-in mitigation already
exists.

### What remains true

The default path is still not compacted. The historical risk described in the audit remains applicable
whenever a caller does not supply --compact. The current reference also uses a fixed threshold only
when the opt-in mode is enabled; it is not an aggregate default-mode budget. Thus the factual
PCA-001 conclusion must not be retracted.

The source audit already avoided recommending an immediate default-on change. At source-audit
lines 198-206 it says to use existing --compact for intentionally long reviews, not restore a blind
byte cap, and collect real token/convergence/failure data before selecting a policy. Its remediation
order at lines 385-392 likewise puts a measured live corpus before a default-policy change. The
response correctly adds project history, but slightly overstates the disagreement if it characterizes
the audit as demanding an immediate default-on implementation.

### Precise consensus

Use this framing going forward:

- **Confirmed condition:** Default ccs sessions retain unpruned resumable history.
- **Risk:** Potentially high cost/reliability impact for long sessions; this is neither a Bash/Python
  heap leak nor a demonstrated current quality failure.
- **Current mitigation:** A deliberate, shipped, opt-in --compact mechanism.
- **Current decision:** No default-policy or threshold change without measured real-run results.

The response's phrase “already an open, explicitly tracked” needs tightening. Its cited Candidate 3
heading says SHIPPED, while compaction.md documents a rationale for remaining opt-in. Those sources
prove a known mitigation and deliberate deferral; they do not name an owner, milestone, or explicit
next decision for making compaction default-on. The remediation ledger at
.agents/reviews/.audit-remediation-ledger.md:25 does say to track a broader aggregate-budget topic as
a future candidate, but it is not a concrete default-policy plan. “Known, deliberately deferred
tradeoff; re-evaluate after measured runs” is the fully supported wording.

## PCA-002 — fully confirmed and suitable for immediate deterministic remediation

Current scripts/run-ccs-review.sh:298-305 says “Respond with ONLY valid JSON matching this exact
shape” and emits the following pseudo-value inside the literal:

    "line": integer >= 1 or null

The following focused command extracted the current line-305 literal and attempted to parse it:

    sed -n '305p' codex-stream-review/scripts/run-ccs-review.sh | awk -F"'" '{print $2}' | jq -e .
    jq: parse error: Invalid numeric literal at line 1, column 77

The same command listed the canonical top-level required fields from
schemas/review-verdict.schema.json:

    verdict
    findings
    summary
    dimensions
    material_reviewed
    material_receipt
    material_receipt_index

No occurrence of material_reviewed, material_receipt, or material_receipt_index exists in the
displayed literal. The schema requires all three at lines 92-97, and the wrapper's semantic
validation requires them at scripts/run-ccs-review.sh:1183-1188.

This fully supports response lines 25-48. The surrounding prose and output-schema enforcement
mitigate the result, but cannot make the phrase “exact shape” accurate. The response's proposed
priority is sound: correct the literal now and leave a deterministic regression check behind.

A minimal test need not wait for a live-evaluation project. At minimum it must parse the actual
rendered/example bytes and assert the required field set. Capturing the rendered prompt, discussed
under PCA-004 below, is stronger than duplicating the literal in an unrelated test because it detects
future drift in build_review_prompt() itself.

## PCA-003 — confirmed raw interface, Low priority is proportionate

The current stream-review documentation explicitly calls itself “experimental” and “lower-level” at
skills/stream-review/SKILL.md:3-6 and :22-30. It then states at lines 86-94 that it reads stdin in
full, forwards it verbatim to Codex, and makes scope the caller's responsibility.

The implementation matches that contract:

- scripts/run-stream-review.sh:172-181 copies stdin byte-for-byte to FOCUS_RECEIVED_FILE.
- The fresh and resumed dispatches redirect that unmodified file to Codex at lines 238-244.

The exact scoped search below produced no matches:

    rg -n -i 'untrusted|injection' \
      codex-stream-review/skills/stream-review/SKILL.md \
      codex-stream-review/scripts/run-stream-review.sh

This confirms the absence of a documented prompt-level trust/data boundary in the two relevant
stream-review files; it does not prove that a model will be bypassed. The ccs path is materially
different: scripts/run-ccs-review.sh:139-153 defines an untrusted-data boundary notice and
build_review_prompt() applies it to Context and diff material at lines 167-193 and 307-312.

The response's severity argument at lines 50-73 is accepted. This is not a broken ccs guarantee,
there is no demonstrated exploit, and the raw wrapper's documented purpose is caller-controlled
input. A short safe-input template is an appropriate Low-priority documentation fix: trusted task
instructions, an explicitly delimited pasted artifact, and a final output requirement. A wrapper
abstraction should remain out of scope unless actual users show that documentation is insufficient.

## PCA-004 — coverage gap confirmed; split the deterministic and live work

### Directly verified gap

tests/fixtures/fake-codex:8-17 documents the redirect form used by the wrapper and explicitly says
stdin (the prompt) is never read. The executable's behavior is selected through FAKE_CODEX_* values
and no existing branch reads standard input. The deterministic harness wires that fake into PATH at
tests/test-run-ccs-review.sh:65-72. Its normal post-dispatch helper supplies only a one-character
focus and inspects wrapper output at lines 303-347; it has no assertion over the prompt sent to the
fake.

The on-disk inventory was independently counted:

    scenario directories: 46
    setup.sh files:       44
    expect.sh files:      44

evals/README.md:214-247 identifies parallel-live-acceptance and
claim-ledger-live-acceptance as the only two real, unscripted Codex scenarios. It describes the
other 42 as scripted fake-Codex flows. The live-eval workflow confirms the larger automation gap:
.github/workflows/codex-stream-review-live-eval.yml:82-93 has no headless-agent driver even if its
credential is configured.

Thus response lines 75-101 correctly reproduce the coverage facts.

### Scope assessment

The response is correct that a maintained, repeated, paid/live corpus needs its own design cycle.
It must decide the model/version, fixture design, repetitions, baseline comparison, cost authority,
and objective success measures. The source says the workflow currently lacks the required
headless-agent driver, so that part is not a same-pass bug patch.

The response is too broad when it treats the deterministic prompt-capture fixture as inherently the
same project. The existing fake is already a test-only executable with many optional FAKE_CODEX_*
behaviors (for example, its invocation-log option at lines 85-110), and the test suite already
injects it through a private PATH. An optional test-only capture path plus assertions over captured
stdin would exercise build_review_prompt() without a backend call or a new external system.

This is a scope judgment, not a claim that the change is literally one line: the exact assertions
must safely handle the per-run random boundary. Nevertheless, the current fixture architecture is
direct evidence that this is a bounded test extension rather than a prerequisite live-evaluation
platform.

The correct split is therefore:

1. Correct PCA-002 and add a deterministic parse/schema regression check now.
2. Add deterministic rendered-prompt assertions as a small test-only follow-up, optionally in the
   same narrowly scoped batch. Assert boundary pairing/placement, the corrected schema-complete
   example, and that chosen untrusted fixture bytes occur only within their generated marker.
3. Track the adversarial/multi-round/large-history live corpus as a separate project. Do not claim
   that deterministic byte assertions establish model-instruction-following quality.

## O-001 through O-004 — deferral remains evidence-based

The source audit explicitly labels these as observations requiring validation rather than confirmed
defects. In particular, it records no A/B result for the large corpus (O-001), no demonstrated
boundary bypass (O-002/O-003), and no deterministic failure for the CI instruction hierarchy
(O-004).

The response's sequencing is valid with one distinction:

- A deterministic capture test can verify that boundary and JSON-contract text is emitted in the
  intended order.
- It cannot determine whether a wording change improves an LLM's behavior. That requires the
  proposed live adversarial corpus and repeatable quality measurements.

Accordingly, do not make speculative O-002/O-003 wording changes first. Also do not delay the
known-invalid PCA-002 literal waiting for a model-quality evaluation.

## Response-document precision corrections

### DR-001 — “no round limit” contradicts the skill contract

Response lines 170-173 say PCA-002/PCA-003 would be routed through ccs “with no round limit.”
Current skills/ccs/SKILL.md:39 states that ccs runs until consensus “or until a hard cap of 20 rounds
is hit.” The same source provides only MAX_ROUNDS = 5 for --quick or 20 otherwise, and the focused
search found no unlimited override:

    rg -n -i 'round limit|MAX_ROUNDS|hard cap|unlimited|no round' \
      codex-stream-review/skills/ccs/SKILL.md \
      codex-stream-review/scripts \
      codex-stream-review/tests

The response should say “under the normal 20-round ccs cap” unless a new, separately implemented
unbounded mode is intended. This is a documentation-accuracy issue, not a defect in the proposed
PCA-002/PCA-003 fixes.

### DR-002 — distinguish shipped mitigation from an open policy item

Response lines 148-154 and 176-178 describe PCA-001 as already an “open, explicitly tracked”
item, while its cited Candidate 3 source calls the feature SHIPPED. The evidence supports the
following narrower statement:

> The retained-context risk is known; an opt-in mitigation is shipped; the project deliberately
> keeps it opt-in pending further real-review validation.

If the response intends to assert a currently open decision about the default policy, it should
link a specific issue, backlog item, owner, or milestone for that decision. No such specific item
was identified in the cited Candidate 3 section.

## Recommended consensus sequence

This is a recommendation only; no implementation was performed by this verification.

1. **PCA-002 now:** Replace the invalid/incomplete displayed JSON example and add a deterministic
   check against the actual emitted example.
2. **PCA-003 next, Low:** Add a concise safe raw-input template to stream-review documentation. Do
   not add a wrapper mode without evidence that documentation fails in practice.
3. **PCA-004 deterministic slice:** Extend the existing fake-Codex test fixture to capture a prompt
   only when a test enables it; add structural rendered-prompt assertions. This does not need a
   paid/live backend.
4. **PCA-004 live slice:** Open a separate design/evaluation effort for the curated live corpus and
   obtain the authority/credentials needed for paid model runs before executing it.
5. **PCA-001:** Use --compact for intentionally long/broad work and collect actual token,
   reliability, convergence, and quality data before changing the default policy.

## Limits of this verification

- Historical 520K-to-60M figures were verified as project-documented measurements, not reproduced
  against a live backend here.
- No prompt injection was live-demonstrated, and no model-quality or context-size A/B claim is made.
- The branch being reviewed adds documentation only; this report therefore makes no claim that the
  proposed remediations are already implemented or passing.

## Final conclusion

The response reaches sound consensus on the core facts and correctly resists an unmeasured
default-on compaction change. Accept PCA-002 immediately, reclassify PCA-003 as Low, and split
PCA-004 at the real boundary between deterministic prompt rendering and live model evaluation.
Correct DR-001 and DR-002 in the response record so its process claims remain as evidence-based as
its technical analysis.

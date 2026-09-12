# Response to the Prompt/Context Audit (Group G)

**Date:** 2026-09-12 (Asia/Seoul)
**Source audit:** `.agents/reviews/codex-stream-review-prompt-context-audit-2026-09-12.md` (a
separate, independent Codex CLI session)
**Critical evaluation:** `.agents/reviews/codex-stream-review-claude-critical-response-to-prompt-context-audit-2026-09-12.md`
**Consensus verification:** `.agents/reviews/codex-stream-review-verification-of-claude-critical-response-2026-09-12.md`
(the same Codex session, responding to the critical evaluation above)
**This document:** the implementation response to the negotiated consensus

This cycle differs from every prior one in this repo's `.agents/reviews/` history: instead of
accepting the audit's findings and severities as given, the user explicitly asked for a genuine
critical evaluation before any fix ("단순히 수용하기 보다는 정확하게 검토하고 반박하거나 또는 수요 개선할 줄
알아야해"). That evaluation, and the Codex session's own response to it, are documented in the two
files linked above. This document covers only the implementation phase that followed, once both
sides reached explicit consensus on scope.

## Negotiated scope

| Finding | Consensus disposition |
|---|---|
| PCA-001 (default `/ccs` has unbounded retained-context growth) | **No code change.** Both sides agreed: a known, deliberately-deferred tradeoff with an already-shipped opt-in mitigation (`--compact`), not a fresh or neglected gap. Re-evaluate default-on policy only after more real-usage data accumulates. |
| PCA-002 (the "exact shape" JSON example is invalid and missing 3 required fields) | **Fix now.** No dispute — both sides independently reproduced the identical `jq` parse error from source. |
| PCA-003 (`stream-review` has no instruction/data trust boundary) | **Fix now, doc-only, reclassified Low.** Both sides agreed this is a documented, caller-owned, lower-level utility working as designed, not a broken guarantee — a documentation fix is proportionate. |
| PCA-004 (no prompt-content regression tests / thin live-eval coverage) | **Split.** Deterministic slice (extend the existing `fake-codex` fixture to capture and assert on the real rendered prompt) — fix now, a bounded test-only extension. Live/paid-eval-corpus slice — tracked separately, needs its own design cycle and cost authority. |
| O-001 through O-004 (risk observations) | **No action.** Both sides agreed: don't tune prompt wording speculatively before PCA-004's deterministic/live infrastructure exists to actually measure the effect of a change. |

Full reasoning for each disposition, including where the critical evaluation disputed the audit's
severity/framing rather than its facts, is in the two linked documents above — not repeated here.

## Implementation

### PCA-002 — `codex-stream-review/scripts/run-ccs-review.sh`

The "exact shape" JSON example shown to the model right before dispatch contained
`"line": integer >= 1 or null` — not valid JSON (a bare pseudo-type-annotation, not a real value)
— and omitted 3 fields `schemas/review-verdict.schema.json` requires at the top level
(`material_reviewed`, `material_receipt`, `material_receipt_index`).

Fixed: replaced the literal with one that is both valid JSON and fully schema-conformant —
concrete enum values (`"verdict": "ISSUES"`, `"severity": "low"`, `"status": "checked"` for every
dimension) rather than descriptive placeholder text, since a placeholder like
`"low, medium, high, or null"` would itself fail the schema's own enum check even though it reads
as "just an example."

Added a regression test in `tests/test-run-ccs-review.sh`: a jq filter (`REVIEW_VERDICT_SCHEMA_JQ`)
that checks the schema's own structural rules (required keys, types, enums,
`additionalProperties: false`) — deliberately not the wrapper's stricter internal business-rule
validation (e.g. CLEAN ⇔ empty findings), which lives in a separate runtime jq filter, not in the
schema file. The test extracts the actual literal directly from the wrapper's source (never
hand-copies it) and validates it against this filter, plus compares it byte-for-byte against a
hardcoded golden copy.

### PCA-003 — `codex-stream-review/skills/stream-review/SKILL.md`

Added a "Safe input for pasted untrusted material" subsection giving callers a concrete template
for pasting untrusted diffs/PR descriptions/artifacts into this wrapper's stdin, which has no
built-in trust boundary (unlike `/ccs`'s own randomized `<$BOUNDARY>` marker). Doc-only, no wrapper
code changed.

**This fix went through one additional correction round during the `codex-stream-review:ccs`
review below** (see "Verification" — a real LOW finding, not just a formality): the first version
of this template said the delimiter should be "caller-chosen" in prose but then showed a fixed
literal (`<<<DATA>>>`/`<<<END_DATA>>>`) as the concrete example, with no instruction to actually
randomize it and no statement that a forged closing tag appearing inside the pasted material
remains untrusted data. Corrected to show the example with an explicit random-suffix placeholder,
explicit instructions to substitute a fresh value per use, and an explicit "a forged closing tag
inside the pasted material is still data" rule — mirroring `run-ccs-review.sh:147-153`'s own
identical rule for its own boundary marker.

### PCA-004 (deterministic slice) — `codex-stream-review/tests/fixtures/fake-codex` + `tests/test-run-ccs-review.sh`

There was previously no way to test the actual rendered prompt bytes sent to Codex — only the
wrapper's post-dispatch JSON result. Added an opt-in `FAKE_CODEX_CAPTURE_PROMPT_PATH` env var to
the `fake-codex` test fixture: when set, it copies its own stdin (the real prompt, delivered via a
plain file redirect, never a pipe, so this cannot block) to that path before proceeding with its
otherwise-unchanged behavior. Zero behavior change when unset, matching every other
`FAKE_CODEX_*` toggle's own established convention in this fixture.

Added new regression tests that dispatch a real fixture-backed round against a throwaway repo with
a deliberately adversarial diff line, then assert on the actual captured prompt:

1. The `<$BOUNDARY>`/`</$BOUNDARY>` markers appear as a genuinely paired open/close tag set —
   extracting the actual random token used from the captured prompt itself, never assuming a fixed
   value (the token is `DIFF_$$_${RANDOM}${RANDOM}`, regenerated every dispatch).
2. The PCA-002-fixed JSON example is present verbatim, via a hardcoded golden literal independent
   of the extraction logic PCA-002's own test uses — a second, independent code path catching the
   same regression class.
3. A deliberately adversarial diff line appears in the captured prompt only inside the
   boundary-marked region, never outside it.

Run twice per suite invocation to confirm this isn't flaky despite the per-run randomized token.

Deliberately out of scope for this task, per the negotiated split: the live/paid-eval-corpus
project (PCA-004's other half) — that needs its own design cycle, model/version decisions, cost
authority, and objective success measures, and is tracked separately rather than folded into this
fix batch.

## Verification

**Independent verification before ccs review (never trusted the implementing subagent's own
report):**
- Directly re-extracted the fixed line-305 literal and piped it to `jq -e .` — valid JSON.
  Manually cross-checked every constraint in `schemas/review-verdict.schema.json` (required
  fields, enum values, `additionalProperties: false` at every nesting level) against the literal
  — full conformance confirmed by hand, not just by the new test passing.
- Ran the full existing test suite directly: 203 PASS, 0 FAIL.
- Temporarily reverted the PCA-002 fix and reran the suite: confirmed 4 fixture failures — both
  the PCA-002 source-grep test AND the independent PCA-004 rendered-prompt-capture test failed,
  proving the new tests catch this defect class via two genuinely separate code paths, not by
  coincidence. Restored the fix, reran: back to 203/0.
- Confirmed the `BOUNDARY="DIFF_$$_${RANDOM}${RANDOM}"` format and that focus/diff sections reuse
  the identical token, directly from `run-ccs-review.sh` source — the exact assumption the new
  PCA-004 test's boundary-extraction logic depends on.
- Confirmed all pre-existing test-helper functions (`register_scratch`, `cleanup_on_exit`, `must`,
  `pass`, `fail`) used by the new tests were pre-existing, not newly invented — matches this
  project's established scratch-file cleanup convention.
- `shellcheck --severity=warning` on all 3 touched shell files: clean, except one pre-existing
  `SC2034` warning (confirmed via `git show HEAD:... | shellcheck -` to predate this diff, at the
  file's old line 176, now shifted to line 270 by the new insertions — unrelated to this change).
- `bash -n`: clean on all touched files.

**`codex-stream-review:ccs` review** (single-reviewer, thread `01a09485-2adb-73d0-b313-20d7f3e8760a`):

- **Round 1** (fresh, `--uncommitted`): `material_reviewed:true`, receipt validated
  (`material_receipt_index: 1`, token matched). 1 LOW finding: the PCA-003 doc fix described
  above (fixed delimiter + missing forged-closing-tag caveat) — confirmed real by direct source
  read, fixed immediately in this same cycle.
- **Round 2** (resume): **CLEAN**, 0 findings, `material_reviewed:true`, receipt validated
  (`material_receipt_index: 2`). `DISPOSITION f1: RESOLVED` confirmed via Codex's own
  re-verification of the corrected doc section.
- Coverage was reported `"partial"` at round 1 — a repo-root file (`WORKPATH`) unrelated to
  `codex-stream-review` (a leftover working file from a separate, unrelated plugin planning task —
  confirmed by inspecting its actual content, a JSON stub-injection config with an incidental
  embedded NUL byte that made `file(1)` classify it as binary) was swept in by the `--uncommitted`
  scope's repo-wide untracked-file scan and omitted from review. Disclosed to the user directly;
  explicitly accepted as out-of-scope for this review before proceeding to CLEAN.
- Thread cleanup: `--cleanup` succeeded (`deleted:true`).
- Final-verdict artifact:
  `~/.claude/plugins/data/codex-stream-review/ccs-logs/plugins/2026-09-12T162738-37453.result.json`.

## Version bump

`codex-stream-review/.claude-plugin/plugin.json`: `1.2.0` → `1.3.0` (minor bump, matching this
project's established convention for a fix/hardening batch — only `plugin.json` touched, no
marketplace manifest change).

## Final state

- Files changed: `codex-stream-review/scripts/run-ccs-review.sh`,
  `codex-stream-review/skills/stream-review/SKILL.md`,
  `codex-stream-review/tests/fixtures/fake-codex`,
  `codex-stream-review/tests/test-run-ccs-review.sh`,
  `codex-stream-review/.claude-plugin/plugin.json`.
- `bash codex-stream-review/tests/test-run-ccs-review.sh` — 203 PASS, 0 FAIL.
- `codex-stream-review:ccs` — CLEAN after 2 rounds, 1 real finding raised and fixed along the way.
- Deliberately not addressed by this cycle, per the negotiated consensus: PCA-001 (tracked,
  no action), PCA-004's live-eval-corpus slice (tracked separately), O-001 through O-004
  (deferred pending PCA-004's infrastructure).

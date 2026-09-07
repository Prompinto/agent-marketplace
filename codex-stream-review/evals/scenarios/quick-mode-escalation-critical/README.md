# Scenario: quick-mode-escalation-critical (documentation-only stub -- no `setup.sh`/`expect.sh`)

**Group:** G (quick mode)
**Would-be target:** identical shape to `quick-mode-escalation-high`, but the triggering finding's
severity is `CRITICAL` instead of `HIGH` -- intended to prove neither literal is accidentally
omitted from the escalation predicate ("HIGH or CRITICAL").

## Why this is not a live, dispatch-driven Tier 2 scenario

Confirmed directly, not assumed: `severity` in this codebase is exactly `low`/`medium`/`high`/`null`
-- there is no `critical` value, and there never can be one through a real (or a
faithfully-scripted, schema-compliant fake-codex) dispatch response.

Evidence:
- `schemas/review-verdict.schema.json` (the finding shape every dispatch response must satisfy) and
  `schemas/interactive-result.schema.json` (claims[].severity in the final artifact): both enums are
  exactly `["low","medium","high",null]`.
- `scripts/run-ccs-review.sh` (around its `emit_final_output`/semantic-verdict check): the wrapper's
  own mandatory cross-field validation rejects ANY severity value outside `low|medium|high|null`
  with `{"ok":false,"reason":"schema_mismatch",...}` -- on a fresh dispatch AND a `--resume` dispatch
  alike, and regardless of whether the underlying `codex` binary is real or
  `tests/fixtures/fake-codex` (this validation is the WRAPPER's own post-processing of whatever the
  `-o`/`--output-last-message` file contains -- it runs unconditionally, not something a fake
  `codex` binary can bypass).
- `tests/test-run-ccs-review.sh` already has a standing regression test proving
  `"severity":"critical"` is rejected as `schema_mismatch` (see that file's own
  `pd_variant '.verdict = "ISSUES" | .findings = [...,"severity":"critical",...]'` fixture).
- `schema_mismatch` is itself resume-safe and automatically retried
  (`references/retry-guards.md`) -- and because `FAKE_CODEX_GROUP_STATE`'s own round counter
  advances on EVERY invocation regardless of outcome, a retry would silently consume the NEXT
  scripted `round-N-final-answer.json` file, desynchronizing the whole intended transcript rather
  than failing cleanly in place.

So a live session scripted to hit this case would never reach "Phase 2 reads a finding with
severity CRITICAL" at all -- that round would fail `schema_mismatch` before any finding is ever
parsed, exercising the retry-guards path instead of the escalation predicate this scenario is
meant to test.

## Where this coverage actually lives instead

`SKILL.md`'s own escalation predicate ("HIGH or CRITICAL") and the MINOR-ISSUES-ACKNOWLEDGED
decision's UNPARSEABLE fail-closed subcase are still implemented exactly as designed (see Phase 2's
"Escalation" paragraph and the Guards section's "Quick-mode early stop" bullet) -- `CRITICAL` is
kept as a documented, forward-compatible branch. Its behavior is covered as a **Tier 1 unit test**
against the extracted, deterministic canonical-severity/decision logic instead of a live Tier 2
dispatch scenario, since the wrapper's own schema simply cannot produce this input via any real
call:

- Filter: `tests/fixtures/quick-mode-decision.jq`
- Test: `tests/test-run-ccs-review.sh`, "quick-mode canonical-severity/MINOR_ISSUES_ACKNOWLEDGED
  decision fixtures" section -- case "an open claim whose latest severity is CRITICAL is NOT
  eligible for MINOR_ISSUES_ACKNOWLEDGED"

This bypasses dispatch entirely (the filter operates on a hand-built JSONL fixture, not a live
`run-ccs-review.sh` call), which is exactly what makes the otherwise-unreachable `CRITICAL` value
testable at all: as a pure input to the decision logic, not as a claimed wrapper output.

This discrepancy and this handling plan were flagged to the task's own requester before building it
this way (see this session's own coordination message), rather than silently dropping the scenario
or the coverage it was meant to provide.

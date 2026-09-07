# Scenario: quick-mode-unparseable-severity-fail-closed (documentation-only stub -- no `setup.sh`/`expect.sh`)

**Group:** G (quick mode)
**Would-be target:** a `--quick` session hitting round 5 where the sole open claim's own
most-recently-recorded severity value is a string that doesn't match `LOW`/`MEDIUM`/`HIGH`/
`CRITICAL` (e.g. `"SEV-2"`) -- intended to prove the UNPARSEABLE fail-closed subcase of
`SKILL.md`'s "Quick-mode early stop" bullet correctly falls through to `NOT_CONVERGED`, never
`MINOR_ISSUES_ACKNOWLEDGED`.

## Why this is not a live, dispatch-driven Tier 2 scenario

Same root cause as `quick-mode-escalation-critical`'s own README (read that file for the full
evidence chain): `scripts/run-ccs-review.sh`'s own mandatory semantic-verdict check rejects ANY
`severity` value outside `low`/`medium`/`high`/`null` as `schema_mismatch`, unconditionally, on
fresh and resumed dispatches alike, regardless of whether `codex` is real or
`tests/fixtures/fake-codex`. A scripted `"severity":"SEV-2"` finding is therefore, if anything, an
even less reachable case than the MISSING (`null`) subcase covered by the live
`quick-mode-missing-severity-fail-closed` scenario: `null` is an explicit legal enum value that
passes the wrapper's check cleanly, but any other non-enum string never does. There is no way to get
a genuinely garbage severity string in front of Phase 2's own per-finding read without a round
failing `schema_mismatch` first (and, per `references/retry-guards.md`, being retried -- which,
under `FAKE_CODEX_GROUP_STATE`'s ever-advancing round counter, would desynchronize the rest of the
scripted transcript rather than surface the intended finding at all).

## Where this coverage actually lives instead

- Filter: `tests/fixtures/quick-mode-decision.jq`
- Test: `tests/test-run-ccs-review.sh`, "quick-mode canonical-severity/MINOR_ISSUES_ACKNOWLEDGED
  decision fixtures" section -- case "an open claim whose latest severity is an unparseable string
  (SEV-2) is NOT eligible for MINOR_ISSUES_ACKNOWLEDGED"

The filter operates on a hand-built JSONL fixture with an intentionally-invalid `severity` value --
bypassing the wrapper's own dispatch-time schema enforcement entirely, which is exactly what makes
this otherwise-unreachable case testable at all: as a pure input to the decision logic, never as a
claimed wrapper output.

This discrepancy and this handling plan were flagged to the task's own requester before building it
this way (see this session's own coordination message), rather than silently dropping the scenario
or the coverage it was meant to provide.

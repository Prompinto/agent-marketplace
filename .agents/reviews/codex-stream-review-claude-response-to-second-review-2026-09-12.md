# Response to the Second Independent Review (Group F)

**Date:** 2026-09-12 (Asia/Seoul)
**Reviewed:** `.agents/reviews/codex-stream-review-claude-remediation-review-2026-09-12.md` (a
separate, independent Codex CLI session's verification of the already-merged remediation, PR #19)
**Base commit (before this fix):** `55e6098` (the merged PR #19 tip)
**Final revision:** `7962110`

This document responds to the second independent Codex verification. That review found the
original remediation "materially sound" but raised 4 items (R-001 through R-004). All 4 were
independently re-confirmed as real by direct source reading before any fix was made — none were
disputed or found overstated.

## Findings and fixes

### R-001 (Medium) — the new CI-wrapper test wasn't wired into continuous CI

**Finding:** `.github/workflows/codex-stream-review-ci.yml` only ever ShellChecked/tested
`run-ccs-review.sh`, `git-safe.sh`, `run-stream-review.sh`, and eval scripts. `run-ccs-ci.sh`,
`validate_ci_result.py`, and the new `tests/test-run-ccs-ci.sh` (built during the original
remediation specifically to close part of L-004) had zero coverage in actual continuous CI — only
in local, manually-run tests.

**Fix (commit `c6a86c1`):** extended the workflow's existing ShellCheck and `bash -n` steps to also
cover `run-ccs-ci.sh`, and added 3 new steps: the `test-run-ccs-ci.sh` fixture suite,
`validate_ci_result.py --selftest`, and `evals/lib/validate_interactive_result.py --selftest` (the
second validator, built during the same remediation to replace `schema-check.jq`, also had zero CI
coverage — closed the same way). `scripts/hooks/pre-push` was deliberately left out, matching the
original review's own "Required closure" wording, which only asked for the wrapper + validators.

**Verification:** manually ran every command the new workflow steps would run, directly in this
shell (since no CI runner is available here): `shellcheck --severity=warning run-ccs-ci.sh` (exit
0), `bash -n run-ccs-ci.sh` (exit 0), `bash test-run-ccs-ci.sh` (all fixtures pass), both
validators' `--selftest` (`selftest OK` each). YAML parses correctly (confirmed via Ruby's YAML
loader, no PyYAML available in this environment).

### R-002 (Low) — `test-run-ccs-ci.sh` still had an unnecessary `mktemp -u` and no cleanup trap

**Finding:** the test's own "TOCTOU debris cleanup" fixture used `mktemp -u` to pick a random name
INSIDE an already-private `mktemp -d` directory — no protection is gained from randomizing a path
inside a directory nobody else knows exists. The whole file also had no `EXIT` cleanup trap, unlike
`tests/test-run-ccs-review.sh`'s own already-shipped `register_scratch`/`cleanup_on_exit` registry
pattern from earlier in the same remediation.

**Fix (commit `aff8657`):** replaced the `mktemp -u` call with a fixed filename inside the
already-private directory. Ported the exact same file-based scratch registry pattern from
`test-run-ccs-review.sh` into `test-run-ccs-ci.sh`, registering all 8 of its own
`mktemp`/`mktemp -d` sites.

**Verification:** confirmed via `grep -c "mktemp"` (11 total call sites, including the registry's
own allocation) and `grep -c 'register_scratch "'` (8 matches — every real scratch resource except
the registry file itself, matching the established convention) that the count and coverage are
exact. Confirmed `grep -n "mktemp -u"` now returns nothing (only a comment mentioning the old
pattern remains). Confirmed `trap cleanup_on_exit EXIT` is present. Ran the full test suite twice —
all fixtures pass, no leftover temp files/directories before vs. after.

### R-003 — the installed 1.1.0 plugin cache still has the old override

Already known and disclosed in the original remediation report — not new information, just
independent re-confirmation by the second review. No code change was required for this item
itself; the version bump below is a partial step toward making the fix distinguishable, not a
substitute for an actual plugin republish/reinstall (which remains the user's own operational step,
outside this repository).

### R-004 (Informational) — the remediation report's own commit count was wrong

**Finding:** the final report document stated "18 commits" in its Summary and a table caption, but
`git rev-list --count 331696c..1188d7a` is actually **19** — a plain counting error (the table
itself already listed all 19 rows correctly).

**Fix (commit `3ce9c06`):** corrected both prose mentions in the report to "19", and deleted an
incorrect "18 unique remediation commits" reconciliation sentence that had nothing real to
reconcile.

**Follow-up (commit `7962110`):** the first `codex-stream-review:ccs` review round of this Group F
fix itself found that `.agents/reviews/.audit-remediation-ledger.md`'s own "FINAL STATUS" paragraph
still said "18 commits" — the same error, in a second document the initial R-004 fix didn't touch.
Fixed directly (a trivial single-line correction, not worth a separate subagent dispatch).

## Version bump

**Commit `fcc121d`:** `codex-stream-review/.claude-plugin/plugin.json` version `1.1.0` → `1.2.0` (a
minor bump, matching this project's own established convention for a fix/hardening batch rather
than a new user-facing feature). Only `plugin.json` was touched, matching the prior `1.1.0` bump's
own precedent of not touching the marketplace manifest.

## Verification: `codex-stream-review:ccs` review

- **Round 1** (thread `01a0931b-fa30-73b2-9676-75fc4a363703`): ISSUES — 1 LOW finding (the ledger's
  own stale "18 commits" mention, described under R-004 above). Fixed directly in commit `7962110`.
- **Round 2** (thread `01a09322-5ce7-7bd1-93a6-77e453b83146`): **CLEAN**, `material_reviewed:true`,
  all 7 dimensions checked. Explicitly confirmed the round-1 finding is closed and the full
  `55e6098..HEAD` diff introduces no other defect.

## Final state

- Full commit list for Group F: `c6a86c1`, `aff8657`, `3ce9c06`, `fcc121d`, `7962110` (5 commits,
  directly on `main`, none amending prior history — confirmed `55e6098` remains an ancestor of
  `HEAD`).
- `bash codex-stream-review/tests/test-run-ccs-review.sh` — all fixtures pass.
- `bash codex-stream-review/tests/test-run-ccs-ci.sh` — all fixtures pass, no leftover temp
  resources.
- Both Python validators' `--selftest` — OK.
- `codex-stream-review` plugin version: `1.2.0`.
- These commits are **not yet pushed** — pending the user's explicit go-ahead, since they land
  directly on `main` rather than through a reviewable feature-branch PR.

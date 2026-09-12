# Independent Review of the Claude Remediation for `codex-stream-review`

**Review date:** 2026-09-12 (Asia/Seoul)
**Reviewed response:** `codex-stream-review-full-audit-2026-09-11-claude-verification.md`
**Original audit base:** `331696c5395d89d71f79c05422f45d55aab62ca5`
**Claude response revision:** `1188d7a`
**Current checked-out revision:** `55e6098a52305740b97b92807207cfa6db61525e`

## Scope and evidence standard

This is an independent, source-and-execution-based review of Claude's response, not an acceptance of
the response document's assertions. Every conclusion below is based on at least one of:

- direct reading of the current implementation and test source;
- a fresh local command result recorded in this report; or
- a Git comparison of the cited revisions.

No real Claude/Codex backend call, plugin-cache mutation, user-config mutation, or destructive
workspace operation was performed. Deterministic tests used the repository's fake CLI fixtures.

### Provenance result

The response correctly identifies a historical remediation revision, although the repository is now
on a merged `main` commit:

```text
git diff --name-status 1188d7a HEAD
A  .agents/reviews/.audit-remediation-ledger.md
A  .agents/reviews/codex-stream-review-full-audit-2026-09-11-claude-verification.md
A  .agents/reviews/codex-stream-review-full-audit-2026-09-11.md

git diff --quiet 1188d7a HEAD -- ':(exclude).agents/**'
exit=0
```

Therefore the current production source under `codex-stream-review/` is equivalent to the source
reviewed by Claude at `1188d7a`; only audit documents differ. The findings in this document apply
to the actual current source, not merely to an obsolete branch.

## Executive verdict

The remediation is materially sound. The high-value runtime fixes were independently reproduced as
passing: repeat-signal handling, result-path failure handling, receipt-slot bounds, Git-path
hardening, canonical-schema validation, malformed-JSON diagnostics, and the collector selftest
cleanup. The replacement interactive-result validator is a technically appropriate use of Draft
2020-12 JSON Schema with a tested fail-closed fallback.

It should **not** be described as fully closed without qualification. Four evidence-based items
remain:

1. **Medium — L-004 remains open at the continuous-integration level.** A good deterministic test
   was added for `run-ccs-ci.sh`, but no workflow runs it. The normal plugin CI also still does not
   syntax-check `run-ccs-ci.sh` or run `validate_ci_result.py`'s selftest.
2. **Low — L-005 is only partially fixed.** The new CI-wrapper test still uses `mktemp -u` and has
   no `EXIT` cleanup trap, despite the remediation report calling L-005 fixed.
3. **Release blocker, not a source-code defect — the installed 1.1.0 plugin remains old.** The
   current source has no version change, while the installed 1.1.0 cache still contains the removed
   `model_reasoning_effort=xhigh` override. A versioned publication/update must be verified before
   claiming the fixes reached normal installed use.
4. **Informational — the response's commit-count claim is false.** Its stated Git range contains 19
   commits, not 18. This is a documentation/provenance correction, not a runtime regression.

The intentionally deferred items—SHA-256 object IDs, aggregate resource budgeting, the pre-push
hook behavioral fixture, skill prompt size, and CI trust/API-key residual risk—remain real and are
still present in source. Claude generally describes those deferrals accurately; they must remain
visible in release and maintenance planning rather than being counted as completed fixes.

## Fresh verification performed

| Check | Fresh result | What it establishes |
|---|---|---|
| Shell syntax, JSON syntax, Python compilation | All plugin `*.sh` files passed `bash -n`; all plugin `*.json` files parsed with `jq -e`; the three changed Python validators/helpers compiled successfully. | No syntax/parse failure was found in the reviewed tree. |
| ShellCheck | The only warning was `SC2034` at `tests/test-run-ccs-review.sh:176`; `git blame` attributes it to pre-remediation commit `f438aa3e`. | No new ShellCheck warning was observed in the remediation paths. |
| Main deterministic fixture suite | `bash codex-stream-review/tests/test-run-ccs-review.sh` exited `0` and ended with `All fixtures passed.` | Covers the stream double-signal regression, receipt bounds, Git-safe regressions, wrapper result semantics, and eval contract checks. |
| CI wrapper fixture suite | `bash codex-stream-review/tests/test-run-ccs-ci.sh` exited `0`; all six fixtures passed. | Reproduces the directory-result-path failure, ordinary write path, malformed/invalid-UTF-8 JSON handling, relative `CLAUDE_BIN` rejection, and cleanup expression. |
| Interactive validator, normal and fallback modes | `python3 .../validate_interactive_result.py --selftest` and `python3 -S ... --selftest` both printed `selftest OK`. | Both the installed-`jsonschema` path and the explicit fallback were exercised. |
| CI validator and collector selftests | Both printed `selftest OK`. An isolated collector run reported `collector_selftest_remaining_directory=none`. | Confirms the former `GIT_SAFE_HOME` selftest directory leak is not present in this run. |
| Six malformed interactive artifacts | Numeric `target.repo`, fractional `round_count`, empty `thread_id`, malformed claim, malformed coverage, and an extra top-level key each returned exit `1` in the normal validator, `python3 -S` fallback, and `evals/check-result.sh`. | The former CSR-005 acceptance gap is closed on both validator paths for the audit's relevant malformed shapes. |

Some fixture output included local Git fsmonitor daemon messages. They were emitted by the host Git
environment; the tests themselves passed and the plugin's Git-safety fixtures explicitly exercise
the `core.fsmonitor=` protection. They are not classified as a plugin defect.

## Original audit disposition, independently checked

| Original item | Independent disposition | Current evidence |
|---|---|---|
| **CSR-001** — duplicate final JSON after repeat signal | **Fixed and reproduced.** | `scripts/run-stream-review.sh:55-93` disables `INT`/`TERM` at handler entry, reaps the child, clears `CODEX_PID`, and emits one result. `tests/test-run-ccs-review.sh:572-579` sends two `SIGTERM`s; the fresh full suite reported exactly one interrupted JSON line. |
| **CSR-002** — directory at result destination silently succeeds | **Fixed for the reproduced condition.** | `scripts/run-ccs-ci.sh:154-191` rejects an existing non-regular target and validates the post-rename target. `tests/test-run-ccs-ci.sh:49-77` passed both the directory failure and ordinary-file success controls. The narrow post-check race is documented and cleans the known nested temporary basename. |
| **CSR-003** — receipt slots 71–999 accepted | **Fixed and reproduced.** | `scripts/run-ccs-review.sh` accepts only `[1-9]`, `[1-6][0-9]`, or `70`; the regression at `tests/test-run-ccs-review.sh:636-640` passed for slot 71 rejection, while the suite also passed slots 5 and 70. |
| **CSR-004** — Git used before a hardened binary was resolved | **Fixed for the stated later-PATH threat model.** | `scripts/lib/git-safe.sh:16-34` requires an absolute `GIT_BIN`. The five skill examples at `skills/ccs/SKILL.md:623`, `726`, `821`, `866`, and `1262` resolve and validate it before their `rev-parse --local-env-vars` call. The full fixture suite passed the function-shadowing, relative-PATH, and post-resolution decoy-Git cases. This does not—and need not—make an already hostile startup `PATH` trustworthy. |
| **CSR-005** — eval checker diverges from canonical schema | **Fixed and reproduced.** | The hand-written `evals/lib/schema-check.jq` is deleted. `evals/lib/validate_interactive_result.py:196-212` uses `jsonschema.Draft202012Validator` when available and otherwise calls strict explicit validation. The six fresh malformed probes failed in normal, fallback, and harness modes. |
| **CSR-006** — SHA-256 Git IDs rejected | **Still intentionally deferred.** | `scripts/run-ccs-ci.sh:133-140` and `schemas/ci-result.schema.json:70` still require 40 lowercase hex characters. The response accurately says this is not fixed. |
| **CSR-007** — collector selftest leaks `GIT_SAFE_HOME` | **Fixed and reproduced.** | `scripts/collect_untracked_files.py:458-473` registers `shutil.rmtree(..., ignore_errors=True)` with `atexit`. The isolated fresh selftest left no child directory in its temporary root. |
| **CSR-008** — malformed CI JSON prints traceback | **Fixed and reproduced.** | `scripts/validate_ci_result.py:333-338` catches `OSError`, `UnicodeDecodeError`, and `json.JSONDecodeError` and emits `INVALID: malformed JSON`. The added fixture passed both malformed JSON and invalid UTF-8 cases without a traceback. |
| **L-001** — aggregate resource pressure unbounded | **Still deferred; accurately remains a limitation.** | `collect_untracked_files.py:364-380` extends one `parts` list for every accepted file and has no aggregate byte/file ceiling. `run-stream-review.sh:180-194` still reads all stdin and stores a whitespace-stripped copy in a shell variable. The collector has a time deadline and a per-file cap, not a total prompt/memory/disk budget. This is peak-pressure risk, not a classic retained-memory leak. |
| **L-002** — stale `/tmp` sweep can affect another user | **Fixed for cross-user deletion; same-user namespace collision remains disclosed.** | `skills/ccs/SKILL.md:497-511` now adds `-user "$(id -un)"` and explicitly documents the remaining same-user filename-pattern risk. This is a meaningful narrow mitigation, though it is not as strong as a plugin-owned temp root. |
| **L-003** — docs direct callers to unsupported rollout tailing | **Fixed.** | `skills/stream-review/SKILL.md:49-78` now says only the early `THREAD_ID=` signal is available and explicitly rejects reliance on rollout files as an unsupported unstable contract. |
| **L-004** — important paths not exercised by CI | **Partially improved locally; still open in CI.** | A useful new fake-Claude test exists, but the workflow evidence in finding R-001 below shows it is not invoked by continuous CI. The pre-push hook also remains without a behavioral fixture. |
| **L-005** — unsafe test/eval reservation and incomplete cleanup | **Partially fixed, not fully fixed.** | The larger fixture was improved with a registered cleanup trap, but the newly added CI-wrapper test has the remaining issues documented in R-002 below. |
| **L-006** — large skill invocation cost | **Still deferred.** | Current measurements are `2,493` lines / `193,856` bytes for `skills/ccs/SKILL.md`, and `5,960` lines / `461,399` bytes across skill Markdown. These are slightly larger than the response's historical figures, so no performance/cost reduction was delivered in this remediation. |
| **L-007** — CI trust/API-key exposure residual risk | **Still documented, not fixed.** | `ccs-ci-review.yml:70-111` and `200-245` retain detailed explicit residual-risk language. No evidence supports calling it resolved; the response correctly treats it as an accepted limitation. |

## Review of the new technical choices

### Signal and process cleanup

The CSR-001 implementation is appropriate. Ignoring repeat `INT`/`TERM` while the terminal handler
is finishing prevents re-entry, then `wait` establishes that the child is reaped before its final
message file is copied or removed. Clearing `CODEX_PID` immediately after the wait avoids using a
recycled PID later. The double-signal fixture exercises the exact contract that failed before.

### Result-file handling

The directory pre-check and regular-file post-check in `write_result_atomic()` are appropriate for
the reported `mv`-to-directory behavior. The code does not claim to eliminate every filesystem
TOCTOU race; it detects the residual directory shape and removes the specific nested temporary
basename. That is an honest and proportionate shell-level mitigation.

### Schema validation

Replacing a partial jq predicate with the canonical JSON Schema validator is the right technique.
The fallback is not a silent bypass: it checks exact key sets, primitive types, enums, minimums, and
the schema's conditional branches. Direct normal/fallback tests showed the same rejection result
for the original malformed-artifact classes.

The fallback is deliberately duplicated logic, so future changes to
`schemas/interactive-result.schema.json` must also update `explicit_validate()`. This is a
maintenance obligation, not a present mismatch: the current source and fresh counterexamples
matched.

### Memory, resource, and performance assessment

No newly introduced persistent memory leak was found. The collector selftest leak is fixed, and
the wrapper processes in the deterministic fixture suite terminate. However, L-001 remains the
principal resource concern: the code can construct a large aggregate prompt/`parts` list from many
individually permitted files. The 30-second collection deadline limits elapsed time but does not
bound bytes, tokens, peak memory, or temporary-file pressure.

The removal of hardcoded `-c model_reasoning_effort=xhigh` is correct behaviorally:

- `scripts/run-ccs-review.sh:1000-1009` and `scripts/run-stream-review.sh:225-244` now defer to the
  caller's Codex configuration on fresh and resumed calls.
- This avoids silently reducing a user's configured `max` effort to `xhigh`.
- It is not itself a measured performance improvement; no benchmark in the response proves lower
  latency, cost, or token use.

## Findings requiring follow-up

### R-001 — Added CI-wrapper regression test is not connected to continuous CI

**Severity:** Medium (test-enforcement/maintenance risk)
**Status:** Confirmed by source and Git scope

`tests/test-run-ccs-ci.sh` is a useful deterministic test and passes locally, but it is not run by
the normal plugin CI workflow:

- `.github/workflows/codex-stream-review-ci.yml:30-38` ShellChecks only
  `run-ccs-review.sh`, `git-safe.sh`, `run-stream-review.sh`, and eval scripts.
- Lines `40-46` likewise omit `run-ccs-ci.sh`, `validate_ci_result.py`, and the pre-push hook from
  the explicit core syntax/selftest steps.
- Lines `48-52` run only `test-run-ccs-review.sh` and the collector selftest.
- Fresh command evidence: `git diff --name-only 331696c HEAD -- .github/workflows` returned zero
  files, and `rg -l 'test-run-ccs-ci\\.sh' .github/workflows` returned no workflow reference.

`ccs-ci-review.yml` does invoke `run-ccs-ci.sh` at lines `251-256`, but for a plugin-source pull
request it checks out `trusted-tooling` from the PR base SHA at lines `127-141`. That execution is
not a deterministic regression test of the proposed source changes in the PR itself and cannot
replace a normal fixture step.

**Required closure:** add the new fixture to `codex-stream-review-ci.yml`, add syntax/lint coverage
for `run-ccs-ci.sh`, and run `validate_ci_result.py --selftest` there. Add a small deterministic
pre-push fixture separately if L-004 is intended to be fully closed.

### R-002 — New CI-wrapper test retains `mktemp -u` and lacks interruption-safe cleanup

**Severity:** Low (test/eval reliability; not a production-wrapper vulnerability)
**Status:** Confirmed by direct source read

`tests/test-run-ccs-ci.sh:150` still executes:

```bash
FAKE_TMP_PATH="$(mktemp -u "$DEBRIS_DIR/.ccs-ci-result.XXXXXX")"
```

The parent `DEBRIS_DIR` is allocated with `mktemp -d` at line 148, which makes this substantially
less exposed than the original shared-temp-directory cases. It nevertheless remains a name-only
reservation: another process running as the same user can create the guessed name before line 151
opens it. More simply, no random name is needed in this private directory at all.

The same file creates temporary directories/files at lines 27, 52, 68, 87, 104, 123, 131, and 148,
but contains no `trap` or cleanup registry. Its explicit `rm` calls cover ordinary completion, not
an `INT`, `TERM`, or an unexpected shell abort. This contrasts with the registered `EXIT` cleanup
introduced in `tests/test-run-ccs-review.sh:40-63`.

**Required closure:** use a fixed fixture filename inside `DEBRIS_DIR` instead of `mktemp -u`, and
use one minimal `EXIT` cleanup trap/registry for this test. Until then, L-005 should be reported as
partially fixed, not fixed.

### R-003 — Source remediation has not been released to the currently installed plugin

**Severity:** Release blocker / operational gap
**Status:** Confirmed by manifest and cache inspection

Fresh read-only evidence:

```text
manifest_diff_count=0
source_version=1.1.0
installed-cache version=1.1.0
```

The remediation range does not modify either the source plugin manifest or marketplace manifest.
The installed cache at
`/Users/hmc7279235/.claude/plugins/cache/agent-marketplace/codex-stream-review/1.1.0/` is also
version `1.1.0`, and still contains `model_reasoning_effort=xhigh` in:

- `scripts/run-ccs-review.sh:1001`, and
- `scripts/run-stream-review.sh:223`.

This confirms the response's deployment caveat is real: the source fixes are not evidence that the
user's already-installed plugin behavior has changed. This review does not assume undocumented
plugin-manager cache semantics; it records only the observable version collision and stale installed
contents.

**Required closure:** increment/package the plugin according to the marketplace release process,
publish it, update/reinstall it, and re-read the installed artifact to verify the fixed source is
what runs.

### R-004 — The response's stated remediation commit count is incorrect

**Severity:** Informational (audit-record accuracy)
**Status:** Confirmed by Git

The response says “18 commits” at lines 48 and 195 and then says its 19 table rows represent 18
unique remediation commits at lines 217-220. The stated range itself proves otherwise:

```text
git rev-list --count 331696c..1188d7a
19
```

All 19 hashes are present in the response's own table, including `1188d7a`. If one commit is meant
to be excluded from a remediation count, the report must identify it and explain why. This does not
affect the source-equivalence result or the tested fixes, but it should be corrected so later
audits have an accurate provenance trail.

## What the response gets right about residual risk

The following statements should be retained rather than “fixed” cosmetically:

- A 40-character SHA-1-only contract is a compatibility limitation until all three enforcement
  points are widened together.
- A per-file cap and an elapsed-time deadline do not create an aggregate prompt/resource budget.
- The pre-push hook is advisory and still has no behavioral test.
- The skill/reference corpus remains large; current source metrics are slightly higher, not lower.
- The `pull_request` workflow trust/API-key limitations remain explicit accepted risk, not a
  newly introduced defect or a solved security boundary.

## Recommended completion order

1. Wire `tests/test-run-ccs-ci.sh`, `run-ccs-ci.sh` syntax/lint, and
   `validate_ci_result.py --selftest` into the normal plugin CI workflow. This closes the most
   important discrepancy between the response and actual continuous enforcement.
2. Finish test hygiene in `test-run-ccs-ci.sh` with a fixed filename inside its private directory
   and an `EXIT` cleanup trap. This is a small, local correction.
3. Release the corrected plugin with a distinguishable version, update/reinstall it, and verify the
   installed cache no longer contains the `xhigh` override.
4. Correct the response document's 18-versus-19 commit count and update the deferred skill-size
   metrics if the document is intended to describe the current tree.
5. Plan—not guess—an aggregate resource policy for L-001, plus the deferred SHA-256 and pre-push
   work, in separate scoped changes.

## Audit limitations

- No live model dispatch, GitHub Actions run, marketplace publication, or plugin update was
  performed; those actions can mutate credentials, configuration, caches, or remote state.
- The deterministic suites establish wrapper behavior against fake CLIs, not semantic correctness
  of an arbitrary LLM response.
- This review assessed the remediation response and current equivalent source. It did not reopen
  every unrelated historical design decision outside the original audit scope.

## Final conclusion

Claude's response is technically credible for the principal runtime fixes, and the fresh tests
support accepting those fixes as implemented in source. The report should be amended before final
closure: L-004 and L-005 are only partially resolved, the installed plugin has not yet received the
source changes, and the commit count is wrong. Once CI wiring, minor test hygiene, and a verified
release are complete, the remaining items can accurately be tracked as deliberate residual design
limitations rather than unresolved remediation mistakes.

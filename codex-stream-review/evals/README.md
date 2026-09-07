# codex-stream-review evals

On-demand eval scenarios that validate the LLM-INTERPRETED `codex-stream-review:ccs` skill
(`skills/ccs/SKILL.md`, its `references/*.md`, and `scripts/run-ccs-review.sh`) end to end, by
actually driving a real `/ccs`-equivalent session against a crafted fixture and structurally
checking the durable `.result.json` artifact it produces.

This complements, and does not replace, `../tests/` (`tests/test-run-ccs-review.sh`), which covers
only the **deterministic** `.sh`/`.py` code layer -- the fake-`codex`-driven wrapper fixture suite,
plus (as of the sibling Tier 1 work) extracted-and-unit-tested versions of the claim-ledger
reducer, the `DISPOSITION` marker parser, and the parallel-mode coverage/findings merges. Neither
of those can exercise whether an LLM actually follows `SKILL.md`'s prose correctly in a live,
multi-round session -- retry-by-failure-reason decision trees, convergence judgment, parallel-mode
dispatch/aggregation. That is what this directory is for.

## Mechanical caveat: PATH must be re-prepended on EVERY Bash call

Claude Code's own Bash tool gives a **fresh shell on every call** -- nothing exported in one call
(a `PATH` override, an env var) survives into the next. `SKILL.md` itself is built entirely around
this constraint (it re-derives `REPO_ROOT`/`INSTALL_PATH` etc. as literal facts and reconstructs
every value in every new command). This means: to make a live scenario run actually dispatch
through the fake `codex` fixture (`../tests/fixtures/fake-codex`) instead of a real Codex backend,
whoever is DRIVING the session -- a human, or a Claude agent following `SKILL.md` in real time --
must prepend the fake-codex `BIN_DIR` (printed by that scenario's own `setup.sh`) to `$PATH` on
**every single Bash call** made during that run. There is no way to set this once and have it
persist. Each scenario's own `README.md` repeats this explicitly, plus any `FAKE_CODEX_*` env vars
that scenario's own fixture behavior depends on (also re-set on every relevant call, for the same
reason).

One scenario in the matrix below (`input-too-large`) is a confirmed exception -- its own
`setup.sh`/`README.md` explain exactly why, verified by reading `scripts/run-ccs-review.sh`
directly and by an actual live run: the size-limit preflight it targets fires before the wrapper
ever invokes a `codex` binary at all, so no PATH injection is needed there.

## How to run a scenario

```bash
bash codex-stream-review/evals/run-evals.sh <scenario-name>
```

This is a **two-phase** tool, not a single fully-automated command, and structurally can't be one
without a live LLM agent in the loop (see `run-evals.sh --help` for the full explanation):

1. **Phase 1** (scenario name only): runs that scenario's `setup.sh` (fixture repo/artifact +
   printed task text and env/PATH instructions).
2. **Phase 2** (scenario name + a `.result.json` path, once a live `codex-stream-review:ccs`
   session following those instructions has completed): validates the result via
   `check-result.sh` under the hood.

Each scenario also documents its own expected result and any scenario-specific nuance in
`scenarios/<name>/README.md` -- read that before running.

## Scenario index

Groups A-F below are copied directly from the original planning document's own scenario matrix
(`~28` scenarios total) -- descriptions are transcribed verbatim from that plan for the scenarios
not yet built, so nothing is lost or reworded. **Status** is `built + verified` only for the 3
scenarios actually implemented and run live end-to-end during this harness's initial build;
everything else is `specified, not yet built`.

### Group A — one scenario per terminal status (7)

| Scenario | Targets | Status |
|---|---|---|
| `clean-basic` | Confirm `exit_state == "CLEAN"` is reachable end-to-end and reported correctly on the simplest possible real dispatch | **built + verified** |
| `not-converged-cap` | Force disagreement to hit the 20-round cap | specified, not yet built |
| `could-not-verify-exhausted` | Force every retry to fail | **built + verified** |
| `partial-coverage` | A scope that omits real files | specified, not yet built |
| `input-too-large` | Oversized combined prompt (diff and/or focus/context text) rejected by the wrapper's own preflight | **built + verified** |
| `snapshot-integrity-failure` | Corrupt/delete the snapshot mid-run | specified, not yet built |
| `review-log-integrity-failure` | Corrupt the JSONL append or force a stale `schema_version` on `--resume` of an old session | specified, not yet built |

### Group B — retry-decision-tree coverage (`retry-guards.md`), one per real branch

| Scenario | Targets | Status |
|---|---|---|
| `retry-no-threadid-fresh` | First-ever attempt fails pre-thread-start, confirm the single fresh retry | specified, not yet built |
| `retry-existing-threadid-badargs` | A `--resume` call fails with no threadId in a way that doesn't abandon the thread | specified, not yet built |
| `retry-resume-safe-round1` | Round-1 resume-safe failure, confirm coverage is captured from the failed attempt before retrying | specified, not yet built |
| `retry-resume-safe-round2plus` | Same resume-safe retry shape, but for a round-2+ failure (no coverage capture applies) | specified, not yet built |
| `retry-exhausted-round1-fresh-fallback` | Both resume-retries fail, confirm the round-1-only fresh fallback + `LEAKED_THREAD_IDS` bookkeeping | specified, not yet built |
| `retry-exhausted-round2plus-no-fallback` | Both resume-retries fail on a round-2+ group, confirm there is no fresh fallback available and the group stops at `COULD NOT VERIFY` directly | specified, not yet built |

(The plan's own group heading says "(5)" while enumerating 6 named scenarios -- transcribed as-is,
not corrected, per the instruction to copy descriptions verbatim rather than reconcile the count.)

### Group C — feature-flag matrix (4)

| Scenario | Targets | Status |
|---|---|---|
| `flags-neither` | Baseline: neither `--capture-evidence` nor `--keep-evidence` set | specified, not yet built |
| `flags-capture-only` | `--capture-evidence` ON, `--keep-evidence` OFF | specified, not yet built |
| `flags-keep-only` | `--keep-evidence` ON, `--capture-evidence` OFF -- needs a non-CLEAN run to actually exercise the keep-vs-delete gate | specified, not yet built |
| `flags-both` | Both flags ON together | specified, not yet built |

Each is checked against both a CLEAN and a non-CLEAN outcome variant where relevant, per the plan.

### Group D — scope/artifact-shape coverage (4)

| Scenario | Targets | Status |
|---|---|---|
| `scope-uncommitted` | `--uncommitted` scope: confirm `target.scope` recorded correctly, `coverage_source` populated | specified, not yet built |
| `scope-base-ref` | `--base <ref>` scope: confirm `target.scope` recorded correctly, no `coverage_source` | specified, not yet built |
| `scope-commit-sha` | `--commit <sha>` scope: confirm `target.scope` recorded correctly, no `coverage_source` | specified, not yet built |
| `scope-non-repo-artifact` | The `CLEAN_REPO_DIR` path (a non-repo artifact review) | specified, not yet built |

Confirm `target.scope` is recorded correctly and coverage semantics differ correctly (only
`--uncommitted` ever populates `coverage_source`), per the plan.

### Group E — parallel-mode coverage (4)

| Scenario | Targets | Status |
|---|---|---|
| `parallel-two-groups-both-clean` | Baseline parallel run, both groups converge CLEAN | specified, not yet built |
| `parallel-one-group-fails` | Worst-case-wins: round not eligible for CLEAN even though the other group is clean | specified, not yet built |
| `parallel-group-namespaced-claims` | Confirm `g1:f3`-style claim IDs never collide | specified, not yet built |
| `parallel-coverage-merge` | One group partial, one complete -- confirm the merged `coverage_source` reflects the worst case | specified, not yet built |

### Group F — claim-ledger end-to-end (4)

| Scenario | Targets | Status |
|---|---|---|
| `claim-clean-resolution` | Raise → fix → `DISPOSITION RESOLVED` | specified, not yet built |
| `claim-retraction` | Raise → rebut → `DISPOSITION RETRACTED` | specified, not yet built |
| `claim-oscillation-nonconsecutive` | Raised round 1, silent round 2, reasserted with no new evidence round 3 -- confirm NOT CONVERGED fires, not silently missed the way the old adjacent-round-only guard would have | specified, not yet built |
| `claim-still-open-marker` | A claim explicitly marked `STILL OPEN` with a reason, confirm it stays `open`, not silently treated as resolved | specified, not yet built |

For scenarios that involve a genuine LLM judgment call rather than a structurally-forced outcome
(especially groups E and F, and `not-converged-cap`), the original plan calls for running with
`--repeat N` and reporting a consistency rate once built -- not needed for the 3 structurally-
forced scenarios already built (`clean-basic`, `input-too-large`, `could-not-verify-exhausted`),
since their outcome does not depend on an LLM judgment call.

## Why this is NOT part of push/PR-triggered CI

`.github/workflows/codex-stream-review-ci.yml` is a bare shell-script CI runner (ShellCheck,
`bash -n`, `tests/test-run-ccs-review.sh`, `collect_untracked_files.py --selftest`) with no live
Claude Code agent in the loop. Running one of these eval scenarios means actually driving the
`codex-stream-review:ccs` skill through a real multi-round Claude+Codex conversation -- an LLM
agent interpreting `SKILL.md`'s prose and making the same judgment calls a real run makes. A plain
`bash` CI step structurally cannot do that on its own; it would need a headless
`claude -p`-style invocation with API credentials wired into CI as repo secrets, which was checked
during implementation and is not currently configured for this repo. So: this directory is the
on-demand form only (`run-evals.sh`, invoked by a human or an agent before a release, after any
`SKILL.md`/reference-file change, or for a health check) -- not wired into any CI trigger, manual
`workflow_dispatch` or otherwise, at this time.

This is the concrete answer to gap #5's disposition in
`docs/2026-09-05-codex-stream-review-improvement-roadmap-design.md`: that document's original
conclusion -- a *deterministic* test harness for LLM-interpreted prose is impossible -- still
stands. This directory is a different kind of asset entirely: real, repeatable scenarios plus
structural checking of the durable output a real session produces, not a reversal of that
conclusion. See that document's own updated gap #5 section for the short pointer back here.

## A real bug this harness already found (and fixed)

Building `input-too-large` surfaced a genuine, independent performance bug in
`scripts/run-ccs-review.sh`: `_focus_is_empty()` stripped whitespace from the caller's ENTIRE focus
text via a bash `${var//[[:space:]]/}` global substitution, which is catastrophically superlinear
for large inputs (confirmed by isolated benchmark: ~6KB took ~13s; extrapolated, an input near
`PROMPT_SIZE_LIMIT_BYTES`, 131072 bytes, would have taken on the order of hours) -- exactly the
input size needed to exercise the `INPUT_TOO_LARGE` terminal status via an oversized focus text, as
originally planned, would have made the wrapper hang for a wildly impractical time on this one
early check, well before ever reaching the size-limit check it's nominally guarding. The identical
pattern was also found in `scripts/run-stream-review.sh`'s own focus-emptiness check.

**Both are now fixed** (replaced with `tr -d '[:space:]'`, confirmed correct and ~340x faster on
the same 6KB benchmark, full `tests/test-run-ccs-review.sh` suite re-run clean afterward).
`scenarios/input-too-large/`'s own `setup.sh`/`README.md` still route around the (now-fixed) slow
path by using an oversized DIFF rather than an oversized focus text, since that's a more direct way
to exercise the wrapper's real `PROMPT_SIZE_LIMIT_BYTES` check regardless. This is exactly the kind
of thing a real, live eval harness is for: it would not have been caught by only reading the prose.

## Layout

```
evals/
  README.md              -- this file
  run-evals.sh            -- two-phase convenience runner (see above)
  check-result.sh         -- schema + scenario-specific validator for a .result.json
  lib/
    common.sh             -- shared setup.sh helpers (fixture repos, fake-codex injection, install-path resolution)
    schema-check.jq       -- structural validator for schemas/interactive-result.schema.json
  scenarios/
    <name>/
      setup.sh            -- creates the fixture, prints run instructions
      expect.sh            -- scenario-specific assertions on a .result.json (checked by check-result.sh)
      README.md            -- what it targets, how to run it, expected result
```

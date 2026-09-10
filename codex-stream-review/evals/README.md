# codex-stream-review evals

On-demand eval scenarios that validate the LLM-INTERPRETED `codex-stream-review:ccs` skill
(`skills/ccs/SKILL.md`, its `references/*.md`, and `scripts/run-ccs-review.sh`) end to end, by
actually driving a real `/ccs`-equivalent session against a crafted fixture and structurally
checking the durable `.result.json` artifact it produces.

This complements, and does not replace, `../tests/` (`tests/test-run-ccs-review.sh`), which covers
only the **deterministic** `.sh`/`.py` code layer -- the fake-`codex`-driven wrapper fixture suite,
plus (as of the sibling Tier 1 work) extracted-and-unit-tested versions of the claim-ledger
reducer, the `DISPOSITION` marker parser, the parallel-mode coverage/findings merges, and (as of
`--quick`) the canonical-current-severity lookup + `MINOR_ISSUES_ACKNOWLEDGED` eligibility
decision (`tests/fixtures/quick-mode-decision.jq`). Neither
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

**Every scenario in every group below (Groups A-F) is `built + verified`** -- all 29 (28 from the
original
planning matrix, plus a split of the original single `review-log-integrity-failure` entry
into two distinct scenarios (a net +1) per a negotiated planning refinement, plus one net-new scenario,
`near-limit-whitespace-performance`, added after a real production bug was found while building
this harness -- see "A real bug this harness already found" below -- minus the since-removed
`input-too-large` scenario, whose target preflight was removed entirely) were actually built,
actually driven live end-to-end (via the Skill tool or a faithful manual execution of `SKILL.md`'s
own documented Phase 0-3 procedure), and confirmed passing via `check-result.sh` against a real
`.result.json`. Every Codex/fake-codex thread created along the way was cleaned up.

**Group G (below), added for `--quick`, adds 3 more `built + verified` live scenarios (32 total)
plus 2 documentation-only stubs** -- `quick-mode-escalation-critical` and
`quick-mode-unparseable-severity-fail-closed` are directories with a `README.md` only, no
`setup.sh`/`expect.sh`, since the case each would need to drive (a `CRITICAL` or otherwise
non-enum `severity` value reaching a live finding) cannot be produced through any real or
faithfully-scripted dispatch at all -- see each one's own `README.md` for the full evidence chain.
Their coverage lives instead as Tier 1 unit tests in `tests/test-run-ccs-review.sh` against
`tests/fixtures/quick-mode-decision.jq`.

**Group H (below), added for `--compact`, adds 5 more `built + verified` live scenarios (37
total)** -- one per distinct terminal/latch outcome the opt-in thread-compaction feature
introduces: the basic successful restart, the benefit-free-restart-loop baseline circuit breaker,
the byte-budget preflight latch, the retry-topology fresh-B escalation, and the `CLEAN_REPO_DIR`
cleanliness recheck's fail-closed behavior. All five follow this harness's own standard two-phase
convention (`setup.sh`, then a live `codex-stream-review:ccs --compact` invocation, then
`check-result.sh` against the real resulting `.result.json`) -- see each scenario's own
`README.md` for its exact task text/env vars. `compact-clean-repo-dir-polluted` is the one
scenario among the five needing genuine mid-session manual intervention (planting a stray file
into a path `/ccs` itself only allocates at runtime, printed during the live session rather than
knowable in advance) -- see that scenario's own `README.md` for why it can't be as fully
pre-scripted as the other four. The `COMPACTION_CONSECUTIVE_FRESH_FAILURES`
repeated-fresh-dispatch-failure circuit breaker, the digest structural-verification-failure path,
and the `baseline_unusable` latch (a compaction round's own freshly-restarted usage telemetry
coming back missing/malformed, so its baseline can't be verified one way or the other) are not
separately covered here — all three are straightforward compositions of mechanics these five
scenarios already exercise individually, and can be added later following the exact same pattern.

### Group A — one scenario per terminal status (6 named entries; `review-log-integrity-failure`
was split into 2 distinct scenarios per its two distinct real triggers, for 7 status-derived
scenarios, plus the `near-limit-whitespace-performance` regression guard below (not tied to any
terminal status), for 8 built)

| Scenario | Targets | Status |
|---|---|---|
| `clean-basic` | Confirm `exit_state == "CLEAN"` is reachable end-to-end and reported correctly on the simplest possible real dispatch | **built + verified** |
| `not-converged-cap` | Force disagreement to hit the 20-round cap -- a real 20-round loop, scripted per-round evidence text (`FAKE_CODEX_GROUP_STATE`) genuinely judged as `evidence_delta:"new"` each round | **built + verified** |
| `could-not-verify-exhausted` | Force every retry to fail | **built + verified** |
| `partial-coverage` | A real oversized untracked file, genuinely omitted by the collector (reason code `over_size_limit`) | **built + verified** |
| `snapshot-integrity-failure` | A real deleted `SNAPSHOT_FILE` before round 2's revalidation, confirmed unconditional hard stop + cleanup | **built + verified** |
| `review-log-integrity-failure-corrupt-append` | A real permission-denied JSONL append (the wrapper's own append-then-verify hard stop) | **built + verified** |
| `review-log-integrity-failure-stale-schema` | A hand-built legacy session log (no/old `schema_version`), `--resume` refused per `claim-ledger.md` section 10 -- distinct trigger from the corrupt-append case, same `exit_state` | **built + verified** |
| `near-limit-whitespace-performance` (NEW, not in the original matrix) | A valid, whitespace-dense, near-limit focus text -- regression guard for the real superlinear-hang bug this harness found and led to fixing (see below); asserts a bounded, fast completion | **built + verified** |

### Group B — retry-decision-tree coverage (`references/retry-guards.md`), one per real branch

| Scenario | Targets | Status |
|---|---|---|
| `retry-no-threadid-fresh` | First-ever attempt fails pre-thread-start, confirm the single fresh retry | **built + verified** |
| `retry-existing-threadid-badargs` | A real `--resume` call fails (genuine empty-stdin `bad_args`) with no threadId, confirmed the SAME thread persists, never a fresh scope | **built + verified** |
| `retry-resume-safe-round1` | Round-1 resume-safe failure, confirm real coverage is captured from the failed attempt before retrying (never falls back to the `unknown` sentinel) | **built + verified** |
| `retry-resume-safe-round2plus` | Same resume-safe retry shape, but for a round-2+ failure (no coverage capture applies); real 5s/15s bounded backoff | **built + verified** |
| `retry-exhausted-round1-fresh-fallback` | Both resume-retries fail, confirm the round-1-only fresh fallback + a real `LEAKED_THREAD_IDS` entry, still cleaned up at Phase 3 | **built + verified** |
| `retry-exhausted-round2plus-no-fallback` | Both resume-retries fail on a round-2+ group, confirm there is no fresh fallback available and the group stops at `COULD_NOT_VERIFY` directly, nothing leaked | **built + verified** |

(The original plan's own group heading said "(5)" while enumerating 6 named scenarios -- all 6 were
built as genuinely distinct scenarios, per a negotiated planning refinement that explicitly kept
the two "exhausted" branches separate rather than merging them, since they exercise different
branch-specific safety behavior (fresh-fallback + leaked-thread bookkeeping vs. no-fallback direct
stop).)

### Group C — feature-flag matrix (3 built; `flags-neither` deliberately dropped)

`flags-neither` (baseline: neither flag set) was explicitly dropped from this matrix -- confirmed
by directly reading `clean-basic/expect.sh` before building this group: `clean-basic` already
asserts the identical default cleanup-lifecycle behavior with both flags off, so a fourth,
near-duplicate scenario would add no new coverage.

| Scenario | Targets | Status |
|---|---|---|
| `flags-capture-only` | `--capture-evidence` ON, `--keep-evidence` OFF, on a CLEAN run -- the JSONL log's `investigation_evidence` field reflects `FAKE_CODEX_COMMANDS` | **built + verified** |
| `flags-keep-only` | `--keep-evidence` ON, `--capture-evidence` OFF, on a forced `COULD_NOT_VERIFY` run -- Phase 3's keep-evidence gate leaves every thread `cleanup:"retained"` and a kept last-message file survives | **built + verified** |
| `flags-both` | Both flags ON together on a CLEAN run -- capture-evidence's log effect present, keep-evidence's gate correctly inert (normal `cleanup:"deleted"`, no kept-evidence directory) | **built + verified** |

Each scenario's `expect.sh` also asserts `FAKE_CODEX_INVOCATION_LOG`'s exact invocation
count/sequence, confirming the fake binary (not a real `codex`) actually ran the expected number
of times.

### Group D — scope/artifact-shape coverage (4)

| Scenario | Targets | Status |
|---|---|---|
| `scope-uncommitted` | `--uncommitted` scope: confirm `target.scope` recorded correctly, `coverage` a real object | **built + verified** |
| `scope-base-ref` | `--base <ref>` scope: confirm `target.scope` recorded correctly, `coverage == null` | **built + verified** |
| `scope-commit-sha` | `--commit <sha>` scope: confirm `target.scope` recorded correctly, `coverage == null` | **built + verified** |
| `scope-non-repo-artifact` | The `CLEAN_REPO_DIR` path (a non-repo artifact review): `target.scope == "uncommitted"`, `coverage.status == "complete"` with `reviewed_file_count == 0` | **built + verified** |

Confirm `target.scope` is recorded correctly and coverage semantics differ correctly (only
`--uncommitted` ever populates `coverage`), per the plan. Each scenario's `expect.sh` also asserts
`FAKE_CODEX_INVOCATION_LOG`'s exact invocation count/sequence.

### Group E — parallel-mode coverage (4)

| Scenario | Targets | Status |
|---|---|---|
| `parallel-two-groups-both-clean` | Baseline parallel run, both groups converge CLEAN | **built + verified** |
| `parallel-one-group-fails` | Worst-case-wins: round not eligible for CLEAN even though the other group is clean | **built + verified** |
| `parallel-group-namespaced-claims` | Confirm `g1:f3`-style claim IDs never collide | **built + verified** |
| `parallel-coverage-merge` | One group partial, one complete -- confirm the merged `coverage_source` reflects the worst case | **built + verified** |

### Group F — claim-ledger end-to-end (4)

| Scenario | Targets | Status |
|---|---|---|
| `claim-clean-resolution` | Raise → fix → `DISPOSITION RESOLVED` | **built + verified** |
| `claim-retraction` | Raise → rebut → `DISPOSITION RETRACTED` | **built + verified** |
| `claim-oscillation-nonconsecutive` | Raised round 1, silent round 2, reasserted with no new evidence round 3 -- confirm NOT CONVERGED fires, not silently missed the way the old adjacent-round-only guard would have | **built + verified** |
| `claim-still-open-marker` | A claim explicitly marked `STILL OPEN` with a reason, confirm it stays `open`, not silently treated as resolved | **built + verified** |

### Group G — quick mode (`--quick`; 3 built + 2 documentation-only stubs)

| Scenario | Targets | Status |
|---|---|---|
| `quick-mode-minor-acknowledged` | A `--quick` session hitting round 5 (the quick cap) with the sole open claim's canonical current severity cleanly `medium` -- confirms `exit_state == "MINOR_ISSUES_ACKNOWLEDGED"`, `round_count == 5` | **built + verified** |
| `quick-mode-escalation-high` | A `--quick` session where round 1's finding is `HIGH` severity -- confirms `MAX_ROUNDS` is permanently escalated to `20` (proven by the loop genuinely reaching round 6, via a deliberate oscillation-guard trip at that round), and `exit_state` is never `MINOR_ISSUES_ACKNOWLEDGED` | **built + verified** |
| `quick-mode-missing-severity-fail-closed` | A `--quick` session hitting round 5 where the sole open claim's severity was never recorded (`null` throughout) -- confirms this MISSING case fails closed to `NOT_CONVERGED`, never treated as "no data, so pass" | **built + verified** |
| `quick-mode-escalation-critical` | Would confirm the escalation predicate's `CRITICAL` half is never accidentally treated as minor -- **documentation-only stub**: `severity:"critical"` cannot reach a live finding at all (`run-ccs-review.sh`'s own schema check rejects it as `schema_mismatch` before dispatch). Coverage lives as a Tier 1 unit test instead | **documented, not a live scenario** |
| `quick-mode-unparseable-severity-fail-closed` | Would confirm an unparseable severity string (e.g. `"SEV-2"`) fails closed to `NOT_CONVERGED` -- **documentation-only stub**, same structural reason as `-escalation-critical` above. Coverage lives as a Tier 1 unit test instead | **documented, not a live scenario** |

`quick-mode-escalation-high`'s own oscillation-guard-based proof technique, and the full evidence
chain for why the two stub scenarios cannot be driven live, are explained in each scenario's own
`README.md` -- read those before assuming either stub represents a gap in coverage rather than a
structural impossibility.

### Group H — opt-in thread compaction (`--compact`; 5 built)

| Scenario | Targets | Status |
|---|---|---|
| `compact-trigger-uncommitted-success` | A round whose own usage crosses `COMPACT_THRESHOLD` causes the very next round to be a genuine fresh restart (never `--resume`); the old thread ends up `"kind":"leaked"`/`"cleanup":"deleted"`; session still reaches `CLEAN` | **built + verified** |
| `compact-baseline-still-over-threshold` | The benefit-free-restart-loop guard: a fresh restart whose OWN baseline usage is ALSO `>= COMPACT_THRESHOLD` latches `compaction_disabled_reason: "baseline_at_or_above_threshold"` and never attempts compaction again for the rest of the session | **built + verified** |
| `compact-byte-budget-exceeded` | The byte-budget preflight: an assembled focus text exceeding `COMPACT_BYTE_BUDGET` latches `compaction_disabled_reason: "byte_budget_exceeded"` WITHOUT ever dispatching a real fresh call for that attempt, falling straight through to the ordinary `--resume` fallback | **built + verified** |
| `compact-fresh-b-escalation` | Retry topology's fresh-B escalation: candidate A's own bounded resume-retries exhaust, thread B succeeds on its own single, unretried attempt -- `compaction_attempt_failed_thread: ["A"]`, both the pre-existing old thread AND candidate A end up leaked/deleted, B becomes current | **built + verified** |
| `compact-clean-repo-dir-polluted` | The 8-check `CLEAN_REPO_DIR` cleanliness recheck fails CLOSED when a stray file is planted into that directory mid-session -- no fresh dispatch for the compaction attempt, no thread ever created for it, immediate fallback to `--resume` on the still-alive old thread | **built + verified** (driven as a real live session -- see that scenario's own `README.md`) |

### Secondary tier — live-Codex acceptance (2, built after the 37 scripted scenarios above)

| Scenario | Targets | Status |
|---|---|---|
| `parallel-live-acceptance` | Real Codex, real parallel dispatch against a tiny 2-file, 2-defect fixture; asserts only a genuine semantic terminal state, never exact wording/round count | **built + verified** |
| `claim-ledger-live-acceptance` | Real Codex, single-reviewer, real `DISPOSITION` marker round-trip against a tiny 1-file, 1-defect fixture | **built + verified** |

For scenarios that involve a genuine LLM judgment call rather than a structurally-forced outcome,
the original plan calls for running with `--repeat N` and reporting a consistency rate -- not
needed for any of the scripted scenarios in this harness, including all of groups E and F as
actually built: every one of them drives real dispatch calls through the deterministic fake-`codex`
fixture with a scripted `FAKE_CODEX_GROUP_STATE`/`FAKE_CODEX_SCENARIO` transcript (per-round for
single-reviewer scenarios, per-group-and-per-round for parallel ones), so the ORCHESTRATOR's own
control-flow/parsing/merge logic is what's under test, not a live Codex judgment call -- their
outcome is exactly as structurally forced as `clean-basic`/
`could-not-verify-exhausted`. The two secondary-tier live-Codex scenarios
(`parallel-live-acceptance`, `claim-ledger-live-acceptance`) are the only ones that exercise a real,
unscripted Codex judgment call -- rather than `--repeat N`, their own `expect.sh` files avoid the
problem a different way: asserting only that a genuine semantic terminal state was reached (never
an exact round count or finding wording), which is stable across repeated real runs even though the
exact path to get there is not.

For someone who still wants to check consistency across several repeated live runs of one of these
two scenarios, `check-consistency.sh` is the recommended tool: it wraps `check-result.sh` per file
and reports a bucketed breakdown plus a `consistency_rate` across however many `.result.json` files
you hand it, e.g.:

```bash
bash codex-stream-review/evals/check-consistency.sh claim-ledger-live-acceptance run1.result.json run2.result.json run3.result.json
```

It is NOT useful for any of the other 37 scripted (fake-codex-driven) scenarios in this harness --
those each have exactly one structurally forced outcome already, so there is no consistency question
to ask of them.

## Why this is NOT part of push/PR-triggered CI

`.github/workflows/codex-stream-review-ci.yml` is a bare shell-script CI runner (ShellCheck,
`bash -n`, `tests/test-run-ccs-review.sh`, `collect_untracked_files.py --selftest`) with no live
Claude Code agent in the loop. Running one of these eval scenarios means actually driving the
`codex-stream-review:ccs` skill through a real multi-round Claude+Codex conversation -- an LLM
agent interpreting `SKILL.md`'s prose and making the same judgment calls a real run makes. A plain
`bash` CI step structurally cannot do that on its own; it would need a headless
`claude -p`-style invocation with API credentials wired into CI as repo secrets.

Re-verification of this decision was ATTEMPTED on 2026-09-07 but could not be completed in this
environment (the `gh` CLI is unauthenticated here, so this repo's Settings > Secrets and variables >
Actions could not be inspected). The original decision therefore stands UNCHALLENGED, not
reconfirmed, pending someone with actual repo admin access checking directly.

`.github/workflows/codex-stream-review-live-eval.yml` (added since the paragraph above) is a
`workflow_dispatch`-only skeleton for exactly this gap -- it takes a `scenario` input, validates it
against a real allow-list (the actual scenario directory basenames under `scenarios/`, not a
hand-maintained list), and always runs that scenario's own `setup.sh` on every manual dispatch, so
the skeleton is genuinely exercised (not just theoretically wired) every time it runs. Its current
honest state: wired through the real `setup.sh` path, blocked only on a `CCS_HEADLESS_AGENT_CREDENTIAL`
repo secret (not configured; the workflow prints a clear message and exits 0 when it's absent) plus a
headless-agent-driving mechanism BUILT FOR THIS SHAPE, which does not exist yet -- something that
would take a scenario's own printed task text and `FAKE_CODEX`/`PATH`-injection instructions, drive a
live `codex-stream-review:ccs` session against them non-interactively, and validate the resulting
`.result.json` via `check-result.sh`.

This is a related but DISTINCT gap from `scripts/run-ccs-ci.sh` / `.github/workflows/ccs-ci-review.yml`
(Phase 4 Item 2, already built and PR-triggered): that mechanism headlessly drives `claude -p` through
the same unmodified `codex-stream-review:ccs` skill, but for a completely different job -- reviewing a
real PR's own diff against its base branch and emitting `schemas/ci-result.schema.json` (a CI-specific
pass/fail mapping), never a scenario's `FAKE_CODEX`-scripted fixture, and never
`schemas/interactive-result.schema.json` (what `check-result.sh` here actually validates). Pointing
`codex-stream-review-live-eval.yml` at `run-ccs-ci.sh` as-is would not produce a `check-result.sh`-
validatable artifact at all -- a genuine adapter (or a new, eval-shaped sibling script) would still
need to be built. So: a headless-capable credential exists in principle (this repo's CI already uses
`ANTHROPIC_API_KEY`/`OPENAI_API_KEY` for the PR-review pipeline), but no mechanism yet drives an eval
*scenario* specifically, which is what `CCS_HEADLESS_AGENT_CREDENTIAL` stands in for above as a
placeholder pending that design work.

So: this directory is the on-demand form only (`run-evals.sh`, invoked by a human or an agent before
a release, after any `SKILL.md`/reference-file change, or for a health check) -- not wired into any
CI trigger that runs unattended end-to-end, manual `workflow_dispatch` or otherwise, at this time.

This is the concrete answer to gap #5's disposition in
`docs/2026-09-05-codex-stream-review-improvement-roadmap-design.md`: that document's original
conclusion -- a *deterministic* test harness for LLM-interpreted prose is impossible -- still
stands. This directory is a different kind of asset entirely: real, repeatable scenarios plus
structural checking of the durable output a real session produces, not a reversal of that
conclusion. See that document's own updated gap #5 section for the short pointer back here.

## A real bug this harness already found (and fixed)

Building the now-removed `input-too-large` scenario (it targeted a pre-dispatch prompt byte-size
preflight in `scripts/run-ccs-review.sh` that has since been removed entirely -- see
`near-limit-whitespace-performance`'s own README for why its removal doesn't affect what follows)
surfaced a genuine, independent performance bug in the same script: `_focus_is_empty()` stripped
whitespace from the caller's ENTIRE focus text via a bash `${var//[[:space:]]/}` global
substitution, which is catastrophically superlinear for large inputs (confirmed by isolated
benchmark: ~6KB took ~13s; a larger whitespace-heavy input would have taken on the order of hours)
-- exactly the input size needed to exercise that former preflight via an oversized focus text, as
originally planned, would have made the wrapper hang for a wildly impractical time on this one
early check, well before ever reaching the check it was nominally guarding. The identical pattern
was also found in `scripts/run-stream-review.sh`'s own focus-emptiness check.

**Both are now fixed** (replaced with `tr -d '[:space:]'`, confirmed correct and ~340x faster on
the same 6KB benchmark, full `tests/test-run-ccs-review.sh` suite re-run clean afterward).
`near-limit-whitespace-performance` remains as the regression guard for this fix, independent of
the now-removed preflight. This is exactly the kind of thing a real, live eval harness is for: it
would not have been caught by only reading the prose.

## Layout

```
evals/
  README.md              -- this file
  run-evals.sh            -- two-phase convenience runner (see above)
  check-result.sh         -- schema + scenario-specific validator for a .result.json
  check-consistency.sh    -- aggregates check-result.sh outcomes across N repeated .result.json files
  lib/
    common.sh             -- shared setup.sh helpers (fixture repos, fake-codex injection, install-path resolution)
    schema-check.jq       -- structural validator for schemas/interactive-result.schema.json
    check-thread-cleanup.sh -- confirms a "deleted" thread left no trace under ~/.codex/sessions/
  scenarios/
    <name>/
      setup.sh            -- creates the fixture, prints run instructions
      expect.sh            -- scenario-specific assertions on a .result.json (checked by check-result.sh)
      README.md            -- what it targets, how to run it, expected result
```

### `lib/check-thread-cleanup.sh`

Usage: `check-thread-cleanup.sh <result.json>`. For every `threads[]` entry in the given result with
`cleanup:"deleted"`, this searches `~/.codex/sessions/` recursively for a filename containing that
entry's `thread_id` -- a real match means the thread was reported deleted but its session file is
still there, a genuine leak. Entries with `cleanup:"failed"` or `"retained"` are only reported
informationally (already known-not-deleted by design, never counted as leaks).

This only means something for a scenario that dispatched to a REAL `codex` CLI (currently:
`parallel-live-acceptance`, `claim-ledger-live-acceptance`). For a fake-`codex`-driven scenario,
`threads[]` entries never correspond to a real `~/.codex/sessions/` file at all, so this check is
trivially a no-op pass for those, by design -- not a gap.

## Development

`scripts/hooks/pre-push` is an ADVISORY-only git pre-push hook -- never real enforcement (trivially
bypassed by `git push --no-verify`, or by simply not opting in), and it never runs in CI or any
server-side context. It warns and asks for interactive confirmation only when a push touches
codex-stream-review's core orchestration files (`skills/`, `scripts/`, `schemas/`), as a reminder to
have run those changes through `codex-stream-review:ccs` first.

Opt in with:

```bash
git config core.hooksPath codex-stream-review/scripts/hooks
```

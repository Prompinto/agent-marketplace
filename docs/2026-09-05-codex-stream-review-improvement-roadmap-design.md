# codex-stream-review Improvement Roadmap — Negotiated Plan

> Status: **Phase 1 negotiated to CLEAN and fully implemented** (6 items, PRs #55–#59).
> **Phase 2 negotiated to CLEAN and fully implemented** (claim ledger, PR #60,
> `codex-stream-review` now v0.10.0). **Phase 3 negotiated to CLEAN** in a third `/ccs`
> non-repo-artifact session (see "Phase 3 negotiation" below) — concretized, not yet implemented.
> Phase 4 remains sketch-level only. This document is the design input for
> `superpowers:writing-plans`-style implementation, taken phase by phase. Still pre-1.0.0 by
> design: the SKILL.md structure, script contracts, and supported feature set are still actively
> changing release to release, so a 1.0.0 tag would falsely signal a frozen interface.
>
> **Convergence summary (4 rounds, all findings verified by Claude, none rebutted — every finding
> was valid):** R1 — 4 findings (rollout-tailing dependency should be replaced by the CLI's own
> `-o`/`--output-last-message`; evidence-retention-on-failure needed a real design; a concrete
> answer to the Phase 2 convergence-gate question; a roadmap-governance disposition rule). R2 — 3
> findings, all "make R1's accepted fixes concrete" (per-dispatch output-file lifecycle; a
> defined hash/mismatch contract; an actual stdin transport, not just "use stdin" in principle). R3
> — 1 finding (R2's hash-based revalidation was internally self-contradictory) plus confirmation
> that every other item was now resolved. R4 — **CLEAN**, no further findings. See "Round N
> negotiation outcome" sections below for full detail per round.

## Why this document exists

The plugin author asked for a broad audit of `codex-stream-review` (gaps, edge cases, stability,
competitive positioning) to plan a push toward 1.0.0 readiness. Two research passes were run:

1. An internal gap analysis (direct reading of `plugin.json`, `run-ccs-review.sh`,
   `run-stream-review.sh`, `lib/git-safe.sh`, `collect_untracked_files.py`,
   `review-verdict.schema.json`, `ccs/SKILL.md` + all `references/*.md`, `stream-review/SKILL.md`,
   CI workflow, fixture tests, README, ~40 commits of git log, and the prior closed backlog
   memory).
2. An external competitive/ecosystem research pass (competing AI code-review tools, multi-agent
   LLM debate literature, Claude Code plugin ecosystem norms, Codex CLI internals/known bugs).

Both are summarized below, followed by a proposed four-phase roadmap. **The open questions at the
end of each phase are the actual negotiation agenda for the Codex round** — this doc is not asking
Codex to just rubber-stamp it.

## Internal gap analysis (verified against current source)

### Highest-impact
1. **Automatic thread cleanup destroys the one diagnostic artifact needed to debug a failure.**
   `ccs/SKILL.md` Phase 3 Step 1 runs `--cleanup` (deletes the Codex thread + its rollout file) on
   **every** terminal outcome, including `⚠️ COULD NOT VERIFY` and `⚠️ NOT CONVERGED`. Even with
   `--capture-evidence` on, only command strings are kept (never output text), and the raw
   eventlog is deleted immediately after extraction. Net effect: for `invalid_json` /
   `schema_mismatch` / `no_final_answer` failures there is no way, ever, to see the actual
   non-conforming model output.
2. **README.md documents a feature that was explicitly removed** (tmux live-pane; removed in
   commit `e2f81c5`, but README still describes "an auto-opening tmux pane").
3. **`--focus` content is exposed via process argv for up to 30 minutes** — for non-repo-artifact
   reviews this includes the entire pasted design doc/plan. Visible to any other local user via
   `ps -ef`/`/proc/<pid>/cmdline` on a shared host.
4. **No orphaned-thread recovery path if the top-level Claude Code session dies mid-run.**
   `LEAKED_THREAD_IDS` lives only in Claude's in-context memory, never logged durably; no
   plugin-provided command to list/clean orphaned `~/.codex/sessions/**` threads.

### Stability / correctness
5. The entire Phase 1/2/3 orchestration "brain" (retry classification, thread bookkeeping,
   convergence gate) is unenforced natural-language prose interpreted fresh by an LLM every run,
   with zero automated test coverage — only the deterministic shell/Python layer is tested.
6. `kill_process_group`'s `kill -TERM/-KILL -"$pid"` assumes Codex never `setsid()`s a child out of
   its process group; unverified against real Codex subprocess behavior.
7. `$PROMPT_FILE` deferred-deletion ordering (must outlive `wait "$CODEX_PID"`) is reasoned
   correctly but untested under real scheduling delay (fixture stand-ins are synchronous).
8. `resolve_rollout`'s `find ... | head -1` has no multiplicity check — a silent wrong-file read on
   a hypothetical duplicate match would be indistinguishable from success.
9. `timeout`'s "resume-safe" classification is empirically tested only for `nonzero_exit`; other
   rows (including `timeout` itself) are "inferred safe by identical reasoning," self-disclosed as
   untested in SKILL.md's own table.

### Edge cases
10. No diff-size preflight / no guard against context-window overflow on a huge diff.
11. Large pasted non-repo artifacts risk OS `ARG_MAX` (E2BIG) at `execve`, a failure mode invisible
    to the documented reason table.
12. No per-round re-validation that a diff is still non-empty (mainly a round-1 concern, since
    round 2+ never re-collects).
13. Only "zero progress twice in a row" is detected — a finding that gets rebutted/re-raised across
    non-consecutive rounds with no new evidence each time is not caught as non-convergent.
14. No compaction strategy for Claude's own accumulating conversational context across up to 20
    rounds (Codex's context stays light via resumable threads; Claude's does not).
15. Shallow clones (`--depth 1`) as a `--base <ref>` diff source are an unaddressed known limitation.

### Security / trust boundary
16. Codex's own past-round output (folded into the next round's History/`--focus`) has no explicit
    "treat as data, not instruction" framing, unlike the diff/`--focus` boundary — a theoretical
    second-order injection vector.
17. `codex exec --sandbox read-only` is trusted with no independent plugin-level verification (e.g.
    a `git status` sanity check before/after a round).
18. `resolve_rollout` trusts `~/.codex/sessions/` content implicitly with no ownership/permission
    check.

### UX / operability
19. No cost/token visibility anywhere in the final report; `model_reasoning_effort=xhigh` is
    hardcoded with no caller-facing knob.
20. Parallel-mode per-group narration has no aggregated "X of N groups done" summary line.

### Scope / feature gaps
21. No incremental/delta review mode.
22. No numeric/aggregate severity scoring across rounds.
23. No structured, machine-readable final verdict artifact (only the JSONL log + prose report).
24. No headless/CI-gateable entry point — `/ccs` is structurally an interactive skill invocation;
    the plugin's own CI doesn't dogfood `/ccs`.
25. No `--paths`/file-filter flag — confirmed in `references/parallel-mode.md`.
26. No model/effort selection or adaptive low-effort-first strategy.
27. No support for reviewing a remote PR diff without a local clone, or format-aware review of
    notebook/schema diffs.

### Already fixed — explicitly out of scope for this roadmap
SKILL.md size/reload restructure (PR #53, v0.5.6); disclosure-ordering fix (PR #54, v0.5.7); git
environment sanitization / `core.fsmonitor` / external-diff-driver injection (`git_safe()`);
`SAFE_GIT_HOME` leak in the collector; zsh word-splitting bug in fallback env-var unset; non-repo
isolation + parallel mode (allowlist redesign); `coverage.source` splicing on failure/interrupted
responses; stale-install detection; leaked round-1 threads now tracked via `LEAKED_THREAD_IDS`
(though see #4 above — tracking exists, durable recovery does not); resume-safety classification
table itself (candor gap in #9 is new, the table isn't); binary/symlink/TOCTOU/FIFO/oversized-file
handling in the untracked-file collector; `--coverage-out` write-failure handling; CI (ShellCheck +
`bash -n` + fixtures + collector selftest); `codex-direct-review` removal; dangling
cross-references from the SKILL.md split.

## External research

### Competitive landscape
No confirmed direct competitor combines: two different model vendors, resumable per-round threads,
N-way parallel dimension-focused reviewers, and non-repo-artifact support via a throwaway repo.
CodeRabbit/Sourcery/Qodo/Greptile/Cursor Bugbot/GitHub Copilot code review are all single-model,
single-pass (per push/PR), SaaS-integrated tools — none do genuine cross-vendor adversarial
consensus. Greptile/Qodo differentiate on whole-repo semantic indexing, which `/ccs` lacks (it
works from diffs/artifacts, not a persistent repo-wide index). **This section is weaker than
ideal**: the research sub-agent tasked with it did not return a fully source-verified answer in
time, so treat "no direct competitor found" as "not found in this pass," not as a confirmed
negative.

### Multi-agent / adversarial LLM review literature
Multi-agent debate improves factuality/reasoning (Du et al. 2305.14325) but has real, documented
failure modes directly relevant to `/ccs`'s design:
- **Sycophancy** (Sharma et al./Anthropic, 2310.13548): a "reach consensus" loop risks converging
  on a mutually agreeable wrong answer.
- **More rounds ≠ better** (Smit et al., "Should We Be Going MAD?", 2311.17371): multi-agent debate
  does not reliably beat cheaper alternatives without careful tuning of agreement thresholds.
- **Judge gameability** (Wang et al., 2305.17926): LLM judges are gameable by response order alone.
- Best practice from the literature: distinct roles/personas per agent (already true for `/ccs` —
  Claude vs. Codex are different vendors, not the same model twice) and a separate, less-informed
  judge rather than self-declared consensus (not currently how `/ccs` decides convergence).
- No paper in this literature uses code review as the task domain specifically; OpenAI's CriticGPT
  is the closest code-specific prior art (noted from general knowledge, not independently
  re-verified this session).

### Claude Code plugin ecosystem norms
`claude plugin validate --strict` and `claude plugin eval` (eval cases with graders, ablation
runs, CI-gateable exit codes) exist but appear essentially unused industry-wide, including by
well-known repos. Adopting them would be a real, currently-rare differentiator. Even prominent
community plugin repos are inconsistent on LICENSE/CHANGELOG/CONTRIBUTING, so the ecosystem bar is
not uniformly high.

### Codex CLI internals (2025–2026)
- `codex exec fork` exists as an official subcommand to branch an existing session into a new
  thread — a possible alternative to `resume` for spinning up parallel-mode reviewer threads.
- Rollout files (`rollout-<timestamp>-<thread_id>.jsonl`) under `$CODEX_HOME/sessions/` **can be
  transparently gzip-compressed on disk**, and session lookup is now backed by an internal SQLite
  index — none of this is a documented stable public contract. Two real, currently-open upstream
  bugs exist in exactly this subsystem: **openai/codex#40630** (thread-store ordinal mismatch) and
  **#35746** (paginated history drops flattened rollout records, reuses ordinals). This directly
  elevates internal finding #8 (`resolve_rollout`'s naive `find | head -1`) from theoretical to
  "coupled to a subsystem with known, open corruption bugs."
- Usage/quota accounting has multiple open 2026 issues (**#41220**, **#42282**, **#39167**,
  **#38116**, **#35226**) — directly elevates internal finding #19 (no cost visibility, hardcoded
  `xhigh` effort): a 20-round, N-group parallel run at max effort has no exposed cost estimate and
  no way to trade off thoroughness vs. spend, against a backdrop of Codex's own quota accounting
  being unreliable right now.
- OpenAI shipped its own plugin/marketplace system inside Codex CLI (0.153.0) — a strategic risk
  that first-party tooling could absorb wrapper-style orchestration.

## Proposed roadmap (four phases, in priority order)

Plugin author has confirmed all four phases should eventually happen; this doc sequences them and
opens phase 1 for concrete design. Phases 2–4 are listed at roadmap depth only (not yet
fully designed) so the Codex round can react to the sequencing itself, not just phase 1's details.

### Phase 1 — Stability/correctness emergency fixes (items A, F above)
- **F**: Fix README.md's stale tmux-pane description (2 locations) to match the actual, already-
  shipped removal.
- **A**: Stop automatically destroying diagnostic evidence on failure/inconclusive terminal
  outcomes. Draft approach: classify Phase 3's terminal outcomes into "clean success" (converged /
  consensus reached) vs. "failure or inconclusive" (`COULD NOT VERIFY`, `NOT CONVERGED`, any
  post-dispatch failure state); run automatic `--cleanup` only for the former; for the latter,
  skip cleanup, surface the thread ID(s) and rollout file path(s) explicitly in the final report,
  and tell the user to clean up manually once they've inspected them. For `--capture-evidence`
  mode specifically, skip the raw-eventlog deletion step under the same failure conditions instead
  of always deleting immediately after extraction.
  - **Open question for Codex**: is "skip cleanup on failure, surface paths" sufficient, or does
    leaving live Codex threads around on failure create its own resource-leak/security concern
    that needs a bound (e.g., a TTL, or an explicit `--keep-evidence` opt-in flag instead of making
    it the unconditional default for all failure states)?
  - **Open question for Codex**: should the raw eventlog's retention-on-failure also need a
    redaction pass (in case the diff/focus content itself contains secrets), or is "same trust
    level as the rollout file we already leave behind on failure" an acceptable equivalence?

### Phase 2 — Convergence-logic hardening (item B above)
Goal: address the literature-confirmed sycophancy and "more rounds ≠ better" failure modes, and
close internal finding #13 (oscillation across non-consecutive rounds not detected as
non-convergent). Not yet designed in detail — this is the headline open question for the Codex
round: **what concrete, checkable signal should replace or augment "zero new findings for two
consecutive rounds" as the convergence gate, given that (a) a rebut/re-raise cycle with no new
evidence should count as non-convergent even if it isn't literally static, and (b) the gate must
stay cheap enough to evaluate every round without itself becoming a third LLM call?**

### Phase 3 — Upstream-risk hardening (items C, D above)
- **C**: Make `resolve_rollout` gzip-aware and add a multiplicity guard (fail loudly instead of
  silently taking `head -1` on >1 match), given the confirmed-open upstream rollout-corruption
  bugs (#40630, #35746).
- **D**: Surface cost/token usage in the final report; make `model_reasoning_effort` a caller-facing
  flag instead of hardcoded `xhigh`, given Codex's own open quota-accounting bugs.
- Not yet designed in detail beyond this — open to Codex on feasibility/scope.

### Phase 4 — Structural/strategic expansion (items E, H above)
- **E**: Evaluate replacing/supplementing `resume` with `codex exec fork` for parallel multi-
  reviewer mode's thread-spinning mechanism.
- **H**: A headless/CI-gateable entry point, given that every direct competitor automates at the
  PR level and this plugin's own CI doesn't dogfood `/ccs`.
- This phase is architectural-scale and will get its own full brainstorming/design-doc pass later,
  not folded into this document's negotiation.

## Round 1 negotiation outcome (Codex thread `01a071e1-e91e-7a23-b2d6-cc50dcc4adb3`)

Codex returned 4 findings, all independently verified by Claude and **ACCEPTED** (no rebuttal
needed — see verification notes per finding):

1. **[HIGH, ACCEPTED] Rollout-file tailing is the wrong correctness dependency; use the CLI's own
   supported output channel instead of hardening the fragile one.** Verified directly: `codex
   --version` on this machine reports `codex-cli 0.153.0`; `codex exec --help` / `resume --help` /
   `fork --help` all confirm `--json` (JSONL events on stdout), `-o/--output-last-message <FILE>`,
   and `--output-schema <FILE>` are real, documented flags on `exec`, `resume`, AND `fork`. A grep
   of the actual installed `run-stream-review.sh` confirms it already passes `--json` and
   `--output-schema` to `codex exec`/`codex exec resume`, but **never uses `-o`** — it still
   extracts the final answer by calling `resolve_rollout()` (`find ~/.codex/sessions/**/rollout-*-
   ${tid}.jsonl | head -1`) and parsing that file for a `final_answer` message. This is exactly the
   subsystem the external research flagged as having open upstream corruption bugs (openai/codex
   #40630, #35746). **This supersedes and absorbs old Phase 3 item C** (gzip-awareness +
   multiplicity guard for `resolve_rollout`) — Codex's own recommendation, which Claude accepts:
   "avoid gzip rollout parsing entirely" rather than hardening it. New Phase 1 scope: add
   `-o "$LAST_MESSAGE_FILE"` to every fresh/resume dispatch and read the final answer from that
   file; rollout-file access, if kept at all, becomes a secondary/best-effort live-progress signal
   only, never the correctness-critical path for the actual verdict.
2. **[HIGH, ACCEPTED] Phase 1-A's evidence-retention-on-failure design was underspecified and
   didn't fix the argv-exposure gap it depends on.** Verified directly: `codex exec --help`'s own
   `[PROMPT]` argument description confirms stdin delivery is officially supported ("If not
   provided as an argument (or if `-` is used), instructions are read from stdin"). Revised Phase 1
   design (folds in old gap #3 and #11 together, per Codex's own cross-reference): (a) switch
   `--focus`/prompt delivery from argv to stdin at BOTH boundaries — Claude→`run-ccs-review.sh` and
   the wrapper→`codex exec` — closing the argv-exposure gap (old #3) and the `ARG_MAX` risk for
   large pasted artifacts (old #11) in one fix, not two; (b) retention of a failed round's
   thread/rollout is an explicit opt-in (`--keep-evidence`), never the unconditional default fallback
   for every failure state; (c) retained artifacts get a durable manifest entry (not just in-context
   memory), an explicit cleanup command, and start-of-run pruning in the same best-effort style as
   the existing Phase 0 Step 0 stale-eventlog sweep — never described as a "guaranteed TTL"; (d) no
   generic redaction pass on retained raw data (can miss secrets, can destroy the exact malformed
   output needed for diagnosis) — instead treat retained data as sensitive, store it in a
   private/owner-only directory, matching this project's existing `umask 077` convention for the
   review-history log.
3. **[MEDIUM, ACCEPTED] Concrete answer to Phase 2's open question.** Deterministic convergence
   ledger: every claim gets a stable `claim_id` (location/subject/rule), a `state` enum (`asserted`
   / `rebutted` / `accepted` / `retracted` / `deferred`), and a hash of its cited evidence.
   Convergence requires every active claim to reach a mutually-recorded terminal state with no new
   claim/evidence introduced that round. A claim that revisits a previously-seen
   `(claim_id, state, evidence-hash-set)` tuple after a rebut/re-raise cycle is explicitly
   `NOT CONVERGED` — directly closes old gap #13 (oscillation across non-consecutive rounds). Pure
   local map/set comparison, no third LLM call needed — satisfies the open question's own
   constraint. This becomes Phase 2's actual design, replacing "zero new findings for two
   consecutive rounds."
4. **[MEDIUM, ACCEPTED] Roadmap governance gap: several material items (old #5, #10/#11, #16, #17,
   #18) had no explicit disposition.** New cross-cutting rule for this roadmap: before declaring it
   complete/1.0-ready, EVERY one of the 27 internal gap-list items must have one of: a phase
   assignment, an explicit accepted-residual-risk statement, or an explicit non-goal — never silent
   omission. Specific dispositions Codex proposed and Claude accepts: old #16 (Codex's own
   past-round output needs the same untrusted-data framing as `--focus` content, not exempted) →
   Phase 1, folded into the stdin-delivery work in finding 2 above (the same trust-boundary
   discipline, applied to history-construction text too); old #17 (`git status` before/after a round
   is defense-in-depth only, never proof of sandbox enforcement) → keep as-is, but the roadmap must
   say so explicitly rather than implying it's a real guarantee; old #12 (per-round diff
   re-validation) → revise to hash the immutable review input rather than re-collecting a live diff
   every round, avoiding both linear I/O growth and review-subject drift mid-run.

**Also resolved directly by Codex, self-reported as its own tool's authoritative behavior (per this
doc's "Note on authority" — independently verified by Claude via `--help` output where checked):**
`codex exec fork` is real and available in the installed 0.153.0 CLI, supports the same
`--json`/`-o`/`--output-schema` output contract as `exec`/`resume`. Codex's own recommendation,
accepted: do NOT pull it into Phase 1 — no cross-version stability guarantee is established, so it
stays a version-gated Phase 4 canary (test parent-session immutability, concurrent children, and
resume/fork history integrity before adopting it for parallel-mode thread-spinning). Cost/effort
visibility (old #19, Phase 3-D): report selected model/effort, elapsed time, and any
process-emitted usage figures as best-effort only — never framed as authoritative billing/quota
data, and no extra quota-lookup call added.

**Revised phase scope after round 1:**
- **Phase 1** now includes: F (README fix), the `-o`/`--output-last-message` switch (absorbs old
  Phase 3-C), stdin-based `--focus` delivery (closes old #3 and #11 together), untrusted-data
  framing extended to Codex's own prior-round output (old #16), and the opt-in
  `--keep-evidence` + durable manifest + start-of-run pruning design for failure-state evidence
  retention (the original "item A," now fully specified).
- **Phase 2**: the claim_id/state/evidence-hash convergence ledger above — no longer an open
  question, a concrete design ready for an implementation plan.
- **Phase 3**: shrinks to just old item D (best-effort cost/effort reporting) plus the per-round
  hash-based revalidation refinement (old #12) — gzip-awareness (old item C) is dropped, superseded
  by Phase 1's `-o` switch.
- **Phase 4**: unchanged in spirit (headless/CI entry point), plus the specific fork-canary test
  criteria above once Phase 1's `-o`-based protocol is in place and stable.
- **New standing rule**: no phase is "done" for 1.0.0 purposes until every one of the 27 gap-list
  items has an explicit disposition (phase/accepted-risk/non-goal).

## Round 2 negotiation outcome (same thread, resumed)

Codex reviewed the round-1 revision and returned 3 more findings (all medium, all led with an
explicit "not verified beyond the supplied revision summary" disclosure per this skill's own
ordering rule). Claude reviewed all 3 as sound engineering-completeness critiques of the round-1
revision (not factual claims needing external verification) and **ACCEPTED all 3**, concretized
using patterns that already exist elsewhere in this same codebase rather than inventing new ones:

5. **[MEDIUM, ACCEPTED] `-o`/`--output-last-message` needs an explicit per-dispatch file-lifecycle
   contract, or a failed run can be read as a stale prior success.** Concretized: allocate a fresh
   `mktemp`'d `LAST_MESSAGE_FILE` for every single dispatch attempt (fresh, resume, AND every
   Guards-section retry attempt — never reused across attempts, same discipline this file's Phase 1
   Step 0 already uses for `PID_FILE`/`OUT_FILE`/`ERR_FILE`/`FOCUS_FILE`). Only trust its content
   when ALL of: the wrapper's own `codex exec` exit code was 0, the `--json` stdout stream actually
   emitted its completion/success event for this attempt, and the file was written during this
   attempt's own lifetime — never fall back to a leftover file from an earlier attempt. Delete it
   after use; retain only under `--keep-evidence` (same opt-in as the round-1 evidence-retention
   design).
6. **[MEDIUM, ACCEPTED] Hash-based revalidation needs a defined canonical subject, a frozen
   snapshot, and an explicit mismatch action — not just "compute a hash."** Concretized: the
   canonical subject (the collected diff bytes for a repo review, or the pasted artifact bytes for
   a non-repo-artifact review) is fixed and hashed exactly once, at round 1, before any dispatch —
   never recomputed against a live, possibly-since-changed workspace. If a mismatch is ever
   detected (including a deliberately amended artifact/diff): **do not resume the existing
   thread(s)** — terminate that review (run Phase 3 cleanup on its threads), start an entirely new
   review with a new session id and new threads. Never let one thread's history argue across two
   different review subjects.
7. **[MEDIUM, ACCEPTED] "Switch to stdin" needed an actual transport, or the fix is nominal only.**
   Concretized, reusing this file's OWN existing `$PROMPT_FILE` deferred-deletion invariant (already
   documented for the wrapper's internal prompt handling) rather than inventing a new mechanism: at
   the Claude→wrapper boundary, the already-existing sentinel-file `FOCUS_FILE` (mktemp'd, written
   via the Write tool, already private-by-default via `mktemp`'s own permissions) is redirected
   directly into the wrapper's stdin — never `printf | wrapper`, never embedded in a `sh -c` string,
   never a `--focus "$FOCUS_TEXT"` argv value. At the wrapper→`codex exec` boundary, replace the
   current `-- "$FOCUS"` positional-argv pattern (confirmed present in the installed
   `run-stream-review.sh`: `codex exec resume "$RESUME_THREAD_ID" --json ... -- "$FOCUS" < /dev/null`)
   with the CLI's own documented `-` PROMPT convention to force stdin reading, sourced from the same
   private file, deleted only after the child process exits — exactly `$PROMPT_FILE`'s existing
   ordering rule (old gap #7), just applied to this new call shape too. `set -x`/xtrace stays off
   for this whole call chain.

**Codex's own summary for this round**: the round-1 direction is sound, but not yet CLEAN without
these three concrete contracts — explicitly including that stdin is only a real fix "when raw focus
bytes enter through an actual stdin/file-descriptor transport and never through a parent command
string, environment, trace, or world-readable temporary file," and that an artifact genuinely
changed between rounds "should always start a new review from a new immutable snapshot" rather than
resuming. Both points are folded into findings 6/7 above.

**Revised Phase 1 scope after round 2** (supersedes the round-1 revision's Phase 1 description):
Phase 1 now specifies, concretely: (a) the `-o` file-lifecycle contract (finding 5); (b) the
canonical-subject hash + mismatch-restarts-review rule, which also answers round 2's own open
question about intentional artifact changes (finding 6, folds in old #12's revalidation refinement);
(c) the exact stdin transport at both boundaries, reusing the existing `$PROMPT_FILE`
deferred-deletion pattern rather than a new one (finding 7, closes old #3/#11 concretely, not just
in principle).

## Round 3 negotiation outcome (same thread, resumed)

Codex confirmed findings 1–5 and 7 are now fully resolved by the round-2 concretization, and
raised exactly **one** remaining finding: item 6 (hash-based revalidation) was internally
self-contradictory — "hashed once, never recomputed from the live source" cannot coexist with
"detect a mismatch and restart," since detecting a mismatch against the *original* artifact
requires re-observing that live source, which the same sentence says never happens. Codex offered
two coherent resolutions and recommended one, consistent with this roadmap's own stated goal of
avoiding per-round live-diff recollection:

8. **[MEDIUM, ACCEPTED — Codex's recommended option]** "Mismatch" is redefined to mean **snapshot
   corruption/tampering of Claude's own private copy**, never a changed original artifact. Concretely:
   round 1 collects the diff/artifact bytes once into a private snapshot file and hashes it. Every
   later round verifies only that the SNAPSHOT FILE ON DISK still matches that original digest
   before dispatch (catches accidental deletion/corruption/TOCTOU on our own temp file) — it never
   re-observes the real working tree or the original pasted text. An intentionally amended
   artifact/diff is **out of scope for an active review by design**: reviewing new changes requires
   an explicit new `/ccs` invocation (a new review, new session id, new threads), never something
   the running review auto-detects and pivots on mid-flight. This matches how the resumed-round
   mechanism already behaves today (round 2+ never re-collects the diff either way) — it closes the
   contradiction without adding the live-recollection cost the design was trying to avoid in the
   first place.

**Revised Phase 1 scope after round 3** (final refinement to item 6 from round 2): "hash-based
revalidation" in Phase 1 now specifically means integrity-checking Claude's own private snapshot
file against corruption/deletion between rounds — not change-detection against the original source.
Reviewing a changed artifact/diff is an explicit non-goal for a single active review; the roadmap
should say so plainly rather than implying auto-detection.

## Phase 2 negotiation (second `/ccs` session, non-repo-artifact, post-Phase-1-implementation)

> Status: **negotiated to CLEAN with Codex**, thread `01a0741d-44e6-7ea0-8a8a-ed3cd988a95d`
> (cleaned up after convergence), 6 rounds, 0 unresolved disagreements. Conducted after Phase 1
> shipped in full (6 items, PRs #55–#59, `codex-stream-review` now v0.9.0) — this negotiation
> concretizes the Phase 2 headline sketch from the original round-1 negotiation above (the
> "deterministic convergence ledger" idea) into an actual, implementable design, grounded in the
> REAL current SKILL.md mechanics as they exist post-Phase-1 (the review-history JSONL schema,
> the `finding_id`/`linked_finding_id`/`claude_verification[].action` fields, the "Zero progress
> twice in a row" Guards rule, and Phase 1 item 6's `SNAPSHOT_DIGEST` mechanism), not the
> pre-implementation sketch that originally proposed it.

**Round-by-round summary:**
- **R1** — 4 findings, all HIGH/MEDIUM: (1) the lifecycle needs a distinct verified-fix terminal
  state, since `accepted` only means "Claude agrees the finding is valid," not "the fix was applied
  and re-confirmed"; (2) `claim_id` cannot be a mechanical text-similarity/hash construction — claim
  identity requires an explicit judgment call (an existing-LLM read, not a new one), with a
  fail-closed "when in doubt, treat as a new claim" default; (3) the oscillation-comparison tuple
  needs an episode/snapshot boundary, since raw evidence text can vary innocuously while the
  underlying observation is unchanged, or vice versa; (4) the persistence design needs immutable,
  append-only `claim_events` reduced on demand, not a duplicated mutable ledger object, plus
  group-namespacing for parallel mode and an explicit legacy-session/schema-version policy.
- **R2** — Claude proposed keeping claim identity entirely on Claude's own side (the "existing-LLM"
  judgment already made during Phase 2's own per-round verification pass) rather than extending
  Codex's own output schema, and asked whether Phase 1 item 6's already-shipped `SNAPSHOT_DIGEST`
  could serve as the "episode boundary" fingerprint Codex's R1 finding called for, avoiding new
  machinery entirely. Also asked directly whether the full design was at risk of over-engineering
  relative to how often non-adjacent-round oscillation is actually likely to occur.
- **R3** — Codex **substantially simplified its own R1 proposal** in response: reuse the existing,
  already-globally-unique `finding_id` as `claim_id` directly (group-namespaced for parallel mode)
  instead of a canonical structured key; add just two new fields to the existing
  `claude_verification[]` array (`claim_id`, `evidence_delta: "none"|"new"`) instead of a separate
  `claim_events` array; confirmed `SNAPSHOT_DIGEST` reuse was sound for the episode-boundary
  question. But raised a new, sharper finding: Claude-side claim linkage can identify a *re-raised*
  claim, but cannot on its own prove Codex *deliberately* retracted a disputed one — a claim
  silently disappearing from a later round's findings is ambiguous (genuine agreement? Codex simply
  overlooking it? sycophantic backing-down with no new evidence?) — and treating disappearance as
  implicit retraction would defeat the sycophancy-resistance goal entirely. Codex's own proposed fix
  required a new structured `claim_updates[]` field on Codex's own output schema.
- **R4** — Claude accepted the "resolved" terminal-state idea in full (after resolving its own
  confusion about whether the already-shipped `SNAPSHOT_DIGEST` — Claude's frozen PRIVATE COPY
  integrity check — meant the live repository was also frozen; it does not: the real repo stays
  live and mutable all session, and Codex independently re-reads it via its own shell access on any
  round, `--resume` included). Countered the schema-change proposal with a schema-untouched
  alternative: require an exact-format `DISPOSITION <claim_id>: <value> — <reason>` marker line
  inside Codex's EXISTING `summary` string field (already free text in the current schema),
  mechanically pattern-matched by Claude rather than semantically interpreted — asked Codex
  directly whether this closes the same gap as a schema-validated field. Also introduced a
  per-round "current-subject digest" to fix a related gap Codex raised about the frozen
  `SNAPSHOT_DIGEST` being unable to distinguish a genuine regression from a sycophantic oscillation.
- **R5** — Codex confirmed the marker approach **is** sufficient once parsed with strict
  cardinality/anchoring/non-empty-reason validation — "not inherently weaker once its parsed result
  is persisted." Two remaining findings: (1) a closure needs its own small immutable JSONL record
  (`claim_closures[]`) since `claude_verification[]` only covers CURRENTLY-appearing findings, and a
  closed claim by definition stops appearing; (2) the round-4 "current-subject digest" fix was
  itself a **regression** — gating oscillation detection on a whole-subject digest match would let
  an unrelated edit to a different file mask a genuine, unchanged, still-oscillating claim about an
  entirely different file, exactly the failure mode this feature exists to catch. Claude accepted
  both findings and dropped the whole-subject-digest idea entirely, keeping `evidence_delta` alone
  as the (already-sufficient) gate.
- **R6** — Codex caught one last small, concrete gap: the marker grammar only specified
  `RESOLVED`/`STILL OPEN`, omitting `RETRACTED` even though `retracted` is a required terminal
  state. Fixed by adding the third marker value. **CLEAN** — Codex confirmed the design is now
  "internally consistent and complete," using "the smallest durable mechanism needed for the stated
  convergence goals."

**What changed most from the original headline sketch, concretely:** no canonical structured key,
no evidence hashing, no separate mutable ledger object, and no wrapper/schema change — the final
design reuses three things that already exist post-Phase-1 (`finding_id`, `claude_verification[]`,
and the `summary` string field) plus two small additions (two new `claude_verification[]` fields,
one new small `claim_closures[]` array) to get the same guarantee the much heavier original sketch
was reaching for.

---

## Phase 3 negotiation (third `/ccs` session, non-repo-artifact, post-Phase-2-implementation)

> Status: **negotiated to CLEAN with Codex**, thread `01a07469-fcc0-7c31-9ef0-68f136faac37`
> (cleaned up after convergence), 4 rounds, 0 unresolved disagreements. Conducted after Phase 2
> shipped (PR #60, `codex-stream-review` now v0.10.0) — this negotiation concretizes the Phase 3
> headline sketch from the original round-1 negotiation ("best-effort cost/effort reporting") into
> an actual, implementable design, grounded in the real v0.10.0 wrapper/skill mechanics.

**Round-by-round summary:**
- **R1** — Claude's brief asked Codex directly (as the more authoritative source on its own CLI)
  whether real per-round token usage is even obtainable from `codex exec --json`'s
  `turn.completed.usage` event, since this project's own fake-CLI fixture only ever emits an empty
  `{}` there. Codex **live-verified this rather than guessing**: the real `codex-cli 0.153.0`
  populates `input_tokens`/`cached_input_tokens`/`cache_write_input_tokens`/`output_tokens`/
  `reasoning_output_tokens` (sometimes `total_tokens`) — the fake fixture's `{}` is confirmed
  non-representative, and the scope is worth pursuing. Codex raised 4 findings: (1) a raw
  grep/direct-`jq` extraction is unsafe against the wrapper's actual mixed stdout/stderr event log
  (a real capture contained a non-JSON stderr line that broke naive parsing) — must reuse the
  existing tolerant `jq -Rn`/`fromjson?` pattern from `capture-evidence.md` instead; (2) the design
  must never report a "model" value, since the wrapper only ever sets `model_reasoning_effort`, not
  `--model`; (3) telemetry needs a durable, per-round/per-group JSONL schema, since the wrapper
  deletes its event log after every dispatch; (4) a low-severity meta-note that the brief's own
  "no need to open project files" scope constraint read like an evidence-suppression instruction
  inside the untrusted Context zone — Codex correctly treated it as informational and verified the
  live files anyway, which is exactly right for a planning negotiation.
- **R2** — Claude accepted all 4 findings and proposed the concrete shapes: reuse the exact
  existing tolerant `jq` pattern; report reasoning effort only ("xhigh on fresh dispatch; inherited
  on resume"); persist a new `execution: {elapsed_seconds, usage}` object, top-level for
  single-reviewer / nested per-group in `groups[]` for parallel mode (a deliberate departure from
  Phase 2's own top-level-only convention, since execution telemetry — unlike a group-namespaced
  `claim_id` — is genuinely per-group data with no other disambiguator); plus a separate
  coordinator-measured `round_wall_seconds` to avoid overstating wall-clock cost by summing
  concurrent groups' individual times. Codex found 2 more issues: (1) the proposed "only for a
  dispatch that actually started" availability rule wrongly excluded `no_thread_started` and a
  post-launch `interrupted` — both DO have a launched child worth timing/extracting from; (2) an
  emitted-but-empty `usage: {}` object (confirmed: the fake fixture emits this even on its SUCCESS
  path) is ambiguous against "no object was ever emitted" — both need to collapse to the same
  "usage unavailable" reporting outcome, while a non-empty object with zero-valued counters must be
  kept and reported as real data.
- **R3** — Claude fixed both: availability keyed to a `DISPATCH_STARTED` marker (covering
  `no_thread_started` and post-launch `interrupted`, excluding only genuine pre-dispatch failures);
  `execution.usage` omitted (never an empty placeholder) for both the absent and the empty-object
  case, retained only when genuinely non-empty. Codex found one more subtlety, and one fixture-
  matrix impossibility: (1) setting `DISPATCH_STARTED` immediately before the background launch
  races the actual `CODEX_PID=$!` assignment on the very next line — a signal landing in that exact
  gap could see the marker true with no PID yet to reap; (2) the proposed fixture matrix asked for
  `no_thread_started` on both fresh AND resume, but that reason is structurally fresh-only (a
  `--resume` call already has a threadId and never enters the `thread.started` polling branch at
  all).
- **R4** — Claude separated TIMING (a plain `DISPATCH_START_SECONDS` snapshot, taken
  unconditionally right before launch) from OWNERSHIP (the actual telemetry-eligibility marker,
  set only after `CODEX_PID=$!` succeeds) — the narrow fork-to-PID handoff gap is accepted as an
  honest best-effort omission (no telemetry in that vanishingly rare race window, never a fabricated
  record), and corrected the fixture matrix to test `no_thread_started` fresh-only while testing
  usage/interruption variants on both fresh and resume. **CLEAN** — Codex confirmed real usage data
  on the actual installed CLI once more and that the design is complete and appropriately narrow.

**What changed most from the original headline sketch:** "cost/effort reporting" turned out to
need real design work despite sounding simple — the actual token-usage data source had to be
empirically verified (not assumed from the project's own necessarily-unrealistic test fixture), the
extraction had to reuse an already-hardened parser rather than a naive one, and the availability/
timing rules needed two rounds of correction to actually match the wrapper's real process-lifecycle
edge cases (`no_thread_started`, post-launch signals, the fork-to-PID gap) rather than a
plausible-sounding approximation of them.

---

## Phase 4 negotiation (fourth `/ccs` session, non-repo-artifact, post-Phase-3-shipped)

> Status: **negotiated to CLEAN with Codex**, thread `01a07510-4e58-7480-8f0d-158ea5d0678a`
> (cleaned up after convergence), 8 rounds, 0 unresolved disagreements. Conducted after Phase 3
> shipped (PR #61, `codex-stream-review` now v0.11.0) and after the repo's own remote/branding
> migration to `github.com/Prompinto/agent-marketplace` — this negotiation concretizes the Phase 4
> headline sketch (`codex exec fork` evaluation; a headless/CI-gateable entry point) into an
> actual, implementable design. The human maintainer added one binding constraint mid-negotiation,
> before round 1 was even reviewed: **nothing in Phase 4 may degrade the performance of, or
> introduce unintended bugs/side effects/edge cases into, the existing shipped Phases 1–3
> functionality** — this "non-regression requirement" governs every design choice below and is
> carried into the Final consolidated plan as its own explicit hard constraint.

**Round-by-round summary (6 claims tracked: f1–f6):**
- **R1** — Claude's brief proposed a 3-property canary protocol for `codex exec fork` (parent
  immutability, concurrent-child isolation, resume/history integrity) and two candidate designs for
  Item 2 (Design A: wrap the existing interactive skill in a headless invocation; Design B: a
  separate, weaker single-pass CI script), deliberately left undecided pending Codex's input. Codex
  raised 6 findings, all high/medium: (f1) the canary tested only safety, not the stated
  "beneficial" half of the goal — no baseline/threshold could ever conclude a real benefit; (f2)
  all 3 properties were conceptually described with no concrete oracle (sentinel values, exact
  assertions, timeout-as-fail handling); (f3) leaving Item 2 undecided meant NEITHER candidate
  actually satisfied Item 2's own stated goal (Design B explicitly provides a strictly weaker
  guarantee); (f4) no CI trust-boundary/permission model for a headless run over untrusted PR
  content plus live credentials; (f5) Design A's "byte-for-byte fidelity" claim was asserted as
  fact with none of the rigor already applied to fork's own claims; (f6) no defined CI output/exit
  contract.
- **R2** — Claude fixed all 6 (added a 4th cost-comparison canary property; rewrote properties 1–3
  with literal sentinels/assertions; resolved f3 by selecting Design A as Item 2's actual
  deliverable and removing Design B from this phase's scope entirely, deferring it as an unnamed,
  separately-scoped future idea; added a CI trust-boundary requirement; downgraded f5's claim to
  explicitly unverified with its own equivalence canary; defined a 5-state CI exit contract).
  DISPOSITION: f3 RESOLVED; f1/f2/f4/f5/f6 all reasserted STILL OPEN with new, sharper critiques —
  the round-1 fix's cost metric excluded the fork workflow's own mandatory parent-ingestion cost
  (making a "30% saving" achievable even if the full workflow used equal or more tokens); the
  concurrent-child property proved isolation but never proved inheritance, nor re-checked the
  parent AFTER concurrent child activity; the CI trust boundary covered only the inner `codex exec`
  sandbox, leaving the outer headless wrapper process and a likely-necessary privileged
  PR-comment-posting job unaddressed (the documented GitHub Actions "pwn request" risk shape); the
  equivalence canary had no defined comparator for matching findings across model variance; the
  exit contract conflated a converged review with real confirmed issues against an unresolved
  disagreement.
- **R3–R7** — Five more rounds of narrowing, each closing 0–2 claims with new, progressively more
  precise critiques on the remainder (never a bare reassertion — evidence_delta was "new" every
  round, the oscillation guard never tripped): R3 closed f1 and f2 (full-workflow token accounting
  with no exclusions; all 3 children now prove inheritance via a shared parent sentinel, re-checked
  post-activity, resume validated for all 3, not one). R4 closed f4 (artifact-provenance binding —
  select by triggering `workflow_run.id`, verify head SHA/PR number, schema-validate before
  rendering). R5–R7 iterated f5/f6 through: dropping an unreliable dimension/severity bucket
  comparator for exact file:line fixture-identity matching; upgrading "which file was read"
  evidence to "the orchestration loop actually ran to a terminal outcome" evidence (a
  machine-readable `orchestration-complete: rounds=<N> outcome=<...>` log line); a real JSON Schema
  replacing an illustrative prose object (missing `required` inside conditional branches meant nothing
  was actually enforced; no representation existed for a run with no underlying Codex verdict at
  all); a CLEAN/PARTIAL_COVERAGE precedence rule for when both a confirmed issue and incomplete
  coverage occur together (issues win, mirroring the interactive skill's own established
  disagreement-over-coverage-gap precedent); and finally two last-mile precision fixes — the fixed
  fixture's planted bug can never be legitimately `"resolved"` (it has no remediation step, so only
  `"open"` is correct), and the `PARTIAL_COVERAGE` schema branch had to accept both `"partial"` and
  `"unknown"` coverage status, not just `"partial"`, to match its own precedence-rule prose.
- **R8** — **CLEAN.** All 6 claims resolved. Codex's own closing assessment: "The Phase 4 design is
  ready to move from design negotiation to implementation, subject to executing its specified
  canaries and non-regression verification before adoption."

**What changed most from the original headline sketch:** both items turned out to need far more
structure than a one-line bullet suggested. Item 1 ("evaluate fork") needed a genuinely executable,
falsifiable protocol with a real cost/benefit threshold, not a conceptual safety check. Item 2
("headless/CI entry point") needed an explicit product decision (Design A, not an unresolved
choice between two candidates with different guarantees), a real CI security model addressing the
full untrusted-PR-content attack surface (not just the inner sandboxed dispatch), and a complete,
machine-validatable result contract — none of which existed in the original sketch at all. The
non-regression requirement the human maintainer added mid-negotiation shaped every fix: both items'
final designs are structurally isolated from the existing interactive `/ccs` path (a throwaway
canary script sharing zero code with `run-ccs-review.sh`/`SKILL.md`; a headless wrapper that adds a
new entry point without modifying the existing skill's own behavior).

---

## Final consolidated plan (post-negotiation, ready for implementation planning)

This section is the single source of truth for what to actually build; everything above is the
negotiation record that produced it.

### Phase 1 — Stability/correctness/security (implement first)
1. **F**: Fix README.md's two stale tmux-pane references.
2. **Replace rollout-file tailing as the correctness-critical path.** Add
   `-o "$LAST_MESSAGE_FILE"` to every dispatch (fresh, resume, and every Guards-section retry
   attempt). `LAST_MESSAGE_FILE` is a fresh `mktemp`'d file per attempt, never reused. Trust its
   content only when: exit code 0 AND the `--json` stdout stream emitted this attempt's own
   completion event AND the file was written during this attempt's lifetime. Rollout-file access,
   if kept at all, is a secondary best-effort live-progress signal only — never the source of the
   actual verdict. Delete `LAST_MESSAGE_FILE` after use; retain only under `--keep-evidence`.
3. **Stdin transport for `--focus`/prompt content, both boundaries, reusing the existing
   `$PROMPT_FILE` deferred-deletion pattern:**
   - Claude → `run-ccs-review.sh`: redirect the existing sentinel-file `FOCUS_FILE` directly into
     the wrapper's stdin. Never `printf | wrapper`, never embedded in a `sh -c` string, never a
     `--focus "$TEXT"` argv value.
   - wrapper → `codex exec`: replace the current `-- "$FOCUS"` positional-argv pattern with the
     CLI's documented `-` PROMPT convention, reading from a private file, deleted only after the
     child process exits (same ordering rule as `$PROMPT_FILE` today). `xtrace` stays off for the
     whole chain.
   - This closes the argv-exposure gap and the large-non-repo-artifact `ARG_MAX` risk together.
4. **Evidence retention on failure, explicit opt-in:** `--keep-evidence` flag (not the unconditional
   default) preserves a failed round's thread/`LAST_MESSAGE_FILE`/rollout; retained artifacts get a
   durable manifest entry, an explicit cleanup command, and best-effort start-of-run pruning (same
   style as the existing Phase 0 stale-eventlog sweep — never described as a guaranteed TTL). No
   generic redaction pass; store retained data in a private, owner-only directory.
5. **Untrusted-data framing extended to Codex's own prior-round output** — the same "data, not
   instruction" discipline the diff/`--focus` boundary already gets, applied to History-construction
   text built from earlier rounds' findings.
6. **Snapshot-integrity-only revalidation** (final, non-contradictory form): round 1 collects the
   diff/artifact bytes once into a private snapshot file and hashes it. Every later round verifies
   only that this snapshot file on disk still matches its original digest before dispatch — it
   never re-observes the real working tree or original pasted text again. Reviewing a genuinely
   changed artifact/diff is explicitly **out of scope for an active review** — that requires a new
   `/ccs` invocation (new session id, new threads), never an auto-detected mid-review pivot.

### Phase 2 — Convergence-logic hardening (final, fully concretized — see negotiation above)
Goal: close finding #13 (non-consecutive-round oscillation invisible to the current "zero progress
in the last two rounds" guard) and harden against sycophantic withdrawal, using only mechanisms
that already exist post-Phase-1 plus minimal additions — no wrapper/schema change, no new LLM call
beyond judgments Claude's existing per-round verification pass already makes.

1. **`claim_id`** = the original `finding_id` of a claim's first-ever appearance, group-namespaced
   in parallel mode (e.g. `g1:f3`). Reuses the existing globally-unique, ever-incrementing
   `finding_id` scheme as-is — no canonical structured key, no evidence hashing.
2. **`claude_verification[]` gains two fields**: `claim_id` (equal to `finding_id` for a new claim;
   equal to an existing open claim_id when Claude judges a later finding is a re-raise of it) and
   `evidence_delta` (`"none"`|`"new"` — whether this reassertion presents any new factual basis
   versus the claim's own prior occurrence). Both are Claude's own judgment, made during the
   read-and-verify pass Phase 2 step 3 already requires — no new LLM call.
3. **A new round-level `claim_closures[]` array** (present only on a round that actually closes one
   or more claims): `{claim_id, disposition, source_round, marker_reason}`, `disposition` exactly
   `"resolved"|"retracted"` — the one durable record of why/when a claim reached a terminal state,
   independent of whether it still appears in that round's `codex_review.findings[]` (by
   definition it usually won't, once closed).
4. **Closure mechanism — no schema change to Codex's own structured output.** When a claim's
   disposition needs confirming, that round's `--focus` text explicitly asks Codex to include,
   verbatim, inside its EXISTING `summary` string field, exactly one anchored, full-line marker per
   requested claim_id: `DISPOSITION <claim_id>: RESOLVED — <non-empty reason>` (Codex's own later
   live re-read of the current code/artifact confirms a fix landed), `DISPOSITION <claim_id>:
   RETRACTED — <non-empty reason>` (Codex explicitly withdraws the claim, typically after a
   rebuttal), or `DISPOSITION <claim_id>: STILL OPEN — <non-empty reason>` (no closure — logged
   informationally, not in `claim_closures[]`). Claude's parser requires exactly one marker per
   requested claim_id, only recognizes claim_ids it actually asked about, and requires a non-empty
   reason — absence, a duplicate, an unrecognized claim_id, or an empty reason all fail closed (the
   claim stays open, no closure recorded, that round cannot converge on it).
5. **Transitions are strictly one-directional and terminal**: `open -> resolved` or
   `open -> retracted`, never reversed. A recurrence of the same underlying issue after either
   terminal state is a brand-new claim_id, never a reopened old one.
6. **CLEAN requires every claim_id that has ever appeared this session to have reached `resolved`
   or `retracted`** — an `accept`-only claim with no closure entry does not satisfy CLEAN, and
   neither does any claim left at `deferred`.
7. **Oscillation guard (replaces "Zero progress twice in a row" entirely)**: the moment an `open`
   claim_id is reasserted with `evidence_delta: "none"` since its own most recent prior occurrence
   — regardless of how many OTHER rounds intervened — that round is NOT CONVERGED. Scoped per-claim,
   not per-adjacent-round-pair, which is what actually closes finding #13's gap. `evidence_delta`
   alone is the gate; an earlier design draft added a whole-subject-digest match condition and it
   was rejected during negotiation (R5) as a regression — it would let an edit to an unrelated file
   mask a genuine, still-oscillating claim about a different file.
8. **Reducer**: a deterministic, pure local read over the existing append-only JSONL log (`jq`),
   exactly how the skill already reconstructs continuity today — no new mutable ledger object
   persisted anywhere.
9. **Parallel mode**: claim_ids are group-namespaced; each group's claims/closures are independent,
   no cross-group claim_id ever collides.
10. **Schema versioning + legacy-session policy**: a version marker on a session's first JSONL
    line; `--resume` of a pre-this-feature session under the new logic is refused outright (a
    version mismatch is a hard stop requiring a fresh session) — never a mixed-mode reduce.
11. **Fail-closed universally**: any malformed/unknown claim_id reference, any transition other
    than the two legal ones, or any marker-parsing ambiguity — all leave the claim open / that
    round unable to converge, never a silent pass-through to CLEAN.

### Phase 3 — Upstream-risk hardening (final, fully concretized — see negotiation above)
Gzip-awareness for `resolve_rollout` is **dropped** — superseded by Phase 1's `-o` switch, which
removes the correctness dependency on rollout parsing entirely. Remaining scope: best-effort
execution telemetry (reasoning effort, elapsed time, real process-emitted token usage — confirmed
obtainable on the actual installed CLI, not assumed) surfaced in `/ccs`'s final report only, never
framed as authoritative billing/quota data.

1. **Extraction**: wrapper-owned (`run-ccs-review.sh`), reusing the exact existing
   `capture-evidence.md` tolerant `jq -Rn`/`fromjson?` pattern against the per-dispatch
   `$EVENTLOG` — no new parser, no raw-log retention, no extra API/quota-lookup call.
2. **Availability, precisely**: separate TIMING from OWNERSHIP. `DISPATCH_START_SECONDS` is a
   plain timestamp snapshot taken unconditionally right before the background `codex exec`/
   `codex exec resume` launch. The actual telemetry-eligibility marker is set only AFTER
   `CODEX_PID=$!` has successfully captured a real PID — never before, closing the launch-vs-PID-
   assignment race. Every terminal path gated on that PID-backed marker (normal success/failure,
   `no_thread_started`, timeout, and `interrupted` when the signal lands after PID capture)
   reaps the child first, then extracts telemetry, never altering the review verdict. Pre-dispatch
   failures (`bad_args`/`git_error`/`incomplete_collection`) and a signal landing in the narrow
   fork-to-PID handoff gap are accepted, honest best-effort omissions — no fabricated or racy
   record.
3. **Shape**: `execution: {elapsed_seconds, usage?}` on the wrapper's own JSON response — one
   optional additive field, backward-compatible with every existing consumer (`.ok`/`.threadId`/
   `.verdict`/`.coverage` reads are unaffected). `elapsed_seconds` is present whenever the
   PID-backed marker was set. `usage` is present ONLY when a genuinely non-empty usage object was
   extracted — omitted (never an empty `{}` placeholder) both when no object was ever emitted AND
   when an empty object was emitted (the real CLI does emit `{}` on some successful turns) — both
   report as "usage unavailable" downstream. A non-empty object is kept and reported as-is even
   with individual zero-valued counters (a real zero is meaningful, distinct from no data at all).
4. **Never a "model" value** — the wrapper only ever sets `-c model_reasoning_effort=xhigh` on a
   fresh dispatch (no `--model` flag exists anywhere in it); report reasoning effort only: "xhigh
   on fresh dispatch; inherited on resume" (a `--resume` call has no `-c` flags of its own).
5. **Persistence**: the review-history JSONL gains `execution` per dispatch — top-level for a
   single-reviewer round, nested inside each `groups[]` member for a parallel round (genuinely
   per-group data, unlike Phase 2's claim-ledger fields which stayed top-level because `claim_id`
   is already self-disambiguating). A separate, coordinator-measured `round_wall_seconds`
   (dispatch-fan-out to all-groups-joined) is recorded once per round — never derived by summing
   individual groups' own `elapsed_seconds`, which would overstate true wall-clock cost since
   groups run concurrently.
6. **Final report**: a "best-effort execution telemetry — not authoritative billing or quota data"
   section listing effort, per-round/per-group elapsed time, round/overall wall-clock time, and
   token usage when available ("usage unavailable" otherwise) — any summed figure explicitly
   labeled as a sum, never presented as wall-clock time or billable cost.
7. **Non-goals** (explicit, per the roadmap's own Standing rule): no cost subsystem, no
   caller-facing configuration option, no full raw event-log retention as a side effect, no
   model/quota-lookup API call, no attempt to report a "model" identity.
8. **Fixture coverage**: `no_thread_started` (fresh-dispatch-only, structurally unreachable on
   resume); populated/empty/null/absent usage, a non-JSON stderr line mixed into the stream, and
   post-launch interruption — each of those on both fresh and resume paths.

### Phase 4 — Structural/strategic expansion (final, fully concretized — see negotiation above)

**Non-regression requirement (hard constraint, governs both items below):** nothing in Phase 4 may
degrade the performance of, or introduce unintended bugs/side effects/edge cases into, the existing
shipped Phases 1–3 functionality. Item 1's canary is a fully separate, throwaway script sharing
zero code with `run-ccs-review.sh`/`SKILL.md`. Item 2 adds a new invocation path without modifying
the existing interactive skill's own behavior — any change to `SKILL.md`/`run-ccs-review.sh` that
implementation turns out to need must be verified as a no-op for the current interactive path
before Item 2 is considered done, never merely assumed.

#### Item 1 — `codex exec fork` canary (evaluation only, not adoption)

Goal: answer, with live evidence, whether `fork` is safe AND beneficial for avoiding parallel
mode's N-way redundant diff-ingestion cost. Deliverable is the canary's own executed results plus a
go/no-go recommendation — no code change to the shipped wrapper/skill.

Four independently falsifiable properties, each with a concrete, executable oracle:
1. **Parent-session immutability**: dispatch a parent turn containing a literal sentinel; fork
   twice; the parent's own rollout file must be byte-for-byte unchanged (mtime included) afterward.
   A fork command that itself errors/times out counts as FAIL, not "inconclusive."
2. **Concurrent-child isolation AND inheritance**: fork exactly 3 children concurrently from one
   parent; each child must recite ONLY its own unique sentinel plus the shared parent's sentinel
   (proving inheritance) and NEVER a sibling's sentinel (proving isolation); the parent's rollout
   is re-checked for byte-for-byte identity twice — once right after forking, once again AFTER all
   3 children's concurrent turns complete (proving isolation from concurrent activity, not just
   from the fork operation itself).
3. **Resume/fork history integrity**: fork a child, dispatch a sentinel turn to it, then in a
   separate process `codex exec resume` that child and ask it to recite both sentinels in order —
   applied independently to ALL 3 children from property 2, not just one.
4. **Comparative cost measurement** (this is what actually answers "beneficial," not just "safe"):
   dispatch the identical workload two ways — (a) today's N independent fresh `--uncommitted`
   dispatches; (b) one parent ingests the diff once, then N children are forked from it. Compare
   the FULL-WORKFLOW total (parent + all children, no exclusions) of non-cached `input_tokens`
   between the two. PASS threshold for "beneficial": at least 30% lower on the fork side. A safe
   but non-beneficial result (no measurable reduction) is a valid, complete outcome — "safe, not
   worth adopting for this use case" — not a blocker to closing this item.

Any property failing is an accepted, informative result, never re-litigated — this item's job is
to produce evidence, not to force an adoption decision either way.

#### Item 2 — Headless CI entry point (Design A only; the weaker single-pass alternative is
explicitly out of scope for this phase)

Goal: run `/ccs`'s full adversarial-review-to-convergence guarantee as a CI gate, without a live
interactive session. **Resolved during negotiation: this means wrapping the existing, UNCHANGED
interactive skill in a non-interactive `claude -p ... --headless`-style invocation** — the only
candidate that actually preserves the stated guarantee. (A separate, deliberately weaker
single-pass CI script was proposed and explicitly removed from this item's scope during
negotiation — if a lighter check is ever wanted, it is a different, separately-named,
separately-scoped future tool, not part of Phase 4.)

Before Item 2 is validated, not merely implemented:
- **Headless-vs-interactive equivalence canary**: dispatch the identical small `/ccs` review both
  ways. Compare STRUCTURED FIELDS only (verdict, per-severity finding counts, round count, thread
  count) — never prose-matching, which is neither reproducible against model variance nor
  sufficient evidence. Before comparing outputs, assert three invariants are equal between the two
  runs (same plugin version, same target-diff snapshot digest, same resolved config) — a mismatch
  invalidates the comparison entirely rather than being scored as a fidelity failure.
- **Deterministic known-bug fixture**: one fixed diff with a single, deliberate, never-remediated
  planted bug at a known `file`/`line`. PASS requires BOTH paths' own machine-readable
  `orchestration-complete: rounds=<N> outcome=<...>` log line (emitted by the loop itself,
  immediately before its own terminal cleanup — proof the full loop executed, not merely that a
  file was read) to report `outcome=CONFIRMED_ISSUES` specifically, AND both paths report a finding
  at the exact known location with `disposition == "open"` (never `"resolved"` — the fixture has no
  remediation step, so only `"open"` is ever correct for it).

**CI trust boundary** (the untrusted-PR-content + live-credentials risk surface):
- The entire `pull_request`-triggered job — including the OUTER headless wrapper process itself,
  not merely the `codex exec` calls inside it — runs with no write/deploy-scoped credentials and no
  elevated permissions, under a plain `pull_request` trigger (never `pull_request_target`, so a
  forked PR's own content can never reach the base repo's secrets).
- Result publication (posting a PR comment) is a SEPARATE `workflow_run`-triggered job, which
  necessarily runs with elevated permissions. That job never checks out or executes the PR's own
  code/content at all; it selects its input artifact by the triggering `workflow_run.id`
  specifically (never "latest"), verifies the downloaded artifact's own embedded `head_sha` and
  `pr_number` fields match the triggering event before trusting it, schema-validates the full
  payload BEFORE rendering any field, and uses a token scoped to nothing beyond posting that one
  comment.
- **Not addressed in full** — see "Phase 4 Item 2 known limitation" below: because `pull_request`
  always runs the workflow YAML as it exists on the PR's own ref (fork or same-repo, no
  distinction), and forging this gate's reported result needs no secret at all, a PR author
  motivated to defeat the gate can do so by editing the review workflow itself. The mitigations
  above close every credential/permission-escalation path they were designed for (write/deploy
  creds, elevated-permission code execution, artifact provenance spoofing via a mismatched SHA/PR
  number) — they do not, and cannot by construction, make the review's reported OUTCOME tamper-proof
  against a PR willing to rewrite the workflow that produces it. This CI result is advisory for
  every PR, not a hard security boundary.

**CI result contract** — a versioned JSON Schema (draft 2020-12), written by the `pull_request` job
via write-to-temp-then-atomic-rename to a fixed path, consumed by the `workflow_run` reporting job:
six mutually-exclusive `exit_state` values (`CLEAN`=0, `CONFIRMED_ISSUES`=1, `NOT_CONVERGED`=2,
`COULD_NOT_VERIFY`=3, `PARTIAL_COVERAGE`=4, `INFRASTRUCTURE_FAILURE`=5 — CLEAN and
CONFIRMED_ISSUES are never conflated, since CI remediation differs completely between "the code has
a confirmed problem" and "the reviewers never reached agreement"), a `verdict` field (`CLEAN` /
`ISSUES` / `UNAVAILABLE` — the last covering the two states with no underlying Codex verdict at
all), and `allOf`/`if`-`then` conditional branches with their own explicit `required` arrays per
state (a schema-authoring pitfall found and fixed during negotiation: an `if`/`then` branch's
`properties` alone constrains a field only if present — it does not require it). `CLEAN` strictly
requires `coverage.status == "complete"` with zero omissions; both `"partial"` and `"unknown"`
coverage map to `PARTIAL_COVERAGE` when no confirmed issue exists, but a confirmed issue always
takes precedence over an incomplete-coverage exit state when both occur together (mirroring the
interactive skill's own already-established disagreement-over-coverage-gap precedent).

### Standing rule
Before calling this roadmap 1.0-ready, every one of the 27 internal gap-list items must have an
explicit disposition: a phase assignment, an accepted-residual-risk statement, or an explicit
non-goal — never silent omission.

### Next step
Phase 1 (PRs #55–#59), Phase 2 (PR #60, the claim ledger), and Phase 3 (PR #61, execution
telemetry) have all shipped in full — `codex-stream-review` is at v0.11.0. Phase 4 is now also
fully concretized (see "Phase 4 negotiation" above) — Item 1 (the fork canary) is ready to execute
directly; Item 2 (the headless CI entry point) is ready for implementation planning, subject to its
own equivalence canary and fixture passing during implementation, per the non-regression
requirement. Same one-item-at-a-time implement → verify → `/ccs` adversarial review-to-CLEAN →
commit/push/PR cycle every prior phase used — with Item 1 explicitly scoped as evaluation-only
(never itself requiring a merge to `run-ccs-review.sh`/`SKILL.md`) unless its own results
separately justify a follow-up adoption proposal.

---

## Phase 4 Item 1 canary results (executed after negotiation, per the negotiated protocol)

> Executed 2026-09-06 against the actual installed `codex-cli 0.153.0`, immediately after the
> Phase 4 negotiation above reached CLEAN. Standalone throwaway script (`/tmp/phase4-canary/
> fork-canary.sh`, not committed — shares zero code with `run-ccs-review.sh`/`SKILL.md`, per the
> non-regression requirement). Raw work directory (`/tmp/phase4-canary-run.QMSh6x`, including every
> dispatch's own JSONL event log and last-message file) was left on disk for inspection at
> execution time; treat the figures below as the durable record.

**Property 1 — parent-session immutability: PASS.**
Parent thread `01a0753f-85a1-75f1-b2c8-99ab944aa719`. Two forks dispatched (`codex exec fork
<parent-id> ...`, both exit 0). Parent's own rollout file
(`~/.codex/sessions/2026/09/06/rollout-2026-09-06T14-44-52-01a0753f-....jsonl`) hash and size
before and after:
```
BEFORE_HASH=0afe79a6171a0b5df5e40e1266681db97e1c84ee5d4f2f4b5f3840c148e12dd7
AFTER_HASH=0afe79a6171a0b5df5e40e1266681db97e1c84ee5d4f2f4b5f3840c148e12dd7
BEFORE_SIZE=105768  AFTER_SIZE=105768
```
Byte-for-byte identical. Forking does not mutate the parent.

**Property 2 — concurrent-child isolation AND inheritance: PASS.**
Parent thread `01a0753f-cbd1-73e2-a1c1-5286c001ff35`, 3 children forked and dispatched
CONCURRENTLY, all exit 0. Each child's own last-message output:
```
A_TEXT: PARENT-MARKER-7f3a / CHILD-A-ONLY-9d2e
B_TEXT: PARENT-MARKER-7f3a / CHILD-B-ONLY-4c81
C_TEXT: PARENT-MARKER-7f3a / CHILD-C-ONLY-e650
```
Every child recited the shared parent sentinel (proving inheritance) and ONLY its own sentinel —
never a sibling's (proving isolation). The parent's own rollout hash was identical both
immediately after forking and again after all 3 children's concurrent turns completed
(`46538a06...` both times) — the parent was not contaminated by concurrent child activity either.

**Property 3 — resume/fork history integrity, all 3 children: PASS.**
Parent thread `01a07540-007c-7aa1-857d-27cca7a9343d`, 3 children each given a distinct sentinel
turn, then each independently resumed (`codex exec resume <child-id> ...`) and asked to recite
both sentinels in order. All 3 succeeded (exit 0) and correctly recited the parent sentinel
followed by their own child-turn sentinel, in order, with no cross-contamination.

**Property 4 — comparative cost measurement: FAIL (not beneficial — actively worse).**
Identical workload (a small representative diff + 3 distinct review-focus prompts) dispatched two
ways:
```
Baseline (3 independent fresh dispatches):
  baseline0 non-cached input_tokens=19772
  baseline1 non-cached input_tokens=22142
  baseline2 non-cached input_tokens=41879
  BASELINE_TOTAL=83793

Fork (1 parent + 3 forked children, full workflow, no exclusions):
  fork parent   non-cached input_tokens=21254
  fork-child0   non-cached input_tokens=44129
  fork-child1   non-cached input_tokens=44130
  fork-child2   non-cached input_tokens=69767
  FORK_TOTAL=179280

REDUCTION_PCT = -114.0%  (fork used 2.14x the tokens of the independent-dispatch baseline)
```
The required 30% reduction threshold was not merely missed — the fork-based approach cost
substantially MORE, not less, in this measurement. Per the negotiated design, this is a valid,
complete, non-blocking outcome for this item.

**Methodology caveat, disclosed rather than hidden:** during this run, at least one bare `codex
exec` dispatch (`baseline1`) was observed spending part of its own turn exploring locally-installed,
workload-irrelevant Claude Code plugin skill files (`using-superpowers`, `ponytail`) rather than
staying scoped to the pasted review workload — the canary script did not constrain the dispatch
with `--sandbox read-only` or an explicit scope-constraint instruction the way `run-ccs-review.sh`'s
own trusted prompt template does for every real `/ccs` round. This means the token figures above are
not a perfectly clean, isolated measurement of "diff-ingestion cost alone" — some variance in both
the baseline and fork arms may be attributable to this unconstrained tool-use rather than the
workload itself. This is disclosed as a limitation, not smoothed over: however, given the fork side
lost by more than 2x rather than narrowly missing a 30% win, this methodology gap is very unlikely
to be large enough to flip the qualitative conclusion.

**Recommendation: DO NOT adopt `codex exec fork` for parallel mode's redundant-ingestion-avoidance
use case.** Fork is confirmed SAFE (3/3 safety properties passed cleanly) but NOT BENEFICIAL for
this specific use case (failed property 4 decisively) on the actual installed CLI. Parallel mode's
existing N-independent-dispatch design should NOT be redesigned around fork based on this evidence.
This closes Item 1 as an evaluated, documented non-adoption — per the negotiated design, this is a
complete outcome, not a blocker requiring further work, and needs no PR against
`run-ccs-review.sh`/`SKILL.md`. Revisit only if a future CLI release's own notes claim a change to
fork's context-sharing/caching behavior specifically.

---

## Phase 4 Item 2 known limitation (accepted, disclosed and corrected during rounds 2–3 of
implementation review)

The two-checkout trust split (`ccs-ci-review.yml`'s own header comment has the full detail) stops a
PR from tampering with the review tooling it runs, but for an `on: pull_request` trigger GitHub
always executes the workflow YAML as it exists on the PR's own ref — for a PR from a fork exactly as
much as a same-repository PR. Forging this gate's reported result needs no repository secret at all:
`github.event.pull_request.head.sha`/`.number` are ordinary, non-secret event-payload fields, and
`actions/upload-artifact` needs only the default, unprivileged `GITHUB_TOKEN` every run already has.
A PR author — from a fork, or from within the repository, no distinction — could therefore edit
`ccs-ci-review.yml` itself to skip the real review and upload a fabricated result with valid
provenance fields, and the trusted reporting job has no way to detect that the real review never ran.

*Correction (round 3):* an earlier draft of this section claimed fork PRs were structurally
protected because GitHub withholds repository secrets from them. Two independent reviewers (both
review groups, in the same round) identified this as wrong: withholding secrets prevents secret
theft, not fabrication of a schema-valid result, which requires no secret whatsoever. The corrected
position is that this CI result is **advisory for every PR, fork or same-repo alike** — a real,
useful signal when nobody bothers to forge it, but not a tamper-proof gate. Fixing this for real
would require either running the actual review logic from a workflow definition that is always
resolved from the trusted default branch regardless of what any PR contains (e.g. a
`workflow_run`-triggered redesign — a materially larger restructuring, deferred rather than
attempted here since /ccs's own review mechanism executes reviewed code as part of verification and
would need new sandboxing in that context), or an org-level policy control outside this repository's
own files. **By explicit maintainer decision**, given this repository's current contribution model,
neither is pursued now: the limitation is accepted and disclosed rather than architecturally fixed,
revisitable if this repository later accepts PRs from parties motivated to defeat the gate.

**Rollout/bootstrap note.** `origin/main` does not yet contain any of Item 2's 5 new files
(`ccs-ci-review.yml`, `ccs-ci-report.yml`, `run-ccs-ci.sh`, `ci-result.schema.json`,
`validate_ci_result.py`) — confirmed directly via `git ls-tree -r --name-only origin/main`. This CI
gate can only validate a PR once these files have themselves landed on the default branch; the PR
that introduces them cannot be validated by itself. This is expected for any self-hosted CI gate's
own introduction, not a defect.

## Phase 4 Item 2 validation results (executed during implementation review)

> Executed 2026-09-06, during the round-1 review-findings fix pass on Item 2's implementation
> (`.github/workflows/ccs-ci-review.yml`, `ccs-ci-report.yml`, `run-ccs-ci.sh`,
> `ci-result.schema.json`, `validate_ci_result.py`). This section records only the HEADLESS half of
> the negotiated equivalence canary — the deterministic known-bug fixture — run for real against the
> actual installed CLIs. Mirrors the "Phase 4 Item 1 canary results" section above in style/level of
> detail.

**Fixture setup.** A throwaway 2-commit repository (`/private/tmp/phase4-item2-fixture/repo`, not
committed): the base commit has a correct `sum_first_n` in `calc.py`; the head commit changes
`for i in range(n):` to `for i in range(n + 1):` at `calc.py:3` — a single, deliberate, off-by-one
regression, never remediated on this fixture branch.

**Headless run — result: CONFIRMED_ISSUES, PASS.** Two separate headless invocations were run
against this fixture (a scripted run with its own generated `workflow_run_id`,
`canary-headless-1788677291`, and a second manual re-verification invocation using a literal
placeholder id, `"x"`, not a real generated one) and both independently reached the same qualitative
outcome: `exit_state: CONFIRMED_ISSUES`, with a finding at the exact planted bug location
(`calc.py:3`, `disposition: "open"`). Two consistent runs are stronger evidence than one. The actual
`.ccs-ci-result.json` from the second (manual) run:

```json
{"exit_state":"CONFIRMED_ISSUES","exit_code":1,"verdict":"ISSUES","workflow_run_id":"x","head_sha":"5475abf7f5922d0888d99ab79ea66820e1b832f7","pr_number":1,"findings":[{"file":"calc.py","line":3,"severity":"high","summary":"Off-by-one regression in sum_first_n: `range(n + 1)` iterates one index past the intended bound, over-summing and raising IndexError at the collection boundary.","evidence":"Diff HEAD~1..HEAD changed `for i in range(n)` to `for i in range(n + 1)` in calc.py. Direct execution: sum_first_n([1,2,3], 0) returns 1 (expected 0); sum_first_n([1,2,3], 2) returns 6 (expected 3); sum_first_n([1,2,3], 3) raises IndexError: list index out of range. Codex independently reproduced identical results via its own execution in rounds 1 and 2.","verification":"Round 1: Codex reported the finding with file/line evidence and reproduction steps; Claude independently re-verified by reading calc.py directly and executing the function for n=0,2,3, obtaining identical results — accepted as VALID. Round 2 (resume, file unchanged, no fix applied per this run's report-only override): Codex re-asserted the identical finding with no new evidence (evidence_delta=none), tripping the per-claim oscillation guard, which is the expected mechanism for a genuinely valid, deliberately-unfixed finding — yielding a terminal NOT CONVERGED for the underlying ccs skill run, correctly translated to CONFIRMED_ISSUES here since disposition was never advanced to resolved/retracted.","disposition":"open"}],"coverage":{"status":"complete","reviewed_file_count":1,"omitted":[]}}
```

Note: `workflow_run_id: "x"` above is a literal placeholder from this manual re-verification
invocation, not a real generated run id — distinct from the earlier scripted run's own generated
`canary-headless-1788677291`, which first produced this same qualitative result. Both are genuine
executions of the real headless path.

**Three real bugs found and fixed only through this actual execution** (all already reflected in
the current `run-ccs-ci.sh`, see its own header comment): a `$schema`/`allOf` incompatibility with
`claude -p --json-schema` (the flag rejects a top-level `$schema` key and a top-level `allOf`,
requiring a flattened copy of the schema handed to the CLI); the report-only prompt override so the
headless session accepts-but-never-fixes a valid finding during a CI run instead of silently
patching it and reporting a false CLEAN; and a third, found only afterward while independently
re-verifying round-1's validator-tightening fix against this section's own raw evidence: **both
real headless invocations' raw `structured_output` (confirmed directly from each session's own
transcript) omitted the `infrastructure_error` key entirely**, rather than setting it to `null` as
every branch of `ci-result.schema.json` requires. This went unnoticed at first because the
round-1-era hand-written validator did not yet check for the key's presence; once round 1's fix
tightened that validator to fully mirror the canonical schema (see "Round-1 findings" in the
implementation-review section below), the exact JSON shown above would now be rejected by the
script's own re-validation and misreported as `INFRASTRUCTURE_FAILURE` instead of the correct
`CONFIRMED_ISSUES` — a real regression risk, not a hypothetical one, since it already happened
twice out of two real runs. `build_ci_prompt()` now explicitly instructs the model to include all 9
top-level keys on every response, `infrastructure_error` set to `null` whenever nothing
infrastructure-related failed. The JSON captured above predates this fix and is kept as the
historical record of the bug it documents, not as a claim that a fresh run today would reproduce it.

**Honest disclosure — this is not the full equivalence comparison.** Only the HEADLESS half of the
negotiated headless-vs-interactive equivalence canary has been run. The INTERACTIVE half (running
the identical fixture through a live, human-driven `/ccs` session and comparing structured fields —
verdict, per-severity finding counts, round count, thread count — against this headless result) has
NOT yet been run. Do not treat this section as closing that canary requirement; it only confirms the
headless path itself reaches the correct terminal outcome on a known-bug fixture, which is real,
useful evidence, but is one half of what was negotiated.

---

## Appendix: original round-1 negotiation brief (historical)

This is **no longer live guidance** — it's the brief that opened round 1, kept for the negotiation
record. See "Final consolidated plan" above for what was actually agreed.

This is a **non-repo-artifact** review: there is no diff. Negotiate the plan itself — sequencing,
Phase 1's two open questions above, Phase 2's convergence-gate design question, and anything in the
internal/external research that seems wrong, overstated, or missing a risk. The goal is a
concretized, mutually-agreed Phase 1 design (ready to turn into an implementation plan) plus a
sanity-checked sequencing for Phases 2–4.

The plugin author additionally asked these four questions to be answered explicitly in the review,
not just implicitly covered:
1. **Is the plan itself sound?** Does the phase ordering and the specific Phase 1 design actually
   solve the stated problems, or does it just look plausible?
2. **Is the tech/approach used valid and current?** In particular: is depending on `codex exec`
   `resume`/rollout-file tailing, given the confirmed-open upstream corruption bugs (#40630,
   #35746), still the right foundation, or should Phase 1/3 reconsider it now rather than patch
   around it? Is `codex exec fork` (Phase 4 candidate) actually available/stable enough to pull
   forward, or premature?
3. **What holes remain?** Anything in the 27-item internal list, the roadmap, or the two Phase 1
   open questions that is underspecified, wrong, or missing.
4. **What could make this worse, not better?** Specifically: could keeping Codex threads/rollout
   files alive on failure (Phase 1 item A) increase disk usage, leak sensitive diff content for
   longer, or degrade performance/latency for the *next* review (e.g. `~/.codex/sessions/`
   directory growth slowing `resolve_rollout`'s glob, or accumulated undeleted threads slowing
   `codex` CLI's own session listing)? Any other proposed change (gzip-aware rollout reading,
   cost/effort surfacing, per-round re-validation) that could add latency or fragility rather than
   remove it?

**Note on authority**: this plugin wraps Codex's own CLI, so on questions about `codex exec`'s
*current* actual behavior — rollout file format/compression, `resume` vs. `fork` semantics,
sandbox mode guarantees, current rate-limit/quota accounting behavior — Codex is the more
authoritative source (it is reporting on its own tool), not merely an equal debate partner. Claude
should actively solicit Codex's direct knowledge on these specific points rather than only
defending the external research above, while still independently verifying any such claim before
it changes the plan (same equal-partnership/disclosure-ordering discipline this skill already
applies everywhere else — a claim of self-knowledge is not exempt from evidence).

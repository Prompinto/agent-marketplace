# Handoff — plugins (2026-09-06)

## ✅ DONE: git remote migration
`origin` was replaced (not added-as-second-remote) with the user's new, formal repository:
**`github.com/Prompinto/agent-marketplace`**, after Phase 3's PR (#61) was confirmed merged into
the old `origin` (`youzooyou/plugins`)'s `main` first, per the user's own agreed sequencing. The
new repo was empty at swap time — `main` (with full history through Phase 3) was pushed to it, and
stale local remote-tracking refs from the old origin were pruned (`git remote prune origin`; local
branches themselves were untouched, only their `origin/...` tracking refs). **All future
push/pull/PR work in this repo now targets `Prompinto/agent-marketplace`, not `youzooyou/plugins`.**

## In progress
- Phase 3 is fully shipped (PR #61, `codex-stream-review` v0.11.0).
- **Phase 4 has just been negotiated to CLEAN** (8-round non-repo-artifact `/ccs` session, thread
  cleaned up, 6/6 claims closed — see "Key decisions from Phase 4's negotiation" below). The final
  consolidated design (Item 1: an executable `codex exec fork` canary protocol with a real
  cost/benefit threshold; Item 2: a headless CI entry point wrapping the UNCHANGED interactive
  skill, Design A only) is written into
  `docs/2026-09-05-codex-stream-review-improvement-roadmap-design.md`'s "Phase 4 negotiation"
  section and its "Final consolidated plan" Phase 4 subsection — **this doc update is NOT YET
  COMMITTED** as of this handoff (ask the user before committing, per this project's standing
  rule).
  **The user added a binding non-regression requirement mid-negotiation**: nothing in Phase 4 may
  degrade the performance of, or introduce unintended bugs/side effects/edge cases into, the
  existing shipped Phases 1-3 functionality — this shaped every fix Codex and Claude negotiated and
  is now a first-class part of the design doc itself, not just a one-off instruction.
  Phases 1, 2, and 3 are shipped/merged (v0.9.0, v0.10.0, v0.11.0); Phase 4 is negotiated but NOT
  implemented — Item 1 is evaluation-only (a throwaway canary script, may never need a PR at all
  unless its own results justify a follow-up adoption proposal); Item 2 needs a real implementation
  pass (GitHub Actions workflow files, the headless wrapper, the JSON Schema) before it can go
  through the same implement -> verify -> `/ccs` review-to-CLEAN -> PR cycle every prior phase used.
- User asked to keep this handoff updated periodically as roadmap phases progress, not just at
  `/clear` time — update this file after each phase (or major item) ships or reaches a milestone
  (e.g. negotiation-CLEAN), not only when winding the session down.

## Roadmap status (source of truth: `docs/2026-09-05-codex-stream-review-improvement-roadmap-design.md`)

| Phase | Status | Version(s) |
|---|---|---|
| **Phase 1** — stability/correctness/security (6 items: README fix, `-o`/`--output-last-message` replacing rollout-tailing, `--focus` stdin transport, `--keep-evidence`, untrusted-data framing for Codex's own output, snapshot-integrity revalidation) | ✅ Done — negotiated (4 rounds), implemented, merged | v0.6.0 → v0.9.0 (PRs #55–#59) |
| **Phase 2** — convergence-logic hardening (claim ledger: `claim_id`/`evidence_delta`, `DISPOSITION` marker closure mechanism, per-claim oscillation guard, `REVIEW LOG INTEGRITY FAILURE`) | ✅ Done — negotiated (6 rounds), implemented (5 rounds), merged | v0.10.0 (PR #60) |
| **Phase 3** — upstream-risk hardening (execution telemetry: `execution: {elapsed_seconds, usage?}` on the wrapper's JSON response, reasoning-effort-only reporting, `round_wall_seconds`) | ✅ Done — negotiated (4 rounds), implemented + reviewed to CLEAN (7 rounds), merged | v0.11.0 (PR #61) |
| **Phase 4** — structural/strategic expansion (`codex exec fork` canary evaluation, headless/CI entry point) | ✅ Negotiated to CLEAN (8 rounds) — ✅ **Item 1 executed: fork is SAFE but NOT BENEFICIAL, not adopted (documented, no PR needed)** — ✅ **Item 2 implemented, reviewed to near-CLEAN (6 rounds; g1 CLEAN, g2's sole open item is the still-unrun interactive canary, not a defect)** — batch commit/PR in progress | — (Item 1 closed via evaluation; Item 2 implementation pending PR/merge) |

**Established per-item workflow** (used for every Phase 1 item and Phase 2): negotiate design via
`/ccs` non-repo-artifact review (isolated `CLEAN_REPO_DIR`) → implement → verify locally
(`bash -n`/`shellcheck --severity=warning`/`tests/test-run-ccs-review.sh`) → real `/ccs`
Claude+Codex adversarial code-diff review to CLEAN (never skip this, even for doc-only changes) →
feature branch → version bump (minor for behavior/interface change, patch for doc-only) → commit →
push → manual PR URL (`gh` is unauthenticated in this environment) → wait for user's "병합 완료" →
`git fetch`/`git log` to confirm → `git checkout main && git pull && git branch -d <branch>`.

## Key decisions from Phase 3's negotiation (things a future session should know before implementing)
- Codex **live-verified** (not guessed) that real `codex exec --json`'s `turn.completed.usage`
  event genuinely carries real token counters on the actual installed `codex-cli 0.153.0`
  (`input_tokens`/`cached_input_tokens`/`cache_write_input_tokens`/`output_tokens`/
  `reasoning_output_tokens`) — this project's own fake-CLI fixture only ever emits an empty `{}`
  there, which is confirmed NON-representative of the real CLI. Don't assume the fixture's shape
  reflects reality for this kind of question — ask Codex to verify directly when it's the more
  authoritative source (its own CLI's behavior), same principle as Phase 1's original negotiation.
- Extraction must reuse the EXISTING tolerant `jq -Rn`/`fromjson?` pattern from
  `capture-evidence.md` — a naive `grep`/direct-`jq -e .` over the wrapper's own `$EVENTLOG` broke
  on a real capture containing a non-JSON stderr line ("Reading additional input from stdin...").
- Telemetry availability must be keyed to whether a Codex child process was actually launched
  (`CODEX_PID=$!` succeeded), NOT to which terminal `reason` eventually occurs — `no_thread_started`
  and a post-launch `interrupted` both DO have a launched child worth timing/extracting from.
  Separate the TIMING snapshot (safe to take unconditionally, right before launch) from the
  OWNERSHIP marker (set only after `$!` succeeds) to avoid a race in the tiny fork-to-PID gap.
- An emitted-but-empty `usage: {}` (real, confirmed CLI behavior on some successful turns) and a
  genuinely absent/failed-to-extract usage object must report identically as "usage unavailable" —
  don't let an empty object masquerade as real (if uninformative) data.
- Never report a "model" value in the final report — the wrapper only ever sets
  `model_reasoning_effort`, never `--model`.

## Key decisions from Phase 3's implementation-review cycle (things a future session should know)
- The hardest problem: safely recording "was a Codex child process ever launched for this
  invocation" in the face of arbitrary signal delivery between any two bash statements, while also
  safely clearing that same tracking variable afterward so a later signal can never act on a stale,
  possibly-OS-recycled PID. Took 7 rounds to fully characterize and close — see
  `codex-stream-review/skills/ccs/references/execution-telemetry.md` section 3 for the final,
  fully-documented design.
- **Final design: two variables, two lifetimes, not one.** `$CODEX_PID` stays exactly what
  `on_signal()`'s own `kill_process_group` targets — reset to empty IMMEDIATELY after every
  `wait "$CODEX_PID"` reaps it (matching this file's own pre-existing `UNTRACKED_PID` precedent).
  `$DISPATCH_PID` holds the identical PID value once set but is NEVER reset — it exists purely as
  `build_execution_json()`'s own persistent telemetry-eligibility signal, safe to read at any point
  after the dispatch, long after `$CODEX_PID` has gone back to empty. Trying to make ONE variable
  serve both purposes was tried 3 different ways across rounds 1–4 and each attempt introduced a
  live-reproduced bug (telemetry silently lost, telemetry fabricated for a dispatch that never
  launched, or a stale-PID signal-safety hole) — the two needs are simply incompatible for one
  variable.
- Both `$CODEX_PID`/`$DISPATCH_PID` are set together, atomically w.r.t. signal delivery, via a
  brief **CATCH-and-defer** trap (`trap 'DEFERRED_SIGNAL=1' INT TERM` around the launch, then
  `trap on_signal INT TERM` restored, then `[ "$DEFERRED_SIGNAL" -eq 1 ] && on_signal`) — NOT an
  **ignore** trap (`trap '' INT TERM`), which was tried first in round 4/5 and found to have two of
  its own bugs: it DISCARDS rather than defers a signal arriving in the window (a genuine Ctrl-C
  there would silently do nothing), and an IGNORED disposition (unlike a CAUGHT one) survives
  `exec()` — so the just-launched `codex` child would inherit permanently-ignored TERM for its
  whole life, silently defeating every later graceful `kill -TERM` this wrapper ever sends it.
- `on_signal()` itself needed hardening too: it used to leave a reaped `$CODEX_PID` non-empty with
  the real trap still installed for its whole remaining body, so a SECOND signal arriving mid-cleanup
  would re-enter the function and act on the now-stale PID. Fixed by disabling INT/TERM
  (`trap '' INT TERM` — an ignore trap is correct and safe HERE, since this function always exits
  the whole script before returning, so nothing after it ever needs signal handling restored) as
  the very first statement, then resetting `$CODEX_PID` immediately after its own `wait`.
- Every one of these races was **live-reproduced by Codex** with a minimal `bash -c`/`bash -m`
  script before being reported as a finding, never just asserted from reading code — and Claude
  live-reproduced each fix's correctness the same way before re-dispatching. This is the plugin's
  own "equal partnership, verify-don't-trust, evidence-based findings" design working exactly as
  intended, applied recursively to reviewing itself.

## Key decisions from Phase 2's implementation-review cycle (things a future session should know)
- The `claim_id`/`evidence_delta`/`claim_closures[]` design deliberately reuses existing
  infrastructure (the already-unique `finding_id`, the existing `claude_verification[]` array,
  Codex's existing `summary` string field) instead of the original headline sketch's heavier
  canonical-key/evidence-hash/mutable-ledger design — Codex itself simplified its own round-1
  proposal once grounded in the real post-Phase-1 SKILL.md mechanics.
- One real departure from "no wrapper change" surfaced during implementation review (not
  negotiation): the `DISPOSITION` marker request, if left ONLY inside `--focus` text, sits inside
  `run-ccs-review.sh`'s own untrusted-data boundary — Codex could legitimately treat it as
  non-binding. Fixed with one small, purely-additive paragraph in `build_review_prompt()`'s
  TRUSTED zone (outside the boundary) establishing the marker's obligation/format as fixed and
  trusted, while WHICH claim_ids to ask about each round stays in the untrusted `--focus` text.
- A real, nearly-shipped bug: the marker grammar used ASCII `--` in the wrapper but a Unicode em
  dash (`—`) in SKILL.md/claim-ledger.md — byte-different, so a fully-compliant response would
  never have matched the parser and no claim could ever have closed. Caught by Codex in round 2 of
  the implementation review via `od -An -tx1` byte inspection. Standardized on ASCII `--`
  everywhere.
- The review-history JSONL append changed from best-effort to hard-stop-verified (new terminal
  status `🛑 REVIEW LOG INTEGRITY FAILURE`, same treatment as `🛑 SNAPSHOT INTEGRITY FAILURE`
  everywhere in the skill) — the claim ledger makes log durability load-bearing for correctness now,
  not merely an audit trail, since a silently-dropped line could hide an open/oscillating claim and
  produce a false CLEAN.

## Key decisions from Phase 4's negotiation (things a future session should know)
- The human maintainer's mid-negotiation non-regression requirement ("nothing may degrade
  performance of, or introduce bugs/side effects/edge cases into, existing Phases 1-3 functionality")
  is now a first-class, named constraint in the design doc itself, not a one-off instruction that
  only applied to this conversation — treat it as binding for Phase 4 implementation too.
- Item 1's canary needed a 4th property (comparative cost measurement, with a concrete 30% token
  threshold) beyond the original 3 safety properties — testing safety alone can never answer
  whether fork is actually worth adopting, only whether it's safe to.
- Item 2's original "two candidate designs, no recommendation" framing was itself a finding — Codex
  correctly identified that leaving it open meant neither candidate satisfied the item's own stated
  goal. Design A (headless wrapper around the UNCHANGED interactive skill) is the resolved
  deliverable; Design B (a weaker single-pass script) was removed from Phase 4's scope entirely.
- The CI trust-boundary discussion surfaced a real, well-known risk class (GitHub Actions' "pwn
  request" pattern) that the first draft missed entirely — an untrusted PR-triggered job must never
  carry write/deploy credentials anywhere in its process tree (including the outer orchestrating
  process, not just the innermost sandboxed dispatch), and posting a result comment needs a
  SEPARATE, elevated-permission `workflow_run` job that never executes PR content and validates the
  artifact's provenance (workflow_run_id/head_sha/pr_number) before trusting it.
  A JSON Schema `if`/`then` branch's `properties` alone does NOT require a field — only that
  branch's own `required` array does. This tripped up 2 rounds of the negotiation's own schema
  design and is worth remembering for any future schema work in this project.

## Key decisions from Phase 4 Item 2's implementation-review cycle (things a future session should know)
- **Round 1 (parallel g1/g2)**: the first implementation checked out and RAN the reviewed tooling
  from the PR's own head checkout — a PR could edit `run-ccs-ci.sh`/`SKILL.md` to forge a CLEAN
  result. Fixed with a two-checkout split (`trusted-tooling/` at the PR's BASE ref, `target-repo/`
  at the PR's HEAD, tooling installed/run ONLY from the former). Also fixed: `ccs-ci-report.yml` had
  no checkout at all (couldn't find its own validator/schema), both hand-written schema validators
  had real gaps vs. the canonical schema, pip install was unpinned, and the fixture/canary results
  existed but were never written into the repo.
- **Round 2**: Claude independently found (not Codex) that both real headless test runs' raw model
  output OMITTED the `infrastructure_error` key entirely rather than setting it null — invisible
  under round-1's looser validator, but would have been silently misreported as
  `INFRASTRUCTURE_FAILURE` once the validator got tightened. Fixed by explicitly instructing the
  model in `build_ci_prompt()` to always include all 9 top-level keys. Also found: the target
  checkout runs as Claude Code's own project directory, so a malicious `.claude/settings.json` hook
  planted in a PR could execute arbitrary code with this job's API-key-bearing credentials.
- **Round 3 — a real self-correction, not just a finding**: Claude's first fix for the hook risk
  (`--setting-sources user`) was applied, but Claude's OWN disclosure text claiming "fork PRs are
  structurally protected since they get no repository secrets" was WRONG, and BOTH review groups
  independently caught it in the same round. The actual fact: forging this gate's reported result
  needs NO secret at all (GitHub event-payload fields like `head_sha`/PR number are public, and
  `actions/upload-artifact` needs only the default unprivileged token) — so ANY PR author, fork or
  same-repo, can forge a fake CLEAN by editing the `pull_request`-triggered workflow file itself,
  which GitHub always runs from the PR's own ref regardless of fork/same-repo origin. **Lesson: "no
  secrets reach this PR" and "this PR cannot forge the reported outcome" are unrelated claims — do
  not conflate them again in this project.** Also confirmed empirically (`claude -p --bare` really
  does make the codex-stream-review:ccs skill unavailable) that `--bare` was correctly rejected as an
  alternative fix, and that `--setting-sources user` genuinely closes the hook-code-execution vector
  even though it leaves CLAUDE.md-as-text open (folded into the pre-existing prompt-injection
  disclosure instead of treated as a new separate gap).
- **Round 4**: g1 reached CLEAN once the corrected, honest "advisory for every PR" disclosure
  landed in both the workflow comment and the design doc. g2 caught that the "Final consolidated
  plan" section's older text still said the CI trust boundary was "addressed in full" — now
  corrected to explicitly say it is not, with a pointer to the known-limitation section.
- **Rounds 5–6**: g2 found one more real bug Claude had introduced-by-omission, again on its own —
  `build_ci_prompt()` listed "PARTIAL COVERAGE" as one of six possible skill terminal outcomes but
  never mapped the DIRECT case (the skill can report `⚠️ PARTIAL COVERAGE` in place of CLEAN, not
  merely as metadata on CLEAN/NOT_CONVERGED/COULD_NOT_VERIFY) to an exit_state — fixed with an
  explicit clause. g2's only remaining open item after that fix is the interactive-canary task
  above, not a code defect.
- **Meta-lesson repeated three times this cycle**: don't trust a disclosure/comment's own confident
  claim about what is or isn't protected — verify the actual GitHub Actions/CLI mechanics directly
  (an empirical `--bare` test, tracing what data `pull_request` actually exposes) before writing it
  down, and expect Codex to independently re-derive the same mechanics and catch a wrong claim.

## Next steps
- Phases 1–3 are all shipped and merged; the git remote migration to
  `github.com/Prompinto/agent-marketplace` and the identity rebrand (marketplace name, plugin
  authors, README, SKILL.md's install-path lookup key) are both done and merged (PR #1 on the new
  origin). Both plugins (`clear-prep@agent-marketplace`, `codex-stream-review@agent-marketplace`)
  are reinstalled and active under the new marketplace name.
- **Phase 4 Item 1 is fully done.** The fork canary was executed for real against the installed
  `codex-cli 0.153.0` (see the design doc's own "Phase 4 Item 1 canary results" section for full
  evidence): all 3 safety properties PASSED, but the cost-benefit property FAILED decisively (fork
  used 2.14x the tokens of independent dispatch, not less) — recommendation is DO NOT adopt fork
  for parallel mode. This is a complete, documented, non-blocking outcome per the negotiated
  design — no code change to `run-ccs-review.sh`/`SKILL.md` is needed or was made.
- **Phase 4 Item 2 (headless CI entry point) is implemented and reviewed to near-CLEAN.** Two
  workflows (`ccs-ci-review.yml`, `ccs-ci-report.yml`), the wrapper (`run-ccs-ci.sh`), the schema
  (`ci-result.schema.json`), and the validator (`validate_ci_result.py`) are all written. A parallel
  2-group `/ccs` code-diff review ran 6 rounds: the security group (g1) reached full **CLEAN**; the
  correctness group (g2) has exactly ONE item still open by design, not by defect — see "Key
  decisions from Phase 4 Item 2's implementation-review cycle" below for the full list of what was
  found and fixed, including two real bugs Claude found on its own (not from Codex) during
  independent re-verification.
  - **Still open, tracked, not a code defect**: the negotiated headless-vs-interactive equivalence
    canary's INTERACTIVE half has never been run (only the headless half has, twice, against the
    known-bug fixture at `/private/tmp/phase4-item2-fixture/repo`). This remains a follow-up task,
    deliberately not blocking this commit per the user's explicit decision to proceed now.
  - User explicitly said: do the PR/merge for ALL of Phase 4's code work (docs + Item 2
    implementation) together, in one batch, at the end — not a separate PR per phase step like
    Phases 1-3 used. This batch commit+push+PR is that one final step for Phase 4.

## Relevant files
- `docs/2026-09-05-codex-stream-review-improvement-roadmap-design.md` — the full roadmap: original
  gap analysis, external research, Phase 1's 4-round negotiation record, Phase 2's 6-round
  negotiation record, and the "Final consolidated plan" section with the authoritative current
  spec for every phase.
- `codex-stream-review/skills/ccs/SKILL.md` — core skill file (now ~1,900 lines after Phase 1 + 2).
- `codex-stream-review/skills/ccs/references/{capture-evidence,keep-evidence,snapshot-integrity,claim-ledger,non-repo-artifact,parallel-mode}.md` — the split-out reference files, each read only when its feature is relevant (all but `claim-ledger.md`/`snapshot-integrity.md` are opt-in flags; those two are always-on).
- `codex-stream-review/scripts/run-ccs-review.sh` — the wrapper `/ccs` dispatches through; also
  carries the trusted-zone `DISPOSITION` marker obligation (`build_review_prompt()`).
- `codex-stream-review/tests/test-run-ccs-review.sh` — 125-fixture suite (grew from 97 during
  Phase 3), run before every push.
- `codex-stream-review/skills/ccs/references/execution-telemetry.md` — Phase 3's own reference file
  (new in this phase); section 3 documents the final `$CODEX_PID`/`$DISPATCH_PID` two-variable,
  catch-and-defer signal design in full.

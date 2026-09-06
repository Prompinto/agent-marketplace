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
- Phase 3 (execution telemetry: `execution: {elapsed_seconds, usage?}`, `round_wall_seconds`) is
  **fully shipped**: implemented, reviewed to CLEAN (7-round real `/ccs` adversarial code-diff
  review — see "Key decisions from Phase 3's implementation-review cycle" below for what each round
  found), merged via PR #61 into `main`, and now also pushed to the new `origin`
  (`Prompinto/agent-marketplace`) above. `codex-stream-review` is at **v0.11.0**.
  Phases 1, 2, and 3 are all shipped/merged so far (v0.9.0, v0.10.0, v0.11.0).
- User asked to keep this handoff updated periodically as roadmap phases progress, not just at
  `/clear` time — update this file after each phase (or major item) ships or reaches a milestone
  (e.g. negotiation-CLEAN), not only when winding the session down.

## Roadmap status (source of truth: `docs/2026-09-05-codex-stream-review-improvement-roadmap-design.md`)

| Phase | Status | Version(s) |
|---|---|---|
| **Phase 1** — stability/correctness/security (6 items: README fix, `-o`/`--output-last-message` replacing rollout-tailing, `--focus` stdin transport, `--keep-evidence`, untrusted-data framing for Codex's own output, snapshot-integrity revalidation) | ✅ Done — negotiated (4 rounds), implemented, merged | v0.6.0 → v0.9.0 (PRs #55–#59) |
| **Phase 2** — convergence-logic hardening (claim ledger: `claim_id`/`evidence_delta`, `DISPOSITION` marker closure mechanism, per-claim oscillation guard, `REVIEW LOG INTEGRITY FAILURE`) | ✅ Done — negotiated (6 rounds), implemented (5 rounds), merged | v0.10.0 (PR #60) |
| **Phase 3** — upstream-risk hardening (execution telemetry: `execution: {elapsed_seconds, usage?}` on the wrapper's JSON response, reasoning-effort-only reporting, `round_wall_seconds`) | ✅ Done — negotiated (4 rounds), implemented + reviewed to CLEAN (7 rounds), merged | v0.11.0 (PR #61) |
| **Phase 4** — structural/strategic expansion (`codex exec fork` evaluation, headless/CI entry point) | ⏳ Sketch-level only, not yet negotiated | — |

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

## Next steps
- Phase 3 is fully implemented and reviewed to CLEAN (v0.11.0 locally). **Ask the user for explicit
  commit/push/PR permission before doing any git write** — do not commit just because CLEAN was
  reached; that authorizes implementation, not git operations, per this project's standing rule.
- Once given: feature branch → commit (version already bumped) → push → manual PR URL (`gh` is
  unauthenticated here) → wait for the user's "병합 완료" → `git fetch`/`git log` to confirm →
  `git checkout main && git pull && git branch -d <branch>`.
- **Then, and only then** (per the user's own confirmed sequencing — see the ⚠️ PENDING section at
  the top of this file): perform the git remote migration to
  `github.com/Prompinto/agent-marketplace`.
- Phase 4 still needs its own `/ccs` non-repo-artifact negotiation (like Phase 2 and 3 got) before
  it can be implemented — it's currently only a one-paragraph sketch.

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

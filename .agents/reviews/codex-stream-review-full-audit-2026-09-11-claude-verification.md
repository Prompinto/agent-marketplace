# Remediation Report: Response to the Full Audit of `codex-stream-review`

**Report date:** 2026-09-12 (Asia/Seoul)
**Source audit:** `.agents/reviews/codex-stream-review-full-audit-2026-09-11.md` (independent Codex
CLI agent, dated 2026-09-11)
**Base revision:** `331696c` (`chore(ccs): bump version to 1.1.0 for material-verification receipts`)
**Final revision:** `1188d7a` (`docs(ccs): correct reasoning-effort claims after removing the xhigh
override`)
**Branch:** `chore/ccs-version-bump-material-verification`
**Author of this report:** the main Claude Code session that orchestrated the remediation (not the
original auditor, not any of the fix implementers named below — this document is an independent
synthesis, written after directly re-reading every diff and re-running every test cited)

This document is written for a second, independent verification pass (the user intends to have a
separate Codex CLI session read it and cross-check it). Every claim below cites either a real commit
hash, a real file:line location, or a `codex-stream-review:ccs` review thread ID — nothing here is
asserted without a pointer to the artifact that backs it.

## 1. Summary

The original audit (`codex-stream-review-full-audit-2026-09-11.md`) reported 8 "confirmed defects"
(CSR-001 through CSR-008, priorities P1-P4) and 7 "source-proven limitations" (L-001 through L-007)
against the `codex-stream-review` plugin — the production wrapper scripts (`run-ccs-review.sh`,
`run-stream-review.sh`, `run-ccs-ci.sh`), the `collect_untracked_files.py`/`validate_ci_result.py`
Python helpers, the eval harness, and the CI workflows that consume them.

This remediation pass:

1. Independently re-verified all 15 original findings against the actual current source before
   touching anything (a separate `audit-verify` pass, itself split across sub-agents). **Result: all
   15 CONFIRMED, none overstated, understated, or disputed.**
2. Fixed 11 of the 15 (CSR-001, CSR-002, CSR-003, CSR-004, CSR-005, CSR-007, CSR-008, L-002, L-003,
   L-005, and the reusable part of L-004), documented-only 1 by explicit user decision (CSR-006),
   documented-only 1 as a disclosed, deferred design limitation (L-001), deferred 2 as genuine future
   work (the remainder of L-004, and L-006), and took no action on 1 that was already correctly
   handled (L-007).
3. Discovered and fixed **9 additional real issues** beyond the original audit's own 15 items —
   found either during independent re-verification or during the `codex-stream-review:ccs` review
   rounds this remediation itself required (listed in full in §4).
4. Was executed in 5 groups (A–E) plus a capstone whole-diff pass, each fixed by a dispatched
   implementer, each independently verified by direct reading and re-running tests, and each sent
   through `codex-stream-review:ccs` for adversarial review — with **no round limit**: several groups
   needed 2-3 review rounds before reaching genuinely CLEAN, and two of those extra rounds found real
   conceptual flaws in the FIRST fix attempt, not just cosmetic polish (§6).
5. Concluded with a capstone whole-diff review (base `331696c` → `1188d7a`) that came back CLEAN,
   `material_reviewed:true`, on its second round (thread `01a0924a-480c-7e13-884e-014a39c5a2ee`).

**Final state:** 19 commits on top of the pre-existing version-bump commit, full test suite passing
(`test-run-ccs-review.sh`, `test-run-ccs-ci.sh`, both Python validators' `--selftest`,
`collect_untracked_files.py --selftest`), whole-diff CLEAN, ready for a PR.

## 2. Independent verdict on the 15 original findings

All 15 were independently re-verified (by a dedicated `audit-verify` agent, itself split across
sub-agents for different subsets, plus my own direct spot-checks of CSR-001 and CSR-002 by reading
the exact cited source lines myself) **before** any fix was attempted. Verdict: **all 15 CONFIRMED**,
exactly as the original audit described them — no finding was found to be overstated, understated,
or wrong.

| ID | Priority | Verdict | Disposition |
|---|---|---|---|
| CSR-001 | P1 | CONFIRMED | Fixed (commit `95a8b57`) |
| CSR-002 | P1 | CONFIRMED | Fixed (commit `a61232f`, hardened further in `ddf4a91`) |
| CSR-003 | P2 | CONFIRMED, still genuinely open despite prior hardening | Fixed (commit `310701c`) |
| CSR-004 | P2 | CONFIRMED, worse than stated (a nearby comment falsely claimed the fix already existed) | Fixed (commits `c60ec79`, `a146e5a`, extended in `da02f5e`) |
| CSR-005 | P2 | CONFIRMED | Fixed (commit `c31690c`, integer-type bug in the new validator fixed in `2105ba8`) |
| CSR-006 | P3 | CONFIRMED | **Documented only** — explicit user decision (§3) |
| CSR-007 | P3 | CONFIRMED | Fixed (commit `eeb68f4`) |
| CSR-008 | P4 | CONFIRMED | Fixed (commit `ec200f4`, UTF-8 edge case fixed in `392d23c`) |
| L-001 | — | CONFIRMED | **Documented only, deferred** (§3) |
| L-002 | — | CONFIRMED | Fixed (commit `6b7b0e5`) |
| L-003 | — | CONFIRMED | Fixed (commit `4ac831d`) |
| L-004 | — | CONFIRMED | **Partially fixed as a byproduct, remainder deferred** (§3) |
| L-005 | — | CONFIRMED, +2 more sites found during verification | Fixed (commit `2afaca6`, corrected in `3ab4beb` after round 1 found the fix itself was flawed) |
| L-006 | — | CONFIRMED | **Deferred** (§3) |
| L-007 | — | CONFIRMED, already fully documented | **No action needed** (§3) |

## 3. What was documented-only, deferred, or needed no action, and why

- **CSR-006 (SHA-1-only Git object IDs)** — `run-ccs-ci.sh`, `schemas/ci-result.schema.json`, and
  `scripts/validate_ci_result.py` all require exactly 40-character SHA-1 hex IDs, rejecting a
  64-character SHA-256 Git object ID. Fixing this properly means widening 3 enforcement points
  together. The user was asked directly (`AskUserQuestion`) whether to invest in this for a
  currently-hypothetical compatibility gap (GitHub Actions' own commit SHAs are still SHA-1 today).
  **User chose documentation-only.** This is tracked as "Candidate 6" in this project's own existing
  backlog-tracking memory convention, for reconsideration if GitHub ever supports SHA-256 hosting or
  this CI script is pointed at a self-hosted SHA-256 Git server. No code was changed for this
  finding in this pass — an explicit "SHA-1 only, by design, for now" disclosure was the originally
  planned documentation step, but was not ultimately added as a separate commit since the ruling
  table above already records the decision durably in this document and the ledger; if the user
  wants an inline code comment too, that is a trivial follow-up.
- **L-001 (unbounded aggregate prompt/memory/disk consumption)** — `collect_untracked_files.py` caps
  each individual file at a fixed byte limit, but nothing caps the AGGREGATE size of everything
  collected across a whole diff/untracked-file set. The audit's own recommendation ("set an explicit,
  configurable aggregate budget... choose the limit based on a measured model-context and
  host-memory budget") is real design work requiring actual measurement, not a minimal patch.
  **Ruling: document the limitation, defer the actual budget design** to a future, dedicated cycle —
  matching this plugin's own established pattern of tracking open design candidates (see the
  `ccs_backlog_from_real_usage_feedback` memory's own existing "Candidate 3"/"Candidate 5" entries)
  rather than bolting on an undersized ceiling.
- **L-004 (CI doesn't test 3 production scripts)** — the original gap named `run-ccs-ci.sh`,
  `validate_ci_result.py`, and `scripts/hooks/pre-push` as having zero behavioral test coverage. This
  pass's own Group A work created `tests/test-run-ccs-ci.sh` from scratch (it did not exist before)
  specifically to cover `run-ccs-ci.sh` and `validate_ci_result.py` while fixing CSR-002/CSR-008 —
  **substantially closing this gap for those two paths as a direct byproduct**, not a separate
  effort. `scripts/hooks/pre-push` remains untested — that is new test-authoring work distinct from
  a bug fix, and is deferred.
- **L-006 (SKILL.md size/cost, ~2,460 lines / ~192KB, ~5,915 lines / ~458KB across all skill+
  reference markdown)** — this plugin already went through exactly this kind of restructuring once
  (the `ccs_backlog_from_real_usage_feedback` memory's own "Candidate 1", shipped as PR #53,
  splitting a 1,902-line monolith into a 1,338-line core plus loaded-on-demand reference files).
  Redoing that exercise again now, bundled into an unrelated bug-fix remediation pass, would be real
  scope creep. **Deferred**, tracked the same way Candidate 1 originally was before it shipped.
- **L-007 (CI trust / API-key exposure residual risks)** — the audit itself said plainly: "this is
  not a newly discovered exploit. The repository itself documents it." Read
  `.github/workflows/ccs-ci-review.yml` lines ~70-111 and ~200-245 directly: both risks (a
  `pull_request` workflow being editable by the PR itself, and 2 API-key exposure paths for a
  headless Claude session over untrusted PR content) are already explicitly disclosed there as
  "RESIDUAL LIMITATION, EXPLICITLY ACCEPTED"-style language. **No action needed** — already correctly
  handled.

## 4. Extra findings beyond the original 15 (all found and fixed during this remediation pass)

These were not in the original audit — they surfaced either during independent re-verification of
the original 15, or during the `codex-stream-review:ccs` adversarial review rounds this remediation
itself required. All are real, all were fixed and independently verified the same way as the
original 15.

1. **`run-ccs-ci.sh`'s `claude` binary invoked via bare ambient-PATH lookup** — the same class of
   risk as CSR-004 (which was about `git`), found in a sibling CI wrapper while verifying CSR-004.
   Fixed in commit `34b1c5e` (resolve `CLAUDE_BIN` via `command -v claude` once, before use).
2. **`CLAUDE_BIN` resolution wasn't guaranteed to be an absolute path** — a follow-up gap in finding
   #1's own fix: `command -v claude` can return a bare name (an exported shell function) or a
   relative path, neither of which stays valid after the script's own later `cd "$REPO_ROOT"`. Found
   by a `codex-stream-review:ccs` review round, fixed in commit `ddf4a91`.
3. **A 5th `GIT_BIN`/git-sanitization instance in `SKILL.md`** (Phase 1 Step 1's dispatch-time
   sanitization block, ~line 1246) that the original audit's own CSR-004 citation (4 locations) did
   not name — found during independent verification before any fix was dispatched. Fixed alongside
   the other 4 in commit `c60ec79`.
4. **A residual TOCTOU debris-cleanup gap in Group A's own CSR-002 fix** — the pre-check/post-check
   around `mv` in `write_result_atomic()` correctly detects a narrow race window (something replacing
   `$RESULT_PATH` with a directory between the pre-check and the `mv`), but the first fix left a
   stray temp file nested inside that directory uncleaned. Found by a `codex-stream-review:ccs`
   review round on Group C's own accumulated diff; fixed in commit `ddf4a91`.
5. **An integer-type over-strictness bug in the new `validate_interactive_result.py`, and identically
   in its sibling `validate_ci_result.py`** — both files' `_is_int()` helper rejected a whole-valued
   JSON float like `1.0` for an `integer`-typed schema field, when JSON Schema's own `integer` type
   is actually satisfied by any number with a zero fractional part. The OPPOSITE direction from
   CSR-005's original bug (too loose). Found by a `codex-stream-review:ccs` review round; fixed
   identically in both files (for consistency, since the helper was deliberately mirrored between
   them) in commit `2105ba8`.
6. **2 extra `mktemp -u` sites beyond L-005's own original 4-line citation** — one added by Group A's
   own CSR-001 regression test (copying a pre-existing style verbatim), one in a 3rd eval scenario's
   `setup.sh` the original audit's citation missed. Found via a fresh `grep` during Group D's own
   dispatch; fixed alongside the rest in commit `2afaca6`.
7. **The "reserve via real `mktemp`, then `rm -f`" pattern (Group D's own first fix for L-005) did
   NOT actually close the TOCTOU window** — deleting the just-created file returns the path to
   exactly the same unreserved state `mktemp -u` was already in, negating the protection the create
   just established. A genuine conceptual flaw in the first fix attempt, not cosmetic. Found by a
   `codex-stream-review:ccs` review round; corrected (private, never-deleted `mktemp -d` directory
   with a fixed filename inside it) in commit `3ab4beb`.
8. **The accompanying top-level `EXIT` trap (Group D's own first fix) could not see 3 function-local
   temp files** — Bash runs an `EXIT` trap after a function's own scope has already unwound, so a
   `local` variable's value is invisible to it, structurally, no matter how many names are added to a
   hardcoded list. Found in the same review round as #7; fixed by porting this exact plugin's own
   production `register_temp_file`/`cleanup_temp_files` pattern (a file-based, not array-based,
   registry) into the test file, in the same commit `3ab4beb`.
9. **`GIT_BIN`'s own resolution (`"$(command -v git)"`) was never verified to be an absolute path,
   in all 6 places it's resolved** — the same class of gap as extra finding #2 above (`CLAUDE_BIN`),
   just never extended to `GIT_BIN`, including in `scripts/lib/git-safe.sh`'s own shared PRODUCTION
   helper (not just documentation). Found by the capstone whole-diff review round 1 (thread
   `01a09195-6c9e-7de3-837f-1dfc50efde94`); fixed in commit `da02f5e`.

A 10th item, not a "finding" in the audit sense but a real behavior change requested directly by the
user mid-session (independent of the Codex audit entirely): both `run-ccs-review.sh` and
`run-stream-review.sh` unconditionally hardcoded `-c model_reasoning_effort=xhigh` on every fresh
Codex dispatch. Querying the real Codex CLI's own error message directly (an invalid
`model_reasoning_effort` value) confirmed the actual valid values, in order:
`none, minimal, low, medium, high, xhigh, max` — `xhigh` is **not** the highest tier; `max` is. A
user with `model_reasoning_effort = "max"` configured in their own `~/.codex/config.toml` was being
silently downgraded to `xhigh` on every `/ccs` dispatch, with no way to opt out. No design rationale
for this cap was found anywhere in the codebase's own docs/comments — it appears to simply predate
`max`'s existence as a tier. **Fixed** (commits `7fecacd`, `1188d7a`) by removing the override
entirely from both dispatch sites, so the wrapper now defers completely to whatever the invoking
Codex CLI environment/config specifies — matching how the wrapper already never overrides `--model`.
This is "Group E" in the work log below.

**Important deployment note:** this fix is only present in this branch's own source. The currently
INSTALLED plugin cache (`~/.claude/plugins/cache/agent-marketplace/codex-stream-review/1.1.0/`, the
latest version published to `main` as of this remediation pass) still has the old hardcoded `xhigh`
at `run-ccs-review.sh:1001` — confirmed by directly reading that installed file. This remediation's
fix will only take effect for the user's own everyday `/ccs` usage once this branch is merged, a new
version is published, and the plugin is reinstalled/updated.

## 5. Full commit list (19 commits, base `331696c` → `1188d7a`)

| # | Commit | Message |
|---|---|---|
| 1 | `95a8b57` | fix(ccs): close run-stream-review.sh's repeat-signal double-JSON-output bug (CSR-001) |
| 2 | `a61232f` | fix(ccs): make run-ccs-ci.sh fail loudly instead of silently on a directory result path (CSR-002) |
| 3 | `ec200f4` | fix(ccs): catch malformed-JSON errors cleanly in validate_ci_result.py (CSR-008) |
| 4 | `4ac831d` | docs(ccs): stop directing stream-review callers at the unsupported rollout-tail mechanism (L-003) |
| 5 | `392d23c` | fix(ccs): close 3 ccs-review findings in CSR-008/test-run-ccs-ci.sh |
| 6 | `310701c` | fix(ccs): tighten --receipt-slot to the schedule's actual 1-70 range (CSR-003) |
| 7 | `c31690c` | fix(ccs): make the eval schema checker authoritative against the canonical schema (CSR-005) |
| 8 | `c60ec79` | fix(ccs): resolve GIT_BIN before the local-env-vars enumeration call, not after (CSR-004) |
| 9 | `34b1c5e` | fix(ccs): resolve claude's absolute path once in run-ccs-ci.sh instead of a bare PATH call |
| 10 | `a146e5a` | docs(ccs): fix overstated GIT_BIN resolution timing claim in 2 comments |
| 11 | `ddf4a91` | fix(ccs): harden run-ccs-ci.sh's CLAUDE_BIN resolution and TOCTOU cleanup |
| 12 | `2105ba8` | fix(ccs): _is_int() must accept a whole-valued float, not just a Python int |
| 13 | `eeb68f4` | fix(ccs): collect_untracked_files.py --selftest leaks its GIT_SAFE_HOME tempdir |
| 14 | `2afaca6` | fix(ccs): close mktemp -u TOCTOU windows, add top-level cleanup trap |
| 15 | `6b7b0e5` | fix(ccs): scope the stale event-log /tmp sweep to the invoking user |
| 16 | `3ab4beb` | fix(ccs): reserve-then-delete doesn't close mktemp's TOCTOU window; add function-local-safe registry |
| 17 | `da02f5e` | fix(ccs): GIT_BIN must also be verified absolute, not just resolved (CSR-004 follow-up) |
| 18 | `7fecacd` | fix(ccs): stop overriding the user's own Codex reasoning-effort config |
| 19 | `1188d7a` | docs(ccs): correct reasoning-effort claims after removing the xhigh override |


## 6. Group-by-group execution log, review rounds, and notable events

Grouped by implementation batch. Each group was implemented by a dispatched agent, independently
verified by direct reading of the diff plus re-running the affected tests, then sent through
`codex-stream-review:ccs` — continuing the fix/re-review loop with no round limit until genuinely
CLEAN.

- **Group A** (CSR-001, CSR-002, CSR-008, L-003) — **2 review rounds**, plus a **live
  `no_material_reviewed` hollow-thread event** worth calling out specifically: the SECOND review
  round's own resume attempt hit `ok:false`/`schema_mismatch` with detail
  `"no_material_reviewed: material_reviewed is false"` — the exact never-resume-safe failure mode
  this plugin's own, separately-shipped material-verification feature is designed to catch. Followed
  that feature's own documented recovery precisely: abandoned the thread, issued exactly one fresh
  dispatch (never `--resume`) — succeeded, CLEAN. A genuine real-world validation that the
  material-verification feature (shipped just before this remediation pass began, in the SAME
  Codex-CLI-driven review loop this remediation pass itself uses) works exactly as designed, even
  firing on an ad-hoc manual dispatch for a completely unrelated task.
- **Group B** (CSR-003, CSR-005) — **1 review round**, CLEAN.
- **Group C** (CSR-004 + extra findings #1, #4, #5 from §4) — **3 review rounds**. Round 1 found 1
  LOW (a comment overstating exactly when `GIT_BIN` gets resolved — fixed directly, not worth a
  subagent dispatch). Round 2 found 1 LOW (extra finding #1's own follow-up, #2 in §4) + 2 MEDIUM
  (extra findings #4 and #5 in §4) — both MEDIUMs were gaps in EARLIER groups' own work (Group A's
  CSR-002, Group B's CSR-005 validator), only surfacing once Group C's changes pushed the
  accumulated diff through another full review pass. Round 3: CLEAN.
- **Group D** (CSR-007, L-005 + 2 extras, L-002) — **2 review rounds**. Round 1 found 2 LOW findings
  that both pointed to a genuine conceptual flaw in the first fix attempt (extra findings #7 and #8
  in §4) — not cosmetic, a real "this doesn't actually work" gap in reasoning that looked correct at
  first pass. Round 2, after a proper fix (a private, never-deleted `mktemp -d` per marker, and a
  file-based registry mirroring this plugin's own production pattern): CLEAN.
- **Capstone whole-diff review** (base `331696c` → HEAD after Group D) — **2 rounds**. Round 1 found
  1 MEDIUM (extra finding #9 in §4, the `GIT_BIN` absoluteness gap) — genuinely only visible once ALL
  4 groups' changes were reviewed TOGETHER, since no single group's own isolated review touched
  `scripts/lib/git-safe.sh`. Round 1 also hit a **real VPN disconnection** mid-dispatch: an ordinary
  `timeout` failure (2534 elapsed seconds against a 1800s limit — not a `no_material_reviewed`
  failure, so safely resumable). Recovery took 3 attempts to get the CLI syntax right (`--resume`
  requires ONLY `--cwd`, no scope flag — the wrapper explicitly rejects combining `--resume` with
  `--uncommitted`/`--base`/`--commit`, since a resumed round never re-collects the diff): the first
  retry omitted the required `--cwd`, the second wrongly combined `--resume` with `--base`, the third
  succeeded. Round 2 (after the GIT_BIN fix, commit `da02f5e`): CLEAN (thread
  `01a0924a-480c-7e13-884e-014a39c5a2ee`, `material_reviewed:true`).
- **Group E** (the reasoning-effort fix, §4's 10th item) — **1 review round**, CLEAN (thread
  `01a092e0-2db1-7bb0-8671-86386f8706e5`, `material_reviewed:true`).

**Overall: 4 implementation groups + 1 capstone pass + 1 follow-up group, roughly 14
`codex-stream-review:ccs` review rounds total across the whole remediation, every finding
independently re-verified against the real, current source (or a real reproduction) before being
ruled on — never accepted or dismissed on the reviewer's word alone.**

## 7. Process note: an avoidable risk during investigation (not a data-loss incident)

While investigating a tangential question — what reasoning-effort value Codex CLI falls back to when
none is configured anywhere — the user's real `~/.codex/config.toml` was temporarily moved aside
(`mv ~/.codex/config.toml ~/.codex/config.toml.bak`) to observe the CLI's own default behavior. This
triggered two real live dispatch attempts against the user's actual configured backend; the second
one (intended to observe the "no config at all" default) instead removed the user's own Azure OpenAI
provider/auth setup along with the file, producing a real chain of `401 Unauthorized` WebSocket
reconnect attempts against `api.openai.com` before failing outright. The config file was restored
immediately afterward and verified byte-for-byte identical via `diff` (exit 1, no differences) with
no leftover `.bak` file. No data was lost and no credential was exposed in this session's own output,
but this was an unnecessary risk for a question that, in the end, did not need answering — the actual
fix (§4, 10th item) only requires that this wrapper stop overriding the user's config, not that this
session know what Codex CLI's own true default value is. Flagged here as a genuine process lesson:
prefer read-only inspection over live-testing directly against a user's own configured environment
and credentials when a safer alternative exists (in this case, there was one — simply not probing
the "no config" case at all, since the fix doesn't depend on it).

## 8. Final state

- `bash codex-stream-review/tests/test-run-ccs-review.sh` — all fixtures pass.
- `bash codex-stream-review/tests/test-run-ccs-ci.sh` — all fixtures pass (this test file did not
  exist before this remediation pass; it was created in Group A specifically to close part of L-004).
- `python3 codex-stream-review/evals/lib/validate_interactive_result.py --selftest` — OK.
- `python3 codex-stream-review/scripts/validate_ci_result.py --selftest` — OK.
- `python3 codex-stream-review/scripts/collect_untracked_files.py --selftest` — OK, no leftover
  temp directories (confirmed before/after, and by reproducing the original CSR-007 leak on the
  pre-fix code for comparison).
- Capstone whole-diff `codex-stream-review:ccs` review: **CLEAN**, `material_reviewed:true`, all 7
  review dimensions checked, thread `01a0924a-480c-7e13-884e-014a39c5a2ee`.
- Group E's own dedicated review (the reasoning-effort fix, landed after the capstone's own CLEAN):
  **CLEAN**, `material_reviewed:true`, thread `01a092e0-2db1-7bb0-8671-86386f8706e5`.

This branch (`chore/ccs-version-bump-material-verification`) is ready for a pull request, pending
the user's decision on how to push/present it.

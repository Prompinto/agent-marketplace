# Snapshot integrity (always on, no opt-in) — reference

> Read this file in full: unlike `--capture-evidence`/`--keep-evidence`, this is not a flag a
> caller can turn off — it applies to every `codex-stream-review:ccs` invocation that gets past
> Phase 0's early-exit checks. Everything below is required for two later points in this run:
> the snapshot allocation (right after Phase 0 step 4 for a non-repo-artifact round, or right
> after Phase 1's "Determine review mode" sizing step for a repo-diff round) and the
> pre-dispatch revalidation check every round 2+ runs in `SKILL.md`'s Phase 1 Step 1.

## What this fixes

A `/ccs` run can span up to 20 rounds across many separately-dispatched tool calls, each a fresh
shell with no memory of prior state except literal facts Claude carries forward and files Claude
wrote under `/tmp` (`SESSION_ID`, `INSTALL_PATH`, `REPO_ROOT`, and now this file's own
`SNAPSHOT_FILE`/`SNAPSHOT_DIGEST`). Nothing before this feature ever re-checked that a
long-lived temp file survived the whole run intact — an accidental overwrite, a stray external
`/tmp` cleanup, disk pressure, or a Claude mistake targeting the wrong path could silently corrupt
or delete the record of what round 1 actually reviewed, with nothing catching it until (or unless)
a human happened to notice a later round's narration didn't match what they expected.

**This closes exactly one gap: corruption or deletion of Claude's own private local copy of the
reviewed subject.** It is explicitly **not** a defense against the live source (the real working
tree, the original ref, the original pasted text) legitimately changing mid-review — see "Not a
defense against a deliberately changed source" below for why that is an intentional non-goal, not
an oversight.

## Canonical subject (what gets hashed)

- **Repo-diff review** (`--uncommitted` / `--base <ref>` / `--commit <sha>`): the tracked-file
  diff bytes for whichever scope Phase 0 step 4 actually selected, collected via the exact same
  sanitized `git` invocation shape already established elsewhere in this file for that scope (same
  `-C "$REPO_ROOT"` anchor, `env -i`/`-c core.fsmonitor=` isolation — see "Determine review mode"
  in `SKILL.md`'s Phase 1) — never a separate, unaudited git call. Untracked files are represented
  by name only (`git ls-files --others --exclude-standard`), appended to the same snapshot file,
  not by their full content — a disclosed, deliberate simplification: this snapshot exists to
  detect corruption of Claude's own local record, not to serve as the actual payload sent to
  Codex (the wrapper's own internal collection, via `collect_untracked_files.py`, remains the
  sole source of truth for what Codex actually receives). A change to an untracked file's own
  content between rounds is therefore not caught by this mechanism — an accepted gap, since the
  wrapper never resends untracked content on a `--resume` round either, so there is nothing for
  round 2+ to silently drift against on that axis specifically.
- **Non-repo-artifact review**: the exact pasted artifact text that Phase 1 Step 0 (round 1) will
  embed into that round's `FOCUS_FILE` — captured into its own standalone snapshot file BEFORE the
  Why/Scope framing text is composed around it, so the hash covers only the reviewed artifact's
  own bytes, not Claude's own generated framing prose (framing text is regenerated fresh at round
  1 and is not itself part of "the reviewed subject").

## Allocation — once, before round 1 ever dispatches

**Repo-diff review:** immediately after Phase 1's "Determine review mode" sizing step computes its
file count. This is its own separately-dispatched call, so it re-establishes its OWN sanitization
from scratch (`GIT_BIN`, `SANITIZE_HOME`, the `unset` loop, and — for `--uncommitted` — its own
`DIFF_BASE` resolution) rather than assuming the sizing step's shell state survived — see
`SKILL.md`'s Phase 1 "Determine review mode" section for the exact, current, per-scope commands
(the canonical source; not reproduced a second time here to avoid the two ever drifting apart).
**Use exactly the one scope block matching whatever scope Phase 0 actually selected** —
`--uncommitted` (tracked diff via the re-derived `DIFF_BASE`, PLUS an appended untracked-file name
listing — the only scope that ever includes untracked files at all), `--base <ref>` (the three-dot
`"<ref>...HEAD"` diff, no untracked-name append), or `--commit <sha>` (mirroring the wrapper's own
merge-vs-non-merge `PARENT_COUNT` branch exactly, no untracked-name append) — never more than one
block, and never a block for a scope that wasn't chosen. **Check every collection command's own
exit status before ever recording a digest** — a failed `git`/`shasum` call is a hard stop for the
whole review, before round 1 ever dispatches; never let a partial or empty snapshot get "success-
fully" hashed and carried forward as if it were the real subject.

**Non-repo-artifact review:** immediately after Phase 0 step 4 finalizes the pasted artifact text
(before Phase 1 ever composes round 1's own `FOCUS_FILE` around it), write that exact text via the
Write tool into a `mktemp`'d `SNAPSHOT_FILE`, then hash it the same way — validating the result
before trusting it, exactly like the repo-diff allocation above:

```bash
SNAPSHOT_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-snapshot.bin.XXXXXX")
# (content written via the Write tool, not a shell redirect — same reasoning as FOCUS_FILE's own
# sentinel-idiom section: Claude does not fully control this text character-by-character)
SNAPSHOT_DIGEST="$(shasum -a 256 "$SNAPSHOT_FILE" | awk '{print $1}')"
# A pipe's own exit status reflects its LAST command (awk), never shasum's -- a shasum that failed
# to read SNAPSHOT_FILE would leave SNAPSHOT_DIGEST empty without tripping any exit-code check.
# Validate the VALUE itself: a real sha256 digest is always exactly 64 lowercase hex characters.
if ! printf '%s' "$SNAPSHOT_DIGEST" | grep -qE '^[0-9a-f]{64}$'; then
  echo "snapshot hashing failed -- stop here, do not dispatch round 1" >&2
  rm -f "$SNAPSHOT_FILE" "<literal REPO_ROOT_FILE>" "<literal INSTALL_PATH_FILE>"
  exit 1
fi
echo "SNAPSHOT_FILE=$SNAPSHOT_FILE"
echo "SNAPSHOT_DIGEST=$SNAPSHOT_DIGEST"
```

**Why `shasum -a 256`, not `sha256sum`:** `shasum` ships by default on macOS (bundled with the
system Perl) as well as on essentially every Linux distribution; `sha256sum` alone is not
guaranteed present on macOS. Using `shasum -a 256` everywhere keeps this file portable across the
environments this skill actually runs in, without needing a fallback-detection branch.

**`SNAPSHOT_DIGEST` needs no sentinel-file idiom.** A `shasum` digest is a fixed-length hex string
with no embedded whitespace, quote, or newline — none of the character-level risk the sentinel
idiom exists to guard against (see `SKILL.md`'s "Sentinel-file safe-read idiom" section). Remember
it directly as a literal string, the same way `SESSION_ID` already is.

**`SNAPSHOT_FILE` is session-scoped, not round-scoped** — allocated once, remembered for the whole
run exactly like `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`, and removed only at Phase 3 (see "Cleanup"
below) — never touched by Phase 2's own per-round temp-file cleanup (which only ever removes that
round's `.pid`/`-out.json`/`-err.log`/`-focus.txt`/eventlog/last-message files, never a
session-scoped fact).

## Revalidation — every round 2+, once per round, before that round's dispatch ever runs

A single canonical subject serves every group in a parallel round (every group reviews the
identical diff — see "Determine review mode" in `SKILL.md`'s Phase 1) — so this check runs
**once per round**, never once per group, and gates every group's dispatch that round together:

```bash
SNAPSHOT_FILE="<literal from allocation above>"
SNAPSHOT_DIGEST="<literal from allocation above>"
if [ ! -f "$SNAPSHOT_FILE" ] || [ "$(shasum -a 256 "$SNAPSHOT_FILE" | awk '{print $1}')" != "$SNAPSHOT_DIGEST" ]; then
  echo "SNAPSHOT_INTEGRITY_FAILURE"
else
  echo "SNAPSHOT_INTEGRITY_OK"
fi
```

Run this as its own small check-and-branch call, distinct from the round's actual `--resume`
dispatch — never merge the two into one command, so a caught failure can short-circuit **before**
any `--resume` call is ever issued that round. Round 1 never runs this check (there is nothing yet
to revalidate against — the snapshot IS round 1's own baseline).

## On failure (missing file OR hash mismatch)

Claude's own copy of the reviewed subject can no longer be trusted for continued use in this run —
no distinction is drawn between "corrupted" and "deleted," both mean the same thing here, and no
partial-content salvage is attempted.

1. **Do not dispatch any `--resume` call this round**, for any group.
2. **Report a new terminal status, `🛑 SNAPSHOT INTEGRITY FAILURE`** — distinct from every
   convergence-loop outcome (`✅ CLEAN`/`⚠️ NOT CONVERGED`/`⚠️ COULD NOT VERIFY`/
   `⚠️ PARTIAL COVERAGE`/`🟡 MINOR ISSUES ACKNOWLEDGED`). This is a Claude-side infrastructure
   failure, not a review-convergence
   outcome, and is never folded into any of those five.
3. **Run Phase 3 steps 1–3 exactly as for any other terminal path — unconditionally, even if
   `--keep-evidence` is ON for this session.** This is the one deliberate exception to the
   keep-evidence gate (see `SKILL.md`'s Phase 3): a normal non-CLEAN outcome under
   `--keep-evidence` keeps threads alive because their history still describes a trustworthy
   record of the reviewed subject; a snapshot integrity failure means that trust itself is gone
   — the existing threads' history can no longer be vouched for as describing the subject Claude
   thinks it does, so resuming or inspecting them later would be building on an already-unreliable
   foundation. Clean them up the same as a CLEAN outcome would.
4. **Remove `$SNAPSHOT_FILE` itself** as part of Phase 3 step 3's session-level temp-file cleanup
   (alongside `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`/`CLEAN_REPO_DIR`/`FAKE_GIT_HOME`).
5. **Tell the user plainly, in the Phase 3 final report**, that the review subject's local record
   could not be re-verified mid-run and a fresh `codex-stream-review:ccs` invocation is required to
   review the target's current state. Never silently start a new review on the user's behalf —
   Claude does not know whether the user wants the exact same target re-reviewed, a different one,
   or nothing further right now.

## Compaction-only exception (`--compact`, opt-in — see `references/compaction.md`)

The "one canonical subject, session-scoped, NEVER changed per round" invariant stated everywhere
above holds UNCHANGED for every ordinary session. It is relaxed ONLY when `--compact` is ON for
this session AND triggers a fully-specified, Claude-orchestrated, fully-disclosed re-snapshot-
and-promote event — never by anything auto-detected, and never for any other reason. In that one
case: a NEW candidate `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` is collected, verified, and atomically
promoted onto the SAME fixed `SNAPSHOT_FILE` path (the path itself never changes — only its
content, and the remembered `SNAPSHOT_DIGEST`, advance together), and the round that performs
this promotion durably records `snapshot_digest_before`/`snapshot_digest_after` as an audit
trail. See `references/compaction.md`'s "Restart mechanism" and "Ordering on success" sections
for the complete, fully-specified mechanics — this file's own revalidation logic (above) and
hard-stop-on-mismatch behavior are otherwise entirely unaffected: a session with `--compact` OFF,
or one where `--compact` is ON but never actually triggers, behaves exactly as documented
everywhere else in this file, with zero difference from before this exception existed.

## Not a defense against a deliberately changed source

By design, revalidation never re-observes the real working tree, the original ref, or the
original pasted text — only Claude's own already-collected `$SNAPSHOT_FILE`. A repo diff that
legitimately changes mid-review (the user commits more work while `/ccs` is still running) is
invisible to this check as long as `$SNAPSHOT_FILE` itself stays intact on disk — that scenario is
an explicit non-goal, not a gap this mechanism is meant to close: reviewing a genuinely changed
artifact/diff requires an entirely new `/ccs` invocation (new session id, new threads), never
something a running review auto-detects and pivots on mid-flight. Folding live-source
change-detection into this same mechanism was considered and rejected during this feature's own
design negotiation — it would require re-observing the live source every round (re-introducing the
per-round diff-recollection cost this design was built to avoid) and would conflate two genuinely
different failure classes (Claude's local copy going bad vs. the reviewed subject legitimately
moving on) under one signal.

## Interaction with `--capture-evidence` / `--keep-evidence`

Fully independent of both. `SNAPSHOT_FILE` holds the reviewed subject's own bytes — never Codex's
investigation commands (`--capture-evidence`'s domain) or a failed round's last-message output
(`--keep-evidence`'s domain). All three may be allocated in the same session with no interaction
between them beyond sharing the same `SESSION_ID` prefix convention in their temp-file names.

## Cleanup

`$SNAPSHOT_FILE` is removed at Phase 3 step 3 (session-level temp-file cleanup) on **every**
terminal path, including the failure path above and including a `--keep-evidence` non-CLEAN
outcome that otherwise leaves threads alive — a snapshot integrity failure removes it as part of
that failure's own cleanup (point 4 above); every other terminal path removes it as one more
`rm -f` alongside `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`.

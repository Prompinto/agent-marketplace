# Kept evidence on failure — reference

> Read this file in full because `--keep-evidence` was determined ON for this session (see
> `SKILL.md`'s Phase 0 Step 0). Everything below is required for four later points in this run:
> Phase 1 Step 0's `LAST_MESSAGE_KEEP_FILE` allocation, Step 1's `--keep-last-message` flag, Phase
> 2's keep-or-delete step, and Phase 3's conditional cleanup-skip in `SKILL.md`.

## Kept evidence on failure (opt-in via `--keep-evidence`)

**Off by default.** A normal `codex-stream-review:ccs <task description>` invocation (no
`--keep-evidence` prefix) never touches anything in this section — no extra dispatch flag, no
extra JSONL field, no change to Phase 3's cleanup behavior. Independent of `--capture-evidence`
(see `SKILL.md`'s Phase 0 Step 0 for the shared prefix-parsing loop) — either, both, or neither may
be ON for a session.

**What turns it on:** the one-time Phase 0 Step 0 decision in `SKILL.md`.

**What it fixes:** `/ccs` normally runs `--cleanup` on every Codex thread on every terminal path,
including a failure (`⚠️ COULD NOT VERIFY`, `⚠️ NOT CONVERGED`, `⚠️ PARTIAL COVERAGE`) — deleting
the one diagnostic artifact (the model's actual last-message output, and the live thread itself)
that would explain what went wrong on an `invalid_json`/`schema_mismatch`/`no_final_answer`/etc.
failure. `--keep-evidence` makes retention of a failed round's thread and last-message output an
explicit opt-in, never the unconditional default.

**Two things get retained on a non-CLEAN outcome, both covered below:** (1) each failed round's own
kept last-message text, moved into a durable per-session directory; (2) every Codex thread that
would otherwise have been `--cleanup`'d, left alive instead (`SKILL.md`'s Phase 3 keep-evidence
gate — see that section, not repeated here). **This applies to `⚠️ COULD NOT VERIFY`/
`⚠️ NOT CONVERGED`/`⚠️ PARTIAL COVERAGE` only — never to `🛑 SNAPSHOT INTEGRITY FAILURE` or
`🛑 REVIEW LOG INTEGRITY FAILURE`**, both of which
always clean up regardless of `--keep-evidence` (see `references/snapshot-integrity.md`,
`SKILL.md`'s "Review history log" section, and `SKILL.md`'s Phase 3 keep-evidence gate for why:
either status means Claude's own local record of the
reviewed subject or its review history can no longer be trusted, so the threads' history can no
longer be vouched for
either — retaining them would build on an already-unreliable foundation, not preserve a
trustworthy one).

**Reuses the existing review-history JSONL log — no second manifest file.** The log already
records every round's outcome, including `codex_review.ok:false` + `reason` + `thread_id`; the
only new information this feature adds is WHERE a kept last-message file lives, if one was kept for
that round — a single new optional field on the existing per-round log line (see "JSONL field:
`kept_last_message_path`" below).

## Directory and file naming

**Directory:** `~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>-kept-evidence/`
— the same `<repo-slug>`/`<session-id>` naming `SKILL.md`'s own "Review history log" section already
uses for that session's `.jsonl` file, just a sibling directory with a `-kept-evidence` suffix
instead of a `.jsonl` extension. Owner-only, same discipline as the existing log directory:
```bash
umask 077 && mkdir -p ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>-kept-evidence
```
**Created lazily** — only the first time a round in this session actually needs to keep a file (a
group's round genuinely failed). Most sessions that run with `--keep-evidence` ON still converge
`✅ CLEAN` and never create this directory at all.

**File naming:** `round-<R>-<GROUP>-lastmsg.txt` inside that directory — e.g.
`round-3-main-lastmsg.txt` for the common single-reviewer case, or `round-2-g1-lastmsg.txt` for a
parallel round's `g1` group.

## Per-round mechanics

**Phase 1 Step 0 (temp-file allocation).** When `KEEP_EVIDENCE` is ON, allocate one additional
`mktemp`'d temp file per dispatched group this round — `LAST_MESSAGE_KEEP_FILE` — same
naming-template discipline as `PID_FILE`/`OUT_FILE`/`ERR_FILE`/`FOCUS_FILE` (session+round+group
baked into the template):
```bash
LAST_MESSAGE_KEEP_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-round-<R>-${GROUP}-lastmsg.txt.XXXXXX")
echo "LAST_MESSAGE_KEEP_FILE=$LAST_MESSAGE_KEEP_FILE"
```
This is a TEMPORARY scratch location only — its content is moved into the durable directory above
ONLY if this group's round actually failed (see Phase 2 below); on success it is simply deleted.

**Phase 1 Step 1 (dispatch).** When `KEEP_EVIDENCE` is ON, add
`--keep-last-message "<this group's literal LAST_MESSAGE_KEEP_FILE path from Step 0>"` as literal
text on BOTH the fresh and resume dispatch command forms — mirror exactly how
`--capture-eventlog`'s own conditional inclusion is written in `SKILL.md`'s Phase 1 Step 1 (same
"Claude already knows the on/off decision, write the concrete literal branch by hand every round"
discipline). When OFF, omit the flag entirely, same as `--capture-eventlog`'s own off-branch.

**Phase 2 (after parsing this round's result — the same step where the round gets logged to the
JSONL and its round-scoped temp files get cleaned up):**
- If `KEEP_EVIDENCE` is ON and this group's round **succeeded** (`ok:true`): delete
  `LAST_MESSAGE_KEEP_FILE` (`rm -f`) — nothing to keep, the parsed `verdict` in the JSON response
  already has everything useful.
- If `KEEP_EVIDENCE` is ON and this group's round **FAILED** (`ok:false`, any reason): lazily
  create the `<session-id>-kept-evidence` directory if it doesn't exist yet (owner-only, as above),
  then `mv` (not copy — it's a temp file, no need to keep two copies) `LAST_MESSAGE_KEEP_FILE` to
  `<that directory>/round-<R>-<GROUP>-lastmsg.txt`. **Best-effort:** if the move fails for any
  reason, note it once and move on — never abort the round. This is a DIFFERENT, still-best-effort
  operation from the JSONL append itself (which now requires a hard-stop `🛑 REVIEW LOG INTEGRITY
  FAILURE` on a failed write — see `SKILL.md`'s "Review history log" → "Write"/"Failure isolation"
  sections) — losing a kept-evidence file is a diagnostics-quality loss, never a correctness risk
  to the claim ledger the way a silently-dropped JSONL line would be, so it keeps the softer
  best-effort handling on its own merits, not by analogy to a rule that no longer applies to the
  log itself.
- Add the resulting durable path (only when a file was actually kept) as a new optional field on
  that round's own JSONL log line: `"kept_last_message_path": "<the durable path>"`. Omitted
  entirely when `KEEP_EVIDENCE` was OFF, the round succeeded, or the move failed. For a parallel
  round, this field lives inside that group's own entry in `groups[]` (see
  `references/parallel-mode.md`'s "JSONL field: `groups`" section for the full `groups[]` schema),
  never at the top level — mirroring exactly how that same section already nests `thread_id` per
  group for a parallel round, versus top-level for the single-reviewer case (see "JSONL field:
  `kept_last_message_path`" below for both shapes).

**Phase 3 (terminal path) — the actual cleanup-skip.** `SKILL.md`'s own Phase 3 has a
"Keep-evidence gate" immediately before its step 1: when `KEEP_EVIDENCE` is ON for this session AND
the run's final terminal status is NOT `✅ CLEAN` AND NOT `🛑 SNAPSHOT INTEGRITY FAILURE` AND NOT
`🛑 REVIEW LOG INTEGRITY FAILURE`, steps 1
and 2 (the `GROUP_THREADS` `--cleanup` loop and the `LEAKED_THREAD_IDS` `--cleanup` loop) are
skipped entirely — every thread is left alive so a human can `--resume` it manually later to keep
investigating, or inspect it directly. When `KEEP_EVIDENCE` is OFF, the outcome IS `✅ CLEAN`, OR
the outcome IS `🛑 SNAPSHOT INTEGRITY FAILURE` or `🛑 REVIEW LOG INTEGRITY FAILURE` (see
`references/snapshot-integrity.md` and `SKILL.md`'s "Review history log" section for why either
status is never eligible for this skip, regardless of `KEEP_EVIDENCE`), behavior is unchanged
from before this feature existed: always cleanup. This is a conditional gate on those two existing
steps, not a duplicate of them — see `SKILL.md`'s Phase 3 for the actual gate text and the two
steps it guards.

**Final report.** When `KEEP_EVIDENCE` was ON and the outcome was non-CLEAN **AND NEITHER
`🛑 SNAPSHOT INTEGRITY FAILURE` NOR `🛑 REVIEW LOG INTEGRITY FAILURE`**, `SKILL.md`'s own Final-report "Thread cleanup results" bullet
requires: an explicit statement that cleanup was intentionally skipped due to `--keep-evidence`;
every thread ID left alive (per group); every kept last-message file's durable path (per
round/group that actually kept one, read back from the JSONL log); the exact manual commands to
inspect or clean up later (`cat <path>` to read the retained output,
`"$INSTALL_PATH/scripts/run-ccs-review.sh" --cleanup "<threadId>"` to delete a thread once done
investigating); and a one-line note that kept-evidence directories are auto-pruned after roughly
30 days if never manually cleaned up (matching Phase 0 Step 0's own pruning sweep). **For either
`🛑` status specifically — regardless of `KEEP_EVIDENCE`** — none of the above
applies: cleanup ran unconditionally for both (see `references/snapshot-integrity.md` and
`SKILL.md`'s "Review history log" section), so
the final report states a normal cleanup outcome instead, never "threads left alive." See
`SKILL.md`'s Final report section for exactly where this plugs in.

**Failure isolation:** exactly the same best-effort discipline as the rest of this log — a failed
directory creation, a failed `mv`, or any other error in this section's mechanics must never abort
or degrade the review round. Note it once in that round's narration and continue with
`kept_last_message_path` simply omitted from that round's line (or entry).

---

## JSONL field: `kept_last_message_path`

**With `--keep-evidence` ON and a group's round having actually failed and kept a file**, that
round's log line gains one more field: `kept_last_message_path`, holding the durable path from
"Directory and file naming" above.

**Single-reviewer round (`GROUP="main"`) — top-level field**, the same nesting level as the
existing top-level `thread_id` field (see `SKILL.md`'s "Review history log" section):
```json
{
  "session_id": "2026-09-05T090000-12345",
  "round": 3,
  "ts": "2026-09-05T09:05:00+09:00",
  "thread_id": "<this round's own threadId>",
  "kept_last_message_path": "~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>-kept-evidence/round-3-main-lastmsg.txt",
  "target": {"repo": "<repo root>", "scope": "resume", "focus": "<the focus text sent this round>"},
  "codex_review": {"ok": false, "reason": "schema_mismatch", "detail": "..."},
  "round_outcome": "not_converged"
}
```
(shown here as a full illustrative line; in an actual log line every other field documented in
`SKILL.md`'s own "Review history log" section is still present exactly as described there — this
example only highlights where the new field sits.)

**Parallel round — inside that group's own `groups[]` entry**, a sibling of that entry's own
`thread_id`/`focus`/`codex_review` keys (see `references/parallel-mode.md`'s "JSONL field:
`groups`" section for the full existing `groups[]` schema this nests into — reproduced here only
for the one entry that actually kept a file, per that file's own exact shape):
```json
{"group": "g3", "thread_id": "<g3's own threadId, if one was ever obtained>", "focus": "<g3's exact --focus text>", "codex_review": {"ok": false, "reason": "timeout", "detail": "..."}, "kept_last_message_path": "~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>-kept-evidence/round-2-g3-lastmsg.txt"}
```
A group whose round succeeded, or whose failed round's move itself failed, has no
`kept_last_message_path` key in its `groups[]` entry at all — never an empty-string placeholder.

Omitted entirely — never an empty-string placeholder — whenever `--keep-evidence` was OFF for the
session, the group's round succeeded, or the best-effort `mv` itself failed, so a plain
`jq 'has("kept_last_message_path")' `/`jq '.groups[] | has("kept_last_message_path")'` reliably
tells whether a durable file actually exists for that round/group.

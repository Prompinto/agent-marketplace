# Defect-class sweep (always on, no opt-in) — reference

> Read this file in full: like "Snapshot integrity" and "Claim ledger," this is not a flag — it
> applies to every `codex-stream-review:ccs` invocation that gets past Phase 0's early-exit checks.
> Everything below is required at four later points in this run: Phase 2 step 3's verification pass
> (running the sweep and/or parsing a `SWEEP_VERIFIED` marker), Phase 2's JSONL line construction
> (`defect_class_sweeps[]`), Phase 1 Step 0's round-2+ History construction (requesting
> `SWEEP_VERIFIED` confirmations on still-open sweeps), and the Guards section's CLEAN gate.

## What this fixes

A confirmed defect is often not a one-off — it is an instance of a repeatable **class** (the same
missing-null-check, the same off-by-one, the same copy-pasted anti-pattern) that recurs elsewhere in
the repository, outside the current diff/focus. Neither `build_review_prompt()`'s own
narrow→wide→narrow instruction nor `SKILL.md`'s own whole-flow re-check previously asked either
side to treat a confirmed defect as a class and grep the rest of the repository for other instances
of it — both stopped at the diff's own immediate siblings.

This mechanism converged over 16 real `codex-stream-review:ccs` review rounds (see
`docs/2026-09-19-ccs-defect-class-sweep-design.md` for the full history) — every mechanism it once
tried and abandoned (a hand-rolled wall-clock watchdog, a per-file match cap, four successive
origin-site-recognition schemes) is recorded there as a design lesson, not repeated here. What
follows is only the converged, CLEAN-verified design.

## 1. Codex-side prompt expansion (trusted zone, `build_review_prompt()`)

Already implemented in `scripts/run-ccs-review.sh`: the narrow→wide→narrow paragraph's own bulleted
list includes an instruction that if a finding looks like an instance of a repeatable defect class,
Codex must grep the rest of the repository for other occurrences of that same pattern before
reporting, and state in the finding's `verification` field exactly what it grepped for and what it
found — never state or imply a pattern is "likely present elsewhere" without having actually
grepped for it.

## 2. Claude-side whole-flow re-check expansion

Already implemented in `SKILL.md`'s Phase 2 step 4: after the existing sibling-path check, for any
VALID/PARTIAL finding just fixed, Claude judges whether it reads as a repeatable defect class
(disclosing that judgment either way, in `claude_verification[].rationale` — never a silent
default). If class-like, Claude actually runs the grep (the literal command, not a description).

**Origin-site recognition — a two-step process, both steps required:**
1. **Coordinate pre-screen (cheap, may over-select):** a raw candidate whose `file`/`line` falls
   within the line range Claude's own edit touched this round is flagged as a LIKELY origin match.
   This step only avoids wasting a read on candidates obviously unrelated to the edit — it never
   makes the final call.
2. **Confirmation read (authoritative, mandatory for every flagged candidate):** Claude reads that
   candidate's actual surrounding code and determines whether it is literally the fix just applied
   or a distinct occurrence. This closes the structural ceiling coordinates alone can never resolve
   — `grep -n`'s own output is line-granular, so a single line can contain more than one genuine
   occurrence, at most one of which is the origin (e.g. `unsafeCall(a); unsafeCall(b);` on one
   line). A candidate the pre-screen does NOT flag proceeds through ORDINARY confirmation exactly
   like any other raw candidate — nothing is ever excluded from consideration without a read.

Never pre-filter the origin out of the search stream before this recognition runs — the search
command (section 6 below) has no exclusion stage at all. `other_candidates_found` is therefore the
TOTAL raw hit count, unconditionally; `other_occurrences_confirmed` is the subset confirmed, during
this two-step process, to be genuine OTHER occurrences (never equal to `other_candidates_found`
whenever any candidate was the origin itself, a false-positive textual match, or an already-safe
call site).

## 3. Scope-expansion guard

- **Under the cap** (at most 5 confirmed occurrences OTHER than the origin, all within the origin's
  own directory): fix them in the same round, same as any other whole-flow re-check finding.
  `scope_decision: "not_applicable"` (no disclosure was ever needed).
- **Over the cap on either axis:** do not silently expand scope. Disclose the pattern, confirmed
  count, and locations to the user and ask whether fixing them all now is in scope — the same
  disclose-then-ask discipline `SKILL.md`'s own `⚠️ PARTIAL COVERAGE` gate already uses for an
  unrelated swept-in file. Record `scope_decision: "pending_scope"` — a hard stop for THAT sweep's
  own further fixing this round, and a session-wide CLEAN blocker (see the Guards section below)
  until the user answers.
- **`search_truncated: true` (section 6's own `MAX_CANDIDATE_FILES` cap was hit) unconditionally
  forces `scope_decision: "pending_scope"`, even when the CONFIRMED count so far is under the
  5-occurrence/same-directory cap.** A truncated raw hit list has no complete confirmed count to
  check against either axis of the "under the cap" rule above — reporting `"not_applicable"` from
  a truncated search would assert completeness the search never actually established (see the
  disclosure text below for exactly what to tell the user, since the confirmed-occurrence count
  itself is unknown at truncation, not a number to guess at). This is a separate, independent
  trigger for `"pending_scope"` from the over-the-cap case above — either condition alone is
  sufficient, and either can apply even when the other does not (e.g. a truncated search whose
  first 20 raw hits happen to confirm to only 2 real occurrences still forces `"pending_scope"`,
  because hits beyond the cap remain totally unexamined). When disclosing to the user, state the
  fact of truncation itself, never a confirmed-occurrence count you do not have — e.g. "grep for
  `<pattern>` found more than 20 raw matches; stopped before confirming every one to avoid
  scanning further without your input — how would you like to proceed?"
- **`"pending_scope"` → `"approved"` — exactly ONE path, unconditional, no exceptions:** re-run the
  search WITHOUT the `MAX_CANDIDATE_FILES` cap (the user's own approval is the explicit
  authorization the cap exists to require before an uncapped scan runs), THEN run the two-step
  recognition process over every result, THEN re-apply the 5-occurrence/same-directory check
  against the now-complete confirmed count (this can legitimately re-trigger `"pending_scope"`
  again if the uncapped search reveals a genuinely enormous count — never assumed away). Only once
  a genuinely complete confirmed count exists does `scope_decision` become `"approved"` — never a
  bare state-flip with stale or placeholder counts.
- **`"pending_scope"` → `"rejected"`:** user declines; only the original in-scope occurrence(s) are
  fixed.
- **A genuine search command failure** (grep exit status `2`+, distinct from an empty or capped
  result) sets `scope_decision: "pending_error"` instead — a search-health question, never a
  scope-authorization one, so user approval cannot resolve it. Its own recovery is a genuine RETRY:
  correct the underlying problem (invalid pattern, permission issue, transient failure) and re-run
  the search from scratch, producing a new `defect_class_sweeps[]` entry for the same `sweep_id`.
  Never a state-flip to `"approved"`/`"rejected"` — those remain reserved for the scope-
  authorization question `"pending_scope"` poses, which a search failure never actually asks.

Both `"pending_scope"` and `"pending_error"` block session-wide CLEAN (see the Guards section
below) — a reducer/CLEAN-gate rule blocking on "any `scope_decision` value starting with
`pending_`" covers both without enumerating them separately.

## 4. Cross-round independent re-verification (anti-collusion)

Already implemented in `scripts/run-ccs-review.sh`'s trusted prompt template: if the untrusted
Context section reports a defect-class sweep from a prior round (naming the pattern, the recorded
origin line range(s) — plural whenever a deduplicated sweep's `origin_site` carries more than one
element, see section 5 — and the fixed count), Codex must independently re-grep for that same
pattern using its own read-only shell access before responding, check whether any of its own raw
hits fall within ANY of the reported origin ranges, and state in its `summary` field, in exactly
this form:

```
SWEEP_VERIFIED <sweep_id>: CONFIRMED -- <what you found>
SWEEP_VERIFIED <sweep_id>: DISPUTED -- <what you found instead, including which specific hit you believe was mis-excluded>
```

Only WHICH `sweep_id`(s) to ask about — and the sweep's own recorded pattern/origin-range/count —
live in the untrusted `--focus`/Context text (ordinary scope guidance); the obligation to respond,
and the exact grammar, are fixed in the trusted zone, mirroring `references/claim-ledger.md`'s own
`DISPOSITION` marker mechanism exactly (this anchoring distinction is why an obligation meant to
bind Codex's own behavior must never live only in caller-supplied `--focus` text).

**`reverify_status`** — exactly one of `"unverified"` (default; FULL QUORUM on a valid
`CONFIRMED` marker has not yet been reached — this covers BOTH "no dispatched group has responded
validly yet" AND, in parallel mode, "at least one dispatched group DID validly confirm this round,
but at least one OTHER dispatched group's own marker is still missing/malformed, so quorum isn't
met" — see the full-quorum paragraph immediately below for why these two cases are the same
outcome, never two different states), `"confirmed"` (full quorum reached — see below), or
`"disputed"` (a valid `DISPUTED` marker was received FROM ANY ONE dispatched group this round —
no quorum requirement on this direction, since a single credible dispute is sufficient reason to
keep looking). Reconstructed via the same per-field reducer section 5 establishes for
`scope_decision`.

**`"confirmed"` has a FULL-QUORUM requirement, in parallel mode specifically — the single-
reviewer case (`GROUP="main"`) trivially satisfies it, since there is only ever one dispatched
group to require agreement from.** In a round dispatching more than one group, EVERY dispatched
group must return a valid `CONFIRMED` marker for that `sweep_id` this round before
`reverify_status` may transition to `"confirmed"` — a marker missing/malformed from even ONE
dispatched group means NO entry is written for that `sweep_id` at all this round (mirroring the
single-reviewer missing-marker rule exactly, just applied group-by-group), so `reverify_status`
carries forward unchanged rather than advancing on a MINORITY of dispatched groups' own agreement.
This is necessary because the per-field reducer (section 5 below) merges status-only entries by
"most recent value wins," with no concept of "how many groups agreed" — a single dispatched
group's own valid `CONFIRMED` status-only entry, written alone with no signal that other groups
were even asked, is otherwise structurally indistinguishable from a unanimous one. Full mechanics,
including why this quorum requirement applies ONLY to `"confirmed"` and never to `"disputed"`, are
in `SKILL.md`'s own Phase 2 step 3 parallel-mode conflict rule — this reference states the
requirement here so this field's own top-level state-machine definition is not, on its own,
internally inconsistent with that rule.

**Selection rule:** request `SWEEP_VERIFIED` for EVERY `sweep_id` whose CURRENT `reverify_status`
is `"unverified"` OR `"disputed"`, every round, until it becomes `"confirmed"` — never limited to
"immediately preceding round" (a one-shot request silently drops a sweep forever the first time a
round passes with no valid marker). The requesting round's History text must include that
`sweep_id`'s own recorded `grep_command`, `origin_site` (every line range in the array, not just the
first), and count — persisting the range in JSONL alone is not sufficient; it must actually be
copied into the Context payload, or
Codex has nothing to check its own hits against despite the obligation asking it to.

**`"disputed"` is never a dead end:** it is re-selected every round exactly like `"unverified"`
until `"confirmed"`. The marker's own `<what you found instead>` text is treated as an ordinary
Codex finding, flowing through the SAME accept/rebut cycle (Phase 2 steps 2-3) any other finding
already goes through — an accepted dispute produces a new sweep entry (a new `source_round`, same
`sweep_id`) whose own next-round verification can then reach `"confirmed"`; a rebutted dispute lets
Codex's own next (re-requested) `SWEEP_VERIFIED` response return `CONFIRMED` instead of repeating
`DISPUTED`.

## 5. JSONL field: `defect_class_sweeps[]`

A new, always-optional, additive round-level field, top-level even in parallel mode (matching
`claim_closures[]`'s existing precedent, since `finding_id`s are already group-namespaced).

**Presence rule:** present on a round where EITHER a finding was judged class-like and swept (a
FULL entry, every field below) OR a validated `SWEEP_VERIFIED` marker was received for an existing
`sweep_id` with no accompanying fresh sweep that round (a STATUS-ONLY entry, carrying `sweep_id`
plus only whichever of `scope_decision`/`reverify_status` actually transitioned — both,
independently, or neither field beyond `sweep_id` itself, depending on what changed). **For a
`reverify_status` transition to `"confirmed"` specifically, in a parallel round dispatching more
than one group: this presence condition is met only once EVERY dispatched group's own valid
`CONFIRMED` marker for that `sweep_id` has arrived — never a single dispatched group's own marker
alone** (see the full-quorum requirement in section 4 above). A transition to `"disputed"` has no
such requirement — a single dispatched group's own valid `DISPUTED` marker satisfies this presence
condition immediately.

Full entry shape:
```json
{
  "sweep_id": "g1:f3",
  "finding_ids": ["g1:f3"],
  "source_round": 3,
  "grep_command": "grep -rn 'parsedConfig\\.value' src/",
  "origin_site": ["src/config/loader.ts:42-42"],
  "search_error": null,
  "search_truncated": false,
  "other_candidates_found": 5,
  "other_occurrences_confirmed": 4,
  "sites_fixed_this_round": 4,
  "scope_decision": "not_applicable",
  "reverify_status": "unverified"
}
```

Status-only entry shapes (either or both fields, never a fresh full entry):
```json
{"sweep_id": "g1:f3", "reverify_status": "confirmed"}
{"sweep_id": "g1:f4", "scope_decision": "rejected"}
```

Field definitions:
- `sweep_id`: a stable identifier, following the same convention `claim-ledger.md` section 1
  establishes for `claim_id` — equal to the ORIGINATING finding's own `finding_id`
  (group-namespaced in parallel mode) for a sweep's first appearance.
- `finding_ids`: an array (never a bare scalar) — for parallel-mode deduplication, when more than
  one group's own confirmed class-like finding triggers the same sweep independently in the same
  round (every dispatched group reviews the identical full diff — see `references/
  parallel-mode.md`); deduplicate by `(grep_command, scope)` before running the search a second
  time for what is actually the same sweep, tagging every contributing group's own `finding_id` in
  this array. A single-reviewer round, or a parallel round where only one group's finding
  triggered this sweep, is a one-element array — never a bare string.
- `source_round`: the round number this entry was recorded on — same traceability purpose
  `claim_closures[].source_round` already provides, and the input to section 4's own selection rule
  (which sweeps are recent enough to still need a re-verification request is derived from the
  reducer's own current state, not from this field directly, but it remains useful for audit).
- `grep_command`: the LITERAL command/pattern actually run — always a runnable command or exact
  search string, reproducible independently, never prose describing the bug.
- `origin_site`: an array of line ranges (never a bare scalar), index-aligned with `finding_ids` —
  each element is the actual line range Claude's own edit modified this round for the
  correspondingly-indexed `finding_id`, as `"<file>:<start_line>-<end_line>"`. This is an array,
  not a single scalar, because a deduplicated parallel-mode sweep (see `finding_ids` above) can
  merge findings from different groups that were each fixed at genuinely DIFFERENT edit sites —
  the same `grep_command`/scope pair does not imply the same origin location, so collapsing to one
  scalar would silently discard whichever contributing group's own origin range didn't win. A
  single-reviewer round, or a parallel round where only one group's finding triggered this sweep,
  is a one-element array, index-0 corresponding to `finding_ids[0]` — never a bare string.
  Informational/diagnostic and the payload section 4's own independent re-verification checks every
  element against; never itself the recognition mechanism (see section 2 above — recognition is a
  two-step read-based process, not a coordinate comparison).
- `search_error`: `null` for an ordinary search attempt (whether it completed cleanly or was
  truncated), or a short string describing the actual stderr diagnostic when the search command
  itself failed (grep exit status `2`+). A non-null value sets `scope_decision: "pending_error"`.
- `search_truncated`: a boolean — `true` only when the bounded search (section 6) hit its own
  `MAX_CANDIDATE_FILES` result-count cap before completing. When `true`,
  `other_candidates_found`/`other_occurrences_confirmed` are known LOWER BOUNDS, not exact counts,
  and `scope_decision` MUST be `"pending_scope"` regardless of how small the confirmed-so-far count
  is (see section 3's own truncation rule) — never `"not_applicable"` from a truncated search.
- `other_candidates_found`: the TOTAL raw grep hit count, unconditionally — including the origin's
  own raw hit, since nothing is ever excluded from the search stream before the cap (see section 2).
- `other_occurrences_confirmed`: the count of candidates CONFIRMED, during the two-step recognition
  process, to be genuine OTHER occurrences (never equal to `other_candidates_found` when any
  candidate was the origin, a false-positive textual match, or an already-safe call site).
- `sites_fixed_this_round`: how many of `other_occurrences_confirmed` were actually fixed this round
  (less than `other_occurrences_confirmed` only when `scope_decision` is `"pending_scope"`,
  `"pending_error"`, or `"rejected"`).
- `scope_decision`: exactly one of `"not_applicable"`, `"pending_scope"`, `"pending_error"`,
  `"approved"`, or `"rejected"` — see section 3 above for the full state machine.
- `reverify_status`: exactly one of `"unverified"`, `"confirmed"`, or `"disputed"` — see section 4
  above.

No `schema_version` bump — purely additive, same policy `claim-ledger.md` section 10 already
establishes for fields that don't change how existing lines are interpreted.

**Reducer (per-field, not per-whole-record):** to reconstruct a sweep's current state at the start
of any round, scan every prior round's `defect_class_sweeps[]` entries for this `sweep_id`; for EACH
field independently, its current value is whatever the MOST RECENT entry that actually SET that
field contains — a status-only entry sets only the field(s) it carries, leaving every other field
at its own most recent full-or-status-only value untouched. This is necessary because a status-only
entry (unlike `claim_closures[]`, which is always a terminal record on its own) carries only a
subset of this sweep's own fields.

## 6. Bounded search (section 6's own final, converged form)

A `grep`/`head` pipeline with a FIFO-based live stderr cap, an explicit-PID `wait`, and a
COMBINED error signal across FOUR independent checks — the simplest correct form reached across
this design's own convergence, after four prior forms each fixed one defect while (three times)
reintroducing another:

```bash
bash -c '
  set -u
  PATTERN="$1"; SCOPE="$2"
  PRIVDIR="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 3; }
  chmod 700 "$PRIVDIR"
  ERRFIFO="$PRIVDIR/errfifo"
  if ! mkfifo "$ERRFIFO" 2>/dev/null; then
    echo "mkfifo failed" >&2
    rm -rf "$PRIVDIR"
    exit 3
  fi
  head -n "$ERR_LINE_CAP" < "$ERRFIFO" > "$ERRFILE" 2>/dev/null &
  ERR_READER_PID=$!
  grep -rn -- "$PATTERN" "$SCOPE" 2>"$ERRFIFO" | head -n "$((MAX_CANDIDATE_FILES + 1))" > "$RESULT_FILE"
  read -r GREP_STATUS STDOUT_HEAD_STATUS <<< "${PIPESTATUS[0]} ${PIPESTATUS[1]}"
  wait "$ERR_READER_PID"
  READER_STATUS=$?
  rm -rf "$PRIVDIR"
  echo "$GREP_STATUS $STDOUT_HEAD_STATUS $READER_STATUS" > "$STATUS_FILE" || exit 4
' bash "<pattern>" "<scope>"
WRAPPER_EXIT=$?
```

- **The whole pipeline runs inside an explicit `bash -c '...'` wrapper, regardless of the ambient
  calling shell.** `PIPESTATUS` is a Bash-specific array; this project's own harness executes
  direct shell tool calls via `/bin/zsh`, not Bash (confirmed directly, `ps -p $$ -o comm=` inside
  a tool call prints `zsh`) — zsh has no `PIPESTATUS` array at all (only a lowercase, 1-indexed
  `pipestatus`), so referencing `${PIPESTATUS[0]}` under `set -u` in zsh aborts the whole attempt
  with `parameter not set`, and without `set -u` it silently evaluates to an empty string,
  live-reproduced both ways directly. Wrapping the whole mechanism in one `bash -c '...'` invocation
  sidesteps needing dual bash/zsh syntax entirely — `$ERRFILE`/`$RESULT_FILE`/`$STATUS_FILE`/
  `$ERR_LINE_CAP`/`$MAX_CANDIDATE_FILES` are `export`-ed from the calling context before this
  invocation so the inner `bash -c` script can see them, and `$STATUS_FILE` carries the three
  captured status values back out to the caller (a `bash -c` subprocess's own shell variables do
  not survive back into the parent process, so they cannot simply be read afterward as ordinary
  variables the way a sourced script's would).
- **`<pattern>` and `<scope>` are passed as POSITIONAL ARGUMENTS to `bash -c '...' bash "<pattern>"
  "<scope>"` (becoming `$1`/`$2` inside the script, assigned to `$PATTERN`/`$SCOPE` and then used
  as ordinary quoted variables), NEVER textually substituted into the single-quoted script body
  itself.** The pattern in section 2's own sweep trigger is a real grep target derived from a
  finding's own text — not a fixed literal this file controls — so it can legitimately contain a
  single quote (an apostrophe in a real code identifier or string literal, e.g. a pattern
  containing `can't`). Live-reproduced the concrete exploit of textual substitution: constructing
  a `bash -c '<script text with <pattern> textually replaced>'` invocation where the replacement
  value was itself `x' ; printf injected > <marker-path> ; : '` closed the outer single quote
  early and caused the trailing `; printf injected > <marker-path> ; : ` to execute as literal,
  unquoted shell commands in the CALLING shell's own context — a full injection, not merely a
  malformed grep invocation. Passing the same value as a POSITIONAL ARGUMENT instead — never
  interpolated into the script's own source text — live-verified this exact same malicious string
  runs harmlessly as `grep`'s own (failing, since it isn't a valid pattern for this scope) literal
  search argument, with no injected command ever executing.
- **`grep -rn -- "$PATTERN" "$SCOPE"` includes an explicit `--` end-of-options marker, immediately
  before `$PATTERN`.** Quoting `$PATTERN` prevents shell-level expansion (globbing, word-splitting)
  but does NOT stop `grep` itself from interpreting a value that starts with `-` as one of its OWN
  command-line options rather than as the search pattern — this is `grep`'s own argument-parsing
  behavior, entirely independent of the shell-injection fix above. Live-reproduced directly: a
  perfectly legitimate, real sweep pattern this project's own codebase actually contains —
  `--compact` (an existing flag name, see `--compact`'s own opt-in thread compaction feature) —
  passed as `$PATTERN` without `--` makes `grep` exit `2` with `unrecognized option '--compact'`,
  a `search_error` for a pattern that in fact has real matches; the identical invocation WITH `--`
  correctly treats it as a literal search string and returns the genuine match. `--` is the POSIX
  convention every one of this project's own greps should already use for exactly this reason —
  present in all three copies of this invocation (the reference's own documented pipeline, and both
  places the shell-level regression test suite mirrors it).
- **`GREP_STATUS`/`STDOUT_HEAD_STATUS` are captured in a SINGLE `read ... <<< "${PIPESTATUS[0]}
  ${PIPESTATUS[1]}"` statement, never as two separate assignment statements.** Live-reproduced that
  a separate second assignment statement (`STDOUT_HEAD_STATUS="${PIPESTATUS[1]}"` on its own line
  after `GREP_STATUS="${PIPESTATUS[0]}"`) silently RESETS `PIPESTATUS` before the second index is
  ever read — Bash repopulates `PIPESTATUS` after every pipeline it runs, including trivial internal
  ones a plain variable assignment can trigger, so by the time the second assignment statement
  executes, `PIPESTATUS[0]` has already changed and `PIPESTATUS[1]` is now empty. A single `read`
  reading both indices as one command's own arguments captures both values from the SAME
  `PIPESTATUS` snapshot, before anything else can run and reset it.
- `MAX_CANDIDATE_FILES = 20` — a fixed constant (not user-configurable in v1, YAGNI, same
  fixed-constant-first precedent as `--compact`'s own `COMPACT_THRESHOLD`).
- `ERR_LINE_CAP = 20` — a second, independent fixed constant capping `$ERRFILE`'s own line count.
  Without it, a broad search against many inaccessible/unreadable paths emits one stderr
  diagnostic line PER failing path — live-reproduced: `grep`'ing for a nonexistent pattern across 5
  nonexistent paths produces exactly 5 stderr lines, scaling linearly with failing-path count, not
  match count, so `$ERRFILE` would otherwise be unbounded regardless of `MAX_CANDIDATE_FILES`.
  `head -n 20` is generous for genuine diagnostics (a real invalid-pattern error is normally one
  line) while still bounding the pathological many-failing-paths case — live-verified with 50
  simultaneously-unreadable paths: `$ERRFILE` still capped at exactly 20 lines, not 50.
- **Why a FIFO plus an explicit-PID `wait`, not `2> >(...)` process substitution with a bare
  `wait`:** an earlier form of this pipeline used inline `2> >(head -n "$ERR_LINE_CAP" >
  "$ERRFILE")` followed by a bare `wait` (no PID argument), reasoning that `wait` would block on
  the substitution's own subshell. **Live-reproduced that this reasoning was wrong on this
  project's actual target shell (bash 3.2, macOS system bash)**: `jobs -l` run immediately after
  the pipeline shows the process-substitution subshell is NOT registered as a waitable job at all
  on this bash version, so a bare `wait` returns immediately without actually waiting for it —
  `$ERRFILE` can then still be empty at the moment it is checked even though `grep`'s own
  diagnostic write is already in flight, restoring exactly the original race this mechanism exists
  to close. **Fixed by using an explicit named pipe (`mkfifo`) with a reader process started
  BEFORE `grep` runs, capturing that reader's own `$!` and `wait`-ing on that SPECIFIC PID** — an
  explicit-PID `wait` reliably blocks until that exact process exits, regardless of whether the
  shell's job table tracks it as a "job." Live-verified across 30 trials of the exact
  permission-error-plus-many-matches case below: 0/30 failures, versus the bare-`wait`
  process-substitution form's own reproducible failure on the same case.
- **`$ERRFIFO` lives inside a PRIVATE, per-attempt `mktemp -d` directory (`chmod 700`, this user
  only), never a bare `mktemp -u` pathname used directly.** `mktemp -u` only PRINTS an unreserved,
  currently-unused pathname — Darwin's own `mktemp(1)` man page states this explicitly ("still
  introduces a race condition... use of this option is not encouraged"). Live-reproduced the
  concrete exploit this enables: after a bare `mktemp -u` pathname's own successful `mkfifo` call,
  replacing that SAME pathname with a symlink to `/dev/null` before the reader/`grep` ever start
  silently discards every stderr diagnostic through it — `$ERRFILE` ends up empty despite a genuine
  permission error being present, and neither `GREP_STATUS` nor `READER_STATUS` catches it either
  (both report clean success, since writing to `/dev/null` never fails). A private, `0700`,
  per-attempt directory removes this ACROSS-USER attack surface entirely — no OTHER user's own
  process can even traverse into the directory to reach the pathname at all. **This does NOT
  remove the TOCTOU window for a process already running as this SAME user** — see the disclosed
  same-UID limitation later in this section for why that residual case is accepted rather than
  further hardened.
- `mktemp -d` and `mkfifo`'s own exit statuses are BOTH checked at creation, each exiting the whole
  attempt (status `3`, a fixed sentinel distinct from any real `grep`/`head` exit code) immediately
  if either fails — before the reader or `grep` are ever started. A failure at either point is
  recorded as `search_error` unconditionally (see the combined check below), since neither `grep`
  nor the reader ever actually ran in that case.
- **The error signal is a COMBINATION of FOUR independent checks — `GREP_STATUS -ge 2` (excluding
  `141`, see below), OR `$ERRFILE` non-empty, OR `READER_STATUS -ne 0`, OR `WRAPPER_EXIT -ne 0`
  (ANY nonzero exit from the whole `bash -c` invocation — never narrowed to checking only for the
  specific `3` sentinel) — any ONE alone sufficient — never any single signal used in isolation.**
  **`WRAPPER_EXIT` must be checked as "nonzero," full stop, never as "equals `3`" specifically** —
  `3` is this script's own DELIBERATE sentinel for the `mktemp -d`/`mkfifo`-failure case, but the
  wrapper can ALSO exit nonzero for reasons this script never anticipated (a `bash -c` invocation
  itself failing to even start, an unhandled error inside the script triggering some OTHER exit
  code, `$STATUS_FILE`'s own final write failing — see the dedicated bullet on that below).
  Live-reproduced directly: making `$STATUS_FILE` itself unwritable (`chmod 000`) makes the whole
  wrapper exit `1`, not `3` — a "check for exactly `3`" rule would silently fail OPEN here, treating
  a broken attempt as if it had run cleanly with a missing/stale `$STATUS_FILE`. Checking
  `WRAPPER_EXIT -ne 0` unconditionally, regardless of the specific nonzero value, closes this
  regardless of which specific way the wrapper failed. Earlier single/double/triple-signal
  forms were each tried and found insufficient in turn:
  - **`$ERRFILE`'s own emptiness alone** fails OPEN whenever `$ERRFILE`'s write path itself fails
    for a reason unrelated to `grep` (a full disk, a permissions problem on the temp directory) —
    a genuine search failure could then leave `$ERRFILE` empty and be silently misclassified as a
    clean, zero-match sweep.
  - **`GREP_STATUS` alone (even with the `141` exclusion below) also fails OPEN** in a genuinely
    live-reproduced mixed case: a scope containing BOTH a permission-denied path AND a match count
    large enough to trigger `head`'s own early-close SIGPIPE. `grep` can only report ONE exit
    status for the whole invocation, and when both conditions occur together, `SIGPIPE` (`141`)
    is what actually terminates the process — silently overwriting/preventing the permission
    error's own `2` exit code that would otherwise have been reported. Live-reproduced directly:
    a directory with one `chmod 000` subdirectory alongside 100,000+ matching lines yields
    `GREP_STATUS=141` (masking the real permission error) while `$ERRFILE` STILL correctly
    contains the actual "Permission denied" diagnostic text — so `$ERRFILE`'s own content remains
    a genuinely independent, non-redundant second signal precisely for this masked-status case,
    not a redundant belt-and-suspenders duplicate of `GREP_STATUS`.
  - **`GREP_STATUS` and `$ERRFILE` combined still both fail OPEN** whenever the READER process
    itself (the `head` writing `$ERRFILE`) fails to write for a reason unrelated to `grep`'s own
    diagnostics (e.g. a full disk, `$ERRFILE`'s own directory made unwritable mid-run) — the
    reader dying breaks the FIFO's write end, which itself delivers `SIGPIPE` (`141`) to `grep`
    (masking `grep`'s real status the same way the case above does, but for a DIFFERENT root
    cause), and leaves `$ERRFILE` empty/incomplete since the reader never finished writing it.
    Live-reproduced directly: a read-only `$ERRFILE` target plus 1,000 nonexistent search operands
    (genuine diagnostics `grep` needs to emit) yields `GREP_STATUS=141` (from the broken pipe, not
    the stdout cap) and `$ERRFILE` inaccessible/empty — neither signal alone catches this, but the
    reader's OWN exit status (`READER_STATUS`, from `wait "$ERR_READER_PID"`) is non-zero exactly
    here, distinguishing "the reader itself broke" from "the reader finished cleanly and simply
    found nothing to write" (the ordinary no-error case, where `READER_STATUS` is `0`).
  - **All three of the above still fail OPEN when a DIFFERENT process (the `RESULT_FILE` writer —
    the stdout `head` closing the candidate list) fails to write, while `grep` itself succeeds with
    matches found (`GREP_STATUS=0`).** Live-reproduced directly: a read-only `$RESULT_FILE` target
    yields `GREP_STATUS=0` (grep itself ran fine and found matches) with `STDOUT_HEAD_STATUS=1`
    (the stdout `head` failed to write) — `$RESULT_FILE` itself ends up empty/inaccessible despite
    genuine matches existing, and neither `GREP_STATUS`, `$ERRFILE`, nor `READER_STATUS` (all about
    the STDERR side of the pipeline) has any visibility into this DIFFERENT process's own failure.
    `STDOUT_HEAD_STATUS` (captured in the same single `read` as `GREP_STATUS`, per the bullet
    above) is what catches this — non-zero here means the candidate LIST itself is unreliable,
    distinct from `search_error` (a search-health question) in the same way `pending_error` is
    already distinct from `pending_scope` in section 3 — treat a non-zero `STDOUT_HEAD_STATUS` as
    its own genuine RETRY case (re-run the whole attempt from scratch), never silently accepted as
    "zero candidates found."
  - Combining all signals — reporting `search_error` (or the analogous RETRY case for
    `STDOUT_HEAD_STATUS`) whenever ANY signal fires — closes every gap found so far: live-verified
    across (a) a genuine invalid-pattern error (caught via `GREP_STATUS=2`), (b) a clean
    large-match-count truncation (correctly NOT flagged — `GREP_STATUS` `141` excluded, `$ERRFILE`
    empty, `READER_STATUS`/`STDOUT_HEAD_STATUS` both `0`, `WRAPPER_EXIT` `0`), (c) a nonexistent
    scope directory (caught via `GREP_STATUS=2`), (d) the masked-status mixed case (caught via
    `$ERRFILE`'s own non-empty content), (e) the stderr-reader-failure case (caught via
    `READER_STATUS`), (f) the `mktemp -d`/`mkfifo`-failure case (caught via `WRAPPER_EXIT=3`), (g)
    the stdout/`RESULT_FILE`-writer-failure case (caught via `STDOUT_HEAD_STATUS`), and a
    `$STATUS_FILE`-write failure itself, per the bullet below (caught via `WRAPPER_EXIT` being
    SOME OTHER nonzero value, e.g. `1`, live-reproduced directly — never assumed to always be `3`).
- **`141` (`128 + SIGPIPE`'s signal number `13`) is explicitly EXCLUDED from the `GREP_STATUS -ge
  2` half of the check** — it is the OS's own normal, EXPECTED result of `head` closing its read
  end early after accepting `MAX_CANDIDATE_FILES + 1` lines while `grep` still had more output
  queued, exactly the SIGPIPE-bounded-real-work behavior this section's own live-pipe design
  already relies on (see the bullet below), never itself a fault. Live-reproduced: a pattern
  matching 100,000+ lines yields `GREP_STATUS=141` on the ordinary capped/fast-path case, which an
  unqualified `GREP_STATUS -ge 2` rule would misclassify as a search failure despite
  `$RESULT_FILE` correctly holding the capped candidate set and zero actual error.
- The `+1` on the `head` cap is deliberate: if the (N+1)th line exists, the true count exceeds the
  cap — the truncation signal. Counting fewer than N+1 lines back could never distinguish "exactly
  N" from "more than N."
- `$PRIVDIR` (and the `$ERRFIFO` inside it), `$ERRFILE`, `$RESULT_FILE`, and `$STATUS_FILE` are
  Claude-side `mktemp -d`/`mktemp`-allocated paths, one full set per sweep ATTEMPT (never reused
  across attempts or shared across parallel groups) — `$PRIVDIR` (which removes `$ERRFIFO` along
  with it) is removed once the reader process has exited (right after `wait "$ERR_READER_PID"`,
  inside the same `bash -c` invocation, before either file's own content is read outside it),
  `$ERRFILE`/`$RESULT_FILE`/`$STATUS_FILE` cleaned up once that attempt's outcome is read and
  recorded — the same allocate-once-per-attempt/clean-up-after-logging convention `EVENTLOG_FILE`
  already uses.
- **`$STATUS_FILE`'s own final write (`echo "..." > "$STATUS_FILE"`) is itself checked (`|| exit
  4`), a SEPARATE sentinel from `mktemp -d`/`mkfifo`'s own `3`** — a failure writing `$STATUS_FILE`
  (a full disk, a permissions problem, `$STATUS_FILE`'s own directory made unwritable mid-run)
  means the whole attempt's captured statuses never reached the caller at all, indistinguishable
  from "everything succeeded and nothing needs recording" unless checked explicitly.
  **`WRAPPER_EXIT` must be checked as "nonzero," never as "equals `3`" — this is why**: the
  underlying OS/shell failure mode for a broken `$STATUS_FILE` write is NOT guaranteed to be `4`
  either (it depends on exactly how/where the write fails) — live-reproduced directly, a
  `chmod 000`'d `$STATUS_FILE` made the whole wrapper exit `1`, not `4` (the shell's own
  redirection-failure handling exits nonzero on its own terms, before this script's explicit `||
  exit 4` guard is even reached in that particular failure mode). The sentinels `3`/`4` are
  DIAGNOSTIC labels for two failure points this script anticipated and deliberately coded for —
  the actual pass/fail DECISION is `WRAPPER_EXIT -ne 0`, full stop, covering both these anticipated
  cases and any other nonzero exit this script did not specifically anticipate.
- Check the combined signal: a genuine search error (`search_error`, section 5) is `WRAPPER_EXIT
  -ne 0` (ANY nonzero value — in this case `$STATUS_FILE` may never have been written at all, or
  may hold stale content from cleanup that ran before the write, so nothing further is read from
  it), OR `READER_STATUS -ne 0`, OR `{ [ "$GREP_STATUS" -ge 2 ] && [ "$GREP_STATUS" != 141 ]; }`,
  OR `[ -s "$ERRFILE" ]` — read `$ERRFILE` for the human-readable diagnostic text to record
  whenever it has content, regardless of which specific signal actually fired (when a nonzero
  `WRAPPER_EXIT` or a genuine reader failure is what fired, `$ERRFILE`'s own content may itself be
  empty/unavailable — record `search_error`'s own text from whichever signal fired, falling back
  to a fixed description of that signal, e.g. "mktemp/mkfifo failed", "stderr reader process
  failed", or "status file write failed", when `$ERRFILE` has nothing useful). SEPARATELY,
  `STDOUT_HEAD_STATUS -ne 0` is its own genuine RETRY case (the candidate list itself is
  unreliable), never folded into `search_error` — see the bullet above (this check is only
  meaningful when `WRAPPER_EXIT` is `0` and `$STATUS_FILE` was actually written; a nonzero
  `WRAPPER_EXIT` already means `search_error` regardless of what `$STATUS_FILE` might contain).
  Otherwise (`WRAPPER_EXIT` `0`, `READER_STATUS` and `STDOUT_HEAD_STATUS` both `0`, `GREP_STATUS`
  is `0`/`1`/`141`, AND `$ERRFILE` is empty), no search error occurred; count the stdout lines
  actually read (up to `MAX_CANDIDATE_FILES + 1`) for this ordinary no-error case.
- The `grep | head` pipeline itself is a live pipe throughout — `head` closing early after N+1
  lines lets the OS deliver `SIGPIPE` to `grep`, bounding real work for the common case (a pattern
  with at least a few matches, found before traversing the whole scope) — this is precisely the
  mechanism that produces the `GREP_STATUS=141` case excluded above, never itself a fault. The
  `$ERRFIFO`-based stderr cap is an independent pipeline from the stdout `head` pipe — `SIGPIPE` on
  stdout closing early has no effect on it, and vice versa (this is also why the masked-status
  case above is possible: the two pipelines' own exit signals are independent, and only ONE exit
  status, `grep`'s own, is available to the caller — motivating the combined-signal check above).

**Explicitly accepted, disclosed limitation — not silently hidden:** this does NOT bound wall-clock
TRAVERSAL TIME for a genuinely enormous search scope with a sparse/zero-match pattern — `grep`
still visits every file in `<scope>` even when each one is quickly rejected. This design tried,
across multiple rounds, to build a hand-rolled wall-clock watchdog (background search racing a
background `sleep`+`kill`) and found it disproportionately expensive to get right and portable
(non-portable `set -m` job control, race conditions in the sentinel-write ordering) relative to
simply accepting this tradeoff: the actual review scope this design operates within is the same
repository `/ccs` is already reviewing, where an unbounded-but-typically-fast full traversal is an
acceptable cost today. Revisit with real usage data if this ever proves wrong in practice, exactly
as `--compact` itself was revisited only once real session data justified it — never re-add a
timing mechanism speculatively.

**A second explicitly accepted, disclosed limitation:** the private `mktemp -d`/`chmod 700`
directory (see the bullet on `$ERRFIFO`'s own placement above) closes the TOCTOU race for any
OTHER user's process, but NOT for a DIFFERENT process already running as this SAME user (a
same-UID attacker) — that process can still traverse the private directory (it shares this user's
own privileges by definition) and race to replace `$ERRFIFO` after `mkfifo` succeeds but before the
reader/`grep` start. Live-reproduced directly: a same-UID process racing to replace `$ERRFIFO` with
a symlink to `/dev/null` in that narrow window (won only with an artificial `sleep` inserted to
widen it for the reproduction itself — the real window, with no artificial delay, is a handful of
shell-fork-and-exec calls wide) silently discards a genuine diagnostic the same way the
`mktemp -u` case above did. This residual risk is accepted rather than further hardened for the
same reason the traversal-time limitation above is: `/ccs`'s own threat model is a single review
session's own read-only shell access, cooperating with itself, not a hostile OTHER same-user
process actively racing this specific mechanism — closing this completely would require atomic
FIFO creation-plus-first-open semantics POSIX shell scripting does not straightforwardly offer
(e.g. `mkfifo`+`open` as one non-interruptible syscall pair), disproportionate to the actual threat
this design defends against today. Revisit with real evidence of exploitation, never speculatively.

## 7. Non-goals

- Not a blanket "always grep the whole repo" instruction — fires only when a specific,
  already-confirmed finding is judged class-like, never as a standing per-round tax on every
  finding.
- Does not change the claim ledger, receipt validation, or `--compact` — a sweep's own fixes and
  findings flow through the existing verification/claim-ledger machinery unchanged; this reference
  only adds the trigger and the record of having swept.
- No new opt-in flag — a bounded, always-on extension to two already-always-on mechanisms
  (narrow→wide→narrow, whole-flow re-check).

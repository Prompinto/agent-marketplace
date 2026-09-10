# Empty/failed review handling — reference

> Read this file in full the moment Phase 2 step 1 parses any group's response as `ok:false`,
> before doing anything else with that result (retrying it, folding it into a round-level status,
> or reporting to the user). A session where every round's dispatch returns `ok:true` never
> triggers this at all — this content is not needed for the common, cleanly-converging case.

- **Empty / failed review ≠ CLEAN.** `ok:false` for a group → retry that group before accepting
  failure, reusing the exact dispatch shape appropriate to whether a thread actually exists for
  it — the shape of that retry depends on the failure reason (below), it is not always the same
  single fresh retry the wrapper's own reason table alone might suggest:
  - **Per-group retry (parallel mode) — the same rule applies per group, not just to a
    single-reviewer round.** If ANY dispatched group in a parallel round returns `"ok":false`, the
    ROUND overall is not eligible for `✅ CLEAN` — worst-case-wins, the same principle `SKILL.md`
    uses for the `coverage_source`/`codex_review` parallel merges. Retry JUST that failed group — the
    other groups' real, already-collected results are kept, not thrown away and re-dispatched.
  - **`artifact_too_large` — never retried, ever, for that group, fresh or resumed (Phase 5 Item
    A).** An identical resend of the same oversized prompt fails identically — there is nothing
    that a bounded resume-retry or a fresh restart could fix on its own, unlike every other
    `ok:false` reason in this section. This group's round-level status is immediately
    **🛑 INPUT TOO LARGE** — the round is NOT eligible for `✅ CLEAN` and no automatic whole-round
    retry with smaller input is attempted; a human must start a fresh `codex-stream-review:ccs`
    invocation with a narrower diff scope or shorter `--focus`/pasted artifact. On a fresh round-1
    attempt, no thread was ever started for this group — nothing to add to `LEAKED_THREAD_IDS`. On
    a resumed attempt, the threadId already existed and is untouched, not abandoned — it receives
    NORMAL terminal-path cleanup like any other outcome's thread (the same `--keep-evidence` gate
    every other non-CLEAN outcome already uses), never a special "keep alive so it can be retried
    later" exception; a caller who wants to retry with shorter text uses `--keep-evidence` for that
    session, the same as investigating any other outcome. **Parallel mode:** other groups that
    already dispatched successfully this round are NOT aborted mid-flight; their threads are
    cleaned up normally at the SAME terminal path, applied uniformly to ALL groups' threads
    together (never a partial keep where some groups' threads are retained and others are not),
    and their real findings are NEVER used to construct a partial/degraded CLEAN — the round-level
    terminal status is **🛑 INPUT TOO LARGE** regardless of what any other group found.
  - **No `threadId` was ever captured for THIS failure response** (`bad_args`, `git_error`,
    `incomplete_collection`, `no_thread_started`, or `interrupted`/`timeout` on the rare occasion
    either fires before a thread ever started — see `SKILL.md`'s reason table's `threadId` column,
    which is per-OCCURRENCE, not a blanket guarantee for every reason in the "resume-safe" row
    below). **A missing `threadId` in the failure response is not the same claim as "no thread
    exists for this group" — check `GROUP_THREADS` directly, never infer this from the round
    number.** The two only coincide for a group's very first-ever dispatch attempt; they do NOT
    coincide for a no-`threadId` failure encountered *during* one of the bounded resume-retries
    below (still round 1, but by definition already past a first attempt that DID obtain a real
    `threadId`), nor for any round-2+ attempt (which always starts from an existing
    `GROUP_THREADS` entry). Handle by whether `GROUP_THREADS` already has an entry for this group,
    checked at the moment of this specific failure — not by which round counter value happens to
    be current:
    - **This group has NO entry in `GROUP_THREADS` yet** (its true first-ever attempt — only
      possible on round 1, before that round's own first dispatch has ever returned a `threadId`):
      nothing exists to resume — retry the same scope flag fresh, exactly once (include
      `--capture-eventlog` with its own fresh `EVENTLOG_FILE` when capture is ON, and
      `--keep-last-message` with its own fresh `LAST_MESSAGE_KEEP_FILE` when keep-evidence is ON,
      same as every dispatch — see `references/capture-evidence.md` and
      `references/keep-evidence.md`). **If this is round 1 and the reason
      is `no_thread_started`, capture coverage from the failing attempt BEFORE dispatching that
      retry** — see the "Round 1 only — capture coverage from the failing attempt BEFORE
      retrying" note below; it applies here identically, even though `no_thread_started` never
      carries a `threadId` and so is always handled by this bullet rather than the
      threadId-captured one below it. If it fails again, stop — report **⚠️ COULD NOT VERIFY**.
    - **This group ALREADY has an entry in `GROUP_THREADS`** (a real, persistent thread from an
      earlier successful dispatch — whether that was this same round's own original attempt,
      before a subsequent resume-retry hit a no-`threadId` failure, or an earlier round entirely):
      a `--resume` call CAN still fail with no `threadId` in its own failure JSON (e.g. `bad_args`
      from empty/whitespace-only focus text on stdin, caught right after the wrapper reads its own
      stdin *before* it ever touches the resumed thread — confirmed directly from the wrapper's
      own dispatch order). That existing thread is untouched, not abandoned, by this kind of
      failure — retry
      the exact same `--resume "<this group's existing threadId from GROUP_THREADS>"` call again
      (correcting whatever caused the bad response, e.g. genuinely non-empty focus text on stdin
      this time), never a "fresh" scope flag (there is none to use once a group has ever been resumed)
      and never anything added to `LEAKED_THREAD_IDS` (nothing was actually abandoned). If the
      retry also fails, stop — report **⚠️ COULD NOT VERIFY**.
  - **A `threadId` WAS captured, and the reason is resume-safe** (`interrupted`, `timeout`,
    `nonzero_exit`, `missing_task_complete`, `no_final_answer`, `invalid_json`, `schema_mismatch`
    — see `SKILL.md`'s "Resume-safety by failure reason" table): prefer a bounded `--resume` retry
    over abandoning the thread.
    **Round 1 only — capture coverage from the failing attempt BEFORE retrying.** If this failure
    is for a group's round-1 attempt (the one dispatched with `--uncommitted`/`--base`/`--commit`,
    not an already-resumed round 2+ attempt) and the reason is one of the 7 post-dispatch reasons
    that unconditionally carry `coverage.source` whenever it was a fresh `--uncommitted` dispatch
    (`timeout`, `nonzero_exit`, `missing_task_complete`, `no_final_answer`,
    `invalid_json`, `schema_mismatch`, `no_thread_started` — see "Coverage" in `SKILL.md`'s
    interface reference), or the reason is `interrupted` (which carries it only conditionally,
    depending on signal timing — see that same section), check this failed response for a
    `coverage.source` object now, before dispatching the retry below. If present, capture that
    value as this group's round-1 `coverage_source` determination (per `SKILL.md`'s "Coverage is a
    Round-1-only property" section) and keep it — the `--resume` retry that follows never reports
    `coverage.source` itself (no `--resume` call ever does), so this failed response is the ONLY
    place this round's real coverage data can come from once a retry is needed. For `interrupted`
    specifically, `coverage.source` may genuinely be absent — if so, there is nothing to capture;
    proceed to the retry below and let the round-1 `coverage_source` determination fall back to
    the `{"status":"unknown","omitted":[]}` sentinel exactly as it would for any other
    coverage-absent round 1 (see "Coverage is a Round-1-only property" in `SKILL.md`). Skipping
    this capture for a failure that DID carry it would force the convergence gate to fall back to
    that same sentinel and block a clean `✅ CLEAN` verdict (see `SKILL.md`'s "Partial or unknown
    source coverage ≠ CLEAN" bullet) even though the diff was, in fact, already fully collected on
    this first attempt — the eventual `ok:true` result coming from the `--resume` retry does not
    change that. (For a round-2+ resume-safe failure, there is nothing to capture here: that
    attempt was itself already a `--resume` call, so it never carried `coverage.source` in the
    first place.)
    Wait 5s, then — using the Write tool to write a fresh `FOCUS_FILE` exactly like `SKILL.md`'s
    Phase 1 Step 0 (no sentinel needed — see `SKILL.md`'s sentinel idiom section for why
    `FOCUS_FILE` is the one exception), then redirecting it into the wrapper's own stdin, never a
    value interpolated directly:
    ```
    FOCUS_FILE="<a fresh mktemp'd path, written via the Write tool exactly like Phase 1 Step 0 --
    content is the SAME ⚠️ SCOPE CONSTRAINT block every round's focus text already requires, plus a
    short note: retrying after a <reason> failure -- please provide your review>"
    # If capture-evidence is ON for this session, literally include --capture-eventlog "<a
    # freshly-mktemp'd EVENTLOG_FILE, same template as Phase 1 Step 0 -- NOT the original round's
    # already-consumed one>" here too -- this retry is its own separate codex exec process with
    # its own event log, exactly like every other dispatch call in this file (see
    # references/capture-evidence.md, including its multi-attempt handling note); omit the flag entirely
    # when capture is OFF, same rule as Step 1. Independently, if keep-evidence is ON for this
    # session, literally include --keep-last-message "<a freshly-mktemp'd LAST_MESSAGE_KEEP_FILE,
    # same template as Phase 1 Step 0 -- NOT the original round's already-consumed one>" here too --
    # this retry is its own separate codex exec process with its own final-answer output, exactly
    # like every other dispatch call in this file (see references/keep-evidence.md, including its
    # own multi-attempt handling note below); omit the flag entirely when keep-evidence is OFF,
    # same rule as Step 1.
    "$INSTALL_PATH/scripts/run-ccs-review.sh" --cwd "$REPO_ROOT_OR_CLEAN_REPO_DIR" \
      --resume "<that threadId>" --timeout 300 \
      < "$FOCUS_FILE"
    ```
    **Multi-attempt evidence handling (general rule, only relevant with capture-evidence ON —
    applies identically to every retry variant in this file, resume or fresh):** when
    ANY retry for the same (round, group) ultimately succeeds (or is itself what a group's final
    `⚠️ COULD NOT VERIFY` outcome is based on), extract `investigation_evidence` from that LAST
    attempt's own `EVENTLOG_FILE` only — never an earlier, now-discarded failed attempt's — since
    the last attempt's result is what the round's own JSONL line actually reports. `rm -f` every
    EARLIER attempt's `EVENTLOG_FILE` too, without extracting from it, once the round concludes —
    a disclosed, deliberate simplification: any commands Codex ran during an earlier failed
    attempt before it failed are not merged into that round's evidence, only the final attempt's
    are. This keeps the merge model in `references/capture-evidence.md` to exactly one value
    per (round, group) rather than needing a second, attempt-level merge layer on top of the
    existing group-level one — and still closes the privacy contract (every allocated eventlog
    this session ever creates is deleted, extracted from or not), just narrows what gets reported
    into the log.
    **Multi-attempt kept-evidence handling (general rule, only relevant with keep-evidence ON —
    applies identically to every retry variant in this file, resume or fresh, by the same
    reasoning as the capture-evidence rule immediately above):** when ANY retry for the same
    (round, group) ultimately succeeds, apply the normal keep-or-delete step (per
    `references/keep-evidence.md`) to that LAST attempt's own `LAST_MESSAGE_KEEP_FILE` only — a
    successful outcome deletes it, same as any other successful round. When a group's round instead
    ultimately ends in `⚠️ COULD NOT VERIFY` after one or more retries, only the LAST attempt's own
    `LAST_MESSAGE_KEEP_FILE` is a candidate for keeping — it is what actually determines that
    group's final failure, and its content is what a human would actually want to inspect. Either
    way, `rm -f` every EARLIER attempt's own `LAST_MESSAGE_KEEP_FILE` without moving or inspecting
    it, once the round concludes — an earlier attempt's output describes a state that a subsequent
    retry has already superseded, so retaining it (whether the round ends in success or in
    `⚠️ COULD NOT VERIFY`) would leave a human sifting through, or `/tmp` accumulating, stale
    superseded output the round's own outcome no longer depends on. This is the identical
    simplification `references/capture-evidence.md`'s own multi-attempt rule already makes, applied
    to kept last-message files instead of eventlogs.
    **`--timeout 300` (5 min) is required on both retry attempts, never the wrapper's 1800s
    default** — without an explicit shorter timeout, a genuinely stuck retry can silently consume
    the full default window per attempt, turning a "bounded, short backoff" retry into a
    worst-case multi-hour stall across the original call plus two full-length retries; 300s is
    ample for a normal review turn and still fails fast on a truly stuck one. **The retry focus
    text still needs the full `⚠️ SCOPE CONSTRAINT` block**, same as every other round's `--focus`
    (see `SKILL.md`'s "Hard rules" and `## Rules` sections) — losing that requirement just because
    this is a retry, not a "real" round, would be inconsistent with the rest of this file; only the
    diff itself is never re-sent, matching every other resumed call. If this also fails with a
    resume-safe reason, wait 15s and retry once more (2 resume attempts total, each with its own
    5-minute cap) before giving up on that thread. **This applies to a failed round 1 as much as
    to round 2+** — the empirical finding this section is based on specifically tested a ROUND-1
    failure (the crash-simulation thread had only ever seen its first prompt) and confirmed the
    original diff-bearing prompt is already present in the thread's own rollout, so a resume-retry
    needs no diff re-sent even here.
    - If both resume-retries are exhausted and this was **round 1**: fall back to one fresh retry
      of the original scope flag, for that group, abandoning the now-unrecoverable thread (this
      fresh retry gets its own new `--capture-eventlog`/`EVENTLOG_FILE` too, when capture is ON,
      and its own new `--keep-last-message`/`LAST_MESSAGE_KEEP_FILE` too, when keep-evidence is ON,
      same as every dispatch — see `references/capture-evidence.md` and
      `references/keep-evidence.md`).
      **Append that abandoned `(GROUP, threadId)` pair to `LEAKED_THREAD_IDS`** — Claude remembers
      this set for the rest of the run, the same way `GROUP_THREADS`/`SESSION_ID` are remembered —
      so `SKILL.md`'s Phase 3 terminal path can clean it up alongside the run's final threads; it
      is never cleaned up here, only recorded. Only that ONE failed group's thread leaks — every
      other group's real, already-live thread is untouched. If this fresh retry also fails, stop —
      report **⚠️ COULD NOT VERIFY** for that group.
    - If both resume-retries are exhausted and this was **round 2+**: there is no fresh scope left
      to fall back to on an already-resumed group — stop directly, report
      **⚠️ COULD NOT VERIFY** for that group. No new threadId was ever created by either
      resume-retry, so nothing is added to `LEAKED_THREAD_IDS` on this path.
  - Besides `artifact_too_large`'s own dedicated bullet above (never retried, threadId presence
    depending on fresh vs. resume — see `SKILL.md`'s "Resume-safety by failure reason" section),
    there is no other "`threadId` was captured but the reason is NOT resume-safe" branch — every
    OTHER reason that can ever carry a `threadId` is resume-safe, now that
    `resume_thread_not_found`/`rollout_not_found` no longer exist as possible outcomes at all. The
    three bullets above (`artifact_too_large`, no `threadId`, and `threadId` + resume-safe) are
    exhaustive.
  - Whenever a group ends in **⚠️ COULD NOT VERIFY**, the round-level status is
    **⚠️ COULD NOT VERIFY**, regardless of how clean every other group's own findings turned out to
    be — never fold this into `⚠️ NOT CONVERGED`/`⚠️ PARTIAL COVERAGE` instead (those cover a
    genuine Claude/Codex disagreement or an unresolved coverage gap, not a group that never
    produced a real verdict). Never declare CLEAN off a missing review from any group. Still run
    the terminal-path cleanup (`SKILL.md`'s Phase 3) using whatever `threadId`s are known for every
    group, even from a failed response — unless `--keep-evidence` is ON for this session, in which
    case a non-CLEAN round-level status (as this one always is, per the bullet above) means Phase
    3's keep-evidence gate skips that cleanup instead; see `SKILL.md`'s "Kept evidence on failure"
    section.
  - Whenever a group ends in `artifact_too_large`, the round-level status is instead
    **🛑 INPUT TOO LARGE** — a DIFFERENT status from `⚠️ COULD NOT VERIFY`, never folded into it
    (see `artifact_too_large`'s own bullet above): unlike a genuinely-unavailable review, this
    outcome is deterministic and known immediately, with no retry ever attempted.

## Compaction-only exception (`--compact`, opt-in — see `references/compaction.md`)

Two narrow, explicitly-scoped exceptions apply ONLY when `--compact` is ON for this session AND
the failure in question occurs on a compaction attempt's own candidate thread specifically —
every rule in this file continues to apply completely unmodified to the round's own REAL group
(the existing/OLD thread), and to every session where `--compact` is OFF:

1. **The `artifact_too_large`/exhausted-retry MANDATORY terminal-outcome rules above (`🛑 INPUT
   TOO LARGE`, `⚠️ COULD NOT VERIFY`) do NOT apply to a failure occurring WITHIN a self-contained
   compaction attempt on a NEW candidate thread.** `references/compaction.md`'s own "Restart
   mechanism"/"On failure" sections deliberately absorb such a failure into "fall through to the
   fallback dispatch on the OLD, still-alive thread" rather than surfacing it as the round's own
   terminal status — a compaction attempt is not "a group" in this file's own sense; it is an
   internal sub-step of producing that round's one real outcome. This file's own existing rules
   for a REAL group's `ok:false` response (every bullet above) are otherwise entirely unaffected.
2. **This file's own no-threadId-fresh-retry and fresh-B escalation rules — scoped above to a
   group's OWN true first-ever attempt, "only possible on round 1" — are keyed on CANDIDATE-level
   thread history for a compaction attempt's candidate A specifically, never on the session's own
   round-index.** A compaction restart's own candidate dispatch is structurally always at session
   round 2 or later, yet candidate A is its own independent "first attempt" lifecycle for these
   specific mechanics, by construction, regardless of what round number in the session it
   actually occurs at — see `references/compaction.md`'s "Retry topology" section for candidate
   A's full four-bullet decision tree. This exception is scoped to candidate A ONLY, never to a
   compaction attempt's thread B, which gets NONE of this file's retry machinery at all (single-
   shot: it either succeeds, or the whole compaction attempt is immediately exhausted) — and never
   to an ordinary group's own genuine round-1 attempt, which keeps this file's literal round-1
   scoping exactly as written.

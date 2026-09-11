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
      `references/keep-evidence.md`).

      **This retry is a schedule-(re)generation trigger — a genuinely fresh thread, and the
      schedule already allocated for the original attempt must never be reused.** The original
      attempt's `RECEIPT_SCHEDULE_FILE` (Phase 1 Step 0) may already have been read by the launched
      `codex exec` process before the wrapper ever detected failure — `run-ccs-review.sh` writes the
      complete prompt (schedule included) and launches the process BEFORE any `thread.started`
      detection runs, so a `no_thread_started` (or any other) failure reason does not prove the
      schedule was never delivered. Generate a genuinely NEW `RECEIPT_SCHEDULE_FILE` for this retry
      (the original allocation is abandoned, never reused); perform the ordinary
      receipt-slot-issuance procedure (`SKILL.md`'s "Receipt slot issuance" section) and pass BOTH
      `--receipt-slot "$NEXT_SLOT"` and `--receipt-schedule-file "$RECEIPT_SCHEDULE_FILE"` (the new
      file) on this retry dispatch.

      **If this is round 1 and the reason
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
      --resume "<that threadId>" --receipt-slot "$NEXT_SLOT" --timeout 300 \
      < "$FOCUS_FILE"
    ```
    **Receipt-slot issuance applies to this retry dispatch too** — see `SKILL.md`'s "Receipt slot
    issuance" section for the full procedure and rationale (the mechanics are identical here): before
    constructing this retry's own dispatch above, durably append `{receipt_issued: {thread_id: "<that
    threadId>", index: $NEXT_SLOT}}` to the session JSONL log (via the same append-then-verify
    hard-stop mechanism, verified by its own shape per `SKILL.md`'s "Review history log" → "Write"),
    where `$NEXT_SLOT` is the highest prior `receipt_issued.index` for this `thread_id` plus 1. This
    is itself a separate dispatch attempt from the original one that failed, so it issues and
    durably records its own next slot, the same way. **Never add `--receipt-schedule-file` here** —
    this is always a resume to an existing thread that already has an active schedule; that flag is
    only for a fresh, thread-establishing dispatch (see `SKILL.md`'s "Dispatching it" note under
    "Receipt schedule generation").
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
      **This fresh retry is ALSO a schedule-(re)generation trigger — a genuinely new thread,
      abandoning the old one.** Generate a fresh `RECEIPT_SCHEDULE_FILE` for this new thread (the
      old thread's schedule, if one was ever established for it, is abandoned along with the
      thread itself — no attempt to salvage or carry forward its unused slots); perform the
      ordinary receipt-slot-issuance procedure (`SKILL.md`'s "Receipt slot issuance" section) and
      pass BOTH `--receipt-slot "$NEXT_SLOT"` and `--receipt-schedule-file "$RECEIPT_SCHEDULE_FILE"`
      on this fresh retry dispatch.
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
  - There is no "`threadId` was captured but the reason is NOT resume-safe" branch — every
    ORDINARY reason that can ever carry a `threadId` is resume-safe, now that
    `resume_thread_not_found`/`rollout_not_found` no longer exist as possible outcomes at all. The
    two bullets above (no `threadId`, and `threadId` + resume-safe) are exhaustive **for the
    ordinary `ok:false` failure reasons this section covers** — `no_material_reviewed` is a
    deliberate, separately-routed exception (see the section immediately below), never reaching
    this decision flow at all since `SKILL.md`'s Phase 2 step 1 intercepts it before ordinary
    Guards processing.
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

## `no_material_reviewed` — never resume-safe, one bounded fresh restart

Unlike every other threadId-bearing reason in the table above, `no_material_reviewed` (whether
detected by the wrapper's own `schema_mismatch` extension for `material_reviewed:false`, or by
Claude's own Phase 2 receipt-mismatch/invalid-null-pair check — see `SKILL.md`'s own Phase 2 step
1) is **never** resume-safe: the thread has just proven its own context is hollow, so resuming it
would only reproduce the identical failure.

**Detecting the wrapper-level route.** A `schema_mismatch` failure is this section's
`no_material_reviewed` route specifically when its own `detail` field contains the literal
substring `"no_material_reviewed"` (`codex-stream-review/scripts/run-ccs-review.sh`'s dedicated
`material_reviewed == false` check, which runs before — and independently of — the combined
semantic-validation check covering every other cross-field rule). Any OTHER `schema_mismatch`
`detail` text is an ordinary, unrelated semantic violation (malformed severity, a missing
dimension, a receipt/index null-pair mismatch, etc.) — handled by this file's normal resume-safe
`schema_mismatch` treatment instead, never routed through this section.

**Recovery — single-reviewer sessions only (`GROUP="main"`).** This recovery is available ONLY
when this session is running single-reviewer (`GROUP="main"`) — `target.original_scope_framing`
(needed to reconstruct this restart's own dispatch) is a single top-level JSONL field with no
per-group equivalent today; building genuine per-group scope-framing isolation is real
infrastructure work, out of this task's scope. See the parallel-mode fallback below for what
happens instead when this session has more than one group.

For a single-reviewer session: abandon that thread immediately (add to `LEAKED_THREAD_IDS`) and
issue exactly ONE fresh restart — same scope flag as round 1 (`--uncommitted`/`--base`/`--commit`),
never `--resume`, to a brand-new thread. **This restart does NOT re-snapshot or promote a new
candidate onto `SNAPSHOT_FILE`** — deliberately simpler than `--compact`'s own restart, by design:
it dispatches this round's own ordinary Step 1 sequence (`SKILL.md`'s Phase 1 Step 1) exactly like
any round would, just substituting a fresh dispatch for what would otherwise be a `--resume` call:
- The SAME snapshot revalidation every round 2+ already runs, unmodified (re-verify the LOCAL
  `SNAPSHOT_FILE` against the remembered `SNAPSHOT_DIGEST`; hard-stop `🛑 SNAPSHOT INTEGRITY
  FAILURE` on mismatch, exactly like any other round — see `references/snapshot-integrity.md`).
  **This check is local-file-integrity only, not drift detection** — per
  `references/snapshot-integrity.md`'s own "Not a defense against a deliberately changed source"
  section, it never re-observes the real working tree/ref/pasted text, only Claude's own
  already-collected `$SNAPSHOT_FILE`; a repo diff that legitimately changes mid-review is
  invisible to it as long as that file stays intact on disk. So this restart tolerates working-tree
  drift exactly like `--compact`'s own restart already does — the one real difference from
  `--compact`'s restart is that this restart never promotes a new "official" session snapshot onto
  `SNAPSHOT_FILE`; it simply re-reviews whatever the working tree currently looks like.
- The claim ledger digest is carried forward into the fresh thread's own seed, built from the
  durable JSONL log's own reducer state (`references/compaction.md`'s "Digest construction and
  verification" section — a general, `--compact`-agnostic procedure with no JSONL-field footprint
  of its own, reused here as-is) — never from the abandoned thread's own internal state.
- The same original Why + task-specific Scope framing, read from `target.original_scope_framing`
  (`SKILL.md`'s Phase 1 Step 0 — captured unconditionally, every session, since this restart is
  one of its two consumers) — never from `target.focus`.
- A `DISPOSITION` request for any still-open claim, constructed by the existing rule
  (`references/claim-ledger.md` section 4), evaluated against the abandoned thread's own most
  recently completed round.
- The fresh restart's own new thread gets its own fresh receipt schedule
  (`RECEIPT_SCHEDULE_FILE`, per `SKILL.md`'s own schedule-generation procedure) — never reusing
  the abandoned thread's schedule.

**This round's own JSONL line logs what actually happened, not a blanket "every round 2+ is a
resume" assumption.** `target.scope` is the ACTUAL scope flag this restart used (matching round
1's own scope-logging rule), never `"resume"` — `SKILL.md`'s general "`resume` for every round
2+" rule assumed, until this restart existed, that no round 2+ could ever be anything else; this
restart is one of TWO known exceptions to that general rule, the other being `--compact`'s own
restart (`references/compaction.md`), which also logs its actual fresh scope rather than
`"resume"` for the same underlying reason. For `--uncommitted` scope specifically, this round ALSO
reports its own `coverage_source` exactly like a fresh `--uncommitted` dispatch would — but which
role this plays depends on when the restart fires, exactly per `SKILL.md`'s own "Coverage is a
Round-1-only property" section: if the restart occurs AT round 1 itself (the group's very
first-ever dispatch attempt failed with `no_material_reviewed` before any successful round-1
result existed), its coverage is simply part of round 1's own single coverage slot, via that
section's existing "record whichever attempt carried it" rule — no second event. If the restart
occurs at round 2+ (an existing thread that had already produced valid earlier-round results
before going hollow), its own round is a genuine SECOND, independent coverage-establishing event
for the session — not folded into round 1's own already-recorded value, but a separate value for a
separate round number — since this restart is genuinely re-collecting the diff fresh, not
resuming.

**If the ONE fresh restart fails for ANY reason — not just a repeat `no_material_reviewed` — this
is immediate, unconditional exhaustion.** A repeat `no_material_reviewed` (either detection route),
or any other wrapper failure reason whatsoever (`timeout`, `nonzero_exit`, `no_thread_started`,
`bad_args`, or anything else): if this failure response captured a `threadId` (some reasons do,
per `SKILL.md`'s own reason table), add it to `LEAKED_THREAD_IDS` immediately — this restart's own
new thread is abandoned too, exactly like the original hollow thread was, so `SKILL.md`'s Phase 3
terminal path can clean it up alongside the run's other final threads. Since this design never
allocates a candidate snapshot file (no re-snapshot/promotion happens here at all), there is no
candidate-cleanup step needed on this failure path. Then stop and report `⚠️ COULD NOT VERIFY`,
never attempt a third thread — matching this file's own existing round-1-fresh-fallback-then-
give-up precedent. Never a bounded-resume-retry of the new restart's own thread, never a fallback
resume of the abandoned old thread.

This recovery is triggered from `no_material_reviewed` REGARDLESS of what session round number it
occurs at — unlike this file's own general round-1-only fresh-fallback restriction for ordinary
resume-exhausted failures, `no_material_reviewed`'s fresh restart is available on ANY round,
including round 2+, since resuming has already been proven useless and there is no round-2+
"no fresh scope left" concern that applies here (this thread's own accumulated context has zero
remaining value once proven hollow).

**Parallel-mode fallback: no restart attempted, immediate `⚠️ COULD NOT VERIFY` for that group
only.** When this session is running in parallel mode (more than one group), the single-reviewer
restriction above means this recovery is not available at all — a group hitting
`no_material_reviewed` in a parallel round does not attempt any restart. That group immediately
reports `⚠️ COULD NOT VERIFY`, matching this file's own existing pattern elsewhere for "no fresh
scope left, stop and report COULD NOT VERIFY for that group" situations (see the round-2+
no-`threadId` bullet and the resume-exhausted-on-round-2+ bullet above). This is a per-group
terminal outcome, not a whole-round abort — consistent with how this file already treats an
ordinary `ok:false` group failure (see the "Per-group retry (parallel mode)" bullet above): other
groups in the same parallel round are unaffected, their own real, already-collected results are
kept, and the round's overall status is worst-case-wins (`⚠️ COULD NOT VERIFY` for the round, since
that is this file's own mandatory rule whenever any group ends there).

## Compaction-only exception (`--compact`, opt-in — see `references/compaction.md`)

Three narrow, explicitly-scoped exceptions apply ONLY when `--compact` is ON for this session AND
the failure in question occurs on a compaction attempt's own candidate thread specifically —
every rule in this file continues to apply completely unmodified to the round's own REAL group
(the existing/OLD thread), and to every session where `--compact` is OFF:

1. **This file's own exhausted-retry MANDATORY terminal-outcome rule above (`⚠️ COULD NOT
   VERIFY`) does NOT apply to a failure occurring WITHIN a self-contained compaction attempt on a
   NEW candidate thread.** `references/compaction.md`'s own "Restart mechanism"/"On failure"
   sections deliberately absorb such a failure into "fall through to the fallback dispatch on the
   OLD, still-alive thread" rather than surfacing it as the round's own terminal status — a
   compaction attempt is not "a group" in this file's own sense; it is an internal sub-step of
   producing that round's one real outcome. This file's own existing rules for a REAL group's
   `ok:false` response (every bullet above) are otherwise entirely unaffected.
2. **This file's own no-threadId-fresh-retry and fresh-B escalation rules — scoped above to a
   group's OWN true first-ever attempt, "only possible on round 1" — are keyed on CANDIDATE-level
   thread history for a compaction attempt's candidate A specifically, never on the session's own
   round-index.** A compaction restart's own candidate dispatch is structurally always at session
   round 2 or later, yet candidate A is its own independent "first attempt" lifecycle for these
   specific mechanics, by construction, regardless of what round number in the session it
   actually occurs at — see `references/compaction.md`'s "Retry topology" section for candidate
   A's full three-bullet decision tree. This exception is scoped to candidate A ONLY, never to a
   compaction attempt's thread B, which gets NONE of this file's retry machinery at all (single-
   shot: it either succeeds, or the whole compaction attempt is immediately exhausted) — and never
   to an ordinary group's own genuine round-1 attempt, which keeps this file's literal round-1
   scoping exactly as written.
3. **This file's own `no_material_reviewed` recovery (its "never resume-safe, one bounded fresh
   restart" rule) does NOT apply when the failure occurs on a compaction attempt's own candidate
   thread specifically.** A compaction candidate's own dispatch returning
   `material_reviewed:false` (the wrapper-level route) or a receipt-mismatch (Claude's own Phase 2
   route) is, like exception 1 above, an internal sub-step of producing that round's one real
   outcome, not "a group" in this file's own sense — `references/compaction.md`'s own "On
   failure" section already fully owns this case: discard the candidate, fall through to the
   fallback `--resume` dispatch on the OLD, still-alive thread, exactly like any other
   candidate-dispatch failure reason. This does NOT contradict `no_material_reviewed`'s own
   "never resume a proven-hollow context" premise — the thread being resumed here is the
   PRE-COMPACTION old thread, which never itself returned `no_material_reviewed`; only the
   abandoned CANDIDATE did, and it is discarded, never resumed. `no_material_reviewed`'s own
   "one bounded fresh restart" recovery applies ONLY to a REAL group's own main thread going
   hollow — never to a compaction candidate's own dispatch, which compaction's own candidate
   lifecycle already fully handles.

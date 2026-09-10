# Opt-in thread compaction (`--compact`) — reference

> Read this file in full because Phase 0 Step 0 determined `--compact` is ON for this session.
> A session where `--compact` is OFF (the default) never triggers anything in this file — zero
> added behavior, zero added JSONL fields, exactly the existing resumable-thread behavior
> documented everywhere else in this skill.

## What this fixes

`run-ccs-review.sh` keeps one resumable Codex thread per reviewer alive for a whole `/ccs` run,
`--resume`ing it every round after the first rather than re-sending the diff. This avoids
re-ingestion cost per round, but nothing prunes the thread's own accumulated history — every
round's own `execution.usage.input_tokens` grows monotonically, round after round, for the life
of the thread. Real measured data from the longest `/ccs` run observed to date (17 rounds to
CLEAN) showed growth from ~520,000 tokens at round 1 to over 60,000,000 by round 17 — front-loaded
(round 1→10 is ~60x), with elapsed wall time NOT tracking token count monotonically (cache hit
rate, not raw size, appears to dominate latency once a thread is this large). The concrete,
structural problem this feature solves is **unbounded token growth with no pruning mechanism**,
not latency specifically.

**What was ruled out, and why:** `codex exec fork` (inherits the parent thread's ENTIRE history —
already measured at 2.14x the tokens of independent dispatch for a different cost problem, see
`docs/2026-09-05-codex-stream-review-improvement-roadmap-design.md`'s "Phase 4 Item 1 canary
results" — carries the same bloat forward, so it cannot serve a compaction goal either); asking
the same resumed thread to "forget" via plain `--focus` text (no Codex CLI primitive shrinks a
thread's own stored server-side context — confirmed against `codex exec`/`codex exec resume`/
`codex queue`/`codex resume`); Codex's own native automatic compaction (real `"type":"compacted"`
events exist in local session rollout logs, but did NOT fire even once during the real 17-round
run measured above, despite that thread growing far larger than a session where it fired 12
times — not something `/ccs` can rely on or control either way).

## The `--compact` flag

A fourth independent, optional `/ccs` prefix flag, alongside `--capture-evidence`,
`--keep-evidence`, and `--quick` — parsed by the SAME Phase 0 Step 0 prefix-stripping loop in
`SKILL.md`, its own independent boolean (`COMPACT_MODE`); any subset of the four may be ON in any
order (see `SKILL.md`'s Phase 0 Step 0 for the exact updated parsing rule — Task 20 of this plan
amends it to include `--compact`). **No changes to `run-ccs-review.sh` itself are required** —
compaction is entirely a `SKILL.md`/reference-file-level orchestration technique built from
primitives the wrapper already exposes (a fresh dispatch, a `--cleanup` call) — the same
relationship `--quick`/`--keep-evidence` already have to the wrapper.

Starting as opt-in (not always-on, unlike snapshot integrity/the claim ledger) is deliberate:
this is a genuinely new failure surface (see "Restart mechanism" and "Digest construction" below)
that has not yet been validated against real reviews the way the always-on mechanisms have.

## Trigger

**Round-ownership terminology.** Call the round whose completed usage triggers this check the
TRIGGERING round. Compaction, when triggered, is attempted for the VERY NEXT round dispatched
afterward — call it the COMPACTION round. Every later use of "round R" in this file's "Restart
mechanism" section, and everywhere else in this file discussing the compaction attempt itself,
means the COMPACTION round — never the triggering round the decision was based on. The triggering
round was already processed and logged normally, before this check ever runs; nothing about it is
retroactively changed.

**When this check runs.** After EVERY completed round — including round 1 itself: round 1's OWN
resulting thread is already a real, resumable thread the moment round 1 completes, and its usage
is already known then, so restricting the check to round 2+ would force at least one wasted
`--resume` turn against an already-oversized round-1 thread whenever round 1 alone exceeds the
threshold. If `COMPACT_MODE` is ON: check that just-completed round's own
`execution.usage.input_tokens` against `COMPACT_THRESHOLD = 8,000,000` (a fixed constant, not
user-configurable in v1 — see "Scope (v1)" below). If exceeded, compact before building the next
round's dispatch — if round 1 itself triggers this, round 2 becomes the COMPACTION round
immediately (running the existing mandatory round-2+ active-snapshot revalidation first, per
"Restart mechanism" step 0 below, then the fresh compaction path), never a wasted ordinary
`--resume` first.

**Handling missing OR malformed usage data.** `execution.usage.input_tokens` is documented as
best-effort and may be entirely absent even on a genuinely successful round (see
`references/execution-telemetry.md`). If the most recently completed round's response has no
`execution.usage.input_tokens` to check: skip the threshold check for this round (never treat
missing data as "under threshold," which would make an opt-in `--compact` session silently never
compact at all, and never as "over threshold" either) — log one narration line noting the check
was skipped, and re-attempt the check normally at the next round where usage data is available.
A PRESENT value must also be validated before comparison, never trusted as-is: `input_tokens`,
when present, must additionally be validated as a non-negative integer before ever being compared
to `COMPACT_THRESHOLD` — a string, `null`, a negative number, or any other non-integer shape is
treated exactly like the ABSENT case (skip, narrate, re-attempt next round). This matters because
`jq`'s own type-ordering ranks any string above any number, so a raw comparison against a
malformed value like `"not-a-number"` would otherwise spuriously compare GREATER than
8,000,000 and trigger an unnecessary, expensive fresh restart.

**Benefit-free-restart-loop guard (the `COMPACTION_BASELINE_TOKENS` circuit breaker).** A
successful COMPACTION round is, itself, just another completed round — its own usage gets
checked by this same trigger. If the underlying diff/claims content is simply large enough that
even a FRESH restart's own single-turn usage is already at or above `COMPACT_THRESHOLD` — not
because of accumulated resumed-thread history, but because the content itself is that big — then
the very next round would trigger compaction again, and again, every round, each one paying the
full fresh-restart cost with ZERO benefit. Fixed: record `COMPACTION_BASELINE_TOKENS` — the
COMPACTION round's OWN, freshly-restarted `execution.usage.input_tokens` (never the TRIGGERING
round's own usage — the triggering round's usage is, by definition, already `>=
COMPACT_THRESHOLD`, since that is what triggered it; recording that value as the baseline would
make the check below true unconditionally, disabling compaction after every single first
successful restart) — every time a compaction round's OWN dispatch succeeds.

If THAT (the compaction round's own, freshly-restarted) baseline is itself already `>=
COMPACT_THRESHOLD`, compaction is disabled for the remainder of the session (narrated once,
clearly, the same way the byte-budget exhaustion limitation is — see "Byte-budget preflight"
below) — record `compaction_disabled_reason: "baseline_at_or_above_threshold"` on that same
round's own JSONL line (see "Logging" below for the full durability rule). If the fresh baseline
IS comfortably under threshold (the common, intended case), ordinary accumulation-based
triggering simply resumes for future rounds exactly as designed, no special-casing needed.

**Fail closed when the compaction round's OWN telemetry is unusable — never assume the restart
helped.** If the compaction round's own `input_tokens` is unusable (per the missing/malformed
rule above), `COMPACTION_BASELINE_TOKENS` is NOT left unset — it is treated IDENTICALLY to a
baseline that IS `>= COMPACT_THRESHOLD`: record `compaction_disabled_reason: "baseline_unusable"`
and disable compaction for the remainder of the session. An unverifiable baseline is treated as a
failed one, not a free pass.

**A second circuit breaker for repeated FAILED fresh-dispatch attempts.** The baseline guard
above only ever engages after a compaction dispatch SUCCEEDS. Every `ok:false` compaction
attempt — including `timeout` (a real possibility for a genuinely large diff, given the
wrapper's own default fresh-dispatch deadline of 1800 seconds) and `nonzero_exit` — instead falls
through to the normal fallback `--resume` (see "On failure" below), with the threshold check
simply running again next round. A diff large/slow enough to reliably time out the fresh dispatch
would otherwise trigger another identical, doomed fresh attempt every single subsequent round.

Fixed: a second session-scoped counter, `COMPACTION_CONSECUTIVE_FRESH_FAILURES`, increments by
one every time a compaction attempt's own fresh dispatch (after exhausting whatever bounded retry
the retry topology below already applies to that one round's own attempt) still ends up
`ok:false` and falls through to the fallback — and resets to `0` every time a compaction attempt
succeeds. This counter must ALSO increment on a purely LOCAL pre-dispatch failure, not only a
wrapper `ok:false` — a persistent local problem (the candidate's own `git diff`/`shasum`
collection failing, or the byte preflight's own authoritative untracked-file collector invocation
failing) falls straight through to the fallback WITHOUT ever reaching a real wrapper dispatch at
all, so this counter is broadened to increment on ANY compaction attempt that falls through to
the fallback without completing a real successful compaction — local collection/hash failure,
local preflight-collector failure, OR a wrapper `ok:false` alike — the one exception being
`byte_budget_exceeded`, which gets its own dedicated, immediate latch (see "Byte-budget
preflight" below) precisely because a successful measurement over budget is a distinct,
already-fully-diagnosed cause that doesn't need this counter's slower two-strikes bound.

Once this counter reaches `COMPACTION_MAX_CONSECUTIVE_FAILURES = 2`, compaction is disabled
for the remainder of the session — via the same `compaction_disabled_reason` mechanism below,
with the value `"repeated_fresh_dispatch_failure"` — a small, deliberately conservative bound
consistent with this design's other fixed, non-configurable limits (`COMPACT_THRESHOLD`,
`CLOSED_CLAIM_LIMIT`, `COMPACT_BYTE_BUDGET`).

**Durable recording — the counter's own intermediate value, not only the final "disabled"
decision.** Every round whose own compaction attempt fails (falls through to the fallback)
durably records the counter's CURRENT value (after incrementing) as a new field,
`compaction_attempt_failure_count`, on that round's own line — this is a pre-append-decided
value, exactly like `compaction_attempt_failed_thread` (see "Retry topology" and "Ordering on
success" below), since the failure is known before that round's own real (fallback) result is
ever logged. Without this, a session recovering from a lost in-memory state after exactly ONE
fresh-dispatch failure — not yet two — would reconstruct the counter as `0`, silently doubling
the effective failure budget across that recovery event.

**A successful compaction's own reset must be durably recorded too.** A successful compaction
round (the same round already appending `compacted_from_thread` and the `snapshot_digest_*` pair
— see "Restart mechanism" below) ALSO durably records `compaction_attempt_failure_count: 0` on
that SAME line, explicitly representing the reset rather than leaving it implicit. Without this,
a state-loss recovery reading only the latest recorded value across the log could find an OLDER
nonzero count from before a since-succeeded reset and restore it as if no reset had ever
happened — the very next fresh-dispatch failure after that recovery would then reach `2` and
wrongly disable compaction, even though it is really only the first consecutive failure since the
last success. Continuity recovery reconstructs `COMPACTION_CONSECUTIVE_FRESH_FAILURES` from
whichever of these two fields — a failure's incremented value or a success's explicit `0` — was
recorded MOST RECENTLY across the whole session log (by round order, not by which field name it
is), defaulting to `0` only when neither has ever been recorded at all.

**The "disabled for the rest of the session" decision must be durably logged and recoverable —
never in-memory-only.** The compaction round that sets this latch (because its own baseline was
`>= COMPACT_THRESHOLD`, its own telemetry was unusable, `COMPACTION_CONSECUTIVE_FRESH_FAILURES`
reached its bound, OR the byte preflight below found the exact assembled payload over
`COMPACT_BYTE_BUDGET`) durably records a new field, `compaction_disabled_reason` (a short
string — exactly one of `"baseline_at_or_above_threshold"`, `"baseline_unusable"`,
`"repeated_fresh_dispatch_failure"`, or `"byte_budget_exceeded"`), on that SAME round's own JSONL
line — never a separate append. `SKILL.md`'s continuity recovery (see "Review history log" →
"Read (continuity)") is extended, alongside its existing reconstruction of
`GROUP_THREADS`/`LEAKED_THREAD_IDS`/claim state, to also check whether ANY prior round in the
session's log ever recorded this field — if so, compaction is reconstructed as disabled for the
rest of the session, exactly matching whatever the original in-memory decision would have been,
never silently forgotten and re-enabled.

## What gets preserved — full fidelity for open claims, one line for closed ones

Reuses the claim ledger's existing reducer (`references/claim-ledger.md` section 8) over the
session's own JSONL log — no new data structure. For every claim_id that has ever appeared this
session:
- **Still open** (no `claim_closures[]` entry): included verbatim, using the claim's MOST RECENT
  occurrence, not necessarily its origin — `file`/`line`/`severity`/`summary`/`evidence`,
  unabridged. This mirrors how Claude Code's own context compaction keeps the most
  currently-relevant material closest to full fidelity rather than summarizing everything
  uniformly. **Disclosed limitation:** this text (including its `file`/`line`) reflects where the
  claim was most recently raised, which may now be stale if the file has changed shape since —
  not treated as an enforcement problem, since Codex is already instructed, in every round, to
  re-read the actual current file rather than trust diff/context text as-is.
- **Resolved or retracted:** collapsed to one line, built directly and deterministically from its
  own `claim_closures[].marker_reason` (already exactly one sentence, by the existing
  `DISPOSITION` marker grammar — see `references/claim-ledger.md` section 4) — no new LLM call,
  no summarization step, zero added cost or design surface. Example: `claim_id g1:f3 — RESOLVED
  (round 5): the null check now covers the empty-array case, confirmed by re-reading the current
  file.` Bounded — see "Closed-claim section has its own ceiling" below.

**Most-recent, not origin.** For each open claim_id, use the SAME "most recent occurrence" lookup
the quick-mode severity check already performs (`SKILL.md`'s own Guards section) — find that
claim_id's latest `claude_verification[]` entry, read its own `finding_id`, and use THAT
finding's `file`/`line`/`severity`/`summary`/`evidence` (falling back to the origin finding only
for a claim that has never been re-raised, where origin IS the most recent). Additionally append
one line noting the most recent `evidence_delta` (when present) and Claude's own most recent
`action`/`rationale` for it, so the fresh thread sees "here is where this stood," not just the
opening complaint.

## Digest construction and verification — structured data first, prose rendering last

**Never re-parse the rendered prose.** Building the digest as prose directly, then re-parsing
that same prose to verify nothing was dropped, is unsound: a claim's own verbatim `evidence` text
can legitimately contain a quoted example, a code block, or prose that itself contains a
column-zero-anchored string shaped exactly like another claim's own `DISPOSITION` marker — the
exact class of ambiguity the existing marker parser avoids via fencing/cardinality rules that this
simpler use case does not need to reinvent. Instead:

1. Compute the reducer's own open-claim-id list (`references/claim-ledger.md` section 8) as
   structured data (e.g. a `jq` array), not prose.
2. For each element of that array, resolve its `{claim_id, file, line, severity, summary,
   evidence}` fields (via the same most-recent-occurrence lookup above) — do NOT render
   `block_text` yet.
3. **Verification is a structural check on this data, BEFORE any prose is ever rendered** — both
   a KEY check and a CONTENT-COMPLETENESS check:
   - **Key check:** the number of resolved objects equals the reducer's own open count, and their
     `claim_id` keys are exactly the reducer's own open-id set (set equality).
   - **Content-completeness check — TYPE/PRESENCE, not non-emptiness:** every one of those
     objects has `summary`, `evidence`, and `file` present as strings (per
     `schemas/review-verdict.schema.json`'s own field types) — an empty string IS a legal value
     for these three and is NOT rejected here. `severity` must be one of the schema's own legal
     values (`"low"`/`"medium"`/`"high"`/`null`). `line` must ALSO be checked — present, and
     either `null` or an integer `>= 1`, matching `schemas/review-verdict.schema.json`'s own exact
     constraint on that field.
   - Neither check can be spoofed by anything a rendering step might later produce, because
     neither ever inspects rendered prose — both read only the resolved fields, sourced directly
     from the finding record the reducer already resolved.
4. **Only once step 3 passes (both checks) is `block_text` computed** — as a pure, canonical
   function of the ALREADY-VALIDATED fields from step 2, in the same step, never a separately/
   independently rendered value: a fixed template, `"OPEN CLAIM <claim_id>:\nfile:
   <file>\nline: <line>\nseverity: <severity>\nsummary: <summary>\nevidence: <evidence>"`. The
   final flattening (one deterministic concatenation, a 1:1 map with nothing filtered) produces
   the prose sent to Codex. `OPEN CLAIM <claim_id>:` remains as a heading purely for Codex's own
   readability — it is never re-parsed by `/ccs`'s own code again after this point.
5. On any structural or content-completeness mismatch in step 3: log a one-line narration note,
   and skip straight to the normal `--resume` fallback (see "On failure" below) — never attempt
   to dispatch an unverified or incomplete digest.

## Closed-claim section has its own ceiling

The closed-claim one-line summaries have no bound by default, and the count of closed claims only
ever grows across a session — in a claims-heavy review, this section could itself grow large
enough to defeat compaction's own purpose (keeping the round's own prompt small) and to
meaningfully slow down or add unnecessary cost to the compaction dispatch itself. Fixed with a
small, bounded rule (no LLM
summarization): include the `CLOSED_CLAIM_LIMIT = 20` most-recently-closed claims' one-line
summaries verbatim (ordered by `source_round` descending), and collapse everything older into a
single line: `<N> additional claims resolved/retracted before round <R>; see the session's own
JSONL log for full detail.` This bounds the closed-claim section's own contribution to a small,
fixed COUNT regardless of how many rounds a session eventually runs.

**Disclosed, accepted residual limitation.** The closed-claim cap bounds COUNT (20 entries), not
bytes — the marker-reason grammar requires only a non-empty sentence, with no length limit, so 20
valid-but-long closure reasons are not actually "small." Open claims remain fully unabridged with
no count or byte bound. So a session with a large number of open/closed claims, one exceptionally
large finding, OR a large re-collected diff/artifact can still produce a rendered compaction
prompt large enough to be slow, costly, or (depending on whatever real limit the underlying
model/CLI itself enforces) outright rejected — see "Byte-budget preflight" below for how this
design guards against that residual risk before ever dispatching.

## Byte-budget preflight

**Measure via the authoritative collection path, never an approximation.** For `--uncommitted`
scope, the diff/untracked-content component is measured by reusing the SAME authoritative
collection the wrapper itself performs (the actual `collect_untracked_files.py`-equivalent
content collection), never the candidate snapshot file — that file deliberately records
untracked files by NAME ONLY (see `references/snapshot-integrity.md`), never their real content,
so a name-only estimate would silently undercount. For `--commit` scope specifically, ALSO
measure the commit's own patch content authoritatively — re-running the SAME `git show`/`git
diff` invocation (through the SAME anchored, sanitized pattern used elsewhere in this skill) the
wrapper itself will use for `target.resolved_commit_sha` (see "Restart mechanism" below) — since
every fresh `--commit` dispatch embeds that patch in the prompt exactly like `--uncommitted`/
`--base` embed their own diffs. Only non-repo-artifact scope is genuinely focus-text-only for
this preflight, since `CLEAN_REPO_DIR`'s guaranteed-empty diff means there is no separate
diff-content component to measure at all.

A nonzero exit from either the `--commit`-scope `git show`/`git diff` measurement OR the
authoritative untracked-content collector invocation is never treated as "zero bytes" — either
is treated exactly like any other compaction failure (log the narration, fall through to the
normal `--resume` fallback) immediately, without ever attempting the real dispatch that would
only hit the identical failure.

**Measure the focus text exactly, never estimate it.** Since Claude constructs the exact,
complete focus text (digest + Why/Scope/SCOPE-CONSTRAINT + original artifact text, when
applicable — see "Restart mechanism" step 4 below) before ever dispatching it, the preflight
measures its REAL byte length directly (e.g. `wc -c` on the assembled focus content) — an exact
count, not an estimate. The total checked against `COMPACT_BYTE_BUDGET = 120,000` is: this exact
focus-text byte count, PLUS the diff/untracked-content (or `--commit` patch) byte count from the
authoritative collection above. `120,000` is this feature's OWN self-imposed ceiling for a single
compaction attempt's rendered prompt — a conservative, practical bound chosen to keep a compaction
dispatch itself fast and inexpensive, independent of whatever real limit the underlying model/CLI
enforces. The base skill's own former self-imposed pre-dispatch guard for an ORDINARY round's
prompt has been removed entirely (see `references/retry-guards.md`'s "Compaction-only exception"
section), so this preflight is not defending against any documented wrapper-side wall — it exists
purely so a compaction ATTEMPT, whose entire purpose is shrinking the round's own prompt, never
itself becomes another oversized dispatch.

**Re-run before EVERY re-collected candidate, not only the original attempt.** The no-threadId
fresh retry and thread B's own dispatch (see "Retry topology" below) each re-collect a genuinely
fresh candidate — a newly re-collected candidate's own byte size can legitimately differ from the
original measurement (the source may have grown in the meantime). This preflight therefore
re-runs before EVERY fresh dispatch that re-collects a candidate — the original attempt, the
no-threadId fresh retry, and thread B's own dispatch alike.

**A real latch, not merely an implicit "it'll fail the same way again" claim.** Exceeding
`COMPACT_BYTE_BUDGET` sets `compaction_disabled_reason` to `"byte_budget_exceeded"` — the SAME
durable latch mechanism as the other two triggers (see "Trigger" above), naming WHICH component
(claims vs. diff/artifact) drove the estimate over budget where determinable. THIS SAME attempt —
the one whose own preflight measurement just exceeded the budget — is treated exactly like any
other compaction failure: it falls through to the normal `--resume` fallback (see "On failure"
above) immediately, without ever attempting the real fresh dispatch on a payload already known to
be too large. Once set, every later triggering round's threshold check no-ops immediately, per the
existing latch contract — skipping the local re-collection and re-measurement entirely, not merely
skipping the network dispatch. This exceeding-budget failure does NOT increment
`COMPACTION_CONSECUTIVE_FRESH_FAILURES`
(see "Trigger" above) — it is a distinct, already-fully-diagnosed cause with its own immediate
latch, not the slower two-strikes bound. A future revision could address the root cause (e.g.
capping open-claim evidence length, or reintroducing LLM summarization) — explicitly out of scope
for v1 (see "Explicitly out of scope for v1" above).

## Restart mechanism

There is no way to shrink an existing thread's own context, so compaction means **abandoning the
old thread and starting a genuinely fresh one**. A compaction attempt is entirely self-contained —
its own success or failure is never itself reported as this round's terminal outcome (see
"Failure isolation from the round loop" below).

### Step 0 — the existing snapshot revalidation always runs first, unconditionally

Round R's own pre-dispatch snapshot check (`references/snapshot-integrity.md`) — validating the
CURRENTLY ACTIVE `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST`, unrelated to anything compaction is about to
do — runs exactly as it does for every other round, BEFORE the threshold check that decides
whether to attempt compaction at all. If that existing check fails, the existing
`🛑 SNAPSHOT INTEGRITY FAILURE` hard stop fires immediately, exactly as today — a corrupted active
snapshot is never silently "fixed" by proceeding into a compaction attempt that would replace it
with a fresh candidate; that would hide a real integrity failure rather than report it.

**This "always runs first" is about ORDINARY per-round dispatch, not about reconstructing the
remembered facts it checks against — those two are sequenced the other way around during
continuity recovery.** This step's job is "does the ACTIVE file still match what Claude currently
remembers," and it assumes that remembered value is already correct going in. Reconstructing what
that remembered value SHOULD be, after an interruption, is the job of the post-append recovery
logic instead (see "Retired- and provisional-snapshot durability" below) — a one-time,
continuity-recovery-only step, run once, BEFORE this step's own check is ever invoked for the
first round dispatched after that recovery, triggered by searching the WHOLE session log for the
most recent round that ever recorded compaction lineage, never by checking only whether the
LATEST completed line happens to be one (once even one ordinary round completes after a
successful compaction, "the latest line" is no longer that compaction's own line). Once that
recovery step has updated the remembered `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` (or confirmed no
update was needed), this step proceeds exactly as already described, now correctly informed.
Outside of continuity recovery — the ordinary case, no interruption having occurred — there is
nothing to reconcile and this step simply runs first as originally stated.

### Step 1 — build and verify `COMPACT_DIGEST`

Build `COMPACT_DIGEST` via the structured-data-first construction in "Digest construction and
verification" above; abort to the normal `--resume` fallback (see "On failure" below) immediately if its
own structural verification fails.

### Step 2 — non-repo-artifact sessions are a SEPARATE case, handled BEFORE the scope branches below

A non-repo-artifact session (`references/non-repo-artifact.md`) dispatches `--uncommitted`
against an intentionally EMPTY `CLEAN_REPO_DIR` — the actual reviewed material lives only in
`--focus` text, never in the diff. If compaction naively re-collected "the diff" here, it would
recollect an empty diff and the fresh thread would never see the artifact at all. Fixed: for a
non-repo-artifact session, compaction (a) allocates NO new snapshot — like `--commit` scope, the
ORIGINAL round-1 snapshot (which already holds the exact pasted artifact bytes for this session
type, per `references/snapshot-integrity.md`) remains active and untouched throughout; (b) the
fresh restart's focus text includes the ORIGINAL ARTIFACT TEXT in addition to `COMPACT_DIGEST` —
exactly mirroring how round 1 itself had to paste the artifact into focus text for this session
type.

**Bind the dispatched bytes to the SAME verified copy the hash-check ran against — never a
separate re-read.** Read `SNAPSHOT_FILE`'s content into a captured copy exactly ONCE, at this
step — hash that SAME captured copy and confirm it equals `SNAPSHOT_DIGEST` before using it for
anything. If it matches, embed that verified copy's content into the fresh restart's focus text
(never re-open or re-read the original file a second time for this purpose). If it does NOT
match, this is the EXISTING `🛑 SNAPSHOT INTEGRITY FAILURE` hard stop, exactly as an ordinary
round's own pre-dispatch revalidation already handles.

**Revalidate `CLEAN_REPO_DIR`'s own cleanliness before trusting it — never simply assumed.**
`CLEAN_REPO_DIR` is created once and reused for the whole session — if anything unexpected
polluted it since round 1, a fresh dispatch against it would collect REAL tracked/untracked
content and silently mix it into what is supposed to be a strictly artifact-only review.
`git status`, in ANY combination of flags, can never prove the directory holds nothing —
committed content is invisible to it entirely (confirmed live: `git status --short
--untracked-files=all --ignored=matching` reports changes RELATIVE TO `HEAD` and produces EXACTLY
ZERO bytes of output against an ordinary clean repo with real committed files, while
`git ls-files`/`git rev-parse --verify -q HEAD` both show real content is present).

Cleanliness means ALL EIGHT of the following checks pass — a bare, freshly-`git init`'d,
genuinely-independent, non-symlinked, self-contained git repo directory with no files, no
commits, no borrowed metadata, and no borrowed objects:

1. **No stray entries.** The directory contains NO entries at all other than `.git` itself — a
   literal directory listing, e.g. `find "$CLEAN_REPO_DIR" -mindepth 1 -maxdepth 1 ! -name .git`,
   through the same anchored/sanitized invocation pattern as every other direct git-adjacent call
   in this skill, expected to produce no output.
2. **Genuinely inside a work tree.** `git rev-parse --is-inside-work-tree` expected to output
   EXACTLY `true`.
3. **HEAD has never been given a commit.** `git rev-parse --verify -q HEAD` expected to FAIL/exit
   nonzero (an unborn HEAD).
4. **`CLEAN_REPO_DIR`'s own literal path is NOT a symlink.** `[ ! -L "$CLEAN_REPO_DIR" ]` —
   otherwise `CLEAN_REPO_DIR` could be swapped for a symlink pointing at a DIFFERENT, also-empty,
   also-commit-less git repo, and checks 1-3 would still report clean while every dispatch
   actually operated against a completely different directory.
5. **`CLEAN_REPO_DIR` is the ROOT of its own independent repository, not merely nested inside
   one.** `git rev-parse --show-toplevel` output EQUALS `CLEAN_REPO_DIR`'s own canonical path
   exactly — `--is-inside-work-tree` alone only confirms the path lives SOMEWHERE inside SOME
   working tree (confirmed live: a nested subdirectory of an unrelated repository also reports
   `--is-inside-work-tree=true`, while its own `--show-toplevel` correctly resolves to the PARENT
   repository, not itself).
6. **`.git` itself is a genuine, self-contained directory.** `[ -d "$CLEAN_REPO_DIR/.git" ] && [
   ! -L "$CLEAN_REPO_DIR/.git" ]` — never a plain file (the standard git-worktree gitfile format,
   `gitdir: <path>`) and never a symlink; both would let a linked git WORKTREE's own
   `--show-toplevel` return its own local root (satisfying check 5) while its `--git-dir`/
   `--git-common-dir` point OUTSIDE it, into a completely different repository's shared metadata.
7. **No `git-dir`/`common-dir` metadata borrowing.** `git rev-parse --git-dir` AND
   `git rev-parse --git-common-dir`, each resolved to its own canonical absolute path, must BOTH
   equal `CLEAN_REPO_DIR/.git`'s own canonical absolute path — this subsumes both the
   gitfile/symlink indirection (check 6) and a separate, independent `commondir`-file indirection
   (per git's own `gitrepository-layout(5)`: a `commondir` file inside an otherwise entirely
   ordinary, non-symlink `.git` directory sets the effective `GIT_COMMON_DIR` to its own target,
   confirmed live to pass every check through check 6 while `git rev-parse --git-common-dir`
   reveals the borrowed external path).
8. **No object-store borrowing.** `CLEAN_REPO_DIR/.git/objects/info/alternates` must NOT exist
   (or, if present, must be empty) — per git's own `gitrepository-layout(5)` documentation, this
   file lets git borrow OBJECTS from a listed external repository's own object store, entirely
   independent of `--git-dir`/`--git-common-dir` (confirmed live: with such a file present, all
   seven checks above still pass while `git cat-file -p` successfully reads real content from the
   foreign repository's own object store).

**A candid scope statement.** This checklist cannot claim to be an EXHAUSTIVE, adversarially-
hardened defense against every conceivable git extension point (hooks, submodules, custom refs,
sparse-checkout redirection, and others not yet enumerated) — closing each CONFIRMED gap as it is
found is the practical, honest bar this design holds itself to. `CLEAN_REPO_DIR` is created once
by this skill's own trusted Phase 0 setup; these checks exist to catch UNEXPECTED, ACCIDENTAL
drift, not to defend against a deliberately adversarial actor with enough local access to plant a
crafted `.git` directory in the first place (that same actor would have comparable access to
sabotage the session through many other paths this design has no power to close either). A
residual, disclosed risk this does not close: `scripts/lib/git-safe.sh`'s own sanitization
protects the WRAPPER's own git invocations specifically — it says nothing about whatever Codex
itself might independently choose to read or execute from `.git/config` during its own
investigation of this same CWD; hardening Codex's own sandboxed behavior against a hypothetically
malicious `.git` directory is a base-sandbox-model concern beyond this design's own scope. A
second residual, disclosed risk: a check-then-use race remains between these eight checks
completing and the wrapper's own LATER, separate re-resolution of the same `$CWD` pathname (once
for its own `git -C "$CWD"` calls, once for its `cd "$CWD"` launch step) — inherent to any
"verify a pathname locally, then hand it to a separately-invoked process" pattern, accepted as a
narrow, low-probability window. This compaction-owned recheck is the ONLY point at which
`CLEAN_REPO_DIR`'s cleanliness is EVER verified anywhere in this whole mechanism — round 1's own
very first artifact dispatch, and any session that never triggers compaction at all, remain fully
exposed to this same pollution risk with NO check of any kind, a real, disclosed, PRE-EXISTING
gap in the base mechanism itself, not introduced or widened by compaction, and out of scope for
this feature to close (doing so would mean adding a new check to the base skill's own Phase 0/
Phase 1 setup, which this file does not own).

If any of the eight checks is not clean, this is treated exactly like any other compaction
failure (log the narration, fall through to the normal `--resume` fallback in "On failure" below) —
never dispatch against a `CLEAN_REPO_DIR` whose emptiness wasn't just reconfirmed. Only once this
check passes does the `--uncommitted` dispatch against `CLEAN_REPO_DIR` proceed, producing an
empty diff as designed, with the wrapper's own no-diff branch falling back to reviewing the focus
text — now containing both the artifact and the digest.

**This recheck runs before EVERY separate fresh dispatch for a non-repo-artifact session** — the
original attempt, the no-threadId fresh retry (see "Retry topology" below), and thread B's own
fresh dispatch alike — never assumed still valid from an earlier check moments or minutes in the
past. **Also required immediately before the "On failure" fallback dispatch**, whenever this session is
non-repo-artifact: if it fails there, this is logged as a disclosed risk, never a hard stop, since
the fallback is this round's own real, required outcome with no further fallback beneath it.
Ordinary, non-compaction `--resume` rounds sharing this identical base-skill property (no round
is otherwise ever forced to recheck `CLEAN_REPO_DIR`'s cleanliness before an ordinary resume) are
an inherited, pre-existing limitation this feature does not newly introduce.

**Fail CLOSED wherever a real alternative still exists.** Candidate A's own resume-retries and
the bullet-2 same-thread retry (see "Retry topology" below) treat a failed recheck exactly like
any other compaction failure — abandon this compaction attempt, fall through to the "On failure"
fallback, never dispatch into a KNOWN-polluted directory. This abandonment unconditionally adds
A's own already-known thread id to `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` before
falling through — this is a LOCAL, pre-dispatch check failure, never a wrapper response, so the
abandonment is entirely local knowledge, nothing to discover from a response. The "log and
continue, disclosed risk" treatment is reserved ONLY for the "On failure" fallback dispatch itself and
any retry OF that fallback — the true last resort, genuinely having nowhere further to fall back
to. The ORIGINAL fresh dispatches (candidate A's first attempt, the no-threadId retry, thread B)
keep their existing hard "fall through to the normal compaction failure path" behavior when this
recheck fails.

**A non-repo-artifact round is always single-group `main` anyway** (see "Scope (v1)" above and
`references/non-repo-artifact.md`), so this recheck never interacts with any group-count merge
logic.

### Step 3 — repo-diff sessions: snapshot candidate lifecycle

Re-collection handling depends on round 1's original scope, as before.

**Disclosed limitation, inherited from round 1's own identical property, not new to
compaction.** The candidate below is collected and hashed by Claude's OWN local git invocation,
BEFORE the wrapper is ever dispatched; the wrapper then independently re-collects its own
`DIFF_TEXT` internally, at its own later moment, since it accepts no snapshot/payload argument at
all — if the source changes in that gap, the candidate Claude hashed and the content the fresh
thread actually reviewed can diverge, and every later verification of the candidate (including
the live pre-promotion checks in "Ordering on success" below) only proves the candidate itself
wasn't corrupted AFTER Claude collected it, never that it equals what the dispatch truly
reviewed. This is especially pronounced for untracked files, whose CONTENT is collected by the
wrapper but whose entry in this design's own snapshot may only track their names. This is the
SAME accepted non-goal `references/snapshot-integrity.md` already documents for round 1's own
original collect-then-dispatch gap ("not a defense against a deliberately changed source") —
compaction inherits this exact property unchanged.

- **`--uncommitted`:** re-collect the diff into a NEW candidate `SNAPSHOT_FILE`, hash it into a
  candidate `SNAPSHOT_DIGEST` (same mechanism as `references/snapshot-integrity.md`'s own Phase 0
  step 5 / Phase 1 post-sizing allocation) — the working tree may genuinely have changed since
  round 1, so this is the one case re-collection is meaningful for.
- **`--base <ref>`:** re-collect `${ref}...HEAD` again into a new candidate the same way — this
  DOES pick up any new commits landed on `HEAD` since round 1, but does **not** reflect
  uncommitted working-tree changes (disclosed limitation: a fix applied but not yet committed
  will not appear in this re-collection).
- **`--commit <value>`:** re-collecting this scope's diff is byte-identical every time ONLY WHEN
  `<value>` is itself an immutable, already-resolved commit SHA — the wrapper's own argument
  parser accepts any git revision expression (confirmed directly: it rejects only a
  leading-dash value, never validates or resolves the value to a fixed SHA), so `--commit HEAD`
  or `--commit main` is legal and can resolve to a genuinely different commit by the time a
  compaction restart happens, if that ref moved since round 1. Fixed: resolve `git rev-parse
  <value>` — through the SAME anchored, sanitized `env -i`/isolated-`HOME` invocation this skill
  already uses for every direct git call outside the wrapper (see `SKILL.md`'s "Determine review
  mode" for the canonical pattern) — into `target.resolved_commit_sha`, and use THAT resolved
  SHA, not the original literal `<value>`, for round 1's OWN scope-dependent
  sizing/snapshot-collection/dispatch, in addition to every later compaction restart.

  **Verify the resolution is a single, clean commit SHA before ever pinning to it.** Plain
  `git rev-parse <value>` does NOT always emit one commit object — for a range-shaped value the
  wrapper's own `--commit` branch already handles successfully today (e.g. `HEAD^..HEAD`),
  `rev-parse` emits the positive commit PLUS a separate `^<parent>` exclusion line; feeding that
  two-line output back in as a single `--commit` argument fails git resolution outright (exit
  128). After resolving, verify the output is EXACTLY one line matching a bare commit-SHA shape
  (`^[0-9a-f]{7,64}$`). **If it matches:** pin to it as designed. **If it does NOT** (multiple
  lines, a range, or anything else non-SHA-shaped): do NOT pin at all — round 1 dispatches with
  the ORIGINAL literal `<value>` exactly as the wrapper already does today (zero behavior change
  for this narrow case), no `target.resolved_commit_sha` is recorded, and compaction is simply
  never attempted for the rest of THIS session under this scope (every later threshold check
  no-ops immediately, falling through as if compaction were never enabled) — disclosed as an
  accepted, narrow limitation: ref-drift protection and compaction restart are both unavailable
  specifically for a `--commit` value that isn't a single resolvable commit.

  **Round 1 itself must be pinned too, not only the compaction restart.** The resolve-once-
  then-pin discipline applies from round 1 onward, uniformly — resolution happens exactly once,
  before ANY scope-dependent collection for this session (round 1's own sizing/snapshot/dispatch
  included), and the resulting SHA is the ONLY value ever used for a real git operation under
  `--commit` scope for the rest of the session. The original literal `<value>` the user typed is
  retained purely as `target.scope_value`, for audit/display, never used for a git operation
  again after this one resolution. This closes the loop completely: from round 1 through every
  possible compaction restart, `--commit` scope operates on one single, immutable commit for the
  whole session. No candidate snapshot is ever allocated for `--commit` scope; the ORIGINAL
  round-1 `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` remains the active snapshot, untouched, through every
  subsequent round including any compaction restart.
- **Durably persisting the original scope ARGUMENT, not just its category.** Round 1's own
  JSONL line (not only a compaction round's) gains a new field, `target.scope_value` — the
  literal `<ref>`/`<value>` string for `--base`/`--commit` scope, omitted for `--uncommitted`
  (which has no such argument) — plus, for `--commit` specifically, `target.resolved_commit_sha`
  as above. A compaction restart under `--base` scope reuses the EXACT durably-recorded
  `scope_value`, never a freshly-typed or re-derived one; a compaction restart under `--commit`
  scope uses the durably-recorded `resolved_commit_sha` instead. **Disclosed limitation,
  inherent to `--base <ref>` where `<ref>` names a movable branch:** re-dispatching with the same
  literal `<ref>` string can still resolve to a different merge-base if that branch has advanced
  since round 1 — the same "not a defense against a deliberately changed source" non-goal
  `references/snapshot-integrity.md` already accepts elsewhere; `--base`'s own resolved
  merge-base is NOT separately pinned/verified here, since its scope is defined relative to the
  CURRENT `HEAD` by design — pinning `--base` further would change what `--base` scope actually
  MEANS, out of scope for this feature to alter.
- **Ownership, for `--uncommitted`/`--base` (where a real candidate exists):** the candidate file
  is a NEW, separate temp file — the ACTIVE (old) `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` used for
  round-2+ revalidation is left completely untouched while the candidate merely sits on disk. On
  compaction failure (see "On failure" below): delete the candidate file immediately (it was never used for
  anything) and continue revalidating rounds against the untouched original active snapshot.
- **Collection/hash failure itself.** Mirrors `references/snapshot-integrity.md`'s own Phase 0
  step 5 / Phase 1 post-sizing allocation, which already checks every collection command's own
  exit status and the resulting digest's shape before trusting it: if the candidate's own `git
  diff`/`shasum` collection fails, or the resulting digest fails the 64-hex-character validation,
  this is treated exactly like any other compaction failure — delete whatever partial candidate
  file may exist (on a failed deletion here, add its path to `RETIRED_SNAPSHOT_FILES` — see
  "Retired-snapshot tracking" below), log the narration note, and go straight to the "On failure" section's normal
  `--resume` fallback. No dispatch is even attempted with an uncollectible candidate.
- **Concrete provisional-resource tracking.** A new session-scoped fact,
  `PROVISIONAL_SNAPSHOT_FILE` (analogous to `LEAKED_THREAD_IDS`), is set the moment a candidate
  is successfully collected and hashed, and cleared the moment that candidate is either promoted
  (success) or deleted (failure/collection error) — never left ambiguous in between.
  `SKILL.md`'s Phase 3 terminal cleanup (every terminal path, including
  `🛑 REVIEW LOG INTEGRITY FAILURE`) is extended to also remove `PROVISIONAL_SNAPSHOT_FILE`
  whenever one is currently set, exactly like it already removes the active `SNAPSHOT_FILE` (see
  Task 21 for the exact `SKILL.md` edit).
- **Snapshot lineage.** The one JSONL line that performs a compaction restart records both
  `snapshot_digest_before` and `snapshot_digest_after` (identical for `--commit` scope, by
  construction) — pure audit trail. This deliberately, narrowly overrides
  `references/snapshot-integrity.md`'s existing "one canonical subject, no external-drift
  detection" contract, only for this Claude-orchestrated, fully-disclosed re-snapshot event,
  never by anything auto-detected — shipping this feature requires a companion amendment to that
  reference file (see Task 17).

**On success, promotion is ONE atomic rename onto the fixed `SNAPSHOT_FILE` path, never a
separate delete-then-move.** `SNAPSHOT_FILE` is, and remains, ONE fixed literal path for the
entire session, exactly like `REPO_ROOT`/`SESSION_ID` — promotion NEVER reassigns which path
Claude calls `SNAPSHOT_FILE`; it always physically replaces that fixed path's own content.
Concretely, only after this round's JSONL append is verified (see "Ordering on success" below):
`mv "$candidate_snapshot_path" "$SNAPSHOT_FILE"` — a single `rename(2)` syscall (both paths
guaranteed on the same filesystem, both under the same session-scoped `/tmp` area), which POSIX
guarantees ATOMICALLY replaces the destination, unlinking its previous content as part of the
SAME operation — there is no OS-visible intermediate state where the active path is empty.

**`SNAPSHOT_DIGEST` must ALSO be advanced on a successful rename.** The instant the `mv` above
completes successfully, Claude's own remembered `SNAPSHOT_DIGEST` literal is updated to
`snapshot_digest_after` — both remembered facts (`SNAPSHOT_FILE`'s path staying constant,
`SNAPSHOT_DIGEST` advancing to the new value) change together, in the same step, never one
without the other. Otherwise the very next round's ordinary revalidation would hash the
newly-promoted file, get a digest that no longer matches the STILL-remembered old
`SNAPSHOT_DIGEST`, and incorrectly raise `🛑 SNAPSHOT INTEGRITY FAILURE` on a perfectly
successful, intended promotion.

**A failed `mv` occurring LIVE, after this round's own success line is ALREADY committed, is
MANDATORY to retry, not optional — there is no fallback path available anymore, because the
durable record has already committed to this outcome.** Retry it up to 2 more times with a brief
pause (matching this skill's other bounded-retry conventions), RE-RUNNING the live active-file
and candidate integrity checks (see "Ordering on success" below) before each retry attempt, not
only the first. If ALL retries are exhausted and the `mv` still fails, this is a genuinely broken
state — hard stop, `🛑 SNAPSHOT INTEGRITY FAILURE`, since the durable log's own claim can no
longer be honored on disk. The OLD content is guaranteed untouched by a failed rename (rename
either fully happens or doesn't, never partially), so this hard stop is at least never compounded
by additional data loss.

**The candidate file keeps using `mktemp` for a fresh, unpredictable, atomically-created path**
exactly like every other snapshot allocation in this design (never a deterministic,
`.candidate`-suffixed path derived from the active `SNAPSHOT_FILE`'s own name — that would
reintroduce a symlink/predictable-path attack `mktemp`'s existing random allocation exists to
prevent, since `/tmp` resolves to the world-writable sticky `/private/tmp` on macOS). The
resulting random path is durably recorded, as a new field, `candidate_snapshot_path`, on that
same round's own JSONL line at the moment of the append (a pre-append-decided value, known the
instant the candidate is collected) — see "Ordering on success" below for continuity recovery's
use of this field.

**Retired- and provisional-snapshot durability.** Two related but distinct durability concerns
for a candidate snapshot file that is abandoned rather than promoted: which deletions get tracked
so nothing is referenced by nothing, and which crash windows around `PROVISIONAL_SNAPSHOT_FILE`
are closed versus merely disclosed.

**Retired-snapshot tracking is general-purpose, covering two deletion points that remain
fallible on their own.** Both cases are genuinely independent `rm` calls on a candidate being
ABANDONED, not promoted (promotion, above, is a single atomic rename with no separate old-file
deletion step): a failed deletion of a PARTIAL candidate (per "Collection/hash failure itself"
above), and a failed deletion of a fully-hashed candidate on ordinary compaction failure (per "On
failure" below). In EITHER case, if a LATER compaction attempt's own single
`PROVISIONAL_SNAPSHOT_FILE` slot then gets reassigned to a new candidate, the earlier
failed-to-delete file is referenced by nothing at all. Both route through the exact same
session-scoped set, `RETIRED_SNAPSHOT_FILES` (analogous to `LEAKED_THREAD_IDS`) — the path is
also added to a new array field, `retired_snapshot_files`, on that SAME round's own line
(present only when non-empty), since both cases are discovered strictly BEFORE that round's own
JSONL line is ever written. `SKILL.md`'s Phase 3 terminal cleanup plus continuity recovery are
both extended to union in every path ever recorded in this field across the session's log — the
same durable-backstop pattern already established for `LEAKED_THREAD_IDS` (see Task 21).

**`PROVISIONAL_SNAPSHOT_FILE` has TWO genuinely different windows.** The FAILURE-path window (and
the SUCCESS path before its own append) is entirely pre-append: disclosed, accepted as a residual
gap, not fully closed — an interruption in this narrow window can leave one orphaned candidate
file (and, on the success sub-case specifically, one orphaned thread — the newly-created thread
is ALSO only tracked in-memory via `LEAKED_THREAD_IDS` until that same append lands, the identical,
already-accepted gap every ordinary round's own thread creation already has before ITS OWN first
append) with no recorded path to retry its cleanup. This window can span up to TWO
candidate/thread pairs when the fresh-B escalation is reached (see "Retry topology" below), since
A is added to `LEAKED_THREAD_IDS` in-memory-only before B is ever dispatched.

The POST-append window (success path only, between the verified append and the promotion `mv`) is
genuinely CLOSED, not merely disclosed, via the durably-recorded `candidate_snapshot_path` above.
Recovery for this window (part of continuity recovery, see `SKILL.md`'s "Review history log" →
"Read (continuity)") never skips the mandatory verify-before-trust step
`references/snapshot-integrity.md` already requires: search the WHOLE log for the most recent
round carrying `compacted_from_thread`/`snapshot_digest_after`/`candidate_snapshot_path` (never
just the latest line — once even one ordinary round completes after a successful compaction, the
latest line no longer carries these fields), reconstruct the remembered `SNAPSHOT_DIGEST` from
THAT round's own recorded values, then:
1. Hash whatever currently exists at the active path. If it is missing, or matches NEITHER
   `snapshot_digest_before` NOR `snapshot_digest_after` — genuine, unexplained corruption — hard
   stop, `🛑 SNAPSHOT INTEGRITY FAILURE`.
2. If it matches `snapshot_digest_after`: still check `candidate_snapshot_path` before concluding
   nothing remains to do — in the before/after-identical edge case (`snapshot_digest_before ==
   snapshot_digest_after`), a crash after the success append but BEFORE the `mv` ever executed
   leaves the OLD, unpromoted file already "matching" `snapshot_digest_after` purely because the
   two digests happen to be equal, with the candidate still sitting, unrenamed, on disk. If
   `candidate_snapshot_path` still exists on disk: delete it (it is no longer needed either way).
   A failed deletion here cannot fold into `retired_snapshot_files` (that field can only be added
   AT APPEND TIME, but recovery runs later) — instead, attach this failed path to the NEXT round
   that actually dispatches and appends its own line (best-effort backfill); if no further round
   is ever dispatched, this shares the same accepted, disclosed, bounded-impact residual gap as
   the pre-append window above.
3. If it matches `snapshot_digest_before` (the rename has NOT yet run): check
   `candidate_snapshot_path`. If it exists and verifies against `snapshot_digest_after`, run the
   SAME `mv` now to complete it, with the IDENTICAL retry-then-hard-stop treatment as the live
   promotion case above (re-verifying both files before each retry attempt); on success, advance
   `SNAPSHOT_DIGEST` the same way. If the candidate is missing, or present but fails to verify
   BEFORE any `mv` is even attempted: hard stop, `🛑 SNAPSHOT INTEGRITY FAILURE`.

### Step 4 — dispatch a fresh `run-ccs-review.sh` call

Dispatch a **fresh** `run-ccs-review.sh` call (same scope flag as round 1, not `--resume` — or,
for a non-repo-artifact session per step 2 above, `--uncommitted` against `CLEAN_REPO_DIR` with
the original artifact text included in focus) with focus text composed of, in order:
1. `COMPACT_DIGEST` (see "Digest construction and verification" above)
2. The original artifact text, for a non-repo-artifact session only (per step 2 above)
3. The original Why AND task-specific Scope framing, read from `target.original_scope_framing`
   (never from `target.focus` — see below for why)
4. The standard `⚠️ SCOPE CONSTRAINT` block
5. The SAME fixed collaboration-frame sentence every round-1 focus already includes (Claude and
   Codex are equal peers, findings must be evidence-based, the goal is 100% clean mutual
   agreement) — this is fixed, static boilerplate, not task-specific content, so it needs no
   separate durable field
6. The SAME `DISPOSITION` request block an ordinary round 2+ would include, constructed by the
   EXISTING rule (`references/claim-ledger.md` section 4 and `SKILL.md`'s own round-2+ History
   construction), evaluated against the pre-compaction thread's own most recently completed
   round exactly as it would be for an ordinary resumed round — without this, a claim this fresh
   reviewer would happily confirm fixed has no mechanism to actually close, eventually producing
   a false `⚠️ NOT CONVERGED` at the round cap purely because compaction never asked.

**This dispatch IS round R's real dispatch** — its own findings are processed through the
ordinary Phase 2 steps exactly like any other round's; no separate follow-up dispatch happens in
the success case.

**A dedicated field is required for the Why/Scope component — `target.focus` is NOT a stable
source for this.** `target.focus` records whatever focus text was sent for round 1's own FINAL
logged dispatch ATTEMPT, not a stable "original task framing" fact — it diverges in two confirmed
real ways: (1) if round 1's own dispatch initially failed and needed a resume-safe retry, the
retry's own focus text is just a short "Retrying after a `<reason>` failure..." note plus the
generic scope constraint, NOT the original Why/Scope; (2) for a non-repo-artifact session,
`target.focus` ALREADY embeds the full original artifact text, so reading it back AND separately
re-embedding the artifact (per step 2 above) would duplicate the artifact in the fresh prompt.
Fixed: a new, dedicated, write-once field — `target.original_scope_framing` — captured exactly
ONCE, at the moment round 1's OWN focus text is first constructed (`SKILL.md`'s Phase 1 Step 0,
BEFORE the very first dispatch attempt of any kind, retry or not), holding ONLY the Why +
task-specific Scope text. For a non-repo-artifact session, this field explicitly EXCLUDES the
pasted artifact text (which stays available separately, via the unchanged snapshot). This field
is written once to round 1's own JSONL line and is NEVER overwritten by a later retry — a retry
only ever changes what is actually dispatched for that attempt (`target.focus`, serving its
existing, unchanged diagnostic/continuity purpose), never this separately-recorded
original-framing fact.

**Coverage epoch.** For a `--uncommitted` compaction dispatch specifically, this call can report
its own `coverage.source` exactly like any fresh `--uncommitted` dispatch can — this is a SECOND
fresh `--uncommitted` epoch within the same session, not only round 1's. The existing "coverage
is a round-1-only property" rule (`SKILL.md`'s own "Coverage is a Round-1-only property" section)
is generalized to "coverage is a property of every fresh `--uncommitted` dispatch this session,
round 1 or a compaction restart" — the CLEAN convergence gate merges EVERY such dispatch's own
coverage outcome (worst-of-all: `"complete"` only if every one of them was `"complete"`, else the
existing `"partial"`/`"unknown"` precedence, `omitted` lists unioned and deduplicated by `(path,
reason)`), never round 1's alone once a compaction has occurred. `--base`/`--commit` compaction
dispatches report no coverage, exactly like round 1 in those scopes.

**A successful restart can ALSO lack real coverage.** The untracked-file collector deliberately
treats a failure to write its own `--coverage-out` sidecar as non-fatal, and the wrapper
deliberately degrades a missing/malformed sidecar to reporting no coverage metadata at all — so
an `ok:true` fresh `--uncommitted` compaction dispatch can genuinely lack `coverage.source` too.
The existing "always record coverage — real value when present, the `"unknown"` sentinel when
absent" rule therefore applies symmetrically here: if this dispatch's own response is `ok:true`
but carries no `coverage.source`, the round's `coverage_source` field is still recorded as the
`"unknown"` sentinel — never silently omitted.

**A retry-then-succeed candidate must reuse its OWN pre-retry coverage, never treat itself as
coverage-less.** A fresh `--uncommitted` dispatch that first returns `ok:false` WITH
`coverage.source` already present (several failure reasons, e.g. `timeout`, occur only after
collection has already completed), and is then retried via `--resume` on that SAME new candidate
thread until it succeeds, ends up with a final `ok:true` response that itself carries NO
`coverage.source` at all — because a `--resume` call never re-collects anything. Fixed
(generalizing `references/retry-guards.md`'s existing round-1 retry-then-succeed rule from
"round 1" to "whichever round performs a fresh `--uncommitted` dispatch"): carry forward the
EARLIER failed attempt's own `coverage.source` as this round's real coverage once the retry
succeeds. If the earlier failed attempt itself carried no `coverage.source` either, the
`"unknown"` sentinel rule above still applies.

**The SAME retry-then-succeed situation applies to `COMPACTION_BASELINE_TOKENS` too, not only
coverage.** `COMPACTION_BASELINE_TOKENS` is read from the EARLIER failed fresh attempt's own
`execution.usage.input_tokens` when one exists (the fresh dispatch's real, original size, before
any retry), never from a subsequent `--resume` retry's own response, whose `execution.usage`
describes only the resumed turn's marginal usage. Only when the fresh attempt's own first
response carried no usable telemetry at all does the existing "fail closed when telemetry is
unusable" rule (see "Trigger" above) apply.

## Retry topology

A compaction attempt's brand-new candidate thread structurally has "no pre-existing thread" —
it has never appeared in `GROUP_THREADS` before this attempt. `references/retry-guards.md`'s own
tested, EXISTING behavior for exactly this shape of failure is: fresh A → resume A → resume A →
if BOTH resumes are STILL exhausted, one further FULL fresh retry with a brand NEW thread B,
abandoning A to `LEAKED_THREAD_IDS`, before ever giving up (see
`evals/scenarios/retry-exhausted-round1-fresh-fallback` for a live-exercised example of this exact
sequence). Compaction reuses this EXACT existing topology rather than inventing a
compaction-specific variant — consistent with this design's own "reuse existing mechanisms"
principle elsewhere.

Apply `references/retry-guards.md`'s own THREE bullets, in the SAME priority order it already
uses, to candidate A ONLY — tracked as its own fact, independent of `GROUP_THREADS` (which keeps
meaning "the old thread" throughout, per "Failure isolation from the round loop" below). Thread
B's own, deliberately simpler treatment is Task 12.

1. **If THIS SPECIFIC response captured no threadId AND the current candidate has NEVER
   previously captured one either, across any earlier response in this same attempt sequence:**
   apply `references/retry-guards.md`'s "no entry yet" bullet to THIS candidate specifically: one
   fresh retry. Checking only "did THIS response lack a threadId" would wrongly treat a
   `--resume` call's own no-threadId failure (e.g. `bad_args` from a stdin mistake) as proof the
   candidate thread never existed — `references/retry-guards.md`'s own explicit rule for exactly
   that case is "that existing thread is untouched, not abandoned... retry the exact same
   `--resume` call again," so the candidate's own thread history must be checked, never inferred
   from this one response alone.

   **This retry ALSO re-collects a genuinely FRESH candidate — never reuse the already-collected
   `candidate_snapshot_path`/digest.** The wrapper accepts no snapshot input at all; EVERY fresh
   dispatch, retry included, independently re-collects `DIFF_TEXT` live from the repository at
   ITS OWN moment. A real, meaningful amount of wall-clock time elapses between the original
   failed attempt and this retry — enough for the worktree or `HEAD` to have moved — so promoting
   the OLD, earlier-collected candidate would durably record a digest for content that is NOT
   what this retry's own dispatch actually reviewed. Fixed, for `--uncommitted`/`--base` scope
   specifically (for non-repo-artifact/`--commit` scope, this retry involves no candidate file,
   exactly like the original failed attempt did not): this retry re-collects and re-hashes a
   brand new candidate (new `candidate_snapshot_path`, new digest) exactly like the original
   attempt did; the OLD (now-superseded) candidate is deleted immediately (folding a failed
   deletion into `retired_snapshot_files`, per "Restart mechanism" step 3 above).

   **This retry ALSO reconstructs the COMPLETE compaction focus text identically to "Restart
   mechanism" step 4 above** — this is a genuinely fresh `codex exec` call with no prior turn of
   its own to inherit anything from, so whatever focus text it sends is the entirety of what this
   new dispatch ever sees.

   If this retry fails AGAIN, for ANY reason: this candidate is exhausted. **Check whether THIS retry's
   own response captured a threadId before assuming nothing needs tracking** — this retry is
   itself a genuinely fresh dispatch, and can fail with a reason that DOES carry a threadId even
   when the ORIGINAL attempt's own failure did not (e.g. the original fails `no_thread_started`
   [no ID], this retry then fails `timeout` or `nonzero_exit` [captures a real, live threadId
   before failing]). If this retry's own response DID capture a threadId, add it to
   `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` exactly like any other abandoned
   thread; only when this retry's response ALSO captured no threadId is there genuinely nothing
   to add. Delete this retry's own candidate too, when one exists. Fall straight through to the
   "On failure" fallback. **The fresh-B escalation (Task 12) is never reached from this bullet**,
   regardless of what the retry's own second failure looks like.
2. **Else (a threadId WAS captured for the current candidate, either by this response or an
   earlier one in the same sequence): if THIS specific response itself lacks a threadId despite
   the candidate already having one** — retry the SAME already-captured thread EXACTLY ONCE,
   never more, and never re-entering the ordinary bounded-resume/fresh-B escalation on ANY
   outcome of this one retry besides success (`references/retry-guards.md`'s own literal rule
   for this exact case describes only two outcomes: it succeeds, or "the retry ALSO fails, stop —
   report `⚠️ COULD NOT VERIFY`," with no carve-out for a different escalation path based on
   what the second failure's own reason happens to be). If that one retry fails AGAIN, for ANY
   reason: exhausted. **Always record the ALREADY-KNOWN thread id on exhaustion here** — this
   bullet's own precondition guarantees one exists, unlike bullet 1's genuinely-uncertain case —
   add it to `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` unconditionally, then fall
   straight through to the "On failure" fallback (never `⚠️ COULD NOT VERIFY`, per this design's own
   failure-isolation principle — see below). Only if this one retry SUCCEEDS does the candidate
   continue as this round's own live, active attempt, exactly as if no no-ID hiccup had ever
   occurred.
3. **Else (THIS response DOES carry a threadId — the ordinary, most common case, whether this is
   the candidate's own first-ever captured id or a later response that continues to carry one):**
   this is the ordinary case — apply the standard bounded-resume-retry-then-fresh-B escalation
   directly: 2 bounded `--resume` retries against this SAME thread; if both are exhausted, the
   fresh-B escalation (Task 12).

The fresh-B escalation is reached ONLY via bullet 3's own ordinary path — a genuinely NEW
resume-safe failure that carries a threadId on its OWN first occurrence for this candidate (never
via a no-ID recovery scenario per bullet 2) — never via bullet 1's own exhaustion, which falls
straight to the "On failure" fallback without ever creating a second candidate thread.

**Thread B's OWN dispatch reconstructs the COMPLETE compaction focus text, identically to
"Restart mechanism" step 4 above — never a partial or abbreviated one.** B's dispatch is a
genuinely fresh `codex exec` call, not a `--resume`, so it has NO prior turn to inherit anything
from — the wrapper copies each invocation's own stdin into a fresh focus-received file and
launches a plain `codex exec` for every non-resume call, meaning whatever focus text this
dispatch sends IS the entirety of what the new thread ever sees. Before dispatching B: thread A
is added to `LEAKED_THREAD_IDS`; if A's own dispatch had allocated a candidate snapshot file,
that candidate is deleted immediately (folding a failed deletion into `retired_snapshot_files`).
For `--uncommitted`/`--base` scope, B's dispatch re-collects a fresh candidate (new
`candidate_snapshot_path`, new digest) exactly as A's original dispatch was — never a reuse of
A's now-deleted candidate. For non-repo-artifact/`--commit` scope, B's dispatch involves no
candidate file at all, exactly like A's did not.

**Thread B's own single dispatch gets NONE of bullets 1-3's retry machinery — it either
succeeds, or the whole compaction attempt is immediately exhausted**, matching
`references/retry-guards.md`'s own "round 2+"/one-fresh-fallback rule exactly. If B's own
dispatch fails, for ANY reason whatsoever (no threadId at all, a
threadId-bearing resume-safe reason — neither is distinguished for B): immediate
exhaustion, with no retry of B, no no-threadId recovery attempt for B, and absolutely no further
escalation to a third candidate/thread. If B's own failed response captured a threadId, add it to
`LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` (alongside A's own); if not, there is
genuinely nothing further to add for B. Delete B's own candidate, when one exists. Fall straight
through to the "On failure" fallback.

`compaction_attempt_failed_thread` becomes an ARRAY of 1 or 2 thread ids — just `[A]` when B was
never reached, `[A, B]` when both were abandoned — rather than a single value; every consumer of
this field (Phase 3 cleanup, the final-report thread enumeration, the append-verify field checks
— see Task 13) is extended to accept and union in either shape.

**Carry-forward applies to A's OWN `--resume` retry-then-succeed too — BOTH bullet-2's no-ID-
hiccup retry AND bullet-3's ordinary threadId-bearing bounded resume retry, the two genuinely
different ways A can succeed via `--resume` — NEVER to A's bullet-1 no-threadId FRESH retry,
which needs the OPPOSITE treatment.** Neither bullet 2's nor bullet 3's own successful `--resume`
response ever re-collects anything, so in BOTH cases the ONLY real coverage/baseline/telemetry
data available is the earlier failed response's own — carry it forward (see "Restart mechanism"
step 4's coverage-epoch rules above, and "Preserving failed-attempt telemetry" below for
`execution`). Bullet 1's own retry is the polar opposite — it is itself a genuinely NEW,
independent re-collection, exactly like the A→B transition already is, with its OWN fresh
coverage and baseline; applying carry-forward there would use STALE data from an attempt whose
own collected content this retry has already deleted and superseded. For bullet 1's own
retry-then-succeed specifically, the RETRY's own response is the sole authoritative source for
coverage and `COMPACTION_BASELINE_TOKENS` — never the earlier, now-superseded failed attempt's —
mechanically identical in principle to how B's own data is used, never A's, after the A→B
transition.

**Exactly THREE sub-cases can produce a round that carries BOTH a success AND preserved
earlier-failure telemetry, never a "B retries" case (B is single-shot by construction, so there
is no possible "B's own first response failed, then B itself went on to succeed" scenario):**
(i) an EARLIER response for the eventually-successful thread A failed before that SAME thread
went on to succeed via its own `--resume` retry (bullet 2's no-ID hiccup, or bullet 3's ordinary
threadId-bearing bounded resume — both are this same sub-case); (ii) A's own first response
failed with no threadId, and its ONE allowed no-threadId fresh retry then succeeded (still "A,"
no abandoned thread, per bullet 1); or (iii) a genuinely abandoned thread A, exhausted, preceded
thread B's own eventual success within that SAME round. **ONLY sub-case (iii) ever populates
`compaction_attempt_failed_thread`** — in sub-cases (i) and (ii), the SAME thread that had an
earlier failed response is what goes on to succeed, so nothing was ever abandoned; recording it
there would cause it to be double-cleaned, or falsely reported as leaked, despite being the
round's own real, live, active thread. All three sub-cases MAY (conditionally, never
unconditionally) populate `compaction_attempt_execution`/`compaction_attempt_coverage` — see
"Preserving failed-attempt telemetry" below.

## Ordering on success

Durability before any thread or snapshot file is touched, with immediate provisional tracking to
close the intermediate-window leak an unprotected implementation would leave open (between
"dispatch returns ok:true" and "JSONL append verified," the new thread and candidate snapshot
must NOT be tracked nowhere — a `🛑 REVIEW LOG INTEGRITY FAILURE` in that window would otherwise
leak both, since that failure's own cleanup only ever sweeps `GROUP_THREADS`/`LEAKED_THREAD_IDS`
and the currently-active snapshot):

1. This dispatch returns `ok:true` (never inferred from "a threadId exists" — several `ok:false`
   failure reasons also carry a `threadId`).
2. **Immediately** (before doing anything else with this result): add the new thread id to
   `LEAKED_THREAD_IDS` provisionally (the candidate snapshot, when one exists, is ALREADY tracked
   as `PROVISIONAL_SNAPSHOT_FILE` from the moment it was collected — see "Restart mechanism" step
   3 above — nothing new to do for it here). Both are now covered by every existing terminal
   cleanup sweep (including a `🛑 REVIEW LOG INTEGRITY FAILURE` that might fire in step 3 below),
   even though neither has been "promoted" yet.
3. Process this round's findings normally (`SKILL.md`'s Phase 2 steps 2-6, including the
   coverage merge from "Restart mechanism" step 4 above), then append this round's JSONL line —
   `target.scope` = the scope flag actually used (never `"resume"`), plus
   `compacted_from_thread: <old thread id>` and the snapshot-lineage fields from "Restart
   mechanism" step 3 above — and run the EXISTING append-verify hard stop exactly as any other
   round does, EXTENDED per the branch-aware table below.

### The append-verify extension — branch-aware, never one fixed field list

The base skill's own verifier only confirms the appended line carries the expected round NUMBER —
it says nothing about which FIELDS that line carries. This extension confirms exactly the fields
THAT SPECIFIC outcome requires, never a one-size-fits-all list (a non-repo-artifact session and
`--commit` scope never allocate a candidate at all; several `ok:false` reasons structurally never
carry a `threadId` at all):

- **Success, `--uncommitted`/`--base` scope (a real candidate was allocated):** REQUIRE
  `compacted_from_thread`, `candidate_snapshot_path`, `snapshot_digest_before`,
  `snapshot_digest_after`, `compaction_attempt_failure_count` (must equal `0`).
- **Success, non-repo-artifact or `--commit` scope (no candidate ever allocated):** the same set
  MINUS `candidate_snapshot_path`, whose absence here is the CORRECT state, not a defect.
- **Success, whenever the ROUND's OWN scope is `--uncommitted`** (including a non-repo-artifact
  session, which dispatches AS `--uncommitted` under the hood) — **regardless of whether the
  SPECIFIC call that ultimately produced success was itself a fresh `--uncommitted` dispatch or a
  later `--resume` retry of it:** ALSO REQUIRE `coverage_source`, either a real value or the
  `"unknown"` sentinel, never simply absent — checked against the round's own recorded
  `target.scope`, never against which specific call within that round happened to succeed (this
  is what makes the retry-then-succeed carry-forward case, whose FINAL successful call is itself
  a `--resume`, correctly still require this field). Never for `--base`/`--commit` scope
  specifically (never non-repo-artifact) — neither ever emits `coverage.source` at all.
- **Success reached after ANY earlier failed sub-attempt** (A's own resume retry-then-succeed,
  A's own no-threadId fresh-retry success, or A-exhausted-then-B-succeeds — the same three
  sub-cases from "Retry topology" above): `compaction_attempt_failed_thread` is REQUIRED only for
  sub-case (iii) (candidate A genuinely abandoned, thread B succeeds) — for sub-cases (i) and
  (ii) it is correctly ABSENT entirely, never required and never present as an empty array,
  since in EITHER, the SAME thread that had the earlier failed response is what goes on to
  succeed, so nothing was actually abandoned. ALSO REQUIRE
  `compaction_attempt_execution` whenever the underlying earlier failed response(s) actually carried it, and
  `compaction_attempt_coverage` ONLY for whichever of those earlier failed response(s) was itself
  a fresh `--uncommitted` dispatch — never for a failed `--resume` call among them (see
  "Preserving failed-attempt telemetry" below).
- **Attempted-and-failed, falling through to the fallback:** REQUIRE
  `compaction_attempt_failure_count` — EXCEPT when the failure was `byte_budget_exceeded` (see
  "Byte-budget preflight" above), which deliberately never increments this counter, so its
  absence here is likewise the correct state. REQUIRE `compaction_attempt_failed_thread`
  ADDITIONALLY, **keyed on whether a threadId was ACTUALLY captured for each abandoned attempt,
  never on a fixed reason-category exclusion list** (`interrupted` can ALSO occasionally lack a
  threadId, per "Retry topology" above's own corrected candidate-retry predicate — checked
  per-occurrence, exactly like that predicate itself). When every abandoned sub-attempt's own
  response genuinely captured no threadId at all, this field is correctly absent.
- **Any round that newly sets `compaction_disabled_reason` this round** (baseline over threshold,
  baseline unusable, failure count reaching its bound, or byte budget exceeded): that field is
  ADDITIONALLY REQUIRED whenever the round's own processing actually reached that decision this
  round.
- **Any round whose own processing discovers a genuinely pre-append snapshot-deletion failure
  this round** (a partial-candidate or abandoned-candidate deletion failure — the two LIVE,
  within-a-round cases; promotion itself is a single atomic rename with no separate post-append
  deletion step): `retired_snapshot_files` is ADDITIONALLY REQUIRED, non-empty. **Also required,
  additionally non-empty, on whichever round actually carries a DEFERRED backfill from an earlier
  recovery-discovered candidate deletion failure** (see "Restart mechanism" step 3's own
  post-append-window recovery step 2 above).
- **Round 1's own line, whenever `--compact` was given for this session:**
  `target.original_scope_framing` is REQUIRED on round 1's own line whenever `--compact` was given for
  the session (regardless of scope); `target.scope_value` is ADDITIONALLY REQUIRED specifically
  for `--base`/`--commit` scope (never for `--uncommitted`). `target.resolved_commit_sha` is
  REQUIRED additionally, specifically for `--commit` scope, WHENEVER resolution succeeded (never
  required when resolution itself failed verification and round 1 deliberately fell back to the
  original unpinned literal value instead — see "Restart mechanism" step 3 above).

**Presence and type are not enough on their own — every durability-critical field must also
match the VALUE Claude itself already computed for this transition, not merely its shape.**
Wherever this round's own processing already computed an authoritative value BEFORE the append
(every field on the list above qualifies — that is precisely why each is being appended in the
first place), the verify step compares the appended value against that already-known value:
`compaction_attempt_failure_count` must equal the just-incremented (or, on success, `0`) value
Claude itself computed this round, never merely "any integer"; `snapshot_digest_before`/
`snapshot_digest_after` must equal the digests Claude itself hashed; `candidate_snapshot_path`
must equal the literal `mktemp` path Claude itself allocated this round; `compaction_disabled_reason`
must equal the SPECIFIC cause that actually triggered it this round, not merely be one of
the 4 valid strings; `compaction_attempt_execution`, when the underlying failed response(s)
actually carried it, must be present and non-empty, never silently dropped.

**`compaction_attempt_coverage` follows a STRICTER rule than `compaction_attempt_execution`, but
ONLY for `--uncommitted`-scope sub-attempts.** Required whenever a real fresh `--uncommitted`
wrapper dispatch was attempted and itself FAILED — candidate A's own original attempt, the
no-threadId fresh retry, or thread B's own dispatch, each only when it uses `--uncommitted` scope
and itself fails — either the real `coverage.source` value or the `"unknown"` sentinel for that
entry, never simply absent. A failed `--resume` call is never a fresh `--uncommitted` dispatch
and correctly gets NO entry here, regardless of the round's overall scope. A round whose FIRST
fresh `--uncommitted` attempt succeeds directly has no failed sub-attempt at all, and correctly
has no `compaction_attempt_coverage` entry — its own coverage is reported via `coverage_source`
instead, never this field. For a `--base`/`--commit`-scope sub-attempt, no entry is ever required
or expected.

A missing, malformed, OR value-mismatched required field for whichever of these branches actually
applies is treated with the SAME severity as a wrong round number — a hard stop,
`🛑 REVIEW LOG INTEGRITY FAILURE`, never a soft warning. A field this round's own outcome does NOT
require is correctly absent and must never be flagged as missing. If this append fails
verification: the new thread and candidate snapshot are ALREADY tracked as provisional/leaked
(step 2 above) and get cleaned up by the existing `🛑 REVIEW LOG INTEGRITY FAILURE` path exactly
like any other leaked resource — nothing extra to do here, and nothing new leaks.

### Promotion — only after the append is verified

**Only after that append is verified**: (a) promote — remove the NEW thread id from its
provisional `LEAKED_THREAD_IDS` entry and make it the active `GROUP_THREADS` entry instead; add
the OLD thread id to `LEAKED_THREAD_IDS` in its place (never an immediate `--cleanup` — see
"Interaction with `--keep-evidence`" below); (b) **only for `--uncommitted`/`--base` scope, where
a real candidate exists** (non-repo-artifact and `--commit` scope allocate NO candidate at all —
`SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` are already correct, having never changed, so this whole
sub-step is simply skipped for those two scopes): immediately before the rename, re-verify BOTH
sides of the transition, not only the destination — checking only the OLD active file would leave
the CANDIDATE itself unverified at this late point, even though it was collected and hashed much
earlier:
- Re-hash whatever currently exists at the active `SNAPSHOT_FILE` path and confirm it still
  matches `snapshot_digest_before`.
- Re-hash `candidate_snapshot_path` and confirm it still matches `snapshot_digest_after`.

If EITHER check fails: hard stop, `🛑 SNAPSHOT INTEGRITY FAILURE` — this is genuine,
newly-discovered corruption unrelated to compaction itself, and promoting over it (or promoting a
corrupted candidate) would erase or misrepresent the only evidence of it. Only once BOTH pass:
promote the candidate snapshot via the single atomic `mv "$candidate_snapshot_path"
"$SNAPSHOT_FILE"` rename described in "Restart mechanism" step 3 above. On success, ALSO advance
the remembered `SNAPSHOT_DIGEST` to `snapshot_digest_after` in this same step. A failure of this
`mv` itself is handled per "Restart mechanism" step 3's own "failed `mv` occurring LIVE" rule —
retried up to 2 more times, then `🛑 SNAPSHOT INTEGRITY FAILURE` if still failing — never the
ordinary "On failure" compaction-fallback path below, which structurally cannot apply once this
round's own success line is already committed. Each retry attempt REPEATS both live checks above
first, immediately before that specific attempt's own `mv`.

## On failure

On any `ok:false` reason — self-contained fallback, never this
round's own terminal outcome, and NEVER a separate JSONL append (a standalone append for the
failed attempt would conflict with the append-verify contract requiring exactly one JSONL object
per round number):

1. **Three independent checks on the failed attempt's own response — each captured whenever
   present, none gated on whether another is present** (`no_thread_started` carries no
   `threadId`, since the wrapper's own reason table shows that branch requires an empty
   `THREAD_ID`, but still carries a genuine `execution` object, since Codex was already launched
   and timed before that failure was detected — nesting the captures would silently drop real
   telemetry):
   - If a `threadId` is present, remember it in-memory in `LEAKED_THREAD_IDS` immediately — this
     is a REQUIRED step whenever a threadId exists, not best-effort (see "Durable backstop for
     abandoned threads" below).
   - If an `execution` object is present, remember it (see "Preserving failed-attempt telemetry"
     below).
   - **A failed compaction attempt's coverage is DURABLY LOGGED for audit, but NEVER folded into
     the shared convergence-gating reducer.** `coverage` describes whether file COLLECTION
     completed for the CANDIDATE diff — it says nothing about whether a real Codex VERDICT was
     ever produced for that candidate. When the attempt fails, the candidate is discarded and the
     round falls back to `--resume` on the OLD thread, which only ever continues reviewing the
     OLD thread's own original diff context (`--resume` cannot be combined with a scope flag and
     never re-collects a diff). Folding the candidate's own "complete" collection status into the
     session's overall coverage would therefore claim the codebase was fully reviewed when the
     specific content that triggered this compaction attempt was, in fact, reviewed by NOBODY.
     This DIFFERS from `references/retry-guards.md`'s existing round-1 retry precedent, which
     works because retrying preserves and eventually resumes the SAME thread that will itself go
     on to produce a real verdict for that SAME collected diff — a failed COMPACTION attempt's
     fallback explicitly does NOT do this.

     Fixed: `compaction_attempt_coverage` is still recorded on the round's own JSONL line
     whenever a real FRESH `--uncommitted` wrapper dispatch specifically was attempted and
     returned `ok:false` — `coverage.source` when present, or the `"unknown"` sentinel when
     absent — but purely as a durable, best-effort AUDIT record. This is scoped to a failed FRESH
     `--uncommitted` dispatch alone — never a failed `--resume` call within the same round's own
     retry machinery, which never carries coverage at all. It is explicitly EXCLUDED from the
     shared reducer's convergence-gating computation — the CLEAN gate, continuity recovery, and
     the final artifact's own `coverage` field all consider ONLY successful fresh `--uncommitted`
     dispatches' coverage (round 1, or a compaction restart that actually succeeded), never a
     failed attempt's. A LOCAL pre-dispatch failure (digest verification, candidate collection/
     hash failure, or the byte-size preflight rejection) records no coverage field at all, for
     the same underlying reason plus the additional fact that no real dispatch was ever
     attempted. For `--base`/`--commit` scope, no coverage field is ever recorded. A non-repo-
     artifact session is NOT exempt from the general rule that a SUCCESSFUL restart's coverage
     DOES fold into the reducer — its `--uncommitted` dispatch against `CLEAN_REPO_DIR` DOES
     report coverage on success, ordinarily `{"status":"complete","reviewed_file_count":0,
     "omitted":[]}` against the always-empty clean repo — but a FAILED non-repo-artifact
     compaction attempt's coverage is excluded from the reducer for the exact same reason as any
     other scope's failed attempt.
2. Delete the candidate snapshot file (if one was allocated this attempt — never for `--commit`
   scope or a non-repo-artifact session, neither of which allocates one) — it was never used for
   anything. On a failed deletion here, add its path to `retired_snapshot_files` (see "Restart
   mechanism" step 3 above).
3. Log one narration line noting the compaction attempt failed and why.
4. Fall through to a NORMAL `--resume` dispatch against the STILL-ALIVE old thread (still the
   active `GROUP_THREADS` entry — never touched by a failed attempt), validated against the
   STILL-ACTIVE, untouched original snapshot, using this round's real History/Scope focus text
   exactly as an ordinary round would — this IS round R's real dispatch in the failure case.
   **This fallback dispatch is subject to the EXISTING retry-by-failure-reason procedure
   (`references/retry-guards.md`) exactly like any other round's own dispatch would be** — the
   compaction-attempt fields from steps 1 and 3 above are carried through that entire retry
   sequence in memory, and attached only once, to whatever single result eventually gets
   appended for round R (its own eventual accepted success, or its own eventual terminal
   non-CLEAN outcome if retries are exhausted) — never an intermediate failed fallback attempt
   logged as if it were round R's final result. The compaction threshold check runs again next
   round if still exceeded.
5. **This round's own single JSONL line — written once, after step 4's fallback dispatch (and any
   of its own retries) reaches its final result, exactly like any other round — additionally
   carries the failed attempt's own `compaction_attempt_failed_thread` (and
   `compaction_attempt_execution`, when available) as REQUIRED fields on THAT SAME line whenever
   step 1 applies**, alongside the incremented `compaction_attempt_failure_count` this failure
   already produced (see "Trigger" above — the same counter, not a new one). There is no separate
   append for the failed attempt at any point — round R
   still produces exactly one JSONL object, satisfying the existing one-object-per-round
   append-verify contract unchanged; the failed attempt is recorded only as additional fields
   riding on round R's own real (fallback) result, and — because that line's append already goes
   through the EXISTING mandatory append-verify hard stop — these fields inherit that same
   mandatory (never best-effort) guarantee.

## Failure isolation from the round loop

A compaction attempt's own dispatch (steps 4-6 of "Restart mechanism"/"On failure" above) must
never be confused with, or reported as, a SEPARATE round from the loop's perspective.
Concretely, round R has exactly ONE real OUTCOME, not one literal network call — "never both"
describes the RESULT, never the dispatch count: a failed fresh compaction attempt IS explicitly
followed by a real, required, SEPARATE fallback `--resume` dispatch — two genuine network calls
for that one round, not one. Round R's own real, reportable OUTCOME is either the compaction
fresh-dispatch's own success or the fallback `--resume`'s own result — never both simultaneously
claimed as round R's terminal status — and a compaction attempt's own failure reason (e.g. a
resume-safe dispatch failure like `timeout` or `nonzero_exit`) is NEVER surfaced as round R's own terminal status regardless of how many
underlying dispatches it took to get there; it is purely an internal detail of "how round R's
real outcome was reached," logged as one narration line plus the durable `compaction_attempt_*`
fields above.

**This directly conflicts with two of `references/retry-guards.md`'s own contracts — shipping
this feature requires a companion amendment to that file (see Task 19):**
1. `references/retry-guards.md`'s own MANDATORY terminal-outcome rule for exhausted retries
   (required to end as `⚠️ COULD NOT VERIFY`) does NOT apply to a failure occurring WITHIN a
   self-contained compaction ATTEMPT on the NEW candidate thread specifically — this design
   deliberately absorbs that failure into "fall through to the fallback" rather than surfacing it
   as the round's own terminal status. A compaction attempt is not "a group" in
   `retry-guards.md`'s own sense; it is an internal sub-step of producing round R's one real
   outcome. The base skill's own ordinary, non-compaction failure handling for a REAL group's
   `ok:false` response remains governed by `retry-guards.md`'s existing, unmodified rules.
2. `references/retry-guards.md`'s own no-threadId-fresh-retry and fresh-B escalation rules are
   explicitly scoped to a group's OWN true first-ever attempt, "only possible on round 1" — but a
   compaction restart's own candidate dispatch is STRUCTURALLY always at session round 2 or
   later. For candidate A specifically (never B — B already gets NONE of bullets 1-3's retry
   machinery, per "Retry topology" above, and a broader "any compaction candidate" wording would
   silently re-enable exactly the bug that exclusion closes), `retry-guards.md`'s own "no entry
   yet"/"true first-ever attempt" language is keyed on the CANDIDATE's own independent
   thread-history tracking (see "Retry topology" above), NOT on the session's own round-index,
   and NOT on `GROUP_THREADS` (which keeps meaning the OLD, pre-existing thread throughout a
   compaction attempt, per this section above). Candidate A is its own independent "first
   attempt" lifecycle for these SPECIFIC mechanics, by construction, REGARDLESS of what round
   number in the session it actually occurs at — the base skill's own ordinary round-1 groups
   keep `retry-guards.md`'s literal round-1 scoping exactly as written; this is a scoped
   exception for candidate A only, never B, and never a change to what "round 1" means for an
   ordinary group.

## Interaction with `--keep-evidence`

It is not yet known, at compaction time, whether this SESSION will end CLEAN or not — and the
`--keep-evidence` contract requires every thread in `GROUP_THREADS`/`LEAKED_THREAD_IDS` to
survive an eligible non-CLEAN outcome for later inspection. **The old thread is never eagerly
deleted.** "Ordering on success"'s own promotion step above always routes it through the EXISTING
`LEAKED_THREAD_IDS` mechanism instead of a direct `--cleanup` call — `SKILL.md`'s Phase 3's
already-keep-evidence-gated terminal cleanup then handles it with zero special-casing: deleted
normally on `✅ CLEAN` (or any outcome with `--keep-evidence` OFF), preserved alongside the new
thread on an eligible non-CLEAN outcome with `--keep-evidence` ON. This reuses machinery that
already exists for exactly this "an earlier thread was abandoned mid-session" shape (see
`SKILL.md`'s own Guards → "Empty / failed review" handling for round-1 retries), rather than
inventing a second cleanup path with its own edge cases.

## Durable backstop for abandoned threads

`LEAKED_THREAD_IDS`/`GROUP_THREADS` are in-memory facts Claude carries across separately-
dispatched tool calls for the rest of the run — the existing design already relies on this for
ordinary round-1 retries. Compaction adds more state of this shape (an abandoned old thread on
every successful restart; a dead-end thread on every failed attempt), extended to cover both here
too, rather than leaving compaction as the one mechanism relying on memory alone:
- A successful compaction's `compacted_from_thread` field (already logged — see "Logging" below)
  is itself sufficient to reconstruct that the named thread is abandoned and needs the same
  treatment as a `LEAKED_THREAD_IDS` entry, purely by reading the JSONL log.
- A FAILED compaction attempt's own threadId(s) (when any exist) are additionally recorded as a
  REQUIRED field on that same round's own single JSONL line (never a separate append, and never
  best-effort — see "On failure" above) — `compaction_attempt_failed_thread`, an ARRAY of 1 or 2
  thread ids (see "Retry topology" above). This field is what makes the "never permanently
  unaccounted-for" guarantee actually true, so it inherits the SAME mandatory append-verify
  guarantee as the rest of that round's line.
- `SKILL.md`'s Phase 3 and the final-verdict artifact's own thread enumeration
  (`references/keep-evidence.md`'s retention rules; the `threads[]` array in the durable result
  artifact) are both extended to union in every `compacted_from_thread` and
  `compaction_attempt_failed_thread` value found anywhere in the session's own JSONL log, in
  addition to whatever `GROUP_THREADS`/`LEAKED_THREAD_IDS` memory currently holds (see Task 21
  for the exact `SKILL.md` edit).

## Preserving failed-attempt telemetry

Several `ok:false` reasons (`timeout`, `nonzero_exit`, `missing_task_complete`, `invalid_json`,
and others) still launch `codex exec` and so still carry a genuine `execution` object (elapsed
time, and usage when available) even on failure. Fixed: when a failed compaction attempt's own
response carries an `execution` object, it is preserved on round R's own JSONL line (alongside
`compaction_attempt_failed_thread`, per "On failure" above — never a separate line) as
`compaction_attempt_execution` — **always an array, one `execution` object per failed sub-attempt
that carried one, in attempt order, even when there is only ever a single entry** — there is
exactly ONE shape, always, never varying by how many sub-attempts actually occurred.
`round_wall_seconds` for a round that included a failed compaction attempt covers the WHOLE round
timeline — from immediately before the compaction attempt's own dispatch through the fallback
dispatch's own completion — consistent with its existing definition as coordinator-measured wall
time for the entire round, not per-dispatch.

**Applies to a retry-then-succeed round too, not only a round that falls all the way through to
the fallback.** Whenever a compaction round's PATH TO SUCCESS included one or more earlier failed
sub-attempts that each carried an `execution` object, those are ALSO preserved — as
`compaction_attempt_execution`, the SAME always-an-array shape — on this SAME successful round's
own line, alongside `compacted_from_thread` and the snapshot-lineage fields. Exactly the THREE
sub-cases from "Retry topology" above can produce this (never a "B retries" case, since B is
single-shot by construction): (a) candidate A's own retry-then-succeed via `--resume`; (b)
candidate A's own bullet-1 no-threadId fresh retry succeeding; or (c) candidate A was exhausted
entirely and thread B then succeeded on its own single, unretried attempt — in case (c)
specifically, the preserved `execution` entries belong to A's own failed attempt(s), never to B.

**Surfaced in the final report, not just durably logged.** The Final Report's existing
execution-telemetry section (`references/execution-telemetry.md` section 6) is extended to also
list, for any round that carries a `compaction_attempt_execution` value, a clearly labeled
separate line — distinct from that round's own real `execution`/`usage` reporting, never merged
into it. The wording branches on this round's own real outcome, never assumes "before falling
back" unconditionally:
- For a round whose real outcome is the fallback: *"Round R also attempted a compaction restart
  that failed after using `<input>`/`<output>` tokens (`<elapsed>`s) before falling back."*
- For a round whose real outcome is a success (any of the three sub-cases above): *"Round R's
  compaction restart succeeded after an earlier attempt used `<input>`/`<output>` tokens
  (`<elapsed>`s)."*

Both templates report each preserved sub-attempt's own figures, never conflated with the round's
own real dispatch numbers. **Both templates must also handle a preserved `execution` entry that
has NO `usage` object at all** — `references/execution-telemetry.md`'s own established contract
allows an `execution` object to legitimately carry only `elapsed_seconds` with `usage` entirely
absent; whenever a preserved entry lacks a `usage` object, both templates substitute that
reference's own established "usage unavailable" wording in place of the `<input>`/`<output>`
tokens portion — e.g. *"Round R also attempted a compaction restart that failed after
`<elapsed>`s (usage unavailable) before falling back."*

**A partial `usage` object (only one of `input_tokens`/`output_tokens` present) is handled
independently per-value, not all-or-nothing.** The wrapper's own `build_execution_json()`
retains a non-empty `usage` object exactly as received with no member validation — a real, valid
response carrying only `{"input_tokens": 12}` (no `output_tokens` key at all) is preserved as-is.
Report each of `<input>`/`<output>` independently — whichever value is actually present in
`usage` is reported normally; whichever is absent (whether because `usage` itself is completely
missing, or present but missing just that one member) is reported with its own "unavailable"
wording — e.g. *"Round R also attempted a compaction restart that failed after using 12 input
tokens (output tokens unavailable) (`<elapsed>`s) before falling back."* This one rule uniformly
covers all three shapes: full usage (both values reported), partial usage (one reported, one
marked unavailable), and no usage at all (both marked unavailable, collapsing to the simpler
"usage unavailable" wording as a natural special case).

**"Present" must mean "present AND valid," reusing the EXISTING malformed-usage validation, never
a bare key-existence check.** `input_tokens`/`output_tokens` can be present but UNUSABLE (a
string, `null`, negative, or otherwise non-integer value) — apply the SAME non-negative-integer
validation this file already uses for `COMPACTION_BASELINE_TOKENS` (see "Trigger" above) to each
token value independently here too; a present key whose value fails that validation is treated
IDENTICALLY to an absent key (its own "unavailable" wording), never rendered as a literal
malformed value.

## A failed compaction attempt is a superseded attempt, not a novel evidence-lifecycle case

A round with a failed compaction attempt followed by its own fallback `--resume` has TWO physical
dispatches. This is exactly the EXISTING "superseded attempt within a round" case
`references/retry-guards.md` already defines for an ordinary round's own retries — apply it
unchanged, inventing nothing new. The failed compaction attempt's own raw event-log file (when
`--capture-evidence` is ON) is deleted, not retained, exactly like any other superseded attempt's;
its own last-message file (when `--keep-evidence` is ON) is never kept, exactly like any other
superseded attempt's — only the round's FINAL attempt (the fallback dispatch) participates
normally in whichever of the two flags is ON. This also avoids any path collision: the compaction
attempt and the fallback each get their own temp files under the existing per-attempt allocation
scheme, exactly as two retries of the same round already would.

## Logging

The compaction round is logged like any other round, with these additions, each present only on
the round(s) they actually apply to:
- `compacted_from_thread` — top-level, the abandoned thread's id, on a successful compaction
  round.
- `compaction_attempt_failed_thread` / `compaction_attempt_execution` /
  `compaction_attempt_coverage` — an optional trio, present when a compaction attempt failed
  (falling through to the fallback) OR when the round's own path to success included an earlier
  failed sub-attempt (see "Retry topology" above's three sub-cases). **ONLY sub-case (iii)
  (candidate A genuinely abandoned, thread B succeeds) ever populates
  `compaction_attempt_failed_thread`** — sub-cases (i) and (ii) both involve the SAME thread
  succeeding after an earlier failure of its own, so nothing was ever abandoned; recording it
  there would cause it to be double-cleaned, or falsely reported as leaked. All three sub-cases
  MAY (conditionally, never unconditionally) populate `compaction_attempt_execution` (present
  only when the earlier failed response actually carried an `execution` object) and
  `compaction_attempt_coverage` (present only when that earlier failed response was itself a
  fresh `--uncommitted` dispatch). A round can carry the `compaction_attempt_*` trio ALONE (a
  failed attempt, fallback succeeded or not), the OTHER three (`compacted_from_thread` +
  `snapshot_digest_before`/`snapshot_digest_after`) alone (a clean first-attempt success), or
  BOTH groups together (any of the three sub-cases above).
- `snapshot_digest_before` / `snapshot_digest_after` — top-level, on a successful compaction
  round (identical values for `--commit` scope, by construction — see "Restart mechanism" step 3
  above).
- `candidate_snapshot_path` — top-level, present only on a round whose own compaction attempt
  SUCCEEDED under `--uncommitted`/`--base` scope, alongside `snapshot_digest_after`.
- `coverage_source` — generalized (see "Restart mechanism" step 4 above) to also cover a
  successful `--uncommitted` compaction restart, not only round 1.
- `compaction_attempt_failure_count` — present on TWO kinds of rounds: a round whose own
  compaction attempt fell through to the fallback (the counter's current value after
  incrementing), and a round whose own compaction attempt SUCCEEDED (the explicit value `0`,
  representing the reset).
- `compaction_disabled_reason` — present only on the ONE round that ever sets this latch, never
  repeated on later rounds once set. Exactly one of `"baseline_at_or_above_threshold"`,
  `"baseline_unusable"`, `"repeated_fresh_dispatch_failure"`, `"byte_budget_exceeded"`.
- `retired_snapshot_files` — an array, present only when non-empty, on whichever round's own line
  is being written when a snapshot-file deletion failure is discovered (or a deferred backfill
  from continuity recovery attaches to it).
- `target.scope_value` — round 1's own line only, whenever `--compact` was given: the literal
  `--base`/`--commit` argument value, omitted for `--uncommitted`.
- `target.resolved_commit_sha` — round 1's own line only, `--commit` scope, whenever resolution
  succeeded.
- `target.original_scope_framing` — round 1's own line only, whenever `--compact` was given
  (regardless of scope): the Why + task-specific Scope text captured once, before round 1's own
  first dispatch attempt, excluding any pasted artifact text, never overwritten by a later
  retry's own different focus.

`finding_id`/`claim_id` numbering continues incrementing globally across the compaction boundary —
never reset — so the existing claim-ledger reducer keeps working over the whole log unmodified.

**Shipping this feature requires bumping `schema_version`** — see Task 21 for the exact
`SKILL.md` edit (from `2` to `3`, per this plan's own Global Constraints).

## Scope (v1)

- **Single-reviewer only (`GROUP="main"`).** Parallel mode is explicitly out of scope for v1 —
  each group could cross its own threshold at a different round, meaningfully increasing
  design/testing surface for a first pass. **Operationally enforced, not merely stated:** when
  `COMPACT_MODE` is ON, `SKILL.md`'s Phase 1 "Determine review mode" (run once before round 1) is
  forced to single-group `main`, regardless of what the normal file-count sizing heuristic would
  otherwise select — a hard override, not a rejection of the `--compact` request (see Task 20 for
  the exact `SKILL.md` edit). Removing this restriction is future work, not a v1 goal.
- **`MAX_ROUNDS` unaffected in meaning** — a compaction round consumes one increment of the round
  counter like any other round; no separate cap or exemption.

## Cost tradeoff, stated plainly

A compaction restart costs roughly as much as an ordinary round-1 dispatch (diff re-collection +
full framing), and Codex must re-establish its own understanding of the current code via its
read-only shell access rather than relying on a rich internal reasoning trail it no longer has —
this is a real, one-time cost per compaction event, not free. The tradeoff being made is: pay
that bounded, one-time cost periodically, in exchange for capping the otherwise-unbounded linear
growth described above. This is disclosed as a deliberate exchange, not a pure win.

## Explicitly out of scope for v1

- Parallel mode (see "Scope (v1)" above).
- User-configurable threshold (fixed constant, `COMPACT_THRESHOLD = 8,000,000`, for now).
- Any LLM-authored (as opposed to deterministic, JSONL-derived) summarization of closed claims.
- A true byte-bound on open-claim content (each kept fully unabridged) or on closed-claim
  marker-reason length (only count-bounded, at `CLOSED_CLAIM_LIMIT = 20`) — a session whose claim
  payload, or whose re-collected diff/artifact, exceeds `COMPACT_BYTE_BUDGET` has compaction
  effectively disabled for the rest of that session (see "Byte-budget preflight" below);
  addressing this would need either bounding evidence/reason length or LLM summarization, both
  deferred.
- Recovering from an intrinsically-large review whose freshly-compacted baseline is itself over
  threshold — compaction is simply disabled for the rest of that session once this is detected
  (see "Benefit-free-restart-loop guard" below); no attempt is made to shrink the underlying
  content itself.
- True crash-safety for a candidate snapshot file (and, on the success sub-case, the newly-created
  Codex thread alongside it) in the narrow pre-append window between its own creation and that
  round's own JSONL append (see "Retired- and provisional-snapshot durability" above): an
  interruption in exactly that window can leave one orphaned candidate file, and on the success
  sub-case one orphaned thread, with no durably-recorded path to retry cleanup for either; not
  addressed further in v1.

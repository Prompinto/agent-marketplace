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

Once this counter reaches `COMPACTION_MAX_CONSECUTIVE_FRESH_FAILURES = 2`, compaction is disabled
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
ever grows across a session — in a claims-heavy review, this section could itself eventually
threaten the wrapper's 131,072-byte combined-prompt cap, at which point compaction would
permanently fail via `artifact_too_large`. Fixed with a small, bounded rule (no LLM
summarization): include the `CLOSED_CLAIM_LIMIT = 20` most-recently-closed claims' one-line
summaries verbatim (ordered by `source_round` descending), and collapse everything older into a
single line: `<N> additional claims resolved/retracted before round <R>; see the session's own
JSONL log for full detail.` This bounds the closed-claim section's own contribution to a small,
fixed COUNT regardless of how many rounds a session eventually runs.

**Disclosed, accepted residual limitation.** The closed-claim cap bounds COUNT (20 entries), not
bytes — the marker-reason grammar requires only a non-empty sentence, with no length limit, so 20
valid-but-long closure reasons are not actually "small." Open claims remain fully unabridged with
no count or byte bound. So a session with a large number of open/closed claims, one exceptionally
large finding, OR a large re-collected diff/artifact can still produce a rendered prompt exceeding
the wrapper's 131,072-byte cap.

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
authoritative collection above. `120,000` is tighter than the wrapper's real 131,072-byte cap —
the remaining ~11,000-byte margin absorbs the wrapper's own fixed prompt scaffolding text outside
the caller-supplied focus, which this estimate does not measure directly.

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
verification" above; abort to the normal `--resume` fallback (step 6 below) immediately if its
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
failure (log the narration, fall through to the normal `--resume` fallback in step 6 below) —
never dispatch against a `CLEAN_REPO_DIR` whose emptiness wasn't just reconfirmed. Only once this
check passes does the `--uncommitted` dispatch against `CLEAN_REPO_DIR` proceed, producing an
empty diff as designed, with the wrapper's own no-diff branch falling back to reviewing the focus
text — now containing both the artifact and the digest.

**This recheck runs before EVERY separate fresh dispatch for a non-repo-artifact session** — the
original attempt, the no-threadId fresh retry (see "Retry topology" below), and thread B's own
fresh dispatch alike — never assumed still valid from an earlier check moments or minutes in the
past. **Also required immediately before the step-6 fallback dispatch**, whenever this session is
non-repo-artifact: if it fails there, this is logged as a disclosed risk, never a hard stop, since
the fallback is this round's own real, required outcome with no further fallback beneath it.
Ordinary, non-compaction `--resume` rounds sharing this identical base-skill property (no round
is otherwise ever forced to recheck `CLEAN_REPO_DIR`'s cleanliness before an ordinary resume) are
an inherited, pre-existing limitation this feature does not newly introduce.

**Fail CLOSED wherever a real alternative still exists.** Candidate A's own resume-retries and
the bullet-3 same-thread retry (see "Retry topology" below) treat a failed recheck exactly like
any other compaction failure — abandon this compaction attempt, fall through to step 6's
fallback, never dispatch into a KNOWN-polluted directory. This abandonment unconditionally adds
A's own already-known thread id to `LEAKED_THREAD_IDS`/`compaction_attempt_failed_thread` before
falling through — this is a LOCAL, pre-dispatch check failure, never a wrapper response, so the
abandonment is entirely local knowledge, nothing to discover from a response. The "log and
continue, disclosed risk" treatment is reserved ONLY for the step-6 fallback dispatch itself and
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
  round's own JSONL append (see "Retired- and provisional-snapshot durability" below): an
  interruption in exactly that window can leave one orphaned candidate file, and on the success
  sub-case one orphaned thread, with no durably-recorded path to retry cleanup for either; not
  addressed further in v1.

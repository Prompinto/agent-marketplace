# Execution telemetry (always on, no opt-in) — reference

> Read this file in full: like "Snapshot integrity" and "Claim ledger," this is not a flag — it
> applies to every `codex-stream-review:ccs` invocation that gets past Phase 0's early-exit checks.
> Everything below is required at three later points in this run: Phase 1 Step 1's own round-level
> wall-clock timestamps (taken right before issuing this round's dispatch calls, and again once all
> of this round's groups' results are in hand), Phase 2 step 6's JSONL line construction (the
> `execution`/`round_wall_seconds` fields), and the Final report's own execution-telemetry bullet.

## 1. What this is, and why

Negotiated with Codex across 4 rounds (see `docs/2026-09-05-codex-stream-review-improvement-
roadmap-design.md`'s "Phase 3 negotiation" section for the full record) — this closes the roadmap's
old finding #19 (no cost/token visibility anywhere in the final report, `model_reasoning_effort=
xhigh` hardcoded with no visibility into what that actually costs). Codex live-verified, on the
actual installed `codex-cli 0.153.0`, that `codex exec --json`'s own `turn.completed.usage` event
DOES populate real token-usage figures (`input_tokens`/`cached_input_tokens`/
`cache_write_input_tokens`/`output_tokens`/`reasoning_output_tokens`, sometimes `total_tokens`) —
this project's own fake-CLI test fixture emitting an empty `{}` there by default is a confirmed
non-representative simplification of the FIXTURE, not evidence the real data doesn't exist.

**Best-effort only, never authoritative billing/quota data.** No cost subsystem, no caller-facing
configuration flag (always on, no `--no-telemetry` opt-out or equivalent), no model/quota-lookup API
call, and never a "model" identity value anywhere — the wrapper only ever sets
`-c model_reasoning_effort=xhigh` on a fresh dispatch (never `--model`), so reasoning effort, not a
model name, is the only "what ran" fact this feature's own mechanics ever surface.

## 2. Extraction — wrapper-owned, `run-ccs-review.sh` only

Entirely internal to `scripts/run-ccs-review.sh`'s own `build_execution_json()` function — nothing
in this skill or its callers ever invokes a separate extraction step of their own. Reuses the exact
same tolerant `jq -Rn -c '[inputs | fromjson? | ...] | ...'` pattern already established in
`references/capture-evidence.md`'s own extraction (a raw grep/direct-`jq` read is unsafe against the
wrapper's actual mixed stdout/stderr event log — a real capture can contain a non-JSON line that
would otherwise break naive parsing) — applied to that SAME dispatch's own private `$EVENTLOG` file
(the identical per-dispatch event log `--capture-eventlog`'s own copy-then-delete step already reads
from), read BEFORE it is ever deleted, extracting the LAST `"type":"turn.completed"` event's own
`.usage` object.

`stream-review` (the plugin's other, lower-level skill) has no equivalent — this is `/ccs`-specific,
mirroring how `references/keep-evidence.md` already notes `stream-review` has no orchestration
concept of its own for a similarly `/ccs`-specific feature; `scripts/run-stream-review.sh` is
untouched by this feature entirely.

## 3. Availability — timing vs. ownership, precisely

Two SEPARATE facts:

- **TIMING** — `DISPATCH_START_SECONDS`, a plain `$SECONDS` snapshot, taken UNCONDITIONALLY right
  before the background `codex exec`/`codex exec resume` launch line. Nothing gates this; it always
  runs immediately before the dispatch attempt.
- **OWNERSHIP** — `$DISPATCH_PID`, a variable dedicated solely to `build_execution_json()`'s own
  eligibility check, deliberately SEPARATE from `$CODEX_PID` (the pre-existing variable
  `on_signal()`'s own `kill_process_group` targets to reap/terminate the dispatched child).

  Three earlier revisions were each tried and each introduced its own confirmed-live bug before
  landing on this design:
  1. A separate "started" marker gated on `CODEX_PID=$!` succeeding — a signal between the two
     assignments ran the kill before the marker was ever set (reproduced directly).
  2. The marker set unconditionally alongside the timing snapshot instead — a signal between that
     marker and the launch itself ran the kill before any child even existed (reproduced directly).
  3. Dropping the separate marker and using `$CODEX_PID` itself as the sole eligibility signal,
     kept alive past its own reap so a later extraction could still read it — this reintroduced
     exactly the stale-PID risk this file's own `UNTRACKED_PID` precedent exists to prevent: a
     signal landing after `wait "$CODEX_PID"` reaped the child, but before the (necessarily
     delayed) reset, would `kill_process_group` a PID the OS may already have recycled for
     something unrelated (reproduced directly).

  The two properties `$CODEX_PID` needs to satisfy — "reset to empty immediately once reaped, so a
  later signal can never act on a stale PID" and "stay readable for telemetry purposes long after
  that reap" — are simply incompatible for one variable. **Final design: two variables, two
  lifetimes.** `$CODEX_PID` is reset to empty immediately after every `wait "$CODEX_PID"` reaps it
  (matching `UNTRACKED_PID`'s own precedent exactly). `$DISPATCH_PID` holds the identical PID value
  once set, but is never reset afterward — safe to read at any point after the dispatch, long after
  `$CODEX_PID` has already gone back to empty. Both are set together, atomically with respect to
  signal delivery, immediately after the background launch — but NOT via `trap '' INT TERM`
  (ignore): an ignored disposition survives `exec()`, so a signal landing during that window would
  leave the just-launched codex process permanently unable to receive a graceful TERM for its whole
  lifetime (confirmed directly), and an ignore trap DISCARDS rather than defers the signal, so a
  genuine Ctrl-C there could leave the round running with no visible effect. Instead: `trap
  'DEFERRED_SIGNAL=1' INT TERM` (a CAUGHT trap, which always resets to default on exec regardless of
  timing, so the dispatched codex process is unaffected either way) brackets
  `CODEX_PID=$!; DISPATCH_PID="$CODEX_PID"`; `trap on_signal INT TERM` then restores the normal
  handler; and finally `[ "$DEFERRED_SIGNAL" -eq 1 ] && on_signal` invokes the real handler directly
  if a signal was recorded during the window — deferred, never dropped. Because the assignment pair
  is now atomic either way, this also closes the one gap
  every earlier revision explicitly accepted as unavoidable — the launch-to-`$!`-capture instant
  itself no longer exists as a gap at all.

**Every terminal path that can have a genuine dispatch is gated on `$DISPATCH_PID`** — normal
success; every one of the 7 post-dispatch failure reasons (`timeout`, `nonzero_exit`,
`missing_task_complete`, `no_final_answer`, `invalid_json`, `schema_mismatch`, `no_thread_started`);
and `interrupted` when the signal lands after the dispatch launched — reaps the child via
`$CODEX_PID` first (if not already reaped), THEN extracts telemetry from `$EVENTLOG` via
`$DISPATCH_PID` (still on disk, read before deletion), THEN splices the `execution` object into the
response, all without ever altering the actual review verdict/success-or-failure determination. This
ordering is no longer load-bearing the way it was under the earlier `$CODEX_PID`-only design —
`$DISPATCH_PID` is unaffected by whichever point `$CODEX_PID` gets reset at.

**Never eligible at all:** the three pre-dispatch failures (`bad_args`, `git_error`,
`incomplete_collection` — nothing was ever launched, neither PID variable was ever touched), and a
signal landing before the background launch itself even begins (while INT/TERM were still on their
normal `on_signal` disposition, i.e. before the masked section starts). No telemetry in that case —
an honest best-effort omission, never a fabricated or racy record — and the signal handler never
crashes or hangs either way.

## 4. Shape

```json
"execution": {"elapsed_seconds": 42, "usage": {"input_tokens": 512, "output_tokens": 77}}
```

Spliced into the wrapper's own JSON response (both `ok:true` success and `ok:false` failure shapes)
as ONE additional, optional, additive object — backward compatible, existing consumers reading
`.ok`/`.threadId`/`.verdict`/`.coverage` are unaffected.

- `elapsed_seconds` — present whenever `execution` is present at all (i.e. whenever `$DISPATCH_PID`
  was captured for this dispatch).
- `usage` — OMITTED ENTIRELY (never an empty `{}` placeholder) when the extracted value is either
  genuinely absent (no `turn.completed` event ever found, or extraction/parsing failed) OR
  present-but-empty (`{}` — the real CLI does emit this on some successful turns, and this project's
  own fake-CLI fixture models both cases via `FAKE_CODEX_USAGE_JSON`). Both collapse to the
  identical "usage unavailable" reporting outcome. A genuinely non-empty usage object (even one with
  individual zero-valued counters — a real zero is meaningful, distinct from no data at all) is kept
  and reported as-is.
- Never a `"model"` field or value anywhere in this object, or anywhere else this feature writes —
  see section 1 above.

## 5. Persistence — JSONL schema

`execution` is genuinely PER-GROUP data (unlike the claim ledger's fields, which stayed top-level
because `claim_id` is self-disambiguating) — so its placement differs by round shape:

- **Single-reviewer round (`GROUP="main"`):** a TOP-LEVEL field on that round's JSONL line, the same
  nesting level as `thread_id`/`coverage_source`.
- **Parallel round:** nested INSIDE each dispatched group's own `groups[]` entry — a sibling of that
  entry's own `thread_id`/`focus`/`codex_review` keys (see `references/parallel-mode.md`'s own
  "JSONL field: `groups`" section, updated alongside this file, for the exact nesting — mirroring
  exactly how that same section already nests `kept_last_message_path` per group, never
  `investigation_evidence`/`claim_closures[]`'s always-top-level rule).

Omitted entirely — never a placeholder — whenever `$DISPATCH_PID` was never captured for that
(round, group)'s own dispatch (one of the three pre-dispatch failures, or a signal landing before
the masked launch section even starts — see section 3 above).

**A NEW, SEPARATE, round-level `round_wall_seconds` field — never confused with `execution`, never
derived from it.** This is COORDINATOR-measured (Claude's own orchestration timing — dispatch-
fan-out to all-groups-joined), not something the wrapper can know (the wrapper only ever sees its
own single dispatch, never the whole round). Computed by Claude: take a timestamp right before
issuing all of this round's backgrounded dispatch calls (`SKILL.md`'s Phase 1 Step 1), and another
right after all of this round's dispatched groups' results are in hand (Phase 1 Step 2's own "wait
for ALL N groups" rule) — the difference is `round_wall_seconds`. **Always TOP-LEVEL, single-
reviewer or parallel alike** — one value per round regardless of how many groups ran within it,
since it describes the whole round's wall-clock cost.

**MUST NEVER be computed by summing individual groups' own `execution.elapsed_seconds` values** —
groups run CONCURRENTLY within a round (Phase 1's own N-concurrent-dispatch design), so summing
would overstate true wall-clock cost; only a genuine dispatch-to-joined timestamp delta is correct.

## 6. Final report content

A new bullet in `SKILL.md`'s own Final report structure, headed **"best-effort execution telemetry
— not authoritative billing or quota data"** in the actual report content (see section 1 above for
why), listing:
- **Effort** — reasoning effort only: "xhigh on fresh dispatch; inherited on resume" (a `--resume`
  call carries no `-c` flags of its own) — NEVER a model value.
- **Per-round/per-group elapsed time** — from each round's own `execution.elapsed_seconds`
  (per-group, in parallel mode).
- **`round_wall_seconds`** — per round, from section 5 above.
- **Token usage when available** — from each round/group's own `execution.usage`; state "usage
  unavailable" for a round/group where it was omitted (section 4 above).

Any summed figure across rounds/groups presented in the report must be explicitly labeled as a sum,
never presented as wall-clock time or billable cost — see section 5's own warning against summing
concurrent groups' elapsed times as a substitute for `round_wall_seconds`.

## 7. Non-goals (explicit, per the roadmap's own Standing rule)

No cost/billing subsystem. No caller-facing configuration flag (always on, no `--no-telemetry` or
similar). No full raw event-log retention as a side effect of this feature — the wrapper's existing
eventlog deletion timing/pattern is otherwise unchanged; this feature only reads `$EVENTLOG` earlier
in the same lifecycle `--capture-eventlog`'s own copy-then-delete step already uses, never retains
it longer. No model/quota-lookup API call. No attempt to report a "model" identity value anywhere.

## 8. Interaction with `--capture-evidence` / `--keep-evidence` / snapshot integrity / claim ledger

Fully independent of all four. This feature reads `$EVENTLOG` for a different purpose (`.usage`,
never investigation commands) than `--capture-evidence` does (`item.completed`/`command_execution`,
never `.usage`) — both may read the same dispatch's `$EVENTLOG` file in the same script invocation,
extracting different fields from it, with no interaction or ordering requirement between them (see
`scripts/run-ccs-review.sh` for both extraction call sites: `build_execution_json()` and the
`--capture-eventlog` copy step). No overlap with `--keep-evidence`'s own domain (a failed round's
last-message text) or the snapshot/claim-ledger mechanisms (the reviewed subject's own integrity;
convergence-logic correctness) — this feature's own JSON is purely additive reporting, never
load-bearing for any convergence, retry, or integrity decision elsewhere in this skill.

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

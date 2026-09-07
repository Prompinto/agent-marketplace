# Scenario: review-log-integrity-failure-corrupt-append

**Group:** A (terminal-status matrix)
**Targets:** `exit_state == "REVIEW_LOG_INTEGRITY_FAILURE"`, via the JSONL-append-verify failure
path specifically (`SKILL.md`'s "Review history log" -> "Write": append via `jq -nc >>`, then
verify with `tail -n 1 <log> | jq -e '.round == <N>'` -- a hard stop on failure, never best-effort).

This is a **sibling scenario to `review-log-integrity-failure-stale-schema`** -- both produce the
same `exit_state`, via two genuinely different triggers named separately in `SKILL.md`'s Guards
section ("differing only in WHEN it's detected... a failed JSONL-append verification... or a stale
`schema_version`..."). This one is the append-verification trigger.

## Round 1's own append fails -- no round 2 needed

Unlike `snapshot-integrity-failure` (which structurally needs a real round 2 to ever run its own
check), the append-verify step runs on EVERY round, including round 1 itself. `setup.sh` prints the
exact real log-path convention (`~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/
<session-id>.jsonl`) and the repo-slug transform to apply to `REPO_DIR`'s own basename. The driving
agent creates that exact file and `chmod 444`s it (no write bit for anyone, including its owner)
BEFORE round 1's own append is ever attempted -- so the real `jq -nc ... >> <path>` redirect
genuinely fails with a permission error, and the real verify step genuinely finds nothing there to
match `round == 1`. This is real corruption via a real permission change, not a simulated failure.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for round 1's dispatch call (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat").

## How to run

```bash
bash codex-stream-review/evals/scenarios/review-log-integrity-failure-corrupt-append/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `FAKE_CODEX_INVOCATION_LOG`, and `REPO_SLUG`. Invoke
`codex-stream-review:ccs` against `REPO_DIR` with:

> review the uncommitted change in this fixture repo

Right after Phase 0 mints `SESSION_ID`, but before round 1's append: create
`~/.claude/plugins/data/codex-stream-review/ccs-logs/<REPO_SLUG>/<SESSION_ID>.jsonl` and
`chmod 444` it. Run round 1's real dispatch, attempt the real append (fails), confirm the real
verify step fails, and report `🛑 REVIEW LOG INTEGRITY FAILURE`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> review-log-integrity-failure-corrupt-append
```

## Expected result

- `exit_state`: `"REVIEW_LOG_INTEGRITY_FAILURE"`
- `claims`: `null`
- `round_count`: `0` -- no round's own line was ever durably logged this run (the schema's own
  degenerate-case allowance for exactly this situation); this is what distinguishes this scenario's
  result from its stale-schema sibling's `round_count: 1`
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"` (round 1's own dispatch DID obtain a
  real threadId before the append ever failed; Phase 3's unconditional cleanup for this status runs
  regardless)
- `input_errors`: `null`
- `FAKE_CODEX_INVOCATION_LOG`: exactly 2 lines (`mode=fresh`, `mode=delete`)

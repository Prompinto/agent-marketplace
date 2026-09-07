# Scenario: snapshot-integrity-failure

**Group:** A (terminal-status matrix)
**Targets:** `exit_state == "SNAPSHOT_INTEGRITY_FAILURE"`.

Confirms `references/snapshot-integrity.md`'s revalidation check -- a SHA-256 hash of the reviewed
subject taken once at round 1, revalidated before every round 2+ dispatch -- genuinely fires a hard
stop when Claude's own local `SNAPSHOT_FILE` is deleted or corrupted mid-run, and that Phase 3's
unconditional cleanup (this is one of the two statuses that cleans up regardless of
`--keep-evidence`) genuinely runs.

## Why round 1 must NOT converge

Round 1 never runs the revalidation check at all ("there is nothing yet to revalidate against --
the snapshot IS round 1's own baseline"). To ever reach round 2, round 1 must end with a genuinely
open claim. `setup.sh` uses `eval_make_fixture_repo`'s own real off-by-one bug and scripts
fake-codex to report it accurately; the driving agent genuinely ACCEPTS the finding and applies the
real fix, but the claim stays `open` (accept-only, no `DISPOSITION` closure yet -- per
`references/claim-ledger.md` section 6) -- so round 1 is not eligible for CLEAN and a real round 2
attempt follows.

## The corruption is real, done live by the driving agent

`setup.sh` cannot pre-create `SNAPSHOT_FILE` -- it's allocated live, mid-run, at the literal
`mktemp`'d path the session itself resolves (right after Phase 1's sizing step, per
`references/snapshot-integrity.md`'s "Allocation" section). The driving agent must genuinely `rm -f`
(or truncate) that exact path itself, live, between round 1 finishing and round 2's own
revalidation check -- not simulated, not asserted, an actual file deletion the check then actually
detects.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for round 1's dispatch call only (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat") -- round 2 never reaches a dispatch at
all, so no `FAKE_CODEX_SCENARIO` is ever needed for it, and `FAKE_CODEX_INVOCATION_LOG` should show
no second dispatch line.

## How to run

```bash
bash codex-stream-review/evals/scenarios/snapshot-integrity-failure/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, `FAKE_CODEX_INVOCATION_LOG`, and the literal `FAKE_CODEX_FINAL_ANSWER`
JSON for round 1. Invoke `codex-stream-review:ccs` against `REPO_DIR` with:

> review the uncommitted change in this fixture repo

Round 1: accept the (real) off-by-one finding, apply the real fix to `lib.py`. Before round 2's
revalidation check, delete the session's own `SNAPSHOT_FILE`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> snapshot-integrity-failure
```

## Expected result

- `exit_state`: `"SNAPSHOT_INTEGRITY_FAILURE"`
- `claims`: `null` (per schema -- neither this status nor `REVIEW_LOG_INTEGRITY_FAILURE` can vouch
  for claims about the reviewed subject)
- `round_count`: `1` (only round 1 ever completed and was durably logged)
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"` -- Phase 3's unconditional cleanup
  rule for this status runs regardless of `--keep-evidence`
- `input_errors`: `null`
- `FAKE_CODEX_INVOCATION_LOG`: exactly 2 lines (`mode=fresh` for round 1, `mode=delete` for Phase 3
  cleanup) -- confirms round 2 never reached a codex dispatch, real or fake, at all

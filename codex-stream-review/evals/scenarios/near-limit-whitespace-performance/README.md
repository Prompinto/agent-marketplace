# Scenario: near-limit-whitespace-performance

**Group:** regression guard (not in the original ~28-scenario matrix). Added because building
`input-too-large` surfaced and led to fixing a real superlinear-hang bug in
`_focus_is_empty()` (`scripts/run-ccs-review.sh`/`scripts/run-stream-review.sh`) -- see this
directory's own `README.md`, "A real bug this harness already found (and fixed)".

**Targets:** a real terminal status reached quickly on a deliberately whitespace-dense,
near-(but-safely-under)-limit `--focus` text -- the exact input shape the old
`${var//[[:space:]]/}` bash substitution choked on (confirmed ~6KB took ~13s; near
`PROMPT_SIZE_LIMIT_BYTES`'s 131072-byte ceiling this would have hung for hours). The fix (`tr -d
'[:space:]'`) is already merged -- this scenario is the regression guard confirming it stays fixed.

## The fixture

`setup.sh` generates a ~90000-byte focus reference text: a short real Why/Scope preamble, then
dense whitespace filler (long runs of spaces/tabs/newlines with sparse real words interspersed, so
it's never mistaken for empty/whitespace-only). Comfortably under `PROMPT_SIZE_LIMIT_BYTES`
(131072) even after the wrapper's own template/boundary-notice text and the fixture's own tiny diff
are added -- this is a test of the input SHAPE the old bug choked on, not of the exact size
boundary (`input-too-large` already covers that, via an oversized diff, for the reasons documented
there).

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for the dispatch call (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat").

## How to run

```bash
bash codex-stream-review/evals/scenarios/near-limit-whitespace-performance/setup.sh
```

Prints `REPO_DIR`, `BIN_DIR`, and `FOCUS_REFERENCE_FILE` (the generated whitespace-dense text).
Invoke `codex-stream-review:ccs` against `REPO_DIR` with:

> review the uncommitted change in this fixture repo

using `FOCUS_REFERENCE_FILE`'s own content verbatim as this round's `FOCUS_FILE`, and
`--timeout 60` explicitly on the dispatch call. Record real wall-clock time around the dispatch.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> near-limit-whitespace-performance
```

`expect.sh` reads round 1's own `round_wall_seconds` from the sibling `.jsonl` review-history log
(the `.result.json` artifact itself carries no timing field) and asserts it is well under 30s.

## Expected result

- The dispatch completes normally well within the 60s `--timeout` -- no hang, no timeout failure.
- `exit_state`: `"CLEAN"`
- `round_count`: `1`
- Round 1's own `round_wall_seconds` (from the sibling `.jsonl` log): well under 30s -- the concrete
  regression-guard number
- `threads`: one entry, `kind:"current"`, `cleanup:"deleted"`
- `claims`: `[]`
- `input_errors`: `null`

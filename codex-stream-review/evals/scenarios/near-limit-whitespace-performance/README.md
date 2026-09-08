# Scenario: near-limit-whitespace-performance

**Group:** regression guard (not in the original ~28-scenario matrix). Added because building
`input-too-large` surfaced and led to fixing a real superlinear-hang bug in
`_focus_is_empty()` (`scripts/run-ccs-review.sh`/`scripts/run-stream-review.sh`) -- see this
directory's own `README.md`, "A real bug this harness already found (and fixed)".

**Targets:** a real terminal status reached quickly on a deliberately whitespace-dense
`--focus` text -- the exact input shape the old
`${var//[[:space:]]/}` bash substitution choked on (confirmed ~6KB took ~13s; a larger
whitespace-heavy focus file would have hung for hours). The fix (`tr -d
'[:space:]'`) is already merged -- this scenario is the regression guard confirming it stays fixed.
(The wrapper's own pre-dispatch prompt byte-size preflight that this fixture's size was originally
sized relative to has since been removed entirely; this scenario's target is independent of that
and unaffected by its removal.)

## The fixture

`setup.sh` generates a ~90000-byte focus reference text: a short real Why/Scope preamble, then
dense whitespace filler (long runs of spaces/tabs/newlines with sparse real words interspersed, so
it's never mistaken for empty/whitespace-only) -- this is a test of the input SHAPE the old bug
choked on, not of any byte-size boundary (there is no size preflight left to test a boundary of).

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

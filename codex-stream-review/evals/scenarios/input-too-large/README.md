# Scenario: input-too-large

**Group:** A (terminal-status matrix)
**Targets:** `exit_state == "INPUT_TOO_LARGE"`.

Confirms `run-ccs-review.sh`'s own deterministic preflight (`PROMPT_SIZE_LIMIT_BYTES`, 131072
bytes) rejects an oversized combined prompt (diff + focus/briefing text), and that the
orchestrator (Claude following `SKILL.md`) correctly reports `INPUT_TOO_LARGE` -- never retries
it, never leaks a thread, never treats it as `COULD_NOT_VERIFY`.

## Oversized DIFF, not oversized focus text -- a real bug discovered while building this scenario

The original design here inflated the FOCUS text (matching the plan's own "--focus/pasted task
text" phrasing). That was abandoned after live testing found a genuine, independent performance
bug in `scripts/run-ccs-review.sh`: `_focus_is_empty()` (around line 139) strips whitespace from
the ENTIRE focus text via a bash `${var//[[:space:]]/}` global substitution, which is
catastrophically superlinear for large inputs -- confirmed directly by isolated benchmark:
stripping a ~5.6KB string took ~11s, a ~22.5KB string took ~590s. A focus text anywhere near the
131072-byte limit this scenario needs to exceed would make the wrapper hang for a wildly
impractical time on this ONE early check, long before ever reaching the size-limit check this
scenario is actually trying to exercise (confirmed live: a 200000-byte focus text against a tiny
diff did not complete within a 3000-second bounded wait). **This is a real production bug,
independent of this eval harness, worth its own fix/report** -- flagged here, not patched, since
fixing `run-ccs-review.sh` itself is out of scope for `evals/`.

`setup.sh` instead builds a fixture repo with a large **tracked-file modification** (~150000
padding lines appended to `lib.py`, left uncommitted), so `git diff` itself renders an oversized
diff (`git diff` output size confirmed >300000 bytes) while the focus/briefing text stays short
and ordinary. `_focus_is_empty()` only ever touches the focus text, never the diff, so this path
reaches the same `PROMPT_SIZE_LIMIT_BYTES` check without the slow path.

## No fake-codex / PATH injection needed for this one

Every other scenario in this harness needs the fake-`codex` binary prepended onto `$PATH` for
every Bash call it makes (see `codex-stream-review/evals/README.md`'s "Mechanical caveat"
section). **This scenario is the one exception, confirmed by reading `scripts/run-ccs-review.sh`
directly, not assumed, and confirmed live (a real, unmodified `codex` CLI sat on `$PATH`
throughout this scenario's actual run and was never invoked):**

- The oversized-prompt check (`PROMPT_SIZE_BYTES -gt PROMPT_SIZE_LIMIT_BYTES`) runs at
  `scripts/run-ccs-review.sh` around line 830 -- strictly before the only two places that script
  ever calls `codex exec`/`codex exec resume` (lines 934 and 937). The check fires and the wrapper
  exits before either is ever reached.
- The only OTHER `codex` invocation anywhere in that script is `codex delete --force` inside
  `--cleanup` mode (line 325). But per `SKILL.md`'s own reason table, a fresh round-1
  `artifact_too_large` failure never obtains a `threadId` at all -- `GROUP_THREADS` stays empty,
  so Phase 3 never issues a `--cleanup` call for this scenario either.

So this scenario's dispatch and its terminal path never invoke the `codex` binary, real or fake,
at all. A real `codex` CLI sitting on `$PATH` unmodified is completely harmless here. (If a future
change to `run-ccs-review.sh` ever moves this check to fire after dispatch, this note -- and this
scenario's need for PATH injection -- would need to be revisited; `setup.sh`'s own header comment
carries the same warning.)

## How to run

```bash
bash codex-stream-review/evals/scenarios/input-too-large/setup.sh
```

Prints `REPO_DIR` (a throwaway fixture repo whose uncommitted diff to `lib.py` is deliberately
inflated, comfortably past 131072 bytes). Then invoke `codex-stream-review:ccs` against `REPO_DIR`
with the task text:

> review the uncommitted change in this fixture repo

Write this round's `FOCUS_FILE` (per `SKILL.md`'s Phase 1 Step 0) as an ORDINARY, short Why/Scope
focus text -- do NOT inflate the focus text itself (see the bug note above for why); the oversized
input here is `REPO_DIR`'s own diff, already comfortably past the limit on disk.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> input-too-large
```

## Expected result

- The round-1 dispatch call returns `{"ok":false,"reason":"artifact_too_large",...}` with no
  `threadId` (fresh round 1 -- `SKILL.md`'s reason table: "Fresh round 1: No"). Confirmed live:
  `{"ok":false,"reason":"artifact_too_large","detail":"the combined rendered prompt (diff plus
  focus/context text) is 333031 bytes, exceeding the 131072-byte limit -- ...","coverage":
  {"source":{"reviewed_file_count":1,"omitted":[],"status":"complete"}}}`.
- Per `references/retry-guards.md`: `artifact_too_large` is never retried, for any reason, ever.
  The round-level status is immediately `🛑 INPUT TOO LARGE`.
- `exit_state`: `"INPUT_TOO_LARGE"`
- `input_errors`: a non-empty array, one entry: `{"group":"main","actual_bytes":<the byte count
  from the failure response's own detail text>,"limit_bytes":131072}`
- `threads`: `[]` -- no thread was ever obtained for this group, so none can be `"leaked"` either
- `claims`: `[]`
- `coverage`: `null` is NOT correct here -- this is `target.scope:"uncommitted"`, so per the
  schema's own conditional, `coverage` must still be an object (whatever `SOURCE_COVERAGE_JSON`
  the wrapper's own `artifact_too_large` response happened to splice in, since collection
  genuinely completed before the size check ran -- see `SKILL.md`'s interface reference,
  "`artifact_too_large` is a further exception...")

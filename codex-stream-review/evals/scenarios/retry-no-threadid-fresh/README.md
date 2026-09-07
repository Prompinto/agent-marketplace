# Scenario: retry-no-threadid-fresh

**Group:** B (`retry-guards.md` retry-decision-tree coverage)
**Targets:** `references/retry-guards.md`'s "This group has NO entry in `GROUP_THREADS` yet" branch
-- a group's true first-ever dispatch attempt fails BEFORE a thread ever starts (no `threadId` in
the response at all). Confirms the wrapper/orchestrator retries the SAME scope flag fresh, exactly
once, rather than treating a single pre-thread-start failure as immediately unverifiable.

## Mechanism

`FAKE_CODEX_NO_THREAD_STARTED=1` (a separate boolean env var, **not** a `FAKE_CODEX_SCENARIO`
value -- confirmed by reading `tests/fixtures/fake-codex`'s own header comment and body) makes a
FRESH dispatch skip emitting `thread.started`, then sleep (`FAKE_CODEX_SLEEP_SECS`, default 11s)
past the wrapper's own hardcoded `THREAD_WAIT_SECS=10s` poll for that event -- so the wrapper kills
the process and reports `{"ok":false,"reason":"no_thread_started",...}` with no `threadId`
(confirmed directly from `scripts/run-ccs-review.sh`, the `if [ -z "$THREAD_ID" ]` block around
line 958).

Since the driving agent (a live Claude Code session following `SKILL.md`) issues each dispatch as
its own separate Bash call anyway, "first call fails this way, second call succeeds" is scripted
simply by setting `FAKE_CODEX_NO_THREAD_STARTED=1` on the FIRST call only, and omitting it (plain
`FAKE_CODEX_SCENARIO=normal`) on the second (retry) call -- no `FAKE_CODEX_GROUP_STATE` playback
mechanism is needed here, unlike a scenario that must script behavior across process invocations the
driving agent doesn't itself individually control.

## Mechanical setup

Needs the fake-`codex` binary on `$PATH` for every Bash call during this run (see
`codex-stream-review/evals/README.md`'s "Mechanical caveat"). `FAKE_CODEX_INVOCATION_LOG` must be
set to the fixed path `setup.sh` prints (`/tmp/ccs-eval-retry-no-threadid-fresh-invocation.log`) on
every dispatch/cleanup call -- `expect.sh` reads that same fixed path directly (it only receives the
`.result.json` path from `check-result.sh`, so a scenario-specific fixed log path is how it locates
the invocation record).

This invocation-count check is best-effort: if the invocation log has already been cleaned up by
the time `expect.sh` runs later (it is an ephemeral `/tmp` diagnostic file, not a durable artifact
like the `.jsonl` log or `.result.json`), that one check is skipped with a WARN instead of failing
the whole scenario -- the schema and field-based assertions remain the authoritative,
always-checkable ones.

## How to run

```bash
bash codex-stream-review/evals/scenarios/retry-no-threadid-fresh/setup.sh
```

Then invoke `codex-stream-review:ccs` against `REPO_DIR` with the task text:

> review the uncommitted change in this fixture repo

Sequence:

1. **Fresh round-1 dispatch** (`--uncommitted`), with `FAKE_CODEX_NO_THREAD_STARTED=1` and
   `FAKE_CODEX_SLEEP_SECS=11` -- fails `no_thread_started`, no `threadId`. Per `retry-guards.md`:
   this group has no entry in `GROUP_THREADS` yet (its true first-ever attempt) -- "nothing exists
   to resume -- retry the same scope flag fresh, exactly once." Also capture `coverage.source` from
   this failing response now (`no_thread_started` is one of the 7 reasons that unconditionally
   carries it on a fresh `--uncommitted` dispatch) -- this is this session's round-1 `coverage_source`
   determination, per "Coverage is a Round-1-only property."
2. **Fresh round-1 RETRY** (`--uncommitted` again -- never `--resume`, since no thread exists yet),
   this time plain `FAKE_CODEX_SCENARIO=normal` -- succeeds, real `threadId`, CLEAN verdict.
3. Round 1 converges `✅ CLEAN`.
4. Phase 3: `--cleanup` the one real thread, with `FAKE_CODEX_CLEANUP_OK=1`.

Locate the resulting `.result.json` and validate it:

```bash
bash codex-stream-review/evals/check-result.sh <result.json> retry-no-threadid-fresh
```

## Expected result

- `exit_state`: `"CLEAN"` (a real terminal status reached via the retry path -- never
  `COULD_NOT_VERIFY`, `INPUT_TOO_LARGE`, or an integrity-failure status, any of which would mean the
  retry never actually reached a real reviewed verdict)
- `threads`: exactly one entry, `kind:"current"`, `cleanup:"deleted"` -- no `"leaked"` entry, since
  the failing first attempt never obtained a `threadId` at all (`no_thread_started` never carries
  one, so there is nothing to abandon)
- The fixed invocation log (`/tmp/ccs-eval-retry-no-threadid-fresh-invocation.log`) shows exactly 2
  lines starting with `mode=fresh ` (the failing attempt, empty `thread_id`, and the succeeding
  retry) and zero `mode=resume ` lines -- the only reliable proof the retry path fired exactly
  twice for this group, not once by accident and not more than the documented single retry.

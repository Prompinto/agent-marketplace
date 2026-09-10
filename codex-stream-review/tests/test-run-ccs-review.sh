#!/usr/bin/env bash
# Regression fixtures for run-ccs-review.sh -- covers exactly the bug
# classes that have already shipped once in this plugin's own history
# (a bypassable --focus gate, a bad --resume contract) plus the
# git-environment/config isolation gap fixed alongside this suite, PLUS
# (see the "post-dispatch reason fixtures" section near the bottom) the 7
# `reason` values that can only occur AFTER a `codex exec` subprocess has
# actually started (no_thread_started, timeout, nonzero_exit,
# missing_task_complete, no_final_answer, invalid_json, schema_mismatch --
# NOT `interrupted`, which can fire at any point in the wrapper's own
# execution, including before a subprocess is ever launched).
# The first set of fixtures fails or short-circuits before the wrapper
# would ever dispatch to Codex; the post-dispatch set substitutes
# tests/fixtures/fake-codex for the real `codex` binary (via a PATH
# override) so the wrapper genuinely spawns and observes a subprocess
# without ever reaching a real Codex backend. This PATH override is
# installed here, at the very top of the file, before ANY fixture below
# runs -- including the pre-existing --cleanup fixtures further down,
# which call the wrapper's own `--cleanup` mode and therefore
# `codex delete --force` (scripts/run-ccs-review.sh:232) via a bare
# `codex` lookup. An earlier revision of this file left that PATH
# override installed only inside the post-dispatch section, so those
# --cleanup fixtures resolved whatever real `codex` binary happened to be
# on $PATH -- on a machine with an authenticated Codex CLI, that silently
# made a real network call every time this suite ran, contradicting this
# very comment's own "no API calls" claim. Installing the override this
# early, for the whole file, closes that gap: no line below can ever
# reach a real `codex` binary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../scripts/run-ccs-review.sh"
LIB_GIT_SAFE="$SCRIPT_DIR/../scripts/lib/git-safe.sh"
FAKE_CODEX="$SCRIPT_DIR/fixtures/fake-codex"
FAKE_BIN_DIR="$(mktemp -d)"
ln -s "$FAKE_CODEX" "$FAKE_BIN_DIR/codex" || { echo "SETUP FAILED: linking fake codex" >&2; exit 1; }
PATH="$FAKE_BIN_DIR:$PATH"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
must() { "$@" || { echo "SETUP FAILED: $*" >&2; exit 1; }; }

# --- wrapper contract regressions (arg parsing, no git/codex involved) ---

OUT="$(printf '' | "$WRAPPER" --cwd /tmp --uncommitted 2>&1)"
if printf '%s' "$OUT" | grep -q '"reason":"bad_args"' && printf '%s' "$OUT" | grep -q 'non-empty focus text'; then
  pass "empty focus (stdin) is rejected"
else
  fail "empty focus (stdin) should be rejected with bad_args, got: $OUT"
fi

# _focus_is_empty() strips ALL whitespace before judging emptiness -- a
# focus value that is only spaces/tabs/newlines must be rejected exactly
# like true EOF, never accepted as "there was something on stdin."
OUT="$(printf ' \t\n  \n' | "$WRAPPER" --cwd /tmp --uncommitted 2>&1)"
if printf '%s' "$OUT" | grep -q '"reason":"bad_args"' && printf '%s' "$OUT" | grep -q 'non-empty focus text'; then
  pass "whitespace-only focus (stdin) is rejected"
else
  fail "whitespace-only focus (stdin) should be rejected with bad_args, got: $OUT"
fi

OUT="$(printf '%s' 'x' | "$WRAPPER" --resume some-thread-id 2>&1)"
if printf '%s' "$OUT" | grep -q '"reason":"bad_args"'; then
  pass "--resume without --cwd is rejected"
else
  fail "--resume without --cwd should be rejected with bad_args, got: $OUT"
fi

OUT1="$("$WRAPPER" --cleanup definitely-not-a-real-thread-id 2>&1)"
OUT2="$("$WRAPPER" --cleanup definitely-not-a-real-thread-id 2>&1)"
if printf '%s' "$OUT1" | grep -q '"ok":false' && printf '%s' "$OUT2" | grep -q '"ok":false'; then
  pass "--cleanup on the same (nonexistent) threadId fails cleanly twice, no hang"
else
  fail "--cleanup idempotency check failed: [$OUT1] / [$OUT2]"
fi

# --- git isolation fixtures -- exercise git_safe() directly, no codex exec ---

TMP_REPO="$(mktemp -d)"
must git -C "$TMP_REPO" init -q
must git -C "$TMP_REPO" -c user.email=test@example.com -c user.name=test commit --allow-empty -q -m init
echo "content" > "$TMP_REPO/file.txt" || { echo "SETUP FAILED: writing file.txt (content)" >&2; exit 1; }
must git -C "$TMP_REPO" add file.txt
must git -C "$TMP_REPO" -c user.email=test@example.com -c user.name=test commit -q -m "add file"
echo "changed" > "$TMP_REPO/file.txt" || { echo "SETUP FAILED: writing file.txt (changed)" >&2; exit 1; }

DECOY_REPO="$(mktemp -d)"
must git -C "$DECOY_REPO" init -q

CWD="$TMP_REPO"
SAFE_GIT_HOME="$(mktemp -d)"
# shellcheck source=../scripts/lib/git-safe.sh
source "$LIB_GIT_SAFE"

# (a) hostile GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_* must not redirect git_safe
# to the decoy repo, or change how git interprets the target repo.
ACTUAL="$(GIT_DIR="$DECOY_REPO/.git" GIT_WORK_TREE="$DECOY_REPO" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
  git_safe rev-parse --show-toplevel 2>/dev/null)"
GIT_SAFE_STATUS=$?
ACTUAL_RESOLVED="$(cd "$ACTUAL" 2>/dev/null && pwd -P)"
EXPECTED_RESOLVED="$(cd "$TMP_REPO" && pwd -P)"
if [ "$GIT_SAFE_STATUS" -eq 0 ] && [ -n "$ACTUAL_RESOLVED" ] && [ "$ACTUAL_RESOLVED" = "$EXPECTED_RESOLVED" ]; then
  pass "git_safe ignores hostile GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_* and resolves the real target repo"
else
  fail "git_safe should resolve to $TMP_REPO regardless of hostile env, got: $ACTUAL (exit $GIT_SAFE_STATUS)"
fi

# (b) a hostile PATH set AFTER GIT_BIN was already resolved must not divert
# execution to a decoy `git` placed earlier on it.
DECOY_BIN_DIR="$(mktemp -d)"
MARKER_FILE="$(mktemp -u)"
cat > "$DECOY_BIN_DIR/git" <<EOF || { echo "SETUP FAILED: writing decoy git script" >&2; exit 1; }
#!/bin/sh
touch "$MARKER_FILE"
exit 1
EOF
must chmod +x "$DECOY_BIN_DIR/git"
PATH="$DECOY_BIN_DIR:$PATH" git_safe diff --no-ext-diff --no-textconv >/dev/null 2>&1
GIT_SAFE_STATUS=$?
if [ "$GIT_SAFE_STATUS" -eq 0 ] && [ ! -e "$MARKER_FILE" ]; then
  pass "git_safe ignores a hostile PATH decoy git executable"
else
  fail "git_safe executed a decoy git binary from a hostile PATH, or failed outright (exit $GIT_SAFE_STATUS)"
  rm -f "$MARKER_FILE"
fi
rm -rf "$DECOY_BIN_DIR"

# (c) a repo-local core.fsmonitor hook must never fire during a real diff --
# the one thing env-var sanitization alone cannot reach, since it lives in
# the target repo's own tracked .git/config.
FSMON_MARKER="$(mktemp -u)"
must git -C "$TMP_REPO" config core.fsmonitor "touch $FSMON_MARKER; true"
git_safe diff --no-ext-diff --no-textconv >/dev/null 2>&1
GIT_SAFE_STATUS=$?
if [ "$GIT_SAFE_STATUS" -eq 0 ] && [ ! -e "$FSMON_MARKER" ]; then
  pass "git_safe disables a repo-local core.fsmonitor hook"
else
  fail "git_safe let a repo-local core.fsmonitor hook execute, or failed outright (exit $GIT_SAFE_STATUS)"
  rm -f "$FSMON_MARKER"
fi
must git -C "$TMP_REPO" config --unset core.fsmonitor

# (d) collect_untracked_files.py's OWN git subprocess (the actual vulnerable
# path Issue 2 fixed) must also resist hostile core.fsmonitor config plus
# GIT_CONFIG_* env-var injection -- the 3 fixtures above only exercise
# git_safe() directly, never this separate subprocess the collector runs,
# invoked here the same way run-ccs-review.sh now invokes it post-fix.
COLLECT_PY="$SCRIPT_DIR/../scripts/collect_untracked_files.py"
COLLECT_FSMON_MARKER="$(mktemp -u)"
must git -C "$TMP_REPO" config core.fsmonitor "touch $COLLECT_FSMON_MARKER; true"
COLLECT_COVERAGE_OUT="$(mktemp)"
GIT_SAFE_BIN="$GIT_BIN" GIT_SAFE_HOME="$SAFE_GIT_HOME" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0="touch $COLLECT_FSMON_MARKER; true" \
  python3 "$COLLECT_PY" "$TMP_REPO" --deadline-secs 5 --max-bytes 65536 --coverage-out "$COLLECT_COVERAGE_OUT" \
  >/dev/null 2>&1
COLLECT_STATUS=$?
if [ "$COLLECT_STATUS" -eq 0 ] && [ ! -e "$COLLECT_FSMON_MARKER" ]; then
  pass "collect_untracked_files.py's own git subprocess ignores hostile core.fsmonitor + GIT_CONFIG_* injection"
else
  fail "collect_untracked_files.py should exit 0 without firing the fsmonitor hook (exit $COLLECT_STATUS, marker exists: $([ -e "$COLLECT_FSMON_MARKER" ] && echo yes || echo no))"
fi
must git -C "$TMP_REPO" config --unset core.fsmonitor
rm -f "$COLLECT_FSMON_MARKER" "$COLLECT_COVERAGE_OUT"

rm -rf "$TMP_REPO" "$DECOY_REPO" "$SAFE_GIT_HOME"

# --- post-dispatch reason fixtures (fake codex, no real API calls) ---
# tests/fixtures/fake-codex stands in for the real `codex` binary -- wired
# into $PATH once, for the whole file, at the top -- so run-ccs-review.sh
# genuinely spawns and observes a subprocess, exercising the 7 `reason`
# values that can only be produced after that subprocess has actually
# started. Only $FAKE_HOME (an isolated $HOME, so this suite never touches
# the real Codex CLI's own state) is specific to this section.

FAKE_HOME="$(mktemp -d)"

PD_REPO="$(mktemp -d)"
must git -C "$PD_REPO" init -q
must git -C "$PD_REPO" -c user.email=test@example.com -c user.name=test commit --allow-empty -q -m init
echo "line" > "$PD_REPO/f.txt" || { echo "SETUP FAILED: writing PD_REPO/f.txt" >&2; exit 1; }

# pd_new_tid -> a fresh unique id for a --resume fixture to pass as its
# threadId. Doesn't need to look like a real Codex thread id, or correspond
# to anything the wrapper or fake-codex actually look up (the wrapper no
# longer preflight-checks --resume against anything) -- just unique text.
pd_new_tid() {
  python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || echo "pd-$$-${RANDOM}"
}

# pd_run fresh [ARGS...]              -- fresh dispatch against $PD_REPO
# pd_run resume THREAD_ID [ARGS...]   -- resume dispatch against THREAD_ID
# Scenario env vars (FAKE_CODEX_SCENARIO/_EXIT_CODE/_SLEEP_SECS/
# _FINAL_ANSWER/_MARKER_FILE) are read from whatever the caller already
# exported -- each call site below sets them inline right before calling
# this, rather than threading them through as parameters.
pd_run() {
  local mode="$1"; shift
  if [ "$mode" = "resume" ]; then
    local tid="$1"; shift
    # --cwd is required on every invocation, even --resume (the wrapper's
    # own arg validation checks CWD unconditionally, and the dispatch
    # subshell always does `cd "$CWD"` before running codex).
    printf '%s' x | PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --resume "$tid" "$@" 2>&1
  else
    printf '%s' x | PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --uncommitted "$@" 2>&1
  fi
}

# pd_reason OUTPUT -> the wrapper's own JSON is always the LAST line of
# combined stdout+stderr (the wrapper's occasional "THREAD_ID=..." debug
# line, when present, is always printed to stderr before it).
pd_reason() { printf '%s' "$1" | tail -1 | jq -r '.reason // empty' 2>/dev/null; }
pd_threadid() { printf '%s' "$1" | tail -1 | jq -r '.threadId // empty' 2>/dev/null; }

pd_assert_reason() {
  local out="$1" expected="$2" label="$3" got
  got="$(pd_reason "$out")"
  if [ "$got" = "$expected" ]; then
    pass "$label: reason=$expected"
  else
    fail "$label: expected reason=$expected, got reason=$got (full: $out)"
  fi
}
pd_assert_threadid_present() {
  local out="$1" label="$2" got
  got="$(pd_threadid "$out")"
  if [ -n "$got" ]; then
    pass "$label: threadId present ($got)"
  else
    fail "$label: expected a threadId, got none (full: $out)"
  fi
}

PD_VALID_VERDICT='{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"not_applicable","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}'

# --- sanity: the fake codex itself, on a scenario meant to succeed,
# actually produces ok:true (fresh and resume) -- every case below relies
# on this fixture behaving correctly, so it gets its own direct check.
export FAKE_CODEX_SCENARIO=normal
OUT="$(pd_run fresh)"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "sanity: fresh normal-success dispatch returns ok:true"
else
  fail "sanity: fresh normal-success dispatch should return ok:true, got: $OUT"
fi

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "sanity: resume normal-success dispatch returns ok:true"
else
  fail "sanity: resume normal-success dispatch should return ok:true, got: $OUT"
fi
unset FAKE_CODEX_SCENARIO

# --- size-limit removal regression: the wrapper used to reject any round
# whose rendered prompt exceeded a self-imposed PROMPT_SIZE_LIMIT_BYTES
# (131072 bytes) with {"ok":false,"reason":"artifact_too_large",...},
# before ever launching codex exec. That preflight has been removed
# entirely -- a prompt this large must now reach a real dispatch instead.
# 200000 bytes of focus text alone (well over the old 131072-byte ceiling)
# piped directly, bypassing pd_run's hardcoded single-byte "x" focus.
export FAKE_CODEX_SCENARIO=normal
PD_OVERSIZED_FOCUS="$(python3 -c 'print("y" * 200000)')"
OUT="$(printf '%s' "$PD_OVERSIZED_FOCUS" | PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --uncommitted 2>&1)"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "size-limit removal: a >131072-byte focus text now reaches real dispatch (ok:true), never rejected as artifact_too_large"
else
  fail "size-limit removal: a >131072-byte focus text should reach real dispatch, got: $OUT"
fi
unset FAKE_CODEX_SCENARIO

# --- interrupted: the WRAPPER's own signal trap, not anything fake-codex
# does -- fake-codex just hangs (FAKE_CODEX_SCENARIO=hang) so there's a
# real window to send SIGTERM to the wrapper's own process into.
pd_test_interrupted() {
  # Only 3 call shapes are actually used below (fresh, resume, fresh +
  # capture-eventlog) -- handled as separate branches rather than an
  # optional-args array, since this project's bash 3.2 floor raises
  # "unbound variable" under `set -u` when expanding "${ARR[@]}" on an
  # array that was ever assigned empty (see run-ccs-review.sh's own note
  # on TRACKED_BINARY_PATHS for the identical constraint).
  # check_coverage (4th, optional): when non-empty, also asserts the
  # captured output's .coverage.source.status is a real value -- the
  # on_signal coverage regression check. Off by default so the 3 existing
  # call sites below keep their original, unchanged assertions.
  # check_execution (5th, optional): when non-empty, also asserts the
  # captured output's .execution.elapsed_seconds is a real non-negative
  # integer -- the execution-telemetry post-launch-interruption check (see
  # build_execution_json in scripts/run-ccs-review.sh: $DISPATCH_PID is set,
  # atomically alongside $CODEX_PID under signal-masking, immediately after
  # the background launch -- well before fake-codex's own marker-file touch
  # this function already waits on below, so it is always captured by the
  # time the SIGTERM below is sent).
  local mode="$1" tid="${2:-}" capture_path="${3:-}" check_coverage="${4:-}" check_execution="${5:-}"
  local label="$mode"
  local marker outfile wrapper_pid
  marker="$(mktemp -u)"
  outfile="$(mktemp)"
  export FAKE_CODEX_SCENARIO=hang FAKE_CODEX_SLEEP_SECS=30 FAKE_CODEX_MARKER_FILE="$marker"
  # Deliberately NOT routed through pd_run here: backgrounding a shell
  # FUNCTION call (`pd_run ... &`) forks an extra supervisor process for
  # the job, so $! captures THAT process, never the actual $WRAPPER
  # process running on_signal's trap -- a SIGTERM sent to $! would then
  # kill the supervisor while the real wrapper (reparented to init) keeps
  # running unsignaled. Invoking "$WRAPPER" directly as the backgrounded
  # command keeps $! pointing at the real process.
  # $! after backgrounding a pipeline is the PID of the pipeline's LAST
  # command (the wrapper itself here, per bash's documented behavior) --
  # piping focus text in via `printf | "$WRAPPER" ...` adds no extra
  # supervisor process of the kind the comment above warns about, so
  # wrapper_pid still points at the real $WRAPPER process.
  if [ "$mode" = "resume" ]; then
    printf '%s' x | PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --resume "$tid" \
      > "$outfile" 2>&1 &
  elif [ -n "$capture_path" ]; then
    printf '%s' x | PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --uncommitted \
      --capture-eventlog "$capture_path" > "$outfile" 2>&1 &
  else
    printf '%s' x | PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --uncommitted \
      > "$outfile" 2>&1 &
  fi
  wrapper_pid=$!
  # Wait for fake-codex to genuinely start (marker file) -- if it never
  # does, fail loudly instead of silently falling through to a SIGTERM
  # that would then race an already-broken dispatch and produce a
  # confusing, unrelated assertion failure below.
  local waited=0
  while [ ! -e "$marker" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  if [ ! -e "$marker" ]; then
    fail "interrupted ($label): fake-codex never started (marker not seen within 5s)"
    kill -TERM "$wrapper_pid" 2>/dev/null
    wait "$wrapper_pid" 2>/dev/null
    rm -f "$marker" "$outfile"
    unset FAKE_CODEX_SCENARIO FAKE_CODEX_SLEEP_SECS FAKE_CODEX_MARKER_FILE
    return
  fi
  # Then wait for the WRAPPER's own "THREAD_ID=..." line in $outfile
  # (scripts/run-ccs-review.sh echoes this to stderr, captured here,
  # immediately once it assigns $THREAD_ID -- for a fresh dispatch, only
  # after its own thread.started poll succeeds; for --resume, almost
  # immediately, since THREAD_ID is just the echoed --resume argument).
  # Polling this exact signal, rather than a fixed sleep after the
  # marker, is what actually closes the race: the marker fires as
  # fake-codex's very FIRST action, before it even emits thread.started,
  # so a fixed delay after it is a guess, not a guarantee, that the
  # wrapper has caught up.
  waited=0
  while ! grep -q '^THREAD_ID=' "$outfile" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  kill -TERM "$wrapper_pid" 2>/dev/null
  wait "$wrapper_pid" 2>/dev/null
  OUT="$(cat "$outfile")"
  pd_assert_reason "$OUT" "interrupted" "interrupted ($label)"
  pd_assert_threadid_present "$OUT" "interrupted ($label)"
  if [ -n "$check_coverage" ]; then
    local cov_status
    cov_status="$(printf '%s' "$OUT" | tail -1 | jq -r '.coverage.source.status // empty')"
    if [ "$cov_status" = "complete" ] || [ "$cov_status" = "partial" ]; then
      pass "interrupted ($label): coverage.source is spliced in on this signal path (status=$cov_status)"
    else
      fail "interrupted ($label): expected a real coverage.source.status, got: $OUT"
    fi
  fi
  if [ -n "$check_execution" ]; then
    local exec_elapsed
    exec_elapsed="$(printf '%s' "$OUT" | tail -1 | jq -r '.execution.elapsed_seconds // empty')"
    if printf '%s' "$exec_elapsed" | grep -qE '^[0-9]+$'; then
      pass "interrupted ($label): execution.elapsed_seconds is populated on this post-launch signal path ($exec_elapsed)"
    else
      fail "interrupted ($label): expected a real execution.elapsed_seconds, got: $OUT"
    fi
  fi
  rm -f "$marker" "$outfile"
  unset FAKE_CODEX_SCENARIO FAKE_CODEX_SLEEP_SECS FAKE_CODEX_MARKER_FILE
}
pd_test_interrupted fresh
TID="$(pd_new_tid)"
pd_test_interrupted resume "$TID"

# --- interrupted coverage regression: a fresh dispatch interrupted AFTER
# thread.started has already fired (proven by the wrapper's own
# "THREAD_ID=..." wait inside pd_test_interrupted, which only happens once
# diff collection -- and therefore $SOURCE_COVERAGE_JSON -- is already
# populated, since collection runs before `codex exec` is even launched)
# must still carry coverage.source. on_signal() used to build its JSON with
# a bare `printf` instead of routing through emit_final_output, silently
# dropping already-collected coverage data on every SIGINT/SIGTERM.
pd_test_interrupted fresh "" "" check_coverage

# on_signal() exits before ever reaching the --capture-eventlog copy step
# that the normal (non-signal) code path uses -- so a signal-interrupted
# round never populates the requested capture path. Worth locking in
# explicitly rather than leaving it an unverified assumption.
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
pd_test_interrupted fresh "" "$CAPTURE_PATH"
if [ ! -e "$CAPTURE_PATH" ]; then
  pass "interrupted: --capture-eventlog is NOT populated (on_signal skips the copy step)"
else
  fail "interrupted: expected no eventlog capture, but $CAPTURE_PATH was created"
fi
rm -rf "$CAPTURE_DIR"

# --- timeout: the wrapper's own --timeout deadline, not a fake-codex exit.
export FAKE_CODEX_SCENARIO=hang FAKE_CODEX_SLEEP_SECS=5
OUT="$(pd_run fresh --timeout 1)"
pd_assert_reason "$OUT" "timeout" "timeout (fresh)"
pd_assert_threadid_present "$OUT" "timeout (fresh)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID" --timeout 1)"
pd_assert_reason "$OUT" "timeout" "timeout (resume)"
pd_assert_threadid_present "$OUT" "timeout (resume)"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_SLEEP_SECS

# --- --receipt-slot: argument validation, then a real accepted dispatch.
OUT="$(pd_run fresh --receipt-slot 0)"
if printf '%s' "$OUT" | jq -e '.reason == "bad_args"' >/dev/null 2>&1; then
  pass "--receipt-slot 0 rejected as bad_args"
else
  fail "--receipt-slot 0 should be rejected, got: $OUT"
fi

OUT="$(pd_run fresh --receipt-slot abc)"
if printf '%s' "$OUT" | jq -e '.reason == "bad_args"' >/dev/null 2>&1; then
  pass "--receipt-slot abc (non-numeric) rejected as bad_args"
else
  fail "--receipt-slot abc should be rejected, got: $OUT"
fi

# An oversized value must be rejected as clean bad_args JSON with no stray
# stderr line (e.g. bash's own "integer expression expected") ahead of it --
# confirms the digit-length bound runs before any native arithmetic.
OUT="$(pd_run fresh --receipt-slot 9999)"
if printf '%s' "$OUT" | jq -e '.reason == "bad_args"' >/dev/null 2>&1; then
  pass "--receipt-slot 9999 (oversized) rejected as clean bad_args JSON, no stray stderr line ahead of it"
else
  fail "--receipt-slot 9999 should be rejected as clean bad_args JSON, got: $OUT"
fi

OUT="$(pd_run fresh --receipt-slot 01)"
if printf '%s' "$OUT" | jq -e '.reason == "bad_args"' >/dev/null 2>&1; then
  pass "--receipt-slot 01 (leading zero) rejected as bad_args"
else
  fail "--receipt-slot 01 should be rejected, got: $OUT"
fi

export FAKE_CODEX_SCENARIO=normal
OUT="$(pd_run fresh --receipt-slot 5)"
if printf '%s' "$OUT" | tail -1 | jq -e '.ok == true' >/dev/null 2>&1; then
  pass "--receipt-slot 5 (valid) accepted, dispatch succeeds"
else
  fail "--receipt-slot 5 should be accepted, got: $OUT"
fi
unset FAKE_CODEX_SCENARIO

# --- --receipt-schedule-file: content-shape validation, then a real accepted
# dispatch. build_review_prompt() cats this file's content straight into the
# prompt's trusted zone, so the parser must reject anything that isn't
# actually a generated schedule (missing file, or present but missing the
# literal REVIEW_RECEIPT_SCHEDULE header line) before it ever gets there.
OUT="$(pd_run fresh --receipt-schedule-file "/tmp/ccs-test-nonexistent-schedule-$$")"
if printf '%s' "$OUT" | jq -e '.reason == "bad_args"' >/dev/null 2>&1; then
  pass "--receipt-schedule-file nonexistent path rejected as bad_args"
else
  fail "--receipt-schedule-file nonexistent path should be rejected, got: $OUT"
fi

WRONG_SCHEDULE_FILE="$(mktemp)"
printf 'not a real schedule\n' > "$WRONG_SCHEDULE_FILE"
OUT="$(pd_run fresh --receipt-schedule-file "$WRONG_SCHEDULE_FILE")"
if printf '%s' "$OUT" | jq -e '.reason == "bad_args"' >/dev/null 2>&1; then
  pass "--receipt-schedule-file without the REVIEW_RECEIPT_SCHEDULE header rejected as bad_args"
else
  fail "--receipt-schedule-file without the header should be rejected, got: $OUT"
fi
rm -f "$WRONG_SCHEDULE_FILE"

VALID_SCHEDULE_FILE="$(mktemp)"
printf 'REVIEW_RECEIPT_SCHEDULE\n1: abc123\n' > "$VALID_SCHEDULE_FILE"
export FAKE_CODEX_SCENARIO=normal
OUT="$(pd_run fresh --receipt-schedule-file "$VALID_SCHEDULE_FILE")"
if printf '%s' "$OUT" | tail -1 | jq -e '.ok == true' >/dev/null 2>&1; then
  pass "--receipt-schedule-file with a valid header accepted, dispatch succeeds"
else
  fail "--receipt-schedule-file with a valid header should be accepted, got: $OUT"
fi
unset FAKE_CODEX_SCENARIO
rm -f "$VALID_SCHEDULE_FILE"

# --- no_thread_started: fresh dispatch only (--resume has no thread.started
# concept) -- fake-codex never emits thread.started, forcing the wrapper's
# own real (hardcoded) THREAD_WAIT_SECS=10s poll to genuinely time out. This
# is also a coverage regression check: diff collection (which populates
# $SOURCE_COVERAGE_JSON) happens BEFORE `codex exec` is ever launched, so by
# the time this branch fires, real coverage data is already available -- the
# fix (scripts/run-ccs-review.sh's no_thread_started branch) must route
# through emit_final_output rather than a bare printf for that data to
# survive into the response. Real wall-clock cost: this case takes slightly
# over 10s, same as the timeout fixture above.
export FAKE_CODEX_NO_THREAD_STARTED=1
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "no_thread_started" "no_thread_started (fresh)"
COV_STATUS="$(printf '%s' "$OUT" | tail -1 | jq -r '.coverage.source.status // empty')"
if [ "$COV_STATUS" = "complete" ] || [ "$COV_STATUS" = "partial" ]; then
  pass "no_thread_started (fresh): coverage.source is spliced in on this post-dispatch failure (status=$COV_STATUS)"
else
  fail "no_thread_started (fresh): expected a real coverage.source.status, got: $OUT"
fi
unset FAKE_CODEX_NO_THREAD_STARTED

# --- nonzero_exit: codex exec/exec resume itself exits nonzero.
for CODE in 1 3; do
  export FAKE_CODEX_SCENARIO=exit_nonzero FAKE_CODEX_EXIT_CODE="$CODE"
  OUT="$(pd_run fresh)"
  pd_assert_reason "$OUT" "nonzero_exit" "nonzero_exit (fresh, exit=$CODE)"
  pd_assert_threadid_present "$OUT" "nonzero_exit (fresh, exit=$CODE)"

  TID="$(pd_new_tid)"
  OUT="$(pd_run resume "$TID")"
  pd_assert_reason "$OUT" "nonzero_exit" "nonzero_exit (resume, exit=$CODE)"
  pd_assert_threadid_present "$OUT" "nonzero_exit (resume, exit=$CODE)"
done

# --capture-eventlog must contain fake-codex's own raw stdout for a
# non-signal failure path (unlike interrupted above).
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=exit_nonzero FAKE_CODEX_EXIT_CODE=1
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
pd_assert_reason "$OUT" "nonzero_exit" "nonzero_exit (fresh, --capture-eventlog)"
if [ -f "$CAPTURE_PATH" ] && grep -q '"type":"thread.started"' "$CAPTURE_PATH"; then
  pass "nonzero_exit: --capture-eventlog captured fake-codex's raw stdout"
else
  fail "nonzero_exit: --capture-eventlog should contain thread.started, file: $([ -f "$CAPTURE_PATH" ] && cat "$CAPTURE_PATH" || echo MISSING)"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_EXIT_CODE

# --- missing_task_complete: process exits 0, task_complete never appears.
export FAKE_CODEX_SCENARIO=no_task_complete
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "missing_task_complete" "missing_task_complete (fresh)"
pd_assert_threadid_present "$OUT" "missing_task_complete (fresh)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
pd_assert_reason "$OUT" "missing_task_complete" "missing_task_complete (resume)"
pd_assert_threadid_present "$OUT" "missing_task_complete (resume)"
unset FAKE_CODEX_SCENARIO

# --- no_final_answer: turn.completed appears, but -o never gets a final message.
export FAKE_CODEX_SCENARIO=no_final_answer
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "no_final_answer" "no_final_answer (fresh)"
pd_assert_threadid_present "$OUT" "no_final_answer (fresh)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
pd_assert_reason "$OUT" "no_final_answer" "no_final_answer (resume)"
pd_assert_threadid_present "$OUT" "no_final_answer (resume)"
unset FAKE_CODEX_SCENARIO

# --- invalid_json: final_answer text exists but isn't valid JSON at all.
PD_INVALID_JSON_VARIANTS=(
  "not json at all"
  "{not even close to json"
  "<<<garbled response>>>"
)
i=0
for VARIANT in "${PD_INVALID_JSON_VARIANTS[@]}"; do
  i=$((i + 1))
  export FAKE_CODEX_SCENARIO=invalid_json FAKE_CODEX_FINAL_ANSWER="$VARIANT"
  OUT="$(pd_run fresh)"
  pd_assert_reason "$OUT" "invalid_json" "invalid_json (fresh, variant $i)"
  pd_assert_threadid_present "$OUT" "invalid_json (fresh, variant $i)"

  TID="$(pd_new_tid)"
  OUT="$(pd_run resume "$TID")"
  pd_assert_reason "$OUT" "invalid_json" "invalid_json (resume, variant $i)"
  pd_assert_threadid_present "$OUT" "invalid_json (resume, variant $i)"
done

CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=invalid_json FAKE_CODEX_FINAL_ANSWER="${PD_INVALID_JSON_VARIANTS[0]}"
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
pd_assert_reason "$OUT" "invalid_json" "invalid_json (fresh, --capture-eventlog)"
if [ -f "$CAPTURE_PATH" ] && grep -q '"type":"thread.started"' "$CAPTURE_PATH"; then
  pass "invalid_json: --capture-eventlog captured fake-codex's raw stdout"
else
  fail "invalid_json: --capture-eventlog should contain thread.started, file: $([ -f "$CAPTURE_PATH" ] && cat "$CAPTURE_PATH" || echo MISSING)"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_FINAL_ANSWER

# --- schema_mismatch: valid JSON, but fails the wrapper's own semantic
# cross-field rules (search run-ccs-review.sh for where invalid_json and
# schema_mismatch are emitted -- each variant below violates exactly one
# rule from that jq check).
pd_variant() {
  # pd_variant NAME JQ_FILTER -> starts from PD_VALID_VERDICT and applies
  # one jq mutation, so each variant only names the ONE rule it breaks
  # instead of restating the whole JSON blob per case.
  printf '%s' "$PD_VALID_VERDICT" | jq -c "$1"
}

PD_SCHEMA_MISMATCH_NAMES=(
  "CLEAN-with-nonempty-findings"
  "ISSUES-with-empty-findings"
  "missing-dimension-key"
  "blank-dimension-evidence"
  "finding-blank-verification"
  "extra-top-level-key"
  "finding-line-zero"
  "invalid-severity-value"
  "invalid-verdict-value"
  "finding-missing-required-key"
)
PD_SCHEMA_MISMATCH_JSON=(
  "$(pd_variant '.findings += [{"file":"a.txt","line":1,"severity":"low","summary":"s","evidence":"e","verification":"v"}]')"
  "$(pd_variant '.verdict = "ISSUES"')"
  "$(pd_variant 'del(.dimensions.intent)')"
  "$(pd_variant '.dimensions.correctness.evidence = "   "')"
  "$(pd_variant '.verdict = "ISSUES" | .findings = [{"file":"a.txt","line":1,"severity":"low","summary":"s","evidence":"e","verification":"   "}]')"
  "$(pd_variant '. + {"extra_field": true}')"
  "$(pd_variant '.verdict = "ISSUES" | .findings = [{"file":"a.txt","line":0,"severity":"low","summary":"s","evidence":"e","verification":"v"}]')"
  "$(pd_variant '.verdict = "ISSUES" | .findings = [{"file":"a.txt","line":1,"severity":"critical","summary":"s","evidence":"e","verification":"v"}]')"
  # Also sets findings to a valid nonempty array: the wrapper's
  # CLEAN/ISSUES-vs-findings cross-field clause branches on `.verdict ==
  # "CLEAN"`, so changing verdict alone to a non-CLEAN, non-ISSUES value
  # would ALSO flip that clause to its non-CLEAN branch (needs
  # findings.length > 0) while findings is still the empty baseline --
  # failing two independent clauses at once instead of isolating the
  # allowed-verdict-values check this variant is named for.
  "$(pd_variant '.verdict = "PASS" | .findings = [{"file":"a.txt","line":1,"severity":"low","summary":"s","evidence":"e","verification":"v"}]')"
  "$(pd_variant '.verdict = "ISSUES" | .findings = [{"line":1,"severity":"low","summary":"s","evidence":"e","verification":"v"}]')"
)
for i in "${!PD_SCHEMA_MISMATCH_NAMES[@]}"; do
  NAME="${PD_SCHEMA_MISMATCH_NAMES[$i]}"
  JSON="${PD_SCHEMA_MISMATCH_JSON[$i]}"
  export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="$JSON"
  OUT="$(pd_run fresh)"
  pd_assert_reason "$OUT" "schema_mismatch" "schema_mismatch (fresh, $NAME)"
  pd_assert_threadid_present "$OUT" "schema_mismatch (fresh, $NAME)"
done

# A couple of the same variants, also exercised over --resume.
for NAME_IDX in 0 1; do
  NAME="${PD_SCHEMA_MISMATCH_NAMES[$NAME_IDX]}"
  JSON="${PD_SCHEMA_MISMATCH_JSON[$NAME_IDX]}"
  TID="$(pd_new_tid)"
  export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="$JSON"
  OUT="$(pd_run resume "$TID")"
  pd_assert_reason "$OUT" "schema_mismatch" "schema_mismatch (resume, $NAME)"
  pd_assert_threadid_present "$OUT" "schema_mismatch (resume, $NAME)"
done

CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="${PD_SCHEMA_MISMATCH_JSON[0]}"
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
pd_assert_reason "$OUT" "schema_mismatch" "schema_mismatch (fresh, --capture-eventlog)"
if [ -f "$CAPTURE_PATH" ] && grep -q '"type":"thread.started"' "$CAPTURE_PATH"; then
  pass "schema_mismatch: --capture-eventlog captured fake-codex's raw stdout"
else
  fail "schema_mismatch: --capture-eventlog should contain thread.started, file: $([ -f "$CAPTURE_PATH" ] && cat "$CAPTURE_PATH" || echo MISSING)"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_FINAL_ANSWER

# --- coverage regression: a post-dispatch failure on a fresh --uncommitted
# round must still carry coverage.source, exactly like an ok:true round on
# the identical scope. emit_final_output's own header comment claims it is
# "shared by both the empty-diff fast path and the normal result path so
# both always get a coverage object" -- but the dispatch epilogue used to
# call emit_final_output only when RESULT was 0, falling through to a bare
# `printf` for every one of the 7 post-dispatch failure reasons instead,
# silently dropping already-collected coverage data on all of them. Picking
# schema_mismatch here (not nonzero_exit/etc.) is arbitrary -- the fix lives
# in the shared epilogue after JUDGE_OUTPUT is set, not in any
# reason-specific branch, so one representative post-dispatch failure
# reason is sufficient to catch a regression in that shared code path.
export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="${PD_SCHEMA_MISMATCH_JSON[0]}"
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "schema_mismatch" "schema_mismatch coverage regression: reason"
COV_STATUS="$(printf '%s' "$OUT" | tail -1 | jq -r '.coverage.source.status // empty')"
if [ "$COV_STATUS" = "complete" ] || [ "$COV_STATUS" = "partial" ]; then
  pass "schema_mismatch (fresh, --uncommitted): coverage.source is still spliced in on a post-dispatch failure (status=$COV_STATUS)"
else
  fail "schema_mismatch (fresh, --uncommitted): expected a real coverage.source.status, got: $OUT"
fi
unset FAKE_CODEX_SCENARIO FAKE_CODEX_FINAL_ANSWER

# --- schema_mismatch: material_reviewed / material_receipt cross-field
# checks (Task 5 of the material-verification plan) -- material_reviewed:
# false must be rejected regardless of verdict (the exact gap an earlier
# design draft left open by only checking the CLEAN combination), and
# material_receipt/material_receipt_index must be both null or both
# non-null, never one of each.
MV_BASE='{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"not_applicable","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}}}'

BAD_ANSWER="$(printf '%s' "$MV_BASE" | jq -c '. + {material_reviewed:false, material_receipt:null, material_receipt_index:null}')"
export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="$BAD_ANSWER"
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "schema_mismatch" "material_reviewed:false + CLEAN rejected"

BAD_ANSWER2="$(printf '%s' "$MV_BASE" | jq -c '.verdict = "ISSUES" | .findings = [{"file":"x.py","line":1,"severity":"low","summary":"s","evidence":"e","verification":"v"}] | . + {material_reviewed:false, material_receipt:null, material_receipt_index:null}')"
export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="$BAD_ANSWER2"
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "schema_mismatch" "material_reviewed:false + ISSUES/nonempty-findings ALSO rejected"

BAD_ANSWER3="$(printf '%s' "$MV_BASE" | jq -c '. + {material_reviewed:true, material_receipt:"abc123", material_receipt_index:null}')"
export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="$BAD_ANSWER3"
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "schema_mismatch" "one-null-one-populated receipt pair rejected"

GOOD_ANSWER="$(printf '%s' "$MV_BASE" | jq -c '. + {material_reviewed:true, material_receipt:null, material_receipt_index:null}')"
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_FINAL_ANSWER="$GOOD_ANSWER"
OUT="$(pd_run fresh)"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "material_reviewed:true + null-null receipt pair accepted"
else
  fail "material_reviewed:true + null-null pair should be accepted, got: $OUT"
fi
unset FAKE_CODEX_SCENARIO FAKE_CODEX_FINAL_ANSWER

# --- investigation_evidence extraction fixtures (capture-evidence, no real API calls) ---
# Exercises the two jq filters documented in skills/ccs/SKILL.md's
# "Investigation evidence capture" section, copied VERBATIM from that file
# below (never paraphrased/simplified) -- step 2's per-(round,group)
# extraction filter and step 3's parallel-mode merge filter. fake-codex's
# FAKE_CODEX_COMMANDS/FAKE_CODEX_GARBAGE_LINE env vars (see
# tests/fixtures/fake-codex) make its own stdout -- which --capture-eventlog
# copies verbatim, per the nonzero_exit/invalid_json/schema_mismatch
# fixtures above -- contain real item.completed/command_execution events (or
# a deliberately unparseable line) without ever touching a real Codex
# backend.

# ccs_extract_evidence EVENTLOG_FILE -> sets (global) INVESTIGATION_EVIDENCE_JSON.
# Verbatim body of SKILL.md step 2's extraction snippet, including its own
# [ -s ... ] guard -- only the surrounding function wrapper and the
# parameter name are test scaffolding.
ccs_extract_evidence() {
  local EVENTLOG_FILE="$1"
  if [ -s "$EVENTLOG_FILE" ]; then
    INVESTIGATION_EVIDENCE_JSON=$(jq -Rn -c '
      [inputs | fromjson? | select(.type == "item.completed" and .item.type == "command_execution") | .item.command]
      | {command_count: length, commands: .}
    ' "$EVENTLOG_FILE")
  else
    INVESTIGATION_EVIDENCE_JSON='{"command_count":0,"commands":[]}'
  fi
}

# 1. Basic extraction, nonzero commands (fresh dispatch). One command
# embeds a double quote, a "$", and a space together, to prove the
# extraction is JSON-safe rather than string-concatenation-safe.
IE_CMD1='grep -rn "foo $HOME" src/dir'
IE_CMD2='cat package.json'
IE_CMD3='npm test -- --watch=false'
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_COMMANDS="$IE_CMD1
$IE_CMD2
$IE_CMD3"
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "investigation_evidence: fresh dispatch with 3 commands returns ok:true"
else
  fail "investigation_evidence: fresh dispatch with 3 commands should return ok:true, got: $OUT"
fi
ccs_extract_evidence "$CAPTURE_PATH"
IE_EXPECTED_COMMANDS="$(jq -nc --arg c1 "$IE_CMD1" --arg c2 "$IE_CMD2" --arg c3 "$IE_CMD3" '[$c1,$c2,$c3]')"
IE_ACTUAL_COUNT="$(printf '%s' "$INVESTIGATION_EVIDENCE_JSON" | jq -r '.command_count')"
IE_ACTUAL_COMMANDS="$(printf '%s' "$INVESTIGATION_EVIDENCE_JSON" | jq -c '.commands')"
if [ "$IE_ACTUAL_COUNT" = "3" ] && [ "$IE_ACTUAL_COMMANDS" = "$IE_EXPECTED_COMMANDS" ]; then
  pass "investigation_evidence: extraction filter yields command_count=3 and the exact commands, special characters intact"
else
  fail "investigation_evidence: expected command_count=3 commands=$IE_EXPECTED_COMMANDS, got: $INVESTIGATION_EVIDENCE_JSON"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_COMMANDS

# 2. Zero commands, but a genuinely non-empty/successful round (ok:true) --
# the extraction filter must report a real, honest zero here, distinct from
# the (separately-decided, not tested here) skip-extraction-entirely case.
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=normal
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "investigation_evidence: fresh dispatch with zero commands returns ok:true"
else
  fail "investigation_evidence: fresh dispatch with zero commands should return ok:true, got: $OUT"
fi
ccs_extract_evidence "$CAPTURE_PATH"
if [ "$INVESTIGATION_EVIDENCE_JSON" = '{"command_count":0,"commands":[]}' ]; then
  pass "investigation_evidence: a genuinely-ran zero-command round extracts a real, honest zero"
else
  fail "investigation_evidence: expected {\"command_count\":0,\"commands\":[]}, got: $INVESTIGATION_EVIDENCE_JSON"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO

# 3. Malformed/garbage line tolerance: fromjson? must silently skip an
# unparseable line -- not count it, not error the whole jq invocation --
# while still extracting the real commands around it.
IE_CMD_A='echo hello'
IE_CMD_B='ls -la /tmp'
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_GARBAGE_LINE=1 FAKE_CODEX_COMMANDS="$IE_CMD_A
$IE_CMD_B"
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "investigation_evidence: fresh dispatch with garbage line + 2 commands returns ok:true"
else
  fail "investigation_evidence: fresh dispatch with garbage line + 2 commands should return ok:true, got: $OUT"
fi
if [ -f "$CAPTURE_PATH" ] && grep -qxF "not valid json at all" "$CAPTURE_PATH"; then
  pass "investigation_evidence: eventlog genuinely contains the injected garbage line"
else
  fail "investigation_evidence: expected the injected garbage line in the eventlog, file: $([ -f "$CAPTURE_PATH" ] && cat "$CAPTURE_PATH" || echo MISSING)"
fi
IE_MALFORMED_JSON=$(jq -Rn -c '
  [inputs | fromjson? | select(.type == "item.completed" and .item.type == "command_execution") | .item.command]
  | {command_count: length, commands: .}
' "$CAPTURE_PATH")
IE_JQ_STATUS=$?
IE_EXPECTED="$(jq -nc --arg a "$IE_CMD_A" --arg b "$IE_CMD_B" '{command_count:2, commands:[$a,$b]}')"
if [ "$IE_JQ_STATUS" -eq 0 ] && [ "$IE_MALFORMED_JSON" = "$IE_EXPECTED" ]; then
  pass "investigation_evidence: fromjson? swallows the garbage line (jq exit 0), extracts exactly the 2 real commands"
else
  fail "investigation_evidence: expected jq exit 0 and $IE_EXPECTED, got exit=$IE_JQ_STATUS value=$IE_MALFORMED_JSON"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_GARBAGE_LINE FAKE_CODEX_COMMANDS

# 4. Parallel-mode merge filter -- SKILL.md step 3, verbatim, including its
# own heredoc-style two-line input. No wrapper dispatch needed: this filter
# operates purely on two already-produced INVESTIGATION_EVIDENCE_JSON-shaped
# objects.
IE_GROUP1_JSON='{"command_count":2,"commands":["a","b"]}'
IE_GROUP2_JSON='{"command_count":1,"commands":["c"]}'
MERGED_INVESTIGATION_EVIDENCE_JSON=$(jq -sc '{command_count: (map(.command_count) | add), commands: (map(.commands) | add)}' <<< "$IE_GROUP1_JSON
$IE_GROUP2_JSON")
IE_EXPECTED_MERGE='{"command_count":3,"commands":["a","b","c"]}'
if [ "$MERGED_INVESTIGATION_EVIDENCE_JSON" = "$IE_EXPECTED_MERGE" ]; then
  pass "investigation_evidence: parallel-mode merge filter sums command_count and concatenates commands in order"
else
  fail "investigation_evidence: expected $IE_EXPECTED_MERGE, got: $MERGED_INVESTIGATION_EVIDENCE_JSON"
fi

# 5. Resume-dispatch extraction: same nonzero-commands case as #1, but via
# --resume, confirming the extraction filter itself has no fresh/resume
# distinction (that distinction lives entirely in the separate
# should-extraction-run decision, not in this filter's logic).
IE_CMD1R='grep -rn "foo $HOME" src/dir'
IE_CMD2R='cat package.json'
IE_CMD3R='npm test -- --watch=false'
TID="$(pd_new_tid)"
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_COMMANDS="$IE_CMD1R
$IE_CMD2R
$IE_CMD3R"
OUT="$(pd_run resume "$TID" --capture-eventlog "$CAPTURE_PATH")"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "investigation_evidence: resume dispatch with 3 commands returns ok:true"
else
  fail "investigation_evidence: resume dispatch with 3 commands should return ok:true, got: $OUT"
fi
ccs_extract_evidence "$CAPTURE_PATH"
IE_EXPECTED_COMMANDS="$(jq -nc --arg c1 "$IE_CMD1R" --arg c2 "$IE_CMD2R" --arg c3 "$IE_CMD3R" '[$c1,$c2,$c3]')"
IE_ACTUAL_COUNT="$(printf '%s' "$INVESTIGATION_EVIDENCE_JSON" | jq -r '.command_count')"
IE_ACTUAL_COMMANDS="$(printf '%s' "$INVESTIGATION_EVIDENCE_JSON" | jq -c '.commands')"
if [ "$IE_ACTUAL_COUNT" = "3" ] && [ "$IE_ACTUAL_COMMANDS" = "$IE_EXPECTED_COMMANDS" ]; then
  pass "investigation_evidence: resume-dispatch extraction works identically to fresh (command_count=3, commands intact)"
else
  fail "investigation_evidence: expected command_count=3 commands=$IE_EXPECTED_COMMANDS, got: $INVESTIGATION_EVIDENCE_JSON"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_COMMANDS

# --- execution telemetry fixtures (Phase 3, always on -- no opt-in) ---
# Exercises build_execution_json's own extraction in scripts/run-ccs-review.sh:
# elapsed_seconds is present whenever $DISPATCH_PID was ever actually captured
# for this dispatch; usage is present only when a genuinely
# non-empty usage object was extracted from the LAST "type":"turn.completed"
# event, collapsing "no such event" and "an emitted-but-empty {} usage" to
# the identical absent-usage outcome. fake-codex's own FAKE_CODEX_USAGE_JSON
# controls what that event reports (see tests/fixtures/fake-codex).

pd_assert_execution_elapsed_present() {
  local out="$1" label="$2" val
  val="$(printf '%s' "$out" | tail -1 | jq -r '.execution.elapsed_seconds // empty')"
  if printf '%s' "$val" | grep -qE '^[0-9]+$'; then
    pass "$label: execution.elapsed_seconds present ($val)"
  else
    fail "$label: expected execution.elapsed_seconds to be a non-negative integer, got: $out"
  fi
}
pd_assert_usage_absent() {
  local out="$1" label="$2"
  if printf '%s' "$out" | tail -1 | jq -e '(.execution | has("usage")) | not' >/dev/null 2>&1; then
    pass "$label: execution.usage is absent (usage unavailable)"
  else
    fail "$label: expected no execution.usage key at all, got: $out"
  fi
}
pd_assert_usage_equals() {
  local out="$1" expected="$2" label="$3" got
  got="$(printf '%s' "$out" | tail -1 | jq -c '.execution.usage // empty')"
  if [ "$got" = "$expected" ]; then
    pass "$label: execution.usage matches expected value"
  else
    fail "$label: expected execution.usage=$expected, got: $got (full: $out)"
  fi
}

# 1. Populated usage -- a real, non-empty usage object is kept and reported
# as-is, even with individual zero-valued counters.
PD_USAGE_POPULATED='{"input_tokens":128,"cached_input_tokens":0,"output_tokens":42,"reasoning_output_tokens":10}'
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_USAGE_JSON="$PD_USAGE_POPULATED"
OUT="$(pd_run fresh)"
pd_assert_execution_elapsed_present "$OUT" "execution (fresh, populated usage)"
pd_assert_usage_equals "$OUT" "$PD_USAGE_POPULATED" "execution (fresh, populated usage)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
pd_assert_execution_elapsed_present "$OUT" "execution (resume, populated usage)"
pd_assert_usage_equals "$OUT" "$PD_USAGE_POPULATED" "execution (resume, populated usage)"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_USAGE_JSON

# 2. Empty {} usage -- the real CLI does emit this on some successful
# turns; it must collapse to the same "usage unavailable" outcome as a
# genuinely absent usage, never surfaced as an empty-object placeholder.
# fake-codex's own default (FAKE_CODEX_USAGE_JSON unset) is already {}.
export FAKE_CODEX_SCENARIO=normal
OUT="$(pd_run fresh)"
pd_assert_execution_elapsed_present "$OUT" "execution (fresh, empty usage)"
pd_assert_usage_absent "$OUT" "execution (fresh, empty usage)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
pd_assert_execution_elapsed_present "$OUT" "execution (resume, empty usage)"
pd_assert_usage_absent "$OUT" "execution (resume, empty usage)"
unset FAKE_CODEX_SCENARIO

# 3. Absent usage -- the turn.completed event carries no "usage" key at all
# (FAKE_CODEX_USAGE_JSON=null tells fake-codex to omit it entirely -- see
# fake-codex's own header comment for why this sentinel means "omit the
# key", distinct from case 3b below).
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_USAGE_JSON=null
OUT="$(pd_run fresh)"
pd_assert_execution_elapsed_present "$OUT" "execution (fresh, absent usage)"
pd_assert_usage_absent "$OUT" "execution (fresh, absent usage)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
pd_assert_execution_elapsed_present "$OUT" "execution (resume, absent usage)"
pd_assert_usage_absent "$OUT" "execution (resume, absent usage)"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_USAGE_JSON

# 3b. Explicit JSON null usage -- the turn.completed event carries
# "usage":null literally (FAKE_CODEX_USAGE_JSON=JSON_NULL), distinct from
# case 3's genuinely absent key. The production jq extraction must treat
# both identically ("usage unavailable"), but that must be PROVEN by a
# fixture that actually emits a literal null, not assumed from the
# absent-key case alone.
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_USAGE_JSON=JSON_NULL
OUT="$(pd_run fresh)"
pd_assert_execution_elapsed_present "$OUT" "execution (fresh, explicit JSON null usage)"
pd_assert_usage_absent "$OUT" "execution (fresh, explicit JSON null usage)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
pd_assert_execution_elapsed_present "$OUT" "execution (resume, explicit JSON null usage)"
pd_assert_usage_absent "$OUT" "execution (resume, explicit JSON null usage)"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_USAGE_JSON

# 4. A non-JSON line mixed into the event stream (the same
# FAKE_CODEX_GARBAGE_LINE the investigation_evidence fixtures above use)
# must not break usage extraction -- build_execution_json's own fromjson?
# tolerates it exactly like the investigation_evidence filter does.
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_GARBAGE_LINE=1 FAKE_CODEX_USAGE_JSON="$PD_USAGE_POPULATED"
OUT="$(pd_run fresh)"
pd_assert_execution_elapsed_present "$OUT" "execution (fresh, garbage line mixed in)"
pd_assert_usage_equals "$OUT" "$PD_USAGE_POPULATED" "execution (fresh, garbage line mixed in)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
pd_assert_execution_elapsed_present "$OUT" "execution (resume, garbage line mixed in)"
pd_assert_usage_equals "$OUT" "$PD_USAGE_POPULATED" "execution (resume, garbage line mixed in)"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_GARBAGE_LINE FAKE_CODEX_USAGE_JSON

# 5. no_thread_started -- fresh-dispatch-only, structurally unreachable on
# --resume (a --resume call already has a threadId and never enters the
# thread.started polling branch at all -- see SKILL.md's own reason table
# note; no resume variant is added here for exactly that reason). A
# dispatch genuinely started (fake-codex is running, it just never emits
# thread.started before the wrapper's own 10s poll gives up), so
# $DISPATCH_PID was captured -- elapsed_seconds must still be present even
# though no turn.completed event (and therefore no usage) was ever
# produced.
export FAKE_CODEX_NO_THREAD_STARTED=1
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "no_thread_started" "execution (fresh, no_thread_started)"
pd_assert_execution_elapsed_present "$OUT" "execution (fresh, no_thread_started)"
pd_assert_usage_absent "$OUT" "execution (fresh, no_thread_started)"
unset FAKE_CODEX_NO_THREAD_STARTED

# 6. Post-launch interruption -- a SIGTERM/SIGINT sent to the wrapper AFTER
# the child process has genuinely started must still populate
# execution.elapsed_seconds in the resulting `interrupted` response.
pd_test_interrupted fresh "" "" "" check_execution
TID="$(pd_new_tid)"
pd_test_interrupted resume "$TID" "" "" check_execution

# --- claim-ledger reducer fixtures (claim-ledger.md section 8, no real API calls) ---
# Exercises tests/fixtures/claim-ledger-reducer.jq, the jq filter implementing
# the deterministic claim-state reducer described in claim-ledger.md section
# 8: reconstructing each distinct claim_id's current status/evidence_delta
# from the append-only JSONL review-history log alone. Pure jq over
# hand-built JSONL fixtures -- no wrapper dispatch, no fake-codex involved.

CLAIM_LEDGER_JQ="$SCRIPT_DIR/fixtures/claim-ledger-reducer.jq"

cl_reduce() {
  # $1 = jsonl file; prints one compact JSON object per distinct claim_id
  jq -n -c -f "$CLAIM_LEDGER_JQ" "$1"
}
cl_status_for() {
  # $1 = reducer output (one obj per line), $2 = claim_id
  printf '%s' "$1" | jq -c --arg id "$2" 'select(.claim_id == $id)'
}

# 1. Cleanly-closed claim: raised round 1, closed "resolved" in round 2.
CL_FIXTURE_1="$(mktemp)"
cat > "$CL_FIXTURE_1" <<'EOF'
{"round":1,"claude_verification":[{"finding_id":"f1","claim_id":"f1","action":"accept","rationale":"looks right"}]}
{"round":2,"claude_verification":[],"claim_closures":[{"claim_id":"f1","disposition":"resolved","source_round":2,"marker_reason":"fix confirmed by re-read"}]}
EOF
CL_OUT="$(cl_reduce "$CL_FIXTURE_1")"
CL_ENTRY="$(cl_status_for "$CL_OUT" f1)"
if [ "$(printf '%s' "$CL_ENTRY" | jq -r '.status')" = "resolved" ]; then
  pass "claim-ledger reducer: a claim closed with disposition:resolved reports status=resolved"
else
  fail "claim-ledger reducer: expected status=resolved for f1, got: $CL_OUT"
fi
rm -f "$CL_FIXTURE_1"

# 2. Still-open claim: raised, never closed.
CL_FIXTURE_2="$(mktemp)"
cat > "$CL_FIXTURE_2" <<'EOF'
{"round":1,"claude_verification":[{"finding_id":"f2","claim_id":"f2","action":"accept","rationale":"valid, fix pending"}]}
EOF
CL_OUT="$(cl_reduce "$CL_FIXTURE_2")"
CL_ENTRY="$(cl_status_for "$CL_OUT" f2)"
if [ "$(printf '%s' "$CL_ENTRY" | jq -r '.status')" = "open" ]; then
  pass "claim-ledger reducer: a claim with no claim_closures entry reports status=open"
else
  fail "claim-ledger reducer: expected status=open for f2, got: $CL_OUT"
fi
rm -f "$CL_FIXTURE_2"

# 3. Non-consecutive oscillation: raised round 1 (first occurrence, no
# evidence_delta), silent round 2 (no entry at all that round), reasserted
# round 3 with evidence_delta:"none" -- exactly the gap the old "last two
# rounds" comparison used to miss (claim-ledger.md section 7). The reducer's
# own job is only to surface the latest evidence_delta correctly; the
# oscillation-guard DECISION built on top of it is Claude's job per
# SKILL.md, not tested here.
CL_FIXTURE_3="$(mktemp)"
cat > "$CL_FIXTURE_3" <<'EOF'
{"round":1,"claude_verification":[{"finding_id":"f3","claim_id":"f3","action":"reject_with_rationale","rationale":"disagree"}]}
{"round":2,"claude_verification":[]}
{"round":3,"claude_verification":[{"finding_id":"f3","claim_id":"f3","action":"reject_with_rationale","rationale":"still disagree","evidence_delta":"none"}]}
EOF
CL_OUT="$(cl_reduce "$CL_FIXTURE_3")"
CL_ENTRY="$(cl_status_for "$CL_OUT" f3)"
if [ "$(printf '%s' "$CL_ENTRY" | jq -r '.status')" = "open" ] && [ "$(printf '%s' "$CL_ENTRY" | jq -r '.evidence_delta')" = "none" ]; then
  pass "claim-ledger reducer: non-consecutive reassertion surfaces the LATEST evidence_delta (none) across a silent round"
else
  fail "claim-ledger reducer: expected status=open evidence_delta=none for f3, got: $CL_OUT"
fi
rm -f "$CL_FIXTURE_3"

# 4. Reasserted with genuinely new evidence -- must surface "new", not stale.
CL_FIXTURE_4="$(mktemp)"
cat > "$CL_FIXTURE_4" <<'EOF'
{"round":1,"claude_verification":[{"finding_id":"f4","claim_id":"f4","action":"reject_with_rationale","rationale":"disagree"}]}
{"round":2,"claude_verification":[]}
{"round":3,"claude_verification":[{"finding_id":"f4","claim_id":"f4","action":"reject_with_rationale","rationale":"new argument presented","evidence_delta":"new"}]}
EOF
CL_OUT="$(cl_reduce "$CL_FIXTURE_4")"
CL_ENTRY="$(cl_status_for "$CL_OUT" f4)"
if [ "$(printf '%s' "$CL_ENTRY" | jq -r '.evidence_delta')" = "new" ]; then
  pass "claim-ledger reducer: reassertion with evidence_delta:new surfaces new, not stale"
else
  fail "claim-ledger reducer: expected evidence_delta=new for f4, got: $CL_OUT"
fi
rm -f "$CL_FIXTURE_4"

# --- quick-mode canonical-severity/MINOR_ISSUES_ACKNOWLEDGED decision fixtures ---
# (SKILL.md's Guards section, "Quick-mode early stop -- MINOR ISSUES ACKNOWLEDGED")
# Exercises tests/fixtures/quick-mode-decision.jq, the jq filter implementing the
# canonical-current-severity lookup (most-recent occurrence, not origin) plus the
# MINOR_ISSUES_ACKNOWLEDGED eligibility decision. Pure jq over hand-built JSONL fixtures -- no
# wrapper dispatch, no fake-codex involved. This is also the ONLY coverage for two severity
# values (`critical`, and an unparseable string) that CANNOT be driven through a live dispatch at
# all: `scripts/run-ccs-review.sh`'s own semantic-verdict check rejects any severity outside
# low/medium/high/null as schema_mismatch before a finding ever reaches Phase 2 -- see
# evals/scenarios/quick-mode-escalation-critical/README.md and
# evals/scenarios/quick-mode-unparseable-severity-fail-closed/README.md for the full evidence
# chain and why those two are documentation-only stubs, not live Tier 2 scenarios.

QUICK_DECISION_JQ="$SCRIPT_DIR/fixtures/quick-mode-decision.jq"

qd_decide() {
  # $1 = jsonl file; prints one compact JSON object per distinct claim_id, then one final
  # aggregate decision line.
  jq -n -c -f "$QUICK_DECISION_JQ" "$1"
}
qd_decision_line() {
  # $1 = qd_decide output (one obj per line) -- the aggregate decision is always the LAST line.
  printf '%s\n' "$1" | tail -1
}

# 1. Sole open claim's latest severity is "medium" -> MINOR_ISSUES_ACKNOWLEDGED.
QD_FIXTURE_1="$(mktemp)"
cat > "$QD_FIXTURE_1" <<'EOF'
{"round":1,"codex_review":{"findings":[{"id":"f1","severity":"medium"}]},"claude_verification":[{"finding_id":"f1","claim_id":"f1","action":"reject_with_rationale"}]}
{"round":2,"codex_review":{"findings":[{"id":"f1","severity":"medium"}]},"claude_verification":[{"finding_id":"f1","claim_id":"f1","action":"reject_with_rationale","evidence_delta":"new"}]}
EOF
QD_OUT="$(qd_decide "$QD_FIXTURE_1")"
QD_DECISION="$(qd_decision_line "$QD_OUT")"
if [ "$(printf '%s' "$QD_DECISION" | jq -r '.decision')" = "MINOR_ISSUES_ACKNOWLEDGED" ] && [ "$(printf '%s' "$QD_DECISION" | jq -r '.open_count')" = "1" ]; then
  pass "quick-mode decision: sole open claim with canonical severity medium -> MINOR_ISSUES_ACKNOWLEDGED"
else
  fail "quick-mode decision: expected MINOR_ISSUES_ACKNOWLEDGED open_count=1, got: $QD_OUT"
fi
rm -f "$QD_FIXTURE_1"

# 2. Sole open claim's latest severity is "critical" -- structurally unreachable via a real
# dispatch (schema_mismatch would fire first), but this filter must still correctly reject it as
# NOT eligible for MINOR_ISSUES_ACKNOWLEDGED, AND -- separately -- must set escalated:true.
# Asserting BOTH matters: a bug that only checks HIGH (never CRITICAL) for the ESCALATED/MAX_ROUNDS
# rule would still produce NOT_ELIGIBLE here for an unrelated reason (critical isn't LOW/MEDIUM
# either way), so the decision field ALONE cannot distinguish "escalation correctly includes
# CRITICAL" from "escalation only checks HIGH" -- escalated must be asserted directly.
QD_FIXTURE_2="$(mktemp)"
cat > "$QD_FIXTURE_2" <<'EOF'
{"round":1,"codex_review":{"findings":[{"id":"f2","severity":"critical"}]},"claude_verification":[{"finding_id":"f2","claim_id":"f2","action":"reject_with_rationale"}]}
EOF
QD_OUT="$(qd_decide "$QD_FIXTURE_2")"
QD_DECISION="$(qd_decision_line "$QD_OUT")"
if [ "$(printf '%s' "$QD_DECISION" | jq -r '.decision')" = "NOT_ELIGIBLE" ] && [ "$(printf '%s' "$QD_DECISION" | jq -r '.escalated')" = "true" ]; then
  pass "quick-mode decision: sole open claim with canonical severity CRITICAL is NOT eligible for MINOR_ISSUES_ACKNOWLEDGED, AND sets escalated:true"
else
  fail "quick-mode decision: expected NOT_ELIGIBLE + escalated:true for a CRITICAL-severity open claim, got: $QD_OUT"
fi
rm -f "$QD_FIXTURE_2"

# 3. Sole open claim's latest severity is an unparseable string ("SEV-2") -- also structurally
# unreachable via a real dispatch, must fail closed to NOT_ELIGIBLE, never treated as minor and
# never treated as a third "ambiguous" category.
QD_FIXTURE_3="$(mktemp)"
cat > "$QD_FIXTURE_3" <<'EOF'
{"round":1,"codex_review":{"findings":[{"id":"f3","severity":"SEV-2"}]},"claude_verification":[{"finding_id":"f3","claim_id":"f3","action":"reject_with_rationale"}]}
EOF
QD_OUT="$(qd_decide "$QD_FIXTURE_3")"
QD_DECISION="$(qd_decision_line "$QD_OUT")"
if [ "$(printf '%s' "$QD_DECISION" | jq -r '.decision')" = "NOT_ELIGIBLE" ]; then
  pass "quick-mode decision: sole open claim with an unparseable severity string fails closed to NOT_ELIGIBLE"
else
  fail "quick-mode decision: expected NOT_ELIGIBLE for an unparseable-severity open claim, got: $QD_OUT"
fi
rm -f "$QD_FIXTURE_3"

# 4. Sole open claim's severity was never recorded (null on its only occurrence) -- the MISSING
# fail-closed subcase must never be treated as "no data, so pass."
QD_FIXTURE_4="$(mktemp)"
cat > "$QD_FIXTURE_4" <<'EOF'
{"round":1,"codex_review":{"findings":[{"id":"f4","severity":null}]},"claude_verification":[{"finding_id":"f4","claim_id":"f4","action":"reject_with_rationale"}]}
EOF
QD_OUT="$(qd_decide "$QD_FIXTURE_4")"
QD_DECISION="$(qd_decision_line "$QD_OUT")"
if [ "$(printf '%s' "$QD_DECISION" | jq -r '.decision')" = "NOT_ELIGIBLE" ]; then
  pass "quick-mode decision: sole open claim with a MISSING (null) severity fails closed to NOT_ELIGIBLE"
else
  fail "quick-mode decision: expected NOT_ELIGIBLE for a MISSING-severity open claim, got: $QD_OUT"
fi
rm -f "$QD_FIXTURE_4"

# 5. Most-recent-occurrence wins, not origin: severity starts "high" round 1, downgraded to
# "medium" by its latest occurrence round 2 -> canonical severity must be "medium" (eligible),
# proving this lookup is NOT the same as Phase 3's own origin-severity claims[] join.
QD_FIXTURE_5="$(mktemp)"
cat > "$QD_FIXTURE_5" <<'EOF'
{"round":1,"codex_review":{"findings":[{"id":"f5","severity":"high"}]},"claude_verification":[{"finding_id":"f5","claim_id":"f5","action":"reject_with_rationale"}]}
{"round":2,"codex_review":{"findings":[{"id":"f5","severity":"medium"}]},"claude_verification":[{"finding_id":"f5","claim_id":"f5","action":"reject_with_rationale","evidence_delta":"new"}]}
EOF
QD_OUT="$(qd_decide "$QD_FIXTURE_5")"
QD_DECISION="$(qd_decision_line "$QD_OUT")"
QD_ENTRY="$(printf '%s\n' "$QD_OUT" | jq -c --arg id f5 'select(.claim_id == $id)')"
if [ "$(printf '%s' "$QD_ENTRY" | jq -r '.canonical_severity')" = "medium" ] && [ "$(printf '%s' "$QD_DECISION" | jq -r '.decision')" = "MINOR_ISSUES_ACKNOWLEDGED" ]; then
  pass "quick-mode decision: canonical severity uses the MOST RECENT occurrence (medium), not the origin (high)"
else
  fail "quick-mode decision: expected canonical_severity=medium (most-recent, not origin high), got: $QD_OUT"
fi
rm -f "$QD_FIXTURE_5"

# 6. No open claims at all (K=0, the sole claim already resolved) -- never eligible regardless of
# its last-known severity.
QD_FIXTURE_6="$(mktemp)"
cat > "$QD_FIXTURE_6" <<'EOF'
{"round":1,"codex_review":{"findings":[{"id":"f6","severity":"medium"}]},"claude_verification":[{"finding_id":"f6","claim_id":"f6","action":"accept"}]}
{"round":2,"claim_closures":[{"claim_id":"f6","disposition":"resolved","source_round":2,"marker_reason":"fixed"}]}
EOF
QD_OUT="$(qd_decide "$QD_FIXTURE_6")"
QD_DECISION="$(qd_decision_line "$QD_OUT")"
if [ "$(printf '%s' "$QD_DECISION" | jq -r '.decision')" = "NOT_ELIGIBLE" ] && [ "$(printf '%s' "$QD_DECISION" | jq -r '.open_count')" = "0" ]; then
  pass "quick-mode decision: zero open claims (K=0) is never eligible for MINOR_ISSUES_ACKNOWLEDGED"
else
  fail "quick-mode decision: expected NOT_ELIGIBLE open_count=0, got: $QD_OUT"
fi
rm -f "$QD_FIXTURE_6"

# 7. A genuine RE-RAISE: the claim's ORIGIN finding_id (f7, round 1, severity medium) differs from
# its most-recent occurrence's OWN finding_id (f8, round 2, severity null -- claude_verification
# maps f8's claim_id back to f7). The canonical-severity lookup must follow f8 (the actual most
# recent occurrence's own finding_id), never fall back to matching against the claim_id (f7)
# itself -- that exact confusion was a real bug found and fixed via adversarial review: matching
# findings by claim_id instead of by the latest verification's own finding_id silently returns the
# ORIGIN severity for any re-raise, exactly backwards from the "most recent occurrence" rule this
# filter exists to implement.
QD_FIXTURE_7="$(mktemp)"
cat > "$QD_FIXTURE_7" <<'EOF'
{"round":1,"codex_review":{"findings":[{"id":"f7","severity":"medium"}]},"claude_verification":[{"finding_id":"f7","claim_id":"f7","action":"reject_with_rationale"}]}
{"round":2,"codex_review":{"findings":[{"id":"f8","severity":null}]},"claude_verification":[{"finding_id":"f8","claim_id":"f7","action":"reject_with_rationale","evidence_delta":"new"}]}
EOF
QD_OUT="$(qd_decide "$QD_FIXTURE_7")"
QD_DECISION="$(qd_decision_line "$QD_OUT")"
QD_ENTRY="$(printf '%s\n' "$QD_OUT" | jq -c --arg id f7 'select(.claim_id == $id)')"
if [ "$(printf '%s' "$QD_ENTRY" | jq -r '.canonical_severity')" = "null" ] && [ "$(printf '%s' "$QD_DECISION" | jq -r '.decision')" = "NOT_ELIGIBLE" ]; then
  pass "quick-mode decision: a re-raise's canonical severity follows its own most-recent finding_id (null), never the claim_id's origin finding (medium)"
else
  fail "quick-mode decision: expected canonical_severity=null via the re-raise's own finding_id f8 (not medium via claim_id f7), got: $QD_OUT"
fi
rm -f "$QD_FIXTURE_7"

# 8. Parallel-mode: a real aggregated finding keeps "id" and "group" as SEPARATE fields (never a
# raw finding whose own "id" already IS the group-prefixed string) -- the filter must compute the
# exact same join key documented in SKILL.md's Phase 3 "claims" construction and already extracted
# in tests/fixtures/claim-key-from-finding.jq: `group + ":" + id`. claude_verification's own
# claim_id/finding_id values ARE already group-prefixed strings (per claim-ledger.md section 9),
# so this fixture uses the real documented shape on both sides: a finding {id:"f1",group:"g1"}
# joined against a claim_id/finding_id of "g1:f1" -- a naive lookup assuming raw findings already
# carry a combined "g1:f1" id (an earlier, incorrect draft of this fixture did exactly that,
# masking this bug) would silently fail to match and wrongly fall through to NOT_ELIGIBLE.
QD_FIXTURE_8="$(mktemp)"
cat > "$QD_FIXTURE_8" <<'EOF'
{"round":1,"codex_review":{"findings":[{"id":"f1","group":"g1","severity":"medium"}]},"claude_verification":[{"finding_id":"g1:f1","claim_id":"g1:f1","action":"reject_with_rationale"}]}
EOF
QD_OUT="$(qd_decide "$QD_FIXTURE_8")"
QD_DECISION="$(qd_decision_line "$QD_OUT")"
if [ "$(printf '%s' "$QD_DECISION" | jq -r '.decision')" = "MINOR_ISSUES_ACKNOWLEDGED" ]; then
  pass "quick-mode decision: a parallel-mode finding ({id,group} separate fields) joins correctly via group+\":\"+id, not a raw group-prefixed id"
else
  fail "quick-mode decision: expected MINOR_ISSUES_ACKNOWLEDGED for a {id:f1,group:g1} finding joined against claim g1:f1, got: $QD_OUT"
fi
rm -f "$QD_FIXTURE_8"

# --- DISPOSITION marker parser fixtures (claim-ledger.md section 4) ---
# Exercises tests/fixtures/parse-disposition-markers.sh against free-text
# blobs standing in for Codex's `summary` field. Pure text parsing -- no
# wrapper dispatch, no fake-codex involved.

DISPOSITION_PARSER="$SCRIPT_DIR/fixtures/parse-disposition-markers.sh"

dm_line_for() {
  # $1 = parser output (one line per requested claim_id), $2 = claim_id
  printf '%s\n' "$1" | grep "^$2 "
}

# 1. One valid marker of each kind (RESOLVED / RETRACTED / STILL OPEN).
DM_FIXTURE_1="$(mktemp)"
cat > "$DM_FIXTURE_1" <<'EOF'
Some narration before the markers.
DISPOSITION f1: RESOLVED -- the null check now covers the empty-array case
DISPOSITION f2: RETRACTED -- withdrawing this, turned out to be a false positive
DISPOSITION f3: STILL OPEN -- not yet fixed, still reproduces on the current code
Trailing narration.
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_1" f1 f2 f3)"
if [ "$(dm_line_for "$DM_OUT" f1)" = "f1 RESOLVED the null check now covers the empty-array case" ] \
  && [ "$(dm_line_for "$DM_OUT" f2)" = "f2 RETRACTED withdrawing this, turned out to be a false positive" ] \
  && [ "$(dm_line_for "$DM_OUT" f3)" = "f3 STILL_OPEN not yet fixed, still reproduces on the current code" ]; then
  pass "DISPOSITION parser: one valid marker each of RESOLVED/RETRACTED/STILL OPEN parses correctly"
else
  fail "DISPOSITION parser: expected clean parses for f1/f2/f3, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_1"

# 2. Duplicate marker for the same claim_id -- must fail closed.
DM_FIXTURE_2="$(mktemp)"
cat > "$DM_FIXTURE_2" <<'EOF'
DISPOSITION f4: RESOLVED -- first marker for this claim
DISPOSITION f4: RETRACTED -- a second, conflicting marker for the same claim
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_2" f4)"
if [ "$(dm_line_for "$DM_OUT" f4)" = "f4 FAIL_CLOSED duplicate" ]; then
  pass "DISPOSITION parser: a duplicate marker for the same claim_id fails closed"
else
  fail "DISPOSITION parser: expected f4 FAIL_CLOSED duplicate, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_2"

# 3. Zero markers for a requested claim_id -- must fail closed as "missing".
DM_FIXTURE_3="$(mktemp)"
cat > "$DM_FIXTURE_3" <<'EOF'
No markers at all in this summary text.
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_3" f5)"
if [ "$(dm_line_for "$DM_OUT" f5)" = "f5 FAIL_CLOSED missing" ]; then
  pass "DISPOSITION parser: zero markers for a requested claim_id fails closed as missing"
else
  fail "DISPOSITION parser: expected f5 FAIL_CLOSED missing, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_3"

# 4. An unrecognized claim_id present in the text but never requested must
# be ignored entirely -- never surfaced, never treated as a closure for
# anything, and must not disturb parsing of the claim_id that WAS requested.
DM_FIXTURE_4="$(mktemp)"
cat > "$DM_FIXTURE_4" <<'EOF'
DISPOSITION f6: RESOLVED -- this one was actually requested
DISPOSITION f_never_requested: RESOLVED -- nobody asked about this claim_id
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_4" f6)"
if [ "$(dm_line_for "$DM_OUT" f6)" = "f6 RESOLVED this one was actually requested" ] \
  && ! printf '%s\n' "$DM_OUT" | grep -q "f_never_requested"; then
  pass "DISPOSITION parser: an unrecognized/not-requested claim_id is ignored, never invented as a closure"
else
  fail "DISPOSITION parser: expected only f6 RESOLVED in output, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_4"

# 5. Empty reason -- must fail closed as "empty_reason".
DM_FIXTURE_5="$(mktemp)"
cat > "$DM_FIXTURE_5" <<'EOF'
DISPOSITION f7: RESOLVED --
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_5" f7)"
if [ "$(dm_line_for "$DM_OUT" f7)" = "f7 FAIL_CLOSED empty_reason" ]; then
  pass "DISPOSITION parser: an empty reason fails closed as empty_reason"
else
  fail "DISPOSITION parser: expected f7 FAIL_CLOSED empty_reason, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_5"

# 6. Em dash instead of ASCII "--" -- claim-ledger.md section 4 explicitly
# worries about exactly this: a byte-for-byte mismatched separator must
# never match, leaving the claim un-parsed (fails closed as "missing", since
# zero valid markers were found for it).
DM_FIXTURE_6="$(mktemp)"
printf 'DISPOSITION f8: RESOLVED \xe2\x80\x94 em dash used instead of two ASCII hyphens\n' > "$DM_FIXTURE_6"
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_6" f8)"
if [ "$(dm_line_for "$DM_OUT" f8)" = "f8 FAIL_CLOSED missing" ]; then
  pass "DISPOSITION parser: an em dash separator never matches the ASCII '--' grammar, fails closed"
else
  fail "DISPOSITION parser: expected f8 FAIL_CLOSED missing (em dash must not match), got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_6"

# 7. A marker embedded mid-sentence (not at column zero, other text on the
# same line) must NOT match -- a whole-text substring search would catch
# this, but the line-anchored column-zero grammar must not.
DM_FIXTURE_7="$(mktemp)"
cat > "$DM_FIXTURE_7" <<'EOF'
A prior response said DISPOSITION f9: RESOLVED -- embedded mid-sentence, not a real marker
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_7" f9)"
if [ "$(dm_line_for "$DM_OUT" f9)" = "f9 FAIL_CLOSED missing" ]; then
  pass "DISPOSITION parser: a mid-sentence/mid-prose marker (not column zero) does not match, fails closed as missing"
else
  fail "DISPOSITION parser: expected f9 FAIL_CLOSED missing, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_7"

# 8. Two valid, non-fenced, column-zero markers for the SAME claim_id, even
# agreeing on the disposition -- must still fail closed as duplicate (a
# stricter case than fixture 2's conflicting-disposition duplicate).
DM_FIXTURE_8="$(mktemp)"
cat > "$DM_FIXTURE_8" <<'EOF'
DISPOSITION f17: RESOLVED -- first occurrence, agrees
DISPOSITION f17: RESOLVED -- second occurrence, same disposition, still a duplicate
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_8" f17)"
if [ "$(dm_line_for "$DM_OUT" f17)" = "f17 FAIL_CLOSED duplicate" ]; then
  pass "DISPOSITION parser: two agreeing markers for the same claim_id still fail closed as duplicate"
else
  fail "DISPOSITION parser: expected f17 FAIL_CLOSED duplicate, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_8"

# 9. The exact same valid marker text, indented 4 spaces -- must NOT match
# (column-zero anchoring also excludes Markdown's own indented-code-block
# convention, which needs >=4 leading spaces).
DM_FIXTURE_9="$(mktemp)"
printf '    DISPOSITION f18: RESOLVED -- indented 4 spaces, must not match\n' > "$DM_FIXTURE_9"
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_9" f18)"
if [ "$(dm_line_for "$DM_OUT" f18)" = "f18 FAIL_CLOSED missing" ]; then
  pass "DISPOSITION parser: a marker indented 4 spaces does not match, fails closed as missing"
else
  fail "DISPOSITION parser: expected f18 FAIL_CLOSED missing, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_9"

# 10. The exact same valid marker text, inside a backtick fence with a
# language tag -- content inside a fence is excluded entirely.
DM_FIXTURE_10="$(mktemp)"
cat > "$DM_FIXTURE_10" <<'EOF'
```text
DISPOSITION f19: RESOLVED -- inside a backtick fence with a language tag
```
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_10" f19)"
if [ "$(dm_line_for "$DM_OUT" f19)" = "f19 FAIL_CLOSED missing" ]; then
  pass "DISPOSITION parser: a marker inside a backtick-fenced block (with language tag) is excluded, fails closed as missing"
else
  fail "DISPOSITION parser: expected f19 FAIL_CLOSED missing, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_10"

# 11. The exact same valid marker text, inside a tilde fence -- content
# inside a tilde-fenced block is excluded exactly like a backtick fence.
DM_FIXTURE_11="$(mktemp)"
cat > "$DM_FIXTURE_11" <<'EOF'
~~~
DISPOSITION f20: RESOLVED -- inside a tilde fence
~~~
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_11" f20)"
if [ "$(dm_line_for "$DM_OUT" f20)" = "f20 FAIL_CLOSED missing" ]; then
  pass "DISPOSITION parser: a marker inside a tilde-fenced block is excluded, fails closed as missing"
else
  fail "DISPOSITION parser: expected f20 FAIL_CLOSED missing, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_11"

# 12. A 4-backtick opener containing a 3-backtick line that looks like a
# closer -- length 3 < opening length 4, so it must NOT close the block; the
# real marker between the fake close and the real 4-backtick closer stays
# excluded.
DM_FIXTURE_12="$(mktemp)"
cat > "$DM_FIXTURE_12" <<'EOF'
````
```
DISPOSITION f21: RESOLVED -- between a too-short fake closer and the real closer
````
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_12" f21)"
if [ "$(dm_line_for "$DM_OUT" f21)" = "f21 FAIL_CLOSED missing" ]; then
  pass "DISPOSITION parser: a shorter same-character line inside a longer fence does not close it, marker stays excluded"
else
  fail "DISPOSITION parser: expected f21 FAIL_CLOSED missing (fake short closer must not close the block), got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_12"

# 13. An opened-but-never-closed fence running to EOF, with a genuinely
# valid marker INSIDE it -- must fail closed for ALL requested claim_ids
# this round (not just the one inside the fence), since the whole response
# is malformed.
DM_FIXTURE_13="$(mktemp)"
cat > "$DM_FIXTURE_13" <<'EOF'
DISPOSITION f22: RESOLVED -- this one sits outside the fence, before it opens
```
DISPOSITION f23: RESOLVED -- this one sits inside the never-closed fence
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_13" f22 f23)"
if [ "$(dm_line_for "$DM_OUT" f22)" = "f22 FAIL_CLOSED unclosed_fence" ] \
  && [ "$(dm_line_for "$DM_OUT" f23)" = "f23 FAIL_CLOSED unclosed_fence" ]; then
  pass "DISPOSITION parser: an unclosed fence at EOF fails closed for EVERY requested claim_id, not just the one inside it"
else
  fail "DISPOSITION parser: expected both f22 and f23 FAIL_CLOSED unclosed_fence, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_13"

# 14. A real, valid, column-zero, non-fenced marker on the line immediately
# AFTER a properly closed fence -- must still match normally (closing a
# fence must not leak "still fenced" state past its own close line).
DM_FIXTURE_14="$(mktemp)"
cat > "$DM_FIXTURE_14" <<'EOF'
```
irrelevant fenced content
```
DISPOSITION f24: RESOLVED -- right after the fence closes, must match
EOF
DM_OUT="$(bash "$DISPOSITION_PARSER" "$DM_FIXTURE_14" f24)"
if [ "$(dm_line_for "$DM_OUT" f24)" = "f24 RESOLVED right after the fence closes, must match" ]; then
  pass "DISPOSITION parser: a valid marker immediately after a properly closed fence still matches"
else
  fail "DISPOSITION parser: expected f24 RESOLVED right after the fence closes, must match, got: $DM_OUT"
fi
rm -f "$DM_FIXTURE_14"

# --- parallel-mode coverage merge fixtures (parallel-mode.md / SKILL.md's ---
# --- "Round-1 N-group merge" worst-case-wins rule) ---
# Exercises tests/fixtures/parallel-coverage-merge.jq. Pure jq over inline
# JSON arrays -- no wrapper dispatch, no fake-codex involved.

COVERAGE_MERGE_JQ="$SCRIPT_DIR/fixtures/parallel-coverage-merge.jq"

cov_merge() {
  # $1 = JSON array of {status, omitted} group coverage.source objects
  printf '%s' "$1" | jq -c -f "$COVERAGE_MERGE_JQ"
}

# 1. All groups complete -> merged complete, empty omitted.
COV_ALL_COMPLETE='[{"status":"complete","omitted":[]},{"status":"complete","omitted":[]},{"status":"complete","omitted":[]}]'
COV_OUT="$(cov_merge "$COV_ALL_COMPLETE")"
if [ "$COV_OUT" = '{"status":"complete","omitted":[]}' ]; then
  pass "coverage merge: all groups complete merges to complete with empty omitted"
else
  fail "coverage merge: expected complete/empty, got: $COV_OUT"
fi

# 2. One partial among otherwise-complete groups -> merged partial, carrying
# that group's own omitted list.
COV_ONE_PARTIAL='[{"status":"complete","omitted":[]},{"status":"partial","omitted":[{"path":"a.bin","reason":"binary_file"}]},{"status":"complete","omitted":[]}]'
COV_OUT="$(cov_merge "$COV_ONE_PARTIAL")"
COV_EXPECTED='{"status":"partial","omitted":[{"path":"a.bin","reason":"binary_file"}]}'
if [ "$COV_OUT" = "$COV_EXPECTED" ]; then
  pass "coverage merge: one partial group among complete ones merges to partial, carrying its omitted list"
else
  fail "coverage merge: expected $COV_EXPECTED, got: $COV_OUT"
fi

# 3. Two partial groups with an overlapping (path, reason) pair -> merged
# omitted has that pair only once (deduplicated), since every group reviews
# the identical full diff and would otherwise report the same skipped file
# once PER GROUP.
COV_TWO_PARTIAL_OVERLAP='[{"status":"partial","omitted":[{"path":"a.bin","reason":"binary_file"}]},{"status":"partial","omitted":[{"path":"a.bin","reason":"binary_file"},{"path":"b.bin","reason":"too_large"}]}]'
COV_OUT="$(cov_merge "$COV_TWO_PARTIAL_OVERLAP")"
COV_A_COUNT="$(printf '%s' "$COV_OUT" | jq '[.omitted[] | select(.path == "a.bin" and .reason == "binary_file")] | length')"
COV_B_COUNT="$(printf '%s' "$COV_OUT" | jq '[.omitted[] | select(.path == "b.bin" and .reason == "too_large")] | length')"
if [ "$(printf '%s' "$COV_OUT" | jq -r '.status')" = "partial" ] && [ "$COV_A_COUNT" = "1" ] && [ "$COV_B_COUNT" = "1" ]; then
  pass "coverage merge: an overlapping (path, reason) pair across two partial groups is deduplicated to one entry"
else
  fail "coverage merge: expected exactly one a.bin/binary_file entry and one b.bin/too_large entry, got: $COV_OUT"
fi

# 4. A mix of complete and unknown, with no partial present at all -> per
# the documented precedence ("'partial' ... if any group reported 'partial',
# else the 'unknown' sentinel if the rest reported 'unknown'"), this merges
# to unknown, not complete -- "complete" requires EVERY group to be complete.
COV_MIX_UNKNOWN='[{"status":"complete","omitted":[]},{"status":"unknown","omitted":[]}]'
COV_OUT="$(cov_merge "$COV_MIX_UNKNOWN")"
if [ "$(printf '%s' "$COV_OUT" | jq -r '.status')" = "unknown" ]; then
  pass "coverage merge: a complete+unknown mix with no partial group merges to unknown per the documented precedence"
else
  fail "coverage merge: expected status=unknown, got: $COV_OUT"
fi

# --- aggregated findings[] group-tagging + claim_id join-key fixtures ---
# (parallel-mode.md's groups[] JSONL section + SKILL.md's Phase 3 "claims"
# join-key expression). Exercises tests/fixtures/aggregate-findings-groups.jq
# and tests/fixtures/claim-key-from-finding.jq. Pure jq over inline JSON --
# no wrapper dispatch, no fake-codex involved.

AGGREGATE_JQ="$SCRIPT_DIR/fixtures/aggregate-findings-groups.jq"
CLAIM_KEY_JQ="$SCRIPT_DIR/fixtures/claim-key-from-finding.jq"

# 1. Two groups, two findings each -> 4 tagged items with correct "group"
# field, then correctly-prefixed join keys (g1:f1, g1:f2, g2:f1, g2:f2).
AGG_INPUT='[{"group":"g1","codex_review":{"findings":[{"id":"f1"},{"id":"f2"}]}},{"group":"g2","codex_review":{"findings":[{"id":"f1"},{"id":"f2"}]}}]'
AGG_OUT="$(printf '%s' "$AGG_INPUT" | jq -c -f "$AGGREGATE_JQ")"
AGG_EXPECTED='[{"id":"f1","group":"g1"},{"id":"f2","group":"g1"},{"id":"f1","group":"g2"},{"id":"f2","group":"g2"}]'
if [ "$AGG_OUT" = "$AGG_EXPECTED" ]; then
  pass "aggregate findings: two groups' findings are concatenated, each tagged with its source group"
else
  fail "aggregate findings: expected $AGG_EXPECTED, got: $AGG_OUT"
fi
KEY_OUT="$(printf '%s' "$AGG_OUT" | jq -c -f "$CLAIM_KEY_JQ")"
KEY_EXPECTED='["g1:f1","g1:f2","g2:f1","g2:f2"]'
if [ "$KEY_OUT" = "$KEY_EXPECTED" ]; then
  pass "claim key join: group-tagged findings produce group-prefixed claim_id keys"
else
  fail "claim key join: expected $KEY_EXPECTED, got: $KEY_OUT"
fi

# 2. Single-reviewer shape (no "group" field anywhere) -> keys fall through
# to the bare id, unifying both shapes in one expression.
SINGLE_REVIEWER_FINDINGS='[{"id":"f1"},{"id":"f2"}]'
KEY_OUT="$(printf '%s' "$SINGLE_REVIEWER_FINDINGS" | jq -c -f "$CLAIM_KEY_JQ")"
KEY_EXPECTED='["f1","f2"]'
if [ "$KEY_OUT" = "$KEY_EXPECTED" ]; then
  pass "claim key join: single-reviewer findings (no group field) fall through to the bare id"
else
  fail "claim key join: expected $KEY_EXPECTED, got: $KEY_OUT"
fi

# --- fake-codex fixture enhancements: FAKE_CODEX_INVOCATION_LOG / ---
# --- FAKE_CODEX_GROUP_STATE (tests/fixtures/fake-codex) ---
# Both are purely-additive, opt-in capabilities needed by follow-up
# scenario-building tasks. Leaving both unset changes nothing -- every
# fixture in this entire suite, above and below, never sets either one, and
# the whole suite passes exactly as before (its own pass/fail counts are the
# regression check for that).

# 1. FAKE_CODEX_INVOCATION_LOG: a fresh dispatch followed by a --resume
# dispatch on the resulting thread must append exactly two lines, in
# mode order, each carrying the actually-resolved thread id and the
# scenario in effect.
FC_INVOCATION_LOG="$(mktemp)"
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_INVOCATION_LOG="$FC_INVOCATION_LOG"
OUT="$(pd_run fresh)"
FC_TID="$(pd_threadid "$OUT")"
pd_run resume "$FC_TID" >/dev/null
unset FAKE_CODEX_SCENARIO FAKE_CODEX_INVOCATION_LOG
FC_LOG_LINE_COUNT="$(wc -l < "$FC_INVOCATION_LOG" | tr -d ' ')"
if [ -n "$FC_TID" ] && [ "$FC_LOG_LINE_COUNT" = "2" ] \
  && [ "$(sed -n '1p' "$FC_INVOCATION_LOG")" = "mode=fresh thread_id=$FC_TID scenario=normal" ] \
  && [ "$(sed -n '2p' "$FC_INVOCATION_LOG")" = "mode=resume thread_id=$FC_TID scenario=normal" ]; then
  pass "fake-codex FAKE_CODEX_INVOCATION_LOG: records mode/thread_id/scenario for a fresh dispatch then its resume, in order"
else
  fail "fake-codex FAKE_CODEX_INVOCATION_LOG: expected 2 lines (fresh then resume) with thread_id=$FC_TID, got: $(cat "$FC_INVOCATION_LOG")"
fi
rm -f "$FC_INVOCATION_LOG"

# 2. FAKE_CODEX_GROUP_STATE: two separate fresh dispatches (each a genuinely
# separate process invocation of the fixture, via pd_run) sharing the same
# state directory must play back round-0's then round-1's pre-scripted
# final answers, in order, and the state directory's own round counter must
# have advanced to 2.
FC_GROUP_STATE="$(mktemp -d)"
cat > "$FC_GROUP_STATE/round-0-final-answer.json" <<'EOF'
{"verdict":"CLEAN","findings":[],"summary":"round zero scripted verdict","dimensions":{"correctness":{"status":"not_applicable","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF
cat > "$FC_GROUP_STATE/round-1-final-answer.json" <<'EOF'
{"verdict":"CLEAN","findings":[],"summary":"round one scripted verdict","dimensions":{"correctness":{"status":"not_applicable","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}
EOF
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_GROUP_STATE="$FC_GROUP_STATE"
OUT_R0="$(pd_run fresh)"
OUT_R1="$(pd_run fresh)"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_GROUP_STATE
FC_R0_SUMMARY="$(printf '%s' "$OUT_R0" | tail -1 | jq -r '.verdict.summary // empty')"
FC_R1_SUMMARY="$(printf '%s' "$OUT_R1" | tail -1 | jq -r '.verdict.summary // empty')"
FC_ROUND_COUNTER="$(cat "$FC_GROUP_STATE/round" 2>/dev/null)"
if [ "$FC_R0_SUMMARY" = "round zero scripted verdict" ] \
  && [ "$FC_R1_SUMMARY" = "round one scripted verdict" ] \
  && [ "$FC_ROUND_COUNTER" = "2" ]; then
  pass "fake-codex FAKE_CODEX_GROUP_STATE: plays back round-0 then round-1 scripted final answers across two separate dispatches, advancing the counter"
else
  fail "fake-codex FAKE_CODEX_GROUP_STATE: expected round0/round1 summaries and counter=2, got round0=$FC_R0_SUMMARY round1=$FC_R1_SUMMARY counter=$FC_ROUND_COUNTER"
fi
rm -rf "$FC_GROUP_STATE"

rm -rf "$FAKE_HOME" "$FAKE_BIN_DIR" "$PD_REPO"

# --- check-result.sh contract fixtures (schema-check.jq + a real scenario's ---
# --- own expect.sh, exercised together) ---
# Proves the FULL check-result.sh contract, not just schema-check.jq alone:
# every case below passes the scenario name "clean-basic" (never omitted),
# so a mutation that schema-check.jq would miss but clean-basic/expect.sh
# would catch (or vice versa) is still caught here.

CHECK_RESULT_SH="$SCRIPT_DIR/../evals/check-result.sh"

# A single canned-valid result.json, simultaneously valid per
# schemas/interactive-result.schema.json (via lib/schema-check.jq) and per
# scenarios/clean-basic/expect.sh's own assertions (exit_state CLEAN,
# round_count 1, one thread kind:current cleanup:deleted).
CB_VALID_JSON='{"session_id":"cb-fixture-session","target":{"repo":"/tmp/cb-fixture-repo","scope":"uncommitted"},"exit_state":"CLEAN","round_count":1,"threads":[{"group":"main","thread_id":"cb-fixture-thread","kind":"current","cleanup":"deleted"}],"claims":[],"coverage":{"status":"complete","reviewed_file_count":0,"omitted":[]},"input_errors":null}'

CB_VALID_FILE="$(mktemp)"
printf '%s' "$CB_VALID_JSON" > "$CB_VALID_FILE"
if bash "$CHECK_RESULT_SH" "$CB_VALID_FILE" clean-basic >/dev/null 2>&1; then
  pass "check-result.sh contract: unmodified canned-valid clean-basic fixture PASSES"
else
  fail "check-result.sh contract: unmodified canned-valid clean-basic fixture should PASS, but failed"
fi

cb_mutation_should_fail() {
  local label="$1" jq_filter="$2" mutated_file
  mutated_file="$(mktemp)"
  printf '%s' "$CB_VALID_JSON" | jq -c "$jq_filter" > "$mutated_file"
  if bash "$CHECK_RESULT_SH" "$mutated_file" clean-basic >/dev/null 2>&1; then
    fail "check-result.sh contract: $label should FAIL, but PASSED"
  else
    pass "check-result.sh contract: $label FAILS as expected"
  fi
  rm -f "$mutated_file"
}

cb_mutation_should_fail "exit_state set to a value outside the 7-value enum" \
  '.exit_state = "BOGUS_STATE"'
cb_mutation_should_fail "a required top-level field (session_id) deleted" \
  'del(.session_id)'
cb_mutation_should_fail "threads[0].cleanup set to a value outside deleted|failed|retained" \
  '.threads[0].cleanup = "bogus"'
cb_mutation_should_fail "round_count changed from a number to a string" \
  '.round_count = "1"'
cb_mutation_should_fail "round_count changed to a schema-valid but scenario-wrong value (2 instead of 1) -- fails clean-basic/expect.sh specifically, not schema-check.jq" \
  '.round_count = 2'

rm -f "$CB_VALID_FILE"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All fixtures passed."
  exit 0
else
  echo "$FAILURES fixture(s) failed."
  exit 1
fi

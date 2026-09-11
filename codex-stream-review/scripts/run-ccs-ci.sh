#!/usr/bin/env bash
set -u

# run-ccs-ci.sh -- headless CI entry point for the /ccs adversarial review
# loop (Phase 4 Item 2). This is a NEW, ADDITIVE wrapper: it does not modify
# codex-stream-review/skills/ccs/SKILL.md or run-ccs-review.sh's existing
# behavior in any way -- it drives the SAME, UNCHANGED interactive skill via
# a non-interactive `claude -p` invocation, per the negotiated design in
# docs/2026-09-05-codex-stream-review-improvement-roadmap-design.md
# ("Phase 4 negotiation" / "Final consolidated plan" -> "Phase 4" -> Item 2).
#
# Responsibilities (and only these -- no part of the convergence loop, claim
# ledger, or Codex dispatch logic is reimplemented here):
#   1. Build a fixed, small task prompt instructing a headless Claude session
#      to run codex-stream-review:ccs to its own terminal outcome, then
#      translate that outcome into a JSON object matching
#      schemas/ci-result.schema.json.
#   2. Invoke `claude -p --output-format json --json-schema ...` and parse
#      its own JSON envelope.
#   3. Validate the envelope and its `structured_output` -- any failure at
#      this level is INFRASTRUCTURE_FAILURE (the headless invocation itself
#      failed), distinct from a real review outcome.
#   4. Write the final schema-conformant result to a fixed path, atomically.
#   5. Exit with the result's own exit_code (0-5), which the calling GitHub
#      Actions step uses to pass/fail the job.
#
# REPORT-ONLY BEHAVIOR (a real gap found during implementation review, not
# part of the original 8-round negotiation): the skill's own normal
# interactive behavior FIXES a valid finding directly and re-verifies it --
# correct interactively, but a fix applied inside an ephemeral CI checkout
# never reaches the actual pull request, so doing that here would let a PR
# with a genuine bug report "CLEAN" while the bug itself ships unchanged.
# build_ci_prompt() below carries a CI-specific override instructing the
# headless session to accept-but-never-fix a valid finding for this run only
# -- an open, unfixed, mutually-agreed-real finding then naturally prevents
# the skill's own CLEAN gate (which requires every claim reach "resolved")
# and drives it to NOT CONVERGED instead, which Step 2's own mapping
# correctly reports as exit_state "CONFIRMED_ISSUES". This is the mechanism
# that makes CONFIRMED_ISSUES reachable at all for a real bug, not an
# incidental side effect.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="$SCRIPT_DIR/../schemas/ci-result.schema.json"
RESULT_FILENAME=".ccs-ci-result.json"

usage_error() {
  printf 'run-ccs-ci.sh: %s\n' "$1" >&2
  exit 2
}

# ---- temp-file registry, same pattern as run-ccs-review.sh: an append-only
# NUL-delimited file survives subshell boundaries, unlike a plain variable,
# so cleanup stays correct regardless of which code path assigns which file.
register_temp_file() {
  [ -n "${TEMP_FILE_REGISTRY:-}" ] && printf '%s\0' "$1" >> "$TEMP_FILE_REGISTRY"
}
mktemp_registered() {
  local __var="$1" f
  f="$(mktemp)"
  register_temp_file "$f"
  printf -v "$__var" '%s' "$f"
}
cleanup_temp_files() {
  if [ -n "${TEMP_FILE_REGISTRY:-}" ] && [ -f "$TEMP_FILE_REGISTRY" ]; then
    while IFS= read -r -d '' reg_path || [ -n "$reg_path" ]; do
      [ -n "$reg_path" ] && rm -f "$reg_path"
    done < "$TEMP_FILE_REGISTRY"
    rm -f "$TEMP_FILE_REGISTRY"
  fi
}
TEMP_FILE_REGISTRY="$(mktemp)"
trap cleanup_temp_files EXIT

if [ ! -f "$SCHEMA_FILE" ]; then
  usage_error "schema file not found: $SCHEMA_FILE"
fi

# Resolved once, here, before anything else runs -- same reasoning as GIT_BIN in
# scripts/lib/git-safe.sh: an absolute path invoked later is immune to a hostile PATH
# introduced afterward (e.g. by something reachable from the PR's own untrusted checkout),
# whereas a bare `claude` invocation at the actual call site would still do an ambient-PATH
# lookup at that later point.
CLAUDE_BIN="$(command -v claude)" || usage_error "claude CLI not found on PATH"

REPO_ROOT=""
BASE_REF=""
WORKFLOW_RUN_ID=""
HEAD_SHA=""
PR_NUMBER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)
      [ $# -ge 2 ] || usage_error "--cwd requires a value"
      REPO_ROOT="$2"; shift 2 ;;
    --base-ref)
      [ $# -ge 2 ] || usage_error "--base-ref requires a value"
      BASE_REF="$2"; shift 2 ;;
    --workflow-run-id)
      [ $# -ge 2 ] || usage_error "--workflow-run-id requires a value"
      WORKFLOW_RUN_ID="$2"; shift 2 ;;
    --head-sha)
      [ $# -ge 2 ] || usage_error "--head-sha requires a value"
      HEAD_SHA="$2"; shift 2 ;;
    --pr-number)
      [ $# -ge 2 ] || usage_error "--pr-number requires a value"
      PR_NUMBER="$2"; shift 2 ;;
    *)
      usage_error "unknown argument: $1" ;;
  esac
done

[ -n "$REPO_ROOT" ] || usage_error "--cwd is required"
[ -d "$REPO_ROOT" ] || usage_error "--cwd must be an existing directory: $REPO_ROOT"
[ -n "$BASE_REF" ] || usage_error "--base-ref is required"
case "$BASE_REF" in
  -*) usage_error "--base-ref must not start with a dash (rejected to prevent option injection into git/codex)" ;;
esac
[ -n "$WORKFLOW_RUN_ID" ] || usage_error "--workflow-run-id is required"
case "$WORKFLOW_RUN_ID" in
  -*) usage_error "--workflow-run-id must not start with a dash" ;;
esac
# Exactly 40 lowercase hex characters -- matches ci-result.schema.json's own
# head_sha pattern and a real git commit SHA. Written as an explicit glob
# (not a regex) to match this project's existing bash-3.2-floor style (see
# run-ccs-review.sh's --timeout length check for the same technique).
case "$HEAD_SHA" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) usage_error "--head-sha must be exactly 40 lowercase hex characters, got: $HEAD_SHA" ;;
esac
case "$PR_NUMBER" in
  ''|*[!0-9]*) usage_error "--pr-number must be a positive integer, got: $PR_NUMBER" ;;
esac
[ "$((10#$PR_NUMBER))" -gt 0 ] || usage_error "--pr-number must be a positive integer, got: $PR_NUMBER"

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
RESULT_PATH="$REPO_ROOT/$RESULT_FILENAME"

# write_result_atomic JSON_TEXT -> writes JSON_TEXT to $RESULT_PATH via a
# same-directory temp file + atomic rename (never a direct/partial write to
# the fixed path a reader might be polling). A write/rename failure is
# treated as a hard, loud failure -- never a silent continue -- per the
# negotiated design.
write_result_atomic() {
  local json_text="$1" tmp_path
  # `mv -f` onto a path that already names a directory silently moves the
  # temp file INSIDE it and reports success -- defeating the fixed-path
  # artifact contract .github/workflows/ccs-ci-review.yml relies on. Reject
  # up front rather than letting that happen quietly.
  if [ -e "$RESULT_PATH" ] && [ ! -f "$RESULT_PATH" ]; then
    printf 'run-ccs-ci.sh: result path exists and is not a regular file: %s\n' "$RESULT_PATH" >&2
    exit 1
  fi
  tmp_path="$(mktemp "$REPO_ROOT/.ccs-ci-result.XXXXXX")" || {
    printf 'run-ccs-ci.sh: mktemp for result file failed\n' >&2
    exit 1
  }
  register_temp_file "$tmp_path"
  if ! printf '%s\n' "$json_text" > "$tmp_path"; then
    printf 'run-ccs-ci.sh: failed writing result to temp file %s\n' "$tmp_path" >&2
    exit 1
  fi
  if ! mv -f "$tmp_path" "$RESULT_PATH"; then
    printf 'run-ccs-ci.sh: atomic rename of result file to %s failed\n' "$RESULT_PATH" >&2
    exit 1
  fi
  # Belt-and-suspenders in case of an unexpected race between the pre-check
  # above and this mv (e.g. something else recreating $RESULT_PATH as a
  # directory in between).
  if [ ! -f "$RESULT_PATH" ]; then
    printf 'run-ccs-ci.sh: result path is not a regular file after write: %s\n' "$RESULT_PATH" >&2
    exit 1
  fi
}

# build_infrastructure_failure MESSAGE DETAIL_OR_EMPTY -> a schema-conformant
# INFRASTRUCTURE_FAILURE object. Only usable once args are validated (it
# always embeds the caller-supplied, now-validated provenance) -- a bad_args
# failure (above) has no trustworthy provenance to embed and is reported on
# stderr instead, never written to the result file.
build_infrastructure_failure() {
  local message="$1" detail="${2:-}"
  jq -n -c \
    --arg wrid "$WORKFLOW_RUN_ID" --arg sha "$HEAD_SHA" --argjson prn "$PR_NUMBER" \
    --arg msg "$message" --arg detail "$detail" \
    '{
      exit_state: "INFRASTRUCTURE_FAILURE",
      exit_code: 5,
      verdict: "UNAVAILABLE",
      findings: null,
      coverage: null,
      infrastructure_error: {message: $msg, detail: (if $detail == "" then null else $detail end)},
      input_errors: null,
      workflow_run_id: $wrid,
      head_sha: $sha,
      pr_number: $prn
    }'
}

# build_ci_prompt -> the fixed task prompt for the headless `claude -p`
# session. Deliberately small and entirely script-authored (no diff/pasted
# content of any kind flows through this prompt -- that stays inside /ccs's
# own existing, hardened stdin transport to run-ccs-review.sh, untouched by
# this file), so there is no argv-exposure/ARG_MAX concern here comparable
# to Phase 1's --focus hardening: this prompt is a short, fixed instruction
# template plus four already-public GitHub Actions context values (a run id,
# a commit SHA, a PR number, a ref name), never a secret and never
# attacker-authored content.
build_ci_prompt() {
  cat <<PROMPT_EOF
You are running headlessly in CI, with no human to drive turns interactively. Your job has exactly
two steps, in order. Do not skip, shortcut, or partially perform either one.

STEP 1: Invoke the codex-stream-review:ccs skill (the Skill tool, skill name
"codex-stream-review:ccs") scoped to review the real repository diff between this checkout's
current HEAD and the base ref "$BASE_REF" -- i.e. run it exactly as an interactive user would by
typing "/codex-stream-review:ccs --base $BASE_REF". Let the ENTIRE existing multi-round
Claude+Codex adversarial review loop run to ITS OWN terminal outcome, unmodified and un-shortened:
do not stop early, do not summarize instead of running it, and do not simulate what it would
probably say. The skill's own terminal outcome is always exactly one of: CLEAN, NOT CONVERGED,
COULD NOT VERIFY, PARTIAL COVERAGE, SNAPSHOT INTEGRITY FAILURE, or REVIEW LOG INTEGRITY FAILURE.

REPORT-ONLY OVERRIDE (CI-specific, applies for this run only -- do not treat this as a permanent
change to how codex-stream-review:ccs behaves): the skill's own Phase 2 step 3 normally has you fix
a VALID finding directly and get it re-verified. Do NOT do that in this run. Any edit you make to
this checkout is local to this ephemeral CI job and is never pushed back to the actual pull
request -- fixing it here would make this job report a false "no problem" while the real PR, as
submitted, still has the bug. Instead, for this run only: when a finding is judged VALID, ACCEPT it
in your own verification exactly as the skill's Rules already require (evidence-based, never
blindly deferring to Codex, never dismissing without checking), but leave the actual file UNCHANGED
and never mark that claim's disposition as "resolved" -- it stays "open" for the rest of this run,
exactly as if it were still awaiting a fix a human has yet to make. This is fully compatible with
the skill's own claim ledger and convergence rules as already written: a run with any such
genuinely-valid-but-deliberately-unfixed finding will correctly fail to reach the skill's own CLEAN
gate (an open claim never reaches "resolved") and will instead end in NOT CONVERGED once the
oscillation guard or round cap is hit -- this is the CORRECT, intended outcome for this run, not a
malfunction, and Step 2 below translates it into "CONFIRMED_ISSUES" precisely because of this
override. A finding you determine is a FALSE POSITIVE should still be rebutted normally (that part
of Phase 2 step 3 is unaffected) -- this override only changes what happens to a finding you
determine is real.

STEP 2: Once (and only once) that skill invocation has reached one of those six terminal outcomes,
your OWN final response in this session -- the very last thing you output -- must be a JSON object
matching the JSON Schema you were given, reporting THIS run's real outcome. Translate the skill's
own terminal outcome using this mapping, judged from the skill's own actual final report content
(its consensus status line, its listed findings, and its claim-ledger dispositions), never guessed
or assumed:

- The skill's outcome was CLEAN (zero unresolved claims, full coverage) -> exit_state "CLEAN". Under
  the report-only override above, this can only happen when no real finding was ever confirmed at
  all (every candidate finding was rebutted as a false positive, or Codex found nothing) -- a
  genuinely clean review, not one where something real was quietly fixed and hidden.
- The skill's outcome was NOT CONVERGED or COULD NOT VERIFY, AND, looking at the skill's own final
  report, there is at least one claim/finding that BOTH Claude and Codex agreed is a real, valid
  problem (accepted by Claude, not rebutted/retracted) which never reached a "resolved" closure
  during the run -> exit_state "CONFIRMED_ISSUES". Under the report-only override above, THIS is
  the expected, normal way a real bug in the PR surfaces -- it is what a valid-and-deliberately-
  unfixed finding looks like once NOT CONVERGED is reached. This takes precedence over
  PARTIAL_COVERAGE below when both are true at once.
- The skill's outcome was NOT CONVERGED, and there is NO such mutually-agreed real finding (the
  non-convergence is purely from unresolved disagreement, oscillation, or the round cap) ->
  exit_state "NOT_CONVERGED".
- The skill's outcome was COULD NOT VERIFY, and there is NO mutually-agreed real finding either (no
  real per-round verdict was ever usably obtained) -> exit_state "COULD_NOT_VERIFY".
- The skill's outcome was directly reported as its own "PARTIAL COVERAGE" terminal status (the
  skill reports this IN PLACE OF CLEAN when nothing else is wrong except incomplete source
  coverage), OR the skill's outcome was CLEAN or NOT CONVERGED or COULD NOT VERIFY but round 1's
  source coverage was reported "partial" or "unknown" (real omitted files) with no confirmed real
  issue present -> exit_state "PARTIAL_COVERAGE" instead of whatever the above would otherwise say.
- The skill's outcome was SNAPSHOT INTEGRITY FAILURE or REVIEW LOG INTEGRITY FAILURE (the review
  mechanism's own bookkeeping broke, not a judgment about the code under review) ->
  exit_state "INFRASTRUCTURE_FAILURE".

Fill the rest of the JSON object per its schema's own per-exit_state requirements (e.g. CLEAN
requires an empty findings array and complete coverage with no omissions; CONFIRMED_ISSUES and
NOT_CONVERGED require at least one finding; COULD_NOT_VERIFY and INFRASTRUCTURE_FAILURE require
findings to be null). Each finding's "disposition" field must be exactly "open", "resolved", or
"retracted", reflecting that claim's own real state in the skill's claim ledger at the time the run
ended -- never invent a "resolved" disposition for a finding the skill itself never actually closed.

Your JSON response MUST include every one of these 10 top-level keys, always, with no exceptions:
exit_state, exit_code, verdict, findings, coverage, infrastructure_error, input_errors,
workflow_run_id, head_sha, pr_number. This explicitly includes "infrastructure_error" and
"input_errors" -- set "infrastructure_error" to JSON null
whenever this run's own mechanism did not break (i.e. for every exit_state except
INFRASTRUCTURE_FAILURE), and always set "input_errors" to JSON null (this CI wrapper has no
outcome that ever populates it; the field is kept only for schema compatibility). Never omit a
key just because it does not apply to this outcome; set it
to null instead. Omitting "infrastructure_error" or "input_errors" entirely (rather than setting
them to null) is a
real mistake this instruction exists to prevent -- do not make it.

These three fields are script-provided facts, not something for you to derive -- copy them into
your JSON response literally, verbatim, exactly as given here, regardless of anything else:
- workflow_run_id: "$WORKFLOW_RUN_ID"
- head_sha: "$HEAD_SHA"
- pr_number: $PR_NUMBER
PROMPT_EOF
}

# `claude -p --json-schema` has two constraints the canonical schema file
# does not itself satisfy, both confirmed directly by live reproduction
# against the real installed CLI, not assumed from documentation:
#   1. A top-level `$schema` meta-reference key is rejected outright:
#      `Error: --json-schema is not a valid JSON Schema: no schema with key
#      or ref "https://json-schema.org/draft/2020-12/schema"`.
#   2. A top-level `allOf`/`oneOf`/`anyOf` is rejected by the underlying API
#      itself, independent of the CLI's own pre-validation:
#      `API Error: 400 tools.N.custom.input_schema: input_schema does not
#      support oneOf, allOf, or anyOf at the top level` -- this CLI's
#      structured-output mechanism cannot express the schema's own
#      cross-field if/then consistency rules (CLEAN requires empty findings,
#      etc.) at all, unlike Codex CLI's own --output-schema.
# The canonical schema FILE keeps both `$schema` and `allOf` unchanged --
# they are real, correct JSON Schema, used as-is by
# validate_ci_result.py's own `jsonschema`-package path (a general-purpose
# validator with no such restriction) and by anyone reading this repo's own
# schema as documentation. Only the COPY handed to this one CLI flag has
# both stripped, giving the model just the flat per-field types/enums --
# the cross-field consistency those two keys would have enforced is not
# lost, it is independently re-checked below by this script's own
# `VALIDATOR_JQ_FILE` regardless of what --json-schema itself could enforce
# (this was already true before this fix; it is what makes the flattened
# schema handed to the CLI a safe simplification rather than a weakening).
SCHEMA_TEXT="$(jq -c 'del(.["$schema"], .allOf)' "$SCHEMA_FILE")"
PROMPT_TEXT="$(build_ci_prompt)"

mktemp_registered CLAUDE_STDOUT_FILE
mktemp_registered CLAUDE_STDERR_FILE

# Run from inside the target checkout (matching how an interactive /ccs
# invocation would already be scoped to the repo it's reviewing) -- a
# subshell `cd`, never a bare `cd` that would change this script's own
# working directory for anything after it.
#
# --setting-sources user (a real, documented flag -- confirmed directly via
# `claude --help`) is REQUIRED here, not optional hardening: $REPO_ROOT is
# the PR's own, untrusted checkout. Without this flag, a PR could plant a
# project-level `.claude/settings.json` (hooks) or CLAUDE.md in its own
# checkout that this session would load and act on -- entirely independent
# of the diff-review content boundary /ccs itself already treats as
# untrusted data, and reachable even though `--dangerously-skip-permissions`
# is otherwise required for this headless invocation to run non-interactively
# at all. Restricting to `user` still loads the trusted tooling installed at
# `--scope user` (see ccs-ci-review.yml's own two-checkout split comment) --
# only the target checkout's own `project`/`local` settings are excluded.
# `--bare` was considered and rejected: its own `--help` text says it also
# skips plugin sync, which would prevent this session from ever loading the
# codex-stream-review:ccs skill in the first place.
(
  cd "$REPO_ROOT" || exit 127
  "$CLAUDE_BIN" -p --output-format json --dangerously-skip-permissions \
    --setting-sources user \
    --json-schema "$SCHEMA_TEXT" \
    -- "$PROMPT_TEXT"
) > "$CLAUDE_STDOUT_FILE" 2> "$CLAUDE_STDERR_FILE"
CLAUDE_STATUS=$?

RESULT_JSON=""

if [ "$CLAUDE_STATUS" -ne 0 ]; then
  STDERR_TAIL="$(tail -c 4000 "$CLAUDE_STDERR_FILE" 2>/dev/null)"
  RESULT_JSON="$(build_infrastructure_failure "claude -p exited with status $CLAUDE_STATUS" "$STDERR_TAIL")"
else
  # Tolerant parse of the CLI's own top-level JSON envelope -- `claude -p
  # --output-format json` emits exactly one JSON object on stdout, but this
  # never trusts that blindly: any parse failure here is itself
  # INFRASTRUCTURE_FAILURE, not a crash of this script.
  if ! jq -e 'type == "object"' "$CLAUDE_STDOUT_FILE" >/dev/null 2>&1; then
    RESULT_JSON="$(build_infrastructure_failure "claude -p stdout was not a single JSON object" "$(head -c 2000 "$CLAUDE_STDOUT_FILE" 2>/dev/null)")"
  elif ! jq -e '(.is_error == false) and (.subtype == "success")' "$CLAUDE_STDOUT_FILE" >/dev/null 2>&1; then
    ENVELOPE_SUMMARY="$(jq -c '{is_error, subtype}' "$CLAUDE_STDOUT_FILE" 2>/dev/null)"
    RESULT_JSON="$(build_infrastructure_failure "claude -p reported a non-success envelope" "$ENVELOPE_SUMMARY")"
  elif ! jq -e '.structured_output != null' "$CLAUDE_STDOUT_FILE" >/dev/null 2>&1; then
    RESULT_JSON="$(build_infrastructure_failure "claude -p succeeded but returned no structured_output" "")"
  else
    STRUCTURED_OUTPUT="$(jq -c '.structured_output' "$CLAUDE_STDOUT_FILE")"
    # Structural re-validation of structured_output, independent of whatever
    # --json-schema already enforced on the model's side -- this project's
    # standing discipline of never trusting a single enforcement point (see
    # git_safe()'s own layered checks for the same philosophy). A full
    # generic JSON-Schema evaluator is not worth building in jq for one
    # fixed schema; this mirrors the schema's own six exit_state branches
    # explicitly instead.
    mktemp_registered VALIDATOR_JQ_FILE
    cat > "$VALIDATOR_JQ_FILE" <<'JQ_EOF'
def exp_code: {"CLEAN":0,"CONFIRMED_ISSUES":1,"NOT_CONVERGED":2,"COULD_NOT_VERIFY":3,"PARTIAL_COVERAGE":4,"INFRASTRUCTURE_FAILURE":5};
def exp_verdict: {"CLEAN":"CLEAN","CONFIRMED_ISSUES":"ISSUES","NOT_CONVERGED":"ISSUES","COULD_NOT_VERIFY":"UNAVAILABLE","PARTIAL_COVERAGE":"ISSUES","INFRASTRUCTURE_FAILURE":"UNAVAILABLE"};
# is_int: a JSON number with no fractional part -- jq's own number/boolean
# types are already distinct (unlike Python's bool-is-an-int-subclass trap),
# but a float where an integer is required (e.g. pr_number: 1.5) must still
# be rejected explicitly.
def is_int: (type == "number") and (. == floor);
def valid_finding_item:
  (type == "object")
  and ((keys_unsorted | sort) == ["disposition","evidence","file","line","severity","summary","verification"])
  and (.file | type == "string")
  and ((.line == null) or ((.line | is_int) and (.line >= 1)))
  and ((.severity == null) or ([.severity] | inside(["low","medium","high"])))
  and (.summary | type == "string")
  and (.evidence | type == "string")
  and (.verification | type == "string")
  and ([.disposition] | inside(["open","resolved","retracted"]));
def valid_omitted_item:
  (type == "object")
  and ((keys_unsorted | sort) == ["path","reason"])
  and (.path | type == "string")
  and (.reason | type == "string");
# valid_coverage: the top-level `coverage` property schema, applied whenever
# the key is present regardless of exit_state -- null is only legal because
# COULD_NOT_VERIFY's own branch has no override forcing coverage non-null.
def valid_coverage:
  . as $c
  | ($c == null) or (
      ($c | type) == "object"
      and (($c | keys_unsorted | sort) == ["omitted","reviewed_file_count","status"])
      and ([$c.status] | inside(["complete","partial","unknown"]))
      and ($c.reviewed_file_count | is_int) and ($c.reviewed_file_count >= 0)
      and (($c.omitted | type) == "array")
      and ($c.omitted | map(valid_omitted_item) | all)
    );
def valid_infra:
  . as $i
  | (type == "object")
  and (($i | keys_unsorted | sort) == ["detail","message"])
  and ($i.message | type == "string")
  and (($i.detail == null) or ($i.detail | type == "string"));
# valid_input_errors: this field is always null now -- the only outcome that
# ever populated it (a self-imposed pre-dispatch prompt byte-size guard) was
# removed. Kept as a function (rather than inlined) purely to match this
# validator's existing per-field style.
def valid_input_errors: . == null;
. as $doc
| ($doc | keys_unsorted | sort) as $keys
| ($doc.exit_state) as $st
| (exp_code[$st]) as $ec
| (exp_verdict[$st]) as $ev
| ($keys == ["coverage","exit_code","exit_state","findings","head_sha","infrastructure_error","input_errors","pr_number","verdict","workflow_run_id"])
  and ($ec != null) and ($ev != null)
  and ($doc.exit_code | is_int) and ($doc.exit_code == $ec)
  and ($doc.verdict == $ev)
  and ($doc.workflow_run_id | type == "string") and ($doc.workflow_run_id | length > 0) and ($doc.workflow_run_id == $wrid)
  and ($doc.head_sha | type == "string") and ($doc.head_sha | test("^[0-9a-f]{40}$")) and ($doc.head_sha == $sha)
  and ($doc.pr_number | is_int) and ($doc.pr_number >= 1) and ($doc.pr_number == $prn)
  and ($doc.coverage | valid_coverage)
  and (($doc.findings == null) or (($doc.findings | type) == "array" and ($doc.findings | map(valid_finding_item) | all)))
  and ($doc.input_errors | valid_input_errors)
  and (
    if $st == "CLEAN" then
      ($doc.findings == []) and ($doc.coverage != null) and ($doc.coverage.status == "complete") and ($doc.coverage.omitted == []) and ($doc.infrastructure_error == null) and ($doc.input_errors == null)
    elif ($st == "CONFIRMED_ISSUES") or ($st == "NOT_CONVERGED") then
      (($doc.findings | type) == "array") and (($doc.findings | length) >= 1) and ($doc.coverage != null) and ($doc.infrastructure_error == null) and ($doc.input_errors == null)
    elif $st == "COULD_NOT_VERIFY" then
      ($doc.findings == null) and ($doc.infrastructure_error == null) and ($doc.input_errors == null)
    elif $st == "PARTIAL_COVERAGE" then
      ($doc.findings == []) and ($doc.coverage != null) and (($doc.coverage.status == "partial") or ($doc.coverage.status == "unknown")) and ($doc.infrastructure_error == null) and ($doc.input_errors == null)
    elif $st == "INFRASTRUCTURE_FAILURE" then
      ($doc.findings == null) and ($doc.coverage == null) and (($doc.infrastructure_error | type) == "object") and ($doc.infrastructure_error | valid_infra) and ($doc.input_errors == null)
    else false
    end
  )
JQ_EOF
    if printf '%s' "$STRUCTURED_OUTPUT" | jq -e \
        --arg wrid "$WORKFLOW_RUN_ID" --arg sha "$HEAD_SHA" --argjson prn "$PR_NUMBER" \
        -f "$VALIDATOR_JQ_FILE" >/dev/null 2>&1; then
      RESULT_JSON="$STRUCTURED_OUTPUT"
    else
      RESULT_JSON="$(build_infrastructure_failure "structured_output failed schema/provenance validation" "$STRUCTURED_OUTPUT")"
    fi
  fi
fi

write_result_atomic "$RESULT_JSON"

EXIT_CODE="$(printf '%s' "$RESULT_JSON" | jq -r '.exit_code')"
case "$EXIT_CODE" in
  0|1|2|3|4|5) exit "$EXIT_CODE" ;;
  *) exit 5 ;;
esac

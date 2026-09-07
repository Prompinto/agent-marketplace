# Structural validator for schemas/interactive-result.schema.json.
# Not a generic JSON-Schema engine -- a targeted check hardcoded to this one
# schema's required fields, enums, and allOf/if/then conditionals, matching
# the file at codex-stream-review/schemas/interactive-result.schema.json.
# If that schema changes, update this filter to match in the same change.
#
# Usage: jq -f schema-check.jq <result.json>  -- prints one violation per
# line to stdout; exit code is 0 if no violations, 1 otherwise (enforced by
# the caller checking output emptiness, since jq itself can't set exit code
# from a --exit-status this loosely without also failing on "input was
# false", so check-result.sh handles the exit code itself).

def has_all(ks): . as $o | (ks | map(. as $k | $o | has($k)) | all);

def base_violations:
  [
    (if (has_all(["session_id","target","exit_state","round_count","threads","claims","coverage","input_errors"]) | not)
      then "missing one or more top-level required fields" else empty end),
    (if (.session_id | type) != "string" or (.session_id | length) < 1
      then "session_id must be a non-empty string" else empty end),
    (if (.target | type) != "object" or (.target | has_all(["repo","scope"]) | not)
      then "target must be an object with repo/scope" else empty end),
    (if (.target.scope as $s | ["uncommitted","base","commit"] | index($s)) == null
      then "target.scope must be one of uncommitted|base|commit" else empty end),
    (if (.exit_state as $e | ["CLEAN","NOT_CONVERGED","COULD_NOT_VERIFY","PARTIAL_COVERAGE","MINOR_ISSUES_ACKNOWLEDGED","SNAPSHOT_INTEGRITY_FAILURE","REVIEW_LOG_INTEGRITY_FAILURE","INPUT_TOO_LARGE"] | index($e)) == null
      then "exit_state must be one of the 8 documented values" else empty end),
    (if (.round_count | type) != "number" or .round_count < 0
      then "round_count must be a non-negative integer" else empty end),
    (if (.threads | type) != "array"
      then "threads must be an array" else empty end)
  ];

def thread_violations:
  [.threads[]? |
    (if (has_all(["group","thread_id","kind","cleanup"]) | not)
      then "threads[]: missing group/thread_id/kind/cleanup" else empty end),
    (if (.kind as $k | ["current","leaked"] | index($k)) == null
      then "threads[]: kind must be current|leaked, got \(.kind)" else empty end),
    (if (.cleanup as $c | ["deleted","failed","retained"] | index($c)) == null
      then "threads[]: cleanup must be deleted|failed|retained, got \(.cleanup)" else empty end)
  ];

def snapshot_or_reviewlog_conditional:
  if (.exit_state as $e | ["SNAPSHOT_INTEGRITY_FAILURE","REVIEW_LOG_INTEGRITY_FAILURE"] | index($e)) != null
  then
    [ (if .claims != null then "exit_state=\(.exit_state) requires claims:null" else empty end),
      (if .input_errors != null then "exit_state=\(.exit_state) requires input_errors:null" else empty end) ]
  else
    [ (if (.claims | type) != "array" then "exit_state=\(.exit_state) requires claims to be an array (not null)" else empty end) ]
  end;

def input_too_large_conditional:
  if .exit_state == "INPUT_TOO_LARGE"
  then
    [ (if (.input_errors | type) != "array" or (.input_errors | length) < 1
        then "exit_state=INPUT_TOO_LARGE requires a non-empty input_errors array" else empty end) ]
  else
    [ (if .input_errors != null then "exit_state != INPUT_TOO_LARGE requires input_errors:null" else empty end) ]
  end;

def coverage_conditional:
  if .target.scope == "uncommitted"
  then
    [ (if (.coverage | type) != "object" then "target.scope=uncommitted requires coverage to be an object" else empty end) ]
  elif (.target.scope as $s | ["base","commit"] | index($s)) != null
  then
    [ (if .coverage != null then "target.scope=\(.target.scope) requires coverage:null" else empty end) ]
  else []
  end;

(base_violations + thread_violations + snapshot_or_reviewlog_conditional + input_too_large_conditional + coverage_conditional)
| map(select(. != null and . != ""))
| .[]

#!/usr/bin/env python3
"""Validate a codex-stream-review:ccs interactive result JSON file
(<session-id>.result.json) against
schemas/interactive-result.schema.json before evals/check-result.sh trusts
any of its fields.

Prefers a real JSON Schema validator (the `jsonschema` package) when
available; falls back to an explicit, hand-written check of the same
required fields, enums, and allOf/if/then conditionals when it is not (e.g.
`pip install jsonschema` failed or is unavailable on the runner) -- never
silently skips validation either way. Mirrors the sibling
scripts/validate_ci_result.py's own fallback pattern for the CI result
schema.
"""
import argparse
import json
import sys

TOP_LEVEL_KEYS = {
    "session_id", "target", "exit_state", "round_count", "threads",
    "claims", "coverage", "input_errors",
}
TARGET_KEYS = {"repo", "scope"}
THREAD_KEYS = {"group", "thread_id", "kind", "cleanup"}
CLAIM_KEYS = {
    "claim_id", "file", "line", "severity", "summary", "evidence",
    "disposition", "source_round", "marker_reason",
}
COVERAGE_KEYS = {"status", "reviewed_file_count", "omitted"}
OMITTED_KEYS = {"path", "reason"}

EXIT_STATES = {
    "CLEAN", "NOT_CONVERGED", "COULD_NOT_VERIFY", "PARTIAL_COVERAGE",
    "MINOR_ISSUES_ACKNOWLEDGED", "SNAPSHOT_INTEGRITY_FAILURE",
    "REVIEW_LOG_INTEGRITY_FAILURE",
}
INTEGRITY_FAILURE_STATES = {"SNAPSHOT_INTEGRITY_FAILURE", "REVIEW_LOG_INTEGRITY_FAILURE"}


def _is_int(v):
    """JSON Schema's `integer` type, which is satisfied by ANY JSON number with
    a zero fractional part (e.g. 1.0), not just a JSON-encoded whole-number
    literal -- so a Python float must be accepted here when v.is_integer() is
    true. float.is_integer() already correctly returns False for nan/inf, so
    those still fail as they must. Still never a JSON boolean (Python's bool
    is an int subclass, so isinstance(True, int) is True -- a naive check
    would silently accept a `true`/`false` value wherever an integer is
    required). Mirrors the sibling scripts/validate_ci_result.py's own
    _is_int()."""
    if isinstance(v, bool):
        return False
    if isinstance(v, int):
        return True
    return isinstance(v, float) and v.is_integer()


def _valid_target(target):
    if not isinstance(target, dict) or set(target.keys()) != TARGET_KEYS:
        return False
    if not isinstance(target.get("repo"), str):
        return False
    return target.get("scope") in ("uncommitted", "base", "commit")


def _valid_thread(item):
    if not isinstance(item, dict) or set(item.keys()) != THREAD_KEYS:
        return False
    if not isinstance(item.get("group"), str):
        return False
    thread_id = item.get("thread_id")
    if not isinstance(thread_id, str) or len(thread_id) < 1:
        return False
    if item.get("kind") not in ("current", "leaked"):
        return False
    return item.get("cleanup") in ("deleted", "failed", "retained")


def _valid_omitted_item(item):
    return (
        isinstance(item, dict)
        and set(item.keys()) == OMITTED_KEYS
        and isinstance(item.get("path"), str)
        and isinstance(item.get("reason"), str)
    )


def _valid_claim(item):
    if not isinstance(item, dict) or set(item.keys()) != CLAIM_KEYS:
        return False
    claim_id = item.get("claim_id")
    if not isinstance(claim_id, str) or len(claim_id) < 1:
        return False
    if not isinstance(item.get("file"), str):
        return False
    line = item.get("line")
    if not (line is None or (_is_int(line) and line >= 1)):
        return False
    if item.get("severity") not in ("low", "medium", "high", None):
        return False
    for key in ("summary", "evidence"):
        if not isinstance(item.get(key), str):
            return False
    if item.get("disposition") not in ("open", "resolved", "retracted"):
        return False
    source_round = item.get("source_round")
    if not (source_round is None or (_is_int(source_round) and source_round >= 1)):
        return False
    marker_reason = item.get("marker_reason")
    return marker_reason is None or isinstance(marker_reason, str)


def _valid_coverage(coverage):
    """coverage may be null at the bare property level -- the allOf
    conditionals (scope==uncommitted requires object, scope in
    {base,commit} requires null) are enforced separately in
    explicit_validate(), since they depend on target.scope."""
    if coverage is None:
        return True
    if not isinstance(coverage, dict) or set(coverage.keys()) != COVERAGE_KEYS:
        return False
    if coverage.get("status") not in ("complete", "partial", "unknown"):
        return False
    rfc = coverage.get("reviewed_file_count")
    if not (_is_int(rfc) and rfc >= 0):
        return False
    omitted = coverage.get("omitted")
    return isinstance(omitted, list) and all(_valid_omitted_item(o) for o in omitted)


def explicit_validate(doc):
    """Mirrors interactive-result.schema.json's required fields, enums, and
    4 allOf/if/then branches by hand, including the constraints inherited
    from the top-level and nested `additionalProperties: false` -- not just
    each branch's own type/const overrides.
    Returns (ok: bool, reason: str)."""
    if not isinstance(doc, dict):
        return False, "result is not a JSON object"

    for key in TOP_LEVEL_KEYS:
        if key not in doc:
            return False, f"missing required top-level field: {key}"
    extra = set(doc.keys()) - TOP_LEVEL_KEYS
    if extra:
        return False, f"unexpected top-level field(s): {sorted(extra)}"

    session_id = doc.get("session_id")
    if not isinstance(session_id, str) or len(session_id) < 1:
        return False, "session_id must be a non-empty string"

    target = doc.get("target")
    if not _valid_target(target):
        return False, "target must be an object with {repo: string, scope: uncommitted|base|commit}, no extra keys"

    exit_state = doc.get("exit_state")
    if exit_state not in EXIT_STATES:
        return False, f"unknown exit_state: {exit_state!r}"

    round_count = doc.get("round_count")
    if not (_is_int(round_count) and round_count >= 0):
        return False, "round_count must be a non-negative integer"

    threads = doc.get("threads")
    if not isinstance(threads, list) or not all(_valid_thread(t) for t in threads):
        return False, "threads must be an array of valid {group, thread_id, kind, cleanup} objects"

    claims = doc.get("claims")
    if claims is not None:
        if not isinstance(claims, list) or not all(_valid_claim(c) for c in claims):
            return False, "claims must be null or an array of valid claim objects"

    if not _valid_coverage(doc.get("coverage")):
        return False, "coverage must be null or a full {status, reviewed_file_count, omitted} object"

    if doc.get("input_errors") is not None:
        return False, "input_errors must always be null"

    if exit_state in INTEGRITY_FAILURE_STATES:
        if claims is not None:
            return False, f"exit_state={exit_state} requires claims to be null"
    else:
        if not isinstance(claims, list):
            return False, f"exit_state={exit_state} requires claims to be an array (not null)"

    scope = target.get("scope")
    coverage = doc.get("coverage")
    if scope == "uncommitted":
        if not isinstance(coverage, dict):
            return False, "target.scope=uncommitted requires coverage to be an object"
    elif scope in ("base", "commit"):
        if coverage is not None:
            return False, f"target.scope={scope} requires coverage to be null"

    return True, "ok"


def validate(schema_path, doc):
    """Returns (ok: bool, reason: str). Tries the real jsonschema package
    first; falls back to explicit_validate() if it is not importable."""
    try:
        import jsonschema
    except ImportError:
        ok, reason = explicit_validate(doc)
        mode = "explicit fallback checks -- jsonschema package unavailable"
        return ok, f"{reason} ({mode})" if not ok else f"ok ({mode})"

    with open(schema_path) as f:
        schema = json.load(f)
    try:
        jsonschema.Draft202012Validator(schema).validate(doc)
        return True, "ok (jsonschema)"
    except jsonschema.exceptions.ValidationError as e:
        return False, f"{e.message} ({'/'.join(str(p) for p in e.path)}) (jsonschema)"


def _selftest():
    base = {
        "session_id": "s1",
        "target": {"repo": "/tmp/r", "scope": "uncommitted"},
        "exit_state": "CLEAN",
        "round_count": 1,
        "threads": [{"group": "main", "thread_id": "t1", "kind": "current", "cleanup": "deleted"}],
        "claims": [],
        "coverage": {"status": "complete", "reviewed_file_count": 1, "omitted": []},
        "input_errors": None,
    }
    one_claim = {
        "claim_id": "c1", "file": "a.py", "line": 1, "severity": "high",
        "summary": "x", "evidence": "y", "disposition": "open",
        "source_round": 1, "marker_reason": None,
    }

    cases = [
        (True, dict(base)),
        (True, {**base, "claims": [one_claim]}),
        # extra top-level field
        (False, {**base, "unexpected": 1}),
        # fractional round_count
        (False, {**base, "round_count": 1.5}),
        # empty thread_id
        (False, {**base, "threads": [{"group": "main", "thread_id": "", "kind": "current", "cleanup": "deleted"}]}),
        # claim item missing a required field (marker_reason)
        (False, {**base, "claims": [{k: v for k, v in one_claim.items() if k != "marker_reason"}]}),
        # wrong allOf branch: SNAPSHOT_INTEGRITY_FAILURE requires claims:null
        (False, {**base, "exit_state": "SNAPSHOT_INTEGRITY_FAILURE", "claims": []}),
        (True, {**base, "exit_state": "SNAPSHOT_INTEGRITY_FAILURE", "claims": None}),
        # wrong allOf branch: a non-integrity exit_state requires claims to be an array, not null
        (False, {**base, "claims": None}),
        # wrong allOf branch: scope=uncommitted requires coverage to be an object
        (False, {**base, "coverage": None}),
        # wrong allOf branch: scope in {base, commit} requires coverage:null
        (False, {**base, "target": {"repo": "/tmp/r", "scope": "base"}, "coverage": {"status": "complete", "reviewed_file_count": 1, "omitted": []}}),
        (True, {**base, "target": {"repo": "/tmp/r", "scope": "base"}, "coverage": None}),
        # _is_int() integer-boundary cases (a whole-valued float IS a valid
        # JSON Schema integer; bool/nan/inf are still never valid)
        (True, {**base, "round_count": 1.0}),
        (False, {**base, "round_count": True}),
        (False, {**base, "round_count": float("nan")}),
        (False, {**base, "round_count": float("inf")}),
    ]

    failures = 0
    for expect_ok, doc in cases:
        ok, reason = explicit_validate(doc)
        if ok != expect_ok:
            failures += 1
            print(f"validate_interactive_result.py: selftest case FAILED (expected ok={expect_ok}, got ok={ok}: {reason})", file=sys.stderr)
    if failures:
        print(f"validate_interactive_result.py: selftest FAILED ({failures} case(s))", file=sys.stderr)
        sys.exit(1)
    print("validate_interactive_result.py: selftest OK")
    sys.exit(0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schema", nargs="?", help="path to interactive-result.schema.json")
    parser.add_argument("result", nargs="?", help="path to the <session-id>.result.json file to validate")
    parser.add_argument("--selftest", action="store_true", help="run internal checks against fixed sample payloads and exit")
    args = parser.parse_args()

    if args.selftest:
        _selftest()
        return

    if not args.schema or not args.result:
        parser.error("schema and result paths are required unless --selftest is given")

    try:
        with open(args.result) as f:
            doc = json.load(f)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        print(f"INVALID: malformed JSON: {exc}", file=sys.stderr)
        sys.exit(1)
    ok, reason = validate(args.schema, doc)
    if ok:
        print(f"VALID: {reason}")
        sys.exit(0)
    print(f"INVALID: {reason}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()

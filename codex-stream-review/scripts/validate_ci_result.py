#!/usr/bin/env python3
"""Validate a codex-stream-review CI result JSON file against
schemas/ci-result.schema.json before any of its fields are trusted.

Used by .github/workflows/ccs-ci-report.yml (the trusted reporting job)
before rendering any field from a downloaded .ccs-ci-result.json artifact
into a PR comment -- per the negotiated design in
docs/2026-09-05-codex-stream-review-improvement-roadmap-design.md ("Phase 4"
-> Item 2 -> "CI result contract"), that job must schema-validate the
payload BEFORE using any of its fields, never after.

Prefers a real JSON Schema validator (the `jsonschema` package) when
available; falls back to an explicit, hand-written check of the same six
exit_state branches when it is not (e.g. `pip install jsonschema` failed or
is unavailable on the runner) -- never silently skips validation either way.
"""
import argparse
import json
import sys

EXPECTED_EXIT_CODE = {
    "CLEAN": 0,
    "CONFIRMED_ISSUES": 1,
    "NOT_CONVERGED": 2,
    "COULD_NOT_VERIFY": 3,
    "PARTIAL_COVERAGE": 4,
    "INFRASTRUCTURE_FAILURE": 5,
}
EXPECTED_VERDICT = {
    "CLEAN": "CLEAN",
    "CONFIRMED_ISSUES": "ISSUES",
    "NOT_CONVERGED": "ISSUES",
    "COULD_NOT_VERIFY": "UNAVAILABLE",
    "PARTIAL_COVERAGE": "ISSUES",
    "INFRASTRUCTURE_FAILURE": "UNAVAILABLE",
}


TOP_LEVEL_KEYS = {
    "exit_state", "exit_code", "verdict", "findings", "coverage",
    "infrastructure_error", "workflow_run_id", "head_sha", "pr_number",
}
FINDING_KEYS = {"file", "line", "severity", "summary", "evidence", "verification", "disposition"}
OMITTED_KEYS = {"path", "reason"}
COVERAGE_KEYS = {"status", "reviewed_file_count", "omitted"}
INFRA_KEYS = {"message", "detail"}


def _is_int(v):
    """JSON integer, never a JSON boolean (Python's bool is an int subclass,
    so isinstance(True, int) is True -- a naive check would silently accept
    a `true`/`false` value wherever an integer is required)."""
    return isinstance(v, int) and not isinstance(v, bool)


def _valid_finding_item(item):
    if not isinstance(item, dict) or set(item.keys()) != FINDING_KEYS:
        return False
    if not isinstance(item.get("file"), str):
        return False
    line = item.get("line")
    if not (line is None or (_is_int(line) and line >= 1)):
        return False
    severity = item.get("severity")
    if severity not in ("low", "medium", "high", None):
        return False
    for key in ("summary", "evidence", "verification"):
        if not isinstance(item.get(key), str):
            return False
    return item.get("disposition") in ("open", "resolved", "retracted")


def _valid_omitted_item(item):
    return (
        isinstance(item, dict)
        and set(item.keys()) == OMITTED_KEYS
        and isinstance(item.get("path"), str)
        and isinstance(item.get("reason"), str)
    )


def _valid_coverage(coverage):
    """coverage may be null (COULD_NOT_VERIFY's own branch has no override
    forcing it non-null); when present it must be a full, valid object --
    this is the top-level `coverage` property schema, which applies whenever
    the key is present regardless of exit_state."""
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


def _valid_infra(infra):
    if not isinstance(infra, dict) or set(infra.keys()) != INFRA_KEYS:
        return False
    if not isinstance(infra.get("message"), str):
        return False
    detail = infra.get("detail")
    return detail is None or isinstance(detail, str)


def explicit_validate(doc):
    """Mirrors ci-result.schema.json's six allOf/if/then branches by hand,
    including the constraints those branches inherit from the top-level
    `properties`/`additionalProperties: false` (coverage/findings/
    infrastructure_error item shapes, the exact top-level key set, integer
    vs. boolean distinctions, etc.) -- not just each branch's own
    const/type/minItems overrides.
    Returns (ok: bool, reason: str)."""
    if not isinstance(doc, dict):
        return False, "result is not a JSON object"

    for key in ("exit_state", "exit_code", "verdict", "workflow_run_id", "head_sha", "pr_number",
                "findings", "coverage", "infrastructure_error"):
        if key not in doc:
            return False, f"missing required top-level field: {key}"
    extra = set(doc.keys()) - TOP_LEVEL_KEYS
    if extra:
        return False, f"unexpected top-level field(s): {sorted(extra)}"

    st = doc.get("exit_state")
    if st not in EXPECTED_EXIT_CODE:
        return False, f"unknown exit_state: {st!r}"
    if not _is_int(doc.get("exit_code")) or doc.get("exit_code") != EXPECTED_EXIT_CODE[st]:
        return False, f"exit_code {doc.get('exit_code')!r} does not match exit_state {st}"
    if doc.get("verdict") != EXPECTED_VERDICT[st]:
        return False, f"verdict {doc.get('verdict')!r} does not match exit_state {st}"

    findings = doc.get("findings")
    coverage = doc.get("coverage")
    infra = doc.get("infrastructure_error")

    if not _valid_coverage(coverage):
        return False, "coverage does not match the required {status, reviewed_file_count, omitted} shape"
    if findings is not None:
        if not isinstance(findings, list) or not all(_valid_finding_item(f) for f in findings):
            return False, "findings must be null or an array of valid finding objects"

    if st == "CLEAN":
        if findings != []:
            return False, "CLEAN requires an empty findings array"
        if coverage is None or coverage.get("status") != "complete" or coverage.get("omitted") != []:
            return False, "CLEAN requires coverage.status == complete with zero omissions"
        if infra is not None:
            return False, "CLEAN requires infrastructure_error == null"
    elif st in ("CONFIRMED_ISSUES", "NOT_CONVERGED"):
        if not isinstance(findings, list) or len(findings) < 1:
            return False, f"{st} requires at least one finding"
        if coverage is None:
            return False, f"{st} requires a non-null coverage object"
        if infra is not None:
            return False, f"{st} requires infrastructure_error == null"
    elif st == "COULD_NOT_VERIFY":
        if findings is not None:
            return False, "COULD_NOT_VERIFY requires findings == null"
        if infra is not None:
            return False, "COULD_NOT_VERIFY requires infrastructure_error == null"
    elif st == "PARTIAL_COVERAGE":
        if findings != []:
            return False, "PARTIAL_COVERAGE requires an empty findings array (a real finding means CONFIRMED_ISSUES instead)"
        if coverage is None or coverage.get("status") not in ("partial", "unknown"):
            return False, "PARTIAL_COVERAGE requires coverage.status in {partial, unknown}"
        if infra is not None:
            return False, "PARTIAL_COVERAGE requires infrastructure_error == null"
    elif st == "INFRASTRUCTURE_FAILURE":
        if findings is not None:
            return False, "INFRASTRUCTURE_FAILURE requires findings == null"
        if coverage is not None:
            return False, "INFRASTRUCTURE_FAILURE requires coverage == null"
        if not _valid_infra(infra):
            return False, "INFRASTRUCTURE_FAILURE requires a valid {message, detail} infrastructure_error object"

    if not isinstance(doc.get("workflow_run_id"), str) or not doc["workflow_run_id"]:
        return False, "workflow_run_id must be a non-empty string"
    head_sha = doc.get("head_sha")
    if not isinstance(head_sha, str) or len(head_sha) != 40 or any(c not in "0123456789abcdef" for c in head_sha):
        return False, "head_sha must be exactly 40 lowercase hex characters"
    pr_number = doc.get("pr_number")
    if not _is_int(pr_number) or pr_number < 1:
        return False, "pr_number must be a positive integer"

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
    base = {"workflow_run_id": "1", "head_sha": "a" * 40, "pr_number": 1}
    cases = [
        (True, {**base, "exit_state": "CLEAN", "exit_code": 0, "verdict": "CLEAN",
                "findings": [], "coverage": {"status": "complete", "reviewed_file_count": 1, "omitted": []},
                "infrastructure_error": None}),
        (False, {**base, "exit_state": "CLEAN", "exit_code": 0, "verdict": "CLEAN",
                 "findings": [{"file": "a", "line": 1, "severity": "low", "summary": "x", "evidence": "y",
                               "verification": "z", "disposition": "open"}],
                 "coverage": {"status": "complete", "reviewed_file_count": 1, "omitted": []},
                 "infrastructure_error": None}),
        (True, {**base, "exit_state": "CONFIRMED_ISSUES", "exit_code": 1, "verdict": "ISSUES",
                "findings": [{"file": "a", "line": 1, "severity": "high", "summary": "x", "evidence": "y",
                              "verification": "z", "disposition": "open"}],
                "coverage": {"status": "complete", "reviewed_file_count": 1, "omitted": []},
                "infrastructure_error": None}),
        (False, {**base, "exit_state": "CONFIRMED_ISSUES", "exit_code": 1, "verdict": "ISSUES",
                 "findings": [], "coverage": {"status": "complete", "reviewed_file_count": 1, "omitted": []},
                 "infrastructure_error": None}),
        (True, {**base, "exit_state": "COULD_NOT_VERIFY", "exit_code": 3, "verdict": "UNAVAILABLE",
                "findings": None, "coverage": {"status": "unknown", "reviewed_file_count": 0, "omitted": []},
                "infrastructure_error": None}),
        (True, {**base, "exit_state": "PARTIAL_COVERAGE", "exit_code": 4, "verdict": "ISSUES",
                "findings": [], "coverage": {"status": "partial", "reviewed_file_count": 1,
                                              "omitted": [{"path": "x", "reason": "binary"}]},
                "infrastructure_error": None}),
        (False, {**base, "exit_state": "PARTIAL_COVERAGE", "exit_code": 4, "verdict": "ISSUES",
                 "findings": [], "coverage": {"status": "complete", "reviewed_file_count": 1, "omitted": []},
                 "infrastructure_error": None}),
        (True, {**base, "exit_state": "INFRASTRUCTURE_FAILURE", "exit_code": 5, "verdict": "UNAVAILABLE",
                "findings": None, "coverage": None,
                "infrastructure_error": {"message": "m", "detail": None}}),
        (False, {**base, "exit_state": "INFRASTRUCTURE_FAILURE", "exit_code": 5, "verdict": "UNAVAILABLE",
                 "findings": None, "coverage": None, "infrastructure_error": None}),
    ]

    # Counterexamples live-reproduced by Codex against the pre-fix validator
    # (both the jq validator in run-ccs-ci.sh and this file's own
    # explicit_validate() previously accepted all three) -- kept here so this
    # exact gap class can never silently regress.
    could_not_verify_missing_coverage = {**base, "exit_state": "COULD_NOT_VERIFY", "exit_code": 3,
                                          "verdict": "UNAVAILABLE", "findings": None,
                                          "infrastructure_error": None}  # coverage key entirely absent, not even null
    cases.append((False, could_not_verify_missing_coverage))

    cases.append((False, {**base, "head_sha": "A" * 40, "exit_state": "COULD_NOT_VERIFY", "exit_code": 3,
                           "verdict": "UNAVAILABLE", "findings": None,
                           "coverage": {"status": "unknown", "reviewed_file_count": 0, "omitted": []},
                           "infrastructure_error": None}))  # uppercase head_sha -- pattern requires lowercase hex

    cases.append((False, {**base, "exit_state": "CONFIRMED_ISSUES", "exit_code": 1, "verdict": "ISSUES",
                           "findings": [1], "coverage": [],
                           "infrastructure_error": None}))  # findings item and coverage both wrong shape

    failures = 0
    for expect_ok, doc in cases:
        ok, reason = explicit_validate(doc)
        if ok != expect_ok:
            failures += 1
            print(f"validate_ci_result.py: selftest case FAILED (expected ok={expect_ok}, got ok={ok}: {reason})", file=sys.stderr)
    if failures:
        print(f"validate_ci_result.py: selftest FAILED ({failures} case(s))", file=sys.stderr)
        sys.exit(1)
    print("validate_ci_result.py: selftest OK")
    sys.exit(0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schema", nargs="?", help="path to ci-result.schema.json")
    parser.add_argument("result", nargs="?", help="path to the .ccs-ci-result.json file to validate")
    parser.add_argument("--selftest", action="store_true", help="run internal checks against fixed sample payloads and exit")
    args = parser.parse_args()

    if args.selftest:
        _selftest()
        return

    if not args.schema or not args.result:
        parser.error("schema and result paths are required unless --selftest is given")

    with open(args.result) as f:
        doc = json.load(f)
    ok, reason = validate(args.schema, doc)
    if ok:
        print(f"VALID: {reason}")
        sys.exit(0)
    print(f"INVALID: {reason}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# auth-stub.sh -- discovery + validation for the opt-in auth-gate stub-injection
# config feature (see skills/verify/SKILL.md, "Auth-stub injection (opt-in)").
#
# Read-only: never writes anything, never executes anything from the loaded
# config. Every identifier pulled from a config file is checked against a
# strict grammar plus a prototype-pollution denylist before it is ever used
# to index an object or resolve a filesystem path.
set -u

usage() {
  cat >&2 <<'EOF'
Usage:
  auth-stub.sh validate <repo-root> [app-subdir]

Prints one JSON object on stdout:
  {"status":"absent"}                                   -- no candidate config file found
  {"path":"...", "status":"unreadable", "detail":"..."}
  {"path":"...", "status":"unsupported_schema_version", "detail":"..."}
  {"path":"...", "status":"unrecognized_profile", "detail":"..."}
  {"path":"...", "status":"invalid", "detail":"..."}
  {"path":"...", "status":"valid", "config":{...}}
EOF
}

MODE="${1:-}"
[ -n "$MODE" ] || { usage; exit 1; }
shift || true

CANDIDATE_PATH=""

fail() {
  # fail <status> <detail>
  jq -n --arg path "$CANDIDATE_PATH" --arg status "$1" --arg detail "$2" \
    '{path:$path, status:$status, detail:$detail}'
  exit 0
}

ok() {
  jq -n --arg path "$CANDIDATE_PATH" --argjson config "$1" \
    '{path:$path, status:"valid", config:$config}'
  exit 0
}

case "$MODE" in
  validate)
    REPO_ROOT="${1:-}"
    APP_SUBDIR="${2:-}"

    if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
      jq -n '{"status":"absent"}'
      exit 0
    fi
    REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
    INSTALL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    # Computed unconditionally (not only in the app-subdir branch below) --
    # every selected CANDIDATE_PATH is re-checked against this same resolved
    # root right before it is ever read, regardless of which candidate
    # (app-subdir or repo-root) produced it.
    REAL_REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"

    # --- discovery: ordered candidate list ---
    CANDIDATES=()
    if [ -n "$APP_SUBDIR" ] && [ "$APP_SUBDIR" != "." ] && [ -d "$REPO_ROOT/$APP_SUBDIR" ]; then
      # Confirm the resolved app dir is a genuine descendant of REPO_ROOT
      # before ever trusting a config found under it -- an app-subdir value
      # containing "../" (confirmed live: "../vv-subdir-external" resolves
      # outside REPO_ROOT while still passing the plain `-d` check above)
      # would otherwise let a config file OUTSIDE the actual target
      # repository be picked up and treated as that repo's own opt-in
      # config, violating the documented "repo-owner-authored, repo-local"
      # boundary this whole feature depends on.
      REAL_APP_DIR="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$REPO_ROOT/$APP_SUBDIR" 2>/dev/null)"
      case "$REAL_APP_DIR" in
        "$REAL_REPO_ROOT"/*)
          CANDIDATES+=("$REAL_APP_DIR/.claude/visual-verify.auth-stub.json")
          ;;
        *) : ;; # resolves outside REPO_ROOT (or realpath failed) -- never a candidate
      esac
    fi
    CANDIDATES+=("$REPO_ROOT/.claude/visual-verify.auth-stub.json")

    for c in "${CANDIDATES[@]}"; do
      # -L (is a symlink, even a dangling one) alongside -e (exists,
      # following symlinks): a dangling symlink at a higher-priority
      # candidate path is a real, notable thing found there -- it must stop
      # the walk with a diagnosed result (the -f/-r checks below correctly
      # reject it), never be silently treated as "missing" and fall through
      # to a lower-priority candidate (confirmed live: plain -e alone
      # returns false for a dangling symlink, since -e follows the link and
      # checks the TARGET's existence).
      if [ -e "$c" ] || [ -L "$c" ]; then
        CANDIDATE_PATH="$c"
        break
      fi
    done

    # Every candidate missing -> absent, no diagnostic (existing disclosure-only
    # heuristic applies exactly as today). Anything else found (even if it turns
    # out unreadable/invalid) STOPS the walk right there -- never silently falls
    # through to a lower-priority candidate.
    if [ -z "$CANDIDATE_PATH" ]; then
      jq -n '{"status":"absent"}'
      exit 0
    fi

    # Reject anything that isn't a REGULAR file before ever reading it -- `-e`
    # (existence) is true for a symlink/device/FIFO/directory too, and so is
    # `-r` (readable) for many of those. A symlink at this exact candidate
    # path pointing to a character device like /dev/zero passes both, but
    # `cat`-ing it never reaches EOF -- confirmed live: this hangs Phase 1's
    # supposedly fast, bounded, read-only detection indefinitely instead of
    # producing a diagnosed "invalid config" result. `-f` follows symlinks
    # but only succeeds when the ultimate target is a regular file, so this
    # is caught here, before the unbounded `cat` below, not after.
    if [ ! -f "$CANDIDATE_PATH" ]; then
      fail "unreadable" "config candidate exists but is not a regular file (a symlink to a device/pipe/directory?): $CANDIDATE_PATH"
    fi

    if [ ! -r "$CANDIDATE_PATH" ]; then
      fail "unreadable" "config file exists but is not readable: $CANDIDATE_PATH"
    fi

    # Same containment check already applied to the app-subdir DIRECTORY
    # above, now applied to the candidate FILE itself -- the app-subdir
    # check alone doesn't cover a config file that is ITSELF a symlink
    # pointing somewhere outside REPO_ROOT (confirmed live: a repo-root
    # `.claude/visual-verify.auth-stub.json` symlinked to an external valid
    # config file returned status "valid" despite the resolved target being
    # outside the repository entirely -- the `-f` check above only confirms
    # the ultimate target is a *regular file*, never that it stays local).
    REAL_CANDIDATE="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CANDIDATE_PATH" 2>/dev/null)"
    case "$REAL_CANDIDATE" in
      "$REAL_REPO_ROOT"/*) : ;;
      *) fail "unreadable" "config candidate resolves outside the target repository (a symlink escape?): $CANDIDATE_PATH" ;;
    esac

    # Strict-JSON gate BEFORE ever trusting jq's own (deliberately lenient)
    # parser: jq accepts non-standard tokens (NaN/Infinity/-Infinity,
    # silently converted to null) and, on a stream with valid JSON followed
    # by trailing garbage, prints the valid prefix and exits nonzero -- which
    # this script previously never checked (only "-z" on jq's stdout), so a
    # config like {"x":1}garbage-that-looks-like-more-json could pass here.
    # Python's json.loads is strict RFC 8259 and, with parse_constant wired
    # to reject NaN/Infinity/-Infinity outright, closes both gaps in one gate.
    #
    # Read $CANDIDATE_PATH DIRECTLY here (open(..., "rb") on the path itself)
    # -- never via a bash variable capture (the old `RAW="$(cat ...)"`) first.
    # Bash variables cannot hold embedded NUL bytes; `$(...)` command
    # substitution silently discards them during capture, so a bash-side
    # round-trip validates a NUL-STRIPPED copy of the file, never its true
    # byte content -- a config containing a raw NUL byte (invalid per RFC
    # 8259) would previously pass this gate with the NUL silently removed
    # from whatever value it was embedded in (e.g. `crea<NUL>te` silently
    # becoming `create`). Confirmed live: json.loads() genuinely rejects a
    # raw NUL byte embedded in a JSON string ("Invalid control character"),
    # so reading the true bytes directly is sufficient -- no separate
    # pre-scan for a literal NUL is needed on top of it.
    if ! python3 -c '
import json, sys
def reject_const(x):
    raise ValueError("non-standard JSON constant: " + x)
with open(sys.argv[1], "rb") as f:
    data = f.read()
json.loads(data.decode("utf-8"), parse_constant=reject_const)
' "$CANDIDATE_PATH" >/dev/null 2>&1; then
      fail "unreadable" "config file is not valid, strict JSON (RFC 8259 -- no trailing content, no NaN/Infinity/-Infinity, no embedded NUL bytes): $CANDIDATE_PATH"
    fi
    # Same reasoning as the gate above: read $CANDIDATE_PATH directly here too
    # -- never the bash-mangled $RAW variable this script used to pipe into
    # jq -- so every check for the REST of this script also operates on the
    # true file content, not a NUL-stripped copy of it.
    CONFIG_JSON="$(jq -c '.' "$CANDIDATE_PATH" 2>/dev/null)"
    if [ -z "$CONFIG_JSON" ]; then
      fail "unreadable" "config file is not valid JSON: $CANDIDATE_PATH"
    fi

    # Whole-document numeric-safety gate, reading $CANDIDATE_PATH FRESH here
    # too -- jq's OWN number reserialization is itself a lossy step for
    # sufficiently extreme literals, a genuinely separate problem from
    # anything Python's json.loads does on its own. Confirmed live: the
    # literal "1e-1147483647" (an extreme but syntactically valid exponent)
    # survives Python's own parse_float hook fine (the hook sees the true
    # text and correctly flags it), but `jq -c '.'` -- run on the SAME file
    # one step above, and again later per stub entry via `jq -c '.stub[$n]'`
    # / `jq -c '.value'` -- had ALREADY rewritten it to "0E-1147483646" by
    # the time any later stage could inspect it, i.e. jq itself silently
    # collapsed a genuinely nonzero literal to a text form that IS exactly
    # zero, before Python's own underflow detection (which relies on seeing
    # the true original text) ever got a chance to run on it. Fixing this
    # requires checking every number in the document against $CANDIDATE_PATH
    # itself, before ANY jq round-trip -- not fixable by hardening the
    # later, already-jq-touched checks alone, no matter how precise their
    # own arithmetic is, since jq has already destroyed the information they
    # would need. This walks the WHOLE document once (every number anywhere
    # in the config, not just inside `stub.*.value`) -- harmless, since no
    # other field in this schema legitimately holds a number at all (profile/
    # global_object_path/factory_method/stub keys/intercept fields are all
    # strings; permission_keys_by_route values are arrays of strings; the
    # only place a real JSON number can appear is nested inside a
    # `stub.<name>.value`) other than `$schema_version` itself, which is
    # separately validated to be exactly the integer 1 immediately below and
    # would never legitimately need an exotic literal in the first place.
    if ! python3 -c '
import json, sys, math
from decimal import Decimal, InvalidOperation

def _parse_float(s):
    f = float(s)
    if math.isinf(f):
        raise ValueError("number literal " + s + " overflows to infinity")
    if f == 0.0:
        # Negative zero is rejected outright, whether it was WRITTEN that way
        # ("-0.0", "-0.00", "-0e-324" all parse to the identical -0.0 float,
        # regardless of spelling) or arrived at by a negative value
        # underflowing all the way to zero (e.g. "-1e-400") -- both cases
        # share the same negative sign bit on the resulting float, so
        # checking copysign FIRST catches both uniformly with one message,
        # before the separate positive-underflow check below ever runs.
        # Confirmed live this was a real gap: a bare "-0.0" was incorrectly
        # ACCEPTED once the copysign check was (mistakenly) only kept in the
        # later per-stub structural check, which was then simplified away
        # once numeric safety moved entirely to this earlier gate -- without
        # this check here, nothing rejects it at all anymore.
        if math.copysign(1.0, f) < 0:
            raise ValueError("number literal " + s + " is negative zero")
        # A literal whose significand is itself all zero digits (e.g.
        # "0e-999999999999999999999999999999999999999999") denotes exact
        # zero for ANY exponent, however extreme -- 0 * 10**n == 0 for
        # every n, so there is no magnitude to underflow-check at all.
        # Detect this from the raw literal text before ever consulting
        # Decimal, since the Decimal parser has its own exponent range and
        # would otherwise reject this genuinely-safe, documented-valid
        # value for the same reason it must reject a truly ambiguous
        # nonzero one below.
        mantissa_digits = s.lstrip("+-").split("e")[0].split("E")[0].replace(".", "")
        if mantissa_digits != "" and mantissa_digits.strip("0") == "":
            return f
        try:
            d = Decimal(s)
        except InvalidOperation:
            # A syntactically valid JSON number can still exceed the
            # parseable range of Decimal itself (confirmed live: an
            # exponent with ~40 digits, e.g.
            # "1e-999999999999999999999999999999999999999999", raises
            # InvalidOperation here) -- fail CLOSED on this, not open. The
            # previous version caught this and silently passed, treating
            # "could not verify this value is safe" as if it meant "this
            # value is safe" -- it does not; if the underflow-vs-genuine-
            # zero question cannot be answered, reject.
            raise ValueError("number literal " + s + " could not be verified against underflow (exponent outside the parseable range of Decimal) -- rejected fail-closed")
        if d != 0:
            raise ValueError("number literal " + s + " underflows to zero")
    elif f.is_integer() and not (-9007199254740991 <= f <= 9007199254740991):
        # A whole number written WITH a decimal point or exponent (e.g.
        # "9007199254740993.0") is routed through this hook, not _parse_int
        # below (the JSON grammar itself sends anything with a "." or
        # "e"/"E" through parse_float regardless of whether the value
        # happens to be integral) -- confirmed live this was a real gap:
        # the MAX_SAFE_INTEGER bound in _parse_int never applied to this
        # spelling at all, and
        # "9007199254740993.0" rendered as a silently-different
        # "9007199254740992" once Node parsed and re-serialized it.
        raise ValueError("number literal " + s + " (a float-spelled whole number) exceeds Number.MAX_SAFE_INTEGER")
    return f

def _parse_int(s):
    n = int(s)
    if n == 0 and s.startswith("-"):
        raise ValueError("integer literal " + s + " is negative zero")
    if not (-9007199254740991 <= n <= 9007199254740991):
        raise ValueError("integer literal " + s + " exceeds Number.MAX_SAFE_INTEGER")
    return n

with open(sys.argv[1], "rb") as f:
    data = f.read()
json.loads(data.decode("utf-8"), parse_float=_parse_float, parse_int=_parse_int)
' "$CANDIDATE_PATH" >/dev/null 2>&1; then
      fail "invalid" "config contains a number that does not safely round-trip through a JS double (finite, not negative zero, not a nonzero magnitude that underflows to zero, and if a whole number, within Number.MAX_SAFE_INTEGER): $CANDIDATE_PATH"
    fi

    # --- layer 1: schema version ---
    SCHEMA_VERSION="$(printf '%s' "$CONFIG_JSON" | jq -c '.["$schema_version"] // null')"
    if [ "$SCHEMA_VERSION" != "1" ]; then
      fail "unsupported_schema_version" "\$schema_version must be exactly 1, found: $SCHEMA_VERSION"
    fi

    # --- layer 2: profile grammar + structural validation ---
    # Every identifier/profile-name safety check below runs ENTIRELY inside
    # jq, against the real (un-stringified) JSON value -- never via bash
    # command substitution followed by a bash `[[ =~ ]]` check. Two separate,
    # real bypasses were found and fixed for that bash-side pattern: (1) a
    # bash `while read` line-splitting loop mis-checking a value with an
    # EMBEDDED newline as multiple independently-valid fragments; (2) bash
    # `$(...)` command substitution unconditionally stripping ALL TRAILING
    # newlines before the value ever reaches a check, silently turning an
    # invalid "name\n" into an accepted "name". A jq-native check has neither
    # problem, PROVIDED the regex's end-anchor is `\z` (true end of string),
    # not jq/Oniguruma's `$` -- `$` also matches immediately before a single
    # trailing newline (confirmed live: `test("...$")` returned `true` for
    # "window\n"), so `\z` is required, not merely "run it in jq instead of
    # bash".
    PROFILE_TOP_TYPE="$(printf '%s' "$CONFIG_JSON" | jq -r '.profile? | type')"
    PROFILE_SAFE="$(printf '%s' "$CONFIG_JSON" | jq '(.profile? // "") | test("^[A-Za-z_$][A-Za-z0-9_$-]*\\z")')"
    if [ "$PROFILE_TOP_TYPE" != "string" ] || [ "$PROFILE_SAFE" != "true" ]; then
      fail "unrecognized_profile" "profile field missing, not a string, or contains invalid characters"
    fi
    PROFILE="$(printf '%s' "$CONFIG_JSON" | jq -r '.profile')"

    # `jq -r` alone would silently stringify a non-string JSON value (a bare
    # boolean/number element prints as "true"/"42", identical to what a real
    # string "true"/"42" would print) -- checking `type` first, on the
    # UN-stringified value, is what actually enforces "this must be a JSON
    # string", not merely "this must print as non-empty text".
    GOP_TOP_TYPE="$(printf '%s' "$CONFIG_JSON" | jq -r '.global_object_path? | type')"
    [ "$GOP_TOP_TYPE" = "array" ] || fail "invalid" "global_object_path must be an array, found type: $GOP_TOP_TYPE"
    GOP_LEN="$(printf '%s' "$CONFIG_JSON" | jq '.global_object_path | length')"
    if [ "$GOP_LEN" -lt 1 ]; then
      fail "invalid" "global_object_path must be a non-empty array of identifiers"
    fi
    GOP_ALL_STRINGS="$(printf '%s' "$CONFIG_JSON" | jq '.global_object_path | all(type == "string" and length > 0)')"
    [ "$GOP_ALL_STRINGS" = "true" ] || fail "invalid" "global_object_path must contain only non-empty string identifiers, never a bare number/boolean/null"
    # Identifier-grammar + denylist check runs ENTIRELY inside jq, on the real
    # JSON string values -- never via a bash `while read` line-splitting loop
    # over `jq -r` output. A single array element containing an embedded
    # newline (e.g. "window\nsdk") would otherwise print as TWO separate
    # lines, each independently well-formed, silently hiding the fact that
    # the original single value never matched the identifier grammar as a
    # whole (confirmed live: this exact input made the old line-oriented
    # check accept it, while the renderer preserves the original one-element
    # value and the injected code ends up indexing by the literal
    # "window\nsdk" property name instead of the two-level traversal the
    # validation appeared to confirm).
    GOP_ALL_SAFE="$(printf '%s' "$CONFIG_JSON" | jq '
      def is_safe_ident: test("^[A-Za-z_$][A-Za-z0-9_$]*\\z") and (. != "__proto__" and . != "constructor" and . != "prototype" and . != "__visualVerifyPermissionKeyMatch");
      .global_object_path | all(is_safe_ident)
    ')"
    [ "$GOP_ALL_SAFE" = "true" ] || fail "invalid" "global_object_path contains an identifier that is invalid or denylisted (__proto__/constructor/prototype/__visualVerifyPermissionKeyMatch)"

    FACTORY_TYPE="$(printf '%s' "$CONFIG_JSON" | jq -r '.factory_method? | type')"
    [ "$FACTORY_TYPE" = "string" ] || fail "invalid" "factory_method must be a string, found type: $FACTORY_TYPE"
    FACTORY_SAFE="$(printf '%s' "$CONFIG_JSON" | jq '
      def is_safe_ident: test("^[A-Za-z_$][A-Za-z0-9_$]*\\z") and (. != "__proto__" and . != "constructor" and . != "prototype" and . != "__visualVerifyPermissionKeyMatch");
      .factory_method | is_safe_ident
    ')"
    [ "$FACTORY_SAFE" = "true" ] || fail "invalid" "factory_method is not a valid identifier, or is denylisted (__proto__/constructor/prototype/__visualVerifyPermissionKeyMatch)"

    INTERCEPT_URL_TYPE="$(printf '%s' "$CONFIG_JSON" | jq -r '.intercept.url_pattern? | type')"
    INTERCEPT_CT_TYPE="$(printf '%s' "$CONFIG_JSON" | jq -r '.intercept.content_type? | type')"
    [ "$INTERCEPT_URL_TYPE" = "string" ] || fail "invalid" "intercept.url_pattern must be a string, found type: $INTERCEPT_URL_TYPE"
    [ "$INTERCEPT_CT_TYPE" = "string" ] || fail "invalid" "intercept.content_type must be a string, found type: $INTERCEPT_CT_TYPE"
    URL_PATTERN="$(printf '%s' "$CONFIG_JSON" | jq -r '.intercept.url_pattern')"
    CONTENT_TYPE="$(printf '%s' "$CONFIG_JSON" | jq -r '.intercept.content_type')"
    [ -n "$URL_PATTERN" ] || fail "invalid" "intercept.url_pattern must be a non-empty string"
    [ -n "$CONTENT_TYPE" ] || fail "invalid" "intercept.content_type must be a non-empty string"

    STUB_TYPE_OK="$(printf '%s' "$CONFIG_JSON" | jq '(.stub? | type) == "object" and ((.stub | length) > 0)')"
    [ "$STUB_TYPE_OK" = "true" ] || fail "invalid" "stub must be a non-empty object"

    # Same jq-native-only identifier check as global_object_path above, and
    # for the identical reason: a JSON object key can itself contain an
    # embedded newline, which a bash `while read` line-splitting loop over
    # `jq -r '.stub | keys[]'` would silently mis-check as multiple
    # separately-valid fragments instead of the one real (invalid) key.
    STUB_KEYS_SAFE="$(printf '%s' "$CONFIG_JSON" | jq '
      def is_safe_ident: test("^[A-Za-z_$][A-Za-z0-9_$]*\\z") and (. != "__proto__" and . != "constructor" and . != "prototype" and . != "__visualVerifyPermissionKeyMatch");
      .stub | keys | all(is_safe_ident)
    ')"
    [ "$STUB_KEYS_SAFE" = "true" ] || fail "invalid" "stub contains a method name that is invalid or denylisted (__proto__/constructor/prototype/__visualVerifyPermissionKeyMatch)"

    STUB_KEYS="$(printf '%s' "$CONFIG_JSON" | jq -r '.stub | keys[]')"
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      ENTRY="$(printf '%s' "$CONFIG_JSON" | jq -c --arg n "$name" '.stub[$n]')"
      # Branch on the real JSON value via jq equality, never on a bash `case`
      # over a `jq -r`-extracted, command-substitution-trimmed variable -- a
      # trailing newline in `.type` (e.g. "async_const\n") would otherwise be
      # silently stripped by `$(...)` before the `case` ever runs, making an
      # entry whose ACTUAL type matches none of the three real values look
      # like a valid "async_const" entry to this check while the renderer
      # (which reads the untouched original JSON) matches none of its own
      # `===` comparisons for that entry, silently producing NO method at
      # all for it (confirmed live: a stub map otherwise satisfying every
      # required method, plus one such malformed entry, rendered to zero
      # actual stub methods) -- recreating, for that one method, exactly the
      # historical "required method silently missing" failure this whole
      # completeness-checking feature exists to prevent.
      IS_ASYNC_OR_NOOPRETURN="$(printf '%s' "$ENTRY" | jq '.type == "async_const" or .type == "noop_return"')"
      IS_NOOP="$(printf '%s' "$ENTRY" | jq '.type == "noop"')"
      if [ "$IS_ASYNC_OR_NOOPRETURN" = "true" ]; then
        TYPE="$(printf '%s' "$ENTRY" | jq -r '.type')"
        # Compare the actual JSON key array inside jq -- never join() the
        # keys into comma-separated TEXT and compare that via bash. A key
        # named "value\n" (trailing newline) would `join(",")` into
        # "type,value\n", which command substitution's unconditional
        # trailing-newline stripping then silently turns into the
        # indistinguishable-from-valid text "type,value" -- exactly the
        # same class of bug already fixed above for the identifier checks,
        # here manifesting as an entry that LOOKS like it has a real
        # "value" key (so `.value | value_shape` below sees a missing key,
        # i.e. JSON null, which value_shape's own "null is a valid scalar"
        # rule then accepts) while the entry's REAL, differently-named key
        # holds the actual configured value untouched and unused.
        KEYS_OK="$(printf '%s' "$ENTRY" | jq '(keys | sort) == ["type","value"]')"
        [ "$KEYS_OK" = "true" ] || fail "invalid" "stub.$name ($TYPE) must have exactly 'type' and 'value'"
        # value_shape was previously hand-rolled in jq (number-magnitude
        # comparisons + tostring), but jq's own double handling is itself
        # imprecise at extreme (subnormal, ~1e-324) magnitudes -- confirmed
        # live: `echo '-2.5e-324' | jq '. <= -5e-324'` returns `true` even
        # though -2.5e-324 is NOT more negative than -5e-324 mathematically,
        # so that comparison both under- and over-rejected right at the
        # boundary it exists to enforce. Separately, `tostring != "-0"` only
        # catches the exact spelling "-0", missing "-0.0"/"-0.00"/"-0e-324"
        # (all ALSO negative zero, but rendered as different tostring text by
        # jq). This check now handles ONLY structural shape (scalar/plain
        # array/object) and the denylisted-key check -- numeric magnitude/
        # underflow/overflow/safe-integer safety is no longer re-derived
        # here at all. That check now runs ONCE, earlier, directly against
        # $CANDIDATE_PATH before any jq round-trip (see the whole-document
        # numeric-safety gate above) -- doing it here instead, against
        # `.value` as extracted via `jq -c` from $CONFIG_JSON/$ENTRY, was
        # confirmed LIVE to be unreliable: jq's own number reserialization
        # is itself lossy for sufficiently extreme literals (e.g.
        # "1e-1147483647" got rewritten by `jq -c '.'` to "0E-1147483646"
        # before this stage ever saw it, defeating even a fully-correct
        # Decimal-based check running on that already-mangled text). By the
        # time this code runs, the earlier gate has already guaranteed every
        # number anywhere in the file is safe, so ordinary structural jq
        # processing of already-known-safe values here is fine.
        VALID_VALUE="$(printf '%s' "$ENTRY" | jq -c '.value' | python3 -c '
import json, sys

DENYLIST = {"__proto__", "constructor", "prototype", "__visualVerifyPermissionKeyMatch"}

def check(v):
    if isinstance(v, (bool, int, float)):
        return True
    if v is None or isinstance(v, str):
        return True
    if isinstance(v, list):
        return all(check(x) for x in v)
    if isinstance(v, dict):
        if any(k in DENYLIST for k in v.keys()):
            return False
        return all(check(x) for x in v.values())
    return False

try:
    data = json.loads(sys.stdin.read())
    print("true" if check(data) else "false")
except Exception:
    print("false")
')"
        [ "$VALID_VALUE" = "true" ] || fail "invalid" "stub.$name.value is not a scalar/plain-JSON value, or contains a denylisted key (__proto__/constructor/prototype/__visualVerifyPermissionKeyMatch) -- JS object-literal syntax treats __proto__ specially even as a nested value, and __visualVerifyPermissionKeyMatch collides with this feature's own route-match marker property, so neither is ever allowed anywhere in a stub value, not only in identifier positions"
      elif [ "$IS_NOOP" = "true" ]; then
        KEYS_OK="$(printf '%s' "$ENTRY" | jq '(keys | sort) == ["type"]')"
        [ "$KEYS_OK" = "true" ] || fail "invalid" "stub.$name (noop) must have exactly 'type', no 'value'"
      else
        TYPE_FOR_MSG="$(printf '%s' "$ENTRY" | jq -r '.type // "<missing>"')"
        fail "invalid" "stub.$name has unrecognized type: $TYPE_FOR_MSG"
      fi
    done <<EOF
$STUB_KEYS
EOF

    HAS_STAR="$(printf '%s' "$CONFIG_JSON" | jq 'if (.permission_keys_by_route? | type) == "object" then (.permission_keys_by_route | has("*")) else false end')"
    [ "$HAS_STAR" = "true" ] || fail "invalid" "permission_keys_by_route must be an object with a '*' fallback key"
    # Collect bad route keys as a compact JSON ARRAY, and decide accept/reject
    # from that array's own `length` inside jq -- never by extracting the
    # keys as bash TEXT (one per line via `jq -r`) and testing that text for
    # emptiness. A route whose KEY is itself the empty string "" is a
    # perfectly valid JSON object key; `jq -r` prints it as a blank line,
    # and if it's the ONLY violation, the entire piped output is nothing but
    # newlines -- which `$(...)` command substitution collapses to a
    # genuinely empty bash string, making `[ -z "$BAD_ROUTE_VALUES" ]`
    # incorrectly report "no violations found" for a route that has one.
    BAD_ROUTE_KEYS_JSON="$(printf '%s' "$CONFIG_JSON" | jq -c '[
      .permission_keys_by_route | to_entries[]
      | select((.value | type) != "array" or (.value | any(type != "string" or length == 0)))
      | .key
    ]')"
    ROUTES_ALL_OK="$(printf '%s' "$BAD_ROUTE_KEYS_JSON" | jq 'length == 0')"
    [ "$ROUTES_ALL_OK" = "true" ] || fail "invalid" "permission_keys_by_route has a non-array-of-non-empty-strings value for route(s): $BAD_ROUTE_KEYS_JSON"

    # --- profile lookup: private dir first, then bundled dir ---
    PRIVATE_PROFILE_DIR="$HOME/.claude/plugins/data/visual-verify/profiles"
    BUNDLED_PROFILE_DIR="$INSTALL_ROOT/profiles"
    PROFILE_FILE_VALID_FILTER='
      def valid_entry:
        (type == "object") and
        ((.allowed_types? | type) == "array") and
        (.allowed_types | length > 0) and
        (.allowed_types | all(. as $t | (["async_const","noop","noop_return"] | index($t)) != null)) and
        ((keys | sort) as $k | ($k == ["allowed_types"] or $k == ["allowed_types","value_must_resolve_placeholder"])) and
        (if has("value_must_resolve_placeholder") then
           ((.value_must_resolve_placeholder == "$PERMISSION_KEYS") or (.value_must_resolve_placeholder == "$ORIGIN_PATHNAME"))
           and (.allowed_types | any(. == "async_const" or . == "noop_return"))
         else true end);
      (.profile == $expected_profile) and
      ((.required_methods? | type) == "object") and
      ((.required_methods | length) > 0) and
      (.required_methods | to_entries | all(
        (.key | test("^[A-Za-z_$][A-Za-z0-9_$]*\\z") and (. != "__proto__" and . != "constructor" and . != "prototype" and . != "__visualVerifyPermissionKeyMatch")) and
        (.value | valid_entry)
      ))
    '
    REQUIRED_METHODS_JSON=""
    for dir in "$PRIVATE_PROFILE_DIR" "$BUNDLED_PROFILE_DIR"; do
      [ -n "$dir" ] && [ -d "$dir" ] || continue
      CAND="$dir/$PROFILE.json"
      [ -f "$CAND" ] || continue
      # Path-containment defense-in-depth: the FULLY SYMLINK-RESOLVED candidate
      # file must sit directly inside this profiles dir's own resolved real
      # path -- never a subdirectory or an escape via a symlinked profile file
      # itself. Resolving only dirname("$CAND") (always syntactically "$dir",
      # since the profile-name grammar already forbids "/") would never catch a symlinked
      # *file* pointing elsewhere; realpath (via python3, portable across
      # macOS/Linux -- BSD readlink has no -f) resolves the file itself,
      # following any symlink chain to its real target.
      REAL_DIR="$(cd "$dir" 2>/dev/null && pwd -P)" || continue
      REAL_CAND="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CAND" 2>/dev/null)" || continue
      [ -n "$REAL_CAND" ] || continue
      REAL_CAND_DIR="$(dirname "$REAL_CAND")"
      [ "$REAL_CAND_DIR" = "$REAL_DIR" ] || continue
      PROFILE_JSON="$(jq -c '.' "$CAND" 2>/dev/null)"
      [ -n "$PROFILE_JSON" ] || continue
      RM_OK="$(printf '%s' "$PROFILE_JSON" | jq --arg expected_profile "$PROFILE" "$PROFILE_FILE_VALID_FILTER" 2>/dev/null)"
      [ "$RM_OK" = "true" ] || continue
      REQUIRED_METHODS_JSON="$(printf '%s' "$PROFILE_JSON" | jq -c '.required_methods')"
      break
    done

    if [ -z "$REQUIRED_METHODS_JSON" ]; then
      fail "unrecognized_profile" "no valid profile file found for profile '$PROFILE' (checked $PRIVATE_PROFILE_DIR then $BUNDLED_PROFILE_DIR)"
    fi

    # --- layer 3: completeness + per-method contract check ---
    COMPLETENESS_FILTER='
      .required_methods as $rm | .stub as $stub |
      ($rm | keys | map(
        . as $name |
        if ($stub[$name] == null) then
          $name + ": missing from config stub"
        elif ($rm[$name].allowed_types | index($stub[$name].type)) == null then
          $name + ": type " + $stub[$name].type + " not allowed (expected one of " + ($rm[$name].allowed_types | join(",")) + ")"
        elif ($rm[$name].value_must_resolve_placeholder != null) and ($stub[$name].value != $rm[$name].value_must_resolve_placeholder) then
          $name + ": value must be exactly " + $rm[$name].value_must_resolve_placeholder
        else empty end
      )) | .[0] // empty
    '
    MERGED="$(jq -n --argjson rm "$REQUIRED_METHODS_JSON" --argjson stub "$(printf '%s' "$CONFIG_JSON" | jq -c '.stub')" '{required_methods:$rm, stub:$stub}')"
    VIOLATION="$(printf '%s' "$MERGED" | jq -r "$COMPLETENESS_FILTER")"
    if [ -n "$VIOLATION" ] && [ "$VIOLATION" != "null" ]; then
      fail "invalid" "completeness check failed: $VIOLATION"
    fi

    ok "$CONFIG_JSON"
    ;;

  *)
    usage
    exit 1
    ;;
esac

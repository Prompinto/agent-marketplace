#!/usr/bin/env bash
# detect-env.sh <repo-path> [app-subdir]
#
# Read-only project detection for visual-verify. Never writes, installs, or
# starts anything -- only inspects package.json/lockfiles/node_modules/source
# files already on disk and prints one JSON object describing what it found.
#
# Framework/company names below (next/vite/nuxt/...) are recognition
# signatures for a best-effort default-port GUESS only -- never assumed
# correct. The real port is confirmed later by an actual health-check
# (lifecycle.sh), never by this script.
set -u

REPO_PATH="${1:-}"
APP_SUBDIR="${2:-}"

if [ -z "$REPO_PATH" ] || [ ! -d "$REPO_PATH" ]; then
  jq -n --arg repo_path "$REPO_PATH" \
    '{"error":"repo_path missing or not a directory","repo_path":$repo_path}'
  exit 1
fi

REPO_PATH="$(cd "$REPO_PATH" && pwd)"
REAL_REPO_PATH="$(cd "$REPO_PATH" && pwd -P)"

# is_contained_app_dir <path relative to REPO_PATH> -- true only if it
# resolves (following any ../ components AND any symlinks) to REPO_PATH
# itself or a genuine descendant of it. Applied to every candidate app
# directory this script ever considers, from either source (an explicit
# app-subdir argument, or a workspace glob match) -- confirmed live: an
# explicit "../external-dir" argument, and separately a
# pnpm-workspace.yaml/package.json workspaces entry of "../external-dir",
# both previously resolved (and were used) outside REPO_PATH despite each
# candidate's own [ -d ]/[ -f package.json ] checks passing, since those
# checks follow ".." via the real filesystem while the STRING prefix-strip
# that derived app_dir from it never re-validated where that resolved to.
is_contained_app_dir() {
  local real
  real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$REPO_PATH/$1" 2>/dev/null)" || return 1
  [ -n "$real" ] || return 1
  case "$real" in
    "$REAL_REPO_PATH") return 0 ;;
    "$REAL_REPO_PATH"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- package manager & lockfile (repo root) ---
PACKAGE_MANAGER="null"
LOCKFILE="null"
if [ -f "$REPO_PATH/pnpm-lock.yaml" ]; then
  PACKAGE_MANAGER='"pnpm"'; LOCKFILE='"pnpm-lock.yaml"'
elif [ -f "$REPO_PATH/yarn.lock" ]; then
  PACKAGE_MANAGER='"yarn"'; LOCKFILE='"yarn.lock"'
elif [ -f "$REPO_PATH/package-lock.json" ]; then
  PACKAGE_MANAGER='"npm"'; LOCKFILE='"package-lock.json"'
fi

# --- monorepo shape (repo root) ---
MONOREPO="false"
WORKSPACE_GLOBS=""
if [ -f "$REPO_PATH/pnpm-workspace.yaml" ]; then
  MONOREPO="true"
  # Best-effort YAML read: lines under `packages:` shaped like `  - "glob"`.
  # Use [[:space:]] (POSIX class), never \s -- BSD sed/grep (macOS default)
  # treats \s as a literal "s" character, not whitespace, unlike GNU.
  WORKSPACE_GLOBS="$(sed -n '/^packages:/,/^[^ -]/p' "$REPO_PATH/pnpm-workspace.yaml" \
    | grep -E '^[[:space:]]*-[[:space:]]*' | sed -E "s/^[[:space:]]*-[[:space:]]*['\"]?//; s/['\"]?[[:space:]]*\$//")"
elif [ -f "$REPO_PATH/package.json" ]; then
  # .workspaces can be either an array (npm/yarn classic form,
  # `"workspaces": ["apps/*"]`) or an object (`{"packages": [...]}`).
  # Indexing an array with a string key (.workspaces.packages) is a jq
  # runtime error, not a null -- the `//` fallback operator never catches it.
  # Detect the shape first, then pick the right path.
  WS_JSON="$(jq -c 'if (.workspaces | type) == "array" then .workspaces
                    elif (.workspaces.packages | type) == "array" then .workspaces.packages
                    else [] end' "$REPO_PATH/package.json" 2>/dev/null)"
  if [ -n "$WS_JSON" ] && [ "$WS_JSON" != "[]" ] && [ "$WS_JSON" != "null" ]; then
    MONOREPO="true"
    WORKSPACE_GLOBS="$(printf '%s' "$WS_JSON" | jq -r '.[]?' 2>/dev/null)"
  fi
fi

# --- candidate app directories ---
# APP_DIRS_ARR holds paths relative to $REPO_PATH, "." meaning the repo root.
# A real bash ARRAY, never a newline-joined string later split by `read` --
# a directory name containing an embedded newline (e.g. literally named
# "safe"+newline+"..") passes is_contained_app_dir as ONE string (the whole
# name resolves inside the repo, correctly), but joining it into a
# newline-delimited string and later splitting that on newlines turns it
# back into TWO separate candidates ("safe" and ".."), the second of which
# was never itself contained-checked. An array preserves each candidate as
# one indivisible element end to end, so this can't happen.
APP_DIRS_ARR=()
if [ -n "$APP_SUBDIR" ]; then
  if is_contained_app_dir "$APP_SUBDIR"; then
    APP_DIRS_ARR=("$APP_SUBDIR")
  else
    # An explicit app-subdir that resolves outside REPO_PATH is never
    # trusted -- fall back to the repo root rather than silently using an
    # external directory as this run's "app."
    APP_DIRS_ARR=(".")
  fi
elif [ "$MONOREPO" = "true" ] && [ -n "$WORKSPACE_GLOBS" ]; then
  while IFS= read -r glob; do
    [ -z "$glob" ] && continue
    for d in "$REPO_PATH"/$glob; do
      [ -d "$d" ] && [ -f "$d/package.json" ] || continue
      is_contained_app_dir "${d#"$REPO_PATH"/}" || continue
      APP_DIRS_ARR+=("${d#"$REPO_PATH"/}")
    done
  done <<EOF
$WORKSPACE_GLOBS
EOF
  [ ${#APP_DIRS_ARR[@]} -eq 0 ] && APP_DIRS_ARR=(".")
else
  APP_DIRS_ARR=(".")
fi

# --- dev-server binary signatures -> default port guess ---
default_port_for() {
  case "$1" in
    *"next dev"*|*"next start"*) echo 3000 ;;
    *"nuxt dev"*|*nuxt*) echo 3000 ;;
    *vite*) echo 5173 ;;
    *"vue-cli-service serve"*) echo 8080 ;;
    *"ng serve"*) echo 4200 ;;
    *"webpack serve"*|*"webpack-dev-server"*) echo 8080 ;;
    *"react-scripts start"*) echo 3000 ;;
    *parcel*) echo 1234 ;;
    *"http-server"*) echo 8080 ;;
    *) echo 3000 ;;
  esac
}

# is_safe_script_name <name> -- true only if <name> matches the grammar real
# npm/pnpm/yarn script keys actually use (letters, digits, underscore, colon,
# dot, hyphen -- e.g. "dev", "dev:local", "build:prod", "test.unit"). Applied
# BEFORE a script name is ever accepted as a candidate in either function
# below -- SKILL.md's Phase 2 builds "<package_manager> run <dev_script_name>"
# as a literal COMMAND string later run via `sh -c`, so a script key like
# "dev:local; printf INJECTED" (a real, if unusual, JSON object key npm
# itself accepts as a script name) would otherwise have its semicolon
# interpreted as a shell command separator once selected and run downstream.
# Confirmed live: a package.json whose ONLY relevant script was that exact
# key got selected by this script before this check existed. Rejecting here,
# at the point the name is chosen, closes the injection before it ever
# reaches a shell-interpreted context.
is_safe_script_name() {
  case "$1" in
    *[!A-Za-z0-9_:.-]*) return 1 ;;
    "") return 1 ;;
    *) return 0 ;;
  esac
}

# pick_dev_script <package.json path> -> prints "name<TAB>command" or nothing
pick_dev_script() {
  local pkg="$1" best_name="" best_cmd=""
  while IFS=$'\t' read -r name cmd; do
    [ -z "$name" ] && continue
    is_safe_script_name "$name" || continue
    if [ "$name" = "dev" ]; then
      best_name="$name"; best_cmd="$cmd"; break
    fi
    case "$name" in
      dev:*|*:dev|serve)
        [ -z "$best_name" ] && { best_name="$name"; best_cmd="$cmd"; } ;;
    esac
    case "$cmd" in
      *"next dev"*|*vite*|*"webpack serve"*|*"webpack-dev-server"*|*"nuxt dev"*|*"vue-cli-service serve"*|*"ng serve"*|*"react-scripts start"*|*parcel*)
        [ -z "$best_name" ] && { best_name="$name"; best_cmd="$cmd"; } ;;
    esac
  done < <(jq -r '.scripts // {} | to_entries[] | "\(.key)\t\(.value)"' "$pkg" 2>/dev/null)
  [ -n "$best_name" ] && printf '%s\t%s\n' "$best_name" "$best_cmd"
}

# find_aux_script <package.json path> <exclude-script-name> -> "name<TAB>command" or nothing
find_aux_script() {
  local pkg="$1" exclude="$2"
  while IFS=$'\t' read -r name cmd; do
    [ -z "$name" ] || [ "$name" = "$exclude" ] && continue
    is_safe_script_name "$name" || continue
    case "$name $cmd" in
      *[Mm]ock*|*msw*|*json-server*|*[Ff]ixture*|*[Ss]tub*)
        case "$name $cmd" in
          *dev*|*serve*|*start*)
            printf '%s\t%s\n' "$name" "$cmd"; return 0 ;;
        esac ;;
    esac
  done < <(jq -r '.scripts // {} | to_entries[] | "\(.key)\t\(.value)"' "$pkg" 2>/dev/null)
}

APPS_JSON="[]"
AUX_JSON="null"
for app_dir in "${APP_DIRS_ARR[@]}"; do
  [ -z "$app_dir" ] && continue
  pkg="$REPO_PATH/$app_dir/package.json"
  [ "$app_dir" = "." ] && pkg="$REPO_PATH/package.json"
  [ -f "$pkg" ] || continue

  DEV_LINE="$(pick_dev_script "$pkg")"
  DEV_NAME="null"; DEV_CMD="null"; PORT="null"; HOST="null"; PORT_SOURCE="null"
  if [ -n "$DEV_LINE" ]; then
    IFS=$'\t' read -r n c <<EOF
$DEV_LINE
EOF
    DEV_NAME="$(printf '%s' "$n" | jq -Rs '. | rtrimstr("\n")')"
    DEV_CMD="$(printf '%s' "$c" | jq -Rs '. | rtrimstr("\n")')"
    P="$(printf '%s' "$c" | grep -oE '(--port|-p)[= ]+[0-9]+' | grep -oE '[0-9]+' | head -1)"
    H="$(printf '%s' "$c" | grep -oE '(--host|-H)[= ]+[^ ]+' | sed -E 's/^(--host|-H)[= ]+//' | head -1)"
    if [ -n "$P" ]; then
      PORT="$P"; PORT_SOURCE='"flag"'
    else
      PORT="$(default_port_for "$c")"; PORT_SOURCE='"default_guess"'
    fi
    # Only trust a --host/-H value extracted from the target repo's own dev
    # script if it is a recognized LOCAL address. Blindly reporting whatever
    # the repo wrote there would let it redirect the caller's own later
    # health-check (which runs BEFORE anything is started, purely to see if
    # something is already listening) to an arbitrary address of the repo
    # author's choosing -- e.g. a cloud metadata endpoint
    # (169.254.169.254) -- an SSRF-shaped risk from merely detecting a
    # repository, never confirmed against anything the caller chose. An
    # untrusted value is reported as null (never silently substituted with
    # a guess), matching the same "null means the caller falls back to
    # 127.0.0.1" contract host already has for the flag-absent case.
    case "$H" in
      localhost|127.0.0.1|0.0.0.0)
        HOST="$(printf '%s' "$H" | jq -Rs '. | rtrimstr("\n")')" ;;
      ::1|\[::1\])
        # lifecycle.sh builds "http://$HOST:$PORT/" for its health check.
        # curl's URL parser requires the BRACKETED form for an IPv6 literal
        # host -- confirmed live: `curl 'http://[::1]:1/'` is a syntactically
        # valid URL (fails with a connection error, nothing listening), while
        # `curl 'http://::1:1/'` is rejected outright as an unparseable URL
        # (`curl: (3) URL rejected`). A dev script may write --host ::1
        # (bare) or --host [::1] (already bracketed); normalize both to the
        # bracketed form here so whatever gets stored in HOST/reported in
        # apps[].host is always usable by that downstream URL construction.
        HOST='"[::1]"' ;;
      *) HOST="null" ;;
    esac
  fi

  ENTRY="$(jq -n \
    --arg app_dir "$app_dir" \
    --arg package_json "$pkg" \
    --argjson dev_script_name "$DEV_NAME" \
    --argjson dev_command "$DEV_CMD" \
    --argjson port "$PORT" \
    --argjson host "$HOST" \
    --argjson port_source "$PORT_SOURCE" \
    '{app_dir:$app_dir, package_json:$package_json, dev_script_name:$dev_script_name, dev_command:$dev_command, port:$port, host:$host, port_source:$port_source}')"
  APPS_JSON="$(printf '%s' "$APPS_JSON" | jq --argjson e "$ENTRY" '. + [$e]')"

  if [ "$AUX_JSON" = "null" ] && [ -n "$DEV_LINE" ]; then
    AUX_LINE="$(find_aux_script "$pkg" "$n")"
    if [ -n "$AUX_LINE" ]; then
      IFS=$'\t' read -r an ac <<EOF
$AUX_LINE
EOF
      AUX_JSON="$(jq -n --arg app_dir "$app_dir" --arg name "$an" --arg command "$ac" \
        '{app_dir:$app_dir, script_name:$name, command:$command}')"
    fi
  fi
done

# --- Playwright availability (search, never assume a fixed path) ---
# Check the repo root plus every candidate app dir (APP_DIRS) -- a monorepo
# can have Playwright hoisted to the root OR installed locally under just one
# specific app's own node_modules, never both checked by only looking at
# $REPO_PATH and a single $APP_SUBDIR.
PLAYWRIGHT_AVAILABLE="false"
PLAYWRIGHT_PACKAGE="null"
PLAYWRIGHT_RESOLVED_PATH="null"
PLAYWRIGHT_VERSION="null"
CANDIDATE_ROOTS_ARR=("$REPO_PATH")
for app_dir in "${APP_DIRS_ARR[@]}"; do
  case "$app_dir" in
    ""|.) continue ;;
  esac
  CANDIDATE_ROOTS_ARR+=("$REPO_PATH/$app_dir")
done
for candidate_root in "${CANDIDATE_ROOTS_ARR[@]}"; do
  [ -z "$candidate_root" ] && continue
  [ "$PLAYWRIGHT_AVAILABLE" = "true" ] && break
  for pkgname in "@playwright/test" "playwright"; do
    ppkg="$candidate_root/node_modules/$pkgname/package.json"
    if [ -f "$ppkg" ]; then
      PLAYWRIGHT_AVAILABLE="true"
      PLAYWRIGHT_PACKAGE="\"$pkgname\""
      PLAYWRIGHT_RESOLVED_PATH="$(jq -Rs '. | rtrimstr("\n")' <<<"$candidate_root/node_modules/$pkgname")"
      PLAYWRIGHT_VERSION="$(jq '.version // null' "$ppkg" 2>/dev/null)"
      [ -z "$PLAYWRIGHT_VERSION" ] && PLAYWRIGHT_VERSION="null"
      break
    fi
  done
done

# --- cached browser binary presence ---
case "$(uname -s)" in
  Darwin) CACHE_DIR="$HOME/Library/Caches/ms-playwright" ;;
  *) CACHE_DIR="$HOME/.cache/ms-playwright" ;;
esac
CACHE_PRESENT="false"
if [ -d "$CACHE_DIR" ] && find "$CACHE_DIR" -maxdepth 1 -type d -name 'chromium-*' -print -quit 2>/dev/null | grep -q .; then
  CACHE_PRESENT="true"
fi

# --- generic auth/permission-gate heuristic (disclosure only, never a bypass) ---
# SEARCH_ROOT is a completely separate variable from APP_DIRS_ARR above and
# was never covered by is_contained_app_dir just because that helper exists
# in this file -- confirmed live: an APP_SUBDIR of "../outside" (or an
# in-repo symlink to an external directory) still passed the plain [ -d ]
# check here and got recursively grepped, disclosing lines from OUTSIDE the
# target repository into the auth-gate-heuristic result. Reuse the same
# containment helper here explicitly; fall back to scanning the whole repo
# (never an external directory) when it doesn't pass.
SEARCH_ROOT="$REPO_PATH"
if [ -n "$APP_SUBDIR" ] && [ -d "$REPO_PATH/$APP_SUBDIR" ] && is_contained_app_dir "$APP_SUBDIR"; then
  SEARCH_ROOT="$REPO_PATH/$APP_SUBDIR"
fi
# `find -type f` restricts this scan to REGULAR files only, before grep ever
# touches anything -- `grep -r`'s own recursion doesn't distinguish file
# types, so a named pipe (FIFO) sitting in the scanned tree with one of these
# extensions (e.g. a file literally named "auth.ts" that is actually a FIFO)
# makes `grep -r` block indefinitely trying to read from it, hanging this
# supposedly fast, bounded, read-only detection phase. `-prune` on the same
# excluded-dir names `grep -r --exclude-dir` used, then `-exec ... {} +`
# (never `xargs`) preserves the "never invoke the command at all when zero
# files matched" behavior on BOTH BSD find/xargs (macOS default) and GNU
# find/xargs -- GNU `xargs` with no `-r`/`--no-run-if-empty` flag WOULD invoke
# a zero-argument `grep 'pattern'` on empty input, which reads from stdin and
# reintroduces the exact same class of hang this fix exists to close.
AUTH_MATCHES="$(find "$SEARCH_ROOT" \
  \( -name node_modules -o -name .git -o -name dist -o -name build -o -name .next -o -name .nuxt -o -name coverage \) -prune -o \
  -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' \) \
  -exec grep -H -niIE \
    'useAuth|withAuth|ProtectedRoute|requireAuth|redirectToLogin|redirect[^\n]{0,20}login|isAuthenticated' \
    {} + \
  2>/dev/null | head -5)"
AUTH_FIRED="false"
[ -n "$AUTH_MATCHES" ] && AUTH_FIRED="true"
AUTH_MATCHES_JSON="$(printf '%s\n' "$AUTH_MATCHES" | jq -Rs 'split("\n") | map(select(length > 0))')"

# --- opt-in auth-gate stub-injection config (see SKILL.md, "Auth-stub
# injection (opt-in)"). Read-only discovery + validation, never a bypass on
# its own -- Phase 3 only injects anything when this reports "valid". ---
STUB_CONFIG_JSON="$("$(dirname "$0")/auth-stub.sh" validate "$REPO_PATH" "$APP_SUBDIR" 2>/dev/null)"
if ! printf '%s' "$STUB_CONFIG_JSON" | jq -e . >/dev/null 2>&1; then
  STUB_CONFIG_JSON='{"status":"absent"}'
fi
STUB_CONFIG_PRESENT="true"
if [ "$(printf '%s' "$STUB_CONFIG_JSON" | jq -r '.status')" = "absent" ]; then
  STUB_CONFIG_PRESENT="false"
fi

jq -n \
  --arg repo_path "$REPO_PATH" \
  --argjson package_manager "$PACKAGE_MANAGER" \
  --argjson lockfile "$LOCKFILE" \
  --argjson monorepo "$MONOREPO" \
  --argjson apps "$APPS_JSON" \
  --argjson aux_service "$AUX_JSON" \
  --argjson playwright_available "$PLAYWRIGHT_AVAILABLE" \
  --argjson playwright_package "$PLAYWRIGHT_PACKAGE" \
  --argjson playwright_resolved_path "$PLAYWRIGHT_RESOLVED_PATH" \
  --argjson playwright_version "$PLAYWRIGHT_VERSION" \
  --argjson browser_cache_present "$CACHE_PRESENT" \
  --arg browser_cache_path "$CACHE_DIR" \
  --argjson auth_gate_fired "$AUTH_FIRED" \
  --argjson auth_gate_matches "$AUTH_MATCHES_JSON" \
  --argjson stub_config_present "$STUB_CONFIG_PRESENT" \
  --argjson stub_config "$STUB_CONFIG_JSON" \
  '{
    repo_path: $repo_path,
    package_manager: $package_manager,
    lockfile: $lockfile,
    monorepo: $monorepo,
    apps: $apps,
    aux_service: $aux_service,
    playwright: {
      available: $playwright_available,
      package: $playwright_package,
      resolved_path: $playwright_resolved_path,
      version: $playwright_version
    },
    browser_cache: {
      present: $browser_cache_present,
      path: $browser_cache_path
    },
    auth_gate_heuristic: {
      fired: $auth_gate_fired,
      matches: $auth_gate_matches
    }
  } + (if $stub_config_present then {stub_config: $stub_config} else {} end)'

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
# APP_DIRS holds paths relative to $REPO_PATH, "." meaning the repo root.
APP_DIRS=""
if [ -n "$APP_SUBDIR" ]; then
  APP_DIRS="$APP_SUBDIR"
elif [ "$MONOREPO" = "true" ] && [ -n "$WORKSPACE_GLOBS" ]; then
  while IFS= read -r glob; do
    [ -z "$glob" ] && continue
    for d in "$REPO_PATH"/$glob; do
      [ -d "$d" ] && [ -f "$d/package.json" ] || continue
      APP_DIRS="${APP_DIRS}${d#"$REPO_PATH"/}
"
    done
  done <<EOF
$WORKSPACE_GLOBS
EOF
  [ -z "$APP_DIRS" ] && APP_DIRS="."
else
  APP_DIRS="."
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

# pick_dev_script <package.json path> -> prints "name<TAB>command" or nothing
pick_dev_script() {
  local pkg="$1" best_name="" best_cmd=""
  while IFS=$'\t' read -r name cmd; do
    [ -z "$name" ] && continue
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
while IFS= read -r app_dir; do
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
    [ -n "$H" ] && HOST="$(printf '%s' "$H" | jq -Rs '. | rtrimstr("\n")')"
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
done <<EOF
$APP_DIRS
EOF

# --- Playwright availability (search, never assume a fixed path) ---
# Check the repo root plus every candidate app dir (APP_DIRS) -- a monorepo
# can have Playwright hoisted to the root OR installed locally under just one
# specific app's own node_modules, never both checked by only looking at
# $REPO_PATH and a single $APP_SUBDIR.
PLAYWRIGHT_AVAILABLE="false"
PLAYWRIGHT_PACKAGE="null"
PLAYWRIGHT_RESOLVED_PATH="null"
PLAYWRIGHT_VERSION="null"
CANDIDATE_ROOTS_LIST="$REPO_PATH
$(printf '%s\n' "$APP_DIRS" | grep -vE '^\.?$' | sed "s#^#${REPO_PATH}/#")"
while IFS= read -r candidate_root; do
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
done <<EOF
$CANDIDATE_ROOTS_LIST
EOF

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
SEARCH_ROOT="$REPO_PATH"
[ -n "$APP_SUBDIR" ] && [ -d "$REPO_PATH/$APP_SUBDIR" ] && SEARCH_ROOT="$REPO_PATH/$APP_SUBDIR"
AUTH_MATCHES="$(grep -rniIE \
  --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.vue' --include='*.svelte' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=.nuxt --exclude-dir=coverage \
  'useAuth|withAuth|ProtectedRoute|requireAuth|redirectToLogin|redirect[^\n]{0,20}login|isAuthenticated' \
  "$SEARCH_ROOT" 2>/dev/null | head -5)"
AUTH_FIRED="false"
[ -n "$AUTH_MATCHES" ] && AUTH_FIRED="true"
AUTH_MATCHES_JSON="$(printf '%s\n' "$AUTH_MATCHES" | jq -Rs 'split("\n") | map(select(length > 0))')"

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
  }'

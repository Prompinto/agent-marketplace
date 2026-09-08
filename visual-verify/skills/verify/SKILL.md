---
name: verify
description: Detects a web project's own dev tooling (any stack — React/Vue/Next/Vite/plain static, npm/pnpm/yarn, monorepo or not), starts or reuses its dev server, drives a real Chromium browser via the project's own installed Playwright to perform a described interaction and capture a screenshot, shows it to the user, and cleans up. No auth-bypass, no mock-server variant switching, no MR/PR comment posting, no custom scenario DSL — Claude authors the Playwright actions directly from the task description each run.
---

# visual-verify:verify — stack-agnostic visual verification

**Usage:** `visual-verify:verify <what to verify>` — invoked plugin-qualified, like every other
plugin-supplied skill. `<what to verify>` is a route, page, or component to visit and (optionally) a
plain-English description of an interaction to perform before capturing (e.g. "open the settings
page and confirm the new toggle renders" or "go to /checkout, click Continue, and check the error
banner appears").

**If invoked with empty task text, do NOT guess and do NOT default to "review the work just
done."** Ask the user directly (via `AskUserQuestion`, or a plain question if that tool doesn't fit
the moment) what to verify. There is no existing convention in this plugin to fall back to a default
target — a wrong guess means driving a real browser against the wrong thing.

This skill is single-pass: one environment detection, one server start-or-reuse, one browser
capture, one report, one cleanup. It has no retry loop, no multi-round negotiation, and no persisted
state across invocations.

---

## Explicitly out of scope (do not attempt any of this)

- **No auth-bypass stub injection.** This skill has no built-in way to defeat any authentication or
  permission system. If Phase 1's auth-gate heuristic fires, disclose it (Phase 1 outcomes, Phase 3,
  Phase 4) — never attempt to inject a bypass, stub, or token for any specific SDK.
- **No mock-server variant switching or fixture patching.** A second/auxiliary service is detected
  generically (Phase 1 item 4) and started if present, but this skill has no concept of a mocking
  library's own variant-switching API and never attempts to drive one.
- **No GitHub/GitLab/any VCS comment posting.** This skill only captures and reports locally. It
  never writes to a PR/MR, issue, or any external shared system.
- **No custom `--scenario` mini-DSL.** There is no fixed grammar for describing interactions. Claude
  reads the task description's prose each run and writes the actual Playwright interaction code
  directly into that run's driver script — see Phase 3.

---

## Phase 0 — Resolve the task and allocate a session ID

1. **Task text:** if non-empty, that is the target to verify — a route/page/component and an
   optional interaction scenario, all read directly from the prose. If empty, ask the user via
   `AskUserQuestion` what to verify; do not proceed until you have a concrete target.

2. **Repo path:** resolve the target repository's root — normally the current working directory,
   unless the task text names a different path explicitly. Use `git rev-parse --show-toplevel` (or
   the given path directly if it isn't a git repo) to get an absolute path. Remember this as
   `REPO_ROOT` for the rest of the run.

3. **Session ID**, mirroring `codex-stream-review`'s own `run-ccs-review.sh` idiom:
   ```bash
   SESSION_ID="$(date +%Y-%m-%dT%H%M%S)-$$"
   ```
   Timestamp plus the invoking shell's PID — the PID suffix matters because a bare-second
   timestamp collides across two invocations started in the same second. Use this literal string to
   namespace every temp file this run creates:
   - `/tmp/vv-${SESSION_ID}-main.pid`, `/tmp/vv-${SESSION_ID}-main.log` — the dev server (Phase 2)
   - `/tmp/vv-${SESSION_ID}-aux.pid`, `/tmp/vv-${SESSION_ID}-aux.log` — the auxiliary service, only
     if Phase 1 found one and Phase 2 starts it
   - `/tmp/vv-${SESSION_ID}-driver.js` — the Playwright driver script (Phase 3)
   - `/tmp/vv-${SESSION_ID}-screenshot.png` — the captured screenshot (Phase 3, kept — this is the
     deliverable, never deleted in Phase 5)

4. **Resolve this plugin's own install path** the same way `codex-stream-review`'s skills do,
   keyed `visual-verify@agent-marketplace`:
   ```bash
   jq -r '.plugins["visual-verify@agent-marketplace"][] | select(.scope=="user") | .installPath' \
     ~/.claude/plugins/installed_plugins.json
   ```
   If empty, or if `<installPath>/scripts/detect-env.sh` doesn't exist and isn't executable, stop
   here and tell the user: `visual-verify@agent-marketplace is not installed, or is missing
   detect-env.sh — run /plugin install visual-verify@agent-marketplace`. Remember the resolved path
   as `INSTALL_PATH` for the rest of the run.

---

## Phase 1 — Environment detection (read-only, always runs first)

Run:
```bash
"$INSTALL_PATH/scripts/detect-env.sh" "$REPO_ROOT" [app-subdir]
```
Pass `app-subdir` only if the task text or repo shape already narrows to one specific app inside a
monorepo (see below) — otherwise omit it and let the script scan every workspace app.

The script performs read-only inspection only — it never writes, installs, or starts anything — and
prints one JSON object:

- `package_manager` / `lockfile` — which lockfile is present, if any.
- `monorepo` (bool) — presence of `pnpm-workspace.yaml` or a `package.json` `workspaces` field.
- `apps[]` — one entry per candidate app directory (just `["."]` for a non-monorepo), each with
  `app_dir`, `dev_script_name`, `dev_command`, `port` (parsed from the command's own `--port`/`-p`
  flag if present, else a framework-default **guess** — see `port_source`: `"flag"` vs
  `"default_guess"`), and `host` (parsed from `--host`/`-H` if present, else `null`).
- `aux_service` — a second dev-adjacent script this repo's own scripts imply should run alongside
  the main one (detected generically by name/command patterns like `mock`, `msw`, `json-server`,
  `fixture`, `stub` combined with `dev`/`serve`/`start` — never a hardcoded product name), or `null`
  if none found.
- `playwright.available` (bool), `playwright.resolved_path` — whether `@playwright/test` or
  `playwright` was found under the target's own `node_modules` (searched, never assumed at a fixed
  path — a monorepo app can have it hoisted to the repo root or installed locally to the app dir).
- `browser_cache.present` (bool) — whether a `chromium-*` directory exists under
  `~/Library/Caches/ms-playwright` (macOS) / `~/.cache/ms-playwright` (Linux). **A `true` here is
  necessary but not sufficient** — the cached browser's own build may not match the installed
  Playwright package's expected revision (confirmed directly during this skill's own verification:
  a stale cached Chromium build failed to launch with "Executable doesn't exist" for the exact
  revision the newer `@playwright/test` package required, even though `browser_cache.present` was
  `true`). Treat a Phase 3 launch failure with that exact error as "needs
  `npx playwright install chromium`", not as a detection bug — see Phase 3.
- `auth_gate_heuristic.fired` (bool) + `matches[]` — generic grep for `useAuth`/`withAuth`/
  `ProtectedRoute`/`requireAuth`/redirect-to-login patterns across the target's source files. This
  is **disclosure only** — see "Explicitly out of scope" above. Never treat a `false` here as proof
  the target has no auth; it only means the grep found nothing, which can also mean the auth is
  server-side/proxy-level and invisible to a static grep.

**Multiple candidate apps in a monorepo:** if `apps[]` has more than one entry with a resolved
`dev_script_name`, and the task text doesn't already name which app, ask the user (via
`AskUserQuestion`) which one before proceeding — do not guess.

### Phase 1 outcomes

- **Dev command found, Playwright available, browser cache present:** if the resolved app's
  `port_source` is `"default_guess"` (not `"flag"`), disclose this to the user now, before starting
  anything: e.g. "no --port flag found in the dev script; guessing port `<N>` based on `<framework
  signature>`; will confirm via health-check once started." Then proceed to the health-check
  short-circuit below, then Phase 2. (The guess itself is a legitimate best-effort default — this is
  a disclosure step, not a reason to stop or ask permission.)
- **Dev command found, but Playwright missing or browser cache absent:** STOP. Tell the user exactly
  what's missing and the exact command to fix it:
  - Playwright package missing: `npm install --save-dev @playwright/test` (or the detected package
    manager's equivalent) run inside the app directory that needs it.
  - Browser cache absent: `npx playwright install chromium` (~150-300MB download).
  Ask via `AskUserQuestion` whether to run that install now. If declined, stop — do not proceed to
  Phase 2 with a browser that can't launch.
- **No dev command discoverable in any candidate app:** STOP. Report what was checked (which
  directories, which `package.json` files, what script names/patterns were searched for) and ask the
  user directly for the command or URL to use — they may already have a server running.

### Already-running server short-circuit (before starting anything)

Before Phase 2 ever starts anything, health-check the resolved `host:port` first:
```bash
"$INSTALL_PATH/scripts/lifecycle.sh" health "<host or 127.0.0.1>" "<port>" 3
```
- `healthy: true` → something is already answering there. Ask the user (via `AskUserQuestion`)
  whether this is their own already-running dev server to reuse (skip Phase 2's start step entirely
  — go straight to Phase 3 against this URL, and record `server.mode = "reused"` with no PIDs in the
  final result) or whether it's an unrelated process occupying the same port (treat as a conflict:
  ask for a different port, or stop and let the user free the port themselves — never kill a process
  this run didn't start).
- `healthy: false` → nothing is listening there yet. Proceed to Phase 2.

---

## Phase 2 — Start the environment (only if not reusing an already-running server)

Start the main dev command **through the detected package manager's `run` subcommand — never by
passing Phase 1's raw `dev_command` string straight to a shell.** A bare-binary-name script (e.g.
`"dev": "vite"`) only resolves because `npm run`/`pnpm run`/`yarn run` prepend that app's own
`node_modules/.bin` (and, in a workspace, the hoisted root's) onto `PATH` before running the script —
a plain `sh -c "$dev_command"` does not get that and fails to find the binary. Build the command from
`package_manager` and the app's `dev_script_name` (both from Phase 1's JSON), dispatched by
`package_manager` value — never by guessing the framework:
- `"pnpm"` → `pnpm run <dev_script_name>`
- `"yarn"` → `yarn run <dev_script_name>`
- `"npm"` → `npm run <dev_script_name>`
- `null` (no lockfile detected) → fall back to `npm run <dev_script_name>` — npm ships with Node and
  adds `node_modules/.bin` to `PATH` the same way, so this fallback stays correct even without a
  lockfile to key off of.

```bash
"$INSTALL_PATH/scripts/lifecycle.sh" start "<app absolute dir>" "<package_manager> run <dev_script_name>" \
  "/tmp/vv-${SESSION_ID}-main.pid" "/tmp/vv-${SESSION_ID}-main.log"
```
`<app absolute dir>` is the cwd passed to `lifecycle.sh start`, so the invocation always runs with
that app's own directory as the working directory — which is what makes the package manager resolve
the correct local `node_modules/.bin` in the first place.

This launches the command via `nohup ... & disown` inside a subshell, and writes the PID to the
given file immediately — before any health-check ever runs — so a PID is recorded even if the
process later turns out unhealthy. **Never use `lsof -ti:<port> | xargs kill`-style "find by port"
killing anywhere in this run** — that can kill an unrelated process that happens to occupy the same
port. Track exactly the PID(s) this run itself started, in the PID file(s) above, nothing else.

If Phase 1 found an `aux_service`, start it the same way — `<package_manager> run <aux_service's own
script_name>` in that app's directory — into its own `-aux.pid`/`-aux.log` pair, before or after the
main service (order doesn't matter unless the task text says the aux service must be up first).

Then wait for the resolved port to actually answer, bounded (not a fixed `sleep N`):
```bash
"$INSTALL_PATH/scripts/lifecycle.sh" wait-healthy "<host or 127.0.0.1>" "<port>" 60 \
  "/tmp/vv-${SESSION_ID}-main.log"
```
- Success → proceed to Phase 3.
- Failure → the script's own JSON includes a `log_tail` of the last ~30 lines of the captured server
  log. Report that tail to the user directly (it is almost always the actual reason: a missing env
  var, a port already bound by something that didn't answer HTTP, a build error). Then go straight
  to Phase 5 cleanup — do not attempt Phase 3 against a server that never came up — and record
  `outcome: "failed_start"` in the result artifact (Phase 4).

**Guarantee cleanup fires on every exit path from here on.** From this point forward, whatever this
run started (recorded in its own PID file(s)) must be stopped in Phase 5 regardless of whether Phase
3 succeeds, fails, or is never reached — there is no code path past this point that skips Phase 5.

---

## Phase 3 — Drive the browser & capture

Re-verify Playwright is actually usable right now (Phase 1's check could have been answered "no" to
an install prompt, or the situation could have changed):
```bash
test -d "<playwright.resolved_path from Phase 1>" && echo present
```
If it's gone, stop, go to Phase 5 cleanup, and record `outcome: "failed_env_detection"`.

Write a session-scoped driver script to `/tmp/vv-${SESSION_ID}-driver.js` that:
1. `require()`s Chromium from the **project's own resolved Playwright path** from Phase 1 — never a
   hardcoded `node_modules/@playwright/test`, never a globally-installed copy:
   ```js
   const { chromium } = require('<playwright.resolved_path from Phase 1>');
   ```
2. Launches Chromium (`chromium.launch()`), opens a page, and navigates to the resolved URL
   (`http://<host>:<port><path from task text, default "/">`).
3. **Performs the interaction scenario described in the task text, written directly as Playwright
   actions for this one run** — there is no DSL to parse; read the prose and write the corresponding
   `page.click(...)`/`page.fill(...)`/`page.waitForSelector(...)`/etc. calls yourself. If the task
   text names no interaction (just "verify this page renders"), skip straight to the screenshot.
4. Screenshots to `/tmp/vv-${SESSION_ID}-screenshot.png` — session-scoped, so concurrent runs never
   collide on a shared fixed path.
5. Closes the browser and exits 0; on any thrown error, `console.error` it and exit 1 so the
   failure is visible in the command's own output rather than silently producing no screenshot.

Run it with the repo's own Node:
```bash
node "/tmp/vv-${SESSION_ID}-driver.js"
```

**If launch fails with "Executable doesn't exist at ... chromium_headless_shell-<N>" or similar**
(confirmed live during this skill's own verification run — a cached browser build from an older
Playwright version does not satisfy a newer package's expected revision even though
`browser_cache.present` was `true` in Phase 1): this is the install-needed case, not a code bug. Tell
the user `npx playwright install chromium` is needed, ask via `AskUserQuestion` whether to run it,
and retry once if they agree.
- **If they decline:** go straight to Phase 5 cleanup and record `outcome: "failed_env_detection"` —
  the same outcome used when Playwright turns out unusable elsewhere in this phase. Do not leave the
  dev server(s) started in Phase 2 running; Phase 5's cleanup guarantee applies here exactly as it
  does to every other exit path from this phase.
- **If it fails for any other reason:** capture the actual error text, go to Phase 5, and record
  `outcome: "failed_navigation"` (a navigation/selector/timeout failure) or `outcome:
  "failed_capture"` (screenshot step itself failed) as appropriate — whichever step in the driver
  script actually threw.

**No auth-bypass attempt here, ever.** If Phase 1's auth-gate heuristic fired, the captured
screenshot may show a login/forbidden page instead of the intended UI — that is expected and must be
disclosed in Phase 4, not silently worked around.

---

## Phase 4 — Show the result & report

**Always run `open <screenshot-path>` (macOS)** so the screenshot actually renders in the user's own
environment — do not rely on your own `Read`-tool image view as a substitute; that is not the same as
the user's terminal actually showing it. This was a real, previously-hit failure mode in the source
workflow this skill generalizes: the model confirming a screenshot looks right to itself is not the
same as the user seeing it.
```bash
open "/tmp/vv-${SESSION_ID}-screenshot.png"
```
(No non-macOS branch exists yet — if running on Linux/Windows, tell the user the screenshot path
directly instead and note that auto-opening isn't implemented for this OS.)

Report to the user, in plain text:
- What was verified (the route/page and the interaction performed, if any).
- The resolved URL actually navigated to.
- Whether the server was reused or started fresh by this run (and the aux service, if any).
- The screenshot path.
- The auth-gate disclosure from Phase 1, if it fired.

Write the structured result artifact:
```bash
mkdir -p ~/.claude/plugins/data/visual-verify/logs/<repo-slug>
```
where `<repo-slug>` is `$REPO_ROOT` with `/` replaced by `-` (mirrors how other plugins in this
marketplace key per-repo log directories). Write
`~/.claude/plugins/data/visual-verify/logs/<repo-slug>/${SESSION_ID}.result.json`, validated against
`schemas/verify-result.schema.json` — fields:
- `session_id`, `target` (`repo`, `app`, `url`)
- `env_detection` (`dev_command_found`, `playwright_status`: `available`|`missing`|
  `install_declined`, `auth_gate_heuristic_fired`)
- `server` (`mode`: `reused`|`started`|`not_applicable`, `pids`: array of the PID(s) this run
  itself started — empty when reused)
- `scenario` (the task text actually used)
- `screenshot_path` (the literal path — required non-null when `outcome` is `captured`, `null`
  otherwise)
- `outcome`: `captured`|`failed_env_detection`|`failed_start`|`failed_navigation`|`failed_capture`
- `cleanup`: `killed`|`left_running`|`not_applicable` — filled in after Phase 5 actually runs

This gives the same "durable evidence, not just a chat message" property `codex-stream-review`
already established as valuable for its own review runs — reused here for a single-pass capture
instead of a multi-round review log.

---

## Phase 5 — Cleanup (always runs, even on failure)

For each service this run itself started (main, and aux if started):
```bash
"$INSTALL_PATH/scripts/lifecycle.sh" stop "/tmp/vv-${SESSION_ID}-main.pid"
"$INSTALL_PATH/scripts/lifecycle.sh" stop "/tmp/vv-${SESSION_ID}-aux.pid"   # only if aux was started
```
`stop` reads the PID from the given file, sends TERM to that PID's own process group, waits briefly,
escalates to KILL only if still alive, then removes the PID file. **It never re-derives a PID by
port** — if the PID file doesn't exist (the reuse case: this run never started anything), `stop`
reports `stopped: "not_applicable"` and touches nothing, which is exactly correct for a reused
server: it must never be killed by this run.

Remove the session-scoped driver script:
```bash
rm -f "/tmp/vv-${SESSION_ID}-driver.js"
```

**Leave the screenshot and the result JSON** — those are the deliverables. Update the result
artifact's `cleanup` field (`killed` if this run stopped something it started, `left_running` if a
stop attempt failed and the process is still alive — report this to the user explicitly, don't let
it pass silently, `not_applicable` if the server was reused or never reached Phase 2 at all).

If this run reused an existing server (Phase 1's short-circuit), skip the `stop` calls entirely for
that service — there is no PID file for it to read in the first place.

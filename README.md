# Prompinto/agent-marketplace

Personal Claude Code plugins.

## Plugins

### clear-prep

Backs up durable memory and in-progress session state before `/clear` wipes context, then automatically restores the handoff note right after.

**Why:** `/clear` can't be triggered programmatically — only a literal keystroke fires it — so "backup then clear" can't be a single command. This plugin closes the gap: you run the backup, then `/clear` yourself, and a bundled hook silently re-surfaces what you backed up the moment the new session starts.

#### Install

```
/plugin marketplace add Prompinto/agent-marketplace
/plugin install clear-prep
```

#### Usage

1. Run `/clear-prep` before you plan to `/clear`. It reviews the session and:
   - Saves anything durable/reusable (facts, preferences, lessons) into Claude's existing memory system
   - Writes a short-lived handoff note (in-progress work, key decisions, next steps) to `<project-root>/.claude/handoff/latest.md`
2. Run `/clear` yourself — no skill or hook can do this step for you.
3. The next session picks the handoff note back up automatically via a bundled `SessionStart` hook — no need to ask for it.

To get a fully blank context with no auto-restore, delete `.claude/handoff/latest.md` before running `/clear`.

#### How it works

- `skills/clear-prep/SKILL.md` — the skill that drives the backup pass
- `hooks/hooks.json` + `hooks/session-resume-handoff.py` — a `SessionStart` hook (matcher: `clear`) that, only when the session started because of `/clear`, reads `.claude/handoff/latest.md` from the project you were in and re-injects it

### codex-stream-review

Runs a Codex CLI review as a persisted, resumable thread and signals its threadId early (on
stderr, before the round finishes) so the caller can resolve and tail that thread's own rollout
file for live progress narration; lets a follow-up round `codex exec resume` that same thread so it
reuses the diff/prior findings already in its own context instead of re-sending them.

**Why:** an ephemeral-process-per-round design has no way to see what Codex is doing until the
whole call finishes, and every round re-sends the full diff and prior findings from scratch. This
plugin trades that for a persisted, resumable thread — live progress visibility and cheaper
multi-round follow-up — at the cost of leaving a real thread and rollout file on disk that the
caller must explicitly clean up (for the raw `stream-review` skill) or that `/ccs` cleans up for
you automatically (see below).

#### Install

```
/plugin marketplace add Prompinto/agent-marketplace
/plugin install codex-stream-review
```

#### Usage

- **`codex-stream-review:ccs`** — a full Claude+Codex adversarial cross-review loop (max 20
  rounds) on a resumable thread per reviewer, so follow-up rounds are cheap (no diff re-send after
  round 1), with live progress narrated in chat as each round runs. It owns its threads' entire
  lifecycle, cleaning them up on every terminal path automatically. Supports both single-reviewer
  and parallel multi-reviewer (N concurrent,
  dimension-focused reviewers, each on its own resumable thread) modes, non-repo-artifact reviews
  (a design doc, a plan, pasted analysis text) via a throwaway isolated repo, and opt-in
  investigation-evidence capture (`--capture-evidence`) — see `skills/ccs/SKILL.md`.
- `stream-review` — the lower-level, single-reviewer building block `/ccs` is built on. Start a
  review with `--cwd` and `--focus`; continue it with `--resume <threadId>` and a follow-up-only
  `--focus` (never the diff again); clean up with `--cleanup <threadId>` once the whole review is
  done, not after every round — see `skills/stream-review/SKILL.md` for the full contract. Every
  fresh round runs `--sandbox read-only` — there is no approval-gated write capability in this
  plugin.

#### How it works

- `scripts/run-stream-review.sh` — dispatches `codex exec`/`codex exec resume --json`, captures the
  thread ID from the process's own stdout stream and immediately echoes it to stderr as
  `THREAD_ID=<uuid>` (the signal a caller uses for live tailing), then detects round completion by
  watching that same captured stdout stream for its own `turn.completed` event and reads the final
  answer directly from the file `codex exec`'s own `-o/--output-last-message` flag wrote it to.
  `--cleanup <threadId>` is a separate mode that deletes the thread via `codex delete --force`. Used
  directly by the raw `stream-review` skill above.
- `skills/stream-review/SKILL.md` — how to start, continue, and clean up a review, and the current
  safety-model status.
- `scripts/run-ccs-review.sh` — a separate wrapper `/ccs` dispatches through instead of
  `run-stream-review.sh` above: adds diff-collection/coverage logic on top of the resumable-thread
  dispatch mechanism, since `run-stream-review.sh` itself has no diff-collection capability.
- `skills/ccs/SKILL.md` — the `codex-stream-review:ccs` command: a resumable-thread Claude+Codex
  adversarial consensus loop (max 20 rounds), with automatic thread cleanup and live progress
  narrated in chat — single-reviewer or parallel multi-reviewer (each group on its own persistent
  resumable thread), non-repo-artifact reviews via a throwaway isolated repo, and opt-in
  investigation-evidence capture.

### visual-verify

Detects a web project's own dev tooling at runtime, starts (or reuses) its dev server, drives a
real Chromium browser via that project's own installed Playwright to perform a described
interaction, and captures a screenshot — for **any** web stack: React/Vue/Next/Vite/plain static,
npm/pnpm/yarn, monorepo or not. Nothing about a specific company's auth SDK, mocking library, or
port convention is hardcoded.

**Why:** verifying that a UI change actually renders correctly normally means manually starting a
dev server, opening a browser, navigating, and eyeballing it. This plugin automates that loop
end-to-end — detection, start-or-reuse, capture, cleanup — while staying honest about what it
can't do: it has no way to defeat an authentication system, no concept of any specific mock-server's
variant-switching API, and no PR/MR comment-posting step.

#### Install

```
/plugin marketplace add Prompinto/agent-marketplace
/plugin install visual-verify
```

#### Usage

```
visual-verify:verify <what to verify>
```

Give it a route/page/component and, optionally, a plain-English interaction to perform first (e.g.
`visual-verify:verify go to /settings, toggle dark mode, and confirm the page background changes`).
Leaving the task text empty does **not** default to "review recent work" (unlike `/ccs`) — the
skill asks you directly what to verify instead, since a wrong guess here means driving a real
browser against the wrong target.

#### How it works

- `scripts/detect-env.sh` — read-only detection: package manager/lockfile, monorepo shape, the
  dev-server script and its port/host (parsed from the command's own flags, else a best-effort
  framework-default guess — never assumed correct until a real health-check confirms it), an
  auxiliary mock/API service if the repo's own scripts imply one, whether `@playwright/test`/
  `playwright` is installed and where, whether a matching Chromium build is cached, and a generic
  (disclosure-only) auth-gate heuristic. Never writes, installs, or starts anything.
- `scripts/lifecycle.sh` — starts a detected dev command via `nohup`/`disown` with its PID written
  to a session-scoped file immediately, health-checks a host:port with a bounded polling loop (no
  fixed `sleep`), and stops a service by reading back that same PID file — **never** by
  `lsof -ti:<port> | xargs kill`, which risks killing an unrelated process on the same port. A
  service this run didn't start (the "reuse an already-running server" path) has no PID file for
  this run, so `stop` correctly leaves it alone.
- `skills/verify/SKILL.md` — the `visual-verify:verify` skill: five phases (resolve task → detect
  → start/reuse → drive browser & capture → report & clean up). Claude writes the actual Playwright
  interaction code per run directly from the task description's prose — no fixed scenario grammar
  to learn or maintain.
- `schemas/verify-result.schema.json` — the structured result artifact written to
  `~/.claude/plugins/data/visual-verify/logs/<repo-slug>/<session_id>.result.json` after every run:
  target, detection findings, server reuse/start mode + PIDs, the scenario used, screenshot path,
  outcome, and cleanup status.

#### Out of scope (by design, not an oversight)

- **No auth-bypass.** If a target route is gated behind login/permissions, the captured screenshot
  may show a login/forbidden page — the auth-gate heuristic only discloses this, never bypasses it.
- **No mock-server variant switching** or fixture patching for any specific mocking library.
- **No GitHub/GitLab/any VCS comment posting.** Capture and report stay local.
- **No custom scenario DSL.** Interactions are described in prose in the task text; there's no fixed
  syntax to learn.
- **macOS-only auto-open** of the captured screenshot (`open <path>`) — other OSes get the path
  printed instead, not an auto-open attempt.

## Contributing

`main` is protected — changes go through a pull request.

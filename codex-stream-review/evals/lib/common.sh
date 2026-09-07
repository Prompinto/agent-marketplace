#!/usr/bin/env bash
# Shared helpers for eval scenario setup scripts. Source this, don't execute
# it directly: `source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"`
# (adjust the relative path from within a scenario's own setup.sh).
set -uo pipefail

# eval_resolve_install_path -- prints the installed codex-stream-review
# plugin's own root dir, the same way SKILL.md's Phase 0 step 2 resolves it.
eval_resolve_install_path() {
  jq -j '.plugins["codex-stream-review@agent-marketplace"][] | select(.scope=="user") | .installPath' \
    ~/.claude/plugins/installed_plugins.json
}

# eval_make_fixture_repo <name> -- creates a throwaway git repo under /tmp
# with a real initial commit plus one uncommitted change, ready to be
# reviewed via --uncommitted. Prints the repo path.
eval_make_fixture_repo() {
  local name="${1:-eval}"
  local dir
  dir="$(mktemp -d "/tmp/ccs-eval-${name}.XXXXXX")"
  git -C "$dir" init -q
  git -C "$dir" config user.email "eval@example.com"
  git -C "$dir" config user.name "ccs-eval"
  printf 'def add(a, b):\n    return a + b\n' > "$dir/lib.py"
  git -C "$dir" add lib.py
  git -C "$dir" commit -q -m "initial"
  printf 'def add(a, b):\n    # deliberate off-by-one for eval fixtures\n    return a + b + 1\n' > "$dir/lib.py"
  echo "$dir"
}

# eval_inject_fake_codex -- prepends a fake `codex` binary (this project's
# own tests/fixtures/fake-codex, already used by test-run-ccs-review.sh) onto
# $PATH for the rest of this shell, so any run-ccs-review.sh dispatch in this
# process (or a child it spawns) resolves the fake, never a real Codex
# backend. Scenarios that need a REAL Codex judgment (parallel-mode content
# review, claim-ledger semantic re-raise judgment) must NOT call this.
eval_inject_fake_codex() {
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local fake_codex="$repo_root/tests/fixtures/fake-codex"
  local bin_dir
  bin_dir="$(mktemp -d)"
  ln -s "$fake_codex" "$bin_dir/codex"
  export PATH="$bin_dir:$PATH"
}

# eval_make_fixture_repo_sized <name> <extra_untracked_count> -- like
# eval_make_fixture_repo, but for Group E (parallel-mode) scenarios that need
# to cross parallel-mode.md's own "20-50 files -> 2-3 groups" medium-scope
# sizing threshold. One initial commit (lib.py), then as the UNCOMMITTED
# change: lib.py is modified (1 tracked file) AND <extra_untracked_count> new
# untracked stub files are created -- Phase 1's own sizing count (tracked
# --name-only + untracked ls-files, deduplicated) totals
# 1 + extra_untracked_count files. Prints the repo path.
eval_make_fixture_repo_sized() {
  local name="${1:-eval}"
  local extra="${2:-23}"
  local dir
  dir="$(mktemp -d "/tmp/ccs-eval-${name}.XXXXXX")"
  git -C "$dir" init -q
  git -C "$dir" config user.email "eval@example.com"
  git -C "$dir" config user.name "ccs-eval"
  printf 'def add(a, b):\n    return a + b\n' > "$dir/lib.py"
  git -C "$dir" add lib.py
  git -C "$dir" commit -q -m "initial"
  printf 'def add(a, b):\n    # deliberate off-by-one for eval fixtures\n    return a + b + 1\n' > "$dir/lib.py"
  local i
  for ((i = 1; i <= extra; i++)); do
    printf 'def stub_%d():\n    return %d\n' "$i" "$i" > "$dir/stub_${i}.py"
  done
  echo "$dir"
}

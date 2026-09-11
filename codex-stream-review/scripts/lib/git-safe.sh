#!/usr/bin/env bash
# git_safe: run every git call that reads a target repo's diff/show content
# through a pre-resolved, absolute git binary under a minimal `env -i`
# allowlist, anchored to $CWD via `-C` (never a bare `cd`).
#
# GIT_BIN is resolved ONCE, here, at source time -- in the sourcing script's
# own trusted startup environment (this is not attacker-influenceable review
# content, it's how the wrapper itself starts) -- then always invoked by
# this absolute path, never a bare `git` name looked up again inside the
# sanitized environment. This is what actually stops a hostile PATH set
# *after* sourcing (e.g. by something the reviewed repo's content could
# reach) from redirecting execution to a decoy `git`: `env -i "PATH=$PATH"`
# alone would NOT do this, since env -i only starts from an empty
# environment and then re-admits exactly whatever PATH is handed to it --
# it does nothing to stop that value itself from being poisoned.
GIT_BIN="$(command -v git)"

# `command -v` does not guarantee an absolute result: an exported shell
# FUNCTION named `git` reports back as the bare name `git` (unlike `type`),
# and a relative PATH entry resolves to a relative path -- either way,
# `env -i` below would not retroactively fix it, since it only isolates the
# environment `$GIT_BIN` runs in, not what `$GIT_BIN` itself points to.
# Fail loudly as a well-formed bad_args JSON response (this file is sourced
# before run-ccs-review.sh's own argument parsing even starts, so this is
# the earliest point such a response can be emitted) rather than letting a
# non-absolute value silently reach `git_safe()` below.
case "$GIT_BIN" in
  /*) ;;
  *)
    GIT_BIN_DETAIL_JSON="$(printf '%s' "$GIT_BIN" | jq -Rs '"git resolved to a non-absolute path: " + .')"
    printf '{"ok":false,"reason":"bad_args","detail":%s}\n' "$GIT_BIN_DETAIL_JSON"
    exit 1
    ;;
esac

# git_safe SUBCOMMAND [ARGS...]
#
# Requires the caller to have set $CWD (the target repo) and $SAFE_GIT_HOME
# (an isolated, empty per-run directory used as HOME so neither the
# invoking user's nor any global ~/.gitconfig is honored) before calling.
#
# - `env -i` + a fixed, literal PATH: strips every inherited environment
#   variable, including GIT_DIR/GIT_WORK_TREE and git's own "command scope"
#   config-injection vars (GIT_CONFIG_COUNT/GIT_CONFIG_KEY_N/...), which
#   otherwise override `-C`/`cd` regardless of anything else. A dynamic
#   `git rev-parse --local-env-vars`-driven unset loop is NOT needed here:
#   that idiom exists only for contexts that must probe-then-unset inside
#   an already-running, already-polluted shell (see ccs/SKILL.md) -- here,
#   `env -i` already guarantees nothing else survives before git even
#   starts.
# - `HOME=$SAFE_GIT_HOME` + `GIT_CONFIG_NOSYSTEM=1`: closes the global
#   (~/.gitconfig) and system (/etc/gitconfig) config layers.
# - `-c core.fsmonitor=`: the one thing environment/config-variable
#   sanitization alone cannot reach -- a target repo's own TRACKED, local
#   `.git/config` can still declare a hook-shaped command (e.g.
#   `core.fsmonitor`) that git will happily execute regardless of how clean
#   the surrounding environment is. Paired with the `--no-ext-diff
#   --no-textconv` flags already present on every diff/show call site,
#   which close the same class of gap for external diff/textconv drivers.
git_safe() {
  env -i "PATH=/usr/bin:/bin" "HOME=$SAFE_GIT_HOME" "GIT_CONFIG_NOSYSTEM=1" \
    "$GIT_BIN" -C "$CWD" -c core.fsmonitor= "$@"
}

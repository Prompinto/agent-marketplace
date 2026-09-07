#!/usr/bin/env bash
# Convenience runner for codex-stream-review/evals/ scenarios.
#
# THIS IS A TWO-PHASE TOOL, NOT A SINGLE FULLY-AUTOMATED COMMAND -- and
# structurally can't be one. A scenario run means actually driving the
# codex-stream-review:ccs SKILL through a real, multi-round Claude+Codex-
# style conversation: an LLM agent interpreting skills/ccs/SKILL.md's prose
# and making the same judgment calls (retry-by-failure-reason branches,
# convergence checks, claim-ledger dispositions) a real run makes. No bare
# shell script can do that part -- only a live Claude Code agent (or a
# human) can. What this script CAN do:
#   Phase 1 (this script, scenario name only): run that scenario's own
#     setup.sh, which creates the fixture repo/artifact and prints exactly
#     what to do next -- the task text to give codex-stream-review:ccs, and
#     any FAKE_CODEX_* / PATH setup that run needs.
#   Phase 2 (this script, scenario name + a .result.json path): once a human
#     or agent has actually run that live session per Phase 1's printed
#     instructions and located the resulting .result.json, hand it to this
#     script to run check-result.sh against it.
#
# Usage:
#   run-evals.sh --help
#   run-evals.sh <scenario-name>                    # Phase 1: setup + instructions
#   run-evals.sh <scenario-name> <result.json>       # Phase 2: validate a completed run
#
# There is no "run everything" mode and no --repeat flag here, for the same
# structural reason: neither can be scripted without a live agent driving
# each individual run. For aggregating a consistency rate across N such
# already-produced .result.json files from repeated manual/live runs, see
# check-consistency.sh instead. See codex-stream-review/evals/README.md for
# the full scenario index, the PATH-per-call mechanical caveat every
# scenario's own README repeats, and why this harness is not part of
# push/PR-triggered CI.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  run-evals.sh --help
  run-evals.sh <scenario-name>
  run-evals.sh <scenario-name> <result.json>

Phase 1 (scenario name only): runs scenarios/<name>/setup.sh, which creates
the fixture repo/artifact and prints the exact task text and env/PATH setup
needed for a live codex-stream-review:ccs run -- to be carried out by a
Claude Code agent (or by hand) immediately after, following
skills/ccs/SKILL.md's own phases for real.

Phase 2 (scenario name + a .result.json path): once that live run has
completed and produced a
~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>.result.json
file, pass its path here to validate it against the schema and this
scenario's own scenarios/<name>/expect.sh assertions (equivalent to calling
check-result.sh directly).

Available scenario names (those with a setup.sh under scenarios/):
EOF
  for d in "$SCRIPT_DIR"/scenarios/*/; do
    [ -f "$d/setup.sh" ] && basename "$d"
  done
  echo
  echo "See codex-stream-review/evals/README.md for the full ~28-scenario index (most are"
  echo "specified there but not yet built -- only the ones listed above have a setup.sh today)."
}

if [ $# -eq 0 ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

SCENARIO="$1"
SCENARIO_DIR="$SCRIPT_DIR/scenarios/$SCENARIO"

if [ ! -d "$SCENARIO_DIR" ] || [ ! -f "$SCENARIO_DIR/setup.sh" ]; then
  echo "run-evals.sh: no such scenario (missing scenarios/$SCENARIO/setup.sh)" >&2
  echo "Run 'run-evals.sh --help' for the list of available scenario names." >&2
  exit 1
fi

if [ $# -ge 2 ]; then
  RESULT_JSON="$2"
  echo "run-evals.sh: Phase 2 -- validating a completed '$SCENARIO' run"
  exec bash "$SCRIPT_DIR/check-result.sh" "$RESULT_JSON" "$SCENARIO"
fi

echo "run-evals.sh: Phase 1 -- setting up scenario '$SCENARIO'"
echo "(see scenarios/$SCENARIO/README.md for full context/expected-result detail)"
echo
bash "$SCENARIO_DIR/setup.sh"
echo
echo "Once the live codex-stream-review:ccs run above has completed and you have located its"
echo ".result.json, validate it with:"
echo "  bash \"$SCRIPT_DIR/run-evals.sh\" $SCENARIO <path-to-result.json>"

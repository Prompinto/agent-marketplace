#!/usr/bin/env bash
# Scenario: near-limit-whitespace-performance
# Regression guard (not in the original ~28-scenario matrix): confirms
# run-ccs-review.sh's `_focus_is_empty()` fix (tr -d '[:space:]', replacing
# the old catastrophically-superlinear bash `${var//[[:space:]]/}`
# substitution -- see this repo's own README.md "A real bug this harness
# already found (and fixed)" section) genuinely handles a large,
# whitespace-dense focus text quickly, not just a large diff.
#
# Builds a deliberately whitespace-dense, ~90000-byte FOCUS text -- the exact
# input shape the old bug choked on (a ~6KB whitespace-heavy string took ~13s
# under the old bash-substitution implementation; a larger whitespace-heavy
# focus file would have hung for hours). The wrapper's pre-dispatch prompt
# byte-size preflight this fixture's size was originally sized relative to
# (131072 bytes) has since been removed entirely; this scenario's own target
# -- the whitespace-stripping performance fix -- is independent of that and
# unaffected by its removal, so the fixture size is unchanged. Dispatches it
# with a generous but bounded --timeout (60s, comfortably above normal
# dispatch variance, nowhere near the old bug's hours-order-of-magnitude
# hang) and records real wall-clock time as a regression guard (must land
# well under 30s).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(eval_make_fixture_repo near-limit-whitespace-performance)"
BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"

# ~90000 bytes total: a short real Why/Scope preamble, then dense
# whitespace filler (runs of spaces/tabs/newlines) with sparse real words
# interspersed so the content is never mistaken for empty/whitespace-only
# (which would be rejected with bad_args before ever reaching the perf
# path this scenario targets). This is a test of the input SHAPE the old bug
# choked on, not of any byte-size boundary (the wrapper's former pre-dispatch
# size preflight has been removed entirely -- there is no boundary left to
# test).
FOCUS_REFERENCE_FILE="$(mktemp "/tmp/ccs-eval-near-limit-whitespace-focus.XXXXXX")"
python3 -c "
import random
random.seed(42)
out = []
out.append('Why: regression guard for the fixed _focus_is_empty() whitespace-stripping performance bug.\n')
out.append('Scope: this fixture repo only.\n\n')
words = ['note', 'context', 'observe', 'detail', 'aside', 'remark']
target = 90000
while sum(len(x) for x in out) < target:
    filler = ('word' if random.random() < 0.05 else '')
    if filler:
        out.append(random.choice(words))
    out.append(' ' * random.randint(1, 40))
    if random.random() < 0.3:
        out.append('\n' * random.randint(1, 5))
    if random.random() < 0.2:
        out.append('\t' * random.randint(1, 8))
text = ''.join(out)
with open('$FOCUS_REFERENCE_FILE', 'w') as f:
    f.write(text[:target])
"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "FAKE_CODEX_SCENARIO=normal"
echo "FOCUS_REFERENCE_FILE=$FOCUS_REFERENCE_FILE"
echo "focus reference size: $(wc -c < "$FOCUS_REFERENCE_FILE") bytes (diff is tiny)"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR, with BIN_DIR
prepended to PATH and FAKE_CODEX_SCENARIO=normal on the dispatch call (see
codex-stream-review/evals/README.md's "Mechanical caveat"). Task text:
"review the uncommitted change in this fixture repo".

When writing this round's FOCUS_FILE (SKILL.md Phase 1 Step 0), use EXACTLY
FOCUS_REFERENCE_FILE's own content (copy it verbatim, still via the Write
tool per the skill's own sentinel-idiom section) -- this IS the fixture
under test, deliberately whitespace-dense. Pass --timeout 60 explicitly on
the dispatch call
(generous but bounded -- comfortably above normal variance, nowhere near
the old bug's hours-order-of-magnitude hang). Record real wall-clock time
around the dispatch call (e.g. `date +%s` immediately before and after).

Expected: the dispatch completes normally (ok:true, CLEAN, no findings) well
within the 60s timeout -- confirm the ACTUAL wall-clock elapsed time is well
under 30s (this is the regression guard: the old bug would have made this
input shape hang for hours). exit_state CLEAN, round_count 1, one thread
kind:current cleanup:deleted (FAKE_CODEX_CLEANUP_OK=1 on the Phase 3
--cleanup call).
EOF

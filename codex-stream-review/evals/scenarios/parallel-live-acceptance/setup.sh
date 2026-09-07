#!/usr/bin/env bash
# Scenario: parallel-live-acceptance
# Targets: a REAL Codex judgment, real parallel dispatch -- not a scripted fake-codex transcript.
# Per prior negotiation (see the task brief this scenario was built from): a TINY 2-file fixture,
# one file per dimensional group, each with ONE independently-verifiable, OBJECTIVE defect stated
# as a documented local requirement in a comment immediately next to the code that violates it --
# something a real Codex reviewer can confirm by reading the adjacent ~5 lines, not organic broad
# discovery across a large diff. NO fake-codex PATH injection for this scenario -- the real `codex`
# CLI must be on $PATH, unmodified.
#
# Sizing judgment call (flagged, per this task's own instructions): a 2-file diff is well inside
# parallel-mode.md's own "<20 files -> single reviewer" tier by raw file count alone. Parallel
# dispatch is deliberately used here anyway under that same reference's own "flexible judgment"
# carve-out ("the task spans multiple unrelated concerns worth distinct reviewer attention") --
# this fixture has two genuinely distinct concerns (correctness vs. security) by deliberate
# construction, one per file, specifically to exercise real concurrent multi-group dispatch and
# convergence with a real Codex backend. Do not treat this as evidence that a 2-file diff should
# normally trigger parallel mode -- it should not, per the sizing table's own default.
set -euo pipefail

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-parallel-live-acceptance.XXXXXX")"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "eval@example.com"
git -C "$REPO_DIR" config user.name "ccs-eval"
printf '# fixture repo for parallel-live-acceptance\n' > "$REPO_DIR/README.md"
git -C "$REPO_DIR" add README.md
git -C "$REPO_DIR" commit -q -m "initial"

cat > "$REPO_DIR/file_a.py" <<'PYEOF'
def clamp_nonnegative(x):
    # REQUIREMENT: this function must raise ValueError for negative input; it must never
    # silently coerce a negative value to a non-negative one.
    return abs(x)
PYEOF

cat > "$REPO_DIR/file_b.py" <<'PYEOF'
import logging


def authenticate(username, password):
    # REQUIREMENT: never log the raw password value; only log that a login attempt occurred
    # (e.g. the username, never the password itself, in any form).
    logging.info("login attempt: user=%s password=%s", username, password)
    return username == "admin" and password == "hunter2"
PYEOF

echo "REPO_DIR=$REPO_DIR"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs against REPO_DIR with the REAL `codex` CLI on PATH
(no fake-codex injection, no FAKE_CODEX_* env vars for this scenario). Task text: "review the
uncommitted change in this fixture repo".

Expected sizing: 2 files is well inside the "small, single reviewer" tier by raw count -- per
this file's own header comment, deliberately dispatch 2 parallel groups anyway under
parallel-mode.md's "multiple unrelated concerns" judgment carve-out: g1's --focus emphasizes
CORRECTNESS (should naturally find file_a.py's violated requirement -- clamp_nonnegative()
returns abs(x) instead of raising ValueError for negative input, contradicting the comment
immediately above it), g2's --focus emphasizes SECURITY (should naturally find file_b.py's
violated requirement -- authenticate() logs the raw password, contradicting the comment
immediately above it). Both groups still review the IDENTICAL full 2-file diff, per
parallel-mode.md's own design -- the dimension text is what differs.

This is a REAL Codex judgment call with NO scripted verdict -- do not assume in advance which
round it converges on, or the exact wording of any finding. Follow SKILL.md's real Phase 1/2/3
procedure genuinely: verify each real finding by reading the actual file, fix each real defect
for real (raise ValueError in file_a.py, redact the password in file_b.py's log call), request
disposition confirmations per claim-ledger.md's real rules, and let the session converge (or
genuinely fail to) on its own.

Expected: a genuine SEMANTIC terminal state -- CLEAN (both real defects found, fixed, and
confirmed resolved) or NOT_CONVERGED (a real, evidence-based disagreement survives) are both
acceptable outcomes for this scenario. COULD_NOT_VERIFY, PARTIAL_COVERAGE, or either integrity-
failure state are NOT acceptable -- those mean the scenario itself broke operationally, not that
it validated real judgment; if any of those occurs, treat it as a scenario failure to debug, not
a result to report as passing. Clean up every real Codex thread (both groups) at the end
regardless of outcome -- no fake-codex here, so no FAKE_CODEX_CLEANUP_OK is needed or applicable;
the real `codex delete --force` call must succeed for real.
EOF

#!/usr/bin/env bash
# Scenario: no-material-reviewed-fresh-restart
# Targets: confirms references/retry-guards.md's no_material_reviewed recovery genuinely reuses
# references/compaction.md's COMPLETE restart mechanism (digest carryforward + snapshot-integrity
# revalidation) -- not a lighter reinvented version -- by establishing one real RESOLVED claim and
# one real still-OPEN claim across a real multi-round session, THEN triggering
# no_material_reviewed, THEN confirming the fresh restart's own new-thread seed genuinely carries
# that digest forward (the open claim verbatim, the resolved claim collapsed to its one-line
# DISPOSITION reason).
#
# This is a FOUR-dispatch scenario against a SINGLE fixture repo whose uncommitted diff carries
# TWO real bugs, so there are two distinct claims to track:
#   Round 1 (fresh, thread A):    ISSUES, f1 (add() off-by-one) + f2 (sub() off-by-one), both real.
#   Round 2 (--resume, thread A): f1 is fixed for real between rounds; DISPOSITION f1: RESOLVED
#                                 closes it. f2 is left broken and unmentioned -- it stays open
#                                 (claim-ledger.md's "When to ask" condition (a) does not fire for
#                                 it yet, since f2 was still an actively-disputed, currently-
#                                 appearing finding in round 1, the round evaluated at round 2's
#                                 own construction time).
#   Round 3 attempt (--resume, thread A): scripted no_material_reviewed (wrapper route:
#                                 material_reviewed:false with a nonempty ISSUES array, mirroring
#                                 material-reviewed-false-never-resumed's own Task-12 design) --
#                                 thread A is abandoned, never resumed again.
#   Restart (fresh, thread B):    the live driving agent constructs COMPACT_DIGEST from the
#                                 durable JSONL log's own reducer state (references/compaction.md's
#                                 "Digest construction and verification" section, reused as-is,
#                                 per retry-guards.md), carrying f1's one-line RESOLVED reason and
#                                 f2's full verbatim finding forward into the fresh thread's own
#                                 seed. f2 is fixed for real at this point too; the restart's own
#                                 scripted response closes it (DISPOSITION f2: RESOLVED), so the
#                                 session converges CLEAN at round 3 (the restart occupies round
#                                 3's own slot -- rounds 1-2 already produced valid results, so
#                                 this is NOT a round-1-style "hollow attempt never produced a
#                                 valid round-1 result" case; see retry-guards.md's own "REGARDLESS
#                                 of what session round number it occurs at" language).
#
# Like material-reviewed-false-never-resumed and receipt-mismatch-phase2-reject, this setup.sh
# deliberately does NOT pre-generate any receipt schedule or pre-populate any GROUP_STATE
# round-N-final-answer.json file -- every receipt schedule (thread A's at round 1, thread B's at
# the restart) and every scripted response embedding a receipt value must be constructed LIVE, by
# whatever agent is actually driving the /ccs session, at the exact point SKILL.md's own
# procedure calls for it. A schedule or answer file pre-baked by this script would be
# illustrative-instructions authorship, not evidence that a live orchestrating agent's own real
# procedure produced it -- see this scenario's README for the full live-verification narrative.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_DIR="$(mktemp -d "/tmp/ccs-eval-no-material-reviewed-fresh-restart.XXXXXX")"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "eval@example.com"
git -C "$REPO_DIR" config user.name "ccs-eval"
printf 'def add(a, b):\n    return a + b\n' > "$REPO_DIR/lib.py"
git -C "$REPO_DIR" add lib.py
git -C "$REPO_DIR" commit -q -m "initial"
printf 'def add(a, b):\n    # deliberate off-by-one for eval fixtures\n    return a + b + 1\n\n\ndef sub(a, b):\n    # deliberate off-by-one for eval fixtures\n    return a - b - 1\n' > "$REPO_DIR/lib.py"

BIN_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
INVOCATION_LOG="/tmp/ccs-eval-no-material-reviewed-fresh-restart-invocation.log"
: > "$INVOCATION_LOG"
GROUP_STATE_DIR="$(mktemp -d)"

echo "REPO_DIR=$REPO_DIR"
echo "BIN_DIR=$BIN_DIR"
echo "INVOCATION_LOG=$INVOCATION_LOG"
echo "GROUP_STATE_DIR=$GROUP_STATE_DIR"
cat <<'EOF'

Next step: invoke codex-stream-review:ccs (the real Skill tool, or -- if that does not run inline
in your own tool-call loop -- a faithful manual walkthrough of SKILL.md's own Phase 0-3 procedure
in the real order) against REPO_DIR, with BIN_DIR prepended to PATH on EVERY Bash call made during
this run, and FAKE_CODEX_INVOCATION_LOG set to the printed INVOCATION_LOG path, and
FAKE_CODEX_GROUP_STATE set to the printed GROUP_STATE_DIR path, on every dispatch/cleanup call.
FAKE_CODEX_SCENARIO must ALSO be set explicitly on every dispatch call (normal for rounds 1, 2,
and the restart; schema_mismatch for round 3's own hollow attempt) -- GROUP_STATE only overrides
FINAL_ANSWER content, never the scenario branch itself. Task text: "review the uncommitted change
in this fixture repo".

lib.py's real uncommitted diff carries TWO genuine bugs: add() returns a + b + 1 (line 3) and
sub() returns a - b - 1 (line 8, a brand-new function relative to the committed baseline, which
only has add()).

Round 1 (fresh --uncommitted, thread A): generate thread A's own RECEIPT_SCHEDULE_FILE live
(SKILL.md's exact mktemp + 70-iteration shasum -a 256 loop), durably record its PENDING
receipt_issued line, then dispatch with --receipt-schedule-file <A's schedule>
--receipt-slot 1. Before dispatching, write GROUP_STATE_DIR/round-0-final-answer.json yourself,
live, with jq (never hand-interpolated), embedding slot 1's own real token off A's schedule:
  {"verdict":"ISSUES","findings":[
    {"file":"lib.py","line":3,"severity":"medium","summary":"add() returns a+b+1, an off-by-one error","evidence":"<cite the real line 3 text>","verification":"..."},
    {"file":"lib.py","line":8,"severity":"medium","summary":"sub() returns a-b-1, an off-by-one error","evidence":"<cite the real line 8 text>","verification":"..."}
  ],"summary":null,"dimensions":{...},"material_reviewed":true,"material_receipt":"<A's real slot-1 token>","material_receipt_index":1}
Expected: ok:true, ISSUES, real threadId (A) captured, receipt genuinely matches slot 1 -- accepted
normally (findings f1, f2 both real, both accepted).

Between round 1 and round 2: actually edit REPO_DIR/lib.py to fix f1 for real (remove the "+ 1"
from add()) -- leave sub() broken. Per claim-ledger.md's "When to ask" condition (b), round 2's own
focus text must explicitly name claim_id f1 and request a DISPOSITION marker; f2 is NOT asked
about yet (condition (a) does not apply -- f2 was still an actively-disputed, currently-appearing
finding in round 1, the round evaluated at this construction point).

Round 2 (--resume thread A, no --receipt-schedule-file): issue slot 2 for thread A, durably record
it, THEN write GROUP_STATE_DIR/round-1-final-answer.json live with slot 2's real token:
  {"verdict":"CLEAN","findings":[],"summary":"DISPOSITION f1: RESOLVED -- <real reason citing the current file>","dimensions":{...},"material_reviewed":true,"material_receipt":"<A's real slot-2 token>","material_receipt_index":2}
Expected: ok:true, receipt matches slot 2, DISPOSITION f1: RESOLVED parsed and closes f1. Because
f2 has no claim_closures entry, the claim-ledger-closure convergence condition still fails even
though Codex's own verdict says CLEAN -- the loop continues to round 3 (this is NOT a
"NOT CONVERGED" oscillation stop; it is an ordinary "keep going" continuation, since no open claim
was ever reasserted with evidence_delta:"none").

Round 3's own original focus text (before it goes hollow), evaluated against round 2 (the most
recently completed round): f2 did NOT appear in round 2's findings, so condition (a) now fires --
this round's focus must explicitly name f2 and request its own DISPOSITION marker too.

Round 3 attempt (--resume thread A): the SAME round-2+ snapshot revalidation that always runs
first passes (nothing has touched SNAPSHOT_FILE). Issue slot 3 for thread A, durably record it,
THEN write GROUP_STATE_DIR/round-2-final-answer.json live -- this one is the scripted hollow
response, its receipt value never matters since the wrapper's own material_reviewed:false check
rejects it before Phase 2 receipt validation ever runs:
  {"verdict":"ISSUES","findings":[{"file":"lib.py","line":6,"severity":"low","summary":"fabricated finding that must never leak into the session JSONL","evidence":"e","verification":"v"}],"summary":null,"dimensions":{...},"material_reviewed":false,"material_receipt":null,"material_receipt_index":null}
For THIS dispatch only, set FAKE_CODEX_SCENARIO=schema_mismatch.
Expected: ok:false, reason schema_mismatch, detail carries the literal substring
"no_material_reviewed" -- references/retry-guards.md's no_material_reviewed rule fires: thread A
is added to LEAKED_THREAD_IDS, never resumed again. This hollow attempt is never separately
persisted to the session's own JSONL log (no round==3 line for it) -- only the eventual restart's
own successful round is.

Restart (fresh --uncommitted, thread B -- NEVER --resume): before dispatching, build
COMPACT_DIGEST via references/compaction.md's own "Digest construction and verification"
procedure, reused as-is per retry-guards.md -- reconstruct the open-claim-id list from the
session's own durable JSONL log (structured data first: the reducer's open set is {f2}, since f1
has a claim_closures entry and f2 does not), resolve f2's most-recent-occurrence fields (its only
occurrence is round 1's own finding: file lib.py, line 8, severity medium, the real
summary/evidence text), verify structurally (key check + content-completeness check) BEFORE
rendering any prose, then render: a CLOSED CLAIMS section with f1's own one-line
claim_closures[].marker_reason, and an OPEN CLAIM f2 block (file/line/severity/summary/evidence
verbatim, unabridged, plus the most recent claude_verification action/rationale for it). Focus
text order matches compaction.md's own Restart-mechanism Step 4: (1) COMPACT_DIGEST, (2) the
original Why/Scope read from target.original_scope_framing (never target.focus), (3) the standard
SCOPE CONSTRAINT block, (4) the same fixed collaboration-frame sentence, (5) a DISPOSITION request
for f2 (still open, evaluated against thread A's own most recently completed round -- round 2).

Generate thread B's own SEPARATE, freshly-mktemp'd RECEIPT_SCHEDULE_FILE live (never reusing A's),
durably record its PENDING receipt_issued line, THEN write GROUP_STATE_DIR/round-3-final-answer.json
live with slot 1's real token off B's schedule. Actually edit REPO_DIR/lib.py to fix f2 for real
too (remove the "- 1" from sub()) before dispatching:
  {"verdict":"CLEAN","findings":[],"summary":"DISPOSITION f2: RESOLVED -- <real reason citing the current file>","dimensions":{...},"material_reviewed":true,"material_receipt":"<B's real slot-1 token>","material_receipt_index":1}
Dispatch with --receipt-schedule-file <B's schedule> --receipt-slot 1.
Expected: ok:true, a NEW real threadId (B), receipt genuinely matches slot 1 of B's OWN schedule,
DISPOSITION f2: RESOLVED parsed and closes f2. Both f1 and f2 now have terminal dispositions, and
this round is genuinely a fresh --uncommitted dispatch reporting its own coverage_source
-- convergence holds. Session reaches CLEAN at round 3 (the restart occupies round 3's own slot,
never round 1's -- rounds 1-2 already produced valid results before thread A went hollow).

Set FAKE_CODEX_CLEANUP_OK=1 on both Phase 3 --cleanup calls (thread B first as the current
thread, then thread A as the leaked one, matching this project's own established cleanup-ordering
convention).

Expected result: exit_state CLEAN, round_count 3, threads: one "leaked" (A) + one "current" (B),
both cleanup:"deleted"; claims: two entries, f1 resolved at round 2 and f2 resolved at round 3;
coverage status "complete". Confirm from the session's own durable JSONL log: exactly 3
round-bearing lines (rounds 1, 2, 3 -- never a 4th for round 3's own hollow attempt); round 3's own
target.focus contains BOTH f1's one-line RESOLVED reason AND f2's full verbatim
summary/evidence text -- never a blank or reset digest; the invocation log shows exactly 2
mode=fresh lines (A then B, distinct thread ids) and exactly 2 mode=resume lines (both to A, never
to B).
EOF

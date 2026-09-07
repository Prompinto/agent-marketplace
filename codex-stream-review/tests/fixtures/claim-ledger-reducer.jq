# Implements the claim-ledger reducer described in
# codex-stream-review/skills/ccs/references/claim-ledger.md section 8:
# "for each distinct claim_id seen so far via claude_verification[].claim_id
# across all prior rounds, its status is open unless some prior round's
# claim_closures[] contains an entry for it, in which case its status is
# that entry's disposition. Its most recent evidence_delta (when present --
# omitted on a claim's first appearance) is whatever the LATEST
# claude_verification[] entry for that claim_id recorded."
#
# Input (stdin/file, via `jq -n -c -f this.jq <file>`): a JSONL log, one
# round object per line, each optionally holding claude_verification[] and
# claim_closures[] (exactly the round-line shape in SKILL.md's "Review
# history log" section).
#
# Output: one compact JSON object per line, one per distinct claim_id:
# {claim_id, status, evidence_delta} -- evidence_delta is null when the
# claim's latest occurrence never recorded one (e.g. a claim that only ever
# appeared once).

[inputs] as $rounds
| ($rounds | map(.claude_verification // []) | add // []) as $verifications
| ($rounds | map(.claim_closures // []) | add // []) as $closures
| ($verifications | group_by(.claim_id) | map(.[-1])) as $latest_per_claim
| $latest_per_claim[]
| . as $v
| ($closures | map(select(.claim_id == $v.claim_id)) | last) as $closure
| {
    claim_id: $v.claim_id,
    status: (if $closure == null then "open" else $closure.disposition end),
    evidence_delta: ($v.evidence_delta // null)
  }

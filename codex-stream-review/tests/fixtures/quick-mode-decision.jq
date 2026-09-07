# Implements the "canonical current severity" lookup + MINOR_ISSUES_ACKNOWLEDGED eligibility
# decision described in codex-stream-review/skills/ccs/SKILL.md's Guards section ("Quick-mode
# early stop -- MINOR ISSUES ACKNOWLEDGED"):
#
# "CANONICAL CURRENT SEVERITY for a claim_id = the severity value recorded on that claim_id's own
# MOST RECENT occurrence as a finding, across every round's own codex_review.findings[] so far...
# except taking the LAST matching round rather than the FIRST" (unlike Phase 3's own .result.json
# claims[] join, which intentionally reports each claim's ORIGIN severity).
#
# "does EVERY still-open claim_id's CANONICAL CURRENT SEVERITY equal exactly LOW or MEDIUM? ...
# MISSING -- no finding ever recorded a severity value for that claim_id at all -- treat exactly
# like a value that fails the LOW/MEDIUM test... UNPARSEABLE -- that claim's own most-recent
# recorded severity value is a string that doesn't literally match (case-insensitively)
# LOW/MEDIUM/HIGH/CRITICAL."
#
# Input (stdin/file, via `jq -n -c -f this.jq <file>`): a JSONL log, one round object per line,
# each optionally holding codex_review.findings[] (each with "id"/"severity" and, for a parallel
# round, a sibling "group" field -- the same round-line shape SKILL.md's "Review history log"
# section documents), claude_verification[] (reused as-is from claim-ledger-reducer.jq's own
# open/closed logic) and claim_closures[]. Parallel-mode findings are joined using the EXACT SAME
# key expression documented verbatim in SKILL.md's Phase 3 "claims" construction and already
# extracted in tests/fixtures/claim-key-from-finding.jq:
# `if (.group? | type) == "string" then (.group + ":" + .id) else .id end` -- never a raw finding
# whose own "id" field is assumed to already BE the group-prefixed form (a real aggregated finding
# keeps "id" and "group" as separate fields; only claim_id/finding_id values recorded in
# claude_verification[] are ever group-prefixed strings like "g1:f3").
#
# Output: one compact JSON object per distinct claim_id -- {claim_id, status, canonical_severity}
# (canonical_severity is null when no finding ever recorded one for that claim_id -- the MISSING
# subcase) -- followed by exactly one final line, the aggregate decision:
# {decision, open_count, open_claim_ids, escalated}. `decision` is "MINOR_ISSUES_ACKNOWLEDGED" only
# when open_count > 0 AND every open claim's own canonical_severity is exactly "low" or "medium"
# (case-insensitively); otherwise "NOT_ELIGIBLE" (covers open_count == 0, a MISSING/null
# severity, an UNPARSEABLE severity string, or a HIGH/CRITICAL severity -- SKILL.md's own
# escalation rule makes the last of these structurally unreachable whenever this check is even
# consulted, since ESCALATED would already be true, but this filter still evaluates it
# structurally rather than assuming that invariant holds). `escalated` models SKILL.md's own
# ESCALATED boolean independently of the MINOR_ISSUES_ACKNOWLEDGED decision above -- true the
# moment ANY finding across ANY round (not just the latest occurrence of open claims -- escalation
# is retrospective-insensitive per SKILL.md's own rule) has severity HIGH or CRITICAL
# (case-insensitively). This exists specifically so a HIGH-only escalation predicate bug (silently
# omitting CRITICAL) is directly caught by a Tier 1 fixture, not inferred from the unrelated
# MINOR_ISSUES_ACKNOWLEDGED decision (which is NOT_ELIGIBLE for a HIGH/CRITICAL claim either way,
# for an entirely different reason -- that claim isn't LOW/MEDIUM -- so it could never by itself
# distinguish "escalation correctly includes CRITICAL" from "escalation only checks HIGH").

[inputs] as $rounds
| ($rounds | map(.claude_verification // []) | add // []) as $verifications
| ($rounds | map(.claim_closures // []) | add // []) as $closures
| ($rounds | map((.codex_review.findings // [])[] | {
    key: (if (.group? | type) == "string" then (.group + ":" + .id) else .id end),
    severity
  })) as $all_findings
# One entry per distinct claim_id, keeping only its LAST verification (round order is preserved
# within each group_by bucket since group_by is a stable sort) -- this is the claim's own most
# recent occurrence, carrying that occurrence's own finding_id (never the claim_id itself, which
# is only the ORIGIN finding_id -- a re-raise gets its own distinct finding_id, mapped back to the
# same claim_id via claude_verification, exactly as claim-ledger.md section 1 describes). This
# finding_id is already group-prefixed for a parallel round (per claim-ledger.md section 9), so it
# is compared directly against $all_findings' own computed `key` (never against a raw `.id`).
| ($verifications | group_by(.claim_id) | map(.[-1])) as $latest_verifications
| ($latest_verifications | map(
    . as $v
    | ($closures | map(select(.claim_id == $v.claim_id)) | last) as $closure
    | ($all_findings | map(select(.key == $v.finding_id)) | last) as $latest_finding
    | {
        claim_id: $v.claim_id,
        status: (if $closure == null then "open" else $closure.disposition end),
        canonical_severity: ($latest_finding.severity // null)
      }
  )) as $claims
| $claims[]
, (
    ($claims | map(select(.status == "open"))) as $open
    | ($open | length) as $k
    | ($open | all(
        .canonical_severity != null
        and ((.canonical_severity | ascii_upcase) == "LOW" or (.canonical_severity | ascii_upcase) == "MEDIUM")
      )) as $all_minor
    | ($all_findings | any(
        .severity != null
        and ((.severity | ascii_upcase) == "HIGH" or (.severity | ascii_upcase) == "CRITICAL")
      )) as $escalated
    | {
        decision: (if $k > 0 and $all_minor then "MINOR_ISSUES_ACKNOWLEDGED" else "NOT_ELIGIBLE" end),
        open_count: $k,
        open_claim_ids: ($open | map(.claim_id)),
        escalated: $escalated
      }
  )

# Implements the claim_id join key documented verbatim in
# codex-stream-review/skills/ccs/SKILL.md's Phase 3 "claims" construction:
# "the join key is
#   if (.group? | type) == "string" then (.group + ":" + .id) else .id end
# before joining to claude_verification[].claim_id -- for a single-reviewer
# round, the aggregated array is simply codex_review.findings[] itself with
# no group tag, so the same expression correctly falls through to the bare
# .id, unifying both cases in one expression."
#
# Input: a JSON array of finding objects (each with at least an "id",
# optionally a "group" field, e.g. produced by aggregate-findings-groups.jq).
# Output: an array of the corresponding claim-id-shaped keys, in order.

[.[] | if (.group? | type) == "string" then (.group + ":" + .id) else .id end]

# Implements the round-1 N-group coverage merge (worst-case-wins) documented
# in codex-stream-review/skills/ccs/SKILL.md's "Round-1 N-group merge
# (parallel mode)" section under "Coverage is a Round-1-only property"
# (cross-referenced, not restated, from
# codex-stream-review/skills/ccs/references/parallel-mode.md's own
# coverage_source-merge mentions): "the round's overall coverage_source.status
# is 'complete' only if every dispatched group's own status was 'complete' --
# else 'partial' (with omitted set to the union of every 'partial' group's
# own omitted list, deduplicated by the (path, reason) pair...) if any group
# reported 'partial', else the 'unknown' sentinel if the rest reported
# 'unknown'."
#
# Input: a JSON array of {status, omitted} objects (one per dispatched
# group's coverage.source; status is "complete"|"partial"|"unknown").
# Output: the single merged {status, omitted} object.

if all(.[]; .status == "complete") then
  {status: "complete", omitted: []}
elif any(.[]; .status == "partial") then
  {
    status: "partial",
    omitted: (
      [.[] | select(.status == "partial") | .omitted[]]
      | unique_by([.path, .reason])
    )
  }
else
  {status: "unknown", omitted: []}
end

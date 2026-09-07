# Implements the aggregated findings[] construction documented in
# codex-stream-review/skills/ccs/references/parallel-mode.md's "JSONL field:
# `groups`" section: "The aggregated findings array concatenates every
# group's own findings, each additionally tagged with a 'group' field naming
# its source group."
#
# Input: a JSON array of {group, codex_review: {findings: [...]}} objects,
# one per dispatched group. Output: the flat, tagged aggregated findings
# array (each finding object plus its source group's "group" field).

[.[] | .group as $g | .codex_review.findings[] | . + {group: $g}]

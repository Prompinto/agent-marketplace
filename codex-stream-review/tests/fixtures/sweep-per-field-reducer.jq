# Implements the defect_class_sweeps[] per-field reducer described in
# codex-stream-review/skills/ccs/references/defect-class-sweep.md section 5:
# "to reconstruct a sweep's current state at the start of any round, scan
# every prior round's defect_class_sweeps[] entries for this sweep_id; for
# EACH field independently, its current value is whatever the MOST RECENT
# entry that actually SET that field contains -- a status-only entry sets
# only the field(s) it carries, leaving every other field at its own most
# recent full-or-status-only value untouched."
#
# Input (stdin/file, via `jq -n -c -f this.jq <file>`): a JSONL log, one
# round object per line, each optionally holding a defect_class_sweeps[]
# array (full entries or status-only entries, exactly the shapes documented
# in defect-class-sweep.md section 5).
#
# Output: one compact JSON object per line, one per distinct sweep_id,
# containing every field ever set for it, each holding the value from the
# most recent entry (across all rounds, in round order) that actually
# carried that field -- never a whole-record replacement.

[inputs] as $rounds
| ($rounds | map(.defect_class_sweeps // []) | add // []) as $entries
| ($entries | map(.sweep_id) | unique) as $sweep_ids
| $sweep_ids[] as $sid
| ($entries | map(select(.sweep_id == $sid))) as $sid_entries
| (
    reduce $sid_entries[] as $e
      ({}; . * $e)
  )

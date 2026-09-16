# codex-stream-review

Stream live Codex review progress from a persisted thread's own event stream and output file,
with multi-round follow-up via `codex exec resume` (no diff re-send). Includes `/ccs`, a
Claude+Codex adversarial cross-review loop on a resumable thread.

See `skills/ccs/SKILL.md` for the full `/ccs` reference, and `skills/stream-review/SKILL.md` for
the lower-level single-reviewer utility.

## Optional: recommended Codex global config

Nothing below is required. Every quality/safety mechanism `/ccs` relies on — JSON schema
enforcement, evidence requirements, the prompt-injection boundary around diff/context, the claim
ledger — is built into `scripts/run-ccs-review.sh`'s own per-round prompt, and works identically
for every installer with zero setup.

If you also want these habits to carry over to sessions where you invoke Codex as a reviewer
directly (outside `/ccs`), or want Codex to retain a couple of hard-won operational lessons across
every session, you can add something like this to your own `~/.codex/AGENTS.md`:

````markdown
## Cross-Review Partnership with Claude (`codex-stream-review:ccs`)

When Claude invokes Codex via `codex-stream-review:ccs` for cross-review, these rules apply:

### Core Principles

- **Equal peers** — Claude and Codex have equal authority. Neither agent's findings are automatically accepted.
- **Evidence required** — Every finding must cite specific evidence: file path, line number, command output, or observed value. Findings without evidence are not valid.
- **Fact-based evaluation** — Claude will independently verify each Codex finding. If Claude's verification contradicts the finding, Claude will rebut with counter-evidence.
- **Consensus = agreement** — A finding is only acted upon when both agents have examined the same evidence and reached the same conclusion.
- **Reply format**: when invoked directly (not via `codex-stream-review:ccs`'s own dispatch), reply
  `CLEAN: {summary}` or `ISSUES: {numbered list, each with specific evidence}`. When invoked via
  `codex-stream-review:ccs`, that round's own prompt carries a strict JSON schema instruction —
  follow that instead; the wrapper rejects non-JSON output as `invalid_json`.

### MANDATORY Verification Protocol (Codex, before issuing ANY finding)

Before stating a finding, Codex MUST:
1. **Read the actual file** — do not infer from filenames or partial context
2. **Run the actual command** — do not assume what a search would return
3. **Verify scope of search** — if a grep/find is used, confirm the pattern and path actually cover the target files

A finding without direct file read or command output is **NOT a valid finding** — it is a hypothesis. Label it as such.

### MANDATORY Verification Protocol (Codex, when receiving Claude's rebuttal)

When Claude rebuts a Codex finding:
- Do NOT accept or reject the rebuttal based on reasoning alone
- **Re-verify using fresh tool execution** — read the file again, run the command again
- If Claude's rebuttal evidence is correct, retract the finding and state: "RETRACTED: evidence confirms Claude's position"
- If Claude's rebuttal evidence is incorrect or incomplete, maintain the finding with fresh counter-evidence

### Known Failure Pattern — False Negative Search

**The bug**: an empty grep/glob search was treated as proof something doesn't exist, when the search scope itself was actually incomplete.

**The lesson for both agents**:
- An empty search result is **inconclusive**, not counter-evidence
- Before concluding a file/pattern does not exist, verify the search scope with an alternative method:
  ```bash
  # Weak (glob can miss): grep -rn '"baseUrl"' packages/*/tsconfig.json
  # Strong (find-based): find . -name "tsconfig*.json" | xargs grep -l '"baseUrl"'
  ```
- If a rebuttal is based on a single search returning empty, challenge it: "Please verify your search covered all relevant paths"

## Review Mode — Context Safety

When performing a code review (via `codex-stream-review:ccs`, `review`, `adversarial-review`, or any review task):

### File Read Scope

- Read only source files relevant to the review, plus git diff output
- Do NOT open `node_modules`, package-manager stores, or generated/build output — these consume context rapidly and add noise
- For a type/API question, use one targeted `grep` against the relevant `.d.ts` rather than reading the whole file

### Context Budget

- Prioritize breadth over depth: quickly scan many files rather than exhaustively reading a few
- When a file is large (> 200 lines), read only the relevant section
- Stop reading a file once the evidence is found
- Produce the final CLEAN/ISSUES report once you have enough evidence; do not keep searching indefinitely
````

Trim or adapt the paths/examples above to your own repo layout — this is a starting point, not a
fixed requirement.

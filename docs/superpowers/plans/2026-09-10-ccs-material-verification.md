# `codex-stream-review:ccs` Material Verification (Fake-Clean Trap Fix) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the "fake-clean trap" — a real production incident where a `--resume` retry
returned a schema-valid `ok:true`/`verdict:CLEAN`/`findings:[]` response while its own free-text
`summary` admitted no reviewable material was actually present. Add two independently-checked
signals (`material_reviewed`, a tightened self-assessment; `material_receipt`/
`material_receipt_index`, an objective single-use delivery-schedule sentinel) so a hollow resumed
response can no longer pass as CLEAN undetected.

**Architecture:** Two new required-but-partially-nullable fields on the shared review-verdict
schema, populated by Codex under obligations placed in `run-ccs-review.sh`'s existing trusted
prompt zone (never caller-supplied `--focus` text). A stateless half of the validation
(`material_reviewed` + verdict cross-check) extends `run-ccs-review.sh`'s existing
`schema_mismatch` jq check; a stateful half (the receipt schedule's cursor) lives entirely in
Claude's own Phase 2 processing, reusing the review-history JSONL log as the sole durable cursor
authority — mirroring how the claim ledger's own `DISPOSITION` markers are already Claude-parsed,
not wrapper-parsed. Recovery for either failure reuses `references/compaction.md`'s own complete
"Restart mechanism" verbatim, with a new `references/retry-guards.md` rule that this new failure
reason is never resume-safe.

**Tech Stack:** Markdown (skill/reference authoring), Bash (`run-ccs-review.sh`'s existing
interface, eval scenario `setup.sh`/`expect.sh` scripts, `tests/fixtures/fake-codex`), `jq`
(JSONL construction/reduction, schema cross-field validation), this project's existing
`tests/fixtures/fake-codex` fixture (env-var-driven fake `codex` CLI) for eval scenarios.

**Spec:** `/Users/hmc7279235/Work/Develop/plugins/docs/2026-09-10-ccs-material-verification-design.md`
(the approved, 8-round-adversarially-reviewed design — this plan argues from it; every task below
names the exact section(s) of that document an implementer must transcribe/adapt from, verbatim,
never paraphrased or summarized. **Read the cited section(s) directly from that file before writing
the corresponding content — this plan gives you the constants, field names, and structure to get
right, but the design doc's own prose is the actual copy source for rationale/wording.**)

## Global Constraints

- `N = 70` (the receipt schedule size, fixed, not user-configurable) — derived as
  `MAX_ROUNDS(20) × up to 3 attempts/round = 60`, plus margin. Never re-derive or change this
  number without updating the design doc's own §2.2 first.
- The new failure reason is spelled `no_material_reviewed` everywhere (wrapper `reason` value,
  `compaction_disabled_reason`-style latch naming conventions, JSONL/eval-scenario naming) — never
  `material_not_reviewed`, `no_material`, or any other variant.
- `material_reviewed` is a plain required boolean. `material_receipt`/`material_receipt_index` are
  required-but-nullable (`["string","null"]` / `["integer","null"]`) and must be both-null or
  both-non-null — never one-null-one-populated.
- The obligation to set `material_reviewed` honestly, and the per-dispatch receipt-slot
  instruction, both live in `run-ccs-review.sh`'s `build_review_prompt()` — OUTSIDE the untrusted
  `<$BOUNDARY>...</$BOUNDARY>` block — never inside caller-supplied `--focus`/stdin content.
- `RECEIPT_SCHEDULE_FILE` is written ONCE, immutably, per thread — never touched again after
  creation. It NEVER appears in any `FOCUS_FILE`, round-2+ History text, or JSONL line.
- The JSONL review-history log is the SOLE authority for "which receipt slot is next" — never
  `RECEIPT_SCHEDULE_FILE`, never in-memory-only state. Reconstructed by scanning the whole session
  log for the highest `receipt_issued` record per thread.
- `no_material_reviewed` is NEVER resume-safe. Recovery is exactly one fresh restart (reusing
  `references/compaction.md`'s own complete "Restart mechanism" section verbatim, including digest
  carryforward and snapshot-integrity handling), then `⚠️ COULD NOT VERIFY` if that also fails —
  never a third thread.
- Every schema/fixture change must keep `tests/test-run-ccs-review.sh` and
  `codex-stream-review/tests/fixtures/fake-codex`-driven eval scenarios passing — `additionalProperties: false`
  on `review-verdict.schema.json`'s top level means every existing canned response needs the three
  new fields to stay valid.

---

### Task 1: Schema — add the three new fields

**Files:**
- Modify: `codex-stream-review/schemas/review-verdict.schema.json`

**Interfaces:**
- Produces: three new top-level keys on the review-verdict object — `material_reviewed` (boolean,
  required), `material_receipt` (`["string","null"]`, required), `material_receipt_index`
  (`["integer","null"]`, `minimum: 1`, required). Every later task that constructs or validates a
  verdict JSON object relies on these exact key names and types.

- [ ] **Step 1: Add the three fields to the schema**

Open `codex-stream-review/schemas/review-verdict.schema.json`. Add to the top-level `properties`
object (alongside the existing `verdict`/`findings`/`summary`/`dimensions` keys):

```json
    "material_reviewed": { "type": "boolean" },
    "material_receipt": { "type": ["string", "null"] },
    "material_receipt_index": { "type": ["integer", "null"], "minimum": 1 },
```

Add all three names to the top-level `required` array, so it reads:

```json
  "required": ["verdict", "findings", "summary", "dimensions", "material_reviewed", "material_receipt", "material_receipt_index"],
```

Leave `additionalProperties: false` at the top level unchanged (it already exists) — this is what
forces every producer of a verdict object (the real `codex exec --output-schema` call, and every
test/eval fixture) to include the three new keys.

- [ ] **Step 2: Validate the schema itself is well-formed JSON**

Run: `jq empty codex-stream-review/schemas/review-verdict.schema.json`
Expected: no output, exit code 0 (a parse error would print to stderr and exit nonzero).

- [ ] **Step 3: Commit**

```bash
git add codex-stream-review/schemas/review-verdict.schema.json
git commit -m "feat(ccs): add material_reviewed/material_receipt/material_receipt_index to review-verdict schema"
```

---

### Task 2: Fixture propagation — `DEFAULT_VERDICT` and every custom canned response

**Files:**
- Modify: `codex-stream-review/tests/fixtures/fake-codex`
- Modify: every `codex-stream-review/evals/scenarios/*/setup.sh` that constructs a custom
  `FAKE_CODEX_FINAL_ANSWER` or `FAKE_CODEX_GROUP_STATE` verdict JSON object directly (rather than
  relying on `fake-codex`'s own `DEFAULT_VERDICT`)
- Test: `codex-stream-review/tests/test-run-ccs-review.sh` (verify existing fixtures still parse)

**Interfaces:**
- Consumes: the three schema fields from Task 1.
- Produces: every existing test/eval fixture stays schema-valid after Task 1's `required`/
  `additionalProperties: false` change — this is a pure propagation task, no new behavior.

Task 1 makes `additionalProperties: false` reject any verdict object missing the three new keys.
`tests/fixtures/fake-codex` centralizes the common case in one `DEFAULT_VERDICT` constant (line
~263 as of this plan's writing) — fixing that one constant covers every scenario that relies on
the default `normal` path. A second pass is needed for scenarios that construct their OWN verdict
JSON directly (via `FAKE_CODEX_FINAL_ANSWER` or a `FAKE_CODEX_GROUP_STATE` round-answer file) —
grep for these across `evals/scenarios/` and fix each one found.

- [ ] **Step 1: Fix the centralized default**

In `codex-stream-review/tests/fixtures/fake-codex`, find the `DEFAULT_VERDICT` assignment:

```bash
DEFAULT_VERDICT='{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"not_applicable","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}}}'
```

Replace it with the same object plus the three new fields, using benign always-valid defaults
(`material_reviewed: true`, and a `material_receipt`/`material_receipt_index` pair of `null`/`null`
— a fixture that never explicitly tests the receipt mechanism has no schedule to reference, so the
null-pair shape is the correct default, not a fabricated non-null value):

```bash
DEFAULT_VERDICT='{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"not_applicable","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}'
```

- [ ] **Step 2: Find every custom verdict JSON that needs the same fields**

```bash
grep -rln "FAKE_CODEX_FINAL_ANSWER='{" codex-stream-review/evals/scenarios/*/setup.sh codex-stream-review/tests/test-run-ccs-review.sh
grep -rl "round-.*-final-answer.json" codex-stream-review/evals/scenarios/*/setup.sh
```

For every file found, locate each inline `'{"verdict":...}'`-shaped JSON literal (or, for
`FAKE_CODEX_GROUP_STATE`, each `round-N-final-answer.json` file it writes) and add
`"material_reviewed":true,"material_receipt":null,"material_receipt_index":null` to it, UNLESS that
specific scenario's own purpose is to test schema_mismatch/invalid-JSON handling on data that is
already deliberately malformed for a different reason — for those, leave the existing deliberate
malformation as-is (adding the three fields would not change what that scenario is testing, but do
add them anyway for consistency unless doing so would make an already-invalid fixture accidentally
valid, in which case leave a one-line comment noting why they were intentionally omitted).

- [ ] **Step 3: Run the full deterministic test suite**

Run: `bash codex-stream-review/tests/test-run-ccs-review.sh`
Expected: `All fixtures passed.` — any fixture that still fails schema validation because it's
missing one of the three new fields will show up here first (before touching any eval scenario) as
a `schema_mismatch`-shaped test failure that previously passed.

- [ ] **Step 4: Run one representative eval scenario end-to-end to confirm no fixture regression**

Run: `bash codex-stream-review/evals/run-evals.sh clean-basic` (Phase 1 only — this just confirms
`setup.sh` itself doesn't error; full Phase 2 validation requires a live session and is out of
scope for this mechanical propagation task).
Expected: exits 0, prints the scenario's own task text and PATH instructions with no error about
malformed fixture JSON.

- [ ] **Step 5: Commit**

```bash
git add codex-stream-review/tests/fixtures/fake-codex codex-stream-review/evals/scenarios codex-stream-review/tests/test-run-ccs-review.sh
git commit -m "test(ccs): propagate material_reviewed/material_receipt fields into every canned verdict fixture"
```

---

### Task 3: `run-ccs-review.sh` — `material_reviewed` trusted-zone obligation

**Files:**
- Modify: `codex-stream-review/scripts/run-ccs-review.sh` (`build_review_prompt()`, the function
  starting at line ~152 in the current file)

**Interfaces:**
- Consumes: nothing new — pure prompt-text addition.
- Produces: every real `codex exec`/`codex exec resume` dispatch's own prompt now carries the
  `material_reviewed` obligation, so later tasks (the schema_mismatch extension in Task 5) can rely
  on Codex having been told the exact rule to self-assess against.

Read the design doc's §1 ("`material_reviewed` — tightened self-assessment") in full before
writing this — the canonical-manifest definition is precise and must not be loosened.

- [ ] **Step 1: Add the obligation paragraph to `build_review_prompt()`**

In `codex-stream-review/scripts/run-ccs-review.sh`, find the existing `DISPOSITION` marker
obligation paragraph inside `build_review_prompt()` (the block starting `echo "If the \"## Context\"
section above explicitly asks you to state a disposition..."`, around line 266 in the current
file) — this paragraph is deliberately placed OUTSIDE the `<$BOUNDARY>...</$BOUNDARY>` block
printed earlier in the same function, i.e. it is NOT wrapped by the `echo "<$BOUNDARY>"` /
`echo "</$BOUNDARY>"` pair. Add the new obligation immediately after that existing paragraph (still
outside the boundary):

```bash
  echo ""
  echo "You must also report \"material_reviewed\" (a boolean) on EVERY response, fresh or"
  echo "resumed. Set it to true only if the specific diff/artifact snapshot AND this round's own"
  echo "Why/Scope/History text -- together, the canonical manifest for THIS round -- were both"
  echo "genuinely present in your context and examined. This includes the ordinary case of"
  echo "examining real, complete material and finding zero defects. Set it to false if either is"
  echo "absent, partial, truncated, stale, or of unknown coverage -- for example, if you are being"
  echo "asked to review a diff you cannot actually find anywhere in your own context. Never guess"
  echo "true when you are uncertain whether you actually saw the material in question."
```

- [ ] **Step 2: Confirm the paragraph lands outside the untrusted boundary**

Run: `bash -n codex-stream-review/scripts/run-ccs-review.sh`
Expected: no output (syntax valid).

Run this to visually confirm placement (the new paragraph's `echo` lines must appear AFTER the
existing `echo "</$BOUNDARY>"` line for the diff/focus boundary, not between the two boundary
markers):
```bash
awk '/^build_review_prompt\(\)/,/^}/' codex-stream-review/scripts/run-ccs-review.sh | grep -n 'BOUNDARY\|material_reviewed'
```
Expected: every `material_reviewed` line number is greater than the LAST `</$BOUNDARY>` line
number shown.

- [ ] **Step 3: Run the existing test suite to confirm no regression**

Run: `bash codex-stream-review/tests/test-run-ccs-review.sh`
Expected: `All fixtures passed.` (this step only changes prompt TEXT sent to the fake/real CLI,
never parsed by the wrapper itself, so no existing test should be affected).

- [ ] **Step 4: Commit**

```bash
git add codex-stream-review/scripts/run-ccs-review.sh
git commit -m "feat(ccs): add material_reviewed obligation to build_review_prompt()'s trusted zone"
```

---

### Task 4: `run-ccs-review.sh` — `--receipt-slot` CLI flag + trusted-zone rendering

**Files:**
- Modify: `codex-stream-review/scripts/run-ccs-review.sh` (argument parser around line ~384-459;
  `build_review_prompt()`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a new optional CLI flag, `--receipt-slot <N>`, parsed into a shell variable
  `RECEIPT_SLOT` (empty string when the flag is omitted). Later tasks (SKILL.md's dispatch
  construction, Task 8) pass this flag on every dispatch to a thread with an active schedule.

Read the design doc's §2.3 ("Issuing a slot — Claude decides, not the model; one sole cursor
authority") in full before writing this — the instruction text must be word-for-word identical on
every dispatch except for the `<N>` value, and must never contain a live token value.

- [ ] **Step 1: Add the `--receipt-slot` case to the argument parser**

In `codex-stream-review/scripts/run-ccs-review.sh`, add a new case alongside the existing
`--capture-eventlog`/`--keep-last-message` cases (which sit between `--timeout` and the catch-all
`*)` case, around line 436-453 in the current file):

```bash
    --receipt-slot)
      # Public, opt-in flag (documented in SKILL.md): the non-secret slot NUMBER Claude has
      # already pre-committed via a durable JSONL receipt_issued append, BEFORE this dispatch was
      # ever constructed. build_review_prompt() renders this into its own trusted zone as a fixed,
      # N-parameterized instruction -- never restates a live token value, only the index to look up.
      [ $# -ge 2 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--receipt-slot requires a value"}\n'; exit 1; }
      case "$2" in
        ''|*[!0-9]*)
          DETAIL_JSON="$(printf '%s' "$2" | jq -Rs '"--receipt-slot must be a positive integer, got: " + .')"
          printf '{"ok":false,"reason":"bad_args","detail":%s}\n' "$DETAIL_JSON"
          exit 1 ;;
      esac
      [ "$2" -ge 1 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--receipt-slot must be >= 1"}\n'; exit 1; }
      RECEIPT_SLOT="$2"; shift 2 ;;
```

Add `RECEIPT_SLOT=""` to the same up-front variable-reset block that already resets `CODEX_PID`/
`SAFE_GIT_HOME` before the `while [ $# -gt 0 ]; do` loop begins, so an omitted flag is always
explicitly empty rather than an unset/inherited value.

- [ ] **Step 2: Render the trusted-zone instruction, parameterized by `$RECEIPT_SLOT`**

In `build_review_prompt()`, immediately after the `material_reviewed` paragraph added in Task 3,
add a conditional block — this text is emitted ONLY when `--receipt-slot` was actually passed (a
dispatch to a thread with no active schedule, e.g. a session that never triggers `no_material_reviewed`
recovery logic and has no schedule allocated at all, omits the flag entirely and this whole block is
skipped):

```bash
  if [ -n "$RECEIPT_SLOT" ]; then
    echo ""
    echo "Your context may contain a block labeled REVIEW_RECEIPT_SCHEDULE with numbered tokens."
    echo "Report material_receipt_index: $RECEIPT_SLOT and the exact token value at position"
    echo "$RECEIPT_SLOT in that schedule, in the material_receipt field. If you cannot locate that"
    echo "schedule, or cannot find entry $RECEIPT_SLOT in it, set both material_receipt and"
    echo "material_receipt_index to null instead of guessing."
  fi
```

This text is otherwise IDENTICAL on every dispatch, fresh or resumed — only `$RECEIPT_SLOT`
changes. It never contains the token's own VALUE, only the slot NUMBER, which is non-secret (see
design doc §2.3 for why revealing the number is safe).

- [ ] **Step 3: Verify the flag round-trips through a manual dispatch**

```bash
bash -n codex-stream-review/scripts/run-ccs-review.sh
echo "test focus" | codex-stream-review/scripts/run-ccs-review.sh --receipt-slot 3 2>&1 | head -5
```
Expected: a `bad_args` JSON response is fine here (no `--cwd`/scope flag was given in this manual
smoke test) — the goal is confirming `--receipt-slot 3` itself is accepted without a `bad_args`
about THAT flag specifically. Confirm by checking the `detail` field never mentions
`--receipt-slot`.

- [ ] **Step 4: Add a fixture test for `--receipt-slot`'s own argument validation**

In `codex-stream-review/tests/test-run-ccs-review.sh`, add three new test cases near the existing
`--timeout` validation tests:

```bash
OUT="$(echo "focus" | "$WRAPPER" --cwd "$REPO" --uncommitted --receipt-slot 0 2>&1)"
if printf '%s' "$OUT" | jq -e '.reason == "bad_args"' >/dev/null 2>&1; then
  pass "--receipt-slot 0 rejected as bad_args"
else
  fail "--receipt-slot 0 should be rejected, got: $OUT"
fi

OUT="$(echo "focus" | "$WRAPPER" --cwd "$REPO" --uncommitted --receipt-slot abc 2>&1)"
if printf '%s' "$OUT" | jq -e '.reason == "bad_args"' >/dev/null 2>&1; then
  pass "--receipt-slot abc (non-numeric) rejected as bad_args"
else
  fail "--receipt-slot abc should be rejected, got: $OUT"
fi

OUT="$(echo "focus" | FAKE_CODEX_SCENARIO=normal "$WRAPPER" --cwd "$REPO" --uncommitted --receipt-slot 5 2>&1)"
if printf '%s' "$OUT" | jq -e '.ok == true' >/dev/null 2>&1; then
  pass "--receipt-slot 5 (valid) accepted, dispatch succeeds"
else
  fail "--receipt-slot 5 should be accepted, got: $OUT"
fi
```

(Adapt `$WRAPPER`/`$REPO` to whatever variable names the surrounding test file already uses for the
wrapper path and the fixture repo directory — match the existing test style exactly rather than
introducing new naming.)

- [ ] **Step 5: Run the full test suite**

Run: `bash codex-stream-review/tests/test-run-ccs-review.sh`
Expected: `All fixtures passed.`

- [ ] **Step 6: Commit**

```bash
git add codex-stream-review/scripts/run-ccs-review.sh codex-stream-review/tests/test-run-ccs-review.sh
git commit -m "feat(ccs): add --receipt-slot flag and its trusted-zone prompt rendering"
```

---

### Task 5: `run-ccs-review.sh` — `schema_mismatch` extension for `material_reviewed`/receipt-pair validation

**Files:**
- Modify: `codex-stream-review/scripts/run-ccs-review.sh` (the `schema_mismatch` jq check, around
  line 1017-1057 in the current file)

**Interfaces:**
- Consumes: the three schema fields (Task 1), which every canned/real response now carries.
- Produces: a schema-conformant JSON that sets `material_reviewed:false` (with ANY verdict), OR
  sets `material_receipt`/`material_receipt_index` as one-null-one-populated, is now rejected by
  the wrapper itself as `schema_mismatch` — never reaches Claude as an accepted `ok:true` response.
  This is the WRAPPER-level half of `no_material_reviewed` detection (see design doc §3, route 1).
  Note: the wrapper still reports the generic `schema_mismatch` reason for this — it does NOT
  itself emit a distinct `no_material_reviewed` reason string (see Task 9 for where the
  wrapper-vs-Claude reason-value split is finalized).

Read the design doc's §2.4 ("Validation and its cross-field contract") and §3 ("The
`no_material_reviewed` failure reason and its recovery path", route 1 specifically) before writing
this.

- [ ] **Step 1: Extend the existing jq semantic check**

In the big `jq -e '...'` expression inside the `schema_mismatch` branch, add two new conjuncts.
The full expression currently ends with:

```
        (.dimensions | to_entries | all(.value |
          (has("status") and (.status == "checked" or .status == "not_applicable" or .status == "blocked")) and
          (has("evidence") and (.evidence | type) == "string" and (.evidence | test("\\S"))) and
          ((keys_unsorted - ["status","evidence"]) == [])
        ))
      ' >/dev/null 2>&1; then
```

Change it to add two new `and`-joined conditions right before the closing `))` / `'`:

```
        (.dimensions | to_entries | all(.value |
          (has("status") and (.status == "checked" or .status == "not_applicable" or .status == "blocked")) and
          (has("evidence") and (.evidence | type) == "string" and (.evidence | test("\\S"))) and
          ((keys_unsorted - ["status","evidence"]) == [])
        )) and
        has("material_reviewed") and (.material_reviewed | type) == "boolean" and
        (if .material_reviewed == false then false else true end) and
        has("material_receipt") and has("material_receipt_index") and
        ((.material_receipt | type) == "null" or (.material_receipt | type) == "string") and
        ((.material_receipt_index | type) == "null" or ((.material_receipt_index | type) == "number" and (.material_receipt_index | floor) == .material_receipt_index and .material_receipt_index >= 1)) and
        (((.material_receipt | type) == "null") == ((.material_receipt_index | type) == "null"))
      ' >/dev/null 2>&1; then
```

Walking through the five new conjuncts:
- `has("material_reviewed") and (.material_reviewed | type) == "boolean"` — the field must exist
  and be a real boolean (type-checked, matching every other field's existing style in this check).
- `(if .material_reviewed == false then false else true end)` — the actual rejection rule:
  `material_reviewed:false` makes the WHOLE check fail (routing to `schema_mismatch`) regardless of
  what `.verdict`/`.findings` say — this deliberately does NOT special-case `.verdict == "CLEAN"`
  the way an earlier draft did (see design doc §3's "ACCEPTED, real gap" note under round 1 of the
  review trail): `material_reviewed:false` combined with `ISSUES`/nonempty findings is rejected
  identically to combined with `CLEAN`.
- `has("material_receipt") and has("material_receipt_index")` — both keys must be present (already
  implied by `required`+`additionalProperties:false` in the schema, but this check runs BEFORE
  `--output-schema` structured-output enforcement would reject a malformed response some other way
  — see the existing comment above this whole `jq -e` block for why cross-field rules need this
  manual check regardless of schema-level `required`).
- The two `type == "null" or type == "string"/"number"` checks — nullable-typed validation.
- `(((.material_receipt | type) == "null") == ((.material_receipt_index | type) == "null"))` — the
  paired-null cross-field rule: both null or both non-null, never one of each.

- [ ] **Step 2: Add fixture tests for each new rejection path**

In `codex-stream-review/tests/test-run-ccs-review.sh`, add test cases (following the file's
existing style for constructing a custom `FAKE_CODEX_FINAL_ANSWER` and asserting the resulting
`reason`):

```bash
# material_reviewed:false with CLEAN -- rejected
BAD_ANSWER='{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"not_applicable","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":false,"material_receipt":null,"material_receipt_index":null}'
OUT="$(echo "focus" | FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="$BAD_ANSWER" "$WRAPPER" --cwd "$REPO" --uncommitted 2>&1)"
if printf '%s' "$OUT" | jq -e '.reason == "schema_mismatch"' >/dev/null 2>&1; then
  pass "material_reviewed:false + CLEAN rejected as schema_mismatch"
else
  fail "material_reviewed:false + CLEAN should be rejected, got: $OUT"
fi

# material_reviewed:false with ISSUES + a fabricated finding -- ALSO rejected (the exact gap
# closed vs. an earlier draft that only checked the CLEAN combination)
BAD_ANSWER2='{"verdict":"ISSUES","findings":[{"file":"x.py","line":1,"severity":"low","summary":"s","evidence":"e","verification":"v"}],"summary":null,"dimensions":{"correctness":{"status":"checked","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":false,"material_receipt":null,"material_receipt_index":null}'
OUT="$(echo "focus" | FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="$BAD_ANSWER2" "$WRAPPER" --cwd "$REPO" --uncommitted 2>&1)"
if printf '%s' "$OUT" | jq -e '.reason == "schema_mismatch"' >/dev/null 2>&1; then
  pass "material_reviewed:false + ISSUES/nonempty-findings ALSO rejected as schema_mismatch"
else
  fail "material_reviewed:false + ISSUES should be rejected, got: $OUT"
fi

# one-null-one-populated receipt pair -- rejected
BAD_ANSWER3='{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"not_applicable","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":true,"material_receipt":"abc123","material_receipt_index":null}'
OUT="$(echo "focus" | FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="$BAD_ANSWER3" "$WRAPPER" --cwd "$REPO" --uncommitted 2>&1)"
if printf '%s' "$OUT" | jq -e '.reason == "schema_mismatch"' >/dev/null 2>&1; then
  pass "one-null-one-populated receipt pair rejected as schema_mismatch"
else
  fail "one-null-one-populated receipt pair should be rejected, got: $OUT"
fi

# material_reviewed:true + a valid null-null receipt pair -- accepted (baseline, no schedule active)
GOOD_ANSWER='{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"not_applicable","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}},"material_reviewed":true,"material_receipt":null,"material_receipt_index":null}'
OUT="$(echo "focus" | FAKE_CODEX_SCENARIO=normal FAKE_CODEX_FINAL_ANSWER="$GOOD_ANSWER" "$WRAPPER" --cwd "$REPO" --uncommitted 2>&1)"
if printf '%s' "$OUT" | jq -e '.ok == true' >/dev/null 2>&1; then
  pass "material_reviewed:true + null-null receipt pair accepted"
else
  fail "material_reviewed:true + null-null pair should be accepted, got: $OUT"
fi
```

(Adapt `$WRAPPER`/`$REPO` to the surrounding file's own established variable names.)

- [ ] **Step 3: Run the full test suite**

Run: `bash codex-stream-review/tests/test-run-ccs-review.sh`
Expected: `All fixtures passed.`

- [ ] **Step 4: Commit**

```bash
git add codex-stream-review/scripts/run-ccs-review.sh codex-stream-review/tests/test-run-ccs-review.sh
git commit -m "feat(ccs): extend schema_mismatch to reject material_reviewed:false (any verdict) and unpaired receipt nulls"
```

---

### Task 6: SKILL.md — schedule generation and `RECEIPT_SCHEDULE_FILE`

**Files:**
- Modify: `codex-stream-review/skills/ccs/SKILL.md` (Phase 0/Phase 1, alongside the existing
  `SNAPSHOT_FILE` allocation)

**Interfaces:**
- Consumes: nothing new.
- Produces: `RECEIPT_SCHEDULE_FILE` (a session-scoped literal fact, remembered like
  `SNAPSHOT_FILE`) and its own on-disk content (the N=70 token mapping) for any thread that
  becomes a material-bearing seed. Later tasks (7, 8) read from this file and embed its content
  into `FOCUS_FILE`.

Read the design doc's §2.2 ("Schedule generation and embedding") in full before writing this.

- [ ] **Step 1: Add the schedule-generation procedure to SKILL.md**

Find `SKILL.md`'s existing `SNAPSHOT_FILE`/`SNAPSHOT_DIGEST` allocation block (Phase 1's
"Immediately after sizing concludes, for a repo-diff round — snapshot & hash the canonical review
subject" section, and Phase 0 step 5's non-repo-artifact equivalent). Immediately after that
existing block concludes (both the repo-diff and non-repo-artifact variants), add a new
subsection:

````markdown
**Receipt schedule generation (always allocated once per material-bearing seed — round 1's own
fresh dispatch, or later a `no_material_reviewed` fresh restart's brand-new thread — see
`references/retry-guards.md`'s new rule for when a restart happens).** Full mechanics in the
design doc's §2.2/§2.3 if this summary is ever unclear, but the exact procedure is:

```bash
SESSION_ID="<literal from Phase 0>"
RECEIPT_SCHEDULE_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-receipt-schedule.txt.XXXXXX")
SCHEDULE_BLOCK="REVIEW_RECEIPT_SCHEDULE"
for i in $(seq 1 70); do
  TOKEN="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  SCHEDULE_BLOCK="$SCHEDULE_BLOCK
$i: $TOKEN"
done
printf '%s\n' "$SCHEDULE_BLOCK" > "$RECEIPT_SCHEDULE_FILE"
echo "RECEIPT_SCHEDULE_FILE=$RECEIPT_SCHEDULE_FILE"
```

`N = 70` is fixed (see this plan's Global Constraints and the design doc's §2.2 derivation:
`MAX_ROUNDS(20) × up to 3 attempts/round = 60`, plus margin) — never a different value.
`RECEIPT_SCHEDULE_FILE` is written ONCE here and never touched again for this thread's lifetime —
remembered as a session-scoped literal fact for this THREAD specifically (not the whole session:
a fresh restart's new thread gets its OWN new `RECEIPT_SCHEDULE_FILE`, a separate file, never
reusing the old thread's). **This file's content is NEVER included in any `FOCUS_FILE`
construction, never excerpted into round 2+'s own History text, and never part of any JSONL
line** — it exists purely as Claude's own local, private record of the schedule, mirroring
`SNAPSHOT_FILE`'s own treatment exactly.

**Embedding into the seed's own payload.** The `REVIEW_RECEIPT_SCHEDULE` block (the exact content
just written to `RECEIPT_SCHEDULE_FILE`, read back via `cat "$RECEIPT_SCHEDULE_FILE"`) is appended
to round 1's own `FOCUS_FILE` content (Phase 1 Step 0's Round 1 focus-text construction, described
above), positioned immediately AFTER the Why/Scope/collaboration-frame text — representative of
the payload having been fully transmitted, not embedded before real content. (This is Claude's own
`FOCUS_FILE` text, not `run-ccs-review.sh`'s own diff/artifact collection — the wrapper never sees
or constructs this block; Claude writes it directly into the same file it already writes Why/Scope
text into.)
````

- [ ] **Step 2: Add cleanup for `RECEIPT_SCHEDULE_FILE` to Phase 3**

Find Phase 3 step 3's session-level temp-file cleanup block (the one that already removes
`REPO_ROOT_FILE`/`INSTALL_PATH_FILE`/`SNAPSHOT_FILE`/`CLEAN_REPO_DIR`/`FAKE_GIT_HOME`). Add:

```bash
   rm -f "<every RECEIPT_SCHEDULE_FILE ever allocated this session, one per thread that got one>"
```

with a short note that a session may have allocated more than one (round 1's own thread, plus one
per `no_material_reviewed` fresh restart), and every one of them must be removed — never leave a
schedule file behind after the run ends, since it durably holds still-secret unused token values.

- [ ] **Step 3: Commit**

```bash
git add codex-stream-review/skills/ccs/SKILL.md
git commit -m "docs(ccs): add receipt schedule generation (RECEIPT_SCHEDULE_FILE) to SKILL.md"
```

---

### Task 7: SKILL.md — pre-dispatch `receipt_issued` JSONL append + `--receipt-slot` on every dispatch

**Files:**
- Modify: `codex-stream-review/skills/ccs/SKILL.md` (Phase 1 Step 1's dispatch construction)

**Interfaces:**
- Consumes: `RECEIPT_SCHEDULE_FILE` (Task 6); `--receipt-slot` (Task 4).
- Produces: every dispatch to a thread with an active schedule now carries a
  `--receipt-slot <N>` argument, and the JSONL log gains a new line-schema addition,
  `receipt_issued: {thread_id, index}`, appended BEFORE that dispatch is ever constructed. Task 9
  reads this durable record back as the sole cursor authority.

Read the design doc's §2.3 in full — the append-BEFORE-dispatch ordering, and "the JSONL log is
the SOLE cursor authority," are both load-bearing and must not be loosened.

- [ ] **Step 1: Add the pre-dispatch cursor-issuance procedure**

Find Phase 1 Step 1's dispatch construction block (the "For each group dispatched this round..."
section, immediately before the "Round 1 (fresh...)"/"Round 2+ (resume...)" dispatch commands).
Immediately before that block's own commands, for a thread that has an active
`RECEIPT_SCHEDULE_FILE` (every thread does, per Task 6 — round 1's own thread from its very first
dispatch onward), add:

````markdown
**Receipt slot issuance — durably committed BEFORE this dispatch is ever constructed, never
after receiving its response.** Reconstruct the current cursor for THIS thread by scanning the
WHOLE session JSONL log for the highest-numbered `receipt_issued.index` value recorded for this
`thread_id` so far (0 if none has ever been recorded for this thread — its own first-ever
dispatch). The slot to issue THIS dispatch is that value plus 1:

```bash
NEXT_SLOT="<highest prior receipt_issued.index for this thread_id, from the JSONL log, plus 1; 1 if none>"
jq -nc --arg tid "<this thread's own literal thread_id, or 'PENDING' if round 1's own thread has no id yet>" --argjson idx "$NEXT_SLOT" \
  '{receipt_issued: {thread_id: $tid, index: $idx}}' >> ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>.jsonl
```

(For round 1's own very first dispatch, before any `threadId` has ever been returned, record
`thread_id` as the literal string `"PENDING"` — reconcile it to the real `threadId` retroactively
once Phase 2 step 1 parses the response and `GROUP_THREADS` is established, by appending a SECOND
`receipt_issued` correction line `{receipt_issued: {thread_id: "<real threadId>", index: 1,
reconciles: "PENDING"}}` immediately after — the cursor-reconstruction scan in Task 9 must treat a
`reconciles` line as authoritative over the `PENDING` line it corrects, never double-counting both
as separate issuances for the same slot.)

This append uses the SAME append-then-verify hard-stop mechanism as every other JSONL write in
this skill (see "Review history log" → "Write" below) — a failed/unverified append here is a hard
stop, `🛑 REVIEW LOG INTEGRITY FAILURE`, exactly like any other critical JSONL write, since a lost
`receipt_issued` record would desynchronize the cursor for the rest of this thread's lifetime.

Once this append is verified, pass `--receipt-slot "$NEXT_SLOT"` as a literal additional argument
on THIS dispatch's own `run-ccs-review.sh` call (both the fresh and resume forms below) — every
dispatch to a thread with an active schedule carries this flag, every round, including bounded
resume retries triggered by `references/retry-guards.md`'s own retry logic (each such retry is
itself a separate dispatch attempt and must issue and durably record its own next slot the same
way, before that retry is ever constructed).
````

- [ ] **Step 2: Update the dispatch command templates to include the new flag**

In the same Step 1 dispatch block, add `--receipt-slot "$NEXT_SLOT"` to both the Round 1 (fresh)
and Round 2+ (resume) command templates shown in SKILL.md, immediately after the existing
`--capture-eventlog`/`--keep-last-message` conditional-inclusion comments (following the identical
pattern: state plainly that this flag is included as literal text whenever a schedule is active for
this thread — which is always, per Task 6 — never a variable-gated branch left for a later call to
resolve).

- [ ] **Step 3: Commit**

```bash
git add codex-stream-review/skills/ccs/SKILL.md
git commit -m "docs(ccs): add pre-dispatch receipt_issued JSONL append and --receipt-slot wiring"
```

---

### Task 8: SKILL.md — Phase 2 receipt validation and the synthetic-failure ordering rule

**Files:**
- Modify: `codex-stream-review/skills/ccs/SKILL.md` (Phase 2 step 1)

**Interfaces:**
- Consumes: `receipt_issued` JSONL records (Task 7); `material_receipt`/`material_receipt_index`
  from the parsed response (Task 1's schema fields).
- Produces: the CLAUDE-SIDE half of `no_material_reviewed` detection (design doc §3, route 2) — a
  receipt mismatch or invalid null-pair is converted to a synthetic `ok:false`/
  `no_material_reviewed` result BEFORE findings/claim-ledger/convergence ever process that
  response.

Read the design doc's §2.4 and §3 in full — the explicit ordering rule ("the MOMENT Phase 2 step 1
parses...") is the single most important sentence in this task; get the sequencing exactly right.

- [ ] **Step 1: Add the receipt-validation check to Phase 2 step 1**

Find Phase 2 step 1 ("Parse each dispatched group's own single-line JSON..."). Immediately after
the existing `ok:false` → failed-round handling and BEFORE step 2 ("Receive Codex's findings") ever
runs for an `ok:true` response, insert:

````markdown
**Receipt validation — runs on every `ok:true` response from a thread with an active schedule,
BEFORE step 2/3/convergence ever process it.** Reconstruct the expected value for the slot THIS
dispatch issued (the `NEXT_SLOT`/token pair from Task 7's pre-dispatch issuance, cross-referenced
against `RECEIPT_SCHEDULE_FILE`'s own immutable content for this thread). Compare against the
response's own `material_receipt`/`material_receipt_index`:

- If `material_receipt_index` does not equal the slot this dispatch issued, OR `material_receipt`
  does not exactly match that slot's own token value in `RECEIPT_SCHEDULE_FILE`, OR both fields are
  `null` despite this thread genuinely having an active schedule: treat this response IMMEDIATELY
  — before step 2 (receiving findings), step 3 (re-verification/claim-ledger judgments), or any
  convergence check — as equivalent to this group's response being `ok:false` with reason
  `no_material_reviewed`. Its own `verdict`/`findings` content is never processed or acted on even
  if it looks internally coherent, and it never participates in the convergence check under any
  circumstance.
- If it matches: no special handling, proceed to step 2 normally. (The wrapper's own
  `material_reviewed:false` rejection, Task 5, has already ruled out that half of `no_material_reviewed`
  before this response ever reached `ok:true` at all — this check only ever needs to catch the
  receipt-specific half.)

`references/retry-guards.md`'s own new rule (see below) governs recovery from a synthetic
`no_material_reviewed` exactly the same way it governs the wrapper-level route — this check's job
is ONLY detection and correct sequencing, never its own separate recovery logic.
````

- [ ] **Step 2: Cross-reference from the Guards section**

In Phase 2's "Guards" subsection, add a new bullet immediately after the existing "Empty/failed
review handling" bullet:

```markdown
- **`no_material_reviewed` handling (wrapper-level `schema_mismatch` route, or the Claude-side
  receipt-validation route in step 1 above) is never resume-safe — read
  `references/retry-guards.md`'s own new section for this reason before doing anything else with
  it.** Never treated as a clean sign-off, and never given the ordinary bounded-resume-retry
  treatment every other threadId-bearing failure gets.
```

- [ ] **Step 3: Commit**

```bash
git add codex-stream-review/skills/ccs/SKILL.md
git commit -m "docs(ccs): add Phase 2 receipt validation with explicit pre-convergence ordering rule"
```

---

### Task 9: `references/retry-guards.md` — `no_material_reviewed` never resume-safe

**Files:**
- Modify: `codex-stream-review/skills/ccs/references/retry-guards.md`

**Interfaces:**
- Consumes: the `no_material_reviewed` reason from both Task 5 (wrapper) and Task 8 (Claude-side
  synthetic).
- Produces: the recovery contract every later eval scenario (Tasks 12-16) tests against.

Read the design doc's §3 in full before writing this.

- [ ] **Step 1: Add the new never-resume-safe reason and its recovery rule**

Find `retry-guards.md`'s existing "Resume-safety by failure reason" table/section (the one this
plan's own SKILL.md excerpt above quotes in full). Add a new subsection immediately after it:

````markdown
## `no_material_reviewed` — never resume-safe, one bounded fresh restart

Unlike every other threadId-bearing reason in the table above, `no_material_reviewed` (whether
detected by the wrapper's own `schema_mismatch` extension for `material_reviewed:false`, or by
Claude's own Phase 2 receipt-mismatch/invalid-null-pair check — see
`references/compaction.md`... no, see this skill's own `SKILL.md` Phase 2 step 1) is **never**
resume-safe: the thread has just proven its own context is hollow, so resuming it would only
reproduce the identical failure.

**Recovery**: abandon that thread immediately (add to `LEAKED_THREAD_IDS`) and issue exactly ONE
fresh restart, reusing `references/compaction.md`'s own COMPLETE "Restart mechanism" section
verbatim — not a separately-invented lighter-weight version. This means:
- The claim ledger digest is carried forward into the fresh thread's own seed, built from the
  durable JSONL log's own reducer state — never from the abandoned thread's own internal state.
- The same snapshot-integrity revalidation/promotion machinery `--compact`'s own restart already
  uses applies here too, inheriting that feature's own already-accepted tradeoff (a restart may
  review the CURRENT state of a possibly-since-changed working tree).
- The fresh restart's own new thread gets its own fresh receipt schedule
  (`RECEIPT_SCHEDULE_FILE`, per `SKILL.md`'s own schedule-generation procedure) — never reusing
  the abandoned thread's schedule.

**If the ONE fresh restart is ALSO `no_material_reviewed`** (either detection route): stop and
report `⚠️ COULD NOT VERIFY`, never attempt a third thread — matching this file's own existing
round-1-fresh-fallback-then-give-up precedent, and `references/compaction.md`'s own
candidate-A-to-thread-B single-shot-escalation-then-give-up pattern.

This recovery is triggered from `no_material_reviewed` REGARDLESS of what session round number it
occurs at — unlike this file's own general round-1-only fresh-fallback restriction for ordinary
resume-exhausted failures, `no_material_reviewed`'s fresh restart is available on ANY round,
including round 2+, since resuming has already been proven useless and there is no round-2+
"no fresh scope left" concern that applies here (this thread's own accumulated context has zero
remaining value once proven hollow).
````

- [ ] **Step 2: Cross-reference from `references/compaction.md`**

In `codex-stream-review/skills/ccs/references/compaction.md`'s "Restart mechanism" section header
or its immediately following paragraph, add one sentence noting this section is now reused by a
second consumer:

```markdown
> This section's restart mechanism is reused verbatim by TWO triggers: `--compact`'s own
> token-threshold trigger (below), and `references/retry-guards.md`'s `no_material_reviewed`
> never-resume-safe rule (a genuinely different trigger, but the identical restart procedure —
> digest carryforward, snapshot revalidation/promotion — applies unchanged either way).
```

- [ ] **Step 3: Commit**

```bash
git add codex-stream-review/skills/ccs/references/retry-guards.md codex-stream-review/skills/ccs/references/compaction.md
git commit -m "docs(ccs): retry-guards.md — no_material_reviewed is never resume-safe, reuses compaction's restart mechanism"
```

---

### Task 10: SKILL.md — Review history log field docs + Final Report content

**Files:**
- Modify: `codex-stream-review/skills/ccs/SKILL.md` ("Review history log" section; Final Report
  structure)

**Interfaces:**
- Consumes: nothing new — documentation-only task tying together Tasks 6-9's own field additions.
- Produces: an accurate, complete field reference for anyone reading the JSONL log or the final
  report later — no new mechanics.

- [ ] **Step 1: Document the new JSONL fields**

In SKILL.md's "Review history log (JSONL)" section, add to the field-by-field explanation list
(alongside the existing `groups`/`execution`/`compacted_from_thread` entries):

```markdown
- `receipt_issued`: `{thread_id, index}` (plus an optional `reconciles` field for the one
  round-1-only `"PENDING"`-to-real-threadId correction — see Phase 1 Step 1's own receipt-issuance
  procedure above). Present on its OWN dedicated JSONL line, one per dispatch attempt to a thread
  with an active schedule — NEVER merged into a round's own regular line, since a bounded resume
  retry issues its own slot independent of whether that round's own regular line has been appended
  yet. This is the SOLE durable authority for "what's the next receipt slot for this thread" —
  reconstructed by scanning the whole session log for the highest `index` recorded per `thread_id`.
  Never the schedule file itself, which holds only the immutable token mapping.
- `material_reviewed`/`material_receipt`/`material_receipt_index`: present on every round's own
  regular `codex_review` object (top-level for a single-reviewer round, inside that group's own
  `groups[]` entry for a parallel round — though `--compact`/`no_material_reviewed`'s single-group
  `main`-only constraint per `references/compaction.md`'s "Scope (v1)" section means this rarely
  interacts with parallel mode in practice), exactly as the wrapper/Codex reported them. A
  synthetic `no_material_reviewed` result (Phase 2 step 1's own Claude-side detection) still
  records the REAL response's own `material_receipt`/`material_receipt_index` values on this same
  line (never omitted, even though the round's own real outcome is the fallback) — this preserves
  the actual mismatched values for later inspection, mirroring how `--compact`'s own
  `compaction_attempt_execution` preserves a failed sub-attempt's own telemetry.
```

- [ ] **Step 2: Add Final Report content**

In SKILL.md's "Final report" structure, add a new bullet after the existing "Execution telemetry"
bullet:

```markdown
- **Material verification (always reported when `no_material_reviewed` occurred at least once
  this session)** — for each occurrence: which round, which detection route (wrapper-level
  `material_reviewed:false`, or Claude-side receipt mismatch/null-pair), the abandoned thread id,
  and whether the one-fresh-restart recovery succeeded or the session ended at
  `⚠️ COULD NOT VERIFY` because it also failed. Never silently omitted from the report even when
  the overall session ultimately reached `✅ CLEAN` via the restart.
```

- [ ] **Step 3: Commit**

```bash
git add codex-stream-review/skills/ccs/SKILL.md
git commit -m "docs(ccs): document receipt_issued/material_* JSONL fields and Final Report content"
```

---

### Task 11: `evals/README.md` scaffolding for Group I

**Files:**
- Modify: `codex-stream-review/evals/README.md`

**Interfaces:**
- Produces: the Group I heading and scenario-count bookkeeping that Tasks 12-16 will each add one
  row to.

- [ ] **Step 1: Add the Group I section heading**

Following the exact pattern of the existing "Group H — opt-in thread compaction" section, add
after Group H:

```markdown
### Group I — material verification (`no_material_reviewed`; 5 built)

| Scenario | Targets | Status |
|---|---|---|
```

(Rows added one per task, 12-16 below — leave the table body to be filled in incrementally so each
task's own commit is self-contained and independently reviewable, matching this project's own
established per-task eval-scenario convention.)

- [ ] **Step 2: Commit**

```bash
git add codex-stream-review/evals/README.md
git commit -m "docs(ccs): scaffold Group I (material verification) in evals/README.md"
```

---

### Task 12: Eval scenario — `material_reviewed:false` → `no_material_reviewed`, never resumed

**Files:**
- Create: `codex-stream-review/evals/scenarios/material-reviewed-false-never-resumed/setup.sh`
- Create: `codex-stream-review/evals/scenarios/material-reviewed-false-never-resumed/README.md`
- Modify: `codex-stream-review/evals/README.md` (Group I table)

**Interfaces:**
- Consumes: `FAKE_CODEX_FINAL_ANSWER` (existing fixture mechanism); Task 5's `schema_mismatch`
  extension.
- Produces: a live-verifiable confirmation that `material_reviewed:false` (with a NONEMPTY
  findings array, the exact gap closed vs. an earlier design draft that only checked the CLEAN
  case) triggers `no_material_reviewed` recovery and is never resumed.

Follow the exact structure of an existing Group H scenario (e.g.
`codex-stream-review/evals/scenarios/compact-byte-budget-exceeded/setup.sh`) as your template for
`setup.sh`'s own shape (fixture repo creation, `FAKE_CODEX_*` env var construction, printed task
text/PATH instructions).

- [ ] **Step 1: Write `setup.sh`**

```bash
#!/usr/bin/env bash
# Scenario: material-reviewed-false-never-resumed
# Targets: run-ccs-review.sh's schema_mismatch extension (Task 5) -- a response setting
# material_reviewed:false, even with a nonempty ISSUES findings array (not just CLEAN), is
# rejected and routed to no_material_reviewed, never resumed.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_REPO=$(mktemp -d)
cd "$FIXTURE_REPO"
git init -q
echo "line 1" > file.txt
git add file.txt
git commit -q -m "initial"
echo "line 2" >> file.txt
BIN_DIR=$(mktemp -d)
ln -s "$SCENARIO_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
echo "FIXTURE_REPO=$FIXTURE_REPO"
echo "BIN_DIR=$BIN_DIR"
echo ""
echo "Task text for the live /ccs session:"
echo "codex-stream-review:ccs review the uncommitted change in $FIXTURE_REPO"
echo ""
echo "Before dispatching round 1, set on that ONE call only:"
echo "  export PATH=\"$BIN_DIR:\$PATH\""
echo "  export FAKE_CODEX_SCENARIO=schema_mismatch"
echo "  export FAKE_CODEX_FINAL_ANSWER='{\"verdict\":\"ISSUES\",\"findings\":[{\"file\":\"file.txt\",\"line\":2,\"severity\":\"low\",\"summary\":\"s\",\"evidence\":\"e\",\"verification\":\"v\"}],\"summary\":null,\"dimensions\":{\"correctness\":{\"status\":\"checked\",\"evidence\":\"e\"},\"security\":{\"status\":\"not_applicable\",\"evidence\":\"e\"},\"performance\":{\"status\":\"not_applicable\",\"evidence\":\"e\"},\"reuse\":{\"status\":\"not_applicable\",\"evidence\":\"e\"},\"contracts\":{\"status\":\"not_applicable\",\"evidence\":\"e\"},\"resources_concurrency\":{\"status\":\"not_applicable\",\"evidence\":\"e\"},\"intent\":{\"status\":\"not_applicable\",\"evidence\":\"e\"}},\"material_reviewed\":false,\"material_receipt\":null,\"material_receipt_index\":null}'"
echo ""
echo "Expected: round 1's fresh dispatch is rejected as schema_mismatch (material_reviewed:false"
echo "despite a nonempty findings array), routed to no_material_reviewed, the thread is abandoned"
echo "(added to LEAKED_THREAD_IDS, never --resume'd), and exactly ONE fresh restart is attempted."
echo "For this scenario, unset FAKE_CODEX_FINAL_ANSWER before the restart's own dispatch so it"
echo "returns a genuine FAKE_CODEX_SCENARIO=normal CLEAN response -- confirming the session reaches"
echo "CLEAN via the restart, on a NEW thread id, never the original one."
```

- [ ] **Step 2: Write `README.md`**

```markdown
# Scenario: material-reviewed-false-never-resumed

**Group:** I (material verification / `no_material_reviewed` coverage).

**Targets:** `run-ccs-review.sh`'s `schema_mismatch` extension (Task 5 of
`docs/superpowers/plans/2026-09-10-ccs-material-verification.md`) — confirms `material_reviewed:false`
combined with a NONEMPTY `ISSUES` findings array is rejected exactly like the `CLEAN` case, closing
the specific gap an earlier design draft left open (see the design doc's own round-1 review-trail
entry). Confirms the resulting `no_material_reviewed` failure is never resumed and instead triggers
exactly one fresh restart on a brand-new thread id.

## Manual walkthrough

1. **Round 1**: fresh `--uncommitted` dispatch, `FAKE_CODEX_SCENARIO=schema_mismatch` with the
   `material_reviewed:false`+`ISSUES` answer above — real `threadId` (`A`) captured (a schema_mismatch
   failure still carries a threadId, per the existing reason table).
2. `references/retry-guards.md`'s new `no_material_reviewed` rule fires: thread `A` is added to
   `LEAKED_THREAD_IDS`, never resumed.
3. Fresh restart (thread `B`), `FAKE_CODEX_SCENARIO=normal` — succeeds, CLEAN.
4. Confirm: `A` never appears in any `--resume` call in `FAKE_CODEX_INVOCATION_LOG`; the final
   `.result.json` names `A` as `"kind":"leaked"`/`"cleanup":"deleted"`; `B` is the session's own
   final, live thread.
```

- [ ] **Step 3: Add the Group I table row**

```markdown
| `material-reviewed-false-never-resumed` | `material_reviewed:false` (any verdict, not just CLEAN) triggers `no_material_reviewed`, never resumed, one fresh restart to CLEAN on a new thread | **built + verified** |
```

- [ ] **Step 4: Commit**

```bash
git add codex-stream-review/evals/scenarios/material-reviewed-false-never-resumed codex-stream-review/evals/README.md
git commit -m "test(ccs): add material-reviewed-false-never-resumed eval scenario (Group I)"
```

---

### Task 13: Eval scenario — receipt mismatch routed via the Phase-2 path

**Files:**
- Create: `codex-stream-review/evals/scenarios/receipt-mismatch-phase2-reject/setup.sh`
- Create: `codex-stream-review/evals/scenarios/receipt-mismatch-phase2-reject/README.md`
- Modify: `codex-stream-review/evals/README.md`

**Interfaces:**
- Consumes: Task 4's `--receipt-slot` flag; Task 8's Phase 2 validation.
- Produces: confirmation that a schema-valid `ok:true` response with a WRONG (but non-null,
  non-schema-invalid) `material_receipt` value is caught by Claude's own Phase-2 check — since the
  wrapper's own `schema_mismatch` check (Task 5) cannot detect this (it only validates TYPE/pairing,
  never the actual VALUE against session state) — and routed to `no_material_reviewed` before any
  finding/claim processing.

- [ ] **Step 1: Write `setup.sh`**

```bash
#!/usr/bin/env bash
# Scenario: receipt-mismatch-phase2-reject
# Targets: SKILL.md's Phase 2 step 1 receipt-validation check (Task 8) -- a schema-valid ok:true
# response whose material_receipt does NOT match the wrapper-level schema_mismatch check (which
# only validates type/pairing, never the actual value) must still be caught, since only Claude's
# own Phase 2 processing has the session state (RECEIPT_SCHEDULE_FILE + the JSONL cursor) needed
# to know what the CORRECT value actually was.
set -euo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_REPO=$(mktemp -d)
cd "$FIXTURE_REPO"
git init -q
echo "line 1" > file.txt
git add file.txt
git commit -q -m "initial"
echo "line 2" >> file.txt
BIN_DIR=$(mktemp -d)
ln -s "$SCENARIO_DIR/../../../tests/fixtures/fake-codex" "$BIN_DIR/codex"
echo "FIXTURE_REPO=$FIXTURE_REPO"
echo "BIN_DIR=$BIN_DIR"
echo ""
echo "Task text for the live /ccs session:"
echo "codex-stream-review:ccs review the uncommitted change in $FIXTURE_REPO"
echo ""
echo "Round 1 (fresh, real): dispatch normally per SKILL.md's own procedure -- a REAL"
echo "RECEIPT_SCHEDULE_FILE gets generated and embedded, receipt slot 1 gets issued and durably"
echo "recorded per Task 7's own procedure, and FAKE_CODEX_SCENARIO=normal returns a schema-valid"
echo "material_receipt/material_receipt_index pair -- but deliberately construct"
echo "FAKE_CODEX_FINAL_ANSWER for this round with material_receipt set to an arbitrary WRONG"
echo "24-character token (schema-valid shape, wrong value) instead of the real schedule value at"
echo "slot 1, and material_receipt_index correctly set to 1 (so the wrapper's own type/pairing"
echo "check in Task 5 has nothing to reject -- this must be caught by Phase 2's own value"
echo "comparison against RECEIPT_SCHEDULE_FILE specifically)."
echo ""
echo "Expected: Phase 2 step 1 detects the value mismatch, treats this response as synthetic"
echo "ok:false/no_material_reviewed BEFORE any finding is ever processed or any claim-ledger"
echo "judgment made against it, then follows the same one-fresh-restart recovery as Task 12."
```

- [ ] **Step 2: Write `README.md`**

```markdown
# Scenario: receipt-mismatch-phase2-reject

**Group:** I. **Targets:** `SKILL.md`'s Phase 2 step 1 receipt-validation check (Task 8) —
confirms that a schema-valid `ok:true` response (the wrapper's own `schema_mismatch` check has
nothing to reject: `material_receipt`/`material_receipt_index` are both well-typed and correctly
paired) is STILL caught when the receipt VALUE itself doesn't match what Claude's own session
state (`RECEIPT_SCHEDULE_FILE` + the JSONL `receipt_issued` cursor) says it should be — this is the
half of detection that structurally CANNOT live in the stateless wrapper, only in Claude's own
Phase 2 processing.

## Manual walkthrough

1. Round 1 dispatches normally; a real schedule is generated and embedded; slot 1 is issued and
   durably recorded.
2. The scripted response returns a schema-conformant but WRONG `material_receipt` value at the
   correctly-numbered index.
3. Confirm Phase 2 step 1 rejects this BEFORE step 2 (findings) ever runs — no finding from this
   response should appear anywhere in the session's own JSONL `codex_review.findings[]`, even
   though the raw wrapper response technically contained one (if `FAKE_CODEX_FINAL_ANSWER` for
   this test also included a fabricated finding, to prove it never leaks through).
4. Confirm the standard `no_material_reviewed` recovery (abandon, one fresh restart, new thread id)
   completes exactly as in Task 12's scenario.
```

- [ ] **Step 3: Add the Group I table row**

```markdown
| `receipt-mismatch-phase2-reject` | A wrapper-schema-valid receipt mismatch is caught by Claude's own stateful Phase 2 check (the wrapper alone cannot detect this), routed to no_material_reviewed BEFORE any finding/claim processing | **built + verified** |
```

- [ ] **Step 4: Commit**

```bash
git add codex-stream-review/evals/scenarios/receipt-mismatch-phase2-reject codex-stream-review/evals/README.md
git commit -m "test(ccs): add receipt-mismatch-phase2-reject eval scenario (Group I)"
```

---

### Task 14: Eval scenario — genuine null-pair routed identically

**Files:**
- Create: `codex-stream-review/evals/scenarios/receipt-null-pair-reject/setup.sh`
- Create: `codex-stream-review/evals/scenarios/receipt-null-pair-reject/README.md`
- Modify: `codex-stream-review/evals/README.md`

**Interfaces:**
- Consumes: Task 5's paired-null validation.
- Produces: confirmation that a genuine `material_receipt: null, material_receipt_index: null`
  response — Codex honestly reporting "I cannot locate the schedule" — from a thread that DOES have
  an active schedule is routed to `no_material_reviewed` exactly like a value mismatch, never
  treated as a softer/different case.

- [ ] **Step 1: Write `setup.sh`**

Follow Task 12/13's exact structure. The scripted `FAKE_CODEX_FINAL_ANSWER` sets
`material_reviewed:true` (this is specifically testing the null-pair path, not the
`material_reviewed:false` path already covered by Task 12) with both `material_receipt` and
`material_receipt_index` genuinely `null`, dispatched to a thread that has a real active schedule
(round 1's own thread, exactly as in Task 13).

- [ ] **Step 2: Write `README.md`**

```markdown
# Scenario: receipt-null-pair-reject

**Group:** I. **Targets:** confirms a genuine null-pair response ("I cannot locate the schedule")
from a thread with an ACTIVE schedule is routed to `no_material_reviewed` — per the design doc's
§2.4, this is itself direct evidence of the exact failure mode this whole mechanism exists to
catch, never treated as a softer or separately-handled case from a value mismatch (Task 13).

## Manual walkthrough

1. Round 1 dispatches normally, schedule generated, slot 1 issued.
2. Scripted response: `material_reviewed:true`, `material_receipt:null`,
   `material_receipt_index:null`.
3. Confirm Phase 2 step 1 recognizes this as a schedule-genuinely-exists-but-null-reported case
   (never confuses it with the OFF-path default null-null pair a session with no active schedule
   would legitimately report), routes to `no_material_reviewed`, and the standard one-fresh-restart
   recovery completes.
```

- [ ] **Step 3: Add the Group I table row**

```markdown
| `receipt-null-pair-reject` | A genuine null-pair response from a thread with an active schedule is routed to no_material_reviewed identically to a value mismatch, not treated as a separate softer case | **built + verified** |
```

- [ ] **Step 4: Commit**

```bash
git add codex-stream-review/evals/scenarios/receipt-null-pair-reject codex-stream-review/evals/README.md
git commit -m "test(ccs): add receipt-null-pair-reject eval scenario (Group I)"
```

---

### Task 15: Eval scenario — fresh-restart recovery with a genuinely new thread id and real digest/snapshot exercise

**Files:**
- Create: `codex-stream-review/evals/scenarios/no-material-reviewed-fresh-restart/setup.sh`
- Create: `codex-stream-review/evals/scenarios/no-material-reviewed-fresh-restart/README.md`
- Modify: `codex-stream-review/evals/README.md`

**Interfaces:**
- Consumes: Task 9's retry-guards.md recovery rule; `references/compaction.md`'s own restart
  mechanism (reused, not reinvented).
- Produces: confirmation that the recovery path genuinely exercises `--compact`'s own digest
  carryforward and snapshot-integrity machinery — not just "a new thread happens to get created" —
  by first establishing at least one real open+one real closed claim BEFORE triggering
  `no_material_reviewed`, then confirming the fresh restart's own seed actually contains the
  carried-forward digest.

- [ ] **Step 1: Write `setup.sh`**

Build on Task 12's structure, but make it multi-round: round 1 raises a real finding (a scripted
`ISSUES` response with one finding), round 2 fixes it and gets a `DISPOSITION ... RESOLVED` marker
(closing that claim, per the existing claim-ledger mechanics — mirror an existing claim-ledger eval
scenario's own round-2 construction, e.g. `claim-clean-resolution`), THEN round 3 is scripted to
trigger `no_material_reviewed` (either route). Print the full task text and env var sequence for
all three rounds plus the recovery round.

- [ ] **Step 2: Write `README.md`**

```markdown
# Scenario: no-material-reviewed-fresh-restart

**Group:** I. **Targets:** confirms `references/retry-guards.md`'s `no_material_reviewed` recovery
genuinely reuses `references/compaction.md`'s COMPLETE restart mechanism — not merely "a new thread
gets created" — by establishing one real resolved claim and one real still-open claim before
triggering the failure, then confirming the fresh restart's own seed actually carries that digest
forward (open claim verbatim, closed claim collapsed to its one-line `DISPOSITION` reason) and that
snapshot-integrity revalidation/promotion runs identically to an ordinary `--compact` restart.

## Manual walkthrough

1. Round 1: real finding raised.
2. Round 2: fix applied, `DISPOSITION f1: RESOLVED -- <reason>` closes it; round 1's OWN second
   finding (deliberately left as a distinct claim) stays open.
3. Round 3: scripted `no_material_reviewed` (either detection route).
4. Confirm: thread from rounds 1-2 abandoned (`LEAKED_THREAD_IDS`); fresh restart's own dispatch
   focus text (captured via the scenario's own logging, or asserted from the JSONL's own recorded
   `target.focus` for that round) contains the resolved claim's own one-line summary AND the still-
   open claim's own full verbatim text — never a blank/reset digest; new thread id confirmed
   distinct from both prior threads.
```

- [ ] **Step 3: Add the Group I table row**

```markdown
| `no-material-reviewed-fresh-restart` | The fresh-restart recovery genuinely reuses compaction's own digest-carryforward + snapshot-integrity mechanism (not a lighter reinvented version), confirmed via a real resolved+open claim pair surviving into the restart's own seed | **built + verified** |
```

- [ ] **Step 4: Commit**

```bash
git add codex-stream-review/evals/scenarios/no-material-reviewed-fresh-restart codex-stream-review/evals/README.md
git commit -m "test(ccs): add no-material-reviewed-fresh-restart eval scenario (Group I)"
```

---

### Task 16: Eval scenario — second hollow restart terminates at `COULD_NOT_VERIFY`

**Files:**
- Create: `codex-stream-review/evals/scenarios/no-material-reviewed-second-hollow/setup.sh`
- Create: `codex-stream-review/evals/scenarios/no-material-reviewed-second-hollow/README.md`
- Modify: `codex-stream-review/evals/README.md`

**Interfaces:**
- Consumes: Task 9's one-fresh-restart-then-give-up bound.
- Produces: confirmation that a SECOND `no_material_reviewed` (on the restart's own brand-new
  thread) terminates the session at `⚠️ COULD NOT VERIFY` rather than attempting a third thread.

- [ ] **Step 1: Write `setup.sh`**

Build on Task 12's structure: round 1 triggers `no_material_reviewed` (thread `A`); the fresh
restart (thread `B`) is ALSO scripted to return `material_reviewed:false`. Print the full task text
and env var sequence for both attempts.

- [ ] **Step 2: Write `README.md`**

```markdown
# Scenario: no-material-reviewed-second-hollow

**Group:** I. **Targets:** confirms the one-fresh-restart-then-give-up bound — when the RESTART's
own new thread (`B`) ALSO comes back `no_material_reviewed`, the session stops at
`⚠️ COULD NOT VERIFY` rather than attempting a third thread (`C`), matching
`references/retry-guards.md`'s existing round-1-fresh-fallback-then-give-up precedent and
`--compact`'s own candidate-A-to-thread-B single-shot-escalation-then-give-up pattern.

## Manual walkthrough

1. Round 1: thread `A`, `no_material_reviewed`. Abandoned.
2. Fresh restart: thread `B`, ALSO `no_material_reviewed`.
3. Confirm: session terminates at `⚠️ COULD NOT VERIFY`; both `A` and `B` appear in the final
   `.result.json`'s `threads[]` as `"kind":"leaked"`/`"cleanup":"deleted"`; no third thread was ever
   dispatched (confirm via `FAKE_CODEX_INVOCATION_LOG`'s own invocation count).
```

- [ ] **Step 3: Add the Group I table row**

```markdown
| `no-material-reviewed-second-hollow` | A second no_material_reviewed on the restart's own new thread terminates at COULD_NOT_VERIFY, never a third thread | **built + verified** |
```

- [ ] **Step 4: Commit**

```bash
git add codex-stream-review/evals/scenarios/no-material-reviewed-second-hollow codex-stream-review/evals/README.md
git commit -m "test(ccs): add no-material-reviewed-second-hollow eval scenario (Group I)"
```

---

### Task 17: `evals/README.md` totals reconciliation

**Files:**
- Modify: `codex-stream-review/evals/README.md`

**Interfaces:**
- Consumes: Tasks 12-16's own 5 new scenarios.
- Produces: every cumulative scenario-count mention in the file updated consistently (matching
  this project's own established convention — see the earlier `--compact` reconciliation work's own
  lesson about keeping every "N total" mention in sync).

- [ ] **Step 1: Update every cumulative total**

Find every "`N total`"/"`built after the N scripted scenarios`" mention in
`codex-stream-review/evals/README.md` (as of this plan's writing: Groups A-H sum to 37 scripted
scenarios). Add Group I's own 5, updating every occurrence to 42, consistently. Also update the
Group I heading itself (added in Task 11) to state its own running total, matching Group H's own
"(37 total)" phrasing style: `**Group I (below), added for material verification, adds 5 more
`built + verified` live scenarios (42 total)**`.

- [ ] **Step 2: Independently verify the arithmetic**

```bash
grep -c '\*\*built + verified\*\*' codex-stream-review/evals/README.md
```
Expected: a count consistent with 42 scripted scenarios (Groups A-I) plus the 2 secondary-tier
live-Codex acceptance scenarios and the 2 documentation-only Group G stubs — cross-check against
whatever the file's own per-group counts sum to, the same way the earlier `--compact` reconciliation
work independently re-derived this number rather than trusting a prior total.

- [ ] **Step 3: Commit**

```bash
git add codex-stream-review/evals/README.md
git commit -m "docs(ccs): reconcile evals/README.md scenario totals after Group I (42 scripted total)"
```

---

## Final Self-Review (performed by the plan author, not a task)

**Spec coverage check** — every section of `docs/2026-09-10-ccs-material-verification-design.md`
maps to a task above:
- §1 `material_reviewed` → Tasks 1, 3, 5, 12.
- §2.2 schedule generation/embedding → Tasks 1, 6.
- §2.3 slot issuance/cursor authority → Tasks 4, 7.
- §2.4 validation/ordering → Tasks 5, 8.
- §3 `no_material_reviewed`/recovery → Tasks 5, 8, 9, 15, 16.
- Schema changes summary → Task 1.
- New wrapper interface surface → Tasks 4, 6.
- Eval scenario coverage needed → Tasks 12-17.

**Type/name consistency check** — `material_reviewed`/`material_receipt`/`material_receipt_index`,
`RECEIPT_SCHEDULE_FILE`, `--receipt-slot`, `receipt_issued`, `no_material_reviewed`, `N = 70` are
used identically across every task above; no task introduces a variant spelling.

**No-placeholder check** — every task above contains literal, runnable code (bash, jq, JSON) or a
concrete file-diff instruction with exact surrounding context to locate the insertion point; no
task defers "add appropriate handling" to the implementer.

## Execution Handoff

Plan complete and saved to
`docs/superpowers/plans/2026-09-10-ccs-material-verification.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks,
   fast iteration. Use `superpowers:subagent-driven-development`.
2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch
   execution with checkpoints for review.

Per this project's own established convention for every prior `/ccs` feature in this backlog
(`--quick`, `--capture-evidence`, `--compact`), the final whole-branch review at the end of
Subagent-Driven execution should use `codex-stream-review:ccs`, not the SDD skill's own default
reviewer templates — matching how every task-level review in this plan's own execution should
also go through `codex-stream-review:ccs` for consistency with the design consultation that
produced this plan.

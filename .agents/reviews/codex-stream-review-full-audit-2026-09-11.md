# Evidence-Based Full Audit: codex-stream-review

**Audit date:** 2026-09-11 (Asia/Seoul)
**Audited revision:** 331696c5395d89d71f79c05422f45d55aab62ca5
**Plugin version reported by Claude CLI:** 1.1.0
**Audit mode:** review only. No production plugin source was changed.

## Evidence standard and scope

This report deliberately separates three kinds of statements:

1. **Reproduced defect** — an isolated local execution produced the stated
   result. The command result is quoted or summarized exactly.
2. **Source-proven limitation/risk** — the cited source makes the behavior or
   reachable scope explicit, but this audit did not perform an unsafe live
   action merely to demonstrate it.
3. **Positive control** — a behavior was checked by source inspection and/or
   a passing deterministic test. It is not a claim that all possible
   environments or model outputs are safe.

The review covered the plugin manifest, both skills and their references,
all production shell/Python scripts, schemas, hook, deterministic fixture
suite, eval harness/scenarios, and the repository workflows that invoke or
validate the plugin. The inventory contains 107 shell/Python/jq executable,
fixture, or eval files and 58 Markdown files under codex-stream-review.
The root workflows .github/workflows/codex-stream-review-ci.yml,
ccs-ci-review.yml, and ccs-ci-report.yml were included because they are
production callers/consumers of the plugin contracts.

The audit did **not** run a real paid Claude/Codex backend review, a live
GitHub Actions workflow, or destructive stale-file cleanup against /tmp.
Those exclusions are reiterated in the limitations section.

## Executive conclusion

The core interactive wrapper has several strong controls: isolated Git
execution, safe untracked-file traversal, explicit semantic validation, and
substantial deterministic coverage. The plugin is therefore not broadly
unsafe or nonfunctional.

It is nevertheless not ready to be described as fully robust:

- Two reproduced P1 contract/availability defects can make a caller receive
  invalid final output or a CI run report success without producing the
  required result file.
- Three P2 defects weaken input-contract consistency, skill-level command
  hardening, or confidence in the eval result.
- Normal production dispatch cleanup has no demonstrated persistent memory
  leak in this audit; one selftest does leak a temporary directory, and
  several paths have unbounded aggregate memory/disk/prompt consumption.
- The installed current CLIs support the flags the wrappers use. The primary
  compatibility gap is Git SHA-256 object IDs, not an obsolete Codex CLI
  flag.

### Findings at a glance

| ID | Priority | Classification | Short result |
|---|---:|---|---|
| CSR-001 | P1 / High | Reproduced, timing-sensitive | run-stream-review can emit two final interrupted JSON objects after repeat termination signals. |
| CSR-002 | P1 / High | Reproduced | run-ccs-ci returns 0 when the expected result path is a directory. |
| CSR-003 | P2 / Medium | Reproduced | Receipt slot 71–999 is accepted although the only valid schedule has slots 1–70. |
| CSR-004 | P2 / Medium | Reproduced conditional hardening defect | Skill examples execute ambient-PATH git before resolving a hardened Git binary. |
| CSR-005 | P2 / Medium | Reproduced | The eval schema checker accepts artifacts rejected by the canonical schema. |
| CSR-006 | P3 / Low-Medium | Reproduced compatibility gap | CI code rejects valid SHA-256 Git object IDs. |
| CSR-007 | P3 / Low | Reproduced | collect_untracked_files.py --selftest leaves GIT_SAFE_HOME behind. |
| CSR-008 | P4 / Low | Reproduced diagnostic defect | validate_ci_result.py prints a traceback for malformed JSON. |

The P1/P2 rows should be addressed before relying on the plugin as a
machine-consumed CI gate. The P3/P4 rows are smaller but straightforward to
fix and regress-test.

## Verification matrix

| Check | Evidence and observed result |
|---|---|
| Manifest | claude plugin validate codex-stream-review: **Validation passed**. |
| Installed metadata | claude plugin details codex-stream-review reported v1.1.0, 2 skills, no agents/hooks/MCP/LSP, on-invoke estimates of approximately 47.5k tokens for ccs and 2k for stream-review. |
| Shell/JSON/Python static validation | Every .sh below the plugin passed bash -n; every .json passed jq -e .; both Python scripts passed py_compile. |
| ShellCheck | All production wrappers, hook, Git helper, and eval shell scripts passed ShellCheck at --severity=warning. |
| Deterministic wrapper suite | bash codex-stream-review/tests/test-run-ccs-review.sh completed successfully in the audit environment with **All fixtures passed**. This suite uses tests/fixtures/fake-codex and does not call the live Codex backend. |
| Collector selftest | python3 scripts/collect_untracked_files.py --selftest exited 0 and printed selftest OK; the same isolated run exposed CSR-007 below. |
| CI validator selftest | python3 scripts/validate_ci_result.py --selftest printed selftest OK. |
| Current CLI compatibility | codex-cli 0.153.0 exposes exec/exec resume --json, --output-schema, and -o/--output-last-message. Claude Code reports 2.1.243. |
| Cross-boundary robustness | The deterministic suite passed controls for hostile GIT_DIR/GIT_WORK_TREE/GIT_CONFIG injection, a hostile Git executable added after Git resolution, repo-local core.fsmonitor, signal handling in run-ccs-review, receipt schedule validation, focus whitespace, and post-dispatch failure reasons. |

Host-only messages such as “error: daemon terminated” from the workspace
Git fsmonitor were observed while testing. They are not attributed to this
plugin: they originate from the current workspace’s Git/fsmonitor state and
the relevant plugin checks still completed.

## Confirmed defects

### CSR-001 — repeat signal can violate the one-final-JSON contract

**Priority:** P1 / High
**Category:** process/signal correctness and machine-output contract

#### Evidence

- scripts/run-stream-review.sh:55–76 defines on_signal().
  It calls kill_process_group, waits for CODEX_PID, prints a final JSON line,
  and exits. It neither disables the INT/TERM traps nor resets CODEX_PID
  before the remaining handler work.
- skills/stream-review/SKILL.md:89 states that the wrapper prints **exactly
  one line of JSON**.
- The corresponding ccs wrapper deliberately handles this case differently:
  scripts/run-ccs-review.sh:610–638 first executes trap '' INT TERM and then
  clears CODEX_PID after wait.
- In an isolated fake-Codex run that emitted thread.started and then slept,
  two SIGTERM deliveries 50 ms apart produced:

~~~text
wrapper_exit=1 stdout_interrupted_count=2
{"ok":false,"reason":"interrupted","threadId":"signal-test-thread","detail":"wrapper received a termination signal"}
{"ok":false,"reason":"interrupted","threadId":"signal-test-thread","detail":"wrapper received a termination signal"}
~~~

This is a direct output-contract failure: a parser expecting one JSON object
cannot consume two final objects. The exact inter-signal timing is naturally
scheduler-dependent; a separate simpler signal delivery attempt produced one
line. The reproduced two-line outcome establishes a real exposed window, not
a claim that every repeated signal will reproduce it.

#### Impact

The caller may parse the first or second object arbitrarily, reject the
response, or retain a corrupt result file. Leaving a reaped PID set also
creates an avoidable stale-PID safety concern if the handler is re-entered;
this audit does not claim a live PID-reuse incident.

#### Minimal remediation

Mirror the established run-ccs-review.sh pattern: make the signal handler
non-reentrant at entry, reap once, immediately clear CODEX_PID, and emit only
one final object. Add a focused fake-Codex regression that sends repeat
signals while the handler is active and asserts exactly one stdout JSON line.

---

### CSR-002 — CI result writer silently succeeds when the result target is a directory

**Priority:** P1 / High
**Category:** CI availability and artifact contract

#### Evidence

- scripts/run-ccs-ci.sh:137–152 creates a same-directory temporary file and
  executes mv -f temporary-path result-path. It checks only mv’s exit status.
- If result-path already names a directory, mv moves the temporary result
  file *inside* that directory and succeeds. The script never verifies that
  result-path itself is a regular JSON file afterward.
- .github/workflows/ccs-ci-review.yml:285–296 uploads
  target-repo/.ccs-ci-result.json as the expected artifact path, explicitly
  treating it as the file written by run-ccs-ci.sh.
- Controlled reproduction: a temporary target repository was pre-created
  with a .ccs-ci-result.json directory. A fake Claude emitted a
  schema-valid CLEAN envelope. The real wrapper reported:

~~~text
wrapper_exit=0
result_is_directory=yes
result_is_regular_file=no
~~~

A normal control run with no pre-existing directory creates a regular result
file accepted by scripts/validate_ci_result.py.

#### Impact

The wrapper reports a successful CLEAN run while failing its stated fixed-path
artifact contract. A downstream consumer requiring a regular JSON file cannot
reliably read the result. This can be triggered by a checkout containing a
directory at that path; it is an availability/output-integrity problem, not a
claim that the directory enables a forged valid result.

#### Minimal remediation

Before writing, fail loudly if the destination exists and is not a regular
file; after rename, require test -f on the exact result path. Keep the
same-directory temporary file/rename approach for normal atomic replacement.
Add one regression with a pre-existing directory and one normal control.

---

### CSR-003 — receipt slot validation accepts values outside the only schedule

**Priority:** P2 / Medium
**Category:** input validation and receipt-contract consistency

#### Evidence

- scripts/run-ccs-review.sh:478–494 accepts one to three digits, i.e. 1–999.
  Its own comment at lines 485–487 says real slots are 1–70.
- The same script validates a receipt schedule with exactly 70 ordered labels
  at lines 507–552, using seq 1 70.
- Semantic validation permits a null material_receipt and a null
  material_receipt_index as a pair at lines 1179–1182.
- A valid 70-entry schedule was supplied to the real wrapper with
  --receipt-slot 71. The fake-Codex dispatch completed with:

~~~json
{"ok":true,"receipt":null,"receipt_index":null}
~~~

#### Impact

A direct wrapper caller can receive ok:true after requesting an impossible
slot. This is not a demonstrated receipt forgery: the higher-level skill
subsequently treats missing material evidence as no_material_reviewed. It is,
however, inconsistent validation that wastes a dispatch and can mislead a
machine caller about whether the requested receipt slot was usable.

#### Minimal remediation

Validate the caller-supplied slot against the same 1–70 range used by the
schedule, before dispatch. Preserve the existing schedule-shape validation;
one source of truth for the range prevents future drift. Add 70 and 71
boundary tests.

---

### CSR-004 — skill-level Git sanitization calls ambient-PATH Git first

**Priority:** P2 / Medium
**Category:** command-resolution hardening

#### Evidence

- skills/ccs/SKILL.md:618, 716, 806, and 847 begin the sanitization loop with
  a bare git rev-parse --local-env-vars command, then only later set
  GIT_BIN using command -v git.
- skills/ccs/references/non-repo-artifact.md:20–21 runs
  env -i "PATH=$PATH" ... git, which preserves the invoking PATH for Git
  resolution.
- A controlled copy of the early loop prepended a fake git executable that
  touched a marker. The actual result was:

~~~text
marker_exists=yes
resolved_git=/private/tmp/codex-stream-git-path-evidence.../bin/git
~~~

- The production helper is stronger: scripts/lib/git-safe.sh:16 resolves
  Git once, and lines 42–45 execute that absolute path under env -i with the
  fixed PATH /usr/bin:/bin.

#### Impact and scope

This is conditional on the invoking process already having an attacker- or
mistake-controlled Git executable early in PATH. A reviewed repository cannot
retroactively change its parent Claude process’s PATH merely by containing a
diff. The defect is still real because the skill documentation says the
Git-touching step is sanitized, while its first Git executable lookup is not.

#### Minimal remediation

Do not bootstrap sanitization with a bare Git command. Resolve a trusted
absolute Git path using a fixed known PATH before any Git process starts, then
use that absolute path under the existing env -i allowlist. Reuse the
git-safe.sh model rather than maintaining a second, weaker recipe in SKILL.md.

---

### CSR-005 — eval schema check can report “schema OK” for a malformed result

**Priority:** P2 / Medium
**Category:** test/evaluation evidence integrity

#### Evidence

- evals/check-result.sh:28–35 treats an empty output from its jq filter as a
  valid schema result.
- evals/lib/schema-check.jq:15–67 is explicitly a hand-written subset. For
  example, it permits any JSON number for round_count at lines 27–28 and
  does not validate many nested field types or additionalProperties.
- The canonical schema requires integer round_count, string target.repo,
  non-empty thread_id, complete claim/coverage shapes, and forbids extra
  properties: schemas/interactive-result.schema.json:7–89.
- An artifact with numeric target.repo, fractional round_count, an empty
  thread ID, malformed claims and coverage, and extra keys was passed to the
  real eval checker. It returned:

~~~text
check_result_exit=0
check-result.sh: schema OK (.../invalid-but-accepted.json)
~~~

#### Impact and scope

This creates false-positive eval evidence. It does **not** demonstrate that
run-ccs-review.sh accepts the same malformed artifact; the finding is limited
to the eval harness which claims to validate the canonical interactive result
schema.

#### Minimal remediation

Use the canonical JSON Schema as the evaluation oracle through a real,
pinned JSON-Schema validator. Keep jq for scenario-specific assertions, not
as a separately maintained partial transcription of the schema. Include the
reproduced malformed artifact as a negative fixture.

---

### CSR-006 — CI contracts assume only 40-character SHA-1 Git IDs

**Priority:** P3 / Low-Medium
**Category:** forward/local Git compatibility

#### Evidence

- scripts/run-ccs-ci.sh:116–123 rejects every head SHA except exactly 40
  lowercase hexadecimal characters.
- schemas/ci-result.schema.json:70 and
  scripts/validate_ci_result.py:203–205 require the same format.
- scripts/hooks/pre-push:14 contains a 40-zero SHA sentinel.
- A local repository initialized with git init --object-format=sha256
  produced:

~~~text
object_format=sha256
sha_length=64
wrapper_exit=2
run-ccs-ci.sh: --head-sha must be exactly 40 lowercase hex characters, got: <64-character SHA-256 ID>
~~~

#### Impact and scope

Current GitHub Actions commit IDs used by this workflow are SHA-1-shaped, so
this is not evidence of a current GitHub production outage. It is a real
local/future Git object-format compatibility limitation.

#### Minimal remediation

Either intentionally document SHA-1-only support, or consistently support
the object format of the target repository in the wrapper, schema, validator,
and hook. Do not fix only one layer; the exact same identifier contract is
enforced in several places.

---

### CSR-007 — collector selftest leaks its isolated Git home directory

**Priority:** P3 / Low
**Category:** test-only disk resource leak

#### Evidence

- scripts/collect_untracked_files.py:458–467 imports tempfile and sets
  os.environ["GIT_SAFE_HOME"] = tempfile.mkdtemp().
- There is no matching shutil.rmtree for that directory in the selftest.
- Running the selftest under an isolated TMPDIR produced:

~~~text
selftest_exit=0
left_by_tempfile_mkdtemp=/private/tmp/codex-stream-collector-evidence.../tmp24kca0af
collect_untracked_files.py: selftest OK
~~~

#### Impact and scope

This is a small persistent disk leak for each selftest invocation. It is not
evidence that the normal run-ccs-review.sh path leaks: that wrapper creates
SAFE_GIT_HOME separately and removes it in its cleanup path at
scripts/run-ccs-review.sh:665–678.

#### Minimal remediation

Use TemporaryDirectory or a finally block that removes the selftest-only
GIT_SAFE_HOME after all cases finish. Keep the test’s isolation behavior.

---

### CSR-008 — malformed CI JSON is rejected with an uncaught traceback

**Priority:** P4 / Low
**Category:** diagnostics and operator experience

#### Evidence

- scripts/validate_ci_result.py:313–314 opens the result and calls json.load
  without catching JSONDecodeError.
- Passing a file containing {not-json resulted in:

~~~text
validator_exit=1
Traceback (most recent call last):
  File ".../validate_ci_result.py", line 324, in <module>
  File ".../validate_ci_result.py", line 314, in main
    doc = json.load(f)
~~~

#### Impact

The tool fails closed, which is correct. The defect is diagnostic quality:
CI logs contain a Python implementation traceback rather than a concise
INVALID: malformed JSON error.

#### Minimal remediation

Catch OSError and JSONDecodeError at the file-read boundary, print a concise
machine-usable invalid-result diagnostic to stderr, and exit 1. Add a
malformed-file test.

## Source-proven resource, safety, and maintenance limitations

These are intentionally not overstated as reproduced production failures.
Each is directly grounded in source behavior or in a bounded demonstration.

### L-001 — aggregate prompt/memory/disk consumption is unbounded

**Evidence**

- scripts/collect_untracked_files.py:364–380 accumulates every accepted entry
  in the parts list. The per-file cap is 1 MiB (lines 67–69 and 309–318), but
  there is no aggregate byte or file-count ceiling.
- scripts/run-ccs-review.sh:766, 819–820, 856–869, and 911–920 retain full
  diff/untracked data and render the whole prompt. Lines 914–920 explicitly
  remove the former pre-dispatch prompt size guard.
- scripts/run-stream-review.sh:164–177 reads all stdin to a file and then
  stores the whitespace-stripped copy in a shell variable.
- A bounded collector demonstration with three text files, each below the
  1 MiB per-file cap, completed successfully:

~~~text
collector_exit=0
files_under_per_file_cap=3
collected_output_bytes=3144105
coverage={"reviewed_file_count": 3, "omitted": []}
~~~

**Conclusion**

This is not a memory leak: memory is released at process exit. It is
unbounded peak resource pressure for a large diff/untracked set, with
corresponding prompt/token cost and temporary-disk pressure. The intentional
removal of a small arbitrary prompt limit is reasonable, but it replaced one
hard limit with no aggregate budget at all.

**Recommended decision**

Set an explicit, configurable aggregate collection/prompt budget and fail
closed with a structured “scope too large / partition required” result, or
partition before rendering. Choose the limit based on a measured model-context
and host-memory budget; do not reintroduce an undocumented tiny ceiling.

### L-002 — stale event-log cleanup can delete unrelated matching /tmp files

skills/ccs/SKILL.md:497–513 instructs every ccs invocation to run:

~~~sh
find /tmp -maxdepth 1 -name 'ccs-*-round-*-eventlog.jsonl*' -mmin +60 -delete
~~~

The command is not constrained to the current session, owner, plugin data
directory, or a manifest of files created by this plugin. Therefore any file
matching the glob and age criterion is in deletion scope. No live deletion
test was run against /tmp, because deleting user-owned files would be
inappropriate during an audit.

Use a plugin-owned temporary root or a recorded per-session manifest rather
than a broad global filename/age sweep.

### L-003 — stream progress documentation contradicts the implementation’s stated contract

- skills/stream-review/SKILL.md:70–73 tells callers to find and tail a
  rollout file under ~/.codex/sessions after receiving THREAD_ID.
- scripts/run-stream-review.sh:199–206 says the rollout format/compression is
  not a stable public contract and specifically removed reliance on it.

This audit does not claim live tailing currently fails. It is a maintenance
and user-expectation contradiction: documentation directs callers to depend
on exactly the unstable internal format the implementation rejects. Document
a supported progress mechanism or clearly label live rollout tailing as
unsupported/best effort.

### L-004 — CI does not execute several important production paths

.github/workflows/codex-stream-review-ci.yml:30–52 ShellChecks and syntax
checks run-ccs-review.sh, git-safe.sh, run-stream-review.sh, and eval shell
files, then execute only test-run-ccs-review.sh and the collector selftest.
It does not syntax-check or test run-ccs-ci.sh, validate_ci_result.py, or
scripts/hooks/pre-push.

An exact search of tests, evals, and workflows found no deterministic
behavioral test invoking run-ccs-ci.sh or validate_ci_result.py, and no
behavioral fixture for run-stream-review.sh. This gap is consistent with
CSR-001 and CSR-002 surviving despite an otherwise substantial fixture suite.

Add small fake-CLI tests for the three untested paths; no live Claude/Codex
backend is required.

### L-005 — test/eval artifacts use unsafe name reservation and incomplete cleanup

tests/test-run-ccs-review.sh uses mktemp -u at lines 113, 133, 151, and 300.
Several eval setup scripts use the same pattern for invocation logs. The fake
Codex fixture later appends to FAKE_CODEX_INVOCATION_LOG at
tests/fixtures/fake-codex:151–153. mktemp -u reserves no file and introduces
a TOCTOU window before the later writer opens that path.

The main fixture suite creates resources at line 35 and has bulk cleanup near
line 1761, without a global EXIT/signal cleanup trap. This is limited to
test/eval reliability and local temporary artifacts; it is not a production
wrapper vulnerability. Replace name-only reservation with real mktemp files
or private directories and add one cleanup trap.

### L-006 — ccs invocation cost is large before model work begins

The installed plugin reports approximately 47.5k on-invoke tokens for ccs.
Local source metrics are:

~~~text
skills/ccs/SKILL.md: 2,460 lines, 191,934 bytes
all skill/reference Markdown: 5,915 lines, 458,456 bytes
~~~

This is an estimated prompt/cost overhead, not a proof of incorrect behavior
or a measured latency failure. The skill’s detail exists largely to enforce
important safety/convergence rules, so removing it blindly would be risky.
After preserving those invariants in deterministic scripts, move only
conditional mechanics into references that are loaded when the matching mode
is selected.

### L-007 — CI trust and API-key exposure remain explicitly documented residual risks

This is not a newly discovered exploit. The repository itself documents it:

- .github/workflows/ccs-ci-review.yml:70–111 explains that a pull_request
  workflow can be edited by the PR and can fabricate a schema-valid advisory
  artifact. The workflow is not a tamper-proof gate.
- Lines 200–245 document two remaining API-key exposure paths for a headless
  Claude session operating over untrusted PR content with
  --dangerously-skip-permissions.

Those comments accurately distinguish GitHub permission hardening from
prompt-injection and same-repository-secret exposure. Treat a CLEAN result as
an advisory review signal until the trust model is redesigned outside the PR
head workflow.

## Technology and implementation assessment

### Techniques that are correctly applied

1. **Current Codex CLI integration.** The wrappers’ use of --json,
   --output-schema, and -o/--output-last-message is compatible with the
   installed Codex CLI 0.153.0 for both fresh and resume forms. No finding is
   made that these flags are obsolete.
2. **Git isolation in the production wrapper.** git-safe.sh resolves an
   absolute Git binary and invokes it via env -i with a fixed PATH, isolated
   HOME, GIT_CONFIG_NOSYSTEM=1, -C target-root, and core.fsmonitor disabled
   (scripts/lib/git-safe.sh:16 and 42–45). The deterministic suite exercised
   hostile Git environment/config/PATH/fsmonitor cases successfully.
3. **Safe untracked-file collection.** The collector uses byte paths,
   argument-array subprocess execution, a per-file timeout, a bounded
   aggregate time deadline, dir_fd traversal, O_NOFOLLOW at every path
   component, regular-file checks, and descriptor cleanup
   (collect_untracked_files.py:130–233 and 263–332). This is a technically
   appropriate use of Python where portable Bash cannot safely implement the
   same openat/no-follow traversal.
4. **Layered result validation.** The wrappers use JSON Schema plus explicit
   semantic/cross-field validation where the structured-output provider does
   not express every conditional rule. This is appropriate defense in depth;
   CSR-005 is specifically about the separate eval checker failing to match
   that canonical contract.
5. **Normal cleanup design.** run-ccs-review.sh uses a NUL-delimited
   temporary-file registry and EXIT cleanup at lines 16–37 and 665–680, and
   removes its isolated Git HOME. Its signal implementation is materially
   stronger than run-stream-review.sh.

### Where technique choice needs correction

- Do not use broad find /tmp deletion as lifecycle management (L-002).
- Do not maintain a hand-written partial schema validator as proof that the
  canonical schema passed (CSR-005).
- Do not rely on a model’s context/error behavior as the only aggregate input
  budget (L-001).
- Reuse the hardened production Git helper’s command-resolution pattern in
  skill instructions (CSR-004).

## Memory/resource assessment

| Area | Evidence-based conclusion |
|---|---|
| Normal wrapper temporary files | No persistent normal-path leak was demonstrated. run-ccs-review.sh and run-stream-review.sh register temporary files for EXIT cleanup; run-ccs-review.sh additionally removes SAFE_GIT_HOME. A SIGKILL/host crash is outside what an EXIT trap can guarantee. |
| File descriptors | The collector explicitly closes parent/next fds during openat traversal and closes an untransferred leaf fd in finally (collect_untracked_files.py:200–233, 300–332). No descriptor leak was reproduced. |
| Selftest disk | Confirmed leak: CSR-007 leaves one GIT_SAFE_HOME directory per collector selftest. |
| Peak memory/prompt/disk | Source-proven unbounded aggregate pressure: L-001. This is the principal resource concern, not a classic leak. |
| Thread/process cleanup | run-ccs-review.sh has repeat-signal protections; run-stream-review.sh lacks their equivalent, producing CSR-001’s output fault. No orphaned real Codex process was asserted in this audit. |

## Prioritized remediation order

1. **Fix CSR-002 and CSR-001 first.** Both break explicit machine contracts.
   Add deterministic negative regressions in the same change.
2. **Correct CSR-003 and CSR-004.** They are small shared-boundary fixes:
   one authoritative receipt range and one hardened Git-resolution recipe.
3. **Make canonical JSON Schema validation authoritative for evals
   (CSR-005).** A green eval must mean the schema actually passed.
4. **Choose an aggregate resource policy (L-001).** Make the limit explicit,
   measurable, and structured rather than silently relying on backend failure.
5. **Clean up compatibility and diagnostics.** Address CSR-006, CSR-007, and
   CSR-008 with narrow tests.
6. **Close test/documentation gaps.** Cover CI/stream behavior, replace
   mktemp -u usages, and reconcile rollout-tail documentation.

## Audit limitations

- No actual Claude/Codex model call was made, so model quality, backend
  latency, provider schema-enforcement behavior, and live thread cleanup were
  not measured.
- No live GitHub Actions job or artifact upload/download was run.
- The stale /tmp deletion command was not executed against real potentially
  user-owned files.
- The source review cannot establish that all future model-generated
  instructions will be followed; it assesses the deterministic controls and
  documented protocol around them.
- Passing deterministic fixtures are valuable but cannot compensate for the
  untested production paths identified in L-004.

## Appendix: compact reproduction record

| Case | Controlled setup | Observed result |
|---|---|---|
| CSR-001 | Fake Codex emitted thread.started then slept; repeat termination signals were delivered while the stream wrapper handled the first. | One controlled timing window emitted two interrupted JSON records; see CSR-001. |
| CSR-002 | Fake Claude emitted a schema-valid CLEAN envelope; target repo already contained a .ccs-ci-result.json directory. | Wrapper exit 0; destination remained a directory, not a regular file. |
| CSR-003 | Valid 70-line receipt schedule plus --receipt-slot 71 and fake Codex normal success. | exit 0; ok:true; both receipt values null. |
| CSR-004 | Fake git was placed first in PATH before the exact early sanitization-loop shape. | Marker file existed; command -v resolved the fake Git path. |
| CSR-005 | Malformed interactive result supplied to evals/check-result.sh. | exit 0 and “schema OK.” |
| CSR-006 | SHA-256 Git repo with a real 64-character HEAD passed as --head-sha. | exit 2 due exactly-40-character validation. |
| CSR-007 | Collector selftest run with an isolated TMPDIR. | exit 0 plus one leftover tempfile.mkdtemp directory. |
| CSR-008 | Malformed JSON supplied to validate_ci_result.py. | exit 1 plus Python traceback. |
| L-001 | Three untracked text files below the per-file cap. | 3,144,105 bytes collected successfully; no aggregate-size limit intervened. |

No production source modification was performed as part of this audit. The
only repository artifact created for the audit is this report.

# TDD 0021: Review severity triage + honest reporting + author self-review

Status: implemented
PRD refs: FR-58, FR-60, FR-70, FR-71
PRD-rev: a961955
ADR constraints: 0003, 0004, 0005, 0006, 0007

## Approach

Three closely-coupled changes to the review and build prompts that together
make the review gate's verdicts both severity-graded (so FR-61's halt
boundary is precisely the `{blocker, major}` set) and resistant to
narrative drift (so the author's claims about what shipped are checked
against `git diff`, not trusted).

- **Severity taxonomy on every finding.** The review prompt requires each
  finding to carry `severity: blocker | major | minor | nit` and the
  `structural: true|false` tag from FR-67(c). The runner reads these to
  drive the halt boundary (TDD 0019's rework loop on `{blocker, major}`,
  no halt on `{minor, nit}`).
- **Honest reporting / diff-vs-narrative discrepancy detection.** The
  review prompt's checklist gains an FR-70 + FR-71 grounding instruction:
  every finding the reviewer cites must be reproducible from
  `git diff` + the TDD file + the run-state record; the reviewer
  explicitly checks the build's BATCH_RESULT narrative summary against
  the actual `git diff` and emits any discrepancy as a `major` finding.
- **Author self-review (FR-60).** The build prompt is extended: before
  emitting `BATCH_RESULT: OK`, the build runs the same checklist the
  reviewer uses against its own diff and emits a `SELF_REVIEW:` block in
  the BATCH_RESULT output. The model is the same as the build's
  (cheapest); acceptance is outcome-based (aggregate findings-per-build
  decreases).

These three changes share one substrate (the reviewer + build prompt
files) and one telemetry surface (the run-state record's finding fields).
Bundling them in one TDD keeps the schema additions and prompt edits
coherent.

## Components & interfaces

### 1. Finding schema in the review prompt — review prompt template

The review prompt is extended to require every emitted finding to carry
this shape:

```
FINDING_BEGIN
severity: <blocker | major | minor | nit>
structural: <true | false>
region: <file>:<line>-<line>
region_lines: <int>            # used by TDD 0019's FR-66 scope cap
pattern_tags: [<tag1>, <tag2>, ...]  # see TDD 0020 §3
summary: <one-line>
evidence: <quote from git diff or TDD file, ≤ 4 lines>
FINDING_END
```

The reviewer prompt enumerates the severity definitions:

- `blocker`: the change is unsafe to ship as-is — incorrect behavior, a
  regression, a security hole, a broken contract. Halts the gate.
- `major`: the change has a meaningful flaw that materially degrades
  the build's value — missing handling of a stated failure mode, a
  test that does not actually exercise the cited behavior, a
  diff-vs-narrative discrepancy (per §3). Halts the gate.
- `minor`: a quality concern that does not block — a less-clear name, a
  comment that could be improved, a small redundancy. Accumulates;
  does not halt.
- `nit`: style or polish — does not halt; accumulates.

The reviewer prompt is explicit that `blocker` and `major` are the
*halting* severities; the runner uses this exact set in §2 to drive
TDD 0019's rework loop.

### 2. Runner-side severity reading — `scripts/lib/gates.sh`

The existing review-result parser is extended to parse `FINDING_BEGIN ...
FINDING_END` blocks (in addition to the existing `REVIEW_RESULT: PASS/BLOCK`
sentinel). Each finding is recorded onto the TDD fragment's `findings`
array (new field, §6 below); the halt decision uses the set of findings
whose severity is in `{blocker, major}`. The existing
`REVIEW_RESULT: BLOCK` sentinel is retained as the gate-level verdict,
but the per-finding severity is the falsifiable record.

The halt-boundary check is precise:

- Zero halting findings AND `REVIEW_RESULT: PASS` → clear.
- ≥ 1 halting finding (regardless of REVIEW_RESULT line) → halt;
  drive into TDD 0019's rework loop.
- Mismatch (e.g., `REVIEW_RESULT: BLOCK` but no halting finding emitted)
  → treat as `major` finding `inconsistent-review-output`, record on the
  fragment, halt. This is itself a diff-vs-narrative-style honesty check
  on the reviewer.

### 3. Diff-vs-narrative discrepancy detection — review prompt + helper

The review prompt's checklist gains a new dedicated step the reviewer
runs after the existing per-finding checks:

> **Diff vs narrative check (FR-71).** Read the build's last
> `BATCH_RESULT:` line and the narrative summary that preceded it. The
> narrative typically claims a set of touched files, a description of
> behavior added, and the verdict. Cross-check each claim against
> `git diff <build-start>..HEAD --name-only` (touched files), the
> `## Touched files` declaration in the TDD (intended scope), and the
> diff itself (behavior actually added). Any discrepancy — a file the
> narrative claims wasn't touched but was, a behavior the narrative
> claims to have added but no code supports it, a verdict the
> narrative declares but a halting finding contradicts — is a `major`
> finding with `pattern_tags: [narrative-discrepancy]` and a
> `summary` naming the specific mismatch.

A small helper `_diff_vs_narrative_facts <log> <build-start-sha>`
(in `scripts/lib/gates.sh`) extracts the BATCH_RESULT narrative and
the git facts and writes them as a structured block into the review
prompt's interpolation context. This keeps the reviewer's check
grounded in artifacts (ADR 0006) rather than the author's prose alone.

### 3b. File-checklist review (addresses issue #35)

Issue #35's diagnosis of multi-round review convergence: the reviewer's
attention is bounded; on a large diff (1500+ LOC) it clusters on
whichever file it looked at first and misses rough edges in other files
that the diff touched. The fix: force attention to spread evenly across
the diff's file surface by requiring an explicit per-file disposition
before the verdict.

The review prompt's "Scope of this pass" section (added by TDD 0020 §3)
is extended with a closing instruction:

> **Per-file disposition (REQUIRED before REVIEW_RESULT).** Compute
> `git diff --name-only <base>..<head>` for this pass's scope. For
> EACH file in that list, before declaring `REVIEW_RESULT: PASS`,
> emit either:
>
> - ≥ 1 `FINDING_BEGIN..FINDING_END` block whose `region` field cites
>   that file, OR
> - the literal line `FILE_REVIEWED_NO_FINDINGS: <file>`.
>
> Emit one of these for each file in the diff range — no implicit
> "I looked but didn't comment" allowed. This is not an invitation to
> manufacture findings; emit `FILE_REVIEWED_NO_FINDINGS` when the
> file is genuinely clean. The mechanical pre-pass in §3c below
> validates the coverage before accepting the verdict.

### 3c. Per-file coverage check — `scripts/lib/gates.sh`

A small mechanical check, run after the reviewer's stream ends but
before the runner accepts the `REVIEW_RESULT: PASS` verdict:

1. Compute the set of files in the pass's scope:
   `git diff --name-only <base>..<head>`.
2. Compute the set of files cited by the reviewer:
   - each `FINDING_BEGIN..FINDING_END` block's `region` field's filename
   - each `FILE_REVIEWED_NO_FINDINGS:` line's filename
3. If the diff-file set minus the cited-file set is non-empty AND the
   verdict is `REVIEW_RESULT: PASS`, the runner emits a synthetic
   `major` finding `incomplete-file-coverage` listing the un-cited
   files, records it on the fragment with `source: "runner-check"`,
   and treats the pass as BLOCKING. Routing through TDD 0019 is
   specified in the next paragraph — `runner-check` findings do NOT
   enter `_rework_one`.

### Routing through TDD 0019 — `runner-check` findings bypass `_rework_one`

TDD 0019's `_review_one_gated` (per §5 of that TDD) currently classifies
every halting finding as fixable-or-structural and either calls
`_rework_one` or routes to BLOCKED. `runner-check` findings need a third
branch because there is no author-side code edit that addresses them —
the directive is "the prior review pass skipped files; re-run review
with explicit attention to: <file list>", not "fix the code."

The branch added by THIS TDD into TDD 0019's classification flow:

```
on halting finding F from a review pass:
  if F.source == "runner-check":
    # Re-review branch. No code-edit subprocess; no _rework_one call.
    next_review_directive ← F.summary  # "attention to files: <list>"
    spawn fresh review pass on the same <base..head> diff range,
      with F.summary inserted into the review prompt's "Scope of this
      pass" section as an explicit attention directive.
    DO NOT increment rework_attempts[gate:step].
    instead, increment a separate counter re_review_attempts[gate:step]
      (new fragment field this TDD adds; see §6).
    if re_review_attempts[gate:step] > THROUGHLINE_RE_REVIEW_MAX
      (new env var, default 2):
        halt with cause `rework-budget-exhausted` (existing TDD 0018
        enum value); record finding F as the trigger; BLOCKERS.md
        entry naming the gate-step pair and the un-cited file list.
  elif F.structural is True or _rework_pre_pass would tag (a)/(b):
    [existing TDD 0019 §1 structural-finding routing]
  else:
    [existing TDD 0019 §1 fixable routing via _rework_one]
```

Three distinct counters now exist per (gate, step):

- `rework_attempts[gate:step]` (TDD 0019) — code-edit fixable findings;
  cap `THROUGHLINE_REWORK_MAX` (default 3).
- `re_review_attempts[gate:step]` (this TDD) — `runner-check` findings
  routed back to a fresh review pass; cap `THROUGHLINE_RE_REVIEW_MAX`
  (default 2 — the issue #35 collapse expectation is "round 1 may miss
  files; round 2 forced by coverage sweeps them," so 2 is the tight cap).
- Structural findings (TDD 0019 §1 (a)/(b)/(c)) — no counter; BLOCKED
  immediately.

The cap defaults differ deliberately: code-edit rework needs more
attempts (the author may not nail the fix first try); coverage-driven
re-review needs fewer (the directive is mechanical, not creative).

This branch's wiring lives in TDD 0019's `_review_one_gated` and reads
the `runner-check` value from §6's enum (now extended; see §6 below).

### Re-review counter — new fragment field in §6

The per-TDD fragment gains:

- `re_review_attempts` (object, keyed by `"<gate>:<step>"` → int) —
  parallel to TDD 0019's `rework_attempts` but counting
  `runner-check` re-review attempts.

The `run.json` configuration snapshot gains `re_review_config`
(parallel to TDD 0019's `rework_config`) with the
`THROUGHLINE_RE_REVIEW_MAX` value in effect at run start.

This collapses the #35 "Sisyphus" loop from N multi-round passes to ≤ 2:
round 1 may legitimately miss files; round 2 forced by per-file
coverage sweeps them.

### 4. FR-70 grounding instruction — review prompt

The review prompt gains a top-level grounding clause ahead of any
finding emission:

> Every fact you cite in a finding's `evidence` field must be
> reproducible from one of these four artifacts: (1) `git diff
> <base>..<head>` for this pass's scope, (2) `git log
> <base>..<head>`, (3) the TDD file at `docs/tdd/<slug>.md`, or
> (4) the run-state record at `docs/tdd/.implement-logs/<runid>/`.
> Quotes in `evidence` must be verbatim from one of these. A finding
> whose evidence is the author's narrative alone — without a backing
> quote from the four artifacts — is itself a `major` finding with
> `pattern_tags: [evidence-not-grounded]`. Apply this rule to your
> own work.

The runner does not enforce this mechanically — it relies on the
reviewer's discipline. The mechanical backstop is the `findings`
array's `evidence` field being present and non-empty; a future TDD
could harden by requiring evidence to literally substring-match one
of the four artifacts.

### 5. Author self-review (FR-60) — build prompt + skills/implement/SKILL.md

The build prompt is extended: before emitting `BATCH_RESULT: OK`, the
build runs a self-review against its own diff using the same checklist
the reviewer uses. The output appears in a `SELF_REVIEW:` block ahead
of the BATCH_RESULT line:

```
SELF_REVIEW_BEGIN
checked_categories:
  - test-first-discipline
  - touched-file-scope
  - per-file-bound
  - failure-modes-coverage
  - verification-plan-coverage
  - diff-vs-tdd-claims
findings:
  - <FINDING block, in the same shape as §1, for each issue the author
    found in its own work>
SELF_REVIEW_END
```

If `findings` is non-empty and includes any halting-severity entry, the
author MUST address it (commit a fix) before emitting BATCH_RESULT. If
the author emits BATCH_RESULT despite a halting finding in
`SELF_REVIEW`, the runner's final review pass (TDD 0020 §2 consolidated)
detects this as a `major` finding `self-review-ignored`.

Acceptance is outcome-based: across runs after this TDD lands, the
aggregate review-pass findings-per-build distribution shifts downward
versus before (measurable from `run.json`'s rolled-up finding counts).

Model: same as the build (cheapest variant); the user has chosen to
revisit if outcomes lag.

### 5b. Build prompt additions for unattended-mode safety (issues #28A + #28B)

The build prompt (`scripts/build-prompt.md`) is extended with two
small new instruction blocks while we are editing it for §5. Both
land in the same file; they are independent of the SELF_REVIEW block
but share the surface.

**(a) Prohibition on `AskUserQuestion` in the build (issue #28A).** A
new instruction inserted near the existing BATCH_RESULT guidance:

> **Never call `AskUserQuestion` in this build.** The build runs
> unattended as a `claude -p` subprocess; nobody is on the other end
> of a question. A call to `AskUserQuestion` will either return an
> "unavailable tool" error (TDD 0020 §Invocation now passes
> `--disallowed-tools AskUserQuestion`, so the call cannot succeed) or,
> if the restriction is somehow bypassed, hang the subprocess
> indefinitely with no diagnostic. If you cannot proceed without
> human guidance, emit `BATCH_RESULT: BLOCKED <reason>` instead —
> that routes via the FR-17 / TDD 0019 BLOCKERS.md path with a
> diagnostic the user will read. The runner also enforces an
> overall watchdog (`THROUGHLINE_BUILD_TIMEOUT`, default 2h) and an
> inter-event timeout (600s) per TDD 0020; a hang at
> `AskUserQuestion` would trip them, but the BLOCKED path gives
> better diagnostics, so prefer it.

This is the prompt-level half of the belt-and-suspenders defense;
TDD 0020 §Invocation's `--disallowed-tools` is the runner-level half.

**(b) Pre-commit-hook escape for `test(failing):` commits (issue #28B).**
A new instruction inserted in the build prompt's commit-discipline
section, alongside the existing red-then-green guidance:

> **Pre-commit hooks that reject `test(failing):` commits.** Some
> repos run the test suite as part of a pre-commit hook (e.g., via
> `git config core.hooksPath = scripts/git-hooks` with a pytest
> step). When you create a `test(failing): <behavior>` commit, the
> failing test will fail the pre-commit hook, which will reject the
> commit — blocking the failing-test-first discipline this build
> prompt requires. The escape: use `git commit --no-verify` for the
> `test(failing):` commit specifically. The runner's `ci-checks.sh`
> gate (gate 2) re-runs lint + tests + typecheck on the build branch
> before flipping `implemented`, and the runtime-verify gate (gate
> 3) drives the BUILT artifact — so bypassing the local hook for
> one failing-test commit does NOT bypass overall verification;
> the four-gate system catches anything the hook would have
> caught.

The two additions are independent and short; either can be omitted
if the implementer judges them unnecessary at build time, but both
are recorded here so the design rationale is durable.

### 6. Per-TDD fragment schema extension — `scripts/lib/state.sh`

Two new fragment fields:

- `findings` (array of finding objects, populated by the runner from
  parsed review output, the BATCH_RESULT's `SELF_REVIEW` block, and
  runner-side mechanical checks):
  ```
  { source: "review" | "self-review" | "runner-check",
    pass_id: <string>,
    severity: <enum from §1>, structural: <bool>,
    region: <string>, region_lines: <int>,
    pattern_tags: <[string]>, summary: <string>,
    evidence: <string>, addressed_at: <epoch | null>,
    addressed_by_sha: <sha | null> }
  ```
  The `source` field is a closed three-value enum:
  - `"review"` — emitted by an independent review-gate pass (TDD 0020
    per-step or final consolidated).
  - `"self-review"` — emitted by the build's `SELF_REVIEW` block (§5).
  - `"runner-check"` — synthesized by a runner-side mechanical check
    (currently: §3c's `_per_file_coverage_check`; future mechanical
    checks reuse the same value). The routing semantics for
    `runner-check` findings are specified in §3c's "Routing through
    TDD 0019" paragraph.
- `self_review_count` (int): number of self-review findings emitted
  across the build's lifetime, for FR-60 outcome-acceptance telemetry.
- `re_review_attempts` (object): per-(gate, step) counter for
  `runner-check`-triggered fresh review passes (parallel to TDD 0019's
  `rework_attempts`). See §3c's "Re-review counter" paragraph for
  semantics and the `THROUGHLINE_RE_REVIEW_MAX` cap (default 2).

The `run.json` configuration snapshot also gains `re_review_config`
(parallel to TDD 0019's `rework_config`).

Schema-version bumped by one from TDD 0020's value.

## Data & state

§6 above. The `findings` array is bounded by the TDD's complexity;
typical TDD sees ≤ 20 findings across all passes; not a fragment-size
concern.

## Sequencing / implementation plan

1. **Add schema fields + setters** in `scripts/lib/state.sh` for
   `findings`, `self_review_count`. Bump schema-version.
2. **Extend the review prompt** with §1 finding schema, §3 diff-vs-narrative
   check, §4 grounding clause.
3. **Implement `_diff_vs_narrative_facts`** in `scripts/lib/gates.sh`;
   wire its output into the review prompt's interpolation context.
4. **Extend the runner's review-result parser** in `scripts/lib/gates.sh`
   to read `FINDING_BEGIN..FINDING_END` blocks; record each on the
   fragment's `findings` array; drive the halt decision from the
   `{blocker, major}` subset per §2.
5. **Extend the build prompt** in `skills/implement/SKILL.md` and
   `scripts/build-prompt.md` with §5's `SELF_REVIEW_BEGIN..END` block,
   the "address halting self-review findings before BATCH_RESULT"
   instruction, and the §5b additions: (a) `AskUserQuestion` prohibition
   for unattended mode (issue #28A); (b) `git commit --no-verify`
   escape for pre-commit-hook-blocked `test(failing):` commits
   (issue #28B).
6. **Extend the review prompt** with §3b's per-file disposition
   requirement (issue #35) and implement §3c's
   `_per_file_coverage_check` helper in `scripts/lib/gates.sh`. Wire
   the check between the reviewer's stream end and the runner's
   verdict acceptance.
7. **Extend the runner's BATCH_RESULT parser** to extract the
   `SELF_REVIEW` block; record its findings onto the fragment with
   `source: "self-review"`; increment `self_review_count`. **Multi-turn
   timing (TDD 0020 dependency):** in TDD 0020's stream-json multi-turn
   mode, `SELF_REVIEW_BEGIN..END` appears in the build's *final turn*
   immediately before `BATCH_RESULT:` (both are emitted after all
   `STEP_COMMIT:` exchanges have completed). The runner drains the full
   final turn — every stream-json event line until the subprocess
   closes its stdout — before dispatching the consolidated review pass,
   so `SELF_REVIEW` is captured in the runner's buffer before any
   downstream consumer (the consolidated review prompt's interpolation
   context) reads it. See TDD 0020's "Build subprocess protocol"
   subsection for the concrete drain loop.

## Failure modes & edge cases

- **Reviewer emits a finding without `severity`.** Runner records it
  with `severity: major` (conservative default) and emits a `minor`
  meta-finding `missing-severity-tag` against the reviewer's output. The
  build is halted as if a real `major` were present.
- **Reviewer emits `severity` outside the closed set.** Runner records
  the value verbatim, treats it as `major`, emits a `minor` meta-finding
  `invalid-severity-value`.
- **Self-review emits findings but the build emits BATCH_RESULT anyway.**
  The runner's final consolidated review pass detects this as
  `self-review-ignored` per §5. The current review pass also has
  visibility into the SELF_REVIEW block (it's in the build log) and may
  flag it during scoped per-step review.
- **Diff-vs-narrative check finds no narrative.** Older builds may not
  produce a narrative section before BATCH_RESULT. The helper records
  this as `narrative-missing` and the reviewer's check skips the §3 step.
  Not a finding (the build prompt's narrative-emission instruction is
  what produces the surface; missing prose pre-instruction is
  pre-existing behavior, not a regression).
- **Pattern tags inconsistent.** Same caveat as TDD 0020's §Failure
  modes — model-generated; eventual consistency, not strict.
- **Self-review token-spend.** Adds to the build's token spend. The
  TDD 0019 FR-68 telemetry surface records build-attempt token spend;
  this is observed in the aggregate. If self-review's cost cancels its
  review-pass savings, the outcome acceptance fails and the design is
  revisited per the user's note.

## Verification plan

**Observable surface:** the per-TDD fragment's `findings` array,
`self_review_count`, and the review/build log outputs.

**Observation points:**

1. **Severity-tagged finding parses correctly.** Fixture: a review pass
   emits one `FINDING_BEGIN..FINDING_END` block with `severity: major`.
   Expect: `findings[0].severity == "major"`, `source: "review"`,
   `region_lines` populated.
2. **Halt boundary respects severity.** Fixture A: review emits one
   `minor` finding, `REVIEW_RESULT: PASS`. Expect: no halt; clear. Fixture
   B: review emits one `major` finding, `REVIEW_RESULT: BLOCK`. Expect:
   halt; rework loop entered (TDD 0019). Fixture C: review emits zero
   findings but `REVIEW_RESULT: BLOCK`. Expect: synthetic `major` finding
   `inconsistent-review-output` recorded, halt.
3. **Diff-vs-narrative discrepancy → `major` finding.** Fixture: build's
   BATCH_RESULT narrative claims 3 files touched; `git diff
   --name-only` shows 5. Expect: review pass emits a finding with
   `severity: major`, `pattern_tags: [narrative-discrepancy]`, summary
   naming the missing files; halt; rework loop entered.
4. **Evidence-not-grounded detection.** Fixture: review prompt's
   diff-vs-narrative check emits a finding whose `evidence` quotes the
   author's narrative without a backing artifact. Expect: meta-finding
   `evidence-not-grounded` from the next consolidated review pass.
   (This is a soft-enforcement verification; the reviewer is asked to
   self-apply the §4 rule.)
5. **Self-review block recorded.** Fixture: a build whose
   `SELF_REVIEW_BEGIN..END` block contains 2 findings before BATCH_RESULT.
   Expect: `findings` array gains 2 entries with `source:
   "self-review"`; `self_review_count == 2`.
6. **Self-review ignored finding detection.** Fixture: build's
   SELF_REVIEW block has a `major` finding but the build emits
   BATCH_RESULT without addressing it. Expect: the next review pass
   emits a `major` `self-review-ignored` finding citing the unaddressed
   self-review finding.
7. **FR-60 outcome-acceptance telemetry.** Acceptance threshold: ≥ 10
   builds in each of the pre-TDD-0021 and post-TDD-0021 batches. The
   post batch's mean `findings.length` (filtered to `source: "review"`)
   must be lower than the pre batch's mean by ≥ 1 finding on average,
   or the design is revisited (per the user's note on outcome-based
   acceptance for self-review model choice). This verification runs
   after accumulation; the immediate verification at implementation time
   is structural — the SELF_REVIEW block is parsed and stored, the
   `self_review_count` field is populated, and the consolidated review
   pass detects `self-review-ignored` per §5.
8. **Per-file coverage check rejects incomplete review + re-review
   routing (issue #35).** Fixture: review pass on a 5-file diff emits
   findings citing only 3 files and emits `REVIEW_RESULT: PASS`.
   Expect: runner's `_per_file_coverage_check` synthesizes a `major`
   `incomplete-file-coverage` finding listing the 2 un-cited files,
   `source: "runner-check"`; the verdict is converted to BLOCK. The
   re-review branch (§3c "Routing through TDD 0019") fires: NO
   `_rework_one` invocation; a fresh review pass is spawned on the
   same `<base..head>` range with the un-cited file list inserted
   into the review prompt's "Scope of this pass" section as an
   attention directive. The fragment's `rework_attempts` counter
   does NOT tick; `re_review_attempts["review:<step>"]` increments
   to 1. A second review pass that emits `FILE_REVIEWED_NO_FINDINGS:`
   for each of the 5 files clears.
8b. **Re-review budget exhaustion (issue #35).** Fixture: review pass
    emits incomplete coverage; runner spawns fresh pass; second pass
    also emits incomplete coverage. With
    `THROUGHLINE_RE_REVIEW_MAX=2`: `re_review_attempts == 2` after the
    second pass; on the third halting `runner-check` finding the TDD
    is BLOCKED with `halt_cause: rework-budget-exhausted` (existing
    TDD 0018 enum) and a BLOCKERS.md entry naming the gate-step pair
    and un-cited file list. The `rework_attempts` counter remains 0
    (unrelated branch).
9. **`FILE_REVIEWED_NO_FINDINGS:` accepted without findings (issue #35).**
   Fixture: review pass on a 3-file diff emits zero
   `FINDING_BEGIN..END` blocks but emits one
   `FILE_REVIEWED_NO_FINDINGS: <file>` line for each file and
   `REVIEW_RESULT: PASS`. Expect: coverage check passes; verdict is
   accepted as clear; no synthetic findings emitted.
10. **Build prompt's `AskUserQuestion` prohibition (issue #28A).**
    Fixture: a build prompt that attempts `AskUserQuestion` despite the
    §5b(a) prohibition. Expect: tool call fails at the runner layer
    per TDD 0020 §Invocation's `--disallowed-tools` enforcement; the
    build subprocess receives the failure and either falls back to
    `BATCH_RESULT: BLOCKED <reason>` or hits TDD 0020's watchdog. The
    process never hangs on the question.
11. **`--no-verify` escape works around pre-commit-hook (issue #28B).**
    Fixture: a repo with a pre-commit hook running pytest, plus a
    failing test for the build to satisfy. Expect: the build's
    `test(failing):` commit uses `git commit --no-verify` per §5b(b);
    the commit lands; the subsequent green-test commit goes through
    the hook normally; `ci-checks.sh` (gate 2) and runtime-verify
    (gate 3) re-run the full suite against the build branch and
    confirm correctness; final `BATCH_RESULT: OK`.

**Expected observations (PASS):** observation points §1–§6 yield the
cited result on initial implementation. §7 is observable telemetry that
the user evaluates after enough runs have accumulated; the immediate
acceptance is structural (the surface is in place).

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-58 (severity taxonomy: halt only on `{blocker, major}`) | §1 prompt schema + §2 runner-side halt-boundary check; verification §2 falsifies the precise boundary |
| FR-60 (author self-review before independent review) | §5 build prompt addition + §6 telemetry; outcome-based acceptance recorded for revisit if findings-per-build does not decrease |
| FR-70 (gate decisions grounded in verifiable artifacts only) | §4 grounding clause in the review prompt + §6 `findings[*].evidence` field carrying the artifact quote; meta-finding `evidence-not-grounded` is the self-applied check |
| FR-71 (honest report: diff-vs-narrative discrepancy as `major`) | §3 dedicated check step in the review prompt + `_diff_vs_narrative_facts` helper grounding the comparison in artifacts; verification §3 falsifies the precise behavior |
| Issue #35 (multi-round review convergence on large diffs) | §3b per-file disposition requirement in the review prompt + §3c mechanical `_per_file_coverage_check` in `scripts/lib/gates.sh`; collapses N-round Sisyphus to ≤ 2 rounds by forcing reviewer attention across the diff's file surface. Not a new FR; this is scope tightening within FR-56 / FR-58 |
| Issue #28A (build hangs in `AskUserQuestion`) | §5b(a) prompt-level prohibition + cross-reference to TDD 0020 §Invocation's `--disallowed-tools AskUserQuestion` and `THROUGHLINE_BUILD_TIMEOUT` watchdog. Not a new FR; this is scope tightening within FR-37 |
| Issue #28B (pre-commit-hook rejects `test(failing):` commits) | §5b(b) `git commit --no-verify` escape in the build prompt's commit-discipline section. Not a new FR; this is scope tightening within FR-15(a) |

## Dependencies considered

No new external dependencies. The prompt extensions are text; the helper
is bash + git.

Alternatives considered:
- **Per-finding `severity` derived deterministically from heuristics in
  the runner (e.g., regex on the summary text)** — rejected: severity
  is a judgment call requiring the reviewer's context; heuristics
  produce false classifications and erode trust in the gate.
- **Author self-review on a different model than the build** — deferred
  per the design plan: same-model is the cheapest start point;
  acceptance is outcome-based; model choice revisited if findings-per-
  build does not decrease.
- **Mechanically enforce evidence-grounding by substring-matching
  `evidence` against `git diff` text** — rejected for this round: too
  brittle (whitespace differences, line-number drift); the prompt-level
  instruction + meta-finding is the lighter-weight first move. A future
  TDD can harden if drift remains.

## PRD conflicts surfaced (and resolution)

The PRD's "Discrepancy detection mechanism" Open question (FR-71) is
resolved here: the check runs as part of the in-build review gate
(FR-56 / TDD 0020), not as a separate mechanical pass. Rationale: the
discrepancy judgment is a textual comparison the reviewer is best-suited
to make; bolting on a separate mechanical pass would either duplicate
the review pass's setup cost or run a degenerate string-compare that
misses semantic discrepancies. The grounding in `_diff_vs_narrative_facts`
gives the reviewer artifacts, not just prose, to anchor the call.

## Decisions to promote (ADR candidates)

- **ADR 0006 — Gate verdicts grounded in verifiable artifacts.** This
  TDD's §4 grounding clause + §3 honest-reporting check are the
  reviewer-facing operational expression of ADR 0006. Promotion
  confirmed by the design plan; high confidence.

## Scope override

This TDD's doc body is over the 350-line default
`THROUGHLINE_TDD_MAX_LINES` cap established by TDD 0014. Justification:
the four in-scope FRs (FR-58 severity, FR-60 self-review, FR-70
grounding, FR-71 honesty) share one substrate (the review prompt + build
prompt) and one telemetry surface (the `findings` array). A follow-up
revision added three small co-located surfaces on the same substrate:
§3b + §3c per-file disposition / coverage check (issue #35) + the
`runner-check` re-review routing branch through TDD 0019 (resolved a
design-critique BLOCKER on the §3c → TDD 0019 interface; adds a
distinct counter `re_review_attempts` and a separate
`THROUGHLINE_RE_REVIEW_MAX` cap), §5b(a) `AskUserQuestion` build-prompt
prohibition (issue #28A), §5b(b) `--no-verify` pre-commit-hook escape
(issue #28B). All three live on
the same review-prompt + build-prompt surface this TDD already owns;
homing them elsewhere would either duplicate this TDD's substrate
description or create cross-TDD prompt-file edit conflicts. Splitting
across multiple TDDs would either edit the same prompt files from
multiple TDDs in the same design pass (a merge-conflict surface and a
coherence loss for the reviewer's checklist) or fragment the finding
schema across multiple state-schema additions. The override is recorded
per FR-53's escape clause (legitimately-wide design; single
prompt-and-schema operation touching one substrate). The verification
plan and prompt-content density account for most of the over-bound
length; trimming would harm specificity.

## Touched files

- `scripts/review-prompt.md` — §1, §3, §3b, §4 extensions
- `scripts/lib/gates.sh` (post-TDD-0017, post-TDD-0019, post-TDD-0020)
  — `_diff_vs_narrative_facts`, finding-block parser, halt-boundary
  logic from §2, `_per_file_coverage_check` from §3c
- `scripts/lib/state.sh` (post-TDD-0015, post-TDD-0018, post-TDD-0019,
  post-TDD-0020) — `findings` + `self_review_count` schema + setters,
  schema-version bump
- `skills/implement/SKILL.md` — §5 self-review block instruction +
  cross-reference to the §5b prompt additions
- `scripts/build-prompt.md` — §5 self-review block insertion + §5b(a)
  AskUserQuestion prohibition + §5b(b) `--no-verify` escape

Total: 5 files touched.

## Expected diff size

- `scripts/review-prompt.md` — ~110 lines added (severity taxonomy,
  grounding clause, diff-vs-narrative check, per-file disposition
  requirement from §3b)
- `scripts/lib/gates.sh` — ~170 lines added (helper + parser + halt
  logic + `_per_file_coverage_check` from §3c)
- `scripts/lib/state.sh` — ~60 lines added
- `skills/implement/SKILL.md` — ~30 lines added
- `scripts/build-prompt.md` — ~80 lines added (self-review block +
  AskUserQuestion prohibition + `--no-verify` escape)

Total expected diff: ~450 lines across 5 files. No per-file exceptions
needed (each under the 300-line default).

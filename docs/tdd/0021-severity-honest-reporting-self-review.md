# TDD 0021: Review severity triage + honest reporting + author self-review

Status: draft
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

### 6. Per-TDD fragment schema extension — `scripts/lib/state.sh`

Two new fragment fields:

- `findings` (array of finding objects, populated by the runner from
  parsed review output and the BATCH_RESULT's `SELF_REVIEW` block):
  ```
  { source: "review" | "self-review", pass_id: <string>,
    severity: <enum from §1>, structural: <bool>,
    region: <string>, region_lines: <int>,
    pattern_tags: <[string]>, summary: <string>,
    evidence: <string>, addressed_at: <epoch | null>,
    addressed_by_sha: <sha | null> }
  ```
- `self_review_count` (int): number of self-review findings emitted
  across the build's lifetime, for FR-60 outcome-acceptance telemetry.

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
5. **Extend the build prompt** in `skills/implement/SKILL.md` and the
   build prompt template with §5's `SELF_REVIEW_BEGIN..END` block and
   the "address halting self-review findings before BATCH_RESULT"
   instruction.
6. **Extend the runner's BATCH_RESULT parser** to extract the
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

No gaps.

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
prompt) and one telemetry surface (the `findings` array). Splitting
across multiple TDDs would either edit the same prompt files from
multiple TDDs in the same design pass (a merge-conflict surface and a
coherence loss for the reviewer's checklist) or fragment the finding
schema across multiple state-schema additions. The override is recorded
per FR-53's escape clause (legitimately-wide design; single
prompt-and-schema operation touching one substrate). The verification
plan and prompt-content density account for most of the over-bound
length; trimming would harm specificity.

## Touched files

- `scripts/review-prompt.md` — §1, §3, §4 extensions
- `scripts/lib/gates.sh` (post-TDD-0017, post-TDD-0019, post-TDD-0020)
  — `_diff_vs_narrative_facts`, finding-block parser, halt-boundary
  logic from §2
- `scripts/lib/state.sh` (post-TDD-0015, post-TDD-0018, post-TDD-0019,
  post-TDD-0020) — `findings` + `self_review_count` schema + setters,
  schema-version bump
- `skills/implement/SKILL.md` — §5 self-review block instruction
- `scripts/build-prompt.md` — §5 self-review block insertion

Total: 5 files touched.

## Expected diff size

- `scripts/review-prompt.md` — ~80 lines added (severity
  taxonomy, grounding clause, diff-vs-narrative check)
- `scripts/lib/gates.sh` — ~140 lines added (helper + parser + halt
  logic)
- `scripts/lib/state.sh` — ~60 lines added
- `skills/implement/SKILL.md` — ~30 lines added
- build prompt template — ~50 lines added

Total expected diff: ~360 lines across 5 files. No exceptions needed
per-file (each under 300).

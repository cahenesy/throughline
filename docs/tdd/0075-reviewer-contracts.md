# TDD 0075: Reviewer contracts — design rigor, a fixed build reviewer, reviewable non-findings

Status: draft
PRD refs: FR-108, FR-109, FR-110, FR-15, FR-10, FR-87
PRD-rev: d526c55
ADR constraints: 0004, 0006, 0010, 0011, 0013, 0015

## Approach
After this TDD, every reviewer shares one contract shape. TDD 0073 adds
the requirements reviewer; this TDD brings the design, build and UX
reviewers into line:
- **Design reviewer (FR-108).** It adds:
  - a simulation trace whose steps each cite a source;
  - an alternatives table for each blocker or major finding;
  - terminology and duplication passes;
  - a metrics line.
- **Build reviewer (FR-109).** It gets a fixed prompt,
  `agents/build-reviewer.md`. The `/build-tdds` step 10 dispatches a
  worker with that file as its instructions, instead of a prompt the
  parent improvises each run. This run's history showed why: every build
  review prompt for 0070–0072 was written ad hoc, and its rigor depended
  on whoever drove the session.
- **Every reviewer (FR-110).** Each one:
  - numbers its findings `R-1, R-2 …`;
  - cites `file:line` (or a document section) for each;
  - may set a candidate finding aside only by quoting it, as *pedantic
    escalation* or *imaginary architecture*;
  - never dismisses race, concurrency, filesystem or security findings by
    category.

Prompts are referenced **by file path** under the plugin root, so dispatch
works on any harness (FR-79, FR-81). On Claude Code the same files are
also agent types. The rigor additions are prompt rules. Their behaviour is
observed by parent-dispatched fixture runs, as for 0071's ux-reviewer.
Text checks cover only that each contract is present.

## Components & interfaces

### `agents/design-reviewer.md` (extended; existing passages kept)
New required report sections, in this order, before the verdict:
1. **`### Simulation trace`.** For each TDD, the main interface or
   flow: the entry point its Verification plan drives. It walks three
   paths, happy, boundary and failure, as `state → state` steps.
   - Each step ends with a citation in square brackets: a TDD section
     (`[0073 §Components: prd_lint.py check]`) or a `file:line`.
   - A step with no citation is suffixed `[unverified]`.
   - A trace made up only of unverified steps cannot be the basis of a
     PASS for that TDD.
2. **`### Findings`.** Each finding is `R-n <severity> — <doc:section or
   file:line> — <finding>`. Every blocker or major finding is followed by
   a table:
   `| Rejected approach | Failure mechanism | Viable alternative | Trade-offs |`.
3. **Terminology and duplication passes,** reported inside `### Findings`:
   - the same concept named two ways across the set;
   - the same interface or requirement specified twice with different
     details.
4. **`### Non-findings`** (FR-110). Each is
   `<label> — "<quoted candidate finding>" — <why set aside>`, with label
   `pedantic escalation` or `imaginary architecture`.
5. **A metrics line**, exactly
   `METRICS: traced <a>/<b> requirements; findings blocker=<n> major=<n> minor=<n> nit=<n>`.
6. **The verdict line** (unchanged): `DESIGN_REVIEW: PASS` or
   `DESIGN_REVIEW: BLOCK <reason>`.

The existing scope-coherence, rubric, calibration and verdict passages
stay word-for-word. The `bounded-tdd-scope`, `evaluation-rubric`,
`token-spend-reduction`, `model-roles` and `ux-pipeline` evals read this
file and assert some of them.

### `agents/build-reviewer.md` (new)
Frontmatter: `name: build-reviewer`, `tools: Read, Grep, Glob, Bash`,
`model: inherit`. The dispatch passes five inputs:
- the TDD path;
- the **base SHA**: the commit the build worktree was created from, as
  recorded at step 6. That is the integration branch, or in sequential
  mode the previous TDD's build HEAD, so stacked builds never count an
  earlier TDD's files as this TDD's changes or scope;
- the build worktree;
- the report-file path;
- the implementer's build report path, which rule 2 needs, and the
  runtime-verify report path;
- `$(tl_plugin_root)/agents/security-reviewer.md`, an absolute path inside
  the plugin, so it works in consumer repos. It is read-only, apart from the report
file, and must not spawn children. It runs these checks:
1. **Conformance.** Every interface, argument, stdout line, return code
   and message the TDD pins, checked against the diff
   (`git -C <wt> diff <base-sha>..HEAD`).
2. **Deviations.** Each deviation the implementer declared is judged
   acceptable or a defect, and undeclared deviations are found.
3. **Tests.** They observe behaviour and don't grep text, except where
   the TDD states why. Negated assertions check that their input is
   readable first.
4. **Fail-loud.** No parse or helper failure reads as success.
5. **Scope.** Changed files are compared against `## Touched files`.
   Undeclared files are listed and judged for conformance and need. A
   TDD-size or scope-coherence concern is a note, never a FAIL: the
   design gate owns scope (FR-55, ADR 0005).
6. **Security.** The checklist at the passed path is applied on every
   review, as a `### Security` section, whether or not anything looks
   security-relevant.
7. **Trace.** A `### Simulation trace` with the same cited-step rule as
   the design reviewer, walking the changed code's happy, boundary and
   failure paths.
8. **Pre-existing debt.** A finding whose `file:line` is not in the
   diff's changed lines (`git diff -U0 <base-sha>..HEAD`) is labelled
   `pre-existing` and is non-blocking. It never causes FAIL.
9. **Findings and non-findings.** Severities are blocker, major, minor
   and nit. The report is **FAIL if and only if** at least one blocker or
   major finding is not labelled `pre-existing`. Each finding is exactly
   `R-n <severity> — <file:line> — <finding>`, the shared line, and every
   FAIL-causing finding has the alternatives table. Non-findings
   follow FR-110 exactly as in the design reviewer.
10. **Verdict.** The full report is written to the report-file path. The
    last line is exactly `REVIEW_RESULT: PASS` or `REVIEW_RESULT: FAIL`,
    which is unchanged so `tl_verdict_write` and FR-82 stay untouched.

### `skills/implement/SKILL.md`, steps 6 and 10
- **Step 6** appends the line `base-sha=<sha>` to the per-TDD log
  (`git -C "$WT" rev-parse HEAD` right after `git worktree add`). Step 10
  reads the last matching line. A Retry or Resume reuses it. For a run
  whose log predates this change (no such line), step 10 uses
  `git -C "$WT" merge-base <integration> HEAD`, and tells the reviewer it
  is a fallback so the report says so.
- **Step 10's** reviewer-dispatch paragraph is replaced. It now says:
  dispatch **one** reviewer worker whose instructions are
  `$(tl_plugin_root)/agents/build-reviewer.md`, passing the five inputs
  above, with `base-sha` read from that log line. The parent adds nothing to the prompt beyond those inputs and the
facts of the run (the implementer report path, the runtime-verify report
path). Model, escalation check, report-file rule and verdict parsing are
unchanged.

### `skills/implement/SKILL.md`, step 9: the parent-dispatched fixture protocol
This is the protocol 0071 used ad hoc, now written down. A TDD's
verification plan may name **parent-dispatched** observations, meaning
behaviour that only a dispatched reviewer or agent can show.
- The runtime-verify worker builds those fixtures, marks the observations
  `PENDING-PARENT` with the exact paths, and sets its verdict on the rest.
- The parent then dispatches a fresh worker per fixture, with the named
  prompt file, and appends each report's last line to the verify report.
- It revises the verdict: a `PENDING-PARENT` observation that does not
  meet its expected result makes the verify FAIL.

This replaces the ADR candidate. The protocol is a step in the skill, not
a cross-cutting decision.

### `skills/tdd-author/SKILL.md`, steps 7b and 9 (FR-108 PR-body acceptance)
The design-PR body carries more of the critique than the verdict and a
findings summary:
- the reviewer's `### Simulation trace` section, verbatim;
- every blocker or major finding, with its alternatives table;
- the `METRICS:` line;
- the `### Non-findings` section.

Minor findings and nits may stay summarised. The design-reviewer
returns its report as text, not as a file. Step 7b holds that returned
text in the session until step 9 has written the body, and never writes
it to the draft (FR-50).

### `agents/ux-reviewer.md` and `agents/security-reviewer.md`
- `ux-reviewer.md` gains the exact finding line
  `R-n <severity> — <file:line or docs/ux path> — <finding>`, the
  `### Non-findings` rule, and the no-category-dismissal sentence. Its
  verdict line is unchanged.
- `security-reviewer.md` gains one sentence: race, TOCTOU, symlink and
  path-handling findings are judged on their merits and never dismissed
  as a category.

### `tests/reviewer-contracts.test.sh` (new)
It contains the text checks (obs 1–4), and is registered in
`tests/implement-gate.test.sh`.

## Data & state
None. Reviewer reports are already written to run-dir or temp paths that
the dispatching skill owns.

**Ordering.** This TDD builds after 0073, because obs 3 reads
`agents/requirements-reviewer.md`, and after 0074, because both edit
`skills/tdd-author/SKILL.md`. Build the set sequentially, never with
`--parallel`.

## Sequencing / implementation plan
1. Write the contract eval first (red), then extend `design-reviewer.md`.
2. Write `agents/build-reviewer.md`, and switch `/build-tdds` step 10 to
   dispatch by that file.
3. Add the `ux-reviewer.md` and `security-reviewer.md` rules, and
   register the eval.

## Failure modes & edge cases
**Real risks**
- *Longer, costlier reviews.* The trace and table add tokens to every
  review. The PRD accepted this: no new cost bound (NFR-3).
- *A trace that cites but doesn't check.* The citation makes a step
  checkable by the human and by a later reviewer. It doesn't prove the
  reviewer read the cited line. That residual is accepted.
- *The pre-existing rule hides a real regression.* A defect *caused* by
  the diff but surfacing on an unchanged line, such as a changed caller
  breaking an unchanged callee. The reviewer must then cite the changed
  line that causes it, which makes it a non-pre-existing finding. The
  prompt states this rule explicitly.
- *A reviewer that can't run git* (for example, the worktree is gone).
  The report must say so, and the verdict is FAIL, never a guessed PASS.

**Overblown risks**
- *Breaking the build gate's parser.* The verdict line and report-file
  rule are byte-identical, and observation 5 runs the existing verdict
  evals.

**Unspoken risks**
- *Parent drift.* The parent could still pad the dispatch with its own
  instructions. Step 10 limits the parent to the inputs plus run facts,
  and observation 4 asserts that the skill's step 10 names the prompt
  file and contains no reviewer checklist of its own.

## Verification plan
- **Surface:** the text of the reviewer prompt files and of
  `skills/implement/SKILL.md` step 10; the report files and verdict lines
  produced by parent-dispatched reviewers on fixtures.
- **Harness:**
  - Text checks: each file is asserted readable first, and a missing file
    is a FAIL (L-001).
  - Behaviour: the parent session dispatches a fresh worker with the
    prompt file as its instructions, on each fixture. It appends each
    report's last line and the relevant excerpts to the verify report,
    exactly as for TDD 0071's obs 11 and 12.
- **Observation points → expected (PASS):**
  1. **Design-reviewer contract** (a text check by necessity): it contains
     `### Simulation trace`, the `[unverified]` rule, the four-column
     table header, `### Non-findings`, the exact `METRICS:` format, and the
     unchanged verdict line. The `bounded-tdd-scope` and
     `evaluation-rubric` eval assertions still pass.
  2. **Build-reviewer contract** (a text check): `model: inherit`, all ten
     rule headings, the `pre-existing` rule including the caller/callee
     clause, and the exact `REVIEW_RESULT:` line.
  3. **FR-110 across reviewers:**
     - `design-reviewer`, `ux-reviewer`, `build-reviewer` and
       `requirements-reviewer` (from 0073) each contain the
       quote-to-dismiss rule and the two labels;
     - no prompt file contains a sentence that dismisses race,
       concurrency, filesystem or security findings as a category. This
       is a readable-first negated grep, case-insensitive, over these
       phrases:
       ```
       synchronous hand-wringing | harmless idempotence
       ignore race | ignore races | dismiss race | not a real race
       single-threaded so no race | idempotent so safe
       ```
     - `security-reviewer.md` contains the no-category-dismissal
       sentence.
  4. **Step 10.** `skills/implement/SKILL.md` step 10 names
     `agents/build-reviewer.md`, and contains none of build-reviewer's ten
     rule headings (Conformance, Deviations, …), so no checklist is
     duplicated in the skill. Step 9 contains the parent-dispatch
     protocol paragraph (below).
  4b. **Design-PR body** (a text check on tdd-author's steps 7b and 9):
      the skill tells the session to carry the trace, the
      blocker/major tables, `METRICS:` and `### Non-findings` into the PR
      body, holding the returned report text in-session (never in the
      draft).
  5. **Regression.** `verdicts.test.sh`, `build-tdds-skill.test.sh`,
     `bounded-tdd-scope.test.sh`, `evaluation-rubric.test.sh` and the
     ci-checks aggregate stay green.
  6. **Design reviewer behaviour** (parent-dispatched fixture). A
     two-TDD fixture set where TDD B names the concept "job" and TDD A
     calls it "task", and A's interface omits the error rc its own
     verification plan expects. The report has:
     - a `### Simulation trace` whose steps carry citations;
     - a finding naming the terminology drift;
     - a blocker or major finding for the missing rc, with the
       four-column table;
     - the `METRICS:` line;
     - a last line of `DESIGN_REVIEW: BLOCK …`.
  7. **Build reviewer, FAIL** (parent-dispatched fixture). A temp repo
     whose TDD pins `rc 2` for bad input, and a build diff returning
     `rc 1`. The report cites the changed `file:line`, has the table, a
     `### Simulation trace` and a `### Security` section, and ends
     `REVIEW_RESULT: FAIL`.
  8. **Build reviewer, pre-existing** (parent-dispatched). The same repo,
     with a correct diff, and one planted defect on a line the diff does
     not touch: an unquoted `rm -rf $dir/*` in an unchanged function,
     where `dir` can be empty. The report has a `### Simulation trace`,
     lists the planted defect as `pre-existing`, and ends
     `REVIEW_RESULT: PASS`. If the reviewer misses the planted defect
     entirely, the observation is reported as inconclusive (a recall
     miss), not PASS.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement traceability | FR-102..110 (+FR-87/NFR-3 enum) each map to a named function, block, prompt rule or lint code | One mapping indirect but named | An in-scope FR untraced |
| interface concreteness | prd-lint/tdd-lint finding codes, rc, verdict lines, override line format pinned | One rc implicit | Reader can't tell what a check prints |
| alternatives-analysis substance | python parser reuse vs awk, override storage, finding ids, dispatch-by-file each with reason | One rejection thin | None named |
| verification-plan actionability | Lints driven in temp repos; reviewers driven on named fixtures by parent dispatch with expected verdicts; text checks state why | One check text-only with stated reason | Reviewer behaviour asserted only by grepping prompts |
| scope-bound adherence | Each TDD <=8 files, <=500 body lines, padded estimates, eval registration declared | One justified exception | Over a bound unexplained |
| naming consistency | Verdict tokens, finding ids, (new) marker, override line identical across 0073-0075 | One alias reconciled | Same concept named two ways |
| contract symmetry | requirements / design / ux / build reviewers each: fixed prompt file, cited findings, R-n ids, exact verdict line, FR-110 non-finding rule | One differs with stated reason | A reviewer still improvised or uncited |
| consumer-repo neutrality | No throughline-repo layout in any lint, prompt or skill; degrade paths (no python3, no integration ref, outside git) stated | One degrade implied | A rule only true in this repo |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-108 design review rigor | `design-reviewer.md`: cited trace + `[unverified]` rule, alternatives table, terminology/duplication passes, `METRICS:` line; tdd-author steps 7b/9 carry them into the design-PR body (the acceptance's surface); obs 1, 4b, 6 |
| FR-109 build review contract | `agents/build-reviewer.md` (ten rules, security always, trace, pre-existing debt, unchanged verdict line); `/build-tdds` step 10 dispatches by file; obs 2, 4, 7, 8 |
| FR-110 reviewable non-findings | `### Non-findings` quote rule in design, build and ux reviewers (requirements reviewer in 0073); no-category-dismissal sentence, including `security-reviewer.md`; obs 3 |
| FR-15(d) independent review (extended) | fixed build-reviewer prompt; verdict line and artifact unchanged; obs 5 |
| FR-10 design critique (extended) | design-reviewer additions; existing passages kept; obs 1, 5 |
| FR-87 reviewers inherit | `model: inherit`; dispatch without a model parameter, unchanged |

## Dependencies considered
- **Dispatch the build reviewer by prompt file (chosen).** It works on
  any harness (FR-79, FR-81).
  - *Rejected: an agent-type name.* It is Claude-specific.
  - *Rejected: keeping the parent-written prompt.* That is the
    improvised rigor FR-109 removes.
- **Cited trace (chosen).**
  - *Rejected: a free-form trace.* A plausible but unchecked trace is the
    theater FR-110 and the PRD's interview warned against.
- **Pre-existing by diff hunks (chosen).** Mechanical, from
  `git diff -U0`.
  - *Rejected: reviewer judgement of what the diff "caused".* There's no
    floor; the caller/callee clause keeps judgement only where it is
    needed.

## PRD conflicts surfaced (and resolution)
- FR-109's acceptance asks that the skill "names one reviewer prompt file
  for every review dispatch". This design names it in step 10 and forbids
  a parent checklist there (obs 4). The retry path re-enters step 10, so
  it uses the same file.

## Decisions to promote (ADR candidates)
- None. Evaluated at this pass's close-out:
  - **The shared reviewer contract.** A fixed prompt file, cited `R-n`
    findings, an alternatives table, quote-to-dismiss non-findings and an
    exact verdict line. It is already binding as requirements (FR-104,
    FR-108, FR-109, FR-110) and reverses no accepted ADR, so an ADR would
    only duplicate the PRD.
  - **The parent-dispatched fixture protocol.** It is written into
    `/build-tdds` step 9 as a skill step, not a cross-cutting decision.

## Touched files
- `agents/design-reviewer.md` — trace, alternatives table, terminology/duplication, metrics, non-findings
- `agents/build-reviewer.md` (new) — fixed Gate-4 reviewer prompt
- `skills/implement/SKILL.md` — step 6 records `base-sha`; step 9 parent-dispatch protocol; step 10 dispatches by `agents/build-reviewer.md`
- `skills/tdd-author/SKILL.md` — steps 7b/9 carry trace, tables, metrics, non-findings into the PR body
- `agents/ux-reviewer.md` — R-n + citations, non-findings rule
- `agents/security-reviewer.md` — no-category-dismissal sentence
- `tests/reviewer-contracts.test.sh` (new) — obs 1–4
- `tests/implement-gate.test.sh` — register the eval

## Expected diff size
- `agents/design-reviewer.md` — 70 lines
- `agents/build-reviewer.md` — 120 lines
- `skills/implement/SKILL.md` — 50 lines
- `skills/tdd-author/SKILL.md` — 20 lines
- `agents/ux-reviewer.md` — 25 lines
- `agents/security-reviewer.md` — 4 lines
- `tests/reviewer-contracts.test.sh` — 220 lines
- `tests/implement-gate.test.sh` — 4 lines

Total expected diff: 513 lines across 8 files.

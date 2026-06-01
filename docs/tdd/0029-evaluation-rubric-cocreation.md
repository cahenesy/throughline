# TDD 0029: Evaluation-rubric co-creation phase

Status: draft
PRD refs: FR-77
PRD-rev: bfc8ad6
ADR constraints: 0003, 0004, 0005, 0006

## Approach

FR-77 adds a distinct rubric phase to both authoring skills: after the
exploratory interview (and after [[0028]]'s interrogation completes), the model
switches to a skeptical grading-expert posture and co-creates with the user a
structured evaluation rubric — what high-quality vs. acceptable vs. failing
output looks like for the artifact about to be written. The rubric persists in
the design record, the design-critique gate consumes it as explicit success
criteria, and future sessions can query it.

Four design decisions:

1. **Rubric storage: a `## Evaluation rubric` section inline in the artifact
   itself.** PRD rubrics live in `docs/PRD.md`; TDD-set rubrics live in each
   TDD. This resolves the PRD's open question ("Rubric storage & query
   mechanism") in favor of the simplest mechanism that satisfies every FR-77
   leg: persistence (it's in the committed artifact), gate consumption (the
   design-reviewer already reads the artifact), and queryability (future
   sessions read the same files; no store, no index, no new query surface).
   The learnings-system integration (rubric patterns feeding `LEARNINGS.md`)
   is explicitly deferred to a future TDD once 0022/0023's store has shipped
   and its real shape is known — recorded as a remaining open question, not
   designed against speculation.

2. **Rubric structure: criteria rows, three grade anchors.** A rubric is a
   markdown table: one row per criterion, three columns of grade anchors
   (`high-quality` / `acceptable` / `failing`), each anchor a one-line
   observable description. Criteria are restricted to gate-observable
   qualities (FR-77's list: traceability, concreteness, scope adherence,
   alternatives-analysis quality, verification-plan actionability, naming
   consistency — plus artifact-specific ones the user adds).

3. **Gate consumption: the design-reviewer prompt interpolates the rubric.**
   `agents/design-reviewer.md` gains a section instructing it to read the
   `## Evaluation rubric` section of each artifact under review and grade
   against those criteria explicitly, citing rubric rows in its findings and
   in its PASS rationale. No rubric present → the reviewer notes its absence
   (post-FR-77 artifacts must have one) and falls back to its standing
   criteria.

4. **The rubric phase is a separate conversational step with its own
   AskUserQuestion flow** — not folded into the interview. The model proposes
   a draft rubric (seeded from the standing criteria + what the interview
   surfaced), the user edits/approves it, and only then does artifact writing
   begin. Per the PRD's open question on ordering, this design picks: the
   rubric phase REQUIRES [[0028]]'s open-assumptions list to be fully
   dispositioned first (strict ordering) — grading criteria co-created while
   feasibility questions are still open would grade against assumptions that
   may not survive.

This extends [[0002]], [[0003]] (both implemented), [[0010]]'s design-reviewer
surface, and layers on top of [[0028]]. It must build after 0028 and after the
current run's 0023 (both also touch tdd-author/SKILL.md).

## Components & interfaces

### 1. Rubric phase block — `skills/prd-author/SKILL.md`

A new numbered step in `## Process`, after the interview steps and before the
"Write `docs/PRD.md`" step, titled **"Rubric co-creation (FR-77)"**:

- **Precondition:** "Do not start this phase until every open-assumptions item
  ([[0028]] / FR-75) is dispositioned."
- **Posture switch:** "You are now a skeptical grading expert, not the author.
  Your job is to define how a harsh reviewer would grade the PRD you are about
  to write — before you write it, so the criteria cannot be bent to fit what
  you produced."
- **Co-creation flow:** "Propose a draft rubric as a markdown table: one row
  per criterion, columns `Criterion | High-quality | Acceptable | Failing`,
  each cell a one-line observable description. Seed it with: requirement
  testability, acceptance-criterion observability, scope coherence,
  non-goal explicitness, open-question honesty. Present it via AskUserQuestion
  for the user to add/remove/edit criteria. Iterate until approved."
- **Persistence:** "Write the approved rubric as a `## Evaluation rubric`
  section in `docs/PRD.md` (after `## Open questions`). It ships in the same
  PR as the requirements it grades."

### 2. Rubric phase block — `skills/tdd-author/SKILL.md`

The same step inserted between step 5 (author the approved set) preparation and
the actual writing — concretely: after the [[0028]] interrogation block
completes and before "Write each TDD from the template". Differences:

- Seed criteria are the design-flavored set: requirement traceability,
  interface concreteness, alternatives-analysis substance, verification-plan
  actionability, scope-bound adherence, naming consistency.
- One rubric covers the whole TDD set of the design pass (not one per TDD);
  it is written as a `## Evaluation rubric` section in EACH TDD of the set
  (identical content), so every TDD is self-contained for the per-TDD reviews
  the build pipeline runs later.
- The skill's step-7b instruction (spawn the design-reviewer) gains: "The
  design-reviewer reads the rubric from the TDDs; your PR body must note that
  a rubric is present and co-created."

### 3. Design-reviewer rubric consumption — `agents/design-reviewer.md`

A new section in the agent prompt:

- "Each artifact under review may carry a `## Evaluation rubric` section
  co-created with the user (FR-77). When present: grade the artifact against
  EACH rubric row explicitly; cite the row's criterion name in any finding
  that maps to it; and in your PASS rationale, state which grade anchor
  (high-quality / acceptable / failing) the artifact earns per criterion. A
  `failing` grade on any rubric criterion is a BLOCK."
- **Absence rule (non-circular):** "The rubric requirement applies to NEWLY
  AUTHORED artifacts in the set under review — i.e. any TDD file that did not
  exist on the integration branch before this design pass (equivalently: any
  TDD whose `PRD-rev` is the PRD revision this pass designs against), and the
  PRD itself when the pass adds or changes requirements. For each such
  artifact lacking a `## Evaluation rubric` section, emit a finding (the
  rubric is required for new authoring). Pre-existing artifacts that the pass
  touches only incidentally (status-line flips, cross-reference updates) are
  NOT subject to the requirement. Grade rubric-less artifacts against your
  standing criteria as the fallback."
- **Precedence rule:** "Standing reviewer criteria — ADR constraints,
  structural/traceability requirements, scope bounds — take precedence over
  rubric grades; an ADR conflict can never be graded acceptable by a rubric.
  The rubric governs quality-bar judgments only (how concrete is concrete
  enough, how substantive the alternatives analysis must be)."

### 4. Template updates — both skills

The PRD template (prd-author SKILL.md) and the TDD template (tdd-author
SKILL.md) each gain an `## Evaluation rubric` line so the section is part of
the canonical artifact shape. tdd-lint's required-section list is NOT extended
(the rubric is required by the design-critique gate per §3, not by the
mechanical pre-pass — keeping prompt-judgment enforcement at the gate that has
judgment, per ADR 0005's spirit).

## Data & state

No new run-state, no schema changes. Rubrics are markdown sections in
committed artifacts. (The deferred learnings-store integration would add state;
that is explicitly out of scope.)

## Sequencing / implementation plan

1. **prd-author SKILL.md**: insert the rubric-phase step (§1) + template line
   (§4).
2. **tdd-author SKILL.md**: insert the rubric-phase step (§2) + template line
   (§4) + the step-7b note.
3. **design-reviewer.md**: add the rubric-consumption section (§3).
4. **Eval**: mechanical greps for the rubric-phase blocks, the template lines,
   and the design-reviewer consumption section; wire into the aggregator.

**Build-order note:** must build after [[0028]] (its precondition references
0028's open-assumptions list) and after the in-flight 0023 (same tdd-author
SKILL.md surface). Numeric ordering (0029 last) produces this naturally.

## Failure modes & edge cases

- **User wants no rubric for a trivial change.** The skill allows a one-row
  minimal rubric (the user approves it as such); FR-77's "boilerplate criteria"
  non-compliance is judged by the human PR reviewer against the change's
  substance — same human-judgment pattern as [[0028]]'s zero-assumptions case.
- **Rubric and standing reviewer criteria conflict** (rubric says X is
  acceptable; standing criteria say X blocks). The design-reviewer's standing
  criteria win for ADR/structural matters (an ADR conflict can never be graded
  acceptable); the rubric wins for quality-bar matters (how concrete is
  concrete enough). The §3 prompt states this precedence explicitly.
- **The rubric phase runs but the user kills the session before the artifact
  is written.** The approved rubric is persisted to the [[0012]] draft via
  `tl_draft_append_elicit` with the `header` argument `rubric: <artifact>` and
  the rubric table as the answer field — same five-argument signature and same
  latest-entry-per-header convention as [[0028]]'s assumptions. Each
  co-creation iteration appends a new entry; **the last `rubric:`-headed
  entry is the approved rubric.** On resume, the same `tl_draft_read` parse
  [[0028]] specifies recovers it, and the artifact-writing step picks it up.
- **Old artifacts (pre-FR-77) have no rubric.** Handled by §3's non-circular
  absence rule: the requirement keys on whether the artifact is NEWLY AUTHORED
  in the pass under review (a TDD whose `PRD-rev` matches the current pass /
  did not previously exist on the integration branch), never on whether a
  rubric happens to be present. Incidental touches to pre-existing artifacts
  draw no finding.
- **Rubric drifts from the artifact across rework cycles** (the build's rework
  loop edits a TDD's design… it doesn't — rework edits code, never TDDs).
  Non-issue: TDDs are append-only post-merge; the rubric and the artifact it
  grades are immutable together.

## Verification plan

**Observable surface:** the three modified prompt files' text; the
`## Evaluation rubric` sections in artifacts produced by post-build authoring
sessions; the design-reviewer's output citing rubric criteria.

**Observation points:**

1. **Rubric-phase blocks present (mechanical).** Grep
   `skills/prd-author/SKILL.md` for: heading "Rubric co-creation (FR-77)";
   the precondition phrase referencing dispositioned assumptions; the table
   column spec `Criterion | High-quality | Acceptable | Failing`; the
   persistence instruction naming `## Evaluation rubric`. Same greps against
   `skills/tdd-author/SKILL.md`. All present → PASS.
2. **Template lines present (mechanical).** Both skills' artifact templates
   contain an `## Evaluation rubric` line.
3. **Design-reviewer consumption present (mechanical).** Grep
   `agents/design-reviewer.md` for: the instruction to grade against each
   rubric row; the failing-grade-is-BLOCK rule; the absence-is-a-finding rule;
   the rubric-vs-standing-criteria precedence statement.
4. **Behavioral: rubric reaches the artifact and the gate cites it.** Run a
   `/tdd-author` session in a fixture repo (post-build, plugin reloaded);
   complete the interrogation + rubric phases; let it author a TDD and spawn
   the design-reviewer. Observe: the authored TDD contains the
   `## Evaluation rubric` section with the co-created table; the
   design-reviewer's output cites at least one rubric criterion by name in its
   findings or PASS rationale.
5. **Behavioral: missing-rubric finding.** Present the design-reviewer with a
   fixture TDD lacking the rubric section (in a context marked as post-FR-77
   authoring). Observe: its output contains a finding noting the rubric's
   absence.

(§4–§5 are session-driven, exercised by the runtime-verify gate; §1–§3 are the
mechanical regression surface.)

**Expected observations (PASS):** every numbered point yields the cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-77 distinct rubric phase, both skills, after interview before artifact | §1 + §2 phase blocks with the strict-ordering precondition. Verification §1. |
| FR-77 skeptical grading-expert posture + co-creation with user | §1/§2 posture-switch + AskUserQuestion co-creation flow. Verification §1, §4. |
| FR-77 criteria limited to gate-observable qualities | §1/§2 seed lists + §2's design-flavored set; rubric structure (observable one-line anchors). Verification §1 (table spec grep), §4. |
| FR-77 persisted as part of the design record | §1/§2 persistence into the artifact's `## Evaluation rubric` section + §4 template lines. Verification §2, §4. |
| FR-77 consumed by the design-critique gate as explicit success criteria | §3 design-reviewer consumption (grade per row, cite criteria, failing→BLOCK). Verification §3, §4, §5. |
| FR-77 queryable by future sessions + learnings system | Inline-in-artifact storage means future sessions read it with the artifact (no new query surface needed); learnings-system integration explicitly deferred (open question retained). Traced as satisfied-by-simplest-mechanism + declared deferral. |

No gaps (the learnings-integration leg is satisfied at the "queryable" level by
file persistence; the deeper integration is a declared deferral, not a silent
one).

## Dependencies considered

No new external dependencies.

Alternatives considered:
- **A `docs/rubrics/` store with one file per rubric** — rejected: a parallel
  artifact tree to keep in sync with the PRD/TDDs it grades; inline sections
  cannot drift from their artifact and need no index.
- **Storing rubrics in the FR-72/73 learnings system** — rejected FOR NOW:
  that system is mid-build (0022/0023); designing against its unconfirmed
  shape couples this TDD to in-flight work. Deferred to a follow-up TDD once
  the store ships; the PRD open question is narrowed (storage is decided:
  inline; only the learnings *integration* remains open). Migration path when
  that TDD comes: copy inline rubric tables into the store (inline copies
  remain in their artifacts as the historical record — they are never removed,
  consistent with the append-only discipline).
- **Making tdd-lint enforce rubric presence mechanically** — rejected: the
  rubric's value is its content quality, which only the design-critique gate
  can judge; a presence-only mechanical check would invite empty boilerplate
  sections that satisfy the grep and defeat the purpose. Enforcement lives in
  the gate that has judgment (§3).
- **One rubric file per design PR (not per TDD)** — rejected: the build
  pipeline's per-TDD reviews ([[0020]]) read TDDs individually; a PR-level
  rubric would be invisible to them. Duplicating the set-rubric into each TDD
  keeps every TDD self-contained.

## PRD conflicts surfaced (and resolution)

One resolved: the PRD's open question "Rubric storage & query mechanism
(FR-77)" is resolved by this design (inline `## Evaluation rubric` sections).
The open question should be narrowed at the next PRD touch to only the
learnings-system integration; this TDD does not edit the PRD (designs don't
edit requirements), but records the resolution here for the next `/prd-author`
pass to fold in.

The second open question ("Rubric phase ordering vs. interrogator completion")
is also resolved: strict ordering (assumptions dispositioned first), per §
Approach decision 4.

## Decisions to promote (ADR candidates)

None proposed. The inline-storage decision is local to the authoring skills
and reversible (a future learnings-integration TDD can migrate); it does not
meet the cross-cutting/durable bar.

## Touched files

- `skills/prd-author/SKILL.md` — rubric-phase step + template line (§1, §4).
- `skills/tdd-author/SKILL.md` — rubric-phase step + template line + step-7b note (§2, §4).
- `agents/design-reviewer.md` — rubric-consumption section (§3).
- `tests/evaluation-rubric.test.sh` — new eval covering verification §1–§3.
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Total: 5 files touched.

## Expected diff size

- `skills/prd-author/SKILL.md` — ~40 lines added.
- `skills/tdd-author/SKILL.md` — ~45 lines added.
- `agents/design-reviewer.md` — ~20 lines added.
- `tests/evaluation-rubric.test.sh` — ~90 lines added (new eval).
- `tests/implement-gate.test.sh` — ~6 lines added (aggregator wire-in).

Total expected diff: ~201 lines across 5 files. No exceptions needed.

# TDD 0072: `[UI]` in `/prd-author`, merged mocks in `/tdd-author`

Status: draft
PRD refs: FR-89, FR-101, FR-10
PRD-rev: 3be6232
ADR constraints: 0005, 0006, 0010, 0017

## Approach
This TDD wires the two existing authoring skills into the UX phase.

- **`/prd-author` writes the signal (FR-89).** For each new or changed
  requirement, the interview asks whether it changes what a user sees or
  does in a graphical UI. If it does, the title gets `[UI]`. Before the
  PR, a `tl:` block runs `tl_ux_ui_reqs` (TDD 0070), so a malformed
  marker fails before it is committed rather than silently skipping
  `/ux-author`. The PR body names the `[UI]` requirements and says to
  run `/ux-author` next.
- **`/tdd-author` consumes it (FR-101).** After the PRD delta is known
  (its step 1), a new block asks `tl_ux_coverage` (TDD 0070) about every
  in-scope `[UI]` id against the **merged** UX set:
  - **covered**: the design proceeds, and the TDD's traceability row
    must cite the screen path;
  - **stale** or **uncovered**: refused, unless the user waives the mock
    or drops that id from this pass.

  The waiver is recorded twice, so both the human and the lint can see
  it. A new `tdd-lint` check makes the citation-or-waiver rule
  mechanical. The design-reviewer also grades whether the design honors
  the cited mocks.

Mocks remain design input. `/build-tdds` is unchanged (PRD non-goal).

## Components & interfaces

### `skills/prd-author/SKILL.md`
- **Interview (Process item 3, under "Interrogator discipline
  (FR-75)").** It adds one rule: for each new or changed
  requirement, ask (structured question, yes/no) "Does this change what
  a user sees or does in a graphical web or mobile UI?". A yes adds
  ` [UI]` after the id in the title (`**FR-120 [UI] Saved searches.**`).
  CLI, API and log surfaces are never `[UI]`. Each answer is appended
  with header `ui: <ID>`.
- **Self-review.** It adds the bullet "`[UI]` markers: every requirement
  answered yes carries `[UI]`; none answered no does; the marker grammar
  is `**<ID> [UI] <title>**`."
- **New block `<!-- tl:ui-markers -->`** (inputs `TL_REPO`), run after
  the PRD is written and before commit. It sources `plugin-root.sh` and
  `ux.sh`, then runs `tl_ux_ui_reqs "$TL_REPO/docs/PRD.md"`. On rc 0 it
  prints `ui-requirements: <n>`, then the id/title lines. On non-zero it
  shows stderr, and the skill fixes the PRD and re-runs the block. It
  never commits a PRD that fails.
- **Git.** When the delta adds or changes any `[UI]` requirement, the
  commit body gets a `## UI requirements` section listing them and the
  line `Next: merge this PR, then run /ux-author before /tdd-author.`
  Otherwise it gets `UI requirements: none`.

### `skills/tdd-author/SKILL.md`
- **New step 1a "UX coverage (FR-101)",** after step 1. The block
  `<!-- tl:ux-coverage -->` takes `TL_REPO` and `TL_IDS`: the in-scope
  `[UI]` ids, one per line. `tl_ux_coverage` reads through
  `tl_ux_merged_index`, which fetches on a best-effort basis first and
  names the ref and SHA it read, so a UX PR merged on the host but not
  fetched locally is not misreported. The session computes `TL_IDS` as the
  `tl_ux_ui_reqs` ids that fall in this pass's PRD delta. When
  `TL_IDS` is empty, the block prints `ux-coverage: no [UI] requirements in scope`
  and exits 0. Otherwise it runs `tl_ux_coverage "$TL_REPO" $TL_IDS` and
  prints its lines.
  - **rc 0**: proceed.
  - **rc 1**: for each `stale` / `uncovered` id, the skill prints
    `throughline: <ID> is a [UI] requirement with no merged UX set (<uncovered|stale: reason>); run /ux-author first, or waive the mock.`
    It then asks a structured question per id:
    - **Stop and run `/ux-author`**: ends the skill. The draft persists.
    - **Waive the mock**: asks for a rationale of 20–400 characters,
      appends `assumption: mock waived <ID>` with the answer
      `waived: <rationale>`, and proceeds.
    - **Drop `<ID>` from this pass**: recorded as a decision, and the id
      leaves the TDD scope.
  - **rc 2 or 3**: show stderr and stop. It never proceeds on an
    unreadable merged index.
- **Template / step 5.** A `[UI]` id in a TDD's `PRD refs` must have a
  traceability row that cites every merged screen the coverage line
  named, as `docs/ux/screens/<sid>/`. A waived id has the row text
  `mock waived: <rationale>` instead. The TDD's design must use the
  merged `docs/ux/tokens.css` values for any visual styling it
  specifies.
- **Step 9 (PR body).** The "Open assumptions & waivers" section already
  renders `assumption:` entries. A mock waiver therefore appears as
  `- mock waived <ID> — waived: <rationale>`. The PR body also lists the
  covered `[UI]` ids with their screen paths, under `UX coverage`.

### `scripts/lib/tdd-lint.sh`
- **New `tl_lint_ux_citations <tdd-path>`**, added to `tl_lint_all`'s
  function list.
  - It resolves the repo root with
    `git -C "$(dirname <tdd>)" rev-parse --show-toplevel`. With no git
    root, or no `docs/PRD.md`, it returns 0: there is nothing to check.
  - When `grep -qF '[UI]' docs/PRD.md` fails, it returns 0 without
    sourcing `ux.sh`.
  - Otherwise it sources `ux.sh` (fail closed:
    `tdd-lint: ux: cannot source ux.sh`, rc 2) and takes the
    intersection of `tl_ux_ui_reqs` ids with the ids on the TDD's
    `PRD refs:` line.
  - For each such id, it reads the `## Requirement traceability` body
    through `md_section_body` and checks that body's rc.
    - If a line containing the id contains `mock waived: ` followed by at
      least one non-space character, the id passes.
    - Otherwise it runs `tl_ux_coverage <root> <id>`. A `covered` result
      needs every screen path on that line to appear on a traceability
      line containing the id. A `stale` or `uncovered` result without a
      waiver is a finding.
  - Findings are emitted through `_tl_emit` with severity `major` and
    code `ux.citation`:
    `<id> is [UI]: cite docs/ux/screens/<sid>/ from the merged UX set, or record 'mock waived: <rationale>'`.
    A finding makes the function return rc 1. `tl_ux_coverage` rc 1
    (stale/uncovered) is an expected result that feeds the rule above;
    it is not a failure. The lint exports `THROUGHLINE_UX_NOFETCH=1`, so
    it never fetches. A helper failure (`tl_ux_*` rc 2/3, or a non-zero
    `md_section_body`) returns rc 2 with
    `tdd-lint: ux: <what> failed (rc <n>) on <tdd>`. A failure never
    reads as clean (L-005).

### `agents/design-reviewer.md`
A new check bullet: "**UX coverage (FR-101).** For each `[UI]`
requirement in scope, the traceability row cites merged
`docs/ux/screens/<sid>/` paths or records `mock waived: <rationale>`.
Open the cited mocks. A design that contradicts a cited mock (a state
the mock shows that the design omits, or styling values that diverge
from `docs/ux/tokens.css`) is a finding. A boilerplate waiver rationale
is a `BLOCK ux-waiver`."

## Data & state
No new state. This TDD reads `docs/PRD.md`, the merged
`docs/ux/index.json` (through TDD 0070) and the TDD files. Waivers live
in the existing `tdd-author` draft (`assumption:` entries) and in the
TDD's traceability row.

## Sequencing / implementation plan
1. Add `tl_lint_ux_citations` to `tdd-lint.sh` and wire it into
   `tl_lint_all`.
2. Edit `skills/prd-author/SKILL.md`: the interview rule, the
   self-review bullet, `tl:ui-markers`, and the commit-body section.
3. Edit `skills/tdd-author/SKILL.md`: step 1a `tl:ux-coverage`, the
   refusal and three-way question, the citation rule, and the PR-body
   `UX coverage`. Add the design-reviewer bullet.
4. Write `tests/ux-pipeline.test.sh`.

## Failure modes & edge cases
**Real risks**
- *The author answers "no" for a UI change.* The PRD PR's human review is
  the gate. The commit body's `UI requirements: none` line makes the
  answer visible in review, not buried.
- *The merged UX set is stale for a requirement that changed again.*
  Coverage reports `stale`. The refusal says so, and the user reruns
  `/ux-author`.
- *A lint false clean.* Any helper failure is rc 2, never 0. A TDD whose
  `PRD refs` omits a `[UI]` id it actually designs is caught by the
  existing traceability lint only if the id is referenced. The
  design-reviewer bullet covers the rest.
- *A consumer repo without python3 that has `[UI]` markers.*
  `tl:ux-coverage` and the lint both return rc 3 / rc 2 with
  `ux: python3 required`. That is loud, matching the UX runtime decision.

**Overblown risks**
- *Old TDDs fail the new lint.* The lint runs only on the set being
  authored (step 7a), and old TDDs reference no `[UI]` ids because none
  existed before FR-89.

**Unspoken risks**
- *A waiver as a habit.* A waiver is cheap to type. Three things keep it
  visible: the rationale bound, its appearance in the PR body, and the
  design-reviewer's `BLOCK ux-waiver` for boilerplate.
- *`/prd-author` and `/ux-author` disagree on the grammar.* Both call the
  same `tl_ux_ui_reqs`, so they cannot disagree.

## Verification plan
- **Surface:** the stdout and rc of the extracted `tl:ui-markers` and
  `tl:ux-coverage` blocks; the stdout and rc of `tdd-lint.sh` on fixture
  TDDs; the agent and skill text where behaviour is model prose.
- **Harness:** temp git repos with `master` holding `docs/PRD.md` and,
  where needed, a merged `docs/ux/index.json` built by TDD 0070's helpers.
  Blocks are extracted by marker and run under `env -i`. A missing marker
  or file is a FAIL, never a skip. Every negated grep asserts that its
  file is readable first (L-001/L-002/L-011). Temp dirs are
  trap-cleaned (L-004).
- **Observation points → expected (PASS):**
  1. **`tl:ui-markers`, clean.** A PRD with `**FR-1 [UI] Login.**` and
     `**FR-2 CLI flag.**` → `ui-requirements: 1` then `FR-1\t…\tLogin`,
     rc 0.
  2. **`tl:ui-markers`, malformed.** A PRD containing `FR-3 [UI]` outside
     the bold title grammar → non-zero rc, and stderr has
     `malformed [UI] marker` and the line number.
  3. **`tl:ux-coverage`.**
     - `TL_IDS` empty → `ux-coverage: no [UI] requirements in scope`,
       rc 0.
     - FR-1 merged on `master` → a `covered` line, rc 0.
     - FR-1 present only on a checked-out branch → `uncovered FR-1`,
       rc 1.
     - A corrupt merged index → rc 2, and stderr has `ux: invalid index`.
  4. **Lint, cited.** A TDD with `PRD refs: FR-1` and a traceability row
     `| FR-1 | … docs/ux/screens/login/ |` where the merged index maps
     FR-1 to `login` → `tdd-lint.sh` exits 0 and prints no `ux.citation`.
  5. **Lint, missing citation.** The same TDD with a row lacking the
     path → rc 1, and stdout has `major ux.citation: FR-1 is [UI]`.
  6. **Lint, waived.** A row `| FR-1 | mock waived: the button reuses the existing toolbar style |`
     → rc 0. The row `| FR-1 | mock waived: |` → rc 1.
  7. **Lint, non-UI repo.** A PRD without `[UI]` on a PATH without
     python3 → `tl_lint_ux_citations` rc 0, and `ux.sh` is never sourced
     (checked by a sentinel function absent afterwards).
  8. **Lint, helper failure.** A corrupt merged index → rc 2 and
     `tdd-lint: ux:` on stderr, never rc 0.
  9. **Skill text** (text checks by necessity: the interview and refusal
     are model prose; each asserts that the file is readable first):
     - `prd-author/SKILL.md` contains the `tl:ui-markers` marker and the
       exact question sentence;
     - `tdd-author/SKILL.md` contains the `tl:ux-coverage` marker, the
       exact refusal sentence prefix
       `is a [UI] requirement with no merged UX set`, and the three
       options;
     - `design-reviewer.md` contains `UX coverage (FR-101)` and
       `BLOCK ux-waiver`.
  10. **Regression.** All existing evals stay green. `tdd-lint.sh` on
      every existing `docs/tdd/0*.md` gives the same exit code as before.
      This repo's PRD mentions `[UI]` only in backticks. The `grep -qF`
      short-circuit therefore does not fire: the lint sources `ux.sh`
      and needs python3 here. `tl_ux_ui_reqs` returns no ids, so the
      check emits nothing.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement traceability | Every FR-89..101 (+79/81/86/87, NFR-1/3) maps to a named ux.sh function, skill block, agent rule, or lint check | One mapping indirect but named | An in-scope FR untraced |
| interface concreteness | Every ux.sh function has args, stdout, rc pinned; index.json schema field-by-field | One rc implicit | Reader cannot tell what a function prints |
| alternatives-analysis substance | Chrome CLI vs Playwright, JSON vs MD index, hash vs git-diff delta, tokens.css vs JSON each with reason | One rejection thin | None named |
| verification-plan actionability | Functions driven in temp repos; skill blocks extracted and run; negated checks assert readability first (L-001/L-011) | One check text-only with stated reason | Behaviour asserted only by grepping prose |
| scope-bound adherence | Each TDD <=8 files, <=500 body lines, padded estimates; exceptions declared | One justified exception | Over a bound unexplained |
| naming consistency | ux.sh names, index.json fields, screen-path form identical across 0070-0072 | One alias reconciled | Same concept named two ways |
| delegation, not reinvention | Skill invokes present delegates by role; ux.sh holds only mechanics, no design logic | Delegates named only as examples | throughline code generates visual design |
| fail-loud parsing | Malformed [UI] marker, unreadable index, awk failure each exit non-zero with a named message | One path returns empty silently but is tested | A parse failure reads as no UI requirements |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-89 `[UI]` marker written by `/prd-author` | step-3 question + `ui: <ID>` draft entries; self-review bullet; `tl:ui-markers` block (`tl_ux_ui_reqs`); commit-body `UI requirements`; obs 1, 2 |
| FR-101 design builds on merged mocks | `/tdd-author` step 1a `tl:ux-coverage` (merged blob); refusal sentence + three-way question; waiver as an `assumption:` entry and `mock waived:` row; `tl_lint_ux_citations`; obs 3–8 |
| FR-10 design-reviewer gate (extended) | `design-reviewer.md` UX-coverage bullet + `BLOCK ux-waiver`; obs 9 |

## Dependencies considered
- **The TDD 0070 helpers (chosen)** for grammar and coverage.
  - *Rejected: a separate grep in `/prd-author` and `tdd-lint`.* A
    second grammar implementation could disagree with `/ux-author`'s and
    silently pass a marker the other rejects.
- **Waiver in the traceability row plus a draft `assumption:` entry
  (chosen).**
  - *Rejected: a separate `## UX waivers` section in the TDD.* That adds
    a required-section variant to `tdd-lint`'s structural check for a
    rare case. The row is where a reader already looks for the
    requirement's design.
- **Lint inside the existing `tl_lint_all` (chosen).**
  - *Rejected: a check only in the design-reviewer prompt.* That is
    model-only and costs tokens on a fact a script can decide (FR-51's
    rationale).

## PRD conflicts surfaced (and resolution)
- FR-101's acceptance requires the refusal to name `/ux-author`. The
  refusal sentence above includes `run /ux-author first`.
- FR-89 says the marker is "the only signal". This TDD adds the
  commit-body `UI requirements` line for review visibility only. No code
  reads it.

## Decisions to promote (ADR candidates)
- Promoted: ADR 0017 (UX record: in-repo, self-contained HTML, delegated by
  role, design input not a build gate), added in this design PR.

## Touched files
- `skills/prd-author/SKILL.md` — `[UI]` question, self-review bullet, `tl:ui-markers`, commit-body section
- `skills/tdd-author/SKILL.md` — step 1a `tl:ux-coverage`, refusal/waiver, citation rule, PR `UX coverage`
- `agents/design-reviewer.md` — UX-coverage check bullet
- `scripts/lib/tdd-lint.sh` — `tl_lint_ux_citations` + `tl_lint_all` wiring
- `tests/ux-pipeline.test.sh` — obs 1–9

## Expected diff size
- `skills/prd-author/SKILL.md` — 45 lines
- `skills/tdd-author/SKILL.md` — 75 lines
- `agents/design-reviewer.md` — 14 lines
- `scripts/lib/tdd-lint.sh` — 95 lines
- `tests/ux-pipeline.test.sh` — 280 lines

Total expected diff: 509 lines across 5 files.

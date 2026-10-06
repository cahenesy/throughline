# TDD 0071: `/ux-author` — the UX phase skill and its independent critique

Status: draft
PRD refs: FR-90, FR-91, FR-92, FR-93, FR-94, FR-95, FR-96, FR-97, FR-98, FR-99, FR-100, FR-22, FR-79, FR-81, FR-86, FR-87, NFR-1, NFR-3
PRD-rev: 3be6232
ADR constraints: 0004, 0006, 0010, 0011, 0015, 0017

## Approach
`/ux-author` is a new interactive authoring skill between a merged PRD
update and `/tdd-author`. It has its siblings' shape, so a user who knows
`/tdd-author` can predict it: a crash-safe draft, the FR-86 check, an
interrogated plan, a co-created rubric, a fresh-worker critique, and a
phase-gate PR it never merges.

throughline owns the **contract**: what gets mocked, the `docs/ux/`
record (TDD 0070's schema), traceability, the critique and the gate.
**Making** the mocks is delegated by **role** to whatever skills and
tools the session has. It reimplements none of them, and it degrades
honestly when none exists (FR-92). The roles are:
- `design`: UI mocks;
- `design-system`: tokens;
- `critique`;
- `accessibility`.

Every mechanical step is a TDD 0070 function called from a `tl:` block,
so runtime-verify can execute the steps. The draft, interrogator and
rubric rules are read from `skills/prd-author/SKILL.md` and applied with
the draft name `ux-author`, not copied (~150 lines). With one source, the
skills cannot drift apart.

## Components & interfaces

### `skills/ux-author/SKILL.md` (new)
Frontmatter: `name: ux-author`, and a description naming the trigger
("after a merged PRD update that adds or changes `[UI]` requirements").
The steps:

0. **Resume + FR-86.** The resume check is identical to `/prd-author`'s
   step 0, with skill name `ux-author` and the same degraded-mode and
   untrusted-draft rules. The `<!-- tl:fr86-check -->` block is
   **byte-identical** to the other skills' copies.
1. **Preflight — `<!-- tl:ux-preflight -->`** (inputs `TL_REPO`). It
   sources `plugin-root.sh` and `ux.sh`, then:
   - fails (rc 1) when `docs/PRD.md` has uncommitted changes:
     `throughline: commit docs/PRD.md first`;
   - **then** writes `tl_ux_merged_index "$TL_REPO"` to a temp file
     (this call does the fetch). rc 1 (no merged index yet) leaves the
     file absent, so every `[UI]` id is `new`; rc 2 is shown and stops
     the skill;
   - **then** fails (rc 1) when `git rev-parse HEAD:docs/PRD.md` differs
     from `<integration>:docs/PRD.md`:
     `throughline: docs/PRD.md differs from the merged PRD on <ref>; merge the PRD PR (or pull the integration branch) and run /ux-author from it`.
     This makes the delta always describe the merged PRD (FR-90);
   - runs `tl_ux_delta "$TL_REPO/docs/PRD.md" <temp>`.

   Empty output means it prints
   `no UI-bearing requirements in this PRD delta` and exits 0. The skill
   then **stops**: no branch, no draft, no PR. Otherwise the block prints
   the delta lines. Any rc 2 or 3 is shown and stops the skill.
1b. **Draft screen plan, shown first (FR-90).** Before any question, the
   session shows a draft plan built mechanically from the delta:
   - one provisional screen per `new` / `changed` id, with id
     `<id-lowercased>` (e.g. `fr-120`) or the merged screen it already
     maps to;
   - all four states as `?`;
   - the platform-default viewports (web until step 2 says otherwise);
   - the requirement id.

   This satisfies FR-90's "the first thing shown is a screen plan naming
   that requirement id". Steps 2–4 refine this draft. Nothing is
   approved yet.
2. **Interview (FR-75 posture, FR-100).** The session reads the
   "Interrogator discipline (FR-75)" section of
   `$(tl_plugin_root)/skills/prd-author/SKILL.md` and applies it with
   `ux-author` as the draft skill. That gives the running assumptions
   list, `tl_draft_append_elicit ux-author …` per answer, and
   resolution-or-waiver before completion. It asks four things:
   - the target platforms (`web` / `ios` / `android`);
   - the viewports, which are global to the UX set. Defaults: web is
     `desktop` 1440×900 plus `mobile` 390×844; iOS is `phone` 390×844;
     Android is `phone-android` 412×915. When a merged set exists, its
     viewports are kept unless the user changes them. A change puts every
     screen into `TL_SCREENS`, so the whole set is **re-rendered**
     (clearing PNGs of removed viewports) before the first validate. The
     HTML of screens outside the delta is not re-mocked and stays as
     merged;
   - the baseline (FR-94): for each existing screen, it is derived from
     code. The user may give a running-app URL;
   - the design-system situation (FR-93).
3. **Delegate discovery (FR-92).** The session lists, from the skills and
   tools it can see in this session, a candidate for each role.
   Examples on Claude Code:
   - `design`: `frontend-design`;
   - `design-system`: `design:design-system`;
   - `critique`: `design:design-critique`;
   - `accessibility`: `design:accessibility-review`.

   On Grok Build, any installed SKILL.md or MCP tool whose description
   fits the role. The skill names roles; the examples are illustrations,
   never requirements. The discovery result is shown to the user. When
   more than one candidate fits a role, the user picks one through a
   structured question; throughline sets no precedence among vendors.
   When none fits, the role is `none` and its work falls back to the
   session (the FR-92 degrade). Only delegates that are actually
   **invoked** later are recorded in `delegates`. Which delegates exist
   on Grok Build was not inventoried (PRD open question). The degrade
   path makes the skill complete there either way.
4. **Screen plan (FR-90, FR-96).** A table is presented as a structured
   question (approve / change). Its columns are screen id, title, states
   (each `default`, `empty`, `loading`, `error`, or `n/a: <reason>`) and
   requirement ids. The set's viewports are listed once above the table. Every delta `new` / `changed` id must
   appear. Each `orphaned` id's mapping is always dropped (TDD 0070's
   `validate` rejects orphans) and listed in the PR under
   "Requirement gaps" as `no longer [UI]: <id>`. The user is not asked to
   keep it.
   The approved plan is appended to the draft as a `decision`.
5. **Rubric (FR-77, FR-100).** The session reads the "Rubric
   co-creation (FR-77)" section of `/prd-author` and applies it, with
   header `rubric: UX-set`. It is seeded with five criteria:
   requirement → screen coverage, state completeness, accessibility
   basics, design-system consistency, and fidelity versus declaration.
   The approved table is written to `docs/ux/RUBRIC.md` (replaced each
   run). The critique and the PR cite it.
6. **Branch + design system (FR-93).** The skill branches
   `docs/ux/<slug>` off the integration branch, then handles the design
   system, checking the cases in this order:
   1. **`tokens.css` already merged**: it is reused unchanged. A change
      goes through a new ADR and is never made silently.
   2. **Existing** design system in code: the `design-system` delegate,
      or the session, derives `tokens.css` from the code's theme.
      `source: existing-code`.
   3. **None**: it establishes `tokens.css` and runs `/adr-new` for the
      ADR "Design system: <name>", written `accepted`. As with ADR 0017,
      merging the UX PR is the acceptance. `source: established`, and
      `adr` is set.
7. **Live capture (FR-94, optional).** For each existing screen, the
   session asks for that screen's URL in the running app (blank skips
   it). It calls
   `tl_ux_capture <url> "<capture-dir>/<sid>" <w>x<h>`. `<capture-dir>`
   comes from one `mktemp -d` and is recorded in the draft (as is the
   review report path), so it survives separate blocks and a resume:
   (TDD 0070) once per viewport. That function refuses an out dir inside
   the repo. On rc 2 or rc 4 the screen's baseline stays `code-derived`,
   and the reason is shown. The index claims
   `live capture (not committed)` only for screens with at least one
   successful capture. It views the captures as reference only. They are never copied
   under `docs/ux/` (`tl_ux_validate` rejects any unlisted image), and
   the directory is removed at step 11.
8. **Mocks (FR-91, FR-92, FR-95).** For each screen, the session invokes
   the `design` delegate, or authors the mocks itself when there is
   none. Fixed instructions go with each call:
   - one self-contained HTML file per state at
     `docs/ux/screens/<sid>/<state>.html`;
   - link `../../tokens.css`;
   - no `http(s)`/`//` URLs. Raster images are inlined as `data:` URIs
     or drawn as SVG; only fonts and SVG may be vendored under `docs/ux/`
     (validate rejects any other raster there);
   - real copy;
   - platform conventions for the target (iOS HIG / Material);
   - every requirement gap rendered as a visible placeholder carrying
     `data-ux-gap="<one line>"`.

   The session then updates `docs/ux/index.json` by **read, merge,
   write**. It starts from the branch's working `index.json` when one
   exists (a loop back from step 9). Otherwise it starts from the merged
   index, or from TDD 0070's initial object when there is none. It
   replaces only the entries for the planned screens and delta ids, and
   keeps every other screen and requirement entry byte-for-byte, so
   earlier `[UI]` ids stay covered. Screenshots are not in the index
   (TDD 0070). The write sets:
   - `prd_rev` to `git log -1 --format=%h <integration> -- docs/PRD.md`;
   - hashes copied from the `tl_ux_ui_reqs` output;
   - `delegates`: the invoked set;
   - `fidelity`: `high` only with a `design` delegate, otherwise the
     level actually reached. `validate` checks only that `delegates` is
     non-empty, because it cannot know roles. Accepted gap: the reviewer
     grades `high` that has no `design`-role delegate;
   - `baseline` per screen.

   It runs `<!-- tl:ux-validate -->`, which calls
   `tl_ux_validate "$TL_REPO"`, and fixes and reruns until the result is
   rc 0. When step 2 changed the viewports, the session runs
   `tl:ux-render` with every screen id **before** this validate. Missing
   PNGs never fail validate; it reports
   `screenshots <k>/<total>`. The session lists each `data-ux-gap` it
   placed. It never edits
   `docs/PRD.md`.
9. **In-session review (FR-96).** `<!-- tl:ux-render -->` takes inputs
   `TL_REPO` and `TL_SCREENS`. `TL_SCREENS` is **exactly** the approved
   plan's screen ids (or the single screen being redone, or every screen
   id when step 2 changed the viewports),
   separated by spaces and read as `${TL_SCREENS:?…}`. An empty value
   fails the block, and `tl_ux_render` refuses an empty id list (TDD
   0070), so merged screens outside the plan are never re-rendered or
   cleared (FR-99). The block calls `tl_ux_render "$TL_REPO" $TL_SCREENS`.
   rc 4 is a declared degrade.
   Then, for each screen set, the session:
   - shows the PNG paths, or the HTML paths when nothing was rendered;
   - asks a structured question: approve / request changes / drop.

   Changes loop back to step 8 for that screen and re-render only it.
   Drop depends on the screen:
   - a **new** screen is removed, with its files and index entries;
   - a screen that **exists in the merged set** is reverted with
     `git checkout <integration> -- docs/ux/screens/<sid>`, which
     restores its HTML and PNGs together, and with its merged index
     entry. Only the delta ids' mappings to it are removed, and a
     requirement left with no screen is removed entirely. It then
     reaches step 10 as unmapped. Under changed viewports, the restored
     screen is re-rendered.

   Because screenshots are derived from disk, both paths leave the index
   and the PNGs consistent. `tl_ux_validate` runs again after any drop.
   Each approval is appended to the draft as a `decision`. A `[UI]` id
   left with no approved screen is a blocking gap, reported in step 10.
10. **Critique (FR-97).** The skill dispatches **one** fresh worker using
    `agents/ux-reviewer.md`:
    - no model parameter, so it inherits (FR-87);
    - it must not spawn children;
    - an empty report file from `mktemp` (its path recorded in the draft),
      whose path is passed in the dispatch prompt.

    The last line of the **report file** (not the transcript, per ADR
    0011) is authoritative, and it must be exactly `UX_REVIEW: PASS` or
    `UX_REVIEW: BLOCK <reason>`. A missing or other last line counts as
    BLOCK. On BLOCK, the skill
    fixes the set (back to 8 or 9) and dispatches a **new** worker. The
    user may instead record a waiver with a rationale. The verdict is
    never written to the draft (as FR-50).
11. **Close-out + PR (FR-98, NFR-1).** The skill:
    - runs `tl_ux_index_html` and `tl_ux_validate` one last time;
    - removes the capture dir and the review report file;
    - commits `docs/ux/` and any FR-93 ADR;
    - pushes and runs `gh pr create` against the integration branch.
      Under "skip git" it commits nothing, and it writes the would-be PR
      body to `${TMPDIR:-/tmp}/tl-ux-pr-body-<pid>.md` and prints that
      path.

    PR-body sections: **Open assumptions & waivers** (from the draft);
    **UX critique** (verdict, findings, waivers); **Delegates & fidelity**
    (`delegates` or `none: degraded`, and `fidelity`); **Requirement
    gaps** (each `data-ux-gap`, or "none found"); **Approved screen
    sets**; and **Screenshots**, with the images embedded via
      `https://github.com/<owner>/<repo>/blob/<commit-sha>/docs/ux/<png>?raw=true`
      (the pushed commit, so links survive branch auto-deletion),
      plus a status line built from the final `tl_ux_validate` count:
      `screenshots: complete` when k equals the total, otherwise
      `screenshots not rendered: <last render reason from the draft, or partial — <n> missing>`.
      Under "skip git", images use local paths;
    - a note that `docs/ux/RUBRIC.md` is co-created.

    It never merges. It then runs `tl_draft_discard ux-author` and tells
    the user to merge the PR and then run `/tdd-author`.

### `agents/ux-reviewer.md` (new)
Frontmatter: `name: ux-reviewer`, `tools: Read, Grep, Glob, Bash`,
`model: inherit`.

It is told that it did not author the set, and that `delegates` is
self-reported. It reads:
- `docs/PRD.md` (the `[UI]` requirements from `tl_ux_ui_reqs`);
- `docs/ux/index.json` and `RUBRIC.md`;
- `tokens.css`;
- every mock, and every PNG (image input where the harness supports it,
  otherwise the HTML).

It runs `tl_ux_validate` first. A non-zero result is an immediate
`UX_REVIEW: BLOCK validate — <first line>`.

Then it checks the following. **Blocking:**
1. Every in-scope `[UI]` id maps to a screen. This is computed
   mechanically: `tl_ux_delta docs/PRD.md docs/ux/index.json` on the
   working index. Any `new` line is an unmapped id, which gives
   `UX_REVIEW: BLOCK unmapped — <id>`.
2. Every screen has `default` plus each of `empty`/`loading`/`error` as
   a file or an `n/a` with a real reason. A boilerplate reason ("not
   needed") is a finding.

**Findings with severity, blocking only when they make a screen
unusable:**
- Accessibility basics: text contrast against the `tokens.css` colours,
  labelled inputs, a logical focus order in the DOM, and touch targets
  of at least 44×44 CSS px on phone viewports.
- Design-system consistency: values are `var(--…)` from `tokens.css`,
  not new literals.
- Visual quality judged against the **declared** fidelity, not against
  the claimed delegate.

It uses the `critique` / `accessibility` delegates when present. It
cites `RUBRIC.md` criteria in its findings. It **writes its full
report to the report-file path given in the dispatch prompt**, ending in
exactly `UX_REVIEW: PASS` or `UX_REVIEW: BLOCK <reason>`. It also
returns the same text.

### Other surfaces
- `README.md`: a `/ux-author` subsection under "Workflow" (trigger,
  delegate roles, degrade path, python3, headless Chrome).
- `.claude-plugin/plugin.json`: the description names the optional
  `/ux-author` phase. The version is bumped per the repo's own
  convention.
- `tests/plugin-root.test.sh` [K] and `tests/parent-session-check.test.sh`
  `NAMES`: both gain `ux-author`, so FR-81 and FR-86 are enforced on the
  new skill.

## Data & state
- **Draft:** `$(tl_draft_path ux-author)` (`drafts.sh`): answers,
  `assumption:` entries, the plan and approvals (`decision`), and the
  rubric (`rubric: UX-set`).
- **Work state on the branch:** the files under `docs/ux/` on
  `docs/ux/<slug>`. A resumed session checks out that branch, when it
  exists, before step 8.
- **Transient:** the capture dir and review report under
  `${TMPDIR:-/tmp}`, removed at close-out, never committed.

## Sequencing / implementation plan
1. Write `skills/ux-author/SKILL.md` with steps 0–11 and the `tl:`
   blocks `fr86-check`, `ux-preflight`, `ux-validate` and `ux-render`.
   Add `ux-author` to the FR-81 [K] list and the FR-86 `NAMES` list.
2. Write `agents/ux-reviewer.md`.
3. Update the README and the `plugin.json` description, and write
   `tests/ux-author-skill.test.sh`.

## Failure modes & edge cases
**Real risks**
- *A delegate ignores "self-contained".* Step 8 loops on `validate`,
  and the reviewer re-runs it and BLOCKs, so a CDN-linked set never
  reaches the PR.
- *Over-claimed fidelity.* `validate` refuses `high` with no delegates,
  and the reviewer grades the declaration. Accepted residual: provenance
  is self-report.
- *No renderer:* HTML only (rc 4), reason in the PR. *Invented requirements.* Gaps appear as mock markers and in a PR
  section. `docs/PRD.md` is never in the UX diff (obs 9).
- *An unmerged UX PR.* Coverage reads only the integration blob.

**Overblown risks**
- *Harness-specific delegates* (roles are abstract); *SKILL.md bloat*.

**Unspoken risks**
- *Two concurrent UX PRs that each establish a design system.* The second
  hits a git conflict on `tokens.css` and an ADR number collision. The
  README says "one UX PR at a time".
- *Reading `/prd-author`'s sections couples the skills.* That is
  intended (a single source), and obs 3 fails CI if a referenced heading
  is renamed.

## Verification plan
- **Surface:** stdout, stderr and rc of the extracted `tl:` blocks; git
  state; agent-file text where behaviour is model-driven.
- **Harness:** temp repos (`master` + fixture PRD). Blocks are extracted
  by marker and run under `env -i`. A missing marker is a FAIL (L-001),
  and every negated grep asserts that its file is readable first.
- **Observation points → expected (PASS):**
  1. **Preflight, no UI.** A PRD without `[UI]` → exactly
     `no UI-bearing requirements in this PRD delta`, rc 0, no `docs/ux/*` branch.
  2. **Preflight, delta.** `**FR-1 [UI] Login.**`:
     - no merged index → `new\tFR-1\tLogin`;
     - a merged index covering FR-1's hash → the no-UI line;
     - FR-1 edited → `changed\tFR-1\tLogin`.
     - An uncommitted PRD edit → rc 1 with `commit docs/PRD.md first`.
     - A committed PRD edit on a branch that is not yet on `master` →
       rc 1 with `differs from the merged PRD`.
  3. **Referenced rules exist.** `skills/prd-author/SKILL.md` contains
     the headings `### Interrogator discipline (FR-75)` and
     `### Rubric co-creation (FR-77)`, and `ux-author/SKILL.md` names
     both (a text check by necessity: prose cross-reference).
  3b. **Resume carries the plan (FR-100).** With
      `CLAUDE_PLUGIN_DATA=<tmp>`, append the plan as a `ux-author`
      `decision`. `tl_draft_exists ux-author` → rc 0, and
      `tl_draft_read` contains the plan, which is what step 0 offers.
  4. **FR-86 bytes.** The `tl:fr86-check` block in `ux-author` is
     byte-identical to `/prd-author`'s. The extended
     `parent-session-check.test.sh` runs it under a fixture
     light-tier transcript and gets the light-tier warning line.
  5. **FR-81.** The extended [K] scan: no vendor tool names; uses `tl_plugin_root`.
  6. **Validate block.** A CDN `<script>` → rc 1 and `ux-invalid:`; clean → rc 0.
  7. **Render block, degrade + scoping.**
     - With `PATH` lacking any browser and `TL_SCREENS=a`, the extracted
       `tl:ux-render` block → rc 4 and
       `screenshots not rendered: no headless Chrome on PATH`.
     - With merged screens `a` and `b` (PNGs present) and
       `TL_SCREENS=a`, `b`'s PNG bytes and index entries are unchanged
       after the block.
     - `TL_SCREENS` empty or unset → non-zero rc, and nothing changes.
  7b. **Draft plan first.** Step 1b precedes any structured question (a
      text check: prose ordering). Preflight's output names `FR-1`,
      which is the draft plan's input.
  8. **Reviewer contract** (text check: model prose). `ux-reviewer.md`
     has `model: inherit`, both `UX_REVIEW:` tokens, the write-report-
     to-dispatched-path rule, `tl_ux_validate` first, and self-reported
     `delegates`.
  9. **Gaps never edit the PRD.** Every `PRD.md` use in the extracted
     blocks is read-only (`tl_ux_*` args, `git status` / `rev-parse`).
  10. **Regression.** All existing evals stay green.
  11. **Live run** (runtime-verify, nontrivial). In a scratch repo with
      one `[UI]` requirement and no design system, run `/ux-author` to
      the PR step with `skip git`, then observe:
      - the printed PR-body file has the sections Open assumptions &
        waivers, UX critique, Delegates & fidelity, Requirement gaps and
        Approved screen sets (FR-98), and repeats `delegates` and
        `fidelity` (FR-92);
      - `docs/ux/tokens.css` and a new `docs/adr/NNNN-*` exist (FR-93);
      - `tl_ux_validate` gives rc 0, and `index.html` opens offline and
        links every screen;
      - `delegates` lists only invoked skills;
      - the critique report's last line is `UX_REVIEW: PASS` or BLOCK.
  12. **Critique blocks an unmapped requirement** (runtime-verify,
      nontrivial; FR-97 acceptance). Dispatch the `ux-reviewer` agent
      against a fixture repo with two `[UI]` ids where `FR-2` has no
      screen. The report file's last line is `UX_REVIEW: BLOCK …`, and
      its text names `FR-2`. If the harness cannot dispatch the agent,
      the result is BLOCKED with that reason.

      If the harness cannot run an interactive skill headlessly, the
      result is BLOCKED with that reason, never PASS.

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
| FR-90 delta-driven, plan first | step 1 `tl:ux-preflight` (no-UI line, no branch); step 4 screen plan; obs 1, 2 |
| FR-91 artifact set | step 8 mock instructions + index; step 11 `tl_ux_index_html`; `tl:ux-render`; obs 6, 7, 11 |
| FR-92 delegated design, honest degrade | step 3 role-based discovery; `delegates` = invoked only; fidelity rule; reviewer grades the declaration; obs 8, 11 |
| FR-93 design system | step 6 (existing → derived `tokens.css`; none → `tokens.css` + proposed ADR via `/adr-new`; merged → reused) |
| FR-94 baseline, captures never committed | step 2 baseline; step 7 capture outside the repo; `validate`'s unreferenced-image rule; obs 6 |
| FR-95 gaps recorded, never invented | `data-ux-gap` markers; PR "Requirement gaps"; obs 9 |
| FR-96 in-session review | step 9 per-set approve/change/drop, approvals in the draft |
| FR-97 independent critique | step 10 fresh `ux-reviewer` worker; blocking rules; verdict not cached; obs 8 |
| FR-98 phase gate | step 11 branch `docs/ux/<slug>`, PR sections, never merges |
| FR-99 superseded | step 9 re-renders only changed screens (TDD 0070 scoping) |
| FR-100 authoring discipline | step 0 drafts + FR-86; step 2 interrogator; step 5 rubric; obs 3, 4 |
| FR-22 loads without delegates | the skill needs no delegate (degrade path); README states it |
| FR-79 both harnesses | role-based discovery; harness-agnostic actions; obs 5 |
| FR-81 harness-agnostic language | `ux-author` added to the [K] scan; obs 5 |
| FR-86 light-tier check | byte-identical `tl:fr86-check`; obs 4 |
| FR-87 critique worker inherits | `ux-reviewer` `model: inherit`, dispatched with no model parameter; obs 8 |
| NFR-1 human merge | step 11 never merges |
| NFR-3 judgment on the parent model | authoring + critique inherit; no light-tier worker in this skill |

## Dependencies considered
- **Delegated design skills, by role (chosen).** No new code dependency.
  The skill invokes whatever the harness offers.
  - *Rejected: bundling a specific design skill, or requiring the Figma
    MCP.* That would make a hard delegate dependency (contradicting
    FR-83) and lock the skill to a vendor. Figma also stores the record
    outside git.
  - *Rejected: generating visual design in throughline's own scripts.*
    That reinvents what the delegates do (the PRD's non-goal).
- **`agents/ux-reviewer.md` (chosen), a new agent.** *Rejected: reusing
  `design-reviewer` with a UX mode.* Its checklist is TDD-specific, and
  merging would dilute both prompts.
- **Reading rules from `/prd-author` by reference (chosen).**
  - *Rejected: copying the interrogator and rubric sections.* That is
    ~150 duplicated lines, and the copies drift.
  - *Rejected: a shared rules file.* It would touch both existing skills
    for no behavioural gain.

## PRD conflicts surfaced (and resolution)
- FR-99's "untouched screens byte-identical" holds for HTML. A viewport
  change deliberately re-renders every screen's PNGs.
- FR-90's acceptance says "the first thing shown is a screen plan naming
  that requirement id". The step-0 resume prompt and the FR-86
  continue/stop prompt can come first; both are session gates, not
  content. FR-100 also applies the FR-75 interview to the
  plan. This design satisfies both. Step 1b shows a mechanically built
  draft plan before any question, and steps 2–4 interrogate and refine
  it into the approved plan.
- FR-97 lists "touch-target size" without a number. This design uses the
  common 44×44 CSS px floor on phone viewports, as a finding rather than
  a block.
- FR-91's "flow index page" is generated (`tl_ux_index_html`), not
  delegate-authored, so it cannot drift from `index.json`.

## Decisions to promote (ADR candidates)
- Promoted: ADR 0017 (UX record: in-repo, self-contained HTML, delegated by
  role, design input not a build gate), added in this design PR.

## Touched files
- `skills/ux-author/SKILL.md` — new skill (steps 0–11, `tl:` blocks)
- `agents/ux-reviewer.md` — FR-97 critique worker
- `tests/ux-author-skill.test.sh` — obs 1–3, 6–9
- `tests/plugin-root.test.sh` — add `ux-author` to the FR-81 [K] list
- `tests/parent-session-check.test.sh` — add `ux-author` to `NAMES`
- `README.md` — `/ux-author` subsection
- `.claude-plugin/plugin.json` — description names `/ux-author`

## Expected diff size
- `skills/ux-author/SKILL.md` — 290 lines
- `agents/ux-reviewer.md` — 80 lines
- `tests/ux-author-skill.test.sh` — 260 lines
- `tests/plugin-root.test.sh` — 4 lines
- `tests/parent-session-check.test.sh` — 6 lines
- `README.md` — 45 lines
- `.claude-plugin/plugin.json` — 2 lines

Total expected diff: 687 lines across 7 files.

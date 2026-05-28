# TDD 0014: Bounded TDD scope — declared expected-diff-size, mechanical bounds, design-critique scope authority

Status: draft
PRD refs: FR-53, FR-54, FR-55
PRD-rev: a961955
ADR constraints: 0003, 0004, 0005

## Approach

Theme A binds three knobs that were previously implicit: TDD doc size, per-file
expected-diff size, and the touched-file set. Each TDD authored under this TDD
must declare its scope in two new required sections — `## Touched files` and
`## Expected diff size` — and that declaration becomes a falsifiable input to
the `/tdd-author` design-critique gate. Two new mechanical checks extend the
FR-51 pre-pass (already specified in TDD 0013) to fail-fast on bound violations
before any model time is spent on review; one new qualitative check is added to
the design-reviewer subagent (FR-10) for the working-memory call mechanical
bounds cannot make. The design-critique gate is the authoritative scope check
under FR-55 — `/implement` does NOT add a scope check of its own (per ADR 0005,
"gate scope by prompt, not sandbox") and never halts a build for a scope
concern the design phase missed.

On a bound violation, `/tdd-author` presents the user three options via
`AskUserQuestion`: (1) split the TDD manually, (2) accept a draft split set the
skill proposes (rule: one TDD per Sequencing-plan section), (3) override with a
recorded justification (the FR-53 escape clause for legitimately-wide-but-
shallow edits, lockfiles, generated files). The choice is recorded in the TDD
itself; the design-critique gate verifies the justification exists and is
specific (not boilerplate).

Initial bound values, calibrated from the existing TDD set:

- **Clean (converged in 0 rework iterations):** TDDs 0007/0008 = 185/189 lines;
  TDD 0009 = 330 (draft); TDD 0010 = 243 (draft). Max clean = 330.
- **Troubled / unproven:** TDD 0011 = 540 lines (required 11 manual fix
  iterations); TDDs 0012/0013 = 528/517 (drafts, not yet built — their size is
  the diagnostic concern Theme A addresses).

The cut between clean and troubled is in the 330–500-line range, so:

- `THROUGHLINE_TDD_MAX_LINES` — default **350**. TDD doc body (excluding
  frontmatter) above this triggers the refusal flow. Clears the clean set,
  rejects the troubled set, gives ~20 lines of margin over the largest clean
  TDD (0009 at 330).
- `THROUGHLINE_TDD_MAX_FILE_DIFF` — default **300**. Per-touched-file
  expected-diff-size declaration above this triggers refusal unless a justified
  exception is recorded against that file.
- `THROUGHLINE_TDD_MAX_TOUCHED` — default **8**. Touched-file count above
  this triggers refusal (a TDD touching nine independent files is almost
  certainly two TDDs).

All three are env-overridable for experimentation, matching the existing
`THROUGHLINE_REVIEW_MODEL` / `THROUGHLINE_RUNTIME_VERIFY_MODEL` pattern from
TDD 0013.

This TDD's own scope declaration (see `## Touched files` and `## Expected diff
size` below) is itself an example application of the new shape, written under
the proposed bounds.

## Components & interfaces

### 1. TDD template additions (skills/tdd-author/SKILL.md)

Two new required sections inserted into the template block in
`skills/tdd-author/SKILL.md` (the fenced ```...``` block around line 130–145
of the skill):

```
## Touched files            (REQUIRED: declared scope set for FR-67 structural-finding check)
## Expected diff size       (REQUIRED: per-file lines added/removed estimate; declare exceptions inline)
```

`## Touched files` carries an explicit list of file paths (one per line, with
optional one-line purpose). `## Expected diff size` carries a per-file estimate
of lines added/removed, plus optional inline exception markers of the form
`(exception: <one-line justification>)` for files declared above the per-file
cap. A required summary line `Total expected diff: <N> lines across <M>
files.` closes the section. Both sections are non-optional; their absence is a
mechanical-pre-pass FAIL.

### 2. Mechanical pre-pass extension (FR-51 + this TDD)

The mechanical pre-pass currently scoped to TDD 0013 (`scripts/tdd_precheck.sh`
or whatever name TDD 0013 fixes) gains three new checks, run on each authored
TDD file in the set:

- **`check_tdd_doc_size`** — counts lines in the TDD body (frontmatter
  excluded). Emit `PRECHECK_FAIL: tdd-doc-size <N> > <max>` if `N >
  THROUGHLINE_TDD_MAX_LINES`.
- **`check_per_file_diff_bound`** — parses the `## Expected diff size`
  section into `(file, lines, exception?)` triples. For any triple where
  `lines > THROUGHLINE_TDD_MAX_FILE_DIFF` AND no `(exception: …)` marker is
  present, emit `PRECHECK_FAIL: per-file-diff <file> <lines> > <max> (no
  exception)`.
- **`check_touched_file_count`** — counts entries in `## Touched files`.
  Emit `PRECHECK_FAIL: touched-files <N> > <max>` if `N >
  THROUGHLINE_TDD_MAX_TOUCHED`.

Each check runs in pure bash + standard text tooling (awk/grep/wc) — no LLM
call. FAIL outputs are caught by the skill (next component).

### 3. Refusal flow in `/tdd-author` step 7b (skills/tdd-author/SKILL.md)

Step 7b of the skill (the design-critique gate) gains a new sub-step that runs
*after* the existing FR-51 pre-pass cleanup checks but *before* spawning the
`design-reviewer` subagent. On any `PRECHECK_FAIL` from §2 above, the skill
collects the failing TDD(s) and presents the user three options via
`AskUserQuestion`:

| Option | Effect |
|---|---|
| Split manually | Skill exits the gate; user revises the TDD; user re-invokes `/tdd-author`. |
| Accept draft split set | Skill proposes a per-`Sequencing` split: one new TDD per top-level numbered item in the offending TDD's `## Sequencing / implementation plan`. User reviews; on approval, skill rewrites the file set. |
| Override with justification | Skill prompts for a one-line justification (or multi-line; min 20 chars, max 400). Justification is inserted into the offending TDD as a new `## Scope override` section. Pre-pass re-runs; if any bound is still violated and no inline exception covers the violation, refusal repeats (the user must justify *each* over-bound file individually, not blanket the whole TDD). |

The draft-split-set rule deliberately uses `## Sequencing / implementation
plan` items as the unit because they're already the unit chosen for continuous
review checkpointing (Theme B / TDD 0020), so the split aligns Theme A's
authoring granularity with Theme B's review granularity.

### 4. Design-reviewer subagent prompt addition (FR-10 + FR-55)

The `design-reviewer` agent definition at `agents/design-reviewer.md`
gains a new checklist item ahead of its existing checks:

> **Scope coherence (working-memory check):** Read each TDD top-to-bottom in
> one pass. Could a competent engineer hold the entire proposal — the
> approach, the components, the failure modes, the verification plan — in
> working memory while building it? If you find yourself losing track of an
> earlier component while reading a later one, that is a scope finding. The
> mechanical pre-pass has already enforced doc-size, per-file-diff, and
> touched-file bounds; your job is the qualitative call mechanical checks
> cannot make: too many distinct concepts, too many independent change
> threads, hidden coupling between components. Flag scope concerns with
> `DESIGN_REVIEW: BLOCK scope-coherence — <reason>`; the absence of such a
> flag is the authoritative "this TDD's scope is fine" verdict per FR-55.

This is the one check FR-55 reserves for the design-critique gate alone — it
runs after §2's mechanical bounds clear, so the LLM is never asked to grade
something mechanically over-bound (cheaper, and matches TDD 0013's "tool for
the job" disposition).

### 5. No `/implement`-side check (FR-55 enforcement)

`/implement` does NOT add a scope check of its own. The runner is forbidden
from halting a build with a `scope-concern` cause; if one ever fires, it is a
defect in this TDD's mechanical pre-pass (§2) or the design-reviewer prompt
(§4), not a runtime concern. FR-63's halt enum (TDD 0018) reflects this — no
`scope-concern` value exists in the enum.

This matches ADR 0005's disposition: gate scope is enforced by prompt and
downstream detection, never by sandboxing the build.

## Data & state

No new run-state schema changes from this TDD. The bound values are
configuration (env vars + defaults), not state. The `## Touched files` and
`## Expected diff size` declarations are durable on disk inside each TDD —
they are the artifact the FR-67 structural-finding check (TDD 0019) reads at
build time to detect "fix touches files outside the declared set."

## Sequencing / implementation plan

1. **TDD template additions** — edit `skills/tdd-author/SKILL.md` template
   block to add `## Touched files` and `## Expected diff size` as required
   sections; update the step-5 instructions to describe what each section
   contains.
2. **Mechanical pre-pass extension** — extend the FR-51 pre-pass script
   (delivered by TDD 0013) with `check_tdd_doc_size`,
   `check_per_file_diff_bound`, `check_touched_file_count`. Each emits a
   `PRECHECK_FAIL: <check> <details>` line on failure; clean exit otherwise.
3. **Refusal flow in step 7b** — edit `skills/tdd-author/SKILL.md` step 7b
   to invoke the extended pre-pass; on `PRECHECK_FAIL`, run the
   `AskUserQuestion` three-option flow described in §3. The split-set
   generator is a deterministic transformation (one new TDD per
   `## Sequencing` item); no LLM call required for the proposal itself,
   though the user reviews it.
4. **Design-reviewer prompt addition** — locate the `design-reviewer` agent
   definition and add the working-memory scope-coherence checklist item from
   §4 ahead of its existing checks.

## Failure modes & edge cases

- **TDD lacks the new required sections.** Pre-pass emits `PRECHECK_FAIL:
  missing-section <section-name>`. Skill BLOCKs; reviewer never invoked. User
  edits the TDD to add the sections.
- **Expected-diff section malformed (unparseable).** Pre-pass parser is
  permissive: each line matching `^- \S` is treated as a file entry; trailing
  `(\d+)\s*lines?` extracts the count. Lines that don't parse are reported as
  `PRECHECK_FAIL: expected-diff-malformed <line>`; user fixes the format.
- **All three checks fail at once.** All `PRECHECK_FAIL` lines are emitted;
  the skill's refusal flow surfaces them as a single multi-line message in the
  `AskUserQuestion` question text. User decides which option to pick once,
  not per-failure.
- **User picks "draft split set" but the proposal is wrong.** The split is a
  proposal, not an enforcement. User can edit the proposed file set before
  approval; if the proposal is rejected entirely, the skill falls back to
  "split manually."
- **User picks "override" but the justification is boilerplate.** The
  design-reviewer subagent's working-memory check sees the `## Scope
  override` section and is instructed to grade the justification specifically
  ("does this justification explain why the over-bound is legitimately wide
  but shallow, or does it just restate the bound was exceeded?"). Empty or
  boilerplate justifications still BLOCK at the design-reviewer.
- **A previously-merged TDD now exceeds the bounds after a future tightening
  of `THROUGHLINE_TDD_MAX_*`.** The bounds apply at authoring time; an
  already-merged TDD is not retroactively refused. The Theme D refactor TDDs
  (0015/0016/0017) bring the *codebase* into compliance with the bounds, but
  there's no equivalent retroactive sweep of the design-doc set — the
  separate quick-pass TDD revision (deferred per the design plan) updates
  the four existing drafts (0009, 0010, 0012, 0013) to add the new sections
  with their current declared values.
- **`THROUGHLINE_TDD_MAX_*` set to 0 or negative.** Pre-pass treats
  non-positive values as "skip this bound check entirely" — an escape valve
  for `/tdd-author` re-runs against the legacy TDD set during the Theme D
  refactor period, before the four drafts get their new sections.

## Verification plan

**Observable surface:** `/tdd-author` skill behavior — specifically, the
`AskUserQuestion` prompt emitted on step 7b, and the `PRECHECK_FAIL` lines
emitted by the pre-pass script. Plus the `DESIGN_REVIEW: BLOCK
scope-coherence` line emitted by the design-reviewer subagent.

**Observation points:**

1. **Mechanical bound violation triggers refusal flow.** Author a fixture
   TDD file with a body of 500 lines (over the 350-line default), invoke
   `/tdd-author` against it. Expect: the skill emits the three-option
   `AskUserQuestion` prompt, with the question text containing the literal
   string `PRECHECK_FAIL: tdd-doc-size 500 > 350`.
2. **Per-file diff violation without exception triggers refusal.** Author a
   fixture TDD whose `## Expected diff size` section declares
   `- scripts/foo.sh — 500 lines` (no `(exception:)` marker). Invoke
   `/tdd-author`. Expect: `PRECHECK_FAIL: per-file-diff scripts/foo.sh 500 >
   300 (no exception)` in the prompt text.
3. **Per-file diff violation with valid exception passes mechanical check.**
   Same fixture but with `- scripts/foo.sh — 500 lines (exception: code move
   from implement.sh, no behavior change)`. Expect: the mechanical pre-pass
   passes that check (the line does NOT appear in `PRECHECK_FAIL` output);
   pre-pass output continues to the design-reviewer.
4. **Touched-file count violation triggers refusal.** Author a fixture with
   12 entries in `## Touched files` (over the 8 default). Expect:
   `PRECHECK_FAIL: touched-files 12 > 8` in the prompt text.
5. **Clean TDD reaches the design-reviewer.** A fixture TDD that fits all
   bounds reaches step 7b's design-reviewer subagent invocation; the
   subagent's output is visible to the user via the skill's report.
6. **Design-reviewer scope-coherence BLOCK.** Author a fixture TDD that
   *technically* fits the mechanical bounds (340 lines, 7 files, each ≤ 300
   lines diff) but proposes five mutually-coupled new abstractions in five
   different files. Invoke `/tdd-author`. Expect: pre-pass passes; the
   design-reviewer emits `DESIGN_REVIEW: BLOCK scope-coherence — <reason>`
   and step 7b reports the BLOCK to the user.
7. **No `/implement`-side scope check.** Invoke `/implement` against a
   merged TDD whose body is now 380 lines (someone edited it post-merge
   beyond the bound). Expect: build proceeds normally; no `PRECHECK_FAIL`
   or scope-related halt appears in the run-state record. The bound applied
   only at authoring time (FR-55 enforced).

**Expected observations (PASS):** for each fixture above, the cited
`PRECHECK_FAIL` / `DESIGN_REVIEW: BLOCK` / clean-pass behavior is observed.
No fixture triggers the wrong refusal arm or skips the design-reviewer when
clean.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-53 (TDD scope bound) | §1 (template additions) + §2 (mechanical pre-pass extensions: `check_tdd_doc_size`, `check_per_file_diff_bound`, `check_touched_file_count`) + bound defaults in `## Approach` (250 / 300 / 8) |
| FR-54 (design-time refusal of over-ambitious per-file change) | §2's `check_per_file_diff_bound` + §3's refusal flow (three options); refusal occurs at `/tdd-author` time, before any build, before the design PR is opened |
| FR-55 (design-critique gate is the authoritative scope check) | §4 (design-reviewer working-memory check) + §5 (no `/implement`-side check; no `scope-concern` value in FR-63's halt enum) |

No gaps; no requirement in scope falls outside §1–§5.

## Dependencies considered

No new external dependencies. The mechanical checks use bash + `awk`/`grep`/
`wc` already required by TDD 0013's pre-pass; the `AskUserQuestion`
mechanism is provided by the Claude Code tool surface already used elsewhere
in the skill. No language runtime, no library, no service.

(Per the throughline architecture disposition, alternatives considered for
the mechanical check implementation:
- **Python script** — rejected: adds a runtime dependency that the
  bootstrap-project skill does not currently mandate; shell tooling
  suffices.
- **Embed the checks in the design-reviewer subagent's prompt** — rejected:
  spends model tokens on work a regex can do in microseconds; matches
  TDD 0013's "tool for the job" rationale.)

## PRD conflicts surfaced (and resolution)

None. FR-53/54/55 are internally consistent; the only design-time question
the PRD defers ("specific bound values") is resolved here with the
TDD-0011-calibrated defaults plus env override.

## Decisions to promote (ADR candidates)

None from this TDD alone. The scope-by-prompt disposition this TDD applies
is already ADR 0005; this TDD is one of its concrete applications.

(The two ADR promotions in this design pass — ADR 0006 on verifiable
artifacts and ADR 0007 on the halt model — come from TDDs 0020/0021 and
0018/0019 respectively, not from this TDD.)

## Touched files

- `skills/tdd-author/SKILL.md` — template additions (§1) + step 7b refusal
  flow (§3)
- `scripts/tdd_precheck.sh` (or whatever name TDD 0013 lands the file
  under) — three new check functions (§2)
- `agents/design-reviewer.md` — scope-coherence checklist item (§4)
- `docs/PRD.md` — no edits (the FRs are already written; this TDD just
  implements them)

Total: 3 files touched.

## Expected diff size

- `skills/tdd-author/SKILL.md` — ~80 lines (new template section text +
  step 7b sub-step description + the three-option flow specification)
- `scripts/tdd_precheck.sh` — ~120 lines (three check functions + their
  shared `PRECHECK_FAIL` emitter; pure bash + awk)
- design-reviewer agent definition — ~25 lines (one new checklist item, a
  paragraph of guidance)

Total expected diff: ~225 lines across 3 files.

---
name: tdd-author
description: Reconcile the current PRD against the previous PRD version and the existing TDDs, decide how many Technical Design Docs the change needs and their scope, then author them. Run once per PRD update, in its own session. Invoke with /tdd-author.
disable-model-invocation: true
---

# TDD authoring

Run once after a PRD update. YOU decide how many TDDs to write, and their scope,
based on what changed. Persist each to `docs/tdd/NNNN-<slug>.md`.

## Relationship to superpowers (read first)
This skill IS the technical-design step for throughline — the governance-producing
equivalent of `superpowers:writing-plans`. When the user invokes `/tdd-author`, do
NOT also invoke `superpowers:brainstorming` or `writing-plans`; this skill owns the
phase and its output is the TDD/ADR design-of-record (see [[ADR 0001]] in
`docs/adr/`). If a `docs/superpowers/plans/*` (or `specs/*`) file or other prior
design notes exist, READ and fold in their substance rather than redoing the work;
they are transient input, never authoritative, never relocated. The canonical
record is `docs/tdd/` + `docs/adr/`. A throughline TDD is a DESIGN, not a
step-by-step build script — the bite-sized failing-test-first task breakdown is
`/implement`'s job (`build-prompt.md`), so do not reproduce it here.

## 1. Determine what changed in the PRD
- Read the current `docs/PRD.md`.
- Establish the previous version: the `PRD-rev` recorded in the most recent
  existing TDD's frontmatter. If TDDs exist, run
  `git diff <that-rev> -- docs/PRD.md` to see exactly what changed since the
  last design pass. If no TDDs exist, treat the entire PRD as new.
- If `docs/PRD.md` has uncommitted changes, ask the user to commit it first so
  the delta is well-defined (or, with consent, diff the working tree vs HEAD).

## 2. Inventory existing coverage
- Read every `docs/tdd/*.md` and its `PRD refs`. Build the map of which PRD
  requirements are already covered by a TDD, and by which.
- Read `docs/tdd/BLOCKERS.md` if present. Each unchecked entry is a design-level
  blocker `/implement` hit while building — a requirement that proved infeasible,
  self-contradictory, or in conflict with an accepted ADR. Treat these as
  first-class inputs to this pass: the design (or a superseding ADR) must resolve
  each one. After authoring the TDD/ADR that resolves a blocker, check off or
  delete its entry and note the resolution in the TDD's "PRD conflicts surfaced"
  section.

## 3. Decide the set of TDDs (the key judgment)
From the delta and the coverage map, identify:
- **New** requirements with no covering TDD  → new TDD(s).
- **Changed** requirements whose covering TDD is now stale  → **revise OR
  supersede, per the covering TDD's `Status`**:
  - `draft` or `ready` → in-place revision is allowed (the TDD isn't built yet).
    Bump the `PRD-rev` to the SHA you're designing against; otherwise the same
    file.
  - `implemented` → **supersede with a new TDD**. The throughline pipeline is
    append-only on substance for implemented design documents (the same rule
    `adr-new` enforces for accepted ADRs): an implemented TDD is a historical
    record of what was built, why, and against which constraints. Substantive
    changes get a *new* TDD that carries `Supersedes: NNNN` in its frontmatter
    and re-states the design from the new ground truth — what's carried
    forward, what's changed, and why. Only the old TDD's `Status:` line is
    edited (set to `superseded by NNNN`); its body stays as written. Never
    rewrite an implemented TDD's substance in place.
- **Unchanged/covered** requirements  → leave alone.
Group related requirements into coherent units of work — one TDD per unit.
Decide the count and the scope of each; don't split arbitrarily or lump
unrelated work together.

Scope-tightening PRD changes (a requirement is removed, a configuration moves
to a non-goal, two surfaces collapse to one) typically produce more supersession
work than additive PRD changes — multiple implemented TDDs may become stale at
once. Surface that in the plan rather than minimizing it.

Present this PLAN to the user before writing: the TDDs you intend to create
(scope + which requirements each covers), and per existing-TDD impact, whether
you intend to **revise in-place** (draft/ready) or **supersede** (implemented).
Get approval; adjust as directed.

## 4. Load design constraints
Read `docs/adr/INDEX.md`. Treat only `accepted` ADRs as binding; pull full ADR
bodies on demand by relevant Scope. Exclude superseded; note proposed.

## 5. Author the approved set
> Tip: the interview parts of this phase benefit from `/fast` (faster output, still
> Opus) for snappier back-and-forth; toggle it off if you want slower, more
> deliberate output while authoring the designs themselves.

Interview the user (AskUserQuestion) on the cross-cutting and per-unit design
decisions. These features are related — reason about them together so the
designs stay consistent. CHALLENGE the PRD: surface infeasible, contradictory,
or under-specified requirements, and any conflict with an accepted ADR, before
designing around them.

Apply the architecture & dependency dispositions (also in global CLAUDE.md):
- **Evaluate alternatives before any dependency (REQUIRED, not optional).** For
  every new library, framework, service, or integration, the TDD's "Dependencies
  considered" section MUST name at least one concrete rejected alternative with a
  one-line reason (licensing, cost, maintenance posture, lock-in). "None
  considered", or an empty/boilerplate section, is not acceptable; if no real
  alternative exists, state explicitly why. Prefer OSS/self-hostable for projects
  branded as such; vendor/subscription-gated deps need deliberate justification.
  The design-critique gate (step 7) BLOCKS a TDD that adds a dependency without
  this analysis, and `/implement` BLOCKS a build that needs a dep the TDD never
  sanctioned — so the analysis cannot be deferred to build time.
- **Don't reinvent what an integrated dependency already provides.** Before
  designing a new abstraction (plugin interface, schema, protocol), check the
  API surface of the system you're integrating with — it may already exist there.

Write each TDD from the template, numbered sequentially, `Status: draft`. Each
TDD MUST include a traceability table mapping every PRD requirement in its scope
(FR/NFR) to the design element that satisfies it, and call out any gaps.

**No placeholders.** Design content must be specific enough to implement without
guessing. "Handle errors appropriately", "add validation", "address edge cases",
"TBD", a bare section header, or a `## Verification plan` that reads "verify it
works" / "tests will pass" / "the change works as expected" are design FAILURES —
name the actual error paths, the actual validation, the actual edge cases, the
actual observable surface and observation points. If something is genuinely
undecided, record it as a named open question or a `BLOCKED`-style note, not a
vague verb.

**Verification plan (REQUIRED).** Every TDD carries a `## Verification plan` that
names the change's *observable surface* (where the change manifests for a user,
human or programmatic: CLI stdout / exit code, HTTP response, library return
value or thrown error, log line, file or DB write, DOM / rendered output), the
*observation point(s)* (the concrete scenarios that drive the changed code to
where it executes — the exact command, request, function call + inputs, or UI
action), and the *expected observations (PASS)* — the specific values or
invariants that must hold at the surface. If the change has genuinely no
observable surface (e.g. a pure internal refactor), the plan must declare
`SKIP: <why>` rather than be omitted — never silent (NFR-4). This plan is what
`/implement`'s runtime-verification gate drives; the *mechanism* is the project's,
delegated (FR-26 / ADR 0004), so do NOT specify a particular harness or framework
— state what to observe and where to observe it. A missing or non-actionable
plan is BLOCKed by the design-critique gate (step 7b).

**Declared scope (REQUIRED — TDD 0014 / FR-53, FR-54).** Every TDD declares its
scope in two sections so the bound is a falsifiable design input, not a
build-time surprise:
- `## Touched files` — an explicit list of the source files this TDD changes,
  one per line as `- <path> — <one-line purpose>`. This is the declared set the
  build-time structural-finding check (FR-67) reads to detect a fix that touches
  files outside it.
- `## Expected diff size` — a per-file estimate of lines added/removed, one per
  line as `- <path> — <N> lines`, closed by a summary line
  `Total expected diff: <N> lines across <M> files.`. A file legitimately over
  the per-file cap (a code move, a lockfile, a generated file) declares an
  inline exception: `- <path> — <N> lines (exception: <one-line justification>)`.

  Keep each TDD inside the bounds (defaults: body ≤ `THROUGHLINE_TDD_MAX_LINES`
  = 350 lines, per-file diff ≤ `THROUGHLINE_TDD_MAX_FILE_DIFF` = 300 lines,
  touched files ≤ `THROUGHLINE_TDD_MAX_TOUCHED` = 8). A TDD that blows a bound
  without a recorded exception is refused at design time by step 7b's scope
  pre-pass — split it instead. The bounds are env-overridable for
  experimentation, matching the `THROUGHLINE_REVIEW_MODEL` pattern.

```
# TDD NNNN: <feature>
Status: draft | ready | implemented
PRD refs: <requirement numbers satisfied>
PRD-rev: <git short SHA of docs/PRD.md at authoring time>
ADR constraints: <accepted ADR numbers this design respects>
Supersedes: <NNNN, only when this TDD replaces a previously-implemented one>

## Approach
## Components & interfaces
## Data & state
## Sequencing / implementation plan
## Failure modes & edge cases
## Verification plan          (observable surface → observation point(s) → expected observations; SKIP: <why> only if no surface)
## Requirement traceability   (each FR/NFR in scope → design element; note gaps)
## Dependencies considered    (REQUIRED per new dep: chosen + ≥1 rejected alternative + reason)
## PRD conflicts surfaced (and resolution)
## Decisions to promote (ADR candidates)
## Touched files              (REQUIRED: declared scope set for the FR-67 structural-finding check)
## Expected diff size         (REQUIRED: per-file lines added/removed estimate; declare exceptions inline)
```

## 6. ADR evaluation
Evaluate the whole set you just wrote against the existing ADRs and present
recommendations for approval — analyze, don't merely ask:
- **New-ADR candidates** — durable, cross-cutting decisions or patterns not yet
  captured. A pattern shared across several of the new and/or existing TDDs is
  a strong candidate.
- **Supersession candidates** — anything conflicting with or reversing an
  accepted ADR.
For each: proposed action, one-line rationale, confidence (mark low-confidence
"optional"). Keep the bar HIGH; recommend zero if nothing qualifies. On
approval, invoke the `adr-new` skill (via the Skill tool) for each — it is
model-invocable precisely so this close-out can call it.

## 7. Review the design — self-review first, then the independent gate

**7a. Author self-review (cheap pass, do it BEFORE spawning the reviewer).** Reread
the whole authored set with fresh eyes and fix issues inline — this catches the
obvious stuff so the independent gate spends its judgment on substance:
- **Traceability gaps** — every in-scope PRD requirement maps to a concrete design
  element? Any untraced or hand-wavingly-traced requirement?
- **Placeholder/vagueness scan** — any "TBD"/"handle errors"/empty section that the
  no-placeholder rule forbids? Make it concrete.
- **Verification plan** — every TDD has a concrete `## Verification plan` (or a
  justified `SKIP`)? No "verify it works"/"tests will pass" placeholders; observable
  surface, observation point(s), and expected observations all named.
- **Interface-name consistency** — the same concept named the same way across all
  the TDDs in the set (a type/function called `X` in one TDD and `X'` in another is
  a bug). Reconcile names.
- **Ambiguity** — could any design element be read two ways? Pick one, state it.

Fix and move on (no re-review loop).

**Mechanical pre-pass (TDD 0013 / FR-51).** Before moving to 7b, run

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tdd-lint.sh" docs/tdd/<your-set>
```

and address every finding. The pre-pass detects the structural-gap findings the
design-reviewer would otherwise spend tokens on (missing required section,
missing frontmatter, placeholder strings outside fences, untraced FR/NFR).
If `tl_lint_all` exits non-zero, fix the findings or record an explicit waiver
in the design PR body before invoking the design-reviewer in 7b. The
design-reviewer subagent is NOT invoked when there are unaddressed mechanical
findings — that would waste tokens on work a `grep` already did.

**Scope-bound pre-pass + refusal flow (TDD 0014 / FR-53, FR-54).** After the
structural pre-pass is clean and BEFORE spawning the design-reviewer, run the
scope-bound checks on each authored TDD (run per-file so a `PRECHECK_FAIL` is
attributable to a specific TDD):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tdd-lint.sh" --bounds docs/tdd/<each-tdd>
```

This emits a `PRECHECK_FAIL: <check> <details>` line per bound violation
(`tdd-doc-size`, `per-file-diff`, `touched-files`, `missing-section`, or
`expected-diff-malformed`). No model time is spent here — these are pure-`awk`
checks. On a clean exit (no `PRECHECK_FAIL`), proceed to 7b.

On ANY `PRECHECK_FAIL`, collect the failing TDD(s) and present the user three
options via `AskUserQuestion`, with the question text containing the verbatim
`PRECHECK_FAIL` lines (when several fail at once, surface them all in one
question — the user decides once, not per-failure):

| Option | Effect |
|---|---|
| **Split manually** | Exit the gate. The user revises the TDD and re-invokes `/tdd-author`. |
| **Accept draft split set** | Propose a per-`Sequencing` split: one new TDD per top-level numbered item in the offending TDD's `## Sequencing / implementation plan` (this is a deterministic transformation — no model judgment in the proposal itself). The user reviews and may edit the proposed file set before approval; if rejected entirely, fall back to "split manually". On approval, rewrite the file set. |
| **Override with justification** | Prompt for a justification (min 20, max 400 chars). Insert it into the offending TDD as a new `## Scope override` section. Re-run the scope pre-pass; if any bound is still violated and no inline `(exception: …)` marker covers that specific file, the refusal repeats — the user must justify *each* over-bound file individually, never blanket the whole TDD. A boilerplate or empty justification still BLOCKs at the design-reviewer (it grades the `## Scope override` text specifically). |

The draft-split-set rule uses `## Sequencing / implementation plan` items as the
split unit deliberately: they are already the unit chosen for continuous-review
checkpointing, so the split aligns authoring granularity with review
granularity. Do NOT add a scope check to `/implement` — per ADR 0005 and FR-55,
the design-critique gate is the sole scope authority; the build never halts on a
scope concern this gate missed.

**7b. Independent design critique (gate — do not skip).** Before opening the design
PR, get an INDEPENDENT critique of the whole authored set. Spawn the
`design-reviewer` subagent — it runs in fresh context on a
different model than you authored in, so it does not share your blind spots. It
reads the PRD, the TDD(s), and the accepted ADRs and checks requirement
traceability, interface specification, the REQUIRED alternatives analysis, ADR
conflicts, and scope coherence, ending with `DESIGN_REVIEW: PASS` or
`DESIGN_REVIEW: BLOCK <reason>`.

- Pre-requisite: `tl_lint_all` exit 0 (or recorded waiver). The design-reviewer
  assumes the pre-pass is clean; spawning it on a structurally-broken TDD set
  is the wrong tool for the job and burns tokens (TDD 0013 / FR-51).

- On BLOCK: fix the design — tighten interfaces, add the missing alternatives
  analysis, resolve the ADR conflict, re-scope — and re-run the critique until it
  passes. If you consciously disagree with a finding, record an explicit waiver
  with your rationale rather than silently ignoring it.
- Do NOT open the design PR with an unresolved blocker and no waiver.
- Carry the critique's verdict and findings summary (and any waivers) into the
  design PR body (step 9) so the human reviewer gates on an informed view, not a
  bare diff.

## 8. Close-out
Report which TDDs were written (as `draft`) and which existing TDDs you
recommend revising. TDDs stay `draft`.  Merging the design PR lands them on the
integration branch, and THAT is what makes them buildable: after the merge the
user runs `/implement`, which builds every TDD the merge delivered.

## 9. Git (phase gate — the human design review)
Unless the user says "skip git":
- Merge the PRD PR first, then branch `docs/design/<change-slug>` off `main`, so
  you design against approved requirements. Stamp each TDD's `PRD-rev` with the
  PRD commit SHA you designed against.
- Commit the TDD set AND any ADRs promoted this round TOGETHER — ADRs ride in the
  design PR because they justify decisions made in these TDDs.
- Open the design PR with `gh pr create` (base `main`) and put the design-critique
  verdict + findings summary (and any waivers) in the PR body, so the human
  reviews an INFORMED design, not a bare diff. Do NOT merge — the human merge of
  this PR is the design gate: merging is what makes the TDDs buildable, so they are
  built only after it lands.

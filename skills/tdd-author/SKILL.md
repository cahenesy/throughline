---
name: tdd-author
description: Reconcile the current PRD against the previous PRD version and the existing TDDs, decide how many Technical Design Docs the change needs and their scope, then author them. Run once per PRD update, in its own session. Invoke with /tdd-author.
disable-model-invocation: true
---

# TDD authoring

Run once after a PRD update. YOU decide how many TDDs to write, and their scope,
based on what changed. Persist each to `docs/tdd/NNNN-<slug>.md`.

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
- **Changed** requirements whose covering TDD is now stale  → flag that TDD for
  revision, noting what changed; propose an update if warranted.
- **Unchanged/covered** requirements  → leave alone.
Group related requirements into coherent units of work — one TDD per unit.
Decide the count and the scope of each; don't split arbitrarily or lump
unrelated work together.

Present this PLAN to the user before writing: the TDDs you intend to create
(scope + which requirements each covers) and any existing TDDs you recommend
revising. Get approval; adjust as directed.

## 4. Load design constraints
Read `docs/adr/INDEX.md`. Treat only `accepted` ADRs as binding; pull full ADR
bodies on demand by relevant Scope. Exclude superseded; note proposed.

## 5. Author the approved set
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

```
# TDD NNNN: <feature>
Status: draft | ready | implemented
PRD refs: <requirement numbers satisfied>
PRD-rev: <git short SHA of docs/PRD.md at authoring time>
ADR constraints: <accepted ADR numbers this design respects>

## Approach
## Components & interfaces
## Data & state
## Sequencing / implementation plan
## Failure modes & edge cases
## Requirement traceability   (each FR/NFR in scope → design element; note gaps)
## Dependencies considered    (REQUIRED per new dep: chosen + ≥1 rejected alternative + reason)
## PRD conflicts surfaced (and resolution)
## Decisions to promote (ADR candidates)
```

## 6. ADR evaluation (do not skip)
Evaluate the whole set you just wrote against the existing ADRs and present
recommendations for approval — analyze, don't merely ask:
- **New-ADR candidates** — durable, cross-cutting decisions or patterns not yet
  captured. A pattern shared across several of these related TDDs is a strong
  candidate.
- **Supersession candidates** — anything conflicting with or reversing an
  accepted ADR.
For each: proposed action, one-line rationale, confidence (mark low-confidence
"optional"). Keep the bar HIGH; recommend zero if nothing qualifies. On
approval, invoke `/adr-new` for each.

## 7. Design critique (independent gate — do not skip)
Before opening the design PR, get an INDEPENDENT critique of the whole authored
set. Spawn the `design-reviewer` subagent — it runs in fresh context on a
different model than you authored in, so it does not share your blind spots. It
reads the PRD, the TDD(s), and the accepted ADRs and checks requirement
traceability, interface specification, the REQUIRED alternatives analysis, ADR
conflicts, and scope coherence, ending with `DESIGN_REVIEW: PASS` or
`DESIGN_REVIEW: BLOCK <reason>`.

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
recommend revising. Tell the user to set `Status: ready` on the ones to build
AFTER the design PR merges, then run `/implement` (it builds all `ready` TDDs).

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
  this PR is the design gate: TDDs are set `ready` and built only after it lands.

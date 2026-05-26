---
name: prd-author
description: Explore a problem space and produce or update the Product Requirements Document (the "what" and "why"). Persists to docs/PRD.md. Invoke with /prd-author. Run in its own session.
disable-model-invocation: true
---

# PRD authoring

Produce or update `docs/PRD.md` — the product intent of record. The PRD is the
WHAT and WHY. It contains no HOW: no architecture, no tech choices, no
implementation detail (those belong in a TDD). Keep it the WHAT. The HOW is
`/tdd-author`'s job. Do not start designing.

Run this in its own session. If `docs/PRD.md` already exists you are UPDATING
it — read it first and preserve requirements still valid; note what changed.

## Relationship to superpowers (read first)
This skill IS the design/requirements step for throughline — it is the
governance-producing equivalent of `superpowers:brainstorming`. When the user
invokes `/prd-author`, do NOT also invoke `superpowers:brainstorming` or
`writing-plans`; this skill owns the phase and its output is the PRD of record (see
[[ADR 0001]] in `docs/adr/`). But do not redo discovery that already happened: if a
`docs/superpowers/specs/*` (or `plans/*`) file or other prior design notes exist,
READ them and fold their substance into the PRD instead of re-interviewing from
scratch. Treat `docs/superpowers/*` as transient input — never authoritative, never
relocated. The canonical record is `docs/PRD.md`.

## Process

> Tip: this phase is an interactive interview — consider toggling `/fast` for
> snappier back-and-forth. Fast mode keeps Opus, just with faster output, so it
> suits requirements/design conversation without trading quality.

1. Explore the problem space. Establish what exists, who the users are, and
   what success looks like. Ingest any prior design notes (see above).
2. **Scope check first.** If the ask is really several independent products or
   subsystems, say so before spending questions on details — help the user split it
   and PRD the first piece. A PRD should describe one coherent product/effort.
3. Interview the user with the AskUserQuestion tool. Surface scope, non-goals,
   constraints, and edge cases the user hasn't stated. Skip obvious questions; dig
   into ambiguity and conflicting goals. Prefer multiple-choice options; don't
   overwhelm — keep each question focused. Apply YAGNI: prune features the user
   doesn't actually need rather than recording them.
4. Keep interviewing until the requirements are unambiguous and testable.
5. Write `docs/PRD.md` from the template. Mark anything unresolved under Open
   questions rather than inventing an answer.

**Observable acceptance criterion (REQUIRED per new requirement).** Every NEW
requirement states an acceptance criterion phrased as an *observation of the
real artifact's surface* — what a user (human or programmatic) would see when
the change works. Examples: "running `foo --bar` prints `OK` and exits 0", "GET
/widgets/42 returns 200 with `kind: 'gizmo'`", "calling `parse('')` throws
`EmptyInputError`", "`error.log` contains `init complete` within 5s". Not
acceptable: "a test exists for X", "X is implemented", "X is supported". The
criterion belongs in the requirement line itself (a trailing "— Acceptance: …"
sentence works well). A requirement without an observable acceptance criterion
is what `/tdd-author`'s verification plan and `/implement`'s runtime-verify gate
turn into evidence; if it cannot be observed it cannot be governed. Per the
PRD's own open question, retrofitting this onto pre-existing requirements is
out of scope here — enforce it for new requirements.

## Self-review (before the PR)
After writing the PRD, reread it with fresh eyes and fix issues inline:
- **Placeholder scan** — any "TBD"/"TODO"/empty section/vague requirement? Resolve
  it or move it to Open questions.
- **Consistency** — do any requirements or goals contradict each other?
- **Scope** — still one coherent product, or did it sprawl into several?
- **Ambiguity** — could a requirement be read two different ways? Pick one and make
  it explicit; an untestable requirement is not done.
- **Missing acceptance criterion** — every NEW requirement carries an *observable
  acceptance criterion* phrased as an observation of the artifact's surface (see
  above), not "a test exists for X". A new requirement without one is not done.

Fix and move on (no re-review loop) then commit and open the PR.

## Template

```
# Product Requirements: <project or feature>

## Problem & context
## Users & goals
## Requirements        (numbered, each independently testable)
## Non-goals
## Constraints & assumptions
## Open questions
```

## Git (phase gate)
Unless the user says "skip git":
- Work on a branch `docs/prd/<change-slug>` off `main`.
- Commit `docs/PRD.md` with a message like "PRD: <summary of change>".
- Open a PR with `gh pr create --fill` (base `main`). Do NOT merge — the merge
  is the human approval gate.
- Tell the user to merge the PRD PR before running `/tdd-author`, so design
  builds on approved requirements. (The PRD commit history is also what
  `/tdd-author` diffs to scope the design work.)

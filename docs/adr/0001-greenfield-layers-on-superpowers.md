# 0001. Greenfield layers on top of superpowers; it governs, superpowers builds

Status: accepted
Date: 2026-05-25
Scope: workflow / plugin-architecture

## Context

The official `claude-plugins-official` marketplace ships **superpowers** (a full
brainstorm → plan → execute → finish development discipline), **pr-review-toolkit**,
**code-review**, and **commit-commands**. These are maintained by Anthropic, widely
used, and likely already present in repos greenfield runs in.

Greenfield independently reimplements much of that same engineering layer
(failing-test-first, worktree isolation, code review, verification, parallel
agents, branch finishing), while also providing a layer none of the official
plugins have: a persistent **PRD/TDD/ADR design-of-record** with requirement
traceability, PRD-diff-driven incremental design, ADR supersession, and phase-gate
PRs.

Two frictions surface when both are installed:

1. `superpowers:brainstorming` is a HARD-GATE skill that auto-fires before creative
   work and owns "the design step" — overlapping `/prd-author` and `/tdd-author`.
   Running both risks a double interview and an auto-chain into superpowers' own
   plan/implement flow that bypasses the PRD/TDD/ADR entirely.
2. Two parallel design-doc trees: `docs/superpowers/{specs,plans}` vs
   `docs/{PRD.md,tdd,adr}`.

## Decision

Greenfield is a thin **governance overlay** on top of the official plugins. It
defers to superpowers for discovery and to superpowers/pr-review-toolkit for
engineering, and it never fights or relocates their output.

1. **Division of labor.** Superpowers owns discovery (`brainstorming`) and the
   generic engineering primitives (TDD, worktrees, code review, verification,
   branch finishing). Greenfield owns governance: PRD/TDD/ADR as the
   design-of-record, requirement traceability, and phase-gate PRs.
2. **Ownership signal = the explicit command.** Invoking `/prd-author` or
   `/tdd-author` means greenfield owns that phase and does NOT separately invoke
   `superpowers:brainstorming` or `writing-plans`. If superpowers artifacts
   (`docs/superpowers/{specs,plans}`) or other prior design notes exist, greenfield
   **ingests** them rather than re-interviewing. When no greenfield command is
   invoked, superpowers' defaults stand.
3. **Canonical docs.** `docs/PRD.md` + `docs/tdd/` + `docs/adr/` are the governance
   design-of-record, kept at conventional top-level paths. `docs/superpowers/*` is
   transient upstream input — ingested, never authoritative, never relocated by
   greenfield.
4. **Adopt, don't reinvent.** Greenfield lifts proven inline patterns from
   brainstorming/writing-plans (an author self-review before the independent gate;
   no-placeholder / disambiguation discipline) rather than rebuilding them. It does
   NOT import writing-plans' bite-sized red→green→commit task format, because
   greenfield already enforces that at build time via `/implement` +
   `build-prompt.md` — importing it into the TDD would collapse the design/build
   split that is core to greenfield.

## Consequences

- Greenfield is non-destructive to drop into a repo already using superpowers: it
  adds governance docs and leaves `docs/superpowers/*` untouched.
- The boundary is enforced where precedence is highest: a line in the user's
  CLAUDE.md plus a "Relationship to superpowers" note in the `prd-author` and
  `tdd-author` skill bodies.
- **Out of scope, tracked separately:** further slimming greenfield's redundant
  engineering layer — `/review` + the code/security reviewer agents could defer to
  pr-review-toolkit/code-review, and `/implement`'s inline TDD/worktree wording
  could reference the superpowers skills rather than restating them.
- This ADR binds future greenfield TDDs to the governance-only scope and the
  deferral rules above.

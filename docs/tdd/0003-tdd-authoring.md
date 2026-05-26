# TDD 0003: TDD authoring & design-critique gate

Status: implemented
PRD refs: FR-7, FR-8, FR-9, FR-10, FR-11, NFR-1, NFR-2
PRD-rev: cbe3c26
ADR constraints: 0003

> Retroactively authored to match the shipped implementation.

## Approach
A `disable-model-invocation` skill, `/tdd-author`, runs once per PRD update: it
computes the delta since the last-designed PRD revision, decides the set of TDDs
(human-approved), authors them with traceability + a required alternatives analysis,
evaluates/creates ADRs, self-reviews, then runs an independent design-critique gate
(a separate-model subagent) before opening the phase-gate design PR.

## Components & interfaces
- `skills/tdd-author/SKILL.md` — the 9-step process, the TDD template, the
  architecture/dependency dispositions, the no-placeholder rule, and the
  superpowers-boundary note.
- `agents/design-reviewer.md` — `model: sonnet`, read-only; checks requirement
  traceability, interface specification, the REQUIRED alternatives analysis, ADR
  conflicts, concreteness/naming consistency, and scope; ends with `DESIGN_REVIEW:
  PASS|BLOCK`.
- Reads: `docs/PRD.md`, `git diff <PRD-rev>`, existing `docs/tdd/*.md`,
  `docs/tdd/BLOCKERS.md`, `docs/adr/INDEX.md` (+ accepted ADR bodies).

## Data & state
- `docs/tdd/NNNN-<slug>.md` (Status: draft; `PRD refs`, `PRD-rev`, `ADR constraints`,
  traceability table, dependencies-considered, etc.).
- Promoted ADRs (via `/adr-new`), committed together with the TDD set.
- Git branch `docs/design/<slug>` + a design PR carrying the critique verdict.

## Sequencing / implementation plan
Determine PRD delta (from latest TDD's `PRD-rev`) → inventory coverage + read
BLOCKERS.md → decide TDD set and present the plan for approval → load accepted ADRs →
author the approved set (challenge the PRD; require an alternatives analysis per new
dependency) → ADR evaluation (+ `/adr-new`) → author self-review → independent
design-critique gate (fix/​re-run until PASS or record a waiver) → commit TDDs+ADRs
and open the design PR; do NOT merge.

## Failure modes & edge cases
- Uncommitted PRD → ask to commit first (well-defined delta).
- New dependency without alternatives analysis → design-critique BLOCK.
- Untraced requirement / under-specified interface / ADR conflict → BLOCK.
- Design-time blocker from `/implement` (BLOCKERS.md) → must be resolved this pass.

## Requirement traceability
- FR-7 → delta computation (PRD-rev diff) + coverage map + plan-for-approval.
- FR-8 → TDD template: traceability table, dependencies-considered, no-placeholder.
  Verification aspects of FR-8 (the `## Verification plan` template section +
  authoring step + no-placeholder coverage) now covered by TDD 0007.
- FR-9 → ADR evaluation + `/adr-new` invocation; only `accepted` ADRs bind.
- FR-10 → author self-review + `design-reviewer` gate (fresh context, diff model).
  Verification aspects of FR-10 (BLOCK on missing/non-actionable verification
  plan) now covered by TDD 0007.
- FR-11 → `docs/design/<slug>` branch, TDDs+ADRs together, verdict in PR, no merge.
- NFR-1 → the human merge of the design PR is the design gate.
- NFR-2 → the `design-reviewer` runs in an isolated subagent context.

## Dependencies considered
No new runtime dependency. The `design-reviewer` is a throughline agent (kept — it
reviews *design docs*, which pr-review-toolkit does not; alternative "delegate design
critique to a code reviewer" rejected: code reviewers review code, not PRD/TDD/ADRs).

## PRD conflicts surfaced (and resolution)
None.

## Decisions to promote (ADR candidates)
None new; respects ADR 0003.

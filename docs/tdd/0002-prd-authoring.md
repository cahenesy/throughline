# TDD 0002: PRD authoring

Status: implemented
PRD refs: FR-4, FR-5, FR-6, NFR-1
PRD-rev: cbe3c26
ADR constraints: 0003

> Retroactively authored to match the shipped implementation.

## Approach
A `disable-model-invocation` skill, `/prd-author`, drives an interactive interview
that produces/updates `docs/PRD.md` — strictly the WHAT/WHY — then opens a phase-gate
PRD PR it never merges. It is the design step for throughline (ADR 0003), so it does
not also fire `superpowers:brainstorming`; it ingests any existing
`docs/superpowers/*` artifacts instead of re-interviewing.

## Components & interfaces
- `skills/prd-author/SKILL.md` — process (explore → scope check → interview →
  self-review → write → PR), the PRD template (Problem/Users/Requirements/Non-goals/
  Constraints/Open questions), a "Relationship to superpowers" boundary note, and a
  `/fast` tip for the interview.
- Interface in: the user (via AskUserQuestion) + any prior `docs/superpowers/{specs,
  plans}`. Interface out: `docs/PRD.md` + a PR on `docs/prd/<slug>`.

## Data & state
- `docs/PRD.md` — the canonical product intent of record (numbered FR/NFR, testable).
- Git branch `docs/prd/<slug>` + a PR (the approval gate / diff anchor).

## Sequencing / implementation plan
Explore + ingest prior notes → scope-decomposition check → interview (multiple-choice
preferred, YAGNI-pruned) until requirements are unambiguous/testable → write the PRD
from the template → inline self-review (placeholder/consistency/scope/ambiguity) →
commit to `docs/prd/<slug>` and open a PR; do NOT merge.

## Failure modes & edge cases
- Multi-product ask → split before detailing (scope check).
- Unresolved item → recorded under Open questions, not invented.
- Existing PRD → update in place, preserve still-valid requirements, note changes.

## Requirement traceability
- FR-4 → PRD-of-record output + WHAT/WHY-only template.
- FR-5 → scope-decomposition check, YAGNI, inline self-review. Verification
  aspects of FR-5 (observable-acceptance-criterion enforcement + the
  missing-acceptance-criterion self-review bullet) now covered by TDD 0007.
- FR-6 → `docs/prd/<slug>` branch + PR, never auto-merge.
- NFR-1 → the human merge of the PRD PR is the requirements gate.

## Dependencies considered
No new runtime dependency. Relies on `superpowers` (already a declared plugin
dependency, ADR 0003) only as an optional input source (ingest-if-present); it is not
required for `/prd-author` to function.

## PRD conflicts surfaced (and resolution)
None.

## Decisions to promote (ADR candidates)
None new; respects ADR 0003 (governance ownership; ingest-not-relocate).

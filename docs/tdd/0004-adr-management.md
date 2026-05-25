# TDD 0004: ADR management

Status: implemented
PRD refs: FR-12
PRD-rev: cbe3c26
ADR constraints: none

> Retroactively authored to match the shipped implementation.

## Approach
A model-invocable skill, `/adr-new`, records durable architectural decisions to
`docs/adr/NNNN-*` with strict append-only-on-substance semantics and maintains the
index. It is model-invocable (no `disable-model-invocation`) specifically so
`/tdd-author` can call it at close-out; the user can also invoke it directly.

## Components & interfaces
- `skills/adr-new/SKILL.md` — the rules (append-only on substance; status
  `proposed|accepted|superseded by NNNN`; supersede-don't-edit; next zero-padded
  number), the ADR template, and the `INDEX.md` format.
- Writes only: `docs/adr/NNNN-<slug>.md` + `docs/adr/INDEX.md`. Does not commit/branch
  (the design phase commits ADRs with the TDD set).

## Data & state
- `docs/adr/NNNN-*.md` — Context/Decision/Consequences, Scope, optional `Supersedes`.
- `docs/adr/INDEX.md` — one row per ADR (#, Title, Status, Scope); only `accepted`
  ADRs bind new TDDs.

## Sequencing / implementation plan
Assign next number → write the ADR from the template → to reverse a prior decision,
create a NEW ADR with `Supersedes: NNNN` capturing the new decision in full and flip
ONLY the old ADR's status line → update `INDEX.md` so both rows reflect the new state.

## Failure modes & edge cases
- Substantive change to an `accepted` ADR → forbidden; must supersede instead
  (editorial touch-ups — typos, links, status flips — are allowed).
- Index drift → both the new and superseded rows are updated together.

## Requirement traceability
- FR-12 → append-only ADRs with status-gated supersession + maintained `INDEX.md`.

## Dependencies considered
No new dependency (markdown + git only).

## PRD conflicts surfaced (and resolution)
None.

## Decisions to promote (ADR candidates)
N/A — this unit IS the ADR mechanism. (It has been exercised by ADRs 0001→0002→0003,
which demonstrate the supersession discipline.)

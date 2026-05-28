# TDD 9005: untraced FR

Status: draft
PRD refs: FR-1, FR-2, FR-3
PRD-rev: deadbee
ADR constraints: 0003

## Approach

This TDD declares three FRs in the frontmatter but the traceability table
only covers two of them. The lint must flag the missing FR-3.

## Verification plan

Observe the traceability lint emits exactly one major finding naming FR-3.

## Requirement traceability

| PRD | Design element |
|---|---|
| FR-1 | component a |
| FR-2 | component b |

## Dependencies considered

None.

# TDD 9001: clean fixture

Status: draft
PRD refs: FR-99
PRD-rev: deadbee
ADR constraints: 0003

## Approach

A clean fixture used by tdd-lint tests. Nothing surprising here.

## Components & interfaces

A single component.

## Verification plan

Observe `scripts/lib/tdd-lint.sh` exit code is 0 and stdout is empty.

## Requirement traceability

| PRD | Design element |
|---|---|
| FR-99 | the only component |

## Dependencies considered

None.

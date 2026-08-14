# 0011. Gate verdicts are on-disk artifacts, not transcript parses

Status: accepted
Date: 2026-08-14
Scope: workflow / gate-architecture / verification-integrity

## Context

ADR 0006 required gate decisions to rest on verifiable artifacts, not
author self-report. The implementation then treated assistant-authored
stream-json sentinels (`BATCH_RESULT`, `STEP_COMMIT`, `THROUGHLINE_SESSION`)
as those artifacts. That tied flip authority to a Claude `claude -p`
coprocess and was spoofable by file contents the worker read (TDD 0056).
FR-82 forbids transcript text as flip authority.

## Decision

Each of the four FR-15 gates records its outcome as a file under
`docs/tdd/.implement-logs/<run-id>/<slug>/`:

- `test-first.json`
- `ci-checks.json`
- `runtime-verify.json`
- `review.json`

Each file is a JSON object `{ "gate": "<name>", "status": "PASS"|"FAIL"|"BLOCKED"|"SKIP", "evidence": "<string>" }`.
A TDD flips to `implemented` only when all four files exist and `status` is
`PASS`, except `runtime-verify.json` may be `SKIP` with a non-empty
`evidence` justification (FR-25).

A string that appears only in a worker transcript, a stream-json event, or
the body of a file the worker read is not flip authority.

## Consequences

- ADR 0006 remains accepted; this ADR specifies the artifact *shape*.
- `scripts/implement.sh` stream-json parsing is not the flip channel.
- Resume (FR-40) reads these files plus `run-record` to decide which gate
  to run next.
- Eval suites that only assert sentinel-in-transcript behavior are obsolete
  with the coprocess (TDD 0063).

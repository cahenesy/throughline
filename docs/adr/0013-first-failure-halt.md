# 0013. Halt on gate failure after transient retry; no in-invocation rework

Status: accepted
Date: 2026-08-14
Scope: workflow / gate-architecture / halt-semantics
Supersedes: 0007

## Context

ADR 0007 replaced first-failure halt with bounded in-invocation rework plus
structural escalation. That loop required a throughline-owned supervisor
(per-step review, attempt budgets, scope caps). FR-56–FR-62 and FR-65–FR-68
are retired. FR-16 is halt-on-failure again. Transient retry (FR-42) stays.

## Decision

A gate that records `FAIL` or `BLOCKED` (after FR-42 transient retries
exhaust) halts that TDD. `/build-tdds` does not automatically author a fix
in the same invocation. The human re-runs `/build-tdds` or revises the TDD
via `/tdd-author`.

Structural findings (FR-67) still write `docs/tdd/BLOCKERS.md` and
`BLOCKED` — they do not expand declared scope.

Recoverable pauses (ratelimit, transient, usage-limit) remain `paused`
(FR-41), distinct from `FAIL`.

ADR 0008's "rework uses the build model" consequence is vacated because
there is no in-invocation rework. ADR 0009 (tier pairing for build vs
review) remains accepted.

## Consequences

- Sequential mode still marks downstream TDDs `BLOCKED` when an earlier TDD
  fails (FR-16).
- TDDs 0019–0021, 0041, 0043 describe a machine that is no longer required.
- Review findings may still be graded; only `review.json` `PASS`/`FAIL`
  flips (FR-15(d)).

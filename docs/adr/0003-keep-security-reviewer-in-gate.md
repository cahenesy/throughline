# 0003. Keep security-reviewer in the gate; delegate build + code-review (spike outcome)

Status: superseded by 0010
Date: 2026-05-25
Scope: workflow / plugin-architecture
Supersedes: 0002

## Context

ADR 0002 set the Phase-2 plan to delegate `/implement`'s gates to the official
plugins and **delete** throughline's `code-reviewer`, `security-reviewer`, and
`test-writer` agents — explicitly gated on a verification spike. The spike (a
detached `claude -p` probing each delegation, with the actual tool-call events
inspected, not just self-report) found:

- `superpowers:test-driven-development` — invocable headless. ✓
- `pr-review-toolkit:code-reviewer` (and the full pr-review-toolkit agent set) —
  dispatchable headless via the Task tool. ✓
- built-in `/security-review` — invocable, **but** its bundled setup runs
  `git log … origin/HEAD…`, which requires an `origin` remote; it errors in a repo
  without one (`--skip-git`/local builds, and it is fragile in detached worktrees),
  and in the probe it did **not** flag an obvious command injection.

## Decision

Carry ADR 0002 forward in full, with **one correction** to its Phase-2 deletions:

- **Delegate the build** to `superpowers:test-driven-development` → delete the
  `test-writer` agent.
- **Delegate code review** to pr-review-toolkit (`code-reviewer` +
  `silent-failure-hunter`) → delete throughline's `code-reviewer` agent.
- **Keep throughline's `security-reviewer`** in the automated `/implement` gate.
  The built-in `/security-review` is too fragile for the headless,
  possibly-remoteless worktree gate; throughline's 11-line agent is deterministic
  and robust. Use the built-in `/security-review` on-demand.

## Consequences

- `/implement`'s review gate now dispatches `pr-review-toolkit:code-reviewer` +
  `pr-review-toolkit:silent-failure-hunter` + `throughline:security-reviewer`; the
  build follows superpowers' TDD discipline (the runner still mechanically gates the
  `test(failing):`-first commit, so the discipline is enforced regardless).
- Throughline keeps `security-reviewer` + `design-reviewer`; removes `code-reviewer`
  + `test-writer` (`explore` was removed in Phase 1).
- Supersedes 0002. Everything else in 0002 — depend on the official plugins,
  governance ownership, canonical `docs/{PRD,tdd,adr}` — is carried forward unchanged.

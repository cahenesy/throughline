# 0010. Dual-harness overlay: shared skills and mechanical core; optional delegates

Status: accepted
Date: 2026-08-14
Scope: workflow / plugin-architecture
Supersedes: 0003

## Context

ADR 0003 made Superpowers and pr-review-toolkit hard, auto-installed
dependencies on the Claude official marketplace, and required the review
gate to fan out to three named agents. That cannot be the install or flip
contract on Grok Build (no Claude-marketplace deps; subagents cannot nest).
FR-22 and FR-83 now say those plugins are optional. FR-79/FR-80 require the
same governance surface on Claude Code and Grok Build.

## Decision

throughline is a governance overlay for Claude Code and Grok Build. Skills,
mechanical bash, and design-of-record paths are shared. How a worker is
started is harness-native and is not required to match.

Engineering plugins (Superpowers, pr-review-toolkit, harness built-ins) are
used when present and are not required to install throughline or to flip a
TDD. `throughline:security-reviewer` remains a file the single reviewer
*may* read as extra criteria; it is not a required nested agent.

The repo ships both `.claude-plugin/` and `.grok-plugin/` marketplace
indexes. Canonical docs stay `docs/{PRD.md,tdd/,adr/}`.
`docs/superpowers/*` stays transient input.

## Consequences

- ADR 0003's hard-dependency and required three-agent fan-out are
  superseded. Its "delegate build TDD and code review when those plugins
  exist" posture is carried forward.
- New TDDs must not declare `claude-plugins-official` as an install
  requirement.
- Review flip authority is one independent different-model artifact
  (ADR 0011), not a nested Task fan-out.

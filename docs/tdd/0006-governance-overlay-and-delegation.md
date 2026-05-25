# TDD 0006: Governance overlay & delegation

Status: implemented
PRD refs: FR-22, NFR-2, NFR-5
PRD-rev: cbe3c26
ADR constraints: 0003

> Retroactively authored to match the shipped implementation.

## Approach
throughline is packaged as a thin governance overlay that *depends on* the official
plugins and *delegates* discovery + generic engineering to them, keeping only the
governance layer and the orchestration that has no official equivalent. The
dependency is declared so installs pull the companions automatically; canonical
design docs live under `docs/`, and superpowers' artifacts are treated as transient
input.

## Components & interfaces
- `.claude-plugin/plugin.json` — `dependencies: [{superpowers, claude-plugins-
  official}, {pr-review-toolkit, claude-plugins-official}]`.
- `.claude-plugin/marketplace.json` — `allowCrossMarketplaceDependenciesOn:
  ["claude-plugins-official"]` (required for cross-marketplace deps) + the mirrored
  plugin entry.
- The skills' "Relationship to superpowers" boundary notes (prd-author, tdd-author):
  the explicit command owns the design step; ingest `docs/superpowers/*` if present.
- `docs/{PRD.md, tdd/, adr/}` as the canonical design-of-record; `docs/README.md`
  documents canonical-vs-transient.

## Data & state
- The dependency + allowlist declarations (resolved at install time).
- The canonical doc tree vs the ingested-only `docs/superpowers/*`.

## Sequencing / implementation plan
Declare the cross-marketplace dependencies + allowlist → delegate engineering in the
gates (TDD 0005) and on-demand review to `/code-review` + `/review-pr` → encode the
boundary (explicit command = design step; no double-invoke of brainstorming) in the
skills → keep scripts/skills running from the plugin cache (not vendored) so updates
reach every project.

## Failure modes & edge cases
- User lacks the `claude-plugins-official` marketplace → throughline loads with a
  `dependency-unsatisfied` error until they add it (documented in README); deps
  auto-resolve only once that marketplace is present.
- Claude Code < 2.1.110 → cross-marketplace version resolution unsupported.
- A repo already using superpowers → non-disruptive: `docs/superpowers/*` is ingested,
  never relocated.

## Requirement traceability
- FR-22 → declared dependencies + allowlist; delegation of discovery/engineering;
  canonical docs + ingest-not-relocate.
- NFR-2 → autonomous work in subagents/detached processes; one-fresh-session-per-command.
- NFR-5 → scripts/skills served from the plugin cache (no vendored drift).

## Dependencies considered
- **`superpowers` + `pr-review-toolkit`** (chosen, hard dependencies). Rejected:
  staying self-contained (ADR 0001) — reversed by ADR 0002 because the official
  plugins are better maintained and the overlap was real. Rejected: declaring them
  *recommended-not-required* — the `dependencies` mechanism is auto-install, with no
  "optional" tier, and "layer on top" implies a hard dependency.

## PRD conflicts surfaced (and resolution)
None.

## Decisions to promote (ADR candidates)
Already promoted: ADR 0001 (layer on top), ADR 0002 (depend + delegate), ADR 0003
(spike correction: keep security-reviewer). This TDD implements ADR 0003's accepted state.

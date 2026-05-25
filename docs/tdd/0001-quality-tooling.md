# TDD 0001: Project quality tooling (bootstrap + format/lint hook)

Status: implemented
PRD refs: FR-1, FR-2, FR-3, FR-21
PRD-rev: cbe3c26
ADR constraints: none

> Retroactively authored to match the shipped implementation.

## Approach
A single `disable-model-invocation` skill, `/bootstrap-project`, sets up a project's
linter/formatter/test framework and the design-doc scaffold; a `format-and-lint`
PostToolUse hook then enforces formatting/linting on every edit. The skill is
prescriptive about greenfield vs brownfield so it never forces tooling onto an
existing repo silently.

## Components & interfaces
- `skills/bootstrap-project/SKILL.md` — language detection; a per-language default
  table (JS/TS prettier+eslint+vitest; Python ruff+pytest; Rust rustfmt+clippy+cargo
  test; Go gofmt+golangci-lint+go test); greenfield vs brownfield branches; the
  design-doc scaffold list; a greenfield init checklist ending in `git init` on `main`.
- `hooks/hooks.json` — registers `format-and-lint.sh` as a `PostToolUse` hook.
- `hooks/format-and-lint.sh` — formats the edited file, then runs the project's
  linter; no-ops when no linter is configured; debounced via a tmp marker
  (`THROUGHLINE_LINT_DEBOUNCE`, default 30s); surfaces lint failures back into the
  session rather than reverting the edit.

## Data & state
- Config files the skill writes (eslint/prettier/ruff/etc. minimal configs).
- `docs/{PRD.md, adr/INDEX.md, tdd/, README.md}` scaffold.
- Debounce marker file under `$TMPDIR` keyed by edited-file id.

## Sequencing / implementation plan
Detect language → (greenfield) install+configure formatter/linter+test framework and
write one trivial passing test → confirm the hook is active → scaffold `docs/` →
`git init` on `main`. (Brownfield) reuse existing tooling; if absent, flag and ask.

## Failure modes & edge cases
- Brownfield repo with no linter/tests → do NOT silently install; flag and ask.
- Ambiguous language → ask.
- Hook with no configured linter → no-op (never forces tooling).
- Lint failure → returned into the session for root-cause fix; edit stays on disk.

## Requirement traceability
- FR-1 → default-tooling table + install/configure steps.
- FR-2 → greenfield/brownfield branches (install+trivial test vs flag-and-ask).
- FR-3 → design-doc scaffold list + `git init` on `main`.
- FR-21 → `hooks/hooks.json` + `format-and-lint.sh` (format→lint, no-op, debounce).

## Dependencies considered
No new runtime dependencies introduced by this unit. Tooling installed is the
project's own (prettier/eslint/ruff/clippy/golangci-lint), chosen as the de-facto
ecosystem defaults; alternatives (e.g. biome for JS, black+flake8 for Python) were
left as user overrides ("override only if the user objects") rather than defaults.

## PRD conflicts surfaced (and resolution)
None.

## Decisions to promote (ADR candidates)
None (no cross-cutting decision beyond the governance ADRs 0001–0003).

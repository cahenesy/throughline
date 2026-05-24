---
name: bootstrap-project
description: Set up a project's toolchain (linter, formatter, test framework) and verify it end-to-end when starting work on a greenfield or brownfield project. Invoke with /bootstrap-project. Say "skip setup" to bypass.
disable-model-invocation: true
---

# Project setup

Run when starting work on a project. Determine whether it is **greenfield**
(empty: no source files, fresh or absent package-manager init) or
**brownfield** (existing code), then follow the matching path. If the user
says "skip setup", stop and do nothing.

First: detect the primary language. If ambiguous, ask.

## Default tooling (override only if the user objects)

| Language | Formatter + Linter      | Test framework      |
|----------|-------------------------|---------------------|
| JS/TS    | prettier + eslint       | vitest              |
| Python   | ruff (format + check)   | pytest              |
| Rust     | rustfmt + clippy        | built-in cargo test |
| Go       | gofmt + golangci-lint   | built-in go test    |

## Linting and formatting

A `format-and-lint` PostToolUse hook ships with this plugin and runs
automatically after edits **when a linter is configured for the project** —
it no-ops otherwise, so it never forces tooling onto a repo. Your job here is
to make sure a linter/formatter is actually configured, per these rules:

- **Greenfield:** install the default formatter + linter for the language and
  create minimal config files.
- **Brownfield, tooling already configured:** use what is there; do not swap
  it out.
- **Brownfield, no linter/formatter:** do NOT silently install one. Point out
  that the repo has no configured linter/formatter and ask whether to add the
  default before proceeding.

How the hook behaves: it formats the edited file, then runs the linter. On a
lint failure it returns the error into the session so the fix happens at the
root cause. The edit is already written to disk — the hook surfaces the
failure for correction rather than reverting it.

## Unit testing

- **Greenfield:** install the default test framework and write one trivial
  passing test, then run it to confirm the setup works end-to-end.
- **Brownfield with existing tests:** use the framework already in use. New
  code must ship with new tests; modified code must have its tests updated.
- **Brownfield with no tests:** stop and explicitly flag that the codebase has
  no unit tests. Ask whether to add a framework and backfill tests for
  existing code before proceeding. Do not silently introduce a framework.

`/implement` gates every `ready -> implemented` flip on `scripts/verify.sh`,
which runs the test suite + typecheck. That gate needs a working test/typecheck
command (auto-detected, or set via `VERIFY_TEST_CMD` / `VERIFY_TYPECHECK_CMD`);
a project with neither cannot pass the gate without `VERIFY_ALLOW_EMPTY=1`.

## Design-doc scaffold

Create the structure the PRD/TDD/ADR pipeline expects, if absent:

- `docs/PRD.md` — a stub with the section headers (`/prd-author` fills it).
- `docs/adr/INDEX.md` — an empty index with its header row and the note that
  only `accepted` ADRs are binding for new TDDs.
- `docs/tdd/` — empty directory for Technical Design Docs.

## Greenfield initialization checklist

When the project is empty:

1. Detect or ask the primary language.
2. Install + configure the default formatter and linter; create minimal config.
3. Install the default test framework, then write and run one trivial passing
   test.
4. Confirm the `format-and-lint` hook is active (it ships with this plugin).
5. Create the design-doc scaffold above.
6. Initialize git and make an initial commit on `main` (the integration branch
   that phase-gate PRs merge into) once setup is complete.
7. Report what was installed, configured, and scaffolded.

After this, the design-doc pipeline is: `/prd-author` (the what) →
`/tdd-author` (the how) → `/adr-new` (durable decisions), each in its own
fresh session.

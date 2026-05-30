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

## Step 0 — read the bootstrap marker (before any work)

Before detecting the language or touching anything, check whether this repo was
already bootstrapped. Source the helpers from the plugin and read the committed
repo marker (from the repo root):

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/repo-id.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/markers.sh"
marker="$(tl_repo_marker_read)"   # the marker JSON, or "{}" if absent/malformed
applied="$(printf '%s\n' "$marker" | sed -n 's/.*"plugin_version_applied"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
language="$(printf '%s\n' "$marker" | sed -n 's/.*"language"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
```

These reads use `sed`, not `jq`: FR-31's re-run short-circuit must work on
machines without `jq` (only the post-update hook's local notice is `jq`-gated).
The marker's string fields are written one-per-line by `tl_repo_marker_write`,
so a line-oriented `sed` extraction is exact.

If `$applied` is **non-empty**, this repo is already bootstrapped. Print exactly
one line:

```
already bootstrapped at <applied> (language: <language>)
```

then **short-circuit**: do NOT install anything, do NOT re-run the
greenfield/brownfield flow, and do NOT rewrite the marker — it must stay
byte-identical on a re-run. Re-apply ONLY the cheap, idempotent steps:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/gitignore.sh"
tl_gitignore_add_line "docs/tdd/.implement-logs/"
```

and re-create only the scaffold files (below) that are now **missing** — leave
existing ones untouched: `docs/PRD.md` (stub with section headers),
`docs/adr/INDEX.md` (empty index + header row + the "only `accepted` ADRs bind"
note), the `docs/tdd/` directory, and `docs/README.md` (the
canonical-vs-transient note). Then stop.

If `$applied` is empty (no marker), or the marker is malformed
(`tl_repo_marker_read` returns `{}`), proceed with the normal flow below.

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

`/implement` gates every TDD's flip to `implemented` on the plugin's verify
gate, which runs the test suite + typecheck + project linter (eslint, ruff,
clippy `-D warnings`, golangci-lint). That gate needs a working test/typecheck
command (auto-detected, or set via `CI_CHECKS_TEST_CMD` / `CI_CHECKS_TYPECHECK_CMD` /
`CI_CHECKS_LINT_CMD`); a project with no test or typecheck cannot pass the gate
without `CI_CHECKS_ALLOW_EMPTY=1` (lint alone is additive strictness, not
behavioral verification, so it does not satisfy the gate on its own).

## Design-doc scaffold

Create the structure the PRD/TDD/ADR pipeline expects, if absent:

- `docs/PRD.md` — a stub with the section headers (`/prd-author` fills it).
- `docs/adr/INDEX.md` — an empty index with its header row and the note that
  only `accepted` ADRs are binding for new TDDs.
- `docs/tdd/` — empty directory for Technical Design Docs.
- `docs/README.md` — a short note on which docs are canonical, so neither you nor a
  teammate confuses throughline's records with superpowers' scratch: `docs/PRD.md` +
  `docs/tdd/` + `docs/adr/` are the **canonical design-of-record**; anything under
  `docs/superpowers/` (specs/plans from `superpowers:brainstorming`/`writing-plans`)
  is **transient input** that throughline ingests but never treats as authoritative
  or relocates. Leave any existing `docs/superpowers/` content untouched.

## Brownfield completion checklist

A brownfield run touches less than a greenfield one, but it still ends the same
way. After you have resolved the linter/formatter and test-framework questions
above and created any missing design-doc scaffold:

1. Record the bootstrap markers + `.gitignore` entry — run the **On completion —
   record the bootstrap markers** step below. This is **not** greenfield-only:
   record the marker even when you installed nothing (so re-runs short-circuit
   at Step 0 and the reconcile hook can track the version). Set `<steps-csv>` to
   whatever you actually applied — often just `scaffold`, or an empty CSV if the
   repo already had everything.
2. Commit the marker and `.gitignore` change with your other edits (do not
   `git init` an existing repo).
3. Report what you used, configured, and scaffolded.

## Greenfield initialization checklist

When the project is empty:

1. Detect or ask the primary language.
2. Install + configure the default formatter and linter; create minimal config.
3. Install the default test framework, then write and run one trivial passing
   test.
4. Confirm the `format-and-lint` hook is active (it ships with this plugin).
5. Create the design-doc scaffold above.
6. Record the bootstrap markers + `.gitignore` entry — see **On completion —
   record the bootstrap markers** below. Do this *before* the initial commit so
   the marker and `.gitignore` are part of it.
7. Initialize git and make an initial commit on `main` (the integration branch
   that phase-gate PRs merge into) once setup is complete.
8. Report what was installed, configured, and scaffolded.

## On completion — record the bootstrap markers

After **any** successful bootstrap run — greenfield or brownfield, and whether
or not it installed or changed anything — record both markers so re-runs
short-circuit at Step 0 and the post-update reconcile hook can track the
version. A brownfield repo that already had its tooling still completes a
bootstrap: record the marker with whatever `repo_steps_applied` were actually
performed (often just `scaffold`, sometimes an empty CSV). Run, from the repo
root:

```bash
# The marker steps are NOT optional, so a helper that cannot be sourced must
# abort loudly rather than turn the write calls below into silent
# "command not found" no-ops. Bail (with no marker written) if any source fails.
for _lib in gitignore.sh repo-id.sh markers.sh; do
  source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/$_lib" || {
    echo "bootstrap: could not source scripts/lib/$_lib from \${CLAUDE_PLUGIN_ROOT} — markers NOT recorded; fix the plugin path and re-run" >&2
    return 1 2>/dev/null || exit 1
  }
done
ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" | head -n1)"

# FR-32: ignore throughline's per-run artifacts (idempotent, byte-stable).
tl_gitignore_add_line "docs/tdd/.implement-logs/"

# Guard: a marker with an empty plugin_version_applied is silent corruption —
# Step 0 reads the field as empty and never short-circuits, so re-runs
# re-bootstrap forever. If the version could not be read, write NO marker and
# report it rather than poison the short-circuit.
if [ -z "$ver" ]; then
  echo "bootstrap: could not read the plugin version from ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json — repo marker NOT written" >&2
else
  # FR-31: committed repo marker. Replace <language> with the detected language
  # and <steps-csv> with the subset of
  # {scaffold,gitignore,linter_config,test_framework_config,git_init}
  # you actually applied this run (comma-separated, no spaces).
  tl_repo_marker_write "$ver" "<language>" "<steps-csv>"

  # FR-33: per-developer local marker (records that deps were installed here).
  # The '|| true' is required: when ${CLAUDE_PLUGIN_DATA} is unwritable the
  # local write fails, but the committed repo marker above is the source of
  # truth and bootstrap must still complete (see TDD 0009 failure modes).
  tl_local_marker_write "$ver" deps_installed || true
fi
```

Commit `docs/.throughline-bootstrap.json` and the `.gitignore` change with the
rest of the bootstrap. The local marker lives outside the repo (under
`${CLAUDE_PLUGIN_DATA}`) and is never committed; if that path is unwritable,
`tl_local_marker_write` warns and returns non-zero — continue anyway, the
committed repo marker is the source of truth for re-run short-circuiting.

After this, the design-doc pipeline is: `/prd-author` (the what) →
`/tdd-author` (the how) → `/adr-new` (durable decisions), each in its own
fresh session.

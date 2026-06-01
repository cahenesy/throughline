# Contributing to throughline

Thanks for your interest. throughline is unusual to contribute to in one
specific way: **it is built with itself.** Every feature in this repo went
through the same PRD → TDD → ADR → gated-build pipeline that the plugin
provides. Contributions follow that same loop — which means contributing *is*
the product demo.

## The contribution loop (self-hosting)

If you have throughline installed, you contribute the same way the maintainer
does:

1. **Requirements** — `/prd-author` in a fresh session. Describe the capability
   you want to add; the interview produces an update to `docs/PRD.md` with an
   observable acceptance criterion per new requirement, and opens a PRD PR.
2. **Design** — after the PRD PR merges, `/tdd-author` in a fresh session. It
   diffs the PRD, proposes the TDD set, runs the mechanical pre-pass + the
   independent design-critique gate, and opens a design PR (TDDs + any ADRs).
3. **Build** — after the design PR merges, `/implement` in a fresh session. The
   detached runner builds failing-test-first in an isolated worktree, passes
   the four gates (test-first, ci-checks, runtime-verify, cross-model review),
   and opens one feature PR per TDD.

Maintainer review happens at each PR gate, exactly as the workflow intends.

**Don't want to use the pipeline?** That's fine for small fixes — see below.

## Small fixes (no pipeline needed)

Typo fixes, doc corrections, test additions, and small bug fixes can be normal
PRs against `master`:

- Branch from `master`, keep the diff focused.
- Run the eval suite before opening the PR:
  ```
  bash tests/implement-gate.test.sh
  ```
  (It aggregates all the per-feature evals; everything must pass.)
- If you change any `scripts/` or `skills/` behavior, bump the version in
  `.claude-plugin/plugin.json` (functional changes bump; doc-only changes
  don't).

## What makes a good contribution here

- **Run reports from real projects.** The most valuable thing you can give
  this project is evidence: a (sanitized) `report.md` from running `/implement`
  on your own repo, what the reviewer caught, where it halted, what felt wrong.
  Open a [Discussion](../../discussions) with it.
- **Recurring-finding patterns.** If the review gate keeps flagging the same
  class of issue on your builds, that's input to the build-norms work
  (FR-74) — share the pattern tags from your run-state records.
- **Design gaps.** If `/implement` halted with a design blocker
  (`docs/tdd/BLOCKERS.md` entry) that you think the TDD pipeline should have
  caught earlier, that's a design-critique-gate gap worth an Issue.
- **Bug reports with run-state attached.** The run-state record
  (`docs/tdd/.implement-logs/<ts>/state.d/`) is designed to make every halt
  reproducible from artifacts alone. Attach it (sanitized) to bug reports.

## What we'll push back on

- **Re-implementing what the official plugins already do.** throughline
  delegates generic engineering (TDD mechanics, code review, worktrees) to
  `superpowers` and `pr-review-toolkit` by design (ADR 0003). PRs that inline
  that functionality will be declined.
- **New gates or enforcement mechanisms that bypass the prompt-level
  philosophy.** ADR 0005: gate scope is enforced by prompt + downstream
  detection, not sandboxing. Read `docs/adr/` before proposing architecture
  changes.
- **Features without an observable acceptance criterion.** If you can't state
  what a user would observe when it works, it isn't ready for a PR — that rule
  applies to us too.

## Project structure

| Path | What it is |
|---|---|
| `docs/PRD.md` | Product requirements — the WHAT and WHY of every feature |
| `docs/tdd/` | Technical design docs — one per built feature, the design-of-record |
| `docs/adr/` | Architecture decision records — binding constraints on all designs |
| `skills/` | The user-facing slash commands (`/prd-author`, `/tdd-author`, `/implement`, …) |
| `scripts/` | The detached runner, gates, prompts, and shared bash libraries |
| `hooks/` | Format/lint and session-reconcile hooks |
| `tests/` | The eval suites (run via `tests/implement-gate.test.sh`) |

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).

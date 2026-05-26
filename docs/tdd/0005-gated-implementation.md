# TDD 0005: Gated unattended implementation

Status: implemented
PRD refs: FR-13, FR-14, FR-15, FR-16, FR-17, FR-18, FR-19, FR-20, NFR-1, NFR-3, NFR-4
PRD-rev: cbe3c26
ADR constraints: 0003

> Retroactively authored to match the shipped implementation.

## Approach
`/implement` turns merged TDDs into code without trusting self-reported success. A
detached shell runner builds each TDD in an isolated git worktree via a fresh
`claude -p`, then flips it to `implemented` only after three independent gates pass.
The design-PR merge (not a manual flag) is the build trigger. Engineering is
delegated to the official plugins (ADR 0003); throughline owns the orchestration and
the mechanical gates.

## Components & interfaces
- `skills/implement/SKILL.md` — the `disable-model-invocation` entry point; confirms
  the queue + mode, then launches the runner detached (`nohup … &`).
- `scripts/implement.sh` — the runner: integration-branch detection, queue selection,
  worktree creation, the three gates, status flip, PR creation, report + merge plan,
  resume logic, and the single-run lock.
- `scripts/build-prompt.md` — per-TDD build prompt; delegates failing-test-first to
  `superpowers:test-driven-development`; uses the built-in `Explore` subagent.
- `scripts/review-prompt.md` — independent review prompt; fans out to
  `pr-review-toolkit:code-reviewer` + `silent-failure-hunter` +
  `throughline:security-reviewer`; ends `REVIEW_RESULT: PASS|BLOCK`.
- `scripts/verify.sh` — mechanical gate: tests + typecheck + linter, package-manager
  aware, auto-detected or via `VERIFY_*` env.
- `agents/security-reviewer.md` — kept in-gate (ADR 0003).

## Data & state
- Build branches (`build/<change>/<slug>` stacked, or `feat/<slug>` parallel, or one
  `build/<change>`); the `Status: implemented` flip is committed on the build branch.
- `docs/tdd/.implement-logs/<ts>/{report.md, *.log}`; the single-run lock
  `.implement-logs/.run.lock` (runner PID).
- `docs/tdd/BLOCKERS.md` — design-blocker ledger.

## Sequencing / implementation plan
Detect integration branch → select TDDs (`draft|ready` on integration, not
`implemented`) → acquire single-run lock → per TDD in a dedicated worktree: install
deps → build (`claude -p`, build-prompt) → gate 1 test-first (a `test(failing):`
commit precedes impl, read from git) → gate 2 `verify.sh` → gate 3 review (`claude -p`
on a different model, review-prompt) requiring `REVIEW_RESULT: PASS` → flip to
`implemented` + open PR. Halt-on-failure (sequential) marks downstream `BLOCKED`.
Emit report + bottom-up merge plan. Release lock on exit.

## Failure modes & edge cases
- Any gate fails → TDD stays unflipped; sequential run halts; downstream `BLOCKED`.
- Design-level infeasibility → build emits `BATCH_RESULT: BLOCKED`; logged to
  BLOCKERS.md (a `BLOCKED`, not a `FAIL`).
- Re-run before merge → TDD already `implemented` on an un-merged branch is skipped
  (`--rebuild` overrides).
- Second concurrent run → refused by the single-run lock (stale PID reclaimed).
- Worktree lacks gitignored deps → `install_deps` runs the project's package manager
  (`THROUGHLINE_SKIP_DEPS=1` opts out).
- No gh/remote → commits stay on branches for manual PRs.
- Stacked PRs + squash-merge → breaks the stack; merge plan warns (use merge/rebase
  or `--combined`).

## Requirement traceability
- FR-13 → merge-triggered selection (integration branch, not-implemented).
- FR-14 → detached `claude -p` + dedicated worktrees; sequential/`--combined`/`--parallel`.
- FR-15 → three gates: test-first (superpowers TDD), `verify.sh`, independent review.
  Verification aspects of FR-15 (the fourth gate, runtime-verify, and the
  reframing of `verify.sh` as the mechanical CI gate rather than verification)
  now covered by TDD 0007.
- FR-16 → never merges; sequential halt marks downstream `BLOCKED`.
- FR-17 → BLOCKERS.md feedback loop.
- FR-18 → resume skip of done-but-unmerged + single-run lock (`--rebuild`).
- FR-19 → report + bottom-up merge plan (squash warning).
- FR-20 → per-worktree package-manager-aware dependency install.
- NFR-1 → opens PRs, never merges (human gate).
- NFR-3 → build on opus, review on a different model (sonnet) by default.
- NFR-4 → `OK`/`FAIL`/`BLOCKED` verdicts kept distinct. Verification aspects of
  NFR-4 (runtime gate's PASS/FAIL/BLOCKED/SKIP distinction; ambiguity → FAIL;
  SKIP never silent) now covered by TDD 0007.

## Dependencies considered
- **Build discipline → `superpowers:test-driven-development`** (chosen). Rejected:
  restating TDD discipline inline (maintenance drift vs Anthropic's maintained skill)
  — see ADR 0002/0003.
- **Code review → `pr-review-toolkit`** (chosen; `code-reviewer` + `silent-failure-
  hunter`). Rejected: throughline's own `code-reviewer` (narrower, unmaintained).
- **Security review → throughline `security-reviewer`** (kept). Rejected for the gate:
  built-in `/security-review` (requires an `origin` remote; fragile in headless
  worktrees; under-flagged in the spike) — see ADR 0003.
- Both `superpowers` and `pr-review-toolkit` are declared cross-marketplace
  dependencies (plugin.json).

## PRD conflicts surfaced (and resolution)
None.

## Decisions to promote (ADR candidates)
None new; this unit is the primary subject of ADRs 0002 (delegate) and 0003 (keep
security-reviewer in the gate).

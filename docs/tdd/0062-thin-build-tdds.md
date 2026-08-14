# TDD 0062: Thin `/build-tdds` on Claude Code and Grok Build

Status: implemented
build-engine: bootstrap
PRD refs: FR-13, FR-14, FR-16, FR-17, FR-18, FR-19, FR-20, FR-41, FR-42, FR-80, FR-84, FR-85, NFR-1, NFR-3
PRD-rev: 373cd89
ADR constraints: 0004, 0005, 0009, 0010, 0011, 0013
Supersedes: 0005, 0008, 0010, 0011, 0025, 0036

## Approach
`/build-tdds` is an interactive skill (not a `nohup` coprocess). It confirms
the queue, creates a worktree, dispatches **one** implementer worker via
the harness, runs 0061 mechanical gates, dispatches **one** reviewer
worker on a different model, writes verdict files, opens a PR, never
merges. The parent skill sequences the workers (Grok depth-1). Session
survival is whatever the harness does; it is not required.

Until this TDD has flipped one TDD to `implemented` on the current
harness, a TDD may carry `build-engine: bootstrap` (FR-84). After that
flip, `/build-tdds` is the only flip authority on that harness.

## Components & interfaces
- `skills/implement/SKILL.md` frontmatter `name: build-tdds` (slash
  command `/build-tdds`). Body algorithm (actions, not vendor tool names):
  1. Source `plugin-root.sh`, `verdicts.sh`, `run-record.sh`,
     `models.sh`. Fail closed if any source fails (L-011).
     `REPO="$(git rev-parse --show-toplevel)"` in the human session
     checkout. Never pass the build worktree path as `<repo-root>`.
  2. If `tl_run_lock` is held by a live PID → refuse. If held by a dead
     PID → reclaim (FR-43).
  3. If `latest` has a non-terminal TDD → ask resume vs fresh (FR-39).
     Fresh deletes `latest` state fragments only (keep logs).
     Resume: `g="$(tl_run_next_gate "$REPO" "$run" "$slug")"` then jump:
     - `test-first` → if the build branch exists, do **not** re-dispatch
       the implementer; run step 8 observe-only. If the branch has no
       commits beyond integration, dispatch the implementer (step 7)
       with "continue from existing branch".
     - `ci-checks` → skip 7–8a; run `ci-checks.sh` only.
     - `runtime-verify` → skip 7–8; run step 9 only.
     - `review` → skip 7–9; run step 10 only.
     - `flip` → skip 7–10; run step 11 only.
     Never treat partial `feat:` commits as build-gate completion
     (FR-40). The test-first verdict file is the only build-complete
     signal.
  4. Queue: every `docs/tdd/0*.md` on the integration branch whose
     `Status:` is `draft` or `ready` and that is not already
     `implemented` on an unmerged `build/` branch (FR-13, FR-18). Skip
     `build-engine: bootstrap` only when **no** TDD on this harness has
     a `implemented` flip from `/build-tdds` yet (record
     `docs/tdd/.implement-logs/.first-flip-done` on first successful
     flip). After that file exists, ignore `build-engine: bootstrap`.
  5. Confirm queue + mode (`sequential` default / `--combined` /
     `--parallel`) with a structured question.
  6. `git worktree add` under `.worktrees/build-tdds-<slug>` from
     integration (or previous sequential HEAD). FR-20: install deps
     unless `THROUGHLINE_SKIP_DEPS=1`.
  7. Dispatch **one** implementer worker: working directory = worktree;
     prompt = read the TDD + cited PRD FRs + accepted ADRs; follow
     test-driven-development if that skill is present; commit on the
     build branch; do not flip Status; do not open a PR; do not spawn
     children. Model = `tl_resolve_models` build slot (see
     `scripts/lib/models.sh` below). Worker writes a parent-created
     report file whose last `^BUILD_RESULT: (OK|BLOCKED)$` line is
     authoritative. `BLOCKED` → parent appends `docs/tdd/BLOCKERS.md`
     (FR-17) and writes `blocked` + halt_cause `design-escalation`.
     If the worker exit or stderr matches
     `rate.?limit|usage.?limit|ECONNRESET` (or rc 143/130) →
     `tl_run_set_tdd … paused <cause>` and stop (FR-41). Genuine
     non-zero without that pattern → `failed`.
  8. When the implementer exits, run `tl_test_first_observe` on the
     worktree → `tl_verdict_write test-first` (`PASS` iff observe rc 0,
     else `FAIL`). Run `scripts/ci-checks.sh`
     in the worktree → write `ci-checks` PASS iff rc 0. On FAIL, set
     halt, unlock, stop (ADR 0013). Transient retry (FR-42): re-run
     `ci-checks.sh` up to `THROUGHLINE_TRANSIENT_RETRY` (default 2) if
     rc is 143/130 or stderr matches `rate.?limit|usage.?limit|ECONNRESET`.
  9. Dispatch **one** runtime-verify worker (different process/context;
     `tl_resolve_models` verify slot). Parent creates an empty report
     file and passes its path. Worker drives the TDD verification plan
     and writes a last line
     `^VERIFY_RESULT: (PASS|FAIL|BLOCKED|SKIP)$`. `SKIP` requires a
     following `EVIDENCE: <non-empty>` line. Missing token → FAIL.
     Transient stderr/rc → `paused` (FR-41), do not write FAIL.
     Parent then `tl_verdict_write runtime-verify`.
  10. Dispatch **one** reviewer worker on the prior-gen top-tier model
      (ADR 0009). Read-only. Inputs: TDD path, `git diff` of the build
      branch vs integration, optional `agents/security-reviewer.md` if
      that file exists. Must not spawn children. Parent writes
      `review.json` from a trailing `REVIEW_RESULT: PASS` or
      `REVIEW_RESULT: FAIL` line in the reviewer's **report file** (a
      path the parent created empty and passed in; not a transcript
      scrape of mid-prose). If the report file has no such line → FAIL.
  11. `tl_verdict_require_flip` → flip TDD `Status: implemented` on the
      **build branch**, `gh pr create` (never merge), write FR-19 report
      under the run dir, create `.first-flip-done`, unlock.
  **Halt rule (ADR 0013 / FR-16) — after every terminal outcome:**
  Continue to the next step only on: implementer `BUILD_RESULT: OK`;
  `test-first` PASS; `ci-checks` PASS; `runtime-verify` PASS or SKIP;
  `review` PASS. Otherwise: `tl_run_set_tdd` to `paused` (transient
  class after FR-42 budget exhaust: `ratelimit` / `usage-limit` /
  `transient`), `blocked` (`BUILD_RESULT: BLOCKED`, FR-67
  `structural-finding`, FR-17 `design-escalation` / `external-blocker`),
  or `failed` (`gate-fail` for a non-transient FAIL); unlock; **stop**.
  Do not dispatch later workers. In sequential mode, remaining queued
  TDDs become `blocked`. FR-42: after
  `THROUGHLINE_TRANSIENT_RETRY` (default 2) exhausted on a transient
  pattern → `paused`, never `failed`.
- Modes: sequential stacks `build/<run>/<slug>` on the previous TDD
  branch; `--combined` one branch; `--parallel` independent worktrees
  (FR-14). Downstream `BLOCKED` only in sequential (FR-16).
- `scripts/lib/models.sh` — **the one greppable binding site** (ADR 0009
  successor). `tl_resolve_models` prints
  `build=<id> review=<id> verify=<id>`. Defaults: build = latest top
  tier on this harness, review = prior-gen top tier, verify = cheaper
  tier when the TDD verification plan is only exit-code / file /
  grep, else build. Overrides:
  `THROUGHLINE_BUILD_MODEL`, `THROUGHLINE_REVIEW_MODEL`,
  `THROUGHLINE_RUNTIME_VERIFY_MODEL`. Product names live only in this
  file.
- Snapshot UI is TDD 0063 (`scripts/status.sh`). This TDD does not
  implement `/implement-status`.

## Data & state
`docs/tdd/.implement-logs/` as in 0061. `.first-flip-done` is an empty
marker file in that directory (gitignored with the rest).

## Sequencing / implementation plan
1. Add `scripts/lib/models.sh` with `tl_resolve_models` (ADR 0009
   binding site; product names only here).
2. Rewrite `skills/implement/SKILL.md`: `name: build-tdds` + the
   algorithm above including the resume jump table. Search of that file
   for required `claude -p` / `AskUserQuestion` / `Task` as tool names
   is empty. All `tl_verdict_*` / `tl_run_*` calls pass the integration
   repo-root, never the worktree path.
3. Add `tests/build-tdds-skill.test.sh`: frontmatter name is `build-tdds`;
   skill mentions `tl_verdict_require_flip`, `tl_run_next_gate`,
   `BUILD_RESULT`, `VERIFY_RESULT`; skill forbids nested worker-spawn
   (`must not spawn children`); no `claude -p` required;
   `models.sh` contains `tl_resolve_models`.
4. Flip `Status:` to `superseded by 0062` on
   `0005-gated-implementation.md`, `0008-run-progress-visibility.md`,
   `0010-build-observability-and-safety-boundaries.md`,
   `0011-detached-run-recovery.md`, `0025-build-coprocess-lifecycle.md`.
   (`0036` is flipped in this design PR already; not a 0062 build file.)

## Failure modes & edge cases
- **Real:** parent session ends after the implementer committed but
  before review. Mitigation: FR-39 resume + `tl_run_next_gate` restarts
  at the first missing verdict; commits stay on the build branch.
- **Real:** reviewer writes `REVIEW_RESULT: PASS` inside a cited code
  block in the report file. Mitigation: parent accepts the token only as
  a whole line `^REVIEW_RESULT: (PASS|FAIL)$` (last matching line wins).
- **Overblown:** `--parallel` worktree collisions — git worktrees already
  isolate; FR-18 still one `/build-tdds` invocation.
- **Unspoken:** Grok bundled `/implement` still exists. This TDD's
  frontmatter name is `build-tdds` so the slash command does not collide
  (FR-85). Do not also register `implement`.

## Verification plan
- **Surface:** skill frontmatter, skill text, slash name, resume next-gate.
- **Observation points:**
  1. `sed -n '1,8p' skills/implement/SKILL.md` contains `name: build-tdds`
     and does not contain `name: implement`.
  2. `rg -n 'claude -p|AskUserQuestion' skills/implement/SKILL.md` exits 1.
  3. `rg -n 'tl_verdict_require_flip|tl_run_next_gate|must not spawn children' skills/implement/SKILL.md` exits 0.
  4. After a simulated implementer-only run (three verdicts missing),
     `tl_run_next_gate` prints `test-first` or the first missing gate —
     not `flip`.
  5. On Grok, `grok inspect` lists a user-invocable skill `build-tdds`
     (or `/build-tdds` in the slash menu). On Claude, `/build-tdds` is
     the implement skill.
- **PASS:** 1–4 hold in CI. 5 is a runtime observation on each harness
  after plugin install/update (FR-80).

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Traceability | Every in-scope FR/NFR maps to a named component | One compound mapping still checkable | Untraced or hand-waved FR |
| Interface concreteness | Paths, env vars, JSON fields, and command names are literal | One interface described by role not path | "the helper", "appropriate adapter" |
| Alternatives | Each new dep has a named rejected alternative | No new deps; section says why | New dep with empty alternatives |
| Verification plan | Surface + command/observation + PASS values | Observable but a bit indirect | "tests pass" / missing |
| Scope bounds | Touched files ≤8, estimates padded, exceptions declared | One justified exception | Over bound with no exception |
| Naming | Same concept same name across all four TDDs | One alias noted | /implement vs /build-tdds mixed as the required surface |
| Supervisor-free | No TDD requires parsing stream-json or nesting reviewers | Mentions old runner only as deletion target | Designs a coprocess as flip authority |

## Requirement traceability
- FR-13 / FR-18 / FR-80 / FR-85 → queue + `name: build-tdds`
- FR-14 / FR-20 → worktree + deps
- FR-17 / FR-67 → BLOCKERS on design infeasibility (implementer reports
  BLOCKED; parent writes BLOCKERS.md)
- FR-19 → report under the run dir
- FR-28 / FR-30 / FR-64 → TDD 0063 (`status.sh`). Not this TDD.
- FR-41 / FR-42 → paused vs failed classification; ci-checks + worker
  transient retries (default 2).
- FR-84 → `.first-flip-done`
- NFR-1 → never merge
- NFR-3 / ADR 0009 → implementer vs reviewer models

## Dependencies considered
No new deps. Rejected: keep `scripts/implement.sh` as the orchestrator
(that is the supervisor). Rejected: implementer spawns the reviewer
(illegal on Grok; ADR 0010).

## PRD conflicts surfaced (and resolution)
None.

## Decisions to promote (ADR candidates)
None beyond 0010/0011/0013.

## Touched files
- `scripts/lib/models.sh` — sole model-id binding (ADR 0009 site)
- `skills/implement/SKILL.md` — `/build-tdds` algorithm
- `tests/build-tdds-skill.test.sh` — name + no-coprocess + next-gate
- `docs/tdd/0005-gated-implementation.md` — Status line
- `docs/tdd/0008-run-progress-visibility.md` — Status line
- `docs/tdd/0010-build-observability-and-safety-boundaries.md` — Status line
- `docs/tdd/0011-detached-run-recovery.md` — Status line
- `docs/tdd/0025-build-coprocess-lifecycle.md` — Status line

## Expected diff size
- `scripts/lib/models.sh` — 70 lines
- `skills/implement/SKILL.md` — 280 lines
- `tests/build-tdds-skill.test.sh` — 180 lines
- `docs/tdd/0005-gated-implementation.md` — 2 lines
- `docs/tdd/0008-run-progress-visibility.md` — 2 lines
- `docs/tdd/0010-build-observability-and-safety-boundaries.md` — 2 lines
- `docs/tdd/0011-detached-run-recovery.md` — 2 lines
- `docs/tdd/0025-build-coprocess-lifecycle.md` — 2 lines
Total expected diff: 540 lines across 8 files.

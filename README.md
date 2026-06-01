# throughline

throughline is a thin **governance overlay** for Claude Code: a persistent
**PRD → TDD → ADR** design-doc pipeline with phase-gate PRs and gated, detached
implementation. It gives you an auditable thread from *requirement → design →
decision → code* — every change traces back to an approved requirement and design,
architectural decisions are recorded and binding, and nothing is marked "done" on
the model's say-so.

It is deliberately minimal. It owns **governance and traceability** and *delegates*
discovery and generic engineering (test-driven-development, code review, worktrees) to
Anthropic's official plugins — **superpowers** and **pr-review-toolkit** — instead of
re-implementing them.

---

## Quick start

**Install** (once per machine — needs Claude Code ≥ 2.1.110 and the official
marketplace, which you almost certainly already have):

```
/plugin marketplace add cahenesy/throughline
/plugin install throughline@throughline
```

This auto-installs the two official plugins it depends on (superpowers,
pr-review-toolkit). If dependency resolution complains, add the official
marketplace first: `/plugin marketplace add anthropics/claude-plugins-official`.

**Set up your repo** (once per project, idempotent):

```
/bootstrap-project
```

**Then every feature is one lap of the loop** — one fresh session per command,
merge the PR it opens before the next command:

| Step | Command | What you get | Your gate |
|---|---|---|---|
| 1. Requirements | `/prd-author` | Interviews you → writes/updates `docs/PRD.md` → opens a **PRD PR** | Review + merge it |
| 2. Design | `/tdd-author` | Diffs the PRD → writes TDDs + ADRs → independent design critique → opens a **design PR** | Review + merge it |
| 3. Build | `/implement` | Detached runner builds each TDD failing-test-first through **four gates** → opens one **feature PR** per TDD | Review + merge them |

Watch a running build with `/implement-status`. If a build pauses (rate limit,
halt), re-run `/implement` — it detects the paused run and offers to resume.

That's the whole workflow. Everything below explains *why* it's shaped this way
and what each gate actually enforces.

**Tried it on a real project?** The most useful feedback is a (sanitized)
run report — what the gates caught, where it halted, what felt wrong. Open a
[Discussion](../../discussions). Bugs and halt reports → [Issues](../../issues)
(templates attach the right run-state artifacts). Want to contribute? See
[CONTRIBUTING.md](CONTRIBUTING.md) — throughline is built with itself, so
contributing is the product demo.

---

## Why use throughline instead of just asking Claude?

Plain Claude Code is excellent at writing code. The problem this overlay solves is
what *surrounds* the code — the parts a single prompt-and-go session quietly
loses:

| Plain Claude session | throughline |
|---|---|
| Design lives in transient chat; "why does this code exist?" decays with the session. | PRD + TDDs + ADRs are the persistent design-of-record. Every commit traces to an approved requirement, an approved design, and the architectural decisions it respects. |
| "Done" is the model's say-so — it ran the tests and they passed. | Nothing flips to `implemented` until **four independent gates** pass, each in its own process: failing-test-first (read from git history, not narrative), `ci-checks.sh` (the project's CI commands), runtime verification (drive the built artifact and observe), and an independent cross-model review. |
| The author reviews itself — same context, same blind spots, polite agreement. | The review gate runs in a separate `claude -p` on a **different model**, fanning out to specialized subagents (code review, silent-failure-hunter, security review). Different opinions, not an echo chamber. |
| Verification means "the tests passed." | Verification means **driving the real artifact** to where a user meets it (CLI output, HTTP response, log line, DOM, file write) and confirming the TDD's named observations hold. Tests-green is necessary, never sufficient. |
| Scope creeps. A "small fix" turns into a 540-line PR with 11 manual review-fix iterations. | Every TDD declares its **expected diff size + touched-file set** at design time. The design-critique gate refuses over-ambitious designs before any build runs. throughline's own scripts comply with the same bounds it enforces on yours. |
| Review is end-of-build — when something's wrong, you re-do the whole build. | Review runs **continuously, per step**, against the diff range since the last cleared pass. Cleared code is never re-evaluated. A halting finding triggers a **bounded automatic rework loop** on sonnet (cheaper, scope-capped) inside the same `/implement` invocation — not a manual fix-loop you babysit. |
| Findings are flat — every comment looks equally severe; the human reads all of them. | Every finding carries `severity: blocker | major | minor | nit` and a `structural: true|false` tag. The runner halts only on `{blocker, major}`. Minors and nits ship in the report but don't gate. |
| Reports are narrative. "I refactored the auth module to be cleaner." | Reports are **diff-grounded**: actual file list, line counts, traceability check, scope-bound check. The author's own self-review runs first (cheaper) and is then independently checked. |
| When work pauses for you, you guess why. "Did it crash? Hit a rate limit? Need a decision?" | A **closed halt taxonomy** of `human-needed` causes (rate-limit, structural-finding, rework-budget-exhausted, design-escalation, external-blocker, …) plus a **one-screen halt context** that names the cause, the artifact, and exactly what you need to do. |
| Lose the session, lose your work. A network drop mid-interview erases your elicitation; a rate-limit kills the build. | Interviews write a **draft file to disk** after every substantive elicitation — kill, reboot, or compaction resumes from where you left off. Builds run **detached + resumable** — rate-limit hits pause the run; you `/implement --resume` after the window. |
| Re-running setup either re-does everything (slow) or skips silently (drift). | **Two markers, queried independently**: repo state in the committed `docs/.throughline-bootstrap.json`, per-developer environment in `${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json`. Bootstrap is mechanically idempotent; a SessionStart hook auto-reconciles plugin updates without launching Claude. |
| Token spend is "whatever the model picked." | The runtime-verify gate **tiers models by plan complexity**: mechanical observations (exit codes, log greps) run on sonnet; nontrivial plans (browser, judgment, multi-step) run on the build model. Mechanical pre-pass lint runs before the LLM design-reviewer, so the reviewer never spends tokens on what `grep` already proved. |
| Engineering basics (TDD, worktrees, code review) are either reinvented per session or skipped. | Delegated **once** to the official plugins (superpowers, pr-review-toolkit). throughline owns the design-of-record and the gates; the plugins own the discipline that gates them. |
| The same class of bug recurs build after build; nothing remembers. | Per-build findings are mined at run-end for **recurring categorical patterns** (a finding class that appeared across more than one TDD or build step). One batched accept/discard prompt; accepted classes persist to `docs/tdd/LEARNINGS.md` and surface as **advisory context** in future `/tdd-author` sessions whose scope intersects the learning's `files=[…]` / `tags=[…]` hints. |

Put another way: plain Claude is a really good pair programmer in a closed room.
throughline is the design doc, the code review, the CI gate, the audit trail, and
the project manager who stays sober while the pair programmer is shipping.

---

## Workflow

One-time, per repo:

```
/bootstrap-project        # detect language → linter + formatter + test framework + docs/ scaffold + git on main
```

Then each feature or change is **one lap** of the loop below. Rule of thumb:
**one fresh session per command** — `/clear` (or a new session) at every phase
boundary, after each GitHub merge and before the next command. throughline's state
of record lives in **git + `docs/`**, not the chat, so each phase re-reads the
merged result; a clear only drops the previous interview's noise. The interactive
phases (`/prd-author`, `/tdd-author`, `/bootstrap-project`) pair well with
**`/fast`** (faster Opus output for snappy interviews); leave it off for
`/implement`, which runs detached and unattended.

**1. Requirements** — *fresh session*
- `/prd-author` → interviews you and writes `docs/PRD.md` (the WHAT and WHY;
  each requirement gets an **observable acceptance criterion**), then opens a
  **PRD PR** for a human reviewer. The interview persists a draft to disk after
  every substantive answer — a kill/reboot/compaction resumes from where you
  were.
- **GitHub:** review and **merge the PRD PR** — that approves the requirements,
  and its commit is the baseline `/tdd-author` diffs against.
- Pull `main` current, do a `/clear` or start a new session.

**2. Design** — *fresh session, on `main`, pulled current*
- `/tdd-author` → diffs the PRD, proposes the TDD set (you approve), writes the
  TDDs as `draft` (each with a requirement-traceability table, **expected diff
  size**, **touched files**, and a **verification plan**), self-reviews, creates
  any ADRs (it invokes `/adr-new` itself), runs the **mechanical pre-pass**
  (cheap shell lint catches missing sections, untraced FRs, scope-bound
  violations, placeholder phrases — *before* spending model time on review),
  then the independent **design-critique gate** (a separate `claude -p` on a
  different model from the author), and opens the **design PR** (TDDs + ADRs,
  with the critique verdict in the body). If a previous build produced
  accepted recurring-pattern learnings in `docs/tdd/LEARNINGS.md`, `/tdd-author`
  reads them and surfaces the ones whose `files=[…]` / `tags=[…]` hints
  intersect the new TDD's scope as **advisory context** (never blocking) — a
  signal "this class of issue has recurred in this project's prior builds."
- **GitHub:** Human reviews and **merges the design PR.** *This merge is the
  build gate* — it lands the `draft` TDDs on `main`, which is what makes them
  buildable.
- Pull `main` current, do a `/clear` or start a new session.

**3. Build** — *fresh session, on `main`, pulled current*
- `/implement` → confirms the queue (every TDD merged to `main` and not yet
  `implemented`) and the mode, then launches a thin **harness-tracked watcher**
  (`scripts/implement-watch.sh`) that in turn `nohup`s the **detached** runner —
  the build survives session close, and the watcher's tracked completion
  re-invokes your session when the run ends. Each TDD builds failing-test-first
  in a dedicated worktree and must pass **four gates** before it flips to
  `implemented` and opens a **feature PR**. It never merges.
- **Watch it:** `/implement-status` prints a progress **snapshot** (current TDD,
  stage, an estimate-labeled %, per-TDD statuses, log/PR pointers); for a live,
  read-only watch it hands you a one-line `!…status.sh --follow` command to
  paste (Ctrl-C to exit — it never touches the build). You can also tail
  `docs/tdd/.implement-logs/<ts>/report.md`. *Or* — because the watcher is
  harness-tracked — just walk away; the session is auto-re-invoked at
  run-completion with the run state and any pending learnings review.
- **Run-end learnings review (if any candidates).** When the run completes, the
  runner mines per-TDD findings for **recurring categorical patterns** (a
  finding class that appeared across more than one TDD or build step) and
  writes a candidates report. On session re-invocation, one batched
  `AskUserQuestion` lets you accept or discard each class; accepted ones append
  to `docs/tdd/LEARNINGS.md` (a `## L-NNN` entry per class, with
  subject-area hints) and become advisory input to future `/tdd-author`
  sessions per Step 2 above. Discarded candidates are not persisted; a run
  with no recurring patterns skips the prompt silently.
- **GitHub:** review and **merge the feature PR(s).** Sequential (default) PRs
  are *stacked* — merge **bottom-up in the report's "Merge plan" order**, with
  a merge-commit or rebase-merge (a squash breaks the stack; use
  `/implement --combined` for one squashable PR).
- Pull `main` current, do a `/clear` and start the next lap.

After the first round, `/prd-author` *updates* the existing PRD. Because
`/implement` runs detached in an isolated worktree, you can start the next lap's
`/prd-author` / `/tdd-author` while a build is still running; a single-run lock
holds off a second `/implement`, so two builds can't race.

### Feedback edges (the unhappy path)

- **Design blocker at build time:** `/implement` appends infeasible or
  contradictory requirements to `docs/tdd/BLOCKERS.md` and halts → re-run
  `/tdd-author` (it reads BLOCKERS.md), merge the design PR, re-run
  `/implement`.
- **Halting review finding (in-build):** the runner classifies the finding as
  structural-or-fixable. *Fixable* → enters a bounded automatic rework loop on
  sonnet (scope-capped per FR-66/67, attempt-budget-bounded per FR-65); the
  next per-step review pass runs against the new diff. *Structural* → routed to
  `docs/tdd/BLOCKERS.md` as a design-action-required cause, halts the TDD.
- **Rate-limit / transient pause:** the runner enters `paused` with the cause
  recorded; you resume after the window with `/implement --resume`. No work
  re-done; gates pick up where they left off.
- **Need human attention:** a single closed enum of **halt causes** + a
  one-screen halt context tells you exactly *why* the run is waiting and *what*
  action unblocks it.

---

## What's inside

```
throughline/
├── .claude-plugin/{plugin.json, marketplace.json}
├── agents/
│   ├── security-reviewer.md  # in-gate security review
│   └── design-reviewer.md    # independent design critique before the design PR
│   # build → superpowers:test-driven-development; code review → pr-review-toolkit (ADR 0003)
├── skills/
│   ├── bootstrap-project/    # /bootstrap-project — toolchain + docs scaffold (idempotent)
│   ├── prd-author/           # /prd-author       — the WHAT → docs/PRD.md (draft-persistent)
│   ├── tdd-author/           # /tdd-author       — the HOW  → docs/tdd/NNNN-* (draft-persistent)
│   ├── adr-new/              # /adr-new          — durable decisions → docs/adr/
│   ├── implement/            # /implement        — build all merged TDDs, detached
│   └── implement-status/     # /implement-status — progress snapshot of a live run
├── scripts/
│   ├── implement.sh             # detached runner (fresh claude -p per TDD) + run-state record
│   ├── implement-watch.sh       # thin harness-tracked watcher; nohups the runner, signals session re-invocation on completion
│   ├── lib/
│   │   ├── state.sh             # per-TDD / per-run JSON state-fragment I/O
│   │   ├── pause-retry.sh       # pause/retry classification (rate-limit, transient, usage-limit)
│   │   ├── gates.sh             # gate executors: build / verify / runtime-verify / review
│   │   ├── resume.sh            # resume orchestration: re-enter paused state, pick gates to re-run
│   │   ├── tdd-lint.sh          # mechanical pre-pass: structural lint + placeholder + traceability; --bounds runs the TDD-scope checks (doc size / per-file diff / touched-file count)
│   │   ├── plan-classifier.sh   # mechanical / nontrivial verification-plan heuristic (model tiering)
│   │   └── learnings.sh         # recurring-pattern detection over per-TDD findings + accepted-learning persistence to docs/tdd/LEARNINGS.md
│   ├── build-prompt.md          # build discipline; delegates to superpowers:test-driven-development
│   ├── review-prompt.md         # review gate: pr-review-toolkit + security-reviewer, separate process/model
│   ├── ci-checks.sh                # mechanical gate: tests + typecheck + lint (CI's job)
│   ├── verify-runtime-prompt.md # runtime-verification gate: drive + observe the real artifact
│   └── status.sh                # renders run progress (snapshot + --follow watch)
├── tests/
│   ├── implement-gate.test.sh             # eval: proves the four gates actually fire
│   ├── run-progress-visibility.test.sh    # eval: run-state record + status renderer
│   ├── run-recovery.test.sh               # eval: detached run recovery (paused / resume)
│   ├── token-spend-reduction.test.sh      # eval: lint + classifier + runtime-verify tiering
│   ├── build-observability.test.sh        # eval: session pointer + log conventions
│   ├── repo-id / markers / gitignore-helper / bootstrap-marker-wiring /
│   │     releases-manifest / session-reconcile-hook .test.sh  # evals: two markers + idempotent re-run + SessionStart reconcile + release-impact notice
│   ├── interactive-draft-persistence.test.sh # eval: draft files written after every elicitation
│   ├── bounded-tdd-scope.test.sh          # eval: expected-diff-size + touched-files bounds
│   ├── continuous-in-build-review.test.sh # eval: per-step scoped review
│   ├── bounded-rework-loop.test.sh        # eval: in-invocation sonnet rework + budget
│   ├── halt-taxonomy.test.sh              # eval: closed cause enum + one-screen context
│   ├── honest-reporting-self-review.test.sh # eval: severity tags + diff-grounded report
│   ├── build-phase-learnings.test.sh      # eval: recurring-pattern detection + watcher liveness + LEARNINGS.md persistence
│   └── accepted-learnings-inform-tdd-author.test.sh # eval: /tdd-author reads LEARNINGS.md + scope-matched advisory surfacing
└── hooks/{hooks.json, format-and-lint.sh, throughline-session-reconcile.sh}
```

## The pipeline at a glance

| Skill                | Produces / does          | Notes                                                       |
|----------------------|--------------------------|------------------------------------------------------------|
| `/bootstrap-project` | toolchain + `docs/` tree | Idempotent: re-running on a bootstrapped repo prints `already bootstrapped` and is a no-op. Two-marker state (repo + local). |
| `/prd-author`        | `docs/PRD.md`            | The WHAT. Explore + interview; observable acceptance criteria. Draft persisted after every answer; a kill resumes. Own session. |
| `/tdd-author`        | `docs/tdd/NNNN-*`        | The HOW. Runs ONCE per PRD update: diffs the PRD to decide how many TDDs; each carries a verification plan, expected diff size, touched files; mechanical pre-pass before the LLM design-reviewer. Draft persisted between turns. |
| `/adr-new`           | `docs/adr/NNNN-*`        | Append-only; status-gated supersession.                    |
| `/implement`         | code + tests + PR(s)     | Builds every merged, unbuilt TDD, detached; four gates before `implemented`; continuous in-build review with bounded automatic rework; one PR per TDD; halts the stack on failure; never merges. |
| `/implement-status`  | progress view            | Read-only snapshot of the active run; `--follow` for a live watch. |

On-demand code review is delegated to the official plugins — use the built-in
`/code-review` or pr-review-toolkit's `/review-pr` (throughline ships no
`/review` of its own).

## How the build gate works

`/implement` does **not** trust a build's self-reported `BATCH_RESULT: OK`. A TDD
flips to `implemented` only after **four independent gates**, each in its own
process:

1. **Failing-test-first** — a `test(failing):` commit must precede the
   implementation (mechanical, read straight from git history; the build follows
   `superpowers:test-driven-development`).
2. **`ci-checks.sh`** — mechanically re-runs the project's tests + typecheck +
   linter (this is CI's job — running tests, not verification).
   Package-manager-aware (pnpm/yarn/bun/npm) and prefers your declared `test` /
   `typecheck` / `lint` scripts; clippy runs at `-D warnings`.
3. **Runtime verification** — drives the *built artifact* to where the change
   is observable and confirms the TDD's verification plan holds, capturing the
   evidence. Reports `PASS` / `FAIL` / `BLOCKED` / `SKIP` (a change with no
   observable surface may `SKIP` with justification, never silently); ambiguity
   resolves to FAIL, never a false PASS (NFR-4); passing tests alone are not
   enough. The *mechanism* is the project's — throughline ships no harness,
   delegating to `superpowers:verification-before-completion` / `/verify`
   ([ADR 0004](docs/adr/0004-verification-is-observation-governed-not-bundled.md)).
   The runner **tiers models** by plan complexity: mechanical observations run
   on sonnet; nontrivial plans (browser, judgment, multi-step) run on the build
   model.
4. **Independent review** — runs **continuously per step** during the build
   (not only at the end), in a separate `claude -p` on a **different model**
   from the author. Each per-step pass reads only the diff range since the
   last cleared pass; cleared code is never re-evaluated. The reviewer fans
   out to `pr-review-toolkit:code-reviewer` + `silent-failure-hunter` +
   `throughline:security-reviewer`, and every finding carries
   `severity: blocker | major | minor | nit` + `structural: true|false`. A
   halting finding (`{blocker, major}`) triggers a **bounded automatic rework
   loop** inside the same `/implement` invocation (sonnet, scope-capped,
   structural-escalation aware, attempt-budget-bounded); `{minor, nit}`
   findings ship in the report but never gate. After all steps clear, a
   final consolidated pass issues the flip-authority `REVIEW_RESULT: PASS`
   over the union of cleared ranges.

The default is one stacked PR per TDD; a failed gate **halts the run** with a
named halt cause and marks downstream TDDs `BLOCKED` rather than building on a
broken base. Every mode builds in a **dedicated git worktree** (deps installed
first — `THROUGHLINE_SKIP_DEPS=1` opts out), so the detached runner never
touches the working tree your session is using. Because the `implemented` flip
lives on the build branch until you merge, a re-run **skips** any TDD already
built on an un-merged branch (`--rebuild` overrides).

## Bounded scope (no megaPR death-marches)

Every TDD declares its scope at design time, and the design-critique gate
enforces it:

- `## Touched files` — the explicit file set this TDD is allowed to change.
- `## Expected diff size` — declared per-file and total line bounds.
- Mechanical pre-pass extends the FR-51 lint with bound checks: scope-cap
  violations and out-of-set file edits fail-fast *before* any model time is
  spent on review.
- The design-critique gate is the authoritative scope check; it will **refuse**
  an over-ambitious TDD with a concrete reason, naming bounds and the
  qualitative red flags mechanical lint can't catch (working-memory pressure,
  cohesion drift).
- During build, halting reviewer findings that demand changes *outside* the
  declared scope escalate as **structural findings** to `BLOCKERS.md` rather
  than expanding the rework loop — the rework loop is bounded; structural
  problems are design problems and get sent back to design.

throughline **dogfoods this**: its own scripts (`implement.sh` plus
`scripts/lib/{state,pause-retry,gates,resume}.sh`) comply with the same per-file
bounds it enforces on consumer TDDs.

## Continuous review + bounded automatic rework

The review gate's authority is unchanged — it must end `REVIEW_RESULT: PASS`
before a flip — but *when* it runs is split:

- **Per-step passes during the build.** After each numbered item in the TDD's
  `## Sequencing / implementation plan` lands, a fresh `claude -p` review
  reads only the diff range since the last *cleared* pass on this TDD. Cleared
  code is never re-evaluated, so review time stays sublinear in diff size.
- **Cross-step learning.** A finding observed and resolved in step N is
  surfaced to the step-(N+1) reviewer as context, so the same class of bug
  isn't re-introduced one step later.
- **Halting finding → bounded automatic rework.** A `{blocker, major}` with
  `structural: false` triggers a sonnet rework attempt: the model gets the
  finding, the scope bounds, and the cleared-code map. Its commit faces the
  mechanical pre-pass first; on clear it ships and the next per-step review
  pass runs against the new diff range. The loop has an attempt budget (per
  gate); exhaustion triggers `rework-budget-exhausted` halt → human attention.
- **Structural escalation, not local sweep.** A halting finding with
  `structural: true` (e.g. needs changes to a file outside `## Touched files`)
  routes to `BLOCKERS.md` as a design-escalation cause; the rework loop does
  **not** silently expand scope to fix it.

The net effect: cheap minor fixes happen inside the build on sonnet without you
babysitting; real design problems escalate visibly with a one-screen context.

## Severity-honest reporting + author self-review

Findings are graded and reports are grounded:

- **Severity taxonomy on every finding.** `severity: blocker | major | minor |
  nit` + `structural: true|false`. The runner halts only on `{blocker, major}`.
  Minor + nit findings ship in the report unchanged but never gate.
- **Author self-review first.** Before the independent review runs, the
  author gives itself a structured self-review (mechanical lint + a brief
  self-critique). Cheap-to-catch issues get caught cheap; the independent
  reviewer's tokens go to the things the author couldn't see.
- **Gate decisions grounded in artifacts.** Verdicts cite the file/line
  evidence; the runner's report is grounded in `git diff`, not narrative.
- **Honest report: actual diff and scope, not story.** The end-of-run report
  carries actual file list, line counts, the scope-bound check result, and the
  per-TDD verdict trail (every gate outcome, every rework attempt). What
  changed is what the diff says changed.

## Build-phase learning capture

Per-TDD findings carry structure (`severity`, `structural`, `pattern_tags`,
`source` — plus rework cross-references). Throughline mines that structure at
run-end for **recurring categorical patterns** — a finding class that appeared
across more than one TDD or build step in this run — and surfaces them to the
human as a single batched accept/discard prompt:

- **Detection is the runner's job**, **review is yours.** The headless detached
  runner cannot prompt mid-build, so detection writes a `candidate-learnings.json`
  report and the harness-tracked watcher re-invokes your session at
  run-completion. One `AskUserQuestion` (`multiSelect: true`) lets you accept or
  discard each pattern class — *selected = accept, unselected = discard*. A run
  with no recurring patterns skips the prompt silently.
- **Accepted patterns persist** to `docs/tdd/LEARNINGS.md` as `## L-NNN`
  entries — class summary, the TDDs it recurred in, and **subject-area hints**
  (`files=[…]` glob/path set, `tags=[…]` set).
- **The loop closes at `/tdd-author`.** When you author the next round of TDDs,
  `/tdd-author` reads `LEARNINGS.md` and surfaces the entries whose hints
  intersect each new TDD's scope as **advisory context**. Never blocking — a
  signal that "this class of issue has recurred in this project's prior
  builds." The author decides what, if anything, to adjust.

The net effect: throughline learns from its own builds, but the human stays
authoritative on what counts as a learning worth carrying forward.

## Verification is observation

throughline treats *verification* — does the real artifact behave where a user
(human or programmatic) actually meets it — as a first-class concern, distinct
from tests/typechecks, carried from the PRD forward:

- each **PRD requirement** states an *observable acceptance criterion* (an
  observation of the artifact's surface, not "a test exists");
- each **TDD** carries a *verification plan*: the observable surface, the
  observation points that drive the changed code to where it runs, and the
  expected observations that constitute PASS — the design-critique gate
  **blocks** a TDD whose plan is missing or non-actionable;
- **`/implement`** executes that plan as gate 3 above, on a model tiered to
  the plan's complexity.

throughline owns only that a plan *exists, is executed, and yields evidence*;
the verification *mechanism* (CLI, HTTP, library, log, DOM, …) is the
project's
([ADR 0004](docs/adr/0004-verification-is-observation-governed-not-bundled.md)).
No verification framework is vendored into your repo.

## Watching a run

Builds run detached, so you keep visibility without blocking or leaving your
session:

- **`/implement-status`** — an on-demand **snapshot**: completed / total TDDs,
  an estimate-labeled percent (TDD- and stage-aware), the current TDD and its
  stage, per-TDD statuses + halt-cause if paused, elapsed time, and log / PR
  pointers. With no active run, it says so plainly.
- **Live watch** — `/implement-status` also hands you a one-line
  `!bash …/scripts/status.sh --follow` command: a foreground, read-only view
  that refreshes until you press Ctrl-C (`SIGHUP`/`SIGQUIT` also stop a
  non-interactive background launch; an optional `--max-seconds N` cap bounds
  scripted/CI use without relying on signals). It only *reads* the run-state
  record, so the detached build is unaffected, and your session is intact when
  you exit.
- **Auto-completion notification** — because the runner is launched by a
  harness-tracked watcher (`scripts/implement-watch.sh`), you don't *have*
  to poll. When the run terminates (done or paused), your session is
  auto-re-invoked with `IMPLEMENT_RUN_COMPLETE` + the run state — and any
  recurring-pattern learnings review (see Workflow §3) opens at that point.
- **One-screen halt context** — when the run pauses for human attention, the
  status output shows the `halt_cause` (a value from a single closed enum)
  plus the TDD, the gate, the artifact pointer, and the action needed. No
  guessing why work stopped.

It is **read-only observability** — the percent is an estimate, and the view
offers no pause / resume / cancel. Both views read one machine-readable
run-state record the runner maintains under the run's log dir.

## Install / update lifecycle hygiene

Setup is idempotent and self-reconciling. Two markers, queried independently:

- **`docs/.throughline-bootstrap.json`** (committed) — records what
  *repo state* has been applied: configs, scaffolds, ignore rules, the
  plugin version that applied them. Re-running `/bootstrap-project` on a
  bootstrapped repo reads this marker, short-circuits applied steps, and
  prints `already bootstrapped at <version>`. The file is byte-identical
  before and after.
- **`${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json`** (per developer) — records
  *per-machine environment* the current developer has applied for this repo:
  installed binaries, dependency state. Derived deterministically from the
  repo's remote URL (falling back to absolute path).

A **SessionStart hook** runs at the start of each session, reads both markers
plus the running plugin version, and silently re-applies any cheap repo steps
the active plugin version requires. It never launches Claude. A
per-release `local_impacting` flag triggers a one-line notice when the
developer-environment side needs attention.

The consumer repo's `.gitignore` is managed minimally: `docs/tdd/.implement-logs/`
is ignored; design state (`docs/PRD.md`, `docs/tdd/0*.md`, `docs/adr/`,
`docs/tdd/BLOCKERS.md`, `docs/.throughline-bootstrap.json`) stays tracked.

## Resilience: detached, resumable, draft-persistent

Long work survives the messy world. Three independent mechanisms:

- **Detached builds.** `/implement` launches a `nohup` runner that survives
  your session closing, host reboot (returning), or network drop. The runner
  uses a single-run lock so two builds can't race.
- **Paused/resume on rate-limit + transient errors.** The pause/retry
  classifier recognizes ratelimit / transient / usage-limit failures, records
  the cause in the run-state, and pauses. `/implement --resume` picks up
  exactly where the run left off — gates already cleared stay cleared; the
  rework attempt budget is preserved; nothing is re-done.
- **Interactive interview draft persistence.** `/prd-author` and `/tdd-author`
  write a transient on-disk draft after every substantive elicitation. Host
  reboot, manual kill, lost session, or intra-session compaction does **not**
  erase your answers — the next invocation reads the draft and resumes the
  interview from where it stopped.

## Design discipline (wired in)

- The **ADR index** is always loaded; full bodies are pulled on demand by
  scope. Only `accepted` ADRs bind new TDDs; superseded ADRs drop out of
  context.
- **`/tdd-author` runs once per PRD update:** it diffs the PRD against the
  last-designed revision, maps existing TDD coverage, and decides how many
  TDDs the change needs (you approve the plan before it writes). It
  challenges the PRD, proposes ADR actions rather than asking open-endedly,
  and reads `docs/tdd/BLOCKERS.md` so build-time design blockers feed back
  into design.
- Before the design PR, the **mechanical pre-pass** runs first (cheap shell
  lint over the authored TDD set); then the independent **design-critique
  gate** (the `design-reviewer` agent — fresh context, a different model than
  the author) blocks on untraced requirements, under-specified interfaces,
  ADR conflicts, a new dependency lacking the REQUIRED alternatives
  analysis, scope-bound violations, or a missing/non-actionable verification
  plan. Its verdict rides in the design PR so the human merges on an
  informed view.
- A TDD becomes **buildable when its design PR merges** — merging lands it on
  the integration branch at `draft`, and `/implement` builds whatever is
  there and not yet `implemented`. No manual `Status: ready` step; an
  un-merged draft on a design branch is not on integration, so the PR stays
  the gate.
- Stacked PRs come with an ordered, bottom-up **merge plan** in the report
  (merge in order; a squash-merge breaks the stack — use a merge commit /
  rebase-merge, or `--combined` for one squashable PR).

## Context hygiene

Skills run inside the session context, so a skill cannot `/clear` itself.
Autonomous work (investigation, test-writing) is pushed into **subagents**,
which run in their own context windows and report back summaries — so the main
session stays clean WITHOUT a manual clear. Implementation goes further: each
TDD builds in its own fresh `claude -p` process, the per-step review passes
run in yet more separate processes, and the runtime-verify gate runs in a
process distinct from the build — so the author never reviews itself in the
same context. The interview stages (`/prd-author`, `/tdd-author`) are
interactive and can't run in a subagent, so run each in its own fresh session
and `/clear` between them.

## Relationship to superpowers & the official plugins

Throughline is a thin **governance overlay** — it does not try to own your
whole SDLC. It **depends on and delegates engineering to** the official
`claude-plugins-official` plugins (superpowers, pr-review-toolkit) rather than
competing with them
([ADR 0003](docs/adr/0003-keep-security-reviewer-in-gate.md), carrying ADR
0002 forward):

- **Superpowers owns discovery and engineering** —
  test-driven-development, worktrees, code review, the verification
  *mechanism*, branch finishing. **Throughline owns governance** —
  PRD/TDD/ADR as the design-of-record, requirement traceability, the
  *requirement* that verification happens, phase-gate PRs, bounded scope,
  continuous review, the rework loop, the halt taxonomy, and honest
  reporting.
- **The explicit command is the ownership signal.** Invoking `/prd-author`
  or `/tdd-author` means throughline owns that phase and will NOT also fire
  `superpowers:brainstorming` / `writing-plans`. If superpowers artifacts
  already exist (`docs/superpowers/{specs,plans}`), throughline **ingests**
  them instead of re-interviewing. With no throughline command invoked,
  superpowers' defaults stand.
- **Canonical docs:** `docs/PRD.md` + `docs/tdd/` + `docs/adr/` are the
  design-of-record. `docs/superpowers/*` is transient input — ingested,
  never authoritative, and never relocated (throughline leaves any existing
  `docs/superpowers/` content untouched).

For the boundary to bind reliably, add a line to your CLAUDE.md, e.g.:
*"When `/prd-author` or `/tdd-author` is invoked, that is the design step —
do not also invoke `superpowers:brainstorming` or `writing-plans` for it."*

## Requirements & dependencies

Throughline is a **layer on top of** the official plugins, not a standalone
tool. It owns the governance layer (PRD/TDD/ADR) and **delegates overlapping
engineering** to the better-maintained official plugins + built-ins, so it
**requires**:

- **superpowers** — discovery (`brainstorming`) and the generic engineering
  skills (test-driven-development, worktrees, and the verification
  *mechanism* via `verification-before-completion` / `/verify`).
  Throughline ingests its `docs/superpowers/*` artifacts if present.
- **pr-review-toolkit** — code review (used on-demand via `/review-pr`, and
  by the `/implement` review gate's continuous in-build passes).

Both are declared as cross-marketplace `dependencies` in `plugin.json`
(`allowCrossMarketplaceDependenciesOn: ["claude-plugins-official"]` in
`marketplace.json`), so installing throughline **auto-installs them** —
*provided you already have the `claude-plugins-official` marketplace added*
(you almost certainly do). If you don't, throughline loads with a
`dependency-unsatisfied` error until you add it:

```
/plugin marketplace add anthropics/claude-plugins-official
```

Then `/plugin install throughline@throughline` pulls throughline + its
dependencies. (Cross-marketplace dependency resolution needs Claude Code
≥ 2.1.110.) Built-in commands throughline also leans on — `/code-review`,
`/security-review`, and the `Explore` agent — ship with Claude Code and need
no install.

## Running the eval suites locally

Install and setup are covered in [Quick start](#quick-start) at the top. If you
want to run the eval suites locally before relying on the gates:

```
chmod +x hooks/format-and-lint.sh hooks/throughline-session-reconcile.sh \
         scripts/implement.sh scripts/ci-checks.sh scripts/status.sh
bash tests/implement-gate.test.sh
bash tests/run-recovery.test.sh
bash tests/token-spend-reduction.test.sh
bash tests/bounded-tdd-scope.test.sh
bash tests/continuous-in-build-review.test.sh
bash tests/bounded-rework-loop.test.sh
bash tests/halt-taxonomy.test.sh
bash tests/honest-reporting-self-review.test.sh
```

## Caveat

Plugin/marketplace JSON schemas and `/plugin` syntax evolve. Run
`claude plugin validate .` and confirm the current commands against the docs.

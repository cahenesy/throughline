# throughline

throughline is a thin **governance overlay** for Claude Code: a persistent
**PRD → TDD → ADR** design-doc pipeline with phase-gate PRs and gated, detached
implementation. It gives you an auditable thread from *requirement → design →
decision → code* — every change traces back to an approved requirement and design,
architectural decisions are recorded and binding, and nothing is marked "done" on
the model's say-so.

It is deliberately minimal. It owns **governance and traceability** and *delegates*
discovery and generic engineering (test-driven-development, code review, worktrees) to
whatever the harness already provides — Superpowers and pr-review-toolkit are
**optional** — instead of re-implementing them. Some harnesses already own
`/implement`; throughline's build command is `/build-tdds` (FR-85).

---

## Quick start

**Install** (once per machine — needs Claude Code ≥ 2.1.110 and the official
marketplace, which you almost certainly already have):

```
/plugin marketplace add cahenesy/throughline
/plugin install throughline@throughline
```

Superpowers and pr-review-toolkit are optional; throughline installs and
flips without them. Add the official marketplace only if you want those
delegates: `/plugin marketplace add anthropics/claude-plugins-official`.

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
| 3. Build | `/build-tdds` | Builds each TDD failing-test-first through **four gates** → opens one **feature PR** per TDD | Review + merge them |

Watch a running build with `/implement-status`. If a build pauses (rate limit,
halt), re-run `/build-tdds` to resume.

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
| Review is end-of-build — when something's wrong, you re-do the whole build. | Review runs **continuously, per step**, against the diff range since the last cleared pass. Cleared code is never re-evaluated. A halting finding triggers a **bounded automatic rework loop** on the build model (scope-capped) inside the same `/implement` invocation — not a manual fix-loop you babysit. |
| Findings are flat — every comment looks equally severe; the human reads all of them. | Every finding carries `severity: blocker | major | minor | nit` and a `structural: true|false` tag. The runner halts only on `{blocker, major}`. Minors and nits ship in the report but don't gate. |
| Reports are narrative. "I refactored the auth module to be cleaner." | Reports are **diff-grounded**: actual file list, line counts, traceability check, scope-bound check. The author's own self-review runs first (cheaper) and is then independently checked. |
| When work pauses for you, you guess why. "Did it crash? Hit a rate limit? Need a decision?" | A **closed halt taxonomy** of `human-needed` causes (rate-limit, structural-finding, rework-budget-exhausted, design-escalation, external-blocker, …) plus a **one-screen halt context** that names the cause, the artifact, and exactly what you need to do. |
| Lose the session, lose your work. A network drop mid-interview erases your elicitation; a rate-limit kills the build. | Interviews write a **draft file to disk** after every substantive elicitation — kill, reboot, or compaction resumes from where you left off. Builds run **detached + resumable** — rate-limit hits pause the run; you `/implement --resume` after the window. |
| Re-running setup either re-does everything (slow) or skips silently (drift). | **Two markers, queried independently**: repo state in the committed `docs/.throughline-bootstrap.json`, per-developer environment in `${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json`. Bootstrap is mechanically idempotent; a SessionStart hook auto-reconciles plugin updates without launching Claude. |
| Token spend is "whatever the model picked." | The runtime-verify gate **tiers models by plan complexity**: mechanical observations (exit codes, log greps) run on a cost-efficient lower-tier model; nontrivial plans (browser, judgment, multi-step) run on the build model. Mechanical pre-pass lint runs before the LLM design-reviewer, so the reviewer never spends tokens on what `grep` already proved. |
| Engineering basics (TDD, worktrees, code review) are either reinvented per session or skipped. | Delegated to optional Superpowers / pr-review-toolkit (or harness built-ins) when present. throughline owns the design-of-record and the gates. |
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
`/build-tdds`.

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
- `/build-tdds` → confirms the queue (every TDD merged to `main` and not yet
  `implemented`) and the mode, then builds each TDD failing-test-first
  in a dedicated worktree. Each TDD must pass **four gates** before it flips to
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
  `/build-tdds --combined` for one squashable PR).
- Pull `main` current, do a `/clear` and start the next lap.

After the first round, `/prd-author` *updates* the existing PRD. You can start
the next lap's `/prd-author` / `/tdd-author` while a build is still running; a
single-run lock holds off a second `/build-tdds`, so two builds can't race.

### Feedback edges (the unhappy path)

- **Design blocker at build time:** `/build-tdds` appends infeasible or
  contradictory requirements to `docs/tdd/BLOCKERS.md` and halts → re-run
  `/tdd-author` (it reads BLOCKERS.md), merge the design PR, re-run
  `/build-tdds`.
- **Halting review finding (in-build):** the runner classifies the finding as
  structural-or-fixable. *Fixable* → enters a bounded automatic rework loop on
  the build model (scope-capped per FR-66/67, attempt-budget-bounded per FR-65); the
  next per-step review pass runs against the new diff. *Structural* → routed to
  `docs/tdd/BLOCKERS.md` as a design-action-required cause, halts the TDD.
- **Rate-limit / transient pause:** the runner enters `paused` with the cause
  recorded; re-run `/build-tdds` after the window. No work
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
│   ├── implement/            # /build-tdds       — build all merged TDDs
│   └── implement-status/     # /implement-status — progress snapshot of a live run
├── scripts/
│   ├── implement.sh             # retired stub (use /build-tdds)
│   ├── implement-watch.sh       # retired stub (use /build-tdds)
│   ├── lib/
│   │   ├── plugin-root.sh       # CLAUDE_PLUGIN_ROOT / GROK_PLUGIN_ROOT resolver
│   │   ├── verdicts.sh          # file-backed gate verdicts
│   │   ├── run-record.sh        # /build-tdds run-state (run.json + per-TDD slugs)
│   │   ├── models.sh            # ADR 0009 model pairing
│   │   ├── tdd-lint.sh          # mechanical pre-pass: structural lint + placeholder + traceability; --bounds runs the TDD-scope checks
│   │   ├── plan-classifier.sh   # mechanical / nontrivial verification-plan heuristic
│   │   ├── json.sh              # single-source JSON helpers: tl_json_escape + tl_json_field
│   │   ├── md.sh                # unified fence-aware markdown section/bullet parsers
│   │   ├── touched-files.sh     # the one Touched-files extractor every consumer delegates to
│   │   ├── drafts.sh            # interview draft persistence (per-elicitation crash safety)
│   │   └── markers.sh / repo-id.sh / gitignore.sh   # bootstrap markers + repo identity + managed ignore rules
│   ├── build-norms.md           # enumerated FR-74 defensive-coding norms
│   ├── ci-checks.sh             # mechanical gate: tests + typecheck + lint (CI's job)
│   └── status.sh                # renders /build-tdds run progress (snapshot + --follow watch)
├── tests/
│   ├── implement-gate.test.sh             # aggregator: 0063 stubs + live 0060–0062 helpers
│   ├── plugin-root / verdicts / run-record / build-tdds-skill .test.sh
│   ├── repo-id / markers / gitignore-helper / bootstrap-marker-wiring /
│   │     releases-manifest / session-reconcile-hook .test.sh
│   ├── token-spend-reduction.test.sh      # eval: tdd-lint + plan classifier
│   ├── interactive-draft-persistence.test.sh
│   ├── bounded-tdd-scope.test.sh
│   └── learnings-inform-tdd-author.test.sh
└── hooks/{hooks.json, format-and-lint.sh, throughline-session-reconcile.sh}
```

## The pipeline at a glance

| Skill                | Produces / does          | Notes                                                       |
|----------------------|--------------------------|------------------------------------------------------------|
| `/bootstrap-project` | toolchain + `docs/` tree | Idempotent: re-running on a bootstrapped repo prints `already bootstrapped` and is a no-op. Two-marker state (repo + local). |
| `/prd-author`        | `docs/PRD.md`            | The WHAT. Explore + interview; observable acceptance criteria. Draft persisted after every answer; a kill resumes. Own session. |
| `/tdd-author`        | `docs/tdd/NNNN-*`        | The HOW. Runs ONCE per PRD update: diffs the PRD to decide how many TDDs; each carries a verification plan, expected diff size, touched files; mechanical pre-pass before the LLM design-reviewer. Draft persisted between turns. |
| `/adr-new`           | `docs/adr/NNNN-*`        | Append-only; status-gated supersession.                    |
| `/build-tdds`        | code + tests + PR(s)     | Builds every merged, unbuilt TDD; four gates before `implemented`; one PR per TDD; halts the stack on failure; never merges. |
| `/implement-status`  | progress view            | Read-only snapshot of the active run; `--follow` for a live watch. |

On-demand code review is delegated to the official plugins — use the built-in
`/code-review` or pr-review-toolkit's `/review-pr` (throughline ships no
`/review` of its own).

## How the build gate works

`/build-tdds` does **not** trust a build's self-reported success. The
verdict itself is **authenticated**: the runner honors only an assistant-authored,
final-line sentinel — observed once and echoed to a runner-written, line-anchored
marker that downstream parsing reads — so sentinel text that merely appears inside
a file the build read, a tool's output, or mid-message prose can neither end the
build nor pass the gate. On top of that, a TDD flips to `implemented` only after
**four independent gates**, each in its own process:

1. **Failing-test-first** — a `test(failing):` commit must precede the
   implementation (mechanical, read straight from git history; the build follows
   `superpowers:test-driven-development`). Enforced **per step** as well as
   whole-build: a step that commits implementation with no preceding
   `test(failing):` in its range (and no declared per-step skip) gets a
   deterministic `STEP_REVIEW: BLOCK` *before* any model review runs.
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
   on a cost-efficient lower-tier model; nontrivial plans (browser, judgment,
   multi-step) run on the build model.
4. **Independent review** — runs **continuously per step** during the build
   (not only at the end), in a separate `claude -p` on a **different model**
   from the author. Each per-step pass reads only the diff range since the
   last cleared pass; cleared code is never re-evaluated. The reviewer fans
   out to `pr-review-toolkit:code-reviewer` + `silent-failure-hunter` +
   `throughline:security-reviewer`, and every finding carries
   `severity: blocker | major | minor | nit` + `structural: true|false`. A
   halting finding (`{blocker, major}`) triggers a **bounded automatic rework
   loop** inside the same `/implement` invocation (the build model, scope-capped,
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

throughline **dogfoods this**: its own live scripts (`scripts/lib/{verdicts,run-record,tdd-lint,drafts}.sh`)
comply with the same per-file bounds it enforces on consumer TDDs.

## `/build-tdds` gates

`/build-tdds` sequences one implementer worker, then four flip gates, then a
PR. It never merges. After any gate FAIL/BLOCKED (or a transient pause), it
unlocks and **stops** — no in-build rework loop, no per-step coprocess review.

1. **test-first** — observe a failing-test commit before the feature commit.
2. **ci-checks** — `scripts/ci-checks.sh` (tests + typecheck + lint).
3. **runtime-verify** — a separate worker drives the TDD `## Verification plan`.
4. **review** — a separate worker on a different model; token
   `REVIEW_RESULT: PASS|FAIL`.

Verdicts are files under `docs/tdd/.implement-logs/<run>/<slug>/`. Progress is
`/implement-status`. Structural / design problems still go to
`docs/tdd/BLOCKERS.md` for `/tdd-author`.

## Build-phase learning capture

`/tdd-author` still **reads** `docs/tdd/LEARNINGS.md` if present and surfaces
matching entries as advisory context. There is no automatic writer after the
coprocess retirement — new `## L-NNN` entries are human-authored for now.

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
- **`/build-tdds`** executes that plan as gate 3 above, on a model tiered to
  the plan's complexity.

throughline owns only that a plan *exists, is executed, and yields evidence*;
the verification *mechanism* (CLI, HTTP, library, log, DOM, …) is the
project's
([ADR 0004](docs/adr/0004-verification-is-observation-governed-not-bundled.md)).
No verification framework is vendored into your repo.

## Watching a run

`/build-tdds` is an interactive parent skill. Progress:

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
- **Session survival** — `/build-tdds` is an interactive parent skill. Progress
  is whatever the harness does; `/implement-status` is the snapshot. There is
  no detached coprocess watcher.
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

- **Detached builds.** `/build-tdds` runs so the session can close; a
  single-run lock so two builds can't race.
- **Paused/resume on rate-limit + transient errors.** The pause/retry
  classifier recognizes ratelimit / transient / usage-limit failures, records
  the cause in the run-state, and pauses. Re-run `/build-tdds` to pick up
  exactly where the run left off — gates already cleared stay cleared;
  nothing is re-done.
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
  the integration branch at `draft`, and `/build-tdds` builds whatever is
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
whole SDLC. Superpowers and pr-review-toolkit are **optional** delegates
(ADR 0010). throughline uses them when present and does not fail install or
a gate solely because they are absent:

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

Throughline is a **layer on top of** the harness, not a standalone tool. It
owns the governance layer (PRD/TDD/ADR) and **optionally delegates**
overlapping engineering to Superpowers, pr-review-toolkit, or harness
built-ins when those are present (FR-22, FR-83). They are **not** install
requirements and are **not** declared in `plugin.json`.

- **superpowers** (optional) — discovery (`brainstorming`) and generic
  engineering (test-driven-development, worktrees, verification *mechanism*).
  Throughline ingests its `docs/superpowers/*` artifacts if present.
- **pr-review-toolkit** (optional) — on-demand `/review-pr` / `/code-review`.

Built-in harness commands (`/code-review`, `/security-review`, Explore)
need no extra install. A harness that already owns `/implement` is why
throughline's build command is `/build-tdds`.

## Running the eval suites locally

Install and setup are covered in [Quick start](#quick-start) at the top. If you
want to run the eval suites locally before relying on the gates:

```
chmod +x hooks/format-and-lint.sh hooks/throughline-session-reconcile.sh \
         scripts/ci-checks.sh scripts/status.sh
bash tests/implement-gate.test.sh
bash tests/token-spend-reduction.test.sh
bash tests/bounded-tdd-scope.test.sh
bash tests/json-helper.test.sh
bash tests/interactive-draft-persistence.test.sh
```

## Caveat

Plugin/marketplace JSON schemas and `/plugin` syntax evolve. Run
`claude plugin validate .` and confirm the current commands against the docs.

# throughline

throughline is a thin **governance overlay** for Claude Code: a persistent
**PRD → TDD → ADR** design-doc pipeline with phase-gate PRs and gated, unattended
implementation. It gives you an auditable thread from *requirement → design →
decision → code* — every change traces back to an approved requirement and design,
architectural decisions are recorded and binding, and nothing is marked "done" on
the model's say-so.

It is deliberately minimal. It owns **governance and traceability** and *delegates*
discovery and generic engineering (test-driven-development, code review, worktrees) to
Anthropic's official plugins — **superpowers** and **pr-review-toolkit** — instead of
re-implementing them.

---

## Workflow

One-time, per repo:

```
/bootstrap-project        # detect language → linter + formatter + test framework + docs/ scaffold + git on main
```

Then each feature or change is **one lap** of the loop below. Rule of thumb:
**one fresh session per command** — `/clear` (or a new session) at every phase
boundary, after each GitHub merge and before the next command. This is deliberate:
throughline's state of record lives in **git + `docs/`**, not the chat, so each phase
re-reads the merged result and a clear only drops the previous interview's noise — you
lose no progress and avoid the model over anchoring on context from the previous phase.
The interactive phases (`/prd-author`, `/tdd-author`, `/bootstrap-project`) pair well
with **`/fast`** (faster Opus output for snappy interviews); leave it off for
`/implement`, which runs detached and unattended.

**1. Requirements** — *fresh session*
- `/prd-author` → interviews you and writes `docs/PRD.md` (the WHAT and WHY; each
  requirement gets an **observable acceptance criterion**), then opens a **PRD PR** for
  a human reviewer.
- **GitHub:** review and **merge the PRD PR** — that approves the requirements, and
  its commit is the baseline `/tdd-author` diffs against.
- Pull `main` current, do a `/clear` or start a new session.

**2. Design** — *fresh session, on `main`, pulled current
- `/tdd-author` → diffs the PRD, proposes the TDD set (you approve), writes the TDDs
  as `draft` (each with a requirement-traceability table and a **verification plan**),
  self-reviews, creates any ADRs (it invokes `/adr-new` itself), runs the independent
  **design-critique gate**, and opens the **design PR** (TDDs + ADRs, with the
  critique verdict in the body).
- **GitHub:** Human reviews and **merges the design PR.** *This merge is the build gate* —
  it lands the `draft` TDDs on `main`, which is what makes them buildable.
- Pull `main` current, do a `/clear` or start a new session.

**3. Build** — *fresh session, on `main`, pulled current
- `/implement` → confirms the queue (every TDD merged to `main` and not yet
  `implemented`) and the mode, then launches a **detached** runner and hands control
  back. Each TDD builds failing-test-first and must pass **four gates** — test-first,
  `verify.sh`, runtime verification, and an independent cross-model review — before it
  flips to `implemented` and opens a **feature PR**. It never merges.
- **Watch it:** `/implement-status` prints a progress **snapshot** (current TDD,
  stage, an estimate-labeled %, per-TDD statuses, log/PR pointers); for a live,
  read-only watch it hands you a one-line `!…status.sh --follow` command to paste
  (Ctrl-C to exit — it never touches the build). You can also tail
  `docs/tdd/.implement-logs/<ts>/report.md`.
- **GitHub:** review and **merge the feature PR(s).** Sequential (default) PRs are
  *stacked* — merge **bottom-up in the report's "Merge plan" order**, with a
  merge-commit or rebase-merge (a squash breaks the stack; use `/implement --combined`
  for one squashable PR).
- Pull `main` current, do a `/clear` and start the next lap.

After the first round, `/prd-author` *updates* the existing PRD.  Because `/implement`
runs detached in an isolated worktree, you can start the next lap's `/prd-author` /
`/tdd-author` while a build is still running; a single-run lock holds off a second
`/implement`, so you can't accidentally cause a race with two builds running at once.

### Feedback edges (the unhappy path)
- **Design blocker at build time:** `/implement` appends infeasible or contradictory
  requirements to `docs/tdd/BLOCKERS.md` and halts → re-run `/tdd-author` (it reads
  BLOCKERS.md), merge the design PR, re-run `/implement`.
- **Partial build:** a failed gate halts the stack and marks downstream TDDs
  `BLOCKED` in the report → fix, then re-run `/implement` (it resumes the unbuilt
  ones).

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
│   ├── bootstrap-project/    # /bootstrap-project — toolchain + docs scaffold
│   ├── prd-author/           # /prd-author       — the WHAT → docs/PRD.md
│   ├── tdd-author/           # /tdd-author       — the HOW  → docs/tdd/NNNN-*
│   ├── adr-new/              # /adr-new          — durable decisions → docs/adr/
│   ├── implement/            # /implement        — build all merged TDDs, detached
│   └── implement-status/     # /implement-status — progress snapshot of a live run
├── scripts/
│   ├── implement.sh             # detached runner (fresh claude -p per TDD) + run-state record
│   ├── build-prompt.md          # build discipline; delegates to superpowers:test-driven-development
│   ├── review-prompt.md         # review gate: pr-review-toolkit + security-reviewer, separate process/model
│   ├── verify.sh                # mechanical gate: tests + typecheck + lint (CI's job)
│   ├── verify-runtime-prompt.md # runtime-verification gate: drive + observe the real artifact
│   └── status.sh                # renders run progress (snapshot + --follow watch)
├── tests/
│   ├── implement-gate.test.sh         # eval: proves the four gates actually fire
│   ├── run-progress-visibility.test.sh # eval: run-state record + status renderer
│   └── run-recovery.test.sh           # eval: detached run recovery (paused / resume)
└── hooks/{hooks.json, format-and-lint.sh}
```

## The pipeline at a glance

| Skill                | Produces / does          | Notes                                                       |
|----------------------|--------------------------|------------------------------------------------------------|
| `/bootstrap-project` | toolchain + `docs/` tree | greenfield: linter, formatter, test, git, scaffold         |
| `/prd-author`        | `docs/PRD.md`            | the WHAT. Explore + interview; observable acceptance criteria. Own session. |
| `/tdd-author`        | `docs/tdd/NNNN-*`        | the HOW. Runs ONCE per PRD update: diffs the PRD to decide how many TDDs; each carries a verification plan; challenges the PRD; recommends ADRs; independent design-critique gate before the PR. |
| `/adr-new`           | `docs/adr/NNNN-*`        | append-only; status-gated supersession.                    |
| `/implement`         | code + tests + PR(s)     | builds every merged, unbuilt TDD, detached; four gates before `implemented`; one PR per TDD; halts the stack on failure; never merges. |
| `/implement-status`  | progress view           | read-only snapshot of the active run; `--follow` for a live watch. |

On-demand code review is delegated to the official plugins — use the built-in
`/code-review` or pr-review-toolkit's `/review-pr` (throughline ships no `/review` of
its own).

## How the build gate works

`/implement` does **not** trust a build's self-reported `BATCH_RESULT: OK`. A TDD
flips to `implemented` only after **four independent gates**, each in its own process:

1. **Failing-test-first** — a `test(failing):` commit must precede the implementation
   (mechanical, read straight from git history; the build follows
   `superpowers:test-driven-development`).
2. **`verify.sh`** — mechanically re-runs the project's tests + typecheck + linter
   (this is CI's job — running tests, not verification). Package-manager-aware
   (pnpm/yarn/bun/npm) and prefers your declared `test` / `typecheck` / `lint`
   scripts; clippy runs at `-D warnings`.
3. **Runtime verification** — drives the *built artifact* to where the change is
   observable and confirms the TDD's verification plan holds, capturing the evidence.
   Reports `PASS` / `FAIL` / `BLOCKED` / `SKIP` (a change with no observable surface
   may `SKIP` with justification, never silently); ambiguity resolves to FAIL, never
   a false PASS (NFR-4); passing tests alone are not enough. The *mechanism* is the
   project's — throughline ships no harness, delegating to
   `superpowers:verification-before-completion` / `/verify`
   ([ADR 0004](docs/adr/0004-verification-is-observation-governed-not-bundled.md)).
4. **Independent review** — a separate `claude -p` on a **different model** (sonnet vs
   an opus build, so it doesn't share the author's blind spots) fans out to
   `pr-review-toolkit:code-reviewer` + `silent-failure-hunter` +
   `throughline:security-reviewer` and must return `REVIEW_RESULT: PASS`.

The default is one stacked PR per TDD; a failed gate **halts the run** and marks
downstream TDDs `BLOCKED` rather than building on a broken base. Every mode builds in
a **dedicated git worktree** (deps installed first — `THROUGHLINE_SKIP_DEPS=1` opts
out), so the detached runner never touches the working tree your session is using.
Because the `implemented` flip lives on the build branch until you merge, a re-run
**skips** any TDD already built on an un-merged branch (`--rebuild` overrides).

## Verification is observation

throughline treats *verification* — does the real artifact behave where a user
(human or programmatic) actually meets it — as a first-class concern, distinct from
tests/typechecks, carried from the PRD forward:

- each **PRD requirement** states an *observable acceptance criterion* (an observation
  of the artifact's surface, not "a test exists");
- each **TDD** carries a *verification plan*: the observable surface, the observation
  points that drive the changed code to where it runs, and the expected observations
  that constitute PASS — the design-critique gate **blocks** a TDD whose plan is
  missing or non-actionable;
- **`/implement`** executes that plan as gate 3 above.

throughline owns only that a plan *exists, is executed, and yields evidence*; the
verification *mechanism* (CLI, HTTP, library, log, DOM, …) is the project's
([ADR 0004](docs/adr/0004-verification-is-observation-governed-not-bundled.md)). No
verification framework is vendored into your repo.

## Watching a run

Builds run detached, so you keep visibility without blocking or leaving your session:

- **`/implement-status`** — an on-demand **snapshot**: completed / total TDDs, an
  estimate-labeled percent (TDD- and stage-aware), the current TDD and its stage,
  per-TDD statuses, elapsed time, and log / PR pointers. With no active run, it says
  so plainly.
- **Live watch** — `/implement-status` also hands you a one-line
  `!bash …/scripts/status.sh --follow` command: a foreground, read-only view that
  refreshes until you press Ctrl-C. It only *reads* the run-state record, so the
  detached build is unaffected, and your session is intact when you exit.

It is **read-only observability** — the percent is an estimate, and the view offers
no pause / resume / cancel. Both views read one machine-readable run-state record
the runner maintains under the run's log dir.

## Design discipline (wired in)

- The **ADR index** is always loaded; full bodies are pulled on demand by Scope. Only
  `accepted` ADRs bind new TDDs; superseded ADRs drop out of context.
- **`/tdd-author` runs once per PRD update:** it diffs the PRD against the
  last-designed revision, maps existing TDD coverage, and decides how many TDDs the
  change needs (you approve the plan before it writes). It challenges the PRD,
  proposes ADR actions rather than asking open-endedly, and reads
  `docs/tdd/BLOCKERS.md` so build-time design blockers feed back into design.
- Before the design PR, an independent **design-critique gate** (the `design-reviewer`
  agent — fresh context, a different model than the author) blocks on untraced
  requirements, under-specified interfaces, ADR conflicts, a new dependency lacking
  the REQUIRED alternatives analysis, or a missing/non-actionable verification plan.
  Its verdict rides in the design PR so the human merges on an informed view.
- A TDD becomes **buildable when its design PR merges** — merging lands it on the
  integration branch at `draft`, and `/implement` builds whatever is there and not yet
  `implemented`. No manual `Status: ready` step; an un-merged draft on a design branch
  is not on integration, so the PR stays the gate.
- Stacked PRs come with an ordered, bottom-up **merge plan** in the report (merge in
  order; a squash-merge breaks the stack — use a merge commit / rebase-merge, or
  `--combined` for one squashable PR).

## Context hygiene

Skills run inside the session context, so a skill cannot `/clear` itself. Autonomous
work (investigation, test-writing) is pushed into **subagents**, which run in their
own context windows and report back summaries — so the main session stays clean
WITHOUT a manual clear. Implementation goes further: each TDD builds in its own fresh
`claude -p` process, and the verification and review gates run in yet more separate
processes, so the author never reviews itself in the same context. The interview
stages (`/prd-author`, `/tdd-author`) are interactive and can't run in a subagent, so
run each in its own fresh session and `/clear` between them.

## Relationship to superpowers & the official plugins

Throughline is a thin **governance overlay** — it does not try to own your whole
SDLC. It **depends on and delegates engineering to** the official
`claude-plugins-official` plugins (superpowers, pr-review-toolkit) rather than
competing with them
([ADR 0003](docs/adr/0003-keep-security-reviewer-in-gate.md), carrying ADR 0002
forward):

- **Superpowers owns discovery and engineering** — test-driven-development, worktrees,
  code review, the verification *mechanism*, branch finishing. **Throughline owns
  governance** — PRD/TDD/ADR as the design-of-record, requirement traceability, the
  *requirement* that verification happens, and phase-gate PRs.
- **The explicit command is the ownership signal.** Invoking `/prd-author` or
  `/tdd-author` means throughline owns that phase and will NOT also fire
  `superpowers:brainstorming` / `writing-plans`. If superpowers artifacts already
  exist (`docs/superpowers/{specs,plans}`), throughline **ingests** them instead of
  re-interviewing. With no throughline command invoked, superpowers' defaults stand.
- **Canonical docs:** `docs/PRD.md` + `docs/tdd/` + `docs/adr/` are the
  design-of-record. `docs/superpowers/*` is transient input — ingested, never
  authoritative, and never relocated (throughline leaves any existing
  `docs/superpowers/` content untouched).

For the boundary to bind reliably, add a line to your CLAUDE.md, e.g.: *"When
`/prd-author` or `/tdd-author` is invoked, that is the design step — do not also
invoke `superpowers:brainstorming` or `writing-plans` for it."*

## Requirements & dependencies

Throughline is a **layer on top of** the official plugins, not a standalone tool. It
owns the governance layer (PRD/TDD/ADR) and **delegates overlapping engineering** to
the better-maintained official plugins + built-ins, so it **requires**:

- **superpowers** — discovery (`brainstorming`) and the generic engineering skills
  (test-driven-development, worktrees, and the verification *mechanism* via
  `verification-before-completion` / `/verify`). Throughline ingests its
  `docs/superpowers/*` artifacts if present.
- **pr-review-toolkit** — code review (used on-demand via `/review-pr`, and by the
  `/implement` review gate).

Both are declared as cross-marketplace `dependencies` in `plugin.json`
(`allowCrossMarketplaceDependenciesOn: ["claude-plugins-official"]` in
`marketplace.json`), so installing throughline **auto-installs them** — *provided you
already have the `claude-plugins-official` marketplace added* (you almost certainly
do). If you don't, throughline loads with a `dependency-unsatisfied` error until you
add it:

```
/plugin marketplace add anthropics/claude-plugins-official
```

Then `/plugin install throughline@throughline` pulls throughline + its dependencies.
(Cross-marketplace dependency resolution needs Claude Code ≥ 2.1.110.) Built-in
commands throughline also leans on — `/code-review`, `/security-review`, and the
`Explore` agent — ship with Claude Code and need no install.

## Install (once per machine)

```
chmod +x hooks/format-and-lint.sh scripts/implement.sh scripts/verify.sh scripts/status.sh
bash tests/implement-gate.test.sh          # optional: prove the gates fire
bash tests/run-recovery.test.sh            # optional: prove paused/resume works
# push this dir to a private GitHub repo, then:
/plugin marketplace add <your-org>/throughline
/plugin install throughline@throughline
```

## Caveat

Plugin/marketplace JSON schemas and `/plugin` syntax evolve. Run
`claude plugin validate .` and confirm the current commands against the docs.

# throughline

A deliberately minimal Claude Code plugin for designing and building complex
software systems from the ground up. It packages the project-*invariant* layer (install once, cached under
`~/.claude/plugins/cache/` so it follows you everywhere) and a persistent
**PRD → TDD → ADR** design-doc pipeline with a build/review loop. Project-
*specific* artifacts are generated per project by the skills below.

## What's inside

```
throughline/
├── .claude-plugin/{plugin.json, marketplace.json}
├── agents/
│   ├── test-writer.md        # focused test authoring (Sonnet)
│   ├── security-reviewer.md  # security review (inherits the review gate's model)
│   ├── code-reviewer.md      # correctness/consistency review (inherits)
│   └── design-reviewer.md    # independent design critique before the design PR
├── skills/
│   ├── bootstrap-project/    # /bootstrap-project — toolchain + docs scaffold
│   ├── prd-author/           # /prd-author  — the WHAT  → docs/PRD.md
│   ├── tdd-author/           # /tdd-author  — the HOW   → docs/tdd/NNNN-*
│   ├── adr-new/              # /adr-new     — durable decisions → docs/adr/
│   └── implement/            # /implement   — build all merged TDDs, detached
├── scripts/
│   ├── implement.sh          # detached runner (fresh claude -p per TDD)
│   ├── build-prompt.md       # per-feature build discipline (failing-test-first)
│   ├── review-prompt.md      # independent review gate (separate process, diverse model)
│   └── verify.sh             # mechanical verify gate (tests + typecheck + lint)
├── tests/
│   └── implement-gate.test.sh # eval: proves the gates actually fire
└── hooks/{hooks.json, format-and-lint.sh}
```

## Pipeline

| Skill              | Produces / does          | Notes                                              |
|--------------------|--------------------------|----------------------------------------------------|
| `/bootstrap-project` | toolchain + `docs/` tree | greenfield: linter, formatter, test, git, scaffold |
| `/prd-author`      | `docs/PRD.md`            | the WHAT. Explore + interview. Own session.        |
| `/tdd-author`      | `docs/tdd/NNNN-*`        | the HOW. Runs ONCE/PRD update: diffs PRD vs prev + |
|                    |                          | existing TDDs to decide how many TDDs to write;    |
|                    |                          | challenges PRD; recommends ADR actions; runs an    |
|                    |                          | independent design-critique gate before the PR.    |
| `/adr-new`         | `docs/adr/NNNN-*`        | append-only, status-gated supersession.            |
| `/implement`       | code + tests + PR(s)     | builds every merged, unbuilt TDD (1 or many), always        |
|                    |                          | detached; gates each on test-first + verify +      |
|                    |                          | review (review on a diverse model) before flipping |
|                    |                          | to `implemented`; one PR per TDD; halts the stack  |
|                    |                          | on failure. Never merges.                          |

On-demand code review is delegated to the official plugins — use the built-in
`/code-review` or pr-review-toolkit's `/review-pr` (throughline no longer ships its
own `/review`).

Wired-in properties: ADR index always loaded, full bodies on demand by Scope;
only `accepted` ADRs bind new TDDs; superseded ADRs drop out of context;
`/tdd-author` proposes ADR actions for approval rather than asking, and reads
`docs/tdd/BLOCKERS.md` so implementation-time design blockers feed back into
design. Before opening the design PR, `/tdd-author` runs an independent
**design-critique gate** (the `design-reviewer` agent — fresh context, a different
model than the author) that blocks on untraced requirements, under-specified
interfaces, ADR conflicts, or a new dependency lacking the REQUIRED alternatives
analysis; its verdict rides in the design PR so the human merges on an informed
view. A TDD becomes buildable when its design PR MERGES — merging lands it on the
integration branch, and `/implement` builds whatever is there at `draft`/`ready`
and not yet `implemented` (no manual `Status: ready` step; an un-merged draft on a
design branch is not on integration, so the PR stays the gate). `/implement` does
NOT trust a build's self-reported success: the flip to `implemented` is gated on
THREE independent checks — failing-test-
first discipline (a `test(failing):` commit must precede the implementation),
`verify.sh` (mechanically re-runs the tests + typecheck + project linter), AND an
independent review that must return `REVIEW_RESULT: PASS`. The build runs on the
best model (opus by default) and the review runs on a DIFFERENT model (sonnet by
default), so the reviewer does not share the author's blind spots (a separate
`claude -p`, not a subagent of the author). Default is
one stacked PR per TDD; a failed gate halts the run and marks downstream TDDs
`BLOCKED` instead of building on a broken base. Every mode builds in a dedicated
git worktree, so the detached runner never touches the working tree your session
is using; each fresh worktree gets the project's dependencies installed first
(e.g. `pnpm install` / `npm ci` / `cargo` & `go` fetch on build), since a worktree
does not carry gitignored `node_modules` (`THROUGHLINE_SKIP_DEPS=1` opts out). The
verify gate is package-manager-aware (pnpm/yarn/bun/npm) and prefers the project's
own `test` / `typecheck` / `lint` scripts when declared. Because the `implemented`
flip lives on the build branch until you
merge, a re-run skips any TDD already built on an un-merged branch (no duplicate
work or PRs; `--rebuild` overrides). Stacked PRs come with an ordered, bottom-up
**merge plan** in the report (merge in order; squash-merge breaks the stack — use
a merge commit/rebase-merge, or `--combined` for one squashable PR).

## Workflow (step by step)

One-time, per repo:

```
/bootstrap-project        # toolchain + docs/ scaffold + git on main
```

Then each feature/change is one lap of the loop below. Rule of thumb: **one fresh
session per command** — `/clear` (or a new session) at every phase boundary, after
each GitHub merge and before the next command.

**1. Requirements** — *fresh session*
- `/prd-author` → interviews you, writes `docs/PRD.md`, opens a **PRD PR** (never merges).
- **GitHub:** review + **merge the PRD PR** — approves requirements; its commit is the
  baseline `/tdd-author` diffs against.
- `/clear`.

**2. Design** — *fresh session*
- `/tdd-author` → diffs the PRD, proposes the TDD set (you approve), writes TDDs as
  `draft`, self-reviews, creates ADRs (it invokes `/adr-new` itself), runs the
  independent design-critique gate, opens the **design PR** (TDDs + ADRs, verdict in
  the body; never merges).
- **GitHub:** review + **merge the design PR**. *This merge is the build trigger* — it
  lands the `draft` TDDs on `main`, which is what makes them buildable. There is no
  manual `Status: ready` step.
- `/clear`.

**3. Build** — *fresh session, on `main`, pulled current*
- `/implement` → confirms the queue (every TDD merged to `main`, not yet
  `implemented`) and the mode, then launches a **detached** runner and hands control
  back. Each TDD builds failing-test-first and must pass three gates (test-first +
  `verify.sh` + independent cross-model review) before it flips to `implemented` and
  opens a **feature PR**. Never merges. Watch
  `docs/tdd/.implement-logs/<ts>/report.md`.
- **GitHub:** review + **merge the feature PR(s)**. Sequential (default) PRs are
  *stacked* — merge **bottom-up in the report's "Merge plan" order**, with a
  merge-commit or rebase-merge (a squash breaks the stack; use `/implement --combined`
  for one squashable PR).
- `/clear` before the next lap.

Next lap: `/prd-author` *updates* the existing PRD, and the cycle repeats.

### When to `/clear`
One fresh session per command — three clears per lap (before `/tdd-author`, before
`/implement`, before the next `/prd-author`). This is safe because the state of
record lives in **git + `docs/`**, not the chat: each phase re-reads the merged
`main`, so a clear only drops the previous interview's noise. Do **not** `/clear`
*during* `/implement` — it runs detached in its own processes, so the session stays
clean on its own (you can even close the terminal).

### Feedback edges (not the happy path)
- **Design blocker at build time:** `/implement` appends infeasible/contradictory
  requirements to `docs/tdd/BLOCKERS.md` and halts → re-run `/tdd-author` (it reads
  BLOCKERS.md), merge the design PR, re-run `/implement`.
- **Partial build:** a failed gate halts the stack and marks downstream TDDs
  `BLOCKED` in the report → fix, then re-run `/implement` (it resumes the unbuilt ones).

## Context hygiene

Skills run inside the session context, so a skill cannot `/clear` itself.
Autonomous work (investigation, test-writing) is pushed into **subagents**, which
run in their own context windows and report back summaries — so the main session
stays clean WITHOUT a manual clear. Implementation goes further: each TDD builds
in its own fresh `claude -p` process, and the review gate runs in yet another
separate process, so the author never reviews itself in the same context. The
interview stages (`/prd-author`, `/tdd-author`) are interactive and can't run in
a subagent, so run each in its own fresh session and `/clear` between them.

## Relationship to superpowers & the official plugins

Throughline is a thin **governance overlay** — it does not try to own your whole
SDLC. It **depends on and delegates engineering to** the official
`claude-plugins-official` plugins (superpowers, pr-review-toolkit) rather than
competing with them ([ADR 0002](docs/adr/0002-delegate-engineering-to-official-plugins.md)):

- **Superpowers owns discovery and engineering** — `brainstorming`, TDD, worktrees,
  code review, verification, branch finishing. **Throughline owns governance** —
  PRD/TDD/ADR as the design-of-record, requirement traceability, and phase-gate PRs.
- **The explicit command is the ownership signal.** Invoking `/prd-author` or
  `/tdd-author` means throughline owns that phase and will NOT also fire
  `superpowers:brainstorming`/`writing-plans`. If superpowers artifacts already
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

Throughline is a **layer on top of** the official plugins, not a standalone tool
([ADR 0002](docs/adr/0002-delegate-engineering-to-official-plugins.md)). It owns the
governance layer (PRD/TDD/ADR) and **delegates overlapping engineering** to the
better-maintained official plugins + built-ins, so it **requires**:

- **superpowers** — discovery (`brainstorming`) and the generic engineering skills
  (TDD, worktrees, verification). Throughline ingests its `docs/superpowers/*`
  artifacts if present.
- **pr-review-toolkit** — code review (used on-demand via `/review-pr`, and by the
  `/implement` review gate as that delegation lands).

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
chmod +x hooks/format-and-lint.sh scripts/implement.sh scripts/verify.sh
bash tests/implement-gate.test.sh          # optional: prove the gates fire
# push this dir to a private GitHub repo, then:
/plugin marketplace add <your-org>/throughline
/plugin install throughline@throughline
```

## Caveat

Plugin/marketplace JSON schemas and `/plugin` syntax evolve. Run
`claude plugin validate .` and confirm the current commands against the docs.

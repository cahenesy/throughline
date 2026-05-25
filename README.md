# cc-greenfield-kit

A deliberately minimal Claude Code plugin for building complex greenfield
systems. It packages the project-*invariant* layer (install once, cached under
`~/.claude/plugins/cache/` so it follows you everywhere) and a persistent
**PRD → TDD → ADR** design-doc pipeline with a build/review loop. Project-
*specific* artifacts are generated per project by the skills below.

## What's inside

```
cc-greenfield-kit/
├── .claude-plugin/{plugin.json, marketplace.json}
├── agents/
│   ├── explore.md            # read-only investigation (Sonnet)
│   ├── test-writer.md        # focused test authoring (Sonnet)
│   ├── security-reviewer.md  # security review (inherits the review gate's model)
│   ├── code-reviewer.md      # correctness/consistency review (inherits)
│   └── design-reviewer.md    # independent design critique before the design PR
├── skills/
│   ├── bootstrap-project/    # /bootstrap-project — toolchain + docs scaffold
│   ├── prd-author/           # /prd-author  — the WHAT  → docs/PRD.md
│   ├── tdd-author/           # /tdd-author  — the HOW   → docs/tdd/NNNN-*
│   ├── adr-new/              # /adr-new     — durable decisions → docs/adr/
│   ├── implement/            # /implement   — build all ready TDDs, detached
│   └── review/               # /review      — unbiased subagent review
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
| `/implement`       | code + tests + PR(s)     | builds ALL `ready` TDDs (1 or many), always        |
|                    |                          | detached; gates each on test-first + verify +      |
|                    |                          | review (review on a diverse model) before flipping |
|                    |                          | to `implemented`; one PR per TDD; halts the stack  |
|                    |                          | on failure. Never merges.                          |
| `/review`          | consolidated findings    | fans out to security + code reviewer subagents.    |

Wired-in properties: ADR index always loaded, full bodies on demand by Scope;
only `accepted` ADRs bind new TDDs; superseded ADRs drop out of context;
`/tdd-author` proposes ADR actions for approval rather than asking, and reads
`docs/tdd/BLOCKERS.md` so implementation-time design blockers feed back into
design. Before opening the design PR, `/tdd-author` runs an independent
**design-critique gate** (the `design-reviewer` agent — fresh context, a different
model than the author) that blocks on untraced requirements, under-specified
interfaces, ADR conflicts, or a new dependency lacking the REQUIRED alternatives
analysis; its verdict rides in the design PR so the human merges on an informed
view. `/implement` does NOT trust a build's self-reported success: the
`ready -> implemented` flip is gated on THREE independent checks — failing-test-
first discipline (a `test(failing):` commit must precede the implementation),
`verify.sh` (mechanically re-runs the tests + typecheck + project linter), AND an
independent review that must return `REVIEW_RESULT: PASS`. The build runs on the
best model (opus by default) and the review runs on a DIFFERENT model (sonnet by
default), so the reviewer does not share the author's blind spots (a separate
`claude -p`, not a subagent of the author). Default is
one stacked PR per TDD; a failed gate halts the run and marks downstream TDDs
`BLOCKED` instead of building on a broken base. Every mode builds in a dedicated
git worktree, so the detached runner never touches the working tree your session
is using. Because the `implemented` flip lives on the build branch until you
merge, a re-run skips any TDD already built on an un-merged branch (no duplicate
work or PRs; `--rebuild` overrides). Stacked PRs come with an ordered, bottom-up
**merge plan** in the report (merge in order; squash-merge breaks the stack — use
a merge commit/rebase-merge, or `--combined` for one squashable PR).

## Context hygiene

Skills run inside the session context, so a skill cannot `/clear` itself.
Autonomous work (investigation, test-writing) is pushed into **subagents**, which
run in their own context windows and report back summaries — so the main session
stays clean WITHOUT a manual clear. Implementation goes further: each TDD builds
in its own fresh `claude -p` process, and the review gate runs in yet another
separate process, so the author never reviews itself in the same context. The
interview stages (`/prd-author`, `/tdd-author`) are interactive and can't run in
a subagent, so run each in its own fresh session and `/clear` between them.

## Install (once per machine)

```
chmod +x hooks/format-and-lint.sh scripts/implement.sh scripts/verify.sh
bash tests/implement-gate.test.sh          # optional: prove the gates fire
# push this dir to a private GitHub repo, then:
/plugin marketplace add <your-org>/cc-greenfield-kit
/plugin install greenfield@cc-greenfield-kit
```

## Caveat

Plugin/marketplace JSON schemas and `/plugin` syntax evolve. Run
`claude plugin validate .` and confirm the current commands against the docs.

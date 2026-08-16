# Product Requirements: throughline

> Retroactively authored to capture the system's existing functionality as the
> design-of-record baseline. New capabilities are added from here via the normal
> `/prd-author` → `/tdd-author` → `/build-tdds` flow.
>
> **This update (thin dual-harness overlay):** throughline remains a governance
> overlay — PRD → TDD → ADR, phase-gate PRs, four independent gates, human merge.
> It is no longer a Claude-only process supervisor. Authoring and `/build-tdds`
> work on Claude Code and on Grok Build. How a worker is started, whether it
> survives session close, and how the human watches it are harness-native and
> need not match. Supervisor-specific requirements (detached `claude -p`,
> stream-json sentinels, STEP_COMMIT coprocess, live-follow, continuous
> per-step review, automatic in-invocation rework) are retired; see Non-goals
> and the retired-FR list under Requirements.
>
> **This update (model capability by job):** review independence is a fresh
> worker, not a different named model. Judgment work (author PRDs and TDDs,
> write and review code and tests, review designs, classify `/build-tdds`
> halts) defaults to the most capable model on the harness. The only cheap
> model slot is mechanical runtime-verify (FR-52). A parent session that is
> below that default, or whose model cannot be read, warns and asks
> continue/stop.

## Problem & context

Building complex software with AI coding agents tends to lose the *design* and the
*decisions*: requirements and architectural rationale live in transient chat, "done"
is self-reported, and implementation is ungated. Generic engineering discipline (TDD,
code review, worktrees) is well covered by harness plugins (Superpowers and
similar), but those provide no persistent, traceable system of record for *what*
is being built and *why*.

throughline is a thin **governance overlay** for AI coding harnesses: a persistent
PRD → TDD → ADR design-doc pipeline with phase-gate PRs and gated implementation.
It owns governance and traceability. It **delegates** discovery and generic
engineering when the harness provides them; those delegates are optional, not
install-blocking (see FR-22, FR-83).

Two principles run through that overlay. First, **verification is runtime
observation at the surface** — confirming the *real artifact* behaves where a user
(human or programmatic) meets it — which is distinct from tests/typechecks (CI's
job); throughline carries verification from the PRD forward, not as an
afterthought, while leaving the verification *mechanism* to the project. Second,
**"done" is never the author's say-so** — a TDD flips to `implemented` only when
four independent observations hold, recorded as artifacts, not as a parse of a
model transcript.

## Users & goals

- **Primary user:** a developer using Claude Code and/or Grok Build who wants
  design-docs-before-code discipline, an auditable thread from requirement →
  design → decision → implementation, and gated builds — without re-implementing
  the generic engineering layer and without owning a second coding harness.
- **Success looks like:** every shipped change traces to an approved requirement and
  design; architectural decisions are recorded and binding; no code is marked "done"
  on self-report; the human stays in control via a merge gate at each phase; the
  same loop is invocable on Claude Code and on Grok Build.

## Requirements

Functional requirements (FR) and non-functional requirements (NFR), each
independently verifiable.

### Setup
- **FR-1 Toolchain bootstrap.** `/bootstrap-project` detects the primary language and
  ensures a linter, formatter, and test framework are configured (defaults: JS/TS
  prettier+eslint+vitest; Python ruff+pytest; Rust rustfmt+clippy+cargo test; Go
  gofmt+golangci-lint+go test).
- **FR-2 Greenfield vs brownfield handling.** On an empty project it installs and
  configures the defaults and writes one trivial passing test; on an existing project
  lacking tooling it does NOT silently install — it flags and asks first; existing
  tooling is reused, not swapped.
- **FR-3 Docs scaffold + git init.** It scaffolds `docs/PRD.md` (stub),
  `docs/adr/INDEX.md`, `docs/tdd/`, and a `docs/README.md` (canonical-vs-transient
  note), then initializes git on `main`.

### Install/update lifecycle hygiene
Two state layers can drift independently between bootstrap and "now": **repo
state** (shared with teammates via git: configs, scaffolds, ignore rules) and
**local-developer environment** (per-machine: installed binaries, dependency
state). Bootstrap is re-runnable, a post-update reconciliation hook catches
plugin updates, and consumer repos do not accumulate plugin-generated noise.

- **FR-31 Bootstrap state marker (committed).** `/bootstrap-project` writes and
  maintains a committed marker `docs/.throughline-bootstrap.json`
  (`{schema, plugin_version_applied, language, repo_steps_applied: [...],
  applied_at}`). Re-running bootstrap reads the marker, short-circuits steps
  already recorded as applied, and re-applies only what is missing or out of
  date. — Acceptance: running `/bootstrap-project` on a freshly-bootstrapped
  repo prints a line of the form `already bootstrapped at <plugin_version>` and
  performs no installs, no scaffold writes, and no `git init`; the marker file
  is byte-identical before and after.
- **FR-32 Consumer-repo `.gitignore` management.** Bootstrap ensures the
  consumer repo's `.gitignore` ignores throughline's per-run artifacts —
  minimally `docs/tdd/.implement-logs/` — adding the entry (and creating
  `.gitignore` if absent) idempotently. No other path is added; design state
  (`docs/PRD.md`, `docs/tdd/0*.md`, `docs/adr/`, `docs/tdd/BLOCKERS.md`,
  `docs/.throughline-bootstrap.json`) remains tracked. — Acceptance: after
  bootstrap, `git check-ignore -q docs/tdd/.implement-logs/anything.log` exits
  0 and `git check-ignore -q docs/tdd/BLOCKERS.md` exits 1; re-running bootstrap
  leaves the `.gitignore` file byte-identical.
- **FR-33 Per-developer local-env marker.** A per-machine marker at
  `${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json`
  (`{schema, plugin_version_seen, local_steps_completed: [...], updated_at}`)
  records the local-environment work the current developer has applied for this
  repo. It is written by `/bootstrap-project` on completion and read by the
  post-update hook (FR-34). The `<repo-id>` is derived deterministically from
  the repo's remote URL, falling back to its absolute path. — Acceptance: after
  a successful local `/bootstrap-project`, the local marker exists with
  `plugin_version_seen` equal to the currently-installed plugin version;
  reading it from a second machine for the same repo shows that machine's
  independent state, not the first machine's.
- **FR-34 Post-update reconciliation hook.** A `SessionStart` hook (or the
  harness equivalent) reconciles the two markers against the running plugin
  version without launching a coding agent: (a) in a repo lacking
  `docs/.throughline-bootstrap.json` it exits silently with no output; (b) on
  a repo-marker version mismatch it re-applies the cheap idempotent
  repo-side steps (`.gitignore` entry per FR-32; any missing docs-scaffold
  files per FR-3) and bumps `plugin_version_applied`; (c) on a local-marker
  mismatch *and* a release flagged local-impacting (FR-35) it attempts one
  session-start notice of the form `throughline updated <old>→<new>; run
  /bootstrap-project to refresh your local toolchain` (best-effort: a
  harness that ignores SessionStart stdout is not a defect), then updates
  `plugin_version_seen`. The hook never installs software, never spawns an
  agent, and never edits files outside the contract above. — Acceptance: on
  a repo without the bootstrap marker, the hook produces no output and
  modifies no files at session start; on a repo with a stale marker and a
  non-local-impacting plugin update, the next session's `.gitignore`
  contains the `docs/tdd/.implement-logs/` entry and the marker's
  `plugin_version_applied` equals the running plugin version.
- **FR-35 Release metadata: local-impacting flag.** The plugin declares per
  release whether the change requires developer-local action (e.g. a new
  toolchain dependency, an incompatible deps bump). The post-update hook
  (FR-34) reads this metadata to decide whether to surface the local notice
  — without it, every version delta would notify and the signal would be
  noise. — Acceptance: a release published with the local-impacting flag set
  causes the FR-34 notice on the next session-start after update; a release
  published without the flag set does not, even though the repo and local
  markers both register the version delta.

### Requirements authoring
- **FR-4 PRD of record.** `/prd-author` produces/updates `docs/PRD.md` — the WHAT and
  WHY only (no architecture, tech choices, or implementation). Requirements are
  numbered and independently testable; it records non-goals, constraints, and open
  questions, leaving unresolved items open rather than inventing answers.
- **FR-5 PRD rigor.** It runs a scope-decomposition check (split multi-product asks),
  applies YAGNI, ensures each requirement carries an observable acceptance criterion
  (see FR-24), and runs an inline self-review (placeholder / consistency / scope /
  ambiguity / missing-acceptance-criterion) before opening the PR. (The interview
  discipline that precedes this rigor pass is specified by FR-75.)
- **FR-6 PRD phase gate.** It commits to a `docs/prd/<slug>` branch and opens a PRD
  PR; it never auto-merges (the human merge approves requirements and anchors the
  diff the design step reads).

### Design authoring
- **FR-7 Delta-driven design.** `/tdd-author` runs once per PRD update: it establishes
  the previously-designed PRD revision (`PRD-rev` in the latest TDD), diffs the PRD,
  maps existing TDD coverage, and decides the set of TDDs the change needs —
  presenting that plan for approval before writing.
- **FR-8 TDD content + traceability.** Each TDD is written `Status: draft` with a
  requirement-traceability table (every in-scope FR/NFR → design element), a
  "dependencies considered" section requiring ≥1 concrete rejected alternative per new
  dependency, a verification plan (see FR-23), and no placeholder / hand-waving design
  content.
- **FR-9 ADR evaluation + creation.** `/tdd-author` evaluates the design against
  existing ADRs and, on approval, records durable decisions via `/adr-new`. Only
  `accepted` ADRs bind new TDDs.
- **FR-10 Self-review + independent design-critique gate.** Before opening the design
  PR it self-reviews, then spawns the `design-reviewer` in a fresh context that is
  not the author's session (NFR-3). The reviewer defaults to the most capable
  model on the harness; it is not required to use a different model name than
  the author. It blocks on untraced requirements, under-specified interfaces, a
  missing alternatives analysis, a missing or non-actionable verification plan
  (see FR-23), or ADR conflicts; the verdict rides in the PR body. — Acceptance:
  a design PR whose critique verdict was produced in the `/tdd-author` parent
  session does not satisfy this gate; a design PR whose critique worker used
  the same model name as the parent is not rejected for that reason.
- **FR-11 Design phase gate.** It commits the TDD set + any promoted ADRs together on
  a `docs/design/<slug>` branch and opens the design PR; it never auto-merges.

### Decisions
- **FR-12 Append-only ADRs.** `/adr-new` records decisions to `docs/adr/NNNN-*` with a
  status (`proposed` | `accepted` | `superseded by NNNN`) and maintains `INDEX.md`. An
  accepted ADR is never edited in substance — a change is a new ADR that supersedes
  the old one, flipping only its status line.

### Implementation
- **FR-13 Merge-triggered build.** `/build-tdds` builds every TDD merged to the
  integration branch and not yet `implemented`; the design-PR merge is the build
  trigger — there is no manual `Status: ready` step. A path argument builds one TDD.
  — Acceptance: invoking `/build-tdds` on a repo whose integration branch has one
  merged `draft` TDD and no `implemented` TDD queues that TDD; a TDD that exists
  only on an unmerged design branch is not queued.
- **FR-14 Isolated, harness-native execution.** Each TDD build runs in a dedicated
  git worktree so it never commits in the live working tree the human session is
  using. How the implementer process is started is harness-native and is not
  required to survive session close or to match across harnesses. Modes:
  sequential (default; stacked, one PR per TDD), `--combined` (one PR),
  `--parallel` (one worktree/PR per feature). — Acceptance: after a `/build-tdds`
  run, `git -C <human-workdir> status` is clean of the build's commits; those
  commits exist on a worktree branch; the human worktree's current branch is
  unchanged.
- **FR-15 Four independent gates.** A TDD flips to `implemented` only after (a)
  failing-test-first discipline — a `test(failing):` commit precedes the
  implementation, observed from `git log` (the build follows
  `superpowers:test-driven-development` when that skill is present); (b) a
  mechanical `ci-checks.sh` re-run of tests + typecheck + linter (this is CI's
  job — running tests, not verification); (c) runtime verification — the real
  artifact is driven to where the change is observable and the TDD's verification
  observations hold (see FR-25); and (d) an independent review produced in a
  context that is not the author's (NFR-3), written as an
  artifact that reads `PASS` or `FAIL` (see FR-82). The reviewer defaults to
  the most capable model on the harness; a different model name than the
  implementer is not required. Named review plugins
  (pr-review-toolkit, throughline security-reviewer, Superpowers reviewers) are
  used when present; they are not required to flip. Self-reported success is not
  trusted. — Acceptance: a TDD whose review artifact is missing or not `PASS`
  does not flip to `implemented`; a TDD whose `git log` has no preceding
  `test(failing):` commit (and no recorded skip) does not flip.
- **FR-16 Never merges; halt-on-failure.** `/build-tdds` opens PRs but never
  merges. A failed gate (after any in-gate transient retry, FR-42) halts that
  TDD. In sequential mode the run marks downstream TDDs `BLOCKED` rather than
  building on a broken base. There is no requirement that the same invocation
  automatically rework the finding. — Acceptance: no merge commit is created by
  `/build-tdds`; a sequential run whose first TDD fails a gate leaves later TDDs
  `BLOCKED` and unbuilt.
- **FR-17 Design-blocker feedback loop.** A requirement that proves infeasible or
  self-contradictory at build time is recorded to `docs/tdd/BLOCKERS.md` (a `BLOCKED`,
  not a `FAIL`) for `/tdd-author` to resolve in the next design pass.
- **FR-18 Resume safety + single-run lock.** A TDD already `implemented` on an
  existing un-merged branch is skipped (no duplicate work or PRs; `--rebuild`
  overrides), and a single-run lock prevents a second concurrent `/build-tdds` on the
  same repo.
- **FR-19 Report + merge plan.** Each run writes a report with per-TDD status and log
  paths and, in sequential mode, an ordered bottom-up merge plan that warns a
  squash-merge breaks the stack.
- **FR-20 Worktree dependency install.** Each fresh build worktree installs the
  project's dependencies first (package-manager-aware) since a worktree carries no
  gitignored `node_modules`; opt out with `THROUGHLINE_SKIP_DEPS=1`.

### Verification (runtime observation at the surface)
Verification — confirming the *real artifact* behaves where a user (human or
programmatic) meets it — is distinct from tests/typechecks (CI's job) and is carried
from the PRD forward. throughline owns the *governance* of verification; the
*mechanism* is the project's.

- **FR-23 TDD verification plan.** Each TDD includes a verification plan: the change's
  observable surface, the observation points (scenarios that drive the changed code to
  where it executes), and the invariants / expected observations that constitute PASS.
  It is artifact-appropriate (CLI stdout, HTTP responses, library return values, log
  lines, DOM, …); the mechanism is delegated (FR-26). — Acceptance: a TDD lacking a
  verification plan fails FR-10's design-critique gate.
- **FR-24 PRD observable acceptance criteria.** Each PRD requirement carries an
  acceptance criterion phrased as an observation of the real artifact's surface, not
  "a test exists"; `/prd-author` enforces this for new requirements (FR-5). —
  Acceptance: every requirement added at or after this update states an observable
  acceptance criterion (this update's FR-23–FR-30 included).
- **FR-25 Runtime-verification gate.** `/build-tdds` runs a verification gate distinct
  from `ci-checks.sh`: it drives the built artifact to where the change is observable and
  confirms the TDD's verification observations hold, capturing the evidence. A TDD
  flips to `implemented` only if verification is PASS — passing tests alone is
  insufficient. A change with genuinely no observable surface (e.g. an internal
  refactor) may be recorded `SKIP` with justification, never silently (NFR-4). —
  Acceptance: a TDD whose runtime verification is FAIL or BLOCKED does not flip to
  `implemented` and is reported as such.
- **FR-26 Verification is governed, not bundled.** throughline owns the *requirement*
  that a verification plan exists (FR-23), is executed, and yields evidence (FR-25); it
  does not ship a verification harness/framework. The mechanism is delegated to the
  project and to `superpowers:verification-before-completion` / the `/verify` skill
  (FR-22, ADR 0002). — Acceptance: no verification framework is vendored into consumer
  repos by throughline.
- **FR-78 Per-requirement test-coverage map.** For each TDD that lands, throughline
  produces a verification-status map of every requirement in *that TDD's scope*,
  classifying each as exactly one of: **pinned** (a test that exists today asserts
  it), **proposed** (a test is recommended or planned but does not yet assert it),
  **justified-no-surface** (no observable surface to verify — a recorded `SKIP` per
  FR-23/FR-25), or **unverified gap** (an observable requirement that no test
  asserts). The map cannot read falsely-green: a requirement whose only verification
  is a not-yet-written or non-asserting test is never shown as `pinned`, and a
  requirement legitimately lacking an observable surface is shown as
  `justified-no-surface`, never as a gap (NFR-4 honesty). The map is *surfaced for
  the human review* at the PR gate; an unverified gap is a visible finding, **not**
  an automatic flip-blocker — the four gates of FR-15 remain the sole automatic
  flip authority. This closes the gap FR-15(a)/FR-23/FR-71 leave: FR-15(a) gates
  that a test *precedes* implementation (per-commit discipline, not per-requirement
  coverage); FR-23 states *intended* observation points (design intent, pre-build);
  FR-71 reports the actual diff and scope (not per-requirement verification status).
  Scope is the landing TDD's in-scope requirements; a retroactive whole-system audit
  of pre-existing requirements is out of scope. — Acceptance: for a landed TDD, an
  artifact lists each in-scope FR/NFR with exactly one of {`pinned`, `proposed`,
  `justified-no-surface`, `unverified-gap`}; a requirement that no test asserts reads
  `proposed` or `unverified-gap`, never `pinned`; and a requirement with no
  observable surface reads `justified-no-surface`, never `unverified-gap`.

### Run progress visibility
- **FR-27 Durable run record.** A `/build-tdds` run maintains a structured,
  machine-readable on-disk record of run state — per TDD: queue position, status
  (pending / building / verifying / reviewing / done / failed / blocked /
  skipped / paused), current stage, halt cause if any, and timestamps; plus a
  run-level rollup. This record is the source of truth for resume (FR-39) and
  for `/implement-status`. — Acceptance: after any status change, reading the
  on-disk record shows that TDD's new status; a crash mid-write leaves each
  fragment parseable as either the prior or the new state (FR-44).
- **FR-28 Progress snapshot.** `/implement-status` prints an on-demand snapshot
  from FR-27: completed / total TDDs, an estimate-labeled percent, the current
  TDD and stage, per-TDD statuses, elapsed time, and log / PR pointers. —
  Acceptance: invoking it during a run prints a summary matching FR-27's
  record; invoking it with no active run says so plainly.
- **FR-29 Live follow mode.** *Retired.* A continuously refreshing follow view
  is not required. The snapshot (FR-28) is the required visibility surface.
  Harness-native watch (if any) is out of throughline's requirements.
- **FR-30 Honest, read-only progress.** The percent is presented as an estimate,
  never implying deterministic precision (NFR-4); `/implement-status` is
  read-only and does not control the run (no pause / resume / cancel). —
  Acceptance: the snapshot never reports 100% before all in-scope TDDs are
  terminal, and offers no run-control action.

### Build observability & safety boundaries
*FR-36, FR-37, and FR-38 are retired.* They existed to make a `claude -p`
coprocess observable and to keep the build process from killing its parent.
Gate honesty is now FR-15 + FR-70 + FR-82 (artifacts, not transcript
pointers). Prompt-level "don't pkill your parent" is not a product
requirement.

- **FR-36 Gate-log session pointer.** *Retired.* No requirement to point at
  `~/.claude/projects/…` JSONL or to parse stream-json.
- **FR-37 Build-phase boundaries.** *Retired.*
- **FR-38 Cleanup safety in runtime-verify.** *Retired.*

### Run recovery & restart resilience
Long-running and interactive throughline flows can be interrupted. Restarting
from scratch on each interruption burns tokens and erases detail already
elicited. Continuity is from the last **artifact** (run record, draft file,
committed build-branch history) forward.

#### Detached `/build-tdds` runs
- **FR-39 Interrupted-run detection.** Re-invoking `/build-tdds` after a prior
  run did not exit cleanly recognizes that prior run from its persisted
  record (FR-27) and surfaces it before doing any work, identifying which TDD
  and which gate it was at and why it stopped. The user decides whether to
  resume or start fresh; the runner does not act silently. — Acceptance:
  launching `/build-tdds` after a prior run is killed mid-build prints a
  one-line summary naming the interrupted TDD and gate and waits for
  resume/fresh before any build work; launching with no non-terminal prior
  run proceeds without prompting.
- **FR-40 Gate-level resume.** On resume, the run continues the interrupted
  TDD at the first of the four gates (FR-15) that does not have a completed
  artifact; gates that completed are not re-run. The persisted run record
  (FR-27) plus the gate verdict files (FR-82) are the source of truth —
  including the build gate, whose completion is recorded only when its
  verdict artifact says the build completed. Partial commits on the build
  branch are NOT evidence of build-gate completion. The build branch's
  committed history is the source of truth for the build gate's *output
  content*. — Acceptance: a TDD interrupted after gate 2 and before gate 3,
  when resumed, produces no new gate-1 or gate-2 artifacts; the build
  branch HEAD contains the same gate-1 commits as before the interruption.
- **FR-41 Recoverable-cause classification.** The run distinguishes
  recoverable causes (usage-limit / ratelimit, transient network/API error)
  from fatal causes (genuine FAIL verdict, malformed verdict, unexpected
  error). Recoverable causes halt into a *paused* state that FR-39 can
  detect and resume; fatal causes follow FAIL (FR-16, FR-17) and are not
  auto-resumed. — Acceptance: a run terminated by a simulated usage-limit
  leaves FR-27 in a paused, resumable shape distinguishable from `failed`;
  a fatal cause does not trigger the resume prompt.
- **FR-42 Bounded in-gate retry on transient errors.** A transient error
  during a gate (FR-41) is retried within the gate a bounded number of times
  before promoting to a paused halt. — Acceptance: a gate that fails
  transiently then succeeds within budget produces a single PASS artifact,
  with intermediate errors recorded; exhausting the budget leaves FR-41
  paused, not `failed`.
- **FR-43 Stale single-run lock reclaim.** The FR-18 lock is reclaimed when
  its prior owner is no longer alive. A live lock owner still blocks a
  second run. — Acceptance: after a prior `/build-tdds` is killed, the next
  proceeds without manual lock cleanup; while it is alive, a second
  `/build-tdds` refuses.
- **FR-44 Persisted-state durability.** The run record (FR-27) remains
  parseable at any point; a reader never observes half-written state. —
  Acceptance: reading every fragment at arbitrary points yields valid
  content; a forced mid-transition interrupt leaves each fragment showing
  either the prior or the new state.
- **FR-45 Paused status in the progress view.** `/implement-status`
  surfaces a paused run distinctly from `building`, `failed`, `blocked`,
  and `done`, and points at the re-invocation that will resume. NFR-4:
  paused is never reported as `failed`, and vice versa. — Acceptance:
  `/implement-status` on a paused run includes the word "paused", the
  recoverable cause, and an instruction to re-run `/build-tdds` to resume.

#### Interactive `/prd-author` and `/tdd-author` sessions
- **FR-46 Incremental persistence of elicited interview detail.** While
  `/prd-author` and `/tdd-author` interview the user, the substantive detail
  elicited (answered questions, requirements drafted, ADR actions proposed)
  is persisted incrementally to a transient draft as the interview proceeds,
  so an interruption between elicitation and the final committed doc is
  recoverable. Persistence is per substantive elicitation, not buffered until
  the end. — Acceptance: after answering several questions in `/prd-author`
  and then killing the session, a draft file exists in the working tree
  containing all answered detail from before the kill; killing the session
  before any answered elicitation leaves no orphaned draft.
- **FR-47 Restart detects and offers to resume from draft.** On re-invocation,
  `/prd-author` and `/tdd-author` detect a draft left by an earlier
  interrupted session and offer to resume from it (rehydrating detail the new
  session would otherwise re-elicit) before starting a fresh interview. The
  user may decline; declining starts fresh and discards the prior draft.
  — Acceptance: re-running `/prd-author` after the kill from FR-46 prompts
  the user to resume with a one-line summary of the draft's scope (timestamp
  and how much detail it contains); confirming resume causes the continued
  interview to build on the elicited detail rather than re-ask for it.
- **FR-48 Draft survives intra-session compaction.** When automatic context
  compaction occurs *within* a still-running interactive skill session,
  detail elicited and persisted to the draft (FR-46) before the compaction
  is recovered into the post-compaction working state. The skill does not
  silently lose interview detail to compaction. — Acceptance: in a session
  where compaction occurs after several elicitations, the final committed
  PRD/TDD reflects the pre-compaction elicitations (verifiable by content
  match against the draft's prior state), not only the post-compaction-visible
  turns.
- **FR-49 Draft lifecycle bounded by skill completion.** A draft from
  `/prd-author` or `/tdd-author` is removed when the skill completes its
  normal path (opening the PRD / design PR per FR-6 / FR-11) and persists
  otherwise. Drafts are transient interview state, not project artifacts;
  they are never committed to version control. — Acceptance: after a normal
  `/prd-author` completion that opens the PRD PR, no draft is left in the
  working tree; after killing `/prd-author` mid-interview, a draft is present
  in the working tree; in either scenario `git ls-files` shows no tracked
  draft files.
- **FR-50 Design-reviewer is not cached across sessions.** When `/tdd-author`
  resumes from a draft, the design-reviewer (FR-10) is run fresh on the
  restored design, not reused from any prior session's verdict. Reviewer
  independence is a fresh worker (NFR-3), not a different model name, and is
  preserved across resumption. — Acceptance: a `/tdd-author` session that resumes after the
  prior session's design-reviewer had already produced a verdict opens a
  design PR whose body carries a freshly-issued reviewer verdict
  (timestamped after the resume), not the prior session's verdict.

### Token-spend reduction
LLM-driven gates dominate throughline's per-flow token cost. Two targeted
reductions cut that cost without weakening any gate's judgment: shift cheap
structural checks left of the LLM design-reviewer so it spends its judgment
where a model is irreplaceable, and pick the smallest capable model for the
runtime-verify gate based on the verification plan's complexity. Neither
relaxes verdict honesty (NFR-4); both are reversible per-run via env overrides.

- **FR-51 Mechanical pre-pass before LLM design-reviewer.** Before invoking the
  design-reviewer subagent (FR-10), `/tdd-author` runs a mechanical pre-pass
  that detects structural-gap findings — missing required sections, missing
  frontmatter, placeholder strings, untraced FR/NFR. On any blocker- or
  major-severity finding the skill BLOCKs without invoking the design-reviewer
  (the LLM gate is not invoked on a structurally-broken TDD set); on clean exit
  the reviewer is invoked normally and judges the irreplaceable findings
  (scope coherence, interface vagueness, ADR conflicts, naming consistency).
  Findings the pre-pass missed remain visible: the reviewer surfaces any
  structural gap it notices as a nit, never silently. — Acceptance: running
  `/tdd-author` against a TDD set with a missing `## Verification plan`
  produces no `Task` tool call to `design-reviewer` in the session transcript
  and surfaces the missing-section finding to the user directly; running
  `/tdd-author` against a structurally-clean TDD set DOES invoke the
  design-reviewer (its `Task` tool call is present in the transcript) and the
  reviewer runs normally.
- **FR-52 Verification-gate model tiering.** The runtime-verify gate (FR-25)
  is run on a model the runner picks based on the TDD's verification plan:
  mechanical observations (CLI exit code, log line grep, file presence, HTTP
  status code) run on a cheaper model — this is the only job that defaults
  off the most-capable model (NFR-3); verification plans requiring
  browser/UI driving, multi-step interactive flows, or judgment about
  ambiguous outputs run on the most-capable default. The tier is the
  requirement and the concrete model binding is an implementation default,
  pinnable unconditionally via `THROUGHLINE_RUNTIME_VERIFY_MODEL`.
  The tiering preserves NFR-4 verdict
  honesty unconditionally — neither model is permitted to emit a false PASS
  on a verification it could not actually observe. — Acceptance: the per-TDD
  log records `runtime-verify model=<m> (plan=<cls>)` before each
  runtime-verify worker; for a TDD with a mechanical verification plan
  `<m>` is the runner's cheaper-tier default (or the env-pinned value);
  for a TDD with a nontrivial
  plan `<m>` is the most-capable default (or the env-pinned value); for a
  TDD whose mechanical plan describes
  an observation the artifact fails, the verdict line is
  `VERIFY_RUNTIME: FAIL` (not a false PASS).

### Bounded scope and trustworthy reporting
Design-time scope stays bounded (Theme A). Gate decisions rest on
independently verifiable artifacts and reports are honest about what
changed (Theme D). Continuous per-step review and automatic in-invocation
rework (former Themes B and C) are **retired** — they required a
throughline-owned supervisor. Review is the FR-15(d) flip-time pass;
rework is a human-driven next `/build-tdds` or a design revision, not an
in-invocation loop.

NFR-1's human control is at phase boundaries (PRD PR merge, design PR
merge, implementation PR merge).

#### Bounded change size (Theme A)
- **FR-53 TDD scope bound (size + per-file impact).** Each TDD describes a
  change small enough that a single review pass can hold the proposal in
  working memory and a single build session can execute it without thrashing.
  The bound is measured on two surfaces: (a) the TDD document's own size, and
  (b) an expected-diff-size estimate the TDD declares per touched source file.
  The bound is escapable per-TDD with an explicit justification recorded in
  the TDD itself; declared exceptions cover generated files, lockfiles, and
  legitimately-wide-but-shallow edits. — Acceptance: TDDs converge to
  `implemented` without `/tdd-author` having to be re-run mid-build to revise
  scope.
- **FR-54 Design-time refusal of over-ambitious per-file change.** A TDD that
  demands more change in a single touched source file than the per-file bound
  (FR-53) without a declared, justified exception is refused at design time
  rather than discovered as a problem at build time. — Acceptance: no merged
  TDD produces a build that fails on grounds of file complexity that were
  predictable from the design (i.e., observable from the TDD's declared
  expected-diff-size estimate and its touched-file list).
- **FR-55 Scope-check authority of the design-critique gate.** The design
  phase detects over-ambitious scope before the design PR opens, not after
  implementation begins. The design-critique gate (FR-10) is the authority
  for scope concerns; if it does not flag a scope concern, the build does not
  halt on one. — Acceptance: the design-critique gate's verdict cites scope
  concerns when they exist; no build halts on a scope concern the design
  phase missed (i.e., a scope-related halt at build time is itself a defect
  in the design-critique gate, not normal operation).

#### Retired: continuous review and automatic rework
- **FR-56** *Retired.* Continuous in-build review is not required. Flip-time
  review (FR-15(d)) is the required review.
- **FR-57** *Retired.*
- **FR-58** *Retired* as a rework trigger. Review artifacts may still carry
  severity; only FR-15(d) `PASS`/`FAIL` flips.
- **FR-59** *Retired.*
- **FR-60** *Retired* as a required author self-review pass. Optional.
- **FR-61** *Retired.* Halting findings do not trigger an in-invocation loop.
- **FR-62** *Retired.* No automatic in-invocation rework.
- **FR-63 Halt taxonomy: human-needed only.** Every halt recorded in the
  run record (FR-27) carries an explicit, enumerated cause explaining why
  human attention is required — e.g. design escalation (FR-67), recoverable
  pause (FR-41), scope concern surfacing post-design (defect in FR-55), or
  external blocker (FR-17). — Acceptance: every halt event in any
  `/build-tdds` run record cites a value from a closed enum of human-needed
  causes; no halt event cites a non-enumerated or process-ended cause.
- **FR-64 One-screen halt context.** `/implement-status` on a halted run
  presents the halt cause, the triggering finding or decision, and the
  available next actions on a single screen. — Acceptance: on any halted
  run, `/implement-status` output fits one terminal screen (≤ 24 lines × 80
  cols by default) and contains the cause label, the triggering finding or
  decision, and the next-action options.
- **FR-65** *Retired.* No rework-budget requirement.
- **FR-66** *Retired.*
- **FR-67 Structural-finding escalation, not local sweep.** When a review
  or build finds that a correct fix would (a) touch files outside the TDD's
  declared touched-file set (FR-53), (b) exceed the TDD's per-file bound,
  or (c) require reconsidering the design itself (the reviewer must name
  the design reconsideration), the TDD is `BLOCKED` with a
  `docs/tdd/BLOCKERS.md` entry — not a silent scope expansion. — Acceptance:
  a finding meeting (a), (b), or named (c) results in `BLOCKED` and a
  BLOCKERS.md entry naming the TDD, the gate, and the trigger; the TDD
  does not flip to `implemented`.
- **FR-68** *Retired.*

#### Trustworthy reporting and a tractable codebase (Theme D)
- **FR-69 Throughline holds itself to Theme A.** The shell scripts and
  skill prompts throughline ships obey the scope bounds throughline
  enforces on its users' TDDs (FR-53, FR-54). Files in the
  throughline codebase that exceed those bounds are first refactored
  to compliance via a Theme D TDD before any new Themes B / C
  behavior ships, so subsequent behavior-change TDDs land on a
  compliant base. The escape clause from FR-53 (per-TDD justification
  for legitimate exceptions) applies to throughline's own TDDs as
  well. — Acceptance: after the Theme D refactor lands, no shell
  script (`scripts/*.sh`) or skill prompt (`skills/*/SKILL.md`)
  throughline ships is in a state that, if proposed via a new TDD
  authored under FR-53, would be rejected for scope under FR-54
  without a recorded exception.
- **FR-70 Gate decisions grounded in verifiable artifacts only.**
  Decisions made by gates (design-critique, mechanical pre-pass,
  in-build review, runtime-verify) rest on facts independently
  reproducible from the design + run artifacts — git history, the
  TDD itself, and the run-state record — not on the author's
  self-report about its own work. Any scope or progress claim a gate
  acts upon is reproducible from those artifacts without consulting
  the author. — Acceptance: every halt-causing or rework-causing
  claim in any run's report is reproducible from `git log`,
  `git diff`, the TDD file, and the run-state record alone (i.e., a
  re-verifier with only those four inputs reaches the same verdict).
- **FR-71 Honest report: actual diff and scope, not narrative.** The
  per-run report and run-state record reflect the actual diff size
  and scope of work the build performed, not the author's narrative
  summary; discrepancies between the author's narrative and the
  ground truth are surfaced as `major` review findings (i.e., they
  trip FR-58's halt boundary and FR-61's rework loop), not silently
  recorded. — Acceptance: for any build that produced a narrative
  summary, a diff-vs-narrative discrepancy (e.g., narrative claims
  three touched files but `git diff` shows seven) appears in that
  build's review log as a `major` finding; the run-state record's
  per-TDD scope metrics reflect the git-derived ground truth (not
  the narrative).

### Build-phase learning capture

throughline runs build after build, accumulating evidence in review logs and
run-state records, but that evidence is currently discarded at run-end: the
same categorical review-finding patterns can recur across TDDs because there is
no feedback path from build artifacts back to the design phase. BLOCKERS.md
captures structural infeasibilities (FR-17) but not recurring quality patterns
that the design phase could have anticipated. These requirements close that gap
by surfacing recurring patterns to the human for review, and persisting the
approved subset as forward context for future design sessions.

- **FR-72 Candidate-learning surface after run.** After a `/build-tdds` run
  completes (all in-scope TDDs in a terminal state), the run surfaces any
  recurring patterns detected across the run's artifacts — review findings,
  rework outcomes, structural escalations — as candidate learnings for human
  review. A pattern is surfaced when it appeared in the same categorical class
  across more than one TDD or build step in the run. The human reviews the
  candidates and marks each as accepted or discarded; discarded candidates are
  not persisted. — Acceptance: after any `/build-tdds` run whose review and
  rework records show the same categorical finding class across two or more
  TDDs, the run surfaces a candidate-learnings report naming those patterns, the
  TDDs each appeared in, and a prompt for the human to accept or discard each
  candidate; completing that review persists exactly the accepted subset and
  discards the rest; a run whose records contain no such recurring patterns
  produces no candidate-learnings report.
- **FR-73 Accepted learnings inform future `/tdd-author` sessions.** Accepted
  learnings are persisted to the project. When `/tdd-author` runs for a
  subsequent PRD update, it surfaces persisted learnings relevant to the TDD
  scope under design as advisory context — a signal that this class of issue has
  recurred in this project's prior builds. The author decides what (if anything)
  to adjust; learnings are advisory and do not block design authoring or open
  any new gate. — Acceptance: a `/tdd-author` session that runs after an
  accepted learning is persisted surfaces that learning (or an explicit
  reference to it) when the current TDD's scope overlaps the learning's subject
  area; the session does not block on the learning; a `/tdd-author` session with
  no overlapping persisted learnings proceeds without surfacing any.

### Build-phase defensive-coding norms
FR-72/FR-73 close the feedback loop into the *design* phase. This requirement
closes the complementary loop into the *build* phase: the recurring quality
classes the reviewer keeps catching (silent error-swallowing, leaked temp files,
unsafe escaping, sourced-library hygiene, path-traversal, TOCTOU reads,
hardcoding) are codified as explicit norms the build applies at generation time,
so the build produces guarded code on the first pass rather than relying on the
review gate to catch each instance and the rework loop to fix it.

- **FR-74 Build-phase defensive-coding norms.** The build prompt carries an
  explicit, enumerated set of defensive-coding norms the build applies to every
  commit it makes — including commits late in a long multi-turn build, not only
  the first. The norm set codifies the recurring finding classes observed across
  prior builds: (1) **fail loud** — check every command's return code; no bare
  `|| true` without a one-line justification; a sourced helper's failure aborts
  rather than silently continuing; (2) **temp-file cleanup** — every temp file is
  registered in an `EXIT` trap before it is created; (3) **safe
  escaping/interpolation** — never hand-roll a JSON escaper (use `jq`; if absent,
  `python3`; if neither, fail closed with a clear diagnostic); never run bash
  pattern-substitution (`${v//x/y}`) on an untrusted string (`&` is the
  matched-text reference); validate before interpolating into `sed`/`eval`/`bash
  -c`; (4) **sourced-library hygiene** — a sourced library has no top-level side
  effects and does not leak shell options (`set -uo pipefail`) to its callers;
  (5) **path/trust-boundary validation** — any filesystem path built from an
  external identifier is validated against a literal allowlist or a containment
  check; (6) **read-once** — mutable external state is read once into a variable,
  not re-read (no TOCTOU window); (7) **no hardcoding** — no hardcoded absolute
  paths, no non-portable commands. The norm set is a fixed enumerated list in
  this requirement; a later requirement may source it dynamically from the
  accepted-learnings store (FR-73) once that store is populated. FR-72/FR-73 feed
  recurring classes to the *design* phase (`/tdd-author`); FR-74 prevents them at
  *build* generation time — the two are complementary, not redundant. — Acceptance:
  in a build whose natural implementation would otherwise exhibit a norm class —
  e.g. a build that creates a temp file, or emits JSON on a `jq`-absent code path,
  or calls a command whose failure it must not ignore — the resulting committed
  diff shows the guarded form (an `EXIT`-trap registration covering the temp file
  before it is written; a `jq`/`python3` escape rather than a hand-rolled one; an
  explicit return-code check rather than a silent continue), observable by
  inspecting that build's committed diff against the specific norm being
  exercised.

### Interrogator discipline & evaluation rubrics
The authoring skills' interviews behave as collaborative scribes: they record
what the user says, dig into ambiguity when it is apparent, and move on. Two
disciplines are missing. First, an *interrogation* posture — aggressively
surfacing unstated assumptions, edge cases, conflicting goals, and feasibility
concerns — applied consistently rather than only when ambiguity happens to be
noticed, with the surfaced items tracked to resolution rather than lost in
chat. Second, an explicit *evaluation-criteria* conversation — "how will we
know this artifact is good?" — held as its own phase with its own output (a
rubric), instead of quality criteria living implicitly in the reviewer's
judgment. Together these convert the interview from transcription into
preparation, and make "what good looks like" an auditable artifact the gates
can use.

- **FR-75 PRD interview interrogator discipline.** `/prd-author`'s interview
  operates in an explicit interrogator / skeptical-challenger mode: the model
  aggressively surfaces unstated assumptions, edge cases, conflicting goals,
  and feasibility concerns rather than acting as a collaborative scribe. The
  skill maintains a running list of open assumptions and questions surfaced
  during the interview; every item is either resolved by the user or
  explicitly waived with a recorded rationale before the interview is declared
  complete. The skill's instructions include explicit anti-sycophancy language
  (agreement is not helpfulness; the model must challenge the user's framing
  and break out of agreeable loops). — Acceptance: a PRD authored or updated
  under this requirement carries an "Open assumptions & waivers" record (in
  the PRD's Open questions section or the PRD PR body) listing each surfaced
  assumption with its disposition (resolved: <how> | waived: <rationale>); a
  PRD PR whose record is absent or empty while the diff adds or changes
  requirements is observably non-compliant.
- **FR-76 Design interview interrogator discipline.** `/tdd-author`'s
  interview follows the same interrogator-mode rules as FR-75 (running
  open-assumptions list, resolution-or-waiver before completion,
  anti-sycophancy instructions), applied to the design conversation: the model
  explicitly challenges the PRD's requirements for infeasibility,
  contradiction, and under-specification, and challenges its own proposed
  design decomposition, before any TDD content is written. — Acceptance: a
  design PR authored under this requirement carries the same "Open assumptions
  & waivers" record (in the design PR body) covering the design-level
  assumptions surfaced; a design PR whose record is absent or empty while the
  TDD set introduces new interfaces or dependencies is observably
  non-compliant.
- **FR-77 Evaluation-rubric co-creation.** Both `/prd-author` and `/tdd-author`
  include a distinct rubric phase, after the exploratory interview and before
  the artifact is written, in which the model switches to a skeptical
  grading-expert posture and co-creates with the user a structured evaluation
  rubric defining what high-quality vs. acceptable vs. failing output looks
  like for the artifact being produced. The rubric's criteria are limited to
  qualities later gates can observe or enforce (e.g. traceability,
  concreteness, scope adherence, alternatives-analysis quality, verification
  plan actionability, naming consistency). The rubric is persisted as part of
  the design record (inline in the PRD/TDD set or as a referenced artifact in
  the same PR), is consumed by the design-critique gate as explicit success
  criteria for that artifact, and is queryable by future authoring sessions
  and the build-phase learnings system (FR-72/FR-73); the storage and query
  mechanism is design-time work, not specified here. — Acceptance: a PRD or
  TDD set authored after this requirement ships contains (or references, in
  the same PR) a co-created rubric with non-trivial criteria; the
  design-critique gate's output for that artifact cites the rubric's criteria
  in its findings or its PASS rationale; an artifact shipped without a rubric,
  or with only boilerplate criteria, is observably non-compliant.

### Dual-harness overlay (this update)
- **FR-79 Authoring on Claude Code and Grok Build.** `/prd-author`,
  `/tdd-author`, `/adr-new`, and `/bootstrap-project` complete their
  specified phase — including the phase-gate PR (FR-6, FR-11, FR-12) — when
  invoked on Claude Code and when invoked on Grok Build. — Acceptance: on
  each harness, invoking `/prd-author` in a throughline-bootstrapped repo
  with no draft starts an interview and can open a `docs/prd/<slug>` PR;
  invoking `/tdd-author` after a merged PRD update can open a
  `docs/design/<slug>` PR.
- **FR-80 `/build-tdds` on Claude Code and Grok Build.** `/build-tdds`
  implements FR-13–FR-20 and FR-15 on both harnesses. Worker start, session
  survival, and watch are harness-native and are not required to match. —
  Acceptance: on each harness, `/build-tdds` against a merged `draft` TDD
  either flips that TDD to `implemented` with the four gate artifacts
  present or records a named halt (FR-63) and does not flip.
- **FR-81 Harness-agnostic skill language.** throughline skills name
  *actions* (ask the user a structured question, dispatch a worker, write a
  file, run a shell command), not a vendor tool or CLI (`AskUserQuestion`,
  `Task`, `claude -p`, `grok -p`). — Acceptance: a case-insensitive search
  of `skills/**/SKILL.md` for `AskUserQuestion`, `` `Task` ``, `claude -p`,
  and `grok -p` as required tool/CLI names returns no matches; the skills
  remain invocable on both harnesses (FR-79, FR-80).
- **FR-82 File-backed gate verdicts.** Each of the four FR-15 gates records
  its outcome as an on-disk artifact the runner reads. A TDD flips only
  when all four artifacts exist and read PASS (or an allowed SKIP for
  FR-25). Transcript text, stream-json events, and sentinels that appear
  inside files the worker read are not flip authority. — Acceptance: a
  build whose only "PASS" string lives in a file it read, or in mid-message
  prose, does not flip; a flip is reproducible from the four artifacts plus
  `git log` / `git diff` / the TDD (FR-70) without reading a harness
  transcript.
- **FR-83 Soft engineering delegates.** Superpowers, pr-review-toolkit, and
  equivalent harness built-ins are optional. throughline uses them when
  present and does not fail install or fail a gate solely because they are
  absent (FR-22). — Acceptance: same as FR-22's acceptance.
- **FR-84 Bootstrap exception (expires).** Until `/build-tdds` has flipped
  one TDD to `implemented` on the harness in use, a TDD may declare
  `build-engine: bootstrap`. That TDD may be built by delegated engineering
  (Superpowers SDD or equivalent) instead of `/build-tdds`. The four FR-15
  observations and the human merge gate still apply. The exception expires
  on that first flip: later TDDs on that harness are built by
  `/build-tdds`. — Acceptance: a TDD marked `build-engine: bootstrap`
  before the first `/build-tdds` flip on that harness may reach
  `implemented` without `/build-tdds` having queued it; after a
  `/build-tdds` flip exists on that harness, a new TDD without the mark is
  queued by `/build-tdds` and is not considered done on a bootstrap
  engine's say-so.
- **FR-85 Implement command is `/build-tdds`.** On every supported harness
  the user-facing command that implements FR-13 is `/build-tdds`. It must
  not rely on the bare name `/implement` (a harness may already own that
  name). `/throughline:implement` is not the intended surface. The progress
  snapshot remains `/implement-status` (FR-28). — Acceptance: the slash
  menu on Claude Code and on Grok Build offers `/build-tdds` as a
  user-invocable throughline command; invoking it runs the FR-13 flow;
  throughline does not require the user to type `/implement` or
  `/throughline:implement`.

### Model selection
- **FR-86 Parent-session model check.** `/prd-author`, `/tdd-author`, and
  `/build-tdds` compare the parent session's model to the harness's latest
  top-tier binding (NFR-3). If the observed model is weaker than that
  binding, or the session model cannot be read, the skill warns and asks
  the user to continue or stop so they can change the model. A session on
  the latest top-tier binding, or on a newer model than that binding,
  proceeds without that warning. Supported harnesses expose the session
  model; an unreadable model is a defect with the same warn-and-ask shape,
  not a silent skip and not a hard stop. — Acceptance: invoking `/prd-author`,
  `/tdd-author`, or `/build-tdds` in a parent session whose observed model
  is weaker than the latest top-tier binding, or whose model cannot be
  read, surfaces a warning and a continue/stop choice before the interview
  or build proceeds; invoking any of those skills in a parent session on
  the latest top-tier binding (or newer) produces no such warning.
- **FR-87 Judgment-worker defaults and cheaper-pin warning.** The
  implementer worker, the FR-15(d) reviewer worker, the FR-10
  design-reviewer worker, and a non-mechanical runtime-verify worker
  default to the latest top-tier binding. A cheaper env/flag pin on the
  implementer or reviewer (`THROUGHLINE_BUILD_MODEL`,
  `THROUGHLINE_REVIEW_MODEL`, or the equivalent flag) is honored: the run
  warns that the slot is below the most-capable default and continues.
  Mechanical runtime-verify stays on the cheaper default (FR-52) and is
  not this warning. — Acceptance: a `/build-tdds` run with no model
  overrides records implementer and reviewer on the latest top-tier
  binding; the same run with `THROUGHLINE_REVIEW_MODEL` set to a weaker
  id records that weaker reviewer, emits a below-default warning, and
  still dispatches the reviewer; a mechanical-plan verify does not emit
  that warning for using the cheaper verify default.

### Quality hook & delegation
- **FR-21 Format + lint hook.** A `format-and-lint` PostToolUse hook formats then
  lints edited files when a linter is configured (no-op otherwise), debounced, for
  JS/TS, Python, Rust, and Go; lint failures are surfaced into the session for
  root-cause fixing.
- **FR-22 Layer-on-top delegation.** throughline delegates discovery
  (`brainstorming`) and generic engineering (TDD mechanics, code review,
  worktrees, the verification *mechanism* — see FR-26) to whatever the
  harness already provides (Superpowers, pr-review-toolkit, built-in
  `/verify` / `/code-review`, or the harness equivalent) **when those
  delegates are present**. They are not required to install throughline and
  not required for a gate to flip (FR-15, FR-83). `docs/PRD.md` +
  `docs/tdd/` + `docs/adr/` are canonical; `docs/superpowers/*` is transient
  input — ingested, never relocated. — Acceptance: installing throughline on
  a harness that does not have Superpowers or pr-review-toolkit still loads
  `/prd-author`, `/tdd-author`, `/adr-new`, `/bootstrap-project`, and
  `/build-tdds`; a `/build-tdds` flip does not fail solely because a named
  delegate plugin is absent.

### Non-functional
- **NFR-1 Human control via merge gates.** Every phase (requirements, design,
  implementation) ends in a PR the human merges; the plugin never merges.
- **NFR-2 Context hygiene.** Autonomous work runs in subagents or other
  harness-native workers so the interactive session stays clean; the
  workflow is one fresh session per command. There is no requirement that
  those workers be detached `claude -p` processes.
- **NFR-3 Model capability by job.** Judgment work defaults to the most
  capable model on the harness (the latest top-tier model). That set is: authoring
  requirements (`/prd-author`), authoring TDDs (`/tdd-author`), the
  `/build-tdds` parent session, writing code and tests (the implementer
  worker), reviewing code and tests (the FR-15(d) reviewer), reviewing
  designs (the FR-10 design-reviewer), and runtime-verify when the plan is
  not mechanical (FR-52). The only job that defaults to a cheaper model is
  mechanical runtime-verify (exit code, log line, file presence, HTTP
  status). Review independence is a fresh worker — a context that is not
  the author's session — not a different named model: the reviewer may use
  the same model name as the author. Concrete model ids live at one
  binding site as implementation defaults; rebinding them when a new
  generation ships is an implementation change, not a requirements change.
  Session-model and override surfaces are FR-86 and FR-87. — Acceptance: a
  TDD whose only review text lives in the implementer's session or report
  does not flip to `implemented`; a TDD whose review artifact was written
  by a separate worker on the same model name as the implementer is not
  rejected for that reason; unset defaults put implementer and reviewer on
  the latest top-tier binding and put mechanical verify on the cheaper
  binding.
- **NFR-4 Verdict honesty.** Outcomes — including runtime verification (FR-25) —
  distinguish `PASS` / `FAIL` / `BLOCKED` / `SKIP`: "couldn't observe" (BLOCKED),
  "nothing to observe" (SKIP), and "design-infeasible" are never conflated with
  "observed and wrong" (FAIL). Ambiguity resolves to FAIL, never to a false PASS, and
  progress estimates are labeled as estimates (FR-30).
- **NFR-5 Centrally maintained.** Scripts and skills run from the plugin cache (not
  vendored into consumer repos), so updates reach every project.

## Non-goals

- Owning **discovery / ideation** (brainstorming) — that is superpowers' job.
- Owning **generic engineering mechanics** (TDD execution, code review, worktrees, the
  Explore agent) — delegated when present (FR-22, FR-83); not re-implemented.
- **Auto-merging** PRs or otherwise removing the human gate.
- Replacing **CI**; `ci-checks.sh` is a pre-flip gate, not a CI system.
- **Bite-sized task-plan documents**; TDDs are designs, not step-by-step build scripts
  (the step-level discipline lives in `/build-tdds`).
- First-class support for **non-git / no-remote** workflows beyond a basic "skip git"
  escape hatch.
- **Bundling a verification harness/framework** — the verification *mechanism* (DOM,
  CLI, HTTP, return values, logs, …) is the project's; throughline governs only that a
  plan exists, is executed, and yields evidence (FR-26).
- **A pre-build de-risking spike** — there is no requirement to validate a design's
  riskiest assumption with a prototype/experiment *before* building it; for
  engineering design the build is typically the cheapest test, and the design-critique
  gate (FR-10) plus the interrogator discipline (FR-75/FR-76) already pressure-test
  assumptions at design time. (Considered and explicitly excluded.)
- **The per-requirement coverage map as a hard auto-gate or a whole-system audit** —
  FR-78's map is *reported* for the human review, not an automatic flip-blocker (the
  FR-15 gates remain the auto-authority), and it covers only the *landing TDD's*
  in-scope requirements, not a retroactive audit of every pre-existing requirement.
- **Precise time-to-completion ETAs** for LLM-driven builds — progress is an honest
  estimate, not a forecast (FR-30).
- **Run control from the progress view** — it is read-only observability, not a console
  to pause / resume / cancel a build.
- **Auto-launching `/bootstrap-project` (or any Claude process) from the post-update
  hook** — reconciliation (FR-34) is limited to cheap idempotent file edits and an
  optional one-line notice; the human decides when to re-run the skill.
- **Probing local toolchain binaries to detect drift** — the local-env marker (FR-33)
  records what was applied, not what is currently present on disk; FR-34's local
  notice is driven by release metadata (FR-35), not by introspecting the developer's
  machine.
- **Sandbox- or static-analysis-enforced gate boundaries** — a misbehaving
  build is caught by the four gates (commits, ci-checks, runtime-verify,
  review artifact), not by pre-execution policing (ADR 0005).
- **Recovering Claude's in-turn working memory** — the recovery features
  (FR-39 onward) cover only detail observably elicited from the user and
  persisted to disk, or progress committed to a build branch. There is no
  attempt to preserve the model's mid-turn reasoning state.
- **Surviving deletion of the run-state or draft files** — removing
  `docs/tdd/.implement-logs/` or the interactive draft is the user's explicit
  fresh-start lever; resume (FR-39, FR-47) is impossible afterward by design.
- **Auto-resuming on host reboot** — the user re-invokes `/build-tdds` (or the
  interactive skill); the plugin does not run a watchdog or daemon to bring
  runs back up. FR-39 / FR-47 handle the rest from the next invocation.
- **Recovering uncommitted edits in a build worktree** — committed history on
  the build branch is the source of truth across a resume (FR-40); any
  uncommitted edits left by an unclean shutdown are discarded.
- **Automated incorporation of build learnings into designs** — persisted
  learnings (FR-72, FR-73) are advisory context for the TDD author; the plugin
  does not automatically modify TDD scope, design decisions, or acceptance
  criteria based on past learnings.
- **Hard per-attempt token caps on rework.** Automatic rework is retired
  (FR-65, FR-68).
- **Sandboxing or static-analysis enforcement of the per-file diff bound
  (FR-54).** The per-file bound is enforced via the design-critique gate
  (FR-55) and the mechanical pre-pass (FR-51), not by sandboxing the
  build's edit tool or filtering its commits. This matches ADR 0005's
  "gate scope by prompt, not sandbox" disposition.
- **In-build human-override of a halt cause (FR-63).** Halt causes are
  system-determined and enumerated. Overrides happen at the next phase
  (design revision, TDD edit, or fresh `/build-tdds` run).
- **A throughline-owned process supervisor.** Detached `claude -p` /
  `grok -p` coprocesses, stream-json / sentinel authentication,
  STEP_COMMIT stdin/stdout protocols, harness-tracked watchers, and
  `THROUGHLINE_SESSION:` pointers into a vendor transcript store are
  not product requirements (retired FR-14-old, FR-29, FR-36–FR-38,
  FR-56–FR-62, FR-65–FR-66, FR-68).
- **Feature-identical detach, live-follow, or session re-invoke across
  harnesses.** Worker lifetime and watch are harness-native (FR-14,
  FR-80).
- **Hard Superpowers / pr-review-toolkit / Claude-marketplace
  dependencies** — optional delegates (FR-22, FR-83).
- **Nested review fan-out** as flip authority. One independent review
  artifact from a fresh worker (not the author's session) is required
  (FR-15(d), FR-82). A different named model is not required.
- **Cross-vendor review** (e.g. Grok builds, Claude reviews) — same-harness
  independent worker is enough (NFR-3).
- **Requiring a different named model** for review. Same-name write and
  review is allowed. Same-session self-review is not.
- **Competing as a spec-driven-development framework** or any
  marketplace-growth / distribution requirement. throughline is a
  governance overlay a developer installs; it is not a Spec Kit / BMAD
  competitor.
- **The qualified command `/throughline:implement`** as the intended
  implement surface. The command is `/build-tdds` (FR-85).
- **Automatic in-invocation rework** of gate findings. The human
  re-runs `/build-tdds` or revises the TDD.

## Constraints & assumptions

- A plugin for **Claude Code and Grok Build**. Other harnesses are out of
  scope. Claude-marketplace dependency resolution is not required to
  install (FR-83).
- PR creation needs a git remote + the `gh` CLI; without them, commits stay on
  branches to be PR'd manually.
- The integration branch is auto-detected (`origin`'s default → `main` → `master`);
  override with `THROUGHLINE_INTEGRATION_BRANCH`.
- Default models: implementer, reviewer, design-reviewer, `/build-tdds`
  parent, and `/prd-author` / `/tdd-author` = the latest top-tier model on
  that harness; mechanical runtime-verify = a cheaper model (NFR-3, FR-52,
  FR-86, FR-87). Concrete bindings are implementation defaults, overridable
  with a warning when a judgment slot is pinned cheaper.
- Supported harnesses expose the parent session's model so FR-86 can
  compare it to the latest top-tier binding.
- At most one `/build-tdds` run is active at a time (FR-18).
- The post-update reconciliation hook (FR-34) runs at session start when the
  harness supports that event. Repo-side file edits are required; a
  human-visible notice is best-effort (some harnesses ignore SessionStart
  stdout). `${CLAUDE_PLUGIN_DATA}` or the harness equivalent must be
  writable for drafts (FR-46). The hook short-circuits via a single
  `docs/.throughline-bootstrap.json` stat in repos not using throughline.
- The per-developer local marker's `<repo-id>` (FR-33) is derived deterministically
  from the repo's remote URL when present, falling back to its absolute path; repos
  moved on disk without a remote produce a fresh marker (no migration is performed).
- A *resumable* halt (FR-39, FR-47) requires the persisted run-state record
  (FR-27) and any draft (FR-46) to still exist at re-invocation; if the user
  removes them between interruption and re-invocation, recovery is impossible
  by design (see corresponding non-goal).
- Recoverable-cause classification (FR-41) is pattern-based on the child
  process's exit signal and stderr; cause patterns the runner does not yet
  recognise fall through to `failed`, never to a false `paused` state — the
  NFR-4 honesty rule applies (ambiguity resolves to FAIL, never to a false
  PASS or a false paused).
- A paused run has no automatic expiration; it remains resumable indefinitely
  provided the state and draft files are intact and the plugin schema is
  compatible (see open question on version skew).

## Open questions

- **Acceptance-criterion backfill.** FR-24 applies going forward and to this update's
  new requirements; whether and when to retrofit observable acceptance criteria onto
  the pre-existing FR-1–FR-22 is open (out of scope for this update).
- **Rubric storage & query mechanism (FR-77).** Where co-created rubrics persist
  (inline PRD/TDD sections, a `docs/rubrics/` store, or the FR-72/73 learnings
  system) and how future authoring sessions query them is deferred to the TDD.
  The learnings system is the natural candidate but is itself mid-build
  (TDDs 0022/0023); the design should not couple to unbuilt infrastructure
  without confirming its final shape.
- **Rubric phase ordering vs. interrogator completion (FR-75/76/77).** Whether
  the rubric phase requires the open-assumptions list to be fully
  resolved/waived first (strict ordering) or the two can interleave is a
  design decision deferred to the TDD; the only PRD-level constraint is that
  both complete before the artifact is written.
- **Retry-budget tuning (FR-42).** The bounded retry count and backoff for
  transient errors is left to the TDD; whether it is fixed, env-configurable,
  or cause-specific is open.
- **Plugin schema skew across pause and resume.** If the plugin updates
  between a paused interrupt and a resume (e.g. FR-34 reconciliation runs
  between them), the compatibility guarantees on the persisted run-state and
  draft formats are TBD — likely schema-versioning, but the policy is open.
- **Pause TTL (FR-39, FR-47).** Whether a very old paused run (e.g. weeks
  old) should be treated as stale and require an explicit resume flag rather
  than the FR-39/FR-47 prompt is open; today there is no TTL.
- **Specific bound values (FR-53, FR-54).** The TDD doc-size cap and
  expected-diff-size-per-file cap remain configured constants deferred to
  TDD-time. Rework-attempt caps (old FR-65/FR-66) are retired with
  automatic rework.
- **Rename `/implement-status`.** The snapshot command does not currently
  collide on Grok. Whether it should become `/build-tdds-status` for
  family consistency is open; this update keeps `/implement-status`
  (FR-28, FR-85).
- **Verdict-file format.** FR-82 requires on-disk gate artifacts. Exact
  path, filename, and schema are design (TDD), not this PRD.
- **Recurring-pattern threshold (FR-72).** FR-72 surfaces a pattern when it
  appears across more than one TDD or step, but the precise threshold —
  whether two occurrences suffice, whether severity affects the threshold,
  whether the threshold should be configurable per project — is deferred to
  the TDD. Initial calibration should be compared against actual run data.
- **Subject-area overlap for learning surface (FR-73).** How `/tdd-author`
  determines whether a persisted learning's subject area overlaps the current
  TDD's scope is a matching question deferred to the TDD. The PRD requires
  the learning be surfaced when overlap exists; the mechanism (keyword match,
  file-set intersection, model judgment) is not specified here.
- **Discrepancy detection mechanism (FR-71).** How the report is checked
  against `git diff` (mechanical pass vs part of FR-15(d) review) is
  design, deferred to `/tdd-author`. FR-56 is retired and is not a
  candidate.
- **Session-model observation and comparison (FR-86).** How each supported
  harness exposes the parent session's model id, and how "weaker than" /
  "newer than" the latest top-tier binding is decided for a given id, is
  design, deferred to `/tdd-author`. The PRD requires the warn-and-ask
  surface; it does not specify the harness API.

## Evaluation rubric

Co-created for this update (model capability by job). A later design gate
and the human PR reviewer grade the PRD against these.

| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement testability | Every changed or new requirement can be independently falsified | Most changed requirements are independently testable; at most one needs a small clarification | A changed requirement cannot be falsified, or two readings are both plausible |
| acceptance-criterion observability | Every new or rewritten requirement states an observation of the artifact surface (command output, file contents, session prompt, log line) | Acceptance is observable but slightly underspecified | Acceptance is "X is implemented", "a test exists", or missing |
| scope coherence | Change is only model-selection policy; four gates, human merge, dual-harness untouched except sentences that named different-model | One adjacent cross-reference cleaned up without expanding product scope | PRD grows a new product (cross-vendor review, supervisor, new phase) |
| non-goal explicitness | Non-goals that required different-model-tier are rewritten: same-name review allowed; same-session self-review still out | Independence is the worker; at most one stale different-model phrase remains in an unrelated bullet | Non-goals still require a different named model, or drop independence entirely |
| open-question honesty | Anything not dispositioned is under Open questions; waived items appear there; no invented HOW | Open questions lists residual HOW items | Silent invention of an unanswered product choice |
| model-policy job split | A reader can list most-capable jobs, the cheap job (mechanical verify only), independent-worker jobs, warn+ask surfaces, and override behavior | The split is present but one job is only implied by cross-reference | Review still required to be a different named model, or cheap vs most-capable jobs are not separable |

# Product Requirements: throughline

> Retroactively authored to capture the system's existing functionality as the
> design-of-record baseline. New capabilities are added from here via the normal
> `/prd-author` → `/tdd-author` → `/implement` flow.

## Problem & context

Building complex software with AI coding agents tends to lose the *design* and the
*decisions*: requirements and architectural rationale live in transient chat, "done"
is self-reported, and implementation is ungated. Generic engineering discipline (TDD,
code review, worktrees) is well covered by Anthropic's official Claude Code plugins
(superpowers, pr-review-toolkit), but those provide no persistent, traceable system
of record for *what* is being built and *why*.

throughline is a thin **governance overlay** for Claude Code: a persistent
PRD → TDD → ADR design-doc pipeline with phase-gate PRs and gated, unattended
implementation. It owns governance and traceability and **depends on / delegates**
discovery + engineering to the official plugins (see ADRs 0001–0003).

Two principles run through that overlay. First, **verification is runtime
observation at the surface** — confirming the *real artifact* behaves where a user
(human or programmatic) meets it — which is distinct from tests/typechecks (CI's
job); throughline carries verification from the PRD forward, not as an
afterthought, while leaving the verification *mechanism* to the project. Second,
because gated builds run unattended and detached, the human keeps **live
visibility** into a run without leaving the session.

## Users & goals

- **Primary user:** a developer using Claude Code who wants design-docs-before-code
  discipline, an auditable thread from requirement → design → decision →
  implementation, and unattended-but-gated builds — without re-implementing the
  generic engineering layer.
- **Success looks like:** every shipped change traces to an approved requirement and
  design; architectural decisions are recorded and binding; no code is marked "done"
  on self-report; and the human stays in control via a merge gate at each phase.

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
- **FR-34 Post-update reconciliation hook.** A `SessionStart` hook reconciles
  the two markers against the running plugin version without launching Claude:
  (a) in a repo lacking `docs/.throughline-bootstrap.json` it exits silently
  with no output; (b) on a repo-marker version mismatch it re-applies the cheap
  idempotent repo-side steps (`.gitignore` entry per FR-32; any missing
  docs-scaffold files per FR-3) and bumps `plugin_version_applied`; (c) on a
  local-marker mismatch *and* a release flagged local-impacting (FR-35) it
  prints exactly one session-start notice of the form
  `throughline updated <old>→<new>; run /bootstrap-project to refresh your local
  toolchain`, then updates `plugin_version_seen`. The hook never installs
  software, never spawns Claude, and never edits files outside the contract
  above. — Acceptance: on a repo without the bootstrap marker, the hook
  produces no output and modifies no files at session start; on a repo with
  a stale marker and a non-local-impacting plugin update, the next session's
  `.gitignore` contains the `docs/tdd/.implement-logs/` entry and the
  marker's `plugin_version_applied` equals the running plugin version, with
  no session notice printed; on a stale marker with a local-impacting update,
  the next session prints the notice exactly once.
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
  PR it self-reviews, then spawns the `design-reviewer` (fresh context, different
  model) which blocks on untraced requirements, under-specified interfaces, a missing
  alternatives analysis, a missing or non-actionable verification plan (see FR-23), or
  ADR conflicts; the verdict rides in the PR body.
- **FR-11 Design phase gate.** It commits the TDD set + any promoted ADRs together on
  a `docs/design/<slug>` branch and opens the design PR; it never auto-merges.

### Decisions
- **FR-12 Append-only ADRs.** `/adr-new` records decisions to `docs/adr/NNNN-*` with a
  status (`proposed` | `accepted` | `superseded by NNNN`) and maintains `INDEX.md`. An
  accepted ADR is never edited in substance — a change is a new ADR that supersedes
  the old one, flipping only its status line.

### Implementation
- **FR-13 Merge-triggered build.** `/implement` builds every TDD merged to the
  integration branch and not yet `implemented`; the design-PR merge is the build
  trigger — there is no manual `Status: ready` step. A path argument builds one TDD.
- **FR-14 Detached, isolated execution.** Builds run in detached `claude -p`
  processes, each in a dedicated git worktree, so the runner never touches the live
  working tree or session. Modes: sequential (default; stacked, one PR per TDD),
  `--combined` (one PR), `--parallel` (one worktree/PR per feature).
- **FR-15 Four independent gates.** A TDD flips to `implemented` only after (a)
  failing-test-first discipline — a `test(failing):` commit precedes the
  implementation, following `superpowers:test-driven-development`; (b) a mechanical
  `ci-checks.sh` re-run of tests + typecheck + linter (this is CI's job — running tests,
  not verification); (c) runtime verification — the real artifact is driven to where
  the change is observable and the TDD's verification observations hold (see FR-25);
  and (d) an independent review in a separate process on a different model
  (`pr-review-toolkit:code-reviewer` + `silent-failure-hunter` +
  `throughline:security-reviewer`) returning `REVIEW_RESULT: PASS`. Self-reported
  success is not trusted.
- **FR-16 Never merges; halt-on-failure.** `/implement` opens PRs but never merges. In
  sequential mode a failed gate halts the run and marks downstream TDDs `BLOCKED`
  rather than building on a broken base.
- **FR-17 Design-blocker feedback loop.** A requirement that proves infeasible or
  self-contradictory at build time is recorded to `docs/tdd/BLOCKERS.md` (a `BLOCKED`,
  not a `FAIL`) for `/tdd-author` to resolve in the next design pass.
- **FR-18 Resume safety + single-run lock.** A TDD already `implemented` on an
  existing un-merged branch is skipped (no duplicate work or PRs; `--rebuild`
  overrides), and a single-run lock prevents a second concurrent `/implement` on the
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
- **FR-25 Runtime-verification gate.** `/implement` runs a verification gate distinct
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
- **FR-27 Structured run state.** A running `/implement` maintains a structured,
  machine-readable record of run state — per TDD: queue position, status (pending /
  building / verifying / reviewing / done / failed / blocked / skipped), current stage,
  and timestamps; plus a run-level rollup — as the single source of truth a progress
  view reads. — Acceptance: at any point during a run the record reflects the run's
  actual per-TDD state.
- **FR-28 Progress snapshot.** From within the Claude Code TUI the user can get an
  on-demand snapshot: completed / total TDDs, an estimate-labeled percent (TDD- and
  current-stage-aware), the current TDD and its stage, per-TDD statuses, elapsed time,
  and log / PR pointers. — Acceptance: invoking it during a run prints a summary
  matching FR-27's record; invoking it with no active run says so plainly.
- **FR-29 Live follow mode.** A live/follow mode continuously refreshes the same view,
  realized so the user can enter and leave it without ending the session or
  interrupting the (detached) build. It is provided because that is feasible in the TUI
  as a read-only, interruptible watch; where an environment cannot support it, the
  snapshot (FR-28) satisfies the need. — Acceptance: entering and exiting the live view
  leaves the running build unaffected and the session intact.
- **FR-30 Honest, read-only progress.** The percent is presented as an estimate, never
  implying deterministic precision (NFR-4); the view is read-only observability and
  does not control the run (no pause / resume / cancel). — Acceptance: the view never
  reports 100% before all in-scope TDDs are terminal, and offers no run-control action.

### Build observability & safety boundaries
Each gate's `claude -p` only redirects its final `end_turn` text to stdout — any
non-`end_turn` exit (turn cap, external kill, ratelimit, self-pkill) yields a
near-empty redirected log even after substantial work. And the boundary between
the build (gate 1) and runtime-verify (gate 3) must be enforced at the prompt
level: a build claude that tries to drive the artifact and clean up child
processes can kill its own parent. These requirements codify those properties.

- **FR-36 Gate-log session pointer.** After every `claude -p` invocation made by
  `/implement` (build, review, runtime-verify), the runner appends to the per-TDD
  gate log a `THROUGHLINE_SESSION: <path>` line pointing at the full session
  JSONL (under `~/.claude/projects/<encoded-cwd>/`) plus a tail of up to five
  recent assistant tool calls (name + first ~140 chars of input). Without this,
  a turn-cap or self-kill produces the cryptic `FAIL (no BATCH_RESULT; see log)`
  with no actionable evidence — the redirected log is empty because `-p` only
  prints the final assistant message and a non-`end_turn` exit emits none. —
  Acceptance: after any `/implement` gate completes (PASS, FAIL, BLOCKED, or
  SKIP), the per-TDD log contains exactly one `THROUGHLINE_SESSION:` line per
  gate that ran, and the path resolves to an existing readable JSONL file.
- **FR-37 Build-phase boundaries.** The build prompt explicitly forbids the
  build claude from (a) spawning nested `claude` processes, (b) using
  pattern-based process killing (`pkill`, `killall`, `pgrep | xargs kill`), or
  (c) creating runtime-driving fixtures outside the repo (e.g. in `/tmp/`).
  These activities belong to the runtime-verify gate (FR-25), which runs as a
  separate process AFTER the build returns. Mixing them into the build risks
  the build claude killing its own parent: a pattern broad enough to clean up
  child processes is broad enough to match the runner's `claude -p`. —
  Acceptance: the build prompt shipped with the plugin enumerates these three
  prohibitions with rationale; for any preserved build session JSONL, no `Bash`
  tool call invokes `claude`, `pkill`, `killall`, or `pgrep`, and the build
  leaves no fixtures rooted in `/tmp/` or other out-of-repo paths.
- **FR-38 Cleanup safety in runtime-verify.** The runtime-verify gate (FR-25)
  IS allowed to spawn processes to drive the artifact, but its prompt mandates
  tracked-PID cleanup: child processes must be tracked from `$!` and killed by
  PID, never by pattern (`pkill -f`, `killall`). Same parent-self-kill trap as
  FR-37, same fix. — Acceptance: the runtime-verify prompt shipped with the
  plugin enumerates this constraint and prescribes `$!`-based PID tracking as
  the only sanctioned cleanup; for any preserved runtime-verify session JSONL,
  no `Bash` tool call uses `pkill` or `killall`.

### Run recovery & restart resilience
Long-running and interactive throughline flows can be interrupted by causes
that are not programming errors: Anthropic usage limits, host reboots, manual
process kills, transient network/API errors, and — in interactive sessions —
automatic context compaction or session loss before a document is committed.
Restarting from scratch on each interruption burns tokens and erases detail the
user already supplied that did not make it to disk. This area carries
continuity from the last observable progress point forward, as a continuation
of the existing run/skill (not a separate "recovery mode" the user has to
think about).

#### Detached `/implement` runs
- **FR-39 Interrupted-run detection.** Re-invoking `/implement` after a prior
  run did not exit cleanly recognizes that prior run from its persisted state
  (FR-27) and surfaces it before doing any work, identifying which TDD and
  which gate it was at and why it stopped (recoverable cause vs. failure). The
  user decides whether to resume or start fresh; the runner does not act
  silently. — Acceptance: launching `/implement` after a prior runner is
  killed mid-build prints a one-line summary naming the interrupted TDD and
  gate and waits for the user's resume/fresh decision before any build work;
  launching `/implement` when there is no non-terminal prior run proceeds
  normally without prompting.
- **FR-40 Gate-level resume.** On resume, the runner continues the interrupted
  TDD at the first of the four gates (FR-15) that did not complete; gates that
  did complete are not re-run. The persisted run-state record (FR-27) is the
  source of truth for which gates completed — including the build gate, whose
  completion is recorded only when the build's terminal sentinel
  `BATCH_RESULT: OK` (FR-15) is observed for that TDD's build attempt. Partial
  commits on the build branch (one or more `test(failing):` + `feat:` pairs
  that landed before an interruption) are NOT evidence of build-gate
  completion; an inferred-from-commits proxy contradicts this requirement and
  is not permitted. The build branch's committed history is the source of
  truth for the build gate's *output content* (what code was implemented), so
  resumed gates run against the same on-disk state the interrupted run left,
  not against untrusted in-flight worktree edits. On intra-gate (mid-build)
  interruption with a recoverable cause (FR-41), the build gate re-runs from
  the current branch state on resume; the build prompt is idempotent at the
  prompt level — it reads the existing commit history and either no-ops on
  already-completed sequencing steps or extends with the remaining ones. —
  Acceptance: (a) **Inter-gate resume.** A TDD interrupted after gate 2
  (ci-checks.sh) and before gate 3 (runtime-verify), when resumed, produces
  no new gate-1 or gate-2 output in the per-TDD log between the resume
  timestamp and the runtime-verify output; the resumed TDD's build branch
  HEAD contains the same gate-1 commits as before the interruption, with
  only the resumed-from gate's downstream commits (if any) added.
  (b) **Intra-build resume.** A TDD whose build process is interrupted by
  a recoverable cause (FR-41) after committing one or more `test(failing):`
  + `feat:` pairs but before emitting `BATCH_RESULT: OK` leaves the per-TDD
  fragment's `gates_completed` field without `build`; on `/implement
  --resume` the build gate re-runs (its log shows new build output between
  the resume timestamp and the next gate's verdict); the pre-resume
  commits are preserved unchanged on the build branch and the resumed
  build either no-ops on them or extends with the remaining sequencing
  steps to produce `BATCH_RESULT: OK`.
- **FR-41 Recoverable-cause classification.** The runner distinguishes
  recoverable causes (usage-limit / ratelimit, transient network/API error)
  from fatal causes (genuine FAIL verdict, malformed verdict, unexpected
  error). Recoverable causes halt the run cleanly into a *paused* state that
  FR-39 can detect and resume; fatal causes follow the existing FAIL pathway
  (FR-16, FR-17) and are not auto-resumed. — Acceptance: a run terminated by
  a simulated usage-limit cause leaves the run-state record (FR-27) in a
  paused, resumable shape distinguishable from `failed`, and triggers FR-39's
  resume prompt on the next `/implement`; a run terminated by a fatal cause
  leaves the existing FAIL state and does not trigger the resume prompt.
- **FR-42 Bounded in-gate retry on transient errors.** A transient error
  encountered during a gate (FR-41 classification) is retried within the gate
  a bounded number of times before promoting to a paused halt. A successful
  retry continues the gate normally and contributes a single verdict;
  unsuccessful retries hand off to FR-41's paused state. — Acceptance: a gate
  whose underlying call fails transiently and then succeeds within the retry
  budget produces a single PASS verdict, with the per-TDD log showing the
  intermediate transient errors and their retries as auditable entries; a
  gate whose transient failures exhaust the budget leaves the run in FR-41's
  paused state, not `failed`.
- **FR-43 Stale single-run lock reclaim.** The single-run lock from FR-18 is
  reclaimed automatically when its prior owner is no longer alive, so a
  recoverable interruption does not require the user to manually clear files
  before resuming. A live lock owner still blocks a second run. — Acceptance:
  after a prior `/implement` is forcibly killed, the next `/implement`
  proceeds without manual lock cleanup; while a prior `/implement` is alive,
  a second `/implement` still refuses with the existing lock-conflict
  message.
- **FR-44 Persisted-state durability.** The run-state record (FR-27) remains
  parseable and internally consistent at any point during a run; a reader
  (including a resuming `/implement`) never observes half-written or corrupt
  state. Mid-write interruption never causes a subsequent run to misclassify
  a TDD's progress. — Acceptance: reading every fragment of the active run's
  state at arbitrary points during the run yields valid, parseable content;
  a forced interruption mid-transition leaves each fragment showing either
  the prior transition or the new one, never an intermediate broken state.
- **FR-45 Paused status in the progress view.** `/implement-status` and the
  live-follow view (FR-28, FR-29) surface a paused run distinctly from
  `building`, `failed`, `blocked`, and `done`, and point the user at the
  re-invocation that will resume. NFR-4's verdict honesty applies: a paused
  run is never reported as `failed`, and vice versa. — Acceptance: invoking
  `/implement-status` on a paused run prints a status block that includes the
  word "paused", the recoverable cause (ratelimit / transient), and an
  instruction to re-run `/implement` to resume; on a `failed` run it does
  not.

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
  independence is preserved across resumption (NFR-3 model diversity is
  unaffected). — Acceptance: a `/tdd-author` session that resumes after the
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
  status code) run on a cost-efficient lower-tier model; verification plans
  requiring browser/UI driving, multi-step interactive flows, or judgment
  about ambiguous outputs run on the build model. As in NFR-3, the tier is
  the requirement and the concrete model binding is an implementation
  default, pinnable unconditionally via `THROUGHLINE_RUNTIME_VERIFY_MODEL`.
  The tiering preserves NFR-4 verdict
  honesty unconditionally — neither model is permitted to emit a false PASS
  on a verification it could not actually observe. — Acceptance: the per-TDD
  log records `runtime-verify model=<m> (plan=<cls>)` before each
  runtime-verify `claude` call; for a TDD with a mechanical verification plan
  `<m>` is the runner's mechanical-tier default (or the env-pinned value);
  for a TDD with a nontrivial
  plan `<m>` is the build model; for a TDD whose mechanical plan describes
  an observation the artifact fails, the verdict line is
  `VERIFY_RUNTIME: FAIL` (not a false PASS).

### Bounded scope, continuous review, automatic rework, trustworthy reporting
A diagnosis of TDD 0011 (PR #36) found an over-scoped TDD (540 lines vs the
prior two TDDs' ~185) produced an implementation whose largest file grew 56%
during the review-fix loop alone, and that the loop required 11 fix iterations
the user had to drive manually. The requirements below bound design-time scope
(Theme A), run review continuously during builds rather than only at the end
(Theme B), tie halting findings to a bounded automatic rework loop inside the
same `/implement` invocation (Theme C), and hold throughline's own codebase to
the scope discipline it enforces on its users while requiring gate decisions to
rest on independently verifiable facts and reports to be honest about what
actually changed (Theme D). Together they sharpen three existing requirements:

- **FR-15's four-gate model** — the review gate (gate d) keeps its verdict
  authority and its independent-process / different-model execution (NFR-3
  model diversity unchanged) but moves from a single end-of-build pass to
  continuous per-step passes during the build, plus a final consolidated
  pass that issues the flip verdict.
- **FR-16's halt-on-failure model** — a gate halt now means "halts after
  bounded rework exhausts," not "halts on first failure." The downstream-
  BLOCKED semantics inside sequential mode (don't build TDD N+1 if TDD N
  failed) are unchanged.
- **FR-39 / FR-41 / FR-45's paused-state taxonomy** — `paused` ceases to be
  a "stopped, awaiting manual re-invocation" terminal; it becomes a
  sub-category of FR-63's human-needed halt enum. The recoverable causes
  (ratelimit, transient, usage-limit) become specific values within that
  enum, distinguished from `rework-budget-exhausted`, `structural-finding`,
  and `design-escalation` causes. Existing `paused`-state surfaces in
  `/implement-status` (FR-45) and the resume flow (FR-39) carry forward
  unchanged on the recoverable sub-categories; FR-64 adds the one-screen
  context surface for the new sub-categories.

NFR-1's human control is preserved at phase boundaries (PRD PR merge, design
PR merge, implementation PR merge) and narrowed inside a build to "informed
of progress; not asked to drive between findings and convergence."

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

#### Continuous, scoped review (Theme B)
- **FR-56 Continuous in-build review (not end-of-build only).** Review runs
  continuously during a build, not only after the build claims completion.
  Issues surface while their cause is fresh and their fix is local. —
  Acceptance: for any TDD, the first review finding (if there is one) is
  emitted before more than half of the implementation's eventual line count
  has been written.
- **FR-57 Scoped review reads — no re-evaluation of cleared code.** Each
  review pass evaluates only what changed since the last review pass on the
  same build branch; code a prior review pass already cleared without
  intervening modification is not re-reviewed. — Acceptance: no review
  finding is raised against code that a prior review pass on the same TDD
  already approved and that has not been modified since.
- **FR-58 Severity taxonomy: halt only on halting categories.** Review
  findings are triaged by severity; only categories defined as halting
  (`blocker` and `major`) suspend forward progress and trigger the rework
  loop (FR-61, FR-62). Lower categories (`minor`, `nit`) accumulate without
  blocking. — Acceptance: the per-run report categorizes findings by
  severity; every halt event in the run-state record (FR-27) cites a
  finding in a halting category, and no halt event is recorded for a
  finding in a non-halting category.
- **FR-59 Cross-step learning within one TDD.** A build session that begins
  a new step benefits from the lessons of prior steps' reviews; the same
  categorical mistake is not made twice within one TDD. — Acceptance: for
  any TDD whose review log contains an addressed finding of categorical
  pattern P in step N, no step N+1..M's review pass surfaces another
  finding of the same categorical pattern P. (Categorical pattern is the
  finding's *kind*, not its exact file:line — e.g., "unchecked
  fragment-write return" addressed once should not recur for a different
  call site in a later step of the same TDD.)
- **FR-60 Author self-review before independent review.** The author gives
  its own work a critical pass against the same criteria the independent
  reviewer uses, before handing off. — Acceptance: aggregated across runs,
  review gates report fewer findings per build, on average, after this
  requirement lands than before (measurable from the run-state record's
  findings-per-build distribution).
- **FR-61 Halting findings trigger the in-invocation rework loop.** A
  finding classified as halting (FR-58) suspends forward progress and
  triggers the bounded automatic rework loop (FR-62) in the same
  `/implement` invocation; the user is informed of progress but is not
  asked to drive the loop. — Acceptance: between a halting per-step
  finding and either convergence (continued forward progress) or
  escalation (human-needed halt per C2), no user message is required.

#### Bounded, automatic rework (Theme C)
- **FR-62 Bounded in-invocation automatic rework.** When a gate fails on
  findings the system classifies as fixable (not structural per FR-67), the
  runner attempts the fix and re-runs the affected gates without user
  intervention. The user is involved only when the system has exhausted its
  bounded attempts (FR-65) or detected a structural finding warranting
  design reconsideration (FR-67). — Acceptance: a build that ultimately
  converges does so within a single `/implement` invocation; the user is
  not asked to restart the runner between a failed gate and its rework
  attempts.
- **FR-63 Halt taxonomy: human-needed only.** Every halt recorded in the
  run-state record carries an explicit, enumerated cause explaining why
  human attention is required — e.g., design escalation (FR-67), rework
  budget exhausted (FR-65), scope concern surfacing post-design (defect in
  FR-55), or external blocker (existing FR-17). No halt carries a cause
  equivalent to "stopped, awaiting manual re-invocation"; that category is
  eliminated. — Acceptance: every halt event in any `/implement` run-state
  record cites a value from a closed enum of human-needed causes; no halt
  event cites a non-enumerated or process-ended cause.
- **FR-64 One-screen halt context.** When the system requires human
  intervention, `/implement-status` (and the equivalent surface for halted
  runs) presents the halt cause, the triggering findings or decisions, and
  the available next actions on a single screen, so the human can decide
  what to do without reading logs or re-deriving state. — Acceptance: on
  any halted run, `/implement-status` output fits one terminal screen
  (≤ 24 lines × 80 cols by default) and contains the cause label, the
  triggering finding or decision, and the next-action options.
- **FR-65 Rework budget bound + design escalation on exceed.** Rework
  attempts are bounded per gate per step; on exceed, the TDD is marked
  for design reconsideration (a BLOCKED outcome routed into
  `docs/tdd/BLOCKERS.md` per FR-17) rather than further attempts. The
  bound's configured value is recorded in the run-state record. —
  Acceptance: no TDD's build records more rework attempts than the
  configured number for any given gate-step pair; on exceed, the
  triggering TDD is marked BLOCKED with a `rework-budget-exhausted`
  cause and the run-state record names the gate-step pair that hit the
  bound.
- **FR-66 Bounded rework scope per attempt.** A rework attempt remains
  proportional in scope to the finding it addresses. Oversized rework
  is rejected before it ships (i.e., before being included in the
  re-evaluated diff for the next review pass). — Acceptance: every
  rework commit's diff fits within a bound scaled by the cited
  finding's region size; oversized rework attempts are recorded in the
  run-state as rejected-before-ship with a `rework-scope-exceeded`
  cause, and do not advance to the next review pass.
- **FR-67 Structural-finding escalation, not local sweep.** When the
  system detects an issue as structural — meaning the fix would (a)
  touch files outside the TDD's declared touched-file set (FR-53),
  (b) exceed the TDD's per-file bound for the touched file, or
  (c) be explicitly classified as structural by the reviewer *because it
  requires reconsidering the design itself* — its interfaces, approach, or
  the TDD's declared decomposition (a fix that cannot be expressed as a
  bounded edit within the existing design) — the finding produces a
  `BLOCKED` outcome and a design-level entry in `docs/tdd/BLOCKERS.md`,
  not a large in-iteration refactor. Criterion (c) is reserved for
  genuine design-level reconsideration: a *mechanical* fix that stays
  within the declared touched-file set (a) AND within the per-file bound
  (b) — a relocation, reordering, anchor-tightening, or rename — is NOT
  structural and MUST be routed to bounded rework (FR-62), even when it
  spans regions of the file or moves a block across a region boundary. A
  reviewer invoking (c) must name the specific design reconsideration the
  fix requires; absent a named design-level reason, an in-scope finding
  is reworkable, not structural. (This closes a deadlock observed in
  practice: an in-scope block relocation classified structural under the
  old, unbounded (c) could neither be reworked — the runner refuses
  structural findings — nor resumed without a TDD revision, even though
  the design was already correct.) — Acceptance: a finding meeting
  criterion (a) or (b), or (c) *with a named design-level reason*,
  results in a `BLOCKED` outcome (not `FAIL`, not a rework attempt) with
  a corresponding `docs/tdd/BLOCKERS.md` entry naming the TDD, the gate,
  and the structural trigger; AND a finding whose fix stays within the
  declared touched-file set and per-file bound and carries no named
  design-level reason is routed to bounded rework — it appears in the
  run-state record (FR-27) as a rework attempt, not as a structural
  `BLOCKED` outcome.
- **FR-68 Rework cost less than original build cost (observable).** The
  token spend per rework attempt is meaningfully less than the token
  spend on the original build attempt for the same TDD. The
  expectation is recorded as observable telemetry, not enforced as a
  hard per-attempt cap. — Acceptance: the run-state record (FR-27) for
  any TDD with rework attempts contains per-attempt token-spend
  values, and the values for rework attempts are less than the value
  for the original build attempt on the same TDD.

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

- **FR-72 Candidate-learning surface after run.** After an `/implement` run
  completes (all in-scope TDDs in a terminal state), the run surfaces any
  recurring patterns detected across the run's artifacts — review findings,
  rework outcomes, structural escalations — as candidate learnings for human
  review. A pattern is surfaced when it appeared in the same categorical class
  across more than one TDD or build step in the run. The human reviews the
  candidates and marks each as accepted or discarded; discarded candidates are
  not persisted. — Acceptance: after any `/implement` run whose review and
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

### Quality hook & delegation
- **FR-21 Format + lint hook.** A `format-and-lint` PostToolUse hook formats then
  lints edited files when a linter is configured (no-op otherwise), debounced, for
  JS/TS, Python, Rust, and Go; lint failures are surfaced into the session for
  root-cause fixing.
- **FR-22 Layer-on-top delegation.** throughline depends on `superpowers` +
  `pr-review-toolkit` (declared cross-marketplace dependencies) and delegates
  discovery (`brainstorming`) and generic engineering (TDD, code review, the `Explore`
  agent, and the verification *mechanism* — see FR-26) to them and to built-ins
  (`superpowers:verification-before-completion`, the `/verify` skill); on-demand code
  review is `/code-review` + `/review-pr`. `docs/PRD.md` + `docs/tdd/` + `docs/adr/`
  are canonical;
  `docs/superpowers/*` is transient input — ingested, never relocated.

### Non-functional
- **NFR-1 Human control via merge gates.** Every phase (requirements, design,
  implementation) ends in a PR the human merges; the plugin never merges.
- **NFR-2 Context hygiene.** Autonomous work runs in subagents / detached processes so
  the interactive session stays clean; the workflow is one fresh session per command.
- **NFR-3 Model diversity.** Builds run on the strongest current-generation model
  (the latest top-tier model); the review gate runs on a different model — the
  prior generation's top-tier model by default — so the reviewer does not share
  the author's blind spots. This requirement names tiers, not products: the
  concrete model bindings are implementation defaults (overridable via
  flags/env), so rebinding them when a new model generation ships is a normal
  implementation change, not a requirements change.
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
  Explore agent) — delegated to superpowers / pr-review-toolkit / built-ins.
- **Auto-merging** PRs or otherwise removing the human gate.
- Replacing **CI**; `ci-checks.sh` is a pre-flip gate, not a CI system.
- **Bite-sized task-plan documents**; TDDs are designs, not step-by-step build scripts
  (the step-level discipline lives in `/implement`).
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
- **Sandbox- or static-analysis-enforced gate boundaries** — throughline relies on
  prompt-level instruction (FR-37, FR-38) to constrain claude's behavior in the build
  and runtime-verify gates; it does NOT sandbox the build's shell, filter its tool
  calls, or sit in front of process invocations with policy. A misbehaving build is
  caught by the four-gate system's downstream effects (its session JSONL is visible
  via FR-36, its commits are inspectable, the gates ultimately decide pass/fail) —
  not by pre-execution policing.
- **Inlining the full session JSONL into the per-TDD log** — FR-36 attaches a pointer
  plus a short tool-call tail. The full transcript (often hundreds of KB to several
  MB per gate) stays in `~/.claude/projects/...` for inspection; inlining it would
  bloat the log without aiding triage.
- **Recovering Claude's in-turn working memory** — the recovery features
  (FR-39 onward) cover only detail observably elicited from the user and
  persisted to disk, or progress committed to a build branch. There is no
  attempt to preserve the model's mid-turn reasoning state.
- **Surviving deletion of the run-state or draft files** — removing
  `docs/tdd/.implement-logs/` or the interactive draft is the user's explicit
  fresh-start lever; resume (FR-39, FR-47) is impossible afterward by design.
- **Auto-resuming on host reboot** — the user re-invokes `/implement` (or the
  interactive skill); the plugin does not run a watchdog or daemon to bring
  runs back up. FR-39 / FR-47 handle the rest from the next invocation.
- **Recovering uncommitted edits in a build worktree** — committed history on
  the build branch is the source of truth across a resume (FR-40); any
  uncommitted edits left by an unclean shutdown are discarded.
- **Automated incorporation of build learnings into designs** — persisted
  learnings (FR-72, FR-73) are advisory context for the TDD author; the plugin
  does not automatically modify TDD scope, design decisions, or acceptance
  criteria based on past learnings.
- **Hard per-attempt token caps on rework (FR-68).** Token spend on rework
  is held to "meaningfully less than original build" via observable
  telemetry, not via a runtime cap that aborts a mid-rework gate. A hard
  per-attempt cap would risk aborting legitimate cases; the retrospective
  audit + the bounded-attempts cap (FR-65) are the enforcement levers.
- **Sandboxing or static-analysis enforcement of the per-file diff bound
  (FR-54).** The per-file bound is enforced via the design-critique gate
  (FR-55) and the mechanical pre-pass (FR-51), not by sandboxing the
  build's edit tool or filtering its commits. This matches ADR 0005's
  "gate scope by prompt, not sandbox" disposition.
- **In-build human-override of a halt cause (FR-63).** Halt causes are
  system-determined and enumerated; the user cannot reclassify a halt to
  bypass the rework loop or skip a structural escalation inside the same
  invocation. Overrides happen at the next phase (design revision, TDD
  edit, or fresh `/implement` run).

## Constraints & assumptions

- A Claude Code plugin; requires the `claude-plugins-official` marketplace added and
  Claude Code ≥ 2.1.110 for cross-marketplace dependency resolution.
- PR creation needs a git remote + the `gh` CLI; without them, commits stay on
  branches to be PR'd manually.
- The integration branch is auto-detected (`origin`'s default → `main` → `master`);
  override with `THROUGHLINE_INTEGRATION_BRANCH`.
- Default models: build = the latest top-tier model, review = the prior
  generation's top tier (NFR-3 tiers; the concrete bindings are implementation
  defaults in the runner, overridden via `--model` / `--review-model` or
  `THROUGHLINE_BUILD_MODEL` / `THROUGHLINE_REVIEW_MODEL`).
- The progress live/follow mode (FR-29) is realized inside the TUI as a read-only,
  interruptible watch over the run-state record (e.g. a foreground `!` command ended
  with Ctrl-C). It neither ends the session nor touches the detached build, which runs
  in its own processes / worktrees; Claude Code has no native always-on dashboard pane,
  so "live" means follow-until-interrupt. At most one run is active at a time (the
  single-run lock, FR-18), so there is a single run to report on.
- The post-update reconciliation hook (FR-34) depends on Claude Code's `SessionStart`
  event firing on every session start and on `${CLAUDE_PLUGIN_DATA}` being writable.
  Claude Code has no native post-install or post-update plugin lifecycle event, so
  reconciliation runs opportunistically at the next session-start after an update; the
  hook short-circuits via a single `docs/.throughline-bootstrap.json` stat in repos
  not using throughline, so its cost outside throughline projects is negligible.
- The per-developer local marker's `<repo-id>` (FR-33) is derived deterministically
  from the repo's remote URL when present, falling back to its absolute path; repos
  moved on disk without a remote produce a fresh marker (no migration is performed).
- The gate-log session pointer (FR-36) relies on Claude Code's project-directory
  encoding scheme (`/path/with/slashes` → `~/.claude/projects/-path-with-slashes/`).
  A change to that scheme upstream would require updating the runner's lookup; if
  the encoded directory does not exist (e.g. the very first `claude -p` for a fresh
  cwd before claude writes its session file), the helper silently no-ops rather
  than failing the gate.
- The tool-call tail rendered into the gate log (FR-36) requires `jq` on PATH;
  without it, only the `THROUGHLINE_SESSION:` pointer is written and the user can
  inspect the JSONL manually. The runner does not vendor `jq`.
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
- **Further token-spend reductions.** FR-51 + FR-52 land the highest-confidence
  reductions surfaced by the investigation that produced TDD 0013. Other ideas
  from that investigation (prompt-caching the PRD + cited-ADR bodies across the
  per-TDD `claude -p` invocations within a single `/implement` run; trimming
  build-prompt re-reads when a TDD has no `ADR constraints`) need measurement
  before commitment and are deferred to a follow-up pass with empirical data.
- **Specific bound values (FR-53, FR-54, FR-65, FR-66).** The TDD doc-size cap,
  expected-diff-size-per-file cap, per-gate-per-step rework attempt cap, and
  the rework-scope scaling factor are configured constants whose values are
  deferred to TDD-time. Initial values should be calibrated against the
  TDD 0011 vs 0007/0008 data (TDDs of ~185 lines converged in zero iterations;
  TDD 0011 at 540 lines required 11) and revisited after the first builds run
  under the new bounds. The bounds should be env-overridable for
  experimentation.
- **Verify.sh / runtime-verify gate participation in the rework loop (FR-61,
  FR-62).** The continuous-review loop and the bounded-rework loop are
  defined here in terms of the review gate's findings. Whether the rework
  loop also re-runs `ci-checks.sh` and the runtime-verify gate after each
  rework commit (cheaper to re-run; could compound cost) versus only after
  rework converges (riskier; later failures cost a full unwind) is a design
  decision deferred to `/tdd-author`.
- **Author self-review model (FR-60).** Whether the author self-review pass
  runs on the same model as the author (cheapest; shares blind spots) or a
  different model (matches NFR-3 model diversity; doubles author-side
  token cost) is deferred to `/tdd-author`. The acceptance criterion is
  outcome-based (fewer findings on average), so either model choice can
  satisfy it.
- **Sequencing.** The intended order is Theme A (FR-53..FR-55) →
  Theme D refactor (FR-69 applied to throughline's existing files) →
  Theme C (FR-62..FR-68) → Theme B (FR-56..FR-61). Theme B requires
  Theme C's rework loop to exist (FR-61 depends on FR-62), so B and C
  are coupled with C necessarily first. The Theme D refactor lands as
  its own TDD between A and C, so subsequent behavior TDDs land on a
  compliant base. Whether the Theme D refactor should be split into
  per-file refactor TDDs (one per non-compliant shipped file) or
  bundled is open.
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
- **Discrepancy detection mechanism (FR-71).** FR-71 requires the
  per-build report and run-state record to reflect the actual diff,
  with narrative-vs-ground-truth discrepancies surfaced as `major`
  findings. Whether the discrepancy check runs as part of the in-build
  review gate (FR-56) or as a separate mechanical pass before the
  review gate is a design decision deferred to `/tdd-author`.

## Evaluation rubric

Co-created criteria for the requirements added in this update (FR-78). A later
design gate grades the requirement against these.

| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Observable acceptance criterion | FR-78 states a falsifiable surface (an artifact lists each in-scope requirement with exactly one status; a requirement no test asserts never reads `pinned`; an unobservable one reads `justified-no-surface`) | acceptance present and checkable | "a test exists for X" / unobservable |
| Stays WHAT, not HOW | no format / file location / which-gate / which-mechanism detail | mostly WHAT, minor leakage | prescribes the mechanism (belongs in a TDD) |
| Distinct + bounded | the delta vs FR-15(a)/FR-23/FR-71 is stated, and the non-goals are explicit (reported-not-gate; per-build scope; justified-SKIP ≠ gap; no whole-system retro-audit; no pre-build spike) | distinct, most non-goals stated | duplicates an existing FR or the scope sprawls |

---
name: implement
description: Turn features described in the PRD and designed in TDDs into code and tests, unattended. With no argument, implements every TDD that has been merged to the integration branch and is not yet `implemented`, as a batch (a batch of one is fine). Pass a TDD path to build just that one. Confirms the queue, then launches the build itself as a detached background job so can do further PRD and TDD updates while it builds. Invoke with /implement.
---

# Implement

The single entry point for turning TDDs into code.

## Scope
- `/implement <tdd-path>` → build just that TDD.
- `/implement` (no argument) → build every TDD that has been merged to the
  integration branch (origin's default / `main` / `master`; override with
  `THROUGHLINE_INTEGRATION_BRANCH`) and is not yet `implemented`, in numeric order.
  **The design-PR merge is what makes a TDD buildable** — merging lands it on the
  integration branch at `draft`, and that is the go-signal. An un-merged draft on
  a design branch is not on integration, so the PR stays the gate. TDDs at
  `Status: implemented` are skipped — that flip is the done-signal.
- Re-run safety: the flip to `implemented` is committed on the build branch, not
  on the integration branch, until you merge. So a re-run before merging would
  otherwise see the TDD as still buildable and rebuild it. The runner prevents
  that — a TDD already `implemented` on an existing un-merged branch is treated as
  done-but-awaiting-merge and SKIPPED (it points you at the branch), so re-running
  never duplicates work or PRs. `--rebuild` forces a fresh build anyway.

## Detect interrupted run (TDD 0011 / FR-39)

Before showing the queue, check whether a prior `/implement` run was
interrupted and left a *paused* TDD in the state record. If it did, the
user must decide whether to **resume** or **start fresh** before any
build work begins; the runner stays headless, so this is the only stage
that asks.

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" --check-paused`.
   - If output is empty, proceed normally to "Prepare".
   - If output names a paused run, output is one line per paused TDD in
     the format `slug=<slug> gate=<gate> cause=<cause>`. Use the FIRST
     line (the run's resume-point per FR-40's per-TDD queue order).
   - A line may also carry a trailing `resumable=blocked` marker
     (TDD 0027 / FR-39): the run did not pause but *halted blocked* on a
     recoverable cause whose `halt_next_actions` begins with a resume
     action (e.g. `rework-scope-exceeded`). Treat it like a paused line —
     it is offerable for Resume; `cause=<cause>` is the `halt_cause`.
     Resume flips it to paused/transient itself, so no manual state edit
     is needed. Blocked halts WITHOUT the marker (design escalations) are
     not surfaced here and stay human-routed via /tdd-author.
   - A line may instead carry a trailing `resumable=orphaned` marker
     (TDD 0030 / FR-39, gap 2): the prior runner *died mid-gate* (e.g. a
     verdict-write SIGPIPE) and left this TDD in a non-terminal status
     (`building`/`verifying`/`reviewing`) with no live runner — an
     interrupted-unclean run. `cause=unclean-exit`. Treat it exactly like
     a `resumable=blocked` line: it is offerable for Resume; `--resume`
     flips it to paused/transient and derives the resume baseline from the
     branch's committed history (FR-40), so no manual state edit is needed.
     A plain (non-`--resume`) re-run would silently rebuild the finished,
     reviewed work, so the orphaned line MUST be surfaced for the user's
     resume/fresh decision.
   - A line may instead carry a trailing `resumable=recoverable` marker
     (TDD 0039 / FR-39): the prior run *halted on a non-structural TERMINAL
     class that is commonly an artifact* — `cause=rework-budget-exhausted`
     (the bounded review rework budget ran out) or `cause=ci-checks` (the
     ci-checks gate went red). These are terminal BY DEFAULT (they are not
     auto-resumable, unlike `resumable=blocked`/`orphaned`); recovery is
     OPT-IN and requires an explicit `--recover` flag, because an automatic
     retry would silently mask a genuinely failing build (NFR-4). Surface it
     as a THIRD option (the **Recover** offer in step 3 below) — but ONLY
     when you have reason to believe the halt was an artifact (a flake, or an
     estimate/bound that has since been fixed in the TDD). Recovery re-enters
     the last good gate: it BUMPS the rework budget (and resets the
     coverage-retry budget) for `rework-budget-exhausted`, or re-runs
     ci-checks for `ci-checks`. It never *suppresses* a verdict — the
     re-entered gate re-observes, so a genuinely failing build re-halts
     honestly. The human owns the "this was an artifact" judgement.
   - A `resumable=blocked` line with `cause=structural-finding` (TDD 0031 /
     FR-39, FR-67, gap B) carries a precondition: the halt is resumable ONLY
     once the resolving TDD revision has been merged to integration. Surface
     it for Resume, but label the option so the user knows the precondition
     (step 3 below). On `--resume` the runner re-checks: if the integration
     copy of the TDD is byte-identical to the halt-time copy (unrevised), it
     refuses with `resume-blocked-tdd-unrevised` (driver-report-only — the
     fragment stays blocked/structural-finding, nothing is persisted); if the
     revision IS merged, it merges integration into the build branch and
     re-runs the halted gate against the revised declarations. A merge that
     conflicts refuses with `resume-blocked-integration-conflict` (a persisted
     paused cause), naming the manual conflict-resolution step. Both refusal
     causes appear on the runner's `refuse-to-resume: <cause>` report line.
   - A `resumable=blocked` line with `cause=verify-unobservable` (TDD 0035 /
     FR-40, FR-41, gap-closure) is the runtime-verify counterpart: the gate
     ended `VERIFY_RUNTIME: BLOCKED` ("couldn't observe" — distinct from FAIL
     "observed and wrong", NFR-4), usually because the TDD's `## Verification
     plan` told the headless gate to drive a surface it cannot reach (e.g. an
     interactive prompt). It carries the SAME precondition as
     `structural-finding`: the halt is resumable ONLY once the TDD's
     `## Verification plan` has been revised and merged to integration. Surface
     it for Resume, labelled with the precondition (step 3 below). On `--resume`
     the runner re-checks the recorded `tdd_rev` against the integration copy: if
     the verification plan is unrevised (byte-identical) it refuses with
     `resume-blocked-verify-plan-unrevised` (driver-report-only — the fragment
     stays blocked/verify-unobservable, nothing is persisted); if the plan IS
     revised, it merges integration into the build branch and re-runs ONLY the
     runtime-verify gate (build / test-first / ci-checks already recorded
     complete) against the revised plan. The refusal cause appears on the
     runner's `refuse-to-resume: <cause>` report line.
2. **Lock-alive race guard (TDD 0011 / iter-3 MAJOR-2).** A paused
   fragment can briefly coexist with a live lock — the runner's atomic
   `mv` lands the fragment a moment before the EXIT trap removes
   `.run.lock`. Don't show the resume prompt during that window: it
   would tell the user to resume while the prior runner is still alive,
   and the next launch would be rejected by the single-run lock.

   - Read the lock PID: `LOCKPID="$(cat docs/tdd/.implement-logs/.run.lock 2>/dev/null)"`.
   - If `LOCKPID` is set and `kill -0 "$LOCKPID" 2>/dev/null` succeeds
     (lock alive) AND `--check-paused` still reports a paused fragment,
     wait 2 seconds and re-check. Cap at 3 iterations (total 6 seconds).
   - On cap, surface "run state inconsistent — investigate
     state.d/ manually" via `AskUserQuestion` instead of offering
     Resume; exit the skill flow.
   - If lock dies during the polling window, proceed to step 3.
3. Surface the interrupted run via `AskUserQuestion`. Options:
   - **Resume from `<gate>` on `<slug>`** — re-launch the runner with
     `--resume` so gates already completed are not re-run. Resuming first
     merges the current integration branch into the build branch (fetching
     `origin` when the integration ref is remote-tracking) so the resumed
     gates run against current integration, not the branch's stale base
     (TDD 0033 / FR-40); a merge conflict refuses the resume with
     `resume-blocked-integration-conflict`, naming the manual
     conflict-resolution step. For a
     `cause=structural-finding` line, label this option **"Resume `<slug>`
     (structural halt; requires the resolving TDD revision to be merged
     first)"** so the user is told the precondition at decision time (TDD
     0031 / FR-64). For a `cause=verify-unobservable` line, label it
     **"Resume `<slug>` (couldn't-observe halt; requires the TDD's
     ## Verification plan to be revised + merged first)"** for the same
     reason (TDD 0035 / FR-64).
   - **Recover `<slug>` (re-run from `<gate>`; treats the halt as an
     artifact — bumps the rework budget / re-runs ci-checks)** — offer this
     ONLY for a `resumable=recoverable` line (TDD 0039 / FR-39). Its launch
     line adds `--recover` (which implies `--resume`). State plainly in the
     option that recovery ASSUMES the halt was an artifact (a flake or a
     since-fixed estimate), so the human owns that judgement: for
     `cause=rework-budget-exhausted` it re-enters the review gate with a fresh
     rework budget (the operator may also raise `THROUGHLINE_REWORK_MAX` at
     launch); for `cause=ci-checks` it re-runs the verify/ci-checks gate.
     Recovery never masks a real failure — the re-entered gate re-observes and
     re-halts honestly if the build is genuinely broken. If the operator does
     NOT believe the halt was an artifact, prefer **Start fresh** (after
     revising the TDD via `/tdd-author`) over Recover.
   - **Start fresh (discard paused state)** — delete `state.d/*.json`
     under the prior run's logdir (preserving the rest of the run dir
     for forensic value) AND remove the `latest` symlink so a stray
     `--resume` later doesn't reach a half-cleaned target (TDD 0011 /
     iter-3 MAJOR-8). Then launch normally.
   - **Cancel** — exit without launching.
4. On Resume, the launch line below MUST carry `--resume`. On Start
   fresh, it does not.

The non-paused interactive flow continues at "Prepare" below.

## Detect pending candidate learnings (TDD 0022 / FR-72)

After a run completes, the runner mines the per-TDD findings for *recurring*
categorical patterns (a finding class that recurred across more than one TDD or
build step) and, when it finds any, writes `<logdir>/candidate-learnings.json`
plus a `## Candidate learnings (pending review)` section in the run's
`report.md`. The accept/discard prompt is forbidden in the headless runner, so it
runs HERE, in this interactive session. It is surfaced two ways:

- **Auto (primary).** When the watcher's harness-tracked background job
  completes, the harness re-invokes this session with the watcher's stdout. Read
  its `IMPLEMENT_RUN_COMPLETE logdir=<abs> state=<…> candidate_learnings=<yes|no>`
  line. ALWAYS report run completion + `state` to the user (this is the status
  side-benefit — no more manual polling). Then CLASSIFY `state` before doing
  anything else, because the watcher can exit while the build is still alive
  (TDD 0036): it bounds *inactivity*, not total run time, so a long backoff or a
  wedge makes it give up with `state=watcher-timeout` even though the detached
  build is still running.
  - **Terminal states** (`done`, `paused`, `blocked`, `failed`): the run is
    genuinely over. Proceed as today — if `candidate_learnings=yes`, proceed to
    **The review** below against that `logdir`.
  - **Non-terminal states** (`watcher-timeout`, `running`, `interrupted`,
    `unknown`): the build may still be alive. Read the build PID from the
    watcher's `launched build pid <PID>` line in that SAME stdout payload (it
    carries both lines). Do NOT read `docs/tdd/.implement-logs/.watch.pid` — the
    watcher removes it on exit (its EXIT trap), so it is already gone. If
    `kill -0 <PID>` succeeds, the build is still running: re-arm the callback by
    launching a harness-tracked background Bash poll
    (`while kill -0 <PID> 2>/dev/null; do sleep 60; done`, then re-read the run
    state) so this session is re-invoked when the build actually finishes; report
    "build still running (watcher timed out); re-armed poll". On a non-terminal
    state, **do NOT run the candidate-learnings review** — it must not run against
    a live build (`apply_accepted_learnings` writes `LEARNINGS.md` and marks the
    queue reviewed, which is premature before the run finishes). If `kill -0 <PID>`
    fails (PID gone but state non-terminal), report the anomaly and rely on the
    **Fallback** review below on the next `/implement` invocation.
- **Fallback.** At the top of a fresh `/implement` invocation (immediately after
  "Detect interrupted run", before "Prepare"), check the most recent completed
  run's logdir (`docs/tdd/.implement-logs/latest`). If it holds an UNREVIEWED
  `candidate-learnings.json` (no sibling `candidate-learnings.reviewed.json`), run
  **The review** before showing the queue. This covers the case where the
  session/watcher died and the auto callback was lost (FR-39 fallback).

A run with no `candidate-learnings.json` skips this step silently.

### The review

1. Read `<logdir>/candidate-learnings.json` — a JSON array, one object per
   recurring class (`class`, `distinct_tdds[]`, `severity_range`,
   `was_structural`, `triggered_rework`, `subject_area_hints.{files,tags}`,
   `summary`, `evidence`).
2. Present ALL candidates in ONE `AskUserQuestion` with **`multiSelect: true`** —
   one option per class, in array order, labeled with the class name, the TDDs it
   recurred in, and its one-line summary. **Selected = accept, unselected =
   discard** (FR-72: discarded candidates are NOT persisted). Keep track of each
   option's 0-based INDEX in the JSON array.
3. Persist the accepted set with `apply_accepted_learnings`, passing the run
   **logdir** and the selected integer **indices** — and NOTHING else. Do NOT
   paste the candidates' `summary` / `evidence` / `class` text into the command:
   those are free review prose that may contain quotes, `$(…)`, or backticks, and
   interpolating them into a shell command would break or inject it. The function
   reads each accepted field from the JSON by index, appends it to
   `docs/tdd/LEARNINGS.md` (idempotently — a recurrence of an existing class
   reinforces its entry rather than duplicating), and then marks the queue
   reviewed by renaming `candidate-learnings.json` →
   `candidate-learnings.reviewed.json` (error-checked: a failure leaves the queue
   UNREVIEWED to retry, never silently lost). The bash body below is FIXED — only
   the trailing arguments (the scripts dir, the logdir, and the indices) vary:

   ```
   bash -c '. "$1/lib/state.sh"; . "$1/lib/learnings.sh"; shift; apply_accepted_learnings "$@"' \
     _ "${CLAUDE_PLUGIN_ROOT}/scripts" "<logdir>" <accepted-index>...
   ```

   If the user accepted NOTHING (all discarded), call it with the logdir and NO
   indices — that persists nothing and still marks the queue reviewed.
4. If the user CANCELS the `AskUserQuestion`, do NOT call it — leave
   `candidate-learnings.json` unreviewed (it re-surfaces next invocation) and
   persist nothing.

## Prepare
1. Show the queue: the TDD(s) in scope and their Status. Confirm.
2. Confirm mode:
   - **Sequential (default):** TDDs build in numeric order, each on its own
     `build/<change>/<slug>` branch STACKED on the previous, with ONE PR PER TDD.
     Dependencies are respected, and each feature stays a separately reviewable
     human gate. A failure halts the run and marks downstream TDDs BLOCKED.
   - **Combined:** one shared `build/<change>` branch and ONE PR for the whole
     set. Use only for a small, tightly-coupled set you want to review together.
   - **Parallel:** a `feat/<slug>` worktree + PR per feature. INDEPENDENT
     features only. Multiplies token usage; may hit rate limits.
3. The runner and its prompts/verify gate live in the plugin and run straight
   from `${CLAUDE_PLUGIN_ROOT}/scripts/` — they are NOT copied into the repo, so
   every project always uses the current version (no vendored drift). The runner
   finds `build-prompt.md`, `review-prompt.md`, `verify-runtime-prompt.md`, and
   `ci-checks.sh` next to itself. `ci-checks.sh` auto-detects the test/typecheck/lint
   commands; for an unusual setup, export `CI_CHECKS_TEST_CMD` /
   `CI_CHECKS_TYPECHECK_CMD` / `CI_CHECKS_LINT_CMD` before launching.

## Run (launch the watcher; it detaches the build)
Implementation runs in separate `claude -p` processes, never in this session —
fresh context per feature, and this session stays clean. Every mode also builds
inside at least one DEDICATED git worktree (sequential/combined share one;
parallel uses one per feature), so the detached runner never switches branches
or commits in the working tree your live session is using — only the build
branches it produces persist. After the user confirms the queue and mode (step
1–2 above), LAUNCH the build yourself and return control immediately. Do not
print a command for the user to run.

Launch the **watcher** (`scripts/implement-watch.sh`) — NOT `implement.sh`
directly — with the Bash tool and **`run_in_background: true`** so the harness
tracks it and re-invokes this session when it exits (that exit is what delivers
the run-completion callback in the next step — TDD 0022 / FR-72). The watcher
`nohup`s the real `implement.sh` itself, so the build still detaches and survives
the session closing (TDD 0011 / FR-39); the watcher just polls for its completion
and then exits. Pass the SAME flags you would have passed `implement.sh` (a TDD
path, `--parallel`, `--combined`, `--resume`, …) — the watcher forwards `"$@"`
verbatim. Append `--resume` when the user chose **Resume** at the "Detect
interrupted run" step; omit it for fresh starts.

Run this with the Bash tool, `run_in_background: true` (adjust flags for the
confirmed mode/scope):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/implement-watch.sh"
```

Resume variant (only when the user chose Resume above) — append `--resume`:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/implement-watch.sh" --resume
```

Recover variant (only when the user chose **Recover** for a
`resumable=recoverable` line above) — append `--recover` (it implies
`--resume`, so you do not also need `--resume`; TDD 0039 / FR-39):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/implement-watch.sh" --recover
```

Variants: append a TDD path to build one; add `--parallel` or `--combined` for
those modes. Launching the watcher as a harness-tracked background job (NOT a
bare `nohup`) is what lets this session be re-invoked on completion; the build
itself is still `nohup`-detached *inside* the watcher, so closing the session
does not kill it (FR-39 preserved).

The watcher echoes one line to its stdout, `launched build pid <PID>`, where
`<PID>` is the **build's** PID. After launching, report from that line: the build
PID, that it is running detached, and the log location
(`docs/tdd/.implement-logs/`). The user can watch with
`tail -f docs/tdd/.implement-logs/<ts>/report.md` or just wait — when the build
finishes, the watcher's exit re-invokes this session automatically (next step).

## Watching it
- `/implement-status` — read-only progress snapshot of the active run
  (current TDD, stage, an estimate-labeled %, per-TDD statuses, log/PR
  pointers). Says so plainly when no run is active.
- Live watch — `/implement-status` hands you a one-line
  `!bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" --follow` command to paste
  in your TUI; it is a foreground, read-only view that refreshes until you
  press Ctrl-C (the build is unaffected).

Both views read one structured run-state record the runner maintains under
`docs/tdd/.implement-logs/<ts>/state.d/` (FR-27):
- `run.json` — run-level identity + rollup;
- `<slug>.json` — one fragment per queued TDD, updated atomically at every
  status / stage transition;
- `docs/tdd/.implement-logs/latest` — symlink to the active run's `<ts>` dir.

What each process does (see `${CLAUDE_PLUGIN_ROOT}/scripts/build-prompt.md`): loads the TDD + its PRD
refs + accepted ADRs, builds failing-test-first (a `test(failing):` commit before
each implementation), lint/typecheck enforced at edit time, updates any docs the
change makes stale IN THE SAME COMMIT
(supersede accepted ADRs/design docs; edit evergreen docs in place), and commits.

Before its final `BATCH_RESULT:` line the build also runs an **author
self-review** (FR-60): it gives its own diff a critical pass against the same
checklist the independent reviewer uses and emits a `SELF_REVIEW` block
(`SELF_REVIEW_BEGIN..SELF_REVIEW_END`, findings in the §1 finding schema)
immediately before BATCH_RESULT, addressing any halting self-review finding
first — an unaddressed one is caught by the consolidated review as a
`self-review-ignored` finding. The build prompt also carries two unattended-mode
guards: it must NEVER call `AskUserQuestion` (the build is a headless `claude -p`
subprocess; it emits `BATCH_RESULT: BLOCKED` for human-needed cases instead), and
it uses `git commit --no-verify` for the `test(failing):` commit specifically so a
repo's pre-commit test hook cannot reject the deliberately-red commit.

The build runs as a multi-turn `claude -p` coprocess (TDD 0020 §1). At the end of
each Sequencing item, the build emits a `STEP_COMMIT: <step-id> <sha>` sentinel
naming the integer step index and the implementation-finishing commit, then
BLOCKS until the runner replies with `STEP_REVIEW: PASS` (proceed to next step)
or `STEP_REVIEW: BLOCK <finding>` (rework the cited finding, then re-emit
`STEP_COMMIT:` for the same step). The runner's `_per_step_review_loop` reads
the sentinels off the build's stdout (stream-json) and writes the verdict to
stdin. This makes review continuous and scoped per step rather than one
end-of-build pass, so already-cleared code is never re-evaluated (FR-57). A
build that never emits `STEP_COMMIT:` degrades gracefully to single-shot
end-of-build review (the legacy shape). A malformed `STEP_COMMIT:` (a
non-integer step id, e.g. copying a `5b.` Sequencing label literally) is not
dropped silently: the runner logs a `THROUGHLINE_PROTOCOL_ERROR` and replies
with a bounded protocol-correction `STEP_REVIEW: BLOCK` telling the build to
re-emit the sentinel with the 1-based ordinal (2 corrections per build);
exhausting that budget kills the build and FAILs the TDD via the fatal pathway
— a protocol error is never classified transient (NFR-4).

The build's own `BATCH_RESULT: OK` is NOT trusted as done. Before flipping a TDD
to `implemented`, the runner enforces four independent gates:
- **test-first** — the build must show failing-test-first discipline: a dedicated
  `test(failing): ...` commit BEFORE the implementation (unless it emits
  `TEST_FIRST: SKIPPED` for a genuine no-new-behavior change). Mechanical, read
  straight from git history.
- **ci-checks.sh** — re-runs the test suite + typecheck + project linter
  mechanically. This is **CI's job** (running tests, not verification — see ADR
  0004); the model's self-report doesn't count.
- **runtime-verify** — a SEPARATE `claude -p` process that drives the BUILT
  artifact to the TDD's `## Verification plan` observation points and confirms
  the expected observations hold at the artifact's surface. Reports
  `VERIFY_RUNTIME: PASS | FAIL | BLOCKED | SKIP` (kept distinct per NFR-4:
  "observed and wrong" is never conflated with "couldn't observe" or "nothing to
  observe"); ambiguity / missing verdict resolves to FAIL, never a false PASS. A
  justified `SKIP` (e.g. a pure internal refactor with no observable surface) is
  allowed and recorded. The verification *mechanism* is the project's, delegated
  to `superpowers:verification-before-completion` / the `/verify` skill —
  throughline ships NO bundled harness (FR-26 / [ADR
  0004](../../docs/adr/0004-verification-is-observation-governed-not-bundled.md)).
- **review** — a SEPARATE `claude -p` process on a DIFFERENT model than the build
  (default sonnet vs an opus build) for genuine reviewer diversity (not a subagent
  of the author), that must end `REVIEW_RESULT: PASS`.
Only when all four pass does the runner flip the TDD and open the PR(s) per the
mode. It NEVER merges — merging is your approval gate.

Bounded rework loop (TDD 0019 / ADR 0007): a review `BLOCK` no longer halts on
first failure. A halting finding (`blocker`/`major`) triggers a bounded
automatic rework loop **inside the same `/implement` invocation** — you are kept
informed but are NOT asked to drive between a finding and convergence. Each
attempt runs on the rework model (`sonnet` by default — cheaper and less prone
to opportunistic refactoring than the Opus build), fixes only the cited finding,
and faces a mechanical pre-pass before it ships: a per-attempt scope cap
(`max(THROUGHLINE_REWORK_SCOPE_FLOOR=60, THROUGHLINE_REWORK_SCOPE_FACTOR=3 ×
finding-region)`) and the TDD's `## Touched files` / `## Expected diff size`
declarations. The loop halts for human attention ONLY when it cannot proceed
automatically:
- **`structural-finding`** — the reviewer tagged the finding structural, or the
  rework would touch a file outside the TDD's declared set / exceed its per-file
  bound. The runner does NOT attempt a large in-iteration refactor; it BLOCKs and
  appends a design-level entry to `docs/tdd/BLOCKERS.md` (FR-67).
- **`rework-scope-exceeded`** — a rework commit overran the scope cap; it is
  hard-reset off the branch before shipping and the TDD BLOCKs (FR-66).
- **`rework-budget-exhausted`** — `THROUGHLINE_REWORK_MAX` (default 3) attempts
  per gate-step did not converge; the TDD BLOCKs for `/tdd-author` (FR-65).
Per-attempt token spend is recorded as telemetry (rework is expected to cost
less than the original build — FR-68), not enforced as a hard cap. The four
knobs are snapshotted into `run.json`'s `config.rework_config` so any halt is
reproducible from the run-state record alone.

Failure handling: in sequential mode a failed gate (after bounded rework
exhausts) HALTS the run and marks every downstream (stacked) TDD `BLOCKED`
rather than building on a broken base; in parallel mode a failure affects only
that feature. A build that ends `BATCH_RESULT: BLOCKED <reason>` is a DESIGN
blocker — the runner appends it to `docs/tdd/BLOCKERS.md` for `/tdd-author` to
resolve.

When the build finishes: a report at
`docs/tdd/.implement-logs/<timestamp>/report.md` lists per-feature status
(OK / FAIL verification / FAIL review / BLOCKED) with log paths, and the PR(s)
await review. If `docs/tdd/BLOCKERS.md` gained entries, run `/tdd-author` to
revise the design, then re-run `/implement`.

## Merging the stack (sequential mode)
Sequential PRs are STACKED: PR 2's base is TDD 1's branch, PR 3's base is TDD 2's,
and so on. The report ends with an ordered "Merge plan" — merge those PRs
**bottom-up, in order**. After you merge one, GitHub auto-retargets the next PR
onto its new base, so the stack collapses cleanly. Caveat: a **squash-merge
rewrites the commits** and breaks that auto-retarget (the next PR will show
already-merged diffs) — for stacked PRs prefer a merge commit or
rebase-merge. If you want squash-friendly review, use `--combined` to get ONE PR
for the set instead.

## Notes
- PRs need a git remote and the `gh` CLI; without them, commits stay on the
  branch to PR manually.
- Integration branch (what "merged = buildable" reads from) is auto-detected as
  origin's default → `main` → `master` → current branch. Set
  `THROUGHLINE_INTEGRATION_BRANCH` for a non-standard default. Normally you run
  `/implement` from that branch, so it matches what you have checked out.
- The runner sets `--permission-mode auto` for unattended runs; for tighter
  control add a tool allowlist or use OS sandboxing.
- Models: the build runs on the best model (opus by default); the review gate runs
  on a DIFFERENT model (sonnet by default) for diversity. Override with `--model` /
  `--review-model`, or `THROUGHLINE_BUILD_MODEL` / `THROUGHLINE_REVIEW_MODEL`.
- `THROUGHLINE_REQUIRE_TEST_FIRST=0` disables the failing-test-first gate (e.g. a
  batch of pure refactors); leave it on (default) for feature work.
- `THROUGHLINE_RUNTIME_VERIFY_MODEL` pins the runtime-verify gate's model
  unconditionally (default is heuristic: sonnet for mechanical plans, build
  model otherwise — TDD 0013 / FR-52).
- `THROUGHLINE_REQUIRE_RUNTIME_VERIFY=0` disables the runtime-verification gate
  the same way (the documented escape hatch — e.g. a batch of pure refactors
  whose TDDs all declare `SKIP`); leave it on (default) for feature work.
- Bounded-rework knobs (TDD 0019): `THROUGHLINE_REWORK_MODEL` (default `sonnet`),
  `THROUGHLINE_REWORK_MAX` (per-gate-step attempt cap, default 3),
  `THROUGHLINE_REWORK_SCOPE_FLOOR` (default 60) and
  `THROUGHLINE_REWORK_SCOPE_FACTOR` (default 3) for the per-attempt scope cap
  `max(floor, factor × finding-region)`. All four are recorded in
  `run.json`'s `config.rework_config`.
- "skip git" → build and commit on the current branch with no branching/PRs.

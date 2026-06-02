---
name: implement
description: Turn features described in the PRD and designed in TDDs into code and tests, unattended. With no argument, implements every TDD that has been merged to the integration branch and is not yet `implemented`, as a batch (a batch of one is fine). Pass a TDD path to build just that one. Confirms the queue, then launches the build itself as a detached background job so can do further PRD and TDD updates while it builds. Invoke with /implement.
disable-model-invocation: true
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
     `--resume` so gates already completed are not re-run. For a
     `cause=structural-finding` line, label this option **"Resume `<slug>`
     (structural halt; requires the resolving TDD revision to be merged
     first)"** so the user is told the precondition at decision time (TDD
     0031 / FR-64).
   - **Start fresh (discard paused state)** — delete `state.d/*.json`
     under the prior run's logdir (preserving the rest of the run dir
     for forensic value) AND remove the `latest` symlink so a stray
     `--resume` later doesn't reach a half-cleaned target (TDD 0011 /
     iter-3 MAJOR-8). Then launch normally.
   - **Cancel** — exit without launching.
4. On Resume, the launch line below MUST carry `--resume`. On Start
   fresh, it does not.

The non-paused interactive flow continues at "Prepare" below.

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

## Run (launch it yourself, detached)
Implementation runs in separate `claude -p` processes, never in this session —
fresh context per feature, and this session stays clean. Every mode also builds
inside at least one DEDICATED git worktree (sequential/combined share one;
parallel uses one per feature), so the detached runner never switches branches
or commits in the working tree your live session is using — only the build
branches it produces persist. After the user confirms the queue and mode (step
1–2 above), LAUNCH the runner yourself as a detached background job and return
control immediately. Do not print a command for the user to run.

Launch with a single Bash call (adjust flags for the confirmed mode/scope).
Append `--resume` when the user chose **Resume** at the "Detect interrupted
run" step (TDD 0011 / FR-39); omit it for fresh starts.

```
mkdir -p docs/tdd/.implement-logs
nohup bash "${CLAUDE_PLUGIN_ROOT}/scripts/implement.sh" \
  > docs/tdd/.implement-logs/nohup.out 2>&1 &
echo "launched pid $!"
```

Resume variant (only when the user chose Resume above):

```
nohup bash "${CLAUDE_PLUGIN_ROOT}/scripts/implement.sh" --resume \
  > docs/tdd/.implement-logs/nohup.out 2>&1 &
```

`nohup … &` survives the session closing and does not block, so the build runs
unattended while the session stays free. Variants: append a TDD path to build
one; add `--parallel` if the user selected Parallel mode.

After launching, report: the PID, that it is running detached, and the log
location. The user can watch with `tail -f docs/tdd/.implement-logs/<ts>/report.md`
or just wait.

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
end-of-build review (the legacy shape).

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

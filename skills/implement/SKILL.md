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
   `verify.sh` next to itself. `verify.sh` auto-detects the test/typecheck/lint
   commands; for an unusual setup, export `VERIFY_TEST_CMD` /
   `VERIFY_TYPECHECK_CMD` / `VERIFY_LINT_CMD` before launching.

## Run (launch it yourself, detached)
Implementation runs in separate `claude -p` processes, never in this session —
fresh context per feature, and this session stays clean. Every mode also builds
inside at least one DEDICATED git worktree (sequential/combined share one;
parallel uses one per feature), so the detached runner never switches branches
or commits in the working tree your live session is using — only the build
branches it produces persist. After the user confirms the queue and mode (step
1–2 above), LAUNCH the runner yourself as a detached background job and return
control immediately. Do not print a command for the user to run.

Launch with a single Bash call (adjust flags for the confirmed mode/scope):

```
mkdir -p docs/tdd/.implement-logs
nohup bash "${CLAUDE_PLUGIN_ROOT}/scripts/implement.sh" \
  > docs/tdd/.implement-logs/nohup.out 2>&1 &
echo "launched pid $!"
```

`nohup … &` survives the session closing and does not block, so the build runs
unattended while the session stays free. Variants: append a TDD path to build
one; add `--parallel` if the user selected Parallel mode.

After launching, report: the PID, that it is running detached, and the log
location. The user can watch with `tail -f docs/tdd/.implement-logs/<ts>/report.md`
or just wait.

What each process does (see `${CLAUDE_PLUGIN_ROOT}/scripts/build-prompt.md`): loads the TDD + its PRD
refs + accepted ADRs, builds failing-test-first (a `test(failing):` commit before
each implementation), lint/typecheck enforced at edit time, updates any docs the
change makes stale IN THE SAME COMMIT
(supersede accepted ADRs/design docs; edit evergreen docs in place), and commits.

The build's own `BATCH_RESULT: OK` is NOT trusted as done. Before flipping a TDD
to `implemented`, the runner enforces four independent gates:
- **test-first** — the build must show failing-test-first discipline: a dedicated
  `test(failing): ...` commit BEFORE the implementation (unless it emits
  `TEST_FIRST: SKIPPED` for a genuine no-new-behavior change). Mechanical, read
  straight from git history.
- **verify.sh** — re-runs the test suite + typecheck + project linter
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

Failure handling: in sequential mode a failed gate HALTS the run and marks every
downstream (stacked) TDD `BLOCKED` rather than building on a broken base; in
parallel mode a failure affects only that feature. A build that ends
`BATCH_RESULT: BLOCKED <reason>` is a DESIGN blocker — the runner appends it to
`docs/tdd/BLOCKERS.md` for `/tdd-author` to resolve.

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
- `THROUGHLINE_REQUIRE_RUNTIME_VERIFY=0` disables the runtime-verification gate
  the same way (the documented escape hatch — e.g. a batch of pure refactors
  whose TDDs all declare `SKIP`); leave it on (default) for feature work.
- "skip git" → build and commit on the current branch with no branching/PRs.

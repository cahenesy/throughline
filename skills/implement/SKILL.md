---
name: build-tdds
description: Turn features described in the PRD and designed in TDDs into code and tests. Confirms the queue, then sequences one implementer worker, mechanical gates, one runtime-verify worker, and one reviewer worker. Opens a PR per TDD. Never merges. Invoke with /build-tdds.
---

# `/build-tdds`

Interactive parent skill. It sequences workers; it is not a detached
coprocess. Session survival is whatever the harness does.

## 1. Source helpers (fail closed)

Resolve the plugin tree from the first set of `CLAUDE_PLUGIN_ROOT` /
`GROK_PLUGIN_ROOT`, then source helpers. If any source fails, stop.

```
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/verdicts.sh" || exit 1
. "$(tl_plugin_root)/scripts/lib/run-record.sh" || exit 1
. "$(tl_plugin_root)/scripts/lib/models.sh" || exit 1
REPO="$(git rev-parse --show-toplevel)"
```

`REPO` is the human session / integration checkout. Never pass the build worktree path as <repo-root>. Every `tl_verdict_*` and `tl_run_*` call uses `"$REPO"`.

## 2. Lock (FR-18 / FR-43)

`tl_run_lock "$REPO"`. If held by a live PID → refuse. If held by a dead
PID → `tl_run_lock_reclaim "$REPO"`.

## 3. Resume vs fresh (FR-39 / FR-40)

If `docs/tdd/.implement-logs/latest` has a TDD whose `status` is not
terminal (`done|failed|blocked|skipped`):

Ask the user a structured question: **Resume** / **Start fresh**.

- **Fresh:** delete `latest` state fragments only (`run.json` and
  `<slug>.json`). Keep logs. Then continue at step 4.
- **Resume:** `g="$(tl_run_next_gate "$REPO" "$run" "$slug")"`. Jump:
  - `test-first` — if the build branch exists **and** has commits beyond
    integration, do **not** re-dispatch the implementer; run step 8
    observe-only. If the branch has no commits beyond integration,
    dispatch the implementer (step 7) with "continue from existing
    branch".
  - `ci-checks` — skip 7–8a; run `ci-checks.sh` only (step 8b).
  - `runtime-verify` — skip 7–8; run step 9 only.
  - `review` — skip 7–9; run step 10 only.
  - `flip` — skip 7–10; run step 11 only.

Never treat partial `feat:` commits as build-gate completion. The
test-first verdict file is the only build-complete signal.

## 4. Queue (FR-13, FR-18, FR-84)

Every `docs/tdd/0*.md` on the integration branch whose `Status:` is
`draft` or `ready` and that is not already `implemented` on an unmerged
`build/` branch.

Skip `build-engine: bootstrap` only when
`docs/tdd/.implement-logs/.first-flip-done` does **not** exist (no TDD
on this harness has an `implemented` flip from `/build-tdds` yet). After
that file exists, ignore `build-engine: bootstrap` and queue those TDDs
normally.

Optional argument: a TDD path builds just that one.

`tl_run_init "$REPO" "<run-id>"` if starting fresh. `run-id` is a UTC
timestamp `YYYYMMDD-HHMMSS`.

## 5. Confirm queue + mode

Ask a structured question. Modes:

- **sequential** (default) — stack `build/<run>/<slug>` on the previous
  TDD branch; one PR per TDD. Downstream `blocked` on halt (FR-16).
- **`--combined`** — one branch, one PR.
- **`--parallel`** — independent worktrees. A failure affects only that
  TDD.

## 6. Worktree (FR-20)

`git worktree add .worktrees/build-tdds-<slug>` from integration (or
previous sequential HEAD). Install deps unless `THROUGHLINE_SKIP_DEPS=1`.
Call the worktree path `WT`. `REPO` stays the human checkout.

## 7. Implementer worker

Dispatch **one** implementer worker. It **must not spawn children**.

- Working directory = `$WT`.
- Model = `build=` from `tl_resolve_models`.
- Prompt: read the TDD + cited PRD FRs + accepted ADRs. Follow
  test-driven-development if that skill is present. Commit on the build
  branch. Do not flip Status. Do not open a PR.
- Parent creates an empty report file under the run dir and passes its
  path. The last line matching `^BUILD_RESULT: (OK|BLOCKED)$` is
  authoritative.

`BLOCKED` → append `docs/tdd/BLOCKERS.md` (FR-17),
`tl_run_set_tdd "$REPO" "$run" "$slug" blocked design-escalation`,
unlock, **stop**.

If worker exit or stderr matches `rate.?limit|usage.?limit|ECONNRESET`
(or rc 143/130) → `tl_run_set_tdd … paused <cause>`, unlock, **stop**
(FR-41). Genuine non-zero without that pattern → `failed` + `gate-fail`,
unlock, **stop**.

Continue only on `BUILD_RESULT: OK`.

## 8. Mechanical gates

Run in `$WT`; write verdicts against `"$REPO"`.

8a. `tl_test_first_observe "$WT"` → `tl_verdict_write "$REPO" "$run"
"$slug" test-first` (`PASS` iff observe rc 0, else `FAIL`). FAIL →
`tl_run_set_tdd … failed gate-fail`, unlock, **stop**.

8b. `bash "$(tl_plugin_root)/scripts/ci-checks.sh"` in `$WT`. Transient
retry (FR-42): re-run up to `THROUGHLINE_TRANSIENT_RETRY` (default 2) if
rc is 143/130 or stderr matches `rate.?limit|usage.?limit|ECONNRESET`.
After retries exhaust on a transient pattern → `paused` (never
`failed`), unlock, **stop**. Non-transient non-zero → write `ci-checks`
`FAIL`, `failed` + `gate-fail`, unlock, **stop**. rc 0 → write
`ci-checks` `PASS`.

## 9. Runtime-verify worker

Dispatch **one** runtime-verify worker (different process/context).
**must not spawn children.** Model = `verify=` from `tl_resolve_models`
(pass the TDD `## Verification plan` text).

Parent creates an empty report file and passes its path. Worker drives
the TDD verification plan and writes a last line
`^VERIFY_RESULT: (PASS|FAIL|BLOCKED|SKIP)$`. `SKIP` requires a following
`EVIDENCE: <non-empty>` line. Missing token → FAIL. Transient stderr/rc
→ `paused` (FR-41), do not write FAIL.

Parent then `tl_verdict_write "$REPO" "$run" "$slug" runtime-verify`.
FAIL or BLOCKED → halt (`failed`/`blocked`), unlock, **stop**. PASS or
SKIP (with evidence) → continue.

## 10. Reviewer worker

Dispatch **one** reviewer worker on the prior-gen top-tier model
(`review=` from `tl_resolve_models`). Read-only. **must not spawn
children.**

Inputs: TDD path, `git diff` of the build branch vs integration,
optional `agents/security-reviewer.md` if that file exists.

Parent creates an empty report file and passes its path. Accept the
token only as a whole line `^REVIEW_RESULT: (PASS|FAIL)$` (last matching
line wins — not a mid-prose scrape). No such line → FAIL.

Parent writes `review.json` via `tl_verdict_write`. FAIL → halt, unlock,
**stop**. PASS → continue.

## 11. Flip + PR (never merge)

`tl_verdict_require_flip "$REPO" "$run" "$slug"` must be 0. Then:

- Flip TDD `Status: implemented` on the **build branch** (not
  integration).
- `gh pr create` (never merge) (NFR-1).
- Write the FR-19 report under the run dir.
- Create `docs/tdd/.implement-logs/.first-flip-done` (empty marker) on
  the first successful flip (FR-84).
- `tl_run_set_tdd "$REPO" "$run" "$slug" done`
- `tl_run_set_pr "$REPO" "$run" "$slug" "<url>"`
- Unlock.

## Halt rule (ADR 0013 / FR-16)

After every terminal outcome: continue to the next step only on
implementer `BUILD_RESULT: OK`; `test-first` PASS; `ci-checks` PASS;
`runtime-verify` PASS or SKIP; `review` PASS. Otherwise:
`tl_run_set_tdd` to `paused` (transient class after FR-42 exhaust:
`ratelimit` / `usage-limit` / `transient`), `blocked`
(`BUILD_RESULT: BLOCKED`, FR-67 `structural-finding`, FR-17
`design-escalation` / `external-blocker`), or `failed` (`gate-fail` for
a non-transient FAIL); unlock; **stop**. Do not dispatch later workers.
In sequential mode, remaining queued TDDs become `blocked`.

## Notes

- Progress snapshot is `/implement-status` (TDD 0063). This skill does
  not render it.
- Integration branch: origin default → `main` → `master`; override
  `THROUGHLINE_INTEGRATION_BRANCH`.
- Models: `tl_resolve_models` is the only product-name binding (ADR
  0009). Overrides: `THROUGHLINE_BUILD_MODEL`,
  `THROUGHLINE_REVIEW_MODEL`, `THROUGHLINE_RUNTIME_VERIFY_MODEL`.
- Sequential stacked PRs: merge bottom-up; enable auto-delete of head
  branches so GitHub retargets. Or use `--combined`.

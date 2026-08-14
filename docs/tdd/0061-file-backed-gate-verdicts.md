# TDD 0061: File-backed four-gate verdicts and durable run record

Status: implemented
build-engine: bootstrap
PRD refs: FR-15, FR-16, FR-25, FR-27, FR-39, FR-40, FR-41, FR-42, FR-43, FR-44, FR-45, FR-63, FR-64, FR-67, FR-70, FR-82
PRD-rev: 373cd89
ADR constraints: 0004, 0005, 0006, 0011, 0013
Supersedes: 0056, 0024, 0030, 0032

## Approach
Flip authority is four JSON files per TDD per run (ADR 0011). A thin
`run-record` library stores queue/status/halt for resume and
`/implement-status`. Neither library reads a harness transcript. The old
stream-json / `BATCH_RESULT` / `STEP_COMMIT` channel is not used.

## Components & interfaces
- Every path below is under `<repo-root>/docs/tdd/.implement-logs/…`.
  `<repo-root>` is a required first argument to every `tl_verdict_*` and
  `tl_run_*` function (absolute path of the human session / integration
  checkout). Functions must not use the process cwd. The build worktree
  is never `<repo-root>` (`.implement-logs` is gitignored and would
  fork per worktree).
- `scripts/lib/verdicts.sh` (sourceable, no top-level side effects):
  - `tl_verdict_dir <repo-root> <run-id> <slug>` →
    `<repo-root>/docs/tdd/.implement-logs/<run-id>/<slug>`
  - `tl_verdict_write <repo-root> <run-id> <slug> <gate> <status> <evidence>`
    writes `<gate>.json` atomically (`mktemp` + `mv`). `<gate>` is exactly
    one of `test-first|ci-checks|runtime-verify|review`. `<status>` is
    exactly one of `PASS|FAIL|BLOCKED|SKIP`. Reject any other token (rc 2,
    stderr names the bad token).
  - `tl_verdict_read <repo-root> <run-id> <slug> <gate>` prints the JSON
    or rc 1 if missing (not 0-with-empty).
  - `tl_verdict_require_flip <repo-root> <run-id> <slug>` returns 0 iff
    `test-first`, `ci-checks`, and `review` are `PASS` and
    `runtime-verify` is `PASS` or `SKIP` with non-empty `evidence`.
    Missing file → rc 1. `SKIP` with empty evidence → rc 1.
  - `tl_test_first_observe <git-dir>` exits 0 if `git -C <git-dir> log
    --format=%s` contains a `test(failing):` commit before the first
    `feat:` / `step(` commit on the unique commits vs the integration
    merge-base; otherwise rc 1. Does not parse assistant text.
- `scripts/lib/run-record.sh` (sourceable, no top-level side effects):
  - `tl_run_init <repo-root> <run-id>` writes
    `<repo-root>/docs/tdd/.implement-logs/<run-id>/run.json`
    `{ "run_id", "status": "running", "started_at", "updated_at",
    "tdd_total": 0, "tdd_done": 0 }` (timestamps ISO-8601) and points
    `<repo-root>/docs/tdd/.implement-logs/latest` at that dir.
  - `tl_run_set_tdd <repo-root> <run-id> <slug> <status> [halt_cause] [current_gate]`
    upserts `<slug>.json` atomically:
    `{ "slug", "status", "halt_cause", "queue_index", "current_gate",
    "started_at", "updated_at", "pr_url", "log_path" }`.
    First insert assigns `queue_index` = `tdd_total` then increments
    `run.json.tdd_total`. Later calls keep `queue_index` and
    `started_at`; refresh `status`, `updated_at`, `current_gate`,
    `log_path` (= verdict dir). `pr_url` is set only by
    `tl_run_set_pr <repo-root> <run-id> <slug> <url>`.
    `<status>` is
    `pending|building|verifying|reviewing|done|failed|blocked|skipped|paused`.
    `halt_cause` if set must be one of
    `ratelimit|usage-limit|transient|resume-blocked-build-state-missing|resume-blocked-branch-missing|resume-blocked-branch-divergence|structural-finding|design-escalation|external-blocker|gate-fail`
    (0018 enum minus retired rework-* plus `gate-fail` for ADR 0013).
    Unknown cause → rc 2. Updates `run.json` `updated_at` / `tdd_done`.
  - `tl_run_lock <repo-root>` / `tl_run_unlock` / `tl_run_lock_reclaim`
    implement FR-18/FR-43 using
    `<repo-root>/docs/tdd/.implement-logs/.run.lock` as `PID`.
    Reclaim if `kill -0` fails.
  - `tl_run_next_gate <repo-root> <run-id> <slug>` prints the first of
    `test-first,ci-checks,runtime-verify,review` whose file is missing or
    whose status is not a completed `PASS`/`SKIP`. If all four satisfy
    `tl_verdict_require_flip`, print `flip`.
- `/implement-status` rendering is TDD 0063 (`scripts/status.sh`). This
  TDD only supplies the libraries.

## Data & state
Paths above. JSON via `scripts/lib/json.sh` (`tl_json_escape`) — do not
hand-roll an escaper (FR-74 / L-005).

## Sequencing / implementation plan
1. Add `verdicts.sh` + `tests/verdicts.test.sh` (write/read/require;
   reject bad gate/status; `SKIP` without evidence fails require; missing
   file is rc 1 not empty PASS).
2. Add `tl_test_first_observe` + tests against a temp git repo
   (failing-then-feat passes; feat-only fails; empty repo fails).
3. Add `run-record.sh` + `tests/run-record.test.sh` (init, set_tdd,
   lock reclaim when PID dead, `next_gate` order, atomic write: a
   `kill -9` mid-write fixture still parses as prior or new).
4. Flip `Status:` only on `docs/tdd/0056-authored-verdict-channel.md`,
   `0024-build-completion-recording-and-intra-build-resume.md`,
   `0030-coproc-verdict-resilience.md`,
   `0032-step-commit-protocol-robustness.md` to `superseded by 0061`.

## Failure modes & edge cases
- **Real:** `jq` absent. Mitigation: write JSON with `tl_json_escape` +
  printf only (already in `json.sh`). Reading uses `tl_json_field` from
  `json.sh`, not `jq`.
- **Real:** slug contains `/`. Mitigation: reject slug unless it matches
  `^[a-z0-9][a-z0-9.-]*$`.
- **Overblown:** concurrent writers on one slug — FR-18 single-run lock
  is the mitigation; no extra file locking inside verdicts.sh.
- **Unspoken:** a worker writes `review.json` `PASS` before the other
  three exist. `require_flip` still fails. Do not treat a lone review
  PASS as flip.

## Verification plan
- **Surface:** function rc, file contents, `git log` in a fixture repo.
- **Observation points:**
  1. `tl_verdict_write "$PWD" r s test-first PASS 'git log …'` creates
     `$PWD/docs/tdd/.implement-logs/r/s/test-first.json` with
     `"status":"PASS"`.
  2. `tl_verdict_require_flip "$PWD" r s` is rc 1 until all four gates
     are written as specified; then rc 0.
  3. `tl_verdict_write "$PWD" r s review WHATEVER x` is rc 2.
  4. Fixture repo with only `feat: x` → `tl_test_first_observe` rc 1;
     add `test(failing): x` then `feat: x` → rc 0.
  5. After `tl_run_set_tdd r slug paused ratelimit`,
     `tl_json_field status` on `slug.json` is `paused`.
- **PASS:** all five hold. `bash tests/verdicts.test.sh` and
  `bash tests/run-record.test.sh` exit 0.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Traceability | Every in-scope FR/NFR maps to a named component | One compound mapping still checkable | Untraced or hand-waved FR |
| Interface concreteness | Paths, env vars, JSON fields, and command names are literal | One interface described by role not path | "the helper", "appropriate adapter" |
| Alternatives | Each new dep has a named rejected alternative | No new deps; section says why | New dep with empty alternatives |
| Verification plan | Surface + command/observation + PASS values | Observable but a bit indirect | "tests pass" / missing |
| Scope bounds | Touched files ≤8, estimates padded, exceptions declared | One justified exception | Over bound with no exception |
| Naming | Same concept same name across all four TDDs | One alias noted | /implement vs /build-tdds mixed as the required surface |
| Supervisor-free | No TDD requires parsing stream-json or nesting reviewers | Mentions old runner only as deletion target | Designs a coprocess as flip authority |

## Requirement traceability
- FR-15 / FR-82 → `tl_verdict_require_flip`
- FR-16 / FR-63 / FR-41 → `tl_run_set_tdd` statuses + `halt_cause`
- FR-25 → `SKIP` only with evidence
- FR-27 / FR-44 / FR-45 → `run-record.sh` + latest symlink
- FR-39 / FR-40 → `tl_run_next_gate`
- FR-42 → not implemented here (retry lives in 0062's dispatch loop). Gap:
  0062 must call write only after retries.
- FR-43 / FR-18 → lock reclaim
- FR-64 → 0063 `status.sh` rendering; this TDD supplies the fields.
- FR-67 / FR-70 → `BLOCKED` + evidence string; no transcript parse
- FR-70 → flip reproducible from the four JSON files + git

## Dependencies considered
No new deps. Rejected: SQLite for run-record (adds a binary; JSON files
already match FR-27). Rejected: reuse `scripts/lib/state.sh` 29-positional
writer (that API is the coprocess record; a new fail-closed pair is
smaller than extending it).

## PRD conflicts surfaced (and resolution)
None.

## Decisions to promote (ADR candidates)
ADR 0011 (already written).

## Touched files
- `scripts/lib/verdicts.sh` — write/read/require + test-first observe
- `scripts/lib/run-record.sh` — run/tdd/lock/next_gate
- `tests/verdicts.test.sh` — verdict + test-first evals
- `tests/run-record.test.sh` — record + lock + next_gate
- `docs/tdd/0056-authored-verdict-channel.md` — Status line
- `docs/tdd/0024-build-completion-recording-and-intra-build-resume.md` — Status line
- `docs/tdd/0030-coproc-verdict-resilience.md` — Status line
- `docs/tdd/0032-step-commit-protocol-robustness.md` — Status line

## Expected diff size
- `scripts/lib/verdicts.sh` — 170 lines
- `scripts/lib/run-record.sh` — 170 lines
- `tests/verdicts.test.sh` — 240 lines
- `tests/run-record.test.sh` — 240 lines
- `docs/tdd/0056-authored-verdict-channel.md` — 2 lines
- `docs/tdd/0024-build-completion-recording-and-intra-build-resume.md` — 2 lines
- `docs/tdd/0030-coproc-verdict-resilience.md` — 2 lines
- `docs/tdd/0032-step-commit-protocol-robustness.md` — 2 lines
Total expected diff: 828 lines across 8 files.

# TDD 0008: Run progress visibility

Status: implemented
PRD refs: FR-27, FR-28, FR-29, FR-30 (new); NFR-4 (estimate-labeling delta)
PRD-rev: 962732c
ADR constraints: 0003

## Approach
The detached `/implement` runner publishes a structured run-state record as it
progresses; a `/implement-status` command renders an on-demand snapshot from it, and
a foreground `--follow` watch refreshes the same render live until Ctrl-C. The record
is the single source of truth; one shared renderer serves both snapshot and follow, so
the honesty rules (estimate-labeled percent, never 100% before terminal, read-only)
are enforced in exactly one place. No daemon, no control actions — read-only
observability inside the TUI, matching the PRD's pinned constraint that "live" means
follow-until-interrupt via a foreground `!` command.

## Components & interfaces
1. **Run-state record (FR-27)** — a per-run directory
   `docs/tdd/.implement-logs/<ts>/state.d/` of atomic fragments. Each writer owns its
   own file, so there is no lock and no race even under `--parallel` (which forks a
   subshell per TDD that cannot share the parent's bash arrays):
   - `run.json` — `{schema, started_at, updated_at, pid, integration_branch, mode,
     change, logdir, total, completed, failed, blocked, skipped, state}` where
     `schema` is the integer `1` (bumped only on a breaking record-format change) and
     `state ∈ {running, done}`.
   - `<slug>.json` per TDD — `{n, slug, path, queue_pos, status, stage, started_at,
     updated_at, branch, pr_url, log, note}` where `n` is the TDD's numeric prefix
     (e.g. `7` for `0007`, for display as "TDD 0007") and `queue_pos` is its 1-based
     position in THIS run's build order (the two differ when only a subset is built),
     and
     `status ∈ {pending, building, verifying, reviewing, done, failed, blocked, skipped}`
     (the FR-27 enum) and `stage ∈ {build, test-first, verify, verify-runtime, review,
     flip, null}` (the finer current step; `verify-runtime` is the gate added by
     TDD 0007).
   - `docs/tdd/.implement-logs/latest` — a symlink to the active run's `<ts>` dir.
     The single-run lock (FR-18) guarantees one run, so `latest` is unambiguous.
2. **`scripts/implement.sh` (modified)** — helpers, writing fragments atomically
   (`printf` JSON via a `json_escape` for the free-text fields `note`/`branch`/`pr_url`;
   write to `<file>.tmp` then `mv`):
   - `state_init` — at run start: create `state.d/`, point `latest` at it (via
     `ln -sfn`; the single-run lock means one writer and `latest` is written once, so
     the non-atomic relink window is inconsequential), write `run.json` (state
     `running`, `total=${#TDDS[@]}`, counts 0) and a `<slug>.json` per queued TDD with
     its `queue_pos`. A TDD that resume-safety will pre-skip (already `implemented` on
     an existing branch) is written `status: skipped` here, NOT `pending`, so the
     fragment count always matches `total` — important under `--parallel`, where
     pre-skipped TDDs never enter the subshell pool and would otherwise have no
     fragment.
   - `set_run_state` — rewrite `run.json` (refresh `updated_at`, rollup counts,
     `state`).
   - `set_tdd_state <slug> <status> <stage> [note]` — rewrite that TDD's `<slug>.json`
     (refresh `updated_at`; carry `branch`/`pr_url` as they become known).
   Instrument every transition in `gate_one` and the three drivers:
   `pending → building(stage build) → verifying(stage verify) → verifying(stage
   verify-runtime) → reviewing(stage review) → done | failed | blocked | skipped`;
   set `branch`/`pr_url` after PR creation; `set_run_state … done` at the end. Parallel
   workers each write their own `<slug>.json` from inside their subshell.
3. **`scripts/status.sh` (new)** — THE renderer + estimator (single source of the
   view, so FR-30 honesty lives once). Resolves the run from `--logdir <dir>` else
   `latest`. One-shot by default; `--follow [secs]` (default 3) clears the screen and
   reprints every N seconds until SIGINT, with a `trap … INT` for a clean exit that
   never signals the build. Reads fragments via `jq` → `python3` → a minimal `bash/sed`
   fallback (all optional; the bash path always works ⇒ no hard dependency). Renders:
   - header: mode, integration branch, elapsed, and
     `"<completed> done / <total>  ·  ~<P>% (estimate)"`;
   - a per-TDD table: queue pos, slug, status, current stage, PR (if any);
   - the current TDD + stage, and log / PR pointers.
   Estimate (TDD- and stage-aware, FR-28): each TDD is worth `1/total`; an in-progress
   TDD contributes a coarse stage fraction (building 0.2, verify 0.5, verify-runtime
   0.7, review 0.85); terminal TDDs (done/skipped/failed/blocked) contribute 1.0, so
   `P` reaches 100 exactly when every TDD is terminal. FR-30: `P` is always suffixed
   `(estimate)`; the renderer never prints `100%` while any TDD is non-terminal; it
   offers no pause/resume/cancel and takes no action on the run. No active run (the
   `.run.lock` PID is absent or dead) → print `no active /implement run` (plus the last
   run's final summary if a `latest` exists) and exit 0.
4. **`skills/implement-status/SKILL.md` (new, `/implement-status`)** — runs
   `status.sh` once via a single Bash call and relays the snapshot. For live mode it
   instructs the user to run, themselves,
   `!bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" --follow` (foreground; Ctrl-C to
   exit). The skill NEVER runs `--follow` through the Bash tool (an endless foreground
   loop would block the session). It states plainly when no run is active. Read-only:
   it offers no run-control.
5. **Docs** — `skills/implement/SKILL.md` cross-links `/implement-status` (snapshot)
   and the `!…status.sh --follow` watch; note the record location.

## Data & state
- The `state.d/` fragment directory is the single source of truth (FR-27); it lives
  under the run's `LOGDIR` (inside `docs/tdd/.implement-logs/`), so it shares the run's
  lifetime. The repo currently has NO `.gitignore`, so this design adds one entry —
  `docs/tdd/.implement-logs/` — so run state, logs, and the lock are never accidentally
  committed (a small gap inherited from TDD 0005's log tree, closed here since this TDD
  is what populates it with per-transition fragments).
- The `latest` symlink is for discovery; the existing `.run.lock` (FR-18) is what
  distinguishes an active run from a finished one. **Hardening (added via
  TDD 0011's review):** the runner resolves `latest` via `readlink` and refuses
  to proceed if the resolved target is outside `docs/tdd/.implement-logs/`. The
  threat model is local only — anyone with write access to the gitignored log
  dir already has write access to the repo — but the one-line confinement
  check is belt-and-suspenders defense in shared-repo dev environments
  (devcontainers, shared CI runners) where the log dir and the script source
  may have different trust boundaries. See TDD 0011 §"Failure modes" for the
  symlink-target validation.
- The rendered view is DERIVED on each read, never stored — so there is no second
  artifact to drift from the record.

## Sequencing / implementation plan
Add `json_escape` + `state_init`/`set_run_state`/`set_tdd_state` and the `latest`
symlink at run start → instrument every transition in `gate_one` and the three drivers
→ write `status.sh` (one-shot path first, then `--follow`, then the
`jq`/`python3`/`bash` readers and the estimator) → add the `/implement-status` skill →
add the `docs/tdd/.implement-logs/` entry to `.gitignore` (creating the file) →
cross-link from the implement skill. **Build on TDD 0007** (sequential/stacked): the
`verify-runtime` stage label this design records is the gate 0007 introduces.

## Failure modes & edge cases
- Concurrent writers under `--parallel` → each owns its `<slug>.json`; only the parent
  writes `run.json` → no races, no `flock` (which macOS lacks).
- Crashed runner (`kill -9`) → the lock PID is dead → `status.sh` reports `no active
  /implement run` plus the last state and exits; it never hangs.
- Neither `jq` nor `python3` present → the `bash/sed` fallback renders the top-level
  rollup and one line per TDD (degraded but functional).
- `--follow` vs. the build → `status.sh` only READS fragments and never signals the
  build PID, so the detached build is unaffected; Ctrl-C exits the watch and the
  session is intact (FR-29 acceptance).
- Partial fragment mid-write → atomic `tmp` + `mv` means a reader sees either the old
  or the new file, never a torn one.
- No run has ever started → `no active /implement run`, exit 0 (FR-28 acceptance).
- Honesty (FR-30) → a non-terminal TDD keeps `P < 100`; a terminal-but-failed TDD
  counts toward 100 only once ALL TDDs are terminal, so 100% never implies success,
  only completeness; failed/blocked counts are reported separately and honestly.

## Verification plan
- **Observable surface:** `status.sh` stdout (the rendered snapshot) and the
  `state.d/` fragments a run writes.
- **Observation points:**
  1. Run `implement.sh` on a small fixture set; while it runs, run
     `bash scripts/status.sh` and read stdout.
  2. Run `bash scripts/status.sh` with no active run.
  3. `cat docs/tdd/.implement-logs/latest/state.d/*.json` during a run.
  4. Run `bash scripts/status.sh --follow 1` for a few seconds during a run, then
     Ctrl-C; afterwards confirm the detached build's `report.md` still reaches "Done".
- **Expected observations (PASS):** (1) stdout shows total, completed/total, a percent
  suffixed `(estimate)`, the current TDD + stage, and per-TDD statuses that match the
  fragments; (2) prints `no active /implement run` and exits 0; (3) each fragment's
  `status`/`stage` reflects the live transition; (4) the follow view refreshes and
  exits cleanly on Ctrl-C while the build's `report.md` still completes; percent never
  shows `100%` while any TDD is non-terminal.
- Mechanism: plain shell observation of stdout + files (artifact-appropriate;
  delegated, not bundled).

## Requirement traceability
- FR-27 → `state.d/` fragments (`run.json` + per-TDD `<slug>.json`) written atomically
  at each transition; the enumerated `status`/`stage` values; single source of truth.
- FR-28 → `status.sh` one-shot snapshot + the `/implement-status` skill:
  completed/total, estimate-labeled percent (TDD- and stage-aware), current TDD/stage,
  per-TDD statuses, elapsed time, log/PR pointers; the "no active run" message.
- FR-29 → `status.sh --follow` foreground watch (read-only, Ctrl-C exits), launched as
  a `!` command; where that is unsupported, the one-shot snapshot (FR-28) satisfies the
  need.
- FR-30 → percent always labeled `(estimate)`; never 100% before all TDDs terminal;
  the renderer offers no pause/resume/cancel (read-only).
- NFR-4 (delta) → the "progress estimates are labeled as estimates" clause is
  satisfied by the renderer's mandatory `(estimate)` suffix (FR-30); the verdict-honesty
  clause is owned by TDD 0007.

## Dependencies considered
No new hard dependency. Record format **JSON** (chosen): machine-readable (FR-27),
parsed natively by the snapshot skill and, in `status.sh`, via `jq` → `python3` → a
`bash` fallback (all optional; the pure-bash last resort means no hard dep). Rejected:
a **single `state.json` + `flock`** — `flock` is absent on macOS, and a single file
races under `--parallel`; a **pre-rendered text file as the source** — it would drift
and violate single-source-of-truth (FR-27), so the rendered view is derived instead; a
**background daemon / HTTP dashboard** — an extra long-lived service with its own
lifecycle, overkill for one local run, and Claude Code has no always-on pane to host
it (see the ADR 0005 candidate); **flat TSV** — no nesting for the run + per-TDD
rollup, while JSON is barely larger and far more parser-friendly.

## PRD conflicts surfaced (and resolution)
None. The PRD constraints already pin "live = follow-until-interrupt via a foreground
`!` command" and "read-only, no run-control"; this design implements exactly that. No
`BLOCKERS.md` entries.

## Decisions to promote (ADR candidates)
ADR 0005 (CONSIDERED this round, NOT promoted): "`/implement` progress visibility is a
read-only TUI follow over a run-state record — no daemon, no run-control." The decision
itself stands and is binding via this TDD + the PRD's "read-only observability"
constraint and non-goals; it was judged not (yet) durable/cross-cutting enough to spend
an ADR slot. Revisit if a future change is tempted to add a daemon or run-control.

# TDD 0036: Watcher completion ceiling is inactivity-based, not total wall-clock — no false-complete on long runs

Status: draft
PRD refs: FR-72, FR-39 (gap-closure); NFR-4
PRD-rev: d289607
ADR constraints: 0004, 0005, 0007

## Approach

`scripts/implement-watch.sh` is the harness-tracked bridge that polls the
nohup'd build and exits to trigger the session's run-completion callback (FR-72).
Its poll loop has three exit conditions: the build PID is gone, a `SIGUSR1` from
the run-end hook (genuine completion), or `elapsed >= MAX`
(`THROUGHLINE_WATCH_MAX_SECS`, default 14400s / 4h). The third is a **total
wall-clock ceiling**. A long multi-TDD `--resume` run (observed 2026-06-03:
0029→0032→0033, ~11h) exceeds 4h, so the watcher hits the ceiling and exits
emitting `IMPLEMENT_RUN_COMPLETE … state=running` while the build is alive and
healthy — dropping the auto-callback and (worse) letting the session's
completion path run the candidate-learnings review against a still-running build.

The ceiling's stated purpose (the comment at `implement-watch.sh:36`) is so "a
wedged build can't pin the watcher forever" — i.e. it should bound a *hung*
build, not a *long-but-progressing* one. This TDD makes it do exactly that:
replace the total-elapsed bound with an **inactivity** bound. The watcher exits
as wedged only when nothing under the run directory has advanced for MAX seconds
— a streaming/transitioning build resets the clock continuously, so a healthy
long run is never false-completed; a genuinely hung build (no log growth, no
state writes) still exits after MAX.

Two coordinated changes:
1. **The watcher** measures inactivity (not total elapsed) and, on a wedge exit,
   reports a DISTINCT state (`watcher-timeout`) instead of `running` — honest
   per NFR-4 (a running build is never reported as a normal completion).
2. **The `/implement` skill's completion-callback** treats a non-terminal state
   (`watcher-timeout`, `running`, …) as "the build may still be alive": it
   re-arms a build-PID poll instead of running the candidate-learnings review.

This respects ADR 0007 (no change to the halt model — this is liveness bridging,
not a gate), ADR 0005 (the watcher remains a mechanical poller; the wedge
decision is a file-mtime read, not a judgment), and ADR 0004 (verification gates
are untouched).

## Components & interfaces

### 1. Inactivity-based poll loop — `scripts/implement-watch.sh`

The poll loop (currently `while :; kill -0 BUILD_PID || break; WOKEN check;
elapsed >= MAX check; sleep; elapsed += POLL`) is changed:
- **Drop** the `elapsed` accumulator and the `elapsed >= MAX` branch.
- **Capture `WATCH_START="$(date +%s)"` once BEFORE the poll loop** — the epoch
  second the watcher began. This is the startup-window guard (see below); it is a
  loop-invariant, read every iteration, never reassigned.
  - **Ordering invariant (load-bearing).** `WATCH_START` is captured immediately
    before the loop — i.e. AFTER the `nohup bash "$BUILD_SCRIPT"` launch but
    before the first probe. The new build cannot have written anything under
    `latest/` at capture time: it must first start, acquire the single-run lock,
    and run `state_init` (which relinks `latest` and writes the new `run.json`),
    all of which happen strictly after `nohup` returns. Therefore every
    current-run write necessarily carries an mtime `≥ WATCH_START`, and every
    file with mtime `< WATCH_START` is provably a stale prior-run artifact — which
    is exactly what makes `newest < WATCH_START` a sound "skip the wedge" signal.
- **Add** an inactivity probe each iteration. `MAX` is reinterpreted as the
  inactivity window (same env var `THROUGHLINE_WATCH_MAX_SECS`, same default;
  the meaning shifts from "total run cap" to "max silence before declaring
  wedged"). Each poll:
  - Compute the newest modification time under the active run dir:
    `newest = max(mtime)` over the regular files in `"$LOGS_DIR/latest/"`
    (recursively — this covers both the per-TDD build logs, which grow
    token-by-token as the coprocess streams, AND `state.d/*.json`, which are
    rewritten at every status/stage transition). Implementation: a single
    `find "$LOGS_DIR/latest/" -type f -printf '%T@\n'` piped to a numeric
    max (or `stat`-based equivalent), taking the integer seconds.
  - **Startup-window guard (REQUIRED — fixes the stale-`latest` false-wedge).**
    The watcher launches and enters this loop BEFORE `implement.sh` relinks
    `latest` to the new run dir (the relink happens at the END of `state_init`,
    `implement.sh:302`, after lib-sourcing + single-run-lock acquisition + the
    per-TDD queue-discovery loop at `implement.sh:281-285`). During that window
    `"$LOGS_DIR/latest/"` still points at the PREVIOUS run's dir with its old
    mtimes. If the prior run finished `≥ MAX` ago, an unguarded `stale ≥ MAX`
    would fire on iteration 1 and false-wedge before the new build has written a
    byte. Guard: **treat any `newest < WATCH_START` as "the current run has not
    written yet" and SKIP the wedge check this iteration** (do not exit) — a file
    older than the watcher's own launch cannot be evidence of inactivity in the
    current run. Once `state_init` relinks `latest` and writes `run.json`
    (mtime `≥ WATCH_START`), the probe measures the current run normally. The
    PID-gone break remains the guaranteed terminator throughout.
  - `stale = now - newest` (both epoch seconds, same host clock).
  - If `newest >= WATCH_START` AND `stale >= MAX` → set `WEDGED=1` and break.
- The PID-gone (`kill -0 BUILD_PID` fails) and `WOKEN` (SIGUSR1) breaks are
  unchanged and keep their current precedence (checked before the inactivity
  probe each iteration), so a clean completion or crash still exits immediately.

### 2. Distinct wedge state on emit — `scripts/implement-watch.sh`

The completion-report block (which today derives `state` from
`run.json`'s `state` field, validated against
`running|done|paused|blocked|interrupted|failed` → else `unknown`) gains:
- `watcher-timeout` is added to the accepted state vocabulary.
- When `WEDGED=1`, the emitted `state` is forced to `watcher-timeout`
  REGARDLESS of `run.json` (which will still say `running` — the build is
  wedged mid-run). The PID-gone and USR1 exits continue to read `run.json` as
  today (a genuine terminal state).

The `IMPLEMENT_RUN_COMPLETE logdir=… state=… candidate_learnings=…` line shape
is otherwise unchanged.

### 3. Non-terminal-exit handling — `skills/implement/SKILL.md`

The "Detect pending candidate learnings → Auto (primary)" callback step gains a
state classification BEFORE the learnings review:
- **Terminal states** (`done`, `paused`, `blocked`, `failed`): proceed exactly
  as today — report run completion + state, and if `candidate_learnings=yes`
  run The review.
- **Non-terminal states** (`watcher-timeout`, `running`, `interrupted`,
  `unknown`): the build may still be alive. Read the build PID from the
  watcher's `launched build pid <PID>` stdout line. **PID source:** the harness
  delivers the watcher's FULL stdout to the re-invoked session (the same payload
  that carries the `IMPLEMENT_RUN_COMPLETE …` line also still carries the
  `launched build pid <PID>` line the watcher emitted at launch — both are in the
  watcher's task-output stream; this was directly observed). Parse the PID from
  that same payload — do NOT use `docs/tdd/.implement-logs/.watch.pid`, which the
  watcher removes on exit (its EXIT trap), so it is gone by the time this runs. If
  `kill -0 <PID>` succeeds,
  the build is still running — re-arm the callback by launching a background
  Bash poll (`while kill -0 <PID> 2>/dev/null; do sleep 60; done` then re-read
  the run state) as a harness-tracked job, report "build still running (watcher
  timed out); re-armed poll", and do NOT run the candidate-learnings review (it
  must not run against a live build — its `apply_accepted_learnings` writes
  `LEARNINGS.md` and marks the queue reviewed, which is premature if the run
  hasn't finished). If `kill -0 <PID>` fails (PID gone but state non-terminal),
  report the anomaly and point at the fallback review on the next `/implement`
  invocation (the existing FR-39 fallback that scans the latest logdir).

## Data & state

No run-state schema change. `watcher-timeout` is a new *value* in the watcher's
emitted-state vocabulary (Component 2), consumed by the skill (Component 3); it
is never written into `run.json` (the runner owns that; the watcher only reports
its own give-up signal on stdout). The inactivity probe is transient per-poll
(no persistence).

## Sequencing / implementation plan

1. **implement-watch.sh — poll loop**: replace the total-elapsed bound with the
   inactivity probe, including the `WATCH_START` capture before the loop and the
   `newest < WATCH_START` startup-window guard inside the probe (Component 1).
2. **implement-watch.sh — emit**: add `watcher-timeout` to the vocabulary and
   force it on `WEDGED=1` (Component 2).
3. **skills/implement/SKILL.md**: add the terminal-vs-non-terminal classification
   and the re-arm-poll instruction to the completion callback (Component 3).
4. **Eval**: add `tests/watcher-inactivity-completion.test.sh` driving the
   watcher against a stub build via `THROUGHLINE_WATCH_BUILD_SCRIPT` with a short
   `THROUGHLINE_WATCH_MAX_SECS`/`POLL`. Includes the §6 stale-prior-run-`latest`
   case (pre-seed `run0/` with old mtimes, `latest -> run0`, assert no
   iteration-1 false wedge), and every watcher-launching case uses the bounded
   background pattern (no synchronous invocation that can hang the aggregator —
   the §2 no-hang discipline).
5. **Wire the eval into the aggregator (do NOT defer):** add the
   `tests/watcher-inactivity-completion.test.sh` invocation to
   `tests/implement-gate.test.sh` in the SAME step (`*_FAIL` accumulator +
   conditional run + final-expression AND).

## Failure modes & edge cases

- **`latest/` unreadable or empty** (symlink missing, race at run start) →
  `find` yields no mtime. Treat as "cannot measure inactivity this poll": SKIP
  the wedge check for that iteration (do NOT exit) and keep polling. The
  PID-gone break remains the guaranteed terminator — when the build process
  dies, the watcher exits regardless. Residual: a build whose PID stays alive
  AND whose run dir is unreadable for the whole run would not wedge-exit; this
  is acceptable (a live PID means the build is running; a dead PID always
  exits). No silent total-time cap is reintroduced.
- **`latest/` exists but points at a STALE prior-run directory** (the startup
  window: the watcher entered the poll loop before `implement.sh`'s `state_init`
  relinked `latest` to the new run). `find` yields the prior run's newest mtime,
  which can be `≥ MAX` old → an unguarded probe false-wedges on iteration 1,
  emitting `watcher-timeout` before the current build writes anything. This is
  the regression the **startup-window guard** (Component 1) closes: `newest <
  WATCH_START` means no current-run file exists yet, so the wedge check is
  SKIPPED until `state_init` relinks `latest` and writes a fresh `run.json`. The
  PID-gone break still terminates a build that genuinely dies during this window.
  Without the guard, this fires reliably on any re-run started `> MAX` after the
  previous run completed (e.g. a "next day" build at the 4h default).
- **A legitimately silent gap** (e.g. a rate-limit backoff longer than MAX). At
  the 4h default this is effectively indistinguishable from wedged; emitting
  `watcher-timeout` (not a false `done`) keeps it honest — and this is where
  Component 3's re-arm path is load-bearing, not just a fallback: the build PID is
  still alive, so the skill re-arms a poll and the build, when the backoff clears,
  still completes and re-triggers the callback (a long legitimate gap costs only a
  re-armed poll, never a lost run or a premature learnings review). The window is
  tunable via the existing env var.
- **`THROUGHLINE_WATCH_MAX_SECS` non-numeric** → existing default-and-warn
  handling is preserved (the var is reinterpreted, not re-validated differently).
- **Clock source** — `find -printf '%T@'` and `date +%s` are both host epoch
  seconds; integer truncation of the fractional `%T@` is fine (sub-second
  precision is irrelevant at a ≥1s poll).
- **SIGUSR1 race** — unchanged: the `WOKEN`/PID-gone breaks are checked before
  the inactivity probe, so a build that completes cleanly within a silent window
  still exits via USR1/PID with the real terminal state, never `watcher-timeout`.

## Verification plan

**Observable surface:** the watcher's `IMPLEMENT_RUN_COMPLETE … state=<…>`
stdout line and WHEN it is emitted (the watcher process exiting); the
`skills/implement/SKILL.md` text.

**Observation points** (driven by `tests/watcher-inactivity-completion.test.sh`,
pointing the watcher at a stub build via `THROUGHLINE_WATCH_BUILD_SCRIPT` with
`THROUGHLINE_WATCH_MAX_SECS` and `THROUGHLINE_WATCH_POLL_SECS` set small, e.g.
3s/1s, and a stub `latest/` run dir):

1. **Progressing build past MAX → no false completion.** Stub build stays alive
   and appends to a file under `latest/` every < MAX seconds for ≥ 3×MAX, THEN
   goes silent. Observe: the watcher emits NO `IMPLEMENT_RUN_COMPLETE` while the
   stub keeps writing, and emits it only AFTER writing stops + ~MAX elapses,
   with `state=watcher-timeout`. (Confirms inactivity, not total-elapsed, governs
   the exit.) Assertion mechanism for the "has not exited yet" half: launch the
   watcher as a background process and assert `kill -0 <WATCHER_PID>` still
   succeeds during the writing phase — a process-alive check, NOT a string-absent
   grep on the (not-yet-written) output.
2. **Silent build for MAX → wedged exit, distinct state.** Stub build alive but
   writes nothing under `latest/` → the watcher exits within ~MAX (+1 poll) and
   emits `state=watcher-timeout` — NOT `state=running`, NOT `state=done`.
3. **PID-gone exit unchanged.** Stub build writes a terminal `run.json`
   (`state=done`) then exits → the watcher exits promptly emitting
   `state=done` (run.json passthrough preserved for real terminal exits).
4. **Clean USR1 completion unchanged.** With the stub alive, deliver `SIGUSR1`
   to the watcher (the run-end-hook path) → the watcher exits promptly and emits
   the run.json state (e.g. `done`), never `watcher-timeout`.
5. **Skill handling present (mechanical).** Grep `skills/implement/SKILL.md` for:
   the non-terminal-state classification (anchor on the new literal listing
   `watcher-timeout`), the re-arm-poll instruction (anchor: `kill -0` + a
   background poll), and the "do NOT run the candidate-learnings review on a
   non-terminal state" instruction.
6. **Stale prior-run `latest/` at startup → NO false wedge (the regression
   guard).** Pre-seed a `run0/` dir under `latest/`'s parent containing a
   `state.d/run.json` (and a build log) whose mtimes are set WELL in the past
   (`> MAX` ago — e.g. `touch -d` to `WATCH_START - 10*MAX`), and point
   `latest -> run0` BEFORE launching the watcher. The stub build stays alive and,
   after a short delay simulating `state_init`, relinks `latest -> run1` and
   writes a fresh `run.json` there. Observe: the watcher does NOT emit
   `state=watcher-timeout` during the stale-`latest` window (iteration 1 sees
   `newest < WATCH_START` and skips the wedge check) — asserted via a
   process-alive check (`kill -0 <WATCHER_PID>` still succeeds through the first
   polls), NOT a string-absent grep. After the relink + fresh write, normal
   inactivity behaviour resumes (a later silence still wedges with
   `watcher-timeout`). This case is what makes the finding-1 regression visible to
   the suite; without the guard the watcher would wedge-exit on iteration 1 here.

**Mechanical-check robustness (binding on this eval — L-001/L-002 mitigations).**
The §1–§6 checks MUST fail closed and assert specifically (see
`docs/tdd/LEARNINGS.md` L-001 `fragile-inversion` and L-002
`misleading-diagnostic`): any absence/removal assertion distinguishes grep
exit 1 (string absent) from exit ≥2 (file unreadable) and fails the eval on the
latter; every target file is asserted readable before its content checks run (no
unconditional check after an early `return`/`exit` on a missing file); and every
anchor is specific to text THIS change introduces (e.g. `watcher-timeout`), never
a phrase already present in `implement-watch.sh`/`SKILL.md`.

**No-hang discipline (binding — every timing-driven case).** EVERY case that
launches the watcher (§1, §2, §3, §6 — any that exercises the poll loop) MUST run
it as a BACKGROUND process (`… &`, capture `WATCHER_PID`) and gate progress on a
BOUNDED wait loop with a hard ceiling (e.g. ≤ `N` iterations of `sleep`, then
`kill "$WATCHER_PID"` and fail the case), NEVER a synchronous foreground
invocation. A synchronous invocation whose stub ends in a long `sleep` (the §2
wedge stub) would hang the whole `tests/implement-gate.test.sh` aggregator for the
stub's full duration on any inactivity-probe regression; the bounded background
pattern caps that blast radius to the test's own ceiling. §1 already uses this
pattern — §2/§3/§6 MUST match it (no `bash "$WATCH"` without `&` + a timeout
guard).

**Expected observations (PASS):** every numbered point yields the cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-72 (gap-closure: the run-completion watcher must signal *actual* completion, not a wall-clock timeout, so the post-run callback/learnings review runs against a finished run) | Component 1 (inactivity bound — a progressing build never trips it) + Component 3 (the callback runs the review only on a terminal state). Verification §1, §2, §5. |
| FR-39 (gap-closure: detached-run liveness/recovery — a watcher exit must not strand a live build without a recovery path) | Component 2 (`watcher-timeout` distinct signal) + Component 3 (re-arm a PID poll when the build is still alive; else point at the FR-39 fallback review). Verification §2, §5. |
| NFR-4 (state honesty: a running build is never reported as a normal completion) | Component 2: a wedge exit emits `watcher-timeout`, never `running`-as-done or a false `done`; PID-gone/USR1 still passthrough the true terminal state. The Component 1 `WATCH_START` startup-window guard prevents the inverse dishonesty — a brand-new run false-wedged on a stale prior-run `latest/` before it has written anything. Verification §2, §3, §4, §6. |

No gaps.

## Dependencies considered

No new external dependency. `find`/`stat` + `date` are already used across the
runner scripts; the inactivity probe reuses them.

Alternatives considered:
- **Raise the default `MAX` (e.g. to 24h)** — rejected: any fixed total-elapsed
  ceiling is exceedable by a large enough run and still false-completes at the
  boundary; it treats the symptom, not the cause (total-time vs inactivity).
- **Use `run.json`'s `updated_at` only as the progress signal** — rejected: it
  advances only at gate/status transitions, so a single long build step (no
  transition) could look stale and false-wedge. Newest-mtime-of-any-file under
  the run dir also captures the streaming build log, which advances continuously.
- **Have the build heartbeat the watcher (touch a liveness file / periodic
  SIGUSR2)** — rejected: adds a new build↔watcher protocol and a failure surface
  for zero benefit over reading the artifacts the build already writes (the logs
  and state.d). Reuses existing output rather than inventing a channel (ADR 0005
  spirit: observe artifacts, don't add machinery).

## PRD conflicts surfaced (and resolution)

None. FR-72 requires the watcher to bridge run completion to the session, and
FR-39 requires detached-run liveness/recovery; neither is contradicted — this
closes a gap where a wall-clock timeout masqueraded as completion. The fix is a
refinement of TDD 0022's watcher mechanism (cited, not superseded).

## Decisions to promote (ADR candidates)

None. A liveness-bound refinement within the existing watcher mechanism; no new
cross-cutting decision.

## Touched files

- `scripts/implement-watch.sh` — inactivity-based poll loop (drop total-elapsed) + `WATCH_START` startup-window guard (no stale-`latest` false-wedge) + `watcher-timeout` distinct wedge state on emit.
- `skills/implement/SKILL.md` — completion callback classifies terminal vs non-terminal state; re-arms a build-PID poll (and suppresses the learnings review) on a non-terminal exit.
- `tests/watcher-inactivity-completion.test.sh` — new eval (stub build via `THROUGHLINE_WATCH_BUILD_SCRIPT`; the four watcher-exit paths + the skill greps).
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Total: 4 files touched.

## Expected diff size

- `scripts/implement-watch.sh` — ~75 lines added/changed (replace the elapsed accumulator + `>= MAX` branch with the inactivity probe; the `WATCH_START` capture + the `newest < WATCH_START` startup-window guard; add `watcher-timeout` to the vocabulary and force it on wedge).
- `skills/implement/SKILL.md` — ~48 lines added (terminal/non-terminal classification + re-arm-poll instruction + the PID-source note).
- `tests/watcher-inactivity-completion.test.sh` — ~290 lines added (new eval: the timing-driven watcher-exit cases via a stub build incl. the §6 stale-`latest` startup-window case + 3 SKILL.md grep checks; every watcher-launching case uses the bounded background pattern; fail-closed assertions and file-readable guards per L-001/L-002).
- `tests/implement-gate.test.sh` — ~38 lines added (aggregator wire-in).

Total expected diff: ~451 lines across 4 files. No exceptions needed (each file is under the 300-line per-file bound).

# TDD 0022: Build-phase learning capture — recurring-pattern detection, run-completion notification, candidate review & persistence

Status: implemented
PRD refs: FR-72
PRD-rev: 52c32b9
ADR constraints: 0003, 0004, 0005, 0006, 0007

## Approach

After an `/implement` run completes, the per-TDD state fragments hold a rich
`findings` record (TDD 0021 §6: `pattern_tags`, `severity`, `structural`,
`source`, plus rework/escalation cross-references from TDDs 0019/0018), today
discarded at run-end. FR-72 mines it for *recurring* categorical patterns — a
finding class that appeared across more than one TDD or build step — and
surfaces them to the human to accept or discard.

Two facts shape the design: (1) **the runner is headless** — `implement.sh` runs
detached and is forbidden `AskUserQuestion` (TDD 0021 §5b(a)), so *detection*
(mining fragments, writing a candidate report) is the runner's job but the
*accept/discard prompt* must run in the interactive main session; (2) **the
detached runner must survive session close** (TDD 0011 / FR-39), so we cannot
foreground the build to get a completion callback.

The bridge is a thin **watcher** (`implement-watch.sh`): the `/implement` skill
launches it as a *harness-tracked* background job (so the harness re-invokes the
session when the watcher exits), and the watcher `nohup`s `implement.sh` (so the
real build still detaches and survives session close). The watcher polls for the
build's completion and exits, which returns control to the main session — where
the accept/discard review runs. If the session/watcher dies, the nohup'd build
finishes anyway; only the auto-callback is lost, and the review falls back to the
next `/implement` invocation. FR-39's survives-close property is untouched.

Accepted learnings are appended to `docs/tdd/LEARNINGS.md` — the quality-pattern
sibling of `BLOCKERS.md` (FR-17 captures structural infeasibilities; this
captures recurring quality patterns), read by TDD 0023.

## Components & interfaces

### 1. Recurring-pattern detection — new file `scripts/lib/learnings.sh`

A bash module sourced by `implement.sh` (after `state.sh`, whose
`_read_fragment_raw_array` it reuses). Public entry point:

```
detect_build_learnings <state_dir> <logdir> <mainrepo>   # FR-72 detection
```

Algorithm:

1. For every `<slug>.json` fragment in `<state_dir>` (skip `run.json`), read its
   `findings` array. Each finding carries `pattern_tags[]`, `severity`,
   `structural`, `source`, `region`, `summary`, `evidence`, and `pass_id`
   (TDD 0021 §6). The fragment's slug is the TDD identity; `pass_id` is the
   build-step identity (TDD 0020 per-step passes). All three `source` values
   (review, self-review, runner-check) are mined — each is a legitimate
   recurring-pattern signal.
2. Drop findings with `severity == "nit"`. Keep `{blocker, major, minor}`.
3. Group the surviving findings by **categorical class** = each `pattern_tag`
   (a finding with multiple tags contributes to each). For each class collect:
   the set of distinct slugs, the set of distinct `(slug, pass_id)` step pairs,
   whether any contributing finding had `structural: true` (a structural
   escalation, TDD 0019 §1), and whether any has `addressed_by_sha != null`
   (it triggered rework, TDD 0019). This single pass covers all three artifact
   classes FR-72 names — review findings, rework outcomes, structural
   escalations — because each is recorded as (or cross-referenced from) a
   `findings` entry.
4. A class is **recurring** when `count(distinct slugs) >= MIN` OR
   `count(distinct (slug,pass_id) steps) >= MIN`, where
   `MIN = THROUGHLINE_LEARNING_MIN_OCCURRENCES` (default 2). Severity is not
   weighted into the threshold beyond the nit exclusion in step 2; this is the
   resolution of the PRD's "recurring-pattern threshold" open question (see
   "PRD conflicts surfaced").
5. For each recurring class, compute **subject-area hints** to seed TDD 0023's
   matching: the union of the `## Touched files` path entries declared in each
   involved TDD's `docs/tdd/<slug>.md` (parsed by the same line shape the
   `tdd-lint.sh` touched-files check reads), plus the class's own `pattern_tags`.

Output (only when ≥1 recurring class is found):

- `<logdir>/candidate-learnings.json` — a JSON array, one object per class:
  ```
  { "class": "<pattern_tag>",
    "distinct_tdds": ["<slug>", ...],
    "distinct_steps": <int>,
    "severity_range": ["<min>", "<max>"],
    "was_structural": <bool>, "triggered_rework": <bool>,
    "subject_area_hints": { "files": ["<path>", ...], "tags": ["<tag>", ...] },
    "summary": "<class-representative one-liner>",
    "evidence": "<verbatim ≤4-line quote from one contributing finding>",
    "occurrences": [ { "slug": "<slug>", "pass_id": "<id>",
                       "severity": "<sev>", "region": "<file:line>" }, ... ] }
  ```
- A `## Candidate learnings (pending review)` section appended to
  `<logdir>/report.md`: one bullet per class naming the class, the TDDs/steps it
  recurred in, structural/rework flags, and the one-line summary, closed by the
  instruction "run `/implement` (or accept the completion callback) to accept or
  discard these."

When zero recurring classes are found, the function writes nothing — no
`candidate-learnings.json`, no report section (FR-72's negative-case acceptance).

### 2. Accepted-learning persistence — `scripts/lib/learnings.sh`

```
append_accepted_learning <mainrepo> <class> <files_csv> <tags_csv> \
                          <tdds_csv> <severity_range> <summary> <evidence> <runid>
```

Appends one entry to `<mainrepo>/docs/tdd/LEARNINGS.md` (creating the file with a
one-line header if absent). The entry schema — **defined here, consumed by
TDD 0023**:

```
## L-<NNN>: <class>
- Pattern class: <pattern_tag>
- Recurred across: <slug>, <slug>, ... (first observed run <runid>)
- Severity range: <min>–<max>
- Subject-area hints: files=[<path>, ...] tags=[<tag>, ...]
- Flags: structural=<bool> rework=<bool>
- Summary: <one-liner>
- Representative evidence: <≤4-line quote>
```

`<NNN>` is the next zero-padded integer after the highest existing `## L-`
heading (computed by scanning the file). **Idempotency:** before appending, the
helper checks for an existing entry whose `Pattern class` equals `<class>` AND
whose `files=` hint set intersects `<files_csv>`; if found, it appends the new
run id and any new slugs to that entry's `Recurred across` line instead of
creating a duplicate (a pattern that recurs across multiple runs reinforces one
entry). The write is atomic (temp-file + `mv`), matching `state.sh`'s convention.

### 3. The watcher — new file `scripts/implement-watch.sh`

Launched by the `/implement` skill as a harness-tracked background job (§4); it
is the only process attached to the session. Behavior:

1. Resolve the main repo's `docs/tdd/.implement-logs/` dir; write its own PID to
   `.implement-logs/.watch.pid`. Install the flag handler `trap 'WOKEN=1' USR1`
   (sets the flag and interrupts the sleep; not `trap '' USR1`, which would
   ignore the signal).
2. `nohup bash "<dir>/implement.sh" "$@" > .implement-logs/nohup.out 2>&1 &`,
   capture child PID `BUILD_PID`, and echo `launched build pid <BUILD_PID>` to
   stdout (the PID the skill reports). `"$@"` forwards every flag/scope the skill
   assembled (TDD path, `--parallel`, `--combined`, `--resume`, …) unchanged —
   the watcher is mode-agnostic.
3. Poll loop: `sleep $THROUGHLINE_WATCH_POLL_SECS` (default 30; `SIGUSR1`
   shortcuts the sleep), then exit the loop when **either** `kill -0 $BUILD_PID`
   fails (build process gone — covers crash-without-signal) **or** `WOKEN=1`
   (build signaled completion). A hard ceiling `THROUGHLINE_WATCH_MAX_SECS`
   (default 14400 = 4h, ≥ the build watchdog) bounds the loop so a wedged build
   cannot pin the watcher forever.
4. On exit: read `latest/state.d/run.json` `state` and test for
   `latest/candidate-learnings.json`. Print exactly one line to stdout:
   `IMPLEMENT_RUN_COMPLETE logdir=<abs> state=<done|paused|unknown> candidate_learnings=<yes|no>`
   then remove `.watch.pid` and exit 0. The watcher exiting is what the harness
   converts into a main-session re-invocation.

### 4. Runner run-end hook — `scripts/implement.sh`

In the existing terminal block (the `_any_paused` branch I/O at end of `main`):

- Source `scripts/lib/learnings.sh` alongside the other `lib/` modules.
- In the **`else` (done) branch only** — all TDDs terminal, FR-72's precondition
  — call `detect_build_learnings "$STATE_DIR" "$LOGDIR" "$MAINREPO"`, guarded so
  a detection failure is a logged warning, never fatal to the run.
- In **both** branches, after the terminal `set_run_state`: write
  `<logdir>/.run-complete` (`done`|`paused`) and wake the watcher —
  `_wp="$(cat "$MAINREPO/docs/tdd/.implement-logs/.watch.pid" 2>/dev/null)";
  [ -n "$_wp" ] && kill -0 "$_wp" 2>/dev/null && kill -USR1 "$_wp" 2>/dev/null`,
  all `|| true` (a dead/absent watcher is the survives-close fallback, not an
  error).

### 5. Interactive review & launch — `skills/implement/SKILL.md`

**Launch (replaces the current `nohup … implement.sh &`)**: the skill launches
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/implement-watch.sh" <flags>` via the Bash
tool with `run_in_background: true` (harness-tracked). The watcher `nohup`s the
real build per §3. The reported PID is the build's (the watcher echoes it).

**New step "Detect pending candidate learnings"** — surfaced two ways:

- *Auto (primary):* when the watcher's background job completes and re-invokes
  the session, read its `IMPLEMENT_RUN_COMPLETE` line. Always report run
  completion + state to the user (this is the status side-benefit — no more
  manual polling). If `candidate_learnings=yes`, proceed to the review.
- *Fallback:* at the top of a fresh `/implement` invocation (immediately after
  the existing "Detect interrupted run" step), if the most recent completed
  run's logdir holds an unreviewed `candidate-learnings.json`, run the review
  before showing the queue.

**The review:** read `candidate-learnings.json`; present all candidates in ONE
`AskUserQuestion` (`multiSelect: true`) — each option is a class with its
TDDs/summary; **selected = accept, unselected = discard** (FR-72: discarded are
not persisted). For each accepted class call `append_accepted_learning` (§2).
Then mark the report reviewed by renaming `candidate-learnings.json` →
`candidate-learnings.reviewed.json` (so neither path re-surfaces it). If the user
cancels, leave it unreviewed (re-surfaced next invocation). A run with no
`candidate-learnings.json` skips the review silently.

## Data & state

- `<logdir>/candidate-learnings.json` — transient per-run review queue; renamed
  to `.reviewed.json` once acted on.
- `docs/tdd/.implement-logs/.watch.pid` — live watcher's PID; removed on exit; a
  stale file is harmless (the `kill -0` guard skips it).
- `<logdir>/.run-complete` — completion marker the watcher's poll can read.
- `docs/tdd/LEARNINGS.md` — the durable accepted-learning store (§2 schema).

No per-TDD fragment schema change: detection reads the existing `findings` array
(TDD 0021 §6) plus TDDs' `## Touched files`; it adds no fragment field.

## Sequencing / implementation plan

1. `scripts/lib/learnings.sh` — `detect_build_learnings` (§1) +
   `append_accepted_learning` (§2): nit filter, distinct-TDD/step threshold,
   hint extraction, JSON + report writers, idempotent atomic append.
2. `scripts/implement-watch.sh` (§3) — PID file, `SIGUSR1` trap, nohup launch +
   flag passthrough, poll loop + ceiling, the `IMPLEMENT_RUN_COMPLETE` line.
3. Wire `scripts/implement.sh` (§4) — source `learnings.sh`; done-branch
   detection; `.run-complete` + watcher wake in both branches; all non-fatal.
4. Edit `skills/implement/SKILL.md` (§5) — watcher launch + the "Detect pending
   candidate learnings" review step (auto + fallback, `multiSelect` + rename).
5. `tests/build-phase-learning-capture.test.sh` (verification plan below).

## Failure modes & edge cases

- **Fragments predate the `findings` schema (0021 not yet built).**
  `detect_build_learnings` reads an absent/empty `findings` array as "no
  findings" → no recurring classes → no report. Graceful no-op; 0022 never
  breaks a pre-0021 runner. (Build order: 0022 lands after 0019–0021.)
- **Paused run.** Detection is gated to the done branch, so a paused run
  produces no candidate report; the watcher reports `state=paused`,
  `candidate_learnings=no`. The run isn't complete (a TDD is non-terminal), so
  FR-72 correctly does not fire until the resume completes.
- **Watcher/session dies mid-build.** Nohup'd build finishes; `.watch.pid` goes
  stale; `kill -USR1` no-ops under its guard. No auto-callback; fallback review
  fires at next `/implement`. FR-39 preserved.
- **Build crashes / single-run lock rejects it.** Either way `BUILD_PID` dies
  fast; the `kill -0` exit condition ends the watcher's loop, which reports
  `state=unknown`/whatever the run left and `candidate_learnings=no`. No false
  review (no fragments → no learnings).
- **Malformed/oversized `evidence`.** Both writers truncate `evidence` to 4
  lines and JSON-escape via `state.sh`'s `json_escape`; no unescaped newline
  corrupts the JSON or the store.
- **User cancels the review.** `candidate-learnings.json` stays unreviewed and
  re-surfaces next invocation; nothing persisted (FR-72: only the accepted
  subset persists).
- **Two recurring classes share a TDD set.** Each `pattern_tag` is its own
  candidate (N tags on a finding → N class contributions); accepted/discarded
  independently.

## Verification plan

**Observable surface:** `candidate-learnings.json`, the `report.md` candidate
section, `docs/tdd/LEARNINGS.md`, the watcher's `IMPLEMENT_RUN_COMPLETE` stdout
line, and the `skills/implement/SKILL.md` instruction text.

**Observation points & expected observations (PASS):**

1. **Recurring class detected.** Fixture: two `<slug>.json` fragments whose
   `findings` carry `pattern_tags: [evidence-not-grounded]` with `severity:
   major`. Call `detect_build_learnings`. Expect: `candidate-learnings.json`
   contains one object `class: "evidence-not-grounded"`, `distinct_tdds` lists
   both slugs, and `report.md` gains a `## Candidate learnings (pending review)`
   section naming the class and both TDDs.
2. **Below threshold → nothing.** Fixture: the tag appears in ONE fragment only,
   `MIN=2`. Expect: no `candidate-learnings.json` written, no report section
   (FR-72 negative case).
3. **Nit excluded.** Fixture: a `pattern_tag` appears across two fragments but
   every contributing finding is `severity: nit`. Expect: not surfaced.
4. **Threshold env override.** Fixture as §1 but `THROUGHLINE_LEARNING_MIN_OCCURRENCES=3`.
   Expect: not surfaced (only 2 distinct TDDs).
5. **Subject-area hints populated.** Fixture: the two involved TDD files declare
   overlapping `## Touched files`. Expect: the candidate's
   `subject_area_hints.files` is the union of those paths; `.tags` has the class tag.
6. **Idempotent persist.** Call `append_accepted_learning` twice for the same
   class+file-hints with different run ids. Expect: `LEARNINGS.md` holds ONE
   `## L-001` entry whose `Recurred across` line names both run ids; no
   duplicate heading.
7. **Watcher completion line.** Fixture: a stub `implement.sh` that writes a
   `latest/state.d/run.json` with `state: done` + a `candidate-learnings.json`,
   then exits. Run `implement-watch.sh`. Expect stdout `IMPLEMENT_RUN_COMPLETE
   logdir=<abs> state=done candidate_learnings=yes`, and `.watch.pid` removed.
8. **Watcher wake via SIGUSR1.** Fixture: a stub build that sleeps, then
   `kill -USR1`s the recorded `.watch.pid`. Expect: the watcher's poll loop
   exits within one sleep tick of the signal (not after `THROUGHLINE_WATCH_MAX_SECS`).
9. **Skill instruction present.** `skills/implement/SKILL.md` contains the
   watcher launch (harness-tracked background, not bare nohup), the "Detect
   pending candidate learnings" step (auto + fallback), and the `multiSelect`
   accept/discard + reviewed-rename instructions. (Mechanical grep — the
   interactive review itself is exercised by the human at run time.)

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-72 (recurring patterns surfaced as candidate learnings after a completed run; human accept/discard; accepted subset persisted; no report when none recur) | §1 `detect_build_learnings` (mines `findings` for ≥2-occurrence non-nit `pattern_tag` classes; covers review findings + rework outcomes + structural escalations via the single `findings` substrate; writes `candidate-learnings.json` + report section; writes nothing when none recur — verification §1–§5); §3/§4/§5 watcher + run-end hook + skill review deliver the human accept/discard prompt in the interactive session (verification §7–§9); §2 `append_accepted_learning` persists exactly the accepted subset (verification §6). Subject-area hints (§1.5) are produced here for TDD 0023's FR-73 consumption. |

No gaps: FR-72 is the sole in-scope requirement; FR-73 (consuming the store) is TDD 0023.

## Dependencies considered

No new external dependencies. Detection is bash + the existing `state.sh`
readers; JSON is emitted via `state.sh`'s `json_escape` (no `jq` requirement,
matching `status.sh`'s sed-fallback posture).

Alternatives considered:
- **Compute learnings inside an interactive skill on demand (no runner change,
  no watcher)** — rejected: the human-review prompt would only ever fire on a
  manual `/implement` re-invocation, never automatically on completion (the
  requested behavior); and "the run surfaces a report" (FR-72) reads as the run
  producing the artifact.
- **Foreground the build / launch as a harness-tracked job directly (no
  `nohup`)** — rejected: couples the build's lifetime to the session and
  regresses TDD 0011 / FR-39's survives-session-close property. The watcher
  decouples them (harness-tracked watcher + nohup'd build).
- **A new fragment field for candidate learnings** — rejected: detection is a
  read-only post-pass over `findings`; a schema field would force a `state.sh`
  version bump for data that belongs in a separate per-run artifact.
- **Persist learnings as JSON** — rejected: TDD 0023's match is model-driven over
  prose; markdown parallel to `BLOCKERS.md` is human-skimmable and greppable.
  (Chosen with the user.)

## PRD conflicts surfaced (and resolution)

The PRD's **"Recurring-pattern threshold (FR-72)"** open question is resolved
here: a class is recurring at `>= MIN` distinct TDDs *or* build steps
(`THROUGHLINE_LEARNING_MIN_OCCURRENCES`, default 2), severity unweighted beyond
excluding `nit`. Rationale: nits are polish noise; blocker/major/minor are all
patterns the design phase could anticipate, so weighting among them discards
signal. Env-overridable so the PRD's "initial calibration against actual run
data" needs no code change. No conflict with an accepted ADR.

## Decisions to promote (ADR candidates)

- **Optional / low confidence:** "Build-phase learnings are advisory, never
  auto-applied design mutations." Durable, but already a PRD non-goal + the
  human-gate norm (ADR 0003 family); recommend *not* promoting. Evaluated step 6.

## Touched files

- `scripts/lib/learnings.sh` — new; `detect_build_learnings` + `append_accepted_learning`
- `scripts/implement-watch.sh` — new; the harness-tracked liveness-bridge watcher
- `scripts/implement.sh` — source `learnings.sh`; run-end detection hook (done branch) + `.run-complete` + watcher wake (both branches)
- `skills/implement/SKILL.md` — launch via watcher; "Detect pending candidate learnings" review step (auto + fallback)
- `tests/build-phase-learning-capture.test.sh` — new; verification-plan observation points

## Expected diff size

- `scripts/lib/learnings.sh` — ~180 lines
- `scripts/implement-watch.sh` — ~70 lines
- `scripts/implement.sh` — ~25 lines
- `skills/implement/SKILL.md` — ~55 lines
- `tests/build-phase-learning-capture.test.sh` — ~150 lines

Total expected diff: ~480 lines across 5 files. No per-file exception needed
(each under the 300-line default).

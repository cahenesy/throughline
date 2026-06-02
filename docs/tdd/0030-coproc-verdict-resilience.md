# TDD 0030: Coproc verdict-write resilience + honest terminal states

Status: implemented
PRD refs: FR-39, FR-42, FR-44 (gap-closure); FR-30, FR-64; NFR-4
PRD-rev: bfc8ad6
ADR constraints: 0004, 0005, 0006, 0007

## Approach

Five gaps discovered while building [[0027]] itself — the runner's behavior
when its build coprocess dies while a synchronous child (a per-step review) is
still in flight, and the honesty of the terminal states it writes on the way
down. All five violate acceptance criteria of existing FRs/NFRs; none require
PRD changes. This TDD designs against post-[[0027]] code (the `_claude_call`
watchdog and blocked-state resume now exist) — it extends [[0024]], [[0025]],
and [[0027]]; it supersedes nothing.

The observed incident chain (run `20260601-150811`, building 0027):

1. The build coproc was killed by the 2h `THROUGHLINE_BUILD_TIMEOUT` while a
   per-step review was still running (the review ran 1h41m; the watchdog
   counts that waiting time against the build — gap 5).
2. When the review returned PASS, `_per_step_review_loop` recorded the cleared
   step, then wrote the verdict to the dead coproc's stdin — **SIGPIPE killed
   the runner's worker subshell** (gap 1: the write at gates.sh ~569 has
   `2>/dev/null || true`, which guards the *redirection* failing, but a SIGPIPE
   raised by the kernel on write-to-broken-pipe terminates the process before
   `|| true` can matter when the shell takes the default SIGPIPE disposition).
3. The dead worker left the fragment as `building` — a state `--check-paused`
   ignores, so the run became invisible to FR-39 detection (gap 2). A plain
   re-run would have silently rebuilt 2 hours of finished, reviewed work.
4. The runner's outer loop wrote `state=done` to run.json with 0 of 1 TDDs
   completed (gap 3) and printed the BLOCKERS.md boilerplate although nothing
   had been recorded there (gap 4).

## Components & interfaces

### 1. SIGPIPE-safe verdict write — `scripts/lib/gates.sh` (gap 1)

The verdict-write site (`_per_step_review_loop`, ~line 569):

```bash
printf '%s\n' "$(_user_turn_json "$verdict")" 1>&"${build_in}" 2>/dev/null || true
```

Two-part fix:

- **Liveness check before the write.** Immediately before writing the verdict,
  check `kill -0 "$bpid"`. If the coproc is dead: do NOT write; instead append
  `THROUGHLINE_COPROC_DEAD: build coprocess exited before verdict delivery
  (step <id> verdict was <PASS|BLOCK>); cleared work is preserved (transient)`
  to the gate log and `break` out of the read loop. The post-loop path then
  runs exactly as it does today: `wait` collects the dead coproc's status and
  `_per_step_review_loop` returns it (124 if the watchdog killed it, the raw
  code otherwise). That return code propagates up through `_build_one_gated`
  to `_retry_in_gate`, whose `_classify_cause` call routes it (124 + the
  timed-out log line → transient) into the existing pause flow — with the
  cleared step already recorded in the fragment.
- **SIGPIPE immunity for the remaining race window.** The liveness check has a
  TOCTOU window (coproc dies between check and write). Close it by running the
  write itself with SIGPIPE ignored: `trap '' PIPE` before the write,
  restore (`trap - PIPE`) after. With SIGPIPE ignored, a write to a broken
  pipe returns EPIPE as a normal error instead of killing the process — the
  existing `2>/dev/null || true` then genuinely covers it, and the next loop
  iteration's `read` hits EOF and exits normally.

Both the initial prompt write (~line 546) and the verdict write (~569) get the
same treatment (one shared helper `_coproc_write <fd> <text>` that does
trap/check/write/restore, returning non-zero when the coproc is gone).

### 2. Unclean-death detection — `scripts/status.sh` + `scripts/lib/resume.sh` (gap 2)

A fragment stuck at a non-terminal status (`building`, `verifying`,
`reviewing`) whose run has no live runner is an **interrupted-unclean** run.
Detection is mechanical: run.json records the runner `pid`; if that pid is not
alive, every non-terminal fragment in that run is orphaned.

- **`--check-paused` extension:** after the existing paused/blocked scans, a
  third arm: fragment status ∈ {building, verifying, reviewing} AND run.json's
  `pid` is not alive (`kill -0` fails) → print
  `slug=<slug> gate=<stage> cause=unclean-exit resumable=orphaned`. (The pid
  liveness check makes this safe against racing a live run — a live runner's
  fragments are never reported.)
- **Resume acceptance** (`_resume_from`, resume.sh): accept `building`/
  `verifying`/`reviewing` fragments the same way [[0027]] §3c accepts blocked
  ones — flip to paused/transient, then proceed through existing validation.
  `branch_head_at_pause` is null for these (the unclean death never wrote it):
  in that case, **derive it from the branch ref directly** (`git rev-parse
  refs/heads/<branch>`) instead of refusing — the branch's committed state IS
  the ground truth (FR-40: committed history is the source of truth for build
  output), and the cleared_step_log tells the resumed build what was reviewed.
- **`skills/implement/SKILL.md`:** document the `resumable=orphaned` marker in
  the detect-interrupted-run step, alongside the existing `resumable=blocked`
  parsing — the skill's resume prompt must offer orphaned runs the same way it
  offers blocked-but-resumable ones.

### 3. Honest terminal rollup — `scripts/implement.sh` + `scripts/lib/state.sh` (gap 3)

The run-end writer (implement.sh ~615) chooses `paused` vs `done` by scanning
for paused fragments only. Extend the scan: any fragment in a **non-terminal**
status (building/verifying/reviewing) at run-end means the run did NOT finish
cleanly → write `state=interrupted` (a new run-level state), never `done`.

`set_run_state` (state.sh ~508) gains `interrupted` with precedence
**blocked > interrupted > paused > done**, implemented as a single fragment
scan with explicit ordering: the loop checks each fragment for `blocked`
(found → derived=blocked, break immediately — nothing outranks it) and for
non-terminal statuses (found → derived=interrupted, do NOT break — keep
scanning in case a later fragment is blocked). Only if neither is found does
the caller's requested state (`paused`/`done`) stand.

`status.sh`'s renderer maps `interrupted` to a "run did not exit cleanly —
re-run /implement to resume" banner.

### 4. Truthful report tail — `scripts/implement.sh` (gap 4)

The BLOCKERS.md boilerplate (implement.sh ~587) prints whenever the file
exists. Fix: print it only when this run APPENDED to it — snapshot
`BLOCKERS.md`'s **line count** (`wc -l`, 0 when the file is absent) at run
start into a variable; at run end, recount and print the boilerplate only if
the count grew. Line count (not mtime/size) is the chosen mechanism: it is
immune to `touch` and to same-length edits, and the file is small enough that
two reads are free. Otherwise print nothing about blockers.

### 5. Review-time excluded from the build wall-clock — `scripts/lib/gates.sh` (gap 5)

The `THROUGHLINE_BUILD_TIMEOUT` watchdog (a `timeout` wrapping the whole
coproc) keeps counting while the build is blocked on stdin waiting for a
per-step review — so long reviews consume the build's budget. Fix: the budget
becomes **active-time**, accounted by the runner; the wall-clock `timeout`
wrapper is **removed entirely** (any wall-clock bound necessarily counts
review-wait time, so no wall-clock backstop can honestly claim "firing it is a
defect"); the backstop becomes an inline active-time check.

**Precise accounting spec.** `THROUGHLINE_BUILD_TIMEOUT` (unchanged name,
unchanged default 7200) now means *active build seconds*. The runner maintains
`build_active_seconds`, accumulated as follows:

- **Active intervals** (the clock RUNS): from coproc spawn to the first
  `STEP_COMMIT` event; and from each verdict-write completing to the next
  `STEP_COMMIT` or `BATCH_RESULT` event (whichever arrives). The interval ends
  the moment the runner reads the sentinel event off the build's stdout.
- **Inactive intervals** (the clock STOPS): from reading a `STEP_COMMIT` to
  finishing the verdict-write for it — i.e. the entire synchronous
  `_run_per_step_review` call plus the write. Also stopped after
  `BATCH_RESULT` is read (the build is done; remaining drain time is free).
- **Accounting mechanism**: capture `interval_start=$(date +%s)` when an
  active interval begins; on reading a sentinel,
  `build_active_seconds=$((build_active_seconds + $(date +%s) - interval_start))`;
  compare against the budget at each accumulation point. On exceed: kill the
  coproc by PID, log the existing
  `THROUGHLINE_BUILD_TIMEOUT: ... (build-overall-timeout) (transient)` line,
  return 124 (the existing classification path).
- **Backstop**: an **inline active-time check**, not a wall-clock `timeout`
  wrapper. The coproc is spawned with NO `timeout` wrapper. At each
  accumulation point, after the primary budget comparison, the runner also
  compares the same accumulated active seconds against a derived local
  `backstop=$((2 * overall))` (not a new env var). Because both checks read
  the same monotonically-growing counter at the same points, exceeding 2× is
  reachable only if the primary 1× check failed to fire at an earlier
  accumulation point — a runner control-flow bug, which is exactly what the
  backstop exists to surface; firing it is a defect. Precision on what this
  catches: threshold-comparison bugs at accumulation points (a broken 1×
  comparison). Lifecycle bugs in the clock gating itself (e.g. the
  active-clock flag stuck off) suppress BOTH checks identically and are out of
  scope for either — they are covered by the inter-event watchdog below, not
  by the backstop. On fire: log a
  distinguishable
  `THROUGHLINE_BUILD_BACKSTOP: hard backstop fired (runner accounting bug?)`
  line, kill the coproc by PID, return 124. The TIMEOUT and BACKSTOP log
  lines are never conflated.
- **Coverage formerly provided by the wall-clock wrapper** (and why removing
  it loses nothing):
  - *Coproc streams forever without emitting a sentinel*: killed by the
    existing inter-event watchdog (`THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT`,
    default 600s `read -t`) — so while the runner is alive, accumulation
    points are guaranteed to keep occurring and both active-time checks
    remain reachable.
  - *Coproc orphaned by unclean runner death*: the runner's death closes the
    coproc's stdin write-end; the coproc sees EOF and self-terminates per
    [[0025]]'s lifecycle. No wall-clock bound is needed to reap it.

## Data & state

- One new run-level state value: `interrupted` (gap 3). Consumers: status.sh
  renderer + the run-end writer. Schema version unchanged (the field's value
  set grows; its shape does not).
- No new fragment fields. Gap 2's orphan detection derives everything from
  existing fields (status, run.json pid) + process liveness.
- Gap 5's `build_active_seconds` is a runner-local variable, not persisted.

## Sequencing / implementation plan

1. **SIGPIPE-safe `_coproc_write` helper + both write-site switches**
   (gates.sh) — gap 1.
2. **Honest terminal rollup**: `interrupted` state in set_run_state +
   run-end scan extension + status.sh banner — gap 3. (Before gap 2, since
   gap 2's detection reads the states gap 3 makes honest.)
3. **Unclean-death detection + orphaned resume**: --check-paused third arm +
   resume.sh acceptance + branch-head derivation + SKILL.md docs — gap 2.
4. **Truthful report tail**: BLOCKERS.md growth check — gap 4.
5. **Active-time build watchdog**: `build_active_seconds` accounting +
   backstop-only `timeout` — gap 5.

## Failure modes & edge cases

- **Coproc dies BETWEEN the liveness check and the write (gap 1 TOCTOU).**
  Covered by the SIGPIPE-ignore trap: the write returns EPIPE as an error,
  `|| true` absorbs it, the next read hits EOF, the loop exits normally.
- **`kill -0` false-positive (pid recycled by another process).** The check
  errs toward writing; the SIGPIPE trap covers the actual-dead case. A recycled
  pid receiving a spurious `kill -0` probe is unaffected (signal 0 sends
  nothing).
- **Orphan detection races a runner that is alive but slow (gap 2).** The pid
  liveness check is the guard: a live runner → fragments never reported as
  orphaned, regardless of how stale they look.
- **run.json's recorded pid was never written (very early crash).** Fragments
  exist but run.json has no pid field or pid=null → treat as not-alive →
  orphan detection applies. Correct: a run that died before recording its pid
  definitionally has no live runner.
- **Resume of an orphaned fragment whose branch was deleted.** The branch-head
  derivation fails (`git rev-parse` non-zero) → the existing
  `resume-blocked-branch-missing` refusal fires (unchanged from [[0024]]).
- **`interrupted` rollup vs blocked fragments in the same run (gap 3).**
  Precedence: blocked > interrupted > paused > done. A run with one blocked
  and one orphaned TDD reads `blocked` (design action needed dominates).
- **BLOCKERS.md is deleted mid-run (gap 4).** Growth check compares against
  the start snapshot; a deleted file reads as 0 lines → no growth → no
  boilerplate. Correct.
- **Gap 5's active-time accounting across a resume.** `build_active_seconds`
  resets on resume (runner-local). Acceptable: each resume's build attempt gets
  a fresh budget; the cap bounds each attempt, not the lifetime sum (consistent
  with how `_retry_in_gate` budgets attempts, not lifetimes).
- **Runner SIGKILLed mid-build (gap 5, no wall-clock wrapper to reap the
  coproc).** The coproc's stdin write-end closes with the runner's death → the
  coproc sees EOF and exits per [[0025]]'s lifecycle; gap 2's orphan detection
  surfaces the dead run's fragments on the next `/implement`. A coproc that is
  BOTH orphaned AND wedged mid-turn (ignoring EOF) is a double failure outside
  any in-process defense — bounded only by claude's own internal turn limits;
  accepted and documented rather than re-introducing a wall-clock bound that
  falsely fires on heavy review load.

## Verification plan

**Observable surface:** the gate log lines (`THROUGHLINE_COPROC_DEAD`),
`status.sh --check-paused` stdout, `run.json`'s state field, the report tail,
runner exit behavior under fault injection, and fragment states after
recovery.

**Observation points:**

1. **Verdict write to a dead coproc does not kill the runner (gap 1).**
   Fixture: a stub coproc (mkfifo-backed or a stub `claude` that exits after
   emitting STEP_COMMIT) that is killed while the per-step review stub runs.
   Drive `_per_step_review_loop`. Expect: the loop function RETURNS (runner
   process still alive); the gate log contains `THROUGHLINE_COPROC_DEAD`; the
   cleared step recorded by the review is present in the fragment; the
   function's return code routes to the transient/pause path (non-zero,
   classified transient).
2. **SIGPIPE race window covered (gap 1).** The TOCTOU window cannot be hit
   deterministically via the liveness check (signal 0 delivers nothing and
   triggers no trap), so the fixture tests the PIPE-trap mechanism directly,
   bypassing the liveness check: drive `_coproc_write` against a pipe whose
   read end has already been closed (`mkfifo p; exec {fd}<>p; exec {rd}<p;
   exec {rd}<&-` — or simpler: a fd opened to a process-substitution reader
   that has already exited). Expect: `_coproc_write` returns non-zero (EPIPE
   absorbed by `|| true` semantics, surfaced as the helper's failure return);
   the calling shell is still alive (the test's next assertion executes); no
   SIGPIPE termination. This proves the trap covers any write-to-dead-pipe,
   which is exactly what the TOCTOU race produces.
3. **Orphaned fragments surfaced (gap 2).** Fixture: a state.d with one
   `building` fragment + a run.json whose pid is a known-dead pid. Run
   `status.sh --check-paused`. Expect: one line with
   `cause=unclean-exit resumable=orphaned`. Negative: same fixture but
   run.json's pid is the current shell's pid (alive) → no line printed.
4. **Orphaned resume accepted with derived branch head (gap 2).** Fixture: an
   orphaned `building` fragment with `branch_head_at_pause:null` and a real
   branch ref. Run resume validation. Expect: no refusal; the fragment's
   status flips to paused; `branch_head_at_pause` equals the branch ref after
   validation; gates_completed is preserved verbatim.
5. **Honest interrupted rollup (gap 3).** Fixture: run-end writer invoked with
   one fragment still `building`. Expect: run.json `state=interrupted`, never
   `done`. status.sh renders the not-cleanly-exited banner. Negative: all
   fragments terminal (done/failed) → `done` exactly as today.
6. **Report tail truthfulness (gap 4).** Fixture A: a run during which
   BLOCKERS.md did not change → report contains NO blockers boilerplate.
   Fixture B: a run that appends one entry → report contains the boilerplate.
7. **Review time excluded from build budget; backstop never fires on
   review wall-clock (gap 5).** Fixture: stub build that emits STEP_COMMIT
   immediately; stub review that sleeps 8s; build active-time budget set to 5s
   (`THROUGHLINE_BUILD_TIMEOUT=5`). Expect: the build is NOT killed during the
   8s review wait (review time doesn't count) and NO `THROUGHLINE_BUILD_BACKSTOP`
   line is logged regardless of how much wall-clock the review wait adds — a
   wall-clock-implemented backstop fails this assertion; after the review
   returns and the build streams for >5s more of active time, THEN the
   active-time watchdog kills it with the existing timed-out classification
   (the `THROUGHLINE_BUILD_TIMEOUT` line, never the BACKSTOP line). Any
   existing test comment that references a wall-clock backstop interval (e.g.
   "< the 2× backstop = Ns") is stale under this design and must be updated by
   the same change that removes the wrapper.

**Expected observations (PASS):** every numbered point yields the cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-42 (transient errors handled boundedly within the gate — never kill the runner) | §1 SIGPIPE-safe `_coproc_write` (liveness check + PIPE trap). Verification §1, §2. |
| FR-39 (interrupted runs detected and surfaced; user decides) | §2 orphan detection (`resumable=orphaned`) + resume acceptance — unclean deaths now reach the FR-39 prompt instead of being invisible. Verification §3, §4. |
| FR-44 (state record never misclassifies progress after interruption) | §2's derived branch head + preserved gates_completed; §3's `interrupted` state (a `building` fragment in a dead run is never read as in-progress or done). Verification §4, §5. |
| FR-30 (progress estimates honest) + NFR-4 (verdict honesty) | §3 `interrupted` rollup — `done` is never written when work did not finish. Verification §5. |
| FR-64 (halt context names the actual cause and next action) | §4 truthful report tail (no phantom BLOCKERS.md pointer); §2's marker names `unclean-exit` as the cause. Verification §3, §6. |
| NFR-4 + FR-42 (gap 5: a timeout that counts time the build did not use is a dishonest budget — "transient error handled boundedly" presumes the bound measures the gate's own work) | §5 active-time accounting — the build budget measures build work, not review waits; the backstop is distinguishable so accounting bugs are never conflated with genuine timeouts. Verification §7. |

No gaps.

## Dependencies considered

No new external dependencies. `trap '' PIPE`, `kill -0`, and `mkfifo` (test
fixtures only) are POSIX/coreutils, already used elsewhere in the runner.

Alternatives considered:
- **Global `trap '' PIPE` for the whole runner** (instead of scoped around
  writes) — rejected: SIGPIPE-ignore process-wide changes the semantics of
  every pipeline in the runner (a `head`-terminated pipe would no longer
  stop the producer); scoping to the two coproc writes contains the change.
- **Re-spawning the coproc when it dies mid-review** (instead of pausing) —
  rejected: a fresh coproc has no conversation context; the RESUME-COMPLETION
  path on a normal resume achieves the same outcome through the designed,
  already-tested mechanism. Re-spawn adds a second lifecycle to maintain.
- **A separate `orphaned` fragment status** (instead of detecting orphans from
  status+pid) — rejected: a status only the crashed runner could write is a
  contradiction (it's dead); detection must be reader-side. The fragment
  statuses stay as they are; orphan-ness is derived.
- **Killing the per-step review when the build coproc dies** (instead of
  letting it finish) — rejected: the review's verdict is still valuable (it
  records the cleared step, exactly what saved the work in the observed
  incident); reviews are bounded by [[0027]]'s `_claude_call` timeout anyway.
- **Counting review time against a separate review budget** (gap 5
  alternative) — rejected for now: [[0027]]'s `THROUGHLINE_GATE_TIMEOUT`
  already bounds each review individually; a cumulative review budget adds a
  knob without a demonstrated need.
- **A wall-clock `timeout` wrapper at 2× the budget as the backstop** (gap 5 —
  this TDD's own original design, revision 0) — rejected after the first build:
  wall-clock includes review-wait time, so the wrapper fires on a correct build
  under heavy review load while logging "runner accounting bug?" — the
  backstop's honesty claim ("firing it is a defect") is unsatisfiable by ANY
  wall-clock mechanism. Caught as finding M1 by the final review of run
  `20260601-191259`; replaced by the inline active-time check.

## PRD conflicts surfaced (and resolution)

None. All five gaps are implementation shortfalls against existing acceptance
criteria. The new `interrupted` run-state value is within FR-27's "run-level
identity + rollup" scope and FR-30/NFR-4's honesty requirements; no FR text
changes.

**Build-blocker resolution (run `20260601-191259`, revision 1 of this TDD).**
The first build of this TDD cleared all five steps but was halted at the final
review gate: (M1) §5's backstop was implemented as a wall-clock `timeout`
wrapper, which counts review-wait time and therefore can fire on a correct
build under heavy review load while being logged as "runner accounting bug?" —
contradicting this TDD's own "firing it is a defect" contract. The automatic
rework produced the correct fix (inline active-time backstop) but was rejected
by the FR-67(b) structural check: `scripts/lib/gates.sh` cumulative diff was
138 lines against the ~55 declared here — the original §1+§5 estimate was low
by ~2.5×. This revision resolves both halt causes: §5 now specifies the inline
active-time backstop (no wall-clock wrapper), and `## Expected diff size` is
trued up to the observed actuals with headroom for the pending rework. The
corresponding `docs/tdd/BLOCKERS.md` entry is resolved by this revision.

## Decisions to promote (ADR candidates)

None. The SIGPIPE handling, orphan detection, and honest rollups all apply
existing ADR dispositions to new failure paths. On [[ADR 0006]] specifically:
that ADR governs *gate verdicts*; the orphan detection here is run-state
*surface detection*, not a verdict — no TDD is passed or failed based on
process liveness. Where this TDD does touch verdict-adjacent ground (deriving
`branch_head_at_pause` from the branch ref for orphans), the grounding IS the
committed git history, which FR-40 names as the source of truth for build
output — the strongest artifact available, fully in 0006's spirit.

## Touched files

- `scripts/lib/gates.sh` — `_coproc_write` helper + two write-site switches (§1); active-time watchdog accounting + inline 2× backstop, no `timeout` wrapper (§5).
- `scripts/lib/state.sh` — `interrupted` in set_run_state's vocabulary + precedence (§3).
- `scripts/implement.sh` — run-end non-terminal scan + interrupted write (§3); BLOCKERS.md growth check (§4).
- `scripts/lib/resume.sh` — orphaned-fragment acceptance + branch-head derivation (§2).
- `scripts/status.sh` — `--check-paused` orphan arm + interrupted banner (§2, §3).
- `skills/implement/SKILL.md` — document `resumable=orphaned` (§2).
- `tests/coproc-verdict-resilience.test.sh` — new eval covering verification §1–§7.
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Build collateral (observed in run `20260601-191259`; not rework surface): the
build's keep-docs-in-sync discipline also touches `scripts/build-prompt.md` and
`skills/implement-status/SKILL.md` (both document the timeout/state semantics
this TDD changes), and `tests/continuous-in-build-review.test.sh` (its fixtures
stub the gates.sh functions §1/§5 modify). These ride in the build's docs-sync
commits. They are NOT files an FR-67 rework may target — a halting finding
whose fix lands in one of them is a design-level event requiring another
revision of this TDD, not an in-run rework. (This is consistent with how the
FR-67 checks measure: (a) membership and (b) cumulative size are evaluated
only for files appearing in the rework's own diff — collateral already landed
by the build is never re-counted unless a rework edits the same file.)

Total: 8 files touched (+3 build collateral).

## Expected diff size

Estimates are trued up to the per-file actuals observed in build run
`20260601-191259` (the first build of this TDD), plus headroom on
`scripts/lib/gates.sh` for the pending §5 backstop rework — so the FR-67(b)
cumulative-diff check measures against realistic declarations, not the
original underestimates.

- `scripts/lib/gates.sh` — ~160 lines (helper ~20, write-site switches ~6, active-time accounting + inline backstop ~110; observed 135 + rework headroom).
- `scripts/lib/state.sh` — ~20 lines (vocabulary + precedence; observed 18).
- `scripts/implement.sh` — ~30 lines (scan extension + growth check; observed 29).
- `scripts/lib/resume.sh` — ~60 lines (orphan acceptance + head derivation; observed 56).
- `scripts/status.sh` — ~45 lines (orphan arm + banner; observed 43).
- `skills/implement/SKILL.md` — ~12 lines (marker documentation; observed 11).
- `tests/coproc-verdict-resilience.test.sh` — ~500 lines (exception: one comprehensive eval covering all 7 verification points with shared stub fixtures; observed 491 — splitting it would fragment the coproc/review stubs every point reuses).
- `tests/implement-gate.test.sh` — ~15 lines (aggregator wire-in; observed 14).

Build collateral (not declared rework surface, see `## Touched files`):
`scripts/build-prompt.md` ~12 lines, `skills/implement-status/SKILL.md` ~6
lines, `tests/continuous-in-build-review.test.sh` ~10 lines.

Total expected diff: ~842 lines across 8 declared files (+~28 lines of build
collateral). One exception declared inline (the eval file).

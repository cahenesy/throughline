# TDD 0017: Theme D refactor (3/3) — extract gate executors and resume orchestration into `scripts/lib/{gates,resume}.sh`

Status: draft
PRD refs: FR-69 (slice 3/3)
PRD-rev: a961955
ADR constraints: 0003, 0004, 0005

## Approach

Third and final slice of the Theme D refactor. This slice extracts two
clusters that together account for the remaining bulk of `implement.sh`:

- **Gate executors** — the functions that spawn `claude -p` for build /
  review / runtime-verify, parse their result sentinels, and run
  `verify.sh`. Plus `install_deps` and the "gated wrapper" functions that
  thread retry-loop bookkeeping around each gate call.
- **Resume orchestration** — the functions that re-enter a paused TDD's
  state and decide which gate(s) to re-run, plus `gate_one` and the
  per-TDD build-branch resolution helpers.

These two clusters get separate modules because they are sourced at
different points in `implement.sh`'s main flow: gates are called from
the per-TDD inner loop; resume is called only when picking up a paused
run. Keeping them in distinct files preserves that separation and lets
future surgical edits to one not touch the other.

This TDD assumes TDDs 0015 and 0016 have landed first; `scripts/lib/state.sh`
and `scripts/lib/pause-retry.sh` exist and are sourced. This slice's
modules are sourced after both.

After this slice lands, `scripts/implement.sh` is ~600 lines: shebang +
header comment + CLI arg parsing + the main per-TDD orchestration loop +
the source directives for the four `lib/` modules. That is within the
350-line *body* bound TDD 0014 sets (header comments do not count toward
the bound; if the body exceeds 350, this TDD declares the legitimately-wide
exception explicitly).

## Components & interfaces

### New file: `scripts/lib/gates.sh`

| Function | Current location (implement.sh, post-0016) | Purpose |
|---|---|---|
| `build_one` | ~953 | Spawn the build `claude -p` for one TDD. |
| `review_one` | ~961 | Spawn the review `claude -p` for one TDD against a base ref. |
| `verify_runtime_one` | ~979 | Spawn the runtime-verify `claude -p` for one TDD. |
| `build_status` / `review_status` / `verify_runtime_status` | ~988–990 | Parse the verdict sentinels from a log file. |
| `run_verify` | ~991 | Run `verify.sh` against the build branch. |
| `test_first_ok` | ~996 | Verify the `test(failing): …` commit precedes implementation. |
| `flip_status` | ~1003 | Edit a TDD's `Status:` line to `implemented`. |
| `record_blocker` | ~1009 | Append a BLOCKERS.md entry. |
| `install_deps` | ~1022 | Install project deps in a freshly-cloned worktree. |
| `_build_one_gated` / `_verify_runtime_one_gated` / `_review_one_gated` | ~1062–1080 | Retry-loop wrappers around the three gates. |

Approximately 11 functions, ~250 lines.

### New file: `scripts/lib/resume.sh`

| Function | Current location (implement.sh, post-0016) | Purpose |
|---|---|---|
| `_resume_gates_var` | ~1090 | Compute which gates to re-run on a resume. |
| `_update_paused_cause` | ~1098 | Update a paused TDD's cause label on resume. |
| `_resume_from` | ~1149 | Top-level resume entry: re-enter a paused run, drive remaining gates. |
| `gate_one` | ~1300 | Drive the gate sequence for a single TDD (called from both fresh-build and resume paths). |
| `built_branch` | ~1448 | Resolve a TDD's own build branch (already-implemented short-circuit). |
| `combined_built_branch` | ~1461 | Resolve the combined-mode branch where every queued TDD is implemented. |

Approximately 6 functions, ~390 lines (mostly `_resume_from` and `gate_one`,
which are large multi-branch flows).

### Edits to `scripts/implement.sh` (post-0015, post-0016 baseline)

- Remove lines ~951–1483 (both clusters above).
- Append two more source directives after `state.sh` and `pause-retry.sh`:

```bash
# shellcheck source=lib/gates.sh
. "$SCRIPT_DIR/lib/gates.sh"
# shellcheck source=lib/resume.sh
. "$SCRIPT_DIR/lib/resume.sh"
```

The remaining `implement.sh` body (post-three-slice) is the CLI-arg parsing,
the integration-branch discovery logic, the queue-construction logic, the
main per-TDD orchestration loop that calls `gate_one`, and the cleanup +
summary emission. Spot-check estimate: ~600 lines.

### No other file changes

`scripts/status.sh`, `scripts/verify.sh`, skill prompts unchanged. The
Theme C / Theme B TDDs (0018–0021) layer new behavior on top of the
post-refactor file layout; their edits will target `scripts/lib/*.sh`
modules directly, not `implement.sh`'s orchestration body.

## Data & state

No on-disk schema changes. Gates write the same sentinel lines
(`BATCH_RESULT:`, `REVIEW_RESULT:`, `VERIFY_RUNTIME:`); `record_blocker`
appends BLOCKERS.md in the same shape; `flip_status` edits the same
`Status:` line. Refactor only.

## Sequencing / implementation plan

1. **Create `scripts/lib/gates.sh`** with the 11 functions in the order
   listed in §Components. Header: "Gate executors: build, review, runtime-
   verify, verify.sh; result-sentinel parsers; install_deps; gated wrappers."
2. **Create `scripts/lib/resume.sh`** with the 6 functions in the order
   listed. Header: "Resume orchestration: re-enter paused runs, decide
   which gates to re-drive, branch resolution helpers."
3. **Edit `scripts/implement.sh`**: remove both clusters; append the two
   source directives. Verify the remaining body is ≤ 600 lines (or, if
   over 350 lines body excluding header comments, declare the wide-but-
   shallow exception in this TDD's Expected diff size section — currently
   declared below).
4. **Run the fixture build** (Verification plan) to confirm the pre/post
   run-state diff is empty across clean, paused, and resume paths.

## Failure modes & edge cases

- **Sourcing order.** `gates.sh` MUST be sourced after `state.sh` and
  `pause-retry.sh` (gates call both). `resume.sh` MUST be sourced after
  all three previous (resume calls all of them, especially `gate_one`).
  Source order is enforced by directive order in `implement.sh`.
- **`gate_one` cohesion.** `gate_one` is itself ~150 lines and is the
  largest single function in the codebase. Splitting it inside this slice
  would balloon the refactor's risk surface; the FR-53 escape applies
  ("legitimately-wide-but-shallow"). A separate future TDD can decompose
  `gate_one` if its internals become hard to follow; for now, the move
  is verbatim.
- **`_resume_from` calls into `gate_one`.** This intra-`resume.sh` call
  resolves naturally because `gate_one` is defined in `gates.sh` (sourced
  before `resume.sh`).
- **Hard-coded path assumptions.** The moved functions reference
  `$MAINREPO`, `$LOGDIR`, `$VERIFY`, `$BUILD_PROMPT`, `$REVIEW_PROMPT`,
  etc. These are shell-scope variables set in `implement.sh`'s main body
  (which still exists post-refactor). Shared shell scope preserves them.
- **Theme C / B will edit these modules.** Subsequent TDDs (0018 — halt
  taxonomy; 0019 — rework loop) modify `gates.sh` and `state.sh`. This
  refactor's job is purely to give those TDDs a tractable file to edit.

## Verification plan

**Observable surface:** as TDDs 0015 / 0016 — run-state fragments + REPORT
verdicts + BLOCKERS.md contents on fixture runs. Additionally, this slice
must preserve resume behavior (the resume path is the largest single
behavior surface inside the refactor).

**Observation points:**

1. **Baseline + refactor clean build fixture.** As TDD 0015's points 1–2.
2. **Paused-then-resumed fixture build.** Construct a fixture that pauses
   on a recoverable failure (mock ratelimit), then resumes on a second
   invocation. Run pre-refactor, capture fragments; run post-refactor on
   the same fixture, capture fragments; byte-equal diff (with TDD 0015's
   normalization).
3. **BLOCKED fixture build.** Construct a fixture whose review gate emits
   `REVIEW_RESULT: BLOCK …`. Run pre-/post-refactor; confirm the
   BLOCKERS.md entry produced is byte-identical (modulo timestamps).
4. **`verify.sh` clean.** `bash scripts/verify.sh` passes on the refactor
   branch — `shellcheck` clean on `implement.sh`, `lib/gates.sh`,
   `lib/resume.sh`.

**Expected observations (PASS):**

- All three fixture paths (clean, paused-then-resume, blocked) produce
  byte-identical (post-normalization) run-state fragments and REPORT/
  BLOCKERS.md outputs across pre-refactor and post-refactor runs.
- `verify.sh` passes.
- Final `scripts/implement.sh` size: orchestration body ≤ 600 lines
  total (including header comments) — confirmed by `wc -l`.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-69 (slice 3/3 — completes the dogfood) | `scripts/implement.sh` post-this-slice ~600 lines (within bound); `scripts/lib/gates.sh` ~250 lines (within bound); `scripts/lib/resume.sh` ~390 lines (over the 300-line per-file bound — declared exception in Expected diff size: legitimately-wide-but-shallow; `gate_one` + `_resume_from` are the long-tail flows the refactor preserves verbatim) |

After this slice merges, FR-69's acceptance is met: no `scripts/*.sh` or
`skills/*/SKILL.md` file in the throughline distribution exceeds the
TDD 0014 bounds without a recorded exception.

## Dependencies considered

No new dependencies.

(Alternative considered: **collapse gates.sh and resume.sh into a single
module** — rejected: their cohesion criteria differ. Gates are leaves
called every TDD; resume is the entry point called only on a paused
re-invocation. Separating them makes future edits in Themes C/B more
surgical.)

(Alternative considered: **decompose `gate_one` and `_resume_from` in
this same refactor** — rejected: this slice's contract is verbatim moves
with byte-identical fragment output. Decomposition is a separate concern
that can be tackled in its own TDD if those functions prove too large
to maintain after Theme C/B edits.)

## PRD conflicts surfaced (and resolution)

None.

## Decisions to promote (ADR candidates)

None.

## Touched files

- `scripts/implement.sh` — remove ~640 lines (both clusters); insert ~6
  lines (two source directives)
- `scripts/lib/gates.sh` — new file, ~250 lines
- `scripts/lib/resume.sh` — new file, ~390 lines

Total: 3 files touched.

## Expected diff size

- `scripts/implement.sh` — net change ~-640 lines (large *removal*).
  **Post-refactor declared body size: ~600 lines** (the remaining
  orchestration body: CLI parsing, queue construction, main per-TDD
  loop calling `gate_one`, cleanup + summary). At ~600 lines this is
  over the 350-line TDD-0014 default `THROUGHLINE_TDD_MAX_FILE_DIFF`
  bound; declared exception: legitimately-wide-but-shallow orchestration
  glue that does not lend itself to further decomposition without
  obscuring the per-TDD build flow. Subsequent Theme B/C TDDs add to
  this file only via small wiring edits (`source` directives, rework
  hook call sites); they do not grow it materially.
- `scripts/lib/gates.sh` — ~250 lines added (within the 300-line bound;
  no exception needed)
- `scripts/lib/resume.sh` — ~390 lines added (exception:
  legitimately-wide-but-shallow code move from `implement.sh`; `gate_one`
  and `_resume_from` are the two long-tail multi-branch flows the
  refactor preserves verbatim; no behavior change, verified by
  byte-identical run-state fragments per Verification plan §1–§3; future
  TDDs may decompose these flows if Theme C/B edits make their
  internals hard to follow)

Total expected diff: ~1280 lines of mechanical move across 3 files.

# TDD 0016: Theme D refactor (2/3) — extract pause/retry classification into `scripts/lib/pause-retry.sh`

Status: implemented
PRD refs: FR-69 (slice 2/3)
PRD-rev: a961955
ADR constraints: 0003, 0004, 0005

## Approach

Second of three slice refactors bringing `scripts/implement.sh` into FR-53
compliance. This slice extracts the **pause/retry classification cluster** —
the functions that recognize recoverable failure modes (ratelimit, transient,
usage-limit), enter and exit the `paused` state, and manage per-gate retry
counts. Cohesion criterion: every function in the cluster either classifies
a failure cause or transitions a TDD between active and paused states; none
of them execute a gate or run resume orchestration — those belong to slice 3.

Behavior is identical pre- and post-refactor, verified the same way as
TDD 0015 (byte-identical run-state fragments on a fixture build).

This TDD assumes TDD 0015 has landed first; `scripts/lib/state.sh` exists
and is sourced by `implement.sh`. This slice's module is sourced after
`state.sh`.

## Components & interfaces

### New file: `scripts/lib/pause-retry.sh`

A standalone bash module sourced by `implement.sh` *after* `state.sh`. It
defines (in order of dependency):

| Function | Current location (implement.sh, post-0015) | Purpose |
|---|---|---|
| `_recoverable_patterns` | ~661 | Catalog of regex patterns identifying recoverable failure causes (ratelimit, transient, usage-limit). |
| `_classify_cause` | ~680 | Match a log tail against `_recoverable_patterns` to assign a cause label. |
| `_enter_paused` | ~710 | Transition a TDD's fragment into `paused` state, recording the cause. |
| `_retry_in_gate` | ~782 | Determine whether a paused TDD's gate is eligible for retry; bookkeep attempt counts. |
| `_append_retry` | ~870 | Record a retry event onto the TDD's fragment's retry array. |
| `record_session_pointer` | ~935 | Anchor the current `claude -p` session's log file + start epoch into the run-state. |

Six functions move verbatim. Signatures unchanged. No behavior changes.

Note on `record_session_pointer`: it lives in this cluster despite not being
classifying-or-pause-transitioning per se because it's called from the same
retry-loop entry points that use `_enter_paused` / `_retry_in_gate`; moving
it to slice 3 (gates) would split the retry-tracking surface across two
modules. Cohesion wins over alphabetical clustering.

### Edits to `scripts/implement.sh` (post-0015 baseline)

- Remove lines ~661–950 (the cluster above).
- Add a second source directive immediately after the `state.sh` source
  from TDD 0015:

```bash
# shellcheck source=lib/pause-retry.sh
. "$SCRIPT_DIR/lib/pause-retry.sh"
```

### No other file changes

`scripts/status.sh`, `scripts/ci-checks.sh`, skill prompts unchanged. Slice 3
(TDD 0017) handles the gates + resume clusters.

## Data & state

No on-disk schema changes. The retry-array entries written by `_append_retry`
and the `paused`/`cause` fields written by `_enter_paused` keep the same
shape as before; this is a pure code-organization refactor.

The closed-enum reshape of `cause` values that Theme C introduces
(TDD 0018) lands as a *future* change against this module; this slice does
not modify the cause vocabulary at all.

## Sequencing / implementation plan

1. **Create `scripts/lib/pause-retry.sh`** with the six functions in the
   order listed in §Components. Include a one-line file header naming
   what the module owns ("Recoverable-failure classification and paused/
   retry state transitions").
2. **Edit `scripts/implement.sh`** (now the post-0015 file) to source the
   new module and remove the moved function definitions. Preserve the
   per-function comments alongside the moves.
3. **Run the fixture build** (see Verification plan) to confirm the
   pre/post run-state diff is empty.

## Failure modes & edge cases

- **Sourcing order.** `pause-retry.sh` MUST be sourced after `state.sh`
  because every function in it calls `_write_tdd_fragment`,
  `_read_fragment_field`, or `set_tdd_state` (all owned by `state.sh`).
  Source order is enforced by the directive order in `implement.sh`.
- **A moved function references a variable defined later in `implement.sh`.**
  Same as TDD 0015 — shared shell scope means inline references continue
  to work. Variables touched include `$LOGDIR`, `$REPORT`, `$RUN_ID`,
  `$MAINREPO`, `$THROUGHLINE_RECOVERABLE_RATELIMIT_MAX`, etc.
- **`_recoverable_patterns` shape.** The function emits regex patterns
  one-per-line. The regex syntax is grep-EREs; preserved verbatim. No
  pattern is added, removed, or changed in this slice.
- **Test coverage of the move.** The current `implement.sh` does not
  carry unit tests for these helpers; correctness rests on the
  fixture-build run-state-diff (Verification plan). This is consistent
  with TDD 0015's approach.

## Verification plan

**Observable surface:** identical to TDD 0015 — the on-disk run-state
fragments produced by an `/implement` run. Additionally, for this slice,
the *behavior under recoverable failure* must be preserved.

**Observation points:**

1. **Baseline + refactor clean-run fixture build** — same as TDD 0015,
   step 1 and 2. Confirms the clean-path moves changed nothing.
2. **Recoverable-failure fixture build (pre-refactor).** Construct a
   fixture that forces a ratelimit-style failure (e.g., a mock `claude -p`
   wrapper that emits a known recoverable-failure log line on its first
   invocation and a clean result on its second). Run on master HEAD;
   capture fragments showing the paused → retry → done transitions.
3. **Recoverable-failure fixture build (post-refactor).** Same fixture
   on this TDD's branch; capture fragments.
4. **Byte-equal diff** of paused/retry fragment state across the two
   runs (modulo timestamps and runid).

**Expected observations (PASS):**

- Run-state fragments byte-identical after normalization (per TDD 0015's
  scheme).
- The paused state's `cause` field, the retry array's entry count and
  per-entry cause/gate/attempt fields, and the eventual resolution
  (gate retry success → `done`) all match across runs.
- `bash scripts/ci-checks.sh` passes on the refactor branch.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-69 (slice 2/3) | `scripts/implement.sh` line count drops to ~1100 post-this-slice; `scripts/lib/pause-retry.sh` created at ~290 lines (within the per-file bound at 300, no exception needed) |

## Dependencies considered

No new dependencies. Pure bash + grep (already used by the moved
functions for regex matching).

(Alternative considered: **classify causes via a structured-output `claude -p`
call instead of regex** — rejected: regex pattern-match is correct, free, and
deterministic for the recoverable-cause taxonomy; spending model tokens on
log classification reverses TDD 0013's pre-pass disposition.)

## PRD conflicts surfaced (and resolution)

None.

## Decisions to promote (ADR candidates)

None.

## Touched files

- `scripts/implement.sh` — remove ~290 lines (the pause/retry cluster);
  insert ~3 lines (source directive)
- `scripts/lib/pause-retry.sh` — new file, ~290 lines (the moved cluster
  + header)

Total: 2 files touched.

## Expected diff size

- `scripts/implement.sh` — net change ~-290 lines
- `scripts/lib/pause-retry.sh` — ~290 lines added (within the 300-line
  per-file bound; no exception needed)

Total expected diff: ~580 lines of mechanical move across 2 files.

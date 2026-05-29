# TDD 0015: Theme D refactor (1/3) — extract state-fragment I/O into `scripts/lib/state.sh`

Status: implemented
PRD refs: FR-69 (slice 1/3)
PRD-rev: a961955
ADR constraints: 0003, 0004, 0005

## Approach

`scripts/implement.sh` is 1836 lines, well over any plausible per-file bound
this codebase would set under FR-53. Theme D dogfoods Theme A: throughline's
own files must comply with the bounds throughline enforces on its users' TDDs.
This is the first of three slice refactors that bring `implement.sh` down to
~600 lines (orchestration only) by extracting cohesive function clusters into
`scripts/lib/` modules.

This slice extracts the **state-fragment I/O cluster**: the functions that
read, validate, and write the per-TDD and per-run JSON fragments under
`docs/tdd/.implement-logs/<runid>/{tdd-*.json,run.json}`. Cohesion criterion:
every function in the cluster either parses a fragment field or writes one;
none of them classifies causes, drives gates, or orchestrates resume — those
belong to slices 2 and 3.

Behavior is identical pre- and post-refactor. The verification mechanism is a
run-state-diff comparison on a fixture build: run a fixture TDD through
`/implement` on master HEAD; run the same fixture through `/implement` on this
refactor's branch; the resulting `run.json` and `tdd-*.json` fragments must
byte-match (excluding timestamps and the runid).

## Components & interfaces

### New file: `scripts/lib/state.sh`

A standalone bash module sourced by `implement.sh`. It defines (in order
of dependency):

| Function | Current location (implement.sh) | Purpose |
|---|---|---|
| `_validate_field_name` | ~244 | Refuse non-alphanumeric field names (security boundary). |
| `_read_fragment_field` | ~250 | Read a single field's value from a fragment. |
| `_read_fragment_array_csv` | ~258 | Read an array field as CSV. |
| `_read_fragment_raw_array` | ~268 | Read an array field as raw JSON. |
| `json_escape` | ~279 | Escape a string for JSON. |
| `_write_tdd_fragment` | ~301 | Atomic write of `tdd-<slug>.json`. |
| `_write_run_fragment` | ~365 | Atomic write of `run.json` (refresh updated_at + rollups). |
| `state_init` | ~424 | First-run initialization of the run-state directory. |
| `set_run_state` | ~546 | Thin wrapper around `_write_run_fragment`. |
| `_terminal_state` | ~557 | Terminal-verdict wrapper around `set_tdd_state` with stderr/REPORT surfacing. |
| `set_tdd_state` | ~574 | Atomic rewrite of one TDD's fragment. |
| `set_tdd_meta` | ~617 | Update a TDD fragment's metadata (n/queue_pos/path/branch/pr_url/log). |

All twelve functions move verbatim. No signatures change. No behavior changes.
The module has no top-level executable code (no side effects at source time).

### Edits to `scripts/implement.sh`

- Remove lines ~244–660 (the cluster above).
- Insert at the top of the script (after the existing shebang + comment
  header, before the first non-comment code), a single source directive:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh"
```

The `SCRIPT_DIR` variable already exists or is trivially derivable from
existing variables; the existing definition is preserved if it already
appears earlier in the file.

### No other file changes

Nothing else moves in this slice. `scripts/status.sh`, `scripts/ci-checks.sh`,
and the skill prompts are untouched. Subsequent slices (TDDs 0016, 0017)
handle the pause-retry and gates+resume clusters.

## Data & state

No on-disk schema changes. The fragments written by the moved functions are
the same shape as before; this is a pure code-organization refactor.

## Sequencing / implementation plan

1. **Create `scripts/lib/state.sh`** with the twelve functions in the order
   listed in §Components. Include a one-line file header comment naming
   what the module owns ("Atomic JSON fragment I/O for run-state and per-TDD
   records").
2. **Edit `scripts/implement.sh`** to source the new module and remove the
   moved function definitions. Preserve every comment that was attached to a
   moved function — comments move *with* the function. Comments that
   referenced the moved cluster from elsewhere in `implement.sh` (none
   expected; verify) stay where they are.
3. **Run the fixture build** (see Verification plan) to confirm the
   pre/post run-state diff is empty.

## Failure modes & edge cases

- **Sourcing order matters.** `state.sh` is sourced before any of the
  pause/retry, gates, or resume code that calls into it. Source order is
  controlled by the order of `. "$SCRIPT_DIR/lib/*.sh"` directives in
  `implement.sh`; this slice places `state.sh` first.
- **A moved function references a variable defined later in
  `implement.sh`.** All twelve functions read shell-scope variables
  (`$LOGDIR`, `$REPORT`, `$RUN_ID`, `$MAINREPO`, etc.) that are set by
  `state_init` and persisted in the outer shell scope. Because bash sourcing
  shares scope, this works unchanged — no parameterization required. Risk:
  if a future refactor wants to make `state.sh` a true library, those
  variables would need to be passed; for now, the dogfood compliance goal
  is achieved without that change.
- **A moved function name collides with a future module.** All function
  names retain their existing `_`-prefix convention for internal helpers
  and bare-name convention for public functions; the convention is
  preserved across slices to avoid cross-module collisions.
- **`set -e` / `set -u` interaction with sourced files.** Bash's `set -e`
  honors sourced code identically to inline code; no change in behavior.
  `set -u` likewise.
- **`shellcheck` runs over `lib/*.sh` independently.** A `# shellcheck
  source=lib/state.sh` directive at the source site links the analyzer's
  view so cross-file references resolve. The new module gets its own
  `shellcheck` clean pass under `ci-checks.sh`.

## Verification plan

**Observable surface:** the on-disk run-state fragments produced by an
`/implement` run — specifically the byte content of
`docs/tdd/.implement-logs/<runid>/run.json` and each
`docs/tdd/.implement-logs/<runid>/tdd-*.json`.

**Observation points:**

1. **Baseline fixture build (pre-refactor).** Check out master HEAD; pick a
   small fixture TDD (e.g. TDD 0007's existing build artifacts, or a
   minimal no-op TDD created for this verification). Invoke `/implement
   docs/tdd/<fixture>.md`. Capture the resulting `run.json` and
   `tdd-*.json` fragments.
2. **Refactor-branch fixture build (post-refactor).** Check out this TDD's
   branch; invoke `/implement docs/tdd/<fixture>.md` against the same
   fixture. Capture the same fragments.
3. **Byte-equal diff (modulo non-determinism).** `diff` the two fragment
   sets, normalizing only:
   - `started_at`, `updated_at`, `finished_at` timestamps
   - `run_id` (UUID)
   - log file paths containing the runid

**Expected observations (PASS):**

- After normalization, the run.json and tdd-*.json fragments are
  byte-identical pre- and post-refactor.
- The verdict line in REPORT (`BATCH_RESULT: OK` for the fixture)
  appears in both runs.
- `bash scripts/ci-checks.sh` passes on the refactor branch (`shellcheck`
  clean on both `implement.sh` and `lib/state.sh`).

**SKIP not applicable** — this refactor has an observable surface
(byte-identical state fragments), even though it changes no behavior.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-69 (throughline holds itself to Theme A — slice 1/3) | `scripts/implement.sh` post-refactor line count ~1500 (target ~600 after all three slices); `scripts/lib/state.sh` is a new file at ~400 lines whose scope is justified by the legitimately-wide-but-shallow code-move exception under FR-53 |

This slice does not fully satisfy FR-69 on its own — slices 2 (TDD 0016)
and 3 (TDD 0017) complete the dogfood. The acceptance criterion for FR-69
("no shell script throughline ships is in a state that … would be rejected
for scope under FR-54 without a recorded exception") is met only after all
three slices land.

## Dependencies considered

No new external dependencies. The new module is pure bash with no library
imports.

(Alternative considered: **lift state I/O to a Python helper** — rejected:
adds a runtime dependency, breaks the "any POSIX-like box" assumption
already encoded in the existing scripts, and provides no benefit beyond
the dogfood compliance the bash extraction also achieves.)

## PRD conflicts surfaced (and resolution)

None.

## Decisions to promote (ADR candidates)

None from this TDD. The bash-module convention this TDD establishes
(`scripts/lib/<cluster>.sh` sourced by `implement.sh`, no top-level
side effects, shared shell scope for state variables) is sufficiently
scoped to throughline's own runner that an ADR would be over-formal;
the convention is documented inline in the new module's header comment
and reinforced by TDDs 0016 / 0017 following the same pattern.

## Touched files

- `scripts/implement.sh` — remove ~400 lines (the state-I/O cluster);
  insert ~3 lines (source directive)
- `scripts/lib/state.sh` — new file, ~400 lines (the moved cluster, verbatim
  + one-line header comment)

Total: 2 files touched.

## Expected diff size

- `scripts/implement.sh` — net change ~-400 lines (large *removal*; the
  remaining file is well within the per-file bound)
- `scripts/lib/state.sh` — ~400 lines added (exception: legitimately-wide
  code move from `implement.sh`, no behavior change, verified by
  byte-identical run-state fragments per Verification plan §3)

Total expected diff: ~800 lines of mechanical move across 2 files.

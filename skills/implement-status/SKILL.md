---
name: implement-status
description: Show progress for the currently-running `/implement` job. Prints a one-shot snapshot (current TDD, stage, an estimate-labeled percent, per-TDD statuses, log/PR pointers) and, for a live watch, hands you a one-line `!bash …/scripts/status.sh --follow` command to paste yourself (Ctrl-C exits the watch; the build is unaffected). Read-only — no pause/resume/cancel. Invoke with /implement-status.
---

# Implement status

A read-only progress view for the detached `/implement` runner. The runner
writes a structured run-state record under
`docs/tdd/.implement-logs/<ts>/state.d/` (FR-27); this skill renders it.

## What you see

The snapshot derives the rendered view fresh on each call from the per-TDD
fragments — there is no second artifact that can drift from the record. It
shows:

- **Header** — mode (sequential / combined / parallel), integration branch,
  elapsed time, run state.
- **Rollup** — `<completed> done / <total>  ·  ~<P>% (estimate)` — the percent
  is always suffixed `(estimate)` and never reads 100% while any TDD is
  non-terminal (FR-30 honesty). Failed / blocked / skipped counts are reported
  separately when non-zero.
- **Per-TDD table** — queue position, slug, status
  (`pending|building|verifying|reviewing|done|failed|blocked|skipped`),
  current stage (`build|test-first|verify|verify-runtime|review|flip`), and
  the TDD's branch / PR URL when known.
- **Current focus** — the in-progress TDD and its stage, when a TDD is
  non-terminal.

If no `/implement` run is active, the skill says so plainly and (if a previous
run exists) summarizes the last run's final state. It never reports false
progress.

## Halted runs

When the most recent run is halted (state `paused`, `blocked`, or `failed`), the
snapshot switches to a one-screen halt context (FR-64): the halt cause from the
closed enum, the triggering finding reference, and the deterministic next-action
options, each on its own numbered line. Halted-run rendering fits 24×80 by
default; to see full logs use `cat docs/tdd/.implement-logs/<runid>/REPORT`. The
`Resume: /implement --resume <runid>` line appears only when the cause is a
recoverable (paused-state) one.

A run whose state is `interrupted` (TDD 0030 §3) did not exit cleanly — the
runner died mid-gate, leaving one or more TDDs orphaned in a non-terminal status.
The snapshot renders a distinct "the run did not exit cleanly" banner naming each
orphaned TDD + gate and pointing at `/implement --resume <runid>`; it is never
reported as `done`.

`--follow` watch mode in a non-interactive background job: use `kill -TERM` (or
`-HUP`/`-QUIT`), not `kill -INT` — SIGINT is silently un-trappable in that launch
mode per POSIX. SIGINT still works correctly in the foreground.

## Run it

For the on-demand snapshot, run the renderer once via a single Bash call and
relay the output:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

Add `--logdir <dir>` to inspect a specific historical run dir instead of the
active one.

## Live watch (do NOT invoke from this skill)

For a live watch that refreshes until you press Ctrl-C, hand the user the
following line for them to paste themselves as a foreground `!` command:

```
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" --follow
```

DO NOT call `status.sh --follow` through the Bash tool from this skill — it is
an endless foreground loop that would block the session. The user runs it in
their TUI directly; Ctrl-C in their terminal exits the watch cleanly. The watch
is read-only — it never signals the build PID, never edits files, and offers
no pause / resume / cancel.

## Where the record lives

- `docs/tdd/.implement-logs/<ts>/state.d/run.json` — run-level rollup +
  identity.
- `docs/tdd/.implement-logs/<ts>/state.d/<slug>.json` — one fragment per
  queued TDD, updated atomically at every status / stage transition.
- `docs/tdd/.implement-logs/latest` — a symlink pointing at the active run's
  `<ts>` directory; `status.sh` resolves it by default.

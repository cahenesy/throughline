# TDD 0069: `/build-tdds` hardening — a lock that holds, and the 0067 follow-ups

Status: draft
PRD refs: FR-18, FR-43, FR-88, FR-41, NFR-4
PRD-rev: f6ef178
ADR constraints: 0005, 0006, 0011, 0013, 0015, 0016

## Approach
Two groups of fixes to the shipped `/build-tdds` (3.49.0).

**1. The single-run lock never held (FR-18 / FR-43).** `tl_run_lock`
writes `$$`. The harness runs every Bash call in a fresh shell that exits
at once, so the recorded PID is dead by the next call, and any second run
"reclaims" it. This was observed in run 20261005-174458. The check-then-
write is also not atomic. The fix:
- record the **session process**, meaning the first long-lived ancestor
  of the Bash shell, together with its **start time**;
- treat a lock as live only if that PID exists *with the same start
  time*, which defeats PID reuse;
- acquire it atomically with noclobber (`mkdir` is not atomic on this
  machine's uutils);
- let a second `/build-tdds` from the same session re-enter its own lock.

**2. The 0067 review follow-ups.** 0067 is implemented, so its text is
not edited; this TDD records the changes.
- **(a)** Stream error text no longer reaches a shell command line. The
  parent writes it to a file with the file-write tool, and a block reads
  that file.
- **(b)** The implementer's rate-limit rule points to the
  `credits_required` exception.
- **(c)** The live probe removes the harness session folders its headless
  children create.
- **(d)** `tl_run_retry_begin` does what 0067 specified: it copies the
  failed report itself and prints `report=` first.
- **(e)** `TL_BASE_SHA` is validated.

## Components & interfaces
All of these live in `scripts/lib/run-record.sh` unless stated otherwise.

**`tl_session_pid`** prints `<pid> <start>` for the first ancestor of the
current shell whose command name (`ps -o comm=`) is not one of `bash`,
`sh`, `zsh`, `dash`, `env`, `timeout`, `nohup`, `script`, `sudo`,
`bwrap`, `firejail`, `flatpak-spawn`.
- `<start>` = `ps -o lstart= -p <pid>`, with whitespace squeezed to
  single spaces.
- The walk follows `ps -o ppid=`.
- PID 1 is never chosen: reaching it returns rc 1 with no output, as does
a `ps` failure.

**Lock file** `docs/tdd/.implement-logs/.run.lock`. Its single line is
`pid=<pid> start=<start>`. Liveness, `_tl_lock_live <line>`:
- **Current format:** `kill -0 <pid>` succeeds **and** the current
  `lstart` of that PID equals `<start>`.
- **Legacy bare-PID line:** `kill -0` only.

**`tl_run_lock <repo> [owner]`**. `owner` defaults to `tl_session_pid`;
if that fails, rc 1 with
`run-record: cannot identify the session process; not locking`.
Every create below uses bash noclobber (`set -C`, `O_EXCL`), which this
machine validated as atomic.

1. **No lock file.** Run `(set -C; printf '%s\n' "<line>" > lock)`.
   - If that fails, another run won the race: rc 1,
     `run-record: lock held by a concurrent run`.
2. **Read the line.** If the file vanished (the owner unlocked), go
   back to step 1. An empty or unparseable line means a writer is
   mid-write. Retry 3× at 0.2 s. If it is still unreadable: rc 1,
   `run-record: lock unreadable; held` (never treated as dead).
3. **Same owner** (same pid and same start) → rc 0. Re-entrant within a
   session.
4. **Live other owner** → rc 1,
   `run-record: lock held by live PID <pid> (started <start>)`.
5. **Dead or reused owner → serialized reclaim.**
   1. Take a guard with `(set -C; : > lock.reclaim)`.
      - If the guard exists and is older than 60 s, break it with an
        atomic `mv lock.reclaim lock.reclaim.stale.$$` and retry once. Only
        one breaker's `mv` succeeds.
      - Otherwise rc 1, `run-record: lock reclaim in progress`.
   2. Re-read the lock. If it **equals** the stale line observed in
      step 2, run `rm -f lock` and then step 1's create.
   3. Otherwise, someone else's fresh lock is there: remove the guard
      and go back to step 2.
   4. Always remove the guard before returning.

   A slower reclaimer can never delete a fresh lock, because it compares
   under the guard. Exactly one racer gets rc 0.

**`tl_run_lock_reclaim <repo>`** stays as a thin alias of `tl_run_lock`
for callers. **`tl_run_unlock <repo>`** removes the file only when the
owner matches `tl_session_pid` or is dead (legacy bare-PID lines: only
when dead). Removing a dead owner's lock takes the same reclaim guard
and re-compares the line before `rm`. Otherwise it returns rc 1 and prints
`run-record: not the lock owner`.

**`skills/implement/SKILL.md` step 2** becomes block `<!-- tl:lock -->`
(input `TL_REPO`; it follows 0066's block contract). It runs
`tl_run_lock "$TL_REPO"` and prints `lock=acquired`, or the refusal on
stderr with rc 1, after which the skill stops. Every "unlock" in the
skill runs `<!-- tl:unlock -->`, which calls `tl_run_unlock`.

**(a) Fall-back reason via a file.** Replaces rule 2's inline argument:
- The parent writes the raw error text with its file-write tool, never
  a shell, to `<run-dir>/<slug>.fallback-reason.txt`.
- It then runs block `<!-- tl:escalation-fellback-record -->`. Inputs:
  `TL_REPO`, `TL_RUN`, `TL_SLUG`, `TL_MODEL`, and `TL_REASON_FILE`
  (which must equal that path).
- The block validates `TL_MODEL` against `^[A-Za-z0-9._:-]+$` (else
  rc 2).
- It reads the file's first non-empty line, deletes bytes `\000–\037`
  and `\177`, and caps the line at 300 chars.
- It calls
  `tl_run_set_escalation … fell-back "$TL_MODEL" "dispatch error: <line>"`.
- A missing or empty file is recorded as reason
  `dispatch error: (no detail)`.
- The block deletes the file after reading, so a stale reason from an
  earlier attempt can never be reused.

**(b)** In step 7, the sentence "If worker exit or stderr matches
`rate.?limit|…` → paused" gains: "unless this TDD is `escalated` and the
text matches `credits_required|requires usage credits`; that is a
fall-back (Escalation check, rule 1 exception), not a pause."

**(c) Probe cleanup** (`tests/live/escalation-probe.sh`). The EXIT trap
also removes the harness project folder created for the scratch dir:
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<enc>`.
- `<enc>` is `$(cd -P "$SCRATCH" && pwd)` with every `[^A-Za-z0-9]`
  replaced by `-`, which matches the harness's encoding.
- It is removed only if all of these hold:
  - `$SCRATCH` came from `mktemp -d`;
  - `<enc>` starts with `-` and is at least 8 characters long;
  - the path contains no `..`;
  - the target is a directory and **not a symlink**.
- Nothing else under `projects/` is touched.

**(d) `tl_run_retry_begin <repo> <run> <slug>`** now:
1. resolves `tl_run_failed_report`;
2. copies it to `${report%.txt}.prev.txt` (the as-built name);
3. archives the verdicts and sets `building`, as before;
4. prints, in order: `report=<path or empty>`, `implementer_report=<copy or empty>`, `archive=<dir>`.

The `tl:retry-begin` block shrinks to the source lines plus one call.
**(e)** In `tl_escalation_fellback_check` and the `tl:escalation-verify`
block, a `<base-sha>` that doesn't match `^[0-9a-f]{7,64}$` → rc 2, with
`run-record: bad base sha`.

## Data & state
- The lock line format changes. A legacy bare-PID lock is read with the
  old liveness rule and is replaced on the next acquisition.
- New per-TDD file: `<run-dir>/<slug>.fallback-reason.txt`, written only
  on a fall-back.

## Sequencing / implementation plan
1. `tests/build-hardening.test.sh`, plus updated `tests/escalation.test.sh`
   / `tests/run-record.test.sh` cases. Register the new eval in
   `tests/implement-gate.test.sh`.
2. `run-record.sh`: `tl_session_pid`, the lock and unlock rewrite,
   `tl_run_retry_begin` (d), and the base-sha validation (e).
3. `SKILL.md`: the `tl:lock` / `tl:unlock` blocks, (a), (b), and the
   shrunken retry-begin block.
4. Probe cleanup (c).

## Failure modes & edge cases
**Real risks**
- **The ancestor walk lands on the wrong process.** For example, a
  terminal multiplexer or a harness wrapper that is itself short-lived.
  Mitigation: the stop-list is explicit, and the eval drives it through
  real nested shells. If it picks a process that later exits, the lock
  merely reclaims early: the FR-43 behaviour, never a stuck lock.
- **The lock is left after a normal stop if the parent skips the unlock
  block.** The owner is the live session, so a second run in *another*
  session refuses, and the refusal names the PID. Closing the session
  frees it. A run in the same session re-enters (step 2).
- **`ps -o lstart` format differs by platform.** Only equality is
  compared, against the same machine's `ps`, so the format never needs
  parsing.
- **Legacy lock files** from 3.49.0 contain the dead shell's PID, so they
  reclaim immediately. That is correct.

**Overblown risks**
- **A noclobber race on network filesystems.** `.implement-logs` is local.
- **The reason file is written by the parent model.** It is still model
  output, but it never reaches a shell, and control bytes are stripped
  before it enters the JSON sidecar.

**Unspoken risks**
- **Grok Build's process tree is unverified.** If `tl_session_pid` finds
  no long-lived ancestor there, it returns rc 1 and the skill stops with
  the message. That is loud, not silent. A Grok session should observe
  this before relying on it.
- **Probe cleanup depends on the harness's project-dir encoding.** If
  that changes, the folder isn't found and nothing is deleted. The
  failure is safe, and the folders pile up as before.

## Verification plan
- **Surface:** the stdout, stderr and rc of the functions; the lock
  file's contents; the stdout of extracted skill blocks; the filesystem
  under a fake `CLAUDE_CONFIG_DIR`.
- **Harness:** a temp git repo with an initialized run. Blocks are run
  with `TL_*` env only.
- **Observation points → expected (PASS):**
  1. **The walk skips shells.** Run
     `python3 -c 'import subprocess,sys; subprocess.run(["bash","-c","bash -c tl_session_pid"])'`.
     It prints the **python3** PID, which the eval knows from
     `os.getpid()` written to a temp file, along with its non-empty start
     time. This does not depend on the CI ancestor tree. With `PATH`
     wrappers `bwrap`/`timeout` in the chain, it skips them too.
  2. **The lock outlives the Bash call.** A sleeper process is the owner
     (`sleep 60 &`, passed explicitly).
     - `tl_run_lock <repo> "<pid> <start>"` → rc 0, with the file line
       `pid=<pid> start=<start>`.
     - A second call with another owner → rc 1, naming the PID.
     - The same owner again → rc 0 (re-entrant).
  3. **A dead owner is reclaimed.** Kill the sleeper, then the next lock
     → rc 0 with the new owner (FR-43).
  4. **PID reuse is detected.** Rewrite the lock with the live sleeper's
     PID but a different `start=`. The next lock with another owner
     → rc 0.
  5. **Races have one winner.**
     - 10 background `tl_run_lock` calls with distinct live owners against
       an **absent** lock → exactly one rc 0, and the file names it.
     - 10 against a **dead-owner** lock → exactly one rc 0, and the lock
       is never deleted out from under that winner. The final line equals
       the winner's, and no `lock.reclaim` is left behind.
  5b. **Partial writes are not stolen.** Pre-create an **empty** lock file
      → `tl_run_lock` returns rc 1 `lock unreadable; held` after its
      retries, and the file is untouched. A guard file older than 60 s is
      cleared.
  6. **Unlock checks ownership.**
     - `tl_run_unlock` by a non-owner with a live owner → rc 1, file
       kept.
     - By the owner → removed.
     - A dead owner → removed.
  7. **Legacy locks.** A bare-PID lock of a dead PID → reclaimed. A
     bare-PID lock of a live PID → refused.
  8. **The extracted `tl:lock` and `tl:unlock` blocks.** They run as two
     `bash` children of one python3 parent (as in obs 1). The first
     parent stays alive, blocked on a sleep, while a second parent tries.
     - Both `tl:lock` runs print `lock=acquired`: the session re-enters.
     - A different python3 parent while the first still holds the lock →
       rc 1.
     - `tl:unlock` from the owner removes the lock; from the non-owner
       → rc 1, and the lock is kept.
  9. **(a) The reason block.**
     - A reason file containing `boom "x" $(whoami) \ y`, then
       ESC-`[31m`, then a second line → the sidecar
       `escalation_reason` is exactly
       `dispatch error: boom "x" $(whoami) \ y[31m`: control byte
       stripped, no command executed, first line only.
     - A missing file → `dispatch error: (no detail)`.
     - After the block runs, the reason file no longer exists.
     - `TL_MODEL='x;rm'` → rc 2.
  10. **(b) Text check.** Stated reason: this is dispatch-time prose
      that an eval can't execute. The step-7 rate-limit sentence
      contains `credits_required` (the file is asserted readable
      first).
  11. **(c) Probe cleanup.** Run `tests/live/escalation-probe.sh` against
      a stub `claude` (via `THROUGHLINE_PROBE_CLAUDE`) that creates
      `<fake config>/projects/<enc of its cwd>/x.jsonl` and emits a
      minimal valid stream.
      - After exit, that folder is gone.
      - A sibling folder `projects/-keep-me` still exists.
      - A scratch path whose encoded folder is a **symlink** is not
        followed or removed.
  12. **(d) `tl:retry-begin` on a failed fixture.** The first line is
      `report=…review.txt`, the second `implementer_report=…review.prev.txt`
      (the copy exists), and the third `archive=…/retry-1`. The block
      itself contains no `cp`. `tests/escalation.test.sh` [12] asserts
      this three-line shape and order.
  13. **(e) Base sha.** `tl_escalation_fellback_check … 'HEAD;x' implementer`
      → rc 2, `bad base sha`. A valid 40-hex sha → the previous
      behaviour.
  14. **Regression.** All existing evals stay green, including 0067's
      `escalation.test.sh` (with its retry-begin expectations updated as
      in 12) and `run-record.test.sh` [E] (reclaim when the PID is dead).

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement traceability | FR-21, FR-18, FR-43, FR-88, FR-41 each map to a named function, hook branch, or skill block | One mapping indirect but named | An in-scope requirement missing |
| interface concreteness | Every new helper (config discovery, tl_session_pid, lock fields, reason block) has args, stdout, rc pinned | One error return implicit | A reader cannot tell what a helper prints or returns |
| executable verification | Hook run via stdin in temp repos with stub tools and real ruff when present; skill blocks extracted and run; negated checks fail closed (L-001/L-011) | One check text-only with stated reason | A behaviour asserted only by grepping text |
| alternatives-analysis substance | Each mechanism names >=1 rejected alternative with reason (PWD discovery, any-ruff-config opt-in, --fix, $PPID lock, env-var reason) | One rejection thin | None |
| verification-plan actionability | Surface, observation points, PASS values named, incl. issue #180 three control cases | One fixture underspecified | Missing or non-actionable |
| scope-bound adherence | Each TDD <=8 files, <=500 body lines; estimates padded; exceptions declared | One justified exception | Over a bound with no exception |
| regression safety | Repos that DID configure tools format/lint as before; a live lock still refuses; existing evals stay green | One regression case only implied | A previously-working configured path is untested or broken |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-18 single-run lock | `tl_session_pid` owner + noclobber acquisition; obs 2, 5, 8 |
| FR-43 stale lock reclaimed; a live owner still blocks | start-time liveness, reclaim; obs 3, 4, 7 |
| FR-88 outcome recorded honestly | (a) reason via file; (e) base-sha validation; obs 9, 13 |
| FR-88 / FR-41 `credits_required` is a fall-back, not a pause | (b) step-7 pointer; obs 10 |
| FR-88 Retry report hand-off | (d) `tl_run_retry_begin`; obs 12 |
| NFR-4 | refusals name the owner; a missing session process stops loudly; the probe leaves no stray state |

## Dependencies considered
No new dependencies.

Rejected alternatives:
- **Record `$PPID` of the Bash call.** It was observed to be the harness
  here, but any wrapper shell breaks it, and it is open to PID reuse.
- **Use `mkdir` as the mutex.** It is not atomic on this machine's uutils
  coreutils 0.8.0; both racers get rc 0. Noclobber was validated as
  atomic.
- **Publish with `ln tmp lock`.** It is atomic in the kernel, but
  whether uutils `ln` pre-checks the target (the same TOCTOU as its
  `mkdir`) is unverified. A noclobber create plus a reclaim guard needs
  no new tool assumptions.
- **`flock(1)`.** It needs a held file descriptor across calls, and the
  harness can't keep one open between Bash calls.
- **Pass the reason through an env var.** The parent would still
  shell-quote untrusted text.
- **Leave probe sessions to accumulate.** They clutter `/resume`
  history, and the cleanup is a one-folder `rm` with strict guards.

## PRD conflicts surfaced (and resolution)
None. FR-18 and FR-43 already require a working lock. The shipped code
didn't meet them, which TDD 0062's eval missed because it used a fixed
PID.

## Decisions to promote (ADR candidates)
None. These are corrections to existing requirements.

## Touched files
- `scripts/lib/run-record.sh` — tl_session_pid, lock/unlock rewrite, retry_begin report copy, base-sha validation
- `skills/implement/SKILL.md` — tl:lock / tl:unlock blocks, fall-back reason file block, credits pointer, shrunken retry-begin block
- `tests/live/escalation-probe.sh` — remove the harness project folder for its scratch dir
- `tests/build-hardening.test.sh` — lock, reason, probe-cleanup, base-sha observations
- `tests/escalation.test.sh` — retry-begin expectations moved to the function
- `tests/run-record.test.sh` — lock line format in existing cases
- `tests/implement-gate.test.sh` — register the new eval

## Expected diff size
- `scripts/lib/run-record.sh` — 190 lines
- `skills/implement/SKILL.md` — 90 lines
- `tests/live/escalation-probe.sh` — 30 lines
- `tests/build-hardening.test.sh` — 420 lines (exception: one cohesive eval over lock races, the reason block and the probe stub, 15 observation points)
- `tests/escalation.test.sh` — 40 lines
- `tests/run-record.test.sh` — 25 lines
- `tests/implement-gate.test.sh` — 12 lines
Total expected diff: 807 lines across 7 files.

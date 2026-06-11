# TDD 0054: Runner & observability hardening (watcher staleness, lock identity, status robustness)
Status: implemented
PRD refs: FR-39 (detached run + completion callback); FR-28 (progress snapshot); FR-72 (learning capture); FR-69 (self-compliance with Theme A)
PRD-rev: 0aa1e28
ADR constraints: 0006

## Approach
Five medium/low correctness defects across the runner-adjacent surface (the
watcher, the single-run lock, status rendering, learning numbering) each produce a
misleading-but-not-corrupting observable. Grouped because they share the
"observability / run-identity" theme and touch the runner shell + status renderer:

- **A9 (watcher stale state).** `implement-watch.sh`'s completion block
  (129-156) reads `latest/state.d/run.json` with **no `WATCH_START` staleness
  guard** (unlike the inactivity probe at 114 which does gate on it). On a 2nd+ run
  where the new build dies BEFORE `state_init` relinks `latest` (single-run-lock
  reject, an early FATAL, a parse error), `latest` still points at the PRIOR run,
  whose run.json carries a terminal state — so the watcher emits
  `IMPLEMENT_RUN_COMPLETE logdir=<prior> state=done` and the callback inspects the
  wrong run, masking the real fast-failure.
- **A25 (lock identity).** The single-run lock-staleness check trusts an arbitrary
  stored PID; if an unrelated live process has reused the dead runner's PID, the
  lock reads as "alive" and blocks ALL future runs (a wedge requiring manual
  removal).
- **A26 (status arg crash).** `status.sh --logdir` / `--max-seconds` with no value
  crashes under `set -u` instead of a clean exit-2 usage error.
- **A27 (status null scalar).** The jq parser path turns a `null` run.json scalar
  into the literal string `"null"`, breaking `[ "$total" -gt 0 ]` (parser-divergent
  from the sed path).
- **A2 (learnings numbering abort).** A non-numeric `L-` id aborts the
  `LEARNINGS.md` numbering/idempotency scan loop under `set -u`, so accept can
  mis-number or fail to dedup.

## Components & interfaces
No new public interface — targeted fixes:
- **A9:** record THIS launch's expected run identity (stamp `WATCH_START` against
  the run's `started_at`/logdir) and, in the completion block, refuse to report a
  run.json whose `started_at`/logdir predates `WATCH_START`; emit `state=unknown`
  (a non-terminal state the skill already handles by re-arming the poll) instead of
  the stale terminal state. Reuse the same `[ "$newest" -ge "$WATCH_START" ]` gate
  the inactivity probe already applies.
- **A25:** validate the lock owner by more than the bare PID — write `PID
  <start-token>` into the lock and, on the staleness check, treat the lock as alive
  only when the live PID's start-token matches. The start-token is resolved in a
  fixed priority order (deterministic, no new dependency): (1) `/proc/<pid>/stat`
  field 22 (start-time jiffies, Linux); (2) `ps -o lstart= -p <pid>` (macOS/BSD);
  (3) PID-only liveness (today's behavior) when neither is available. A PID-alive
  whose start-token MISMATCHES is a provably-reused PID → stale lock, safe to break;
  a match, an absent token (old lock), or no resolver available all fail SAFE
  (treat as alive).
- **A26:** the `--logdir`/`--max-seconds` option parser checks that a value
  argument is present (`[ $# -ge 2 ]` / `${2:-}` guard) and exits 2 with a usage
  line instead of dereferencing an unset `$2` under `set -u`.
- **A27:** the jq scalar read maps a JSON `null` to empty (the sed path's behavior)
  before the numeric test, so `[ "$total" -gt 0 ]` sees a clean empty/0, not the
  string `"null"`.
- **A2:** the numbering/idempotency scan guards each parsed `L-` id with the
  numeric predicate before arithmetic, skipping a malformed id rather than aborting
  the loop under `set -u`.

## Data & state
No schema change. A9 adds a launch-identity comparison (in-memory + the existing
lock/run.json fields); A25 augments what the lock file stores (PID + start-token)
— a lock written by an older runner (PID only) is treated as "can't verify
identity → fall back to today's PID-only liveness check", so no migration breakage.

## Sequencing / implementation plan
1. A9: `WATCH_START`-gate the watcher completion read; emit `state=unknown` for a
   pre-`WATCH_START` `latest`.
2. A25: write PID+start-token into the lock; validate both on staleness check;
   fall back to PID-only when the token is absent (old lock).
3. A26: guard the `--logdir`/`--max-seconds` value args; exit-2 usage.
4. A27: map jq `null` scalar → empty before the numeric test.
5. A2: numeric-guard the `L-` id scan.
6. Regressions in `tests/watcher-inactivity-completion.test.sh` (A9),
   `tests/run-progress-visibility.test.sh` or the status eval (A26/A27),
   `tests/detached-run-recovery.test.sh` (A25), and the learnings eval (A2);
   register if new.

## Failure modes & edge cases
**Real risks.**
- *A9 emits `state=unknown` for a genuinely-fast-but-real completion.* The skill
  treats `unknown` as non-terminal and re-arms a poll on the build PID, which then
  observes the real terminal state — so a false `unknown` self-corrects rather than
  masking. Verification §1 asserts a genuine completion (fresh `latest`) still
  reports its real terminal state (no over-broad `unknown`).
- *A25 start-token unavailable on a minimal host* (`ps`/`/proc` both absent).
  Mitigated by the documented fallback to PID-only liveness (today's behavior) —
  no host regresses; identity-validation is a strict improvement where available.

**Overblown risks.**
- *A26/A27/A2 are `set -u`/parse guards* with no behavioral surface beyond not
  crashing / not mis-typing `null`. Low blast radius.

**Unspoken risks (elephants).**
- *A25 could break a legitimately-held lock if the start-token comparison is
  wrong* (treating a live runner's lock as stale → two concurrent runs). This is
  the dangerous direction. Mitigated by failing **safe**: treat the lock as ALIVE
  whenever identity can't be positively disproven (token missing, ps unavailable,
  or PID+token both match) — only a PID-alive-but-token-mismatch (provable reuse)
  breaks it. Verification §2 tests both: matching token → lock held; mismatched
  token (reused PID) → lock broken.

## Verification plan
- **Observable surface:** (a) the watcher's `IMPLEMENT_RUN_COMPLETE … state=` line;
  (b) the lock-staleness decision (held vs broken) + run launch outcome; (c)
  status.sh exit code / rendered totals; (d) `LEARNINGS.md` numbering after accept.
- **Observation points (mechanical, the cited evals with backgrounded launches /
  stubbed `ps`):**
  1. **A9.** Pre-seed a prior run dir with `latest` → it and a terminal run.json;
     launch a watcher whose build dies before `state_init` (stub the build to exit
     pre-relink) → assert the completion line is `state=unknown` (not the stale
     `state=done`). Control: a build that DOES relink `latest` to a fresh run still
     reports its real terminal state.
  2. **A25.** Write a lock with PID of a live process but a MISMATCHED start-token →
     assert the staleness check breaks it (run proceeds). Control: matching
     PID+token → lock held (run refused). Control: token-absent old lock → PID-only
     fallback (today's behavior).
  3. **A26.** `status.sh --logdir` with no following value → exit code 2 + usage
     line, no `set -u` crash. **A27.** A run.json with a `null` scalar → the
     numeric test sees empty/0, no `[: null: integer expression expected`.
  4. **A2.** A `LEARNINGS.md` containing a malformed `L-xx` heading → accept
     numbers the new entry correctly and does not abort the scan.
- **Expected observations (PASS):** each folded bug's regression FAILS pre-fix
  (stale `state=done`; reused-PID wedge; `set -u` crash / `null` mistype; scan
  abort) and PASSES post-fix, with the A9 and A25 controls confirming no
  over-correction.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement + folded-bug traceability | Every FR-53/54/67 tie-in AND each folded bug (A-id) maps to a named design element | All mapped | Any req or folded bug untraced |
| Folded-bug regression coverage | Each folded bug has a named observation point that fails pre-fix / passes post-fix | Each folded bug has a regression check | A folded bug has no regression observation |
| Single-source-of-truth (refactors) | One canonical helper; all callers verified-thin delegates | Callers delegate; one definition | A divergent copy remains |
| Sourcing + back-compat | New shared lib sources cleanly in all 4 contexts incl markers minimal-host; existing callers/tests unbroken | Sourcing + guard specified | A context unhandled or a caller regressed |
| Verification-plan actionability | Observable surface + exact points + expected values | Surface + points named | placeholder/vague |
| Scope-bound adherence | Within bounds, or a declared/justified exception (state.sh) | Within bounds | Bound blown without exception |
| Naming consistency | Same helper names across all 5 TDDs | Mostly consistent | Same concept named two ways |

## Requirement traceability
| Requirement / bug | Design element |
|---|---|
| FR-39 (detached run + callback) | A9 watcher reports the CORRECT run (or `unknown`), not a stale prior; A25 lock can't wedge on a reused PID |
| FR-28 (progress snapshot) | A26/A27 status renders robustly (clean usage exit; `null`→0) |
| FR-72 (learning capture) | A2 numbering scan survives a malformed `L-` id |
| FR-69 (self-compliance with Theme A) | hardens the runner's own scripts (watcher/lock/status/learnings) against the audited defects |
| ADR 0006 (artifacts grounded) | the watcher's completion artifact reflects the actual run, not a stale terminal record |
| bugs A9/A25/A26/A27/A2 | each → its fix above + named regression (with controls for A9/A25) |

No gaps.

## Dependencies considered
No new external dependency. A25 uses `ps`/`/proc` start-time (already-present OS
facilities) with a PID-only fallback. Rejected alternative:
- **A lock daemon / flock(1)** for run mutual-exclusion — rejected: heavier, adds a
  tool dependency, and changes the detached-run model; the PID+start-token check is
  a minimal, dependency-light hardening of the existing lock-file scheme.

## PRD conflicts surfaced (and resolution)
None. Hardens existing run-lifecycle/visibility requirements; no ADR reversed.

## Decisions to promote (ADR candidates)
None — localized hardening across the runner surface.

## Touched files
- `scripts/implement-watch.sh` — `WATCH_START`-gate the completion read; `state=unknown` for a stale `latest` (A9).
- `scripts/implement.sh` — write + validate PID+start-token in the single-run lock; PID-only fallback (A25).
- `scripts/status.sh` — guard `--logdir`/`--max-seconds` value args (A26); map jq `null` scalar → empty (A27).
- `scripts/lib/learnings.sh` — numeric-guard the `L-` id numbering scan (A2).
- `tests/watcher-inactivity-completion.test.sh` — A9 stale-latest + control regressions.
- `tests/detached-run-recovery.test.sh` — A25 reused-PID + control regressions.
- `.claude-plugin/plugin.json` — version bump (build-applied housekeeping).

## Expected diff size
- `scripts/implement-watch.sh` — 30 lines (WATCH_START gate + unknown emit; ×1.4 shell-script).
- `scripts/implement.sh` — 35 lines (lock PID+token write + validation + fallback; ×1.4).
- `scripts/status.sh` — 25 lines (arg guards + null map; ×1.4).
- `scripts/lib/learnings.sh` — 12 lines (numeric guard; ×1.4).
- `tests/watcher-inactivity-completion.test.sh` — 90 lines (A9 + control; ×1.6 test).
- `tests/detached-run-recovery.test.sh` — 90 lines (A25 + controls; ×1.6 test).
- `.claude-plugin/plugin.json` — 2 lines (version bump).
Total expected diff: ~282 lines across 7 files. No per-file exception needed.

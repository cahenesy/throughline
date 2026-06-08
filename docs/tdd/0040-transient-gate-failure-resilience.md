# TDD 0040: Transient gate-failure resilience — ci-checks retry-once + no-verdict is couldn't-observe, not failed

Status: draft
PRD refs: FR-15 (gap-closure); FR-57 (gap-closure); NFR-4
PRD-rev: d289607
ADR constraints: 0004, 0005, 0006, 0007

## Approach

Two transient gate-failure modes observed in run 20260608-011142 each produced a
**terminal `failed`** that, on the evidence, was not a real "observed and wrong"
verdict — violating NFR-4's distinction between *observed-failure* and
*couldn't-observe*:

1. **A flaky ci-checks run.** A single flaky test in an UNRELATED suite
   (`bounded-rework-loop.test.sh`, `build_attempt.token_spend` → null under load)
   made `ci-checks.sh` go red once; the runner marked the TDD `failed` and, in
   sequential mode, blocked the whole downstream stack. The same aggregator passes
   in isolation on master and on the branch. ci-checks runs the project's tests —
   a *deterministic* gate in principle, but real suites flake under load, and the
   gate has no tolerance for a one-off.
2. **A review-gate subprocess that exited with no verdict.** The review
   `claude -p` exited rc=1 with no parseable `REVIEW_RESULT:` line (observed cause:
   a `timeout … claude` exec failure — `claude` resolved via a volatile per-shell
   path). The runner recorded `review gate fatal exit … no fresh verdict (rc=1)`
   and marked the TDD `failed`. "Couldn't run the reviewer" is **couldn't-observe**,
   not "the code is wrong" — conflating them is the exact NFR-4 error
   [[0035]]/ADR 0006 already fixed for runtime-verify (`verify-unobservable`).

This TDD makes both modes honest and non-fatal:
- **ci-checks retry-once.** On a ci-checks failure the gate re-runs the checks
  ONE more time (configurable) before declaring FAIL; a pass on retry is recorded
  as a recovered flake (with a telemetry note), a second failure is a real FAIL.
  Re-observing — never guessing — keeps it ADR-0006-honest.
- **No-verdict → couldn't-observe.** A review/verify gate subprocess that exits
  with NO parseable verdict (crash, exec failure, empty output) is classified
  `gate-unobservable` — a recoverable, non-terminal halt distinct from an observed
  `REVIEW_RESULT: BLOCK` / `VERIFY_RUNTIME: FAIL`. It is surfaced as resumable so
  the gate is simply re-run, never recorded as a false terminal verdict.

ADR 0006 (verdicts grounded in artifacts — a missing verdict is the absence of an
artifact, so it cannot be a verdict) and NFR-4 (never conflate couldn't-observe
with observed-wrong) are the governing constraints. ADR 0007's halt model is
unchanged: a real `BLOCK`/`FAIL` still drives bounded rework exactly as today.

## Components & interfaces

### 1. ci-checks retry-once — `scripts/lib/gates.sh`

The retry lives INSIDE the `run_ci_checks` wrapper (currently
`bash "$CI_CHECKS" >>"$1" 2>&1`), NOT at the `gate_one` call site — so the gate
stays a single function call and the call site is unchanged. On a non-zero exit,
`run_ci_checks` re-runs `ci-checks.sh` up to `THROUGHLINE_CI_CHECKS_RETRIES`
(default `1`) more times. The FIRST passing run wins (PASS); only when the initial run AND all
retries fail is it a real ci-checks FAIL. Each attempt's pass/fail is logged; a
"passed on retry N (initial run flaked)" telemetry line is written to the gate
log and the fragment note so a recovered flake is visible, not silent (NFR-4:
honest about the recovery). Retries are sequential, same worktree, no parallelism.
`THROUGHLINE_CI_CHECKS_RETRIES=0` restores the no-retry behavior (an escape hatch
for a deterministic-suite project).

### 2. No-verdict classification — `scripts/lib/gates.sh`

The review gate (the `claude -p` review subprocess driven inside `_rework_loop`)
and the runtime-verify gate already parse a verdict line out of the subprocess
output. Today the no-verdict crash path in `_rework_loop` (the
`review gate fatal exit … no fresh verdict (rc=1)` case) calls
`_terminal_state "$slug" failed ""`, writing **`status:failed`,
`halt_cause:null`**. Change: a gate subprocess that exits leaving **no parseable
verdict line** (no `REVIEW_RESULT:` / no `VERIFY_RUNTIME:`), REGARDLESS of exit
code, is classified `gate-unobservable`:

- **The existing `_terminal_state "$slug" failed ""` call on the no-verdict path
  is REPLACED (not supplemented) with `set_halt_cause "$slug" gate-unobservable
  "<gate>" "<detail>"` followed by `_terminal_state "$slug" blocked "" "<note>"`,
  in that order**, so the fragment ends at **`status:blocked`** (NOT `failed`).
  The `blocked` status is load-bearing: `_resume_from`'s blocked-resume arm only
  accepts `status:blocked` fragments whose `halt_next_actions` begins with
  `resume` — a `failed` fragment is never picked up. Leaving the old `failed`
  write in place would defeat the entire feature.
- `set_halt_cause` double-writes `halt_cause` + `halt_next_actions` from
  `_next_actions_for_cause` (state.sh); Component 3 adds `gate-unobservable` to
  that map with a `resume`-first action list, so the resulting blocked fragment is
  AUTOMATICALLY resumable via the existing blocked-resume arm ([[0039]]'s
  `--recover` is NOT required — a no-verdict gate is genuinely couldn't-observe,
  so re-running it is safe and needs no operator intent).
- `halt_cause_detail` names which gate (`review` / `verify-runtime`) and the
  captured stderr tail (e.g. the `timeout … No such file or directory` exec error)
  so the operator can see WHY the gate couldn't run.

This mirrors [[0035]]'s `verify-unobservable` exactly: a closed-enum cause, a
status-render mirror, and an `halt_next_actions` resume entry. An *observed*
`REVIEW_RESULT: BLOCK` / `VERIFY_RUNTIME: FAIL` is UNTOUCHED — it still drives
bounded rework / terminal FAIL as today. The discriminator is purely "did the
subprocess emit a parseable verdict?", a mechanical check on its output.

### 3. Enum + next-actions + status-render mirror — `scripts/lib/state.sh`, `scripts/status.sh`

Mirroring the `verify-unobservable` precedent (TDD 0035 §1), add `gate-unobservable`
to three places:
- the closed halt-cause enum (`state.sh`), so `set_halt_cause` accepts it;
- `_next_actions_for_cause` (`state.sh`) with a **`resume`-first** action list
  (e.g. `resume (re-runs the gate)`), so the blocked fragment Component 2 writes
  is automatically resumable via `_resume_from`'s blocked-resume arm and surfaced
  by `status.sh --check-paused` as `resumable=blocked`;
- `status.sh`'s `_halt_cause_known` set, so it renders without an "unknown cause"
  warning.
No schema change — a new enum value + its next-action mapping only.

## Data & state

No schema change. `gate-unobservable` is a new value in the existing closed
halt-cause enum (Component 3). The ci-checks retry telemetry is a log line + a
fragment `note` string (existing field). No new persisted field.

## Sequencing / implementation plan

1. **gates.sh — ci-checks retry**: wrap the ci-checks invocation in a
   retry-once loop (`THROUGHLINE_CI_CHECKS_RETRIES`, default 1); record a
   recovered-flake telemetry note on a retry pass (Component 1).
2. **state.sh + status.sh — enum**: add `gate-unobservable` to the closed enum
   and the status-render known-cause set (Component 3) — landed before Component 2
   uses it.
3. **gates.sh — no-verdict classification**: a review/verify subprocess that emits
   no parseable verdict records a `gate-unobservable` halt with a resume action +
   stderr-tail detail, instead of the generic fatal `failed` (Component 2).
4. **Eval** `tests/transient-gate-resilience.test.sh`: drive both paths with stub
   `ci-checks.sh` / stub gate subprocesses.
5. **Wire the eval into the aggregator** (`tests/implement-gate.test.sh`) in the
   SAME step.

## Failure modes & edge cases

- **ci-checks genuinely red (real regression)** → initial + retry both fail →
  real FAIL, no false PASS. Retry only *re-observes*; it never masks a
  reproducible failure.
- **ci-checks flaky in BOTH the initial and the retry** (rare double-flake) →
  recorded FAIL; the operator recovers via [[0039]]'s `--recover` (the residue
  retry-once doesn't catch). Retry-once bounds cost; it is not a retry-until-green
  loop (which could mask a 50%-flaky real failure — NFR-4).
- **A gate subprocess emits a verdict AND exits non-zero** → the verdict wins
  (it observed something); not reclassified `gate-unobservable`. The discriminator
  is verdict-presence, not exit code.
- **A gate subprocess emits a malformed/truncated verdict** → treated as
  no-parseable-verdict → `gate-unobservable` (couldn't-observe), never a guessed
  PASS/FAIL (NFR-4: ambiguity resolves to couldn't-observe, not a false verdict).
- **`gate-unobservable` re-run flakes again** → re-halts `gate-unobservable`
  (resumable again); bounded by the operator's patience, not an infinite loop
  inside one run (each resume is a fresh human-or-watcher-initiated launch).
- **`THROUGHLINE_CI_CHECKS_RETRIES` non-numeric** → default-and-warn (mirrors the
  `THROUGHLINE_WATCH_MAX_SECS` validation pattern).

## Verification plan

**Observable surface:** the ci-checks gate's PASS/FAIL outcome + its telemetry
log/note; the review/verify gate's recorded halt (`gate-unobservable` vs
`failed`) + its `halt_next_actions`; `status.sh` rendering of the new cause.

**Observation points** (driven by `tests/transient-gate-resilience.test.sh` with
stub `ci-checks.sh` and stub gate subprocesses via the existing gate test
harness):

1. **ci-checks flaky-then-green → PASS.** Stub `ci-checks.sh` fails on its first
   invocation and passes on the second (e.g. keyed off a counter file). With
   `THROUGHLINE_CI_CHECKS_RETRIES=1`: the gate PASSES, and the gate log/note
   records "passed on retry (initial flaked)". With `RETRIES=0`: the same stub
   FAILS (no retry) — confirms the knob governs it.
2. **ci-checks red-twice → FAIL.** Stub fails both initial and retry → real
   ci-checks FAIL (terminal verify-FAIL as today). No false PASS.
3. **Review no-verdict → gate-unobservable, resumable.** Stub review subprocess
   exits rc=1 emitting NO `REVIEW_RESULT:` line (and a stderr line mimicking the
   `timeout … No such file` exec error). Observe: the fragment records
   `halt_cause=gate-unobservable` (NOT `failed`/`null`), `halt_cause_detail` names
   `review` + the stderr tail, and `halt_next_actions` begins with a `resume`
   action.
4. **Verify no-verdict → gate-unobservable.** Same for a runtime-verify subprocess
   that exits with no `VERIFY_RUNTIME:` line → `gate-unobservable` (gate=verify-runtime).
5. **Observed BLOCK untouched.** A review subprocess that DOES emit
   `REVIEW_RESULT: BLOCK …` still drives the bounded-rework path (not reclassified
   `gate-unobservable`) — confirms the discriminator is verdict-presence.
6. **Status render.** `status.sh` renders a `gate-unobservable` fragment without
   an "unknown cause" warning (the `_halt_cause_known` mirror), and
   `--check-paused` surfaces it `resumable=blocked` (it has a resume action).

**Mechanical-check robustness (binding — L-001/L-002):** absence assertions
distinguish grep exit 1 vs ≥2 and fail on unreadable; every target file asserted
readable before content checks; stub subprocess exit codes + outputs are explicit
fixtures (no reliance on real `claude`); fragment seeds are compact single-line
JSON. No real timing/process races (stubs are deterministic).

**Expected observations (PASS):** every numbered point yields the cited result.

## Evaluation rubric

| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | every in-scope FR/NFR maps to a named component + verification point | maps with minor gaps noted | an in-scope requirement is untraced |
| Interface concreteness | exact knob names, the verdict-presence discriminator, and the new enum value named | named with one ambiguity | "retry on failure" hand-waving |
| Alternatives analysis | ≥1 concrete rejected alternative with reason for each design choice | one named alternative | "none considered" |
| Verification-plan actionability | each point names a stub setup, an action, and an expected observation a test can assert | mostly actionable | no observable surface / observation point named |
| Scope-bound adherence | within declared touched-files + per-file diff bounds, honestly estimated | within bounds, estimate loose | blows a bound with no exception |
| Naming consistency | one name per concept (`gate-unobservable`, `THROUGHLINE_CI_CHECKS_RETRIES`) across the TDD | minor drift | same concept two names |

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-15 (gap-closure: gate (b) ci-checks runs the suite/typecheck/linter; a transient suite flake must not be read as a failing gate) | Component 1 (retry-once re-observes before declaring FAIL; a recovered flake is logged, not silent). Verification §1, §2. |
| FR-57 (gap-closure: the review gate's verdict governs the flip; a gate that could not produce a verdict has not governed anything) | Component 2 (no parseable verdict → `gate-unobservable`, resumable, never a false terminal `failed`). Verification §3, §4, §5. |
| NFR-4 (never conflate couldn't-observe with observed-wrong) | Components 1+2: retry re-observes (no guess); a missing verdict is couldn't-observe, distinct from an observed BLOCK/FAIL; a malformed verdict resolves to couldn't-observe, not a guessed verdict. Verification §2, §3, §5. |

No gaps.

## Dependencies considered

No new external dependency — changes are in the existing bash runner
(`lib/gates.sh`, `lib/state.sh`, `status.sh`). The retry reuses the existing
`ci-checks.sh`; the no-verdict classification reuses the existing verdict parser.

Alternatives considered:
- **Retry ci-checks until green** — rejected: masks a 50%-flaky *real* failure;
  bounded retry-once re-observes a one-off without hiding a reproducible fault
  (NFR-4).
- **Treat any non-zero gate-subprocess exit as transient** — rejected: an
  *observed* `REVIEW_RESULT: BLOCK` can accompany a non-zero exit; keying off
  verdict-presence (not exit code) keeps observed verdicts authoritative
  (ADR 0006).
- **Pin `claude` to an absolute path in the runner** — rejected as the fix here:
  it addresses only one cause of a no-verdict exit (the exec-path issue) and is an
  environment concern, not a gate-honesty one; the `gate-unobservable`
  classification is robust to ALL no-verdict causes (crash, OOM, empty output).
  (A stable-`claude`-resolution hardening may be a separate small change; out of
  scope here.)

## PRD conflicts surfaced (and resolution)

None. FR-15 (gate (b) ci-checks runs the suite) and FR-57 (review governs the
flip) are both honored more faithfully: a transient inability to run a check is no
longer mis-recorded as a failing check. NFR-4 is strengthened. The
`docs/tdd/BLOCKERS.md` "0036 … rework-budget-exhausted" entry and the 0037
ci-checks failure in the same run are instances of the flake class Component 1
addresses.

## Decisions to promote (ADR candidates)

None. The no-verdict-is-couldn't-observe rule is a direct application of ADR 0006
(grounded verdicts) and the existing `verify-unobservable` precedent (TDD 0035);
no new cross-cutting decision. (If a future change broadens couldn't-observe
handling across more gates, consolidating it into an ADR may be warranted — not
yet.)

## Touched files

- `scripts/lib/gates.sh` — ci-checks retry-once loop + no-verdict `gate-unobservable` classification for the review/verify subprocesses.
- `scripts/lib/state.sh` — add `gate-unobservable` to the closed halt-cause enum AND to `_next_actions_for_cause` (resume-first action list).
- `scripts/status.sh` — add `gate-unobservable` to `_halt_cause_known` (render mirror).
- `tests/transient-gate-resilience.test.sh` — new eval (stub ci-checks + stub gate subprocesses).
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Total: 5 files touched.

## Expected diff size

- `scripts/lib/gates.sh` — ~55 lines (retry loop ~25 + no-verdict classification → blocked+gate-unobservable ~30).
- `scripts/lib/state.sh` — ~12 lines (enum entry + `_next_actions_for_cause` resume mapping).
- `scripts/status.sh` — ~4 lines (known-cause mirror).
- `tests/transient-gate-resilience.test.sh` — ~165 lines (6 cases with explicit stub fixtures, fail-closed assertions, file-readable guards).
- `tests/implement-gate.test.sh` — ~12 lines (aggregator wire-in).

Total expected diff: ~242 lines across 5 files. No exceptions needed (each file is under the 300-line per-file bound).

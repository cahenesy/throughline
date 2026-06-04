# TDD 0035: Resumable runtime-verify "couldn't observe" halt — revise the verification plan, resume just the verify gate

Status: draft
PRD refs: FR-40, FR-41, FR-63, FR-64 (gap-closure); NFR-4
PRD-rev: d289607
ADR constraints: 0004, 0005, 0007

## Approach

A runtime-verify gate that ends `VERIFY_RUNTIME: BLOCKED` ("couldn't observe" —
distinct from `FAIL` "observed and wrong", per NFR-4) is recorded as a plain
terminal blocked state: `gate_one` calls `_terminal_state "$slug" blocked` with
no `halt_cause` and an empty `halt_next_actions` (`resume.sh`). That halt has no
resume affordance — `_resume_from` only accepts a `paused` fragment or a
`blocked` fragment whose `halt_next_actions` begins with a resume action — so the
only way to re-attempt the TDD is a full rebuild, even when the *only* defect is
the TDD's verification plan (e.g. it told the headless gate to drive an
interactive `AskUserQuestion` session it cannot complete; the fix is a
plan-only edit declaring that observation `SKIP`).

This happened in practice (TDD 0029): a clean build — all mechanical checks and
every other behavioral observation passing — was blocked solely because one
verification point was not headlessly observable. The verification-plan revision
was a doc-only change, yet the runner offered only a rebuild; the build was
preserved by manual run-state surgery (adding a resume action) plus a manual
integration merge.

This TDD productizes that recovery by mirroring the structural-finding resume
(TDD 0031): the couldn't-observe halt is recorded as a *resumable* blocked halt
with a new `verify-unobservable` cause, a resume action, and a `tdd_rev`
fingerprint of the TDD (the verification plan lives in the TDD). On `--resume`
the runner refuses if the plan is unrevised (`resume-blocked-verify-plan-
unrevised`), and otherwise accepts — and **composes with TDD 0033** (integration
merge on all resume paths) to bring the revised plan into the build branch, then
re-runs only the runtime-verify gate (build / test-first / ci-checks already
recorded complete in `gates_completed`), followed by review and flip.

`FAIL` (observed and wrong) is unaffected: it is a genuine defect and stays a
fatal, non-resumable failure (FR-16/17). Only the `BLOCKED` couldn't-observe
verdict becomes resumable-after-revision.

This respects ADR 0004 (verification remains observation at the surface — the
revised plan is what the gate re-drives; the mechanism is unchanged), ADR 0007
(this is a halt-taxonomy entry in the bounded-rework/structural-escalation model,
not a new model), and ADR 0005 (the resume decision is a mechanical read of the
fragment's recorded cause + `tdd_rev` vs the integration blob, not a sandbox).

## Components & interfaces

### 1. Closed halt-cause enum + cause→next-actions — `scripts/lib/state.sh`

`set_halt_cause`'s closed FR-63 enum (the `case` that validates a cause and the
cause→next-actions map, and the resumable/paused classifier) gains
`verify-unobservable`:
- **Enum membership:** `verify-unobservable` is accepted by `set_halt_cause`
  (currently it would be rejected as "unknown halt cause").
- **Next-actions mapping:** maps to a list whose FIRST element is a resume
  action, e.g. `resume (re-run runtime-verify against the revised verification
  plan),revise the TDD's ## Verification plan via /tdd-author`. The leading
  `resume` token is what `_resume_from` and `status.sh --check-paused` key on
  (the same contract structural-finding and rework-scope-exceeded use).
- **Resumable/paused classifier:** the helper that marks a cause
  recoverable/paused (the one that returns 0 for
  `resume-blocked-integration-conflict`) returns 0 for `verify-unobservable`,
  so `status.sh` renders it as a known resumable cause without the unknown-cause
  warning (FR-64 one-screen halt context).

### 2. Halt recording at the gate — `scripts/lib/resume.sh` (`gate_one`)

The runtime-verify `*BLOCKED*` arm in `gate_one` is changed from
`_terminal_state "$slug" blocked "" "runtime-verify BLOCKED (couldn't observe)"`
to record a *resumable* halt:
- `set_halt_cause "$slug" verify-unobservable "verify-runtime" "tdd_rev=<blob>"`
  where `<blob>` is `git rev-parse --verify HEAD:<tdd-path>` on the build
  branch at halt time — the same fingerprint shape structural-finding records,
  so the resume guard can compare it to the integration copy.
- The fragment keeps `status=blocked` (the resume action is what makes it
  resumable; this matches the structural-finding shape and keeps the
  build/test-first/verify entries in `gates_completed` intact for the resumed
  `gate_one` to skip). The gate still returns non-zero (the TDD is not flipped).

### 3. Resume acceptance arm — `scripts/lib/resume.sh` (`_resume_from`)

`_resume_from`'s blocked-with-resume-action branch gains a `verify-unobservable`
sub-arm mirroring the existing `structural-finding` sub-arm:
- Read `halt_cause`; when it is `verify-unobservable`, read the recorded
  `tdd_rev=` from `halt_cause_detail` and compare to the integration copy's blob
  (`git rev-parse --verify --quiet "$INTEGRATION:<path>"`).
- **Unrevised** (recorded blob == integration blob): refuse with
  `RESUME_REFUSE_CAUSE=resume-blocked-verify-plan-unrevised`, persist nothing
  (the fragment stays blocked/verify-unobservable so a later, post-revision
  resume still works) — the exact write-nothing contract structural's
  `resume-blocked-tdd-unrevised` uses.
- **Revised** (blobs differ, or fingerprint unresolvable → accept-with-warning,
  same degraded path as structural): accept — flip blocked→paused/transient via
  the existing `_accept_blocked_as_paused`, then fall through to the shared
  validation. Bringing the revised plan into the build branch is the integration
  merge of **TDD 0033** (merge on all accepted resume paths); this TDD relies on
  that merge rather than duplicating it (see Dependencies). The resumed
  `gate_one` then skips the gates in `gates_completed` (`build`, `test-first`,
  and `verify` — where `verify` is the ci-checks gate stage, distinct from the
  `verify-runtime` runtime-verify gate that BLOCKED and is therefore NOT in
  `gates_completed`) and re-runs `verify-runtime` against the merged, revised
  plan → review → flip.

`resume-blocked-verify-plan-unrevised` is a transient driver-report-only refusal
cause (like `resume-blocked-tdd-unrevised`): it is surfaced on the runner's
`refuse-to-resume:` line and is NOT persisted to the closed-enum
`paused_cause` (it must not need enum membership; it is a refusal signal, not a
recorded halt state).

### 4. Interactive surfacing — `skills/implement/SKILL.md`

The "Detect interrupted run" section's list of resumable `resumable=blocked`
causes gains `verify-unobservable`: a couldn't-observe halt is offerable for
Resume, with the precondition that the TDD's `## Verification plan` has been
revised and merged to integration (mirroring the structural-finding entry's
"requires the resolving TDD revision merged first" note). On `--resume` the
runner re-checks and refuses `resume-blocked-verify-plan-unrevised` if the plan
is unrevised.

## Data & state

No new run-state schema. `verify-unobservable` reuses the existing
`halt_cause` / `halt_next_actions` / `halt_cause_detail` fields (the
`tdd_rev=` detail convention is shared with structural-finding). The only schema
surface that grows is the closed cause enum's membership set (Component 1), which
is a value addition, not a structural change. `resume-blocked-verify-plan-
unrevised` is a transient `RESUME_REFUSE_CAUSE` value, never persisted to the
fragment.

## Sequencing / implementation plan

1. **state.sh**: add `verify-unobservable` to the closed enum, its
   cause→next-actions (leading `resume` action), and the resumable-cause
   classifier (Component 1).
2. **resume.sh — recording**: change `gate_one`'s runtime-verify `*BLOCKED*` arm
   to `set_halt_cause verify-unobservable` with the `tdd_rev=` fingerprint
   (Component 2).
3. **resume.sh — acceptance**: add the `verify-unobservable` sub-arm in
   `_resume_from` with the verify-plan-unrevised guard (Component 3).
4. **skills/implement/SKILL.md**: document the resumable cause + its
   plan-revised precondition (Component 4).
5. **Eval**: add `tests/runtime-verify-resume.test.sh` covering recording,
   check-paused surfacing, the unrevised refusal, the revised acceptance, and the
   enum/render.
6. **Wire the eval into the aggregator (do NOT defer):** add the
   `tests/runtime-verify-resume.test.sh` invocation to
   `tests/implement-gate.test.sh` in the SAME step (`*_FAIL` accumulator +
   conditional run + final-expression AND), so the eval is regression-gated by
   ci-checks, not orphaned.

**Build-order dependency:** this TDD composes with TDD 0033 (integration merge on
all resume paths). It must build AFTER 0033 is merged to integration so the
acceptance arm can rely on 0033's merge to bring the revised plan into the build
branch. Numeric order (0035 > 0033) plus the "merged = buildable" rule produce
this naturally; if 0033 is somehow not yet merged at build time, the build should
BLOCK as a design dependency rather than duplicate 0033's merge logic.

## Failure modes & edge cases

- **Plan revised but the revision did not fix observability.** The resumed
  runtime-verify re-runs and may BLOCK couldn't-observe again — re-recording a
  fresh `verify-unobservable` halt with the new `tdd_rev`. This is correct: each
  revision gets one re-verify; a pointless resume (no real fix) costs one gate
  run, not an unbounded loop, and the next unrevised-guard catches a no-op
  re-resume.
- **`FAIL` (observed and wrong), not BLOCKED.** Untouched — `gate_one`'s
  `*FAIL*`/ambiguous path stays the fatal failure pathway (FR-16/17); only the
  explicit `BLOCKED` couldn't-observe verdict is made resumable. A missing or
  malformed verdict still resolves to FAIL, never to a resumable BLOCKED (NFR-4).
- **`tdd_rev` fingerprint unresolvable** (build branch or path missing). Mirror
  structural's degraded path: accept with a stderr warning rather than refuse —
  a bounded re-verify limits a pointless resume.
- **`THROUGHLINE_REQUIRE_RUNTIME_VERIFY=0`.** The gate is skipped entirely, so no
  couldn't-observe halt is produced; no interaction with this TDD.
- **0033 not yet merged at build time.** BLOCK as a design dependency (see
  build-order note) — do not duplicate the integration merge.

## Verification plan

**Observable surface:** the per-TDD fragment's `halt_cause` /
`halt_next_actions` / `halt_cause_detail` after a runtime-verify couldn't-observe
halt; `status.sh --check-paused` output; `_resume_from`'s return code +
`RESUME_REFUSE_CAUSE`; the build branch git history after an accepted resume;
`skills/implement/SKILL.md` text.

**Observation points** (driven by `tests/runtime-verify-resume.test.sh` with
fixture repos + a stub runtime-verify command + a stub-`git` shim where needed,
following the fixture pattern of
`tests/honest-review-scope-structural-resume.test.sh`):

1. **Halt records resumable.** A stub runtime-verify gate emitting
   `VERIFY_RUNTIME: BLOCKED` → the fragment has `halt_cause=verify-unobservable`,
   a `halt_next_actions` whose first element begins with `resume`, and
   `halt_cause_detail` containing `tdd_rev=<40-hex>` — NOT a plain terminal
   blocked with null halt_cause.
2. **check-paused surfaces it.** `status.sh --check-paused` prints a line for the
   slug with `cause=verify-unobservable resumable=blocked`, and `status.sh`
   renders the halt without an unknown-cause warning.
3. **Unrevised → refuse.** `_resume_from` with the integration copy of the TDD
   byte-identical to the recorded `tdd_rev` → returns 3,
   `RESUME_REFUSE_CAUSE=resume-blocked-verify-plan-unrevised`, the fragment
   remains `blocked`/`verify-unobservable` (nothing persisted), and the build
   branch gains no merge commit.
4. **Revised → accept.** Integration's TDD differs from the recorded `tdd_rev`
   (verification plan revised) → `_resume_from` returns 0 and flips the fragment to
   paused/transient. Because this TDD builds after 0033 is merged (build-order
   dependency), the integration-merge-on-resume is live, so the build branch
   carries the merge commit bringing the revised plan in; the resumed `gate_one`
   skips `build`/`test-first`/`verify` (recorded in `gates_completed`) and
   re-enters at `verify-runtime`. The test drives this against the real merged
   `resume.sh` (not a stubbed merge): the fixture sets an integration branch that
   advanced the TDD's verification plan after the build branch forked, and asserts
   both the acceptance (rc 0) and the resulting merge commit — the same fixture
   shape `tests/integration-merge-on-resume.test.sh` (TDD 0033) uses.
5. **Enum membership.** `set_halt_cause <slug> verify-unobservable` returns 0 and
   writes the cause (a value NOT in the enum still returns 1, proving the
   addition is what admits it).
6. **SKILL.md documents it.** Grep `skills/implement/SKILL.md` for
   `verify-unobservable` and its plan-revised resume precondition.

**Expected observations (PASS):** every numbered point yields the cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-40 (gate-level resume: completed gates not re-run) | Components 2+3: the resumed `gate_one` re-runs only `verify-runtime`; build/test-first/verify stay in `gates_completed` and are skipped. Verification §4. |
| FR-41 (recoverable-cause classification: recoverable halts are resumable, fatal are not) | Components 1+2: `verify-unobservable` (couldn't observe) is a recoverable, resumable cause; `FAIL` (observed and wrong) stays fatal. Verification §1, §3, §4; failure-modes (FAIL untouched). |
| FR-63 (closed halt-taxonomy enum; every halt cites an enumerated cause) | Component 1: `verify-unobservable` added to the closed enum with a deterministic next-actions mapping. Verification §5. |
| FR-64 (one-screen halt context; known causes render without warning) | Component 1 classifier + Component 4 SKILL.md: the cause renders as a known resumable cause with named next actions. Verification §2, §6. |
| NFR-4 (verdict honesty: couldn't-observe ≠ observed-wrong) | Approach + failure modes: only `BLOCKED` becomes resumable; `FAIL`/ambiguous stays fatal, never a false resumable PASS. Verification §1; failure-modes. |

No gaps.

## Dependencies considered

No new external dependency. One internal design dependency: **TDD 0033**
(integration merge on all resume paths) supplies the merge that brings the
revised verification plan into the build branch on an accepted resume.

Alternatives considered:
- **Duplicate the integration merge inside this TDD's acceptance arm** —
  rejected: it would re-implement TDD 0033's merge + conflict-refusal for one
  halt path, duplicating logic and risking divergence from 0033's behavior. The
  user-approved choice is to compose with 0033; the only cost is a build-order
  dependency, which numeric ordering already enforces.
- **Make the couldn't-observe halt resumable WITHOUT a tdd_rev guard** (always
  re-verify on resume) — rejected: a resume with no revision would re-run the
  gate against the same plan and BLOCK identically, burning a gate run each time.
  The `tdd_rev` guard (mirroring structural's tdd-unrevised) refuses a pointless
  resume cheaply, matching the established pattern.
- **Auto-rewrite the verification plan to `SKIP` the unobservable point** —
  rejected: deciding an observation is genuinely un-observable (vs the build
  being wrong) is a design judgment for `/tdd-author` + the human merge gate, not
  something the runner should infer and self-apply (ADR 0006: the runner acts on
  artifacts, it does not author them).

## PRD conflicts surfaced (and resolution)

None. FR-40/41 already require resume to continue at the first incomplete gate
and to distinguish recoverable from fatal causes; this TDD closes the gap that
the couldn't-observe cause was never wired as recoverable. No requirement is
contradicted.

## Decisions to promote (ADR candidates)

None. This is a halt-taxonomy entry within the established model (ADR 0007),
mirroring an existing pattern (TDD 0031); it introduces no new cross-cutting
decision.

## Touched files

- `scripts/lib/state.sh` — add `verify-unobservable` to the closed halt-cause enum, its cause→next-actions (resume action), and the resumable-cause classifier.
- `scripts/lib/resume.sh` — record the runtime-verify couldn't-observe halt as resumable (Component 2) and add the `_resume_from` acceptance arm + verify-plan-unrevised guard (Component 3).
- `skills/implement/SKILL.md` — document `verify-unobservable` as a resumable cause with its plan-revised precondition.
- `tests/runtime-verify-resume.test.sh` — new eval (recording, check-paused, unrevised refusal, revised acceptance, enum/render).
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Total: 5 files touched.

## Expected diff size

- `scripts/lib/state.sh` — ~14 lines added (enum case + next-actions map entry + resumable classifier entry).
- `scripts/lib/resume.sh` — ~48 lines added/changed (the BLOCKED-arm recording change + the `_resume_from` verify-unobservable sub-arm with the unrevised guard, modeled on the structural-finding sub-arm).
- `skills/implement/SKILL.md` — ~14 lines added (resumable-cause documentation + precondition).
- `tests/runtime-verify-resume.test.sh` — ~210 lines added (new eval: 6 fixture-driven observation points with per-assertion ok/bad reporting and fail-closed guards).
- `tests/implement-gate.test.sh` — ~14 lines added (aggregator wire-in).

Total expected diff: ~300 lines across 5 files. No exceptions needed (each file is at or under the 300-line per-file bound; the eval at ~210 is the largest single file).

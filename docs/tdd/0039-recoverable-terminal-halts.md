# TDD 0039: Opt-in recovery from non-structural terminal halts — resume without state surgery

Status: implemented
PRD refs: FR-39 (gap-closure); FR-40; NFR-4
PRD-rev: d289607
ADR constraints: 0004, 0005, 0007

## Approach

Today only three halt classes are resumable (`_resume_from` in
`scripts/lib/resume.sh`): a `paused` fragment, a `blocked` fragment whose
`halt_next_actions` begins with a `resume` action (structural-finding,
rework-scope-exceeded), and an orphaned `building/verifying/reviewing` fragment.
Two *terminal* halt classes that are commonly **artifacts** — `rework-budget-exhausted`
(`status:blocked`, `halt_cause:rework-budget-exhausted`) and a ci-checks
`failed` (`status:failed`, `halt_cause:null`, note `ci-checks.sh FAIL`) — have no
resume path: their `halt_next_actions` is "fresh /implement after revision",
i.e. **rebuild from scratch**, discarding build/gate work already shipped and
reviewed. The only recovery observed in practice (run 20260608-011142) was
hand-editing the state fragment, which is both undocumented and a footgun (a
non-compact JSON edit is silently misread — see [[0042]]/issue, deferred).

This TDD adds a **deliberately opt-in** recovery path so a human who has judged a
terminal halt to be an artifact can resume from the last good gate WITHOUT
surgery, while preserving NFR-4 honesty: terminal-by-default stays terminal, and
recovery requires an explicit `--recover` intent (never automatic — an automatic
retry would silently mask a genuinely failing build).

Three coordinated changes:
1. **`--recover` flag** on `/implement` (sets `RECOVER=1`), only meaningful with
   `--resume`.
2. **`_resume_from` recovery arms** that, under `RECOVER=1`, accept
   `rework-budget-exhausted` (extending the rework budget) and ci-checks `failed`
   (re-entering at the verify gate). Without `--recover` these stay terminal.
3. **Divergence-guard recovery (FR-40 gap):** a recovery resume derives
   `branch_head_at_pause` from the **current branch ref** rather than a possibly
   stale recorded value, so a build branch that legitimately advanced (the rework
   commits that shipped before the halt) is not refused
   `resume-blocked-branch-divergence`.

This respects ADR 0007 (no change to the halt *model* — bounded rework +
structural escalation are untouched; this is a recovery affordance for halts the
model already produced), ADR 0005 (the gates are unchanged; recovery re-enters
existing gates), and ADR 0004 (verification gates untouched).

## Components & interfaces

### 1. `--recover` flag — `scripts/implement.sh`

Parse `--recover` in the argument loop (next to `--resume`): set `RECOVER=1`
(default 0) and `export RECOVER`. `--recover` implies `--resume` — if `--recover`
is passed without `--resume`, set `RESUME=1` too and log a one-line note. Recovery
is meaningless without a prior run: if the implied resume reaches the existing
no-prior-run condition (no `latest` symlink / missing `state.d/run.json`), emit a
recover-specific diagnostic — `--recover requires a prior run to recover; none
found` — and exit non-zero, rather than the generic resume FATAL, so the operator
gets an actionable message. The watcher (`implement-watch.sh`) already forwards
`"$@"` verbatim, so no watcher change is needed.

### 2. Recovery acceptance arms — `scripts/lib/resume.sh`

In `_resume_from`, after the existing `paused`/blocked-resume/orphaned arms and
BEFORE the final `else return 0`, add two recovery arms guarded by
`[ "${RECOVER:-0}" -eq 1 ]`:

- **`rework-budget-exhausted`** (`status:blocked`, `halt_cause:rework-budget-exhausted`):
  accept via the same atomic `_accept_blocked_as_paused` flip used by the
  structural arm, THEN reset the per-(gate,step) rework counter so the budget is
  fresh: `_reset_rework_attempts "$slug"` (Component 4). Falls through to the
  shared integration merge + branch-derivation below.
- **ci-checks `failed`** (`status:failed`, note matches `ci-checks` and
  `gates_completed` includes `build` + `test-first` but NOT `verify`): accept via
  the same flip; re-entry is governed by `gates_completed` (verify absent → the
  verify/ci-checks gate re-runs), so no extra wiring is needed. A `failed`
  fragment whose note is NOT a ci-checks failure (e.g. a review-gate fatal exit —
  [[0040]] reclassifies that one) is NOT accepted here.

Both arms set `RESUME_RECOVER_CAUSE` for the driver's report line. A
`rework-budget-exhausted`/`failed` fragment WITHOUT `--recover` falls through to
`else return 0` exactly as today (terminal).

### 3. Divergence-guard recovery — `scripts/lib/resume.sh`

The divergence guard has two outcomes today: if the recorded `branch_head_at_pause`
is an ANCESTOR of the live branch HEAD it fast-forwards and accepts; if it is a
NON-ANCESTOR (the recorded SHA is no longer on the branch — e.g. rework hard-reset
an overrunning commit, or an integration merge rewrote history) it REFUSES
`resume-blocked-branch-divergence`. On a recovery resume the branch has
legitimately advanced and may have been rewritten by exactly those mechanisms, so
the recorded head can be a non-ancestor → spurious refusal. Fix: when `RECOVER=1`
(and ONLY then), **bypass the non-ancestor refusal specifically** by re-baselining
`branch_head_at_pause` to the live branch tip (the same FR-40 "branch history is
ground truth" principle the orphaned arm applies when the field is null). The
existing fast-forward arm is UNCHANGED (it already accepts the ancestor case
without `--recover`); only the refusal is relaxed, and only under explicit
recover intent. The integration merge (TDD 0033, on every accepted resume) still
brings current integration in and still refuses on a real merge conflict — so
recovery re-baselines the branch's OWN history but never silences an
integration-vs-branch conflict.

### 4. Budget-reset helper — `scripts/lib/state.sh`

`_reset_rework_attempts <slug>`: rewrite BOTH the fragment's `rework_attempts`
AND its `re_review_attempts` to `{}` via the same atomic-write path as the other
state mutators (compact single-line JSON — the readers are line-oriented). Both
are reset because a budget-exhausted recovery wants a genuinely fresh review
budget: the `re_review_attempts` coverage-retry counter (TDD 0021) is independent
of `rework_attempts`, and leaving it exhausted would re-halt the recovered run on
the first review pass with an uncovered file — defeating the recovery. Used by
Component 2's budget-exhausted arm so the recovered run gets a fresh
`THROUGHLINE_REWORK_MAX` budget (the operator may also raise
`THROUGHLINE_REWORK_MAX` at launch). Error-checked: a write failure returns
non-zero so `_resume_from` refuses the recovery
(`RESUME_REFUSE_CAUSE=resume-recover-state-write-failed`) rather than resuming
with an un-reset budget.

### 5. Surface + document — `scripts/status.sh`, `skills/implement/SKILL.md`

- `status.sh --check-paused`: emit a `resumable=recoverable cause=<halt_cause>`
  line for a `rework-budget-exhausted` blocked fragment and for a ci-checks
  `failed` fragment, DISTINCT from the existing `resumable=blocked`/`orphaned`
  markers so the skill (and a human) can tell "needs explicit --recover" apart
  from an automatically-resumable halt. A `failed` fragment that is NOT a
  ci-checks failure is not surfaced (it stays human-routed).
- `SKILL.md` "Detect interrupted run": a `resumable=recoverable` line is offered
  as a THIRD option, **"Recover `<slug>` (re-run from `<gate>`; treats the halt
  as an artifact — bumps the rework budget / re-runs ci-checks)"**, whose launch
  line adds `--recover`. The option text states plainly that recovery assumes the
  halt was an artifact (a flake or a since-fixed estimate), so the human owns that
  judgement.

## Data & state

No schema change. `RESUME_RECOVER_CAUSE` is a driver-report-only shell variable
(never persisted, mirroring `RESUME_REFUSE_CAUSE`). `_reset_rework_attempts`
rewrites an existing field. The `resumable=recoverable` marker is a status.sh
output token, not stored.

## Sequencing / implementation plan

1. **implement.sh**: parse `--recover` → `RECOVER=1` (implies `--resume`); export.
2. **state.sh**: add `_reset_rework_attempts` (atomic compact write, error-checked).
3. **resume.sh**: add the two `RECOVER`-guarded acceptance arms (budget-exhausted
   resets the counter; ci-checks-failed re-enters at verify) + the divergence-guard
   re-baseline under `RECOVER=1`.
4. **status.sh**: emit `resumable=recoverable cause=<halt_cause>` for the two
   recoverable terminal classes under `--check-paused`.
5. **SKILL.md**: document `--recover` and add the "Recover" offer for a
   `resumable=recoverable` line.
6. **Eval** `tests/recoverable-terminal-halts.test.sh`: drive `_resume_from` and
   `status.sh --check-paused` against seeded fragments.
7. **Wire the eval into the aggregator** (`tests/implement-gate.test.sh`) in the
   SAME step.

## Failure modes & edge cases

- **`--recover` without a recoverable halt** → the recovery arms don't match;
  `_resume_from` proceeds as a normal resume (no-op recovery). No error.
- **`--recover` on a genuinely-failing build** → the operator's call; recovery
  re-runs the gate, which fails again (the failure re-halts honestly). Recovery
  never *suppresses* a verdict — it only re-enters the gate.
- **ci-checks `failed` whose cause was a real regression** → re-running ci-checks
  re-fails; no false PASS. Recovery is safe-by-construction (it re-observes).
- **Budget reset races a live runner** → recovery only runs at resume launch
  (single-run lock held), never against a live run.
- **`failed` fragment ambiguity** — a `failed` status can come from a ci-checks
  failure OR a review-gate fatal exit ([[0040]]). Component 2 accepts ONLY the
  ci-checks case (note + `gates_completed` discriminator); the review-fatal case
  is [[0040]]'s domain. If the discriminator is ambiguous (note absent), do NOT
  accept — refuse `resume-recover-cause-ambiguous` and leave the fragment
  terminal (NFR-4: never guess a recovery).
- **State-write failure during budget reset** → refuse the recovery
  (`resume-recover-state-write-failed`), fragment stays terminal — never a
  half-reset budget.

## Verification plan

**Observable surface:** `_resume_from`'s acceptance/refusal (its return code +
the fragment's resulting `status`/`rework_attempts`/`branch_head_at_pause`), and
`status.sh --check-paused` stdout lines, and the `SKILL.md` text.

**Observation points** (driven by `tests/recoverable-terminal-halts.test.sh`,
seeding fragments under a temp `state.d/` via the existing `_write_tdd_fragment`
test helper):

1. **Budget-exhausted, no `--recover` → terminal.** Seed `status:blocked`,
   `halt_cause:rework-budget-exhausted`. Run `_resume_from` with `RECOVER=0`.
   Observe: returns 0 (proceeds-normally / not accepted as resumable) and the
   fragment is NOT flipped to paused — i.e. terminal-by-default preserved.
2. **Budget-exhausted, `--recover` → accepted + budget reset.** Same seed, set
   `RECOVER=1`. Observe: the fragment is flipped to paused/transient AND
   `rework_attempts` is now `{}` (reset), so the re-entered review gets a fresh
   budget.
3. **ci-checks `failed`, `--recover` → re-enters at verify.** Seed
   `status:failed`, note `ci-checks.sh FAIL`, `gates_completed:[build,test-first]`.
   With `RECOVER=1`: accepted; with `RECOVER=0`: not accepted (terminal).
4. **Divergence-guard re-baseline.** Seed a recoverable fragment whose
   `branch_head_at_pause` is an OLD sha while the (fixture) branch ref points at a
   NEWER sha. With `RECOVER=1`: resume is accepted (no
   `resume-blocked-branch-divergence`). With `RECOVER=0` on the same divergence:
   the existing guard still refuses (the recovery re-baseline is gated on RECOVER).
5. **`--check-paused` surfacing.** `status.sh --check-paused` emits
   `resumable=recoverable cause=rework-budget-exhausted` for the budget seed and
   `cause=ci-checks` (or the recorded cause) for the ci-checks seed; a plain
   design-escalation `blocked` (halt_next_actions without `resume`) is NOT
   surfaced as recoverable.
6. **Ambiguous `failed` → not accepted.** Seed `status:failed` with no
   ci-checks note: `_resume_from` with `RECOVER=1` refuses
   (`resume-recover-cause-ambiguous`), fragment stays terminal.
7. **SKILL.md (mechanical).** Grep `skills/implement/SKILL.md` for the `--recover`
   flag, the "Recover" offer keyed off `resumable=recoverable`, and the explicit
   "treats the halt as an artifact" framing.

**Mechanical-check robustness (binding — L-001/L-002):** every absence/removal
assertion distinguishes grep exit 1 (absent) from ≥2 (unreadable) and fails on
the latter; every target file is asserted readable before its content checks; the
fragment seeds use compact single-line JSON (the readers are line-oriented); no
watcher/process is launched (this eval is pure function-level, no timing).

**Expected observations (PASS):** every numbered point yields the cited result.

## Evaluation rubric

| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | every in-scope FR/NFR maps to a named component + verification point | maps with minor gaps noted | an in-scope requirement is untraced |
| Interface concreteness | exact functions/flags/fragment fields + acceptance/refusal conditions named | named with one ambiguity | "handle recovery" hand-waving |
| Alternatives analysis | ≥1 concrete rejected alternative with reason for each design choice | one named alternative | "none considered" |
| Verification-plan actionability | each point names a seed, an action, and an expected observation a test can assert | mostly actionable | no observable surface / observation point named |
| Scope-bound adherence | within declared touched-files + per-file diff bounds, honestly estimated | within bounds, estimate loose | blows a bound with no exception |
| Naming consistency | one name per concept across the TDD (`RECOVER`, `resumable=recoverable`, `_reset_rework_attempts`) | minor drift | same concept two names |

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-39 (gap-closure: detached-run recovery — a terminal halt that is an artifact must have a recovery path that does not discard shipped/reviewed work) | Components 1+2 (`--recover` + the budget-exhausted / ci-checks-failed acceptance arms re-enter the last good gate). Verification §1–§3. |
| FR-40 (resume baseline derives from the branch's committed history) | Component 3 (divergence-guard re-baseline from the branch ref under RECOVER). Verification §4. |
| NFR-4 (verdict honesty: terminal-by-default stays terminal; recovery never masks a real failure) | Opt-in `--recover` gate (Components 1–2 require explicit intent); recovery re-OBSERVES (re-runs the gate), never suppresses a verdict; ambiguous `failed` is refused, not guessed. Verification §1, §3, §6. |

No gaps.

## Dependencies considered

No new external dependency — all changes are in the existing bash runner
(`implement.sh`, `lib/resume.sh`, `lib/state.sh`, `status.sh`) and the skill doc.

Alternatives considered:
- **Automatic resume of these halts (no flag)** — rejected: silently retries a
  genuinely-failing build, weakening the terminal-means-terminal honesty (NFR-4);
  the operator must own the "this was an artifact" judgement.
- **A separate `/implement-recover` skill/command** — rejected: duplicates the
  resume machinery and its lock/queue handling; a `--recover` modifier on the
  existing resume reuses all of it.
- **Auto-classifying a ci-checks failure as flaky** — rejected here: that is
  [[0040]]'s retry-once mechanism (re-observe, don't guess); 0039 is the *human-judged*
  recovery path for the residue 0040's retry doesn't catch.

## PRD conflicts surfaced (and resolution)

None. FR-39 requires detached-run recovery; the current design only offered
rebuild for these two halt classes, which discards shipped work — this closes
that gap without weakening NFR-4 (recovery is opt-in and re-observes). The
unchecked `docs/tdd/BLOCKERS.md` entry "0036 … rework-budget-exhausted" is a
direct instance: it motivated this design and 0041's budget accounting; it is
resolved by the live recovery of that run (and would not have required surgery
had `--recover` existed).

## Decisions to promote (ADR candidates)

None. A recovery affordance within the existing halt model (ADR 0007); no new
cross-cutting decision. (If a future TDD adds more recoverable causes, an ADR on
"which halts are operator-recoverable vs design-routed" may become warranted —
not yet.)

## Touched files

- `scripts/implement.sh` — parse `--recover` → `RECOVER=1` (implies `--resume`).
- `scripts/lib/resume.sh` — two `RECOVER`-guarded recovery arms + divergence-guard re-baseline under RECOVER.
- `scripts/lib/state.sh` — `_reset_rework_attempts` (atomic compact, error-checked).
- `scripts/status.sh` — `resumable=recoverable cause=<halt_cause>` for the two recoverable terminal classes.
- `skills/implement/SKILL.md` — document `--recover`; add the "Recover" offer.
- `tests/recoverable-terminal-halts.test.sh` — new eval (function-level resume/status seeds).
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Total: 7 files touched.

## Expected diff size

- `scripts/implement.sh` — ~10 lines (flag parse + implies-resume).
- `scripts/lib/resume.sh` — ~55 lines (two acceptance arms + divergence re-baseline).
- `scripts/lib/state.sh` — ~18 lines (`_reset_rework_attempts`).
- `scripts/status.sh` — ~16 lines (recoverable surfacing in `--check-paused`).
- `skills/implement/SKILL.md` — ~32 lines (flag docs + Recover offer).
- `tests/recoverable-terminal-halts.test.sh` — ~150 lines (7 seeded cases, fail-closed assertions, file-readable guards).
- `tests/implement-gate.test.sh` — ~12 lines (aggregator wire-in).

Total expected diff: ~293 lines across 7 files. No exceptions needed (each file is under the 300-line per-file bound).

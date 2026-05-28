# 0007. Halt model: bounded rework + structural escalation (not first-failure halt)
Status: accepted
Date: 2026-05-28
Scope: workflow / gate-architecture / halt-semantics

## Context

FR-16's halt-on-failure model had been: a gate failure halts the TDD's
build, the runner stops, and the user is asked to drive the next step.
The diagnosis of TDD 0011 (PR #36) showed this model was too brittle —
the review-fix loop required 11 manual fix iterations the user had to
drive between findings and convergence. The PRD's FR-15, FR-16, and the
new FR-61 / FR-62 / FR-65 / FR-67 sharpen the halt model: a gate halt
now means "halts after bounded rework exhausts," not "halts on first
failure"; and the runner is responsible for routing structurally-out-of-
scope findings to design escalation rather than attempting to fix them
in-iteration.

The PRD's FR-63 (closed enum of human-needed halt causes), FR-65 (per-
gate, per-step rework budget), FR-66 (bounded rework scope per attempt),
and FR-67 (structural-finding escalation, not local sweep) together
define a durable two-axis halt model: how many times the gate retries
(budget) and what kind of finding refuses to be retried at all
(structural). NFR-1's human control is preserved at phase boundaries
(PRD PR merge, design PR merge, implementation PR merge) and narrowed
inside a build to "informed of progress; not asked to drive between
findings and convergence."

Two enforcement approaches were available in principle:

- **First-failure halt (status quo before this ADR).** Every gate
  failure stops the runner; the user fixes manually and re-invokes.
  Simple, predictable; loses the cheap automatic-retry case (most review
  findings are local and Sonnet-tractable); externalizes work the
  runner could absorb.
- **Bounded rework + structural escalation.** Halting findings trigger
  an automatic rework attempt within the same `/implement` invocation,
  bounded by per-(gate, step) attempt count and per-attempt scope cap;
  findings classified as structural (touching files outside the TDD's
  declared scope, exceeding per-file bounds, or reviewer-tagged
  structural) skip rework entirely and route to design escalation
  (BLOCKERS.md). The user is involved only at exhaustion or escalation
  boundaries.

TDD 0019 implements the second approach pragmatically: rework runs on
Sonnet (cheaper, less prone to opportunistic refactoring than Opus);
per-(gate, step) attempt budget defaults to 3; scope cap is
`max(60, 3 × cited-finding-region-size)`; structural detection is
retrospective (FR-67(a), (b)) plus predictive (FR-67(c) reviewer tag);
all bounds are env-overridable. This ADR records that as a durable
architectural disposition so it doesn't drift in either direction.

This decision sits alongside ADR 0006 (gate verdicts grounded in
verifiable artifacts) and ADR 0005 (gate scope by prompt, not sandbox).
The bounded-rework model is meaningful only because every halt event
cites an artifact-reproducible cause (ADR 0006); structural escalation
respects scope declarations the design-critique gate already enforces
(ADR 0005 + TDD 0014).

## Decision

Treat **halt-on-finding** as a bounded-rework operation with structural
escalation, enforced by:

- **Per-(gate, step) attempt budget.** A halting finding triggers up to
  `THROUGHLINE_REWORK_MAX` rework attempts (default 3); on exceed, the
  TDD is BLOCKED with cause `rework-budget-exhausted` and a structured
  entry is appended to `docs/tdd/BLOCKERS.md`. The runner is finished
  with that TDD; the human takes over (revise TDD via `/tdd-author`,
  then fresh `/implement`).
- **Bounded scope per rework attempt.** Each rework commit faces a
  mechanical pre-pass: total diff ≤ `max(THROUGHLINE_REWORK_SCOPE_FLOOR,
  THROUGHLINE_REWORK_SCOPE_FACTOR × cited-finding-region-size)`; over-
  cap commits are hard-reset and recorded with `rework-scope-exceeded`.
  Defaults: floor 60 lines, factor 3.
- **Structural escalation, not in-iteration sweep.** Three OR'd
  structural criteria refuse rework entirely: (a) the rework commit
  touches files outside the TDD's `## Touched files` declaration
  (TDD 0014); (b) the rework commit exceeds the TDD's
  `## Expected diff size` declaration for an affected file; (c) the
  reviewer explicitly tagged the finding with `structural: true`.
  (a) and (b) are retrospective (post-commit pre-pass); (c) is
  predictive (pre-rework). Any criterion fired → BLOCKED with cause
  `structural-finding` + BLOCKERS.md entry.
- **Closed halt-cause enum.** Every halt records a cause from a closed
  enum spanning recoverable causes (ratelimit, usage-limit, transient,
  resume-blocked-*), rework-exhaustion causes (rework-budget-exhausted,
  rework-scope-exceeded), structural causes (structural-finding,
  design-escalation), and external causes (external-blocker). The enum
  is the unified vocabulary across `paused` and `blocked` runtime
  states; the renderer (TDD 0018) shows the cause label plus a
  deterministic next-actions list.

throughline does NOT halt the runner on first failure. The runner does
NOT attempt in-iteration refactors larger than the cited finding's
local region. The runner does NOT cap individual rework attempts by
token-spend (FR-68 is telemetry-only); the aggregate enforcement is the
attempt-count budget.

NFR-3 (reviewer model diversity at the gate boundary) is preserved:
the original build runs on Opus; rework attempts run on Sonnet (chosen
for reduced opportunistic-refactoring tendency); the review gate runs
on Sonnet. The gate-1 / gate-d model split persists; the original/rework
split is within gate 1.

Rejected alternatives:
- **First-failure halt with manual user fix loop.** Status quo before
  this ADR; rejected per FR-15's update and the TDD 0011 diagnosis.
  Most findings are local and Sonnet-tractable; externalizing the loop
  to the user wastes their attention.
- **Unbounded automatic rework (no attempt budget).** Risks runaway
  cost and infinite loops on genuinely structural problems the runner
  cannot fix. Bounded attempts plus structural escalation are the
  safety pair.
- **Hard per-attempt token-spend cap that aborts mid-rework.** Risks
  aborting legitimate cases that happen to span a large region;
  rejected per the design-plan resolution of the PRD's Open question.
  Aggregate enforcement via attempt count is sufficient; per-attempt
  cost is observable via FR-68 telemetry.
- **In-iteration "structural fix-up" (the runner tries to satisfy a
  structural finding by expanding scope on its own).** Defeats the
  bounded-scope guarantee that makes per-TDD scope reasoning tractable
  in the first place (FR-53–FR-55). Structural findings escalate, not
  expand.

## Consequences

- The runner has authority to drive a fixable-finding loop without
  user involvement; the user is involved only at design boundaries.
  NFR-1's human control is preserved at phase boundaries (PRD merge,
  design PR merge, implementation PR merge) and narrowed inside a
  build to "informed of progress; not asked to drive between findings
  and convergence."
- The runner has BLOCKERS.md write authority (FR-17 + this ADR);
  BLOCKERS.md entries are the structured handoff from runner to human
  for rework-exhausted, structural, and design-escalation causes.
- Every halt is reproducible from the run-state record alone (composes
  with ADR 0006): cause label, triggering finding ref, rework attempt
  log, and configured budgets are on disk.
- The closed halt-cause enum (TDD 0018) is the single vocabulary for
  rendering halts to humans (`/implement-status`) and for routing
  follow-up actions; future halt-producing components must use a value
  from this enum or supersede this ADR with an enum extension.
- Default bound values (3 attempts / 60-line floor / 3× factor) are
  calibrated from TDD 0011 data; they are env-overridable for
  experimentation and will be revisited with operational data.
- Rework runs on Sonnet by default; the original-build/rework model
  diversity within gate 1 is a deliberate cost-reduction choice that
  the FR-68 telemetry surface lets us validate.
- Composes with ADR 0005 (gate scope by prompt): structural detection
  uses the TDD's declared `## Touched files` and `## Expected diff
  size` as the scope boundary, not a sandbox.
- Composes with ADR 0006 (gate verdicts grounded in artifacts): every
  rework decision (attempt? structural? exhausted?) cites artifact-
  reproducible facts.
- **Future tightening when warranted.** If operational data shows
  rework attempts converge well below 3 (suggesting a tighter budget
  is fine) or that the scope cap is too tight (suggesting common
  legitimate fixes exceed it), the defaults will be revised by a TDD
  rather than this ADR; the disposition (bounded + structural-
  escalating) is the durable decision, not the specific numbers.
- Promoted by TDDs 0018 + 0019; supersedes nothing. Refines FR-16's
  halt model in line with FR-61 / FR-62 / FR-63 / FR-65 / FR-66 /
  FR-67.

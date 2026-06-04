# TDD 0034: Bounded structural classification — (c) needs a named design reason, in-scope mechanical fixes rework

Status: implemented
PRD refs: FR-67 (gap-closure), FR-62, FR-66
PRD-rev: d289607
ADR constraints: 0005, 0006, 0007

## Approach

FR-67's criterion (c) was unbounded. The shipped review prompt defines
`structural: true` as "a finding whose fix would reach beyond the finding's
local region" (`review-prompt.md`), and the runner escalates ANY such finding to
a structural BLOCKED outcome before rework runs (`gates.sh` `_rework_loop`,
FR-67(c) branch). "Reaches beyond the local region" is satisfied by an in-scope
*mechanical* fix — relocating a block, reordering bullets, tightening a grep
anchor — that stays within the TDD's declared touched-file set and per-file
bound. The amended FR-67 (PRD-rev d289607) reserves (c) for genuine
design-level reconsideration and routes in-scope mechanical fixes to bounded
rework (FR-62).

This deadlocked a build in practice: an in-scope block relocation tagged
structural-(c) could neither be reworked (the runner refuses structural
findings) nor resumed without a TDD revision (the design was already correct),
and required manual build-branch surgery to break.

The fix has two surfaces, both already present — no new mechanism:
1. **The review prompt** gains a required `structural_reason` field and a
   tightened definition of `structural: true`.
2. **The runner's (c) escalation** (`gates.sh`) fires only when the reviewer
   supplied a non-empty `structural_reason`; a `structural: true` finding with no
   named reason falls through to the existing bounded-rework path, where the
   mechanical FR-67(a)/(b) scope checks (already in `_rework_pre_pass`) remain the
   real guardrail — an in-scope fix ships, an out-of-scope one is caught as
   structural-(a)/(b) exactly as today.

This respects ADR 0007 (bounded rework + structural escalation is the halt
model — this tightens *which* findings escalate, not the model), ADR 0005 (the
classification is enforced by the prompt plus the runner's mechanical read of
the finding, not a sandbox), and ADR 0006 (the routing decision rests on the
finding block's own fields and the TDD's declared scope — reproducible
artifacts, not author self-report).

## Components & interfaces

### 1. Finding schema — `scripts/review-prompt.md`

The `FINDING_BEGIN .. FINDING_END` schema gains one field, emitted on every
finding directly after `structural:`:

```
structural_reason: <one-line design-level reason | none>
```

The `structural: true` definition is rewritten from "reaches beyond the
finding's local region" to:

> `structural: true` marks a finding whose fix requires reconsidering the design
> itself — its interfaces, approach, or the TDD's declared decomposition — i.e. a
> fix that cannot be expressed as a bounded edit within the existing design. A
> *mechanical* fix that stays within the TDD's declared touched files and per-file
> bound — a relocation, reordering, anchor-tightening, or rename — is NOT
> structural even when it spans regions of a file; mark it `structural: false` and
> let bounded rework apply it. When (and only when) you set `structural: true`,
> `structural_reason` MUST name the specific design reconsideration required (not
> a restatement of the finding, not boilerplate). For `structural: false`, set
> `structural_reason: none`.

### 2. Runner classification — `scripts/lib/gates.sh`

Two edits, both in the existing finding-extraction / rework path:

- **Parse the new field.** The finding-parsing `awk` (the block that already
  captures `severity`/`structural`/`region`/… into the
  `␟`-delimited record `severity␟structural␟region␟region_lines␟pattern_tags␟summary␟evidence`)
  appends `structural_reason` as a new trailing field of that record (after
  `evidence`, so existing field positions are unchanged), and
  `_rework_extract_finding` reads it into a new `RWK_STRUCTURAL_REASON` variable
  alongside the existing `RWK_STRUCTURAL` / `RWK_REF` / `RWK_TEXT`.
- **Gate the (c) escalation.** `_rework_loop`'s FR-67(c) branch currently
  escalates whenever `RWK_STRUCTURAL` is set. It is changed to escalate only when
  `RWK_STRUCTURAL` is set AND `RWK_STRUCTURAL_REASON` is non-empty and not the
  sentinel `none` (after trimming). A `structural: true` finding whose
  `structural_reason` is empty / `none` is treated as a normal halting finding:
  the branch is skipped and control continues into the existing bounded-rework
  attempt, which runs `_rework_pre_pass` (the FR-67(a)/(b) + FR-66 mechanical
  caps). Thus an in-scope mechanical fix is applied by rework; an out-of-scope
  one is still caught — as structural-(a)/(b) — by the unchanged pre-pass.

The legacy single-line `REVIEW_FINDING:` fallback format (the TDD 0021 degraded
path read by `_rework_extract_finding`) carries no `structural_reason` token and
is NOT extended to carry one — a legacy structural finding therefore has an empty
`RWK_STRUCTURAL_REASON` and routes to rework, exactly the safe default of
failure-mode #2. Only the primary `FINDING_BEGIN..FINDING_END` block can express
a (c) escalation under the amended rule.

No change to the FR-67(a)/(b) pre-pass, to `_rework_escalate`, to the halt
taxonomy enum, or to the structural-finding resume path (TDD 0031): a genuine
(c) escalation still records `halt_cause=structural-finding` and is still
revision-resumable exactly as today.

## Data & state

No new persisted state and no run-state schema change. `structural_reason` lives
only in the transient review-log finding block and the in-memory
`RWK_STRUCTURAL_REASON` variable; it is consumed at classification time and not
persisted. A genuine (c) escalation records the same `halt_cause` /
`halt_cause_detail` it does today.

## Sequencing / implementation plan

1. **review-prompt.md**: add the `structural_reason` schema field and rewrite the
   `structural: true` definition (Component 1).
2. **gates.sh**: parse `structural_reason` into the finding record and expose
   `RWK_STRUCTURAL_REASON`; gate the FR-67(c) escalation branch on a non-empty,
   non-`none` reason (Component 2).
3. **Eval**: add `tests/structural-classification-bound.test.sh` covering the
   prompt greps and the classification routing against stub findings.
4. **Wire the eval into the aggregator (do NOT defer):** add the
   `tests/structural-classification-bound.test.sh` invocation to
   `tests/implement-gate.test.sh` in the SAME step — `*_FAIL` accumulator,
   conditional run, AND into the final pass/fail expression — so the eval is
   regression-gated by ci-checks, not orphaned.
5. **Update the E2 regression case** in `tests/bounded-rework-loop.test.sh`: its
   legacy single-line `structural=true` stub carries no reason, so Component 2
   now routes it to rework. Replace E2's `do_rework` stub (was `exit 9`) with a
   converging in-scope fix (mirroring E1) and invert its assertions to expect a
   shipped rework + flip, NOT a `structural-finding` halt. The genuine
   named-reason → (c) escalation path stays covered by the new eval (§3).

## Failure modes & edge cases

- **Boilerplate `structural_reason` to force escalation.** A reviewer could write
  a vacuous reason on an in-scope finding to push it to structural. Mitigated, not
  eliminated (same posture as FR-66's `## Scope override` boilerplate): the reason
  is graded by the human PR reviewer and the design-reviewer's diversity; the
  runner cannot judge prose quality (ADR 0006 limits it to artifact facts). The
  mechanical floor still holds — an in-scope fix that IS reworkable will be
  applied if the reviewer tags it `structural: false`, which the tightened prompt
  directs.
- **Missing `structural_reason` field entirely** (older prompt, malformed
  finding, or the legacy single-line `REVIEW_FINDING:` fallback format, which
  carries no reason token). The parser yields an empty `RWK_STRUCTURAL_REASON`;
  an empty reason is treated as "no named reason" → the finding routes to rework
  (the safe, non-escalating direction). A genuinely out-of-scope rework is then
  caught by the (a)/(b) pre-pass, so no out-of-scope change ships. Regression-
  covered end-to-end by `tests/bounded-rework-loop.test.sh` E2.
- **`structural: false` with a non-empty `structural_reason`.** Ignored: the (c)
  branch keys on `RWK_STRUCTURAL` first; a false structural flag never escalates
  via (c) regardless of the reason text.
- **`structural_reason: none` literal.** Treated as empty (no named reason) after
  trimming — routes to rework.

## Verification plan

**Observable surface:** `scripts/review-prompt.md` text; the runner's
classification decision for a finding — observable as whether `_rework_loop`
escalates (a `structural-finding` halt + `docs/tdd/BLOCKERS.md` entry) or routes
to a bounded-rework attempt (a `rework_attempts` entry in the run-state record).

**Observation points** (mechanical, driven by
`tests/structural-classification-bound.test.sh` with stub review-log fixtures and
a stub TDD declaring a touched-file set + per-file bound, following the fixture
pattern of `tests/bounded-rework-loop.test.sh`):

1. **Prompt text present.** Grep `scripts/review-prompt.md` for: the
   `structural_reason:` schema field; the phrase "requires reconsidering the
   design"; the instruction that a mechanical relocation/reorder within bounds is
   NOT structural.
2. **In-scope + no reason → rework, not escalation.** Drive the classification
   path with a stub finding: `structural: true`, `structural_reason: none`,
   `region` inside the stub TDD's declared touched file and within its per-file
   bound → the runner does NOT record a `structural-finding` halt; it proceeds to
   a bounded-rework attempt (observable: no `structural-finding` in the fragment's
   `halt_cause`; a rework attempt is recorded).
3. **In-scope + named reason → structural escalation.** Same finding but
   `structural_reason: the gate's interface contract must change` → the runner
   escalates: `halt_cause=structural-finding`, criterion `(c)`, and a
   `docs/tdd/BLOCKERS.md` entry is written.
4. **Out-of-scope, no reason → still structural-(a).** `structural: true`,
   `structural_reason: none`, but the rework's diff touches a file outside the
   declared set → the (a)/(b) pre-pass escalates `structural-finding(a)` exactly
   as today (the no-reason path did NOT make an out-of-scope change shippable).
5. **Empty/absent field is safe.** A finding block with no `structural_reason`
   line at all and `structural: true`, in-scope → routes to rework (same as §2).

**Expected observations (PASS):** every numbered point yields the cited
classification.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-67 (gap-closure: (c) reserved for named design-level reconsideration; in-scope mechanical fix routes to rework) | Component 1 (prompt: `structural_reason` field + tightened `structural: true` definition) + Component 2 (runner gates the (c) escalation on a non-empty named reason; otherwise falls through to rework). Verification §1, §2, §3, §5. |
| FR-62 (bounded in-invocation rework for fixable findings) | Component 2: a `structural: true`-but-unnamed in-scope finding now enters the existing bounded-rework path instead of escalating. Verification §2, §5. |
| FR-66 (bounded rework scope per attempt) | Unchanged and relied upon: the FR-67(a)/(b) + FR-66 pre-pass remains the guardrail for the now-reworked findings, catching any out-of-scope rework. Verification §4. |

No gaps.

## Dependencies considered

No new external dependencies and no new internal mechanism — the change reuses
the existing finding-parse, `_rework_extract_finding`, `_rework_loop`, and
`_rework_pre_pass` surfaces.

Alternatives considered:
- **Prompt-only tightening (no schema field, no runner change)** — rejected: the
  classification would rest entirely on reviewer compliance with no mechanical
  read, violating the project's artifact-grounded posture (ADR 0006) and leaving
  the deadlock reachable whenever the reviewer still tags an in-scope fix
  structural. The `structural_reason` field makes the (c) decision a fact the
  runner reads.
- **Runner re-derives "is this mechanical?" itself** (classify relocation vs
  design change by analyzing the diff) — rejected: that is exactly the design
  judgment the reviewer is for; duplicating it in shell is brittle and
  unbounded. The runner's role stays mechanical (read the flag + reason + the
  declared scope), per ADR 0005/0006.
- **Add a resume-into-rework path for already-escalated structural halts** —
  rejected for this TDD's scope: that is the broader safety net the user
  deferred; bounding (c) at classification time prevents the mis-escalation at
  the source, which is the root cause. (A genuine structural halt remains
  revision-resumable via TDD 0031.)

## PRD conflicts surfaced (and resolution)

None. This TDD implements the FR-67 amendment (PRD-rev d289607) directly; the
amendment's acceptance criterion (both directions: named-reason → BLOCKED;
in-scope-unnamed → rework) is the verification plan's §2/§3.

## Decisions to promote (ADR candidates)

None. The change refines an existing classification rule within the established
halt model (ADR 0007); it introduces no new cross-cutting decision.

## Touched files

- `scripts/review-prompt.md` — `structural_reason` schema field + tightened `structural: true` definition.
- `scripts/lib/gates.sh` — parse `structural_reason` into the finding record / `RWK_STRUCTURAL_REASON`; gate the FR-67(c) escalation on a non-empty named reason.
- `tests/structural-classification-bound.test.sh` — new eval (prompt greps + classification routing against stub findings).
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.
- `tests/bounded-rework-loop.test.sh` — update the E2 case: a legacy single-line `structural=true` finding carries no `structural_reason`, so under Component 2 it now routes to bounded rework (failure-mode #2), not (c)-escalation. Re-point E2's `do_rework` stub + assertions to the rework-converges outcome.

Total: 5 files touched.

## Expected diff size

- `scripts/review-prompt.md` — ~16 lines added.
- `scripts/lib/gates.sh` — ~32 lines added/changed (awk field capture + `RWK_STRUCTURAL_REASON` export + the (c)-branch guard).
- `tests/structural-classification-bound.test.sh` — ~150 lines added (new eval: prompt greps + 4 stub-finding classification cases with per-assertion ok/bad reporting and fail-closed file guards).
- `tests/implement-gate.test.sh` — ~14 lines added (aggregator wire-in).
- `tests/bounded-rework-loop.test.sh` — ~10 lines changed (E2 `do_rework` stub + inverted assertions; no new case).

Total expected diff: ~222 lines across 5 files. No exceptions needed (each file is under the 300-line per-file bound).

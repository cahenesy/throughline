# TDD 0041: Bounded-rework convergence — don't burn budget on scope-rejected attempts; sweep binding-rule violations

Status: draft
PRD refs: FR-65 (gap-closure); FR-66; FR-67; FR-58; FR-59
PRD-rev: d289607
ADR constraints: 0005, 0006, 0007

## Approach

Run 20260608-011142 exhausted TDD 0036's rework budget (`THROUGHLINE_REWORK_MAX=3`)
without a genuine convergence failure, for two compounding reasons:

1. **Scope-rejected attempts counted against the convergence budget.** An attempt
   hard-reset for a scope overrun (FR-66 `rework-scope-exceeded` / FR-67(b)
   structural-finding — the commit is reset off the branch and the run BLOCKs for
   a TDD revision) still incremented the per-(gate,step) rework counter. The
   counter persists in the fragment across resumes, so a couple of scope rejections
   (each correctly routed to a `## Expected diff size` revision) permanently ate
   the budget meant for *real* convergence attempts. The result: after the
   declarations were fixed, the resumed run had no budget left and halted
   `rework-budget-exhausted` on already-correct work.

2. **The reviewer trickled a binding-rule violation one instance per pass.** A
   TDD-binding rule that applies to several sites (e.g. 0036's "no-hang discipline"
   binding §1/§2/§3/§6, or its timing-margin rule) was cited as one violating site
   per review pass. Each pass consumed a separate rework attempt to fix one site,
   so a 4-site rule needed ~4 attempts — multiplying budget pressure for what is
   logically one fix.

This TDD fixes both without loosening the scope gate (the declared per-file bound
stays a hard cap — operator decision; estimate accuracy is the discipline):

- **(a) Convergence-budget honesty.** A rework attempt that is hard-reset for
  scope (never shipped a commit that survived the pre-pass) does NOT consume the
  convergence budget — the counter increment for that attempt is rolled back when
  the run escalates structural/scope. The budget counts only *shipped-but-still-flawed*
  attempts (the case it exists to bound).
- **(b) Binding-rule sweep.** The review prompt instructs the reviewer: when a
  finding is a violation of a **TDD-binding rule** that the same diff violates in
  MORE THAN ONE place, enumerate ALL violating regions in ONE finding (a single
  rework target), rather than emitting (or reserving for a later pass) one finding
  per site. The bounded rework then fixes the whole class in one attempt.

ADR 0007 (the halt model — bounded rework + structural escalation) is preserved:
escalation still happens, scope is still enforced; only the *accounting* of what
spends the budget changes. ADR 0006 (grounded verdicts) constrains (b): the sweep
must cite each region verbatim from the diff, not assert "and others". ADR 0005
(gate scope by prompt + downstream detection) is the lever for (b) — it is a
review-prompt instruction, not new runner machinery.

## Components & interfaces

### 1. Convergence-budget honesty — `scripts/lib/gates.sh`

The exact ordering in `_rework_loop` matters for where the fix belongs:
`structural-finding`(c) and the `rework-budget-exhausted` guard both fire
**before** `_rework_attempt_count` increments the counter for the iteration, so
neither needs a rollback (nothing was counted yet) — they are correct as-is. The
increment happens, then `_rework_one` generates the commit, then the scope
pre-pass (`_rework_pre_pass`) evaluates it; ONLY the pre-pass-fail paths —
`structural-finding`(b) and FR-66 `rework-scope-exceeded` — escalate **after** the
increment with a commit that was hard-reset (never shipped). Those two paths are
the bug.

Change: a new fragment-mutator helper `_decrement_rework_attempt <slug>
<gate:step>` (in `lib/state.sh`, with the other fragment mutators like
`set_halt_cause`) does a read-modify-write of
the `rework_attempts` JSON object — `rework_attempts[<gate:step>] = max(0,
current - 1)` — as a single atomic compact-JSON write. On the
`structural-finding`(b) and `rework-scope-exceeded` escalation sites in
`_rework_loop`, call `_decrement_rework_attempt` for the current `<gate:step>`
BEFORE the `_rework_escalate`/`_terminal_state` BLOCK, so the budget reflects only
attempts that shipped a surviving rework commit. Error-checked: a write failure
logs a warning but does not change the BLOCK outcome (the escalation is
authoritative; the worst case degrades to today's over-counting, never a crash).
`structural-finding`(c) and `rework-budget-exhausted` are explicitly NOT touched
(they are pre-increment).

A one-line telemetry note records "attempt not counted (scope-rejected, never
shipped)" so the accounting is visible, not silent (NFR-4 spirit).

### 2. Binding-rule sweep instruction — `scripts/review-prompt.md`

Add a rule to the Findings section: when a finding's `pattern_tags` identify a
violation of a **TDD-binding rule** (a rule the governing TDD states as binding —
e.g. a "MUST"/"binding" discipline in the Verification plan or Approach) AND the
SAME diff violates that rule in more than one region, the reviewer MUST emit ONE
finding whose `region` enumerates ALL violating sites (the primary region in
`region`, the rest in the `evidence` with a verbatim quote per site), with a
`pattern_tags` entry `binding-rule-sweep`. The reviewer must NOT split a single
binding-rule class across multiple passes or findings. Each enumerated site's
quote is grounded per ADR 0006 (verbatim from the diff). `region_lines` is the sum
of the enumerated spans so the rework scope cap (FR-66) accounts for the whole
fix. (A non-binding, site-specific quality nit is unaffected — it stays one
finding per site, as today.)

### 3. Sweep-aware rework scoping — `scripts/lib/gates.sh`

The bounded-rework attempt sets the per-attempt scope cap (FR-66:
`max(floor, factor × finding-region)`) from the triggering finding's span. The
post-condition this component guarantees: that span is the finding's
**`region_lines`** field — which Component 2 sets to the SUMMED span for a swept
finding — NOT a value re-derived from only the primary `region` line-range. Net
change is conditional on the current code:
- if `_rework_loop` already feeds `region_lines` into the cap formula (the likely
  case — `region_lines` is the FR-66-declared span field), Component 3 is a
  no-op confirmed by Verification §7 (no code change);
- if it instead re-computes the span from the primary `region` `<a>-<b>` range,
  change it to use `region_lines`.
The formula itself is unchanged. Either way the post-condition holds: a swept
finding's cap covers all enumerated sites, so a whole-class fix is not itself
scope-rejected for touching all its sites at once.

## Data & state

No schema change. `rework_attempts[<gate:step>]` is an existing integer field;
Component 1 decrements it on the scope-rejection path. The `binding-rule-sweep`
pattern tag and the summed `region_lines` are existing finding fields used
differently. The telemetry note is an existing `note`/log string.

## Sequencing / implementation plan

1. **gates.sh — budget rollback**: on the `structural-finding`(b) and
   `rework-scope-exceeded` escalation paths, decrement the current attempt's
   persisted counter (floored at 0) before BLOCKing; log the not-counted note
   (Component 1).
2. **review-prompt.md — sweep rule**: add the binding-rule-sweep instruction to
   the Findings section (Component 2).
3. **gates.sh — sweep-aware scope read**: ensure the rework scope cap reads the
   swept finding's summed `region_lines` so a whole-class fix is not itself
   scope-rejected (Component 3).
4. **Eval** `tests/bounded-rework-convergence.test.sh`: drive the rollback
   accounting and assert the review-prompt carries the sweep rule.
5. **Wire the eval into the aggregator** (`tests/implement-gate.test.sh`) in the
   SAME step.

## Failure modes & edge cases

- **A scope-rejected attempt that DID partially ship before the reset** → the
  hard-reset removes the commit (FR-66), so "never shipped" holds; the rollback is
  correct. If a future reset path leaves a commit, the rollback must key off
  "commit survived the pre-pass", not merely "escalated" — Component 1 keys off
  the scope-rejection escalation specifically (not all BLOCKs).
- **Counter underflow** → decrement is floored at 0; a rollback when the counter
  is already 0 (no prior increment) is a no-op, never negative.
- **Rollback write fails** → log a warning, keep the BLOCK (the escalation is
  authoritative); the worst case is the OLD behavior (the attempt counts) — a safe
  degradation, never a crash or an uncapped loop.
- **Sweep over-reach** → the reviewer enumerates sites that are NOT all the same
  rule (lumping distinct issues) → grounded-evidence requirement (ADR 0006) plus
  the `binding-rule-sweep` tag scope it to ONE rule; a reviewer that lumps
  unrelated findings produces an evidence mismatch a human PR review catches. The
  sweep is for ONE binding rule's instances, explicitly.
- **A binding rule with a single violating site** → emitted as an ordinary single
  finding (the sweep only triggers on >1 site); no behavior change.
- **Sweep finding's summed span exceeds the per-file declared bound** → that is a
  legitimate scope signal (the whole-class fix is genuinely large) → structural(b)
  as designed, routing to a TDD `## Expected diff size` revision. The sweep does
  not bypass the scope gate; it just doesn't fragment the fix across attempts.

## Verification plan

**Observable surface:** the persisted `rework_attempts[<gate:step>]` counter after
a scope-rejection escalation; the `scripts/review-prompt.md` text; the rework
scope cap's input span for a swept finding.

**Observation points** (driven by `tests/bounded-rework-convergence.test.sh`,
using the existing bounded-rework gate test harness with stub review verdicts):

1. **Scope-rejected attempt is not counted.** Drive a rework attempt whose
   pre-pass yields `structural-finding`(b) (a stub finding touching a file beyond
   the declared set). Observe: after the BLOCK, the fragment's
   `rework_attempts[review:1]` is UNCHANGED from before the attempt (the increment
   was rolled back), and a "not counted (scope-rejected)" note is present.
2. **rework-scope-exceeded is not counted.** Same for an attempt that overruns the
   per-attempt scope cap (FR-66) → hard-reset → BLOCK → counter unchanged.
3. **Shipped-but-flawed attempt IS counted.** Drive an attempt that ships a rework
   commit which the re-review still BLOCKs (an ordinary halting finding, not
   scope) → the counter increments by one (the budget rightly bounds genuine
   convergence attempts).
4. **structural-finding(c) is unchanged.** A genuine design escalation (c) does
   NOT roll back the counter (it's not a scope rejection) — confirms the rollback
   is scoped to (b)/scope-exceeded.
5. **Counter floor.** A scope rejection when the counter is 0 leaves it 0 (no
   underflow).
6. **Sweep rule present (mechanical).** Grep `scripts/review-prompt.md` for the
   binding-rule-sweep instruction: "more than one region" enumeration, the
   `binding-rule-sweep` tag, the summed `region_lines` requirement, and the
   "do NOT split across passes" clause.
7. **Sweep scope read.** A stub swept finding with a summed `region_lines`
   spanning multiple sites yields a rework scope cap that covers the full span
   (the cap reads the summed span, so the whole-class fix is not scope-rejected
   for touching all sites).

**Mechanical-check robustness (binding — L-001/L-002):** absence assertions
distinguish grep exit 1 vs ≥2 and fail on unreadable; every target file asserted
readable before content checks; the counter seeds + verdict stubs are explicit
fixtures (compact single-line JSON); no real review subprocess is spawned.

**Expected observations (PASS):** every numbered point yields the cited result.

## Evaluation rubric

| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | every in-scope FR/NFR maps to a named component + verification point | maps with minor gaps noted | an in-scope requirement is untraced |
| Interface concreteness | exact counter field, the two rollback escalation sites, and the sweep instruction named | named with one ambiguity | "fix the budget" hand-waving |
| Alternatives analysis | ≥1 concrete rejected alternative with reason for each design choice | one named alternative | "none considered" |
| Verification-plan actionability | each point names a fixture, an action, and an expected observation a test can assert | mostly actionable | no observable surface / observation point named |
| Scope-bound adherence | within declared touched-files + per-file diff bounds, honestly estimated | within bounds, estimate loose | blows a bound with no exception |
| Naming consistency | one name per concept (`binding-rule-sweep`, `rework_attempts`) across the TDD | minor drift | same concept two names |

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-65 (gap-closure: the rework attempt budget bounds genuine convergence attempts) | Component 1 (a scope-rejected, never-shipped attempt is rolled back, so the budget counts only shipped-but-flawed attempts). Verification §1–§3, §5. |
| FR-66 (per-attempt scope cap) | Component 3 (a swept finding's summed span feeds the existing cap so a whole-class fix isn't itself scope-rejected) — the cap formula is unchanged. Verification §7. |
| FR-67 (structural escalation (b)/(c)) | Component 1 rolls back on (b)/scope-exceeded only; (c) is unchanged. Verification §4. |
| FR-58 (severity-driven halting findings) | Component 2 keeps severity semantics; a sweep is one halting finding covering its class. Verification §6. |
| FR-59 (recurrence is a stronger finding) | Component 2's sweep is the within-pass analogue: all instances of one binding rule are cited together, not trickled. Verification §6. |

No gaps.

## Dependencies considered

No new external dependency — changes are in the existing bash runner
(`lib/gates.sh`) and the review-prompt template (`review-prompt.md`).

Alternatives considered:
- **Reset the whole rework counter on every resume** — rejected: would also wipe
  *genuine* convergence attempts, defeating the budget's purpose (a real
  non-converging build could loop indefinitely across resumes). Rolling back only
  the scope-rejected attempt is precise. ([[0039]]'s `--recover` resets the budget,
  but that is an explicit operator act for a judged artifact, not automatic.)
- **A runner-side dedup that merges per-site review findings into one** — rejected:
  duplicates judgement the reviewer already has (it knows the binding rule);
  ADR 0005 favors the prompt instruction (the reviewer enumerates) over new runner
  machinery parsing/merging findings.
- **Raise the default `THROUGHLINE_REWORK_MAX`** — rejected: treats the symptom
  (run out of budget) not the cause (budget spent on non-attempts and trickled
  fixes); a higher cap still wastes attempts and delays a real non-convergence
  signal.

## PRD conflicts surfaced (and resolution)

Resolves the unchecked `docs/tdd/BLOCKERS.md` entry "0036 …
rework-budget-exhausted budget — rework budget 3 exhausted at review:1": the
budget was exhausted by scope-rejected attempts (Component 1) compounded by
one-site-per-pass binding-rule findings (Component 2), not by a real convergence
failure. No PRD requirement is contradicted — FR-65's intent (bound genuine
convergence) is honored more faithfully. (The specific 0036 run is recovered
operationally via [[0039]]; this TDD prevents the recurrence.)

## Decisions to promote (ADR candidates)

None. Refinements within ADR 0007's halt model and ADR 0005's prompt-driven gate
scope; no new cross-cutting decision.

## Touched files

- `scripts/lib/gates.sh` — call `_decrement_rework_attempt` on the two scope-rejection escalation sites; read the swept finding's summed span for the scope cap.
- `scripts/lib/state.sh` — `_decrement_rework_attempt` fragment-mutator helper (atomic compact, error-checked, floored at 0).
- `scripts/review-prompt.md` — binding-rule-sweep instruction (enumerate all violating regions of one binding rule in one finding).
- `tests/bounded-rework-convergence.test.sh` — new eval (rollback accounting + sweep-rule presence + scope read).
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Total: 5 files touched.

## Expected diff size

- `scripts/lib/gates.sh` — ~30 lines (two `_decrement_rework_attempt` calls + telemetry note + summed-span read for the scope cap).
- `scripts/lib/state.sh` — ~16 lines (`_decrement_rework_attempt` helper).
- `scripts/review-prompt.md` — ~22 lines (binding-rule-sweep instruction block).
- `tests/bounded-rework-convergence.test.sh` — ~150 lines (7 cases: rollback on (b)/scope-exceeded, counted-when-shipped, (c)-unchanged, floor, sweep-present, sweep-scope; fail-closed assertions).
- `tests/implement-gate.test.sh` — ~12 lines (aggregator wire-in).

Total expected diff: ~230 lines across 5 files. No exceptions needed (each file is under the 300-line per-file bound).

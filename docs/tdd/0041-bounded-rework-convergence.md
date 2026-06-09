# TDD 0041: Bounded-rework convergence — tolerate estimate error, don't burn budget on scope-rejected attempts, sweep binding-rule violations

Status: draft
PRD refs: FR-65 (gap-closure); FR-66; FR-67 (gap-closure: (b) tolerance); FR-58; FR-59
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

A later analysis (2026-06-09, run 20260608-195531 / TDD 0038) showed the budget
churn has a THIRD, upstream cause that an earlier draft of this TDD deliberately
declined to address: the per-file `structural-finding`(b) escalation fires on
*normal estimation error*. A history study of declared `## Expected diff size` vs
actual implemented diff found estimates run **~1.5× low systematically** (mean
1.55× across a clean non-survivorship sample of 7 implemented TDDs; 8 historical
upward TDD revisions and **0 downward** — the one-sided asymmetry is the tell).
The earlier stance here — "estimate accuracy is the discipline" — is contradicted
by that data: a ~1.5× systematic bias means `actual > declared` routinely fires on
TDDs that are not over-scoped, just normally-estimated, converting each into a
revise→merge→`--resume` cycle (TDD 0038 took THREE such halts in one session). So
this TDD now adds a tolerance lever (c) ALONGSIDE the two accounting/review fixes
(a)/(b); the HARD design-time caps (`THROUGHLINE_TDD_MAX_FILE_DIFF`=300/file,
`MAX_TOUCHED`=8, enforced by `tdd-lint --bounds` on the DECLARED estimate) are
unchanged — only the *runtime* escalation threshold gains tolerance:

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
- **(c) Estimate-error tolerance on the runtime per-file escalation.** The
  runtime `structural-finding`(b) check (`_rework_pre_pass`, `lib/gates.sh`)
  escalates only when a touched file's cumulative actual diff exceeds its declared
  estimate × a tolerance factor **K** (`THROUGHLINE_STRUCTURAL_DIFF_TOLERANCE`,
  default **1.6**), not when it merely exceeds the raw estimate. K=1.6 sits just
  above the measured ~1.55× mean, so a normally-biased estimate passes while a
  genuine ≥1.6× under-scope (e.g. the observed 1.87× `implement-watch.sh` case)
  still escalates to a design revision. Tolerance applies ONLY to the runtime
  actual-vs-declared comparison; there is no "actual" at design time, so
  `tdd-lint --bounds` (which caps the DECLARED estimate at 300) is untouched.
- **(d) Authoring-side estimate padding** (belt-and-suspenders to (c)). The
  tdd-author skill pads first-instinct per-file estimates by the measured per-class
  bias at authoring time, so the DECLARED number is closer to reality and (c)'s
  runtime tolerance becomes headroom rather than the sole guard. Advisory, never a
  gate.

ADR 0007 (the halt model — bounded rework + structural escalation) is preserved:
escalation still happens (just at the tolerated threshold), scope is still
enforced; only the *accounting* of what spends the budget (a) and the *threshold*
at which a per-file overrun escalates (c) change. ADR 0006 (grounded verdicts)
constrains (b): the sweep must cite each region verbatim from the diff, not assert
"and others"; and constrains (c): the threshold is computed from verifiable git
`--numstat` actuals against the TDD's declared estimate, no model judgment. ADR
0005 (gate scope by prompt + downstream detection) is the lever for (b) — it is a
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
finding — NOT a value re-derived from only the primary `region` line-range.
**Confirmed no-op in the current code** (verified, not conditional):
`_rework_extract_finding` (gates.sh:1652) sets `RWK_REGION` from the structured
finding's `region_lines`, and `_rework_loop` (gates.sh:1863) passes `RWK_REGION`
directly to `_rework_scope_cap` — so the cap already reads the summed span.
Component 3 therefore makes NO code change; it is a post-condition GUARANTEE that
the cap reads `region_lines` (not the primary `region` range), asserted by
Verification §7 so a future refactor that breaks it is caught. The formula is
unchanged. The post-condition holds: a swept finding's cap covers all enumerated
sites, so a whole-class fix is not itself scope-rejected for touching all its
sites at once.

### 4. Estimate-error tolerance on the runtime per-file escalation — `scripts/lib/gates.sh`

The `_rework_pre_pass` FR-67(b) per-file check currently escalates on a raw
integer comparison `actual > num` (where `actual` is `git diff --numstat
build_start..new_head` summed for the file and `num` is the TDD's declared
per-file estimate). Change it to escalate only when `actual` exceeds `num × K`:

- **Knob.** `K = THROUGHLINE_STRUCTURAL_DIFF_TOLERANCE`, default `1.6`. Guard
  with an explicit ERE test (the existing `*[!0-9]*` case-glob guards in this
  function can't express "decimal with optional fraction", so use `[[ =~ ]]`):
  `if ! [[ "$K" =~ ^[0-9]+([.][0-9]+)?$ ]]; then K=1.6; fi`; on a non-numeric /
  empty value fall back to the `1.6` default (a malformed knob must never make K
  read as `0`, which would make every file escalate — fail safe toward the
  default, not toward `0`). Then floor at `1.0` via an awk compare
  (`awk -v k="$K" 'BEGIN{exit !(k<1)}' && K=1.0`) — a tolerance below 1 would
  *tighten* the bound, which is nonsensical and would re-introduce false halts.
- **Comparison.** Use `awk` for the multiply so a float K is exact without bash
  integer-truncation games:
  `awk -v a="$actual" -v n="$num" -v k="$K" 'BEGIN{exit !(a > n*k)}'` → exit 0
  (escalate) iff `a > n*k`. The threshold is recomputed from the same `actual`
  and declared `num` already in scope; no new state.
- **Diagnostic.** The `PRECHECK_FAIL` line records the factor so a halt is
  self-explanatory and reproducible (ADR 0006):
  `printf 'PRECHECK_FAIL: structural-finding(b) %s %s > %s (tolerance ×%s)\n' "$file" "$actual" "$num" "$K"`.
- **Scope.** Tolerance applies ONLY here — the runtime rework pre-pass
  actual-vs-declared escalation. The FR-67(a) touched-file-membership check
  (a file outside the declared SET) is unchanged: K is a per-file *size* tolerance,
  never a license to touch undeclared files. The declared-exception path
  (`exc=1 → continue`) is unchanged (an exception already disables the bound).
  The design-time hard caps (`tdd-lint --bounds`: declared ≤ 300, ≤ 8 files) are
  untouched — there is no `actual` at design time to tolerate.

Worst case: a file declared at the 300 design-time cap can reach `300 × 1.6 = 480`
actual before escalating. That is acceptable — the design-critique gate already
vetted `declared ≤ 300`, and a rework that genuinely overran its vetted estimate
by ≥1.6× is a real signal worth a design revision (which still fires at the
tolerated threshold).

### 5. Authoring-side estimate padding — `skills/tdd-author/SKILL.md`

Component 4 tolerates the systematic underestimate at RUNTIME; this component
reduces it at AUTHORING time (belt-and-suspenders — a smaller raw error means even
fewer escalations, and the runtime tolerance is then headroom rather than the only
guard). In the `## Expected diff size` authoring instructions (the "Declared
scope (REQUIRED — TDD 0014 / FR-53, FR-54)" block), add a short calibration
heuristic instructing the author to pad first-instinct per-file estimates by the
measured bias before declaring them: **test/eval files ≈ 1.6×, shell-library /
script files ≈ 1.4×** (the classes the history study found most under-counted —
test scaffolding and helper plumbing), prose/markdown ≈ 1.2×. The heuristic is
advisory authoring guidance, NOT a gate: it never emits a `PRECHECK_FAIL` and the
design-critique gate does not check whether it was applied (mirroring the FR-73
learning-surfacing posture). It cites the systematic-underestimate finding so a
future reader knows the multipliers are data-derived, not arbitrary, and notes
they are a starting calibration to refine as more runs accrue.

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
4. **gates.sh — estimate-tolerance**: change the `_rework_pre_pass` FR-67(b)
   comparison from `actual > num` to `actual > num × K` (awk multiply, guarded
   knob, factor in the diagnostic) (Component 4).
5. **tdd-author SKILL.md — estimate-padding heuristic**: add the data-derived
   per-file padding multipliers to the `## Expected diff size` authoring block
   (Component 5).
6. **Eval** `tests/bounded-rework-convergence.test.sh`: drive the rollback
   accounting, the K-tolerance threshold (under-K passes, over-K escalates,
   malformed-knob → default), assert the review-prompt carries the sweep rule, and
   assert the SKILL.md carries the padding heuristic.
7. **Wire the eval into the aggregator** (`tests/implement-gate.test.sh`) in the
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
- **Sweep finding's summed span exceeds the per-file declared bound × K** → that is
  a legitimate scope signal (the whole-class fix is genuinely large, beyond even the
  tolerance) → structural(b) as designed, routing to a TDD `## Expected diff size`
  revision. The sweep does not bypass the scope gate; it just doesn't fragment the
  fix across attempts.
- **Malformed `THROUGHLINE_STRUCTURAL_DIFF_TOLERANCE`** (non-numeric, empty, or
  `<1`) → falls back to the `1.6` default (or floors at `1.0`); it NEVER reads as
  `0` (which would make every per-file overrun escalate — the opposite of intended)
  and never tightens the bound below the raw estimate.
- **A genuinely over-scoped rework (≥ K× the estimate)** → still escalates
  structural(b) exactly as before, just at the tolerated threshold; the design
  revision path (FR-54/FR-67) is preserved for real under-scopes. K absorbs normal
  estimation error, not genuine 2×-off designs.

## Verification plan

**Observable surface:** the persisted `rework_attempts[<gate:step>]` counter after
a scope-rejection escalation; the `scripts/review-prompt.md` text; the rework
scope cap's input span for a swept finding; the `_rework_pre_pass` exit + its
`PRECHECK_FAIL: structural-finding(b) … (tolerance ×K)` line as a function of
`actual` vs `declared × K`.

**Observation points** (driven by `tests/bounded-rework-convergence.test.sh`,
using the existing bounded-rework gate test harness with stub review verdicts):

1. **Scope-rejected attempt is not counted.** Drive a rework attempt whose
   pre-pass yields `structural-finding`(b) (a stub whose cumulative actual diff
   for a declared file exceeds its bound × K — a per-file overrun, the (b)
   criterion; NOT the (a) out-of-set criterion). Observe: after the BLOCK, the
   fragment's
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
8. **Within-tolerance overrun PASSES the pre-pass (Component 4).** A file declared
   at N=50 whose actual cumulative diff is 70 (1.4× ≤ K=1.6) does NOT emit
   `structural-finding(b)` (`_rework_pre_pass` does not fail on that file). Drive
   `_rework_pre_pass` directly with a stub TDD declaring 50 and a diff of 70.
9. **Beyond-tolerance overrun ESCALATES (Component 4).** Same file, actual 90
   (1.8× > 1.6) emits `PRECHECK_FAIL: structural-finding(b) <file> 90 > 50
   (tolerance ×1.6)`. Asserts the genuine under-scope still routes to a revision.
10. **Knob override + malformed fallback.** With
    `THROUGHLINE_STRUCTURAL_DIFF_TOLERANCE=2.0`, actual 90 vs declared 50 (1.8× <
    2.0) PASSES; with the knob set to a malformed value (`abc`), the check uses the
    1.6 default (actual 90 escalates), proving the guard never reads K as 0.
11. **Authoring heuristic present (mechanical, Component 5).** Grep
    `skills/tdd-author/SKILL.md` for the estimate-padding multipliers (the
    `test/eval ≈ 1.6×` and `shell-library ≈ 1.4×` calibration in the
    `## Expected diff size` block), fail-closed on grep ≥2 / unreadable.

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
| FR-67 (gap-closure: (b) tolerance) | Component 4 — the runtime (b) per-file escalation fires at `actual > declared × K` (K=1.6 default), absorbing the measured ~1.5× estimate bias while still escalating genuine ≥K under-scopes; design-time hard caps unchanged. Verification §8–§10. |
| FR-53 (the declared per-file estimate's quality) | Component 5 — the tdd-author skill pads first-instinct per-file estimates by the measured per-class bias (test/eval ≈1.6×, shell-lib ≈1.4×) so the DECLARED estimate is closer to reality at authoring time (belt-and-suspenders to Component 4's runtime tolerance). Advisory, non-gating. Verification §11. |
| FR-58 (severity-driven halting findings) | Component 2 keeps severity semantics; a sweep is one halting finding covering its class. Verification §6. |
| FR-59 (recurrence is a stronger finding) | Component 2's sweep is the within-pass analogue: all instances of one binding rule are cited together, not trickled. Verification §6. |

No gaps.

## Dependencies considered

No new external dependency — changes are in the existing bash runner
(`lib/gates.sh`, `lib/state.sh`), the review-prompt template (`review-prompt.md`),
and the tdd-author skill (`skills/tdd-author/SKILL.md`).

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
- **(Component 4) "Fix the estimates" instead of adding tolerance** (the earlier
  draft's stance) — rejected by data: declared estimates run ~1.5× low
  *systematically* (8 upward revisions, 0 downward), so expecting per-TDD accuracy
  fights a measured cognitive bias; a tolerance factor absorbs it mechanically with
  no per-author behavior change.
- **(Component 4) An absolute runtime ceiling (e.g. halt at actual > 2×300)** in
  addition to K — rejected: adds a second threshold and knob, and a file
  legitimately near the ceiling could still false-halt — the exact failure K
  exists to remove. The design-time `declared ≤ 300` cap already bounds the worst
  case to `300 × K`.
- **(Component 4) Apply K to the design-time `tdd-lint --bounds` check** —
  rejected as a category error: there is no `actual` diff at design time;
  `tdd-lint` caps the DECLARED estimate (≤300), and tolerating a *declared* number
  would just let authors declare 480 — defeating the bound. K is meaningful only
  against a real `actual`.

## PRD conflicts surfaced (and resolution)

Resolves the unchecked `docs/tdd/BLOCKERS.md` entry "0036 …
rework-budget-exhausted budget — rework budget 3 exhausted at review:1": the
budget was exhausted by scope-rejected attempts (Component 1) compounded by
one-site-per-pass binding-rule findings (Component 2), not by a real convergence
failure. No PRD requirement is contradicted — FR-65's intent (bound genuine
convergence) is honored more faithfully. (The specific 0036 run is recovered
operationally via [[0039]]; this TDD prevents the recurrence.)

Component 4 additionally addresses the recurring `structural-finding(b)` per-file
under-estimate class — the closed BLOCKERS entries for 0028 (`131 > 90`), 0036
(`71 > 38`, `293 > 290`), and 0038 (`78 > 55`, `307 > 280`), each resolved by a
manual estimate bump. The data study (see Approach) shows these were normal
estimation error, not over-scope. **Stance reversal (deliberate):** an earlier
draft of THIS TDD stated "the declared per-file bound stays a hard cap — estimate
accuracy is the discipline"; Component 4 reverses that on the strength of the
~1.5× systematic-bias measurement. No PRD requirement is contradicted: FR-53/FR-54
govern the DESIGN-TIME declared bound (unchanged — still ≤300, refused by the
design gate per FR-55), and FR-67(b) names the runtime escalation whose *threshold*
this gap-closure tunes; the requirement's intent (catch genuinely over-ambitious
per-file change) is served better by a threshold calibrated to real data than by
one that fires on every normally-biased estimate.

## Decisions to promote (ADR candidates)

None. Refinements within ADR 0007's halt model and ADR 0005's prompt-driven gate
scope; no new cross-cutting decision.

## Touched files

- `scripts/lib/gates.sh` — call `_decrement_rework_attempt` on the two scope-rejection escalation sites; read the swept finding's summed span for the scope cap; the Component 4 `actual > num × K` tolerance in `_rework_pre_pass` (guarded knob + awk multiply + factor in the diagnostic).
- `scripts/lib/state.sh` — `_decrement_rework_attempt` fragment-mutator helper (atomic compact, error-checked, floored at 0).
- `scripts/review-prompt.md` — binding-rule-sweep instruction (enumerate all violating regions of one binding rule in one finding).
- `skills/tdd-author/SKILL.md` — estimate-padding heuristic in the `## Expected diff size` authoring block (advisory multipliers: test/eval ≈1.6×, shell-lib ≈1.4×) (Component 5).
- `skills/implement/SKILL.md` — required same-commit doc-sync: the implement behavior spec describes the bounded-rework budget + structural(b) escalation that Components 1/4 change, so it is updated in lockstep (no behavior of its own added).
- `tests/bounded-rework-convergence.test.sh` — new eval (rollback accounting + sweep-rule presence + scope read + K-tolerance threshold + heuristic presence).
- `tests/bounded-rework-loop.test.sh` — update the existing bounded-rework eval whose (b)-escalation / budget-accounting expectations change under Components 1/4 (the K-tolerance + counter rollback).
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Total: 8 files touched.

## Expected diff size

- `scripts/lib/gates.sh` — ~48 lines (two `_decrement_rework_attempt` calls + telemetry note + summed-span read for the scope cap + the Component 4 K-tolerance comparison, knob guard, and diagnostic).
- `scripts/lib/state.sh` — ~45 lines (`_decrement_rework_attempt` helper: atomic compact-JSON read-modify-write, floored at 0, error-checked).
- `scripts/review-prompt.md` — ~24 lines (binding-rule-sweep instruction block).
- `skills/tdd-author/SKILL.md` — ~16 lines (estimate-padding heuristic block).
- `skills/implement/SKILL.md` — ~15 lines (doc-sync of the budget/(b)-escalation behavior spec; no new behavior).
- `tests/bounded-rework-convergence.test.sh` — ~420 lines (exception: one cohesive convergence eval — 11+ cases sharing the same harness/stub/fixture setup, over the 300 per-file cap; splitting would fragment the shared setup). (rollback on (b)/scope-exceeded, counted-when-shipped, (c)-unchanged, floor, sweep-present, sweep-scope, K within-tolerance pass, K beyond-tolerance escalate, K knob-override + malformed-fallback, heuristic-present; fail-closed assertions.)
- `tests/bounded-rework-loop.test.sh` — ~10 lines (update the (b)-escalation / budget-accounting expectations for the K-tolerance + rollback).
- `tests/implement-gate.test.sh` — ~20 lines (aggregator wire-in).

Total expected diff: ~598 lines across 8 files. One per-file exception declared (`tests/bounded-rework-convergence.test.sh`, a single cohesive convergence eval over the 300-line per-file bound); every other file is under 300.

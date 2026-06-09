# TDD 0038: Mechanical per-step test-first enforcement

Status: draft
PRD refs: FR-15 (gap-closure: FR-15(a) enforcement)
PRD-rev: d289607
ADR constraints: 0005, 0006, 0007

> **Split note (blocker resolution).** The original 0038 also carried the
> per-step learning-capture (FR-72/73) as "Component 4". A build of that TDD
> BLOCKED: persisting the per-step findings requires modifying
> `scripts/lib/state.sh` (fragment carry-forward) — a file the TDD never
> declared — and the combined change exceeded the 8-file scope bound. The
> learning-capture half is now **[[0042]]** (per-step BLOCK learning capture),
> which stacks on this TDD. This TDD is FR-15(a) per-step *enforcement* only.

## Approach

FR-15(a) requires failing-test-first discipline — "a `test(failing):` commit
precedes the implementation, following `superpowers:test-driven-development`" —
and gates it mechanically. But that mechanical gate (`test_first_ok`,
`scripts/lib/gates.sh`) runs ONCE, over the whole build (`build-start..HEAD`).
Per *step*, the only enforcement is whether the model per-step reviewer
(`_run_per_step_review`) happens to notice impl-first ordering.

Measured across ~15 recent runs in `docs/tdd/.implement-logs/`: a genuine
failing-test-first violation (a BLOCK or flagged `after-the-fact-test` /
`missing-test-first` finding, not the checklist boilerplate every review log
prints) occurred in **9 of ~15 builds (~60%)**, and recurred *within* single
builds even after being caught (0033 at steps 1/3/5; 0022, 0023, 0034 twice
each). No untested code shipped — the four gates plus per-step review catch every
instance — but enforcement is **reactive and model-dependent**: the slip is
committed, then a later review BLOCK forces a revert→redo, repeatedly.

This TDD tightens *enforcement* of FR-15(a). The requirement (the "what") is
unchanged; this is the "how". Three coupled surfaces:

1. **Mechanical per-step pre-check** (`gates.sh`) — before the model per-step
   review runs, a deterministic git-history check on the step's commit range. A
   step that introduces new behavior with no `test(failing):` precursor (and no
   declared per-step skip) gets a `STEP_REVIEW: BLOCK` with **no model spawn**.
2. **Preventive self-gate** (`build-prompt.md`) — the build self-verifies the
   ordering *before* emitting `STEP_COMMIT`, turning reactive catch-and-revert
   into prevention at the source.
3. **Aggregator wire-in rule** (`build-prompt.md`) — standardize the gray zone
   that caused reviewer disagreement: wiring a new eval into the CI aggregator is
   new gating behavior and requires a failing wire-in test (not `SKIPPED`).

**Default-on, and what it breaks (the honest part).** The per-step pre-check
honors the SAME `THROUGHLINE_REQUIRE_TEST_FIRST` knob as the whole-build gate,
and like that gate it is **on by default**. Turning it on is NOT additive to the
existing test suite: four existing fixtures
(`tests/continuous-in-build-review.test.sh`,
`tests/build-defensive-norms.test.sh`, `tests/step-commit-protocol.test.sh`,
`tests/coproc-verdict-resilience.test.sh`) drive `_per_step_review_loop` with
`step(N): work` commits that have **no** `test(failing):` precursor — they
exercise the coproc/handshake/protocol/review mechanics, for which test-first
ordering is irrelevant. Under default-on per-step enforcement each would now hit
the deterministic BLOCK before reaching the path it asserts. The resolution
(Component 4 below) is to make those four fixtures **export
`THROUGHLINE_REQUIRE_TEST_FIRST=0`**, since the test-first dimension is
orthogonal to what they test; the new eval (`tests/test-first-per-step.test.sh`)
is then the sole knob-ON exerciser of the pre-check.

ADR alignment: **0006** — the per-step verdict is grounded in verifiable
artifacts (git commit order + the STEP_COMMIT sentinel), never author
self-report; **0005** — it is runner-side downstream detection, not a sandbox;
**0007** — a per-step test-first BLOCK rides the *existing* per-step
`STEP_REVIEW: BLOCK` → build-fixes-and-re-emits path, introducing no new halt
type and not touching the bounded-rework loop (which runs only against the
consolidated review, TDD 0019/0020).

## Components & interfaces

### 1. Per-step mechanical test-first pre-check — `scripts/lib/gates.sh`

- **New helper `_test_first_ok_range <base> <head> <skip_present>`.** Returns 0
  when `git log --format='%s' <base>..<head>` contains a commit subject matching
  `^test\(failing\)` **case-insensitively** (`grep -qiE` — identical to the
  existing `test_first_ok`, gates.sh:556, so the refactor preserves the
  whole-build gate's exact matching semantics), OR `<skip_present>` equals the
  literal `1`; returns 1 otherwise. Git-history only (ADR 0006). The existing
  whole-build `test_first_ok` is refactored to delegate to it
  (`_test_first_ok_range "$base" HEAD "$skip"` where `$skip=1` iff a whole-build
  `TEST_FIRST: SKIPPED` log line is present), so the two share one definition of
  "a `test(failing):` precursor exists". The per-step caller (below) passes
  `<skip_present>` from the per-step `TEST_FIRST_SKIPPED:` sentinel ONLY — it does
  NOT consult the whole-build `TEST_FIRST: SKIPPED` log line, since a whole-build
  skip must not silently satisfy a per-step range check.
- **Wiring in `_per_step_review_loop`** (the `STEP_COMMIT` branch, after `step_id`
  + `sha` parse, BEFORE `_run_per_step_review`):
  - Parse the OPTIONAL per-step skip token **off the extracted sentinel match,
    NOT off the raw `$text`** (review:1 blocker fix). `$text` is the full
    multi-line assistant event (that is why `step_id`/`sha` are themselves
    `grep -aoE … | tail -1`'d out of it), so an unanchored
    `case "$text" in *"TEST_FIRST_SKIPPED:"*)` would match a *prose* mention of
    the token anywhere in the turn and silently disable the gate — a build that
    writes "I am not using TEST_FIRST_SKIPPED here" before its real sentinel would
    bypass the deterministic BLOCK. The skip token MUST therefore be read from the
    SAME single sentinel line the step-id/sha came from. Extend the existing
    extractor with an OPTIONAL trailing-token group and capture the chosen
    sentinel once:
    `sentinel="$(printf '%s' "$text" | grep -aoE 'STEP_COMMIT:[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+([[:space:]]+TEST_FIRST_SKIPPED:[^[:space:]]+)?' | tail -1)"`,
    then `skip_present=0; case "$sentinel" in *"TEST_FIRST_SKIPPED:"*) skip_present=1 ;; esac`,
    and read the `<reason>` for telemetry with
    `printf '%s' "$sentinel" | grep -aoE 'TEST_FIRST_SKIPPED:[^[:space:]]+'`. Because
    the match is the same `tail -1` sentinel used for step-id/sha, a prose mention
    elsewhere in the turn cannot reach it. The step-id/sha extractor is unchanged
    and **backward-compatible with the TDD 0032 parser**: the optional group is at
    the END, so for a sentinel with no token the match is byte-identical to today's
    three-token form, and the malformed/protocol-error branch (which keys on a `<`
    placeholder or an unparseable step-id) is never reached.
  - Resolve the per-step base = the SAME base `_run_per_step_review` uses for this
    step: the fragment's `last_cleared_review_sha` if set, else `build_start`
    (gates.sh:720–721's derivation). When `STATE_DIR` is unset or the fragment is
    absent (the `THROUGHLINE_SOURCE_ONLY` test path), the base falls back to
    `build_start`, so the pre-check degrades gracefully exactly as the existing
    per-step review does.
  - Call `_test_first_ok_range "$base" "$sha" "$skip_present"`. Honors
    `THROUGHLINE_REQUIRE_TEST_FIRST` (the same env knob as the whole-build gate):
    when `0`, the pre-check is a no-op (returns 0).
    - **Fail** (no `test(failing):` precursor in `<base>..<sha>`, `skip_present=0`):
      set `verdict` to a fixed deterministic line —
      `STEP_REVIEW: BLOCK test-first: step <id> commits implementation in <base>..<sha> with no preceding test(failing): commit (FR-15a). Add the failing test as a separate test(failing): <behavior> commit, then re-emit STEP_COMMIT: <id> <new-sha> for the same step. If this step is genuinely no-new-behavior, re-emit as STEP_COMMIT: <id> <sha> TEST_FIRST_SKIPPED:<reason>.` —
      write it to the build's stdin via the existing `_coproc_write` path (same
      SIGPIPE-safe, clock-pause handling as the review-verdict write), and
      `continue` the loop. **No review `claude -p` is spawned** (deterministic +
      token-saving). **Recording-site marker (for [[0042]]):** this is one of the
      two per-step BLOCK sites where 0042 adds `step_block_log` recording; this
      TDD writes the verdict only and records nothing.
    - **Pass:** fall through to `_run_per_step_review` exactly as today.

### 2. Preventive self-gate — `scripts/build-prompt.md`

In the four-step STEP_COMMIT handshake, before step 3 (emit `STEP_COMMIT`), add a
self-verification bullet: the build runs
`git log --format='%s' <last-cleared-or-build-start>..HEAD | grep '^test(failing)'`
and, if this step introduced new behavior but no `test(failing):` precedes the
implementation commit, it MUST add the failing test as a separate `test(failing):`
commit (fixing the order) BEFORE emitting the sentinel. Only a genuine
no-new-behavior step emits `STEP_COMMIT: <id> <sha> TEST_FIRST_SKIPPED:<reason>`.
This makes the build catch its own slip before the runner round-trip; §1 is the
mechanical backstop if it does not.

### 3. Aggregator wire-in rule — `scripts/build-prompt.md`

Add a precise rule under "FAILING TEST FIRST": wiring a new eval into the CI
aggregator (`tests/implement-gate.test.sh`) is **new gating behavior** — it adds a
`*_FAIL` accumulator to the gate's final AND-chain, so the aggregator now exits
non-zero on a new condition. It is **NOT** `TEST_FIRST: SKIPPED`-eligible. The
wire-in's `test(failing):` asserts the aggregator's overall exit goes non-zero
when the newly-wired eval fails (drive the aggregator with the new eval stubbed to
fail; assert the final pass/fail expression is non-zero) BEFORE adding the
wire-in that makes it pass. Only pure no-op glue that does not change the
AND-chain may `SKIP`. This standardizes the reviewer-disagreement source on
enforce.

### 4. Fixture reconciliation (default-on non-regression) — 4 existing tests

Each of the four fixtures that drive `_per_step_review_loop` with impl-only
`step(N): work` commits exports `THROUGHLINE_REQUIRE_TEST_FIRST=0` once, near the
top (after the `THROUGHLINE_SOURCE_ONLY` source of `gates.sh`), with a one-line
comment stating WHY (this fixture exercises coproc/protocol/review mechanics, not
test-first ordering; the orthogonal per-step gate is disabled so the default-on
pre-check from TDD 0038 §1 does not pre-empt the path under test):

- `tests/continuous-in-build-review.test.sh` — §2 handshake cases (c1–c9, E1)
  drive the loop with `step(N): work`.
- `tests/build-defensive-norms.test.sh` — e4 / e4p / e5 cases.
- `tests/step-commit-protocol.test.sh` — the `x5` real-sentinel case
  (`STEP_COMMIT: 1`); the malformed `5b`/`<…>` cases never parse a step-id so the
  pre-check is unreached, but the export is set once for the whole file for
  uniformity.
- `tests/coproc-verdict-resilience.test.sh` — s1 / s7a / s7b cases.

The export is at file scope (not per-invocation) because none of these fixtures
asserts test-first behavior; a single top-level export is the smallest honest
change and cannot mask a real regression (the dedicated eval covers the gate ON).

## Data & state

No run-state schema change in this TDD. The per-step pre-check reads git history
and the STEP_COMMIT sentinel only; it writes a verdict to the build's stdin (the
existing `_coproc_write` path) and persists nothing. The `step_block_log`
fragment field and its persistence/mining are **[[0042]]**, not here. The
whole-build `test_first_ok` gate, the flip verdict, and the halt taxonomy are
untouched.

## Sequencing / implementation plan

1. Factor `_test_first_ok_range` from `test_first_ok` and wire the per-step
   pre-check into `_per_step_review_loop` (Component 1), including the
   **sentinel-anchored** optional `TEST_FIRST_SKIPPED:` parse (read off the single
   `tail -1` extracted sentinel, never the raw multi-line `$text`) and the
   deterministic no-model BLOCK.
2. Add the preventive self-gate bullet and the aggregator wire-in rule to
   `build-prompt.md` (Components 2 + 3).
3. Add `export THROUGHLINE_REQUIRE_TEST_FIRST=0` (with the why-comment) to the
   four existing per-step-loop fixtures (Component 4).
4. Add the eval `tests/test-first-per-step.test.sh` (per-step routing, skip
   token, sentinel compat, fixture-non-regression); wire the new eval into
   `tests/implement-gate.test.sh` — the wire-in itself carries a `test(failing):`
   asserting the aggregator exits non-zero when the new eval is stubbed to fail
   (dogfooding Component 3).

## Failure modes & edge cases

- **Step with no new behavior and no skip token.** The pre-check BLOCKs (no
  `test(failing):` precursor). Correct posture: the build either adds a test or
  re-emits with `TEST_FIRST_SKIPPED:<reason>` — the safe direction is to make the
  build justify the skip explicitly rather than silently pass impl-first.
- **`test(failing):` exists but outside this step's range** (committed in a prior
  cleared step). `_test_first_ok_range` scopes to `<base>..<sha>` where `base`
  is the last-cleared SHA, so a stale prior `test(failing):` does NOT satisfy the
  current step — matching the per-step review's own scope (TDD 0020).
- **Malformed skip token** (`TEST_FIRST_SKIPPED:` with no reason). The step-id +
  sha still parse (token ignored by the 0032 extractor); `skip_present=1` and the
  build proceeds. The empty `<reason>` is the build's responsibility to make
  meaningful; the human / consolidated gate still sees an impl-only range.
- **Prose mention of the token before the sentinel** (review:1 blocker). A build
  that writes `TEST_FIRST_SKIPPED:` in narrative text earlier in the same turn,
  then emits a real impl-only `STEP_COMMIT` with no token, must STILL be BLOCKed.
  Because `skip_present` is read from the single extracted sentinel match (the
  `tail -1` of the anchored `STEP_COMMIT: <id> <sha>[ TEST_FIRST_SKIPPED:<reason>]`
  regex), not from the raw `$text`, the prose mention is unreachable and the gate
  holds. Verified by observation point §8.
- **`THROUGHLINE_REQUIRE_TEST_FIRST=0`** (a batch of pure refactors, OR the four
  reconciled fixtures). The per-step pre-check no-ops exactly as the whole-build
  gate does — one knob, both scopes.
- **Coproc died during the (no-)review window.** The deterministic BLOCK is
  written through `_coproc_write`; a dead coproc breaks to the post-loop
  classifier identically to the existing verdict-write path (TDD 0030 §1).

## Verification plan

**Observable surface:** (a) the runner's per-step decision — observable as a
`STEP_REVIEW: BLOCK test-first:` line written to the build (and the absence of a
spawned review process) vs. a normal per-step review; (b) `build-prompt.md` text;
(c) the four reconciled fixtures still pass under default-on enforcement.

**Observation points** (mechanical, `tests/test-first-per-step.test.sh` with stub
fixtures following `tests/bounded-rework-loop.test.sh`'s harness):

1. **Impl-first step → deterministic BLOCK, no model spawn.** Drive
   `_per_step_review_loop` with a `STEP_COMMIT` whose `<base>..<sha>` range has an
   implementation commit but no `test(failing):` precursor and no skip token
   (knob ON). Expected: a `STEP_REVIEW: BLOCK test-first:` line is written; the
   review `claude -p` stub records ZERO invocations.
2. **test(failing): precursor → pass-through to model review.** Same step but with
   a `test(failing):` commit before the impl in range. Expected: no test-first
   BLOCK; `_run_per_step_review` (model stub) IS invoked once.
3. **`TEST_FIRST_SKIPPED:` token → pass-through.** Impl-only range but the
   sentinel carries `TEST_FIRST_SKIPPED:no-new-behavior`. Expected: no test-first
   BLOCK; the model review runs.
4. **Sentinel backward-compat.** A `STEP_COMMIT: 2 <sha> TEST_FIRST_SKIPPED:x`
   line parses to `step_id=2`, `sha=<sha>` (assert both) and does NOT increment
   the protocol-error counter.
5. **Knob OFF → no-op.** With `THROUGHLINE_REQUIRE_TEST_FIRST=0`, an impl-only
   range passes through to the model review (no test-first BLOCK) — proving the
   fixture-reconciliation escape works.
6. **Aggregator wire-in rule present.** Grep `build-prompt.md` for the wire-in
   rule text (aggregator wire-in is new gating behavior; not SKIPPED-eligible).
7. **Fixture non-regression.** The four reconciled fixtures
   (`continuous-in-build-review`, `build-defensive-norms`, `step-commit-protocol`,
   `coproc-verdict-resilience`) run green under the default (knob unset → ON),
   each carrying the `THROUGHLINE_REQUIRE_TEST_FIRST=0` export — driven by
   `ci-checks.sh` / `tests/implement-gate.test.sh` on the build branch.
8. **Prose-mention does not bypass the gate (review:1 blocker).** Drive a
   `STEP_COMMIT` whose event `$text` contains a narrative `TEST_FIRST_SKIPPED:`
   line BEFORE the real sentinel, where the sentinel itself carries NO token and
   the range is impl-only (knob ON). Expected: `skip_present=0`, a
   `STEP_REVIEW: BLOCK test-first:` line is written (the prose mention is NOT read
   off the raw `$text`), and zero review spawns.

**Mechanical-check robustness (folds in L-001 / L-002).** Every grep-based
assertion in the new eval (i) anchors on a SPECIFIC new string (no vacuous match
on pre-existing content) and (ii) **fails closed on grep exit ≥2 / an unreadable
fixture** — distinguishing exit 1 (string legitimately absent) from exit ≥2
(error), and emitting a DISTINCT infra-failure diagnostic rather than a content
`bad()` when a fixture file is missing. (Recurrence guard: `fragile-inversion-pattern`
L-001; `misleading-diagnostic` L-002.)

**Expected observations (PASS):** every numbered point yields the cited behavior.

## Evaluation rubric

| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | every FR (15a/72/73) + ADR (0005/6/7) maps to a named element; gaps noted | all in-scope reqs mapped | any untraced requirement |
| Mechanical determinism (ADR 0006) | per-step gate reads git/sentinel artifacts only; BLOCKs without spawning the model | artifact-only, no model judgment | relies on model judgment for the verdict |
| Protocol backward-compat | STEP_COMMIT extension shown compatible against 0032 exact parse path | compat asserted | unaddressed or breaks the parser |
| Fragment-persistence correctness | step_block_log carry-forward preserves across all 8 writers; reader anchor invariant restated | preserve-on-absent + reader specified | drops field on carry-forward / breaks cleared_step_log anchor |
| Cross-TDD coupling | 0042 edits to 0038 BLOCK sites named; stack order satisfies dependency | dependency stated | hidden/contradictory coupling |
| Verification-plan actionability | per-component observation points with exact commands/fixtures | surface + points + expected obs named | vague / no concrete observation point |
| Scope-bound adherence | comfortably within bounds, all files declared | within bounds, exceptions declared inline | over-bound without exception |
| Naming consistency | one canonical name for sentinel token, helpers, pattern_tag across files + tests | consistent | same concept named two ways |

(Rows for FR-72/73, `step_block_log` persistence, and cross-TDD coupling are
graded against **[[0042]]**; the rubric is shared across the set so each TDD is
self-contained for its per-TDD review.)

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-15 (gap-closure: FR-15(a) per-step enforcement of failing-test-first) | Component 1 (mechanical per-step pre-check) + Component 2 (preventive self-gate) + Component 3 (aggregator wire-in rule) + Component 4 (default-on fixture reconciliation). Verification §1–§7. |

No gaps. FR-72 / FR-73 (per-step BLOCK findings reaching the miner and thereby
`/tdd-author`) are deferred to **[[0042]]**, which stacks on this TDD's per-step
BLOCK sites.

## Dependencies considered

No new external or internal dependency. The change reuses the existing
`_per_step_review_loop`, `_run_per_step_review`, `_coproc_write`, and
`test_first_ok` surfaces.

Alternatives considered:
- **Per-step gate OFF by default** — rejected: it would defeat FR-15(a)
  enforcement (the ~60% slip rate is *with* the prompt already present); the
  point is a default-on mechanical backstop. The four orthogonal fixtures opt out
  explicitly instead (Component 4).
- **Gate the pre-check on `STATE_DIR` presence to spare the fixtures** — rejected:
  it creates a silent enforcement blind-spot — a real build that transiently lost
  `STATE_DIR` would skip test-first entirely. Per-fixture opt-out keeps the gate
  honest and the escape explicit.
- **Keep enforcement model-only, just strengthen the prompt** — rejected: the
  measured ~60% slip rate is *with* the prompt instruction already present; a
  mechanical, artifact-grounded gate (ADR 0006) is what makes the verdict
  deterministic and token-free, rather than depending on the reviewer noticing.

## PRD conflicts surfaced (and resolution)

Resolves the open `docs/tdd/BLOCKERS.md` entry for 0038 (2026-06-08): the build
found (1) `step_block_log` persistence needs `scripts/lib/state.sh`, undeclared,
and (2) the default-on per-step pre-check regresses four existing fixtures,
contradicting the "additive/no-break" premise. Resolution: split the persistence
+ mining half into **[[0042]]** (which declares `state.sh`), and replace the
false premise with an explicit default-on reconciliation (Component 4) that opts
the four orthogonal fixtures out of the gate. FR-15(a) itself is unchanged (the
"what"); this remains the "how".

## Decisions to promote (ADR candidates)

None. The change refines enforcement within the established gate-architecture
(ADR 0005/0006) and halt model (ADR 0007); it introduces no new cross-cutting
decision.

## Touched files

The eight files below are the design scope. The build ALSO applies two
mechanical, non-design changes that ride the same commit and are NOT counted
here (mirroring how the runner's `plugin.json` version bump is never a declared
design surface): a build-mandated **doc-sync** to `README.md` (~7 lines: add
`test-first-per-step.test.sh` to the `tests/` file-tree listing + one sentence on
per-step enforcement under the failing-test-first gate) and the `plugin.json`
version bump. Neither is a design decision; the runtime structural check
(FR-67) does not flag them (it gates per-file diff of the declared set and
rework that strays outside it, not build-applied doc/version sync).

- `scripts/lib/gates.sh` — `_test_first_ok_range` helper; per-step pre-check + anchored `TEST_FIRST_SKIPPED:` sentinel parse in `_per_step_review_loop`; deterministic no-model BLOCK (no recording — that is 0042).
- `scripts/build-prompt.md` — preventive self-gate bullet (Component 2) + aggregator wire-in rule (Component 3).
- `tests/test-first-per-step.test.sh` — new eval (per-step routing, skip token, sentinel compat, knob-off no-op, prose-mention anchoring, fixture-non-regression, aggregator dogfood).
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator (with its failing wire-in test per Component 3).
- `tests/continuous-in-build-review.test.sh` — `THROUGHLINE_REQUIRE_TEST_FIRST=0` export (orthogonal-gate opt-out).
- `tests/build-defensive-norms.test.sh` — `THROUGHLINE_REQUIRE_TEST_FIRST=0` export.
- `tests/step-commit-protocol.test.sh` — `THROUGHLINE_REQUIRE_TEST_FIRST=0` export.
- `tests/coproc-verdict-resilience.test.sh` — `THROUGHLINE_REQUIRE_TEST_FIRST=0` export.

Total: 8 design files touched (+ build-applied `README.md` doc-sync and `plugin.json` version bump, not design scope).

## Expected diff size

- `scripts/lib/gates.sh` — ~90 lines added/changed (helper + anchored loop wiring + the long fixed BLOCK message; no recording).
- `scripts/build-prompt.md` — ~22 lines added (self-gate + wire-in rule).
- `tests/test-first-per-step.test.sh` — ~330 lines added (exception: a single cohesive per-step test-first eval — 9 observation points incl. the security-relevant prose-mention anchoring case §9, all sharing one stub-claude/handshake harness; splitting would fragment shared fixture setup and is more brittle than the marginal over-300 size).
- `tests/implement-gate.test.sh` — ~18 lines added (aggregator wire-in + its failing test).
- `tests/continuous-in-build-review.test.sh` — ~8 lines added (export + comment).
- `tests/build-defensive-norms.test.sh` — ~8 lines added (export + comment).
- `tests/step-commit-protocol.test.sh` — ~9 lines added (export + comment).
- `tests/coproc-verdict-resilience.test.sh` — ~8 lines added (export + comment).

Total expected diff: ~493 lines across 8 design files (all under the 300-line per-file bound except `test-first-per-step.test.sh`, which declares an inline exception above). Build-applied `README.md` (~7 lines) + `plugin.json` bump ride the commit, not counted.

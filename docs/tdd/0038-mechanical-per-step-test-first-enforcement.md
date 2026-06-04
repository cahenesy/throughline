# TDD 0038: Mechanical per-step test-first enforcement

Status: draft
PRD refs: FR-15 (gap-closure: FR-15(a) enforcement), FR-72, FR-73
PRD-rev: d289607
ADR constraints: 0005, 0006, 0007

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
unchanged; this is the "how". Four coupled surfaces:

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
4. **Miner blind-spot fix** (`learnings.sh`) — per-step BLOCK findings are never
   recorded to a mined location, so recurring per-step classes
   (`failing-test-first-violation`, `after-the-fact-test`) are invisible to
   FR-72. Record them and mine them, so the pattern flows to `/tdd-author`
   (FR-73).

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
  - Parse the OPTIONAL per-step skip token off the sentinel text:
    `skip_present=0; case "$text" in *"TEST_FIRST_SKIPPED:"*) skip_present=1 ;; esac`.
    The token is read with `grep -aoE 'TEST_FIRST_SKIPPED:[^[:space:]]+'` for its
    `<reason>` (telemetry). `$text` here is ALREADY the extracted STEP_COMMIT
    event text (the loop is inside the `*"STEP_COMMIT: "*` branch), so the match
    is structurally confined to the sentinel line — no extra line-anchoring is
    needed and a prose mention elsewhere in the build's output cannot reach it.
    This is additive to the sentinel and
    **backward-compatible with the TDD 0032 parser**: the `STEP_COMMIT:` step-id
    + sha extractor (`grep -aoE 'STEP_COMMIT:[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+'`)
    matches the first three tokens and ignores any trailing token, so the
    extended form parses cleanly and never reaches the malformed/protocol-error
    branch (which keys on a `<` placeholder or an unparseable step-id).
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
      SIGPIPE-safe, clock-pause handling as the review-verdict write), record the
      block (§4), and `continue` the loop. **No review `claude -p` is spawned**
      (deterministic + token-saving).
    - **Pass:** fall through to `_run_per_step_review` exactly as today.
  - A `TEST_FIRST_SKIPPED:` step is recorded to the fragment as telemetry (§4,
    `skipped:true`) so a build that skips every step is observable to the human /
    consolidated gate.

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

### 4. Miner blind-spot fix — `scripts/lib/gates.sh` + `scripts/lib/learnings.sh`

- **Recording (`gates.sh`).** Per-step BLOCK findings are currently persisted
  nowhere the miner reads (`findings` = consolidated + rework only;
  `cleared_step_log` = *passing* review tags). Add a per-fragment array
  `step_block_log`, appended on every per-step BLOCK:
  - the §1 mechanical BLOCK appends
    `{"pass_id":"step-<id>","severity":"major","pattern_tags":["failing-test-first-violation"],"summary":"no test(failing): precursor for step <id>","skipped":false}`;
  - `_run_per_step_review`'s model BLOCK appends an entry whose `pattern_tags` are
    harvested from the review log via the existing `_extract_pattern_tags`, with a
    fixed `severity:"major"` (a per-step BLOCK is by definition a halting finding;
    the review-log line carries only the top-level `REVIEW_RESULT:` verdict, not a
    per-finding severity, so no per-finding severity extraction is invented), and
    `summary` a one-line excerpt of the BLOCK reason;
  - a `TEST_FIRST_SKIPPED:` step appends `{"pass_id":"step-<id>","skipped":true,...}`
    (telemetry only; not mined).
  Recording is additive — readers that do not know `step_block_log` (status.sh,
  TDD 0023) ignore it (NFR-4: no existing consumer breaks).
- **Mining (`learnings.sh`).** `detect_build_learnings` gains a second corpus
  pass: after the `findings` loop, for each fragment it reads `step_block_log`
  (new helper `_read_fragment_step_blocks`, mirroring `_read_fragment_findings`;
  an absent or empty `step_block_log` returns the empty string and the loop skips
  that fragment, exactly as `_read_fragment_findings` does for one with no
  findings) and folds each non-skipped, non-nit entry's `pattern_tags` into the SAME
  per-class accumulators (`C_slugs`/`C_steps`/`C_sevmin`/…). The existing
  per-class distinct-TDD dedup (`C_slugs`) means a class appearing in both
  `findings` and `step_block_log` for one TDD counts that TDD once; the threshold
  (`_learnings_min`, ≥2 distinct TDDs) is unchanged. Result: a per-step class such
  as `failing-test-first-violation` that recurs across ≥2 TDDs surfaces as a
  candidate learning (FR-72) and thereby reaches `/tdd-author` (FR-73).

## Data & state

One additive per-fragment field, `step_block_log` (a JSON array, default `[]`),
in each `state.d/<slug>.json` fragment. It is write-only telemetry consumed only
by `detect_build_learnings`; no run-state status/stage transition depends on it,
and no existing reader is changed. No run.json schema change. The whole-build
`test_first_ok` gate, the flip verdict, and the halt taxonomy are untouched.

## Sequencing / implementation plan

1. Factor `_test_first_ok_range` from `test_first_ok` and wire the per-step
   pre-check into `_per_step_review_loop` (Component 1), including the optional
   `TEST_FIRST_SKIPPED:` sentinel parse and the deterministic no-model BLOCK.
2. Add the `step_block_log` recording at both per-step BLOCK sites — the §1
   mechanical BLOCK and `_run_per_step_review`'s model BLOCK (Component 4,
   recording half).
3. Extend `detect_build_learnings` with the `step_block_log` corpus pass and add
   `_read_fragment_step_blocks` (Component 4, mining half).
4. Add the preventive self-gate bullet and the aggregator wire-in rule to
   `build-prompt.md` (Components 2 + 3).
5. Add the eval `tests/test-first-per-step.test.sh` and the miner-extension cases
   in `tests/build-phase-learning-capture.test.sh`; wire the new eval into
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
  sha still parse (token ignored by the 0032 extractor); `skip_present=1` but the
  empty `<reason>` is recorded as `unspecified`. The build proceeds; the human /
  consolidated gate sees an unjustified skip in `step_block_log`.
- **`THROUGHLINE_REQUIRE_TEST_FIRST=0`** (a batch of pure refactors). The
  per-step pre-check no-ops exactly as the whole-build gate does — one knob, both
  scopes.
- **Coproc died during the (no-)review window.** The deterministic BLOCK is
  written through `_coproc_write`; a dead coproc breaks to the post-loop
  classifier identically to the existing verdict-write path (TDD 0030 §1).
- **Per-step BLOCK that never clears** (build fails before re-emitting). The
  `step_block_log` entry is already persisted at BLOCK time, so the violation is
  mineable even though the step never reached `cleared_step_log`.

## Verification plan

**Observable surface:** (a) the runner's per-step decision — observable as a
`STEP_REVIEW: BLOCK test-first:` line written to the build (and the absence of a
spawned review process) vs. a normal per-step review; (b) `build-prompt.md` text;
(c) the `step_block_log` array in a fragment; (d) `detect_build_learnings` output
(a candidate-learnings entry for a recurring per-step class).

**Observation points** (mechanical, `tests/test-first-per-step.test.sh` with stub
fixtures following `tests/bounded-rework-loop.test.sh`'s harness, and miner cases
in `tests/build-phase-learning-capture.test.sh`):

1. **Impl-first step → deterministic BLOCK, no model spawn.** Drive
   `_per_step_review_loop` with a `STEP_COMMIT` whose `<base>..<sha>` range has an
   implementation commit but no `test(failing):` precursor and no skip token.
   Expected: a `STEP_REVIEW: BLOCK test-first:` line is written; the review
   `claude -p` stub records ZERO invocations; a `step_block_log` entry with
   `pattern_tags:["failing-test-first-violation"]` is appended.
2. **test(failing): precursor → pass-through to model review.** Same step but with
   a `test(failing):` commit before the impl in range. Expected: no test-first
   BLOCK; `_run_per_step_review` (model stub) IS invoked once.
3. **`TEST_FIRST_SKIPPED:` token → pass-through, recorded skipped.** Impl-only
   range but the sentinel carries `TEST_FIRST_SKIPPED:no-new-behavior`. Expected:
   no test-first BLOCK; the model review runs; `step_block_log` records
   `skipped:true` with the reason.
4. **Sentinel backward-compat.** A `STEP_COMMIT: 2 <sha> TEST_FIRST_SKIPPED:x`
   line parses to `step_id=2`, `sha=<sha>` (assert both) and does NOT increment
   the protocol-error counter.
5. **Miner surfaces the recurring per-step class.** Two stub fragments each with a
   `step_block_log` entry tagged `failing-test-first-violation`. Expected:
   `detect_build_learnings` emits a candidate-learnings class naming that tag,
   `distinct_tdds` = 2; a single fragment with one such entry emits nothing
   (threshold unchanged).
6. **Aggregator wire-in rule present.** Grep `build-prompt.md` for the wire-in
   rule text (aggregator wire-in is new gating behavior; not SKIPPED-eligible).

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
| Requirement traceability | every FR (15a, 72, 73) + ADR (0005/6/7) maps to a named element; gaps noted | all in-scope reqs mapped | any untraced requirement |
| Mechanical determinism (ADR 0006) | per-step gate reads git/sentinel artifacts only; BLOCKs without spawning the model | artifact-only, no model judgment | relies on model judgment for the verdict |
| Protocol backward-compat | STEP_COMMIT extension shown compatible against 0032's exact parse path | compat asserted | unaddressed or breaks the parser |
| Verification-plan actionability | per-component observation points with exact commands/fixtures | surface + points + expected obs named | vague / no concrete observation point |
| Scope-bound adherence | comfortably within bounds, all files declared | within bounds, exceptions declared inline | over-bound without exception |
| Naming consistency | one canonical name for the sentinel token, helpers, pattern_tag across gates.sh/build-prompt.md/learnings.sh + tests | consistent | same concept named two ways |

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-15 (gap-closure: FR-15(a) per-step enforcement of failing-test-first) | Component 1 (mechanical per-step pre-check) + Component 2 (preventive self-gate) + Component 3 (aggregator wire-in rule). Verification §1–§4, §6. |
| FR-72 (recurring patterns surfaced as candidate learnings) | Component 4: per-step BLOCK findings recorded to `step_block_log` and mined by `detect_build_learnings`, closing the per-step blind spot. Verification §5. |
| FR-73 (accepted learnings inform `/tdd-author`) | Component 4 (mining half): once a per-step class is mineable and accepted, it persists to `LEARNINGS.md` and surfaces in future `/tdd-author` sessions — the unchanged FR-73 path. Verification §5 (mineability is the precondition). |

No gaps. (FR-73's surfacing mechanism itself is unchanged by this TDD; this TDD
only makes the per-step class *reach* the store, which is the missing link.)

## Dependencies considered

No new external or internal dependency. The change reuses the existing
`_per_step_review_loop`, `_run_per_step_review`, `_coproc_write`,
`_extract_pattern_tags`, `test_first_ok`, and `detect_build_learnings` surfaces.

Alternatives considered:
- **Mine `cleared_step_log` tags instead of adding `step_block_log`** — rejected:
  `cleared_step_log` records only *passing* review tags, so a test-first slip that
  is fixed then cleared carries the *passing* tags, not the violation; and a step
  that never clears (build failed) has no entry at all. The violation must be
  recorded at BLOCK time, which `cleared_step_log` does not do.
- **Inject per-step BLOCK findings into the existing `findings` array** —
  rejected: `findings` has consolidated/rework semantics that other readers
  (TDD 0023, the report) consume; overloading it with per-step entries risks
  semantic bleed. A dedicated additive array is lower-risk.
- **Keep enforcement model-only, just strengthen the prompt** — rejected: the
  measured ~60% slip rate is *with* the prompt instruction already present; a
  mechanical, artifact-grounded gate (ADR 0006) is what makes the verdict
  deterministic and token-free, rather than depending on the reviewer noticing.

## PRD conflicts surfaced (and resolution)

None. FR-15(a) already mandates failing-test-first "following
`superpowers:test-driven-development`"; this TDD implements *how* that mandate is
enforced per step and is therefore additive to the requirement, not a change to
it. No PRD edit is required (the "what" is unchanged; this is the "how").

## Decisions to promote (ADR candidates)

None. The change refines enforcement within the established gate-architecture
(ADR 0005/0006) and halt model (ADR 0007); it introduces no new cross-cutting
decision.

## Touched files

- `scripts/lib/gates.sh` — `_test_first_ok_range` helper; per-step pre-check + `TEST_FIRST_SKIPPED:` parse in `_per_step_review_loop`; `step_block_log` recording at both per-step BLOCK sites.
- `scripts/lib/learnings.sh` — `_read_fragment_step_blocks`; `step_block_log` corpus pass in `detect_build_learnings`.
- `scripts/build-prompt.md` — preventive self-gate bullet (Component 2) + aggregator wire-in rule (Component 3).
- `tests/test-first-per-step.test.sh` — new eval (per-step routing, skip token, sentinel compat, recording).
- `tests/build-phase-learning-capture.test.sh` — miner `step_block_log` mining cases.
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator (with its failing wire-in test per Component 3).

Total: 6 files touched.

## Expected diff size

- `scripts/lib/gates.sh` — ~70 lines added/changed (helper + loop wiring + recording at two sites).
- `scripts/lib/learnings.sh` — ~30 lines added (reader + corpus pass).
- `scripts/build-prompt.md` — ~28 lines added (self-gate + wire-in rule).
- `tests/test-first-per-step.test.sh` — ~165 lines added (new eval: 6 observation points with fail-closed grep guards).
- `tests/build-phase-learning-capture.test.sh` — ~30 lines added (miner mining cases).
- `tests/implement-gate.test.sh` — ~12 lines added (aggregator wire-in + its failing test).

Total expected diff: ~335 lines across 6 files. No exceptions needed (each file is under the 300-line per-file bound).

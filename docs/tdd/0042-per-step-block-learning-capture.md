# TDD 0042: Per-step BLOCK learning capture

Status: draft
PRD refs: FR-72, FR-73
PRD-rev: d289607
ADR constraints: 0005, 0006, 0007

> **Stacks on [[0038]].** This TDD records and mines the per-step `STEP_REVIEW:
> BLOCK` findings that 0038 introduces. It edits the two per-step BLOCK sites
> 0038 creates/uses in `_per_step_review_loop`, so it must build AFTER 0038
> (numeric order 0038 → … → 0042 satisfies this). It was split out of the
> original 0038 because per-step-finding persistence requires modifying
> `scripts/lib/state.sh` (fragment carry-forward) and the combined change
> exceeded the 8-file scope bound (see the 0038 blocker resolution).

## Approach

Per-step `STEP_REVIEW: BLOCK` findings are persisted **nowhere the learning
miner reads**. `detect_build_learnings` (FR-72) mines the `findings` array
(consolidated + rework only) and `cleared_step_log` records only *passing*
review tags. So a recurring per-step class — most importantly the
`failing-test-first-violation` that [[0038]]'s mechanical pre-check now BLOCKs,
but also any model per-step BLOCK — is invisible to FR-72 and therefore never
reaches `/tdd-author` (FR-73). A test-first slip that is BLOCKed, fixed, then
cleared carries the *passing* tags in `cleared_step_log`, not the violation; a
step that never clears (build failed) has no entry at all. The violation must be
recorded **at BLOCK time**.

This TDD adds a write-only per-fragment telemetry array, `step_block_log`,
appended on every per-step BLOCK, and extends the miner to fold it into the same
per-class accumulators it already uses for `findings`. Three components:

1. **Fragment persistence** (`scripts/lib/state.sh`) — a new cumulative
   `step_block_log` field with a reader, carry-forward, and append setter,
   following the exact FR-58/60 preserve-on-absent convention the `findings`
   ledger already uses.
2. **Recording** (`scripts/lib/gates.sh`) — append a `step_block_log` entry at
   both per-step BLOCK sites: 0038's deterministic mechanical BLOCK and
   `_run_per_step_review`'s model BLOCK.
3. **Mining** (`scripts/lib/learnings.sh`) — a second corpus pass in
   `detect_build_learnings` that reads each fragment's `step_block_log` and folds
   non-skipped entries' `pattern_tags` into the same per-class accumulators, with
   the existing ≥2-distinct-TDD threshold unchanged.

ADR alignment: **0006** — the recorded finding is grounded in the same verifiable
artifacts (git order, the STEP_COMMIT sentinel, the review log's pattern tags) the
verdict itself used; **0005** — runner-side telemetry, not a sandbox; **0007** —
recording is observational only: it does not change the per-step verdict, the
halt taxonomy, or the bounded-rework loop. Recording is additive and best-effort
— a reader that does not know `step_block_log` (status.sh, TDD 0023) ignores it,
and recording is skipped (never fatal) when `STATE_DIR` is unset.

## Components & interfaces

### 1. Fragment persistence — `scripts/lib/state.sh`

- **Field placement.** `step_block_log` (a JSON array, default `[]`) is inserted
  into `_write_tdd_fragment`'s printf **between `re_review_attempts` and
  `last_cleared_review_sha`**. This keeps `cleared_step_log` the LAST field, so
  `_read_fragment_cleared_log`'s greedy `}`-anchor invariant (state.sh:93–98) is
  preserved unchanged, and keeps `findings`' anchor (`,"self_review_count":`)
  unchanged.
- **New reader `_read_fragment_step_blocks <file>`** — mirrors
  `_read_fragment_findings`. Because `step_block_log` nests objects, it uses a
  greedy array match anchored on the field that immediately follows it:
  `sed -n 's/.*"step_block_log":\(\[.*\]\),"last_cleared_review_sha":.*/\1/p' "$f" | head -1`.
  Empty / `[]` / absent → empty string (the other readers' "no value yet"
  default). INVARIANT comment: `step_block_log` must remain immediately before
  `last_cleared_review_sha` in the printf.
- **Carry-forward in `_write_tdd_fragment`.** Add a new optional positional
  param **29** `step_block_log`, in the cumulative-by-default (preserve-on-absent)
  group with `findings`/`self_review_count`/`re_review_attempts`:
  `if [ "$argc" -ge 29 ]; then step_block_log_lit="${29}"; elif [ -f "$f" ]; then
  step_block_log_lit="$(_read_fragment_step_blocks "$f")"; else
  step_block_log_lit=""; fi; [ -z "$step_block_log_lit" ] && step_block_log_lit='[]'`.
  Add the `%s` to the printf format and `"$step_block_log_lit"` to its args at the
  field position above. Update the function header doc to describe param 29.
  Because it is preserve-on-absent, **all existing call sites are unchanged**: the
  eight carry-forward writers and the §6 setters (which call with argc≤28) round
  it through from disk untouched.
- **Append setter.** Extend the existing single chokepoint
  `_rewrite_fragment_findings <slug> <findings> <srv> <rr>` with an OPTIONAL 5th
  arg `[<step_block_log>]`: when present it is threaded as `_write_tdd_fragment`
  param 29 (argc 29); when absent the call stays argc 28 and `step_block_log`
  preserves from disk — so its current four-arg callers (`_record_finding`,
  `_incr_self_review_count`, `_re_review_attempt_count`) are behavior-unchanged.
  **Conditional-forward footgun (design-review finding).** `_rewrite_fragment_findings`
  passes `_write_tdd_fragment`'s args explicitly, so forward the 5th arg as
  `${5:+"${5}"}` (append ONLY when set and non-empty), NOT an unconditional
  `"${5:-}"`. An unconditional append would pass an empty param 29 on every legacy
  four-arg call, overriding preserve-on-absent and silently resetting
  `step_block_log` to `[]` on each `_record_finding` / `_incr_self_review_count`
  write. The conditional form keeps argc at 28 for legacy callers so the preserve
  path fires.
  Then add `_record_step_block <slug> <entry_json>` mirroring `_record_finding`:
  read the current `findings`/`self_review_count`/`re_review_attempts`
  (preserved) and `step_block_log` (via `_read_fragment_step_blocks`), append
  `<entry_json>` to the step_block_log array using the same `${existing%]},$entry]`
  splice + the same empty-vs-unparseable fail-loud guard `_record_finding` uses
  (refuse to overwrite an unparseable array; start fresh only when literally `[]`
  or absent), and call
  `_rewrite_fragment_findings "$slug" "$findings" "$srv" "$rr" "$new_block_log"`.
  Requires `STATE_DIR` set and the fragment present (returns non-zero with a
  diagnostic otherwise — the caller in §2 treats that as best-effort and does not
  fail the loop).

### 2. Recording at both per-step BLOCK sites — `scripts/lib/gates.sh`

In `_per_step_review_loop`, append a `step_block_log` entry on each per-step
BLOCK, guarded by `[ -n "${STATE_DIR:-}" ]` (best-effort telemetry; the
`THROUGHLINE_SOURCE_ONLY` path skips it):

- **0038's mechanical BLOCK site** (the `_test_first_ok_range` fail branch):
  `_record_step_block "$slug" '{"pass_id":"step-<id>","severity":"major","pattern_tags":["failing-test-first-violation"],"summary":"no test(failing): precursor for step <id>","skipped":false}'`
  (the `<id>` interpolated via `json_escape` of the parsed step-id). A
  `TEST_FIRST_SKIPPED:` step instead appends
  `{"pass_id":"step-<id>","skipped":true,"reason":"<reason>"}` (telemetry only;
  the miner skips `skipped:true` entries).
- **`_run_per_step_review`'s model BLOCK site:** on a `STEP_REVIEW: BLOCK`
  verdict, append an entry whose `pattern_tags` are harvested from the review log
  via the existing `_extract_pattern_tags`, a fixed `severity:"major"` (a per-step
  BLOCK is by definition halting; the review-log line carries only the top-level
  `REVIEW_RESULT:`/`STEP_REVIEW:` verdict, not a per-finding severity, so none is
  invented), `skipped:false`, and `summary` a one-line `json_escape`d excerpt of
  the BLOCK reason.

Recording never changes the verdict already written to the build (the BLOCK line
is emitted exactly as in 0038/0020); it only persists telemetry after the write.

### 3. Mining — `scripts/lib/learnings.sh`

`detect_build_learnings` gains a second corpus pass: after the existing `findings`
loop, for each fragment it reads `step_block_log` (via the state.sh
`_read_fragment_step_blocks`, already sourced) and folds each **non-skipped,
non-nit** entry's `pattern_tags` into the SAME per-class accumulators
(`C_slugs`/`C_steps`/`C_sevmin`/…). **Skipped-entry exclusion (design-review
finding):** unlike `findings` entries (which have no `skipped` field), a
`step_block_log` entry may carry `skipped:true`; the corpus pass excludes those
BEFORE tag accumulation with an explicit guard on the raw entry JSON —
`case "$obj" in *'"skipped":true'*) continue ;; esac` — so a justified
no-new-behavior skip never inflates a pattern class. The existing per-class
distinct-TDD dedup
(`C_slugs`) means a class appearing in BOTH `findings` and `step_block_log` for
one TDD counts that TDD once; the threshold (`_learnings_min`, ≥2 distinct TDDs)
is unchanged. An absent or empty `step_block_log` returns the empty string and the
loop skips that fragment, exactly as `_read_fragment_findings` does for a fragment
with no findings. Result: a per-step class such as `failing-test-first-violation`
that recurs across ≥2 TDDs surfaces as a candidate learning (FR-72) and thereby
reaches `/tdd-author` (FR-73).

## Data & state

One additive per-fragment field, `step_block_log` (JSON array, default `[]`), in
each `state.d/<slug>.json` fragment, positioned immediately before
`last_cleared_review_sha`. It is write-only telemetry consumed only by
`detect_build_learnings`; no run-state status/stage transition depends on it, and
no existing reader is changed. No `run.json` schema change. The whole-build
`test_first_ok` gate, the per-step verdict, the flip verdict, and the halt
taxonomy are untouched. Entry shapes:

- mechanical test-first BLOCK: `{pass_id, severity:"major", pattern_tags:["failing-test-first-violation"], summary, skipped:false}`
- model per-step BLOCK: `{pass_id, severity:"major", pattern_tags:[…from _extract_pattern_tags], summary, skipped:false}`
- skip telemetry: `{pass_id, skipped:true, reason}`

## Sequencing / implementation plan

1. Add `step_block_log` persistence to `scripts/lib/state.sh`: the
   `_read_fragment_step_blocks` reader, the param-29 carry-forward in
   `_write_tdd_fragment` (+ header doc), the `_rewrite_fragment_findings` optional
   5th arg, and the `_record_step_block` setter (Component 1).
2. Add the recording calls at both per-step BLOCK sites in `_per_step_review_loop`
   / `_run_per_step_review`, `STATE_DIR`-guarded (Component 2).
3. Extend `detect_build_learnings` with the `step_block_log` corpus pass
   (Component 3).
4. Add miner cases to `tests/build-phase-learning-capture.test.sh` and
   recording-path cases to `tests/test-first-per-step.test.sh` (the eval 0038
   created), each shipped failing-test-first (a `test(failing):` precursor per
   FR-15(a)) since they add new, observable test behavior.

## Failure modes & edge cases

- **`STATE_DIR` unset (source-only / test path).** Recording is skipped (the
  `[ -n "${STATE_DIR:-}" ]` guard); the per-step verdict is unaffected. Telemetry
  is best-effort, never a gate — distinct from 0038's enforcement, which must NOT
  depend on `STATE_DIR`.
- **Per-step BLOCK that never clears** (build fails before re-emitting). The
  `step_block_log` entry is already persisted at BLOCK time, so the violation is
  mineable even though the step never reached `cleared_step_log`.
- **`step_block_log` present but unparseable.** `_record_step_block` reuses
  `_record_finding`'s fail-loud guard: it refuses to overwrite (returns non-zero,
  preserving forensics) rather than silently resetting the array; the loop logs
  the best-effort failure and proceeds.
- **A class in both `findings` and `step_block_log` for one TDD.** The `C_slugs`
  distinct-TDD dedup counts that TDD once; the ≥2-distinct-TDD threshold is
  unchanged, so no double-count inflates a class over threshold.
- **Skip-token entries.** `skipped:true` entries are recorded for human/consolidated
  visibility but excluded from mining (a justified skip is not a violation).

## Verification plan

**Observable surface:** (a) the `step_block_log` array in a fragment after a
per-step BLOCK; (b) `detect_build_learnings` output (a candidate-learnings entry
for a recurring per-step class); (c) the field round-trips across a carry-forward
write (preserve-on-absent).

**Observation points** (mechanical; recording cases in
`tests/test-first-per-step.test.sh` with `STATE_DIR` set, miner cases in
`tests/build-phase-learning-capture.test.sh` with stub fragments):

1. **Mechanical BLOCK records the violation.** Drive `_per_step_review_loop`
   (STATE_DIR set, knob ON) with an impl-only `STEP_COMMIT` range. Expected: a
   `step_block_log` entry with `pattern_tags:["failing-test-first-violation"]`,
   `skipped:false` is appended to the fragment.
2. **Model BLOCK records harvested tags.** Drive a step whose model review stub
   emits `STEP_REVIEW: BLOCK` with a pattern-tag in its log. Expected: a
   `step_block_log` entry whose `pattern_tags` match `_extract_pattern_tags`'s
   harvest, `severity:"major"`.
3. **Skip token records skipped telemetry, not mined.** A
   `TEST_FIRST_SKIPPED:<reason>` step appends `{skipped:true,reason:…}`; the miner
   pass ignores it.
4. **Carry-forward preserves the field.** Append a `step_block_log` entry, then
   perform an unrelated `set_tdd_state` carry-forward write (argc≤28). Expected:
   the `step_block_log` array is byte-identical afterward (preserve-on-absent),
   and `cleared_step_log` remains the last field (assert `_read_fragment_cleared_log`
   still parses).
5. **Miner surfaces the recurring per-step class.** Two stub fragments each with a
   `step_block_log` entry tagged `failing-test-first-violation`. Expected:
   `detect_build_learnings` emits a candidate-learnings class naming that tag,
   `distinct_tdds` = 2; a single fragment with one such entry emits nothing
   (threshold unchanged).

**Mechanical-check robustness (folds in L-001 / L-002).** Every grep/sed-based
assertion anchors on a SPECIFIC new string (no vacuous match on pre-existing
content) and **fails closed on grep exit ≥2 / an unreadable fixture**,
distinguishing exit 1 (absent) from exit ≥2 (error) with a DISTINCT infra-failure
diagnostic. (Recurrence guard: `fragile-inversion-pattern` L-001;
`misleading-diagnostic` L-002.)

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

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-72 (recurring patterns surfaced as candidate learnings) | Component 1 (`step_block_log` persistence) + Component 2 (recording at both per-step BLOCK sites) + Component 3 (miner corpus pass), closing the per-step blind spot. Verification §1–§5. |
| FR-73 (accepted learnings inform `/tdd-author`) | Component 3 (mining half): once a per-step class is mineable and accepted, it persists to `LEARNINGS.md` and surfaces in future `/tdd-author` sessions — the unchanged FR-73 path. Verification §5 (mineability is the precondition). |

No gaps. FR-73's surfacing mechanism is unchanged by this TDD; this TDD only makes
the per-step class *reach* the store, the missing link. FR-15(a) per-step
enforcement (the BLOCK these entries record) is **[[0038]]**.

## Dependencies considered

No new external or internal dependency. The change reuses `_per_step_review_loop`,
`_run_per_step_review`, `_extract_pattern_tags`, `_read_fragment_findings` /
`_record_finding` / `_rewrite_fragment_findings` (as the persistence template),
and `detect_build_learnings`.

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
- **Append `step_block_log` as the new LAST fragment field** — rejected: it would
  break `_read_fragment_cleared_log`'s "cleared_step_log must remain last"
  greedy-anchor invariant (state.sh:95). Inserting before `last_cleared_review_sha`
  preserves that invariant and the `findings` anchor.

## PRD conflicts surfaced (and resolution)

Resolves the persistence half of the open `docs/tdd/BLOCKERS.md` entry for the
original 0038 (2026-06-08): the build found `step_block_log` persistence requires
`scripts/lib/state.sh`, which the original TDD never declared. This TDD declares
`state.sh` and owns the full `step_block_log` lifecycle (reader + carry-forward +
append setter), keeping each TDD within the 8-file scope bound.

## Decisions to promote (ADR candidates)

None. The change extends existing telemetry/mining within the established
gate-architecture (ADR 0005/0006) and the §6 cumulative-fragment convention; it
introduces no new cross-cutting decision.

## Touched files

- `scripts/lib/state.sh` — `_read_fragment_step_blocks` reader; `step_block_log` param-29 carry-forward in `_write_tdd_fragment` (+ header doc); `_rewrite_fragment_findings` optional 5th arg; `_record_step_block` setter.
- `scripts/lib/gates.sh` — `_record_step_block` calls at both per-step BLOCK sites (mechanical + model), STATE_DIR-guarded.
- `scripts/lib/learnings.sh` — `step_block_log` corpus pass in `detect_build_learnings`.
- `tests/build-phase-learning-capture.test.sh` — miner `step_block_log` mining cases.
- `tests/test-first-per-step.test.sh` — recording-path cases (STATE_DIR set: mechanical/model BLOCK records; skip telemetry; carry-forward preserve).
- `skills/implement/SKILL.md` — required same-commit doc-sync: the implement behavior spec's mining-scope description, updated in lockstep with the §6 `step_block_log` corpus pass (no behavior of its own added).

Total: 6 files touched.

## Expected diff size

- `scripts/lib/state.sh` — ~110 lines added/changed (reader + carry-forward param/literal/printf field + header doc + `_rewrite_fragment_findings` 5th arg + `_record_step_block`).
- `scripts/lib/gates.sh` — ~80 lines added (entry construction + the STATE_DIR-guarded `_record_step_block` calls at the per-step BLOCK + skip sites).
- `scripts/lib/learnings.sh` — ~125 lines added (reader call + `step_block_log` corpus pass folding into the per-class accumulators + the split helpers it needs).
- `skills/implement/SKILL.md` — ~8 lines (doc-sync of the mining-scope description; no new behavior).
- `tests/build-phase-learning-capture.test.sh` — ~95 lines added (miner `step_block_log` mining cases + headroom for the per-step review rework to ship a genuine `test(failing):`-first restructure of the step-4 cases).
- `tests/test-first-per-step.test.sh` — ~135 lines added (recording-path + carry-forward-preserve cases with fail-closed guards).

Total expected diff: ~553 lines across 6 files. No per-file exception needed (each file is under the 300-line per-file bound). Estimates reconciled to the actual build diff: the original authoring underestimated systematically (the ~1.5–2× bias that TDD 0041's K-tolerance + padding heuristic address, neither built at this TDD's authoring time).

# TDD 0053: gates.sh gate-integrity hardening (fresh-verdict + sentinel/parse fixes)
Status: draft
PRD refs: NFR-4 (no false PASS; ambiguity resolves to FAIL); FR-57 (per-step review); FR-67 (structural-finding scope); FR-69 (self-compliance with Theme A)
PRD-rev: 0aa1e28
ADR constraints: 0006

## Approach
A cluster of correctness defects in `scripts/lib/gates.sh` weakens gate integrity —
the property NFR-4 exists to guarantee (a gate never reports a false PASS, and
ambiguity resolves to FAIL). The anchor is a genuine gate-bypass:

- **A1 (review-gate bypass).** `_review_one_gated` derives its PASS from
  `review_status` (gates.sh:529), which greps the **whole cumulative** review log
  and `tail -1`s it. The bounded-rework loop legitimately leaves a prior
  `REVIEW_RESULT: PASS` in that cumulative log (PASS+halting-finding → rework;
  PASS+incomplete-coverage → re-review). When a later re-review iteration writes
  **no fresh verdict** (the review subprocess exits 0 with no `REVIEW_RESULT`, or
  fails closed without writing one) AND the scoped `git diff --name-only
  $rbase..HEAD` is empty (genuinely, OR because a transient git failure's rc is
  swallowed by `2>/dev/null` at 1811), the loop falls back to the **stale**
  cumulative PASS (2252 `rs=${verdict_in_new:-$(review_status "$log")}`) and
  **falsely converges** (2278) — flipping the TDD toward done with no fresh review.
  This is the exact bypass the `verdict_in_new` machinery was built to prevent, via
  the `rc==0` path it doesn't cover.

The supporting fixes harden the same surface (the build coprocess lifecycle + the
sentinel/scope parsers):

- **A15.** The protocol-error correction path (1180-1189) resets `interval_start`
  WITHOUT first committing the elapsed streaming interval into `build_active_seconds`
  (the review-verdict and test-first paths both do). The active-time watchdog then
  under-measures, letting a misbehaving build run past its active-seconds budget.
- **A16.** `BATCH_RESULT:` matched on the raw event but extracted only from
  assistant **text** content; a sentinel carried in a tool-use block yields empty
  text, the stdin-close lifecycle never runs, and a finished build hangs until the
  inter-event timeout → spurious transient pause.
- **A17.** `_diff_vs_narrative_facts` file-count picks up `BATCH_RESULT` via a
  byte-line (`-a`) match that can over-include.
- **A18.** Membership greps use `grep -qxF` **without `--`**, so a diff/cited path
  beginning with `-` is parsed as a grep option (mis-membership on the FR-67 check).
- **A19.** `_rework_pre_pass` routes cause/excerpt inconsistently when a git-diff
  failure coincides with a scope/(a) violation.

Scope is one file (`gates.sh`); the fixes are localized and each carries a
regression observation. (gates.sh is also touched by [[0050]]'s one array-builder
delegate; this TDD's regions are disjoint and it builds stacked on 0050.)

## Components & interfaces
No new public interface — targeted fixes inside existing functions:
- **A1 — `_review_one_gated` / the rework-loop convergence (1346-1356, 2239-2279):**
  derive the convergence verdict from a **fresh** verdict only. Concretely: on the
  `rrc==0` arm, treat an empty `verdict_in_new` (the `_fresh_review_verdict`
  post-`pre_log_size` slice, 541-546) as **no-verdict** and route it to
  `_classify_gate_no_verdict` — do NOT fall back to `review_status`'s cumulative
  PASS. A genuine empty-diff PASS that DID write a fresh `REVIEW_RESULT: PASS`
  still converges (the fresh slice is non-empty); only a MISSING fresh verdict is
  caught. Also harden the coverage check (1807-1836): a non-empty `git diff` rc
  must be distinguished from an empty diff (don't swallow the rc at 1811), so a
  transient git failure cannot masquerade as "no files changed → converged".
- **A15:** insert `build_active_seconds=$((build_active_seconds + $(date +%s) - interval_start))` immediately before the `interval_start=$(date +%s)` reset at 1189.
- **A16:** on the outer `*"BATCH_RESULT: "*` match, if `_extract_event_text` yields
  empty, still run the stdin-close lifecycle (the verdict is parsed from the
  mirrored raw log anyway), so a tool-use-carried sentinel does not hang the build.
  Guard the close with a `_build_stdin_closed` flag set on the FIRST close, and have
  both the empty-text path and the normal text-path BATCH_RESULT arm check it before
  closing — so a subsequent real BATCH_RESULT cannot double-close the `{build_in}` fd.
- **A17:** count changed files from the structured diff, not a byte-line BATCH_RESULT
  pickup; drop the `-a` over-inclusion.
- **A18:** add `--` to the `grep -qxF` membership checks so a leading-`-` path is a
  pattern, not an option.
- **A19:** in `_rework_pre_pass`, make the git-diff-failure branch route a single
  consistent cause + excerpt regardless of a co-occurring scope/(a) violation.

## Data & state
No state-schema change. A1 changes which verdict value drives convergence (fresh,
not cumulative) and how a git-diff rc is interpreted; A15 changes the
`build_active_seconds` accumulator value. No on-disk format changes.

## Sequencing / implementation plan
1. A1: fresh-verdict convergence + git-diff-rc-aware coverage check (the anchor).
2. A15: commit the elapsed interval before the protocol-error `interval_start` reset.
3. A16: run the stdin-close lifecycle on an empty-text BATCH_RESULT match.
4. A18: add `--` to the membership greps.
5. A17 + A19: structured file-count; consistent pre-pass cause/excerpt routing.
6. Extend `tests/bounded-rework-loop.test.sh` (A1, A18, A19) and
   `tests/continuous-in-build-review.test.sh` (A15, A16) with the regressions.

## Failure modes & edge cases
**Real risks.**
- *A1 fix false-fails a legitimate convergence.* A rework that genuinely converged
  with a fresh `REVIEW_RESULT: PASS` (even on an empty final diff) MUST still pass.
  Mitigated by keying on the FRESH-slice verdict (non-empty when a verdict was
  written) rather than diff-emptiness; Verification §1 includes the legitimate
  empty-diff-with-fresh-PASS case and asserts it still converges.
- *A16 double-close.* Running the stdin-close on the empty-text path must be
  idempotent / guarded so a later real BATCH_RESULT doesn't double-close the fd.
  Mitigated by a closed-flag guard; Verification §3.

**Overblown risks.**
- *A15 changes timing accounting under normal builds.* It only adds an accumulation
  on the protocol-error path (≤2 per attempt); a prose-conformant build never hits
  it, so steady-state timing is unchanged.

**Unspoken risks (elephants).**
- *A1 is the load-bearing fix; the others are guards.* If the fresh-verdict change
  is subtly wrong it could swing the other way (false FAIL on a real PASS), halting
  good builds. The Verification plan therefore tests BOTH directions explicitly
  (no-fresh-verdict → no-converge; fresh-PASS-on-empty-diff → converge), so a
  one-directional fix is caught.

## Verification plan
- **Observable surface:** (a) the rework-loop's convergence outcome (TDD flipped /
  gate-no-verdict halt) and its run-state cause; (b) `build_active_seconds` /
  watchdog behavior; (c) the build coprocess completing vs hanging; (d) the
  membership-check result for a leading-`-` path.
- **Observation points (mechanical, the cited evals with the build/review
  subprocesses stubbed):**
  1. **A1 both directions.** (a) Drive the rework loop so a re-review iteration
     writes NO fresh `REVIEW_RESULT` while a prior cumulative PASS exists and the
     scoped diff is empty → assert the loop does NOT converge; assert the recorded
     `halt_cause` is `gate-unobservable` (the resumable no-verdict cause), NOT a
     terminal `failed`/`done` flip. (b) Same, but the re-review writes a fresh
     `REVIEW_RESULT: PASS` on an empty final diff → assert it DOES converge.
     (c) Simulate a `git diff` rc!=0 at the coverage check → assert it is NOT
     treated as "no files changed → converged".
  2. **A15.** Feed a malformed `STEP_COMMIT:` after a measurable streaming interval;
     assert `build_active_seconds` includes that interval (watchdog accounting not
     under-counted).
  3. **A16.** Emit a terminal `BATCH_RESULT: OK` carried in a tool-use block (empty
     assistant text); assert the build coprocess closes/exits rather than hanging to
     the inter-event timeout.
  4. **A18.** Run the membership check with a declared path beginning `-`; assert it
     matches correctly (not parsed as a grep option).
  5. **A17/A19.** A diff with N changed files → correct count; a git-diff failure
     co-occurring with an (a) violation → one consistent cause/excerpt.
- **Expected observations (PASS):** each lettered case above holds; for every
  folded bug the regression FAILS against the pre-fix code and PASSES post-fix.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement + folded-bug traceability | Every FR-53/54/67 tie-in AND each folded bug (A-id) maps to a named design element | All mapped | Any req or folded bug untraced |
| Folded-bug regression coverage | Each folded bug has a named observation point that fails pre-fix / passes post-fix | Each folded bug has a regression check | A folded bug has no regression observation |
| Single-source-of-truth (refactors) | One canonical helper; all callers verified-thin delegates | Callers delegate; one definition | A divergent copy remains |
| Sourcing + back-compat | New shared lib sources cleanly in all 4 contexts incl markers minimal-host; existing callers/tests unbroken | Sourcing + guard specified | A context unhandled or a caller regressed |
| Verification-plan actionability | Observable surface + exact points + expected values | Surface + points named | placeholder/vague |
| Scope-bound adherence | Within bounds, or a declared/justified exception (state.sh) | Within bounds | Bound blown without exception |
| Naming consistency | Same helper names across all 5 TDDs | Mostly consistent | Same concept named two ways |

## Requirement traceability
| Requirement / bug | Design element |
|---|---|
| NFR-4 (no false PASS; ambiguity→FAIL) | A1 fresh-verdict convergence + git-diff-rc-aware coverage; A16 no-hang lifecycle |
| FR-57 (per-step review) | A15 protocol-error active-time accounting; A16 sentinel lifecycle |
| FR-67 (structural-finding scope) | A18 `--`-safe membership; A19 consistent pre-pass cause/excerpt |
| ADR 0006 (artifacts grounded) | convergence keyed on a FRESH artifact verdict, not a stale cumulative one |
| FR-69 (self-compliance with Theme A) | hardens the runner's own gate logic (gates.sh) against the audited integrity defects |
| bugs A1/A15/A16/A17/A18/A19 | each → its fix above + named regression in Verification |

No gaps.

## Dependencies considered
No new dependency — targeted fixes to existing bash/awk/grep logic. (A "refactor
the whole sentinel parser" alternative was rejected as out of scope here; the
sentinel/section-parser consolidation is the deferred post-0049 md-section work.)

## PRD conflicts surfaced (and resolution)
None. Strengthens NFR-4 gate integrity; no ADR reversed. (The A1 entry in the
consolidated audit is the durable fix for a process-integrity hole, not a PRD
conflict.)

## Decisions to promote (ADR candidates)
None — localized correctness fixes. ADR 0006 governs and is respected.

## Touched files
- `scripts/lib/gates.sh` — A1 fresh-verdict convergence + git-diff-rc-aware coverage; A15 active-time commit; A16 empty-text BATCH_RESULT lifecycle; A17 structured file-count; A18 `--`-safe membership greps; A19 consistent pre-pass routing.
- `tests/bounded-rework-loop.test.sh` — A1 (both directions) + A19 regressions.
- `tests/continuous-in-build-review.test.sh` — A15 + A16 lifecycle regressions.

## Expected diff size
- `scripts/lib/gates.sh` — 70 lines (six localized fixes; ×1.4 shell-lib).
- `tests/bounded-rework-loop.test.sh` — 130 lines (A1 three-case + A19; ×1.6 test).
- `tests/continuous-in-build-review.test.sh` — 90 lines (A15 + A16 lifecycle cases; ×1.6 test).
Total expected diff: ~290 lines across 3 files. No per-file exception needed.

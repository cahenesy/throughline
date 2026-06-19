# TDD 0059: Combined-mode resume skips already-built TDDs (issue #165)
Status: implemented
PRD refs: FR-18 (resume safety — skip already-implemented); FR-40 (gate-level resume preserves completed work)
PRD-rev: d7bc491
ADR constraints: 0005, 0006

## Approach
Fixes filed issue #165: a `--combined` run that **halts on a downstream TDD
(position > 1)** cannot be cleanly resumed. The resume re-processes the whole
queue from the first TDD; because that first TDD is already `Status: implemented`
on the shared `build/<change>` branch, its flip-to-implemented becomes an empty
commit and fails with `FAIL flip (could not commit the implemented flip)`. In
combined mode that failure cascades to mark every remaining TDD `BLOCKED`, so the
only sanctioned recovery is a full fresh rebuild — discarding the four-gates-passed
build work of every already-built TDD in the batch. This violates **FR-18**
("a TDD already `implemented` on an existing un-merged branch is skipped", stated
mode-agnostically) and **FR-40** (resume preserves completed work).

**Root cause (two interacting gaps, confirmed on master 3.39.0):**
1. The **combined driver loop** (`implement.sh`, the `elif [ "$COMBINED" -eq 1 ]`
   branch) has **no per-TDD skip** — unlike the parallel driver (which calls
   `built_branch`) and the sequential driver (same). `built_branch`
   (`resume.sh`) only matches a per-TDD branch ref `*/<slug>`, so it never
   recognizes an already-flipped TDD on the suffix-less combined branch;
   `combined_built_branch` only short-circuits when the *whole* set is built,
   which is false mid-batch. So an already-built TDD in a combined batch is
   re-entered on every resume.
2. `flip_status` (`gates.sh`) is **not idempotent**: it `sed`s `draft→implemented`
   (a no-op for an already-`implemented` TDD), then `git add`/`git commit` with
   nothing staged → non-zero exit → `gate_one` reports `FAIL flip`.

**The fix (both, per the chosen scope):**
- **Primary — combined-aware per-TDD skip.** In the combined loop, before
  `_resume_from`/`gate_one`, skip a TDD already `implemented` at the combined
  branch HEAD (mark it `skipped`, `continue`) — the combined analogue of the
  parallel/sequential `built_branch` skip, so the loop advances to the halted TDD.
- **Defense-in-depth — idempotent flip.** `flip_status` treats a TDD already
  `Status: implemented` at HEAD as a **no-op success** (return 0, no commit),
  distinct from a genuine commit failure (NFR-4: a real `draft→implemented` whose
  commit fails still returns non-zero). This closes the class — any path that
  reaches the flip on an already-implemented TDD can no longer FAIL on the empty
  commit.
- **Single-source the predicate.** The `^Status:[[:space:]]*implemented` check is
  already duplicated twice in `resume.sh`; factor one `_tdd_implemented_at <ref>
  <tdd>` and repoint all four sites (the two existing + the new skip + the flip
  guard), avoiding the L-003 duplicate-drift class.

## Components & interfaces
- **`_tdd_implemented_at <ref> <tdd>` (new, `scripts/lib/resume.sh`).** Returns 0
  iff `git show "<ref>:<tdd>"` contains a `^Status:[[:space:]]*implemented` line;
  non-zero otherwise (including when the ref/path is absent — `git show` fails,
  grep sees nothing). The single home for the pattern. Lives in `resume.sh`
  beside the existing greps (`built_branch`, `combined_built_branch`). `flip_status`
  (`gates.sh`, sourced *before* `resume.sh`) calls it cross-lib at runtime — this
  matches the documented sourceability contract ("calls are resolved at call time,
  so resume.sh sources standalone", `tests/gates-resume-module-sourceability.test.sh`),
  exactly as `gate_one` (resume.sh) already calls `gates.sh` helpers.
- **`built_branch` / `combined_built_branch` (`resume.sh`).** Repointed to delegate
  their inline `git show … | grep -qE '^Status:…implemented'` to
  `_tdd_implemented_at "$ref" "$tdd"`. Behavior-identical (the iteration and
  `*/<slug>` / all-set logic is unchanged; only the per-ref predicate is factored).
- **Combined driver loop (`scripts/implement.sh`, the `COMBINED` branch).** At the
  top of the per-TDD loop body (after `slug`/`log` are set, before
  `set_tdd_meta`/`_resume_from`/`gate_one`), add:
  ```
  if [ "$REBUILD" -ne 1 ] && _tdd_implemented_at "$CHANGE" "$tdd"; then
    echo "- $slug — already built on $CHANGE (combined batch); skipped" >>"$REPORT"
    _terminal_state "$slug" skipped "" "already built on $CHANGE (combined batch); awaiting your merge"
    set_tdd_meta "$slug" "branch=$CHANGE"
    continue
  fi
  ```
  `$CHANGE` is the combined branch (created/entered at the driver's
  `git checkout -b "$CHANGE"`). The skip is gated on `REBUILD -ne 1` (mirrors
  `built_branch`) and uses `continue` without touching the `blocked`/`paused_halt`
  flags, so it advances the loop without suppressing the eventual push/PR. Note
  the guard sits ABOVE the loop's existing unconditional
  `set_tdd_meta "$slug" "branch=$CHANGE"` (the line before `_resume_from`), so the
  skip carries its OWN `set_tdd_meta` (the snippet above) and the original line is
  left intact for the non-skipped path — do not remove it.
- **`flip_status` (`scripts/lib/gates.sh`).** Prepend an idempotency guard before
  the `sed`/`git add`/`git commit`:
  ```
  if _tdd_implemented_at HEAD "$tdd"; then return 0; fi   # already flipped on this un-merged branch; nothing to commit (FR-18/NFR-4)
  ```
  A TDD not yet `implemented` at HEAD falls through to the existing real
  flip-and-commit path unchanged, so a genuine commit failure (rejecting hook,
  disk) still returns non-zero — the guard precedes, never replaces, the honest
  commit.

## Data & state
No schema change, no new fragment field. On resume, an already-built TDD's fragment
(carried in the prior run's `state.d/`) is re-marked `skipped` via `_terminal_state`
— consistent with how the sequential/parallel drivers report an already-built TDD,
and with the run-state `skipped` status enum. The combined branch is unchanged
(no duplicate `mark <slug> implemented` commit is added for the skipped TDD).

## Sequencing / implementation plan
1. Add `_tdd_implemented_at` to `resume.sh`; repoint `built_branch` and
   `combined_built_branch` to it (behavior-preserving; existing resume/sourceability
   evals stay green).
2. Make `flip_status` (`gates.sh`) idempotent via the `_tdd_implemented_at HEAD`
   guard.
3. Add the per-TDD skip to the combined driver loop in `implement.sh`.
4. Add `tests/combined-resume-skip.test.sh` (the issue-#165 regression that drives
   a combined resume with a built first TDD + a halted second; the `flip_status`
   idempotency + real-failure units; the single-source grep), and register it in
   `tests/implement-gate.test.sh` red-first (TDD 0038 §3 wire-in).
5. Add `_tdd_implemented_at` to the `[D]` function roster in
   `tests/gates-resume-module-sourceability.test.sh` so the sourceability eval
   guards the new predicate (a one-line addition to the existing function list).

## Failure modes & edge cases
**Real risks.**
- *The idempotent flip masks a genuine commit failure (NFR-4).* Mitigated by
  keying the no-op strictly on `_tdd_implemented_at HEAD` (already committed as
  implemented); a real `draft→implemented` still runs `git commit` and propagates
  its non-zero. Verification §2 drives both arms (already-implemented → 0 no commit;
  a stubbed failing `git commit` on a genuine draft → non-zero).
- *Cross-lib call breaks a standalone `gates.sh` unit test.* `flip_status` now
  calls `_tdd_implemented_at` (resume.sh). The sourceability eval only checks
  function *definition* (`type -t`), which is unaffected; the tests that *call*
  `flip_status` source the full runner (`THROUGHLINE_SOURCE_ONLY=1`), so the
  predicate is loaded. Verification §3 keeps the new `flip_status` cases on the
  full-source path. (fails if a future test calls `flip_status` after sourcing
  only `gates.sh`.)

**Overblown risks.**
- *Skipping changes the combined PR contents.* It does not — the skipped TDD's
  commits are already on `$CHANGE`; the skip just avoids re-flipping. The push/PR
  (gated on not-paused/not-blocked) includes the built TDD + the resumed one + any
  later ones.
- *`--rebuild` interaction.* The skip is gated on `REBUILD -ne 1`; under `--rebuild`
  the branch is rebuilt from the integration `draft` copy, so HEAD is `draft` until
  the real flip and the idempotent guard is naturally inert.

**Unspoken risks (elephants).**
- *Asserting the fix without exercising the combined-resume control-flow* — the
  exact L-009/L-010 pattern (a TDD claimed a resume mitigation its test never
  drove). Verification §1 is therefore an end-to-end combined-resume run via the
  real driver (built A + halted B), asserting A is `skipped` (not `FAIL flip`) and
  B is reached — not a unit assertion on the predicate alone.

## Verification plan
- **Observable surface:** the combined driver's per-TDD report lines + the run-state
  fragment `status` per TDD; `flip_status`'s return code and whether it adds a
  commit; the combined branch's commit list; a repo-grep over the three libs.
- **Observation points (mechanical):**
  1. **Combined-resume regression (drives the real path).** Build a fixture repo +
     combined run state: TDD A `implemented` and committed on branch `$CHANGE`, TDD
     B halted at review (fragment paused/blocked, B still `draft` on `$CHANGE`), TDD
     C unbuilt; the prior `state.d/` present. Invoke the combined driver with
     `--resume` (via `THROUGHLINE_SOURCE_ONLY=1` harness or a stubbed-gate run).
     Assert: A's report line is `already built on $CHANGE (combined batch); skipped`
     and A's fragment `status=skipped` (NOT `FAIL flip`); B is reached (its halted
     gate re-runs / its fragment leaves the paused state); the run does **not** mark
     B or C `BLOCKED (upstream TDD failed)`; no second `mark A implemented` commit
     is added to `$CHANGE`.
  2. **`flip_status` idempotency + honesty.** (a) On a TDD already `Status:
     implemented` at HEAD, `flip_status` returns 0 and `git rev-list` shows no new
     commit. (b) On a genuine `draft` TDD it flips and commits (returns 0, one new
     commit). (c) With a forced-failing `git commit` (e.g. a rejecting pre-commit
     hook) on a genuine `draft` TDD, `flip_status` returns non-zero (the guard does
     not mask it).
  3. **Single-source.** Grep the three libs: exactly one definition of the
     `^Status:[[:space:]]*implemented` predicate (`_tdd_implemented_at`); no other
     inline `git show … | grep -qE '^Status:…implemented'` remains in `built_branch`,
     `combined_built_branch`, the combined loop, or `flip_status`.
- **Expected observations (PASS):** §1 — pre-fix A reports `FAIL flip` and B/C
  cascade `BLOCKED`; post-fix A is `skipped`, B is reached, no cascade (named
  fail-pre/pass-post). §2 — the three arms return 0/0/non-zero respectively. §3 —
  one predicate, no inline copy.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Regression closure | A combined run halted on TDD>1, resumed, skips the already-built TDD and reaches the halted one — pinned by a test that ACTUALLY drives the combined-resume path (not assert-only) | Combined-resume regression asserted | No regression, or it does not exercise the skip path |
| Requirement traceability | FR-18 (skip already-implemented) + FR-40 (resume preserves work) each map to a named design element | Both refs traced | Any untraced ref |
| Single-source predicate | One Status:implemented predicate; built_branch + combined_built_branch + combined-loop skip + flip_status all delegate; no inline copy remains | One definition, delegates | A 3rd/4th inline copy of the grep added |
| NFR-4 honesty | Idempotent flip no-ops (returns 0) ONLY when already-implemented at HEAD; a genuine draft→implemented commit failure still returns non-zero | Idempotency + real-failure paths both stated | Guard masks a real commit failure |
| Behavior preservation | sequential/parallel skip, --rebuild override, and combined push/PR all unaffected; skip gated on REBUILD≠1 | Equivalence stated + spot-checked | A non-combined path or --rebuild regresses |
| Verification-plan actionability | Observable surface + exact observation points (report lines, fragment status, flip rc, branch commits) + expected values | Surface + points named | Tests-pass placeholder |
| Scope-bound adherence | Within per-file + touched-file bounds (no exception) | Within bounds | Over a bound without exception |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-18 (resume safety — skip already-implemented, mode-agnostic) | the combined-loop per-TDD skip recognizes an already-`implemented` TDD at the combined branch HEAD and marks it `skipped`, closing the combined-mode gap in FR-18's "skipped (no duplicate work or PRs)" |
| FR-40 (gate-level resume preserves completed work) | the skip + idempotent flip let `--resume` reach the halted downstream gate without re-flipping/rebuilding the already-built TDDs, preserving their four-gates-passed work as FR-40 requires |
| NFR-4 (verdict honesty) | the idempotent flip no-ops ONLY on an already-`implemented` HEAD; a genuine commit failure is still surfaced non-zero (the guard never masks a real failure) |
No gaps. ADR 0005 (gate scope: prompt + downstream detection, not new gates) is
respected — this adds no gate; it corrects the runner's skip/flip control flow.
ADR 0006 (verdicts grounded in artifacts) is respected — the skip/flip key on the
branch's committed `Status:` line (a verifiable artifact), not a self-report.

## Dependencies considered
No new dependency — `git show`/`grep` are already in-tree. Rejected alternatives:
- **Generalize `built_branch` to also match the combined branch** — rejected:
  `built_branch` iterates refs keyed on the `*/<slug>` suffix that combined
  branches do not carry; bending it to the suffix-less combined branch muddies a
  per-TDD-branch helper. A direct per-TDD check against the known `$CHANGE`
  (delegating to the shared predicate) is clearer and keeps the two concerns
  separate.
- **Idempotent flip ONLY (skip nothing)** — rejected: it would stop the `FAIL flip`
  but still re-enter `_resume_from`/`gate_one` for every already-built TDD on every
  resume (wasted work, and a misleading per-TDD `OK` re-report); the skip is the
  behavior FR-18 actually specifies.

## PRD conflicts surfaced (and resolution)
None. This is a bug against existing, mode-agnostic requirements (FR-18, FR-40),
not a requirements change — the PRD already mandates the desired behavior; the
combined-mode implementation had a gap. No PRD edit; no ADR reversed. No
`BLOCKERS.md` entry (the report came via a filed issue, not a build halt).

## Decisions to promote (ADR candidates)
None. Correcting a control-flow gap to honor existing requirements is not a durable
cross-cutting decision. ADR 0005/0006 govern and are respected.

## Touched files
- `scripts/lib/resume.sh` — new `_tdd_implemented_at` predicate; repoint `built_branch` + `combined_built_branch` to it.
- `scripts/lib/gates.sh` — `flip_status` idempotency guard (delegates to `_tdd_implemented_at HEAD`).
- `scripts/implement.sh` — combined driver loop per-TDD skip for an already-implemented TDD at the combined branch HEAD.
- `tests/combined-resume-skip.test.sh` — issue-#165 combined-resume regression + flip idempotency/honesty units + single-source grep.
- `tests/implement-gate.test.sh` — register the new eval (CRS_FAIL term + AND-chain), red-first wire-in.
- `tests/gates-resume-module-sourceability.test.sh` — add `_tdd_implemented_at` to the `[D]` function roster.
- `.claude-plugin/plugin.json` — version bump (build-applied).

## Expected diff size
- `scripts/lib/resume.sh` — 24 lines (new predicate ~8 + two delegations; ×1.4 shell-lib).
- `scripts/lib/gates.sh` — 8 lines (one guard line + comment; ×1.4).
- `scripts/implement.sh` — 14 lines (the per-TDD skip block; ×1.4).
- `tests/combined-resume-skip.test.sh` — 190 lines (combined-resume fixture + regression + flip units + grep; ×1.6 test).
- `tests/implement-gate.test.sh` — 20 lines (registration block + AND-chain term; ×1.6).
- `tests/gates-resume-module-sourceability.test.sh` — 3 lines (add `_tdd_implemented_at` to the `[D]` roster; ×1.6).
- `.claude-plugin/plugin.json` — 2 lines (version bump).
Total expected diff: ~261 lines across 7 files. All files within the 300-line per-file cap (no exception); touched files 7 ≤ 8.

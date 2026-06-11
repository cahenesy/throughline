# TDD 0052: Single PR-publish path (_publish_pr) that surfaces swallowed failures
Status: draft
PRD refs: FR-16 (opens PRs; never merges); FR-19 (per-TDD report + merge plan); FR-27 (run-state pr_url record); FR-69 (self-compliance with Theme A)
PRD-rev: 0aa1e28
ADR constraints: 0006

## Approach
`/implement` publishes a built TDD in three modes, and each open-codes the same
push → `gh pr create --fill` → record-pr-url → coverage-pointer block
(implement.sh:469-476 parallel, 569-577 combined, 645-653 sequential — reuse #5).
The three copies have **drifted**, and the drift is a swallowed-failure bug:

- The sequential site (645-653) carries explicit `else pr=", push failed"` /
  `", PR create failed"` diagnostics; the **parallel and combined sites silently
  omit them** — a `git push` or `gh pr create` failure is reported in one mode and
  **swallowed** in the other two (**bug A8**), so a feature whose PR never opened is
  reported as success.
- Combined-mode branch checkout failure is **silently swallowed**; the build then
  proceeds on a detached HEAD (implement.sh:521 — **bug A6**).
- `install_deps`'s total-failure return code is **ignored** in both the sequential
  and parallel drivers (implement.sh:449 — **bug A7**), so a worktree with no
  installed deps builds and fails opaquely downstream.

This TDD extracts one `_publish_pr` helper that the three sites call, with the
sequential site's failure-surfacing as the single contract, and makes the two
swallowed precondition failures (checkout, install_deps) loud. Folds reuse #5 and
bugs A8, A6, A7.

## Components & interfaces
**New helper in scripts/implement.sh** (above the `THROUGHLINE_SOURCE_ONLY` guard
so the eval can drive it), alongside the existing `_pr_coverage_pointer`:
```
_publish_pr <branch> <base> <log>
    git push -u origin <branch>      (append stderr to <log>)
    -> on push failure: echo "" to stdout AND a non-empty diagnostic to fd 2
       in the form "push failed", return 1.
    gh pr create --base <base> --head <branch> --fill   (append stderr to <log>)
    -> on create failure: echo "" , diagnostic "PR create failed", return 2.
    on success: echo the PR url to stdout, call _pr_coverage_pointer, return 0.
    The push/create CLI invocation + its 2>><log> redirection live ONLY here.
```
Each of the three sites becomes:
```
prurl="$(_publish_pr "$branch" "$base" "$log")"; ppr_rc=$?
# mode-specific bookkeeping: set_tdd_meta (single) vs TDDS loop (parallel),
# report wording from ppr_rc, PR_PLAN append.
```
The mode-specific parts (how pr_url is recorded, report text) stay at the call
site; only the publish CLI + its failure contract are centralized — so a failure
is now surfaced identically in all three modes (A8 fix). The sequential site's
`pbase="${prev#origin/}"` base normalization moves into the caller that needs it
(unchanged behavior).

**Precondition surfacing (A6, A7):**
- Combined-mode checkout (implement.sh:521): the `git checkout`/`git switch` rc is
  checked; on failure the runner FAILs the TDD with a clear cause and does NOT
  proceed on detached HEAD (mirrors how the sequential driver already guards its
  branch ops).
- `install_deps` (implement.sh:449): its return code is captured; a total failure
  FAILs the affected TDD (sequential/parallel) with a `deps-install-failed` cause
  rather than being discarded.

## Data & state
No new state. `pr_url` continues to be recorded via the existing `set_tdd_meta` /
TDDS-loop writes; `_publish_pr` only returns the value. Run-state cause writes for
the new precondition failures use the existing `set_tdd_state` blocked/failed path.

## Sequencing / implementation plan
1. Add `_publish_pr <branch> <base> <log>` (push + gh-pr-create + coverage pointer,
   with the loud failure contract) above the SOURCE_ONLY guard.
2. Repoint the three publish sites (parallel 469-476, combined 569-577, sequential
   645-653) to call it; keep each site's mode-specific pr_url recording + report
   wording; the sequential site's diagnostics are now the shared default (A8).
3. Check the combined-mode checkout rc (521); FAIL-not-detached on failure (A6).
4. Capture `install_deps` rc at the call sites (449 and the parallel driver); FAIL
   the TDD on total failure (A7).
5. Update `tests/gated-implementation.test.sh` (or the implement driver eval) with
   the publish-failure-surfaced + checkout-fail + deps-fail regressions; register
   if new.

## Failure modes & edge cases
**Real risks.**
- *`gh`/remote absent* (documented: commits stay on the branch). `_publish_pr`
  must distinguish "no remote/gh" (the existing tolerated path) from "push/create
  attempted and failed" (the newly-surfaced error). Mitigated by gating on the
  same remote/gh presence check the current code uses before calling `_publish_pr`.
- *A6/A7 FAIL turns a previously-"succeeding" build into a FAIL.* That is the
  intended correctness change (the build was proceeding on a broken precondition);
  Verification §2/§3 assert the FAIL is honest and carries a clear cause.

**Overblown risks.**
- *Centralizing changes PR-body content.* `--fill` and the coverage pointer are
  unchanged; only the failure branches move. No PR-body behavior change.

**Unspoken risks (elephants).**
- *Stacked-PR base retargeting.* Sequential PRs are stacked (base = prev branch);
  the `pbase="${prev#origin/}"` strip is load-bearing for that. Moving the publish
  CLI into `_publish_pr` must NOT lose the per-site base argument — the caller
  passes the already-normalized base, so the helper stays mode-agnostic. Verification
  §1 asserts the sequential call still receives the stripped base.

## Verification plan
- **Observable surface:** (a) the runner's report line + run-state cause for a TDD
  whose push/create/checkout/deps step fails; (b) `_publish_pr` stdout (url-or-empty)
  and return code; (c) the report wording across the three modes.
- **Observation points (mechanical, `tests/gated-implementation.test.sh` with
  `git`/`gh` stubbed):**
  1. Stub `gh pr create` to succeed; call `_publish_pr` from a fixture in each
     mode-shape; assert the url is returned, coverage pointer invoked, and the
     sequential call received the `origin/`-stripped base.
  2. Stub `git push` to FAIL; call `_publish_pr` in the parallel and combined
     shapes; assert a non-empty diagnostic is surfaced (fd 2 / report) and rc=1 —
     i.e. the failure is NOT swallowed (A8 regression).
  3. Stub the combined-mode checkout to FAIL; assert the TDD is FAILed with a clear
     cause and the build does NOT run on detached HEAD (A6 regression).
  4. Stub `install_deps` to return non-zero; assert the TDD FAILs with
     `deps-install-failed` rather than proceeding (A7 regression).
- **Expected observations (PASS):**
  - §1: url returned, pointer called, stacked base intact.
  - §2 (**A8**): pre-fix the parallel/combined push failure is silent (success
    reported); post-fix a diagnostic + non-zero rc surface in all three modes.
  - §3 (**A6**): pre-fix build proceeds on detached HEAD; post-fix it FAILs loudly.
  - §4 (**A7**): pre-fix deps failure is discarded; post-fix the TDD FAILs with cause.

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
| FR-16 (opens PRs; never merges) | `_publish_pr` is the one publish path for all three modes; it pushes + opens the PR and never merges |
| FR-19 (per-TDD report + merge plan) | the report wording per mode is preserved at the call site; a publish failure now surfaces into the report instead of a false success |
| FR-27 (pr_url record) | call sites keep their existing pr_url recording; helper returns the value |
| FR-69 (self-compliance with Theme A) | collapses the 3 duplicated publish blocks in implement.sh into one helper, reducing the script's duplicated scope |
| ADR 0006 (artifacts grounded) | push/create/checkout/deps failures surface a diagnostic + non-zero rc rather than a false success |
| bug A8 | sequential failure-surfacing becomes the shared contract; Verification §2 |
| bug A6 | combined-mode checkout rc checked, FAIL-not-detached; Verification §3 |
| bug A7 | install_deps rc captured, FAIL on total failure; Verification §4 |

No gaps.

## Dependencies considered
No new dependency — uses the `git`/`gh` CLIs already required for PR output. Chosen:
one in-file `_publish_pr` helper. Rejected alternative:
- **Leave the three publish blocks, just add the missing diagnostics to the
  parallel/combined copies** — rejected: fixes A8 but leaves three copies of the
  publish CLI to re-diverge (reuse #5), and does not address the checkout/deps
  swallowing (A6/A7) which live at the same driver layer.

## PRD conflicts surfaced (and resolution)
None. Hardens the existing publish/output requirement; no ADR reversed.

## Decisions to promote (ADR candidates)
None. An in-file driver helper is not a durable cross-cutting decision.

## Touched files
- `scripts/implement.sh` — `_publish_pr` helper; repoint 3 publish sites (A8); check combined-mode checkout rc (A6); capture install_deps rc (A7).
- `tests/gated-implementation.test.sh` — publish-failure-surfaced + checkout-fail + deps-fail regressions.

## Expected diff size
- `scripts/implement.sh` — 90 lines (helper ~30 + 3 site rewrites + checkout/deps rc checks; ×1.4 shell-script).
- `tests/gated-implementation.test.sh` — 110 lines (3 publish-mode cases + checkout + deps regressions, with git/gh stubs; ×1.6 test).
Total expected diff: ~200 lines across 2 files. No per-file exception needed.

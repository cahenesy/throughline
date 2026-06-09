# TDD 0045: Review-gate intent-conformance + policy-shadow lenses
Status: draft
PRD refs: FR-10, FR-15
PRD-rev: 0aa1e28
ADR constraints: 0005, 0006

## Approach
The independent review gate (`scripts/review-prompt.md`, FR-15(d)) judges the
build's diff on its merits. Two recurring blind spots in prompt/framework work
motivate sharpening it — both observed in this repo's own build history:

1. **Documented-but-unenforced drift.** A constraint stated in an in-scope FR or
   accepted ADR is "satisfied" in narrative but has no enforcement point in the
   code — e.g. a rule the prompt claims to apply that no sentinel or check
   actually reads. The current review checks the diff against the TDD's claims;
   it does not systematically ask "for each in-scope constraint, WHERE is it
   enforced, or is its absence provable?"
2. **Policy-shadow tests.** A test asserts an *extracted decision-helper*
   (e.g. a pure function that returns the right verdict) but the *framework* may
   never call that helper on the real path — so the test is green while the
   behavior is unenforced. The review does not currently distinguish a test that
   exercises the REAL enforcement path from one that exercises a shadow of it.

Both are added as REVIEW LENSES — additional analyses the existing pass performs
before its verdict — NOT as a new gate (ADR 0005: scope authority stays with the
design-critique gate and the four build gates; this adds rigor to gate 4, it
does not add a gate). Findings use the existing §1 finding schema and existing
severity model; both lenses are grounded (ADR 0006): a finding must cite both
sides (the documenting FR/ADR line AND the code location or its provable
absence).

## Components & interfaces
Both changes are in `scripts/review-prompt.md`, added after the existing
`## Grounding (FR-70 / ADR 0006)` section and before the per-file disposition
block, so the lenses inherit the grounding rules.

- **`## Lens: intent-conformance (FR-10 / FR-15(d))`** — instructs the reviewer:
  for each FR/ADR constraint *in this TDD's scope* (the TDD's `PRD refs` and
  `ADR constraints`, NOT every constraint in the repo), locate the enforcement
  point in the scoped diff, or establish its provable absence.
  - "Documented-but-unenforced is a finding": a constraint the TDD/PRD says
    holds, for which no diff line enforces it, is a finding.
  - **Cite both sides** (ADR 0006): the finding `evidence` must quote the
    documenting line (`docs/PRD.md` / the ADR / the TDD) AND name the code
    location that should enforce it (`<file>:<line>`) or state the searched
    locations that prove its absence.
  - **Severity by boundary:** a mismatch that crosses a real behavioral boundary
    (a governance/safety/correctness rule that can now be violated unobserved)
    is `blocker`/`major` with `pattern_tags: [intent-unenforced]`; a cosmetic or
    redundant-doc mismatch is `minor`. Scope guard: the lens applies ONLY to the
    in-scope constraint set — it never blocks a small diff for an unrelated
    repo-wide constraint it did not touch.
- **`## Lens: policy-shadow tests (FR-15)`** — instructs the reviewer: when a
  test asserts a helper/function in isolation, check whether the *framework*
  actually invokes that helper on the path the requirement governs.
  - A finding is raised ONLY when the reviewer can NAME the real enforcement
    path (`<file>:<line>` where the framework should call the helper) AND show
    the test misses it (the test imports/calls the helper directly without
    driving the framework entry point). If the reviewer cannot show the concrete
    gap, NO finding is raised — this keeps the lens grounded and prevents false
    positives on tests that do exercise the real path.
  - Severity: a shadow test for a governance/gate behavior is `major` with
    `pattern_tags: [policy-shadow]`; raise it against the test file's region.

Neither lens changes the `REVIEW_RESULT:` contract, the per-file disposition
requirement, or the verdict line. They add finding categories the existing
severity-honest reporting (FR-21 / TDD 0021) already governs.

## Data & state
None. Prompt-only change plus its test; no runner state, no new sentinel, no
verdict-format change.

## Sequencing / implementation plan
1. Add the `## Lens: intent-conformance` section to `review-prompt.md` (in-scope
   constraint set, both-sides citation, boundary severity, scope guard).
2. Add the `## Lens: policy-shadow tests` section (name-the-real-path
   requirement, no-finding-without-concrete-gap rule).
3. Add `tests/review-lenses.test.sh` asserting the rendered prompt carries both
   lenses with their grounding + scope-guard clauses; register it in
   `tests/implement-gate.test.sh`.

## Failure modes & edge cases
Real risks:
- **Over-blocking on out-of-scope constraints.** Mitigated by the explicit
  in-scope-set guard: the lens domain is the TDD's `PRD refs` + `ADR
  constraints`, not the whole repo.
- **Policy-shadow false positives** (flagging a test that DOES drive the real
  path). Mitigated by the name-the-real-path rule: no finding unless the
  reviewer cites the concrete uncalled enforcement location.

Overblown risks:
- **Lens noise drowning real findings.** The existing severity model + per-file
  disposition already bound output; minors do not block.

Unspoken risks (elephants):
- **A reviewer "satisfying" the lens with a generic remark** rather than the
  required both-sides citation. The grounding rule (ADR 0006) already rejects an
  evidence field without a verbatim artifact quote, which the lens reuses.

## Verification plan
- **Observable surface:** the rendered review prompt (what the review `claude -p`
  receives) — the text `_render_review_prompt` produces.
- **Observation point(s):** render the prompt via the same path
  `tests/implement-gate.test.sh` uses (source `gates.sh`, call
  `_render_review_prompt` with a fixture TDD/scope), and `grep` the output.
- **Expected observations (PASS):** the rendered prompt contains the
  intent-conformance lens (with the "in-scope" scope guard, the "cite both
  sides" clause, and the boundary-severity rule) and the policy-shadow lens
  (with the "name the real enforcement path" / "no finding without a concrete
  gap" clause). A control assertion confirms the `REVIEW_RESULT:` verdict
  contract text is unchanged (the lenses did not alter the verdict block).

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | every in-scope FR/NFR maps to a concrete named design element (sentinel/block/function/report section); gaps called out | all mapped, some terse | an FR untraced or hand-waved |
| Interface concreteness | exact marker/sentinel names, file paths, block format, status-enum values specified | mostly concrete, minor gaps | "emit a coverage block" with no format |
| Anti-false-green rigor | the pinned/proposed/justified-no-surface/unverified-gap distinction has a falsifiable mechanism (pinned requires a cited asserting test) | mechanism present | left to model discretion, no citation rule |
| No-conflict reconciliation | each new norm/lens explicitly reconciles with mandated duties (same-commit stale-doc update; ADR 0005/0006/0008) | reconciled | contradicts an existing instruction |
| Verification-plan actionability | observable surface + observation point + expected observation named (or justified SKIP) | present, somewhat generic | non-actionable — a vague verb instead of a named surface/observation |
| Scope-bound adherence | within body/diff/touched bounds or inline exceptions; estimates padded per the underestimation lesson | within bounds | blows a bound silently |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-10 (design/intent conformance judged at review) | `## Lens: intent-conformance` — for each in-scope FR/ADR, enforcement point or provable absence |
| FR-15(d) (independent review gate rigor) | both lenses added to `review-prompt.md`; existing verdict + severity model unchanged |
| FR-15 (meaningful tests, not shadows) | `## Lens: policy-shadow tests` — distinguish real enforcement path from a helper shadow |
| ADR 0006 (artifact grounding) | both lenses require both-sides verbatim citation; no-finding-without-concrete-gap |
| ADR 0005 (no new gate) | lenses are analyses within gate 4, not a new gate; scope authority unchanged |

## Dependencies considered
No new dependency — prompt text plus a grep-based render test. Considered adding
a separate static "enforcement-point" linter (rejected: enforcement of a
governance rule is semantic, not mechanically greppable in general; the review
model with the both-sides citation rule is the right tool and stays grounded).

## PRD conflicts surfaced (and resolution)
None. Sharpens existing FR-10 / FR-15(d) review behavior without changing the
PRD.

## Decisions to promote (ADR candidates)
None. Extends ADR 0006 grounding to two new lens categories; consistent with it,
no reversal, no new cross-cutting decision.

## Touched files
- scripts/review-prompt.md — add intent-conformance + policy-shadow lenses (grounded, scoped, severity-by-boundary)
- tests/review-lenses.test.sh — assert both lenses present in the rendered prompt; verdict contract unchanged
- tests/implement-gate.test.sh — register the new eval

## Expected diff size
- scripts/review-prompt.md — 72 lines
- tests/review-lenses.test.sh — 115 lines
- tests/implement-gate.test.sh — 10 lines
Total expected diff: 197 lines across 3 files.

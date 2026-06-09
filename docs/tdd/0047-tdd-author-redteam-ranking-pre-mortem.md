# TDD 0047: tdd-author red-team ranking + pre-mortem taxonomy
Status: draft
PRD refs: FR-76
PRD-rev: 0aa1e28
ADR constraints: 0006

## Approach
FR-76 gives the tdd-author interrogator an anti-sycophancy posture and a tracked
OPEN ASSUMPTIONS list. Two upgrades sharpen the design quality the interrogation
produces, both drawn from established product-design practice:

1. **Red-team ranking of load-bearing assumptions.** The interrogator already
   surfaces assumptions; it does not PRIORITIZE them. Add a discipline: rank the
   tracked assumptions by **impact × likelihood × cheapness-to-test**, write each
   as a falsifiable "fails if ___" statement, and surface the top few for the
   user to confront first — so the riskiest, cheapest-to-check assumptions get
   attention rather than whichever surfaced last.
2. **Pre-mortem failure-mode taxonomy.** The TDD `## Failure modes & edge cases`
   section is currently unstructured prose. Add a recommended three-way structure
   — **Real risks / Overblown risks / Unspoken risks (elephants)** — so the
   author is prompted to separate genuine risks from overblown ones AND to name
   the risk nobody stated. (This is the structure the four TDDs in THIS set
   already use.) It is a recommended structure WITHIN the existing section, NOT a
   new linter-required heading — the `tdd-lint` required-section set is unchanged.

Both are SKILL.md authoring-guidance changes. The ranking reuses the existing
assumption-tracking mechanism (no new persistence); the taxonomy reuses the
existing `## Failure modes & edge cases` section (no template/lint change).

## Components & interfaces
- **`skills/tdd-author/SKILL.md`, "Interrogator discipline (FR-76)" section** —
  add a **"Red-team ranking"** bullet after the existing "Tracking" bullet:
  - After surfacing assumptions, rank them by impact × likelihood ×
    cheapness-to-test; phrase each as a falsifiable "fails if ___" clause.
  - Surface the top-ranked few to the user first (the ranking orders the
    interrogation, it does not change the completion gate — every tracked
    assumption still ends `resolved:`/`waived:` per the existing rule).
  - The ranking is advisory ordering; it does NOT add a new persisted field —
    the "fails if ___" phrasing rides in the existing
    `tl_draft_append_elicit … "assumption: <one-line>"` challenge text.
- **`skills/tdd-author/SKILL.md`, the template + step-7a self-review** — add a
  one-line note under the `## Failure modes & edge cases` template entry:
  > Recommended structure: **Real risks** (genuine, with mitigations) /
  > **Overblown risks** (named and deflated) / **Unspoken risks (elephants)**
  > (the failure nobody stated). Plain labels; the metaphor is noted once. This
  > is guidance within the section, not a required sub-heading.
  And a matching self-review checklist line: "Failure-modes section separates
  real from overblown risks and names at least one unspoken (elephant) risk, or
  states why none applies."

No change to `tdd-lint.sh`'s required-section list, to the draft schema, or to
the `## Failure modes & edge cases` heading itself.

## Data & state
None new. The ranking phrasing rides existing assumption draft entries; the
taxonomy is prose structure within an existing section.

## Sequencing / implementation plan
1. Add the "Red-team ranking" bullet to the Interrogator-discipline section of
   `skills/tdd-author/SKILL.md`.
2. Add the failure-mode taxonomy note to the template entry and the self-review
   checklist line.
3. Add `tests/tdd-author-redteam.test.sh` asserting both additions are present
   in the rendered SKILL.md; register it in `tests/implement-gate.test.sh`.

## Failure modes & edge cases
Real risks:
- **Ranking formalism bloating the interview.** Mitigated: the ranking is an
  ordering of assumptions already being surfaced — no new questions, no new
  persisted field; it reuses the existing challenge text.
- **Taxonomy misread as a required heading** that `tdd-lint` would then demand.
  Mitigated: explicitly "recommended structure within the section"; the
  `tdd-lint` required-section set is unchanged and the test asserts the heading
  set is NOT expanded.
- **Test false-pass from the matched learnings (L-001, L-002).** Both prior
  learnings touched `skills/tdd-author/SKILL.md`: L-001 (an inverted removal
  grep firing `ok` on grep exit-2 = file-missing, not just exit-1 =
  string-absent) and L-002 (a content check running after an early-return on a
  missing file, emitting a misleading content failure). The eval here is a
  *presence* check, but it must (a) assert the SKILL.md file EXISTS and is
  readable before any content grep, failing with an infra-message (not a content
  message) if not, and (b) use direct positive `grep -q` presence assertions
  (exit 0 = found), never an inverted `! grep` whose exit-2 on a missing file
  would read as success.

Overblown risks:
- **The taxonomy constraining genuinely-different failure-mode shapes.** It is
  recommended, not mandatory; an author may state "no overblown risks apply".

Unspoken risks (elephants):
- **The ranking criteria (impact × likelihood × cheapness) being applied as
  theater** — numbers without judgment. Mitigated by requiring the falsifiable
  "fails if ___" phrasing, which forces a concrete failure condition rather than
  a score.

## Verification plan
- **Observable surface:** the `skills/tdd-author/SKILL.md` file content (the
  skill text the tdd-author session loads).
- **Observation point(s):** read the SKILL.md file in the test (after asserting
  it exists and is readable — guard per L-002) and `grep -q` for the additions.
- **Expected observations (PASS):**
  - The Interrogator-discipline section contains the "Red-team ranking" guidance
    (impact × likelihood × cheapness-to-test AND the "fails if ___" phrasing).
  - The failure-modes template entry contains the Real/Overblown/Unspoken
    taxonomy note, and the self-review checklist contains the matching line.
  - A control assertion confirms `tdd-lint.sh`'s required-section list was NOT
    changed to demand a new sub-heading (the taxonomy stays advisory).
  - The eval emits an INFRA-failure message (distinct from a content-failure
    message) if SKILL.md is unreadable, and uses positive `grep -q` (never an
    inverted `! grep`) so a missing file cannot read as a pass (L-001/L-002).

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
| FR-76 (interrogator discipline) | "Red-team ranking" bullet — rank assumptions impact × likelihood × cheapness, "fails if ___" phrasing |
| FR-76 (failure-mode authoring) | Real/Overblown/Unspoken taxonomy note in the template + self-review checklist line |
| ADR 0006 (grounding) | the "fails if ___" phrasing keeps each ranked assumption falsifiable, consistent with grounded design |

## Dependencies considered
No new dependency — SKILL.md prose plus a grep-based presence test. Considered a
structured scoring field persisted in the draft for the ranking (rejected: adds
a draft-schema field and a new mechanism for what is advisory interview ordering;
the existing assumption entries already carry the challenge text).

## PRD conflicts surfaced (and resolution)
None. Strengthens FR-76 interrogation/authoring without changing the PRD.

## Decisions to promote (ADR candidates)
None. Authoring-guidance refinement; no durable cross-cutting decision.

## Touched files
- skills/tdd-author/SKILL.md — add red-team ranking bullet + failure-mode taxonomy note + self-review line
- tests/tdd-author-redteam.test.sh — assert both additions present; infra-guarded, positive-grep (L-001/L-002)
- tests/implement-gate.test.sh — register the new eval

## Expected diff size
- skills/tdd-author/SKILL.md — 60 lines
- tests/tdd-author-redteam.test.sh — 130 lines
- tests/implement-gate.test.sh — 10 lines
Total expected diff: 200 lines across 3 files.

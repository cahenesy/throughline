# 0008. Rework authoring on the build model (author↔reviewer diversity over gate-1-internal cost reduction)
Status: accepted
Date: 2026-06-09
Scope: workflow / gate-architecture / model-diversity

## Context

The bounded-rework gate (ADR 0007 / TDD 0019) authors code-fixes for a halting
review finding. ADR 0007's Consequences recorded a deliberate disposition:
"Rework runs on Sonnet by default; the original-build/rework model diversity
within gate 1 is a deliberate cost-reduction choice." That choice read NFR-3's
model-diversity requirement at the **gate-1 (build) ↔ gate-d (review)** boundary
and accepted Sonnet for rework as cheaper and less prone to opportunistic
refactoring than Opus.

NFR-3's text, however, is about the **author↔reviewer** relationship: "the review
gate runs on a different model … so the reviewer does not share the **author's**
blind spots." The review gate runs on **Sonnet**. So when rework is authored by
**Sonnet** and then re-reviewed by the **Sonnet** review gate, the rework's author
and its reviewer are the *same model* — on every rework iteration the reviewer
shares the author's blind spots, the exact condition NFR-3 exists to prevent. The
narrower gate-1↔gate-d reading missed this because it treated rework as part of
gate 1's diversity story rather than as a distinct authoring act that gate d
re-reviews.

Two further facts shifted the balance since ADR 0007 was written: the build/rework
model in use (Opus 4.8) is materially less prone to the opportunistic "wandering"
refactor that motivated the Sonnet choice, and the **FR-66 per-attempt scope cap**
(`max(60, 3 × finding-region)` + hard-reset of an oversized rework commit before it
ships) bounds a wandering rework *regardless of which model authored it*.

## Decision

The bounded-rework gate **authors on the build model** (Opus by default;
`THROUGHLINE_REWORK_MODEL` still overrides at the same two resolution sites). The
pipeline therefore uses the strong build model for **all code-writing — build AND
rework — and reserves Sonnet for the review gates only**. This restores NFR-3
author↔reviewer diversity on rework iterations: an Opus-authored rework is
re-reviewed by the Sonnet review gate, so the reviewer no longer shares the
author's model.

This decision **revises ADR 0007's rework-model consequence specifically**. ADR
0007's CORE decision — the halt model (bounded rework + structural escalation, not
first-failure halt) — is **unchanged and remains `accepted` and binding**. This
ADR does not supersede ADR 0007; it narrows one of its recorded consequences. Per
the append-only convention (ADR 0001), ADR 0007's body is not edited; this ADR and
the index record the relationship.

## Consequences

- Rework iterations cost more (Opus vs Sonnet per attempt). The FR-68 rework
  token-spend telemetry surfaces the delta; cost is the accepted price of
  author↔reviewer diversity on rework.
- The opportunistic-refactoring ("wander") risk ADR 0007/TDD 0019 guarded against
  is reintroduced in principle, but bounded in practice by the **model-independent**
  FR-66 scope cap + pre-pass hard-reset (an oversized rework is rejected before it
  ships, whoever authored it) and mitigated by Opus 4.8's improved restraint.
- Operators who want the prior cost profile set `THROUGHLINE_REWORK_MODEL=sonnet`
  (the override path is unchanged); this ADR changes only the default.
- ADR 0007's Consequences text still reads "Rework runs on Sonnet by default" as a
  historical record of the prior disposition; this ADR is the current operative
  decision on the rework authoring model, and the ADR index points here.
- Implemented by TDD 0043 (the default flip + doc/test reconciliation); this ADR
  rides that design PR.

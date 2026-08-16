# 0014. Model capability by job (fresh worker, not a different named model)
Status: accepted
Date: 2026-08-16
Scope: workflow / gate-architecture / model-selection
Supersedes: 0009

## Context
NFR-3 was rewritten (PRD-rev 5dbf968, PR #178). Review independence is a
**fresh worker** — a context that is not the author's session — not a
different named model. Judgment work defaults to the most capable model
on the harness. The only job that defaults cheap is mechanical
runtime-verify (FR-52).

ADR 0009 still binds the opposite pairing: build = latest top-tier,
review = prior-generation top-tier, with a derivation that keeps
author≠reviewer by name. That pairing is now a requirements violation.
`scripts/lib/models.sh` and `agents/design-reviewer.md` (`model: sonnet`)
still implement 0009.

FR-86 adds a parent-session check whose bar is the vendor's current
most-capable coding model. A shipped family/rank table would go stale
the way 0009's product names did. A Models-API recency order is not
capability (Sonnet 5 and Opus 5 shipped after Fable 5).

ADR 0008 (rework authors on the build model) is left accepted. Automatic
rework is already retired by ADR 0013; 0008 has no live caller.

## Decision
- **Dispatch defaults** live in exactly one file: `scripts/lib/models.sh`
  (`tl_resolve_models`). Unset `build=` and `review=` are the **same**
  latest top-tier id on that harness. Mechanical `verify=` stays on the
  cheaper id; nontrivial verify follows `build=`. Env pins
  (`THROUGHLINE_BUILD_MODEL`, `THROUGHLINE_REVIEW_MODEL`,
  `THROUGHLINE_RUNTIME_VERIFY_MODEL`) still win. A cheaper pin on
  implementer or reviewer is honored; the parent warns and continues
  (FR-87). Rebinding the literals when a generation ships is an
  implementation change, not a new ADR.
- **Independence** is a separate worker, not a different model name.
  The FR-10 design-reviewer and the FR-15(d) reviewer may use the same
  model id as the author. Same-session self-review is still forbidden.
  Agent frontmatter inherits the parent (`model: inherit`); it does not
  pin a product name.
- **FR-86 compare** is not the dispatch table. Each `/prd-author`,
  `/tdd-author`, and `/build-tdds` invoke observes the parent model from
  the harness session artifact and fetches the official models page
  **this turn**. Weaker or unreadable → warn+ask. No static rank map.
  This decision **revises ADR 0010's recorded consequence** that review
  flip authority is a “different-model artifact”: the artifact is still
  required (ADR 0011); the model name need not differ. ADR 0010's core
  (dual-harness overlay, optional delegates) is unchanged.

## Consequences
- Review and design-critique default to the same id as the implementer.
  Blind-spot diversity is a fresh context, not a cheaper or older model.
- Mechanical verify remains the only default-cheap slot (FR-52).
- The morning a vendor ships a new flagship, FR-86 may nag a session
  that is still on the `models.sh` default until that file is rebound.
  That nag is the rebind signal.
- ADR 0009's prior-gen derivation and rollback pairing (`opus` build →
  `sonnet` review) are no longer defaults. Operators who want that
  pairing set `THROUGHLINE_REVIEW_MODEL` explicitly and accept the
  FR-87 warning.
- ADR 0010's body still says “different-model artifact”; this ADR and
  the index record the revision. The body is not edited.

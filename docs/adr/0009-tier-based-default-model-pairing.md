# 0009. Tier-based default model pairing (latest top tier builds; prior-gen top tier reviews)
Status: accepted
Date: 2026-06-12
Scope: workflow / gate-architecture / model-diversity

## Context

NFR-3 (model diversity) and the ADRs that instantiate it have historically
named concrete products. ADR 0008's Decision reads "authors on the build model
(Opus by default…)" and "reserves Sonnet for the review gates only"; NFR-3
itself read "(opus default)… (sonnet default)" until the PRD tier-language
revision (PR #156, PRD-rev d7bc491). Product names in durable documents go
stale every model generation: when Fable 5 shipped, every such sentence
silently described the second-best pairing while still reading as current.

The concrete trigger: a two-run pilot of a fable-build/opus-review pairing
(the 0054 rebuild, run 20260611-200724, and 0056, run 20260611-220255) — both
end-to-end clean with zero rework attempts and zero halts, where the
comparable opus-build/sonnet-review era required `--recover` and structural
revisions (0049, 0055 among others), and session history had repeatedly shown
the REVIEW gate, not the build, to be the pipeline's noise source. Two runs is
a thin evidence base for a default; what makes the change cheap is that the
review-model derivation maps an explicit opus build to a sonnet review, so the
legacy pairing remains one flag away.

## Decision

Default model assignment is **tier-based, not product-based**:

- The **build** (and, per ADR 0008, **rework**) default is the **latest
  top-tier model** — the strongest current-generation model available.
- The **review-gate** default is the **prior generation's top-tier model** — a
  different, still-strong model, preserving NFR-3's author≠reviewer diversity
  with minimal capability sacrifice in the gate that session evidence shows
  needs it most.
- Concrete product names are bound in exactly ONE place: the runner's model
  resolution (`resolve_models()` in `scripts/implement.sh`), overridable via
  the existing flags/env. Prose surfaces (PRD, skills, plugin description)
  speak tiers.
- **Rebinding the names when a new generation ships is a normal
  implementation change** — a TDD/PR updating the resolution defaults — not a
  new ADR and not a requirements change. This ADR records the principle; the
  binding-of-record as of 2026-06 is **fable (build/rework) / opus (review)**.

This decision **revises ADR 0008's recorded product-name consequences
specifically** ("Opus by default", "reserves Sonnet for the review gates
only"), exactly as ADR 0008 revised ADR 0007's rework-model consequence. ADR
0008's CORE decision — rework authors on the build model so the reviewer never
shares the rework author's blind spots — is **unchanged, accepted, and
binding**; under this ADR it reads "rework authors on the build-tier model".
Per the append-only convention, ADR 0008's body is not edited; this ADR and
the index record the relationship.

## Consequences

- Builds and rework run on the latest top tier (~2× the prior per-token
  price); review runs one generation back instead of two tiers down. Pilot
  telemetry (FR-68) showed roughly flat net dollar spend — fewer tokens and
  zero recovery round-trips offset the rate — but the evidence base is two
  runs; the telemetry keeps the cost observable per run, and the legacy
  pairing remains reachable via `--model opus` (whose review derives sonnet)
  or the `THROUGHLINE_*_MODEL` env bindings.
- The runtime-verify mechanical tier (FR-52) is intentionally NOT rebound by
  this ADR — it stays a cost-efficient lower-tier binding in the runner;
  nontrivial verification plans follow the build model and so move with the
  build tier automatically.
- A tier claim can read stale in the OTHER direction when a new generation
  ships and the binding hasn't been rebound yet — the failure mode is a stale
  default (builds run one generation behind "latest"), never a broken run or
  a diversity violation: the derivation keeps author≠reviewer for every
  build model.
- Documents that previously cited the opus/sonnet pairing as current should
  cite the tier principle (this ADR) rather than re-naming products.

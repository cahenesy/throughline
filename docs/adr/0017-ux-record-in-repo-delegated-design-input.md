# 0017. UX record: in-repo, self-contained HTML, delegated by role, design input not a build gate
Status: accepted
Date: 2026-10-06
Scope: workflow / ux / plugin-architecture

## Context
PRD FR-89–FR-101 add an optional `/ux-author` phase between `/prd-author`
and `/tdd-author`. It runs for requirements marked `[UI]`, and the human
gates its output in a PR. TDDs 0070–0072 design it. Several choices in
that design are durable stances that later work would otherwise reopen:
- where the UX record lives;
- who produces the visual design;
- what authority mocks have over the build.

Two existing ADRs relate to them. ADR 0004 delegates the verification
*mechanism* to the project, and ADR 0010 makes engineering delegates
optional. The superseded ADR 0001 lineage had throughline own the
authoring phases while delegating ideation. This ADR extends that
ownership to a third authoring phase, UX, and delegates its design
work.

## Decision
1. **The record is in git, self-contained, and machine-checkable.** The
   UX record of record lives under `docs/ux/`:
   - offline HTML mocks, one per screen and state, with no `http(s)` or
     `//` references;
   - `docs/ux/tokens.css`, CSS custom properties, as the design-system
     artifact;
   - `docs/ux/index.json` (schema v1), which maps `[UI]` requirement ids,
     with a text hash of each, to screens and records provenance and
     fidelity;
   - a generated `index.html` flow page;
   - PNG screenshots rendered by a headless Chrome/Chromium CLI when one
     is available.

   External design tools (Figma, hosted design canvases) may be used as
   delegates, but they are never the record.
2. **Visual design is delegated by role.** `/ux-author` invokes whatever
   the harness offers for the `design`, `design-system`, `critique` and
   `accessibility` roles. throughline code holds only the mechanics:
   parse, hash, validate, render and report. With no delegate, the
   session makes the mocks itself and declares the fidelity it reached
   (never `high`). The `delegates` field is self-reported, and the
   independent critique grades against the declared fidelity.
3. **Mocks are design input, not a build gate.** `/tdd-author` must cite
   merged mocks for each `[UI]` requirement, or record a waiver with a
   rationale. `/build-tdds` never compares built UI to mocks, and no
   visual-diff gate exists.

## Consequences
- Repos with `[UI]` requirements need python3 for UX tooling. Repos
  whose PRD contains no literal `[UI]` text are unaffected: every entry point those repos can reach
  (`/prd-author`'s marker check, `/tdd-author`'s coverage step, the
  `tdd-lint` citation check) short-circuits when no `[UI]` appears.
- Screenshot PNGs live in git history. A superseding UX run removes the
  superseded files, and Git LFS is not required.
- The record is reviewable in a plain PR and readable offline. It cannot
  drift with an external tool's later edits.
- The quality of the mocks depends on the delegates present. The degrade
  path keeps the phase completable on any harness (FR-79, FR-83).
- Adding a visual-diff or screenshot-comparison gate to `/build-tdds`
  later requires a new ADR that supersedes this one.
- Rejected alternatives:
  - **An external tool as the record:** it lives outside git, stays
    mutable after merge, and may be private.
  - **A visual-diff runtime-verify gate:** it couples verification to a
    browser and to pixel stability, which contradicts ADR 0004's
    delegated mechanism.
  - **Bundling a specific design skill:** it creates a hard dependency,
    which contradicts ADR 0010's optional delegates.

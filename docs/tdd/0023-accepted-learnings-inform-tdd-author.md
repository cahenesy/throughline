# TDD 0023: Accepted build-phase learnings inform future `/tdd-author` sessions

Status: implemented
PRD refs: FR-73
PRD-rev: 52c32b9
ADR constraints: 0003, 0004, 0005, 0006, 0007

## Approach

TDD 0022 persists human-accepted build-phase learnings to `docs/tdd/LEARNINGS.md`
(one `## L-NNN` entry per recurring pattern class, each carrying subject-area
hints: a `files=[...]` glob/path set and a `tags=[...]` set). FR-73 closes the
loop: when `/tdd-author` runs for a later PRD update, it surfaces the persisted
learnings that are *relevant to the TDD scope under design* as advisory context —
a signal "this class of issue has recurred in this project's prior builds." The
author decides what, if anything, to adjust. Learnings never block authoring and
open no new gate.

This is a skill-only change: `/tdd-author` already reads design inputs
(`BLOCKERS.md`, ADRs) and decides the TDD set. We add a parallel input
(`LEARNINGS.md`) and a surfacing step that runs once the set's rough scope is
known. The relevance match is **hybrid** (the user's choice): a cheap mechanical
pre-filter (the learning's recorded `files`/`tags` hints intersect the new TDD's
declared `## Touched files` and PRD-ref subject area) OR the author's model
judgment that the pattern bears on the design. The mechanical filter gives a
falsifiable floor; model judgment is the backstop for cross-cutting patterns that
share no files (e.g. a prompt-design class).

## Components & interfaces

### 1. Load the store — `skills/tdd-author/SKILL.md` step 4

Step 4 ("Load design constraints") gains: also read `docs/tdd/LEARNINGS.md` if
present. Each entry's `Pattern class`, `Subject-area hints` (`files`/`tags`), and
`Summary` are the matchable surface. An absent file is a no-op (no prior
learnings).

### 2. Surface relevant learnings — `skills/tdd-author/SKILL.md` step 5 lead-in

A new lead-in to step 5 ("Author the approved set"), placed after the TDD set and
its rough scope are decided in step 3 (relevance needs each new TDD's intended
touched-file/PRD-ref area). For each TDD about to be authored:

1. **Mechanical pre-filter.** A learning is a candidate match when its
   `files=[...]` hints intersect the paths the new TDD is expected to touch, OR
   its `tags=[...]` intersect tags/keywords from the new TDD's PRD refs or
   working title.
2. **Model-judgment backstop.** Independently, the author scans the remaining
   learnings and includes any whose `Summary`/class plausibly bears on the design
   even without a file/tag overlap.
3. **Surface, do not gate.** For each matched learning, surface it to the user as
   advisory: the class, the TDDs it recurred in, and the one-line summary, framed
   as "this class recurred in prior builds — consider whether this design should
   account for it." The author may fold a mitigation into the design or note why
   it does not apply. Authoring proceeds regardless; no `BLOCKED`/`PRECHECK_FAIL`
   is ever emitted for a learning, and the design-critique gate (step 7b) does
   not check learning incorporation.

When `LEARNINGS.md` is absent, or no learning matches a TDD's scope, step 5
proceeds with no surfaced learnings and no note (FR-73's negative case).

## Data & state

No new state. Reads `docs/tdd/LEARNINGS.md` (written by TDD 0022 §2); writes
nothing to it. The `## L-NNN` entry schema is owned by TDD 0022 — this TDD only
consumes the `Pattern class`, `Subject-area hints`, `Recurred across`, and
`Summary` fields.

## Sequencing / implementation plan

1. Edit `skills/tdd-author/SKILL.md` step 4 to also read `LEARNINGS.md`.
2. Add the step-5 lead-in (§2): hybrid match + advisory surfacing + the explicit
   non-blocking / no-gate statement.
3. Write `tests/learnings-inform-tdd-author.test.sh` asserting the skill carries
   the load + surface + non-blocking instructions, and exercising the match
   against a fixture `LEARNINGS.md`.

## Failure modes & edge cases

- **`LEARNINGS.md` absent.** Step 4 read is a no-op; nothing surfaced. (Common
  case before any run has produced accepted learnings.)
- **Malformed entry.** A learning entry missing `Subject-area hints` falls
  through the mechanical pre-filter and is reachable only by model judgment;
  it is never an error (advisory input, not a gated artifact).
- **A learning matches but the author judges it irrelevant to this design.** The
  author records a one-line "not applicable: <why>" and proceeds. No obligation
  to mitigate (FR-73: advisory).
- **Many learnings, broad match.** Surfacing is per-TDD and scoped by the
  mechanical filter first, bounding noise; model judgment widens only
  deliberately. No cap is imposed (the store grows slowly — one entry per
  human-accepted recurring class).
- **Stale learning naming a since-removed file.** The hint is a match heuristic,
  not a binding reference; a non-matching/over-matching hint at worst surfaces an
  irrelevant advisory the author dismisses. Consistent with the memory-recall
  caveat that hints reflect when written.

## Verification plan

**Observable surface:** the `skills/tdd-author/SKILL.md` instruction text, and a
`/tdd-author` session's surfaced-learnings output.

**Observation points & expected observations (PASS):**

1. **Skill loads the store.** `skills/tdd-author/SKILL.md` step 4 instructs
   reading `docs/tdd/LEARNINGS.md`. (Mechanical grep.)
2. **Skill surfaces with a hybrid match, non-blocking.** Step 5's lead-in
   instructs the mechanical `files`/`tags` pre-filter AND the model-judgment
   backstop, and states explicitly that learnings are advisory — no
   `BLOCKED`/`PRECHECK_FAIL`, and step 7b does not check incorporation.
   (Mechanical grep for the match instruction + the non-blocking clause.)
3. **Overlap → surfaced (behavioral).** Fixture: a `LEARNINGS.md` with one entry
   whose `files=` hint is `scripts/lib/state.sh`, and a TDD being authored whose
   `## Touched files` includes `scripts/lib/state.sh`. Expect: the session
   surfaces that learning as advisory before authoring that TDD.
4. **No overlap → not surfaced (behavioral).** Fixture: the same entry but the
   TDD touches only `docs/PRD.md` with an unrelated PRD ref and no plausible
   topical link. Expect: the session does not surface the learning and emits no
   note (FR-73 negative case).

Observation points §1–§2 are mechanical and run at implementation time; §3–§4
are observed in a `/tdd-author` session (the surfacing is a model behavior driven
by the instruction, exercised against the fixtures).

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-73 (accepted learnings surfaced as advisory when `/tdd-author`'s current TDD scope overlaps the learning's subject area; non-blocking; nothing surfaced when no overlap) | §1 step-4 store load + §2 step-5 hybrid match (mechanical `files`/`tags` pre-filter + model-judgment backstop) and advisory, explicitly non-gating surfacing; verification §1–§2 (instruction present, non-blocking) and §3–§4 (overlap surfaces, no-overlap stays silent) |

No gaps. The persisted store and its entry schema are produced by TDD 0022;
this TDD depends on that store existing.

## Dependencies considered

No new external dependencies. The change is skill-prose plus a shell-based
content/fixture test. No library or service is introduced.

Depends on **TDD 0022** for the `docs/tdd/LEARNINGS.md` store and its `## L-NNN`
entry schema (the `Subject-area hints` field this TDD matches on). No alternative
store was considered here — the format is fixed by 0022, chosen with the user
(markdown, model-greppable) over a JSON store.

## PRD conflicts surfaced (and resolution)

The PRD's **"Subject-area overlap for learning surface (FR-73)"** open question
is resolved here as the hybrid match (mechanical `files`/`tags` intersection +
model judgment), per the user's decision — neither pure file-set intersection
(brittle for cross-cutting patterns) nor pure model judgment (no falsifiable
floor). No conflict with an accepted ADR. FR-73's "advisory, does not block"
requirement is honored by the explicit no-gate statement in §2 and is consistent
with the PRD non-goal that the plugin never auto-modifies design from learnings.

## Decisions to promote (ADR candidates)

None. See TDD 0022's note on the (optional, not-recommended) advisory-only ADR;
this TDD does not strengthen the case for it.

## Touched files

- `skills/tdd-author/SKILL.md` — step-4 `LEARNINGS.md` load + step-5 lead-in hybrid-match advisory surfacing (non-blocking)
- `tests/learnings-inform-tdd-author.test.sh` — new; content checks + fixture overlap/no-overlap observation points

## Expected diff size

- `skills/tdd-author/SKILL.md` — ~35 lines
- `tests/learnings-inform-tdd-author.test.sh` — ~90 lines

Total expected diff: ~125 lines across 2 files. No per-file exception needed.

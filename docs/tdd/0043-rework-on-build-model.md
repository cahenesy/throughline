# TDD 0043: Rework on the build model (Opus) — restore author↔reviewer diversity on rework iterations

Status: draft
PRD refs: NFR-3 (gap-closure: rework author↔reviewer diversity); FR-65; FR-66
PRD-rev: d289607
ADR constraints: 0005, 0006, 0007, 0008

## Approach

**NFR-3** requires that "the review gate runs on a different model … so the
reviewer does not share the author's blind spots." TDD 0019 set the bounded-rework
model to **Sonnet** (`THROUGHLINE_REWORK_MODEL:-sonnet`), arguing it preserved
NFR-3 at the *build↔review* boundary (build=Opus, review=Sonnet) and was cheaper
and less prone to opportunistic refactoring than Opus.

That reasoning has a gap on the boundary NFR-3 actually names — **author↔reviewer**.
The review gate runs on **Sonnet**. With Sonnet-rework, a rework attempt's *author*
is Sonnet and its *reviewer* (the same consolidated/per-step review gate that
re-evaluates the reworked diff) is also Sonnet — so on every rework iteration the
reviewer **shares the author's model and blind spots**, the exact condition NFR-3
exists to prevent. 0019's "preserves NFR-3" claim held only for the *original*
build (Opus) vs review (Sonnet); it did not cover the rework author vs review
relationship.

This TDD flips the rework default to the **build model (Opus)** so the pipeline
uses Opus for **all code-writing (build AND rework)** and Sonnet **only** for the
review gates. The effect on NFR-3 is a *restoration*, not a regression: a rework
authored by Opus is re-reviewed by Sonnet — author≠reviewer, blind spots not
shared — exactly as the original build is. Secondary benefit: code-writing quality
consistency on the strongest model.

**Tradeoffs (accepted).** Opus rework costs more than Sonnet, and 0019 cited
Opus's tendency to *opportunistically refactor* unrelated code when told to fix one
finding — a real risk in an unattended loop. Two things bound it: (a) Opus 4.8 is
materially less wander-prone than the model 0019 was written against; (b) the
**FR-66 per-attempt scope cap** (`max(60, 3 × finding-region)`) and the rework
scope pre-pass already **hard-reset an oversized rework off the branch before it
ships**, regardless of which model authored it — so a wandering Opus rework is
bounded and rejected, never merged. The model change does not touch that guard.

ADR alignment: **0006** — the model is a config value passed to the gate's
`claude -p`, recorded in `rework_log[*].model` (a verifiable artifact); **0007** —
the halt model (bounded rework + structural escalation) is unchanged; only which
model authors the rework changes. **0005** — runner-side config, not a sandbox.

**Honest framing of the reversal.** 0019 — and **ADR 0007** (Consequences:
"Rework runs on Sonnet by default; the original-build/rework model diversity
within gate 1 is a deliberate cost-reduction choice") — did not merely *miss* the
author↔reviewer reading; they *deliberately* adopted the narrower gate-1↔gate-d
reading and accepted Sonnet-rework/Sonnet-review as a recorded cost-reduction
disposition. Both readings of NFR-3's text are defensible. This TDD argues the
author↔reviewer reading is the one NFR-3's wording ("the reviewer does not share
the **author's** blind spots") most directly supports, AND that operational
experience (the strong model authoring code throughout) favors the flip — so it
revises that ADR-level disposition deliberately, not by claiming 0019/0007 were
simply wrong. Because this changes a decision an **accepted ADR records**, it is
handled at the ADR level (see `## Decisions to promote` → ADR 0008 and
`## PRD conflicts surfaced`), not silently.

On the TDD axis this is a **gap-closure**, not a supersession: 0019's rework-loop
mechanism (FR-61/62/65/66/67/68) is intact and authoritative. Only the one default
value 0019/0007 set — and the specific "Rework-on-Sonnet" cost-reduction
disposition — is revised here, via a new ADR scoped to that decision.

## Components & interfaces

### 1. Rework-model default → the build model — `scripts/lib/gates.sh`

Two sites resolve the rework model from the same knob with a `sonnet` fallback:

- `gates.sh:1351` — `local rm="${THROUGHLINE_REWORK_MODEL:-sonnet}"`
- `gates.sh:1876` — `local model="${THROUGHLINE_REWORK_MODEL:-sonnet}"`

Change BOTH fallbacks `sonnet` → **`opus`**, so an unset `THROUGHLINE_REWORK_MODEL`
resolves to `opus` (the build default). The knob itself is unchanged — an explicit
`THROUGHLINE_REWORK_MODEL=<x>` still overrides at both sites (the override path is
untouched). The two sites MUST stay in lock-step (the same default), since they are
the resolve-for-spawn and resolve-for-telemetry reads of one value; a future helper
could centralize them, but this TDD keeps the minimal two-line change and the
verification asserts both resolve identically.

### 2. Documentation reconciliation — `skills/implement/SKILL.md`, `README.md`

Reconcile every doc that states the rework default is Sonnet so the docs match the
new default and the NFR-3 rationale:

- `skills/implement/SKILL.md:395` — the rework-loop description ("runs on the rework
  model (`sonnet` by default — cheaper and less prone …)") → state the rework runs
  on the **build model (`opus`) by default**, so Opus authors all code and Sonnet
  is reserved for the review gates (author↔reviewer diversity, NFR-3); note the
  knob still overrides.
- `skills/implement/SKILL.md:458` — the knob list (`THROUGHLINE_REWORK_MODEL`
  (default `sonnet`)) → default `opus`.
- `README.md:74` — the comparison-table line ("bounded automatic rework loop on
  **sonnet**") → on **opus** (or "the build model").
- `README.md:235` — the file-tree comment ("in-invocation **sonnet** rework +
  budget") → "in-invocation rework + budget" (drop the now-wrong model word rather
  than re-pin it in a one-line tree comment).

The SKILL.md:448 line (review gate "on a DIFFERENT model (sonnet by default) for
diversity") is about the REVIEW model and is **unchanged** — it is the other half
of the NFR-3 boundary and stays correct.

## Data & state

No schema change. `rework_log[*].model` already records the model per attempt
(0019); after this change a default run records `"model":"opus"` there. No run.json
config-shape change — `rework_config.model` already snapshots the resolved value
(it will now snapshot `opus` by default).

## Sequencing / implementation plan

1. Flip both `THROUGHLINE_REWORK_MODEL` fallbacks `sonnet`→`opus` in
   `scripts/lib/gates.sh` (Component 1).
2. Reconcile the rework-default text in `skills/implement/SKILL.md` (two sites) and
   `README.md` (two sites) (Component 2).
3. Update `tests/bounded-rework-loop.test.sh` at **four** assertion sites that
   currently encode the Sonnet default:
   - **A1** (`~line 44`): the default-model assertion now expects `opus`.
   - **A2** (`~line 58`): repoint the existing override test to override to
     `sonnet` (so it still proves `THROUGHLINE_REWORK_MODEL` overridability against
     the new default).
   - **E1** (`~line 605`) and **E2** (`~line 639`): both drive the rework loop on
     the *default* model (no `THROUGHLINE_REWORK_MODEL` export) and assert
     `"model":"sonnet"` while really testing rework *routing* (E1 structural→rework,
     E2 legacy `structural=true`→rework). The model is incidental telemetry there,
     so flip both assertions to `"model":"opus"`. (B7 at `~line 210` passes
     `sonnet` as a literal arg to `_record_rework_attempt`, not the default — it is
     unaffected and stays.)

## Failure modes & edge cases

- **The two gates.sh sites drift** (one flipped, one not) → telemetry and the
  spawned model would disagree. Verification §1 asserts BOTH resolve to `opus` on
  an unset knob, catching a half-applied change.
- **An operator who wants the old behavior** sets `THROUGHLINE_REWORK_MODEL=sonnet`
  — the override path is unchanged, so the old cost/behavior is one env var away
  (Verification §2).
- **Opus rework wanders (opportunistic refactor)** → unchanged guard: the FR-66
  scope cap + pre-pass hard-reset the oversized commit before it ships
  (model-independent). This TDD does not weaken that; it is the reason the wander
  risk is acceptable.
- **A doc left saying "sonnet rework"** → a stale claim contradicting the code.
  Verification §3 greps the reconciled docs (fail-closed) so a missed site is red.

## Verification plan

**Observable surface:** (a) the rework model resolved when `THROUGHLINE_REWORK_MODEL`
is unset — observable as `rework_log[*].model` / `rework_config.model` in the
state fragment (and the `--model` arg the rework `claude -p` is spawned with); (b)
the reconciled doc text.

**Observation points** (mechanical, in `tests/bounded-rework-loop.test.sh`'s
existing harness which stubs `claude` and records the rework `--model`, plus greps
on the docs):

1. **Default resolves to opus (both sites).** With `THROUGHLINE_REWORK_MODEL`
   unset, drive a rework attempt: the recorded `rework_log` entry has
   `"model":"opus"` (the existing line-44 assertion, flipped from `sonnet`). The
   telemetry read (gates.sh:1876) and the spawn read (gates.sh:1351) agree (the one
   recorded value reflects both).
2. **Override still honored.** With `THROUGHLINE_REWORK_MODEL=sonnet` exported, the
   same rework records `"model":"sonnet"` — proving the override path is intact
   against the new default (the repointed override test).
3. **Docs reconciled.** Grep `skills/implement/SKILL.md` and `README.md`
   (fail-closed: distinguish grep exit 1 from ≥2, assert each file readable) that
   the rework-default text says the build model / `opus` and that no stale
   "rework … on sonnet" / "rework model (`sonnet` by default" string remains. The
   review-gate "sonnet" mention (SKILL.md:448) is explicitly allowed (it is the
   review model, not the rework default).

**Expected observations (PASS):** §1 `opus`, §2 `sonnet`, §3 reconciled with no
stale rework-default string.

## Evaluation rubric

| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Default flip + doc reconciliation | both gates.sh sites flipped to opus; SKILL.md + README + knob-list all reconciled; no stale sonnet-rework text | flipped + main docs reconciled | a gates.sh site or doc still says sonnet rework default |
| NFR-3 rationale + 0019 reversal | NFR-3 author↔reviewer restoration traced; 0019 reversed decision noted honestly + wander-risk mitigation | rationale present | reversal unacknowledged / NFR-3 untraced |
| Test reflects new default | default-model test asserts opus; an override test still proves THROUGHLINE_REWORK_MODEL overridability | default test flipped | stale default=sonnet assertion left red |

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| NFR-3 (gap-closure: rework author↔reviewer diversity) | Component 1 makes the rework author Opus while the review gate stays Sonnet, so the reviewer no longer shares the rework author's model/blind spots — closing the gap 0019's Sonnet-rework left on rework iterations. Verification §1. |
| FR-65 (rework budget bound) | Unchanged by this TDD — the budget/escalation mechanism (0019) is intact; only the authoring model changes. The model is recorded per attempt as before. Verification §2 (telemetry still records the model). |
| FR-66 (bounded rework scope per attempt) | Unchanged and explicitly relied upon: the per-attempt scope cap + pre-pass hard-reset bound a wandering Opus rework, making the model flip safe. (No code change to the cap.) |

No gaps. (FR-67/68 and the rest of 0019's loop are untouched; this TDD changes
only the default authoring model.)

## Dependencies considered

No new dependency — the change is two fallback literals in the existing bash runner
plus doc/test reconciliation. The "model" is already a config value the runner
passes to `claude -p`.

Alternatives considered:
- **Keep Sonnet rework; accept the rework author↔reviewer sameness** — rejected:
  it leaves NFR-3 unmet on rework iterations (the reviewer shares the fix-author's
  model), and the operator wants code-writing consistency on the strongest model.
- **Set the default via operator env (`THROUGHLINE_REWORK_MODEL=opus` in settings)
  instead of changing the plugin default** — rejected by the operator: the desired
  behavior is the plugin's default for every run/repo, not a per-environment
  override that each setup must remember.
- **A third model for rework (e.g. Haiku) to keep author≠build AND author≠review**
  — rejected: adds a third model to the matrix for no NFR-3 benefit (Opus≠Sonnet
  already satisfies author↔reviewer diversity) and weakens code-writing quality;
  NFR-3 asks for reviewer≠author, not author≠build.

## PRD conflicts surfaced (and resolution)

No PRD requirement is contradicted — this **better satisfies** NFR-3 (the reviewer
no longer shares the rework author's model).

**Accepted-ADR conflict (ADR 0007).** It DOES conflict with an accepted ADR: ADR
0007's Decision/Consequences explicitly record "rework attempts run on Sonnet
(chosen …)" and "Rework runs on Sonnet by default; the original-build/rework model
diversity within gate 1 is a deliberate cost-reduction choice." Reversing that
is an ADR-level change, not a silent default flip. **Resolution:** promote a new,
narrowly-scoped **ADR 0008** ("Rework authoring on the build model — author↔reviewer
diversity over the gate-1-internal cost reduction"), which records the revised
decision and explicitly revises ADR 0007's rework-model consequence. ADR 0007's
CORE decision (the halt model: bounded rework + structural escalation) is unchanged
and stays `accepted`; only its rework-model cost-reduction disposition is revised by
0008. Per the append-only ADR convention (ADR 0001 / `adr-new`), ADR 0007's body is
NOT edited — 0008 carries the revision and the ADR INDEX records the relationship.
This TDD's `ADR constraints` lists 0008 alongside the still-binding 0007 halt model.

It also reverses the matching design decision in the implemented TDD 0019 (the
`THROUGHLINE_REWORK_MODEL=sonnet` default + its "Rework-on-Sonnet … preserves
NFR-3" traceability claim). 0019 stays `implemented` (gap-closure framing; its loop
mechanism is authoritative); only that one default + claim is revised, on the
strength of the author↔reviewer reading of NFR-3 and the FR-66 scope-cap mitigation
of the wander risk 0019/0007 were guarding against.

## Decisions to promote (ADR candidates)

**Promote ADR 0008 — "Rework authoring on the build model (author↔reviewer
diversity)."** (Required, high confidence.) Reversing ADR 0007's recorded
rework-on-Sonnet cost-reduction disposition is an ADR-level decision, so it cannot
be a silent default flip. ADR 0008 records: the rework gate authors on the build
model (Opus default) so Sonnet is reserved for the review gates, satisfying NFR-3's
author↔reviewer reading on rework iterations; it revises ADR 0007's rework-model
consequence specifically while ADR 0007's halt-model decision remains accepted; the
cost/wander tradeoff is accepted and bounded by the FR-66 scope cap. This skill
invokes `adr-new` to author ADR 0008, which rides this design PR with the TDD.

## Touched files

- `scripts/lib/gates.sh` — flip both `THROUGHLINE_REWORK_MODEL` fallbacks `sonnet`→`opus` (gates.sh:1351, :1876).
- `skills/implement/SKILL.md` — reconcile the rework-default text (rework-loop description :395 + knob list :458) to the build model (opus); review-model line :448 unchanged.
- `README.md` — reconcile the two rework-on-sonnet mentions (:74 comparison table, :235 file-tree comment).
- `tests/bounded-rework-loop.test.sh` — four assertion sites encoding the Sonnet default: A1 default `sonnet`→`opus`; A2 override test repointed to `sonnet`; E1 + E2 default-driven assertions `sonnet`→`opus` (B7's literal-arg case unaffected).

Total: 4 files touched (plus the new ADR 0008, which rides the design PR — see `## Decisions to promote`).

## Expected diff size

- `scripts/lib/gates.sh` — ~2 lines (two fallback literals).
- `skills/implement/SKILL.md` — ~6 lines (two text sites, including the rationale clause).
- `README.md` — ~2 lines (two mentions).
- `tests/bounded-rework-loop.test.sh` — ~10 lines (four assertion sites: A1/E1/E2 → opus, A2 override → sonnet).

Total expected diff: ~20 lines across 4 files. No exceptions needed (each file is far under the 300-line per-file bound). The new ADR 0008 is a separate doc that rides the design PR (ADRs are not counted in the touched-source-file scope bound).

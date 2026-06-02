# TDD 0028: Interrogator discipline for authoring interviews

Status: draft
PRD refs: FR-75, FR-76
PRD-rev: bfc8ad6
ADR constraints: 0004, 0005, 0006

## Approach

FR-75/FR-76 convert the authoring interviews from collaborative transcription
into explicit interrogation: the model aggressively surfaces unstated
assumptions, edge cases, conflicting goals, and feasibility concerns; every
surfaced item is tracked to an explicit disposition (resolved or waived with
rationale) before the interview is declared complete; and the disposition
record ships as an auditable artifact in the phase-gate PR body.

This is a **prompt-level change to two skills** — no runner code, no new
gates, no new state schema. Three design choices shape it:

1. **The open-assumptions list rides on the existing draft-persistence
   mechanism ([[0012]]).** Both skills already persist interview elicitations
   to a per-repo draft file via `scripts/lib/drafts.sh` (`tl_draft_append_elicit`),
   so a kill/compaction mid-interview already restores the conversation state.
   Assumptions are appended as elicitation entries with an `assumption:`
   header prefix — reusing the existing helper verbatim, no drafts.sh changes.
   A resumed session re-reads the draft and reconstitutes the open list.

2. **The record's home is the phase-gate PR body** (per FR-75/76's acceptance):
   `/prd-author`'s Git step and `/tdd-author`'s step 9 each gain an instruction
   to render the final list — every surfaced assumption with its disposition —
   as an "Open assumptions & waivers" section in the PR body. `/prd-author`
   additionally folds still-open (waived) items into the PRD's own
   `## Open questions` section so the artifact itself records what was
   consciously deferred.

3. **Anti-sycophancy language is specified verbatim here** (FR-75 requires it
   in the skill instructions, not as an implementation nicety) — see §1.

This extends [[0002]] (prd-authoring) and [[0003]] (tdd-authoring), both
`implemented`; their interview flows remain authoritative — interrogation is a
discipline layered onto those flows, not a replacement. Same extends-pattern
as [[0026]]/[[0027]].

## Components & interfaces

### 1. Interrogator-mode block — `skills/prd-author/SKILL.md`

A new subsection inserted into the `## Process` section, between the existing
step 2 (scope check) and step 3 (interview), titled **"Interrogator discipline
(FR-75)"**, containing:

- **Posture instruction:** "You are an interrogator, not a scribe. For every
  capability the user describes, actively hunt for: the unstated assumption it
  rests on, the edge case that breaks it, the goal it conflicts with, and the
  feasibility concern nobody raised. Surface these as direct challenges, not
  softened suggestions."
- **Anti-sycophancy instruction (verbatim, per FR-75):** "When you agree with
  the user you are not being helpful. You are most helpful when you challenge
  their thinking and force them to confront the edges of the problem. If you
  notice the conversation has become a sequence of agreements, break the loop:
  find the weakest assumption on the table and attack it."
- **Tracking instruction:** "Maintain a running OPEN ASSUMPTIONS list. Every
  assumption, edge case, conflict, or feasibility concern you surface gets an
  entry the moment you surface it. Persist each entry to the interview draft
  via `tl_draft_append_elicit <skill> question "assumption: <one-line>"
  "<the challenge you raised>" "<open|the user's answer>"` — the `header`
  argument carries the `assumption:` prefix (this is the same helper and the
  same five-argument signature the interview already uses; no new mechanism).
  Update an entry's disposition by appending a NEW elicitation with the same
  header and the disposition in the answer field (`resolved: <how>` or
  `waived: <rationale>`); the latest entry per header is authoritative."
- **Resume instruction:** "On a resumed session, call `tl_draft_read` and parse
  its JSON output: scan the `interview` array for entries whose `header` field
  begins with `assumption:`; group by header; the LAST entry per header is its
  current state. Entries whose latest answer is not a `resolved:`/`waived:`
  disposition are still OPEN — rebuild the working list from them and continue
  the interview from there."
- **Completion gate:** "The interview is NOT complete while any list entry
  lacks a disposition. Each entry ends as either `resolved: <how the user
  resolved it>` or `waived: <the user's recorded rationale>`. Ask the user to
  disposition each open item explicitly (an AskUserQuestion per batch of
  related items); never silently drop one."

### 2. The same block, design-flavored — `skills/tdd-author/SKILL.md`

The same instructions (posture, anti-sycophancy, tracking, resume, completion
gate) inserted at the top of `## 5. Author the approved set` (where the design
interview happens), with the challenge targets adapted: "challenge the PRD's
requirements for infeasibility, contradiction, and under-specification;
challenge your OWN proposed TDD decomposition — is the split right, is anything
lumped, is anything missing — before writing any TDD content."

The existing one-sentence directive in step 5 ("CHALLENGE the PRD: surface
infeasible, contradictory, or under-specified requirements…") is **subsumed by
the new block and removed** — keeping both would leave two overlapping
challenge instructions of different strengths; the new block is the
authoritative form. The tracking, resume, and completion-gate instructions are
identical to §1 (tdd-author also has draft persistence via [[0012]]).

### 3. PR-body record — both skills' git phase-gate steps

`/prd-author`'s `## Git (phase gate)` section and `/tdd-author`'s `## 9. Git`
section each gain:

- "Render the final assumptions list as an **'Open assumptions & waivers'**
  section in the PR body: one line per item, `- <assumption> — resolved:
  <how>` or `- <assumption> — waived: <rationale>`. Source the list from the
  draft (`tl_draft_read`, latest entry per `assumption:` header — the same
  parse as the resume instruction), NOT from conversational memory, so the
  rendered record survives any compaction that happened mid-interview. A PR
  whose interview surfaced no assumptions states 'Open assumptions: none
  surfaced' explicitly (the absence is declared, never silent)."
- prd-author only: "Items dispositioned as `waived` are ALSO appended to the
  PRD's `## Open questions` section, so the artifact records what was
  consciously deferred without re-reading the PR."

### 4. Self-review additions — both skills

Each skill's self-review checklist gains one item: "Open-assumptions record —
every surfaced item has a disposition; the PR body section is present and
matches the draft's assumption entries."

## Data & state

No new state, no schema changes. The open-assumptions entries reuse the
[[0012]] draft file: `tl_draft_append_elicit`'s existing five-argument
signature, with the `header` argument carrying the `assumption:` prefix and
dispositions recorded as follow-up entries under the same header (latest entry
per header is authoritative — an append-only convention over the existing
array, not a new structure). The draft is deleted on normal completion exactly
as today. The PR-body record is rendered text, not persisted state.

## Sequencing / implementation plan

1. **prd-author SKILL.md**: insert the Interrogator-discipline block (§1), the
   PR-body record instruction (§3), and the self-review item (§4).
2. **tdd-author SKILL.md**: insert the design-flavored block (§2), the PR-body
   record instruction (§3), and the self-review item (§4).
3. **Eval**: extend or add a test that greps both SKILL.mds for the required
   instruction blocks (presence + key phrases: "interrogator", "OPEN
   ASSUMPTIONS", the agreement-is-not-helpfulness anti-sycophancy sentence,
   "resolved:" / "waived:" dispositions, the `tl_draft_read` resume parse,
   the PR-body section name).

**Build-order note:** the current `/implement` run (TDDs 0021/0022/0023/0026)
also modifies `skills/tdd-author/SKILL.md` (0023's learnings surfacing). This
TDD must build AFTER that run's PRs merge, so its edits land on the
post-0023 file — declared here so the runner's queue ordering (numeric: 0028
after 0023) produces the right result naturally.

## Failure modes & edge cases

- **The user refuses to disposition an item** ("just move on"). The skill
  records it as `waived: user deferred without rationale` — the record stays
  honest about what happened rather than blocking the phase indefinitely. The
  human PR reviewer sees it.
- **An interview surfaces zero assumptions** (tiny PRD tweak, e.g. a one-line
  FR clarification). Legitimate; the PR body states "Open assumptions: none
  surfaced." The acceptance criterion's "absent or empty while the diff adds
  or changes requirements" clause is judged by the human reviewer — a
  genuinely trivial change with no record is fine; a substantial change with
  none is the observable non-compliance.
- **Session killed mid-interview.** Already handled: assumptions are draft
  elicitations; [[0012]]'s resume flow restores them; the resumed session
  reconstitutes the open list from `assumption:`-prefixed entries.
- **The model's challenges become performative** (manufactured objections to
  satisfy the letter of the instruction). Mitigated, not eliminated: the
  completion gate requires user dispositions, so noise challenges cost the
  user time and get pushed back on; the human PR reviewer sees the record's
  quality. Residual risk accepted — prompt discipline cannot be mechanically
  verified, only its artifacts can (ADR 0006 spirit).
- **Draft-file write fails mid-interview** (disk, permissions). [[0012]]'s
  existing failure handling applies (fail-loud per its design); the interview
  continues with the in-conversation list as the working copy.

## Verification plan

**Observable surface:** the two SKILL.md files' text content; the PR bodies
produced by authoring sessions; the draft file's elicitation entries during an
interview.

**Observation points:**

1. **Instruction blocks present (mechanical).** Grep
   `skills/prd-author/SKILL.md` for: the literal section heading "Interrogator
   discipline (FR-75)"; the phrase "you are not being helpful" (anti-sycophancy
   anchor); the phrase "OPEN ASSUMPTIONS"; the disposition forms "resolved:"
   and "waived:"; the PR-body section name "Open assumptions & waivers". All
   five present → PASS. Same five greps against
   `skills/tdd-author/SKILL.md` (with FR-76 in the heading).
2. **Completion gate present (mechanical).** Grep both SKILL.mds for the
   instruction that the interview is not complete while any entry lacks a
   disposition (anchor: "NOT complete").
3. **Draft integration instructions present (mechanical).** Grep both for:
   the `assumption:` header-prefix usage with `tl_draft_append_elicit`; AND
   the resume-parse instruction (anchors: `tl_draft_read`, "latest entry per
   header").
4. **Behavioral: record reaches the PR body.** Run a `/prd-author` session in
   a fixture repo making a small requirement change; answer its challenges;
   waive at least one item with a rationale. Observe: the opened PR's body
   contains "Open assumptions & waivers" with the waived item and its
   rationale; the PRD's `## Open questions` gained the waived item.
5. **Behavioral: zero-assumptions path.** Run `/prd-author` for a trivial
   change (fix a typo in a non-requirement line). Observe: the PR body states
   "Open assumptions: none surfaced" (declared absence, not missing section).

(§4–§5 are session-driven observations, exercised by the runtime-verify gate
against this TDD's own build per the standing pattern; §1–§3 are the
mechanical regression surface.)

**Expected observations (PASS):** every numbered point yields the cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-75 (PRD interview interrogator mode; tracked assumptions; resolve-or-waive; anti-sycophancy in instructions; "Open assumptions & waivers" record observable) | §1 instruction block (posture + anti-sycophancy verbatim + tracking + completion gate) + §3 PR-body record + waived→Open-questions fold + §4 self-review item. Verification §1, §2, §3, §4, §5. |
| FR-76 (same discipline for the design interview; challenges PRD feasibility/contradiction/under-specification AND own decomposition; record in design PR body) | §2 design-flavored block + §3 PR-body record + §4 self-review item. Verification §1 (tdd-author greps), §2, §3. |

No gaps.

## Dependencies considered

No new external dependencies; no new internal mechanisms. Reuses [[0012]]'s
draft helpers as-is.

Alternatives considered:
- **A structured assumptions file (JSON/YAML) instead of draft elicitations** —
  rejected: a second persistence mechanism alongside [[0012]]'s drafts adds a
  failure surface and a sync question for zero benefit; the draft already
  survives kills and the list's final form is prose in a PR body.
- **Mechanically enforce the record via tdd-lint** (a check that the PR body
  has the section) — rejected: tdd-lint checks artifacts in the repo; PR
  bodies live in GitHub. The enforcement point is the skill's own completion
  gate plus the human PR reviewer (consistent with NFR-1: the human merge is
  the gate). A repo-side mechanical check would require persisting the record
  into the artifact, which FR-75 allows but does not require beyond the
  waived→Open-questions fold.
- **A separate interrogator subagent** (fresh-context challenger, like the
  design-reviewer) — rejected for this scope: FR-75/76 specify a discipline
  *within* the interview, not a second gate after it. A challenger subagent is
  a plausible future enhancement but is not what the requirements ask for, and
  it would double interview token cost.

## PRD conflicts surfaced (and resolution)

None. FR-75/76 are additive to FR-5/FR-7's existing interview requirements;
the cross-reference FR-5 already carries ("the interview discipline that
precedes this rigor pass is specified by FR-75") was added in the same PRD
revision this TDD designs against.

## Decisions to promote (ADR candidates)

None. The discipline is prompt-level instruction within existing skills; no
cross-cutting architectural decision is introduced.

## Touched files

- `skills/prd-author/SKILL.md` — interrogator block, PR-body record instruction, self-review item (§1, §3, §4).
- `skills/tdd-author/SKILL.md` — design-flavored interrogator block, PR-body record instruction, self-review item (§2, §3, §4).
- `tests/interrogator-discipline.test.sh` — new eval covering verification §1–§3 (mechanical greps).
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Total: 4 files touched.

## Expected diff size

- `skills/prd-author/SKILL.md` — ~45 lines added.
- `skills/tdd-author/SKILL.md` — ~45 lines added.
- `tests/interrogator-discipline.test.sh` — ~90 lines added (new eval).
- `tests/implement-gate.test.sh` — ~6 lines added (aggregator wire-in).

Total expected diff: ~186 lines across 4 files. No exceptions needed.

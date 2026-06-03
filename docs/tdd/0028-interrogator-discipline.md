# TDD 0028: Interrogator discipline for authoring interviews

Status: implemented
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

- "**Before** invoking `gh pr create`, render the final assumptions list as an
  **'Open assumptions & waivers'** section and assemble it INTO the PR body
  string that the SAME `gh pr create --body` (or `--body-file`) call publishes —
  the section is part of the body at creation time, never a step performed after
  the PR already exists. One line per item, `- <assumption> — resolved: <how>`
  or `- <assumption> — waived: <rationale>`. Source the list from the draft
  (`tl_draft_read`, latest entry per `assumption:` header — the same parse as the
  resume instruction), NOT from conversational memory, so the rendered record
  survives any compaction that happened mid-interview. A PR whose interview
  surfaced no assumptions states 'Open assumptions: none surfaced' explicitly
  (the absence is declared, never silent)." **Ordering is load-bearing (FR-76):
  the instruction MUST be positioned in the git step so the model renders and
  folds the section into the body it passes to `gh pr create`, not as a bullet
  that follows the create call — a post-creation render leaves the primary
  record deliverable out of the published PR body.**
  **Concrete mechanism (mirror the proven prd-author pattern, do not reinvent):**
  prd-author already does this correctly — it puts the rendered section in the
  commit-message body so `gh pr create --fill` carries it into the PR body (or
  passes it via `--body`), with the render bullet placed BEFORE the create bullet.
  tdd-author MUST use the same shape: the "Open assumptions & waivers" render bullet
  precedes the `gh pr create` bullet, and the create bullet explicitly names both
  the design-critique verdict AND the rendered section as required body content.
  This keeps the two skills' git steps structurally identical and removes any
  ambiguity about when/how the section reaches the published body.
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
   PR-body record instruction (§3), and the self-review item (§4). The §3 record
   instruction MUST be positioned so the section is assembled into the body
   passed to `gh pr create` (before the create call), not after it.
2. **tdd-author SKILL.md**: insert the design-flavored block (§2), the PR-body
   record instruction (§3), and the self-review item (§4). Same ordering
   constraint as step 1: the §3 record is folded into the `gh pr create --body`
   in `## 9. Git` BEFORE the create call, never as a following bullet.
3. **Eval**: extend or add a test that greps both SKILL.mds for the required
   instruction blocks (presence + key phrases: "interrogator", "OPEN
   ASSUMPTIONS", the agreement-is-not-helpfulness anti-sycophancy sentence,
   "resolved:" / "waived:" dispositions, the `tl_draft_read` resume parse,
   the PR-body section name). Every check MUST satisfy the **Mechanical-check
   robustness** requirements in the Verification plan: absence checks fail closed
   on file-read error (no `grep && bad || ok` that passes on grep exit ≥2), and
   every anchor is specific to text THIS change introduces (no vacuous match on
   pre-existing skill content).
4. **Wire the eval into the aggregator (do NOT defer):** add the
   `tests/interrogator-discipline.test.sh` invocation to
   `tests/implement-gate.test.sh` in the SAME step as creating the eval —
   declare its `*_FAIL` accumulator, run it conditionally like the sibling
   evals, and AND it into the suite's final pass/fail expression. An eval that
   is not wired here is orphaned from `ci-checks.sh` and provides no regression
   gate for FR-75/FR-76; this is a required deliverable of step 3's unit, not a
   follow-up.

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

**Mechanical-check robustness (binding on the §1–§3 eval — `tests/interrogator-discipline.test.sh`).**
The greps that back §1–§3 MUST fail closed and assert specifically, so a passing
eval means the behavior is present rather than that the check couldn't tell:

- **Absence/removal checks fail closed on read error.** The subsumed-directive
  removal check (the assertion that `CHALLENGE the PRD:` is GONE) MUST
  distinguish "string correctly absent" (grep exit 1) from "file unreadable"
  (grep exit ≥2). A bare `grep -q PATTERN FILE && bad || ok` is forbidden — grep's
  error exit is non-zero and would silently take the `ok` (pass) branch on a
  missing/unreadable file. Guard it: assert the target file exists and is
  readable first (fail the eval if not), THEN treat exit 1 as the pass and any
  exit ≥2 as an eval failure.
- **Anchors are specific to the NEW text, never strings the skill already
  contains.** Every presence grep MUST anchor on a phrase introduced by THIS
  change (e.g. the literal `Interrogator discipline (FR-75/FR-76)` heading, the
  verbatim anti-sycophancy sentence, the `Open assumptions & waivers` section
  name). An anchor that matches pre-existing skill text — e.g. a bare
  `Open questions` or a bare `decomposition` that already appears elsewhere in
  the file — passes vacuously and is forbidden; for the prd-author
  waived→Open-questions fold, anchor on the new combined phrasing, not the bare
  pre-existing `## Open questions` heading.

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

**Build blocker resolved (2026-06-03).** The first `/implement` build of this
TDD halted with a `structural-finding(b)` scope precheck (`PRECHECK_FAIL:
tests/interrogator-discipline.test.sh 131 > 90`): the bounded-rework loop had
correctly added the aggregator wire-in but the eval test then exceeded its
declared per-file bound. This was a design-time underestimate in `## Expected
diff size`, not a code defect — the eval genuinely needs ~130 lines. Resolved
in-place (this TDD is `draft`): per-file bounds corrected to the build branch's
actual sizes and the aggregator wire-in promoted to an explicit `## Sequencing`
step so a rebuild does it inline. No design substance changed; see
`docs/tdd/BLOCKERS.md`.

**Second build blocker resolved (2026-06-03, after `--resume`).** With the scope
bound corrected, the resumed review reached deeper and surfaced three genuine
defects: a `structural-finding(c)` — the §3 PR-body record instruction was built
positioned *after* `gh pr create`, so the FR-76 record could miss the published
PR body — plus two recurrent build-quality majors in the eval
(`fragile-inversion-pattern`: an absence check that false-passes on `grep` exit
≥2; `weak-structural-assertion`: an anchor that matches pre-existing skill text
and passes vacuously). Resolved by tightening the design, not by relaxing it: §3
now mandates pre-creation assembly of the section into `gh pr create --body`
(load-bearing ordering, both skills), and the Verification plan gained binding
**Mechanical-check robustness** rules (fail-closed absence checks; new-text-only
anchors) that the eval must satisfy. These are clarifications of the existing
design's intent, not new behavior.

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

- `skills/prd-author/SKILL.md` — ~65 lines added (interrogator block + PR-body record with the pre-creation assembly clause + self-review item; the verbatim anti-sycophancy and tracking instructions are intrinsically multi-line).
- `skills/tdd-author/SKILL.md` — ~72 lines added (same block, design-flavored, plus removal of the subsumed one-line directive and the §3 pre-creation reorder: the "Open assumptions & waivers" render bullet moved before `gh pr create` and the create bullet expanded to require both the critique verdict and the section in the body, mirroring prd-author).
- `tests/interrogator-discipline.test.sh` — ~155 lines added (new eval: ~10 mechanical anchors greped across both SKILL.mds, plus the subsumed-directive removal check hardened to fail closed on grep exit ≥2, plus the file-readable guards and per-assertion `ok`/`bad` reporting required by the Verification plan's mechanical-check robustness rules).
- `tests/implement-gate.test.sh` — ~18 lines added (aggregator wire-in: `*_FAIL` accumulator + conditional run block + final-expression AND, matching the sibling-eval pattern).

Total expected diff: ~310 lines across 4 files. No exceptions needed (the eval at ~155 lines and tdd-author at ~72 are both under the 300-line per-file bound).

# TDD 0065: Parent-session light-tier check (FR-86)

Status: implemented
PRD refs: FR-86, NFR-3, NFR-4
PRD-rev: f6ef178
ADR constraints: 0004, 0005, 0006, 0010, 0015

## Approach
FR-86 is now narrow. `/prd-author`, `/tdd-author`, and `/build-tdds`
read the parent session's model. If it is on the light tier, or it
cannot be read, the skill warns and asks Continue / Stop before the
interview or build proceeds. Any other model proceeds silently. There
is no vendor web fetch and no "most capable" comparison (both removed
from 0065-rev1).

All logic lives in one executable function in `scripts/lib/models.sh`
that reuses TDD 0064's `tl_parent_model` and `tl_model_tier`. Each skill
carries an identical, marker-tagged bash block that calls it. The eval
**extracts and runs** that block from each skill file, so a block that
fails in a clean shell (the 0064-rev1 defect: a function that does not
exist in a `bash -c` child) fails the eval.

Stacks on 0064.

## Components & interfaces
**`tl_fr86_message`** (added to `scripts/lib/models.sh`). No args.
Calls `tl_parent_model`; on rc 1 captures its stderr reason. Prints:

| Case | stdout (exactly one line, or nothing) |
|---|---|
| parent readable, `tl_model_tier` = `above` | nothing |
| parent readable, tier `light` | `throughline: parent session model <id> is on the light tier; judgment work in this session inherits it. Continue, or stop and change the model.` |
| unreadable | `throughline: parent session model could not be read (<reason>). Continue, or stop and change the model.` |

rc 0 in all three cases. rc 2 only when `models.sh` itself is
unusable (a sourcing failure is caught by the block below first).
`<reason>` is the text after `tl_parent_model: ` on its stderr line,
or `unknown` if empty.

**Skill block** — identical bytes in all three skills, preceded by the
HTML comment `<!-- tl:fr86-check -->` on its own line, then a fenced
`bash` block:
```
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/models.sh" || { echo "throughline: cannot source models.sh" >&2; exit 1; }
tl_fr86_message
```
Every function is defined in the same shell that calls it; no
`bash -c` child, no function crossing a process boundary.

Skill prose after the block (same in all three): "If the block printed
a line, show that line to the user and ask a structured question with
exactly two options, `Continue` and `Stop`. `Stop` ends the skill with
no interview, no draft init, no lock, and no queue. `Continue` proceeds.
If the block printed nothing, proceed without asking. If the block
exits non-zero, show its stderr and stop (fail closed)."

Placement:
- `skills/prd-author/SKILL.md` — after step 0 (resume check), before
  step 1. The draft is not initialized on `Stop` (it is lazy anyway).
- `skills/tdd-author/SKILL.md` — after `## 0. Resume check`, before
  `## 1.`.
- `skills/implement/SKILL.md` — new section after `## 1. Source
  helpers`, before `## 2. Lock`. On `Continue` with an unreadable
  parent, 0066 records `parent=unknown`.

## Data & state
None. Reads the session transcript / Grok `summary.json` via
`tl_parent_model` (read-only). No cache, no env override for the check.

## Sequencing / implementation plan
1. Add `tl_fr86_message` to `scripts/lib/models.sh`.
2. Insert the marker + block + prose into the three skills.
3. Add `tests/parent-session-check.test.sh` (extracts and runs each
   skill's block with fixtures); register it in
   `tests/implement-gate.test.sh`.

## Failure modes & edge cases
**Real risks**
- A skill's block drifts from the others (hand edit). Mitigation: the
  eval asserts the three extracted blocks are byte-identical.
- `tl_parent_model` unreadable on every run after a transcript format
  change → the question appears every time. Honest by design
  (NFR-4: unreadable is warn+ask, not a silent skip); the reason in
  parentheses tells the operator why.
- The block runs before `/prd-author`'s draft helper is sourced; a
  `Stop` must leave no draft. Mitigation: placement before any
  `tl_draft_init` (which is lazy) — eval observation 6.

**Overblown risks**
- A mid-session `/model` switch: the newest assistant line wins, so the
  check reflects the model in use at invoke time.
- Grok sessions: same function, Grok branch of `tl_parent_model`.

**Unspoken risks**
- An operator who deliberately authors on a light model gets the
  question every invoke. Accepted: FR-86 says warn+ask; it is one
  keystroke and states the cost tradeoff.
- The `<!-- tl:fr86-check -->` marker is the eval's extraction anchor.
  If a later edit removes it, the eval fails closed ("marker not found
  in <skill>") rather than passing on nothing.

## Verification plan
- **Surface:** stdout / rc of the extracted skill block, run as
  `env -i HOME=<tmp> PATH="$PATH" CLAUDE_PLUGIN_ROOT=<repo> CLAUDE_CONFIG_DIR=<tmp>/.claude [CLAUDE_CODE_SESSION_ID=<sid>] bash <extracted.sh>`.
  No network.
- **Extraction:** for each of the three skills, take the first fenced
  `bash` block after the line `<!-- tl:fr86-check -->`. Marker or block
  missing, or the skill file unreadable → `bad` (infra-fail, L-001).
- **Observation points → expected (PASS):**
  1. The three extracted blocks are byte-identical.
  2. Fixture transcript, newest assistant `message.model` = `claude-opus-5-5` → block stdout empty, rc 0.
  3. Same with `claude-fable-5-1` → empty, rc 0.
  4. Same with `claude-sonnet-5-5` → stdout exactly the light line with `<id>` = `claude-sonnet-5-5`, rc 0. With `claude-haiku-4-5` → light line naming it.
  5. `CLAUDE_CODE_SESSION_ID` unset → stdout exactly `throughline: parent session model could not be read (no session id). Continue, or stop and change the model.`, rc 0. Session id set but no transcript → reason `transcript not found`.
  6. `CLAUDE_PLUGIN_ROOT` pointing at an empty dir → block rc ≠ 0 and stderr contains `cannot source` (fail closed).
  7. Each skill's prose within 15 lines after the block contains `Continue`, `Stop`, and `fail closed` (grep with the file-readable precheck).
  8. `grep -c 'platform.claude.com\|docs.x.ai\|this turn' ` over the three skills totals 0 (rev1's fetch removed), with each file asserted readable first.
- **PASS:** 1–8 hold.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement traceability | Every in-scope FR/NFR (NFR-3, FR-10, FR-15(d), FR-52, FR-86, FR-87, FR-88) maps to a named function, skill step, or run-record field | One mapping indirect but named | An in-scope requirement missing or hand-waved |
| interface concreteness | Every new helper (`tl_resolve_models`, `tl_parent_model`, tier placement, run-record setters) has its signature, stdout format, and return codes pinned | One helper's error return implicit | A reader cannot tell what a helper prints or returns |
| executable verification | Every skill snippet and helper the design adds is run by an eval, not only grepped; missing file / empty output / grep exit 2 is infra-fail, never ok | One check is text-only with a stated reason | A snippet is pinned in prose but never executed (the 0064 failure) |
| alternatives-analysis substance | Each new mechanism names ≥1 concrete rejected alternative with reason (live fetch, rank table, frontmatter effort, rebuild-on-escalate) | One rejection thin | None given |
| verification-plan actionability | Surface, observation points, PASS values named, including the live fell-back probe and its BLOCKED rule | One fixture underspecified | Missing or non-actionable |
| scope-bound adherence | Each TDD ≤8 files, ≤500 body lines; estimates padded; exceptions declared | One justified inline exception | Over a bound with no exception |
| naming consistency | `inherit`, `light`, `escalation`, `escalated`/`already-top`/`fell-back`, `parent=unknown` spelled identically across all four TDDs and ADR 0015 | One synonym | Same concept named two ways |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-86 read the parent model | `tl_parent_model` (0064), called by `tl_fr86_message` |
| FR-86 light tier → warn+ask | light line + Continue/Stop prose; observation 4 |
| FR-86 unreadable → warn+ask, not skip, not hard stop | unreadable line + Continue/Stop; observation 5 |
| FR-86 above light → no warning, no fetch | empty stdout; observations 2, 3, 8 |
| FR-86 before interview/build | placement in each skill; observation 6/7 |
| NFR-3 operator owns the model choice | no most-capable comparison |
| NFR-4 honesty | unreadable reason printed; fail closed on source failure |

## Dependencies considered
No new libraries. Rejected: **0065-rev1's this-turn fetch of vendor
model pages** (FR-86 non-goal now; fragile offline; judged "most
capable", the wrong bar). Rejected: **skill prose that tells the model
to read the transcript itself** (unexecutable by an eval; the 0064-rev1
class). Rejected: **a separate `session-check.sh` library** (one more
source line in three skills; `models.sh` already owns observation and
tiers).

## PRD conflicts surfaced (and resolution)
None. FR-86 was rewritten to match this design (PR #181).

## Decisions to promote (ADR candidates)
Covered by ADR 0015 (no live discovery; light-tier check only).

## Touched files
- `scripts/lib/models.sh` — add `tl_fr86_message`
- `skills/prd-author/SKILL.md` — marker + FR-86 block + prose
- `skills/tdd-author/SKILL.md` — marker + FR-86 block + prose
- `skills/implement/SKILL.md` — FR-86 section before the lock
- `tests/parent-session-check.test.sh` — extracts and runs each skill block
- `tests/implement-gate.test.sh` — register the new eval

## Expected diff size
- `scripts/lib/models.sh` — 40 lines
- `skills/prd-author/SKILL.md` — 22 lines
- `skills/tdd-author/SKILL.md` — 22 lines
- `skills/implement/SKILL.md` — 24 lines
- `tests/parent-session-check.test.sh` — 210 lines
- `tests/implement-gate.test.sh` — 12 lines
Total expected diff: 330 lines across 6 files.

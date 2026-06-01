# TDD 0012: Interactive interview-draft persistence & resume

Status: implemented
PRD refs: FR-46, FR-47, FR-48, FR-49, FR-50 (new)
PRD-rev: 9626a59
ADR constraints: 0003, 0004

## Approach

`/prd-author` and `/tdd-author` are interview-driven skills that today
buffer all elicited detail in-conversation until the final write to
`docs/PRD.md` / `docs/tdd/NNNN-*.md`. An interruption between elicitation
and the final commit — host reboot, manual kill, lost session,
intra-session compaction — erases everything the user already answered.

This TDD adds a single mechanism — **a transient, on-disk draft file
written incrementally after every substantive elicitation** — that
fixes FR-46..49 with one moving part. Per-skill prompt edits instruct
the model to:
1. on entry, check for an existing draft and offer to resume from it;
2. after each substantive elicitation, append the answered detail to
   the draft;
3. before each authoring step, re-read the draft to refresh state
   (the cheap compaction-survival mechanism — see FR-48);
4. on normal completion, delete the draft;
5. on resume, run the design-reviewer fresh on the restored design
   (do not persist its verdict to the draft at all — see FR-50).

The draft lives under `${CLAUDE_PLUGIN_DATA}/<repo-id>/drafts/` —
reusing the per-developer per-repo path established by TDD 0009 (FR-33)
— so it is naturally per-machine, naturally outside git (no `.gitignore`
work required), and survives repo deletion / re-clone without leaving
orphaned files in the consumer repo.

## Components & interfaces

### Draft format and location

Path:
```
${CLAUDE_PLUGIN_DATA}/<repo-id>/drafts/prd-author.json   # /prd-author
${CLAUDE_PLUGIN_DATA}/<repo-id>/drafts/tdd-author.json   # /tdd-author
```

`<repo-id>` is computed by the existing helper `scripts/lib/repo-id.sh::
tl_repo_id` from TDD 0009. Both skills source it via a small new helper
script (#3 below) so they don't reach into the runner's helpers
directly.

The draft is a single JSON object. Schema `1`:

```json
{
  "schema": 1,
  "skill": "prd-author",
  "started_at": 1748390000,
  "updated_at": 1748390800,
  "prd_rev_at_start": "9626a59",
  "interview": [
    { "ts": 1748390050, "kind": "question", "header": "Scope check",
      "question": "Is this one product or several?",
      "answer": "One: throughline plugin overlay" },
    { "ts": 1748390200, "kind": "question", "header": "Users",
      "question": "Who is the primary user?",
      "answer": "Developers using Claude Code who want design-docs-first discipline" },
    { "ts": 1748390400, "kind": "decision", "label": "Scope decomposition",
      "value": "single product, no split needed" }
  ],
  "draft_doc": "# Product Requirements: throughline\n\n## Problem & context\n\nBuilding complex software with AI coding agents tends to..."
}
```

Field semantics:
- `schema`: integer `1`. Same versioning policy as TDD 0011 (already
  implemented at `scripts/lib/state.sh:295` for paused-run fragments):
  additive fields stay at `1`; breaking changes bump and the skill on
  resume refuses an incompatible schema. Refusal message mirrors the
  runner's wording for parity:
  `draft schema 'X' not compatible with this plugin version; discard and
  start fresh? (y/N) (see docs/tdd/0012)`.
- `skill`: literal `prd-author` or `tdd-author`. A loaded draft whose
  `skill` mismatches the invoking skill is treated as not-mine (the
  skill warns and ignores). This is defense against a future third
  interview skill collision.
- `prd_rev_at_start`: for `tdd-author`, the PRD short-SHA the session is
  designing against. If the PRD has advanced since (`git rev-parse
  --short HEAD docs/PRD.md` differs), resume notes the drift in its
  one-line summary and lets the user decide whether the draft is still
  applicable. Null for `prd-author`.
- `interview`: array of elicitations, append-only within a session. Each
  entry is a small record so the model can scan it back into context
  cheaply. `kind` is `question` (an AskUserQuestion + answer pair) or
  `decision` (the model recorded a substantive design choice between
  questions). Future kinds may be added (additive, schema stays at 1).
- `draft_doc`: the in-progress PRD or TDD body as the model has assembled
  it so far. The skill rewrites this on each authoring step (atomic
  `tmp + mv` per the runner's existing pattern). This is what
  re-reading on each step (FR-48) recovers; the `interview` array is the
  audit trail.

### File / module changes

1. **`scripts/lib/repo-id.sh` (modified, additive).** Add a new function
   `tl_drafts_dir`:
   ```bash
   tl_drafts_dir() {
     local d
     d="${CLAUDE_PLUGIN_DATA:-}/$(tl_repo_id)/drafts"
     mkdir -p "$d" 2>/dev/null || { echo "tl_drafts_dir: cannot create $d" >&2; return 1; }
     printf '%s' "$d"
   }
   ```
   Re-uses TDD 0009's `tl_repo_id`. Same failure semantics: returns
   non-zero with stderr if `CLAUDE_PLUGIN_DATA` is unset or unwritable.

2. **New `scripts/lib/drafts.sh`** — sourced helper for both skills.
   Functions:

   - `tl_draft_path <skill-name>` → echoes the absolute draft path for
     this skill (`<tl_drafts_dir>/<skill-name>.json`).

   - `tl_draft_exists <skill-name>` → exits 0 if the draft file exists
     AND parses as JSON (basic structural check; uses `python3 -c`
     `json.load` if available, falls back to a `grep -q '"schema"'`
     heuristic). Exits 1 otherwise. Used by the skill's resume-detect
     step.

   - `tl_draft_summary <skill-name>` → echoes a one-line summary
     suitable for the resume prompt: `<count> elicitations, started <iso8601>,
     last updated <iso8601> (skill=<skill>, prd_rev=<sha or "n/a">)`.
     Uses `python3 -c` if available; falls back to `grep`/`sed`
     extraction (lossy but never wrong: missing fields render as
     `<unknown>`).

   - `tl_draft_read <skill-name>` → prints the entire draft JSON to
     stdout. Skill consumes this to rehydrate state.

   - `tl_draft_append_elicit <skill-name> <kind> <header> <question> <answer>`
     → atomically appends one entry to `interview[]` with the current
     epoch as `ts`, writes via `tmp + mv`. Uses `python3` if available
     (single-line program); falls back to a bash JSON-builder using
     the existing `json_escape` from `scripts/lib/state.sh` (extracted
     there by TDD 0015 — TDD 0012 consumes it directly rather than
     re-promoting it). `drafts.sh` sources `state.sh` once at the top
     so both the runner and the skills share one escaper without
     duplicating the function.

   - `tl_draft_write_doc <skill-name> <doc-path-or-stdin>` →
     replaces `draft_doc` with the contents of the file (or stdin if
     `-`), atomically. Used after each authoring step.

   - `tl_draft_discard <skill-name>` → `rm -f` the draft file. Called
     on normal completion (FR-49) and on the user's "discard and start
     fresh" choice (FR-47).

   - `tl_draft_init <skill-name> [prd_rev]` → write a fresh
     `{schema:1, skill:…, started_at:NOW, updated_at:NOW,
     prd_rev_at_start:…, interview:[], draft_doc:""}` skeleton.
     **Called lazily by the skill in step 3, immediately before
     the first `tl_draft_append_elicit` call (and only when no
     draft was resumed in step 0). Never called at step 0** — see
     the step-0 and step-3 prompt edits below, and the
     "Data & state → Lifecycle" section. Calling it earlier would
     create an orphaned draft when the session is killed before
     the first substantive elicitation, breaking FR-46's negative
     acceptance criterion.

3. **`json_escape` already lives in `scripts/lib/state.sh`** (extracted
   from `scripts/implement.sh` by TDD 0015 — `scripts/lib/state.sh:84`).
   `drafts.sh` sources `state.sh` once at its top to consume the same
   escaper. No new helper file, no behavioral change, no Touched-files
   entry for an escaper-promotion step. (The original draft of this
   TDD planned to promote `json_escape` to its own
   `scripts/lib/json-escape.sh` — that work is obsolete now that TDD
   0015's state-lib extraction already shares the function.)

4. **`skills/prd-author/SKILL.md` (modified).** Five concrete prompt
   edits, each surrounded by adjacent existing text so the change is
   reviewable:

   - **Before step 1 (Explore the problem space)**, insert step 0:
     "Resume check. Source `scripts/lib/drafts.sh`. If
     `tl_draft_exists prd-author` is true, run `tl_draft_summary
     prd-author` and present its output to the user via
     AskUserQuestion with options `Resume from draft` / `Discard and
     start fresh`. On resume, `tl_draft_read prd-author` and use its
     `interview` and `draft_doc` as your starting state (do not
     re-elicit anything already in `interview`); the draft already
     exists, so do NOT call `tl_draft_init`. On discard,
     `tl_draft_discard prd-author`. On no-existing-draft, simply
     proceed; do NOT call `tl_draft_init` here. `tl_draft_init` is
     lazy and is called only at the moment of the first substantive
     elicitation in step 3 (see below) — so killing the session
     between steps 0 and 3's first AskUserQuestion leaves no
     orphaned draft, satisfying FR-46's negative-acceptance clause
     ('killing the session before any answered elicitation leaves
     no orphaned draft')."

   - **In step 3 (Interview the user)**, replace "Prefer
     multiple-choice options; don't overwhelm" with the same text plus
     "Before the FIRST `tl_draft_append_elicit` call of this session
     (and only when no draft was resumed in step 0), run
     `tl_draft_init prd-author` once to create the draft skeleton.
     After EACH AskUserQuestion that elicits substantive content,
     run `tl_draft_append_elicit prd-author question
     "<header>" "<question text>" "<answer text>"` immediately, BEFORE
     asking the next question. This persistence is per substantive
     elicitation (FR-46), not buffered. Trivial confirmation prompts
     (yes/no without semantic content) may skip the append (and do not
     trigger `tl_draft_init`)."

   - **In step 5 (Write `docs/PRD.md` from the template)**, prepend a
     mandatory sub-step: "Before drafting any section, re-read the
     draft to refresh your working state across any compaction or
     long pause: `cat $(tl_draft_path prd-author)`. After EACH
     section you write or revise, run `tl_draft_write_doc prd-author
     -` with the in-progress PRD piped to stdin. This is the
     compaction-survival mechanism (FR-48): the draft on disk is the
     source of truth across context loss."

   - **At the end of step 5 (the inline self-review)**, append: "Self-
     review reads the draft, not in-memory state. If the draft and
     in-memory state disagree, the draft wins (you may have crossed a
     compaction). Update in-memory from the draft and continue."

   - **In the existing Git step**, after "Open a PR with `gh pr
     create --fill`", prepend: "After the PR is opened, run
     `tl_draft_discard prd-author`. This is the only path that
     discards the draft on success; on any path that exits before
     PR creation (including a user cancel), the draft persists for
     a later resume (FR-49)."

5. **`skills/tdd-author/SKILL.md` (modified).** Same five edits adapted
   to `tdd-author`, with two skill-specific tweaks:

   - The resume check at step 0 records the current PRD SHA via
     `prd_rev_at_start`. On resume, the skill compares
     `git rev-parse --short HEAD docs/PRD.md` to the draft's
     `prd_rev_at_start`; if they differ, the resume prompt includes
     the line `PRD has advanced since this draft was started (<old>
     → <new>). Your interview answers may no longer apply.` The user
     decides resume vs. discard with the drift surfaced.

   - **In step 7b (Independent design critique gate)**, append: "The
     design-reviewer verdict is NEVER persisted to the draft. It is
     produced only inside the live skill session, consumed only when
     assembling the design PR body, and lost when this session ends
     (FR-50 — reviewer freshness across resumption). A resumed
     session has no prior verdict to consider reusing; the cheapest
     correct behavior is to not write it down."

6. **No changes to `scripts/implement.sh`.** The runner does not
   interact with these drafts directly; FR-46..50 are entirely
   skill-side. (`json_escape` was extracted into `scripts/lib/state.sh`
   by TDD 0015 — already shared, no further runner change needed.)

## Data & state

- Drafts at `${CLAUDE_PLUGIN_DATA}/<repo-id>/drafts/<skill>.json`. Per-
  developer (inherits from TDD 0009's `<repo-id>` scheme), per-machine,
  never tracked by git (`CLAUDE_PLUGIN_DATA` lives outside the repo;
  FR-49 acceptance is satisfied structurally — no `.gitignore` rule
  required and `git ls-files` cannot include it).
- Atomic write semantics same as the runner: `tmp + mv`. Promoted
  `json_escape` is the single point that escapes user-content strings
  for JSON inclusion.
- Lifecycle:
  - **Created on the first substantive elicitation** — `tl_draft_init`
    is called in step 3 immediately before the first
    `tl_draft_append_elicit`, NOT at step 0. Step 0 is detection-only:
    it checks for an existing draft and either resumes from it or
    confirms its absence. Killing the session between step 0 and the
    first elicitation in step 3 leaves no orphaned draft (FR-46
    negative acceptance).
  - Updated on each elicitation (`tl_draft_append_elicit`) and each
    authoring sub-step (`tl_draft_write_doc`).
  - Deleted on PR-creation success (`tl_draft_discard`).
  - Persists across every other exit (kill, host reboot, lost
    session, intra-session compaction).
- Schema versioning: same policy as TDD 0011 — additive fields stay at
  `schema: 1`; a breaking bump refuses to resume across the version
  delta. Resolves FR-49 + the same PRD open question on schema skew
  from this side.

## Sequencing / implementation plan

**Build-order constraint.** TDD 0009 (install/update lifecycle hygiene)
must land first: it owns `scripts/lib/repo-id.sh::tl_repo_id` and the
`${CLAUDE_PLUGIN_DATA}/<repo-id>/` path convention this TDD extends with
`tl_drafts_dir`. If 0012 is queued ahead of 0009 the build will fail at
its first `tl_repo_id` reference. (`json_escape` is already in
`scripts/lib/state.sh` per TDD 0015 — no prerequisite there.)

1. **`scripts/lib/repo-id.sh::tl_drafts_dir`.** Add the new function next
   to `tl_repo_id` (introduced by TDD 0009). Land with a test that
   asserts the function creates the directory and returns its absolute
   path when `CLAUDE_PLUGIN_DATA` is set + writable; returns non-zero
   with stderr when unset.
2. **`scripts/lib/drafts.sh`.** Source `scripts/lib/state.sh` at the top to
   reuse `json_escape`. Land with one test per function: init, exists,
   append, write_doc, summary (with `python3` and the bash fallback both
   exercised), read, discard. Each is a small subshell case that exits
   0 / non-zero distinctly.
3. **`skills/prd-author/SKILL.md` edits.** Verification is by reading
   the file back (no LLM call needed): the five inserted blocks contain
   the required keywords (`Resume check`, `tl_draft_append_elicit`,
   `re-read the draft`, `Self-review reads the draft`,
   `tl_draft_discard`).
4. **`skills/tdd-author/SKILL.md` edits.** Same verification approach
   plus the PRD-drift and FR-50 (no-verdict-persistence) lines.
5. **End-to-end smoke (manual, recorded in verification plan).** Run
   `/prd-author` against a fixture repo; answer 2 questions; kill the
   session. Re-invoke `/prd-author`; observe the resume prompt with
   the count-of-elicitations summary; choose Resume; confirm the
   skill does not re-ask the 2 questions.

## Failure modes & edge cases

- **`CLAUDE_PLUGIN_DATA` unset or unwritable.** `tl_drafts_dir` returns
  non-zero with a stderr message; the skill warns the user and
  proceeds without draft persistence (interview proceeds, but FR-46
  guarantees do not apply for this run). This is documented in the
  skill prompt as a degraded mode.
- **Draft exists but is unparseable.** `tl_draft_exists` returns false;
  skill warns "found a draft at <path> but it is not parseable —
  ignoring" and proceeds as for no-existing-draft (do NOT call
  `tl_draft_init` here; lazy init happens at step 3's first
  elicitation per the corrected lifecycle). The unreadable file is
  left in place for the user to inspect (not deleted automatically;
  conservative); when lazy init fires later, the file is overwritten
  atomically by `tl_draft_init`'s `tmp + mv`.
- **Two `/prd-author` sessions in different working trees of the
  same repo.** Both map to the same `<repo-id>` (TDD 0009's scheme is
  by remote URL when present), so they share one draft file. Last
  writer wins per the atomic `tmp + mv` semantics; the loser's
  elicitations are lost. This is intentional — the draft is
  per-repo, not per-worktree, matching how PRDs themselves are
  per-repo. Document in the skill prompt with a warning that running
  the interview skill in two trees simultaneously is unsupported.
- **`/prd-author` resumed from a draft, then re-killed before PR
  creation.** The append-only `interview[]` array preserves the
  combined detail of both sessions; the second resume picks up
  where the second session left off. Verified by the smoke test
  appending an additional elicitation after resume and confirming
  the third resume sees three entries.
- **`/tdd-author` draft + PRD has advanced.** The skill surfaces the
  drift in the resume prompt; the user decides. If they discard,
  TDDs are designed against the current PRD. If they resume, the
  skill re-runs its own step-1 PRD-delta logic from the new PRD SHA,
  which may produce a different TDD plan; the user reviews the plan
  before authoring (the existing `/tdd-author` "Present this PLAN
  to the user before writing" gate catches scope drift).
- **`tl_draft_append_elicit` fails (disk full, permission lost
  mid-session).** The skill prompt instructs: "if any
  `tl_draft_*` call fails, surface the failure to the user
  immediately and stop the interview rather than continuing without
  persistence." NFR-4 spirit: silent partial persistence would be
  worse than an honest halt.
- **Compaction inside `/prd-author` or `/tdd-author`.** The model's
  in-conversation memory of prior turns is summarized. The skill's
  "re-read the draft before each authoring step" rule (FR-48)
  ensures the model's writing-state is anchored on the persisted
  draft, not the post-compaction summary. Verified by the smoke
  test injecting a long no-op interlude that forces compaction (in
  practice: a long /context summary turn) and confirming the final
  PRD contains pre-compaction elicitations.
- **Compaction degrades the re-read instruction itself** (the prompt
  edit telling the model to re-read survives but the model's
  reasoning about WHY skips a re-read at a particular step). FR-48's
  mechanism is delegated to prompt-instruction stickiness, consistent
  with ADR 0004 (govern, not bundle). When this degrades: the
  `draft_doc` on disk remains authoritative; the worst case is the
  resumed/post-compaction session re-elicits a small amount of
  detail it could have read from disk, which is a recoverable
  degradation (the user notices the re-asked question and can point
  the skill at the draft). The skill prompt's self-review sub-bullet
  ("Self-review reads the draft, not in-memory state. If the draft
  and in-memory state disagree, the draft wins.") is the final
  catch — at minimum the self-review step re-reads and resyncs. This
  is the design's honest limit: no bundled mechanism (a
  PreCompact hook, an MCP server, a daemon) was considered worth the
  weight (see "Rejected alternatives" — PreCompact rejection
  reasoning), and a fully reliable compaction-survival guarantee
  would require one. Tested via verification observation 3 with the
  pre-compaction-elicitation match against the final doc.
- **Design-reviewer verdict written into the draft by mistake.**
  Defense-in-depth: `drafts.sh` has NO function that accepts a
  verdict, and `tl_draft_append_elicit`'s `<kind>` parameter is
  restricted to the literals `question` / `decision`. A skill that
  tried to record the verdict would have to invent a new mechanism;
  the FR-50 prompt edit forbids that explicitly.
- **Throughline plugin upgrade between draft creation and resume.**
  Schema-version policy applies: additive fields stay at `1`;
  breaking bumps refuse resume with the documented message. Same as
  TDD 0011.

## Verification plan

**Observable surface:** files at `${CLAUDE_PLUGIN_DATA}/<repo-id>/
drafts/<skill>.json`; the `/prd-author` and `/tdd-author` skill
sessions' AskUserQuestion prompts (visible in transcripts); the
final `docs/PRD.md` / `docs/tdd/NNNN-*.md` content; the per-skill
prompt files (the SKILL.md texts).

**Observation points & expected observations (PASS):**

1. **Incremental persistence (FR-46).** In a fixture repo, run
   `/prd-author`; answer 2 substantive questions via
   AskUserQuestion; kill the session (Ctrl-C in the TUI before any
   PR is opened). Observe:
   ```
   [ -f "${CLAUDE_PLUGIN_DATA}/$(tl_repo_id)/drafts/prd-author.json" ]
   ```
   exits 0; `jq '.interview | length' <path>` (or the bash fallback)
   prints `2` (or more, if `decision` records were appended); the
   answered detail from each AskUserQuestion is present in the
   matching entry's `answer` field.
   - Negative: kill the session before answering any question.
     Observe: `[ -f <path> ]` exits 1 (no orphaned draft) — the
     init step is only triggered on the first elicitation.
2. **Restart detects + offers resume (FR-47).** After the kill in
   observation 1, re-invoke `/prd-author`. Observe: the first
   AskUserQuestion the skill emits names the draft path, prints the
   one-line summary (count of elicitations, started/updated
   timestamps), and offers options `Resume from draft` / `Discard
   and start fresh`. Confirming Resume: the next prompt is the
   *third* question (not a re-ask of the first two). Confirming
   Discard: the draft file is deleted (`[ -f <path> ]` exits 1) and
   the skill starts from step 1 normally.
3. **Draft survives compaction (FR-48).** In a fixture repo, run
   `/prd-author`; answer 3 substantive questions; force a context
   compaction (manually via `/compact` in the TUI, or by running the
   interview long enough to hit the automatic threshold); answer 2
   more questions; complete the PRD; open the PR. Observe: the final
   `docs/PRD.md` contains content traceable to all 5 elicitations
   (verifiable by `grep` against the answers); the draft's
   `interview[]` array at the moment before PR creation contains all
   5 entries.
4. **Draft lifecycle bounded by completion (FR-49).** From observation
   3's setup, after the PR is opened: `[ -f <path> ]` exits 1 (draft
   removed). `git ls-files | grep -i draft` produces no output (the
   draft was never under the repo's directory tree). Then kill a new
   `/prd-author` session mid-interview: `[ -f <path> ]` exits 0 (draft
   persists outside the repo).
5. **Design-reviewer freshness across resume (FR-50).** Run
   `/tdd-author` against a PRD that has a new requirement; let the
   skill reach step 7b and produce a design-reviewer verdict; kill
   the session before the PR opens; re-invoke `/tdd-author`; choose
   Resume. Observe: the resumed session runs the design-reviewer
   again (the per-TDD log under `~/.claude/projects/.../*.jsonl` for
   the second session contains a `Task` tool call to
   `design-reviewer` after the resume timestamp); the final design
   PR body carries a verdict whose timestamp is after the resume; the
   draft file at no point contains the string `DESIGN_REVIEW: PASS`
   or `DESIGN_REVIEW: BLOCK` (`grep -q DESIGN_REVIEW <draft>` exits
   1 throughout).

(Mechanism is the project's — plain shell + `grep`/`jq`/`python3`
here — delegated, not bundled, per FR-26 / ADR 0004.)

## Requirement traceability

| PRD | Design element |
|---|---|
| FR-46 Incremental persistence | `drafts.sh::tl_draft_append_elicit`; `prd-author`/`tdd-author` step-3 edit instructing append after EACH AskUserQuestion |
| FR-47 Restart detects + offers resume | `drafts.sh::tl_draft_exists` + `tl_draft_summary`; step-0 "Resume check" prompt edit in both skills |
| FR-48 Draft survives intra-session compaction | step-5 (prd-author) / step-5 (tdd-author) prompt edit: "re-read the draft before each authoring step + after each writes via `tl_draft_write_doc`"; self-review-from-draft sub-bullet |
| FR-49 Draft lifecycle bounded by completion | `tl_draft_discard` invocation at the end of the Git step (only after PR creation); `CLAUDE_PLUGIN_DATA` path naturally outside git (no tracking possible) |
| FR-50 Design-reviewer not cached across sessions | step-7b prompt edit forbidding verdict persistence; `drafts.sh` has no API for storing verdicts; `<kind>` parameter restricted to `question`/`decision` |

## Dependencies considered

**No new external dependencies.**

- `repo-id.sh` (TDD 0009) and `scripts/lib/state.sh::json_escape`
  (extracted there by TDD 0015) are existing throughline helpers;
  `drafts.sh` consumes both rather than duplicating them.
- `python3` is optional (the existing runner already uses the
  `jq → python3 → bash` cascade); `drafts.sh`'s reader functions
  follow the same cascade.
- `mkdir`, `mv`, `printf`, `grep`, `sed`, `rm` are POSIX.
- `CLAUDE_PLUGIN_DATA` is a Claude Code platform contract, not a new
  dep.

Rejected alternatives evaluated:
- **Persist to `docs/.prd-author.draft.json` (gitignored) inside
  the consumer repo.** Rejected: tied to the working tree (clone
  loses the draft); needs `.gitignore` extensions per repo;
  conflict between concurrent worktrees would be worse (both could
  ignore the file under their own ignore rule but still race-
  write). The `CLAUDE_PLUGIN_DATA` location chosen by the user
  removes these failure modes.
- **A PreCompact hook that snapshots the conversation.** Rejected:
  Claude Code's PreCompact hook does not have a way to know which
  skill is in flight or what counts as the "substantive
  elicitations"; it would dump raw conversation, which is exactly
  what `/compact` already does. The skill-driven `interview[]`
  array is the right granularity.
- **A SessionStart hook that auto-resumes.** Rejected as PRD non-
  goal (recovery is per-invocation, no daemon / auto-resume).
- **JSON Lines (one elicitation per line) instead of an embedded
  array.** Rejected: complicates the `draft_doc` co-location (we
  want one file per draft, not two); the at-most-tens-of-
  elicitations scale doesn't motivate the format change.
- **A SQLite database under `CLAUDE_PLUGIN_DATA`.** Rejected:
  introduces a runtime dep; one JSON file per draft is plenty for
  the scale; SQLite would also obscure the file-on-disk
  visibility the design relies on (a developer can `cat` the
  draft to inspect what was elicited).
- **Storing the AskUserQuestion message verbatim instead of a
  summarized record.** Rejected: the questions can be long; the
  draft would balloon. The `<header>` + truncated-question-text
  + answer format is sufficient for resume (it gives the model
  enough to know it asked X already).

## PRD conflicts surfaced (and resolution)

None. FR-46..50 form an internally consistent set; no conflict with
any `accepted` ADR (0003, 0004); no conflict with existing
implemented FRs.

The PRD's open question on **plugin schema skew across pause and
resume** is partially resolved here for the draft schema (additive
fields stay at `schema: 1`; breaking changes bump and refuse
resume) — the same policy TDD 0011 applies to run-state. The
combined effect closes the PRD open question across both surfaces.

No `BLOCKERS.md` entries to resolve.

## Touched files

- `scripts/lib/repo-id.sh` (modified, additive) — new `tl_drafts_dir`
  function per Components §1 (file itself is introduced by TDD 0009;
  this TDD's build must run after 0009)
- `scripts/lib/drafts.sh` (new) — seven `tl_draft_*` helper functions
  per Components §2; sources `scripts/lib/state.sh` for `json_escape`
- `skills/prd-author/SKILL.md` (modified) — five concrete prompt edits
  per Components §4
- `skills/tdd-author/SKILL.md` (modified) — five concrete prompt edits
  + two skill-specific tweaks per Components §5

Total: 4 files touched. (Prior draft listed 6 files; the
`scripts/lib/json-escape.sh` promotion + `scripts/implement.sh` edit
were dropped because TDD 0015 already extracted `json_escape` into
`scripts/lib/state.sh`.)

## Expected diff size

- `scripts/lib/repo-id.sh` — ~15 lines added (one function)
- `scripts/lib/drafts.sh` — ~185 lines added (seven helper functions +
  one `state.sh` source line at top; this is a meaty new helper file)
- `skills/prd-author/SKILL.md` — ~75 lines added (five prompt edits,
  each a substantive paragraph)
- `skills/tdd-author/SKILL.md` — ~75 lines added (five prompt edits
  + two skill-specific tweaks)

Total expected diff: ~350 lines across 4 files. All per-file under the
300-line default `THROUGHLINE_TDD_MAX_FILE_DIFF` bound; no per-file
exceptions needed.

## Scope override

This TDD's doc body is over the 350-line default
`THROUGHLINE_TDD_MAX_LINES` cap established by TDD 0014. Justification:
this TDD was authored before TDD 0014 (the bounds didn't exist when
this TDD was written). Its substance is a coordinated five-prompt-edit
operation against both authoring skills (`prd-author` and `tdd-author`)
plus their shared helper substrate (`scripts/lib/drafts.sh` consuming
`scripts/lib/state.sh::json_escape` and `scripts/lib/repo-id.sh::
tl_repo_id` from prior TDDs); the five-edit structure is mirrored in
both skill files for parallel resume/persist behavior. Splitting at this
point would either duplicate the helper layer description across two
TDDs or fragment the prompt-edit set across skills that need consistent
behavior. The override is recorded retroactively per FR-53's escape
clause (legitimately-wide design; coupled prompt-edit operation across
two skill files sharing one helper substrate).

## Decisions to promote (ADR candidates)

**None.**

The schema-versioning policy is already articulated in TDD 0011 for
the run-state; this TDD reuses it on the draft schema. The "drafts
live under `CLAUDE_PLUGIN_DATA`, never in the repo" decision is in-
scope of FR-49 itself; promoting to an ADR would add ceremony
without durable cross-cutting value.

(`tl_draft_*` helpers in `scripts/lib/drafts.sh` are an internal
plugin API — visible only to the skill prompts that source them —
and do not warrant an ADR on their own.)

# TDD 0073: Requirements review gate — coverage scan, PRD pre-pass, independent reviewer, overrides

Status: draft
PRD refs: FR-102, FR-103, FR-104, FR-105, FR-110, FR-87, NFR-3
PRD-rev: d526c55
ADR constraints: 0006, 0010, 0011, 0015

## Approach
`/prd-author` is the only authoring phase with no independent review.
This TDD gives it the same shape as the design gate (FR-10, FR-51):
- **Interview coverage scan (FR-102).** The interview marks nine
  categories `Clear`, `Partial` or `Missing`, and asks first about the
  categories where the answer would most change the design and is least
  settled. The result becomes a table in the PR body.
- **Mechanical pre-pass (FR-103):** `scripts/lib/prd-lint.sh`. It blocks
  on structural defects without spending model time, and it computes the
  **delta**, the requirement ids this change adds or alters.
- **Independent review (FR-104).** A fresh worker follows the fixed prompt
  `agents/requirements-reviewer.md`. It reviews the delta's requirements
  one by one, and the delta against the whole PRD for set-level problems.
  Its report ends `REQUIREMENTS_REVIEW: PASS|BLOCK <reason>`.
- **Overrides (FR-105).** Overrides are recorded lines under the PRD's
  `## Open questions`. prd-lint checks their form, and a re-run reviewer
  judges their substance.

The pre-pass reuses the requirement-block parser that TDD 0070 built in
`scripts/lib/ux_record.py`. One PRD grammar serves both the `[UI]` check
and the lint, so the two cannot disagree. Reviews are decision support
for the human merge (PRD non-goal: reviews are not a quality guarantee).

## Components & interfaces

### `scripts/lib/ux_record.py` (refactor, no behaviour change)
- Expose `parse_requirements(path) -> [(id, lineno, block_text, title_text)]`
  (`lineno` is the 1-based title line number; `title_text` is that line's
  text)
  for every requirement title (`REQ_RE`, with or without `[UI]`), in file
  order. It skips fences and inline code exactly as `parse_prd` does, and
  shares its block boundaries.
- `parse_prd` is reimplemented on top of it.
- `tl_ux_ui_reqs` output stays byte-identical. Observation 9 checks this.

### `scripts/lib/prd_lint.py` (new, python3 stdlib, `python3 -I -B`)
It imports `ux_record` the way `ux_render.py` does. Findings are printed
one per line as `<path>:<line> <severity> <code>: <message>`, matching
`tdd-lint`'s format.

The `<base-file>` argument is a path. The literal `none` means there is no
base, so every requirement is `new`. Stdin is never read.

The id grammar is `REQ_RE` (`^\*\*[A-Z][A-Z0-9]*-[0-9]+ `). The
requirement rules (`acceptance.missing`, `id.duplicate`, `id.malformed`,
`vague.term`) apply only to lines inside the PRD's `## Requirements`
section, up to the next `## ` heading. So bold text elsewhere, such as
`**COVID-19 policy.**` in Constraints or `**Phase-2 rollout**` in
Non-goals, is never read as a requirement. The prd-author Template states
the id grammar. A PRD with no `## Requirements` section gets one major
`placeholder` finding (`no ## Requirements section`) instead of silently
linting nothing. A retired-id
line of the form `**FR-56** *Retired.*` (the id closed by `**` with no
title) is recognised as a retired marker. It is never a requirement
block and never `id.malformed`. In `prd_lint` only, it ends the previous
block, so editing a retired line does not mark its neighbour `changed`.
`parse_prd`'s boundaries are unchanged, so `[UI]` hashes don't move. A
base PRD that fails to parse (for example an unterminated fence in an old
commit) is treated as no base, with a degrade line, never rc 2.

- **`delta <prd> <base-file|none>`.** It parses requirements in both files and
  prints one line per id, in PRD order:
  - `new\t<id>` when the id is absent from the base;
  - `changed\t<id>` when the block text differs (trailing whitespace
    ignored);
  - `removed\t<id>` when the id is in the base only.

  A missing base file means every id is `new`. It returns rc 0, or rc 2 on
  a parse error (an unreadable PRD, or a malformed `[UI]` marker, which is
  the same error as `tl_ux_ui_reqs`).
- **`check <prd> <base-file|none>`.** Runs every rule below; per-requirement
  rules apply to `new`/`changed` ids only.

  | Code | Severity | Fires when |
  |---|---|---|
  | `placeholder` | major | one of the placeholder tokens (to-be-decided, to-do, triple question mark; the exact list lives in `prd_lint.py`), outside fences and inline code, **on a line that is new compared with the base** (a line-level diff), so old text never blocks a later change. Also an **empty section**: a `##`/`###` heading followed by nothing, not even a subsection, before the next heading of the **same or higher** level. A `## Requirements` heading followed directly by `### Area` is not empty |
  | `acceptance.missing` | major | a delta requirement block does not match `(—\|--)\s+Acceptance:` (any whitespace, line breaks included, between the dash and `Acceptance:`) |
  | `id.duplicate` | major | the same id is the title of two requirement blocks |
  | `id.malformed` | major | **on a line new compared with the base**, a list line whose bold token matches `^\*\*[A-Za-z]+ ?- ?[0-9]` (a digit after the hyphen) but neither `REQ_RE` nor the retired-marker form, for example `FR-1a`, `FR -3`, `fr-3`. Ordinary hyphenated bold words (`**Auto-merging**`, `**Cross-vendor review**`) never match |
  | `override.rationale` | major | an `## Open questions` line `- "<finding>" — overridden: <rationale>` whose rationale is outside 20–400 characters |
  | `vague.term` | info | a delta requirement block contains, outside inline code, a word from the fixed list (below) not followed within the same sentence by a number |

  The fixed vague-term list is: fast, quick, quickly, slow, scalable,
  robust, secure, user-friendly, intuitive, easy, simple, efficient,
  flexible, seamless, reliable, performant, appropriate, adequate,
  sufficient, reasonable, minimal, as needed, as appropriate.

  Return codes:
  - rc 0: no major findings; info findings may print;
  - rc 1: at least one major finding;
  - rc 2: a parse or internal error, as `prd-lint: internal error: <type>: <msg>`.

### `scripts/lib/prd-lint.sh` (new)
It sources `plugin-root.sh` and `verdicts.sh` (for `_tl_integration_ref`),
and fails closed with `prd-lint: cannot source <file>` (rc 2).
- **`tl_prd_base <repo-root> <out-file>`.** It resolves the base and never
  stops the skill:
  1. If `<repo-root>` is outside git, it prints
     `prd-lint: no base (not a git work tree); every requirement is new`
     and returns rc 1.
  2. It resolves `<ref>` with `_tl_integration_ref <repo-root>`; when none
     resolves it falls back to `HEAD`, and prints
     `prd-lint: base is HEAD (no integration branch)`. It checks the ref
     with `git rev-parse -q --verify <ref>^{commit}`. If that fails (for
     example a repo with no commits), it prints
     `prd-lint: no base (no commits); every requirement is new` and
     returns rc 1.
  3. It tests for the file with
     `git -C "<repo-root>" ls-tree <ref> -- docs/PRD.md`. `ls-tree` paths
     are relative to the current directory, so `-C` is required:
     - empty output with rc 0 means no PRD on the base yet: rc 1;
     - a non-empty line means
       `git -C "<repo-root>" show <ref>:docs/PRD.md > <out-file>`,
       then rc 0;
     - any non-zero rc from `ls-tree` or `show` is a real git failure:
       `prd-lint: git <cmd> failed (rc <n>)`, rc 2.

  A degrade line (steps 1–2) is printed to stdout so the skill can copy it
  into the PR body. This also covers the skill's existing "skip git" path.

  **Strictness by base mode.**
  - With a real base, or a genuine first PRD (no PRD on a valid ref, or a
    repo with no commits), the rules apply as written. A first PRD is
    meant to be fully reviewed.
  - When the base is **degraded**, `acceptance.missing` and `placeholder`
    on lines that are only "new" because the base is missing are reported
    as `info`, not `major`, so a legacy PRD isn't blocked by its own
    history. Degraded means outside git, or an unparseable base
    (`prd_lint.py` prints
    `prd-lint: base unparseable (<reason>); every requirement is new`).
    The degrade line tells the reviewer to apply judgement instead.
- **`tl_prd_lint <repo-root>`.** Gets the base through `tl_prd_base`
  (rc 1 passes `none`; rc 2 is returned as rc 2), then runs `check`. It
  first prints `prd-lint: base <ref>` (or `prd-lint: base none`), then the
  findings, then `prd-lint: delta <n> requirements, <m> major, <k> info`.
  - When python3 is absent it prints `prd-lint: python3 required` and
    returns rc 3. Unlike `ux.sh`, there is no short-circuit: every PRD
    needs the parser.
  - Otherwise it returns `check`'s rc.
- **`tl_prd_delta <repo-root>`.** Prints `delta`'s lines, with the same rc
  rules.

### `agents/requirements-reviewer.md` (new)
Frontmatter: `name: requirements-reviewer`, `tools: Read, Grep, Glob,
Bash`, `model: inherit`. The dispatch gives it the PRD path, the delta
lines, the report-file path and the repo root. Its rules:
1. **Scope.** It checks only the `new`/`changed` ids, one by one; it never
   re-litigates earlier requirements. It reads the whole PRD for
   set-level checks.
2. **Per-requirement checks:**
   - necessary: it traces to a stated user goal or problem;
   - unambiguous: there is exactly one reasonable reading;
   - complete: no missing actor, trigger or outcome;
   - singular: one need per requirement;
   - feasible: no conflict with stated constraints;
   - verifiable: the `— Acceptance:` clause names an observable surface,
     never "a test exists" (FR-24);
   - conforms to the template.
3. **Set-level checks** of the delta against the whole PRD:
   - contradiction with an existing requirement, constraint or non-goal;
   - duplication;
   - terminology drift, where the same concept is named differently.
4. **Readers' perspectives:** it reads the delta as the product owner, an
   implementer, a tester and a stakeholder, and reports any finding that
   only one of them would raise.
5. **Rubric.** It grades the PRD's `## Evaluation rubric` rows (FR-77).
   A `Failing` grade is a BLOCK.
6. **Findings.** Each finding is one line in exactly the shared format
   (TDD 0075):
   `R-n <severity> — docs/PRD.md:<line> — <finding>`. Severity is
   blocker, major, minor or nit, and `<finding>` is one sentence stating
   the defect. Why it matters follows on the next indented line.

   `vague.term` info lines from prd-lint are inputs. Each is a finding
   only if the term really leaves the requirement unverifiable.
7. **Overrides (FR-105).** It reads the `## Open questions` lines
   `- "<finding>" — overridden: <rationale>`. The quote is the
   `<finding>` sentence only, with no `R-n`, severity or citation, so
   renumbering and line shifts don't break it.
   - When it raises an issue that an override covers (judged by meaning),
     it repeats that override's quoted `<finding>` text word for word and
     reports it as `overridden`, non-blocking.
   - That doesn't apply when the rationale is boilerplate: it restates
     the decision, or gives no reason specific to the finding. The
     finding is then reported as
     `R-n blocker — docs/PRD.md:<line> — override rejected: "<finding>"`,
     with `<why>` on the indented second line like every finding.
8. **Non-findings (FR-110).** These are listed under `### Non-findings`
   in the shared format
   `<label> — "<quoted candidate finding>" — <why set aside>`, with label
   `pedantic escalation` or `imaginary architecture`. It never dismisses
   a category of finding by rule.
9. **Calibration.** It blocks only on a blocker or major finding that
   would make an implementer build the wrong thing, or a tester unable to
   tell. Approve otherwise.
10. **Verdict.** It writes the full report to the dispatched path, and the
    last line is exactly `REQUIREMENTS_REVIEW: PASS` or
    `REQUIREMENTS_REVIEW: BLOCK <one-line reason>`.

### `skills/prd-author/SKILL.md`
- **Interview, coverage scan (FR-102).** Before the first substantive
  question, the session marks each of the nine categories
  `Clear`/`Partial`/`Missing` for this change:
  - functional scope;
  - domain and data;
  - interaction and flow;
  - non-functional qualities;
  - integrations and dependencies;
  - edge cases and failure handling;
  - constraints and trade-offs;
  - terminology;
  - completion signals.

  It asks first about the `Partial`/`Missing` categories with the highest
  (impact on the design × uncertainty). Each category is appended with
  header `coverage: <category>`, with the answer
  `initial <status>; final <status>; <resolution or open question>`. The
  PR-body table shows both statuses, so a `Partial`/`Missing` row names
  what resolved it (FR-102). Before writing the PRD, every
  `Partial`/`Missing` category has a resolution or an Open questions
  entry.
- **New step, "Requirements review" (after self-review and
  `tl:ui-markers`, before Git):**
  1. Run `<!-- tl:prd-lint -->` (inputs `TL_REPO`). It sources
     `plugin-root.sh` and `prd-lint.sh`, runs `tl_prd_lint "$TL_REPO"`,
     then `tl_prd_delta "$TL_REPO"`, printing both outputs.
     - rc 1: fix and re-run.
     - rc 3: the PR body records
       `Pre-pass unavailable: python3 required`, and the review still runs.
     - rc 2 (a real git failure): show stderr and stop.
     - Any `prd-lint: base is HEAD …`, `no base …` or
       `base unparseable …` line is copied into the PR body under
       `## Requirements review`.
  2. Dispatch **one** fresh worker whose instructions are
     `$(tl_plugin_root)/agents/requirements-reviewer.md`:
     - no model parameter (FR-87);
     - it must not spawn children;
     - it gets the repo root, the PRD path, the `prd-lint: base <ref>`
       line, the delta lines, the prd-lint `vague.term` info lines, and a
       report file from a fresh `mktemp`. The path is never recorded in
       the draft. A resumed session always makes a new one and dispatches
       a new reviewer, so an earlier verdict can't be reused (FR-104).
     - When prd-lint returned rc 3 (no python3), it gets no delta lines.
       Instead it is told to derive the delta itself from
       `git diff <base> -- docs/PRD.md`, or from the whole PRD when
       there is no base.

     The report file's last line is authoritative. A missing or any other
     line counts as BLOCK.
  3. **On BLOCK,** for each blocking `R-n`, ask a structured question
     with three options:
     - fix the requirement;
     - override with a rationale of 20–400 characters, which writes the
       Open questions line in the exact form above;
     - stop.

     Then dispatch a **new** reviewer, since the verdict is never reused
     (as FR-50) or written to the draft.
- **Git.** The commit body (and therefore the PR body) gains:
  - `## Coverage scan`: the nine-row table;
  - `## Requirements review`: the verdict line, the findings summary
    (`R-n <severity> — <finding>`), and each override as
    `"<finding>" — overridden: <rationale>`, the same form as the Open
    questions line (FR-105).

### Tests
- `tests/prd-lint.test.sh` (new): drives `prd_lint.py` through
  `prd-lint.sh` in temp git repos with a `master` base.
- `tests/requirements-review.test.sh` (new): extracts the
  `tl:prd-lint` block and runs it under `env -i`, and checks the agent
  contract text.
- Both are registered in `tests/implement-gate.test.sh`.

## Data & state
No new persistent state beyond the PRD itself. Overrides live in
`## Open questions`. The draft gains `coverage:` entries and the report
path. The review verdict is never persisted (FR-50 analogue).

## Sequencing / implementation plan
1. Refactor `ux_record.py` (`parse_requirements`), then add `prd_lint.py`
   and `prd-lint.sh` with `delta` and `check`. Write the prd-lint eval
   first (red), then the code.
2. Write `agents/requirements-reviewer.md`.
3. Edit `skills/prd-author/SKILL.md` (the coverage scan, the review step,
   the `tl:prd-lint` block, the commit-body sections), and write the
   requirements-review eval. Register both evals.

## Failure modes & edge cases
**Real risks**
- *The first PRD in a repo.* There is no base on the integration branch,
  so everything is `new` and every requirement gets per-requirement
  review once. That is correct for a first PRD.
- *A rename of a requirement id* shows as `removed` plus `new`. The
  reviewer sees both lines and can flag a lost requirement.
- *Low recall.* The reviewer misses about half of real issues (benchmark).
  The PR body says "decision support"; the human merge remains the gate.
- *The vague-term list is English-only and crude.* It is info only, so it
  can never block. The reviewer decides.

**Overblown risks**
- *python3 now needed for every PRD.* It degrades with a recorded line
  and never fails silently. A python3-less consumer repo still gets the
  review.

**Unspoken risks**
- *An override that matches a different finding on a re-run.* Matching
  uses the bare `<finding>` sentence, not `R-n`, so a renumbered report still
  matches. A finding whose wording changed between runs is a new finding,
  which is the safe direction.
- *The integration branch is behind origin.* `tl_prd_base` uses the same
  ref as `ux.sh`, so a stale local branch inflates the delta. That is
  noisy but safe: more is reviewed, not less.

## Verification plan
- **Surface:** stdout, stderr and rc of `tl_prd_lint` / `tl_prd_delta`
  and the extracted `tl:prd-lint` block; `tl_ux_ui_reqs` output bytes;
  the requirements-reviewer's report file and verdict line on fixtures.
- **Harness:** temp git repos with `master` holding a base `docs/PRD.md`
  and a working-tree edit. Blocks run under `env -i`. A missing marker or
  file is a FAIL (L-001), every negated grep asserts readability first,
  and temp dirs are trap-cleaned (L-004).
- **Observation points → expected (PASS):**
  1. **Delta.** Base with FR-1 and FR-2; working tree edits FR-2 and adds
     FR-3 → `changed\tFR-2`, `new\tFR-3`. Removing FR-1 →
     `removed\tFR-1`. No base on master → all ids `new`.
  2. **acceptance.missing.** A new FR-3 with no `— Acceptance:` → rc 1,
     and a line `docs/PRD.md:<n> major acceptance.missing:` naming FR-3.
     Unchanged FR-1 lacking an acceptance clause → no finding.
  3. **placeholder.** A to-do token in prose → major. The same token in
     backticks or a fence → none. An empty `### X` section → major.
  4. **ids.** Two `**FR-2 …**` titles → `id.duplicate`. `**FR-2a …**` →
     `id.malformed`.
  5. **vague.term.** A new FR containing "fast" with no number → an
     `info vague.term` line, and rc 0. "within 2 seconds" alongside it →
     no finding.
  6. **override.rationale.** A rationale of `ok` → major, rc 1. A
     30-character rationale → none.
  7. **No python3.** A PATH without python3 → `prd-lint: python3 required`,
     rc 3. The git degrade cases are observations 15 and 17.
  8. **The block.** The extracted `tl:prd-lint` block under `env -i` on
     the observation-2 fixture → rc 1, both outputs printed. Unset
     `TL_REPO` → it fails loudly.
  9. **No UX regression.** `tl_ux_ui_reqs` on the 0070 fixtures and on
     this repo's PRD gives byte-identical output before and after the
     refactor, and `tests/ux-record.test.sh` stays green. The
     retired-marker block boundary is applied by `prd_lint` only, never by
     `parse_prd`, so `[UI]` block hashes are unchanged.
  9b. **Hyphenated bold bullets.** `- **Auto-merging** …` and
      `- **Cross-vendor review** …` on new lines → no `id.malformed`.
      `**FR-1a …**` → `id.malformed`.
  9c. **Unparseable base.** A base PRD with an unterminated fence → the
      lint prints `prd-lint: base unparseable (<reason>); every
      requirement is new` and treats the base as `none`, rc 0 or 1 on the
      working tree's own findings. Never rc 2.
  10. **Reviewer, BLOCK** (parent-dispatched fixture). Delta FR-3 reads
      "The export runs when the user is ready." The parent dispatches a
      fresh reviewer with `agents/requirements-reviewer.md`. The report's
      last line is `REQUIREMENTS_REVIEW: BLOCK …`, and a finding citing
      `docs/PRD.md:<FR-3 line>` names the ambiguity.
  11. **Reviewer, PASS** (parent-dispatched). A clean delta FR-3 with an
      observable acceptance clause → `REQUIREMENTS_REVIEW: PASS`, and
      every finding carries an `R-n` id and a `docs/PRD.md:<line>`
      citation.
  12. **Override re-check** (parent-dispatched). The observation-10
      finding is overridden with the 32-character boilerplate rationale
      "overriding because we decided so" → `BLOCK` with
      `override rejected`. A specific rationale → that finding is
      reported `overridden`, with PASS.
  13. **Agent contract** (a text check by necessity, prompt prose):
      `model: inherit`, both verdict tokens, the exact finding-line format
      shared with TDD 0075, the write-to-dispatched-path rule, the
      override line format with the bare `<finding>` quote, and the
      `### Non-findings` format. No rule dismisses a category of finding.
  14. **Regression.** All evals are green, and this repo's PRD lints with
      rc 0 against its own master base, even though it contains an old
      placeholder token in prose (line-level diff rule) and retired-id
      lines (retired-marker rule).
  15. **Degrade without git.** Outside git (and on the skill's
      "skip git" path), `tl_prd_lint` prints
      `prd-lint: no base (not a git work tree); every requirement is new`
      and still lints. In a repo whose only branch is `feature`, it prints
      `prd-lint: base is HEAD (no integration branch)`. In a fresh
      `git init` repo with no commits, it prints the no-commits line. None
      of these returns rc 2.
  16. **Parent heading.** `## Requirements` followed directly by
      `### Setup` gives no `placeholder` finding. A `### Empty` followed
      directly by `### Next` gives one.
  17. **Git failure.** A `git` stub that passes `rev-parse` but exits 128
      on `ls-tree` → rc 2 and a `prd-lint: git ls-tree failed` line.
  18. **Skill text** (a text check in `requirements-review.test.sh`, by
      necessity; the interview is model prose):
      - the nine coverage category names;
      - the `initial <status>; final <status>; …` answer format;
      - the `## Coverage scan` and `## Requirements review` PR-body
        sections;
      - the PR-body override line;
      - the fresh-`mktemp` / never-recorded report rule.

      Each check asserts the file is readable first.
  19. **Section scoping and degraded strictness.**
      - A new `**COVID-19 policy.**` bullet under `## Constraints` → no
        `acceptance.missing`. A PRD with no `## Requirements` → one major
        `placeholder`.
      - Outside git, a legacy requirement without an acceptance clause →
        `info acceptance.missing`, and rc 0.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement traceability | FR-102..110 (+FR-87/NFR-3 enum) each map to a named function, block, prompt rule or lint code | One mapping indirect but named | An in-scope FR untraced |
| interface concreteness | prd-lint/tdd-lint finding codes, rc, verdict lines, override line format pinned | One rc implicit | Reader can't tell what a check prints |
| alternatives-analysis substance | python parser reuse vs awk, override storage, finding ids, dispatch-by-file each with reason | One rejection thin | None named |
| verification-plan actionability | Lints driven in temp repos; reviewers driven on named fixtures by parent dispatch with expected verdicts; text checks state why | One check text-only with stated reason | Reviewer behaviour asserted only by grepping prompts |
| scope-bound adherence | Each TDD <=8 files, <=500 body lines, padded estimates, eval registration declared | One justified exception | Over a bound unexplained |
| naming consistency | Verdict tokens, finding ids, (new) marker, override line identical across 0073-0075 | One alias reconciled | Same concept named two ways |
| contract symmetry | requirements / design / ux / build reviewers each: fixed prompt file, cited findings, R-n ids, exact verdict line, FR-110 non-finding rule | One differs with stated reason | A reviewer still improvised or uncited |
| consumer-repo neutrality | No throughline-repo layout in any lint, prompt or skill; degrade paths (no python3, no integration ref, outside git) stated | One degrade implied | A rule only true in this repo |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-102 interview coverage scan | prd-author interview: nine categories, impact × uncertainty ordering, `coverage:` draft entries, PR-body `## Coverage scan` table |
| FR-103 mechanical PRD pre-pass | `prd_lint.py check` codes `placeholder`, `acceptance.missing`, `id.duplicate`, `id.malformed`, info `vague.term`; `tl_prd_lint`; obs 2–8 |
| FR-104 independent requirements review | `agents/requirements-reviewer.md` (delta-scoped, set-level, four perspectives, rubric, `REQUIREMENTS_REVIEW` verdict); fresh-worker dispatch; never reused; obs 10, 11, 13 |
| FR-105 recorded, re-checkable overrides | the `## Open questions` override line; `override.rationale` lint; reviewer re-check; obs 6, 12 |
| FR-110 reviewable non-findings (requirements reviewer) | reviewer rule 8 (quote to dismiss, no category dismissal); obs 13. The other reviewers are in TDD 0075 |
| FR-87 / NFR-3 reviewer inherits | dispatch with no model parameter; `model: inherit` |

## Dependencies considered
- **Reuse the `ux_record.py` parser (chosen).** One requirement grammar.
  - *Rejected: a new awk prd-lint.* A second grammar could disagree with
    `tl_ux_ui_reqs` (the drift TDD 0072 avoided), and it would repeat the
    L-005 silent-parse risk.
- **Overrides in the PRD's `## Open questions` (chosen).** They persist
  in the artifact and re-run reviewers read them.
  - *Rejected: draft-only overrides.* They are lost after the PR, and the
    PRD stops recording what was consciously accepted.
- **`R-n` ids plus the bare `<finding>` sentence as the override quote (chosen).**
  - *Rejected: hashes of the finding text.* They are stable but
    unreadable to the human who must judge the override.
- **Dispatch by prompt file (chosen).** It works on Claude Code and Grok
  (FR-79, FR-81).
  - *Rejected: naming a Claude agent type.* It is harness-specific.

## PRD conflicts surfaced (and resolution)
- FR-105's acceptance writes the override as
  `<finding> — overridden: <rationale>`. This design puts the finding in
  double quotes (`"<finding>"`), so a reviewer can match it exactly and
  prd-lint can split it unambiguously. The quotes delimit the same
  content.
- FR-105's acceptance expects a re-run given the override rationale `ok`
  to BLOCK. Under FR-103 the mechanical pre-pass rejects `ok` (under 20
  characters) before any reviewer runs. The design honours both:
  `override.rationale` catches short rationales mechanically (obs 6), and
  the reviewer's re-check is exercised with a 20+ character boilerplate
  rationale (obs 12).

## Decisions to promote (ADR candidates)
- None. See TDD 0075: the shared reviewer contract is already binding as
  FR-104/108–110.

## Touched files
- `scripts/lib/ux_record.py` — expose `parse_requirements`; `parse_prd` built on it
- `scripts/lib/prd_lint.py` (new) — `delta`, `check`
- `scripts/lib/prd-lint.sh` (new) — `tl_prd_base`, `tl_prd_lint`, `tl_prd_delta`
- `agents/requirements-reviewer.md` (new) — fixed reviewer prompt
- `skills/prd-author/SKILL.md` — coverage scan, review step, `tl:prd-lint`, commit-body sections
- `tests/prd-lint.test.sh` (new) — obs 1–9c, 14–17, 19
- `tests/requirements-review.test.sh` (new) — obs 8, 13
- `tests/implement-gate.test.sh` — register the two evals

## Expected diff size
- `scripts/lib/ux_record.py` — 60 lines
- `scripts/lib/prd_lint.py` — 260 lines
- `scripts/lib/prd-lint.sh` — 110 lines
- `agents/requirements-reviewer.md` — 110 lines
- `skills/prd-author/SKILL.md` — 110 lines
- `tests/prd-lint.test.sh` — 290 lines
- `tests/requirements-review.test.sh` — 160 lines
- `tests/implement-gate.test.sh` — 6 lines

Total expected diff: 1106 lines across 8 files.

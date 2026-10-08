# TDD 0074: `tdd-lint` workspace grounding and no deferred discovery

Status: draft
PRD refs: FR-106, FR-107
PRD-rev: d526c55
ADR constraints: 0005, 0006, 0010

## Approach
Two new checks in the existing mechanical TDD pre-pass (FR-51), so a TDD
that names files that don't exist, or that defers codebase discovery to
the build, is stopped before any model time is spent:
- **Grounding (FR-106).** Every `## Touched files` path either exists on
  the integration branch, or is marked `(new)` right after the path. This
  applies only to **new** TDDs, meaning TDD files absent from the
  integration branch. Merged TDDs are never re-checked, so existing
  history is unaffected.
- **Deferred discovery (FR-107).** Phrases that put off finding code until
  the build are blocking placeholder findings outside fences and inline
  code.

Both reuse the existing parsers. The Touched-files path comes from the
single annotation-robust extractor (`md_bullet_path`, TDD 0049), extended
with a mode that also reports the `(new)` mark. The phrase check extends
`tl_lint_placeholders`'s phrase list. The integration ref comes from
`_tl_integration_ref` in `verdicts.sh`, the same resolution `/build-tdds`
and the UX helpers use. Nothing here is specific to the throughline repo.

## Components & interfaces

### `scripts/lib/md.sh`: `md_bullet_path <file> <section> marked` (new mode)
For each `- ` bullet in the section, it prints `<path>\t(new)` when the
text between the path and the em-dash contains the token `(new)`
(case-sensitive, standalone). Otherwise it prints `<path>\t-`. Path
extraction is exactly the existing `paths` mode, so the two cannot
disagree. Existing modes are unchanged.

### `scripts/lib/tdd-lint.sh`
- **`tl_lint_grounding <tdd-path>`** (new, wired into `tl_lint_all`):
  1. Resolve the repo root as `git -C "$(dirname <tdd>)" rev-parse
     --show-toplevel`. If that fails (outside git), print
     `tdd-lint: grounding skipped: <tdd> is not in a git work tree` to
     stderr and return 0. That is a declared skip, never a silent pass.
  2. Load `_tl_integration_ref` by sourcing `verdicts.sh` lazily inside
     the function, the first time it is needed. A source failure prints
     `tdd-lint: grounding: cannot source verdicts.sh` and returns rc 2.
     Call it as `_tl_integration_ref "<repo-root>"`. If none resolves,
     use `HEAD`, and say so in every finding as
     `(checked against HEAD: no integration branch)`. Then check the ref
     once with `git -C <root> rev-parse -q --verify <ref>^{commit}`. If
     that fails (a repo with no commits), print
     `tdd-lint: grounding skipped: no commits` to stderr and return 0.
  3. **Path queries** never use `git cat-file -e`, whose exit 128 means
     both "missing" and "git failed". They use
     `git -C <root> ls-tree <ref> -- <path>`:
     - rc 0 with non-empty output: the path exists;
     - rc 0 with empty output: it does not;
     - any non-zero rc: a real failure. Print
       `tdd-lint: grounding: git ls-tree failed (rc <n>) on <tdd>` and
       return 2. It never reports clean on a helper failure (L-005).
  4. **Go-forward rule.** The TDD's repo-relative path comes from
     `git -C "$(dirname <tdd>)" ls-files --full-name --error-unmatch
     -- "$(basename <tdd>)"`, falling back to
     `git rev-parse --show-prefix` plus the basename for an untracked
     file. It never comes from string-stripping a possibly symlinked
     absolute path. If that path exists on `<ref>` (step 3), the TDD is
     already merged: return 0 with no findings.
  5. For each `marked` line, in this order:
     - a path that contains a `..` segment, or starts with `/`, is
       `grounding.invalid` (major), whatever its marker;
     - a path marked `(new)` passes;
     - otherwise, a path that does not exist on `<ref>` (step 3) gets,
       through `_tl_emit`, severity `major`, code `grounding.missing`:
       `<path> is not on <ref> and is not marked (new)`. rc 1.

     A path created by another TDD in the same unmerged design set is
     written `(new)` in every TDD that touches it, because it is not on
     the integration branch yet.
  6. An extractor failure (`md_bullet_path` non-zero) prints
     `tdd-lint: grounding: extractor failed (rc <n>) on <tdd>` and returns
     2.
- **Deferred-discovery phrases (FR-107)**, added to the existing
  `tl_lint_placeholders` phrase list and emitted under the new code
  `placeholder.deferred_discovery` (major). They use the existing ```
  fence skipping and case-insensitive match. **Inline-code skipping is
  new, and applies to these phrases only.** The existing
  `tl_lint_placeholders` does not skip backticks, and changing that for
  the old phrases would change existing TDDs' exit codes (for example
  0013 fires on a backticked token today). Before matching a
  deferred-discovery phrase, the line has its `` `…` `` spans removed.
  The old phrases are matched exactly as before. The list is one more
  `split` string, so adding a phrase later is a one-line change. The list is kept in a fence here so that this TDD
  does not trip its own check:

  ```
  find the file | search for the file | locate the file
  locate during implementation | located during implementation
  locate the caller | search for callers
  determined during implementation | discover during implementation
  figure out during implementation | during implementation, find
  ```

### `skills/tdd-author/SKILL.md`
- The "Declared scope" paragraph documents the marker: a file the TDD
  creates is written `` - `<path>` (new) — <purpose> ``. Every other path
  must already exist on the integration branch, and `tdd-lint` checks it
  (FR-106).
- The pre-pass paragraph in 7a names the two new finding codes. It also
  says that a `grounding.missing` finding means fix the path or mark it
  `(new)`, never suppress it.

### `tests/tdd-grounding.test.sh` (new)
It drives `tdd-lint.sh` on fixture TDDs in temp git repos. It is
registered in `tests/implement-gate.test.sh`.

## Data & state
None. The check is read-only over git and the TDD file.

## Sequencing / implementation plan
1. Add the `marked` mode to `md_bullet_path`, then `tl_lint_grounding`
   and its wiring into `tl_lint_all`, failing eval first.
2. Add the deferred-discovery phrases and finding code, then the
   tdd-author skill text. Register the eval.

## Failure modes & edge cases
**Real risks**
- *A TDD that moves or renames a file.* The old path exists and the new
  path is marked `(new)`. Both lines pass, which is correct.
- *A path that is a directory* (e.g. `docs/ux/screens/login/`).
  `git ls-tree <ref> -- <dir>` lists a tree entry, so it passes when the
  directory exists on the integration branch.
- *A stale local integration branch.* A file merged on the host but not
  fetched reads as missing. The finding names `<ref>`, so the fix (fetch)
  is obvious. The lint never fetches; the pre-pass stays offline, as
  with `THROUGHLINE_UX_NOFETCH`.
- *The phrase list catches legitimate prose* ("the build will locate the
  file by its hash"). Findings are fixable by rewording, or can be waived
  in the design PR body, as for every lint finding (FR-51).

**Overblown risks**
- *Existing TDDs suddenly failing.* The go-forward rule exempts every TDD
  already on the integration branch. Observation 7 runs the lint over all
  of `docs/tdd/0*.md` and requires unchanged exit codes.

**Unspoken risks**
- *The marker hides a typo.* A misspelled path marked `(new)` passes
  grounding; the build creates the misspelled file. The design-reviewer
  and build reviewer still see it; grounding only guarantees that an
  unmarked path is real.
- *Detection of "new TDD" by absence from the integration branch.* A TDD
  authored on a branch, merged, then revised in a later pass is "merged"
  and no longer grounding-checked. That matches FR-106's go-forward
  wording, but means revisions of a merged draft TDD skip grounding. This
  is accepted and recorded here.

## Verification plan
- **Surface:** stdout, stderr and rc of `bash scripts/lib/tdd-lint.sh
  <tdd>`, and of the sourced `tl_lint_grounding`; `md_bullet_path …
  marked` output.
- **Harness:** temp git repos with `master` holding some files and a
  merged TDD, plus a new, uncommitted TDD in the working tree. A missing
  file or marker is a FAIL. Every negated grep asserts readability first.
  Temp dirs are trap-cleaned.
- **Observation points → expected (PASS):**
  1. **Missing path.** A new TDD lists `scripts/lib/nope.sh` without
     `(new)` → rc 1, and a `major grounding.missing:` line naming the path
     and `master`.
  2. **Marked.** The same path written as `` `scripts/lib/nope.sh` (new) — x ``
     → no finding.
  3. **Existing.** A path that is on `master` → no finding. A path present
     only in the working tree, unmarked → finding, because grounding
     checks the integration branch, not the disk.
  4. **Go-forward.** The same unmarked missing path inside a TDD that is
     already committed on `master` → rc 0, no finding.
  5. **No integration ref.** In a repo with only a `feature` branch and
     `THROUGHLINE_INTEGRATION_BRANCH` unset, the finding text says
     `(checked against HEAD: no integration branch)`. Outside git → rc 0,
     with the stderr skip line.
  6. **Deferred discovery.** A fixture TDD whose prose contains the
     FR-107 acceptance example → rc 1, and a
     `major placeholder.deferred_discovery` line quoting the phrase. The
     same phrase in a ``` fence, or inside backticks → no finding.
     Backtick skipping applies to these phrases only: an old forbidden
     phrase inside backticks still fires, as it does today.
  7. **Regression.** `tdd-lint.sh` on every `docs/tdd/0*.md` in this repo
     gives the same exit code as master's `tdd-lint.sh`. They are all
     merged TDDs, so grounding is exempt. The phrase additions are checked
     for any new finding, which is listed and must be zero. All existing
     evals stay green, including those that call `tdd-lint`
     (`ux-pipeline`, `token-spend-reduction`, `md-parser`,
     `bounded-tdd-scope`). Their fixtures have no `## Touched files`, or
     sit outside git and only gain the stderr skip line.
  8. **The `marked` mode.** `md_bullet_path <tdd> "Touched files" marked`
     prints `<path>\t(new)` / `<path>\t-` in bullet order, and `paths`
     mode output is byte-identical to before.
  9. **Helper failure.** With `git` replaced on PATH by a stub that passes
     `rev-parse` (it execs the real git for that subcommand) but exits 128
     on `ls-tree`, the lint on a new TDD → rc 2 and a
     `tdd-lint: grounding: git ls-tree failed` line, never rc 0. A repo
     with no commits → rc 0, and the `no commits` skip line.
  10. **Invalid paths and siblings.** A `../x` path marked `(new)` →
      `grounding.invalid`. Two new TDDs that both list the same
      not-yet-merged file as `(new)` → no findings.

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
| FR-106 TDD workspace grounding | `md_bullet_path … marked`; `tl_lint_grounding` (integration ref, HEAD fallback, go-forward rule, `grounding.missing`/`grounding.invalid`, fail-loud); tdd-author `(new)` marker text; obs 1–5, 7–9 |
| FR-107 no deferred discovery | `placeholder.deferred_discovery` phrases in `tl_lint_placeholders`; obs 6, 7 |

## Dependencies considered
- **Check against the integration branch with `git ls-tree` (chosen).**
  Merged state is what the build branches from.
  - *Rejected: the working tree.* It passes files created on the very
    branch being designed, and files that are local only.
- **Detect new TDDs by absence from the integration branch (chosen).** No
  author action is needed.
  - *Rejected: an opt-in `Grounding: v1` frontmatter flag.* It is
    explicit, but forgettable, and a forgotten flag silently disables the
    check.
- **Extend `md_bullet_path` with a mode (chosen).** One Touched-files
  parser.
  - *Rejected: a separate `(new)` regex in tdd-lint.* A second path
    parser is the drift TDDs 0048/0049 were written to remove.

## PRD conflicts surfaced (and resolution)
- FR-107's acceptance example is matched by the listed phrase
  `locate the caller`, so observation 6 uses exactly that sentence.
- The existing forbidden-phrase list already catches FR-107's example
  (the "to-be-determined" phrase) under the older code. This TDD adds the
  deferred-discovery phrases that the old list does not catch.
- No existing TDD contains any of the new phrases (checked at authoring
  time with a case-insensitive grep), so observation 7's "zero new
  findings" is expected to hold.

## Decisions to promote (ADR candidates)
- None. This extends the FR-51 pre-pass in place.

## Touched files
- `scripts/lib/md.sh` — `md_bullet_path` `marked` mode
- `scripts/lib/tdd-lint.sh` — `tl_lint_grounding`, `tl_lint_all` wiring, deferred-discovery phrases
- `skills/tdd-author/SKILL.md` — `(new)` marker convention; new finding codes in 7a
- `tests/tdd-grounding.test.sh` (new) — obs 1–10
- `tests/implement-gate.test.sh` — register the eval

## Expected diff size
- `scripts/lib/md.sh` — 30 lines
- `scripts/lib/tdd-lint.sh` — 110 lines
- `skills/tdd-author/SKILL.md` — 20 lines
- `tests/tdd-grounding.test.sh` — 260 lines
- `tests/implement-gate.test.sh` — 4 lines

Total expected diff: 424 lines across 5 files.

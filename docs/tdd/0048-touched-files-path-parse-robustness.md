# TDD 0048: Touched-files path-parse robustness (consistent declared-scope extraction)
Status: implemented
PRD refs: FR-67 (criterion (a) touched-file-set check); FR-53; FR-54
PRD-rev: 0aa1e28
ADR constraints: 0005, 0006

## Approach
The FR-67(a) structural check ("a rework that touches a file outside the TDD's
declared `## Touched files` set is structural") depends on correctly parsing the
declared set out of the TDD. Today three readers parse the declared-scope
sections and they DISAGREE:

- `_rework_file_declared_bound` (gates.sh) parses `## Expected diff size` by
  splitting each `- ` bullet on the em-dash (`—`), taking the left side, and
  stripping backticks — so it tolerates BOTH `` - `path` — … `` and
  `- path — …`.
- `_rework_touched_files` (gates.sh) parses `## Touched files` by taking the
  FIRST backtick-delimited token on each `- ` bullet — so a bullet that writes
  the path BARE and uses backticks only in its description (e.g.
  `- scripts/lib/gates.sh — \`coverage_map_block\`/…`) yields the DESCRIPTION
  token (`coverage_map_block`), not the path. The declared set becomes garbage
  and an in-scope rework edit fails the (a) membership check → a FALSE
  `structural-finding(a)` halt.
- `check_touched_file_count` (tdd-lint) only COUNTS `- ` bullets; it never
  extracts the path token, so it cannot detect the malformed-for-the-parser case
  at design time. A bare-path TDD passes the mechanical pre-pass and then false-
  halts at build-time rework.

This is not hypothetical: TDDs 0044–0047 were authored with bare paths (the form
the `/tdd-author` template example itself prescribes) and 0044 false-halted
`structural-finding(a) scripts/lib/gates.sh` on a rework whose edit was fully
in-scope (run 20260610-093522). The fix has three parts, all consistency-driven:
(1) make `_rework_touched_files` extract the path the SAME way
`_rework_file_declared_bound` does, so bare and backticked both parse; (2) teach
`tdd-lint` to validate that each touched-file bullet yields a non-empty
extractable path, so design-time agrees with build-time; (3) align the
`/tdd-author` template example to the canonical backticked form (the parser still
tolerates bare).

This directly applies learning **L-003 (tdd-drift)**: a gates.sh parser that
diverges from its sibling extractor enables a bypass — here the divergence
produced a false halt rather than a green bypass, but the remedy is the same,
make the sibling parsers identical.

## Components & interfaces
### 1. `_rework_touched_files` — extract like its sibling — `scripts/lib/gates.sh`
Replace the first-backtick-token extraction with the SAME em-dash-split +
backtick-strip + trim logic `_rework_file_declared_bound` already uses, so the
two functions extract a path identically. The new per-bullet awk body (run only
inside the fence-aware `## Touched files` section, unchanged):

```
in_sec && !in_fence && /^- / {
  rest = substr($0, 3)                       # drop "- "
  em = index(rest, "—")                      # em-dash separates path from purpose
  if (em > 0) { file = substr(rest, 1, em - 1) }
  else        { file = rest; sub(/[[:space:]].*/, "", file) }  # no em-dash: first token
  gsub(/`/, "", file)                        # strip backticks if the path was quoted
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", file)
  if (file != "") print file                 # skip a bullet with no extractable path
}
```

Behavior: `` - `scripts/lib/gates.sh` — desc `` → `scripts/lib/gates.sh`;
`- scripts/lib/gates.sh — \`x\`/\`y\`` → `scripts/lib/gates.sh` (no longer the
description token); `- scripts/foo.sh trailing words` (no em-dash) →
`scripts/foo.sh`. An empty extraction is dropped (not emitted as a blank line that
would pollute the membership set). The fence/section guards are unchanged.

### 2. Touched-file path extractability check — `scripts/lib/tdd-lint.sh`
Factor the per-bullet path extraction into a sourceable helper
`_tl_extract_touched_paths <tdd>` that emits one extracted path per
`## Touched files` bullet using the IDENTICAL em-dash-split + backtick-strip +
trim logic as Component 1 (fence/section-aware), dropping empties. Have
`check_touched_file_count` consume it so that, in addition to counting bullets, it
flags any bullet whose extracted path is empty: the bash wrapper emits one
`PRECHECK_FAIL: touched-files-malformed <bullet>` per offending bullet (the
`<bullet>` excerpt, truncated to its first 60 chars for a readable diagnostic) and
returns non-zero, so the design-critique gate's mechanical pre-pass (FR-51)
refuses a TDD whose touched-files section cannot be parsed into a scope set — the
same defect that previously slipped to build time. A bare-but-extractable path
does NOT fail (the parser tolerates it); only a bullet yielding no path fails. The
count check and its `touched-files <n> > <max>` PRECHECK are unchanged.

Exposing the extraction as a named helper (rather than inlining it in the count
awk) is what makes the Verification §2 cross-check implementable: `tdd-lint.sh` is
already sourceable (its `[ "${BASH_SOURCE[0]:-$0}" = "$0" ]` entry guard), so a
test can source it and call `_tl_extract_touched_paths` directly and diff its
output against `_rework_touched_files` on the same fixture.

### 3. Template example → canonical backticked form — `skills/tdd-author/SKILL.md`
The `## Touched files` template guidance currently shows the form as
`- <path> — <one-line purpose>` (bare). Update the example to the canonical
backticked form `` - `<path>` — <one-line purpose> `` (matching every existing
TDD), and add a one-line note that the path may be backticked or bare — both
parse — with backticks preferred for rendering. This nudges future authors to the
form the whole corpus uses without making bare a lint failure.

## Data & state
No persistent state, no schema change. All three changes are pure parse/validation
logic over existing TDD-document sections. The FR-67(a) check's INPUT (the
declared set) is computed more correctly; its contract (a diff file outside the
declared set is structural) is unchanged.

## Sequencing / implementation plan
1. Rewrite `_rework_touched_files`'s per-bullet extraction in `scripts/lib/gates.sh`
   to the em-dash-split + backtick-strip + trim logic (Component 1).
2. Extend `check_touched_file_count` in `scripts/lib/tdd-lint.sh` with the
   path-extractability validation emitting `touched-files-malformed` (Component 2).
3. Update the `## Touched files` template example + add the both-parse note in
   `skills/tdd-author/SKILL.md` (Component 3).
4. Add `_rework_touched_files` extraction cases to `tests/bounded-rework-loop.test.sh`
   (bare, backticked, description-backticks-only, no-em-dash, malformed) and an
   (a)-membership case proving a bare-path declared file is in-scope. ALSO update
   the existing `mk_rework_repo` fixture's first bullet from
   `` - `src/a.txt` (post) — the in-scope file `` to
   `` - `src/a.txt` — (post) the in-scope file `` (move the `(post)` annotation
   AFTER the em-dash): under the new em-dash-split parser the old form extracts
   `src/a.txt (post)` (the `(post)` sits between the backtick and the em-dash),
   which would break the existing C2–C7 cases that expect `src/a.txt` — the only
   pre-existing fixture affected by the parser change.
5. Add tdd-lint cases to `tests/bounded-tdd-scope.test.sh`
   (`touched-files-malformed` fires on an unextractable bullet; does NOT fire on a
   bare-but-extractable path). Add the parser-agreement cross-check: source
   `gates.sh` (via `THROUGHLINE_SOURCE_ONLY=1`) AND `tdd-lint.sh` (sourceable) in
   one subshell, run `_rework_touched_files` and `_tl_extract_touched_paths` on the
   same fixture, and assert their output is identical.

## Failure modes & edge cases
- **A bullet legitimately has no path** (a stray `- ` note in the section). The
  extraction yields empty; Component 1 drops it from the set, and Component 2
  flags it `touched-files-malformed` so the author fixes the section — neither
  silently admits a blank into the membership set nor lets the section through.
- **A path containing a literal em-dash.** Source paths do not contain `—`
  (U+2014); the sibling `_rework_file_declared_bound` already relies on this, so
  Component 1 inherits the same safe assumption (consistency, not a new risk).
- **The two extractors drift again later.** Component 1 and Component 2 use
  textually identical extraction logic; the Verification cross-check (below)
  asserts they agree on the same fixture, so a future one-sided edit is caught by
  the eval rather than re-surfacing as a build-time false halt.
- **An existing test fixture mis-parses under the new logic.** The current
  `mk_rework_repo` fixture in `tests/bounded-rework-loop.test.sh` writes
  `` - `src/a.txt` (post) — … ``; the `(post)` annotation sits between the
  backtick and the em-dash, so the new em-dash-split parser extracts
  `src/a.txt (post)` and breaks the existing C2–C7 cases (they expect `src/a.txt`).
  Sequencing step 4 updates that fixture (moves `(post)` after the em-dash) IN
  THE SAME change — it is the one pre-existing fixture the parser change touches.
- **L-001 / L-002 (test robustness).** The new eval assertions are positive
  (extracted output equals the expected path; the PRECHECK token is present).
  Any grep used distinguishes exit 1 (absent) from exit ≥2 (error/unreadable) and
  guards fixture readability, so an infra failure cannot read as a content pass
  or a misleading content `bad()`.
- **0047 also edits `skills/tdd-author/SKILL.md`.** 0047 (red-team ranking) and
  0048 touch DIFFERENT regions (0047 adds a red-team bullet; 0048 edits the
  Touched-files template line); 0048 builds after 0047 lands. No region overlap.

## Verification plan
- **Observable surface:** (a) `_rework_touched_files`'s stdout (the extracted
  declared-path set); (b) `tdd-lint.sh`'s `PRECHECK_FAIL:` lines + exit code; (c)
  the `_rework_pre_pass` (a)-membership outcome for an in-scope edit.
- **Observation points** (mechanical, in the two named test files; Component 1
  cases source `gates.sh` via `THROUGHLINE_SOURCE_ONLY=1` as the existing
  bounded-rework cases do, Component 2 PRECHECK cases invoke `bash tdd-lint.sh
  --bounds <f>` as a subprocess as the existing bounded-tdd-scope cases do, and the
  cross-check sources BOTH libs in one subshell):
  1. Feed `_rework_touched_files` a fixture TDD whose `## Touched files` bullets
     are: one backticked path with backticked words in its description; one BARE
     path with backticked words in its description; one bare path with NO em-dash;
     one `- ` bullet with no extractable path.
  2. Run `check_touched_file_count` (via the tdd-lint entry) on the same fixture
     and on a clean all-backticked fixture.
  3. Drive `_rework_pre_pass` with a rework diff touching a file that is declared
     with a BARE path, against that TDD.
- **Expected observations (PASS):**
  - §1: the extractor emits exactly the three real paths (backticked, bare-with-
    description-backticks, bare-no-em-dash) and DROPS the no-path bullet — in
    particular the bare-with-description-backticks bullet yields the PATH, not the
    first description backtick (the 0044 regression).
  - §2: `tdd-lint` emits `PRECHECK_FAIL: touched-files-malformed …` for the
    no-path bullet and exits non-zero; it emits NO `touched-files-malformed` for a
    bare-but-extractable path and (on the clean fixture) exits zero.
  - §2 cross-check: `_tl_extract_touched_paths` (tdd-lint) and
    `_rework_touched_files` (gates.sh), called on the SAME fixture in one subshell
    that sources both libs, emit byte-identical output (the two parsers agree —
    the durable guard against a future one-sided edit re-introducing the drift).
  - §3: the (a)-membership check does NOT fire `structural-finding(a)` for the
    in-scope edit to the bare-path-declared file (the original false halt is gone).

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | FR-67(a)/FR-53/FR-54 each map to a named element (parser fn, lint check) | all mapped, terse | an FR untraced |
| Parser-consistency | `_rework_touched_files` provably matches `_rework_file_declared_bound`'s extraction (em-dash split + backtick-strip); cites both | matches in effect | a third, divergent parse |
| Interface concreteness | exact fn names, the lint check + PRECHECK token, the malformed-vs-bare distinction stated | mostly concrete | "make it tolerant" with no rule |
| Verification actionability | observable surface + observation points + expected obs named (bare/backticked/malformed cases) | present | vague verb |
| Test robustness (L-001/L-002) | eval grep asserts fail closed on exit ≥2 + guard infra | present | unguarded inversion |
| Scope-bound adherence | within bounds; estimates padded per the underestimation lesson | within bounds | blows a bound silently |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-67 (a) (touch-outside-declared-set is structural) | Component 1 makes the declared set correctly parsed from `## Touched files` (bare or backticked), so the membership check no longer false-fires on an in-scope edit; Verification §3 |
| FR-53 (declared scope is a falsifiable design input) | Component 2 validates at design time that `## Touched files` yields a parseable path set, so the bound is well-defined before build; Verification §2 |
| FR-54 (design-time refusal of the predictable) | Component 2's `touched-files-malformed` PRECHECK refuses an unparseable touched-files section at the mechanical pre-pass rather than discovering it as a build-time false halt; Verification §2 |

No gaps. FR-67 criteria (b)/(c) and the rework loop itself are untouched; only the
(a)-input parsing is made correct and consistent.

## Dependencies considered
No new dependency — `awk`/`grep` are already used by both files. Alternatives:
- **A single shared awk helper sourced by both `gates.sh` and `tdd-lint.sh`**
  (rejected: the two libs are sourced independently in different contexts —
  including the `THROUGHLINE_SOURCE_ONLY` test path — and a shared snippet crosses
  that boundary for a ~10-line function; textual identity plus the Verification
  cross-check that asserts the two agree is sufficient and far less invasive).
- **Lint-enforce backticked paths only (no parser change)** (rejected by the
  operator: it punishes the bare form the `/tdd-author` template historically
  prescribed and would re-break any already-merged bare-path draft; making the
  parser tolerant is the correctness fix, with lint as a malformed-only backstop).

## PRD conflicts surfaced (and resolution)
None. This is a robustness gap-closure on FR-67(a)'s existing implementation; no
requirement is contradicted. It resolves the false-`structural-finding(a)` class
recorded for TDD 0044 in `docs/tdd/BLOCKERS.md` (2026-06-10) — that entry is
already checked off by the per-TDD backtick fix; 0048 removes the underlying cause
so the class cannot recur for a bare-path TDD.

## Decisions to promote (ADR candidates)
None. No durable cross-cutting decision is added — this is an implementation-
consistency fix to an existing FR's parsing, fully consistent with ADR 0005
(scope enforced by downstream detection: 0048 makes that detection's input
parsing correct) and ADR 0006.

## Touched files
- `scripts/lib/gates.sh` — rewrite `_rework_touched_files`'s per-bullet extraction to the em-dash-split + backtick-strip + trim logic (match `_rework_file_declared_bound`).
- `scripts/lib/tdd-lint.sh` — extend `check_touched_file_count` to flag `touched-files-malformed` for a bullet yielding no extractable path.
- `skills/tdd-author/SKILL.md` — template example → canonical backticked form + a one-line "both parse" note.
- `tests/bounded-rework-loop.test.sh` — `_rework_touched_files` extraction cases (bare / backticked / description-backticks-only / no-em-dash / malformed) + a bare-path (a)-membership case.
- `tests/bounded-tdd-scope.test.sh` — tdd-lint `touched-files-malformed` cases + the lint↔parser agreement cross-check.
- `tests/bounded-rework-convergence.test.sh` — conform the `mk_pp_repo` fixture's `## Touched files` bullet to the canonical path-before-em-dash form (same one-line fix already applied to `mk_rework_repo`), so the new em-dash-split parser reads `src/a.txt` rather than `src/a.txt (post)`.

## Expected diff size
- `scripts/lib/gates.sh` — 25 lines (replace the one-line match with the ~12-line extraction block + comments).
- `scripts/lib/tdd-lint.sh` — 45 lines (the `_tl_extract_touched_paths` helper + `check_touched_file_count` consuming it + the malformed PRECHECK wrapper).
- `skills/tdd-author/SKILL.md` — 10 lines (template example + note).
- `tests/bounded-rework-loop.test.sh` — 70 lines (five extraction cases + the membership case + the one-line `mk_rework_repo` fixture fix, sharing one fixture builder).
- `tests/bounded-tdd-scope.test.sh` — 95 lines (malformed + bare-ok lint cases + the dual-sourced parser-agreement cross-check, sharing one fixture).
- `tests/bounded-rework-convergence.test.sh` — 1 line (the `mk_pp_repo` fixture conforming edit).
Total expected diff: ~246 lines across 6 files. No exceptions needed (each file is well under the 300-line per-file cap; estimates padded per the systematic underestimation lesson).

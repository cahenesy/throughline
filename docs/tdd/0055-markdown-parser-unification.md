# TDD 0055: Markdown section/bullet parser unification (scripts/lib/md.sh)
Status: implemented
PRD refs: FR-53 (Touched files / Expected diff parsing); FR-54 (per-file diff bound); FR-67 (structural-finding scope); FR-69 (self-compliance with Theme A)
PRD-rev: 0aa1e28
ADR constraints: 0006

## Approach
Two families of markdown-structure parser are still duplicated across the runner's
shell libs, each a divergence risk and each carrying a folded bug:

- **Section-body scan (reuse #11).** A fence-aware `^## <heading>` … `^## ` walk is
  copy-pasted 4× (`tdd-lint.sh:99-105`, `tdd-lint.sh:289-295`, `gates.sh:1938-1944`,
  `plan-classifier.sh:~39`). The plan-classifier copy is the **one that is NOT
  fence-aware** (no `in_fence` tracking): a fenced `## Verification plan` example
  inside another section leaks into its keyword scan and can mis-route the build's
  model (real bug, the #11 anchor). The copies also honor only ` ``` ` fences, not
  `~~~` (**bug A21**) — a `~~~`-fenced block is mis-parsed by every copy.
- **Bullet path extract (reuse #12).** TDD 0049 unified the two `## Touched files`
  path extractors into `touched-files.sh:tl_extract_touched_paths`, but the
  IDENTICAL em-dash-split extractor for `## Expected diff size`
  (`gates.sh:_rework_file_declared_bound`, `tdd-lint.sh:check_per_file_diff_bound`)
  was left duplicated — and `## Expected diff size` has **no** cross-check guard
  (unlike `## Touched files`), so a one-sided edit silently re-opens the 0044
  false-`structural-finding(a)` drift on the diff-bound path. Two more folded bugs
  live here: `tl_extract_touched_paths`'s awk has **no exit-code check** so a silent
  awk failure emits an empty declared set → spurious `structural-finding(a)` for
  every changed file (**L-005 / swallowed-stderr**); and `check_touched_file_count`
  COUNTS bullets with `/^- [^[:space:]]/` while the extractor matches `/^- /`, so
  count and extraction disagree on the bullet anchor (**bug A23**).

This TDD creates **one `scripts/lib/md.sh`** owning both parsers and routes every
caller (including 0049's `tl_extract_touched_paths`) through it — a single source
of truth for markdown-structure parsing. It folds reuse #11/#12 and bugs A4, A21,
A23, L-005.

**Build ordering (declared dependency).** 0055 builds LAST: after 0049's
implementation merges (it delegates `tl_extract_touched_paths`, which lands with
0049 / PR #142) AND after the 0050–0054 stack (it shares `gates.sh` and
`tdd-lint.sh` with 0050/0053). Nothing stacks on 0055.

## Components & interfaces
**New — `scripts/lib/md.sh`** (side-effect-free, idempotently sourceable, include
guard `_TL_MD_SOURCED`, dependency-free per the 0049 sourcing pattern):
```
md_section_body <file> <heading>
    Emit, one per line, the RAW in-section lines of the `^## <heading>` section,
    fence-aware: a line toggling a ``` OR ~~~ fence is a fence boundary (and is NOT
    emitted as a section line), so a fenced example inside the section is excluded.
    Heading match is `^## <heading>` (optional trailing ws). awk's exit code is
    CHECKED: a non-zero awk returns 2 and prints a stderr diagnostic (never a silent
    empty body). The caller layers its own predicate (classify/rows/columns) on the
    emitted stream — this helper unifies ONLY the fence/section-boundary walk.
md_bullet_path_of_line <bullet-line>
    The SHARED per-bullet PATH extractor: given ONE `- ` bullet line, echo its path
    via 0049's annotation-robust algorithm (leading backtick-quoted token else first
    whitespace token, em-dash split) or empty for a no-path bullet. Pure string op,
    no file/awk — this is the one definition of "the path of a bullet" that BOTH the
    paths-list (md_bullet_path) AND the annotation-bearing `## Expected diff size`
    callers reuse (resolving the #12 divergence at the path-isolation layer, while
    each caller keeps its own count/exception parsing).
md_bullet_path <file> <heading> [mode]
    Emit one declared path per `- ` bullet of the (fence-aware, ```+~~~) `^## <heading>`
    section: it is `md_section_body <file> <heading>` filtered to `/^- /` lines, each
    run through `md_bullet_path_of_line`. mode=paths (default) | malformed (60-char
    excerpt of a no-path bullet). The bullet anchor is `/^- /` (single canonical
    anchor — A23). awk's exit code is CHECKED (L-005): a non-zero awk in the
    underlying md_section_body → return 2 + stderr diagnostic, NOT a silent empty list.
```

**rc propagation (the L-005 fix is end-to-end, not just at md.sh).** A non-zero rc
from `md_bullet_path` MUST reach the membership check, or the false
`structural-finding(a)` persists. Each delegation layer propagates it, and — because
`local x="$(cmd)"` masks the command's rc behind `local`'s own rc — every capture
site uses split declaration: `local set; set="$(...)"; rc=$?`. The chain:
`md_bullet_path` (rc 2) → `tl_extract_touched_paths` (returns it) →
`_rework_touched_files` / `_tl_extract_touched_paths` (return it) → `_rework_pre_pass`,
which captures `set_list="$(_rework_touched_files "$tdd")"; rc=$?` and, on rc 2,
takes a **parse-error** path (a distinct diagnostic / blocked cause), NEVER the
empty-set → `structural-finding(a)` path. Verification §4 asserts the rc reaches
`_rework_pre_pass` and routes away from structural-finding(a).

**The parse-error path is a FIRST-CLASS dispatch arm, not a fall-through**
(pinned 2026-06-11 after the review:1 finding "parsefail PRECHECK_FAIL type has
no dispatch arm"): the `PRECHECK_FAIL: parse-failed …` emission from
`_rework_pre_pass` gets its OWN arm in the escalation dispatch — its operator
guidance is "the touched-files declaration could not be PARSED (awk failed);
inspect the parse environment / the TDD's `## Touched files` section", NOT the
structural-finding "revise the TDD's declared scope via /tdd-author" guidance,
and never the generic `structural-finding (?)` fall-through. The parse-failed
diagnostic must also state that BOTH FR-67(a) membership AND FR-67(b) per-file
bounds were skipped for the attempt (a parse failure suspends the whole declared-
scope evaluation, not just (a)). Additionally, `gates.sh` sources `md.sh`
DIRECTLY (its own sibling-source block), not transitively via `touched-files.sh`
— every md.sh consumer owns its source line (the 0050 consumer-sources-it rule).
**Migrations (each becomes a thin caller of md.sh):**
- `touched-files.sh:tl_extract_touched_paths` → `md_bullet_path "$f" "Touched files" "$mode"`.
  Name/signature/output unchanged; the 0049 3-way agreement cross-check still passes.
  This also fixes L-005 for the `## Touched files` path (the rc check now applies).
- `plan-classifier.sh` section scan → `md_section_body "$f" "Verification plan"`,
  then its existing keyword-classify predicate on the emitted body. Gains
  fence-awareness (the #11 misroute fix); its current standalone awk-rc handling is
  subsumed by md_section_body's.
- `tdd-lint.sh`: the two `Requirement traceability` section scans AND
  `check_touched_file_count`'s OWN fence walk → `md_section_body` (so count and
  extract share ONE fence behavior, incl `~~~` — closes the residual
  count-vs-extract `~~~` divergence, MINOR-1); `check_touched_file_count`'s bullet
  recognition re-anchored to `/^- /` to match `md_bullet_path` (**A23**);
  `check_per_file_diff_bound` walks `md_section_body "$f" "Expected diff size"` and,
  per `/^- /` line, takes the path from `md_bullet_path_of_line` and parses
  count/`(exception:…)` caller-side (the count/exc logic stays here; only the
  fence walk + path isolation are shared). The **A4** fix is a TARGETED,
  refactor-independent sentinel change to that caller-side comparison awk: the
  missing-`## Expected diff size` signal moves OFF `exit 2` (which gawk also uses for
  a FATAL) to a distinct `exit 3`, and the guard becomes
  `awk_rc -ge 2 && awk_rc != 3 → real crash` — so a gawk fatal is no longer silently
  read as "missing section". (Applied first, then the fence-walk delegation, so the
  two changes don't entangle.)
- `gates.sh`: `_coverage_inscope_reqs` section scan (1938-1944) → `md_section_body`,
  **preserving its advisory silent-fail contract** — this is the FR-78 coverage map
  (REPORTED, advisory, not a gate), so it intentionally ignores `md_section_body`'s
  rc and yields empty on a parse failure (its `2>/dev/null` / rc-0-on-failure
  behavior is kept; the L-005 rc-propagation above applies only to the
  structural-finding membership path, not this advisory reader);
  `_rework_file_declared_bound` walks `md_section_body "$f" "Expected diff size"` and
  takes each bullet's path from `md_bullet_path_of_line`, keeping its (n, exc)
  return caller-side.

**Sourcing.** Each caller sources md.sh by its sibling path with the FATAL-on-missing
+ dual `return||exit` idiom 0049/0050 established; `${BASH_SOURCE[0]%/*}` (no dirname)
keeps plan-classifier/markers-style minimal-host callers safe.

## Data & state
No persisted state, no schema change. Pure functions: file + heading → in-section
lines / declared paths on stdout. `_TL_MD_SOURCED` is process-local. The behavioral
changes are intended fixes only: fenced/`~~~` content correctly excluded; a parse
failure surfaces (rc 2 + stderr) instead of an empty result; count/extract share one
anchor; gawk-fatal no longer reads as missing-section.

## Sequencing / implementation plan
1. Create `scripts/lib/md.sh`: guard + `md_bullet_path_of_line` (shared per-bullet
   path op) + `md_section_body` (fence-aware ```+~~~, rc-checked) + `md_bullet_path`
   (md_section_body | `/^- /` | md_bullet_path_of_line; rc-propagating).
2. Wire `scripts/lib/touched-files.sh`: `tl_extract_touched_paths` → `md_bullet_path`
   delegate, PROPAGATING rc (split-declare to dodge the `local x=$()` rc mask).
3. Wire `scripts/lib/plan-classifier.sh`: section scan → `md_section_body` (fence fix).
4. Wire `scripts/lib/tdd-lint.sh`: the 2 traceability section scans AND
   `check_touched_file_count`'s fence walk → `md_section_body`; re-anchor the count to
   `/^- /` (A23); A4 sentinel fix to `check_per_file_diff_bound`'s comparison awk FIRST,
   then route its path isolation through `md_bullet_path_of_line` (count/exc caller-side).
5. Wire `scripts/lib/gates.sh`: `_coverage_inscope_reqs` section scan → `md_section_body`
   (advisory, rc ignored); `_rework_file_declared_bound` path → `md_bullet_path_of_line`;
   propagate rc on the `_rework_touched_files` → `_rework_pre_pass` membership path.
6. Add `tests/md-parser.test.sh` (section fence ```+~~~, bullet extraction, awk-rc,
   malformed, A23 anchor, A4 exit-code) + register in `tests/implement-gate.test.sh`;
   extend `tests/bounded-tdd-scope.test.sh` to keep the 0049 3-way agreement green
   through the delegate and add the plan-classifier fence-misroute regression.

## Failure modes & edge cases
**Real risks.**
- *A caller's in-section predicate changes.* md_section_body emits raw lines only;
  each caller keeps its own classify/row/column logic. Mitigated by Verification §2
  (per-caller behavior asserted unchanged on a fixture).
- *Honoring `~~~` breaks a TDD using `~~~` as content.* The current ```-only parsers
  already mis-handle `~~~`; honoring it is the fix. Mitigated by a `~~~`-fence
  regression (Verification §1) and the fact that TDD bodies use ``` for examples.
- *The touched-files delegate changes output / breaks 0049's cross-check.*
  `tl_extract_touched_paths` keeps name/signature/output; Verification §3 re-runs the
  0049 3-way agreement.

**Overblown risks.**
- *A4 sentinel change cascades.* The missing-section signal is internal to
  `check_per_file_diff_bound`; moving it 2→3 is local and covered by its own eval.

**Unspoken risks (elephants).**
- *md_bullet_path's rc check (L-005) now FAILS builds that previously passed on a
  silently-empty parse.* That is the point — a silent awk failure was producing a
  FALSE structural-finding(a); now it surfaces honestly. But if awk fails for a
  benign reason on some host, a previously-(wrongly)-passing path now errors. The rc
  path returns a DISTINCT diagnostic (not a structural-finding), so the operator sees
  "parse failed", not "out of scope" — Verification §4 asserts the two are
  distinguishable, so the fix can't itself masquerade as the bug it removes.

## Verification plan
- **Observable surface:** (a) `md_section_body` / `md_bullet_path` stdout + exit code;
  (b) each migrated caller's existing output (classifier verdict, lint PRECHECK lines,
  the structural-finding(a) membership outcome); (c) the 0049 3-way agreement result.
- **Observation points (mechanical, `tests/md-parser.test.sh` + the existing
  plan-classifier / bounded-tdd-scope / bounded-rework evals; libs sourced via the
  existing harness):**
  1. Feed `md_section_body` a fixture with a `## X` section containing a ` ``` `-fenced
     AND a `~~~`-fenced `## Y`-looking example line → assert the fenced lines are
     excluded (A21); feed plan-classifier a `## Verification plan` whose body has a
     fenced `## …` example → assert no misroute (the #11 fix).
  2. For each migrated caller, run it on a fixture and assert its output is identical
     to the pre-migration behavior on the non-fenced case (predicate preserved).
  3. Re-run the 0049 `[bounds-parser-agreement]` 3-way cross-check through the
     delegate → still byte-identical.
  4. **L-005 (end-to-end rc propagation):** stub awk to exit non-zero so
     `md_bullet_path` returns 2; assert the rc PROPAGATES through
     `tl_extract_touched_paths` → `_rework_touched_files` → `_rework_pre_pass` (verify
     each layer's split-declared capture does not mask it) and that `_rework_pre_pass`
     takes the parse-error path (a distinct diagnostic / blocked cause) and does NOT
     emit `structural-finding(a)`. Control: a genuinely empty (but cleanly-parsed)
     `## Touched files` still yields the normal empty-set behavior, NOT the parse-error
     path — so rc=2 (parse fail) and rc=0+empty (no bullets) are distinguishable.
  5. **A23:** a fixture whose `## Touched files` bullet anchor differs (`- x` vs `-  x`)
     → assert `check_touched_file_count` and `md_bullet_path` agree on what is a bullet.
  6. **A4:** stub awk to a gawk-style FATAL (exit 2) inside `check_per_file_diff_bound`
     → assert it is reported as a crash (rc 2 + diagnostic), NOT silently read as
     "missing section"; and a genuine missing `## Expected diff size` still emits its
     PRECHECK.
- **Expected observations (PASS):** each lettered/numbered case holds; every folded
  bug's regression FAILS against the pre-fix code and PASSES post-fix.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement + folded-bug traceability | Reuse #11/#12 AND each folded bug (A4/A21/A23/L-005) map to a named design element | All mapped | Any untraced |
| Folded-bug regression coverage | Each folded bug has a fail-pre/pass-post observation (plan-classifier fence misroute, ~~~ fence, gawk exit-2, awk-rc, anchor) | Each has a regression check | A folded bug has no regression |
| Single-source-of-truth | Exactly one md_section_body + one md_bullet_path; all 4 section + 2 bullet sites + the touched-files delegate verified | Callers delegate; one definition each | A divergent copy remains |
| Caller-predicate preservation | Each caller's in-section logic (classify/rows/columns) provably unchanged; helper unifies only the fence/section walk | Predicate behavior named as preserved | A caller's behavior silently changed |
| Sourcing + back-compat | md.sh sources cleanly in all contexts; 0049 3-way agreement cross-check still passes; callers/tests unbroken | Sourcing + guard specified | A context unhandled or 0049 cross-check broken |
| Verification-plan actionability | Observable surface + exact points + expected values | Surface + points named | placeholder/vague |

## Requirement traceability
| Requirement / bug | Design element |
|---|---|
| FR-53 (Touched/Expected parsing) | one `md_bullet_path` parses both sections; `tl_extract_touched_paths` delegates |
| FR-54 (per-file diff bound) | `check_per_file_diff_bound` walks `md_section_body` + isolates each path via `md_bullet_path_of_line` (count/exc caller-side); A4 exit-code fix keeps the bound check honest |
| FR-67 (structural-finding scope) | L-005 rc check stops a silent parse failure from emitting a false `structural-finding(a)` |
| FR-69 (self-compliance with Theme A) | retires 4 section + 2 bullet duplicated parsers into one `md.sh` |
| ADR 0006 (artifacts grounded) | a parse failure surfaces (rc 2 + stderr), never a silent empty result that a gate would misread |
| reuse #11 / #12 | `md_section_body` single-sources the section walk; `md_bullet_path_of_line` single-sources the per-bullet path op used by `md_bullet_path` AND the Expected-diff callers |
| bug A4 | exit-code collision (gawk fatal 2 vs missing-section 2) split to a distinct sentinel (targeted, refactor-independent); Verification §6 |
| bug A21 | fence walk honors ``` AND ~~~; Verification §1 |
| bug A23 | single `/^- /` bullet anchor shared by count + extract; Verification §5 |
| bug L-005 | `md_bullet_path` checks awk's exit code AND the rc propagates end-to-end through the delegation wrappers to `_rework_pre_pass` (split-declared captures), which routes rc=2 to a parse-error path, never `structural-finding(a)`; Verification §4 |

No gaps.

## Dependencies considered
No new external dependency — pure bash/awk, NO jq, no dirname (minimal-host-safe,
matching 0049/0050). Chosen: one `md.sh`. Rejected alternatives:
- **The findings' two-home split** (new `md-section.sh` for #11 + extend
  `touched-files.sh` for #12) — rejected: it keeps section vs bullet parsing in two
  libs and re-creates the very fragmentation being collapsed; one `md.sh` is the
  single source.
- **Leave `## Expected diff size` on its own copy, only unify the section scan** —
  rejected: the Expected-diff extractor is byte-identical to the Touched-files one
  and has NO cross-check, so it is exactly where the 0044 drift silently re-opens.

## PRD conflicts surfaced (and resolution)
None. Hardens the existing FR-53/54/67 parsing mechanism; no new requirement, no ADR
reversed. Folds the L-005 learning 0049 shipped (the awk-rc check) into the single
extractor rather than patching it in place.

## Decisions to promote (ADR candidates)
None. A shared pure-bash markdown helper is a localized choice; ADR 0006 governs.

## Touched files
- `scripts/lib/md.sh` — NEW: guard + `md_bullet_path_of_line` (shared per-bullet path op) + `md_section_body` (fence-aware ```+~~~, rc-checked) + `md_bullet_path` (md_section_body | `/^- /` | md_bullet_path_of_line; rc-propagating).
- `scripts/lib/touched-files.sh` — `tl_extract_touched_paths` → `md_bullet_path` delegate (folds L-005 for Touched files).
- `scripts/lib/plan-classifier.sh` — section scan → `md_section_body` (fence-aware fix, reuse #11).
- `scripts/lib/tdd-lint.sh` — 2 section scans → `md_section_body`; `check_per_file_diff_bound` path → `md_bullet_path`; re-anchor `check_touched_file_count` (A23); A4 exit-code split.
- `scripts/lib/gates.sh` — section scan → `md_section_body`; `_rework_file_declared_bound` path → `md_bullet_path` (reuse #12).
- `tests/md-parser.test.sh` — NEW unit + A4/A21/A23/L-005 + plan-classifier-fence regressions.
- `tests/bounded-tdd-scope.test.sh` — keep the 0049 3-way agreement green through the delegate + the count/extract anchor case.
- `tests/implement-gate.test.sh` — register the new eval.
- `.claude-plugin/plugin.json` — version bump (build-applied housekeeping).

## Expected diff size
(Reconciled 2026-06-11 to the OBSERVED build sizes after the review:1
structural-finding(b) halt — the original first-instinct estimates ran 2–3× low
across the board (the systematic under-count), and the bounded rework's in-scope
fix to the `parsefail` dispatch arm was rejected against the stale gates.sh
bound. Numbers below = observed build diff + rework headroom, per the 0044
reconciliation precedent.)
- `scripts/lib/md.sh` — 130 lines (observed 107: guard + `md_bullet_path_of_line` + 2 rc-checked awk functions + comments).
- `scripts/lib/touched-files.sh` — 75 lines (observed 61: body → delegate + rc-propagating split-declare).
- `scripts/lib/plan-classifier.sh` — 60 lines (observed 50: section scan → delegate).
- `scripts/lib/tdd-lint.sh` — 185 lines (observed 164: 2 traceability scans + count fence walk → md_section_body; A23 re-anchor; A4 sentinel; per-line path via md_bullet_path_of_line).
- `scripts/lib/gates.sh` — 150 lines (observed 120 + headroom for the parsefail dispatch-arm rework: coverage section delegate + Expected-diff per-line path delegate + membership rc propagation + the parse-error halt arm).
- `tests/md-parser.test.sh` — 430 lines (exception: a single cohesive eval over the 300-line per-file cap — the section/bullet/fence/rc-propagation/anchor/exit-code cases share one harness and splitting would fragment the shared fixture setup; observed build size 415).
- `tests/bounded-tdd-scope.test.sh` — 45 lines (3-way agreement through delegate + count/extract anchor + ~~~ case).
- `tests/implement-gate.test.sh` — 15 lines (register).
- `.claude-plugin/plugin.json` — 2 lines (version bump).
Total expected diff: ~1090 lines across 9 files. One inline exception declared on `tests/md-parser.test.sh` (over the 300 per-file cap). The 9th file is the trivial build-applied version bump; it pushes the touched-file COUNT to 9 > the default `THROUGHLINE_TDD_MAX_TOUCHED`=8 (design-time `--bounds` only — the build does not re-check the count).

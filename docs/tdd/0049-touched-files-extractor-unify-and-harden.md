# TDD 0049: Touched-files path extractor — single source of truth + annotation-robust
Status: implemented
PRD refs: FR-67 (criterion (a) touched-file-set check); FR-53; FR-54
PRD-rev: 0aa1e28
ADR constraints: 0005, 0006

## Approach
TDD 0048 unified TWO of the three `## Touched files` readers
(`_rework_touched_files` in gates.sh and `_tl_extract_touched_paths` in
tdd-lint.sh) onto an em-dash-split extractor and added a byte-identical
cross-check. It left two gaps, both surfaced while landing 0048 (PR #139):

1. **The em-dash-split mis-parses an annotated path.** The 0048 rule takes
   *everything left of the em-dash* as the path. A bullet that writes an
   annotation between the path and the em-dash —
   `` - `src/a.txt` (post) — the in-scope file `` — yields `src/a.txt (post)`,
   so the FR-67(a) membership check no longer matches the real changed file
   `src/a.txt` → a FALSE `structural-finding(a)`. This is the same *class* of
   false-halt 0048 set out to remove, just a different surface form; it bit the
   `mk_pp_repo` fixture during the 0048 build and forced a manual fix-forward.

2. **A THIRD reader was never unified.** `_touched_files_of_tdd`
   (learnings.sh:~129) still uses the pre-0048 "first backtick-delimited token"
   logic, and its comment falsely claims parity with `_rework_touched_files`.
   It reads the same `## Touched files` section on the learning-aggregation path,
   so it can extract a description backtick as the "path" exactly as the original
   0044 footgun did. The 0048 cross-check does not cover it.

This TDD closes both. It does NOT supersede 0048 (the em-dash split stands as the
section grammar; 0048's body is the historical record of that unification) — it
**refines the extraction algorithm and widens it to all three readers**, in the
established repo pattern where a gap-closure extends rather than rewrites (0041
extended 0019, 0033 extended 0031).

The two changes are one coherent unit because they share the same parser trio and
the same fix: a single annotation-robust extractor that all three readers call.

**The extraction algorithm (refined).** Within each `- ` bullet of the
(fence-aware) `## Touched files` section, the path is found in the segment LEFT of
the em-dash (`—`, U+2014), or the whole bullet when there is no em-dash:
- if that segment contains a backtick-delimited token, the path is the FIRST such
  token (the quoted path);
- otherwise the path is the segment's FIRST whitespace-delimited token.
A bullet that yields no path is dropped (and, in `malformed` mode, reported).

This single rule subsumes every form 0048 handled AND the annotated form:

| Bullet | left-of-em-dash segment | extracted |
|---|---|---|
| `` - `path` — purpose `` | `` `path` `` | `path` |
| `- path — purpose` (bare) | `path ` | `path` |
| `` - `path` (post) — purpose `` (annotated) | `` `path` (post) `` | `path` |
| `- path (new) — purpose` (bare+annotated) | `path (new) ` | `path` |
| ``- scripts/lib/gates.sh — `coverage_map_block` `` (0044 case: bare path, backticked DESC) | `scripts/lib/gates.sh ` (no backtick) | `scripts/lib/gates.sh` |
| `- path` (no em-dash) | `path` | `path` |
| `- — a stray note` (no path) | `` (empty) | dropped |

The 0044 case still works because its backtick is in the DESCRIPTION (right of the
em-dash), so the path segment has none and the first-whitespace-token branch
applies — the prefer-backtick-*within-the-segment* rule is what makes this safe.

**Silent tolerance.** The annotated form is parsed correctly and nothing
complains (no new `PRECHECK_FAIL`, no advisory). The canonical
`` - `path` — purpose `` stays the documented norm in tdd-author; the parser is
simply tolerant. (Decision recorded in the design interview.)

## Components & interfaces
**New — `scripts/lib/touched-files.sh` (single source of truth).** A side-effect-free,
idempotently-sourceable library exposing exactly one extractor:

```
tl_extract_touched_paths <tdd-file> [mode]
    mode=paths (default) — emit each non-empty extracted path, one per line.
    mode=malformed       — emit the 60-char excerpt of each `- ` bullet whose
                           extracted path is empty (the no-path bullets).
    Returns 0 and emits nothing for a missing file (caller-friendly).
```

It carries an include guard so double-sourcing (gates.sh AND learnings.sh both
pull it under one implement.sh) is a no-op:

```
[ -n "${_TL_TOUCHED_FILES_SOURCED:-}" ] && return 0
_TL_TOUCHED_FILES_SOURCED=1
```

`_TL_TOUCHED_FILES_SOURCED` is the PERSISTENT guard and must NOT be unset (unlike
the `_tf_lib` scratch variable in the per-host sourcing block, which IS unset
after use) — unsetting it would defeat the no-op. The name is `_TL_`-prefixed to
sit in the same private namespace as tdd-lint's `_tl_*` helpers; implementation
greps gates.sh/learnings.sh/tdd-lint.sh to confirm no existing collision.

The awk body is the refined algorithm above, MODE-parameterized exactly as
tdd-lint's current `_tl_extract_touched_paths` is (so `check_touched_file_count`'s
`malformed` consumer is unchanged).

**The three readers become thin delegating wrappers** (names + signatures kept so
every existing caller and test is untouched):
- `_rework_touched_files <tdd-file>` (gates.sh) → `tl_extract_touched_paths "$1"`.
- `_tl_extract_touched_paths <tdd-file> [mode]` (tdd-lint.sh) →
  `tl_extract_touched_paths "$@"` (preserves the `malformed` mode
  `check_touched_file_count` calls at tdd-lint.sh:526).
- `_touched_files_of_tdd <mainrepo> <slug>` (learnings.sh) →
  `f="$1/docs/tdd/$2.md"; [ -f "$f" ] || return 0; tl_extract_touched_paths "$f"`
  — paths-only by intent (learnings never needs `malformed` mode, so unlike the
  tdd-lint wrapper it does not forward `"$@"`), and its false "mirrors
  `_rework_touched_files`" comment is corrected to "delegates to
  `tl_extract_touched_paths` (single source of truth)".

**Sourcing (the load-bearing detail of the shared-lib choice).** Each of the three
libs sources the shared lib by its SIBLING path, resolved from the sourcing file's
own location, with the FATAL-on-missing pattern implement.sh already uses for its
libs, and an idiom that works whether the host file is sourced or executed:

```
_tf_lib="${BASH_SOURCE[0]%/*}/touched-files.sh"
{ [ -r "$_tf_lib" ] && . "$_tf_lib"; } || {
  echo "FATAL: cannot source $_tf_lib (partial install or perms)" >&2
  return 1 2>/dev/null || exit 1
}
unset _tf_lib
```

`${BASH_SOURCE[0]%/*}` resolves to the host lib's directory in every sourcing
context this repo uses — implement.sh sources gates.sh/learnings.sh by ABSOLUTE
path (so `BASH_SOURCE[0]` is absolute), the evals source implement.sh via
`THROUGHLINE_SOURCE_ONLY=1` (same absolute path), and `bash scripts/lib/tdd-lint.sh`
runs tdd-lint.sh as `$0` with `BASH_SOURCE[0]` = its own path. The
`return 1 2>/dev/null || exit 1` is a SINGLE idiom that is correct in both
contexts, and the implementer must use it verbatim (do NOT substitute a bare
`exit` thinking tdd-lint.sh is "executed here"): bash permits `return` at the
top level of a *sourced* file, where it unwinds the `source`/`.` call (so a test
that `source`s tdd-lint.sh sees the source terminate, not the whole harness
exit); the `2>/dev/null || exit 1` then fires only in the EXECUTED context
(`bash tdd-lint.sh`), where a top-level `return` is an error. Either way a FATAL
diagnostic is printed first, so a missing/unreadable shared lib is never silent
(ADR 0006 spirit). This sourcing block runs at the TOP of each host file, before
tdd-lint.sh's own bottom-of-file `[ "${BASH_SOURCE[0]:-$0}" = "$0" ]` dispatch
guard — the two guards are independent and do not interact.

## Data & state
No persisted state. The extractor is a pure function of the TDD file's
`## Touched files` section text → a newline-delimited path list on stdout. No
run-state fragment, no draft, no config knob is read or written. The `_TL_TOUCHED_FILES_SOURCED`
guard is process-local shell state only.

## Sequencing / implementation plan
1. Create `scripts/lib/touched-files.sh`: header comment, include guard, and
   `tl_extract_touched_paths` with the refined annotation-robust, MODE-parameterized awk.
2. Wire `scripts/lib/gates.sh`: add the sibling-source block; replace
   `_rework_touched_files`'s awk body with the one-line delegation; update its
   doc comment to name the shared lib.
3. Wire `scripts/lib/tdd-lint.sh`: add the sibling-source block; replace
   `_tl_extract_touched_paths`'s awk body with `tl_extract_touched_paths "$@"`;
   update its doc comment. `check_touched_file_count` is unchanged.
4. Wire `scripts/lib/learnings.sh`: add the sibling-source block; replace
   `_touched_files_of_tdd`'s awk body with the path-build + delegation; correct
   the false-parity comment.
5. Extend `tests/bounded-tdd-scope.test.sh`: (a) promote the parser-agreement
   cross-check from two readers to all THREE public entrypoints (staging a
   `docs/tdd/<slug>.md` under a temp repo so the `<repo> <slug>`-signature
   `_touched_files_of_tdd` runs on the same fixture); (b) add direct
   `tl_extract_touched_paths` unit cases for the annotated, bare+annotated, and
   no-em-dash forms with their expected outputs; (c) a regression case asserting
   the annotated form does NOT trip `structural-finding(a)` through the gates.sh
   wrapper.

## Failure modes & edge cases
**Real risks.**
- *Sourcing breaks in one context.* If the sibling path or guard is wrong, a host
  lib fails to source → the runner FATALs (loud, not silent) per ADR 0006 spirit.
  Mitigated by `${BASH_SOURCE[0]%/*}` (host-relative, not cwd-relative) + the
  guard + the dual `return||exit`; pinned by Verification §3 across all four
  contexts.
- *A reader keeps its own copy.* If a future edit re-inlines a divergent awk into
  one reader, the single-source-of-truth is lost. Mitigated structurally (the
  wrappers hold no awk) and caught by the §5 agreement test (Verification §2).
- *Mode regression.* If the shared extractor drops the `malformed` mode,
  `check_touched_file_count`'s design-time malformed PRECHECK silently stops
  firing. Mitigated by keeping the MODE parameter identical and by the existing
  `bounds-touched-malformed` case (unchanged) plus Verification §4.

**Overblown risks.**
- *Double-sourcing redefining the function twice.* Harmless in bash (last
  definition wins, identical), but the include guard makes it a clean no-op
  anyway — not a correctness risk, only tidiness.
- *Annotated form now "blessed".* It is tolerated, not blessed; the canonical
  form remains the documented norm. No grammar is being widened in tdd-author.

**Unspoken risks (elephants).**
- *A FOURTH+ reader exists somewhere unsearched.* The whole point is to stop
  duplicating this parser. Verification §2's agreement test only guards the three
  known readers; a future fifth reader would not be auto-caught. Mitigation: the
  shared lib is now the obvious home, and step-4's comment fix removes the
  misleading "mirrors X" breadcrumb that invited copying. A repo-wide grep for
  `## Touched files`-parsing awk is part of Verification §2 to assert no other
  inlined copy exists at authoring time.

## Verification plan
- **Observable surface:** (a) `tl_extract_touched_paths` stdout (the extracted
  path list) and, through them, the three wrapper functions' stdout; (b) the
  `_rework_pre_pass` FR-67(a)-membership outcome (rc + `PRECHECK_FAIL` line) for an
  in-scope edit to an annotated-path-declared file; (c) successful sourcing (no
  FATAL) of each host lib in each context.
- **Observation points (mechanical, in `tests/bounded-tdd-scope.test.sh` unless
  noted; libs sourced via `THROUGHLINE_SOURCE_ONLY=1` / `bash tdd-lint.sh` as the
  existing cases do):**
  1. Feed `tl_extract_touched_paths` a fixture whose `## Touched files` bullets
     cover: backticked, bare, annotated (`` `p` (x) — ``), bare+annotated
     (`p (x) — `), bare-with-backticked-description (the 0044 case), no-em-dash,
     and a no-path stray bullet — in `paths` and `malformed` modes.
  2. Call all THREE public entrypoints (`_rework_touched_files`,
     `_tl_extract_touched_paths`, `_touched_files_of_tdd`) on ONE staged fixture
     (a `docs/tdd/9xxx.md` under a temp repo, so the `<repo> <slug>` signature
     resolves to it) and diff their outputs.
  3. Drive `_rework_pre_pass` with an in-scope rework edit to a file declared with
     the ANNOTATED form, against that TDD.
  4. Run `check_touched_file_count` (via `bash tdd-lint.sh --bounds`) on a no-path
     fixture and on a clean fixture.
  5. Source each host lib in each context: `THROUGHLINE_SOURCE_ONLY=1 source
     implement.sh` (brings gates.sh + learnings.sh), `source tdd-lint.sh`, and
     `bash tdd-lint.sh --bounds <clean>` standalone — assert no FATAL and the
     functions are defined.
- **Expected observations (PASS):**
  - §1: the extractor emits exactly the real paths — annotated and bare+annotated
    both yield the bare path (not `path (x)`); the 0044 bare-with-description case
    yields the path (not the description backtick); the no-path bullet is dropped
    in `paths` mode and reported in `malformed` mode.
  - §2: all three entrypoints emit byte-identical output (single source of truth);
    a repo-wide grep finds no other inlined `## Touched files` awk extractor
    outside `touched-files.sh`.
  - §3: `_rework_pre_pass` does NOT emit `structural-finding(a)` for the in-scope
    annotated-path edit and exits 0.
  - §4: `touched-files-malformed` fires (non-zero exit) for the no-path bullet and
    does NOT fire for the clean fixture (mode preserved).
  - §5: every context sources without FATAL and `tl_extract_touched_paths` plus the
    three wrappers are defined.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | Every FR-53/54/67 tie-in maps to a named design element | All in-scope reqs mapped | Any req untraced |
| Single-source-of-truth | Exactly one awk extractor exists; all 3 readers are verified-thin delegating wrappers | 3 readers delegate; one shared definition | A divergent copy remains inlined |
| Sourcing robustness | All 4 contexts (standalone tdd-lint, implement.sh abs-path, SOURCE_ONLY evals, double-source) + include-guard + FATAL-on-missing specified | Sibling-path + guard specified | Relative-source assumed; a context unhandled |
| Extraction-form coverage | bare / backticked / annotated / no-em-dash / no-path each named with expected output | The 3 new forms covered | An asserted form has no expected output |
| Verification-plan actionability | Observable surface + exact observation points + expected values, all concrete | Surface + points named | placeholder/vague |
| Scope-bound adherence | Inside all bounds, estimates padded per class bias | Inside bounds | A bound blown without exception |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-67(a) (touched-file-set membership check) | `tl_extract_touched_paths` feeds the same declared set to `_rework_pre_pass` via the `_rework_touched_files` wrapper; annotation-robustness removes the false (a)-halt (Components; Verification §3) |
| FR-53 (declared scope set is the bound input) | The single extractor is the one definition of "the declared touched-file set"; all three readers agree by construction (Components; Verification §2) |
| FR-54 (design-time refusal) | `check_touched_file_count`'s `malformed` PRECHECK preserved through the shared extractor's `malformed` mode (Verification §4) |
| ADR 0005 (gate scope via downstream detection) | The extractor serves the FR-67 structural detection; no scope check added to `/implement` |
| ADR 0006 (verdicts grounded in artifacts) | Sourcing failure FATALs loudly (no silent stranded reader); the malformed check stays mechanical |

No gaps: every in-scope requirement maps to a concrete element.

## Dependencies considered
No new external dependency. The change is a pure-bash/awk refactor using tools
already in use (awk, bash sourcing). The structural choice (where the single
definition lives) and its rejected alternatives:
- **CHOSEN — a single shared lib (`touched-files.sh`) all three readers source.**
  Rejected alternative: **keeping three byte-identical copies guarded only by the
  cross-check (0048's pattern)** — three copies can still drift between cross-check
  runs and invite a fourth copy, whereas a single sourced definition removes the
  divergence by construction. Cost (a sibling source edge, awkward for standalone
  `tdd-lint.sh`) is mitigated by the host-relative `${BASH_SOURCE[0]%/*}` + include
  guard + the dual `return||exit` idiom.
- Rejected alternative: **delegating `_touched_files_of_tdd` to gates.sh's
  `_rework_touched_files`** (no new file) — it couples learnings.sh to gates.sh
  being sourced, which is true at runtime but breaks standalone learnings.sh
  testing; a neutral shared lib both libs source is cleaner than a cross-lib
  function call.

## PRD conflicts surfaced (and resolution)
None. This TDD hardens the existing FR-53/54/67 mechanism; it introduces no new
requirement and reverses no accepted ADR. No `BLOCKERS.md` entry remains open (the
0044 entry that logged this "LATENT RUNNER FOOTGUN candidate gap-closure" is
already checked off; this TDD is its durable follow-up).

## Decisions to promote (ADR candidates)
None. "One sourced definition for a parser shared across libs" is a localized
implementation choice, not a durable cross-cutting architectural decision — it
does not clear the ADR bar. ADRs 0005 and 0006 already govern the area and are
respected.

## Touched files
- `scripts/lib/touched-files.sh` — NEW shared lib: include guard + `tl_extract_touched_paths` (annotation-robust, MODE-parameterized extractor).
- `scripts/lib/gates.sh` — source the shared lib; reduce `_rework_touched_files` to a delegating wrapper + update its doc comment.
- `scripts/lib/tdd-lint.sh` — source the shared lib; reduce `_tl_extract_touched_paths` to a delegating wrapper (preserving `malformed` mode) + update its doc comment.
- `scripts/lib/learnings.sh` — source the shared lib; reduce `_touched_files_of_tdd` to path-build + delegation; fix the false-parity comment.
- `tests/bounded-tdd-scope.test.sh` — 3-way agreement cross-check + annotation/bare-annotation/no-em-dash unit cases + the annotated-path (a)-membership regression.

## Expected diff size
- `scripts/lib/touched-files.sh` — 45 lines (new file: header + guard + ~25-line awk function; padded ×1.4 shell-lib).
- `scripts/lib/gates.sh` — 25 lines (source block + awk-body → wrapper; net replace; ×1.4).
- `scripts/lib/tdd-lint.sh` — 35 lines (source block + awk-body → wrapper + comment; ×1.4).
- `scripts/lib/learnings.sh` — 25 lines (source block + awk-body → wrapper + comment fix; ×1.4).
- `tests/bounded-tdd-scope.test.sh` — 80 lines (3-way cross-check upgrade + ~4 form cases + membership regression; ×1.6 test).
Total expected diff: ~210 lines across 5 files. No exceptions needed (each file is well under the 300-line per-file cap; estimates padded per the systematic underestimation lesson — test ×1.6, shell-lib ×1.4).

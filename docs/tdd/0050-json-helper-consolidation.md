# TDD 0050: Canonical JSON escaper + array builder (scripts/lib/json.sh)
Status: implemented
PRD refs: FR-72 (candidate-learnings JSON); FR-27 (run-state JSON record); FR-46 (draft persistence JSON); FR-39 (resume reads run-state); FR-69 (self-compliance with Theme A)
PRD-rev: 0aa1e28
ADR constraints: 0006

## Approach
Pure-bash JSON construction is currently implemented in **four competing places**
with **divergent validity guarantees**, and the weakest one emits invalid JSON:

- `json_escape` (state.sh:139-147) — escapes `"`, `\`, `\n`, `\r`, `\t` but NOT
  the other C0 control characters U+0001–U+001F. A finding/note/halt-detail
  containing a raw control byte (e.g. a `\x01` in captured subprocess output)
  produces a JSON fragment that violates RFC 8259 §7 (controls MUST be escaped) →
  the whole run-state fragment or candidate-learnings file can fail a downstream
  strict parse (**bug A11**, and **bug A3** where this same gap reaches
  `candidate-learnings.json` via learnings.sh).
- `_tl_json_escape` (markers.sh:30-48) — the CORRECT full escaper (handles all C0
  controls via `\u00XX`).
- `_tl_json_escape_full` (drafts.sh:130-144) — a THIRD escaper that exists only to
  post-process `json_escape`'s output to paper over its C0 gap (drafts.sh:117-129
  admits this).
- JSON string-array building is open-coded ~5× (state.sh:246-258, 260-274,
  1409-1421, 1623-1634; gates.sh:778-788) plus two named one-offs (`_json_str_array`
  learnings.sh:63 space-separated; `_tl_csv_to_json_array` markers.sh:51 CSV), which
  also diverge cosmetically (`["a", "b"]` vs `["a","b"]`).

This TDD creates **one canonical, C0-safe, dependency-free** library
`scripts/lib/json.sh` and routes every escaper/array caller through it, so JSON
validity is single-sourced (folds reuse findings B-json #1/#6/#7 and bugs A11, A3).

`markers.sh` is deliberately standalone/minimal-host (it sources only repo-id.sh
and avoids `dirname` for coreutils-light hosts). To let it adopt the shared lib
without breaking that contract (interview decision), `json.sh` is itself
**dependency-free and `dirname`-free**: it defines pure-bash functions with no
top-level side effects and no sourcing of its own. The *consumers* source it.

**JSON also has a READ side, and its primary reader is broken (folds A10/A5,
extracted from the deferred [[0051]]).** `state.sh`'s free-text fragment fields
(`note`, `halt_cause_detail`) are read with `sed -n 's/.*"k":"\([^"]*\)".*/\1/p'`.
The `[^"]*` class stops at the FIRST `"` byte — which is the quote half of a stored
`\"` escape — so a quote-bearing value is silently TRUNCATED on read (and the
dangling `\` is re-escaped to `\\` on the next write). The audit traced the
reachable corruption through `_read_fragment_field` (state.sh:50): a gate's
free-text `halt_cause_detail` (e.g. `gate emitted no verdict: "PASS" expected`) is
truncated on the very next `set_tdd_state`. Because `json.sh` is now THE canonical
JSON helper, this TDD adds the matching READ helper and repoints the PRIMARY reader
to it. The mutator-inline `[^"]*` copies (state.sh:701, 782, …) and resume.sh's
copies are left to the deferred [[0051]] carry-forward refactor, which routes them
ALL through this same reader — so the highest-traffic documented path is fixed now,
the rest follow with the refactor.

## Components & interfaces
**New — `scripts/lib/json.sh`** (side-effect-free, idempotently sourceable):
```
tl_json_escape <string>
    echo the RFC-8259-valid escaped form of <string> WITHOUT surrounding quotes.
    Escapes " \ and the two-char forms \b \f \n \r \t, and EVERY remaining C0
    control U+0001–U+001F as \u00XX (lowercase hex). Pure bash (printf %02x loop
    over the control set + parameter-expansion replacement); no jq, no dirname.
tl_json_array <csv>
    echo a JSON string array ["a","b",...] from a comma-separated <csv>; each
    element is tl_json_escape'd; empty input → []. No trailing space after commas.
tl_json_array_ws <ws-list>
    same, for a whitespace-separated list (the _json_str_array shape learnings uses).
tl_json_field <key>     (reads the JSON text on stdin)
    echo the UNescaped string value of top-level "<key>":"…" from the JSON on stdin,
    consuming the JSON string quote-aware (honoring \" \\ \/ \n.. escapes) so an
    embedded quote does not truncate it; empty if the key is absent or null. Pure
    awk, no jq (state.sh's fragment I/O is deliberately jq-optional — TDD 0037).
    This is the A10/A5 read-side fix and the inverse of tl_json_escape.
```
Include guard so double-sourcing (state.sh + gates.sh both pull it under one
implement.sh) is a no-op:
```
[ -n "${_TL_JSON_SOURCED:-}" ] && return 0
_TL_JSON_SOURCED=1
```
`_TL_JSON_SOURCED` is the persistent guard and is never unset.

**The four escapers + the array sites become thin delegating wrappers** (names
kept so every caller and test is untouched):
- `json_escape` (state.sh) → `tl_json_escape "$1"`. **This is the A11 fix**: the
  C0-safe body now backs every state.sh JSON write.
- `_tl_json_escape` (markers.sh) → `tl_json_escape "$1"`.
- `_tl_json_escape_full` (drafts.sh) → removed; callers use `tl_json_escape`
  directly (folds #6 — the post-processing third escaper is deleted).
- `_json_str_array` (learnings.sh) → `tl_json_array_ws "$1"`; the
  candidate-learnings.json field writes route through it, so a C0 byte in a
  finding summary/evidence is now escaped (**A3 fix**).
- `_tl_csv_to_json_array` (markers.sh) → `tl_json_array "$1"`.
- The 5 inline array builders (state.sh ×4, gates.sh ×1) → `tl_json_array`/`_ws`.
- `_read_fragment_field` (state.sh:50) → reads the fragment and pipes it to
  `tl_json_field "$key"` instead of the `[^"]*` sed. **This is the A10/A5 fix** for
  the primary reader; its name/signature/output are unchanged (only quote-bearing
  values now round-trip instead of truncating — the sole intended output change).

**Sourcing (per consumer).** Each consumer sources json.sh by its sibling path
with the FATAL-on-missing pattern and the dual `return||exit` idiom established by
TDD 0049 for touched-files.sh:
```
_jlib="${BASH_SOURCE[0]%/*}/json.sh"
{ [ -r "$_jlib" ] && . "$_jlib"; } || { echo "FATAL: cannot source $_jlib" >&2; return 1 2>/dev/null || exit 1; }
unset _jlib
```
`${BASH_SOURCE[0]%/*}` is `dirname`-free (parameter expansion), so markers.sh's
minimal-host contract is preserved. state.sh, learnings.sh, gates.sh are sourced
by implement.sh (abs path); drafts.sh already sources state.sh; markers.sh and
drafts.sh also run/standalone-source in tests — all four contexts covered as in 0049.
The bare-name sourcing edge case (`${BASH_SOURCE[0]%/*}` == the source string when
there is no `/`) does NOT arise here because every markers.sh/json.sh caller sources
via an absolute path (`$CLAUDE_PLUGIN_ROOT`/`$REPO`/`$SCRIPT_DIR`-rooted), never a
bare basename — so the pure-`%/*` resolve (without 0049's `cd && pwd` belt) is safe
for this set.

## Data & state
No persisted state. Pure functions: string → escaped string / JSON array on
stdout. `_TL_JSON_SOURCED` is process-local shell state only.

## Sequencing / implementation plan
1. Create `scripts/lib/json.sh`: guard + `tl_json_escape` (C0-complete) +
   `tl_json_array` + `tl_json_array_ws` + `tl_json_field` (quote-aware reader).
2. Wire `scripts/lib/state.sh`: source json.sh; `json_escape` → delegate; the 4
   inline array builders → `tl_json_array`/`_ws`; repoint `_read_fragment_field`
   (state.sh:50) to `tl_json_field` (A10/A5 primary-reader fix).
3. Wire `scripts/lib/markers.sh`: source json.sh (dependency-free); `_tl_json_escape`
   + `_tl_csv_to_json_array` → delegate.
4. Wire `scripts/lib/learnings.sh`: source json.sh; `_json_str_array` → delegate;
   the candidate-learnings summary/evidence writes flow through the C0-safe escaper.
5. Wire `scripts/lib/drafts.sh`: source json.sh; delete `_tl_json_escape_full`;
   callers use `tl_json_escape`.
6. Wire `scripts/lib/gates.sh`: source json.sh; the array builder at 778-788 → `tl_json_array`.
7. Add `tests/json-helper.test.sh` (unit + the A11/A3 regression) and register it
   in `tests/implement-gate.test.sh`.

## Failure modes & edge cases
**Real risks.**
- *Escaper output changes break a golden/snapshot test.* The new escaper emits
  `\u00XX` for controls that the old `json_escape` passed through raw — any test
  pinning the OLD (invalid) output must be updated. Mitigated by Verification §1
  (assert valid JSON, not a byte-pin) and a sweep of existing JSON-output tests.
- *Sourcing breaks markers minimal-host.* Mitigated by the `dirname`-free
  `${BASH_SOURCE[0]%/*}` resolution; pinned by Verification §4.
- *A divergent inline copy is missed.* Mitigated by Verification §2 (repo-grep
  asserts no `\\u00` / hand-rolled escaper remains outside json.sh).

**Overblown risks.**
- *Performance of a pure-bash control-escape loop.* The escape walks a fixed
  31-char control set with parameter expansion, not per-byte iteration; the JSON
  written is small (fragments, candidate lists). Negligible.

**Unspoken risks (elephants).**
- *The C0 fix surfaces previously-hidden corruption.* Some run-state files written
  by the OLD escaper may already contain raw control bytes; readers tolerant of
  them won't change, but a strict consumer added later would now see valid JSON.
  This is a fix, not a regression — noted so a reviewer doesn't read the output
  diff as a behavior break.

## Verification plan
- **Observable surface:** (a) `tl_json_escape` stdout; (b) the JSON files the
  callers write (run-state fragment, `candidate-learnings.json`, draft json),
  parsed by a strict JSON parser; (c) successful sourcing (no FATAL) of each
  consumer.
- **Observation points (mechanical, `tests/json-helper.test.sh` + the existing
  state/learnings/markers/drafts evals):**
  1. Feed `tl_json_escape` a string containing `"`, `\`, newline, tab, and a raw
     `\x01`/`\x1f` control byte; pipe the result (wrapped as a JSON value) through
     a strict parser.
  2. Drive a learnings candidate write (A3) and a state fragment write (A11) whose
     free-text field contains a `\x01` byte; parse the resulting file strictly.
  3. `tl_json_array "a,b,\"c\""` and `tl_json_array_ws "a b"` → assert exact,
     valid array output.
  4. Source each consumer in all four contexts (implement.sh abs-path, standalone
     `bash markers.sh`-style, SOURCE_ONLY eval, double-source) — assert no FATAL
     and `tl_json_escape` is defined.
  5. Repo-grep: no escaper/array awk/sed copy remains outside json.sh.
  6. **A10/A5:** write a fragment whose `note`/`halt_cause_detail` contains a `"`
     (e.g. `gate emitted no verdict: "PASS" expected`); read it back via
     `_read_fragment_field` and, separately, drive a `set_tdd_state` carry-forward
     of it → assert the full original string round-trips (no truncation at the first
     `"`, no dangling `\`). Also feed `tl_json_field` an absent key and a `null`
     value → empty.
- **Expected observations (PASS):**
  - §1: the parser accepts the output; the control byte appears as ``/``.
  - §2 (**A11 + A3 regression**): pre-fix, the strict parse FAILS (raw control in
    the file); post-fix it PASSES. This is the named fail-pre/pass-post check.
  - §3: arrays are byte-exact (`["a","b","c"]`, no inner space; `[]` on empty).
  - §4: every context sources cleanly; markers.sh still needs no `dirname`.
  - §5: single source of truth — no other escaper body found.
  - §6 (**A10/A5 regression**): pre-fix the quote-bearing field reads back truncated
    at the first `"`; post-fix it round-trips intact through the primary reader.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement + folded-bug traceability | Every FR-53/54/67 tie-in AND each folded bug (A-id) maps to a named design element | All mapped | Any req or folded bug untraced |
| Folded-bug regression coverage | Each folded bug has a named observation point that fails pre-fix / passes post-fix | Each folded bug has a regression check | A folded bug has no regression observation |
| Single-source-of-truth (refactors) | One canonical helper; all callers verified-thin delegates | Callers delegate; one definition | A divergent copy remains |
| Sourcing + back-compat | New shared lib sources cleanly in all 4 contexts incl markers minimal-host; existing callers/tests unbroken | Sourcing + guard specified | A context unhandled or a caller regressed |
| Verification-plan actionability | Observable surface + exact points + expected values | Surface + points named | placeholder/vague |
| Scope-bound adherence | Within bounds, or a declared/justified exception (state.sh) | Within bounds | Bound blown without exception |
| Naming consistency | Same helper names across all 5 TDDs | Mostly consistent | Same concept named two ways |

## Requirement traceability
| Requirement / bug | Design element |
|---|---|
| FR-72 (candidate-learnings JSON validity) | learnings.sh routes summary/evidence through the C0-safe `tl_json_escape` (step 4); A3 regression Verification §2 |
| FR-27 (run-state JSON record) | state.sh `json_escape` delegates to C0-safe escaper (step 2); A11 regression Verification §2 |
| FR-39 (resume reads run-state) | `_read_fragment_field` → `tl_json_field` so a quote-bearing `note`/`halt_cause_detail` is not truncated on the read paths resume/refuse-to-resume use; A10/A5 regression Verification §6 |
| FR-46 (draft JSON) | drafts.sh drops its third escaper for the canonical one (step 5) |
| ADR 0006 (artifacts grounded) | a sourcing failure FATALs loudly (no silent half-escaped writer) |
| FR-69 (self-compliance with Theme A) | one canonical `json.sh` retires 3 escapers + 5 array sites, reducing the libs' duplicated scope |
| bug A11 | `json_escape` → `tl_json_escape` (C0-complete); Verification §2 |
| bug A3 | learnings candidate writes route through C0-safe escaper; Verification §2 |
| bug A10 / A5 (primary reader) | `tl_json_field` quote-aware reader; `_read_fragment_field` repointed to it; Verification §6. Residual mutator-inline + resume.sh readers → deferred [[0051]] |

No gaps (A10/A5 are fixed at the primary `_read_fragment_field` path; the inline mutator/resume.sh copies are explicitly carried to the deferred [[0051]] refactor — not dropped).

## Dependencies considered
No new external dependency — pure bash, NO jq (json.sh must work on the same
jq-optional hosts state.sh targets; see [[0051]]). Chosen: one shared `json.sh`.
Rejected alternatives:
- **Fix `json_escape` in place, leave the other three escapers** — rejected: the
  divergence (3 escapers, 2 array builders) and the cosmetic `["a", "b"]` vs
  `["a","b"]` split persist, and a future C0 fix would again need 3 edits.
- **Use `jq -Rs` for escaping** — rejected: jq is deliberately OPTIONAL on the
  core state path (state.sh `_extract_token_spend` falls back to `null` when jq is
  absent, "no new dependency"); a hard jq dep would reverse TDD 0037's
  dependency-light posture.

## PRD conflicts surfaced (and resolution)
None. Hardens existing JSON-writing requirements; no new requirement, no ADR reversed.

## Decisions to promote (ADR candidates)
None. A shared pure-bash JSON helper is a localized implementation choice, not a
durable cross-cutting decision. ADR 0006 already governs and is respected.

## Touched files
- `scripts/lib/json.sh` — NEW: guard + `tl_json_escape` (C0-safe) + `tl_json_array` + `tl_json_array_ws` + `tl_json_field` (quote-aware reader, A10/A5).
- `scripts/lib/state.sh` — source json.sh; `json_escape` → delegate (A11); 4 inline array builders → delegate; `_read_fragment_field` → `tl_json_field` (A10/A5 primary-reader fix).
- `scripts/lib/markers.sh` — source json.sh (dependency-free); `_tl_json_escape` + `_tl_csv_to_json_array` → delegate.
- `scripts/lib/learnings.sh` — source json.sh; `_json_str_array` → delegate (A3 escaper path).
- `scripts/lib/drafts.sh` — source json.sh; delete `_tl_json_escape_full`; callers use `tl_json_escape`.
- `scripts/lib/gates.sh` — source json.sh; array builder (778-788) → delegate.
- `tests/json-helper.test.sh` — NEW unit + A11/A3 regression eval.
- `tests/implement-gate.test.sh` — register the new eval.
- `tests/lifecycle-helpers.test.sh` — compact-array byte-pin update (the §Failure-modes "tests pinning the OLD output" sweep; found at build time).
- `tests/interactive-draft-persistence.test.sh` — [R]-block comment sync (the deleted third-escaper rationale; same sweep).
- `.claude-plugin/plugin.json` — version bump (build-applied housekeeping).

## Expected diff size
Reconciled at build time (run 20260612-062318) to the enforcement metric —
cumulative adds+dels per `git diff --numstat <build-start>..HEAD` — which
counts every REPLACED line twice (the retired escaper/array bodies are
deletions the original net-new estimates never counted), on top of the
documented ~1.5× systematic under-estimate. Design-time estimates were ~342
net lines across 9 files; the measured churn:
- `scripts/lib/json.sh` — 159 lines (new: guard + 4 functions incl the `tl_json_field` quote-aware reader awk + contract comments).
- `scripts/lib/state.sh` — 114 lines (source block + escaper delegate + 4 array-builder replacements + `_read_fragment_field` repoint; replaced bodies count add+del).
- `scripts/lib/markers.sh` — 62 lines (source block + 2 delegates; the two replaced bodies count add+del).
- `scripts/lib/learnings.sh` — 39 lines (source block + 1 delegate + header-comment sync).
- `scripts/lib/drafts.sh` — 64 lines (source block + full-escaper deletion + caller updates + comment sync).
- `scripts/lib/gates.sh` — 30 lines (source block + 1 array delegate).
- `tests/json-helper.test.sh` — 370 lines (exception: ONE consolidated eval carries all six Verification sections — §1/§3 units, §2 A11+A3 regressions, §6 A10/A5 round-trip, §4 four-context sourcing matrix, §5 single-source greps, §W aggregator chain-drive — plus the per-consumer delegation observables; splitting it into per-section files would spread, not shrink, the same lines).
- `tests/implement-gate.test.sh` — 18 lines (register + AND-chain term).
- `tests/lifecycle-helpers.test.sh` — 2 lines (compact-array byte-pin update; §Failure-modes sweep).
- `tests/interactive-draft-persistence.test.sh` — 11 lines ([R]-block comment sync; same sweep).
- `.claude-plugin/plugin.json` — 2 lines (version bump).
Total measured diff: ~871 lines across 11 files. The touched-file COUNT 11 >
the default `THROUGHLINE_TDD_MAX_TOUCHED`=8 (design-time `--bounds` only — the
build does not re-check the count), so a clean design-time `--bounds` uses
`THROUGHLINE_TDD_MAX_TOUCHED=11`.

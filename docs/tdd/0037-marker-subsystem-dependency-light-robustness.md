# TDD 0037: Marker subsystem dependency-light robustness — valid-JSON escaping + jq-free read needs no external coreutils

Status: implemented
PRD refs: FR-31, FR-33 (gap-closure); FR-74; NFR-4
PRD-rev: d289607
ADR constraints: 0004, 0005

## Approach

Two confirmed defects in `scripts/lib/markers.sh` (the TDD 0009 marker
subsystem), each with a failing test already on master, both in the subsystem's
deliberately *dependency-light* paths (the no-jq write/read paths that exist so
markers work on jq-absent machines, markers.sh:8-9):

1. **The marker writer emits invalid JSON for control-char values.**
   `_tl_json_escape` (markers.sh:22-27) escapes only `\` and `"`; a value
   containing a tab/newline is written RAW into the JSON string literal —
   invalid JSON (the spec requires C0 controls U+0000–U+001F to be escaped), so
   `jq` cannot parse the marker and the value does not round-trip. Confirmed:
   `_tl_json_escape "$(printf 'a\tb\nc')"` emits literal tab/newline bytes
   (`od`-verified), and `{"x":"<that>"}` fails `jq -e .`. The function's own
   comment concedes the gap ("Sufficient for our fields … which never contain
   control characters"). This is exactly the hand-rolled-JSON-escaper hazard
   FR-74's escaping/quoting defensive norm targets — an escaper that silently
   mishandles a class of input. (`tests/markers.test.sh` case [G], red.)

2. **The jq-free marker read gratuitously needs external coreutils.** The no-jq
   fallback in `_tl_marker_read_file` strips whitespace with `tr -d '[:space:]'`
   (markers.sh:65), and markers.sh resolves its own directory at source time with
   `dirname` (markers.sh:15). On a genuinely minimal jq-absent environment these
   external tools may be absent, so the read returns `{}` and
   `plugin_version_applied` is unrecoverable — defeating FR-31's re-run
   short-circuit on exactly the jq-absent machines the no-jq path exists for.
   Confirmed: with `tr`+`dirname` removed from the PATH the read yields `{}`;
   adding them back makes the test pass 23/0. (`tests/bootstrap-marker-wiring.test.sh`
   case [I], red.)

The fix makes both paths correct in **pure bash** — no new dependency, and
fewer external processes (aligning with the FR-74 defensive-coding norms: the
no-jq path should not reach for an external process where a shell builtin
suffices). The marker WRITE path stays jq-free by design (markers.sh:8); the fix
does NOT introduce jq into writing.

Per ADR 0005 (mechanism in the shell, observed not sandboxed) and ADR 0004
(verification by observation) this is a contained correctness fix to existing
helpers; it adds no new mechanism.

## Components & interfaces

### 1. Control-char-correct JSON escaping — `_tl_json_escape` (markers.sh:22-27)

Rewrite the escaper so its output is always a valid JSON string body, in pure
bash (no jq, no external process):

- Escape `\` → `\\` FIRST (so backslashes already present are doubled before any
  escape sequence is introduced), then `"` → `\"`.
- Escape the five named C0 controls via parameter expansion against their literal
  bytes (`$'\b'`,`$'\t'`,`$'\n'`,`$'\f'`,`$'\r'`) to `\b`,`\t`,`\n`,`\f`,`\r`.
- Escape every REMAINING C0 control (U+0001–U+001F minus the five named above —
  i.e. `01 02 03 04 05 06 07 0b 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d
  1e 1f`) to its six-char `\u00XX` form, by looping that fixed hex list:
  `printf -v lit '%b' "\\x$cc"; s="${s//$lit/\\u00$cc}"`. U+0000 (NUL) needs no
  handling — bash cannot hold a NUL in a string variable, so it can never reach
  this function.
- `printf '%s' "$s"`.

Replacements are single-pass left-to-right (bash PE does not re-scan the
replacement text), so the ordering above is sufficient and correct.

### 2. jq-free read needs no `tr` — `_tl_marker_read_file` (markers.sh:65)

Replace `stripped="$(printf '%s' "$content" | tr -d '[:space:]')"` with the
pure-bash equivalent `stripped="${content//[[:space:]]/}"` (bash parameter
expansion supports the POSIX `[[:space:]]` class). Same result (all whitespace
removed for the structural `{…}` check), no external `tr`.

### 3. Source-time path resolution needs no `dirname` — markers.sh:15

Replace `_TL_MARKERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` with a
pure-bash directory extraction:
`d="${BASH_SOURCE[0]%/*}"; [ "$d" = "${BASH_SOURCE[0]}" ] && d="."; [ -z "$d" ] && d="/"; _TL_MARKERS_DIR="$(cd "$d" && pwd)"`.
The first guard handles the no-slash case (sourced by bare name → `%/*` is a
no-op → fall back to `.`, matching `dirname`'s `.`); the second handles the
root-level case (`/markers.sh` → `%/*` yields `""` → fall back to `/`, matching
`dirname`'s `/`) — unreachable in the plugin's deploy layout but cheap to cover.
`cd`/`pwd` are bash builtins (no external process); only the external `dirname`
is removed.

No other external dependency in the no-jq read is changed: `cat` (markers.sh:64)
and `grep` (markers.sh:67) are retained — the [I] regression's curated PATH
sanctions them as the basic toolset, and they are not the failure cause. Scope
stays the two confirmed-missing tools.

## Data & state

No state, schema, or interface-signature change. The marker file FORMAT is
unchanged for the fields that occur in practice (versions/languages/enums never
contain control chars, so their on-disk bytes are identical); the escaper change
only affects values that previously produced invalid JSON. The read change is
output-identical for well-formed markers. No migration.

## Sequencing / implementation plan

1. **Failing-test-first.** The regression is already captured by two red tests on
   the integration branch: `tests/markers.test.sh` [G] (control-char round-trip)
   and `tests/bootstrap-marker-wiring.test.sh` [I] (jq-free read recovers the
   version). As the failing-test-first step, add ONE focused direct unit
   assertion to `tests/markers.test.sh` — call `_tl_json_escape` on a
   control-char value and assert `{"x":"<escaped>"}` parses with `jq -e .` and
   round-trips — committed as `test(failing):` BEFORE the fix (it is red against
   the current escaper). The pre-existing [G]/[I] cases are the authoritative
   regression surface that must also end green; no new test is needed for the
   [I] half (its harness already exercises the jq-free path).
2. **Fix the escaper** (Component 1) in `scripts/lib/markers.sh`.
3. **Drop `tr`** from the jq-free read (Component 2) and **`dirname`** from
   source-time resolution (Component 3), same file.

## Failure modes & edge cases

- **NUL (U+0000) in a value** — unrepresentable in a bash string variable, so it
  can never reach `_tl_json_escape`; no handling needed (documented in Component
  1). The marker fields never contain NUL regardless.
- **Backslash-ordering** — escaping `\` first is required; doing it after the
  control-char escapes would double the backslashes the `\uXXXX`/`\n` sequences
  introduce. Component 1 fixes the order.
- **`[[:space:]]` PE portability** — bash supports POSIX character classes in
  parameter-expansion glob patterns (since 3.x); the runner targets bash 4+
  regardless. No regression on supported shells.
- **`${BASH_SOURCE[0]%/*}` no-slash case** — guarded to `.` (Component 3), so
  sourcing markers.sh by bare name still locates `repo-id.sh` exactly as
  `dirname` did.
- **A non-marker / malformed file on a jq-absent host** — unchanged: the
  structural `{…}`-plus-`"schema"` check still degrades to `{}` (the `tr`→PE swap
  is output-identical for that check).

## Verification plan

**Observable surface:** the bytes `_tl_json_escape` / `tl_repo_marker_write`
write to `docs/.throughline-bootstrap.json` (must be `jq`-parseable and
round-trip); the value `tl_repo_marker_read` + the bootstrap field-extraction
recover on a PATH lacking `jq`/`tr`/`dirname`; the two pre-existing tests' and
the aggregator's pass/fail.

**Observation points** (mechanical):

1. **Control-char round-trip (the new `test(failing):` + existing [G]).** Call
   `tl_repo_marker_write "$(printf 'a\tb\nc')" sh a`, then `jq -e . <marker>`
   parses AND `jq -r '.plugin_version_applied' <marker>` equals the original
   tab+newline value. `tests/markers.test.sh` ends `… 0 failed` (case [G] green).
2. **Direct escaper unit (the new assertion).** `_tl_json_escape` on a value
   containing a tab, newline, and a bare control char (e.g. `$'\x01'`) →
   embedding it in `{"x":"…"}` parses with `jq -e .` and `jq -r .x` round-trips
   the original.
3. **jq-free read recovers the version (existing [I]).** With a curated PATH
   containing only `bash git cat sed head grep printf` (NO `jq`, NO `tr`, NO
   `dirname`), the bootstrap Step-0 read recovers `plugin_version_applied`
   (`APPLIED=9.9.9`). `tests/bootstrap-marker-wiring.test.sh` ends `… 0 failed`
   (case [I] green).
4. **Aggregator.** `bash tests/implement-gate.test.sh` no longer reports the
   markers / bootstrap reds attributable to these two cases (the suite's
   `markers`/`bootstrap-marker-wiring` sections pass).

**Expected observations (PASS):** every numbered point yields the cited result;
no new external dependency is introduced (the fixes are pure bash).

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-31 (committed bootstrap marker; re-run short-circuit reads `plugin_version_applied`, must work jq-absent) | Components 2+3: the jq-free read recovers the version with no external `tr`/`dirname`. Verification §3, §4. |
| FR-33 (per-developer local marker, same read/write helpers) | Components 1–3 fix the shared `_tl_json_escape` / `_tl_marker_read_file` / source-time path used by both markers. Verification §1–§3. |
| FR-74 (build-phase defensive-coding norms — fail-safe, minimal external deps, no hand-rolled escaper landmines) | Component 1 replaces the incomplete hand-rolled escaper with a control-char-correct one (satisfying FR-74's escaping norm on a path where jq is contractually unavailable — see PRD conflicts surfaced); Components 2-3 remove gratuitous external processes from the fallback path. Verification §1, §2, §3. |
| NFR-4 (honest behavior; no silent corruption) | Component 1: the writer no longer silently emits invalid JSON that reads back wrong. Verification §1, §2. |

No gaps.

## Dependencies considered

No new dependency — the entire fix is pure bash, and it REMOVES two external
process dependencies (`tr`, `dirname`) from the jq-free path.

Alternatives considered:
- **Use `jq` (or `python3`) to write/escape the marker** — rejected: the marker
  WRITE path is deliberately jq-free (markers.sh:8) so `/bootstrap-project` can
  record markers on jq-absent machines; introducing jq for writing reverses that
  decision and reintroduces the very dependency the no-jq path exists to avoid.
  (FR-74's escaping norm — prefer `jq`/`python3` over a hand-rolled escaper —
  presumes jq is an available dependency; the marker WRITE path is contractually
  jq-free per FR-31, so a *correct, control-char-complete pure-bash* escaper for
  this bounded transform is the reconciliation — see PRD conflicts surfaced.)
- **Relax the tests to the documented "no control chars" contract** (drop [G]'s
  control-char case; add `tr`/`dirname` to [I]'s curated PATH) — rejected by the
  design decision: the tests encode the correct contracts (a JSON writer must
  emit valid JSON; FR-31's no-jq path must be dependency-light), the code fixes
  are cheap, and relaxing would leave a latent invalid-JSON landmine and a weaker
  FR-31 guarantee.
- **Keep `tr`/`dirname`, just guarantee them** (document a coreutils
  prerequisite) — rejected: contradicts the dependency-light purpose of the
  no-jq path and adds an environment precondition where a builtin suffices.

## PRD conflicts surfaced (and resolution)

**FR-74 ↔ FR-31 tension (surfaced, resolved in-design).** FR-74's escaping norm
says a JSON-emitting code path should use a `jq`/`python3` escape "rather than a
hand-rolled one." This TDD fixes a JSON-emitting path (the marker writer) by
shipping a *hand-rolled* (pure-bash) escaper — a literal-reading conflict with
that norm. **Resolution:** FR-74's "prefer jq/python3" presumes jq is an
available dependency on that path, but the marker WRITE path is *contractually
jq-free* per FR-31 (so `/bootstrap-project` can record markers on jq-absent
machines, markers.sh:8). The two requirements cannot both be honored literally;
the reconciliation is the one this TDD takes — keep the path jq-free (honor
FR-31) and make the hand-rolled escaper **control-char-complete and tested**
(honor FR-74's *intent*: no silent-mishandling landmine), rather than reintroduce
the jq dependency FR-31 forbids. FR-74's wording could be sharpened at the next
PRD touch to carve out contractually-dependency-free paths (where a *correct,
tested* hand-rolled escaper is the sanctioned form) — recorded here for
`/prd-author`; out of scope for this TDD-only gap-closure.

Otherwise none: FR-31/FR-33 already require the markers to work (including
jq-absent per FR-31's dependency note); this closes the gap where the
implementation didn't meet them. TDD 0009 (implemented) is the historical record
and is not rewritten — this is a gap-closure of its FRs.

## Decisions to promote (ADR candidates)

None. A contained correctness fix to existing helpers within the established
no-jq marker design; no new cross-cutting decision.

## Touched files

- `scripts/lib/markers.sh` — control-char-correct `_tl_json_escape`; drop external `tr` (jq-free read) and `dirname` (source-time path) for pure-bash equivalents.
- `tests/markers.test.sh` — add one focused `_tl_json_escape` control-char round-trip assertion as the `test(failing):` step (the existing [G] case stays; [I] in bootstrap-marker-wiring.test.sh is unchanged).

Total: 2 files touched.

## Expected diff size

- `scripts/lib/markers.sh` — ~22 lines changed/added (the escaper rewrite: 2 quote/backslash + 5 named + the fixed residual-C0 loop ~6, plus the two one-/two-line dependency swaps).
- `tests/markers.test.sh` — ~12 lines added (one focused control-char round-trip assertion).

Total expected diff: ~34 lines across 2 files. No exceptions needed (both well under the 300-line per-file bound).

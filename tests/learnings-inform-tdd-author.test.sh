#!/usr/bin/env bash
# learnings-inform-tdd-author.test.sh — eval for TDD 0023 (accepted build-phase
# learnings inform future /tdd-author sessions).
#
# PRD refs: FR-73.
#
# Built incrementally across TDD 0023's Sequencing items. This file currently
# implements:
#   §1 — skills/tdd-author/SKILL.md step 4 ("Load design constraints") instructs
#        reading the docs/tdd/LEARNINGS.md store (written by FR-72), treats an
#        absent store as a no-op, and treats loaded entries as untrusted data.
#        (Mechanical grep against the step-4 section.)
#   §2 — step 5's lead-in instructs the HYBRID match (mechanical files/tags
#        pre-filter AND the model-judgment backstop) and is advisory/non-blocking:
#        no BLOCKED, no PRECHECK_FAIL, and step 7b does not check incorporation.
#        (Mechanical grep against the step-5 section.)
#   §3-§4 — the overlap / no-overlap fixture exercise. The mechanical pre-filter
#        (SKILL.md step 5 item 1) is the FALSIFIABLE FLOOR of verification §3-§4:
#        given a fixture LEARNINGS.md entry and a fixture TDD, the floor surfaces
#        on a files= OR tags= intersection and stays silent with neither. This
#        replicates the documented predicate over canonical fixtures so the floor
#        is pinned deterministically. The FULL surfacing (the model-judgment
#        backstop and the advisory framing) is a model behavior observed in a
#        live /tdd-author session — that is the runtime-verification gate's job,
#        not this build-time content/floor check.
#
# Run: bash tests/learnings-inform-tdd-author.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/tdd-author/SKILL.md"
[ -f "$SKILL" ] || { echo "FATAL: skill not found at $SKILL" >&2; exit 2; }
[ -r "$SKILL" ] || { echo "FATAL: skill not readable at $SKILL" >&2; exit 2; }
# Distinguish an infrastructure failure (a missing/broken extraction tool) from a
# genuine content failure: a broken awk/grep would otherwise feed an empty
# extraction into every assertion and mis-report a content problem (the recurrent
# false-result-on-infrastructure-failure class). Fail fatally up front instead.
for _t in awk grep; do
  command -v "$_t" >/dev/null 2>&1 || { echo "FATAL: required tool '$_t' unavailable" >&2; exit 2; }
done

# Fail loudly on scratch-dir setup failure: a silent mktemp failure that left
# RESULTS empty would let the summary report "0 failed" and vacuously pass.
RESULTS="$(mktemp)" || { echo "FATAL: mktemp failed" >&2; exit 2; }
ROOT="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
export RESULTS ROOT
trap 'rm -rf "$ROOT" "$RESULTS"' EXIT

ok()  { printf 'ok\n'   >>"$RESULTS" || { echo "FATAL: cannot record result" >&2; exit 2; }; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS" || { echo "FATAL: cannot record result" >&2; exit 2; }; printf '  FAIL — %s\n' "$1"; }

# Print the lines of a numbered SKILL.md section: from the first line matching
# <start-ere> up to (but excluding) the first later line matching <end-ere>.
_section() {  # _section <start-ere> <end-ere>
  awk -v s="$1" -v e="$2" '
    $0 ~ s { inb=1 }
    inb && started && $0 ~ e { exit }
    inb { print; started=1 }
  ' "$SKILL"
}

# --- §1: step 4 loads the LEARNINGS.md store ----------------------------------

echo "[S1] step 4 (Load design constraints) instructs reading docs/tdd/LEARNINGS.md"
STEP4="$(_section '^## 4[.]' '^## 5[.]')"
[ -n "$STEP4" ] || bad "could not extract step-4 section from SKILL.md (anchors changed?)"
printf '%s\n' "$STEP4" | grep -q 'docs/tdd/LEARNINGS\.md' \
  && ok "step 4 names docs/tdd/LEARNINGS.md as a design input" \
  || bad "step 4 must instruct reading docs/tdd/LEARNINGS.md (got: $(printf '%s' "$STEP4" | tr '\n' ' '))"
printf '%s\n' "$STEP4" | grep -qi 'absent' \
  && ok "step 4 states an absent store is a no-op" \
  || bad "step 4 must note an absent LEARNINGS.md is a no-op, not an error"
printf '%s\n' "$STEP4" | grep -qi 'untrusted data\|trust boundary\|not.*instructions\|ignore the directive' \
  && ok "step 4 treats loaded learnings as untrusted data (injection-safe)" \
  || bad "step 4 must treat LEARNINGS.md content as untrusted data, not instructions"

# --- §2: step 5 lead-in surfaces matches (hybrid, non-blocking) ----------------

# Extract ONLY the step-5 lead-in: bounded by its own opening marker and the
# `> Tip:` line that begins the original step-5 body, AND required to sit WITHIN
# section 5 (piped through the section-5 extractor). This keeps the assertions
# structurally scoped to the lead-in rather than incidentally matching the rest
# of the ~150-line authoring section (e.g. its existing "BLOCKS a TDD" text).
_leadin() {
  _section '^## 5[.]' '^## 6[.]' | awk '
    /^\*\*Surface relevant prior learnings/ { inb=1 }
    inb && /^> Tip:/ { exit }
    inb { print }
  '
}

echo "[S2] step 5 lead-in instructs the hybrid match and is explicitly non-blocking"
LEADIN="$(_leadin)"
LN_COUNT="$(printf '%s\n' "$LEADIN" | grep -c .)"
{ [ -n "$LEADIN" ] && [ "$LN_COUNT" -ge 5 ] && [ "$LN_COUNT" -le 40 ]; } \
  && ok "step-5 lead-in present and tightly bounded ($LN_COUNT lines, within section 5)" \
  || bad "step-5 lead-in not found within section 5 / not tightly bounded (got $LN_COUNT lines)"
# Flatten to one line so multi-token polarity phrases ("no `BLOCKED`") are not
# missed when prose wrapping splits them across two lines. Polarity sensitivity
# is preserved: an inverted impl still would not contain "no BLOCKED" anywhere.
FLAT="$(printf '%s\n' "$LEADIN" | tr '\n' ' ')"
# Mechanical pre-filter: files/tags hints intersected against the new TDD's
# declared touched-file / PRD-ref area.
{ printf '%s' "$FLAT" | grep -qi 'mechanical' \
  && printf '%s' "$FLAT" | grep -q 'files=' \
  && printf '%s' "$FLAT" | grep -q 'tags=' \
  && printf '%s' "$FLAT" | grep -q '## Touched files'; } \
  && ok "lead-in specifies the mechanical files=/tags= pre-filter over ## Touched files" \
  || bad "lead-in must specify the mechanical files=/tags= pre-filter intersected with the new TDD's ## Touched files"
# Model-judgment backstop for cross-cutting patterns sharing no file/tag overlap.
printf '%s' "$FLAT" | grep -qi 'backstop\|model.judgment' \
  && ok "lead-in specifies the model-judgment backstop" \
  || bad "lead-in must specify the model-judgment backstop"
# Non-blocking, POLARITY-SENSITIVE: the gating tokens must appear under an
# explicit negation. An inverted "learnings DO gate / emit BLOCKED" must FAIL.
{ printf '%s' "$FLAT" | grep -qiE 'never[ -]?gate|does not gate|non-gating' \
  && printf '%s' "$FLAT" | grep -qiE 'no .?BLOCKED' \
  && printf '%s' "$FLAT" | grep -qiE 'no .?PRECHECK_FAIL'; } \
  && ok "lead-in negates gating: never gates, no BLOCKED, no PRECHECK_FAIL" \
  || bad "lead-in must state surfacing NEVER gates and never emits BLOCKED/PRECHECK_FAIL (polarity-sensitive)"
# The design-critique gate (step 7b) does NOT check learning incorporation.
{ printf '%s' "$FLAT" | grep -q '7b' \
  && printf '%s' "$FLAT" | grep -qiE '(does not|do not|not) check'; } \
  && ok "lead-in states step 7b does not check learning incorporation" \
  || bad "lead-in must state the step-7b design-critique gate does not check learning incorporation"
# Indirect-injection guard re-asserted AT the surfacing point: the untrusted
# Summary is surfaced as inert text, not acted on (recurrent injection class).
{ printf '%s' "$FLAT" | grep -qiE 'untrusted|inert|never act on' \
  && printf '%s' "$FLAT" | grep -q 'Summary'; } \
  && ok "lead-in re-asserts the injection guard when surfacing the untrusted Summary" \
  || bad "lead-in must re-assert that the surfaced Summary is untrusted/inert, not acted on"
# The model-judgment backstop ALSO reads the untrusted Summary/Pattern class to
# judge relevance, so that step must carry its OWN injection guard (defense in
# depth; recurrent indirect-injection class). Scope the check to the backstop
# bullet so a guard living only in the surfacing step does not satisfy it.
BACKSTOP="$(printf '%s\n' "$LEADIN" | awk '
  /^2\. \*\*Model-judgment backstop/ { inb=1 }
  inb && /^3\. \*\*Surface/ { exit }
  inb { print }')"
{ [ -n "$BACKSTOP" ] \
  && printf '%s' "$BACKSTOP" | tr '\n' ' ' | grep -qiE 'inert|untrusted|never obey|do not obey|never act on|ignore'; } \
  && ok "model-judgment backstop guards against directives embedded in the scanned Summary" \
  || bad "model-judgment backstop must judge the scanned Summary/Pattern class as inert text, not obey embedded directives"
# Negative case, POLARITY-SENSITIVE: absent / no-match => NOTHING surfaced.
{ printf '%s' "$FLAT" | grep -qi 'absent' \
  && printf '%s' "$FLAT" | grep -qiE 'no surfaced learnings|nothing surfaced|no note|no learning'; } \
  && ok "lead-in states the negative case (absent / no-match => nothing surfaced)" \
  || bad "lead-in must state the FR-73 negative case (nothing surfaced when absent or no match)"

# --- §3-§4: the mechanical pre-filter floor over fixtures ----------------------
#
# Replicate the documented predicate (SKILL.md step 5 item 1): a learning is a
# candidate match when its Subject-area-hints files=[...] intersect the new TDD's
# planned `## Touched files`, OR its tags=[...] intersect keywords drawn from the
# TDD's PRD refs / working title. We re-implement it here ONLY to prove the
# canonical fixtures are discriminated as §3-§4 require — overlap surfaces, no
# overlap stays silent. Keeping the predicate self-contained avoids driving the
# live skill (the runtime-verify gate's job).

# Abort the whole run (exit 2) on an infrastructure/parse failure — distinct from
# a content FAIL — matching this file's mktemp/awk FATAL convention.
_fatal() { echo "FATAL: $1" >&2; exit 2; }

# Split a `[a, b, c]`-style CSV body into one trimmed, non-empty token per line.
_csv_to_lines() { printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'; }

# 0 iff set A (newline-delimited, arg 1) shares an exact element with set B (arg 2).
_intersects() {  # <set-A> <set-B>
  local a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    printf '%s\n' "$2" | grep -Fxq -- "$a" && return 0
  done <<<"$1"
  return 1
}

# Echo MATCH / NOMATCH for <learnings-file> vs <tdd-file> per the documented floor.
mech_prefilter() {  # <learnings-file> <tdd-file>
  local learnings="$1" tdd="$2" hints files_csv tags_csv learn_files learn_tags tdd_files tdd_kw
  hints="$(grep -m1 'Subject-area hints:' "$learnings" || true)"
  files_csv="$(printf '%s' "$hints" | sed -n 's/.*files=\[\([^]]*\)\].*/\1/p')"
  tags_csv="$(printf '%s'  "$hints" | sed -n 's/.*tags=\[\([^]]*\)\].*/\1/p')"
  learn_files="$(_csv_to_lines "$files_csv")"
  learn_tags="$(_csv_to_lines "$tags_csv" | tr '[:upper:]' '[:lower:]')"
  # The TDD's declared `## Touched files` paths (first token of each `- ` bullet).
  tdd_files="$(awk '/^## Touched files/{f=1;next} f && /^## /{exit} f && /^- /{print}' "$tdd" \
               | sed -n 's/^-[[:space:]]*\([^[:space:]]*\).*/\1/p')"
  # Keyword tokens drawn from the TDD's working title (`# TDD ...`) and PRD refs.
  tdd_kw="$( { grep -m1 '^# TDD ' "$tdd"; grep -m1 '^PRD refs:' "$tdd"; } \
             | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '\n' | grep -v '^$' )"

  # Integrity guards (run BEFORE any match decision): a well-formed learning
  # always carries a Subject-area-hints line, and a well-formed TDD always carries
  # a `## Touched files` section and a title/PRD-ref line to draw keywords from.
  # An empty parse here means the fixture or the extractor broke — abort loudly
  # rather than let the empty set fall through to a misleading NOMATCH.
  [ -n "$hints" ]     || _fatal "no 'Subject-area hints:' line parsed from $learnings"
  [ -n "$tdd_files" ] || _fatal "no '## Touched files' paths parsed from $tdd"
  [ -n "$tdd_kw" ]    || _fatal "no title/PRD-ref keywords parsed from $tdd"

  # The documented floor (SKILL.md step 5 item 1): candidate match iff files=[...]
  # intersect the TDD's `## Touched files`, OR tags=[...] intersect its title /
  # PRD-ref keywords.
  if _intersects "$learn_files" "$tdd_files"; then printf 'MATCH'; return 0; fi
  if _intersects "$learn_tags"  "$tdd_kw";    then printf 'MATCH'; return 0; fi
  printf 'NOMATCH'
}

# Score a well-formed fixture pair and assert the expected result. Called at TOP
# LEVEL (never inside a `$(...)`), so when mech_prefilter's integrity guard trips
# `_fatal`, the exit 2 propagates here and aborts the whole run — a broken fixture
# is an infra failure, never a MATCH/NOMATCH result to score. Any non-zero status
# (not just 2) is treated as that infra failure; a rc=1 is never swallowed.
assert_prefilter() {  # <learnings-file> <tdd-file> <expected MATCH|NOMATCH> <label>
  local out rc
  out="$(mech_prefilter "$1" "$2")"; rc=$?
  [ "$rc" -eq 0 ] || _fatal "mech_prefilter signalled failure (rc=$rc) on a well-formed fixture pair ($1 vs $2) — infra/parse failure, not a result"
  [ "$out" = "$3" ] \
    && ok "$4" \
    || bad "$4 (expected $3, got '$out')"
}

echo "[S3] mechanical pre-filter floor: files/tags overlap surfaces; no overlap stays silent"

# Fixture LEARNINGS.md entry (TDD 0022's `## L-NNN` schema) hinting one file + tags.
LFIX="$ROOT/LEARNINGS.md"
cat >"$LFIX" <<'EOF' || { echo "FATAL: cannot write fixture LEARNINGS.md" >&2; exit 2; }
# Build-phase learnings (accepted)

## L-001: state-persistence-atomicity
- Pattern class: state-persistence
- Recurred across: 0014-foo, 0020-bar (first observed run 20260501-000000)
- Severity range: major–major
- Subject-area hints: files=[scripts/lib/state.sh] tags=[atomicity, persistence]
- Flags: structural=false rework=true
- Summary: state writes must be atomic temp-file + mv to survive concurrent runs
- Representative evidence: "non-atomic write to state.sh truncated under concurrency"
EOF

# §3 overlap: a TDD whose `## Touched files` includes scripts/lib/state.sh.
T_FILE="$ROOT/overlap.tdd.md"
cat >"$T_FILE" <<'EOF' || { echo "FATAL: cannot write overlap fixture" >&2; exit 2; }
# TDD 9001: rework the resume cursor
Status: draft
PRD refs: FR-99

## Touched files
- scripts/lib/state.sh — adjust the persisted resume cursor
- scripts/implement.sh — call site
EOF

# tags-only overlap: no shared file, but the title carries a tag keyword.
T_TAG="$ROOT/tagmatch.tdd.md"
cat >"$T_TAG" <<'EOF' || { echo "FATAL: cannot write tag-match fixture" >&2; exit 2; }
# TDD 9003: queue persistence hardening
Status: draft
PRD refs: FR-50

## Touched files
- scripts/lib/queue.sh — new queue persistence layer
EOF

# §4 no overlap: docs-only TDD, unrelated PRD ref, no file or tag intersection.
T_NONE="$ROOT/nooverlap.tdd.md"
cat >"$T_NONE" <<'EOF' || { echo "FATAL: cannot write no-overlap fixture" >&2; exit 2; }
# TDD 9002: clarify PRD wording
Status: draft
PRD refs: FR-12

## Touched files
- docs/PRD.md — clarify a requirement's wording
EOF

assert_prefilter "$LFIX" "$T_FILE" MATCH \
  "§3 file overlap (scripts/lib/state.sh) surfaces the learning"
assert_prefilter "$LFIX" "$T_TAG" MATCH \
  "tags= overlap (title keyword) surfaces the learning with no shared file"
assert_prefilter "$LFIX" "$T_NONE" NOMATCH \
  "§4 no file/tag overlap surfaces nothing (FR-73 negative case)"

# Silent-failure guards: a malformed fixture (no Subject-area hints line, no
# `## Touched files`, no title/PRD-ref keywords) leaves an extraction empty. An
# empty extraction that silently returns NOMATCH would let a broken fixture be
# mis-scored as a legitimate "no match" — the false-result-on-infrastructure-
# failure class. The predicate must instead ABORT (exit 2) on a broken parse.
echo "[S3-guard] malformed fixtures FATAL (exit 2) rather than silently scoring NOMATCH"

BADL="$ROOT/bad-learnings.md"
printf '## L-001: x\n- Summary: an entry that lost its Subject-area hints line\n' >"$BADL" \
  || { echo "FATAL: cannot write bad-learnings fixture" >&2; exit 2; }
( mech_prefilter "$BADL" "$T_FILE" >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 2 ] \
  && ok "a learning with no 'Subject-area hints' line FATALs (rc=2), not a silent NOMATCH" \
  || bad "missing 'Subject-area hints' must abort the parse, got rc=$rc"

BADT="$ROOT/bad-touched.tdd.md"
printf '# TDD 9004: no touched-files section\nStatus: draft\nPRD refs: FR-1\n' >"$BADT" \
  || { echo "FATAL: cannot write bad-touched fixture" >&2; exit 2; }
( mech_prefilter "$LFIX" "$BADT" >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 2 ] \
  && ok "a TDD with no '## Touched files' paths FATALs (rc=2), not a silent NOMATCH" \
  || bad "missing '## Touched files' must abort the parse, got rc=$rc"

BADK="$ROOT/bad-title.tdd.md"
printf '## Touched files\n- scripts/lib/queue.sh — body only, no title or PRD refs\n' >"$BADK" \
  || { echo "FATAL: cannot write bad-title fixture" >&2; exit 2; }
( mech_prefilter "$LFIX" "$BADK" >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 2 ] \
  && ok "a TDD with no title/PRD-ref keywords FATALs (rc=2), not a silent NOMATCH" \
  || bad "missing title/PRD-ref keywords must abort the parse, got rc=$rc"

# The good-path scorer must PROPAGATE a guard trip as a whole-run abort, not
# absorb it in a command-substitution subshell and downgrade it to a content
# fail. Run assert_prefilter against a malformed fixture in a subshell and
# confirm the subshell exits 2 (the FATAL reached script level, not just the
# inner $(...)).
( assert_prefilter "$BADL" "$T_FILE" MATCH "unreachable" >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 2 ] \
  && ok "assert_prefilter propagates a guard trip as a FATAL script abort (rc=2)" \
  || bad "assert_prefilter must abort the run (exit 2) on a guard trip, got rc=$rc"

# --- summary ------------------------------------------------------------------
echo
[ -s "$RESULTS" ] || { echo "FATAL: no assertions were recorded — failing rather than vacuously passing" >&2; exit 2; }
PASS="$(grep -c '^ok$'   "$RESULTS")" || PASS=0
FAIL="$(grep -c '^fail$' "$RESULTS")" || FAIL=0
TOTAL=$((PASS + FAIL))
[ "$TOTAL" -gt 0 ] || { echo "FATAL: 0 assertions ran" >&2; exit 2; }
echo "=== learnings-inform-tdd-author eval: $PASS passed, $FAIL failed (of $TOTAL) ==="
[ "$FAIL" -eq 0 ]

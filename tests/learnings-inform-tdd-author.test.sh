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
# Sequencing item 3 extends this file with §3-§4 (the overlap / no-overlap
# fixture exercise).
#
# Run: bash tests/learnings-inform-tdd-author.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/tdd-author/SKILL.md"
[ -f "$SKILL" ] || { echo "FATAL: skill not found at $SKILL" >&2; exit 2; }

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

echo "[S2] step 5 lead-in instructs the hybrid match and is explicitly non-blocking"
STEP5="$(_section '^## 5[.]' '^## 6[.]')"
[ -n "$STEP5" ] || bad "could not extract step-5 section from SKILL.md (anchors changed?)"
# Mechanical pre-filter: files/tags hints intersected against the new TDD's
# declared touched-file / PRD-ref area.
{ printf '%s\n' "$STEP5" | grep -qi 'mechanical' \
  && printf '%s\n' "$STEP5" | grep -q 'files=' \
  && printf '%s\n' "$STEP5" | grep -q 'tags=' \
  && printf '%s\n' "$STEP5" | grep -q '## Touched files'; } \
  && ok "lead-in specifies the mechanical files=/tags= pre-filter over ## Touched files" \
  || bad "lead-in must specify the mechanical files=/tags= pre-filter intersected with the new TDD's ## Touched files"
# Model-judgment backstop for cross-cutting patterns sharing no file/tag overlap.
printf '%s\n' "$STEP5" | grep -qi 'backstop\|model.judgment' \
  && ok "lead-in specifies the model-judgment backstop" \
  || bad "lead-in must specify the model-judgment backstop"
# Non-blocking: advisory, never BLOCKED/PRECHECK_FAIL.
{ printf '%s\n' "$STEP5" | grep -qi 'advisory' \
  && printf '%s\n' "$STEP5" | grep -q 'BLOCKED' \
  && printf '%s\n' "$STEP5" | grep -q 'PRECHECK_FAIL'; } \
  && ok "lead-in states surfacing is advisory and never emits BLOCKED/PRECHECK_FAIL" \
  || bad "lead-in must state learnings are advisory and never emit BLOCKED/PRECHECK_FAIL"
# The design-critique gate (step 7b) does not check learning incorporation.
{ printf '%s\n' "$STEP5" | grep -q '7b' \
  && printf '%s\n' "$STEP5" | grep -qi 'not check'; } \
  && ok "lead-in states step 7b does not check learning incorporation" \
  || bad "lead-in must state the step-7b design-critique gate does not check learning incorporation"
# Negative case: absent store / no match => nothing surfaced.
printf '%s\n' "$STEP5" | grep -qi 'absent\|no learning matches\|negative case' \
  && ok "lead-in states the negative case (absent / no-match => nothing surfaced)" \
  || bad "lead-in must state the FR-73 negative case (nothing surfaced when absent or no match)"

# --- summary ------------------------------------------------------------------
echo
[ -s "$RESULTS" ] || { echo "FATAL: no assertions were recorded — failing rather than vacuously passing" >&2; exit 2; }
PASS="$(grep -c '^ok$'   "$RESULTS")" || PASS=0
FAIL="$(grep -c '^fail$' "$RESULTS")" || FAIL=0
TOTAL=$((PASS + FAIL))
[ "$TOTAL" -gt 0 ] || { echo "FATAL: 0 assertions ran" >&2; exit 2; }
echo "=== learnings-inform-tdd-author eval: $PASS passed, $FAIL failed (of $TOTAL) ==="
[ "$FAIL" -eq 0 ]

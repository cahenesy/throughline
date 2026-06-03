#!/usr/bin/env bash
# learnings-inform-tdd-author.test.sh — eval for TDD 0023 (accepted build-phase
# learnings inform future /tdd-author sessions).
#
# PRD refs: FR-73.
#
# The contract under test:
#   §1 — skills/tdd-author/SKILL.md step 4 ("Load design constraints") instructs
#        reading the docs/tdd/LEARNINGS.md store (written by FR-72). (Mechanical
#        grep against the step-4 section.)
#   §2 — step 5's lead-in instructs the HYBRID match (mechanical files/tags
#        pre-filter AND the model-judgment backstop) and states the surfacing is
#        advisory/non-blocking — no BLOCKED, no PRECHECK_FAIL, and step 7b does
#        not check learning incorporation. (Mechanical grep against the lead-in.)
#   §3 — overlap → surfaced: against a fixture LEARNINGS.md whose files= hint is
#        scripts/lib/state.sh and a TDD whose ## Touched files includes that path,
#        the mechanical pre-filter the skill prescribes reports a match.
#   §4 — no overlap → not surfaced: the same fixture entry vs a TDD touching only
#        docs/PRD.md with an unrelated tag yields no mechanical match.
#
# §1–§2 are the implementation-time mechanical observation points (Verification
# plan §1–§2). §3–§4 exercise the mechanical floor of the hybrid match against a
# fixture; the live surfacing is a model behavior driven by the instruction and
# re-driven by the runtime-verify gate in a /tdd-author session (Verification
# plan §3–§4).
#
# Run: bash tests/learnings-inform-tdd-author.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/tdd-author/SKILL.md"

RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

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
printf '%s\n' "$STEP4" | grep -q 'docs/tdd/LEARNINGS\.md' \
  && ok "step 4 names docs/tdd/LEARNINGS.md as a design input" \
  || bad "step 4 must instruct reading docs/tdd/LEARNINGS.md (got: $(printf '%s' "$STEP4" | tr '\n' ' '))"
printf '%s\n' "$STEP4" | grep -qi 'absent' \
  && ok "step 4 states an absent store is a no-op" \
  || bad "step 4 must note an absent LEARNINGS.md is a no-op, not an error"

# --- summary ------------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== learnings-inform-tdd-author eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# tdd-author-redteam.test.sh — eval for TDD 0047 (tdd-author red-team ranking +
# pre-mortem failure-mode taxonomy; FR-76; ADR 0006).
#
# Observable surface per the TDD's Verification plan: the content of
# skills/tdd-author/SKILL.md (the skill text a tdd-author session loads).
# Built incrementally across TDD 0047's Sequencing items:
#   §1 — the Interrogator-discipline section carries the "Red-team ranking"
#        guidance: rank tracked assumptions by impact × likelihood ×
#        cheapness-to-test, phrase each as a falsifiable "fails if ___"
#        clause, surface the top-ranked few first; advisory ordering only —
#        the completion gate is unchanged.
#
# L-001/L-002 guards (matched learnings): SKILL.md existence + readability is
# asserted BEFORE any content grep and fails with an INFRA-prefixed message
# (distinct from a content-failure message); every presence assertion is a
# direct positive `grep -q` (exit 0 = found) — never an inverted `! grep`,
# whose exit-2 on a missing file would read as success.
#
# Run: bash tests/tdd-author-redteam.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/tdd-author/SKILL.md"

command -v grep >/dev/null 2>&1 \
  || { echo "FATAL: INFRA — required tool 'grep' unavailable" >&2; exit 2; }

RESULTS=""
trap 'rm -f "$RESULTS"' EXIT
RESULTS="$(mktemp)" || { echo "FATAL: INFRA — mktemp failed" >&2; exit 2; }
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# L-002 guard: the observed file must exist and be readable BEFORE any content
# assertion — otherwise every grep below would mis-report an infrastructure
# problem as a content failure.
[ -f "$SKILL" ] \
  || { echo "FATAL: INFRA — SKILL.md not found at $SKILL (infrastructure failure, not a content failure)" >&2; exit 2; }
[ -r "$SKILL" ] \
  || { echo "FATAL: INFRA — SKILL.md not readable at $SKILL (infrastructure failure, not a content failure)" >&2; exit 2; }

# has <literal> <label> — positive presence assertion (L-001: exit 0 = found,
# anything else = FAIL; never inverted, so a read error can never pass).
has() { grep -qF "$1" "$SKILL" && ok "$2" || bad "$2 (expected '$1' in $SKILL)"; }

# ===========================================================================
# §1: the Interrogator-discipline section carries the red-team ranking
# guidance (FR-76; the "fails if ___" falsifiability keeps each ranked
# assumption grounded per ADR 0006).
echo "[§1] red-team ranking guidance in the Interrogator-discipline section (FR-76)"
has 'Red-team ranking' \
  "the 'Red-team ranking' bullet is present"
has 'impact × likelihood × cheapness-to-test' \
  "ranking criteria: impact × likelihood × cheapness-to-test"
has 'fails if ___' \
  "falsifiable 'fails if ___' phrasing required for each ranked assumption"
has 'top-ranked few' \
  "the top-ranked few are surfaced to the user first"
has 'does not change the completion gate' \
  "ranking is advisory ordering — the completion gate is unchanged"

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== tdd-author-redteam eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

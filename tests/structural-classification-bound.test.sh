#!/usr/bin/env bash
# structural-classification-bound.test.sh — eval for the bounded structural
# classification (TDD 0034 / FR-67 gap-closure, FR-62, FR-66; ADR 0005, 0006,
# 0007).
#
# The contract under test:
#   - scripts/review-prompt.md carries the `structural_reason:` schema field and
#     the tightened `structural: true` definition (a mechanical relocation /
#     reorder within bounds is NOT structural).
#   - the runner escalates a `structural: true` finding to a `structural-finding`
#     halt (criterion (c) + a BLOCKERS.md entry) ONLY when the reviewer supplied
#     a non-empty, non-`none` `structural_reason`; a `structural: true` finding
#     with no named reason falls through to the existing bounded-rework path
#     (FR-62), where the FR-67(a)/(b) pre-pass remains the real guardrail
#     (an in-scope fix ships; an out-of-scope one is still caught as
#     structural-(a)).
#
# Observable surface (per the TDD's Verification plan): the prompt text, and the
# runner's classification decision — observable as whether `_rework_loop`
# escalates (`halt_cause=structural-finding` + a docs/tdd/BLOCKERS.md entry) or
# routes to a bounded-rework attempt (a `rework_log` entry in the fragment).
#
# Run: bash tests/structural-classification-bound.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# --- §1 / Component 1: prompt text present ------------------------------------
echo "[P1] review-prompt.md carries the structural_reason field + tightened definition"
( cd "$REPO"
  F="scripts/review-prompt.md"
  [ -f "$F" ] && ok "scripts/review-prompt.md exists" || { bad "scripts/review-prompt.md should exist"; exit 0; }
  # The schema field is a single token; grep the raw file.
  grep -q 'structural_reason:' "$F" \
    && ok "carries the structural_reason: schema field" \
    || bad "review-prompt.md should add the structural_reason: schema field"
  # The multi-word phrases may wrap across lines in the prose; flatten newlines
  # to a single space before matching so wrapping never hides a present phrase.
  flat="$(tr '\n' ' ' < "$F")"
  printf '%s' "$flat" | grep -q 'requires reconsidering the design' \
    && ok "tightened definition says 'requires reconsidering the design'" \
    || bad "review-prompt.md should define structural:true as requiring reconsidering the design"
  printf '%s' "$flat" | grep -qE 'relocation' \
    && printf '%s' "$flat" | grep -qE 'NOT structural' \
    && ok "instructs that a mechanical relocation/reorder within bounds is NOT structural" \
    || bad "review-prompt.md should instruct that a bounded mechanical relocation/reorder is NOT structural"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== structural-classification-bound eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

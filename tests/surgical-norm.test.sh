#!/usr/bin/env bash
# surgical-norm.test.sh — eval for TDD 0046 (surgical-changes build norm;
# FR-66, FR-74; ADR 0005, 0007, 0008).
#
# The norm is prompt guidance only (ADR 0005: enforcement stays the FR-66
# mechanical cap + the review gate — no new gate). Observation point per the
# TDD's verification plan: the text each `claude -p` actually receives —
# render build-prompt.md via _render_build_prompt (the runner's render path)
# and rework-prompt.md via _rework_one's template load — then grep the
# RENDERED output, not the raw template.
#   §1 build prompt: the surgical-changes norm AND its carve-out (the three
#      required-change classes named, so a future edit cannot drop the
#      carve-out and reintroduce the doc-update contradiction); control: the
#      mandated "Keep docs in sync IN THIS COMMIT" duty is still present.
#
# Run: bash tests/surgical-norm.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS=""; ROOT=""
trap 'rm -rf "$ROOT"; rm -f "$RESULTS"' EXIT
RESULTS="$(mktemp)"; ROOT="$(mktemp -d)"
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# ===========================================================================
# §1: the rendered build prompt carries the surgical-changes norm with its
# carve-out, and the norm did not displace the mandated doc-sync duty.
echo "[§1] rendered build prompt: surgical-changes norm + carve-out; doc-sync duty intact"
( TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §1 — source guard missing"; exit 0; }
  export TMPL="$REPO/scripts/build-prompt.md"; unset STATE_DIR
  prompt="$(_render_build_prompt 0046-x docs/tdd/0046-x.md)"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$prompt" ]; then
    bad "INFRA: §1 — could not render the build prompt (rc=$rc)"; exit 0
  fi
  has() { printf '%s' "$prompt" | grep -qF "$1" && ok "$2" || bad "$2 (expected '$1' in rendered prompt)"; }
  has '**Surgical changes.**'           "the surgical-changes norm bullet is present"
  has 'must trace to the requirement'   "norm: every changed line traces to the requirement being built"
  has 'refactor adjacent code'          "norm: no improving/refactoring adjacent code that was only read"
  has 'match the existing style'        "norm: match the existing style, not impose one"
  has 'nothing speculative'             "norm: no speculative additions"
  has 'CARVE-OUT'                       "the required-changes carve-out clause is present"
  has 'failing-test-first commit'       "carve-out names the failing-test-first commit"
  has 'stale-doc updates'               "carve-out names same-commit stale-doc updates"
  has 'superseding an accepted ADR'     "carve-out names accepted-ADR/design-doc supersession"
  has 'not when it is zero'             "carve-out: a required change's minimum is not zero"
  has 'Keep docs in sync IN THIS COMMIT' "control: the mandated doc-sync duty is still present"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== surgical-norm eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

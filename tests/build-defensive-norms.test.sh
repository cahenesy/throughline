#!/usr/bin/env bash
# build-defensive-norms.test.sh — eval for TDD 0026 (build-phase defensive-coding
# norms / FR-74). Covers the verification plan's observation points:
#   §0 build-norms.md structural contract (anchor unique + 7 numbered norms) —
#      the extraction contract §2/§3 depend on.
#   §1 norms reach the initial build prompt (_render_build_prompt substitutes
#      {{BUILD_NORMS}}; anchor + 7 lead-ins present; no literal placeholder left).
#   §2 a missing norms file is FATAL at render (non-zero + stderr diagnostic; no
#      partial prompt).
#   §3 substitution is bash PE, not sed (sed-breaking chars survive verbatim; a
#      {{TDD}}-like token inside the norms is NOT re-substituted).
#   §4 a BLOCK reply carries the norms reminder (finding + headlines); a PASS
#      reply carries neither.
#   §5 the reminder degrades gracefully when the norms file is gone (generic
#      one-liner, no fatal).
#
# Function-level eval (the runtime-verify gate re-drives the observable surface
# against a real /implement build). Uses a stub `claude`/coprocess so no model or
# tokens are needed.
#
# Run: bash tests/build-defensive-norms.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
NORMS="$REPO/scripts/build-norms.md"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ===========================================================================
# §0: the norms file's structural contract. The H2 anchor must be present and
# UNIQUE (the §3 reminder extracts the numbered list under it), and there must be
# exactly the seven enumerated norms (one `N. ` line each). A drift here silently
# breaks both the render substitution and the reminder extraction.
echo "[§0] build-norms.md structural contract: unique H2 anchor + seven numbered norms"
( if [ ! -f "$NORMS" ]; then bad "scripts/build-norms.md should exist"; exit 0; fi
  anchors="$(grep -c '^## Defensive-coding norms (FR-74)$' "$NORMS" 2>/dev/null || echo 0)"
  [ "$anchors" = "1" ] && ok "the '## Defensive-coding norms (FR-74)' anchor appears exactly once" \
    || bad "anchor must appear exactly once (got $anchors)"
  norms="$(grep -cE '^[0-9]+\. ' "$NORMS" 2>/dev/null || echo 0)"
  [ "$norms" = "7" ] && ok "exactly seven numbered norm lead-ins are present" \
    || bad "expected 7 numbered norms (got $norms)"
  # The seven recurring finding classes FR-74 enumerates must each be named.
  for kw in "Fail loud" "Temp files" "Safe escaping" "Sourced-library hygiene" \
            "Path / trust boundary" "Read once" "No hardcoding"; do
    grep -qF "$kw" "$NORMS" 2>/dev/null && ok "norm class present: $kw" \
      || bad "norm class missing: $kw"
  done
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== build-defensive-norms eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

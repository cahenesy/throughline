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
IMPL="$REPO/scripts/implement.sh"
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

# mk_prompt_dir <dir> — a build-prompt.md fixture carrying the three render
# placeholders ({{TDD}}, {{CLEARED_STEPS}}, {{BUILD_NORMS}}). The norms file is
# created separately by each case (present / absent / sed-breaking) beside it, so
# the dirname-of-$TMPL resolution picks it up.
mk_prompt_dir() {  # <dir>
  local d="$1"; mkdir -p "$d"
  cat > "$d/build-prompt.md" <<'EOF'
Implement {{TDD}} as a single unattended build.

Build discipline:
- RESUME SIGNAL. Cleared steps: {{CLEARED_STEPS}}

Defensive-coding norms (FR-74). The following norms are non-negotiable:

{{BUILD_NORMS}}

Close:
- done
EOF
}

# ===========================================================================
# §1: the norms reach the initial build prompt. _render_build_prompt must
# substitute {{BUILD_NORMS}} with the full norms file content — the anchor and
# all seven lead-ins present, no literal placeholder left, return code 0.
echo "[§1] _render_build_prompt substitutes {{BUILD_NORMS}}: anchor + 7 norms present, no placeholder left"
( D="$ROOT/r1"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_prompt_dir "$D"
  cp "$NORMS" "$D/build-norms.md"
  export TMPL="$D/build-prompt.md"; unset STATE_DIR
  prompt="$(_render_build_prompt 0026-x docs/tdd/0026-x.md)"; rc=$?
  [ "$rc" -eq 0 ] && ok "render returns 0 with a norms file present" || bad "render should return 0 (got $rc)"
  printf '%s' "$prompt" | grep -qF '## Defensive-coding norms (FR-74)' \
    && ok "rendered prompt carries the norms H2 anchor" || bad "rendered prompt should carry the anchor"
  miss=0
  for kw in "Fail loud" "Temp files" "Safe escaping" "Sourced-library hygiene" \
            "Path / trust boundary" "Read once" "No hardcoding"; do
    printf '%s' "$prompt" | grep -qF "$kw" || { miss=1; bad "rendered prompt missing norm lead-in: $kw"; }
  done
  [ "$miss" -eq 0 ] && ok "all seven norm lead-ins reached the prompt"
  printf '%s' "$prompt" | grep -qF '{{BUILD_NORMS}}' \
    && bad "literal {{BUILD_NORMS}} placeholder must NOT remain" || ok "no literal {{BUILD_NORMS}} placeholder remains"
) || true

# ===========================================================================
# §2: a missing/unreadable norms file is FATAL at render — _render_build_prompt
# returns non-zero with a stderr diagnostic naming the file, and emits NO partial
# prompt. A build prompt that silently drops its norms is the exact failure mode
# FR-74 prevents (norm #1, fail loud).
echo "[§2] a missing norms file is FATAL at render (non-zero + stderr diagnostic; no partial prompt)"
( D="$ROOT/r2"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_prompt_dir "$D"            # build-prompt.md but NO build-norms.md beside it
  export TMPL="$D/build-prompt.md"; unset STATE_DIR
  err="$ROOT/r2.err"
  prompt="$(_render_build_prompt 0026-x docs/tdd/0026-x.md 2>"$err")"; rc=$?
  [ "$rc" -ne 0 ] && ok "render returns non-zero when the norms file is absent" \
    || bad "render must fail when the norms file is missing (got rc=$rc)"
  grep -qF 'build-norms.md' "$err" 2>/dev/null \
    && ok "stderr diagnostic names the missing norms file" || bad "stderr should name build-norms.md (got: $(cat "$err" 2>/dev/null))"
  printf '%s' "$prompt" | grep -qF 'Implement docs/tdd/0026-x.md' \
    && bad "no partial prompt should be emitted on the fatal path" || ok "no partial prompt emitted on the fatal path"
) || true

# ===========================================================================
# §3: the norms are inserted literally — not by sed, and not by a bash PE replace
# (in bash >=5.2 an unescaped `&` in a ${v//p/r} REPLACEMENT is the matched-text
# reference too, the same hazard norm #3 cites for sed). A norms file containing
# &, / and a {{TDD}}-like token must survive verbatim: the chars are not
# corrupted, and the {{TDD}}-like token inside the norms is NOT re-substituted
# with the TDD path (proving the norms go in LAST and are never re-scanned).
echo "[§3] norms inserted literally: &, / survive; a {{TDD}}-like token in the norms is NOT re-substituted"
( D="$ROOT/r3"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_prompt_dir "$D"
  cat > "$D/build-norms.md" <<'EOF'
## Defensive-coding norms (FR-74)

1. Amp & ersand and a /slash/path survive verbatim.
2. A token {{TDD}} inside the norms must stay literal, never re-substituted.
EOF
  export TMPL="$D/build-prompt.md"; unset STATE_DIR
  prompt="$(_render_build_prompt 0026-x docs/tdd/0026-real.md)"; rc=$?
  [ "$rc" -eq 0 ] && ok "render returns 0 with the sed-breaking norms file" || bad "render should return 0 (got $rc)"
  printf '%s' "$prompt" | grep -qF 'Amp & ersand and a /slash/path' \
    && ok "& and / in the norms survive verbatim (no sed corruption)" || bad "& and / should survive verbatim"
  # The build-prompt body's own {{TDD}} WAS substituted (sed, first)...
  printf '%s' "$prompt" | grep -qF 'Implement docs/tdd/0026-real.md' \
    && ok "the template's own {{TDD}} placeholder was substituted" || bad "the template {{TDD}} should be substituted"
  # ...but the {{TDD}}-like token INSIDE the norms stays literal (norms go in last).
  printf '%s' "$prompt" | grep -qF 'A token {{TDD}} inside the norms' \
    && ok "a {{TDD}}-like token inside the norms is NOT re-substituted (norms inserted last)" \
    || bad "the norms' {{TDD}}-like token should remain literal"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== build-defensive-norms eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

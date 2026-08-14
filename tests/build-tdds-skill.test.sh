#!/usr/bin/env bash
# build-tdds-skill.test.sh — eval for TDD 0062 / FR-13, FR-80, FR-85:
# pins /build-tdds skill name, action language, resume next-gate, models.sh.
#
# Written red-first. Run: bash tests/build-tdds-skill.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/implement/SKILL.md"
MODELS="$REPO/scripts/lib/models.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$RESULTS"' EXIT

# --- [A] frontmatter name is build-tdds, not implement (obs 1) ---------------
echo "[A] skill frontmatter name is build-tdds"
( head="$(sed -n '1,8p' "$SKILL")"
  printf '%s\n' "$head" | grep -q 'name: build-tdds' \
    && ok "frontmatter contains name: build-tdds" \
    || bad "frontmatter missing name: build-tdds"
  printf '%s\n' "$head" | grep -q 'name: implement' \
    && bad "frontmatter still has name: implement" \
    || ok "frontmatter does not contain name: implement"
) || true

# --- [B] no vendor CLI/tool names (obs 2) ------------------------------------
echo "[B] skill does not require claude -p or AskUserQuestion"
( hits="$(grep -nE 'claude -p|AskUserQuestion' "$SKILL" || true)"
  [ -z "$hits" ] && ok "no claude -p / AskUserQuestion" \
    || bad "vendor names still present:"$'\n'"$hits"
) || true

# --- [C] algorithm anchors (obs 3) -------------------------------------------
echo "[C] skill names require_flip, next_gate, tokens, no nested spawn"
( grep -q 'tl_verdict_require_flip' "$SKILL" \
    && ok "mentions tl_verdict_require_flip" \
    || bad "missing tl_verdict_require_flip"
  grep -q 'tl_run_next_gate' "$SKILL" \
    && ok "mentions tl_run_next_gate" \
    || bad "missing tl_run_next_gate"
  grep -q 'BUILD_RESULT' "$SKILL" \
    && ok "mentions BUILD_RESULT" \
    || bad "missing BUILD_RESULT"
  grep -q 'VERIFY_RESULT' "$SKILL" \
    && ok "mentions VERIFY_RESULT" \
    || bad "missing VERIFY_RESULT"
  grep -q 'must not spawn children' "$SKILL" \
    && ok "forbids nested worker-spawn" \
    || bad "missing 'must not spawn children'"
) || true

# --- [D] models.sh is the ADR 0009 binding site ------------------------------
echo "[D] models.sh binds tl_resolve_models"
( bash -n "$MODELS" 2>"$ROOT/D.err" \
    && ok "models.sh parses" \
    || bad "models.sh bash -n failed: $(cat "$ROOT/D.err" 2>/dev/null)"
  if env -u GROK_PLUGIN_ROOT -u THROUGHLINE_BUILD_MODEL \
        -u THROUGHLINE_REVIEW_MODEL -u THROUGHLINE_RUNTIME_VERIFY_MODEL \
        bash -c "source \"$MODELS\"; tl_resolve_models" >"$ROOT/D.out" 2>"$ROOT/D2.err"; then
    out="$(cat "$ROOT/D.out")"
    printf '%s' "$out" | grep -qE '^build=.+ review=.+ verify=.+$' \
      && ok "prints build= review= verify= ($out)" \
      || bad "unexpected resolve line: $out"
  else
    bad "tl_resolve_models failed: $(cat "$ROOT/D2.err")"
  fi
  grep -q 'tl_resolve_models' "$MODELS" \
    && ok "models.sh contains tl_resolve_models" \
    || bad "models.sh missing tl_resolve_models"
) || true

# --- [E] next_gate after implementer-only run is not flip (obs 4) ------------
echo "[E] implementer-only run → next_gate is first missing gate, not flip"
( R="$ROOT/e"; mkdir -p "$R"
  bash -c "
    set -uo pipefail
    source \"$REPO/scripts/lib/run-record.sh\"
    source \"$REPO/scripts/lib/verdicts.sh\"
    tl_run_init \"$R\" r
    tl_run_set_tdd \"$R\" r slug building
  "
  g="$(bash -c "set -uo pipefail; source \"$REPO/scripts/lib/run-record.sh\"; tl_run_next_gate \"$R\" r slug")"
  [ "$g" = "test-first" ] && ok "three verdicts missing → next_gate=test-first" \
    || bad "next_gate='$g' want test-first (not flip)"
  [ "$g" != "flip" ] && ok "next_gate is not flip" || bad "next_gate was flip"
) || true

# --- [F] skill never passes worktree as repo-root ----------------------------
echo "[F] skill tells the parent to pass integration REPO, never the worktree"
( grep -q 'Never pass the build worktree path as <repo-root>' "$SKILL" \
    && ok "repo-root vs worktree rule present" \
    || bad "missing worktree-is-not-repo-root rule"
  grep -q 'tl_plugin_root' "$SKILL" \
    && ok "resolves plugin tree via tl_plugin_root" \
    || bad "skill does not use tl_plugin_root"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== build-tdds-skill eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

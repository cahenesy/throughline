#!/usr/bin/env bash
# plugin-root.test.sh — eval for TDD 0060 / FR-79, FR-81, FR-34:
# pins scripts/lib/plugin-root.sh::tl_plugin_root and ::tl_plugin_data.
#
# Written red-first: before TDD 0060 lands, plugin-root.sh does not exist, so
# [A] fails on `bash -n` and every behavioral case errors out. The
# implementation commit makes them green.
#
# tl_plugin_root prints the first of $CLAUDE_PLUGIN_ROOT, $GROK_PLUGIN_ROOT
# that names an existing directory. No path probing, no git lookup. Both
# unset, or neither path a directory → rc 1 and a diagnostic naming both
# env vars. tl_plugin_data is the first of $CLAUDE_PLUGIN_DATA,
# $GROK_PLUGIN_DATA (fail closed); it may export THROUGHLINE_PLUGIN_DATA.
#
# Run: bash tests/plugin-root.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib/plugin-root.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT" "$RESULTS"' EXIT

# Source under a clean env so a leaked CLAUDE_PLUGIN_ROOT from the host
# session cannot satisfy a "unset both" case. Each case sets what it needs.
run_root() { # env assignments... -- <function>
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      *)  args+=("$1"); shift ;;
    esac
  done
  env -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
      -u CLAUDE_PLUGIN_DATA -u GROK_PLUGIN_DATA \
      -u THROUGHLINE_PLUGIN_DATA \
      "${args[@]}" \
      bash -c "set -uo pipefail; source \"$LIB\"; $*"
}

# --- [A] plugin-root.sh parses + sources standalone --------------------------
echo "[A] plugin-root.sh parses + sources in isolation"
( bash -n "$LIB" 2>"$ROOT/A.err" \
    && ok "plugin-root.sh parses (bash -n)" \
    || bad "plugin-root.sh failed bash -n: $(cat "$ROOT/A.err" 2>/dev/null)"
  if bash -c "set -uo pipefail; source \"$LIB\"; type -t tl_plugin_root >/dev/null && type -t tl_plugin_data >/dev/null" 2>"$ROOT/A2.err"; then
    ok "plugin-root.sh sources standalone and binds both functions"
  else
    bad "plugin-root.sh failed to source standalone: $(cat "$ROOT/A2.err" 2>/dev/null)"
  fi
) || true

# --- [B] both ROOT env vars unset → rc 1 + diagnostic ------------------------
echo "[B] tl_plugin_root fails closed when both ROOT vars are unset"
( set +e
  out="$(run_root -- 'tl_plugin_root' 2>"$ROOT/B.err")"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] && ok "unset both ROOT vars → rc 1 (got $rc)" \
                  || bad "unset both ROOT vars: expected rc 1, got $rc (out='$out')"
  if grep -q 'CLAUDE_PLUGIN_ROOT or GROK_PLUGIN_ROOT' "$ROOT/B.err"; then
    ok "stderr names CLAUDE_PLUGIN_ROOT or GROK_PLUGIN_ROOT"
  else
    bad "stderr missing required diagnostic (got: $(cat "$ROOT/B.err"))"
  fi
  [ -z "$out" ] && ok "stdout is empty on fail-closed" \
                || bad "stdout not empty on fail-closed (got '$out')"
) || true

# --- [C] CLAUDE_PLUGIN_ROOT that is an existing dir wins ---------------------
echo "[C] CLAUDE_PLUGIN_ROOT (existing dir) wins"
( mkdir -p "$ROOT/claude-root"
  set +e
  out="$(run_root CLAUDE_PLUGIN_ROOT="$ROOT/claude-root" -- 'tl_plugin_root')"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && [ "$out" = "$ROOT/claude-root" ] \
    && ok "CLAUDE_PLUGIN_ROOT existing dir printed + rc 0" \
    || bad "CLAUDE_PLUGIN_ROOT existing dir: rc=$rc out='$out' want='$ROOT/claude-root'"
) || true

# --- [D] only GROK_PLUGIN_ROOT (existing dir) works --------------------------
echo "[D] GROK_PLUGIN_ROOT alone (existing dir) works"
( mkdir -p "$ROOT/grok-root"
  set +e
  out="$(run_root GROK_PLUGIN_ROOT="$ROOT/grok-root" -- 'tl_plugin_root')"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && [ "$out" = "$ROOT/grok-root" ] \
    && ok "GROK_PLUGIN_ROOT existing dir printed + rc 0" \
    || bad "GROK_PLUGIN_ROOT existing dir: rc=$rc out='$out' want='$ROOT/grok-root'"
) || true

# --- [E] set-but-not-a-directory fails closed --------------------------------
echo "[E] a set-but-not-a-directory ROOT value fails closed"
( : > "$ROOT/not-a-dir"
  set +e
  out="$(run_root CLAUDE_PLUGIN_ROOT="$ROOT/not-a-dir" -- 'tl_plugin_root' 2>"$ROOT/E.err")"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] && ok "file-not-dir CLAUDE_PLUGIN_ROOT → rc 1" \
                  || bad "file-not-dir CLAUDE_PLUGIN_ROOT: expected rc 1, got $rc out='$out'"
  grep -q 'CLAUDE_PLUGIN_ROOT or GROK_PLUGIN_ROOT' "$ROOT/E.err" \
    && ok "not-a-dir case emits the same fail-closed diagnostic" \
    || bad "not-a-dir stderr missing diagnostic (got: $(cat "$ROOT/E.err"))"

  set +e
  out2="$(run_root GROK_PLUGIN_ROOT="$ROOT/not-a-dir" -- 'tl_plugin_root' 2>"$ROOT/E2.err")"
  rc2=$?
  set -e
  [ "$rc2" -eq 1 ] && ok "file-not-dir GROK_PLUGIN_ROOT → rc 1" \
                   || bad "file-not-dir GROK_PLUGIN_ROOT: expected rc 1, got $rc2 out='$out2'"
) || true

# --- [F] CLAUDE_PLUGIN_ROOT wins when both are existing dirs -----------------
echo "[F] CLAUDE_PLUGIN_ROOT takes precedence over GROK_PLUGIN_ROOT"
( mkdir -p "$ROOT/both-claude" "$ROOT/both-grok"
  set +e
  out="$(run_root CLAUDE_PLUGIN_ROOT="$ROOT/both-claude" \
                  GROK_PLUGIN_ROOT="$ROOT/both-grok" -- 'tl_plugin_root')"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && [ "$out" = "$ROOT/both-claude" ] \
    && ok "both set → CLAUDE_PLUGIN_ROOT wins" \
    || bad "both set: rc=$rc out='$out' want='$ROOT/both-claude'"
) || true

# --- [G] CLAUDE set but not a dir, GROK is a dir → GROK (first *valid*) ------
# The contract is "first of CLAUDE, GROK that is an existing directory".
# A set-but-invalid CLAUDE does not shadow a valid GROK.
echo "[G] invalid CLAUDE_PLUGIN_ROOT does not shadow a valid GROK_PLUGIN_ROOT"
( mkdir -p "$ROOT/g-grok"; : > "$ROOT/g-claude-file"
  set +e
  out="$(run_root CLAUDE_PLUGIN_ROOT="$ROOT/g-claude-file" \
                  GROK_PLUGIN_ROOT="$ROOT/g-grok" -- 'tl_plugin_root')"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && [ "$out" = "$ROOT/g-grok" ] \
    && ok "invalid CLAUDE + valid GROK → GROK" \
    || bad "invalid CLAUDE + valid GROK: rc=$rc out='$out' want='$ROOT/g-grok'"
) || true

# --- [H] tl_plugin_data: unset both → rc 1 + diagnostic ----------------------
echo "[H] tl_plugin_data fails closed when both DATA vars are unset"
( set +e
  out="$(run_root -- 'tl_plugin_data' 2>"$ROOT/H.err")"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] && ok "unset both DATA vars → rc 1 (got $rc)" \
                  || bad "unset both DATA vars: expected rc 1, got $rc (out='$out')"
  if grep -Eq 'CLAUDE_PLUGIN_DATA or GROK_PLUGIN_DATA' "$ROOT/H.err"; then
    ok "stderr names CLAUDE_PLUGIN_DATA or GROK_PLUGIN_DATA"
  else
    bad "tl_plugin_data stderr missing required diagnostic (got: $(cat "$ROOT/H.err"))"
  fi
) || true

# --- [I] tl_plugin_data: CLAUDE wins; GROK-only works; export ----------------
echo "[I] tl_plugin_data precedence + THROUGHLINE_PLUGIN_DATA export"
( set +e
  out="$(run_root CLAUDE_PLUGIN_DATA="$ROOT/cdata" GROK_PLUGIN_DATA="$ROOT/gdata" \
                  -- 'tl_plugin_data')"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && [ "$out" = "$ROOT/cdata" ] \
    && ok "both DATA set → CLAUDE_PLUGIN_DATA wins" \
    || bad "both DATA set: rc=$rc out='$out' want='$ROOT/cdata'"

  set +e
  out2="$(run_root GROK_PLUGIN_DATA="$ROOT/gdata-only" -- 'tl_plugin_data')"
  rc2=$?
  set -e
  [ "$rc2" -eq 0 ] && [ "$out2" = "$ROOT/gdata-only" ] \
    && ok "GROK_PLUGIN_DATA alone printed + rc 0" \
    || bad "GROK_PLUGIN_DATA alone: rc=$rc2 out='$out2' want='$ROOT/gdata-only'"

  # After a successful call, THROUGHLINE_PLUGIN_DATA is exported as the winner
  # so subsequent helpers can read one name.
  set +e
  exported="$(run_root GROK_PLUGIN_DATA="$ROOT/gdata-only" \
                       -- 'tl_plugin_data >/dev/null; printf %s "$THROUGHLINE_PLUGIN_DATA"')"
  rc3=$?
  set -e
  [ "$rc3" -eq 0 ] && [ "$exported" = "$ROOT/gdata-only" ] \
    && ok "tl_plugin_data exports THROUGHLINE_PLUGIN_DATA as the winner" \
    || bad "THROUGHLINE_PLUGIN_DATA export: rc=$rc3 got='$exported' want='$ROOT/gdata-only'"
) || true

# --- [J] no path probing / git lookup: a valid env wins even outside a repo --
echo "[J] tl_plugin_root does not consult git or cwd"
( mkdir -p "$ROOT/nogit/plugin"
  set +e
  out="$(cd "$ROOT/nogit" && run_root CLAUDE_PLUGIN_ROOT="$ROOT/nogit/plugin" -- 'tl_plugin_root')"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && [ "$out" = "$ROOT/nogit/plugin" ] \
    && ok "works outside a git repo (no git lookup)" \
    || bad "outside git repo: rc=$rc out='$out'"
) || true

# --- [K] five authoring/status skills: no vendor tool/CLI names (FR-81) ------
# TDD 0060 verification observation 3: a case-insensitive search of these
# five files for AskUserQuestion / claude -p / grok -p as required names
# is empty. ${CLAUDE_PLUGIN_ROOT} may remain only as an env *name*.
echo "[K] authoring/status skills name actions, not vendor tools"
SKILLS=(
  "$REPO/skills/prd-author/SKILL.md"
  "$REPO/skills/tdd-author/SKILL.md"
  "$REPO/skills/adr-new/SKILL.md"
  "$REPO/skills/bootstrap-project/SKILL.md"
  "$REPO/skills/implement-status/SKILL.md"
)
( hits="$(grep -nEi 'AskUserQuestion|claude -p|grok -p' "${SKILLS[@]}" 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    ok "five skills contain no AskUserQuestion / claude -p / grok -p"
  else
    bad "vendor tool/CLI names still present:"$'\n'"$hits"
  fi
  for f in "${SKILLS[@]}"; do
    base="$(basename "$(dirname "$f")")"
    # Skills that source plugin scripts must resolve them via tl_plugin_root.
    # adr-new has no plugin-path sources — vendor-name absence is enough.
    if grep -qE 'scripts/lib/|scripts/status\.sh' "$f"; then
      if grep -q 'tl_plugin_root' "$f"; then
        ok "$base resolves plugin paths via tl_plugin_root"
      else
        bad "$base sources plugin scripts but does not use tl_plugin_root"
      fi
    fi
  done
) || true

# --- [L] Grok marketplace index (FR-79 install surface) ----------------------
echo "[L] .grok-plugin/marketplace.json names throughline"
( mf="$REPO/.grok-plugin/marketplace.json"
  if [ -f "$mf" ]; then
    ok "marketplace.json exists"
  else
    bad "marketplace.json missing at $mf"
  fi
  if [ -f "$mf" ] && command -v jq >/dev/null 2>&1; then
    if jq -e '.plugins[0].name=="throughline"' "$mf" >/dev/null; then
      ok "plugins[0].name == throughline"
    else
      bad "plugins[0].name is not throughline ($(jq -c '.plugins[0].name' "$mf" 2>/dev/null))"
    fi
    if jq -e '.plugins[0].source.type=="local" and .plugins[0].source.path=="./"' "$mf" >/dev/null; then
      ok "plugins[0].source is local ./"
    else
      bad "plugins[0].source is not {type:local,path:./}"
    fi
    if jq -e '(.plugins[0].dependencies|length)//0 == 0' "$mf" >/dev/null; then
      ok "no Superpowers/pr-review-toolkit dependency entries (ADR 0010)"
    else
      bad "marketplace lists dependencies (ADR 0010 forbids them)"
    fi
  elif [ -f "$mf" ]; then
    # jq-free fallback matching TDD 0060 observation 4's field.
    if grep -q '"name"[[:space:]]*:[[:space:]]*"throughline"' "$mf"; then
      ok "marketplace.json names throughline (jq-free)"
    else
      bad "marketplace.json does not name throughline"
    fi
  fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== plugin-root eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

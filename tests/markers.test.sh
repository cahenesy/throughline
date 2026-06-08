#!/usr/bin/env bash
# markers.test.sh — eval for TDD 0009 / FR-31 + FR-33: pins the read/write
# contract of scripts/lib/markers.sh for both the committed repo marker and the
# per-developer local marker.
#
# Written red-first: scripts/lib/markers.sh does not exist before TDD 0009, so
# [A] fails on `bash -n` and every roundtrip case errors out.
#
# Contract:
#   tl_repo_marker_read  -> repo marker JSON, or `{}` if absent/malformed.
#   tl_repo_marker_write <plugin_version> <language> <steps_csv>
#       -> writes docs/.throughline-bootstrap.json atomically; schema=1;
#          repo_steps_applied is a JSON array of the CSV; applied_at is set.
#   tl_local_marker_read / tl_local_marker_write <plugin_version> <steps_csv>
#       -> same shape against ${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json.
#   All writes emit VALID JSON (jq/python parse).
#
# Run: bash tests/markers.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RID="$REPO/scripts/lib/repo-id.sh"
LIB="$REPO/scripts/lib/markers.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mkrepo() { local d="$1"; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" remote add origin "git@github.com:acme/$(basename "$d").git"; printf '%s\n' "$d"; }
# Source both libs (markers.sh leans on repo-id.sh for the local-marker path).
SRC="source \"$RID\"; source \"$LIB\""

# --- [A] markers.sh parses + sources standalone ------------------------------
echo "[A] markers.sh parses + sources in isolation"
( bash -n "$LIB" 2>"$ROOT/A.err" \
    && ok "markers.sh parses (bash -n)" \
    || bad "markers.sh failed bash -n: $(cat "$ROOT/A.err" 2>/dev/null)"
  if bash -c "set -uo pipefail; source \"$LIB\"
       for f in tl_repo_marker_read tl_repo_marker_write tl_local_marker_read tl_local_marker_write; do
         type -t \$f >/dev/null || exit 1; done" 2>"$ROOT/A2.err"; then
    ok "markers.sh binds all four read/write functions"
  else
    bad "markers.sh missing a read/write function: $(cat "$ROOT/A2.err" 2>/dev/null)"
  fi
) || true

# --- [B] repo marker read is {} when absent ----------------------------------
echo "[B] tl_repo_marker_read returns {} when no marker exists"
( R="$(mkrepo "$ROOT/b")"
  out="$(cd "$R" && bash -c "$SRC; tl_repo_marker_read")"
  printf '%s' "$out" | jq -e '. == {}' >/dev/null 2>&1 \
    && ok "absent repo marker reads as {}" \
    || bad "absent repo marker did not read as {} (got '$out')"
) || true

# --- [C] repo marker write -> valid JSON with the FR-31 fields ---------------
echo "[C] tl_repo_marker_write writes the FR-31 shape; read returns it"
( R="$(mkrepo "$ROOT/c")"
  ( cd "$R" && bash -c "$SRC; tl_repo_marker_write 3.11.2 shell scaffold,gitignore,git_init" )
  f="$R/docs/.throughline-bootstrap.json"
  if [ -f "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
    ok "marker file exists and is valid JSON"
  else
    bad "marker file missing or invalid JSON"
  fi
  schema="$(jq -r '.schema' "$f" 2>/dev/null)"
  pv="$(jq -r '.plugin_version_applied' "$f" 2>/dev/null)"
  lang="$(jq -r '.language' "$f" 2>/dev/null)"
  steps="$(jq -rc '.repo_steps_applied' "$f" 2>/dev/null)"
  appl="$(jq -r '.applied_at' "$f" 2>/dev/null)"
  [ "$schema" = "1" ] && ok "schema == 1" || bad "schema != 1 (got '$schema')"
  [ "$pv" = "3.11.2" ] && ok "plugin_version_applied recorded" || bad "plugin_version_applied wrong ('$pv')"
  [ "$lang" = "shell" ] && ok "language recorded" || bad "language wrong ('$lang')"
  [ "$steps" = '["scaffold","gitignore","git_init"]' ] \
    && ok "repo_steps_applied is the CSV as a JSON array" \
    || bad "repo_steps_applied wrong ('$steps')"
  printf '%s' "$appl" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$' \
    && ok "applied_at is ISO-8601 UTC" || bad "applied_at not ISO-8601 UTC ('$appl')"
  # read echoes the same JSON
  out="$(cd "$R" && bash -c "$SRC; tl_repo_marker_read")"
  printf '%s' "$out" | jq -e '.plugin_version_applied == "3.11.2"' >/dev/null 2>&1 \
    && ok "tl_repo_marker_read echoes the written marker" \
    || bad "tl_repo_marker_read did not echo the written marker"
) || true

# --- [D] malformed repo marker reads as {} -----------------------------------
echo "[D] tl_repo_marker_read returns {} on a malformed marker"
( R="$(mkrepo "$ROOT/d")"; mkdir -p "$R/docs"
  printf '{ this is not json ' > "$R/docs/.throughline-bootstrap.json"
  out="$(cd "$R" && bash -c "$SRC; tl_repo_marker_read")"
  printf '%s' "$out" | jq -e '. == {}' >/dev/null 2>&1 \
    && ok "malformed repo marker reads as {}" \
    || bad "malformed repo marker did not read as {} (got '$out')"
) || true

# --- [E] empty steps_csv -> empty JSON array ---------------------------------
echo "[E] an empty steps CSV yields an empty JSON array"
( R="$(mkrepo "$ROOT/e")"
  ( cd "$R" && bash -c "$SRC; tl_repo_marker_write 1.0.0 python ''" )
  steps="$(jq -rc '.repo_steps_applied' "$R/docs/.throughline-bootstrap.json" 2>/dev/null)"
  [ "$steps" = '[]' ] && ok "empty CSV -> []" || bad "empty CSV did not yield [] (got '$steps')"
) || true

# --- [F] local marker write/read roundtrip (FR-33 shape) ---------------------
echo "[F] tl_local_marker_write/read roundtrip under CLAUDE_PLUGIN_DATA"
( R="$(mkrepo "$ROOT/f")"; DATA="$ROOT/f-data"
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "$SRC; tl_local_marker_write 3.11.2 deps_installed" )
  id="$(cd "$R" && bash -c "source \"$RID\"; tl_repo_id")"
  f="$DATA/$id/local.json"
  if [ -f "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
    ok "local marker exists and is valid JSON"
  else
    bad "local marker missing or invalid JSON"
  fi
  [ "$(jq -r '.schema' "$f" 2>/dev/null)" = "1" ] && ok "local schema == 1" || bad "local schema != 1"
  [ "$(jq -r '.plugin_version_seen' "$f" 2>/dev/null)" = "3.11.2" ] \
    && ok "plugin_version_seen recorded" || bad "plugin_version_seen wrong"
  [ "$(jq -rc '.local_steps_completed' "$f" 2>/dev/null)" = '["deps_installed"]' ] \
    && ok "local_steps_completed is the CSV as a JSON array" || bad "local_steps_completed wrong"
  out="$(cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "$SRC; tl_local_marker_read")"
  printf '%s' "$out" | jq -e '.plugin_version_seen == "3.11.2"' >/dev/null 2>&1 \
    && ok "tl_local_marker_read echoes the written local marker" \
    || bad "tl_local_marker_read did not echo the local marker"
) || true

# --- [G] JSON string escaping (quote AND control chars stay valid) -----------
echo "[G] string fields are JSON-escaped (write stays parseable)"
( R="$(mkrepo "$ROOT/g")"
  ( cd "$R" && bash -c "$SRC; tl_repo_marker_write '1.0\"x' 'sh' 'a'" )
  f="$R/docs/.throughline-bootstrap.json"
  if jq -e . "$f" >/dev/null 2>&1 && [ "$(jq -r '.plugin_version_applied' "$f")" = '1.0"x' ]; then
    ok "a double-quote in a value is escaped and round-trips"
  else
    bad "embedded quote broke the JSON or did not round-trip"
  fi
  # A value carrying a newline + tab must NOT break the JSON (control chars are
  # escaped, not emitted raw).
  weird="$(printf 'a\tb\nc')"
  ( cd "$R" && SRC="$SRC" weird="$weird" bash -c 'eval "$SRC"; tl_repo_marker_write "$weird" sh a' )
  if jq -e . "$f" >/dev/null 2>&1 && [ "$(jq -r '.plugin_version_applied' "$f")" = "$weird" ]; then
    ok "a tab+newline value is escaped and round-trips"
  else
    bad "a control-char value broke the JSON or did not round-trip"
  fi
) || true

# --- [G2] direct _tl_json_escape control-char unit (valid JSON + round-trip) --
# Focused unit on the escaper itself (TDD 0037 §Verification point 2): a value
# carrying a tab, a newline, and a bare C0 control (\x01) must escape to a body
# that is a VALID JSON string and round-trips byte-for-byte through jq.
echo "[G2] _tl_json_escape escapes control chars to a valid, round-tripping JSON string body"
( val="$(printf 'a\tb\nc\x01d')"
  esc="$(bash -c "$SRC; _tl_json_escape \"\$1\"" _ "$val")"
  obj="{\"x\":\"$esc\"}"
  if printf '%s' "$obj" | jq -e . >/dev/null 2>&1 \
       && [ "$(printf '%s' "$obj" | jq -r '.x')" = "$val" ]; then
    ok "tab/newline/\\x01 escape to valid JSON and round-trip"
  else
    bad "_tl_json_escape control-char output was not valid round-tripping JSON (esc='$esc')"
  fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== markers eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

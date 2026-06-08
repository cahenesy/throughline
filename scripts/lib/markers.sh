#!/usr/bin/env bash
# markers.sh — read/write the two TDD 0009 state markers (FR-31, FR-33).
#
#   Repo-state marker  (committed):   <repo-root>/docs/.throughline-bootstrap.json
#   Per-developer marker (per-machine): ${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json
#
# Both carry a top-level integer `schema` field (currently 1). Writes are atomic
# (`.tmp` + `mv`) and use printf with manual JSON escaping — NO jq dependency for
# writing. Reading uses jq to validate WHEN PRESENT, degrading to a permissive
# check otherwise; an absent or malformed marker reads back as `{}` so callers
# can treat "needs reconcile" uniformly. Defines functions only (sources
# repo-id.sh for tl_local_marker_path).

# Source repo-id.sh relative to this file so markers.sh is usable standalone.
_TL_MARKERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./repo-id.sh
. "$_TL_MARKERS_DIR/repo-id.sh"

# _tl_json_escape <str> — escape <str> into a VALID JSON string body for
# embedding between the quotes of a JSON string literal. Pure bash, no jq/no
# external process (the marker WRITE path is contractually jq-free, markers.sh:8).
# Handles backslash, double-quote, and every C0 control U+0001–U+001F (the five
# named ones to their short escapes, the rest to \u00XX) so control-char values
# round-trip instead of corrupting the JSON (FR-74 escaping norm; NFR-4). NUL
# (U+0000) cannot occur — bash strings cannot hold it — so it needs no handling.
_tl_json_escape() {
  local s="$1" cc lit
  # Backslash FIRST (so pre-existing backslashes are doubled before any escape
  # sequence below introduces its own), then double-quote.
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # The five named C0 controls -> their short JSON escapes.
  s="${s//$'\b'/\\b}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\f'/\\f}"
  s="${s//$'\r'/\\r}"
  # Every remaining C0 control (U+0001–U+001F minus the five above) -> \u00XX.
  for cc in 01 02 03 04 05 06 07 0b 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f; do
    printf -v lit '%b' "\\x$cc"
    s="${s//$lit/\\u00$cc}"
  done
  printf '%s' "$s"
}

# _tl_csv_to_json_array <csv> — turn "a,b,c" into ["a", "b", "c"] (empty -> []).
_tl_csv_to_json_array() {
  local csv="$1" out="" first=1 tok
  [ -n "$csv" ] || { printf '[]'; return 0; }
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if [ "$first" -eq 1 ]; then first=0; else out="$out, "; fi
    out="$out\"$(_tl_json_escape "$tok")\""
  done < <(printf '%s\n' "$csv" | tr ',' '\n')   # trailing \n so `read` keeps the last token
  printf '[%s]' "$out"
}

# _tl_now_iso — current time as ISO-8601 UTC, e.g. 2026-05-26T20:30:00Z.
_tl_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _tl_repo_marker_path — echo <repo-root>/docs/.throughline-bootstrap.json;
# returns non-zero when not in a git repo.
_tl_repo_marker_path() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  printf '%s/docs/.throughline-bootstrap.json' "$top"
}

# _tl_marker_read_file <path> — echo the file's JSON if it looks like a marker,
# else `{}`. Uses jq to validate when present; otherwise falls back to a cheap
# structural check (a JSON object carrying a "schema" field) so a malformed
# marker still degrades to `{}` on hosts without jq.
_tl_marker_read_file() {
  local f="$1"
  [ -f "$f" ] || { printf '{}'; return 0; }
  if command -v jq >/dev/null 2>&1; then
    if jq -e . "$f" >/dev/null 2>&1; then cat "$f"; else printf '{}'; fi
    return 0
  fi
  local content stripped
  content="$(cat "$f")"
  stripped="$(printf '%s' "$content" | tr -d '[:space:]')"
  case "$stripped" in
    \{*\}) if printf '%s' "$content" | grep -q '"schema"'; then printf '%s' "$content"; else printf '{}'; fi ;;
    *) printf '{}' ;;
  esac
}

# --- repo-state marker -----------------------------------------------------

# tl_repo_marker_read — echo the repo marker JSON, or `{}` if absent/malformed.
tl_repo_marker_read() {
  local f
  f="$(_tl_repo_marker_path)" || { printf '{}'; return 0; }
  _tl_marker_read_file "$f"
}

# tl_repo_marker_write <plugin_version> <language> <steps_csv> — atomically
# write docs/.throughline-bootstrap.json with applied_at = now.
tl_repo_marker_write() {
  local version="$1" language="$2" steps_csv="$3"
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "markers: not inside a git repo" >&2; return 1; }
  mkdir -p "$top/docs" 2>/dev/null || {
    echo "markers: cannot create $top/docs" >&2; return 1; }
  local f="$top/docs/.throughline-bootstrap.json"
  local tmp="$f.tmp.$$"
  {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "plugin_version_applied": "%s",\n' "$(_tl_json_escape "$version")"
    printf '  "language": "%s",\n' "$(_tl_json_escape "$language")"
    printf '  "repo_steps_applied": %s,\n' "$(_tl_csv_to_json_array "$steps_csv")"
    printf '  "applied_at": "%s"\n' "$(_tl_now_iso)"
    printf '}\n'
  } >"$tmp" || { rm -f "$tmp"; echo "markers: failed to write $tmp" >&2; return 1; }
  mv -f "$tmp" "$f"
}

# --- per-developer local marker --------------------------------------------

# tl_local_marker_read — echo the local marker JSON, or `{}` if absent/malformed
# or when the local path cannot be derived (CLAUDE_PLUGIN_DATA unset).
tl_local_marker_read() {
  local f
  f="$(tl_local_marker_path 2>/dev/null)" || { printf '{}'; return 0; }
  _tl_marker_read_file "$f"
}

# tl_local_marker_write <plugin_version> <steps_csv> — atomically write
# ${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json with updated_at = now.
tl_local_marker_write() {
  local version="$1" steps_csv="$2"
  local f
  f="$(tl_local_marker_path)" || return 1   # also mkdir -p's the dir
  local tmp="$f.tmp.$$"
  {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "plugin_version_seen": "%s",\n' "$(_tl_json_escape "$version")"
    printf '  "local_steps_completed": %s,\n' "$(_tl_csv_to_json_array "$steps_csv")"
    printf '  "updated_at": "%s"\n' "$(_tl_now_iso)"
    printf '}\n'
  } >"$tmp" || { rm -f "$tmp"; echo "markers: failed to write $tmp" >&2; return 1; }
  mv -f "$tmp" "$f"
}

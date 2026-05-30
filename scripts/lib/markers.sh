#!/usr/bin/env bash
# markers.sh — read/write helpers for the two install/update markers (TDD 0009).
#
#   Repo marker  (docs/.throughline-bootstrap.json, committed):
#     { schema, plugin_version_applied, language, repo_steps_applied[], applied_at }
#   Local marker (${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json, per-machine):
#     { schema, plugin_version_seen, local_steps_completed[], updated_at }
#
# Sourced by /bootstrap-project and the SessionStart reconcile hook. The local
# helpers rely on tl_local_marker_path from repo-id.sh, resolved at call time,
# so source repo-id.sh alongside this file. No top-level side effects.
#
# Writes use printf with manual JSON escaping — no `jq` dependency for WRITING.
# `jq`/`python3` are used only to VALIDATE on read (degrading to "assume valid"
# when neither is installed), keeping the read path soft per FR-36.

# Escape a string for embedding inside a JSON double-quoted value: backslash and
# double-quote only (the few fields here never carry control chars).
_tl_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# CSV -> JSON array of strings. Empty/blank CSV -> [].
_tl_csv_to_json_array() {
  local csv="${1-}" out="" item
  local -a items=()
  IFS=',' read -ra items <<<"$csv"
  for item in "${items[@]}"; do
    [ -n "$item" ] || continue
    out="${out:+$out,}\"$(_tl_json_escape "$item")\""
  done
  printf '[%s]' "$out"
}

# Validate a JSON file: jq, then python3, else assume valid (non-empty) so the
# read path never hard-depends on a parser.
_tl_json_valid() {
  local f="$1"
  [ -s "$f" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$f" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$f" >/dev/null 2>&1
  else
    return 0
  fi
}

_tl_now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_tl_repo_marker_file() {
  local t
  t="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$t" ] || return 1
  printf '%s\n' "$t/docs/.throughline-bootstrap.json"
}

# --- repo marker -------------------------------------------------------------

tl_repo_marker_read() {
  local f
  f="$(_tl_repo_marker_file)" || { printf '{}\n'; return 0; }
  if [ -f "$f" ] && _tl_json_valid "$f"; then cat "$f"; else printf '{}\n'; fi
}

# tl_repo_marker_write <plugin_version> <language> <steps_csv>
tl_repo_marker_write() {
  local pv="${1-}" lang="${2-}" steps_csv="${3-}" f tmp arr
  f="$(_tl_repo_marker_file)" \
    || { echo "tl_repo_marker_write: not inside a git repo" >&2; return 1; }
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  arr="$(_tl_csv_to_json_array "$steps_csv")"
  tmp="$f.tmp.$$"
  printf '{\n  "schema": 1,\n  "plugin_version_applied": "%s",\n  "language": "%s",\n  "repo_steps_applied": %s,\n  "applied_at": "%s"\n}\n' \
    "$(_tl_json_escape "$pv")" "$(_tl_json_escape "$lang")" "$arr" "$(_tl_now_utc)" > "$tmp" \
    && mv -f "$tmp" "$f"
}

# --- local marker ------------------------------------------------------------

tl_local_marker_read() {
  local f
  f="$(tl_local_marker_path 2>/dev/null)" || { printf '{}\n'; return 0; }
  if [ -f "$f" ] && _tl_json_valid "$f"; then cat "$f"; else printf '{}\n'; fi
}

# tl_local_marker_write <plugin_version> <steps_csv>
tl_local_marker_write() {
  local pv="${1-}" steps_csv="${2-}" f tmp arr
  f="$(tl_local_marker_path)" \
    || { echo "tl_local_marker_write: local marker path unavailable" >&2; return 1; }
  arr="$(_tl_csv_to_json_array "$steps_csv")"
  tmp="$f.tmp.$$"
  printf '{\n  "schema": 1,\n  "plugin_version_seen": "%s",\n  "local_steps_completed": %s,\n  "updated_at": "%s"\n}\n' \
    "$(_tl_json_escape "$pv")" "$arr" "$(_tl_now_utc)" > "$tmp" \
    && mv -f "$tmp" "$f"
}

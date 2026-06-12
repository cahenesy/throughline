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
# Pure-bash directory extraction (no external `dirname`) so the no-jq path works
# on minimal hosts lacking coreutils. The scratch `d` lives only in the subshell
# (FR-74 sourced-library hygiene: do not leak ambient variables to callers).
# `%/*` no-slash case -> "." (bare-name source); empty case -> "/" (root-level).
_TL_MARKERS_DIR="$(d="${BASH_SOURCE[0]%/*}"; [ "$d" = "${BASH_SOURCE[0]}" ] && d="."; [ -z "$d" ] && d="/"; cd "$d" && pwd)"
# shellcheck source=./repo-id.sh
. "$_TL_MARKERS_DIR/repo-id.sh"

# Source the canonical JSON helpers (TDD 0050) from the same sibling dir.
# json.sh is dependency-free and dirname-free (pure bash + awk), so the
# minimal-host contract above is preserved — and $_TL_MARKERS_DIR is already
# resolved without dirname. FATAL on missing per ADR 0006 (running with the
# escaper undefined would write corrupt markers); the dual `return||exit`
# idiom is correct sourced or executed (TDD 0049). json.sh's include guard
# makes a double-source a no-op.
_jlib="$_TL_MARKERS_DIR/json.sh"
# shellcheck source=./json.sh
{ [ -r "$_jlib" ] && . "$_jlib"; } || {
  echo "FATAL: cannot source $_jlib (partial install or perms)" >&2
  return 1 2>/dev/null || exit 1
}
unset _jlib

# _tl_json_escape <str> — escape <str> into a VALID JSON string body for
# embedding between the quotes of a JSON string literal. Thin delegate to
# json.sh's canonical C0-complete escaper (TDD 0050; its body originated
# here). Pure bash, no jq/no external process, so the marker WRITE path stays
# contractually jq-free (markers.sh:8; FR-74 escaping norm; NFR-4). Name kept
# so every caller and test is untouched.
_tl_json_escape() { tl_json_escape "${1:-}"; }

# _tl_csv_to_json_array <csv> — turn "a,b,c" into ["a","b","c"] (empty -> []).
# Thin delegate to json.sh's canonical builder (TDD 0050): output is now the
# canonical COMPACT form — no space after commas (the parsed value is
# unchanged; only the cosmetic ["a", "b"] spacing ends here).
_tl_csv_to_json_array() { tl_json_array "${1:-}"; }

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
  # Strip whitespace in pure bash (no external `tr`) for the structural {…} check
  # — output-identical to `tr -d '[:space:]'`, but works on a coreutils-minimal,
  # jq-absent host (FR-31's dependency-light read path).
  stripped="${content//[[:space:]]/}"
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

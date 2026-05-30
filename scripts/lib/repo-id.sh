#!/usr/bin/env bash
# repo-id.sh — deterministic per-repo identity + local-marker path.
#
# Sourced by /bootstrap-project, the SessionStart reconcile hook, and any future
# caller so they all derive the SAME <repo-id> for a given repo (TDD 0009 /
# FR-33; the path convention TDD 0012 also builds on). No top-level side
# effects: this file only declares functions.
#
#   tl_repo_id            -> 12 lowercase hex chars identifying $PWD's repo:
#                            sha256 of `git remote get-url origin` when present,
#                            else sha256 of the absolute repo toplevel path.
#                            Exits 1 (msg to stderr) outside a git repo or when
#                            no sha256 tool is available.
#   tl_local_marker_path  -> ${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json, creating
#                            the per-repo dir as a side effect. Exits 1 (msg to
#                            stderr) when CLAUDE_PLUGIN_DATA is unset/unwritable.

# Hash stdin -> hex digest. GNU coreutils `sha256sum` first; BSD `shasum -a 256`
# fallback (fresh macOS without Homebrew coreutils); else fail (rare).
#
# The digest tool runs in a COMMAND SUBSTITUTION, not a `tool | cut` pipeline:
# piping into `cut` would make the pipeline's exit status `cut`'s (always 0),
# silently masking a sha256sum failure and yielding an empty digest. Capturing
# directly lets the tool's non-zero exit propagate so callers fail closed.
_tl_sha256_hex() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum)" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256)" || return 1
  else
    return 1
  fi
  out="${out%%[[:space:]]*}"          # strip the trailing "  -" filename field
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

tl_repo_id() {
  local toplevel src digest
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "tl_repo_id: not inside a git repo" >&2; return 1; }
  [ -n "$toplevel" ] || { echo "tl_repo_id: not inside a git repo" >&2; return 1; }
  # Prefer the origin remote URL (stable across clones/paths); else the
  # absolute toplevel path. sha256 operates on bytes, so any path encodes.
  src="$(git -C "$toplevel" remote get-url origin 2>/dev/null)"
  [ -n "$src" ] || src="$toplevel"
  digest="$(printf '%s' "$src" | _tl_sha256_hex)" \
    || { echo "tl_repo_id: need sha256sum or shasum to derive a repo id" >&2; return 1; }
  # Fail closed: a short/empty/non-hex digest must never silently truncate to a
  # bogus id. Require at least 12 lowercase hex chars before slicing.
  case "$digest" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) echo "tl_repo_id: digest tool produced an invalid result" >&2; return 1 ;;
  esac
  printf '%s\n' "${digest:0:12}"
}

tl_local_marker_path() {
  local data="${CLAUDE_PLUGIN_DATA:-}" id dir
  [ -n "$data" ] || { echo "tl_local_marker_path: CLAUDE_PLUGIN_DATA is unset" >&2; return 1; }
  id="$(tl_repo_id)" || return 1
  dir="$data/$id"
  mkdir -p "$dir" 2>/dev/null || { echo "tl_local_marker_path: cannot create $dir" >&2; return 1; }
  [ -w "$dir" ] || { echo "tl_local_marker_path: $dir is not writable" >&2; return 1; }
  printf '%s\n' "$dir/local.json"
}

#!/usr/bin/env bash
# repo-id.sh — deterministic per-repo identity + local-marker path helper.
#
# Sourced by /bootstrap-project, the SessionStart reconcile hook, and any future
# caller so they all compute the SAME <repo-id> for a given repo (TDD 0009,
# FR-33). Defines functions only — no top-level side effects — so it is safe to
# source from any context.
#
#   repo_id := sha256_hex_prefix12( git remote get-url origin || abspath(repo_root) )
#
# 12 hex chars (48 bits): collision-vanishingly-rare across one developer's
# repos, short enough for a readable path. sha256sum (GNU coreutils) is tried
# first, shasum -a 256 (BSD/macOS) second; neither present is a hard error. No
# Node, no jq — present wherever Bash runs.

# _tl_sha256_12 — read stdin, emit the first 12 hex chars of its sha256.
# Returns 1 (diagnostic to stderr) when no hasher is available.
_tl_sha256_12() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-12
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-12
  else
    echo "repo-id: no sha256sum or shasum on PATH" >&2
    return 1
  fi
}

# tl_repo_id — echo the 12-hex id for $PWD's containing repo. Returns non-zero
# when not inside a git repo (so callers can fail closed). Uses the origin
# remote URL as the hash key when present, else the absolute toplevel path.
tl_repo_id() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1
  local key
  key="$(git -C "$top" remote get-url origin 2>/dev/null)"
  [ -n "$key" ] || key="$top"
  # printf '%s' (no trailing newline) so the hash is of exactly the key bytes.
  printf '%s' "$key" | _tl_sha256_12
}

# tl_local_marker_path — echo ${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json and
# mkdir -p its dir as a side effect. Returns 1 (diagnostic to stderr) when
# CLAUDE_PLUGIN_DATA is unset/empty, the repo id cannot be derived, or the dir
# is not writable — letting callers fail closed.
tl_local_marker_path() {
  if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
    echo "repo-id: CLAUDE_PLUGIN_DATA is not set" >&2
    return 1
  fi
  local id
  id="$(tl_repo_id)" || { echo "repo-id: cannot derive repo id" >&2; return 1; }
  local dir="${CLAUDE_PLUGIN_DATA}/${id}"
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "repo-id: cannot create ${dir} (CLAUDE_PLUGIN_DATA not writable)" >&2
    return 1
  fi
  printf '%s/local.json\n' "$dir"
}

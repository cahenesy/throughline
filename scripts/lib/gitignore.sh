#!/usr/bin/env bash
# gitignore.sh — idempotent .gitignore line management for consumer repos.
#
# tl_gitignore_add_line <line>: ensure the repo's top-level .gitignore contains
# an exact line equal to <line>, creating the file if absent. Idempotent — a
# second call with the same line leaves the file byte-identical (TDD 0009,
# FR-32). Returns 0 in both the "added" and "already present" cases; returns
# non-zero only when not inside a git repo. Defines functions only.

tl_gitignore_add_line() {
  local line="$1"
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "gitignore: not inside a git repo" >&2; return 1; }
  local gi="$top/.gitignore"
  # Already present as an EXACT line? Nothing to do — keeps re-runs byte-identical.
  if [ -f "$gi" ] && grep -Fxq -- "$line" "$gi"; then
    return 0
  fi
  # If the file exists and its last byte is not a newline, terminate that line
  # first so we never glue our entry onto a trailing no-newline line.
  if [ -s "$gi" ] && [ -n "$(tail -c1 "$gi" 2>/dev/null)" ]; then
    printf '\n' >>"$gi"
  fi
  printf '%s\n' "$line" >>"$gi"
}

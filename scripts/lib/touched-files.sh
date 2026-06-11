#!/usr/bin/env bash
# touched-files.sh — the SINGLE source of truth for parsing a TDD's
# `## Touched files` section into its declared path set (TDD 0049 / FR-53, FR-54,
# FR-67(a)). gates.sh, tdd-lint.sh and learnings.sh all delegate here so no
# divergent copy can re-introduce the 0044 footgun or the annotated-path
# mis-parse 0048 left open. Sourced, never executed: no top-level side effects.
#
# TDD 0055: the path-extraction body now delegates to the unified markdown parser
# in lib/md.sh (md_bullet_path), so `## Touched files` and `## Expected diff size`
# share ONE per-bullet path op (reuse #12) and the L-005 awk-rc check applies to
# this path too (a parse failure surfaces as rc 2 + stderr, never a silent empty
# set). Name/signature/output are unchanged, so every caller and the 0049 3-way
# agreement cross-check are untouched.

# Include guard: gates.sh AND learnings.sh both pull this lib under one
# implement.sh, so double-sourcing must be a clean no-op. _TL_TOUCHED_FILES_SOURCED
# is PERSISTENT state, never unset (unlike the per-host `_tf_lib` scratch var).
[ -n "${_TL_TOUCHED_FILES_SOURCED:-}" ] && return 0
_TL_TOUCHED_FILES_SOURCED=1

# Source the unified markdown parser (TDD 0055) by its SIBLING path, with the
# FATAL-on-missing + dual `return||exit` idiom 0049/0050 established (correct in
# BOTH a sourced and an executed context). `${BASH_SOURCE[0]%/*}` (no dirname)
# keeps minimal-host callers safe; md.sh's own include guard makes a repeat source
# a no-op. The FATAL prints first, so a missing lib is never silent (ADR 0006).
_md_lib="${BASH_SOURCE[0]%/*}/md.sh"
# shellcheck source=scripts/lib/md.sh
{ [ -r "$_md_lib" ] && . "$_md_lib"; } || {
  echo "FATAL: cannot source $_md_lib (partial install or perms)" >&2
  return 1 2>/dev/null || exit 1
}
unset _md_lib

# tl_extract_touched_paths <tdd-file> [mode] — extract one declared path per
# `- ` bullet of the (fence-aware) `## Touched files` section. A missing file is
# caller-friendly: return 0, emit nothing (md_bullet_path handles this).
#   mode=paths (default): emit each non-empty extracted path, one per line.
#   mode=malformed:       emit the 60-char excerpt of each `- ` bullet whose path
#                         is empty (the no-path bullets).
# Delegates to md.sh's md_bullet_path — the single per-bullet path op (the
# annotation-robust leading-backtick-else-first-token + em-dash-split algorithm
# lives there now). As the LAST command its rc propagates unchanged (no
# `local x="$(...)"` capture to mask it), so a non-zero md_bullet_path (awk
# failure, rc 2) reaches the caller's membership check (L-005 fix, end-to-end).
tl_extract_touched_paths() {  # <tdd-file> [mode]
  local f="$1" mode="${2:-paths}"
  md_bullet_path "$f" "Touched files" "$mode"
}

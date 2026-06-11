#!/usr/bin/env bash
# touched-files.sh — the SINGLE source of truth for parsing a TDD's
# `## Touched files` section into its declared path set (TDD 0049 / FR-53, FR-54,
# FR-67(a)). gates.sh, tdd-lint.sh and learnings.sh all delegate here so no
# divergent copy can re-introduce the 0044 footgun or the annotated-path
# mis-parse 0048 left open. Sourced, never executed: no top-level side effects.

# Include guard: gates.sh AND learnings.sh both pull this lib under one
# implement.sh, so double-sourcing must be a clean no-op. _TL_TOUCHED_FILES_SOURCED
# is PERSISTENT state, never unset (unlike the per-host `_tf_lib` scratch var).
[ -n "${_TL_TOUCHED_FILES_SOURCED:-}" ] && return 0
_TL_TOUCHED_FILES_SOURCED=1

# tl_extract_touched_paths <tdd-file> [mode] — extract one declared path per
# `- ` bullet of the (fence-aware) `## Touched files` section. A missing file is
# caller-friendly: return 0, emit nothing.
#   mode=paths (default): emit each non-empty extracted path, one per line.
#   mode=malformed:       emit the 60-char excerpt of each `- ` bullet whose path
#                         is empty (the no-path bullets).
# Algorithm (annotation-robust): the path lives in the segment LEFT of the em-dash
# (`—`, U+2014), or the whole bullet when there is none. If that segment (leading
# ws trimmed) STARTS with a backtick, the path is that leading backtick-quoted
# token (so `` `path` (post) — purpose `` yields `path`, not `path (post)`);
# otherwise it is the segment's FIRST whitespace token (so the 0044 bare-path-with-
# backticked-DESCRIPTION case yields the path). Anchoring the backtick check to the
# segment START (not "contains a backtick anywhere") is what subsumes EVERY form
# the em-dash-split predecessor handled, including a no-em-dash bullet whose
# trailing words contain a backtick. A no-path bullet is dropped / reported.
tl_extract_touched_paths() {  # <tdd-file> [mode]
  local f="$1" mode="${2:-paths}"
  [ -f "$f" ] || return 0
  awk -v MODE="$mode" '
    BEGIN { in_fence=0; in_sec=0 }
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    !in_fence && /^## Touched files[[:space:]]*$/ { in_sec=1; next }
    !in_fence && /^## / { in_sec=0; next }
    in_sec && !in_fence && /^- / {
      rest = substr($0, 3)                       # drop "- "
      em = index(rest, "—")                      # em-dash separates path from purpose
      if (em > 0) { seg = substr(rest, 1, em - 1) }
      else        { seg = rest }                 # no em-dash: whole bullet is the segment
      sub(/^[[:space:]]+/, "", seg)              # trim leading ws so "starts with" is real
      if (substr(seg, 1, 1) == "`" && match(seg, /`[^`]+`/)) {
        file = substr(seg, RSTART + 1, RLENGTH - 2)   # leading quoted-path token
      } else {
        file = seg
        sub(/[[:space:]].*/, "", file)           # first whitespace-delimited token
        gsub(/`/, "", file)                       # strip stray backticks (predecessor parity)
      }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", file)
      if (MODE == "malformed") { if (file == "") print substr($0, 1, 60) }
      else                     { if (file != "") print file }
    }
  ' "$f"
}

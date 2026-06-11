#!/usr/bin/env bash
# touched-files.sh — the SINGLE source of truth for parsing a TDD's
# `## Touched files` section into its declared path set (TDD 0049 / FR-53, FR-54,
# FR-67(a)).
#
# Three readers parse this section: gates.sh's _rework_touched_files (build-time
# FR-67(a) membership), tdd-lint.sh's _tl_extract_touched_paths (design-time
# malformed PRECHECK), and learnings.sh's _touched_files_of_tdd (learning
# aggregation). TDD 0048 unified the first two onto an em-dash-split extractor;
# this lib unifies ALL THREE onto one annotation-robust definition so a future
# edit cannot re-introduce a divergent copy (the 0044 footgun) or the annotated-
# path mis-parse 0048 left open.
#
# Sourced, never executed: no top-level side effects, no `set` options, only the
# include guard and the function definition.

# Include guard: gates.sh AND learnings.sh both pull this lib under one
# implement.sh, so double-sourcing must be a clean no-op. _TL_TOUCHED_FILES_SOURCED
# is PERSISTENT process state and is never unset (unlike the per-host `_tf_lib`
# scratch variable), or the guard would not hold.
[ -n "${_TL_TOUCHED_FILES_SOURCED:-}" ] && return 0
_TL_TOUCHED_FILES_SOURCED=1

# tl_extract_touched_paths <tdd-file> [mode] — extract one declared path per
# `- ` bullet of the (fence-aware) `## Touched files` section.
#   mode=paths (default): emit each non-empty extracted path, one per line.
#   mode=malformed:       emit the 60-char excerpt of each `- ` bullet whose
#                         extracted path is empty (the no-path bullets).
# A missing file is caller-friendly: return 0, emit nothing.
#
# Algorithm (annotation-robust). Within each bullet, the path lives in the
# segment LEFT of the em-dash (`—`, U+2014, which separates path from purpose),
# or the whole bullet when there is no em-dash:
#   - if the segment (after trimming leading whitespace) STARTS with a backtick,
#     the path is that leading backtick-delimited token (the quoted path) — this
#     is what makes an annotated bullet like `` `path` (post) — purpose `` yield
#     `path`, not `path (post)`;
#   - otherwise the path is the segment's FIRST whitespace-delimited token (with
#     any stray backticks stripped, matching the predecessor) — this keeps the
#     0044 case (bare path, backticked DESCRIPTION) yielding the path, not the
#     description backtick, INCLUDING the no-em-dash bullet where the description
#     backtick sits in the same segment as the bare path.
# The start-anchored backtick check (not "contains a backtick anywhere") is what
# makes this subsume EVERY form the em-dash-split predecessor handled: a no-em-
# dash bullet whose trailing words contain a backtick still yields its first
# token, exactly as the predecessor's first-whitespace-token branch did.
# A bullet that yields no path is dropped (paths mode) or reported (malformed).
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

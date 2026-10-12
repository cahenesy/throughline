#!/usr/bin/env bash
# md.sh — the SINGLE source of truth for markdown section/bullet parsing across
# the runner's shell libs (TDD 0055 / FR-53, FR-54, FR-67, FR-69). It folds the
# fence-aware `^## <heading>` section walk that was copy-pasted 4× (reuse #11) and
# the em-dash-split per-bullet path extractor duplicated for `## Touched files` and
# `## Expected diff size` (reuse #12), plus the folded bugs A21 (~~~ fences) and
# L-005 (silent awk-failure → false empty result). Every caller (plan-classifier,
# tdd-lint, gates, and 0049's touched-files delegate) routes through here so no
# divergent copy can re-introduce the 0044 footgun or a fence mis-parse.
#
# Sourced, never executed: NO top-level side effects, NO shell-option changes
# (`set -uo pipefail` would leak to every caller), dependency-free (pure bash/awk;
# no jq, no dirname) per the 0049/0050 minimal-host sourcing pattern.

# Include guard: gates.sh, tdd-lint.sh, plan-classifier.sh and touched-files.sh
# can all pull this lib under one implement.sh, so double-sourcing must be a clean
# no-op. _TL_MD_SOURCED is PERSISTENT process-local state, never unset.
[ -n "${_TL_MD_SOURCED:-}" ] && return 0
_TL_MD_SOURCED=1

# md_section_body <file> <heading> — emit, one per line, the RAW in-section lines
# of the `^## <heading>` section, fence-aware: a line toggling a ``` OR ~~~ fence
# is a fence boundary (and is NOT emitted), so a fenced example inside the section
# is excluded (closes the reuse-#11 misroute AND bug A21). The heading match is
# `^## <heading>` with optional trailing whitespace; <heading> is an INTERNAL
# literal the callers supply (never external input), interpolated into the awk
# regex. awk's exit code is CHECKED: a non-zero awk returns 2 + a stderr
# diagnostic (never a silent empty body — L-005). A missing file is
# caller-friendly: return 0, emit nothing. The caller layers its own predicate
# (classify / rows / columns) on the emitted stream — this unifies ONLY the
# fence/section-boundary walk.
md_section_body() {  # <file> <heading>
  local f="$1" heading="$2" out awk_rc
  [ -f "$f" ] || return 0
  out="$(awk -v H="$heading" '
    BEGIN { in_fence=0; in_sec=0 }
    /^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; next }
    !in_fence && $0 ~ ("^## " H "[[:space:]]*$") { in_sec=1; next }
    !in_fence && /^## / { in_sec=0; next }
    in_sec && !in_fence { print }
  ' "$f")"
  awk_rc=$?
  if [ "$awk_rc" -ne 0 ]; then
    echo "md_section_body: awk failed (exit $awk_rc) on $f [## $heading]" >&2
    return 2
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# md_bullet_path_of_line <bullet-line> — the SHARED per-bullet PATH extractor
# (reuse #12). Given ONE `- ` bullet line, echo its path via 0049's
# annotation-robust algorithm, or empty for a no-path bullet. Pure string op (no
# file, no awk): the path lives in the segment LEFT of the em-dash (`—`, U+2014 —
# matched as its literal byte sequence, so locale-independent), or the whole
# bullet when there is none. If that segment (leading ws trimmed) STARTS with a
# backtick, the path is the leading backtick-quoted token (so
# `` `path` (post) — purpose `` yields `path`); otherwise it is the segment's
# FIRST whitespace token (so the 0044 bare-path-with-backticked-DESCRIPTION case
# yields the path). This is the ONE definition of "the path of a bullet" reused by
# md_bullet_path AND the annotation-bearing `## Expected diff size` callers.
md_bullet_path_of_line() {  # <bullet-line>
  local line="$1" seg file
  line="${line#- }"                       # drop the leading "- " bullet marker
  seg="${line%%—*}"                        # path is left of the em-dash, else whole bullet
  seg="${seg#"${seg%%[![:space:]]*}"}"     # trim leading whitespace so "starts with" is real
  if [ "${seg:0:1}" = '`' ]; then
    file="${seg#\`}"; file="${file%%\`*}"  # leading backtick-quoted token
  else
    file="${seg%%[[:space:]]*}"            # first whitespace-delimited token
    file="${file//\`/}"                    # strip stray backticks (predecessor parity)
  fi
  file="${file#"${file%%[![:space:]]*}"}"  # trim surrounding whitespace
  file="${file%"${file##*[![:space:]]}"}"
  printf '%s\n' "$file"
}

# _md_bullet_mark <bullet-line> — `(new)` or `-` for md_bullet_path's marked
# mode. The annotation text is the em-dash-left segment minus the path token
# (the leading backtick-quoted token, else the first whitespace token — the same
# split md_bullet_path_of_line makes); `(new)` must be a whitespace-delimited
# token in it, so `(newer)` or a `(new)` after the em-dash is not a mark.
_md_bullet_mark() {  # <bullet-line>
  local seg="${1#- }" rest
  seg="${seg%%—*}"
  seg="${seg#"${seg%%[![:space:]]*}"}"
  if [ "${seg:0:1}" = '`' ]; then
    rest="${seg#\`}"
    case "$rest" in *'`'*) rest="${rest#*\`}" ;; *) rest="" ;; esac
  else
    case "$seg" in *[[:space:]]*) rest="${seg#*[[:space:]]}" ;; *) rest="" ;; esac
  fi
  case " ${rest//[[:space:]]/ } " in
    *' (new) '*) printf '(new)' ;;
    *) printf -- '-' ;;
  esac
}

# md_bullet_path <file> <heading> [mode] — emit one declared path per `- ` bullet
# of the (fence-aware ```+~~~) `^## <heading>` section: it is
# `md_section_body <file> <heading>` filtered to `/^- /` lines, each run through
# md_bullet_path_of_line. The bullet anchor is `/^- /` — the single canonical
# anchor (A23). awk's exit code is CHECKED end-to-end: a non-zero awk in the
# underlying md_section_body → return 2 + stderr diagnostic, NOT a silent empty
# list (L-005). mode=paths (default): emit each non-empty path. mode=malformed:
# emit the 60-char excerpt of each `- ` bullet whose extracted path is empty.
# mode=marked (TDD 0074 / FR-106): emit `<path>\t(new)` when the text between
# the path and the em-dash holds the standalone, case-sensitive token `(new)`,
# else `<path>\t-`. The path is the SAME md_bullet_path_of_line result `paths`
# prints, so the two modes cannot disagree on what the path is.
md_bullet_path() {  # <file> <heading> [mode]
  local f="$1" heading="$2" mode="${3:-paths}" body rc line file
  body="$(md_section_body "$f" "$heading")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "md_bullet_path: section body parse failed (rc=$rc) for [## $heading] in $f" >&2
    return 2
  fi
  [ -z "$body" ] && return 0
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;          # only `/^- /` bullets (single canonical anchor — A23)
      *) continue ;;
    esac
    file="$(md_bullet_path_of_line "$line")"
    if [ "$mode" = malformed ]; then
      [ -z "$file" ] && printf '%s\n' "${line:0:60}"
    elif [ "$mode" = marked ]; then
      [ -n "$file" ] && printf '%s\t%s\n' "$file" "$(_md_bullet_mark "$line")"
    else
      [ -n "$file" ] && printf '%s\n' "$file"
    fi
  done <<< "$body"
  return 0
}

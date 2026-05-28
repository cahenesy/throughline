#!/usr/bin/env bash
# tdd-lint.sh — mechanical pre-checks for a TDD set (TDD 0013 / FR-51).
#
# Three lint functions + an aggregate wrapper that runs against a TDD path or
# list of TDD paths and surfaces the structural-gap findings the design-reviewer
# subagent would otherwise spend tokens on. The point is to BLOCK the reviewer
# locally when a `grep` already proves the design isn't reviewable yet.
#
# Unified exit-code contract (every function in this file):
#   0 — no findings, or only nit-severity findings.
#   1 — at least one major-severity finding (no blocker).
#   2 — at least one blocker-severity finding (regardless of other findings).
#
# All findings go to STDOUT in the format
#   <file>:<line> <severity> <code>: <msg>
# Findings always print; exit code is the routable signal. STDERR is reserved
# for runtime errors of the script itself (e.g. a missing input file).
#
# Source it (`source scripts/lib/tdd-lint.sh`) to call the helpers, or invoke
# the file directly (`bash scripts/lib/tdd-lint.sh <tdd-or-glob>...`) — the
# trailing dispatcher routes positional args to `tl_lint_all`.

# Emit a finding line on stdout. Internal helper; callers pass severity/code/msg.
_tl_emit() {  # <file> <line> <severity> <code> <msg>
  printf '%s:%s %s %s: %s\n' "$1" "$2" "$3" "$4" "$5"
}

# tl_lint_structural — required sections + frontmatter checks.
# Rules per TDD 0013 §FR-51 Components §1:
#   blocker frontmatter.status     — `^Status: (draft|ready|implemented)$`
#   blocker frontmatter.prd_refs   — `^PRD refs:`
#   blocker frontmatter.prd_rev    — `^PRD-rev:` (or `Supersedes:` present)
#   blocker section.approach       — `^## Approach$`
#   blocker section.verification_plan — `^## Verification plan$`
#   blocker section.deps_considered   — `^## Dependencies considered$`
#   blocker section.traceability   — `^## Requirement traceability$` AND
#                                    contains a `|`-table or `- FR-`/`- NFR-`
#                                    definition list inside it.
#   major   section.empty          — two consecutive `^## ` headings with no
#                                    non-blank, non-separator content between.
tl_lint_structural() {  # <tdd-path>
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "tdd-lint: structural: input not found: $f" >&2
    return 2
  fi
  local rc=0

  # Frontmatter checks (the line numbers are not strictly meaningful for
  # `missing` findings, so we use 0 to indicate "the file as a whole").
  if ! grep -qE '^Status: (draft|ready|implemented)$' "$f"; then
    _tl_emit "$f" 0 blocker "frontmatter.status" \
      "missing or malformed 'Status: (draft|ready|implemented)' line"
    rc=2
  fi
  if ! grep -qE '^PRD refs:' "$f"; then
    _tl_emit "$f" 0 blocker "frontmatter.prd_refs" \
      "missing 'PRD refs:' frontmatter line"
    rc=2
  fi
  # PRD-rev required unless Supersedes: is present (a superseding TDD reuses
  # the predecessor's pinned PRD rev).
  if ! grep -qE '^PRD-rev:' "$f" && ! grep -qE '^Supersedes:' "$f"; then
    _tl_emit "$f" 0 blocker "frontmatter.prd_rev" \
      "missing 'PRD-rev:' (or 'Supersedes:') frontmatter line"
    rc=2
  fi

  # Required sections.
  if ! grep -qE '^## Approach$' "$f"; then
    _tl_emit "$f" 0 blocker "section.approach" "missing '## Approach' section"
    rc=2
  fi
  if ! grep -qE '^## Verification plan$' "$f"; then
    _tl_emit "$f" 0 blocker "section.verification_plan" \
      "missing '## Verification plan' section"
    rc=2
  fi
  if ! grep -qE '^## Dependencies considered$' "$f"; then
    _tl_emit "$f" 0 blocker "section.deps_considered" \
      "missing '## Dependencies considered' section"
    rc=2
  fi

  # Traceability: section header AND a table-row or definition-list entry
  # inside the section (between the heading and the next `^## ` heading).
  if ! grep -qE '^## Requirement traceability$' "$f"; then
    _tl_emit "$f" 0 blocker "section.traceability" \
      "missing '## Requirement traceability' section"
    rc=2
  else
    # BL-2 + MAJ-4 (review pass 2): capture awk's rc directly (command
    # substitution would otherwise mask a crash as "no rows" — a
    # false-positive blocker that hides the real error). Also track
    # fenced-code state so a fenced-only |-table inside the section does
    # NOT satisfy has_rows (the traceability rows must be real markdown
    # structure, not example literals inside a code fence).
    local has_rows awk_rc
    has_rows="$(awk '
      BEGIN { in_sec=0; in_fence=0 }
      /^[[:space:]]*```/ { in_fence = !in_fence; next }
      !in_fence && /^## Requirement traceability$/ { in_sec=1; next }
      !in_fence && /^## / { in_sec=0; next }
      in_sec && !in_fence && (/^\|/ || /^- FR-/ || /^- NFR-/) { print "yes"; exit }
    ' "$f")"
    awk_rc=$?
    if [ "$awk_rc" -ne 0 ]; then
      echo "tdd-lint: structural: traceability has_rows awk failed (exit $awk_rc) on $f" >&2
      return 2
    fi
    if [ -z "$has_rows" ]; then
      _tl_emit "$f" 0 blocker "section.traceability" \
        "'## Requirement traceability' section contains no table-row or '- FR-/NFR-' definition-list entry"
      rc=2
    fi
  fi

  # section.empty (major) — two adjacent `^## ` headings with nothing
  # substantive between them. Implementation: an awk pass that tracks the
  # last `^## ` heading's line number + a count of non-blank, non-table-
  # separator lines seen since; if a new `^## ` arrives with count == 0 we
  # emit a finding against the PRIOR heading's line.
  #
  # M1 (review pass): capture awk's stdout into a local instead of writing to
  # an adjacent temp file. The temp-file pattern silently dropped the
  # finding when the input's directory was read-only (the redirect failed,
  # `2>/dev/null` swallowed the error, [ -s ] read false → rc=0 = "clean"),
  # violating NFR-4 verdict honesty. Command substitution survives a
  # read-only working tree.
  local empty_out
  empty_out="$(awk '
    function emit(ln, hdr) {
      printf "%s:%d major section.empty: %s heading has no content before next section\n", FILE, ln, hdr
    }
    BEGIN { last_ln=0; last_hdr=""; count=0; in_fence=0 }
    # Fence-aware: a `^[[:space:]]*```` flips fence state. Headings and content
    # inside a fence are literal text, not markdown structure, so we count them
    # as content for the prior heading (so `## Foo` followed by a fenced block
    # is NOT flagged empty) and never treat them as new headings.
    /^[[:space:]]*```/ { in_fence = !in_fence; count++; next }
    !in_fence && /^## / {
      if (last_ln > 0 && count == 0) emit(last_ln, last_hdr)
      last_ln = NR
      last_hdr = $0
      count = 0
      next
    }
    {
      # Strip leading/trailing whitespace before counting.
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") next               # blank
      if (line ~ /^[|+-][-=+|: ]+[|+-]?$/) next  # markdown table separator
      count++
    }
    END {
      if (last_ln > 0 && count == 0) emit(last_ln, last_hdr)
    }
  ' FILE="$f" "$f")"
  # BL-1 (review pass 2): capture awk's rc directly. The first M1 fix
  # moved the section.empty pass from a temp-file redirect to a command
  # substitution, but still ignored awk's exit code — an awk crash left
  # empty_out empty and the [ -n ] guard returned "no findings" rc=0,
  # the same NFR-4 violation the temp-file form had.
  local empty_awk_rc=$?
  if [ "$empty_awk_rc" -ne 0 ]; then
    echo "tdd-lint: structural: section.empty awk failed (exit $empty_awk_rc) on $f" >&2
    return 2
  fi
  if [ -n "$empty_out" ]; then
    printf '%s\n' "$empty_out"
    # Promote rc to 1 (major) but never demote a 2 (blocker).
    [ "$rc" -lt 1 ] && rc=1
  fi
  return "$rc"
}

# tl_lint_placeholders — `grep -Fi` for forbidden placeholder phrases.
# Two well-known false-positive patterns are silenced:
#   - TBD inside a ``` fenced code block
#   - <TBD> inside angle brackets (template metasyntax)
# Every match is a major-severity finding.
tl_lint_placeholders() {  # <tdd-path>
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "tdd-lint: placeholders: input not found: $f" >&2
    return 2
  fi
  local rc=0

  awk -v FILE="$f" '
    BEGIN {
      # Forbidden phrases (case-insensitive substring match).
      n = split("TBD|verify it works|verify it is correct|tests will pass|the change works as expected|handle errors appropriately|handle errors gracefully|add validation|to be determined|to be decided", phrases, "|")
      for (i = 1; i <= n; i++) lower[i] = tolower(phrases[i])
      in_fence = 0
    }
    {
      # Toggle fenced-code state on lines starting with ```
      if ($0 ~ /^[[:space:]]*```/) { in_fence = !in_fence; next }
      if (in_fence) next

      lc = tolower($0)
      for (i = 1; i <= n; i++) {
        idx = index(lc, lower[i])
        if (idx == 0) continue

        # Silence <TBD> template metasyntax for the "TBD" phrase specifically.
        if (lower[i] == "tbd") {
          # Inspect the original line around the match for `<TBD>` (case-
          # insensitive). If every TBD occurrence on this line is wrapped in
          # angle brackets, skip the line; otherwise fire.
          orig = $0
          orig_lc = tolower(orig)
          any_bare = 0
          search_from = 1
          while ((p = index(substr(orig_lc, search_from), "tbd")) > 0) {
            abs = search_from + p - 1
            before = (abs > 1) ? substr(orig, abs - 1, 1) : ""
            after  = substr(orig, abs + 3, 1)
            if (!(before == "<" && after == ">")) any_bare = 1
            search_from = abs + 3
          }
          if (!any_bare) continue
        }

        printf "%s:%d major placeholder.forbidden_phrase: %s appears outside a code fence\n", FILE, NR, phrases[i]
        found = 1
        break  # one finding per line is enough
      }
    }
    END { exit (found ? 1 : 0) }
  ' "$f"
  # M2 (review pass): map awk's exit code honestly. The previous form mapped
  # every non-1 exit (including awk crashes, exit ≥2) to rc=0 "clean" — a
  # silent FAIL that violates NFR-4. Capture awk's rc first (the `case`
  # branches were resetting $? on each match), then propagate {0,1} as
  # intended and surface any other exit as rc=2 (blocker) + stderr.
  local awk_rc=$?
  case "$awk_rc" in
    0) rc=0 ;;
    1) rc=1 ;;
    *)
      echo "tdd-lint: placeholders: awk failed (exit $awk_rc) on $f" >&2
      return 2
      ;;
  esac
  return "$rc"
}

# tl_lint_traced — extracts requirement IDs from `^PRD refs:` and from the
# `## Requirement traceability` section; emits a major finding per FR/NFR in
# PRD refs that does not appear in the traceability section body.
tl_lint_traced() {  # <tdd-path>
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "tdd-lint: traced: input not found: $f" >&2
    return 2
  fi

  # Extract the PRD refs line content (right of the colon) and pull FR-/NFR- IDs.
  local refs_line refs_ids ids_in_table missing rc=0
  refs_line="$(grep -E '^PRD refs:' "$f" | head -1)"
  [ -z "$refs_line" ] && return 0  # structural lint already flagged this
  refs_ids="$(printf '%s' "$refs_line" | grep -oE '(FR|NFR)-[0-9]+' | sort -u)"
  [ -z "$refs_ids" ] && return 0   # nothing to trace

  # Pull all FR-/NFR- mentions from the traceability section body.
  #
  # BL-1 (review pass 3): the previous form used `PIPESTATUS` AFTER a
  # `$(pipeline)` command substitution. Without `set -o pipefail`,
  # `PIPESTATUS` in the outer shell collapses to a single subshell exit
  # code — and the production CLI invocation
  # `bash scripts/lib/tdd-lint.sh <tdd>` runs WITHOUT pipefail, so the
  # guard was non-functional on the primary use path (`pipe_rcs[1]`
  # was also unset, emitting `[: : integer expected` under `set -u` on
  # every CLEAN run). The fix runs awk INDEPENDENTLY of the pipeline,
  # captures awk's rc directly, and only then pipes the captured awk
  # output to the trivial tail (grep/sort) — which never reaches the
  # primary failure modes for this lint (grep rc=1 = no matches = valid
  # empty result; sort is read-only on a small stdin buffer).
  # MAJ-1 (review pass 5): fence-aware body extraction. The previous form
  # let an FR ID inside a ``` fenced code block in the traceability section
  # silently satisfy the trace — a real untraced requirement hidden behind
  # a code-block illustration. This is the same convention `has_rows`
  # (BL-2/MAJ-4 fix), `section.empty`, and `tl_lint_placeholders` already
  # use; tl_lint_traced now matches.
  local awk_out awk_rc
  awk_out="$(awk '
    BEGIN { in_sec=0; in_fence=0 }
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    !in_fence && /^## Requirement traceability$/ { in_sec=1; next }
    !in_fence && /^## / { in_sec=0; next }
    in_sec && !in_fence { print }
  ' "$f")"
  awk_rc=$?
  if [ "$awk_rc" -ne 0 ]; then
    echo "tdd-lint: traced: ids_in_table awk failed (exit $awk_rc) on $f" >&2
    return 2
  fi
  ids_in_table="$(printf '%s\n' "$awk_out" | grep -oE '(FR|NFR)-[0-9]+' | sort -u)"

  # Find the PRD-refs line's actual line number for the finding pointer.
  local refs_line_num
  refs_line_num="$(grep -nE '^PRD refs:' "$f" | head -1 | cut -d: -f1)"

  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! printf '%s\n' "$ids_in_table" | grep -qx "$id"; then
      _tl_emit "$f" "${refs_line_num:-0}" major "traceability.untraced" \
        "$id appears in 'PRD refs:' but not in '## Requirement traceability'"
      rc=1
      missing=1
    fi
  done <<EOF
$refs_ids
EOF
  return "$rc"
}

# tl_lint_all — run the three lints over each TDD in turn. All three lints
# always run (no early-exit) so findings accumulate; the aggregate exit is the
# MAX of any sub-lint's exit code, capped at 2.
tl_lint_all() {  # <tdd-path>...
  local max=0 rc tdd
  for tdd in "$@"; do
    for fn in tl_lint_structural tl_lint_placeholders tl_lint_traced; do
      "$fn" "$tdd"
      rc=$?
      [ "$rc" -gt "$max" ] && max="$rc"
      [ "$max" -ge 2 ] && max=2
    done
  done
  return "$max"
}

# When invoked directly (not sourced), dispatch positional args to tl_lint_all.
# `BASH_SOURCE[0] == $0` is the canonical "this file is the entry point" check.
# Use a parameter-defaulted access so set -u doesn't trip when the array is
# unset (e.g. when the file is sourced into a function-only context).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  if [ "$#" -eq 0 ]; then
    echo "usage: $0 <tdd-path>..." >&2
    exit 2
  fi
  tl_lint_all "$@"
  exit "$?"
fi

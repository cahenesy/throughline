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

# tl_lint_sequencing — the `## Sequencing / implementation plan` top-level labels
# must be exactly 1, 2, 3, …, N (TDD 0032 §1 / FR-51). The STEP_COMMIT protocol
# carries the Sequencing item's integer index as <step-id>; a non-integer label
# (`5b.`, `3a.`) or a non-sequential list (gaps / duplicates / not starting at 1)
# made an earlier build copy the literal label into the sentinel, which the
# runner's integer-only parser dropped silently — a deadlock the inter-event
# watchdog later mis-classified as transient. Catching it here, at design time,
# is the cheapest of this TDD's four defense layers.
#
# Rules (all `blocker`, code `sequencing.labels`):
#   - A top-level item is a line matching `^[0-9]+[a-zA-Z]*\.` at column 0 inside
#     the section (section ends at the next `^## ` heading or EOF). Indented
#     (nested) list items are not top-level and are excluded by the column-0
#     anchor; fenced (``` or ~~~) lines are ignored (the tl_lint_placeholders
#     convention, extended to ~~~ fences).
#   - Non-integer label → one finding per offending label.
#   - Non-sequential labels (gap / duplicate / not starting at 1) → one finding
#     naming the found list. (Skipped when a non-integer label already fired —
#     a `5b` is reported as non-integer, not also as out-of-sequence.)
#   - No section, or a section with zero numbered items → no finding (a prose-only
#     plan is valid; the build degrades to end-of-build review). Numbered lists in
#     OTHER sections (e.g. `## Verification plan`) are out of scope.
# Exit code follows _tl_emit: 2 on blocker, 0 clean.
tl_lint_sequencing() {  # <tdd-path>
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "tdd-lint: sequencing: input not found: $f" >&2
    return 2
  fi
  awk -v FILE="$f" -v Q="'" '
    BEGIN { in_sec=0; in_fence=0; n=0 }
    # Fence-aware: ``` or ~~~ toggles fenced state; fenced lines are literal text.
    /^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; next }
    # Enter the section on its exact heading (checked before the generic ^##
    # close, which the heading line would otherwise also match).
    !in_fence && /^## Sequencing \/ implementation plan[[:space:]]*$/ { in_sec=1; next }
    !in_fence && /^## / { in_sec=0; next }
    in_sec && !in_fence && /^[0-9]+[a-zA-Z]*\./ {
      lbl = $0
      sub(/\..*/, "", lbl)       # keep the leading token before the first dot
      n++
      labels[n] = lbl
      lines[n]  = NR
    }
    END {
      if (n == 0) exit 0
      bad = 0
      for (i = 1; i <= n; i++) {
        if (labels[i] ~ /[^0-9]/) {
          printf "%s:%d blocker sequencing.labels: non-integer sequencing label %s%s%s — the STEP_COMMIT protocol requires integer step ids (1..N)\n", FILE, lines[i], Q, labels[i], Q
          bad = 1
        }
      }
      if (bad) exit 1
      list = ""; seq_ok = 1
      for (i = 1; i <= n; i++) {
        list = list (i > 1 ? "," : "") labels[i]
        if (labels[i] + 0 != i) seq_ok = 0
      }
      if (!seq_ok) {
        printf "%s:%d blocker sequencing.labels: sequencing labels must be exactly 1..N sequential (found: %s)\n", FILE, lines[1], list
        exit 1
      }
      exit 0
    }
  ' "$f"
  # Map awk{0,1} → rc{0,2}; any other awk exit is a script error (rc 2 + stderr),
  # never silently swallowed (NFR-4, matching tl_lint_placeholders' M2 fix).
  local awk_rc=$?
  case "$awk_rc" in
    0) return 0 ;;
    1) return 2 ;;
    *)
      echo "tdd-lint: sequencing: awk failed (exit $awk_rc) on $f" >&2
      return 2
      ;;
  esac
}

# ============================================================================
# Scope-bound checks (TDD 0014 / FR-53 + FR-54). These are a SEPARATE concern
# from the tl_lint_* structural pre-pass: they enforce the declared-scope bounds
# a TDD authored under FR-53 must respect, and they emit a distinct
# `PRECHECK_FAIL: <check> <details>` line (not the `<file>:<line> <sev> <code>`
# finding format) because /tdd-author's step-7b refusal flow keys its
# three-option AskUserQuestion off that exact prefix.
#
# Three bounds, each env-overridable (matching the THROUGHLINE_REVIEW_MODEL /
# THROUGHLINE_RUNTIME_VERIFY_MODEL pattern from TDD 0013):
#   THROUGHLINE_TDD_MAX_LINES      default 500  (TDD body size)
#   THROUGHLINE_TDD_MAX_FILE_DIFF  default 300  (per-touched-file diff estimate)
#   THROUGHLINE_TDD_MAX_TOUCHED    default 8    (touched-file count)
# A non-positive (or non-integer) value SKIPS that bound entirely — the escape
# valve for /tdd-author re-runs against the legacy TDD set during the Theme D
# refactor period, before the existing drafts gain the two new sections.

# Emit a scope-bound failure line on stdout.
_tl_precheck_fail() {  # <details...>
  printf 'PRECHECK_FAIL: %s\n' "$*"
}

# True when an env-configured bound is an active positive integer; false (skip)
# for empty / non-integer / zero / negative values.
_tl_bound_active() {  # <value>
  printf '%s' "$1" | grep -qE '^[1-9][0-9]*$'
}

# check_tdd_doc_size — count the TDD body (frontmatter excluded: the body is
# everything from the first `^## ` heading through EOF) and fail if it exceeds
# THROUGHLINE_TDD_MAX_LINES.
check_tdd_doc_size() {  # <tdd-path>
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "tdd-lint: doc-size: input not found: $f" >&2
    return 2
  fi
  local max="${THROUGHLINE_TDD_MAX_LINES:-500}"
  _tl_bound_active "$max" || return 0   # non-positive / non-int → skip

  local n awk_rc
  n="$(awk '/^## /{started=1} started{c++} END{print c+0}' "$f")"
  awk_rc=$?
  if [ "$awk_rc" -ne 0 ]; then
    echo "tdd-lint: doc-size: body-count awk failed (exit $awk_rc) on $f" >&2
    return 2
  fi
  if [ "$n" -gt "$max" ]; then
    _tl_precheck_fail "tdd-doc-size $n > $max"
    return 1
  fi
  return 0
}

# _tl_extract_touched_paths <tdd> [mode] — extract one path per `## Touched files`
# bullet (fence/section-aware) using the IDENTICAL em-dash-split + backtick-strip
# + trim logic as gates.sh _rework_touched_files (TDD 0048 / FR-53, FR-54), so the
# design-time and build-time parsers agree (the Verification §2 cross-check asserts
# byte-identical output as the durable guard against a one-sided edit re-introducing
# the drift). The path is whatever precedes the em-dash (`—`, U+2014), or — when a
# bullet has no em-dash — its first whitespace-delimited token; backticks are
# stripped so a bare or backticked path both parse.
#   mode=paths (default): emit each non-empty extracted path (drop empties) — this
#     is the surface the cross-check diffs against _rework_touched_files.
#   mode=malformed: emit the 60-char excerpt of each `- ` bullet whose extracted
#     path is empty (a stray bullet with no parseable path), for the PRECHECK below.
_tl_extract_touched_paths() {  # <tdd> [mode]
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
      if (em > 0) { file = substr(rest, 1, em - 1) }
      else        { file = rest; sub(/[[:space:]].*/, "", file) }  # no em-dash: first token
      gsub(/`/, "", file)                        # strip backticks if the path was quoted
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", file)
      if (MODE == "malformed") { if (file == "") print substr($0, 1, 60) }
      else                     { if (file != "") print file }
    }
  ' "$f"
}

# check_touched_file_count — count `^- \S` entries in the `## Touched files`
# section (fence-aware) and fail if it exceeds THROUGHLINE_TDD_MAX_TOUCHED. A
# missing section is itself a PRECHECK_FAIL (the section is REQUIRED). Also flags
# any bullet that yields no extractable path (TDD 0048 / FR-53, FR-54) via
# `touched-files-malformed`, so a touched-files section the build-time parser
# cannot turn into a scope set is refused at design time rather than discovered as
# a build-time false halt.
check_touched_file_count() {  # <tdd-path>
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "tdd-lint: touched-files: input not found: $f" >&2
    return 2
  fi
  local max="${THROUGHLINE_TDD_MAX_TOUCHED:-8}"
  _tl_bound_active "$max" || return 0   # non-positive / non-int → skip

  local out awk_rc
  out="$(awk '
    BEGIN { in_fence=0; in_sec=0; found=0; n=0 }
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    !in_fence && /^## Touched files[[:space:]]*$/ { in_sec=1; found=1; next }
    !in_fence && /^## / { in_sec=0; next }
    in_sec && !in_fence && /^- [^[:space:]]/ { n++ }
    END { printf "%d %d\n", found, n }
  ' "$f")"
  awk_rc=$?
  if [ "$awk_rc" -ne 0 ]; then
    echo "tdd-lint: touched-files: awk failed (exit $awk_rc) on $f" >&2
    return 2
  fi
  local found="${out%% *}" n="${out##* }"
  if [ "$found" -eq 0 ]; then
    _tl_precheck_fail "missing-section ## Touched files"
    return 1
  fi
  local rc=0
  # TDD 0048 (FR-53/FR-54): flag any bullet the parser cannot turn into a path, so
  # an unparseable touched-files section is refused here rather than at build time.
  local malformed b
  malformed="$(_tl_extract_touched_paths "$f" malformed)"
  if [ -n "$malformed" ]; then
    while IFS= read -r b; do
      [ -n "$b" ] && _tl_precheck_fail "touched-files-malformed $b"
    done <<< "$malformed"
    rc=1
  fi
  if [ "$n" -gt "$max" ]; then
    _tl_precheck_fail "touched-files $n > $max"
    rc=1
  fi
  return "$rc"
}

# check_per_file_diff_bound — parse the `## Expected diff size` section into
# (file, lines, exception?) triples (fence-aware). For any file whose estimate
# exceeds THROUGHLINE_TDD_MAX_FILE_DIFF with no inline `(exception: …)` marker,
# emit a per-file-diff PRECHECK_FAIL. Unparseable entries emit
# expected-diff-malformed; a missing section is a missing-section PRECHECK_FAIL.
# The whole awk pass emits the lines directly and signals via exit code:
#   0 clean, 1 at least one finding, 2 section missing.
check_per_file_diff_bound() {  # <tdd-path>
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "tdd-lint: per-file-diff: input not found: $f" >&2
    return 2
  fi
  local max="${THROUGHLINE_TDD_MAX_FILE_DIFF:-300}"
  _tl_bound_active "$max" || return 0   # non-positive / non-int → skip

  # The em-dash (—) is the file/estimate separator in the declared section; the
  # awk index() below is byte-based so it works regardless of locale.
  local out awk_rc
  out="$(awk -v MAX="$max" '
    BEGIN { in_fence=0; in_sec=0; found=0; fail=0 }
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    !in_fence && /^## Expected diff size[[:space:]]*$/ { in_sec=1; found=1; next }
    !in_fence && /^## / { in_sec=0; next }
    in_sec && !in_fence && /^- [^[:space:]]/ {
      rest = substr($0, 3)                       # strip the leading "- "
      em = index(rest, "—")
      if (em > 0) { file = substr(rest, 1, em - 1) }
      else        { file = rest; sub(/[[:space:]].*/, "", file) }
      gsub(/`/, "", file)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", file)
      if (match(rest, /[0-9]+[[:space:]]*lines?/)) {
        num = substr(rest, RSTART, RLENGTH)
        sub(/[^0-9].*/, "", num)
        n = num + 0
        if (n > MAX && index(rest, "(exception:") == 0) {
          printf "PRECHECK_FAIL: per-file-diff %s %d > %d (no exception)\n", file, n, MAX
          fail = 1
        }
      } else {
        printf "PRECHECK_FAIL: expected-diff-malformed %s\n", $0
        fail = 1
      }
    }
    END {
      if (!found) { printf "PRECHECK_FAIL: missing-section ## Expected diff size\n"; exit 2 }
      exit (fail ? 1 : 0)
    }
  ' "$f")"
  awk_rc=$?
  if [ "$awk_rc" -gt 2 ]; then
    echo "tdd-lint: per-file-diff: awk failed (exit $awk_rc) on $f" >&2
    return 2
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  [ "$awk_rc" -eq 0 ] && return 0
  return 1
}

# tl_check_bounds — run the three scope-bound checks over each TDD. Findings
# always print (PRECHECK_FAIL lines); the exit code is the routable signal:
#   0 — every TDD is within bounds.
#   1 — at least one PRECHECK_FAIL was emitted.
#   2 — a script-level error (missing input / awk crash).
tl_check_bounds() {  # <tdd-path>...
  local rc=0 r tdd
  for tdd in "$@"; do
    if [ ! -f "$tdd" ]; then
      echo "tdd-lint: bounds: input not found: $tdd" >&2
      [ "$rc" -lt 2 ] && rc=2
      continue
    fi
    for fn in check_tdd_doc_size check_touched_file_count check_per_file_diff_bound; do
      "$fn" "$tdd"; r=$?
      [ "$r" -gt "$rc" ] && rc="$r"
    done
  done
  [ "$rc" -gt 2 ] && rc=2
  return "$rc"
}

# tl_lint_all — run the three lints over each TDD in turn. All three lints
# always run (no early-exit) so findings accumulate; the aggregate exit is the
# MAX of any sub-lint's exit code, capped at 2.
tl_lint_all() {  # <tdd-path>...
  local max=0 rc tdd
  for tdd in "$@"; do
    for fn in tl_lint_structural tl_lint_placeholders tl_lint_traced tl_lint_sequencing; do
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
    echo "usage: $0 [--bounds] <tdd-path>..." >&2
    exit 2
  fi
  # `--bounds` runs the TDD 0014 scope-bound checks (PRECHECK_FAIL output);
  # the default path runs the FR-51 structural pre-pass (tl_lint_all).
  if [ "$1" = "--bounds" ]; then
    shift
    if [ "$#" -eq 0 ]; then
      echo "usage: $0 --bounds <tdd-path>..." >&2
      exit 2
    fi
    tl_check_bounds "$@"
    exit "$?"
  fi
  tl_lint_all "$@"
  exit "$?"
fi

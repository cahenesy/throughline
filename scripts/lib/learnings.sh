#!/usr/bin/env bash
# learnings.sh — build-phase learning capture (TDD 0022 / FR-72).
#
# Two public entry points, both pure functions with no top-level side effects so
# this module is SOURCED (by implement.sh, after state.sh — it reuses state.sh's
# _read_fragment_findings reader) and is independently sourceable by the test
# suite:
#
#   detect_build_learnings <state_dir> <logdir> <mainrepo>
#       Mine the per-TDD findings[] (TDD 0021 §6) for RECURRING categorical
#       pattern classes — a non-nit pattern_tag seen across ≥ MIN distinct TDDs
#       OR build steps in this run. Writes <logdir>/candidate-learnings.json and
#       a "## Candidate learnings (pending review)" section in <logdir>/report.md.
#       Writes NOTHING when no class recurs (FR-72 negative case).
#
#   append_accepted_learning <mainrepo> <class> <files_csv> <tags_csv> \
#                            <tdds_csv> <severity_range> <summary> <evidence> \
#                            <runid> [<structural>] [<rework>]
#       Append one accepted-learning entry to <mainrepo>/docs/tdd/LEARNINGS.md
#       (the §2 schema, consumed by TDD 0023), idempotently: a same-class entry
#       whose files= hint set intersects <files_csv> is reinforced (new run id +
#       new slugs) rather than duplicated. The two trailing flag args reconcile
#       the §2 signature (9 positional) with the §2 schema's `Flags:` line: they
#       are additive and default to false, so the documented 9-arg call still
#       works while the skill can pass real flags for TDD 0023.
#
# No external dependencies: bash + state.sh readers; JSON via the canonical
# scripts/lib/json.sh helpers (TDD 0050 — no jq requirement, matching
# status.sh's sed-fallback posture).

# Source the single source of truth for `## Touched files` parsing (TDD 0049 /
# FR-53) by its SIBLING path. learnings.sh sources standalone (the test suite
# does so), so a neutral shared lib both libs source is cleaner than coupling to
# gates.sh being sourced. FATAL-on-missing per ADR 0006 spirit; the dual
# `return 1 2>/dev/null || exit 1` idiom is correct sourced or executed. The lib's
# `_TL_TOUCHED_FILES_SOURCED` include guard makes the double-source under one
# implement.sh (gates.sh AND learnings.sh) a no-op.
_tf_lib="${BASH_SOURCE[0]%/*}/touched-files.sh"
# shellcheck source=scripts/lib/touched-files.sh
{ [ -r "$_tf_lib" ] && . "$_tf_lib"; } || {
  echo "FATAL: cannot source $_tf_lib (partial install or perms)" >&2
  return 1 2>/dev/null || exit 1
}
unset _tf_lib

# Source the canonical JSON helpers (TDD 0050) the same way: learnings.sh
# consumes tl_json_array_ws (and, through it, the C0-complete escaper — the A3
# fix for candidate-learnings.json), so it owns its own source line rather than
# relying on state.sh having been sourced first. Same FATAL-on-missing + dual
# `return||exit` idiom; json.sh's include guard makes the double-source under
# one implement.sh a no-op.
_jlib="${BASH_SOURCE[0]%/*}/json.sh"
# shellcheck source=scripts/lib/json.sh
{ [ -r "$_jlib" ] && . "$_jlib"; } || {
  echo "FATAL: cannot source $_jlib (partial install or perms)" >&2
  return 1 2>/dev/null || exit 1
}
unset _jlib

# --- small helpers ------------------------------------------------------------

# Resolve the recurring threshold (FR-72; resolves the PRD open question).
# THROUGHLINE_LEARNING_MIN_OCCURRENCES default 2; non-numeric → default + warn
# (matching state.sh's env-validation discipline).
_learnings_min() {
  local m="${THROUGHLINE_LEARNING_MIN_OCCURRENCES:-2}"
  case "$m" in ''|*[!0-9]*) echo "warning: THROUGHLINE_LEARNING_MIN_OCCURRENCES='$m' not numeric; using 2" >&2; m=2 ;; esac
  [ "$m" -lt 1 ] 2>/dev/null && m=2
  printf '%s' "$m"
}

# Map a severity name to a comparable rank (nit/unknown → 0, excluded by callers).
_sev_rank() { case "${1:-}" in blocker) echo 3 ;; major) echo 2 ;; minor) echo 1 ;; *) echo 0 ;; esac; }
_sev_name() { case "${1:-}" in 3) echo blocker ;; 2) echo major ;; 1) echo minor ;; *) echo unknown ;; esac; }

_count_words() { local -a _a; read -ra _a <<< "${1:-}"; printf '%s' "${#_a[@]}"; }

# Strip raw CR/LF from a string (defensive — fragment-stored text is already
# json-escaped so it never carries a raw newline, but a hand-built input might).
_jclean() { local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; printf '%s' "$s"; }

# Truncate an (already json-escaped) evidence string to its first 4 `\n`-segments
# and strip raw newlines — so neither writer's output can be corrupted by an
# oversized or newline-bearing quote (TDD 0022 §Failure modes).
_clip_evidence() {
  local s; s="$(_jclean "${1:-}")"
  printf '%s' "$s" | awk '{ n=split($0,a,/\\n/); out=a[1]; for(i=2;i<=n&&i<=4;i++) out=out "\\n" a[i]; printf "%s", out }'
}

# Emit a JSON string-array from a space-separated item list. Thin delegate to
# json.sh's canonical builder (TDD 0050): each item rides the C0-complete
# escaper (safe for the raw `## Touched files` paths — the A3 fix; a no-op for
# the already-escaped slugs). Name kept so every caller and test is untouched.
_json_str_array() {  # <space-separated items>
  tl_json_array_ws "${1:-}"
}

# Read one object-per-line out of a findings array literal. Every finding object
# begins with {"source": (it is built by state.sh's _record_finding), so the
# inter-object separator is `},{"source":` — anchoring the split on that
# structural first-key (not a bare brace) tolerates summary/evidence text that
# happens to contain a brace.
_split_findings_objects() {
  local arr="${1:-}"
  [ -z "$arr" ] && return 0
  arr="${arr#\[}"; arr="${arr%\]}"
  [ -z "$arr" ] && return 0
  printf '%s' "$arr" | sed 's/},{"source":/}\n{"source":/g'
}

# Read one object-per-line out of a step_block_log array literal (TDD 0042 §3).
# step_block_log entries begin with {"pass_id": (built by gates.sh's
# _step_block_entry / _step_block_skip_entry), so the inter-object separator is
# `},{"pass_id":` — the structural-first-key anchor _split_findings_objects uses,
# adapted to this array's first key (so summary/reason text containing a brace is
# tolerated).
_split_step_block_objects() {
  local arr="${1:-}"
  [ -z "$arr" ] && return 0
  arr="${arr#\[}"; arr="${arr%\]}"
  [ -z "$arr" ] && return 0
  printf '%s' "$arr" | sed 's/},{"pass_id":/}\n{"pass_id":/g'
}

# Extract a single string field's value from one finding object, with JSON
# escapes PRESERVED and an embedded \" handled — the walk respects backslash
# escapes and stops at the first UNescaped quote. A naive [^"]* match would
# truncate at an embedded \" and leave a dangling backslash that corrupts the
# re-embedded JSON for quote-bearing review prose (TDD 0022 §Failure modes);
# this returns valid JSON string content, re-embeddable verbatim inside quotes.
_finding_field() {  # <obj> <field>
  printf '%s' "$1" | awk -v K="$2" '
    {
      key = "\"" K "\":\""
      p = index($0, key)
      if (p == 0) { exit }
      s = substr($0, p + length(key)); n = length(s); i = 1; out = ""
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { out = out substr(s, i, 2); i += 2; continue }
        if (c == "\"") break
        out = out c; i++
      }
      printf "%s", out
    }'
}
# Extract the pattern_tags array as a space-separated tag list.
_finding_tags() { printf '%s' "$1" | sed -n 's/.*"pattern_tags":\(\[[^]]*\]\).*/\1/p' | head -1 | tr -d '[]"' | sed 's/,/ /g'; }

# Echo the declared `## Touched files` paths (one per line) of a TDD. Delegates to
# tl_extract_touched_paths (single source of truth, lib/touched-files.sh — TDD
# 0049 / FR-53), so the learning-aggregation path reads the SAME annotation-robust
# set as gates.sh's FR-67(a) reader and tdd-lint.sh's design-time reader (the
# pre-0049 first-backtick-token logic here was the 0044 footgun: it extracted a
# description backtick or dropped a bare path). Signature kept as <mainrepo> <slug>;
# paths-only by intent (learnings never needs `malformed` mode).
_touched_files_of_tdd() {  # <mainrepo> <slug>
  local f="$1/docs/tdd/$2.md"
  [ -f "$f" ] || return 0
  tl_extract_touched_paths "$f"
}

# --- §1: recurring-pattern detection ------------------------------------------

# _fold_pattern_obj <obj> <slug> — fold ONE finding/step_block object's non-nit,
# tagged pattern into the per-class accumulators of the calling detect_build_learnings
# (the C_* associative arrays + `classes` are visible here via bash dynamic scope,
# so both the findings corpus pass and the TDD-0042 step_block_log corpus pass fold
# into the SAME accumulators — one canonical definition of "accumulate a class").
# A nit/unknown-severity or untagged object is skipped (FR-72 step 2). struct/rework
# are derived from the object's own fields (a step_block entry has neither, so they
# read false — matching its telemetry-only shape).
_fold_pattern_obj() {  # <obj> <slug>
  local obj="$1" slug="$2"
  local sev rank; sev="$(_finding_field "$obj" severity)"; rank="$(_sev_rank "$sev")"
  [ "$rank" -eq 0 ] && return 0   # nit / unknown — dropped (FR-72 step 2)
  local pass_id region tags summary evidence struct rework tag stepkey
  pass_id="$(_finding_field "$obj" pass_id)"
  region="$(_finding_field "$obj" region)"
  summary="$(_finding_field "$obj" summary)"
  evidence="$(_finding_field "$obj" evidence)"
  tags="$(_finding_tags "$obj")"
  [ -z "$tags" ] && return 0      # an untagged finding cannot form a class
  struct=0; case "$obj" in *'"structural":true'*) struct=1 ;; esac
  # Rework iff addressed_by_sha is present AND non-null (TDD 0021 §6 stamps a
  # SHA string when a finding triggers rework, TDD 0019). An ABSENT field
  # (a pre-0019 finding / a step_block entry) reads as null → NOT rework.
  rework=0
  case "$obj" in
    *'"addressed_by_sha":null'*) : ;;        # present & null → not rework
    *'"addressed_by_sha":"'*) rework=1 ;;     # present & non-null SHA → rework
    *) : ;;                                    # absent → treat as null
  esac
  for tag in $tags; do
    case " $classes " in *" $tag "*) : ;; *) classes="$classes $tag" ;; esac
    case " ${C_slugs[$tag]:-} " in *" $slug "*) : ;; *) C_slugs[$tag]="${C_slugs[$tag]:-} $slug" ;; esac
    stepkey="$slug|$pass_id"
    case " ${C_steps[$tag]:-} " in *" $stepkey "*) : ;; *) C_steps[$tag]="${C_steps[$tag]:-} $stepkey" ;; esac
    [ "$struct" -eq 1 ] && C_struct[$tag]=1
    [ "$rework" -eq 1 ] && C_rework[$tag]=1
    local cmin="${C_sevmin[$tag]:-}" cmax="${C_sevmax[$tag]:-}"
    { [ -z "$cmin" ] || [ "$rank" -lt "$cmin" ]; } && C_sevmin[$tag]="$rank"
    { [ -z "$cmax" ] || [ "$rank" -gt "$cmax" ]; } && C_sevmax[$tag]="$rank"
    [ -z "${C_summary[$tag]:-}" ] && C_summary[$tag]="$summary"
    [ -z "${C_evidence[$tag]:-}" ] && C_evidence[$tag]="$evidence"
    local occ="{\"slug\":\"$slug\",\"pass_id\":\"$pass_id\",\"severity\":\"$sev\",\"region\":\"$region\"}"
    if [ -z "${C_occ[$tag]:-}" ]; then C_occ[$tag]="$occ"; else C_occ[$tag]="${C_occ[$tag]},$occ"; fi
  done
}

detect_build_learnings() {  # <state_dir> <logdir> <mainrepo>
  local state_dir="$1" logdir="$2" mainrepo="$3"
  [ -d "$state_dir" ] || return 0
  local MIN; MIN="$(_learnings_min)"

  # Per-class accumulators, keyed by pattern_tag. Local associative arrays.
  declare -A C_slugs C_steps C_struct C_rework C_sevmin C_sevmax C_summary C_evidence C_occ
  local classes="" f slug arr obj

  for f in "$state_dir"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "run.json" ] && continue
    slug="$(sed -n 's/.*"slug":"\([^"]*\)".*/\1/p' "$f" | head -1)"
    [ -z "$slug" ] && slug="$(basename "$f" .json)"
    arr="$(_read_fragment_findings "$f")"
    [ -z "$arr" ] && continue
    while IFS= read -r obj; do
      [ -z "$obj" ] && continue
      _fold_pattern_obj "$obj" "$slug"
    done <<< "$(_split_findings_objects "$arr")"
  done

  # TDD 0042 §3: a SECOND corpus pass over each fragment's step_block_log (the
  # per-step BLOCK telemetry the findings ledger never captured). Fold each
  # non-skipped entry into the SAME per-class accumulators via _fold_pattern_obj,
  # so a per-step class (e.g. failing-test-first-violation) recurring across ≥ MIN
  # distinct TDDs surfaces as a candidate (FR-72) → reaches /tdd-author (FR-73).
  # SKIPPED-ENTRY EXCLUSION (design-review finding): unlike findings entries, a
  # step_block_log entry may carry skipped:true (a justified no-new-behavior skip);
  # exclude those BEFORE accumulation with an explicit guard on the raw entry JSON,
  # so a justified skip never inflates a pattern class. The C_slugs distinct-TDD
  # dedup means a class in BOTH findings and step_block_log for one TDD counts that
  # TDD once; the ≥2-distinct-TDD threshold is unchanged. An absent/empty
  # step_block_log returns empty and the fragment is skipped (as findings does).
  local sbarr
  for f in "$state_dir"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "run.json" ] && continue
    slug="$(sed -n 's/.*"slug":"\([^"]*\)".*/\1/p' "$f" | head -1)"
    [ -z "$slug" ] && slug="$(basename "$f" .json)"
    sbarr="$(_read_fragment_step_blocks "$f")"
    [ -z "$sbarr" ] && continue
    while IFS= read -r obj; do
      [ -z "$obj" ] && continue
      case "$obj" in *'"skipped":true'*) continue ;; esac   # justified skip — not a violation
      _fold_pattern_obj "$obj" "$slug"
    done <<< "$(_split_step_block_objects "$sbarr")"
  done

  # Select recurring classes and build both outputs.
  local json_objs="" report_bullets="" any=0 tag
  for tag in $classes; do
    local nslug nstep; nslug="$(_count_words "${C_slugs[$tag]:-}")"; nstep="$(_count_words "${C_steps[$tag]:-}")"
    { [ "$nslug" -lt "$MIN" ] && [ "$nstep" -lt "$MIN" ]; } && continue
    any=1
    # subject-area files = union of every involved TDD's ## Touched files.
    local files="" slug2 p
    for slug2 in ${C_slugs[$tag]}; do
      while IFS= read -r p; do
        [ -z "$p" ] && continue
        case " $files " in *" $p "*) : ;; *) files="$files $p" ;; esac
      done <<< "$(_touched_files_of_tdd "$mainrepo" "$slug2")"
    done
    local smin smax; smin="$(_sev_name "${C_sevmin[$tag]}")"; smax="$(_sev_name "${C_sevmax[$tag]}")"
    local wstruct=false wrework=false
    [ "${C_struct[$tag]:-0}" = 1 ] && wstruct=true
    [ "${C_rework[$tag]:-0}" = 1 ] && wrework=true
    local obj_json
    obj_json="{\"class\":\"$tag\""
    obj_json="$obj_json,\"distinct_tdds\":$(_json_str_array "${C_slugs[$tag]}")"
    obj_json="$obj_json,\"distinct_steps\":$nstep"
    obj_json="$obj_json,\"severity_range\":[\"$smin\",\"$smax\"]"
    obj_json="$obj_json,\"was_structural\":$wstruct,\"triggered_rework\":$wrework"
    obj_json="$obj_json,\"subject_area_hints\":{\"files\":$(_json_str_array "$files"),\"tags\":[\"$tag\"]}"
    obj_json="$obj_json,\"summary\":\"$(_jclean "${C_summary[$tag]:-}")\""
    obj_json="$obj_json,\"evidence\":\"$(_clip_evidence "${C_evidence[$tag]:-}")\""
    obj_json="$obj_json,\"occurrences\":[${C_occ[$tag]:-}]}"
    if [ -z "$json_objs" ]; then json_objs="$obj_json"; else json_objs="$json_objs,$obj_json"; fi
    local tdds_disp flagstr=""
    tdds_disp="$(printf '%s' "${C_slugs[$tag]# }" | sed 's/ /, /g')"
    [ "$wstruct" = true ] && flagstr="$flagstr structural"
    [ "$wrework" = true ] && flagstr="$flagstr rework"
    report_bullets="$report_bullets- **$tag** — recurred across $tdds_disp (${nstep} step(s))${flagstr:+ [flags:$flagstr ]}. $(_jclean "${C_summary[$tag]:-}")"$'\n'
  done

  [ "$any" -eq 0 ] && return 0   # FR-72 negative case: write nothing.

  # Atomic write of candidate-learnings.json (temp + mv, matching state.sh).
  local cl="$logdir/candidate-learnings.json" tmp="$logdir/candidate-learnings.json.tmp.$$"
  if ! printf '[%s]\n' "$json_objs" > "$tmp"; then
    echo "warning: detect_build_learnings: could not write $tmp" >&2; rm -f "$tmp" 2>/dev/null; return 1
  fi
  if ! mv "$tmp" "$cl"; then
    echo "warning: detect_build_learnings: could not place $cl" >&2; rm -f "$tmp" 2>/dev/null; return 1
  fi
  # Append the human-readable report section.
  {
    echo
    echo "## Candidate learnings (pending review)"
    printf '%s' "$report_bullets"
    echo "Run \`/implement\` (or accept the completion callback) to accept or discard these."
  } >> "$logdir/report.md" 2>/dev/null || echo "warning: detect_build_learnings: could not append report section" >&2
  return 0
}

# --- §2: accepted-learning persistence ----------------------------------------

# Emit per existing entry: "<id>\t<class>\t<files-space-joined>" for the
# idempotency scan + numbering.
_learning_blocks() {  # <file>
  awk '
    /^## L-/ {
      if (id != "") print id "\t" cls "\t" files
      id=$0; sub(/^## L-/,"",id); sub(/:.*/,"",id); cls=""; files=""
    }
    /^- Pattern class:/ { c=$0; sub(/^- Pattern class:[[:space:]]*/,"",c); cls=c }
    /^- Subject-area hints:/ {
      if (match($0, /files=\[[^]]*\]/)) {
        seg=substr($0, RSTART, RLENGTH); sub(/files=\[/,"",seg); sub(/\]$/,"",seg)
        gsub(/,/, " ", seg); gsub(/[[:space:]]+/, " ", seg); files=seg
      }
    }
    END { if (id != "") print id "\t" cls "\t" files }
  ' "$1"
}

_files_intersect() {  # <spaceA> <spaceB> — 0 if any token shared
  local a b
  for a in $1; do for b in $2; do [ -n "$a" ] && [ "$a" = "$b" ] && return 0; done; done
  return 1
}

# _candidate_record <candidate-learnings.json> <index>  — emit ONE candidate
# object's persistence fields as a TAB-joined record:
#   class \t files_csv \t tags_csv \t tdds_csv \t severity_range \t summary \t
#   evidence \t structural \t rework
# Parsed by jq → python3 → fail-closed (FR-74 #3: never hand-roll a JSON parser
# for untrusted text). Both parsers escape any tab/newline INSIDE a field so the
# caller's tab-walk split is unambiguous. An out-of-range index yields empty
# output with a zero status; a genuine PARSE failure (malformed JSON) propagates
# the parser's NON-ZERO status (and its diagnostic on stderr) so the caller's `||`
# handler fires and leaves the queue unreviewed — the error path is live, not
# dead. This is also what makes acceptance injection-proof: the candidate's
# summary / evidence (free review prose that may contain quotes, $(…), or
# backticks) is read from the JSON HERE and handed to append_accepted_learning as
# positional args — it is NEVER interpolated into a shell command line.
# _untsv <field> — reverse the @tsv transport escaping (\\ \t \n \r → the literal
# backslash / tab / newline / CR) applied by _candidate_record's jq @tsv / python
# producers. WITHOUT this, a field that legitimately holds a backslash or newline
# is persisted in its transport-escaped form (a doubled backslash, a literal `\n`)
# — corrupting LEARNINGS.md. Single left-to-right pass so `\\n` round-trips to a
# literal `\n`, not backslash+newline.
_untsv() {  # <field>
  printf '%s' "${1:-}" | awk '
    {
      n = length($0); i = 1; out = ""
      while (i <= n) {
        c = substr($0, i, 1)
        if (c == "\\" && i < n) {
          d = substr($0, i + 1, 1)
          if (d == "t") { out = out "\t"; i += 2; continue }
          if (d == "n") { out = out "\n"; i += 2; continue }
          if (d == "r") { out = out "\r"; i += 2; continue }
          if (d == "\\") { out = out "\\"; i += 2; continue }
        }
        out = out c; i++
      }
      printf "%s", out
    }'
}

_candidate_record() {  # <cl> <index>
  local cl="$1" i="$2"
  if command -v jq >/dev/null 2>&1; then
    # No stderr suppression / no forced `return 0`: jq's own exit status is this
    # function's status, so malformed JSON surfaces instead of masquerading as an
    # empty (out-of-range) result.
    jq -r --argjson i "$i" '
      if (length > $i) then .[$i] as $o |
        [ $o.class,
          (($o.subject_area_hints.files // []) | join(",")),
          (($o.subject_area_hints.tags  // []) | join(",")),
          (($o.distinct_tdds // []) | join(",")),
          (($o.severity_range // []) | join("–")),
          ($o.summary // ""), ($o.evidence // ""),
          (($o.was_structural // false)|tostring), (($o.triggered_rework // false)|tostring)
        ] | @tsv
      else empty end' "$cl"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$cl" "$i" <<'PY'
import json, sys
cl, i = sys.argv[1], int(sys.argv[2])
a = json.load(open(cl))
if 0 <= i < len(a):
    o = a[i]; h = o.get("subject_area_hints", {}) or {}
    def j(x): return ",".join(x or [])
    def esc(s): return str(s).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")
    fields = [o.get("class", ""), j(h.get("files")), j(h.get("tags")),
              j(o.get("distinct_tdds")), "–".join(o.get("severity_range", []) or []),
              o.get("summary", ""), o.get("evidence", ""),
              str(o.get("was_structural", False)).lower(), str(o.get("triggered_rework", False)).lower()]
    sys.stdout.write("\t".join(esc(f) for f in fields))
PY
    return
  fi
  echo "error: _candidate_record: neither jq nor python3 available to parse $cl (FR-74 #3 — fail closed rather than hand-roll a JSON parser)" >&2
  return 1
}

# apply_accepted_learnings <logdir> [<index>...]  — persist the human-ACCEPTED
# candidate classes (identified by their 0-based index into
# <logdir>/candidate-learnings.json) to docs/tdd/LEARNINGS.md, then mark the queue
# reviewed (rename → candidate-learnings.reviewed.json). The skill calls this with
# ONLY the logdir + integer indices, so no untrusted candidate prose ever reaches
# the command line (the field values are read from the JSON by _candidate_record).
# Zero indices = accept nothing, just mark reviewed (the all-discarded case). If
# ANY accepted class fails to persist, the queue is left UNREVIEWED and the call
# returns non-zero so the human can retry — never a silent false completion
# (FR-74 #1).
apply_accepted_learnings() {  # <logdir> [<index>...]
  local logdir="${1:-}"; [ "$#" -gt 0 ] && shift
  [ -n "$logdir" ] || { echo "error: apply_accepted_learnings: no logdir given" >&2; return 1; }
  local cl="$logdir/candidate-learnings.json"
  [ -r "$cl" ] || { echo "error: apply_accepted_learnings: no readable candidate-learnings.json at $cl" >&2; return 1; }
  # Derive the repo root DETERMINISTICALLY from the logdir
  # (<mainrepo>/docs/tdd/.implement-logs/<runid> → four levels up) rather than
  # trusting $PWD: a caller in the wrong cwd would otherwise silently write the
  # store to the wrong tree. Validate the result actually holds docs/tdd so a
  # non-standard logdir fails loud instead of writing astray.
  local mainrepo runid; runid="$(basename "$logdir")"
  mainrepo="$(cd "$logdir/../../../.." 2>/dev/null && pwd -P)" \
    || { echo "error: apply_accepted_learnings: cannot resolve the repo root from logdir '$logdir'" >&2; return 1; }
  [ -d "$mainrepo/docs/tdd" ] \
    || { echo "error: apply_accepted_learnings: derived repo root '$mainrepo' has no docs/tdd (logdir not in the expected layout?)" >&2; return 1; }
  local idx rec fail=0 _rest _dec
  local cls files tags tdds sev summ evid struct rew
  local -a _F
  for idx in "$@"; do
    case "$idx" in ''|*[!0-9]*) echo "error: apply_accepted_learnings: non-numeric index '$idx' rejected" >&2; fail=1; continue ;; esac
    rec="$(_candidate_record "$cl" "$idx")" || { echo "error: apply_accepted_learnings: cannot parse candidate index $idx" >&2; fail=1; continue; }
    [ -z "$rec" ] && { echo "error: apply_accepted_learnings: candidate index $idx out of range" >&2; fail=1; continue; }
    # Split the @tsv record on TAB while PRESERVING empty fields. `IFS=$'\t' read`
    # would collapse consecutive tabs (a whitespace-IFS quirk), so an empty field
    # — e.g. files_csv when the involved TDDs declared no `## Touched files` — would
    # be dropped and every later field (summary, evidence, …) would shift left. The
    # @tsv producer escapes any in-field tab/newline, so a literal tab here is
    # always a field boundary; walk them explicitly. Reset the accumulator each
    # iteration (declared once, above the loop).
    _rest="$rec"; _F=()
    while :; do
      _F+=("${_rest%%$'\t'*}")
      case "$_rest" in *$'\t'*) _rest="${_rest#*$'\t'}" ;; *) break ;; esac
    done
    # Reverse the @tsv transport escaping so a backslash / newline in any field is
    # persisted faithfully (not doubled / left as a literal \n). CHECK every
    # decode's exit status: a failed _untsv (e.g. awk unavailable) yields empty
    # output, and silently persisting empty fields + marking the queue reviewed
    # would lose the learning with no retry (FR-74 #1). On any failure, skip this
    # index so `fail=1` leaves the queue unreviewed.
    _dec=1
    cls="$(_untsv "${_F[0]:-}")"    || _dec=0
    files="$(_untsv "${_F[1]:-}")"  || _dec=0
    tags="$(_untsv "${_F[2]:-}")"   || _dec=0
    tdds="$(_untsv "${_F[3]:-}")"   || _dec=0
    sev="$(_untsv "${_F[4]:-}")"    || _dec=0
    summ="$(_untsv "${_F[5]:-}")"   || _dec=0
    evid="$(_untsv "${_F[6]:-}")"   || _dec=0
    struct="$(_untsv "${_F[7]:-}")" || _dec=0
    rew="$(_untsv "${_F[8]:-}")"    || _dec=0
    if [ "$_dec" -ne 1 ]; then
      echo "error: apply_accepted_learnings: field decode (_untsv) failed for index $idx; not persisting (queue left unreviewed)" >&2
      fail=1; continue
    fi
    append_accepted_learning "$mainrepo" "$cls" "$files" "$tags" "$tdds" "$sev" "$summ" "$evid" "$runid" "$struct" "$rew" \
      || { echo "error: apply_accepted_learnings: persist failed for index $idx ($cls)" >&2; fail=1; }
  done
  if [ "$fail" -ne 0 ]; then
    echo "error: apply_accepted_learnings: one or more accepted learnings did not persist; leaving $cl UNREVIEWED for retry" >&2
    return 1
  fi
  # Error-checked reviewed-rename: a failed mv must NOT pass silently — the queue
  # has to visibly re-surface, never vanish (FR-74 #1; no silent false completion).
  if ! mv "$cl" "$logdir/candidate-learnings.reviewed.json"; then
    echo "error: apply_accepted_learnings: could not mark $cl reviewed (mv failed); it will re-surface next run" >&2
    return 1
  fi
  return 0
}

append_accepted_learning() {  # <mainrepo> <class> <files_csv> <tags_csv> <tdds_csv> <severity_range> <summary> <evidence> <runid> [<structural>] [<rework>]
  local mainrepo="$1" class="$2" files_csv="$3" tags_csv="$4" tdds_csv="$5"
  local sev_range="$6" summary="$7" evidence="$8" runid="$9"
  local structural="${10:-false}" rework="${11:-false}"
  local lm="$mainrepo/docs/tdd/LEARNINGS.md" dir hdr
  dir="$(dirname "$lm")"
  hdr='# Build-phase learnings (accepted) — recurring quality patterns mined at run-end (FR-72), advisory context for /tdd-author (FR-73).'
  [ -d "$dir" ] || mkdir -p "$dir" || { echo "error: append_accepted_learning: cannot create $dir" >&2; return 1; }

  local files_space; files_space="$(printf '%s' "$files_csv" | tr ',' ' ')"
  local match_id="" maxnum=0 bid bcls bfiles bn
  if [ -f "$lm" ]; then
    while IFS=$'\t' read -r bid bcls bfiles; do
      [ -z "$bid" ] && continue
      # TDD 0054 A2: guard the id with the numeric predicate BEFORE the 10#
      # arithmetic — a malformed (non-numeric) id is a bash expansion ABORT that
      # `|| bn=0` cannot catch (it kills the whole function mid-scan, so accept
      # fails outright and dedup never reaches later blocks). A malformed id
      # contributes nothing to numbering; the idempotency match still runs so
      # the rest of the scan behaves as if the junk block were well-formed.
      case "$bid" in
        *[!0-9]*) bn=0 ;;
        *) bn=$((10#$bid)) ;;
      esac
      [ "$bn" -gt "$maxnum" ] && maxnum="$bn"
      if [ "$bcls" = "$class" ] && _files_intersect "$bfiles" "$files_space"; then match_id="$bid"; fi
    done <<< "$(_learning_blocks "$lm")"
  fi

  if [ -n "$match_id" ]; then
    # Reinforce the matched entry: add the new run id + any new slugs to its
    # `Recurred across` line (atomic temp + mv). A pattern recurring across runs
    # strengthens ONE entry rather than spawning duplicates.
    local tmp="$lm.tmp.$$"
    if ! awk -v ID="$match_id" -v RUNID="$runid" -v NEWSLUGS="$(printf '%s' "$tdds_csv" | tr ',' ' ')" '
      /^## L-/ { inblk = ($0 ~ ("^## L-" ID ":")) ? 1 : 0 }
      inblk && /^- Recurred across:/ {
        line=$0; lp=index(line,"(")
        if (lp>0) { head=substr(line,1,lp-1); paren=substr(line,lp) } else { head=line; paren="" }
        sub(/[[:space:]]+$/, "", head)
        # Split the existing slug list into EXACT tokens (not substrings): a new
        # slug that happens to be a substring of an existing one must still be
        # added (§2 idempotency must compare whole tokens, not text-contains).
        hs=head; sub(/^.*across:[[:space:]]*/, "", hs)
        delete seen
        ne=split(hs, ex, /,[[:space:]]*/)
        for (j=1;j<=ne;j++) if (ex[j] != "") seen[ex[j]]=1
        n=split(NEWSLUGS, ns, " ")
        for (i=1;i<=n;i++) { s=ns[i]; if (s != "" && !(s in seen)) { head=head ", " s; seen[s]=1 } }
        # Same whole-token test for the run id: tokenize the paren on non-id
        # chars and compare exactly, so e.g. run-11 is not masked by run-111.
        hasrun=0; pp=paren; gsub(/[^A-Za-z0-9_-]/, " ", pp)
        np=split(pp, pw, /[[:space:]]+/); for (j=1;j<=np;j++) if (pw[j]==RUNID) hasrun=1
        if (paren != "" && hasrun==0) sub(/\)[[:space:]]*$/, "; also run " RUNID ")", paren)
        else if (paren == "") paren="(also run " RUNID ")"
        print head " " paren; next
      }
      { print }
    ' "$lm" > "$tmp"; then
      echo "error: append_accepted_learning: reinforce rewrite failed for L-$match_id" >&2; rm -f "$tmp" 2>/dev/null; return 1
    fi
    mv "$tmp" "$lm" || { echo "error: append_accepted_learning: could not place reinforced $lm" >&2; rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
  fi

  # No match — append a fresh entry numbered after the highest existing one.
  # Atomic write (temp + mv, matching state.sh's convention / §2): rewrite the
  # whole file (existing content or a fresh header) plus the new block, so a
  # reader never sees a torn half-written entry.
  local nnn tdds_disp files_disp tags_disp tmp="$lm.tmp.$$"
  nnn="$(printf '%03d' $((maxnum + 1)))"
  tdds_disp="$(printf '%s' "$tdds_csv" | sed 's/,/, /g')"
  files_disp="$(printf '%s' "$files_csv" | sed 's/,/, /g')"
  tags_disp="$(printf '%s' "$tags_csv" | sed 's/,/, /g')"
  {
    if [ -f "$lm" ]; then cat "$lm"; else printf '%s\n' "$hdr"; fi
    echo
    echo "## L-$nnn: $class"
    echo "- Pattern class: $class"
    echo "- Recurred across: $tdds_disp (first observed run $runid)"
    echo "- Severity range: $sev_range"
    echo "- Subject-area hints: files=[$files_disp] tags=[$tags_disp]"
    echo "- Flags: structural=$structural rework=$rework"
    echo "- Summary: $(_jclean "$summary")"
    echo "- Representative evidence: $(_clip_evidence "$evidence")"
  } > "$tmp" || { echo "error: append_accepted_learning: could not write $tmp" >&2; rm -f "$tmp" 2>/dev/null; return 1; }
  mv "$tmp" "$lm" || { echo "error: append_accepted_learning: could not place $lm" >&2; rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

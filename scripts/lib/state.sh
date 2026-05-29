#!/usr/bin/env bash
# state.sh — Atomic JSON fragment I/O for run-state and per-TDD records.
#
# Extracted from scripts/implement.sh per TDD 0015 (Theme D slice 1/3, FR-69):
# the cohesive cluster of functions that read, validate, and write the per-run
# run.json and per-TDD <slug>.json fragments under
# docs/tdd/.implement-logs/<runid>/state.d/. Every function here either parses a
# fragment field or writes one; cause-classification, gate-driving, and resume
# orchestration stay in implement.sh (and move in slices 2/3).
#
# This module is SOURCED by implement.sh, not executed: it has no top-level side
# effects, and it shares the outer shell's scope for the state variables the
# functions read ($STATE_DIR, $LOGDIR, $REPORT, $STATE_STARTED_AT, $STATE_MODE,
# $INTEGRATION, $CHANGE, $MAINREPO, $TDDS, $RESUME, ...), which the runner sets
# before these functions are called. Shared scope is deliberate for this dogfood
# slice; a future change that wants state.sh as a standalone library would
# parameterize those instead.

# --- run-state record (FR-27) --------------------------------------------------
# A per-run directory of atomic JSON fragments at $LOGDIR/state.d/:
#   run.json       — run-level rollup + identity
#   <slug>.json    — one per queued TDD (queue_pos, status, current stage, …)
# Each writer owns its own file, so there is no lock and no race even under
# --parallel (where each subshell only writes its own slug.json). The renderer
# (scripts/status.sh) is the single consumer; it re-rollups counts at read time,
# so run.json's counts are advisory — the per-TDD fragments are the truth.
# Atomic write = `printf` to <file>.tmp then `mv`, so a reader sees the old or
# the new file but never a torn one.

# Read a single string-valued JSON field from a fragment, decoded back to the
# raw string (or empty when the field is missing or `null`). Used by the FR-39
# resume path so the additive fields survive a `set_tdd_state` rewrite.
# TDD 0011 / iter-3 MAJOR-4: validate the field-name parameter is a plain
# identifier before it is interpolated into grep/sed patterns. All current
# call sites pass hard-coded literals, but defending here means a future
# caller passing a name with `|`, `/`, or other metacharacters cannot
# corrupt the pattern or sed delimiter (which would produce silent
# wrong-field reads).
_validate_field_name() {  # <field-name> — return 0 if safe, 1 otherwise
  case "${1:-}" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
    *) return 0 ;;
  esac
}
_read_fragment_field() {  # <file> <field-name>  -> echoes the value (no quotes)
  local f="$1" k="$2"
  _validate_field_name "$k" || { echo "error: _read_fragment_field rejected unsafe field name '$k'" >&2; return 1; }
  if grep -q "\"$k\":null" "$f" 2>/dev/null; then printf ''; return 0; fi
  sed -n "s/.*\"$k\":\"\\([^\"]*\\)\".*/\\1/p" "$f" | head -1
}
# Read a JSON string-array field (e.g. gates_completed) as a comma-separated list
# of its members. Empty when the array is `[]` or absent.
_read_fragment_array_csv() {  # <file> <field-name>
  local f="$1" k="$2" raw
  _validate_field_name "$k" || { echo "error: _read_fragment_array_csv rejected unsafe field name '$k'" >&2; return 1; }
  raw="$(sed -n "s/.*\"$k\":\\(\\[[^]]*\\]\\).*/\\1/p" "$f" | head -1)"
  [ -z "$raw" ] && return 0
  [ "$raw" = "[]" ] && return 0
  printf '%s' "$raw" | tr -d '[]"' | sed 's/, */,/g'
}
# Read a raw JSON array literal (used for the structured `retries` array — its
# nested objects don't fit the CSV scheme above).
_read_fragment_raw_array() {  # <file> <field-name>
  local f="$1" k="$2"
  _validate_field_name "$k" || { echo "error: _read_fragment_raw_array rejected unsafe field name '$k'" >&2; return 1; }
  # Greedy-match the array literal up to its closing bracket. The retries
  # array's elements are flat objects, so a single-level bracket match works.
  sed -n "s/.*\"$k\":\\(\\[[^]]*\\]\\).*/\\1/p" "$f" | head -1
}

# Escape a string for safe inclusion as a JSON string value. Free-text fields
# (note/branch/pr_url/log) ride through this; structural fields are integers or
# enums so they don't need it.
json_escape() {
  local s="${1:-}"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# _write_tdd_fragment <slug> <n> <path> <qp> <status> <stage> <started> <updated>
#                     <branch> <pr_url> <log> <note>
#                     [<paused_cause> <gates_completed_csv> <retries_json> <branch_head>]
# stage="" → JSON `null` literal; non-empty → quoted string (matches the TDD's
# `stage ∈ {build, test-first, verify, verify-runtime, review, flip, null}`).
# The four trailing params (TDD 0011 / FR-39..FR-45) are additive and optional:
#   paused_cause       free-text (or empty → JSON null)
#   gates_completed    comma-separated list (or empty → [])
#   retries_json       a complete JSON array literal (or empty → [])
#   branch_head_at_pause   commit SHA at pause time (or empty → JSON null)
# Callers that do not need them omit them; the existing twelve-param call sites
# continue to work unchanged.
_write_tdd_fragment() {
  local slug="$1" n="$2" path="$3" qp="$4" status="$5" stage="$6" sta="$7" upd="$8"
  local branch="$9" pr_url="${10}" log="${11}" note="${12}"
  local paused_cause="${13:-}" gates_csv="${14:-}" retries_json="${15:-}" branch_head="${16:-}"
  local stage_lit cause_lit head_lit gates_lit retries_lit
  if [ -z "$stage" ]; then stage_lit='null'
  else stage_lit="\"$(json_escape "$stage")\""; fi
  if [ -z "$paused_cause" ]; then cause_lit='null'
  else cause_lit="\"$(json_escape "$paused_cause")\""; fi
  if [ -z "$branch_head" ]; then head_lit='null'
  else head_lit="\"$(json_escape "$branch_head")\""; fi
  if [ -z "$gates_csv" ]; then
    gates_lit='[]'
  else
    # Split CSV → JSON string array. Each entry is JSON-escaped.
    local g entry first=1
    gates_lit='['
    local IFS=','; for g in $gates_csv; do
      if [ -n "$g" ]; then
        entry="\"$(json_escape "$g")\""
        if [ "$first" -eq 1 ]; then gates_lit+="$entry"; first=0
        else gates_lit+=",$entry"; fi
      fi
    done
    gates_lit+=']'
  fi
  if [ -z "$retries_json" ]; then retries_lit='[]'
  else retries_lit="$retries_json"; fi
  # Split the `local` declaration: under bash 5.3 `set -u`, a single
  # `local f="..." tmp="$f..."` raises 'f: unbound variable' because the
  # `tmp` initializer references `$f` before the local declaration has bound
  # it. Two separate assignments avoid the ordering issue.
  local f tmp
  f="$STATE_DIR/$slug.json"
  tmp="$f.tmp.$$"
  # TDD 0011 / iter-3 MAJOR-5: detect printf or mv failure. A disk-full
  # or permission failure on `printf > $tmp` under set -uo pipefail (no -e)
  # would not abort the runner; mv would then atomically replace the live
  # fragment with a corrupted/empty one, and subsequent reads would
  # round-trip empty values back. Bail loudly instead so the run is
  # halted while data is still recoverable.
  if ! printf '{"n":%d,"slug":"%s","path":"%s","queue_pos":%d,"status":"%s","stage":%s,"started_at":%d,"updated_at":%d,"branch":"%s","pr_url":"%s","log":"%s","note":"%s","paused_cause":%s,"gates_completed":%s,"retries":%s,"branch_head_at_pause":%s}\n' \
    "$n" "$(json_escape "$slug")" "$(json_escape "$path")" "$qp" \
    "$(json_escape "$status")" "$stage_lit" \
    "$sta" "$upd" \
    "$(json_escape "$branch")" "$(json_escape "$pr_url")" "$(json_escape "$log")" \
    "$(json_escape "$note")" \
    "$cause_lit" "$gates_lit" "$retries_lit" "$head_lit" \
    > "$tmp"; then
    echo "error: _write_tdd_fragment printf failed for $slug (disk full? perm?); fragment NOT updated" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv "$tmp" "$f"; then
    echo "error: _write_tdd_fragment mv failed for $slug; fragment may be stale" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# Re-roll the run-level rollup from per-TDD fragments and rewrite run.json.
# state ∈ {running, done, paused}. Called by state_init (running), at run end
# (done), and by _enter_paused (paused). When state is paused, pause_started_at
# is stamped (display only).
_write_run_fragment() {
  local state="$1" tmp="$STATE_DIR/run.json.tmp.$$"
  local total="${#TDDS[@]}"
  local completed=0 failed=0 blocked=0 skipped=0 paused=0 st f
  if [ -d "$STATE_DIR" ]; then
    for f in "$STATE_DIR"/*.json; do
      [ -f "$f" ] || continue
      [ "$(basename "$f")" = "run.json" ] && continue
      st="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
      case "$st" in
        done)    completed=$((completed+1)) ;;
        failed)  failed=$((failed+1)) ;;
        blocked) blocked=$((blocked+1)) ;;
        skipped) skipped=$((skipped+1)) ;;
        paused)  paused=$((paused+1)) ;;
      esac
    done
  fi
  # TDD 0011 / iter-5 MAJOR-4: preserve pause_started_at across writes.
  # The previous code stamped a fresh `date +%s` on every `paused` write,
  # so a second TDD pausing in a parallel run would overwrite the first's
  # timestamp. Read the existing value and reuse it if the run was already
  # paused; only stamp on the first transition into paused.
  local pause_started_lit='null'
  if [ "$state" = "paused" ]; then
    local _prior_pause=""
    if [ -f "$STATE_DIR/run.json" ]; then
      _prior_pause="$(sed -n 's/.*"pause_started_at":\([0-9]*\).*/\1/p' "$STATE_DIR/run.json" | head -1)"
    fi
    if [ -n "$_prior_pause" ] && [ "$_prior_pause" != "null" ] && [ "$_prior_pause" -gt 0 ] 2>/dev/null; then
      pause_started_lit="$_prior_pause"
    else
      pause_started_lit="$(date +%s)"
    fi
  fi
  # TDD 0011 / iter-3 MAJOR-5: same printf+mv failure handling as
  # _write_tdd_fragment.
  if ! printf '{"schema":1,"started_at":%d,"updated_at":%d,"pid":%d,"integration_branch":"%s","mode":"%s","change":"%s","logdir":"%s","total":%d,"completed":%d,"failed":%d,"blocked":%d,"skipped":%d,"paused":%d,"state":"%s","pause_started_at":%s}\n' \
    "$STATE_STARTED_AT" "$(date +%s)" "$$" \
    "$(json_escape "$INTEGRATION")" "$STATE_MODE" "$(json_escape "$CHANGE")" "$(json_escape "$LOGDIR")" \
    "$total" "$completed" "$failed" "$blocked" "$skipped" "$paused" \
    "$(json_escape "$state")" "$pause_started_lit" \
    > "$tmp"; then
    echo "error: _write_run_fragment printf failed; run.json NOT updated" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv "$tmp" "$STATE_DIR/run.json"; then
    echo "error: _write_run_fragment mv failed; run.json may be stale" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# state_init — at run start: create state.d/, write a pending <slug>.json per
# queued TDD (with its `n` and 1-based queue_pos for THIS run), write run.json
# in state=running, and point the `latest` symlink at this run's <ts> dir. The
# single-run lock (FR-18) means one writer for `latest`, so the brief non-atomic
# relink window is inconsequential.
state_init() {
  STATE_DIR="$LOGDIR/state.d"
  mkdir -p "$STATE_DIR"
  # On --resume (TDD 0011 / FR-40) the state.d already contains paused
  # fragments from the prior run. Reuse the prior started_at and mode so
  # the run-level header remains coherent; do not overwrite per-TDD
  # fragments (the paused state IS the resume signal).
  if [ "${RESUME:-0}" -eq 1 ] && [ -f "$STATE_DIR/run.json" ]; then
    # TDD 0011 / iter-3 BLOCKER-1: schema-version refusal gate. TDD 0011
    # §"Schema-version policy" mandates that a resuming runner against
    # `schema != 1` refuses with the exact spec'd message and exits
    # before any further state mutation. Additive changes (new field,
    # new enum value) stay at schema 1; breaking changes bump to 2 and
    # force a fresh-start.
    local _resume_schema
    _resume_schema="$(sed -n 's/.*"schema":\([0-9]*\).*/\1/p' "$STATE_DIR/run.json" | head -1)"
    # TDD 0011 / iter-6 MAJOR-3: an absent/empty schema field is NOT
    # schema 1 — it's an unknown / truncated state record, which per
    # TDD §schema-version-policy must refuse to resume. The previous
    # `[ -n "$x" ] && [ "$x" != "1" ]` short-circuited the refusal on
    # empty input.
    if [ -z "$_resume_schema" ] || [ "$_resume_schema" != "1" ]; then
      echo "paused-run schema '${_resume_schema:-missing}' not compatible with this plugin version; resume not possible (see docs/tdd/0011)" | tee -a "$REPORT" >&2
      exit 1
    fi
    STATE_STARTED_AT="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p' "$STATE_DIR/run.json" | head -1)"
    STATE_MODE="$(sed -n 's/.*"mode":"\([^"]*\)".*/\1/p' "$STATE_DIR/run.json" | head -1)"
    [ -z "$STATE_STARTED_AT" ] && STATE_STARTED_AT=$(date +%s)
    [ -z "$STATE_MODE" ] && STATE_MODE="sequential"
    # TDD 0011 / iter-5 BLOCKER-1+2: restore the CLI flags that drive
    # branch naming and driver dispatch. Without these, a resume gets
    # a FRESH timestamped $CHANGE (so the sequential driver computes
    # branch names that don't exist) and runs the sequential driver
    # even for a paused parallel/combined run.
    local _resume_change _resume_mode
    _resume_change="$(sed -n 's/.*"change":"\([^"]*\)".*/\1/p' "$STATE_DIR/run.json" | head -1)"
    _resume_mode="$STATE_MODE"
    # Only override $CHANGE if the caller didn't pass --change explicitly.
    # The default CHANGE format from the runner is "build/<ts>"; if the
    # current value still matches that pattern, the caller used the
    # default and we should restore the paused run's value.
    if [ -n "$_resume_change" ] && [ "$CHANGE" != "$_resume_change" ]; then
      case "$CHANGE" in
        build/[0-9]*-[0-9]*) CHANGE="$_resume_change" ;;
        *) : ;;   # explicit --change was passed; respect it
      esac
    fi
    case "$_resume_mode" in
      parallel) PARALLEL=1; COMBINED=0 ;;
      combined) PARALLEL=0; COMBINED=1 ;;
      sequential|*) PARALLEL=0; COMBINED=0 ;;
    esac
    # TDD 0011 / MA-4: queue freeze. Newly-buildable TDDs that appeared on the
    # integration branch BETWEEN pause and resume must NOT be built by this
    # resuming run — resume's contract is "pick up where you left off", not
    # "resume + grow." Diff the discovered queue against the existing state
    # fragments; drop newcomers from TDDS and surface them in the report so
    # the user can run /implement again after resume completes to build them.
    local _kept=() _path _slug
    for _path in "${TDDS[@]}"; do
      _slug="$(basename "$_path" .md)"
      if [ -f "$STATE_DIR/$_slug.json" ]; then
        _kept+=("$_path")
      else
        echo "Skipping $_slug: newly-buildable, not in paused queue (run /implement after resume completes to build it)" | tee -a "$REPORT"
      fi
    done
    TDDS=("${_kept[@]}")
    # TDD 0011 / MAJOR-8: if EVERY TDD in the new buildable set is a
    # newcomer (so _kept is empty), there is nothing to resume — the
    # drivers would no-op silently and leave the run in `paused` with
    # `total=0`. Emit a clear message and exit so the user knows the
    # next concrete step.
    if [ "${#TDDS[@]}" -eq 0 ]; then
      echo "No TDDs to resume: every queued buildable TDD is newly-added since the pause. Run /implement (without --resume) to build them." | tee -a "$REPORT"
      # TDD 0011 / iter-4 MAJOR-6: surface write failures on this
      # early-exit path. A disk-full here would otherwise leave
      # run.json in the prior `paused` state while the script exits
      # 0 — status.sh would show "still paused with nothing to do."
      _write_run_fragment running \
        || echo "warning: state_init exit-path: run.json running update failed" | tee -a "$REPORT" >&2
      _write_run_fragment done \
        || echo "warning: state_init exit-path: run.json done update failed" | tee -a "$REPORT" >&2
      ln -sfn "$(basename "$LOGDIR")" "$MAINREPO/docs/tdd/.implement-logs/latest" 2>/dev/null || true
      exit 0
    fi
    # TDD 0011 / iter-6 MAJOR-2: guard the main resume-path's run.json
    # flip. The two early-exit paths above already check; this one was
    # the silent gap. A disk-full here would otherwise leave run.json
    # at `paused` for the entire resumed run, and again at run-end
    # (the same disk-full prevents the final `done` write), permanently
    # confusing status.sh.
    _write_run_fragment running \
      || { echo "FATAL: state_init resume could not write run.json (running state)" | tee -a "$REPORT" >&2; exit 1; }
    ln -sfn "$(basename "$LOGDIR")" "$MAINREPO/docs/tdd/.implement-logs/latest" 2>/dev/null || true
    return 0
  fi
  STATE_STARTED_AT=$(date +%s)
  if   [ "$PARALLEL" -eq 1 ]; then STATE_MODE="parallel"
  elif [ "$COMBINED" -eq 1 ]; then STATE_MODE="combined"
  else                             STATE_MODE="sequential"; fi
  local i=0 path slug n
  for path in "${TDDS[@]}"; do
    i=$((i+1))
    slug="$(basename "$path" .md)"
    n=$((10#${slug%%-*}))
    # TDD 0011 / iter-5 MAJOR-2: fail loudly on fresh-start fragment-write
    # failures. A disk-full here would otherwise produce empty/missing
    # fragments that subsequent set_tdd_state reads round-trip as empty.
    if ! _write_tdd_fragment "$slug" "$n" "$path" "$i" pending "" \
      "$STATE_STARTED_AT" "$STATE_STARTED_AT" "" "" "" "" \
      "" "" "" ""; then
      echo "FATAL: state_init could not write initial fragment for $slug" | tee -a "$REPORT" >&2
      exit 1
    fi
  done
  _write_run_fragment running \
    || { echo "FATAL: state_init could not write initial run.json" | tee -a "$REPORT" >&2; exit 1; }
  ln -sfn "$(basename "$LOGDIR")" "$MAINREPO/docs/tdd/.implement-logs/latest" 2>/dev/null || true
}

# set_run_state <state>  — rewrite run.json (refresh updated_at + rollup counts).
set_run_state() { _write_run_fragment "$1"; }

# _terminal_state <slug> <status> [stage] [note]
# TDD 0011 / iter-10 M-1+M-2: wrapper around set_tdd_state that surfaces
# write failures at TERMINAL verdict points (done/failed/blocked/skipped/
# paused). A swallowed failure here would leave the fragment stuck in a
# pre-terminal stage (building/verifying/reviewing) forever, violating
# FR-44 (run-state record remains internally consistent). The wrapper
# echoes to stderr AND appends to $REPORT so a disk-full at the verdict
# write is visible in the human-readable summary, not just lost to a
# detached process's discarded stderr.
_terminal_state() {
  local slug="$1" status="$2"
  if ! set_tdd_state "$@"; then
    local msg="warning: could not write terminal verdict status=$status for $slug (fragment may be stale)"
    echo "$msg" >&2
    [ -n "${REPORT:-}" ] && [ -w "$(dirname "${REPORT}")" ] 2>/dev/null && echo "$msg" >> "$REPORT"
    return 1
  fi
}

# set_tdd_state <slug> <status> <stage> [note] [gate-completed-append]
# Rewrite that TDD's fragment atomically; carry n/queue_pos/path/started_at/
# branch/pr_url/log + the FR-39..45 additive fields forward. `stage=""` writes
# JSON null. The optional 5th param `gate-completed-append` (TDD 0011) appends
# a gate name to the carried-forward `gates_completed` array IF it is not
# already present — used by gate_one to record progressive gate completion
# (FR-40 / FR-44).
set_tdd_state() {
  local slug="$1" status="$2" stage="$3" note="${4:-}" gate_done="${5:-}"
  local f="${STATE_DIR:-}/$slug.json"
  [ -n "$STATE_DIR" ] && [ -f "$f" ] || return 0
  local n qp path sta branch pr_url log now
  local paused_cause gates_csv retries_json branch_head
  n="$(sed -n 's/.*"n":\([0-9]*\).*/\1/p'            "$f" | head -1)"
  qp="$(sed -n 's/.*"queue_pos":\([0-9]*\).*/\1/p'   "$f" | head -1)"
  path="$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  sta="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
  branch="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  pr_url="$(sed -n 's/.*"pr_url":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  log="$(sed -n 's/.*"log":"\([^"]*\)".*/\1/p'       "$f" | head -1)"
  paused_cause="$(_read_fragment_field "$f" paused_cause)"
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"
  retries_json="$(_read_fragment_raw_array "$f" retries)"
  branch_head="$(_read_fragment_field "$f" branch_head_at_pause)"
  if [ -n "$gate_done" ]; then
    case ",$gates_csv," in
      *",$gate_done,"*) : ;;  # already recorded; idempotent
      *) if [ -z "$gates_csv" ]; then gates_csv="$gate_done"
         else gates_csv="$gates_csv,$gate_done"; fi ;;
    esac
  fi
  # TDD 0011 / iter-5 MAJOR-3: clear paused_cause when status leaves paused.
  # Otherwise a fragment that goes paused → building → done retains a stale
  # paused_cause label, confusing any forensic consumer.
  if [ "$status" != "paused" ]; then paused_cause=""; fi
  now=$(date +%s)
  # TDD 0011 / iter-5 MAJOR-1: propagate _write_tdd_fragment failures so
  # the runner doesn't silently continue with a stale fragment.
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$now}" "$now" "$branch" "$pr_url" "$log" "$note" \
    "$paused_cause" "$gates_csv" "$retries_json" "$branch_head"; then
    echo "error: set_tdd_state: could not write $slug fragment (status=$status)" >&2
    return 1
  fi
}

# set_tdd_meta <slug> [branch=<v>] [pr_url=<v>] [log=<v>] [note=<v>]
# Update branch/pr_url/log/note while preserving status/stage and the FR-39..45
# additive fields. Used after PR creation to record `branch`/`pr_url` against
# the existing fragment.
set_tdd_meta() {
  local slug="$1"; shift
  local f="${STATE_DIR:-}/$slug.json"
  [ -n "$STATE_DIR" ] && [ -f "$f" ] || return 0
  local n qp path status stage sta branch pr_url log note kv now
  local paused_cause gates_csv retries_json branch_head
  n="$(sed -n 's/.*"n":\([0-9]*\).*/\1/p'            "$f" | head -1)"
  qp="$(sed -n 's/.*"queue_pos":\([0-9]*\).*/\1/p'   "$f" | head -1)"
  path="$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  status="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  if grep -q '"stage":null' "$f" 2>/dev/null; then stage=""
  else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
  sta="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
  branch="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  pr_url="$(sed -n 's/.*"pr_url":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  log="$(sed -n 's/.*"log":"\([^"]*\)".*/\1/p'       "$f" | head -1)"
  note="$(sed -n 's/.*"note":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  paused_cause="$(_read_fragment_field "$f" paused_cause)"
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"
  retries_json="$(_read_fragment_raw_array "$f" retries)"
  branch_head="$(_read_fragment_field "$f" branch_head_at_pause)"
  for kv in "$@"; do case "$kv" in
    branch=*) branch="${kv#branch=}" ;;
    pr_url=*) pr_url="${kv#pr_url=}" ;;
    log=*)    log="${kv#log=}" ;;
    note=*)   note="${kv#note=}" ;;
  esac; done
  now=$(date +%s)
  # TDD 0011 / iter-5 MAJOR-1: propagate write failures.
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$now}" "$now" "$branch" "$pr_url" "$log" "$note" \
    "$paused_cause" "$gates_csv" "$retries_json" "$branch_head"; then
    echo "error: set_tdd_meta: could not write $slug fragment" >&2
    return 1
  fi
}

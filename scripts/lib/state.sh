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
  local v
  v="$(sed -n "s/.*\"$k\":\"\\([^\"]*\\)\".*/\\1/p" "$f" | head -1)"
  # TDD 0018 backward-compat shim (§Data): a TDD-0008/0011-shape fragment has no
  # halt_cause field at all. When a new reader asks for halt_cause on such a
  # fragment, fall back to paused_cause so the unified taxonomy still surfaces
  # the carried cause. Only applies when halt_cause is genuinely ABSENT (an
  # explicit halt_cause:null is honored as empty, matching the early return).
  if [ -z "$v" ] && [ "$k" = "halt_cause" ] && ! grep -q '"halt_cause":' "$f" 2>/dev/null; then
    v="$(sed -n 's/.*"paused_cause":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  fi
  printf '%s' "$v"
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
# Read a raw JSON object literal (TDD 0019: rework_attempts + build_attempt).
# A single-level `{…}` match — the rework_attempts map's values are integers and
# build_attempt's only field is an int|null, so neither nests an object. A
# `"<field>":null` (or absent field) reads as empty, matching the callers' "no
# value yet" default.
_read_fragment_raw_object() {  # <file> <field-name>
  local f="$1" k="$2"
  _validate_field_name "$k" || { echo "error: _read_fragment_raw_object rejected unsafe field name '$k'" >&2; return 1; }
  sed -n "s/.*\"$k\":\\({[^}]*}\\).*/\\1/p" "$f" | head -1
}
# Read the cleared_step_log array (TDD 0020). Its entries nest pattern_tags
# arrays, so the flat _read_fragment_raw_array regex (`\[[^]]*\]`, which stops at
# the FIRST `]`) would truncate it mid-array and corrupt the JSON on the next
# carry-forward write (FR-44). cleared_step_log is the LAST fragment field, so a
# greedy match anchored to the fragment's closing brace captures the whole array
# including nested brackets. INVARIANT: cleared_step_log must remain the last
# field written by _write_tdd_fragment's printf — if a field is ever added after
# it, update this reader's anchor. Empty/`[]`/absent → empty (matching the other
# readers' "no value yet" default).
_read_fragment_cleared_log() {  # <file>
  local f="$1" raw
  raw="$(sed -n 's/.*"cleared_step_log":\(\[.*\]\)}[[:space:]]*$/\1/p' "$f" | head -1)"
  [ "$raw" = "[]" ] && return 0
  printf '%s' "$raw"
}
# Read the findings array (TDD 0021 §6). Like cleared_step_log it nests objects,
# so the flat _read_fragment_raw_array regex would truncate it at the first `]`.
# findings is NOT the last field (self_review_count / re_review_attempts /
# last_cleared_review_sha / cleared_step_log follow it), so we anchor the greedy
# array match on the field that immediately follows — `,"self_review_count":`,
# which appears exactly once — instead of the fragment's closing brace. INVARIANT:
# findings must remain immediately before self_review_count in _write_tdd_fragment's
# printf. Empty/`[]`/absent → empty (matching the other readers' "no value yet"
# default).
_read_fragment_findings() {  # <file>
  local f="$1" raw
  raw="$(sed -n 's/.*"findings":\(\[.*\]\),"self_review_count":.*/\1/p' "$f" | head -1)"
  [ "$raw" = "[]" ] && return 0
  printf '%s' "$raw"
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
#                     [<halt_cause> <halt_finding_ref> <halt_next_actions_csv> <halt_detail>]
# stage="" → JSON `null` literal; non-empty → quoted string (matches the TDD's
# `stage ∈ {build, test-first, verify, verify-runtime, review, flip, null}`).
# The four params 13..16 (TDD 0011 / FR-39..FR-45) are additive and optional:
#   paused_cause       free-text (or empty → JSON null)
#   gates_completed    comma-separated list (or empty → [])
#   retries_json       a complete JSON array literal (or empty → [])
#   branch_head_at_pause   commit SHA at pause time (or empty → JSON null)
# The four params 17..20 (TDD 0018 / FR-63..FR-64) are likewise additive:
#   halt_cause          one of the closed enum (or empty → JSON null)
#   halt_finding_ref    <review-pass-id>:<finding-index> (or empty → JSON null)
#   halt_next_actions   comma-separated label list (or empty → []); labels never
#                       contain commas, so CSV round-trips losslessly
#   halt_cause_detail   free-text sub-classification (or empty → JSON null)
# The three params 21..23 (TDD 0019 / FR-65, FR-68) are likewise additive:
#   rework_attempts   a complete JSON object literal (or empty → {}); keyed by
#                     "<gate>:<step>" → int attempt count
#   rework_log        a complete JSON array literal (or empty → []); per-attempt
#                     telemetry objects (attempt/gate/step/model/token_spend/…)
#   build_attempt     a complete JSON object literal (or empty → null); holds
#                     the original build attempt's token_spend for the FR-68
#                     rework-vs-original comparison
# The two params 24..25 (TDD 0020 / FR-57, FR-59; ADR 0006) are likewise additive:
#   last_cleared_review_sha   the head SHA the last per-step or consolidated
#                             review pass cleared (or empty → JSON null)
#   cleared_step_log          a complete JSON array literal (or empty → []);
#                             per-cleared-step objects {step_id, base_sha,
#                             head_sha, pattern_tags[], cleared_at}
# The three params 26..28 (TDD 0021 / FR-58, FR-60, FR-70, FR-71; §6) are
# CUMULATIVE-by-default. Unlike every field above (which a caller omitting the
# param resets to its empty default), these three are PRESERVED from the
# on-disk fragment when the param is ABSENT (arg count < 26/27/28). This is a
# deliberate convention shift: the cumulative findings ledger + self-review
# counter + re-review counter must survive every status/halt/rework transition,
# and there are EIGHT carry-forward writers (set_tdd_state, set_tdd_meta,
# set_halt_cause, _rewrite_fragment_rework, _record_cleared_step, the two
# pause-retry writers, the resume writer) — threading three new reads + args
# through all eight is error-prone and one missed site silently wipes findings.
# Preserve-on-absent makes them safe-by-construction: a writer that does not
# manage them just omits the params and they round-trip. The new §6 setters
# (_record_finding, _incr_self_review_count, _re_review_attempt_count) pass them
# EXPLICITLY (arg count ≥ 26), which overrides the preserve. Their JSON is
# placed BEFORE last_cleared_review_sha so cleared_step_log remains the LAST
# field (the _read_fragment_cleared_log greedy-anchor invariant).
#   findings           a complete JSON array literal (param ≥26 wins; else
#                      preserved from disk; fresh/absent → [])
#   self_review_count  an int (param ≥27 wins; else preserved; fresh → 0)
#   re_review_attempts a complete JSON object literal keyed "<gate>:<step>" → int
#                      (param ≥28 wins; else preserved; fresh → {})
# Callers that do not need them omit them; the existing twelve-, sixteen-,
# twenty-, twenty-three-, and twenty-five-param call sites continue to work
# unchanged (24/25 default to null/[]; 26..28 preserve-or-default).
_write_tdd_fragment() {
  local slug="$1" n="$2" path="$3" qp="$4" status="$5" stage="$6" sta="$7" upd="$8"
  local branch="$9" pr_url="${10}" log="${11}" note="${12}"
  local paused_cause="${13:-}" gates_csv="${14:-}" retries_json="${15:-}" branch_head="${16:-}"
  local halt_cause="${17:-}" halt_finding="${18:-}" halt_actions_csv="${19:-}" halt_detail="${20:-}"
  local rework_attempts="${21:-}" rework_log="${22:-}" build_attempt="${23:-}"
  local last_cleared_sha="${24:-}" cleared_step_log="${25:-}"
  local argc="$#"
  local stage_lit cause_lit head_lit gates_lit retries_lit
  local halt_cause_lit halt_finding_lit halt_actions_lit halt_detail_lit
  local rework_attempts_lit rework_log_lit build_attempt_lit
  local last_cleared_sha_lit cleared_step_log_lit
  local findings_lit self_review_lit re_review_lit
  # TDD 0021 §6: $f is needed up-front so the preserve-on-absent reads (below)
  # can pull the cumulative findings / self_review_count / re_review_attempts
  # from the CURRENT on-disk fragment when the caller omits params 26..28.
  local f tmp
  f="$STATE_DIR/$slug.json"
  if [ -z "$stage" ]; then stage_lit='null'
  else stage_lit="\"$(json_escape "$stage")\""; fi
  if [ -z "$paused_cause" ]; then cause_lit='null'
  else cause_lit="\"$(json_escape "$paused_cause")\""; fi
  if [ -z "$branch_head" ]; then head_lit='null'
  else head_lit="\"$(json_escape "$branch_head")\""; fi
  if [ -z "$halt_cause" ]; then halt_cause_lit='null'
  else halt_cause_lit="\"$(json_escape "$halt_cause")\""; fi
  if [ -z "$halt_finding" ]; then halt_finding_lit='null'
  else halt_finding_lit="\"$(json_escape "$halt_finding")\""; fi
  if [ -z "$halt_detail" ]; then halt_detail_lit='null'
  else halt_detail_lit="\"$(json_escape "$halt_detail")\""; fi
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
  if [ -z "$halt_actions_csv" ]; then
    halt_actions_lit='[]'
  else
    # Same CSV→array split as gates_completed. Next-action labels are comma-free
    # by construction (see _next_actions_for_cause), so the split is unambiguous.
    local a aentry afirst=1
    halt_actions_lit='['
    local IFS=','; for a in $halt_actions_csv; do
      if [ -n "$a" ]; then
        aentry="\"$(json_escape "$a")\""
        if [ "$afirst" -eq 1 ]; then halt_actions_lit+="$aentry"; afirst=0
        else halt_actions_lit+=",$aentry"; fi
      fi
    done
    halt_actions_lit+=']'
  fi
  if [ -z "$retries_json" ]; then retries_lit='[]'
  else retries_lit="$retries_json"; fi
  # TDD 0019 rework telemetry literals: object → {} default, array → [] default,
  # build_attempt object → null default. Callers pass complete JSON literals.
  if [ -z "$rework_attempts" ]; then rework_attempts_lit='{}'
  else rework_attempts_lit="$rework_attempts"; fi
  if [ -z "$rework_log" ]; then rework_log_lit='[]'
  else rework_log_lit="$rework_log"; fi
  if [ -z "$build_attempt" ]; then build_attempt_lit='null'
  else build_attempt_lit="$build_attempt"; fi
  # TDD 0020 cleared-step literals: SHA → quoted string or null; the
  # cleared_step_log array → [] default. Callers pass a complete JSON array.
  if [ -z "$last_cleared_sha" ]; then last_cleared_sha_lit='null'
  else last_cleared_sha_lit="\"$(json_escape "$last_cleared_sha")\""; fi
  if [ -z "$cleared_step_log" ]; then cleared_step_log_lit='[]'
  else cleared_step_log_lit="$cleared_step_log"; fi
  # TDD 0021 §6: findings / self_review_count / re_review_attempts. Param ≥26/27/28
  # wins; otherwise PRESERVE the on-disk value (cumulative-by-default — see the
  # header). A fresh fragment (file absent) or an explicitly-empty value falls
  # back to the type's empty literal ([] / 0 / {}).
  if [ "$argc" -ge 26 ]; then findings_lit="${26}"
  elif [ -f "$f" ]; then findings_lit="$(_read_fragment_findings "$f")"
  else findings_lit=""; fi
  [ -z "$findings_lit" ] && findings_lit='[]'
  local _srv
  if [ "$argc" -ge 27 ]; then _srv="${27}"
  elif [ -f "$f" ]; then _srv="$(sed -n 's/.*"self_review_count":\([0-9]*\).*/\1/p' "$f" | head -1)"
  else _srv=""; fi
  case "$_srv" in ''|*[!0-9]*) _srv=0 ;; esac
  self_review_lit="$_srv"
  if [ "$argc" -ge 28 ]; then re_review_lit="${28}"
  elif [ -f "$f" ]; then re_review_lit="$(_read_fragment_raw_object "$f" re_review_attempts)"
  else re_review_lit=""; fi
  [ -z "$re_review_lit" ] && re_review_lit='{}'
  tmp="$f.tmp.$$"
  # TDD 0011 / iter-3 MAJOR-5: detect printf or mv failure. A disk-full
  # or permission failure on `printf > $tmp` under set -uo pipefail (no -e)
  # would not abort the runner; mv would then atomically replace the live
  # fragment with a corrupted/empty one, and subsequent reads would
  # round-trip empty values back. Bail loudly instead so the run is
  # halted while data is still recoverable.
  if ! printf '{"n":%d,"slug":"%s","path":"%s","queue_pos":%d,"status":"%s","stage":%s,"started_at":%d,"updated_at":%d,"branch":"%s","pr_url":"%s","log":"%s","note":"%s","paused_cause":%s,"gates_completed":%s,"retries":%s,"branch_head_at_pause":%s,"halt_cause":%s,"halt_triggering_finding_ref":%s,"halt_next_actions":%s,"halt_cause_detail":%s,"rework_attempts":%s,"rework_log":%s,"build_attempt":%s,"findings":%s,"self_review_count":%s,"re_review_attempts":%s,"last_cleared_review_sha":%s,"cleared_step_log":%s}\n' \
    "$n" "$(json_escape "$slug")" "$(json_escape "$path")" "$qp" \
    "$(json_escape "$status")" "$stage_lit" \
    "$sta" "$upd" \
    "$(json_escape "$branch")" "$(json_escape "$pr_url")" "$(json_escape "$log")" \
    "$(json_escape "$note")" \
    "$cause_lit" "$gates_lit" "$retries_lit" "$head_lit" \
    "$halt_cause_lit" "$halt_finding_lit" "$halt_actions_lit" "$halt_detail_lit" \
    "$rework_attempts_lit" "$rework_log_lit" "$build_attempt_lit" \
    "$findings_lit" "$self_review_lit" "$re_review_lit" \
    "$last_cleared_sha_lit" "$cleared_step_log_lit" \
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

# _rework_config_json — emit the §6 rework-config snapshot object from the four
# env knobs with their defaults (TDD 0019 §6). Recorded once in run.json's
# config snapshot (below) so any halt citing these values is reproducible from
# the run-state record alone (ADR 0006). Self-contained (reads env with
# defaults) so it is correct regardless of caller scope — including the
# THROUGHLINE_SOURCE_ONLY test path that never runs the implement.sh setup
# block. The model default `sonnet` resolves to the same alias
# THROUGHLINE_REVIEW_MODEL resolves to (TDD 0013); only the alias is snapshotted.
_rework_config_json() {
  local model="${THROUGHLINE_REWORK_MODEL:-sonnet}"
  local max="${THROUGHLINE_REWORK_MAX:-3}"
  local floor="${THROUGHLINE_REWORK_SCOPE_FLOOR:-60}"
  local factor="${THROUGHLINE_REWORK_SCOPE_FACTOR:-3}"
  # Guard the three numeric knobs against non-numeric input (bash-arith
  # injection / malformed config) — fall back to the default + warn, matching
  # _retry_in_gate's env-validation discipline. The cap/budget math downstream
  # consumes the snapshot, so a non-numeric value must never reach it.
  case "$max"    in ''|*[!0-9]*) echo "warning: THROUGHLINE_REWORK_MAX='$max' not numeric; using 3" >&2; max=3 ;; esac
  case "$floor"  in ''|*[!0-9]*) echo "warning: THROUGHLINE_REWORK_SCOPE_FLOOR='$floor' not numeric; using 60" >&2; floor=60 ;; esac
  case "$factor" in ''|*[!0-9]*) echo "warning: THROUGHLINE_REWORK_SCOPE_FACTOR='$factor' not numeric; using 3" >&2; factor=3 ;; esac
  printf '{"model":"%s","max":%d,"scope_floor":%d,"scope_factor":%d}' \
    "$(json_escape "$model")" "$max" "$floor" "$factor"
}

# _re_review_config_json — emit the §6 re-review-config snapshot from the
# THROUGHLINE_RE_REVIEW_MAX knob (TDD 0021 §3c; default 2). Recorded in run.json's
# config snapshot (parallel to _rework_config_json) so any rework-budget-exhausted
# halt that a `runner-check` re-review triggered is reproducible from run-state
# alone (ADR 0006). The cap is deliberately tighter than THROUGHLINE_REWORK_MAX:
# the issue #35 collapse expectation is "round 1 may miss files; round 2 forced by
# per-file coverage sweeps them," so 2 is the tight cap. Non-numeric input falls
# back to the default + warn, matching _rework_config_json's discipline.
_re_review_config_json() {
  local max="${THROUGHLINE_RE_REVIEW_MAX:-2}"
  case "$max" in ''|*[!0-9]*) echo "warning: THROUGHLINE_RE_REVIEW_MAX='$max' not numeric; using 2" >&2; max=2 ;; esac
  printf '{"max":%d}' "$max"
}

# Re-roll the run-level rollup from per-TDD fragments and rewrite run.json.
# state ∈ {running, done, paused}. Called by state_init (running), at run end
# (done), and by _enter_paused (paused). When state is paused, pause_started_at
# is stamped (display only). run.json carries a `config` snapshot
# (TDD 0019 §6) whose `rework_config` makes any rework-budget / scope halt
# reproducible from the run-state record alone (ADR 0006).
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
  local rework_config_lit re_review_config_lit
  rework_config_lit="$(_rework_config_json)"
  re_review_config_lit="$(_re_review_config_json)"
  if ! printf '{"schema":1,"started_at":%d,"updated_at":%d,"pid":%d,"integration_branch":"%s","mode":"%s","change":"%s","logdir":"%s","total":%d,"completed":%d,"failed":%d,"blocked":%d,"skipped":%d,"paused":%d,"state":"%s","pause_started_at":%s,"config":{"rework_config":%s,"re_review_config":%s}}\n' \
    "$STATE_STARTED_AT" "$(date +%s)" "$$" \
    "$(json_escape "$INTEGRATION")" "$STATE_MODE" "$(json_escape "$CHANGE")" "$(json_escape "$LOGDIR")" \
    "$total" "$completed" "$failed" "$blocked" "$skipped" "$paused" \
    "$(json_escape "$state")" "$pause_started_lit" "$rework_config_lit" "$re_review_config_lit" \
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
    #
    # TDD 0018 (halt taxonomy) note: the new halt_cause / halt_*_finding_ref /
    # halt_next_actions / halt_cause_detail fields are ADDITIVE (old fragments
    # read fine; halt_cause falls back to paused_cause — see _read_fragment_field)
    # and the resume aspect of TDD 0011 "carries forward unchanged" (0018 §scope).
    # Per the policy above, an additive change stays at schema 1, so this gate is
    # left at `== 1`. (TDD 0018 §Data's "bump the schema-version constant" reads
    # as in tension with both its own "additive" framing and 0011's policy;
    # bumping under this refusal gate would make every pre-0018 paused run
    # un-resumable, contradicting the dual-write/fallback backward-compat the TDD
    # exists to provide. The additive-compatible, resume-preserving resolution is
    # to NOT bump.)
    #
    # TDD 0020 (continuous review) §Data says "schema-version bumped by one"
    # for the new last_cleared_review_sha / cleared_step_log fields. The
    # SAME analysis applies: those fields are ADDITIVE (absent on an older
    # fragment, both readers default — null and [] — so an old paused run
    # resumes fine under the new code), and bumping under this `== 1` refusal
    # gate would break resume of every pre-0020 paused run for no correctness
    # gain. Following the TDD-0018 precedent, the schema stays at 1; the
    # directive is satisfied in spirit (the change IS recorded — here) without
    # the resume-breaking literal bump.
    #
    # TDD 0021 (severity / honest reporting / self-review) §6 likewise says
    # "Schema-version bumped by one from TDD 0020's value." The SAME analysis
    # applies a third time: the new fragment fields (findings[], self_review_count,
    # re_review_attempts) and run.json's config.re_review_config are ADDITIVE —
    # an older paused fragment lacks them and every reader defaults ([] / 0 / {}),
    # so an old paused run resumes fine under the new code; _write_tdd_fragment's
    # preserve-on-absent (params 26..28) round-trips them on every rewrite.
    # Bumping under this `== 1` refusal gate would break resume of every pre-0021
    # paused run for no correctness gain. Schema stays at 1; the directive is
    # recorded here, not honored as a resume-breaking literal bump.
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
# TDD 0018 §Failure modes: `blocked` dominates `paused` in the run-level rollup.
# If any per-TDD fragment is `blocked`, the run is `blocked` regardless of the
# requested state (a blocked TDD needs human design action; a co-queued paused
# TDD's recoverable pause does not override that). Only-paused runs stay paused
# (the caller passes "paused" in that case). This keeps the existing run-end
# call sites (set_run_state "paused" / "done") correct without their needing to
# know about blocked.
set_run_state() {
  local derived="$1" f
  if [ -n "${STATE_DIR:-}" ] && [ -d "$STATE_DIR" ]; then
    for f in "$STATE_DIR"/*.json; do
      [ -f "$f" ] || continue
      [ "$(basename "$f")" = "run.json" ] && continue
      if grep -q '"status":"blocked"' "$f" 2>/dev/null; then derived="blocked"; break; fi
    done
  fi
  _write_run_fragment "$derived"
}

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
  local halt_cause halt_finding halt_actions_csv halt_detail
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
  # TDD 0018: carry the halt metadata forward. Reading halt_cause via
  # _read_fragment_field also upgrades a TDD-0011-shape fragment (no halt_cause)
  # by deriving it from paused_cause, so a resume rewrite does not lose the cause.
  halt_cause="$(_read_fragment_field "$f" halt_cause)"
  halt_finding="$(_read_fragment_field "$f" halt_triggering_finding_ref)"
  halt_actions_csv="$(_read_fragment_array_csv "$f" halt_next_actions)"
  halt_detail="$(_read_fragment_field "$f" halt_cause_detail)"
  # TDD 0019: rework telemetry is cumulative across the whole TDD lifecycle
  # (FR-68 compares rework vs build spend at the end), so it is ALWAYS carried
  # forward and NEVER cleared — unlike halt metadata, a state transition does
  # not reset it.
  local rework_attempts rework_log build_attempt
  rework_attempts="$(_read_fragment_raw_object "$f" rework_attempts)"
  rework_log="$(_read_fragment_raw_array "$f" rework_log)"
  build_attempt="$(_read_fragment_raw_object "$f" build_attempt)"
  # TDD 0020: the cleared-step log + last-cleared SHA are cumulative across the
  # whole TDD lifecycle (FR-57 anchors the next scoped diff; FR-59 counts
  # addressed patterns), so — like the rework telemetry — they are ALWAYS carried
  # forward and NEVER cleared by a status transition (resume reads them).
  local last_cleared_sha cleared_step_log
  last_cleared_sha="$(_read_fragment_field "$f" last_cleared_review_sha)"
  cleared_step_log="$(_read_fragment_cleared_log "$f")"
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
  # TDD 0018: clear halt metadata when the TDD leaves ALL halt states. A halt
  # is only meaningful while the TDD sits in paused/blocked/failed; a resume
  # that moves it back to building/done must not retain a stale halt_cause,
  # finding ref, or next-action list.
  case "$status" in
    paused|blocked|failed) : ;;
    *) halt_cause=""; halt_finding=""; halt_actions_csv=""; halt_detail="" ;;
  esac
  now=$(date +%s)
  # TDD 0011 / iter-5 MAJOR-1: propagate _write_tdd_fragment failures so
  # the runner doesn't silently continue with a stale fragment.
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$now}" "$now" "$branch" "$pr_url" "$log" "$note" \
    "$paused_cause" "$gates_csv" "$retries_json" "$branch_head" \
    "$halt_cause" "$halt_finding" "$halt_actions_csv" "$halt_detail" \
    "$rework_attempts" "$rework_log" "$build_attempt" \
    "$last_cleared_sha" "$cleared_step_log"; then
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
  local halt_cause halt_finding halt_actions_csv halt_detail
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
  # TDD 0018: carry halt metadata forward unchanged (set_tdd_meta never alters
  # status, so a halt that was set stays set). Read halt_cause raw (no fallback
  # synthesis) to avoid upgrading a clean fragment that has no cause at all —
  # _read_fragment_field only falls back when the field is absent, which is the
  # intended migration behavior here too.
  halt_cause="$(_read_fragment_field "$f" halt_cause)"
  halt_finding="$(_read_fragment_field "$f" halt_triggering_finding_ref)"
  halt_actions_csv="$(_read_fragment_array_csv "$f" halt_next_actions)"
  halt_detail="$(_read_fragment_field "$f" halt_cause_detail)"
  # TDD 0019: carry rework telemetry forward (set_tdd_meta never touches it).
  local rework_attempts rework_log build_attempt
  rework_attempts="$(_read_fragment_raw_object "$f" rework_attempts)"
  rework_log="$(_read_fragment_raw_array "$f" rework_log)"
  build_attempt="$(_read_fragment_raw_object "$f" build_attempt)"
  # TDD 0020: carry the cleared-step fields forward (set_tdd_meta never alters them).
  local last_cleared_sha cleared_step_log
  last_cleared_sha="$(_read_fragment_field "$f" last_cleared_review_sha)"
  cleared_step_log="$(_read_fragment_cleared_log "$f")"
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
    "$paused_cause" "$gates_csv" "$retries_json" "$branch_head" \
    "$halt_cause" "$halt_finding" "$halt_actions_csv" "$halt_detail" \
    "$rework_attempts" "$rework_log" "$build_attempt" \
    "$last_cleared_sha" "$cleared_step_log"; then
    echo "error: set_tdd_meta: could not write $slug fragment" >&2
    return 1
  fi
}

# --- Halt-cause taxonomy (TDD 0018 / FR-63, FR-64; ADR 0007) ------------------
# The closed enum of human-needed halt causes, the deterministic cause→next-
# actions mapping, and the writer (set_halt_cause) that enforces both. This is
# the single authoritative writer of halt_cause; TDD 0019's gate writers call
# set_halt_cause rather than editing fragments directly.

# _next_actions_for_cause <cause>  — echo the CSV next-action labels for a cause,
# or return 1 for an unknown value. Doubles as the closed-enum membership test
# (every legal cause has a non-empty mapping; no other value does). The labels
# are deliberately comma-free so the CSV round-trips through _write_tdd_fragment's
# array split and _read_fragment_array_csv without loss. Mapping per TDD 0018 §3.
_next_actions_for_cause() {
  case "$1" in
    ratelimit|usage-limit|transient)
      echo "resume now (retries the gate),wait and resume later" ;;
    resume-blocked-build-state-missing)
      echo "abandon paused run,manual investigation: docs/tdd/.implement-logs/<runid>/" ;;
    resume-blocked-branch-missing)
      echo "abandon paused run,restore branch and resume" ;;
    resume-blocked-branch-divergence)
      echo "abandon paused run,rebase build branch and resume" ;;
    rework-budget-exhausted)
      echo "revise TDD via /tdd-author,fresh /implement after revision" ;;
    rework-scope-exceeded)
      echo "resume (retries with stricter scope),revise TDD bounds via /tdd-author" ;;
    structural-finding)
      echo "revise TDD via /tdd-author,see docs/tdd/BLOCKERS.md" ;;
    design-escalation)
      echo "revise TDD via /tdd-author,/adr-new if a constraint is being challenged" ;;
    external-blocker)
      echo "resolve external dependency,see docs/tdd/BLOCKERS.md" ;;
    *) return 1 ;;
  esac
}

# _is_paused_cause <cause>  — return 0 if <cause> produces the `paused`
# (recoverable, auto-resumable) runtime state; 1 otherwise. Drives the
# paused_cause dual-write and the renderer's Resume: line.
_is_paused_cause() {
  case "$1" in
    ratelimit|usage-limit|transient) return 0 ;;
    resume-blocked-build-state-missing|resume-blocked-branch-missing|resume-blocked-branch-divergence) return 0 ;;
    *) return 1 ;;
  esac
}

# set_halt_cause <slug> <cause> [triggering-finding-ref] [detail]
# The authoritative halt-event writer (TDD 0018 §6). Validates <cause> against
# the closed enum (returns 1 on an unknown value, naming it on stderr), looks up
# the deterministic next-action list, and writes halt_cause /
# halt_triggering_finding_ref / halt_next_actions / halt_cause_detail onto the
# TDD fragment atomically, preserving every other field. For a paused-state
# cause it also dual-writes paused_cause so the TDD 0008/0011 renderer keeps
# working during the migration window; for a blocked-state cause paused_cause is
# left null (verdict honesty: a blocked halt is not a recoverable pause).
set_halt_cause() {
  local slug="$1" cause="$2" finding="${3:-}" detail="${4:-}"
  local actions_csv
  if ! actions_csv="$(_next_actions_for_cause "$cause")"; then
    echo "error: set_halt_cause: unknown halt cause '$cause' (not in the closed FR-63 enum); fragment $slug NOT updated" >&2
    return 1
  fi
  local f="${STATE_DIR:-}/$slug.json"
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: set_halt_cause: no state fragment for $slug ($f); cannot record halt" >&2
    return 1
  fi
  # Carry every existing field forward; only the halt fields (+ paused_cause for
  # paused-state causes) change.
  local n qp path status stage sta branch pr_url log note now
  local gates_csv retries_json branch_head paused_cause
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
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"
  retries_json="$(_read_fragment_raw_array "$f" retries)"
  branch_head="$(_read_fragment_field "$f" branch_head_at_pause)"
  # TDD 0019: a halt write (rework-budget-exhausted, structural-finding,
  # rework-scope-exceeded) must NOT wipe the rework telemetry it cites — the
  # FR-68 comparison and the BLOCKERS triage both read rework_log post-halt.
  local rework_attempts rework_log build_attempt
  rework_attempts="$(_read_fragment_raw_object "$f" rework_attempts)"
  rework_log="$(_read_fragment_raw_array "$f" rework_log)"
  build_attempt="$(_read_fragment_raw_object "$f" build_attempt)"
  # TDD 0020: a halt write must NOT wipe the cleared-step log it may cite (the
  # FR-59 cross-step-learning audit reads it post-halt) or the last-cleared SHA.
  local last_cleared_sha cleared_step_log
  last_cleared_sha="$(_read_fragment_field "$f" last_cleared_review_sha)"
  cleared_step_log="$(_read_fragment_cleared_log "$f")"
  if _is_paused_cause "$cause"; then paused_cause="$cause"; else paused_cause=""; fi
  now=$(date +%s)
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$now}" "$now" "$branch" "$pr_url" "$log" "$note" \
    "$paused_cause" "$gates_csv" "$retries_json" "$branch_head" \
    "$cause" "$finding" "$actions_csv" "$detail" \
    "$rework_attempts" "$rework_log" "$build_attempt" \
    "$last_cleared_sha" "$cleared_step_log"; then
    echo "error: set_halt_cause: could not write $slug fragment (cause=$cause)" >&2
    return 1
  fi
}

# --- Rework telemetry + budget (TDD 0019 / FR-65, FR-68) ----------------------
# These three writers mutate ONLY the rework fields; every other field is read
# from the existing fragment and round-tripped unchanged. _rewrite_fragment_rework
# is the shared read-all/write-with-new-rework-literals core (the same pattern
# _append_retry uses for retries[]), so the three public mutators stay small.

# _rewrite_fragment_rework <slug> <rework_attempts_lit> <rework_log_lit> <build_attempt_lit>
# Carry every non-rework field forward; overwrite the three rework literals.
_rewrite_fragment_rework() {
  local slug="$1" ra_lit="$2" rl_lit="$3" ba_lit="$4"
  local f="${STATE_DIR:-}/$slug.json"
  [ -n "$STATE_DIR" ] && [ -f "$f" ] || return 0
  local n qp path status stage sta branch pr_url log note now
  local paused_cause gates_csv retries_json branch_head
  local halt_cause halt_finding halt_actions_csv halt_detail
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
  halt_cause="$(_read_fragment_field "$f" halt_cause)"
  halt_finding="$(_read_fragment_field "$f" halt_triggering_finding_ref)"
  halt_actions_csv="$(_read_fragment_array_csv "$f" halt_next_actions)"
  halt_detail="$(_read_fragment_field "$f" halt_cause_detail)"
  # TDD 0020: carry the cleared-step fields forward (a rework-telemetry rewrite
  # must not wipe last_cleared_review_sha / cleared_step_log).
  local last_cleared_sha cleared_step_log
  last_cleared_sha="$(_read_fragment_field "$f" last_cleared_review_sha)"
  cleared_step_log="$(_read_fragment_cleared_log "$f")"
  now=$(date +%s)
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$now}" "$now" "$branch" "$pr_url" "$log" "$note" \
    "$paused_cause" "$gates_csv" "$retries_json" "$branch_head" \
    "$halt_cause" "$halt_finding" "$halt_actions_csv" "$halt_detail" \
    "$ra_lit" "$rl_lit" "$ba_lit" \
    "$last_cleared_sha" "$cleared_step_log"; then
    echo "error: _rewrite_fragment_rework: could not write $slug fragment" >&2
    return 1
  fi
}

# _extract_token_spend <session-json-path>  — echo the session's total token
# spend (sum of input + output + cache-creation + cache-read tokens across every
# assistant message), or the literal `null` when the file is missing, jq is
# absent, or no usage is found. FR-68 is observability, not enforcement: `null`
# is acceptable (the acceptance criterion compares numeric values only). Reads
# the session JSONL the Claude Code SDK already writes (no new dependency).
_extract_token_spend() {  # <session-json-path>
  local s="${1:-}"
  [ -n "$s" ] && [ -f "$s" ] || { printf 'null'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'null'; return 0; }
  local total
  total="$(jq -s '
    [ .[]
      | select(.type=="assistant")
      | (.message.usage // {})
      | ((.input_tokens//0)+(.output_tokens//0)+(.cache_creation_input_tokens//0)+(.cache_read_input_tokens//0))
    ] | add // 0' "$s" 2>/dev/null)"
  case "$total" in
    ''|*[!0-9]*) printf 'null' ;;
    0)           printf 'null' ;;   # no usage rows found → treat as unobserved
    *)           printf '%s' "$total" ;;
  esac
}

# _rework_attempt_count_peek <slug> <gate> <step>  — read-only counterpart of
# _rework_attempt_count below: echoes the persisted attempt count for the given
# key (0 if absent or no fragment yet) WITHOUT incrementing or rewriting the
# fragment. _rework_loop calls this on entry to seed its local `attempts` from
# state so a pause+resume preserves the budget across invocations — the
# pre-fix bug (TDD 0019 review-rerun finding 1) was that the local `attempts=0`
# initialization shadowed the persisted counter, granting one extra rework
# beyond THROUGHLINE_REWORK_MAX after every resume. Safe to call without a
# fragment file (returns 0; the loop starts fresh, identical to pre-fix
# semantics in the no-prior-state case).
_rework_attempt_count_peek() {  # <slug> <gate> <step>
  local slug="$1" gate="$2" step="$3"
  local f="${STATE_DIR:-}/$slug.json" key="$gate:$step" obj cur
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then echo 0; return 0; fi
  obj="$(_read_fragment_raw_object "$f" rework_attempts)"
  [ -z "$obj" ] && { echo 0; return 0; }
  cur="$(printf '%s' "$obj" | sed -n "s/.*\"$key\":\\([0-9]*\\).*/\\1/p" | head -1)"
  [ -z "$cur" ] && cur=0
  echo "$cur"
}

# _rework_attempt_count <slug> <gate> <step>  — increment the per-(gate,step)
# attempt counter in rework_attempts and echo the NEW value. The key is
# "<gate>:<step>". Used by the loop to enforce THROUGHLINE_REWORK_MAX (FR-65).
_rework_attempt_count() {  # <slug> <gate> <step>
  local slug="$1" gate="$2" step="$3"
  local f="${STATE_DIR:-}/$slug.json"
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: _rework_attempt_count: no state fragment for $slug ($f)" >&2
    return 1
  fi
  local key="$gate:$step" obj cur new new_obj
  obj="$(_read_fragment_raw_object "$f" rework_attempts)"
  [ -z "$obj" ] && obj='{}'
  # Current count for this key (0 if absent). The key is well-formed
  # (gate ∈ {review,…}, step is numeric) so the literal match is safe.
  cur="$(printf '%s' "$obj" | sed -n "s/.*\"$key\":\\([0-9]*\\).*/\\1/p" | head -1)"
  [ -z "$cur" ] && cur=0
  new=$((cur + 1))
  if [ "$obj" = '{}' ]; then
    new_obj="{\"$key\":$new}"
  elif printf '%s' "$obj" | grep -q "\"$key\":[0-9]"; then
    new_obj="$(printf '%s' "$obj" | sed "s/\"$key\":[0-9]*/\"$key\":$new/")"
  else
    new_obj="${obj%\}},\"$key\":$new}"
  fi
  local rl ba
  rl="$(_read_fragment_raw_array "$f" rework_log)"
  ba="$(_read_fragment_raw_object "$f" build_attempt)"
  if ! _rewrite_fragment_rework "$slug" "$new_obj" "$rl" "$ba"; then
    echo "error: _rework_attempt_count: could not persist counter for $slug ($key)" >&2
    return 1
  fi
  printf '%s' "$new"
}

# _record_rework_attempt <slug> <attempt> <gate> <step> <model> <token_spend>
#                        <started_at> <finished_at> <finding_ref> <outcome>
# Append one telemetry object to rework_log (FR-68). <token_spend> is an int or
# the literal `null`; <finding_ref> / <outcome> are free text (JSON-escaped).
_record_rework_attempt() {
  local slug="$1" attempt="$2" gate="$3" step="$4" model="$5" spend="$6"
  local started="$7" finished="$8" finding="$9" outcome="${10}"
  local f="${STATE_DIR:-}/$slug.json"
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: _record_rework_attempt: no state fragment for $slug ($f)" >&2
    return 1
  fi
  # token_spend is numeric or null (FR-68: null is acceptable telemetry).
  local spend_lit
  case "$spend" in
    ''|null) spend_lit='null' ;;
    *[!0-9]*) spend_lit='null' ;;
    *)       spend_lit="$spend" ;;
  esac
  local entry rl new
  entry="{\"attempt\":${attempt:-0},\"gate\":\"$(json_escape "$gate")\",\"step\":${step:-0},\"model\":\"$(json_escape "$model")\",\"token_spend\":$spend_lit,\"started_at\":${started:-0},\"finished_at\":${finished:-0},\"finding_ref\":\"$(json_escape "$finding")\",\"outcome\":\"$(json_escape "$outcome")\"}"
  rl="$(_read_fragment_raw_array "$f" rework_log)"
  if [ -z "$rl" ] || [ "$rl" = "[]" ]; then
    new="[$entry]"
  elif [ "${rl: -1}" != ']' ]; then
    echo "warning: rework_log for $slug was malformed (no closing ']'); resetting" >&2
    new="[$entry]"
  else
    new="${rl%]},$entry]"
  fi
  local ra ba
  ra="$(_read_fragment_raw_object "$f" rework_attempts)"; [ -z "$ra" ] && ra='{}'
  ba="$(_read_fragment_raw_object "$f" build_attempt)"
  if ! _rewrite_fragment_rework "$slug" "$ra" "$new" "$ba"; then
    echo "error: _record_rework_attempt: could not append rework_log entry for $slug" >&2
    return 1
  fi
}

# _set_build_attempt_token_spend <slug> <value>  — record the original build
# attempt's token spend so the FR-68 rework-vs-original comparison is derivable
# from run-state alone. <value> is an int or the literal `null`.
_set_build_attempt_token_spend() {  # <slug> <value>
  local slug="$1" value="${2:-null}"
  local f="${STATE_DIR:-}/$slug.json"
  [ -n "$STATE_DIR" ] && [ -f "$f" ] || return 0
  local val_lit
  case "$value" in
    ''|null)  val_lit='null' ;;
    *[!0-9]*) val_lit='null' ;;
    *)        val_lit="$value" ;;
  esac
  local ra rl
  ra="$(_read_fragment_raw_object "$f" rework_attempts)"; [ -z "$ra" ] && ra='{}'
  rl="$(_read_fragment_raw_array "$f" rework_log)"
  _rewrite_fragment_rework "$slug" "$ra" "$rl" "{\"token_spend\":$val_lit}"
}

# --- Cleared-step log + last-cleared SHA (TDD 0020 / FR-57, FR-59; ADR 0006) --
# _record_cleared_step <slug> <step-id> <base-sha> <head-sha> <pattern-tags-csv>
# Append one {step_id, base_sha, head_sha, pattern_tags[], cleared_at} entry to
# cleared_step_log and advance last_cleared_review_sha to <head-sha>, atomically.
# Every OTHER field is read from the existing fragment and round-tripped unchanged
# (the same read-all/write-all discipline every fragment mutator uses). The pair
# makes any review verdict reproducible from `git diff <base>..<head>` of a
# recorded entry (ADR 0006); the pattern_tags feed the FR-59 cross-step-learning
# acceptance. <pattern-tags-csv> is a comma-separated tag list (or empty → []);
# each tag is JSON-escaped. The cleared_step_log is bounded (≤ Sequencing items,
# plus resume re-appends — §Failure modes), so size is not a concern.
_record_cleared_step() {  # <slug> <step-id> <base-sha> <head-sha> <pattern-tags-csv>
  local slug="$1" step_id="$2" base_sha="$3" head_sha="$4" tags_csv="${5:-}"
  local f="${STATE_DIR:-}/$slug.json"
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: _record_cleared_step: no state fragment for $slug ($f)" >&2
    return 1
  fi
  # step_id is numeric (the Sequencing item index); guard it so a malformed
  # value cannot corrupt the JSON literal. An empty/non-numeric id collapses to 0.
  case "$step_id" in ''|*[!0-9]*) step_id=0 ;; esac
  # Build the pattern_tags JSON array from the CSV (comma-free tags by
  # construction — the reviewer emits short categorical labels).
  local tags_lit t first=1
  if [ -z "$tags_csv" ]; then
    tags_lit='[]'
  else
    tags_lit='['
    local IFS=','; for t in $tags_csv; do
      if [ -n "$t" ]; then
        if [ "$first" -eq 1 ]; then tags_lit+="\"$(json_escape "$t")\""; first=0
        else tags_lit+=",\"$(json_escape "$t")\""; fi
      fi
    done
    tags_lit+=']'
  fi
  local now entry; now=$(date +%s)
  entry="{\"step_id\":$step_id,\"base_sha\":\"$(json_escape "$base_sha")\",\"head_sha\":\"$(json_escape "$head_sha")\",\"pattern_tags\":$tags_lit,\"cleared_at\":$now}"
  # Append to the existing log (bounded; §Data). Splice before the closing
  # bracket; entries contain nested arrays but no nested top-level brackets that
  # would confuse a `%]}` strip, so the splice is unambiguous on a well-formed
  # `]`-terminated array.
  local existing new
  existing="$(_read_fragment_cleared_log "$f")"
  if [ -z "$existing" ] || [ "$existing" = "[]" ]; then
    new="[$entry]"
  elif [ "${existing: -1}" != ']' ]; then
    echo "warning: cleared_step_log for $slug was malformed (no closing ']'); resetting" >&2
    new="[$entry]"
  else
    new="${existing%]},$entry]"
  fi
  # Read-all/write-all: carry every other field forward unchanged.
  local n qp path status stage sta branch pr_url log note
  local paused_cause gates_csv retries_json branch_head
  local halt_cause halt_finding halt_actions_csv halt_detail
  local rework_attempts rework_log build_attempt
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
  halt_cause="$(_read_fragment_field "$f" halt_cause)"
  halt_finding="$(_read_fragment_field "$f" halt_triggering_finding_ref)"
  halt_actions_csv="$(_read_fragment_array_csv "$f" halt_next_actions)"
  halt_detail="$(_read_fragment_field "$f" halt_cause_detail)"
  rework_attempts="$(_read_fragment_raw_object "$f" rework_attempts)"
  rework_log="$(_read_fragment_raw_array "$f" rework_log)"
  build_attempt="$(_read_fragment_raw_object "$f" build_attempt)"
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$now}" "$now" "$branch" "$pr_url" "$log" "$note" \
    "$paused_cause" "$gates_csv" "$retries_json" "$branch_head" \
    "$halt_cause" "$halt_finding" "$halt_actions_csv" "$halt_detail" \
    "$rework_attempts" "$rework_log" "$build_attempt" \
    "$head_sha" "$new"; then
    echo "error: _record_cleared_step: could not write $slug fragment (step $step_id)" >&2
    return 1
  fi
}

# --- §6 findings ledger + self-review counter + re-review counter (TDD 0021) --
# These four writers mutate ONLY the §6 fields; every other field is read from
# the existing fragment and round-tripped unchanged. _rewrite_fragment_findings
# is the shared read-all/write-with-new-§6-literals core (the same pattern
# _rewrite_fragment_rework uses for the rework fields), so the public mutators
# stay small. It passes all 28 args EXPLICITLY (so the §6 preserve-on-absent does
# not shadow an intended override) — including last_cleared_review_sha (24) and
# cleared_step_log (25), which it carries forward unchanged.

# _rewrite_fragment_findings <slug> <findings_lit> <self_review_lit> <re_review_lit>
_rewrite_fragment_findings() {
  local slug="$1" findings_lit="$2" srv_lit="$3" rr_lit="$4"
  local f="${STATE_DIR:-}/$slug.json"
  # SOURCE_ONLY / no-run path (STATE_DIR unset) → graceful no-op success, matching
  # the other fragment writers. But when STATE_DIR IS set and the fragment is
  # missing (e.g. a TOCTOU removal after the caller's top-of-function existence
  # check), this is a genuine can't-persist: return NON-ZERO so the §6 counter
  # setters (_re_review_attempt_count / _incr_self_review_count) propagate the
  # failure instead of reporting a persisted increment that never landed — a
  # silent persist failure would let a later _re_review_attempt_count_peek read a
  # stale count and bypass the THROUGHLINE_RE_REVIEW_MAX budget.
  [ -z "${STATE_DIR:-}" ] && return 0
  if [ ! -f "$f" ]; then
    echo "error: _rewrite_fragment_findings: no fragment $f; refusing to report a §6 write that cannot land" >&2
    return 1
  fi
  local n qp path status stage sta branch pr_url log note now
  local paused_cause gates_csv retries_json branch_head
  local halt_cause halt_finding halt_actions_csv halt_detail
  local rework_attempts rework_log build_attempt last_cleared_sha cleared_step_log
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
  halt_cause="$(_read_fragment_field "$f" halt_cause)"
  halt_finding="$(_read_fragment_field "$f" halt_triggering_finding_ref)"
  halt_actions_csv="$(_read_fragment_array_csv "$f" halt_next_actions)"
  halt_detail="$(_read_fragment_field "$f" halt_cause_detail)"
  rework_attempts="$(_read_fragment_raw_object "$f" rework_attempts)"
  rework_log="$(_read_fragment_raw_array "$f" rework_log)"
  build_attempt="$(_read_fragment_raw_object "$f" build_attempt)"
  last_cleared_sha="$(_read_fragment_field "$f" last_cleared_review_sha)"
  cleared_step_log="$(_read_fragment_cleared_log "$f")"
  now=$(date +%s)
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$now}" "$now" "$branch" "$pr_url" "$log" "$note" \
    "$paused_cause" "$gates_csv" "$retries_json" "$branch_head" \
    "$halt_cause" "$halt_finding" "$halt_actions_csv" "$halt_detail" \
    "$rework_attempts" "$rework_log" "$build_attempt" \
    "$last_cleared_sha" "$cleared_step_log" \
    "$findings_lit" "$srv_lit" "$rr_lit"; then
    echo "error: _rewrite_fragment_findings: could not write $slug fragment" >&2
    return 1
  fi
}

# _record_finding <slug> <source> <pass_id> <severity> <structural> <region>
#                 <region_lines> <pattern_tags_csv> <summary> <evidence>
# Append one finding object (the §6 shape) to findings[]. <source> ∈
# {review, self-review, runner-check}; <structural> is "true"/"false";
# <region_lines> is an int; <pattern_tags_csv> is a comma-separated tag list (or
# empty → []). Every finding is reproducible from `git diff` of its region (ADR
# 0006); addressed_at / addressed_by_sha start null (a later rework stamps them).
_record_finding() {  # <slug> <source> <pass_id> <severity> <structural> <region> <region_lines> <tags_csv> <summary> <evidence>
  local slug="$1" source="$2" pass_id="$3" severity="$4" structural="$5"
  local region="$6" region_lines="$7" tags_csv="${8:-}" summary="${9:-}" evidence="${10:-}"
  local f="${STATE_DIR:-}/$slug.json"
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: _record_finding: no state fragment for $slug ($f)" >&2
    return 1
  fi
  case "$region_lines" in ''|*[!0-9]*) region_lines=0 ;; esac
  local struct_lit='false'; [ "$structural" = "true" ] && struct_lit='true'
  local tags_lit t first=1
  if [ -z "$tags_csv" ]; then tags_lit='[]'
  else
    tags_lit='['
    local IFS=','; for t in $tags_csv; do
      if [ -n "$t" ]; then
        if [ "$first" -eq 1 ]; then tags_lit+="\"$(json_escape "$t")\""; first=0
        else tags_lit+=",\"$(json_escape "$t")\""; fi
      fi
    done
    tags_lit+=']'
  fi
  local entry
  entry="{\"source\":\"$(json_escape "$source")\",\"pass_id\":\"$(json_escape "$pass_id")\",\"severity\":\"$(json_escape "$severity")\",\"structural\":$struct_lit,\"region\":\"$(json_escape "$region")\",\"region_lines\":$region_lines,\"pattern_tags\":$tags_lit,\"summary\":\"$(json_escape "$summary")\",\"evidence\":\"$(json_escape "$evidence")\",\"addressed_at\":null,\"addressed_by_sha\":null}"
  local existing new
  existing="$(_read_fragment_findings "$f")"
  if [ -z "$existing" ]; then
    # An empty reader result is AMBIGUOUS: either the ledger is genuinely empty
    # (`"findings":[]` / field absent), or it holds findings the greedy reader
    # could not parse (a corrupt/truncated array, or evidence text that defeats
    # the anchor). Resetting to "[$entry]" in the latter case would silently
    # DISCARD the accumulated FR-71 honest-reporting audit trail. Distinguish by
    # the raw literal: start fresh ONLY when findings is literally [] or absent;
    # otherwise fail loud and preserve the on-disk state for forensics.
    if grep -q '"findings":\[\]' "$f" 2>/dev/null || ! grep -q '"findings":' "$f" 2>/dev/null; then
      new="[$entry]"
    else
      echo "error: _record_finding: findings present but unparseable for $slug; refusing to overwrite and lose prior findings" >&2
      return 1
    fi
  elif [ "${existing: -1}" != ']' ]; then
    # Defensive: _read_fragment_findings only ever returns a ]-terminated capture,
    # so this is normally unreachable — but keep the fail-loud guard rather than a
    # silent reset in case the reader's contract ever changes.
    echo "error: _record_finding: findings ledger for $slug is malformed (no closing ']'); refusing to write and lose prior findings" >&2
    return 1
  else
    new="${existing%]},$entry]"
  fi
  local srv rr
  srv="$(sed -n 's/.*"self_review_count":\([0-9]*\).*/\1/p' "$f" | head -1)"; case "$srv" in ''|*[!0-9]*) srv=0 ;; esac
  rr="$(_read_fragment_raw_object "$f" re_review_attempts)"; [ -z "$rr" ] && rr='{}'
  if ! _rewrite_fragment_findings "$slug" "$new" "$srv" "$rr"; then
    echo "error: _record_finding: could not append finding for $slug" >&2
    return 1
  fi
}

# _incr_self_review_count <slug> [<delta>]  — add <delta> (default 1) to the
# fragment's self_review_count (FR-60 telemetry: self-review findings emitted
# across the build's lifetime). Other §6 fields carried forward unchanged.
_incr_self_review_count() {  # <slug> [<delta>]
  local slug="$1" delta="${2:-1}"
  local f="${STATE_DIR:-}/$slug.json"
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: _incr_self_review_count: no state fragment for $slug ($f)" >&2
    return 1
  fi
  case "$delta" in ''|*[!0-9]*) delta=1 ;; esac
  local cur new findings rr
  cur="$(sed -n 's/.*"self_review_count":\([0-9]*\).*/\1/p' "$f" | head -1)"; case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  new=$((cur + delta))
  findings="$(_read_fragment_findings "$f")"; [ -z "$findings" ] && findings='[]'
  rr="$(_read_fragment_raw_object "$f" re_review_attempts)"; [ -z "$rr" ] && rr='{}'
  if ! _rewrite_fragment_findings "$slug" "$findings" "$new" "$rr"; then
    echo "error: _incr_self_review_count: could not persist counter for $slug" >&2
    return 1
  fi
}

# _re_review_attempt_count_peek <slug> <gate> <step>  — read-only count of the
# `runner-check` re-review attempts for the given key (0 if absent/no fragment),
# WITHOUT incrementing. Parallel to _rework_attempt_count_peek; the §3c routing
# seeds its budget check from this so a pause+resume preserves the cap.
_re_review_attempt_count_peek() {  # <slug> <gate> <step>
  local slug="$1" gate="$2" step="$3"
  # Validate gate/step BEFORE building $key — it is interpolated raw into sed/grep
  # patterns below, so a metacharacter (`.` `*` `[` `\` `/`) would corrupt the
  # match. gate is an identifier; step is numeric. Reject anything else rather
  # than rely on the caller (matches the codebase's numeric-guard discipline).
  case "$gate" in ''|*[!a-zA-Z0-9_-]*) echo "error: _re_review_attempt_count_peek: invalid gate '$gate'" >&2; return 1 ;; esac
  case "$step" in ''|*[!0-9]*)         echo "error: _re_review_attempt_count_peek: invalid step '$step'" >&2; return 1 ;; esac
  local f="${STATE_DIR:-}/$slug.json" key="$gate:$step" obj cur
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then echo 0; return 0; fi
  obj="$(_read_fragment_raw_object "$f" re_review_attempts)"
  [ -z "$obj" ] && { echo 0; return 0; }
  cur="$(printf '%s' "$obj" | sed -n "s/.*\"$key\":\\([0-9]*\\).*/\\1/p" | head -1)"
  [ -z "$cur" ] && cur=0
  echo "$cur"
}

# _re_review_attempt_count <slug> <gate> <step>  — increment the per-(gate,step)
# `runner-check` re-review counter and echo the NEW value. Parallel to
# _rework_attempt_count; the §3c branch enforces THROUGHLINE_RE_REVIEW_MAX (FR-58
# scope-tightening for issue #35) against it.
_re_review_attempt_count() {  # <slug> <gate> <step>
  local slug="$1" gate="$2" step="$3"
  # Validate gate/step BEFORE building $key — it is interpolated raw into the
  # sed/grep/sed-replace patterns below (a metacharacter would corrupt the match
  # or, in the sed replacement, mis-edit the object). gate is an identifier; step
  # is numeric. Reject anything else rather than rely on the caller.
  case "$gate" in ''|*[!a-zA-Z0-9_-]*) echo "error: _re_review_attempt_count: invalid gate '$gate'" >&2; return 1 ;; esac
  case "$step" in ''|*[!0-9]*)         echo "error: _re_review_attempt_count: invalid step '$step'" >&2; return 1 ;; esac
  local f="${STATE_DIR:-}/$slug.json"
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: _re_review_attempt_count: no state fragment for $slug ($f)" >&2
    return 1
  fi
  local key="$gate:$step" obj cur new new_obj findings srv
  obj="$(_read_fragment_raw_object "$f" re_review_attempts)"; [ -z "$obj" ] && obj='{}'
  cur="$(printf '%s' "$obj" | sed -n "s/.*\"$key\":\\([0-9]*\\).*/\\1/p" | head -1)"
  [ -z "$cur" ] && cur=0
  new=$((cur + 1))
  if [ "$obj" = '{}' ]; then
    new_obj="{\"$key\":$new}"
  elif printf '%s' "$obj" | grep -q "\"$key\":[0-9]"; then
    new_obj="$(printf '%s' "$obj" | sed "s/\"$key\":[0-9]*/\"$key\":$new/")"
  else
    new_obj="${obj%\}},\"$key\":$new}"
  fi
  findings="$(_read_fragment_findings "$f")"; [ -z "$findings" ] && findings='[]'
  srv="$(sed -n 's/.*"self_review_count":\([0-9]*\).*/\1/p' "$f" | head -1)"; case "$srv" in ''|*[!0-9]*) srv=0 ;; esac
  if ! _rewrite_fragment_findings "$slug" "$findings" "$srv" "$new_obj"; then
    echo "error: _re_review_attempt_count: could not persist counter for $slug ($key)" >&2
    return 1
  fi
  printf '%s' "$new"
}

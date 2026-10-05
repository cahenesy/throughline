#!/usr/bin/env bash
# run-record.sh — durable /build-tdds run record (TDD 0061 / FR-27, FR-39,
# FR-40, FR-43, FR-18). Queue, status, halt, lock, next-gate. Does not
# read a harness transcript. No top-level side effects.
#
# Every tl_run_* takes <repo-root> first (absolute). Never uses cwd as
# the logs root.

_TL_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/verdicts.sh
{ [ -r "${_TL_RUN_DIR}/verdicts.sh" ] && . "${_TL_RUN_DIR}/verdicts.sh"; } || {
  echo "FATAL: cannot source ${_TL_RUN_DIR}/verdicts.sh" >&2
  return 1 2>/dev/null || exit 1
}

_tl_run_abs() {
  case "${1:-}" in
    /*) return 0 ;;
    *)  echo "run-record: <repo-root> must be an absolute path" >&2; return 2 ;;
  esac
}

_tl_run_logs() {  # <repo-root>
  _tl_run_abs "$1" || return $?
  printf '%s/docs/tdd/.implement-logs\n' "$1"
}

_tl_run_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Atomic write: printf to mktemp then mv. A kill -9 before mv leaves the
# previous file intact (FR-44).
_tl_run_atomic() {  # <dest> <contents>
  local dest="$1" body="$2" tmp dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.$(basename "$dest").XXXXXX")" || return 1
  if ! printf '%s\n' "$body" >"$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv "$tmp" "$dest"; then rm -f "$tmp"; return 1; fi
  return 0
}

_tl_run_json() {  # <run-id> <status> <started> <updated> <total> <done>
  printf '{"run_id":"%s","status":"%s","started_at":"%s","updated_at":"%s","tdd_total":"%s","tdd_done":"%s"}' \
    "$(tl_json_escape "$1")" "$(tl_json_escape "$2")" \
    "$(tl_json_escape "$3")" "$(tl_json_escape "$4")" \
    "$(tl_json_escape "$5")" "$(tl_json_escape "$6")"
}

tl_run_init() {  # <repo-root> <run-id>
  local root="${1:-}" run="${2:-}" logs dir now
  logs="$(_tl_run_logs "$root")" || return $?
  _tl_valid_run "$run" || { echo "run-record: invalid run-id" >&2; return 2; }
  dir="$logs/$run"
  mkdir -p "$dir" || return 1
  now="$(_tl_run_now)"
  _tl_run_atomic "$dir/run.json" "$(_tl_run_json "$run" running "$now" "$now" 0 0)" || return 1
  ln -sfn "$dir" "$logs/latest" || return 1
}

_tl_run_read_run() {  # <run.json path> <key>
  [ -f "$1" ] || return 1
  tl_json_field "$2" <"$1"
}

tl_run_set_tdd() {  # <repo-root> <run-id> <slug> <status> [halt_cause] [current_gate]
  local root="${1:-}" run="${2:-}" slug="${3:-}" status="${4:-}"
  local cause="${5:-}" gate="${6:-}" logs rfile sfile now
  local qidx started pr logp total done prev
  logs="$(_tl_run_logs "$root")" || return $?
  _tl_valid_run "$run" || { echo "run-record: invalid run-id" >&2; return 2; }
  _tl_valid_slug "$slug" || { echo "run-record: invalid slug '$slug'" >&2; return 2; }
  case "$status" in
    pending|building|verifying|reviewing|done|failed|blocked|skipped|paused) ;;
    *) echo "run-record: bad status '$status'" >&2; return 2 ;;
  esac
  if [ -n "$cause" ]; then
    case "$cause" in
      ratelimit|usage-limit|transient|resume-blocked-build-state-missing|resume-blocked-branch-missing|resume-blocked-branch-divergence|structural-finding|design-escalation|external-blocker|gate-fail) ;;
      *) echo "run-record: bad halt_cause '$cause'" >&2; return 2 ;;
    esac
  fi
  rfile="$logs/$run/run.json"
  [ -f "$rfile" ] || { echo "run-record: run $run not initialized" >&2; return 1; }
  sfile="$logs/$run/${slug}.json"
  now="$(_tl_run_now)"
  logp="$(tl_verdict_dir "$root" "$run" "$slug")" || return $?
  total="$(_tl_run_read_run "$rfile" tdd_total)"; total="${total:-0}"
  done="$(_tl_run_read_run "$rfile" tdd_done)"; done="${done:-0}"
  if [ -f "$sfile" ]; then
    qidx="$(tl_json_field queue_index <"$sfile")"
    started="$(tl_json_field started_at <"$sfile")"
    pr="$(tl_json_field pr_url <"$sfile")"
    prev="$(tl_json_field status <"$sfile")"
  else
    qidx="$total"
    started="$now"
    pr=""
    prev=""
    total=$((total + 1))
  fi
  if [ "$status" = "done" ] && [ "$prev" != "done" ]; then
    done=$((done + 1))
  fi
  _tl_run_atomic "$sfile" "$(printf \
    '{"slug":"%s","status":"%s","halt_cause":"%s","queue_index":"%s","current_gate":"%s","started_at":"%s","updated_at":"%s","pr_url":"%s","log_path":"%s"}' \
    "$(tl_json_escape "$slug")" "$(tl_json_escape "$status")" \
    "$(tl_json_escape "$cause")" "$(tl_json_escape "$qidx")" \
    "$(tl_json_escape "$gate")" "$(tl_json_escape "$started")" \
    "$(tl_json_escape "$now")" "$(tl_json_escape "$pr")" \
    "$(tl_json_escape "$logp")")" || return 1
  _tl_run_atomic "$rfile" "$(_tl_run_json "$run" \
    "$(_tl_run_read_run "$rfile" status || printf running)" \
    "$(_tl_run_read_run "$rfile" started_at || printf '%s' "$now")" \
    "$now" "$total" "$done")" || return 1
}

tl_run_set_pr() {  # <repo-root> <run-id> <slug> <url>
  local root="${1:-}" run="${2:-}" slug="${3:-}" url="${4:-}"
  local logs sfile now qidx started status cause gate logp
  logs="$(_tl_run_logs "$root")" || return $?
  sfile="$logs/$run/${slug}.json"
  [ -f "$sfile" ] || { echo "run-record: no fragment for $slug" >&2; return 1; }
  now="$(_tl_run_now)"
  status="$(tl_json_field status <"$sfile")"
  cause="$(tl_json_field halt_cause <"$sfile")"
  qidx="$(tl_json_field queue_index <"$sfile")"
  gate="$(tl_json_field current_gate <"$sfile")"
  started="$(tl_json_field started_at <"$sfile")"
  logp="$(tl_json_field log_path <"$sfile")"
  _tl_run_atomic "$sfile" "$(printf \
    '{"slug":"%s","status":"%s","halt_cause":"%s","queue_index":"%s","current_gate":"%s","started_at":"%s","updated_at":"%s","pr_url":"%s","log_path":"%s"}' \
    "$(tl_json_escape "$slug")" "$(tl_json_escape "$status")" \
    "$(tl_json_escape "$cause")" "$(tl_json_escape "$qidx")" \
    "$(tl_json_escape "$gate")" "$(tl_json_escape "$started")" \
    "$(tl_json_escape "$now")" "$(tl_json_escape "$url")" \
    "$(tl_json_escape "$logp")")"
}

_tl_lock_path() { printf '%s/.run.lock\n' "$(_tl_run_logs "$1")" || return $?; }

tl_run_lock() {  # <repo-root>
  local root="${1:-}" lock pid logs
  logs="$(_tl_run_logs "$root")" || return $?
  mkdir -p "$logs" || return 1
  lock="$logs/.run.lock"
  if [ -f "$lock" ]; then
    pid="$(tr -d ' \n' <"$lock")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "run-record: lock held by live PID $pid" >&2
      return 1
    fi
  fi
  printf '%s\n' "$$" >"$lock"
}

tl_run_unlock() {  # <repo-root>
  local lock
  lock="$(_tl_lock_path "$1")" || return $?
  rm -f "$lock"
}

tl_run_lock_reclaim() {  # <repo-root>
  local root="${1:-}" lock pid logs
  logs="$(_tl_run_logs "$root")" || return $?
  mkdir -p "$logs" || return 1
  lock="$logs/.run.lock"
  if [ -f "$lock" ]; then
    pid="$(tr -d ' \n' <"$lock")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "run-record: cannot reclaim; PID $pid is live" >&2
      return 1
    fi
  fi
  printf '%s\n' "$$" >"$lock"
}

tl_run_next_gate() {  # <repo-root> <run-id> <slug>
  local root="${1:-}" run="${2:-}" slug="${3:-}" g json st
  if tl_verdict_require_flip "$root" "$run" "$slug" 2>/dev/null; then
    printf 'flip\n'
    return 0
  fi
  for g in test-first ci-checks runtime-verify review; do
    json="$(tl_verdict_read "$root" "$run" "$slug" "$g" 2>/dev/null)" || { printf '%s\n' "$g"; return 0; }
    st="$(printf '%s' "$json" | tl_json_field status)"
    case "$st" in
      PASS|SKIP) ;;
      *) printf '%s\n' "$g"; return 0 ;;
    esac
  done
  # Files look complete but require_flip failed (e.g. SKIP without evidence).
  printf 'runtime-verify\n'
}

# --- per-TDD models sidecar (TDD 0066 / FR-87, NFR-4, ADR 0015) -------------
# <logs>/<run>/<slug>.models.json: one JSON object, exactly the 17 string keys
# below (empty when unset). It is a separate file because tl_run_set_tdd and
# tl_run_set_pr rewrite <slug>.json with a fixed key set. Every write goes
# through _tl_models_write, which overlays the given keys on the existing file
# and rewrites ALL 17, so the models setter and TDD 0067's escalation setter
# never drop each other's keys. tl_run_set_models needs models.sh sourced.

_tl_models_keys() {
  printf '%s\n' 'parent effort effort_source build build_src build_model review review_src review_model verify verify_src verify_model verify_class escalation escalation_model escalation_reason halt_tdd_blob'
}

_tl_models_key_ok() {  # <key> — rc 0 iff one of the 17 keys
  case "${1:-}" in ''|*[!a-z_]*) return 1 ;; esac
  case " $(_tl_models_keys) " in *" $1 "*) return 0 ;; esac
  return 1
}

_tl_models_path() {  # <repo-root> <run-id> <slug> → the sidecar path
  local logs
  logs="$(_tl_run_logs "${1:-}")" || return $?
  _tl_valid_run "${2:-}" || { echo "run-record: invalid run-id" >&2; return 2; }
  _tl_valid_slug "${3:-}" || { echo "run-record: invalid slug '${3:-}'" >&2; return 2; }
  printf '%s/%s/%s.models.json\n' "$logs" "$2" "$3"
}

# _tl_models_write <repo-root> <run-id> <slug> <key>=<val>… — read the sidecar
# once (if any), overlay the given keys, write all 17 atomically. Every pair is
# validated before anything is read or written: an unknown key or a pair
# without `=` → rc 2, nothing written. rc 1 on io or an uninitialized run.
_tl_models_write() {
  local run="${2:-}" f old kv k i n body="{" sep=""
  local -a keys vals
  f="$(_tl_models_path "${1:-}" "$run" "${3:-}")" || return $?
  shift 3
  [ "$#" -gt 0 ] || { echo "run-record: _tl_models_write needs <key>=<val>" >&2; return 2; }
  for kv in "$@"; do
    case "$kv" in *=*) ;; *) echo "run-record: models pair '$kv' is not <key>=<val>" >&2; return 2 ;; esac
    _tl_models_key_ok "${kv%%=*}" || { echo "run-record: unknown models key '${kv%%=*}'" >&2; return 2; }
  done
  [ -f "${f%/*}/run.json" ] || { echo "run-record: run $run not initialized" >&2; return 1; }
  old=""
  if [ -f "$f" ]; then old="$(cat "$f")" || return 1; fi
  IFS=' ' read -r -a keys <<<"$(_tl_models_keys)"
  n="${#keys[@]}"
  for (( i = 0; i < n; i++ )); do
    vals[i]=""
    if [ -n "$old" ]; then
      # Trailing `x` keeps a value's own trailing newlines through $(…).
      vals[i]="$(printf '%s' "$old" | tl_json_field "${keys[i]}"; printf x)"
      vals[i]="${vals[i]%x}"
    fi
  done
  for kv in "$@"; do
    k="${kv%%=*}"
    for (( i = 0; i < n; i++ )); do
      if [ "${keys[i]}" = "$k" ]; then vals[i]="${kv#*=}"; fi
    done
  done
  for (( i = 0; i < n; i++ )); do
    body="$body$sep\"${keys[i]}\":\"$(tl_json_escape "${vals[i]}")\""
    sep=","
  done
  _tl_run_atomic "$f" "$body}" || { echo "run-record: cannot write $f" >&2; return 1; }
}

# _tl_slot_model <value> <parent-shown> — what a slot actually runs on: the
# parent for `inherit` (`unknown` when unread), else the value.
_tl_slot_model() {
  if [ "$1" = inherit ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

# tl_run_set_models <repo-root> <run-id> <slug> <tdd-path> [parent-id] —
# record the TDD's resolved slots (tl_resolve_models / tl_model_sources), plan
# class, session effort and parent (`unknown` when empty) in the sidecar.
# Escalation keys are kept. TDD 0067 adds an optional 6th arg.
tl_run_set_models() {
  local repo="${1:-}" run="${2:-}" slug="${3:-}" tdd="${4:-}" parent="${5:-}"
  local p eff cls all b bs r rs v vs k
  _tl_models_path "$repo" "$run" "$slug" >/dev/null || return $?
  { [ -n "$tdd" ] && [ -r "$tdd" ]; } || { echo "run-record: tl_run_set_models: TDD '$tdd' not readable" >&2; return 2; }
  for k in _tl_models_resolved tl_parent_effort tl_plan_class; do
    [ "$(type -t "$k")" = function ] || { echo "run-record: $k is not defined (source models.sh)" >&2; return 2; }
  done
  p="${parent:-unknown}"
  all="$(_tl_models_resolved "$tdd" "$parent")" || { echo "run-record: cannot resolve models for $slug" >&2; return 1; }
  { IFS= read -r b; IFS= read -r bs; IFS= read -r r; IFS= read -r rs
    IFS= read -r v; IFS= read -r vs; } <<<"$all"
  eff="$(tl_parent_effort)" || return 1
  cls="$(tl_plan_class "$tdd")" || return 1
  _tl_models_write "$repo" "$run" "$slug" \
    parent="$p" effort="${eff% *}" effort_source="${eff##* }" verify_class="$cls" \
    build="$b" build_src="$bs" build_model="$(_tl_slot_model "$b" "$p")" \
    review="$r" review_src="$rs" review_model="$(_tl_slot_model "$r" "$p")" \
    verify="$v" verify_src="$vs" verify_model="$(_tl_slot_model "$v" "$p")"
}

# tl_run_get_model_field <repo-root> <run-id> <slug> <key> — print the key's
# value (tl_json_field). rc 1 when there is no sidecar; rc 2 on a bad key.
tl_run_get_model_field() {
  local f
  f="$(_tl_models_path "${1:-}" "${2:-}" "${3:-}")" || return $?
  _tl_models_key_ok "${4:-}" || { echo "run-record: unknown models key '${4:-}'" >&2; return 2; }
  [ -f "$f" ] || return 1
  tl_json_field "$4" <"$f"
}

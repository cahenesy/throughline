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

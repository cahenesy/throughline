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

# tl_run_set_models <repo-root> <run-id> <slug> <tdd-path> [parent-id]
# [escalation-model] — record the TDD's resolved slots (tl_resolve_models /
# tl_model_sources), plan class, session effort and parent (`unknown` when
# empty) in the sidecar. Escalation keys are kept. A non-empty 6th arg (TDD
# 0067) is forwarded as the resolvers' escalation model.
tl_run_set_models() {
  local repo="${1:-}" run="${2:-}" slug="${3:-}" tdd="${4:-}" parent="${5:-}" esc="${6:-}"
  local p eff cls all b bs r rs v vs k
  _tl_models_path "$repo" "$run" "$slug" >/dev/null || return $?
  { [ -n "$tdd" ] && [ -r "$tdd" ]; } || { echo "run-record: tl_run_set_models: TDD '$tdd' not readable" >&2; return 2; }
  for k in _tl_models_resolved tl_parent_effort tl_plan_class; do
    [ "$(type -t "$k")" = function ] || { echo "run-record: $k is not defined (source models.sh)" >&2; return 2; }
  done
  p="${parent:-unknown}"
  all="$(_tl_models_resolved "$tdd" "$parent" "$esc")" || { echo "run-record: cannot resolve models for $slug" >&2; return 1; }
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

# --- Retry and escalation (TDD 0067 / FR-88, FR-39, FR-15, ADR 0015) --------
# Report files live in the run dir root, one per gate:
#   <run-dir>/<slug>.<build|ci-checks|verify|review>.txt  (test-first → build)
# Verdict files live in tl_verdict_dir. A Retry archives only the verdict
# *.json files, so a report path stays valid.

_tl_run_gate_report() {  # <gate> → the report-name part for that gate
  case "${1:-}" in
    test-first)     printf 'build' ;;
    runtime-verify) printf 'verify' ;;
    *)              printf '%s' "$1" ;;
  esac
}

# _tl_ref_blob <repo-root> <ref> <relpath> — the blob id of <relpath> at
# <ref>, or rc 1 (no output) when <ref> is empty, the path is absent, or it
# is not a blob.
_tl_ref_blob() {
  local sha
  [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  sha="$(git -C "$1" rev-parse -q --verify "$2:$3" 2>/dev/null)" || return 1
  [ "$(git -C "$1" cat-file -t "$sha" 2>/dev/null)" = blob ] || return 1
  printf '%s\n' "$sha"
}

# tl_run_latest_run <repo-root> — the run id `latest` points to (the basename
# of its resolved target). rc 1, no output, when `latest` is absent or
# dangling; rc 2 on a relative repo root.
tl_run_latest_run() {
  local logs l t id
  logs="$(_tl_run_logs "${1:-}")" || return $?
  l="$logs/latest"
  { [ -L "$l" ] && [ -d "$l" ]; } || return 1
  t="$(cd -P "$l" 2>/dev/null && pwd -P)" || return 1
  id="${t##*/}"
  _tl_valid_run "$id" || return 1
  printf '%s\n' "$id"
}

# tl_run_retry_candidates <repo-root> <run-id> — one slug per line for each
# <slug>.json fragment with status `failed` and halt_cause `gate-fail`
# (run.json and <slug>.models.json are not fragments). rc 0, including when
# there are none; rc 2 on an invalid or unknown run.
tl_run_retry_candidates() {
  local run="${2:-}" logs d f slug
  logs="$(_tl_run_logs "${1:-}")" || return $?
  _tl_valid_run "$run" || { echo "run-record: invalid run-id" >&2; return 2; }
  d="$logs/$run"
  [ -d "$d" ] || { echo "run-record: no run $run" >&2; return 2; }
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    slug="${f##*/}"; slug="${slug%.json}"
    case "$slug" in run|*.models) continue ;; esac
    _tl_valid_slug "$slug" || continue
    if [ "$(tl_json_field status <"$f")" = failed ] && [ "$(tl_json_field halt_cause <"$f")" = gate-fail ]; then
      printf '%s\n' "$slug"
    fi
  done
  return 0
}

# tl_run_failed_report <repo-root> <run-id> <slug> — the report path of the
# first gate (test-first, ci-checks, runtime-verify, review) whose verdict
# reads FAIL. rc 1, no output, when no verdict is FAIL or that report file is
# missing; rc 2 on a bad argument.
tl_run_failed_report() {
  local repo="${1:-}" run="${2:-}" slug="${3:-}" logs g json f
  logs="$(_tl_run_logs "$repo")" || return $?
  _tl_valid_run "$run" || { echo "run-record: invalid run-id" >&2; return 2; }
  _tl_valid_slug "$slug" || { echo "run-record: invalid slug '$slug'" >&2; return 2; }
  for g in test-first ci-checks runtime-verify review; do
    json="$(tl_verdict_read "$repo" "$run" "$slug" "$g" 2>/dev/null)" || continue
    [ "$(printf '%s' "$json" | tl_json_field status)" = FAIL ] || continue
    f="$logs/$run/$slug.$(_tl_run_gate_report "$g").txt"
    [ -f "$f" ] || return 1
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

# tl_run_retry_begin <repo-root> <run-id> <slug> — start a Retry: move every
# verdict *.json in tl_verdict_dir into <that dir>/retry-<N>/ (N = 1 + the
# highest existing retry-<n> dir), then tl_run_set_tdd … building, so
# tl_run_next_gate is test-first and an interrupted Retry resumes from the
# first gate. Prints the archive dir. rc 0; rc 1 on an io error (nothing
# moved when the mkdir fails) or an uninitialized run; rc 2 on a bad argument.
tl_run_retry_begin() {
  local repo="${1:-}" run="${2:-}" slug="${3:-}" logs vdir d k n=0 arch f
  logs="$(_tl_run_logs "$repo")" || return $?
  vdir="$(tl_verdict_dir "$repo" "$run" "$slug")" || return $?
  [ -f "$logs/$run/run.json" ] || { echo "run-record: run $run not initialized" >&2; return 1; }
  for d in "$vdir"/retry-*; do
    [ -d "$d" ] || continue
    k="${d##*/retry-}"
    case "$k" in ''|*[!0-9]*) continue ;; esac
    k=$((10#$k))
    if [ "$k" -gt "$n" ]; then n="$k"; fi
  done
  arch="$vdir/retry-$((n + 1))"
  { mkdir -p "$vdir" && mkdir "$arch"; } 2>/dev/null || { echo "run-record: cannot create $arch" >&2; return 1; }
  for f in "$vdir"/*.json; do
    [ -f "$f" ] || continue
    mv "$f" "$arch/" || { echo "run-record: cannot move $f into $arch" >&2; return 1; }
  done
  tl_run_set_tdd "$repo" "$run" "$slug" building || return 1
  printf '%s\n' "$arch"
}

# tl_run_set_halt_blob <repo-root> <run-id> <slug> <tdd-relpath> — record
# halt_tdd_blob = `git rev-parse <integ>:<tdd-relpath>` (integ from
# _tl_integration_ref) in the sidecar. Unresolvable: rc 1, nothing written,
# stderr `run-record: cannot resolve <tdd-relpath> on <integ>`.
tl_run_set_halt_blob() {
  local repo="${1:-}" run="${2:-}" slug="${3:-}" rel="${4:-}" integ blob
  _tl_models_path "$repo" "$run" "$slug" >/dev/null || return $?
  [ -n "$rel" ] || { echo "run-record: tl_run_set_halt_blob needs <tdd-relpath>" >&2; return 2; }
  integ="$(_tl_integration_ref "$repo" 2>/dev/null)" || integ=""
  blob="$(_tl_ref_blob "$repo" "$integ" "$rel")" || {
    printf 'run-record: cannot resolve %s on %s\n' "$rel" "${integ:-(no integration branch)}" >&2
    return 1
  }
  _tl_models_write "$repo" "$run" "$slug" halt_tdd_blob="$blob"
}

# tl_escalation_decide <repo-root> <run-id> <slug> <tdd-relpath> <requested>
# <auto> — prints `requested`, `auto` or `none` (FR-88). requested=1 →
# requested; else auto=0 → none; else auto iff the fragment is
# failed/gate-fail, at least one verdict reads FAIL, and the sidecar
# halt_tdd_blob is non-empty and equals the TDD's current integration blob;
# else none. rc 0; rc 2 on a usage error.
tl_escalation_decide() {
  local repo="${1:-}" run="${2:-}" slug="${3:-}" rel="${4:-}" req="${5:-}" aut="${6:-}"
  local logs sfile g json anyfail=0 blob cur integ
  [ "$#" -eq 6 ] || { echo "run-record: tl_escalation_decide <repo> <run> <slug> <tdd-relpath> <requested> <auto>" >&2; return 2; }
  logs="$(_tl_run_logs "$repo")" || return 2
  _tl_valid_run "$run" || { echo "run-record: invalid run-id" >&2; return 2; }
  _tl_valid_slug "$slug" || { echo "run-record: invalid slug '$slug'" >&2; return 2; }
  [ -n "$rel" ] || { echo "run-record: tl_escalation_decide needs <tdd-relpath>" >&2; return 2; }
  case "$req" in 0|1) ;; *) echo "run-record: <requested> must be 0 or 1" >&2; return 2 ;; esac
  case "$aut" in 0|1) ;; *) echo "run-record: <auto> must be 0 or 1" >&2; return 2 ;; esac
  if [ "$req" = 1 ]; then printf 'requested\n'; return 0; fi
  if [ "$aut" = 0 ]; then printf 'none\n'; return 0; fi
  sfile="$logs/$run/$slug.json"
  if [ ! -f "$sfile" ] || [ "$(tl_json_field status <"$sfile")" != failed ] \
     || [ "$(tl_json_field halt_cause <"$sfile")" != gate-fail ]; then
    printf 'none\n'; return 0
  fi
  for g in test-first ci-checks runtime-verify review; do
    json="$(tl_verdict_read "$repo" "$run" "$slug" "$g" 2>/dev/null)" || continue
    if [ "$(printf '%s' "$json" | tl_json_field status)" = FAIL ]; then anyfail=1; fi
  done
  [ "$anyfail" = 1 ] || { printf 'none\n'; return 0; }
  blob="$(tl_run_get_model_field "$repo" "$run" "$slug" halt_tdd_blob 2>/dev/null)" || blob=""
  integ="$(_tl_integration_ref "$repo" 2>/dev/null)" || integ=""
  cur="$(_tl_ref_blob "$repo" "$integ" "$rel")" || cur=""
  if [ -n "$blob" ] && [ "$blob" = "$cur" ]; then printf 'auto\n'; else printf 'none\n'; fi
  return 0
}

# tl_run_set_escalation <repo-root> <run-id> <slug> <outcome> <model> [reason]
# — record escalation / escalation_model / escalation_reason (an absent reason
# clears it), then print the one outcome line
# `throughline: <slug> escalation=<outcome> model=<model>[ reason=<reason>]`.
# <outcome> must be escalated|already-top|fell-back. rc 0; rc 2 on a bad
# outcome or an empty model (nothing written); rc 1 on io.
tl_run_set_escalation() {
  local repo="${1:-}" run="${2:-}" slug="${3:-}" outcome="${4:-}" model="${5:-}" reason="${6:-}" shown
  case "$outcome" in
    escalated|already-top|fell-back) ;;
    *) echo "run-record: bad escalation outcome '$outcome' (want escalated|already-top|fell-back)" >&2; return 2 ;;
  esac
  [ -n "$model" ] || { echo "run-record: tl_run_set_escalation needs <model>" >&2; return 2; }
  _tl_models_write "$repo" "$run" "$slug" \
    escalation="$outcome" escalation_model="$model" escalation_reason="$reason" || return $?
  if [ -n "$reason" ]; then
    shown="${reason//$'\r'/ }"; shown="${shown//$'\n'/ }"   # one line; the sidecar keeps the raw reason
    printf 'throughline: %s escalation=%s model=%s reason=%s\n' "$slug" "$outcome" "$model" "$shown"
  else
    printf 'throughline: %s escalation=%s model=%s\n' "$slug" "$outcome" "$model"
  fi
}

# tl_escalation_fellback_check <report-path> <worktree> <base-sha> <worker>
# — prints `ok` or `fell-back <reason>` for an escalated worker (FR-88: a
# fall-back is detected at dispatch, never by an inactivity timeout). <worker>
# is implementer|verify|review. A missing or empty (whitespace-only) report →
# `fell-back no report`; for the implementer, when `git rev-list
# <base-sha>..HEAD` in <worktree> is readable: empty → `fell-back no report,
# no commits`, non-empty → `ok` (a real failure, classified by the normal
# rules). A non-empty report → `ok`. rc 0; rc 2 on a bad <worker>.
tl_escalation_fellback_check() {
  local rep="${1:-}" wt="${2:-}" base="${3:-}" worker="${4:-}" commits
  case "$worker" in
    implementer|verify|review) ;;
    *) echo "run-record: bad worker '$worker' (want implementer|verify|review)" >&2; return 2 ;;
  esac
  if [ -n "$rep" ] && [ -f "$rep" ] && grep -q '[^[:space:]]' "$rep" 2>/dev/null; then
    printf 'ok\n'; return 0
  fi
  if [ "$worker" = implementer ] && [ -n "$wt" ] && [ -n "$base" ] \
     && commits="$(git -C "$wt" rev-list "$base..HEAD" 2>/dev/null)"; then
    if [ -n "$commits" ]; then printf 'ok\n'; else printf 'fell-back no report, no commits\n'; fi
    return 0
  fi
  printf 'fell-back no report\n'
}

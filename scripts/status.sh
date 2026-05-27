#!/usr/bin/env bash
# status.sh — render /implement run progress (FR-28/FR-29/FR-30).
#
# Single source of THE view: a one-shot snapshot by default, --follow for a
# live, read-only watch. Read-only observability — never signals the build,
# never offers pause/resume/cancel. The honesty rules (FR-30) live here in one
# place: the percent is always suffixed `(estimate)`, and it never reads 100%
# while any TDD is non-terminal.
#
# The view is DERIVED on each read from the per-run state record at
# $LOGDIR/state.d/ (FR-27 — run.json + a per-TDD <slug>.json fragment). The
# record is the single source of truth (see scripts/implement.sh).
#
# Usage:
#   status.sh                     snapshot the active run (resolves `latest`)
#   status.sh --logdir <dir>      snapshot a specific run dir (overrides latest)
#   status.sh --follow [secs]     live watch (default 3s); Ctrl-C exits cleanly
#
# Parsers: jq → python3 → a minimal bash/sed fallback (all optional). The
# bash path always works ⇒ no hard dependency.
set -uo pipefail

LOGDIR_ARG=""; FOLLOW=0; FOLLOW_INTERVAL=3; CHECK_PAUSED=0
while [ $# -gt 0 ]; do case "$1" in
  --logdir) LOGDIR_ARG="$2"; shift 2 ;;
  --follow)
    FOLLOW=1; shift
    if [ $# -gt 0 ] && printf '%s' "$1" | grep -qE '^[0-9]+$'; then
      FOLLOW_INTERVAL="$1"; shift; fi ;;
  --check-paused) CHECK_PAUSED=1; shift ;;
  -h|--help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "status.sh: unknown arg: $1" >&2; exit 2 ;;
esac; done

PARSER=bash
if   command -v jq      >/dev/null 2>&1; then PARSER=jq
elif command -v python3 >/dev/null 2>&1; then PARSER=python; fi

# Field separator for the intermediate stream the readers emit and the renderer
# splits on. Tab is whitespace IFS, which would collapse adjacent empty fields
# (a `null` stage or empty pr_url between two populated fields) — use the ASCII
# Unit Separator instead so empty fields round-trip exactly.
SEP=$'\x1f'

# extract_run <file>   -> TAB-separated: mode integration started updated state total
# Reads run.json and emits a tab-separated, header-free record the renderer can
# split with `IFS=$'\t' read`. PARSER chooses jq/python3/bash; all produce the
# same intermediate shape so render code stays parser-agnostic.
extract_run() {
  local f="$1"
  case "$PARSER" in
    jq)
      jq -r '[.mode, .integration_branch, (.started_at|tostring), (.updated_at|tostring), .state, (.total|tostring)] | @tsv' "$f" 2>/dev/null \
        | tr '\t' "$SEP"
      ;;
    python)
      python3 - "$f" "$SEP" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1])); sep = sys.argv[2]
def s(v): return "" if v is None else str(v)
print(sep.join(s(d.get(k, "")) for k in ("mode","integration_branch","started_at","updated_at","state","total")))
PY
      ;;
    *)
      local mode integ sta upd state tot
      mode="$(sed -n 's/.*"mode":"\([^"]*\)".*/\1/p'              "$f" | head -1)"
      integ="$(sed -n 's/.*"integration_branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
      sta="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p'          "$f" | head -1)"
      upd="$(sed -n 's/.*"updated_at":\([0-9]*\).*/\1/p'          "$f" | head -1)"
      state="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p'            "$f" | head -1)"
      tot="$(sed -n 's/.*"total":\([0-9]*\).*/\1/p'               "$f" | head -1)"
      printf '%s%s%s%s%s%s%s%s%s%s%s\n' "$mode" "$SEP" "$integ" "$SEP" "$sta" "$SEP" "$upd" "$SEP" "$state" "$SEP" "$tot"
      ;;
  esac
}

# extract_tdd <file>   -> TAB: n slug path qp status stage updated_at branch pr_url note paused_cause
# TDD 0011 / FR-45 extends the emit shape with paused_cause (or empty
# when the fragment is not in paused state / a pre-FR-39 fragment).
extract_tdd() {
  local f="$1"
  case "$PARSER" in
    jq)
      jq -r '[(.n|tostring), .slug, .path, (.queue_pos|tostring), .status, (.stage // ""), (.updated_at|tostring), (.branch // ""), (.pr_url // ""), (.note // ""), (.paused_cause // "")] | @tsv' "$f" 2>/dev/null \
        | tr '\t' "$SEP"
      ;;
    python)
      python3 - "$f" "$SEP" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1])); sep = sys.argv[2]
def s(v): return "" if v is None else str(v)
print(sep.join(s(d.get(k, "")) for k in ("n","slug","path","queue_pos","status","stage","updated_at","branch","pr_url","note","paused_cause")))
PY
      ;;
    *)
      local n slug path qp status stage upd br pr note cause
      n="$(sed -n      's/.*"n":\([0-9]*\).*/\1/p'         "$f" | head -1)"
      slug="$(sed -n   's/.*"slug":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
      path="$(sed -n   's/.*"path":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
      qp="$(sed -n     's/.*"queue_pos":\([0-9]*\).*/\1/p' "$f" | head -1)"
      status="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p'   "$f" | head -1)"
      if grep -q '"stage":null' "$f" 2>/dev/null; then stage=""
      else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
      upd="$(sed -n    's/.*"updated_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
      br="$(sed -n     's/.*"branch":"\([^"]*\)".*/\1/p'   "$f" | head -1)"
      pr="$(sed -n     's/.*"pr_url":"\([^"]*\)".*/\1/p'   "$f" | head -1)"
      note="$(sed -n   's/.*"note":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
      if grep -q '"paused_cause":null' "$f" 2>/dev/null; then cause=""
      else cause="$(sed -n 's/.*"paused_cause":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
      printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
        "$n" "$SEP" "$slug" "$SEP" "$path" "$SEP" "$qp" "$SEP" "$status" "$SEP" \
        "$stage" "$SEP" "$upd" "$SEP" "$br" "$SEP" "$pr" "$SEP" "$note" "$SEP" "$cause"
      ;;
  esac
}

# Format seconds as "HhMm" / "MmSs" / "Ss" — compact and human-readable.
fmt_elapsed() {
  local s="$1" h m
  [ -z "$s" ] && { printf '?'; return; }
  h=$((s / 3600)); m=$(( (s % 3600) / 60 ))
  if   [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm%ds' "$m" "$((s % 60))"
  else                      printf '%ds'   "$s"
  fi
}

# Render the snapshot from <state.d>. Computes the rollup + estimate from the
# per-TDD fragments (single source of truth — run.json's counts are advisory).
# Estimate (FR-28 / FR-30):
#   - each TDD is worth 1/total of the percent
#   - terminal TDDs (done/failed/blocked/skipped) contribute 1.0
#   - non-terminal contribute a stage fraction:
#       build 0.20 / test-first 0.40 / verify 0.50 / verify-runtime 0.70
#       / review 0.85 / flip 0.95
#     (pending → 0.0). The renderer caps at 99% while ANY TDD is non-terminal,
#     so "100%" is only ever displayed when every TDD has reached a terminal
#     state (FR-30 honesty).
render_snapshot() {
  local sd="$1"
  local run_file="$sd/run.json"
  local mode="" integ="" sta="" upd="" state="" tot=""
  if [ -f "$run_file" ]; then
    IFS="$SEP" read -r mode integ sta upd state tot <<<"$(extract_run "$run_file")"
  fi
  local total="${tot:-0}"
  local now; now=$(date +%s)

  local tmp; tmp="$(mktemp)"
  local f
  for f in "$sd"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "run.json" ] && continue
    extract_tdd "$f" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    sort -t "$SEP" -k4,4n "$tmp" > "$tmp.sorted"
    mv "$tmp.sorted" "$tmp"
  fi

  local completed=0 failed=0 blocked=0 skipped=0 paused=0 nonterm=0 sum_num=0
  local cur_slug="" cur_status="" cur_stage=""
  # paused_resume_* — the first paused TDD's slug + stage, used to render
  # the FR-45 resume-instruction trailer once after the table.
  local paused_resume_slug="" paused_resume_stage=""
  local n slug path qp status stage upd_t br pr note cause
  while IFS="$SEP" read -r n slug path qp status stage upd_t br pr note cause; do
    [ -z "$slug" ] && continue
    case "$status" in
      done)    completed=$((completed+1)); sum_num=$((sum_num + 100)) ;;
      failed)  failed=$((failed+1));       sum_num=$((sum_num + 100)) ;;
      blocked) blocked=$((blocked+1));     sum_num=$((sum_num + 100)) ;;
      skipped) skipped=$((skipped+1));     sum_num=$((sum_num + 100)) ;;
      paused)  paused=$((paused+1))
               # Paused is a non-terminal (resumable) state; the percent
               # estimate should reflect the most-recent stage reached,
               # not jump to 100.
               case "$stage" in
                 build)          sum_num=$((sum_num + 20)) ;;
                 test-first)     sum_num=$((sum_num + 40)) ;;
                 verify)         sum_num=$((sum_num + 50)) ;;
                 verify-runtime) sum_num=$((sum_num + 70)) ;;
                 review)         sum_num=$((sum_num + 85)) ;;
                 flip)           sum_num=$((sum_num + 95)) ;;
                 *)              : ;;
               esac
               nonterm=$((nonterm+1))
               [ -z "$paused_resume_slug" ] && {
                 paused_resume_slug="$slug"; paused_resume_stage="$stage"; }
               ;;
      *)
        nonterm=$((nonterm+1))
        case "$stage" in
          build)          sum_num=$((sum_num + 20)) ;;
          test-first)     sum_num=$((sum_num + 40)) ;;
          verify)         sum_num=$((sum_num + 50)) ;;
          verify-runtime) sum_num=$((sum_num + 70)) ;;
          review)         sum_num=$((sum_num + 85)) ;;
          flip)           sum_num=$((sum_num + 95)) ;;
          *)              : ;;  # pending or unknown → 0
        esac
        [ -z "$cur_slug" ] && { cur_slug="$slug"; cur_status="$status"; cur_stage="$stage"; }
        ;;
    esac
  done < "$tmp"

  local pct=0
  if [ "$total" -gt 0 ]; then
    pct=$(( sum_num / total ))
    # FR-30 honesty: 100% is reserved for "every TDD is terminal".
    [ "$nonterm" -gt 0 ] && [ "$pct" -ge 100 ] && pct=99
  fi

  local elapsed
  elapsed="$(fmt_elapsed "$(( now - ${sta:-now} ))")"

  printf '/implement run — mode=%s · integration=%s · elapsed=%s · state=%s\n' \
    "${mode:-?}" "${integ:-?}" "$elapsed" "${state:-?}"
  printf '%d done / %d  ·  ~%d%% (estimate)' "$completed" "$total" "$pct"
  if [ "$failed" -gt 0 ] || [ "$blocked" -gt 0 ] || [ "$skipped" -gt 0 ] || [ "$paused" -gt 0 ]; then
    printf '  · '
    [ "$failed" -gt 0 ]  && printf ' failed=%d'  "$failed"
    [ "$blocked" -gt 0 ] && printf ' blocked=%d' "$blocked"
    [ "$skipped" -gt 0 ] && printf ' skipped=%d' "$skipped"
    [ "$paused" -gt 0 ]  && printf ' paused=%d'  "$paused"
  fi
  printf '\n\n'

  printf '%-3s  %-30s  %-12s  %-15s  %s\n' "#" "slug" "status" "stage" "PR / branch"
  printf '%-3s  %-30s  %-12s  %-15s  %s\n' "---" "------------------------------" "------------" "---------------" "-----------"
  while IFS="$SEP" read -r n slug path qp status stage upd_t br pr note cause; do
    [ -z "$slug" ] && continue
    local ptr="${pr:-${br:-—}}"
    local status_disp="$status"
    # TDD 0011 / FR-45: paused rows show the recoverable cause inline so
    # the user sees ratelimit / usage-limit / transient at a glance.
    if [ "$status" = "paused" ] && [ -n "$cause" ]; then
      status_disp="paused ($cause)"
    fi
    printf '%-3s  %-30s  %-12s  %-15s  %s\n' "$qp" "$slug" "$status_disp" "${stage:--}" "$ptr"
  done < "$tmp"

  if [ -n "$cur_slug" ]; then
    printf '\nCurrent: %s (status=%s · stage=%s)\n' "$cur_slug" "$cur_status" "${cur_stage:--}"
  fi
  # FR-45: surface the resume instruction once. Only when there's a paused
  # TDD; never on `failed` (NFR-4 distinct verdict honesty).
  if [ -n "$paused_resume_slug" ]; then
    printf '\nRun /implement to resume from %s on %s\n' \
      "${paused_resume_stage:-?}" "$paused_resume_slug"
  fi

  rm -f "$tmp"
}

# Resolve the run directory: --logdir wins, else follow `latest`.
IMPL_ROOT="docs/tdd/.implement-logs"
RUNDIR=""
if [ -n "$LOGDIR_ARG" ]; then
  RUNDIR="$LOGDIR_ARG"
elif [ -L "$IMPL_ROOT/latest" ]; then
  TGT="$(readlink "$IMPL_ROOT/latest")"
  case "$TGT" in
    /*) RUNDIR="$TGT" ;;
    *)  RUNDIR="$IMPL_ROOT/$TGT" ;;
  esac
fi

# Active check (FR-27 single-run lock — FR-18 ensures one run, so a live PID at
# the lock means active; an absent/dead PID means no active run).
ACTIVE=0
LOCK="$IMPL_ROOT/.run.lock"
if [ -f "$LOCK" ]; then
  PID="$(cat "$LOCK" 2>/dev/null)"
  [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && ACTIVE=1
fi

# --check-paused (TDD 0011 / FR-39): scan the resolved state.d for any
# fragment with status=paused; print one machine-parseable line per paused
# TDD (slug=<slug> gate=<gate> cause=<cause>) and exit 0. Print nothing
# and exit 0 if none are paused or the run dir doesn't exist. Used by the
# /implement skill's "Detect interrupted run" step BEFORE any build work.
if [ "$CHECK_PAUSED" -eq 1 ]; then
  [ -n "$RUNDIR" ] && [ -d "$RUNDIR/state.d" ] || exit 0
  for f in "$RUNDIR"/state.d/*.json; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in run.json) continue ;; esac
    st="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
    [ "$st" = "paused" ] || continue
    slug="$(sed -n 's/.*"slug":"\([^"]*\)".*/\1/p' "$f" | head -1)"
    if grep -q '"stage":null' "$f" 2>/dev/null; then stage="-"
    else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
    if grep -q '"paused_cause":null' "$f" 2>/dev/null; then cause="-"
    else cause="$(sed -n 's/.*"paused_cause":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
    printf 'slug=%s gate=%s cause=%s\n' "$slug" "${stage:--}" "${cause:--}"
  done
  exit 0
fi

# --logdir always renders the requested dir; default flow respects ACTIVE.
if [ -z "$LOGDIR_ARG" ] && [ "$ACTIVE" -eq 0 ]; then
  echo "no active /implement run"
  if [ -n "$RUNDIR" ] && [ -d "$RUNDIR/state.d" ]; then
    echo
    echo "Last run:"
    render_snapshot "$RUNDIR/state.d"
  fi
  exit 0
fi

if [ -z "$RUNDIR" ] || [ ! -d "$RUNDIR/state.d" ]; then
  echo "no active /implement run"
  exit 0
fi

if [ "$FOLLOW" -eq 1 ]; then
  # Read-only watch: Ctrl-C exits cleanly without signalling the build (FR-29).
  # Only this process is touched — the build PID is never referenced here.
  trap 'exit 0' INT TERM
  while true; do
    printf '\033[H\033[2J'
    render_snapshot "$RUNDIR/state.d"
    sleep "$FOLLOW_INTERVAL"
  done
else
  render_snapshot "$RUNDIR/state.d"
fi

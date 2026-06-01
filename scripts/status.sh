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
#   status.sh --follow [secs] --max-seconds N
#                                 bound the watch's wall-clock; exit 0 at the cap
#
# A halted run (run.json state ∈ {paused, blocked, failed}) renders a one-screen
# halt context (TDD 0018 / FR-64): cause label, triggering finding, and the
# deterministic next-action options, fitting ≤ 24 lines × 80 columns.
#
# --follow signal caveat (issue #30): the watch traps INT TERM HUP QUIT. When
# `--follow` is launched as a background `&` job from a non-interactive shell,
# SIGINT is inherited as SIG_IGN and is silently un-trappable per POSIX-1-2017
# §2.11. Use SIGTERM (or SIGHUP/SIGQUIT) to stop a background `--follow` watch;
# SIGINT works correctly in the foreground. The optional `--max-seconds N` cap
# (default unlimited) bounds scripted/CI use of `--follow` without any signal.
#
# Parsers: jq → python3 → a minimal bash/sed fallback (all optional). The
# bash path always works ⇒ no hard dependency.
set -uo pipefail

LOGDIR_ARG=""; FOLLOW=0; FOLLOW_INTERVAL=3; CHECK_PAUSED=0; MAX_SECONDS=""
while [ $# -gt 0 ]; do case "$1" in
  --logdir) LOGDIR_ARG="$2"; shift 2 ;;
  --follow)
    FOLLOW=1; shift
    if [ $# -gt 0 ] && printf '%s' "$1" | grep -qE '^[0-9]+$'; then
      FOLLOW_INTERVAL="$1"; shift; fi ;;
  --max-seconds)
    MAX_SECONDS="$2"
    case "$MAX_SECONDS" in
      ''|*[!0-9]*) echo "status.sh: --max-seconds requires a non-negative integer" >&2; exit 2 ;;
    esac
    shift 2 ;;
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

# --- halted-run one-screen render (TDD 0018 / FR-64) -------------------------
# Clip a string to <max> columns, marking truncation with a trailing "..." so
# the renderer never wraps (TDD 0018 §Failure modes).
_clip() {  # <text> <max>
  local s="$1" max="$2"
  if [ "${#s}" -le "$max" ]; then printf '%s' "$s"
  else printf '%s...' "${s:0:$((max-3))}"; fi
}

# Read a scalar fragment field for the halt view, with the TDD 0018 backward-
# compat shim: a missing halt_cause falls back to paused_cause (matches
# scripts/lib/state.sh:_read_fragment_field so old paused fragments still render).
_halt_field() {  # <file> <key>
  local f="$1" k="$2" v
  if grep -q "\"$k\":null" "$f" 2>/dev/null; then v=""
  else v="$(sed -n "s/.*\"$k\":\"\\([^\"]*\\)\".*/\\1/p" "$f" | head -1)"; fi
  if [ -z "$v" ] && [ "$k" = "halt_cause" ] && ! grep -q '"halt_cause":' "$f" 2>/dev/null; then
    v="$(sed -n 's/.*"paused_cause":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  fi
  printf '%s' "$v"
}

# Echo the halt_next_actions labels, one per line (empty when absent/[]). Labels
# are comma- and quote-free by construction (state.sh:_next_actions_for_cause),
# so splitting on the `","` delimiter is unambiguous.
_halt_actions() {  # <file>
  local f="$1" raw
  raw="$(sed -n 's/.*"halt_next_actions":\(\[[^]]*\]\).*/\1/p' "$f" | head -1)"
  [ -z "$raw" ] && return 0
  [ "$raw" = "[]" ] && return 0
  raw="${raw#[}"; raw="${raw%]}"
  printf '%s' "$raw" | sed 's/^"//; s/"$//; s/","/\n/g'
}

# Is this halt_cause a paused-state (recoverable, resumable) cause? Mirrors
# state.sh:_is_paused_cause; gates the Resume: trailer.
_halt_is_paused_cause() {  # <cause>
  case "$1" in
    ratelimit|usage-limit|transient) return 0 ;;
    resume-blocked-build-state-missing|resume-blocked-branch-missing|resume-blocked-branch-divergence) return 0 ;;
    *) return 1 ;;
  esac
}

# A halt_cause the renderer recognizes (the closed FR-63 enum). An unrecognized
# value triggers the §Failure-modes raw-render fallback + a warning line.
_halt_cause_known() {  # <cause>
  case "$1" in
    ratelimit|usage-limit|transient|resume-blocked-build-state-missing) return 0 ;;
    resume-blocked-branch-missing|resume-blocked-branch-divergence) return 0 ;;
    rework-budget-exhausted|rework-scope-exceeded|structural-finding) return 0 ;;
    design-escalation|external-blocker) return 0 ;;
    *) return 1 ;;
  esac
}

# render_halt <state.d> <run-state> — the one-screen halt context. Selects the
# dominant halt fragment (blocked dominates paused dominates failed; ties break
# on queue position) and renders its cause, triggering finding, summary, and the
# deterministic next-action list within ≤ 24 lines × 80 columns.
render_halt() {
  local sd="$1" run_state="$2"
  local runid; runid="$(basename "$(dirname "$sd")")"

  # Pick the dominant halt fragment.
  local f st qp rank dom="" dom_rank=99 dom_qp=0
  for f in "$sd"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "run.json" ] && continue
    st="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
    case "$st" in
      blocked) rank=0 ;;
      paused)  rank=1 ;;
      failed)  rank=2 ;;
      *) continue ;;
    esac
    qp="$(sed -n 's/.*"queue_pos":\([0-9]*\).*/\1/p' "$f" | head -1)"; qp="${qp:-0}"
    if [ "$rank" -lt "$dom_rank" ] || { [ "$rank" -eq "$dom_rank" ] && [ "$qp" -lt "$dom_qp" ]; }; then
      dom="$f"; dom_rank="$rank"; dom_qp="$qp"
    fi
  done
  # Defensive: run.json says halted but no halt fragment found → fall back to
  # the normal table so the user still sees something.
  if [ -z "$dom" ]; then render_table "$sd" "$run_state"; return; fi

  local slug stage cause finding note
  slug="$(sed -n 's/.*"slug":"\([^"]*\)".*/\1/p' "$dom" | head -1)"
  if grep -q '"stage":null' "$dom" 2>/dev/null; then stage=""
  else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$dom" | head -1)"; fi
  cause="$(_halt_field "$dom" halt_cause)"
  finding="$(_halt_field "$dom" halt_triggering_finding_ref)"
  note="$(sed -n 's/.*"note":"\([^"]*\)".*/\1/p' "$dom" | head -1)"

  # §Failure modes: an unknown cause renders raw + warns, never refuses.
  if [ -n "$cause" ] && ! _halt_cause_known "$cause"; then
    printf 'warning: unknown halt_cause %s in fragment %s — falling back to raw render\n' \
      "'$cause'" "$slug"
  fi

  _clip "Run $runid  •  ${run_state:-?}: ${cause:-?}" 80; printf '\n'
  _clip "TDD: $slug  •  Gate: ${stage:--}" 80; printf '\n'
  _clip "Triggered by: ${finding:-(no finding reference)}" 80; printf '\n'
  printf '\n'
  if [ -n "$note" ]; then _clip "$note" 80; else _clip "Halt cause: ${cause:-unknown}" 80; fi
  printf '\n\n'

  printf 'Next actions:\n'
  local n=0 line
  # `|| [ -n "$line" ]` so the final newline-less line from _halt_actions
  # (sed emits no trailing newline) is not dropped.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    n=$((n+1))
    _clip "  $n) $line" 80; printf '\n'
  done < <(_halt_actions "$dom")
  if [ "$n" -eq 0 ]; then
    printf '  (none — see logs for guidance)\n'
  fi
  printf '\n'

  printf 'Logs: docs/tdd/.implement-logs/%s/\n' "$runid"
  # The Resume: trailer appears ONLY for a paused-state cause (TDD 0018 §4).
  if _halt_is_paused_cause "$cause"; then
    printf 'Resume: /implement --resume %s\n' "$runid"
  fi
}

# render_table — the rolling progress table (TDD 0008/0011 view). Used for
# active (running) runs and as render_halt's defensive fallback.
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
# render_snapshot — the single render entry point. Dispatches to the one-screen
# halt context (TDD 0018 / FR-64) when the run is halted (state ∈ {paused,
# blocked, failed}), else to the rolling progress table.
render_snapshot() {
  local sd="$1"
  local run_file="$sd/run.json"
  local _state=""
  if [ -f "$run_file" ]; then
    _state="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$run_file" | head -1)"
  fi
  case "$_state" in
    paused|blocked|failed) render_halt "$sd" "$_state"; return ;;
    interrupted) render_interrupted "$sd"; return ;;
  esac
  render_table "$sd"
}

# render_interrupted <state.d> — TDD 0030 §3 (gap 3) / FR-44, NFR-4. The run did
# not exit cleanly: the runner died while ≥1 TDD was mid-gate, leaving an
# orphaned non-terminal fragment a plain re-run would silently rebuild. Name each
# orphaned TDD + gate and point the user at /implement --resume, so a `building`
# fragment in a dead run reads honestly as interrupted — never in-progress, never
# done.
render_interrupted() {
  local sd="$1"
  local runid; runid="$(basename "$(dirname "$sd")")"
  _clip "Run $runid  •  interrupted: the run did not exit cleanly" 80; printf '\n'
  local f st slug stage
  for f in "$sd"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "run.json" ] && continue
    st="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
    case "$st" in building|verifying|reviewing) : ;; *) continue ;; esac
    slug="$(sed -n 's/.*"slug":"\([^"]*\)".*/\1/p' "$f" | head -1)"
    if grep -q '"stage":null' "$f" 2>/dev/null; then stage="-"
    else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
    _clip "TDD: $slug  •  Gate: ${stage:--}  •  orphaned (unclean-exit)" 80; printf '\n'
  done
  printf '\n'
  _clip "The runner exited without finishing. Re-run /implement to resume." 80; printf '\n'
  printf 'Resume: /implement --resume %s\n' "$runid"
}

render_table() {
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
    slug="$(sed -n 's/.*"slug":"\([^"]*\)".*/\1/p' "$f" | head -1)"
    if grep -q '"stage":null' "$f" 2>/dev/null; then stage="-"
    else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
    if [ "$st" = "paused" ]; then
      if grep -q '"paused_cause":null' "$f" 2>/dev/null; then cause="-"
      else cause="$(sed -n 's/.*"paused_cause":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
      # Plain paused lines stay exactly as they were (no marker) so existing
      # consumers parse unchanged.
      printf 'slug=%s gate=%s cause=%s\n' "$slug" "${stage:--}" "${cause:--}"
    elif [ "$st" = "blocked" ]; then
      # TDD 0027 §3a / FR-39: a blocked halt whose halt_next_actions array
      # contains an entry beginning `resume` is recoverable — surface it with a
      # trailing resumable=blocked marker (cause = the halt_cause, since
      # paused_cause is null for a blocked fragment). Other blocked causes
      # (design escalations) carry no resume prefix and stay unsurfaced.
      acts="$(sed -n 's/.*\("halt_next_actions":\[[^]]*\]\).*/\1/p' "$f" | head -1)"
      printf '%s' "$acts" | grep -qE '(\[|,)"resume' || continue
      if grep -q '"halt_cause":null' "$f" 2>/dev/null; then cause="-"
      else cause="$(sed -n 's/.*"halt_cause":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
      printf 'slug=%s gate=%s cause=%s resumable=blocked\n' "$slug" "${stage:--}" "${cause:--}"
    fi
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
  # Read-only watch: a stop signal exits cleanly without signalling the build
  # (FR-29). Only this process is touched — the build PID is never referenced.
  #
  # issue #30: trap INT TERM HUP QUIT (not just INT TERM). When --follow is
  # launched as a background `&` job from a non-interactive shell, SIGINT is
  # inherited as SIG_IGN and cannot be re-trapped (POSIX-1-2017 §2.11), so a
  # `kill -INT` is silently ignored. HUP and QUIT are NOT inherited-ignored on
  # async fork, so at least one stop signal is always trappable regardless of
  # launch mode; SIGTERM already worked and is preserved.
  trap 'exit 0' INT TERM HUP QUIT
  _follow_start=$(date +%s)
  while true; do
    printf '\033[H\033[2J'
    render_snapshot "$RUNDIR/state.d"
    # --max-seconds N: bound the watch's wall-clock for CI smoke tests / scripted
    # use. Exit 0 once the cap is reached (checked before the sleep so the loop
    # terminates near the cap, not a full interval past it).
    if [ -n "$MAX_SECONDS" ] && [ "$(( $(date +%s) - _follow_start ))" -ge "$MAX_SECONDS" ]; then
      exit 0
    fi
    sleep "$FOLLOW_INTERVAL"
  done
else
  render_snapshot "$RUNDIR/state.d"
fi

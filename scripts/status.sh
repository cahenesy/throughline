#!/usr/bin/env bash
# status.sh — /implement-status snapshot of the 0061 run-record (TDD 0063).
# Read-only. No pause/resume/cancel verbs. No jq hard dependency.
# Repo root is always `git rev-parse --show-toplevel`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
# shellcheck source=lib/run-record.sh
. "$SCRIPT_DIR/lib/run-record.sh" || {
  echo "FATAL: cannot source $SCRIPT_DIR/lib/run-record.sh" >&2
  exit 1
}

NO_RUN="no active /build-tdds run"
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "$NO_RUN"; exit 0; }

LOGS="$(_tl_run_logs "$REPO")"
RUNDIR=""
if [ -L "$LOGS/latest" ]; then
  TGT="$(readlink "$LOGS/latest")"
  case "$TGT" in
    /*) RUNDIR="$TGT" ;;
    *)  RUNDIR="$LOGS/$TGT" ;;
  esac
fi
if [ -z "$RUNDIR" ] || [ ! -f "$RUNDIR/run.json" ]; then
  echo "$NO_RUN"
  exit 0
fi

iso_epoch() { date -u -d "${1:-}" +%s 2>/dev/null || true; }
fmt_elapsed() {
  local s="${1:-}" h m
  case "$s" in ''|*[!0-9]*) printf '?'; return ;; esac
  h=$((s / 3600)); m=$(( (s % 3600) / 60 ))
  if   [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm%ds' "$m" "$((s % 60))"
  else                      printf '%ds'   "$s"
  fi
}

run_id="$(tl_json_field run_id <"$RUNDIR/run.json")"
started="$(tl_json_field started_at <"$RUNDIR/run.json")"
updated="$(tl_json_field updated_at <"$RUNDIR/run.json")"
n_total=0 n_done=0 n_term=0
any_paused=0 any_halt=0
cur_slug="" cur_status="" cur_gate=""
halt_slug="" halt_cause="" halt_gate=""
logp="" pr=""
SEP=$'\t'
tmp="$(mktemp)"
for f in "$RUNDIR"/*.json; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = "run.json" ] && continue
  slug="$(tl_json_field slug <"$f")"
  [ -n "$slug" ] || continue
  st="$(tl_json_field status <"$f")"
  cause="$(tl_json_field halt_cause <"$f")"
  gate="$(tl_json_field current_gate <"$f")"
  lp="$(tl_json_field log_path <"$f")"
  pu="$(tl_json_field pr_url <"$f")"
  qidx="$(tl_json_field queue_index <"$f")"; qidx="${qidx:-0}"
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$qidx" "$SEP" "$slug" "$SEP" "$st" "$SEP" "$cause" "$SEP" \
    "$gate" "$SEP" "$lp" "$SEP" "$pu" >>"$tmp"
done
if [ -s "$tmp" ]; then
  sort -t "$SEP" -k1,1n "$tmp" >"$tmp.s" && mv "$tmp.s" "$tmp"
fi

while IFS="$SEP" read -r qidx slug st cause gate lp pu; do
  [ -n "$slug" ] || continue
  n_total=$((n_total + 1))
  case "$st" in
    done) n_done=$((n_done + 1)); n_term=$((n_term + 1)) ;;
    failed|blocked|skipped) n_term=$((n_term + 1)) ;;
    *)
      [ -z "$cur_slug" ] && { cur_slug="$slug"; cur_status="$st"; cur_gate="$gate"; }
      ;;
  esac
  case "$st" in
    paused) any_paused=1; any_halt=1 ;;
    failed|blocked) any_halt=1 ;;
  esac
  if [ "$any_halt" -eq 1 ] && [ -z "$halt_slug" ]; then
    case "$st" in
      paused|failed|blocked)
        halt_slug="$slug"; halt_cause="$cause"; halt_gate="$gate" ;;
    esac
  fi
  [ -z "$logp" ] && [ -n "$lp" ] && logp="$lp"
  [ -z "$pr" ] && [ -n "$pu" ] && pr="$pu"
done <"$tmp"

if [ -z "$cur_slug" ] && [ -s "$tmp" ]; then
  IFS="$SEP" read -r _ cur_slug cur_status _ cur_gate _ _ <"$tmp"
fi
[ -z "$cur_slug" ] && { cur_slug="-"; cur_status="-"; cur_gate="-"; }

pct=0
if [ "$n_total" -gt 0 ]; then
  if [ "$n_term" -eq "$n_total" ]; then
    pct=100
  else
    pct=$(( n_term * 100 / n_total ))
    [ "$pct" -ge 100 ] && pct=99
  fi
fi

se="$(iso_epoch "$started")"
ue="$(iso_epoch "$updated")"
elapsed="?"
if [ -n "$se" ] && [ -n "$ue" ]; then
  delta=$((ue - se))
  [ "$delta" -lt 0 ] && delta=0
  elapsed="$(fmt_elapsed "$delta")"
fi

finding="$halt_cause"
case "$halt_gate" in
  test-first|ci-checks|runtime-verify|review)
    _vj="$(tl_verdict_read "$REPO" "$run_id" "$halt_slug" "$halt_gate" 2>/dev/null)" || _vj=""
    if [ -n "$_vj" ]; then
      _ev="$(printf '%s' "$_vj" | tl_json_field evidence)"
      [ -n "$_ev" ] && finding="$_ev"
    fi
    ;;
esac
[ -z "$finding" ] && finding="$halt_cause"

# Budget: run + current + elapsed + optional log/pr + paused + halt extras.
reserved=1
[ -n "$logp" ] && reserved=$((reserved + 1))
[ -n "$pr" ] && reserved=$((reserved + 1))
[ "$any_paused" -eq 1 ] && reserved=$((reserved + 1))
[ "$any_halt" -eq 1 ] && reserved=$((reserved + 3))
max_tdd=$((24 - 2 - reserved))
[ "$max_tdd" -lt 0 ] && max_tdd=0

printf 'run %s  %s/%s  ~%s%% (estimate)\n' "$run_id" "$n_done" "$n_total" "$pct"
printf 'current %s  stage=%s  gate=%s\n' "$cur_slug" "${cur_status:--}" "${cur_gate:--}"
n_tdd=0
while IFS="$SEP" read -r qidx slug st cause gate lp pu; do
  [ -n "$slug" ] || continue
  [ "$n_tdd" -ge "$max_tdd" ] && break
  if [ -n "$cause" ]; then
    printf '%s %s halt=%s\n' "$slug" "$st" "$cause"
  else
    printf '%s %s\n' "$slug" "$st"
  fi
  n_tdd=$((n_tdd + 1))
done <"$tmp"
printf 'elapsed %s\n' "$elapsed"
[ -n "$logp" ] && printf 'log %s\n' "$logp"
[ -n "$pr" ] && printf 'pr %s\n' "$pr"
[ "$any_paused" -eq 1 ] && printf 're-run /build-tdds to resume\n'
if [ "$any_halt" -eq 1 ]; then
  printf 'cause %s\n' "$halt_cause"
  printf 'finding %s\n' "$finding"
  printf 'next /build-tdds | /tdd-author\n'
fi
rm -f "$tmp"
exit 0

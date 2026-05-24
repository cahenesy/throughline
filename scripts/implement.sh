#!/usr/bin/env bash
# implement.sh — build TDDs unattended, behind real gates. Run detached
# (nohup/tmux) so it survives the session closing and keeps context clean.
#
#   ./scripts/implement.sh                    # all `ready` TDDs, stacked PRs
#   ./scripts/implement.sh docs/tdd/0003-x.md # just one TDD
#   ./scripts/implement.sh --parallel         # independent features, worktrees
#   ./scripts/implement.sh --combined         # one shared branch + ONE PR
#
# Each TDD is built in a FRESH `claude -p` process (clean context per feature).
# A build's own `BATCH_RESULT: OK` is NOT trusted as done. Before a TDD is
# flipped to `Status: implemented`, the runner enforces two independent gates:
#   1. verify.sh — re-runs the test suite + typecheck mechanically (deterministic).
#   2. review    — a SEPARATE `claude -p` review process (not a subagent of the
#                  author) that must end with `REVIEW_RESULT: PASS`.
# Only after both pass does the runner flip the TDD and (if gh+remote) open a PR.
# It never merges — merging is your gate.
#
# Failure handling (the key safety property):
#   sequential → TDDs are stacked, so a failure HALTS the run and marks every
#                downstream TDD BLOCKED rather than building on a broken base.
#   parallel   → TDDs are independent; a failure affects only that feature.
# A build that ends `BATCH_RESULT: BLOCKED <reason>` is a DESIGN blocker: it is
# appended to docs/tdd/BLOCKERS.md and surfaced for /tdd-author to revise.
set -uo pipefail

PARALLEL=0; COMBINED=0; MODEL=""; CHANGE=""; ONE=""
BASE="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
while [ $# -gt 0 ]; do case "$1" in
  --parallel) PARALLEL=1; shift ;;
  --combined) COMBINED=1; shift ;;
  --model)    MODEL="$2";  shift 2 ;;
  --change)   CHANGE="$2"; shift 2 ;;
  --base)     BASE="$2";   shift 2 ;;
  -*) echo "unknown arg: $1"; exit 2 ;;
  *)  ONE="$1"; shift ;;
esac; done
[ -z "$CHANGE" ] && CHANGE="build/$(date +%Y%m%d-%H%M%S)"

command -v claude >/dev/null 2>&1 || { echo "claude CLI not found on PATH"; exit 1; }
HASGH=0; command -v gh >/dev/null 2>&1 && HASGH=1
SDIR="$(cd "$(dirname "$0")" && pwd)"
TMPL="$SDIR/build-prompt.md"; RTMPL="$SDIR/review-prompt.md"; VERIFY="$SDIR/verify.sh"
for f in "$TMPL" "$RTMPL" "$VERIFY"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
[ -x "$VERIFY" ] || chmod +x "$VERIFY" 2>/dev/null || true
MAINREPO="$PWD"

LOGDIR="docs/tdd/.implement-logs/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$LOGDIR"
REPORT="$LOGDIR/report.md"; { echo "# Implement report — $(date)"; echo; } > "$REPORT"

if [ -n "$ONE" ]; then TDDS=("$ONE")
else mapfile -t TDDS < <(grep -lE '^Status:[[:space:]]*ready' docs/tdd/*.md 2>/dev/null | sort); fi
[ "${#TDDS[@]}" -eq 0 ] && { echo "No ready TDDs to build." | tee -a "$REPORT"; exit 0; }
echo "Queue (${#TDDS[@]}):"; printf '  %s\n' "${TDDS[@]}"; echo "Report: $REPORT"; echo

# --- per-TDD primitives (cwd = the repo or worktree they run in) ---------------
build_one() {  # <tdd> <log>
  local tdd="$1" log="$2" prompt; prompt="$(sed "s#{{TDD}}#${tdd}#g" "$TMPL")"
  local args=(-p "$prompt" --permission-mode auto); [ -n "$MODEL" ] && args+=(--model "$MODEL")
  claude "${args[@]}" >>"$log" 2>&1
}
review_one() {  # <tdd> <base-ref> <log>
  local tdd="$1" base="$2" log="$3" prompt
  prompt="$(sed -e "s#{{TDD}}#${tdd}#g" -e "s#{{BASE}}#${base}#g" "$RTMPL")"
  local args=(-p "$prompt" --permission-mode auto); [ -n "$MODEL" ] && args+=(--model "$MODEL")
  claude "${args[@]}" >>"$log" 2>&1
}
build_status()  { grep -aoE 'BATCH_RESULT: (OK|FAIL.*|BLOCKED.*)' "$1" 2>/dev/null | tail -1; }
review_status() { grep -aoE 'REVIEW_RESULT: (PASS|BLOCK.*)' "$1" 2>/dev/null | tail -1; }
run_verify()    { "$VERIFY" >>"$1" 2>&1; }
flip_status() {  # <tdd> <log>
  local tdd="$1" log="$2"
  sed -i.bak -E 's/^Status:[[:space:]]*ready/Status: implemented/' "$tdd" && rm -f "$tdd.bak"
  git add "$tdd" >>"$log" 2>&1
  git commit -m "mark $(basename "$tdd" .md) implemented (verified + reviewed)" >>"$log" 2>&1
}
record_blocker() {  # <tdd> <reason>  -> append to the main repo's blocker ledger
  local tdd="$1" reason="$2" bf="${MAINREPO:-$PWD}/docs/tdd/BLOCKERS.md"
  mkdir -p "$(dirname "$bf")"
  [ -f "$bf" ] || printf '# Implementation blockers\n\n> Design-level blockers raised by /implement. Resolve via /tdd-author, then delete the entry.\n\n' > "$bf"
  printf -- '- [ ] **%s** (%s): %s\n' "$(basename "$tdd")" "$(date +%Y-%m-%d)" "$reason" >> "$bf"
}

# gate_one: build -> classify -> verify gate -> independent review gate -> flip.
# Echoes a one-line status; returns 0 ONLY when the TDD was flipped to implemented.
gate_one() {  # <tdd> <review-base-ref> <log>
  local tdd="$1" rbase="$2" log="$3" bs rs
  build_one "$tdd" "$log"; bs="$(build_status "$log")"
  case "$bs" in
    *BLOCKED*) record_blocker "$tdd" "${bs#*BLOCKED}"; echo "BLOCKED (design)${bs#*BLOCKED}"; return 1 ;;
    *OK*) : ;;
    *) echo "${bs:-FAIL (no BATCH_RESULT; see log)}"; return 1 ;;
  esac
  if ! run_verify "$log"; then echo "FAIL verification (tests/typecheck red; not flipped)"; return 1; fi
  review_one "$tdd" "$rbase" "$log"; rs="$(review_status "$log")"
  case "$rs" in
    *PASS*) : ;;
    *BLOCK*) echo "FAIL review:${rs#*BLOCK}"; return 1 ;;
    *) echo "FAIL review (no REVIEW_RESULT; see log)"; return 1 ;;
  esac
  flip_status "$tdd" "$log"; echo "OK (verified + reviewed)"; return 0
}

# --- drivers -------------------------------------------------------------------
if [ "$PARALLEL" -eq 1 ]; then
  pids=()
  for tdd in "${TDDS[@]}"; do
    slug="$(basename "$tdd" .md)"; log="$LOGDIR/$slug.log"; wt="../$(basename "$PWD")-wt-$slug"
    if ! git worktree add -b "feat/$slug" "$wt" "$BASE" >>"$log" 2>&1; then
      echo "worktree failed for $slug" >>"$log"; continue; fi
    abslog="$PWD/$log"
    ( cd "$wt" || exit 1
      pre="$(git rev-parse HEAD)"
      st="$(gate_one "$tdd" "$pre" "$abslog")"; rc=$?
      printf 'PARSTATUS::%s\n' "$st" >>"$abslog"
      if [ "$rc" -eq 0 ] && [ "$HASGH" -eq 1 ]; then
        git push -u origin "feat/$slug" >>"$abslog" 2>&1 \
          && gh pr create --base "$BASE" --head "feat/$slug" --fill >>"$abslog" 2>&1; fi ) &
    pids+=("$!")
  done
  [ "${#pids[@]}" -gt 0 ] && wait "${pids[@]}" 2>/dev/null
  for tdd in "${TDDS[@]}"; do slug="$(basename "$tdd" .md)"; log="$LOGDIR/$slug.log"
    st="$(sed -n 's/^PARSTATUS:://p' "$log" 2>/dev/null | tail -1)"
    echo "- $slug — ${st:-UNKNOWN (see log)} (branch feat/$slug, log: $log)" >>"$REPORT"; done
  { echo; echo "Parallel: one PR per feat/* (if gh+remote). Review & merge each, then 'git worktree remove'."; } >>"$REPORT"

elif [ "$COMBINED" -eq 1 ]; then
  git checkout -b "$CHANGE" "$BASE" >>"$REPORT" 2>&1 || git checkout "$CHANGE" >>"$REPORT" 2>&1
  blocked=0
  for tdd in "${TDDS[@]}"; do slug="$(basename "$tdd" .md)"; log="$LOGDIR/$slug.log"
    if [ "$blocked" -eq 1 ]; then echo "- $slug — BLOCKED (upstream TDD failed; not attempted)" >>"$REPORT"; continue; fi
    pre="$(git rev-parse HEAD 2>/dev/null || echo "$BASE")"
    echo ">>> $slug"; st="$(gate_one "$tdd" "$pre" "$log")"; rc=$?
    echo "  $st"; echo "- $slug — $st (log: $log)" >>"$REPORT"
    [ "$rc" -ne 0 ] && blocked=1
  done
  if [ "$blocked" -eq 0 ] && [ "$HASGH" -eq 1 ]; then
    if git push -u origin "$CHANGE" >>"$REPORT" 2>&1 && gh pr create --base "$BASE" --head "$CHANGE" --fill >>"$REPORT" 2>&1; then
      echo "Opened ONE combined PR: $CHANGE -> $BASE (not merged — merging is your gate)." >>"$REPORT"; fi
  elif [ "$HASGH" -ne 1 ]; then echo "gh/remote not available: commits are on branch '$CHANGE'; open a PR manually." >>"$REPORT"; fi

else
  # default: one stacked branch + PR per TDD (preserves dependency order while
  # keeping each feature a separately reviewable human gate).
  prev="$BASE"; blocked=0
  for tdd in "${TDDS[@]}"; do
    slug="$(basename "$tdd" .md)"; log="$LOGDIR/$slug.log"; branch="$CHANGE/$slug"
    if [ "$blocked" -eq 1 ]; then echo "- $slug — BLOCKED (upstream TDD failed; not attempted)" >>"$REPORT"; continue; fi
    if ! git checkout -b "$branch" "$prev" >>"$log" 2>&1; then
      echo "- $slug — FAIL (could not branch off $prev; log: $log)" >>"$REPORT"; blocked=1; continue; fi
    pre="$(git rev-parse HEAD)"
    echo ">>> $slug (off $prev)"; st="$(gate_one "$tdd" "$pre" "$log")"; rc=$?; echo "  $st"
    if [ "$rc" -eq 0 ]; then
      pr=""
      if [ "$HASGH" -eq 1 ]; then
        git push -u origin "$branch" >>"$log" 2>&1 \
          && gh pr create --base "$prev" --head "$branch" --fill >>"$log" 2>&1 && pr=", PR base $prev"; fi
      echo "- $slug — $st (branch $branch$pr, log: $log)" >>"$REPORT"
      prev="$branch"
    else
      echo "- $slug — $st (branch $branch retained, NOT flipped; log: $log)" >>"$REPORT"; blocked=1
    fi
  done
  [ "$HASGH" -ne 1 ] && echo "gh/remote not available: per-TDD commits are on build/* branches; open PRs manually." >>"$REPORT"
fi

if [ -f "${MAINREPO:-$PWD}/docs/tdd/BLOCKERS.md" ]; then
  { echo; echo "Design blockers were recorded in docs/tdd/BLOCKERS.md — run /tdd-author to revise the design, then re-run /implement."; } >>"$REPORT"
fi
echo; echo "=== Done. Report: $REPORT ==="; cat "$REPORT"

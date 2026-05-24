#!/usr/bin/env bash
# implement.sh — build TDDs unattended, behind real gates. Run detached
# (nohup/tmux) so it survives the session closing and keeps context clean.
#
# Every mode builds in a DEDICATED git worktree (sequential/combined share one;
# parallel uses one per feature), so the detached runner never mutates the
# working tree your interactive session is using. Build branches/commits persist
# in the shared repo after the worktree is removed.
#
#   ./scripts/implement.sh                    # all `ready` TDDs, stacked PRs
#   ./scripts/implement.sh docs/tdd/0003-x.md # just one TDD
#   ./scripts/implement.sh --parallel         # independent features, worktrees
#   ./scripts/implement.sh --combined         # one shared branch + ONE PR
#   ./scripts/implement.sh --rebuild          # rebuild even already-built TDDs
#
# Re-run safety (the done-signal lives on the build branch, not your base, until
# you merge): a TDD already `implemented` on an existing un-merged branch is
# treated as done-but-awaiting-your-merge and SKIPPED, not rebuilt — so a re-run
# before you merge does not duplicate work or open duplicate PRs. A merged TDD is
# `implemented` on BASE and never queued; an abandoned/deleted branch rebuilds.
# --rebuild forces a fresh build regardless.
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

PARALLEL=0; COMBINED=0; REBUILD=0; MODEL=""; CHANGE=""; ONE=""
BASE="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
while [ $# -gt 0 ]; do case "$1" in
  --parallel) PARALLEL=1; shift ;;
  --combined) COMBINED=1; shift ;;
  --rebuild)  REBUILD=1;  shift ;;
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

# Logs/report live in the MAIN repo (absolute), so they survive the throwaway
# worktree and stay tailable from your session regardless of where builds run.
LOGDIR="$MAINREPO/docs/tdd/.implement-logs/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$LOGDIR"
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
run_verify()    { bash "$VERIFY" >>"$1" 2>&1; }
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

# --- resume support ------------------------------------------------------------
# The done-signal (Status: implemented) is committed on the build branch, not on
# your BASE, until you merge. These helpers read real branch state so a re-run
# skips work that is done-but-unmerged instead of rebuilding it. --rebuild forces.
built_branch() {  # <tdd> -> echoes the TDD's own build branch if already implemented
  [ "$REBUILD" -eq 1 ] && return 1
  local tdd="$1" slug; slug="$(basename "$tdd" .md)"; local ref
  while IFS= read -r ref; do
    case "$ref" in
      "$BASE"|"origin/$BASE") continue ;;
      */"$slug")
        git show "$ref:$tdd" 2>/dev/null | grep -qE '^Status:[[:space:]]*implemented' \
          && { printf '%s\n' "$ref"; return 0; } ;;
    esac
  done < <(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null)
  return 1
}
combined_built_branch() {  # echoes a branch where EVERY queued TDD is implemented
  [ "$REBUILD" -eq 1 ] && return 1
  local ref tdd ok
  while IFS= read -r ref; do
    case "$ref" in "$BASE"|"origin/$BASE") continue ;; esac
    ok=1
    for tdd in "${TDDS[@]}"; do
      git show "$ref:$tdd" 2>/dev/null | grep -qE '^Status:[[:space:]]*implemented' || { ok=0; break; }
    done
    [ "$ok" -eq 1 ] && { printf '%s\n' "$ref"; return 0; }
  done < <(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null)
  return 1
}
PR_PLAN=()  # ordered, bottom-up "merge me" list for stacked sequential PRs

# --- drivers -------------------------------------------------------------------
if [ "$PARALLEL" -eq 1 ]; then
  pids=(); declare -A SKIPPED=()
  for tdd in "${TDDS[@]}"; do
    slug="$(basename "$tdd" .md)"; log="$LOGDIR/$slug.log"; wt="../$(basename "$PWD")-wt-$slug"
    built="$(built_branch "$tdd")"
    if [ -n "$built" ]; then SKIPPED[$slug]="$built"; continue; fi
    if ! git worktree add -b "feat/$slug" "$wt" "$BASE" >>"$log" 2>&1; then
      echo "worktree failed for $slug" >>"$log"; continue; fi
    abslog="$log"
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
    if [ -n "${SKIPPED[$slug]:-}" ]; then
      echo "- $slug — already built on ${SKIPPED[$slug]} (awaiting your merge); skipped" >>"$REPORT"; continue; fi
    st="$(sed -n 's/^PARSTATUS:://p' "$log" 2>/dev/null | tail -1)"
    echo "- $slug — ${st:-UNKNOWN (see log)} (branch feat/$slug, log: $log)" >>"$REPORT"; done
  { echo; echo "Parallel: one PR per feat/* (if gh+remote). Review & merge each, then 'git worktree remove'."; } >>"$REPORT"

else
  # Sequential and combined both build inside ONE dedicated worktree, so the
  # detached runner never touches the working tree your live session is using.
  # The build branches/commits persist in the shared repo after the worktree is
  # removed — only the throwaway checkout goes away. Fail closed: if the isolated
  # worktree can't be created, refuse rather than fall back to the live tree.
  git worktree prune >/dev/null 2>&1 || true
  WORKROOT="$(dirname "$MAINREPO")/$(basename "$MAINREPO")-wt-$(printf '%s' "$CHANGE" | tr '/ :' '---')"
  if ! git worktree add --detach "$WORKROOT" "$BASE" >>"$REPORT" 2>&1; then
    { echo "FATAL: could not create isolated worktree at $WORKROOT (base '$BASE')."
      echo "Refusing to build in the live working tree; clear the error and re-run."; } | tee -a "$REPORT" >&2
    exit 1
  fi
  cd "$WORKROOT" || { echo "FATAL: cannot enter worktree $WORKROOT" | tee -a "$REPORT" >&2; exit 1; }

  if [ "$COMBINED" -eq 1 ]; then
    cb="$(combined_built_branch)"
    if [ -n "$cb" ]; then
      echo "- combined set already built on $cb (awaiting your merge); skipped. Use --rebuild to force." >>"$REPORT"
    else
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
    fi

  else
    # default: one stacked branch + PR per TDD (preserves dependency order while
    # keeping each feature a separately reviewable human gate).
    prev="$BASE"; blocked=0
    for tdd in "${TDDS[@]}"; do
      slug="$(basename "$tdd" .md)"; log="$LOGDIR/$slug.log"; branch="$CHANGE/$slug"
      if [ "$blocked" -eq 1 ]; then echo "- $slug — BLOCKED (upstream TDD failed; not attempted)" >>"$REPORT"; continue; fi
      built="$(built_branch "$tdd")"
      if [ -n "$built" ]; then
        echo "- $slug — already built on $built (awaiting your merge); skipped" >>"$REPORT"
        prev="$built"; continue; fi   # stack later TDDs on the already-built branch
      if ! git checkout -b "$branch" "$prev" >>"$log" 2>&1; then
        echo "- $slug — FAIL (could not branch off $prev; log: $log)" >>"$REPORT"; blocked=1; continue; fi
      pre="$(git rev-parse HEAD)"
      echo ">>> $slug (off $prev)"; st="$(gate_one "$tdd" "$pre" "$log")"; rc=$?; echo "  $st"
      if [ "$rc" -eq 0 ]; then
        pr=""; pbase="${prev#origin/}"   # PR base is a branch name, never origin/<name>
        if [ "$HASGH" -eq 1 ]; then
          if git push -u origin "$branch" >>"$log" 2>&1; then
            prurl="$(gh pr create --base "$pbase" --head "$branch" --fill 2>>"$log")"
            if [ -n "$prurl" ]; then pr=", $prurl"; PR_PLAN+=("$prurl  (base $pbase)")
            else pr=", PR create failed (see log)"; fi
          else pr=", push failed (see log)"; fi
        fi
        echo "- $slug — $st (branch $branch$pr, log: $log)" >>"$REPORT"
        prev="$branch"
      else
        echo "- $slug — $st (branch $branch retained, NOT flipped; log: $log)" >>"$REPORT"; blocked=1
      fi
    done
    [ "$HASGH" -ne 1 ] && echo "gh/remote not available: per-TDD commits are on build/* branches; open PRs manually." >>"$REPORT"
  fi

  cd "$MAINREPO" || true
  git worktree remove --force "$WORKROOT" >>"$REPORT" 2>&1 \
    || echo "note: leftover worktree at $WORKROOT (remove: git worktree remove --force '$WORKROOT')" >>"$REPORT"
fi

if [ "${#PR_PLAN[@]}" -gt 0 ]; then
  { echo
    echo "## Merge plan (stacked PRs — merge bottom-up)"
    echo "Merge in THIS order, bottom first. After you merge one, GitHub retargets"
    echo "the next PR onto its new base automatically. A SQUASH-merge rewrites the"
    echo "commits and breaks the stack, so prefer a merge commit or rebase-merge for"
    echo "these — or run with --combined next time to get a single squashable PR."
    i=1; for p in "${PR_PLAN[@]}"; do printf '%d. %s\n' "$i" "$p"; i=$((i+1)); done
  } >>"$REPORT"
fi

if [ -f "${MAINREPO:-$PWD}/docs/tdd/BLOCKERS.md" ]; then
  { echo; echo "Design blockers were recorded in docs/tdd/BLOCKERS.md — run /tdd-author to revise the design, then re-run /implement."; } >>"$REPORT"
fi
echo; echo "=== Done. Report: $REPORT ==="; cat "$REPORT"

#!/usr/bin/env bash
# implement.sh — orchestrate detached TDD builds behind real gates.
# Behavior contract (modes, gates 1-4, re-run safety, failure handling) lives
# in skills/implement/SKILL.md; this file is the runner. Keep it terse — read
# the skill for the rationale.
#
# Gate observability & safety boundaries (TDD 0010 / FR-36..38) layer onto those
# four gates: each `claude -p` gate logs a THROUGHLINE_SESSION: pointer via
# record_session_pointer (now in lib/pause-retry.sh, called from the gate
# executors in lib/gates.sh — no longer inline here); the build / runtime-verify
# scope rules live in scripts/build-prompt.md + verify-runtime-prompt.md.
#
#   ./scripts/implement.sh                    # every TDD merged to integration, stacked PRs
#   ./scripts/implement.sh docs/tdd/0003-x.md # just one TDD
#   ./scripts/implement.sh --parallel         # independent features, worktrees
#   ./scripts/implement.sh --combined         # one shared branch + ONE PR
#   ./scripts/implement.sh --rebuild          # rebuild even already-built TDDs
#
# Gate 3 (runtime-verify) tiers the model by the plan's complexity (mechanical →
# sonnet; nontrivial → the build model); override via THROUGHLINE_RUNTIME_VERIFY_MODEL
# (TDD 0013 / FR-52).
set -uo pipefail

# Sourced library modules (TDD 0015 + 0016 + 0017 / Theme D). Load order is
# load-bearing: state → pause-retry (uses state) → gates (uses both) → resume
# (uses gate_one). Sourced OUTSIDE the THROUGHLINE_SOURCE_ONLY guard so the test
# suite can call helpers when sourcing this script. Under `set -uo pipefail`
# (no -e), bare `.` failures don't abort; fail explicitly so a partial install
# can't leave the run silently no-op. pwd -P normalizes symlinks.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || {
  echo "FATAL: cannot resolve scripts directory from ${BASH_SOURCE[0]}" >&2
  exit 1
}
if [ ! -r "$SCRIPT_DIR/lib/state.sh" ]; then
  echo "FATAL: cannot read $SCRIPT_DIR/lib/state.sh (partial install or perms)" >&2
  exit 1
fi
# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh" || {
  echo "FATAL: failed to source $SCRIPT_DIR/lib/state.sh" >&2
  exit 1
}
if [ ! -r "$SCRIPT_DIR/lib/pause-retry.sh" ]; then
  echo "FATAL: cannot read $SCRIPT_DIR/lib/pause-retry.sh (partial install or perms)" >&2
  exit 1
fi
# shellcheck source=lib/pause-retry.sh
. "$SCRIPT_DIR/lib/pause-retry.sh" || {
  echo "FATAL: failed to source $SCRIPT_DIR/lib/pause-retry.sh" >&2
  exit 1
}
if [ ! -r "$SCRIPT_DIR/lib/gates.sh" ]; then
  echo "FATAL: cannot read $SCRIPT_DIR/lib/gates.sh (partial install or perms)" >&2
  exit 1
fi
# shellcheck source=lib/gates.sh
. "$SCRIPT_DIR/lib/gates.sh" || {
  echo "FATAL: failed to source $SCRIPT_DIR/lib/gates.sh" >&2
  exit 1
}
if [ ! -r "$SCRIPT_DIR/lib/resume.sh" ]; then
  echo "FATAL: cannot read $SCRIPT_DIR/lib/resume.sh (partial install or perms)" >&2
  exit 1
fi
# shellcheck source=lib/resume.sh
. "$SCRIPT_DIR/lib/resume.sh" || {
  echo "FATAL: failed to source $SCRIPT_DIR/lib/resume.sh" >&2
  exit 1
}

# _reclaim_stale_worktree <workroot> <report> (TDD 0027 §2 / FR-43)
# A kill -9 (or any unclean death) skips the EXIT trap that removes the build
# worktree, so the path is left on disk + registered; the next launch then FATALs
# on `git worktree add` because the path exists. Reclaim it: remove the
# registration + the directory so the caller falls through to a fresh add. Build
# branches (the durable output) live in refs, not in the worktree, so removing a
# stale worktree never discards committed work; uncommitted edits in a stale
# worktree are intentionally discarded per the existing non-goal ("Recovering
# uncommitted edits in a build worktree"). A path that is NOT a git worktree
# (random dir) makes `git worktree remove` fail → the `|| rm -rf` fallback clears
# it; if even that fails (permissions), the caller's FATAL on `git worktree add`
# still fires, so we never silently build inside an unknown directory. Defined
# above the SOURCE_ONLY guard so the test suite can drive it in isolation.
_reclaim_stale_worktree() {  # <workroot> <report>
  local workroot="$1" report="$2"
  [ -d "$workroot" ] || return 0
  echo "Reclaiming stale build worktree at $workroot (prior unclean exit)" >>"$report"
  git worktree remove --force "$workroot" >>"$report" 2>&1 || rm -rf "$workroot"
  git worktree prune >>"$report" 2>&1
}

# THROUGHLINE_SOURCE_ONLY=1 lets the test suite source this script to call
# helpers in isolation. Runtime side effects (arg parsing, lock, drivers,
# report) live below the guard; helpers are defined unconditionally above.

if [ "${THROUGHLINE_SOURCE_ONLY:-0}" != "1" ]; then
PARALLEL=0; COMBINED=0; REBUILD=0; MODEL=""; REVIEW_MODEL=""; CHANGE=""; ONE=""
RESUME=0
BASE="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
while [ $# -gt 0 ]; do case "$1" in
  --parallel) PARALLEL=1; shift ;;
  --combined) COMBINED=1; shift ;;
  --rebuild)  REBUILD=1;  shift ;;
  --resume)   RESUME=1;   shift ;;
  --model)        MODEL="$2";        shift 2 ;;
  --review-model) REVIEW_MODEL="$2"; shift 2 ;;
  --change)   CHANGE="$2"; shift 2 ;;
  --base)     BASE="$2";   shift 2 ;;
  -*) echo "unknown arg: $1"; exit 2 ;;
  *)  ONE="$1"; shift ;;
esac; done
[ -z "$CHANGE" ] && CHANGE="build/$(date +%Y%m%d-%H%M%S)"

# Integration branch: where a merged design PR lands a TDD. "Approved to build" =
# present there and not yet `implemented` — so the design-PR merge is the trigger,
# with no manual `ready` flip and no CI dependency. Un-merged drafts on a design
# branch are absent here, so the PR stays the gate. Detect it (origin's default →
# main → master → current branch); override with THROUGHLINE_INTEGRATION_BRANCH.
INTEGRATION="${THROUGHLINE_INTEGRATION_BRANCH:-}"
if [ -z "$INTEGRATION" ]; then
  git symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1 \
    && INTEGRATION="$(git symbolic-ref --short refs/remotes/origin/HEAD)"
  for cand in "$INTEGRATION" main master "$BASE"; do
    [ -n "$cand" ] && git rev-parse -q --verify "$cand^{commit}" >/dev/null 2>&1 \
      && { INTEGRATION="$cand"; break; }
  done
fi

# Models: build on the best available (opus); review on a DIFFERENT model for
# genuine diversity — a same-model reviewer shares the author's blind spots. The
# reviewer subagents are `model: inherit`, so this choice reaches the analysis,
# not just the orchestrator. Override via --model / --review-model or
# THROUGHLINE_BUILD_MODEL / THROUGHLINE_REVIEW_MODEL.
[ -z "$MODEL" ] && MODEL="${THROUGHLINE_BUILD_MODEL:-opus}"
if [ -z "$REVIEW_MODEL" ]; then
  REVIEW_MODEL="${THROUGHLINE_REVIEW_MODEL:-}"
  [ -z "$REVIEW_MODEL" ] && case "$MODEL" in
    *opus*) REVIEW_MODEL="sonnet" ;;
    *)      REVIEW_MODEL="opus"   ;;
  esac
fi

command -v claude >/dev/null 2>&1 || { echo "claude CLI not found on PATH"; exit 1; }
HASGH=0; command -v gh >/dev/null 2>&1 && HASGH=1
SDIR="$(cd "$(dirname "$0")" && pwd)"
TMPL="$SDIR/build-prompt.md"; RTMPL="$SDIR/review-prompt.md"; CI_CHECKS="$SDIR/ci-checks.sh"
RVMTPL="$SDIR/verify-runtime-prompt.md"; RWTMPL="$SDIR/rework-prompt.md"
for f in "$TMPL" "$RTMPL" "$RVMTPL" "$RWTMPL" "$CI_CHECKS"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
[ -x "$CI_CHECKS" ] || chmod +x "$CI_CHECKS" 2>/dev/null || true
MAINREPO="$PWD"

# Logs/report live in the MAIN repo (absolute), so they survive the throwaway
# worktree and stay tailable from your session regardless of where builds run.
# On --resume (TDD 0011 / FR-39), reuse the prior run's logdir (resolved from
# the `latest` symlink) so state.d/ + per-TDD logs continue, not restart.
if [ "$RESUME" -eq 1 ] && [ -L "$MAINREPO/docs/tdd/.implement-logs/latest" ]; then
  _prior="$(readlink "$MAINREPO/docs/tdd/.implement-logs/latest")"
  case "$_prior" in
    /*) LOGDIR="$_prior" ;;
    *)  LOGDIR="$MAINREPO/docs/tdd/.implement-logs/$_prior" ;;
  esac
  # TDD 0011 / MA-5: confine the symlink target to the log directory. The
  # threat model is local only (anyone who can rewrite this symlink can
  # already edit scripts/implement.sh), but the one-line check is belt-
  # and-suspenders defense in shared-repo environments (devcontainers,
  # shared CI runners) where the log dir's trust boundary may differ
  # from the script source. The check uses canonical paths so symlinks
  # within the target chain cannot escape via .. components.
  # TDD 0011 / iter-9 SEC-1: hard-fail on `cd` failure. The previous fallback
  # `echo "$LOGDIR"` let unresolved paths slip past the confinement check —
  # a symlink target with `..` segments would compare its UNRESOLVED form
  # against the unresolved root prefix and pass spuriously.
  _resolved_logdir="$(cd "$LOGDIR" 2>/dev/null && pwd -P)" \
    || { echo "FATAL: cannot canonicalize logdir '$LOGDIR' (symlink target missing or unreadable)" >&2; exit 1; }
  _resolved_root="$(cd "$MAINREPO/docs/tdd/.implement-logs" 2>/dev/null && pwd -P)" \
    || { echo "FATAL: cannot canonicalize log root '$MAINREPO/docs/tdd/.implement-logs'" >&2; exit 1; }
  case "$_resolved_logdir/" in
    "$_resolved_root/"*) : ;;
    *) echo "FATAL: 'latest' symlink target escapes log dir: $_resolved_logdir" >&2; exit 1 ;;
  esac
  [ -d "$LOGDIR" ] || { echo "FATAL: --resume target '$LOGDIR' does not exist" >&2; exit 1; }
  # TDD 0011 / iter-3 MAJOR-8: when "Start fresh" deleted state.d/*.json
  # but left the `latest` symlink, --resume would otherwise reach state_init
  # with a missing run.json, fall through to the fresh-init branch INSIDE
  # the prior run's directory, and silently overwrite it. Refuse explicitly
  # so the user understands the prior state was cleaned.
  if [ ! -f "$LOGDIR/state.d/run.json" ]; then
    echo "FATAL: --resume target has no paused state ($LOGDIR/state.d/run.json missing)." >&2
    echo "       Drop --resume to start fresh, or remove the 'latest' symlink." >&2
    exit 1
  fi
elif [ "$RESUME" -eq 1 ]; then
  # TDD 0011 / MAJOR-7: --resume with no `latest` symlink would otherwise
  # silently fall back to a fresh LOGDIR while RESUME=1 stays set. In
  # parallel mode that lets the driver attach to unrelated `feat/<slug>`
  # branches from prior runs. Fail loudly instead.
  echo "FATAL: --resume requested but no prior run found (docs/tdd/.implement-logs/latest missing)." >&2
  echo "       If the prior run dir was deleted, re-run without --resume." >&2
  exit 1
else
  LOGDIR="$MAINREPO/docs/tdd/.implement-logs/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$LOGDIR"
fi
REPORT="$LOGDIR/report.md"
# TDD 0011 / iter-7 MAJOR-1: on --resume the prior run's report.md
# carries the human-readable summary of every TDD that ran before the
# pause. Truncating it with `>` silently erases that history and
# violates the TDD's "reuse logdir for continuity" contract. Append a
# Resume header instead so the timeline is auditable end-to-end.
if [ "$RESUME" -eq 1 ] && [ -f "$REPORT" ]; then
  { echo; echo "# Resume — $(date)"; echo; } >> "$REPORT"
else
  { echo "# Implement report — $(date)"; echo; } > "$REPORT"
fi

# TDD 0030 §4 (gap 4): snapshot BLOCKERS.md's line count at run start so the
# run-end report prints the design-blocker pointer ONLY when THIS run appended to
# it (growth), not merely because the file exists. Line count (not mtime/size) is
# immune to `touch` and same-length edits; an absent file reads as 0.
BLOCKERS_FILE="${MAINREPO:-$PWD}/docs/tdd/BLOCKERS.md"
if [ -f "$BLOCKERS_FILE" ]; then
  BLOCKERS_LINES_AT_START="$(wc -l < "$BLOCKERS_FILE" 2>/dev/null | tr -d '[:space:]')"
else
  BLOCKERS_LINES_AT_START=0
fi
BLOCKERS_LINES_AT_START="${BLOCKERS_LINES_AT_START:-0}"

# Single-run lock: a second /implement on the same repo would double-build, so refuse
# to start while another run is live. This is what lets you keep authoring PRDs/TDDs
# in your session while a build runs detached — you can't accidentally launch a rival
# run. The lock is the runner's PID; a dead PID (e.g. after kill -9) is treated as
# stale and reclaimed. Released on exit (any cause) via the trap.
LOCK="$MAINREPO/docs/tdd/.implement-logs/.run.lock"
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  { echo "An /implement run is already in progress (PID $(cat "$LOCK")). Refusing to"
    echo "start a second — it would double-build. Wait for it, or if it's stale remove"
    echo "$LOCK and re-run."; } | tee -a "$REPORT" >&2
  exit 1
fi
echo "$$" > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

if [ -n "$ONE" ]; then TDDS=("$ONE")
else
  # Buildable = a TDD on the integration branch whose status THERE is draft|ready
  # (not yet implemented). The merge brought it onto integration; that is the
  # go-signal — no manual `ready` flip. Reading status from the ref (not the
  # working tree) keeps the queue deterministic and is what makes the merge-guard
  # airtight: an un-merged draft simply is not in this ref. `ready` is still
  # accepted, so TDDs hand-flipped under the old flow keep building.
  TDDS=()
  while IFS= read -r f; do
    st="$(git show "$INTEGRATION:$f" 2>/dev/null | sed -n 's/^Status:[[:space:]]*//p' | head -1)"
    case "$st" in draft|ready) TDDS+=("$f") ;; esac
  done < <(git ls-tree -r --name-only "$INTEGRATION" -- docs/tdd 2>/dev/null \
            | grep -E 'docs/tdd/[0-9][^/]*\.md$' | sort)
fi
[ "${#TDDS[@]}" -eq 0 ] && { echo "No buildable TDDs (none merged to $INTEGRATION awaiting build)." | tee -a "$REPORT"; exit 0; }
echo "Queue (${#TDDS[@]}):"; printf '  %s\n' "${TDDS[@]}"; echo "Report: $REPORT"; echo
# state_init (defined in lib/state.sh, sourced at the top) is invoked later, not
# here — it must run AFTER the parallel pre-skip pass below so a pre-skipped TDD
# still gets its fragment. See the call site further down.
fi  # end THROUGHLINE_SOURCE_ONLY guard (setup block)

# shellcheck disable=SC2317  # exit 0 is reached when this file is executed (not sourced)
if [ "${THROUGHLINE_SOURCE_ONLY:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi
PR_PLAN=()  # ordered, bottom-up "merge me" list for stacked sequential PRs

# Initialize the per-run state record (FR-27). One fragment per queued TDD so
# the renderer (status.sh) always sees `total` fragments — important under
# --parallel, where a pre-skipped TDD never enters the subshell pool and would
# otherwise leave no fragment behind. Runs here, AFTER every helper is defined.
state_init

# --- drivers -------------------------------------------------------------------
if [ "$PARALLEL" -eq 1 ]; then
  pids=(); declare -A SKIPPED=() BRANCH_MISSING=()
  for tdd in "${TDDS[@]}"; do
    slug="$(basename "$tdd" .md)"; log="$LOGDIR/$slug.log"; wt="../$(basename "$PWD")-wt-$slug"
    built="$(built_branch "$tdd")"
    if [ -n "$built" ]; then
      SKIPPED[$slug]="$built"
      _terminal_state "$slug" skipped "" "already built on $built; awaiting your merge"
      set_tdd_meta  "$slug" "branch=$built"
      continue
    fi
    # TDD 0011 / BL-3: parallel-mode resume. Each TDD's branch exists from
    # the prior run; the worktree may or may not exist. Three cases:
    #   (a) RESUME=1 and the feat/<slug> branch exists → re-create the
    #       worktree pointing at the existing branch (NO -b flag), then
    #       call _resume_from in the subshell so gate_one's _is_done
    #       check sees the prior completion list.
    #   (b) RESUME=1 and the branch is missing → mark paused with
    #       resume-blocked-branch-missing; do NOT spawn a subshell.
    #   (c) Fresh build → existing path (create branch + worktree).
    if [ "$RESUME" -eq 1 ] && git show-ref --verify --quiet "refs/heads/feat/$slug"; then
      # TDD 0011 / iter-3 BLOCKER-3: a paused run typically leaves the
      # worktree on disk (only the subshell exited; the parent's `git
      # worktree add` was never removed). An unconditional `git worktree
      # add` here fails with "<wt> already exists" and the TDD is
      # permanently marked failed. Detect a pre-registered worktree
      # pointing at feat/$slug and reuse it instead of re-creating.
      # TDD 0011 / iter-5 BLOCKER-3: $wt is a RELATIVE path
      # ("../$(basename $PWD)-wt-$slug") but `git worktree list --porcelain`
      # always emits ABSOLUTE paths. Comparing them directly would never
      # match → the reuse guard becomes dead code. Canonicalize $wt first
      # (resolve via the parent dir + basename so we don't require the
      # directory to exist yet — though in the resume case it usually does).
      _wt_existing=""
      _wt_abs=""
      if [ -d "$wt" ]; then
        _wt_abs="$(cd "$wt" 2>/dev/null && pwd -P)"
      else
        # Resolve the parent and append the leaf; works even if $wt itself
        # was removed.
        _wt_parent="$(cd "$(dirname "$wt")" 2>/dev/null && pwd -P)"
        [ -n "$_wt_parent" ] && _wt_abs="$_wt_parent/$(basename "$wt")"
      fi
      if [ -n "$_wt_abs" ] && git worktree list --porcelain 2>/dev/null | awk -v p="$_wt_abs" '
        /^worktree / { w=substr($0,10) }
        /^branch / { if (w==p) { print substr($0,8); exit } }
      ' | grep -qE "(^|/)feat/$slug\$"; then
        _wt_existing="$wt"
      fi
      if [ -n "$_wt_existing" ]; then
        echo "worktree-resume: reusing existing worktree at $wt for feat/$slug" >>"$log"
      else
        if ! git worktree add "$wt" "feat/$slug" >>"$log" 2>&1; then
          echo "worktree-resume failed for $slug" >>"$log"
          _terminal_state "$slug" failed "" "worktree resume failed"
          continue
        fi
      fi
    elif [ "$RESUME" -eq 1 ]; then
      # Branch is gone between pause and resume → documented paused_cause.
      echo "- $slug — PAUSED (branch feat/$slug missing; resume-blocked-branch-missing)" >>"$REPORT"
      _update_paused_cause "$slug" "resume-blocked-branch-missing" \
        || echo "warning: could not update paused_cause for $slug" >&2
      # TDD 0011 / iter-3 MAJOR-6: track branch-missing slugs so the
      # second reporting loop skips them (otherwise an UNKNOWN line is
      # appended duplicating the PAUSED line).
      BRANCH_MISSING[$slug]=1
      continue
    else
      # TDD 0011 / MAJOR-9: detect orphan feat/<slug> branches from a prior
      # run that the user cleaned state.d/ for. Fresh-start in parallel
      # mode otherwise fails opaquely with "branch already exists".
      if git show-ref --verify --quiet "refs/heads/feat/$slug"; then
        { echo "- $slug — FAIL (orphan branch feat/$slug exists from a prior run;"
          echo "  delete it with: git branch -D feat/$slug   (and any worktree at $wt)"
          echo "  before retrying)"; } >>"$REPORT"
        _terminal_state "$slug" failed "" "orphan branch feat/$slug exists; delete before retry"
        continue
      fi
      if ! git worktree add -b "feat/$slug" "$wt" "$BASE" >>"$log" 2>&1; then
        echo "worktree failed for $slug" >>"$log"
        _terminal_state "$slug" failed "" "worktree create failed"
        continue
      fi
    fi
    set_tdd_meta "$slug" "branch=feat/$slug"
    abslog="$log"
    # Export the resume-gates-done variable name AHEAD of the subshell so
    # _resume_from's `export "$var"` (which runs in the subshell) sets a
    # variable already attributed-exported in the calling scope. The
    # subshell inherits the exported binding either way; the
    # `_rkey_export` capture here is for the (rare) tests that read it
    # back from the parent. TDD 0011 / BLOCKER-1: _resume_from MUST run
    # INSIDE the subshell so its git operations resolve against the
    # worktree's HEAD (the build branch), not the main repo's HEAD.
    if [ "$RESUME" -eq 1 ]; then
      _rkey_export="$(_resume_gates_var "$slug")"
      export "${_rkey_export?}"
    fi
    ( cd "$wt" || exit 1
      install_deps "$abslog"
      # TDD 0011 / BLOCKER-1: resume inside the subshell so git context is
      # the worktree. BLOCKER-2: refuse-to-resume returns rc=3; emit a
      # report line and skip gate_one for this TDD.
      if [ "$RESUME" -eq 1 ]; then
        _resume_from "$slug"
        _rrc=$?
        if [ "$_rrc" -eq 3 ]; then
          # Read the just-written paused_cause for the report.
          _cause="${RESUME_REFUSE_CAUSE:-$(_read_fragment_field "$STATE_DIR/$slug.json" paused_cause)}"; unset RESUME_REFUSE_CAUSE
          printf 'PARSTATUS::PAUSED (refuse-to-resume: %s)\n' "${_cause:-unknown}" >>"$abslog"
          exit 0
        fi
      fi
      pre="$(git rev-parse HEAD)"
      st="$(gate_one "$tdd" "$pre" "$abslog")"; rc=$?
      printf 'PARSTATUS::%s\n' "$st" >>"$abslog"
      if [ "$rc" -eq 0 ] && [ "$HASGH" -eq 1 ]; then
        if git push -u origin "feat/$slug" >>"$abslog" 2>&1; then
          prurl="$(gh pr create --base "$BASE" --head "feat/$slug" --fill 2>>"$abslog")"
          [ -n "$prurl" ] && set_tdd_meta "$slug" "pr_url=$prurl"
        fi
      fi ) &
    pids+=("$!")
  done
  [ "${#pids[@]}" -gt 0 ] && wait "${pids[@]}" 2>/dev/null
  for tdd in "${TDDS[@]}"; do slug="$(basename "$tdd" .md)"; log="$LOGDIR/$slug.log"
    if [ -n "${SKIPPED[$slug]:-}" ]; then
      echo "- $slug — already built on ${SKIPPED[$slug]} (awaiting your merge); skipped" >>"$REPORT"; continue; fi
    # TDD 0011 / iter-3 MAJOR-6: branch-missing slugs already wrote their
    # own PAUSED line in the first loop; skip them here so we don't append
    # a duplicate UNKNOWN line (no subshell ran, so no PARSTATUS exists).
    [ -n "${BRANCH_MISSING[$slug]:-}" ] && continue
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
  # TDD 0027 §2 / FR-43: reclaim a worktree left registered by a prior unclean
  # exit before adding, so a forcible kill of the prior run doesn't block this one.
  _reclaim_stale_worktree "$WORKROOT" "$REPORT"
  if ! git worktree add --detach "$WORKROOT" "$BASE" >>"$REPORT" 2>&1; then
    { echo "FATAL: could not create isolated worktree at $WORKROOT (base '$BASE')."
      echo "Refusing to build in the live working tree; clear the error and re-run."; } | tee -a "$REPORT" >&2
    exit 1
  fi
  cd "$WORKROOT" || { echo "FATAL: cannot enter worktree $WORKROOT" | tee -a "$REPORT" >&2; exit 1; }
  install_deps "$LOGDIR/worktree-setup.log"

  if [ "$COMBINED" -eq 1 ]; then
    cb="$(combined_built_branch)"
    if [ -n "$cb" ]; then
      echo "- combined set already built on $cb (awaiting your merge); skipped. Use --rebuild to force." >>"$REPORT"
      for tdd in "${TDDS[@]}"; do
        slug="$(basename "$tdd" .md)"
        _terminal_state "$slug" skipped "" "combined set already built on $cb; awaiting your merge"
        set_tdd_meta  "$slug" "branch=$cb"
      done
    else
    git checkout -b "$CHANGE" "$BASE" >>"$REPORT" 2>&1 || git checkout "$CHANGE" >>"$REPORT" 2>&1
    blocked=0; paused_halt=0
    for tdd in "${TDDS[@]}"; do slug="$(basename "$tdd" .md)"; log="$LOGDIR/$slug.log"
      # Paused-halt: TDD 0011 / FR-41 — a paused TDD halts the run cleanly
      # but does NOT mark downstream as BLOCKED (which would lie about the
      # downstream's state). Just stop iterating; resume will pick up here.
      [ "$paused_halt" -eq 1 ] && break
      if [ "$blocked" -eq 1 ]; then
        echo "- $slug — BLOCKED (upstream TDD failed; not attempted)" >>"$REPORT"
        _terminal_state "$slug" blocked "" "upstream TDD failed; not attempted"
        continue
      fi
      # TDD 0011 / MA-3: write branch metadata BEFORE _resume_from runs.
      # _resume_from's divergence guard reads the fragment's `branch` field
      # to find the build branch's HEAD-at-pause sibling; if branch is
      # blank (the state_init default), the guard short-circuits and never
      # detects mid-resume divergence on the first resume.
      set_tdd_meta "$slug" "branch=$CHANGE"
      if [ "$RESUME" -eq 1 ]; then
        _resume_from "$slug"
        _rrc=$?
        if [ "$_rrc" -eq 3 ]; then
          # TDD 0011 / BLOCKER-2: refuse-to-resume — log the cause, halt
          # (combined mode follows the paused_halt semantics), do NOT
          # call gate_one which would overwrite paused→building.
          _cause="${RESUME_REFUSE_CAUSE:-$(_read_fragment_field "$STATE_DIR/$slug.json" paused_cause)}"; unset RESUME_REFUSE_CAUSE
          echo "- $slug — refuse-to-resume: ${_cause:-unknown} (no gate run)" >>"$REPORT"
          paused_halt=1
          continue
        fi
      fi
      pre="$(git rev-parse HEAD 2>/dev/null || echo "$BASE")"
      echo ">>> $slug"; st="$(gate_one "$tdd" "$pre" "$log")"; rc=$?
      echo "  $st"; echo "- $slug — $st (log: $log)" >>"$REPORT"
      case "$rc" in
        0) : ;;
        2) paused_halt=1 ;;
        *) blocked=1 ;;
      esac
    done
    # TDD 0011 / iter-3 BLOCKER-2: paused runs MUST NOT push or open a PR.
    # A paused TDD means the combined branch is half-built; pushing it
    # would expose an incomplete change to reviewers and (worse) tempt
    # someone to merge it. NFR-4 verdict honesty: paused ≠ done.
    if [ "${paused_halt:-0}" -eq 1 ]; then
      echo "Combined run paused (≥1 TDD halted at a recoverable gate). NOT pushing and NOT opening a PR; resume with /implement." >>"$REPORT"
    elif [ "$blocked" -eq 0 ] && [ "$HASGH" -eq 1 ]; then
      if git push -u origin "$CHANGE" >>"$REPORT" 2>&1; then
        prurl="$(gh pr create --base "$BASE" --head "$CHANGE" --fill 2>>"$REPORT")"
        if [ -n "$prurl" ]; then
          echo "Opened ONE combined PR: $prurl (not merged — merging is your gate)." >>"$REPORT"
          for tdd in "${TDDS[@]}"; do set_tdd_meta "$(basename "$tdd" .md)" "pr_url=$prurl"; done
        fi
      fi
    elif [ "$HASGH" -ne 1 ]; then echo "gh/remote not available: commits are on branch '$CHANGE'; open a PR manually." >>"$REPORT"; fi
    fi

  else
    # default: one stacked branch + PR per TDD (preserves dependency order while
    # keeping each feature a separately reviewable human gate).
    prev="$BASE"; blocked=0; paused_halt=0
    for tdd in "${TDDS[@]}"; do
      slug="$(basename "$tdd" .md)"; log="$LOGDIR/$slug.log"; branch="$CHANGE/$slug"
      # Paused-halt: TDD 0011 / FR-41 — stop cleanly without marking
      # downstream BLOCKED, since downstream simply hasn't been attempted.
      [ "$paused_halt" -eq 1 ] && break
      if [ "$blocked" -eq 1 ]; then
        echo "- $slug — BLOCKED (upstream TDD failed; not attempted)" >>"$REPORT"
        _terminal_state "$slug" blocked "" "upstream TDD failed; not attempted"
        continue
      fi
      built="$(built_branch "$tdd")"
      if [ -n "$built" ]; then
        echo "- $slug — already built on $built (awaiting your merge); skipped" >>"$REPORT"
        _terminal_state "$slug" skipped "" "already built on $built; awaiting your merge"
        set_tdd_meta  "$slug" "branch=$built"
        prev="$built"; continue; fi   # stack later TDDs on the already-built branch
      if ! git checkout -b "$branch" "$prev" >>"$log" 2>&1; then
        # On --resume, the branch already exists; check it out instead.
        if [ "$RESUME" -eq 1 ] && git checkout "$branch" >>"$log" 2>&1; then
          : # successfully re-entered the existing build branch
        elif [ "$RESUME" -eq 1 ]; then
          # TDD 0011 / BL-4: the build branch was deleted between pause and
          # resume. This is a documented paused_cause; route it to /implement-
          # status so the user can decide fresh-start vs investigate, rather
          # than misclassifying as a generic failure.
          echo "- $slug — PAUSED (branch $branch missing; resume-blocked-branch-missing)" >>"$REPORT"
          # TDD 0011 / iter-3 MAJOR-7: diagnose a swallowed update failure
          # (e.g. missing fragment) so status.sh's "wrong cause" doesn't
          # appear unexplained in the snapshot.
          _update_paused_cause "$slug" "resume-blocked-branch-missing" \
            || echo "warning: could not update paused_cause for $slug" >&2
          paused_halt=1; continue
        else
          echo "- $slug — FAIL (could not branch off $prev; log: $log)" >>"$REPORT"
          _terminal_state "$slug" failed "" "could not branch off $prev"
          blocked=1; continue
        fi
      fi
      set_tdd_meta "$slug" "branch=$branch"
      if [ "$RESUME" -eq 1 ]; then
        _resume_from "$slug"
        _rrc=$?
        if [ "$_rrc" -eq 3 ]; then
          # TDD 0011 / BLOCKER-2: refuse-to-resume halts cleanly. Log
          # the cause, mark paused_halt, do NOT call gate_one (which
          # would overwrite paused→building and lose the cause).
          _cause="${RESUME_REFUSE_CAUSE:-$(_read_fragment_field "$STATE_DIR/$slug.json" paused_cause)}"; unset RESUME_REFUSE_CAUSE
          echo "- $slug — refuse-to-resume: ${_cause:-unknown} (no gate run)" >>"$REPORT"
          paused_halt=1; continue
        fi
      fi
      pre="$(git rev-parse HEAD)"
      echo ">>> $slug (off $prev)"; st="$(gate_one "$tdd" "$pre" "$log")"; rc=$?; echo "  $st"
      case "$rc" in
        0)
          pr=""; pbase="${prev#origin/}"   # PR base is a branch name, never origin/<name>
          if [ "$HASGH" -eq 1 ]; then
            if git push -u origin "$branch" >>"$log" 2>&1; then
              prurl="$(gh pr create --base "$pbase" --head "$branch" --fill 2>>"$log")"
              if [ -n "$prurl" ]; then pr=", $prurl"; PR_PLAN+=("$prurl  (base $pbase)")
                set_tdd_meta "$slug" "pr_url=$prurl"
              else pr=", PR create failed (see log)"; fi
            else pr=", push failed (see log)"; fi
          fi
          echo "- $slug — $st (branch $branch$pr, log: $log)" >>"$REPORT"
          prev="$branch"
          ;;
        2)
          echo "- $slug — $st (branch $branch retained, PAUSED; resume with /implement)" >>"$REPORT"
          paused_halt=1
          ;;
        *)
          echo "- $slug — $st (branch $branch retained, NOT flipped; log: $log)" >>"$REPORT"; blocked=1
          ;;
      esac
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

# TDD 0030 §4 (gap 4): print the BLOCKERS.md pointer only when THIS run grew the
# ledger (line count rose above the run-start snapshot) — not whenever the file
# merely exists. A deleted/shrunk file reads as ≤ the snapshot → no growth → no
# phantom pointer (FR-64: name the actual next action, not a stale one).
if [ -f "$BLOCKERS_FILE" ]; then
  _blockers_lines_now="$(wc -l < "$BLOCKERS_FILE" 2>/dev/null | tr -d '[:space:]')"; _blockers_lines_now="${_blockers_lines_now:-0}"
  if [ "$_blockers_lines_now" -gt "$BLOCKERS_LINES_AT_START" ]; then
    { echo; echo "Design blockers were recorded in docs/tdd/BLOCKERS.md — run /tdd-author to revise the design, then re-run /implement."; } >>"$REPORT"
  fi
fi

# Mark the run-state record as terminal (FR-27) so a later status.sh on this
# logdir sees the rollup. If any TDD paused (TDD 0011 / FR-41), the run-level
# state is `paused` (resumable), not `done` — verdict honesty per NFR-4.
# Re-roll the fragments to see if any are paused; rerun parser is fragment-by-
# fragment because the loop-level `paused_halt` variable is scoped to the
# specific driver block.
#
# TDD 0030 §3 (gap 3): the requested paused/done below is only the BASE state.
# set_run_state runs the authoritative run-end fragment scan and upgrades it per
# precedence blocked > interrupted > paused > done — so a fragment left
# non-terminal (the runner died mid-gate) writes `interrupted`, never `done`,
# even though this site still passes "done". No duplicate scan is needed here.
_any_paused=0
if [ -d "$STATE_DIR" ]; then
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "run.json" ] && continue
    if grep -q '"status":"paused"' "$f" 2>/dev/null; then
      _any_paused=1; break
    fi
  done
fi
# TDD 0011 / iter-8 M-1: guard the terminal run-state writes. On disk-full
# at run-end, an unchecked failure would leave run.json at `running`
# forever; status.sh would show a stale in-progress run. The recovery
# path (--check-paused reads per-TDD fragments directly) is unaffected,
# but the display state is persistently wrong.
if [ "$_any_paused" -eq 1 ]; then
  set_run_state "paused" \
    || echo "warning: could not write final run.json (state=paused)" | tee -a "$REPORT" >&2
else
  set_run_state "done" \
    || echo "warning: could not write final run.json (state=done)" | tee -a "$REPORT" >&2
fi

echo; echo "=== Done. Report: $REPORT ==="; cat "$REPORT"

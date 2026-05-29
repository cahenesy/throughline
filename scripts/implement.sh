#!/usr/bin/env bash
# implement.sh — build TDDs unattended, behind real gates. Run detached
# (nohup/tmux) so it survives the session closing and keeps context clean.
#
# Every mode builds in a DEDICATED git worktree (sequential/combined share one;
# parallel uses one per feature), so the detached runner never mutates the
# working tree your interactive session is using. Build branches/commits persist
# in the shared repo after the worktree is removed.
#
#   ./scripts/implement.sh                    # every TDD merged to integration, stacked PRs
#   ./scripts/implement.sh docs/tdd/0003-x.md # just one TDD
#   ./scripts/implement.sh --parallel         # independent features, worktrees
#   ./scripts/implement.sh --combined         # one shared branch + ONE PR
#   ./scripts/implement.sh --rebuild          # rebuild even already-built TDDs
#
# What gets built: a TDD becomes buildable when its design PR MERGES — i.e. when
# it lands on the integration branch (origin's default / main / master; override
# with THROUGHLINE_INTEGRATION_BRANCH) at status draft|ready and not yet
# implemented. There is no manual `Status: ready` step; an un-merged draft on a
# design branch is not on integration, so the PR stays the gate.
#
# Re-run safety (the done-signal lives on the build branch, not your base, until
# you merge): a TDD already `implemented` on an existing un-merged branch is
# treated as done-but-awaiting-your-merge and SKIPPED, not rebuilt — so a re-run
# before you merge does not duplicate work or open duplicate PRs. A merged TDD is
# `implemented` on the integration branch and never queued; an abandoned/deleted
# branch rebuilds. --rebuild forces a fresh build regardless.
#
# Each TDD is built in a FRESH `claude -p` process (clean context per feature),
# pinned by default to the best model (opus). A build's own `BATCH_RESULT: OK` is
# NOT trusted as done. Before a TDD is flipped to `Status: implemented`, the
# runner enforces four independent gates:
#   1. test-first      — the build must show failing-test-first discipline: a
#                        dedicated `test(failing): ...` commit BEFORE the impl,
#                        unless it emits `TEST_FIRST: SKIPPED` for a no-new-
#                        behavior change.
#   2. ci-checks.sh       — re-runs tests + typecheck + lint mechanically (this is
#                        CI's job — running tests, not verification).
#   3. runtime-verify  — a SEPARATE `claude -p` process drives the BUILT artifact
#                        to the TDD's verification observation points and confirms
#                        the expected observations hold (PASS/SKIP), keeping
#                        PASS/FAIL/BLOCKED/SKIP distinct (NFR-4). Runs on a model
#                        the runner tiers based on the verification plan's
#                        complexity (mechanical observations → sonnet; nontrivial
#                        → the build model); override via
#                        `THROUGHLINE_RUNTIME_VERIFY_MODEL` (TDD 0013 / FR-52).
#                        The verification mechanism is the project's — delegated
#                        to `superpowers:verification-before-completion` /
#                        `/verify`, never a bundled harness (FR-26 / ADR 0004).
#   4. review          — a SEPARATE `claude -p` process on a DIFFERENT model
#                        (default sonnet vs an opus build) for genuine reviewer
#                        diversity (not a subagent of the author) that must end
#                        `REVIEW_RESULT: PASS`.
# Only after all pass does the runner flip the TDD and (if gh+remote) open a PR.
# It never merges — merging is your gate.
#
# Failure handling (the key safety property):
#   sequential → TDDs are stacked, so a failure HALTS the run and marks every
#                downstream TDD BLOCKED rather than building on a broken base.
#   parallel   → TDDs are independent; a failure affects only that feature.
# A build that ends `BATCH_RESULT: BLOCKED <reason>` is a DESIGN blocker: it is
# appended to docs/tdd/BLOCKERS.md and surfaced for /tdd-author to revise.
set -uo pipefail

# Sourced library modules (TDD 0015 / Theme D). state.sh holds the atomic
# run-state / per-TDD fragment I/O cluster. The source directive lives OUTSIDE
# the THROUGHLINE_SOURCE_ONLY guard below on purpose: the test suite sources
# this script (in SOURCE_ONLY mode) to call those helpers in isolation, so they
# must be defined on every source path, not only on a normal run. $SCRIPT_DIR is
# computed from BASH_SOURCE (not $0) so it resolves correctly when sourced.
# Fail fast on a missing/unreadable module: under `set -uo pipefail` (no -e), a
# bare `.` would return non-zero without aborting, leaving every state-tracking
# helper undefined and the whole run silently no-op. pwd -P normalizes symlinks
# so a wrapper-invoked SCRIPT_DIR still resolves to the real lib/ dir.
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

# THROUGHLINE_SOURCE_ONLY=1 lets the test suite `source` this script to call
# individual helpers in isolation (per the TDD 0011 sequencing plan): the
# helpers below are defined unconditionally, but every runtime side effect
# (arg parsing, lock acquisition, state.d/ init, the drivers, the trailing
# report) is bracketed by `if [ "${THROUGHLINE_SOURCE_ONLY:-0}" != "1" ]`.
# The guard is a no-op when launched normally (the env var is unset).

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
RVMTPL="$SDIR/verify-runtime-prompt.md"
for f in "$TMPL" "$RTMPL" "$RVMTPL" "$CI_CHECKS"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
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

# --- recoverable-cause classification (TDD 0011 / FR-41) ----------------------
# A small allowlist + exit-signal table that maps a gate's `claude -p` failure
# to one of: ratelimit, usage-limit, transient, fatal. Stdout determines
# routing; an unmatched stderr buffer falls through to `fatal` (NFR-4 honesty —
# ambiguity is never a false paused). Cases are matched left-to-right; first
# match wins. Pattern source lives inline (single call site; auditability
# matters more than reuse).
_recoverable_patterns() {
  # Echoes one "cause:regex" pair per line. The classifier walks this list in
  # order and applies grep -aiE; first hit wins. Patterns are
  # case-insensitive — claude / network errors arrive in mixed casing.
  cat <<'PATTERNS'
ratelimit:(ratelimit|rate_limit|429 |too[- ]many[- ]requests)
usage-limit:(usage[- ]limit|monthly[- ]limit[- ]reached|quota[- ]exceeded)
transient:(connection[- ]reset|timed[- ]out|EAI_AGAIN|temporary failure|503 |502 |504 |gateway timeout)
PATTERNS
}

# _classify_cause <log> <exit_status>  -> echoes one of
#     ratelimit | usage-limit | transient | fatal
# Inspects:
#   - the redirected log's tail (claude prints recoverable error messages
#     before a non-`end_turn` exit), and
#   - the wait-status signal — SIGTERM (143) is `transient` (host shutdown,
#     orderly kill); SIGKILL (137) is `fatal` (we cannot prove it was not a
#     runaway-process kill).
_classify_cause() {
  local log="$1" rc="$2" line pat cause
  # Signal-based decision first: a SIGTERM is a recoverable shutdown signal;
  # a SIGKILL is unrecoverable (out-of-memory, deliberate hard kill, …) and
  # must NEVER promote to paused (NFR-4).
  case "$rc" in
    137) printf 'fatal\n';     return 0 ;;
    143) printf 'transient\n'; return 0 ;;
  esac
  # Pattern-based stderr classification. Last ~2KB of log is the tail.
  if [ -s "$log" ]; then
    local tail
    tail="$(tail -c 4096 "$log" 2>/dev/null)"
    while IFS=':' read -r cause pat; do
      [ -z "$cause" ] && continue
      if printf '%s' "$tail" | grep -aiqE "$pat"; then
        printf '%s\n' "$cause"; return 0
      fi
    done < <(_recoverable_patterns)
  fi
  printf 'fatal\n'
}

# _enter_paused <slug> <cause> [<gate-name>] [<log>]
# Promote the in-flight TDD to status=paused (TDD 0011 / FR-41). Preserves the
# current stage so resume knows where to re-enter; captures the build branch's
# HEAD at pause time into branch_head_at_pause (used by _resume_from to detect
# divergence). The run-level fragment is re-rolled so the rollup reflects ≥1
# paused TDD. The caller exits cleanly so the detached process terminates
# without producing a FAIL verdict.
_enter_paused() {
  local slug="$1" cause="$2" gate_name="${3:-}" log="${4:-}"
  local f="${STATE_DIR:-}/$slug.json"
  # TDD 0011 / MA-2: do NOT silently swallow a missing state fragment.
  # Without the fragment we cannot record paused state, and a silent rc=0
  # would let the run mis-finalize as "done" while the TDD was actually
  # abandoned mid-gate (NFR-4: never silently lose state). Log and return
  # non-zero so _retry_in_gate can route the caller to FAIL instead of
  # paused.
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: _enter_paused cannot record pause for $slug: state fragment missing ($f)" >&2
    [ -n "$log" ] && printf '\nTHROUGHLINE_PAUSE_FAILED: slug=%s cause=%s gate=%s reason=state-fragment-missing ts=%d\n' \
      "$slug" "$cause" "${gate_name:-}" "$(date +%s)" >> "$log"
    return 1
  fi
  # Preserve everything from the existing fragment; only mutate status,
  # paused_cause, and branch_head_at_pause.
  local n qp path stage sta branch pr_url log_f note
  local gates_csv retries_json now branch_head_now
  n="$(sed -n 's/.*"n":\([0-9]*\).*/\1/p'            "$f" | head -1)"
  qp="$(sed -n 's/.*"queue_pos":\([0-9]*\).*/\1/p'   "$f" | head -1)"
  path="$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  if grep -q '"stage":null' "$f" 2>/dev/null; then stage=""
  else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
  sta="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
  branch="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  pr_url="$(sed -n 's/.*"pr_url":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  log_f="$(sed -n 's/.*"log":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  note="$(sed -n 's/.*"note":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"
  retries_json="$(_read_fragment_raw_array "$f" retries)"
  # Capture the build branch HEAD so resume can detect divergence (TDD 0011
  # failure mode: "Build branch HEAD differs at resume from what gates saw").
  branch_head_now="$(git rev-parse --verify HEAD 2>/dev/null || true)"
  now=$(date +%s)
  # TDD 0011 / iter-4 MAJOR-1: check the fragment-write outcome. If it
  # fails (disk full / perm), do NOT call _write_run_fragment paused —
  # otherwise run.json would say `paused` while the per-TDD fragment
  # still says `building`, and the run would exit cleanly with a
  # falsely consistent appearance. Propagate the failure so
  # _retry_in_gate returns FAIL (rc=1), not paused (rc=2).
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" paused "$stage" \
    "${sta:-$now}" "$now" "$branch" "$pr_url" "$log_f" "${note:-paused ($cause)}" \
    "$cause" "$gates_csv" "$retries_json" "$branch_head_now"; then
    echo "error: _enter_paused: could not write per-TDD fragment for $slug; not promoting to paused" >&2
    return 1
  fi
  # TDD 0011 / iter-4 MAJOR-2: warn on run.json write failure. The
  # rollup is re-derivable from per-TDD fragments so this is not
  # fatal, but a stale run.json.state misleads any direct consumer.
  _write_run_fragment paused || echo "warning: _enter_paused: run.json not updated to paused for $slug" >&2
  # Best-effort: append a marker to the per-TDD log so a future operator
  # has a clear timestamped paused entry above the resume timestamp.
  if [ -n "$log" ] && [ -w "$(dirname "$log")" ] 2>/dev/null; then
    printf '\nTHROUGHLINE_PAUSED: slug=%s cause=%s gate=%s ts=%d\n' \
      "$slug" "$cause" "${gate_name:-}" "$now" >> "$log"
  fi
}

# _retry_in_gate <gate-fn> <gate-name> <slug> <log> <args...>
# (TDD 0011 / FR-42) — wrap one of the LLM gate calls with bounded
# transient-error retry. Algorithm:
#   for attempt in 1..MAX_RETRIES:
#     run gate-fn "$@"
#     if rc==0:           return 0 (success; gate may proceed)
#     classify the log + rc:
#       cause=fatal → return 1 (fail; do NOT retry; gate halts)
#       cause=ratelimit/usage-limit/transient → record retry, sleep backoff
#   exhausted → _enter_paused; return 2 (caller maps rc=2 to "paused, not
#   flipped", distinct from rc=1 "failed")
# Env knobs: THROUGHLINE_GATE_RETRIES (default 3), THROUGHLINE_GATE_BACKOFF_BASE
# (default 30s). Backoff schedule: BASE * 4^(attempt-1) ⇒ 30, 120, 480s.
_retry_in_gate() {
  local gate_fn="$1" gate_name="$2" slug="$3" log="$4"; shift 4
  local max_retries="${THROUGHLINE_GATE_RETRIES:-3}"
  local backoff_base="${THROUGHLINE_GATE_BACKOFF_BASE:-30}"
  # TDD 0011 / iter-3 MAJOR-3: validate env-var inputs are purely numeric
  # BEFORE they reach bash arithmetic. `$(( $max_retries ))` with an
  # attacker-controlled non-numeric value triggers bash's well-known
  # arithmetic-injection vector (the inner string is evaluated as a bash
  # expression, allowing `a[$(cmd)]`-style command substitution). Fall
  # back to defaults on invalid input + warn so misconfiguration is
  # visible.
  case "$max_retries" in
    ''|*[!0-9]*) echo "warning: THROUGHLINE_GATE_RETRIES='$max_retries' not numeric; falling back to 3" >&2; max_retries=3 ;;
    0) echo "warning: THROUGHLINE_GATE_RETRIES=0 not allowed (would cause immediate paused-with-no-attempt); normalizing to 1" >&2; max_retries=1 ;;
  esac
  # TDD 0011 / iter-5 MAJOR-5: cap the upper bound. backoff_base * 4^(n-1)
  # overflows signed 64-bit around attempt=30, producing negative values
  # that skip the sleep guard. Even before overflow, attempt~20 produces
  # ~8e6 seconds (months) of sleep — unhelpful. 10 retries is a safe upper
  # bound (final backoff is base*4^9 ≈ 70h with default base=30).
  if [ "$max_retries" -gt 10 ] 2>/dev/null; then
    echo "warning: THROUGHLINE_GATE_RETRIES=$max_retries exceeds cap of 10; capping (4^attempt overflows / huge sleeps)" >&2
    max_retries=10
  fi
  case "$backoff_base" in
    ''|*[!0-9]*) echo "warning: THROUGHLINE_GATE_BACKOFF_BASE='$backoff_base' not numeric; falling back to 30" >&2; backoff_base=30 ;;
  esac
  # TDD 0011 / iter-9 SEC-2: cap the backoff base. Without an upper bound,
  # `BACKOFF_BASE=86400` would produce 86400 * 4^2 = ~16-day sleeps on the
  # third attempt, holding the single-run lock and blocking the repo for
  # days. 3600s (1h) base is plenty for any legitimate rate-limit retry.
  if [ "$backoff_base" -gt 3600 ] 2>/dev/null; then
    echo "warning: THROUGHLINE_GATE_BACKOFF_BASE=$backoff_base exceeds cap of 3600s; capping (would hold the single-run lock for many hours)" >&2
    backoff_base=3600
  fi
  local attempt cause rc backoff
  for (( attempt=1; attempt<=max_retries; attempt++ )); do
    "$gate_fn" "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
    cause="$(_classify_cause "$log" "$rc")"
    if [ "$cause" = "fatal" ]; then return 1; fi
    # TDD 0011 / iter-3 MAJOR-1: backoff schedule MUST match the TDD's
    # documented sequence BASE * 4^(attempt-1) on EVERY failed attempt,
    # including the final one before promoting to paused. Previously the
    # last sleep was forced to 0, which meant a rate-limit clearing in
    # under 8 minutes (after the third attempt) produced a spurious
    # paused state. The audit record now reflects the actual upcoming
    # sleep — including the final one — for honesty.
    backoff=$(( backoff_base * (4 ** (attempt - 1)) ))
    # TDD 0011 / iter-9 M-1: on the FINAL attempt the sleep is wasted —
    # no further gate call follows it. Skip it to avoid up to 480s of
    # gratuitous wall-clock delay before writing the paused fragment.
    # Audit the planned backoff still (so the retries[] entry matches the
    # schedule), but use 0 in the actual sleep guard.
    # TDD 0011 / iter-9 SF-1: surface _append_retry failures (otherwise
    # disk-full would silently drop the retry record and break iter-6
    # MA-1's retries-proxy guard).
    _append_retry "$slug" "$gate_name" "$attempt" "$backoff" \
      || echo "warning: _retry_in_gate: retry audit write failed for $slug (attempt $attempt)" >&2
    if [ "$attempt" -lt "$max_retries" ] && [ "$backoff" -gt 0 ]; then
      sleep "$backoff"
    fi
    if [ "$attempt" -ge "$max_retries" ]; then
      # TDD 0011 / MA-2: propagate _enter_paused failure. If we can't
      # record paused state, return FAIL (1) instead of paused (2) so
      # the run-level fragment doesn't roll up to a false `done`.
      if ! _enter_paused "$slug" "$cause" "$gate_name" "$log"; then
        return 1
      fi
      return 2
    fi
  done
  # Defensive: loop should always return inside; if we get here, treat as
  # paused (NFR-4 — never silently lose state). Reached when max_retries
  # is 0 (the loop body never runs); `cause` is unset in that case so
  # fall back to a literal label for the audit.
  if ! _enter_paused "$slug" "${cause:-transient}" "$gate_name" "$log"; then
    return 1
  fi
  return 2
}

# _append_retry <slug> <gate-name> <count> <backoff_s>
# Append one retry record to the per-TDD fragment's retries[] array. Used
# only by _retry_in_gate. Reads the existing fragment, splices a new entry
# into retries[], and rewrites via _write_tdd_fragment so every other field
# is round-tripped unchanged.
_append_retry() {
  local slug="$1" gate_name="$2" count="$3" backoff="$4"
  local f="${STATE_DIR:-}/$slug.json"
  [ -n "$STATE_DIR" ] && [ -f "$f" ] || return 0
  local n qp path status stage sta upd branch pr_url log_f note
  local paused_cause gates_csv retries_json branch_head
  n="$(sed -n 's/.*"n":\([0-9]*\).*/\1/p'            "$f" | head -1)"
  qp="$(sed -n 's/.*"queue_pos":\([0-9]*\).*/\1/p'   "$f" | head -1)"
  path="$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  status="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  if grep -q '"stage":null' "$f" 2>/dev/null; then stage=""
  else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
  sta="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
  upd="$(sed -n 's/.*"updated_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
  branch="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  pr_url="$(sed -n 's/.*"pr_url":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  log_f="$(sed -n 's/.*"log":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  note="$(sed -n 's/.*"note":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  paused_cause="$(_read_fragment_field "$f" paused_cause)"
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"
  retries_json="$(_read_fragment_raw_array "$f" retries)"
  branch_head="$(_read_fragment_field "$f" branch_head_at_pause)"
  local entry new
  entry="{\"gate\":\"$(json_escape "$gate_name")\",\"count\":$count,\"backoff_s\":$backoff}"
  # TDD 0011 / BL-5: validate that retries_json is well-formed before
  # splicing. A truncated array from a torn read (despite tmp+mv atomicity,
  # a reader can race against a partial write window of a long string field
  # somewhere else in the fragment if the runner is ever extended) would
  # otherwise produce invalid JSON: `${retries_json%]}` strips nothing,
  # and the splice yields `[…,{…}]` with no inner closing bracket. The
  # next read returns empty, retries[] silently resets, and the audit trail
  # is lost. Refuse to splice into a non-`]`-terminated array; warn and
  # restart the trail. (The trail is recorded twice in practice: in the
  # log via _retry_in_gate's printf, and in the fragment; the warning
  # ensures the discontinuity is visible.)
  if [ -z "$retries_json" ] || [ "$retries_json" = "[]" ]; then
    new="[$entry]"
  elif [ "${retries_json: -1}" != ']' ]; then
    echo "warning: retries[] for $slug was malformed (no closing ']'); resetting audit trail" >&2
    new="[$entry]"
  else
    # Splice before the closing bracket. The retries entries are flat
    # objects with no nested brackets, so this is unambiguous.
    new="${retries_json%]},$entry]"
  fi
  # TDD 0011 / iter-5 MAJOR-1: propagate write failures so a failed retry-
  # audit append doesn't silently disappear into a stale fragment.
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$(date +%s)}" "$(date +%s)" "$branch" "$pr_url" "$log_f" "$note" \
    "$paused_cause" "$gates_csv" "$new" "$branch_head"; then
    echo "error: _append_retry: could not write $slug fragment (retry audit lost)" >&2
    return 1
  fi
}

# --- per-TDD primitives (cwd = the repo or worktree they run in) ---------------
# record_session_pointer: `claude -p` redirects only its FINAL assistant message
# (the `end_turn` text) to stdout. If a run ends without `end_turn` — turn cap,
# external kill, ratelimit, or the build accidentally pkill'ing its own parent —
# the redirected log is near-empty, and the runner's `FAIL (no BATCH_RESULT;
# see log)` is correct but useless for triage. The full transcript still exists
# at ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl. This helper finds it (newest
# .jsonl in the cwd-encoded project dir, modified at or after the call started)
# and appends a `THROUGHLINE_SESSION:` pointer plus the last few tool calls to
# the log, so a FAIL like that is diagnosable from the log itself.
record_session_pointer() {  # <log> <start-epoch>
  local log="$1" start="$2" enc proj sess
  enc="$(printf '%s' "$PWD" | sed 's|/|-|g')"
  proj="$HOME/.claude/projects/$enc"
  [ -d "$proj" ] || return 0
  sess="$(find "$proj" -maxdepth 1 -name "*.jsonl" -newermt "@$start" -printf '%T@\t%p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -f2)"
  [ -n "$sess" ] || return 0
  {
    echo
    echo "THROUGHLINE_SESSION: $sess"
    if command -v jq >/dev/null 2>&1; then
      echo "Last assistant tool calls (newest last; up to 5):"
      jq -r 'select(.type=="assistant") | .message.content // [] | .[] | select(.type=="tool_use") | "  \(.name)\t\((.input|tostring)[:140])"' \
        "$sess" 2>/dev/null | tail -5
    fi
  } >>"$log"
}
build_one() {  # <tdd> <log>
  local tdd="$1" log="$2" prompt; prompt="$(sed "s#{{TDD}}#${tdd}#g" "$TMPL")"
  local args=(-p "$prompt" --permission-mode auto); [ -n "$MODEL" ] && args+=(--model "$MODEL")
  local start _rc; start=$(date +%s); _rc=0
  claude "${args[@]}" >>"$log" 2>&1; _rc=$?
  record_session_pointer "$log" "$start"
  return "$_rc"   # TDD 0011 / BL-2: preserve claude's exit code (incl. signals like 143)
}
review_one() {  # <tdd> <base-ref> <log>
  local tdd="$1" base="$2" log="$3" prompt
  prompt="$(sed -e "s#{{TDD}}#${tdd}#g" -e "s#{{BASE}}#${base}#g" "$RTMPL")"
  local args=(-p "$prompt" --permission-mode auto); [ -n "$REVIEW_MODEL" ] && args+=(--model "$REVIEW_MODEL")
  local start _rc; start=$(date +%s); _rc=0
  claude "${args[@]}" >>"$log" 2>&1; _rc=$?
  record_session_pointer "$log" "$start"
  return "$_rc"   # TDD 0011 / BL-2: preserve claude's exit code
}
# Runtime-verify gate (FR-25 / FR-26 / ADR 0004): drives the BUILT artifact to
# the TDD's verification observation points in a FRESH `claude -p` process — so
# it is independent of the build's self-report regardless of model. Model is
# tiered by the verification plan's complexity (TDD 0013 / FR-52): mechanical
# observations (CLI exit code, log line grep, file presence, HTTP status code,
# etc.) run on `sonnet`; plans needing browser/UI driving, multi-step interactive
# flows, or judgment about ambiguous output run on the build `$MODEL`. The env
# `THROUGHLINE_RUNTIME_VERIFY_MODEL` pins a model unconditionally (matching the
# `--review-model` / `THROUGHLINE_REVIEW_MODEL` escape hatch). If the classifier
# helper is missing on disk (e.g. partial install), fall back to `$MODEL` and
# note the missing classifier in the gate log — no correctness regression, just
# no token saving for that run. cwd is the build worktree with deps installed
# by `install_deps`. The {{BASE}} substitution scopes the diff so the verifier
# can SEE which change to focus its observation on; it orients the verifier, it
# does not gate on the diff. The verdict is parsed from the transcript
# (`VERIFY_RUNTIME: ...`), exactly as build's `BATCH_RESULT:` and review's
# `REVIEW_RESULT:` already are.
verify_runtime_one() {  # <tdd> <base-ref> <log>
  local tdd="$1" base="$2" log="$3" prompt cls vm classifier note=""
  prompt="$(sed -e "s#{{TDD}}#${tdd}#g" -e "s#{{BASE}}#${base}#g" "$RVMTPL")"
  # Model tiering (FR-52). The env override always wins.
  vm="${THROUGHLINE_RUNTIME_VERIFY_MODEL:-}"
  classifier="${SDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/lib/plan-classifier.sh"
  # M3 (review pass): capture the classifier's exit code and attach a
  # distinguishing note when it fails. The previous form silently fell
  # through to plan=nontrivial on classifier error — the gate log line
  # was IDENTICAL to a genuine nontrivial classification, so a triage
  # could not tell a crashed classifier from a deliberate choice. The
  # `(classifier failed, rc=N)` annotation preserves NFR-4 honesty.
  # MAJ-1 (review pass 3): the classifier's stderr is redirected to the
  # gate log (`2>>"$log"`) rather than silenced. With BL-1/BL-2 fixed so
  # the classifier itself surfaces awk crashes as rc≠0 + stderr, the log
  # capture preserves the only externally-observable signal of what went
  # wrong for triage — `2>/dev/null` would have erased it.
  #
  # MAJ-2 (review pass 3): the env-pinned branch now applies the same
  # `case` guard for unexpected classifier output as the unpinned branch,
  # sanitizing any non-{mechanical, nontrivial} value to `nontrivial`
  # with a distinguishing note. Without this guard a misbehaving
  # classifier could propagate arbitrary text into the `plan=<x>` log
  # line, polluting the FR-36 observability surface.
  local cls_rc
  if [ -z "$vm" ]; then
    if [ -f "$classifier" ]; then
      # shellcheck source=/dev/null
      . "$classifier"
      cls="$(tl_classify_plan "$tdd" 2>>"$log")"; cls_rc=$?
      if [ "$cls_rc" -ne 0 ] || [ -z "$cls" ]; then
        vm="$MODEL"; cls="nontrivial"; note=" (classifier failed, rc=$cls_rc)"
      else
        case "$cls" in
          mechanical) vm="sonnet" ;;
          nontrivial) vm="$MODEL" ;;
          *)          vm="$MODEL"; note=" (classifier returned unexpected '$cls', defaulted nontrivial)"; cls="nontrivial" ;;
        esac
      fi
    else
      vm="$MODEL"; cls="nontrivial"; note=" (classifier missing)"
    fi
  else
    # Env-pinned: still classify for the observability line (so triage knows
    # what the heuristic *would* have picked), but the pin wins.
    if [ -f "$classifier" ]; then
      # shellcheck source=/dev/null
      . "$classifier"
      cls="$(tl_classify_plan "$tdd" 2>>"$log")"; cls_rc=$?
      if [ "$cls_rc" -ne 0 ] || [ -z "$cls" ]; then
        cls="nontrivial"; note=" (classifier failed, rc=$cls_rc)"
      else
        case "$cls" in
          mechanical|nontrivial) : ;;  # accept the heuristic's choice for the log line
          *)
            note=" (classifier returned unexpected '$cls', defaulted nontrivial)"
            cls="nontrivial"
            ;;
        esac
      fi
    else
      cls="nontrivial"; note=" (classifier missing)"
    fi
  fi
  printf 'runtime-verify model=%s (plan=%s)%s\n' "$vm" "$cls" "$note" >> "$log"
  local args=(-p "$prompt" --permission-mode auto)
  [ -n "$vm" ] && args+=(--model "$vm")
  local start _rc; start=$(date +%s); _rc=0
  claude "${args[@]}" >>"$log" 2>&1; _rc=$?
  record_session_pointer "$log" "$start"
  return "$_rc"   # TDD 0011 / BL-2: preserve claude's exit code
}
build_status()          { grep -aoE 'BATCH_RESULT: (OK|FAIL.*|BLOCKED.*)' "$1" 2>/dev/null | tail -1; }
review_status()         { grep -aoE 'REVIEW_RESULT: (PASS|BLOCK.*)' "$1" 2>/dev/null | tail -1; }
verify_runtime_status() { grep -aoE 'VERIFY_RUNTIME: (PASS|FAIL.*|BLOCKED.*|SKIP.*)' "$1" 2>/dev/null | tail -1; }
run_ci_checks()    { bash "$CI_CHECKS" >>"$1" 2>&1; }
# test-first gate: mechanical, git-history only. The build must show failing-test-
# first discipline — a dedicated `test(failing): ...` commit BEFORE the impl —
# unless it emits `TEST_FIRST: SKIPPED` for a genuine no-new-behavior change. The
# independent review gate judges test QUALITY; this just proves the order existed.
test_first_ok() {  # <base-ref> <log>
  [ "${THROUGHLINE_REQUIRE_TEST_FIRST:-1}" = "1" ] || return 0
  local base="$1" log="$2"
  grep -aqE 'TEST_FIRST:[[:space:]]*SKIPPED' "$log" && return 0
  git log --format='%s' "$base..HEAD" 2>/dev/null | grep -qiE '^test\(failing\)' && return 0
  return 1
}
flip_status() {  # <tdd> <log>
  local tdd="$1" log="$2"
  sed -i.bak -E 's/^Status:[[:space:]]*(draft|ready)/Status: implemented/' "$tdd" && rm -f "$tdd.bak"
  git add "$tdd" >>"$log" 2>&1
  git commit -m "mark $(basename "$tdd" .md) implemented (verified + reviewed)" >>"$log" 2>&1
}
record_blocker() {  # <tdd> <reason>  -> append to the main repo's blocker ledger
  local tdd="$1" reason="$2" bf="${MAINREPO:-$PWD}/docs/tdd/BLOCKERS.md"
  mkdir -p "$(dirname "$bf")"
  [ -f "$bf" ] || printf '# Implementation blockers\n\n> Design-level blockers raised by /implement. Resolve via /tdd-author, then delete the entry.\n\n' > "$bf"
  printf -- '- [ ] **%s** (%s): %s\n' "$(basename "$tdd")" "$(date +%Y-%m-%d)" "$reason" >> "$bf"
}

# install_deps: a fresh worktree does NOT carry gitignored, uncommitted state —
# most importantly node_modules — so a JS/TS build can't run its tests/typecheck
# and ci-checks.sh fails until deps are installed. Install them once per worktree,
# before building, using the project's package manager. No-ops for non-JS repos
# (and other ecosystems that fetch on build, e.g. cargo/go); skip with
# THROUGHLINE_SKIP_DEPS=1. cwd must be the worktree.
install_deps() {  # <log>
  [ "${THROUGHLINE_SKIP_DEPS:-0}" = "1" ] && return 0
  [ -f package.json ] || return 0
  local log="$1" pm cmd
  if   [ -f pnpm-lock.yaml ];   then pm=pnpm; cmd="pnpm install --frozen-lockfile"
  elif [ -f yarn.lock ];        then pm=yarn; cmd="yarn install --immutable"
  elif [ -f bun.lockb ] || [ -f bun.lock ]; then pm=bun; cmd="bun install --frozen-lockfile"
  elif [ -f package-lock.json ]; then pm=npm; cmd="npm ci"
  else pm=npm; cmd="npm install"; fi
  if ! command -v "$pm" >/dev/null 2>&1; then
    echo "install_deps: $pm not found on PATH; skipping (build will likely fail at verify)" >>"$log"; return 0
  fi
  echo "install_deps: $cmd" >>"$log"
  # Fall back to a plain install if the locked/frozen form fails (e.g. a lockfile
  # that's out of sync) so a build isn't blocked by a lock mismatch.
  sh -c "$cmd" >>"$log" 2>&1 || sh -c "$pm install" >>"$log" 2>&1 \
    || echo "install_deps: dependency install failed; build may fail at verify" >>"$log"
}

# gate_one: build -> classify -> test-first -> ci-checks.sh -> runtime-verify ->
# independent review -> flip. Echoes a one-line status; returns 0 ONLY when the
# TDD was flipped to implemented. Every transition publishes status/stage to the
# per-TDD fragment (FR-27) so /implement-status sees the live state.
#
# Status enum: pending → building → verifying → reviewing → done | failed |
# blocked | skipped. Stage enum: build / test-first / verify / verify-runtime /
# review / flip / null. Runtime-verify BLOCKED maps to status=blocked (distinct
# from FAIL per NFR-4) but is NOT a design blocker — only build BATCH_RESULT:
# BLOCKED appends to BLOCKERS.md (see record_blocker).
# --- gate-call wrappers used by _retry_in_gate (TDD 0011 / FR-42) ------------
# _retry_in_gate calls a gate-fn that returns 0 on success, non-zero on retry-
# eligible failure. The raw build_one / verify_runtime_one / review_one print
# to the log and don't return a useful exit code; these adapters parse the
# log's verdict line and convert it.
# TDD 0011 / BL-2: forward claude's actual exit code so _retry_in_gate's
# _classify_cause can see signals (143 SIGTERM → transient, 137 SIGKILL →
# fatal). The verdict in the log is the success signal; on non-zero exit
# the raw rc is what classifies the cause. Order: if exit was non-zero,
# return it (preserves signal); else if verdict is good, return 0; else
# return 1 (generic non-signal failure).
_build_one_gated() {  # <tdd> <log>
  local tdd="$1" log="$2" bs _rc
  build_one "$tdd" "$log"; _rc=$?
  [ "$_rc" -ne 0 ] && return "$_rc"
  bs="$(build_status "$log")"
  case "$bs" in *OK*) return 0 ;; esac
  return 1
}
_verify_runtime_one_gated() {  # <tdd> <rbase> <log>
  local tdd="$1" rbase="$2" log="$3" rvs _rc
  verify_runtime_one "$tdd" "$rbase" "$log"; _rc=$?
  [ "$_rc" -ne 0 ] && return "$_rc"
  rvs="$(verify_runtime_status "$log")"
  case "$rvs" in *PASS*|*SKIP*) return 0 ;; esac
  return 1
}
_review_one_gated() {  # <tdd> <rbase> <log>
  local tdd="$1" rbase="$2" log="$3" rs _rc
  review_one "$tdd" "$rbase" "$log"; _rc=$?
  [ "$_rc" -ne 0 ] && return "$_rc"
  rs="$(review_status "$log")"
  case "$rs" in *PASS*) return 0 ;; esac
  return 1
}

# _resume_gates_var <slug> — convert a slug to a shell-safe variable name
# (RESUME_GATES_DONE_<slug-with-non-alnum-replaced>). Used to set a per-TDD
# resume hint without conflicting with shell variable name rules.
_resume_gates_var() {
  printf 'RESUME_GATES_DONE_%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_')"
}

# _update_paused_cause <slug> <new-cause>
# Mutate just the paused_cause field of a paused fragment. Used by
# _resume_from to mark resume-blocked fragments. All other fields are
# round-tripped via _write_tdd_fragment.
_update_paused_cause() {
  local slug="$1" new_cause="$2"
  local f="${STATE_DIR:-}/$slug.json"
  # TDD 0011 / MAJOR-6: fail loudly on missing fragment instead of silent
  # return 0. _update_paused_cause is called only from _resume_from's
  # refuse-to-resume paths where the fragment MUST exist — silently
  # swallowing the absence would let the refusal vanish and the driver
  # fall through to a silent rebuild (mirrors the _enter_paused MA-2 fix).
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: _update_paused_cause cannot record cause for $slug: state fragment missing ($f)" >&2
    return 1
  fi
  local n qp path status stage sta branch pr_url log_f note
  local gates_csv retries_json branch_head
  n="$(sed -n 's/.*"n":\([0-9]*\).*/\1/p'            "$f" | head -1)"
  qp="$(sed -n 's/.*"queue_pos":\([0-9]*\).*/\1/p'   "$f" | head -1)"
  path="$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  status="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  if grep -q '"stage":null' "$f" 2>/dev/null; then stage=""
  else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
  sta="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
  branch="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  pr_url="$(sed -n 's/.*"pr_url":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  log_f="$(sed -n 's/.*"log":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  note="$(sed -n 's/.*"note":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"
  retries_json="$(_read_fragment_raw_array "$f" retries)"
  branch_head="$(_read_fragment_field "$f" branch_head_at_pause)"
  # TDD 0011 / iter-5 MAJOR-1: propagate write failures.
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$(date +%s)}" "$(date +%s)" "$branch" "$pr_url" "$log_f" "$note" \
    "$new_cause" "$gates_csv" "$retries_json" "$branch_head"; then
    echo "error: _update_paused_cause: could not write $slug fragment (cause=$new_cause)" >&2
    return 1
  fi
}

# _resume_from <slug> (TDD 0011 / FR-40)
# Validate that <slug>'s paused fragment is resumable; if so, set the
# RESUME_GATES_DONE_<slug> variable listing the gates already completed
# (build / test-first / verify / verify-runtime / review). Two sources of
# truth, with the documented trust hierarchy:
#   A — the build branch's commit history (authoritative for gate 1: a
#       `test(failing):` commit must exist).
#   B — the per-TDD fragment's gates_completed array (authoritative for
#       gates 2-4).
# On a refuse-to-resume condition, updates paused_cause to one of:
#   resume-blocked-build-state-missing
#   resume-blocked-branch-missing
#   resume-blocked-branch-divergence
# and leaves the RESUME_GATES_DONE_<slug> variable unset.
_resume_from() {
  local slug="$1" f var
  f="${STATE_DIR:-}/$slug.json"
  # TDD 0011 / iter-4 MAJOR-4: under --resume the fragment MUST exist
  # (state_init's queue-freeze already filtered TDDs without fragments).
  # Returning 0 (success) here would let callers treat the missing
  # fragment as "not paused, proceed normally" — gate_one's own MA-4
  # guard then sets blocked=1, marking ALL downstream sequential TDDs
  # as BLOCKED instead of pausing this one. Refuse with rc=3 so the
  # driver halts cleanly. Outside --resume the helper is harmless to
  # call defensively, so keep the silent-0 path for that case.
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    if [ "${RESUME:-0}" -eq 1 ]; then
      echo "error: _resume_from $slug: state fragment missing under --resume; refusing to proceed" >&2
      return 3
    fi
    return 0
  fi
  var="$(_resume_gates_var "$slug")"
  local fragment_status
  fragment_status="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  [ "$fragment_status" = "paused" ] || return 0

  # TDD 0011 / MAJOR-5: guard $INTEGRATION — under THROUGHLINE_SOURCE_ONLY=1
  # (the test harness) the runner's INTEGRATION assignment is skipped, and
  # an unguarded `"$INTEGRATION"` aborts the test process under `set -u`.
  local integration="${INTEGRATION:-}"
  local branch branch_head_at_pause gates_csv
  branch="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  branch_head_at_pause="$(_read_fragment_field "$f" branch_head_at_pause)"
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"

  # Source A — gate-1 completion is signaled by a `test(failing):` commit
  # in the branch history. TDD 0011 / MA-1: scope the scan to commits
  # introduced by THIS build branch via the merge-base with the integration
  # branch. Scanning HEAD's full ancestry (the previous behavior) would
  # falsely match a `test(failing):` commit from any prior TDD on the same
  # long-lived integration branch.
  #
  # TDD 0011 / iter-4 BLOCKER-1: in COMBINED mode the build branch is
  # SHARED across all TDDs in $CHANGE — another TDD's `test(failing):`
  # commit lives in the ancestry of this paused TDD, so the test-first
  # scan would falsely declare gate 1 done. Instead of trying to scope
  # the scan (no slug-keyed marker exists in the commit subjects),
  # SKIP the gate-1 resume optimization entirely for combined mode:
  # treat gate 1 as NOT-done so gate_one re-runs it. The done_list
  # below is intentionally constructed WITHOUT 'build' for combined,
  # so gate_one's `_is_done build` returns false and gate 1 executes.
  # Re-running gate 1 is safe in combined mode: build_one is idempotent
  # at the prompt level (the LLM sees the current branch state); if it
  # already committed the change in the prior attempt, the new attempt
  # will see it and either no-op or extend it.
  local has_test_first=0 base_ref="" ref_to_scan combined_resume=0
  if [ "${COMBINED:-0}" = "1" ]; then
    combined_resume=1
    # Skip the entire test-first scan branch; jump to divergence check.
  else
    # Source A's scan target: TDD 0011 / BLOCKER-1+MAJOR-10 — the divergence
    # guard below now resolves the build branch via refs/heads/$branch (not
    # HEAD), so we know exactly which ref we're scanning regardless of the
    # process's CWD. The test-first scan must use the same ref.
    ref_to_scan="HEAD"
    if [ -n "$branch" ] && git rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
      ref_to_scan="refs/heads/$branch"
    fi
    if [ -n "$integration" ]; then
      base_ref="$(git merge-base "$ref_to_scan" "$integration" 2>/dev/null \
                   || git merge-base "$ref_to_scan" "origin/$integration" 2>/dev/null \
                   || true)"
    fi
    if [ -n "$base_ref" ]; then
      if git log --format='%s' "$base_ref..$ref_to_scan" 2>/dev/null | grep -qiE '^test\(failing\)'; then
        has_test_first=1
      fi
    else
      # TDD 0011 / iter-4 MAJOR-5: no merge-base means we cannot
      # distinguish THIS TDD's `test(failing):` commit from a prior
      # stacked TDD's. Per NFR-4 "never silently claim a gate complete
      # on degraded evidence", REFUSE to resume rather than emit an
      # affirmative based on the wider ancestry scan (the prior
      # warning-and-pass behavior).
      echo "warning: _resume_from $slug — no merge-base with ${integration:-<unset>}; refusing to claim gate 1 done on degraded evidence" >&2
      # TDD 0011 / iter-6 MAJOR-4: do NOT `|| true` here — that would
      # swallow a fragment-write failure and let the driver's report
      # read back a stale paused_cause (e.g. "ratelimit") instead of
      # the resume-blocked diagnostic.
      # TDD 0011 / iter-10 M-3: also expose the cause via a global so
      # drivers don't have to re-read it from the fragment (and read a
      # stale value if the write failed).
      RESUME_REFUSE_CAUSE="resume-blocked-build-state-missing"
      _update_paused_cause "$slug" "$RESUME_REFUSE_CAUSE" \
        || echo "warning: _resume_from $slug: could not update paused_cause (status.sh may show stale cause)" >&2
      return 3
    fi
  fi
  # In combined mode we deliberately bypass the has_test_first check —
  # gate 1 will re-run via the empty done_list below.
  if [ "$combined_resume" -eq 0 ] && [ "$has_test_first" -ne 1 ]; then
    RESUME_REFUSE_CAUSE="resume-blocked-build-state-missing"
    _update_paused_cause "$slug" "$RESUME_REFUSE_CAUSE" \
      || echo "warning: _resume_from $slug: could not update paused_cause (status.sh may show stale cause)" >&2
    return 3
  fi

  # Divergence: if the fragment recorded a HEAD SHA at pause time and the
  # current branch ref differs, the branch was rewritten while paused.
  # TDD 0011 / BLOCKER-1+MAJOR-10: resolve via refs/heads/$branch (not the
  # process's HEAD) so the check is correct regardless of CWD. This is
  # what fixes parallel-mode resume — the previous HEAD-based check saw
  # the main repo's HEAD when called outside the subshell.
  if [ -n "$branch_head_at_pause" ] && [ -n "$branch" ]; then
    local current_head
    current_head="$(git rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)"
    if [ -n "$current_head" ] && [ "$current_head" != "$branch_head_at_pause" ]; then
      # iter-10 M-3: expose cause via global for drivers.
      RESUME_REFUSE_CAUSE="resume-blocked-branch-divergence"
      _update_paused_cause "$slug" "$RESUME_REFUSE_CAUSE" \
        || echo "warning: _resume_from $slug: could not update paused_cause (status.sh may show stale cause)" >&2
      return 3   # see BLOCKER-2
    fi
  fi

  # All checks pass: build the done-list.
  # - Non-combined: gate 1 (build) is implicit when the test(failing):
  #   commit is present.
  # - Combined (iter-4 BLOCKER-1): explicitly omit 'build' so gate_one
  #   re-runs gate 1 against the shared branch (idempotent at the
  #   prompt level). Gates 2-4 come from gates_completed in both modes.
  local done_list
  if [ "${combined_resume:-0}" -eq 1 ]; then
    done_list=""
    if [ -n "$gates_csv" ]; then done_list="$gates_csv"; fi
  else
    done_list="build"
    if [ -n "$gates_csv" ]; then done_list="${done_list},${gates_csv}"; fi
  fi
  printf -v "$var" '%s' "$done_list"
  export "$var"
}

# gate_one — build → test-first → ci-checks.sh → runtime-verify → review → flip.
# Return codes:
#   0 — TDD flipped to implemented
#   1 — gate failed (existing FAIL/BLOCKED semantics)
#   2 — gate paused (TDD 0011 / FR-41) — drivers MUST stop iterating and not
#       mark downstream as BLOCKED
#
# Resume-aware: when launched with --resume, _resume_from has set
# RESUME_GATES_DONE_<slug> listing the gates already complete; gate_one
# skips those gates. Each successfully-completed gate is recorded into
# gates_completed via set_tdd_state's 5th param (TDD 0011 / FR-40).
gate_one() {  # <tdd> <review-base-ref> <log>
  local tdd="$1" rbase="$2" log="$3" bs rs rvs slug rrc _retries_json=""
  slug="$(basename "$tdd" .md)"
  # TDD 0011 / MA-4 belt-and-suspenders: refuse to process a slug whose state
  # fragment is missing. state_init's queue-freeze should have dropped any
  # newly-added TDDs from TDDS on resume, but defending here means a stray
  # call can never produce an untracked build.
  if [ -n "${STATE_DIR:-}" ] && [ ! -f "$STATE_DIR/$slug.json" ]; then
    echo "FAIL (no state fragment for $slug; queue-freeze should have dropped it)" >&2
    return 1
  fi
  set_tdd_meta "$slug" "log=$log"

  local _rkey _resume_done
  _rkey="$(_resume_gates_var "$slug")"
  _resume_done="${!_rkey:-}"
  _is_done() { case ",$_resume_done," in *",$1,"*) return 0;; esac; return 1; }

  # --- Gate 1: build (LLM-driven; retry-eligible) --------------------------
  if _is_done build; then
    : # branch already carries the impl + test(failing): commit; skip
  else
    set_tdd_state "$slug" building build
    _retry_in_gate _build_one_gated build "$slug" "$log" "$tdd" "$log"
    rrc=$?
    # TDD 0011 / BL-1: paused short-circuit MUST run before any BATCH_RESULT
    # scan of the cumulative log. After a retry sequence the log carries
    # earlier attempts' verdict lines; build_status (a tail-1 over the log)
    # can then surface a stale BLOCKED from a prior attempt and re-classify
    # a clean pause as a design blocker, corrupting BLOCKERS.md. Returning
    # 2 here makes the pause terminal for this run; the runtime-verify and
    # review gates already follow the same ordering.
    if [ "$rrc" -eq 2 ]; then
      echo "PAUSED build (see paused_cause in run state)"; return 2; fi
    # TDD 0011 / iter-6 MAJOR-1: when retries occurred, the cumulative
    # log may carry stale verdict lines from prior transient attempts.
    # If `_retry_in_gate` classified the latest attempt fatal AND retries
    # happened, do NOT consult the log's verdict (tail -1 would surface
    # an old BLOCKED from attempt 1 and corrupt BLOCKERS.md). Without
    # retries, the log's latest verdict IS the only verdict and can be
    # trusted. Use the fragment's retries[] count as the proxy.
    _retries_json="$(_read_fragment_raw_array "${STATE_DIR:-}/$slug.json" retries 2>/dev/null)"
    if [ "$rrc" -ne 0 ] && [ -n "$_retries_json" ] && [ "$_retries_json" != "[]" ]; then
      _terminal_state "$slug" failed "" "build gate fatal exit after retries (rc=$rrc)"
      echo "FAIL build (fatal exit after retries; see log)"; return 1
    fi
    bs="$(build_status "$log")"
    case "$bs" in
      *BLOCKED*) record_blocker "$tdd" "${bs#*BLOCKED}"
                 _terminal_state "$slug" blocked "" "build BLOCKED (design):${bs#*BLOCKED}"
                 echo "BLOCKED (design)${bs#*BLOCKED}"; return 1 ;;
    esac
    case "$bs" in
      *OK*) : ;;
      *) _terminal_state "$slug" failed "" "build did not return OK (${bs:-no BATCH_RESULT})"
         echo "${bs:-FAIL (no BATCH_RESULT; see log)}"; return 1 ;;
    esac
  fi

  # --- Gate 2: test-first + ci-checks.sh (mechanical; never retried) ----------
  if ! _is_done test-first; then
    set_tdd_state "$slug" verifying test-first
    if ! test_first_ok "$rbase" "$log"; then
      _terminal_state "$slug" failed "" "test-first gate: no failing-test-first commit"
      echo "FAIL test-first (no failing-test-first commit and no TEST_FIRST: SKIPPED; not flipped)"; return 1; fi
    # TDD 0011 / iter-9 SF-2: gate-completion writes feed FR-40's
    # resume hint; a swallowed failure would let resume re-run completed
    # gates. Surface failures via stderr.
    set_tdd_state "$slug" verifying test-first "" test-first \
      || echo "warning: gate_one: could not record test-first completion for $slug" >&2
  fi
  if ! _is_done verify; then
    set_tdd_state "$slug" verifying verify
    if ! run_ci_checks "$log"; then
      _terminal_state "$slug" failed "" "ci-checks.sh FAIL (tests/typecheck/lint)"
      echo "FAIL verification (tests/typecheck/lint red; not flipped)"; return 1; fi
    set_tdd_state "$slug" verifying verify "" verify \
      || echo "warning: gate_one: could not record verify completion for $slug" >&2
  fi

  # --- Gate 3: runtime-verify (LLM-driven; retry-eligible) -----------------
  if [ "${THROUGHLINE_REQUIRE_RUNTIME_VERIFY:-1}" = "1" ] && ! _is_done verify-runtime; then
    set_tdd_state "$slug" verifying verify-runtime
    _retry_in_gate _verify_runtime_one_gated verify-runtime "$slug" "$log" "$tdd" "$rbase" "$log"
    rrc=$?
    # TDD 0011 / MAJOR-4: paused short-circuit MUST run before any verdict
    # scan (same as gate 1 / BL-1). A stale `VERIFY_RUNTIME: BLOCKED` line
    # from a transient earlier attempt would otherwise misclassify a fatal
    # failure as status=blocked, violating NFR-4 verdict honesty.
    if [ "$rrc" -eq 2 ]; then
      echo "PAUSED runtime-verify"; return 2; fi
    # TDD 0011 / iter-6 MAJOR-1: only bypass log-verdict scan when retries
    # occurred (cumulative log may carry stale entries). Same proxy as
    # gate 1.
    _retries_json="$(_read_fragment_raw_array "${STATE_DIR:-}/$slug.json" retries 2>/dev/null)"
    if [ "$rrc" -ne 0 ] && [ -n "$_retries_json" ] && [ "$_retries_json" != "[]" ]; then
      _terminal_state "$slug" failed "" "runtime-verify gate fatal exit after retries (rc=$rrc)"
      echo "FAIL runtime-verify (fatal exit after retries; see log)"; return 1
    fi
    rvs="$(verify_runtime_status "$log")"
    case "$rvs" in
      *PASS*|*SKIP*) set_tdd_state "$slug" verifying verify-runtime "" verify-runtime \
                       || echo "warning: gate_one: could not record verify-runtime completion for $slug" >&2 ;;
      *BLOCKED*) _terminal_state "$slug" blocked "" "runtime-verify BLOCKED (couldn't observe)"
                 echo "BLOCKED runtime-verify (couldn't observe)${rvs#*BLOCKED}"; return 1 ;;
      *FAIL*)    _terminal_state "$slug" failed "" "runtime-verify FAIL"
                 echo "FAIL runtime-verify${rvs#*FAIL}"; return 1 ;;
      *) _terminal_state "$slug" failed "" "runtime-verify: no VERIFY_RUNTIME line"
         echo "FAIL runtime-verify (no VERIFY_RUNTIME line; ambiguity is never a false PASS; see log)"; return 1 ;;
    esac
  fi

  # --- Gate 4: review (LLM-driven; retry-eligible) -------------------------
  if ! _is_done review; then
    set_tdd_state "$slug" reviewing review
    _retry_in_gate _review_one_gated review "$slug" "$log" "$tdd" "$rbase" "$log"
    rrc=$?
    # TDD 0011 / MAJOR-4: paused short-circuit before verdict scan (see
    # gate 3 above + BL-1).
    if [ "$rrc" -eq 2 ]; then
      echo "PAUSED review"; return 2; fi
    # TDD 0011 / iter-6 MAJOR-1: same retries-proxy as gates 1 and 3.
    _retries_json="$(_read_fragment_raw_array "${STATE_DIR:-}/$slug.json" retries 2>/dev/null)"
    if [ "$rrc" -ne 0 ] && [ -n "$_retries_json" ] && [ "$_retries_json" != "[]" ]; then
      _terminal_state "$slug" failed "" "review gate fatal exit after retries (rc=$rrc)"
      echo "FAIL review (fatal exit after retries; see log)"; return 1
    fi
    rs="$(review_status "$log")"
    case "$rs" in
      *PASS*) set_tdd_state "$slug" reviewing review "" review \
                || echo "warning: gate_one: could not record review completion for $slug" >&2 ;;
      *BLOCK*) _terminal_state "$slug" failed "" "review BLOCK"
               echo "FAIL review:${rs#*BLOCK}"; return 1 ;;
      *) _terminal_state "$slug" failed "" "review: no REVIEW_RESULT line"
         echo "FAIL review (no REVIEW_RESULT; see log)"; return 1 ;;
    esac
  fi

  set_tdd_state "$slug" reviewing flip
  flip_status "$tdd" "$log"
  _terminal_state "$slug" done "" "OK (verified + reviewed)"
  echo "OK (verified + reviewed)"; return 0
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

if [ -f "${MAINREPO:-$PWD}/docs/tdd/BLOCKERS.md" ]; then
  { echo; echo "Design blockers were recorded in docs/tdd/BLOCKERS.md — run /tdd-author to revise the design, then re-run /implement."; } >>"$REPORT"
fi

# Mark the run-state record as terminal (FR-27) so a later status.sh on this
# logdir sees the rollup. If any TDD paused (TDD 0011 / FR-41), the run-level
# state is `paused` (resumable), not `done` — verdict honesty per NFR-4.
# Re-roll the fragments to see if any are paused; rerun parser is fragment-by-
# fragment because the loop-level `paused_halt` variable is scoped to the
# specific driver block.
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
  set_run_state paused \
    || echo "warning: could not write final run.json (state=paused)" | tee -a "$REPORT" >&2
else
  set_run_state done \
    || echo "warning: could not write final run.json (state=done)" | tee -a "$REPORT" >&2
fi

echo; echo "=== Done. Report: $REPORT ==="; cat "$REPORT"

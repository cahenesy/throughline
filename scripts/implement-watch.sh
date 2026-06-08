#!/usr/bin/env bash
# implement-watch.sh — the harness-tracked liveness bridge between the headless
# runner and the interactive session (TDD 0022 §3 / FR-72).
#
# The /implement skill launches THIS as a harness-tracked background job (so the
# harness re-invokes the session when it exits), and it in turn `nohup`s the real
# build (scripts/implement.sh) so the build still detaches and survives session
# close (TDD 0011 / FR-39). We poll for the build's completion, then exit — which
# returns control to the main session, where the accept/discard review runs. If
# the session/watcher dies, the nohup'd build finishes anyway; only the
# auto-callback is lost (the skill's fallback review picks it up next invocation).
#
# Every flag/scope the skill assembled ("$@") is forwarded to implement.sh
# unchanged — the watcher is mode-agnostic.
set -uo pipefail

# implement.sh lives next to this script; the logs dir hangs off the repo cwd
# (the skill launches both from the repo root, matching implement.sh's MAINREPO=$PWD).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || {
  echo "FATAL: cannot resolve scripts directory from ${BASH_SOURCE[0]}" >&2; exit 1
}
# THROUGHLINE_WATCH_BUILD_SCRIPT lets the eval point the watcher at a stub build;
# production always resolves the real implement.sh beside this file.
BUILD_SCRIPT="${THROUGHLINE_WATCH_BUILD_SCRIPT:-$SCRIPT_DIR/implement.sh}"
LOGS_DIR="$PWD/docs/tdd/.implement-logs"
# Fail loud: the logs dir is load-bearing for the PID file, the nohup redirect,
# and the run-state read. A swallowed failure here would cascade silently into a
# false IMPLEMENT_RUN_COMPLETE with no build ever running, so abort instead of
# `|| true` (FR-74 norm #1).
if ! mkdir -p "$LOGS_DIR" 2>/dev/null; then
  echo "FATAL: implement-watch.sh: cannot create logs dir $LOGS_DIR (perms? a non-dir in the path?)" >&2
  exit 1
fi
PIDFILE="$LOGS_DIR/.watch.pid"

# Poll cadence + INACTIVITY window. MAX is the max silence under the run dir
# before the watcher declares the build wedged — NOT a total wall-clock cap: a
# streaming/transitioning build resets the clock continuously, so a long-but-
# progressing run is never false-completed; only a build whose run dir has not
# advanced for MAX seconds exits (TDD 0036 §1). Non-numeric → default + warn,
# matching state.sh discipline.
POLL="${THROUGHLINE_WATCH_POLL_SECS:-30}"
MAX="${THROUGHLINE_WATCH_MAX_SECS:-14400}"
case "$POLL" in ''|*[!0-9]*) echo "warning: THROUGHLINE_WATCH_POLL_SECS='$POLL' not numeric; using 30" >&2; POLL=30 ;; esac
case "$MAX"  in ''|*[!0-9]*) echo "warning: THROUGHLINE_WATCH_MAX_SECS='$MAX' not numeric; using 14400" >&2; MAX=14400 ;; esac
[ "$POLL" -lt 1 ] 2>/dev/null && POLL=1

# Record our PID so implement.sh's run-end hook can SIGUSR1 us (§4). A stale file
# is harmless — the run-end hook's `kill -0` guard skips a dead/absent watcher.
WOKEN=0
trap 'WOKEN=1' USR1
trap 'rm -f "$PIDFILE" 2>/dev/null' EXIT
# A PID-write failure is non-fatal BY DESIGN: an absent .watch.pid just means the
# run-end hook's `kill -USR1` no-ops under its `kill -0` guard and we fall back to
# poll-only completion detection (TDD §Failure-modes) — but surface it so the lost
# USR1 shortcut isn't silent (FR-74 #1).
printf '%s\n' "$$" > "$PIDFILE" 2>/dev/null \
  || echo "warning: implement-watch.sh: could not write $PIDFILE; falling back to poll-only completion detection" >&2

# Readiness is validated DETERMINISTICALLY, BEFORE launch — the watcher's own
# launch machinery (the build script + the nohup.out redirect target) must be
# usable, or we would echo a phantom pid for a build that exec-fails on the spot
# and later emit a false IMPLEMENT_RUN_COMPLETE (FR-74 #1). We do NOT post-hoc
# probe run-state: `latest` is relinked only at the END of state_init (state.sh),
# so on a 2nd-or-later run a stale `latest` from the prior run would make such a
# probe pass incorrectly. A build that genuinely STARTS and then dies fast (crash,
# single-run-lock reject) is the runner's domain — the poll loop reports it as
# state=unknown / whatever the run left per the TDD's failure-mode contract, not a
# watcher launch failure.
if [ ! -r "$BUILD_SCRIPT" ]; then
  echo "FATAL: implement-watch.sh: build script not found/readable: $BUILD_SCRIPT" >&2
  exit 1
fi
# Pre-create (and so prove writable) the nohup.out redirect target. A failure
# here is the redirect failure that would otherwise silently strand the build.
if ! : > "$LOGS_DIR/nohup.out" 2>/dev/null; then
  echo "FATAL: implement-watch.sh: cannot create the build-log redirect target $LOGS_DIR/nohup.out" >&2
  exit 1
fi

# Detach the real build (nohup → survives session close). "$@" forwards the
# skill's flags verbatim. Capture the child PID; it is the PID the skill reports.
nohup bash "$BUILD_SCRIPT" "$@" >> "$LOGS_DIR/nohup.out" 2>&1 &
BUILD_PID=$!
echo "launched build pid $BUILD_PID"

# Poll: exit when the build process is gone (covers crash-without-signal) OR the
# build signalled completion (SIGUSR1 → WOKEN) OR the run dir has gone INACTIVE
# for MAX seconds (wedged). The PID-gone and WOKEN breaks keep their precedence
# (checked before the inactivity probe each iteration), so a clean completion or
# crash still exits immediately and never as `watcher-timeout`. The sleep runs as
# a backgrounded child waited on with `wait`, so a trapped SIGUSR1 interrupts the
# wait immediately (a foreground `sleep` would defer the trap until it elapsed —
# defeating the shortcut).
LATEST="$LOGS_DIR/latest"
WEDGED=0   # set only on an inactivity break; consumed by the emit block below
while :; do
  kill -0 "$BUILD_PID" 2>/dev/null || break
  [ "$WOKEN" -eq 1 ] && break
  # Inactivity probe (TDD 0036 §1). newest = the latest mtime of any regular file
  # under the active run dir (recursively — covers BOTH the per-TDD build logs,
  # which grow token-by-token as the coprocess streams, AND state.d/*.json, which
  # are rewritten at every status/stage transition). %T@ is fractional epoch
  # seconds; truncate to integer (sub-second precision is irrelevant at a ≥1s
  # poll). An unreadable/empty run dir (symlink missing, race at run start) yields
  # NO mtime → we cannot measure inactivity this poll, so we SKIP the wedge check
  # (never exit) and keep polling; the PID-gone break stays the guaranteed
  # terminator. This reintroduces no silent total-time cap (TDD 0036 §Failure-modes).
  newest="$(find "$LATEST/" -type f -printf '%T@\n' 2>/dev/null | cut -d. -f1 | sort -rn | head -1)"
  if [ -n "$newest" ]; then
    now="$(date +%s)"
    stale=$((now - newest))
    if [ "$stale" -ge "$MAX" ]; then WEDGED=1; break; fi
  fi
  sleep "$POLL" & SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  # Best-effort cleanup of the sleep child: on a normal `wait` it has already
  # exited (kill fails harmlessly); on a SIGUSR1-interrupted wait this reaps the
  # still-running sleep. Either outcome is fine, hence || true (FR-74 #1).
  kill "$SLEEP_PID" 2>/dev/null || true
  [ "$WOKEN" -eq 1 ] && break
done

# Report completion in one parseable line. logdir is the absolute path the
# `latest` symlink resolves to (LATEST was resolved before the poll loop); state
# comes from run.json; candidate_learnings is yes when the detector wrote a review
# queue this run.
logdir_abs="$(cd "$LATEST" 2>/dev/null && pwd -P)" || logdir_abs=""
[ -z "$logdir_abs" ] && logdir_abs="$LATEST"
# The line is a single whitespace-tokenized key=value record. A path may legally
# contain spaces (the consumer recovers the trailing closed-vocabulary fields by
# anchored key= match), but a raw CR/LF would inject a second line and split the
# contract — collapse any to a space so the record stays exactly one line.
logdir_abs="${logdir_abs//$'\n'/ }"; logdir_abs="${logdir_abs//$'\r'/ }"
# Validate state against the known run-state vocabulary (state.sh's run.json
# writer), now including watcher-timeout — the watcher's own give-up signal.
# Anything unexpected/malformed (whitespace, empty, corrupt run.json) collapses to
# `unknown`, so the state= token is always a single clean word (TDD §3 contract;
# §Failure-modes' "whatever the run left" passes through here).
#
# On a WEDGED exit (inactivity break, TDD 0036 §2), FORCE state=watcher-timeout
# REGARDLESS of run.json — which still says "running", since the build is wedged
# mid-run. Honest per NFR-4: a running build is never reported as a normal
# completion. The PID-gone and USR1 exits (WEDGED stays 0) keep reading run.json
# as today — a genuine terminal state passes through unchanged.
state="unknown"
if [ "$WEDGED" -eq 1 ]; then
  state="watcher-timeout"
elif [ -r "$LATEST/state.d/run.json" ]; then
  _s="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$LATEST/state.d/run.json" | head -1)"
  case "$_s" in
    running|done|paused|blocked|interrupted|failed|watcher-timeout) state="$_s" ;;
    *) state="unknown" ;;
  esac
fi
cl="no"; [ -f "$LATEST/candidate-learnings.json" ] && cl="yes"
echo "IMPLEMENT_RUN_COMPLETE logdir=$logdir_abs state=$state candidate_learnings=$cl"

# Benign: the file may already be gone (EXIT trap) or never written; nothing
# downstream depends on the removal succeeding (FR-74 #1).
rm -f "$PIDFILE" 2>/dev/null || true
exit 0

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
mkdir -p "$LOGS_DIR" 2>/dev/null || true
PIDFILE="$LOGS_DIR/.watch.pid"

# Poll cadence + hard ceiling (≥ the build watchdog so a wedged build can't pin
# the watcher forever). Non-numeric → default + warn, matching state.sh discipline.
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
printf '%s\n' "$$" > "$PIDFILE" 2>/dev/null || true

# Detach the real build (nohup → survives session close). "$@" forwards the
# skill's flags verbatim. Capture the child PID; it is the PID the skill reports.
nohup bash "$BUILD_SCRIPT" "$@" > "$LOGS_DIR/nohup.out" 2>&1 &
BUILD_PID=$!
echo "launched build pid $BUILD_PID"

# Poll: exit when the build process is gone (covers crash-without-signal) OR the
# build signalled completion (SIGUSR1 → WOKEN), bounded by the MAX ceiling. The
# sleep runs as a backgrounded child waited on with `wait`, so a trapped SIGUSR1
# interrupts the wait immediately (a foreground `sleep` would defer the trap
# until it elapsed — defeating the shortcut).
elapsed=0
while :; do
  kill -0 "$BUILD_PID" 2>/dev/null || break
  [ "$WOKEN" -eq 1 ] && break
  [ "$elapsed" -ge "$MAX" ] && break
  sleep "$POLL" & SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  kill "$SLEEP_PID" 2>/dev/null || true
  WOKEN_NOW="$WOKEN"
  elapsed=$((elapsed + POLL))
  [ "$WOKEN_NOW" -eq 1 ] && break
done

# Report completion in one parseable line. logdir is the absolute path the
# `latest` symlink resolves to; state comes from run.json; candidate_learnings is
# yes when the detector wrote a review queue this run.
LATEST="$LOGS_DIR/latest"
logdir_abs="$(cd "$LATEST" 2>/dev/null && pwd -P)" || logdir_abs=""
[ -z "$logdir_abs" ] && logdir_abs="$LATEST"
# The line is a single whitespace-tokenized key=value record. A path may legally
# contain spaces (the consumer recovers the trailing closed-vocabulary fields by
# anchored key= match), but a raw CR/LF would inject a second line and split the
# contract — collapse any to a space so the record stays exactly one line.
logdir_abs="${logdir_abs//$'\n'/ }"; logdir_abs="${logdir_abs//$'\r'/ }"
# Validate state against the known run-state vocabulary (state.sh's run.json
# writer). Anything unexpected/malformed (whitespace, empty, corrupt run.json)
# collapses to `unknown`, so the state= token is always a single clean word
# (TDD §3 contract; §Failure-modes' "whatever the run left" passes through here).
state="unknown"
if [ -r "$LATEST/state.d/run.json" ]; then
  _s="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$LATEST/state.d/run.json" | head -1)"
  case "$_s" in
    running|done|paused|blocked|interrupted|failed) state="$_s" ;;
    *) state="unknown" ;;
  esac
fi
cl="no"; [ -f "$LATEST/candidate-learnings.json" ] && cl="yes"
echo "IMPLEMENT_RUN_COMPLETE logdir=$logdir_abs state=$state candidate_learnings=$cl"

rm -f "$PIDFILE" 2>/dev/null || true
exit 0

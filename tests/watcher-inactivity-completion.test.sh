#!/usr/bin/env bash
# watcher-inactivity-completion.test.sh — eval for TDD 0036 (the watcher's
# completion ceiling is INACTIVITY-based, not total wall-clock). A long but
# progressing build must never be false-completed; only a genuinely wedged build
# (no run-dir activity for >= MAX) exits, and it reports a DISTINCT state.
#
# Drives the real scripts/implement-watch.sh against a STUB build via
# THROUGHLINE_WATCH_BUILD_SCRIPT with a short THROUGHLINE_WATCH_MAX_SECS /
# THROUGHLINE_WATCH_POLL_SECS (no model or tokens needed). Mirrors the watcher
# fixture pattern of tests/build-phase-learning-capture.test.sh (§3 [S13]-[S18]).
#
# Run: bash tests/watcher-inactivity-completion.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="$REPO/scripts/implement-watch.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# Fail-closed absence assertion (TDD 0036 Verification plan, "Mechanical-check
# robustness" / LEARNINGS L-001 fragile-inversion): PASS only when the pattern is
# genuinely ABSENT (grep rc 1). rc 0 (present) fails; rc >= 2 (file unreadable or
# missing) ALSO fails — an unreadable file must NEVER masquerade as "string
# absent". The explicit -r guard catches the missing/unreadable file before grep
# so the diagnostic is specific rather than a bare grep error.
absent() {  # <file> <pattern> <label>
  if [ ! -r "$1" ]; then bad "$3 (file unreadable/missing: $1)"; return; fi
  grep -q "$2" "$1"
  case $? in
    1) ok "$3" ;;
    0) bad "$3 (unexpected /$2/ in $1)" ;;
    *) bad "$3 (grep could not read $1 — failing closed)" ;;
  esac
}

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Kill the stub build the watcher nohup'd (it survives the watcher by design).
# Parse the PID from the watcher's own `launched build pid <PID>` stdout line and
# kill ONLY that PID (no pattern-based killing).
kill_stub() {  # <watcher-out-file>
  local bpid
  bpid="$(grep -oE 'launched build pid [0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+$' | head -1)"
  [ -n "$bpid" ] && kill "$bpid" 2>/dev/null || true
}

# ===========================================================================
# §1: a PROGRESSING build past MAX is NOT false-completed; the watcher exits only
# AFTER the run dir goes inactive for >= MAX. This is the crux: it proves
# inactivity — not total elapsed — governs the exit. A stub build appends under
# latest/ every 1s for ~3×MAX, THEN goes silent (but stays ALIVE, so only
# inactivity, never PID-gone, can end the watcher).
echo "[§1] progressing build past MAX -> no false completion; exits after inactivity"
( WT="$ROOT/s1"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  cat > "$WT/scripts/stub.sh" <<'EOF'
#!/usr/bin/env bash
LOGS="$PWD/docs/tdd/.implement-logs"
mkdir -p "$LOGS/run1/state.d"
printf '{"schema":1,"state":"running"}\n' > "$LOGS/run1/state.d/run.json"
ln -sfn run1 "$LOGS/latest"
# Progress: append every 1s for 6s (= 3×MAX with MAX=2), well past MAX.
i=0; while [ "$i" -lt 6 ]; do date +%s%N >> "$LOGS/run1/build.log"; sleep 1; i=$((i+1)); done
# Now silent but ALIVE — only the inactivity bound can end the watcher.
sleep 120
EOF
  out="$WT/out.txt"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_BUILD_SCRIPT="$WT/scripts/stub.sh" \
      THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=2 \
      bash "$WATCH" >"$out" 2>&1 ) &
  wpid=$!
  # At 4s the build is still writing (writes for 6s) and 4s > MAX=2 — a
  # total-elapsed watcher would already have exited here; an inactivity watcher
  # stays alive because the run dir is fresh. Assert process-ALIVE, not a
  # string-absent grep (the completion line is simply not written yet).
  sleep 4
  if kill -0 "$wpid" 2>/dev/null; then ok "watcher still alive past MAX while the build progresses"; else bad "watcher false-completed during a progressing build (total-elapsed bound not removed)"; fi
  absent "$out" '^IMPLEMENT_RUN_COMPLETE' "no premature IMPLEMENT_RUN_COMPLETE while progressing"
  # The build keeps writing until ~6s then goes silent; the watcher should
  # detect inactivity (stale >= MAX) and exit within ~MAX+POLL after that.
  i=0; while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$wpid" 2>/dev/null; then bad "watcher never exited after the run dir went inactive"; kill "$wpid" 2>/dev/null; else ok "watcher exited after inactivity (stale >= MAX)"; fi
  wait "$wpid" 2>/dev/null
  grep -q '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null && ok "IMPLEMENT_RUN_COMPLETE emitted on the inactivity exit" || bad "watcher should emit IMPLEMENT_RUN_COMPLETE on the inactivity exit (got: $(cat "$out" 2>/dev/null))"
  ln1="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  # The wedge exit must report the DISTINCT state, not the run.json passthrough
  # (run.json still says "running" — the build is wedged mid-run). NFR-4 honesty.
  case "$ln1" in
    *"state=watcher-timeout"*) ok "inactivity exit reports the distinct state=watcher-timeout" ;;
    *) bad "inactivity exit must report state=watcher-timeout, not the run.json passthrough ($ln1)" ;;
  esac
  kill_stub "$out"
) || true

# ===========================================================================
# §2: a build that is ALIVE but writes NOTHING under latest/ for MAX seconds is
# wedged → the watcher exits within ~MAX (+1 poll) and emits the DISTINCT
# state=watcher-timeout — NOT state=running (the run.json passthrough), NOT
# state=done. This is the honest give-up signal (NFR-4): a running build is never
# reported as a normal completion.
echo "[§2] silent build for MAX -> wedged exit, state=watcher-timeout (not running/done)"
( WT="$ROOT/s2"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  cat > "$WT/scripts/stub.sh" <<'EOF'
#!/usr/bin/env bash
LOGS="$PWD/docs/tdd/.implement-logs"
mkdir -p "$LOGS/run1/state.d"
printf '{"schema":1,"state":"running"}\n' > "$LOGS/run1/state.d/run.json"
ln -sfn run1 "$LOGS/latest"
# Silent from the start, but stays ALIVE — only the inactivity bound can end it.
sleep 120
EOF
  out="$WT/out.txt"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_BUILD_SCRIPT="$WT/scripts/stub.sh" \
      THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=2 \
      bash "$WATCH" >"$out" 2>&1 )
  ln1="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  [ -n "$ln1" ] && ok "watcher exited and emitted IMPLEMENT_RUN_COMPLETE on silence" || bad "watcher should exit + emit on a silent build (got: $(cat "$out" 2>/dev/null))"
  case "$ln1" in *"state=watcher-timeout"*) ok "silent-build exit reports state=watcher-timeout" ;; *) bad "expected state=watcher-timeout ($ln1)" ;; esac
  case "$ln1" in *"state=running"*) bad "must NOT report state=running for a wedged build ($ln1)" ;; *) ok "not reported as state=running (NFR-4)" ;; esac
  case "$ln1" in *"state=done"*) bad "must NOT report state=done for a wedged build ($ln1)" ;; *) ok "not reported as a false state=done (NFR-4)" ;; esac
  kill_stub "$out"
) || true

# ===========================================================================
# §3: PID-gone exit unchanged. A build that writes a terminal run.json (state=done)
# then EXITS → the watcher exits promptly via the PID-gone break and passes the
# real run.json state through (state=done), never watcher-timeout. MAX is large so
# inactivity cannot be what ends it — the PID-gone break must.
echo "[§3] PID-gone exit -> run.json passthrough preserved (state=done)"
( WT="$ROOT/s3"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  cat > "$WT/scripts/stub.sh" <<'EOF'
#!/usr/bin/env bash
LOGS="$PWD/docs/tdd/.implement-logs"
mkdir -p "$LOGS/run1/state.d"
printf '{"schema":1,"state":"done"}\n' > "$LOGS/run1/state.d/run.json"
ln -sfn run1 "$LOGS/latest"
# Build finishes (process exits) immediately — PID-gone is the terminator.
EOF
  out="$WT/out.txt"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_BUILD_SCRIPT="$WT/scripts/stub.sh" \
      THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=60 \
      bash "$WATCH" >"$out" 2>&1 )
  ln1="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  case "$ln1" in *"state=done"*) ok "PID-gone exit passes run.json state=done through" ;; *) bad "expected state=done passthrough on PID-gone ($ln1)" ;; esac
  case "$ln1" in *"state=watcher-timeout"*) bad "a clean PID-gone exit must NOT report watcher-timeout ($ln1)" ;; *) ok "PID-gone exit is not mislabeled watcher-timeout" ;; esac
  kill_stub "$out"
) || true

# ===========================================================================
# §4: clean SIGUSR1 completion unchanged. With the build still ALIVE, deliver
# SIGUSR1 (the run-end-hook path) → the watcher exits promptly and emits the
# run.json state (done), never watcher-timeout. POLL is large so a non-signalled
# watcher would still be asleep; the wake must be the USR1.
echo "[§4] clean SIGUSR1 completion -> run.json passthrough (state=done), never watcher-timeout"
( WT="$ROOT/s4"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  cat > "$WT/scripts/stub.sh" <<'EOF'
#!/usr/bin/env bash
LOGS="$PWD/docs/tdd/.implement-logs"
mkdir -p "$LOGS/run1/state.d"
printf '{"schema":1,"state":"done"}\n' > "$LOGS/run1/state.d/run.json"
ln -sfn run1 "$LOGS/latest"
sleep 120
EOF
  out="$WT/out.txt"; pidf="$WT/repo/docs/tdd/.implement-logs/.watch.pid"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_BUILD_SCRIPT="$WT/scripts/stub.sh" \
      THROUGHLINE_WATCH_POLL_SECS=30 THROUGHLINE_WATCH_MAX_SECS=60 \
      bash "$WATCH" >"$out" 2>&1 ) &
  wpid=$!
  i=0; while [ ! -f "$pidf" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done
  wp="$(cat "$pidf" 2>/dev/null)"
  sleep 1   # let the watcher enter its sleep
  [ -n "$wp" ] && kill -USR1 "$wp" 2>/dev/null
  i=0; while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 16 ]; do sleep 0.5; i=$((i+1)); done
  if kill -0 "$wpid" 2>/dev/null; then bad "watcher did not wake on SIGUSR1 within ~8s (POLL=30)"; kill "$wpid" 2>/dev/null; else ok "watcher woke on SIGUSR1 before the poll elapsed"; fi
  wait "$wpid" 2>/dev/null
  ln1="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  case "$ln1" in *"state=done"*) ok "USR1 exit passes run.json state=done through" ;; *) bad "expected state=done on USR1 wake ($ln1)" ;; esac
  case "$ln1" in *"state=watcher-timeout"*) bad "a USR1-woken exit must NOT report watcher-timeout ($ln1)" ;; *) ok "USR1 exit is not mislabeled watcher-timeout" ;; esac
  kill_stub "$out"
) || true

# ===========================================================================
# §5: the skill's completion callback classifies terminal vs non-terminal state
# and re-arms a build-PID poll (and suppresses the learnings review) on a
# non-terminal exit. Mechanical grep on skills/implement/SKILL.md. The file is
# asserted READABLE before any content check (TDD 0036 "Mechanical-check
# robustness" / L-002 misleading-diagnostic — no unconditional check after a
# missing file); every anchor is specific to text THIS change introduces
# (watcher-timeout / while kill -0 / the learnings-review suppression sentence),
# never a phrase already present in SKILL.md.
echo "[§5] SKILL.md completion callback: terminal-vs-non-terminal classification + re-arm poll"
( SK="$REPO/skills/implement/SKILL.md"
  if [ ! -r "$SK" ]; then
    bad "SKILL.md unreadable/missing — cannot run the §5 content checks: $SK"
  else
    grep -q 'watcher-timeout' "$SK" \
      && ok "SKILL.md classifies watcher-timeout as a non-terminal state" \
      || bad "SKILL.md should list watcher-timeout among the non-terminal states"
    grep -q 'while kill -0' "$SK" \
      && ok "SKILL.md re-arms a background build-PID poll (while kill -0 ...)" \
      || bad "SKILL.md should re-arm a background 'while kill -0 <PID>' poll on a non-terminal exit"
    grep -q 'do NOT run the candidate-learnings review' "$SK" \
      && ok "SKILL.md forbids the candidate-learnings review on a non-terminal state" \
      || bad "SKILL.md should forbid running the candidate-learnings review on a non-terminal state"
  fi
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== watcher-inactivity-completion eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

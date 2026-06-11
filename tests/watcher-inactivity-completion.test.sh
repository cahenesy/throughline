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
# Covers the TDD's Verification plan observation points:
#   §1 — a progressing build past MAX is NOT false-completed; the watcher exits
#        only after the run dir goes inactive for >= MAX, with state=watcher-timeout
#        (process-alive check during the writing phase, not a string-absent grep).
#   §2 — a silent-but-alive build for MAX wedges → exit with the DISTINCT
#        state=watcher-timeout, never state=running or a false state=done (NFR-4).
#   §3 — a PID-gone exit (terminal run.json) passes the real state through (done).
#   §4 — a clean SIGUSR1 completion passes the run.json state through, never
#        watcher-timeout.
#   §5 — skills/implement/SKILL.md classifies the non-terminal state and re-arms a
#        build-PID poll (mechanical grep, file-readable-guarded).
#   §7 — TDD 0054 A9: the COMPLETION read is WATCH_START-gated. A build that dies
#        BEFORE state_init relinks `latest` leaves `latest` on the PRIOR run,
#        whose run.json is terminal — the watcher must report state=unknown, not
#        the stale terminal state. Control: a build that DOES relink to a fresh
#        run still passes its real terminal state through.
#
# Mechanical-check robustness (L-001/L-002): absence assertions fail CLOSED via
# absent() (grep rc 1 = absent → PASS; rc >= 2 = unreadable → FAIL); the §5 target
# file is asserted readable before its content checks; every anchor is specific to
# text THIS change introduces (watcher-timeout / while kill -0 / the learnings-
# review suppression sentence).
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
# Progress: append every 1s for 6s (= 1.5×MAX with MAX=4), well past MAX.
i=0; while [ "$i" -lt 6 ]; do date +%s%N >> "$LOGS/run1/build.log"; sleep 1; i=$((i+1)); done
# Now silent but ALIVE — only the inactivity bound can end the watcher.
sleep 120
EOF
  out="$WT/out.txt"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_BUILD_SCRIPT="$WT/scripts/stub.sh" \
      THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=4 \
      bash "$WATCH" >"$out" 2>&1 ) &
  wpid=$!
  # At 5s the build is still writing (writes for 6s) and 5s > MAX=4 — a
  # total-elapsed watcher would already have exited here; an inactivity watcher
  # stays alive because the run dir is fresh. Assert process-ALIVE, not a
  # string-absent grep (the completion line is simply not written yet).
  sleep 5
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
      bash "$WATCH" >"$out" 2>&1 ) &
  wpid=$!
  # Bounded wait: MAX=2 + POLL=1 → should exit within ~4s; 10s ceiling prevents
  # an inactivity-probe regression from hanging the aggregator (no-hang discipline).
  i=0; while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$wpid" 2>/dev/null; then bad "watcher still alive after 10s ceiling (inactivity probe regressed)"; kill "$wpid" 2>/dev/null; fi
  wait "$wpid" 2>/dev/null
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
      bash "$WATCH" >"$out" 2>&1 ) &
  wpid=$!
  # Bounded wait: stub exits immediately (PID-gone); 10s ceiling prevents a
  # PID-gone regression from blocking the aggregator (no-hang discipline).
  i=0; while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$wpid" 2>/dev/null; then bad "watcher still alive after 10s ceiling (PID-gone check regressed)"; kill "$wpid" 2>/dev/null; fi
  wait "$wpid" 2>/dev/null
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

# ===========================================================================
# §6: startup-window guard — a stale prior-run latest/ must NOT trigger a
# false-wedge at startup. Pre-seeds run0/ with files timestamped > MAX ago,
# links latest -> run0, then launches the watcher. The stub simulates a
# state_init delay (relinks latest -> run1 after 2s). During the stale window
# the watcher must NOT exit as wedged; after the relink, normal inactivity
# resumes and the later silence does wedge (MAX=3).
echo "[§6] startup-window guard: stale prior-run latest/ must not trigger false-wedge"
( WT="$ROOT/s6"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  # Pre-create a stale prior-run dir and link latest -> it.
  mkdir -p "$WT/repo/docs/tdd/.implement-logs/run0/state.d"
  printf '{"schema":1,"state":"done"}\n' > "$WT/repo/docs/tdd/.implement-logs/run0/state.d/run.json"
  touch "$WT/repo/docs/tdd/.implement-logs/run0/build.log"
  ln -sfn run0 "$WT/repo/docs/tdd/.implement-logs/latest"
  # Set mtime WELL before WATCH_START (30s > MAX=3) — newest < WATCH_START guaranteed.
  find "$WT/repo/docs/tdd/.implement-logs/run0" -type f -exec touch -d '30 seconds ago' {} \;
  cat > "$WT/scripts/stub.sh" <<'EOF'
#!/usr/bin/env bash
# Simulate state_init: after a 2s delay relink latest -> run1 + write fresh files.
LOGS="$PWD/docs/tdd/.implement-logs"
mkdir -p "$LOGS/run1/state.d"
printf '{"schema":1,"state":"running"}\n' > "$LOGS/run1/state.d/run.json"
sleep 2
ln -sfn run1 "$LOGS/latest"
touch "$LOGS/run1/build.log"
# Silent but alive from here — inactivity probe should wedge after MAX.
sleep 120
EOF
  out="$WT/out.txt"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_BUILD_SCRIPT="$WT/scripts/stub.sh" \
      THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=3 \
      bash "$WATCH" >"$out" 2>&1 ) &
  wpid=$!
  # At ~2s the stub has not yet relinked. The watcher sees stale run0 files
  # (newest < WATCH_START) and must skip the wedge check. Assert process-alive,
  # NOT a string-absent grep (IMPLEMENT_RUN_COMPLETE not written yet).
  sleep 2
  if kill -0 "$wpid" 2>/dev/null
  then ok "watcher alive during stale-latest window (WATCH_START guard prevents false-wedge)"
  else bad "watcher false-wedged on stale prior-run latest/ — WATCH_START guard missing or broken (got: $(cat "$out" 2>/dev/null))"
  fi
  # After the relink + silence, inactivity eventually wedges (MAX=3, silence starts ~2s).
  i=0; while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.5; i=$((i+1)); done
  if kill -0 "$wpid" 2>/dev/null
  then bad "watcher never exited after the relinked run1 went inactive"; kill "$wpid" 2>/dev/null
  else ok "watcher exited on inactivity after latest/ relinked to run1"
  fi
  wait "$wpid" 2>/dev/null
  ln1="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  [ -n "$ln1" ] && ok "IMPLEMENT_RUN_COMPLETE emitted on wedge after relink" \
    || bad "no IMPLEMENT_RUN_COMPLETE after inactivity wedge (got: $(cat "$out" 2>/dev/null))"
  case "$ln1" in
    *"state=watcher-timeout"*) ok "inactivity wedge after relink reports state=watcher-timeout" ;;
    *) bad "expected state=watcher-timeout on inactivity wedge after relink ($ln1)" ;;
  esac
  kill_stub "$out"
) || true

# ===========================================================================
# §7 (TDD 0054 A9): stale-latest completion guard. The completion block's
# run.json read must be WATCH_START-gated (the same newest-mtime gate the
# inactivity probe applies at the wedge check). Arm 1: pre-seed a PRIOR run dir
# (terminal run.json, mtimes well before WATCH_START), link latest -> it, and
# stub a build that dies BEFORE state_init relinks (single-run-lock reject /
# early FATAL) — the watcher must emit state=unknown, NOT the prior run's stale
# state=done (which would make the callback inspect the wrong run and mask the
# real fast-failure). Arm 2 (control, no over-broad unknown): with the same
# stale prior seeded, a build that DOES relink latest to a fresh terminal run
# still reports its real state=done.
echo "[§7] stale-latest completion guard: pre-relink death -> state=unknown; fresh relink -> real state"
( WT="$ROOT/s7"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  # Pre-seed the prior run: terminal run.json, latest -> run0, mtimes 30s old
  # (well before WATCH_START, so newest < WATCH_START is guaranteed).
  mkdir -p "$WT/repo/docs/tdd/.implement-logs/run0/state.d"
  printf '{"schema":1,"state":"done"}\n' > "$WT/repo/docs/tdd/.implement-logs/run0/state.d/run.json"
  ln -sfn run0 "$WT/repo/docs/tdd/.implement-logs/latest"
  find "$WT/repo/docs/tdd/.implement-logs/run0" -type f -exec touch -d '30 seconds ago' {} \;
  # Arm 1: the build dies before state_init ever relinks latest.
  cat > "$WT/scripts/stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  out="$WT/out.txt"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_BUILD_SCRIPT="$WT/scripts/stub.sh" \
      THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=60 \
      bash "$WATCH" >"$out" 2>&1 ) &
  wpid=$!
  # Bounded wait: the stub exits immediately, so the PID-gone break ends the
  # watcher within ~1 poll; 10s ceiling keeps the aggregator hang-free.
  i=0; while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$wpid" 2>/dev/null; then bad "watcher still alive after 10s ceiling (PID-gone check regressed)"; kill "$wpid" 2>/dev/null; fi
  wait "$wpid" 2>/dev/null
  ln1="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  [ -n "$ln1" ] && ok "watcher emitted IMPLEMENT_RUN_COMPLETE after the pre-relink death" \
    || bad "no IMPLEMENT_RUN_COMPLETE after the pre-relink death (got: $(cat "$out" 2>/dev/null))"
  case "$ln1" in
    *"state=unknown"*) ok "pre-relink death reports state=unknown (stale terminal state suppressed)" ;;
    *) bad "expected state=unknown for a stale latest, got the prior run's state ($ln1)" ;;
  esac
  case "$ln1" in
    *"state=done"*) bad "stale prior-run state=done leaked through the completion read ($ln1)" ;;
    *) ok "stale state=done is not reported (callback will not inspect the wrong run)" ;;
  esac
) || true

( WT="$ROOT/s7b"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  # Same stale prior seeded as arm 1.
  mkdir -p "$WT/repo/docs/tdd/.implement-logs/run0/state.d"
  printf '{"schema":1,"state":"done"}\n' > "$WT/repo/docs/tdd/.implement-logs/run0/state.d/run.json"
  ln -sfn run0 "$WT/repo/docs/tdd/.implement-logs/latest"
  find "$WT/repo/docs/tdd/.implement-logs/run0" -type f -exec touch -d '30 seconds ago' {} \;
  # Arm 2 (control): the build relinks latest to a FRESH terminal run and exits.
  cat > "$WT/scripts/stub.sh" <<'EOF'
#!/usr/bin/env bash
LOGS="$PWD/docs/tdd/.implement-logs"
mkdir -p "$LOGS/run1/state.d"
printf '{"schema":1,"state":"done"}\n' > "$LOGS/run1/state.d/run.json"
ln -sfn run1 "$LOGS/latest"
EOF
  out="$WT/out.txt"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_BUILD_SCRIPT="$WT/scripts/stub.sh" \
      THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=60 \
      bash "$WATCH" >"$out" 2>&1 ) &
  wpid=$!
  i=0; while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$wpid" 2>/dev/null; then bad "watcher still alive after 10s ceiling (PID-gone check regressed)"; kill "$wpid" 2>/dev/null; fi
  wait "$wpid" 2>/dev/null
  ln1="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  case "$ln1" in
    *"state=done"*) ok "control: fresh relink passes the real terminal state=done through" ;;
    *) bad "control: a genuinely-relinked fresh run must report its real state=done, got ($ln1) — over-broad unknown" ;;
  esac
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== watcher-inactivity-completion eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

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
  kill_stub "$out"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== watcher-inactivity-completion eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

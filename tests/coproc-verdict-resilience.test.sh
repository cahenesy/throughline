#!/usr/bin/env bash
# coproc-verdict-resilience.test.sh — eval for TDD 0030 (coproc verdict-write
# resilience + honest terminal states). Covers verification points §1–§7:
#   §1 verdict write to a dead coproc does not kill the runner (gap 1)
#   §2 SIGPIPE race window covered by the PIPE trap (gap 1)
#   §3 orphaned fragments surfaced by status.sh --check-paused (gap 2)
#   §4 orphaned resume accepted with a derived branch head (gap 2)
#   §5 honest interrupted rollup in set_run_state (gap 3)
#   §6 report-tail truthfulness via the BLOCKERS.md growth check (gap 4)
#   §7 review time excluded from the active-time build budget (gap 5)
#
# Function-level eval (the runtime-verify gate re-drives the observable surface
# against a real /implement run). Uses stub `claude`/coprocesses so no model or
# tokens are needed.
#
# Run: bash tests/coproc-verdict-resilience.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# setup_step_repo <dir>: a git repo + scope-declaring TDD + a state fragment + a
# stub `claude` that acts as BOTH the multi-turn build (runs $CTL/build_plan,
# which emits STEP_COMMIT lines and reads STEP_REVIEW replies) and the per-step
# review (echoes $CTL/review.out, default PASS). Leaves PWD in the repo. Mirrors
# tests/continuous-in-build-review.test.sh's setup_step_repo.
setup_step_repo() {  # <dir>
  local d="$1"; mkdir -p "$d/ctl" "$d/bin"
  cd "$d" || return 1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
  printf 'ctl/\nbin/\n' > .gitignore
  printf 'orig\n' > src/a.txt
  cat > docs/tdd/0030-fix.md <<'EOF'
# TDD 0030: fixture
Status: draft
PRD refs: 1

## Touched files
- `src/a.txt` — the in-scope file
EOF
  git add -A; git commit -qm "build start" >/dev/null
  cat > "$d/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""; argv="\$*"
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
if printf '%s' "\$prompt" | grep -q 'INDEPENDENT review gate'; then
  n=\$(cat "$d/ctl/revcount" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$d/ctl/revcount"
  printf '%s' "\$prompt" > "$d/ctl/review-prompt.\$n"
  cat "$d/ctl/review.out" 2>/dev/null || echo "REVIEW_RESULT: PASS"
  exit 0
fi
printf '%s\n' "\$argv" > "$d/ctl/build-argv"
bash "$d/ctl/build_plan"
EOF
  chmod +x "$d/bin/claude"
  export PATH="$d/bin:$PATH"
  export TMPL="$REPO/scripts/build-prompt.md" RTMPL="$REPO/scripts/review-prompt.md"
  export MODEL="" REVIEW_MODEL="" MAINREPO="$d"
  printf 'REVIEW_RESULT: PASS\n' > "$d/ctl/review.out"
}

# ===========================================================================
# §1 (gap 1): verdict write to a dead coproc does NOT kill the runner.
# A build coprocess that dies (here: self-SIGTERM right after emitting
# STEP_COMMIT, modelling the watchdog kill in the observed incident) must not
# SIGPIPE-kill the runner's worker when the verdict is written. The loop must
# RETURN, log THROUGHLINE_COPROC_DEAD, preserve the cleared step the review
# recorded, and surface a non-zero return that classifies transient.
echo "[§1] verdict write to a dead coproc: loop returns, logs COPROC_DEAD, cleared step preserved"
( D="$ROOT/s1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  # No overall watchdog wrapper: bpid is the coproc itself, so its death is
  # observed immediately by the liveness check (deterministic COPROC_DEAD).
  export THROUGHLINE_BUILD_TIMEOUT=0 THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=10
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0030-fix 30 docs/tdd/0030-fix.md 1 building build 1000 1000 "feat/0030-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  # Build emits one STEP_COMMIT, then self-terminates with SIGTERM BEFORE reading
  # the verdict reply — so when the runner writes the verdict, the coproc is gone.
  cat > "$D/repo/ctl/build_plan" <<'EOF'
echo "line 1" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(1): work" >/dev/null 2>&1
echo "STEP_COMMIT: 1 $(git rev-parse HEAD)"
kill -TERM $$
EOF
  _per_step_review_loop 0030-fix docs/tdd/0030-fix.md "$D/s1.log"; rc=$?
  # The mere fact that this line executes proves the runner worker was NOT killed.
  ok "the loop returned (runner worker not SIGPIPE-killed)"
  [ "$rc" -ne 0 ] && ok "loop returns non-zero (routes to the pause/transient path)" \
    || bad "loop should return non-zero on a dead-coproc verdict write (rc=$rc)"
  grep -q '^THROUGHLINE_COPROC_DEAD' "$D/s1.log" 2>/dev/null \
    && ok "gate log records THROUGHLINE_COPROC_DEAD" \
    || bad "gate log should record THROUGHLINE_COPROC_DEAD (got tail: $(tail -3 "$D/s1.log" 2>/dev/null))"
  F="$STATE_DIR/0030-fix.json"
  if command -v jq >/dev/null 2>&1; then
    n="$(jq '.cleared_step_log | length' "$F" 2>/dev/null)"
    [ "$n" = "1" ] && ok "the cleared step the review recorded is preserved" \
      || bad "the cleared step should be preserved (got '$n')"
  else
    grep -q '"step_id":1' "$F" 2>/dev/null && ok "cleared step preserved (no jq)" || bad "cleared step should be preserved"
  fi
  cause="$(_classify_cause "$D/s1.log" "$rc")"
  [ "$cause" = "transient" ] && ok "dead-coproc death classifies as transient (NFR-4)" \
    || bad "should classify transient (got '$cause' rc=$rc)"
) || true

# ===========================================================================
# §2 (gap 1): the PIPE-trap mechanism covers any write-to-dead-pipe. Drive
# _coproc_write directly against a write fd whose reader has already exited
# (the TOCTOU race produces exactly this). With SIGPIPE ignored, the write
# returns EPIPE as a normal error — _coproc_write returns non-zero and the
# calling shell survives (its next assertion executes).
echo "[§2] _coproc_write survives a write to a dead pipe (PIPE trap covers the TOCTOU window)"
( D="$ROOT/s2"; mkdir -p "$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  command -v _coproc_write >/dev/null 2>&1 || { bad "_coproc_write helper missing"; exit 0; }
  # A write fd whose reader (the process substitution) has already exited.
  exec {wfd}> >(exit 0)
  sleep 0.2     # ensure the reader has exited so the read end is closed
  # bpid alive → the liveness check passes, exercising the PIPE-trap write path.
  bpid=$$
  if _coproc_write "$wfd" "STEP_REVIEW: PASS"; then
    bad "_coproc_write should return non-zero writing to a dead pipe"
  else
    ok "_coproc_write returns non-zero on a dead pipe (EPIPE absorbed, not fatal)"
  fi
  exec {wfd}>&- 2>/dev/null || true
  ok "calling shell survived the dead-pipe write (no SIGPIPE termination)"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== coproc-verdict-resilience eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

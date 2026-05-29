#!/usr/bin/env bash
# halt-taxonomy.test.sh — eval for the unified halt-cause taxonomy (TDD 0018 /
# FR-63, FR-64; ADR 0007). Co-located §4b hardening covers issue #30 (FR-29).
#
# The contract:
#   - A closed enum of human-needed halt causes is enforced at the writer level
#     by set_halt_cause (scripts/lib/state.sh). Unknown values are rejected.
#   - Each cause maps deterministically (no model call) to a fixed list of
#     next-action labels written into the fragment as halt_next_actions.
#   - set_halt_cause dual-writes paused_cause for paused-state causes (back-compat
#     with the TDD 0011 renderer) and writes halt_triggering_finding_ref for
#     finding-driven causes.
#   - The run-level state rollup makes `blocked` dominate `paused`.
#   - status.sh renders a one-screen (<=24 lines x <=80 cols) halt context for a
#     halted run: cause label, triggering finding, numbered next actions. The
#     Resume: line appears only for paused-state causes.
#   - _read_fragment_field falls back to paused_cause when asked for a missing
#     halt_cause (reading a TDD-0011-shape fragment).
#   - status.sh --follow widens its stop-signal trap to INT TERM HUP QUIT and
#     accepts a --max-seconds N cap (issue #30).
#
# Run: bash tests/halt-taxonomy.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
STATUS="$REPO/scripts/status.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# --- Obs 1: set_halt_cause for a paused-state cause (ratelimit) --------------
echo "[1] set_halt_cause ratelimit writes halt_cause + dual paused_cause + next-actions"
( D="$ROOT/1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 paused verify-runtime \
    1000 1000 "feat/0007-x" "" "log" "" "" "" "" ""
  set_halt_cause 0007-x ratelimit
  F="$D/state.d/0007-x.json"
  grep -q '"halt_cause":"ratelimit"' "$F" 2>/dev/null \
    && ok "halt_cause=ratelimit" || bad "halt_cause should be ratelimit"
  grep -q '"paused_cause":"ratelimit"' "$F" 2>/dev/null \
    && ok "paused_cause dual-written" || bad "paused_cause should be dual-written to ratelimit"
  grep -q '"halt_next_actions":\["resume now (retries the gate)","wait and resume later"\]' "$F" 2>/dev/null \
    && ok "halt_next_actions for ratelimit correct" \
    || bad "halt_next_actions should be the ratelimit pair (got: $(grep -o '"halt_next_actions":[^]]*]' "$F"))"
) || true

# --- Obs 2: set_halt_cause for a blocked-state cause (structural-finding) ----
echo "[2] set_halt_cause structural-finding writes halt_cause + finding ref + next-actions; no paused_cause"
( D="$ROOT/2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 blocked review \
    1000 1000 "feat/0007-x" "" "log" "" "" "" "" ""
  set_halt_cause 0007-x structural-finding "review-1:3"
  F="$D/state.d/0007-x.json"
  grep -q '"halt_cause":"structural-finding"' "$F" 2>/dev/null \
    && ok "halt_cause=structural-finding" || bad "halt_cause should be structural-finding"
  grep -q '"halt_triggering_finding_ref":"review-1:3"' "$F" 2>/dev/null \
    && ok "halt_triggering_finding_ref recorded" || bad "halt_triggering_finding_ref should be review-1:3"
  grep -q '"paused_cause":null' "$F" 2>/dev/null \
    && ok "paused_cause null for a blocked cause" || bad "paused_cause should be null for structural-finding"
  grep -q '"halt_next_actions":\["revise TDD via /tdd-author","see docs/tdd/BLOCKERS.md"\]' "$F" 2>/dev/null \
    && ok "halt_next_actions for structural-finding correct" \
    || bad "halt_next_actions should be the structural-finding pair (got: $(grep -o '"halt_next_actions":[^]]*]' "$F"))"
) || true

# --- Obs 3: run-level rollup — blocked dominates paused ----------------------
echo "[3] set_run_state: blocked dominates paused in the run-level rollup"
( D="$ROOT/3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=("docs/tdd/0001-a.md" "docs/tdd/0002-b.md")
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0001-a 1 docs/tdd/0001-a.md 1 paused  verify-runtime 1000 1000 "" "" "" "" "ratelimit" "" "" ""
  _write_tdd_fragment 0002-b 2 docs/tdd/0002-b.md 2 blocked review         1000 1000 "" "" "" "" "" "" "" ""
  set_run_state "done"
  R="$D/state.d/run.json"
  grep -q '"state":"blocked"' "$R" 2>/dev/null \
    && ok "run.json state=blocked when a TDD is blocked (dominates paused)" \
    || bad "run.json state should be blocked (got: $(grep -o '"state":"[^"]*"' "$R"))"
) || true

# --- Obs 4 + 5: one-screen halt render (blocked / structural-finding) --------
mk_blocked_fixture() {  # <dir>
  local D="$1"; mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1,"updated_at":2,"pid":1,"integration_branch":"master","mode":"sequential","change":"ci","logdir":"$D","total":1,"completed":0,"failed":0,"blocked":1,"skipped":0,"paused":0,"state":"blocked"}
EOF
  cat > "$D/state.d/0007-x.json" <<EOF
{"n":7,"slug":"0007-x","path":"docs/tdd/0007-x.md","queue_pos":1,"status":"blocked","stage":"review","started_at":1,"updated_at":2,"branch":"feat/0007-x","pr_url":"","log":"","note":"reviewer flagged a cross-module refactor","paused_cause":null,"gates_completed":["test-first","verify","verify-runtime"],"retries":[],"branch_head_at_pause":null,"halt_cause":"structural-finding","halt_triggering_finding_ref":"review-1:3","halt_next_actions":["revise TDD via /tdd-author","see docs/tdd/BLOCKERS.md"],"halt_cause_detail":null}
EOF
}

echo "[4] status.sh halt render fits 24x80 and shows cause + finding ref + numbered actions"
( D="$ROOT/4"; mk_blocked_fixture "$D"
  out="$(bash "$STATUS" --logdir "$D" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "status.sh exits 0 on a halted run" || bad "status.sh should exit 0 (got $rc)"
  lines="$(printf '%s\n' "$out" | awk 'END { print NR }')"
  maxcol="$(printf '%s\n' "$out" | awk '{ if (length > m) m = length } END { print m+0 }')"
  [ "$lines" -le 24 ] && ok "render <=24 lines (got $lines)" || bad "render must be <=24 lines (got $lines)"
  [ "$maxcol" -le 80 ] && ok "render <=80 cols (got $maxcol)" || bad "render must be <=80 cols (got $maxcol)"
  printf '%s\n' "$out" | grep -q 'structural-finding' \
    && ok "render names the cause label" || bad "render should name the cause label"
  printf '%s\n' "$out" | grep -q 'review-1:3' \
    && ok "render shows the triggering finding ref" || bad "render should show the finding ref"
  printf '%s\n' "$out" | grep -qE '1\) revise TDD via /tdd-author' \
    && ok "render lists action 1 on its own numbered line" || bad "render should number action 1"
  printf '%s\n' "$out" | grep -qE '2\) see docs/tdd/BLOCKERS.md' \
    && ok "render lists action 2 on its own numbered line" || bad "render should number action 2"
) || true

echo "[5] status.sh halt render for a non-paused cause omits the Resume: line"
( D="$ROOT/5"; mk_blocked_fixture "$D"
  out="$(bash "$STATUS" --logdir "$D" 2>&1)"
  printf '%s\n' "$out" | grep -qE 'Resume: /implement --resume' \
    && bad "Resume: line must be omitted for a non-paused (blocked) cause" \
    || ok "no Resume: line for structural-finding"
) || true

echo "[5b] status.sh halt render for a paused cause INCLUDES the Resume: line"
( D="$ROOT/5b"; mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1,"updated_at":2,"pid":1,"integration_branch":"master","mode":"sequential","change":"ci","logdir":"$D","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"paused":1,"state":"paused","pause_started_at":3}
EOF
  cat > "$D/state.d/0007-x.json" <<EOF
{"n":7,"slug":"0007-x","path":"docs/tdd/0007-x.md","queue_pos":1,"status":"paused","stage":"verify-runtime","started_at":1,"updated_at":2,"branch":"feat/0007-x","pr_url":"","log":"","note":"","paused_cause":"ratelimit","gates_completed":["test-first","verify"],"retries":[],"branch_head_at_pause":null,"halt_cause":"ratelimit","halt_triggering_finding_ref":null,"halt_next_actions":["resume now (retries the gate)","wait and resume later"],"halt_cause_detail":null}
EOF
  out="$(bash "$STATUS" --logdir "$D" 2>&1)"
  printf '%s\n' "$out" | grep -qE 'Resume: /implement --resume' \
    && ok "Resume: line present for a paused cause" || bad "Resume: line should appear for ratelimit"
  printf '%s\n' "$out" | grep -q 'ratelimit' \
    && ok "render names the paused cause" || bad "render should name ratelimit"
) || true

# --- Obs 6: backward-compat read — halt_cause falls back to paused_cause -----
echo "[6] _read_fragment_field halt_cause falls back to paused_cause on a TDD-0011-shape fragment"
( D="$ROOT/6"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # A TDD-0011-shape fragment: has paused_cause, has NO halt_cause field at all.
  F="$D/state.d/0007-x.json"
  cat > "$F" <<EOF
{"n":7,"slug":"0007-x","path":"docs/tdd/0007-x.md","queue_pos":1,"status":"paused","stage":"verify-runtime","started_at":1,"updated_at":2,"branch":"","pr_url":"","log":"","note":"","paused_cause":"transient","gates_completed":[],"retries":[],"branch_head_at_pause":null}
EOF
  got="$(_read_fragment_field "$F" halt_cause)"
  [ "$got" = "transient" ] \
    && ok "halt_cause read falls back to paused_cause (transient)" \
    || bad "halt_cause should fall back to paused_cause value (got '$got')"
) || true

# --- Obs 7: setter rejects an unknown cause ----------------------------------
echo "[7] set_halt_cause rejects an unknown cause (exit 1, names the value)"
( D="$ROOT/7"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 blocked review \
    1000 1000 "" "" "" "" "" "" "" ""
  err="$(set_halt_cause 0007-x not-a-real-cause 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] && ok "set_halt_cause returns 1 on unknown cause" \
    || bad "set_halt_cause should return 1 on unknown cause (got $rc)"
  printf '%s\n' "$err" | grep -q 'not-a-real-cause' \
    && ok "stderr names the invalid cause" || bad "stderr should name the invalid cause (got: '$err')"
) || true

# --- Obs 8: --follow hardening (issue #30): HUP/QUIT trappable + --max-seconds
echo "[8] status.sh --follow: --max-seconds caps the loop; HUP stops a background watch"
( D="$ROOT/8"; mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1,"updated_at":2,"pid":1,"integration_branch":"master","mode":"sequential","change":"ci","logdir":"$D","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"state":"running"}
EOF
  cat > "$D/state.d/0001-a.json" <<EOF
{"n":1,"slug":"0001-a","path":"docs/tdd/0001-a.md","queue_pos":1,"status":"building","stage":"build","started_at":1,"updated_at":2,"branch":"","pr_url":"","log":"","note":""}
EOF
  # --max-seconds: bounded loop exits 0 on its own, no signal.
  start=$(date +%s)
  bash "$STATUS" --logdir "$D" --follow 1 --max-seconds 2 >/dev/null 2>&1; rc=$?
  dur=$(( $(date +%s) - start ))
  [ "$rc" -eq 0 ] && ok "--max-seconds loop exits 0" || bad "--max-seconds loop should exit 0 (got $rc)"
  [ "$dur" -le 6 ] && ok "--max-seconds loop terminates promptly (~${dur}s)" \
    || bad "--max-seconds loop should terminate near the cap (took ${dur}s)"

  # HUP: a background --follow watch stops on SIGHUP within the watch interval.
  bash "$STATUS" --logdir "$D" --follow 1 >/dev/null 2>&1 &
  pid=$!
  sleep 2
  kill -HUP "$pid" 2>/dev/null || true
  stopped=0
  for _ in 1 2 3 4; do kill -0 "$pid" 2>/dev/null || { stopped=1; break; }; sleep 1; done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
  [ "$stopped" -eq 1 ] && ok "background --follow stops on SIGHUP" \
    || bad "background --follow should stop on SIGHUP (issue #30 trap widening)"
) || true

# --- Skill doc: one-screen contract + watch caveat ---------------------------
echo "[9] skills/implement-status/SKILL.md documents the one-screen contract + watch caveat"
( cd "$REPO"
  F="skills/implement-status/SKILL.md"
  grep -qE '24[x×[:space:]]*80|24 *× *80|fits 24' "$F" 2>/dev/null \
    && ok "skill documents the 24x80 one-screen contract" \
    || bad "skill should document the 24x80 one-screen contract"
  grep -qiE 'kill -TERM|-HUP|SIGINT' "$F" 2>/dev/null \
    && ok "skill documents the --follow background-signal caveat" \
    || bad "skill should document the background --follow signal caveat"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== halt-taxonomy eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

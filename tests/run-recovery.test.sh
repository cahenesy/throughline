#!/usr/bin/env bash
# run-recovery.test.sh — eval for detached `/implement` run recovery & restart
# resilience (TDD 0011 / FR-39..FR-45).
#
# Each block tests one slice from the TDD's "Sequencing / implementation plan",
# so a regression in one step does not mask another.
#
# Many blocks source implement.sh in `THROUGHLINE_SOURCE_ONLY=1` mode (an early-
# return guard the runner declares for testability), so they can call individual
# helpers directly without spinning up a full detached run for every assertion.
#
# Run: bash tests/run-recovery.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
STATUS="$REPO/scripts/status.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# --- Step 1: schema extensions + paused status enum ---------------------------
echo "[1.a] _write_tdd_fragment writes the four additive fields (paused_cause, gates_completed, retries, branch_head_at_pause)"
( D="$ROOT/1a"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "implement.sh must support THROUGHLINE_SOURCE_ONLY guard"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 paused verify-runtime \
    1000 1100 "feat/0007-x" "" "log.txt" "ratelimit" \
    "ratelimit" "test-first,verify" '[{"gate":"verify-runtime","count":1,"backoff_s":30}]' "deadbeefcafe"
  F="$D/state.d/0007-x.json"
  grep -q '"paused_cause":"ratelimit"' "$F" 2>/dev/null \
    && ok "paused_cause field present" || bad "paused_cause should be in fragment"
  grep -q '"gates_completed":\["test-first","verify"\]' "$F" 2>/dev/null \
    && ok "gates_completed array present" || bad "gates_completed array should be in fragment"
  grep -q '"retries":\[{"gate":"verify-runtime","count":1,"backoff_s":30}\]' "$F" 2>/dev/null \
    && ok "retries array present" || bad "retries array should be in fragment"
  grep -q '"branch_head_at_pause":"deadbeefcafe"' "$F" 2>/dev/null \
    && ok "branch_head_at_pause field present" || bad "branch_head_at_pause should be in fragment"
  grep -q '"status":"paused"' "$F" 2>/dev/null \
    && ok "status=paused round-trips" || bad "status=paused should round-trip"
) || true

echo "[1.b] _write_tdd_fragment with empty cause/gates/retries emits null + [] (back-compat)"
( D="$ROOT/1b"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "implement.sh must support THROUGHLINE_SOURCE_ONLY guard"; exit 0; }
  _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 pending "" \
    1000 1000 "" "" "" "" \
    "" "" "" ""
  F="$D/state.d/0001-alpha.json"
  grep -q '"paused_cause":null' "$F" 2>/dev/null \
    && ok "paused_cause null when empty" || bad "paused_cause should be JSON null when empty"
  grep -q '"gates_completed":\[\]' "$F" 2>/dev/null \
    && ok "gates_completed [] when empty" || bad "gates_completed should be []"
  grep -q '"retries":\[\]' "$F" 2>/dev/null \
    && ok "retries [] when empty" || bad "retries should be [] when empty/missing"
  grep -q '"branch_head_at_pause":null' "$F" 2>/dev/null \
    && ok "branch_head_at_pause null when empty" || bad "branch_head_at_pause should be JSON null when empty"
) || true

echo "[1.c] _write_run_fragment accepts paused and stamps pause_started_at"
( D="$ROOT/1c"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "implement.sh must support THROUGHLINE_SOURCE_ONLY guard"; exit 0; }
  _write_run_fragment paused
  R="$D/state.d/run.json"
  grep -q '"state":"paused"' "$R" 2>/dev/null \
    && ok "run.json state=paused" || bad "run.json should accept state=paused"
  grep -qE '"pause_started_at":[0-9]+' "$R" 2>/dev/null \
    && ok "pause_started_at stamped" || bad "pause_started_at should be stamped"
) || true

echo "[1.d] status.sh renders an unfamiliar status without crashing"
( D="$ROOT/1d"; mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1,"updated_at":2,"pid":1,"integration_branch":"main","mode":"sequential","change":"ci","logdir":"$D","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"state":"paused","pause_started_at":3}
EOF
  cat > "$D/state.d/0001-alpha.json" <<EOF
{"n":1,"slug":"0001-alpha","path":"docs/tdd/0001-alpha.md","queue_pos":1,"status":"paused","stage":"verify-runtime","started_at":1,"updated_at":2,"branch":"","pr_url":"","log":"","note":"","paused_cause":"ratelimit","gates_completed":["test-first","verify"],"retries":[],"branch_head_at_pause":null}
EOF
  out="$(bash "$STATUS" --logdir "$D" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "status.sh exits 0 on a paused fragment" || bad "status.sh should exit 0 (got $rc)"
  printf '%s\n' "$out" | grep -qi 'paused' \
    && ok "status.sh names the paused status" || bad "status.sh should print the paused status"
) || true

# --- Step 2: _classify_cause + _recoverable_patterns -------------------------
echo "[2.a] _classify_cause maps each documented stderr pattern to its cause"
( D="$ROOT/2a"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  L="$D/log"

  printf 'foo bar ratelimit_error here\n' > "$L"
  [ "$(_classify_cause "$L" 0)" = "ratelimit" ] && ok "ratelimit pattern -> ratelimit" \
    || bad "ratelimit pattern should classify as ratelimit (got '$(_classify_cause "$L" 0)')"

  printf 'HTTP/1.1 429 Too Many Requests\n' > "$L"
  [ "$(_classify_cause "$L" 0)" = "ratelimit" ] && ok "429 -> ratelimit" \
    || bad "429 should classify as ratelimit"

  printf 'monthly-limit-reached for opus\n' > "$L"
  [ "$(_classify_cause "$L" 0)" = "usage-limit" ] && ok "monthly-limit-reached -> usage-limit" \
    || bad "monthly-limit should classify as usage-limit"

  printf 'connection reset by peer\n' > "$L"
  [ "$(_classify_cause "$L" 0)" = "transient" ] && ok "connection reset -> transient" \
    || bad "connection reset should classify as transient"

  printf '503 Service Unavailable\n' > "$L"
  [ "$(_classify_cause "$L" 0)" = "transient" ] && ok "503 -> transient" \
    || bad "503 should classify as transient"

  printf 'some unrelated message\n' > "$L"
  [ "$(_classify_cause "$L" 0)" = "fatal" ] && ok "unmatched -> fatal (NFR-4)" \
    || bad "unmatched stderr should classify as fatal (NFR-4 conservatism)"
) || true

echo "[2.b] _classify_cause uses exit-signal table: SIGTERM transient, SIGKILL fatal"
( D="$ROOT/2b"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  L="$D/log"; : > "$L"
  # 128+15 SIGTERM
  [ "$(_classify_cause "$L" 143)" = "transient" ] && ok "exit=143 (SIGTERM) -> transient" \
    || bad "SIGTERM exit should classify as transient"
  # 128+9 SIGKILL
  [ "$(_classify_cause "$L" 137)" = "fatal" ] && ok "exit=137 (SIGKILL) -> fatal" \
    || bad "SIGKILL exit should classify as fatal"
  # generic non-zero exit with clean log -> fatal
  [ "$(_classify_cause "$L" 2)" = "fatal" ] && ok "exit=2 clean log -> fatal" \
    || bad "non-zero exit with clean log should classify as fatal"
) || true

# --- Step 3: _retry_in_gate + _enter_paused ----------------------------------
echo "[3.a] _retry_in_gate retries transient until success and records each retry"
( D="$ROOT/3a"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 building build \
    1000 1000 "" "" "log" "" "" "" "" ""

  COUNTER_FILE="$D/calls"; printf '0\n' > "$COUNTER_FILE"
  my_gate_fn() {  # writes the supplied log; returns 0 only on the 3rd call
    local logfile="$1"
    local n; n=$(cat "$COUNTER_FILE"); n=$((n+1)); printf '%s\n' "$n" > "$COUNTER_FILE"
    if [ "$n" -lt 3 ]; then
      printf 'simulated 429 ratelimit\n' >> "$logfile"
      return 1
    fi
    return 0
  }
  L="$D/3a.log"; : > "$L"
  # Override backoff so the test does not block on real sleeps.
  THROUGHLINE_GATE_RETRIES=3 THROUGHLINE_GATE_BACKOFF_BASE=0 \
    _retry_in_gate my_gate_fn build 0007-x "$L" "$L"
  rc=$?
  [ "$rc" -eq 0 ] && ok "_retry_in_gate returns 0 on eventual success" \
    || bad "_retry_in_gate should return 0 after a successful retry (rc=$rc)"
  F="$D/state.d/0007-x.json"
  count="$(grep -oE '"count":[0-9]+' "$F" | wc -l)"
  [ "$count" -ge 2 ] && ok "retries[] records each retry (count=$count)" \
    || bad "retries[] should record both transient retries (count=$count)"
) || true

echo "[3.b] _retry_in_gate exhausts budget -> _enter_paused, returns 2"
( D="$ROOT/3b"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 building verify-runtime \
    1000 1000 "" "" "log" "" "" "" "" ""
  my_gate_fn() {
    local logfile="$1"
    printf 'simulated 429 ratelimit\n' >> "$logfile"
    return 1
  }
  L="$D/3b.log"; : > "$L"
  THROUGHLINE_GATE_RETRIES=3 THROUGHLINE_GATE_BACKOFF_BASE=0 \
    _retry_in_gate my_gate_fn verify-runtime 0007-x "$L" "$L"
  rc=$?
  [ "$rc" -eq 2 ] && ok "_retry_in_gate returns 2 on exhausted retries (paused signal)" \
    || bad "_retry_in_gate should return 2 when retries exhaust (rc=$rc)"
  F="$D/state.d/0007-x.json"
  grep -q '"status":"paused"' "$F" \
    && ok "TDD fragment is paused after exhaustion" || bad "fragment should be paused"
  grep -q '"paused_cause":"ratelimit"' "$F" \
    && ok "paused_cause=ratelimit" || bad "paused_cause should be ratelimit"
) || true

echo "[3.c] _retry_in_gate on fatal cause does NOT retry; returns 1, no paused"
( D="$ROOT/3c"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 building verify-runtime \
    1000 1000 "" "" "log" "" "" "" "" ""
  COUNTER_FILE="$D/calls"; printf '0\n' > "$COUNTER_FILE"
  my_gate_fn() {
    local logfile="$1"
    local n; n=$(cat "$COUNTER_FILE"); n=$((n+1)); printf '%s\n' "$n" > "$COUNTER_FILE"
    printf 'unmatched fatal output\n' >> "$logfile"
    return 1
  }
  L="$D/3c.log"; : > "$L"
  THROUGHLINE_GATE_RETRIES=3 THROUGHLINE_GATE_BACKOFF_BASE=0 \
    _retry_in_gate my_gate_fn verify-runtime 0007-x "$L" "$L"
  rc=$?
  [ "$rc" -eq 1 ] && ok "_retry_in_gate returns 1 on fatal (not 2)" \
    || bad "_retry_in_gate fatal path should return 1 (rc=$rc)"
  n="$(cat "$COUNTER_FILE")"
  [ "$n" -eq 1 ] && ok "no retry on fatal (gate-fn called exactly once)" \
    || bad "fatal should not retry (calls=$n)"
  F="$D/state.d/0007-x.json"
  grep -q '"status":"paused"' "$F" \
    && bad "fragment must not be paused on fatal" \
    || ok "TDD fragment NOT paused on fatal"
) || true

# --- Step 4: _resume_from + driver halt-on-paused ----------------------------
echo "[4.a] _resume_from populates RESUME_GATES_DONE_<slug> from gates_completed when build branch HEAD matches"
( D="$ROOT/4a"; mkdir -p "$D/state.d"
  # Stand up a tiny git repo with a `test(failing):` commit on the build branch
  # so the build-history source-of-truth says gate 1 is done.
  REPO_T="$D/repo"
  mkdir -p "$REPO_T" && cd "$REPO_T"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'base\n' > base.txt; git add -A; git commit -qm base
  git checkout -q -b feat/0007-x
  printf 'test\n' > test.txt; git add -A; git commit -qm "test(failing): 0007-x"
  printf 'impl\n' > impl.txt; git add -A; git commit -qm "stub build 0007-x"
  BRANCH_HEAD="$(git rev-parse HEAD)"

  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=("docs/tdd/0007-x.md")
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 paused verify-runtime \
    1000 1000 "feat/0007-x" "" "log" "paused (ratelimit)" \
    "ratelimit" "test-first,verify" "[]" "$BRANCH_HEAD"

  # _resume_from sets a per-slug shell var listing the gates already done.
  _resume_from 0007-x
  rkey="RESUME_GATES_DONE_0007_x"
  done_list="${!rkey:-}"
  printf '%s' "$done_list" | grep -q 'build' \
    && ok "build gate marked done (test(failing): commit present)" \
    || bad "build gate should be marked done (got: '$done_list')"
  printf '%s' "$done_list" | grep -q 'test-first' \
    && ok "test-first gate carried forward" || bad "test-first should be in done list (got: '$done_list')"
  printf '%s' "$done_list" | grep -q 'verify' \
    && ok "ci-checks gate carried forward" || bad "ci-checks should be in done list (got: '$done_list')"
  printf '%s' "$done_list" | grep -q 'verify-runtime' \
    && bad "verify-runtime must NOT be marked done (it was in-flight at pause)" \
    || ok "verify-runtime correctly NOT marked done (was in-flight)"
  printf '%s' "$done_list" | grep -q 'review' \
    && bad "review must NOT be marked done" \
    || ok "review correctly NOT marked done"
) || true

echo "[4.b] _resume_from refuses to resume when build branch HEAD diverges -> paused_cause=resume-blocked-branch-divergence"
( D="$ROOT/4b"; mkdir -p "$D/state.d"
  REPO_T="$D/repo"; mkdir -p "$REPO_T" && cd "$REPO_T"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'base\n' > base.txt; git add -A; git commit -qm base
  git checkout -q -b feat/0007-x
  printf 'test\n' > test.txt; git add -A; git commit -qm "test(failing): 0007-x"

  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=("docs/tdd/0007-x.md")
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 paused verify-runtime \
    1000 1000 "feat/0007-x" "" "log" "paused (ratelimit)" \
    "ratelimit" "test-first,verify" "[]" "STALE_HEAD_FROM_PRIOR_RUN_abcdef"

  _resume_from 0007-x
  F="$STATE_DIR/0007-x.json"
  grep -q 'resume-blocked-branch-divergence' "$F" \
    && ok "paused_cause updated to resume-blocked-branch-divergence" \
    || bad "paused_cause should be resume-blocked-branch-divergence"
  rkey="RESUME_GATES_DONE_0007_x"
  [ -z "${!rkey:-}" ] && ok "RESUME_GATES_DONE_<slug> not populated (refuse-to-resume)" \
    || bad "RESUME_GATES_DONE should not be populated on divergence (got: '${!rkey:-}')"
) || true

echo "[4.c] _resume_from refuses when build branch has no test(failing): commit"
( D="$ROOT/4c"; mkdir -p "$D/state.d"
  REPO_T="$D/repo"; mkdir -p "$REPO_T" && cd "$REPO_T"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'base\n' > base.txt; git add -A; git commit -qm base
  # No build branch / no test(failing): commit anywhere
  BRANCH_HEAD="$(git rev-parse HEAD)"

  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=("docs/tdd/0007-x.md")
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 paused build \
    1000 1000 "" "" "log" "paused (ratelimit)" \
    "ratelimit" "" "[]" "$BRANCH_HEAD"

  _resume_from 0007-x
  F="$STATE_DIR/0007-x.json"
  grep -q 'resume-blocked-build-state-missing' "$F" \
    && ok "paused_cause updated to resume-blocked-build-state-missing" \
    || bad "paused_cause should be resume-blocked-build-state-missing"
) || true

# --- Step 5: status.sh renderer extensions + --check-paused ------------------
echo "[5.a] status.sh --check-paused prints one line per paused fragment"
( D="$ROOT/5a"; mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1,"updated_at":2,"pid":1,"integration_branch":"main","mode":"sequential","change":"ci","logdir":"$D","total":2,"completed":0,"failed":0,"blocked":0,"skipped":0,"state":"paused","pause_started_at":3}
EOF
  cat > "$D/state.d/0001-alpha.json" <<EOF
{"n":1,"slug":"0001-alpha","path":"docs/tdd/0001-alpha.md","queue_pos":1,"status":"paused","stage":"verify-runtime","started_at":1,"updated_at":2,"branch":"","pr_url":"","log":"","note":"","paused_cause":"ratelimit","gates_completed":["test-first","verify"],"retries":[],"branch_head_at_pause":null}
EOF
  cat > "$D/state.d/0002-beta.json" <<EOF
{"n":2,"slug":"0002-beta","path":"docs/tdd/0002-beta.md","queue_pos":2,"status":"pending","stage":null,"started_at":1,"updated_at":1,"branch":"","pr_url":"","log":"","note":"","paused_cause":null,"gates_completed":[],"retries":[],"branch_head_at_pause":null}
EOF
  out="$(bash "$STATUS" --logdir "$D" --check-paused 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "--check-paused exits 0" || bad "--check-paused should exit 0 (got $rc)"
  printf '%s\n' "$out" | grep -qE '^slug=0001-alpha gate=verify-runtime cause=ratelimit$' \
    && ok "--check-paused emits machine-parseable line" \
    || bad "--check-paused should print 'slug=0001-alpha gate=verify-runtime cause=ratelimit'"
  count="$(printf '%s\n' "$out" | grep -c '^slug=')"
  [ "$count" -eq 1 ] && ok "--check-paused prints exactly one line per paused TDD" \
    || bad "--check-paused should print only the paused fragment (got $count lines)"
) || true

echo "[5.b] status.sh --check-paused on a clean run prints nothing"
( D="$ROOT/5b"; mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1,"updated_at":2,"pid":1,"integration_branch":"main","mode":"sequential","change":"ci","logdir":"$D","total":1,"completed":1,"failed":0,"blocked":0,"skipped":0,"state":"done"}
EOF
  cat > "$D/state.d/0001-alpha.json" <<EOF
{"n":1,"slug":"0001-alpha","path":"docs/tdd/0001-alpha.md","queue_pos":1,"status":"done","stage":null,"started_at":1,"updated_at":2,"branch":"","pr_url":"","log":"","note":"","paused_cause":null,"gates_completed":["test-first","verify","verify-runtime","review"],"retries":[],"branch_head_at_pause":null}
EOF
  out="$(bash "$STATUS" --logdir "$D" --check-paused 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "--check-paused on done run exits 0" || bad "--check-paused done-run should exit 0"
  [ -z "$out" ] && ok "--check-paused on done run prints nothing" \
    || bad "--check-paused should print nothing for a done run (got: '$out')"
) || true

# TDD 0018 / FR-64: a paused run is a halt state, so the snapshot now renders
# the one-screen halt context (cause + triggering finding + next actions +
# Resume: line) instead of the TDD-0011 table-plus-trailer. FR-45 semantics are
# preserved — the output still names "paused", the recoverable cause, and an
# instruction to resume — but the exact strings changed (superseded format).
echo "[5.c] status.sh snapshot shows the one-screen paused halt context (FR-45 via FR-64)"
( D="$ROOT/5c"; mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1,"updated_at":2,"pid":1,"integration_branch":"main","mode":"sequential","change":"ci","logdir":"$D","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"state":"paused","pause_started_at":3}
EOF
  # Post-0018 paused fragment: _enter_paused now also records halt_cause +
  # halt_next_actions via set_halt_cause, so a live paused run carries them.
  cat > "$D/state.d/0007-x.json" <<EOF
{"n":7,"slug":"0007-x","path":"docs/tdd/0007-x.md","queue_pos":1,"status":"paused","stage":"verify-runtime","started_at":1,"updated_at":2,"branch":"feat/0007-x","pr_url":"","log":"","note":"","paused_cause":"ratelimit","gates_completed":["test-first","verify"],"retries":[],"branch_head_at_pause":null,"halt_cause":"ratelimit","halt_triggering_finding_ref":null,"halt_next_actions":["resume now (retries the gate)","wait and resume later"],"halt_cause_detail":null}
EOF
  out="$(bash "$STATUS" --logdir "$D" 2>&1)"
  printf '%s\n' "$out" | grep -qE 'paused' \
    && ok "snapshot prints 'paused'" || bad "snapshot should print paused"
  printf '%s\n' "$out" | grep -qE 'ratelimit' \
    && ok "snapshot names the cause" || bad "snapshot should name the cause"
  printf '%s\n' "$out" | grep -qE 'Resume: /implement --resume' \
    && ok "snapshot prints the resume instruction (one-screen halt context)" \
    || bad "snapshot should print 'Resume: /implement --resume <runid>'"
  printf '%s\n' "$out" | grep -qE 'resume now \(retries the gate\)' \
    && ok "snapshot lists the paused-cause next actions" \
    || bad "snapshot should list the ratelimit next-action options"
) || true

# --- iter-4 BLOCKER-1: combined-mode resume re-runs gate 1 -------------------
echo "[4.d] _resume_from in combined mode skips gate-1 done-list (force re-run)"
( D="$ROOT/4d"; mkdir -p "$D/state.d"
  REPO_T="$D/repo"; mkdir -p "$REPO_T" && cd "$REPO_T"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'base\n' > base.txt; git add -A; git commit -qm base
  # In combined mode, ALL TDDs share the same $CHANGE branch — but no
  # per-TDD test(failing): commits are required for resume to succeed.
  git checkout -q -b ci
  # Simulate two TDDs already partially built: one fully (with a
  # test(failing): commit), one just starting.
  printf 'test-a\n' > test-a.txt; git add -A; git commit -qm "test(failing): 0001-alpha"
  printf 'impl-a\n' > impl-a.txt; git add -A; git commit -qm "stub build 0001-alpha"
  BRANCH_HEAD="$(git rev-parse HEAD)"

  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="combined"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" COMBINED=1
  TDDS=("docs/tdd/0002-beta.md")
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # 0002-beta has no test(failing): commit on the branch (its turn was
  # interrupted before gate 1 finished). In non-combined mode this would
  # be refused. In combined mode it should resume; gate-1 will re-run.
  _write_tdd_fragment 0002-beta 2 docs/tdd/0002-beta.md 1 paused build \
    1000 1000 "ci" "" "log" "paused (ratelimit)" \
    "ratelimit" "" "[]" "$BRANCH_HEAD"

  _resume_from 0002-beta
  rrc=$?
  [ "$rrc" -ne 3 ] && ok "combined-mode resume does NOT refuse with rc=3 (got $rrc)" \
    || bad "combined-mode resume should NOT refuse (rc=3 means BLOCKER-1 regression)"
  rkey="RESUME_GATES_DONE_0002_beta"
  done_list="${!rkey:-}"
  # done_list MUST be empty for combined mode — gate 1 must re-run.
  [ -z "$done_list" ] && ok "combined-mode done_list omits 'build' so gate 1 re-runs" \
    || bad "combined-mode done_list should be empty (got: '$done_list')"
) || true

# --- iter-5 BLOCKER-1+2: resume restores CHANGE/PARALLEL/COMBINED ---------
echo "[8.a] state_init resume branch restores CHANGE / PARALLEL / COMBINED from run.json"
( D="$ROOT/8a"; mkdir -p "$D/state.d"
  # Write a fake paused run with parallel mode + non-default change.
  printf '{"schema":1,"started_at":1,"updated_at":2,"pid":0,"integration_branch":"master","mode":"parallel","change":"build/20260101-000000","logdir":"%s","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"paused":1,"state":"paused","pause_started_at":2}\n' "$D" > "$D/state.d/run.json"
  printf '{"n":1,"slug":"0001-alpha","path":"docs/tdd/0001-alpha.md","queue_pos":1,"status":"paused","stage":"build","started_at":1,"updated_at":2,"branch":"feat/0001-alpha","pr_url":"","log":"","note":"paused","paused_cause":"ratelimit","gates_completed":[],"retries":[],"branch_head_at_pause":null}\n' > "$D/state.d/0001-alpha.json"
  ln -sfn "$D" "$D/../latest" 2>/dev/null || true
  # state_init reads STATE_DIR/run.json; simulate the runner-init values
  # the resume branch is supposed to restore.
  ( cd "$D"
    export THROUGHLINE_SOURCE_ONLY=1
    # shellcheck disable=SC1090
    source "$IMPL"
    LOGDIR="$D"; STATE_DIR="$D/state.d"; REPORT="$D/report.md"
    INTEGRATION="master"; MAINREPO="$D"; mkdir -p "$D/docs/tdd/.implement-logs"
    RESUME=1; PARALLEL=0; COMBINED=0
    CHANGE="build/$(date +%Y%m%d-%H%M%S)"   # default-format value
    TDDS=("docs/tdd/0001-alpha.md")
    state_init
    [ "$CHANGE" = "build/20260101-000000" ] && ok "CHANGE restored from run.json" \
      || bad "CHANGE should restore from run.json (got '$CHANGE')"
    [ "$PARALLEL" -eq 1 ] && ok "PARALLEL flag set from mode=parallel" \
      || bad "PARALLEL should be 1 (got $PARALLEL)"
    [ "$COMBINED" -eq 0 ] && ok "COMBINED stays 0 for parallel mode" \
      || bad "COMBINED should be 0 (got $COMBINED)"
  )
) || true

echo "[8.b] state_init resume branch maps mode=combined to COMBINED=1"
( D="$ROOT/8b"; mkdir -p "$D/state.d"
  printf '{"schema":1,"started_at":1,"updated_at":2,"pid":0,"integration_branch":"master","mode":"combined","change":"ci-change","logdir":"%s","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"paused":1,"state":"paused","pause_started_at":2}\n' "$D" > "$D/state.d/run.json"
  printf '{"n":1,"slug":"0001-alpha","path":"docs/tdd/0001-alpha.md","queue_pos":1,"status":"paused","stage":"build","started_at":1,"updated_at":2,"branch":"ci-change","pr_url":"","log":"","note":"paused","paused_cause":"ratelimit","gates_completed":[],"retries":[],"branch_head_at_pause":null}\n' > "$D/state.d/0001-alpha.json"
  ( cd "$D"
    export THROUGHLINE_SOURCE_ONLY=1
    # shellcheck disable=SC1090
    source "$IMPL"
    LOGDIR="$D"; STATE_DIR="$D/state.d"; REPORT="$D/report.md"
    INTEGRATION="master"; MAINREPO="$D"; mkdir -p "$D/docs/tdd/.implement-logs"
    RESUME=1; PARALLEL=0; COMBINED=0
    CHANGE="build/$(date +%Y%m%d-%H%M%S)"
    TDDS=("docs/tdd/0001-alpha.md")
    state_init
    [ "$COMBINED" -eq 1 ] && ok "COMBINED=1 for mode=combined" \
      || bad "COMBINED should be 1 for combined mode (got $COMBINED)"
    [ "$PARALLEL" -eq 0 ] && ok "PARALLEL stays 0 for combined mode" \
      || bad "PARALLEL should be 0 (got $PARALLEL)"
    [ "$CHANGE" = "ci-change" ] && ok "CHANGE restored to ci-change" \
      || bad "CHANGE should be ci-change (got '$CHANGE')"
  )
) || true

# --- iter-3 BLOCKER-1: schema-version refusal gate -------------------------
echo "[7.a] state_init refuses to resume across an incompatible schema"
( cd "$REPO"
  # Create a fake paused run with schema=2 and assert the runner refuses.
  TMP="$(mktemp -d)"
  STATE_D="$TMP/state.d"
  mkdir -p "$STATE_D"
  LATEST_LINK="$TMP/latest"
  # Minimal run.json with schema:2 — the only field state_init's gate
  # reads at the refusal step.
  printf '{"schema":2,"started_at":1,"updated_at":1,"pid":0,"integration_branch":"master","mode":"sequential","change":"x","logdir":"%s","total":0,"completed":0,"failed":0,"blocked":0,"skipped":0,"paused":0,"state":"paused","pause_started_at":1}\n' "$TMP" > "$STATE_D/run.json"
  ln -sfn "$TMP" "$LATEST_LINK"
  # Source the script and call state_init under RESUME=1; capture the message + exit code.
  OUT="$TMP/out"; ERR="$TMP/err"
  ( export THROUGHLINE_SOURCE_ONLY=1
    # shellcheck disable=SC1090
    source "$REPO/scripts/implement.sh"
    LOGDIR="$TMP"; STATE_DIR="$STATE_D"; RESUME=1; REPORT="$TMP/report.md"; TDDS=()
    state_init >"$OUT" 2>"$ERR"
  ) ; rc=$?
  if [ "$rc" -ne 0 ] && grep -qE "paused-run schema '?2'? not compatible" "$OUT" "$ERR" 2>/dev/null; then
    ok "schema=2 paused run is refused with the spec'd message + non-zero exit"
  else
    bad "schema=2 should refuse resume with TDD 0011 §schema-version policy message (rc=$rc, out=$(cat "$OUT" "$ERR" 2>/dev/null | head -1))"
  fi
  rm -rf "$TMP"
) || true

# --- iter-6 MAJOR-3: empty/absent schema also refuses (a missing schema is NOT schema 1) ---
echo "[7.b] state_init refuses to resume when run.json has no schema field"
( cd "$REPO"
  TMP="$(mktemp -d)"
  STATE_D="$TMP/state.d"
  mkdir -p "$STATE_D"
  # run.json WITHOUT a schema field (e.g., truncated state record).
  printf '{"started_at":1,"updated_at":1,"pid":0,"integration_branch":"master","mode":"sequential","change":"x","logdir":"%s","total":0,"completed":0,"failed":0,"blocked":0,"skipped":0,"paused":0,"state":"paused","pause_started_at":1}\n' "$TMP" > "$STATE_D/run.json"
  OUT="$TMP/out"; ERR="$TMP/err"
  ( export THROUGHLINE_SOURCE_ONLY=1
    # shellcheck disable=SC1090
    source "$REPO/scripts/implement.sh"
    LOGDIR="$TMP"; STATE_DIR="$STATE_D"; RESUME=1; REPORT="$TMP/report.md"; TDDS=()
    state_init >"$OUT" 2>"$ERR"
  ) ; rc=$?
  if [ "$rc" -ne 0 ] && grep -qE "paused-run schema '?(missing|)'? not compatible" "$OUT" "$ERR" 2>/dev/null; then
    ok "empty-schema paused run is refused"
  else
    bad "empty schema should refuse (rc=$rc, out=$(cat "$OUT" "$ERR" 2>/dev/null | head -1))"
  fi
  rm -rf "$TMP"
) || true

# --- Step 6: skill's "Detect interrupted run" step ---------------------------
echo "[6.a] skills/implement/SKILL.md documents --check-paused and conditional --resume"
( cd "$REPO"
  F="skills/implement/SKILL.md"
  grep -q -- '--check-paused' "$F" \
    && ok "skill mentions --check-paused" || bad "skill should mention --check-paused"
  grep -q -- '--resume' "$F" \
    && ok "skill mentions --resume on the launch line" \
    || bad "skill should mention --resume on the launch line"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== run-recovery eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

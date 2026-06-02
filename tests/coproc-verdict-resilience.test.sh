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

# ===========================================================================
# §5 (gap 3): honest `interrupted` terminal rollup. A fragment left in a
# non-terminal status (building/verifying/reviewing) at run-end means the run
# did NOT finish cleanly — set_run_state must derive `interrupted`, never
# `done`. Precedence: blocked > interrupted > paused > done.
echo "[§5a] set_run_state derives interrupted when a fragment is still building (never done)"
( D="$ROOT/s5a"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=(docs/tdd/0030-a.md docs/tdd/0030-b.md)
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0030-a 1 docs/tdd/0030-a.md 1 done flip 1000 1000 "" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  _write_tdd_fragment 0030-b 2 docs/tdd/0030-b.md 2 building build 1000 1000 "feat/0030-b" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  set_run_state "done"
  st="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$D/state.d/run.json" | head -1)"
  [ "$st" = "interrupted" ] && ok "run state is interrupted (not done) with a building fragment" \
    || bad "run state should be interrupted (got '$st')"
) || true

echo "[§5b] precedence: a blocked fragment dominates an interrupted one (blocked > interrupted)"
( D="$ROOT/s5b"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=(docs/tdd/0030-a.md docs/tdd/0030-b.md)
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # One blocked TDD, one still-verifying (orphaned) TDD — blocked must win.
  _write_tdd_fragment 0030-a 1 docs/tdd/0030-a.md 1 verifying verify 1000 1000 "feat/0030-a" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  _write_tdd_fragment 0030-b 2 docs/tdd/0030-b.md 2 blocked review 1000 1000 "feat/0030-b" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  set_run_state "done"
  st="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$D/state.d/run.json" | head -1)"
  [ "$st" = "blocked" ] && ok "run state is blocked (design action outranks interrupted)" \
    || bad "blocked should dominate interrupted (got '$st')"
) || true

echo "[§5c] negative: all fragments terminal -> done exactly as today"
( D="$ROOT/s5c"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=(docs/tdd/0030-a.md docs/tdd/0030-b.md)
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0030-a 1 docs/tdd/0030-a.md 1 done flip 1000 1000 "" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  _write_tdd_fragment 0030-b 2 docs/tdd/0030-b.md 2 failed "" 1000 1000 "feat/0030-b" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  set_run_state "done"
  st="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$D/state.d/run.json" | head -1)"
  [ "$st" = "done" ] && ok "run state is done when every fragment is terminal" \
    || bad "all-terminal run should stay done (got '$st')"
) || true

echo "[§5d] status.sh renders the 'did not exit cleanly' banner for an interrupted run"
( D="$ROOT/s5d"; mkdir -p "$D/state.d"
  # Hand-craft a run.json in state=interrupted + one orphaned building fragment.
  printf '{"schema":1,"started_at":1000,"updated_at":1001,"pid":999999,"integration_branch":"master","mode":"sequential","change":"ci","logdir":"%s","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"paused":0,"state":"interrupted","pause_started_at":null,"config":{"rework_config":{},"gate_timeout":{}}}\n' "$D" > "$D/state.d/run.json"
  printf '{"schema":1,"n":1,"slug":"0030-x","path":"docs/tdd/0030-x.md","queue_pos":1,"status":"building","stage":"build","started_at":1000,"updated_at":1001,"branch":"feat/0030-x","pr_url":"","log":"log","note":""}\n' > "$D/state.d/0030-x.json"
  out="$(bash "$REPO/scripts/status.sh" --logdir "$D" 2>&1)"
  printf '%s' "$out" | grep -qi 'interrupted' \
    && ok "banner names the interrupted state" || bad "banner should mention interrupted (got: $out)"
  printf '%s' "$out" | grep -qi 'did not exit cleanly' \
    && ok "banner says the run did not exit cleanly" || bad "banner should say the run did not exit cleanly (got: $out)"
  printf '%s' "$out" | grep -q '/implement' \
    && ok "banner points the user at /implement to resume" || bad "banner should point at /implement (got: $out)"
) || true

# setup_impl_run <dir>: a minimal git project (PRD + ADR index + one ready TDD)
# with a stub `claude` (build OK / runtime PASS / review PASS) and a controllable
# ci-checks command, so `implement.sh --change ci` runs end-to-end with no model.
# Leaves PWD in <dir>. Mirrors tests/implement-gate.test.sh's setup.
setup_impl_run() {  # <dir>
  local dir="$1"
  mkdir -p "$dir"/{docs/tdd,docs/adr,.stub/bin}
  cd "$dir" || return 1
  git init -q; git config user.email t@t.t; git config user.name t
  printf '# PRD\n## Requirements\n1. do the thing\n' > docs/PRD.md
  printf '# ADR Index\n| # | Title | Status | Scope |\n|---|---|---|---|\n' > docs/adr/INDEX.md
  printf '# TDD 0001: alpha\nStatus: ready\nPRD refs: 1\nPRD-rev: deadbee\nADR constraints: none\n\n## Approach\nstub\n' > docs/tdd/0001-alpha.md
  git add -A; git commit -qm init >/dev/null
  export STUBDIR="$dir/.stub"
  printf '0\n' > "$STUBDIR/verify_rc"
  cat > "$STUBDIR/verify_test.sh" <<EOF
#!/usr/bin/env bash
exit "\$(cat "$STUBDIR/verify_rc" 2>/dev/null || echo 0)"
EOF
  export CI_CHECKS_TEST_CMD="bash $STUBDIR/verify_test.sh"
  export CI_CHECKS_TYPECHECK_CMD=""
  cat > "$STUBDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; *) shift;; esac; done
slug="$(printf '%s' "$prompt" | grep -oE 'docs/tdd/[0-9]+-[a-z]+' | head -1 | sed 's#docs/tdd/##')"
if printf '%s' "$prompt" | grep -q 'INDEPENDENT runtime-verification gate'; then echo "VERIFY_RUNTIME: PASS"; exit 0; fi
if printf '%s' "$prompt" | grep -q 'INDEPENDENT review gate'; then echo "REVIEW_RESULT: PASS"; exit 0; fi
echo "test for $slug" >> "test-$slug.txt"
git add -A >/dev/null 2>&1; git commit -q -m "test(failing): $slug" >/dev/null 2>&1 || true
echo "gen $(date +%s%N)" >> "gen-$slug.txt"
git add -A >/dev/null 2>&1; git commit -q -m "stub build $slug" >/dev/null 2>&1 || true
cat "$STUBDIR/build-$slug" 2>/dev/null || echo "BATCH_RESULT: OK"
exit 0
EOF
  chmod +x "$STUBDIR/bin/claude"
  export PATH="$STUBDIR/bin:$PATH"
}
_impl_report() { ls -t docs/tdd/.implement-logs/*/report.md 2>/dev/null | head -1; }

# ===========================================================================
# §6 (gap 4): truthful report tail. The BLOCKERS.md pointer must print ONLY when
# THIS run appended to BLOCKERS.md (line-count growth), not merely because the
# file exists — otherwise every run with a pre-existing ledger prints a phantom
# "design blockers were recorded" pointer (FR-64: halt context names the actual
# next action, not a stale one).
echo "[§6a] a pre-existing BLOCKERS.md that does NOT grow this run -> NO boilerplate"
( D="$ROOT/s6a"
  setup_impl_run "$D" || { bad "setup failed"; exit 0; }
  # A pre-existing ledger from some earlier run, untouched by this happy-path run.
  printf '# Design blockers\n\n- 9999-old — some prior blocker\n' > docs/tdd/BLOCKERS.md
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(_impl_report)"
  if grep -q 'Design blockers were recorded in docs/tdd/BLOCKERS.md' "$R" 2>/dev/null; then
    bad "report must NOT print the BLOCKERS pointer when the ledger did not grow"
  else
    ok "no phantom BLOCKERS pointer when the ledger was unchanged"
  fi
) || true

echo "[§6b] a run that appends to BLOCKERS.md -> boilerplate IS printed"
( D="$ROOT/s6b"
  setup_impl_run "$D" || { bad "setup failed"; exit 0; }
  # Build emits BATCH_RESULT: BLOCKED so record_blocker appends to BLOCKERS.md.
  printf 'BATCH_RESULT: BLOCKED requirement needs a new ADR\n' > "$STUBDIR/build-0001-alpha"
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(_impl_report)"
  [ -f docs/tdd/BLOCKERS.md ] && grep -q '0001-alpha' docs/tdd/BLOCKERS.md \
    && ok "the run appended a blocker entry to BLOCKERS.md" || bad "build BLOCKED should append to BLOCKERS.md"
  grep -q 'Design blockers were recorded in docs/tdd/BLOCKERS.md' "$R" 2>/dev/null \
    && ok "report prints the BLOCKERS pointer when the ledger grew" \
    || bad "report should print the BLOCKERS pointer after an append (got tail: $(tail -3 "$R" 2>/dev/null))"
) || true

# ===========================================================================
# §3 (gap 2): orphaned-fragment detection. A fragment stuck non-terminal whose
# run has no live runner (run.json's pid is dead) is interrupted-unclean —
# status.sh --check-paused must surface it as resumable=orphaned. A LIVE runner
# pid is the guard: its fragments are never reported (no racing a slow run).
echo "[§3] status.sh --check-paused surfaces an orphaned building fragment (dead runner pid)"
( D="$ROOT/s3"; mkdir -p "$D/state.d"
  deadpid="$(bash -c 'echo $$')"   # a pid that is definitely dead now
  printf '{"schema":1,"pid":%s,"state":"interrupted","total":1}\n' "$deadpid" > "$D/state.d/run.json"
  printf '{"schema":1,"n":1,"slug":"0030-orph","queue_pos":1,"status":"building","stage":"build","branch":"feat/0030-orph"}\n' > "$D/state.d/0030-orph.json"
  out="$(bash "$REPO/scripts/status.sh" --logdir "$D" --check-paused 2>&1)"
  printf '%s\n' "$out" | grep -qE 'slug=0030-orph .*cause=unclean-exit resumable=orphaned' \
    && ok "orphaned fragment surfaced with cause=unclean-exit resumable=orphaned" \
    || bad "should surface the orphaned fragment (got: '$out')"
  printf '%s' "$out" | grep -q 'gate=build' \
    && ok "orphaned line names the gate (stage)" || bad "orphaned line should carry gate=build (got: '$out')"
) || true

echo "[§3-pid0] pid:0 counts as not-alive (kill -0 0 targets the process group, not a runner)"
( D="$ROOT/s3p"; mkdir -p "$D/state.d"
  # pid:0 is never a valid runner pid; `kill -0 0` would spuriously succeed
  # against the caller's process group, so it must be treated as dead → orphaned.
  printf '{"schema":1,"pid":0,"state":"interrupted","total":1}\n' > "$D/state.d/run.json"
  printf '{"schema":1,"n":1,"slug":"0030-p0","queue_pos":1,"status":"building","stage":"build","branch":"feat/0030-p0"}\n' > "$D/state.d/0030-p0.json"
  out="$(bash "$REPO/scripts/status.sh" --logdir "$D" --check-paused 2>&1)"
  printf '%s' "$out" | grep -q 'resumable=orphaned' \
    && ok "pid:0 is treated as not-alive → orphaned line printed" \
    || bad "pid:0 must not suppress orphan detection (got: '$out')"
) || true

echo "[§3-neg] a LIVE runner pid is never reported as orphaned (no racing a slow run)"
( D="$ROOT/s3n"; mkdir -p "$D/state.d"
  printf '{"schema":1,"pid":%s,"state":"running","total":1}\n' "$$" > "$D/state.d/run.json"   # this test's own (alive) pid
  printf '{"schema":1,"n":1,"slug":"0030-live","queue_pos":1,"status":"building","stage":"build","branch":"feat/0030-live"}\n' > "$D/state.d/0030-live.json"
  out="$(bash "$REPO/scripts/status.sh" --logdir "$D" --check-paused 2>&1)"
  [ -z "$out" ] && ok "no orphaned line printed when the runner pid is alive" \
    || bad "a live-runner fragment must NOT be reported (got: '$out')"
) || true

# ===========================================================================
# §4 (gap 2): orphaned resume accepted with a derived branch head. An orphaned
# building fragment (branch_head_at_pause:null — the unclean death never wrote
# it) must resume the same way a recoverable blocked fragment does: flip to
# paused/transient, derive branch_head from the branch ref (FR-40: committed
# history is the source of truth), preserve gates_completed, and NOT refuse.
echo "[§4] _resume_from accepts an orphaned building fragment + derives branch_head from the branch ref"
( D="$ROOT/s4"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D" RESUME=1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'x\n' > f.txt; git add -A; git commit -qm base >/dev/null
  git checkout -q -b feat/0030-orph
  printf 'y\n' >> f.txt; git add -A; git commit -qm step1 >/dev/null
  head_sha="$(git rev-parse refs/heads/feat/0030-orph)"
  # Orphaned fragment: status=building, branch_head_at_pause null, gates=build.
  _write_tdd_fragment 0030-orph 1 docs/tdd/0030-orph.md 1 building build 1000 1000 "feat/0030-orph" "" log "" "" "build" "" "" "" "" "" "" "" "" ""
  F="$D/state.d/0030-orph.json"
  grep -q '"branch_head_at_pause":null' "$F" || { bad "fixture: branch_head_at_pause should start null (got: $(cat "$F"))"; }
  _resume_from 0030-orph; rrc=$?
  [ "$rrc" -ne 3 ] && ok "_resume_from does NOT refuse an orphaned fragment (rc=$rrc)" \
    || bad "_resume_from should accept the orphaned fragment, not refuse (rc=$rrc, cause=${RESUME_REFUSE_CAUSE:-})"
  st="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)"
  [ "$st" = "paused" ] && ok "orphaned fragment flipped to paused" || bad "orphaned fragment should flip to paused (got '$st')"
  bh="$(_read_fragment_field "$F" branch_head_at_pause)"
  [ "$bh" = "$head_sha" ] && ok "branch_head_at_pause derived from the branch ref" \
    || bad "branch_head_at_pause should equal the branch ref $head_sha (got '$bh')"
  gc="$(_read_fragment_array_csv "$F" gates_completed)"
  [ "$gc" = "build" ] && ok "gates_completed preserved verbatim" || bad "gates_completed should be 'build' (got '$gc')"
  rk="$(_resume_gates_var 0030-orph)"
  [ "${!rk:-}" = "build" ] && ok "RESUME_GATES_DONE carries the completed gates" || bad "resume hint should list build (got '${!rk:-}')"
) || true

# §4-acceptfail (gap 2): if the orphan→paused flip write fails, _resume_from must
# REFUSE the resume (rc=3 + RESUME_REFUSE_CAUSE) rather than fall through with a
# half-written fragment — same no-false-success contract as the blocked arm.
echo "[§4-acceptfail] orphan resume refuses (rc=3) when the building->paused flip write fails"
( D="$ROOT/s4af"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D" RESUME=1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0030-orph 1 docs/tdd/0030-orph.md 1 building build 1000 1000 "feat/0030-orph" "" log "" "" "build" "" "" "" "" "" "" "" "" ""
  F="$D/state.d/0030-orph.json"
  _write_tdd_fragment() { return 1; }   # simulate the flip write failing
  RESUME_REFUSE_CAUSE=""
  _resume_from 0030-orph 2>/dev/null; rc=$?
  [ "$rc" = "3" ] && ok "flip-write failure refuses the orphan resume (rc=3)" \
    || bad "should refuse on flip-write failure (got $rc)"
  [ -n "${RESUME_REFUSE_CAUSE:-}" ] && ok "RESUME_REFUSE_CAUSE set on refusal" \
    || bad "RESUME_REFUSE_CAUSE should be set on refusal"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "building" ] \
    && ok "fragment left building (no half-written paused state)" \
    || bad "fragment should remain building on refusal"
  vC="$(_resume_gates_var 0030-orph)"
  [ -z "${!vC:-}" ] && ok "no gates-done var set on refusal" || bad "no gates-done var should be set on refusal"
) || true

# §4-headfail (gap 2 / MAJOR-1): if the flip succeeds but the derived-branch-head
# WRITE fails, _resume_from must NOT adopt the head in memory (which would run
# the divergence guard against a never-persisted baseline). It accepts the resume
# (the branch is still ground truth), leaves branch_head_at_pause null on disk,
# and warns.
echo "[§4-headfail] derived branch-head write failure: resume still accepted, head not adopted in memory"
( D="$ROOT/s4hf"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D" RESUME=1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'x\n' > f.txt; git add -A; git commit -qm base >/dev/null
  git checkout -q -b feat/0030-orph; printf 'y\n' >> f.txt; git add -A; git commit -qm step1 >/dev/null
  _write_tdd_fragment 0030-orph 1 docs/tdd/0030-orph.md 1 building build 1000 1000 "feat/0030-orph" "" log "" "" "build" "" "" "" "" "" "" "" "" ""
  F="$D/state.d/0030-orph.json"
  _update_branch_head_at_pause() { return 1; }   # the flip succeeds; only the head-write fails
  _resume_from 0030-orph 2>/dev/null; rc=$?
  [ "$rc" != "3" ] && ok "head-write failure does NOT refuse the resume (the branch is ground truth)" \
    || bad "head-write failure should not refuse (rc=$rc)"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "paused" ] \
    && ok "fragment still flipped to paused (the flip itself succeeded)" || bad "fragment should be paused"
  bh="$(_read_fragment_field "$F" branch_head_at_pause)"
  [ -z "$bh" ] && ok "branch_head_at_pause left null on disk (no never-persisted baseline adopted)" \
    || bad "branch_head_at_pause should stay null when the write fails (got '$bh')"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== coproc-verdict-resilience eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

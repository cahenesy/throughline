#!/usr/bin/env bash
# bounded-rework-convergence.test.sh — eval for TDD 0041 (bounded-rework
# convergence: tolerate estimate error, don't burn budget on scope-rejected
# attempts, sweep binding-rule violations).
# PRD refs: FR-65, FR-66, FR-67 (incl. (b)-tolerance gap-closure), FR-58, FR-59,
# FR-53; ADR 0005, 0006, 0007.
#
# The contract under test (function-level; the runtime-verify gate re-drives the
# same observable surface against a real /implement run):
#   - Component 1: a scope-rejected rework attempt (rework-scope-exceeded /
#     structural-finding(b)) does NOT consume the convergence budget — the
#     iteration's rework_attempts increment is rolled back (floored at 0) before
#     the BLOCK, via the new _decrement_rework_attempt state mutator. A genuine
#     design escalation (c) and a shipped-but-still-flawed attempt are unaffected.
#   - Component 2: scripts/review-prompt.md carries the binding-rule-sweep rule.
#   - Component 3 (no-op post-condition): the rework scope cap reads the swept
#     finding's SUMMED region_lines (RWK_REGION → _rework_scope_cap), so a
#     whole-class fix is not itself scope-rejected for touching all its sites.
#   - Component 4: the _rework_pre_pass FR-67(b) per-file check escalates only at
#     actual > declared × K (K = THROUGHLINE_STRUCTURAL_DIFF_TOLERANCE, default
#     1.6, guarded + floored at 1.0), with the factor in the PRECHECK_FAIL line.
#   - Component 5: skills/tdd-author/SKILL.md carries the estimate-padding
#     heuristic in the `## Expected diff size` block.
#
# Mechanical-check robustness (binding — L-001/L-002): absence assertions
# distinguish grep exit 1 vs ≥2 and fail on unreadable; every target file is
# asserted readable before content checks; the counter seeds + verdict stubs are
# explicit compact single-line JSON fixtures; no real review subprocess is spawned.
#
# Run: bash tests/bounded-rework-convergence.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# setup_loop_repo <dir> — git repo + scope-declaring TDD + a state fragment + a
# stub `claude` that acts as the review gate (cats $CTL/review.out) and the
# rework model (runs $CTL/do_rework). Gates 1-3 are marked done via
# RESUME_GATES_DONE_* so gate_one runs ONLY the review gate + its rework loop.
# Mirrors tests/bounded-rework-loop.test.sh's harness. Leaves PWD in the repo.
setup_loop_repo() {  # <dir>  (caller exports STATE_DIR etc. + sources $IMPL first)
  local d="$1"; mkdir -p "$d/ctl" "$d/bin"
  cd "$d" || return 1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
  # ctl/ + bin/ are test scaffolding, not part of the build — keep them out of
  # git so a rework's `git add -A` never sweeps them into the commit.
  printf 'ctl/\nbin/\n' > .gitignore
  printf 'orig\n' > src/a.txt
  cat > docs/tdd/0099-fix.md <<'EOF'
# TDD 0099: fixture
Status: draft
PRD refs: 1

## Touched files
- `src/a.txt` — the in-scope file

## Expected diff size
- `src/a.txt` — ~50 lines added
EOF
  git add -A; git commit -qm "build start" >/dev/null
  cat > "$d/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
if printf '%s' "\$prompt" | grep -q 'BOUNDED rework pass'; then
  bash "$d/ctl/do_rework"; exit 0
fi
if printf '%s' "\$prompt" | grep -q 'INDEPENDENT review gate'; then
  cat "$d/ctl/review.out" 2>/dev/null || echo "REVIEW_RESULT: PASS"; exit 0
fi
echo "BATCH_RESULT: OK"; exit 0
EOF
  chmod +x "$d/bin/claude"
  export PATH="$d/bin:$PATH"
  export RTMPL="$REPO/scripts/review-prompt.md" RWTMPL="$REPO/scripts/rework-prompt.md"
  export REVIEW_MODEL="" REBUILD=0 BASE=master
  export THROUGHLINE_GATE_RETRIES=1 THROUGHLINE_GATE_BACKOFF_BASE=0
  export THROUGHLINE_REQUIRE_TEST_FIRST=0 THROUGHLINE_REQUIRE_RUNTIME_VERIFY=0
  RESUME_GATES_DONE_0099_fix="build,test-first,verify,verify-runtime"
  export RESUME_GATES_DONE_0099_fix
  _write_tdd_fragment 0099-fix 99 docs/tdd/0099-fix.md 1 reviewing review \
    1000 1000 "feat/0099-fix" "" "log" "" "" "build,test-first,verify,verify-runtime" "" "" "" "" "" "" ""
}

# ============================================================================
# Component 1 — convergence-budget honesty (rollback on scope rejection)
# ============================================================================

echo "[D1] _decrement_rework_attempt decrements the per-(gate,step) counter"
( D="$ROOT/D1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 reviewing review \
    1000 1000 "feat/0007-x" "" "log" "" "" "" "" "" \
    "" "" "" "" '{"review:1":2}' "" "" ""
  _decrement_rework_attempt 0007-x review:1
  F="$D/state.d/0007-x.json"
  grep -q '"review:1":1' "$F" 2>/dev/null \
    && ok "2 → 1 after one decrement" || bad "review:1 should decrement 2→1 (got: $(_read_fragment_raw_object "$F" rework_attempts))"
) || true

echo "[D5] _decrement_rework_attempt floors at 0 (no underflow)"
( D="$ROOT/D5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 reviewing review \
    1000 1000 "feat/0007-x" "" "log" "" "" "" "" "" \
    "" "" "" "" '{"review:1":0}' "" "" ""
  _decrement_rework_attempt 0007-x review:1
  F="$D/state.d/0007-x.json"
  grep -q '"review:1":0' "$F" 2>/dev/null \
    && ok "0 stays 0 (floored, never negative)" || bad "review:1 should stay 0 (got: $(_read_fragment_raw_object "$F" rework_attempts))"
  grep -q '"review:1":-' "$F" 2>/dev/null \
    && bad "counter went negative" || ok "counter never negative"
) || true

echo "[V1] scope-rejected structural-finding(b) attempt is NOT counted (rolled back)"
( D="$ROOT/V1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_loop_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"
  printf 'build-output\n' >> src/a.txt; git add -A; git commit -qm "build: output past build-start" >/dev/null
  # region_lines=40 → scope cap 120; per-file declared 50 → ×1.6 = 80. A 90-line
  # rework on src/a.txt fires (b) (90 > 80) but NOT the scope cap (≤ 120), so the
  # (b) escalation path — the one Component 1 rolls back — is isolated.
  printf 'REVIEW_FINDING: severity=major structural=false region_lines=40 ref=review-1:1 | over-bound rework\nREVIEW_RESULT: BLOCK over-bound\n' > "$D/repo/ctl/review.out"
  cat > "$D/repo/ctl/do_rework" <<'EOF'
seq 1 90 > src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: overshoots per-file bound" >/dev/null 2>&1
EOF
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/v1.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -ne 0 ] && ok "gate_one blocks on (b)" || bad "(b) over-bound should block (rc=$rc, st=$st)"
  grep -q '"halt_cause":"structural-finding"' "$F" 2>/dev/null \
    && ok "halt_cause=structural-finding" || bad "halt_cause should be structural-finding"
  grep -q '"review:1":0' "$F" 2>/dev/null \
    && ok "rework_attempts review:1 rolled back to 0 (not counted)" \
    || bad "scope-rejected (b) attempt must NOT be counted — review:1 should be 0 (got: $(_read_fragment_raw_object "$F" rework_attempts))"
  grep -q 'not counted (scope-rejected' "$D/v1.log" 2>/dev/null \
    && ok "not-counted telemetry note present" || bad "a 'not counted (scope-rejected)' note should be logged"
) || true

echo "[V2] rework-scope-exceeded attempt is NOT counted (rolled back)"
( D="$ROOT/V2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_loop_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"
  printf 'build-output\n' >> src/a.txt; git add -A; git commit -qm "build: output past build-start" >/dev/null
  # region_lines=8 → scope cap 60; a 200-line rework overruns the cap (FR-66).
  printf 'REVIEW_FINDING: severity=major structural=false region_lines=8 ref=review-1:1 | small bug\nREVIEW_RESULT: BLOCK bug\n' > "$D/repo/ctl/review.out"
  cat > "$D/repo/ctl/do_rework" <<'EOF'
seq 1 200 > src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: oversized" >/dev/null 2>&1
EOF
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/v2.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -ne 0 ] && ok "gate_one blocks on scope-exceeded" || bad "oversized rework should block (rc=$rc, st=$st)"
  grep -q '"halt_cause":"rework-scope-exceeded"' "$F" 2>/dev/null \
    && ok "halt_cause=rework-scope-exceeded" || bad "halt_cause should be rework-scope-exceeded"
  grep -q '"review:1":0' "$F" 2>/dev/null \
    && ok "rework_attempts review:1 rolled back to 0 (not counted)" \
    || bad "scope-exceeded attempt must NOT be counted — review:1 should be 0 (got: $(_read_fragment_raw_object "$F" rework_attempts))"
) || true

echo "[V3] shipped-but-still-flawed attempt IS counted (budget bounds genuine attempts)"
( D="$ROOT/V3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  export THROUGHLINE_REWORK_MAX=1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_loop_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"
  printf 'build-output\n' >> src/a.txt; git add -A; git commit -qm "build: output past build-start" >/dev/null
  # review ALWAYS blocks; the rework ships a small in-scope commit that does not
  # resolve the finding → it survives the pre-pass (shipped) → next pass blocks →
  # budget (max=1) exhausted. The one shipped attempt MUST stay counted.
  printf 'REVIEW_FINDING: severity=major structural=false region_lines=8 ref=review-1:1 | persistent bug\nREVIEW_RESULT: BLOCK persistent\n' > "$D/repo/ctl/review.out"
  cat > "$D/repo/ctl/do_rework" <<'EOF'
echo "tweak $(wc -l < src/a.txt)" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: small in-scope tweak" >/dev/null 2>&1
EOF
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/v3.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -ne 0 ] && ok "gate_one blocks (budget exhausted after the shipped attempt)" || bad "should exhaust budget (rc=$rc, st=$st)"
  grep -q '"outcome":"shipped"' "$F" 2>/dev/null \
    && ok "rework_log records a shipped attempt" || bad "rework_log should record a shipped attempt"
  grep -q '"review:1":1' "$F" 2>/dev/null \
    && ok "rework_attempts review:1 == 1 (shipped attempt counted)" \
    || bad "a shipped-but-flawed attempt MUST be counted — review:1 should be 1 (got: $(_read_fragment_raw_object "$F" rework_attempts))"
) || true

echo "[V4] structural-finding(c) does NOT roll back the counter (rollback scoped to (b)/scope)"
( D="$ROOT/V4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_loop_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"
  printf 'build-output\n' >> src/a.txt; git add -A; git commit -qm "build: output past build-start" >/dev/null
  # Seed a prior carried-over count of 1 (rework_attempts is param 21, so six
  # empty positional args 15-20 pad up to it); a genuine (c) escalation
  # (structural=true WITH a named reason) fires BEFORE any increment and is NOT a
  # scope rejection, so the rollback must NOT touch the counter — it stays 1.
  _write_tdd_fragment 0099-fix 99 docs/tdd/0099-fix.md 1 reviewing review \
    1000 1000 "feat/0099-fix" "" "log" "" "" "build,test-first,verify,verify-runtime" "" "" "" "" "" "" '{"review:1":1}' "" ""
  printf 'FINDING_BEGIN\nseverity: major\nstructural: true\nstructural_reason: requires reworking the module decomposition across files\nregion: src/a.txt:1-8\nregion_lines: 8\npattern_tags: [cross-module]\nsummary: cross-module refactor needed\nevidence: n/a\nFINDING_END\nREVIEW_RESULT: BLOCK structural\n' > "$D/repo/ctl/review.out"
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/v4.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -ne 0 ] && ok "gate_one blocks on (c)" || bad "named structural should (c)-escalate (rc=$rc, st=$st)"
  grep -q '"halt_cause":"structural-finding"' "$F" 2>/dev/null \
    && ok "halt_cause=structural-finding (c)" || bad "halt_cause should be structural-finding"
  grep -q '"review:1":1' "$F" 2>/dev/null \
    && ok "rework_attempts review:1 unchanged at 1 (c not rolled back)" \
    || bad "(c) must NOT roll back the counter — review:1 should stay 1 (got: $(_read_fragment_raw_object "$F" rework_attempts))"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== bounded-rework-convergence eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

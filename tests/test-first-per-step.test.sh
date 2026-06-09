#!/usr/bin/env bash
# test-first-per-step.test.sh — eval for the mechanical per-step test-first
# pre-check (TDD 0038 / FR-15(a) per-step enforcement; ADR 0005, 0006, 0007).
#
# The contract under test (function-level; ci-checks.sh re-runs the suite on the
# build branch and the four reconciled fixtures re-drive the same surface):
#   - _test_first_ok_range <base> <head> <skip-present> is a pure git-history +
#     skip predicate shared by the whole-build test_first_ok gate and the new
#     per-step pre-check (one definition of "a test(failing): precursor exists").
#   - _per_step_review_loop, on each STEP_COMMIT sentinel, runs a DETERMINISTIC
#     per-step test-first pre-check BEFORE the model review: a step whose commit
#     range introduces implementation with no preceding `test(failing):` commit
#     (and no per-step TEST_FIRST_SKIPPED: token) gets a `STEP_REVIEW: BLOCK
#     test-first:` verdict written to the build with NO model review spawned
#     (artifact-grounded, ADR 0006; token-free).
#   - the OPTIONAL `TEST_FIRST_SKIPPED:<reason>` token on the sentinel is
#     backward-compatible with the TDD 0032 STEP_COMMIT parser (the step-id + sha
#     still parse; the trailing token never trips the protocol-error branch).
#   - the pre-check honors THROUGHLINE_REQUIRE_TEST_FIRST (off => no-op), the
#     same knob as the whole-build gate.
#
# Run: bash tests/test-first-per-step.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# grep_has / grep_absent: fail-closed grep assertions (folds in L-001
# fragile-inversion-pattern + L-002 misleading-diagnostic). Each anchors on a
# SPECIFIC string, distinguishes exit 1 (legitimately absent) from exit >=2
# (grep error) / an unreadable file, and emits a DISTINCT infra diagnostic for
# the error case rather than a content bad().
grep_has() {  # <pattern> <file> <label>
  local pat="$1" file="$2" label="$3" rc
  if [ ! -r "$file" ]; then bad "INFRA: $label — fixture unreadable: $file"; return; fi
  grep -aqE -- "$pat" "$file"; rc=$?
  case "$rc" in
    0) ok "$label" ;;
    1) bad "$label (pattern absent: $pat)" ;;
    *) bad "INFRA: $label — grep error rc=$rc on $file" ;;
  esac
}
grep_absent() {  # <pattern> <file> <label>
  local pat="$1" file="$2" label="$3" rc
  if [ ! -r "$file" ]; then bad "INFRA: $label — fixture unreadable: $file"; return; fi
  grep -aqE -- "$pat" "$file"; rc=$?
  case "$rc" in
    1) ok "$label" ;;
    0) bad "$label (pattern unexpectedly present: $pat)" ;;
    *) bad "INFRA: $label — grep error rc=$rc on $file" ;;
  esac
}

# setup_step_repo <dir>: a git repo + scope-declaring TDD + a stub `claude` that
# acts as BOTH the multi-turn build (emits STEP_COMMIT lines, blocks on
# STEP_REVIEW stdin replies, per $CTL/build_plan) and the per-step review (echoes
# $CTL/review.out, default PASS, and records each invocation in $CTL/revcount).
# Leaves PWD in the repo. Mirrors continuous-in-build-review.test.sh's
# setup_step_repo so the per-step loop drives identically.
setup_step_repo() {  # <dir>
  local d="$1"; mkdir -p "$d/ctl" "$d/bin"
  cd "$d" || return 1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
  printf 'ctl/\nbin/\n' > .gitignore
  printf 'orig\n' > src/a.txt
  cat > docs/tdd/0038-fix.md <<'EOF'
# TDD 0038: fixture
Status: draft
PRD refs: 15

## Touched files
- `src/a.txt` — the in-scope file
EOF
  git add -A; git commit -qm "build start" >/dev/null
  # Stub claude: review path (prompt contains 'INDEPENDENT review gate') records
  # an invocation count and echoes $CTL/review.out (default PASS). Build path runs
  # $CTL/build_plan (emits STEP_COMMIT lines, reads STEP_REVIEW replies on stdin).
  cat > "$d/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
if printf '%s' "\$prompt" | grep -q 'INDEPENDENT review gate'; then
  n=\$(cat "$d/ctl/revcount" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$d/ctl/revcount"
  cat "$d/ctl/review.out" 2>/dev/null || echo "REVIEW_RESULT: PASS"
  exit 0
fi
bash "$d/ctl/build_plan"
EOF
  chmod +x "$d/bin/claude"
  export PATH="$d/bin:$PATH"
  export TMPL="$REPO/scripts/build-prompt.md" RTMPL="$REPO/scripts/review-prompt.md"
  export MODEL="" REVIEW_MODEL="" MAINREPO="$d"
  # Bound any handshake hang well under the default inter-event watchdog so a
  # regression surfaces as a fast eval failure, not a multi-minute stall.
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=30
  printf 'REVIEW_RESULT: PASS\n' > "$d/ctl/review.out"
}

revcount() {  # echoes the recorded review-invocation count (0 if never invoked)
  cat "$1/ctl/revcount" 2>/dev/null || echo 0
}

echo "[§1] impl-first step -> deterministic STEP_REVIEW: BLOCK test-first:, NO model review spawned"
( D="$ROOT/s1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0038-fix 38 docs/tdd/0038-fix.md 1 building build 1000 1000 "feat/0038-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  # impl-only step: a single `step(1):` commit, NO preceding test(failing):.
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true   # consume the runner's initial prompt so reply reads stay aligned
echo "impl" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(1): work" >/dev/null 2>&1
echo "STEP_COMMIT: 1 $(git rev-parse HEAD)"
IFS= read -r _reply || true   # absorb the deterministic BLOCK verdict
echo "BATCH_RESULT: OK"
EOF
  # default knob (unset => ON)
  _per_step_review_loop 0038-fix docs/tdd/0038-fix.md "$D/s1.log" >/dev/null 2>&1
  grep_has 'STEP_REVIEW: BLOCK test-first:' "$D/s1.log" "impl-first step writes a deterministic test-first BLOCK"
  rc="$(revcount "$D/repo")"
  [ "$rc" = "0" ] && ok "no model review spawned on the deterministic BLOCK (revcount=0)" || bad "review must NOT spawn on test-first BLOCK (revcount=$rc)"
) || true

echo "[§2] test(failing): precursor in range -> NO test-first BLOCK, model review runs once"
( D="$ROOT/s2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0038-fix 38 docs/tdd/0038-fix.md 1 building build 1000 1000 "feat/0038-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true
echo "t" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "test(failing): behavior x" >/dev/null 2>&1
echo "impl" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(1): work" >/dev/null 2>&1
echo "STEP_COMMIT: 1 $(git rev-parse HEAD)"
IFS= read -r _reply || true
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0038-fix docs/tdd/0038-fix.md "$D/s2.log" >/dev/null 2>&1
  grep_absent 'STEP_REVIEW: BLOCK test-first:' "$D/s2.log" "test(failing): precursor passes the pre-check (no test-first BLOCK)"
  rc="$(revcount "$D/repo")"
  [ "$rc" = "1" ] && ok "model review runs once when the precursor exists (revcount=1)" || bad "review should run exactly once (revcount=$rc)"
) || true

echo "[§3] TEST_FIRST_SKIPPED: token on an impl-only range -> pass-through to the model review"
( D="$ROOT/s3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0038-fix 38 docs/tdd/0038-fix.md 1 building build 1000 1000 "feat/0038-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true
echo "impl" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(1): pure refactor" >/dev/null 2>&1
echo "STEP_COMMIT: 1 $(git rev-parse HEAD) TEST_FIRST_SKIPPED:no-new-behavior"
IFS= read -r _reply || true
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0038-fix docs/tdd/0038-fix.md "$D/s3.log" >/dev/null 2>&1
  grep_absent 'STEP_REVIEW: BLOCK test-first:' "$D/s3.log" "declared per-step skip suppresses the test-first BLOCK"
  rc="$(revcount "$D/repo")"
  [ "$rc" = "1" ] && ok "model review runs on a declared TEST_FIRST_SKIPPED step (revcount=1)" || bad "review should run once on a skip (revcount=$rc)"
  grep_has 'THROUGHLINE_TEST_FIRST_SKIP: step 1 TEST_FIRST_SKIPPED:no-new-behavior' "$D/s3.log" "the skip reason is recorded as telemetry"
) || true

echo "[§4] sentinel backward-compat: STEP_COMMIT: 2 <sha> TEST_FIRST_SKIPPED:x parses step-id=2 + sha, no protocol error"
( D="$ROOT/s4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0038-fix 38 docs/tdd/0038-fix.md 1 building build 1000 1000 "feat/0038-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  # claim step-id 2 on the extended sentinel; a test(failing): precursor keeps the
  # pre-check from BLOCKing so the parse path (not the skip path) is what routes.
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true
echo "t" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "test(failing): behavior y" >/dev/null 2>&1
echo "impl" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(2): work" >/dev/null 2>&1
SHA="$(git rev-parse HEAD)"; echo "$SHA" > ctl/sha2
echo "STEP_COMMIT: 2 $SHA TEST_FIRST_SKIPPED:demo"
IFS= read -r _reply || true
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0038-fix docs/tdd/0038-fix.md "$D/s4.log" >/dev/null 2>&1
  RLOG="$D/0038-fix.step2.review.log"
  [ -f "$RLOG" ] && ok "extended sentinel parses to step-id=2 (step2 review log produced)" || bad "step-id=2 should parse (no $RLOG)"
  sha2="$(cat "$D/repo/ctl/sha2" 2>/dev/null || echo MISSING)"
  grep_has "$sha2" "$RLOG" "extended sentinel parses the sha (review scope header carries it)"
  grep_absent 'THROUGHLINE_PROTOCOL_ERROR' "$D/s4.log" "extended sentinel does NOT increment the protocol-error counter"
) || true

echo "[§5] knob OFF (THROUGHLINE_REQUIRE_TEST_FIRST=0) -> per-step pre-check is a no-op"
( D="$ROOT/s5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  export THROUGHLINE_REQUIRE_TEST_FIRST=0
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0038-fix 38 docs/tdd/0038-fix.md 1 building build 1000 1000 "feat/0038-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  # impl-only range, but the knob is OFF: must pass through to the model review.
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true
echo "impl" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(1): work" >/dev/null 2>&1
echo "STEP_COMMIT: 1 $(git rev-parse HEAD)"
IFS= read -r _reply || true
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0038-fix docs/tdd/0038-fix.md "$D/s5.log" >/dev/null 2>&1
  grep_absent 'STEP_REVIEW: BLOCK test-first:' "$D/s5.log" "knob OFF: impl-only range produces no test-first BLOCK"
  rc="$(revcount "$D/repo")"
  [ "$rc" = "1" ] && ok "knob OFF: pre-check no-ops, model review runs (revcount=1)" || bad "knob OFF should pass through to review (revcount=$rc)"
) || true

echo "[§6] build-prompt.md carries the preventive self-gate (Component 2) + the aggregator wire-in rule (Component 3)"
( BP="$REPO/scripts/build-prompt.md"
  grep_has 'Self-verify test-first ordering BEFORE step 3' "$BP" "preventive self-gate bullet present (TDD 0038 §2)"
  grep_has 'AGGREGATOR WIRE-IN is new gating behavior' "$BP" "aggregator wire-in rule present: new gating behavior (TDD 0038 §3)"
  grep_has 'aggregator with the new eval stubbed to fail' "$BP" "wire-in rule mandates a failing wire-in test, not SKIPPED-eligible"
) || true

echo "[§7] the four per-step-loop fixtures opt out of the orthogonal gate (THROUGHLINE_REQUIRE_TEST_FIRST=0)"
( for fx in continuous-in-build-review build-defensive-norms step-commit-protocol coproc-verdict-resilience; do
    grep_has 'export THROUGHLINE_REQUIRE_TEST_FIRST=0' "$REPO/tests/$fx.test.sh" \
      "$fx carries the default-on opt-out export (Component 4)"
  done
) || true

echo "[§8] dogfood (Component 3): wiring this eval into the aggregator makes its exit go non-zero when the eval fails"
( AGG="$REPO/tests/implement-gate.test.sh"
  if [ ! -r "$AGG" ]; then bad "INFRA: §8 — aggregator unreadable: $AGG"; exit 0; fi
  # Structural: the new eval is registered (run) in the aggregator. Anchored on
  # the eval filename so an unwired aggregator is RED. Fail-closed on grep error.
  grep_has 'test-first-per-step\.test\.sh' "$AGG" "the new eval is wired into the aggregator (registration present)"
  # Behavioral: DRIVE the aggregator's real final AND-chain (extracted verbatim)
  # with every accumulator green EXCEPT this eval (TFP_FAIL), stubbed to fail.
  # Before the wire-in the chain never references TFP_FAIL, so it evaluates true
  # (exit 0 = RED); after the wire-in it includes `[ "$TFP_FAIL" -eq 0 ]` and
  # evaluates false (exit non-zero = GREEN). Artifact-grounded (ADR 0006); no
  # recursion (the chain runs against stub integers, not the real sub-evals).
  chain="$(grep -aE '^\[ "\$FAIL" -eq 0 \] &&' "$AGG" | tail -1)"
  if [ -z "$chain" ]; then bad "INFRA: §8 — could not locate the aggregator final AND-chain"; exit 0; fi
  drive_rc="$(
    set +u
    for v in $(printf '%s' "$chain" | grep -aoE '\$[A-Za-z_][A-Za-z0-9_]*' | tr -d '$' | sort -u); do
      eval "$v=0"
    done
    TFP_FAIL=1
    eval "$chain"; echo $?
  )"
  [ "$drive_rc" != "0" ] \
    && ok "aggregator final AND-chain goes non-zero when the new eval fails (wire-in propagates)" \
    || bad "aggregator AND-chain must be non-zero with TFP_FAIL=1 (got rc=$drive_rc)"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== test-first-per-step eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

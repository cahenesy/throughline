#!/usr/bin/env bash
# transient-gate-resilience.test.sh — eval for TDD 0040 (transient gate-failure
# resilience). Two transient gate-failure modes are made honest and non-fatal:
#
#   Component 1 — ci-checks retry-once. On a ci-checks failure the gate re-runs
#   the checks up to THROUGHLINE_CI_CHECKS_RETRIES (default 1) more times before
#   declaring FAIL; the FIRST passing run wins, a recovered flake is logged (not
#   silent), and only the initial run AND all retries failing is a real FAIL.
#   RETRIES=0 restores the no-retry behavior; a non-numeric value default-warns.
#
#   Component 2 — no-verdict → gate-unobservable. A review/verify gate subprocess
#   that exits leaving NO parseable verdict line (no REVIEW_RESULT: / no
#   VERIFY_RUNTIME:), REGARDLESS of exit code, is classified `gate-unobservable`
#   (a resumable blocked halt) instead of a terminal `failed` — couldn't-observe
#   is not observed-wrong (ADR 0006 / NFR-4). The classification is a
#   gate-agnostic helper (_classify_gate_no_verdict) the review gate (_rework_loop
#   in lib/gates.sh) drives. The verify-runtime gate's terminal-state write lives
#   in lib/resume.sh's gate_one (OUTSIDE this TDD's declared ## Touched files) and
#   is NOT rewired here — it still records the old terminal `failed`; §4 exercises
#   the helper with gate=verify-runtime to pin that the classification is
#   gate-agnostic, so a follow-up can wire that call site to it.
#
#   Component 3 — enum + render mirror. `gate-unobservable` is admitted by the
#   closed FR-63 halt-cause enum with a resume-first next-action list (state.sh)
#   and rendered without an unknown-cause warning (status.sh).
#
# Covers the TDD's Verification plan §1-§6, following the fixture pattern of
# tests/runtime-verify-resume.test.sh (§5/§6 enum + render) and
# tests/structural-classification-bound.test.sh (a stub `claude` review gate
# driving the real gate_one + _rework_loop). Stubs mean no model or tokens are
# needed; all subprocess exit codes + outputs are explicit fixtures.
#
#   §1 ci-checks flaky-then-green → PASS (retry recovers; telemetry logged); RETRIES=0 → FAIL
#   §2 ci-checks red-twice → real FAIL (no false PASS); RETRIES non-numeric → default-and-warn
#   §3 review no-verdict → gate-unobservable (resumable), gate=review + stderr-tail detail
#   §4 verify no-verdict → gate-unobservable (gate=verify-runtime) via the gate-agnostic helper
#   §5 observed REVIEW_RESULT: BLOCK is UNTOUCHED (discriminator is verdict-presence)
#   §6 enum membership + status.sh render (resumable=blocked; no unknown-cause warning)
#
# Run: bash tests/transient-gate-resilience.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ===========================================================================
# §1: ci-checks flaky-then-green → PASS. A stub ci-checks.sh fails on its first
# invocation and passes on the second (keyed off a counter file). With
# THROUGHLINE_CI_CHECKS_RETRIES=1 run_ci_checks PASSES and the gate log records a
# recovered-flake telemetry line; with RETRIES=0 the SAME stub FAILS (no retry).
echo "[§1] ci-checks flaky-then-green → PASS with retry; RETRIES=0 → FAIL (knob governs)"
( D="$ROOT/s1"; mkdir -p "$D"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  mkdir -p "$D/state.d"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # Stub ci-checks: fail on attempt 1, pass on attempt 2+ (counter file). The
  # counter is reset per scenario so each run starts on the flaky first attempt.
  cnt="$D/ci.count"
  cat > "$D/ci-checks-stub.sh" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$cnt" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$cnt"
echo "ci-checks stub invocation \$n"
[ "\$n" -ge 2 ] && exit 0 || exit 1
EOF
  chmod +x "$D/ci-checks-stub.sh"
  export CI_CHECKS="$D/ci-checks-stub.sh"

  # RETRIES=1: initial run flakes, retry passes → PASS.
  printf '0\n' > "$cnt"; : > "$D/r1.log"
  THROUGHLINE_CI_CHECKS_RETRIES=1 run_ci_checks "$D/r1.log"; rc=$?
  [ "$rc" -eq 0 ] && ok "flaky-then-green run_ci_checks returns 0 with RETRIES=1" || bad "retry should recover the flake (got rc=$rc)"
  grep -qiE 'passed on retry' "$D/r1.log" \
    && ok "the gate log records a recovered-flake telemetry line" || bad "recovered flake must be logged, not silent (NFR-4); log: $(cat "$D/r1.log")"

  # RETRIES=0: no retry — the same flaky stub FAILS on its single attempt.
  printf '0\n' > "$cnt"; : > "$D/r0.log"
  THROUGHLINE_CI_CHECKS_RETRIES=0 run_ci_checks "$D/r0.log"; rc0=$?
  [ "$rc0" -ne 0 ] && ok "RETRIES=0 disables the retry (the knob governs it)" || bad "RETRIES=0 should NOT retry (got rc=$rc0)"
) || true

# ===========================================================================
# §2: ci-checks red-twice → real FAIL (no false PASS). A stub that fails on EVERY
# invocation must FAIL even with the retry — retry only re-observes a one-off, it
# never masks a reproducible failure (NFR-4). A non-numeric RETRIES default-warns.
echo "[§2] ci-checks red-twice → real FAIL (retry never masks a reproducible failure); RETRIES non-numeric → default-and-warn"
( D="$ROOT/s2"; mkdir -p "$D"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  mkdir -p "$D/state.d"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # Stub that ALWAYS fails (a reproducible regression).
  cat > "$D/ci-red.sh" <<'EOF'
#!/usr/bin/env bash
echo "ci-checks red (reproducible failure)"; exit 1
EOF
  chmod +x "$D/ci-red.sh"
  export CI_CHECKS="$D/ci-red.sh"

  : > "$D/red.log"
  THROUGHLINE_CI_CHECKS_RETRIES=1 run_ci_checks "$D/red.log"; rc=$?
  [ "$rc" -ne 0 ] && ok "red-twice run_ci_checks returns non-zero (real FAIL, no false PASS)" || bad "a reproducible failure must FAIL even with retry (got rc=$rc)"
  ! grep -qiE 'passed on retry' "$D/red.log" \
    && ok "no recovered-flake telemetry on a genuine FAIL" || bad "must NOT log a recovered flake when it really failed"
  # NFR-4 honesty: a real FAIL must be as visible in the gate log as a recovery —
  # record an explicit "FAILED after N attempt(s)" line on retry exhaustion so a
  # reader can tell a retries-exhausted FAIL from a single-shot one.
  grep -qiE 'ci-checks: FAILED after [0-9]+ attempt' "$D/red.log" \
    && ok "retry exhaustion logs an explicit FAILED-after-N telemetry line" || bad "a retries-exhausted FAIL must be logged (NFR-4); log: $(cat "$D/red.log")"

  # Non-numeric RETRIES → default-and-warn (still bounded; mirrors WATCH_MAX_SECS).
  printf '0\n' > "$D/c2"
  cat > "$D/ci-flaky2.sh" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$D/c2" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$D/c2"
[ "\$n" -ge 2 ] && exit 0 || exit 1
EOF
  chmod +x "$D/ci-flaky2.sh"; export CI_CHECKS="$D/ci-flaky2.sh"
  : > "$D/warn.log"
  warn="$(THROUGHLINE_CI_CHECKS_RETRIES=abc run_ci_checks "$D/warn.log" 2>&1 >/dev/null)"; rcw=$?
  [ "$rcw" -eq 0 ] && ok "non-numeric RETRIES defaults to 1 (flaky-then-green still recovers)" || bad "non-numeric RETRIES should default to 1 and retry (got rc=$rcw)"
  printf '%s' "$warn" | grep -qiE 'not numeric|falling back' \
    && ok "non-numeric RETRIES emits a default-and-warn diagnostic" || bad "non-numeric RETRIES should warn (got: '$warn')"
) || true

# ===========================================================================
# tgr_setup_review_repo <dir> — git repo + scope-declaring TDD + a state fragment
# + a stub `claude` acting as BOTH the review gate (cats $CTL/review.out, exits
# $CTL/review.rc) and the rework model (runs $CTL/do_rework). Gates 1-3 are marked
# done so gate_one runs ONLY the review gate + its bounded rework loop. Mirrors
# tests/structural-classification-bound.test.sh::scb_setup_repo. Leaves PWD in the
# repo. The caller exports STATE_DIR etc. + sources $IMPL first.
tgr_setup_review_repo() {  # <dir>
  local d="$1"; mkdir -p "$d/ctl" "$d/bin"
  cd "$d" || return 1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
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
  printf '0\n' > "$d/ctl/review.rc"   # default: review subprocess exits 0
  cat > "$d/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
if printf '%s' "\$prompt" | grep -q 'BOUNDED rework pass'; then
  bash "$d/ctl/do_rework"; exit 0
fi
if printf '%s' "\$prompt" | grep -q 'INDEPENDENT review gate'; then
  cat "$d/ctl/review.out" 2>/dev/null
  exit "\$(cat "$d/ctl/review.rc" 2>/dev/null || echo 0)"
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
# Commit build output past build-start so the consolidated review scope is
# non-empty (the empty-scope guard fails closed on a HEAD..HEAD scope).
tgr_build_output() { printf 'build-output\n' >> src/a.txt; git add -A; git commit -qm "build: simulated output" >/dev/null; }

# §3: review no-verdict → gate-unobservable (resumable). The stub review
# subprocess exits rc=1 emitting NO REVIEW_RESULT: line plus a stderr line
# mimicking the `timeout … No such file` exec error. The fragment must record
# halt_cause=gate-unobservable (NOT failed/null), halt_cause_detail naming `review`
# + the stderr tail, status=blocked, and halt_next_actions beginning with resume —
# couldn't-observe, not observed-wrong (ADR 0006 / NFR-4).
echo "[§3] review subprocess emits NO REVIEW_RESULT → gate-unobservable (resumable, gate=review, stderr-tail detail)"
( D="$ROOT/s3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  tgr_setup_review_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"; tgr_build_output
  # No-verdict review: emit the exec-error tail to stdout (captured to the gate
  # log by _claude_call) and exit non-zero, with NO REVIEW_RESULT line.
  printf "timeout: failed to run command 'claude': No such file or directory\n" > "$D/repo/ctl/review.out"
  printf '1\n' > "$D/repo/ctl/review.rc"
  : > "$D/s3.log"
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/s3.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -ne 0 ] && ok "gate_one does not clear on a no-verdict review" || bad "no-verdict review should not converge (rc=$rc)"
  hc="$(_read_fragment_field "$F" halt_cause)"
  [ "$hc" = "gate-unobservable" ] && ok "review no-verdict → halt_cause=gate-unobservable" || bad "halt_cause should be gate-unobservable, NOT failed/null (got '$hc')"
  stt="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)"
  [ "$stt" = "blocked" ] && ok "fragment ends at status=blocked (resumable), not failed" || bad "status should be blocked (got '$stt')"
  det="$(_read_fragment_field "$F" halt_cause_detail)"
  printf '%s' "$det" | grep -q 'review' \
    && ok "halt_cause_detail names the gate (review)" || bad "detail should name review (got '$det')"
  printf '%s' "$det" | grep -qi 'No such file or directory' \
    && ok "halt_cause_detail carries the captured stderr tail" || bad "detail should carry the stderr tail (got '$det')"
  acts="$(sed -n 's/.*\("halt_next_actions":\[[^]]*\]\).*/\1/p' "$F" | head -1)"
  printf '%s' "$acts" | grep -qE '(\[|,)"resume' \
    && ok "halt_next_actions begins with a resume action (auto-resumable)" || bad "halt_next_actions should begin with resume (got '$acts')"
) || true

# §4: verify no-verdict → gate-unobservable (gate=verify-runtime). The verify-gate
# terminal-state write lives in lib/resume.sh's gate_one (OUTSIDE this TDD's
# declared ## Touched files) and is NOT rewired here — it still records the old
# terminal `failed`. This pins that the classifier is gate-AGNOSTIC so a future
# follow-up can wire that call site to it: _classify_gate_no_verdict <slug>
# verify-runtime <tail> records the SAME resumable gate-unobservable halt with
# gate=verify-runtime that the review path produces.
echo "[§4] verify-runtime no-verdict → gate-unobservable via the gate-agnostic helper (gate=verify-runtime)"
( D="$ROOT/s4"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  command -v _classify_gate_no_verdict >/dev/null 2>&1 \
    && ok "_classify_gate_no_verdict helper is defined (gate-agnostic)" || bad "_classify_gate_no_verdict should exist"
  _write_tdd_fragment 0040-v 40 docs/tdd/0040-v.md 1 verifying verify-runtime 1000 1000 "feat/0040-v" "" log "" "" "build,test-first,verify" "" "" "" "" "" "" "" "" "" "" "" ""
  _classify_gate_no_verdict 0040-v verify-runtime "timeout: failed to run command 'claude': No such file or directory" 2>/dev/null
  F="$STATE_DIR/0040-v.json"
  hc="$(_read_fragment_field "$F" halt_cause)"
  [ "$hc" = "gate-unobservable" ] && ok "verify-runtime no-verdict → halt_cause=gate-unobservable" || bad "halt_cause should be gate-unobservable (got '$hc')"
  stt="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)"
  [ "$stt" = "blocked" ] && ok "verify no-verdict ends at status=blocked (resumable)" || bad "status should be blocked (got '$stt')"
  det="$(_read_fragment_field "$F" halt_cause_detail)"
  printf '%s' "$det" | grep -q 'verify-runtime' \
    && ok "halt_cause_detail names the gate (verify-runtime)" || bad "detail should name verify-runtime (got '$det')"
) || true

# §5: observed REVIEW_RESULT: BLOCK is UNTOUCHED — the discriminator is
# verdict-presence, not exit code. A review that emits BLOCK + a halting finding
# drives the bounded-rework path (converges here), NOT a gate-unobservable
# reclassification. Even when the subprocess ALSO exits non-zero, the verdict wins.
echo "[§5] observed REVIEW_RESULT: BLOCK drives bounded rework, NOT gate-unobservable (verdict wins, even on rc!=0)"
( D="$ROOT/s5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  tgr_setup_review_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"; tgr_build_output
  # Observed BLOCK + a non-structural major finding AND a non-zero exit — the
  # verdict must still win (not reclassified gate-unobservable).
  cat > "$D/repo/ctl/review.out" <<'EOF'
FINDING_BEGIN
severity: major
structural: false
region: src/a.txt:1-1
region_lines: 8
pattern_tags: [in-scope-fix]
summary: tighten the in-scope block
evidence: src/a.txt:1 needs a fix
FINDING_END
REVIEW_RESULT: BLOCK in-scope finding
EOF
  printf '1\n' > "$D/repo/ctl/review.rc"   # verdict present AND rc!=0 → verdict wins
  cat > "$D/repo/ctl/do_rework" <<EOF
printf 'fixed\n' > src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: in-scope fix to src/a.txt" >/dev/null 2>&1
printf 'FILE_REVIEWED_NO_FINDINGS: src/a.txt\nREVIEW_RESULT: PASS\n' > "$D/repo/ctl/review.out"
printf '0\n' > "$D/repo/ctl/review.rc"
EOF
  : > "$D/s5.log"
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/s5.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  hc="$(_read_fragment_field "$F" halt_cause)"
  [ "$hc" != "gate-unobservable" ] \
    && ok "an observed BLOCK is NOT reclassified gate-unobservable (got halt_cause='$hc')" || bad "observed BLOCK must not become gate-unobservable"
  grep -q '"outcome":"shipped"' "$F" 2>/dev/null \
    && ok "the observed BLOCK drove a bounded rework attempt (verdict-presence discriminator)" || bad "observed BLOCK should drive rework (rework_log: $(_read_fragment_raw_array "$F" rework_log))"
) || true

# ===========================================================================
# §6: enum membership + status.sh render (Component 3). set_halt_cause
# <slug> gate-unobservable returns 0 and writes the cause; the first next-action
# begins with `resume` (the resumable marker _resume_from + status.sh
# --check-paused key on); a value NOT in the closed enum still returns 1 (the
# addition is what admits gate-unobservable, not a wildcard). status.sh
# --check-paused surfaces it resumable=blocked, and the full render emits no
# unknown-cause warning.
echo "[§6] gate-unobservable: closed-enum membership, resume-first action, status.sh render"
( D="$ROOT/s6"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _next_actions_for_cause gate-unobservable >/dev/null 2>&1 \
    && ok "_next_actions_for_cause admits gate-unobservable" || bad "gate-unobservable should be enumerated"
  acts="$(_next_actions_for_cause gate-unobservable 2>/dev/null)"
  printf '%s' "$acts" | grep -qE '^resume' \
    && ok "gate-unobservable's first next-action begins with resume" || bad "first next-action must begin with resume (got '$acts')"
  # The action labels must be comma-free per element so the CSV round-trips.
  _write_tdd_fragment 0040-x 40 docs/tdd/0040-x.md 1 blocked review 1000 1000 "feat/0040-x" "" log "" "" "build,test-first,verify,verify-runtime" "" "" "" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0040-x gate-unobservable review "timeout: failed to run command 'claude': No such file or directory" 2>/dev/null; rc=$?
  [ "$rc" -eq 0 ] && ok "set_halt_cause gate-unobservable returns 0" || bad "set_halt_cause should accept gate-unobservable (got rc=$rc)"
  hc="$(_read_fragment_field "$STATE_DIR/0040-x.json" halt_cause)"
  [ "$hc" = "gate-unobservable" ] && ok "halt_cause written = gate-unobservable" || bad "halt_cause should be gate-unobservable (got '$hc')"
  # Negative: an unknown cause still returns 1 (the enum is still closed).
  set_halt_cause 0040-x not-a-real-cause-xyz review "" 2>/dev/null; rc2=$?
  [ "$rc2" -ne 0 ] && ok "an unknown cause still returns non-zero (enum stays closed)" || bad "unknown cause must return non-zero"
) || true

echo "[§6b] status.sh surfaces gate-unobservable as resumable=blocked with no unknown-cause warning"
( D="$ROOT/s6b"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  printf '{"schema":1,"started_at":1000,"updated_at":1001,"pid":1,"state":"blocked","total":1,"completed":0,"failed":0,"blocked":1,"skipped":0,"paused":0}\n' > "$D/state.d/run.json"
  _write_tdd_fragment 0040-x 40 docs/tdd/0040-x.md 1 blocked review 1000 1000 "feat/0040-x" "" log "" "" "build,test-first,verify,verify-runtime" "" "" "" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0040-x gate-unobservable review "timeout: No such file or directory" 2>/dev/null
  cp="$(bash "$REPO/scripts/status.sh" --logdir "$D" --check-paused 2>&1)"
  printf '%s' "$cp" | grep -qE 'slug=0040-x .*cause=gate-unobservable resumable=blocked' \
    && ok "--check-paused surfaces cause=gate-unobservable resumable=blocked" || bad "should surface gate-unobservable resumable=blocked (got: '$cp')"
  out="$(bash "$REPO/scripts/status.sh" --logdir "$D" 2>&1)"
  printf '%s' "$out" | grep -qi 'unknown halt_cause' \
    && bad "status.sh must NOT warn unknown-cause for gate-unobservable (got: $out)" \
    || ok "full render emits no unknown-cause fallback warning"
  printf '%s' "$out" | grep -q 'gate-unobservable' \
    && ok "the gate-unobservable cause label appears in the halt render" || bad "render should name gate-unobservable (got: $out)"
) || true

# --- report ----------------------------------------------------------------
# Fail loud (FR-74 #1): the result tally is what makes every assertion above
# enforceable — the final `[ "$FAIL" -eq 0 ]` sets the script's exit code, so a
# single `bad` makes `bash tests/transient-gate-resilience.test.sh` exit non-zero
# and the aggregator's `|| TGR_FAIL=1` (step 5) catches it.
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== transient-gate-resilience eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

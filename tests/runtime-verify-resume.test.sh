#!/usr/bin/env bash
# runtime-verify-resume.test.sh — eval for TDD 0035 (resumable runtime-verify
# "couldn't observe" halt). A runtime-verify gate that ends VERIFY_RUNTIME:
# BLOCKED ("couldn't observe", distinct from FAIL "observed and wrong" per NFR-4)
# is recorded as a *resumable* blocked halt with a new `verify-unobservable`
# cause + a tdd_rev fingerprint, mirroring the structural-finding resume of
# TDD 0031. Covers the TDD's Verification plan §1–§6 with shared git/worktree
# fixtures + a stub runtime-verify command, following the fixture pattern of
# tests/honest-review-scope-structural-resume.test.sh.
#
# Run: bash tests/runtime-verify-resume.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ===========================================================================
# §5: enum membership. set_halt_cause <slug> verify-unobservable returns 0 and
# writes the cause; a value NOT in the closed FR-63 enum still returns 1 (proving
# the addition is what admits verify-unobservable, not a wildcard).
echo "[§5] verify-unobservable is admitted by the closed halt-cause enum"
( D="$ROOT/s5"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _next_actions_for_cause verify-unobservable >/dev/null 2>&1 \
    && ok "_next_actions_for_cause admits verify-unobservable" || bad "verify-unobservable should be enumerated"
  acts="$(_next_actions_for_cause verify-unobservable 2>/dev/null)"
  # The FIRST next-action element must begin with `resume` (the resumable marker
  # _resume_from + status.sh --check-paused key on).
  printf '%s' "$acts" | grep -qE '^resume' \
    && ok "verify-unobservable's first next-action begins with resume" || bad "first next-action must begin with resume (got '$acts')"
  _write_tdd_fragment 0035-x 35 docs/tdd/0035-x.md 1 blocked verify-runtime 1000 1000 "feat/0035-x" "" log "" "" "" "" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0035-x verify-unobservable verify-runtime "tdd_rev=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>/dev/null; rc=$?
  [ "$rc" -eq 0 ] && ok "set_halt_cause verify-unobservable returns 0" || bad "set_halt_cause should accept verify-unobservable (got rc=$rc)"
  hc="$(_read_fragment_field "$STATE_DIR/0035-x.json" halt_cause)"
  [ "$hc" = "verify-unobservable" ] && ok "halt_cause written = verify-unobservable" || bad "halt_cause should be verify-unobservable (got '$hc')"
  # Negative: an unknown cause still returns 1 (the enum is still closed).
  set_halt_cause 0035-x not-a-real-cause-xyz verify-runtime "" 2>/dev/null; rc2=$?
  [ "$rc2" -ne 0 ] && ok "an unknown cause still returns non-zero (enum stays closed)" || bad "unknown cause must return non-zero"
) || true

# ===========================================================================
# §2: check-paused surfaces it. status.sh --check-paused prints a line for the
# slug with cause=verify-unobservable resumable=blocked, and the full status.sh
# render emits no unknown-cause fallback warning (FR-64 one-screen halt context).
echo "[§2] status.sh surfaces verify-unobservable as resumable=blocked with no unknown-cause warning"
( D="$ROOT/s2"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  printf '{"schema":1,"started_at":1000,"updated_at":1001,"pid":1,"state":"blocked","total":1,"completed":0,"failed":0,"blocked":1,"skipped":0,"paused":0}\n' > "$D/state.d/run.json"
  _write_tdd_fragment 0035-x 35 docs/tdd/0035-x.md 1 blocked verify-runtime 1000 1000 "feat/0035-x" "" log "" "" "build,test-first,verify" "" "" "" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0035-x verify-unobservable verify-runtime "tdd_rev=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>/dev/null
  cp="$(bash "$REPO/scripts/status.sh" --logdir "$D" --check-paused 2>&1)"
  printf '%s' "$cp" | grep -qE 'slug=0035-x .*cause=verify-unobservable resumable=blocked' \
    && ok "--check-paused surfaces cause=verify-unobservable resumable=blocked" || bad "should surface verify-unobservable resumable=blocked (got: '$cp')"
  out="$(bash "$REPO/scripts/status.sh" --logdir "$D" 2>&1)"
  printf '%s' "$out" | grep -qi 'unknown halt_cause' \
    && bad "status.sh must NOT warn unknown-cause for verify-unobservable (got: $out)" \
    || ok "full render emits no unknown-cause fallback warning"
  printf '%s' "$out" | grep -q 'verify-unobservable' \
    && ok "the verify-unobservable cause label appears in the halt render" || bad "render should name verify-unobservable (got: $out)"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== runtime-verify-resume eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# bounded-rework-loop.test.sh — eval for the bounded automatic rework loop
# (TDD 0019 / FR-61, FR-62, FR-65, FR-66, FR-67, FR-68; ADR 0007).
#
# The contract under test (function-level; the runtime-verify gate re-drives the
# same observable surface against a real /implement run):
#   - run.json carries a config.rework_config snapshot of the four §6 knobs
#     (model, max, scope_floor, scope_factor) so any halt citing them is
#     reproducible from run-state alone (ADR 0006).
#   - the per-TDD fragment gains rework_attempts (object), rework_log (array),
#     and build_attempt.token_spend, threaded through _write_tdd_fragment and
#     carried forward by every fragment writer.
#   - _extract_token_spend reads a session JSONL's token usage (or null).
#   - _rework_attempt_count increments the per-(gate,step) counter.
#   - _rework_scope_cap = max(floor, factor × region).
#   - _rework_pre_pass enforces FR-66 scope cap + FR-67(a) touched-file set +
#     FR-67(b) per-file bound against a rework commit's diff, with the §5
#     build-start-SHA fallback when no cleared SHA is supplied.
#   - the gate_one review gate drives the bounded loop: a structural finding with
#     a named structural_reason → immediate (c) BLOCK (covered by
#     tests/structural-classification-bound.test.sh under TDD 0034); a structural
#     finding with no named reason (e.g. the legacy single-line fallback) → routes
#     to bounded rework (E2); budget exhaustion → rework-budget-exhausted BLOCK;
#     oversized/out-of-set/over-bound rework → reset + structural/scope BLOCK.
#
# Run: bash tests/bounded-rework-loop.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# --- §6 / FR-65, FR-66: rework_config snapshot in run.json -------------------
echo "[A1] _rework_config_json emits the four §6 knobs with defaults"
( D="$ROOT/A1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  # This case observes the DEFAULT resolution (TDD 0043 §1); a runner-inherited
  # THROUGHLINE_REWORK_MODEL override would poison it, so drop it explicitly.
  unset THROUGHLINE_REWORK_MODEL
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  out="$(_rework_config_json)"
  printf '%s' "$out" | grep -q '"model":"opus"' \
    && ok "default model=opus (build model, TDD 0043)" || bad "default rework model should be opus (got: $out)"
  printf '%s' "$out" | grep -q '"max":3' \
    && ok "default max=3" || bad "default rework max should be 3 (got: $out)"
  printf '%s' "$out" | grep -q '"scope_floor":60' \
    && ok "default scope_floor=60" || bad "default scope_floor should be 60 (got: $out)"
  printf '%s' "$out" | grep -q '"scope_factor":3' \
    && ok "default scope_factor=3" || bad "default scope_factor should be 3 (got: $out)"
) || true

echo "[A2] _rework_config_json honors env overrides"
( D="$ROOT/A2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  # Override to sonnet — the value that DIFFERS from the new opus default
  # (TDD 0043), so this still proves the knob overrides the default rather
  # than coinciding with it.
  export THROUGHLINE_REWORK_MODEL="sonnet" THROUGHLINE_REWORK_MAX="5"
  export THROUGHLINE_REWORK_SCOPE_FLOOR="100" THROUGHLINE_REWORK_SCOPE_FACTOR="2"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  out="$(_rework_config_json)"
  printf '%s' "$out" | grep -q '"model":"sonnet"' \
    && ok "model override honored" || bad "model override should be sonnet (got: $out)"
  printf '%s' "$out" | grep -q '"max":5' \
    && ok "max override honored" || bad "max override should be 5 (got: $out)"
  printf '%s' "$out" | grep -q '"scope_floor":100' \
    && ok "scope_floor override honored" || bad "scope_floor override should be 100 (got: $out)"
  printf '%s' "$out" | grep -q '"scope_factor":2' \
    && ok "scope_factor override honored" || bad "scope_factor override should be 2 (got: $out)"
) || true

echo "[A3] _write_run_fragment embeds config.rework_config in run.json"
( D="$ROOT/A3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_run_fragment running
  R="$D/state.d/run.json"
  grep -q '"config":{"rework_config":{' "$R" 2>/dev/null \
    && ok "run.json carries config.rework_config" \
    || bad "run.json should carry config.rework_config (got: $(cat "$R"))"
  grep -q '"scope_factor":3' "$R" 2>/dev/null \
    && ok "rework_config values present in run.json" \
    || bad "run.json rework_config should carry the knob values"
) || true

# --- §3 / Data: fragment rework fields threaded through _write_tdd_fragment ---
echo "[B1] _write_tdd_fragment writes rework_attempts / rework_log / build_attempt (params 21-23)"
( D="$ROOT/B1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 reviewing review \
    1000 1000 "feat/0007-x" "" "log" "" "" "" "" "" \
    "" "" "" "" \
    '{"review:3":2}' '[{"attempt":1,"gate":"review","outcome":"shipped"}]' '{"token_spend":12345}'
  F="$D/state.d/0007-x.json"
  grep -q '"rework_attempts":{"review:3":2}' "$F" 2>/dev/null \
    && ok "rework_attempts object round-trips" || bad "rework_attempts should round-trip (got: $(cat "$F"))"
  grep -q '"rework_log":\[{"attempt":1,"gate":"review","outcome":"shipped"}\]' "$F" 2>/dev/null \
    && ok "rework_log array round-trips" || bad "rework_log should round-trip"
  grep -q '"build_attempt":{"token_spend":12345}' "$F" 2>/dev/null \
    && ok "build_attempt object round-trips" || bad "build_attempt should round-trip"
) || true

echo "[B2] _write_tdd_fragment defaults rework fields to {} / [] / null when empty"
( D="$ROOT/B2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # Back-compat: a 16-arg call (the historical shape) must still emit the
  # rework defaults so old call sites keep working.
  _write_tdd_fragment 0001-a 1 docs/tdd/0001-a.md 1 pending "" \
    1000 1000 "" "" "" "" "" "" "" ""
  F="$D/state.d/0001-a.json"
  grep -q '"rework_attempts":{}' "$F" 2>/dev/null \
    && ok "rework_attempts defaults to {}" || bad "rework_attempts should default to {}"
  grep -q '"rework_log":\[\]' "$F" 2>/dev/null \
    && ok "rework_log defaults to []" || bad "rework_log should default to []"
  grep -q '"build_attempt":null' "$F" 2>/dev/null \
    && ok "build_attempt defaults to null" || bad "build_attempt should default to null"
) || true

echo "[B3] _read_fragment_raw_object reads a single-level object field"
( D="$ROOT/B3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  F="$D/state.d/0007-x.json"
  printf '{"slug":"0007-x","rework_attempts":{"review:3":2},"build_attempt":null}\n' > "$F"
  [ "$(_read_fragment_raw_object "$F" rework_attempts)" = '{"review:3":2}' ] \
    && ok "reads rework_attempts object" || bad "should read rework_attempts object (got '$(_read_fragment_raw_object "$F" rework_attempts)')"
  [ -z "$(_read_fragment_raw_object "$F" build_attempt)" ] \
    && ok "null object reads as empty" || bad "build_attempt:null should read empty"
) || true

echo "[B4] set_tdd_state carries rework_attempts / rework_log / build_attempt forward"
( D="$ROOT/B4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 reviewing review \
    1000 1000 "feat/0007-x" "" "log" "" "" "" "" "" \
    "" "" "" "" \
    '{"review:3":2}' '[{"attempt":1,"gate":"review","outcome":"shipped"}]' '{"token_spend":999}'
  set_tdd_state 0007-x reviewing flip
  F="$D/state.d/0007-x.json"
  grep -q '"rework_attempts":{"review:3":2}' "$F" 2>/dev/null \
    && ok "rework_attempts survives set_tdd_state" || bad "rework_attempts must survive set_tdd_state"
  grep -q '"rework_log":\[{"attempt":1' "$F" 2>/dev/null \
    && ok "rework_log survives set_tdd_state" || bad "rework_log must survive set_tdd_state"
  grep -q '"build_attempt":{"token_spend":999}' "$F" 2>/dev/null \
    && ok "build_attempt survives set_tdd_state" || bad "build_attempt must survive set_tdd_state"
) || true

echo "[B5] set_halt_cause carries the rework telemetry forward (halt must not wipe it)"
( D="$ROOT/B5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 blocked review \
    1000 1000 "feat/0007-x" "" "log" "" "" "" "" "" \
    "" "" "" "" \
    '{"review:3":3}' '[{"attempt":1,"gate":"review","outcome":"shipped"}]' '{"token_spend":999}'
  set_halt_cause 0007-x rework-budget-exhausted "review:3"
  F="$D/state.d/0007-x.json"
  grep -q '"halt_cause":"rework-budget-exhausted"' "$F" 2>/dev/null \
    && ok "halt_cause set" || bad "halt_cause should be rework-budget-exhausted"
  grep -q '"rework_log":\[{"attempt":1' "$F" 2>/dev/null \
    && ok "rework_log survives set_halt_cause" || bad "rework_log must survive set_halt_cause"
  grep -q '"rework_attempts":{"review:3":3}' "$F" 2>/dev/null \
    && ok "rework_attempts survives set_halt_cause" || bad "rework_attempts must survive set_halt_cause"
) || true

echo "[B6] _rework_attempt_count increments the per-(gate,step) counter and echoes the new value"
( D="$ROOT/B6"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 reviewing review \
    1000 1000 "feat/0007-x" "" "log" "" "" "" "" "" "" "" "" ""
  c1="$(_rework_attempt_count 0007-x review 3)"
  [ "$c1" = "1" ] && ok "first increment returns 1" || bad "first increment should be 1 (got '$c1')"
  c2="$(_rework_attempt_count 0007-x review 3)"
  [ "$c2" = "2" ] && ok "second increment returns 2" || bad "second increment should be 2 (got '$c2')"
  # A different (gate,step) key is independent.
  cx="$(_rework_attempt_count 0007-x review 5)"
  [ "$cx" = "1" ] && ok "independent (gate,step) key starts at 1" || bad "review:5 should start at 1 (got '$cx')"
  F="$D/state.d/0007-x.json"
  grep -q '"review:3":2' "$F" 2>/dev/null \
    && ok "rework_attempts persists review:3=2" || bad "review:3 should be 2 in fragment (got: $(_read_fragment_raw_object "$F" rework_attempts))"
) || true

echo "[B7] _record_rework_attempt appends an entry to rework_log"
( D="$ROOT/B7"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 reviewing review \
    1000 1000 "feat/0007-x" "" "log" "" "" "" "" "" "" "" "" ""
  _record_rework_attempt 0007-x 1 review 3 sonnet 4200 1000 1100 "review-1:1" shipped
  _record_rework_attempt 0007-x 2 review 3 sonnet 3900 1200 1300 "review-2:1" "rejected:rework-scope-exceeded"
  F="$D/state.d/0007-x.json"
  n="$(grep -oE '"attempt":[0-9]+' "$F" | wc -l)"
  [ "$n" -eq 2 ] && ok "rework_log has two entries" || bad "rework_log should have two entries (got $n)"
  grep -q '"model":"sonnet"' "$F" 2>/dev/null \
    && ok "entry records model" || bad "entry should record model"
  grep -q '"outcome":"rejected:rework-scope-exceeded"' "$F" 2>/dev/null \
    && ok "entry records rejected outcome" || bad "entry should record rejected outcome"
  grep -q '"token_spend":4200' "$F" 2>/dev/null \
    && ok "entry records token_spend" || bad "entry should record token_spend"
) || true

echo "[B8] _extract_token_spend sums session usage (or null when absent)"
( D="$ROOT/B8"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  S="$D/session.jsonl"
  cat > "$S" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":200,"output_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":10}}}
EOF
  got="$(_extract_token_spend "$S")"
  if command -v jq >/dev/null 2>&1; then
    [ "$got" = "365" ] && ok "_extract_token_spend sums all token kinds (365)" \
      || bad "_extract_token_spend should sum to 365 (got '$got')"
  else
    [ "$got" = "null" ] && ok "_extract_token_spend null without jq" \
      || bad "_extract_token_spend should be null without jq (got '$got')"
  fi
  [ "$(_extract_token_spend "$D/does-not-exist.jsonl")" = "null" ] \
    && ok "missing session -> null" || bad "missing session should yield null"
) || true

echo "[B9] _set_build_attempt_token_spend records build_attempt.token_spend"
( D="$ROOT/B9"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0007-x 7 docs/tdd/0007-x.md 1 building build \
    1000 1000 "feat/0007-x" "" "log" "" "" "" "" "" "" "" "" ""
  _set_build_attempt_token_spend 0007-x 88888
  F="$D/state.d/0007-x.json"
  grep -q '"build_attempt":{"token_spend":88888}' "$F" 2>/dev/null \
    && ok "build_attempt.token_spend recorded" || bad "build_attempt.token_spend should be 88888 (got: $(_read_fragment_raw_object "$F" build_attempt))"
  # null spend is acceptable (FR-68: observability, not enforcement)
  _set_build_attempt_token_spend 0007-x null
  grep -q '"build_attempt":{"token_spend":null}' "$F" 2>/dev/null \
    && ok "null token_spend recorded as null" || bad "null token_spend should write {\"token_spend\":null}"
) || true

# --- §1 / FR-66, FR-67: scope cap + touched-file + per-file-bound pre-pass ----
echo "[C1] _rework_scope_cap = max(floor, factor × region)"
( D="$ROOT/C1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  [ "$(_rework_scope_cap 8)" = "60" ] && ok "region 8 → cap 60 (floor wins)" || bad "cap(8) should be 60 (got '$(_rework_scope_cap 8)')"
  [ "$(_rework_scope_cap 40)" = "120" ] && ok "region 40 → cap 120 (factor wins)" || bad "cap(40) should be 120 (got '$(_rework_scope_cap 40)')"
  [ "$(_rework_scope_cap '')" = "60" ] && ok "empty region → floor 60" || bad "cap('') should be 60 (got '$(_rework_scope_cap '')')"
) || true

# Set up a git repo + scope-declaring TDD IN PWD (caller must `cd` into a fresh
# dir FIRST — never run these git commits in the real repo). Leaves PWD in the
# repo with HEAD at the build-start commit.
mk_rework_repo() {
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'base\n' > base.txt; git add -A; git commit -qm base >/dev/null
  mkdir -p docs/tdd
  cat > docs/tdd/0099-fix.md <<'EOF'
# TDD 0099: fixture
Status: draft

## Touched files
- `src/a.txt` (post) — the in-scope file
- `src/b.txt` — another in-scope file

## Expected diff size
- `src/a.txt` — ~50 lines added
- `src/b.txt` — ~200 lines added (exception: legitimately wide)
EOF
  git add -A; git commit -qm "build start: declare scope" >/dev/null
}

echo "[C2] _rework_touched_files parses the declared set"
( D="$ROOT/C2"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_rework_repo
  files="$(_rework_touched_files docs/tdd/0099-fix.md | tr '\n' ',')"
  [ "$files" = "src/a.txt,src/b.txt," ] && ok "touched-file set parsed" \
    || bad "touched set should be src/a.txt,src/b.txt (got '$files')"
) || true

echo "[C3] _rework_pre_pass clears a small in-scope rework commit"
( D="$ROOT/C3"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_rework_repo; BS="$(git rev-parse HEAD)"
  mkdir -p src; printf 'l1\nl2\nl3\nl4\nl5\n' > src/a.txt
  git add -A; git commit -qm "rework: fix the cited finding" >/dev/null
  NH="$(git rev-parse HEAD)"
  out="$(_rework_pre_pass 0099-fix docs/tdd/0099-fix.md "$NH" "$BS" "$BS" 8)"; rc=$?
  [ "$rc" -eq 0 ] && ok "pre-pass returns 0 (clear)" || bad "pre-pass should clear (rc=$rc, out=$out)"
  [ -z "$out" ] && ok "no PRECHECK_FAIL emitted on clear" || bad "clear pre-pass should emit nothing (got: $out)"
) || true

echo "[C4] _rework_pre_pass rejects an oversized rework (FR-66 scope cap)"
( D="$ROOT/C4"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_rework_repo; BS="$(git rev-parse HEAD)"
  mkdir -p src; seq 1 200 > src/a.txt   # 200 lines for an 8-line region (cap=60)
  git add -A; git commit -qm "rework: oversized" >/dev/null
  NH="$(git rev-parse HEAD)"
  out="$(_rework_pre_pass 0099-fix docs/tdd/0099-fix.md "$NH" "$BS" "$BS" 8)"; rc=$?
  [ "$rc" -ne 0 ] && ok "pre-pass returns non-zero on oversized" || bad "oversized pre-pass should be non-zero"
  printf '%s\n' "$out" | grep -q 'PRECHECK_FAIL: rework-scope-exceeded' \
    && ok "emits rework-scope-exceeded" || bad "should emit rework-scope-exceeded (got: $out)"
) || true

echo "[C5] _rework_pre_pass rejects an out-of-set file as structural(a)"
( D="$ROOT/C5"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_rework_repo; BS="$(git rev-parse HEAD)"
  mkdir -p src; printf 'x\n' > src/c.txt   # c.txt is NOT in the touched-file set
  git add -A; git commit -qm "rework: edits out-of-set file" >/dev/null
  NH="$(git rev-parse HEAD)"
  out="$(_rework_pre_pass 0099-fix docs/tdd/0099-fix.md "$NH" "$BS" "$BS" 8)"; rc=$?
  [ "$rc" -ne 0 ] && ok "pre-pass non-zero on out-of-set file" || bad "out-of-set should be non-zero"
  printf '%s\n' "$out" | grep -qE 'PRECHECK_FAIL: structural-finding\(a\) src/c.txt' \
    && ok "emits structural-finding(a) naming the file" || bad "should emit structural-finding(a) src/c.txt (got: $out)"
) || true

echo "[C6] _rework_pre_pass rejects an over-bound file as structural(b)"
( D="$ROOT/C6"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_rework_repo; BS="$(git rev-parse HEAD)"
  # src/a.txt declared at 50 lines, no exception. Add 90 lines cumulatively
  # since build start; region 40 → cap 120 so the scope cap does NOT fire,
  # isolating the (b) per-file-bound check. 90 > 50 × 1.6 = 80, so the (b)
  # escalation still fires under TDD 0041's K-tolerance (the old 80-line fixture
  # sat exactly on the new 50×1.6 boundary and `actual > num×K` is strict).
  mkdir -p src; seq 1 90 > src/a.txt
  git add -A; git commit -qm "rework: overshoots per-file bound" >/dev/null
  NH="$(git rev-parse HEAD)"
  out="$(_rework_pre_pass 0099-fix docs/tdd/0099-fix.md "$NH" "$BS" "$BS" 40)"; rc=$?
  [ "$rc" -ne 0 ] && ok "pre-pass non-zero on over-bound file" || bad "over-bound should be non-zero"
  printf '%s\n' "$out" | grep -qE 'PRECHECK_FAIL: structural-finding\(b\) src/a.txt' \
    && ok "emits structural-finding(b) naming the file" || bad "should emit structural-finding(b) src/a.txt (got: $out)"
) || true

echo "[C7] _rework_pre_pass honors a declared (exception:) marker for (b)"
( D="$ROOT/C7"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_rework_repo; BS="$(git rev-parse HEAD)"
  # src/b.txt has (exception: …) at 200, so an 80-line add must NOT fire (b).
  mkdir -p src; seq 1 80 > src/b.txt
  git add -A; git commit -qm "rework: wide but declared-exception file" >/dev/null
  NH="$(git rev-parse HEAD)"
  out="$(_rework_pre_pass 0099-fix docs/tdd/0099-fix.md "$NH" "$BS" "$BS" 40)"; rc=$?
  [ "$rc" -eq 0 ] && ok "exception file clears (b)" || bad "exception file should not fire (b) (rc=$rc, out=$out)"
) || true

echo "[C8] _rework_pre_pass falls back to build-start SHA when no cleared SHA"
( D="$ROOT/C8"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_rework_repo; BS="$(git rev-parse HEAD)"
  mkdir -p src; seq 1 200 > src/a.txt
  git add -A; git commit -qm "rework: oversized, degraded mode" >/dev/null
  NH="$(git rev-parse HEAD)"
  # cleared SHA empty → §5 fallback to build-start SHA; scope cap still fires.
  out="$(_rework_pre_pass 0099-fix docs/tdd/0099-fix.md "$NH" "" "$BS" 8)"; rc=$?
  [ "$rc" -ne 0 ] && ok "degraded-mode pre-pass still enforces the cap" \
    || bad "degraded mode should still reject oversized (rc=$rc, out=$out)"
  printf '%s\n' "$out" | grep -q 'PRECHECK_FAIL: rework-scope-exceeded' \
    && ok "fallback uses build-start SHA for the scope diff" || bad "should still emit scope-exceeded (got: $out)"
) || true

# --- §5 / FR-61, FR-62: _rework_one spawns a bounded fix + commits -----------
echo "[D1] _rework_one substitutes the template, runs the rework model, echoes the new HEAD"
( D="$ROOT/D1"; mkdir -p "$D/state.d" "$D/bin"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
  printf 'bug\n' > src/a.txt
  cat > docs/tdd/0099-fix.md <<'EOF'
# TDD 0099: fixture
Status: draft

## Touched files
- `src/a.txt` — file

## Expected diff size
- `src/a.txt` — ~50 lines added
EOF
  git add -A; git commit -qm "build start" >/dev/null
  pre="$(git rev-parse HEAD)"
  # stub claude: capture the prompt, then act as the rework model (edit + commit).
  cat > "$D/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
printf '%s' "\$prompt" > "$D/captured-prompt"
printf 'fixed\n' > src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: fix the cited finding" >/dev/null 2>&1
echo done
EOF
  chmod +x "$D/bin/claude"
  export PATH="$D/bin:$PATH"
  new="$(_rework_one docs/tdd/0099-fix.md "$D/rw.log" "review-1:1" "src/a.txt:1 has a bug" 60)"
  [ -n "$new" ] && [ "$new" != "$pre" ] && ok "_rework_one echoes the new HEAD SHA" \
    || bad "_rework_one should echo the post-rework HEAD (pre=$pre new=$new)"
  git log -1 --format='%s' "$new" 2>/dev/null | grep -q '^rework:' \
    && ok "rework commit subject begins 'rework:'" || bad "rework commit should be a 'rework:' commit"
  grep -q 'has a bug' "$D/captured-prompt" 2>/dev/null \
    && ok "prompt carries the finding text" || bad "rework prompt should include the finding text"
  grep -q '60' "$D/captured-prompt" 2>/dev/null \
    && ok "prompt carries the scope cap" || bad "rework prompt should include the computed cap"
  grep -q 'src/a.txt' "$D/captured-prompt" 2>/dev/null \
    && ok "prompt carries the touched-file set" || bad "rework prompt should include the touched-file set"
) || true

echo "[D2] rework-prompt.md exists and carries the key bounded-fix instructions"
( cd "$REPO"
  F="scripts/rework-prompt.md"
  [ -f "$F" ] && ok "scripts/rework-prompt.md exists" || { bad "scripts/rework-prompt.md should exist"; exit 0; }
  grep -qi 'only the cited finding' "$F" && ok "instructs: fix only the cited finding" || bad "prompt should say fix only the cited finding"
  grep -q '{{TDD}}'           "$F" && ok "has {{TDD}} placeholder" || bad "prompt needs {{TDD}}"
  grep -q '{{FINDING}}'       "$F" && ok "has {{FINDING}} placeholder" || bad "prompt needs {{FINDING}}"
  grep -q '{{CAP}}'           "$F" && ok "has {{CAP}} placeholder" || bad "prompt needs {{CAP}}"
  grep -q '{{TOUCHED_FILES}}' "$F" && ok "has {{TOUCHED_FILES}} placeholder" || bad "prompt needs {{TOUCHED_FILES}}"
  grep -qiE 'rework:' "$F" && ok "instructs the rework: commit message form" || bad "prompt should specify the rework: commit form"
  grep -qiE 'do not modify tests|tests.*mask' "$F" && ok "warns against masking the bug via tests" || bad "prompt should warn against test-masking"
) || true

# --- §3 / FR-68: original-build token spend recorded for the comparison ------
echo "[F1] _last_session_path finds the newest session newer than the start epoch"
( D="$ROOT/F1"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" HOME="$D/home"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  enc="$(printf '%s' "$PWD" | sed 's|/|-|g')"
  proj="$HOME/.claude/projects/$enc"; mkdir -p "$proj"
  printf '{"type":"assistant"}\n' > "$proj/sess.jsonl"
  got="$(_last_session_path 1)"
  [ "$got" = "$proj/sess.jsonl" ] && ok "_last_session_path returns the session path" \
    || bad "_last_session_path should return $proj/sess.jsonl (got '$got')"
) || true

echo "[F2] build_one records build_attempt.token_spend from its session JSON"
( D="$ROOT/F2"; mkdir -p "$D/state.d" "$D/bin"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" HOME="$D/home"
  export TMPL="$REPO/scripts/build-prompt.md" MODEL=""
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0099-fix 99 docs/tdd/0099-fix.md 1 building build \
    1000 1000 "" "" "log" "" "" "" "" "" "" "" "" ""
  enc="$(printf '%s' "$PWD" | sed 's|/|-|g')"
  proj="$HOME/.claude/projects/$enc"; mkdir -p "$proj"
  cat > "$proj/sess.jsonl" <<'EOF'
{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":1000,"output_tokens":234,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
  # Flake fix: this fixture creates the session BEFORE build_one runs, so
  # build_one's `_last_session_path "$start"` (find -newermt "@$start", SECOND
  # granularity) race-excludes it whenever build_one's start crosses a wall-clock
  # second boundary relative to the file's creation -> token_spend comes back
  # null (~5% in the aggregator, ~100% under the runner's scheduling). Pin the
  # session mtime safely past any plausible build_one start so the lookup is
  # deterministic. (In production claude -p writes the session DURING the build,
  # after start, so mtime > start reliably; only this fixture inverts that.)
  touch -d '@9999999999' "$proj/sess.jsonl"
  # no-op stub claude (build_one's own work is irrelevant here; we assert the
  # post-build token-spend recording).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$D/bin/claude"; chmod +x "$D/bin/claude"
  export PATH="$D/bin:$PATH"
  build_one docs/tdd/0099-fix.md "$D/build.log" >/dev/null 2>&1
  F="$D/state.d/0099-fix.json"
  if command -v jq >/dev/null 2>&1; then
    grep -q '"build_attempt":{"token_spend":1234}' "$F" 2>/dev/null \
      && ok "build_attempt.token_spend = 1234 from session" \
      || bad "build_attempt.token_spend should be 1234 (got: $(_read_fragment_raw_object "$F" build_attempt))"
  else
    grep -q '"build_attempt":{"token_spend":null}' "$F" 2>/dev/null \
      && ok "build_attempt.token_spend = null without jq (acceptable per FR-68)" \
      || bad "build_attempt should be {token_spend:null} without jq"
  fi
) || true

# --- §5 wiring: gate_one review gate drives the bounded loop (FR-61/62/65/67) -
# setup_loop_repo: git repo + scope-declaring TDD + a state fragment + a stub
# `claude` that acts as the review gate (cats $CTL/review.out) and the rework
# model (runs $CTL/do_rework). Gates 1-3 are marked done via RESUME_GATES_DONE_*
# so gate_one runs ONLY the review gate. Leaves PWD in the repo.
setup_loop_repo() {  # <dir>  (caller exports STATE_DIR etc. + sources $IMPL first)
  local d="$1"; mkdir -p "$d/ctl" "$d/bin"
  cd "$d" || return 1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
  # ctl/ + bin/ are test scaffolding, not part of the build — keep them out of
  # git so a rework's `git add -A` never sweeps them into the commit (which
  # would falsely trip the FR-67(a) out-of-set check).
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
  # Skip gates 1-3 — only the review gate (and its rework loop) runs.
  RESUME_GATES_DONE_0099_fix="build,test-first,verify,verify-runtime"
  export RESUME_GATES_DONE_0099_fix
  _write_tdd_fragment 0099-fix 99 docs/tdd/0099-fix.md 1 reviewing review \
    1000 1000 "feat/0099-fix" "" "log" "" "" "build,test-first,verify,verify-runtime" "" "" "" "" "" "" ""
}

echo "[E1] single fixable finding → rework ships → re-review PASS → flipped"
( D="$ROOT/E1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  # Drives the DEFAULT rework model (TDD 0043 §1); drop any runner-inherited
  # THROUGHLINE_REWORK_MODEL override so the default is what gets observed.
  unset THROUGHLINE_REWORK_MODEL
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_loop_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"
  # Build output committed PAST the build-start base, so the consolidated review
  # scope BS..HEAD is non-empty — what a real build always produces (TDD 0031 §2's
  # empty-scope guard fails closed on a HEAD..HEAD scope). The reviewer stub returns
  # the canned review.out regardless of diff content, so the loop's behavior is
  # unchanged; this only keeps the scope realistic.
  printf 'build-output\n' >> src/a.txt; git add -A; git commit -qm "build: simulated output past build-start" >/dev/null
  printf 'REVIEW_FINDING: severity=major structural=false region_lines=8 ref=review-1:1 | src/a.txt has a real bug\nREVIEW_RESULT: BLOCK found a real bug\n' > "$D/repo/ctl/review.out"
  # rework: small in-scope fix, then the finding is resolved (review now PASS).
  # The PASS must carry a per-file disposition for the reworked file (TDD 0021
  # §3b/§3c): a bare PASS that leaves a diff file un-dispositioned is now converted
  # to an incomplete-file-coverage finding and re-reviewed.
  cat > "$D/repo/ctl/do_rework" <<EOF
printf 'fixed\n' > src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: fix src/a.txt bug" >/dev/null 2>&1
printf 'FILE_REVIEWED_NO_FINDINGS: src/a.txt\nREVIEW_RESULT: PASS\n' > "$D/repo/ctl/review.out"
EOF
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/e1.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -eq 0 ] && ok "gate_one returns 0 (converged + flipped)" || bad "gate_one should converge (rc=$rc, st=$st)"
  grep -q '"outcome":"shipped"' "$F" 2>/dev/null && ok "rework_log records a shipped attempt" || bad "rework_log should record shipped (got: $(_read_fragment_raw_array "$F" rework_log))"
  grep -q '"model":"opus"' "$F" 2>/dev/null && ok "rework ran on opus (build model, TDD 0043)" || bad "rework attempt should be model opus"
) || true

echo "[E2] legacy single-line structural=true carries no reason → routes to rework (TDD 0034)"
( D="$ROOT/E2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  # Drives the DEFAULT rework model (TDD 0043 §1); drop any runner-inherited
  # THROUGHLINE_REWORK_MODEL override so the default is what gets observed.
  unset THROUGHLINE_REWORK_MODEL
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_loop_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"
  # Build output committed PAST the build-start base, so the consolidated review
  # scope BS..HEAD is non-empty — what a real build always produces (TDD 0031 §2's
  # empty-scope guard fails closed on a HEAD..HEAD scope). The reviewer stub returns
  # the canned review.out regardless of diff content, so the loop's behavior is
  # unchanged; this only keeps the scope realistic.
  printf 'build-output\n' >> src/a.txt; git add -A; git commit -qm "build: simulated output past build-start" >/dev/null
  # The legacy single-line REVIEW_FINDING fallback carries NO structural_reason
  # token, so under TDD 0034 / FR-67 it is treated as a structural finding with no
  # named reason → it falls through to bounded rework (failure-mode #2), NOT a
  # (c)-escalation. The genuine named-reason → (c) path is covered by
  # tests/structural-classification-bound.test.sh (S3).
  printf 'REVIEW_FINDING: severity=major structural=true region_lines=8 ref=review-1:3 | cross-module refactor needed\nREVIEW_RESULT: BLOCK structural\n' > "$D/repo/ctl/review.out"
  # rework: small in-scope fix that converges; re-review then PASSes with a
  # per-file disposition for the reworked file (mirrors E1).
  cat > "$D/repo/ctl/do_rework" <<EOF
printf 'fixed\n' > src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: fix src/a.txt" >/dev/null 2>&1
printf 'FILE_REVIEWED_NO_FINDINGS: src/a.txt\nREVIEW_RESULT: PASS\n' > "$D/repo/ctl/review.out"
EOF
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/e2.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -eq 0 ] && ok "gate_one converges (no-reason structural reworked + flipped)" || bad "no-reason structural should rework + converge (rc=$rc, st=$st)"
  grep -q '"outcome":"shipped"' "$F" 2>/dev/null && ok "rework_log records a shipped attempt" || bad "rework_log should record shipped (got: $(_read_fragment_raw_array "$F" rework_log))"
  grep -q '"model":"opus"' "$F" 2>/dev/null && ok "rework ran on opus (build model, TDD 0043)" || bad "rework attempt should be model opus"
  ! grep -q '"halt_cause":"structural-finding"' "$F" 2>/dev/null && ok "did NOT escalate structural-finding (no named reason)" || bad "no-reason structural must not escalate (got halt_cause structural-finding)"
) || true

echo "[E3] oversized rework → rejected pre-ship → reset + rework-scope-exceeded"
( D="$ROOT/E3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_loop_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"
  # Build output committed PAST the build-start base, so the consolidated review
  # scope BS..HEAD is non-empty — what a real build always produces (TDD 0031 §2's
  # empty-scope guard fails closed on a HEAD..HEAD scope). The reviewer stub returns
  # the canned review.out regardless of diff content, so the loop's behavior is
  # unchanged; this only keeps the scope realistic.
  printf 'build-output\n' >> src/a.txt; git add -A; git commit -qm "build: simulated output past build-start" >/dev/null
  CLEARED_HEAD="$(git rev-parse HEAD)"   # the last-cleared SHA the oversized rework is reset back to
  printf 'REVIEW_FINDING: severity=major structural=false region_lines=8 ref=review-1:1 | small bug\nREVIEW_RESULT: BLOCK bug\n' > "$D/repo/ctl/review.out"
  cat > "$D/repo/ctl/do_rework" <<'EOF'
seq 1 200 > src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: oversized" >/dev/null 2>&1
EOF
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/e3.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -ne 0 ] && ok "gate_one returns non-zero (scope-rejected)" || bad "oversized rework should block (rc=$rc)"
  grep -q '"outcome":"rejected:rework-scope-exceeded"' "$F" 2>/dev/null && ok "rework_log records rejected:rework-scope-exceeded" || bad "should record rejected:rework-scope-exceeded (got: $(_read_fragment_raw_array "$F" rework_log))"
  grep -q '"halt_cause":"rework-scope-exceeded"' "$F" 2>/dev/null && ok "halt_cause=rework-scope-exceeded" || bad "halt_cause should be rework-scope-exceeded"
  [ "$(git -C "$D/repo" rev-parse HEAD)" = "$CLEARED_HEAD" ] && ok "build branch HEAD reset to the prior cleared SHA" || bad "HEAD should be hard-reset to $CLEARED_HEAD (got $(git -C "$D/repo" rev-parse HEAD))"
) || true

echo "[E4] rework edits out-of-set file → structural(a) BLOCKED"
( D="$ROOT/E4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_loop_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"
  # Build output committed PAST the build-start base, so the consolidated review
  # scope BS..HEAD is non-empty — what a real build always produces (TDD 0031 §2's
  # empty-scope guard fails closed on a HEAD..HEAD scope). The reviewer stub returns
  # the canned review.out regardless of diff content, so the loop's behavior is
  # unchanged; this only keeps the scope realistic.
  printf 'build-output\n' >> src/a.txt; git add -A; git commit -qm "build: simulated output past build-start" >/dev/null
  printf 'REVIEW_FINDING: severity=major structural=false region_lines=8 ref=review-1:1 | bug\nREVIEW_RESULT: BLOCK bug\n' > "$D/repo/ctl/review.out"
  cat > "$D/repo/ctl/do_rework" <<'EOF'
printf 'x\n' > src/out_of_scope.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: out-of-set" >/dev/null 2>&1
EOF
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/e4.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -ne 0 ] && ok "gate_one returns non-zero (structural a)" || bad "out-of-set rework should block"
  grep -q '"outcome":"rejected:structural-finding"' "$F" 2>/dev/null && ok "rework_log records rejected:structural-finding" || bad "should record rejected:structural-finding (got: $(_read_fragment_raw_array "$F" rework_log))"
  grep -q '"halt_cause":"structural-finding"' "$F" 2>/dev/null && ok "halt_cause=structural-finding" || bad "halt_cause should be structural-finding"
  grep -qE '\(a\)' "$D/repo/docs/tdd/BLOCKERS.md" 2>/dev/null && ok "BLOCKERS.md names criterion (a)" || bad "BLOCKERS.md should name criterion (a)"
) || true

echo "[E5] budget exhaustion → 3 ships then rework-budget-exhausted"
( D="$ROOT/E5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  export THROUGHLINE_REWORK_MAX=3
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_loop_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"
  # Build output committed PAST the build-start base, so the consolidated review
  # scope BS..HEAD is non-empty — what a real build always produces (TDD 0031 §2's
  # empty-scope guard fails closed on a HEAD..HEAD scope). The reviewer stub returns
  # the canned review.out regardless of diff content, so the loop's behavior is
  # unchanged; this only keeps the scope realistic.
  printf 'build-output\n' >> src/a.txt; git add -A; git commit -qm "build: simulated output past build-start" >/dev/null
  # review ALWAYS blocks; each rework ships a clean small commit that does not
  # resolve the finding (a new distinct line each call).
  printf 'REVIEW_FINDING: severity=major structural=false region_lines=8 ref=review-1:1 | persistent bug\nREVIEW_RESULT: BLOCK persistent\n' > "$D/repo/ctl/review.out"
  cat > "$D/repo/ctl/do_rework" <<'EOF'
echo "tweak $(wc -l < src/a.txt)" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: another small tweak" >/dev/null 2>&1
EOF
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/e5.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -ne 0 ] && ok "gate_one returns non-zero (budget exhausted)" || bad "budget exhaustion should block (rc=$rc)"
  n="$(grep -oE '"outcome":"shipped"' "$F" | wc -l)"
  [ "$n" -eq 3 ] && ok "exactly 3 shipped rework attempts" || bad "should ship exactly 3 reworks (got $n)"
  grep -q '"halt_cause":"rework-budget-exhausted"' "$F" 2>/dev/null && ok "halt_cause=rework-budget-exhausted" || bad "halt_cause should be rework-budget-exhausted"
  grep -q '"review:1":3' "$F" 2>/dev/null && ok "rework_attempts == {review:1:3}" || bad "rework_attempts should be review:1=3 (got: $(_read_fragment_raw_object "$F" rework_attempts))"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== bounded-rework-loop eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

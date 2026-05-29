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
#   - the gate_one review gate drives the bounded loop: structural(c) tag →
#     immediate BLOCK; budget exhaustion → rework-budget-exhausted BLOCK;
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
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  out="$(_rework_config_json)"
  printf '%s' "$out" | grep -q '"model":"sonnet"' \
    && ok "default model=sonnet" || bad "default rework model should be sonnet (got: $out)"
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
  export THROUGHLINE_REWORK_MODEL="opus" THROUGHLINE_REWORK_MAX="5"
  export THROUGHLINE_REWORK_SCOPE_FLOOR="100" THROUGHLINE_REWORK_SCOPE_FACTOR="2"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  out="$(_rework_config_json)"
  printf '%s' "$out" | grep -q '"model":"opus"' \
    && ok "model override honored" || bad "model override should be opus (got: $out)"
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

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== bounded-rework-loop eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

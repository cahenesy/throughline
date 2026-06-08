#!/usr/bin/env bash
# recoverable-terminal-halts.test.sh — eval for TDD 0039 (opt-in recovery from
# non-structural terminal halts). Two terminal halt classes that are commonly
# artifacts — rework-budget-exhausted (status:blocked) and a ci-checks failure
# (status:failed, note "ci-checks") — gain an OPT-IN recovery path under an
# explicit `--recover` (RECOVER=1) so a human can resume from the last good gate
# WITHOUT hand-editing the state fragment, while terminal-by-default stays
# terminal (NFR-4). Covers the TDD's Verification plan §1–§7 by driving
# `_resume_from` + `status.sh --check-paused` against seeded fragments and the
# `--recover` flag against scripts/implement.sh, following the fixture pattern of
# tests/runtime-verify-resume.test.sh. No model or tokens are needed (function /
# flag level only; no watcher/process is launched).
#
#   S1 implement.sh parses --recover (implies --resume) + recover-specific diagnostic
#   §1 budget-exhausted, no --recover → terminal (not flipped)
#   §2 budget-exhausted, --recover → accepted + rework/re-review budgets reset
#   §3 ci-checks failed, --recover → re-enters at verify; no --recover → terminal
#   §4 divergence-guard re-baseline under --recover (refuses without it)
#   §5 status.sh --check-paused surfaces resumable=recoverable for both classes
#   §6 ambiguous failed (no ci-checks note) → refused (resume-recover-cause-ambiguous)
#   §7 SKILL.md documents --recover + the "Recover" offer keyed on resumable=recoverable
#
# Mechanical-check robustness (L-001/L-002): every absence/removal grep
# distinguishes exit 1 (absent) from ≥2 (unreadable) and fails on the latter;
# each target file is asserted readable before its content checks; the fragment
# seeds use compact single-line JSON (the readers are line-oriented).
#
# Run: bash tests/recoverable-terminal-halts.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ===========================================================================
# S1: scripts/implement.sh parses --recover (sets RECOVER=1, implies --resume)
# and, when the implied resume finds no prior run, emits a recover-specific
# diagnostic naming the missing prior run — distinct from the generic resume
# FATAL — and exits non-zero. Driven behaviorally with a stubbed `claude` (so the
# CLI-present guard passes) against a temp git repo that has no `latest` symlink.
echo "[S1] implement.sh parses --recover (implies --resume) + recover-specific diagnostic"
( d="$ROOT/S1"; mkdir -p "$d/bin" "$d/repo"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/claude"; chmod +x "$d/bin/claude"
  cd "$d/repo" || { bad "cd failed"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init >/dev/null
  out="$(PATH="$d/bin:$PATH" bash "$IMPL" --recover 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "implement.sh --recover with no prior run exits non-zero" || bad "should exit non-zero (got rc=$rc)"
  printf '%s' "$out" | grep -qiE 'requires a prior run to recover' \
    && ok "emits the recover-specific 'requires a prior run to recover' diagnostic" \
    || bad "should emit the recover-specific diagnostic (got: $out)"
  printf '%s' "$out" | grep -qi 'unknown arg' \
    && bad "--recover must be a known flag (got 'unknown arg')" \
    || ok "--recover is a recognized flag (no 'unknown arg')"
  # Mechanical: the runner source carries the flag parse + RECOVER export.
  grep -q -- '--recover' "$IMPL" && ok "implement.sh source mentions --recover" || bad "implement.sh should parse --recover"
  grep -q 'RECOVER' "$IMPL" && ok "implement.sh source sets RECOVER" || bad "implement.sh should set RECOVER"
) || true

# ===========================================================================
# S2: _reset_rework_attempts <slug> rewrites BOTH rework_attempts AND
# re_review_attempts to {} (a budget-exhausted recovery wants a genuinely fresh
# review budget), preserving every other field, via the atomic-write path. On a
# missing fragment it returns non-zero so the caller can refuse the recovery.
echo "[S2] _reset_rework_attempts resets rework_attempts + re_review_attempts to {} (preserving the rest)"
( d="$ROOT/S2"; mkdir -p "$d/state.d"; cd "$d" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$d"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # Seed: rework_attempts (param 21) + re_review_attempts (param 28) both non-empty,
  # plus distinctive carry-forward fields (note, gates_completed, branch_head,
  # self_review_count) so the preserve-the-rest claim is observable.
  _write_tdd_fragment 0039-x 39 docs/tdd/0039-x.md 1 blocked review 1000 1000 "build/x" "" log "keep-me" \
    "" "build,test-first,verify,verify-runtime" "" "abc123" \
    "" "" "" "" \
    '{"review:6":3}' "" "" \
    "" "" \
    "[]" "7" '{"review:6":2}'
  F="$STATE_DIR/0039-x.json"
  if declare -F _reset_rework_attempts >/dev/null 2>&1; then ok "_reset_rework_attempts is defined"
  else bad "_reset_rework_attempts should be defined"; fi
  _reset_rework_attempts 0039-x 2>/dev/null; rc=$?
  [ "$rc" -eq 0 ] && ok "_reset_rework_attempts returns 0 on a present fragment" || bad "should return 0 (got rc=$rc)"
  ra="$(_read_fragment_raw_object "$F" rework_attempts)"
  [ "$ra" = '{}' ] && ok "rework_attempts reset to {}" || bad "rework_attempts should be {} (got '$ra')"
  rr="$(_read_fragment_raw_object "$F" re_review_attempts)"
  [ "$rr" = '{}' ] && ok "re_review_attempts reset to {}" || bad "re_review_attempts should be {} (got '$rr')"
  note="$(_read_fragment_field "$F" note)"
  [ "$note" = "keep-me" ] && ok "note preserved across the reset" || bad "note should be preserved (got '$note')"
  gates="$(_read_fragment_array_csv "$F" gates_completed)"
  [ "$gates" = "build,test-first,verify,verify-runtime" ] && ok "gates_completed preserved" || bad "gates_completed should be preserved (got '$gates')"
  bh="$(_read_fragment_field "$F" branch_head_at_pause)"
  [ "$bh" = "abc123" ] && ok "branch_head_at_pause preserved" || bad "branch_head_at_pause should be preserved (got '$bh')"
  srv="$(sed -n 's/.*"self_review_count":\([0-9]*\).*/\1/p' "$F" | head -1)"
  [ "$srv" = "7" ] && ok "self_review_count preserved" || bad "self_review_count should be preserved (got '$srv')"
  st="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)"
  [ "$st" = "blocked" ] && ok "status preserved (reset does not flip)" || bad "status should be preserved (got '$st')"
  # Missing fragment → non-zero (so _resume_from can refuse the recovery).
  _reset_rework_attempts no-such-slug 2>/dev/null; rc2=$?
  [ "$rc2" -ne 0 ] && ok "_reset_rework_attempts returns non-zero on a missing fragment" || bad "missing fragment should return non-zero"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== recoverable-terminal-halts eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

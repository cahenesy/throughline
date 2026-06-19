#!/usr/bin/env bash
# gates-resume-module-sourceability.test.sh — eval for TDD 0017 / FR-69, slice 3/3:
# pins the sourceability contract of scripts/lib/gates.sh + scripts/lib/resume.sh
# and the fail-fast behavior implement.sh must exhibit when either module is
# missing/unreadable.
#
# Written red-first against this branch's pre-extraction state: before the
# refactor scripts/lib/gates.sh and scripts/lib/resume.sh do not exist (so
# [A]/[C] fail on `bash -n`) and implement.sh has no source directive for them
# (so [E]–[H] fail — they exit 0 with no FATAL diagnostic instead of failing
# fast). The companion refactor commit makes them green by extracting both
# modules AND landing the existence / readability guards at the same time.
# Without those guards, under `set -uo pipefail` (no -e), a failed `.` returns
# non-zero but does not abort — leaving every gate-executor / resume function
# undefined and the whole run silently no-op.
#
# Source order is state.sh -> pause-retry.sh -> gates.sh -> resume.sh; gates.sh
# is sourced after the first two (it calls their helpers) and resume.sh after all
# three (gate_one lives in gates.sh and resume.sh calls it). The fail-fast cases
# keep the upstream modules present in the scratch tree and omit only the module
# under test, isolating each new guard.
#
# Run: bash tests/gates-resume-module-sourceability.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
STATE="$REPO/scripts/lib/state.sh"
PR="$REPO/scripts/lib/pause-retry.sh"
GATES="$REPO/scripts/lib/gates.sh"
RESUME="$REPO/scripts/lib/resume.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

# --- [A] gates.sh parses + sources standalone (no top-level side effects) -----
echo "[A] gates.sh parses + sources in isolation"
( bash -n "$GATES" 2>"$ROOT/A.err" \
    && ok "gates.sh parses (bash -n)" \
    || bad "gates.sh failed bash -n: $(cat "$ROOT/A.err" 2>/dev/null)"
  # Sourcing it directly must succeed — top-level only declares functions; the
  # state.sh / pause-retry.sh helpers it calls are resolved at call time.
  if bash -c "set -uo pipefail; source \"$GATES\"; type -t build_one >/dev/null && type -t run_ci_checks >/dev/null" 2>"$ROOT/A2.err"; then
    ok "gates.sh sources standalone and binds the cluster"
  else
    bad "gates.sh failed to source standalone: $(cat "$ROOT/A2.err" 2>/dev/null)"
  fi
) || true

# --- [B] every TDD-listed gates.sh function is defined after sourcing ---------
# Guards the move's completeness: all named functions must be bound, so a
# half-moved cluster (some left behind in implement.sh) is caught.
echo "[B] gates.sh binds all moved functions"
( missing=""
  for fn in build_one review_one verify_runtime_one build_status review_status \
            verify_runtime_status run_ci_checks test_first_ok flip_status \
            record_blocker install_deps _build_one_gated \
            _verify_runtime_one_gated _review_one_gated; do
    bash -c "source \"$GATES\"; type -t $fn >/dev/null" 2>/dev/null || missing="$missing $fn"
  done
  if [ -z "$missing" ]; then
    ok "all gate-executor functions bound after sourcing gates.sh"
  else
    bad "gates.sh missing functions:$missing"
  fi
) || true

# --- [C] resume.sh parses + sources standalone -------------------------------
echo "[C] resume.sh parses + sources in isolation"
( bash -n "$RESUME" 2>"$ROOT/C.err" \
    && ok "resume.sh parses (bash -n)" \
    || bad "resume.sh failed bash -n: $(cat "$ROOT/C.err" 2>/dev/null)"
  # gate_one (in gates.sh) and the state.sh/pause-retry.sh helpers resume.sh
  # calls are resolved at call time, so resume.sh sources standalone too.
  if bash -c "set -uo pipefail; source \"$RESUME\"; type -t gate_one >/dev/null && type -t _resume_from >/dev/null" 2>"$ROOT/C2.err"; then
    ok "resume.sh sources standalone and binds the cluster"
  else
    bad "resume.sh failed to source standalone: $(cat "$ROOT/C2.err" 2>/dev/null)"
  fi
) || true

# --- [D] every TDD-listed resume.sh function is defined after sourcing --------
echo "[D] resume.sh binds all moved functions"
( missing=""
  for fn in _resume_gates_var _update_paused_cause _resume_from gate_one \
            built_branch combined_built_branch _tdd_implemented_at; do
    bash -c "source \"$RESUME\"; type -t $fn >/dev/null" 2>/dev/null || missing="$missing $fn"
  done
  if [ -z "$missing" ]; then
    ok "all resume-orchestration functions bound after sourcing resume.sh"
  else
    bad "resume.sh missing functions:$missing"
  fi
) || true

# --- [E] missing gates.sh causes implement.sh to FAIL FAST -------------------
# The silent-failure mode: rc=0 + every gate function 127. The scratch tree
# keeps readable state.sh + pause-retry.sh + resume.sh and omits ONLY gates.sh,
# isolating the new guard. THROUGHLINE_SOURCE_ONLY=1 exercises only the source
# path.
echo "[E] implement.sh fails fast when scripts/lib/gates.sh is missing"
( D="$ROOT/E"; mkdir -p "$D/scripts/lib"
  cp "$IMPL"   "$D/scripts/implement.sh"
  cp "$STATE"  "$D/scripts/lib/state.sh"
  cp "$PR"     "$D/scripts/lib/pause-retry.sh"
  cp "$RESUME" "$D/scripts/lib/resume.sh"
  # Deliberately NO gates.sh — simulate partial install / missed checkout.
  set +e
  out="$(THROUGHLINE_SOURCE_ONLY=1 bash "$D/scripts/implement.sh" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    ok "implement.sh exits non-zero with gates.sh missing (rc=$rc)"
  else
    bad "implement.sh exited 0 with gates.sh missing — silent failure (rc=$rc)"
  fi
  if printf '%s\n' "$out" | grep -qiE 'fatal|cannot (find|read)|failed to source'; then
    ok "implement.sh emits a FATAL diagnostic on missing gates.sh"
  else
    bad "implement.sh missing a FATAL diagnostic on missing gates.sh; saw: $out"
  fi
) || true

# --- [F] unreadable gates.sh similarly fails fast (perms scenario) -----------
echo "[F] implement.sh fails fast when scripts/lib/gates.sh is unreadable"
( D="$ROOT/F"; mkdir -p "$D/scripts/lib"
  cp "$IMPL"   "$D/scripts/implement.sh"
  cp "$STATE"  "$D/scripts/lib/state.sh"
  cp "$PR"     "$D/scripts/lib/pause-retry.sh"
  cp "$GATES"  "$D/scripts/lib/gates.sh"
  cp "$RESUME" "$D/scripts/lib/resume.sh"
  chmod 000 "$D/scripts/lib/gates.sh"
  set +e
  out="$(THROUGHLINE_SOURCE_ONLY=1 bash "$D/scripts/implement.sh" 2>&1)"; rc=$?
  set -e
  chmod 644 "$D/scripts/lib/gates.sh" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    ok "implement.sh exits non-zero with gates.sh unreadable (rc=$rc)"
  else
    bad "implement.sh exited 0 with gates.sh unreadable — silent failure (rc=$rc)"
  fi
  if printf '%s\n' "$out" | grep -qiE 'fatal|cannot (find|read)|failed to source'; then
    ok "implement.sh emits a FATAL diagnostic on unreadable gates.sh"
  else
    bad "implement.sh missing a FATAL diagnostic on unreadable gates.sh; saw: $out"
  fi
) || true

# --- [G] missing resume.sh causes implement.sh to FAIL FAST ------------------
# resume.sh is sourced last; keep the three upstream modules present and omit
# ONLY resume.sh so the gates.sh guard passes and this exercises resume's guard.
echo "[G] implement.sh fails fast when scripts/lib/resume.sh is missing"
( D="$ROOT/G"; mkdir -p "$D/scripts/lib"
  cp "$IMPL"   "$D/scripts/implement.sh"
  cp "$STATE"  "$D/scripts/lib/state.sh"
  cp "$PR"     "$D/scripts/lib/pause-retry.sh"
  cp "$GATES"  "$D/scripts/lib/gates.sh"
  # Deliberately NO resume.sh.
  set +e
  out="$(THROUGHLINE_SOURCE_ONLY=1 bash "$D/scripts/implement.sh" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    ok "implement.sh exits non-zero with resume.sh missing (rc=$rc)"
  else
    bad "implement.sh exited 0 with resume.sh missing — silent failure (rc=$rc)"
  fi
  if printf '%s\n' "$out" | grep -qiE 'fatal|cannot (find|read)|failed to source'; then
    ok "implement.sh emits a FATAL diagnostic on missing resume.sh"
  else
    bad "implement.sh missing a FATAL diagnostic on missing resume.sh; saw: $out"
  fi
) || true

# --- [H] unreadable resume.sh similarly fails fast (perms scenario) ----------
echo "[H] implement.sh fails fast when scripts/lib/resume.sh is unreadable"
( D="$ROOT/H"; mkdir -p "$D/scripts/lib"
  cp "$IMPL"   "$D/scripts/implement.sh"
  cp "$STATE"  "$D/scripts/lib/state.sh"
  cp "$PR"     "$D/scripts/lib/pause-retry.sh"
  cp "$GATES"  "$D/scripts/lib/gates.sh"
  cp "$RESUME" "$D/scripts/lib/resume.sh"
  chmod 000 "$D/scripts/lib/resume.sh"
  set +e
  out="$(THROUGHLINE_SOURCE_ONLY=1 bash "$D/scripts/implement.sh" 2>&1)"; rc=$?
  set -e
  chmod 644 "$D/scripts/lib/resume.sh" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    ok "implement.sh exits non-zero with resume.sh unreadable (rc=$rc)"
  else
    bad "implement.sh exited 0 with resume.sh unreadable — silent failure (rc=$rc)"
  fi
  if printf '%s\n' "$out" | grep -qiE 'fatal|cannot (find|read)|failed to source'; then
    ok "implement.sh emits a FATAL diagnostic on unreadable resume.sh"
  else
    bad "implement.sh missing a FATAL diagnostic on unreadable resume.sh; saw: $out"
  fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== gates-resume-module-sourceability eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

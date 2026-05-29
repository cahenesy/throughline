#!/usr/bin/env bash
# pause-retry-module-sourceability.test.sh — eval for TDD 0016 / FR-69, slice 2/3:
# pins the sourceability contract of scripts/lib/pause-retry.sh and the fail-fast
# behavior implement.sh must exhibit when the module is missing/unreadable.
#
# Written red-first against this branch's pre-extraction state: before the
# refactor scripts/lib/pause-retry.sh does not exist (so [A] fails on `bash -n`)
# and implement.sh has no source directive for it (so [C]/[D] fail — they exit 0
# with no FATAL diagnostic instead of failing fast). The companion refactor
# commit makes all four green by extracting the module AND landing the existence
# / readability guard at the same time. Without that guard, under
# `set -uo pipefail` (no -e), a failed `.` returns non-zero but does not abort —
# leaving every pause/retry-classification function undefined and a recoverable
# failure silently mis-routed with no audit trail.
#
# The module is sourced AFTER lib/state.sh, so [C]/[D] keep a readable state.sh
# present in the scratch tree and exercise ONLY the pause-retry.sh guard.
#
# Run: bash tests/pause-retry-module-sourceability.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
STATE="$REPO/scripts/lib/state.sh"
PR="$REPO/scripts/lib/pause-retry.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

# --- [A] pause-retry.sh parses + sources standalone (no top-level side effects) -
echo "[A] pause-retry.sh parses + sources in isolation"
( bash -n "$PR" 2>"$ROOT/A.err" \
    && ok "pause-retry.sh parses (bash -n)" \
    || bad "pause-retry.sh failed bash -n: $(cat "$ROOT/A.err" 2>/dev/null)"
  # Sourcing it directly must succeed — top-level only declares functions; the
  # state.sh helpers it calls are resolved at call time, not at source time.
  if bash -c "set -uo pipefail; source \"$PR\"; type -t _classify_cause >/dev/null && type -t record_session_pointer >/dev/null" 2>"$ROOT/A2.err"; then
    ok "pause-retry.sh sources standalone and binds the cluster"
  else
    bad "pause-retry.sh failed to source standalone: $(cat "$ROOT/A2.err" 2>/dev/null)"
  fi
) || true

# --- [B] every TDD-listed function is defined after sourcing -----------------
# Guards the move's completeness: all six named functions must be bound, so a
# half-moved cluster (some left behind in implement.sh) is caught.
echo "[B] pause-retry.sh binds all six moved functions"
( missing=""
  for fn in _recoverable_patterns _classify_cause _enter_paused _retry_in_gate _append_retry record_session_pointer; do
    bash -c "source \"$PR\"; type -t $fn >/dev/null" 2>/dev/null || missing="$missing $fn"
  done
  if [ -z "$missing" ]; then
    ok "all six functions bound after sourcing pause-retry.sh"
  else
    bad "pause-retry.sh missing functions:$missing"
  fi
) || true

# --- [C] missing pause-retry.sh causes implement.sh to FAIL FAST -------------
# The silent-failure mode: rc=0 + every pause/retry function 127 + a recoverable
# failure mis-routed. The scratch tree keeps a readable state.sh (so its guard
# passes) and deliberately omits pause-retry.sh, isolating the new guard.
# THROUGHLINE_SOURCE_ONLY=1 exercises only the source path.
echo "[C] implement.sh fails fast when scripts/lib/pause-retry.sh is missing"
( D="$ROOT/C"; mkdir -p "$D/scripts/lib"
  cp "$IMPL"   "$D/scripts/implement.sh"
  cp "$STATE"  "$D/scripts/lib/state.sh"
  # Deliberately NO pause-retry.sh — simulate partial install / missed checkout.
  set +e
  out="$(THROUGHLINE_SOURCE_ONLY=1 bash "$D/scripts/implement.sh" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    ok "implement.sh exits non-zero with pause-retry.sh missing (rc=$rc)"
  else
    bad "implement.sh exited 0 with pause-retry.sh missing — silent failure (rc=$rc)"
  fi
  if printf '%s\n' "$out" | grep -qiE 'fatal|cannot (find|read)|failed to source'; then
    ok "implement.sh emits a FATAL diagnostic on missing pause-retry.sh"
  else
    bad "implement.sh missing a FATAL diagnostic on missing pause-retry.sh; saw: $out"
  fi
) || true

# --- [D] unreadable pause-retry.sh similarly fails fast (perms scenario) -----
echo "[D] implement.sh fails fast when scripts/lib/pause-retry.sh is unreadable"
( D="$ROOT/D"; mkdir -p "$D/scripts/lib"
  cp "$IMPL"   "$D/scripts/implement.sh"
  cp "$STATE"  "$D/scripts/lib/state.sh"
  cp "$PR"     "$D/scripts/lib/pause-retry.sh"
  chmod 000 "$D/scripts/lib/pause-retry.sh"
  set +e
  out="$(THROUGHLINE_SOURCE_ONLY=1 bash "$D/scripts/implement.sh" 2>&1)"; rc=$?
  set -e
  chmod 644 "$D/scripts/lib/pause-retry.sh" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    ok "implement.sh exits non-zero with pause-retry.sh unreadable (rc=$rc)"
  else
    bad "implement.sh exited 0 with pause-retry.sh unreadable — silent failure (rc=$rc)"
  fi
  if printf '%s\n' "$out" | grep -qiE 'fatal|cannot (find|read)|failed to source'; then
    ok "implement.sh emits a FATAL diagnostic on unreadable pause-retry.sh"
  else
    bad "implement.sh missing a FATAL diagnostic on unreadable pause-retry.sh; saw: $out"
  fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== pause-retry-module-sourceability eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

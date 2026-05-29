#!/usr/bin/env bash
# state-module-sourceability.test.sh — eval for TDD 0015 / FR-69, slice 1/3:
# pins the sourceability contract of scripts/lib/state.sh and the fail-fast
# behavior implement.sh must exhibit when the module is missing/unreadable.
#
# Written red-first against master, before the extraction: on master HEAD
# scripts/lib/state.sh does not exist (so [A] fails on `bash -n`) and
# implement.sh has no source directive (so [C]/[D] fail — they exit 0 with no
# FATAL diagnostic instead of failing fast). The companion refactor commit
# makes all three green by extracting the module AND landing the existence /
# readability guard at the same time. Without that guard, under
# `set -uo pipefail` (no -e), a failed `.` returns non-zero but does not
# abort — leaving every state-writing function undefined and the run silently
# no-op with no audit trail.
#
# Run: bash tests/state-module-sourceability.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
STATE="$REPO/scripts/lib/state.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

# --- [A] state.sh parses + sources standalone (no top-level side effects) ----
echo "[A] state.sh parses + sources in isolation"
( bash -n "$STATE" 2>"$ROOT/A.err" \
    && ok "state.sh parses (bash -n)" \
    || bad "state.sh failed bash -n: $(cat "$ROOT/A.err")"
  # Sourcing it directly must succeed — top-level only declares functions; any
  # state-dir / lock side effects belong to call sites in implement.sh.
  if bash -c "set -uo pipefail; source \"$STATE\"; type -t state_init >/dev/null" 2>"$ROOT/A2.err"; then
    ok "state.sh sources standalone and binds state_init"
  else
    bad "state.sh failed to source standalone: $(cat "$ROOT/A2.err")"
  fi
) || true

# --- [C] missing state.sh causes implement.sh to FAIL FAST ------------------
# The silent-failure mode the review flagged: rc=0 + every state function 127
# + the run proceeds with no fragments written. The test isolates the source
# directive by invoking implement.sh out of a scratch tree that does NOT have
# scripts/lib/state.sh — and exercises only the source path by setting
# THROUGHLINE_SOURCE_ONLY=1 so the runtime side effects do not run.
echo "[C] implement.sh fails fast when scripts/lib/state.sh is missing"
( D="$ROOT/C"; mkdir -p "$D/scripts"
  cp "$IMPL" "$D/scripts/implement.sh"
  # Deliberately NO state.sh — simulate partial install / missed checkout.
  set +e
  out="$(THROUGHLINE_SOURCE_ONLY=1 bash "$D/scripts/implement.sh" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    ok "implement.sh exits non-zero with state.sh missing (rc=$rc)"
  else
    bad "implement.sh exited 0 with state.sh missing — silent failure (rc=$rc)"
  fi
  if printf '%s\n' "$out" | grep -qiE 'fatal|cannot (find|read)|failed to source'; then
    ok "implement.sh emits a FATAL diagnostic on missing state.sh"
  else
    bad "implement.sh missing a FATAL diagnostic on missing state.sh; saw: $out"
  fi
) || true

# --- [D] unreadable state.sh similarly fails fast (perms scenario) ----------
echo "[D] implement.sh fails fast when scripts/lib/state.sh is unreadable"
( D="$ROOT/D"; mkdir -p "$D/scripts/lib"
  cp "$IMPL"  "$D/scripts/implement.sh"
  cp "$STATE" "$D/scripts/lib/state.sh"
  chmod 000 "$D/scripts/lib/state.sh"
  set +e
  out="$(THROUGHLINE_SOURCE_ONLY=1 bash "$D/scripts/implement.sh" 2>&1)"; rc=$?
  set -e
  chmod 644 "$D/scripts/lib/state.sh" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    ok "implement.sh exits non-zero with state.sh unreadable (rc=$rc)"
  else
    bad "implement.sh exited 0 with state.sh unreadable — silent failure (rc=$rc)"
  fi
  if printf '%s\n' "$out" | grep -qiE 'fatal|cannot (find|read)|failed to source'; then
    ok "implement.sh emits a FATAL diagnostic on unreadable state.sh"
  else
    bad "implement.sh missing a FATAL diagnostic on unreadable state.sh; saw: $out"
  fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== state-module-sourceability eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

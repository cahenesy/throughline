#!/usr/bin/env bash
# verdicts.test.sh — eval for TDD 0061 / FR-15, FR-25, FR-82:
# pins scripts/lib/verdicts.sh (write/read/require + tl_test_first_observe).
#
# Written red-first: before TDD 0061 lands, verdicts.sh does not exist.
# Run: bash tests/verdicts.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib/verdicts.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT" "$RESULTS"' EXIT

src() { bash -c "set -uo pipefail; source \"$LIB\"; $*"; }

# --- [A] parses + sources + binds the contract -------------------------------
echo "[A] verdicts.sh parses + sources in isolation"
( bash -n "$LIB" 2>"$ROOT/A.err" \
    && ok "verdicts.sh parses (bash -n)" \
    || bad "verdicts.sh failed bash -n: $(cat "$ROOT/A.err" 2>/dev/null)"
  if bash -c "set -uo pipefail; source \"$LIB\"; type -t tl_verdict_dir && type -t tl_verdict_write && type -t tl_verdict_read && type -t tl_verdict_require_flip && type -t tl_test_first_observe" >/dev/null 2>"$ROOT/A2.err"; then
    ok "binds dir/write/read/require_flip/test_first_observe"
  else
    bad "failed to source/bind: $(cat "$ROOT/A2.err" 2>/dev/null)"
  fi
) || true

# --- [B] write creates <repo>/docs/tdd/.implement-logs/<run>/<slug>/<gate>.json
echo "[B] tl_verdict_write creates the ADR 0011 artifact"
( R="$ROOT/b"; mkdir -p "$R"
  set +e
  src "tl_verdict_write \"$R\" r s test-first PASS 'git log …'" >/dev/null 2>"$ROOT/B.err"
  rc=$?
  set -e
  f="$R/docs/tdd/.implement-logs/r/s/test-first.json"
  [ "$rc" -eq 0 ] && [ -f "$f" ] && ok "wrote $f (rc=0)" \
    || bad "write rc=$rc file-exists=$([ -f "$f" ] && echo y || echo n) err=$(cat "$ROOT/B.err")"
  if [ -f "$f" ]; then
    st="$(tl_json_field() { :; }; bash -c "source \"$REPO/scripts/lib/json.sh\"; tl_json_field status" <"$f")"
    [ "$st" = "PASS" ] && ok "status field is PASS" || bad "status='$st' want PASS"
    gt="$(bash -c "source \"$REPO/scripts/lib/json.sh\"; tl_json_field gate" <"$f")"
    [ "$gt" = "test-first" ] && ok "gate field is test-first" || bad "gate='$gt'"
  fi
) || true

# --- [C] require_flip is rc 1 until all four gates satisfy the flip rule ------
echo "[C] tl_verdict_require_flip stays rc 1 until all four are written"
( R="$ROOT/c"; mkdir -p "$R"
  src "tl_verdict_require_flip \"$R\" r s"; rc=$?
  [ "$rc" -eq 1 ] && ok "missing files → rc 1" || bad "empty require rc=$rc want 1"

  src "tl_verdict_write \"$R\" r s test-first PASS e1; tl_verdict_write \"$R\" r s ci-checks PASS e2; tl_verdict_write \"$R\" r s review PASS e3"
  src "tl_verdict_require_flip \"$R\" r s"; rc=$?
  [ "$rc" -eq 1 ] && ok "three PASS, runtime-verify missing → rc 1" \
    || bad "three-of-four require rc=$rc want 1"

  src "tl_verdict_write \"$R\" r s runtime-verify PASS e4"
  src "tl_verdict_require_flip \"$R\" r s"; rc=$?
  [ "$rc" -eq 0 ] && ok "four PASS → rc 0" || bad "four PASS require rc=$rc want 0"
) || true

# --- [D] SKIP without evidence fails require; SKIP with evidence on rv ok -----
echo "[D] runtime-verify SKIP requires non-empty evidence"
( R="$ROOT/d"; mkdir -p "$R"
  src "tl_verdict_write \"$R\" r s test-first PASS a
       tl_verdict_write \"$R\" r s ci-checks PASS b
       tl_verdict_write \"$R\" r s review PASS c
       tl_verdict_write \"$R\" r s runtime-verify SKIP ''"
  src "tl_verdict_require_flip \"$R\" r s"; rc=$?
  [ "$rc" -eq 1 ] && ok "SKIP with empty evidence → rc 1" || bad "empty-SKIP require rc=$rc want 1"

  src "tl_verdict_write \"$R\" r s runtime-verify SKIP 'no observable surface'"
  src "tl_verdict_require_flip \"$R\" r s"; rc=$?
  [ "$rc" -eq 0 ] && ok "SKIP with evidence → rc 0" || bad "justified SKIP require rc=$rc want 0"
) || true

# --- [E] reject unknown gate/status with rc 2 --------------------------------
echo "[E] unknown gate/status rejected (rc 2)"
( R="$ROOT/e"; mkdir -p "$R"
  set +e
  src "tl_verdict_write \"$R\" r s review WHATEVER x" >/dev/null 2>"$ROOT/E.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] && ok "bad status WHATEVER → rc 2" || bad "bad status rc=$rc want 2"
  grep -q 'WHATEVER' "$ROOT/E.err" && ok "stderr names the bad token" \
    || bad "stderr did not name WHATEVER ($(cat "$ROOT/E.err"))"
  [ ! -f "$R/docs/tdd/.implement-logs/r/s/review.json" ] \
    && ok "bad write created no file" || bad "bad write left a file"

  set +e
  src "tl_verdict_write \"$R\" r s not-a-gate PASS x" >/dev/null 2>"$ROOT/E2.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] && ok "bad gate → rc 2" || bad "bad gate rc=$rc want 2"
) || true

# --- [F] missing read is rc 1, not 0-with-empty ------------------------------
echo "[F] tl_verdict_read missing file is rc 1"
( R="$ROOT/f"; mkdir -p "$R"
  set +e
  out="$(src "tl_verdict_read \"$R\" r s test-first" 2>/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] && ok "missing read → rc 1" || bad "missing read rc=$rc want 1"
  [ -z "$out" ] && ok "missing read stdout empty" || bad "missing read out='$out'"
) || true

# --- [G] slug with slash rejected --------------------------------------------
echo "[G] slug containing / is rejected"
( R="$ROOT/g"; mkdir -p "$R"
  set +e
  src "tl_verdict_write \"$R\" r 'evil/slug' test-first PASS x" >/dev/null 2>"$ROOT/G.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "slash slug rejected (rc=$rc)" || bad "slash slug accepted"
  [ ! -d "$R/docs/tdd/.implement-logs/r/evil" ] \
    && ok "slash slug did not create a nested dir" || bad "slash slug escaped into a path"
) || true

# --- [H] functions do not use process cwd ------------------------------------
echo "[H] write honors <repo-root> even when cwd is elsewhere"
( R="$ROOT/h"; mkdir -p "$R" "$ROOT/h-cwd"
  ( cd "$ROOT/h-cwd" && src "tl_verdict_write \"$R\" r s ci-checks PASS ev" )
  [ -f "$R/docs/tdd/.implement-logs/r/s/ci-checks.json" ] \
    && ok "file landed under repo-root, not cwd" \
    || bad "file missing under repo-root"
  [ ! -e "$ROOT/h-cwd/docs" ] && ok "cwd was not used as repo-root" \
    || bad "wrote under cwd"
) || true

# --- [I] tl_test_first_observe: feat-only fail; test-then-feat pass -----------
echo "[I] tl_test_first_observe on a fixture repo"
mkfix() { # <dir>
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" checkout -q -b master 2>/dev/null || git -C "$d" branch -M master
  git -C "$d" config user.email t@e; git -C "$d" config user.name t
  printf 'init\n' >"$d/f"
  git -C "$d" add f; git -C "$d" commit -qm init
}
( D="$ROOT/i-feat"; mkfix "$D"
  git -C "$D" checkout -q -b build
  printf 'x\n' >>"$D/f"; git -C "$D" add f; git -C "$D" commit -qm 'feat: x'
  set +e
  src "tl_test_first_observe \"$D\""; rc=$?
  set -e
  [ "$rc" -eq 1 ] && ok "feat-only → rc 1" || bad "feat-only rc=$rc want 1"
)
( D="$ROOT/i-ok"; mkfix "$D"
  git -C "$D" checkout -q -b build
  printf 't\n' >>"$D/f"; git -C "$D" add f; git -C "$D" commit -qm 'test(failing): x'
  printf 'x\n' >>"$D/f"; git -C "$D" add f; git -C "$D" commit -qm 'feat: x'
  set +e
  src "tl_test_first_observe \"$D\""; rc=$?
  set -e
  [ "$rc" -eq 0 ] && ok "test(failing): then feat: → rc 0" || bad "ordered pair rc=$rc want 0"
)
( D="$ROOT/i-empty"; mkdir -p "$D"; git -C "$D" init -q
  git -C "$D" config user.email t@e; git -C "$D" config user.name t
  set +e
  src "tl_test_first_observe \"$D\""; rc=$?
  set -e
  [ "$rc" -eq 1 ] && ok "empty repo → rc 1" || bad "empty repo rc=$rc want 1"
)
( D="$ROOT/i-late"; mkfix "$D"
  git -C "$D" checkout -q -b build
  printf 'x\n' >>"$D/f"; git -C "$D" add f; git -C "$D" commit -qm 'feat: x'
  printf 't\n' >>"$D/f"; git -C "$D" add f; git -C "$D" commit -qm 'test(failing): late'
  set +e
  src "tl_test_first_observe \"$D\""; rc=$?
  set -e
  [ "$rc" -eq 1 ] && ok "feat: before test(failing): → rc 1" \
    || bad "reversed order rc=$rc want 1"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== verdicts eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

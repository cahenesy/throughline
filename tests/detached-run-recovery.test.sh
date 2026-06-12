#!/usr/bin/env bash
# detached-run-recovery.test.sh — eval for the single-run lock identity check
# (TDD 0054 A25 / FR-39).
#
# The lock stored a bare PID and staleness was decided by `kill -0` alone — if
# an unrelated live process had REUSED a dead runner's PID, the lock read as
# "alive" and wedged ALL future runs until manually removed. The fix stores
# `PID <start-token>`; a PID-alive lock whose token MISMATCHES the live
# process's resolved token is provably reused -> stale, safe to break. Every
# can't-verify case (token absent, no resolver) fails SAFE (alive) — breaking
# a legitimately-held lock is the dangerous direction (TDD 0054 §Failure modes).
#
#   §1 _lock_start_token: live pid -> token; dead/invalid pid -> empty
#   §2 _run_lock_owner decision table (reused/match/old-lock/dead/malformed)
#   §3 launch outcome: reused-PID lock -> run proceeds; held lock -> refused
#   §4 lock format `PID <token>`; status.sh ACTIVE check parses field 1
#   §W dogfood: wired into the aggregator and propagates failure
#
# Run: bash tests/detached-run-recovery.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
STATUS="$REPO/scripts/status.sh"
RESULTS="$(mktemp)"
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"; rm -f "$RESULTS"' EXIT

# Source the helpers once for the whole eval (they are defined above the
# SOURCE_ONLY guard). HAVE_TOKEN gates the identity-specific asserts: on a host
# with neither /proc nor ps the contract IS the PID-only fallback (§2/§3 cover it).
THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" 2>/dev/null \
  || { bad "INFRA: cannot source implement.sh with THROUGHLINE_SOURCE_ONLY=1"; exit 1; }
HAVE_TOKEN=0; [ -n "$(_lock_start_token "$$" 2>/dev/null || true)" ] && HAVE_TOKEN=1

echo "[§1] _lock_start_token: live pid -> stable token; dead/invalid -> empty"
command -v _lock_start_token >/dev/null 2>&1 || bad "_lock_start_token is not defined after sourcing"
if [ "$HAVE_TOKEN" = 1 ]; then
  t1="$(_lock_start_token "$$")"; t2="$(_lock_start_token "$$")"
  [ -n "$t1" ] && [ "$t1" = "$t2" ] && ok "live pid resolves a stable non-empty token" \
    || bad "live pid token unstable or empty ('$t1' vs '$t2')"
else
  ok "no start-token resolver on this host — PID-only fallback is the contract (§2/§3)"
fi
sleep 0.05 & _dead=$!; wait "$_dead" 2>/dev/null
[ -z "$(_lock_start_token "$_dead")" ] && ok "dead pid -> empty token" || bad "dead pid must yield an empty token"
[ -z "$(_lock_start_token abc)" ] && [ -z "$(_lock_start_token 0)" ] && [ -z "$(_lock_start_token "")" ] \
  && ok "invalid pid (garbage/0/empty) -> empty token" || bad "invalid pid must yield an empty token"

echo "[§2] _run_lock_owner: held vs stale decision table"
command -v _run_lock_owner >/dev/null 2>&1 || bad "_run_lock_owner is not defined after sourcing"
L="$ROOT/lock"
sleep 60 & VICTIM=$!   # tracked child; killed below by PID (never by pattern)
if [ "$HAVE_TOKEN" = 1 ]; then
  printf '%s %s\n' "$VICTIM" "REUSED-PID-BOGUS-TOKEN" > "$L"
  _run_lock_owner "$L" >/dev/null && bad "live PID + MISMATCHED token must read STALE (provably reused PID)" \
    || ok "live PID + mismatched token -> stale (reused-PID wedge broken)"
  printf '%s %s\n' "$VICTIM" "$(_lock_start_token "$VICTIM")" > "$L"
  owner="$(_run_lock_owner "$L")" && [ "$owner" = "$VICTIM" ] \
    && ok "control: live PID + MATCHING token -> held (owner pid reported)" \
    || bad "matching PID+token lock must read HELD (got rc=$? owner='${owner:-}')"
fi
printf '%s\n' "$VICTIM" > "$L"
_run_lock_owner "$L" >/dev/null && ok "control: token-absent old lock + live PID -> held (PID-only fallback)" \
  || bad "old-format live lock must fail SAFE (held)"
kill "$VICTIM" 2>/dev/null; wait "$VICTIM" 2>/dev/null
printf '%s SOME-TOKEN\n' "$_dead" > "$L"
_run_lock_owner "$L" >/dev/null && bad "dead PID must read stale regardless of token" || ok "dead PID + token -> stale"
printf '%s\n' "$_dead" > "$L"
_run_lock_owner "$L" >/dev/null && bad "dead PID-only lock must read stale (today's reclaim)" || ok "dead PID-only -> stale"
: > "$L"
_run_lock_owner "$L" >/dev/null && bad "empty lock must read stale" || ok "empty lock -> stale"
printf 'notapid\n' > "$L"
_run_lock_owner "$L" >/dev/null && bad "garbage lock must read stale" || ok "garbage lock -> stale"
rm -f "$L"
_run_lock_owner "$L" >/dev/null && bad "absent lock must read stale" || ok "absent lock -> stale"

echo "[§3] launch outcome: the staleness decision gates the real runner"
D="$ROOT/repo"; mkdir -p "$D/docs/tdd/.implement-logs" "$D/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$D/bin/claude"; chmod +x "$D/bin/claude"
RLOCK="$D/docs/tdd/.implement-logs/.run.lock"
launch() { (cd "$D" && PATH="$D/bin:$PATH" bash "$IMPL" --change ci 2>&1); }
sleep 60 & VICTIM=$!
if [ "$HAVE_TOKEN" = 1 ]; then
  printf '%s %s\n' "$VICTIM" "REUSED-PID-BOGUS-TOKEN" > "$RLOCK"
  out="$(launch)"; rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "No buildable TDDs" \
    && ok "reused-PID lock is broken: the run PROCEEDS (rc=0)" \
    || bad "reused-PID lock must not wedge the runner (rc=$rc: $(printf '%s' "$out" | head -2))"
  [ ! -f "$RLOCK" ] && ok "reclaimed lock is released on exit" || bad "lock left behind after a reclaimed run"
fi
printf '%s\n' "$VICTIM" > "$RLOCK"   # live owner, old PID-only format
out="$(launch)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "already in progress" \
  && ok "control: live old-format lock -> run REFUSED (no over-correction)" \
  || bad "live PID-only lock must still refuse a second run (rc=$rc)"
kill "$VICTIM" 2>/dev/null; wait "$VICTIM" 2>/dev/null
printf '%s\n' "$VICTIM" > "$RLOCK"   # now-dead owner
out="$(launch)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "No buildable TDDs" \
  && ok "control: dead-owner lock reclaimed -> run proceeds" \
  || bad "dead-owner lock must be reclaimed (rc=$rc)"

echo "[§4] lock format: writer stamps PID+token; status.sh ACTIVE parses field 1"
command -v _write_run_lock >/dev/null 2>&1 || bad "_write_run_lock is not defined after sourcing"
_write_run_lock "$L" 2>/dev/null || true
wpid=""; wtok=""
read -r wpid wtok < "$L" 2>/dev/null || true
[ "$wpid" = "$$" ] && ok "writer stamps the caller pid as field 1" || bad "writer field 1 must be the pid (got '$wpid')"
if [ "$HAVE_TOKEN" = 1 ]; then
  [ "$wtok" = "$(_lock_start_token "$$")" ] && ok "writer stamps the start-token as field 2" \
    || bad "writer field 2 must be the start-token (got '$wtok')"
fi
S="$ROOT/srepo"; mkdir -p "$S/docs/tdd/.implement-logs/run1/state.d"
printf '{"mode":"sequential","integration_branch":"master","started_at":100,"updated_at":200,"state":"running","total":1}\n' \
  > "$S/docs/tdd/.implement-logs/run1/state.d/run.json"
ln -s run1 "$S/docs/tdd/.implement-logs/latest"
printf '%s SOME-START-TOKEN\n' "$$" > "$S/docs/tdd/.implement-logs/.run.lock"
sout="$( (cd "$S" && bash "$STATUS") 2>&1 )"
printf '%s' "$sout" | grep -q "no active /implement run" \
  && bad "status.sh ACTIVE check broke on the two-field lock (live run read as inactive)" \
  || ok "status.sh parses the lock's first field: live run still reads ACTIVE"

echo "[§W] dogfood: this eval is wired into the aggregator"
AGG="$REPO/tests/implement-gate.test.sh"
grep -q 'detached-run-recovery.test.sh' "$AGG" \
  && ok "registered in implement-gate.test.sh" || bad "detached-run-recovery.test.sh is not registered in the aggregator"
grep -q '\[ "\$DRR_FAIL" -eq 0 \]' "$AGG" \
  && ok "aggregator AND-chain goes non-zero when this eval fails" || bad "DRR_FAIL term missing from the aggregator AND-chain"

echo
total=$(grep -c . "$RESULTS"); fails=$(grep -c fail "$RESULTS" || true)
echo "=== detached-run-recovery eval: $((total - fails)) passed, $fails failed ==="
[ "$fails" -eq 0 ]

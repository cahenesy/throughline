#!/usr/bin/env bash
# run-record.test.sh — eval for TDD 0061 / FR-27, FR-39, FR-40, FR-43, FR-18:
# pins scripts/lib/run-record.sh (init, set_tdd, lock reclaim, next_gate,
# atomic write).
#
# Written red-first: before TDD 0061 lands, run-record.sh does not exist.
# Run: bash tests/run-record.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib/run-record.sh"
JLIB="$REPO/scripts/lib/json.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT" "$RESULTS"' EXIT

src() { bash -c "set -uo pipefail; source \"$LIB\"; $*"; }
field() { # <file> <key>
  bash -c "set -uo pipefail; source \"$JLIB\"; tl_json_field \"$2\"" <"$1"
}

# --- [A] parses + sources ----------------------------------------------------
echo "[A] run-record.sh parses + sources in isolation"
( bash -n "$LIB" 2>"$ROOT/A.err" \
    && ok "run-record.sh parses (bash -n)" \
    || bad "run-record.sh failed bash -n: $(cat "$ROOT/A.err" 2>/dev/null)"
  if bash -c "set -uo pipefail; source \"$LIB\"; type -t tl_run_init && type -t tl_run_set_tdd && type -t tl_run_set_pr && type -t tl_run_lock && type -t tl_run_unlock && type -t tl_run_lock_reclaim && type -t tl_run_next_gate" >/dev/null 2>"$ROOT/A2.err"; then
    ok "binds init/set_tdd/set_pr/lock/unlock/reclaim/next_gate"
  else
    bad "failed to source/bind: $(cat "$ROOT/A2.err" 2>/dev/null)"
  fi
) || true

# --- [B] tl_run_init writes run.json and points latest -----------------------
echo "[B] tl_run_init writes run.json + latest symlink"
( R="$ROOT/b"; mkdir -p "$R"
  src "tl_run_init \"$R\" run1"
  f="$R/docs/tdd/.implement-logs/run1/run.json"
  [ -f "$f" ] && ok "run.json exists" || bad "run.json missing"
  [ "$(field "$f" status)" = "running" ] && ok "status=running" || bad "status=$(field "$f" status)"
  [ "$(field "$f" run_id)" = "run1" ] && ok "run_id=run1" || bad "run_id=$(field "$f" run_id)"
  link="$R/docs/tdd/.implement-logs/latest"
  if [ -L "$link" ]; then
    tgt="$(readlink "$link")"
    case "$tgt" in
      *run1) ok "latest points at run1 ($tgt)" ;;
      *) bad "latest target unexpected: $tgt" ;;
    esac
  else
    bad "latest is not a symlink"
  fi
) || true

# --- [C] set_tdd upsert + queue_index + observation 5 ------------------------
echo "[C] tl_run_set_tdd upserts slug.json; first insert assigns queue_index"
( R="$ROOT/c"; mkdir -p "$R"
  src "tl_run_init \"$R\" r
       tl_run_set_tdd \"$R\" r slug paused ratelimit"
  f="$R/docs/tdd/.implement-logs/r/slug.json"
  [ -f "$f" ] && ok "slug.json exists" || bad "slug.json missing"
  [ "$(field "$f" status)" = "paused" ] && ok "status=paused (obs 5)" \
    || bad "status=$(field "$f" status) want paused"
  [ "$(field "$f" halt_cause)" = "ratelimit" ] && ok "halt_cause=ratelimit" \
    || bad "halt_cause=$(field "$f" halt_cause)"
  [ "$(field "$f" queue_index)" = "0" ] && ok "first queue_index=0" \
    || bad "queue_index=$(field "$f" queue_index) want 0"
  rf="$R/docs/tdd/.implement-logs/r/run.json"
  # tdd_total incremented after first insert
  tot="$(field "$rf" tdd_total)"
  [ "$tot" = "1" ] && ok "run.json tdd_total=1 after first insert" \
    || bad "tdd_total=$tot want 1"

  src "tl_run_set_tdd \"$R\" r slug building"
  [ "$(field "$f" queue_index)" = "0" ] && ok "later call keeps queue_index" \
    || bad "queue_index mutated to $(field "$f" queue_index)"
  [ "$(field "$f" status)" = "building" ] && ok "later call refreshes status" \
    || bad "status after upsert=$(field "$f" status)"

  src "tl_run_set_tdd \"$R\" r other pending"
  [ "$(field "$R/docs/tdd/.implement-logs/r/other.json" queue_index)" = "1" ] \
    && ok "second slug queue_index=1" || bad "second queue_index wrong"
) || true

# --- [D] unknown halt_cause is rc 2 ------------------------------------------
echo "[D] unknown halt_cause rejected"
( R="$ROOT/d"; mkdir -p "$R"
  src "tl_run_init \"$R\" r"
  set +e
  src "tl_run_set_tdd \"$R\" r slug paused not-a-cause" >/dev/null 2>"$ROOT/D.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] && ok "unknown cause → rc 2" || bad "unknown cause rc=$rc want 2"
) || true

# --- [E] lock: live PID holds; dead PID reclaimable --------------------------
echo "[E] tl_run_lock reclaim when PID is dead (FR-43)"
( R="$ROOT/e"; mkdir -p "$R"
  src "tl_run_init \"$R\" r"
  lock="$R/docs/tdd/.implement-logs/.run.lock"
  # Stale lock: PID that is not alive.
  printf '1\n' >"$lock"   # PID 1 is init — usually alive. Use a high unused pid.
  printf '999999\n' >"$lock"
  set +e
  src "tl_run_lock_reclaim \"$R\""; rc=$?
  set -e
  [ "$rc" -eq 0 ] && ok "reclaim succeeds when PID is dead" \
    || bad "reclaim rc=$rc want 0"
  # After reclaim, lock should hold this (sub)shell's... actually src is a
  # new bash, so the lock PID is that child's (now dead). Re-read: reclaim
  # writes $$ of the src bash, which has exited. That's OK for this case —
  # we only asserted reclaim rc 0.

  # Held by a live background PID.
  sleep 30 &
  live=$!
  printf '%s\n' "$live" >"$lock"
  set +e
  src "tl_run_lock \"$R\""; rc=$?
  set -e
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ "$rc" -ne 0 ] && ok "lock held by live PID is refused" \
    || bad "lock accepted while live PID held it"
) || true

# --- [F] next_gate order + flip ----------------------------------------------
echo "[F] tl_run_next_gate walks test-first → … → flip"
( R="$ROOT/f"; mkdir -p "$R"
  src "tl_run_init \"$R\" r
       tl_run_set_tdd \"$R\" r s pending"
  g="$(src "tl_run_next_gate \"$R\" r s")"
  [ "$g" = "test-first" ] && ok "no verdicts → next_gate=test-first" \
    || bad "next_gate='$g' want test-first"

  src "source \"$REPO/scripts/lib/verdicts.sh\"; tl_verdict_write \"$R\" r s test-first PASS e"
  g="$(src "tl_run_next_gate \"$R\" r s")"
  [ "$g" = "ci-checks" ] && ok "after test-first PASS → ci-checks" \
    || bad "next_gate='$g' want ci-checks"

  src "source \"$REPO/scripts/lib/verdicts.sh\"
       tl_verdict_write \"$R\" r s ci-checks PASS e
       tl_verdict_write \"$R\" r s runtime-verify PASS e
       tl_verdict_write \"$R\" r s review PASS e"
  g="$(src "tl_run_next_gate \"$R\" r s")"
  [ "$g" = "flip" ] && ok "all four PASS → flip" || bad "next_gate='$g' want flip"
) || true

# --- [G] atomic write: a mid-write tmp does not corrupt the live file --------
echo "[G] kill-mid-write fixture still parses as prior or new (FR-44)"
( R="$ROOT/g"; mkdir -p "$R"
  src "tl_run_init \"$R\" r
       tl_run_set_tdd \"$R\" r slug paused ratelimit"
  f="$R/docs/tdd/.implement-logs/r/slug.json"
  dir="$(dirname "$f")"
  # Plant a truncated tmp as if kill -9 hit during printf, before mv.
  printf '{"slug":"slug","status":"buil' >"$dir/.slug.json.tmp"
  # Live file must still parse as the prior (paused) state.
  python3 -m json.tool "$f" >/dev/null 2>&1 \
    && ok "live slug.json still valid JSON after orphan tmp" \
    || bad "live file unparseable"
  [ "$(field "$f" status)" = "paused" ] && ok "live file still prior status=paused" \
    || bad "live status=$(field "$f" status)"
  # Completing a new write replaces atomically.
  src "tl_run_set_tdd \"$R\" r slug done"
  python3 -m json.tool "$f" >/dev/null 2>&1 \
    && [ "$(field "$f" status)" = "done" ] \
    && ok "post-write file is the new state (done)" \
    || bad "post-write status=$(field "$f" status)"
) || true

# --- [H] pr_url only via tl_run_set_pr ---------------------------------------
echo "[H] pr_url is set only by tl_run_set_pr"
( R="$ROOT/h"; mkdir -p "$R"
  src "tl_run_init \"$R\" r
       tl_run_set_tdd \"$R\" r slug building
       tl_run_set_pr \"$R\" r slug https://example.test/pr/1"
  [ "$(field "$R/docs/tdd/.implement-logs/r/slug.json" pr_url)" = "https://example.test/pr/1" ] \
    && ok "tl_run_set_pr stored pr_url" || bad "pr_url not stored"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== run-record eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

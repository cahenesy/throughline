#!/usr/bin/env bash
# build-hardening.test.sh — eval for TDD 0069 / FR-18, FR-43, FR-88, FR-41,
# NFR-4: the /build-tdds single-run lock that holds across Bash calls, and the
# 0067 follow-ups (fall-back reason via a file, the step-7 credits pointer, the
# live probe's session-folder cleanup, tl_run_retry_begin's report copy, and
# base-sha validation).
#
# Lock owners are REAL processes: sleepers (`sleep 300 &`) passed explicitly,
# and python3 parents whose `bash` children call tl_session_pid / the extracted
# tl:lock / tl:unlock blocks, so the walk is exercised through real nested
# shells, not a fixed PID. Races are real concurrent background processes on
# temp repos. Skill blocks are extracted from skills/implement/SKILL.md and run
# the way the harness does (a fresh shell, TL_* env only). The probe runs
# against a stub `claude` under a fake CLAUDE_CONFIG_DIR. A missing marker,
# block, tool or file is a FAIL (L-001/L-011), never a skip. Observation 10 is
# the one text check (stated reason: dispatch-time prose an eval can't run).
#
# Written red-first. Run: bash tests/build-hardening.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib/run-record.sh"
MODELS="$REPO/scripts/lib/models.sh"
SKILL="$REPO/skills/implement/SKILL.md"
PROBE="$REPO/tests/live/escalation-probe.sh"
RESULTS=""; ROOT=""; SLEEPERS=()
cleanup() {
  local p
  for p in ${SLEEPERS[@]+"${SLEEPERS[@]}"}; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  [ -n "$ROOT" ] && rm -rf "$ROOT"
  [ -n "$RESULTS" ] && rm -f "$RESULTS"
}
trap cleanup EXIT
RESULTS="$(mktemp)"; export RESULTS
ROOT="$(mktemp -d)"
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
q() { printf '%q' "$1"; }
H="$ROOT/home"; mkdir -p "$H" "$ROOT/blocks"
BASH_BIN="$(command -v bash)"
HAVE_PY=1; command -v python3 >/dev/null 2>&1 || { bad "infra: python3 not found (owner parents)"; HAVE_PY=0; }
HAVE_JQ=1; command -v jq >/dev/null 2>&1 || { bad "infra: jq not found"; HAVE_JQ=0; }

# rr '<cmds>' — source run-record.sh in a CLEAN shell, run <cmds>. Sets OUT ERR RC.
rr() {
  env -i HOME="$H" PATH="$PATH" bash -c ". $(q "$LIB") || exit 98; $1" >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
}
lst() { ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1; print}'; }
# sleeper — start a live owner; sets SP (pid) and SO ("<pid> <start>").
sleeper() { sleep 300 & SP=$!; SLEEPERS+=("$SP"); SO="$SP $(lst "$SP")"; }
dead_owner() { sleeper; kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; DO="$SO"; }
lockline() { printf 'pid=%s start=%s' "${1%% *}" "${1#* }"; }
mkrepo() { mkdir -p "$1/docs/tdd/.implement-logs"; }
LK() { printf '%s/docs/tdd/.implement-logs/.run.lock' "$1"; }
fline() { if [ -f "$1" ]; then head -n 1 "$1"; else printf '<absent>'; fi; }

# extract <marker> <out> — the first ```bash block after the marker line.
getblock() {
  local rc
  { [ -r "$SKILL" ] && [ -s "$SKILL" ]; } || { bad "infra: $SKILL unreadable"; return 1; }
  awk -v M="$1" '
    !seen && $0 == M                    { seen = 1; next }
    seen && !open && /^```bash[ \t]*$/  { open = 1; next }
    open && /^```[ \t]*$/               { closed = 1; exit }
    open                                { print }
    END { if (!seen) exit 3; if (!open) exit 4; if (!closed) exit 5 }
  ' "$SKILL" >"$2"; rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$2" ]; then ok "block after '$1' extracted"; return 0; fi
  bad "cannot extract the bash block after '$1' (rc=$rc)"; return 1
}
runb() {  # <block> [VAR=val …]
  local b="$1"; shift
  env -i HOME="$H" PATH="$PATH" CLAUDE_PLUGIN_ROOT="$REPO" "$@" bash "$b" >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
}

echo "[1] tl_session_pid skips shells and wrappers; prints the python3 parent"
WR="$ROOT/wrap"; mkdir -p "$WR"
for w in bwrap timeout; do printf '#!%s\n"$@"\n' "$BASH_BIN" >"$WR/$w"; chmod +x "$WR/$w"; done
PYWALK='import os,subprocess,sys
pid=os.getpid()
st=" ".join(subprocess.run(["ps","-o","lstart=","-p",str(pid)],capture_output=True,text=True).stdout.split())
open(sys.argv[1],"w").write("%d %s" % (pid, st))
sys.exit(subprocess.run(["bash","-c",sys.argv[2]]).returncode)'
walk() {  # <label> <inner command>
  local want got
  [ "$HAVE_PY" = 1 ] || { bad "$1: infra: no python3"; return; }
  rm -f "$ROOT/py.self"
  got="$(env -i HOME="$H" PATH="$WR:$PATH" python3 -c "$PYWALK" "$ROOT/py.self" "$2" 2>"$ROOT/err")"
  want="$(cat "$ROOT/py.self" 2>/dev/null)"
  if [ -n "$want" ] && [ "${want#* }" != "$want" ] && [ -n "${want#* }" ] && [ "$got" = "$want" ]; then
    ok "$1: '$got'"
  else bad "$1: got '$got' want '$want' (err: $(cat "$ROOT/err"))"; fi
}
walk "[1] python3 → bash -c → bash -c tl_session_pid" "bash -c '. $(q "$LIB"); tl_session_pid'"
walk "[1] python3 → bash → bwrap → timeout → bash tl_session_pid" "bwrap timeout bash -c '. $(q "$LIB"); tl_session_pid'"
# A fake ps whose every ancestor is a shell up to PID 1, and a failing ps.
FP="$ROOT/fakeps"; mkdir -p "$FP"
printf '#!%s\ncase "$*" in *ppid=*) echo 1 ;; *comm=*) echo bash ;; *) echo "Thu Jan 1 00:00:00 2026" ;; esac\n' "$BASH_BIN" >"$FP/ps"
chmod +x "$FP/ps"
env -i HOME="$H" PATH="$FP:$PATH" bash -c ". $(q "$LIB"); tl_session_pid" >"$ROOT/out" 2>/dev/null; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$ROOT/out" ] && ok "only shells up to PID 1 → rc 1, no output (PID 1 never chosen)" \
  || bad "walk to PID 1: rc=$rc out='$(cat "$ROOT/out")'"
printf '#!%s\nexit 1\n' "$BASH_BIN" >"$FP/ps"
env -i HOME="$H" PATH="$FP:$PATH" bash -c ". $(q "$LIB"); tl_session_pid" >"$ROOT/out" 2>/dev/null; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$ROOT/out" ] && ok "a ps failure → rc 1, no output" || bad "ps failure: rc=$rc"
R0="$ROOT/r0"; mkrepo "$R0"
env -i HOME="$H" PATH="$FP:$PATH" bash -c ". $(q "$LIB"); tl_run_lock $(q "$R0")" >"$ROOT/out" 2>"$ROOT/err"; rc=$?
[ "$rc" -eq 1 ] && grep -qF 'cannot identify the session process; not locking' "$ROOT/err" && [ ! -e "$(LK "$R0")" ] \
  && ok "no session process → tl_run_lock refuses loudly, no lock" || bad "no session: rc=$rc err='$(cat "$ROOT/err")'"

echo "[2] the lock outlives the Bash call: a sleeper owns it"
R2="$ROOT/r2"; mkrepo "$R2"; L2="$(LK "$R2")"
sleeper; A="$SO"; AP="$SP"; sleeper; B="$SO"; BP="$SP"
rr "tl_run_lock $(q "$R2") $(q "$A")"
[ "$RC" -eq 0 ] && [ "$(fline "$L2")" = "$(lockline "$A")" ] && ok "[2] owner A → rc 0, line '$(fline "$L2")'" \
  || bad "[2] owner A: rc=$RC line='$(fline "$L2")' want '$(lockline "$A")' err='$ERR'"
rr "tl_run_lock $(q "$R2") $(q "$B")"
[ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -qF "lock held by live PID $AP (started ${A#* })" \
  && [ "$(fline "$L2")" = "$(lockline "$A")" ] && ok "[2] another owner → rc 1, names PID $AP" \
  || bad "[2] other owner: rc=$RC err='$ERR' line='$(fline "$L2")'"
rr "tl_run_lock $(q "$R2") $(q "$A")"
[ "$RC" -eq 0 ] && [ "$(fline "$L2")" = "$(lockline "$A")" ] && ok "[2] same owner again → rc 0 (re-entrant)" \
  || bad "[2] re-entry: rc=$RC err='$ERR'"
rr "tl_run_lock_reclaim $(q "$R2") $(q "$B")"
[ "$RC" -eq 1 ] && ok "tl_run_lock_reclaim (alias) still refuses a live owner" || bad "reclaim alias: rc=$RC"

echo "[3] a dead owner is reclaimed (FR-43)"
kill "$AP" 2>/dev/null; wait "$AP" 2>/dev/null
rr "tl_run_lock $(q "$R2") $(q "$B")"
[ "$RC" -eq 0 ] && [ "$(fline "$L2")" = "$(lockline "$B")" ] && ok "[3] dead A → B gets rc 0 and the line" \
  || bad "[3] reclaim: rc=$RC line='$(fline "$L2")' err='$ERR'"
[ ! -e "$L2.reclaim" ] && ok "[3] no reclaim guard left behind" || bad "[3] lock.reclaim left"

echo "[4] PID reuse is detected (same live PID, different start)"
sleeper; C="$SO"
printf 'pid=%s start=Mon Jan 1 00:00:00 2001\n' "$BP" >"$L2"
rr "tl_run_lock $(q "$R2") $(q "$C")"
[ "$RC" -eq 0 ] && [ "$(fline "$L2")" = "$(lockline "$C")" ] && ok "[4] live PID $BP with a different start → reclaimed" \
  || bad "[4] reuse: rc=$RC line='$(fline "$L2")' err='$ERR'"

echo "[5] races have exactly one winner"
OWN=(); for i in 0 1 2 3 4 5 6 7 8 9; do sleeper; OWN+=("$SO"); done
R5="$ROOT/r5"; mkrepo "$R5"; L5="$(LK "$R5")"
race() {  # <label> — 10 concurrent tl_run_lock calls, released together
  local i n=0 win="" d="$ROOT/race"; rm -rf "$d"; mkdir -p "$d"
  for i in 0 1 2 3 4 5 6 7 8 9; do
    ( while [ ! -e "$d/go" ]; do :; done
      env -i HOME="$H" PATH="$PATH" bash -c ". $(q "$LIB"); tl_run_lock $(q "$R5") $(q "${OWN[i]}")" \
        >/dev/null 2>"$d/$i.err"
      echo $? >"$d/$i.rc" ) &
  done
  sleep 0.3; : >"$d/go"; wait_rc "$d"
  for i in 0 1 2 3 4 5 6 7 8 9; do
    [ "$(cat "$d/$i.rc" 2>/dev/null)" = 0 ] && { n=$((n + 1)); win="${OWN[i]}"; }
  done
  if [ "$n" = 1 ] && [ "$(fline "$L5")" = "$(lockline "$win")" ] && [ ! -e "$L5.reclaim" ]; then
    ok "$1: one winner, the file names it, no guard left"
  else bad "$1: winners=$n line='$(fline "$L5")' guard=$([ -e "$L5.reclaim" ] && echo left || echo none) errs=$(cat "$d"/*.err | sort | uniq -c | tr '\n' ' ')"; fi
}
wait_rc() {  # <dir> — wait (bounded) until all 10 rc files exist
  local t=0
  while [ "$(ls "$1"/*.rc 2>/dev/null | wc -l)" -lt 10 ] && [ "$t" -lt 300 ]; do sleep 0.1; t=$((t + 1)); done
}
for round in 1 2 3; do rm -f "$L5"; race "[5] round $round: absent lock"; done
for round in 1 2 3; do
  dead_owner; printf '%s\n' "$(lockline "$DO")" >"$L5"; race "[5] round $round: dead-owner lock"
done
printf '424242424\n' >"$L5"; race "[5] legacy dead bare-PID lock"

echo "[5b] partial writes are not stolen; a stale guard is cleared"
R6="$ROOT/r6"; mkrepo "$R6"; L6="$(LK "$R6")"
: >"$L6"; sleeper; D6="$SO"
rr "tl_run_lock $(q "$R6") $(q "$D6")"
[ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -qF 'lock unreadable; held' && [ -f "$L6" ] && [ ! -s "$L6" ] \
  && ok "[5b] empty lock → rc 1 'lock unreadable; held', file untouched" || bad "[5b] empty: rc=$RC err='$ERR' size=$(wc -c <"$L6" 2>/dev/null)"
printf 'garbage line\n' >"$L6"
rr "tl_run_lock $(q "$R6") $(q "$D6")"
[ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -qF 'lock unreadable; held' && [ "$(fline "$L6")" = 'garbage line' ] \
  && ok "unparseable lock → refused, never treated as dead" || bad "garbage: rc=$RC err='$ERR'"
dead_owner; printf '%s\n' "$(lockline "$DO")" >"$L6"; : >"$L6.reclaim"
rr "tl_run_lock $(q "$R6") $(q "$D6")"
[ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -qF 'lock reclaim in progress' && [ "$(fline "$L6")" = "$(lockline "$DO")" ] \
  && ok "a fresh guard → rc 1 'lock reclaim in progress', lock unchanged" || bad "fresh guard: rc=$RC err='$ERR'"
touch -d '2 minutes ago' "$L6.reclaim" 2>/dev/null || touch -t "$(date -d '-2 min' +%Y%m%d%H%M.%S)" "$L6.reclaim"
rr "tl_run_lock $(q "$R6") $(q "$D6")"
[ "$RC" -eq 0 ] && [ "$(fline "$L6")" = "$(lockline "$D6")" ] && [ ! -e "$L6.reclaim" ] \
  && [ -z "$(ls "$(dirname "$L6")" | grep reclaim)" ] && ok "[5b] a guard older than 60 s is cleared; the reclaim wins" \
  || bad "[5b] stale guard: rc=$RC err='$ERR' line='$(fline "$L6")' left: $(ls -A "$(dirname "$L6")" | tr '\n' ' ')"

echo "[6] unlock checks ownership"
R7="$ROOT/r7"; mkrepo "$R7"; L7="$(LK "$R7")"
sleeper; O7="$SO"; O7P="$SP"; sleeper; N7="$SO"
rr "tl_run_lock $(q "$R7") $(q "$O7")"
rr "tl_run_unlock $(q "$R7") $(q "$N7")"
[ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -qF 'not the lock owner' && [ "$(fline "$L7")" = "$(lockline "$O7")" ] \
  && ok "[6] non-owner, live owner → rc 1, file kept" || bad "[6] non-owner: rc=$RC err='$ERR'"
rr "tl_run_unlock $(q "$R7") $(q "$O7")"
[ "$RC" -eq 0 ] && [ ! -e "$L7" ] && ok "[6] the owner → removed" || bad "[6] owner unlock: rc=$RC err='$ERR'"
rr "tl_run_lock $(q "$R7") $(q "$O7")"; kill "$O7P" 2>/dev/null; wait "$O7P" 2>/dev/null
rr "tl_run_unlock $(q "$R7") $(q "$N7")"
[ "$RC" -eq 0 ] && [ ! -e "$L7" ] && [ ! -e "$L7.reclaim" ] && ok "[6] a dead owner → removed (no guard left)" \
  || bad "[6] dead owner unlock: rc=$RC err='$ERR'"

echo "[7] legacy bare-PID locks"
sleeper; LP="$SP"
printf '%s\n' "$LP" >"$L7"
rr "tl_run_lock $(q "$R7") $(q "$N7")"
[ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -qF "lock held by live PID $LP" && [ "$(fline "$L7")" = "$LP" ] \
  && ok "[7] bare live PID → refused" || bad "[7] live legacy: rc=$RC err='$ERR'"
rr "tl_run_unlock $(q "$R7") $(q "$N7")"
[ "$RC" -eq 1 ] && [ "$(fline "$L7")" = "$LP" ] && ok "[7] bare live PID → unlock refused" || bad "[7] legacy unlock: rc=$RC"
dead_owner; printf '%s\n' "${DO%% *}" >"$L7"
rr "tl_run_lock $(q "$R7") $(q "$N7")"
[ "$RC" -eq 0 ] && [ "$(fline "$L7")" = "$(lockline "$N7")" ] && ok "[7] bare dead PID → reclaimed, new format" \
  || bad "[7] dead legacy: rc=$RC line='$(fline "$L7")' err='$ERR'"

echo "[8] the extracted tl:lock / tl:unlock blocks under real python3 parents"
LB="$ROOT/blocks/lock.sh"; UB="$ROOT/blocks/unlock.sh"
if getblock '<!-- tl:lock -->' "$LB" && getblock '<!-- tl:unlock -->' "$UB" && [ "$HAVE_PY" = 1 ]; then
  R8="$ROOT/r8"; mkrepo "$R8"; L8="$(LK "$R8")"; D8="$ROOT/d8"; mkdir -p "$D8"
  cat >"$ROOT/drv.py" <<'PY'
import os, subprocess, sys, time
pre = sys.argv[1]
open(pre + ".pid", "w").write(str(os.getpid()))
for i, s in enumerate(sys.argv[2:]):
    kind, arg = s.split(":", 1)
    if kind == "run":
        with open("%s.%d.out" % (pre, i), "w") as o, open("%s.%d.err" % (pre, i), "w") as e:
            rc = subprocess.run(["bash", arg], stdout=o, stderr=e).returncode
        open("%s.%d.rc" % (pre, i), "w").write(str(rc))
    elif kind == "touch":
        open(arg, "w").close()
    elif kind == "wait":
        t = time.time()
        while not os.path.exists(arg) and time.time() - t < 60:
            time.sleep(0.05)
PY
  drv() { env -i HOME="$H" PATH="$PATH" CLAUDE_PLUGIN_ROOT="$REPO" TL_REPO="$R8" python3 "$ROOT/drv.py" "$@"; }
  drv "$D8/a" "run:$LB" "run:$LB" "touch:$D8/a.ready" "wait:$D8/go" "run:$UB" &
  APY=$!
  t=0; while [ ! -e "$D8/a.ready" ] && [ "$t" -lt 300 ]; do sleep 0.1; t=$((t + 1)); done
  [ "$(cat "$D8/a.0.out" 2>/dev/null)" = lock=acquired ] && [ "$(cat "$D8/a.1.out" 2>/dev/null)" = lock=acquired ] \
    && ok "[8] two tl:lock runs from one python3 parent both print lock=acquired (re-entry)" \
    || bad "[8] parent A: out0='$(cat "$D8/a.0.out" 2>/dev/null)' out1='$(cat "$D8/a.1.out" 2>/dev/null)' err='$(cat "$D8"/a.*.err 2>/dev/null)'"
  [ "$(fline "$L8" | sed -n 's/^pid=\([0-9]*\) .*/\1/p')" = "$(cat "$D8/a.pid" 2>/dev/null)" ] \
    && ok "[8] the lock names parent A's python3 PID" || bad "[8] lock line '$(fline "$L8")' vs A pid $(cat "$D8/a.pid" 2>/dev/null)"
  drv "$D8/b" "run:$LB" "run:$UB"
  [ "$(cat "$D8/b.0.rc" 2>/dev/null)" = 1 ] && grep -qF "lock held by live PID $(cat "$D8/a.pid")" "$D8/b.0.err" \
    && [ ! -s "$D8/b.0.out" ] && ok "[8] a different python3 parent → tl:lock rc 1, names A" \
    || bad "[8] parent B lock: rc=$(cat "$D8/b.0.rc" 2>/dev/null) err='$(cat "$D8/b.0.err" 2>/dev/null)'"
  [ "$(cat "$D8/b.1.rc" 2>/dev/null)" = 1 ] && [ -f "$L8" ] && ok "[8] tl:unlock from the non-owner → rc 1, lock kept" \
    || bad "[8] parent B unlock: rc=$(cat "$D8/b.1.rc" 2>/dev/null) lock=$(fline "$L8")"
  : >"$D8/go"; wait "$APY"
  [ "$(cat "$D8/a.4.rc" 2>/dev/null)" = 0 ] && [ ! -e "$L8" ] && ok "[8] tl:unlock from the owner removes the lock" \
    || bad "[8] owner unlock: rc=$(cat "$D8/a.4.rc" 2>/dev/null) err='$(cat "$D8/a.4.err" 2>/dev/null)' lock=$(fline "$L8")"
  runb "$LB"
  [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qF TL_REPO && ok "tl:lock without TL_REPO fails loudly" || bad "tl:lock no TL_REPO: rc=$RC"
fi

echo "[9] (a) the fall-back reason travels by file"
FB="$ROOT/blocks/fellback.sh"
if getblock '<!-- tl:escalation-fellback-record -->' "$FB"; then
  R9="$ROOT/r9"; mkrepo "$R9"; RUN=r9; SL=0099-x; RD="$R9/docs/tdd/.implement-logs/$RUN"
  RF="$RD/$SL.fallback-reason.txt"; SC="$RD/$SL.models.json"
  rr "tl_run_init $(q "$R9") $RUN && tl_run_set_escalation $(q "$R9") $RUN $SL escalated fable >/dev/null"
  [ "$RC" -eq 0 ] || bad "infra: run r9: rc=$RC err='$ERR'"
  fb() { runb "$FB" TL_REPO="$R9" TL_RUN="$RUN" TL_SLUG="$SL" "$@"; }
  reason() { [ "$HAVE_JQ" = 1 ] && jq -r .escalation_reason "$SC" 2>/dev/null; }
  printf '%s\033[31m\n%s\n' 'boom "x" $(whoami) \ y' 'second line' >"$RF"
  fb TL_MODEL=fable TL_REASON_FILE="$RF"
  W='dispatch error: boom "x" $(whoami) \ y[31m'
  [ "$RC" -eq 0 ] && [ "$(reason)" = "$W" ] && ok "[9] reason recorded exactly: control byte stripped, first line, nothing run" \
    || bad "[9] reason: rc=$RC got '$(reason)' want '$W' err='$ERR'"
  [ "$HAVE_JQ" = 1 ] && [ "$(jq -r .escalation "$SC")" = fell-back ] && ok "[9] escalation=fell-back" || bad "[9] escalation not fell-back"
  [ ! -e "$RF" ] && ok "[9] the reason file is deleted after reading" || bad "[9] the reason file is still there"
  fb TL_MODEL=fable TL_REASON_FILE="$RF"
  [ "$RC" -eq 0 ] && [ "$(reason)" = 'dispatch error: (no detail)' ] && ok "[9] missing file → 'dispatch error: (no detail)'" \
    || bad "[9] missing: rc=$RC got '$(reason)' err='$ERR'"
  printf '\n\n%0400d\n' 0 >"$RF"
  fb TL_MODEL=fable TL_REASON_FILE="$RF"; r="$(reason)"
  [ "$RC" -eq 0 ] && [ "$r" = "dispatch error: $(printf '%0300d' 0)" ] && ok "first non-empty line, capped at 300 chars" \
    || bad "cap: rc=$RC len=${#r}"
  rr "tl_run_set_escalation $(q "$R9") $RUN $SL escalated fable >/dev/null"
  printf 'x\n' >"$RF"
  fb TL_MODEL='x;rm' TL_REASON_FILE="$RF"
  [ "$RC" -eq 2 ] && [ "$(jq -r .escalation "$SC" 2>/dev/null)" = escalated ] && ok "[9] TL_MODEL='x;rm' → rc 2, nothing recorded" \
    || bad "[9] bad model: rc=$RC err='$ERR'"
  fb TL_MODEL=fable TL_REASON_FILE="$ROOT/elsewhere.txt"
  [ "$RC" -eq 2 ] && [ "$(jq -r .escalation "$SC" 2>/dev/null)" = escalated ] && ok "TL_REASON_FILE not the run-dir path → rc 2" \
    || bad "wrong reason path: rc=$RC err='$ERR'"
  fb TL_MODEL=fable
  [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qF TL_REASON_FILE && ok "TL_REASON_FILE unset → fails loudly" || bad "no TL_REASON_FILE: rc=$RC"
fi

echo "[10] (b) text check: the step-7 rate-limit sentence points to credits_required"
if [ -r "$SKILL" ] && [ -s "$SKILL" ]; then
  P="$(awk '/^## 7\. /{s=1} /^## 8\. /{s=0} s' "$SKILL" | awk 'BEGIN{RS=""} /If worker exit or stderr matches/ {gsub(/\n/," "); print}')"
  case "$P" in
    *credits_required*fall-back*) ok "[10] step 7's rate-limit rule names credits_required as a fall-back" ;;
    '') bad "[10] no 'If worker exit or stderr matches' paragraph in step 7" ;;
    *) bad "[10] the step-7 rate-limit rule lacks the credits_required pointer: $P" ;;
  esac
else bad "[10] infra: $SKILL unreadable (L-001)"; fi

echo "[11] (c) the probe removes the harness folder for its scratch dir"
if [ -r "$PROBE" ]; then
  SB="$ROOT/stub"; mkdir -p "$SB"
  cat >"$SB/claude" <<'STUB'
#!/usr/bin/env bash
prompt="${!#}"
model="$(printf '%s' "$prompt" | sed -n 's/.*model "\([^"]*\)".*/\1/p' | head -n 1)"
nonce="$(printf '%s' "$prompt" | grep -oE 'Reply with exactly [0-9a-f]+' | head -n 1 | sed 's/.* //')"
cwd="$(pwd -P)"; enc="$(printf '%s' "$cwd" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
pd="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc"
printf '%s\n' "$pd" >>"$STUB_LOG"
if [ "${STUB_MODE:-}" = symlink ]; then [ -e "$pd" ] || ln -s "$STUB_VICTIM" "$pd"; else mkdir -p "$pd"; fi
case "$model" in opus) p=p3 ;; claude-nonexistent-0) p=p2 ;; *) p=p1 ;; esac
sid="s-$p"; printf '{}\n' >"$pd/x.jsonl"
ev() { printf '%s\n' "$1"; }
ev '{"type":"system","subtype":"init","session_id":"'"$sid"'"}'
ev '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"toolu_A","name":"Agent","input":{"model":"'"$model"'"}}]}}'
tres() { ev '{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_A","is_error":'"$1"',"content":"'"$2"'"}]}}'; }
case "$p" in
  p1) tres true 'requires usage credits (credits_required)' ;;
  p2) tres true 'InputValidationError' ;;
  p3) mkdir -p "$pd/$sid/subagents"
      { ev '{"type":"user","message":{"role":"user","content":"go"}}'
        ev '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"'"$nonce"'"}]}}'
      } >"$pd/$sid/subagents/agent-agp3.jsonl"
      tres false "$nonce\\nagentId: agp3" ;;
esac
ev '{"type":"result","subtype":"success","is_error":false}'
STUB
  chmod +x "$SB/claude"
  CFG="$ROOT/cfg"; mkdir -p "$CFG/projects/-keep-me"; : >"$CFG/projects/-keep-me/k.jsonl"
  probe() {  # [VAR=val …]
    : >"$ROOT/stub.log"
    env -i HOME="$H" PATH="$PATH" THROUGHLINE_PROBE_CLAUDE="$SB/claude" CLAUDE_CONFIG_DIR="$CFG" \
      STUB_LOG="$ROOT/stub.log" "$@" bash "$PROBE" >"$ROOT/out" 2>"$ROOT/err"
    RC=$?; PD="$(head -n 1 "$ROOT/stub.log")"
  }
  probe
  [ "$RC" -eq 0 ] && ok "[11] the probe completes against the stub (rc 0)" || bad "[11] probe rc=$RC out='$(cat "$ROOT/out")' err='$(cat "$ROOT/err")'"
  case "$PD" in "$CFG/projects/-"?*) ok "[11] the stub created the scratch dir's folder ${PD##*/}" ;;
    *) bad "[11] infra: stub folder '$PD'" ;; esac
  [ -n "$PD" ] && [ ! -e "$PD" ] && ok "[11] after exit, that folder is gone" || bad "[11] the folder is left: $PD"
  [ -f "$CFG/projects/-keep-me/k.jsonl" ] && ok "[11] the sibling projects/-keep-me still exists" || bad "[11] -keep-me was touched"
  V="$ROOT/victim"; mkdir -p "$V"; : >"$V/precious"
  probe STUB_MODE=symlink STUB_VICTIM="$V"
  [ -n "$PD" ] && [ -L "$PD" ] && [ -f "$V/precious" ] && [ -f "$V/x.jsonl" ] \
    && ok "[11] an encoded folder that is a symlink is neither followed nor removed" \
    || bad "[11] symlink case: link=$([ -L "$PD" ] && echo kept || echo gone) victim=$(ls -A "$V" | tr '\n' ' ') rc=$RC"
  [ -f "$CFG/projects/-keep-me/k.jsonl" ] && ok "-keep-me still exists after the symlink run" || bad "-keep-me touched (symlink run)"
else bad "[11] infra: $PROBE unreadable"; fi

echo "[12] (d) tl_run_retry_begin copies the report itself; the block has no cp"
RB="$ROOT/blocks/retry-begin.sh"
R12="$ROOT/r12"; mkrepo "$R12"; S12=0099-x; RD12="$R12/docs/tdd/.implement-logs"
mk12() {  # <run>
  rr "tl_run_init $(q "$R12") $1 && tl_run_set_tdd $(q "$R12") $1 $S12 failed gate-fail \
      && tl_verdict_write $(q "$R12") $1 $S12 test-first PASS e && tl_verdict_write $(q "$R12") $1 $S12 review FAIL e"
  printf 'review findings for %s\n' "$1" >"$RD12/$1/$S12.review.txt"
}
mk12 a12
rr "tl_run_retry_begin $(q "$R12") a12 $S12"
W12="report=$RD12/a12/$S12.review.txt
implementer_report=$RD12/a12/$S12.review.prev.txt
archive=$RD12/a12/$S12/retry-1"
[ "$RC" -eq 0 ] && [ "$OUT" = "$W12" ] && ok "[12] the function prints report= / implementer_report= / archive= in order" \
  || bad "[12] function: rc=$RC err='$ERR' got:"$'\n'"$OUT"
cmp -s "$RD12/a12/$S12.review.txt" "$RD12/a12/$S12.review.prev.txt" && ok "[12] the copy exists, byte-identical" || bad "[12] no copy"
if getblock '<!-- tl:retry-begin -->' "$RB"; then
  grep -qE '(^|[^a-z_])cp([^a-z_]|$)' "$RB" && bad "[12] the block still contains cp" || { [ -s "$RB" ] && ok "[12] the block contains no cp"; }
  mk12 b12
  runb "$RB" TL_REPO="$R12" TL_RUN=b12 TL_SLUG="$S12"
  [ "$RC" -eq 0 ] && [ "$OUT" = "${W12//a12/b12}" ] && [ -f "$RD12/b12/$S12.review.prev.txt" ] \
    && ok "[12] block: three lines, report= first, the copy exists" || bad "[12] block: rc=$RC err='$ERR' got:"$'\n'"$OUT"
fi

echo "[13] (e) base sha is validated"
WT="$ROOT/wt"; EMPTY="$ROOT/rep.empty"; : >"$EMPTY"
{ git init -q "$WT" && git -C "$WT" config user.email t@t.t && git -C "$WT" config user.name t \
  && git -C "$WT" config commit.gpgsign false && git -C "$WT" commit -q --allow-empty -m base; } >/dev/null 2>&1 \
  || bad "[13] infra: cannot build the worktree fixture"
BASE="$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
rr "tl_escalation_fellback_check $(q "$EMPTY") $(q "$WT") 'HEAD;x' implementer"
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -qF 'bad base sha' && ok "[13] 'HEAD;x' → rc 2, bad base sha" \
  || bad "[13] HEAD;x: rc=$RC out='$OUT' err='$ERR'"
rr "tl_escalation_fellback_check $(q "$EMPTY") $(q "$WT") $BASE implementer"
[ "$RC" -eq 0 ] && [ "$OUT" = 'fell-back no report, no commits' ] && ok "[13] a valid 40-hex sha → the previous behaviour" \
  || bad "[13] valid sha: rc=$RC out='$OUT' err='$ERR'"
VB="$ROOT/blocks/verify.sh"
if getblock '<!-- tl:escalation-verify -->' "$VB"; then
  R13="$ROOT/r13"; mkrepo "$R13"
  rr "tl_run_init $(q "$R13") r13 && tl_run_set_escalation $(q "$R13") r13 0099-x escalated fable >/dev/null"
  runb "$VB" TL_REPO="$R13" TL_RUN=r13 TL_SLUG=0099-x TL_AGENT_ID=a1 TL_REPORT="$EMPTY" TL_WT="$WT" \
    TL_BASE_SHA='HEAD;x' TL_WORKER=implementer
  [ "$RC" -eq 2 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -qF 'bad base sha' \
    && [ "$(jq -r .escalation "$R13/docs/tdd/.implement-logs/r13/0099-x.models.json" 2>/dev/null)" = escalated ] \
    && ok "[13] the tl:escalation-verify block: bad TL_BASE_SHA → rc 2, nothing recorded" \
    || bad "[13] block: rc=$RC out='$OUT' err='$ERR'"
fi

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== build-hardening eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

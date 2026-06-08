#!/usr/bin/env bash
# runtime-verify-resume.test.sh — eval for TDD 0035 (resumable runtime-verify
# "couldn't observe" halt). A runtime-verify gate that ends VERIFY_RUNTIME:
# BLOCKED ("couldn't observe", distinct from FAIL "observed and wrong" per NFR-4)
# is recorded as a *resumable* blocked halt with a new `verify-unobservable`
# cause + a tdd_rev fingerprint, mirroring the structural-finding resume of
# TDD 0031. Covers the TDD's Verification plan §1–§6 with shared git/worktree
# fixtures + a stub runtime-verify command, following the fixture pattern of
# tests/honest-review-scope-structural-resume.test.sh. Stub `verify_runtime_one`
# means no model or tokens are needed.
#
#   §5 verify-unobservable is admitted by the closed FR-63 halt-cause enum
#   §2 status.sh surfaces it (--check-paused resumable=blocked; no unknown-cause warning)
#   §1 a runtime-verify BLOCKED verdict records a resumable verify-unobservable halt
#   §3 resume refused while the verification plan is unrevised (verify-plan-unrevised)
#   §4 resume accepted after revision: integration merged, only verify-runtime re-runs
#   §6 SKILL.md documents the cause + its plan-revised resume precondition
#
# Run: bash tests/runtime-verify-resume.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ===========================================================================
# §5: enum membership. set_halt_cause <slug> verify-unobservable returns 0 and
# writes the cause; a value NOT in the closed FR-63 enum still returns 1 (proving
# the addition is what admits verify-unobservable, not a wildcard).
echo "[§5] verify-unobservable is admitted by the closed halt-cause enum"
( D="$ROOT/s5"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _next_actions_for_cause verify-unobservable >/dev/null 2>&1 \
    && ok "_next_actions_for_cause admits verify-unobservable" || bad "verify-unobservable should be enumerated"
  acts="$(_next_actions_for_cause verify-unobservable 2>/dev/null)"
  # The FIRST next-action element must begin with `resume` (the resumable marker
  # _resume_from + status.sh --check-paused key on).
  printf '%s' "$acts" | grep -qE '^resume' \
    && ok "verify-unobservable's first next-action begins with resume" || bad "first next-action must begin with resume (got '$acts')"
  _write_tdd_fragment 0035-x 35 docs/tdd/0035-x.md 1 blocked verify-runtime 1000 1000 "feat/0035-x" "" log "" "" "" "" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0035-x verify-unobservable verify-runtime "tdd_rev=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>/dev/null; rc=$?
  [ "$rc" -eq 0 ] && ok "set_halt_cause verify-unobservable returns 0" || bad "set_halt_cause should accept verify-unobservable (got rc=$rc)"
  hc="$(_read_fragment_field "$STATE_DIR/0035-x.json" halt_cause)"
  [ "$hc" = "verify-unobservable" ] && ok "halt_cause written = verify-unobservable" || bad "halt_cause should be verify-unobservable (got '$hc')"
  # Negative: an unknown cause still returns 1 (the enum is still closed).
  set_halt_cause 0035-x not-a-real-cause-xyz verify-runtime "" 2>/dev/null; rc2=$?
  [ "$rc2" -ne 0 ] && ok "an unknown cause still returns non-zero (enum stays closed)" || bad "unknown cause must return non-zero"
) || true

# ===========================================================================
# §2: check-paused surfaces it. status.sh --check-paused prints a line for the
# slug with cause=verify-unobservable resumable=blocked, and the full status.sh
# render emits no unknown-cause fallback warning (FR-64 one-screen halt context).
echo "[§2] status.sh surfaces verify-unobservable as resumable=blocked with no unknown-cause warning"
( D="$ROOT/s2"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  printf '{"schema":1,"started_at":1000,"updated_at":1001,"pid":1,"state":"blocked","total":1,"completed":0,"failed":0,"blocked":1,"skipped":0,"paused":0}\n' > "$D/state.d/run.json"
  _write_tdd_fragment 0035-x 35 docs/tdd/0035-x.md 1 blocked verify-runtime 1000 1000 "feat/0035-x" "" log "" "" "build,test-first,verify" "" "" "" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0035-x verify-unobservable verify-runtime "tdd_rev=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>/dev/null
  cp="$(bash "$REPO/scripts/status.sh" --logdir "$D" --check-paused 2>&1)"
  printf '%s' "$cp" | grep -qE 'slug=0035-x .*cause=verify-unobservable resumable=blocked' \
    && ok "--check-paused surfaces cause=verify-unobservable resumable=blocked" || bad "should surface verify-unobservable resumable=blocked (got: '$cp')"
  out="$(bash "$REPO/scripts/status.sh" --logdir "$D" 2>&1)"
  printf '%s' "$out" | grep -qi 'unknown halt_cause' \
    && bad "status.sh must NOT warn unknown-cause for verify-unobservable (got: $out)" \
    || ok "full render emits no unknown-cause fallback warning"
  printf '%s' "$out" | grep -q 'verify-unobservable' \
    && ok "the verify-unobservable cause label appears in the halt render" || bad "render should name verify-unobservable (got: $out)"
) || true

# ===========================================================================
# §1: a runtime-verify gate that emits VERIFY_RUNTIME: BLOCKED ("couldn't
# observe") records a *resumable* verify-unobservable halt — NOT a plain
# terminal blocked with a null halt_cause. The fragment carries halt_cause=
# verify-unobservable, a halt_next_actions whose first element begins with
# resume, and a halt_cause_detail containing tdd_rev=<40-hex> (the build-branch
# TDD blob, so the §3 resume guard can compare it to the integration copy).
echo "[§1] a runtime-verify BLOCKED verdict records a resumable verify-unobservable halt"
( d="$ROOT/s1"; mkdir -p "$d/state.d" "$d/repo"; cd "$d/repo" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$d"
  export THROUGHLINE_REQUIRE_RUNTIME_VERIFY=1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd
  printf '# TDD 0035\nStatus: draft\n## Verification plan\nobserve X\n' > docs/tdd/0035-x.md
  git add -A; git commit -qm "build start" >/dev/null
  blob="$(git rev-parse HEAD:docs/tdd/0035-x.md)"
  # Skip build/test-first/verify (already complete); run ONLY runtime-verify.
  RESUME_GATES_DONE_0035_x="build,test-first,verify"; export RESUME_GATES_DONE_0035_x
  _write_tdd_fragment 0035-x 35 docs/tdd/0035-x.md 1 verifying verify-runtime 1000 1000 "feat/0035-x" "" "$d/g.log" "" "" "build,test-first,verify" "" "" "" "" "" "" "" "" "" "" "" ""
  # Stub the runtime-verify executor to emit a couldn't-observe verdict into the log.
  verify_runtime_one() { printf 'VERIFY_RUNTIME: BLOCKED could not drive the interactive surface headlessly\n' >> "$3"; return 0; }
  st="$(gate_one docs/tdd/0035-x.md "$(git rev-parse HEAD)" "$d/g.log")"; rc=$?
  F="$STATE_DIR/0035-x.json"
  [ "$rc" -ne 0 ] && ok "gate_one returns non-zero on a couldn't-observe BLOCKED verdict" || bad "gate_one should return non-zero (got rc=$rc, st=$st)"
  hc="$(_read_fragment_field "$F" halt_cause)"
  [ "$hc" = "verify-unobservable" ] && ok "halt_cause=verify-unobservable (resumable, not plain terminal blocked)" || bad "halt_cause should be verify-unobservable (got '$hc')"
  status="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)"
  [ "$status" = "blocked" ] && ok "fragment status stays blocked" || bad "status should be blocked (got '$status')"
  acts="$(_read_fragment_array_csv "$F" halt_next_actions)"
  printf '%s' "$acts" | grep -qE '^resume' && ok "halt_next_actions first element begins with resume" || bad "first next-action should begin with resume (got '$acts')"
  detail="$(_read_fragment_field "$F" halt_cause_detail)"
  printf '%s' "$detail" | grep -qE 'tdd_rev=[0-9a-f]{40}' && ok "halt_cause_detail carries tdd_rev=<40-hex>" || bad "detail should carry the tdd_rev fingerprint (got '$detail')"
  printf '%s' "$detail" | grep -qF "tdd_rev=$blob" && ok "recorded tdd_rev equals the build-branch TDD blob" || bad "tdd_rev should equal the HEAD blob (got '$detail')"
) || true

# ===========================================================================
# Shared fixture for §3–§4: a master (integration) + feat build branch carrying a
# verify-unobservable halt whose tdd_rev fingerprint was recorded from the
# branch's TDD copy. Leaves PWD on feat/0035-fix; sets fragment + FEAT_HEAD.
# Mirrors honest-review-scope-structural-resume.test.sh:_setup_structural_halt.
#   <dir> <revise-integration?0|1> <conflict?0|1>
_setup_unobservable_halt() {  # <dir> <revise> <conflict>
  local d="$1" revise="$2" conflict="$3" blob
  # state.d lives OUTSIDE the repo worktree so the fixture's `git add -A` / branch
  # switches never sweep the fragment (it is run-state, not repo content).
  mkdir -p "$d/state.d" "$d/repo"; cd "$d/repo" || return 1
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" \
         INTEGRATION="master" CHANGE="ci" LOGDIR="$d" RESUME=1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd src
  printf '# TDD 0035\nStatus: draft\n## Verification plan\nv1 observe X\n' > docs/tdd/0035-fix.md
  printf 'orig\n' > src/a.txt
  git add -A; git commit -qm "build start (plan v1)" >/dev/null
  git checkout -q -b feat/0035-fix
  if [ "$conflict" = 1 ]; then
    printf 'feat-version\n' > src/a.txt   # conflicts with master's edit below
  else
    printf 'build\n' >> src/a.txt          # a build-output commit, non-conflicting
  fi
  git add -A; git commit -qm "build output" >/dev/null
  FEAT_HEAD="$(git rev-parse HEAD)"
  blob="$(git rev-parse HEAD:docs/tdd/0035-fix.md)"
  # Record the couldn't-observe halt: status=blocked, gates_completed has
  # build,test-first,verify (NOT verify-runtime — it BLOCKED), tdd_rev = the
  # branch's (v1) plan blob, exactly as gate_one's §2 recording would.
  _write_tdd_fragment 0035-fix 35 docs/tdd/0035-fix.md 1 blocked verify-runtime 1000 1000 \
    "feat/0035-fix" "" log "" "" "build,test-first,verify" "" "$FEAT_HEAD" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0035-fix verify-unobservable verify-runtime "tdd_rev=$blob"
  if [ "$revise" = 1 ]; then
    git checkout -q master
    printf '# TDD 0035\nStatus: draft\n## Verification plan\nv2 REVISED: SKIP X (unobservable)\n' > docs/tdd/0035-fix.md
    [ "$conflict" = 1 ] && printf 'master-version\n' > src/a.txt
    git add -A; git commit -qm "revise verification plan (resolves the couldn't-observe halt)" >/dev/null
    git checkout -q feat/0035-fix
  fi
}

# §3: resume refused while the verification plan is UNREVISED. The recorded
# tdd_rev equals integration's current blob for the TDD path → resuming would
# re-BLOCK identically; refuse with resume-blocked-verify-plan-unrevised, persist
# NOTHING (the fragment keeps its accurate blocked/verify-unobservable state), and
# add no merge commit to the build branch.
echo "[§3] resume refused while the verification plan is unrevised (tdd_rev == integration blob)"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _setup_unobservable_halt "$ROOT/s3refuse" 0 0 || { bad "setup failed"; exit 0; }
  F="$STATE_DIR/0035-fix.json"; before="$(cat "$F")"
  RESUME_REFUSE_CAUSE=""
  _resume_from 0035-fix; rc=$?
  [ "$rc" -eq 3 ] && ok "resume refused (rc=3) while the plan is unrevised" || bad "should refuse rc=3 (got $rc)"
  [ "${RESUME_REFUSE_CAUSE:-}" = "resume-blocked-verify-plan-unrevised" ] \
    && ok "RESUME_REFUSE_CAUSE=resume-blocked-verify-plan-unrevised" || bad "cause should be verify-plan-unrevised (got '${RESUME_REFUSE_CAUSE:-}')"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "blocked" ] \
    && ok "fragment stays blocked (not flipped to paused)" || bad "fragment should stay blocked"
  [ "$(cat "$F")" = "$before" ] && ok "fragment byte-identical (refusal persists nothing)" || bad "fragment must be unchanged on refusal"
  [ "$(git rev-parse HEAD)" = "$FEAT_HEAD" ] && ok "build branch gained no merge commit" || bad "build branch HEAD should be unchanged on refusal"
) || true

# §4: resume accepted after the verification plan is revised + merged to
# integration. The blobs differ → accept; the TDD 0033 integration merge brings
# the revised plan into the build branch; the fragment flips to paused/transient;
# branch_head_at_pause advances to the post-merge head; the resume done-list
# excludes verify-runtime (it re-runs) while build/test-first/verify are skipped.
echo "[§4] resume accepted after revision: integration merged, only verify-runtime re-runs"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _setup_unobservable_halt "$ROOT/s4accept" 1 0 || { bad "setup failed"; exit 0; }
  F="$STATE_DIR/0035-fix.json"
  V2="$(git rev-parse master:docs/tdd/0035-fix.md)"
  RESUME_REFUSE_CAUSE=""
  _resume_from 0035-fix; rc=$?
  [ "$rc" -eq 0 ] && ok "resume accepted (rc=0) after revision" || bad "should accept rc=0 (got $rc, cause=${RESUME_REFUSE_CAUSE:-})"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "paused" ] \
    && ok "fragment flipped to paused/transient" || bad "fragment should be paused"
  [ "$(git rev-parse HEAD:docs/tdd/0035-fix.md)" = "$V2" ] \
    && ok "build branch carries the revised plan (integration merge happened)" || bad "worktree TDD should equal the revised version"
  post="$(git rev-parse refs/heads/feat/0035-fix)"
  [ "$(_read_fragment_field "$F" branch_head_at_pause)" = "$post" ] \
    && ok "branch_head_at_pause advanced to the post-merge head" || bad "branch_head_at_pause should equal the post-merge head"
  var="$(_resume_gates_var 0035-fix)"; done_list="${!var:-}"
  case ",$done_list," in *,verify-runtime,*) bad "verify-runtime must NOT be in the resume done-list (it must re-run)";; *) ok "resume done-list excludes verify-runtime (it re-runs)";; esac
  case ",$done_list," in *,build,*) ok "resume done-list includes build (already complete, skipped)";; *) bad "build should be in the resume done-list (got '$done_list')";; esac
) || true

# ===========================================================================
# §6: skills/implement/SKILL.md documents verify-unobservable as a resumable
# cause with its plan-revised resume precondition (FR-64; mirrors the
# structural-finding entry's "requires the resolving TDD revision merged" note).
echo "[§6] SKILL.md documents verify-unobservable + its plan-revised resume precondition"
( SK="$REPO/skills/implement/SKILL.md"
  [ -f "$SK" ] || { bad "SKILL.md not found"; exit 0; }
  grep -q 'verify-unobservable' "$SK" \
    && ok "SKILL.md names the verify-unobservable cause" || bad "SKILL.md should mention verify-unobservable"
  grep -q 'resume-blocked-verify-plan-unrevised' "$SK" \
    && ok "SKILL.md names the verify-plan-unrevised refusal cause" || bad "SKILL.md should mention resume-blocked-verify-plan-unrevised"
  # The plan-revised precondition: a line tying verify-unobservable's resume to a
  # revised+merged ## Verification plan.
  grep -iqE 'verification plan.*(revis|merge)' "$SK" \
    && ok "SKILL.md states the revised+merged Verification plan precondition" || bad "SKILL.md should state the plan-revised precondition"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== runtime-verify-resume eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

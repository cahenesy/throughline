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

# Shared fixture for the accept paths: a master (integration) + build/x branch
# with one build-output commit. Leaves PWD on build/x, exports STATE_DIR/
# INTEGRATION/etc, sets FEAT_HEAD. Mirrors runtime-verify-resume.test.sh's
# _setup_unobservable_halt (minus the tdd_rev revision machinery — budget /
# ci-checks recovery has no plan-revision precondition). Call AFTER sourcing.
_setup_recover_fixture() {  # <dir>
  local d="$1"
  mkdir -p "$d/state.d" "$d/repo"; cd "$d/repo" || return 1
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" \
         INTEGRATION="master" CHANGE="ci" LOGDIR="$d" RESUME=1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd src
  printf '# TDD 0039\nStatus: draft\n' > docs/tdd/0039-x.md
  printf 'orig\n' > src/a.txt
  git add -A; git commit -qm "build start" >/dev/null
  git checkout -q -b build/x
  printf 'build\n' >> src/a.txt
  git add -A; git commit -qm "build output" >/dev/null
  FEAT_HEAD="$(git rev-parse HEAD)"
}

# ===========================================================================
# §1: budget-exhausted, NO --recover → terminal. _resume_from returns 0 (not
# accepted as resumable) and the fragment is NOT flipped to paused — i.e.
# terminal-by-default is preserved (NFR-4).
echo "[§1] budget-exhausted, no --recover → terminal (not flipped)"
( d="$ROOT/g1"; mkdir -p "$d/state.d"; cd "$d" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$d" RESUME=1 RECOVER=0
  TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0039-x 39 docs/tdd/0039-x.md 1 blocked review 1000 1000 "build/x" "" log "" \
    "" "build,test-first,verify,verify-runtime" "" "abc" "" "" "" "" '{"review:6":3}' "" "" "" "" "[]" "0" "{}"
  set_halt_cause 0039-x rework-budget-exhausted review ""
  F="$STATE_DIR/0039-x.json"; before="$(cat "$F")"
  _resume_from 0039-x; rc=$?
  [ "$rc" -eq 0 ] && ok "no --recover: _resume_from returns 0 (not accepted)" || bad "should return 0 (got $rc)"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "blocked" ] && ok "fragment stays blocked (terminal-by-default)" || bad "should stay blocked"
  [ "$(cat "$F")" = "$before" ] && ok "fragment unchanged (no flip, no reset)" || bad "fragment must be unchanged without --recover"
) || true

# ===========================================================================
# §2: budget-exhausted, --recover → accepted + budget reset. The fragment flips
# to paused/transient AND rework_attempts + re_review_attempts are now {} (fresh
# budget); review re-runs (NOT in the resume done-list); RESUME_RECOVER_CAUSE is
# set for the driver report.
echo "[§2] budget-exhausted, --recover → accepted + budgets reset"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _setup_recover_fixture "$ROOT/g2" || { bad "setup failed"; exit 0; }
  export RECOVER=1
  _write_tdd_fragment 0039-x 39 docs/tdd/0039-x.md 1 blocked review 1000 1000 "build/x" "" log "" \
    "" "build,test-first,verify,verify-runtime" "" "$FEAT_HEAD" "" "" "" "" '{"review:6":3}' "" "" "" "" "[]" "0" '{"review:6":2}'
  set_halt_cause 0039-x rework-budget-exhausted review ""
  F="$STATE_DIR/0039-x.json"; RESUME_RECOVER_CAUSE=""
  _resume_from 0039-x; rc=$?
  [ "$rc" -eq 0 ] && ok "resume accepted (rc=0) under --recover" || bad "should accept rc=0 (got $rc, refuse=${RESUME_REFUSE_CAUSE:-})"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "paused" ] && ok "fragment flipped to paused/transient" || bad "should be paused"
  [ "$(_read_fragment_raw_object "$F" rework_attempts)" = '{}' ] && ok "rework_attempts reset to {}" || bad "rework_attempts should be reset (got '$(_read_fragment_raw_object "$F" rework_attempts)')"
  [ "$(_read_fragment_raw_object "$F" re_review_attempts)" = '{}' ] && ok "re_review_attempts reset to {}" || bad "re_review_attempts should be reset (got '$(_read_fragment_raw_object "$F" re_review_attempts)')"
  [ "${RESUME_RECOVER_CAUSE:-}" = "rework-budget-exhausted" ] && ok "RESUME_RECOVER_CAUSE=rework-budget-exhausted" || bad "cause should be rework-budget-exhausted (got '${RESUME_RECOVER_CAUSE:-}')"
  var="$(_resume_gates_var 0039-x)"; done_list="${!var:-}"
  case ",$done_list," in *,review,*) bad "review must NOT be in the resume done-list (it re-runs with the fresh budget)";; *) ok "done-list excludes review (re-runs with reset budget)";; esac
  case ",$done_list," in *,verify-runtime,*) ok "done-list includes verify-runtime (skipped)";; *) bad "verify-runtime should be in done-list (got '$done_list')";; esac
) || true

# §2b: a reset write-FAILURE must leave the fragment terminal (§Failure modes:
# "fragment stays terminal — never a half-reset budget"). Because the budget
# reset runs BEFORE the blocked->paused flip, a failing reset refuses the recovery
# with the fragment still `blocked`. Driven by stubbing _reset_rework_attempts to
# fail after sourcing (mirrors runtime-verify-resume.test.sh stubbing a gate exec).
echo "[§2b] reset write-failure refuses the recovery, fragment stays terminal (blocked)"
( d="$ROOT/g2b"; mkdir -p "$d/state.d"; cd "$d" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$d" RESUME=1 RECOVER=1
  TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0039-x 39 docs/tdd/0039-x.md 1 blocked review 1000 1000 "build/x" "" log "" \
    "" "build,test-first,verify,verify-runtime" "" "abc" "" "" "" "" '{"review:6":3}' "" "" "" "" "[]" "0" "{}"
  set_halt_cause 0039-x rework-budget-exhausted review ""
  F="$STATE_DIR/0039-x.json"
  _reset_rework_attempts() { return 1; }   # simulate a budget-reset write failure
  RESUME_REFUSE_CAUSE=""
  _resume_from 0039-x; rc=$?
  [ "$rc" -eq 3 ] && ok "reset failure refuses the recovery (rc=3)" || bad "should refuse rc=3 (got $rc)"
  [ "${RESUME_REFUSE_CAUSE:-}" = "resume-recover-state-write-failed" ] && ok "refuse cause = resume-recover-state-write-failed" || bad "cause should be state-write-failed (got '${RESUME_REFUSE_CAUSE:-}')"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "blocked" ] && ok "fragment stays blocked (terminal) — flip never ran" || bad "fragment must stay blocked on reset failure (got '$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)')"
) || true

# ===========================================================================
# §3: ci-checks failed, --recover → re-enters at verify; no --recover → terminal.
# Seed status:failed, note "ci-checks.sh FAIL", gates_completed [build,test-first]
# (NOT verify). RECOVER=0 leaves it terminal; RECOVER=1 flips to paused with the
# verify gate ABSENT from the done-list (so the verify/ci-checks gate re-runs).
echo "[§3] ci-checks failed, --recover → re-enters at verify; no --recover → terminal"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _setup_recover_fixture "$ROOT/g3" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0039-x 39 docs/tdd/0039-x.md 1 failed verify 1000 1000 "build/x" "" log "ci-checks.sh FAIL (tests/typecheck/lint)" \
    "" "build,test-first" "" "$FEAT_HEAD" "" "" "" "" "" "" "" "" "" "[]" "0" "{}"
  F="$STATE_DIR/0039-x.json"; before="$(cat "$F")"
  export RECOVER=0
  _resume_from 0039-x; rc0=$?
  [ "$rc0" -eq 0 ] && ok "no --recover: ci-checks failed returns 0 (terminal)" || bad "should return 0 (got $rc0)"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "failed" ] && ok "no --recover: stays failed" || bad "should stay failed"
  [ "$(cat "$F")" = "$before" ] && ok "no --recover: fragment unchanged" || bad "fragment must be unchanged without --recover"
  export RECOVER=1; RESUME_RECOVER_CAUSE=""
  _resume_from 0039-x; rc1=$?
  [ "$rc1" -eq 0 ] && ok "--recover: ci-checks failed accepted (rc=0)" || bad "should accept rc=0 (got $rc1, refuse=${RESUME_REFUSE_CAUSE:-})"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "paused" ] && ok "--recover: flipped to paused" || bad "should be paused"
  [ "${RESUME_RECOVER_CAUSE:-}" = "ci-checks" ] && ok "RESUME_RECOVER_CAUSE=ci-checks" || bad "cause should be ci-checks (got '${RESUME_RECOVER_CAUSE:-}')"
  var="$(_resume_gates_var 0039-x)"; done_list="${!var:-}"
  case ",$done_list," in *,verify,*) bad "verify must NOT be in the done-list (the verify/ci-checks gate re-runs)";; *) ok "done-list excludes verify (verify gate re-runs)";; esac
  case ",$done_list," in *,build,*) ok "done-list includes build (skipped)";; *) bad "build should be in done-list (got '$done_list')";; esac
) || true

# ===========================================================================
# §4: divergence-guard re-baseline. A (paused) fragment recording an OLD,
# now-non-ancestor sha while the branch ref points at a NEWER sha. RECOVER=1
# re-baselines to the live tip and accepts (no resume-blocked-branch-divergence);
# RECOVER=0 on the SAME divergence still refuses (the re-baseline is gated on RECOVER).
echo "[§4] divergence-guard re-baseline under --recover (refuses without it)"
_setup_divergence() {  # <dir>; leaves PWD on build/x; OLD=non-ancestor sha, build/x at NEW
  local d="$1"
  mkdir -p "$d/state.d" "$d/repo"; cd "$d/repo" || return 1
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$d" RESUME=1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src; printf 'm0\n' > src/a.txt; git add -A; git commit -qm "M0" >/dev/null
  git checkout -q -b build/x
  printf 'A\n' >> src/a.txt; git add -A; git commit -qm "A (orphaned by the reset below)" >/dev/null
  OLD="$(git rev-parse HEAD)"
  git reset --hard HEAD~1 >/dev/null 2>&1   # back to M0; A is no longer on the branch
  printf 'B\n' >> src/a.txt; git add -A; git commit -qm "B (A is now a non-ancestor)" >/dev/null
  NEW="$(git rev-parse HEAD)"
}
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _setup_divergence "$ROOT/g4" || { bad "setup failed"; exit 0; }
  F="$STATE_DIR/0039-x.json"
  seed() { _write_tdd_fragment 0039-x 39 docs/tdd/0039-x.md 1 paused review 1000 1000 "build/x" "" log "" \
      transient "build,test-first,verify,verify-runtime" "" "$OLD" "" "" "" "" "" "" "" "" "" "[]" "0" "{}"; }
  seed; export RECOVER=0; RESUME_REFUSE_CAUSE=""
  _resume_from 0039-x; rc0=$?
  [ "$rc0" -eq 3 ] && ok "no --recover: non-ancestor divergence refused (rc=3)" || bad "should refuse rc=3 (got $rc0)"
  [ "${RESUME_REFUSE_CAUSE:-}" = "resume-blocked-branch-divergence" ] && ok "refuse cause = resume-blocked-branch-divergence" || bad "cause should be branch-divergence (got '${RESUME_REFUSE_CAUSE:-}')"
  seed; export RECOVER=1; RESUME_REFUSE_CAUSE=""
  _resume_from 0039-x; rc1=$?
  [ "$rc1" -eq 0 ] && ok "--recover: re-baselines and accepts (rc=0, no divergence refusal)" || bad "should accept rc=0 (got $rc1, refuse=${RESUME_REFUSE_CAUSE:-})"
  [ "$(_read_fragment_field "$F" branch_head_at_pause)" = "$NEW" ] && ok "branch_head_at_pause re-baselined to the live tip" || bad "branch_head should be re-baselined to NEW (got '$(_read_fragment_field "$F" branch_head_at_pause)')"
) || true

# ===========================================================================
# §6: ambiguous failed → not accepted. status:failed with NO ci-checks note
# cannot be classified as a recoverable ci-checks failure; under --recover
# _resume_from refuses (resume-recover-cause-ambiguous) and the fragment stays
# terminal (NFR-4: never guess a recovery).
echo "[§6] ambiguous failed (no ci-checks note) → refused resume-recover-cause-ambiguous"
( d="$ROOT/g6"; mkdir -p "$d/state.d"; cd "$d" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$d" RESUME=1 RECOVER=1
  TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0039-x 39 docs/tdd/0039-x.md 1 failed review 1000 1000 "build/x" "" log "" \
    "" "build,test-first,verify" "" "abc" "" "" "" "" "" "" "" "" "" "[]" "0" "{}"
  F="$STATE_DIR/0039-x.json"; before="$(cat "$F")"
  RESUME_REFUSE_CAUSE=""
  _resume_from 0039-x; rc=$?
  [ "$rc" -eq 3 ] && ok "ambiguous failed under --recover refused (rc=3)" || bad "should refuse rc=3 (got $rc)"
  [ "${RESUME_REFUSE_CAUSE:-}" = "resume-recover-cause-ambiguous" ] && ok "refuse cause = resume-recover-cause-ambiguous" || bad "cause should be ambiguous (got '${RESUME_REFUSE_CAUSE:-}')"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "failed" ] && ok "fragment stays failed (terminal)" || bad "should stay failed"
  [ "$(cat "$F")" = "$before" ] && ok "fragment unchanged (refusal persists nothing)" || bad "fragment must be unchanged on ambiguous refusal"
) || true

# ===========================================================================
# §5: status.sh --check-paused surfacing. A rework-budget-exhausted blocked
# fragment and a ci-checks failed fragment each emit a DISTINCT
# `resumable=recoverable cause=<...>` line (so the skill can tell "needs explicit
# --recover" apart from an auto-resumable halt); a plain design-escalation blocked
# (halt_next_actions without a `resume` prefix) is NOT surfaced as recoverable.
echo "[§5] status.sh --check-paused surfaces resumable=recoverable for the two recoverable terminal classes"
( d="$ROOT/g5"; mkdir -p "$d/state.d"; cd "$d" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$d"
  TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  printf '{"schema":1,"started_at":1000,"updated_at":1001,"pid":1,"state":"blocked","total":3,"completed":0,"failed":1,"blocked":2,"skipped":0,"paused":0}\n' > "$d/state.d/run.json"
  # (1) rework-budget-exhausted blocked
  _write_tdd_fragment 0039-budget 39 docs/tdd/0039-budget.md 1 blocked review 1000 1000 "build/x" "" log "" \
    "" "build,test-first,verify,verify-runtime" "" "abc" "" "" "" "" "" "" "" "" "" "[]" "0" "{}"
  set_halt_cause 0039-budget rework-budget-exhausted review ""
  # (2) ci-checks failed (halt_cause null; note names ci-checks; gates build,test-first)
  _write_tdd_fragment 0039-cic 39 docs/tdd/0039-cic.md 2 failed verify 1000 1000 "build/y" "" log "ci-checks.sh FAIL (tests/typecheck/lint)" \
    "" "build,test-first" "" "abc" "" "" "" "" "" "" "" "" "" "[]" "0" "{}"
  # (3) plain design-escalation blocked (NOT recoverable, no resume prefix)
  _write_tdd_fragment 0039-desc 39 docs/tdd/0039-desc.md 3 blocked review 1000 1000 "build/z" "" log "" \
    "" "build,test-first" "" "abc" "" "" "" "" "" "" "" "" "" "[]" "0" "{}"
  set_halt_cause 0039-desc design-escalation review ""
  cp="$(bash "$REPO/scripts/status.sh" --logdir "$d" --check-paused 2>&1)"
  printf '%s' "$cp" | grep -qE 'slug=0039-budget .*cause=rework-budget-exhausted resumable=recoverable' \
    && ok "budget-exhausted blocked → resumable=recoverable cause=rework-budget-exhausted" || bad "should surface budget recoverable (got: '$cp')"
  printf '%s' "$cp" | grep -qE 'slug=0039-cic .*cause=ci-checks resumable=recoverable' \
    && ok "ci-checks failed → resumable=recoverable cause=ci-checks" || bad "should surface ci-checks recoverable (got: '$cp')"
  # The budget line must NOT be mis-tagged resumable=blocked (it is a distinct token).
  printf '%s' "$cp" | grep -E 'slug=0039-budget ' | grep -q 'resumable=blocked' \
    && bad "budget line must be resumable=recoverable, not resumable=blocked" || ok "budget line is not mis-tagged resumable=blocked"
  # design-escalation is not surfaced at all (no resume prefix, not recoverable).
  printf '%s' "$cp" | grep -q 'slug=0039-desc' \
    && bad "design-escalation blocked must NOT be surfaced (got: '$cp')" || ok "design-escalation blocked is not surfaced (stays human-routed)"
) || true

# ===========================================================================
# §7 (mechanical): skills/implement/SKILL.md documents the --recover flag, adds
# the "Recover" offer keyed off a resumable=recoverable line, and states plainly
# that recovery TREATS THE HALT AS AN ARTIFACT (so the human owns that judgement).
# Fail-closed greps (L-001/L-002): distinguish exit 1 (absent → real failure)
# from ≥2 (unreadable → harness failure) and fail on the latter; assert the file
# is readable before any content check.
echo "[§7] SKILL.md documents --recover + the Recover offer keyed on resumable=recoverable"
( SK="$REPO/skills/implement/SKILL.md"
  [ -r "$SK" ] || { bad "SKILL.md not readable"; exit 0; }
  has() {  # <regex> <ok-msg> <bad-msg>  (-e so a pattern starting with - is not an option)
    grep -qE -e "$1" "$SK"; local rc=$?
    if [ "$rc" -eq 0 ]; then ok "$2"
    elif [ "$rc" -eq 1 ]; then bad "$3"
    else bad "grep failed reading SKILL.md (rc=$rc) for: $1"; fi
  }
  has '--recover' "SKILL.md documents the --recover flag" "SKILL.md should document --recover"
  has 'resumable=recoverable' "SKILL.md keys the Recover offer on resumable=recoverable" "SKILL.md should mention resumable=recoverable"
  has 'Recover' "SKILL.md names the Recover option" "SKILL.md should name a Recover option"
  has 'treats the halt as an artifact|as an artifact' "SKILL.md states recovery treats the halt as an artifact" "SKILL.md should state the halt-is-an-artifact framing"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== recoverable-terminal-halts eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

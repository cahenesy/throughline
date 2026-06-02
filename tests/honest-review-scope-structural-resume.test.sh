#!/usr/bin/env bash
# honest-review-scope-structural-resume.test.sh — eval for TDD 0031
# (honest consolidated-review scope on resume + revision-resolved structural-halt
# resume). Covers the TDD's verification points §1–§9 with shared git/worktree
# fixtures (one comprehensive eval per the TDD's declared expected-diff exception:
# every point reuses the same repo/worktree scaffolding, so splitting would
# duplicate it). Uses stub `claude` so no model or tokens are needed.
#
#   §1 _review_base derives the build-start merge-base, not gate-entry HEAD (gap A)
#   §2 the derived base flows into the rendered review prompt's diff line (gap A)
#   §3 review_one fails closed on an empty scope, spawning no reviewer (gap A)
#   §4 a structural-finding halt records the tdd_rev= revision fingerprint (gap B)
#   §5 a structural-finding halt surfaces as resumable in status.sh (gap B)
#   §6 resume refused while the resolving TDD revision is unmerged (gap B)
#   §7 resume accepted after revision + integration merge (gap B)
#   §8 a merge conflict refuses cleanly with a persisted cause (gap B)
#   §9 both new refusal outcomes render correctly in status.sh (gap B)
#
# Run: bash tests/honest-review-scope-structural-resume.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# A stub `claude` that records the prompt it was handed and emits a review PASS.
# Used by the §3 negative path: BEFORE the empty-scope guard exists, review_one
# would spawn this (rc 0, a THROUGHLINE_SESSION line) — the RED failure; AFTER,
# the guard returns before any spawn so this is never invoked.
_install_review_stub() {  # <bindir> <recordfile>
  local b="$1" rec="$2"; mkdir -p "$b"
  cat > "$b/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
printf '%s' "\$prompt" > "$rec"
echo "REVIEW_RESULT: PASS"
exit 0
EOF
  chmod +x "$b/claude"
}

# ===========================================================================
# §1 (gap A): _review_base derives the build start, NOT gate-entry HEAD. On a
# resumed branch the old `git rev-parse HEAD` equals the branch tip, collapsing
# the consolidated review to HEAD..HEAD (the vacuous-pass bug). _review_base
# returns `git merge-base <stacking-base> HEAD` — the true fork point — instead.
echo "[§1] _review_base returns the build-start merge-base, not gate-entry HEAD"
( D="$ROOT/s1"; mkdir -p "$D"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  command -v _review_base >/dev/null 2>&1 || { bad "_review_base helper missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'x\n' > f.txt; git add -A; git commit -qm base >/dev/null
  fork="$(git rev-parse HEAD)"
  git checkout -q -b build/x
  for i in 1 2 3; do printf '%s\n' "$i" >> f.txt; git add -A; git commit -qm "c$i" >/dev/null; done
  mb="$(git merge-base master HEAD)"; tip="$(git rev-parse HEAD)"
  rb="$(_review_base master)"
  [ "$rb" = "$mb" ]   && ok "_review_base equals git merge-base <base> HEAD" || bad "_review_base should equal the merge-base (got '$rb' want '$mb')"
  [ "$rb" != "$tip" ] && ok "_review_base is NOT gate-entry HEAD (the resume vacuous-pass bug)" || bad "_review_base must not equal the branch tip on a resumed branch"
  [ "$rb" = "$fork" ] && ok "_review_base equals the fork point (the build start)" || bad "_review_base should equal the fork point (got '$rb' want '$fork')"
  # negative (fresh-build equivalence): zero commits past the fork → equals HEAD,
  # so a fresh build is unchanged by construction.
  git checkout -q master; git checkout -q -b build/fresh
  rb2="$(_review_base master)"
  [ "$rb2" = "$(git rev-parse HEAD)" ] && ok "fresh build: _review_base equals HEAD (no behavior change)" || bad "fresh-build base should equal HEAD (got '$rb2')"
) || true

# §1-fallback: no merge base (unrelated histories / deleted base) → echo the
# passed ref unchanged + warn. Never worse than the pre-0031 behavior.
echo "[§1-fallback] _review_base falls back to the passed ref when no merge-base resolves"
( D="$ROOT/s1f"; mkdir -p "$D"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  command -v _review_base >/dev/null 2>&1 || { bad "_review_base helper missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'x\n' > f.txt; git add -A; git commit -qm base >/dev/null
  rb="$(_review_base does-not-exist 2>/dev/null)"
  [ "$rb" = "does-not-exist" ] && ok "unresolvable base echoes the passed ref unchanged" || bad "fallback should echo the ref (got '$rb')"
) || true

# ===========================================================================
# §2 (gap A): the derived base is what scopes the consolidated review. On resume
# the driver computes `pre=_review_base <stacking-base>`; review_one renders the
# prompt with `git diff <pre>..HEAD`. Confirm the merge-base — not the branch tip
# — lands in the rendered diff line (the observable for "not a vacuous scope").
echo "[§2] the derived base flows into the rendered review prompt's diff line"
( D="$ROOT/s2"; mkdir -p "$D"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export RTMPL="$REPO/scripts/review-prompt.md"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd; printf '# TDD\nStatus: draft\n' > docs/tdd/0031-x.md
  git add -A; git commit -qm base >/dev/null
  git checkout -q -b build/x
  printf 'more\n'  >> docs/tdd/0031-x.md; git add -A; git commit -qm c1 >/dev/null
  printf 'more2\n' >> docs/tdd/0031-x.md; git add -A; git commit -qm c2 >/dev/null
  pre="$(_review_base master)"; mb="$(git merge-base master HEAD)"; tip="$(git rev-parse HEAD)"
  [ "$pre" = "$mb" ] && ok "driver pre= equals the merge-base (the build start)" || bad "pre should equal the merge-base (got '$pre')"
  prompt="$(_render_review_prompt docs/tdd/0031-x.md "$pre" HEAD build/x "")"
  printf '%s' "$prompt" | grep -qF "git diff $pre..HEAD" \
    && ok "rendered review prompt scopes git diff <merge-base>..HEAD" || bad "prompt should scope the merge-base diff"
  printf '%s' "$prompt" | grep -qF "git diff $tip..HEAD" \
    && bad "prompt must NOT collapse to git diff <tip>..HEAD (the vacuous-pass bug)" \
    || ok "prompt does not collapse to <tip>..HEAD"
) || true

# ===========================================================================
# §3 (gap A): defense-in-depth — review_one refuses an empty review scope. With
# base == HEAD the diff is provably empty; review_one must log
# THROUGHLINE_REVIEW_SCOPE_EMPTY and return non-zero WITHOUT spawning a reviewer
# (no THROUGHLINE_SESSION line after the EMPTY line). NFR-4: ambiguity is never a
# false PASS.
echo "[§3] review_one fails closed on an empty scope (base == HEAD), spawning no reviewer"
( D="$ROOT/s3"; mkdir -p "$D/bin"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export RTMPL="$REPO/scripts/review-prompt.md" MODEL="" REVIEW_MODEL=""
  _install_review_stub "$D/bin" "$D/review-prompt.txt"
  export PATH="$D/bin:$PATH"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd; printf '# TDD\nStatus: draft\n' > docs/tdd/0031-x.md
  git add -A; git commit -qm base >/dev/null
  head="$(git rev-parse HEAD)"
  log="$D/review.log"
  review_one docs/tdd/0031-x.md "$head" "$log"; rc=$?
  [ "$rc" -ne 0 ] && ok "review_one returns non-zero on an empty scope" || bad "review_one should fail closed (got rc=$rc)"
  grep -q 'THROUGHLINE_REVIEW_SCOPE_EMPTY' "$log" 2>/dev/null \
    && ok "gate log records THROUGHLINE_REVIEW_SCOPE_EMPTY" || bad "gate log should record THROUGHLINE_REVIEW_SCOPE_EMPTY"
  # The precise observable for "no reviewer spawned": no THROUGHLINE_SESSION line
  # after the EMPTY line.
  if awk '/THROUGHLINE_REVIEW_SCOPE_EMPTY/{seen=1} seen&&/THROUGHLINE_SESSION:/{f=1} END{exit !f}' "$log" 2>/dev/null; then
    bad "a THROUGHLINE_SESSION line followed the EMPTY line (a reviewer was spawned)"
  else
    ok "no reviewer process spawned (no THROUGHLINE_SESSION after the EMPTY line)"
  fi
  [ ! -s "$D/review-prompt.txt" ] && ok "stub reviewer was never invoked (no recorded prompt)" || bad "the reviewer stub should not have been invoked"
) || true

# ===========================================================================
# §3a (gap B): taxonomy. structural-finding gains a `resume` next-action (so
# status.sh --check-paused and _resume_from's blocked arm surface it);
# resume-blocked-integration-conflict joins the closed PERSISTED enum as a paused
# cause; resume-blocked-tdd-unrevised is driver-report-only and joins NO enum.
echo "[§3a-taxonomy] structural-finding gains a resume action; integration-conflict joins the enum; tdd-unrevised does not"
( D="$ROOT/s3a"; mkdir -p "$D"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  acts="$(_next_actions_for_cause structural-finding)"
  printf '%s' "$acts" | grep -q 'resume after revision' \
    && ok "structural-finding next-actions include a resume-after-revision entry" || bad "structural-finding should gain a resume action (got '$acts')"
  printf '%s' "$acts" | grep -q 'see docs/tdd/BLOCKERS.md' \
    && ok "structural-finding still points at BLOCKERS.md (FR-67 reaffirmed)" || bad "structural-finding should still cite BLOCKERS.md (got '$acts')"
  _next_actions_for_cause resume-blocked-integration-conflict >/dev/null 2>&1 \
    && ok "resume-blocked-integration-conflict is in the closed enum" || bad "resume-blocked-integration-conflict should be enumerated"
  _is_paused_cause resume-blocked-integration-conflict \
    && ok "resume-blocked-integration-conflict is a paused (recoverable) cause" || bad "integration-conflict should be a paused cause"
  # resume-blocked-tdd-unrevised is NEVER persisted (the fragment stays blocked/
  # structural-finding) → it must NOT join the enum or the paused classifier.
  if _next_actions_for_cause resume-blocked-tdd-unrevised >/dev/null 2>&1; then
    bad "resume-blocked-tdd-unrevised must NOT be enumerated (driver-report-only)"
  else
    ok "resume-blocked-tdd-unrevised stays out of the enum (never persisted)"
  fi
  _is_paused_cause resume-blocked-tdd-unrevised \
    && bad "resume-blocked-tdd-unrevised must NOT be a paused cause" || ok "resume-blocked-tdd-unrevised is not classified paused"
) || true

# ===========================================================================
# §4 (gap B): a structural-finding halt records the revision fingerprint inside
# halt_cause_detail (no schema change; the token rides in free text). set_halt_cause
# derives git rev-parse HEAD:<tdd-path> in the halt-time cwd and appends tdd_rev=.
echo "[§4] a structural-finding halt records the tdd_rev= revision fingerprint"
( D="$ROOT/s4"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd; printf '# TDD 0031\nStatus: draft\n## Approach\nx\n' > docs/tdd/0031-fix.md
  git add -A; git commit -qm "build start" >/dev/null
  blob="$(git rev-parse HEAD:docs/tdd/0031-fix.md)"
  _write_tdd_fragment 0031-fix 31 docs/tdd/0031-fix.md 1 blocked review 1000 1000 "feat/0031-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0031-fix structural-finding review:1 "(b)"
  F="$STATE_DIR/0031-fix.json"
  detail="$(_read_fragment_field "$F" halt_cause_detail)"
  [ "$detail" = "(b) tdd_rev=$blob" ] \
    && ok "halt_cause_detail ends with the tdd_rev fingerprint" || bad "detail should be '(b) tdd_rev=$blob' (got '$detail')"
) || true

echo "[§4-degraded] no tdd_rev token when the TDD blob cannot be derived (e.g. path absent)"
( D="$ROOT/s4d"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'x\n' > f.txt; git add -A; git commit -qm base >/dev/null   # TDD path NOT committed
  _write_tdd_fragment 0031-fix 31 docs/tdd/0031-fix.md 1 blocked review 1000 1000 "feat/0031-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0031-fix structural-finding review:1 "(b)"
  detail="$(_read_fragment_field "$STATE_DIR/0031-fix.json" halt_cause_detail)"
  [ "$detail" = "(b)" ] && ok "detail written verbatim (no token) when the blob is unresolvable" || bad "degraded detail should be '(b)' (got '$detail')"
) || true

# ===========================================================================
# §5 (gap B): a structural-finding halt now surfaces in status.sh --check-paused
# (it previously had no resume action, so it was invisible to resume).
echo "[§5] structural-finding surfaces as resumable=blocked in status.sh --check-paused"
( D="$ROOT/s5"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  printf '{"schema":1,"pid":1,"state":"interrupted","total":1}\n' > "$D/state.d/run.json"
  _write_tdd_fragment 0031-fix 31 docs/tdd/0031-fix.md 1 blocked review 1000 1000 "feat/0031-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0031-fix structural-finding review:1 "(b)"   # writes the new taxonomy next-actions
  out="$(bash "$REPO/scripts/status.sh" --logdir "$D" --check-paused 2>&1)"
  printf '%s\n' "$out" | grep -qE 'slug=0031-fix .*cause=structural-finding resumable=blocked' \
    && ok "structural-finding surfaces as resumable=blocked" || bad "should surface resumable=blocked (got: '$out')"
) || true

# §3a-mirror: status.sh recognizes resume-blocked-integration-conflict as a known
# paused cause (no raw-render fallback warning), exercising both status.sh mirror
# functions (_halt_cause_known + _halt_is_paused_cause).
echo "[§3a-mirror] status.sh renders a resume-blocked-integration-conflict pause without the unknown-cause warning"
( D="$ROOT/s3am"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  printf '{"schema":1,"started_at":1000,"updated_at":1001,"pid":1,"state":"paused","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"paused":1}\n' > "$D/state.d/run.json"
  _write_tdd_fragment 0031-fix 31 docs/tdd/0031-fix.md 1 paused review 1000 1000 "feat/0031-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0031-fix resume-blocked-integration-conflict review:1 "merge conflict"
  out="$(bash "$REPO/scripts/status.sh" --logdir "$D" 2>&1)"
  printf '%s' "$out" | grep -qi 'unknown halt_cause' \
    && bad "status.sh must NOT warn unknown-cause for resume-blocked-integration-conflict (got: $out)" \
    || ok "resume-blocked-integration-conflict renders as a known cause (no fallback warning)"
  printf '%s' "$out" | grep -q 'resume-blocked-integration-conflict' \
    && ok "the conflict cause label appears in the halt render" || bad "the conflict cause should render (got: $out)"
) || true

# ===========================================================================
# Shared fixture for §6–§8: a master (integration) + feat build branch carrying a
# structural-finding halt whose tdd_rev fingerprint was recorded from the branch's
# TDD copy. Leaves PWD on feat/<slug>. Echoes nothing; sets fragment + globals.
#   <dir> <revise-integration?0|1> <conflict?0|1>
_setup_structural_halt() {  # <dir> <revise> <conflict>
  local d="$1" revise="$2" conflict="$3"
  # state.d lives OUTSIDE the repo worktree so the fixture's `git add -A` / branch
  # switches never sweep or delete the fragment (it is run-state, not repo content).
  mkdir -p "$d/state.d" "$d/repo"; cd "$d/repo" || return 1
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" \
         INTEGRATION="master" CHANGE="ci" LOGDIR="$d" RESUME=1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd src
  printf '# TDD 0031\nStatus: draft\n## Approach\nv1\n' > docs/tdd/0031-fix.md
  printf 'orig\n' > src/a.txt
  git add -A; git commit -qm "build start (TDD v1)" >/dev/null
  git checkout -q -b feat/0031-fix
  if [ "$conflict" = 1 ]; then
    printf 'feat-version\n' > src/a.txt   # conflicts with master's edit below
  else
    printf 'build\n' >> src/a.txt          # a build-output commit, non-conflicting
  fi
  git add -A; git commit -qm "build output" >/dev/null
  FEAT_HEAD="$(git rev-parse HEAD)"
  # Record the structural halt: tdd_rev = the branch's (v1) TDD blob.
  _write_tdd_fragment 0031-fix 31 docs/tdd/0031-fix.md 1 blocked review 1000 1000 \
    "feat/0031-fix" "" log "" "" "build,test-first,verify,verify-runtime" "" "$FEAT_HEAD" "" "" "" "" "" "" "" "" ""
  set_halt_cause 0031-fix structural-finding review:1 "(b)"
  if [ "$revise" = 1 ]; then
    git checkout -q master
    printf '# TDD 0031\nStatus: draft\n## Approach\nv2 REVISED\n' > docs/tdd/0031-fix.md
    [ "$conflict" = 1 ] && printf 'master-version\n' > src/a.txt
    git add -A; git commit -qm "revise TDD (resolves the structural halt)" >/dev/null
    git checkout -q feat/0031-fix
  fi
}

# §6 (gap B): resume refused while the resolving TDD revision is UNMERGED. The
# recorded tdd_rev equals integration's current blob for the TDD path → resuming
# would re-halt identically; refuse, persist NOTHING (the fragment keeps its
# accurate blocked/structural-finding state).
echo "[§6] resume refused while the TDD revision is unmerged (tdd_rev == integration blob)"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _setup_structural_halt "$ROOT/s6" 0 0 || { bad "setup failed"; exit 0; }
  F="$STATE_DIR/0031-fix.json"; before="$(cat "$F")"
  RESUME_REFUSE_CAUSE=""
  _resume_from 0031-fix; rc=$?
  [ "$rc" -eq 3 ] && ok "resume refused (rc=3) while the TDD is unrevised" || bad "should refuse rc=3 (got $rc)"
  [ "${RESUME_REFUSE_CAUSE:-}" = "resume-blocked-tdd-unrevised" ] \
    && ok "RESUME_REFUSE_CAUSE=resume-blocked-tdd-unrevised" || bad "cause should be tdd-unrevised (got '${RESUME_REFUSE_CAUSE:-}')"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "blocked" ] \
    && ok "fragment stays blocked (not flipped to paused)" || bad "fragment should stay blocked"
  [ "$(cat "$F")" = "$before" ] && ok "fragment byte-identical (refusal persists nothing)" || bad "fragment must be unchanged on refusal"
) || true

# §7 (gap B): resume accepted after the revision is merged to integration. The
# blobs differ → accept; merge integration into the build branch so the resumed
# gates read the REVISED TDD; advance branch_head_at_pause to the post-merge head.
echo "[§7] resume accepted after revision: integration merged into the build branch"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _setup_structural_halt "$ROOT/s7" 1 0 || { bad "setup failed"; exit 0; }
  F="$STATE_DIR/0031-fix.json"
  V2="$(git rev-parse master:docs/tdd/0031-fix.md)"
  RESUME_REFUSE_CAUSE=""
  _resume_from 0031-fix; rc=$?
  [ "$rc" -eq 0 ] && ok "resume accepted (rc=0) after revision" || bad "should accept rc=0 (got $rc, cause=${RESUME_REFUSE_CAUSE:-})"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "paused" ] \
    && ok "fragment flipped to paused/transient" || bad "fragment should be paused"
  [ "$(git rev-parse HEAD:docs/tdd/0031-fix.md)" = "$V2" ] \
    && ok "worktree TDD content == integration's revised version (merge happened)" || bad "worktree TDD should equal the revised version"
  post="$(git rev-parse refs/heads/feat/0031-fix)"
  [ "$(_read_fragment_field "$F" branch_head_at_pause)" = "$post" ] \
    && ok "branch_head_at_pause advanced to the post-merge head" || bad "branch_head_at_pause should equal the post-merge head"
) || true

# §8 (gap B): the integration merge conflicts → abort, persist
# resume-blocked-integration-conflict, leave the worktree clean (no in-progress
# merge, no conflict markers), return 3.
echo "[§8] integration merge conflict refuses cleanly with a persisted cause"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _setup_structural_halt "$ROOT/s8" 1 1 || { bad "setup failed"; exit 0; }
  F="$STATE_DIR/0031-fix.json"
  RESUME_REFUSE_CAUSE=""
  _resume_from 0031-fix; rc=$?
  [ "$rc" -eq 3 ] && ok "merge conflict refuses (rc=3)" || bad "should refuse rc=3 (got $rc)"
  [ "${RESUME_REFUSE_CAUSE:-}" = "resume-blocked-integration-conflict" ] \
    && ok "RESUME_REFUSE_CAUSE=resume-blocked-integration-conflict" || bad "cause should be integration-conflict (got '${RESUME_REFUSE_CAUSE:-}')"
  [ "$(sed -n 's/.*"paused_cause":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "resume-blocked-integration-conflict" ] \
    && ok "paused_cause persisted == resume-blocked-integration-conflict" || bad "paused_cause should be persisted (got: $(grep -o '"paused_cause":[^,]*' "$F"))"
  git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
    && bad "an in-progress merge was left behind (abort failed)" || ok "no in-progress merge (git merge --abort ran)"
  grep -q '^<<<<<<<' src/a.txt 2>/dev/null \
    && bad "conflict markers left on disk" || ok "no conflict markers on disk (worktree clean)"
) || true

# ===========================================================================
# §9 (gap B): both refusal outcomes render correctly in status.sh.
# Fixture A — the point-8 conflict fragment: full render emits no raw-render
# fallback warning (the carried structural-finding cause is known), and
# --check-paused surfaces the persisted conflict cause.
echo "[§9-A] the conflict outcome renders correctly in status.sh (no unknown-cause warning; --check-paused surfaces it)"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _setup_structural_halt "$ROOT/s9a" 1 1 || { bad "setup failed"; exit 0; }
  # Guard the fixture: the resume MUST refuse on the merge conflict (rc=3) before
  # we assert on the render — a silently-discarded rc would let the render checks
  # pass against the wrong fragment state (false pass).
  _resume_from 0031-fix >/dev/null 2>&1; rrc=$?
  [ "$rrc" -eq 3 ] || { bad "§9-A fixture: resume should refuse on the merge conflict (rc=3, got $rrc)"; exit 0; }
  printf '{"schema":1,"started_at":1000,"updated_at":1001,"pid":1,"state":"paused","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"paused":1}\n' > "$STATE_DIR/run.json" \
    || { bad "§9-A fixture: could not write run.json"; exit 0; }
  out="$(bash "$REPO/scripts/status.sh" --logdir "$LOGDIR" 2>&1)"
  printf '%s' "$out" | grep -qi 'unknown halt_cause' \
    && bad "status.sh must not emit a raw-render fallback warning (got: $out)" \
    || ok "full render emits no unknown-cause fallback warning"
  cp="$(bash "$REPO/scripts/status.sh" --logdir "$LOGDIR" --check-paused 2>&1)"
  printf '%s' "$cp" | grep -q 'cause=resume-blocked-integration-conflict' \
    && ok "--check-paused surfaces the persisted conflict cause" || bad "--check-paused should surface the conflict cause (got: $cp)"
) || true

# §9-A2: when the conflict cause IS the rendered cause (the _halt_field fallback /
# a conflict-cause halt), status.sh renders its next-action text + a Resume:
# trailer with no fallback warning — exercising BOTH new status.sh mirror arms
# (_halt_cause_known + _halt_is_paused_cause).
echo "[§9-A2] a conflict-cause halt renders its next-action text + Resume trailer (status.sh mirrors)"
( D="$ROOT/s9a2"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  printf '{"schema":1,"started_at":1000,"updated_at":1001,"pid":1,"state":"paused","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"paused":1}\n' > "$D/state.d/run.json" \
    || { bad "§9-A2 fixture: could not write run.json"; exit 0; }
  _write_tdd_fragment 0031-fix 31 docs/tdd/0031-fix.md 1 paused review 1000 1000 "feat/0031-fix" "" log "" "" "" "" "" "" "" "" "" "" "" "" \
    || { bad "§9-A2 fixture: could not write fragment"; exit 0; }
  set_halt_cause 0031-fix resume-blocked-integration-conflict review:1 "merge conflict on src/a.txt" \
    || { bad "§9-A2 fixture: set_halt_cause failed (cause not recorded)"; exit 0; }
  out="$(bash "$REPO/scripts/status.sh" --logdir "$D" 2>&1)"
  printf '%s' "$out" | grep -qi 'unknown halt_cause' \
    && bad "must not warn unknown-cause for resume-blocked-integration-conflict (got: $out)" || ok "conflict cause renders without a fallback warning"
  printf '%s' "$out" | grep -q 'resolve the integration merge conflict on the build branch manually' \
    && ok "render shows the conflict cause's next-action text" || bad "render should show the conflict next-action (got: $out)"
  printf '%s' "$out" | grep -q 'Resume: /implement --resume' \
    && ok "Resume trailer shown (conflict is a paused/recoverable cause)" || bad "Resume trailer should appear for the conflict cause (got: $out)"
) || true

# Fixture B — the point-6 tdd-unrevised fragment: the refused resume changed
# NOTHING, so the fragment still renders the structural-finding halt exactly as a
# fresh structural halt would (cause label + the 3-entry next-actions; no Resume
# trailer since structural-finding is not a paused cause).
echo "[§9-B] the tdd-unrevised refusal leaves the structural-finding halt rendering unchanged"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _setup_structural_halt "$ROOT/s9b" 0 0 || { bad "setup failed"; exit 0; }
  # Guard the fixture: the resume MUST refuse (rc=3, tdd-unrevised) and leave the
  # fragment unchanged before we assert the structural-finding render — a discarded
  # rc would risk asserting against the wrong state.
  _resume_from 0031-fix >/dev/null 2>&1; rrc=$?
  [ "$rrc" -eq 3 ] || { bad "§9-B fixture: resume should refuse tdd-unrevised (rc=3, got $rrc)"; exit 0; }
  printf '{"schema":1,"started_at":1000,"updated_at":1001,"pid":1,"state":"blocked","total":1,"completed":0,"failed":0,"blocked":1,"skipped":0,"paused":0}\n' > "$STATE_DIR/run.json" \
    || { bad "§9-B fixture: could not write run.json"; exit 0; }
  out="$(bash "$REPO/scripts/status.sh" --logdir "$LOGDIR" 2>&1)"
  printf '%s' "$out" | grep -qi 'unknown halt_cause' \
    && bad "must not warn unknown-cause for structural-finding (got: $out)" || ok "structural-finding renders without a fallback warning"
  printf '%s' "$out" | grep -q 'structural-finding' \
    && ok "render names the structural-finding cause" || bad "render should name structural-finding (got: $out)"
  printf '%s' "$out" | grep -q 'resume after revision' \
    && ok "render lists the resume-after-revision next-action (taxonomy)" || bad "render should list resume-after-revision (got: $out)"
  printf '%s' "$out" | grep -q 'Resume: /implement --resume' \
    && bad "structural-finding must NOT show a Resume trailer (it is not a paused cause)" || ok "no Resume trailer for the blocked structural-finding halt"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== honest-review-scope-structural-resume eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# runner-resilience.test.sh — eval for TDD 0027 (runner resilience: hung
# children, unclean exits, resumable halts).
#
# Covers the eight observation points in TDD 0027's `## Verification plan`:
#   VP1 — a hung gate child self-recovers via the per-call watchdog (gap 1).
#   VP2 — the gate-timeout knob is snapshotted into run.json config (gap 1).
#   VP3 — a stale build worktree is reclaimed at launch (gap 2).
#   VP4 — a fast-forward-advanced branch resumes (gap 3b).
#   VP5 — a true rewrite is still refused (gap 3b negative).
#   VP6 — a resumable `blocked` halt is surfaced + accepted; a non-resumable
#         one is not (gap 3a/3c).
#   VP7 — an honest FAIL/BLOCK verdict survives a non-zero child exit (gap 4).
#   VP8 — a verdict-less clean exit resolves to FAIL, never a false PASS (gap 4).
#
# Most blocks source implement.sh in `THROUGHLINE_SOURCE_ONLY=1` mode (the
# runner's testability guard) so they can call the gate/resume helpers directly
# without spinning up a full detached run.
#
# Run: bash tests/runner-resilience.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
STATUS="$REPO/scripts/status.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Test isolation: VP5's true-rewrite REFUSAL asserts _resume_from's default,
# no-`--recover` divergence behavior. The runner sets RECOVER=1 for a `/implement
# --recover` resume, and ci-checks runs this eval as a SUBPROCESS that INHERITS
# that env — an inherited RECOVER=1 routes the refusal through resume.sh's
# divergence re-baseline arm (TDD 0039 §3) instead of refusing, producing false
# failures (green standalone, red only inside a --recover resume). Unset it so
# every scenario controls RECOVER explicitly. (Sibling fix to run-recovery.test.sh.)
unset RECOVER

# A minimal review-prompt template so _render_review_prompt resolves without the
# implement.sh setup block. The placeholders are the same ones the real template
# carries; the content is irrelevant to the wrapper under test.
review_tmpl() {  # <path>
  cat > "$1" <<'TMPL'
INDEPENDENT review gate for {{TDD}} scope {{SCOPE_BASE}}..{{SCOPE_HEAD}} on {{BRANCH}}.
Prior addressed patterns: {{PRIOR_PATTERNS}}.
TMPL
}

# A minimal runtime-verify prompt template (placeholders the real one carries).
verify_tmpl() {  # <path>
  cat > "$1" <<'TMPL'
INDEPENDENT runtime-verification gate for {{TDD}} base {{BASE}}.
TMPL
}

# Write a `claude` stub that prints <line> then exits <rc>, and prepend its dir
# to PATH. Used to drive the gate wrappers with a controllable verdict + exit
# code (gap 4: verdict-before-exit-code ordering).
mk_stub() {  # <bindir> <line> <rc>
  mkdir -p "$1"
  cat > "$1/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$2"
exit $3
EOF
  chmod +x "$1/claude"; export PATH="$1:$PATH"
}

# A minimal git repo with one committed TDD; cwd is the repo on return, and
# HEAD/build_start are echoed via the BUILD_START global.
setup_repo() {  # <dir>
  local dir="$1"
  mkdir -p "$dir/docs/tdd"
  cd "$dir"
  git init -q; git config user.email t@t.invalid; git config user.name "resilience test"
  cat > docs/tdd/0001-alpha.md <<'TDD'
# TDD 0001 — alpha
Status: draft
## Sequencing
1. step one
## Touched files
- foo.txt
TDD
  git add -A; git commit -q -m "init"
  BUILD_START="$(git rev-parse HEAD)"
  # A build-output commit PAST build-start so the consolidated review scope
  # BUILD_START..HEAD is non-empty — what a real build always produces. TDD 0031
  # §2's empty-scope guard in review_one fails closed on a HEAD..HEAD scope, so a
  # build-start that equals HEAD would short-circuit the verdict-vs-exit-code paths
  # these scenarios exercise. (The per-step review path is unaffected by the guard.)
  printf 'build output\n' > foo.txt; git add -A; git commit -q -m "build output"
}

# --- [VP1] hung gate child self-recovers (gap 1) ---------------------------
# A stub `claude` that sleeps forever, driven through _run_per_step_review with
# a 5s gate watchdog, MUST return promptly (not hang), leave the step-review log
# on disk with the timeout marker, and emit a `STEP_REVIEW: BLOCK …no
# REVIEW_RESULT…` line (NFR-4: a timed-out review is never a false PASS).
echo "[VP1] hung per-step-review child is killed by the gate watchdog and BLOCKs"
( D="$ROOT/vp1"; mkdir -p "$D/bin"
  setup_repo "$D"
  cat > "$D/bin/claude" <<'EOF'
#!/usr/bin/env bash
exec sleep 10000
EOF
  chmod +x "$D/bin/claude"; export PATH="$D/bin:$PATH"
  review_tmpl "$D/review.md"; export RTMPL="$D/review.md"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_GATE_TIMEOUT=5
  mainlog="$D/main.log"; : > "$mainlog"
  t0=$(date +%s)
  verdict="$(_run_per_step_review 0001-alpha docs/tdd/0001-alpha.md 1 "$BUILD_START" "$BUILD_START" "$mainlog")"
  t1=$(date +%s); elapsed=$((t1 - t0))
  rlog="$D/0001-alpha.step1.review.log"
  [ "$elapsed" -lt 30 ] \
    && ok "per-step review returns within the watchdog (took ${elapsed}s)" \
    || bad "per-step review should return within ~10s but took ${elapsed}s (hang)"
  case "$verdict" in
    *"STEP_REVIEW: BLOCK"*"no REVIEW_RESULT"*) ok "verdict is BLOCK (no REVIEW_RESULT) after timeout" ;;
    *) bad "verdict should be STEP_REVIEW: BLOCK …no REVIEW_RESULT… (got '$verdict')" ;;
  esac
  [ -f "$rlog" ] && ok "step-review log exists on disk" || bad "step-review log should exist ($rlog)"
  grep -q '^THROUGHLINE_GATE_TIMEOUT' "$rlog" 2>/dev/null \
    && ok "gate log carries the THROUGHLINE_GATE_TIMEOUT marker" \
    || bad "gate log should carry the THROUGHLINE_GATE_TIMEOUT marker (routes 124 -> transient)"
) || true

# --- [VP2] gate-timeout knob snapshotted into run.json (gap 1) -------------
# Launching with THROUGHLINE_GATE_TIMEOUT=120 must record "gate_timeout":120 in
# run.json's config block so a timeout-driven halt is reproducible from
# run-state alone (ADR 0006).
echo "[VP2] THROUGHLINE_GATE_TIMEOUT is snapshotted into run.json config"
( D="$ROOT/vp2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_GATE_TIMEOUT=120
  _write_run_fragment running
  R="$D/state.d/run.json"
  grep -q '"gate_timeout":120' "$R" 2>/dev/null \
    && ok "run.json config records gate_timeout=120" \
    || bad "run.json config should record \"gate_timeout\":120 ($(cat "$R" 2>/dev/null))"
) || true

# --- [VP7] honest verdict survives a non-zero child exit (gap 4) -----------
# _verify_runtime_one_gated / _review_one_gated parse the verdict FIRST; only a
# verdict-less child is classified by exit code. So a PASS/SKIP verdict wins even
# when the child exits non-zero (e.g. killed by the gate timeout after emitting
# its verdict), and an honest FAIL/BLOCK + non-zero exit is a plain gate failure
# (rc=1), never conflated with a process error (NFR-4).
echo "[VP7] gate wrappers honor the logged verdict over the child's exit code"
( D="$ROOT/vp7"; setup_repo "$D"
  verify_tmpl "$D/verify.md"; review_tmpl "$D/review.md"
  export MODEL=stub-model REVIEW_MODEL=stub-model RVMTPL="$D/verify.md" RTMPL="$D/review.md"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }

  # (a) DISCRIMINATING: PASS verdict but the child exited non-zero -> 0.
  ( mk_stub "$D/bin-a" "VERIFY_RUNTIME: PASS observed the surface" 3
    _verify_runtime_one_gated docs/tdd/0001-alpha.md "$BUILD_START" "$D/va.log"; rc=$?
    [ "$rc" = "0" ] && ok "verify: PASS verdict wins over a non-zero exit (rc=0)" \
      || bad "verify: PASS verdict + exit 3 should return 0 (got $rc)" )
  ( mk_stub "$D/bin-ar" "REVIEW_RESULT: PASS clean" 3
    _review_one_gated docs/tdd/0001-alpha.md "$BUILD_START" "$D/ra.log"; rc=$?
    [ "$rc" = "0" ] && ok "review: PASS verdict wins over a non-zero exit (rc=0)" \
      || bad "review: REVIEW_RESULT PASS + exit 3 should return 0 (got $rc)" )

  # (b) honest FAIL/BLOCK + exit 1 -> a gate failure (rc=1), not transient.
  ( mk_stub "$D/bin-b" "VERIFY_RUNTIME: FAIL surface produced wrong value" 1
    _verify_runtime_one_gated docs/tdd/0001-alpha.md "$BUILD_START" "$D/vb.log"; rc=$?
    [ "$rc" = "1" ] && ok "verify: honest FAIL + exit 1 returns gate-fail (rc=1)" \
      || bad "verify: FAIL verdict + exit 1 should return 1 (got $rc)" )
  ( mk_stub "$D/bin-br" "REVIEW_RESULT: BLOCK found a real bug" 1
    _review_one_gated docs/tdd/0001-alpha.md "$BUILD_START" "$D/rb.log"; rc=$?
    [ "$rc" = "1" ] && ok "review: honest BLOCK + exit 1 returns gate-fail (rc=1)" \
      || bad "review: BLOCK verdict + exit 1 should return 1 (got $rc)" )

  # (c) no verdict + non-zero exit -> classify by the child's rc (preserved).
  ( mk_stub "$D/bin-c" "I emit no verdict line at all." 3
    _verify_runtime_one_gated docs/tdd/0001-alpha.md "$BUILD_START" "$D/vc.log"; rc=$?
    [ "$rc" = "3" ] && ok "verify: verdict-less non-zero exit preserves the child rc (3)" \
      || bad "verify: no verdict + exit 3 should return 3 for rc-classification (got $rc)" )
) || true

# --- [VP8] verdict-less clean exit resolves to FAIL (gap 4 / NFR-4) ---------
# A child that exits 0 but emits no verdict line must NOT be a false PASS: the
# gate wrapper returns 1.
echo "[VP8] verdict-less clean exit (rc=0) resolves to FAIL, never a false PASS"
( D="$ROOT/vp8"; setup_repo "$D"
  verify_tmpl "$D/verify.md"; review_tmpl "$D/review.md"
  export MODEL=stub-model REVIEW_MODEL=stub-model RVMTPL="$D/verify.md" RTMPL="$D/review.md"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  ( mk_stub "$D/bin-v" "uncertain; no verdict line" 0
    _verify_runtime_one_gated docs/tdd/0001-alpha.md "$BUILD_START" "$D/v.log"; rc=$?
    [ "$rc" = "1" ] && ok "verify: clean exit + no verdict returns FAIL (rc=1)" \
      || bad "verify: rc=0 + no verdict should return 1 (got $rc)" )
  ( mk_stub "$D/bin-r" "uncertain; no verdict line" 0
    _review_one_gated docs/tdd/0001-alpha.md "$BUILD_START" "$D/r.log"; rc=$?
    [ "$rc" = "1" ] && ok "review: clean exit + no verdict returns FAIL (rc=1)" \
      || bad "review: rc=0 + no verdict should return 1 (got $rc)" )
) || true

# --- [VP3] stale build worktree reclaimed at launch (gap 2) ----------------
# A worktree left registered by an unclean exit (kill -9 skips the EXIT trap)
# must be reclaimed before `git worktree add`, so the next /implement proceeds
# without manual cleanup (FR-43). Build branches live in refs, not the worktree,
# so removing a stale worktree never discards committed work.
echo "[VP3] _reclaim_stale_worktree clears a stale worktree so a fresh add succeeds"
( D="$ROOT/vp3"; mkdir -p "$D"
  setup_repo "$D"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  REPORT="$D/report.md"; : > "$REPORT"

  # (a) a genuinely-registered stale worktree.
  WT="$D/stale-wt"
  git worktree add --detach "$WT" HEAD >/dev/null 2>&1
  [ -d "$WT" ] && ok "stale worktree set up (registered)" || bad "could not set up the stale worktree"
  _reclaim_stale_worktree "$WT" "$REPORT"
  grep -q "Reclaiming stale build worktree" "$REPORT" \
    && ok "reclaim logs the 'Reclaiming stale build worktree' line" \
    || bad "report should carry the reclaim line"
  if git worktree add --detach "$WT" HEAD >>"$REPORT" 2>&1; then
    ok "fresh git worktree add succeeds after reclaim (no FATAL)"
  else
    bad "fresh git worktree add should succeed after reclaim"
  fi
  git worktree remove --force "$WT" >/dev/null 2>&1 || true

  # (b) path exists but is NOT a git worktree (random dir) — rm -rf fallback.
  WT2="$D/not-a-wt"; mkdir -p "$WT2"; echo junk > "$WT2/file"
  _reclaim_stale_worktree "$WT2" "$REPORT"
  [ ! -d "$WT2" ] && ok "non-worktree dir cleared via the rm -rf fallback" \
    || bad "non-worktree dir at the path should be cleared"
) || true

# --- [VP4-setter] _update_branch_head_at_pause mutates only that field ------
echo "[VP4-setter] _update_branch_head_at_pause rewrites only branch_head_at_pause"
( D="$ROOT/vp4s"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE=sequential
  export INTEGRATION=master CHANGE=ci LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 paused review \
    1000 1100 "build/x" "" "log.txt" "transient" \
    "transient" "build,verify" "[]" "oldsha111"
  F="$D/state.d/0001-alpha.json"
  _update_branch_head_at_pause 0001-alpha newsha222
  [ "$(_read_fragment_field "$F" branch_head_at_pause)" = "newsha222" ] \
    && ok "setter updates branch_head_at_pause" || bad "setter should update branch_head_at_pause"
  [ "$(_read_fragment_field "$F" paused_cause)" = "transient" ] \
    && ok "setter preserves paused_cause" || bad "setter should preserve paused_cause"
  grep -q '"gates_completed":\["build","verify"\]' "$F" \
    && ok "setter preserves gates_completed" || bad "setter should preserve gates_completed"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "paused" ] \
    && ok "setter preserves status" || bad "setter should preserve status=paused"
) || true

# --- [VP4] fast-forward-advanced branch resumes (gap 3b) -------------------
# When the branch ref advanced past the recorded SHA (commits added, none
# rewritten — e.g. killed after committing but before updating the fragment),
# resume accepts it as continuation and advances branch_head_at_pause.
echo "[VP4] fast-forward-advanced branch resumes; branch_head_at_pause updated"
( D="$ROOT/vp4"; mkdir -p "$D/state.d"
  setup_repo "$D"
  git checkout -q -b build/x
  git commit -q --allow-empty -m c1; C1="$(git rev-parse HEAD)"
  git commit -q --allow-empty -m c2; C2="$(git rev-parse HEAD)"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE=sequential
  export INTEGRATION=master CHANGE=ci LOGDIR="$D" RESUME=1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 paused review \
    1000 1100 "build/x" "" "log.txt" "transient" \
    "transient" "build,test-first,verify" "[]" "$C1"
  F="$D/state.d/0001-alpha.json"
  RESUME_REFUSE_CAUSE=""
  _resume_from 0001-alpha; rc=$?
  [ "$rc" = "0" ] && ok "fast-forward resume accepted (rc=0)" || bad "ff resume should return 0 (got $rc)"
  [ -z "${RESUME_REFUSE_CAUSE:-}" ] && ok "no divergence refusal on fast-forward" \
    || bad "ff resume should not set a refuse cause (got '${RESUME_REFUSE_CAUSE:-}')"
  [ "$(_read_fragment_field "$F" branch_head_at_pause)" = "$C2" ] \
    && ok "branch_head_at_pause advanced to the current head" \
    || bad "branch_head_at_pause should be $C2 (got '$(_read_fragment_field "$F" branch_head_at_pause)')"
  var="$(_resume_gates_var 0001-alpha)"
  [ -n "${!var:-}" ] && ok "RESUME_GATES_DONE var set (resume proceeds to the gates list)" \
    || bad "gates-done var should be set after acceptance"
) || true

# --- [VP5] true rewrite still refused (gap 3b negative) --------------------
# The recorded SHA is NOT an ancestor of the current head (branch hard-reset to a
# sibling): a genuine rewrite, refused exactly as today.
echo "[VP5] non-ancestor head (true rewrite) is still refused"
( D="$ROOT/vp5"; mkdir -p "$D/state.d"
  setup_repo "$D"
  git checkout -q -b build/x
  git commit -q --allow-empty -m c1; C1="$(git rev-parse HEAD)"
  git reset --hard HEAD~1 >/dev/null 2>&1     # back to C0
  git commit -q --allow-empty -m sibling       # divergent commit; C1 is NOT an ancestor
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE=sequential
  export INTEGRATION=master CHANGE=ci LOGDIR="$D" RESUME=1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 paused review \
    1000 1100 "build/x" "" "log.txt" "transient" \
    "transient" "build" "[]" "$C1"
  F="$D/state.d/0001-alpha.json"
  RESUME_REFUSE_CAUSE=""
  _resume_from 0001-alpha; rc=$?
  [ "$rc" = "3" ] && ok "true rewrite refused (rc=3)" || bad "rewrite resume should return 3 (got $rc)"
  [ "${RESUME_REFUSE_CAUSE:-}" = "resume-blocked-branch-divergence" ] \
    && ok "refuse cause is resume-blocked-branch-divergence" \
    || bad "rewrite should set resume-blocked-branch-divergence (got '${RESUME_REFUSE_CAUSE:-}')"
  [ "$(_read_fragment_field "$F" branch_head_at_pause)" = "$C1" ] \
    && ok "branch_head_at_pause left unchanged on refusal" \
    || bad "branch_head_at_pause should remain $C1 on refusal"
) || true

# Write a blocked fragment: <statedir> <slug> <n> <halt_cause> <halt_actions_csv>.
# Helper that wraps _write_tdd_fragment with a blocked status + halt metadata.
write_blocked() {  # <slug> <n> <halt_cause> <halt_actions_csv>
  #          paused_cause↓ gates_csv↓                retries↓ branch_head↓
  _write_tdd_fragment "$1" "$2" "docs/tdd/$1.md" "$2" blocked review \
    1000 1100 "build/$1" "" "log.txt" "" \
    "" "build,test-first,verify" "" "" \
    "$3" "review:$2" "$4" "halt detail for $1"
}

# --- [VP6a] resumable blocked surfaced by --check-paused; non-resumable not -
# A blocked fragment whose halt_next_actions begins with a resume action
# (rework-scope-exceeded) is surfaced with the resumable=blocked marker; a
# design-escalation-only blocked fragment (structural-finding) is not.
echo "[VP6a] --check-paused surfaces a resumable blocked fragment with the marker"
( D="$ROOT/vp6a"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE=sequential
  export INTEGRATION=master CHANGE=ci LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  write_blocked 0001-alpha 1 rework-scope-exceeded \
    "resume (retries with stricter scope),revise TDD bounds via /tdd-author"
  write_blocked 0002-beta 2 structural-finding \
    "revise TDD via /tdd-author,see docs/tdd/BLOCKERS.md"
  out="$(bash "$STATUS" --logdir "$D" --check-paused 2>&1)"
  printf '%s\n' "$out" | grep -qE 'slug=0001-alpha .*resumable=blocked' \
    && ok "resumable blocked fragment surfaced with resumable=blocked marker" \
    || bad "0001-alpha should be surfaced with resumable=blocked (got: $out)"
  printf '%s\n' "$out" | grep -qE 'slug=0001-alpha .*cause=rework-scope-exceeded' \
    && ok "blocked line reports the halt_cause" \
    || bad "blocked line should carry cause=rework-scope-exceeded (got: $out)"
  printf '%s\n' "$out" | grep -q '0002-beta' \
    && bad "non-resumable blocked (0002-beta) must NOT be surfaced" \
    || ok "non-resumable blocked fragment not surfaced"
) || true

# --- [VP6b] resume accepts a resumable blocked fragment; refuses non-resumable
echo "[VP6b] resume validation flips a resumable blocked fragment to paused"
( D="$ROOT/vp6b"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE=sequential
  export INTEGRATION=master CHANGE=ci LOGDIR="$D" RESUME=1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  write_blocked 0001-alpha 1 rework-scope-exceeded \
    "resume (retries with stricter scope),revise TDD bounds via /tdd-author"
  write_blocked 0002-beta 2 structural-finding \
    "revise TDD via /tdd-author,see docs/tdd/BLOCKERS.md"
  FA="$D/state.d/0001-alpha.json"; FB="$D/state.d/0002-beta.json"

  _resume_from 0001-alpha; rc=$?
  [ "$rc" = "0" ] && ok "resumable blocked fragment accepted (rc=0)" || bad "should accept resumable blocked (got $rc)"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$FA" | head -1)" = "paused" ] \
    && ok "blocked fragment flipped to paused on acceptance" \
    || bad "0001-alpha should be flipped to paused"
  [ "$(_read_fragment_field "$FA" paused_cause)" = "transient" ] \
    && ok "paused_cause set to transient on acceptance" \
    || bad "paused_cause should be transient (got '$(_read_fragment_field "$FA" paused_cause)')"
  vA="$(_resume_gates_var 0001-alpha)"
  [ -n "${!vA:-}" ] && ok "RESUME_GATES_DONE var set (resume proceeds)" || bad "gates-done var should be set"

  _resume_from 0002-beta; rcb=$?
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$FB" | head -1)" = "blocked" ] \
    && ok "non-resumable blocked fragment left blocked (not accepted)" \
    || bad "0002-beta should stay blocked"
  vB="$(_resume_gates_var 0002-beta)"
  [ -z "${!vB:-}" ] && ok "non-resumable blocked: no gates-done var set" || bad "0002-beta should not set a gates-done var"
) || true

# --- [VP6c] resume refuses (no false success) when the flip write fails -----
# If the blocked->paused/transient flip cannot be written, resume must REFUSE
# (rc=3) rather than fall through and treat a half-written fragment as a valid
# resume (silent-success assumption). set_tdd_state is stubbed to simulate the
# write failure deterministically.
echo "[VP6c] resume refuses when the blocked->paused flip write fails"
( D="$ROOT/vp6c"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE=sequential
  export INTEGRATION=master CHANGE=ci LOGDIR="$D" RESUME=1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  write_blocked 0001-alpha 1 rework-scope-exceeded \
    "resume (retries with stricter scope),revise TDD bounds via /tdd-author"
  F="$D/state.d/0001-alpha.json"
  _write_tdd_fragment() { return 1; }   # simulate a fragment-write failure at the flip
  RESUME_REFUSE_CAUSE=""
  _resume_from 0001-alpha; rc=$?
  [ "$rc" = "3" ] && ok "flip-write failure refuses the resume (rc=3)" \
    || bad "should refuse on flip-write failure (got $rc)"
  [ "$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "blocked" ] \
    && ok "fragment left blocked (no half-written paused state on disk)" \
    || bad "fragment should remain blocked on refusal"
  [ -n "${RESUME_REFUSE_CAUSE:-}" ] && ok "refuse cause exposed for the report" \
    || bad "RESUME_REFUSE_CAUSE should be set on refusal"
  vC="$(_resume_gates_var 0001-alpha)"
  [ -z "${!vC:-}" ] && ok "no gates-done var set on refusal" || bad "no gates-done var should be set on refusal"
) || true

# --- [VP6d] the blocked->paused flip is atomic (no half-written window) ------
# A non-atomic flip (set status, then set cause) has a window where the status
# write lands but the cause write fails, leaving status=paused with a null
# paused_cause — indistinguishable from a normal paused fragment, which the NEXT
# resume invocation silently accepts. The flip must be a SINGLE write so the
# fragment is EITHER still blocked OR fully paused+transient, never a mix.
echo "[VP6d] a failed flip never leaves status=paused with a null cause"
( D="$ROOT/vp6d"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE=sequential
  export INTEGRATION=master CHANGE=ci LOGDIR="$D" RESUME=1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  write_blocked 0001-alpha 1 rework-scope-exceeded \
    "resume (retries with stricter scope),revise TDD bounds via /tdd-author"
  F="$D/state.d/0001-alpha.json"
  # Make the SECOND write of a two-step flip fail (the cause write). An atomic
  # single-write flip never reaches a second write, so this leaves no half-state.
  _update_paused_cause() { return 1; }
  _resume_from 0001-alpha >/dev/null 2>&1 || true
  st="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$F" | head -1)"
  if grep -q '"paused_cause":null' "$F" 2>/dev/null; then ca=""
  else ca="$(sed -n 's/.*"paused_cause":"\([^"]*\)".*/\1/p' "$F" | head -1)"; fi
  if [ "$st" = "paused" ] && [ -z "$ca" ]; then
    bad "atomicity violated: status=paused with null paused_cause after a failed flip"
  else
    ok "no half-written paused/null-cause fragment after a failed flip (st=$st cause=${ca:-null})"
  fi
  # And a second invocation must not silently accept a partially-flipped fragment.
  RESUME_REFUSE_CAUSE=""
  _resume_from 0001-alpha >/dev/null 2>&1; rc2=$?
  if [ "$st" = "paused" ] && [ -z "$ca" ] && [ "$rc2" = "0" ]; then
    bad "second invocation silently accepted a half-written fragment as a valid resume"
  else
    ok "second invocation does not silently accept a half-written fragment"
  fi
) || true

# --- report ----------------------------------------------------------------
n_ok=$(grep -c '^ok$' "$RESULTS" 2>/dev/null); n_ok=${n_ok:-0}
n_fail=$(grep -c '^fail$' "$RESULTS" 2>/dev/null); n_fail=${n_fail:-0}
rm -f "$RESULTS"
echo
printf 'runner-resilience: %s passed, %s failed\n' "$n_ok" "$n_fail"
[ "$n_fail" -eq 0 ]

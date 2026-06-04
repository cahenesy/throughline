#!/usr/bin/env bash
# structural-classification-bound.test.sh — eval for the bounded structural
# classification (TDD 0034 / FR-67 gap-closure, FR-62, FR-66; ADR 0005, 0006,
# 0007).
#
# The contract under test:
#   - scripts/review-prompt.md carries the `structural_reason:` schema field and
#     the tightened `structural: true` definition (a mechanical relocation /
#     reorder within bounds is NOT structural).
#   - the runner escalates a `structural: true` finding to a `structural-finding`
#     halt (criterion (c) + a BLOCKERS.md entry) ONLY when the reviewer supplied
#     a non-empty, non-`none` `structural_reason`; a `structural: true` finding
#     with no named reason falls through to the existing bounded-rework path
#     (FR-62), where the FR-67(a)/(b) pre-pass remains the real guardrail
#     (an in-scope fix ships; an out-of-scope one is still caught as
#     structural-(a)).
#
# Observable surface (per the TDD's Verification plan): the prompt text, and the
# runner's classification decision — observable as whether `_rework_loop`
# escalates (`halt_cause=structural-finding` + a docs/tdd/BLOCKERS.md entry) or
# routes to a bounded-rework attempt (a `rework_log` entry in the fragment).
#
# Run: bash tests/structural-classification-bound.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# --- §1 / Component 1: prompt text present ------------------------------------
echo "[P1] review-prompt.md carries the structural_reason field + tightened definition"
( cd "$REPO"
  F="scripts/review-prompt.md"
  [ -f "$F" ] && ok "scripts/review-prompt.md exists" || { bad "scripts/review-prompt.md should exist"; exit 0; }
  # The schema field is a single token; grep the raw file.
  grep -q 'structural_reason:' "$F" \
    && ok "carries the structural_reason: schema field" \
    || bad "review-prompt.md should add the structural_reason: schema field"
  # The multi-word phrases may wrap across lines in the prose; flatten newlines
  # to a single space before matching so wrapping never hides a present phrase.
  flat="$(tr '\n' ' ' < "$F")"
  printf '%s' "$flat" | grep -q 'requires reconsidering the design' \
    && ok "tightened definition says 'requires reconsidering the design'" \
    || bad "review-prompt.md should define structural:true as requiring reconsidering the design"
  printf '%s' "$flat" | grep -qE 'relocation' \
    && printf '%s' "$flat" | grep -qE 'NOT structural' \
    && ok "instructs that a mechanical relocation/reorder within bounds is NOT structural" \
    || bad "review-prompt.md should instruct that a bounded mechanical relocation/reorder is NOT structural"
) || true

# --- §2-§5 / Component 2: runner classification routing ----------------------
# scb_setup_repo: git repo + scope-declaring TDD + a state fragment + a stub
# `claude` that acts as the review gate (cats $CTL/review.out) and the rework
# model (runs $CTL/do_rework). Gates 1-3 are marked done via RESUME_GATES_DONE_*
# so gate_one runs ONLY the review gate and its bounded rework loop. Mirrors the
# fixture pattern of tests/bounded-rework-loop.test.sh::setup_loop_repo, but the
# review.out emits a primary FINDING_BEGIN..FINDING_END block (the only schema
# that can carry structural_reason), not the legacy single-line REVIEW_FINDING.
# Leaves PWD in the repo.
scb_setup_repo() {  # <dir>  (caller exports STATE_DIR etc. + sources $IMPL first)
  local d="$1"; mkdir -p "$d/ctl" "$d/bin"
  cd "$d" || return 1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
  # ctl/ + bin/ are test scaffolding, not part of the build — keep them out of
  # git so a rework's `git add -A` never sweeps them into the commit (which
  # would falsely trip the FR-67(a) out-of-set check).
  printf 'ctl/\nbin/\n' > .gitignore
  printf 'orig\n' > src/a.txt
  cat > docs/tdd/0099-fix.md <<'EOF'
# TDD 0099: fixture
Status: draft
PRD refs: 1

## Touched files
- `src/a.txt` — the in-scope file

## Expected diff size
- `src/a.txt` — ~50 lines added
EOF
  git add -A; git commit -qm "build start" >/dev/null
  cat > "$d/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
if printf '%s' "\$prompt" | grep -q 'BOUNDED rework pass'; then
  bash "$d/ctl/do_rework"; exit 0
fi
if printf '%s' "\$prompt" | grep -q 'INDEPENDENT review gate'; then
  cat "$d/ctl/review.out" 2>/dev/null || echo "REVIEW_RESULT: PASS"; exit 0
fi
echo "BATCH_RESULT: OK"; exit 0
EOF
  chmod +x "$d/bin/claude"
  export PATH="$d/bin:$PATH"
  export RTMPL="$REPO/scripts/review-prompt.md" RWTMPL="$REPO/scripts/rework-prompt.md"
  export REVIEW_MODEL="" REBUILD=0 BASE=master
  export THROUGHLINE_GATE_RETRIES=1 THROUGHLINE_GATE_BACKOFF_BASE=0
  export THROUGHLINE_REQUIRE_TEST_FIRST=0 THROUGHLINE_REQUIRE_RUNTIME_VERIFY=0
  # Skip gates 1-3 — only the review gate (and its rework loop) runs.
  RESUME_GATES_DONE_0099_fix="build,test-first,verify,verify-runtime"
  export RESUME_GATES_DONE_0099_fix
  _write_tdd_fragment 0099-fix 99 docs/tdd/0099-fix.md 1 reviewing review \
    1000 1000 "feat/0099-fix" "" "log" "" "" "build,test-first,verify,verify-runtime" "" "" "" "" "" "" ""
}

# scb_build_output: commit some build output PAST the build-start base so the
# consolidated review scope BS..HEAD is non-empty — what a real build always
# produces (TDD 0031 §2's empty-scope guard fails closed on a HEAD..HEAD scope).
scb_build_output() {
  printf 'build-output\n' >> src/a.txt
  git add -A; git commit -qm "build: simulated output past build-start" >/dev/null
}

echo "[S2] in-scope structural:true + structural_reason:none → routes to bounded rework (FR-62), not (c)-escalation"
( D="$ROOT/S2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  scb_setup_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"; scb_build_output
  cat > "$D/repo/ctl/review.out" <<'EOF'
FINDING_BEGIN
severity: major
structural: true
structural_reason: none
region: src/a.txt:1-1
region_lines: 8
pattern_tags: [in-scope-relocation]
summary: relocate the block within src/a.txt
evidence: src/a.txt:1 block out of place
FINDING_END
REVIEW_RESULT: BLOCK in-scope relocation
EOF
  # rework: small in-scope fix that converges; re-review then PASSes with a
  # per-file disposition for the reworked file (TDD 0021 §3b/§3c).
  cat > "$D/repo/ctl/do_rework" <<EOF
printf 'fixed\n' > src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: relocate block in src/a.txt" >/dev/null 2>&1
printf 'FILE_REVIEWED_NO_FINDINGS: src/a.txt\nREVIEW_RESULT: PASS\n' > "$D/repo/ctl/review.out"
EOF
  : > "$D/s2.log"
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/s2.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -eq 0 ] && ok "gate_one converges (no-reason structural reworked + flipped)" || bad "no-reason structural should rework + converge (rc=$rc, st=$st)"
  grep -q '"outcome":"shipped"' "$F" 2>/dev/null && ok "rework_log records a shipped attempt" || bad "rework_log should record shipped (got: $(_read_fragment_raw_array "$F" rework_log))"
  ! grep -q '"halt_cause":"structural-finding"' "$F" 2>/dev/null && ok "did NOT escalate structural-finding(c)" || bad "no-reason structural must not escalate (c)"
) || true

echo "[S3] in-scope structural:true + a named structural_reason → (c) escalation (halt + BLOCKERS)"
( D="$ROOT/S3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  scb_setup_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"; scb_build_output
  cat > "$D/repo/ctl/review.out" <<'EOF'
FINDING_BEGIN
severity: major
structural: true
structural_reason: the gate's interface contract must change
region: src/a.txt:1-1
region_lines: 8
pattern_tags: [design-change]
summary: the gate interface contract must change
evidence: src/a.txt:1 contract mismatch
FINDING_END
REVIEW_RESULT: BLOCK structural
EOF
  printf 'echo "do_rework should NOT run" >&2; exit 9\n' > "$D/repo/ctl/do_rework"
  : > "$D/s3.log"
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/s3.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -ne 0 ] && ok "gate_one blocks (named-reason structural)" || bad "named-reason structural should block (rc=$rc)"
  ! grep -q '"outcome"' "$F" 2>/dev/null && ok "no rework_log entry (rework skipped)" || bad "named-reason structural must not run a rework"
  grep -q '"halt_cause":"structural-finding"' "$F" 2>/dev/null && ok "halt_cause=structural-finding" || bad "halt_cause should be structural-finding"
  grep -qE '\(c\)' "$D/repo/docs/tdd/BLOCKERS.md" 2>/dev/null && ok "BLOCKERS.md names criterion (c)" || bad "BLOCKERS.md should name criterion (c) (got: $(cat "$D/repo/docs/tdd/BLOCKERS.md" 2>/dev/null))"
) || true

echo "[S4] out-of-scope rework + no reason → still caught as structural-(a) by the pre-pass"
( D="$ROOT/S4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  scb_setup_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"; scb_build_output
  cat > "$D/repo/ctl/review.out" <<'EOF'
FINDING_BEGIN
severity: major
structural: true
structural_reason: none
region: src/a.txt:1-1
region_lines: 8
pattern_tags: [in-scope-relocation]
summary: relocate the block within src/a.txt
evidence: src/a.txt:1 block out of place
FINDING_END
REVIEW_RESULT: BLOCK in-scope relocation
EOF
  # The no-reason finding routes to rework, but the rework edits an out-of-set
  # file → the FR-67(a) pre-pass must still escalate structural-(a). The no-reason
  # path did NOT make an out-of-scope change shippable.
  cat > "$D/repo/ctl/do_rework" <<'EOF'
printf 'x\n' > src/out_of_scope.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: edits out-of-set file" >/dev/null 2>&1
EOF
  : > "$D/s4.log"
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/s4.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -ne 0 ] && ok "gate_one blocks (out-of-set rework)" || bad "out-of-set rework should block (rc=$rc, st=$st)"
  grep -q '"outcome":"rejected:structural-finding"' "$F" 2>/dev/null && ok "rework_log records rejected:structural-finding" || bad "should record rejected:structural-finding (got: $(_read_fragment_raw_array "$F" rework_log))"
  grep -q '"halt_cause":"structural-finding"' "$F" 2>/dev/null && ok "halt_cause=structural-finding" || bad "halt_cause should be structural-finding"
  grep -qE '\(a\)' "$D/repo/docs/tdd/BLOCKERS.md" 2>/dev/null && ok "BLOCKERS.md names criterion (a)" || bad "BLOCKERS.md should name criterion (a) (got: $(cat "$D/repo/docs/tdd/BLOCKERS.md" 2>/dev/null))"
) || true

echo "[S5] structural:true with the structural_reason field absent entirely → routes to rework (safe default)"
( D="$ROOT/S5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" MAINREPO="$D/repo"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  scb_setup_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"; scb_build_output
  # No `structural_reason:` line at all (older prompt / malformed finding) →
  # RWK_STRUCTURAL_REASON is empty → no named reason → routes to rework (§Failure
  # modes "missing field entirely", the safe non-escalating direction).
  cat > "$D/repo/ctl/review.out" <<'EOF'
FINDING_BEGIN
severity: major
structural: true
region: src/a.txt:1-1
region_lines: 8
pattern_tags: [in-scope-relocation]
summary: relocate the block within src/a.txt
evidence: src/a.txt:1 block out of place
FINDING_END
REVIEW_RESULT: BLOCK in-scope relocation
EOF
  cat > "$D/repo/ctl/do_rework" <<EOF
printf 'fixed\n' > src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: relocate block in src/a.txt" >/dev/null 2>&1
printf 'FILE_REVIEWED_NO_FINDINGS: src/a.txt\nREVIEW_RESULT: PASS\n' > "$D/repo/ctl/review.out"
EOF
  : > "$D/s5.log"
  st="$(gate_one docs/tdd/0099-fix.md "$BS" "$D/s5.log")"; rc=$?
  F="$STATE_DIR/0099-fix.json"
  [ "$rc" -eq 0 ] && ok "gate_one converges (absent-field structural reworked + flipped)" || bad "absent-field structural should rework + converge (rc=$rc, st=$st)"
  grep -q '"outcome":"shipped"' "$F" 2>/dev/null && ok "rework_log records a shipped attempt" || bad "rework_log should record shipped (got: $(_read_fragment_raw_array "$F" rework_log))"
  ! grep -q '"halt_cause":"structural-finding"' "$F" 2>/dev/null && ok "did NOT escalate structural-finding(c)" || bad "absent-field structural must not escalate (c)"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== structural-classification-bound eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

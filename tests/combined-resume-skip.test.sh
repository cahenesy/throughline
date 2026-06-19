#!/usr/bin/env bash
# combined-resume-skip.test.sh — eval for TDD 0059 (issue #165 / FR-18, FR-40, NFR-4).
#
# A `--combined` run that halts on a downstream TDD (position > 1) must be cleanly
# resumable: the resume re-processes the queue from the first TDD, but an
# already-`implemented` TDD on the shared combined branch must be SKIPPED (not
# re-flipped → empty-commit `FAIL flip` → BLOCKED cascade). Two interacting fixes
# close this: (1) a per-TDD skip in the combined driver loop, and (2) an
# idempotent `flip_status`. Both delegate to a single-sourced predicate
# `_tdd_implemented_at`.
#
#   §1 _tdd_implemented_at predicate (the single-sourced Status:implemented check)
#   §2 flip_status idempotency + honesty (already-implemented no-op vs real failure)
#   §3 combined-resume regression (drives the real combined driver end-to-end)
#   §4 single-source: exactly one Status:implemented predicate across the libs
#   §W dogfood: registering this eval makes the aggregator exit non-zero on failure
#
# Run: bash tests/combined-resume-skip.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# --- [§1] _tdd_implemented_at predicate ---------------------------------------
# The single home for the `^Status:[[:space:]]*implemented` check. Returns 0 iff
# the TDD at <ref> carries a Status: implemented line; non-zero otherwise,
# including when the ref or path is absent (git show fails → grep sees nothing).
echo "[§1] _tdd_implemented_at predicate"
( D="$ROOT/s1"; mkdir -p "$D"; cd "$D" || { bad "§1 cd failed"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd
  printf '# TDD 0001: a\nStatus: draft\n\n## Approach\nx\n' > docs/tdd/0001-a.md
  git add -A; git commit -qm init >/dev/null 2>&1
  git checkout -q -b built
  printf '# TDD 0001: a\nStatus: implemented\n\n## Approach\nx\n' > docs/tdd/0001-a.md
  git add -A; git commit -qm "mark 0001-a implemented" >/dev/null 2>&1
  git checkout -q master

  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "§1 could not source implement.sh"; exit 0; }
  if ! type -t _tdd_implemented_at >/dev/null; then
    bad "§1 _tdd_implemented_at is not defined after sourcing"; exit 0
  fi
  _tdd_implemented_at built docs/tdd/0001-a.md \
    && ok "implemented at <ref> → 0" \
    || bad "should return 0 for an implemented TDD at <ref>"
  _tdd_implemented_at master docs/tdd/0001-a.md \
    && bad "a draft TDD at <ref> must be non-zero" \
    || ok "draft at <ref> → non-zero"
  _tdd_implemented_at built docs/tdd/9999-missing.md \
    && bad "a missing path must be non-zero" \
    || ok "missing path → non-zero"
  _tdd_implemented_at no-such-ref docs/tdd/0001-a.md \
    && bad "a missing ref must be non-zero" \
    || ok "missing ref → non-zero"
) || true

# --- [§2] flip_status idempotency + honesty -----------------------------------
# A TDD already `implemented` at HEAD must flip as a no-op SUCCESS (return 0, no
# commit) — the empty-commit `FAIL flip` that issue #165 cascaded from. A genuine
# draft still flips and commits; a real commit failure on a genuine draft still
# returns non-zero (NFR-4: the guard precedes, never masks, the honest commit).
echo "[§2] flip_status idempotency + honesty"
( THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "§2 could not source implement.sh"; exit 0; }
  log="$ROOT/s2.log"; : > "$log"

  # (a) already implemented at HEAD → no-op success (return 0, no new commit)
  ( A="$ROOT/s2a"; mkdir -p "$A/docs/tdd"; cd "$A" || exit 0
    git init -q -b master; git config user.email t@t.t; git config user.name t
    printf '# TDD 0001: a\nStatus: implemented\n\n## Approach\nx\n' > docs/tdd/0001-a.md
    git add -A; git commit -qm init >/dev/null 2>&1
    before="$(git rev-list --count HEAD)"
    flip_status docs/tdd/0001-a.md "$log"; rc=$?
    after="$(git rev-list --count HEAD)"
    [ "$rc" -eq 0 ] && ok "(a) already-implemented flip returns 0" || bad "(a) already-implemented flip must return 0 (got rc=$rc)"
    [ "$before" = "$after" ] && ok "(a) no new commit on an already-implemented flip" || bad "(a) must add no commit (before=$before after=$after)"
  ) || true

  # (b) genuine draft → flips and commits (return 0, exactly one new commit)
  ( B="$ROOT/s2b"; mkdir -p "$B/docs/tdd"; cd "$B" || exit 0
    git init -q -b master; git config user.email t@t.t; git config user.name t
    printf '# TDD 0001: b\nStatus: draft\n\n## Approach\nx\n' > docs/tdd/0001-b.md
    git add -A; git commit -qm init >/dev/null 2>&1
    before="$(git rev-list --count HEAD)"
    flip_status docs/tdd/0001-b.md "$log"; rc=$?
    after="$(git rev-list --count HEAD)"
    [ "$rc" -eq 0 ] && ok "(b) genuine draft flip returns 0" || bad "(b) genuine draft flip must return 0 (got rc=$rc)"
    [ "$((after - before))" -eq 1 ] && ok "(b) exactly one new commit on a genuine flip" || bad "(b) must add exactly one commit (before=$before after=$after)"
    git show "HEAD:docs/tdd/0001-b.md" 2>/dev/null | grep -qE '^Status:[[:space:]]*implemented' \
      && ok "(b) HEAD now carries Status: implemented" || bad "(b) flipped TDD must be implemented at HEAD"
  ) || true

  # (c) genuine draft but git commit forced to fail → honest non-zero, no commit
  ( C="$ROOT/s2c"; mkdir -p "$C/docs/tdd"; cd "$C" || exit 0
    git init -q -b master; git config user.email t@t.t; git config user.name t
    printf '# TDD 0001: c\nStatus: draft\n\n## Approach\nx\n' > docs/tdd/0001-c.md
    git add -A; git commit -qm init >/dev/null 2>&1
    # reject every commit (issue #28B-style pre-commit hook), forcing git commit to fail
    printf '#!/usr/bin/env bash\nexit 1\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
    before="$(git rev-list --count HEAD)"
    flip_status docs/tdd/0001-c.md "$log"; rc=$?
    after="$(git rev-list --count HEAD)"
    [ "$rc" -ne 0 ] && ok "(c) a real commit failure still returns non-zero (NFR-4)" || bad "(c) guard must not mask a real commit failure (got rc=$rc)"
    [ "$before" = "$after" ] && ok "(c) no commit landed on a forced commit failure" || bad "(c) failed flip must not add a commit (before=$before after=$after)"
  ) || true
) || true

# --- [§3] combined-resume regression (drives the real combined driver) ---------
# Issue #165: a --combined run halted on a downstream TDD (position > 1) must
# resume cleanly. Fixture: A (0001-alpha) implemented + committed on the combined
# branch `ci`; B (0002-beta) paused at review (resumable) with B still draft on
# ci; C (0003-gamma) unbuilt. On `--combined --resume` the driver must SKIP A
# (already built — not re-flip → empty-commit FAIL flip → BLOCKED cascade), REACH
# B (re-run only its remaining gate), and NOT cascade-BLOCK B or C.
echo "[§3] combined-resume regression (real driver, end-to-end)"
( D="$ROOT/s3"; mkdir -p "$D/.stub/bin"; cd "$D" || { bad "§3 cd failed"; exit 0; }
  git init -q -b master >/dev/null; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd docs/adr
  printf '# PRD\n## Requirements\n1. x\n' > docs/PRD.md
  printf '# ADR Index\n' > docs/adr/INDEX.md
  for s in 0001-alpha 0002-beta 0003-gamma; do
    printf '# TDD %s\nStatus: draft\nPRD refs: 1\nPRD-rev: deadbee\nADR constraints: none\n\n## Approach\nstub\n' "$s" > "docs/tdd/$s.md"
  done
  git add -A; git commit -qm init >/dev/null

  # Combined branch `ci`: A flipped to implemented + committed; B, C left draft.
  git checkout -q -b ci
  sed -i -E 's/^Status:[[:space:]]*draft/Status: implemented/' docs/tdd/0001-alpha.md
  git add -A; git commit -qm "mark 0001-alpha implemented (verified + reviewed)" >/dev/null
  ci_head="$(git rev-parse refs/heads/ci)"
  git checkout -q master

  # stub ci-checks (tests pass; typecheck + lint skipped) + stub claude
  printf '#!/usr/bin/env bash\nexit 0\n' > "$D/.stub/verify_test.sh"
  export CI_CHECKS_TEST_CMD="bash $D/.stub/verify_test.sh" CI_CHECKS_TYPECHECK_CMD="" CI_CHECKS_LINT_CMD=""
  cat > "$D/.stub/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; *) shift;; esac; done
slug="$(printf '%s' "$prompt" | grep -oE 'docs/tdd/[0-9]+-[a-z]+' | head -1 | sed 's#docs/tdd/##')"
if printf '%s' "$prompt" | grep -q 'INDEPENDENT runtime-verification gate'; then
  echo "VERIFY_RUNTIME: PASS"; exit 0
fi
if printf '%s' "$prompt" | grep -q 'INDEPENDENT review gate'; then
  rbase="$(printf '%s' "$prompt" | grep -oE 'name-only[[:space:]]+[0-9a-f]{7,40}' | head -1 | grep -oE '[0-9a-f]{7,40}')"
  [ -n "$rbase" ] && git diff --name-only "$rbase"..HEAD 2>/dev/null | while IFS= read -r f; do
    [ -n "$f" ] && echo "FILE_REVIEWED_NO_FINDINGS: $f"
  done
  echo "REVIEW_RESULT: PASS"; exit 0
fi
echo "t $slug" >> "test-$slug.txt"; git add -A >/dev/null 2>&1; git commit -q -m "test(failing): $slug" >/dev/null 2>&1 || true
echo "g $(date +%s%N)" >> "gen-$slug.txt"; git add -A >/dev/null 2>&1; git commit -q -m "stub build $slug" >/dev/null 2>&1 || true
echo "BATCH_RESULT: OK"; exit 0
EOF
  chmod +x "$D/.stub/bin/claude"
  export PATH="$D/.stub/bin:$PATH"

  # Build the prior combined run's paused state (state.d + run.json + latest link)
  # via the real state helpers (source-only), so the JSON is parser-faithful.
  ts=20260101-000000
  LOGDIR_ABS="$D/docs/tdd/.implement-logs/$ts"; mkdir -p "$LOGDIR_ABS/state.d"
  ( THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || exit 1
    export STATE_DIR="$LOGDIR_ABS/state.d" STATE_STARTED_AT=1000 STATE_MODE=combined
    export INTEGRATION=master CHANGE=ci LOGDIR="$LOGDIR_ABS" MAINREPO="$D"
    TDDS=(docs/tdd/0001-alpha.md docs/tdd/0002-beta.md docs/tdd/0003-gamma.md)
    # A: already built (done) on ci, every gate complete.
    _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 done "" 1000 1000 ci "" log "" \
      "" "build,test-first,verify,verify-runtime,review" "" "$ci_head"
    # B: paused at review (resumable transient) — only the review gate remains.
    _write_tdd_fragment 0002-beta 2 docs/tdd/0002-beta.md 2 paused review 1000 1000 ci "" log "" \
      ratelimit "build,test-first,verify,verify-runtime" "" "$ci_head"
    # C: unbuilt.
    _write_tdd_fragment 0003-gamma 3 docs/tdd/0003-gamma.md 3 pending "" 1000 1000 "" "" log ""
    _write_run_fragment paused
  ) || { bad "§3 fixture-state build failed"; exit 0; }
  ln -sfn "$ts" "$D/docs/tdd/.implement-logs/latest"

  # Resume the combined run via the REAL driver (separate process; no source-only).
  THROUGHLINE_INTEGRATION_BRANCH=master bash "$IMPL" --combined --resume >/dev/null 2>&1
  R="$(ls -t "$D"/docs/tdd/.implement-logs/*/report.md 2>/dev/null | head -1)"
  st_of() { sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1; }
  sa="$(st_of "$LOGDIR_ABS/state.d/0001-alpha.json")"
  sb="$(st_of "$LOGDIR_ABS/state.d/0002-beta.json")"
  sc="$(st_of "$LOGDIR_ABS/state.d/0003-gamma.json")"

  grep -q "0001-alpha — already built on ci (combined batch); skipped" "$R" 2>/dev/null \
    && ok "A reports the combined-batch skip line (not FAIL flip / not OK re-report)" \
    || bad "A must report the combined-batch skip line (report: ${R:-none})"
  [ "$sa" = skipped ] && ok "A fragment status=skipped" || bad "A fragment must be skipped (got '$sa')"
  grep -q "0002-beta — BLOCKED (upstream" "$R" 2>/dev/null \
    && bad "B must NOT be cascade-BLOCKED by A's re-entry" || ok "B is not cascade-BLOCKED (the skip advanced the loop)"
  [ "$sb" = done ] && ok "B is reached and completes (status=done)" || bad "B should be reached + flipped (got '$sb')"
  grep -q "0003-gamma — BLOCKED (upstream" "$R" 2>/dev/null \
    && bad "C must NOT be cascade-BLOCKED" || ok "C is not cascade-BLOCKED (got status '$sc')"
  marks="$(git -C "$D" log --format='%s' refs/heads/ci 2>/dev/null | grep -c 'mark 0001-alpha implemented')"
  [ "$marks" = 1 ] && ok "no duplicate 'mark 0001-alpha implemented' commit on ci" || bad "expected exactly one A-flip commit on ci (got $marks)"
) || true

# --- [§4] single-source Status:implemented predicate --------------------------
# Exactly one definition of the predicate; built_branch + combined_built_branch +
# flip_status + the combined-loop skip all delegate; no inline copy of the
# `git show … | grep … '^Status:…implemented'` check remains (L-003 drift class).
echo "[§4] single-source Status:implemented predicate"
( libs=("$REPO/scripts/lib/resume.sh" "$REPO/scripts/lib/gates.sh" "$REPO/scripts/implement.sh")
  inline="$(grep -rhF "grep -qE '^Status:[[:space:]]*implemented'" "${libs[@]}" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$inline" = "1" ] && ok "exactly one inline Status:implemented predicate across the libs" \
    || bad "expected exactly 1 inline predicate (the _tdd_implemented_at body), found $inline"
  defs="$(grep -rhE '^_tdd_implemented_at\(\)' "${libs[@]}" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$defs" = "1" ] && ok "_tdd_implemented_at defined exactly once" \
    || bad "expected exactly 1 _tdd_implemented_at definition, found $defs"
  calls="$(grep -rhE '_tdd_implemented_at (HEAD|"\$)' "${libs[@]}" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$calls" -ge 4 ] && ok "all four sites delegate to _tdd_implemented_at (call sites: $calls)" \
    || bad "expected >=4 delegating call sites (built_branch, combined_built_branch, flip_status, combined-loop skip), found $calls"
) || true

# --- [§W] dogfood (TDD 0038 §3 wire-in rule) ----------------------------------
# Registering this eval in the aggregator adds a CRS_FAIL accumulator to its final
# AND-chain, so the aggregator now exits non-zero on a new condition. Drive the
# REAL extracted chain with every accumulator green EXCEPT this eval's, stubbed to
# fail: before the wire-in the chain never references CRS_FAIL and evaluates true
# (RED); after, it includes the term and evaluates false (GREEN).
echo "[§W] dogfood: wiring this eval into the aggregator makes its exit go non-zero when the eval fails"
( AGG="$REPO/tests/implement-gate.test.sh"
  if [ ! -r "$AGG" ]; then bad "INFRA: §W — aggregator unreadable: $AGG"; exit 0; fi
  grep -q 'combined-resume-skip\.test\.sh' "$AGG" 2>/dev/null \
    && ok "the new eval is wired into the aggregator (registration present)" \
    || bad "the new eval must be registered in the aggregator"
  chain="$(grep -aE '^\[ "\$FAIL" -eq 0 \] &&' "$AGG" | tail -1)"
  if [ -z "$chain" ]; then bad "INFRA: §W — could not locate the aggregator final AND-chain"; exit 0; fi
  drive_rc="$(
    set +u
    for v in $(printf '%s' "$chain" | grep -aoE '\$[A-Za-z_][A-Za-z0-9_]*' | tr -d '$' | sort -u); do
      eval "$v=0"
    done
    CRS_FAIL=1
    eval "$chain"; echo $?
  )"
  [ "$drive_rc" != "0" ] \
    && ok "aggregator final AND-chain goes non-zero when the new eval fails (wire-in propagates)" \
    || bad "aggregator AND-chain must be non-zero with CRS_FAIL=1 (got rc=$drive_rc)"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== combined-resume-skip eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

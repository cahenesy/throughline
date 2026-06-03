#!/usr/bin/env bash
# step-commit-protocol.test.sh — eval for STEP_COMMIT protocol robustness
# (TDD 0032 / FR-51, FR-56, FR-42, FR-41, NFR-4).
#
# The contract under test, layer by layer:
#   1. tl_lint_sequencing (scripts/lib/tdd-lint.sh) rejects a
#      `## Sequencing / implementation plan` whose top-level labels are not
#      exactly 1..N sequential — fence-aware, section-scoped (Verification 1-3).
#   2. build-prompt.md carries the 1-based-ordinal fallback rule;
#      skills/implement/SKILL.md carries the protocol-correction sentence
#      (Verification 9).
#   3. _sequencing_labels_ok (scripts/lib/gates.sh) refuses to spawn the build
#      coprocess for a non-conforming TDD; the gate fails fatal (Verification 4).
#   4. The _per_step_review_loop read loop fails loud on a malformed STEP_COMMIT
#      sentinel, replies with a bounded protocol-correction BLOCK, and routes
#      exhaustion to the fatal pathway — never transient (Verification 5-8).
#
# Run: bash tests/step-commit-protocol.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
LINT="$REPO/scripts/lib/tdd-lint.sh"
# ok/bad run inside `( … )` subshells, so tally via a file (a parent-scope
# counter would never see the subshell increments — the same pattern
# continuous-in-build-review.test.sh uses).
RESULTS="$(mktemp)"
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$RESULTS"' EXIT

# mk_seq_tdd <file> <sequencing-body-heredoc-on-stdin> — write a minimal fixture
# TDD whose `## Sequencing / implementation plan` section is the stdin content.
mk_seq_tdd() {  # <file>  (body on stdin)
  local f="$1"
  { printf '# TDD fixture\nStatus: draft\nPRD refs: 1\n\n## Sequencing / implementation plan\n\n'
    cat
    printf '\n## Touched files\n- `src/a` — x\n'
  } > "$f"
}

# ============================================================================
# §1 / Verification 1 — Lint accepts 1..N (exit 0, no output).
# ============================================================================
echo "[L1] tl_lint_sequencing accepts labels 1..N"
(
  source "$LINT" || { bad "could not source tdd-lint.sh"; exit 0; }
  f="$ROOT/l1.md"
  mk_seq_tdd "$f" <<'EOF'
1. first
2. second
3. third
4. fourth
5. fifth
EOF
  out="$(tl_lint_sequencing "$f")"; rc=$?
  [ "$rc" -eq 0 ] && ok "1..5 sequential exits 0" || bad "1..5 should exit 0 (rc=$rc)"
  [ -z "$out" ] && ok "1..5 emits no finding" || bad "1..5 should emit nothing (got: $out)"
) || true

# ============================================================================
# §2 / Verification 2 — Lint rejects non-integer / non-sequential, one finding.
# ============================================================================
echo "[L2a] tl_lint_sequencing rejects a non-integer label (5b)"
(
  source "$LINT" || { bad "could not source tdd-lint.sh"; exit 0; }
  f="$ROOT/l2a.md"
  mk_seq_tdd "$f" <<'EOF'
1. one
2. two
3. three
4. four
5. five
5b. extra
6. six
EOF
  out="$(tl_lint_sequencing "$f")"; rc=$?
  [ "$rc" -eq 2 ] && ok "non-integer label exits 2 (blocker)" || bad "5b should exit 2 (rc=$rc)"
  printf '%s' "$out" | grep -q 'blocker sequencing.labels' && ok "emits blocker sequencing.labels" || bad "should emit blocker sequencing.labels (got: $out)"
  printf '%s' "$out" | grep -qi 'non-integer' && printf '%s' "$out" | grep -q "5b" \
    && ok "names the non-integer violation (5b)" || bad "finding should name 5b as non-integer (got: $out)"
  n="$(printf '%s\n' "$out" | grep -c 'sequencing.labels')"
  [ "$n" -eq 1 ] && ok "exactly one finding" || bad "should be exactly one finding (got $n: $out)"
) || true

echo "[L2b] tl_lint_sequencing rejects a gap (1,2,5)"
(
  source "$LINT" || { bad "could not source tdd-lint.sh"; exit 0; }
  f="$ROOT/l2b.md"
  mk_seq_tdd "$f" <<'EOF'
1. one
2. two
5. five
EOF
  out="$(tl_lint_sequencing "$f")"; rc=$?
  [ "$rc" -eq 2 ] && ok "gap exits 2" || bad "1,2,5 should exit 2 (rc=$rc)"
  printf '%s' "$out" | grep -qi 'sequential' && printf '%s' "$out" | grep -q '1,2,5' \
    && ok "names the non-sequential set (1,2,5)" || bad "finding should name found:1,2,5 (got: $out)"
  n="$(printf '%s\n' "$out" | grep -c 'sequencing.labels')"
  [ "$n" -eq 1 ] && ok "exactly one finding" || bad "should be exactly one finding (got $n: $out)"
) || true

echo "[L2c] tl_lint_sequencing rejects a duplicate (1,2,2)"
(
  source "$LINT" || { bad "could not source tdd-lint.sh"; exit 0; }
  f="$ROOT/l2c.md"
  mk_seq_tdd "$f" <<'EOF'
1. one
2. two
2. two-again
EOF
  out="$(tl_lint_sequencing "$f")"; rc=$?
  [ "$rc" -eq 2 ] && ok "duplicate exits 2" || bad "1,2,2 should exit 2 (rc=$rc)"
  printf '%s' "$out" | grep -q '1,2,2' && ok "names the duplicate set (1,2,2)" || bad "finding should name found:1,2,2 (got: $out)"
  n="$(printf '%s\n' "$out" | grep -c 'sequencing.labels')"
  [ "$n" -eq 1 ] && ok "exactly one finding" || bad "should be exactly one finding (got $n: $out)"
) || true

echo "[L2d] tl_lint_sequencing rejects a list not starting at 1 (2,3)"
(
  source "$LINT" || { bad "could not source tdd-lint.sh"; exit 0; }
  f="$ROOT/l2d.md"
  mk_seq_tdd "$f" <<'EOF'
2. two
3. three
EOF
  out="$(tl_lint_sequencing "$f")"; rc=$?
  [ "$rc" -eq 2 ] && ok "not-starting-at-1 exits 2" || bad "2,3 should exit 2 (rc=$rc)"
  printf '%s' "$out" | grep -q '2,3' && ok "names the offending set (2,3)" || bad "finding should name found:2,3 (got: $out)"
  n="$(printf '%s\n' "$out" | grep -c 'sequencing.labels')"
  [ "$n" -eq 1 ] && ok "exactly one finding" || bad "should be exactly one finding (got $n: $out)"
) || true

# ============================================================================
# §3 / Verification 3 — Lint ignores fenced labels and other sections.
# ============================================================================
echo "[L3] tl_lint_sequencing ignores fenced labels and Verification-plan labels"
(
  source "$LINT" || { bad "could not source tdd-lint.sh"; exit 0; }
  f="$ROOT/l3.md"
  # Build the fixture directly (the sequencing section embeds a ``` fence and a
  # following ## Verification plan with an 8b. label that must NOT be examined).
  cat > "$f" <<'EOF'
# TDD fixture
Status: draft
PRD refs: 1

## Sequencing / implementation plan

1. one
2. two

```
5b. this label is inside a fence and must be ignored
```

## Verification plan

8b. observation labels in other sections are not examined

## Touched files
- `src/a` — x
EOF
  out="$(tl_lint_sequencing "$f")"; rc=$?
  [ "$rc" -eq 0 ] && ok "fenced 5b + Verification 8b are ignored (exit 0)" || bad "should exit 0 (rc=$rc, out: $out)"
  [ -z "$out" ] && ok "no finding emitted" || bad "should emit nothing (got: $out)"
) || true

# ============================================================================
# §1b — No sequencing section / zero numbered items → no finding (graceful).
# ============================================================================
echo "[L4] tl_lint_sequencing emits no finding for a prose-only / absent plan"
(
  source "$LINT" || { bad "could not source tdd-lint.sh"; exit 0; }
  # Absent section.
  f1="$ROOT/l4a.md"
  printf '# TDD\nStatus: draft\nPRD refs: 1\n\n## Approach\n\nProse only.\n' > "$f1"
  out="$(tl_lint_sequencing "$f1")"; rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "absent sequencing section → clean" || bad "absent section should be clean (rc=$rc, out: $out)"
  # Section present but zero numbered items (prose plan).
  f2="$ROOT/l4b.md"
  mk_seq_tdd "$f2" <<'EOF'
First we add the lint, then wire it, then test it. No numbered list.
EOF
  out="$(tl_lint_sequencing "$f2")"; rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "zero-item plan → clean" || bad "zero-item plan should be clean (rc=$rc, out: $out)"
) || true

# ============================================================================
# §1c — tl_lint_all runs tl_lint_sequencing (wired into the aggregate).
# ============================================================================
echo "[L5] tl_lint_all surfaces a sequencing.labels blocker"
(
  source "$LINT" || { bad "could not source tdd-lint.sh"; exit 0; }
  # A structurally-complete TDD with a bad sequencing label: the only blocker
  # must be sequencing.labels, proving tl_lint_all invokes tl_lint_sequencing.
  f="$ROOT/l5.md"
  cat > "$f" <<'EOF'
# TDD
Status: draft
PRD refs: FR-1
PRD-rev: abc

## Approach

Body.

## Sequencing / implementation plan

1. one
3. three

## Verification plan

Observe it.

## Dependencies considered

None.

## Requirement traceability

| Requirement | Design element |
|---|---|
| FR-1 | the thing |
EOF
  out="$(tl_lint_all "$f")"; rc=$?
  [ "$rc" -eq 2 ] && ok "tl_lint_all exits 2 (blocker)" || bad "tl_lint_all should exit 2 (rc=$rc)"
  printf '%s' "$out" | grep -q 'sequencing.labels' && ok "tl_lint_all surfaces the sequencing.labels finding" || bad "tl_lint_all must run tl_lint_sequencing (got: $out)"
) || true

# ============================================================================
# §2 / Verification 9 — prompt text present (layers 2 + 5).
# ============================================================================
echo "[P1] build-prompt.md carries the 1-based-ordinal fallback rule (layer 2)"
(
  F="$REPO/scripts/build-prompt.md"
  grep -q '1-based ordinal' "$F" \
    && ok "build-prompt names the 1-based ordinal fallback" || bad "build-prompt.md must carry the literal '1-based ordinal' rule (Verification 9)"
  grep -q 'plain integer' "$F" \
    && ok "build-prompt requires a plain integer step-id" || bad "build-prompt.md must state <step-id> MUST be a plain integer"
  grep -q '5b' "$F" \
    && ok "build-prompt gives the 5b → ordinal example" || bad "build-prompt.md must show the non-integer-label example (5b)"
) || true

echo "[P2] skills/implement/SKILL.md carries the protocol-correction sentence (layer 5)"
(
  F="$REPO/skills/implement/SKILL.md"
  grep -qi 'malformed' "$F" && grep -q 'STEP_COMMIT' "$F" \
    && ok "SKILL.md describes the malformed-STEP_COMMIT handling" || bad "SKILL.md must describe the malformed STEP_COMMIT handling"
  grep -qiE 'protocol-correction|protocol correction' "$F" \
    && ok "SKILL.md names the bounded protocol-correction reply" || bad "SKILL.md must name the bounded protocol-correction BLOCK reply"
  grep -qiE 'never .*transient|not .*transient' "$F" \
    && ok "SKILL.md states exhaustion is never classified transient" || bad "SKILL.md must state exhaustion FAILs via the fatal pathway, never transient"
) || true

# ============================================================================
# §3 / Verification 4 — pre-flight refuses to spawn the build (layer 3).
# ============================================================================
# setup_preflight_repo <dir> <seq-body-on-stdin>: a git repo + a fixture TDD
# whose Sequencing body is stdin, a state fragment, and a stub `claude` that
# writes ctl/SPAWNED if it is ever invoked (proving the coprocess never spawns
# when the pre-flight refuses). Leaves PWD in the repo.
setup_preflight_repo() {  # <dir>  (sequencing body on stdin)
  local d="$1"; mkdir -p "$d/ctl" "$d/bin"
  cd "$d" || return 1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
  printf 'ctl/\nbin/\n' > .gitignore
  printf 'orig\n' > src/a.txt
  { printf '# TDD 0032: fixture\nStatus: draft\nPRD refs: 1\n\n## Sequencing / implementation plan\n\n'
    cat
    printf '\n## Touched files\n- `src/a.txt` — the in-scope file\n'
  } > docs/tdd/0032-fix.md
  git add -A; git commit -qm "build start" >/dev/null
  # Any invocation of claude marks ctl/SPAWNED. If the pre-flight refuses before
  # the coproc spawn, this file must never appear.
  cat > "$d/bin/claude" <<EOF
#!/usr/bin/env bash
touch "$d/ctl/SPAWNED"
echo "BATCH_RESULT: OK"
EOF
  chmod +x "$d/bin/claude"
  export PATH="$d/bin:$PATH"
  export TMPL="$REPO/scripts/build-prompt.md" RTMPL="$REPO/scripts/review-prompt.md"
  export MODEL="" REVIEW_MODEL="" MAINREPO="$d"
}

echo "[PF] _per_step_review_loop refuses to spawn the build for non-integer Sequencing labels"
( D="$ROOT/PF"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_preflight_repo "$D/repo" <<'EOF'
1. one
2. two
5b. the non-integer label that breaks the STEP_COMMIT parser
6. six
EOF
  _write_tdd_fragment 0032-fix 32 docs/tdd/0032-fix.md 1 building build 1000 1000 "feat/0032-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  _per_step_review_loop 0032-fix docs/tdd/0032-fix.md "$D/pf.log"; rc=$?
  [ ! -f "$D/repo/ctl/SPAWNED" ] && ok "build coprocess never spawned (zero tokens)" || bad "pre-flight must refuse BEFORE spawning claude"
  grep -q 'THROUGHLINE_PROTOCOL_PREFLIGHT' "$D/pf.log" 2>/dev/null \
    && ok "log records THROUGHLINE_PROTOCOL_PREFLIGHT" || bad "log should carry the pre-flight refusal marker (got: $(cat "$D/pf.log" 2>/dev/null))"
  [ "$rc" -ne 0 ] && ok "gate returns non-zero" || bad "pre-flight refusal should return non-zero (rc=$rc)"
  cause="$(_classify_cause "$D/pf.log" "$rc")"
  [ "$cause" = "fatal" ] && ok "_classify_cause routes the refusal to fatal (never transient)" || bad "refusal must classify fatal, got '$cause'"
  ! grep -q 'BATCH_RESULT' "$D/pf.log" 2>/dev/null && ok "no BATCH_RESULT fabricated" || bad "must not fabricate a BATCH_RESULT on refusal"
) || true

echo "[PF2] _sequencing_labels_ok passes a conforming 1..N plan (no false refusal)"
( D="$ROOT/PF2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_preflight_repo "$D/repo" <<'EOF'
1. one
2. two
3. three
EOF
  if _sequencing_labels_ok docs/tdd/0032-fix.md >/dev/null 2>&1; then
    ok "_sequencing_labels_ok returns 0 for a conforming plan"
  else
    bad "_sequencing_labels_ok should pass labels 1..3"
  fi
  # A prose-only / absent plan also passes (degrades to end-of-build review).
  printf '# TDD\nStatus: draft\n\n## Approach\n\nProse.\n' > docs/tdd/0032-prose.md
  if _sequencing_labels_ok docs/tdd/0032-prose.md >/dev/null 2>&1; then
    ok "_sequencing_labels_ok passes a prose-only plan"
  else
    bad "_sequencing_labels_ok should pass a prose-only plan"
  fi
) || true

# <<INSERT NEW SECTIONS ABOVE THIS LINE>>

# grep -c prints the count and exits 1 when zero — keep the count, drop the rc.
# Tallied LAST so every section above has appended its results first.
PASS="$(grep -c '^ok$'   "$RESULTS")" || true
FAIL="$(grep -c '^fail$' "$RESULTS")" || true
echo "=== step-commit-protocol eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

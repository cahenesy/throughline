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

# grep -c prints the count and exits 1 when zero — keep the count, drop the rc.
PASS="$(grep -c '^ok$'   "$RESULTS")" || true
FAIL="$(grep -c '^fail$' "$RESULTS")" || true
echo "=== step-commit-protocol eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

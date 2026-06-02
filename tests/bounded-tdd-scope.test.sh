#!/usr/bin/env bash
# bounded-tdd-scope.test.sh — eval for TDD 0014 (FR-53 + FR-54 + FR-55).
#
# Theme A binds three previously-implicit knobs at design time: TDD doc size,
# per-touched-file expected-diff size, and the touched-file count. The bounds
# are enforced by three new mechanical checks added to the FR-51 pre-pass
# (scripts/lib/tdd-lint.sh), surfaced via `bash tdd-lint.sh --bounds <tdd>...`,
# which emit `PRECHECK_FAIL: <check> <details>` lines. The design-critique gate
# (FR-55) owns the qualitative scope call via a new design-reviewer checklist
# item; /implement adds NO scope check of its own (ADR 0005).
#
# Covers:
#   - scripts/lib/tdd-lint.sh::check_tdd_doc_size / check_per_file_diff_bound /
#     check_touched_file_count and the `--bounds` dispatcher, including the
#     missing-section + malformed-line + declared-exception + env-skip paths.
#   - agents/design-reviewer.md: the scope-coherence working-memory item +
#     the `DESIGN_REVIEW: BLOCK scope-coherence — <reason>` verdict form.
#   - skills/tdd-author/SKILL.md: the two new required template sections, the
#     step-7b refusal flow (AskUserQuestion three options + `## Scope override`),
#     and the `--bounds` invocation.
#   - the FR-55 enforcement: implement.sh / build-prompt.md carry NO scope-bound
#     env var and NO `scope-concern` halt cause (the build never halts on scope).
#
# Run: bash tests/bounded-tdd-scope.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$REPO/scripts/lib/tdd-lint.sh"
SKILL="$REPO/skills/tdd-author/SKILL.md"
AGENT="$REPO/agents/design-reviewer.md"
IMPL="$REPO/scripts/implement.sh"
BUILDP="$REPO/scripts/build-prompt.md"

RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# --- fixture builders (inline; same mktemp idiom as token-spend-reduction) ----

# A structurally-complete, in-bounds TDD with both new required sections.
make_clean() {  # <path>
  cat > "$1" <<'EOF'
# TDD 9001: clean bounded fixture
Status: draft
PRD refs: FR-53
PRD-rev: deadbee
ADR constraints: none

## Approach
A small, in-bounds change.

## Verification plan
Run the CLI and observe exit code 0.

## Requirement traceability
| PRD | Design element |
|---|---|
| FR-53 | the bounded change |

## Dependencies considered
None.

## Touched files
- scripts/foo.sh — the one change

## Expected diff size
- scripts/foo.sh — 40 lines

Total expected diff: 40 lines across 1 file.
EOF
}

# A TDD whose body (first `## ` heading → EOF) is exactly 600 lines — over the
# 500-line default cap (raised from 350 in the post-0014 cap-raise; see
# tdd-lint.sh THROUGHLINE_TDD_MAX_LINES) — with all other bounds satisfied so
# ONLY tdd-doc-size fires.
make_oversize() {  # <path>
  {
    printf '# TDD 9002: oversize fixture\nStatus: draft\nPRD refs: FR-53\nPRD-rev: deadbee\nADR constraints: none\n\n'
    printf '## Approach\n'
    # 582 pad lines + the 18 non-pad body lines below == 600 body lines.
    local i
    for ((i=1;i<=582;i++)); do printf 'pad line %d\n' "$i"; done
    printf '\n## Touched files\n- scripts/foo.sh — small change\n'
    printf '\n## Expected diff size\n- scripts/foo.sh — 10 lines\n'
    printf '\nTotal expected diff: 10 lines across 1 file.\n'
    printf '\n## Verification plan\nRun it, observe exit code 0.\n'
    printf '\n## Requirement traceability\n| FR-53 | x |\n'
    printf '\n## Dependencies considered\nNone.\n'
  } > "$1"
}

# Per-file diff over the bound, with NO declared exception.
make_perfile_noexc() {  # <path>
  cat > "$1" <<'EOF'
# TDD 9003: per-file over bound, no exception
Status: draft
PRD refs: FR-54
PRD-rev: deadbee
ADR constraints: none

## Approach
One file changes a lot.

## Verification plan
Run it, observe exit code 0.

## Requirement traceability
| FR-54 | x |

## Dependencies considered
None.

## Touched files
- scripts/foo.sh — the big change

## Expected diff size
- scripts/foo.sh — 500 lines

Total expected diff: 500 lines across 1 file.
EOF
}

# Per-file diff over the bound WITH a declared inline exception.
make_perfile_exc() {  # <path>
  cat > "$1" <<'EOF'
# TDD 9004: per-file over bound, with exception
Status: draft
PRD refs: FR-54
PRD-rev: deadbee
ADR constraints: none

## Approach
A wide-but-shallow code move.

## Verification plan
Run it, observe exit code 0.

## Requirement traceability
| FR-54 | x |

## Dependencies considered
None.

## Touched files
- scripts/foo.sh — code move

## Expected diff size
- scripts/foo.sh — 500 lines (exception: code move from implement.sh, no behavior change)

Total expected diff: 500 lines across 1 file.
EOF
}

# 12 entries in `## Touched files` (over the 8 default).
make_touched12() {  # <path>
  {
    printf '# TDD 9005: too many touched files\nStatus: draft\nPRD refs: FR-53\nPRD-rev: deadbee\nADR constraints: none\n\n'
    printf '## Approach\nTouches twelve files.\n\n'
    printf '## Verification plan\nRun it, observe exit code 0.\n\n'
    printf '## Requirement traceability\n| FR-53 | x |\n\n'
    printf '## Dependencies considered\nNone.\n\n'
    printf '## Touched files\n'
    local i
    for ((i=1;i<=12;i++)); do printf -- '- scripts/file%02d.sh — change %d\n' "$i" "$i"; done
    printf '\n## Expected diff size\n'
    for ((i=1;i<=12;i++)); do printf -- '- scripts/file%02d.sh — 10 lines\n' "$i"; done
    printf '\nTotal expected diff: 120 lines across 12 files.\n'
  } > "$1"
}

# Missing BOTH new required sections.
make_missing_sections() {  # <path>
  cat > "$1" <<'EOF'
# TDD 9006: missing new sections
Status: draft
PRD refs: FR-53
PRD-rev: deadbee
ADR constraints: none

## Approach
No touched-files or expected-diff section here.

## Verification plan
Run it, observe exit code 0.

## Requirement traceability
| FR-53 | x |

## Dependencies considered
None.
EOF
}

# An `## Expected diff size` entry with no extractable line count.
make_malformed() {  # <path>
  cat > "$1" <<'EOF'
# TDD 9007: malformed expected-diff entry
Status: draft
PRD refs: FR-54
PRD-rev: deadbee
ADR constraints: none

## Approach
The estimate is unparseable.

## Verification plan
Run it, observe exit code 0.

## Requirement traceability
| FR-54 | x |

## Dependencies considered
None.

## Touched files
- scripts/foo.sh — change

## Expected diff size
- scripts/foo.sh — a big rewrite, hard to estimate

Total expected diff: unknown.
EOF
}

# ============================================================================
echo "[bounds-clean] in-bounds TDD: --bounds exits 0 with no PRECHECK_FAIL"
(
  TMP="$(mktemp -d)"; f="$TMP/clean.md"; make_clean "$f"
  out="$(bash "$LINT" --bounds "$f" 2>/dev/null)"; rc=$?
  rm -rf "$TMP"
  [ "$rc" -eq 0 ] && ok "exit 0 on in-bounds TDD" || bad "expected exit 0 (got $rc; out=$out)"
  printf '%s\n' "$out" | grep -q 'PRECHECK_FAIL' \
    && bad "expected no PRECHECK_FAIL on clean fixture (got: $out)" \
    || ok "no PRECHECK_FAIL on clean fixture"
)

echo "[bounds-docsize] oversize body emits 'tdd-doc-size 600 > 500'"
(
  TMP="$(mktemp -d)"; f="$TMP/oversize.md"; make_oversize "$f"
  out="$(bash "$LINT" --bounds "$f" 2>/dev/null)"; rc=$?
  rm -rf "$TMP"
  printf '%s\n' "$out" | grep -qF 'PRECHECK_FAIL: tdd-doc-size 600 > 500' \
    && ok "emits 'PRECHECK_FAIL: tdd-doc-size 600 > 500'" \
    || bad "expected /PRECHECK_FAIL: tdd-doc-size 600 > 500/ (got: $out)"
  [ "$rc" -ne 0 ] && ok "non-zero exit on doc-size violation (rc=$rc)" || bad "expected non-zero exit (got $rc)"
)

echo "[bounds-perfile] per-file over bound, no exception, emits per-file-diff"
(
  TMP="$(mktemp -d)"; f="$TMP/perfile.md"; make_perfile_noexc "$f"
  out="$(bash "$LINT" --bounds "$f" 2>/dev/null)"; rc=$?
  rm -rf "$TMP"
  printf '%s\n' "$out" | grep -qF 'PRECHECK_FAIL: per-file-diff scripts/foo.sh 500 > 300 (no exception)' \
    && ok "emits 'per-file-diff scripts/foo.sh 500 > 300 (no exception)'" \
    || bad "expected the per-file-diff line (got: $out)"
  [ "$rc" -ne 0 ] && ok "non-zero exit on per-file violation (rc=$rc)" || bad "expected non-zero exit (got $rc)"
)

echo "[bounds-perfile-exc] declared exception suppresses the per-file-diff finding"
(
  TMP="$(mktemp -d)"; f="$TMP/perfile-exc.md"; make_perfile_exc "$f"
  out="$(bash "$LINT" --bounds "$f" 2>/dev/null)"; rc=$?
  rm -rf "$TMP"
  printf '%s\n' "$out" | grep -q 'per-file-diff' \
    && bad "exception should suppress the per-file-diff finding (got: $out)" \
    || ok "no per-file-diff finding when an (exception:) marker is present"
  [ "$rc" -eq 0 ] && ok "exit 0 when the only over-bound file has an exception" || bad "expected exit 0 (got $rc; out=$out)"
)

echo "[bounds-touched] 12 touched files emits 'touched-files 12 > 8'"
(
  TMP="$(mktemp -d)"; f="$TMP/touched12.md"; make_touched12 "$f"
  out="$(bash "$LINT" --bounds "$f" 2>/dev/null)"; rc=$?
  rm -rf "$TMP"
  printf '%s\n' "$out" | grep -qF 'PRECHECK_FAIL: touched-files 12 > 8' \
    && ok "emits 'PRECHECK_FAIL: touched-files 12 > 8'" \
    || bad "expected /PRECHECK_FAIL: touched-files 12 > 8/ (got: $out)"
)

echo "[bounds-missing] missing new sections emit missing-section for each"
(
  TMP="$(mktemp -d)"; f="$TMP/missing.md"; make_missing_sections "$f"
  out="$(bash "$LINT" --bounds "$f" 2>/dev/null)"; rc=$?
  rm -rf "$TMP"
  printf '%s\n' "$out" | grep -qF 'PRECHECK_FAIL: missing-section ## Touched files' \
    && ok "emits missing-section for '## Touched files'" \
    || bad "expected missing-section ## Touched files (got: $out)"
  printf '%s\n' "$out" | grep -qF 'PRECHECK_FAIL: missing-section ## Expected diff size' \
    && ok "emits missing-section for '## Expected diff size'" \
    || bad "expected missing-section ## Expected diff size (got: $out)"
)

echo "[bounds-malformed] unparseable expected-diff entry emits expected-diff-malformed"
(
  TMP="$(mktemp -d)"; f="$TMP/malformed.md"; make_malformed "$f"
  out="$(bash "$LINT" --bounds "$f" 2>/dev/null)"; rc=$?
  rm -rf "$TMP"
  printf '%s\n' "$out" | grep -q 'PRECHECK_FAIL: expected-diff-malformed' \
    && ok "emits expected-diff-malformed for the unparseable entry" \
    || bad "expected /expected-diff-malformed/ (got: $out)"
)

echo "[bounds-skip-zero] non-positive THROUGHLINE_TDD_MAX_* skips that bound"
(
  TMP="$(mktemp -d)"
  make_oversize "$TMP/oversize.md"
  make_touched12 "$TMP/touched12.md"
  make_missing_sections "$TMP/missing.md"
  out1="$(THROUGHLINE_TDD_MAX_LINES=0 bash "$LINT" --bounds "$TMP/oversize.md" 2>/dev/null)"
  out2="$(THROUGHLINE_TDD_MAX_TOUCHED=0 bash "$LINT" --bounds "$TMP/touched12.md" 2>/dev/null)"
  out3="$(THROUGHLINE_TDD_MAX_FILE_DIFF=0 bash "$LINT" --bounds "$TMP/missing.md" 2>/dev/null)"
  rm -rf "$TMP"
  printf '%s\n' "$out1" | grep -q 'tdd-doc-size' \
    && bad "MAX_LINES=0 should skip doc-size (got: $out1)" \
    || ok "MAX_LINES=0 skips the doc-size bound"
  printf '%s\n' "$out2" | grep -q 'touched-files' \
    && bad "MAX_TOUCHED=0 should skip touched-count (got: $out2)" \
    || ok "MAX_TOUCHED=0 skips the touched-count bound"
  printf '%s\n' "$out3" | grep -q 'missing-section ## Expected diff size' \
    && bad "MAX_FILE_DIFF=0 should skip the expected-diff bound (incl. its missing-section) (got: $out3)" \
    || ok "MAX_FILE_DIFF=0 skips the expected-diff bound entirely"
)

echo "[bounds-env-raise] raising THROUGHLINE_TDD_MAX_TOUCHED clears the 12-file fixture"
(
  TMP="$(mktemp -d)"; f="$TMP/touched12.md"; make_touched12 "$f"
  out="$(THROUGHLINE_TDD_MAX_TOUCHED=20 bash "$LINT" --bounds "$f" 2>/dev/null)"
  rm -rf "$TMP"
  printf '%s\n' "$out" | grep -q 'touched-files' \
    && bad "MAX_TOUCHED=20 should clear a 12-file TDD (got: $out)" \
    || ok "the bound is env-overridable (MAX_TOUCHED=20 clears 12 files)"
)

# --- design-reviewer prompt (FR-55 / §4) ------------------------------------
echo "[agent-scope] design-reviewer carries the scope-coherence working-memory item"
(
  grep -qi 'scope.coherence' "$AGENT" \
    && ok "design-reviewer.md mentions scope coherence" \
    || bad "expected scope-coherence checklist item in $AGENT"
  grep -qiE 'working[ -]memory' "$AGENT" \
    && ok "design-reviewer.md frames it as a working-memory check" \
    || bad "expected the working-memory framing in $AGENT"
  grep -qF 'DESIGN_REVIEW: BLOCK scope-coherence' "$AGENT" \
    && ok "design-reviewer.md specifies the scope-coherence BLOCK verdict form" \
    || bad "expected 'DESIGN_REVIEW: BLOCK scope-coherence' in $AGENT"
)

# --- tdd-author SKILL.md (§1 + §3) ------------------------------------------
echo "[skill-template] the two new required sections are in the TDD template"
(
  grep -qF '## Touched files' "$SKILL" \
    && ok "template has '## Touched files'" \
    || bad "expected '## Touched files' in the SKILL template"
  grep -qF '## Expected diff size' "$SKILL" \
    && ok "template has '## Expected diff size'" \
    || bad "expected '## Expected diff size' in the SKILL template"
)

echo "[skill-7b] step 7b wires the --bounds pre-pass + the refusal flow"
(
  grep -qF -- '--bounds' "$SKILL" \
    && ok "SKILL.md invokes the --bounds scope pre-pass" \
    || bad "expected a '--bounds' invocation in $SKILL"
  grep -q 'PRECHECK_FAIL' "$SKILL" \
    && ok "SKILL.md keys the refusal flow off PRECHECK_FAIL" \
    || bad "expected PRECHECK_FAIL handling in $SKILL"
  grep -q 'AskUserQuestion' "$SKILL" \
    && ok "SKILL.md presents AskUserQuestion on a bound violation" \
    || bad "expected AskUserQuestion in the refusal flow ($SKILL)"
  grep -qF '## Scope override' "$SKILL" \
    && ok "SKILL.md documents the '## Scope override' section for the override arm" \
    || bad "expected '## Scope override' in $SKILL"
)

# --- FR-55 enforcement / §5: no /implement-side scope check -----------------
echo "[fr55-no-impl-check] the build side carries no scope-bound logic"
(
  grep -q 'THROUGHLINE_TDD_MAX_' "$IMPL" \
    && bad "implement.sh must not reference the design-time scope-bound env vars (FR-55 / §5)" \
    || ok "implement.sh carries no THROUGHLINE_TDD_MAX_* (scope is a design gate, not a build gate)"
  grep -q 'scope-concern' "$IMPL" \
    && bad "implement.sh must not carry a 'scope-concern' halt cause (FR-55 / §5)" \
    || ok "implement.sh has no 'scope-concern' halt cause"
  grep -q 'THROUGHLINE_TDD_MAX_\|scope-concern' "$BUILDP" \
    && bad "build-prompt.md must not add a scope check (FR-55 / §5)" \
    || ok "build-prompt.md adds no scope check"
)

PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo
echo "=== bounded-tdd-scope eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

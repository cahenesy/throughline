#!/usr/bin/env bash
# md-parser.test.sh — eval for TDD 0055 (markdown section/bullet parser
# unification, scripts/lib/md.sh). FR-53, FR-54, FR-67, FR-69.
#
# scripts/lib/md.sh is the SINGLE source of truth for the two markdown-structure
# parser families the runner's shell libs had copy-pasted:
#   - md_section_body <file> <heading>  — the fence-aware (``` AND ~~~) section
#     walk (reuse #11), rc-checked (never a silent empty body on awk failure).
#   - md_bullet_path_of_line <bullet>   — the shared per-bullet path op (reuse
#     #12): leading backtick-quoted token else first whitespace token, em-dash
#     split, annotation-robust.
#   - md_bullet_path <file> <heading> [mode] — md_section_body | `/^- /` |
#     md_bullet_path_of_line; single canonical bullet anchor (A23); rc-propagating.
#
# Covers the folded bugs:
#   A21 — `~~~` fences honored (not only ```), so a `~~~`-fenced example is excluded.
#   A23 — one `/^- /` bullet anchor shared by count + extract.
#   L-005 — md_bullet_path checks awk's exit code: a parse failure surfaces (rc 2 +
#           stderr diagnostic), never a silent empty list that reads as out-of-scope.
# The migrated callers (plan-classifier, tdd-lint, gates, touched-files) and the
# A4 sentinel fix are covered in their own sections below, added as each caller is
# wired through md.sh.
#
# Run: bash tests/md-parser.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MD="$REPO/scripts/lib/md.sh"

RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# ============================================================================
# md_section_body — fence-aware (``` AND ~~~) section walk.
# ============================================================================

# A section whose body straddles a ```-fenced AND a ~~~-fenced block, each
# containing `## …`-looking and bullet-looking lines that must NOT leak out, plus
# a real following `## Beta` that ends the section.
make_section_fixture() {  # <path>
  cat > "$1" <<'EOF'
# Fixture
intro line (outside any section)

## Alpha
line a1
```
## NotAHeading inside backtick fence
- not-a-bullet.txt — inside fence
```
line a2
~~~
## AlsoNot inside tilde fence
- also-not.txt — inside tilde fence
~~~
line a3

## Beta
line b1
EOF
}

echo "[section-fence] md_section_body emits only the real in-section lines; both fence styles (triple-backtick AND tilde) excluded (A21)"
(
  source "$MD" 2>/dev/null || { bad "INFRA: could not source md.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/sec.md"; make_section_fixture "$f"
  got="$(md_section_body "$f" "Alpha")"; rc=$?
  [ "$rc" -eq 0 ] && ok "rc 0 on a well-formed section" || bad "expected rc 0 (got $rc)"
  want="$(printf 'line a1\nline a2\nline a3')"
  [ "$got" = "$want" ] \
    && ok "body is the 3 real lines; fenced ## headings + bullets excluded" \
    || bad "section body mismatch: got=[$got] want=[$want]"
  printf '%s\n' "$got" | grep -q 'NotAHeading' \
    && bad "a ```-fenced ## line leaked into the body (A21 fence-walk broken)" \
    || ok "no ```-fenced line leaked"
  printf '%s\n' "$got" | grep -q 'AlsoNot\|also-not' \
    && bad "a ~~~-fenced line leaked into the body (A21 ~~~ fence not honored)" \
    || ok "no ~~~-fenced line leaked"
)

echo "[section-boundary] the section ends at the next real ## heading"
(
  source "$MD" 2>/dev/null || { bad "INFRA: could not source md.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/sec.md"; make_section_fixture "$f"
  got="$(md_section_body "$f" "Beta")"
  [ "$got" = "line b1" ] \
    && ok "Beta body is exactly its one line (Alpha content not bled in)" \
    || bad "Beta body wrong: [$got]"
)

echo "[section-missing-file] a missing file is caller-friendly: rc 0, no output"
(
  source "$MD" 2>/dev/null || { bad "INFRA: could not source md.sh"; exit 0; }
  got="$(md_section_body "/nonexistent/nope.md" "Alpha")"; rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$got" ]; } \
    && ok "missing file → rc 0, empty output" \
    || bad "missing file should be rc 0 + empty (rc=$rc, out=[$got])"
)

echo "[section-awk-rc] an awk failure surfaces as rc 2 + a stderr diagnostic, never a silent empty body (L-005)"
(
  source "$MD" 2>/dev/null || { bad "INFRA: could not source md.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/sec.md"; make_section_fixture "$f"
  awk() { return 3; }   # stub awk to a non-zero exit
  err="$TMP/err"
  got="$(md_section_body "$f" "Alpha" 2>"$err")"; rc=$?
  [ "$rc" -eq 2 ] \
    && ok "rc 2 when the underlying awk fails (not a silent rc 0)" \
    || bad "expected rc 2 on awk failure (got $rc, out=[$got])"
  grep -qi 'awk failed' "$err" \
    && ok "a stderr diagnostic names the awk failure" \
    || bad "expected an 'awk failed' diagnostic on stderr (got: $(cat "$err"))"
)

# ============================================================================
# md_bullet_path_of_line — the shared per-bullet path extractor (reuse #12).
# ============================================================================
echo "[bullet-of-line] each annotated/bare/backticked form yields the real path; a no-path bullet yields empty"
(
  source "$MD" 2>/dev/null || { bad "INFRA: could not source md.sh"; exit 0; }
  check() {  # <input-bullet> <expected-path> <label>
    local got; got="$(md_bullet_path_of_line "$1")"
    [ "$got" = "$2" ] && ok "$3 → [$2]" || bad "$3: got=[$got] want=[$2]"
  }
  check '- `src/backticked.txt` — purpose'                          'src/backticked.txt'   'backticked'
  check '- src/bare.txt — purpose'                                  'src/bare.txt'         'bare'
  check '- `src/annot.txt` (post) — the in-scope file'             'src/annot.txt'        'backticked+annotation'
  check '- src/bareannot.txt (new) — purpose'                       'src/bareannot.txt'    'bare+annotation'
  check '- scripts/lib/gates.sh — `coverage_map_block` description' 'scripts/lib/gates.sh' '0044 bare-path/backticked-desc'
  check '- src/noemdash.txt trailing words'                         'src/noemdash.txt'     'no-em-dash'
  check '- src/noemdash2.txt notes `backtick` token'                'src/noemdash2.txt'    'no-em-dash with trailing backtick'
  check '- — a stray note with no path'                             ''                     'no-path stray'
)

# ============================================================================
# md_bullet_path — fence-aware section + `/^- /` anchor + per-line path op.
# ============================================================================
make_bullet_fixture() {  # <path>
  cat > "$1" <<'EOF'
# Fixture
## Touched files
- `src/backticked.txt` — purpose
- src/bare.txt — purpose
- `src/annot.txt` (post) — the in-scope file
- src/bareannot.txt (new) — purpose
- scripts/lib/gates.sh — `coverage_map_block` description backtick
- src/noemdash.txt trailing words
- src/noemdash2.txt notes `backtick` token
- — a stray note with no path
```
- fenced/not-a-bullet.txt — inside a backtick fence
```
~~~
- tilde/not-a-bullet.txt — inside a tilde fence
~~~

## Expected diff size
- src/elsewhere.txt — 40 lines
EOF
}

echo "[bullet-path-paths] paths mode emits one path per real bullet; fenced bullets + other sections excluded"
(
  source "$MD" 2>/dev/null || { bad "INFRA: could not source md.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/b.md"; make_bullet_fixture "$f"
  got="$(md_bullet_path "$f" "Touched files")"; rc=$?
  want="$(printf 'src/backticked.txt\nsrc/bare.txt\nsrc/annot.txt\nsrc/bareannot.txt\nscripts/lib/gates.sh\nsrc/noemdash.txt\nsrc/noemdash2.txt')"
  [ "$rc" -eq 0 ] && ok "rc 0 on a clean section" || bad "expected rc 0 (got $rc)"
  [ "$got" = "$want" ] \
    && ok "exactly the real bullets' paths (no fenced bullet, no Expected-diff path)" \
    || bad "paths mismatch: got=[$got] want=[$want]"
)

echo "[bullet-path-malformed] malformed mode reports exactly the no-path bullet excerpt"
(
  source "$MD" 2>/dev/null || { bad "INFRA: could not source md.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/b.md"; make_bullet_fixture "$f"
  mal="$(md_bullet_path "$f" "Touched files" malformed)"
  { printf '%s\n' "$mal" | grep -q 'stray' && [ "$(printf '%s\n' "$mal" | grep -c .)" = "1" ]; } \
    && ok "exactly the one no-path bullet is reported" \
    || bad "malformed mode wrong: [$mal]"
)

echo "[bullet-path-anchor] the bullet anchor is /^- /: a two-space bullet (dash, two spaces, path) is recognized and yields its path (A23)"
(
  source "$MD" 2>/dev/null || { bad "INFRA: could not source md.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/anchor.md"
  printf '## Touched files\n-  src/two.txt — extra space after the dash\n' > "$f"
  got="$(md_bullet_path "$f" "Touched files")"
  [ "$got" = "src/two.txt" ] \
    && ok "a /^- / bullet with extra leading space yields src/two.txt" \
    || bad "the /^- / anchor missed a `-  x` bullet: [$got]"
)

echo "[bullet-path-awk-rc] md_bullet_path propagates md_section_body's rc 2 on an awk failure (L-005)"
(
  source "$MD" 2>/dev/null || { bad "INFRA: could not source md.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/b.md"; make_bullet_fixture "$f"
  awk() { return 3; }
  out="$(md_bullet_path "$f" "Touched files" 2>/dev/null)"; rc=$?
  { [ "$rc" -eq 2 ] && [ -z "$out" ]; } \
    && ok "rc 2 + no output on awk failure (parse-fail, not a silent empty list)" \
    || bad "expected rc 2 + empty on awk failure (rc=$rc, out=[$out])"
)

# ============================================================================
# touched-files.sh delegate — tl_extract_touched_paths routes through
# md_bullet_path (TDD 0055 step 2): output unchanged + rc propagates (L-005 for
# the `## Touched files` path).
# ============================================================================
TF="$REPO/scripts/lib/touched-files.sh"
echo "[touched-delegate] tl_extract_touched_paths delegates to md_bullet_path: same paths, and rc 2 + diagnostic on awk failure (L-005)"
(
  source "$TF" 2>/dev/null || { bad "INFRA: could not source touched-files.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/t.md"
  printf '## Touched files\n- `src/a.txt` (post) — annotated\n- src/b.txt — bare\n' > "$f"
  got="$(tl_extract_touched_paths "$f")"
  want="$(printf 'src/a.txt\nsrc/b.txt')"
  [ "$got" = "$want" ] \
    && ok "paths match md_bullet_path output (annotated + bare)" \
    || bad "delegate output mismatch: got=[$got] want=[$want]"
  mal="$(printf '## Touched files\n- src/ok.txt — fine\n- — stray\n' > "$f"; tl_extract_touched_paths "$f" malformed)"
  printf '%s\n' "$mal" | grep -q 'stray' \
    && ok "malformed mode forwarded through the delegate" \
    || bad "malformed mode not forwarded: [$mal]"
  # L-005: an awk failure must surface as rc 2 + a stderr diagnostic, never a
  # silent empty set (which a membership check would read as "every file out of scope").
  printf '## Touched files\n- src/a.txt — annotated\n' > "$f"
  (
    awk() { return 3; }
    err="$TMP/err"; out="$(tl_extract_touched_paths "$f" 2>"$err")"; rc=$?
    { [ "$rc" -eq 2 ] && [ -z "$out" ]; } \
      && ok "rc 2 + empty on awk failure (delegated L-005)" \
      || bad "expected rc 2 + empty on awk failure (rc=$rc, out=[$out])"
    grep -qiE 'awk failed|parse failed' "$err" \
      && ok "a stderr diagnostic surfaces the parse failure" \
      || bad "expected a parse-fail diagnostic on stderr (got: $(cat "$err"))"
  )
)

# ============================================================================
# plan-classifier.sh — section scan routed through md_section_body (TDD 0055
# step 3): the classifier becomes fence-aware, closing the reuse-#11 misroute
# (a fenced `## Verification plan` / nontrivial-keyword example inside ANOTHER
# section no longer leaks into the keyword scan).
# ============================================================================
CLS="$REPO/scripts/lib/plan-classifier.sh"
# A TDD whose REAL `## Verification plan` is mechanical (CLI exit code), but whose
# `## Approach` contains a FENCED example of a rejected browser-driven approach —
# including a fenced `## Verification plan` heading. A non-fence-aware walk reads
# the fenced "browser/playwright" lines and misroutes to `nontrivial`.
make_fence_misroute() {  # <path>
  cat > "$1" <<'EOF'
# TDD 9100: fence-misroute fixture
Status: draft

## Approach
We considered a browser-driven check but rejected it. The rejected example:
```
## Verification plan
Open a browser with playwright and click through the rendered DOM.
```
The chosen approach is a plain CLI invocation.

## Verification plan
Run the CLI and assert exit code 0; grep the log for the done marker.

## Requirement traceability
| FR-52 | x |
EOF
}

echo "[cls-fence-misroute] a fenced browser/playwright example does not misroute a mechanical plan (reuse #11)"
(
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/m.md"; make_fence_misroute "$f"
  out="$(source "$CLS"; tl_classify_plan "$f" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && ok "classifier exits 0 on the fixture" || bad "expected rc 0 (got $rc)"
  [ "$out" = "mechanical" ] \
    && ok "mechanical (fenced browser example excluded; real plan is exit-code/grep)" \
    || bad "fence misroute: expected 'mechanical', got '$out'"
)

# ============================================================================
# tdd-lint.sh — check_per_file_diff_bound + check_touched_file_count routed
# through md.sh (TDD 0055 step 4). Folds A4 (gawk-fatal vs missing-section
# exit-code collision) and A23 (count/extract bullet-anchor agreement), plus the
# residual ~~~ count-vs-extract divergence (MINOR-1).
# ============================================================================
LINT="$REPO/scripts/lib/tdd-lint.sh"

echo "[a4-gawk-fatal] a gawk FATAL (awk exit 2) inside check_per_file_diff_bound is a crash (rc 2 + diag), NOT 'missing section' (A4, Verification §6)"
(
  source "$LINT" 2>/dev/null || { bad "INFRA: could not source tdd-lint.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/d.md"
  printf '## Expected diff size\n- scripts/foo.sh — 40 lines\n' > "$f"
  (
    awk() { return 2; }   # gawk-style FATAL exit code (collides with old missing-section sentinel)
    err="$TMP/err"; out="$(check_per_file_diff_bound "$f" 2>"$err")"; rc=$?
    [ "$rc" -eq 2 ] \
      && ok "rc 2 (crash) on awk exit 2" \
      || bad "expected crash rc 2 on a gawk FATAL, got $rc (out=[$out])"
    grep -qiE 'awk failed|parse failed' "$err" \
      && ok "a stderr diagnostic surfaces the crash" \
      || bad "expected a parse-fail diagnostic (got: $(cat "$err"))"
    printf '%s\n' "$out" | grep -q 'missing-section' \
      && bad "a gawk FATAL was wrongly read as missing-section (A4 collision)" \
      || ok "the gawk FATAL is not read as missing-section"
  )
)

echo "[a4-genuine-missing] a genuinely missing ## Expected diff size still emits its missing-section PRECHECK"
(
  source "$LINT" 2>/dev/null || { bad "INFRA: could not source tdd-lint.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/d.md"
  printf '## Approach\nno expected-diff section here at all\n' > "$f"
  out="$(check_per_file_diff_bound "$f" 2>/dev/null)"; rc=$?
  printf '%s\n' "$out" | grep -qF 'missing-section ## Expected diff size' \
    && ok "missing-section PRECHECK still emitted (rc=$rc)" \
    || bad "expected the missing-section PRECHECK (got: $out, rc=$rc)"
)

echo "[a23-count-extract-anchor] check_touched_file_count and md_bullet_path agree on a two-space bullet (A23, Verification §5)"
(
  source "$LINT" 2>/dev/null || { bad "INFRA: could not source tdd-lint.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/t.md"
  # one normal bullet + one two-space bullet (dash, two spaces, path); the count
  # and the extractor must agree that BOTH are bullets.
  printf '## Touched files\n- a.txt — one\n-  b.txt — two-space bullet\n\n## Expected diff size\n- a.txt — 10 lines\n-  b.txt — 10 lines\n' > "$f"
  n_extract="$(md_bullet_path "$f" "Touched files" | grep -c .)"
  out="$(THROUGHLINE_TDD_MAX_TOUCHED=1 check_touched_file_count "$f" 2>/dev/null)"
  [ "$n_extract" -eq 2 ] \
    && ok "md_bullet_path extracts 2 paths (incl the two-space bullet)" \
    || bad "md_bullet_path count=$n_extract (want 2)"
  printf '%s\n' "$out" | grep -qF 'touched-files 2 > 1' \
    && ok "check_touched_file_count counts 2 (anchor agrees with extract)" \
    || bad "count/extract disagree on the two-space bullet (got: $out)"
)

echo "[minor1-tilde-fence] a ~~~-fenced bullet in ## Touched files is excluded by BOTH count and extract (MINOR-1)"
(
  source "$LINT" 2>/dev/null || { bad "INFRA: could not source tdd-lint.sh"; exit 0; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; f="$TMP/t.md"
  printf '## Touched files\n- real.txt — keep\n~~~\n- fenced.txt — drop\n~~~\n\n## Expected diff size\n- real.txt — 10 lines\n' > "$f"
  paths="$(md_bullet_path "$f" "Touched files")"
  out="$(THROUGHLINE_TDD_MAX_TOUCHED=1 check_touched_file_count "$f" 2>/dev/null)"
  [ "$paths" = "real.txt" ] \
    && ok "extract excludes the ~~~-fenced bullet" \
    || bad "extract did not exclude the ~~~-fenced bullet: [$paths]"
  printf '%s\n' "$out" | grep -q 'touched-files [0-9]* >' \
    && bad "count should be 1 (~~~-fenced bullet excluded), but reported an overflow: $out" \
    || ok "count excludes the ~~~-fenced bullet (no overflow at MAX=1)"
)

# --- report ----------------------------------------------------------------
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo
echo "=== md-parser eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

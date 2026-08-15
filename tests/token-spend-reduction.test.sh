#!/usr/bin/env bash
# token-spend-reduction.test.sh — eval for TDD 0013 (FR-51 + FR-52).
#
# Covers:
#   - scripts/lib/tdd-lint.sh: the four lint functions and the unified exit-code
#     contract (0 = clean / nit-only, 1 = major, 2 = blocker), with the file's
#     stdout finding format `<file>:<line> <severity> <code>: <msg>`. Each
#     fixture under tests/fixtures/tdds/ asserts one rule of that contract.
#   - scripts/lib/plan-classifier.sh::tl_classify_plan: the mechanical vs
#     nontrivial heuristic.
#   - the agent / skill edits that wire FR-51 into /tdd-author.
#
# Run: bash tests/token-spend-reduction.test.sh

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$REPO/scripts/lib/tdd-lint.sh"
CLS="$REPO/scripts/lib/plan-classifier.sh"
FIX="$REPO/tests/fixtures/tdds"

# Tally results in a tempfile so subshells can append.
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
expect_exit() {  # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then ok "$3 (exit=$2)"; else bad "$3 (expected exit=$1, got exit=$2)"; fi
}

echo "[lint-A] structural lint blocks on missing ## Verification plan"
(
  out="$(bash "$LINT" "$FIX/missing-vp.md" 2>/dev/null)"; rc=$?
  expect_exit 2 "$rc" "exit code 2 (blocker)"
  printf '%s\n' "$out" | grep -q 'section.verification_plan' \
    && ok "stdout names section.verification_plan" \
    || bad "expected /section.verification_plan/ in stdout (got: $out)"
)

echo "[lint-B] clean fixture exits 0 with no findings"
(
  out="$(bash "$LINT" "$FIX/clean.md" 2>/dev/null)"; rc=$?
  expect_exit 0 "$rc" "exit code 0 (clean)"
  [ -z "$out" ] && ok "stdout empty on clean fixture" || bad "expected empty stdout on clean fixture (got: $out)"
)

echo "[lint-C] placeholder lint silences fenced + <angle> TBD, fires on prose TBD"
(
  out="$(bash "$LINT" "$FIX/placeholder-prose.md" 2>/dev/null)"; rc=$?
  # major-severity placeholder + missing section nothing → exit 1
  expect_exit 1 "$rc" "exit code 1 (major)"
  printf '%s\n' "$out" | grep -qE 'placeholder' \
    && ok "stdout names placeholder finding" \
    || bad "expected /placeholder/ in stdout (got: $out)"

  out2="$(bash "$LINT" "$FIX/placeholder-fenced.md" 2>/dev/null)"; rc2=$?
  expect_exit 0 "$rc2" "fenced/angle-bracket TBD does not fire"
  [ -z "$out2" ] && ok "stdout empty on fenced-only TBD fixture" || bad "expected empty stdout on fenced-only fixture (got: $out2)"
)

echo "[lint-D] traceability lint flags an FR in PRD refs but absent from the table"
(
  out="$(bash "$LINT" "$FIX/untraced.md" 2>/dev/null)"; rc=$?
  expect_exit 1 "$rc" "exit code 1 (major)"
  printf '%s\n' "$out" | grep -qE 'FR-3' \
    && ok "stdout names the untraced FR-3" \
    || bad "expected /FR-3/ in stdout (got: $out)"
)

echo "[lint-E] section.empty lint fires on adjacent ## headings"
(
  out="$(bash "$LINT" "$FIX/empty-section.md" 2>/dev/null)"; rc=$?
  expect_exit 1 "$rc" "exit code 1 (major)"
  printf '%s\n' "$out" | grep -q 'section.empty' \
    && ok "stdout names section.empty" \
    || bad "expected /section.empty/ in stdout (got: $out)"
)

echo "[lint-F] aggregate exit is max(sub-lints), capped at 2"
(
  # missing-vp has a blocker -> aggregate rc must be 2 even when run alongside
  # cleans.
  out="$(bash "$LINT" "$FIX/clean.md" "$FIX/missing-vp.md" 2>/dev/null)"; rc=$?
  expect_exit 2 "$rc" "aggregate exit = max severity (blocker wins)"
)

echo "[cls-A] tl_classify_plan: mechanical observation -> mechanical"
(
  out="$(bash -c "source '$CLS'; tl_classify_plan '$FIX/clean.md'" 2>/dev/null)"; rc=$?
  [ "$out" = "mechanical" ] && ok "mechanical plan classified mechanical" || bad "expected mechanical, got '$out' (rc=$rc)"
)

echo "[cls-B] tl_classify_plan: browser/Playwright -> nontrivial"
(
  tmp="$(mktemp --suffix=.md)"
  cat > "$tmp" <<'EOF'
# fixture
PRD refs: FR-1
## Verification plan
Drive a browser via Playwright and observe the rendered DOM.
EOF
  out="$(bash -c "source '$CLS'; tl_classify_plan '$tmp'" 2>/dev/null)"
  [ "$out" = "nontrivial" ] && ok "browser/Playwright -> nontrivial" || bad "expected nontrivial, got '$out'"
  rm -f "$tmp"
)

echo "[cls-C] tl_classify_plan: HTTP 200 / body assertion -> mechanical"
(
  tmp="$(mktemp --suffix=.md)"
  cat > "$tmp" <<'EOF'
# fixture
## Verification plan
curl the endpoint and observe HTTP 200 plus the JSON body matches.
EOF
  out="$(bash -c "source '$CLS'; tl_classify_plan '$tmp'" 2>/dev/null)"
  [ "$out" = "mechanical" ] && ok "HTTP-200 plan -> mechanical" || bad "expected mechanical, got '$out'"
  rm -f "$tmp"
)

echo "[cls-D] tl_classify_plan: no obvious markers -> nontrivial (conservative)"
(
  tmp="$(mktemp --suffix=.md)"
  cat > "$tmp" <<'EOF'
# fixture
## Verification plan
The change is correct.
EOF
  out="$(bash -c "source '$CLS'; tl_classify_plan '$tmp'" 2>/dev/null)"
  [ "$out" = "nontrivial" ] && ok "ambiguous plan -> nontrivial (conservative default)" || bad "expected nontrivial default, got '$out'"
  rm -f "$tmp"
)

echo "[cls-E] tl_classify_plan: mixed (mechanical + browser) -> nontrivial (browser wins)"
(
  tmp="$(mktemp --suffix=.md)"
  cat > "$tmp" <<'EOF'
# fixture
## Verification plan
Drive the browser to /foo, observe stdout / exit code at the CLI side too.
EOF
  out="$(bash -c "source '$CLS'; tl_classify_plan '$tmp'" 2>/dev/null)"
  [ "$out" = "nontrivial" ] && ok "mixed plan -> nontrivial" || bad "expected nontrivial, got '$out'"
  rm -f "$tmp"
)

echo "[agent-A] design-reviewer.md carries the Pre-check already ran preamble"
(
  grep -q 'Pre-check already ran' "$REPO/agents/design-reviewer.md" \
    && ok "preamble present in agents/design-reviewer.md" \
    || bad "expected 'Pre-check already ran' in agents/design-reviewer.md"
)

echo "[agent-B] tdd-author SKILL.md invokes tdd-lint.sh in step 7a"
(
  grep -q 'tdd-lint.sh' "$REPO/skills/tdd-author/SKILL.md" \
    && ok "tdd-lint.sh referenced in tdd-author SKILL.md" \
    || bad "expected 'tdd-lint.sh' in skills/tdd-author/SKILL.md"
)

echo "[agent-C] implement SKILL.md documents THROUGHLINE_RUNTIME_VERIFY_MODEL"
(
  grep -q 'THROUGHLINE_RUNTIME_VERIFY_MODEL' "$REPO/skills/implement/SKILL.md" \
    && ok "env var documented in implement SKILL.md" \
    || bad "expected THROUGHLINE_RUNTIME_VERIFY_MODEL in skills/implement/SKILL.md"
)






# --- Review-blocker coverage (M1/M2/M3 from the TDD 0013 review pass) --------
# Each test below exercises a silent-failure mode the independent reviewer
# flagged. The pre-fix lint/runner answers `clean`/`nontrivial` to the caller
# despite an underlying failure, violating NFR-4 verdict honesty. The fixes
# either propagate the failure as an error code (rc=2) or attach a
# distinguishable note to the log line so triage can tell error from genuine.

echo "[lint-M1] section.empty lint emits finding even when input directory is read-only"
(
  # Pre-fix: tl_lint_structural's section.empty pass writes to
  # "$f.tdd-lint.empty.$$" adjacent to the input. Read-only directory →
  # redirect fails (silenced by 2>/dev/null) → [ -s ... ] is false → zero
  # findings, rc=0 (silent FAIL). The fix must keep the finding visible.
  TMP="$(mktemp -d)"
  cp "$FIX/empty-section.md" "$TMP/empty-section.md"
  chmod -w "$TMP"
  out="$(bash "$LINT" "$TMP/empty-section.md" 2>/dev/null)"; rc=$?
  chmod +w "$TMP"; rm -rf "$TMP"
  expect_exit 1 "$rc" "exit code 1 (major) under read-only dir"
  printf '%s\n' "$out" | grep -q 'section.empty' \
    && ok "stdout names section.empty even under read-only dir" \
    || bad "expected /section.empty/ in stdout under read-only dir (got: $out)"
)

echo "[lint-M2] placeholder lint surfaces awk crash as rc=2 instead of mapping it to clean"
(
  # Pre-fix: case "$?" in 1) rc=1 ;; *) rc=0 ;; — awk exit ≥2 (crash) maps
  # to "clean", so a broken awk run looks like a TDD with no placeholders.
  # The fix must propagate non-{0,1} awk exits as rc=2 (blocker) with a
  # stderr message.
  TMP="$(mktemp -d)"
  cat > "$TMP/awk" <<'EOF2'
#!/usr/bin/env bash
exit 3
EOF2
  chmod +x "$TMP/awk"
  export PATH="$TMP:$PATH"
  source "$LINT"
  err="$(tl_lint_placeholders "$FIX/clean.md" 2>&1 >/dev/null)"; rc=$?
  unset -f tl_lint_structural tl_lint_placeholders tl_lint_traced tl_lint_all _tl_emit 2>/dev/null
  rm -rf "$TMP"
  expect_exit 2 "$rc" "tl_lint_placeholders rc=2 on awk crash"
  printf '%s\n' "$err" | grep -q 'awk' \
    && ok "stderr names awk failure" \
    || bad "expected stderr to mention awk crash (got: $err)"
)


# --- Second review pass: deeper awk-rc + boundary findings (BL/MAJ from review 2)
# The first re-review pass surfaced 2 blockers + 4 majors of the same NFR-4 bug
# class: unchecked awk / pipeline exit codes that map a crash to a clean caller
# answer. Each test below pins one of those down before its corresponding fix.

echo "[lint-B1B2] tl_lint_structural surfaces awk crash as rc=2 (BL-1 + BL-2)"
(
  # Pre-fix: both `has_rows=\$(awk ...)` (traceability check) and
  # `empty_out=\$(awk ...)` (section.empty check) ignore awk's exit code.
  # An awk crash leaves the captured variable empty, the [ -z / -n ]
  # check evaluates as "no rows" / "no findings", and the function
  # returns rc=0 (clean) or a false-positive blocker. Either way the
  # caller is lied to. The fix must surface non-zero awk exit codes
  # from EITHER awk invocation as rc=2 (blocker).
  TMP="$(mktemp -d)"
  cat > "$TMP/awk" <<'EOF2'
#!/usr/bin/env bash
exit 3
EOF2
  chmod +x "$TMP/awk"
  export PATH="$TMP:$PATH"
  source "$LINT"
  err="$(tl_lint_structural "$FIX/clean.md" 2>&1 >/dev/null)"; rc=$?
  unset -f tl_lint_structural tl_lint_placeholders tl_lint_traced tl_lint_all _tl_emit 2>/dev/null
  rm -rf "$TMP"
  expect_exit 2 "$rc" "tl_lint_structural rc=2 on awk crash"
  printf '%s\n' "$err" | grep -qi 'awk' \
    && ok "stderr names awk failure" \
    || bad "expected stderr to mention awk crash (got: $err)"
)

echo "[lint-M2pipe] tl_lint_traced surfaces awk pipeline crash as rc=2 (MAJ-2)"
(
  # Pre-fix: `ids_in_table="\$(awk ... | grep ... | sort -u)"` ignores the
  # pipeline's exit status. An awk crash → empty ids_in_table → every FR
  # in `PRD refs` is "missing from table" → all FRs falsely flagged
  # untraced. The fix must propagate pipeline failures as rc=2.
  TMP="$(mktemp -d)"
  cat > "$TMP/awk" <<'EOF2'
#!/usr/bin/env bash
exit 3
EOF2
  chmod +x "$TMP/awk"
  export PATH="$TMP:$PATH"
  source "$LINT"
  err="$(tl_lint_traced "$FIX/clean.md" 2>&1 >/dev/null)"; rc=$?
  unset -f tl_lint_structural tl_lint_placeholders tl_lint_traced tl_lint_all _tl_emit 2>/dev/null
  rm -rf "$TMP"
  expect_exit 2 "$rc" "tl_lint_traced rc=2 on awk pipeline crash"
  printf '%s\n' "$err" | grep -qi 'awk' \
    && ok "stderr names awk failure" \
    || bad "expected stderr to mention awk crash (got: $err)"
)

echo "[cls-Mawk] tl_classify_plan surfaces awk crash as non-zero rc (MAJ-3)"
(
  # Pre-fix: `body="\$(awk ... | tr ...)"` ignores awk's exit code. A
  # crashed awk → empty body → the bare `nontrivial` default at the end
  # of the function (echoed via the conservative fallback) returns rc=0
  # (clean), which the runner's M3 fix interprets as a genuine
  # nontrivial classification — bypassing the "(classifier failed, ...)"
  # note. The fix must propagate non-zero awk exit as a non-zero rc out
  # of tl_classify_plan so the runner can see the failure.
  TMP="$(mktemp -d)"
  cat > "$TMP/awk" <<'EOF2'
#!/usr/bin/env bash
exit 3
EOF2
  chmod +x "$TMP/awk"
  export PATH="$TMP:$PATH"
  source "$CLS"
  out="$(tl_classify_plan "$FIX/clean.md" 2>/dev/null)"; rc=$?
  unset -f tl_classify_plan 2>/dev/null
  rm -rf "$TMP"
  if [ "$rc" -eq 0 ]; then
    bad "tl_classify_plan returned rc=0 despite awk crash (got out='$out')"
  else
    ok "tl_classify_plan returned non-zero rc on awk crash (rc=$rc)"
  fi
)

echo "[cls-Mui] UI regex matches punctuation forms (UI? / UI)) (MAJ-1)"
(
  # The plan body intentionally MIXES the nontrivial trigger `UI?` with a
  # mechanical trigger `exit code`. Pre-fix: the UI regex
  # `(^| )ui( |$|[.,:;])` doesn't include `?` / `)` in its boundary
  # character class, so `UI?` doesn't match → nontrivial check fails →
  # mechanical check fires (because of `exit code`) → returns mechanical.
  # That's a UI-bearing plan misclassified as mechanical and sent to
  # sonnet, defeating the gate-strength tiering for UI verification.
  # Post-fix (extended boundary class): `UI?` matches → nontrivial wins.
  TMP="$(mktemp -d)"
  cat > "$TMP/ui-question.md" <<'EOF3'
# TDD
Status: draft
PRD refs: FR-99
PRD-rev: dead
ADR constraints: none
## Approach
x
## Verification plan
Run the CLI, observe exit code 0. Then click the UI? Confirm the modal
closes (the visible UI).
## Requirement traceability
| FR | x |
|---|---|
| FR-99 | x |
## Dependencies considered
None.
EOF3
  out="$(bash "$CLS" "$TMP/ui-question.md")"
  rm -rf "$TMP"
  printf '%s\n' "$out" | awk '{print $1}' | grep -q 'nontrivial' \
    && ok "UI? + UI) prose classifies nontrivial despite mechanical evidence" \
    || bad "expected nontrivial classification for UI?/UI) prose (got: $out)"
)

echo "[lint-Mfence] has_rows ignores fenced traceability content (MAJ-4)"
(
  # Pre-fix: the has_rows awk does not track fenced code blocks. A
  # traceability section that contains ONLY a fenced table satisfies the
  # has_rows check (the `|`-line matches the regex). The fix must
  # fence-track so a fenced-only traceability section still fires the
  # `section.traceability: no table-row / FR-/NFR- entry` blocker.
  TMP="$(mktemp -d)"
  cat > "$TMP/fenced-only-traceability.md" <<'EOF4'
# TDD
Status: draft
PRD refs: FR-99
PRD-rev: dead
ADR constraints: none
## Approach
x
## Verification plan
Run the CLI, observe exit code 0, stdout matches.
## Requirement traceability
Below is what we'd put if there were anything to put, but this is just
an illustrative code block, not a real table:
```
| FR | thing |
|---|---|
| FR-99 | x |
```
## Dependencies considered
None.
EOF4
  out="$(bash "$LINT" "$TMP/fenced-only-traceability.md" 2>/dev/null)"; rc=$?
  rm -rf "$TMP"
  if [ "$rc" -eq 2 ]; then
    printf '%s\n' "$out" | grep -q 'section.traceability' \
      && ok "blocker fires when traceability content is only inside a fence" \
      || bad "expected /section.traceability/ blocker (got: $out)"
  else
    bad "expected rc=2 blocker for fenced-only traceability (got rc=$rc, out=$out)"
  fi
)

# --- Third review pass: pipefail-independent awk-rc guards + classifier
# stderr capture + env-pin sanitization ---------------------------------------
# Pass 2's MAJ-2/MAJ-3 fixes used `PIPESTATUS` AFTER a `\$(pipeline)`
# command substitution — which collapses to a single subshell exit when
# `pipefail` is not set. The production CLI invocations
# `bash scripts/lib/tdd-lint.sh <tdd>` and `bash scripts/lib/plan-classifier.sh
# <tdd>` run without pipefail, so the guards were non-functional on the
# primary use path. The fix below captures awk's stdout to a local first,
# checks its rc directly, and only then pipes to the trivial tail
# (grep/sort/tr). The tests deliberately UNSET pipefail in their subshells so
# they exercise the production CLI path rather than the test harness's
# inherited pipefail.

echo "[lint-BL1-standalone] tl_lint_traced surfaces awk crash WITHOUT pipefail (BL-1 from pass 3)"
(
  TMP="$(mktemp -d)"
  cat > "$TMP/awk" <<'EOF2'
#!/usr/bin/env bash
exit 3
EOF2
  chmod +x "$TMP/awk"
  set +o pipefail
  export PATH="$TMP:$PATH"
  source "$LINT"
  err="$(tl_lint_traced "$FIX/clean.md" 2>&1 >/dev/null)"; rc=$?
  unset -f tl_lint_structural tl_lint_placeholders tl_lint_traced tl_lint_all _tl_emit 2>/dev/null
  rm -rf "$TMP"
  expect_exit 2 "$rc" "tl_lint_traced rc=2 on awk crash without pipefail"
  printf '%s\n' "$err" | grep -qi 'awk' \
    && ok "stderr names awk failure (standalone path)" \
    || bad "expected stderr to mention awk crash without pipefail (got: $err)"
)

echo "[cls-BL2-standalone] tl_classify_plan surfaces awk crash WITHOUT pipefail (BL-2 from pass 3)"
(
  TMP="$(mktemp -d)"
  cat > "$TMP/awk" <<'EOF2'
#!/usr/bin/env bash
exit 3
EOF2
  chmod +x "$TMP/awk"
  set +o pipefail
  export PATH="$TMP:$PATH"
  source "$CLS"
  out="$(tl_classify_plan "$FIX/clean.md" 2>/dev/null)"; rc=$?
  unset -f tl_classify_plan 2>/dev/null
  rm -rf "$TMP"
  if [ "$rc" -eq 0 ]; then
    bad "tl_classify_plan rc=0 despite awk crash without pipefail (got out='$out')"
  else
    ok "tl_classify_plan non-zero rc on awk crash without pipefail (rc=$rc)"
  fi
)



# --- Pass 4: plan-classifier CLI dispatcher NFR-4 gap -----------------------

echo "[cls-M2cli] plan-classifier CLI dispatcher surfaces tl_classify_plan failure (MAJ-2 from pass 4)"
(
  # Pre-fix: the standalone `bash plan-classifier.sh <tdd>` dispatcher
  # discards `tl_classify_plan`'s exit code. An awk crash inside the
  # function leaves `cls` empty, the dispatcher prints a tab-separated
  # blank line, and exits 0 — indistinguishable from a clean classification.
  # The fix must (a) propagate a non-zero exit, (b) emit a stderr line,
  # and (c) substitute a non-blank `error` token in the stdout column so
  # the failed entry stands out in a batch.
  TMP="$(mktemp -d)"
  cat > "$TMP/awk" <<'EOF2'
#!/usr/bin/env bash
exit 3
EOF2
  chmod +x "$TMP/awk"
  err="$(PATH="$TMP:$PATH" bash "$CLS" "$FIX/clean.md" 2>&1 >"$TMP/stdout")"; rc=$?
  out="$(cat "$TMP/stdout")"
  rm -rf "$TMP"
  if [ "$rc" -eq 0 ]; then
    bad "dispatcher rc=0 despite classifier failure (got out='$out')"
  else
    ok "dispatcher non-zero rc on classifier failure (rc=$rc)"
  fi
  printf '%s\n' "$out" | grep -q '^error' \
    && ok "stdout names the failed row with an 'error' token" \
    || bad "expected stdout 'error\\t<tdd>' on classifier failure (got: $out)"
  printf '%s\n' "$err" | grep -qi 'classifier\|awk\|fail' \
    && ok "stderr names the failure (standalone path)" \
    || bad "expected stderr to mention the classifier failure (got: $err)"
)

# --- Pass 5: tl_lint_traced fence-awareness ---------------------------------

echo "[lint-Mfence-traced] tl_lint_traced ignores FR IDs that appear ONLY inside a fence (MAJ-1 from pass 5)"
(
  # Pre-fix: tl_lint_traced's body-extraction awk has no fence tracking,
  # so an FR ID that appears only inside a ``` fenced code block in the
  # Requirement traceability section counts as "traced" — silently
  # suppressing the traceability.untraced finding. The same file's
  # has_rows + section.empty + tl_lint_placeholders are all fence-aware
  # (MAJ-4 in pass 2 added this to has_rows). tl_lint_traced is the
  # holdout; this test pins down the inconsistency.
  TMP="$(mktemp -d)"
  cat > "$TMP/fenced-fr.md" <<'EOF5'
# TDD
Status: draft
PRD refs: FR-1, FR-2
PRD-rev: dead
ADR constraints: none
## Approach
x
## Verification plan
Run the CLI, observe exit code 0.
## Requirement traceability
| PRD | Design element |
|---|---|
| FR-1 | something |

The second requirement is illustrated below as code-fence prose,
NOT as a real traceability row — the lint must treat the row
inside the fence as a non-entry:
```
| FR-2 | (this is just example syntax, not a real entry) |
```
## Dependencies considered
None.
EOF5
  out="$(bash "$LINT" "$TMP/fenced-fr.md" 2>/dev/null)"; rc=$?
  rm -rf "$TMP"
  printf '%s\n' "$out" | grep -q 'traceability.untraced.*FR-2' \
    && ok "blocker fires on FR-2 traced only inside a fenced block" \
    || bad "expected traceability.untraced finding for FR-2 (got: $out)"
  [ "$rc" -ge 1 ] \
    && ok "exit code reflects the finding (rc=$rc)" \
    || bad "expected non-zero rc when FR is traced only via fenced text (got rc=$rc)"
)

PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo
echo "=== token-spend-reduction eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

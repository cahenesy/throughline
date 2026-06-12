#!/usr/bin/env bash
# implement-gate.test.sh — eval for the build runner's quality gates.
#
# The kit's core quality claim is that a build cannot mark itself "done": the
# ready->implemented flip is gated on failing-test-first discipline, an INDEPENDENT
# mechanical ci-checks (tests+typecheck+lint), an INDEPENDENT runtime-verify gate
# that drives the built artifact at its observable surface (per the TDD's
# `## Verification plan`), and an INDEPENDENT review process — and a failure
# halts the dependent stack. This eval proves those four gates actually fire,
# using a stub `claude` (so no model/tokens are needed) and a controllable verify
# command.
#
# Run: bash tests/implement-gate.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
# Scenarios run in subshells, so tally via a shared file rather than shell vars.
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
has()  { grep -q "$2" "$1" 2>/dev/null && ok "$3" || bad "$3 (expected /$2/ in $1)"; }
hasnt(){ grep -q "$2" "$1" 2>/dev/null && bad "$3 (unexpected /$2/ in $1)" || ok "$3"; }

# Build a fresh project: <dir> <ntdds> [status]. Installs a stub `claude` and a
# controllable ci-checks command on PATH/env; returns with PWD inside <dir>. TDDs are
# committed on the init branch (= the integration branch) at <status> (default
# ready; pass draft to exercise the merge-as-trigger default path).
setup() {
  local dir="$1" n="$2" status="${3:-ready}" i
  mkdir -p "$dir"/{docs/tdd,docs/adr,.stub/bin}
  cd "$dir"
  git init -q; git config user.email t@t.t; git config user.name t
  printf '# PRD\n## Requirements\n1. do the thing\n' > docs/PRD.md
  printf '# ADR Index\n| # | Title | Status | Scope |\n|---|---|---|---|\n' > docs/adr/INDEX.md
  local names=(alpha beta gamma)
  for ((i=1;i<=n;i++)); do
    printf '# TDD %04d: %s\nStatus: %s\nPRD refs: 1\nPRD-rev: deadbee\nADR constraints: none\n\n## Approach\nstub\n' \
      "$i" "${names[$((i-1))]}" "$status" > "docs/tdd/$(printf '%04d' "$i")-${names[$((i-1))]}.md"
  done
  git add -A; git commit -qm init

  export STUBDIR="$dir/.stub"
  printf '0\n' > "$STUBDIR/verify_rc"          # default: tests pass
  # controllable ci-checks command (read by scripts/ci-checks.sh via CI_CHECKS_TEST_CMD)
  cat > "$STUBDIR/verify_test.sh" <<EOF
#!/usr/bin/env bash
exit "\$(cat "$STUBDIR/verify_rc" 2>/dev/null || echo 0)"
EOF
  export CI_CHECKS_TEST_CMD="bash $STUBDIR/verify_test.sh"
  export CI_CHECKS_TYPECHECK_CMD=""               # explicitly skip typecheck

  # stub `claude`: simulates a build (commits a file), a runtime-verification, or a
  # review, emitting the control line for the TDD's slug (defaults: build OK,
  # runtime PASS, review PASS).
  cat > "$STUBDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; *) shift;; esac; done
slug="$(printf '%s' "$prompt" | grep -oE 'docs/tdd/[0-9]+-[a-z]+' | head -1 | sed 's#docs/tdd/##')"
if printf '%s' "$prompt" | grep -q 'INDEPENDENT runtime-verification gate'; then
  cat "$STUBDIR/runtime-$slug" 2>/dev/null || echo "VERIFY_RUNTIME: PASS"
  exit 0
fi
if printf '%s' "$prompt" | grep -q 'INDEPENDENT review gate'; then
  if [ -f "$STUBDIR/review-$slug" ]; then
    cat "$STUBDIR/review-$slug"
  else
    # TDD 0021 §3b/§3c: a bare PASS is now converted to an incomplete-file-coverage
    # block unless every file in the review's diff scope carries a per-file
    # disposition. Disposition each touched file (the review prompt renders the
    # scope as `--name-only <base>..<head>`) so a stubbed clean review still clears
    # under the new coverage gate.
    rbase="$(printf '%s' "$prompt" | grep -oE 'name-only[[:space:]]+[0-9a-f]{7,40}' | head -1 | grep -oE '[0-9a-f]{7,40}')"
    [ -n "$rbase" ] && git diff --name-only "$rbase"..HEAD 2>/dev/null | while IFS= read -r f; do
      [ -n "$f" ] && echo "FILE_REVIEWED_NO_FINDINGS: $f"
    done
    echo "REVIEW_RESULT: PASS"
  fi
  exit 0
fi
# TDD 0019 bounded rework loop: a review BLOCK triggers a rework pass. The
# default rework is a no-op (empty diff) so the loop exhausts its attempt
# budget and the TDD halts BLOCKED with rework-budget-exhausted — scenarios
# that want a real fix supply $STUBDIR/rework-$slug.
if printf '%s' "$prompt" | grep -q 'BOUNDED rework pass'; then
  bash "$STUBDIR/rework-$slug" 2>/dev/null || true
  exit 0
fi
# failing-test-first commit, unless this scenario suppresses it
if [ ! -f "$STUBDIR/no-test-first-$slug" ]; then
  echo "test for $slug" >> "test-$slug.txt"
  git add -A >/dev/null 2>&1; git commit -q -m "test(failing): $slug" >/dev/null 2>&1 || true
fi
echo "generated $(date +%s%N)" >> "generated-$slug.txt"
git add -A >/dev/null 2>&1; git commit -q -m "stub build $slug" >/dev/null 2>&1 || true
cat "$STUBDIR/build-$slug" 2>/dev/null || echo "BATCH_RESULT: OK"
exit 0
EOF
  chmod +x "$STUBDIR/bin/claude"
  export PATH="$STUBDIR/bin:$PATH"
}

report() { ls -t docs/tdd/.implement-logs/*/report.md 2>/dev/null | head -1; }
status_of() { sed -n 's/^Status:[[:space:]]*//p' "$1" | head -1; }
# Builds run in an isolated worktree on a build branch; read the TDD's Status
# from that branch (the main working tree is intentionally left untouched).
status_on() { git show "$2:$1" 2>/dev/null | sed -n 's/^Status:[[:space:]]*//p' | head -1; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

echo "[A] happy path: build OK + verify pass + review PASS -> implemented"
( setup "$ROOT/a" 1
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = implemented ] && ok "TDD flipped to implemented on build branch" || bad "TDD should be implemented on ci/0001-alpha (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  [ "$(status_of docs/tdd/0001-alpha.md)" = ready ] && ok "main working tree left untouched (isolated worktree)" || bad "main tree must be unchanged by the isolated build (got '$(status_of docs/tdd/0001-alpha.md)')"
  has "$R" "OK (verified + reviewed)" "report shows verified+reviewed OK"
) || true

echo "[B] ci-checks gate: tests red -> NOT implemented"
( setup "$ROOT/b" 1
  printf '1\n' > "$STUBDIR/verify_rc"          # tests fail
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = ready ] && ok "TDD left ready (flip refused)" || bad "TDD must stay ready when verify fails (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$R" "FAIL verification" "report shows verification failure"
) || true

echo "[C] review gate: persistent review BLOCK -> bounded rework exhausts -> NOT implemented"
( setup "$ROOT/c" 1
  # Review always blocks and the default rework is a no-op (empty diff), so the
  # bounded loop ships nothing, exhausts its attempt budget (TDD 0019 / FR-65),
  # and the TDD halts BLOCKED — never flipped (ADR 0007 supersedes first-failure
  # halt; a review BLOCK now drives the rework loop, not an immediate FAIL).
  printf 'REVIEW_RESULT: BLOCK found a real bug\n' > "$STUBDIR/review-0001-alpha"
  THROUGHLINE_REWORK_MAX=2 bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = ready ] && ok "TDD left ready (review blocked flip)" || bad "TDD must stay ready when review blocks (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$R" "BLOCKED review" "report shows the rework loop halted the review gate"
) || true

echo "[D] downstream halt: first TDD fails verify -> second BLOCKED, not attempted"
( setup "$ROOT/d" 2
  printf '1\n' > "$STUBDIR/verify_rc"          # 0001 fails verify
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = ready ] && ok "first TDD left ready (verify failed)" || bad "first TDD must stay ready when verify fails"
  has "$R" "0002-beta — BLOCKED (upstream" "report marks downstream BLOCKED"
  git rev-parse --verify ci/0002-beta >/dev/null 2>&1 && bad "downstream build should NOT have run (branch ci/0002-beta exists)" || ok "downstream build was skipped (no branch created)"
) || true

echo "[E] design blocker: BATCH_RESULT BLOCKED -> BLOCKERS.md ledger + halt"
( setup "$ROOT/e" 2
  printf 'BATCH_RESULT: BLOCKED requirement needs a new ADR\n' > "$STUBDIR/build-0001-alpha"
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ -f docs/tdd/BLOCKERS.md ] && ok "BLOCKERS.md ledger created in main repo" || bad "BLOCKERS.md should be created in the main repo"
  has docs/tdd/BLOCKERS.md "0001-alpha" "blocker ledger names the TDD"
  has "$R" "BLOCKED (design)" "report shows design blocker"
  has "$R" "run /tdd-author" "report points back to /tdd-author"
) || true

echo "[F] resume: re-run skips a TDD already built on an un-merged branch"
( setup "$ROOT/f" 1
  bash "$IMPL" --change ci  >/dev/null 2>&1     # run 1 builds 0001 on ci/0001-alpha
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = implemented ] && ok "run 1 built it" || bad "run 1 should build it"
  bash "$IMPL" --change ci2 >/dev/null 2>&1     # run 2 must SKIP (done-but-unmerged)
  R="$(report)"
  has "$R" "already built on" "re-run reports the TDD as already built"
  git rev-parse --verify ci2/0001-alpha >/dev/null 2>&1 && bad "re-run must NOT create a duplicate branch (ci2/0001-alpha exists)" || ok "re-run created no duplicate branch"
) || true

echo "[G] --rebuild forces a fresh build even when already built"
( setup "$ROOT/g" 1
  bash "$IMPL" --change ci  >/dev/null 2>&1
  bash "$IMPL" --change ci2 --rebuild >/dev/null 2>&1
  R="$(report)"
  hasnt "$R" "already built on" "rebuild run does not skip"
  git rev-parse --verify ci2/0001-alpha >/dev/null 2>&1 && ok "rebuild created a fresh branch" || bad "rebuild should create ci2/0001-alpha"
  [ "$(status_on docs/tdd/0001-alpha.md ci2/0001-alpha)" = implemented ] && ok "rebuild branch is implemented" || bad "rebuild branch should be implemented"
) || true

echo "[H] stacked PRs: report emits a bottom-up merge plan"
( setup "$ROOT/h" 2
  git init --bare -q "$ROOT/h-remote.git"
  git remote add origin "$ROOT/h-remote.git"
  git push -q -u origin HEAD >/dev/null 2>&1     # publish base so PRs have a base
  cat > "$STUBDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
# shadow any real gh; only `gh pr create` is exercised — echo a deterministic URL
echo "https://example.test/pr/$RANDOM"
EOF
  chmod +x "$STUBDIR/bin/gh"
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  has "$R" "Merge plan (stacked PRs" "report includes a merge plan"
  has "$R" "SQUASH-merge rewrites" "merge plan warns about squash-merge"
  has "$R" "^1\. https://example.test/pr/" "merge plan lists PR 1 (base BASE)"
  has "$R" "^2\. https://example.test/pr/" "merge plan lists PR 2 (stacked)"
  has "$R" "(base ci/0001-alpha)" "PR 2 is based on the first TDD's branch (stacked)"
) || true

echo "[I] lint gate: linter red -> NOT implemented (verify covers lint, not just tests/typecheck)"
( setup "$ROOT/i" 1
  export CI_CHECKS_LINT_CMD=false                  # linter fails (tests still pass)
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = ready ] && ok "TDD left ready (lint blocked flip)" || bad "TDD must stay ready when lint fails (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$R" "FAIL verification" "report shows verification failure on lint"
) || true

echo "[J] test-first gate: no failing-test-first commit -> NOT implemented"
( setup "$ROOT/j" 1
  touch "$STUBDIR/no-test-first-0001-alpha"    # build skips the failing-test commit
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = ready ] && ok "TDD left ready (test-first gate)" || bad "TDD must stay ready without failing-test-first (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$R" "FAIL test-first" "report shows test-first failure"
  git rev-parse --verify ci/0001-alpha >/dev/null 2>&1 && ok "build branch exists but was not flipped" || bad "build branch ci/0001-alpha should exist"
) || true

echo "[K] worktree deps: a JS project's package-manager install runs in the build worktree"
( setup "$ROOT/k" 1
  # A committed JS manifest + pnpm lockfile, so the worktree (cut from BASE) carries them.
  printf '{ "name": "x", "private": true, "version": "0.0.0" }\n' > package.json
  printf 'lockfileVersion: "9.0"\n' > pnpm-lock.yaml
  git add -A; git commit -qm "add js manifest" >/dev/null 2>&1
  # Stub pnpm: record invocations instead of really installing (no network).
  cat > "$STUBDIR/bin/pnpm" <<EOF
#!/usr/bin/env bash
echo "pnpm \$*" >> "$STUBDIR/pm.log"
exit 0
EOF
  chmod +x "$STUBDIR/bin/pnpm"
  bash "$IMPL" --change ci >/dev/null 2>&1
  has "$STUBDIR/pm.log" "install --frozen-lockfile" "worktree install ran via the project's package manager"
  # The TDD still flips: install + stubbed build + verify + review all pass.
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = implemented ] && ok "TDD implemented after worktree deps install" || bad "TDD should be implemented (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
) || true

echo "[L] default draft path: a draft TDD merged to integration builds -> implemented (no manual ready)"
( setup "$ROOT/l" 1 draft
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = implemented ] && ok "draft TDD built and flipped to implemented" || bad "draft TDD should build to implemented (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$R" "OK (verified + reviewed)" "report shows verified+reviewed OK for the draft TDD"
) || true

echo "[M] merge-guard: a TDD absent from the integration branch is NOT built (PR stays the gate)"
( setup "$ROOT/m" 0                               # integration branch has PRD/ADR but NO TDDs
  git checkout -q -b design/x                     # author a TDD only on a design branch
  printf '# TDD 0001: alpha\nStatus: ready\nPRD refs: 1\nPRD-rev: deadbee\nADR constraints: none\n\n## Approach\nstub\n' > docs/tdd/0001-alpha.md
  git add -A; git commit -qm "tdd on un-merged design branch" >/dev/null 2>&1
  bash "$IMPL" --change ci >/dev/null 2>&1        # run while sitting on the un-merged branch
  R="$(report)"
  git rev-parse --verify ci/0001-alpha >/dev/null 2>&1 && bad "un-merged TDD must NOT be built (branch ci/0001-alpha exists)" || ok "un-merged TDD was not built (no build branch)"
  has "$R" "No buildable TDDs" "report says nothing is buildable until merged"
) || true

echo "[N] runtime-verify gate: PASS by default -> implemented; verdict lands between ci-checks and review"
( setup "$ROOT/n" 1
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  L="docs/tdd/.implement-logs/$(ls -t docs/tdd/.implement-logs 2>/dev/null | head -1)/0001-alpha.log"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = implemented ] && ok "TDD flipped to implemented after runtime-verify PASS" || bad "runtime PASS should still flip the TDD (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$L" "VERIFY_RUNTIME: PASS" "log carries the VERIFY_RUNTIME verdict line"
  # ordering: VERIFY_RUNTIME must appear AFTER 'ci-checks: gate PASS' and BEFORE 'REVIEW_RESULT:'
  vsh="$(grep -n 'ci-checks: gate PASS'   "$L" 2>/dev/null | tail -1 | cut -d: -f1)"
  vrt="$(grep -n 'VERIFY_RUNTIME: PASS' "$L" 2>/dev/null | tail -1 | cut -d: -f1)"
  rvw="$(grep -n 'REVIEW_RESULT: PASS'  "$L" 2>/dev/null | tail -1 | cut -d: -f1)"
  if [ -n "$vsh" ] && [ -n "$vrt" ] && [ -n "$rvw" ] && [ "$vsh" -lt "$vrt" ] && [ "$vrt" -lt "$rvw" ]; then
    ok "gate ordering: ci-checks.sh -> runtime-verify -> review"
  else
    bad "gate ordering wrong (ci-checks.sh @${vsh:-?} runtime-verify @${vrt:-?} review @${rvw:-?})"
  fi
) || true

echo "[O] runtime-verify gate: FAIL -> NOT implemented"
( setup "$ROOT/o" 1
  printf 'VERIFY_RUNTIME: FAIL surface produced wrong value\n' > "$STUBDIR/runtime-0001-alpha"
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = ready ] && ok "TDD left ready (runtime-verify blocked flip)" || bad "TDD must stay ready when runtime-verify FAILs (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$R" "FAIL runtime-verify" "report shows runtime-verify failure"
) || true

echo "[P] runtime-verify gate: BLOCKED -> NOT implemented; ledger NOT touched (distinct from design BLOCKED)"
( setup "$ROOT/p" 1
  printf 'VERIFY_RUNTIME: BLOCKED missing tooling to drive artifact\n' > "$STUBDIR/runtime-0001-alpha"
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = ready ] && ok "TDD left ready (runtime-verify BLOCKED)" || bad "TDD must stay ready on runtime-verify BLOCKED (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$R" "BLOCKED runtime-verify" "report shows runtime-verify BLOCKED (distinct from FAIL)"
  [ -f docs/tdd/BLOCKERS.md ] && bad "runtime BLOCKED must NOT append to BLOCKERS.md (only build BATCH_RESULT: BLOCKED does)" || ok "BLOCKERS.md not touched by a runtime-verify BLOCKED"
) || true

echo "[Q] runtime-verify gate: SKIP (justified) -> implemented"
( setup "$ROOT/q" 1
  printf 'VERIFY_RUNTIME: SKIP pure internal refactor; no observable surface\n' > "$STUBDIR/runtime-0001-alpha"
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = implemented ] && ok "TDD flipped after justified SKIP" || bad "justified SKIP should still flip (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
) || true

echo "[R] runtime-verify gate: ambiguous (no verdict line) -> treated as FAIL (never a false PASS)"
( setup "$ROOT/r" 1
  printf 'I am uncertain and emit no verdict line at all.\n' > "$STUBDIR/runtime-0001-alpha"
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = ready ] && ok "TDD left ready when verdict is missing (NFR-4: ambiguity resolves to FAIL)" || bad "missing verdict line must NOT flip (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$R" "FAIL runtime-verify" "report classes missing-verdict as runtime-verify FAIL"
) || true

echo "[S] env toggle: THROUGHLINE_REQUIRE_RUNTIME_VERIFY=0 -> gate is skipped wholesale"
( setup "$ROOT/s" 1
  printf 'VERIFY_RUNTIME: FAIL stub would fail\n' > "$STUBDIR/runtime-0001-alpha"
  THROUGHLINE_REQUIRE_RUNTIME_VERIFY=0 bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  L="docs/tdd/.implement-logs/$(ls -t docs/tdd/.implement-logs 2>/dev/null | head -1)/0001-alpha.log"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = implemented ] && ok "toggle=0 lets the TDD flip without the runtime gate" || bad "with toggle=0 the TDD should flip (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  grep -q 'VERIFY_RUNTIME:' "$L" 2>/dev/null && bad "toggle=0 should skip the gate (no VERIFY_RUNTIME line expected)" || ok "no runtime gate invocation under the toggle"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== gate eval: $PASS passed, $FAIL failed ==="

# Run the run-progress-visibility eval (TDD 0008 / FR-27..FR-30) as part of the
# same suite — CI_CHECKS_TEST_CMD points at this file only, and the progress-record
# + status-renderer evals are runner-adjacent quality gates that belong here.
RPV="$(dirname "$0")/run-progress-visibility.test.sh"
RPV_FAIL=0
if [ -f "$RPV" ]; then
  echo
  bash "$RPV" || RPV_FAIL=1
fi

# Run the token-spend-reduction eval (TDD 0013 / FR-51 + FR-52) as part of the
# same suite. Same rationale: it tests runner-adjacent helpers (tdd-lint,
# plan-classifier) plus verify_runtime_one's tiering, all part of the gate
# scaffolding that CI_CHECKS_TEST_CMD exercises in CI.
TSR="$(dirname "$0")/token-spend-reduction.test.sh"
TSR_FAIL=0
if [ -f "$TSR" ]; then
  echo
  bash "$TSR" || TSR_FAIL=1
fi

# Run the bounded-tdd-scope eval (TDD 0014 / FR-53..FR-55) as part of the same
# suite. Same rationale: it tests the scope-bound checks added to tdd-lint.sh
# plus the design-time refusal/critique wiring — gate scaffolding that
# CI_CHECKS_TEST_CMD exercises in CI.
BTS="$(dirname "$0")/bounded-tdd-scope.test.sh"
BTS_FAIL=0
if [ -f "$BTS" ]; then
  echo
  bash "$BTS" || BTS_FAIL=1
fi

# Run the state-module-sourceability eval (TDD 0015 / FR-69) as part of the same
# suite. Pins the contract of the extracted scripts/lib/state.sh: it must source
# in isolation, and a missing or unreadable module must cause implement.sh to
# FAIL FAST rather than proceed silently with every state-tracking function
# undefined.
SMS="$(dirname "$0")/state-module-sourceability.test.sh"
SMS_FAIL=0
if [ -f "$SMS" ]; then
  echo
  bash "$SMS" || SMS_FAIL=1
fi

# Run the pause-retry-module-sourceability eval (TDD 0016 / FR-69) as part of the
# same suite. Pins the contract of the extracted scripts/lib/pause-retry.sh: it
# must source in isolation (after state.sh), and a missing or unreadable module
# must cause implement.sh to FAIL FAST rather than proceed silently with every
# pause/retry-classification function undefined.
PRM="$(dirname "$0")/pause-retry-module-sourceability.test.sh"
PRM_FAIL=0
if [ -f "$PRM" ]; then
  echo
  bash "$PRM" || PRM_FAIL=1
fi

# Run the gates-resume-module-sourceability eval (TDD 0017 / FR-69) as part of
# the same suite. Pins the contract of the extracted scripts/lib/gates.sh +
# scripts/lib/resume.sh: each must source in isolation (gates.sh after state.sh
# + pause-retry.sh; resume.sh after all three), and a missing or unreadable
# module must cause implement.sh to FAIL FAST rather than proceed silently with
# every gate-executor / resume function undefined.
GRM="$(dirname "$0")/gates-resume-module-sourceability.test.sh"
GRM_FAIL=0
if [ -f "$GRM" ]; then
  echo
  bash "$GRM" || GRM_FAIL=1
fi

# Run the bounded-rework-loop eval (TDD 0019 / FR-61, FR-62, FR-65, FR-66,
# FR-67, FR-68) as part of the same suite — it exercises the rework loop's
# config snapshot, telemetry, scope/structural pre-pass, and the gate_one
# review-gate wiring, all runner-adjacent gate scaffolding.
BRL="$(dirname "$0")/bounded-rework-loop.test.sh"
BRL_FAIL=0
if [ -f "$BRL" ]; then
  echo
  bash "$BRL" || BRL_FAIL=1
fi

# Run the structural-classification-bound eval (TDD 0034 / FR-67 gap-closure,
# FR-62, FR-66) as part of the same suite — it pins the review-prompt
# structural_reason field + tightened definition and the runner's (c)-escalation
# gating (a named reason escalates; an in-scope unnamed structural routes to
# bounded rework), so a regression in either surface fails here under ci-checks
# rather than in a real build.
SCB="$(dirname "$0")/structural-classification-bound.test.sh"
SCB_FAIL=0
if [ -f "$SCB" ]; then
  echo
  bash "$SCB" || SCB_FAIL=1
fi

# Run the run-recovery eval (TDD 0011 / FR-39..FR-45 + TDD 0019 carry-over
# fail-loud fixes) as part of the same suite so the resume + carry-over
# fixtures are gated by CI, not orphaned from the aggregator.
RR="$(dirname "$0")/run-recovery.test.sh"
RR_FAIL=0
if [ -f "$RR" ]; then
  echo
  bash "$RR" || RR_FAIL=1
fi

# Run the build-coprocess-lifecycle eval (TDD 0025 / FR-56 mechanism) as part
# of the same suite — it pins the stdin-close-on-BATCH_RESULT lifecycle so a
# regression deadlocks here (rc=143 in the eval) instead of in a real build
# (where the symptom is `paused: transient` after the inter-event watchdog).
BCL="$(dirname "$0")/build-coprocess-lifecycle.test.sh"
BCL_FAIL=0
if [ -f "$BCL" ]; then
  echo
  bash "$BCL" || BCL_FAIL=1
fi

# Run the build-observability eval (TDD 0010 / FR-36..FR-38) as part of the same
# suite so the gate-log session pointer (record_session_pointer) and the build /
# runtime-verify prompt boundaries are regression-gated by ci-checks, not only by
# the standalone runtime-verify gate. Same rationale as the sibling evals above.
BO="$(dirname "$0")/build-observability.test.sh"
BO_FAIL=0
if [ -f "$BO" ]; then
  echo
  bash "$BO" || BO_FAIL=1
fi

# Run the interactive-draft-persistence eval (TDD 0012 / FR-46..FR-50) as part of
# the same suite so the draft helper (scripts/lib/drafts.sh) AND the prd-author /
# tdd-author prompt-edit wiring are regression-gated by ci-checks, not orphaned
# from the aggregator. Same rationale as the sibling evals above.
IDP="$(dirname "$0")/interactive-draft-persistence.test.sh"
IDP_FAIL=0
if [ -f "$IDP" ]; then
  echo
  bash "$IDP" || IDP_FAIL=1
fi

# Run the runner-resilience eval (TDD 0027 / FR-39, FR-41, FR-42, FR-43, NFR-4)
# as part of the same suite — it pins the gate-child watchdog, worktree reclaim,
# fast-forward + blocked-state resume, and verdict-before-exit-code ordering, all
# runner-adjacent resilience gates that belong with the other evals above.
RES="$(dirname "$0")/runner-resilience.test.sh"
RES_FAIL=0
if [ -f "$RES" ]; then
  echo
  bash "$RES" || RES_FAIL=1
fi

# Run the coproc-verdict-resilience eval (TDD 0030 / FR-39, FR-42, FR-44, FR-30,
# FR-64, NFR-4) as part of the same suite — it pins the SIGPIPE-safe verdict
# write, unclean-death (orphan) detection + resume, the honest `interrupted`
# rollup, the truthful BLOCKERS.md report tail, and the active-time build
# watchdog, all runner-adjacent resilience gates that belong with the evals above.
CVR="$(dirname "$0")/coproc-verdict-resilience.test.sh"
CVR_FAIL=0
if [ -f "$CVR" ]; then
  echo
  bash "$CVR" || CVR_FAIL=1
fi

# Run the honest-review-scope-structural-resume eval (TDD 0031 / FR-15, FR-39,
# FR-40, FR-57, FR-63, FR-64, FR-67, NFR-4) as part of the same suite — it pins
# the honest consolidated-review base + empty-scope fail-closed (gap A) and the
# revision-resolved structural-halt resume (gap B), all runner-adjacent gates
# that belong with the other evals above.
HRS="$(dirname "$0")/honest-review-scope-structural-resume.test.sh"
HRS_FAIL=0
if [ -f "$HRS" ]; then
  echo
  bash "$HRS" || HRS_FAIL=1
fi

# Run the severity-honest-reporting eval (TDD 0021 / FR-58, FR-60, FR-70, FR-71 +
# issues #35, #28A, #28B) as part of the same suite so the findings-schema state
# I/O, the review/build prompt edits, the diff-vs-narrative + finding-block
# parsers, and the per-file coverage check are regression-gated by ci-checks,
# not orphaned from the aggregator. Same rationale as the sibling evals above.
SHR="$(dirname "$0")/severity-honest-reporting.test.sh"
SHR_FAIL=0
if [ -f "$SHR" ]; then
  echo
  bash "$SHR" || SHR_FAIL=1
fi

# Run the build-phase-learning-capture eval (TDD 0022 / FR-72) as part of the same
# suite so the recurring-pattern detection, the accepted-learning persistence +
# index-based injection-safe acceptance, the run-completion watcher, and the
# run-end hook are regression-gated by ci-checks, not orphaned from the aggregator.
# Same rationale as the sibling evals above.
BPL="$(dirname "$0")/build-phase-learning-capture.test.sh"
BPL_FAIL=0
if [ -f "$BPL" ]; then
  echo
  bash "$BPL" || BPL_FAIL=1
fi

# Run the build-defensive-norms eval (TDD 0026 / FR-74) as part of the same
# suite so the build-norms source-of-truth file, the {{BUILD_NORMS}} render
# substitution (fail-loud on a missing norms file), and the BLOCK-only norms
# reminder are regression-gated by ci-checks, not orphaned from the aggregator.
# Same rationale as the sibling evals above.
BDN="$(dirname "$0")/build-defensive-norms.test.sh"
BDN_FAIL=0
if [ -f "$BDN" ]; then
  echo
  bash "$BDN" || BDN_FAIL=1
fi

# Run the interrogator-discipline eval (TDD 0028 / FR-75, FR-76) as part of the
# same suite so the prd-author / tdd-author interrogator instruction blocks (the
# interrogator posture + anti-sycophancy + OPEN ASSUMPTIONS tracking + resolve-or-
# waive completion gate + "Open assumptions & waivers" PR-body record) are
# regression-gated by ci-checks, not orphaned from the aggregator. Same rationale
# as the sibling evals above.
IDISC="$(dirname "$0")/interrogator-discipline.test.sh"
IDISC_FAIL=0
if [ -f "$IDISC" ]; then
  echo
  bash "$IDISC" || IDISC_FAIL=1
fi

# Run the evaluation-rubric eval (TDD 0029 / FR-77) as part of the same suite so
# the prd-author / tdd-author rubric-co-creation phase blocks, the '## Evaluation
# rubric' template lines, and the design-reviewer rubric-consumption section are
# regression-gated by ci-checks, not orphaned from the aggregator. Same rationale
# as the sibling evals above.
ERC="$(dirname "$0")/evaluation-rubric.test.sh"
ERC_FAIL=0
if [ -f "$ERC" ]; then
  echo
  bash "$ERC" || ERC_FAIL=1
fi

# Run the step-commit-protocol eval (TDD 0032 / FR-51, FR-56, FR-42, FR-41,
# NFR-4) as part of the same suite so the tl_lint_sequencing label check, the
# build-prompt/SKILL.md protocol text, the _sequencing_labels_ok pre-flight, and
# the runtime malformed-sentinel branch (fail-loud correction + fatal exhaustion)
# are regression-gated by ci-checks, not orphaned from the aggregator. Same
# rationale as the sibling evals above.
SCP="$(dirname "$0")/step-commit-protocol.test.sh"
SCP_FAIL=0
if [ -f "$SCP" ]; then
  echo
  bash "$SCP" || SCP_FAIL=1
fi

# Run the integration-merge-on-resume eval (TDD 0033 / FR-40, FR-41, FR-39,
# FR-15, FR-64, NFR-4) as part of the same suite so the _fetch_integration helper
# and the broadened resume-merge block (integration merged into the build branch
# on every accepted resume, with the conflict-refusal contract) are regression-
# gated by ci-checks, not orphaned from the aggregator. Same rationale — and same
# one-line registration shape — as the ~20 sibling evals above: this is test-
# harness registration of an already-green eval, not product behavior. The
# feature's behavior was driven failing-test-first in its own steps (the
# _fetch_integration parsing/guard cases and the broadened-merge cases each landed
# as a `test(failing):` red before their implementation in steps 1–2).
IMR="$(dirname "$0")/integration-merge-on-resume.test.sh"
IMR_FAIL=0
if [ -f "$IMR" ]; then
  echo
  bash "$IMR" || IMR_FAIL=1
fi

# Run the runtime-verify-resume eval (TDD 0035 / FR-40, FR-41, FR-63, FR-64,
# NFR-4) as part of the same suite so the verify-unobservable halt-cause enum
# entry, the gate_one resumable-halt recording, and the _resume_from
# verify-plan-unrevised guard are regression-gated by ci-checks, not orphaned
# from the aggregator. Same rationale — and same one-line registration shape —
# as the sibling evals above: this is test-harness registration of an
# already-green eval, not product behavior. The feature's behavior was driven
# failing-test-first in its own steps (the enum/render, the gate_one recording,
# and the unrevised-refuse/revised-accept resume cases each landed as a
# `test(failing):` red before their implementation in steps 1–4).
RVR="$(dirname "$0")/runtime-verify-resume.test.sh"
RVR_FAIL=0
if [ -f "$RVR" ]; then
  echo
  bash "$RVR" || RVR_FAIL=1
fi

# Run the watcher-inactivity-completion eval (TDD 0036 / FR-72, FR-39, NFR-4) as
# part of the same suite so the inactivity-based watcher poll loop, the distinct
# watcher-timeout wedge state, and the SKILL.md non-terminal-state callback are
# regression-gated by ci-checks, not orphaned from the aggregator. Same rationale
# — and same one-line registration shape — as the sibling evals above: this is
# test-harness registration of an already-green eval, not product behavior. The
# feature's behavior was driven failing-test-first in its own steps (the §1
# inactivity-exit, the §2-§4 distinct-state/passthrough, and the §5 SKILL.md grep
# cases each landed as a `test(failing):` red before their implementation in
# steps 1-3).
WIC="$(dirname "$0")/watcher-inactivity-completion.test.sh"
WIC_FAIL=0
if [ -f "$WIC" ]; then
  echo
  bash "$WIC" || WIC_FAIL=1
fi

# Run the recoverable-terminal-halts eval (TDD 0039 / FR-39, FR-40, NFR-4) as part
# of the same suite so the --recover flag parse, the _resume_from recovery arms
# (rework-budget-exhausted / ci-checks-failed) + divergence re-baseline,
# _reset_rework_attempts, and the status.sh --check-paused resumable=recoverable
# surfacing are regression-gated by ci-checks, not orphaned from the aggregator.
# Same rationale — and same one-line registration shape — as the sibling evals
# above: this is test-harness registration of an already-green eval, not product
# behavior. The feature's behavior was driven failing-test-first in its own steps
# (the flag/diagnostic, the budget-reset helper, the recovery arms + divergence
# re-baseline, the check-paused surfacing, and the SKILL.md docs each landed as a
# `test(failing):` red before their implementation in steps 1–5).
RTH="$(dirname "$0")/recoverable-terminal-halts.test.sh"
RTH_FAIL=0
if [ -f "$RTH" ]; then
  echo
  bash "$RTH" || RTH_FAIL=1
fi

# Run the test-first-per-step eval (TDD 0038 / FR-15(a) per-step enforcement;
# ADR 0005, 0006, 0007) as part of the same suite so the mechanical per-step
# test-first pre-check (_test_first_ok_range + the _per_step_review_loop wiring),
# the build-prompt self-gate + aggregator wire-in rule, and the four reconciled
# fixtures' default-on non-regression are gated by ci-checks, not orphaned from
# the aggregator. Per the TDD 0038 §3 wire-in rule this registration is new
# gating behavior — its failing wire-in test (the eval's §8 dogfood) drove the
# AND-chain term below red→green before this block landed.
TFP="$(dirname "$0")/test-first-per-step.test.sh"
TFP_FAIL=0
if [ -f "$TFP" ]; then
  echo
  bash "$TFP" || TFP_FAIL=1
fi

# Run the transient-gate-resilience eval (TDD 0040 / FR-15, FR-57, NFR-4; ADR
# 0004, 0006, 0007) as part of the same suite so the ci-checks retry-once loop
# (Component 1), the gate-unobservable no-verdict classification + the gate-agnostic
# _classify_gate_no_verdict / _gate_output_tail helpers (Component 2), and the
# closed-enum + status-render mirror for gate-unobservable (Component 3) are
# regression-gated by ci-checks, not orphaned from the aggregator. Per the
# TDD 0038 §3 wire-in rule this registration is new gating behavior — its failing
# wire-in test (the eval's §W dogfood) drove the AND-chain term below red→green
# before this block landed.
TGR="$(dirname "$0")/transient-gate-resilience.test.sh"
TGR_FAIL=0
if [ -f "$TGR" ]; then
  echo
  bash "$TGR" || TGR_FAIL=1
fi

# Run the bounded-rework-convergence eval (TDD 0041 / FR-65, FR-66, FR-67 incl.
# the (b)-tolerance gap-closure, FR-58, FR-59, FR-53; ADR 0005, 0006, 0007) as
# part of the same suite so the convergence-budget rollback on scope rejection
# (Component 1), the binding-rule-sweep prompt rule (Component 2), the sweep-aware
# scope-cap read (Component 3), the K-tolerance per-file (b) escalation (Component
# 4), and the authoring-padding heuristic (Component 5) are regression-gated by
# ci-checks, not orphaned from the aggregator. Per the TDD 0038 §3 wire-in rule
# this registration is new gating behavior — its failing wire-in test (the eval's
# §W dogfood) drove the AND-chain term below red→green before this block landed.
BRC="$(dirname "$0")/bounded-rework-convergence.test.sh"
BRC_FAIL=0
if [ -f "$BRC" ]; then
  echo
  bash "$BRC" || BRC_FAIL=1
fi

# Run the coverage-map eval (TDD 0044 / FR-78; ADR 0004, 0005, 0006) as part of
# the same suite so the review-prompt COVERAGE_MAP section, the
# coverage_map_block / coverage_map_normalize extractors with both
# model-independent pinned downgrades, the write_coverage_report report.md
# section (idempotent per-slug replace + advisory legend), and the
# _pr_coverage_pointer PR-comment pointer are regression-gated by ci-checks,
# not orphaned from the aggregator. Per the TDD 0038 §3 wire-in rule this
# registration is new gating behavior — its failing wire-in test (the eval's
# §W dogfood) drove the AND-chain term below red→green before this block landed.
CMAP="$(dirname "$0")/coverage-map.test.sh"
CMAP_FAIL=0
if [ -f "$CMAP" ]; then
  echo
  bash "$CMAP" || CMAP_FAIL=1
fi

# Run the review-lenses eval (TDD 0045 / FR-10, FR-15(d), FR-15; ADR 0005, 0006)
# as part of the same suite so the review prompt's intent-conformance +
# policy-shadow lenses and the pinned verdict-contract control are
# regression-gated by ci-checks, not orphaned from the aggregator. Per the
# TDD 0038 §3 wire-in rule this registration is new gating behavior — its
# failing wire-in test (the eval's §W dogfood) drove the AND-chain term below
# red→green before this block landed.
RLNS="$(dirname "$0")/review-lenses.test.sh"
RLNS_FAIL=0
if [ -f "$RLNS" ]; then
  echo
  bash "$RLNS" || RLNS_FAIL=1
fi

# Run the surgical-norm eval (TDD 0046 / FR-66, FR-74; ADR 0005, 0007, 0008)
# as part of the same suite so the build prompt's surgical-changes norm (with
# its required-changes carve-out) and the rework prompt's single-finding-scope
# echo are regression-gated by ci-checks, not orphaned from the aggregator.
# Per the TDD 0038 §3 wire-in rule this registration is new gating behavior —
# its failing wire-in test (the eval's §W dogfood) drove the AND-chain term
# below red→green before this block landed.
SRG="$(dirname "$0")/surgical-norm.test.sh"
SRG_FAIL=0
if [ -f "$SRG" ]; then
  echo
  bash "$SRG" || SRG_FAIL=1
fi

# Run the tdd-author-redteam eval (TDD 0047 / FR-76; ADR 0006) as part of the
# same suite so the tdd-author skill's red-team assumption-ranking guidance
# and the pre-mortem failure-mode taxonomy (note + self-review line, with the
# tdd-lint-unchanged control) are regression-gated by ci-checks, not orphaned
# from the aggregator. Per the TDD 0038 §3 wire-in rule this registration is
# new gating behavior — its failing wire-in test (the eval's §W dogfood) drove
# the AND-chain term below red→green before this block landed.
RTM="$(dirname "$0")/tdd-author-redteam.test.sh"
RTM_FAIL=0
if [ -f "$RTM" ]; then
  echo
  bash "$RTM" || RTM_FAIL=1
fi

# Run the md-parser eval (TDD 0055 / FR-52, FR-53, FR-54, FR-67) as part of the
# same suite so the unified scripts/lib/md.sh section/bullet parsers (fence-aware
# ```+~~~, A21/A23 anchor, L-005 rc propagation) are regression-gated by ci-checks,
# not orphaned from the aggregator. Same one-line registration shape as the sibling
# evals above; the AND-chain term below makes its failure fail the gate.
MDP="$(dirname "$0")/md-parser.test.sh"
MDP_FAIL=0
if [ -f "$MDP" ]; then
  echo
  bash "$MDP" || MDP_FAIL=1
fi

# Run the gate-effort eval (hardcoded per-gate --effort levels) as part of the
# same suite so the _gate_effort mapping (build/rework/review xhigh on
# fable/opus, verify high, sonnet capped at high, empty model → no flag) and
# the six spawn-site wirings are regression-gated by ci-checks, not orphaned
# from the aggregator. Per the TDD 0038 §3 wire-in rule this registration is
# new gating behavior — its failing wire-in test (the eval's §W dogfood) drove
# the AND-chain term below red→green before this block landed.
GEF="$(dirname "$0")/gate-effort.test.sh"
GEF_FAIL=0
if [ -f "$GEF" ]; then
  echo
  bash "$GEF" || GEF_FAIL=1
fi

# Run the detached-run-recovery eval (TDD 0054 A25 / FR-39) as part of the same
# suite so the single-run lock's PID+start-token identity check (reused-PID
# stale-break, the fail-safe holds, the PID-only old-lock fallback, and
# status.sh's first-field ACTIVE parse) is regression-gated by ci-checks, not
# orphaned from the aggregator. Per the TDD 0038 §3 wire-in rule this
# registration is new gating behavior — its failing wire-in test (the eval's §W
# dogfood) drove the AND-chain term below red→green before this block landed.
DRR="$(dirname "$0")/detached-run-recovery.test.sh"
DRR_FAIL=0
if [ -f "$DRR" ]; then
  echo
  bash "$DRR" || DRR_FAIL=1
fi

# Run the json-helper eval (TDD 0050 / FR-27, FR-39, FR-46, FR-69, FR-72) as
# part of the same suite so the canonical scripts/lib/json.sh helpers
# (tl_json_escape C0-complete escaper, tl_json_array/_ws compact builders,
# tl_json_field quote-aware reader), the five consumers' delegation wiring,
# and the A11/A3/A10/A5 regressions are regression-gated by ci-checks, not
# orphaned from the aggregator. Per the TDD 0038 §3 wire-in rule this
# registration is new gating behavior — its failing wire-in test (the eval's
# §W dogfood) drove the AND-chain term below red→green before this block
# landed.
JSH="$(dirname "$0")/json-helper.test.sh"
JSH_FAIL=0
if [ -f "$JSH" ]; then
  echo
  bash "$JSH" || JSH_FAIL=1
fi

# TDD 0052 (FR-16/FR-19/FR-27/FR-69; bugs A8/A6/A7): the gated-implementation
# eval pins the single _publish_pr publish path (push/create CLI lives only in
# the helper; loud rc 1/2 + fd-2 diagnostics surfaced in all three modes) and
# the loud combined-checkout (A6) + install_deps (A7) precondition failures.
# Registered here so the publish/precondition regressions are gated by
# ci-checks, not orphaned from the aggregator. Per the TDD 0038 §3 wire-in
# rule this registration is new gating behavior — its failing wire-in test
# (the eval's §W dogfood) drove the AND-chain term below red→green before
# this block landed.
GIM="$(dirname "$0")/gated-implementation.test.sh"
GIM_FAIL=0
if [ -f "$GIM" ]; then
  echo
  bash "$GIM" || GIM_FAIL=1
fi

[ "$FAIL" -eq 0 ] && [ "$RPV_FAIL" -eq 0 ] && [ "$TSR_FAIL" -eq 0 ] && [ "$BTS_FAIL" -eq 0 ] && [ "$SMS_FAIL" -eq 0 ] && [ "$PRM_FAIL" -eq 0 ] && [ "$GRM_FAIL" -eq 0 ] && [ "$BRL_FAIL" -eq 0 ] && [ "$SCB_FAIL" -eq 0 ] && [ "$RR_FAIL" -eq 0 ] && [ "$BCL_FAIL" -eq 0 ] && [ "$BO_FAIL" -eq 0 ] && [ "$IDP_FAIL" -eq 0 ] && [ "$RES_FAIL" -eq 0 ] && [ "$CVR_FAIL" -eq 0 ] && [ "$HRS_FAIL" -eq 0 ] && [ "$SHR_FAIL" -eq 0 ] && [ "$BPL_FAIL" -eq 0 ] && [ "$BDN_FAIL" -eq 0 ] && [ "$IDISC_FAIL" -eq 0 ] && [ "$ERC_FAIL" -eq 0 ] && [ "$SCP_FAIL" -eq 0 ] && [ "$IMR_FAIL" -eq 0 ] && [ "$RVR_FAIL" -eq 0 ] && [ "$WIC_FAIL" -eq 0 ] && [ "$RTH_FAIL" -eq 0 ] && [ "$TFP_FAIL" -eq 0 ] && [ "$TGR_FAIL" -eq 0 ] && [ "$BRC_FAIL" -eq 0 ] && [ "$CMAP_FAIL" -eq 0 ] && [ "$RLNS_FAIL" -eq 0 ] && [ "$SRG_FAIL" -eq 0 ] && [ "$RTM_FAIL" -eq 0 ] && [ "$MDP_FAIL" -eq 0 ] && [ "$GEF_FAIL" -eq 0 ] && [ "$DRR_FAIL" -eq 0 ] && [ "$JSH_FAIL" -eq 0 ] && [ "$GIM_FAIL" -eq 0 ]

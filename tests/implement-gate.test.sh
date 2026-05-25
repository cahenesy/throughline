#!/usr/bin/env bash
# implement-gate.test.sh — eval for the build runner's quality gates.
#
# The kit's core quality claim is that a build cannot mark itself "done": the
# ready->implemented flip is gated on failing-test-first discipline, an INDEPENDENT
# mechanical verify (tests+typecheck+lint), and an INDEPENDENT review process, and
# a failure halts the dependent stack. This eval proves those gates actually fire,
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

# Build a fresh project: <dir> <ntdds>. Installs a stub `claude` and a
# controllable verify command on PATH/env; returns with PWD inside <dir>.
setup() {
  local dir="$1" n="$2" i
  mkdir -p "$dir"/{docs/tdd,docs/adr,.stub/bin}
  cd "$dir"
  git init -q; git config user.email t@t.t; git config user.name t
  printf '# PRD\n## Requirements\n1. do the thing\n' > docs/PRD.md
  printf '# ADR Index\n| # | Title | Status | Scope |\n|---|---|---|---|\n' > docs/adr/INDEX.md
  local names=(alpha beta gamma)
  for ((i=1;i<=n;i++)); do
    printf '# TDD %04d: %s\nStatus: ready\nPRD refs: 1\nPRD-rev: deadbee\nADR constraints: none\n\n## Approach\nstub\n' \
      "$i" "${names[$((i-1))]}" > "docs/tdd/$(printf '%04d' "$i")-${names[$((i-1))]}.md"
  done
  git add -A; git commit -qm init

  export STUBDIR="$dir/.stub"
  printf '0\n' > "$STUBDIR/verify_rc"          # default: tests pass
  # controllable verify command (read by scripts/verify.sh via VERIFY_TEST_CMD)
  cat > "$STUBDIR/verify_test.sh" <<EOF
#!/usr/bin/env bash
exit "\$(cat "$STUBDIR/verify_rc" 2>/dev/null || echo 0)"
EOF
  export VERIFY_TEST_CMD="bash $STUBDIR/verify_test.sh"
  export VERIFY_TYPECHECK_CMD=""               # explicitly skip typecheck

  # stub `claude`: simulates a build (commits a file) or a review, emitting the
  # control line for the TDD's slug (defaults: build OK, review PASS).
  cat > "$STUBDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; *) shift;; esac; done
slug="$(printf '%s' "$prompt" | grep -oE 'docs/tdd/[0-9]+-[a-z]+' | head -1 | sed 's#docs/tdd/##')"
if printf '%s' "$prompt" | grep -q 'INDEPENDENT review gate'; then
  cat "$STUBDIR/review-$slug" 2>/dev/null || echo "REVIEW_RESULT: PASS"
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

echo "[B] verify gate: tests red -> NOT implemented"
( setup "$ROOT/b" 1
  printf '1\n' > "$STUBDIR/verify_rc"          # tests fail
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = ready ] && ok "TDD left ready (flip refused)" || bad "TDD must stay ready when verify fails (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$R" "FAIL verification" "report shows verification failure"
) || true

echo "[C] review gate: review BLOCK -> NOT implemented"
( setup "$ROOT/c" 1
  printf 'REVIEW_RESULT: BLOCK found a real bug\n' > "$STUBDIR/review-0001-alpha"
  bash "$IMPL" --change ci >/dev/null 2>&1
  R="$(report)"
  [ "$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)" = ready ] && ok "TDD left ready (review blocked flip)" || bad "TDD must stay ready when review blocks (got '$(status_on docs/tdd/0001-alpha.md ci/0001-alpha)')"
  has "$R" "FAIL review" "report shows review block"
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
  export VERIFY_LINT_CMD=false                  # linter fails (tests still pass)
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

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== gate eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

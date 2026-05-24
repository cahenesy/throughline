#!/usr/bin/env bash
# verify.sh — the mechanical verification gate.
#
# Runs the project's test suite, typecheck, and linter; exits 0 ONLY if all pass.
# implement.sh calls this independently AFTER a build process claims success, so
# the `ready -> implemented` flip is gated on a real, deterministic check rather
# than on the model's own `BATCH_RESULT: OK`. "Done" is verified, not asserted.
#
# Detection is best-effort per language. Override it explicitly for any project:
#   VERIFY_TEST_CMD="<cmd>"        run this for tests (empty string = skip tests)
#   VERIFY_TYPECHECK_CMD="<cmd>"   run this for the typecheck (empty = skip)
#   VERIFY_LINT_CMD="<cmd>"        run this for the linter (empty = skip lint)
# A command set to a non-empty string is run via `sh -c`. Setting a var to the
# empty string explicitly skips that stage.
#
# If nothing can be detected AND no override is given, this FAILS by default —
# an unverifiable build is not a verified build. Set VERIFY_ALLOW_EMPTY=1 to
# treat "nothing to run" as a pass (e.g. a docs-only repo).
set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

# Overrides win. Use a sentinel so an explicitly-empty override means "skip",
# distinct from "unset, please detect".
TEST_CMD="${VERIFY_TEST_CMD-__detect__}"
TYPE_CMD="${VERIFY_TYPECHECK_CMD-__detect__}"
LINT_CMD="${VERIFY_LINT_CMD-__detect__}"

if [ "$TEST_CMD" = "__detect__" ] || [ "$TYPE_CMD" = "__detect__" ] || [ "$LINT_CMD" = "__detect__" ]; then
  det_test=""; det_type=""; det_lint=""
  if [ -f package.json ]; then
    grep -q '"test"[[:space:]]*:' package.json 2>/dev/null && det_test="npm test --silent"
    [ -f tsconfig.json ] && det_type="npx --no-install tsc --noEmit"
    # eslint only if the project actually configures it (mirrors the lint hook).
    # Respect the project's configured rule severities — no --max-warnings.
    if ls .eslintrc* eslint.config.* >/dev/null 2>&1 \
       || grep -q '"eslintConfig"' package.json 2>/dev/null; then
      det_lint="npx --no-install eslint ."
    fi
  elif [ -f Cargo.toml ]; then
    det_test="cargo test --quiet"; det_type="cargo check --quiet"
    # -D warnings so this authoritative gate fails on warnings (clippy's default
    # severity); the edit-time hook stays lenient, the final backstop does not.
    det_lint="cargo clippy --quiet --all-targets -- -D warnings"
  elif [ -f go.mod ]; then
    det_test="go test ./..."; det_type="go vet ./..."
    have golangci-lint && det_lint="golangci-lint run ./..."
  elif [ -f pyproject.toml ] || [ -f setup.py ] || [ -f setup.cfg ] \
       || ls test_*.py *_test.py tests/ >/dev/null 2>&1; then
    have pytest && det_test="pytest -q"
    if grep -q '\[tool.mypy\]' pyproject.toml 2>/dev/null || [ -f mypy.ini ]; then
      have mypy && det_type="mypy ."
    elif [ -f pyrightconfig.json ]; then
      have pyright && det_type="pyright"
    fi
    have ruff && det_lint="ruff check ."
  fi
  [ "$TEST_CMD" = "__detect__" ] && TEST_CMD="$det_test"
  [ "$TYPE_CMD" = "__detect__" ] && TYPE_CMD="$det_type"
  [ "$LINT_CMD" = "__detect__" ] && LINT_CMD="$det_lint"
fi

# "Verifiable" means behavioral: tests or typecheck. Lint is additive strictness,
# not a substitute — a lint-only repo is still treated as unverifiable.
if [ -z "$TEST_CMD" ] && [ -z "$TYPE_CMD" ]; then
  if [ "${VERIFY_ALLOW_EMPTY:-0}" = "1" ]; then
    echo "verify: nothing to run; VERIFY_ALLOW_EMPTY=1 -> PASS"; exit 0
  fi
  echo "verify: no test/typecheck command detected and no override set." >&2
  echo "verify: refusing to certify an unverifiable build. Set VERIFY_TEST_CMD" >&2
  echo "verify: (and/or VERIFY_TYPECHECK_CMD), or VERIFY_ALLOW_EMPTY=1 to bypass." >&2
  exit 1
fi

fail=0
for stage in "test:$TEST_CMD" "typecheck:$TYPE_CMD" "lint:$LINT_CMD"; do
  label="${stage%%:*}"; cmd="${stage#*:}"
  if [ -z "$cmd" ]; then echo "verify: $label — skipped (no command)"; continue; fi
  echo "verify: $label -> $cmd"
  if sh -c "$cmd"; then echo "verify: $label PASS"; else echo "verify: $label FAIL"; fail=1; fi
done

[ "$fail" -eq 0 ] && echo "verify: gate PASS" || echo "verify: gate FAIL"
exit "$fail"

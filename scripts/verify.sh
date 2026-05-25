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
    # Package manager: honor the lockfile, then the packageManager field, else npm.
    # A pnpm/yarn project run with `npm test` / bare `tsc` often fails outright, so
    # detect the real PM and prefer the project's OWN declared scripts.
    pm=npm
    if   [ -f pnpm-lock.yaml ]; then pm=pnpm
    elif [ -f yarn.lock ];      then pm=yarn
    elif [ -f bun.lockb ] || [ -f bun.lock ]; then pm=bun
    elif grep -q '"packageManager"[[:space:]]*:[[:space:]]*"pnpm' package.json 2>/dev/null; then pm=pnpm
    elif grep -q '"packageManager"[[:space:]]*:[[:space:]]*"yarn' package.json 2>/dev/null; then pm=yarn
    elif grep -q '"packageManager"[[:space:]]*:[[:space:]]*"bun'  package.json 2>/dev/null; then pm=bun
    fi
    case "$pm" in
      pnpm) pmx="pnpm exec" ;;
      yarn) pmx="yarn exec" ;;
      bun)  pmx="bunx" ;;
      *)    pmx="npx --no-install" ;;
    esac
    has_script() { grep -qE "\"$1\"[[:space:]]*:" package.json 2>/dev/null; }

    # tests: prefer the declared "test" script. `bun test` is bun's own runner,
    # not the package script, so use `bun run test` there.
    if has_script test; then
      if [ "$pm" = bun ]; then det_test="bun run test"; else det_test="$pm test"; fi
    fi
    # typecheck: prefer a declared typecheck script; else fall back to tsc, using
    # project-references BUILD mode when the tsconfig declares it (a flat
    # `tsc --noEmit` is wrong for a composite/references monorepo).
    if   has_script typecheck;  then det_type="$pm run typecheck"
    elif has_script type-check; then det_type="$pm run type-check"
    elif [ -f tsconfig.json ]; then
      if grep -qE '"(references|composite)"' tsconfig.json 2>/dev/null; then
        det_type="$pmx tsc -b"
      else
        det_type="$pmx tsc --noEmit"
      fi
    fi
    # lint: prefer a declared lint script; else eslint only if the project
    # actually configures it (mirrors the lint hook). Respect the project's
    # configured rule severities — no --max-warnings.
    if has_script lint; then
      det_lint="$pm run lint"
    elif ls .eslintrc* eslint.config.* >/dev/null 2>&1 \
       || grep -q '"eslintConfig"' package.json 2>/dev/null; then
      det_lint="$pmx eslint ."
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

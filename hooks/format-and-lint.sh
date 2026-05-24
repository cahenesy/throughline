#!/usr/bin/env bash
# format-and-lint.sh — Claude Code PostToolUse hook
#
# Formats then lints the file Claude just edited, but ONLY if the relevant tool
# is available. On a repo with no linter configured it exits 0 silently, so it
# never forces tooling onto a brownfield project. On a lint failure it exits 2,
# which feeds the error back to Claude to fix at the root cause.
#
# Hook input arrives as JSON on stdin (tool_input.file_path). We parse it with
# jq, falling back to python3. If NEITHER is available we fail loudly (exit 2)
# rather than silently skipping every edit — a quality hook that quietly stops
# running is worse than one that complains.
#
# The whole-project linters (clippy, golangci-lint) are expensive, so they are
# DEBOUNCED: at most one run per GREENFIELD_LINT_DEBOUNCE seconds (default 30)
# per repo. Per-file linters (eslint, ruff) are cheap and always run. The build
# runner's verify.sh + review gates are the real backstop, so a debounced skip
# never lets a defect through unchecked.
set -uo pipefail

input="$(cat)"
file=""
if command -v jq >/dev/null 2>&1; then
  file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"
elif command -v python3 >/dev/null 2>&1; then
  file="$(printf '%s' "$input" | python3 -c \
    'import sys,json;print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' \
    2>/dev/null)"
else
  echo "format-and-lint: need jq or python3 to parse hook input; install one to re-enable lint enforcement." >&2
  exit 2
fi

[ -z "${file}" ] && exit 0
[ ! -f "${file}" ] && exit 0

ext="${file##*.}"
have() { command -v "$1" >/dev/null 2>&1; }
fail() { echo "format-and-lint: $1" >&2; exit 2; }

# debounce <key>: returns 0 (run) at most once per window per repo, else 1 (skip).
debounce() {
  local key="$1" window="${GREENFIELD_LINT_DEBOUNCE:-30}" now last
  local id marker
  id="$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
  marker="${TMPDIR:-/tmp}/greenfield-lint-${id}-${key}.ts"
  now="$(date +%s)"
  last="$(cat "$marker" 2>/dev/null || echo 0)"
  [ $((now - last)) -lt "$window" ] && return 1
  echo "$now" > "$marker"; return 0
}

case "${ext}" in
  js|jsx|ts|tsx|mjs|cjs)
    have npx || exit 0
    npx --no-install prettier --write "${file}" >/dev/null 2>&1 || true
    if ls .eslintrc* eslint.config.* >/dev/null 2>&1 \
       || grep -q '"eslintConfig"' package.json 2>/dev/null; then
      npx --no-install eslint --fix "${file}" 2>&1 \
        || fail "eslint reported errors in ${file}. Fix the root cause; do not suppress."
    fi
    ;;
  py)
    have ruff || exit 0
    ruff format "${file}" >/dev/null 2>&1 || true
    ruff check --fix "${file}" 2>&1 \
      || fail "ruff reported errors in ${file}. Fix the root cause; do not suppress."
    ;;
  rs)
    have rustfmt && rustfmt "${file}" >/dev/null 2>&1 || true
    if have cargo && [ -f Cargo.toml ] && debounce clippy; then
      cargo clippy --quiet 2>&1 \
        || fail "clippy reported errors. Fix the root cause; do not suppress."
    fi
    ;;
  go)
    have gofmt && gofmt -w "${file}" >/dev/null 2>&1 || true
    if have golangci-lint && debounce golangci; then
      golangci-lint run "$(dirname "${file}")/..." 2>&1 \
        || fail "golangci-lint reported errors. Fix the root cause; do not suppress."
    fi
    ;;
  *) exit 0 ;;
esac
exit 0

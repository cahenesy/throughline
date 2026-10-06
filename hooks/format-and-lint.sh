#!/usr/bin/env bash
# format-and-lint.sh — Claude Code PostToolUse hook (FR-21, TDD 0068)
#
# Formats then lints the file Claude just edited, honoring the EDITED REPO's
# configuration (issue #180):
#   1. Discovery starts from the edited file's directory and walks up to the
#      file's git toplevel (or `/` outside a repo). It never looks at $PWD.
#   2. Lint runs only when a linter is configured, and only REPORTS (no --fix).
#      On failure the diagnostics go to stderr and the hook exits 2, so the
#      agent sees the rule and line and fixes the root cause.
#   3. Format runs only on opt-in: an explicit formatter config for Python
#      ([tool.ruff.format] / [format]) and JS/TS (a Prettier config). Rust and
#      Go use the language convention, but only for a file in git whose HEAD
#      copy is already formatter-clean (or that is new to git). Rust formats
#      through stdin so rustfmt never touches child modules.
#   4. A missing tool or config is a silent exit 0. A missing jq AND python3
#      stays a loud exit 2: the hook then cannot read its input at all.
#
# The whole-project linters (clippy, golangci-lint) are DEBOUNCED: at most one
# run per THROUGHLINE_LINT_DEBOUNCE seconds (default 30) per project root.
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
case "${file}" in /*) ;; *) file="${PWD}/${file}" ;; esac
# Physical directory, so it compares cleanly with git's (physical) toplevel.
fdir="$(cd -P "$(dirname "${file}")" 2>/dev/null && pwd -P)" || exit 0
ext="${file##*.}"

have() { command -v "$1" >/dev/null 2>&1; }
fail() { echo "format-and-lint: $1" >&2; exit 2; }
fail_tool() { fail "$1 reported errors in $2 (diagnostics above). Fix the root cause; do not suppress."; }

# _tl_stop_dir <dir>: the dir's git toplevel, or `/` outside a repo.
_tl_stop_dir() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || echo /; }

# _tl_find_up <dir> <test-fn>: print the first dir from <dir> up to the stop
# dir (inclusive) where `<test-fn> <d>` returns 0; rc 1 + no output if none.
_tl_find_up() {
  local d="$1" fn="$2" stop
  stop="$(_tl_stop_dir "$d")"
  while :; do
    if "$fn" "$d"; then printf '%s\n' "$d"; return 0; fi
    if [ "$d" = "$stop" ] || [ "$d" = / ]; then return 1; fi
    d="$(dirname "$d")"
  done
}

# _tl_json_has_key <package.json> <key>: rc 0 iff <key> is a TOP-LEVEL key.
# A key that only appears inside devDependencies does not count.
_tl_json_has_key() {
  local f="$1" k="$2"
  [ -f "$f" ] || return 1
  if have jq; then
    jq -e --arg k "$k" 'type == "object" and has($k)' "$f" >/dev/null 2>&1
    return
  fi
  if have python3; then
    python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if isinstance(d,dict) and sys.argv[2] in d else 1)' "$f" "$k" 2>/dev/null
    return
  fi
  return 1
}

# _tl_local_bin <dir> <tool>: print the first node_modules/.bin/<tool> found
# walking up from <dir>; rc 1 if none.
_TL_BIN=""
_tl_has_bin() { [ -x "$1/node_modules/.bin/${_TL_BIN}" ]; }
_tl_local_bin() {
  local d
  _TL_BIN="$2"
  d="$(_tl_find_up "$1" _tl_has_bin)" || return 1
  printf '%s\n' "$d/node_modules/.bin/$2"
}

# _tl_git_rel <file>: the file's path relative to its git toplevel.
_tl_git_rel() {
  local d prefix
  d="$(dirname "$1")"
  prefix="$(git -C "$d" rev-parse --show-prefix 2>/dev/null)" || return 1
  printf '%s%s\n' "$prefix" "${1##*/}"
}

# _tl_git_state <file>: outside | new | tracked (HEAD:<rel> exists).
_tl_git_state() {
  local d rel
  d="$(dirname "$1")"
  if [ "$(git -C "$d" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
    echo outside; return 0
  fi
  rel="$(_tl_git_rel "$1")" || { echo outside; return 0; }
  if git -C "$d" cat-file -e "HEAD:${rel}" 2>/dev/null; then echo tracked; else echo new; fi
}

# _tl_head_clean <file> <check-cmd...>: rc 0 iff the file is tracked and
# `git show HEAD:<rel> | (cd <file dir> && <check-cmd>)` exits 0 with EMPTY
# stdout. Any error counts as not-clean.
_tl_head_clean() {
  local f="$1" d rel out
  shift
  [ "$(_tl_git_state "$f")" = tracked ] || return 1
  d="$(dirname "$f")"
  rel="$(_tl_git_rel "$f")" || return 1
  out="$(git -C "$d" show "HEAD:${rel}" 2>/dev/null | (cd "$d" && "$@") 2>/dev/null)" || return 1
  [ -z "$out" ]
}

# debounce <root> <key>: returns 0 (run) at most once per window per project
# root, else 1 (skip).
debounce() {
  local root="$1" key="$2" window="${THROUGHLINE_LINT_DEBOUNCE:-30}" now last id marker
  id="$(printf '%s' "$root" | cksum | cut -d' ' -f1)"
  marker="${TMPDIR:-/tmp}/throughline-lint-${id}-${key}.ts"
  now="$(date +%s)"
  last="$(cat "$marker" 2>/dev/null || echo 0)"
  [ $((now - last)) -lt "$window" ] && return 1
  echo "$now" > "$marker"; return 0
}

# --- per-language config tests (each takes a directory) ---------------------
# _tl_py_cfg_file <dir>: print the ruff config that governs <dir>, in ruff's
# precedence (ruff.toml > .ruff.toml > pyproject.toml with a [tool.ruff] table).
# `[].]` is the POSIX-ERE spelling of "`]` or `.`" (a backslash is literal inside
# a bracket expression), so `[tool.ruffle]` does not match.
_tl_py_cfg_file() {
  local d="$1"
  if   [ -f "$d/ruff.toml" ];  then printf '%s\n' "$d/ruff.toml"
  elif [ -f "$d/.ruff.toml" ]; then printf '%s\n' "$d/.ruff.toml"
  elif [ -f "$d/pyproject.toml" ] && grep -Eq '^\[tool\.ruff[].]' "$d/pyproject.toml"; then
    printf '%s\n' "$d/pyproject.toml"
  else return 1; fi
}
_tl_has_py_cfg() { _tl_py_cfg_file "$1" >/dev/null; }
_tl_any() { local f; for f in "$@"; do [ -e "$f" ] && return 0; done; return 1; }
_tl_has_prettier_cfg() {
  _tl_any "$1/.prettierrc" "$1"/.prettierrc.* "$1"/prettier.config.* \
    || _tl_json_has_key "$1/package.json" prettier
}
_tl_has_eslint_cfg() {
  _tl_any "$1"/eslint.config.* "$1"/.eslintrc* \
    || _tl_json_has_key "$1/package.json" eslintConfig
}
_tl_has_cargo()    { [ -f "$1/Cargo.toml" ]; }
_tl_has_gomod()    { [ -f "$1/go.mod" ]; }
_tl_has_golangci() { _tl_any "$1/.golangci.yml" "$1/.golangci.yaml" "$1/.golangci.toml" "$1/.golangci.json"; }

case "${ext}" in
  py)
    have ruff || exit 0
    cfgdir="$(_tl_find_up "$fdir" _tl_has_py_cfg)" || exit 0
    cfg="$(_tl_py_cfg_file "$cfgdir")"
    fmt=0
    case "${cfg##*/}" in
      pyproject.toml) grep -Eq '^\[tool\.ruff\.format\]' "$cfg" && fmt=1 ;;
      *)              grep -Eq '^\[format\]' "$cfg" && fmt=1 ;;
    esac
    [ "$fmt" -eq 1 ] && { ruff format "${file}" >/dev/null 2>&1 || true; }
    ruff check --no-fix --output-format concise "${file}" 1>&2 \
      || fail_tool ruff "${file}"
    ;;
  js|jsx|ts|tsx|mjs|cjs)
    if pdir="$(_tl_find_up "$fdir" _tl_has_prettier_cfg)" \
       && pbin="$(_tl_local_bin "$pdir" prettier)"; then
      (cd "$pdir" && "$pbin" --write "${file}") >/dev/null 2>&1 || true
    fi
    if edir="$(_tl_find_up "$fdir" _tl_has_eslint_cfg)" \
       && ebin="$(_tl_local_bin "$edir" eslint)"; then
      (cd "$edir" && "$ebin" "${file}") 1>&2 || fail_tool eslint "${file}"
    fi
    ;;
  rs)
    root="$(_tl_find_up "$fdir" _tl_has_cargo)" || exit 0
    if have rustfmt && [ ! -L "${file}" ]; then
      ed="$(sed -n 's/^[[:space:]]*edition[[:space:]]*=[[:space:]]*"\([0-9][0-9]*\)".*/\1/p' \
              "$root/Cargo.toml" 2>/dev/null | head -n1)"
      ed="${ed:-2021}"
      dofmt=0
      case "$(_tl_git_state "${file}")" in
        new) dofmt=1 ;;
        tracked) _tl_head_clean "${file}" rustfmt --edition "$ed" --check && dofmt=1 ;;
      esac
      if [ "$dofmt" -eq 1 ] && tmp="$(mktemp 2>/dev/null)"; then
        if (cd "$fdir" && rustfmt --edition "$ed") < "${file}" > "$tmp" 2>/dev/null \
           && ! cmp -s "$tmp" "${file}"; then
          cat "$tmp" > "${file}"   # keeps the file's mode and inode
        fi
        rm -f "$tmp"
      fi
    fi
    if have cargo && debounce "$root" clippy; then
      (cd "$root" && cargo clippy --quiet) 1>&2 || fail_tool clippy "$root"
    fi
    ;;
  go)
    root="$(_tl_find_up "$fdir" _tl_has_gomod)" || exit 0
    if have gofmt; then
      dofmt=0
      case "$(_tl_git_state "${file}")" in
        new) dofmt=1 ;;
        tracked) _tl_head_clean "${file}" gofmt -l && dofmt=1 ;;
      esac
      [ "$dofmt" -eq 1 ] && { gofmt -w "${file}" >/dev/null 2>&1 || true; }
    fi
    if have golangci-lint && _tl_find_up "$root" _tl_has_golangci >/dev/null \
       && debounce "$root" golangci; then
      if [ "$fdir" = "$root" ]; then target="./..."; else target="./${fdir#"$root"/}/..."; fi
      (cd "$root" && golangci-lint run "$target") 1>&2 || fail_tool golangci-lint "$root"
    fi
    ;;
  *) exit 0 ;;
esac
exit 0

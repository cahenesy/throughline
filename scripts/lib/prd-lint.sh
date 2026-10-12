#!/usr/bin/env bash
# prd-lint.sh — the mechanical PRD pre-pass (TDD 0073; FR-103, FR-105).
# Blocks on structural defects in docs/PRD.md without spending model time, and
# computes the delta (the requirement ids this change adds or alters) that the
# requirements reviewer (agents/requirements-reviewer.md) is scoped to.
#
#   tl_prd_base <repo-root> <out-file>  base docs/PRD.md → <out-file>; rc 0 base,
#                                       rc 1 no base (degrade line on stdout),
#                                       rc 2 a real git failure
#   tl_prd_lint <repo-root>             `prd-lint: base <ref|none>`, findings,
#                                       `prd-lint: delta <n> requirements, <m> major, <k> info`
#                                       rc 0 clean | 1 major | 2 error | 3 no python3
#   tl_prd_delta <repo-root>            new/changed/removed<TAB><id>; same rc rules
#
# The python half (prd_lint.py) is stdlib-only and runs as `python3 -I -B`; it
# shares ux_record.py's requirement grammar. Unlike ux.sh there is no
# short-circuit: every PRD needs the parser, so no python3 is rc 3. Sourced,
# never executed: functions only, no top-level side effects beyond its deps.

# Absolute at source time: helpers later `cd` into the linted repo, so a
# relative dir would resolve to that repo's own scripts/lib/prd_lint.py.
_TL_PRD_LINT_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd -P)" || {
  echo "prd-lint: cannot resolve its own directory" >&2; return 2 2>/dev/null || exit 2; }
for _pl_dep in plugin-root.sh verdicts.sh; do
  # shellcheck source=/dev/null
  { [ -r "$_TL_PRD_LINT_DIR/$_pl_dep" ] && . "$_TL_PRD_LINT_DIR/$_pl_dep"; } || {
    echo "prd-lint: cannot source $_TL_PRD_LINT_DIR/$_pl_dep" >&2
    unset _pl_dep
    return 2 2>/dev/null || exit 2
  }
done
unset _pl_dep

# tl_prd_base <repo-root> <out-file>. Sets _TL_PRD_BASE_REF (the ref, or empty)
# and _TL_PRD_BASE_DEGRADED (1 only when the base is missing because the repo
# is outside git). Degrade lines go to stdout so the skill can copy them into
# the PR body; it never stops the skill except on a real git failure (rc 2).
tl_prd_base() {
  local root="${1:-}" out="${2:-}" ref fallback=0 tree rc
  _TL_PRD_BASE_REF=""; _TL_PRD_BASE_DEGRADED=0
  [ -n "$root" ] && [ -n "$out" ] || { echo "prd-lint: usage: tl_prd_base <repo-root> <out-file>" >&2; return 2; }
  if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "prd-lint: no base (not a git work tree); every requirement is new"
    _TL_PRD_BASE_DEGRADED=1
    return 1
  fi
  ref="$(_tl_integration_ref "$root")" || { ref=HEAD; fallback=1; }
  if ! git -C "$root" rev-parse -q --verify "${ref}^{commit}" >/dev/null 2>&1; then
    echo "prd-lint: no base (no commits); every requirement is new"
    return 1
  fi
  [ "$fallback" -eq 1 ] && echo "prd-lint: base is HEAD (no integration branch)"
  _TL_PRD_BASE_REF="$ref"
  # ls-tree paths are relative to the current directory: -C is required.
  tree="$(git -C "$root" ls-tree "$ref" -- docs/PRD.md)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "prd-lint: git ls-tree failed (rc $rc)" >&2; return 2; }
  [ -n "$tree" ] || return 1
  git -C "$root" show "${ref}:docs/PRD.md" >"$out"; rc=$?
  [ "$rc" -eq 0 ] || { echo "prd-lint: git show failed (rc $rc)" >&2; return 2; }
  return 0
}

# _tl_prd_run <check|delta> <repo-root> — shared body of tl_prd_lint/tl_prd_delta.
_tl_prd_run() {
  local mode="$1" root="${2:-}" py tmp msgs brc rc base label
  [ -n "$root" ] || { echo "prd-lint: usage: tl_prd_$([ "$mode" = check ] && echo lint || echo delta) <repo-root>" >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || { echo "prd-lint: python3 required" >&2; return 3; }
  py="$_TL_PRD_LINT_DIR/prd_lint.py"
  [ -r "$py" ] || { echo "prd-lint: cannot read $py" >&2; return 2; }
  [ -f "$root/docs/PRD.md" ] && [ -r "$root/docs/PRD.md" ] \
    || { echo "prd-lint: cannot read $root/docs/PRD.md" >&2; return 2; }
  tmp="$(mktemp)" && msgs="$(mktemp)" || { echo "prd-lint: mktemp failed" >&2; rm -f "${tmp:-}"; return 2; }
  tl_prd_base "$root" "$tmp" >"$msgs"; brc=$?
  case "$brc" in
    0) base="$tmp"; label="$_TL_PRD_BASE_REF" ;;
    1) base=none; label=none ;;
    *) rm -f "$tmp" "$msgs"; return 2 ;;
  esac
  if [ "$mode" = check ]; then
    echo "prd-lint: base $label"
    cat "$msgs"
    set -- check docs/PRD.md "$base"
    [ "${_TL_PRD_BASE_DEGRADED:-0}" = 1 ] && set -- "$@" --degraded
  else
    cat "$msgs" >&2
    set -- delta docs/PRD.md "$base"
  fi
  ( cd "$root" && python3 -I -B "$py" "$@" ); rc=$?
  rm -f "$tmp" "$msgs"
  return "$rc"
}

tl_prd_lint()  { _tl_prd_run check "$@"; }
tl_prd_delta() { _tl_prd_run delta "$@"; }

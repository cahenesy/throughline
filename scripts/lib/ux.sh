#!/usr/bin/env bash
# ux.sh — UX record library wrappers (TDD 0070; FR-89, FR-90, FR-91, FR-94,
# FR-99, FR-101, NFR-4; ADR 0017). Mechanics only: parse, hash, validate,
# render, report. Visual design belongs to the delegates (TDD 0071).
#
#   tl_ux_ui_reqs <prd>                 <id>\t<hash>\t<title> per [UI] requirement
#   tl_ux_delta <prd> <index|->         new / changed / orphaned lines
#   tl_ux_validate <repo-root>          ok … | ux-invalid: lines (rc 1)
#   tl_ux_render <repo-root> <sid>…     scoped PNG render; rc 4 = declared degrade
#   tl_ux_capture <url> <outdir> <WxH>  reference capture, never in a git tree
#   tl_ux_index_html <repo-root>        regenerate docs/ux/index.html
#   tl_ux_merged_index <repo-root>      the integration branch's index.json blob
#   tl_ux_coverage <repo-root> <id>…    covered / stale / uncovered vs the merged set
#
# The python halves (ux_record.py, ux_render.py) are stdlib-only and run as
# `python3 -I`. A wrapper whose input has no `[UI]` returns before looking for
# python3, so non-UI repos never need it. rc 3 = python3 missing. Sourced, never
# executed: functions only, no top-level side effects beyond sourcing its deps.

for _ux_dep in plugin-root.sh verdicts.sh; do
  # shellcheck source=/dev/null
  { [ -r "${BASH_SOURCE[0]%/*}/$_ux_dep" ] && . "${BASH_SOURCE[0]%/*}/$_ux_dep"; } || {
    echo "ux: cannot source ${BASH_SOURCE[0]%/*}/$_ux_dep" >&2
    unset _ux_dep
    return 2 2>/dev/null || exit 2
  }
done
unset _ux_dep

# _tl_ux_py <record|render> <subcommand> <args…> — run a python half.
_tl_ux_py() {
  local which="$1" root py; shift
  command -v python3 >/dev/null 2>&1 || { echo "ux: python3 required" >&2; return 3; }
  root="$(tl_plugin_root)" || return 2
  py="$root/scripts/lib/ux_${which}.py"
  [ -r "$py" ] || { echo "ux: cannot read $py" >&2; return 2; }
  python3 -I "$py" "$@"
}

tl_ux_ui_reqs() {
  local prd="${1:-}"
  [ -n "$prd" ] && [ -f "$prd" ] && [ -r "$prd" ] || { echo "ux: cannot read $prd" >&2; return 1; }
  grep -qF '[UI]' "$prd" || return 0
  _tl_ux_py record ui-reqs "$prd"
}

tl_ux_delta() {
  local prd="${1:-}" idx="${2:-}"
  [ -n "$prd" ] && [ -n "$idx" ] || { echo "ux: usage: tl_ux_delta <prd-path> <index-path|->" >&2; return 2; }
  [ -f "$prd" ] && [ -r "$prd" ] || { echo "ux: cannot read $prd" >&2; return 2; }
  # No [UI] in the PRD and no UX set yet: nothing to report, no python3 needed.
  if [ "$idx" != "-" ] && [ ! -e "$idx" ] && ! grep -qF '[UI]' "$prd"; then return 0; fi
  _tl_ux_py record delta "$prd" "$idx"
}

tl_ux_validate() {
  local root="${1:-}"
  [ -n "$root" ] || { echo "ux: usage: tl_ux_validate <repo-root>" >&2; return 2; }
  [ -f "$root/docs/ux/index.json" ] || { echo "ux: no index at $root/docs/ux/index.json" >&2; return 2; }
  _tl_ux_py record validate "$root"
}

tl_ux_render() {
  local root="${1:-}"
  [ -n "$root" ] || { echo "ux: usage: tl_ux_render <repo-root> <screen-id>…" >&2; return 2; }
  shift
  [ "$#" -gt 0 ] || { echo "ux: render needs explicit screen ids" >&2; return 2; }
  _tl_ux_py render render "$root" "$@"
}

tl_ux_capture() {
  [ "$#" -eq 3 ] || { echo "ux: usage: tl_ux_capture <url> <outdir> <w>x<h>" >&2; return 2; }
  _tl_ux_py render capture "$@"
}

tl_ux_index_html() {
  local root="${1:-}"
  [ -n "$root" ] || { echo "ux: usage: tl_ux_index_html <repo-root>" >&2; return 2; }
  _tl_ux_py render index-html "$root"
}

# _tl_ux_fetch_once <repo-root> — best-effort `git fetch origin`, once per
# process, so a merge on the host is not misread as "no merged UX set".
# THROUGHLINE_UX_NOFETCH=1 skips it (tdd-lint never reaches the network).
_tl_ux_fetch_once() {
  [ "${THROUGHLINE_UX_NOFETCH:-}" = 1 ] && return 0
  [ -n "${_TL_UX_FETCHED:-}" ] && return 0
  _TL_UX_FETCHED=1
  git -C "$1" remote get-url origin >/dev/null 2>&1 || return 0
  command -v timeout >/dev/null 2>&1 || return 0
  timeout 20 git -C "$1" fetch -q origin >/dev/null 2>&1 || true
}

tl_ux_merged_index() {
  local root="${1:-}" ref sha
  [ -n "$root" ] || { echo "ux: usage: tl_ux_merged_index <repo-root>" >&2; return 2; }
  _tl_ux_fetch_once "$root"
  ref="$(_tl_integration_ref "$root")" || { echo "ux: no integration branch" >&2; return 2; }
  git -C "$root" cat-file -e "${ref}:docs/ux/index.json" 2>/dev/null || return 1
  sha="$(git -C "$root" rev-parse --short "${ref}^{commit}" 2>/dev/null)"
  echo "ux: merged index from ${ref} @ ${sha}" >&2
  git -C "$root" show "${ref}:docs/ux/index.json" || { echo "ux: cannot read ${ref}:docs/ux/index.json" >&2; return 2; }
}

tl_ux_coverage() {
  local root="${1:-}" rc id tmp
  [ -n "$root" ] && [ "$#" -ge 2 ] || { echo "ux: usage: tl_ux_coverage <repo-root> <id>…" >&2; return 2; }
  shift
  _tl_ux_fetch_once "$root"
  tmp="$(mktemp)" || { echo "ux: mktemp failed" >&2; return 2; }
  tl_ux_merged_index "$root" >"$tmp"; rc=$?
  if [ "$rc" -eq 1 ]; then
    rm -f "$tmp"
    for id in "$@"; do printf 'uncovered\t%s\n' "$id"; done
    return 1
  fi
  [ "$rc" -eq 0 ] || { rm -f "$tmp"; return 2; }
  _tl_ux_py record coverage-check "$root/docs/PRD.md" "merged docs/ux/index.json" "$@" <"$tmp"; rc=$?
  rm -f "$tmp"
  return "$rc"
}

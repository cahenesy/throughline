#!/usr/bin/env bash
# verdicts.sh — file-backed four-gate verdicts (TDD 0061 / FR-15, FR-25, FR-82,
# ADR 0011). Flip authority is four JSON files under
#   <repo-root>/docs/tdd/.implement-logs/<run-id>/<slug>/<gate>.json
# Never reads a harness transcript. No top-level side effects.
#
# Every tl_verdict_* / tl_test_first_observe takes an explicit path; none
# consult the process cwd as <repo-root>.

_TL_VERDICTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_jlib="${_TL_VERDICTS_DIR}/json.sh"
# shellcheck source=scripts/lib/json.sh
{ [ -r "$_jlib" ] && . "$_jlib"; } || {
  echo "FATAL: cannot source $_jlib (partial install or perms)" >&2
  return 1 2>/dev/null || exit 1
}
unset _jlib

_tl_verdict_gates='test-first|ci-checks|runtime-verify|review'
_tl_verdict_statuses='PASS|FAIL|BLOCKED|SKIP'

# _tl_abs_root <path> — rc 0 iff <path> is a non-empty absolute directory
# path (need not exist yet). Rejects empty and relative so callers cannot
# silently write under cwd.
_tl_abs_root() {
  case "${1:-}" in
    /*) return 0 ;;
    *)  echo "verdicts: <repo-root> must be an absolute path" >&2; return 2 ;;
  esac
}

# _tl_valid_slug <slug> — ^[a-z0-9][a-z0-9.-]*$
_tl_valid_slug() {
  case "${1:-}" in
    ''|*[!a-z0-9.-]*|.*|-*) return 1 ;;
  esac
  case "${1}" in
    [a-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# _tl_valid_run <run-id> — no slashes; non-empty path segment.
_tl_valid_run() {
  case "${1:-}" in
    ''|*/*|*..*) return 1 ;;
    *) return 0 ;;
  esac
}

tl_verdict_dir() {  # <repo-root> <run-id> <slug>
  local root="${1:-}" run="${2:-}" slug="${3:-}"
  _tl_abs_root "$root" || return $?
  _tl_valid_run "$run" || { echo "verdicts: invalid run-id" >&2; return 2; }
  _tl_valid_slug "$slug" || { echo "verdicts: invalid slug '$slug'" >&2; return 2; }
  printf '%s/docs/tdd/.implement-logs/%s/%s\n' "$root" "$run" "$slug"
}

tl_verdict_write() {  # <repo-root> <run-id> <slug> <gate> <status> <evidence>
  local root="${1:-}" run="${2:-}" slug="${3:-}" gate="${4:-}" status="${5:-}" evidence="${6:-}"
  local dir f tmp
  dir="$(tl_verdict_dir "$root" "$run" "$slug")" || return $?
  case "$gate" in
    test-first|ci-checks|runtime-verify|review) ;;
    *) echo "verdicts: bad gate token '$gate' (want ${_tl_verdict_gates})" >&2; return 2 ;;
  esac
  case "$status" in
    PASS|FAIL|BLOCKED|SKIP) ;;
    *) echo "verdicts: bad status token '$status' (want ${_tl_verdict_statuses})" >&2; return 2 ;;
  esac
  mkdir -p "$dir" || { echo "verdicts: cannot mkdir $dir" >&2; return 1; }
  f="$dir/${gate}.json"
  tmp="$(mktemp "$dir/.${gate}.XXXXXX")" || { echo "verdicts: mktemp failed" >&2; return 1; }
  if ! printf '{"gate":"%s","status":"%s","evidence":"%s"}\n' \
      "$(tl_json_escape "$gate")" \
      "$(tl_json_escape "$status")" \
      "$(tl_json_escape "$evidence")" >"$tmp"; then
    rm -f "$tmp"
    echo "verdicts: write failed for $f" >&2
    return 1
  fi
  if ! mv "$tmp" "$f"; then
    rm -f "$tmp"
    echo "verdicts: mv failed for $f" >&2
    return 1
  fi
  return 0
}

tl_verdict_read() {  # <repo-root> <run-id> <slug> <gate>
  local root="${1:-}" run="${2:-}" slug="${3:-}" gate="${4:-}" dir f
  dir="$(tl_verdict_dir "$root" "$run" "$slug")" || return $?
  case "$gate" in
    test-first|ci-checks|runtime-verify|review) ;;
    *) echo "verdicts: bad gate token '$gate'" >&2; return 2 ;;
  esac
  f="$dir/${gate}.json"
  [ -f "$f" ] || return 1
  cat "$f"
}

# tl_verdict_require_flip — 0 iff test-first, ci-checks, review are PASS
# and runtime-verify is PASS or SKIP with non-empty evidence.
tl_verdict_require_flip() {  # <repo-root> <run-id> <slug>
  local root="${1:-}" run="${2:-}" slug="${3:-}" g json st ev
  for g in test-first ci-checks review; do
    json="$(tl_verdict_read "$root" "$run" "$slug" "$g")" || return 1
    st="$(printf '%s' "$json" | tl_json_field status)"
    [ "$st" = "PASS" ] || return 1
  done
  json="$(tl_verdict_read "$root" "$run" "$slug" runtime-verify)" || return 1
  st="$(printf '%s' "$json" | tl_json_field status)"
  ev="$(printf '%s' "$json" | tl_json_field evidence)"
  case "$st" in
    PASS) return 0 ;;
    SKIP) [ -n "$ev" ] && return 0; return 1 ;;
    *) return 1 ;;
  esac
}

# _tl_integration_ref <git-dir> — print a resolvable integration ref, or rc 1.
_tl_integration_ref() {
  local d="$1" cand
  if [ -n "${THROUGHLINE_INTEGRATION_BRANCH:-}" ]; then
    git -C "$d" rev-parse -q --verify "${THROUGHLINE_INTEGRATION_BRANCH}^{commit}" >/dev/null 2>&1 \
      && { printf '%s\n' "$THROUGHLINE_INTEGRATION_BRANCH"; return 0; }
  fi
  if git -C "$d" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1; then
    cand="$(git -C "$d" symbolic-ref --short refs/remotes/origin/HEAD)"
    git -C "$d" rev-parse -q --verify "${cand}^{commit}" >/dev/null 2>&1 \
      && { printf '%s\n' "$cand"; return 0; }
  fi
  for cand in main master; do
    git -C "$d" rev-parse -q --verify "${cand}^{commit}" >/dev/null 2>&1 \
      && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# tl_test_first_observe <git-dir> — 0 iff unique commits vs the integration
# merge-base contain a test(failing): subject before the first feat: / step(
# subject. Empty range / feat-only / reversed order → rc 1. Git-history only.
tl_test_first_observe() {
  local d="${1:-}" integ mb subj seen_tf=0
  [ -n "$d" ] && [ -d "$d" ] || { echo "verdicts: tl_test_first_observe needs a git dir" >&2; return 1; }
  integ="$(_tl_integration_ref "$d")" || return 1
  mb="$(git -C "$d" merge-base "$integ" HEAD 2>/dev/null)" || return 1
  while IFS= read -r subj; do
    case "$subj" in
      'test(failing):'*) seen_tf=1 ;;
      feat:*|step\(*)
        [ "$seen_tf" -eq 1 ] || return 1
        ;;
    esac
  done < <(git -C "$d" log --format=%s --reverse "${mb}..HEAD" 2>/dev/null)
  [ "$seen_tf" -eq 1 ]
}

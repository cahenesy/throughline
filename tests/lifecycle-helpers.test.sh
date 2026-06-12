#!/usr/bin/env bash
# lifecycle-helpers.test.sh — eval for TDD 0009 (FR-31/FR-32/FR-33), step 1.
#
# Pins the contract of the three sourced shell helpers introduced by TDD 0009:
#   scripts/lib/repo-id.sh   — tl_repo_id / tl_local_marker_path
#   scripts/lib/gitignore.sh — tl_gitignore_add_line
#   scripts/lib/markers.sh   — tl_repo_marker_{read,write} / tl_local_marker_{read,write}
#
# Written red-first: with the three lib files absent, sourcing no-ops and every
# tl_* call is "command not found" (127), so every behavioral assertion fails.
# Landing the helpers turns the file green. Pure bash/grep — no python/jq
# dependency (jq is only consulted opportunistically by the impl when present).
#
# Run: bash tests/lifecycle-helpers.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

for m in repo-id gitignore markers; do
  if [ -r "$LIB/$m.sh" ]; then
    # shellcheck disable=SC1090
    . "$LIB/$m.sh"
  else
    echo "  (note: $LIB/$m.sh absent — expected RED before the impl)"
  fi
done

# Deterministic hasher mirroring repo-id.sh's formula, for expected-value checks.
sha12() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-12
  else shasum -a 256 | cut -c1-12; fi
}

# Best-effort JSON validity check on stdin (jq -> python3 -> structural).
is_json() {
  if command -v jq >/dev/null 2>&1; then jq -e . >/dev/null 2>&1; return; fi
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; return; fi
  local s; s="$(cat)"; case "$(printf '%s' "$s" | tr -d '[:space:]')" in \{*\}) return 0;; *) return 1;; esac
}

mk_repo() {
  local d="$1" remote="${2:-}"
  mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t
    [ -n "$remote" ] && git remote add origin "$remote"
    git commit -q --allow-empty -m init ) >/dev/null 2>&1
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
echo "[repo-id] tl_repo_id / tl_local_marker_path"
( R="$(mk_repo "$ROOT/ri/with-remote" "https://example.com/acme/widget.git")"; cd "$R"
  id="$(tl_repo_id 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$id" | grep -Eq '^[0-9a-f]{12}$'; then
    ok "tl_repo_id emits 12 lowercase hex chars in a repo with a remote"
  else bad "tl_repo_id did not emit a 12-hex id (rc=$rc, got '${id:-}')"; fi
  want="$(printf '%s' "https://example.com/acme/widget.git" | sha12)"
  if [ "${id:-}" = "$want" ]; then ok "tl_repo_id == sha256_hex12(origin url)"
  else bad "tl_repo_id '$id' != sha12(origin url) '$want'"; fi
  id2="$(tl_repo_id 2>/dev/null)"
  if [ -n "${id:-}" ] && [ "${id:-}" = "${id2:-}" ]; then ok "tl_repo_id is stable across calls"
  else bad "tl_repo_id not stable: '$id' vs '$id2'"; fi
) || true

( R="$(mk_repo "$ROOT/ri/no-remote")"; cd "$R"
  id="$(tl_repo_id 2>/dev/null)"
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  want="$(printf '%s' "$top" | sha12)"
  if [ -n "${id:-}" ] && [ "${id:-}" = "$want" ]; then ok "tl_repo_id falls back to sha12(abspath) with no origin"
  else bad "tl_repo_id no-remote fallback wrong: got '$id', want '$want'"; fi
) || true

( cd "$ROOT"
  if tl_repo_id >/dev/null 2>&1; then bad "tl_repo_id should fail outside a git repo"
  else ok "tl_repo_id returns non-zero outside a git repo"; fi
) || true

( R="$(mk_repo "$ROOT/ri/lmp" "git@example.com:acme/lmp.git")"; cd "$R"
  export CLAUDE_PLUGIN_DATA="$ROOT/ri/data"
  p="$(tl_local_marker_path 2>/dev/null)"; rc=$?
  id="$(tl_repo_id 2>/dev/null)"
  want="$CLAUDE_PLUGIN_DATA/$id/local.json"
  if [ "$rc" -eq 0 ] && [ "${p:-}" = "$want" ]; then ok "tl_local_marker_path == \$CLAUDE_PLUGIN_DATA/<repo-id>/local.json"
  else bad "tl_local_marker_path wrong: rc=$rc got '$p' want '$want'"; fi
  if [ -d "$CLAUDE_PLUGIN_DATA/$id" ]; then ok "tl_local_marker_path created the <repo-id> dir"
  else bad "tl_local_marker_path did not create $CLAUDE_PLUGIN_DATA/$id"; fi
) || true

( R="$(mk_repo "$ROOT/ri/nodata" "git@example.com:acme/nd.git")"; cd "$R"
  unset CLAUDE_PLUGIN_DATA
  if tl_local_marker_path >/dev/null 2>&1; then bad "tl_local_marker_path should fail when CLAUDE_PLUGIN_DATA unset"
  else ok "tl_local_marker_path returns non-zero when CLAUDE_PLUGIN_DATA unset"; fi
) || true

# ---------------------------------------------------------------------------
echo "[gitignore] tl_gitignore_add_line"
( R="$(mk_repo "$ROOT/gi/fresh")"; cd "$R"; rm -f .gitignore
  tl_gitignore_add_line "docs/tdd/.implement-logs/" >/dev/null 2>&1
  if [ -f .gitignore ] && grep -Fxq "docs/tdd/.implement-logs/" .gitignore; then
    ok "tl_gitignore_add_line creates .gitignore and adds the line when absent"
  else bad "tl_gitignore_add_line did not create/append the line"; fi
  before="$(cat .gitignore 2>/dev/null)"
  tl_gitignore_add_line "docs/tdd/.implement-logs/" >/dev/null 2>&1
  after="$(cat .gitignore 2>/dev/null)"
  if [ "$before" = "$after" ]; then ok "tl_gitignore_add_line is idempotent (byte-identical on re-run)"
  else bad "tl_gitignore_add_line not idempotent"; fi
  n="$(grep -Fxc "docs/tdd/.implement-logs/" .gitignore 2>/dev/null || echo 0)"
  if [ "$n" = "1" ]; then ok "tl_gitignore_add_line does not duplicate an exact-match line"
  else bad "tl_gitignore_add_line duplicated the line ($n occurrences)"; fi
) || true

( R="$(mk_repo "$ROOT/gi/existing")"; cd "$R"
  printf 'node_modules/\n' > .gitignore
  tl_gitignore_add_line "docs/tdd/.implement-logs/" >/dev/null 2>&1
  if grep -Fxq "node_modules/" .gitignore && grep -Fxq "docs/tdd/.implement-logs/" .gitignore; then
    ok "tl_gitignore_add_line preserves existing entries while appending"
  else bad "tl_gitignore_add_line clobbered existing content"; fi
) || true

# ---------------------------------------------------------------------------
echo "[markers] repo + local marker read/write"
( R="$(mk_repo "$ROOT/mk/repo")"; cd "$R"
  tl_repo_marker_write "3.11.2" "shell" "scaffold,gitignore,git_init" >/dev/null 2>&1
  f="docs/.throughline-bootstrap.json"
  if [ -f "$f" ]; then ok "tl_repo_marker_write creates docs/.throughline-bootstrap.json"
  else bad "tl_repo_marker_write did not create $f"; fi
  if is_json < "$f"; then ok "repo marker is valid JSON"; else bad "repo marker is not valid JSON"; fi
  grep -Fq '"plugin_version_applied": "3.11.2"' "$f" && grep -Fq '"language": "shell"' "$f" \
    && ok "repo marker records plugin_version_applied + language" \
    || bad "repo marker missing version/language fields"
  grep -Fq '"repo_steps_applied": ["scaffold","gitignore","git_init"]' "$f" \
    && ok "repo_steps_applied is a JSON array of the csv steps in order" \
    || bad "repo_steps_applied wrong (got: $(grep repo_steps_applied "$f"))"
  grep -Fq '"schema": 1' "$f" && ok "repo marker has integer schema == 1" || bad "repo marker schema wrong"
  tl_repo_marker_read 2>/dev/null | grep -Fq '"plugin_version_applied": "3.11.2"' \
    && ok "tl_repo_marker_read echoes the marker JSON" \
    || bad "tl_repo_marker_read did not echo the marker"
) || true

( R="$(mk_repo "$ROOT/mk/absent")"; cd "$R"
  out="$(tl_repo_marker_read 2>/dev/null)"
  [ "$(printf '%s' "$out" | tr -d '[:space:]')" = "{}" ] \
    && ok "tl_repo_marker_read returns {} when absent" || bad "absent-case wrong: '$out'"
  mkdir -p docs; printf 'not json at all' > docs/.throughline-bootstrap.json
  out="$(tl_repo_marker_read 2>/dev/null)"
  [ "$(printf '%s' "$out" | tr -d '[:space:]')" = "{}" ] \
    && ok "tl_repo_marker_read returns {} when malformed" || bad "malformed-case wrong: '$out'"
) || true

( R="$(mk_repo "$ROOT/mk/local" "git@example.com:acme/lm.git")"; cd "$R"
  export CLAUDE_PLUGIN_DATA="$ROOT/mk/data"
  tl_local_marker_write "3.11.2" "deps_installed" >/dev/null 2>&1
  p="$(tl_local_marker_path 2>/dev/null)"
  if [ -f "$p" ] && grep -Fq '"plugin_version_seen": "3.11.2"' "$p" \
     && grep -Fq '"local_steps_completed": ["deps_installed"]' "$p" && grep -Fq '"schema": 1' "$p"; then
    ok "tl_local_marker_write writes plugin_version_seen + local_steps_completed + schema"
  else bad "tl_local_marker_write produced an unexpected local marker at '$p'"; fi
  tl_local_marker_read 2>/dev/null | grep -Fq '"plugin_version_seen": "3.11.2"' \
    && ok "tl_local_marker_read echoes the local marker JSON" \
    || bad "tl_local_marker_read did not echo the local marker"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== lifecycle-helpers eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

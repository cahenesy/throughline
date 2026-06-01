#!/usr/bin/env bash
# repo-id.test.sh — eval for TDD 0009 / FR-33: pins the contract of
# scripts/lib/repo-id.sh::tl_repo_id and ::tl_local_marker_path. Extended by
# TDD 0012 / FR-46..49 to also pin ::tl_drafts_dir (the per-repo drafts dir the
# interview-draft persistence layer hangs under).
#
# Written red-first: before TDD 0009 lands, scripts/lib/repo-id.sh does not
# exist, so [A] fails on `bash -n` and every behavioral case errors out. The
# implementation commit makes them green.
#
# tl_repo_id must be a PURE function of the repo's identity: the same repo
# (same origin remote, or same toplevel path when there is no remote) always
# yields the same 12-hex-char id; a different identity yields a different id.
# tl_local_marker_path composes that id under ${CLAUDE_PLUGIN_DATA}.
#
# Run: bash tests/repo-id.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib/repo-id.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

# A throwaway git repo with a controllable origin remote.
mkrepo() { # <dir> [remote-url]
  local d="$1" url="${2-}"
  mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" config user.email t@e; git -C "$d" config user.name t
  [ -n "$url" ] && git -C "$d" remote add origin "$url"
  printf '%s\n' "$d"
}

# --- [A] repo-id.sh parses + sources standalone ------------------------------
echo "[A] repo-id.sh parses + sources in isolation"
( bash -n "$LIB" 2>"$ROOT/A.err" \
    && ok "repo-id.sh parses (bash -n)" \
    || bad "repo-id.sh failed bash -n: $(cat "$ROOT/A.err" 2>/dev/null)"
  if bash -c "set -uo pipefail; source \"$LIB\"; type -t tl_repo_id >/dev/null && type -t tl_local_marker_path >/dev/null" 2>"$ROOT/A2.err"; then
    ok "repo-id.sh sources standalone and binds both functions"
  else
    bad "repo-id.sh failed to source standalone: $(cat "$ROOT/A2.err" 2>/dev/null)"
  fi
) || true

# --- [B] tl_repo_id: 12 hex chars, deterministic, remote-derived -------------
echo "[B] tl_repo_id is a deterministic 12-hex id keyed on the remote URL"
( R="$(mkrepo "$ROOT/b" git@github.com:acme/widget.git)"
  id1="$(cd "$R" && bash -c "source \"$LIB\"; tl_repo_id")"
  id2="$(cd "$R" && bash -c "source \"$LIB\"; tl_repo_id")"
  if printf '%s' "$id1" | grep -Eq '^[0-9a-f]{12}$'; then
    ok "tl_repo_id emits exactly 12 lowercase hex chars ($id1)"
  else
    bad "tl_repo_id did not emit a 12-hex id (got '$id1')"
  fi
  [ "$id1" = "$id2" ] && ok "tl_repo_id is deterministic across calls" \
                       || bad "tl_repo_id not deterministic ($id1 vs $id2)"
) || true

# --- [C] different remote -> different id; no remote -> path-derived ----------
echo "[C] identity drives the id (remote URL, else toplevel path)"
( Ra="$(mkrepo "$ROOT/c1" git@github.com:acme/one.git)"
  Rb="$(mkrepo "$ROOT/c2" git@github.com:acme/two.git)"
  ida="$(cd "$Ra" && bash -c "source \"$LIB\"; tl_repo_id")"
  idb="$(cd "$Rb" && bash -c "source \"$LIB\"; tl_repo_id")"
  [ "$ida" != "$idb" ] && ok "distinct remotes yield distinct ids" \
                        || bad "distinct remotes collided ($ida)"
  Rc="$(mkrepo "$ROOT/c3")"   # no remote
  idc="$(cd "$Rc" && bash -c "source \"$LIB\"; tl_repo_id")"
  if printf '%s' "$idc" | grep -Eq '^[0-9a-f]{12}$'; then
    ok "remoteless repo still yields a 12-hex id from its path ($idc)"
  else
    bad "remoteless repo failed to yield a path-derived id (got '$idc')"
  fi
) || true

# --- [D] outside a git repo, tl_repo_id fails (non-zero) ----------------------
echo "[D] tl_repo_id fails outside a git repo"
( mkdir -p "$ROOT/d-nogit"
  set +e
  out="$(cd "$ROOT/d-nogit" && bash -c "source \"$LIB\"; tl_repo_id" 2>/dev/null)"; rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "tl_repo_id exits non-zero outside a git repo (rc=$rc)" \
                  || bad "tl_repo_id returned 0 outside a git repo (out='$out')"
) || true

# --- [E] tl_local_marker_path composes the id under CLAUDE_PLUGIN_DATA --------
echo "[E] tl_local_marker_path -> \$CLAUDE_PLUGIN_DATA/<id>/local.json (+mkdir)"
( R="$(mkrepo "$ROOT/e" git@github.com:acme/widget.git)"
  DATA="$ROOT/e-data"
  p="$(cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_local_marker_path")"
  id="$(cd "$R" && bash -c "source \"$LIB\"; tl_repo_id")"
  if [ "$p" = "$DATA/$id/local.json" ]; then
    ok "tl_local_marker_path returns \$DATA/<id>/local.json"
  else
    bad "tl_local_marker_path wrong path (got '$p', want '$DATA/$id/local.json')"
  fi
  [ -d "$DATA/$id" ] && ok "tl_local_marker_path created the per-repo dir" \
                     || bad "tl_local_marker_path did not mkdir the per-repo dir"
) || true

# --- [F] tl_local_marker_path fails when CLAUDE_PLUGIN_DATA is unset ----------
echo "[F] tl_local_marker_path fails closed when CLAUDE_PLUGIN_DATA is unset"
( R="$(mkrepo "$ROOT/f" git@github.com:acme/widget.git)"
  set +e
  out="$(cd "$R" && bash -c "unset CLAUDE_PLUGIN_DATA; source \"$LIB\"; tl_local_marker_path" 2>/dev/null)"; rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "tl_local_marker_path exits non-zero with no CLAUDE_PLUGIN_DATA (rc=$rc)" \
                  || bad "tl_local_marker_path returned 0 with no CLAUDE_PLUGIN_DATA (out='$out')"
) || true

# --- [G] tl_drafts_dir -> $CLAUDE_PLUGIN_DATA/<id>/drafts (+mkdir) ------------
# TDD 0012 / FR-46..49: the interview-draft files live under this dir, one
# subdir per repo (sharing TDD 0009's <repo-id> scheme).
echo "[G] tl_drafts_dir -> \$CLAUDE_PLUGIN_DATA/<id>/drafts (+mkdir)"
( R="$(mkrepo "$ROOT/g" git@github.com:acme/widget.git)"
  DATA="$ROOT/g-data"
  p="$(cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_drafts_dir")"
  id="$(cd "$R" && bash -c "source \"$LIB\"; tl_repo_id")"
  if [ "$p" = "$DATA/$id/drafts" ]; then
    ok "tl_drafts_dir returns \$DATA/<id>/drafts"
  else
    bad "tl_drafts_dir wrong path (got '$p', want '$DATA/$id/drafts')"
  fi
  [ -d "$DATA/$id/drafts" ] && ok "tl_drafts_dir created the per-repo drafts dir" \
                            || bad "tl_drafts_dir did not mkdir the drafts dir"
) || true

# --- [H] tl_drafts_dir fails closed when CLAUDE_PLUGIN_DATA is unset ----------
echo "[H] tl_drafts_dir fails closed when CLAUDE_PLUGIN_DATA is unset"
( R="$(mkrepo "$ROOT/h" git@github.com:acme/widget.git)"
  set +e
  out="$(cd "$R" && bash -c "unset CLAUDE_PLUGIN_DATA; source \"$LIB\"; tl_drafts_dir" 2>"$ROOT/H.err")"; rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    ok "tl_drafts_dir exits non-zero with no CLAUDE_PLUGIN_DATA (rc=$rc)"
  else
    bad "tl_drafts_dir returned 0 with no CLAUDE_PLUGIN_DATA (out='$out')"
  fi
  [ -s "$ROOT/H.err" ] && ok "tl_drafts_dir wrote a diagnostic to stderr" \
                       || bad "tl_drafts_dir emitted no stderr diagnostic"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== repo-id eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

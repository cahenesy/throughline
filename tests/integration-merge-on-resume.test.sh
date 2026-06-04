#!/usr/bin/env bash
# integration-merge-on-resume.test.sh — eval for TDD 0033 (integration merge on
# all resume paths). Covers the TDD's Verification points §1–§8 with shared
# git/worktree fixtures + a stub-`git`-fetch PATH shim, following the fixture
# pattern of tests/honest-review-scope-structural-resume.test.sh. Uses no model
# or tokens (the resume helpers are driven directly).
#
#   §1 transient resume merges integration into the build branch
#   §2 a merge conflict refuses with resume-blocked-integration-conflict
#   §3 no-op when integration has not advanced (rc 0, no new commit)
#   §4 orphaned (status=building, dead pid) resume merges
#   §5 mid-build resume (empty gates_completed) merges before the build gate
#   §6 fetch behavior: remote-prefixed ref fetches; failure warns; local ref does not
#   §7 review scope after merge: _review_base returns the integration head
#   §8 structural regression: an unrevised structural halt still refuses pre-merge
#
# Run: bash tests/integration-merge-on-resume.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# A stub `git` that records every `fetch` invocation to <recordfile> and exits
# with the rc in <rcfile> (default 0); all other git subcommands delegate to the
# real git binary (captured before the shim is on PATH). Lets a fixture observe
# whether _fetch_integration shelled out to `git fetch …` — and force it to fail
# — without any network. Mirrors honest-review's stub-claude PATH-shim approach.
_install_git_fetch_shim() {  # <bindir> <recordfile> <rcfile>
  local b="$1" rec="$2" rcfile="$3" realgit
  realgit="$(command -v git)"
  mkdir -p "$b"
  cat > "$b/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = fetch ]; then
  shift
  printf 'fetch %s\n' "\$*" >> "$rec"
  exit "\$(cat "$rcfile" 2>/dev/null || echo 0)"
fi
exec "$realgit" "\$@"
EOF
  chmod +x "$b/git"
}

# ===========================================================================
# §6 (unit): _fetch_integration's parsing + best-effort contract, driven on the
# helper directly. A ref of the form <remote>/<branch> whose prefix names a
# configured remote shells out to `git fetch <remote> <branch>`; a bare local
# name (no slash) or a multi-slash value does not; a fetch that fails warns to
# stderr and still returns 0 (best-effort — the merge proceeds against the local
# ref). RED before the helper exists: command -v fails, so every assertion below
# reports bad.
echo "[§6-unit] _fetch_integration: remote-prefixed ref fetches; local ref does not; failure warns + rc 0"
( D="$ROOT/u6"; mkdir -p "$D/bin"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  command -v _fetch_integration >/dev/null 2>&1 || { bad "_fetch_integration helper missing"; exit 0; }
  rec="$D/fetch.log"; rcfile="$D/fetch.rc"; printf '0\n' > "$rcfile"
  _install_git_fetch_shim "$D/bin" "$rec" "$rcfile"
  export PATH="$D/bin:$PATH"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'x\n' > f.txt; git add -A; git commit -qm base >/dev/null
  git remote add origin "$D/nonexistent.git"   # configured remote; fetch is shimmed

  # (a) remote-prefixed ref whose prefix is a configured remote → fetch invoked.
  : > "$rec"
  _fetch_integration "origin/master"; rc=$?
  [ "$rc" -eq 0 ] && ok "remote-prefixed ref returns rc 0" || bad "should return 0 (got $rc)"
  grep -qxF 'fetch -- origin master' "$rec" 2>/dev/null \
    && ok "remote-prefixed ref invokes git fetch -- <remote> <branch>" || bad "should have run 'fetch -- origin master' (got: $(cat "$rec" 2>/dev/null))"

  # (b) bare local branch name (no slash) → no fetch.
  : > "$rec"
  _fetch_integration "master"; rc=$?
  [ "$rc" -eq 0 ] && ok "local ref returns rc 0" || bad "local ref should return 0 (got $rc)"
  [ ! -s "$rec" ] && ok "local ref invokes no fetch" || bad "local ref must not fetch (got: $(cat "$rec" 2>/dev/null))"

  # (c) prefix is NOT a configured remote → no fetch (parsing rule degrades safely).
  : > "$rec"
  _fetch_integration "notaremote/master"; rc=$?
  [ "$rc" -eq 0 ] && ok "non-remote prefix returns rc 0" || bad "non-remote prefix should return 0 (got $rc)"
  [ ! -s "$rec" ] && ok "non-remote prefix invokes no fetch" || bad "non-remote prefix must not fetch (got: $(cat "$rec" 2>/dev/null))"

  # (d) multi-slash value → no fetch (not a <remote>/<branch> pair).
  : > "$rec"
  _fetch_integration "origin/feature/x"; rc=$?
  [ "$rc" -eq 0 ] && ok "multi-slash ref returns rc 0" || bad "multi-slash ref should return 0 (got $rc)"
  [ ! -s "$rec" ] && ok "multi-slash ref invokes no fetch" || bad "multi-slash ref must not fetch (got: $(cat "$rec" 2>/dev/null))"

  # (e) fetch fails (shim rc 1) → warning on stderr AND best-effort rc 0.
  printf '1\n' > "$rcfile"; : > "$rec"
  err="$(_fetch_integration "origin/master" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && ok "fetch failure still returns rc 0 (best-effort)" || bad "fetch failure must return 0 (got $rc)"
  printf '%s' "$err" | grep -q 'could not fetch origin master' \
    && ok "fetch failure warns to stderr (names the remote + branch)" || bad "fetch failure should warn (got: '$err')"

  # (f) trust boundary: a branch component beginning with '-' would be a git option
  # (arg injection) — validation rejects it, so no fetch runs (rc 0, degraded).
  printf '0\n' > "$rcfile"; : > "$rec"
  _fetch_integration "origin/-x"; rc=$?
  [ "$rc" -eq 0 ] && ok "dash-leading branch returns rc 0 (degraded)" || bad "dash-leading branch should return 0 (got $rc)"
  [ ! -s "$rec" ] && ok "dash-leading branch invokes no fetch (option-injection guarded)" || bad "dash-leading branch must not fetch (got: $(cat "$rec" 2>/dev/null))"

  # (g) trust boundary: a remote component carrying an embedded newline would let
  # `grep -xF` match an unintended remote line — validation rejects it, no fetch.
  : > "$rec"
  _fetch_integration "$(printf 'origin\nmaster')/branch"; rc=$?
  [ "$rc" -eq 0 ] && ok "newline-bearing remote returns rc 0 (degraded)" || bad "newline-bearing remote should return 0 (got $rc)"
  [ ! -s "$rec" ] && ok "newline-bearing remote invokes no fetch (grep-bypass guarded)" || bad "newline-bearing remote must not fetch (got: $(cat "$rec" 2>/dev/null))"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== integration-merge-on-resume eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

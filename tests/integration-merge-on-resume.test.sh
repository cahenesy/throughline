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

# Create a fixture with a LOCAL integration ref (master): a build-start commit on
# master, a feat/x build branch forked from it with one build commit, and — when
# <advance>=1 — an integration-only commit on master AFTER the fork (so a merge
# has real work). When <conflict>=1 the build commit and the integration commit
# edit the same line, so the merge conflicts. Leaves PWD in the repo; sets
# FEAT_HEAD and INTEG_HEAD. STATE_DIR is <dir>/state.d (outside the worktree, so
# the fixture's `git add -A` never sweeps the fragment).
_mk_local_fixture() {  # <dir> <advance> <conflict>
  local d="$1" advance="$2" conflict="$3"
  mkdir -p "$d/state.d" "$d/repo"; cd "$d/repo" || return 1
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" \
         INTEGRATION="master" CHANGE="ci" LOGDIR="$d" RESUME=1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src; printf 'base\n' > src/a.txt
  git add -A; git commit -qm "build start" >/dev/null
  git checkout -q -b feat/x
  if [ "$conflict" = 1 ]; then printf 'feat-edit\n' > src/a.txt; else printf 'feat-build\n' >> src/b.txt; fi
  git add -A; git commit -qm "build output" >/dev/null
  FEAT_HEAD="$(git rev-parse HEAD)"; INTEG_HEAD="$(git rev-parse master)"
  if [ "$advance" = 1 ]; then
    git checkout -q master
    if [ "$conflict" = 1 ]; then printf 'master-edit\n' > src/a.txt; else printf 'from-integration\n' > src/integration.txt; fi
    git add -A; git commit -qm "integration advanced" >/dev/null
    INTEG_HEAD="$(git rev-parse master)"
    git checkout -q feat/x
  fi
}

# Create a fixture with a REMOTE integration ref (origin/master): a configured
# 'origin' remote whose master has advanced past the feat/x fork, with
# refs/remotes/origin/master populated (via a real fetch, before the shim) so the
# resume merge has real work. Installs the git-fetch PATH shim so the resume's
# fetch is observed + controllable without touching the network. Leaves PWD in
# the repo; sets FEAT_HEAD, INTEG_HEAD, REC (fetch record), RCFILE (fetch rc),
# ERRF (stderr capture path). INTEGRATION=origin/master.
_mk_remote_fixture() {  # <dir>
  local d="$1" bare="$1/origin.git"
  mkdir -p "$d/state.d" "$d/repo" "$d/bin"; cd "$d/repo" || return 1
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" \
         INTEGRATION="origin/master" CHANGE="ci" LOGDIR="$d" RESUME=1
  git init --bare -q "$bare"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src; printf 'base\n' > src/a.txt; git add -A; git commit -qm "build start" >/dev/null
  git remote add origin "$bare"; git push -q origin master >/dev/null 2>&1
  git checkout -q -b feat/x; printf 'feat-build\n' >> src/b.txt; git add -A; git commit -qm "build output" >/dev/null
  FEAT_HEAD="$(git rev-parse HEAD)"
  git checkout -q master; printf 'integ\n' > src/integration.txt; git add -A; git commit -qm "integration advanced" >/dev/null
  git push -q origin master >/dev/null 2>&1
  git fetch -q origin >/dev/null 2>&1            # real fetch (before shim) populates origin/master
  INTEG_HEAD="$(git rev-parse refs/remotes/origin/master)"
  git checkout -q feat/x
  REC="$d/fetch.log"; RCFILE="$d/fetch.rc"; ERRF="$d/err"; printf '0\n' > "$RCFILE"; : > "$REC"
  _install_git_fetch_shim "$d/bin" "$REC" "$RCFILE"
  export PATH="$d/bin:$PATH"
}

# Write a standard paused/transient fragment for slug 0033-x resuming at review.
_write_paused_fragment() {  # <branch> <branch-head> [<gates-csv>] [<status>]
  _write_tdd_fragment 0033-x 33 docs/tdd/0033-x.md 1 "${4:-paused}" review 1000 1000 \
    "$1" "" log "" transient "${3:-build,test-first,verify,verify-runtime}" "" "$2" \
    "" "" "" "" "" "" "" "" ""
}

# A merge commit's HEAD has two parents — `git rev-list --parents -n1 HEAD` prints
# the commit SHA followed by its parent SHAs (3 tokens for a 2-parent merge).
_head_is_merge() { [ "$(git rev-list --parents -n1 HEAD | wc -w)" -eq 3 ]; }

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

# ===========================================================================
# §1: a TRANSIENT resume (the common paused case, NOT structural) now merges
# current integration into the build branch. Before TDD 0033 the merge was gated
# on _resumed_structural, so a transient resume left the branch on its stale base
# (the stale-base-resume blocker). RED before §2's broadening: no merge commit.
echo "[§1] transient resume merges integration into the build branch"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _mk_local_fixture "$ROOT/s1" 1 0 || { bad "setup failed"; exit 0; }
  _write_paused_fragment feat/x "$FEAT_HEAD" || { bad "fragment write failed"; exit 0; }
  F="$STATE_DIR/0033-x.json"
  _resume_from 0033-x 2>"$ROOT/s1.err"; rc=$?
  [ "$rc" -eq 0 ] && ok "transient resume accepted (rc 0)" || bad "should accept rc 0 (got $rc; stderr=$(cat "$ROOT/s1.err" 2>/dev/null))"
  _head_is_merge && ok "build branch HEAD is a merge commit (two parents)" || bad "HEAD should be a merge commit"
  pp="$(git rev-list --parents -n1 HEAD)"
  printf '%s' "$pp" | grep -qF "$FEAT_HEAD" && ok "merge parent: the old build head" || bad "merge should have the old build head as a parent (parents: $pp)"
  printf '%s' "$pp" | grep -qF "$INTEG_HEAD" && ok "merge parent: the integration head" || bad "merge should have the integration head as a parent (parents: $pp)"
  newhead="$(git rev-parse refs/heads/feat/x)"
  [ "$(_read_fragment_field "$F" branch_head_at_pause)" = "$newhead" ] \
    && ok "branch_head_at_pause advanced to the post-merge head" || bad "branch_head_at_pause should equal the post-merge head"
  grep -qF "resume: merged master into feat/x" "$ROOT/s1.err" \
    && ok "observable merge line on stderr" || bad "should log the merge line (stderr: $(cat "$ROOT/s1.err" 2>/dev/null))"
) || true

# ===========================================================================
# §2: the integration merge conflicts → abort, persist the existing
# resume-blocked-integration-conflict cause, leave the worktree clean (no
# in-progress merge, no conflict markers), return 3. The conflict contract
# (TDD 0031) is unchanged but now protects the transient path too.
echo "[§2] a transient-resume merge conflict refuses with the existing cause"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _mk_local_fixture "$ROOT/s2" 1 1 || { bad "setup failed"; exit 0; }
  _write_paused_fragment feat/x "$FEAT_HEAD" || { bad "fragment write failed"; exit 0; }
  F="$STATE_DIR/0033-x.json"; RESUME_REFUSE_CAUSE=""
  _resume_from 0033-x 2>/dev/null; rc=$?
  [ "$rc" -eq 3 ] && ok "merge conflict refuses (rc 3)" || bad "should refuse rc 3 (got $rc)"
  [ "${RESUME_REFUSE_CAUSE:-}" = "resume-blocked-integration-conflict" ] \
    && ok "RESUME_REFUSE_CAUSE=resume-blocked-integration-conflict" || bad "cause should be integration-conflict (got '${RESUME_REFUSE_CAUSE:-}')"
  [ "$(sed -n 's/.*"paused_cause":"\([^"]*\)".*/\1/p' "$F" | head -1)" = "resume-blocked-integration-conflict" ] \
    && ok "paused_cause persisted == resume-blocked-integration-conflict" || bad "paused_cause should be persisted"
  git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
    && bad "an in-progress merge was left behind (abort failed)" || ok "no in-progress merge (git merge --abort ran)"
  grep -q '^<<<<<<<' src/a.txt 2>/dev/null && bad "conflict markers left on disk" || ok "no conflict markers on disk"
  _head_is_merge && bad "a merge commit was created despite the conflict" || ok "branch has no merge commit (refused before commit)"
) || true

# ===========================================================================
# §3: no-op when integration has NOT advanced past the branch (integration is an
# ancestor of the branch) → resume proceeds, rc 0, no new commit, an observable
# "already merged" line.
echo "[§3] no-op merge when integration has not advanced (rc 0, no new commit)"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _mk_local_fixture "$ROOT/s3" 0 0 || { bad "setup failed"; exit 0; }   # advance=0: master is an ancestor of feat/x
  _write_paused_fragment feat/x "$FEAT_HEAD" || { bad "fragment write failed"; exit 0; }
  before="$(git rev-parse HEAD)"
  _resume_from 0033-x 2>"$ROOT/s3.err"; rc=$?
  [ "$rc" -eq 0 ] && ok "no-op resume accepted (rc 0)" || bad "should accept rc 0 (got $rc)"
  [ "$(git rev-parse HEAD)" = "$before" ] && ok "no new commit on the branch (already up to date)" || bad "HEAD should be unchanged"
  grep -qF "already merged" "$ROOT/s3.err" && ok "observable no-op line on stderr" || bad "should log the already-merged no-op line (stderr: $(cat "$ROOT/s3.err" 2>/dev/null))"
) || true

# ===========================================================================
# §4: an ORPHANED fragment (status=building — the TDD 0030 unclean-death shape)
# is accepted and merges. _resume_from flips building→paused/transient, derives
# the null branch_head from the branch ref, then runs the shared merge block.
echo "[§4] orphaned (status=building) resume merges integration"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _mk_local_fixture "$ROOT/s4" 1 0 || { bad "setup failed"; exit 0; }
  # Orphan shape: status=building, branch_head_at_pause null (the unclean death
  # never wrote it) → derived from refs/heads/feat/x.
  _write_tdd_fragment 0033-x 33 docs/tdd/0033-x.md 1 building build 1000 1000 \
    feat/x "" log "" "" "build,test-first" "" "" "" "" "" "" "" "" "" "" "" \
    || { bad "fragment write failed"; exit 0; }
  _resume_from 0033-x 2>"$ROOT/s4.err"; rc=$?
  [ "$rc" -eq 0 ] && ok "orphaned resume accepted (rc 0)" || bad "should accept rc 0 (got $rc; stderr=$(cat "$ROOT/s4.err" 2>/dev/null))"
  _head_is_merge && ok "orphaned resume produced the merge commit" || bad "HEAD should be a merge commit"
  git merge-base --is-ancestor "$INTEG_HEAD" HEAD 2>/dev/null \
    && ok "integration head is now an ancestor of the branch" || bad "integration should be merged into the branch"
) || true

# ===========================================================================
# §6 (through-resume): the fetch runs before the merge, degrades on failure, and
# is skipped for a local ref — observed end-to-end through _resume_from.
echo "[§6a] remote integration: fetch runs before the merge (origin/master)"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _mk_remote_fixture "$ROOT/s6a" || { bad "setup failed"; exit 0; }
  _write_paused_fragment feat/x "$FEAT_HEAD" || { bad "fragment write failed"; exit 0; }
  : > "$REC"
  _resume_from 0033-x 2>"$ERRF"; rc=$?
  [ "$rc" -eq 0 ] && ok "remote-ref resume accepted (rc 0)" || bad "should accept rc 0 (got $rc; stderr=$(cat "$ERRF" 2>/dev/null))"
  grep -qxF 'fetch -- origin master' "$REC" && ok "resume invoked git fetch -- origin master" || bad "resume should fetch origin master (got: $(cat "$REC" 2>/dev/null))"
  _head_is_merge && ok "merge ran after the fetch (HEAD is a merge commit)" || bad "merge should run after the fetch"
) || true

echo "[§6b] remote integration: fetch failure warns + the merge still runs"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _mk_remote_fixture "$ROOT/s6b" || { bad "setup failed"; exit 0; }
  printf '1\n' > "$RCFILE"                          # fetch shim exits 1
  _write_paused_fragment feat/x "$FEAT_HEAD" || { bad "fragment write failed"; exit 0; }
  _resume_from 0033-x 2>"$ERRF"; rc=$?
  [ "$rc" -eq 0 ] && ok "resume still accepted despite fetch failure (rc 0)" || bad "should accept rc 0 (got $rc)"
  grep -qF "could not fetch origin master" "$ERRF" && ok "fetch failure warns to stderr" || bad "should warn on fetch failure (stderr: $(cat "$ERRF" 2>/dev/null))"
  _head_is_merge && ok "the merge still runs against the local ref (degraded)" || bad "merge should run even when the fetch failed"
) || true

echo "[§6c] local integration ref: no fetch is invoked"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _mk_local_fixture "$ROOT/s6c" 1 0 || { bad "setup failed"; exit 0; }
  rec="$ROOT/s6c.fetch"; rcfile="$ROOT/s6c.rc"; printf '0\n' > "$rcfile"; : > "$rec"
  _install_git_fetch_shim "$ROOT/s6c-bin" "$rec" "$rcfile"
  export PATH="$ROOT/s6c-bin:$PATH"
  _write_paused_fragment feat/x "$FEAT_HEAD" || { bad "fragment write failed"; exit 0; }
  _resume_from 0033-x 2>/dev/null; rc=$?
  [ "$rc" -eq 0 ] && ok "local-ref resume accepted (rc 0)" || bad "should accept rc 0 (got $rc)"
  [ ! -s "$rec" ] && ok "no fetch invoked for a local integration ref" || bad "local ref must not fetch (got: $(cat "$rec" 2>/dev/null))"
  _head_is_merge && ok "the local-ref merge still runs" || bad "local-ref merge should run"
) || true

# ===========================================================================
# §8: structural regression. A blocked/structural-finding fragment whose
# integration TDD copy is byte-identical to the halt-time fingerprint still
# refuses with resume-blocked-tdd-unrevised BEFORE any merge — the precondition
# check must keep short-circuiting now that the merge block is unconditional.
echo "[§8] unrevised structural halt still refuses pre-merge (no merge commit)"
( TDDS=(); THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  D="$ROOT/s8"; mkdir -p "$D/state.d" "$D/repo"; cd "$D/repo" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D" RESUME=1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd src
  printf '# TDD 0033\nStatus: draft\n## Approach\nv1\n' > docs/tdd/0033-x.md
  printf 'orig\n' > src/a.txt
  git add -A; git commit -qm "build start (TDD v1)" >/dev/null
  git checkout -q -b feat/x
  printf 'build\n' >> src/a.txt; git add -A; git commit -qm "build output" >/dev/null   # TDD unchanged
  FEAT_HEAD="$(git rev-parse HEAD)"
  _write_tdd_fragment 0033-x 33 docs/tdd/0033-x.md 1 blocked review 1000 1000 \
    feat/x "" log "" "" "build,test-first,verify,verify-runtime" "" "$FEAT_HEAD" "" "" "" "" "" "" "" "" "" \
    || { bad "fragment write failed"; exit 0; }
  set_halt_cause 0033-x structural-finding review:1 "(b)"   # records tdd_rev == integration's (unrevised) blob
  RESUME_REFUSE_CAUSE=""
  _resume_from 0033-x 2>/dev/null; rc=$?
  [ "$rc" -eq 3 ] && ok "unrevised structural resume refuses (rc 3)" || bad "should refuse rc 3 (got $rc)"
  [ "${RESUME_REFUSE_CAUSE:-}" = "resume-blocked-tdd-unrevised" ] \
    && ok "RESUME_REFUSE_CAUSE=resume-blocked-tdd-unrevised (precondition fired)" || bad "cause should be tdd-unrevised (got '${RESUME_REFUSE_CAUSE:-}')"
  [ "$(git rev-parse HEAD)" = "$FEAT_HEAD" ] && ok "branch unchanged — no merge ran before the refusal" || bad "branch should be unchanged (no pre-merge)"
  _head_is_merge && bad "a merge commit was created before the structural precondition refused" || ok "no merge commit (refused before the merge block)"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== integration-merge-on-resume eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# gated-implementation.test.sh — eval for TDD 0052 (single PR-publish path,
# FR-16/FR-19/FR-27/FR-69; ADR 0006; folded bugs A8, A6, A7).
#
# `/implement` published a built TDD via three drifted copies of the same
# push → `gh pr create --fill` → record-url → coverage-pointer block; the drift
# swallowed publish failures in two of the three modes (A8), a combined-mode
# checkout failure left the build on a detached HEAD (A6), and a total
# install_deps failure was discarded (A7). This eval pins the consolidated
# `_publish_pr` helper's contract and the loud surfacing of all three failures.
#
#   §1 _publish_pr happy path: url on stdout, rc 0, coverage pointer invoked,
#      base passed through verbatim (the sequential caller strips origin/)
#   §2 A8: push failure → rc 1 + "push failed" diagnostic on fd 2; create
#      failure (non-zero OR empty url) → rc 2 + "PR create failed"; stdout
#      stays empty; CLI stderr lands in <log>; never a silent success
#
# Run: bash tests/gated-implementation.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
REALGIT="$(command -v git)"
RESULTS="$(mktemp)"
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"; rm -f "$RESULTS"' EXIT

# mkstubs <dir> — git/gh stubs in <dir>/bin recording invocations to
# <dir>/git.log + <dir>/gh.log. Controls: push_rc (git push exit), create_rc
# (gh pr create exit), create_out (gh pr create stdout). Everything but `git
# push` passes through to the real git so repo plumbing keeps working.
mkstubs() {
  local d="$1"; mkdir -p "$d/bin"
  cat > "$d/bin/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/git.log"
if [ "\${1:-}" = push ]; then
  rc="\$(cat "$d/push_rc" 2>/dev/null || echo 0)"
  [ "\$rc" != 0 ] && echo "stub: push refused" >&2
  exit "\$rc"
fi
exec "$REALGIT" "\$@"
EOF
  cat > "$d/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/gh.log"
if [ "\${1:-} \${2:-}" = "pr create" ]; then
  rc="\$(cat "$d/create_rc" 2>/dev/null || echo 0)"
  if [ "\$rc" = 0 ]; then cat "$d/create_out" 2>/dev/null
  else echo "stub: create refused" >&2; fi
  exit "\$rc"
fi
exit 0
EOF
  chmod +x "$d/bin/git" "$d/bin/gh"
}

# ===========================================================================
# §1: _publish_pr <branch> <base> <log> happy path — the one publish path all
# three modes call. Asserts the url-on-stdout/rc-0 contract, the push + create
# CLI argument shapes, the TDD 0044 coverage-pointer invocation, and (the
# stacked-PR elephant) that the base argument reaches gh verbatim — the
# sequential caller passes the already-`origin/`-stripped base.
echo "[§1] _publish_pr happy path: url on stdout, rc 0, pointer invoked, base verbatim"
( D="$ROOT/s1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D" REPORT="$D/report.md"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §1 — source guard missing"; exit 0; }
  command -v _publish_pr >/dev/null 2>&1 || { bad "_publish_pr is not defined after sourcing"; exit 0; }
  mkstubs "$D"; PATH="$D/bin:$PATH"
  printf 'https://example.test/pr/1\n' > "$D/create_out"

  # parallel shape: feat/<slug> onto the run base.
  out="$(_publish_pr "feat/0001-alpha" "master" "$D/pub.log" 2>>"$D/pub.log")"; rc=$?
  [ "$rc" -eq 0 ] && ok "rc 0 on success" || bad "expected rc 0 (got $rc)"
  [ "$out" = "https://example.test/pr/1" ] && ok "PR url on stdout" || bad "expected the url on stdout (got [$out])"
  grep -q '^push -u origin feat/0001-alpha$' "$D/git.log" 2>/dev/null \
    && ok "pushes the branch (-u origin)" || bad "expected git push -u origin feat/0001-alpha (got: $(cat "$D/git.log" 2>/dev/null))"
  grep -q '^pr create --base master --head feat/0001-alpha --fill$' "$D/gh.log" 2>/dev/null \
    && ok "creates the PR with --base/--head/--fill" || bad "expected gh pr create --base master --head feat/0001-alpha --fill (got: $(cat "$D/gh.log" 2>/dev/null))"
  grep -q '^pr comment https://example.test/pr/1 ' "$D/gh.log" 2>/dev/null \
    && ok "coverage pointer invoked on success (TDD 0044 / FR-78)" || bad "expected a gh pr comment on the created PR"

  # sequential shape: the caller strips origin/ from the stacked base; the
  # helper is mode-agnostic and must pass it through untouched.
  : > "$D/gh.log"
  prev="origin/master"; pbase="${prev#origin/}"
  out="$(_publish_pr "ci/0002-beta" "$pbase" "$D/pub.log" 2>>"$D/pub.log")"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "https://example.test/pr/1" ] \
    && ok "sequential shape returns the url" || bad "sequential shape must succeed (rc=$rc, out=[$out])"
  grep -q '^pr create --base master --head ci/0002-beta --fill$' "$D/gh.log" 2>/dev/null \
    && ok "stacked base arrives origin/-stripped and verbatim" || bad "expected --base master for the stacked PR (got: $(cat "$D/gh.log" 2>/dev/null))"
  grep -q -- '--base origin/master' "$D/gh.log" 2>/dev/null \
    && bad "an origin/-prefixed base must never reach gh" || ok "no origin/-prefixed base reached gh"
) || true

# ===========================================================================
# §2: A8 regression — a publish failure is LOUD in the shared helper: empty
# stdout (the url-or-empty contract), a non-empty diagnostic on fd 2, and a
# distinct rc (1 push / 2 create). Pre-fix the parallel and combined sites
# swallowed both failures; the helper makes the sequential site's diagnostics
# the single shared contract (ADR 0006: no false success).
echo "[§2] A8: push/create failures are loud — empty stdout, fd-2 diagnostic, rc 1/2"
( D="$ROOT/s2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D" REPORT="$D/report.md"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §2 — source guard missing"; exit 0; }
  command -v _publish_pr >/dev/null 2>&1 || { bad "_publish_pr is not defined after sourcing"; exit 0; }
  mkstubs "$D"; PATH="$D/bin:$PATH"
  printf 'https://example.test/pr/9\n' > "$D/create_out"

  # push fails → rc 1, empty stdout, "push failed" diagnostic, create not attempted.
  printf '1\n' > "$D/push_rc"
  out="$(_publish_pr "feat/0001-alpha" "master" "$D/pub.log" 2>"$D/err")"; rc=$?
  [ "$rc" -eq 1 ] && ok "push failure returns rc 1" || bad "expected rc 1 on push failure (got $rc)"
  [ -z "$out" ] && ok "push failure yields empty stdout" || bad "stdout must be empty on push failure (got [$out])"
  grep -q 'push failed' "$D/err" 2>/dev/null \
    && ok "non-empty 'push failed' diagnostic on fd 2 (not swallowed)" || bad "expected a push-failed diagnostic on fd 2 (got: $(cat "$D/err" 2>/dev/null))"
  grep -q '^pr create' "$D/gh.log" 2>/dev/null \
    && bad "PR create must not be attempted after a failed push" || ok "no PR create after a failed push"
  grep -q 'stub: push refused' "$D/pub.log" 2>/dev/null \
    && ok "push stderr appended to <log>" || bad "push stderr must land in <log>"

  # create fails → rc 2, empty stdout, "PR create failed" diagnostic, no pointer.
  printf '0\n' > "$D/push_rc"; printf '1\n' > "$D/create_rc"; : > "$D/gh.log"
  out="$(_publish_pr "ci" "master" "$D/pub.log" 2>"$D/err")"; rc=$?
  [ "$rc" -eq 2 ] && ok "create failure returns rc 2" || bad "expected rc 2 on create failure (got $rc)"
  [ -z "$out" ] && ok "create failure yields empty stdout" || bad "stdout must be empty on create failure (got [$out])"
  grep -q 'PR create failed' "$D/err" 2>/dev/null \
    && ok "'PR create failed' diagnostic on fd 2" || bad "expected a create-failed diagnostic on fd 2 (got: $(cat "$D/err" 2>/dev/null))"
  grep -q '^pr comment' "$D/gh.log" 2>/dev/null \
    && bad "no coverage pointer may be posted on a failed create" || ok "coverage pointer not invoked on failure"
  grep -q 'stub: create refused' "$D/pub.log" 2>/dev/null \
    && ok "create stderr appended to <log>" || bad "create stderr must land in <log>"

  # create exits 0 but prints NO url → still a loud create failure (rc 2):
  # an empty url recorded as success is exactly the A8 false-success shape.
  printf '0\n' > "$D/create_rc"; : > "$D/create_out"; : > "$D/err"
  out="$(_publish_pr "ci" "master" "$D/pub.log" 2>"$D/err")"; rc=$?
  [ "$rc" -eq 2 ] && [ -z "$out" ] && grep -q 'PR create failed' "$D/err" 2>/dev/null \
    && ok "rc-0-but-empty-url create surfaces as a create failure" \
    || bad "empty-url create must fail loud (rc=$rc, out=[$out], err: $(cat "$D/err" 2>/dev/null))"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== gated-implementation eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

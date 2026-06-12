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
#   §2b wiring: the push/create CLI invocations live ONLY in _publish_pr; the
#      three mode sites are thin delegates keeping mode-specific bookkeeping
#      (sequential rc→wording, combined loud report lines, parallel
#      PARPUBLISH:: marker + render, stacked base stripped at the caller)
#   §3 A6: a combined-mode checkout failure FAILs every queued TDD with a
#      combined-checkout-failed cause and never builds on the detached HEAD
#   §4 A7: a total install_deps failure FAILs the affected TDD(s) with a
#      deps-install-failed cause (sequential shared worktree + parallel
#      per-TDD worktree) instead of building against missing deps
#   §W dogfood: wiring this eval into the aggregator makes the aggregator's
#      final AND-chain go non-zero when this eval fails (TDD 0038 §3 rule)
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

# ===========================================================================
# §2b: single-source-of-truth wiring (FR-69, reuse #5) — the push/create CLI
# invocations live ONLY in _publish_pr; all three mode sites delegate to it
# and keep their mode-specific bookkeeping: sequential report wording derived
# from the helper's rc (the shared contract), combined loud report lines,
# the parallel subshell's PARPUBLISH:: marker rendered by the reporting loop,
# and the stacked-PR base still origin/-stripped at the sequential call site
# (the TDD's elephant — the helper stays mode-agnostic).
echo "[§2b] wiring: one publish CLI site; three thin _publish_pr callers with mode wording"
( cnt() { grep -cF "$1" "$IMPL"; }
  [ "$(cnt 'git push -u origin')" = "1" ] \
    && ok "git push CLI appears exactly once (inside _publish_pr)" \
    || bad "expected exactly 1 'git push -u origin' in implement.sh (got $(cnt 'git push -u origin'))"
  [ "$(cnt 'gh pr create --base')" = "1" ] \
    && ok "gh pr create CLI appears exactly once (inside _publish_pr)" \
    || bad "expected exactly 1 'gh pr create --base' in implement.sh (got $(cnt 'gh pr create --base'))"
  [ "$(cnt '$(_publish_pr ')" = "3" ] \
    && ok "all three mode sites call _publish_pr" \
    || bad "expected 3 _publish_pr call sites (got $(cnt '$(_publish_pr '))"
  grep -qF 'pbase="${prev#origin/}"' "$IMPL" \
    && ok "sequential caller still strips origin/ from the stacked base" \
    || bad "the origin/ strip must stay at the sequential call site"
  grep -qF '_publish_pr "$branch" "$pbase" "$log"' "$IMPL" \
    && ok "sequential site passes the stripped base to the helper" \
    || bad "sequential site must pass \$pbase to _publish_pr"
  grep -qF 'pr=", push failed (see log)"' "$IMPL" && grep -qF 'pr=", PR create failed (see log)"' "$IMPL" \
    && ok "sequential report wording derives from the helper's rc" \
    || bad "sequential push/create failure wording missing"
  grep -qF 'Combined PR NOT opened: push failed' "$IMPL" && grep -qF 'Combined PR NOT opened: PR create failed' "$IMPL" \
    && ok "combined mode reports a publish failure loudly (A8: was swallowed)" \
    || bad "combined publish-failure report wording missing"
  grep -qF 'PARPUBLISH::push failed (see log)' "$IMPL" && grep -qF 'PARPUBLISH::PR create failed (see log)' "$IMPL" \
    && ok "parallel subshell records a publish-failure marker (A8: was swallowed)" \
    || bad "parallel PARPUBLISH:: failure markers missing"
  grep -qF "sed -n 's/^PARPUBLISH:://p'" "$IMPL" \
    && ok "parallel reporting loop renders the publish-failure marker" \
    || bad "the reporting loop must read PARPUBLISH:: from the log"
) || true

# ===========================================================================
# §3: A6 regression (full runner, git/claude stubbed) — the combined-mode
# worktree is created --detach, so a failed `git checkout -b $CHANGE` (and its
# resume fallback) pre-fix left the whole combined build committing onto a
# detached HEAD, silently. The runner must FAIL every queued TDD with a
# combined-checkout-failed cause, surface it in the report, and never start a
# build gate on the detached HEAD.
echo "[§3] A6: combined checkout failure FAILs the queue; no build on a detached HEAD"
( D="$ROOT/s3"; mkdir -p "$D/repo/docs/tdd" "$D/bin"
  cd "$D/repo" || { bad "INFRA: §3 — cd failed"; exit 0; }
  git init -q; git config user.email t@t.t; git config user.name t
  for s in 0001-alpha 0002-beta; do
    printf '# TDD %s\nStatus: ready\nPRD refs: 1\nPRD-rev: deadbee\nADR constraints: none\n\n## Approach\nstub\n' "$s" > "docs/tdd/$s.md"
  done
  git add -A; git commit -qm init
  cat > "$D/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = checkout ]; then echo "stub: checkout refused" >&2; exit 1; fi
exec "$REALGIT" "\$@"
EOF
  cat > "$D/bin/claude" <<EOF
#!/usr/bin/env bash
echo invoked >> "$D/claude.log"
echo "BATCH_RESULT: FAIL stub build must never run"
EOF
  chmod +x "$D/bin/git" "$D/bin/claude"
  PATH="$D/bin:$PATH" CI_CHECKS_TEST_CMD="true" CI_CHECKS_TYPECHECK_CMD="" CI_CHECKS_LINT_CMD="" \
    bash "$IMPL" --combined --change ci >/dev/null 2>&1
  RPT="$(ls -t docs/tdd/.implement-logs/*/report.md 2>/dev/null | head -1)"
  SD="$(dirname "${RPT:-/nonexistent}")/state.d"
  grep -q 'combined-checkout-failed' "${RPT:-/nonexistent}" 2>/dev/null \
    && ok "report names the checkout failure (clear cause)" \
    || bad "report must carry combined-checkout-failed (tail: $(tail -3 "${RPT:-/nonexistent}" 2>/dev/null))"
  for s in 0001-alpha 0002-beta; do
    grep -q '"status":"failed"' "$SD/$s.json" 2>/dev/null && grep -q 'combined-checkout-failed' "$SD/$s.json" 2>/dev/null \
      && ok "$s FAILed with the combined-checkout-failed cause" \
      || bad "$s fragment must be failed + combined-checkout-failed (got: $(cat "$SD/$s.json" 2>/dev/null))"
  done
  [ -e "$D/claude.log" ] \
    && bad "build gate ran despite the failed checkout (detached-HEAD build)" \
    || ok "no build gate ran on the detached HEAD"
  grep -q 'Opened ONE combined PR' "${RPT:-/nonexistent}" 2>/dev/null \
    && bad "a PR must not be opened after a checkout failure" \
    || ok "no PR opened after the checkout failure"
) || true

# ===========================================================================
# §4: A7 regression (full runner, npm/claude stubbed) — install_deps returns
# non-zero ONLY on a total failure (locked AND plain install both failed);
# pre-fix both drivers discarded that rc and built against missing deps,
# failing opaquely downstream. The affected TDD(s) must FAIL with a
# deps-install-failed cause and no build gate may start. THROUGHLINE_SKIP_DEPS
# is pinned to 0 so an ambient skip cannot mask the install (env-leak guard).
echo "[§4] A7: total install_deps failure FAILs the TDD with deps-install-failed (both drivers)"
( D="$ROOT/s4"; mkdir -p "$D/repo/docs/tdd" "$D/bin"
  cd "$D/repo" || { bad "INFRA: §4 — cd failed"; exit 0; }
  git init -q; git config user.email t@t.t; git config user.name t
  printf '# TDD 0001: alpha\nStatus: ready\nPRD refs: 1\nPRD-rev: deadbee\nADR constraints: none\n\n## Approach\nstub\n' > docs/tdd/0001-alpha.md
  printf '{ "name": "x", "private": true, "version": "0.0.0" }\n' > package.json
  git add -A; git commit -qm init
  cat > "$D/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "stub: npm install refused" >&2
exit 1
EOF
  cat > "$D/bin/claude" <<EOF
#!/usr/bin/env bash
echo invoked >> "$D/claude.log"
echo "BATCH_RESULT: FAIL stub build must never run"
EOF
  chmod +x "$D/bin/npm" "$D/bin/claude"

  # sequential driver: the shared worktree's install fails -> queue FAILs.
  THROUGHLINE_SKIP_DEPS=0 PATH="$D/bin:$PATH" CI_CHECKS_TEST_CMD="true" CI_CHECKS_TYPECHECK_CMD="" CI_CHECKS_LINT_CMD="" \
    bash "$IMPL" --change ci >/dev/null 2>&1
  RPT="$(ls -t docs/tdd/.implement-logs/*/report.md 2>/dev/null | head -1)"
  SD="$(dirname "${RPT:-/nonexistent}")/state.d"
  grep -q 'deps-install-failed' "${RPT:-/nonexistent}" 2>/dev/null \
    && ok "sequential: report names the deps failure (clear cause)" \
    || bad "sequential: report must carry deps-install-failed (tail: $(tail -3 "${RPT:-/nonexistent}" 2>/dev/null))"
  grep -q '"status":"failed"' "$SD/0001-alpha.json" 2>/dev/null && grep -q 'deps-install-failed' "$SD/0001-alpha.json" 2>/dev/null \
    && ok "sequential: TDD FAILed with the deps-install-failed cause" \
    || bad "sequential: fragment must be failed + deps-install-failed (got: $(cat "$SD/0001-alpha.json" 2>/dev/null))"
  [ -e "$D/claude.log" ] \
    && bad "sequential: build gate ran despite the deps failure" \
    || ok "sequential: no build gate ran against missing deps"

  # parallel driver: the per-TDD worktree's install fails -> that TDD FAILs.
  sleep 1   # second-granularity LOGDIR timestamps: force a fresh run dir
  THROUGHLINE_SKIP_DEPS=0 PATH="$D/bin:$PATH" CI_CHECKS_TEST_CMD="true" CI_CHECKS_TYPECHECK_CMD="" CI_CHECKS_LINT_CMD="" \
    bash "$IMPL" --parallel --change ci2 >/dev/null 2>&1
  RPT="$(ls -t docs/tdd/.implement-logs/*/report.md 2>/dev/null | head -1)"
  SD="$(dirname "${RPT:-/nonexistent}")/state.d"
  grep -q 'FAIL (deps-install-failed)' "${RPT:-/nonexistent}" 2>/dev/null \
    && ok "parallel: report line renders the deps failure" \
    || bad "parallel: report must render FAIL (deps-install-failed) (tail: $(tail -3 "${RPT:-/nonexistent}" 2>/dev/null))"
  grep -q '"status":"failed"' "$SD/0001-alpha.json" 2>/dev/null && grep -q 'deps-install-failed' "$SD/0001-alpha.json" 2>/dev/null \
    && ok "parallel: TDD FAILed with the deps-install-failed cause" \
    || bad "parallel: fragment must be failed + deps-install-failed (got: $(cat "$SD/0001-alpha.json" 2>/dev/null))"
  [ -e "$D/claude.log" ] \
    && bad "parallel: build gate ran despite the deps failure" \
    || ok "parallel: no build gate ran against missing deps"
) || true

# ===========================================================================
# §W: dogfood (TDD 0038 §3 wire-in rule) — registering this eval in the
# aggregator adds a GIM_FAIL accumulator to its final AND-chain, so the
# aggregator now exits non-zero on a new condition. Drive the REAL extracted
# chain with every accumulator green EXCEPT this eval's, stubbed to fail:
# before the wire-in the chain never references GIM_FAIL and evaluates true
# (RED); after, it includes the term and evaluates false (GREEN).
echo "[§W] dogfood: wiring this eval into the aggregator makes its exit go non-zero when the eval fails"
( AGG="$REPO/tests/implement-gate.test.sh"
  if [ ! -r "$AGG" ]; then bad "INFRA: §W — aggregator unreadable: $AGG"; exit 0; fi
  # Structural: the new eval is registered (run) in the aggregator. Anchored on
  # the eval filename so an unwired aggregator is RED.
  grep -q 'gated-implementation\.test\.sh' "$AGG" 2>/dev/null \
    && ok "the new eval is wired into the aggregator (registration present)" \
    || bad "the new eval must be registered in the aggregator"
  # Behavioral: extract the aggregator's real final AND-chain verbatim and
  # evaluate it against stub integers (no recursion into the sub-evals).
  chain="$(grep -aE '^\[ "\$FAIL" -eq 0 \] &&' "$AGG" | tail -1)"
  if [ -z "$chain" ]; then bad "INFRA: §W — could not locate the aggregator final AND-chain"; exit 0; fi
  drive_rc="$(
    set +u
    for v in $(printf '%s' "$chain" | grep -aoE '\$[A-Za-z_][A-Za-z0-9_]*' | tr -d '$' | sort -u); do
      eval "$v=0"
    done
    GIM_FAIL=1
    eval "$chain"; echo $?
  )"
  [ "$drive_rc" != "0" ] \
    && ok "aggregator final AND-chain goes non-zero when the new eval fails (wire-in propagates)" \
    || bad "aggregator AND-chain must be non-zero with GIM_FAIL=1 (got rc=$drive_rc)"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== gated-implementation eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

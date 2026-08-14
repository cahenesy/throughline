#!/usr/bin/env bash
# implement-gate.test.sh — aggregator after TDD 0063 coprocess retirement.
#
# The claude -p runner is not flip authority. This file no longer executes
# implement.sh scenarios or the coprocess-only evals it used to chain.
#
# Retired-with-coprocess (still in tree; not invoked here):
#   implement-gate [A]–[S] (inline implement.sh scenarios)
#   run-progress-visibility.test.sh
#   token-spend-reduction.test.sh
#   bounded-tdd-scope.test.sh
#   state-module-sourceability.test.sh
#   pause-retry-module-sourceability.test.sh
#   gates-resume-module-sourceability.test.sh
#   bounded-rework-loop.test.sh
#   structural-classification-bound.test.sh
#   run-recovery.test.sh
#   build-coprocess-lifecycle.test.sh
#   build-observability.test.sh
#   interactive-draft-persistence.test.sh
#   runner-resilience.test.sh
#   coproc-verdict-resilience.test.sh
#   honest-review-scope-structural-resume.test.sh
#   severity-honest-reporting.test.sh
#   build-phase-learning-capture.test.sh
#   build-defensive-norms.test.sh
#   interrogator-discipline.test.sh
#   evaluation-rubric.test.sh
#   step-commit-protocol.test.sh
#   integration-merge-on-resume.test.sh
#   runtime-verify-resume.test.sh
#   watcher-inactivity-completion.test.sh
#   recoverable-terminal-halts.test.sh
#   test-first-per-step.test.sh
#   transient-gate-resilience.test.sh
#   bounded-rework-convergence.test.sh
#   coverage-map.test.sh
#   review-lenses.test.sh
#   surgical-norm.test.sh
#   tdd-author-redteam.test.sh
#   md-parser.test.sh
#   gate-effort.test.sh
#   detached-run-recovery.test.sh
#   json-helper.test.sh
#   gated-implementation.test.sh
#   state-carryforward-quotesafe.test.sh
#   combined-resume-skip.test.sh
#
# Kept (0060–0062): plugin-root, verdicts, run-record, build-tdds-skill.
#
# Run: bash tests/implement-gate.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# --- TDD 0063 observations (soft delegates / coprocess retirement) -----------
echo "[0063] soft delegates and coprocess retirement"
ROOT63="$(mktemp -d)"
trap 'rm -rf "$ROOT63" "$RESULTS"' EXIT
mkdir -p "$ROOT63/bin" "$ROOT63/empty" "$ROOT63/paused"
git init -q "$ROOT63/empty"
git -C "$ROOT63/empty" config user.email t@t.t
git -C "$ROOT63/empty" config user.name t
printf '# empty\n' > "$ROOT63/empty/README.md"
git -C "$ROOT63/empty" add README.md
git -C "$ROOT63/empty" commit -qm init
git init -q "$ROOT63/paused"
git -C "$ROOT63/paused" config user.email t@t.t
git -C "$ROOT63/paused" config user.name t
printf '# paused\n' > "$ROOT63/paused/README.md"
git -C "$ROOT63/paused" add README.md
git -C "$ROOT63/paused" commit -qm init
cat > "$ROOT63/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'claude %s\n' "\$*" >> "$ROOT63/spawned"
exit 0
EOF
cat > "$ROOT63/bin/grok" <<EOF
#!/usr/bin/env bash
printf 'grok %s\n' "\$*" >> "$ROOT63/spawned"
exit 0
EOF
chmod +x "$ROOT63/bin/claude" "$ROOT63/bin/grok"
SAFE_PATH="$ROOT63/bin:/usr/bin:/bin"

# 1. plugin.json dependencies empty/null
if command -v jq >/dev/null 2>&1 \
   && jq -e '(.dependencies|length)==0 or .dependencies==null' \
        "$REPO/.claude-plugin/plugin.json" >/dev/null 2>&1; then
  ok "plugin.json dependencies empty or null"
else
  bad "plugin.json still declares hard dependencies"
fi

# 1b. marketplace.json: no cross-marketplace allowlist / per-plugin deps
if command -v jq >/dev/null 2>&1 \
   && jq -e 'has("allowCrossMarketplaceDependenciesOn")|not' \
        "$REPO/.claude-plugin/marketplace.json" >/dev/null 2>&1 \
   && jq -e 'all(.plugins[]?; ((.dependencies|length)//0)==0)' \
        "$REPO/.claude-plugin/marketplace.json" >/dev/null 2>&1; then
  ok "marketplace.json has no cross-marketplace or per-plugin dependencies"
else
  bad "marketplace.json still allowlists or lists plugin dependencies"
fi

# 2. implement.sh exits 2; stderr contains /build-tdds; no claude/grok child
rm -f "$ROOT63/spawned"
set +e
impl_err="$ROOT63/impl.err"
( cd "$ROOT63/empty" && PATH="$SAFE_PATH" timeout 8 bash "$IMPL" \
    >/dev/null 2>"$impl_err" )
impl_rc=$?
set +e
[ "$impl_rc" -eq 2 ] && ok "implement.sh exits 2" \
  || bad "implement.sh rc=$impl_rc want 2"
grep -q '/build-tdds' "$impl_err" \
  && ok "implement.sh stderr contains /build-tdds" \
  || bad "implement.sh stderr missing /build-tdds (got: $(tr '\n' ' ' <"$impl_err"))"
if [ -f "$ROOT63/spawned" ]; then
  bad "implement.sh spawned claude/grok: $(tr '\n' ' ' <"$ROOT63/spawned")"
else
  ok "implement.sh did not spawn claude/grok"
fi

# 3. implement-watch.sh same fail-closed stub
rm -f "$ROOT63/spawned"
set +e
watch_err="$ROOT63/watch.err"
( cd "$ROOT63/empty" && PATH="$SAFE_PATH" THROUGHLINE_WATCH_POLL_SECS=1 \
    timeout 8 bash "$REPO/scripts/implement-watch.sh" \
    >/dev/null 2>"$watch_err" )
watch_rc=$?
set +e
[ "$watch_rc" -eq 2 ] && ok "implement-watch.sh exits 2" \
  || bad "implement-watch.sh rc=$watch_rc want 2"
grep -q '/build-tdds' "$watch_err" \
  && ok "implement-watch.sh stderr contains /build-tdds" \
  || bad "implement-watch.sh stderr missing /build-tdds (got: $(tr '\n' ' ' <"$watch_err"))"
if [ -f "$ROOT63/spawned" ]; then
  bad "implement-watch.sh spawned claude/grok: $(tr '\n' ' ' <"$ROOT63/spawned")"
else
  ok "implement-watch.sh did not spawn claude/grok"
fi

# 3b. status.sh: no latest/run.json → exact no-run message
set +e
status_none="$(cd "$ROOT63/empty" && bash "$REPO/scripts/status.sh" 2>/dev/null)"
status_none_rc=$?
set +e
[ "$status_none_rc" -eq 0 ] && [ "$status_none" = "no active /build-tdds run" ] \
  && ok "status.sh no-run message is exact" \
  || bad "status.sh no-run: rc=$status_none_rc out='${status_none}'"

# 3c. fixture latest/run.json + one paused slug
# shellcheck source=scripts/lib/run-record.sh
. "$REPO/scripts/lib/run-record.sh"
tl_run_init "$ROOT63/paused" fixture-run
tl_run_set_tdd "$ROOT63/paused" fixture-run 0063-alpha paused ratelimit review
set +e
status_paused="$(cd "$ROOT63/paused" && bash "$REPO/scripts/status.sh" 2>/dev/null)"
status_paused_rc=$?
set +e
status_nlines="$(printf '%s\n' "$status_paused" | grep -c . || true)"
[ "$status_paused_rc" -eq 0 ] && ok "paused-run status.sh exits 0" \
  || bad "paused-run status.sh rc=$status_paused_rc"
printf '%s\n' "$status_paused" | grep -q 'paused' \
  && ok "paused-run stdout contains paused" \
  || bad "paused-run stdout missing paused (got: $(printf '%s' "$status_paused" | tr '\n' ' '))"
printf '%s\n' "$status_paused" | grep -q 'estimate' \
  && ok "paused-run stdout contains estimate" \
  || bad "paused-run stdout missing estimate"
printf '%s\n' "$status_paused" | grep -q 're-run /build-tdds' \
  && ok "paused-run stdout contains re-run /build-tdds" \
  || bad "paused-run stdout missing re-run /build-tdds"
[ "$status_nlines" -le 24 ] && ok "paused-run line count ≤24 ($status_nlines)" \
  || bad "paused-run line count $status_nlines > 24"

# 4. aggregator no longer invokes a known coprocess eval
# Double-quoted pattern expands to bash "$BCL" so it matches a live call
# and not this assertion's escaped source.
if grep -vE '^[[:space:]]*#' "$0" | grep -q "bash \"\$BCL\""; then
  bad "aggregator still invokes the coprocess-lifecycle eval"
else
  ok "aggregator does not invoke the retired coprocess-lifecycle eval"
fi

# 5. 0006 Status superseded by 0063 (already true on master)
st0006="$(sed -n 's/^Status:[[:space:]]*//p' \
  "$REPO/docs/tdd/0006-governance-overlay-and-delegation.md" | head -1)"
[ "$st0006" = "superseded by 0063" ] \
  && ok "0006 Status is superseded by 0063" \
  || bad "0006 Status is '$st0006' want 'superseded by 0063'"

# README: build-command table lists /build-tdds; ^/implement only historical
# or the bundled-name collision note; Superpowers/pr-review-toolkit optional.
if grep -qE '\|[[:space:]]*3\. Build[[:space:]]*\|[[:space:]]*`/build-tdds`' \
     "$REPO/README.md"; then
  ok "README command table lists /build-tdds"
else
  bad "README command table does not list /build-tdds as the build command"
fi
if grep -nEi 'superpowers|pr-review-toolkit' "$REPO/README.md" \
     | grep -qi 'optional'; then
  ok "README states Superpowers/pr-review-toolkit are optional"
else
  bad "README does not call Superpowers/pr-review-toolkit optional"
fi
impl_hits="$(grep -n '^/implement' "$REPO/README.md" || true)"
if [ -z "$impl_hits" ]; then
  ok "README has no start-of-line /implement"
else
  impl_bad=""
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qiE 'historical|bundled|collision|already own' \
      || impl_bad="${impl_bad}${line}"$'\n'
  done <<< "$impl_hits"
  if [ -z "$impl_bad" ]; then
    ok "README ^/implement lines are historical or collision notes"
  else
    bad "README ^/implement still names the build command:"$'\n'"$impl_bad"
  fi
fi

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== 0063 observations: $PASS passed, $FAIL failed ==="

# 0060–0062 evals (kept). Each file is invoked only when it exists.
EVAL_FAIL=0
for ev in plugin-root verdicts run-record build-tdds-skill; do
  f="$(dirname "$0")/${ev}.test.sh"
  if [ -f "$f" ]; then
    echo
    bash "$f" || EVAL_FAIL=1
  fi
done

[ "$FAIL" -eq 0 ] && [ "$EVAL_FAIL" -eq 0 ]

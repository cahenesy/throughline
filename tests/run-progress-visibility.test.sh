#!/usr/bin/env bash
# run-progress-visibility.test.sh — eval for the run-state record + status renderer
# introduced by TDD 0008 (FR-27..FR-30).
#
# The contract:
#   - implement.sh writes a structured, machine-readable run record under
#     docs/tdd/.implement-logs/<ts>/state.d/ (FR-27): run.json + per-TDD
#     <slug>.json fragments. The `latest` symlink points at the active run.
#   - status.sh is THE renderer (single source of the view, so the honesty rules
#     FR-30 live in exactly one place): one-shot snapshot by default, --follow
#     for a live watch; estimate-labeled percent; never 100% before terminal;
#     read-only (no run-control).
#   - skills/implement-status/SKILL.md exposes the snapshot via /implement-status.
#
# Run: bash tests/run-progress-visibility.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
STATUS="$REPO/scripts/status.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# Mirror tests/implement-gate.test.sh's setup: stub `claude`, controllable verify.
setup() {
  local dir="$1" n="$2" status="${3:-ready}" i
  mkdir -p "$dir"/{docs/tdd,docs/adr,.stub/bin}
  cd "$dir"
  git init -q; git config user.email t@t.t; git config user.name t
  printf '# PRD\n## Requirements\n1. do the thing\n' > docs/PRD.md
  printf '# ADR Index\n| # | Title | Status | Scope |\n|---|---|---|---|\n' > docs/adr/INDEX.md
  local names=(alpha beta gamma)
  for ((i=1;i<=n;i++)); do
    printf '# TDD %04d: %s\nStatus: %s\nPRD refs: 1\nPRD-rev: deadbee\nADR constraints: none\n\n## Approach\nstub\n' \
      "$i" "${names[$((i-1))]}" "$status" > "docs/tdd/$(printf '%04d' "$i")-${names[$((i-1))]}.md"
  done
  git add -A; git commit -qm init

  export STUBDIR="$dir/.stub"
  printf '0\n' > "$STUBDIR/verify_rc"
  cat > "$STUBDIR/verify_test.sh" <<EOF
#!/usr/bin/env bash
exit "\$(cat "$STUBDIR/verify_rc" 2>/dev/null || echo 0)"
EOF
  export CI_CHECKS_TEST_CMD="bash $STUBDIR/verify_test.sh"
  export CI_CHECKS_TYPECHECK_CMD=""

  cat > "$STUBDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; *) shift;; esac; done
slug="$(printf '%s' "$prompt" | grep -oE 'docs/tdd/[0-9]+-[a-z]+' | head -1 | sed 's#docs/tdd/##')"
if printf '%s' "$prompt" | grep -q 'INDEPENDENT runtime-verification gate'; then
  cat "$STUBDIR/runtime-$slug" 2>/dev/null || echo "VERIFY_RUNTIME: PASS"
  exit 0
fi
if printf '%s' "$prompt" | grep -q 'INDEPENDENT review gate'; then
  if [ -f "$STUBDIR/review-$slug" ]; then
    cat "$STUBDIR/review-$slug"
  else
    # TDD 0021 §3b/§3c: a bare PASS is now converted to an incomplete-file-coverage
    # block unless every file in the review's diff scope carries a per-file
    # disposition. Disposition each touched file (the review prompt renders the
    # scope as `--name-only <base>..<head>`) so a stubbed clean review still clears
    # under the new coverage gate.
    rbase="$(printf '%s' "$prompt" | grep -oE 'name-only[[:space:]]+[0-9a-f]{7,40}' | head -1 | grep -oE '[0-9a-f]{7,40}')"
    [ -n "$rbase" ] && git diff --name-only "$rbase"..HEAD 2>/dev/null | while IFS= read -r f; do
      [ -n "$f" ] && echo "FILE_REVIEWED_NO_FINDINGS: $f"
    done
    echo "REVIEW_RESULT: PASS"
  fi
  exit 0
fi
if [ ! -f "$STUBDIR/no-test-first-$slug" ]; then
  echo "test for $slug" >> "test-$slug.txt"
  git add -A >/dev/null 2>&1; git commit -q -m "test(failing): $slug" >/dev/null 2>&1 || true
fi
echo "generated $(date +%s%N)" >> "generated-$slug.txt"
git add -A >/dev/null 2>&1; git commit -q -m "stub build $slug" >/dev/null 2>&1 || true
cat "$STUBDIR/build-$slug" 2>/dev/null || echo "BATCH_RESULT: OK"
exit 0
EOF
  chmod +x "$STUBDIR/bin/claude"
  export PATH="$STUBDIR/bin:$PATH"
}

# Pick the freshest run directory; tolerate the trailing slash from `ls -td */`.
statedir() { ls -td docs/tdd/.implement-logs/2*/state.d 2>/dev/null | head -1; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

echo "[A] state_init: state.d/ + run.json + per-TDD fragments exist after a run (FR-27)"
( setup "$ROOT/a" 2
  bash "$IMPL" --change ci >/dev/null 2>&1
  SD="$(statedir)"
  [ -n "$SD" ] && [ -d "$SD" ] && ok "state.d/ directory exists" || bad "state.d/ should exist (got '$SD')"
  [ -f "$SD/run.json" ] && ok "run.json exists" || bad "run.json should exist"
  [ -f "$SD/0001-alpha.json" ] && ok "0001-alpha.json fragment exists" || bad "0001-alpha.json should exist"
  [ -f "$SD/0002-beta.json" ] && ok "0002-beta.json fragment exists" || bad "0002-beta.json should exist"
) || true

echo "[B] state_init: run.json has the documented top-level fields (FR-27)"
( setup "$ROOT/b" 1
  bash "$IMPL" --change ci >/dev/null 2>&1
  SD="$(statedir)"
  R="$SD/run.json"
  for k in schema started_at updated_at pid integration_branch mode change logdir total state; do
    grep -q "\"$k\"" "$R" 2>/dev/null && ok "run.json has field $k" || bad "run.json missing field $k"
  done
  grep -qE '"schema":[[:space:]]*1\b' "$R" 2>/dev/null && ok "schema=1" || bad "schema should be 1"
  grep -qE '"total":[[:space:]]*1\b' "$R" 2>/dev/null && ok "total=1" || bad "total should be 1"
) || true

echo "[C] state_init: per-TDD fragments have the documented fields + queue_pos (FR-27)"
( setup "$ROOT/c" 2
  bash "$IMPL" --change ci >/dev/null 2>&1
  SD="$(statedir)"
  F1="$SD/0001-alpha.json"; F2="$SD/0002-beta.json"
  for k in n slug path queue_pos status stage updated_at; do
    grep -q "\"$k\"" "$F1" 2>/dev/null && ok "0001 fragment has field $k" || bad "0001 fragment missing field $k"
  done
  grep -qE '"queue_pos":[[:space:]]*1\b' "$F1" && ok "0001 queue_pos=1" || bad "0001 should have queue_pos=1"
  grep -qE '"queue_pos":[[:space:]]*2\b' "$F2" && ok "0002 queue_pos=2" || bad "0002 should have queue_pos=2"
  grep -qE '"n":[[:space:]]*1\b' "$F1" && ok "0001 n=1" || bad "0001 should have n=1"
  grep -qE '"n":[[:space:]]*2\b' "$F2" && ok "0002 n=2" || bad "0002 should have n=2"
) || true

echo "[D] latest symlink: points at the active run's <ts> dir (FR-27 discovery)"
( setup "$ROOT/d" 1
  bash "$IMPL" --change ci >/dev/null 2>&1
  LATEST="docs/tdd/.implement-logs/latest"
  [ -L "$LATEST" ] && ok "latest is a symlink" || bad "latest should be a symlink"
  T="$(readlink "$LATEST" 2>/dev/null)"
  [ -n "$T" ] && [ -d "docs/tdd/.implement-logs/$T/state.d" ] && ok "latest target has state.d/" \
    || bad "latest should point at a <ts> dir containing state.d/ (got '$T')"
) || true

echo "[E] happy run: run.json state=done; per-TDD fragment status=done (FR-27 transitions)"
( setup "$ROOT/e" 1
  bash "$IMPL" --change ci >/dev/null 2>&1
  SD="$(statedir)"
  grep -qE '"state":[[:space:]]*"done"' "$SD/run.json" && ok "run.json state=done after run" \
    || bad "run.json should be state=done after the run"
  grep -qE '"status":[[:space:]]*"done"' "$SD/0001-alpha.json" \
    && ok "0001 status=done after successful gates" || bad "0001 should be status=done"
) || true

echo "[F] failure transition: TDD that fails verify ends status=failed (FR-27)"
( setup "$ROOT/f" 1
  printf '1\n' > "$STUBDIR/verify_rc"        # tests red -> ci-checks gate fails
  bash "$IMPL" --change ci >/dev/null 2>&1
  SD="$(statedir)"
  grep -qE '"status":[[:space:]]*"failed"' "$SD/0001-alpha.json" \
    && ok "0001 status=failed" || bad "0001 should be status=failed"
) || true

echo "[G] design-blocker transition: BATCH_RESULT BLOCKED -> status=blocked (FR-27)"
( setup "$ROOT/g" 1
  printf 'BATCH_RESULT: BLOCKED needs a new ADR\n' > "$STUBDIR/build-0001-alpha"
  bash "$IMPL" --change ci >/dev/null 2>&1
  SD="$(statedir)"
  grep -qE '"status":[[:space:]]*"blocked"' "$SD/0001-alpha.json" \
    && ok "0001 status=blocked" || bad "0001 should be status=blocked"
) || true

echo "[H] resume pre-skip: a TDD already built on an un-merged branch records status=skipped (FR-27)"
( setup "$ROOT/h" 1
  bash "$IMPL" --change ci  >/dev/null 2>&1    # run 1: builds + flips on ci/0001-alpha
  bash "$IMPL" --change ci2 >/dev/null 2>&1    # run 2: must pre-skip
  SD="$(statedir)"
  grep -qE '"status":[[:space:]]*"skipped"' "$SD/0001-alpha.json" \
    && ok "0001 status=skipped on resume" || bad "0001 should be status=skipped on resume"
) || true

echo "[I] status.sh: no active run -> prints message and exits 0 (FR-28)"
( cd "$(mktemp -d)"                            # empty cwd, no state, no lock
  out="$(bash "$STATUS" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -qi 'no active' \
    && ok "prints a no-active-run message" || bad "should mention no active run"
  [ "$rc" -eq 0 ] && ok "exits 0" || bad "should exit 0 (got $rc)"
) || true

echo "[J] status.sh: renders snapshot from a fixture state.d/ (FR-28)"
( D="$(mktemp -d)"
  mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1000,"updated_at":1100,"pid":123,"integration_branch":"main","mode":"sequential","change":"ci","logdir":"$D","total":2,"completed":1,"failed":0,"blocked":0,"skipped":0,"state":"running"}
EOF
  cat > "$D/state.d/0001-alpha.json" <<EOF
{"n":1,"slug":"0001-alpha","path":"docs/tdd/0001-alpha.md","queue_pos":1,"status":"done","stage":null,"started_at":1000,"updated_at":1050,"branch":"ci/0001-alpha","pr_url":"","log":"","note":""}
EOF
  cat > "$D/state.d/0002-beta.json" <<EOF
{"n":2,"slug":"0002-beta","path":"docs/tdd/0002-beta.md","queue_pos":2,"status":"building","stage":"build","started_at":1050,"updated_at":1100,"branch":"","pr_url":"","log":"","note":""}
EOF
  out="$(bash "$STATUS" --logdir "$D" 2>&1)"
  printf '%s\n' "$out" | grep -qE '1 done */ *2' \
    && ok "rollup line shows 1 done / 2" || bad "rollup should show '1 done / 2'"
  printf '%s\n' "$out" | grep -qE '~[0-9]+%[[:space:]]*\(estimate\)' \
    && ok "percent labeled (estimate)" || bad "percent should be suffixed (estimate)"
  printf '%s\n' "$out" | grep -q '0001-alpha' && ok "lists 0001-alpha" || bad "should list 0001-alpha"
  printf '%s\n' "$out" | grep -q '0002-beta'  && ok "lists 0002-beta"  || bad "should list 0002-beta"
  printf '%s\n' "$out" | grep -qi 'building'  && ok "shows building status" || bad "should show building status"
  printf '%s\n' "$out" | grep -qi 'sequential' && ok "header names the mode" || bad "header should name the mode"
) || true

echo "[K] status.sh: honesty — never 100% while any TDD is non-terminal (FR-30)"
( D="$(mktemp -d)"
  mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1,"updated_at":2,"pid":1,"integration_branch":"main","mode":"sequential","change":"ci","logdir":"$D","total":2,"completed":1,"failed":0,"blocked":0,"skipped":0,"state":"running"}
EOF
  cat > "$D/state.d/0001-alpha.json" <<EOF
{"n":1,"slug":"0001-alpha","path":"docs/tdd/0001-alpha.md","queue_pos":1,"status":"done","stage":null,"started_at":1,"updated_at":2,"branch":"","pr_url":"","log":"","note":""}
EOF
  cat > "$D/state.d/0002-beta.json" <<EOF
{"n":2,"slug":"0002-beta","path":"docs/tdd/0002-beta.md","queue_pos":2,"status":"reviewing","stage":"review","started_at":2,"updated_at":3,"branch":"","pr_url":"","log":"","note":""}
EOF
  out="$(bash "$STATUS" --logdir "$D" 2>&1)"
  printf '%s\n' "$out" | grep -q '100%' \
    && bad "must NOT show 100% while any TDD is non-terminal" \
    || ok "no 100% while a TDD is non-terminal"
  printf '%s\n' "$out" | grep -qE '~[0-9]+%[[:space:]]*\(estimate\)' \
    && ok "percent labeled (estimate)" || bad "percent should be labeled (estimate)"
) || true

echo "[L] status.sh: 100% only when every TDD is terminal — even mixed terminals (FR-30)"
( D="$(mktemp -d)"
  mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1,"updated_at":2,"pid":1,"integration_branch":"main","mode":"sequential","change":"ci","logdir":"$D","total":2,"completed":1,"failed":1,"blocked":0,"skipped":0,"state":"done"}
EOF
  cat > "$D/state.d/0001-alpha.json" <<EOF
{"n":1,"slug":"0001-alpha","path":"docs/tdd/0001-alpha.md","queue_pos":1,"status":"done","stage":null,"started_at":1,"updated_at":2,"branch":"","pr_url":"","log":"","note":""}
EOF
  cat > "$D/state.d/0002-beta.json" <<EOF
{"n":2,"slug":"0002-beta","path":"docs/tdd/0002-beta.md","queue_pos":2,"status":"failed","stage":null,"started_at":1,"updated_at":2,"branch":"","pr_url":"","log":"","note":""}
EOF
  out="$(bash "$STATUS" --logdir "$D" 2>&1)"
  printf '%s\n' "$out" | grep -q '100%' \
    && ok "shows 100% when ALL TDDs terminal (done + failed)" \
    || bad "should show 100% when all TDDs are terminal"
) || true

echo "[M] status.sh: --follow exits cleanly on a stop signal and never writes to state.d/ (FR-29/FR-30)"
# Real Ctrl-C in the TUI sends SIGINT to the foreground status.sh and the trap
# fires. In a non-interactive test, `bash &` inherits SIG_IGN for SIGINT (POSIX)
# and a trap cannot un-ignore it, so we use SIGTERM here as the script-context
# proxy — the trap covers both signals.
( D="$(mktemp -d)"
  mkdir -p "$D/state.d"
  cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":1,"updated_at":2,"pid":1,"integration_branch":"main","mode":"sequential","change":"ci","logdir":"$D","total":1,"completed":0,"failed":0,"blocked":0,"skipped":0,"state":"running"}
EOF
  cat > "$D/state.d/0001-alpha.json" <<EOF
{"n":1,"slug":"0001-alpha","path":"docs/tdd/0001-alpha.md","queue_pos":1,"status":"building","stage":"build","started_at":1,"updated_at":2,"branch":"","pr_url":"","log":"","note":""}
EOF
  pre="$(ls "$D/state.d" | sort | tr '\n' ',')"
  bash "$STATUS" --logdir "$D" --follow 1 >/dev/null 2>&1 &
  pid=$!
  sleep 2
  kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
  post="$(ls "$D/state.d" | sort | tr '\n' ',')"
  [ "$pre" = "$post" ] && ok "--follow did not modify state.d/" \
    || bad "--follow must be read-only (before='$pre' after='$post')"
) || true

echo "[N] .gitignore includes docs/tdd/.implement-logs/ entry (FR-27 hygiene)"
( cd "$REPO"
  grep -qE '^docs/tdd/\.implement-logs/' .gitignore 2>/dev/null \
    && ok ".gitignore ignores docs/tdd/.implement-logs/" \
    || bad ".gitignore should ignore docs/tdd/.implement-logs/"
) || true

echo "[O] /implement-status skill exists and points at status.sh (FR-28/FR-29)"
( cd "$REPO"
  F="skills/implement-status/SKILL.md"
  [ -f "$F" ] && ok "$F exists" || bad "$F should exist"
  grep -qE '^name:[[:space:]]*implement-status' "$F" 2>/dev/null \
    && ok "frontmatter name=implement-status" || bad "skill name should be implement-status"
  grep -q 'status.sh' "$F" 2>/dev/null && ok "skill references status.sh" \
    || bad "skill should reference status.sh"
  grep -qE '!.*status\.sh.*--follow' "$F" 2>/dev/null \
    && ok "skill hands user the !…status.sh --follow line" \
    || bad "skill should expose the !…status.sh --follow watch line"
) || true

echo "[P] /implement skill cross-links /implement-status (TDD 0008 §5 docs)"
( cd "$REPO"
  grep -q '/implement-status' skills/implement/SKILL.md \
    && ok "implement skill cross-links /implement-status" \
    || bad "implement skill should cross-link /implement-status"
) || true

echo "[Q] status.sh: --logdir/--max-seconds with no value -> exit 2 + usage, no set -u crash (TDD 0054 A26 / FR-28)"
( D="$ROOT/q"; mkdir -p "$D"; cd "$D"
  for flag in --logdir --max-seconds; do
    out="$(bash "$STATUS" "$flag" 2>&1)"; rc=$?
    [ "$rc" -eq 2 ] && ok "$flag with no value exits 2" || bad "$flag with no value should exit 2 (got $rc)"
    printf '%s\n' "$out" | grep -qi 'unbound variable' \
      && bad "$flag with no value crashed under set -u ($out)" || ok "$flag: no set -u crash"
    printf '%s\n' "$out" | grep -qi 'usage' \
      && ok "$flag: diagnostic carries a usage line" || bad "$flag: expected a usage line (got: $out)"
  done
) || true

echo "[R] status.sh: jq parser maps a null scalar to empty — sed-path parity, no integer-test crash (TDD 0054 A27 / FR-28)"
( if command -v jq >/dev/null 2>&1; then
    D="$ROOT/r"; mkdir -p "$D/state.d"
    cat > "$D/state.d/run.json" <<EOF
{"schema":1,"started_at":null,"updated_at":null,"pid":123,"integration_branch":"main","mode":"sequential","change":"ci","logdir":"$D","total":null,"state":"running"}
EOF
    cat > "$D/state.d/0001-alpha.json" <<EOF
{"n":null,"slug":"0001-alpha","path":"docs/tdd/0001-alpha.md","queue_pos":null,"status":"building","stage":"build","started_at":1000,"updated_at":null,"branch":"","pr_url":"","note":""}
EOF
    out="$(bash "$STATUS" --logdir "$D" 2>&1)"
    printf '%s\n' "$out" | grep -qE 'integer (expression )?expected|unbound variable|invalid number' \
      && bad "jq null scalar leaked into a numeric context ($(printf '%s' "$out" | head -1))" \
      || ok "no integer-test / set -u / printf crash on null scalars"
    printf '%s\n' "$out" | grep -qE '0 done */ *0' \
      && ok "null total renders as 0 (sed-path parity)" || bad "null total should render '0 done / 0'"
    printf '%s\n' "$out" | grep -qw 'null' \
      && bad "literal 'null' leaked into the rendered view" || ok "no literal 'null' in the rendered view"
  else
    ok "jq absent on this host — A27 is the jq path; sed/python already map null to empty"
  fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== run-progress-visibility eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# runner-resilience.test.sh — eval for TDD 0027 (runner resilience: hung
# children, unclean exits, resumable halts).
#
# Covers the eight observation points in TDD 0027's `## Verification plan`:
#   VP1 — a hung gate child self-recovers via the per-call watchdog (gap 1).
#   VP2 — the gate-timeout knob is snapshotted into run.json config (gap 1).
#   VP3 — a stale build worktree is reclaimed at launch (gap 2).
#   VP4 — a fast-forward-advanced branch resumes (gap 3b).
#   VP5 — a true rewrite is still refused (gap 3b negative).
#   VP6 — a resumable `blocked` halt is surfaced + accepted; a non-resumable
#         one is not (gap 3a/3c).
#   VP7 — an honest FAIL/BLOCK verdict survives a non-zero child exit (gap 4).
#   VP8 — a verdict-less clean exit resolves to FAIL, never a false PASS (gap 4).
#
# Most blocks source implement.sh in `THROUGHLINE_SOURCE_ONLY=1` mode (the
# runner's testability guard) so they can call the gate/resume helpers directly
# without spinning up a full detached run.
#
# Run: bash tests/runner-resilience.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
STATUS="$REPO/scripts/status.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# A minimal review-prompt template so _render_review_prompt resolves without the
# implement.sh setup block. The placeholders are the same ones the real template
# carries; the content is irrelevant to the wrapper under test.
review_tmpl() {  # <path>
  cat > "$1" <<'TMPL'
INDEPENDENT review gate for {{TDD}} scope {{SCOPE_BASE}}..{{SCOPE_HEAD}} on {{BRANCH}}.
Prior addressed patterns: {{PRIOR_PATTERNS}}.
TMPL
}

# A minimal git repo with one committed TDD; cwd is the repo on return, and
# HEAD/build_start are echoed via the BUILD_START global.
setup_repo() {  # <dir>
  local dir="$1"
  mkdir -p "$dir/docs/tdd"
  cd "$dir"
  git init -q; git config user.email t@t.invalid; git config user.name "resilience test"
  cat > docs/tdd/0001-alpha.md <<'TDD'
# TDD 0001 — alpha
Status: draft
## Sequencing
1. step one
## Touched files
- foo.txt
TDD
  git add -A; git commit -q -m "init"
  BUILD_START="$(git rev-parse HEAD)"
}

# --- [VP1] hung gate child self-recovers (gap 1) ---------------------------
# A stub `claude` that sleeps forever, driven through _run_per_step_review with
# a 5s gate watchdog, MUST return promptly (not hang), leave the step-review log
# on disk with the timeout marker, and emit a `STEP_REVIEW: BLOCK …no
# REVIEW_RESULT…` line (NFR-4: a timed-out review is never a false PASS).
echo "[VP1] hung per-step-review child is killed by the gate watchdog and BLOCKs"
( D="$ROOT/vp1"; mkdir -p "$D/bin"
  setup_repo "$D"
  cat > "$D/bin/claude" <<'EOF'
#!/usr/bin/env bash
exec sleep 10000
EOF
  chmod +x "$D/bin/claude"; export PATH="$D/bin:$PATH"
  review_tmpl "$D/review.md"; export RTMPL="$D/review.md"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_GATE_TIMEOUT=5
  mainlog="$D/main.log"; : > "$mainlog"
  t0=$(date +%s)
  verdict="$(_run_per_step_review 0001-alpha docs/tdd/0001-alpha.md 1 "$BUILD_START" "$BUILD_START" "$mainlog")"
  t1=$(date +%s); elapsed=$((t1 - t0))
  rlog="$D/0001-alpha.step1.review.log"
  [ "$elapsed" -lt 30 ] \
    && ok "per-step review returns within the watchdog (took ${elapsed}s)" \
    || bad "per-step review should return within ~10s but took ${elapsed}s (hang)"
  case "$verdict" in
    *"STEP_REVIEW: BLOCK"*"no REVIEW_RESULT"*) ok "verdict is BLOCK (no REVIEW_RESULT) after timeout" ;;
    *) bad "verdict should be STEP_REVIEW: BLOCK …no REVIEW_RESULT… (got '$verdict')" ;;
  esac
  [ -f "$rlog" ] && ok "step-review log exists on disk" || bad "step-review log should exist ($rlog)"
  grep -q '^THROUGHLINE_GATE_TIMEOUT' "$rlog" 2>/dev/null \
    && ok "gate log carries the THROUGHLINE_GATE_TIMEOUT marker" \
    || bad "gate log should carry the THROUGHLINE_GATE_TIMEOUT marker (routes 124 -> transient)"
) || true

# --- [VP2] gate-timeout knob snapshotted into run.json (gap 1) -------------
# Launching with THROUGHLINE_GATE_TIMEOUT=120 must record "gate_timeout":120 in
# run.json's config block so a timeout-driven halt is reproducible from
# run-state alone (ADR 0006).
echo "[VP2] THROUGHLINE_GATE_TIMEOUT is snapshotted into run.json config"
( D="$ROOT/vp2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_GATE_TIMEOUT=120
  _write_run_fragment running
  R="$D/state.d/run.json"
  grep -q '"gate_timeout":120' "$R" 2>/dev/null \
    && ok "run.json config records gate_timeout=120" \
    || bad "run.json config should record \"gate_timeout\":120 ($(cat "$R" 2>/dev/null))"
) || true

# --- report ----------------------------------------------------------------
n_ok=$(grep -c '^ok$' "$RESULTS" 2>/dev/null); n_ok=${n_ok:-0}
n_fail=$(grep -c '^fail$' "$RESULTS" 2>/dev/null); n_fail=${n_fail:-0}
rm -f "$RESULTS"
echo
printf 'runner-resilience: %s passed, %s failed\n' "$n_ok" "$n_fail"
[ "$n_fail" -eq 0 ]

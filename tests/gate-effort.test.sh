#!/usr/bin/env bash
# gate-effort.test.sh — eval for the hardcoded per-gate effort levels.
#
# Every gate subprocess (`claude -p …`) carries an explicit `--effort` flag so
# gate depth is part of the runner's contract (pinned by plugin version), not
# inherited invisibly from the operator's local effortLevel setting. The
# mapping is HARDCODED in gates.sh `_gate_effort` (deliberately not
# configurable): build/rework/review on the frontier tiers (fable/opus) run
# `xhigh`; runtime-verify runs `high` (observation, not construction); sonnet
# caps at `high` everywhere (it has no xhigh tier); an empty/unknown model
# emits NO flag (the spawn must never fail on a guessed tier — NFR-4).
#
#   §1 _gate_effort unit table (gate × model → level)
#   §2 structural: all six spawn sites in gates.sh append the flag
#   §3 behavioral: a stubbed `claude` records argv — runtime-verify on a
#      mechanical plan (model sonnet) receives `--effort high`
#   §D default-model resolution (TDD 0057): resolve_models pairing,
#      rollback arm, overrides
#   §W dogfood: the eval is wired into the aggregator and propagates failure
#
# Run: bash tests/gate-effort.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"; rm -f "$RESULTS"' EXIT

# ===========================================================================
echo "[§1] _gate_effort: hardcoded gate × model mapping"
( D="$ROOT/s1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §1 — source guard missing"; exit 0; }
  command -v _gate_effort >/dev/null 2>&1 || { bad "_gate_effort is not defined after sourcing"; exit 0; }

  check() { # <gate> <model> <expected> <label>
    local got; got="$(_gate_effort "$1" "$2")"
    [ "$got" = "$3" ] && ok "$4" || bad "$4 (expected '$3', got '$got')"
  }
  check build  fable           xhigh "build/fable → xhigh"
  check build  opus            xhigh "build/opus → xhigh"
  check build  claude-opus-4-8 xhigh "build/claude-opus-4-8 (full id) → xhigh"
  check build  claude-fable-5  xhigh "build/claude-fable-5 (full id) → xhigh"
  check rework opus            xhigh "rework/opus → xhigh"
  check review fable           xhigh "review/fable → xhigh"
  check review opus            xhigh "review/opus → xhigh"
  check review sonnet          high  "review/sonnet → high (sonnet has no xhigh tier)"
  check verify opus            high  "verify/opus → high (observation, not construction)"
  check verify fable           high  "verify/fable → high"
  check verify sonnet          high  "verify/sonnet → high"
  check build  sonnet          high  "build/sonnet → high (cap)"
  check build  ""              ""    "build/<empty> → no flag (host default)"
  check build  haiku           ""    "build/haiku → no flag (never guess a tier)"
) || true

# ===========================================================================
# §2: every spawn site appends the flag. Six call sites: single-shot build,
# consolidated review, runtime-verify, per-step review, the build COPROC, and
# rework. The count is exact so a regressing edit (dropping a site, or adding a
# seventh spawn without effort) turns this red.
echo "[§2] gates.sh: all six claude spawn sites carry _gate_effort"
( G="$REPO/scripts/lib/gates.sh"
  n="$(grep -c '_eff="\$(_gate_effort ' "$G")"
  [ "$n" = "6" ] && ok "exactly 6 _gate_effort call sites (got $n)" \
    || bad "expected exactly 6 _gate_effort call sites in gates.sh (got $n)"
  for pair in "build:2" "review:2" "verify:1" "rework:1"; do
    g="${pair%%:*}"; want="${pair##*:}"
    c="$(grep -c "_gate_effort $g " "$G")"
    [ "$c" = "$want" ] && ok "gate class '$g' wired at $want site(s)" \
      || bad "gate class '$g': expected $want site(s), got $c"
  done
  # The coproc build (the main build path) specifically must carry it.
  grep -A2 'coproc BUILD' "$G" >/dev/null 2>&1 || { bad "INFRA: coproc BUILD not found"; exit 0; }
  grep -B3 'coproc BUILD' "$G" | grep -q '_gate_effort build' \
    && ok "the build COPROC argv includes the effort flag" \
    || bad "the build COPROC argv is missing _gate_effort (main build path unpinned)"
) || true

# ===========================================================================
# §3: behavioral — the flag reaches the actual claude invocation. Mirrors the
# token-spend-reduction runtime-verify harness: stub claude records its full
# argv; a mechanical-plan TDD routes to sonnet, so the spawn must carry
# `--effort high`.
echo "[§3] runtime-verify spawn carries --effort high (sonnet, mechanical plan)"
( D="$ROOT/s3"; mkdir -p "$D/state.d" "$D/stub/bin" "$D/repo/docs/tdd"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  export STUB_LOG="$D/stub.log"; : > "$STUB_LOG"
  # Record FLAGS only — the -p prompt is multi-line and would split the argv
  # record across lines, defeating the line-based greps below.
  cat > "$D/stub/bin/claude" <<'EOF'
#!/usr/bin/env bash
flags=""
while [ $# -gt 0 ]; do case "$1" in -p) shift 2 ;; *) flags="$flags $1"; shift ;; esac; done
echo "claude-flags:$flags" >> "$STUB_LOG"
echo "VERIFY_RUNTIME: SKIP stub"
exit 0
EOF
  chmod +x "$D/stub/bin/claude"
  export PATH="$D/stub/bin:$PATH"
  cd "$D/repo" || { bad "cd failed"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  cat > docs/tdd/0001-mechanical.md <<'EOF'
# TDD 0001: mechanical fixture
Status: draft

## Verification plan
Run the script, observe exit code 0 and the expected line on stdout.
EOF
  git add -A; git commit -qm init >/dev/null 2>&1
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §3 — source guard missing"; exit 0; }
  MODEL=opus
  RVMTPL="$REPO/scripts/verify-runtime-prompt.md"
  LOGF="$D/0001.log"; : > "$LOGF"
  verify_runtime_one docs/tdd/0001-mechanical.md HEAD "$LOGF" >/dev/null 2>&1
  grep -q 'claude-flags:.*--model sonnet' "$STUB_LOG" \
    && ok "mechanical plan routed to sonnet (control)" \
    || bad "expected --model sonnet in stub argv (got: $(cat "$STUB_LOG"))"
  grep -q 'claude-flags:.*--effort high' "$STUB_LOG" \
    && ok "runtime-verify spawn carries --effort high" \
    || bad "expected --effort high in stub argv (got: $(cat "$STUB_LOG"))"
  grep -q 'claude-flags:.*--effort xhigh' "$STUB_LOG" \
    && bad "verify must NOT run xhigh (observation gate)" \
    || ok "no xhigh on the verify gate"
) || true

# ===========================================================================
# §D: default model resolution (TDD 0057 / NFR-3, ADR 0009). resolve_models()
# in implement.sh is the binding-of-record for the default build/review model
# pairing; these cases pin the pairing, the rollback arm (an explicit opus
# build derives a sonnet review), and the override precedence (flag > env >
# default). Each check runs in its own subshell so env never leaks between
# cases.
echo "[§D] resolve_models: default build/review model resolution"
( D="$ROOT/sD"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §D — source guard missing"; exit 0; }
  command -v resolve_models >/dev/null 2>&1 \
    || { bad "resolve_models is not defined after sourcing (binding-of-record missing)"; exit 0; }

  # check_resolve <MODEL-in> <BUILD-env|-> <REVIEW-env|-> <want-MODEL> <want-REVIEW> <label>
  # "-" = unset env knob. MODEL/REVIEW_MODEL enter as the runner's arg-parse
  # state ("" when the flag was not passed).
  check_resolve() {
    ( MODEL="$1"; REVIEW_MODEL=""
      if [ "$2" != "-" ]; then export THROUGHLINE_BUILD_MODEL="$2"; else unset THROUGHLINE_BUILD_MODEL; fi
      if [ "$3" != "-" ]; then export THROUGHLINE_REVIEW_MODEL="$3"; else unset THROUGHLINE_REVIEW_MODEL; fi
      resolve_models
      [ "$MODEL" = "$4" ] && [ "$REVIEW_MODEL" = "$5" ] \
        && ok "$6" \
        || bad "$6 (expected MODEL=$4 REVIEW_MODEL=$5; got MODEL=$MODEL REVIEW_MODEL=$REVIEW_MODEL)"
    )
  }
  check_resolve ""     - - fable opus "unset everything → build fable (latest top tier), review opus (prior-gen top tier)"
  check_resolve opus   - - opus sonnet "MODEL=opus → review sonnet (rollback pairing)"
  check_resolve sonnet - - sonnet opus "MODEL=sonnet → review opus (diversity for any non-opus build)"
  check_resolve ""     opus - opus sonnet "THROUGHLINE_BUILD_MODEL=opus + no flag → opus/sonnet (env binding wins over default)"
  check_resolve sonnet - haiku sonnet haiku "THROUGHLINE_REVIEW_MODEL=haiku → review haiku (explicit override wins over derivation)"
) || true

# ===========================================================================
echo "[§W] dogfood: wiring this eval into the aggregator makes its exit go non-zero when the eval fails"
( AGG="$REPO/tests/implement-gate.test.sh"
  grep -q 'gate-effort.test.sh' "$AGG" \
    && ok "the new eval is wired into the aggregator (registration present)" \
    || bad "gate-effort.test.sh is not registered in implement-gate.test.sh"
  grep -q 'GEF_FAIL' "$AGG" && grep -q '\[ "\$GEF_FAIL" -eq 0 \]' "$AGG" \
    && ok "aggregator final AND-chain goes non-zero when this eval fails (wire-in propagates)" \
    || bad "GEF_FAIL term missing from the aggregator AND-chain"
) || true

# ===========================================================================
total=$(grep -c . "$RESULTS"); fails=$(grep -c fail "$RESULTS" || true)
echo
echo "=== gate-effort eval: $((total - fails)) passed, $fails failed ==="
[ "$fails" -eq 0 ]

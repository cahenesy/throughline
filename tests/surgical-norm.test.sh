#!/usr/bin/env bash
# surgical-norm.test.sh — eval for TDD 0046 (surgical-changes build norm;
# FR-66, FR-74; ADR 0005, 0007, 0008).
#
# The norm is prompt guidance only (ADR 0005: enforcement stays the FR-66
# mechanical cap + the review gate — no new gate). Observation point per the
# TDD's verification plan: the text each `claude -p` actually receives —
# render build-prompt.md via _render_build_prompt (the runner's render path)
# and rework-prompt.md via _rework_one's template load — then grep the
# RENDERED output, not the raw template.
#   §1 build prompt: the surgical-changes norm AND its carve-out (the three
#      required-change classes named, so a future edit cannot drop the
#      carve-out and reintroduce the doc-update contradiction); control: the
#      mandated "Keep docs in sync IN THIS COMMIT" duty is still present.
#   §2 rework prompt: the single-finding-scope echo (fix ONLY the cited
#      finding; nothing outside the finding region except where mechanically
#      required; no adjacent improvement) reaches the prompt _rework_one
#      assembles; the shared "Surgical changes" token appears in BOTH prompts
#      (drift guard); control: the "Fix only the cited finding" hard bound is
#      still present.
#   §W dogfood: the aggregator's final AND-chain goes non-zero when this eval
#      fails (TDD 0038 §3 wire-in rule).
#
# Run: bash tests/surgical-norm.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS=""; ROOT=""
trap 'rm -rf "$ROOT"; rm -f "$RESULTS"' EXIT
RESULTS="$(mktemp)"; ROOT="$(mktemp -d)"
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# ===========================================================================
# §1: the rendered build prompt carries the surgical-changes norm with its
# carve-out, and the norm did not displace the mandated doc-sync duty.
echo "[§1] rendered build prompt: surgical-changes norm + carve-out; doc-sync duty intact"
( TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §1 — source guard missing"; exit 0; }
  export TMPL="$REPO/scripts/build-prompt.md"; unset STATE_DIR
  prompt="$(_render_build_prompt 0046-x docs/tdd/0046-x.md)"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$prompt" ]; then
    bad "INFRA: §1 — could not render the build prompt (rc=$rc)"; exit 0
  fi
  has() { printf '%s' "$prompt" | grep -qF "$1" && ok "$2" || bad "$2 (expected '$1' in rendered prompt)"; }
  has '**Surgical changes.**'           "the surgical-changes norm bullet is present"
  has 'must trace to the requirement'   "norm: every changed line traces to the requirement being built"
  has 'refactor adjacent code'          "norm: no improving/refactoring adjacent code that was only read"
  has 'match the existing style'        "norm: match the existing style, not impose one"
  has 'nothing speculative'             "norm: no speculative additions"
  has 'CARVE-OUT'                       "the required-changes carve-out clause is present"
  has 'failing-test-first commit'       "carve-out names the failing-test-first commit"
  has 'stale-doc updates'               "carve-out names same-commit stale-doc updates"
  has 'superseding an accepted ADR'     "carve-out names accepted-ADR/design-doc supersession"
  has 'not when it is zero'             "carve-out: a required change's minimum is not zero"
  has 'Keep docs in sync IN THIS COMMIT' "control: the mandated doc-sync duty is still present"
) || true

# ===========================================================================
# §2: the rendered rework prompt carries the single-finding-scope echo of the
# norm. Observation point: the prompt the rework `claude -p` actually receives
# — a stub claude captures it from _rework_one's real template load + render.
echo "[§2] rendered rework prompt: single-finding-scope echo; hard bounds intact"
( D="$ROOT/s2"; mkdir -p "$D/state.d" "$D/bin"; cd "$D" || { bad "INFRA: §2 — cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §2 — source guard missing"; exit 0; }
  export RWTMPL="$REPO/scripts/rework-prompt.md"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
  printf 'bug\n' > src/a.txt
  cat > docs/tdd/0046-fix.md <<'EOF'
# TDD 0046: fixture
Status: draft

## Touched files
- `src/a.txt` — file
EOF
  git add -A; git commit -qm "build start" >/dev/null
  # stub claude: capture the assembled prompt, then act as the rework model.
  cat > "$D/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
printf '%s' "\$prompt" > "$D/captured-prompt"
printf 'fixed\n' > src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "rework: fix the cited finding" >/dev/null 2>&1
echo done
EOF
  chmod +x "$D/bin/claude"
  export PATH="$D/bin:$PATH"
  _rework_one docs/tdd/0046-fix.md "$D/rw.log" "review-1:1" "src/a.txt:1 has a bug" 60 >/dev/null
  if [ ! -s "$D/captured-prompt" ]; then bad "INFRA: §2 — stub claude captured no prompt"; exit 0; fi
  rhas() { grep -qF "$1" "$D/captured-prompt" && ok "$2" || bad "$2 (expected '$1' in rendered rework prompt)"; }
  rhas 'Surgical changes'          "the shared norm token reaches the rework prompt (drift guard with §1)"
  rhas 'ONLY the cited'            "echo: a rework fixes ONLY the cited finding"
  rhas 'outside the finding'       "echo: nothing outside the finding region"
  rhas 'mechanically requires'     "echo: except where the fix mechanically requires it"
  rhas 'no adjacent improvement'   "echo: no adjacent improvement"
  rhas 'Fix only the cited finding.' "control: the existing hard-bound bullet is still present"
) || true

# ===========================================================================
# §W: dogfood (TDD 0038 §3) — drive the aggregator's REAL extracted final
# AND-chain with this eval's accumulator forced to 1; the chain must go
# non-zero, proving the wire-in propagates a failure of this eval.
echo "[§W] dogfood: wiring this eval into the aggregator makes its exit go non-zero when the eval fails"
( AGG="$REPO/tests/implement-gate.test.sh"
  if [ ! -r "$AGG" ]; then bad "INFRA: §W — aggregator unreadable: $AGG"; exit 0; fi
  grep -qE 'surgical-norm\.test\.sh' "$AGG" \
    && ok "the new eval is wired into the aggregator (registration present)" \
    || bad "the new eval is wired into the aggregator (expected /surgical-norm\\.test\\.sh/ in $AGG)"
  chain="$(grep -aE '^\[ "\$FAIL" -eq 0 \] &&' "$AGG" | tail -1)"
  if [ -z "$chain" ]; then bad "INFRA: §W — could not locate the aggregator final AND-chain"; exit 0; fi
  drive_rc="$(
    set +u
    for v in $(printf '%s' "$chain" | grep -aoE '\$[A-Za-z_][A-Za-z0-9_]*' | tr -d '$' | sort -u); do
      eval "$v=0"
    done
    SRG_FAIL=1
    eval "$chain"; echo $?
  )"
  [ "$drive_rc" != "0" ] \
    && ok "aggregator final AND-chain goes non-zero when the new eval fails (wire-in propagates)" \
    || bad "aggregator AND-chain must be non-zero with SRG_FAIL=1 (got rc=$drive_rc)"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== surgical-norm eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

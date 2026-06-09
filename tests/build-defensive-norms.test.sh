#!/usr/bin/env bash
# build-defensive-norms.test.sh — eval for TDD 0026 (build-phase defensive-coding
# norms / FR-74). Covers the verification plan's observation points:
#   §0 build-norms.md structural contract (anchor unique + 7 numbered norms) —
#      the extraction contract §2/§3 depend on.
#   §1 norms reach the initial build prompt (_render_build_prompt substitutes
#      {{BUILD_NORMS}}; anchor + 7 lead-ins present; no literal placeholder left).
#   §2 a missing norms file is FATAL at render (non-zero + stderr diagnostic; no
#      partial prompt).
#   §3 substitution is bash PE, not sed (sed-breaking chars survive verbatim; a
#      {{TDD}}-like token inside the norms is NOT re-substituted).
#   §4 a BLOCK reply carries the norms reminder (finding + headlines); a PASS
#      reply carries neither.
#   §5 the reminder degrades gracefully when the norms file is gone (generic
#      one-liner, no fatal).
#
# Function-level eval (the runtime-verify gate re-drives the observable surface
# against a real /implement build). Uses a stub `claude`/coprocess so no model or
# tokens are needed.
#
# Run: bash tests/build-defensive-norms.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
NORMS="$REPO/scripts/build-norms.md"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# This fixture exercises coproc/handshake/review mechanics, not test-first
# ordering; disable the orthogonal default-on per-step pre-check (TDD 0038 §1) so
# its `step(N): work` impl-only commits do not hit the deterministic BLOCK before
# reaching the path under test. The dedicated eval (tests/test-first-per-step.test.sh)
# covers the gate ON.
export THROUGHLINE_REQUIRE_TEST_FIRST=0

# ===========================================================================
# §0: the norms file's structural contract. The H2 anchor must be present and
# UNIQUE (the §3 reminder extracts the numbered list under it), and there must be
# exactly the seven enumerated norms (one `N. ` line each). A drift here silently
# breaks both the render substitution and the reminder extraction.
echo "[§0] build-norms.md structural contract: unique H2 anchor + seven numbered norms"
( if [ ! -f "$NORMS" ]; then bad "scripts/build-norms.md should exist"; exit 0; fi
  anchors="$(grep -c '^## Defensive-coding norms (FR-74)$' "$NORMS" 2>/dev/null || echo 0)"
  [ "$anchors" = "1" ] && ok "the '## Defensive-coding norms (FR-74)' anchor appears exactly once" \
    || bad "anchor must appear exactly once (got $anchors)"
  norms="$(grep -cE '^[0-9]+\. ' "$NORMS" 2>/dev/null || echo 0)"
  [ "$norms" = "7" ] && ok "exactly seven numbered norm lead-ins are present" \
    || bad "expected 7 numbered norms (got $norms)"
  # The seven recurring finding classes FR-74 enumerates must each be named.
  for kw in "Fail loud" "Temp files" "Safe escaping" "Sourced-library hygiene" \
            "Path / trust boundary" "Read once" "No hardcoding"; do
    grep -qF "$kw" "$NORMS" 2>/dev/null && ok "norm class present: $kw" \
      || bad "norm class missing: $kw"
  done
) || true

# mk_prompt_dir <dir> — a build-prompt.md fixture carrying the three render
# placeholders ({{TDD}}, {{CLEARED_STEPS}}, {{BUILD_NORMS}}). The norms file is
# created separately by each case (present / absent / sed-breaking) beside it, so
# the dirname-of-$TMPL resolution picks it up.
mk_prompt_dir() {  # <dir>
  local d="$1"; mkdir -p "$d"
  cat > "$d/build-prompt.md" <<'EOF'
Implement {{TDD}} as a single unattended build.

Build discipline:
- RESUME SIGNAL. Cleared steps: {{CLEARED_STEPS}}

Defensive-coding norms (FR-74). The following norms are non-negotiable:

{{BUILD_NORMS}}

Close:
- done
EOF
}

# setup_step_repo <dir> — a git repo + scope-declaring TDD + a stub `claude` that
# acts as BOTH the multi-turn build coprocess (runs ctl/build_plan, which emits
# STEP_COMMIT and reads the STEP_REVIEW reply) and the per-step review (echoes
# ctl/review.out, default PASS). Leaves PWD in the repo. Mirrors the
# coproc-verdict-resilience eval's harness so the §4/§5 cases can drive the real
# _per_step_review_loop with no model. The caller may override TMPL afterwards.
setup_step_repo() {  # <dir>
  local d="$1"; mkdir -p "$d/ctl" "$d/bin"
  cd "$d" || return 1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
  printf 'ctl/\nbin/\n' > .gitignore
  printf 'orig\n' > src/a.txt
  cat > docs/tdd/0026-fix.md <<'EOF'
# TDD 0026: fixture
Status: draft
PRD refs: 1

## Touched files
- `src/a.txt` — the in-scope file
EOF
  git add -A; git commit -qm "build start" >/dev/null
  cat > "$d/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
if printf '%s' "\$prompt" | grep -q 'INDEPENDENT review gate'; then
  cat "$d/ctl/review.out" 2>/dev/null || echo "REVIEW_RESULT: PASS"
  exit 0
fi
bash "$d/ctl/build_plan"
EOF
  chmod +x "$d/bin/claude"
  export PATH="$d/bin:$PATH"
  export TMPL="$REPO/scripts/build-prompt.md" RTMPL="$REPO/scripts/review-prompt.md"
  export MODEL="" REVIEW_MODEL="" MAINREPO="$d"
  printf 'REVIEW_RESULT: PASS\n' > "$d/ctl/review.out"
}

# ===========================================================================
# §1: the norms reach the initial build prompt. _render_build_prompt must
# substitute {{BUILD_NORMS}} with the full norms file content — the anchor and
# all seven lead-ins present, no literal placeholder left, return code 0.
echo "[§1] _render_build_prompt substitutes {{BUILD_NORMS}}: anchor + 7 norms present, no placeholder left"
( D="$ROOT/r1"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_prompt_dir "$D"
  cp "$NORMS" "$D/build-norms.md"
  export TMPL="$D/build-prompt.md"; unset STATE_DIR
  prompt="$(_render_build_prompt 0026-x docs/tdd/0026-x.md)"; rc=$?
  [ "$rc" -eq 0 ] && ok "render returns 0 with a norms file present" || bad "render should return 0 (got $rc)"
  printf '%s' "$prompt" | grep -qF '## Defensive-coding norms (FR-74)' \
    && ok "rendered prompt carries the norms H2 anchor" || bad "rendered prompt should carry the anchor"
  miss=0
  for kw in "Fail loud" "Temp files" "Safe escaping" "Sourced-library hygiene" \
            "Path / trust boundary" "Read once" "No hardcoding"; do
    printf '%s' "$prompt" | grep -qF "$kw" || { miss=1; bad "rendered prompt missing norm lead-in: $kw"; }
  done
  [ "$miss" -eq 0 ] && ok "all seven norm lead-ins reached the prompt"
  printf '%s' "$prompt" | grep -qF '{{BUILD_NORMS}}' \
    && bad "literal {{BUILD_NORMS}} placeholder must NOT remain" || ok "no literal {{BUILD_NORMS}} placeholder remains"
) || true

# ===========================================================================
# §2: a missing/unreadable norms file is FATAL at render — _render_build_prompt
# returns non-zero with a stderr diagnostic naming the file, and emits NO partial
# prompt. A build prompt that silently drops its norms is the exact failure mode
# FR-74 prevents (norm #1, fail loud).
echo "[§2] a missing norms file is FATAL at render (non-zero + stderr diagnostic; no partial prompt)"
( D="$ROOT/r2"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_prompt_dir "$D"            # build-prompt.md but NO build-norms.md beside it
  export TMPL="$D/build-prompt.md"; unset STATE_DIR
  err="$ROOT/r2.err"
  prompt="$(_render_build_prompt 0026-x docs/tdd/0026-x.md 2>"$err")"; rc=$?
  [ "$rc" -ne 0 ] && ok "render returns non-zero when the norms file is absent" \
    || bad "render must fail when the norms file is missing (got rc=$rc)"
  grep -qF 'build-norms.md' "$err" 2>/dev/null \
    && ok "stderr diagnostic names the missing norms file" || bad "stderr should name build-norms.md (got: $(cat "$err" 2>/dev/null))"
  printf '%s' "$prompt" | grep -qF 'Implement docs/tdd/0026-x.md' \
    && bad "no partial prompt should be emitted on the fatal path" || ok "no partial prompt emitted on the fatal path"
) || true

# ===========================================================================
# §2b: an EMPTY (or otherwise unreadable-at-read-time) norms file is ALSO FATAL —
# the "NOT a silent empty substitution" contract (§2) must hold even when the file
# exists and passes the [ -r ] pre-flight but yields no content. A norms-less build
# prompt is the failure mode FR-74 prevents; the cat must be guarded (norm #1).
echo "[§2b] an empty norms file is FATAL at render (no silent empty-norms substitution)"
( D="$ROOT/r2b"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_prompt_dir "$D"
  : > "$D/build-norms.md"        # present + readable, but EMPTY
  export TMPL="$D/build-prompt.md"; unset STATE_DIR
  err="$ROOT/r2b.err"
  prompt="$(_render_build_prompt 0026-x docs/tdd/0026-x.md 2>"$err")"; rc=$?
  [ "$rc" -ne 0 ] && ok "render returns non-zero when the norms file is empty" \
    || bad "render must fail on an empty norms file, not substitute empty norms (got rc=$rc)"
  grep -qF 'build-norms.md' "$err" 2>/dev/null \
    && ok "stderr diagnostic names the norms file on the empty path" || bad "stderr should name build-norms.md (got: $(cat "$err" 2>/dev/null))"
  printf '%s' "$prompt" | grep -qF 'Implement docs/tdd/0026-x.md' \
    && bad "no partial prompt should be emitted on the empty-norms fatal path" || ok "no partial prompt emitted on the empty-norms fatal path"
) || true

# ===========================================================================
# §3: the norms are inserted literally — not by sed, and not by a bash PE replace
# (in bash >=5.2 an unescaped `&` in a ${v//p/r} REPLACEMENT is the matched-text
# reference too, the same hazard norm #3 cites for sed). A norms file containing
# &, / and a {{TDD}}-like token must survive verbatim: the chars are not
# corrupted, and the {{TDD}}-like token inside the norms is NOT re-substituted
# with the TDD path (proving the norms go in LAST and are never re-scanned).
echo "[§3] norms inserted literally: &, / survive; a {{TDD}}-like token in the norms is NOT re-substituted"
( D="$ROOT/r3"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  mk_prompt_dir "$D"
  cat > "$D/build-norms.md" <<'EOF'
## Defensive-coding norms (FR-74)

1. Amp & ersand and a /slash/path survive verbatim.
2. A token {{TDD}} inside the norms must stay literal, never re-substituted.
EOF
  export TMPL="$D/build-prompt.md"; unset STATE_DIR
  prompt="$(_render_build_prompt 0026-x docs/tdd/0026-real.md)"; rc=$?
  [ "$rc" -eq 0 ] && ok "render returns 0 with the sed-breaking norms file" || bad "render should return 0 (got $rc)"
  printf '%s' "$prompt" | grep -qF 'Amp & ersand and a /slash/path' \
    && ok "& and / in the norms survive verbatim (no sed corruption)" || bad "& and / should survive verbatim"
  # The build-prompt body's own {{TDD}} WAS substituted (sed, first)...
  printf '%s' "$prompt" | grep -qF 'Implement docs/tdd/0026-real.md' \
    && ok "the template's own {{TDD}} placeholder was substituted" || bad "the template {{TDD}} should be substituted"
  # ...but the {{TDD}}-like token INSIDE the norms stays literal (norms go in last).
  printf '%s' "$prompt" | grep -qF 'A token {{TDD}} inside the norms' \
    && ok "a {{TDD}}-like token inside the norms is NOT re-substituted (norms inserted last)" \
    || bad "the norms' {{TDD}}-like token should remain literal"
) || true

# ===========================================================================
# §4-unit: _build_norms_reminder emits a one-line lead-in plus the seven TERSE
# norm headlines (the leading number + the label clause up to the first period),
# NOT the full norm bodies — the full norms are already in the build's retained
# context; the reminder re-points at them by name.
echo "[§4-unit] _build_norms_reminder emits a lead-in + the seven terse norm headlines"
( D="$ROOT/u4"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  command -v _build_norms_reminder >/dev/null 2>&1 || { bad "_build_norms_reminder helper missing"; exit 0; }
  mk_prompt_dir "$D"; cp "$NORMS" "$D/build-norms.md"
  export TMPL="$D/build-prompt.md"
  out="$(_build_norms_reminder)"; rc=$?
  [ "$rc" -eq 0 ] && ok "_build_norms_reminder returns 0 with the norms file present" || bad "should return 0 (got $rc)"
  miss=0
  for lbl in "1. Fail loud." "2. Temp files." "3. Safe escaping." "4. Sourced-library hygiene." \
             "5. Path / trust boundary." "6. Read once." "7. No hardcoding."; do
    printf '%s' "$out" | grep -qF "$lbl" || { miss=1; bad "reminder missing terse headline: $lbl"; }
  done
  [ "$miss" -eq 0 ] && ok "all seven terse norm headlines present in the reminder"
  # Terse: the headline stops at the label clause, so a norm BODY phrase must not appear.
  printf '%s' "$out" | grep -qF "Check every command's return code" \
    && bad "reminder should be terse headlines, not the full norm bodies" || ok "reminder is terse (full bodies excluded)"
) || true

# ===========================================================================
# §5-unit: a missing norms file at reminder time degrades to a generic one-liner
# (NOT a fatal) — the reminder is best-effort reinforcement and the full norms are
# already in the build's retained context (distinct from §2's fail-loud render).
echo "[§5-unit] _build_norms_reminder degrades to a generic one-liner when the norms file is gone"
( D="$ROOT/u5"; TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  command -v _build_norms_reminder >/dev/null 2>&1 || { bad "_build_norms_reminder helper missing"; exit 0; }
  mk_prompt_dir "$D"            # build-prompt.md but NO build-norms.md beside it
  export TMPL="$D/build-prompt.md"
  out="$(_build_norms_reminder)"; rc=$?
  [ "$rc" -eq 0 ] && ok "_build_norms_reminder returns 0 (does NOT fail) when the file is gone" || bad "should not fail (got $rc)"
  printf '%s' "$out" | grep -qiF 'defensive-coding norms' && printf '%s' "$out" | grep -qiF 'initial prompt' \
    && ok "degrades to a generic one-line norms reminder" || bad "should emit the generic one-liner (got: $out)"
  printf '%s' "$out" | grep -qF "1. Fail loud." \
    && bad "the degraded reminder must not contain headlines (file is gone)" || ok "no headlines in the degraded reminder"
) || true

# ===========================================================================
# §4: end-to-end — the message written to the build's stdin on a BLOCK verdict
# carries BOTH the original finding AND the norm headlines; a PASS verdict is sent
# UNCHANGED (no reminder). The build coprocess captures its stdin reply to ctl/reply.
echo "[§4] BLOCK reply on the build's stdin carries the finding AND the norm headlines"
( D="$ROOT/e4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  export THROUGHLINE_BUILD_TIMEOUT=0 THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=30
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  printf 'REVIEW_RESULT: BLOCK found a real bug\n' > "$D/repo/ctl/review.out"
  _write_tdd_fragment 0026-fix 26 docs/tdd/0026-fix.md 1 building build 1000 1000 "feat/0026-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true
echo "line 1" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(1): work" >/dev/null 2>&1
echo "STEP_COMMIT: 1 $(git rev-parse HEAD)"
IFS= read -r _reply || true
printf '%s\n' "$_reply" > ctl/reply
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0026-fix docs/tdd/0026-fix.md "$D/e4.log" >/dev/null 2>&1
  reply="$(cat "$D/repo/ctl/reply" 2>/dev/null)"
  printf '%s' "$reply" | grep -qF 'found a real bug' \
    && ok "BLOCK reply preserves the original finding text" || bad "BLOCK reply should carry the finding (got: $reply)"
  printf '%s' "$reply" | grep -qF 'Fail loud.' \
    && ok "BLOCK reply carries the norm headlines (reinforcement at the rework moment)" || bad "BLOCK reply should carry norm headlines (got: $reply)"
) || true

echo "[§4-pass] a PASS reply is sent UNCHANGED (no norm reminder appended)"
( D="$ROOT/e4p"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  export THROUGHLINE_BUILD_TIMEOUT=0 THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=30
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  # review.out defaults to PASS
  _write_tdd_fragment 0026-fix 26 docs/tdd/0026-fix.md 1 building build 1000 1000 "feat/0026-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true
echo "line 1" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(1): work" >/dev/null 2>&1
echo "STEP_COMMIT: 1 $(git rev-parse HEAD)"
IFS= read -r _reply || true
printf '%s\n' "$_reply" > ctl/reply
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0026-fix docs/tdd/0026-fix.md "$D/e4p.log" >/dev/null 2>&1
  reply="$(cat "$D/repo/ctl/reply" 2>/dev/null)"
  printf '%s' "$reply" | grep -qF 'STEP_REVIEW: PASS' \
    && ok "PASS reply reached the build's stdin" || bad "PASS reply should reach stdin (got: $reply)"
  printf '%s' "$reply" | grep -qF 'Fail loud.' \
    && bad "PASS reply must NOT carry a norm reminder (BLOCK-only by design)" || ok "PASS reply carries no norm reminder (sent unchanged)"
) || true

# ===========================================================================
# §5: end-to-end degrade — with the norms file removed AFTER render but BEFORE the
# BLOCK reminder, the BLOCK reply still reaches the build's stdin (build NOT
# aborted) and carries the generic one-liner, not the headlines. TMPL points at a
# fixture so the norms file can be safely removed mid-build.
echo "[§5] degrade end-to-end: BLOCK reply still sent with the generic one-liner; build not aborted"
( D="$ROOT/e5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  export THROUGHLINE_BUILD_TIMEOUT=0 THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=30
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  # Point TMPL at a fixture (with the norms present) so the build_plan can remove
  # the norms file mid-build without touching the real repo's norms.
  mk_prompt_dir "$D/fix"; cp "$NORMS" "$D/fix/build-norms.md"
  export TMPL="$D/fix/build-prompt.md"
  printf 'REVIEW_RESULT: BLOCK found a real bug\n' > "$D/repo/ctl/review.out"
  _write_tdd_fragment 0026-fix 26 docs/tdd/0026-fix.md 1 building build 1000 1000 "feat/0026-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  # build_plan removes the fixture norms AFTER the loop already rendered the prompt
  # (the loop reads it once at start) but BEFORE the BLOCK reminder is computed.
  cat > "$D/repo/ctl/build_plan" <<EOF
IFS= read -r _init || true
rm -f "$D/fix/build-norms.md"
echo "line 1" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(1): work" >/dev/null 2>&1
echo "STEP_COMMIT: 1 \$(git rev-parse HEAD)"
IFS= read -r _reply || true
printf '%s\n' "\$_reply" > ctl/reply
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0026-fix docs/tdd/0026-fix.md "$D/e5.log" >/dev/null 2>&1
  reply="$(cat "$D/repo/ctl/reply" 2>/dev/null)"
  [ -n "$reply" ] && ok "the BLOCK reply still reached the build's stdin (build not aborted)" || bad "reply should still be written (got empty)"
  printf '%s' "$reply" | grep -qF 'found a real bug' \
    && ok "degraded BLOCK reply still carries the finding" || bad "degraded reply should carry the finding (got: $reply)"
  printf '%s' "$reply" | grep -qiF 'initial prompt' \
    && ok "degraded reply carries the generic one-liner reminder" || bad "degraded reply should carry the generic reminder (got: $reply)"
  printf '%s' "$reply" | grep -qF '1. Fail loud.' \
    && bad "degraded reply must NOT carry headlines (the file is gone)" || ok "no headlines once the file is gone"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== build-defensive-norms eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# build-coprocess-lifecycle.test.sh — eval for TDD 0025 (FR-56 mechanism).
#
# Contract under test (function-level): when the build coprocess emits a
# `BATCH_RESULT:` in assistant content, the runner closes its end of the
# build's stdin so the build sees EOF and exits cleanly with rc=0 — NOT
# stalls indefinitely until the 600s inter-event watchdog kills it.
#
# Failing-test-first: this test FAILS on the pre-fix master ( _per_step_review_loop's
# `*"BATCH_RESULT: "*` inner case is a no-op `: ;;`; the stub claude blocks on
# stdin → inter-event timeout fires → exit 143 → THROUGHLINE_BUILD_HANG in log).
# It PASSES after the fix (the inner case closes ${build_in} → stub sees EOF
# → exits 0 → loop drains → wait returns 0 → no HANG marker).
#
# Run: bash tests/build-coprocess-lifecycle.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# --- shared helpers --------------------------------------------------------

# install_stub_claude <bindir> <verdict-line>
# Stub `claude` that prints ONE assistant event whose
# message.content[0].text contains <verdict-line>, then a result(end_turn)
# event, then runs `while read; do :; done` (blocks reading stdin until EOF),
# then exits 0. Prepends <bindir> to PATH.
install_stub_claude() {
  local bindir="$1" verdict="$2"
  mkdir -p "$bindir"
  cat > "$bindir/claude" <<EOF
#!/usr/bin/env bash
# Stub claude for TDD 0025 lifecycle test. Ignores args; emits two stream-json
# events, then blocks on stdin until EOF.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"${verdict}"}]}}'
printf '%s\n' '{"type":"result","subtype":"success","stop_reason":"end_turn","terminal_reason":"completed","is_error":false,"result":"${verdict}"}'
while IFS= read -r _line; do :; done
exit 0
EOF
  chmod +x "$bindir/claude"
  export PATH="$bindir:$PATH"
}

# setup_repo <dir>
# Minimal git repo with one TDD and a build-prompt template so the function
# under test can run end-to-end. cwd is the repo on return.
setup_repo() {
  local dir="$1"
  mkdir -p "$dir/docs/tdd" "$dir/scripts"
  cd "$dir"
  git init -q
  git config user.email t@t.invalid
  git config user.name "lifecycle test"
  cat > docs/tdd/0001-alpha.md <<'TDD'
# TDD 0001 — alpha
Status: draft
## Sequencing
1. step one
## Touched files
- foo.txt
TDD
  cat > scripts/build-prompt.md <<'TMPL'
build {{TDD}} cleared={{CLEARED_STEPS}}
TMPL
  # TDD 0026 / FR-74: _render_build_prompt now requires a build-norms.md beside
  # the build-prompt template (fail-loud if missing). This suite stubs TMPL into
  # a temp scripts/ dir, so it must provide a well-formed norms file or every
  # _per_step_review_loop call aborts at render. Minimal but anchor-valid.
  cat > scripts/build-norms.md <<'NORMS'
## Defensive-coding norms
1. Fail loud. Never swallow an error into a silent empty result.
2. Validate inputs. Reject malformed data at the boundary.
NORMS
  git add -A
  git commit -q -m "init"
}

# --- [VP1] Lifecycle: BATCH_RESULT → clean exit, no HANG -------------------
# Verification point 1 from TDD 0025: a stub claude that emits a final
# assistant turn containing BATCH_RESULT: OK and then blocks on stdin MUST
# cause _per_step_review_loop to (a) return 0, (b) exit within the watchdog
# (here set short for fast failure), (c) record the verdict in the log,
# (d) NOT emit a THROUGHLINE_BUILD_HANG marker.
echo "[VP1] BATCH_RESULT in assistant content → runner closes stdin → build exits cleanly"
( D="$ROOT/vp1"; mkdir -p "$D"
  setup_repo "$D"
  install_stub_claude "$D/bin" "BATCH_RESULT: OK"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # Short inter-event watchdog: a regression hangs here and we want fast feedback.
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=5
  export TMPL="$D/scripts/build-prompt.md"
  log="$D/build.log"
  t0=$(date +%s)
  _per_step_review_loop "0001-alpha" "docs/tdd/0001-alpha.md" "$log"; rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  [ "$rc" = "0" ] \
    && ok "loop returns 0 on clean lifecycle" \
    || bad "loop should return 0 (got rc=$rc — deadlock with watchdog kill?)"
  [ "$elapsed" -lt 5 ] \
    && ok "loop exits within watchdog (took ${elapsed}s)" \
    || bad "loop should exit within 5s but took ${elapsed}s (deadlock signature)"
  grep -q 'BATCH_RESULT: OK' "$log" \
    && ok "gate log contains BATCH_RESULT: OK" \
    || bad "gate log missing BATCH_RESULT: OK"
  grep -q '^THROUGHLINE_BUILD_HANG' "$log" \
    && bad "gate log contains HANG marker (lifecycle regression)" \
    || ok "gate log has no HANG marker"
) || true

# --- [VP5] Explicit FAIL preserved ----------------------------------------
# Verification point 5 from TDD 0025: when the build emits BATCH_RESULT: FAIL,
# the stdin-close fires (lifecycle is identical regardless of verdict), the
# log retains the FAIL verdict, and _per_step_review_loop still returns 0
# (clean coprocess exit) — the FAIL is interpreted by _build_one_gated's
# `build_status` grep, not by the loop's return code. The synth-OK path
# does NOT fire because `bs` is non-empty.
echo "[VP5] BATCH_RESULT: FAIL preserved — synth-OK does NOT fire"
( D="$ROOT/vp5"; mkdir -p "$D"
  setup_repo "$D"
  install_stub_claude "$D/bin" "BATCH_RESULT: FAIL test-failure-reason"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=5
  export TMPL="$D/scripts/build-prompt.md"
  log="$D/build.log"
  t0=$(date +%s)
  _per_step_review_loop "0001-alpha" "docs/tdd/0001-alpha.md" "$log"; loop_rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  [ "$loop_rc" = "0" ] \
    && ok "loop returns 0 on FAIL verdict (clean coprocess exit)" \
    || bad "loop should return 0 on clean FAIL exit (got $loop_rc)"
  [ "$elapsed" -lt 5 ] \
    && ok "FAIL path exits within watchdog (took ${elapsed}s)" \
    || bad "FAIL path should exit within 5s but took ${elapsed}s"
  grep -q 'BATCH_RESULT: FAIL' "$log" \
    && ok "FAIL verdict preserved in gate log" \
    || bad "FAIL verdict missing from log"
  bs="$(build_status "$log")"
  case "$bs" in
    *FAIL*) ok "build_status grep returns FAIL verdict (synth-OK guard correctly skipped)" ;;
    *)      bad "build_status should return FAIL (got '$bs')" ;;
  esac
) || true

# --- [VP6] Sentinel injection: tool_result content must NOT close stdin ----
# Hotfix regression (incident run 20260611-181309; full redesign → TDD 0056):
# a tool_result that merely CONTAINS the literal `BATCH_RESULT: OK` (the build
# Reading ci-checks.sh, whose header comment carries it) is environment-
# authored, not an assistant-declared verdict. Pre-fix, the raw-event
# substring match closed the build's stdin → the stub saw EOF → exited rc=0,
# and the injected string satisfied build_status's grep — the false-complete
# vector. Post-fix the lifecycle does NOT fire; the verdict-less build ends at
# the inter-event watchdog (rc=143 + HANG marker) — the HONEST transient
# outcome for a build that never declared completion.

# install_stub_claude_raw <bindir> <events-file>
# Stub claude that replays the given stream-json events verbatim, then blocks
# reading stdin until EOF (exit 0). Lets a case emit arbitrary event shapes
# (user/tool_result, prose-only assistant turns) the templated stub cannot.
install_stub_claude_raw() {
  local bindir="$1" events="$2"
  mkdir -p "$bindir"
  cat > "$bindir/claude" <<EOF
#!/usr/bin/env bash
# Stub claude (sentinel-injection cases). Replays canned events; blocks on stdin.
cat "$events"
while IFS= read -r _line; do :; done
exit 0
EOF
  chmod +x "$bindir/claude"
  export PATH="$bindir:$PATH"
}

echo "[VP6] injected tool_result carrying 'BATCH_RESULT: OK' → stdin stays open; watchdog ends the verdict-less build"
( D="$ROOT/vp6"; mkdir -p "$D"
  setup_repo "$D"
  cat > "$D/events.jsonl" <<'EVENTS'
{"type":"system","subtype":"init"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"# ci-checks.sh — gates the flip on a real check rather than the model's own `BATCH_RESULT: OK`. Done is verified, not asserted."}]}}
EVENTS
  install_stub_claude_raw "$D/bin" "$D/events.jsonl"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=4
  export TMPL="$D/scripts/build-prompt.md"
  log="$D/build.log"
  _per_step_review_loop "0001-alpha" "docs/tdd/0001-alpha.md" "$log"; rc=$?
  [ "$rc" != "0" ] \
    && ok "loop refuses rc=0 for an injected (non-authored) sentinel (got rc=$rc)" \
    || bad "loop returned 0 — injected tool_result sentinel closed the lifecycle (false-complete vector)"
  grep -q '^THROUGHLINE_BUILD_HANG' "$log" \
    && ok "verdict-less build ends at the watchdog (honest transient)" \
    || bad "no HANG marker — build was treated as cleanly finished without an authored verdict"
) || true

# --- [VP7] Assistant PROSE mention must NOT close stdin --------------------
# The agent routinely RESTATES the protocol in planning text ("I will emit
# BATCH_RESULT: OK when done"). A mid-line/mid-message mention is not a
# verdict: only a final-line, line-anchored sentinel is. Pre-fix the raw
# substring match treated the restatement as completion.
echo "[VP7] assistant prose mentioning 'BATCH_RESULT: OK' mid-sentence → stdin stays open"
( D="$ROOT/vp7"; mkdir -p "$D"
  setup_repo "$D"
  cat > "$D/events.jsonl" <<'EVENTS'
{"type":"assistant","message":{"content":[{"type":"text","text":"Plan: implement each Sequencing step, then after the final step I will emit BATCH_RESULT: OK as the protocol requires."}]}}
EVENTS
  install_stub_claude_raw "$D/bin" "$D/events.jsonl"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=4
  export TMPL="$D/scripts/build-prompt.md"
  log="$D/build.log"
  _per_step_review_loop "0001-alpha" "docs/tdd/0001-alpha.md" "$log"; rc=$?
  [ "$rc" != "0" ] \
    && ok "loop refuses rc=0 for a prose protocol restatement (got rc=$rc)" \
    || bad "loop returned 0 — prose mention closed the lifecycle"
  grep -q '^THROUGHLINE_BUILD_HANG' "$log" \
    && ok "prose-only build ends at the watchdog (honest transient)" \
    || bad "no HANG marker — prose mention was treated as a clean finish"
) || true

# --- [VP8] Control: multi-line final message ENDING with the sentinel ------
# The genuine protocol shape — self-review narrative, then the verdict as the
# final line — must still close the lifecycle (guards against over-anchoring,
# e.g. requiring the whole message to equal the sentinel). Passes pre- and
# post-fix; red here means the guard broke the normal completion path.
echo "[VP8] control: final assistant message ending with the sentinel line still closes stdin"
( D="$ROOT/vp8"; mkdir -p "$D"
  setup_repo "$D"
  install_stub_claude "$D/bin" 'Self-review complete; all steps cleared.\nBATCH_RESULT: OK'
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=5
  export TMPL="$D/scripts/build-prompt.md"
  log="$D/build.log"
  t0=$(date +%s)
  _per_step_review_loop "0001-alpha" "docs/tdd/0001-alpha.md" "$log"; rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  [ "$rc" = "0" ] \
    && ok "loop returns 0 on the genuine multi-line completion" \
    || bad "loop should return 0 (got rc=$rc — guard over-anchored?)"
  [ "$elapsed" -lt 5 ] \
    && ok "control exits within watchdog (took ${elapsed}s)" \
    || bad "control should exit within 5s but took ${elapsed}s (stdin never closed)"
  grep -q '^THROUGHLINE_BUILD_HANG' "$log" \
    && bad "control hit the watchdog (lifecycle broken by the guard)" \
    || ok "control has no HANG marker"
) || true

# --- [VP9] Authored-verdict marker: exactly once, column 0, verbatim -------
# TDD 0056 §1 (NFR-4 / FR-15): at the moment the authored-verdict rule fires,
# the runner echoes the observed verdict as a canonical column-0 marker line
# `THROUGHLINE_AUTHORED_VERDICT: <verbatim final line>`. The stub emits TWO
# sentinel-bearing events (assistant text + result), so an unguarded write
# would produce two markers — the _build_stdin_closed latch must bound it to
# exactly one.
echo "[VP9] authored verdict echoed once as a column-0 THROUGHLINE_AUTHORED_VERDICT marker"
( D="$ROOT/vp9"; mkdir -p "$D"
  setup_repo "$D"
  install_stub_claude "$D/bin" "BATCH_RESULT: OK"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=5
  export TMPL="$D/scripts/build-prompt.md"
  log="$D/build.log"
  _per_step_review_loop "0001-alpha" "docs/tdd/0001-alpha.md" "$log"; rc=$?
  [ "$rc" = "0" ] \
    && ok "loop returns 0 on clean lifecycle" \
    || bad "loop should return 0 (got rc=$rc)"
  n="$(grep -ac '^THROUGHLINE_AUTHORED_VERDICT: BATCH_RESULT: OK$' "$log")"
  [ "$n" = "1" ] \
    && ok "marker line appears exactly once, at column 0, carrying the verbatim verdict" \
    || bad "expected exactly one '^THROUGHLINE_AUTHORED_VERDICT: BATCH_RESULT: OK' line (got ${n:-0})"
  bs="$(build_status "$log")"
  [ "$bs" = "BATCH_RESULT: OK" ] \
    && ok "build_status echoes BATCH_RESULT: OK" \
    || bad "build_status should echo 'BATCH_RESULT: OK' (got '$bs')"
) || true

# --- [VP10] Marker wins over injected junk — ordering-independent ----------
# TDD 0056 §2 (NFR-4 / FR-15): the genuine authored verdict must survive a log
# that ALSO contains injected `BATCH_RESULT: OK` junk arriving AFTER it — the
# ordering-independence point the implicit four-link chain could not
# guarantee. The stub authors a genuine FAIL, then (post-verdict, while the
# loop drains tail events) a tool_result mirroring sentinel-bearing text. A
# whole-log substring grep + tail -1 would return the junk OK; the marker-first
# read must return the authored FAIL.
echo "[VP10] genuine authored FAIL survives later injected JSON-carried 'BATCH_RESULT: OK' junk"
( D="$ROOT/vp10"; mkdir -p "$D"
  setup_repo "$D"
  cat > "$D/events.jsonl" <<'EVENTS'
{"type":"assistant","message":{"content":[{"type":"text","text":"Step 3 could not be completed; see log.\nBATCH_RESULT: FAIL genuine-authored-verdict"}]}}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"# ci-checks.sh — gates the flip on a real check rather than the model's own `BATCH_RESULT: OK`. Done is verified, not asserted."}]}}
EVENTS
  install_stub_claude_raw "$D/bin" "$D/events.jsonl"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=5
  export TMPL="$D/scripts/build-prompt.md"
  log="$D/build.log"
  _per_step_review_loop "0001-alpha" "docs/tdd/0001-alpha.md" "$log"; rc=$?
  [ "$rc" = "0" ] \
    && ok "loop returns 0 (authored FAIL closes the lifecycle cleanly)" \
    || bad "loop should return 0 (got rc=$rc)"
  bs="$(build_status "$log")"
  [ "$bs" = "BATCH_RESULT: FAIL genuine-authored-verdict" ] \
    && ok "build_status returns the authored FAIL (marker wins; ordering-independent)" \
    || bad "build_status should return the authored FAIL line, not later injected junk (got '$bs')"
) || true

# --- [VP11] Bare-line fallback: degraded/no-marker log still parses --------
# TDD 0056 §2: a stub/degraded log (the non-stream-json path, pre-0056 logs)
# carries a bare-line sentinel and no marker; build_status's line-anchored
# fallback must still parse it (compat preserved). The anchored fallback can
# never match a sentinel INSIDE a mirrored JSON event line — only at column 0.
echo "[VP11] bare-line sentinel in a marker-less degraded log parses via the anchored fallback"
( D="$ROOT/vp11"; mkdir -p "$D"
  setup_repo "$D"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  log="$D/degraded.log"
  printf 'plain-text degraded output, no stream-json\nBATCH_RESULT: OK\n' > "$log"
  bs="$(build_status "$log")"
  [ "$bs" = "BATCH_RESULT: OK" ] \
    && ok "fallback parses the bare-line sentinel (got '$bs')" \
    || bad "fallback should parse the bare-line sentinel (got '$bs')"
) || true

# --- [VP12] Clean-exit-no-verdict → return 1; synth-OK fallback is gone ----
# TDD 0056 §4 (NFR-4 / ADR 0006): a build that exits rc=0 WITHOUT an authored
# verdict (injection-only log, the VP6 event shape, but a stub that exits
# instead of blocking) must read as "build did not return OK" — return 1, no
# fabricated `BATCH_RESULT: OK (synthesized: ...)` line. The harness arms the
# old fallback's every precondition (STATE_DIR fragment with
# last_cleared_review_sha == HEAD, clean working tree) to prove the fabricated-
# verdict path is REMOVED, not merely unarmed.

# install_stub_claude_raw_noblock <bindir> <events-file>
# Like install_stub_claude_raw but exits 0 immediately after replaying the
# events (no blocking read) — the clean-exit-no-verdict shape synth-OK guarded.
install_stub_claude_raw_noblock() {
  local bindir="$1" events="$2"
  mkdir -p "$bindir"
  cat > "$bindir/claude" <<EOF
#!/usr/bin/env bash
# Stub claude (clean-exit-no-verdict case). Replays canned events; exits 0.
cat "$events"
exit 0
EOF
  chmod +x "$bindir/claude"
  export PATH="$bindir:$PATH"
}

echo "[VP12] clean exit without an authored verdict → _build_one_gated returns 1, nothing synthesized"
( D="$ROOT/vp12"; mkdir -p "$D"
  # Repo in a SUBDIR so the harness's aux files (events, state.d, log) stay
  # outside the working tree — the old fallback required `git status
  # --porcelain` empty, and untracked aux files would unarm it vacuously.
  setup_repo "$D/repo"
  cat > "$D/events.jsonl" <<'EVENTS'
{"type":"system","subtype":"init"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"# ci-checks.sh — gates the flip on a real check rather than the model's own `BATCH_RESULT: OK`. Done is verified, not asserted."}]}}
EVENTS
  install_stub_claude_raw_noblock "$D/bin" "$D/events.jsonl"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=5
  export TMPL="$D/repo/scripts/build-prompt.md"
  export STATE_DIR="$D/state.d"; mkdir -p "$STATE_DIR"
  printf '{"slug":"0001-alpha","last_cleared_review_sha":"%s","cleared_step_log":[]}\n' \
    "$(git rev-parse HEAD)" > "$STATE_DIR/0001-alpha.json"
  log="$D/build.log"
  _build_one_gated "docs/tdd/0001-alpha.md" "$log"; rc=$?
  bs="$(build_status "$log")"
  [ -z "$bs" ] \
    && ok "build_status returns empty on the injection-only log" \
    || bad "build_status should return empty (got '$bs')"
  [ "$rc" = "1" ] \
    && ok "_build_one_gated returns 1 (no verdict = not OK)" \
    || bad "_build_one_gated should return 1 (got rc=$rc)"
  grep -aq 'synthesized' "$log" \
    && bad "log contains a synthesized verdict line (synth-OK fallback still present)" \
    || ok "log contains NO synthesized line (synth-OK gone)"
) || true

# --- [VP13] Narrative facts: marker wins the build-verdict-line fact -------
# TDD 0056 §3 (FR-71 / ADR 0006): _diff_vs_narrative_facts' br extraction is
# marker-first with the same anchored fallback, so an injected JSON-carried
# sentinel — even one arriving AFTER the marker — is no longer selected as the
# `build-verdict-line:` fact the reviewer's honesty check anchors on.
echo "[VP13] _diff_vs_narrative_facts selects the marker's verdict, not injected JSON-carried junk"
( D="$ROOT/vp13"; mkdir -p "$D"
  setup_repo "$D"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  log="$D/build.log"
  cat > "$log" <<'LOG'
{"type":"assistant","message":{"content":[{"type":"text","text":"Step 3 could not be completed; see log.\nBATCH_RESULT: FAIL genuine-authored-verdict"}]}}
THROUGHLINE_AUTHORED_VERDICT: BATCH_RESULT: FAIL genuine-authored-verdict
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"# ci-checks.sh — gates the flip on a real check rather than the model's own `BATCH_RESULT: OK`. Done is verified, not asserted."}]}}
LOG
  facts="$(_diff_vs_narrative_facts "$log" "$(git rev-parse HEAD)")"
  bvl="$(printf '%s\n' "$facts" | grep '^build-verdict-line: ')"
  [ "$bvl" = "build-verdict-line: BATCH_RESULT: FAIL genuine-authored-verdict" ] \
    && ok "build-verdict-line fact equals the marker's verdict" \
    || bad "build-verdict-line should be the marker's authored FAIL, not injected junk (got '$bvl')"
) || true

# --- report ----------------------------------------------------------------
# grep -c exits non-zero when there are zero matches; suppress that so the
# `0 failed` happy path doesn't leak its exit code through pipefail.
n_ok=$(grep -c '^ok$' "$RESULTS" 2>/dev/null); n_ok=${n_ok:-0}
n_fail=$(grep -c '^fail$' "$RESULTS" 2>/dev/null); n_fail=${n_fail:-0}
echo
printf 'build-coprocess-lifecycle: %s passed, %s failed\n' "$n_ok" "$n_fail"
[ "$n_fail" -eq 0 ]

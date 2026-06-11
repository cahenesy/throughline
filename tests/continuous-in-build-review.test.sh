#!/usr/bin/env bash
# continuous-in-build-review.test.sh — eval for continuous in-build review
# (TDD 0020 / FR-56, FR-57, FR-59; ADR 0006).
#
# The contract under test (function-level; the runtime-verify gate re-drives the
# same observable surface against a real /implement run):
#   - the per-TDD fragment gains last_cleared_review_sha (string|null) and
#     cleared_step_log (array), threaded through _write_tdd_fragment and carried
#     forward by every fragment writer (FR-57 / ADR 0006).
#   - _record_cleared_step appends a {step_id, base_sha, head_sha, pattern_tags,
#     cleared_at} entry and advances last_cleared_review_sha atomically.
#   - the review prompt carries a "Scope of this pass" section anchored to the
#     SHA range and a "Prior addressed patterns" section (FR-59), interpolated by
#     the runner.
#   - the build/runner coprocess intercepts STEP_COMMIT: sentinels, runs a scoped
#     per-step review, and replies STEP_REVIEW: PASS|BLOCK on the build's stdin;
#     a sentinel-less build degrades to end-of-build review.
#
# Run: bash tests/continuous-in-build-review.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
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

# --- §4 / Data: cleared-step log + last-cleared-SHA fields -------------------
echo "[A1] _write_tdd_fragment writes last_cleared_review_sha + cleared_step_log (params 24-25)"
( D="$ROOT/A1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0020-x 20 docs/tdd/0020-x.md 1 reviewing review \
    1000 1000 "feat/0020-x" "" "log" "" "" "" "" "" \
    "" "" "" "" \
    "" "" "" \
    "abc123" '[{"step_id":1,"base_sha":"aaa","head_sha":"abc123","pattern_tags":["t1"],"cleared_at":1000}]'
  F="$D/state.d/0020-x.json"
  grep -q '"last_cleared_review_sha":"abc123"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha round-trips" || bad "last_cleared_review_sha should round-trip (got: $(cat "$F"))"
  grep -q '"cleared_step_log":\[{"step_id":1,"base_sha":"aaa","head_sha":"abc123"' "$F" 2>/dev/null \
    && ok "cleared_step_log array round-trips" || bad "cleared_step_log should round-trip"
) || true

echo "[A2] _write_tdd_fragment defaults the new fields to null / [] when empty"
( D="$ROOT/A2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # The historical 23-arg (TDD 0019) call shape must still emit the new
  # defaults so old call sites keep working.
  _write_tdd_fragment 0001-a 1 docs/tdd/0001-a.md 1 pending "" \
    1000 1000 "" "" "" "" "" "" "" "" \
    "" "" "" "" \
    "" "" ""
  F="$D/state.d/0001-a.json"
  grep -q '"last_cleared_review_sha":null' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha defaults to null" || bad "last_cleared_review_sha should default to null (got: $(cat "$F"))"
  grep -q '"cleared_step_log":\[\]' "$F" 2>/dev/null \
    && ok "cleared_step_log defaults to []" || bad "cleared_step_log should default to []"
) || true

echo "[A3] _read_fragment_field + _read_fragment_raw_array read the new fields"
( D="$ROOT/A3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  F="$D/state.d/0020-x.json"
  printf '{"slug":"0020-x","last_cleared_review_sha":"deadbee","cleared_step_log":[{"step_id":2,"head_sha":"deadbee"}]}\n' > "$F"
  [ "$(_read_fragment_field "$F" last_cleared_review_sha)" = "deadbee" ] \
    && ok "reads last_cleared_review_sha" || bad "should read last_cleared_review_sha (got '$(_read_fragment_field "$F" last_cleared_review_sha)')"
  [ "$(_read_fragment_raw_array "$F" cleared_step_log)" = '[{"step_id":2,"head_sha":"deadbee"}]' ] \
    && ok "reads cleared_step_log array" || bad "should read cleared_step_log (got '$(_read_fragment_raw_array "$F" cleared_step_log)')"
) || true

echo "[A4] _record_cleared_step appends an entry and advances last_cleared_review_sha"
( D="$ROOT/A4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0020-x 20 docs/tdd/0020-x.md 1 reviewing review \
    1000 1000 "feat/0020-x" "" "log" "" "" "" "" "" "" "" "" "" "" "" ""
  _record_cleared_step 0020-x 1 base000 head111 "tag-a,tag-b"
  F="$D/state.d/0020-x.json"
  grep -q '"last_cleared_review_sha":"head111"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha advanced to head111" || bad "last_cleared_review_sha should be head111 (got: $(_read_fragment_field "$F" last_cleared_review_sha))"
  grep -q '"step_id":1' "$F" 2>/dev/null \
    && ok "cleared_step_log entry records step_id" || bad "entry should record step_id (got: $(_read_fragment_raw_array "$F" cleared_step_log))"
  grep -q '"base_sha":"base000"' "$F" 2>/dev/null \
    && ok "entry records base_sha" || bad "entry should record base_sha"
  grep -q '"head_sha":"head111"' "$F" 2>/dev/null \
    && ok "entry records head_sha" || bad "entry should record head_sha"
  grep -q '"pattern_tags":\["tag-a","tag-b"\]' "$F" 2>/dev/null \
    && ok "entry records pattern_tags as a JSON array" || bad "entry should record pattern_tags array (got: $(_read_fragment_raw_array "$F" cleared_step_log))"
  # A second cleared step appends (does not overwrite) and re-advances the SHA.
  _record_cleared_step 0020-x 2 head111 head222 ""
  n="$(grep -oE '"step_id":[0-9]+' "$F" | wc -l)"
  [ "$n" -eq 2 ] && ok "second cleared step appends (two entries)" || bad "cleared_step_log should have two entries (got $n)"
  grep -q '"last_cleared_review_sha":"head222"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha re-advanced to head222" || bad "last_cleared_review_sha should be head222"
  grep -q '"step_id":2,"base_sha":"head111","head_sha":"head222","pattern_tags":\[\]' "$F" 2>/dev/null \
    && ok "empty pattern tags record as []" || bad "empty pattern_tags should be [] (got: $(_read_fragment_raw_array "$F" cleared_step_log))"
) || true

echo "[A5] set_tdd_state / set_tdd_meta carry the new fields forward"
( D="$ROOT/A5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0020-x 20 docs/tdd/0020-x.md 1 reviewing review \
    1000 1000 "feat/0020-x" "" "log" "" "" "" "" "" \
    "" "" "" "" \
    "" "" "" \
    "ccc333" '[{"step_id":1,"base_sha":"a","head_sha":"ccc333","pattern_tags":[],"cleared_at":1}]'
  set_tdd_state 0020-x reviewing flip
  F="$D/state.d/0020-x.json"
  grep -q '"last_cleared_review_sha":"ccc333"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha survives set_tdd_state" || bad "last_cleared_review_sha must survive set_tdd_state"
  grep -q '"cleared_step_log":\[{"step_id":1' "$F" 2>/dev/null \
    && ok "cleared_step_log survives set_tdd_state" || bad "cleared_step_log must survive set_tdd_state"
  set_tdd_meta 0020-x "pr_url=http://x"
  grep -q '"last_cleared_review_sha":"ccc333"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha survives set_tdd_meta" || bad "last_cleared_review_sha must survive set_tdd_meta"
  grep -q '"cleared_step_log":\[{"step_id":1' "$F" 2>/dev/null \
    && ok "cleared_step_log survives set_tdd_meta" || bad "cleared_step_log must survive set_tdd_meta"
) || true

echo "[A6] set_halt_cause / _append_retry / _enter_paused carry the new fields forward"
( D="$ROOT/A6"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0020-x 20 docs/tdd/0020-x.md 1 blocked review \
    1000 1000 "feat/0020-x" "" "log" "" "" "" "" "" \
    "" "" "" "" \
    "" "" "" \
    "ddd444" '[{"step_id":1,"base_sha":"a","head_sha":"ddd444","pattern_tags":[],"cleared_at":1}]'
  F="$D/state.d/0020-x.json"
  set_halt_cause 0020-x rework-budget-exhausted "review:1"
  grep -q '"last_cleared_review_sha":"ddd444"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha survives set_halt_cause" || bad "last_cleared_review_sha must survive set_halt_cause"
  grep -q '"cleared_step_log":\[{"step_id":1' "$F" 2>/dev/null \
    && ok "cleared_step_log survives set_halt_cause" || bad "cleared_step_log must survive set_halt_cause"
  _append_retry 0020-x review 1 30
  grep -q '"last_cleared_review_sha":"ddd444"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha survives _append_retry" || bad "last_cleared_review_sha must survive _append_retry"
  _enter_paused 0020-x transient review "$D/p.log"
  grep -q '"cleared_step_log":\[{"step_id":1' "$F" 2>/dev/null \
    && ok "cleared_step_log survives _enter_paused" || bad "cleared_step_log must survive _enter_paused"
) || true

# --- §3 / FR-57, FR-59: review-prompt scope + prior-patterns + pattern-tags ---
echo "[B1] review-prompt.md carries the scope, prior-patterns, and pattern-tag sections"
( cd "$REPO"
  F="scripts/review-prompt.md"
  grep -qi 'Scope of this pass'        "$F" && ok "has 'Scope of this pass' section" || bad "review prompt needs a Scope-of-this-pass section (FR-57)"
  grep -q '{{SCOPE_BASE}}'             "$F" && ok "has {{SCOPE_BASE}} placeholder" || bad "review prompt needs {{SCOPE_BASE}}"
  grep -q '{{SCOPE_HEAD}}'             "$F" && ok "has {{SCOPE_HEAD}} placeholder" || bad "review prompt needs {{SCOPE_HEAD}}"
  grep -q '{{BRANCH}}'                 "$F" && ok "has {{BRANCH}} placeholder" || bad "review prompt needs {{BRANCH}}"
  grep -qi 'Prior addressed patterns'  "$F" && ok "has 'Prior addressed patterns' section (FR-59)" || bad "review prompt needs a Prior-addressed-patterns section (FR-59)"
  grep -q '{{PRIOR_PATTERNS}}'         "$F" && ok "has {{PRIOR_PATTERNS}} placeholder" || bad "review prompt needs {{PRIOR_PATTERNS}}"
  grep -qi 'recurrent-pattern'         "$F" && ok "instructs the recurrent-pattern finding kind" || bad "review prompt needs the recurrent-pattern instruction"
  grep -qi 'pattern_tags'              "$F" && ok "instructs per-finding pattern_tags emission" || bad "review prompt needs the pattern_tags emission instruction"
) || true

echo "[B2] _review_prior_patterns_csv flattens + dedups cleared_step_log[*].pattern_tags"
( D="$ROOT/B2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  F="$D/state.d/0020-x.json"
  printf '{"slug":"0020-x","cleared_step_log":[{"step_id":1,"pattern_tags":["tag-a","tag-b"]},{"step_id":2,"pattern_tags":["tag-b","tag-c"]}]}\n' > "$F"
  csv="$(_review_prior_patterns_csv 0020-x)"
  # all three distinct tags present; tag-b not duplicated.
  printf '%s' "$csv" | grep -q 'tag-a' && printf '%s' "$csv" | grep -q 'tag-c' \
    && ok "extracts tags across all cleared steps" || bad "should extract tag-a..tag-c (got '$csv')"
  [ "$(printf '%s' "$csv" | tr ',' '\n' | grep -c '^tag-b$')" = "1" ] \
    && ok "dedups a tag that recurs across steps" || bad "tag-b should appear once (got '$csv')"
  # No fragment / no tags → empty.
  [ -z "$(_review_prior_patterns_csv 0000-none)" ] \
    && ok "missing fragment yields empty CSV" || bad "missing fragment should yield empty CSV"
) || true

echo "[B3] _render_review_prompt substitutes scope + branch + prior-patterns placeholders"
( D="$ROOT/B3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" RTMPL="$REPO/scripts/review-prompt.md"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  out="$(_render_review_prompt docs/tdd/0020-x.md base999 head888 "build/ci/0020-x" "tag-a,tag-b")"
  printf '%s' "$out" | grep -q 'base999..head888' \
    && ok "scope base..head substituted" || bad "scope range should be base999..head888 (got scope line: $(printf '%s' "$out" | grep -i scope))"
  printf '%s' "$out" | grep -q 'build/ci/0020-x' \
    && ok "branch substituted" || bad "branch should be substituted"
  printf '%s' "$out" | grep -q 'tag-a, tag-b' \
    && ok "prior patterns substituted (comma-space joined)" || bad "prior patterns should be substituted (got: $(printf '%s' "$out" | grep -i 'prior'))"
  printf '%s' "$out" | grep -q '{{SCOPE_BASE}}' \
    && bad "raw {{SCOPE_BASE}} placeholder leaked into rendered prompt" || ok "no raw placeholder leaks"
) || true

echo "[B4] _render_review_prompt renders 'none' for empty prior patterns and no leaks"
( D="$ROOT/B4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" RTMPL="$REPO/scripts/review-prompt.md"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  out="$(_render_review_prompt docs/tdd/0020-x.md base000 HEAD "master" "")"
  printf '%s' "$out" | grep -qi 'prior addressed patterns' \
    && ok "section present even with no prior patterns" || bad "prior-patterns section should still render"
  printf '%s' "$out" | grep -q '{{PRIOR_PATTERNS}}' \
    && bad "raw {{PRIOR_PATTERNS}} leaked when empty" || ok "empty prior patterns leave no raw placeholder"
) || true

echo "[B5] _extract_pattern_tags pulls pattern_tags: lines from review output into a CSV"
( D="$ROOT/B5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  L="$D/review.log"
  cat > "$L" <<'EOF'
Finding 1: src/a.txt:10 unchecked return
pattern_tags: [unchecked-fragment-write-return, missing-guard]
Finding 2: src/b.txt:3 another
pattern_tags: [unchecked-fragment-write-return]
REVIEW_RESULT: PASS
EOF
  csv="$(_extract_pattern_tags "$L")"
  printf '%s' "$csv" | grep -q 'unchecked-fragment-write-return' \
    && ok "extracts a pattern tag" || bad "should extract unchecked-fragment-write-return (got '$csv')"
  printf '%s' "$csv" | grep -q 'missing-guard' \
    && ok "extracts a second tag from the same line" || bad "should extract missing-guard (got '$csv')"
  [ "$(printf '%s' "$csv" | tr ',' '\n' | grep -c '^unchecked-fragment-write-return$')" = "1" ] \
    && ok "dedups a tag emitted by two findings" || bad "duplicate tag should collapse (got '$csv')"
  # No pattern_tags lines → empty CSV.
  printf 'REVIEW_RESULT: PASS\n' > "$D/review2.log"
  [ -z "$(_extract_pattern_tags "$D/review2.log")" ] \
    && ok "no pattern_tags lines yields empty CSV" || bad "absent pattern_tags should yield empty"
) || true

echo "[B6] review_one renders a scoped prompt carrying base..HEAD, branch, and prior patterns"
( D="$ROOT/B6"; mkdir -p "$D/state.d" "$D/bin"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" RTMPL="$REPO/scripts/review-prompt.md" REVIEW_MODEL=""
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd
  printf '# TDD 0020\nStatus: draft\n' > docs/tdd/0020-x.md
  git add -A; git commit -qm base >/dev/null
  BS="$(git rev-parse HEAD)"
  # A build-output commit PAST the build-start base so the review scope BS..HEAD is
  # non-empty and BS is a resolvable ref — TDD 0031 §2's empty-scope guard fails
  # closed on an empty/unresolvable scope (the old literal "deadbeef" base no longer
  # resolves). The reviewer stub echoes the prompt regardless of diff content.
  printf 'work\n' >> docs/tdd/0020-x.md; git add -A; git commit -qm "build output" >/dev/null
  # Fragment with a prior cleared step carrying a pattern tag.
  printf '{"slug":"0020-x","cleared_step_log":[{"step_id":1,"pattern_tags":["prior-tag-x"]}]}\n' > "$D/state.d/0020-x.json"
  cat > "$D/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
printf '%s' "\$prompt" > "$D/captured"
echo "REVIEW_RESULT: PASS"
EOF
  chmod +x "$D/bin/claude"; export PATH="$D/bin:$PATH"
  review_one docs/tdd/0020-x.md "$BS" "$D/r.log" >/dev/null 2>&1
  grep -q "$BS..HEAD" "$D/captured" 2>/dev/null \
    && ok "review_one scopes the prompt to <base>..HEAD" || bad "review_one prompt should scope $BS..HEAD"
  grep -q 'prior-tag-x' "$D/captured" 2>/dev/null \
    && ok "review_one interpolates the prior pattern tags (FR-59)" || bad "review_one should interpolate prior-tag-x"
  grep -q 'REVIEW_RESULT: PASS' "$D/r.log" 2>/dev/null \
    && ok "review verdict still parsed from the log" || bad "review_one should still log the verdict"
) || true

echo "[A7] cleared_step_log stays well-formed JSON across appends + carry-forward (FR-44; nested pattern_tags arrays)"
( D="$ROOT/A7"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0020-x 20 docs/tdd/0020-x.md 1 reviewing review \
    1000 1000 "" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  _record_cleared_step 0020-x 1 base000 head111 "tag-a,tag-b"
  _record_cleared_step 0020-x 2 head111 head222 "tag-c"
  set_tdd_state 0020-x reviewing flip   # carry-forward must not corrupt the nested arrays
  F="$D/state.d/0020-x.json"
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$F" >/dev/null 2>&1 && ok "fragment is valid JSON after two appends + a carry-forward" \
      || bad "fragment must stay valid JSON (got: $(cat "$F"))"
    n="$(jq '.cleared_step_log | length' "$F" 2>/dev/null)"
    [ "$n" = "2" ] && ok "cleared_step_log has exactly two entries" || bad "cleared_step_log should have two entries (got '$n')"
    [ "$(jq -r '.cleared_step_log[1].pattern_tags[0]' "$F" 2>/dev/null)" = "tag-c" ] \
      && ok "second entry's nested pattern_tags survive intact" || bad "nested pattern_tags should survive (got: $(_read_fragment_raw_array "$F" cleared_step_log 2>/dev/null))"
  else
    # Without jq, at least assert the structural bracket balance the corruption broke.
    [ "$(grep -oF '[' "$F" | wc -l)" = "$(grep -oF ']' "$F" | wc -l)" ] \
      && ok "bracket count balanced (no jq)" || bad "brackets unbalanced — cleared_step_log corrupted"
  fi
) || true

# --- §2 / Build subprocess protocol: _per_step_review_loop coprocess + handshake
echo "[C0] _extract_event_text pulls content text from a JSON event, raw line otherwise"
( D="$ROOT/C0"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  if command -v jq >/dev/null 2>&1; then
    t="$(_extract_event_text '{"type":"assistant","message":{"content":[{"type":"text","text":"STEP_COMMIT: 1 abc"}]}}')"
    case "$t" in *"STEP_COMMIT: 1 abc"*) ok "extracts STEP_COMMIT from JSON content text" ;; *) bad "should extract content text (got '$t')" ;; esac
    t2="$(_extract_event_text '{"type":"system","subtype":"init"}')"
    [ -z "$t2" ] && ok "non-message JSON event yields empty text" || bad "non-message event should be empty (got '$t2')"
  fi
  t3="$(_extract_event_text 'STEP_COMMIT: 2 def')"
  case "$t3" in *"STEP_COMMIT: 2 def"*) ok "plain (non-JSON) line returned raw" ;; *) bad "plain line should be returned raw (got '$t3')" ;; esac
) || true

echo "[C0b] _user_turn_json wraps a STEP_REVIEW reply as a stream-json user turn"
( D="$ROOT/C0b"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  out="$(_user_turn_json 'STEP_REVIEW: PASS')"
  if command -v jq >/dev/null 2>&1; then
    [ "$(printf '%s' "$out" | jq -r '.type')" = "user" ] && ok "user-turn JSON has type=user" || bad "should be a user turn (got '$out')"
    [ "$(printf '%s' "$out" | jq -r '.message.content')" = "STEP_REVIEW: PASS" ] && ok "content carries the verdict" || bad "content should be the verdict"
  else
    case "$out" in *'"type":"user"'*'STEP_REVIEW: PASS'*) ok "user-turn JSON shape (no jq)" ;; *) bad "user-turn shape wrong (got '$out')" ;; esac
  fi
) || true

# setup_step_repo <dir>: a git repo + scope-declaring TDD + a state fragment + a
# stub `claude` that acts as BOTH the multi-turn build (emits STEP_COMMIT lines,
# blocks on STEP_REVIEW stdin replies, per $CTL/build_plan) and the per-step
# review (echoes $CTL/review.out). Leaves PWD in the repo. Mirrors the
# bounded-rework-loop setup_loop_repo pattern.
setup_step_repo() {  # <dir>
  local d="$1"; mkdir -p "$d/ctl" "$d/bin"
  cd "$d" || return 1
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p src docs/tdd
  printf 'ctl/\nbin/\n' > .gitignore
  printf 'orig\n' > src/a.txt
  cat > docs/tdd/0020-fix.md <<'EOF'
# TDD 0020: fixture
Status: draft
PRD refs: 1

## Touched files
- `src/a.txt` — the in-scope file
EOF
  git add -A; git commit -qm "build start" >/dev/null
  # Stub claude: build path records its argv, then runs $CTL/build_plan (which
  # emits STEP_COMMIT lines and reads STEP_REVIEW replies). Review path echoes
  # $CTL/review.out (default PASS) and captures the review prompt per step.
  cat > "$d/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""; argv="\$*"
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
if printf '%s' "\$prompt" | grep -q 'INDEPENDENT review gate'; then
  # capture each review prompt for scope/prior-pattern assertions
  n=\$(cat "$d/ctl/revcount" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$d/ctl/revcount"
  printf '%s' "\$prompt" > "$d/ctl/review-prompt.\$n"
  cat "$d/ctl/review.out" 2>/dev/null || echo "REVIEW_RESULT: PASS"
  exit 0
fi
# build path
printf '%s\n' "\$argv" > "$d/ctl/build-argv"
bash "$d/ctl/build_plan"
EOF
  chmod +x "$d/bin/claude"
  export PATH="$d/bin:$PATH"
  export TMPL="$REPO/scripts/build-prompt.md" RTMPL="$REPO/scripts/review-prompt.md"
  export MODEL="" REVIEW_MODEL="" MAINREPO="$d"
  printf 'REVIEW_RESULT: PASS\n' > "$d/ctl/review.out"
}

echo "[C1] sentinel handshake: 3 STEP_COMMITs -> 3 STEP_REVIEW PASS -> 3 cleared steps in order"
( D="$ROOT/C1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
# Consume the runner's initial user-turn prompt first (the runner writes it on
# stdin before the loop, matching real `claude -p --input-format stream-json`).
# Without this, every per-STEP_COMMIT reply read is off by one and the build
# exits one verdict early — leaving the final verdict write hitting a dead
# coprocess (TDD 0030 §1). The init read keeps the handshake aligned.
IFS= read -r _init || true
for i in 1 2 3; do
  echo "line $i" >> src/a.txt
  git add -A >/dev/null 2>&1; git commit -q -m "step($i): work" >/dev/null 2>&1
  echo "STEP_COMMIT: $i $(git rev-parse HEAD)"
  IFS= read -r _reply || true
done
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/c1.log"; rc=$?
  F="$STATE_DIR/0020-fix.json"
  [ "$rc" -eq 0 ] && ok "loop returns 0 on a clean handshake" || bad "loop should return 0 (rc=$rc)"
  grep -q 'BATCH_RESULT: OK' "$D/c1.log" 2>/dev/null && ok "BATCH_RESULT mirrored to the log" || bad "log should mirror BATCH_RESULT"
  if command -v jq >/dev/null 2>&1; then
    n="$(jq '.cleared_step_log | length' "$F" 2>/dev/null)"
    [ "$n" = "3" ] && ok "three cleared steps recorded" || bad "should record 3 cleared steps (got '$n')"
    [ "$(jq -r '.cleared_step_log[0].step_id' "$F")" = "1" ] && [ "$(jq -r '.cleared_step_log[2].step_id' "$F")" = "3" ] \
      && ok "cleared steps in order 1..3" || bad "cleared steps should be in order"
    lc="$(jq -r '.last_cleared_review_sha' "$F")"
    h3="$(jq -r '.cleared_step_log[2].head_sha' "$F")"
    [ "$lc" = "$h3" ] && ok "last_cleared_review_sha matches the 3rd step head" || bad "last_cleared should match 3rd head ($lc vs $h3)"
  fi
) || true

echo "[C2] scoped diff: step 2's review base = step 1's cleared head (not build start) — FR-57"
( D="$ROOT/C2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true   # consume the runner's initial prompt (TDD 0030 §1) so reply reads stay aligned
for i in 1 2; do
  echo "line $i" >> src/a.txt
  git add -A >/dev/null 2>&1; git commit -q -m "step($i): work" >/dev/null 2>&1
  echo "$(git rev-parse HEAD)" >> ctl/heads
  echo "STEP_COMMIT: $i $(git rev-parse HEAD)"
  IFS= read -r _reply || true
done
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/c2.log" >/dev/null 2>&1
  step1_head="$(sed -n 1p "$D/repo/ctl/heads")"
  # the SECOND review prompt should scope from step 1's head
  grep -q "$step1_head" "$D/repo/ctl/review-prompt.2" 2>/dev/null \
    && ok "step 2 review scopes from step 1's cleared head (FR-57)" || bad "step 2 review base should be step1 head ($step1_head)"
) || true

echo "[C3+C4] pattern tags recorded on clear; step 2 review prompt shows the prior pattern (FR-59)"
( D="$ROOT/C3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  # step 1's review PASSes but emits a (minor) finding with a pattern tag.
  printf 'minor: src/a.txt:1 nit\npattern_tags: [unchecked-fragment-write-return]\nREVIEW_RESULT: PASS\n' > "$D/repo/ctl/review.out"
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true   # consume the runner's initial prompt (TDD 0030 §1) so reply reads stay aligned
for i in 1 2; do
  echo "line $i" >> src/a.txt
  git add -A >/dev/null 2>&1; git commit -q -m "step($i): work" >/dev/null 2>&1
  echo "STEP_COMMIT: $i $(git rev-parse HEAD)"
  IFS= read -r _reply || true
done
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/c3.log" >/dev/null 2>&1
  F="$STATE_DIR/0020-fix.json"
  grep -q 'unchecked-fragment-write-return' "$F" 2>/dev/null \
    && ok "pattern tag harvested into cleared_step_log[0] (FR-59 §3)" || bad "step 1's pattern tag should be recorded (got: $(_read_fragment_cleared_log "$F" 2>/dev/null))"
  grep -q 'unchecked-fragment-write-return' "$D/repo/ctl/review-prompt.2" 2>/dev/null \
    && ok "step 2 review prompt lists the prior addressed pattern (FR-59 §4)" || bad "step 2 review prompt should show the prior pattern"
) || true

echo "[C5] sentinel-less build degrades to end-of-build (no per-step reviews; cleared log stays [])"
( D="$ROOT/C5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  # build emits NO STEP_COMMIT — just commits and ends (the legacy single-shot shape).
  cat > "$D/repo/ctl/build_plan" <<'EOF'
echo "work" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "build" >/dev/null 2>&1
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/c5.log"; rc=$?
  F="$STATE_DIR/0020-fix.json"
  [ "$rc" -eq 0 ] && ok "degraded build returns 0" || bad "degraded build should return 0 (rc=$rc)"
  [ ! -f "$D/repo/ctl/review-prompt.1" ] && ok "no per-step review ran (no STEP_COMMIT)" || bad "no per-step review should run in degraded mode"
  grep -q '"cleared_step_log":\[\]' "$F" 2>/dev/null && ok "cleared_step_log stays [] in degraded mode" || bad "cleared_step_log should stay [] (got: $(_read_fragment_cleared_log "$F"))"
) || true

echo "[C6] AskUserQuestion is stripped + stream-json invocation (issue #28A)"
( D="$ROOT/C6"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  printf 'echo "BATCH_RESULT: OK"\n' > "$D/repo/ctl/build_plan"
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/c6.log" >/dev/null 2>&1
  A="$D/repo/ctl/build-argv"
  grep -q -- '--disallowed-tools AskUserQuestion' "$A" 2>/dev/null && ok "build invocation strips AskUserQuestion" || bad "build should pass --disallowed-tools AskUserQuestion (got: $(cat "$A" 2>/dev/null))"
  grep -q -- '--input-format stream-json' "$A" 2>/dev/null && ok "build invocation uses --input-format stream-json" || bad "build should use --input-format stream-json"
  grep -q -- '--output-format stream-json' "$A" 2>/dev/null && ok "build invocation uses --output-format stream-json" || bad "build should use --output-format stream-json"
) || true

echo "[C7] malformed stream-json events tolerated (§9): WARNING logged, run completes"
( D="$ROOT/C7"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
echo '{"type":"system","subtype":"init"}'
echo '{this is }{ not valid json at all'
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/c7.log"; rc=$?
  if command -v jq >/dev/null 2>&1; then
    grep -q 'WARNING: malformed stream-json event' "$D/c7.log" 2>/dev/null && ok "malformed event logged a WARNING" || bad "malformed event should log a WARNING (jq present)"
  else
    ok "malformed-warning check skipped (no jq)"
  fi
  [ "$rc" -eq 0 ] && grep -q 'BATCH_RESULT: OK' "$D/c7.log" && ok "run completes after a malformed event" || bad "run should complete past the malformed event (rc=$rc)"
) || true

echo "[C8] deadlock recovery (§8): STEP_COMMIT then stdin ignored -> inter-event timeout kills + transient"
( D="$ROOT/C8"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=2
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
echo "work" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(1): work" >/dev/null 2>&1
echo "STEP_COMMIT: 1 $(git rev-parse HEAD)"
sleep 60   # never read the STEP_REVIEW reply, never emit another event
EOF
  t0=$(date +%s)
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/c8.log"; rc=$?
  t1=$(date +%s)
  [ "$rc" -ne 0 ] && ok "deadlocked build returns non-zero" || bad "deadlock should return non-zero (rc=$rc)"
  [ $((t1 - t0)) -lt 30 ] && ok "loop gave up promptly (inter-event timeout, not a 60s hang)" || bad "loop should not hang for the full sleep"
  # cause must classify as transient (signal 143 from the kill, or a 'timed out' log marker)
  { [ "$rc" = "143" ] || grep -qiE 'timed out|hang' "$D/c8.log"; } && ok "deadlock classifies as transient (NFR-4)" || bad "deadlock should be transient-classifiable (rc=$rc)"
) || true

echo "[C9] overall watchdog (§11): steady events but no BATCH_RESULT -> killed at cap, build-overall-timeout"
( D="$ROOT/C9"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  export THROUGHLINE_BUILD_TIMEOUT=2 THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=30
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
while true; do echo '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'; sleep 0.3; done
EOF
  t0=$(date +%s)
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/c9.log"; rc=$?
  t1=$(date +%s)
  [ "$rc" -ne 0 ] && ok "watchdog-killed build returns non-zero" || bad "overall-timeout should return non-zero (rc=$rc)"
  [ $((t1 - t0)) -lt 20 ] && ok "killed near the 2s cap, not left running" || bad "build should be killed at the overall cap"
  grep -q 'build-overall-timeout' "$D/c9.log" 2>/dev/null && ok "log records build-overall-timeout" || bad "log should note build-overall-timeout (got tail: $(tail -2 "$D/c9.log" 2>/dev/null))"
  ! grep -q 'BATCH_RESULT' "$D/c9.log" 2>/dev/null && ok "no BATCH_RESULT fabricated" || bad "must not fabricate a BATCH_RESULT"
) || true

# --- §3 / Sequencing step 3: build prompt teaches the per-step protocol ----
echo "[D1] build-prompt.md instructs the author about STEP_COMMIT/STEP_REVIEW + step(<id>): commits"
( cd "$REPO"
  F="scripts/build-prompt.md"
  grep -q 'STEP_COMMIT:'              "$F" && ok "names STEP_COMMIT sentinel"          || bad "build prompt must name the STEP_COMMIT sentinel (TDD 0020 §1)"
  grep -q 'STEP_REVIEW:'              "$F" && ok "names STEP_REVIEW reply"             || bad "build prompt must describe the STEP_REVIEW reply contract"
  grep -qE 'step\([^)]*step-id'       "$F" && ok "describes step(<step-id>): commits"  || bad "build prompt must instruct the step(<step-id>): commit prefix"
  grep -qi 'block until\|wait.*STEP_REVIEW\|read.*STEP_REVIEW' "$F" && ok "tells the author to block on STEP_REVIEW" \
    || bad "build prompt must tell the author to BLOCK until STEP_REVIEW arrives (otherwise the coprocess deadlocks)"
  grep -qi 'next.*Sequencing\|next.*step' "$F" && ok "describes when to proceed to next step" \
    || bad "build prompt must describe the 'do not start next step until PASS' contract"
) || true

echo "[D2] skills/implement/SKILL.md mentions the per-step protocol so the runtime contract is discoverable"
( cd "$REPO"
  F="skills/implement/SKILL.md"
  grep -q 'STEP_COMMIT:' "$F" && ok "SKILL.md names STEP_COMMIT" || bad "SKILL.md should name the STEP_COMMIT sentinel so the runtime contract is discoverable"
) || true

# --- §step-5: consolidated final pass picks up every cleared step's tags ---
echo "[E1] consolidated review_one sees prior patterns from _per_step_review_loop's cleared_step_log writes (TDD 0020 §2 / step 5)"
( D="$ROOT/E1"; mkdir -p "$D/state.d" "$D/bin"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" RTMPL="$REPO/scripts/review-prompt.md" REVIEW_MODEL=""
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  BS="$(git rev-parse HEAD)"   # build-start (before the per-step loop commits step 1) — the consolidated review base
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  # Per-step review records a pattern tag on step 1's clear (mirrors C3+C4).
  printf 'minor: nit\npattern_tags: [step5-marker-tag]\nREVIEW_RESULT: PASS\n' > "$D/repo/ctl/review.out"
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true   # consume the runner's initial prompt (TDD 0030 §1) so the reply read stays aligned
echo "line 1" >> src/a.txt
git add -A >/dev/null 2>&1; git commit -q -m "step(1): work" >/dev/null 2>&1
echo "STEP_COMMIT: 1 $(git rev-parse HEAD)"
IFS= read -r _reply || true
echo "BATCH_RESULT: OK"
EOF
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/e1.log" >/dev/null 2>&1
  # Now run the consolidated review_one (the existing gate-4 path) with the
  # SAME fragment. It must pick up the cleared step's pattern tag.
  cat > "$D/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
printf '%s' "\$prompt" > "$D/captured-consolidated"
echo "REVIEW_RESULT: PASS"
EOF
  chmod +x "$D/bin/claude"; export PATH="$D/bin:$PATH"
  cd "$D/repo"
  review_one "$STATE_DIR/../0020-fix.md" "$BS" "$D/consolidated.log" >/dev/null 2>&1
  grep -q 'step5-marker-tag' "$D/captured-consolidated" 2>/dev/null \
    && ok "consolidated review prompt carries the per-step cleared pattern tag" \
    || bad "step 5: review_one (consolidated) should see step1's recorded pattern_tag"
) || true

# --- TDD 0024 / FR-40: structured cleared-step RESUME SIGNAL -----------------
echo "[F1] _cleared_steps_csv + {{CLEARED_STEPS}} render: none on a fresh build, CSV of cleared step_ids on resume"
( D="$ROOT/F1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }

  # Fresh build: empty cleared_step_log -> "none".
  _write_tdd_fragment 0024-fresh 24 docs/tdd/0024-fresh.md 1 building build \
    1000 1000 "feat/0024-fresh" "" "log" "" "" "" "" "" \
    "" "" "" "" "" "" "" "" "[]"
  out="$(_cleared_steps_csv 0024-fresh)"
  [ "$out" = "none" ] && ok "_cleared_steps_csv -> none for an empty cleared_step_log" \
    || bad "_cleared_steps_csv should be 'none' on empty (got '$out')"

  # Missing fragment -> "none".
  out="$(_cleared_steps_csv 0024-absent)"
  [ "$out" = "none" ] && ok "_cleared_steps_csv -> none when the fragment is missing" \
    || bad "_cleared_steps_csv should be 'none' for a missing fragment (got '$out')"

  # Resume: a populated cleared_step_log -> CSV of step_ids (deduped, in record order).
  _write_tdd_fragment 0024-resume 24 docs/tdd/0024-resume.md 1 building build \
    1000 1000 "feat/0024-resume" "" "log" "" "" "" "" "" \
    "" "" "" "" "" "" "" "ccc" \
    '[{"step_id":1,"base_sha":"a","head_sha":"b","pattern_tags":[],"cleared_at":1},{"step_id":2,"base_sha":"b","head_sha":"c","pattern_tags":[],"cleared_at":2},{"step_id":4,"base_sha":"c","head_sha":"ccc","pattern_tags":[],"cleared_at":3}]'
  out="$(_cleared_steps_csv 0024-resume)"
  [ "$out" = "1,2,4" ] && ok "_cleared_steps_csv -> CSV of cleared step_ids" \
    || bad "_cleared_steps_csv should be '1,2,4' (got '$out')"

  # The build prompt declares the placeholder. (TMPL is only set in real-run
  # mode, so reference the file path directly — as _render_build_prompt's own
  # fallback does.)
  grep -q '{{CLEARED_STEPS}}' "$REPO/scripts/build-prompt.md" \
    && ok "build-prompt.md declares the {{CLEARED_STEPS}} placeholder" \
    || bad "build-prompt.md should carry a {{CLEARED_STEPS}} placeholder"

  # Render-time substitution (the path _per_step_review_loop uses): fresh -> none.
  rendered_fresh="$(_render_build_prompt 0024-fresh docs/tdd/0024-fresh.md)"
  printf '%s' "$rendered_fresh" | grep -q '{{CLEARED_STEPS}}' \
    && bad "fresh render still contains the literal {{CLEARED_STEPS}} placeholder" \
    || ok "fresh render substitutes the placeholder"
  printf '%s' "$rendered_fresh" | grep -qE 'Cleared steps from any prior attempt: none' \
    && ok "fresh render shows 'none'" \
    || bad "fresh render should show the RESUME SIGNAL bullet with 'none'"

  # Render-time substitution: resume -> the CSV.
  rendered_resume="$(_render_build_prompt 0024-resume docs/tdd/0024-resume.md)"
  printf '%s' "$rendered_resume" | grep -qE 'Cleared steps from any prior attempt: 1,2,4' \
    && ok "resume render shows the cleared step CSV (1,2,4)" \
    || bad "resume render should show 'Cleared steps from any prior attempt: 1,2,4'"
  # The {{TDD}} placeholder is still substituted alongside (no regression).
  printf '%s' "$rendered_resume" | grep -q 'docs/tdd/0024-resume.md' \
    && ok "render still substitutes {{TDD}} alongside {{CLEARED_STEPS}}" \
    || bad "render must still substitute {{TDD}}"
) || true

# --- §rerun-1 review finding MAJOR-1: _per_step_review_loop must fail loud
#     when _render_build_prompt fails. Without this, a missing template
#     produces an empty prompt + claude -p invocation + no BATCH_RESULT +
#     misleading FAIL with no error trail in the gate log (NFR-4 honesty).
echo "[F2] _per_step_review_loop fails loud (rc≠0, log diagnostic) when _render_build_prompt fails"
( D="$ROOT/F2"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  # Point TMPL at a path that doesn't exist so _render_build_prompt fails
  # at the existence check (rc=1, stderr diagnostic).
  export TMPL="$D/nonexistent-build-prompt.md"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0024-fix 24 docs/tdd/0024-fix.md 1 building build 1000 1000 "feat/0024-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  _per_step_review_loop 0024-fix docs/tdd/0024-fix.md "$D/f2.log" 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] && ok "_per_step_review_loop returns non-zero when the build prompt cannot render" \
    || bad "_per_step_review_loop must NOT proceed with an empty prompt (rc=$rc)"
  # The gate log MUST carry the rendering-failure diagnostic — runner bash
  # stderr goes to nohup.out, but a triage reading the per-TDD log needs
  # the cause IN-BAND. (Reviewer's MAJOR-1 specifically.)
  grep -qiE 'render.*build.*prompt|build.*prompt.*render|template.*not.*found' "$D/f2.log" 2>/dev/null \
    && ok "gate log carries the rendering-failure diagnostic" \
    || bad "gate log should name the rendering failure so a triage reading the durable artifact can see it"
  ! grep -q 'BATCH_RESULT' "$D/f2.log" 2>/dev/null \
    && ok "no fabricated BATCH_RESULT — gate fails honestly" \
    || bad "must not fabricate BATCH_RESULT when the prompt failed to render"
) || true

# --- §rerun-1 robustness: the rework-loop's verdict-detection regex must
#     match a REVIEW_RESULT line wrapped in markdown backticks. The reviewer
#     on this branch's prior pass emitted the verdict as
#     `REVIEW_RESULT: BLOCK ...` (single inline-code backticks), which the
#     strict `^REVIEW_RESULT:` anchor missed — the runner then classified
#     the BLOCK verdict as "no fresh verdict (rc=1)" and skipped the bounded
#     rework loop entirely. NFR-4: a real verdict must never be silently
#     discarded just because the reviewer styled it as markdown code.
echo "[F3] _fresh_review_verdict helper extracts a backtick-wrapped REVIEW_RESULT verdict (review-rerun-1)"
( D="$ROOT/F3"; mkdir -p "$D"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # Reproduces what the reviewer emitted on 0024 review-rerun-1: a single-
  # backtick markdown-inline verdict. The strict `^REVIEW_RESULT:` anchor on
  # _rework_loop's verdict-detection missed it → fatal-classified instead of
  # rework-triggering. NFR-4: a real verdict must never be silently discarded.
  cat > "$D/slice.log" <<'EOF'
some prose before the verdict
`REVIEW_RESULT: BLOCK MAJOR-1 (...) and MAJOR-2 (...)`
some prose after
EOF
  if ! command -v _fresh_review_verdict >/dev/null 2>&1; then
    bad "_fresh_review_verdict helper missing (extract it from _rework_loop so verdict-detection is testable)"
  else
    verdict="$(_fresh_review_verdict "$D/slice.log" 0)"
    [ -n "$verdict" ] && ok "_fresh_review_verdict matches a backtick-wrapped REVIEW_RESULT line" \
      || bad "_fresh_review_verdict must match \`REVIEW_RESULT: ...\` (got empty)"
    rs="$(review_status "$D/slice.log")"
    case "$rs" in *BLOCK*) ok "review_status extracts BLOCK downstream from a backticked verdict" ;;
                  *)       bad "review_status should still see BLOCK (got '$rs')" ;;
    esac
  fi
) || true

# --- TDD 0053 / A15: the protocol-error correction path must COMMIT the elapsed
# streaming interval into build_active_seconds BEFORE resetting interval_start
# (the review-verdict and test-first paths already do). Otherwise the active-time
# watchdog under-counts and a misbehaving build runs past its active-seconds
# budget (FR-57). Observable surface: the watchdog kill (build-overall-timeout).
# Timing-based, mirroring the existing [C9] overall-watchdog test: overall_active
# is 6s; the build streams ~4s, hits a malformed STEP_COMMIT (the protocol-error
# reset), then streams another ~4s. Pre-fix the first interval is dropped so the
# accumulated active time stays ~4s (< 6s) and the build reaches BATCH_RESULT;
# post-fix the committed 4s + the second ~4s exceeds 6s and the watchdog kills it.
echo "[G1] A15: a malformed STEP_COMMIT does not drop the elapsed active interval (watchdog accounting not under-counted)"
( D="$ROOT/G1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  export THROUGHLINE_BUILD_TIMEOUT=6 THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=20
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true   # consume the runner's initial prompt (TDD 0030 §1)
sleep 4                      # active interval #1 (~4s) BEFORE the protocol error
echo "STEP_COMMIT: notaninteger badsha"   # malformed: no integer step-id → protocol-error correction path
IFS= read -r _reply || true  # the protocol-error BLOCK reply (interval_start reset here)
sleep 4                      # active interval #2 (~4s)
echo "BATCH_RESULT: OK"
EOF
  t0=$(date +%s)
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/g1.log"; rc=$?
  t1=$(date +%s)
  [ "$rc" -ne 0 ] && ok "build killed by the active-time watchdog (interval #1 was accounted)" \
    || bad "pre-reset interval must be committed so the watchdog fires (rc=$rc)"
  grep -q 'build-overall-timeout' "$D/g1.log" 2>/dev/null \
    && ok "log records build-overall-timeout (active budget exceeded)" \
    || bad "log should note build-overall-timeout (got tail: $(tail -2 "$D/g1.log" 2>/dev/null))"
  ! grep -q 'BATCH_RESULT' "$D/g1.log" 2>/dev/null \
    && ok "build did not reach BATCH_RESULT (under-counting would have let it finish)" \
    || bad "build should have been killed before BATCH_RESULT (under-counted active time)"
  [ $((t1 - t0)) -lt 18 ] && ok "killed near the active cap, not left to the inter-event timeout" \
    || bad "build should be killed at the active cap, not hang"
) || true

# --- TDD 0053 / A16: a terminal BATCH_RESULT carried in a TOOL-USE block yields
# empty assistant text (the sentinel sits in the model's tool-call JSON, not its
# spoken content). The stdin-close lifecycle must still run — the verdict is
# parsed from the mirrored raw log regardless — so a finished build does not hang
# to the inter-event timeout → a spurious transient pause (NFR-4, FR-57). The bug
# only manifests when _extract_event_text can parse JSON (jq present); without jq
# the raw line is returned and the normal BATCH_RESULT arm already fires.
echo "[G2] A16: an empty-text (tool-use-carried) BATCH_RESULT closes the build instead of hanging"
( D="$ROOT/G2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  export THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT=8
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  if ! command -v jq >/dev/null 2>&1; then ok "A16 hang-repro needs jq to empty the text (skipped without jq)"; exit 0; fi
  setup_step_repo "$D/repo" || { bad "setup failed"; exit 0; }
  _write_tdd_fragment 0020-fix 20 docs/tdd/0020-fix.md 1 building build 1000 1000 "feat/0020-fix" "" log "" "" "" "" "" "" "" "" "" "" "" ""
  cat > "$D/repo/ctl/build_plan" <<'EOF'
IFS= read -r _init || true
# BATCH_RESULT carried INSIDE a tool_use block: _extract_event_text yields empty
# assistant text, but the raw event line still contains "BATCH_RESULT: ". Pre-fix
# the empty-text inner case fell through with no stdin-close lifecycle, so the
# build hung on the next stdin read until the inter-event watchdog killed it.
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"BATCH_RESULT: OK"}}]}}'
IFS= read -r _next || true   # blocks for the next user turn; the loop's stdin close → EOF → returns → build exits
EOF
  t0=$(date +%s)
  _per_step_review_loop 0020-fix docs/tdd/0020-fix.md "$D/g2.log"; rc=$?
  t1=$(date +%s)
  [ "$rc" -eq 0 ] && ok "build exits cleanly via stdin EOF (rc=0), not a transient kill" \
    || bad "empty-text BATCH_RESULT must close the build, not hang to a transient kill (rc=$rc)"
  [ $((t1 - t0)) -lt 6 ] && ok "completed promptly (did not hang to the inter-event timeout)" \
    || bad "build hung instead of closing on the empty-text BATCH_RESULT (took $((t1 - t0))s)"
  grep -q 'BATCH_RESULT' "$D/g2.log" 2>/dev/null && ok "the BATCH_RESULT event was mirrored to the log" \
    || bad "the BATCH_RESULT event should be mirrored to the log"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== continuous-in-build-review eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

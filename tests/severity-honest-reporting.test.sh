#!/usr/bin/env bash
# severity-honest-reporting.test.sh — eval for TDD 0021 (severity taxonomy +
# honest reporting / diff-vs-narrative + author self-review + per-file coverage).
#
# PRD refs: FR-58, FR-60, FR-70, FR-71 (+ issues #35, #28A, #28B).
#
# The contract under test (function-level; the runtime-verify gate re-drives the
# same observable surface against a real /implement run):
#   §6 — the per-TDD fragment gains findings (array), self_review_count (int),
#        re_review_attempts (object), threaded through _write_tdd_fragment and
#        carried forward by every fragment writer; run.json gains
#        config.re_review_config.
#   §1/§4/§3/§3b — review-prompt.md carries the FINDING_BEGIN..END schema, the
#        severity definitions, the FR-70 grounding clause, the FR-71 diff-vs-
#        narrative check, and the per-file disposition requirement.
#   §3 — _diff_vs_narrative_facts extracts the BATCH_RESULT narrative + git facts.
#   §2/§4 — the runner parses FINDING_BEGIN..END blocks onto findings[], drives
#        the halt boundary from the {blocker,major} subset, and synthesizes the
#        §2 meta-findings.
#   §5/§5b — build-prompt.md + skills/implement/SKILL.md carry the SELF_REVIEW
#        block, the AskUserQuestion prohibition, and the --no-verify escape.
#   §3c — _per_file_coverage_check rejects an incomplete review pass and routes
#        through the re_review_attempts branch.
#   §6/item6 — the BATCH_RESULT SELF_REVIEW block is parsed onto findings[] with
#        source:self-review and increments self_review_count.
#
# Run: bash tests/severity-honest-reporting.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# A complete finding object literal in the §6 shape, used across scenarios.
FIND1='{"source":"review","pass_id":"review-1:1","severity":"major","structural":false,"region":"src/a.txt:1-9","region_lines":8,"pattern_tags":["bug"],"summary":"real bug","evidence":"the line","addressed_at":null,"addressed_by_sha":null}'

# --- §6 / Data: findings / self_review_count / re_review_attempts -------------
echo "[S1] _write_tdd_fragment writes findings / self_review_count / re_review_attempts (params 26-28)"
( D="$ROOT/S1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0021-x 21 docs/tdd/0021-x.md 1 reviewing review \
    1000 1000 "feat/0021-x" "" "log" "" "" "" "" "" \
    "" "" "" "" \
    "" "" "" \
    "" "" \
    "[$FIND1]" 2 '{"review:1":1}'
  F="$D/state.d/0021-x.json"
  grep -q '"findings":\['         "$F" 2>/dev/null && ok "findings array present" || bad "findings should be present (got: $(cat "$F"))"
  grep -q '"self_review_count":2' "$F" 2>/dev/null && ok "self_review_count round-trips" || bad "self_review_count should be 2"
  grep -q '"re_review_attempts":{"review:1":1}' "$F" 2>/dev/null && ok "re_review_attempts round-trips" || bad "re_review_attempts should round-trip"
  # cleared_step_log must stay the LAST field (greedy-reader invariant).
  grep -qE '"cleared_step_log":\[\]}[[:space:]]*$' "$F" 2>/dev/null && ok "cleared_step_log stays last" || bad "cleared_step_log must remain the last field"
) || true

echo "[S2] _write_tdd_fragment defaults findings/self_review_count/re_review_attempts when absent (16-arg call)"
( D="$ROOT/S2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0001-a 1 docs/tdd/0001-a.md 1 pending "" \
    1000 1000 "" "" "" "" "" "" "" ""
  F="$D/state.d/0001-a.json"
  grep -q '"findings":\[\]'          "$F" 2>/dev/null && ok "findings defaults to []" || bad "findings should default to [] (got: $(cat "$F"))"
  grep -q '"self_review_count":0'    "$F" 2>/dev/null && ok "self_review_count defaults to 0" || bad "self_review_count should default to 0"
  grep -q '"re_review_attempts":{}'  "$F" 2>/dev/null && ok "re_review_attempts defaults to {}" || bad "re_review_attempts should default to {}"
) || true

echo "[S3] _read_fragment_findings reads the nested findings array back"
( D="$ROOT/S3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0021-x 21 docs/tdd/0021-x.md 1 reviewing review \
    1000 1000 "feat/0021-x" "" "log" "" "" "" "" "" \
    "" "" "" "" "" "" "" "" "" \
    "[$FIND1]" 0 '{}'
  F="$D/state.d/0021-x.json"
  got="$(_read_fragment_findings "$F")"
  case "$got" in
    "[$FIND1]") ok "_read_fragment_findings round-trips the nested array" ;;
    *) bad "_read_fragment_findings should return the findings array (got: $got)" ;;
  esac
) || true

echo "[S4] _record_finding appends an entry; carry-forward preserves prior findings"
( D="$ROOT/S4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0021-x 21 docs/tdd/0021-x.md 1 reviewing review 1000 1000 "" "" "" ""
  F="$D/state.d/0021-x.json"
  _record_finding 0021-x review "review-1:1" major false "src/a.txt:1-9" 8 "bug" "real bug" "the line" \
    || bad "_record_finding (1) should succeed"
  _record_finding 0021-x self-review "self:1" minor false "src/b.txt:2-2" 1 "nit,style" "small nit" "another line" \
    || bad "_record_finding (2) should succeed"
  n="$(grep -o '"source":' "$F" | wc -l | tr -d ' ')"
  [ "$n" = "2" ] && ok "two findings recorded" || bad "expected 2 findings (got $n) in $(cat "$F")"
  grep -q '"source":"review".*"severity":"major"' "$F" 2>/dev/null && ok "review finding carries severity major" || bad "first finding should be review/major"
  grep -q '"source":"self-review"' "$F" 2>/dev/null && ok "self-review finding recorded" || bad "second finding should be self-review"
  # carry-forward: a status transition must not wipe findings.
  set_tdd_state 0021-x done flip "transition"
  m="$(grep -o '"source":' "$F" | wc -l | tr -d ' ')"
  [ "$m" = "2" ] && ok "findings survive set_tdd_state" || bad "findings should survive a status transition (got $m)"
) || true

echo "[S5] _re_review_attempt_count increments + _re_review_attempt_count_peek reads"
( D="$ROOT/S5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0021-x 21 docs/tdd/0021-x.md 1 reviewing review 1000 1000 "" "" "" ""
  [ "$(_re_review_attempt_count_peek 0021-x review 1)" = "0" ] && ok "peek starts at 0" || bad "peek should start at 0"
  v1="$(_re_review_attempt_count 0021-x review 1)"
  [ "$v1" = "1" ] && ok "first increment -> 1" || bad "first increment should echo 1 (got $v1)"
  v2="$(_re_review_attempt_count 0021-x review 1)"
  [ "$v2" = "2" ] && ok "second increment -> 2" || bad "second increment should echo 2 (got $v2)"
  [ "$(_re_review_attempt_count_peek 0021-x review 1)" = "2" ] && ok "peek reads persisted 2" || bad "peek should read 2"
  grep -q '"re_review_attempts":{"review:1":2}' "$D/state.d/0021-x.json" 2>/dev/null \
    && ok "counter persisted in fragment" || bad "re_review_attempts should persist {\"review:1\":2}"
) || true

echo "[S6] _incr_self_review_count increments the fragment counter"
( D="$ROOT/S6"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0021-x 21 docs/tdd/0021-x.md 1 reviewing review 1000 1000 "" "" "" ""
  _incr_self_review_count 0021-x 2 || bad "_incr_self_review_count should succeed"
  grep -q '"self_review_count":2' "$D/state.d/0021-x.json" 2>/dev/null && ok "self_review_count incremented to 2" || bad "self_review_count should be 2"
  _incr_self_review_count 0021-x || bad "_incr_self_review_count default delta should succeed"
  grep -q '"self_review_count":3' "$D/state.d/0021-x.json" 2>/dev/null && ok "default delta of 1 -> 3" || bad "self_review_count should be 3"
) || true

echo "[S7] _re_review_config_json emits THROUGHLINE_RE_REVIEW_MAX (default 2; override honored)"
( D="$ROOT/S7"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  out="$(_re_review_config_json)"
  printf '%s' "$out" | grep -q '"max":2' && ok "default re_review max=2" || bad "default re_review max should be 2 (got: $out)"
  out2="$(THROUGHLINE_RE_REVIEW_MAX=5 _re_review_config_json)"
  printf '%s' "$out2" | grep -q '"max":5' && ok "re_review max override honored" || bad "re_review max override should be 5 (got: $out2)"
) || true

echo "[S8] _write_run_fragment embeds config.re_review_config in run.json"
( D="$ROOT/S8"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_run_fragment running
  R="$D/state.d/run.json"
  grep -q '"re_review_config":{' "$R" 2>/dev/null && ok "run.json carries config.re_review_config" || bad "run.json should carry config.re_review_config (got: $(cat "$R"))"
  grep -q '"rework_config":{' "$R" 2>/dev/null && ok "rework_config still present (back-compat)" || bad "run.json must still carry rework_config"
) || true

echo "[S9] _record_finding fails loud (no silent ledger loss) on a malformed findings array"
( D="$ROOT/S9"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0021-x 21 docs/tdd/0021-x.md 1 reviewing review 1000 1000 "" "" "" ""
  F="$D/state.d/0021-x.json"
  # Corrupt the findings array (truncate its closing bracket) to simulate a
  # malformed ledger; _record_finding must refuse rather than reset/discard.
  perl -0pi -e 's/"findings":\[\]/"findings":[{"source":"review"/' "$F" 2>/dev/null \
    || sed -i 's/"findings":\[\]/"findings":[{"source":"review"/' "$F"
  if _record_finding 0021-x review "review-1:1" major false "src/a.txt:1-9" 8 "bug" "s" "e" 2>/dev/null; then
    bad "_record_finding should FAIL on a malformed findings array (fail-loud, no silent reset)"
  else
    ok "_record_finding refuses to write on a malformed ledger"
  fi
) || true

echo "[S10] re-review counters reject gate/step with regex metacharacters (no sed/grep injection)"
( D="$ROOT/S10"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0021-x 21 docs/tdd/0021-x.md 1 reviewing review 1000 1000 "" "" "" ""
  _re_review_attempt_count 0021-x 're.*[/' 1 2>/dev/null && bad "increment must reject a gate with metacharacters" || ok "_re_review_attempt_count rejects metacharacter gate"
  _re_review_attempt_count 0021-x review 'x9' 2>/dev/null && bad "increment must reject a non-numeric step" || ok "_re_review_attempt_count rejects non-numeric step"
  _re_review_attempt_count_peek 0021-x 're/d' 1 >/dev/null 2>&1 && bad "peek must reject a metacharacter gate" || ok "_re_review_attempt_count_peek rejects metacharacter gate"
  # The valid form still works after the guards.
  v="$(_re_review_attempt_count 0021-x review 1)"
  [ "$v" = "1" ] && ok "valid gate/step still increments" || bad "valid gate/step should still work (got $v)"
) || true

# --- §1/§4/§3: review-prompt.md finding schema + grounding + diff-vs-narrative -
echo "[P1] review-prompt.md carries the §1 FINDING_BEGIN..END finding schema"
( cd "$REPO"; F="scripts/review-prompt.md"
  grep -q 'FINDING_BEGIN'              "$F" && ok "has FINDING_BEGIN"  || bad "review prompt needs the FINDING_BEGIN block opener (§1)"
  grep -q 'FINDING_END'                "$F" && ok "has FINDING_END"    || bad "review prompt needs the FINDING_END block closer (§1)"
  grep -qE 'severity:.*blocker.*major.*minor.*nit' "$F" && ok "lists the four severities in the block" || bad "FINDING block needs the severity field listing blocker|major|minor|nit"
  grep -q 'structural:'                "$F" && ok "has structural field"   || bad "FINDING block needs a structural: field (FR-67c)"
  grep -q 'region_lines'               "$F" && ok "has region_lines field" || bad "FINDING block needs region_lines (FR-66 scope cap)"
  grep -q 'evidence:'                  "$F" && ok "has evidence field"      || bad "FINDING block needs an evidence: field"
  # [B1] strings must survive the rewrite.
  grep -qi 'pattern_tags'              "$F" && ok "pattern_tags preserved"  || bad "review prompt must keep pattern_tags emission"
  grep -qi 'recurrent-pattern'         "$F" && ok "recurrent-pattern preserved" || bad "review prompt must keep recurrent-pattern instruction"
) || true

echo "[P2] review-prompt.md defines the severities and names blocker+major as halting"
( cd "$REPO"; F="scripts/review-prompt.md"
  grep -qiE 'blocker.*(unsafe to ship|incorrect behavior|regression|security)' "$F" && ok "defines blocker" || bad "review prompt needs a blocker definition"
  grep -qiE 'major.*(meaningful flaw|materially|discrepancy)' "$F" && ok "defines major" || bad "review prompt needs a major definition"
  grep -qiE 'minor.*(does not block|quality concern)' "$F" && ok "defines minor (non-halting)" || bad "review prompt needs a minor definition"
  grep -qiE 'nit.*(style|polish|does not halt)' "$F" && ok "defines nit (non-halting)" || bad "review prompt needs a nit definition"
  grep -qiE 'blocker.*(and|/).*major.*(halt|halting)|halting.*blocker.*major' "$F" && ok "names blocker+major the halting set" || bad "review prompt must state blocker+major are the halting severities (FR-58)"
) || true

echo "[P3] review-prompt.md carries the §4 four-artifact grounding clause"
( cd "$REPO"; F="scripts/review-prompt.md"
  grep -q 'git log'             "$F" && ok "names git log artifact"  || bad "grounding clause needs git log (§4 artifact 2)"
  grep -qi 'run-state record'   "$F" && ok "names run-state record"  || bad "grounding clause needs the run-state record (§4 artifact 4)"
  grep -q 'evidence-not-grounded' "$F" && ok "names evidence-not-grounded meta-finding" || bad "grounding clause needs the evidence-not-grounded meta-finding tag (§4)"
) || true

echo "[P4] review-prompt.md carries the §3 diff-vs-narrative honesty check (FR-71)"
( cd "$REPO"; F="scripts/review-prompt.md"
  grep -qi 'diff vs narrative\|diff-vs-narrative' "$F" && ok "has the diff-vs-narrative check heading" || bad "review prompt needs the §3 diff-vs-narrative check (FR-71)"
  grep -q 'BATCH_RESULT'        "$F" && ok "references the BATCH_RESULT narrative" || bad "§3 check must read the build's BATCH_RESULT narrative"
  grep -q -- '--name-only'      "$F" && ok "cross-checks git diff --name-only" || bad "§3 check must cross-check git diff --name-only"
  grep -q 'narrative-discrepancy' "$F" && ok "emits narrative-discrepancy pattern_tag" || bad "§3 discrepancy must be a major finding tagged narrative-discrepancy"
) || true

# --- §3: _diff_vs_narrative_facts helper + interpolation wiring ---------------
echo "[D1] _diff_vs_narrative_facts surfaces the BATCH_RESULT line + git --name-only ground truth"
( D="$ROOT/D1/repo"; mkdir -p "$D"
  export STATE_DIR="$ROOT/D1/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$ROOT/D1"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  cd "$D"; git init -q; git config user.email t@t.t; git config user.name t
  printf 'base\n' > seed.txt; git add -A; git commit -qm base; BASE="$(git rev-parse HEAD)"
  for fn in a b c d e; do printf 'x\n' > "src_$fn.txt"; done
  git add -A; git commit -qm work
  L="$ROOT/D1/build.log"
  printf 'Implemented the change.\nI touched two files: src_a.txt and src_b.txt.\nBATCH_RESULT: OK\n' > "$L"
  out="$(_diff_vs_narrative_facts "$L" "$BASE")"
  printf '%s' "$out" | grep -q 'BATCH_RESULT: OK' && ok "surfaces the BATCH_RESULT verdict line" || bad "facts block must carry the BATCH_RESULT line (got: $out)"
  printf '%s' "$out" | grep -q 'src_e.txt' && ok "surfaces git --name-only ground truth (all 5 files)" || bad "facts block must list the git-touched files (got: $out)"
  printf '%s' "$out" | grep -qE 'git-touched-file-count: *5' && ok "reports the git-derived file count (5, not the narrative's 2)" || bad "facts block must report the git file count (got: $out)"
  printf '%s' "$out" | grep -q 'src_a.txt and src_b.txt' && ok "surfaces the author narrative for comparison" || bad "facts block should carry the narrative region (got: $out)"
) || true

echo "[D2] _diff_vs_narrative_facts reports narrative-missing when the log has no BATCH_RESULT"
( D="$ROOT/D2/repo"; mkdir -p "$D"
  export STATE_DIR="$ROOT/D2/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$ROOT/D2"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  cd "$D"; git init -q; git config user.email t@t.t; git config user.name t
  printf 'base\n' > seed.txt; git add -A; git commit -qm base; BASE="$(git rev-parse HEAD)"
  L="$ROOT/D2/build.log"; printf 'some build output with no terminal sentinel\n' > "$L"
  out="$(_diff_vs_narrative_facts "$L" "$BASE")"
  printf '%s' "$out" | grep -q 'narrative-missing' && ok "reports narrative-missing (§Failure modes)" || bad "no-BATCH_RESULT log must report narrative-missing (got: $out)"
) || true

echo "[D3] _render_review_prompt substitutes {{DIFF_VS_NARRATIVE_FACTS}} (6th arg) and never leaks it"
( D="$ROOT/D3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D" RTMPL="$REPO/scripts/review-prompt.md"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  out="$(_render_review_prompt docs/tdd/0021-x.md base999 head888 "build/ci/0021-x" "tag-a" "MY_FACTS_BLOCK_MARKER")"
  printf '%s' "$out" | grep -q 'MY_FACTS_BLOCK_MARKER' && ok "facts block substituted into the prompt" || bad "6th-arg facts should substitute {{DIFF_VS_NARRATIVE_FACTS}}"
  printf '%s' "$out" | grep -q '{{DIFF_VS_NARRATIVE_FACTS}}' && bad "raw {{DIFF_VS_NARRATIVE_FACTS}} leaked" || ok "no raw facts placeholder leaks (with facts)"
  # Empty 6th arg (per-step pass) must still leave no raw placeholder.
  out2="$(_render_review_prompt docs/tdd/0021-x.md base999 head888 "br" "")"
  printf '%s' "$out2" | grep -q '{{DIFF_VS_NARRATIVE_FACTS}}' && bad "raw placeholder leaked when facts empty" || ok "no raw placeholder leaks when facts empty"
) || true

echo "[D4] review-prompt.md carries the {{DIFF_VS_NARRATIVE_FACTS}} interpolation point"
( cd "$REPO"; F="scripts/review-prompt.md"
  grep -q '{{DIFF_VS_NARRATIVE_FACTS}}' "$F" && ok "review prompt has the facts interpolation point" || bad "review prompt needs the {{DIFF_VS_NARRATIVE_FACTS}} placeholder (§3 wiring)"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== severity-honest-reporting eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

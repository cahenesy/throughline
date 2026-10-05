#!/usr/bin/env bash
# model-roles.test.sh — eval for TDD 0064 / NFR-3, FR-52, FR-87, FR-10,
# FR-15(d), FR-50: EXECUTES every scripts/lib/models.sh function in a clean
# `env -i HOME=<tmp> PATH="$PATH" bash -c '. models.sh; …'` shell against
# fixture TDDs, Claude transcripts and a Grok summary.json (no network), and
# pins the fresh-worker independence wording (design-reviewer, /tdd-author 7b,
# plugin.json). Observation numbers [1]–[15] are the TDD's Verification plan.
#
# Written red-first. Run: bash tests/model-roles.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="$REPO/scripts/lib/models.sh"
DR="$REPO/agents/design-reviewer.md"
TA="$REPO/skills/tdd-author/SKILL.md"
PJ="$REPO/.claude-plugin/plugin.json"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$RESULTS"' EXIT
H="$ROOT/home"; mkdir -p "$H"
q() { printf '%q' "$1"; }

# m [VAR=val ...] '<cmds>' — source models.sh then run <cmds> in a CLEAN shell
# (env -i: no caller variable or function leaks in). A later PATH=/HOME= in the
# VAR list overrides the default. Sets OUT, ERR, RC, NL (stdout line count).
m() {
  local cmd="${!#}"
  local -a envs=("${@:1:$#-1}")
  env -i HOME="$H" PATH="$PATH" ${envs[@]+"${envs[@]}"} \
    bash -c ". $(q "$MODELS") || exit 97; $cmd" >"$ROOT/out" 2>"$ROOT/err"
  RC=$?
  OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
  NL="$(wc -l <"$ROOT/out" | tr -d ' ')"
}
# eq <label> <want> — rc 0 and stdout is exactly one line equal to <want>.
eq() {
  if [ "$RC" -eq 0 ] && [ "$NL" = 1 ] && [ "$OUT" = "$2" ]; then ok "$1 → $2"
  else bad "$1: rc=$RC lines=$NL out='$OUT' want '$2' (err: $ERR)"; fi
}
# unreadable <label> <reason|-> — rc 1, no stdout, one stderr line
# `tl_parent_model: …` containing <reason> (- = any reason).
unreadable() {
  if [ "$RC" -eq 1 ] && [ -z "$OUT" ] && [ "$(printf '%s\n' "$ERR" | grep -c .)" = 1 ] \
     && printf '%s' "$ERR" | grep -q '^tl_parent_model: ' \
     && { [ "$2" = - ] || printf '%s' "$ERR" | grep -qF "$2"; }; then
    ok "$1 → rc 1 ($ERR)"
  else bad "$1: rc=$RC out='$OUT' err='$ERR' want rc 1 + '$2'"; fi
}

MECH="$ROOT/mech.md"; NONT="$ROOT/nontrivial.md"
printf '# TDD 9001: fixture\n\n## Verification plan\n- Run `tool --check`; exit code 0 and stdout has `ok`.\n\n## Touched files\n' >"$MECH"
printf '# TDD 9002: fixture\n\n## Verification plan\n- Drive the browser UI with playwright and take a screenshot.\n\n## Touched files\n' >"$NONT"

echo "[0] models.sh sources cleanly and binds the function table"
( bash -n "$MODELS" 2>"$ROOT/n.err" && ok "models.sh parses (bash -n)" \
    || bad "models.sh bash -n failed: $(cat "$ROOT/n.err" 2>/dev/null)"
  m 'for f in tl_model_harness tl_light_model tl_escalation_model tl_model_family tl_model_tier tl_parent_model tl_parent_effort tl_plan_class tl_resolve_models tl_model_sources _tl_resolve_slot; do [ "$(type -t "$f")" = function ] || echo "missing $f"; done'
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && ok "all functions defined; source is silent" \
    || bad "rc=$RC out='$OUT' err='$ERR'"
  mkdir -p "$ROOT/lone"; cp "$MODELS" "$ROOT/lone/models.sh"
  env -i HOME="$H" PATH="$PATH" bash -c ". $(q "$ROOT/lone/models.sh")" >/dev/null 2>"$ROOT/lone.err"; rc=$?
  [ "$rc" -ne 0 ] && grep -q 'FATAL' "$ROOT/lone.err" && ok "missing plan-classifier.sh → FATAL, rc≠0" \
    || bad "lone models.sh rc=$rc err=$(cat "$ROOT/lone.err")"
  m 'tl_model_harness'; eq "tl_model_harness (claude)" claude
  m GROK_PLUGIN_ROOT=/tmp 'tl_model_harness'; eq "tl_model_harness (GROK_PLUGIN_ROOT set)" grok
  m "tl_plan_class $(q "$MECH")"; eq "tl_plan_class mechanical fixture" mechanical
  m "tl_plan_class $(q "$NONT")"; eq "tl_plan_class nontrivial fixture" nontrivial
  m 'tl_plan_class'; eq "tl_plan_class no path" nontrivial
  m "tl_plan_class $(q "$ROOT/absent.md")"; eq "tl_plan_class missing file (classifier rc≠0)" nontrivial
) || true

echo "[1] no pins, Claude, no tdd-path → everything inherits the parent"
( m 'tl_resolve_models'; eq "[1] tl_resolve_models" "build=inherit review=inherit verify=inherit"
  m 'tl_model_sources'; eq "[1] tl_model_sources" "build_src=parent review_src=parent verify_src=parent"
  m "tl_resolve_models $(q "$MECH") ''"; eq "[1] mechanical + empty parent" "build=inherit review=inherit verify=inherit"
  m "tl_model_sources $(q "$MECH") ''"; eq "[1] mechanical + empty parent sources" "build_src=parent review_src=parent verify_src=parent-cap"
) || true

echo "[2]-[4] runtime-verify tier: light only below an above-light parent"
( m "tl_resolve_models $(q "$MECH") claude-opus-5-5"; eq "[2] mechanical + opus parent" "build=inherit review=inherit verify=sonnet"
  m "tl_model_sources $(q "$MECH") claude-opus-5-5"; eq "[2] sources" "build_src=parent review_src=parent verify_src=light"
  for p in claude-sonnet-5-5 claude-haiku-4-5; do
    m "tl_resolve_models $(q "$MECH") $p"; eq "[3] mechanical + $p" "build=inherit review=inherit verify=inherit"
    m "tl_model_sources $(q "$MECH") $p"; eq "[3] sources ($p)" "build_src=parent review_src=parent verify_src=parent-cap"
  done
  m "tl_resolve_models $(q "$NONT") claude-opus-5-5"; eq "[4] nontrivial + opus" "build=inherit review=inherit verify=inherit"
  m "tl_model_sources $(q "$NONT") claude-opus-5-5"; eq "[4] sources" "build_src=parent review_src=parent verify_src=parent"
) || true

echo "[5]-[6] pins win; CLAUDE_CODE_SUBAGENT_MODEL is a Claude-only pin"
( m THROUGHLINE_REVIEW_MODEL=sonnet 'tl_resolve_models'; eq "[5] review pin" "build=inherit review=sonnet verify=inherit"
  m THROUGHLINE_REVIEW_MODEL=sonnet 'tl_model_sources'; eq "[5] review pin sources" "build_src=parent review_src=pin:THROUGHLINE_REVIEW_MODEL verify_src=parent"
  m CLAUDE_CODE_SUBAGENT_MODEL=haiku 'tl_resolve_models'; eq "[6] subagent env" "build=haiku review=haiku verify=haiku"
  m CLAUDE_CODE_SUBAGENT_MODEL=haiku 'tl_model_sources'; eq "[6] subagent env sources" "build_src=pin:CLAUDE_CODE_SUBAGENT_MODEL review_src=pin:CLAUDE_CODE_SUBAGENT_MODEL verify_src=pin:CLAUDE_CODE_SUBAGENT_MODEL"
  m CLAUDE_CODE_SUBAGENT_MODEL=haiku GROK_PLUGIN_ROOT=/tmp 'tl_resolve_models'; eq "[6] Grok ignores subagent env" "build=inherit review=inherit verify=inherit"
  m THROUGHLINE_BUILD_MODEL=opus CLAUDE_CODE_SUBAGENT_MODEL=haiku 'tl_model_sources'
  eq "build pin beats subagent env" "build_src=pin:THROUGHLINE_BUILD_MODEL review_src=pin:CLAUDE_CODE_SUBAGENT_MODEL verify_src=pin:THROUGHLINE_BUILD_MODEL"
  m THROUGHLINE_RUNTIME_VERIFY_MODEL=opus "tl_resolve_models $(q "$MECH") claude-opus-5-5"; eq "verify pin beats light" "build=inherit review=inherit verify=opus"
  m THROUGHLINE_RUNTIME_VERIFY_MODEL=opus "tl_model_sources $(q "$MECH") claude-opus-5-5"; eq "verify pin source" "build_src=parent review_src=parent verify_src=pin:THROUGHLINE_RUNTIME_VERIFY_MODEL"
) || true

echo "[7]-[8] family / tier / light / escalation bindings"
( for pair in claude-sonnet-5-5:light claude-haiku-4-5:light claude-opus-5-5:above claude-fable-5-1:above claude-newname-1:above; do
    m "tl_model_tier ${pair%%:*}"; eq "[7] tier ${pair%%:*}" "${pair#*:}"
  done
  m "tl_model_tier ''"; eq "[7] tier empty" unknown
  m GROK_PLUGIN_ROOT=/tmp 'tl_model_tier grok-4.5'; eq "[7] Grok tier grok-4.5" light
  m GROK_PLUGIN_ROOT=/tmp 'tl_model_tier grok-4.6'; eq "[7] Grok tier grok-4.6" above
  m 'tl_model_family Claude-OPUS-5-5'; eq "family lowercases + names the family" opus
  m 'tl_model_family claude-mythos-1'; eq "family mythos" mythos
  m 'tl_model_family Claude-NewName-1'; eq "family unknown → lowercased id" claude-newname-1
  m GROK_PLUGIN_ROOT=/tmp 'tl_model_family GROK-4.5'; eq "Grok family = lowercased id" grok-4.5
  m "tl_model_family ''"; [ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok "family of empty id → rc 1, no output" \
    || bad "family empty: rc=$RC out='$OUT'"
  m 'tl_light_model'; eq "light (claude)" sonnet
  m GROK_PLUGIN_ROOT=/tmp 'tl_light_model'; eq "light (grok)" grok-4.5
  m 'tl_escalation_model'; eq "[8] escalation (claude)" fable
  m THROUGHLINE_ESCALATION_MODEL=x 'tl_escalation_model'; eq "[8] escalation override" x
  m GROK_PLUGIN_ROOT=/tmp 'tl_escalation_model'; eq "[8] escalation (grok)" grok-4.6
) || true

echo "[9]-[10] tl_parent_model reads the Claude transcript as JSON"
CFG="$ROOT/cfg"; SID="0a1b2c3d-sess"; mkdir -p "$CFG/projects/-tmp-proj"
T="$CFG/projects/-tmp-proj/$SID.jsonl"
{ printf '%s\n' '{"type":"assistant","message":{"model":"claude-trunc'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}'
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","name":"Agent","input":{"model":"haiku","prompt":"x"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"x"}]}}'
} >"$T"
( m CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" 'tl_parent_model'; eq "[9] transcript fixture" claude-opus-5-5
  m CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" 'set -euo pipefail; tl_parent_model'; eq "[9] same under set -euo pipefail" claude-opus-5-5
  T2="$CFG/projects/-tmp-proj/1-trailing.jsonl"
  { cat "$T"; printf '%s' '{"type":"assistant","message":{"model":"claude-par'; } >"$T2"
  m CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID=1-trailing 'tl_parent_model'; eq "[9] partial newest line skipped" claude-opus-5-5
  mkdir -p "$H/.claude/projects/-x"; cp "$T" "$H/.claude/projects/-x/2-home.jsonl"
  m CLAUDE_CODE_SESSION_ID=2-home 'tl_parent_model'; eq "[9] default \$HOME/.claude" claude-opus-5-5
  SHIM="$ROOT/shim"; SHIM0="$ROOT/shim0"; mkdir -p "$SHIM" "$SHIM0"
  for t in bash tac tail tr head cat awk grep sed git; do
    p="$(command -v "$t")" && ln -sf "$p" "$SHIM/$t" && ln -sf "$p" "$SHIM0/$t"
  done
  p="$(command -v python3)" && ln -sf "$p" "$SHIM/python3"
  if [ -x "$SHIM/python3" ]; then
    m PATH="$SHIM" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" 'tl_parent_model'; eq "[9] python3 fallback (no jq)" claude-opus-5-5
  else bad "infra: python3 not found for the fallback check"; fi
  m PATH="$SHIM0" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" 'tl_parent_model'; unreadable "neither jq nor python3" "no json parser"
  m CLAUDE_CONFIG_DIR="$CFG" 'tl_parent_model'; unreadable "[10] CLAUDE_CODE_SESSION_ID unset" "no session id"
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-escaped-1"}}' >"$CFG/projects/x.jsonl"
  m CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID=../x 'tl_parent_model'; unreadable "[10] session id ../x" -
  m CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID=no-such-sess 'tl_parent_model'; unreadable "[10] no transcript file" "transcript not found"
  printf '%s\n' '{"type":"user","message":{"content":"x"}}' >"$CFG/projects/-tmp-proj/3-nomodel.jsonl"
  m CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID=3-nomodel 'tl_parent_model'; unreadable "transcript with no assistant model" "no model in transcript"
) || true

echo "[11] tl_parent_model reads Grok summary.json current_model_id"
( GH="$ROOT/grokhome"; P="$ROOT/proj"; mkdir -p "$P/sub"
  case "$P" in *[!A-Za-z0-9/._-]*) bad "infra: fixture path has chars needing encoding: $P" ;; esac
  enc="$(printf '%s' "$P" | sed 's|/|%2F|g')"
  mkdir -p "$GH/sessions/$enc/gsess1"
  printf '%s\n' '{"current_model_id":"grok-4.6","title":"x"}' >"$GH/sessions/$enc/gsess1/summary.json"
  m GROK_PLUGIN_ROOT=/tmp GROK_HOME="$GH" GROK_SESSION_ID=gsess1 "cd $(q "$P") && tl_parent_model"; eq "[11] Grok summary.json" grok-4.6
  git init -q "$P" 2>/dev/null
  m GROK_PLUGIN_ROOT=/tmp GROK_HOME="$GH" GROK_SESSION_ID=gsess1 "cd $(q "$P/sub") && tl_parent_model"; eq "[11] retry via git toplevel" grok-4.6
  m GROK_PLUGIN_ROOT=/tmp GROK_HOME="$GH" "cd $(q "$P") && tl_parent_model"; unreadable "Grok GROK_SESSION_ID unset" -
  printf '%s\n' '{"current_model_id":"grok-escaped"}' >"$GH/sessions/summary.json"
  m GROK_PLUGIN_ROOT=/tmp GROK_HOME="$GH" GROK_SESSION_ID=.. "cd $(q "$P") && tl_parent_model"; unreadable "Grok session id .. rejected" -
) || true

echo "[12] tl_parent_effort: env, then settings.json, else unknown"
( CE="$ROOT/cfge"; mkdir -p "$CE"; printf '%s\n' '{"effortLevel":"xhigh"}' >"$CE/settings.json"
  m CLAUDE_CODE_EFFORT_LEVEL=high 'tl_parent_effort'; eq "[12] env" "high env"
  m CLAUDE_CODE_EFFORT_LEVEL=high CLAUDE_CONFIG_DIR="$CE" 'tl_parent_effort'; eq "env beats settings" "high env"
  m CLAUDE_CONFIG_DIR="$CE" 'tl_parent_effort'; eq "[12] settings" "xhigh settings"
  m CLAUDE_CONFIG_DIR="$ROOT/none" 'tl_parent_effort'; eq "[12] neither" "unknown -"
  m GROK_PLUGIN_ROOT=/tmp CLAUDE_CODE_EFFORT_LEVEL=high 'tl_parent_effort'; eq "Grok" "unknown -"
) || true

echo "[13] product names only on the four binding lines + the family list"
( if [ ! -r "$MODELS" ] || [ ! -s "$MODELS" ]; then bad "infra: $MODELS missing/unreadable/empty"
  else
    n="$(grep -cE 'sonnet|fable|grok-4' "$MODELS")"; grc=$?
    ni="$(grep -ciE 'sonnet|fable|grok-4' "$MODELS")"
    if [ "$grc" -ge 2 ] || [ -z "$n" ]; then bad "infra: grep rc=$grc"
    elif [ "$n" -eq 5 ] && [ "$ni" -eq 5 ]; then ok "[13] product-name line count is exactly 5"
    else bad "[13] product-name lines=$n (case-insensitive $ni) want 5:"$'\n'"$(grep -niE 'sonnet|fable|grok-4' "$MODELS")"; fi
    for b in '_TL_CLAUDE_LIGHT=sonnet' '_TL_CLAUDE_ESCALATION=fable' '_TL_GROK_LIGHT=grok-4.5' '_TL_GROK_ESCALATION=grok-4.6'; do
      grep -qE "^${b//./\\.}([[:space:]]|\$)" "$MODELS" && ok "binding line $b" || bad "missing binding line $b"
    done
    rest="$(grep -E 'sonnet|fable|grok-4' "$MODELS" | grep -vE '^_TL_(CLAUDE|GROK)_(LIGHT|ESCALATION)=')"
    [ -n "$rest" ] && [ "$(printf '%s\n' "$rest" | grep -c .)" = 1 ] \
      && printf '%s' "$rest" | grep -q 'mythos fable opus sonnet haiku' \
      && ok "the one other product-name line is the family list" || bad "non-binding product-name lines: $rest"
    stale="$(grep -nE 'latest top-tier|prior-gen|author ≠ reviewer' "$MODELS")"; src=$?
    [ "$src" -eq 1 ] && ok "no latest top-tier / prior-gen / author ≠ reviewer text" \
      || bad "stale pairing text (rc=$src): $stale"
  fi
) || true

norm() { tr '\n' ' ' <"$1" | tr -s ' '; }
echo "[14] design-reviewer inherits; independence is the fresh worker"
( pre=1
  for f in "$DR" "$TA"; do
    { [ -r "$f" ] && [ -s "$f" ]; } || { bad "infra: $f missing/unreadable/empty (L-001)"; pre=0; }
  done
  if [ "$pre" = 1 ]; then
    head8="$(sed -n '1,8p' "$DR")"
    [ -n "$head8" ] && printf '%s\n' "$head8" | grep -q '^model: inherit$' \
      && ok "[14] design-reviewer frontmatter has model: inherit" || bad "[14] frontmatter: $head8"
    total=0; infra=0
    for f in "$DR" "$TA"; do
      c="$(grep -c 'deliberately on a different model\|on a different model than you authored in' "$f")"; grc=$?
      if [ "$grc" -ge 2 ] || [ -z "$c" ]; then infra=1; else total=$((total + c)); fi
    done
    [ "$infra" = 0 ] && [ "$total" = 0 ] && ok "[14] no different-model wording (grep -c total 0)" \
      || bad "[14] different-model wording count=$total infra=$infra"
    jn="$(norm "$DR")$(norm "$TA")"
    [ -n "$jn" ] && ! printf '%s' "$jn" | grep -qiE 'on a different model|deliberately on a different' \
      && ok "no different-model wording across line breaks" || bad "different-model wording survives (line-joined)"
    norm "$DR" | grep -qF "You did NOT author this design. You run in a fresh context that is not the author's session; that fresh context is the independence. You may be on the same model as the author." \
      && ok "design-reviewer opening paragraph pinned" || bad "design-reviewer opening paragraph missing"
    norm "$TA" | grep -qF "it runs in a fresh worker that is not this session and inherits this session's model (FR-10); independence is the fresh context, not a distinct model name" \
      && ok "/tdd-author 7b fresh-worker wording pinned" || bad "/tdd-author 7b wording missing"
  fi
) || true

echo "[15] plugin.json description: fresh worker, no different-model claims"
( if [ ! -r "$PJ" ]; then bad "infra: $PJ unreadable"
  elif ! command -v jq >/dev/null 2>&1; then bad "infra: jq not found"
  else
    d="$(jq -r .description "$PJ" 2>"$ROOT/pj.err")"; jrc=$?
    if [ "$jrc" -ne 0 ] || [ -z "$d" ] || [ "$d" = null ]; then bad "infra: jq rc=$jrc desc='$d' $(cat "$ROOT/pj.err")"
    else
      printf '%s' "$d" | grep -qF 'fresh worker' && ok "[15] contains fresh worker" || bad "[15] missing fresh worker"
      for s in 'prior generation' 'DIFFERENT model' 'latest top-tier' 'different model, fresh context'; do
        printf '%s' "$d" | grep -qF "$s" && bad "[15] still contains '$s'" || ok "[15] no '$s'"
      done
      for s in '(fresh worker, same model allowed)' "on the parent session's model (escalation on demand)" 'an independent review in a fresh worker'; do
        printf '%s' "$d" | grep -qF "$s" && ok "contains '$s'" || bad "missing '$s'"
      done
    fi
  fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== model-roles eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

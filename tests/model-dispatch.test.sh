#!/usr/bin/env bash
# model-dispatch.test.sh — eval for TDD 0066 / FR-87, FR-52, FR-15(d), NFR-3,
# NFR-4: /build-tdds model dispatch, queue confirmation, and run record.
#
# EXECUTES the new models.sh / run-record.sh functions in a clean
#   env -i HOME=<tmp> PATH="$PATH" bash -c '. models.sh; . run-record.sh; …'
# shell against fixture TDDs and a temp git repo with a run initialized by the
# real tl_run_init, and EXTRACTS + RUNS the `<!-- tl:models-confirm -->` and
# `<!-- tl:models-record -->` blocks from skills/implement/SKILL.md the way the
# harness does: a fresh shell, nothing pre-sourced, no positional args, inputs
# only from TL_* env vars —
#   env -i HOME=<tmp> PATH="$PATH" CLAUDE_PLUGIN_ROOT=<repo> \
#     CLAUDE_CONFIG_DIR=<tmp>/.claude CLAUDE_CODE_SESSION_ID=<sid> TL_…=… bash <block>
# No network. A missing marker, block or file is a FAIL (infra, L-001/L-011),
# never a skip. Observation numbers [1]–[13] are the TDD's Verification plan;
# [13] is the one text-only check (stated reason: it instructs the harness's
# dispatch tool, which an eval cannot execute).
#
# Written red-first. Run: bash tests/model-dispatch.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="$REPO/scripts/lib/models.sh"
RREC="$REPO/scripts/lib/run-record.sh"
SKILL="$REPO/skills/implement/SKILL.md"
README="$REPO/README.md"
RESULTS=""; ROOT=""
trap 'rm -rf "$ROOT" "$RESULTS"' EXIT
RESULTS="$(mktemp)"; export RESULTS
ROOT="$(mktemp -d)"
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
q() { printf '%q' "$1"; }

H="$ROOT/home"; WORK="$ROOT/work"; TP="$H/.claude/projects/-tmp-proj"; FX="$ROOT/tdd"
mkdir -p "$TP" "$WORK" "$FX" "$ROOT/blocks"

# --- fixtures ----------------------------------------------------------------
NONT="$FX/0099-x.md"; MECH="$FX/0098-m.md"
printf '# TDD 0099: fixture\n\n## Verification plan\n- Drive the browser UI with playwright and take a screenshot.\n\n## Touched files\n' >"$NONT"
printf '# TDD 0098: fixture\n\n## Verification plan\n- Run `tool --check`; exit code 0 and stdout has `ok`.\n\n## Touched files\n' >"$MECH"
mk_transcript() {  # <sid> <model>
  { printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}'
    printf '{"type":"assistant","message":{"model":"%s","content":[{"type":"text","text":"x"}]}}\n' "$2"
  } >"$TP/$1.jsonl"
}
mk_transcript s-opus  claude-opus-5-5
mk_transcript s-fable claude-fable-5-1
GR="$ROOT/repo"; RUN=r1; LOGS="$GR/docs/tdd/.implement-logs"
FIXOK=1
{ git init -q "$GR" && git -C "$GR" config user.email t@t.t && git -C "$GR" config user.name t \
  && printf '# r\n' >"$GR/README.md" && git -C "$GR" add README.md && git -C "$GR" commit -qm init; } \
  >/dev/null 2>&1 || { bad "infra: cannot build the temp git repo fixture"; FIXOK=0; }

# m [VAR=val ...] '<cmds>' — source models.sh + run-record.sh, then run <cmds>
# in a CLEAN shell (env -i: no caller variable or function leaks in). A VAR=val
# overrides a default. Sets OUT ERR RC NL (stdout newline count).
m() {
  local cmd="${!#}"
  local -a envs=("${@:1:$#-1}")
  env -i HOME="$H" PATH="$PATH" ${envs[@]+"${envs[@]}"} \
    bash -c ". $(q "$MODELS") || exit 97; . $(q "$RREC") || exit 98; $cmd" >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
  NL="$(wc -l <"$ROOT/out" | tr -d ' ')"
}
# runb <block> [VAR=val ...] — run an extracted block as the harness does:
# `bash <file>` under env -i, no args, nothing pre-sourced, cwd $WORK.
runb() {
  local b="$1"; shift
  ( cd "$WORK" && exec env -i HOME="$H" PATH="$PATH" CLAUDE_PLUGIN_ROOT="$REPO" \
      CLAUDE_CONFIG_DIR="$H/.claude" "$@" bash "$b" ) >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
  NL="$(wc -l <"$ROOT/out" | tr -d ' ')"
}
# want <label> <want> — rc 0, stdout is exactly <want> (every line
# newline-terminated), no stderr.
want() {
  local wl; wl="$(printf '%s\n' "$2" | wc -l | tr -d ' ')"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "$2" ] && [ "$NL" = "$wl" ] && [ -z "$ERR" ]; then ok "$1"
  else bad "$1: rc=$RC lines=$NL err='$ERR'"$'\n'"--- got:"$'\n'"$OUT"$'\n'"--- want:"$'\n'"$2"; fi
}
# silent <label> — rc 0, zero stdout bytes, no stderr.
silent() {
  if [ "$RC" -eq 0 ] && [ ! -s "$ROOT/out" ] && [ -z "$ERR" ]; then ok "$1"
  else bad "$1: rc=$RC out='$OUT' err='$ERR' want no output, rc 0"; fi
}
# has_line <label> <file> <exact-line> — <file> exists and has that whole line.
has_line() {
  if [ -f "$2" ] && grep -qxF -- "$3" "$2"; then ok "$1"
  else bad "$1: '$3' not a line of $2 ($( [ -f "$2" ] && tr '\n' '|' <"$2" || echo missing))"; fi
}
# out_line <label> <exact-line> — the last run's stdout has that whole line.
out_line() {
  if [ -s "$ROOT/out" ] && grep -qxF -- "$2" "$ROOT/out"; then ok "$1"
  else bad "$1: stdout has no line '$2' (rc=$RC out='$OUT' err='$ERR')"; fi
}
HAVE_JQ=1
command -v jq >/dev/null 2>&1 || { bad "infra: jq not found (needed to validate the sidecar JSON)"; HAVE_JQ=0; }
# jf <label> <file> <key> <want> — the JSON <file>'s <key> is the string <want>.
jf() {
  local got
  [ "$HAVE_JQ" = 1 ] || { bad "$1: infra: no jq"; return; }
  got="$(jq -r --arg k "$3" 'if has($k) then .[$k] else "<absent>" end' "$2" 2>&1)"
  [ "$got" = "$4" ] && ok "$1: $3=$4" || bad "$1: $3='$got' want '$4'"
}
WANTKEYS="$(printf '%s\n' parent effort effort_source build build_src build_model review \
  review_src review_model verify verify_src verify_model verify_class escalation \
  escalation_model escalation_reason halt_tdd_blob | LC_ALL=C sort | paste -sd' ' -)"
# keys17 <label> <file> — valid JSON object with exactly the 17 keys, all strings.
keys17() {
  local got
  [ "$HAVE_JQ" = 1 ] || { bad "$1: infra: no jq"; return; }
  if [ ! -f "$2" ]; then bad "$1: sidecar missing: $2"; return; fi
  got="$(jq -r 'keys | join(" ")' "$2" 2>&1)" || { bad "$1: not valid JSON: $got"; return; }
  [ "$got" = "$WANTKEYS" ] && ok "$1: exactly the 17 keys" || bad "$1: keys '$got' want '$WANTKEYS'"
  jq -e 'type == "object" and length == 17 and all(.[]; type == "string")' "$2" >/dev/null 2>&1 \
    && ok "$1: valid JSON, 17 string values" || bad "$1: not an object of 17 strings: $(cat "$2")"
}

# extract <file> <marker> <out> — the first ```bash block after the marker
# line → <out>. rc 0 ok | 10 file unreadable/empty | 3 no marker | 4 no bash
# block after it | 5 block never closed | 6 block empty | other: awk failed.
extract() {
  { [ -r "$1" ] && [ -s "$1" ]; } || return 10
  awk -v M="$2" '
    !seen && $0 == M                    { seen = 1; next }
    seen && !open && /^```bash[ \t]*$/  { open = 1; next }
    open && /^```[ \t]*$/               { closed = 1; exit }
    open                                { print }
    END { if (!seen) exit 3; if (!open) exit 4; if (!closed) exit 5 }
  ' "$1" >"$3" || return $?
  [ -s "$3" ] || return 6
}
# getblock <marker> <out> — extract from the skill; report; rc 0 iff extracted.
getblock() {
  local rc
  extract "$SKILL" "$1" "$2"; rc=$?
  case "$rc" in
    0)  ok "block after '$1' extracted"; return 0 ;;
    10) bad "infra: $SKILL missing/unreadable/empty" ;;
    3)  bad "marker '$1' not found in skills/implement/SKILL.md" ;;
    4)  bad "no fenced bash block after '$1'" ;;
    5)  bad "the bash block after '$1' is never closed" ;;
    6)  bad "the bash block after '$1' is empty" ;;
    *)  bad "infra: extractor rc=$rc for '$1'" ;;
  esac
  return 1
}

echo "[0] the new functions are defined after sourcing models.sh + run-record.sh"
( m 'for f in tl_dispatch_model_arg tl_model_warnings tl_models_confirm _tl_models_write tl_run_set_models tl_run_get_model_field; do [ "$(type -t "$f")" = function ] || echo "missing $f"; done'
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && ok "all six functions defined; sourcing is silent" \
    || bad "rc=$RC out='$OUT' err='$ERR'"
) || true

echo "[1] tl_dispatch_model_arg: inherit → no model parameter"
( m 'tl_dispatch_model_arg inherit'; silent "[1] inherit → empty, rc 0"
  m 'tl_dispatch_model_arg sonnet'; want "[1] sonnet → sonnet" sonnet
  m 'tl_dispatch_model_arg claude-opus-5-5'; want "a full id is passed exactly" claude-opus-5-5
) || true

echo "[2]-[4] tl_models_confirm renders the queue confirmation"
( X2="models 0099-x: parent=claude-opus-5-5 effort=high (env; session-wide)
  implementer: inherit (claude-opus-5-5) [parent]
  reviewer: inherit (claude-opus-5-5) [parent]
  runtime-verify (nontrivial): inherit (claude-opus-5-5) [parent]"
  m CLAUDE_CODE_EFFORT_LEVEL=high "tl_models_confirm 0099-x $(q "$NONT") claude-opus-5-5"
  want "[2] no pins, parent claude-opus-5-5, nontrivial, effort env" "$X2"

  X3="models 0098-m: parent=claude-opus-5-5 effort=high (env; session-wide)
  implementer: inherit (claude-opus-5-5) [parent]
  reviewer: inherit (claude-opus-5-5) [parent]
  runtime-verify (mechanical): sonnet [light] effort=low requested; session effort applies"
  m CLAUDE_CODE_EFFORT_LEVEL=high "tl_models_confirm 0098-m $(q "$MECH") claude-opus-5-5"
  want "[3] mechanical fixture → light verify line, low effort requested" "$X3"

  X4="models 0099-x: parent=claude-fable-5-1 effort=high (env; session-wide)
  implementer: inherit (claude-fable-5-1) [parent]
  reviewer: inherit (claude-fable-5-1) [parent]
  runtime-verify (nontrivial): inherit (claude-fable-5-1) [parent]"
  m CLAUDE_CODE_EFFORT_LEVEL=high "tl_models_confirm 0099-x $(q "$NONT") claude-fable-5-1"
  want "[4] same TDD from parent claude-fable-5-1 (FR-87 M2)" "$X4"

  XU="models 0098-m: parent=unknown effort=unknown (-; session-wide)
  implementer: inherit (unknown) [parent]
  reviewer: inherit (unknown) [parent]
  runtime-verify (mechanical): inherit (unknown) [parent-cap] effort=low requested; session effort applies"
  m "tl_models_confirm 0098-m $(q "$MECH")"
  want "unreadable parent → parent=unknown, mechanical verify parent-cap" "$XU"

  CE="$ROOT/cfge"; mkdir -p "$CE"; printf '%s\n' '{"effortLevel":"xhigh"}' >"$CE/settings.json"
  m CLAUDE_CONFIG_DIR="$CE" "tl_models_confirm 0099-x $(q "$NONT") claude-opus-5-5"
  [ "$RC" -eq 0 ] && [ "$(sed -n 1p "$ROOT/out")" = "models 0099-x: parent=claude-opus-5-5 effort=xhigh (settings; session-wide)" ] \
    && ok "effort from settings.json is labeled (settings; session-wide)" || bad "settings effort: rc=$RC out='$OUT' err='$ERR'"

  m THROUGHLINE_REVIEW_MODEL=opus "tl_models_confirm 0099-x $(q "$NONT") claude-opus-5-5"
  [ "$RC" -eq 0 ] && [ "$(sed -n 3p "$ROOT/out")" = "  reviewer: opus [pin:THROUGHLINE_REVIEW_MODEL]" ] \
    && ok "a pin renders as the id with [pin:<ENV>]" || bad "pin line: rc=$RC out='$OUT' err='$ERR'"

  m "tl_models_confirm"
  [ "$RC" -eq 2 ] && [ ! -s "$ROOT/out" ] && [ -n "$ERR" ] && ok "no slug → rc 2, no stdout" \
    || bad "no slug: rc=$RC out='$OUT' err='$ERR'"
) || true

echo "[5]-[7] tl_model_warnings: light pins and effort pins"
( m THROUGHLINE_REVIEW_MODEL=sonnet "tl_model_warnings $(q "$NONT") claude-opus-5-5"
  want "[5] THROUGHLINE_REVIEW_MODEL=sonnet → light-tier warning" \
    'throughline: THROUGHLINE_REVIEW_MODEL=sonnet puts the reviewer on the light tier; continuing'
  m THROUGHLINE_REVIEW_MODEL=opus "tl_model_warnings $(q "$NONT") claude-opus-5-5"
  silent "[5] THROUGHLINE_REVIEW_MODEL=opus → no output"
  m THROUGHLINE_BUILD_MODEL=haiku "tl_model_warnings $(q "$NONT") claude-opus-5-5"
  want "implementer pinned to haiku → light-tier warning" \
    'throughline: THROUGHLINE_BUILD_MODEL=haiku puts the implementer on the light tier; continuing'
  m CLAUDE_CODE_SUBAGENT_MODEL=haiku "tl_model_warnings $(q "$NONT") claude-opus-5-5"
  want "CLAUDE_CODE_SUBAGENT_MODEL is a pin: both judgment slots warn" \
    'throughline: CLAUDE_CODE_SUBAGENT_MODEL=haiku puts the implementer on the light tier; continuing
throughline: CLAUDE_CODE_SUBAGENT_MODEL=haiku puts the reviewer on the light tier; continuing'

  m THROUGHLINE_BUILD_EFFORT=max "tl_model_warnings $(q "$NONT") claude-opus-5-5"
  want "[6] THROUGHLINE_BUILD_EFFORT=max → effort-ignored line" \
    'throughline: THROUGHLINE_BUILD_EFFORT=max ignored: per-worker effort is not supported on this harness (workers run at the session effort)'
  m THROUGHLINE_RUNTIME_VERIFY_EFFORT=low THROUGHLINE_REVIEW_EFFORT=high THROUGHLINE_BUILD_EFFORT=max \
    THROUGHLINE_REVIEW_MODEL=haiku THROUGHLINE_BUILD_MODEL=sonnet "tl_model_warnings $(q "$NONT") claude-opus-5-5"
  want "order: build, review, then the effort pins" \
    'throughline: THROUGHLINE_BUILD_MODEL=sonnet puts the implementer on the light tier; continuing
throughline: THROUGHLINE_REVIEW_MODEL=haiku puts the reviewer on the light tier; continuing
throughline: THROUGHLINE_BUILD_EFFORT=max ignored: per-worker effort is not supported on this harness (workers run at the session effort)
throughline: THROUGHLINE_REVIEW_EFFORT=high ignored: per-worker effort is not supported on this harness (workers run at the session effort)
throughline: THROUGHLINE_RUNTIME_VERIFY_EFFORT=low ignored: per-worker effort is not supported on this harness (workers run at the session effort)'

  m "tl_model_warnings $(q "$MECH") claude-opus-5-5"
  silent "[7] mechanical verify on the light binding, no pins → nothing"
  m THROUGHLINE_RUNTIME_VERIFY_MODEL=haiku "tl_model_warnings $(q "$MECH") claude-opus-5-5"
  silent "a light verify pin is not a judgment-slot warning (build/review only)"
  m 'tl_model_warnings'; silent "no args, no pins → nothing"
) || true

echo "[8] tl_run_set_models writes the 17-key sidecar"
SC="$LOGS/$RUN/0099-x.models.json"
( [ "$FIXOK" = 1 ] || { bad "[8] infra: no fixture repo"; exit 0; }
  m "tl_run_init $(q "$GR") $RUN"
  { [ "$RC" -eq 0 ] && [ -f "$LOGS/$RUN/run.json" ]; } || { bad "[8] infra: tl_run_init failed: rc=$RC err='$ERR'"; exit 0; }
  m CLAUDE_CODE_EFFORT_LEVEL=high "tl_run_set_models $(q "$GR") $RUN 0099-x $(q "$NONT") claude-opus-5-5"
  silent "[8] tl_run_set_models (5 args) → rc 0, quiet"
  keys17 "[8] 0099-x sidecar" "$SC"
  for kv in build=inherit build_src=parent build_model=claude-opus-5-5 review=inherit \
            review_src=parent review_model=claude-opus-5-5 parent=claude-opus-5-5 \
            verify=inherit verify_src=parent verify_model=claude-opus-5-5 verify_class=nontrivial \
            effort=high effort_source=env escalation= halt_tdd_blob=; do
    jf "[8] parent opus" "$SC" "${kv%%=*}" "${kv#*=}"
  done
  m CLAUDE_CODE_EFFORT_LEVEL=high "tl_run_set_models $(q "$GR") $RUN 0098-m $(q "$MECH") claude-opus-5-5"
  for kv in verify=sonnet verify_src=light verify_model=sonnet verify_class=mechanical build_model=claude-opus-5-5; do
    jf "[8] mechanical fixture" "$LOGS/$RUN/0098-m.models.json" "${kv%%=*}" "${kv#*=}"
  done
  m "tl_run_set_models $(q "$GR") $RUN 0095-f $(q "$NONT") claude-fable-5-1"
  for kv in build_model=claude-fable-5-1 review_model=claude-fable-5-1 parent=claude-fable-5-1 build=inherit; do
    jf "[8] parent claude-fable-5-1 (FR-87 M2)" "$LOGS/$RUN/0095-f.models.json" "${kv%%=*}" "${kv#*=}"
  done
  m "tl_run_set_models $(q "$GR") $RUN 0094-u $(q "$MECH")"
  for kv in parent=unknown build=inherit build_model=unknown review_model=unknown verify=inherit verify_src=parent-cap verify_model=unknown effort=unknown; do
    jf "[8] unreadable parent" "$LOGS/$RUN/0094-u.models.json" "${kv%%=*}" "${kv#*=}"
  done
  keys17 "[8] unreadable-parent sidecar" "$LOGS/$RUN/0094-u.models.json"
  m "tl_run_set_models $(q "$GR") $RUN 0093-n"
  [ "$RC" -eq 2 ] && [ ! -e "$LOGS/$RUN/0093-n.models.json" ] && ok "no <tdd-path> → rc 2, nothing written" \
    || bad "missing tdd-path: rc=$RC err='$ERR'"
) || true

echo "[9] _tl_models_write overlays; never drops a key; validates; escapes"
( [ -f "$SC" ] || { bad "[9] infra: no sidecar from [8]"; exit 0; }
  m "_tl_models_write $(q "$GR") $RUN 0099-x escalation=escalated"
  silent "[9] _tl_models_write escalation=escalated → rc 0"
  m CLAUDE_CODE_EFFORT_LEVEL=high "tl_run_set_models $(q "$GR") $RUN 0099-x $(q "$NONT") claude-opus-5-5"
  jf "[9] after a second tl_run_set_models" "$SC" escalation escalated
  jf "[9] after a second tl_run_set_models" "$SC" build inherit
  keys17 "[9] overlaid sidecar" "$SC"
  cp "$SC" "$ROOT/sc.before"
  m "_tl_models_write $(q "$GR") $RUN 0099-x foo=1"
  [ "$RC" -eq 2 ] && cmp -s "$SC" "$ROOT/sc.before" && ok "[9] unknown key foo=1 → rc 2, file unchanged" \
    || bad "[9] unknown key: rc=$RC err='$ERR' (file changed? $(cmp "$SC" "$ROOT/sc.before" 2>&1))"
  m "_tl_models_write $(q "$GR") $RUN 0099-x build=x foo=1"
  [ "$RC" -eq 2 ] && cmp -s "$SC" "$ROOT/sc.before" && ok "a valid key next to an unknown one → rc 2, nothing written" \
    || bad "mixed keys: rc=$RC err='$ERR'"
  m "_tl_models_write $(q "$GR") $RUN 0099-x noequals"
  [ "$RC" -eq 2 ] && cmp -s "$SC" "$ROOT/sc.before" && ok "a pair without = → rc 2, nothing written" \
    || bad "no '=': rc=$RC err='$ERR'"
  VAL='dispatch error: "x" \ y \"z\" & end'
  m "_tl_models_write $(q "$GR") $RUN 0099-x escalation_reason=$(q "$VAL")"
  silent "[9] write a value with \" and \\"
  m "tl_run_get_model_field $(q "$GR") $RUN 0099-x escalation_reason"
  [ "$RC" -eq 0 ] && [ "$OUT" = "$VAL" ] && ok "[9] the value round-trips through tl_run_get_model_field" \
    || bad "[9] round-trip: rc=$RC got '$OUT' want '$VAL' err='$ERR'"
  jf "[9] the file stays valid JSON" "$SC" escalation_reason "$VAL"
  jf "[9] 0066's keys intact after the write" "$SC" build inherit
  VAL2=$'two\nlines\tand tab'
  m "_tl_models_write $(q "$GR") $RUN 0099-x halt_tdd_blob=$(q "$VAL2")"
  m "tl_run_get_model_field $(q "$GR") $RUN 0099-x halt_tdd_blob"
  [ "$RC" -eq 0 ] && [ "$OUT" = "$VAL2" ] && ok "control characters round-trip" \
    || bad "control chars: rc=$RC got '$OUT' err='$ERR'"
  keys17 "[9] after escaped writes" "$SC"
  m "tl_run_get_model_field $(q "$GR") $RUN 0091-none build"
  [ "$RC" -eq 1 ] && [ ! -s "$ROOT/out" ] && ok "tl_run_get_model_field with no sidecar → rc 1, no output" \
    || bad "no sidecar: rc=$RC out='$OUT'"
  m "tl_run_get_model_field $(q "$GR") $RUN 0099-x foo"
  [ "$RC" -eq 2 ] && [ ! -s "$ROOT/out" ] && ok "tl_run_get_model_field unknown key → rc 2" \
    || bad "unknown read key: rc=$RC out='$OUT'"
  m "_tl_models_write $(q "$GR") $RUN ../evil build=x"
  [ "$RC" -eq 2 ] && [ ! -e "$LOGS/evil.models.json" ] && [ ! -e "$LOGS/$RUN/../evil.models.json" ] \
    && ok "slug ../evil → rc 2, no file" || bad "bad slug: rc=$RC err='$ERR'"
  m "_tl_models_write $(q "$GR") ../x 0099-x build=x"
  [ "$RC" -eq 2 ] && ok "run ../x → rc 2" || bad "bad run: rc=$RC err='$ERR'"
  m "_tl_models_write $(q "$GR") r-none 0099-x build=x"
  [ "$RC" -eq 1 ] && [ ! -e "$LOGS/r-none" ] && ok "uninitialized run → rc 1, no run dir created" \
    || bad "uninitialized run: rc=$RC err='$ERR'"
  m "_tl_models_write relative/root $RUN 0099-x build=x"
  [ "$RC" -eq 2 ] && ok "relative repo root → rc 2" || bad "relative root: rc=$RC"
) || true

echo "[10] tl_run_set_tdd / tl_run_set_pr leave the sidecar alone"
( [ -f "$SC" ] || { bad "[10] infra: no sidecar from [8]"; exit 0; }
  cp "$SC" "$ROOT/sc.10"
  m "tl_run_set_tdd $(q "$GR") $RUN 0099-x failed gate-fail"
  [ "$RC" -eq 0 ] && cmp -s "$SC" "$ROOT/sc.10" && ok "[10] tl_run_set_tdd … failed gate-fail → sidecar unchanged" \
    || bad "[10] set_tdd: rc=$RC err='$ERR' $(cmp "$SC" "$ROOT/sc.10" 2>&1)"
  m "tl_run_set_pr $(q "$GR") $RUN 0099-x https://example.invalid/pr/1"
  [ "$RC" -eq 0 ] && cmp -s "$SC" "$ROOT/sc.10" && ok "tl_run_set_pr → sidecar unchanged" \
    || bad "set_pr: rc=$RC err='$ERR'"
  if [ "$HAVE_JQ" = 1 ] && jq -e 'has("slug") and (has("build") | not)' "$LOGS/$RUN/0099-x.json" >/dev/null 2>&1; then
    ok "<slug>.json keeps its own key set (no model keys)"
  else bad "<slug>.json: $(cat "$LOGS/$RUN/0099-x.json" 2>&1)"; fi
) || true

echo "[extract] extractor self-test: a bad skill fails closed"
( X="$ROOT/x"; MK='<!-- tl:t -->'; mkdir -p "$X"
  printf '# s\n\nno marker\n```bash\necho hi\n```\n' >"$X/nomarker.md"
  printf '# s\n%s\n\ntext only\n' "$MK" >"$X/noblock.md"
  printf '%s\n```bash\necho hi\n' "$MK" >"$X/open.md"
  printf '%s\n```bash\n```\n' "$MK" >"$X/empty.md"
  printf 'a\n%s\n\n```\nnot bash\n```\n```bash\necho one\n```\n```bash\necho two\n```\n' "$MK" >"$X/good.md"
  for c in nomarker:3 noblock:4 open:5 empty:6 absent:10; do
    extract "$X/${c%%:*}.md" "$MK" "$X/o"; rc=$?
    [ "$rc" = "${c#*:}" ] && ok "${c%%:*} → rc ${c#*:}" || bad "${c%%:*}: rc=$rc want ${c#*:}"
  done
  extract "$X/good.md" "$MK" "$X/o" && [ "$(cat "$X/o")" = "echo one" ] \
    && ok "takes the first bash block after the marker" || bad "good fixture: '$(cat "$X/o" 2>/dev/null)'"
) || true

# A plugin root with everything the models-confirm/-record blocks need except
# run-record.sh: the third source line must fail closed.
PART="$ROOT/partial"; mkdir -p "$PART/scripts/lib"
for l in plugin-root.sh models.sh plan-classifier.sh md.sh; do cp "$REPO/scripts/lib/$l" "$PART/scripts/lib/" 2>/dev/null; done
fail_closed() {  # <label> <stderr-substring>
  if [ "$RC" -ne 0 ] && [ ! -s "$ROOT/out" ] && printf '%s' "$ERR" | grep -qF -- "$2"; then ok "$1 (rc=$RC)"
  else bad "$1: rc=$RC out='$OUT' err='$ERR' want rc≠0, no stdout, stderr '$2'"; fi
}

echo "[11] the extracted tl:models-confirm block, run in a fresh env -i shell"
CB="$ROOT/blocks/confirm.sh"
if getblock '<!-- tl:models-confirm -->' "$CB"; then
  runb "$CB" CLAUDE_CODE_SESSION_ID=s-opus TL_QUEUE="$NONT"
  case "$OUT" in
    "models "*) [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'implementer: inherit' \
                  && ok "[11] stdout begins 'models ' and has 'implementer: inherit'" \
                  || bad "[11] rc=$RC out='$OUT' err='$ERR'" ;;
    *) bad "[11] stdout does not begin 'models ': rc=$RC out='$OUT' err='$ERR'" ;;
  esac
  want "[11] one-TDD queue, exact block" "models 0099-x: parent=claude-opus-5-5 effort=unknown (-; session-wide)
  implementer: inherit (claude-opus-5-5) [parent]
  reviewer: inherit (claude-opus-5-5) [parent]
  runtime-verify (nontrivial): inherit (claude-opus-5-5) [parent]"
  runb "$CB" CLAUDE_CODE_SESSION_ID=s-opus CLAUDE_CODE_EFFORT_LEVEL=high THROUGHLINE_REVIEW_MODEL=sonnet \
    TL_QUEUE="$NONT"$'\n'"$MECH"
  W='throughline: THROUGHLINE_REVIEW_MODEL=sonnet puts the reviewer on the light tier; continuing'
  want "two-TDD queue: confirmation then warnings, per TDD" "models 0099-x: parent=claude-opus-5-5 effort=high (env; session-wide)
  implementer: inherit (claude-opus-5-5) [parent]
  reviewer: sonnet [pin:THROUGHLINE_REVIEW_MODEL]
  runtime-verify (nontrivial): inherit (claude-opus-5-5) [parent]
$W
models 0098-m: parent=claude-opus-5-5 effort=high (env; session-wide)
  implementer: inherit (claude-opus-5-5) [parent]
  reviewer: sonnet [pin:THROUGHLINE_REVIEW_MODEL]
  runtime-verify (mechanical): sonnet [light] effort=low requested; session effort applies
$W"
  runb "$CB" CLAUDE_CODE_SESSION_ID=s-fable TL_QUEUE="$NONT"
  if [ "$RC" -eq 0 ]; then out_line "parent claude-fable-5-1 → implementer inherits it" '  implementer: inherit (claude-fable-5-1) [parent]'
  else bad "fable parent: rc=$RC err='$ERR'"; fi
  runb "$CB" TL_QUEUE="$NONT"
  [ "$RC" -eq 0 ] && [ "$(sed -n 1p "$ROOT/out")" = "models 0099-x: parent=unknown effort=unknown (-; session-wide)" ] \
    && ok "no session id → parent=unknown" || bad "unknown parent: rc=$RC out='$OUT' err='$ERR'"
  runb "$CB" CLAUDE_CODE_SESSION_ID=s-opus
  fail_closed "[11] TL_QUEUE unset → rc≠0, stderr names TL_QUEUE" TL_QUEUE
  runb "$CB" CLAUDE_CODE_SESSION_ID=s-opus TL_QUEUE="$NONT" CLAUDE_PLUGIN_ROOT="$PART"
  fail_closed "run-record.sh missing from the plugin root → fails closed" 'cannot source run-record.sh'
  runb "$CB" CLAUDE_CODE_SESSION_ID=s-opus TL_QUEUE="$NONT" CLAUDE_PLUGIN_ROOT=
  fail_closed "no plugin root env → fails closed" 'cannot source plugin-root.sh'
else
  bad "[11] infra: no tl:models-confirm block to run"
fi

echo "[12] the extracted tl:models-record block, run in a fresh env -i shell"
RB="$ROOT/blocks/record.sh"
if getblock '<!-- tl:models-record -->' "$RB"; then
  if [ "$FIXOK" = 1 ] && [ -f "$LOGS/$RUN/run.json" ]; then
    runb "$RB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN="$RUN" TL_SLUG=0097-rec TL_TDD="$NONT"
    [ "$RC" -eq 0 ] && [ -z "$ERR" ] && ok "[12] block rc 0, no stderr" || bad "[12] rc=$RC out='$OUT' err='$ERR'"
    S12="$LOGS/$RUN/0097-rec.models.json"
    [ -f "$S12" ] && ok "[12] the sidecar exists afterwards" || bad "[12] no sidecar $S12"
    keys17 "[12] block sidecar" "$S12"
    jf "[12] block sidecar" "$S12" parent claude-opus-5-5
    jf "[12] block sidecar" "$S12" build_model claude-opus-5-5
    has_line "[12] per-TDD log has the implementer line" "$LOGS/$RUN/0097-rec.log" 'implementer model=inherit (src=parent)'
    out_line "inherit → empty implementer dispatch model" 'dispatch implementer model='
    out_line "inherit → empty reviewer dispatch model" 'dispatch reviewer model='
    out_line "inherit → empty runtime-verify dispatch model" 'dispatch runtime-verify model='

    runb "$RB" CLAUDE_CODE_SESSION_ID=s-opus THROUGHLINE_BUILD_MODEL=opus TL_REPO="$GR" TL_RUN="$RUN" \
      TL_SLUG=0096-pin TL_TDD="$MECH"
    [ "$RC" -eq 0 ] && ok "pinned run: rc 0" || bad "pinned run: rc=$RC err='$ERR'"
    has_line "a pin is logged with its source" "$LOGS/$RUN/0096-pin.log" 'implementer model=opus (src=pin:THROUGHLINE_BUILD_MODEL)'
    out_line "a pin is the dispatch model" 'dispatch implementer model=opus'
    out_line "mechanical verify dispatches on the light binding" 'dispatch runtime-verify model=sonnet'
    out_line "an unpinned reviewer still inherits" 'dispatch reviewer model='

    runb "$RB" TL_REPO="$GR" TL_RUN="$RUN" TL_SLUG=0092-unk TL_TDD="$NONT"
    jf "unreadable parent through the block" "$LOGS/$RUN/0092-unk.models.json" parent unknown
    jf "unreadable parent through the block" "$LOGS/$RUN/0092-unk.models.json" build_model unknown

    for miss in TL_REPO TL_RUN TL_SLUG TL_TDD; do
      args=(CLAUDE_CODE_SESSION_ID=s-opus)
      for v in "TL_REPO=$GR" "TL_RUN=$RUN" "TL_SLUG=0090-miss" "TL_TDD=$NONT"; do
        [ "${v%%=*}" = "$miss" ] || args+=("$v")
      done
      runb "$RB" "${args[@]}"
      fail_closed "[12] $miss unset → rc≠0, stderr names $miss" "$miss"
    done
    [ ! -e "$LOGS/$RUN/0090-miss.models.json" ] && ok "a missing input writes no sidecar" \
      || bad "a sidecar was written despite a missing input"
    runb "$RB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN="$RUN" TL_SLUG=../evil TL_TDD="$NONT"
    [ "$RC" -ne 0 ] && [ ! -e "$LOGS/evil.log" ] && [ ! -e "$LOGS/evil.models.json" ] \
      && ok "slug ../evil → rc≠0, nothing written outside the run" || bad "bad slug through block: rc=$RC"
    runb "$RB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN="$RUN" TL_SLUG=0089-p TL_TDD="$NONT" \
      CLAUDE_PLUGIN_ROOT="$PART"
    fail_closed "run-record.sh missing from the plugin root → fails closed" 'cannot source run-record.sh'
  else
    bad "[12] infra: no initialized fixture run (see [8])"
  fi
else
  bad "[12] infra: no tl:models-record block to run"
fi

echo "[placement] each block sits in its step"
place() {  # <marker> <after-ERE> <before-ERE>
  local a mk z
  { [ -r "$SKILL" ] && [ -s "$SKILL" ]; } || { bad "infra: $SKILL unreadable"; return; }
  a="$(grep -nE -m1 -- "$2" "$SKILL" | cut -d: -f1)"; z="$(grep -nE -m1 -- "$3" "$SKILL" | cut -d: -f1)"
  mk="$(grep -nxF -m1 -- "$1" "$SKILL" | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$mk" ] && [ -n "$z" ] && [ "$a" -lt "$mk" ] && [ "$mk" -lt "$z" ]; then
    ok "'$1' at line $mk, between '$2' ($a) and '$3' ($z)"
  else bad "'$1' line '$mk' not between '$2' ('$a') and '$3' ('$z')"; fi
}
place '<!-- tl:models-confirm -->' '^## 5\. ' '^## 6\. '
place '<!-- tl:models-record -->'  '^## 7\. ' '^## 8\. '

echo "[13] text check: dispatch rule (instructs the harness's dispatch tool)"
( if [ -r "$SKILL" ] && [ -s "$SKILL" ]; then
    for s in 'no model parameter' 'tl_dispatch_model_arg' 'runtime-verify model=' 'reviewer model=' 'ADR 0015'; do
      grep -qF -- "$s" "$SKILL" && ok "[13] SKILL.md contains '$s'" || bad "[13] SKILL.md lacks '$s'"
    done
    c="$(grep -c 'prior-gen' "$SKILL")"; grc=$?
    if [ "$grc" -ge 2 ] || [ -z "$c" ]; then bad "[13] infra: grep rc=$grc"
    elif [ "$c" = 0 ]; then ok "[13] SKILL.md does not contain prior-gen"
    else bad "[13] SKILL.md still contains prior-gen ($c lines)"; fi
  else bad "[13] infra: $SKILL missing/unreadable/empty (L-001)"; fi
) || true

echo "[readme] README: fresh worker, ADR 0015 models.sh, pins are aliases"
( if [ -r "$README" ] && [ -s "$README" ]; then
    c="$(tr '\n' ' ' <"$README" | tr -s ' ' | grep -ciE 'different model|cross-model')"; grc=$?
    if [ "$grc" -ge 2 ] || [ -z "$c" ]; then bad "infra: grep rc=$grc on README"
    elif [ "$c" = 0 ]; then ok "README has no different-model / cross-model review claim (line-joined)"
    else bad "README still claims a different model: $(grep -niE 'different model|cross-model' "$README")"; fi
    grep -qE 'models\.sh +# .*ADR 0015' "$README" && ok "README models.sh comment cites ADR 0015" \
      || bad "README models.sh tree comment does not cite ADR 0015"
    grep -qF 'fresh worker' "$README" && ok "README says fresh worker" || bad "README lacks 'fresh worker'"
    for s in THROUGHLINE_BUILD_EFFORT 'aliases' '.models.json'; do
      grep -qF -- "$s" "$README" && ok "README models paragraph names '$s'" || bad "README lacks '$s'"
    done
  else bad "infra: $README missing/unreadable/empty"; fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== model-dispatch eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

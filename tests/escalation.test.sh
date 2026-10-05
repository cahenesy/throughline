#!/usr/bin/env bash
# escalation.test.sh — eval for TDD 0067 / FR-88, FR-87, FR-15, FR-39, NFR-3,
# NFR-4: /build-tdds Retry and escalation to the most capable model.
#
# EXECUTES the new models.sh / run-record.sh functions in a clean
#   env -i HOME=<tmp> PATH="$PATH" bash -c '. models.sh; . run-record.sh; …'
# shell against a fixture git repo (integration branch `master`, one committed
# TDD) whose runs are built through the real tl_run_init / tl_run_set_tdd /
# tl_verdict_write, and EXTRACTS + RUNS the tl:escalation-flags,
# tl:retry-candidates, tl:escalation-decide and tl:retry-begin blocks (and
# 0066's tl:models-confirm / tl:models-record with an escalation recorded) from
# skills/implement/SKILL.md the way the harness does: a fresh shell, nothing
# pre-sourced, no positional args, inputs only from TL_* env vars —
#   env -i HOME=<tmp> PATH="$PATH" CLAUDE_PLUGIN_ROOT=<repo> \
#     CLAUDE_CONFIG_DIR=<tmp>/.claude CLAUDE_CODE_SESSION_ID=<sid> TL_…=… bash <block>
# No network. Observation 14 (the live probe) runs only in the runtime-verify
# gate; here tests/live/escalation-probe.sh is checked statically and its exit
# classification is driven against a stub `claude` (THROUGHLINE_PROBE_CLAUDE).
# A missing marker, block or file is a FAIL (infra, L-001/L-011), never a skip.
# Observation numbers [1]–[14] (incl. 11b, 11c) are the TDD's Verification
# plan; [13] is the one text-only check (stated reason: it covers
# dispatch-tool behavior and the interactive menu, which an eval cannot run).
#
# Written red-first. Run: bash tests/escalation.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="$REPO/scripts/lib/models.sh"
RREC="$REPO/scripts/lib/run-record.sh"
SKILL="$REPO/skills/implement/SKILL.md"
PROBE="$REPO/tests/live/escalation-probe.sh"
GATE="$REPO/tests/implement-gate.test.sh"
RESULTS=""; ROOT=""
trap 'chmod -R u+w "$ROOT" 2>/dev/null; rm -rf "$ROOT" "$RESULTS"' EXIT
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
mk_transcript s-opus   claude-opus-5-5
mk_transcript s-fable  claude-fable-5-1

# The fixture repo: integration branch master, one committed TDD (nontrivial).
GR="$ROOT/repo"; LOGS="$GR/docs/tdd/.implement-logs"; SLUG=0099-x
REL="docs/tdd/$SLUG.md"; GTDD="$GR/$REL"
FIXOK=1
{ git init -q "$GR" && git -C "$GR" symbolic-ref HEAD refs/heads/master \
  && git -C "$GR" config user.email t@t.t && git -C "$GR" config user.name t \
  && git -C "$GR" config commit.gpgsign false \
  && mkdir -p "$GR/docs/tdd" && cp "$NONT" "$GTDD" \
  && git -C "$GR" add "$REL" && git -C "$GR" commit -qm "tdd 0099"; } \
  >/dev/null 2>&1 || { bad "infra: cannot build the fixture git repo"; FIXOK=0; }
BLOB=""
[ "$FIXOK" = 1 ] && BLOB="$(git -C "$GR" rev-parse "master:$REL" 2>/dev/null)"

# m [VAR=val ...] '<cmds>' — source models.sh + run-record.sh, then run <cmds>
# in a CLEAN shell (env -i). Sets OUT ERR RC NL (stdout newline count).
m() {
  local cmd="${!#}"
  local -a envs=("${@:1:$#-1}")
  env -i HOME="$H" PATH="$PATH" ${envs[@]+"${envs[@]}"} \
    bash -c ". $(q "$MODELS") || exit 97; . $(q "$RREC") || exit 98; $cmd" >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
  NL="$(wc -l <"$ROOT/out" | tr -d ' ')"
}
# runb <block> [VAR=val ...] — run an extracted block as the harness does.
runb() {
  local b="$1"; shift
  ( cd "$WORK" && exec env -i HOME="$H" PATH="$PATH" CLAUDE_PLUGIN_ROOT="$REPO" \
      CLAUDE_CONFIG_DIR="$H/.claude" "$@" bash "$b" ) >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
  NL="$(wc -l <"$ROOT/out" | tr -d ' ')"
}
# want <label> <want> — rc 0, stdout is exactly <want> (newline-terminated
# lines), no stderr.
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
# rc_quiet <label> <rc> — exactly that rc and no stdout.
rc_quiet() {
  if [ "$RC" -eq "$2" ] && [ ! -s "$ROOT/out" ]; then ok "$1"
  else bad "$1: rc=$RC (want $2) out='$OUT' err='$ERR'"; fi
}
out_line() {  # <label> <exact-line>
  if [ -s "$ROOT/out" ] && grep -qxF -- "$2" "$ROOT/out"; then ok "$1"
  else bad "$1: stdout has no line '$2' (rc=$RC out='$OUT' err='$ERR')"; fi
}
has_line() {  # <label> <file> <exact-line>
  if [ -f "$2" ] && grep -qxF -- "$3" "$2"; then ok "$1"
  else bad "$1: '$3' not a line of $2 ($( [ -f "$2" ] && tr '\n' '|' <"$2" || echo missing))"; fi
}
fail_closed() {  # <label> <stderr-substring>
  if [ "$RC" -ne 0 ] && [ ! -s "$ROOT/out" ] && printf '%s' "$ERR" | grep -qF -- "$2"; then ok "$1 (rc=$RC)"
  else bad "$1: rc=$RC out='$OUT' err='$ERR' want rc≠0, no stdout, stderr '$2'"; fi
}
HAVE_JQ=1
command -v jq >/dev/null 2>&1 || { bad "infra: jq not found (needed to validate JSON)"; HAVE_JQ=0; }
jf() {  # <label> <json-file> <key> <want>
  local got
  [ "$HAVE_JQ" = 1 ] || { bad "$1: infra: no jq"; return; }
  [ -f "$2" ] || { bad "$1: $2 missing"; return; }
  got="$(jq -r --arg k "$3" 'if has($k) then .[$k] else "<absent>" end' "$2" 2>&1)"
  [ "$got" = "$4" ] && ok "$1: $3=$4" || bad "$1: $3='$got' want '$4'"
}
WANTKEYS="$(printf '%s\n' parent effort effort_source build build_src build_model review \
  review_src review_model verify verify_src verify_model verify_class escalation \
  escalation_model escalation_reason halt_tdd_blob | LC_ALL=C sort | paste -sd' ' -)"
keys17() {  # <label> <sidecar>
  local got
  [ "$HAVE_JQ" = 1 ] || { bad "$1: infra: no jq"; return; }
  [ -f "$2" ] || { bad "$1: sidecar missing: $2"; return; }
  got="$(jq -r 'keys | join(" ")' "$2" 2>&1)" || { bad "$1: not valid JSON: $got"; return; }
  [ "$got" = "$WANTKEYS" ] && jq -e 'length == 17 and all(.[]; type == "string")' "$2" >/dev/null 2>&1 \
    && ok "$1: valid JSON, exactly the 17 string keys" || bad "$1: keys '$got' / $(cat "$2")"
}
# lsA <dir> — the dir's entries, sorted, space-joined ('<missing>' if absent).
lsA() { if [ -d "$1" ]; then ls -A "$1" | LC_ALL=C sort | paste -sd' ' -; else printf '<missing>'; fi; }

# extract <file> <marker> <out> — the first ```bash block after the marker
# line → <out>. rc 0 ok | 10 file unreadable/empty | 3 no marker | 4 no bash
# block after it | 5 block never closed | 6 block empty.
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
getblock() {  # <marker> <out> — rc 0 iff extracted from the skill
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
# A plugin root without run-record.sh: every new block must fail closed.
PART="$ROOT/partial"; mkdir -p "$PART/scripts/lib"
for l in plugin-root.sh models.sh plan-classifier.sh md.sh; do cp "$REPO/scripts/lib/$l" "$PART/scripts/lib/" 2>/dev/null; done

# mkrun <run> <status> <cause> <tf> <ci> <rv> <rev> [noblob] — a fixture run
# for $SLUG through the real setters: tl_run_init, tl_run_set_tdd, one
# tl_verdict_write per verdict that is not '-', then (unless noblob)
# tl_run_set_halt_blob; plus one report file per gate in the run dir root.
mkrun() {
  local run="$1" st="$2" cause="$3" i v g c
  local -a gates=(test-first ci-checks runtime-verify review) vs=("$4" "$5" "$6" "$7")
  [ "$FIXOK" = 1 ] || { bad "infra: no fixture repo for run $run"; return 1; }
  c="tl_run_init $(q "$GR") $run && tl_run_set_tdd $(q "$GR") $run $SLUG $st $(q "$cause")"
  for i in 0 1 2 3; do
    v="${vs[i]}"; [ "$v" = - ] && continue
    c="$c && tl_verdict_write $(q "$GR") $run $SLUG ${gates[i]} $v 'fixture evidence'"
  done
  [ "${8:-}" = noblob ] || c="$c && tl_run_set_halt_blob $(q "$GR") $run $SLUG $REL"
  m "$c"
  if [ "$RC" -ne 0 ]; then bad "infra: fixture run $run: rc=$RC err='$ERR'"; return 1; fi
  for g in build ci-checks verify review; do
    printf '%s report for %s\n' "$g" "$run" >"$LOGS/$run/$SLUG.$g.txt" || return 1
  done
}
decide() {  # <run> <requested> <auto> — tl_escalation_decide on the fixture
  m "tl_escalation_decide $(q "$GR") $1 $SLUG $REL $2 $3"
}

echo "[0] the new functions are defined after sourcing models.sh + run-record.sh"
( m 'for f in tl_escalation_outcome tl_escalation_flags tl_run_latest_run tl_run_retry_candidates tl_run_retry_begin tl_run_failed_report tl_run_set_halt_blob tl_escalation_decide tl_run_set_escalation tl_escalation_fellback_check; do [ "$(type -t "$f")" = function ] || echo "missing $f"; done'
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && ok "all ten functions defined; sourcing is silent" \
    || bad "rc=$RC out='$OUT' err='$ERR'"
) || true

echo "[1] tl_resolve_models / tl_model_sources with an escalation model"
( m "tl_resolve_models $(q "$NONT") claude-opus-5-5 fable"
  want "[1] nontrivial, parent opus, escalation fable" "build=fable review=fable verify=fable"
  m "tl_model_sources $(q "$NONT") claude-opus-5-5 fable"
  want "[1] sources: escalation ×3" "build_src=escalation review_src=escalation verify_src=escalation"
  m THROUGHLINE_REVIEW_MODEL=opus "tl_resolve_models $(q "$NONT") claude-opus-5-5 fable"
  want "[1] a review pin keeps its pin" "build=fable review=opus verify=fable"
  m THROUGHLINE_REVIEW_MODEL=opus "tl_model_sources $(q "$NONT") claude-opus-5-5 fable"
  want "[1] review_src=pin:THROUGHLINE_REVIEW_MODEL" "build_src=escalation review_src=pin:THROUGHLINE_REVIEW_MODEL verify_src=escalation"
  m "tl_resolve_models $(q "$MECH") claude-opus-5-5 fable"
  want "[1] mechanical TDD: verify keeps the light rule" "build=fable review=fable verify=sonnet"
  m "tl_model_sources $(q "$MECH") claude-opus-5-5 fable"
  want "[1] mechanical TDD: verify_src=light" "build_src=escalation review_src=escalation verify_src=light"
  m "tl_model_sources $(q "$MECH") claude-sonnet-5-5 fable"
  want "mechanical TDD, light parent: verify stays parent-cap" "build_src=escalation review_src=escalation verify_src=parent-cap"
  m THROUGHLINE_BUILD_MODEL=opus "tl_model_sources $(q "$NONT") claude-opus-5-5 fable"
  want "nontrivial verify follows a build pin, not the escalation" "build_src=pin:THROUGHLINE_BUILD_MODEL review_src=escalation verify_src=pin:THROUGHLINE_BUILD_MODEL"
  m CLAUDE_CODE_SUBAGENT_MODEL=haiku "tl_resolve_models $(q "$NONT") claude-opus-5-5 fable"
  want "CLAUDE_CODE_SUBAGENT_MODEL is a pin: escalation never replaces it" "build=haiku review=haiku verify=haiku"
  # An empty third arg is byte-identical to the two-arg (0064) call.
  for t in "$NONT" "$MECH" ''; do
    for p in claude-opus-5-5 claude-sonnet-5-5 ''; do
      for f in tl_resolve_models tl_model_sources; do
        m "$f $(q "$t") $(q "$p")"; cp "$ROOT/out" "$ROOT/out2"; r2=$RC
        m "$f $(q "$t") $(q "$p") ''"
        if [ "$r2" -eq 0 ] && [ "$RC" -eq 0 ] && [ -s "$ROOT/out" ] && cmp -s "$ROOT/out" "$ROOT/out2"; then
          ok "[1] $f '${t##*/}' '$p' '' == two-arg call"
        else bad "[1] $f '${t##*/}' '$p': 2-arg rc=$r2 '$(cat "$ROOT/out2")' vs 3-arg rc=$RC '$OUT'"; fi
      done
    done
  done
) || true

echo "[1+] CLAUDE_CODE_SUBAGENT_MODEL is what an inherited mechanical verify runs on"
( m CLAUDE_CODE_SUBAGENT_MODEL=opus "tl_resolve_models $(q "$MECH") claude-sonnet-5-5; tl_model_sources $(q "$MECH") claude-sonnet-5-5"
  want "light parent + mechanical TDD + CLAUDE_CODE_SUBAGENT_MODEL=opus → verify=opus verify_src=pin:CLAUDE_CODE_SUBAGENT_MODEL" \
"build=opus review=opus verify=opus
build_src=pin:CLAUDE_CODE_SUBAGENT_MODEL review_src=pin:CLAUDE_CODE_SUBAGENT_MODEL verify_src=pin:CLAUDE_CODE_SUBAGENT_MODEL"
  m CLAUDE_CODE_SUBAGENT_MODEL=opus "tl_model_sources $(q "$MECH") ''"
  want "unreadable parent + mechanical TDD: the env pin, not parent-cap" \
    "build_src=pin:CLAUDE_CODE_SUBAGENT_MODEL review_src=pin:CLAUDE_CODE_SUBAGENT_MODEL verify_src=pin:CLAUDE_CODE_SUBAGENT_MODEL"
  m CLAUDE_CODE_SUBAGENT_MODEL=opus "tl_resolve_models $(q "$MECH") claude-opus-5-5; tl_model_sources $(q "$MECH") claude-opus-5-5"
  want "above parent: verify is dispatched WITH the light model, so the env does not apply" \
"build=opus review=opus verify=sonnet
build_src=pin:CLAUDE_CODE_SUBAGENT_MODEL review_src=pin:CLAUDE_CODE_SUBAGENT_MODEL verify_src=light"
  m GROK_PLUGIN_ROOT=/tmp CLAUDE_CODE_SUBAGENT_MODEL=opus "tl_model_sources $(q "$MECH") ''"
  want "Grok ignores CLAUDE_CODE_SUBAGENT_MODEL" "build_src=parent review_src=parent verify_src=parent-cap"
) || true

echo "[2] tl_escalation_outcome"
( m "tl_escalation_outcome claude-opus-5-5 $(q "$NONT")"; want "[2] parent opus → escalated" "escalated fable"
  m "tl_escalation_outcome claude-fable-5-1 $(q "$NONT")"; want "[2] parent fable → already-top" "already-top fable"
  m "tl_escalation_outcome '' $(q "$NONT")"; want "[2] unreadable parent is never already-top" "escalated fable"
  m THROUGHLINE_BUILD_MODEL=opus THROUGHLINE_REVIEW_MODEL=opus "tl_escalation_outcome claude-opus-5-5 $(q "$MECH")"
  want "[2] build+review pinned, mechanical TDD → fell-back" "fell-back fable all judgment slots pinned"
  m THROUGHLINE_BUILD_MODEL=opus THROUGHLINE_REVIEW_MODEL=opus "tl_escalation_outcome claude-fable-5-1 $(q "$NONT")"
  want "all pinned is checked before already-top" "fell-back fable all judgment slots pinned"
  m THROUGHLINE_BUILD_MODEL=opus "tl_escalation_outcome claude-opus-5-5 $(q "$MECH")"
  want "one unpinned judgment slot left → escalated" "escalated fable"
  m THROUGHLINE_ESCALATION_MODEL=opus "tl_escalation_outcome claude-opus-5-5 $(q "$NONT")"
  want "override binding, parent in its family → already-top" "already-top opus"
  m THROUGHLINE_ESCALATION_MODEL=opus "tl_escalation_outcome claude-fable-5-1 $(q "$NONT")"
  want "override binding, parent in another family → escalated" "escalated opus"
  m 'tl_escalation_outcome'; want "no args → escalated, rc 0" "escalated fable"
) || true

echo "[3] tl_escalation_flags"
( m "tl_escalation_flags --escalate"; want "[3] --escalate" "requested=1 auto=1"
  m "tl_escalation_flags --no-auto-escalate"; want "[3] --no-auto-escalate" "requested=0 auto=0"
  m THROUGHLINE_AUTO_ESCALATE=0 "tl_escalation_flags ''"; want "[3] '' + THROUGHLINE_AUTO_ESCALATE=0" "requested=0 auto=0"
  m "tl_escalation_flags --escalatex"; want "[3] --escalatex is not --escalate" "requested=0 auto=1"
  m "tl_escalation_flags ''"; want "default" "requested=0 auto=1"
  m 'tl_escalation_flags'; want "no arg → default" "requested=0 auto=1"
  m THROUGHLINE_ESCALATE=1 "tl_escalation_flags ''"; want "THROUGHLINE_ESCALATE=1" "requested=1 auto=1"
  m THROUGHLINE_ESCALATE=yes THROUGHLINE_AUTO_ESCALATE=no "tl_escalation_flags ''"
  want "only 1 / 0 count for the env vars" "requested=0 auto=1"
  m "tl_escalation_flags $(q "docs/tdd/0099-x.md  --escalate"$'\n\t'"--no-auto-escalate")"
  want "tokens split on any whitespace" "requested=1 auto=0"
  m "tl_escalation_flags '--escalate=1 x--escalate --no-auto-escalatex'"
  want "only exact tokens count" "requested=0 auto=1"
  m "tl_escalation_flags '' --escalate"; want "only the args-text (\$1) is read" "requested=0 auto=1"
  mkdir -p "$ROOT/glob" && : >"$ROOT/glob/--escalate"
  m "cd $(q "$ROOT/glob") && tl_escalation_flags '*'"; want "a glob token is not expanded" "requested=0 auto=1"
) || true

echo "[4] fixture 4: failed/gate-fail, review FAIL, halt blob, TDD unchanged"
R4OK=0; mkrun r4 failed gate-fail PASS PASS - FAIL && R4OK=1
( [ "$R4OK" = 1 ] || { bad "[4] infra: no fixture 4"; exit 0; }
  [ -n "$BLOB" ] && ok "the TDD's integration blob is $BLOB" || bad "infra: no integration blob"
  jf "[4] tl_run_set_halt_blob" "$LOGS/r4/$SLUG.models.json" halt_tdd_blob "$BLOB"
  keys17 "[4] halt-blob sidecar" "$LOGS/r4/$SLUG.models.json"
  m "tl_run_retry_candidates $(q "$GR") r4"; want "[4] tl_run_retry_candidates lists the slug" "$SLUG"
  decide r4 0 1; want "[4] tl_escalation_decide → auto" auto
) || true

echo "[5] the TDD edited on master since the halt → none"
( [ "$R4OK" = 1 ] || { bad "[5] infra: no fixture 4"; exit 0; }
  printf '\nEdited after the halt.\n' >>"$GTDD"
  git -C "$GR" commit -qam "edit tdd" >/dev/null 2>&1 || { bad "[5] infra: cannot commit the edit"; exit 0; }
  decide r4 0 1; want "[5] edited TDD → none" none
  cp "$NONT" "$GTDD"
  git -C "$GR" commit -qam "revert tdd" >/dev/null 2>&1 || { bad "[5] infra: cannot commit the revert"; exit 0; }
  decide r4 0 1; want "a byte-for-byte revert counts as unchanged (accepted)" auto
  printf 'uncommitted\n' >>"$GTDD"
  decide r4 0 1; want "an uncommitted working-tree edit is not an integration change" auto
  git -C "$GR" checkout -q -- "$REL"
) || true

echo "[6] not auto-escalated"
( if mkrun r6b blocked design-escalation PASS PASS - FAIL; then
    m "tl_run_retry_candidates $(q "$GR") r6b"; silent "[6] blocked/design-escalation → not a retry candidate"
    decide r6b 0 1; want "[6] blocked/design-escalation → none" none
  fi
  if mkrun r6p failed gate-fail PASS PASS PASS PASS; then
    decide r6p 0 1; want "[6] failed with only PASS verdicts → none" none
  fi
  if mkrun r6n failed gate-fail PASS PASS - FAIL noblob; then
    decide r6n 0 1; want "[6] no halt blob → none" none
    m "tl_run_set_halt_blob $(q "$GR") r6n $SLUG docs/tdd/none.md"
    if [ "$RC" -eq 1 ] && [ ! -s "$ROOT/out" ] && [ "$ERR" = "run-record: cannot resolve docs/tdd/none.md on master" ] \
       && [ ! -e "$LOGS/r6n/$SLUG.models.json" ]; then ok "unresolvable path → rc 1, exact stderr, nothing written"
    else bad "set_halt_blob on a missing path: rc=$RC out='$OUT' err='$ERR'"; fi
    m "tl_run_set_halt_blob $(q "$GR") r6n $SLUG docs/tdd"
    rc_quiet "a tree (not a blob) is not a halt blob → rc 1" 1
    decide r6n 0 1; want "still none after the failed writes" none
  fi
  if mkrun r6v failed gate-fail PASS PASS BLOCKED -; then
    decide r6v 0 1; want "a BLOCKED verdict is not a FAIL → none" none
  fi
) || true

echo "[7] auto declined; requested"
( [ "$R4OK" = 1 ] || { bad "[7] infra: no fixture 4"; exit 0; }
  decide r4 0 0; want "[7] fixture 4 with auto=0 → none" none
  decide r4 1 0; want "requested wins over auto=0" requested
  if mkrun r7 pending '' - - - - noblob; then
    decide r7 1 1; want "[7] requested=1 on a clean fragment → requested" requested
    decide r7 0 1; want "clean fragment, not requested → none" none
  fi
  m "tl_escalation_decide $(q "$GR") r7 0097-none docs/tdd/0097-none.md 1 1"
  want "requested=1 with no fragment → requested" requested
  decide r4 2 1; rc_quiet "requested=2 → rc 2" 2
  decide r4 0 yes; rc_quiet "auto=yes → rc 2" 2
  m "tl_escalation_decide $(q "$GR") r4 $SLUG $REL 0"; rc_quiet "five args → rc 2" 2
  m "tl_escalation_decide $(q "$GR") r4 ../x $REL 0 1"; rc_quiet "slug ../x → rc 2" 2
  m "tl_escalation_decide relative/repo r4 $SLUG $REL 0 1"; rc_quiet "relative repo → rc 2" 2
) || true

echo "[8] tl_run_set_escalation: one line, sidecar, round-trip"
S8="$LOGS/r8/$SLUG.models.json"
( [ "$FIXOK" = 1 ] || { bad "[8] infra: no fixture repo"; exit 0; }
  m "tl_run_init $(q "$GR") r8 && tl_run_set_models $(q "$GR") r8 $SLUG $(q "$GTDD") claude-opus-5-5"
  [ "$RC" -eq 0 ] || { bad "[8] infra: run r8 / set_models: rc=$RC err='$ERR'"; exit 0; }
  VAL='dispatch error: "x" \ y'
  m "tl_run_set_escalation $(q "$GR") r8 $SLUG fell-back claude-nonexistent-0 $(q "$VAL")"
  want "[8] the outcome line, reason verbatim" \
    'throughline: 0099-x escalation=fell-back model=claude-nonexistent-0 reason=dispatch error: "x" \ y'
  keys17 "[8] sidecar after the escalation write" "$S8"
  jf "[8]" "$S8" escalation fell-back
  jf "[8]" "$S8" escalation_model claude-nonexistent-0
  jf "[8] reason round-trips (jq)" "$S8" escalation_reason "$VAL"
  jf "[8] 0066's build key intact" "$S8" build inherit
  jf "[8] 0066's build_model intact" "$S8" build_model claude-opus-5-5
  m "tl_run_get_model_field $(q "$GR") r8 $SLUG escalation_reason"
  [ "$RC" -eq 0 ] && [ "$OUT" = "$VAL" ] && ok "[8] reason round-trips (tl_run_get_model_field)" \
    || bad "[8] round-trip: rc=$RC got '$OUT'"
  cp "$S8" "$ROOT/s8.before"
  m "tl_run_set_escalation $(q "$GR") r8 $SLUG maybe fable"
  [ "$RC" -eq 2 ] && [ ! -s "$ROOT/out" ] && cmp -s "$S8" "$ROOT/s8.before" \
    && ok "[8] outcome maybe → rc 2, no line, sidecar unchanged" || bad "[8] maybe: rc=$RC out='$OUT' err='$ERR'"
  m "tl_run_set_escalation $(q "$GR") r8 $SLUG escalated ''"
  [ "$RC" -eq 2 ] && cmp -s "$S8" "$ROOT/s8.before" && ok "an empty model → rc 2, sidecar unchanged" \
    || bad "empty model: rc=$RC err='$ERR'"
  m "tl_run_set_escalation $(q "$GR") r8 $SLUG escalated fable"
  want "no reason → no reason= field" 'throughline: 0099-x escalation=escalated model=fable'
  jf "a later write without a reason clears it" "$S8" escalation_reason ""
  m "tl_run_set_escalation $(q "$GR") r8 $SLUG already-top fable"
  want "already-top line" 'throughline: 0099-x escalation=already-top model=fable'
  m "tl_run_set_escalation $(q "$GR") r-none $SLUG escalated fable"
  [ "$RC" -ne 0 ] && [ ! -s "$ROOT/out" ] && [ ! -e "$LOGS/r-none" ] \
    && ok "uninitialized run → rc≠0, no line, nothing created" || bad "uninitialized run: rc=$RC out='$OUT'"
) || true

echo "[9] tl_escalation_fellback_check"
( WT="$ROOT/wt"; EMPTY="$ROOT/rep.empty"; BLANK="$ROOT/rep.blank"; FULL="$ROOT/rep.full"
  : >"$EMPTY"; printf ' \n\t\n' >"$BLANK"; printf 'BUILD_RESULT: OK\n' >"$FULL"
  { git init -q "$WT" && git -C "$WT" config user.email t@t.t && git -C "$WT" config user.name t \
    && git -C "$WT" config commit.gpgsign false && git -C "$WT" commit -q --allow-empty -m base; } >/dev/null 2>&1 \
    || { bad "[9] infra: cannot build the worktree fixture"; exit 0; }
  BASE="$(git -C "$WT" rev-parse HEAD)"
  m "tl_escalation_fellback_check $(q "$EMPTY") $(q "$WT") $BASE review"; want "[9] review, empty report" "fell-back no report"
  m "tl_escalation_fellback_check $(q "$ROOT/absent.txt") $(q "$WT") $BASE verify"; want "verify, missing report" "fell-back no report"
  m "tl_escalation_fellback_check $(q "$BLANK") $(q "$WT") $BASE verify"; want "a whitespace-only report is empty" "fell-back no report"
  m "tl_escalation_fellback_check $(q "$EMPTY") $(q "$WT") $BASE implementer"
  want "[9] implementer, empty report, no commits" "fell-back no report, no commits"
  m "tl_escalation_fellback_check $(q "$FULL") $(q "$WT") $BASE implementer"; want "[9] non-empty report → ok" ok
  m "tl_escalation_fellback_check $(q "$FULL") $(q "$WT") $BASE review"; want "non-empty review report → ok" ok
  git -C "$WT" commit -q --allow-empty -m work >/dev/null 2>&1 || { bad "[9] infra: commit"; exit 0; }
  m "tl_escalation_fellback_check $(q "$EMPTY") $(q "$WT") $BASE implementer"
  want "[9] implementer, a commit, empty report → ok (a real failure)" ok
  m "tl_escalation_fellback_check $(q "$EMPTY") $(q "$WT") 0000000000000000000000000000000000000000 implementer"
  want "unusable base-sha: no claim about commits" "fell-back no report"
  m "tl_escalation_fellback_check $(q "$FULL") $(q "$WT") $BASE bogus"; rc_quiet "worker bogus → rc 2" 2
) || true

echo "[10] the extracted tl:escalation-flags block"
FB="$ROOT/blocks/flags.sh"
if getblock '<!-- tl:escalation-flags -->' "$FB"; then
  runb "$FB" TL_ARGS='--escalate'; want "[10] TL_ARGS='--escalate'" "requested=1 auto=1"
  runb "$FB" TL_ARGS=''; want "TL_ARGS='' (no arguments) is valid" "requested=0 auto=1"
  runb "$FB" TL_ARGS='docs/tdd/0099-x.md --no-auto-escalate'; want "path + --no-auto-escalate" "requested=0 auto=0"
  runb "$FB" TL_ARGS='' THROUGHLINE_ESCALATE=1; want "THROUGHLINE_ESCALATE=1 through the block" "requested=1 auto=1"
  runb "$FB"; fail_closed "[10] TL_ARGS unset → rc≠0, stderr names TL_ARGS" TL_ARGS
  runb "$FB" TL_ARGS='--escalate' CLAUDE_PLUGIN_ROOT="$PART"
  fail_closed "run-record.sh missing from the plugin root → fails closed" 'cannot source run-record.sh'
else bad "[10] infra: no tl:escalation-flags block to run"; fi

echo "[11] the extracted tl:retry-candidates block"
RCB="$ROOT/blocks/retry-candidates.sh"
if getblock '<!-- tl:retry-candidates -->' "$RCB"; then
  if mkrun r11 failed gate-fail PASS PASS - FAIL; then
    m "tl_run_latest_run $(q "$GR")"; want "tl_run_latest_run → the run latest points to" r11
    runb "$RCB" TL_REPO="$GR"
    want "[11] all-terminal fixture 4 + latest → run=<id> and the slug" "run=r11
$SLUG"
  fi
  NLR="$ROOT/nolatest"; mkdir -p "$NLR"
  runb "$RCB" TL_REPO="$NLR"; silent "[11] no latest → nothing, rc 0"
  m "tl_run_latest_run $(q "$NLR")"; rc_quiet "tl_run_latest_run with no latest → rc 1, no output" 1
  DG="$ROOT/dangle"; mkdir -p "$DG/docs/tdd/.implement-logs"; ln -s "$ROOT/gone" "$DG/docs/tdd/.implement-logs/latest"
  runb "$RCB" TL_REPO="$DG"; silent "dangling latest → nothing, rc 0"
  m "tl_run_latest_run $(q "$DG")"; rc_quiet "tl_run_latest_run with a dangling latest → rc 1" 1
  runb "$RCB"; fail_closed "TL_REPO unset → rc≠0, stderr names TL_REPO" TL_REPO
  runb "$RCB" TL_REPO="$GR" CLAUDE_PLUGIN_ROOT="$PART"
  fail_closed "run-record.sh missing from the plugin root → fails closed" 'cannot source run-record.sh'
else bad "[11] infra: no tl:retry-candidates block to run"; fi
( m "tl_run_retry_candidates $(q "$GR") ../x"; rc_quiet "tl_run_retry_candidates invalid run → rc 2" 2
  m "tl_run_retry_candidates $(q "$GR") r-none"; rc_quiet "tl_run_retry_candidates unknown run → rc 2" 2
  [ "$R4OK" = 1 ] && { m "tl_run_retry_candidates $(q "$GR") r6p"; want "the models sidecar and run.json are not fragments" "$SLUG"; }
) || true

echo "[11c] tl_run_failed_report"
( [ "$R4OK" = 1 ] || { bad "[11c] infra: no fixture 4"; exit 0; }
  m "tl_run_failed_report $(q "$GR") r4 $SLUG"; want "[11c] review FAIL → the review report" "$LOGS/r4/$SLUG.review.txt"
  m "tl_run_failed_report $(q "$GR") r6p $SLUG"; rc_quiet "[11c] every verdict PASS → rc 1, no output" 1
  if mkrun r11c failed gate-fail PASS PASS - FAIL; then
    rm -f "$LOGS/r11c/$SLUG.review.txt"
    m "tl_run_failed_report $(q "$GR") r11c $SLUG"; rc_quiet "[11c] the FAIL verdict's report deleted → rc 1" 1
  fi
  if mkrun r11d failed gate-fail FAIL - - FAIL; then
    m "tl_run_failed_report $(q "$GR") r11d $SLUG"; want "first FAIL in gate order; test-first → build" "$LOGS/r11d/$SLUG.build.txt"
  fi
  if mkrun r11e failed gate-fail PASS FAIL - -; then
    m "tl_run_failed_report $(q "$GR") r11e $SLUG"; want "ci-checks FAIL → ci-checks report" "$LOGS/r11e/$SLUG.ci-checks.txt"
  fi
  if mkrun r11f failed gate-fail PASS PASS FAIL -; then
    m "tl_run_failed_report $(q "$GR") r11f $SLUG"; want "runtime-verify FAIL → verify report" "$LOGS/r11f/$SLUG.verify.txt"
  fi
) || true

echo "[12] the extracted tl:escalation-decide block, then 0066's confirm/record blocks"
DB="$ROOT/blocks/decide.sh"; CB="$ROOT/blocks/confirm.sh"; RB="$ROOT/blocks/record.sh"
S4="$LOGS/r4/$SLUG.models.json"
getblock '<!-- tl:models-confirm -->' "$CB"; HAVE_CB=$?
getblock '<!-- tl:models-record -->' "$RB"; HAVE_RB=$?
if getblock '<!-- tl:escalation-decide -->' "$DB"; then
  if [ "$R4OK" = 1 ]; then
    runb "$DB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN=r4 TL_SLUG="$SLUG" TL_REQUESTED=0 TL_AUTO=1
    want "[12] fixture 4, auto, parent opus → trigger + outcome line" "trigger=auto
throughline: $SLUG escalation=escalated model=fable"
    jf "[12] sidecar records it" "$S4" escalation escalated
    jf "[12] sidecar records it" "$S4" escalation_model fable
    jf "the halt blob is kept" "$S4" halt_tdd_blob "$BLOB"
    keys17 "[12] sidecar" "$S4"
    if [ "$HAVE_CB" = 0 ]; then
      runb "$CB" CLAUDE_CODE_SESSION_ID=s-opus TL_QUEUE="$GTDD" TL_REPO="$GR" TL_RUN=r4
      out_line "[12] confirm shows the escalation line" '  escalation: escalated model=fable'
      out_line "[12] confirm shows implementer: fable [escalation]" '  implementer: fable [escalation]'
      want "confirm, exact" "models $SLUG: parent=claude-opus-5-5 effort=unknown (-; session-wide)
  implementer: fable [escalation]
  reviewer: fable [escalation]
  runtime-verify (nontrivial): fable [escalation]
  escalation: escalated model=fable"
      runb "$CB" CLAUDE_CODE_SESSION_ID=s-opus TL_QUEUE="$GTDD"
      want "without TL_REPO/TL_RUN the 0066 confirmation is unchanged" "models $SLUG: parent=claude-opus-5-5 effort=unknown (-; session-wide)
  implementer: inherit (claude-opus-5-5) [parent]
  reviewer: inherit (claude-opus-5-5) [parent]
  runtime-verify (nontrivial): inherit (claude-opus-5-5) [parent]"
    else bad "[12] infra: no tl:models-confirm block"; fi
    if [ "$HAVE_RB" = 0 ]; then
      runb "$RB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN=r4 TL_SLUG="$SLUG" TL_TDD="$GTDD"
      [ "$RC" -eq 0 ] && [ -z "$ERR" ] && ok "record block with escalated sidecar: rc 0" || bad "record: rc=$RC err='$ERR'"
      out_line "escalated → implementer dispatched on the escalation model" 'dispatch implementer model=fable'
      out_line "escalated → reviewer dispatched on the escalation model" 'dispatch reviewer model=fable'
      out_line "escalated → nontrivial verify on the escalation model" 'dispatch runtime-verify model=fable'
      has_line "the per-TDD log names the escalation" "$LOGS/r4/$SLUG.log" 'implementer model=fable (src=escalation)'
      jf "record block, escalated" "$S4" build_src escalation
      jf "record block, escalated" "$S4" build_model fable
      jf "record block keeps the outcome" "$S4" escalation escalated
      m "tl_run_set_escalation $(q "$GR") r4 $SLUG fell-back fable 'dispatch error: model unavailable'"
      want "fall-back recorded with its one line" \
        "throughline: $SLUG escalation=fell-back model=fable reason=dispatch error: model unavailable"
      runb "$RB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN=r4 TL_SLUG="$SLUG" TL_TDD="$GTDD"
      out_line "after fell-back the record block passes no escalation" 'dispatch implementer model='
      jf "after fell-back" "$S4" build inherit
      jf "after fell-back" "$S4" build_model claude-opus-5-5
      jf "after fell-back" "$S4" escalation fell-back
      jf "after fell-back" "$S4" escalation_reason 'dispatch error: model unavailable'
      if [ "$HAVE_CB" = 0 ]; then
        runb "$CB" CLAUDE_CODE_SESSION_ID=s-opus TL_QUEUE="$GTDD" TL_REPO="$GR" TL_RUN=r4
        out_line "confirm after fell-back: outcome line" '  escalation: fell-back model=fable'
        out_line "confirm after fell-back: the parent again" '  implementer: inherit (claude-opus-5-5) [parent]'
      fi
    else bad "[12] infra: no tl:models-record block"; fi
  fi
  if [ -f "$LOGS/r7/run.json" ]; then
    runb "$DB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN=r7 TL_SLUG="$SLUG" TL_REQUESTED=0 TL_AUTO=1
    silent "decide → none: the block prints nothing"
    [ ! -e "$LOGS/r7/$SLUG.models.json" ] && ok "decide → none: nothing written" || bad "a sidecar was written on none"
    runb "$DB" CLAUDE_CODE_SESSION_ID=s-fable TL_REPO="$GR" TL_RUN=r7 TL_SLUG="$SLUG" TL_REQUESTED=1 TL_AUTO=1
    want "requested from a fable parent → already-top" "trigger=requested
throughline: $SLUG escalation=already-top model=fable"
    runb "$DB" CLAUDE_CODE_SESSION_ID=s-opus THROUGHLINE_BUILD_MODEL=opus THROUGHLINE_REVIEW_MODEL=opus \
      TL_REPO="$GR" TL_RUN=r7 TL_SLUG="$SLUG" TL_REQUESTED=1 TL_AUTO=1
    want "requested with every judgment slot pinned → fell-back + reason" "trigger=requested
throughline: $SLUG escalation=fell-back model=fable reason=all judgment slots pinned"
    jf "the reason is recorded" "$LOGS/r7/$SLUG.models.json" escalation_reason 'all judgment slots pinned'
    runb "$DB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN=r7 TL_SLUG=0097-none TL_REQUESTED=1 TL_AUTO=1
    # The plan classifier names the missing file on stderr; stdout is exact.
    [ "$RC" -eq 0 ] && [ "$OUT" = "trigger=requested
throughline: 0097-none escalation=escalated model=fable" ] \
      && ok "requested for a TDD with no file → escalated (nontrivial by default)" \
      || bad "no-file TDD: rc=$RC out='$OUT' err='$ERR'"
  else bad "[12] infra: no run r7 (see [7])"; fi
  for miss in TL_REPO TL_RUN TL_SLUG TL_REQUESTED TL_AUTO; do
    args=(CLAUDE_CODE_SESSION_ID=s-opus)
    for v in "TL_REPO=$GR" "TL_RUN=r7" "TL_SLUG=0090-miss" "TL_REQUESTED=1" "TL_AUTO=1"; do
      [ "${v%%=*}" = "$miss" ] || args+=("$v")
    done
    runb "$DB" "${args[@]}"
    fail_closed "[12] $miss unset → rc≠0, stderr names $miss" "$miss"
  done
  [ ! -e "$LOGS/r7/0090-miss.models.json" ] && ok "a missing input writes nothing" || bad "written despite a missing input"
  runb "$DB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN=r7 TL_SLUG=../evil TL_REQUESTED=1 TL_AUTO=1
  [ "$RC" -ne 0 ] && [ ! -e "$LOGS/evil.models.json" ] && ok "slug ../evil → rc≠0, nothing written" || bad "bad slug: rc=$RC out='$OUT'"
  runb "$DB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN=r7 TL_SLUG="$SLUG" TL_REQUESTED=1 TL_AUTO=1 \
    CLAUDE_PLUGIN_ROOT="$PART"
  fail_closed "run-record.sh missing from the plugin root → fails closed" 'cannot source run-record.sh'
else bad "[12] infra: no tl:escalation-decide block to run"; fi

echo "[11b] tl_run_retry_begin archives the verdicts; the extracted tl:retry-begin block"
VD="$LOGS/r4/$SLUG"
( [ "$R4OK" = 1 ] || { bad "[11b] infra: no fixture 4"; exit 0; }
  [ "$(lsA "$VD")" = "ci-checks.json review.json test-first.json" ] && ok "precondition: three halt-time verdicts" \
    || bad "infra: verdict dir before retry: $(lsA "$VD")"
  m "tl_run_retry_begin $(q "$GR") r4 $SLUG"; want "[11b] prints the archive dir" "$VD/retry-1"
  [ "$(lsA "$VD")" = "retry-1" ] && ok "[11b] the verdict dir holds only retry-1/" || bad "[11b] verdict dir: $(lsA "$VD")"
  [ "$(lsA "$VD/retry-1")" = "ci-checks.json review.json test-first.json" ] \
    && ok "[11b] retry-1/ holds all three verdict files" || bad "[11b] retry-1: $(lsA "$VD/retry-1")"
  jf "[11b] fragment" "$LOGS/r4/$SLUG.json" status building
  jf "[11b] fragment" "$LOGS/r4/$SLUG.json" halt_cause ""
  m "tl_run_next_gate $(q "$GR") r4 $SLUG"; want "[11b] tl_run_next_gate → test-first" test-first
  [ -f "$LOGS/r4/$SLUG.review.txt" ] && ok "report .txt files in the run dir root are not moved" \
    || bad "the review report moved or vanished"
  decide r4 0 1; want "after retry-begin auto no longer applies (accepted)" none
  m "tl_run_retry_begin $(q "$GR") r4 $SLUG"; want "[11b] a second call → retry-2/" "$VD/retry-2"
  [ "$(lsA "$VD")" = "retry-1 retry-2" ] && [ "$(lsA "$VD/retry-1")" = "ci-checks.json review.json test-first.json" ] \
    && [ "$(lsA "$VD/retry-2")" = "" ] && ok "retry-1 kept, retry-2 empty" || bad "after 2nd: $(lsA "$VD") / $(lsA "$VD/retry-2")"
  if mkrun r11g failed gate-fail PASS PASS - FAIL; then
    : >"$LOGS/r11g/$SLUG/retry-1"   # a non-directory takes the archive name: mkdir fails
    m "tl_run_retry_begin $(q "$GR") r11g $SLUG"
    [ "$RC" -eq 1 ] && [ ! -s "$ROOT/out" ] && [ "$(lsA "$LOGS/r11g/$SLUG")" = "ci-checks.json retry-1 review.json test-first.json" ] \
      && [ "$(jq -r .status "$LOGS/r11g/$SLUG.json" 2>/dev/null)" = failed ] \
      && ok "mkdir fails → rc 1, nothing moved, status unchanged" \
      || bad "mkdir failure: rc=$RC out='$OUT' dir=$(lsA "$LOGS/r11g/$SLUG")"
  fi
  m "tl_run_retry_begin $(q "$GR") r-none $SLUG"
  [ "$RC" -ne 0 ] && [ ! -e "$LOGS/r-none" ] && ok "uninitialized run → rc≠0, nothing created" || bad "r-none: rc=$RC"
) || true
RBB="$ROOT/blocks/retry-begin.sh"
if getblock '<!-- tl:retry-begin -->' "$RBB"; then
  if mkrun r4b failed gate-fail PASS PASS - FAIL; then
    VB="$LOGS/r4b/$SLUG"
    runb "$RBB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN=r4b TL_SLUG="$SLUG"
    [ "$RC" -eq 0 ] && [ "$(sed -n 1p "$ROOT/out")" = "report=$LOGS/r4b/$SLUG.review.txt" ] \
      && ok "[11b] block: first line is report=<run-dir>/<slug>.review.txt" || bad "[11b] block: rc=$RC out='$OUT' err='$ERR'"
    want "block output, exact" "report=$LOGS/r4b/$SLUG.review.txt
archive=$VB/retry-1
implementer_report=$LOGS/r4b/$SLUG.review.prev.txt"
    cmp -s "$LOGS/r4b/$SLUG.review.txt" "$LOGS/r4b/$SLUG.review.prev.txt" \
      && ok "the implementer's copy of the failed report is byte-identical" || bad "no / different report copy"
    [ "$(lsA "$VB")" = "retry-1" ] && [ "$(lsA "$VB/retry-1")" = "ci-checks.json review.json test-first.json" ] \
      && ok "[11b] block: same archive result" || bad "[11b] block dir: $(lsA "$VB") / $(lsA "$VB/retry-1")"
    jf "[11b] block" "$LOGS/r4b/$SLUG.json" status building
    m "tl_run_next_gate $(q "$GR") r4b $SLUG"; want "[11b] block: next gate test-first" test-first
    runb "$RBB" CLAUDE_CODE_SESSION_ID=s-opus TL_REPO="$GR" TL_RUN=r4b TL_SLUG="$SLUG"
    want "a second block run: no FAIL verdict left → empty report=, retry-2" "report=
archive=$VB/retry-2
implementer_report="
  fi
  for miss in TL_REPO TL_RUN TL_SLUG; do
    args=()
    for v in "TL_REPO=$GR" "TL_RUN=r4b" "TL_SLUG=$SLUG"; do [ "${v%%=*}" = "$miss" ] || args+=("$v"); done
    runb "$RBB" "${args[@]}"
    fail_closed "[11b] $miss unset → rc≠0, stderr names $miss" "$miss"
  done
  runb "$RBB" TL_REPO="$GR" TL_RUN=r4b TL_SLUG="$SLUG" CLAUDE_PLUGIN_ROOT="$PART"
  fail_closed "run-record.sh missing from the plugin root → fails closed" 'cannot source run-record.sh'
else bad "[11b] infra: no tl:retry-begin block to run"; fi

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
place '<!-- tl:escalation-flags -->'  '^## 1\. '  '^## 2\. '
place '<!-- tl:retry-candidates -->'  '^## 3\. '  '^## 4\. '
place '<!-- tl:retry-begin -->'       '^## 3\. '  '^## 4\. '
place '<!-- tl:escalation-decide -->' '^## 4\. '  '^<!-- tl:models-confirm -->$'

echo "[13] text check: Retry, flags, fall-back dispatch rule"
( if [ -r "$SKILL" ] && [ -s "$SKILL" ]; then
    for s in 'Retry' '--escalate' '--no-auto-escalate' 'no model parameter' 'transient' \
             'tl_escalation_fellback_check' 'tl_run_set_halt_blob' 'tl_run_set_escalation'; do
      grep -qF -- "$s" "$SKILL" && ok "[13] SKILL.md contains '$s'" || bad "[13] SKILL.md lacks '$s'"
    done
    J="$(tr '\n' ' ' <"$SKILL" | tr -s ' ')"
    if [ -z "$J" ]; then bad "[13] infra: line-joined SKILL.md is empty"
    else
      case "$J" in
        *'(every slot)'*) bad "SKILL.md still says CLAUDE_CODE_SUBAGENT_MODEL applies to every slot" ;;
        *) ok "the env pin is not described as applying to every slot (line-joined)" ;;
      esac
      case "$J" in
        *'every worker dispatched without a model parameter'*) ok "the env pin applies to every worker dispatched without a model parameter" ;;
        *) bad "SKILL.md lacks 'every worker dispatched without a model parameter'" ;;
      esac
    fi
  else bad "[13] infra: $SKILL missing/unreadable/empty (L-001)"; fi
) || true

echo "[14] tests/live/escalation-probe.sh: static checks + exit classification against a stub claude"
( if [ -f "$PROBE" ] && [ -r "$PROBE" ] && [ -s "$PROBE" ]; then
    [ -x "$PROBE" ] && ok "[14] the probe is executable" || bad "[14] the probe is not executable"
    bash -n "$PROBE" 2>"$ROOT/p.err" && ok "[14] the probe parses (bash -n)" || bad "[14] bash -n: $(cat "$ROOT/p.err")"
    for s in 'stream-json' 'claude-nonexistent-0' 'tl_escalation_model' 'PROBE_BLOCKED' 'mktemp -d' 'trap'; do
      grep -qF -- "$s" "$PROBE" && ok "the probe names '$s'" || bad "the probe lacks '$s'"
    done
  else bad "[14] infra: $PROBE missing/unreadable/empty"; exit 0; fi
  if [ -r "$GATE" ]; then
    c="$(grep -c 'escalation-probe' "$GATE")"; grc=$?
    if [ "$grc" -ge 2 ] || [ -z "$c" ]; then bad "infra: grep rc=$grc on the aggregator"
    elif [ "$c" = 0 ]; then ok "the aggregator (ci-checks) never runs the live probe"
    else bad "tests/implement-gate.test.sh references the live probe"; fi
  else bad "infra: $GATE unreadable"; fi
  SB="$ROOT/stubbin"; mkdir -p "$SB"
  # The stub stands in for the harness: it reads the probe's prompt (last arg),
  # emits stream-json, and logs its argv. Every mode also emits a truncated
  # line, a subagent message (parent_tool_use_id set) and a parent reply that
  # carry the nonce: neither may count — only the Agent tool_result does.
  cat >"$SB/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
prompt="${!#}"
model="$(printf '%s' "$prompt" | sed -n 's/.*model "\([^"]*\)".*/\1/p' | head -n 1)"
nonce="$(printf '%s' "$prompt" | grep -oE 'Reply with exactly [0-9a-f]+' | head -n 1 | sed 's/.* //')"
ev() { printf '%s\n' "$1"; }
ev '{"type":"system","subtype":"init","model":"claude-opus-5-5"}'
ev '{"type":"assist'
if [ "$STUB_MODE" = none ]; then
  ev '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"'"$nonce"'"}]}}'
  ev '{"type":"result","subtype":"success","is_error":false}'; exit 0
fi
# Real shapes observed on Claude Code 2.1.289 (2026-10-05): a session that is
# rate-limited before it dispatches, and the async Agent tool (the tool_result
# is only an ack; the outcome is the task_notification; the reply is the
# subagent's SubagentHandback). The ack's prompt, task_started's prompt and
# the parent's own text all echo the nonce: none of them may count.
case "$STUB_MODE" in
  ratelimited)
    ev '{"type":"assistant","parent_tool_use_id":null,"error":"rate_limit","message":{"model":"<synthetic>","content":[{"type":"text","text":"Session limit reached, resets 7pm"}]}}'
    ev '{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"Session limit reached, resets 7pm"}'
    exit 0 ;;
  async*)
    ev '{"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_A","name":"Agent","input":{"subagent_type":"general-purpose","description":"probe","model":"'"$model"'","prompt":"Reply with exactly '"$nonce"'"}}]}}'
    if [ "$model" = claude-nonexistent-0 ]; then
      ev '{"type":"user","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_A","is_error":true,"content":"<tool_use_error>InputValidationError: expected one of sonnet|opus|haiku|fable</tool_use_error>"}]},"tool_use_result":"InputValidationError"}'
      ev '{"type":"result","subtype":"success","is_error":false}'; exit 0
    fi
    ev '{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"toolu_A","prompt":"Reply with exactly '"$nonce"'"}'
    ev '{"type":"user","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_A","content":[{"type":"text","text":"Async agent launched successfully.\nagentId: a1"}]}]},"tool_use_result":{"isAsync":true,"status":"async_launched","agentId":"a1","resolvedModel":"claude-fable-5-1","prompt":"Reply with exactly '"$nonce"'"}}'
    ev '{"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"done '"$nonce"'"}]}}'
    sm=claude-fable-5-1; [ "$STUB_MODE" = asyncsub ] && sm=claude-opus-5-5
    case "$STUB_MODE" in
      async|asyncsub)
        ev '{"type":"assistant","parent_tool_use_id":"toolu_A","message":{"model":"'"$sm"'","content":[{"type":"tool_use","id":"toolu_H","name":"SubagentHandback","input":{"message":"'"$nonce"'"}}]}}'
        ev '{"type":"system","subtype":"task_notification","task_id":"a1","tool_use_id":"toolu_A","status":"completed","summary":"This agent report was delivered to you as a message (its SubagentHandback call)."}' ;;
      asyncnoreply)
        ev '{"type":"assistant","parent_tool_use_id":"toolu_A","message":{"model":"claude-fable-5-1","content":[{"type":"tool_use","id":"toolu_H","name":"SubagentHandback","input":{"message":"something else"}}]}}'
        ev '{"type":"system","subtype":"task_notification","task_id":"a1","tool_use_id":"toolu_A","status":"completed","summary":"delivered"}' ;;
      asyncfail)
        ev '{"type":"assistant","parent_tool_use_id":"toolu_A","error":"rate_limit","message":{"model":"<synthetic>","content":[{"type":"text","text":"Fable 5.1 requires usage credits."}]}}'
        ev '{"type":"system","subtype":"task_notification","task_id":"a1","tool_use_id":"toolu_A","status":"failed","summary":"Agent terminated early due to an API error: Fable 5.1 requires usage credits. (error type rate_limit, HTTP 429, model sent to the API: claude-fable-5-1)"}' ;;
    esac
    ev '{"type":"result","subtype":"success","is_error":false}'
    exit 0 ;;
esac
dm=",\"model\":\"$model\""; [ "$STUB_MODE" = nomodel ] && dm=""
ev '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Agent","input":{"subagent_type":"general-purpose","description":"probe"'"$dm"',"prompt":"Reply with exactly '"$nonce"'"}}]}}'
ev '{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"content":[{"type":"text","text":"'"$nonce"'"}]}}'
p2=0; [ "$model" = claude-nonexistent-0 ] && p2=1
case "$STUB_MODE:$p2" in
  pass:0|subst:*|nomodel:*) res='{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"'"$nonce"'"}]}' ;;
  *) res='{"type":"tool_result","tool_use_id":"toolu_1","is_error":true,"content":"model unavailable"}' ;;
esac
ev '{"type":"user","parent_tool_use_id":null,"message":{"role":"user","content":['"$res"']}}'
ev '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"done '"$nonce"'"}]}}'
ev '{"type":"result","subtype":"success","is_error":false}'
STUB
  chmod +x "$SB/claude"
  probe() {  # <mode> — run the probe against the stub; sets RC OUT
    : >"$ROOT/stub.log"
    env -i HOME="$H" PATH="$SB:$PATH" THROUGHLINE_PROBE_CLAUDE="$SB/claude" STUB_MODE="$1" \
      STUB_LOG="$ROOT/stub.log" bash "$PROBE" >"$ROOT/out" 2>"$ROOT/err"
    RC=$?; OUT="$(cat "$ROOT/out" "$ROOT/err")"
  }
  probe pass
  [ "$RC" -eq 0 ] && ok "[14] P1 nonce + P2 error → exit 0" || bad "[14] pass: rc=$RC out='$OUT'"
  [ "$(grep -c . "$ROOT/stub.log")" = 2 ] && ok "two headless sessions" || bad "stub calls: $(cat "$ROOT/stub.log")"
  for a in '-p' '--model opus' '--output-format stream-json' '--verbose'; do
    grep -qF -- "$a" "$ROOT/stub.log" && ok "the probe passes '$a'" || bad "the probe does not pass '$a': $(cat "$ROOT/stub.log")"
  done
  grep -qF 'model "fable"' "$ROOT/stub.log" && grep -qF 'model "claude-nonexistent-0"' "$ROOT/stub.log" \
    && ok "P1 asks for tl_escalation_model, P2 for claude-nonexistent-0" || bad "probe models: $(cat "$ROOT/stub.log")"
  probe p1fail
  [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^PROBE_BLOCKED: ' \
    && ok "[14] P1 tool_result is_error (parent echoes the nonce) → exit 3 PROBE_BLOCKED" || bad "[14] p1fail: rc=$RC out='$OUT'"
  probe subst
  [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^PROBE_BLOCKED: ' \
    && ok "[14] P2 returned the nonce (silent substitution) → exit 3 PROBE_BLOCKED" || bad "[14] subst: rc=$RC out='$OUT'"
  probe none
  [ "$RC" -eq 1 ] && ok "[14] no tool_result (malformed run) → exit 1" || bad "[14] none: rc=$RC out='$OUT'"
  probe nomodel
  [ "$RC" -eq 1 ] && ok "no Agent dispatch on the stated model → exit 1" || bad "nomodel: rc=$RC out='$OUT'"
  probe async
  [ "$RC" -eq 0 ] && ok "[14] async shape: completed task_notification + SubagentHandback nonce on the requested family → exit 0" \
    || bad "[14] async: rc=$RC out='$OUT'"
  probe asyncfail
  [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^PROBE_BLOCKED: P1: .*requires usage credits' \
    && ok "[14] async shape: task_notification failed (usage credits; the parent echoes the nonce) → exit 3" \
    || bad "[14] asyncfail: rc=$RC out='$OUT'"
  probe asyncsub
  [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^PROBE_BLOCKED: .*ran as claude-opus-5-5.*substituted' \
    && ok "[14] async shape: the subagent answered on another family → exit 3 (silent substitution)" \
    || bad "[14] asyncsub: rc=$RC out='$OUT'"
  probe asyncnoreply
  [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^PROBE_BLOCKED: P1: ' \
    && ok "async shape: completed without the nonce in the reply (ack / task_started / parent echoes ignored) → exit 3" \
    || bad "asyncnoreply: rc=$RC out='$OUT'"
  probe asyncnonote
  [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'no task_notification' \
    && ok "async ack without a task_notification → exit 1, named" || bad "asyncnonote: rc=$RC out='$OUT'"
  probe ratelimited
  [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'rate/usage limit (transient)' \
    && ok "a session rate-limited before it dispatches → exit 1 naming a rate/usage limit (FR-41 transient)" \
    || bad "ratelimited: rc=$RC out='$OUT'"
  env -i HOME="$H" PATH="/usr/bin:/bin" THROUGHLINE_PROBE_CLAUDE="$ROOT/no-such-claude" bash "$PROBE" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "no claude binary → exit 1" || bad "missing claude: rc=$rc"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== escalation eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

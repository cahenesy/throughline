#!/usr/bin/env bash
# parent-session-check.test.sh — eval for TDD 0065 / FR-86, NFR-3, NFR-4.
#
# EXTRACTS the first fenced bash block after the line `<!-- tl:fr86-check -->`
# from /prd-author, /tdd-author, /build-tdds and /ux-author and RUNS each one the way the
# harness does: a fresh shell, nothing pre-sourced, no positional args —
#   env -i HOME=<tmp> PATH="$PATH" CLAUDE_PLUGIN_ROOT=<repo> \
#     CLAUDE_CONFIG_DIR=<tmp>/.claude [CLAUDE_CODE_SESSION_ID=<sid>] bash <block>
# against fixture transcripts (no network). A block that only works when an
# earlier call sourced something (the 0064-rev1 defect) fails here. A missing
# marker, block or skill file is a FAIL (infra, L-001), never a skip.
# Observation numbers [1]–[8] are the TDD's Verification plan.
#
# Written red-first. Run: bash tests/parent-session-check.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="$REPO/scripts/lib/models.sh"
NAMES=(prd-author tdd-author implement ux-author)
MARKER='<!-- tl:fr86-check -->'
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$RESULTS"' EXIT
H="$ROOT/home"; WORK="$ROOT/work"; TP="$H/.claude/projects/-tmp-proj"
mkdir -p "$TP" "$WORK" "$ROOT/blocks"
q() { printf '%q' "$1"; }

# The two warning lines, byte-exact (TDD 0065 Components & interfaces).
light_line()  { printf 'throughline: parent session model %s is on the light tier; judgment work in this session inherits it. Continue, or stop and change the model.' "$1"; }
unread_line() { printf 'throughline: parent session model could not be read (%s). Continue, or stop and change the model.' "$1"; }

# extract <skill-file> <out> — the first ```bash block after the marker line
# → <out>. rc 0 ok | 10 file unreadable/empty | 3 no marker | 4 no bash block
# after it | 5 block never closed | 6 block empty | other: awk failed.
extract() {
  { [ -r "$1" ] && [ -s "$1" ]; } || return 10
  awk -v M="$MARKER" '
    !seen && $0 == M                    { seen = 1; next }
    seen && !open && /^```bash[ \t]*$/  { open = 1; next }
    open && /^```[ \t]*$/               { closed = 1; exit }
    open                                { print }
    END { if (!seen) exit 3; if (!open) exit 4; if (!closed) exit 5 }
  ' "$1" >"$2" || return $?
  [ -s "$2" ] || return 6
}
# after_block <skill-file> <n> — the <n> lines after that block's closing fence.
after_block() {
  awk -v M="$MARKER" -v N="$2" '
    !seen && $0 == M                    { seen = 1; next }
    seen && !open && /^```bash[ \t]*$/  { open = 1; next }
    open && !closed && /^```[ \t]*$/    { closed = 1; next }
    closed { if (n++ >= N) exit; print }
  ' "$1"
}
# prose_para <skill-file> — the first paragraph after the block.
prose_para() { after_block "$1" 15 | awk 'NF { p = 1 } p && !NF { exit } p { print }'; }

# runb <block> [VAR=val ...] — run <block> as the harness would: `bash <file>`
# under env -i, no args, nothing pre-sourced, cwd $WORK. A VAR=val in the list
# overrides a default. Sets OUT ERR RC NL (stdout newline count).
runb() {
  local b="$1"; shift
  ( cd "$WORK" && exec env -i HOME="$H" PATH="$PATH" CLAUDE_PLUGIN_ROOT="$REPO" \
      CLAUDE_CONFIG_DIR="$H/.claude" "$@" bash "$b" ) >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
  NL="$(wc -l <"$ROOT/out" | tr -d ' ')"
}
# m [VAR=val ...] '<cmds>' — source models.sh then run <cmds> in a clean shell.
m() {
  local cmd="${!#}"
  local -a envs=("${@:1:$#-1}")
  env -i HOME="$H" PATH="$PATH" ${envs[@]+"${envs[@]}"} \
    bash -c ". $(q "$MODELS") || exit 97; $cmd" >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
  NL="$(wc -l <"$ROOT/out" | tr -d ' ')"
}
# want_line <label> <want> — rc 0, exactly one stdout line == <want>, no stderr.
want_line() {
  if [ "$RC" -eq 0 ] && [ "$NL" = 1 ] && [ "$OUT" = "$2" ] && [ -z "$ERR" ]; then ok "$1"
  else bad "$1: rc=$RC lines=$NL out='$OUT' err='$ERR' want '$2'"; fi
}
# want_silent <label> — rc 0, no stdout, no stderr.
want_silent() {
  if [ "$RC" -eq 0 ] && [ ! -s "$ROOT/out" ] && [ -z "$ERR" ]; then ok "$1"
  else bad "$1: rc=$RC out='$OUT' err='$ERR' want no output, rc 0"; fi
}
# want_fail_closed <label> <stderr-substring> — rc ≠ 0, no stdout, stderr has it.
want_fail_closed() {
  if [ "$RC" -ne 0 ] && [ ! -s "$ROOT/out" ] && [ -n "$ERR" ] \
     && printf '%s' "$ERR" | grep -qF -- "$2"; then ok "$1 (rc=$RC)"
  else bad "$1: rc=$RC out='$OUT' err='$ERR' want rc≠0 + '$2'"; fi
}

# mk_transcript <sid> <older> <newest> — a mid-session /model switch: the
# newest assistant line wins; a later <synthetic> line and a tool_use input's
# own "model" key are not the parent model.
mk_transcript() {
  { printf '%s\n' '{"type":"user","message":{"role":"user","content":"start"}}'
    printf '{"type":"assistant","message":{"model":"%s","content":[{"type":"text","text":"x"}]}}\n' "$2"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"/model"}}'
    printf '{"type":"assistant","message":{"model":"%s","content":[{"type":"tool_use","name":"Agent","input":{"model":"haiku","prompt":"x"}}]}}\n' "$3"
    printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[]}}'
  } >"$TP/$1.jsonl"
}
mk_transcript s-opus   claude-sonnet-5-5 claude-opus-5-5
mk_transcript s-fable  claude-haiku-4-5  claude-fable-5-1
mk_transcript s-sonnet claude-opus-5-5   claude-sonnet-5-5
mk_transcript s-haiku  claude-fable-5-1  claude-haiku-4-5

echo "[extract] extractor self-test: a bad skill fails closed"
( X="$ROOT/x"; mkdir -p "$X"
  printf '# s\n\nno marker\n```bash\necho hi\n```\n' >"$X/nomarker.md"
  printf '# s\n%s\n\ntext only\n' "$MARKER" >"$X/noblock.md"
  printf '%s\n```bash\necho hi\n' "$MARKER" >"$X/open.md"
  printf '%s\n```bash\n```\n' "$MARKER" >"$X/empty.md"
  printf 'a\n%s\n\n```\nnot bash\n```\n```bash\necho one\n```\n```bash\necho two\n```\n' "$MARKER" >"$X/good.md"
  for c in nomarker:3 noblock:4 open:5 empty:6 absent:10; do
    extract "$X/${c%%:*}.md" "$X/o"; rc=$?
    [ "$rc" = "${c#*:}" ] && ok "${c%%:*} → rc ${c#*:}" || bad "${c%%:*}: rc=$rc want ${c#*:}"
  done
  extract "$X/good.md" "$X/o" && [ "$(cat "$X/o")" = "echo one" ] \
    && ok "takes the first bash block after the marker" || bad "good fixture: '$(cat "$X/o" 2>/dev/null)'"
) || true

echo "[extract] the block after '$MARKER' is extracted from each skill"
BLK=(); GOT=()
for i in "${!NAMES[@]}"; do
  n="${NAMES[$i]}"; f="$REPO/skills/$n/SKILL.md"; BLK[i]="$ROOT/blocks/$n.sh"; GOT[i]=0
  extract "$f" "${BLK[i]}"; rc=$?
  case "$rc" in
    0)  GOT[i]=1; ok "$n: block extracted" ;;
    10) bad "infra: skills/$n/SKILL.md missing/unreadable/empty" ;;
    3)  bad "marker not found in skills/$n/SKILL.md" ;;
    4)  bad "no fenced bash block after the marker in skills/$n/SKILL.md" ;;
    5)  bad "the bash block after the marker is never closed in skills/$n/SKILL.md" ;;
    6)  bad "the bash block after the marker is empty in skills/$n/SKILL.md" ;;
    *)  bad "infra: extractor rc=$rc on skills/$n/SKILL.md" ;;
  esac
done

echo "[1] the extracted blocks are byte-identical (and are the TDD's block)"
cat >"$ROOT/want-block.sh" <<'EOF'
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/models.sh" || { echo "throughline: cannot source models.sh" >&2; exit 1; }
tl_fr86_message
EOF
if [ "$(IFS=; echo "${GOT[*]}")" = 1111 ]; then
  for i in 1 2 3; do
    cmp -s "${BLK[0]}" "${BLK[i]}" && ok "[1] ${NAMES[i]} block is byte-identical to prd-author's" \
      || bad "[1] ${NAMES[i]} block differs:"$'\n'"$(diff "${BLK[0]}" "${BLK[i]}")"
  done
  cmp -s "${BLK[0]}" "$ROOT/want-block.sh" && ok "[1] block bytes are the TDD's four lines" \
    || bad "[1] block differs from the TDD:"$'\n'"$(diff "$ROOT/want-block.sh" "${BLK[0]}")"
else bad "[1] infra: not every skill yielded a block (see [extract])"; fi

echo "[2]-[5] the extracted block, run in a fresh env -i shell"
for i in "${!NAMES[@]}"; do
  n="${NAMES[$i]}"; b="${BLK[i]}"
  [ "${GOT[i]}" = 1 ] || { bad "[2]-[5] $n: infra: no extracted block to run"; continue; }
  runb "$b" CLAUDE_CODE_SESSION_ID=s-opus;   want_silent "[2] $n: parent claude-opus-5-5 → no output, rc 0"
  runb "$b" CLAUDE_CODE_SESSION_ID=s-fable;  want_silent "[3] $n: parent claude-fable-5-1 → no output, rc 0"
  runb "$b" CLAUDE_CODE_SESSION_ID=s-sonnet; want_line "[4] $n: claude-sonnet-5-5 → light line" "$(light_line claude-sonnet-5-5)"
  runb "$b" CLAUDE_CODE_SESSION_ID=s-haiku;  want_line "[4] $n: claude-haiku-4-5 → light line" "$(light_line claude-haiku-4-5)"
  runb "$b";                                 want_line "[5] $n: session id unset → unreadable" "$(unread_line 'no session id')"
  runb "$b" CLAUDE_CODE_SESSION_ID=s-gone;   want_line "[5] $n: no transcript → unreadable" "$(unread_line 'transcript not found')"
done

echo "[6] plugin root unusable → the block fails closed"
EMPTY="$ROOT/emptyroot"; PART="$ROOT/partial"; BROKEN="$ROOT/broken"
mkdir -p "$EMPTY" "$PART/scripts/lib" "$BROKEN/scripts/lib"
cp "$REPO/scripts/lib/plugin-root.sh" "$PART/scripts/lib/"
cp "$REPO/scripts/lib/plugin-root.sh" "$MODELS" "$BROKEN/scripts/lib/"   # no plan-classifier.sh
for i in "${!NAMES[@]}"; do
  n="${NAMES[$i]}"; b="${BLK[i]}"
  [ "${GOT[i]}" = 1 ] || { bad "[6] $n: infra: no extracted block to run"; continue; }
  runb "$b" CLAUDE_CODE_SESSION_ID=s-sonnet CLAUDE_PLUGIN_ROOT="$EMPTY"
  want_fail_closed "[6] $n: CLAUDE_PLUGIN_ROOT=<empty dir>" 'cannot source'
  runb "$b" CLAUDE_CODE_SESSION_ID=s-sonnet CLAUDE_PLUGIN_ROOT=
  want_fail_closed "$n: no plugin root env" 'cannot source plugin-root.sh'
  runb "$b" CLAUDE_CODE_SESSION_ID=s-sonnet CLAUDE_PLUGIN_ROOT="$PART"
  want_fail_closed "$n: models.sh missing" 'cannot source models.sh'
  runb "$b" CLAUDE_CODE_SESSION_ID=s-sonnet CLAUDE_PLUGIN_ROOT="$BROKEN"
  want_fail_closed "$n: models.sh unsourceable (no plan-classifier.sh)" 'cannot source models.sh'
done

echo "[grok] the same block on Grok reads summary.json current_model_id"
WORKP="$(cd "$WORK" && pwd -P)"; GH="$ROOT/grokhome"
case "$WORKP" in
  *[!A-Za-z0-9/._-]*) bad "infra: fixture path has chars needing encoding: $WORKP" ;;
  *)
    enc="$(printf '%s' "$WORKP" | sed 's|/|%2F|g')"
    mkdir -p "$GH/sessions/$enc/g-light" "$GH/sessions/$enc/g-above"
    printf '%s\n' '{"current_model_id":"grok-4.5"}' >"$GH/sessions/$enc/g-light/summary.json"
    printf '%s\n' '{"current_model_id":"grok-4.6"}' >"$GH/sessions/$enc/g-above/summary.json"
    for i in "${!NAMES[@]}"; do
      n="${NAMES[$i]}"; b="${BLK[i]}"
      [ "${GOT[i]}" = 1 ] || { bad "[grok] $n: infra: no extracted block to run"; continue; }
      runb "$b" CLAUDE_PLUGIN_ROOT= GROK_PLUGIN_ROOT="$REPO" GROK_HOME="$GH" GROK_SESSION_ID=g-light
      want_line "$n: Grok parent grok-4.5 → light line" "$(light_line grok-4.5)"
      runb "$b" CLAUDE_PLUGIN_ROOT= GROK_PLUGIN_ROOT="$REPO" GROK_HOME="$GH" GROK_SESSION_ID=g-above
      want_silent "$n: Grok parent grok-4.6 → no output"
    done ;;
esac

echo "[fn] tl_fr86_message contract, called directly"
( m 'type -t tl_fr86_message'
  [ "$RC" -eq 0 ] && [ "$OUT" = function ] && ok "tl_fr86_message is defined by models.sh" \
    || bad "tl_fr86_message not defined: rc=$RC out='$OUT' err='$ERR'"
  m CLAUDE_CONFIG_DIR="$H/.claude" 'set -euo pipefail; tl_fr86_message'
  want_line "unreadable under set -euo pipefail → line, rc 0" "$(unread_line 'no session id')"
  m 'tl_parent_model() { return 1; }; tl_fr86_message'
  want_line "no stderr reason → (unknown)" "$(unread_line unknown)"
  m 'tl_parent_model() { echo "tac: noise" >&2; echo "tl_parent_model: transcript not found" >&2; return 1; }; tl_fr86_message'
  want_line "reason is the tl_parent_model: line, other stderr ignored" "$(unread_line 'transcript not found')"
  m 'tl_parent_model() { echo "claude-sonnet-%s"; }; tl_fr86_message'
  want_line "id printed literally (no format expansion)" "$(light_line 'claude-sonnet-%s')"
  m 'unset -f tl_model_tier; tl_fr86_message'
  [ "$RC" -eq 2 ] && [ ! -s "$ROOT/out" ] && printf '%s' "$ERR" | grep -q 'tl_fr86_message' \
    && ok "models.sh unusable (tier helper gone) → rc 2 + stderr" || bad "unusable: rc=$RC out='$OUT' err='$ERR'"
  m 'tl_parent_model() { echo claude-x-1; }; tl_model_tier() { echo bogus; }; tl_fr86_message'
  [ "$RC" -eq 2 ] && [ ! -s "$ROOT/out" ] && [ -n "$ERR" ] \
    && ok "unexpected tier → rc 2, no warning line" || bad "bogus tier: rc=$RC out='$OUT' err='$ERR'"
) || true

echo "[7] Continue / Stop / fail closed prose within 15 lines after the block"
for i in "${!NAMES[@]}"; do
  n="${NAMES[$i]}"; f="$REPO/skills/$n/SKILL.md"
  { [ -r "$f" ] && [ -s "$f" ]; } || { bad "[7] infra: skills/$n/SKILL.md missing/unreadable/empty"; continue; }
  win="$(after_block "$f" 15)"
  [ -n "$win" ] || { bad "[7] $n: no lines after the marker-tagged block (marker/block missing?)"; continue; }
  for w in Continue Stop 'fail closed'; do
    printf '%s\n' "$win" | grep -qF -- "$w" && ok "[7] $n: '$w'" || bad "[7] $n: '$w' not within 15 lines after the block"
  done
done
p0="$(prose_para "$REPO/skills/${NAMES[0]}/SKILL.md")"
p1="$(prose_para "$REPO/skills/${NAMES[1]}/SKILL.md")"
p2="$(prose_para "$REPO/skills/${NAMES[2]}/SKILL.md")"
p3="$(prose_para "$REPO/skills/${NAMES[3]}/SKILL.md")"
[ -n "$p0" ] && [ "$p0" = "$p1" ] && [ "$p0" = "$p2" ] && [ "$p0" = "$p3" ] \
  && printf '%s' "$p0" | grep -qF 'exactly two options' \
  && ok "the prose after the block is the same in all four skills" \
  || bad "prose after the block differs or is empty:"$'\n'"--- $p0"$'\n'"--- $p1"$'\n'"--- $p2"$'\n'"--- $p3"

echo "[placement] the check runs before the interview / lock / queue"
place() {  # <name> <after-ERE> <before-ERE>
  local f="$REPO/skills/$1/SKILL.md" a mk z
  { [ -r "$f" ] && [ -s "$f" ]; } || { bad "infra: skills/$1/SKILL.md unreadable"; return; }
  a="$(grep -nE -m1 -- "$2" "$f" | cut -d: -f1)"; z="$(grep -nE -m1 -- "$3" "$f" | cut -d: -f1)"
  mk="$(grep -nxF -m1 -- "$MARKER" "$f" | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$mk" ] && [ -n "$z" ] && [ "$a" -lt "$mk" ] && [ "$mk" -lt "$z" ]; then
    ok "$1: marker at line $mk, between '$2' ($a) and '$3' ($z)"
  else bad "$1: marker line '$mk' not between '$2' ('$a') and '$3' ('$z')"; fi
}
place prd-author '^0\. \*\*Resume check\.\*\*' '^1\. Explore the problem space'
place tdd-author '^## 0\. Resume check'        '^## 1\. '
place implement  '^## 1\. Source helpers'      '^## 2\. Lock'
place ux-author  '^0\. \*\*Resume \+ FR-86\.\*\*' '^1\. \*\*Preflight'

echo "[8] no vendor-page fetch text in the four skills"
( total=0; infra=0
  for n in "${NAMES[@]}"; do
    f="$REPO/skills/$n/SKILL.md"
    { [ -r "$f" ] && [ -s "$f" ]; } || { bad "[8] infra: skills/$n/SKILL.md missing/unreadable/empty"; infra=1; continue; }
    c="$(grep -c 'platform.claude.com\|docs.x.ai\|this turn' "$f")"; grc=$?
    if [ "$grc" -ge 2 ] || [ -z "$c" ]; then bad "[8] infra: grep rc=$grc on $n"; infra=1
    else total=$((total + c)); fi
  done
  [ "$infra" = 0 ] && [ "$total" = 0 ] && ok "[8] grep -c total is 0 across the four skills" \
    || bad "[8] total=$total infra=$infra"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== parent-session-check eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

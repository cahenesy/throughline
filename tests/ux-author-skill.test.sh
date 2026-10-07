#!/usr/bin/env bash
# ux-author-skill.test.sh — eval for TDD 0071 / FR-90..FR-100, FR-79, FR-81,
# FR-87: the /ux-author skill's tl: blocks and the ux-reviewer agent contract.
#
# EXTRACTS the first fenced bash block after each `<!-- tl:ux-… -->` marker in
# skills/ux-author/SKILL.md and RUNS it the way the harness does: a fresh
# shell, nothing pre-sourced, inputs from env only —
#   env -i HOME=<tmp> PATH=<path> CLAUDE_PLUGIN_ROOT=<repo> TL_REPO=<fixture> bash <block>
# against temp git repos (`master` + a fixture docs/PRD.md; no origin, so no
# network). A missing marker, block or file is a FAIL (L-001), never a skip.
# Every negated grep first asserts its file is readable (L-001/L-011); every
# temp dir is trap-cleaned (L-004). Observation numbers are the TDD's
# Verification plan (obs 4 and 5 live in parent-session-check.test.sh and
# plugin-root.test.sh [K]).
#
# Written red-first. Run: bash tests/ux-author-skill.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/ux-author/SKILL.md"
AGENT="$REPO/agents/ux-reviewer.md"
PRDA="$REPO/skills/prd-author/SKILL.md"
RESULTS=""; ROOT=""
cleanup() { [ -n "$ROOT" ] && rm -rf "$ROOT"; [ -n "$RESULTS" ] && rm -f "$RESULTS"; }
trap cleanup EXIT
RESULTS="$(mktemp)"; export RESULTS
ROOT="$(mktemp -d)"
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
readable() { [ -r "$1" ] && [ -s "$1" ]; }
H="$ROOT/home"; mkdir -p "$H" "$ROOT/blocks"
BASH_BIN="$(command -v bash)"
command -v python3 >/dev/null 2>&1 || bad "infra: python3 not found (fixtures)"
G() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=master -c commit.gpgsign=false "$@"; }

# extract <marker-name> <out> — first ```bash block after `<!-- tl:<name> -->`.
# rc 0 ok | 10 skill unreadable | 3 no marker | 4 no block | 5 unclosed | 6 empty.
extract() {
  readable "$SKILL" || return 10
  awk -v M="<!-- tl:$1 -->" '
    !seen && $0 == M                    { seen = 1; next }
    seen && !open && /^```bash[ \t]*$/  { open = 1; next }
    open && /^```[ \t]*$/               { closed = 1; exit }
    open                                { print }
    END { if (!seen) exit 3; if (!open) exit 4; if (!closed) exit 5 }
  ' "$SKILL" >"$2" || return $?
  [ -s "$2" ] || return 6
}

echo "[extract] the four tl: blocks are present in skills/ux-author/SKILL.md"
declare -A BLK=()
for n in fr86-check ux-preflight ux-validate ux-render; do
  f="$ROOT/blocks/$n.sh"; extract "$n" "$f"; rc=$?
  case "$rc" in
    0)  BLK[$n]="$f"; ok "tl:$n extracted" ;;
    10) bad "infra: $SKILL missing/unreadable/empty (tl:$n)" ;;
    3)  bad "marker <!-- tl:$n --> not found" ;;
    4)  bad "no fenced bash block after tl:$n" ;;
    5)  bad "the block after tl:$n is never closed" ;;
    6)  bad "the block after tl:$n is empty" ;;
    *)  bad "infra: extractor rc=$rc on tl:$n" ;;
  esac
done

# runb <name> <cwd> [VAR=val ...] — run an extracted block under env -i.
# Sets OUT ERR RC. PATH defaults to $PATH; override with PATH=… in the list.
runb() {
  local n="$1" cwd="$2"; shift 2
  local b="${BLK[$n]:-}"
  if [ -z "$b" ]; then OUT=""; ERR="no extracted block tl:$n"; RC=99; return; fi
  ( cd "$cwd" && exec env -i HOME="$H" PATH="$PATH" CLAUDE_PLUGIN_ROOT="$REPO" "$@" \
      "$BASH_BIN" "$b" ) >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
}

echo "[contract] each block reads its inputs fail-loud and sources its own helpers"
for n in ux-preflight ux-validate ux-render; do
  b="${BLK[$n]:-}"; [ -n "$b" ] || { bad "[contract] tl:$n: no block"; continue; }
  runb "$n" "$ROOT"
  [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -q 'TL_REPO' \
    && ok "[contract] tl:$n with TL_REPO unset → rc $RC naming TL_REPO" \
    || bad "[contract] tl:$n TL_REPO unset: rc=$RC err='$ERR'"
  grep -qF 'scripts/lib/plugin-root.sh' "$b" && grep -qF 'tl_plugin_root' "$b" \
    && grep -qF 'scripts/lib/ux.sh' "$b" \
    && ok "[contract] tl:$n sources plugin-root.sh and ux.sh via tl_plugin_root" \
    || bad "[contract] tl:$n does not source its own helpers"
  runb "$n" "$ROOT" TL_REPO="$ROOT" TL_SCREENS=a CLAUDE_PLUGIN_ROOT="$ROOT/nope"
  [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -q 'cannot source' \
    && ok "[contract] tl:$n with an unusable plugin root fails closed" \
    || bad "[contract] tl:$n bad plugin root: rc=$RC err='$ERR'"
done

# --- fixtures -----------------------------------------------------------------
BLK1='- **FR-1 [UI] Login.** The user logs in.
  Details here.'
PRD_UI="# PRD

## Requirements
$BLK1
- **FR-2 API.** Not UI.
"
PRD_NOUI="# PRD

## Requirements
- **FR-2 API.** Not UI.
"
# mkidx.py <repo> <screens-json> — a schema-1 index mapping FR-1 to the screens
# (default.html each), with FR-1's current block hash from the repo's PRD.
cat >"$ROOT/mkidx.py" <<'PY'
import hashlib, json, os, sys
d, screens = sys.argv[1], json.loads(sys.argv[2])
lines = open(os.path.join(d, "docs/PRD.md")).read().split("\n")
s = next(i for i, l in enumerate(lines) if l.startswith("- **FR-1 [UI]"))
e = next(i for i in range(s + 1, len(lines)) if lines[i].startswith("- **FR-") or lines[i].startswith("#"))
h = hashlib.sha256("\n".join(l.rstrip() for l in lines[s:e]).encode()).hexdigest()
idx = {"schema": 1, "prd_rev": "abc1234", "platforms": ["web"],
       "viewports": [{"name": "desktop", "width": 1280, "height": 800}],
       "fidelity": "mid", "delegates": [],
       "design_system": {"tokens": None, "adr": None, "source": "none"},
       "requirements": [{"id": "FR-1", "hash": h, "screens": screens}],
       "screens": [], "flow": screens}
for sid in screens:
    os.makedirs(os.path.join(d, "docs/ux/screens", sid), exist_ok=True)
    open(os.path.join(d, "docs/ux/screens", sid, "default.html"), "w").write(
        "<!doctype html><html><head><title>%s</title></head><body><h1>%s</h1></body></html>\n" % (sid, sid))
    idx["screens"].append({"id": sid, "title": "Screen " + sid, "baseline": "none (new screen)",
        "states": [{"name": "default", "file": "screens/%s/default.html" % sid}] +
                  [{"name": n, "na": "a static page with no data load"} for n in ("empty", "loading", "error")]})
open(os.path.join(d, "docs/ux/index.json"), "w").write(json.dumps(idx, indent=2) + "\n")
PY
# mkrepo <dir> <prd-text> — a git repo on master with docs/PRD.md committed.
mkrepo() {
  mkdir -p "$1/docs"; G init -q "$1"; printf '%s' "$2" >"$1/docs/PRD.md"
  G -C "$1" add -A && G -C "$1" commit -qm "PRD" || bad "infra: mkrepo $1 failed"
}
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
treesum() { (cd "$1" && find docs -type f -print0 | sort -z | xargs -0 sha256sum) 2>/dev/null; }
ux_branches() { G -C "$1" branch --list 'docs/ux/*'; }

NO_UI_LINE='no UI-bearing requirements in this PRD delta'

echo "[1] preflight, no [UI] → the no-UI line, rc 0, no docs/ux branch"
R1="$ROOT/r1"; mkrepo "$R1" "$PRD_NOUI"; s0="$(sha "$R1/docs/PRD.md")"
runb ux-preflight "$R1" TL_REPO="$R1"
[ "$RC" -eq 0 ] && [ "$OUT" = "$NO_UI_LINE" ] \
  && ok "[1] exactly '$NO_UI_LINE', rc 0" || bad "[1] rc=$RC out='$OUT' err='$ERR'"
[ -d "$R1/.git" ] && [ -z "$(ux_branches "$R1")" ] && ok "[1] no docs/ux/* branch created" \
  || bad "[1] docs/ux branch present: '$(ux_branches "$R1")'"
[ -n "$s0" ] && [ "$s0" = "$(sha "$R1/docs/PRD.md")" ] && ok "[9] preflight left docs/PRD.md bytes unchanged" \
  || bad "[9] docs/PRD.md changed by preflight"

echo "[2] preflight delta"
R2="$ROOT/r2"; mkrepo "$R2" "$PRD_UI"
runb ux-preflight "$R2" TL_REPO="$R2"
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf 'new\tFR-1\tLogin')" ] \
  && ok "[2] no merged index → new<TAB>FR-1<TAB>Login" || bad "[2] no index: rc=$RC out='$OUT' err='$ERR'"
printf '%s' "$OUT" | grep -q 'FR-1' && ok "[7b] preflight output names FR-1 (the draft plan's input)" \
  || bad "[7b] preflight output does not name FR-1: '$OUT'"
python3 -I "$ROOT/mkidx.py" "$R2" '["login"]' && G -C "$R2" add -A && G -C "$R2" commit -qm "ux set" \
  || bad "infra: merged index fixture"
runb ux-preflight "$R2" TL_REPO="$R2"
[ "$RC" -eq 0 ] && [ "$OUT" = "$NO_UI_LINE" ] \
  && ok "[2] merged index covering FR-1's hash → the no-UI line" || bad "[2] covered: rc=$RC out='$OUT' err='$ERR'"
sed -i 's/Details here\./Details changed./' "$R2/docs/PRD.md" && G -C "$R2" commit -qam "edit FR-1" \
  || bad "infra: FR-1 edit"
runb ux-preflight "$R2" TL_REPO="$R2"
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf 'changed\tFR-1\tLogin')" ] \
  && ok "[2] FR-1 edited → changed<TAB>FR-1<TAB>Login" || bad "[2] changed: rc=$RC out='$OUT' err='$ERR'"
printf '\nmore\n' >>"$R2/docs/PRD.md"; s0="$(sha "$R2/docs/PRD.md")"
runb ux-preflight "$R2" TL_REPO="$R2"
[ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -qF 'commit docs/PRD.md first' \
  && ok "[2] uncommitted PRD edit → rc 1 'commit docs/PRD.md first'" || bad "[2] dirty: rc=$RC out='$OUT' err='$ERR'"
[ "$s0" = "$(sha "$R2/docs/PRD.md")" ] && ok "[9] the dirty PRD's bytes are unchanged" || bad "[9] dirty PRD changed"
G -C "$R2" checkout -q -- docs/PRD.md
G -C "$R2" checkout -qb docs/prd/next && printf '\n- **FR-3 [UI] Cart.** Carts.\n' >>"$R2/docs/PRD.md" \
  && G -C "$R2" commit -qam "unmerged PRD edit" || bad "infra: branch edit"
runb ux-preflight "$R2" TL_REPO="$R2"
[ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -qF 'differs from the merged PRD' \
  && ok "[2] committed edit not on master → rc 1 'differs from the merged PRD'" \
  || bad "[2] unmerged: rc=$RC out='$OUT' err='$ERR'"

echo "[3] the /prd-author rules /ux-author reads by reference exist"
if readable "$PRDA" && readable "$SKILL"; then
  for h in 'Interrogator discipline (FR-75)' 'Rubric co-creation (FR-77)'; do
    grep -qxF "### $h" "$PRDA" && ok "[3] prd-author has '### $h'" || bad "[3] prd-author lacks '### $h'"
    grep -qF "$h" "$SKILL" && ok "[3] ux-author names '$h'" || bad "[3] ux-author does not name '$h'"
  done
else bad "[3] infra: $PRDA or $SKILL unreadable"; fi

echo "[3b] resume carries the approved plan (FR-100)"
R3="$ROOT/r3"; mkrepo "$R3" "$PRD_UI"; PD="$ROOT/pdata"; mkdir -p "$PD"
PLAN='| login | Login | default, empty: n/a: no list, loading, error | FR-1 |'
( cd "$R3" && env -i HOME="$H" PATH="$PATH" CLAUDE_PLUGIN_DATA="$PD" PLAN="$PLAN" "$BASH_BIN" -c '
    . "$1/scripts/lib/drafts.sh" || exit 97
    tl_draft_init ux-author || exit 96
    tl_draft_append_elicit ux-author decision "screen plan" "approved screen plan" "$PLAN" || exit 95
    tl_draft_exists ux-author || exit 94
    tl_draft_read ux-author' _ "$REPO" ) >"$ROOT/out" 2>"$ROOT/err"; RC=$?
[ "$RC" -eq 0 ] && grep -qF 'login | Login' "$ROOT/out" && grep -qF '"decision"' "$ROOT/out" \
  && ok "[3b] tl_draft_exists ux-author rc 0; tl_draft_read holds the plan decision" \
  || bad "[3b] rc=$RC out='$(cat "$ROOT/out")' err='$(cat "$ROOT/err")'"
if readable "$SKILL"; then
  grep -qF 'tl_draft_append_elicit ux-author decision' "$SKILL" && grep -qF 'tl_draft_exists ux-author' "$SKILL" \
    && ok "[3b] the skill persists the plan as a ux-author decision and checks for a draft" \
    || bad "[3b] the skill lacks 'tl_draft_append_elicit ux-author decision' / 'tl_draft_exists ux-author'"
else bad "[3b] infra: $SKILL unreadable"; fi

echo "[6] validate block"
R6="$ROOT/r6"; mkrepo "$R6" "$PRD_UI"; python3 -I "$ROOT/mkidx.py" "$R6" '["login"]' || bad "infra: r6 index"
runb ux-validate "$R6" TL_REPO="$R6"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^ok 1 screens, 1 requirements, screenshots 0/1$' \
  && ok "[6] clean set → rc 0, 'ok … screenshots 0/1'" || bad "[6] clean: rc=$RC out='$OUT' err='$ERR'"
printf '<!doctype html><html><head><script src="https://cdn.example.com/x.js"></script></head><body>x</body></html>\n' \
  >"$R6/docs/ux/screens/login/default.html"
runb ux-validate "$R6" TL_REPO="$R6"
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '^ux-invalid:' \
  && ok "[6] CDN <script> → rc 1 with a ux-invalid: line" || bad "[6] cdn: rc=$RC out='$OUT' err='$ERR'"

echo "[7] render block: degrade and scoping"
NOB="$ROOT/nobrowser"; mkdir -p "$NOB"
for t in bash sh env python3 git grep sed awk cat dirname mkdir rm ls head tail tr timeout cut mktemp base64; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOB/$t"
done
for b in chromium chromium-browser google-chrome chrome; do [ -e "$NOB/$b" ] && bad "infra: $b leaked into $NOB"; done
PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
R7="$ROOT/r7"; mkrepo "$R7" "$PRD_UI"; python3 -I "$ROOT/mkidx.py" "$R7" '["a","b"]' || bad "infra: r7 index"
for s in a b; do printf '%s' "$PNG_B64" | base64 -d >"$R7/docs/ux/screens/$s/default@desktop.png"; done
printf 'old-b-bytes' >>"$R7/docs/ux/screens/b/default@desktop.png"
G -C "$R7" add -A && G -C "$R7" commit -qm "merged a+b" || bad "infra: r7 commit"
pre="$(treesum "$R7")"; bsha="$(sha "$R7/docs/ux/screens/b/default@desktop.png")"; isha="$(sha "$R7/docs/ux/index.json")"
runb ux-render "$R7" TL_REPO="$R7"
[ "$RC" -ne 0 ] && [ "$pre" = "$(treesum "$R7")" ] && ok "[7] TL_SCREENS unset → rc $RC, nothing changed" \
  || bad "[7] unset: rc=$RC err='$ERR' (or files changed)"
runb ux-render "$R7" TL_REPO="$R7" TL_SCREENS=
[ "$RC" -ne 0 ] && [ "$pre" = "$(treesum "$R7")" ] && ok "[7] TL_SCREENS empty → rc $RC, nothing changed" \
  || bad "[7] empty: rc=$RC err='$ERR' (or files changed)"
runb ux-render "$R7" TL_REPO="$R7" TL_SCREENS=' ' PATH="$NOB"
[ "$RC" -ne 0 ] && [ "$pre" = "$(treesum "$R7")" ] && ok "[7] TL_SCREENS blank → rc $RC, nothing changed" \
  || bad "[7] blank: rc=$RC err='$ERR' (or files changed)"
runb ux-render "$R7" TL_REPO="$R7" TL_SCREENS=a PATH="$NOB"
last="$(printf '%s\n' "$OUT" | tail -n 1)"
[ "$RC" -eq 4 ] && [ "$last" = 'screenshots not rendered: no headless Chrome on PATH' ] \
  && ok "[7] no browser, TL_SCREENS=a → rc 4 + the no-Chrome status line" \
  || bad "[7] degrade: rc=$RC out='$OUT' err='$ERR'"
[ -n "$bsha" ] && [ "$bsha" = "$(sha "$R7/docs/ux/screens/b/default@desktop.png")" ] \
  && [ "$isha" = "$(sha "$R7/docs/ux/index.json")" ] \
  && ok "[7] b's PNG bytes and the index are unchanged (FR-99 scoping)" \
  || bad "[7] b's PNG or the index changed"
[ ! -e "$R7/docs/ux/screens/a/default@desktop.png" ] && [ -r "$R7/docs/ux/screens/a/default.html" ] \
  && ok "[7] a's stale PNG was cleared, its HTML kept" || bad "[7] a's PNG survived or its HTML is gone"
cat >"$ROOT/stub" <<EOF
#!$BASH_BIN
for a in "\$@"; do case "\$a" in --screenshot=*) printf '%s' '$PNG_B64' | base64 -d >"\${a#--screenshot=}" ;; esac; done
exit 0
EOF
chmod +x "$ROOT/stub"
runb ux-render "$R7" TL_REPO="$R7" TL_SCREENS=a PATH="$NOB" THROUGHLINE_UX_BROWSER="$ROOT/stub"
last="$(printf '%s\n' "$OUT" | tail -n 1)"
[ "$RC" -eq 0 ] && [ "$last" = 'screenshots: complete' ] && [ -s "$R7/docs/ux/screens/a/default@desktop.png" ] \
  && ok "[7] stub browser, TL_SCREENS=a → rc 0, 'screenshots: complete'" || bad "[7] stub: rc=$RC out='$OUT' err='$ERR'"
[ "$bsha" = "$(sha "$R7/docs/ux/screens/b/default@desktop.png")" ] \
  && ok "[7] b's PNG bytes unchanged after rendering a" || bad "[7] b's PNG changed after rendering a"

echo "[7b] the draft screen plan (step 1b) precedes any structured question"
if readable "$SKILL"; then
  pf="$(grep -nxF -m1 '<!-- tl:ux-preflight -->' "$SKILL" | cut -d: -f1)"
  sb="$(grep -nE -m1 '^1b\. ' "$SKILL" | cut -d: -f1)"
  sq="$(awk -v P="${pf:-0}" 'NR > P && /structured question/ { print NR; exit }' "$SKILL")"
  if [ -n "$pf" ] && [ -n "$sb" ] && [ -n "$sq" ] && [ "$pf" -lt "$sb" ] && [ "$sb" -lt "$sq" ]; then
    ok "[7b] preflight ($pf) < step 1b ($sb) < first structured question after it ($sq)"
  else bad "[7b] order: preflight='$pf' 1b='$sb' first-question='$sq'"; fi
else bad "[7b] infra: $SKILL unreadable"; fi

echo "[8] ux-reviewer contract"
if readable "$AGENT"; then
  for w in 'name: ux-reviewer' 'tools: Read, Grep, Glob, Bash' 'model: inherit' 'UX_REVIEW: PASS' 'UX_REVIEW: BLOCK' \
           'tl_ux_validate' 'tl_ux_delta' 'self-reported' 'report-file path' 'did not author'; do
    grep -qF -- "$w" "$AGENT" && ok "[8] agent names '$w'" || bad "[8] agent lacks '$w'"
  done
  v="$(grep -nF -m1 'tl_ux_validate' "$AGENT" | cut -d: -f1)"; d="$(grep -nF -m1 'tl_ux_delta' "$AGENT" | cut -d: -f1)"
  [ -n "$v" ] && [ -n "$d" ] && [ "$v" -lt "$d" ] && ok "[8] tl_ux_validate runs before the blocking checks" \
    || bad "[8] tl_ux_validate ($v) not before tl_ux_delta ($d)"
  hits="$(grep -nEi 'AskUserQuestion|claude -p|grok -p' "$AGENT")"
  [ -z "$hits" ] && ok "[8] agent names no vendor tool/CLI (FR-81)" || bad "[8] vendor names in agent: $hits"
else bad "[8] infra: $AGENT missing/unreadable/empty"; fi
if readable "$SKILL"; then
  grep -qF 'agents/ux-reviewer.md' "$SKILL" && grep -qF 'no model parameter' "$SKILL" \
    && ok "[8] the skill dispatches agents/ux-reviewer.md with no model parameter (FR-87)" \
    || bad "[8] the skill lacks the ux-reviewer dispatch / no-model-parameter rule"
  hits="$(grep -nE '\bTask tool\b|AskUserQuestion|claude -p|grok -p' "$SKILL")"
  [ -z "$hits" ] && ok "[5] the skill names actions, not vendor tools (FR-81)" || bad "[5] vendor names in skill: $hits"
else bad "[8] infra: $SKILL unreadable"; fi

echo "[9] every docs/PRD.md use in the extracted blocks is read-only"
for n in ux-preflight ux-validate ux-render; do
  b="${BLK[$n]:-}"; readable "$b" || { bad "[9] infra: tl:$n block unreadable"; continue; }
  w="$(grep -nE 'PRD\.md' "$b" | grep -nE '>[[:space:]]*"?[^ ]*PRD\.md|sed -i|tee |mv |cp |rm |truncate|git (add|commit|checkout)' )"
  u="$(grep -nE 'PRD\.md' "$b" | grep -vE 'tl_ux_(delta|ui_reqs)|status --porcelain|rev-parse|throughline:')"
  [ -z "$w" ] && [ -z "$u" ] && ok "[9] tl:$n: PRD.md appears only in reads / messages" \
    || bad "[9] tl:$n: PRD.md write or unrecognised use: $w $u"
done

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== ux-author-skill eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

#!/usr/bin/env bash
# ux-pipeline.test.sh — eval for TDD 0072 / FR-89, FR-101, FR-10: `[UI]` in
# /prd-author, merged mocks in /tdd-author, the tdd-lint ux.citation check and
# the design-reviewer UX-coverage bullet.
#
# EXTRACTS the first fenced bash block after `<!-- tl:ui-markers -->`
# (skills/prd-author/SKILL.md) and `<!-- tl:ux-coverage -->`
# (skills/tdd-author/SKILL.md) and RUNS each the way the harness does: a fresh
# shell, nothing pre-sourced, inputs from env only —
#   env -i HOME=<tmp> PATH=<path> CLAUDE_PLUGIN_ROOT=<repo> TL_REPO=<fixture> … bash <block>
# against temp git repos (`master` + a fixture docs/PRD.md and, where needed, a
# merged docs/ux/index.json; no origin, so no network). tdd-lint.sh runs under
# `env -i` too (no CLAUDE_PLUGIN_ROOT: the lint must find its own helpers) on
# fixture TDDs inside those repos. A missing marker, block or file is a FAIL
# (L-001), never a skip. Every negated grep first asserts its file is readable
# (L-001/L-002/L-011); every temp dir is trap-cleaned (L-004). Observation
# numbers are the TDD's Verification plan (obs 10 is the suite + the per-TDD
# exit-code regression run by the build).
#
# Written red-first. Run: bash tests/ux-pipeline.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PRDA="$REPO/skills/prd-author/SKILL.md"
TDDA="$REPO/skills/tdd-author/SKILL.md"
AGENT="$REPO/agents/design-reviewer.md"
LINT="$REPO/scripts/lib/tdd-lint.sh"
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
readable "$LINT" || bad "infra: $LINT missing/unreadable/empty"
G() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=master -c commit.gpgsign=false "$@"; }

# extract <skill-file> <marker-name> <out> — first ```bash block after `<!-- tl:<name> -->`.
# rc 0 ok | 10 file unreadable | 3 no marker | 4 no block | 5 unclosed | 6 empty.
extract() {
  readable "$1" || return 10
  awk -v M="<!-- tl:$2 -->" '
    !seen && $0 == M                    { seen = 1; next }
    seen && !open && /^```bash[ \t]*$/  { open = 1; next }
    open && /^```[ \t]*$/               { closed = 1; exit }
    open                                { print }
    END { if (!seen) exit 3; if (!open) exit 4; if (!closed) exit 5 }
  ' "$1" >"$3" || return $?
  [ -s "$3" ] || return 6
}

echo "[extract] tl:ui-markers (prd-author) and tl:ux-coverage (tdd-author) are present"
declare -A BLK=()
for pair in "$PRDA:ui-markers" "$TDDA:ux-coverage"; do
  file="${pair%:*}"; n="${pair##*:}"
  f="$ROOT/blocks/$n.sh"; extract "$file" "$n" "$f"; rc=$?
  case "$rc" in
    0)  BLK[$n]="$f"; ok "tl:$n extracted" ;;
    10) bad "infra: $file missing/unreadable/empty (tl:$n)" ;;
    3)  bad "marker <!-- tl:$n --> not found in $file" ;;
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

# lint <tdd> [VAR=val ...] — run tdd-lint.sh under env -i (no CLAUDE_PLUGIN_ROOT).
lint() {
  local t="$1"; shift
  ( cd "$ROOT" && exec env -i HOME="$H" PATH="$PATH" "$@" "$BASH_BIN" "$LINT" "$t" ) >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
}

echo "[contract] each block reads its inputs fail-loud and sources its own helpers"
for n in ui-markers ux-coverage; do
  b="${BLK[$n]:-}"; [ -n "$b" ] || { bad "[contract] tl:$n: no block"; continue; }
  runb "$n" "$ROOT" TL_IDS=
  [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -q 'TL_REPO' \
    && ok "[contract] tl:$n with TL_REPO unset → rc $RC naming TL_REPO" \
    || bad "[contract] tl:$n TL_REPO unset: rc=$RC err='$ERR'"
  grep -qF 'scripts/lib/plugin-root.sh' "$b" && grep -qF 'tl_plugin_root' "$b" \
    && grep -qF 'scripts/lib/ux.sh' "$b" \
    && ok "[contract] tl:$n sources plugin-root.sh and ux.sh via tl_plugin_root" \
    || bad "[contract] tl:$n does not source its own helpers"
  runb "$n" "$ROOT" TL_REPO="$ROOT" TL_IDS=FR-1 CLAUDE_PLUGIN_ROOT="$ROOT/nope"
  [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -q 'cannot source' \
    && ok "[contract] tl:$n with an unusable plugin root fails closed" \
    || bad "[contract] tl:$n bad plugin root: rc=$RC err='$ERR'"
done
runb ux-coverage "$ROOT" TL_REPO="$ROOT"
[ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -q 'TL_IDS' \
  && ok "[contract] tl:ux-coverage with TL_IDS unset → rc $RC naming TL_IDS" \
  || bad "[contract] tl:ux-coverage TL_IDS unset: rc=$RC err='$ERR'"

# --- fixtures -----------------------------------------------------------------
PRD_UI='# PRD

## Requirements
- **FR-1 [UI] Login.** The user logs in.
  Details here.
- **FR-2 CLI flag.** Not UI.
'
PRD_NOUI='# PRD

## Requirements
- **FR-2 CLI flag.** Not UI.
'
PRD_BAD='# PRD

## Requirements
- **FR-1 [UI] Login.** The user logs in.
- FR-3 [UI] Cart, written outside the title grammar.
'
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
  mkdir -p "$1/docs/tdd"; G init -q "$1"; printf '%s' "$2" >"$1/docs/PRD.md"
  G -C "$1" add -A && G -C "$1" commit -qm "PRD" || bad "infra: mkrepo $1 failed"
}
# mktdd <path> <prd-refs> <traceability-row> — an otherwise lint-clean TDD.
mktdd() {
  cat >"$1" <<EOF
# TDD 0001: Login

Status: draft
PRD refs: $2
PRD-rev: abc1234
ADR constraints: none

## Approach
Render the login screen from the merged mock.

## Verification plan
Open the login page; the form shows the two fields and the submit button.

## Requirement traceability
| Requirement | Design element |
|---|---|
$3

## Dependencies considered
No new dependency; the existing form component is reused because it already ships.
EOF
}

echo "[1] tl:ui-markers, clean"
R1="$ROOT/r1"; mkrepo "$R1" "$PRD_UI"
runb ui-markers "$R1" TL_REPO="$R1"
l1="$(printf '%s\n' "$OUT" | sed -n 1p)"; l2="$(printf '%s\n' "$OUT" | sed -n 2p)"
nl="$(printf '%s\n' "$OUT" | wc -l)"
[ "$RC" -eq 0 ] && [ "$l1" = 'ui-requirements: 1' ] && [ "$nl" -eq 2 ] \
  && printf '%s\n' "$l2" | grep -qE $'^FR-1\t[0-9a-f]{64}\tLogin$' \
  && ok "[1] 'ui-requirements: 1' then FR-1<TAB>…<TAB>Login, rc 0" \
  || bad "[1] rc=$RC out='$OUT' err='$ERR'"
R1b="$ROOT/r1b"; mkrepo "$R1b" "$PRD_NOUI"
runb ui-markers "$R1b" TL_REPO="$R1b"
[ "$RC" -eq 0 ] && [ "$OUT" = 'ui-requirements: 0' ] \
  && ok "[1] no [UI] → exactly 'ui-requirements: 0', rc 0" || bad "[1] no-UI: rc=$RC out='$OUT' err='$ERR'"

echo "[2] tl:ui-markers, malformed"
R2m="$ROOT/r2m"; mkrepo "$R2m" "$PRD_BAD"
runb ui-markers "$R2m" TL_REPO="$R2m"
[ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qF 'malformed [UI] marker' \
  && printf '%s' "$ERR" | grep -qF 'PRD.md:5' \
  && ok "[2] off-grammar FR-3 [UI] → rc $RC, 'malformed [UI] marker' at line 5" \
  || bad "[2] rc=$RC out='$OUT' err='$ERR'"
[ -r "$ROOT/out" ] && ! grep -q 'ui-requirements:' "$ROOT/out" \
  && ok "[2] no 'ui-requirements:' count printed for a malformed PRD" || bad "[2] a count was printed: '$OUT'"

echo "[3] tl:ux-coverage"
RC3="$ROOT/r3c"; mkrepo "$RC3" "$PRD_UI"
python3 -I "$ROOT/mkidx.py" "$RC3" '["login"]' && G -C "$RC3" add -A && G -C "$RC3" commit -qm "ux set" \
  || bad "infra: merged index fixture"
runb ux-coverage "$RC3" TL_REPO="$RC3" TL_IDS=
[ "$RC" -eq 0 ] && [ "$OUT" = 'ux-coverage: no [UI] requirements in scope' ] \
  && ok "[3] TL_IDS empty → the no-[UI] line, rc 0" || bad "[3] empty: rc=$RC out='$OUT' err='$ERR'"
runb ux-coverage "$RC3" TL_REPO="$RC3" TL_IDS=FR-1
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf 'covered\tFR-1\tdocs/ux/screens/login/')" ] \
  && ok "[3] FR-1 merged on master → covered<TAB>FR-1<TAB>docs/ux/screens/login/, rc 0" \
  || bad "[3] covered: rc=$RC out='$OUT' err='$ERR'"
RU="$ROOT/r3u"; mkrepo "$RU" "$PRD_UI"
G -C "$RU" checkout -qb docs/ux/login && python3 -I "$ROOT/mkidx.py" "$RU" '["login"]' \
  && G -C "$RU" add -A && G -C "$RU" commit -qm "unmerged ux set" || bad "infra: branch-only index"
runb ux-coverage "$RU" TL_REPO="$RU" TL_IDS=FR-1
[ "$RC" -eq 1 ] && [ "$OUT" = "$(printf 'uncovered\tFR-1')" ] \
  && ok "[3] FR-1 only on a checked-out branch → uncovered<TAB>FR-1, rc 1" \
  || bad "[3] uncovered: rc=$RC out='$OUT' err='$ERR'"
RX="$ROOT/r3x"; mkrepo "$RX" "$PRD_UI"
mkdir -p "$RX/docs/ux" && printf '{not json\n' >"$RX/docs/ux/index.json" \
  && G -C "$RX" add -A && G -C "$RX" commit -qm "corrupt index" || bad "infra: corrupt index"
runb ux-coverage "$RX" TL_REPO="$RX" TL_IDS=FR-1
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF 'ux: invalid index' \
  && ok "[3] corrupt merged index → rc 2, 'ux: invalid index'" || bad "[3] corrupt: rc=$RC out='$OUT' err='$ERR'"

echo "[4] lint, cited"
T4="$RC3/docs/tdd/0001-login.md"
mktdd "$T4" "FR-1" '| FR-1 | login form per docs/ux/screens/login/ |'
lint "$T4"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "[4] cited screen path → tdd-lint rc 0, empty stdout" \
  || bad "[4] rc=$RC out='$OUT' err='$ERR'"
[ -r "$ROOT/out" ] && ! grep -q 'ux.citation' "$ROOT/out" && ok "[4] no ux.citation finding" \
  || bad "[4] ux.citation present or out unreadable"
mktdd "$T4" "FR-2" '| FR-2 | a new CLI flag |'
lint "$T4"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "[4] a TDD citing only non-[UI] FR-2 → rc 0, empty stdout" \
  || bad "[4] non-UI refs: rc=$RC out='$OUT' err='$ERR'"

echo "[5] lint, missing citation"
mktdd "$T4" "FR-1" '| FR-1 | login form |'
lint "$T4"
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF 'major ux.citation: FR-1 is [UI]' \
  && printf '%s' "$OUT" | grep -qF 'docs/ux/screens/' \
  && ok "[5] no path → rc 1, 'major ux.citation: FR-1 is [UI]'" || bad "[5] rc=$RC out='$OUT' err='$ERR'"
mktdd "$T4" "FR-1" '| FR-1 | login form per docs/ux/screens/signup/ |'
lint "$T4"
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF 'ux.citation' \
  && ok "[5] a path to the wrong screen → rc 1 ux.citation" || bad "[5] wrong screen: rc=$RC out='$OUT' err='$ERR'"
# The same check through tl_lint_all when sourced (the wiring), not just the CLI.
( cd "$ROOT" && exec env -i HOME="$H" PATH="$PATH" "$BASH_BIN" -c '. "$1" || exit 97; tl_lint_all "$2"' _ "$LINT" "$T4" ) \
  >"$ROOT/out" 2>"$ROOT/err"; RC=$?
[ "$RC" -eq 1 ] && grep -qF 'ux.citation' "$ROOT/out" && ok "[5] sourced tl_lint_all reports ux.citation, rc 1" \
  || bad "[5] tl_lint_all: rc=$RC out='$(cat "$ROOT/out")' err='$(cat "$ROOT/err")'"

echo "[6] lint, waived"
T6="$RU/docs/tdd/0001-login.md"
mktdd "$T6" "FR-1" '| FR-1 | mock waived: the button reuses the existing toolbar style |'
lint "$T6"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "[6] uncovered + 'mock waived: <rationale>' → rc 0" \
  || bad "[6] waived: rc=$RC out='$OUT' err='$ERR'"
mktdd "$T6" "FR-1" '| FR-1 | mock waived: |'
lint "$T6"
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF 'major ux.citation: FR-1 is [UI]' \
  && ok "[6] empty waiver 'mock waived: |' → rc 1 ux.citation" || bad "[6] empty waiver: rc=$RC out='$OUT' err='$ERR'"
mktdd "$T6" "FR-1" '| FR-1 | login form per docs/ux/screens/login/ |'
lint "$T6"
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF 'ux.citation' \
  && ok "[6] uncovered with no waiver (path cited but unmerged) → rc 1" || bad "[6] uncovered: rc=$RC out='$OUT' err='$ERR'"
RS="$ROOT/r6s"; mkrepo "$RS" "$PRD_UI"
python3 -I "$ROOT/mkidx.py" "$RS" '["login"]' && G -C "$RS" add -A && G -C "$RS" commit -qm "ux set" \
  || bad "infra: stale fixture"
sed -i 's/Details here\./Details changed./' "$RS/docs/PRD.md" || bad "infra: stale edit"
T6s="$RS/docs/tdd/0001-login.md"
mktdd "$T6s" "FR-1" '| FR-1 | login form per docs/ux/screens/login/ |'
lint "$T6s"
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF 'ux.citation' \
  && ok "[6] stale (FR-1 changed since the merged set) without a waiver → rc 1" \
  || bad "[6] stale: rc=$RC out='$OUT' err='$ERR'"

echo "[7] lint, non-UI repo, no python3"
NOPY="$ROOT/nopy"; mkdir -p "$NOPY"
for t in git grep sed awk cat dirname mkdir rm head tail tr cut sort mktemp basename wc; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOPY/$t"
done
[ -e "$NOPY/python3" ] && bad "infra: python3 leaked into $NOPY"
R7="$ROOT/r7"; mkrepo "$R7" "$PRD_NOUI"; T7="$R7/docs/tdd/0001-cli.md"
mktdd "$T7" "FR-2" '| FR-2 | the flag parser |'
( cd "$ROOT" && exec env -i HOME="$H" PATH="$NOPY" "$BASH_BIN" -c '
    command -v python3 >/dev/null 2>&1 && { echo "python3 on PATH"; exit 96; }
    . "$1" || exit 97
    tl_lint_ux_citations "$2"; rc=$?
    declare -F tl_ux_ui_reqs >/dev/null && echo "SOURCED ux.sh"
    echo "rc=$rc"' _ "$LINT" "$T7" ) >"$ROOT/out" 2>"$ROOT/err"
if [ -r "$ROOT/out" ]; then
  grep -qx 'rc=0' "$ROOT/out" && ! grep -q 'SOURCED' "$ROOT/out" \
    && ok "[7] no [UI] in the PRD, no python3 → rc 0 and ux.sh never sourced" \
    || bad "[7] out='$(cat "$ROOT/out")' err='$(cat "$ROOT/err")'"
else bad "[7] infra: output unreadable"; fi
# Positive control: the sentinel does appear when the PRD has [UI].
( cd "$ROOT" && exec env -i HOME="$H" PATH="$PATH" "$BASH_BIN" -c '
    . "$1" || exit 97
    tl_lint_ux_citations "$2"; rc=$?
    declare -F tl_ux_ui_reqs >/dev/null && echo "SOURCED ux.sh"
    echo "rc=$rc"' _ "$LINT" "$T4" ) >"$ROOT/out" 2>"$ROOT/err"
grep -q 'SOURCED ux.sh' "$ROOT/out" && ok "[7] control: a [UI] PRD does source ux.sh (the sentinel discriminates)" \
  || bad "[7] control: out='$(cat "$ROOT/out")' err='$(cat "$ROOT/err")'"

echo "[8] lint, helper failure"
T8="$RX/docs/tdd/0001-login.md"
mktdd "$T8" "FR-1" '| FR-1 | login form per docs/ux/screens/login/ |'
lint "$T8"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF 'tdd-lint: ux:' \
  && ok "[8] corrupt merged index → rc 2, 'tdd-lint: ux:' on stderr" || bad "[8] rc=$RC out='$OUT' err='$ERR'"
lint "$T4" PATH="$NOPY"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF 'tdd-lint: ux:' && printf '%s' "$ERR" | grep -qF 'python3 required' \
  && ok "[8] [UI] PRD with no python3 → rc 2, 'tdd-lint: ux:' + 'python3 required'" \
  || bad "[8] no python3: rc=$RC out='$OUT' err='$ERR'"
mktdd "$T8" "FR-1" '| FR-1 | login form |'
cp "$RX/docs/PRD.md" "$ROOT/prd.bak"; printf '%s' "$PRD_BAD" >"$RX/docs/PRD.md"
lint "$T8"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF 'tdd-lint: ux:' \
  && ok "[8] malformed [UI] marker in the PRD → rc 2, never clean" || bad "[8] malformed: rc=$RC out='$OUT' err='$ERR'"
cp "$ROOT/prd.bak" "$RX/docs/PRD.md"

echo "[9] skill and agent text"
if readable "$PRDA"; then
  for w in '<!-- tl:ui-markers -->' \
           'Does this change what a user sees or does in a graphical web or mobile UI?' \
           'ui: <ID>' '`[UI]` markers' '## UI requirements' 'UI requirements: none' \
           'Next: merge this PR, then run /ux-author before /tdd-author.' 'tl_ux_ui_reqs'; do
    grep -qF -- "$w" "$PRDA" && ok "[9] prd-author has '$w'" || bad "[9] prd-author lacks '$w'"
  done
else bad "[9] infra: $PRDA missing/unreadable/empty"; fi
if readable "$TDDA"; then
  for w in '<!-- tl:ux-coverage -->' 'UX coverage (FR-101)' \
           'is a [UI] requirement with no merged UX set' \
           'throughline: <ID> is a [UI] requirement with no merged UX set (<uncovered|stale: reason>); run /ux-author first, or waive the mock.' \
           'Stop and run `/ux-author`' 'Waive the mock' 'Drop `<ID>` from this pass' \
           'assumption: mock waived <ID>' 'mock waived: <rationale>' 'docs/ux/screens/<sid>/' \
           'docs/ux/tokens.css' 'UX coverage' 'tl_ux_coverage'; do
    grep -qF -- "$w" "$TDDA" && ok "[9] tdd-author has '$w'" || bad "[9] tdd-author lacks '$w'"
  done
  a="$(grep -nxF -m1 '## 1. Determine what changed in the PRD' "$TDDA" | cut -d: -f1)"
  c="$(grep -nxF -m1 '<!-- tl:ux-coverage -->' "$TDDA" | cut -d: -f1)"
  d="$(grep -nxF -m1 '## 2. Inventory existing coverage' "$TDDA" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$c" ] && [ -n "$d" ] && [ "$a" -lt "$c" ] && [ "$c" -lt "$d" ] \
    && ok "[9] tl:ux-coverage sits after step 1, before step 2 (step 1a)" \
    || bad "[9] order: step1='$a' ux-coverage='$c' step2='$d'"
else bad "[9] infra: $TDDA missing/unreadable/empty"; fi
if readable "$AGENT"; then
  for w in 'UX coverage (FR-101)' 'BLOCK ux-waiver' 'docs/ux/tokens.css' 'mock waived: <rationale>'; do
    grep -qF -- "$w" "$AGENT" && ok "[9] design-reviewer has '$w'" || bad "[9] design-reviewer lacks '$w'"
  done
else bad "[9] infra: $AGENT missing/unreadable/empty"; fi
for f in "$PRDA" "$TDDA" "$AGENT"; do
  if readable "$f"; then
    hits="$(grep -nEi 'AskUserQuestion|claude -p|grok -p|\bTask tool\b' "$f")"
    [ -z "$hits" ] && ok "[9] $(basename "$(dirname "$f")")/$(basename "$f") names no vendor tool (FR-81)" \
      || bad "[9] vendor names in $f: $hits"
  else bad "[9] infra: $f unreadable"; fi
done

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== 0072 ux-pipeline: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

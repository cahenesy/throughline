#!/usr/bin/env bash
# ux-record.test.sh — eval for TDD 0070 / FR-89, FR-90, FR-91, FR-94, FR-101,
# NFR-4: the [UI] grammar, block hashing, delta, index validation, merged-index
# coverage and the loud-failure paths of scripts/lib/ux.sh + ux_record.py.
#
# Observation points 1–6, 12, 13 of the TDD's Verification plan. Every
# function runs through the sourced ux.sh in a clean `env -i` shell against
# temp repos built by a fixture writer that hashes independently of the lib.
# Every negated assertion first asserts its file is readable (L-001/L-011);
# every temp dir is trap-cleaned (L-004).
#
# Written red-first. Run: bash tests/ux-record.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
UX="$REPO/scripts/lib/ux.sh"
RESULTS=""; ROOT=""
cleanup() { [ -n "$ROOT" ] && rm -rf "$ROOT"; [ -n "$RESULTS" ] && rm -f "$RESULTS"; }
trap cleanup EXIT
RESULTS="$(mktemp)"; export RESULTS
ROOT="$(mktemp -d)"
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
q() { printf '%q' "$1"; }
H="$ROOT/home"; mkdir -p "$H"
BASH_BIN="$(command -v bash)"
TAB="$(printf '\t')"
command -v python3 >/dev/null 2>&1 || bad "infra: python3 not found (fixtures)"
[ -r "$UX" ] || bad "infra: $UX unreadable"

# ux '<cmds>' [VAR=val …] — source ux.sh in a clean shell; sets OUT ERR RC.
ux() {
  local c="$1"; shift
  env -i HOME="$H" PATH="${UXPATH:-$PATH}" CLAUDE_PLUGIN_ROOT="$REPO" THROUGHLINE_UX_NOFETCH=1 "$@" \
    "$BASH_BIN" -c ". $(q "$UX") || exit 98; $c" >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
}
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# Fixture writer: mk.py <dir> [json-spec]. Writes docs/PRD.md and a valid
# docs/ux set (index.json + mocks). FR-1's hash is computed here from the
# fixed block text, independently of the library.
cat >"$ROOT/mk.py" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]; spec = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
blk = "- **FR-1 [UI] Login.** The user logs in.\n  Details here."
prd = spec.get("prd", "# PRD\n\n## Requirements\n" + blk + "\n- **FR-2 API.** Not UI.\n")
screens = spec.get("screens", {"a": ["default"]})
os.makedirs(os.path.join(d, "docs/ux"), exist_ok=True)
open(os.path.join(d, "docs/PRD.md"), "w").write(prd)
idx = {"schema": 1, "prd_rev": "abc1234", "platforms": ["web"],
       "viewports": [{"name": n, "width": w, "height": h} for n, w, h in spec.get("viewports", [["desktop", 1280, 800]])],
       "fidelity": spec.get("fidelity", "mid"), "delegates": spec.get("delegates", []),
       "design_system": {"tokens": None, "adr": None, "source": "none"},
       "requirements": [{"id": "FR-1", "hash": hashlib.sha256(blk.encode()).hexdigest(), "screens": list(screens)}],
       "screens": [], "flow": spec.get("flow", list(screens))}
for sid, files in screens.items():
    st = []
    for n in ["default", "empty", "loading", "error"]:
        if n in files:
            f = "screens/%s/%s.html" % (sid, n); st.append({"name": n, "file": f})
            os.makedirs(os.path.join(d, "docs/ux/screens", sid), exist_ok=True)
            open(os.path.join(d, "docs/ux", f), "w").write(
                "<!doctype html><html><head><title>%s %s</title></head><body><h1>%s</h1></body></html>\n" % (sid, n, n))
        else:
            st.append({"name": n, "na": "not applicable here"})
    idx["screens"].append({"id": sid, "title": spec.get("titles", {}).get(sid, "Screen " + sid),
                           "baseline": "none (new screen)", "states": st})
open(os.path.join(d, "docs/ux/index.json"), "w").write(json.dumps(idx, indent=2) + "\n")
PY
mk() { python3 -I "$ROOT/mk.py" "$@"; }
# jmut <file> '<python on d>' — mutate a JSON file in place.
jmut() {
  python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); exec(sys.argv[2]); open(p,"w").write(json.dumps(d,indent=2))' "$1" "$2"
}

echo "[1] grammar: [UI] titles in file order; inline code and fences skipped"
P1="$ROOT/p1.md"
cat >"$P1" <<'EOF'
# T
- **FR-1 [UI] Login.** body
Prose mentions the `[UI]` marker and ``a [UI] b`` too.
```
**FR-9 [UI] Fenced.**
```
**R-7 [UI] Cart** body
EOF
ux "tl_ux_ui_reqs $(q "$P1")"
ids="$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ')"
[ "$RC" -eq 0 ] && [ "$ids" = "FR-1 R-7 " ] && [ "$(printf '%s\n' "$OUT" | wc -l)" -eq 2 ] \
  && ok "[1] exactly FR-1 then R-7, rc 0" || bad "[1] rc=$RC out='$OUT' err='$ERR'"
r7="$(printf '%s\n' "$OUT" | grep "^R-7${TAB}" || true)"
[ "$r7" = "R-7${TAB}$(sha "**R-7 [UI] Cart** body")${TAB}Cart" ] \
  && ok "[1] R-7 line: id, block hash (sha256 of the raw block), title" || bad "[1] R-7 line '$r7'"
printf '%s\n' "$OUT" | grep -q "^FR-1${TAB}[0-9a-f]\{64\}${TAB}Login\$" \
  && ok "[1] FR-1 title 'Login' (trailing period dropped)" || bad "[1] FR-1 line: '$OUT'"
P1b="$ROOT/p1b.md"; printf '%s\n' '- **FR-3 [UI] Use `x` here.** b' '  more   ' '## H' 'tail' >"$P1b"
ux "tl_ux_ui_reqs $(q "$P1b")"
[ "$RC" -eq 0 ] && [ "$OUT" = "FR-3${TAB}$(sha "$(printf '%s\n%s' '- **FR-3 [UI] Use `x` here.** b' '  more')")${TAB}Use \`x\` here" ] \
  && ok "[1] block ends at a heading, trailing whitespace stripped, title keeps raw backticks" \
  || bad "[1] heading-bounded block: rc=$RC out='$OUT' err='$ERR'"

echo "[2] loud miss: stray [UI] and duplicate ids fail rc 2"
P2="$ROOT/p2.md"; printf '%s\n' '# T' '- **FR-1 [UI] Login.** x' 'see [UI] below' >"$P2"
ux "tl_ux_ui_reqs $(q "$P2")"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF "ux: malformed [UI] marker at $P2:3: see [UI] below" \
  && ok "[2] stray [UI] → rc 2 naming <path>:<line>" || bad "[2] stray: rc=$RC err='$ERR'"
P2d="$ROOT/p2d.md"; printf '%s\n' '- **FR-1 [UI] A.** x' '- **FR-1 [UI] B.** y' >"$P2d"
ux "tl_ux_ui_reqs $(q "$P2d")"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF "ux: duplicate [UI] id FR-1 at $P2d:1,2" \
  && ok "[2] duplicate FR-1 → rc 2 duplicate" || bad "[2] dup: rc=$RC err='$ERR'"
P2x="$ROOT/p2x.md"; printf '%s\n' '- **fr-1 [UI] Lower.** x' >"$P2x"
ux "tl_ux_ui_reqs $(q "$P2x")"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF 'malformed [UI] marker' \
  && ok "[2] another id shape with [UI] fails loudly" || bad "[2] id shape: rc=$RC err='$ERR'"
ux "tl_ux_ui_reqs $(q "$ROOT/nope.md")"
[ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -qF "ux: cannot read $ROOT/nope.md" \
  && ok "[2] unreadable PRD → rc 1" || bad "[2] unreadable: rc=$RC err='$ERR'"

echo "[3] short-circuit: no [UI] needs no python3"
NOPY="$ROOT/nopy"; mkdir -p "$NOPY"
for t in bash sh env grep cat dirname sed awk git head tr mkdir rm ls cut wc; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOPY/$t"
done
[ ! -e "$NOPY/python3" ] && ok "[3] infra: PATH dir without python3" || bad "[3] infra: python3 leaked into $NOPY"
P3="$ROOT/p3.md"; printf '%s\n' '# T' '- **FR-1 Plain.** no marker' >"$P3"
UXPATH="$NOPY" ux "tl_ux_ui_reqs $(q "$P3")"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "[3] no [UI], no python3 → rc 0, empty" || bad "[3] rc=$RC out='$OUT' err='$ERR'"
printf '%s\n' '- **FR-2 [UI] Now UI.** x' >>"$P3"
UXPATH="$NOPY" ux "tl_ux_ui_reqs $(q "$P3")"
[ "$RC" -eq 3 ] && printf '%s' "$ERR" | grep -qF 'ux: python3 required' \
  && ok "[3] one [UI], no python3 → rc 3 ux: python3 required" || bad "[3] rc=$RC err='$ERR'"

echo "[4] throughline's own PRD has no [UI] requirements"
if [ -r "$REPO/docs/PRD.md" ] && grep -qF '[UI]' "$REPO/docs/PRD.md"; then
  ux "tl_ux_ui_reqs $(q "$REPO/docs/PRD.md")"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "[4] docs/PRD.md → rc 0, empty (all mentions backticked)" \
    || bad "[4] rc=$RC out='$OUT' err='$ERR'"
else
  bad "[4] infra: docs/PRD.md unreadable or no longer mentions [UI]"
fi

echo "[5] delta: new / changed / orphaned"
R5="$ROOT/r5"; mk "$R5"
P5="$R5/docs/PRD.md"; I5="$R5/docs/ux/index.json"
printf '%s\n' '- **R-7 [UI] Cart** body' >>"$P5"
ux "tl_ux_delta $(q "$P5") $(q "$ROOT/no-such-index.json")"
[ "$RC" -eq 0 ] && [ "$OUT" = "new${TAB}FR-1${TAB}Login"$'\n'"new${TAB}R-7${TAB}Cart" ] \
  && ok "[5] no index → all new, PRD order" || bad "[5] none: rc=$RC out='$OUT' err='$ERR'"
ux "tl_ux_delta $(q "$P5") $(q "$I5")"
[ "$RC" -eq 0 ] && [ "$OUT" = "new${TAB}R-7${TAB}Cart" ] \
  && ok "[5] index holds FR-1's current hash → FR-1 absent" || bad "[5] current: rc=$RC out='$OUT' err='$ERR'"
ux "tl_ux_delta $(q "$P5") - < $(q "$I5")"
[ "$RC" -eq 0 ] && [ "$OUT" = "new${TAB}R-7${TAB}Cart" ] && ok "[5] '-' reads the index from stdin" \
  || bad "[5] stdin: rc=$RC out='$OUT' err='$ERR'"
sed -i 's/Details here\./Details changed./' "$P5"
ux "tl_ux_delta $(q "$P5") $(q "$I5")"
printf '%s\n' "$OUT" | grep -qx "changed${TAB}FR-1${TAB}Login" && [ "$RC" -eq 0 ] \
  && ok "[5] FR-1 body edited → changed FR-1" || bad "[5] changed: rc=$RC out='$OUT' err='$ERR'"
sed -i 's/FR-1 \[UI\] Login/FR-1 Login/' "$P5"
ux "tl_ux_delta $(q "$P5") $(q "$I5")"
printf '%s\n' "$OUT" | grep -qx "orphaned${TAB}FR-1" && [ "$RC" -eq 0 ] \
  && ok "[5] marker removed → orphaned FR-1" || bad "[5] orphaned: rc=$RC out='$OUT' err='$ERR'"
printf '{"schema":1,' >"$ROOT/bad.json"
ux "tl_ux_delta $(q "$P5") $(q "$ROOT/bad.json")"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF "ux: invalid index $ROOT/bad.json:" \
  && ok "[5] malformed index → rc 2" || bad "[5] malformed: rc=$RC err='$ERR'"
cp "$I5" "$ROOT/struct.json"; jmut "$ROOT/struct.json" 'd["fidelity"]="ultra"'
ux "tl_ux_delta $(q "$P5") $(q "$ROOT/struct.json")"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF 'ux: invalid index' \
  && ok "[5] structural violation → rc 2 in delta" || bad "[5] structural: rc=$RC err='$ERR'"

echo "[6] validate: a valid set, then each mutation rejected"
R6="$ROOT/r6"; mk "$R6"
ux "tl_ux_validate $(q "$R6")"
[ "$RC" -eq 0 ] && [ "$OUT" = "ok 1 screens, 1 requirements, screenshots 0/1" ] \
  && ok "[6] valid fixture → ok 1 screens, 1 requirements, screenshots 0/1" || bad "[6] valid: rc=$RC out='$OUT' err='$ERR'"
# mut <label> <grep-ERE> <shell cmds using $M>
mut() {
  local label="$1" pat="$2" cmd="$3" M="$ROOT/m$RANDOM$RANDOM"
  cp -a "$R6" "$M"; ( cd "$M" && eval "$cmd" ) || { bad "[6] infra: mutation '$label' failed"; return; }
  ux "tl_ux_validate $(q "$M")"
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -E '^ux-invalid: ' | grep -qE "$pat"; then
    ok "[6] $label → rc 1, ux-invalid names it"
  else bad "[6] $label: rc=$RC out='$OUT' err='$ERR'"; fi
}
J=docs/ux/index.json
mut "CDN script" 'default\.html: .*https://cdn' \
  "sed -i 's#<head>#<head><script src=\"https://cdn.example.com/x.js\"></script>#' docs/ux/screens/a/default.html"
mut "url(//fonts…)" 'default\.html: .*//fonts' \
  "sed -i 's#<head>#<head><style>body{background:URL(//fonts.example.com/f.woff)}</style>#' docs/ux/screens/a/default.html"
mut "tokens.css not linked" 'default\.html: .*tokens\.css' "printf ':root{--x:1px}\n' > docs/ux/tokens.css"
mut "states missing error" 'error' "jmut $J 'd[\"screens\"][0][\"states\"].pop()'"
mut "high fidelity, no delegates" 'fidelity' "jmut $J 'd[\"fidelity\"]=\"high\"'"
mut "wrong hash" 'hash.*FR-1|FR-1.*hash' "jmut $J 'd[\"requirements\"][0][\"hash\"]=\"0\"*64'"
mut "orphaned requirement" 'orphaned.*FR-1|FR-1.*orphaned' "sed -i 's/FR-1 \[UI\] Login/FR-1 Login/' docs/PRD.md"
mut "PNG of an undeclared viewport" 'default@phone\.png: unreferenced image' \
  "cp docs/ux/screens/a/default.html docs/ux/screens/a/default@phone.png"
mut "leftover n/a mock" 'screens/a/error\.html: unlisted mock \(superseded\)' "printf x > docs/ux/screens/a/error.html"
mut "stray capture" 'docs/ux/capture\.png: unreferenced image' "printf x > docs/ux/capture.png"
mut "'..' path" '\.\.' "jmut $J 'd[\"screens\"][0][\"states\"][0][\"file\"]=\"screens/a/../a/default.html\"'"
# [S] security: local-file disclosure, network bypass, symlinks (0070 build review)
mut "file:// iframe" 'default\.html: .*file://' \
  "sed -i 's#<head>#<head><iframe src=\"file:///etc/hostname\"></iframe>#' docs/ux/screens/a/default.html"
mut "absolute local path" 'default\.html: .*/etc/passwd.*outside docs/ux' \
  "sed -i 's#<head>#<head><img src=\"/etc/passwd\">#' docs/ux/screens/a/default.html"
mut "relative path escaping docs/ux" 'default\.html: .*outside docs/ux' \
  "sed -i 's#<head>#<head><img src=\"../../../../../etc/passwd\">#' docs/ux/screens/a/default.html"
mut "IP literal in script" 'default\.html: .*10\.0\.0\.1' \
  "sed -i 's#<head>#<head><script>fetch(\"http://10.0.0.1/x\")</script>#' docs/ux/screens/a/default.html"
mut "websocket URL" 'default\.html: .*wss?://' \
  "sed -i 's#<head>#<head><script>new WebSocket(\"ws://h:1\")</script>#' docs/ux/screens/a/default.html"
mut "symlinked mock" 'default\.html: symlink' \
  "printf '<html><head></head></html>' > \"$ROOT/outside.html\"; rm docs/ux/screens/a/default.html; ln -s \"$ROOT/outside.html\" docs/ux/screens/a/default.html"
mut "symlinked screen dir" 'screens/a: symlink' \
  "mv docs/ux/screens/a \"$ROOT/adir$RANDOM\" && ln -s \"\$(ls -d $ROOT/adir* | tail -n1)\" docs/ux/screens/a"
MD="$ROOT/m6data"; cp -a "$R6" "$MD"
sed -i 's#<head>#<head><img src="data:image/png;base64,AAAA" alt=""><a href="#top">t</a>#' "$MD/docs/ux/screens/a/default.html"
ux "tl_ux_validate $(q "$MD")"
[ "$RC" -eq 0 ] && ok "[S] data: URI and #fragment stay valid" || bad "[S] data/fragment: rc=$RC out='$OUT' err='$ERR'"
M6="$ROOT/m6tok"; cp -a "$R6" "$M6"; printf ':root{--x:1px}\n' >"$M6/docs/ux/tokens.css"
sed -i 's#<head>#<head><link rel="stylesheet" href="../../tokens.css">#' "$M6/docs/ux/screens/a/default.html"
ux "tl_ux_validate $(q "$M6")"
[ "$RC" -eq 0 ] && ok "[6] tokens.css linked relatively → valid" || bad "[6] tokens linked: rc=$RC out='$OUT' err='$ERR'"
rm -f "$M6/docs/ux/index.json"
ux "tl_ux_validate $(q "$M6")"
[ "$RC" -eq 2 ] && ok "[6] missing index → rc 2" || bad "[6] missing index: rc=$RC out='$OUT' err='$ERR'"

echo "[12] coverage reads the merged index only"
R12="$ROOT/r12"; mk "$R12"
printf '%s\n' '- **FR-5 [UI] Search.** find things' >>"$R12/docs/PRD.md"
g() { git -C "$R12" -c user.email=t@t.t -c user.name=t "$@"; }
g init -q -b master && g add -A && g commit -qm A
g checkout -q -b feat
python3 -I -c '
import json,sys,hashlib
p=sys.argv[1]; d=json.load(open(p))
d["requirements"].append({"id":"FR-5","hash":hashlib.sha256(b"- **FR-5 [UI] Search.** find things").hexdigest(),"screens":["a"]})
open(p,"w").write(json.dumps(d,indent=2))' "$R12/docs/ux/index.json"
g commit -qam B
ux "tl_ux_validate $(q "$R12")"
[ "$RC" -eq 0 ] && ok "[12] infra: branch index B validates" || bad "[12] infra: B invalid: $OUT $ERR"
ux "tl_ux_coverage $(q "$R12") FR-1 FR-5"
[ "$RC" -eq 1 ] && [ "$OUT" = "covered${TAB}FR-1${TAB}docs/ux/screens/a/"$'\n'"uncovered${TAB}FR-5" ] \
  && ok "[12] covered FR-1 (merged), uncovered FR-5 (branch-only), rc 1" || bad "[12] rc=$RC out='$OUT' err='$ERR'"
printf '%s' "$ERR" | grep -qE '^ux: merged index from master @ [0-9a-f]+' \
  && ok "[12] stderr names the merged ref and sha" || bad "[12] stderr '$ERR'"
ux "tl_ux_coverage $(q "$R12") FR-1"
[ "$RC" -eq 0 ] && ok "[12] all covered → rc 0" || bad "[12] all covered: rc=$RC out='$OUT'"
sed -i 's/Details here\./Details edited./' "$R12/docs/PRD.md"
ux "tl_ux_coverage $(q "$R12") FR-1"
[ "$RC" -eq 1 ] && [ "$OUT" = "stale${TAB}FR-1${TAB}hash differs from merged index" ] \
  && ok "[12] working-tree edit → stale FR-1" || bad "[12] stale: rc=$RC out='$OUT' err='$ERR'"
R12n="$ROOT/r12n"; mkdir -p "$R12n"; git -C "$R12n" init -q -b dev
git -C "$R12n" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m x
ux "tl_ux_coverage $(q "$R12n") FR-1" THROUGHLINE_INTEGRATION_BRANCH=nope
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF 'ux: no integration branch' \
  && ok "[12] no integration ref → rc 2 ux: no integration branch" || bad "[12] noref: rc=$RC err='$ERR'"
ux "tl_ux_merged_index $(q "$R12n")" THROUGHLINE_INTEGRATION_BRANCH=dev
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok "[12] merged_index: no index on the integration branch → rc 1" \
  || bad "[12] merged_index none: rc=$RC out='$OUT' err='$ERR'"
ux "tl_ux_coverage $(q "$R12n") FR-1" THROUGHLINE_INTEGRATION_BRANCH=dev
[ "$RC" -eq 1 ] && [ "$OUT" = "uncovered${TAB}FR-1" ] && ok "[12] no merged index → uncovered" \
  || bad "[12] no merged: rc=$RC out='$OUT' err='$ERR'"
g checkout -q master && printf '{"schema":2}\n' >"$R12/docs/ux/index.json" && g commit -qam broken
ux "tl_ux_coverage $(q "$R12") FR-1"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF 'ux: invalid index' \
  && ok "[12] merged blob invalid → rc 2" || bad "[12] invalid blob: rc=$RC out='$OUT' err='$ERR'"

echo "[13] internal errors never read as success"
printf '\x89PNG\r\n\x1a\n\x00\xff\xfe\xfd' >"$ROOT/bin.json"
ux "tl_ux_delta $(q "$P5") $(q "$ROOT/bin.json")"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qE 'ux: (invalid index|internal error)' \
  && ok "[13] binary index → rc 2 with a named ux: message" || bad "[13] rc=$RC err='$ERR'"

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== ux-record eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

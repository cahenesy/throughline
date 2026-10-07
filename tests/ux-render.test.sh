#!/usr/bin/env bash
# ux-render.test.sh — eval for TDD 0070 / FR-91, FR-94, FR-99, NFR-4: screenshot
# rendering (scoped clear, whole-set status, rc-4 degrade), captures that are
# never in-repo, and the generated index.html flow page.
#
# Observation points 7–11 and 9b of the TDD's Verification plan. A stub browser
# (THROUGHLINE_UX_BROWSER) writes a 1×1 PNG and logs its argv; when a real
# Chrome/Chromium is on PATH, obs 10 also runs one real render (skipped with a
# printed note when none exists; --no-sandbox is never passed). Every negated
# assertion first asserts its file is readable (L-001/L-011); every temp dir
# and the local http server are trap-cleaned (L-004).
#
# Written red-first. Run: bash tests/ux-render.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
UX="$REPO/scripts/lib/ux.sh"
RESULTS=""; ROOT=""; SRV=""
cleanup() {
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; wait 2>/dev/null
  [ -n "$ROOT" ] && rm -rf "$ROOT"; [ -n "$RESULTS" ] && rm -f "$RESULTS"
}
trap cleanup EXIT
RESULTS="$(mktemp)"; export RESULTS
ROOT="$(mktemp -d)"
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
q() { printf '%q' "$1"; }
H="$ROOT/home"; mkdir -p "$H"
BASH_BIN="$(command -v bash)"
command -v python3 >/dev/null 2>&1 || bad "infra: python3 not found (fixtures)"
[ -r "$UX" ] || bad "infra: $UX unreadable"

# ux '<cmds>' [VAR=val …] — source ux.sh in a clean shell; sets OUT ERR RC LAST.
ux() {
  local c="$1"; shift
  env -i HOME="$H" PATH="${UXPATH:-$PATH}" CLAUDE_PLUGIN_ROOT="$REPO" THROUGHLINE_UX_NOFETCH=1 "$@" \
    "$BASH_BIN" -c ". $(q "$UX") || exit 98; $c" >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"; LAST="$(printf '%s\n' "$OUT" | tail -n 1)"
}

# Stub browsers. Each logs argv (one per line, then ---) to $ROOT/stub.log and
# counts calls in $ROOT/stub.n. ok: always writes a 1×1 PNG. fail2: writes the
# PNG then exits 1 on its 2nd call. failall: exits 1 without writing.
PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
mkstub() {
  cat >"$ROOT/stub-$1" <<EOF
#!$BASH_BIN
for a in "\$@"; do printf '%s\n' "\$a"; done >>"$ROOT/stub.log"; echo --- >>"$ROOT/stub.log"
n=\$(( \$(cat "$ROOT/stub.n" 2>/dev/null || echo 0) + 1 )); echo \$n >"$ROOT/stub.n"
out=""; for a in "\$@"; do case "\$a" in --screenshot=*) out="\${a#--screenshot=}" ;; file://*) f="\${a#file://}"; f="\$(printf '%b' "\${f//%/\\\\x}")"; cat "\$f" >>"$ROOT/stub.html" 2>/dev/null ;; esac; done
mode=$1
[ "\$mode" = failall ] && exit 1
printf '%s' '$PNG_B64' | base64 -d >"\$out"
[ "\$mode" = fail2 ] && [ "\$n" -eq 2 ] && exit 1
exit 0
EOF
  chmod +x "$ROOT/stub-$1"
}
for m in ok fail2 failall; do mkstub "$m"; done
reset_stub() { rm -f "$ROOT/stub.log" "$ROOT/stub.n" "$ROOT/stub.html"; }
SOK="THROUGHLINE_UX_BROWSER=$ROOT/stub-ok"

# PATH dir with python3 and tools but no browser.
NOB="$ROOT/nobrowser"; mkdir -p "$NOB"
for t in bash sh env python3 git grep sed awk cat dirname mkdir rm ls head tail tr timeout cut base64; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOB/$t"
done
for b in chromium chromium-browser google-chrome chrome; do
  [ -e "$NOB/$b" ] && bad "infra: $b leaked into $NOB"
done

# Fixture writer (same contract as ux-record.test.sh): mk.py <dir> [json-spec].
cat >"$ROOT/mk.py" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]; spec = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
blk = "- **FR-1 [UI] Login.** The user logs in.\n  Details here."
prd = "# PRD\n\n## Requirements\n" + blk + "\n- **FR-2 API.** Not UI.\n"
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
jmut() {
  python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); exec(sys.argv[2]); open(p,"w").write(json.dumps(d,indent=2))' "$1" "$2"
}
VP2='"viewports":[["desktop",1280,800],["phone",390,844]]'
pngs() { find "$1/docs/ux" -name '*.png' 2>/dev/null | sort; }
npng() { pngs "$1" | grep -c . ; }
fp() { sha256sum "$1" | cut -d' ' -f1; stat -c %y "$1"; }   # bytes + mtime fingerprint
rdable() { [ -r "$1" ] || { bad "infra: $1 unreadable before a negated check"; return 1; }; }

echo "[7] render (stub): two viewports × two state files"
R7="$ROOT/r7"; mk "$R7" "{\"screens\":{\"a\":[\"default\",\"error\"]},$VP2}"
before="$(sha256sum "$R7/docs/ux/index.json")"; reset_stub
ux "tl_ux_render $(q "$R7") a" "$SOK"
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^rendered docs/ux/screens/a/.*\.png$')" -eq 4 ] \
  && [ "$(npng "$R7")" -eq 4 ] && ok "[7] four rendered lines, four PNGs" || bad "[7] rc=$RC out='$OUT' err='$ERR'"
for f in default@desktop default@phone error@desktop error@phone; do
  [ -s "$R7/docs/ux/screens/a/$f.png" ] || bad "[7] missing screens/a/$f.png"
done
[ "$LAST" = "screenshots: complete" ] && ok "[7] last line: screenshots: complete" || bad "[7] last '$LAST'"
[ "$(sha256sum "$R7/docs/ux/index.json")" = "$before" ] && ok "[7] index.json bytes unchanged" || bad "[7] index changed"
ux "tl_ux_validate $(q "$R7")"
[ "$RC" -eq 0 ] && [ "$OUT" = "ok 1 screens, 1 requirements, screenshots 4/4" ] \
  && ok "[7] validate reports screenshots 4/4" || bad "[7] validate rc=$RC out='$OUT' err='$ERR'"
if rdable "$ROOT/stub.log" && [ -s "$ROOT/stub.log" ]; then
  grep -qx -- '--host-resolver-rules=MAP \* ~NOTFOUND' "$ROOT/stub.log" && grep -qx -- '--headless=new' "$ROOT/stub.log" \
    && grep -qx -- '--window-size=390,844' "$ROOT/stub.log" \
    && grep -qE -- '^file:///.+/ux/screens/a/error\.html$' "$ROOT/stub.log" \
    && ok "[7] stub argv: --headless=new, resolver rule, window size, file:// URL" || bad "[7] argv: $(cat "$ROOT/stub.log")"
  ! grep -qF -- "file://$R7/docs/ux/" "$ROOT/stub.log" \
    && ok "[7] the browser renders a private copy, never the repo's mock in place" || bad "[7] in-place URL: $(cat "$ROOT/stub.log")"
  if rdable "$ROOT/stub.html"; then
    [ "$(grep -c "Content-Security-Policy\" content=\"script-src 'none'" "$ROOT/stub.html")" -eq 4 ] \
      && ok "[7] every rendered page carries a script-src 'none' CSP (scripts off)" || bad "[7] CSP: $(head -c 600 "$ROOT/stub.html")"
  fi
  [ -z "$(find "$R7/docs" -maxdepth 1 -name '.ux-render.*' 2>/dev/null)" ] && ok "[7] the private copy is removed" \
    || bad "[7] leftover copy: $(ls -a "$R7/docs")"
  ! grep -q -- '--no-sandbox' "$ROOT/stub.log" && ok "[7] stub argv has no --no-sandbox" || bad "[7] --no-sandbox passed"
else bad "[7] stub log empty"; fi

echo "[8] render scoping (FR-99): untouched screens byte-identical"
R8="$ROOT/r8"; mk "$R8" "{\"screens\":{\"a\":[\"default\",\"error\"],\"b\":[\"default\"]},$VP2}"
ux "tl_ux_render $(q "$R8") a b" "$SOK"
[ "$RC" -eq 0 ] && [ "$(npng "$R8")" -eq 6 ] && ok "[8] both screens rendered (6 PNGs)" || bad "[8] rc=$RC out='$OUT'"
b0="$(fp "$R8/docs/ux/screens/b/default@desktop.png")"
a0="$(stat -c %y "$R8/docs/ux/screens/a/default@desktop.png")"
sleep 0.05; sed -i 's#<h1>#<h1>changed #' "$R8/docs/ux/screens/a/default.html"; reset_stub
ux "tl_ux_render $(q "$R8") a" "$SOK"
[ "$RC" -eq 0 ] && [ "$(stat -c %y "$R8/docs/ux/screens/a/default@desktop.png")" != "$a0" ] \
  && ok "[8] a's PNGs rewritten" || bad "[8] a not rewritten rc=$RC"
rdable "$ROOT/stub.log" && ! grep -q 'screens/b/' "$ROOT/stub.log" && ok "[8] the browser was never pointed at b" \
  || bad "[8] b rendered: $(cat "$ROOT/stub.log")"
[ "$(fp "$R8/docs/ux/screens/b/default@desktop.png")" = "$b0" ] && ok "[8] b's bytes and mtime unchanged" || bad "[8] b changed"
jmut "$R8/docs/ux/index.json" 'd["screens"][0]["states"][3]={"name":"error","na":"no errors"}'
rm -f "$R8/docs/ux/screens/a/error.html"
ux "tl_ux_render $(q "$R8") a" "$SOK"
rdable "$R8/docs/ux/screens/a" && [ "$RC" -eq 0 ] && ! ls "$R8/docs/ux/screens/a" | grep -q '^error@' \
  && ok "[8] error state dropped → its old PNGs gone after re-render" || bad "[8] stale error PNG: $(ls "$R8/docs/ux/screens/a")"
ux "tl_ux_validate $(q "$R8")"
[ "$RC" -eq 0 ] && ok "[8] validate rc 0 after superseding" || bad "[8] validate rc=$RC out='$OUT'"

echo "[9] render degrade (rc 4) and explicit-id scoping"
R9="$ROOT/r9"; mk "$R9" "{\"screens\":{\"a\":[\"default\",\"error\"]},$VP2}"
UXPATH="$NOB" ux "tl_ux_render $(q "$R9") a"
[ "$RC" -eq 4 ] && [ "$LAST" = "screenshots not rendered: no headless Chrome on PATH" ] \
  && ok "[9] no browser → rc 4, exact status line" || bad "[9] nobrowser rc=$RC out='$OUT' err='$ERR'"
reset_stub
ux "tl_ux_render $(q "$R9") a" "THROUGHLINE_UX_BROWSER=$ROOT/stub-fail2"
rdable "$R9/docs/ux/screens/a" && [ "$RC" -eq 4 ] && [ "$(npng "$R9")" -eq 0 ] \
  && printf '%s' "$LAST" | grep -qE '^screenshots not rendered: .*stub-fail2 failed on docs/ux/screens/a/[a-z]+\.html \(rc 1\)$' \
  && ok "[9] 2nd shot fails → rc 4, no PNG from this call remains" || bad "[9] fail2 rc=$RC out='$OUT' pngs=$(pngs "$R9")"
! printf '%s\n' "$OUT" | grep -q '^rendered ' && ok "[9] no 'rendered' line for a PNG the same call deleted" \
  || bad "[9] rendered line for a deleted PNG: out='$OUT'"
T="$ROOT/t"; mk "$T" "{\"screens\":{\"a\":[\"default\"],\"b\":[\"default\"]},$VP2}"
ux "tl_ux_render $(q "$T") a b" "$SOK"; [ "$RC" -eq 0 ] || bad "[9] infra: two-screen render rc=$RC"
cp -a "$T" "$ROOT/t-clean"
b0="$(fp "$T/docs/ux/screens/b/default@desktop.png")"
ux "tl_ux_render $(q "$T") a" "THROUGHLINE_UX_BROWSER=$ROOT/stub-failall"
rdable "$T/docs/ux/screens/a" && [ "$RC" -eq 4 ] && ! ls "$T/docs/ux/screens/a" | grep -q '\.png$' \
  && ok "[9] two screens: a's old PNGs gone after a failed re-render" || bad "[9] a: rc=$RC $(ls "$T/docs/ux/screens/a")"
[ "$(fp "$T/docs/ux/screens/b/default@desktop.png")" = "$b0" ] && ok "[9] b's bytes unchanged" || bad "[9] b changed"
ux "tl_ux_validate $(q "$T")"
[ "$RC" -eq 0 ] && [ "$OUT" = "ok 2 screens, 1 requirements, screenshots 2/4" ] \
  && ok "[9] validate rc 0, screenshots 2/4" || bad "[9] validate rc=$RC out='$OUT'"
ux "tl_ux_index_html $(q "$T")"
[ "$RC" -eq 0 ] && grep -qF 'screens/a/default@desktop.png' "$T/docs/ux/index.html" \
  && grep -qF 'screens/a/default@phone.png' "$T/docs/ux/index.html" \
  && ok "[9] index.html lists a's two missing PNGs" || bad "[9] index.html rc=$RC err='$ERR'"
snap() { find "$1/docs/ux" -type f -exec sha256sum {} + | sort; }
s0="$(snap "$T")"
ux "tl_ux_render $(q "$T")" "$SOK"
[ "$RC" -eq 2 ] && printf '%s' "$ERR$OUT" | grep -qF 'ux: render needs explicit screen ids' && [ "$(snap "$T")" = "$s0" ] \
  && ok "[9] no ids → rc 2, message, no file changes" || bad "[9] no ids: rc=$RC out='$OUT' err='$ERR'"
ux "tl_ux_render $(q "$T") zz" "$SOK"
[ "$RC" -eq 2 ] && [ "$(snap "$T")" = "$s0" ] && ok "[9] unknown id → rc 2, no file changes" || bad "[9] unknown: rc=$RC"
C="$ROOT/t-clean"
python3 -I "$ROOT/mk.py" "$ROOT/cgen" "{\"screens\":{\"c\":[\"default\"]}}"
mkdir -p "$C/docs/ux/screens/c"; cp "$ROOT/cgen/docs/ux/screens/c/default.html" "$C/docs/ux/screens/c/"
jmut "$C/docs/ux/index.json" '
c=json.load(open(sys.argv[1].replace("t-clean","cgen")))["screens"][0]
d["screens"].append(c); d["flow"].append("c"); d["requirements"][0]["screens"].append("c")'
ux "tl_ux_validate $(q "$C")"
[ "$RC" -eq 0 ] && [ "$OUT" = "ok 3 screens, 1 requirements, screenshots 4/6" ] \
  && ok "[9] new screen c, HTML only → validate rc 0, screenshots 4/6" || bad "[9] pre-render rc=$RC out='$OUT' err='$ERR'"
ux "tl_ux_render $(q "$C") c" "$SOK"
[ "$RC" -eq 0 ] && [ "$LAST" = "screenshots: complete" ] && ok "[9] render c → screenshots: complete" || bad "[9] c rc=$RC out='$OUT'"
jmut "$C/docs/ux/index.json" 'd["viewports"]=[v for v in d["viewports"] if v["name"]!="phone"]'
ux "tl_ux_validate $(q "$C")"
[ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c '@phone\.png: unreferenced image$')" -eq 3 ] \
  && ok "[9] viewport removed → rc 1, unreferenced image ×3" || bad "[9] vp removed rc=$RC out='$OUT'"
ux "tl_ux_render $(q "$C") a b c" "$SOK"
ux "tl_ux_validate $(q "$C")"
[ "$RC" -eq 0 ] && [ "$OUT" = "ok 3 screens, 1 requirements, screenshots 3/3" ] \
  && ok "[9] rendering every screen clears them → rc 0" || bad "[9] after rerender rc=$RC out='$OUT'"
S="$ROOT/s"; mk "$S" "{\"screens\":{\"a\":[\"default\"],\"b\":[\"default\"]},$VP2}"
ux "tl_ux_render $(q "$S") a b" "$SOK"
UXPATH="$NOB" ux "tl_ux_render $(q "$S") a"
rdable "$S/docs/ux/screens/a" && [ "$RC" -eq 4 ] && ! ls "$S/docs/ux/screens/a" | grep -q '\.png$' \
  && [ "$(ls "$S/docs/ux/screens/b" | grep -c '\.png$')" -eq 2 ] \
  && ok "[9] no browser, scoped: a's PNGs gone, b's remain" || bad "[9] scoped nobrowser rc=$RC"
ux "tl_ux_validate $(q "$S")"
[ "$RC" -eq 0 ] && ok "[9] … and validate rc 0" || bad "[9] scoped validate rc=$RC out='$OUT'"

echo "[9b] capture: reference only, never in-repo"
PORT="$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
mkdir -p "$ROOT/www"; printf '<h1>live</h1>\n' >"$ROOT/www/index.html"
python3 -I -m http.server --bind 127.0.0.1 --directory "$ROOT/www" "$PORT" >/dev/null 2>&1 & SRV=$!
CAP="$ROOT/caps/home"; reset_stub
ux "tl_ux_capture http://127.0.0.1:$PORT/ $(q "$CAP") 390x844" "$SOK"
[ "$RC" -eq 0 ] && [ -s "$CAP/capture-390x844.png" ] && [ "$OUT" = "$CAP/capture-390x844.png" ] \
  && ok "[9b] capture outside the repo → rc 0, PNG written, path printed" || bad "[9b] rc=$RC out='$OUT' err='$ERR'"
if rdable "$ROOT/stub.log" && [ -s "$ROOT/stub.log" ]; then
  ! grep -q -- '--host-resolver-rules' "$ROOT/stub.log" && ! grep -q -- '--no-sandbox' "$ROOT/stub.log" \
    && grep -qx -- "http://127.0.0.1:$PORT/" "$ROOT/stub.log" \
    && ok "[9b] capture argv: the URL, no resolver rule, no --no-sandbox" || bad "[9b] argv: $(cat "$ROOT/stub.log")"
else bad "[9b] stub log empty"; fi
git -C "$T" init -q
ux "tl_ux_capture http://127.0.0.1:$PORT/ $(q "$T/caps/a") 390x844" "$SOK"
[ "$RC" -eq 2 ] && ! [ -e "$T/caps" ] && ok "[9b] outdir inside a git work tree → rc 2" || bad "[9b] inrepo rc=$RC"
mkdir -p "$ROOT/gitrepo" && git -C "$ROOT/gitrepo" init -q
ux "tl_ux_capture http://127.0.0.1:$PORT/ $(q "$ROOT/gitrepo/x/y") 390x844" "$SOK"
[ "$RC" -eq 2 ] && ok "[9b] outdir under a git repo (not yet created) → rc 2" || bad "[9b] gitrepo rc=$RC out='$OUT'"
ux "tl_ux_capture file://$ROOT/www/index.html $(q "$ROOT/caps/f") 390x844" "$SOK"
[ "$RC" -eq 2 ] && ok "[9b] file:// URL → rc 2" || bad "[9b] file url rc=$RC"
UXPATH="$NOB" ux "tl_ux_capture http://127.0.0.1:$PORT/ $(q "$ROOT/caps/n") 390x844"
[ "$RC" -eq 4 ] && printf '%s' "$OUT$ERR" | grep -q 'capture failed: ' && ok "[9b] no browser → rc 4 capture failed" \
  || bad "[9b] nobrowser rc=$RC"

echo "[10] real render (when Chrome/Chromium is present)"
REAL=""; for b in chromium chromium-browser google-chrome chrome; do command -v "$b" >/dev/null 2>&1 && { REAL="$b"; break; }; done
if [ -n "$REAL" ]; then
  R10="$ROOT/r10"; mk "$R10" '{"viewports":[["phone",390,844]]}'
  ux "tl_ux_render $(q "$R10") a" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
  P10="$R10/docs/ux/screens/a/default@phone.png"
  wh="$(python3 -I -c 'import struct,sys; b=open(sys.argv[1],"rb").read(24); print("%dx%d" % struct.unpack(">II", b[16:24]) if b[:8]==b"\x89PNG\r\n\x1a\n" else "notpng")' "$P10" 2>/dev/null)"
  [ "$RC" -eq 0 ] && [ "$wh" = "390x844" ] && ok "[10] real $REAL render → PNG IHDR 390x844" \
    || bad "[10] real render rc=$RC wh='$wh' out='$OUT' err='$(printf '%s' "$ERR" | tail -n 5)'"
else
  echo "  skip — [10] no headless Chrome/Chromium on PATH; real render not observed"
fi

echo "[S] render security: network fully blocked, unsafe mocks and symlinks refused"
RS="$ROOT/rs"; mk "$RS"; reset_stub
ux "tl_ux_render $(q "$RS") a" "$SOK"
if rdable "$ROOT/stub.log" && [ -s "$ROOT/stub.log" ]; then
  grep -qx -- '--proxy-server=http://127.0.0.1:9' "$ROOT/stub.log" && grep -qx -- '--proxy-bypass-list=<-loopback>' "$ROOT/stub.log" \
    && ok "[S] render argv routes all traffic (incl. IP literals, loopback) to a dead proxy" || bad "[S] proxy argv: $(cat "$ROOT/stub.log")"
else bad "[S] stub log empty"; fi
RS2="$ROOT/rs2"; mk "$RS2"; reset_stub
sed -i 's#<head>#<head><iframe src="file:///etc/hostname"></iframe>#' "$RS2/docs/ux/screens/a/default.html"
ux "tl_ux_render $(q "$RS2") a" "$SOK"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'render refused' && [ ! -s "$ROOT/stub.log" ] \
  && ok "[S] a mock referencing file:// is refused before the browser runs (rc 2)" || bad "[S] unsafe mock rc=$RC err='$ERR'"
RS3="$ROOT/rs3"; mk "$RS3"; reset_stub
mkdir -p "$ROOT/victim"; printf 'keep' >"$ROOT/victim/precious.png"
mv "$RS3/docs/ux/screens/a/default.html" "$ROOT/victim/default.html"; rmdir "$RS3/docs/ux/screens/a"
ln -s "$ROOT/victim" "$RS3/docs/ux/screens/a"
ux "tl_ux_render $(q "$RS3") a" "$SOK"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'symlink' && [ -f "$ROOT/victim/precious.png" ] && [ ! -s "$ROOT/stub.log" ] \
  && ok "[S] symlinked screen dir → rc 2, nothing outside the repo deleted or written" || bad "[S] symlink dir rc=$RC err='$ERR'"
RS4="$ROOT/rs4"; mk "$RS4"; mv "$RS4/docs/ux" "$ROOT/uxreal"; ln -s "$ROOT/uxreal" "$RS4/docs/ux"
ux "tl_ux_index_html $(q "$RS4")"
[ "$RC" -eq 2 ] && [ ! -e "$ROOT/uxreal/index.html" ] && ok "[S] symlinked docs/ux → index-html rc 2, writes nothing" \
  || bad "[S] symlinked docs/ux rc=$RC err='$ERR'"

RS5="$ROOT/rs5"; mk "$RS5" "{\"screens\":{\"a\":[\"default\"],\"b\":[\"default\"]}}"
ux "tl_ux_render $(q "$RS5") a b" "$SOK"; [ "$RC" -eq 0 ] || bad "[S] infra: rs5 render rc=$RC"
s5="$(find "$RS5/docs/ux" -type f -exec sha256sum {} + | sort)"; rm -f "$RS5/docs/ux/screens/b/default.html"
s5="$(printf '%s\n' "$s5" | grep -v 'screens/b/default\.html$')"; reset_stub
ux "tl_ux_render $(q "$RS5") a b" "$SOK"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF 'missing mock docs/ux/screens/b/default.html' && [ ! -s "$ROOT/stub.log" ] \
  && [ "$(find "$RS5/docs/ux" -type f -exec sha256sum {} + | sort)" = "$s5" ] \
  && ok "[S] mock missing at render → rc 2 (invalid input), nothing cleared or rendered" || bad "[S] missing mock rc=$RC out='$OUT' err='$ERR'"
RS6="$ROOT/rs 6#x%y"; mk "$RS6"; reset_stub
ux "tl_ux_render $(q "$RS6") a" "$SOK"
if rdable "$ROOT/stub.log" && [ "$RC" -eq 0 ]; then
  u="$(grep '^file://' "$ROOT/stub.log")"
  printf '%s' "$u" | grep -qE '^file:///[^ #?]+/ux/screens/a/default\.html$' && [ -s "$ROOT/stub.html" ] \
    && ok "[S] render URL is a proper file URI (pathlib as_uri)" || bad "[S] URL '$u'"
else bad "[S] special-char repo render rc=$RC err='$ERR'"; fi
PLUG="$ROOT/plug"; mkdir -p "$PLUG/scripts/lib"; cp "$REPO/scripts/lib/"ux_*.py "$PLUG/scripts/lib/"
RS7="$ROOT/rs7"; mk "$RS7"
ux "tl_ux_validate $(q "$RS7"); tl_ux_render $(q "$RS7") a; tl_ux_index_html $(q "$RS7")" "$SOK" CLAUDE_PLUGIN_ROOT="$PLUG"
rdable "$PLUG/scripts/lib" && [ "$RC" -eq 0 ] && [ -z "$(find "$PLUG" -name '__pycache__' -o -name '*.pyc')" ] \
  && ok "[S] no __pycache__/.pyc written into the plugin tree" || bad "[S] bytecode: rc=$RC $(find "$PLUG")"
echo "[S] real browser: a JS-navigating mock cannot pull a local file into the PNG"
redpx() {  # count pure-red pixels in an 8-bit RGB(A) PNG; 'err' if unreadable
  python3 -I -c '
import struct, sys, zlib
b = open(sys.argv[1], "rb").read()
assert b[:8] == b"\x89PNG\r\n\x1a\n"
i, idat, ihdr = 8, b"", None
while i < len(b):
    n, t = struct.unpack(">I4s", b[i:i+8]); c = b[i+8:i+8+n]; i += 12 + n
    if t == b"IHDR": ihdr = struct.unpack(">IIBBBBB", c)
    elif t == b"IDAT": idat += c
w, h, depth, ct = ihdr[:4]
assert depth == 8 and ct in (2, 6)
bpp = 3 if ct == 2 else 4; st = w * bpp; raw = zlib.decompress(idat); prev = bytearray(st); red = 0
for y in range(h):
    f = raw[y*(st+1)]; cur = bytearray(raw[y*(st+1)+1:(y+1)*(st+1)])
    for x in range(st):
        a = cur[x-bpp] if x >= bpp else 0; up = prev[x]; ul = prev[x-bpp] if x >= bpp else 0
        if f == 1: cur[x] = (cur[x] + a) & 255
        elif f == 2: cur[x] = (cur[x] + up) & 255
        elif f == 3: cur[x] = (cur[x] + (a + up) // 2) & 255
        elif f == 4:
            p = a + up - ul; pa, pb, pc = abs(p-a), abs(p-up), abs(p-ul)
            cur[x] = (cur[x] + (a if pa <= pb and pa <= pc else up if pb <= pc else ul)) & 255
    for x in range(0, st, bpp):
        if cur[x] > 200 and cur[x+1] < 60 and cur[x+2] < 60: red += 1
    prev = cur
print(red)' "$1" 2>/dev/null || echo err
}
if [ -n "$REAL" ]; then
  CAN="$ROOT/outside-canary"; mkdir -p "$CAN"
  printf '<html><body style="margin:0;background:#ff0000"><h1>SECRET-CANARY-1234</h1></body></html>\n' >"$CAN/canary.html"
  RJ="$ROOT/rj"; mk "$RJ" '{"viewports":[["phone",390,844]]}'
  printf "<!doctype html><html><head><title>a</title></head><body>b<script>location='file://'+'%s'+'/canary.html'</script></body></html>\n" "$CAN" \
    >"$RJ/docs/ux/screens/a/default.html"
  CTL="$ROOT/ctl.png"; cp "$RJ/docs/ux/screens/a/default.html" "$ROOT/ctl.html"
  timeout 60 "$REAL" --headless=new --disable-gpu --hide-scrollbars --window-size=390,844 --screenshot="$CTL" "file://$ROOT/ctl.html" >/dev/null 2>&1
  ctl="$(redpx "$CTL")"
  ux "tl_ux_validate $(q "$RJ")"
  [ "$RC" -eq 0 ] && ok "[S] infra: the JS-navigating mock passes the static scan (only the browser can stop it)" \
    || bad "[S] infra: JS mock validate rc=$RC out='$OUT'"
  ux "tl_ux_render $(q "$RJ") a" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
  PJ="$RJ/docs/ux/screens/a/default@phone.png"; got="$(redpx "$PJ")"
  if [ "$ctl" = err ] || [ "$ctl" -eq 0 ]; then
    echo "  note — [S] control render did not navigate (red=$ctl); canary check below proves less"
  else ok "[S] control: the same mock rendered without protection shows the canary ($ctl red px)"; fi
  [ "$RC" -eq 0 ] && [ "$got" != err ] && [ "$got" -eq 0 ] \
    && ok "[S] real $REAL render of the JS-navigating mock → PNG has no canary content" \
    || bad "[S] canary leak: rc=$RC red='$got' out='$OUT' err='$(printf '%s' "$ERR" | tail -n 3)'"
else
  echo "  skip — [S] no headless Chrome/Chromium on PATH; real-browser canary check not observed"
fi

echo "[11] index.html: deterministic, escaped, flow-ordered, provenance"
R11="$ROOT/r11"
mk "$R11" "{\"screens\":{\"a\":[\"default\",\"error\"],\"b\":[\"default\"]},\"flow\":[\"b\",\"a\"],\"titles\":{\"a\":\"<img src=x onerror=alert(1)>\"},\"delegates\":[\"frontend-design\"],\"fidelity\":\"high\",$VP2}"
ux "tl_ux_index_html $(q "$R11")"; h1="$(sha256sum <"$R11/docs/ux/index.html" 2>/dev/null)"
ux "tl_ux_index_html $(q "$R11")"; h2="$(sha256sum <"$R11/docs/ux/index.html" 2>/dev/null)"
[ "$RC" -eq 0 ] && [ -n "$h1" ] && [ "$h1" = "$h2" ] && ok "[11] two runs → identical bytes" || bad "[11] rc=$RC err='$ERR'"
IH="$R11/docs/ux/index.html"
if rdable "$IH"; then
  grep -qF '&lt;img src=x onerror=alert(1)&gt;' "$IH" && ! grep -qF '<img src=x onerror' "$IH" \
    && ok "[11] hostile title escaped" || bad "[11] escaping"
  lb="$(grep -n 'href="screens/b/default.html"' "$IH" | head -n1 | cut -d: -f1)"
  la="$(grep -n 'href="screens/a/default.html"' "$IH" | head -n1 | cut -d: -f1)"
  [ -n "$lb" ] && [ -n "$la" ] && [ "$lb" -lt "$la" ] && grep -qF 'href="screens/a/error.html"' "$IH" \
    && ok "[11] flow links in flow order (b before a), other states linked" || bad "[11] order lb=$lb la=$la"
  grep -qF 'frontend-design' "$IH" && ! grep -qF 'none: degraded' "$IH" && grep -qF 'abc1234' "$IH" \
    && grep -qF '0/6' "$IH" && ok "[11] provenance names delegates, PRD rev, screenshot count" || bad "[11] provenance"
  ! grep -qiE '(src|href)="(https?:)?//' "$IH" && ok "[11] index.html has no external URL" || bad "[11] external URL"
fi
jmut "$R11/docs/ux/index.json" 'd["delegates"]=[]; d["fidelity"]="low"'
ux "tl_ux_index_html $(q "$R11")"
[ "$RC" -eq 0 ] && grep -qF 'none: degraded' "$IH" && ok "[11] no delegates → none: degraded" || bad "[11] degraded rc=$RC"
printf 'nope' >"$R11/docs/ux/index.json"
ux "tl_ux_index_html $(q "$R11")"
[ "$RC" -eq 2 ] && ok "[11] invalid index → rc 2" || bad "[11] invalid rc=$RC"

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== ux-render eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

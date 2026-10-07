#!/usr/bin/env bash
# ux-render.test.sh — eval for TDD 0070 / FR-91, FR-94, FR-99, NFR-4: screenshot
# rendering (scoped clear, whole-set status, rc-4 degrade), captures that are
# never in-repo, and the generated index.html flow page.
#
# Observation points 7–11, 9b and 10b of the TDD's Verification plan.
# Section [C] covers cleanup: a SIGTERM/SIGHUP to render removes the private
# copy and stops the browser; the browser profile, HOME and TMPDIR stay inside
# the private tree (no ~/Downloads write from a downloading mock). A stub
# browser (THROUGHLINE_UX_BROWSER) writes a 1×1 PNG, logs its argv, and fetches
# its http://127.0.0.1 URL while render's loopback server is live (body, headers);
# when a real Chrome/Chromium is on PATH, obs 10 and the 10b isolation probe
# matrix run against it (skipped with a printed note when none exists;
# --no-sandbox is never passed). Every negated
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
# counts calls in $ROOT/stub.n. A render URL is fetched by fetch.py (body →
# stub.html, first 57 bytes → stub.heads, headers → stub.hdrs), and the
# browser's TMPDIR and HOME go to stub.tmpls. ok: always writes a 1×1 PNG. fail2: writes the
# PNG then exits 1 on its 2nd call. failall: exits 1 without writing.
cat >"$ROOT/fetch.py" <<'PY'
import sys, urllib.error, urllib.request
url, root = sys.argv[1], sys.argv[2]
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
r = op.open(url, timeout=10); body = r.read()
open(root + "/stub.html", "ab").write(body + b"\n")
open(root + "/stub.heads", "ab").write(body[:57] + b"\n")
with open(root + "/stub.hdrs", "a") as f:
    f.write("URL %s\n" % url)
    for k, v in r.headers.items():
        f.write("%s: %s\n" % (k, v))
    base = url.split("/screens/")[0]
    for bad in ("/screens/nope.html", "/%2e%2e/%2e%2e/%2e%2e/etc/hostname"):
        try:
            op.open(base + bad, timeout=10); f.write("ERR 200 %s\n" % bad)
        except urllib.error.HTTPError as e:
            f.write("ERR %d CSP: %s\n" % (e.code, e.headers.get("Content-Security-Policy")))
PY
PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
mkstub() {
  cat >"$ROOT/stub-$1" <<EOF
#!$BASH_BIN
for a in "\$@"; do printf '%s\n' "\$a"; done >>"$ROOT/stub.log"; echo --- >>"$ROOT/stub.log"
n=\$(( \$(cat "$ROOT/stub.n" 2>/dev/null || echo 0) + 1 )); echo \$n >"$ROOT/stub.n"
out=""; for a in "\$@"; do case "\$a" in --screenshot=*) out="\${a#--screenshot=}" ;; http://127.0.0.1:*/screens/*) python3 -I "$ROOT/fetch.py" "\$a" "$ROOT" 2>>"$ROOT/stub.ferr" ;; esac; done
printf 'TMPDIR=%s\nHOME=%s\n' "\${TMPDIR:-}" "\${HOME:-}" >>"$ROOT/stub.tmpls"
mode=$1
[ "\$mode" = failall ] && exit 1
printf '%s' '$PNG_B64' | base64 -d >"\$out"
[ "\$mode" = fail2 ] && [ "\$n" -eq 2 ] && exit 1
exit 0
EOF
  chmod +x "$ROOT/stub-$1"
}
for m in ok fail2 failall; do mkstub "$m"; done
reset_stub() { rm -f "$ROOT/stub.log" "$ROOT/stub.n" "$ROOT/stub.html" "$ROOT/stub.heads" "$ROOT/stub.hdrs" "$ROOT/stub.tmpls"; }
POLICY="default-src 'self' data:; script-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'; style-src 'self' 'unsafe-inline' data:"
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
# px <png> <rrggbb>: pixels within ±40 per channel of the colour ('err' if unreadable).
cat >"$ROOT/px.py" <<'PY'
import struct, sys, zlib
b = open(sys.argv[1], "rb").read(); tgt = bytes.fromhex(sys.argv[2])
assert b[:8] == b"\x89PNG\r\n\x1a\n"
i, idat, ihdr = 8, b"", None
while i < len(b):
    n, t = struct.unpack(">I4s", b[i:i+8]); c = b[i+8:i+8+n]; i += 12 + n
    if t == b"IHDR": ihdr = struct.unpack(">IIBBBBB", c)
    elif t == b"IDAT": idat += c
w, h, depth, ct = ihdr[:4]
assert depth == 8 and ct in (2, 6)
bpp = 3 if ct == 2 else 4; st = w * bpp; raw = zlib.decompress(idat); prev = bytearray(st); hit = 0
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
        if all(abs(cur[x+k] - tgt[k]) <= 40 for k in range(3)): hit += 1
    prev = cur
print(hit)
PY
px() { python3 -I "$ROOT/px.py" "$1" "$2" 2>/dev/null || echo err; }
npng() { pngs "$1" | grep -c . ; }
fp() { sha256sum "$1" | cut -d' ' -f1; stat -c %y "$1"; }   # bytes + mtime fingerprint
rdable() { [ -r "$1" ] || { bad "infra: $1 unreadable before a negated check"; return 1; }; }

echo "[7] render (stub): two viewports × two state files"
R7="$ROOT/r7"; mk "$R7" "{\"screens\":{\"a\":[\"default\",\"error\"]},$VP2}"
before="$(sha256sum "$R7/docs/ux/index.json")"; reset_stub; T7="$ROOT/tmp7"; mkdir -p "$T7"
ux "tl_ux_render $(q "$R7") a" "$SOK" TMPDIR="$T7"
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
  url7="$(grep -E '^http://127\.0\.0\.1:[0-9]+/screens/a/error\.html$' "$ROOT/stub.log" | head -n1)"; p7="${url7#http://127.0.0.1:}"; p7="${p7%%/*}"
  grep -qx -- '--host-resolver-rules=MAP \* ~NOTFOUND, EXCLUDE 127.0.0.1' "$ROOT/stub.log" && grep -qx -- '--headless=new' "$ROOT/stub.log" \
    && grep -qx -- '--window-size=390,844' "$ROOT/stub.log" && [ -n "$url7" ] \
    && grep -qx -- '--proxy-server=http://127.0.0.1:9' "$ROOT/stub.log" \
    && grep -qxF -- "--proxy-bypass-list=<-loopback>;127.0.0.1:$p7" "$ROOT/stub.log" \
    && ok "[7] stub argv: --headless=new, resolver rule, dead proxy, bypass only the server port, http://127.0.0.1 URL" \
    || bad "[7] argv: $(cat "$ROOT/stub.log")"
  ! grep -q 'file://' "$ROOT/stub.log" && ok "[7] no file:// URL reaches the browser" || bad "[7] file:// in argv: $(cat "$ROOT/stub.log")"
  if rdable "$ROOT/stub.heads" && rdable "$ROOT/stub.hdrs"; then
    [ "$(grep -c . "$ROOT/stub.heads")" -eq 4 ] && ! grep -qvxF '<!DOCTYPE html><meta http-equiv="Content-Security-Policy"' "$ROOT/stub.heads" \
      && [ "$(grep -cF "content=\"$POLICY\"" "$ROOT/stub.html")" -eq 4 ] \
      && ok "[7] each served page starts with our doctype + the exact CSP meta" || bad "[7] bodies: $(head -c 600 "$ROOT/stub.html")"
    [ "$(grep -cxF "Content-Security-Policy: $POLICY" "$ROOT/stub.hdrs")" -eq 4 ] \
      && [ "$(grep -cixF 'Content-Type: text/html; charset=utf-8' "$ROOT/stub.hdrs")" -eq 4 ] \
      && ok "[7] each page response has the CSP header and text/html; charset=utf-8" || bad "[7] headers: $(cat "$ROOT/stub.hdrs")"
    [ "$(grep -cxF "ERR 404 CSP: $POLICY" "$ROOT/stub.hdrs")" -eq 8 ] \
      && ok "[7] 404s (missing file, %2e%2e climb) also carry the CSP header" || bad "[7] error responses: $(grep ^ERR "$ROOT/stub.hdrs")"
  else bad "[7] the stub fetched nothing: $(cat "$ROOT/stub.ferr" 2>/dev/null)"; fi
  rdable "$ROOT/stub.tmpls" && [ -s "$ROOT/stub.tmpls" ] && rdable "$T7" && [ -z "$(ls -A "$T7")" ] \
    && [ "$(grep -cF "TMPDIR=$T7/ux-render." "$ROOT/stub.tmpls")" -eq 4 ] \
    && [ "$(grep -cF "HOME=$T7/ux-render." "$ROOT/stub.tmpls")" -eq 4 ] \
    && [ -z "$(find "$R7/docs" -maxdepth 1 -name '.ux-render.*')" ] \
    && ok "[7] the browser's TMPDIR and HOME lived in the private \$TMPDIR/ux-render.* tree and are gone after" \
    || bad "[7] copy: during='$(cat "$ROOT/stub.tmpls" 2>/dev/null)' after='$(ls -A "$T7")' docs='$(ls -a "$R7/docs")'"
  udd="$(grep -m1 '^--user-data-dir=' "$ROOT/stub.log")"; udd="${udd#--user-data-dir=}"
  [ "$(grep -c '^--user-data-dir=' "$ROOT/stub.log")" -eq 4 ] && [ "$(grep '^--user-data-dir=' "$ROOT/stub.log" | sort -u | wc -l)" -eq 1 ] \
    && case "$udd" in "$T7"/ux-render.*/*) true ;; *) false ;; esac && [ ! -e "$udd" ] \
    && ok "[7] every shot gets one per-render --user-data-dir inside the private tree, removed after" \
    || bad "[7] user-data-dir: '$(grep '^--user-data-dir=' "$ROOT/stub.log")' exists-after=$([ -e "$udd" ] && echo y)"
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
CAP="$ROOT/caps/home"; reset_stub; TC="$ROOT/tmpc"; mkdir -p "$TC"
ux "tl_ux_capture http://127.0.0.1:$PORT/ $(q "$CAP") 390x844" "$SOK" TMPDIR="$TC"
[ "$RC" -eq 0 ] && [ -s "$CAP/capture-390x844.png" ] && [ "$OUT" = "$CAP/capture-390x844.png" ] \
  && ok "[9b] capture outside the repo → rc 0, PNG written, path printed" || bad "[9b] rc=$RC out='$OUT' err='$ERR'"
if rdable "$ROOT/stub.log" && [ -s "$ROOT/stub.log" ]; then
  ! grep -q -- '--host-resolver-rules' "$ROOT/stub.log" && ! grep -q -- '--no-sandbox' "$ROOT/stub.log" \
    && ! grep -q -- '--proxy-server' "$ROOT/stub.log" && ! grep -q -- '--proxy-bypass-list' "$ROOT/stub.log" \
    && grep -qx -- "http://127.0.0.1:$PORT/" "$ROOT/stub.log" \
    && ok "[9b] capture argv: the URL, no resolver rule, no proxy flags, no --no-sandbox" || bad "[9b] argv: $(cat "$ROOT/stub.log")"
  udd="$(grep -m1 '^--user-data-dir=' "$ROOT/stub.log")"; udd="${udd#--user-data-dir=}"
  rdable "$TC" && case "$udd" in "$TC"/ux-capture.*/*) true ;; *) false ;; esac && [ ! -e "$udd" ] && [ -z "$(ls -A "$TC")" ] \
    && grep -qF "HOME=$TC/ux-capture." "$ROOT/stub.tmpls" && grep -qF "TMPDIR=$TC/ux-capture." "$ROOT/stub.tmpls" \
    && ok "[9b] capture: throwaway --user-data-dir, HOME and TMPDIR under its own mkdtemp, removed after" \
    || bad "[9b] capture profile: udd='$udd' left='$(ls -A "$TC")' env='$(cat "$ROOT/stub.tmpls" 2>/dev/null)'"
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

echo "[C] a signalled render removes its private copy and stops its browser"
# stub-sleep logs argv, records its pid and a child sleep's pid, then blocks.
cat >"$ROOT/stub-sleep" <<EOF
#!$BASH_BIN
for a in "\$@"; do printf '%s\n' "\$a"; done >>"$ROOT/stub.log"; echo --- >>"$ROOT/stub.log"
sleep 300 & echo "\$\$ \$!" >"$ROOT/stub.pids"
wait
EOF
chmod +x "$ROOT/stub-sleep"
gone() { local i; for i in $(seq 50); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
for sig in TERM:143 HUP:129; do
  s="${sig%%:*}"; want="${sig#*:}"; RG="$ROOT/rg-$s"; TG="$ROOT/tg-$s"; mk "$RG"; mkdir -p "$TG"
  reset_stub; rm -f "$ROOT/stub.pids"
  env -i HOME="$H" PATH="$PATH" TMPDIR="$TG" THROUGHLINE_UX_BROWSER="$ROOT/stub-sleep" \
    python3 -I -B "$REPO/scripts/lib/ux_render.py" render "$RG" a >"$ROOT/out" 2>"$ROOT/err" & PY=$!
  for i in $(seq 100); do [ -s "$ROOT/stub.pids" ] && break; sleep 0.1; done
  during="$(ls -A "$TG")"
  kill -"$s" "$PY"; wait "$PY"; rc=$?
  read -r sp cp <"$ROOT/stub.pids" 2>/dev/null || { sp=""; cp=""; }
  printf '%s' "$during" | grep -q '^ux-render\.' || bad "[C] infra: no private copy in \$TMPDIR before SIG$s ('$during')"
  rdable "$TG" && [ "$rc" -eq "$want" ] && [ -z "$(ls -A "$TG")" ] \
    && ok "[C] SIG$s mid-render → rc $want, no ux-render.* left in \$TMPDIR" \
    || bad "[C] SIG$s: rc=$rc left='$(ls -A "$TG")' err='$(cat "$ROOT/err")'"
  [ -n "$sp" ] && gone "$sp" && gone "$cp" && ok "[C] SIG$s: the stub browser and its child are gone" \
    || { bad "[C] SIG$s: browser survived (pids '$sp' '$cp')"; kill -9 $sp $cp 2>/dev/null; }
  udd="$(grep -m1 '^--user-data-dir=' "$ROOT/stub.log" 2>/dev/null)"; udd="${udd#--user-data-dir=}"
  case "$udd" in "$TG"/ux-render.*/*) [ ! -e "$udd" ] ;; *) false ;; esac \
    && ok "[C] SIG$s: --user-data-dir was inside the private tree and is gone" || bad "[C] SIG$s: user-data-dir '$udd'"
done

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

echo "[C] real browser: a mock that downloads a file writes nothing into \$HOME"
if [ -n "$REAL" ]; then
  RD="$ROOT/rd"; mk "$RD" '{"viewports":[["phone",390,844]]}'; FH="$ROOT/fakehome"; TD="$ROOT/td"; mkdir -p "$FH/Downloads" "$TD"
  printf '<!doctype html><html><head><title>d</title><meta http-equiv="refresh" content="0;url=e"></head><body>x</body></html>\n' \
    >"$RD/docs/ux/screens/a/default.html"
  printf 'payload' >"$RD/docs/ux/screens/a/e"
  env -i HOME="$FH" PATH="$PATH" TMPDIR="$TD" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
    python3 -I -B "$REPO/scripts/lib/ux_render.py" render "$RD" a >"$ROOT/out" 2>"$ROOT/err" & PY=$!
  # The download stalls the shot until its timeout; stop the render once the
  # private copy of the download exists (also exercises SIGTERM with Chrome).
  seen=""; for i in $(seq 700); do
    kill -0 "$PY" 2>/dev/null || break
    [ -n "$(find "$TD" -path '*/Downloads/*' -type f 2>/dev/null)" ] && { seen=y; break; }; sleep 0.1
  done
  kill -TERM "$PY" 2>/dev/null; wait "$PY"; rc=$?
  [ -n "$seen" ] || echo "  note — [C] the download never appeared in the private tree (rc $rc); the HOME check proves less"
  rdable "$FH/Downloads" && [ -z "$(ls -A "$FH/Downloads")" ] && [ "$(find "$FH" -mindepth 1 | wc -l)" -eq 1 ] \
    && ok "[C] real $REAL: nothing downloaded into \$HOME/Downloads, nothing else written under \$HOME" \
    || bad "[C] HOME written: $(find "$FH" -mindepth 1 -maxdepth 2 | tr '\n' ' ')"
  gone_c=y; for i in $(seq 50); do pgrep -f -- "$TD" >/dev/null || break; sleep 0.1; done
  pgrep -f -- "$TD" >/dev/null && gone_c=""
  rdable "$TD" && [ -z "$(ls -A "$TD")" ] && [ -n "$gone_c" ] && case "$rc" in 0|4|143) true ;; *) false ;; esac \
    && ok "[C] real $REAL: render stopped (rc $rc), no Chrome left running, nothing left in \$TMPDIR" \
    || { bad "[C] after real download render: rc=$rc left='$(ls -A "$TD")' chrome-left=$([ -z "$gone_c" ] && echo y)"; pkill -9 -f -- "$TD"; }
else
  echo "  skip — [C] no headless Chrome/Chromium on PATH; real-browser download check not observed"
fi

echo "[10b] isolation probe matrix (real Chrome): the browser holds the boundary"
# vec.py <repo> <vector> <canary-dir> <port>: rewrite screen a's mock (and CSS)
# as one probe vector. Every mock links tokens.css; the canary is magenta.
cat >"$ROOT/vec.py" <<'PY'
import base64, os, sys
root, v, can, port = sys.argv[1:5]
ud = os.path.join(root, "docs/ux"); png = can + "/canary.png"; climb = "/.." * 30
full = 'width=390 height=844 style="position:fixed;top:0;left:0"'
evil = lambda u: "body{background:url(" + u + ") !important}\n"
js = "<script>location='file://'+'" + can + "/canary.html'</script>"
tok, pre, head, body = ":root{--c:#123456}\n", "", "", "<h1>mock</h1>"
if v == "tokens-css": tok = evil(png)
elif v == "shared-css":
    open(os.path.join(ud, "shared.css"), "w").write(evil(png)); head = '<link rel="stylesheet" href="../../shared.css">'
elif v == "data-css-b64":
    head = '<link rel="stylesheet" href="data:text/css;base64,%s">' % base64.b64encode(evil("file://" + png).encode()).decode()
elif v == "css-loopback-port": tok = evil("http://127.0.0.1:" + port + "/canary.png")
elif v == "css-pct-climb": tok = evil("/%2e%2e" * 30 + png)
elif v == "bang-comment": pre = "<!-->" + js + "<!-- -->"
elif v == "bang-dash-comment": pre = "<!--->" + js + "<!-- -->"
elif v == "img-unquoted-eq": body = "<img src=x=" + climb + png + " " + full + ">"
elif v == "img-backtick": body = "<img src=`" + climb + png + " " + full + ">"
elif v == "img-nbsp": body = "<img src=x " + climb + png + " " + full + ">"
elif v == "meta-refresh": head = "<meta http-equiv=refresh content=0;url=file://" + can + "/canary.html>"
elif v == "base-file": head, body = '<base href="file:///">', '<img src="' + png[1:] + '" ' + full + ">"
elif v == "img-loopback-port": body = '<img src="http://127.0.0.1:' + port + '/canary.png" ' + full + ">"
elif v == "img-pct-climb": body = '<img src="' + "%2e%2e/" * 30 + png[1:] + '" ' + full + ">"
elif v == "legit-styled": tok = ":root{--brand:#0a7d32}\nbody{background:var(--brand);margin:0}\n"
elif v == "legit-svg":
    body = '<svg width="390" height="844"><rect width="390" height="844" fill="#1e40af"/></svg><p>See https://example.com</p>'
open(os.path.join(ud, "tokens.css"), "w").write(tok)
with open(os.path.join(ud, "screens/a/default.html"), "w", encoding="utf-8") as f:
    f.write(pre + '<!doctype html><html><head><title>m</title><link rel="stylesheet" href="../../tokens.css">'
            + head + "</head><body>" + body + "</body></html>\n")
PY
# probe <vector> <must|any|legit:rrggbb>: validate rc / render rc / canary px.
probe() {
  local v="$1" P="$ROOT/v-$1" vr rr got f
  mk "$P" '{"viewports":[["phone",390,844]]}'; python3 -I "$ROOT/vec.py" "$P" "$v" "$CAN" "$PORT"
  ux "tl_ux_validate $(q "$P")"; vr=$RC
  ux "tl_ux_render $(q "$P") a" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"; rr=$RC
  f="$P/docs/ux/screens/a/default@phone.png"; got=nopng; [ -e "$f" ] && got="$(px "$f" ff00ff)"
  printf '  probe %-18s validate %s / render %s / canary px %s\n' "$v" "$vr" "$rr" "$got"
  case "$2" in
    must) [ "$vr" -eq 0 ] && [ "$rr" -eq 0 ] && [ "$got" = 0 ] \
            && ok "[10b] $v: passes validate, renders, 0 canary px (browser-enforced)" \
            || bad "[10b] $v: validate $vr render $rr canary '$got' out='$OUT' err='$(printf '%s' "$ERR" | tail -n 3)'" ;;
    any) if { [ "$rr" -eq 0 ] && [ "$got" = 0 ]; } || { [ "$rr" -eq 2 ] && [ "$got" = nopng ]; } \
            || { [ "$rr" -eq 4 ] && [ "$got" = nopng ]; }; then ok "[10b] $v: no leak (render rc $rr, canary $got)"
         else bad "[10b] $v: LEAK validate $vr render $rr canary '$got'"; fi ;;
    legit:*) local n; n="$([ -e "$f" ] && px "$f" "${2#legit:}" || echo nopng)"
         [ "$vr" -eq 0 ] && [ "$rr" -eq 0 ] && [ "$n" != err ] && [ "$n" != nopng ] && [ "$n" -gt 10000 ] \
            && ok "[10] $v renders non-blank under isolation ($n px of #${2#legit:})" \
            || bad "[10] $v: validate $vr render $rr px '$n' err='$(printf '%s' "$ERR" | tail -n 3)'" ;;
  esac
}
if [ -n "$REAL" ]; then
  CAN="$ROOT/outside-canary"; mkdir -p "$CAN"
  printf '<html><body style="margin:0;background:#ff00ff"><h1>SECRET-CANARY</h1></body></html>\n' >"$CAN/canary.html"
  python3 -I -c '
import struct, sys, zlib
def ch(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
raw = b"".join(b"\0" + b"\xff\x00\xff" * 8 for _ in range(8))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0))
                              + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))' "$CAN/canary.png"
  cp "$CAN/canary.png" "$ROOT/www/canary.png"   # the 9b server: "another loopback port"
  probe legit-styled legit:0a7d32; probe legit-svg legit:1e40af
  for v in tokens-css shared-css data-css-b64 css-loopback-port css-pct-climb; do probe "$v" must; done
  for v in bang-comment bang-dash-comment img-unquoted-eq img-backtick img-nbsp meta-refresh base-file \
           img-loopback-port img-pct-climb; do probe "$v" any; done
  C10="$ROOT/ctl10b.png"
  timeout 60 "$REAL" --headless=new --disable-gpu --hide-scrollbars --window-size=390,844 --screenshot="$C10" \
    "file://$ROOT/v-tokens-css/docs/ux/screens/a/default.html" >/dev/null 2>&1
  c="$(px "$C10" ff00ff)"
  [ "$c" != err ] && [ "$c" -gt 0 ] && ok "[10b] control: the tokens-css mock over unisolated file:// shows the canary ($c px)" \
    || bad "[10b] control did not show the canary (px '$c'); the probe cannot see a leak"
else
  echo "  skip — [10b] no headless Chrome/Chromium on PATH; isolation probe matrix not observed"
fi

echo "[S] render security: network fully blocked, unsafe mocks and symlinks refused"
RS="$ROOT/rs"; mk "$RS"; reset_stub
ux "tl_ux_render $(q "$RS") a" "$SOK"
if rdable "$ROOT/stub.log" && [ -s "$ROOT/stub.log" ]; then
  grep -qx -- '--proxy-server=http://127.0.0.1:9' "$ROOT/stub.log" && grep -qxE -- '--proxy-bypass-list=<-loopback>;127\.0\.0\.1:[0-9]+' "$ROOT/stub.log" \
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
  u="$(grep '^http://' "$ROOT/stub.log")"
  printf '%s' "$u" | grep -qE '^http://127\.0\.0\.1:[0-9]+/screens/a/default\.html$' && grep -qF '<h1>default</h1>' "$ROOT/stub.html" \
    && ok "[S] a repo path with ' ', '#', '%' still serves the mock (URL is server-relative)" || bad "[S] URL '$u'"
else bad "[S] special-char repo render rc=$RC err='$ERR'"; fi
PLUG="$ROOT/plug"; mkdir -p "$PLUG/scripts/lib"; cp "$REPO/scripts/lib/"ux_*.py "$PLUG/scripts/lib/"
RS7="$ROOT/rs7"; mk "$RS7"
ux "tl_ux_validate $(q "$RS7"); tl_ux_render $(q "$RS7") a; tl_ux_index_html $(q "$RS7")" "$SOK" CLAUDE_PLUGIN_ROOT="$PLUG"
rdable "$PLUG/scripts/lib" && [ "$RC" -eq 0 ] && [ -z "$(find "$PLUG" -name '__pycache__' -o -name '*.pyc')" ] \
  && ok "[S] no __pycache__/.pyc written into the plugin tree" || bad "[S] bytecode: rc=$RC $(find "$PLUG")"
echo "[S] real browser: a JS-navigating mock cannot pull a local file into the PNG"
redpx() { px "$1" ff0000; }
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

echo "[S] CSP prefix: every rendered copy starts with our doctype + CSP, whatever precedes the mock's doctype"
# pfx.py <ux-dir> <canary-url>: one screen per prefix case; each mock tries to
# navigate to the canary before (or instead of) its own doctype.
cat >"$ROOT/pfx.py" <<'PY'
import os, sys
ud, can = sys.argv[1], sys.argv[2]
js = b"<script>location='file://'+'" + can.encode() + b"'</script>"
body = b"<html><head><title>m</title></head><body><h1>mock</h1></body></html>\n"
cases = {
    "p1": b"<!-->" + js + b"<!-- --><!doctype html>" + body,                     # abruptly-closed comment
    "p2": b"<!--->" + js + b"<!-- --><!doctype html>" + body,                    # abruptly-closed comment
    "p3": b"<!-- c -->\n<!doctype html><html><head>" + js + b"</head><body><h1>mock</h1></body></html>\n",
    "p4": b"<html><head>" + js + b"</head><body><h1>mock</h1></body></html>\n",   # no doctype
    "p5": b"\xef\xbb\xbf" + js + b"<!doctype html>" + body,                      # BOM then script
    "p6": b"<!-- c -->\r\n<!doctype html>\r\n<html>\r\n<head>" + js + b"</head>\r\n<body><h1>mock</h1></body>\r\n</html>\r\n",
}
for sid, b in cases.items():
    open(os.path.join(ud, "screens", sid, "default.html"), "wb").write(b)
PY
PIDS='"p1":["default"],"p2":["default"],"p3":["default"],"p4":["default"],"p5":["default"],"p6":["default"]'
PFX='<!DOCTYPE html><meta http-equiv="Content-Security-Policy"'
RP="$ROOT/rp"; mk "$RP" "{\"screens\":{$PIDS},\"viewports\":[[\"phone\",390,844]]}"
python3 -I "$ROOT/pfx.py" "$RP/docs/ux" "$ROOT/outside-canary/canary.html"
reset_stub
ux "tl_ux_render $(q "$RP") p1 p2 p3 p4 p5 p6" "$SOK"
if [ "$RC" -eq 0 ] && rdable "$ROOT/stub.heads" && [ -s "$ROOT/stub.heads" ]; then
  nh="$(grep -c . "$ROOT/stub.heads")"; nbad="$(grep -cvxF -- "$PFX" "$ROOT/stub.heads")"
  [ "$nh" -eq 6 ] && [ "$nbad" -eq 0 ] \
    && ok "[S] stub: all $nh served pages start exactly with our doctype + CSP meta" \
    || bad "[S] stub: $nbad/$nh heads differ: $(grep -vxF -- "$PFX" "$ROOT/stub.heads" | sort -u | head -n 3)"
else bad "[S] stub prefix render rc=$RC err='$ERR'"; fi
if [ -n "$REAL" ]; then
  mkdir -p "$ROOT/outside-canary"
  printf '<html><body style="margin:0;background:#ff0000"><h1>SECRET-CANARY-1234</h1></body></html>\n' >"$ROOT/outside-canary/canary.html"
  CP="$ROOT/ctlp.png"; cp "$RP/docs/ux/screens/p1/default.html" "$ROOT/ctlp.html"
  timeout 60 "$REAL" --headless=new --disable-gpu --hide-scrollbars --window-size=390,844 --screenshot="$CP" "file://$ROOT/ctlp.html" >/dev/null 2>&1
  ctl="$(redpx "$CP")"
  [ "$ctl" != err ] && [ "$ctl" -gt 0 ] && ok "[S] control: the <!--> mock rendered without protection shows the canary ($ctl red px)" \
    || echo "  note — [S] <!--> control render did not navigate (red=$ctl); canary checks below prove less"
  ux "tl_ux_render $(q "$RP") p1 p2 p3 p4 p5 p6" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
  [ "$RC" -eq 0 ] || bad "[S] real prefix render rc=$RC err='$(printf '%s' "$ERR" | tail -n 3)'"
  for c in "p1 <!-->" "p2 <!--->" "p3 comment-then-doctype" "p4 no-doctype" "p5 BOM-then-script" "p6 CRLF"; do
    id="${c%% *}"; got="$(redpx "$RP/docs/ux/screens/$id/default@phone.png")"
    [ "$got" != err ] && [ "$got" -eq 0 ] && ok "[S] real $REAL: ${c#* } mock → PNG has no canary pixels" \
      || bad "[S] canary leak via ${c#* } prefix: red='$got'"
  done
else
  echo "  skip — [S] no headless Chrome/Chromium on PATH; real-browser prefix canary checks not observed"
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

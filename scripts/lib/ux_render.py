"""ux_render.py — UX screenshots, captures and the flow page (TDD 0070; FR-91, FR-94, FR-99).

Run as `python3 -I ux_render.py <subcommand> …` from scripts/lib/ux.sh.
Subcommands: render, capture, index-html. stdlib only. Never writes index.json.
rc 4 is the declared screenshot degrade (no browser / failed shot), distinct
from rc 2 (invalid input / internal error) — NFR-4.
"""
import html
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

# -I drops the script dir from sys.path; load the sibling module explicitly,
# without leaving a __pycache__ in the plugin tree.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ux_record import (IMG_EXT, UxError, checked_index, mock_problems,  # noqa: E402
                       present_pngs, run, symlink_problems, ux_dir)

BROWSERS = ["chromium", "chromium-browser", "google-chrome", "chrome"]
NO_BROWSER = "no headless Chrome on PATH"


def find_browser():
    env = os.environ.get("THROUGHLINE_UX_BROWSER", "")
    cands = ([env] if env else []) + BROWSERS
    for c in cands:
        if os.sep in c:
            if os.path.isfile(c) and os.access(c, os.X_OK):
                return c
        else:
            p = shutil.which(c)
            if p:
                return p
    return None


def shoot(browser, w, h, png, url, block_network):
    """Run one headless screenshot. Returns the browser's exit code."""
    cmd = [browser, "--headless=new", "--disable-gpu", "--hide-scrollbars"]
    if block_network:
        # The resolver rule stops DNS names; the dead proxy (with loopback not
        # bypassed) also stops IP literals and localhost, for http(s) and ws(s).
        cmd += ["--host-resolver-rules=MAP * ~NOTFOUND",
                "--proxy-server=http://127.0.0.1:9", "--proxy-bypass-list=<-loopback>"]
    cmd += ["--window-size=%d,%d" % (w, h), "--screenshot=" + png, url]
    if shutil.which("timeout"):
        cmd = ["timeout", "60"] + cmd
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=90)
    except subprocess.TimeoutExpired:
        return 124
    if p.returncode != 0:
        tail = p.stderr.decode("utf-8", "replace").strip().splitlines()[-3:]
        for line in tail:
            print("ux: browser: " + line, file=sys.stderr)
    return p.returncode


def _good_png(p):
    return os.path.isfile(p) and os.path.getsize(p) > 0


# Every page the render shows carries this policy: no script runs (so nothing
# can build a path or navigate to a local file at render time — B1), and no
# frame, plugin, worker, fetch, <base> or form target can load either. A CSP
# meta is used because --blink-settings=scriptEnabled=false (and a profile
# that blocks JavaScript) stop headless Chrome from writing --screenshot.
CSP = ("script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; "
       "worker-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'")
CSP_META = ('<meta http-equiv="Content-Security-Policy" content="%s">' % CSP).encode("ascii")
_PREFIX = b"<!DOCTYPE html>" + CSP_META


def _inject_csp(path):
    """Write _PREFIX at byte 0, before the mock's own bytes (one leading UTF-8
    BOM dropped). No HTML is parsed: whatever the mock starts with (comments,
    abruptly-closed <!--> comments, script, no doctype) comes after the CSP.
    Our doctype comes first, so the page renders in standards mode and the
    mock's own later doctype is ignored."""
    with open(path, "rb") as fh:
        b = fh.read()
    if b.startswith(b"\xef\xbb\xbf"):
        b = b[3:]
    with open(path, "wb") as fh:
        fh.write(_PREFIX + b)


def _private_copy(root, ud):
    """Copy docs/ux to docs/.ux-render.XXXX/r/docs/ux (inside the repo, so a
    confined browser such as snap Chromium can still read it). The browser
    only ever sees the copy: it is checked and rendered, so a concurrent edit
    of the real mock cannot slip past the check (N4), and every HTML page in it
    gets CSP_META. Returns (tmp, copy_root)."""
    tmp = tempfile.mkdtemp(prefix=".ux-render.", dir=os.path.dirname(ud))
    croot = os.path.join(tmp, "r")
    try:
        shutil.copytree(ud, ux_dir(croot), symlinks=True)
        bad = symlink_problems(croot)
        if bad:
            raise UxError("ux: render refused: %s" % bad[0])
        for dp, _, fns in os.walk(ux_dir(croot)):
            for fn in fns:
                if fn.lower().endswith((".html", ".htm", ".xhtml")):
                    _inject_csp(os.path.join(dp, fn))
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return tmp, croot


def cmd_render(args):
    if len(args) < 2:
        raise UxError("ux: render needs explicit screen ids")
    root, ids = os.path.abspath(args[0]), []
    for a in args[1:]:
        if a not in ids:
            ids.append(a)
    ud = ux_dir(root)
    d = checked_index(os.path.join(ud, "index.json"))
    byid = {s["id"]: s for s in d["screens"]}
    for sid in ids:
        if sid not in byid:
            raise UxError("ux: unknown screen id %s" % sid)
    # 0. Refuse before touching anything: a symlink under docs/ux/ would make the
    # clear step delete, or the browser write, outside the repo; a missing mock
    # is invalid input (rc 2, N6); an unsafe mock could bake a local file or a
    # network fetch into a committed PNG. The mocks are checked in the private
    # copy the browser will render, not in place.
    bad = symlink_problems(root)
    if bad:
        raise UxError("ux: render refused: %s (run tl_ux_validate)" % bad[0])
    for sid in ids:
        for st in byid[sid]["states"]:
            if "file" in st and not os.path.isfile(os.path.join(ud, st["file"])):
                raise UxError("ux: render refused: missing mock docs/ux/%s (run tl_ux_validate)" % st["file"])
    tmp, croot = _private_copy(root, ud)
    try:
        bad = mock_problems(croot, d, set(ids))
        if bad:
            raise UxError("ux: render refused: %s (run tl_ux_validate)" % bad[0])
        return _render(root, ud, d, byid, ids, ux_dir(croot))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _render(root, ud, d, byid, ids, cud):
    # 1. Clear every image under the named screens, before looking for a browser.
    for sid in ids:
        sd = os.path.join(ud, "screens", sid)
        if os.path.isdir(sd):
            for fn in sorted(os.listdir(sd)):
                fp = os.path.join(sd, fn)
                if fn.lower().endswith(IMG_EXT) and os.path.isfile(fp):
                    os.remove(fp)
    # 2. Find a browser.
    browser = find_browser()
    reason, rc, wrote = None, 0, []
    if browser is None:
        reason, rc = NO_BROWSER, 4
    else:
        # 3. Render each shot, from the CSP-guarded private copy.
        for sid in ids:
            for st in byid[sid]["states"]:
                if "file" not in st:
                    continue
                hrel = "docs/ux/" + st["file"]
                url = pathlib.Path(os.path.join(cud, st["file"])).as_uri()
                for v in d["viewports"]:
                    prel = "docs/ux/screens/%s/%s@%s.png" % (sid, st["name"], v["name"])
                    pabs = os.path.join(root, prel)
                    wrote.append((pabs, prel))
                    brc = shoot(browser, v["width"], v["height"], pabs, url, True)
                    if brc != 0 or not _good_png(pabs):
                        reason, rc = "%s failed on %s (rc %d)" % (browser, hrel, brc), 4
                        break
                if rc:
                    break
            if rc:
                break
        # 4. On failure, delete only the PNGs this call wrote; report a PNG as
        # rendered only once the whole call has succeeded (N5).
        if rc:
            for p, _ in wrote:
                if os.path.isfile(p):
                    os.remove(p)
        else:
            for _, prel in wrote:
                print("rendered " + prel)
    # 5. Whole-set status, from disk.
    exp, have = present_pngs(root, d)
    if reason is None and len(have) == len(exp):
        print("screenshots: complete")
    else:
        print("screenshots not rendered: %s" % (reason or "partial — %d missing" % (len(exp) - len(have))))
    return rc


def _in_git_tree(path):
    p = os.path.realpath(path)
    while True:
        if os.path.exists(os.path.join(p, ".git")):
            return True
        parent = os.path.dirname(p)
        if parent == p:
            return False
        p = parent


def cmd_capture(args):
    if len(args) != 3:
        raise UxError("ux: usage: capture <url> <outdir> <w>x<h>")
    url, outdir, size = args
    if not re.match(r"https?://", url):
        raise UxError("ux: capture needs an http:// or https:// URL, got %s" % url)
    m = re.fullmatch(r"([0-9]+)x([0-9]+)", size)
    if not m:
        raise UxError("ux: capture size must be <w>x<h>, got %s" % size)
    if _in_git_tree(outdir):
        raise UxError("ux: capture outdir %s is inside a git work tree; captures are never committed" % outdir)
    os.makedirs(outdir, exist_ok=True)
    w, h = int(m.group(1)), int(m.group(2))
    browser = find_browser()
    if browser is None:
        print("capture failed: " + NO_BROWSER)
        return 4
    png = os.path.join(os.path.abspath(outdir), "capture-%dx%d.png" % (w, h))
    brc = shoot(browser, w, h, png, url, False)
    if brc != 0 or not _good_png(png):
        if os.path.isfile(png):
            os.remove(png)
        print("capture failed: %s failed on %s (rc %d)" % (browser, url, brc))
        return 4
    print(png)
    return 0


def _page(d, root):
    e = html.escape
    exp, have = present_pngs(root, d)
    missing = [p for p in exp if p not in have]
    out = ["<!doctype html>", '<html lang="en">', "<head>", '<meta charset="utf-8">',
           "<title>UX record</title>",
           "<style>body{font-family:system-ui,sans-serif;margin:2rem;max-width:60rem}"
           "table{border-collapse:collapse}td,th{border:1px solid #999;padding:.25rem .5rem;text-align:left}</style>",
           "</head>", "<body>", "<h1>UX record</h1>", "<h2>Provenance</h2>", "<ul>"]
    vps = ", ".join("%s %dx%d" % (v["name"], v["width"], v["height"]) for v in d["viewports"])
    prov = [("PRD rev", d["prd_rev"]), ("Platforms", ", ".join(d["platforms"])), ("Viewports", vps),
            ("Fidelity", d["fidelity"]),
            ("Delegates", ", ".join(d["delegates"]) if d["delegates"] else "none: degraded"),
            ("Design system", d["design_system"]["source"]),
            ("Screenshots", "%d/%d" % (len(have), len(exp)))]
    for k, v in prov:
        out.append("<li>%s: %s</li>" % (e(k), e(v)))
    out += ["</ul>", "<h2>Flow</h2>", "<ol>"]
    byid = {s["id"]: s for s in d["screens"]}
    for sid in d["flow"]:
        s = byid[sid]
        out.append('<li><a href="screens/%s/default.html">%s</a> (%s; baseline: %s)'
                   % (e(sid), e(s["title"]), e(sid), e(s["baseline"])))
        others = []
        for st in s["states"]:
            if st["name"] == "default":
                continue
            if "file" in st:
                others.append('<a href="%s">%s</a>' % (e(st["file"]), e(st["name"])))
            else:
                others.append("%s: n/a (%s)" % (e(st["name"]), e(st["na"])))
        out.append(" &mdash; " + " &middot; ".join(others) + "</li>")
    out += ["</ol>", "<h2>Requirements</h2>", "<table>", "<tr><th>Requirement</th><th>Screens</th></tr>"]
    for r in d["requirements"]:
        links = ", ".join('<a href="screens/%s/default.html">%s</a>' % (e(x), e(x)) for x in r["screens"])
        out.append("<tr><td>%s</td><td>%s</td></tr>" % (e(r["id"]), links))
    out += ["</table>", "<h2>Missing screenshots</h2>"]
    if missing:
        out.append("<ul>")
        out += ["<li>%s</li>" % e(p) for p in missing]
        out.append("</ul>")
    else:
        out.append("<p>none</p>")
    out += ["</body>", "</html>", ""]
    return "\n".join(out)


def cmd_index_html(args):
    if len(args) != 1:
        raise UxError("ux: usage: index-html <repo-root>")
    root = os.path.abspath(args[0])
    ud = ux_dir(root)
    bad = symlink_problems(root)
    if bad:
        raise UxError("ux: index-html refused: %s" % bad[0])
    d = checked_index(os.path.join(ud, "index.json"))
    page = _page(d, root)
    fd, tmp = tempfile.mkstemp(prefix=".index.html.", dir=ud)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(page)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(ud, "index.html"))
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
    print("wrote docs/ux/index.html")
    return 0


CMDS = {"render": cmd_render, "capture": cmd_capture, "index-html": cmd_index_html}

if __name__ == "__main__":
    sys.exit(run(CMDS, sys.argv))

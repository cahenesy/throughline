"""ux_render.py — UX screenshots, captures and the flow page (TDD 0070; FR-91, FR-94, FR-99).

Run as `python3 -I ux_render.py <subcommand> …` from scripts/lib/ux.sh.
Subcommands: render, capture, index-html. stdlib only. Never writes index.json.
rc 4 is the declared screenshot degrade (no browser / failed shot), distinct
from rc 2 (invalid input / internal error) — NFR-4.
"""
import functools
import html
import http.server
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

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


def _browser_home(tmp):
    """Private browser state under the caller's mkdtemp `tmp`: the profile
    (--user-data-dir), HOME (so downloads land in <tmp>/b/h/Downloads, not
    ~/Downloads), XDG dirs and TMPDIR. All of it goes when `tmp` is removed.
    Short names: Chrome's socket path under TMPDIR has a 108-byte limit."""
    b = os.path.join(tmp, "b")
    h, t, p = os.path.join(b, "h"), os.path.join(b, "t"), os.path.join(b, "p")
    for x in (h, t, p):
        os.makedirs(x, mode=0o700)
    env = dict(os.environ, HOME=h, TMPDIR=t, XDG_CONFIG_HOME=os.path.join(h, ".config"),
               XDG_CACHE_HOME=os.path.join(h, ".cache"), XDG_DATA_HOME=os.path.join(h, ".local", "share"))
    return p, env


def _kill_group(proc):
    """Stop the browser's whole process group (Chrome and its helpers): TERM,
    then KILL after 3 s. The browser runs in its own session, so this never
    reaches render itself."""
    for sig, grace in ((signal.SIGTERM, 3.0), (signal.SIGKILL, 3.0)):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        end = time.monotonic() + grace
        while proc.poll() is None and time.monotonic() < end:
            time.sleep(0.05)
        if proc.poll() is not None:
            break
    try:
        os.killpg(proc.pid, signal.SIGKILL)   # helpers outliving the leader
    except (ProcessLookupError, PermissionError):
        pass
    proc.wait()


def shoot(browser, w, h, png, url, profile, env, port=None):
    """Run one headless screenshot. Returns the browser's exit code (124 on
    timeout). `profile`/`env` come from _browser_home: a throwaway profile
    (--incognito: a fresh --user-data-dir otherwise stalls on first run),
    with HOME and TMPDIR inside the caller's private temp tree. With
    `port` (render), the network is cut to render's own server: the resolver
    rule stops DNS names (127.0.0.1 is excluded: Chrome otherwise maps IP
    literals too and the page itself fails ERR_NAME_NOT_RESOLVED), and the
    dead proxy — bypassed only for 127.0.0.1:<port>, with the implicit
    loopback bypass removed — stops IP literals, localhost and every other
    loopback port. A capture (no port)
    must reach the user's live app, so it gets none of these flags.
    The browser runs in its own session; on timeout, or on any exception
    (a signal turned into SystemExit), its whole process group is killed."""
    cmd = [browser, "--headless=new", "--disable-gpu", "--hide-scrollbars",
           "--incognito", "--user-data-dir=" + profile]
    if port is not None:
        cmd += ["--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
                "--proxy-server=http://127.0.0.1:9",
                "--proxy-bypass-list=<-loopback>;127.0.0.1:%d" % port]
    cmd += ["--window-size=%d,%d" % (w, h), "--screenshot=" + png, url]
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, env=env, start_new_session=True)
    try:
        _, err = p.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        return 124
    finally:
        _kill_group(p)
    if p.returncode != 0:
        tail = err.decode("utf-8", "replace").strip().splitlines()[-3:]
        for line in tail:
            print("ux: browser: " + line, file=sys.stderr)
    return p.returncode


def _good_png(p):
    return os.path.isfile(p) and os.path.getsize(p) > 0


# Render isolation (TDD 0070 rev 2). The browser never opens a repo file and
# never uses file://: it loads http://127.0.0.1:<port>/ from a loopback server
# rooted at a private copy of docs/ux outside the repo. This policy rides on
# every response as a header and at byte 0 of every HTML page as a meta, so
# the browser enforces it: no script runs; images, fonts, media and CSS load
# only from the server ('self') or data:; no frame, plugin, worker, <base> or
# form target. An absolute or ../ path resolves on the server (404); file: is
# never 'self'. The regex scan in validate is defence in depth only.
CSP = ("default-src 'self' data:; script-src 'none'; object-src 'none'; frame-src 'none'; "
       "worker-src 'none'; base-uri 'none'; form-action 'none'; style-src 'self' 'unsafe-inline' data:")
CSP_META = ('<meta http-equiv="Content-Security-Policy" content="%s">' % CSP).encode("ascii")
_PREFIX = b"<!DOCTYPE html>" + CSP_META
_HTML_EXT = (".html", ".htm", ".xhtml")


def _inject_csp(path):
    """Write _PREFIX at byte 0, before the mock's own bytes (one leading UTF-8
    BOM dropped). No HTML is parsed, so no mock prefix (comments, <!-->,
    script, no doctype) can precede the policy."""
    with open(path, "rb") as fh:
        b = fh.read()
    if b.startswith(b"\xef\xbb\xbf"):
        b = b[3:]
    with open(path, "wb") as fh:
        fh.write(_PREFIX + b)


def _private_copy(ud):
    """Copy docs/ux into <mkdtemp>/r/docs/ux, outside the repo. Only render's
    python server reads it. The copy is re-checked for symlinks (closing the
    check-to-copy race) and every HTML page in it gets _PREFIX. The caller
    removes the returned tmp dir. Returns (tmp, copy_root)."""
    tmp = tempfile.mkdtemp(prefix="ux-render.")
    croot = os.path.join(tmp, "r")
    try:
        shutil.copytree(ud, ux_dir(croot), symlinks=True)
        bad = symlink_problems(croot)
        if bad:
            raise UxError("ux: render refused: %s" % bad[0])
        for dp, _, fns in os.walk(ux_dir(croot)):
            for fn in fns:
                if fn.lower().endswith(_HTML_EXT):
                    _inject_csp(os.path.join(dp, fn))
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return tmp, croot


class _Handler(http.server.SimpleHTTPRequestHandler):
    """GET only, rooted at the copy; the policy header on every response
    (pages, assets, redirects, errors); no directory listings; silent."""
    extensions_map = dict(http.server.SimpleHTTPRequestHandler.extensions_map,
                          **{e: "text/html; charset=utf-8" for e in _HTML_EXT})

    def end_headers(self):
        self.send_header("Content-Security-Policy", CSP)
        super().end_headers()

    def do_HEAD(self):
        self.send_error(405)

    def list_directory(self, path):
        self.send_error(404)
        return None

    def log_message(self, *a):
        pass


class _Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass  # nothing reaches the ux: stderr channel


def _serve(cud):
    """Start the loopback server for the copy at `cud` on 127.0.0.1:<free>."""
    srv = _Server(("127.0.0.1", 0), functools.partial(_Handler, directory=cud))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


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
    # clear step delete, or the render write, outside the repo; a missing mock
    # is invalid input (rc 2, N6); a mock failing the scan is refused as well
    # (defence in depth; the browser boundary is the CSP + loopback server).
    # The mocks are scanned in the private copy that is served, not in place.
    bad = symlink_problems(root)
    if bad:
        raise UxError("ux: render refused: %s (run tl_ux_validate)" % bad[0])
    for sid in ids:
        for st in byid[sid]["states"]:
            if "file" in st and not os.path.isfile(os.path.join(ud, st["file"])):
                raise UxError("ux: render refused: missing mock docs/ux/%s (run tl_ux_validate)" % st["file"])
    tmp, croot = _private_copy(ud)
    try:
        bad = mock_problems(croot, d, set(ids))
        if bad:
            raise UxError("ux: render refused: %s (run tl_ux_validate)" % bad[0])
        srv = _serve(ux_dir(croot))
        try:
            return _render(root, ud, d, byid, ids, srv.server_address[1], tmp)
        finally:
            srv.shutdown()
            srv.server_close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _drop(wrote):
    for p, _ in wrote:
        if os.path.isfile(p):
            os.remove(p)


def _render(root, ud, d, byid, ids, port, tmp):
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
        # 3. Render each shot, served from the CSP-guarded private copy, with
        # one browser profile/HOME/TMPDIR for the call inside the same tree.
        profile, env = _browser_home(tmp)
        try:
            for sid in ids:
                for st in byid[sid]["states"]:
                    if "file" not in st:
                        continue
                    hrel = "docs/ux/" + st["file"]
                    url = "http://127.0.0.1:%d/%s" % (port, urllib.parse.quote(st["file"]))
                    for v in d["viewports"]:
                        prel = "docs/ux/screens/%s/%s@%s.png" % (sid, st["name"], v["name"])
                        pabs = os.path.join(root, prel)
                        wrote.append((pabs, prel))
                        brc = shoot(browser, v["width"], v["height"], pabs, url, profile, env, port)
                        if brc != 0 or not _good_png(pabs):
                            reason, rc = "%s failed on %s (rc %d)" % (browser, hrel, brc), 4
                            break
                    if rc:
                        break
                if rc:
                    break
        except BaseException:   # a signal (SystemExit) mid-call: same as a failure
            _drop(wrote)
            raise
        # 4. On failure, delete only the PNGs this call wrote; report a PNG as
        # rendered only once the whole call has succeeded (N5).
        if rc:
            _drop(wrote)
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
    tmp = tempfile.mkdtemp(prefix="ux-capture.")
    try:
        brc = shoot(browser, w, h, png, url, *_browser_home(tmp))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
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

def _on_signal(signum, frame):
    """SIGTERM/SIGHUP/SIGINT → SystemExit(128+signum), so every `finally`
    runs: the browser group is killed, the loopback server shut down and the
    private temp tree removed. Further signals are ignored while that runs."""
    for s in _SIGS:
        signal.signal(s, signal.SIG_IGN)
    raise SystemExit(128 + signum)


_SIGS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)

if __name__ == "__main__":
    for _s in _SIGS:
        if signal.getsignal(_s) is not signal.SIG_IGN:   # respect nohup / ignored SIGINT
            signal.signal(_s, _on_signal)
    sys.exit(run(CMDS, sys.argv))

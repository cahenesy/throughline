"""ux_record.py — UX record mechanics (TDD 0070; FR-89, FR-90, FR-91, FR-94, FR-101).

Run as `python3 -I ux_record.py <subcommand> …` from scripts/lib/ux.sh.
Subcommands: ui-reqs, delta, validate, coverage-check. stdlib only.
Results go to stdout, `ux: …` diagnostics to stderr. No parse failure reads as
"no UI requirements": every one exits non-zero with a named message (L-005).
Also imported by ux_render.py for the index loader and the structural checks.
"""
import hashlib
import json
import os
import re
import sys

UI_RE = re.compile(r"^\*\*(?P<id>[A-Z][A-Z0-9]*-[0-9]+) \[UI\] (?P<title>[^*]+?)\.?\*\*")
REQ_RE = re.compile(r"^\*\*(?P<id>[A-Z][A-Z0-9]*-[0-9]+) ")
ID_RE = re.compile(r"[A-Z][A-Z0-9]*-[0-9]+")
CODE_RE = re.compile(r"(`+)(.+?)\1")
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
STATES = ["default", "empty", "loading", "error"]
IMG_EXT = (".png", ".jpg", ".jpeg", ".webp")
TOP_KEYS = {"schema", "prd_rev", "platforms", "viewports", "fidelity", "delegates",
            "design_system", "requirements", "screens", "flow"}


class UxError(Exception):
    """A named failure: message for stderr, rc to exit with."""

    def __init__(self, msg, rc=2):
        super().__init__(msg)
        self.rc = rc


def _delist(line):
    if line.startswith("- ") or line.startswith("* "):
        return line[2:]
    return line


def parse_prd_strict(path):
    """parse_prd, but an unreadable PRD is rc 2 (rc 1 means something else)."""
    try:
        return parse_prd(path)
    except UxError as e:
        raise UxError(str(e), 2)


def parse_prd(path):
    """Return (ui, titles): ui = [(id, hash, title, lineno)] in file order;
    titles = {id: lineno} for every requirement title (with or without [UI])."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        raise UxError("ux: cannot read %s" % path, 1)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        raise UxError("ux: cannot decode %s as UTF-8: %s" % (path, e))
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    fence = None
    fence_line = 0
    heads = []  # (index, kind, id, title) — kind: 'ui' | 'req' | 'heading'
    for i, line in enumerate(lines):
        m = FENCE_RE.match(line)
        if fence is None and m:
            fence, fence_line = m.group(1)[0], i + 1
            continue
        if fence is not None:
            if m and m.group(1)[0] == fence:
                fence = None
            continue
        if line.startswith("#"):
            heads.append((i, "heading", None, None))
            continue
        body = _delist(line)
        scan = CODE_RE.sub("", body)
        if "[UI]" in scan:
            if not UI_RE.match(scan):
                raise UxError("ux: malformed [UI] marker at %s:%d: %s" % (path, i + 1, line[:120]))
            m2 = UI_RE.match(body) or UI_RE.match(scan)
            heads.append((i, "ui", m2.group("id"), m2.group("title")))
            continue
        m3 = REQ_RE.match(body)
        if m3:
            heads.append((i, "req", m3.group("id"), None))
    if fence is not None:
        raise UxError("ux: unterminated code fence at %s:%d" % (path, fence_line))
    ui, seen, titles = [], {}, {}
    for n, (i, kind, rid, title) in enumerate(heads):
        if kind == "heading":
            continue
        titles.setdefault(rid, i + 1)
        if kind != "ui":
            continue
        if rid in seen:
            raise UxError("ux: duplicate [UI] id %s at %s:%d,%d" % (rid, path, seen[rid], i + 1))
        seen[rid] = i + 1
        end = heads[n + 1][0] if n + 1 < len(heads) else len(lines)
        block = "\n".join(l.rstrip() for l in lines[i:end])
        ui.append((rid, hashlib.sha256(block.encode("utf-8")).hexdigest(), title, i + 1))
    return ui, titles


# ---- index ------------------------------------------------------------------

def load_index(path, data=None):
    """Parse an index (file path, or `data` text). Raises UxError rc 2."""
    if data is None:
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            raise UxError("ux: invalid index %s: cannot read" % path)
    try:
        if isinstance(data, bytes):
            data = data.decode("utf-8")
        return json.loads(data)
    except (UnicodeDecodeError, ValueError) as e:
        raise UxError("ux: invalid index %s: %s" % (path, e))


def _isint(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _badpath(p):
    return p.startswith("/") or ".." in p.replace("\\", "/").split("/")


def structural_errors(d):
    """Every schema-v1 rule except PRD-consistency. Returns a list of reasons."""
    e = []
    if not isinstance(d, dict):
        return ["index is not a JSON object"]
    for k in sorted(TOP_KEYS - set(d)):
        e.append("missing field %s" % k)
    for k in sorted(set(d) - TOP_KEYS):
        e.append("unknown field %s" % k)
    if e:
        return e
    if not (_isint(d["schema"]) and d["schema"] == 1):
        e.append("schema must be 1")
    if not isinstance(d["prd_rev"], str):
        e.append("prd_rev must be a string")
    pl = d["platforms"]
    if not (isinstance(pl, list) and pl and all(p in ("web", "ios", "android") for p in pl)):
        e.append("platforms must be a non-empty array of web/ios/android")
    vps = d["viewports"]
    if not isinstance(vps, list):
        e.append("viewports must be an array")
        vps = []
    vnames = set()
    for v in vps:
        if not (isinstance(v, dict) and set(v) == {"name", "width", "height"}):
            e.append("viewport must be {name, width, height}: %r" % (v,))
            continue
        if not (isinstance(v["name"], str) and re.fullmatch(r"[a-z0-9-]+", v["name"])):
            e.append("bad viewport name %r" % (v["name"],))
        elif v["name"] in vnames:
            e.append("duplicate viewport %s" % v["name"])
        vnames.add(v["name"])
        for k in ("width", "height"):
            if not (_isint(v[k]) and 200 <= v[k] <= 4000):
                e.append("viewport %s %s must be an int in 200-4000" % (v["name"], k))
    dl = d["delegates"]
    if not (isinstance(dl, list) and all(isinstance(x, str) and x for x in dl)):
        e.append("delegates must be an array of strings")
    if d["fidelity"] not in ("high", "mid", "low"):
        e.append("fidelity must be high/mid/low")
    elif d["fidelity"] == "high" and dl == []:
        e.append("fidelity high requires a delegate (delegates is empty)")
    ds = d["design_system"]
    if not (isinstance(ds, dict) and set(ds) == {"tokens", "adr", "source"}):
        e.append("design_system must be {tokens, adr, source}")
    else:
        if ds["tokens"] not in ("tokens.css", None):
            e.append('design_system.tokens must be "tokens.css" or null')
        if ds["adr"] is not None:
            if not isinstance(ds["adr"], str) or not ds["adr"]:
                e.append("design_system.adr must be a path or null")
            elif _badpath(ds["adr"]):
                e.append("path must be relative without '..': %s" % ds["adr"])
        if ds["source"] not in ("existing-code", "established", "none"):
            e.append("design_system.source must be existing-code/established/none")
    scr = d["screens"]
    if not isinstance(scr, list):
        e.append("screens must be an array")
        scr = []
    sids = []
    for s in scr:
        if not (isinstance(s, dict) and set(s) == {"id", "title", "baseline", "states"}):
            e.append("screen must be {id, title, baseline, states}: %r" % (s,))
            continue
        sid = s["id"]
        if not (isinstance(sid, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]*", sid)):
            e.append("bad screen id %r" % (sid,))
            continue
        if sid in sids:
            e.append("duplicate screen id %s" % sid)
        sids.append(sid)
        if not isinstance(s["title"], str):
            e.append("screen %s: title must be a string" % sid)
        if s["baseline"] not in ("code-derived", "live capture (not committed)", "none (new screen)"):
            e.append("screen %s: bad baseline %r" % (sid, s["baseline"]))
        sts = s["states"] if isinstance(s["states"], list) else []
        if not isinstance(s["states"], list):
            e.append("screen %s: states must be an array" % sid)
        names = []
        for st in sts:
            if not (isinstance(st, dict) and set(st) in ({"name", "file"}, {"name", "na"})):
                e.append("screen %s: state must be {name, file} or {name, na}: %r" % (sid, st))
                continue
            n = st["name"]
            if n not in STATES:
                e.append("screen %s: unknown state %r" % (sid, n))
                continue
            names.append(n)
            if "file" in st:
                f = st["file"]
                if not isinstance(f, str) or _badpath(f):
                    e.append("path must be relative without '..': %s" % (f,))
                elif f != "screens/%s/%s.html" % (sid, n):
                    e.append("screen %s state %s: file must be screens/%s/%s.html" % (sid, n, sid, n))
            elif not (isinstance(st["na"], str) and st["na"].strip()):
                e.append("screen %s state %s: na needs a reason" % (sid, n))
            elif n == "default":
                e.append("screen %s: default state must have a file" % sid)
        for n in STATES:
            c = names.count(n)
            if c != 1:
                e.append("screen %s: state %s must appear exactly once (found %d)" % (sid, n, c))
    reqs = d["requirements"]
    if not isinstance(reqs, list):
        e.append("requirements must be an array")
        reqs = []
    rids = []
    for r in reqs:
        if not (isinstance(r, dict) and set(r) == {"id", "hash", "screens"}):
            e.append("requirement must be {id, hash, screens}: %r" % (r,))
            continue
        if not (isinstance(r["id"], str) and ID_RE.fullmatch(r["id"])):
            e.append("bad requirement id %r" % (r["id"],))
            continue
        if r["id"] in rids:
            e.append("duplicate requirement id %s" % r["id"])
        rids.append(r["id"])
        if not (isinstance(r["hash"], str) and re.fullmatch(r"[0-9a-f]{64}", r["hash"])):
            e.append("requirement %s: hash must be 64 lowercase hex" % r["id"])
        rs = r["screens"]
        if not (isinstance(rs, list) and rs):
            e.append("requirement %s: screens must be non-empty" % r["id"])
        else:
            for x in rs:
                if x not in sids:
                    e.append("requirement %s: unknown screen %r" % (r["id"], x))
    fl = d["flow"]
    if not (isinstance(fl, list) and all(isinstance(x, str) for x in fl)
            and sorted(fl) == sorted(sids) and len(set(fl)) == len(fl)):
        e.append("flow must list every screen exactly once")
    return e


def checked_index(path, data=None, label=None):
    """Load + structurally check, raising `ux: invalid index …` rc 2."""
    d = load_index(path, data)
    errs = structural_errors(d)
    if errs:
        raise UxError("ux: invalid index %s: %s" % (label or path, "; ".join(errs)))
    return d


def expected_pngs(d):
    """Every screens/<sid>/<state>@<viewport>.png the set should have."""
    out = []
    for s in d["screens"]:
        for st in s["states"]:
            if "file" in st:
                for v in d["viewports"]:
                    out.append("screens/%s/%s@%s.png" % (s["id"], st["name"], v["name"]))
    return out


def ux_dir(root):
    return os.path.join(root, "docs", "ux")


def present_pngs(root, d):
    exp = expected_pngs(d)
    return exp, [p for p in exp if os.path.isfile(os.path.join(ux_dir(root), p))]


# ---- subcommands --------------------------------------------------------------

def cmd_ui_reqs(args):
    if len(args) != 1:
        raise UxError("ux: usage: ui-reqs <prd-path>")
    ui, _ = parse_prd(args[0])
    for rid, h, title, _ in ui:
        print("%s\t%s\t%s" % (rid, h, title))
    return 0


def cmd_delta(args):
    if len(args) != 2:
        raise UxError("ux: usage: delta <prd-path> <index-path|->")
    prd, ip = args
    ui, titles = parse_prd_strict(prd)
    if ip == "-":
        d = checked_index("-", sys.stdin.buffer.read(), "<stdin>")
    elif not os.path.exists(ip):
        d = {"requirements": []}
    else:
        d = checked_index(ip)
    have = {r["id"]: r["hash"] for r in d["requirements"]}
    cur = {rid for rid, _, _, _ in ui}
    rows = []  # (sort key, line)
    for rid, h, title, ln in ui:
        if rid not in have:
            rows.append((ln, "new\t%s\t%s" % (rid, title)))
        elif have[rid] != h:
            rows.append((ln, "changed\t%s\t%s" % (rid, title)))
    big = 1 << 30
    for n, r in enumerate(d["requirements"]):
        if r["id"] not in cur:
            rows.append((titles.get(r["id"], big + n), "orphaned\t%s" % r["id"]))
    for _, line in sorted(rows, key=lambda x: x[0]):
        print(line)
    return 0


def _scan_mock(rel, text):
    """External-URL and other per-mock problems."""
    probs = []
    pats = [r"""(?:src|href)\s*=\s*["']?\s*((?:https?:|//)[^"'\s>]*)""",
            r"""@import\s+(?:url\(\s*)?["']?\s*((?:https?:|//)[^"'\s>);]*)""",
            r"""url\(\s*["']?\s*((?:https?:|//)[^"'\s)]*)"""]
    found = []
    for p in pats:
        for m in re.finditer(p, text, re.I):
            if m.group(1) not in found:
                found.append(m.group(1))
    for u in found:
        probs.append("%s: external URL %s (mocks must be self-contained)" % (rel, u))
    return probs


def _links_tokens(mock_abs, text, tokens_abs):
    for tag in re.finditer(r"<link\b[^>]*>", text, re.I):
        t = tag.group(0)
        if not re.search(r"""\brel\s*=\s*["']?stylesheet\b""", t, re.I):
            continue
        m = re.search(r"""\bhref\s*=\s*["']?([^"'\s>]+)""", t, re.I)
        if not m:
            continue
        href = m.group(1)
        if href.startswith("/") or re.match(r"[a-z][a-z0-9+.-]*:", href, re.I):
            continue
        tgt = os.path.normpath(os.path.join(os.path.dirname(mock_abs), href))
        if tgt == os.path.normpath(tokens_abs):
            return True
    return False


def cmd_validate(args):
    if len(args) != 1:
        raise UxError("ux: usage: validate <repo-root>")
    root = os.path.abspath(args[0])
    ud = ux_dir(root)
    ipath = os.path.join(ud, "index.json")
    rel_index = "docs/ux/index.json"
    if not os.path.isfile(ipath):
        raise UxError("ux: no index at %s" % ipath)
    d = load_index(ipath)
    errs = structural_errors(d)
    if errs:
        for r in errs:
            print("ux-invalid: %s: %s" % (rel_index, r))
        return 1
    probs = []
    ui, _ = parse_prd_strict(os.path.join(root, "docs", "PRD.md"))
    cur = {rid: h for rid, h, _, _ in ui}
    for r in d["requirements"]:
        if r["id"] not in cur:
            probs.append("%s: orphaned requirement %s (no longer [UI] in docs/PRD.md)" % (rel_index, r["id"]))
        elif cur[r["id"]] != r["hash"]:
            probs.append("%s: hash mismatch for %s (index %s…, PRD %s…)"
                         % (rel_index, r["id"], r["hash"][:12], cur[r["id"]][:12]))
    tokens_abs = os.path.join(ud, "tokens.css")
    has_tokens = os.path.isfile(tokens_abs)
    listed = set()
    for s in d["screens"]:
        for st in s["states"]:
            if "file" not in st:
                continue
            listed.add(st["file"])
            rel = "docs/ux/" + st["file"]
            fa = os.path.join(ud, st["file"])
            if not os.path.isfile(fa):
                probs.append("%s: missing mock" % rel)
                continue
            with open(fa, "rb") as fh:
                text = fh.read().decode("utf-8", "replace")
            probs.extend(_scan_mock(rel, text))
            if has_tokens and not _links_tokens(fa, text, tokens_abs):
                probs.append('%s: does not link tokens.css (<link rel="stylesheet" href="…tokens.css">)' % rel)
    expected = set(expected_pngs(d))
    for dirpath, dirnames, filenames in os.walk(ud):
        dirnames.sort()
        for fn in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, fn), ud).replace(os.sep, "/")
            low = fn.lower()
            if low.endswith(IMG_EXT) and rel not in expected:
                probs.append("docs/ux/%s: unreferenced image" % rel)
            elif low.endswith(".html") and rel.startswith("screens/") and rel not in listed:
                probs.append("docs/ux/%s: unlisted mock (superseded)" % rel)
    if probs:
        for p in probs:
            print("ux-invalid: " + p)
        return 1
    exp, have = present_pngs(root, d)
    print("ok %d screens, %d requirements, screenshots %d/%d"
          % (len(d["screens"]), len(d["requirements"]), len(have), len(exp)))
    return 0


def cmd_coverage_check(args):
    if len(args) < 3:
        raise UxError("ux: usage: coverage-check <prd-path> <label> <id>…")
    prd, label, ids = args[0], args[1], args[2:]
    d = checked_index("-", sys.stdin.buffer.read(), label)
    ui, _ = parse_prd_strict(prd)
    cur = {rid: h for rid, h, _, _ in ui}
    merged = {r["id"]: r for r in d["requirements"]}
    rc = 0
    for rid in ids:
        r = merged.get(rid)
        if r is None:
            print("uncovered\t%s" % rid)
            rc = 1
        elif cur.get(rid) != r["hash"]:
            print("stale\t%s\thash differs from merged index" % rid)
            rc = 1
        else:
            print("covered\t%s\t%s" % (rid, ",".join("docs/ux/screens/%s/" % s for s in r["screens"])))
    return rc


CMDS = {"ui-reqs": cmd_ui_reqs, "delta": cmd_delta, "validate": cmd_validate,
        "coverage-check": cmd_coverage_check}


def run(cmds, argv):
    try:
        if len(argv) < 2 or argv[1] not in cmds:
            raise UxError("ux: usage: %s {%s} …" % (os.path.basename(argv[0]), "|".join(cmds)))
        rc = cmds[argv[1]](argv[2:])
        sys.stdout.flush()
        return rc
    except UxError as e:
        print(str(e), file=sys.stderr)
        return e.rc
    except SystemExit:
        raise
    except BaseException as e:  # noqa: BLE001 — the fail-loud top-level handler
        print("ux: internal error: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(run(CMDS, sys.argv))

"""prd_lint.py — the mechanical PRD pre-pass (TDD 0073; FR-103, FR-105).

Run as `python3 -I -B prd_lint.py <subcommand> …` from scripts/lib/prd-lint.sh.

  delta <prd> <base-file|none>               new / changed / removed requirement ids
  check <prd> <base-file|none> [--degraded]  findings, one per line, then a summary

`none` means there is no base: every requirement is new. Stdin is never read.
`--degraded` (passed by prd-lint.sh when the base is missing only because the
repo is outside git) reports acceptance.missing and placeholder as info.

Findings print as `<path>:<line> <severity> <code>: <message>` (tdd-lint's
format). rc 0 = no major finding, rc 1 = at least one major, rc 2 = a parse or
internal error. The requirement grammar is ux_record.parse_requirements, so
this lint and tl_ux_ui_reqs cannot disagree. stdlib only.
"""
import difflib
import os
import re
import sys

# -I drops the script dir from sys.path; load the sibling module explicitly,
# exactly as ux_render.py does.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ux_record import (CODE_RE, FENCE_RE, REQ_RE, RETIRED_RE, UxError,  # noqa: E402
                       _delist, _read_lines, parse_requirements)

# The placeholder tokens: to-be-decided, to-do, triple question mark.
PLACEHOLDER_RE = re.compile(r"(?<![A-Za-z0-9_])(?:TBD|TODO)(?![A-Za-z0-9_])|\?\?\?")
ACCEPT_RE = re.compile(r"(?:—|--)\s+Acceptance:")
MALFORMED_RE = re.compile(r"^\*\*[A-Za-z]+ ?- ?[0-9]")
OVERRIDE_RE = re.compile(r'^- "(?P<finding>.+)" (?:—|--) overridden: (?P<rationale>.*)$')
HEADING_RE = re.compile(r"^(#{1,6})\s")
REQ_SECTION_RE = re.compile(r"^##\s+Requirements\b")
OQ_SECTION_RE = re.compile(r"^##\s+Open questions\b")
# A sentence ends at . ! or ? followed (after any closing emphasis/quote) by
# whitespace or the end; a requirement id's digits are not a quantity.
SENT_END_RE = re.compile(r"[.!?](?=[*_)\"'\]]*(?:\s|$))")
ID_TOKEN_RE = re.compile(r"\b[A-Z][A-Z0-9]*-[0-9]+\b")
DIGIT_RE = re.compile(r"[0-9]")
VAGUE_TERMS = ["fast", "quick", "quickly", "slow", "scalable", "robust", "secure",
               "user-friendly", "intuitive", "easy", "simple", "efficient", "flexible",
               "seamless", "reliable", "performant", "appropriate", "adequate",
               "sufficient", "reasonable", "minimal", "as needed", "as appropriate"]
VAGUE_RE = re.compile(r"(?<![A-Za-z0-9_-])(%s)(?![A-Za-z0-9_-])"
                      % "|".join(re.escape(t).replace(r"\ ", r"\s+")
                                 for t in sorted(VAGUE_TERMS, key=len, reverse=True)), re.I)
RATIONALE_MIN, RATIONALE_MAX = 20, 400


class LintError(Exception):
    pass


def _strip_ux(msg):
    return msg[4:] if msg.startswith("ux: ") else msg


class Doc:
    """A parsed PRD: lines, fence mask, headings, sections, requirement blocks."""

    def __init__(self, path, lines):
        self.path = path
        self.lines = lines
        # Raises UxError (malformed [UI], unterminated fence) before anything else.
        allreqs = parse_requirements(path, retired_ends=True, lines=lines)
        self.fenced = []
        fence = None
        for line in lines:
            m = FENCE_RE.match(line)
            if fence is None and m:
                fence = m.group(1)[0]
                self.fenced.append(True)
            elif fence is not None:
                if m and m.group(1)[0] == fence:
                    fence = None
                self.fenced.append(True)
            else:
                self.fenced.append(False)
        self.headings = []  # (index, level, text)
        for i, line in enumerate(lines):
            m = HEADING_RE.match(line)
            if m and not self.fenced[i]:
                self.headings.append((i, len(m.group(1)), line.rstrip()))
        self.req_range = self._section(REQ_SECTION_RE)
        self.oq_range = self._section(OQ_SECTION_RE)
        lo, hi = self.req_range or (0, 0)
        # (id, lineno, block, title) inside ## Requirements only.
        self.reqs = [r for r in allreqs if lo <= r[1] - 1 < hi]
        self.blocks = {}
        for rid, ln, block, _ in self.reqs:
            self.blocks.setdefault(rid, (ln, block))

    def _section(self, rx):
        """[start, end) line indexes of the first `## <name>` section's body."""
        for n, (i, level, text) in enumerate(self.headings):
            if level == 2 and rx.match(text):
                end = len(self.lines)
                for j, lv, _ in self.headings[n + 1:]:
                    if lv <= 2:
                        end = j
                        break
                return (i + 1, end)
        return None

    def in_range(self, rng, i):
        return rng is not None and rng[0] <= i < rng[1]

    def empty_sections(self):
        """[(index, heading text)] for each ##/### heading with no content
        (not even a subsection) before the next heading of the same or higher level."""
        out = []
        hidx = {i: lv for i, lv, _ in self.headings}
        for i, level, text in self.headings:
            if level not in (2, 3):
                continue
            empty = True
            for j in range(i + 1, len(self.lines)):
                if j in hidx and hidx[j] <= level:
                    break
                if self.lines[j].strip():
                    empty = False
                    break
            if empty:
                out.append((i, text))
        return out


def load(path, label=None):
    return Doc(label or path, _read_lines(path))


def load_base(base, unparseable_stream):
    """(Doc|None, degraded). `none` or a missing file is no base (not degraded);
    a base that fails to parse is no base, with a degrade line (never rc 2)."""
    if base == "none" or not os.path.exists(base):
        return None, False
    try:
        return load(base), False
    except UxError as e:
        print("prd-lint: base unparseable (%s); every requirement is new" % _strip_ux(str(e)),
              file=unparseable_stream)
        return None, True


def compute_delta(cur, base):
    """[(kind, id, lineno)]: new/changed in PRD order, then removed in base order."""
    rows, seen = [], set()
    have = base.blocks if base is not None else {}
    for rid, ln, _, _ in cur.reqs:
        if rid in seen:
            continue
        seen.add(rid)
        block = cur.blocks[rid][1].rstrip()
        if rid not in have:
            rows.append(("new", rid, ln))
        elif have[rid][1].rstrip() != block:
            rows.append(("changed", rid, ln))
    if base is not None:
        done = set()
        for rid, ln, _, _ in base.reqs:
            if rid not in cur.blocks and rid not in done:
                done.add(rid)
                rows.append(("removed", rid, ln))
    return rows


def new_lines(cur, base):
    """Indexes of cur lines that are new compared with the base (line-level diff)."""
    if base is None:
        return set(range(len(cur.lines)))
    a = [l.rstrip() for l in base.lines]
    b = [l.rstrip() for l in cur.lines]
    out = set()
    for tag, _, _, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag in ("replace", "insert"):
            out.update(range(j1, j2))
    return out


def _code_masked(line):
    """The line with inline code removed; a span holding a digit leaves `0`
    behind so a number written in code still quantifies a term."""
    return CODE_RE.sub(lambda m: " 0 " if DIGIT_RE.search(m.group(2)) else " ", line)


def vague_findings(cur, rid, ln, block):
    nlines = block.count("\n") + 1
    idx = range(ln - 1, ln - 1 + nlines)
    text = "\n".join("" if cur.fenced[i] else _code_masked(cur.lines[i]) for i in idx)
    out, seen = [], set()
    for m in VAGUE_RE.finditer(text):
        term = re.sub(r"\s+", " ", m.group(1).lower())
        if term in seen:
            continue
        end = SENT_END_RE.search(text, m.end())
        rest = text[m.end():end.start() if end else len(text)]
        if DIGIT_RE.search(ID_TOKEN_RE.sub("", rest)):
            continue
        seen.add(term)
        line = ln + text.count("\n", 0, m.start())
        out.append((line, "info", "vague.term",
                    '%s uses "%s" with no number in the same sentence' % (rid, term)))
    return out


def cmd_delta(args):
    if len(args) != 2:
        raise LintError("prd-lint: usage: delta <prd> <base-file|none>")
    cur = load(args[0])
    base, _ = load_base(args[1], sys.stderr)
    for kind, rid, _ in compute_delta(cur, base):
        print("%s\t%s" % (kind, rid))
    return 0


def cmd_check(args):
    degraded = False
    if args and args[-1] == "--degraded":
        degraded, args = True, args[:-1]
    if len(args) != 2:
        raise LintError("prd-lint: usage: check <prd> <base-file|none> [--degraded]")
    cur = load(args[0])
    base, unparseable = load_base(args[1], sys.stdout)
    degraded = degraded or unparseable
    soft = "info" if degraded else "major"
    fresh = new_lines(cur, base)
    rows = compute_delta(cur, base)
    delta = [(rid, ln) for kind, rid, ln in rows if kind in ("new", "changed")]
    f = []  # (line, severity, code, message)

    if cur.req_range is None:
        f.append((1, "major", "placeholder", "no ## Requirements section"))

    for i, line in enumerate(cur.lines):
        if cur.fenced[i] or i not in fresh:
            continue
        m = PLACEHOLDER_RE.search(CODE_RE.sub("", line))
        if m:
            f.append((i + 1, soft, "placeholder", 'placeholder text "%s"' % m.group(0)))
    base_empty = {t for _, t in base.empty_sections()} if base is not None else set()
    for i, text in cur.empty_sections():
        if text not in base_empty:
            f.append((i + 1, soft, "placeholder", 'empty section "%s"' % text))

    for rid, ln in delta:
        block = cur.blocks[rid][1]
        if not ACCEPT_RE.search(block):
            f.append((ln, soft, "acceptance.missing", "%s has no — Acceptance: clause" % rid))
        f.extend(vague_findings(cur, rid, ln, block))

    first = {}
    for rid, ln, _, _ in cur.reqs:
        if rid in first:
            f.append((ln, "major", "id.duplicate",
                      "%s is already the title at line %d" % (rid, first[rid])))
        else:
            first[rid] = ln

    for i, line in enumerate(cur.lines):
        if cur.fenced[i] or i not in fresh or not cur.in_range(cur.req_range, i):
            continue
        body = _delist(line)
        if MALFORMED_RE.match(body) and not REQ_RE.match(body) and not RETIRED_RE.match(body):
            tok = body[2:].split("**", 1)[0][:40]
            f.append((i + 1, "major", "id.malformed",
                      '"%s" is not a requirement id (expected **<ID>-<n> <title>**)' % tok))

    for i, line in enumerate(cur.lines):
        if cur.fenced[i] or not cur.in_range(cur.oq_range, i):
            continue
        m = OVERRIDE_RE.match(line.rstrip())
        if m:
            n = len(m.group("rationale").strip())
            if not RATIONALE_MIN <= n <= RATIONALE_MAX:
                f.append((i + 1, "major", "override.rationale",
                          'override of "%s" has a %d-character rationale (needs %d-%d)'
                          % (m.group("finding")[:60], n, RATIONALE_MIN, RATIONALE_MAX)))

    f.sort(key=lambda x: (x[0], x[2]))
    for line, sev, code, msg in f:
        print("%s:%d %s %s: %s" % (cur.path, line, sev, code, msg))
    major = sum(1 for x in f if x[1] == "major")
    info = len(f) - major
    print("prd-lint: delta %d requirements, %d major, %d info" % (len(delta), major, info))
    return 1 if major else 0


CMDS = {"delta": cmd_delta, "check": cmd_check}


def main(argv):
    try:
        if len(argv) < 2 or argv[1] not in CMDS:
            raise LintError("prd-lint: usage: %s {%s} …" % (os.path.basename(argv[0]), "|".join(CMDS)))
        rc = CMDS[argv[1]](argv[2:])
        sys.stdout.flush()
        return rc
    except LintError as e:
        print(str(e), file=sys.stderr)
        return 2
    except UxError as e:
        print("prd-lint: %s" % _strip_ux(str(e)), file=sys.stderr)
        return 2
    except SystemExit:
        raise
    except BaseException as e:  # noqa: BLE001 — the fail-loud top-level handler
        print("prd-lint: internal error: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

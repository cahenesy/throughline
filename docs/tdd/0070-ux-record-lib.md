# TDD 0070: UX record library — `[UI]` requirements, the UX index, validation, rendering

Status: implemented
PRD refs: FR-89, FR-90, FR-91, FR-94, FR-99, FR-101, NFR-4
PRD-rev: 3be6232
ADR constraints: 0004, 0005, 0006, 0010, 0011, 0017

## Approach
`/ux-author` (TDD 0071) and the `/prd-author` / `/tdd-author`
integration (TDD 0072) need the same mechanical facts:
- which requirements are `[UI]`, and which of those changed since the
  last UX set;
- whether a UX set on disk is well-formed and self-contained;
- what the merged UX set covers.

This TDD puts them in one library that the skills call from `tl:`
blocks. The library holds **mechanics only**: it parses, hashes,
validates, renders and reports. Visual design belongs to the delegates
(FR-92, TDD 0071).

The library has two layers:
- `scripts/lib/ux.sh`: thin `tl_ux_*` bash wrappers;
- `scripts/lib/ux_record.py` and `ux_render.py`: python3 stdlib only,
  run as `python3 -I <file> <subcommand>`.

A wrapper whose input has no `[UI]` returns before looking for python3,
so non-UI repos never need it. Every parse failure fails loudly with a
named `ux:` message, and none reads as "no UI requirements" (rubric:
fail-loud parsing; L-005).

## Components & interfaces

### The `[UI]` grammar (FR-89)
A `[UI]` requirement is a line matching (Python `re`, after stripping one
leading list marker `- ` or `* `):

```
^\*\*(?P<id>[A-Z][A-Z0-9]*-[0-9]+) \[UI\] (?P<title>[^*]+?)\.?\*\*
```

Example: `- **FR-120 [UI] Saved searches.** …`.

The scan skips two kinds of text:
- **Fenced code blocks.** Lines between ```` ``` ```` / `~~~` fences are
  ignored.
- **Inline code spans.** Text between backticks on a line is removed
  for the `[UI]` scan only. Titles and block hashes use the **raw**
  line, so a backticked span in a title is kept. This lets a PRD talk *about* the marker, as
  throughline's own PRD does in FR-89 (`` `[UI]` ``), without marking
  anything.

Every remaining `[UI]` occurrence must sit on a line that matches the
grammar. Otherwise the scan fails with
`ux: malformed [UI] marker at <path>:<line>: <line text, first 120 chars>`
(rc 2).

Title and boundary matching runs after stripping one leading list
marker. A `^#` line inside a fenced block does not end a block. A
requirement's **block** starts at its title line and runs to the line
before the next requirement title (any line matching the grammar with or
without `[UI]`, i.e. `^\*\*[A-Z][A-Z0-9]*-[0-9]+ `), the next markdown
heading (`^#`), or EOF. Its **hash** is SHA-256 over the block's lines,
with trailing whitespace stripped and joined by `\n`, as lowercase hex.

### `docs/ux/index.json` schema v1 (FR-91, FR-92, FR-93, FR-94, FR-99)
All paths are relative to `docs/ux/`. They must not be absolute and must
not contain a `..` segment.

| Field | Type | Rule |
|---|---|---|
| `schema` | int | `1` |
| `prd_rev` | string | `git log -1 --format=%h <integration> -- docs/PRD.md`: the short SHA of the last commit touching the merged PRD the set was made for. It uses the same convention as a TDD's `PRD-rev`, and every UX run sets it |
| `platforms` | array of `web`/`ios`/`android` | non-empty |
| `viewports` | array of `{name, width, height}` | `name` is `[a-z0-9-]+`, unique; width and height are ints in 200–4000 |
| `fidelity` | `high`/`mid`/`low` | `high` is not allowed when `delegates` is empty (FR-92) |
| `delegates` | array of strings | skills or tools **invoked this run**; `[]` means no delegate |
| `design_system` | `{tokens, adr, source}` | `tokens`: `"tokens.css"` or null; `adr`: repo-relative ADR path or null; `source`: `existing-code`/`established`/`none` |
| `requirements` | array of `{id, hash, screens}` | `id` matches the id grammar and is unique; `hash` is 64 lowercase hex; `screens` is non-empty and names existing screen ids. **PRD-consistency (validate only):** `id` is a current `[UI]` id and `hash` equals its current block hash |
| `screens` | array of `{id, title, baseline, states}` | `id` is `[a-z0-9][a-z0-9-]*` and unique; `baseline` is `code-derived` / `live capture (not committed)` / `none (new screen)` |
| `states[]` | `{name, file}` or `{name, na}` | `name` is one of `default`/`empty`/`loading`/`error`, each exactly once; `default` must have a `file`; `file` is `screens/<screen-id>/<name>.html`; `na` is a non-empty reason |
| `flow` | array of screen ids | every screen exactly once, in user-flow order |

**Screenshots are not in the index.** They are derived from the files on
disk. The expected set is every `screens/<sid>/<state>@<viewport>.png`
for each state with a file and each declared viewport. Whether that set
is complete is *reported*, never stored or enforced. Nothing in the index
can disagree with the PNGs, so neither the skill nor `render` has a
screenshot field to keep in sync.

Rules not marked "validate only" are **structural**. Every subcommand
that reads an index (`delta`, `validate`, `coverage-check`, `render`,
`index-html`) enforces them, and a violation is rc 2 (invalid index).
The PRD-consistency rules are enforced only by `validate`. `delta` and `coverage-check` exist to *report* PRD drift as
`changed` / `orphaned` / `stale`, never to reject it.

The skill (TDD 0071) owns `index.json` entirely. The library never
writes it.

A first run starts from this initial object:
`{"schema":1,"prd_rev":"","platforms":[],"viewports":[],"fidelity":"low","delegates":[],"design_system":{"tokens":null,"adr":null,"source":"none"},"requirements":[],"screens":[],"flow":[]}`.
The skill fills it before the first validate.

### `scripts/lib/ux.sh` functions
`ux.sh` sources `plugin-root.sh` and `verdicts.sh` (for
`_tl_integration_ref`), failing closed with `ux: cannot source <file>`
(rc 2). It resolves its python files through `tl_plugin_root`. When `python3` is absent and the
input contains `[UI]`, it prints `ux: python3 required` and returns rc 3.

- **`tl_ux_ui_reqs <prd-path>`.** One line per `[UI]` requirement,
  `<id>\t<hash>\t<title>`, in file order.
  - rc 0, including empty output when there are no `[UI]` lines;
  - rc 1 for an unreadable file (`ux: cannot read <path>`);
  - rc 2 for a malformed marker, or a duplicate id
    (`ux: duplicate [UI] id <id> at <path>:<l1>,<l2>`);
  - rc 3 for missing python3.

  Short-circuit: when `grep -qF '[UI]' <prd-path>` finds nothing, it
  prints nothing and returns rc 0 without python3.
- **`tl_ux_delta <prd-path> <index-path>`.** `<index-path>` may be a file
  that does not exist (meaning no UX set yet), or `-` (read from stdin).
  It prints one line per affected id, in PRD order:
  - `new\t<id>\t<title>`: a `[UI]` id that is not in `requirements`;
  - `changed\t<id>\t<title>`: in the index, with a different hash;
  - `orphaned\t<id>`: in the index, but no longer `[UI]`. `validate`
    rejects any orphaned mapping, so the skill always drops it and
    reports it in the PR (TDD 0071 step 4). The user is never asked to
    keep it.

  Return codes:
  - rc 0, including empty output when nothing changed;
  - rc 2 for an invalid index (`ux: invalid index <path>: <reason>`) or
    a `tl_ux_ui_reqs` failure;
  - rc 3 for missing python3.
- **`tl_ux_validate <repo-root>`.** Validates `docs/ux/index.json`
  against schema v1 and the PRD at `<repo-root>/docs/PRD.md`, then checks
  the files on disk:
  - every `states[].file` exists;
  - each mock's reference values pass the scan. The values scanned are
    `src`, `href`, every `srcset` candidate, `action`, `poster`, `data`,
    `xlink:href`, `background`, meta-refresh targets, and CSS `url()`,
    `@import` and `image-set()`. Entity-, CSS- and percent-encoded forms
    are decoded first. Any of these is rejected:
    - an `http(s)` / `ws(s)` / `ftp` / `file` scheme, a
      protocol-relative `//`, or a `data:text/html`;
    - an absolute path;
    - a path climbing out of `docs/ux/`.

    `xmlns` attributes and plain text are not scanned. The scan is
    defence in depth: rev 2's render isolation is the boundary;
  - when `tokens.css` exists, each mock links it through a relative
    `<link rel="stylesheet" href="…tokens.css">`;
  - every image (`*.png` / `*.jpg` / `*.jpeg` / `*.webp`) under
    `docs/ux/` is an **expected** screenshot path: a declared screen, a
    state that has a file, and a declared viewport. Anything else is
    `unreferenced image`. That covers captures (FR-94), stale PNGs of a
    removed viewport or state, and stray files;
  - every `*.html` under `screens/` is a listed `states[].file`. A
    leftover mock of a state that is now `n/a`, or of a removed screen,
    is `unlisted mock (superseded)`.

  Missing expected PNGs are **not** an error, because they are only
  reported.   It prints
  `ok <n> screens, <m> requirements, screenshots <k>/<total>` with rc 0,
  where `<k>/<total>` counts the expected PNGs present. Otherwise it
  prints one line per problem, `ux-invalid: <path>: <reason>`, with rc 1.
  It returns rc 2 when the index is missing or unparseable, and rc 3 for
  missing python3.
- **`tl_ux_render <repo-root> <screen-id>…`.** It needs at least one
  screen id. Called with none, it returns rc 2 with
  `ux: render needs explicit screen ids` and touches nothing. Every id
  must exist in the index (rc 2 otherwise). There is no "all" default,
  so a run can never re-render or clear screens it did not plan (FR-99).
  It renders every state-with-file × viewport for the named screens to
  `docs/ux/screens/<sid>/<state>@<viewport>.png`. It works in this fixed
  order:
  1. **Clear.** Delete every existing image under the named screens'
     directories. This runs before the browser is looked for, so
     superseded screenshots never survive (FR-99).
  2. **Find a browser.**
  3. **Render** each shot.
  4. **On failure,** delete only the PNGs this call wrote.
  5. **Report.** The last stdout line is the status of the **whole**
     set, from disk: `screenshots: complete` when every expected PNG
     exists, otherwise `screenshots not rendered: <reason>`. The reason
     is this call's failure or no-browser reason when there was one,
     otherwise `partial — <n> missing`.

  `render` never writes `index.json`. Screens it was not asked to render
  keep their PNG bytes in every outcome.
  - **Browser choice.** It uses the first executable found among
    `$THROUGHLINE_UX_BROWSER`, `chromium`, `chromium-browser`,
    `google-chrome`, `chrome`. It never passes `--no-sandbox`.
  - **Render isolation (rev 2).** The browser never opens a repo file,
    and never uses `file://`:
    1. Check the **whole** `docs/ux/` tree for symlinks
       (`symlink_problems`), and check the named screens' mocks with the
       scan. Then copy `docs/ux/` with `copytree(symlinks=True)` into a
       private dir from `tempfile.mkdtemp()`, **outside the repo**. Only
       the python server reads it, never the browser, so snap confinement
       does not matter. Re-check the copy for symlinks, which closes the
       check-to-copy TOCTOU, and remove the copy in a `finally`.
    2. Rewrite each `.html`/`.htm`/`.xhtml` file in the copy as
       `<!DOCTYPE html>` + `CSP_META` + its original bytes, with one
       leading UTF-8 BOM stripped. There is no HTML parsing, so no
       prefix can precede the policy.
    3. Serve the copy from a loopback-only HTTP server: a stdlib
       `ThreadingHTTPServer` with daemon threads, bound to `127.0.0.1:0`,
       GET only, rooted at the copy, with request logging silenced so
       nothing reaches the `ux:` stderr channel. **Every** response,
       including SVG, XML and errors, carries the same policy as a
       `Content-Security-Policy` HTTP header. The meta is a second
       layer. HTML is served as `text/html; charset=utf-8`.
    4. Shoot each page as
       `<browser> --headless=new --disable-gpu --hide-scrollbars --host-resolver-rules="MAP * ~NOTFOUND" --proxy-server=http://127.0.0.1:9 --proxy-bypass-list="<-loopback>;127.0.0.1:<port>" --window-size=<w>,<h> --screenshot=<abs png> http://127.0.0.1:<port>/screens/<sid>/<state>.html`,
       under `timeout 60` when `timeout` exists.

    The policy (header and `CSP_META`) is
    `default-src 'self' data:; script-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'; style-src 'self' 'unsafe-inline' data:`.

    The **browser** therefore enforces the boundary, and the regex scan
    in `validate` is defence in depth:
    - no script runs;
    - an `http://` page cannot load `file:` URLs;
    - an absolute or `../` path resolves on the server, which serves
      only the copy, and returns 404;
    - every other host, IP literal or loopback port goes to a dead
      proxy, and CSP blocks it as well.

    A symlink anywhere in `docs/ux/`, or a named-screen mock that fails
    the scan, makes render refuse before clearing (rc 2).
  - **On success:** one `rendered <path>` line per PNG, then the status
    line, then rc 0.
  - **No browser:** status line
    `screenshots not rendered: no headless Chrome on PATH`, rc 4.
  - **Failed shot:** a non-zero exit, or a missing or empty PNG, triggers
    step 4. Status line
    `screenshots not rendered: <browser> failed on <html path> (rc <n>)`,
    rc 4.

  rc 4 is a declared degrade, not an error (FR-91). It returns rc 2 for an
  invalid index and rc 3 for missing python3.
- **`tl_ux_capture <url> <outdir> <w>x<h>`** (FR-94). It makes one
  capture per call. The skill calls it once per existing screen and
  viewport, with `<outdir>` = `<capture-dir>/<screen-id>`, which it
  creates when it is absent.
  - It refuses (rc 2) when `<outdir>` resolves inside a git work tree,
    or when `<url>` is not `http://` or `https://`.
  - It runs the same browser binary as `render`, without
    `--host-resolver-rules` **and without either proxy flag** (a capture
    must reach the user's live app), to
    `<outdir>/capture-<w>x<h>.png`, and
    prints the path. A capture is reference only, and this function
    writes no index.
  - rc 0 means captured. rc 4 means no browser was found or the capture
    failed, with `capture failed: <reason>` printed. rc 2 means the
    arguments were refused.
- **`tl_ux_index_html <repo-root>`.** Regenerates `docs/ux/index.html`
  from the index and the PNG files present. It is deterministic: the
  same inputs give the same bytes. The page contains:
  - a provenance header: PRD rev, platforms, viewports, fidelity,
    delegates (or `none: degraded`), design-system source, and the
    screenshot count `<k>/<total>` from disk;
  - the flow, one ordered `<a href="screens/<sid>/default.html">` per
    screen, followed by links to the screen's other state files;
  - a requirement → screens table;
  - a **missing screenshots** list: every expected PNG absent on disk,
    or `none`. A partial set never looks complete.

  It escapes every value from the index with `html.escape`. It returns
  rc 0, rc 2 for an invalid index, and rc 3 for missing python3. This
  page is the flow index of FR-91.
- **`tl_ux_merged_index <repo-root>`.** Prints
  `git show <integration>:docs/ux/index.json` to stdout. `<integration>`
  comes from `_tl_integration_ref`: `THROUGHLINE_INTEGRATION_BRANCH`,
  then `origin/HEAD`, then `main`, then `master`.
  - rc 0: the blob was printed;
  - rc 1: no index on the integration branch yet, so nothing is printed;
  - rc 2: no integration ref resolves (`ux: no integration branch`).

  It first runs a best-effort `timeout 20 git fetch -q origin`, at most
  once per process (a marker variable). `THROUGHLINE_UX_NOFETCH=1` skips
  it; `tdd-lint` sets this so the pre-pass never reaches the network.
  A fetch failure is ignored, and the fetch does nothing without an `origin` remote. This
  keeps a merge on the host from being misread as "no merged UX set". It
  writes `ux: merged index from <ref> @ <short-sha>` to stderr, so a
  stale read is visible. It needs no python3.
- **`tl_ux_coverage <repo-root> <id>…`.** Reads the **merged** index
  through `tl_ux_merged_index`. For each id it prints one of:
  - `covered\t<id>\tdocs/ux/screens/<sid>/[,…]`;
  - `stale\t<id>\thash differs from merged index` when the merged hash differs from the current
    working-tree PRD block (the UX set predates the change);
  - `uncovered\t<id>` when the id is absent from the merged index, or no
    merged index exists.

  It returns rc 0 when every id is covered and rc 1 when any id is stale
  or uncovered. It returns rc 2 when the blob exists but is invalid, or
  when no integration ref resolves (`ux: no integration branch`), and
  rc 3 for missing python3. A UX set that exists only on a branch never
  counts (FR-101).

### Python entry points
`ux_record.py` holds the subcommands `ui-reqs`, `delta`, `validate` and
`coverage-check`. `coverage-check` takes the merged blob on stdin and the
PRD path; the git read stays in bash. `ux_render.py` holds `render`,
`capture` and `index-html`. Each one:
- writes its results to stdout;
- writes `ux: …` diagnostics to stderr;
- exits with the codes above;
- runs any unexpected exception through a top-level handler that prints
  `ux: internal error: <type>: <msg>` and exits 2, never 0.

## Data & state
The only persistent state is the committed `docs/ux/` tree: `index.json`,
`index.html`, `tokens.css`, `screens/<sid>/*.html` and
`screens/<sid>/*.png`. The library never writes `index.json`. It writes
PNGs only from `render`, and `index.html` only from `index-html` (through
a temp file and `os.replace`). Everything else under `docs/ux/` is
written by the skill (TDD 0071).

## Sequencing / implementation plan
1. Write `ux_record.py` with `ui-reqs` (grammar, fence/inline-code
   skipping, block hashing) and `delta`, plus their `ux.sh` wrappers with
   the `[UI]` short-circuit and the python3 check.
2. Add `validate` (schema, file checks, offline-URL scan, tokens link,
   unreferenced images) and `coverage-check`, plus the `tl_ux_validate` /
   `tl_ux_coverage` wrappers (integration-ref resolution, `git show`).
3. Write `ux_render.py` with `render` (browser discovery, rev-2
   isolation: private copy, byte-0 CSP, loopback server; scoped
   cleanup; whole-set status line) and
   `index-html`, plus their wrappers.

## Failure modes & edge cases
**Real risks**
- *`[UI]` in PRD prose.* Inline code and fences are skipped. Any other
  stray `[UI]` fails loudly (rc 2 with the line), so a requirement is
  never silently lost.
- *Other id schemes.* Any `PREFIX-N` id works (`FR-12`, `R-3`, `UX-4`).
  An id of another shape that carries `[UI]` fails loudly.
- *CDN links or local-file references from a delegate.* `validate`
  names them. At render time the browser cannot load them anyway (rev 2
  isolation), so even a scanner miss cannot bake a local file or a
  network fetch into a PNG.
- *A browser hangs.* `timeout 60` turns it into a failed shot, which
  gives the scoped cleanup and rc 4.
- *No integration ref* (fresh clone): coverage gives rc 2. It never
  treats the working tree as merged.

**Overblown risks**
- *Hash churn.* Trailing whitespace is stripped, and any other edit is
  meant to count as `changed`.
- *PNG size.* Accepted in the PRD (FR-99, no LFS). Re-renders replace
  files rather than adding them.

**Unspoken risks**
- *Hash agreement.* A hash copied wrongly into the index is rejected by
  `validate`. It is never committed and later misread as `stale`.
- *A partial screenshot set looks complete.* Prevented three ways:
  - the cleanup lists only PNGs that exist;
  - completeness is computed from disk, never stored;
  - `index.html` lists the missing PNGs.
- *`index.html` injection.* Delegate-supplied titles are escaped.

## Verification plan
- **Surface:** stdout, stderr and rc of each `tl_ux_*` function; the
  bytes of `docs/ux/index.json` and `index.html`; the PNG files on disk.
- **Harness:** temp git repos with a fixture `docs/PRD.md`, run through
  the sourced `ux.sh` with `env -i` plus `PATH`. A stub browser
  (`THROUGHLINE_UX_BROWSER` pointing at a script that writes a 1×1 PNG
  and logs its argv) is used. When a real Chrome/Chromium is on PATH, one
  real render is also run. Every negated assertion first asserts that its
  file is readable (L-001/L-011), and every temp directory is
  trap-cleaned (L-004).
- **Observation points → expected (PASS):**
  1. **Grammar.** A PRD with `**FR-1 [UI] Login.**`, `**R-7 [UI] Cart**`,
     a backticked `` `[UI]` `` in prose, and a fenced `[UI]` → exactly
     two lines, `FR-1` then `R-7`, rc 0.
  2. **Loud miss.** A bare `see [UI] below` line → rc 2, and stderr names
     `<path>:<line>`. A duplicate `FR-1` → rc 2 `duplicate`.
  3. **Short-circuit.** A PRD with no `[UI]` and `PATH` without python3
     → rc 0, empty output. The same PRD with one `[UI]` → rc 3
     `ux: python3 required`.
  4. **Throughline's own PRD.** `tl_ux_ui_reqs docs/PRD.md` on this repo
     → rc 0, empty output: every mention there is backticked.
  5. **Delta.**
     - No index → all `new`.
     - Index holding FR-1's current hash → FR-1 absent from the output.
     - Editing FR-1's body text → `changed FR-1`.
     - Removing FR-1's marker → `orphaned FR-1`.
     - A malformed index → rc 2.
  6. **Validate.** One valid fixture set →
     `ok 1 screens, 1 requirements, screenshots 0/1`,
     rc 0. Each of these mutations gives rc 1 with a `ux-invalid:` line
     naming it:
     - a mock with `<script src="https://cdn…">`;
     - `url(//fonts…)`;
     - a missing `tokens.css` link when `tokens.css` exists;
     - a `states` entry missing `error`;
     - `fidelity: "high"` with `delegates: []`;
     - a wrong hash;
     - a `requirements` entry whose id is no longer `[UI]` (orphaned);
     - a PNG for an undeclared viewport (`unreferenced image`);
     - a leftover `screens/a/error.html` whose state is now `n/a`;
     - a stray `docs/ux/capture.png` (`unreferenced image`);
     - a `..` path.
  7. **Render (stub).**
     - Two viewports × two state files → four `rendered` lines and four
       PNGs.
     - The last line is `screenshots: complete`, the index bytes are
       unchanged, and `validate` reports `screenshots 4/4`.
     - The stub's logged argv contains `--host-resolver-rules`, the proxy
       flags and an `http://127.0.0.1:<port>/screens/…` URL. It has no
       `--no-sandbox` and no `file://`. The stub fetches its URL argument
       while the server is live, and logs the body and the headers: the
       body starts with `<!DOCTYPE html><meta http-equiv="Content-Security-Policy"`,
       and the response has a `Content-Security-Policy` header. After
       the call, no render copy remains.
  8. **Render scoping (FR-99).** After rendering both screens, re-render
     only `a` with a changed mock → `a`'s PNGs are rewritten, and `b`'s
     PNG bytes and mtimes are unchanged. Delete `a`'s `error.html` from
     the index → its old PNG is gone after the re-render.
  9. **Render degrade.**
     - No browser on PATH → rc 4, and the last line is exactly
       `screenshots not rendered: no headless Chrome on PATH`.
     - A stub that exits 1 on the second shot → rc 4, and no PNG written
       by this call remains.
     - **Two screens.** Render `a` and `b`, then re-render only `a` with
       a failing stub:
       - `a`'s old PNGs are gone;
       - `b`'s bytes are unchanged;
       - `validate` gives rc 0 with `screenshots 2/4` (one state per
         screen);
       - `index.html` lists `a`'s two missing PNGs.
     - **Explicit ids.** `tl_ux_render <repo>` with no ids → rc 2, the
       message above, and no file changes. An unknown id → rc 2.
     - **Pre-render validate.** A second run adds screen `c` (HTML only,
       no PNGs) to a set whose other PNGs are complete → `validate` rc 0
       with `screenshots 4/6`. Rendering `c` → `screenshots: complete`.
     - **Viewport removed.** Drop a viewport from the index →
       `validate` rc 1, `unreferenced image` for each old PNG. Rendering
       every screen clears them → rc 0.
     - **No browser, scoped.** In the two-screen setup, re-render `a`
       with no browser → `a`'s PNGs are gone, `b`'s remain, and
       `validate` gives rc 0.
  9b. **Capture.**
      - `tl_ux_capture http://127.0.0.1:<port>/ <tmp-outside-repo> 390x844`
        against a local `python3 -m http.server` → rc 0, and a PNG
        exists in the out dir.
      - The same call with `<outdir>` inside the temp repo → rc 2.
      - A `file://` URL → rc 2.
      - The stub's argv has no `--host-resolver-rules` and no
        `--proxy-server`.
  10. **Real render** (when Chrome is present): one mock at 390×844 → a
      PNG whose IHDR width/height read 390×844. A styled mock linking
      `tokens.css` and an inline-SVG mock render non-blank.
  10b. **Isolation probe matrix** (real Chrome; rev 2). A brightly
      coloured canary sits outside the repo.
      - **Browser-enforced cases.** The CSS-file vectors (`tokens.css` /
        `shared.css` with `url(/abs/canary.png)`) and the base64
        `data:text/css` vector must **pass validate (rc 0), render rc 0,
        and show 0 canary pixels**. This proves the browser, not the
        scanner, holds the boundary.
      - **Other cases.** Each renders with 0 canary pixels, or render
        refuses it (rc 2), or Chrome hangs (rc 4, no PNG):
      - `<script>location=…</script>` behind `<!-->` / `<!--->`;
      - `<img src=…>` with an unquoted `=`, a backtick, or NBSP;
      - `data:text/css;base64` `url()`;
      - `tokens.css` and another CSS file with `url(/abs/canary.png)`;
      - meta refresh;
      - `<base href=file:///>`;
      - an `<img>` on another loopback port, and a `%2e%2e` path.

      A positive control (a direct, unisolated `file://` render of one
      vector) shows the canary, which proves the probe can see a leak.
  11. **index.html.**
      - Deterministic: two runs give identical bytes.
      - A screen titled `<img src=x onerror=alert(1)>` appears escaped.
      - Links appear in `flow` order.
      - The provenance block names the delegates, or
        `none: degraded`.
  12. **Coverage.** Commit index A on `master`, and index B (which adds
      FR-2) on a branch, with the branch checked out.
      - `tl_ux_coverage . FR-1 FR-2` → `covered FR-1 docs/ux/screens/…/`
        and `uncovered FR-2`, rc 1.
      - Edit FR-1's text in the working-tree PRD → `stale FR-1`.
      - `THROUGHLINE_INTEGRATION_BRANCH=nope` with no main/master/
        origin → rc 2 `ux: no integration branch`.
  13. **Internal error.** Feed `delta` a binary index → rc 2,
      `ux: invalid index …` or `ux: internal error …`, never rc 0.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement traceability | Every FR-89..101 (+79/81/86/87, NFR-1/3) maps to a named ux.sh function, skill block, agent rule, or lint check | One mapping indirect but named | An in-scope FR untraced |
| interface concreteness | Every ux.sh function has args, stdout, rc pinned; index.json schema field-by-field | One rc implicit | Reader cannot tell what a function prints |
| alternatives-analysis substance | Chrome CLI vs Playwright, JSON vs MD index, hash vs git-diff delta, tokens.css vs JSON each with reason | One rejection thin | None named |
| verification-plan actionability | Functions driven in temp repos; skill blocks extracted and run; negated checks assert readability first (L-001/L-011) | One check text-only with stated reason | Behaviour asserted only by grepping prose |
| scope-bound adherence | Each TDD <=8 files, <=500 body lines, padded estimates; exceptions declared | One justified exception | Over a bound unexplained |
| naming consistency | ux.sh names, index.json fields, screen-path form identical across 0070-0072 | One alias reconciled | Same concept named two ways |
| delegation, not reinvention | Skill invokes present delegates by role; ux.sh holds only mechanics, no design logic | Delegates named only as examples | throughline code generates visual design |
| fail-loud parsing | Malformed [UI] marker, unreadable index, awk failure each exit non-zero with a named message | One path returns empty silently but is tested | A parse failure reads as no UI requirements |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-89 `[UI]` marker is the only signal | `[UI]` grammar + `tl_ux_ui_reqs` (inline-code/fence skipping, loud miss); obs 1–4 |
| FR-90 delta-driven scope | per-requirement block hash + `tl_ux_delta` (`new`/`changed`/`orphaned`); obs 5 |
| FR-91 artifact set | index schema v1 (states incl. `n/a`, flow, viewports, provenance, baseline); `tl_ux_validate` offline-URL scan; `tl_ux_index_html` flow index; `tl_ux_render` with declared rc-4 degrade; obs 6, 7, 9–11 |
| FR-94 captures never committed | `validate`'s `unreferenced image` rule; `tl_ux_capture` refuses an in-repo out dir; `baseline` enum; obs 6, 9b |
| FR-99 point-in-time, superseded | `tl_ux_render` scoped deletion and re-render; untouched screens byte-identical; obs 8 |
| FR-101 merged-mock check (query side) | `tl_ux_merged_index` + `tl_ux_coverage` read the integration-branch blob; `stale`/`uncovered`; obs 12 |
| FR-91 "networking disabled" (rev 2; ADR 0017 §1) | render isolation via private copy + byte-0 CSP + loopback HTTP; obs 7, 10b |
| NFR-4 verdict honesty | rc 4 degrade distinct from rc 1/2 failures; internal errors exit 2; obs 9, 13 |

Skill-side FR-90/91/94/99 is TDD 0071; the FR-101 refusal is TDD 0072.

## Dependencies considered
- **python3 stdlib (chosen)** for nested JSON, SHA-256, regex HTML
  scanning and atomic replace, in one implementation.
  - *Rejected: jq + awk + sha256sum.* Awk block and URL parsing repeats
    the silent-empty-parse class (L-005), and the logic splits across
    three tools.
  - *Rejected: a jq → python3 cascade (`drafts.sh` style).* Two
    implementations to keep identical. Python is needed only when
    `[UI]` appears.
- **Headless Chrome/Chromium CLI (chosen):** an existing binary with
  stable `--screenshot` / `--window-size` flags and no install step.
  - *Rejected: Playwright via `npx`.* It downloads browsers, needs Node
    in non-JS repos, and makes throughline an installer (FR-83, ADR
    0010).
  - *Rejected: a delegate's screenshot tool.* It varies by harness.
- **JSON index (chosen):** a strict schema a validator can reject.
  *Rejected: `docs/ux/INDEX.md`.* Hand-edited tables parse fragilely,
  and the generated `index.html` already covers readability.
- **`tokens.css` custom properties (chosen):** offline mocks link it
  directly, with no build step. *Rejected: `tokens.json` (W3C / Style
  Dictionary).* Every mock would need a CSS generation step. It is more
  portable to design tools, but that is not needed for an HTML record.
- **Loopback HTTP + CSP render isolation (chosen, rev 2):** stdlib
  `http.server` on `127.0.0.1:0`, rooted at a private copy, so the
  browser enforces the boundary.
  - *Rejected: `file://` + regex scan.* A browser can read any local
    file, and three build gates found scanner bypasses.
  - *Rejected: bwrap/container sandboxing.* Linux-only, and a new system
    dependency.
  - *Rejected: `--blink-settings=scriptEnabled=false`.* Headless
    `--screenshot` writes no PNG with it, and it does not stop static
    loads.
- **Text-hash change detection (chosen).** *Rejected: git-diffing the
  PRD at the recorded rev.* It breaks on rewritten or squashed history,
  and mapping hunks to blocks needs a second parser.

## PRD conflicts surfaced (and resolution)
- FR-92's acceptance says the UX index "says `delegates: none`". This
  design writes `"delegates": []` in `index.json` and renders it as
  `none: degraded` in `index.html` and the PR body. Runtime-verify
  should read FR-92 as "the index records no delegate": an empty array
  in the JSON, and `none: degraded` on the human surfaces.
- FR-89's acceptance says `grep -n '\[UI\]' docs/PRD.md` "lists exactly
  the marked requirements". That is false for any PRD that mentions the
  marker in backticked prose, including throughline's own. The
  authoritative list is `tl_ux_ui_reqs`, which skips inline code and
  fences.
- FR-91's acceptance says "networking disabled". The PRD leaves how to
  enforce that open. This design checks it statically in `validate`, and
  the browser enforces it at render time through rev 2's loopback-HTTP +
  CSP isolation.

- The PRD's cascade note (#191) expected supersession of the
  `/prd-author` and `/tdd-author` TDDs. FR-89–FR-101 are new
  requirements, and the existing FRs those TDDs cover are unchanged, so
  this pass adds new TDDs and supersedes none.

**Revision 2 (build halts, run 20261006-220142).** The original render
opened repo mocks over `file://`, and relied on a resolver rule plus a
regex scan. Gates showed three times that a scanner cannot bound what a
browser loads:
- script navigation;
- `<!-->` before the doctype;
- unquoted, backtick and NBSP attribute values;
- base64 CSS;
- `url()` in CSS files.

Each baked an out-of-repo file into a committed PNG. Rev 2 makes the
browser the boundary (a private copy, a byte-0 CSP, loopback HTTP), keeps
the scan as a second layer, and records the private-copy and byte-0 CSP
changes the build already made.

## Decisions to promote (ADR candidates)
- Promoted: ADR 0017 (UX record: in-repo, self-contained HTML, delegated by
  role, design input not a build gate), added in this design PR.

## Scope override
The body runs past the 500-line bound (612, per the pre-pass) because of revision 2, which
is gate-driven security hardening of a unit that is already built: the
render-isolation contract, its real-browser probe-matrix observation, and
the revision record that explains why the original `file://` render was
replaced. None of it is new scope. Every added line constrains how
`render` stops out-of-repo files reaching committed PNGs. Splitting
render/capture/index-html into another TDD now would orphan the retained
build branch, which already implements them, and force a re-scope with
no reviewer gain.

## Touched files
- `scripts/lib/ux.sh` — `tl_ux_*` wrappers, `[UI]` short-circuit, python3 check, integration ref + `git show`
- `scripts/lib/ux_record.py` — `ui-reqs`, `delta`, `validate`, `coverage-check`
- `scripts/lib/ux_render.py` — `render`, `capture`, `index-html`
- `tests/ux-record.test.sh` — obs 1–6, 12, 13
- `tests/ux-render.test.sh` — obs 7–11, 9b, 10b
- `tests/implement-gate.test.sh` — registers the two new evals (ci-checks runs only this aggregator)

## Expected diff size
- `scripts/lib/ux.sh` — 130 lines
- `scripts/lib/ux_record.py` — 660 lines (exception: one cohesive module; the field-by-field schema validator, the PRD parser, and the reference scanner are each a single concern, and splitting them adds import plumbing for no reviewer gain)
- `scripts/lib/ux_render.py` — 420 lines (exception: render isolation — private copy, byte-0 CSP, loopback server, browser lifecycle — must stay in one place to be auditable)
- `tests/ux-record.test.sh` — 330 lines (exception: fixture-heavy eval; one mutation per validate rule)
- `tests/ux-render.test.sh` — 600 lines (exception: real-browser probe matrix plus stub scoping cases)
- `tests/implement-gate.test.sh` — 6 lines

Total expected diff: 2146 lines across 6 files.

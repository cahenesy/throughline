#!/usr/bin/env bash
# format-and-lint-hook.test.sh — eval for TDD 0068 / FR-21 (issue #180):
# hooks/format-and-lint.sh honors the edited repo's configuration.
#
# Every case runs the hook the way Claude Code does: the PostToolUse JSON on
# stdin, under `env -i HOME=<tmp> PATH=<stubdir>:/usr/bin:/bin`, started from a
# directory UNRELATED to the edited file. The tools are stubs that log
# "<tool> <argv> @<cwd>" to <case>/calls and mimic the real tools' contracts:
#   - ruff format / prettier --write / gofmt -w rewrite the file to a marker;
#   - rustfmt in stdin mode prints a marker; rustfmt <file> (the rejected
#     design) rewrites EVERY .rs in the dir, so recursion is observable;
#   - rustfmt --check prints a diff + rc 1 on UNCLEAN stdin;
#   - gofmt -l (like real gofmt) exits 0 either way and prints
#     `<standard input>` when stdin contains UNCLEAN;
#   - lint stubs print STUB-DIAG on stdout + rc 1 when the file contains BAD.
# Observation 13 (real tools) belongs to the runtime-verify gate, not here.
# Negated checks assert their input is readable first (L-001, L-011); every
# temp dir is under one trap-cleaned root (L-004).
#
# Run: bash tests/format-and-lint-hook.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/hooks/format-and-lint.sh"
SKILL="$REPO/skills/bootstrap-project/SKILL.md"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
ROOT="$(mktemp -d)"; ROOT="$(cd -P "$ROOT" && pwd -P)"
trap 'rm -rf "$ROOT" "$RESULTS"' EXIT
mkdir -p "$ROOT/elsewhere"
BASH_BIN="$(command -v bash)"

# newcase <name>: fresh dir with bin/ (stubs), calls (empty, readable), home/.
newcase() {
  C="$ROOT/$1"; mkdir -p "$C/bin" "$C/home"; : > "$C/calls"
  local t
  for t in ruff rustfmt cargo gofmt golangci-lint; do mkstub "$C/bin/$t" "$t"; done
}
# mkstub <path> <name>: write one stub tool (calls path baked in at creation).
mkstub() {
  local p="$1" name="$2"
  cat > "$p" <<EOF
#!/usr/bin/env bash
CALLS="$C/calls"; NAME="$name"
EOF
  cat >> "$p" <<'EOF'
printf '%s %s @%s\n' "$NAME" "$*" "$PWD" >> "$CALLS"
last=""; for a in "$@"; do last="$a"; done
case "$NAME" in
  ruff)
    if [ "${1:-}" = format ]; then printf 'FORMATTED-BY-RUFF\n' > "$last"; exit 0; fi
    if grep -q BAD "$last" 2>/dev/null; then echo "STUB-DIAG $last:1:1 F401"; exit 1; fi
    exit 0 ;;
  rustfmt)
    in=""
    case " $* " in
      *" --check "*) in="$(cat)"
        case "$in" in *UNCLEAN*) echo "Diff in stdin at line 1"; exit 1;; esac
        exit 0 ;;
    esac
    case "$last" in
      *.rs) for f in "$(dirname "$last")"/*.rs; do printf '// RUSTFMT-RECURSED\n' > "$f"; done; exit 0 ;;
    esac
    in="$(cat)"; printf '// RUSTFMT-FORMATTED\n%s\n' "$in"; exit 0 ;;
  gofmt)
    if [ "${1:-}" = -l ]; then
      in="$(cat)"; case "$in" in *UNCLEAN*) echo '<standard input>';; esac; exit 0
    fi
    if [ "${1:-}" = -w ]; then printf '// GOFMT-FORMATTED\n' > "$last"; fi
    exit 0 ;;
  cargo|golangci-lint)
    if grep -rqs BAD --include='*.rs' --include='*.go' .; then echo "STUB-DIAG lint"; exit 1; fi
    exit 0 ;;
  prettier)
    [ "${1:-}" = --write ] && printf 'FORMATTED-BY-PRETTIER\n' > "$last"; exit 0 ;;
  eslint)
    if grep -q BAD "$last" 2>/dev/null; then echo "STUB-DIAG $last eslint"; exit 1; fi
    exit 0 ;;
esac
exit 0
EOF
  chmod +x "$p"
}
# jsbins <dir>: stub prettier + eslint into <dir>/node_modules/.bin.
jsbins() { mkdir -p "$1/node_modules/.bin"
  mkstub "$1/node_modules/.bin/prettier" prettier
  mkstub "$1/node_modules/.bin/eslint" eslint; }
mkrepo() { mkdir -p "$1"; git -C "$1" init -q
  git -C "$1" config user.email t@t.t; git -C "$1" config user.name t; }
commit() { git -C "$1" add -A && git -C "$1" commit -qm c; }
# run <file> [path]: run the hook on <file> from an unrelated cwd.
run() {
  local f="$1" p="${2:-$C/bin:/usr/bin:/bin}"
  ( cd "$ROOT/elsewhere" && printf '{"tool_input":{"file_path":"%s"}}' "$f" \
      | env -i HOME="$C/home" TMPDIR="$C" PATH="$p" "$BASH_BIN" "$HOOK" \
        >"$C/out" 2>"$C/err" )
  RC=$?
}
readable() { [ -f "$1" ] && [ -r "$1" ]; }
has_call()  { readable "$C/calls" && grep -qF -- "$1" "$C/calls"; }
no_call()   { readable "$C/calls" && ! grep -qF -- "$1" "$C/calls"; }
calls_empty() { readable "$C/calls" && [ ! -s "$C/calls" ]; }
same() { readable "$1" && readable "$2" && cmp -s "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1 [rc=$RC calls=$(tr '\n' '|' <"$C/calls" 2>/dev/null) err=$(head -c 300 "$C/err" 2>/dev/null)]"; fi; }

# --- [1] no config, Python -> nothing --------------------------------------
echo "[1] Python with no ruff config is a no-op"
newcase o1; mkrepo "$C/r"; printf 'import os\nimport sys\n' > "$C/r/m.py"; commit "$C/r"
cp "$C/r/m.py" "$C/m.orig"; run "$C/r/m.py"
check "rc 0" '[ "$RC" -eq 0 ]'
check "no tool called" 'calls_empty'
check "file byte-identical" 'same "$C/m.orig" "$C/r/m.py"'
check "stdout and stderr empty" 'readable "$C/out" && readable "$C/err" && [ ! -s "$C/out" ] && [ ! -s "$C/err" ]'

# --- [2] lint-only ruff config -> check only, report-only ------------------
echo "[2] [tool.ruff] + [tool.ruff.lint] only: lint, never format"
newcase o2; mkrepo "$C/r"
printf '[tool.ruff]\nline-length = 88\n\n[tool.ruff.lint]\nselect = ["F"]\n' > "$C/r/pyproject.toml"
printf 'x=1\n' > "$C/r/m.py"; cp "$C/r/m.py" "$C/m.orig"; run "$C/r/m.py"
check "rc 0" '[ "$RC" -eq 0 ]'
check "only call is ruff check --no-fix --output-format concise <file>" \
  '[ "$(wc -l <"$C/calls")" -eq 1 ] && has_call "ruff check --no-fix --output-format concise $C/r/m.py"'
check "no ruff format call" 'no_call "ruff format"'
check "file unchanged" 'same "$C/m.orig" "$C/r/m.py"'

# --- [3] [tool.ruff.format] -> format then check ---------------------------
echo "[3] [tool.ruff.format] opts in to formatting"
newcase o3; mkrepo "$C/r"
printf '[tool.ruff]\n\n[tool.ruff.format]\nquote-style = "double"\n' > "$C/r/pyproject.toml"
printf 'x=1\n' > "$C/r/m.py"; run "$C/r/m.py"
check "rc 0" '[ "$RC" -eq 0 ]'
check "ruff format first, then ruff check --no-fix" \
  '[ "$(sed -n 1p "$C/calls" | cut -d" " -f1-2)" = "ruff format" ] && sed -n 2p "$C/calls" | grep -qF "ruff check --no-fix --output-format concise $C/r/m.py"'
check "file rewritten by the formatter" 'grep -qx FORMATTED-BY-RUFF "$C/r/m.py"'

# --- [4] ruff precedence: ruff.toml > .ruff.toml > pyproject.toml ----------
echo "[4] per-directory ruff config precedence"
newcase o4a; mkrepo "$C/r"
printf '[format]\nquote-style = "double"\n' > "$C/r/ruff.toml"
printf '[tool.ruff]\nline-length = 88\n' > "$C/r/pyproject.toml"
printf 'x=1\n' > "$C/r/m.py"; run "$C/r/m.py"
check "ruff.toml with [format] beside a format-less pyproject -> formats" 'has_call "ruff format $C/r/m.py"'
newcase o4b; mkrepo "$C/r"
printf '[lint]\nselect = ["F"]\n' > "$C/r/ruff.toml"
printf '[tool.ruff]\n\n[tool.ruff.format]\n' > "$C/r/pyproject.toml"
printf 'x=1\n' > "$C/r/m.py"; cp "$C/r/m.py" "$C/m.orig"; run "$C/r/m.py"
check "format-less ruff.toml beats pyproject [tool.ruff.format] -> no format" \
  'has_call "ruff check" && no_call "ruff format" && same "$C/m.orig" "$C/r/m.py"'
newcase o4c; mkrepo "$C/r"
printf '[format]\n' > "$C/r/.ruff.toml"
printf 'x=1\n' > "$C/r/m.py"; run "$C/r/m.py"
check ".ruff.toml with [format] -> formats" 'has_call "ruff format $C/r/m.py"'
newcase o4d; mkrepo "$C/r"
printf '[tool.ruffle]\nx = 1\n' > "$C/r/pyproject.toml"
printf 'x=1\n' > "$C/r/m.py"; run "$C/r/m.py"
check "[tool.ruffle] look-alike is not a ruff config -> no calls" 'calls_empty && [ "$RC" -eq 0 ]'

# --- [5] lint failure surfaces on stderr -----------------------------------
echo "[5] lint failure: rc 2, diagnostics on stderr, stdout empty"
newcase o5; mkrepo "$C/r"
printf '[tool.ruff.lint]\nselect = ["F"]\n' > "$C/r/pyproject.toml"
printf 'BAD = 1\n' > "$C/r/m.py"; run "$C/r/m.py"
check "rc 2" '[ "$RC" -eq 2 ]'
check "stderr carries STUB-DIAG and (diagnostics above)" \
  'readable "$C/err" && grep -q STUB-DIAG "$C/err" && grep -qF "(diagnostics above)" "$C/err"'
check "stderr ends with the pinned ruff message" \
  '[ "$(tail -n1 "$C/err")" = "format-and-lint: ruff reported errors in $C/r/m.py (diagnostics above). Fix the root cause; do not suppress." ]'
check "stdout empty" 'readable "$C/out" && [ ! -s "$C/out" ]'

# --- [7] JS/TS --------------------------------------------------------------
echo "[7] JS/TS: config + local bin, top-level package.json keys, no --fix"
newcase o7a; mkrepo "$C/r"; jsbins "$C/r"; printf 'x\n' > "$C/r/a.js"; run "$C/r/a.js"
check "no config (bins present) -> no calls, rc 0" 'calls_empty && [ "$RC" -eq 0 ]'
newcase o7b; mkrepo "$C/r"; mkdir -p "$C/r/pkg/src"; jsbins "$C/r/pkg"
printf '{}\n' > "$C/r/pkg/.prettierrc"; printf 'x\n' > "$C/r/pkg/src/a.ts"; run "$C/r/pkg/src/a.ts"
check ".prettierrc + local bin -> prettier --write <file> from the config dir" \
  'has_call "prettier --write $C/r/pkg/src/a.ts @$C/r/pkg" && grep -qx FORMATTED-BY-PRETTIER "$C/r/pkg/src/a.ts"'
newcase o7c; mkrepo "$C/r"; jsbins "$C/r"
printf '{"devDependencies":{"prettier":"^3.0.0","eslint":"^9"}}\n' > "$C/r/package.json"
printf 'x\n' > "$C/r/a.js"; cp "$C/r/a.js" "$C/a.orig"; run "$C/r/a.js"
check "prettier only in devDependencies -> no prettier call" \
  'no_call "prettier" && no_call "eslint" && same "$C/a.orig" "$C/r/a.js"'
newcase o7d; mkrepo "$C/r"; jsbins "$C/r"
printf '{"prettier":{},"devDependencies":{"prettier":"^3"}}\n' > "$C/r/package.json"
printf 'x\n' > "$C/r/a.js"; run "$C/r/a.js"
check "top-level \"prettier\": {} -> prettier call" 'has_call "prettier --write $C/r/a.js"'
newcase o7e; mkrepo "$C/r"; jsbins "$C/r"
printf 'export default [];\n' > "$C/r/eslint.config.js"
printf 'x\n' > "$C/r/a.jsx"; run "$C/r/a.jsx"
check "eslint.config.js + bin -> eslint <file>, rc 0" \
  'has_call "eslint $C/r/a.jsx @$C/r" && [ "$RC" -eq 0 ]'
newcase o7f; mkrepo "$C/r"; jsbins "$C/r"
printf '{"eslintConfig":{}}\n' > "$C/r/package.json"
printf 'BAD\n' > "$C/r/a.mjs"; run "$C/r/a.mjs"
check "package.json eslintConfig + BAD -> rc 2, diag on stderr naming eslint" \
  '[ "$RC" -eq 2 ] && grep -q STUB-DIAG "$C/err" && tail -n1 "$C/err" | grep -qF "eslint reported errors in $C/r/a.mjs (diagnostics above)"'
newcase o7g; mkrepo "$C/r"
printf '{}\n' > "$C/r/.prettierrc"; printf 'export default [];\n' > "$C/r/eslint.config.mjs"
printf 'x\n' > "$C/r/a.cjs"; cp "$C/r/a.cjs" "$C/a.orig"; run "$C/r/a.cjs"
check "config without a local bin -> rc 0, no call" \
  '[ "$RC" -eq 0 ] && calls_empty && same "$C/a.orig" "$C/r/a.cjs"'

# --- [8] discovery is from the file, never $PWD -----------------------------
echo "[8] config next to the file, hook run from an unrelated cwd"
newcase o8a; mkrepo "$C/r"; mkdir -p "$C/r/deep/pkg"
printf '[tool.ruff.format]\n' > "$C/r/deep/pkg/pyproject.toml"
printf 'x=1\n' > "$C/r/deep/pkg/m.py"; run "$C/r/deep/pkg/m.py"
check "config beside the file is detected (formats + lints)" \
  'has_call "ruff format $C/r/deep/pkg/m.py" && has_call "ruff check --no-fix"'
newcase o8b; mkrepo "$C/r"; printf 'x=1\n' > "$C/r/m.py"; cp "$C/r/m.py" "$C/m.orig"
printf '[tool.ruff]\n[tool.ruff.format]\n' > "$ROOT/elsewhere/pyproject.toml"
run "$C/r/m.py"; rm -f "$ROOT/elsewhere/pyproject.toml"
check "a config in \$PWD does not apply to a file in another repo" \
  'calls_empty && same "$C/m.orig" "$C/r/m.py"'

# --- [9] Rust ---------------------------------------------------------------
echo "[9] Rust: stdin rustfmt, HEAD-clean guard, git state, no recursion"
mkcrate() { mkrepo "$C/r"; mkdir -p "$C/r/src"; printf '[package]\nname = "x"\n%s' "${1:-}" > "$C/r/Cargo.toml"; }
newcase o9a; mkcrate
printf 'mod foo;\nfn a() {}\n' > "$C/r/src/lib.rs"; printf 'fn  messy( ){}\n' > "$C/r/src/foo.rs"; commit "$C/r"
cp "$C/r/src/foo.rs" "$C/foo.orig"; printf 'mod foo;\nfn a() {}\nfn b(){}\n' > "$C/r/src/lib.rs"
run "$C/r/src/lib.rs"
check "clean tracked file: HEAD checked with --edition 2021 --check" \
  'has_call "rustfmt --edition 2021 --check @$C/r/src"'
check "formatted via stdin mode (no file arg), --edition 2021, cwd = file dir" \
  'grep -qx "rustfmt --edition 2021 @$C/r/src" "$C/calls"'
check "file written back with the formatter output" 'head -n1 "$C/r/src/lib.rs" | grep -qx "// RUSTFMT-FORMATTED"'
check "child module foo.rs byte-identical" 'same "$C/foo.orig" "$C/r/src/foo.rs"'
check "cargo clippy --quiet from the crate root" 'has_call "cargo clippy --quiet @$C/r"'
newcase o9b; mkcrate 'edition = "2018"
'
printf 'UNCLEAN\n' > "$C/r/src/lib.rs"; commit "$C/r"
printf 'UNCLEAN\nfn b(){}\n' > "$C/r/src/lib.rs"; cp "$C/r/src/lib.rs" "$C/lib.orig"; run "$C/r/src/lib.rs"
check "HEAD UNCLEAN: checked with the Cargo.toml edition (2018)" 'has_call "rustfmt --edition 2018 --check"'
check "HEAD UNCLEAN: no format pass, file byte-identical" \
  '! grep -qx "rustfmt --edition 2018 @$C/r/src" "$C/calls" && same "$C/lib.orig" "$C/r/src/lib.rs"'
newcase o9c; mkcrate; printf 'fn a() {}\n' > "$C/r/src/lib.rs"; commit "$C/r"
printf 'fn n(){}\n' > "$C/r/src/new.rs"; run "$C/r/src/new.rs"
check "new (untracked) file: formatted without a HEAD check" \
  'no_call "--check" && head -n1 "$C/r/src/new.rs" | grep -qx "// RUSTFMT-FORMATTED"'
newcase o9d; mkdir -p "$C/nogit/src"; printf '[package]\nname = "x"\n' > "$C/nogit/Cargo.toml"
printf 'fn a(){}\n' > "$C/nogit/src/lib.rs"; cp "$C/nogit/src/lib.rs" "$C/lib.orig"; run "$C/nogit/src/lib.rs"
check "outside git: no rustfmt, file byte-identical" 'no_call "rustfmt" && same "$C/lib.orig" "$C/nogit/src/lib.rs"'
newcase o9e; mkrepo "$C/r"; printf 'fn a(){}\n' > "$C/r/lib.rs"; run "$C/r/lib.rs"
check "no Cargo.toml -> no calls" 'calls_empty && [ "$RC" -eq 0 ]'
newcase o9f; mkcrate; printf 'fn a() {}\n' > "$C/r/src/lib.rs"; commit "$C/r"
printf 'fn BAD() {}\n' > "$C/r/src/lib.rs"; run "$C/r/src/lib.rs"
check "clippy failure -> rc 2 with diagnostics on stderr" \
  '[ "$RC" -eq 2 ] && grep -q STUB-DIAG "$C/err" && readable "$C/out" && [ ! -s "$C/out" ]'

# --- [10] Go ----------------------------------------------------------------
echo "[10] Go: gofmt HEAD-clean guard reads stdout, golangci-lint needs config"
mkmod() { mkrepo "$C/r"; printf 'module x\n' > "$C/r/go.mod"; }
newcase o10a; mkmod; printf 'package x\n' > "$C/r/x.go"; commit "$C/r"
printf 'package x\nfunc a(){}\n' > "$C/r/x.go"; run "$C/r/x.go"
check "clean tracked file: gofmt -l on HEAD, then gofmt -w <file>" \
  'has_call "gofmt -l @$C/r" && has_call "gofmt -w $C/r/x.go" && grep -qx "// GOFMT-FORMATTED" "$C/r/x.go"'
check "no .golangci.* -> no golangci-lint call" 'no_call "golangci-lint"'
newcase o10b; mkmod; printf 'package x // UNCLEAN\n' > "$C/r/x.go"; commit "$C/r"
printf 'package x // UNCLEAN\nfunc a(){}\n' > "$C/r/x.go"; cp "$C/r/x.go" "$C/x.orig"; run "$C/r/x.go"
check "HEAD UNCLEAN (stub rc 0 + stdout) -> gofmt -l ran, NO gofmt -w" \
  'has_call "gofmt -l" && no_call "gofmt -w" && same "$C/x.orig" "$C/r/x.go"'
newcase o10c; mkmod; printf 'linters: {}\n' > "$C/r/.golangci.yml"; printf 'package x\n' > "$C/r/x.go"; run "$C/r/x.go"
check ".golangci.yml at module root -> golangci-lint run ./... from the root" \
  'has_call "golangci-lint run ./... @$C/r"'
check "new file -> gofmt -w without a HEAD check" 'no_call "gofmt -l" && has_call "gofmt -w $C/r/x.go"'
newcase o10d; mkmod; mkdir -p "$C/r/pkg"; printf 'linters: {}\n' > "$C/r/.golangci.yaml"
printf 'package pkg\n' > "$C/r/pkg/p.go"; run "$C/r/pkg/p.go"
check "file in a subpackage -> golangci-lint run ./pkg/..." 'has_call "golangci-lint run ./pkg/... @$C/r"'
newcase o10e; mkmod; mkdir -p "$C/r/pkg"; printf 'linters: {}\n' > "$C/r/pkg/.golangci.yml"
printf 'package pkg\n' > "$C/r/pkg/p.go"; run "$C/r/pkg/p.go"
check "config only in a subdirectory -> golangci-lint not called" 'has_call "gofmt" && no_call "golangci-lint"'

# --- [12] regression: fully configured repo; missing parser stays loud ------
echo "[12] regression: fully configured repo still formats + lints; no parser -> loud"
newcase o12; mkrepo "$C/r"; jsbins "$C/r"
printf '[tool.ruff]\n[tool.ruff.lint]\nselect = ["F"]\n[tool.ruff.format]\n' > "$C/r/pyproject.toml"
printf '{"semi":false}\n' > "$C/r/.prettierrc"; printf 'export default [];\n' > "$C/r/eslint.config.js"
printf 'x=1\n' > "$C/r/m.py"; printf 'x\n' > "$C/r/a.ts"
run "$C/r/m.py"; RC1=$RC; run "$C/r/a.ts"
check "python: formatted and linted, rc 0" \
  '[ "$RC1" -eq 0 ] && has_call "ruff format $C/r/m.py" && has_call "ruff check --no-fix --output-format concise $C/r/m.py"'
check "js: prettier --write then eslint, rc 0" \
  '[ "$RC" -eq 0 ] && has_call "prettier --write $C/r/a.ts" && has_call "eslint $C/r/a.ts" && grep -qx FORMATTED-BY-PRETTIER "$C/r/a.ts"'
newcase o12b; mkdir -p "$C/min"; ln -s "$(command -v cat)" "$C/min/cat"
printf 'x=1\n' > "$C/m.py"; run "$C/m.py" "$C/min"
check "jq and python3 hidden -> rc 2 + the need-jq-or-python3 message" \
  '[ "$RC" -eq 2 ] && grep -qF "need jq or python3" "$C/err"'

# --- [6] no --fix anywhere ---------------------------------------------------
echo "[6] no tool was ever called with --fix"
cat "$ROOT"/o*/calls > "$ROOT/all-calls" 2>/dev/null
if readable "$ROOT/all-calls" && [ -s "$ROOT/all-calls" ] && grep -q 'ruff check' "$ROOT/all-calls"; then
  if grep -qE '(^| )--fix( |$)' "$ROOT/all-calls"; then
    bad "a tool was called with --fix: $(grep -E '(^| )--fix( |$)' "$ROOT/all-calls" | head -3)"
  else ok "no --fix across $(wc -l <"$ROOT/all-calls") logged calls"; fi
else bad "aggregated call log unreadable or empty — cannot assert absence of --fix"; fi

# --- [11] bootstrap writes the format opt-in (text check: skill prose) -------
echo "[11] bootstrap skill names [tool.ruff.format] on every formatter-writing path"
# Text check by necessity: the skill is prose an eval cannot execute.
# bullet <start-regex>: print that bullet up to the next bullet/heading/blank.
bullet() { awk -v re="$1" 'f && (/^- \*\*/ || /^#/ || /^[0-9]+\. / || /^$/) {exit} $0 ~ re {f=1} f' "$SKILL"; }
if readable "$SKILL" && [ -s "$SKILL" ]; then
  g="$(bullet '^- [*][*]Greenfield:[*][*]')"; b="$(bullet '^- [*][*]Brownfield, no linter/formatter:[*][*]')"
  s="$(bullet '^2[.] Install [+] configure the default formatter')"
  if [ -n "$g" ] && printf '%s' "$g" | grep -qF '[tool.ruff.format]'; then ok "greenfield path names [tool.ruff.format]"
  else bad "greenfield bullet missing or lacks [tool.ruff.format]"; fi
  if [ -n "$b" ] && printf '%s' "$b" | grep -qF '[tool.ruff.format]'; then ok "brownfield add-the-default path names [tool.ruff.format]"
  else bad "brownfield-add bullet missing or lacks [tool.ruff.format]"; fi
  if [ -n "$s" ] && printf '%s' "$s" | grep -qF '[tool.ruff.format]'; then ok "greenfield checklist step 2 names [tool.ruff.format]"
  else bad "greenfield checklist step 2 missing or lacks [tool.ruff.format]"; fi
  if grep -qF '.prettierrc' "$SKILL" && grep -qF 'eslint.config' "$SKILL"; then ok "skill names .prettierrc and eslint.config.* for JS/TS"
  else bad "skill lacks the JS/TS formatter opt-in (.prettierrc + eslint.config.*)"; fi
else bad "bootstrap SKILL.md unreadable or empty: $SKILL"; fi

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== format-and-lint hook (0068): $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

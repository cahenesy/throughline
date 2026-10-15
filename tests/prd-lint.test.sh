#!/usr/bin/env bash
# prd-lint.test.sh — eval for TDD 0073 / FR-103 (and FR-105's mechanical half):
# the PRD pre-pass scripts/lib/prd-lint.sh + prd_lint.py, and the
# parse_requirements refactor of ux_record.py (no [UI] regression).
#
# Observation points 1–7, 9, 9b, 9c, 14–17 and 19 of the TDD's Verification
# plan. Every function runs through the sourced prd-lint.sh in a clean
# `env -i` shell against temp git repos whose `master` holds the base
# docs/PRD.md and whose working tree holds the edit. A missing file is a FAIL
# (L-001), every negated grep first asserts its input is readable/non-empty
# (L-001/L-011), every temp dir is trap-cleaned (L-004).
#
# Written red-first. Run: bash tests/prd-lint.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PL="$REPO/scripts/lib/prd-lint.sh"
UXR="$REPO/scripts/lib/ux_record.py"
# The pre-refactor ux_record.py lives at this commit (TDD 0073's base).
PRE_REFACTOR=4f217b3
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
command -v python3 >/dev/null 2>&1 || bad "infra: python3 not found"
[ -r "$PL" ] || bad "infra: $PL missing/unreadable"
G() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=master -c commit.gpgsign=false "$@"; }

# pl <dir> '<cmds>' [VAR=val …] — source prd-lint.sh in a clean shell in <dir>.
# Sets OUT ERR RC; ALL = stdout+stderr.
pl() {
  local d="$1" c="$2"; shift 2
  ( cd "$d" && exec env -i HOME="$H" PATH="${PLPATH:-$PATH}" CLAUDE_PLUGIN_ROOT="$REPO" \
      GIT_CEILING_DIRECTORIES="$ROOT" "$@" \
      "$BASH_BIN" -c ". $(q "$PL") || exit 98; $c" ) >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"; ALL="$OUT"$'\n'"$ERR"
}
lint()  { pl "$1" "tl_prd_lint $(q "$1")"; }
delta() { pl "$1" "tl_prd_delta $(q "$1")"; }
# has <text> <fixed-string> — non-empty input that contains the string.
has()   { [ -n "$1" ] && printf '%s\n' "$1" | grep -qF -- "$2"; }
# hasnt <text> <fixed-string> — non-empty (readable) input without it.
hasnt() { [ -n "$1" ] && ! printf '%s\n' "$1" | grep -qF -- "$2"; }
lineof() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

# mkrepo <dir> <base-prd-file|-> — git repo, `master` holds the base PRD
# (or, with `-`, only a README: no PRD on the base). The working tree's
# docs/PRD.md starts as a copy of the base.
mkrepo() {
  local d="$1" b="$2"
  mkdir -p "$d/docs"
  G -C "$d" init -q
  if [ "$b" = - ]; then echo readme >"$d/README.md"; else cp "$b" "$d/docs/PRD.md"; fi
  G -C "$d" add -A && G -C "$d" commit -qm base
}

BASE="$ROOT/base.md"
cat >"$BASE" <<'EOF'
# Product Requirements: Demo

## Problem & context
People need a demo.

## Requirements
### Core
- **FR-1 Login.** The user logs in. — Acceptance: `login` prints `ok`.
- **FR-2 Export.** The user exports a CSV. — Acceptance: `export` writes
  `out.csv`.

## Non-goals
- Nothing else.

## Constraints & assumptions
- Linux only.

## Open questions
- None yet.
EOF
# add_after <file> <anchor-fixed-string> <text…> — insert lines after anchor.
add_after() {
  local f="$1" a="$2"; shift 2
  python3 -I -c 'import sys
p, a = sys.argv[1], sys.argv[2]; new = sys.argv[3:]
ls = open(p).read().split("\n"); i = next(n for n, l in enumerate(ls) if a in l)
ls[i+1:i+1] = new; open(p, "w").write("\n".join(ls))' "$f" "$a" "$@"
}
FR3_OK='- **FR-3 Import.** The user imports a CSV. — Acceptance: `import a.csv` prints `3 rows`.'
FR3_NOACC='- **FR-3 Import.** The user imports a CSV file from disk.'

echo "[1] delta: changed / new / removed, PRD order"
R1="$ROOT/r1"; mkrepo "$R1" "$BASE"
sed -i 's/exports a CSV/exports a TSV/' "$R1/docs/PRD.md"
add_after "$R1/docs/PRD.md" '`out.csv`.' "$FR3_OK"
delta "$R1"
[ "$RC" -eq 0 ] && [ "$OUT" = "changed${TAB}FR-2"$'\n'"new${TAB}FR-3" ] \
  && ok "[1] edit FR-2 + add FR-3 → exactly changed FR-2, new FR-3 (rc 0)" \
  || bad "[1] rc=$RC out='$OUT' err='$ERR'"
sed -i '/FR-1 Login/d' "$R1/docs/PRD.md"
delta "$R1"
[ "$RC" -eq 0 ] && has "$OUT" "removed${TAB}FR-1" \
  && ok "[1] removing FR-1 → removed FR-1" || bad "[1] removed: rc=$RC out='$OUT' err='$ERR'"
R1b="$ROOT/r1b"; mkrepo "$R1b" -; cp "$BASE" "$R1b/docs/PRD.md"
delta "$R1b"
[ "$RC" -eq 0 ] && [ "$OUT" = "new${TAB}FR-1"$'\n'"new${TAB}FR-2" ] \
  && ok "[1] no PRD on master → every id new" || bad "[1] no base: rc=$RC out='$OUT' err='$ERR'"
R1c="$ROOT/r1c"; mkrepo "$R1c" "$BASE"
delta "$R1c"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "[1] unchanged PRD → empty delta, rc 0" \
  || bad "[1] unchanged: rc=$RC out='$OUT' err='$ERR'"

echo "[2] acceptance.missing — delta only"
B2="$ROOT/base2.md"; sed 's/ — Acceptance: `login` prints `ok`\.//' "$BASE" >"$B2"
R2="$ROOT/r2"; mkrepo "$R2" "$B2"
add_after "$R2/docs/PRD.md" '`out.csv`.' "$FR3_NOACC"
lint "$R2"
n3="$(lineof "$R2/docs/PRD.md" 'FR-3 Import')"
[ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qE "^docs/PRD\.md:${n3} major acceptance\.missing: .*FR-3" \
  && ok "[2] new FR-3 without acceptance → rc 1, docs/PRD.md:$n3 major acceptance.missing naming FR-3" \
  || bad "[2] rc=$RC out='$OUT' err='$ERR'"
hasnt "$OUT" "FR-1 " && hasnt "$OUT" "acceptance.missing: FR-1" \
  && ok "[2] unchanged FR-1 lacking acceptance → no finding" || bad "[2] FR-1 flagged: '$OUT'"
has "$OUT" "prd-lint: base master" && has "$OUT" "prd-lint: delta 1 requirements, 1 major, 0 info" \
  && [ "$(printf '%s\n' "$OUT" | head -1)" = "prd-lint: base master" ] \
  && ok "[2] first line 'prd-lint: base master', summary 'delta 1 requirements, 1 major, 0 info'" \
  || bad "[2] header/summary: '$OUT'"
# A wrapped acceptance clause (line break between dash and Acceptance:) counts.
R2b="$ROOT/r2b"; mkrepo "$R2b" "$BASE"
add_after "$R2b/docs/PRD.md" '`out.csv`.' '- **FR-3 Import.** The user imports a CSV file from disk. —' '  Acceptance: `import a.csv` prints `3 rows`.'
lint "$R2b"
[ "$RC" -eq 0 ] && hasnt "$ALL" "acceptance.missing" \
  && ok "[2] '—' then newline then 'Acceptance:' → accepted, rc 0" || bad "[2] wrapped: rc=$RC out='$OUT' err='$ERR'"

echo "[3] placeholder tokens and empty sections"
R3="$ROOT/r3"; mkrepo "$R3" "$BASE"
add_after "$R3/docs/PRD.md" 'People need a demo.' 'The pricing model is TODO for now.'
lint "$R3"
n="$(lineof "$R3/docs/PRD.md" 'is TODO for')"
[ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qE "^docs/PRD\.md:${n} major placeholder: " \
  && ok "[3] TODO in prose → major placeholder at line $n, rc 1" || bad "[3] prose: rc=$RC out='$OUT' err='$ERR'"
R3b="$ROOT/r3b"; mkrepo "$R3b" "$BASE"
add_after "$R3b/docs/PRD.md" 'People need a demo.' 'Write `TODO` and ``a TBD b`` in code.' '```' 'TODO: fenced ???' '```'
lint "$R3b"
[ "$RC" -eq 0 ] && hasnt "$OUT" "placeholder" \
  && ok "[3] tokens in backticks / a fence → no finding, rc 0" || bad "[3] code: rc=$RC out='$OUT' err='$ERR'"
R3c="$ROOT/r3c"; mkrepo "$R3c" "$BASE"
add_after "$R3c/docs/PRD.md" 'People need a demo.' '' '### Empty' '' '### Next' 'Some text.'
lint "$R3c"
n="$(lineof "$R3c/docs/PRD.md" '### Empty')"
[ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qE "^docs/PRD\.md:${n} major placeholder: .*empty section" \
  && ok "[3] empty ### section → major placeholder (empty section)" || bad "[3] empty: rc=$RC out='$OUT' err='$ERR'"
R3d="$ROOT/r3d"; B3d="$ROOT/base3d.md"; sed 's/People need a demo\./The TODO stays here./' "$BASE" >"$B3d"
mkrepo "$R3d" "$B3d"; add_after "$R3d/docs/PRD.md" '`out.csv`.' "$FR3_OK"
lint "$R3d"
[ "$RC" -eq 0 ] && hasnt "$OUT" "placeholder" \
  && ok "[3] an old TODO on the base never blocks a later change" || bad "[3] old token: rc=$RC out='$OUT' err='$ERR'"

echo "[4] id.duplicate and id.malformed"
R4="$ROOT/r4"; mkrepo "$R4" "$BASE"
add_after "$R4/docs/PRD.md" '`out.csv`.' '- **FR-2 Again.** Dup. — Acceptance: `x` prints `y`.'
lint "$R4"
[ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qE "major id\.duplicate: .*FR-2" \
  && ok "[4] two **FR-2 …** titles → id.duplicate, rc 1" || bad "[4] dup: rc=$RC out='$OUT' err='$ERR'"
R4b="$ROOT/r4b"; mkrepo "$R4b" "$BASE"
add_after "$R4b/docs/PRD.md" '`out.csv`.' '- **FR-2a Variant.** x. — Acceptance: `x` prints `y`.'
lint "$R4b"
[ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qE "major id\.malformed: .*FR-2a" \
  && ok "[4] **FR-2a …** → id.malformed, rc 1" || bad "[4] malformed: rc=$RC out='$OUT' err='$ERR'"

echo "[5] vague.term is info only"
R5="$ROOT/r5"; mkrepo "$R5" "$BASE"
add_after "$R5/docs/PRD.md" '`out.csv`.' '- **FR-3 Import.** The import is fast for the user. — Acceptance: `import a.csv` prints `3 rows`.'
lint "$R5"
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qE "info vague\.term: .*fast" \
  && has "$OUT" "prd-lint: delta 1 requirements, 0 major, 1 info" \
  && ok "[5] 'fast' with no number → info vague.term naming it, rc 0" || bad "[5] rc=$RC out='$OUT' err='$ERR'"
R5b="$ROOT/r5b"; mkrepo "$R5b" "$BASE"
add_after "$R5b/docs/PRD.md" '`out.csv`.' '- **FR-3 Import.** The import is fast, within 2 seconds. — Acceptance: `import a.csv` prints `3 rows`.'
lint "$R5b"
[ "$RC" -eq 0 ] && hasnt "$OUT" "vague.term" \
  && ok "[5] 'fast, within 2 seconds' → no vague.term" || bad "[5] quantified: rc=$RC out='$OUT' err='$ERR'"

echo "[6] override.rationale length"
R6="$ROOT/r6"; mkrepo "$R6" "$BASE"
add_after "$R6/docs/PRD.md" '- None yet.' '- "FR-2 has two readings" — overridden: ok'
lint "$R6"
[ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qE "major override\.rationale: " \
  && ok "[6] rationale 'ok' → major override.rationale, rc 1" || bad "[6] short: rc=$RC out='$OUT' err='$ERR'"
R6b="$ROOT/r6b"; mkrepo "$R6b" "$BASE"
add_after "$R6b/docs/PRD.md" '- None yet.' '- "FR-2 has two readings" — overridden: CSV is the only export format.'
lint "$R6b"
[ "$RC" -eq 0 ] && hasnt "$OUT" "override.rationale" \
  && ok "[6] a 30-character rationale → no finding, rc 0" || bad "[6] ok-length: rc=$RC out='$OUT' err='$ERR'"

echo "[7] no python3 → rc 3"
NP="$ROOT/nopy"; mkdir -p "$NP"
for t in git mktemp rm cat dirname grep sed head tr wc cut printf env; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NP/$t"
done
PLPATH="$NP" lint "$R2"
[ "$RC" -eq 3 ] && has "$ALL" "prd-lint: python3 required" \
  && ok "[7] PATH without python3 → 'prd-lint: python3 required', rc 3" || bad "[7] rc=$RC out='$OUT' err='$ERR'"
PLPATH="$NP" delta "$R2"
[ "$RC" -eq 3 ] && has "$ALL" "prd-lint: python3 required" \
  && ok "[7] tl_prd_delta without python3 → rc 3" || bad "[7] delta rc=$RC out='$OUT' err='$ERR'"

echo "[9] parse_requirements refactor: tl_ux_ui_reqs byte-identical"
OLD="$ROOT/old/ux_record.py"; mkdir -p "$ROOT/old"
if git -C "$REPO" show "$PRE_REFACTOR:scripts/lib/ux_record.py" >"$OLD" 2>/dev/null && [ -s "$OLD" ]; then
  FX="$ROOT/fx"; mkdir -p "$FX"
  cat >"$FX/a.md" <<'EOF'
# T
- **FR-1 [UI] Login.** body
Prose mentions the `[UI]` marker and ``a [UI] b`` too.
```
**FR-9 [UI] Fenced.**
```
**R-7 [UI] Cart** body
EOF
  printf '%s\n' '- **FR-3 [UI] Use `x` here.** b' '  more   ' '## H' 'tail' >"$FX/b.md"
  cat >"$FX/c.md" <<'EOF'
# P
## Requirements
- **FR-1 [UI] Login.** The user logs in.
  Details here.
- **FR-2 API.** Not UI.
- **FR-55 [UI] Panel.** body
- **FR-56** *Retired.* gone
- **FR-57 [UI] Other.** x
## Constraints
- **COVID-19 [UI] policy.** odd but parsed
EOF
  cp "$REPO/docs/PRD.md" "$FX/repo-prd.md"
  allsame=1
  for f in "$FX"/*.md; do
    o="$(python3 -I -B "$OLD" ui-reqs "$f" 2>&1; echo "rc=$?")"
    n="$(python3 -I -B "$UXR" ui-reqs "$f" 2>&1; echo "rc=$?")"
    if [ "$o" = "$n" ] && [ -n "$o" ]; then :; else allsame=0; bad "[9] ui-reqs differs on $(basename "$f"): old='$o' new='$n'"; fi
    o="$(python3 -I -B "$OLD" delta "$f" "$ROOT/none.json" 2>&1; echo "rc=$?")"
    n="$(python3 -I -B "$UXR" delta "$f" "$ROOT/none.json" 2>&1; echo "rc=$?")"
    [ "$o" = "$n" ] || { allsame=0; bad "[9] delta differs on $(basename "$f")"; }
  done
  printf '%s\n' '- **FR-1 [UI Login.** x' >"$FX/bad.md"
  o="$(python3 -I -B "$OLD" ui-reqs "$FX/bad.md" 2>&1; echo "rc=$?")"
  n="$(python3 -I -B "$UXR" ui-reqs "$FX/bad.md" 2>&1; echo "rc=$?")"
  [ "$o" = "$n" ] || { allsame=0; bad "[9] malformed-marker error differs: old='$o' new='$n'"; }
  [ "$allsame" -eq 1 ] && ok "[9] ui-reqs + delta output byte-identical to $PRE_REFACTOR on fixtures and this repo's PRD"
  grep -q '^def parse_requirements(' "$UXR" && ok "[9] ux_record.py exposes parse_requirements" \
    || bad "[9] ux_record.py has no parse_requirements"
  pr="$(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import ux_record as u
for r in u.parse_requirements(sys.argv[2]): print("%s|%d|%s" % (r[0], r[1], r[3]))' "$REPO/scripts/lib" "$FX/c.md" 2>&1)"
  [ "$pr" = "FR-1|3|- **FR-1 [UI] Login.** The user logs in.
FR-2|5|- **FR-2 API.** Not UI.
FR-55|6|- **FR-55 [UI] Panel.** body
FR-57|8|- **FR-57 [UI] Other.** x
COVID-19|10|- **COVID-19 [UI] policy.** odd but parsed" ] \
    && ok "[9] parse_requirements → (id, title line, block, title text) for every title, file order" \
    || bad "[9] parse_requirements: '$pr'"
else
  bad "infra: cannot read $PRE_REFACTOR:scripts/lib/ux_record.py (need full history)"
fi

echo "[9b] hyphenated bold bullets are not ids"
R9="$ROOT/r9"; mkrepo "$R9" "$BASE"
add_after "$R9/docs/PRD.md" '### Core' '- **Auto-merging** is never done.' '- **Cross-vendor review** is optional.'
lint "$R9"
[ "$RC" -eq 0 ] && hasnt "$OUT" "id.malformed" \
  && ok "[9b] **Auto-merging** / **Cross-vendor review** → no id.malformed" || bad "[9b] rc=$RC out='$OUT' err='$ERR'"
R9b="$ROOT/r9b"; mkrepo "$R9b" "$BASE"
add_after "$R9b/docs/PRD.md" '### Core' '- **FR-1a Variant.** x — Acceptance: `x` prints `y`.'
lint "$R9b"
[ "$RC" -eq 1 ] && has "$OUT" "id.malformed" \
  && ok "[9b] **FR-1a …** → id.malformed" || bad "[9b] FR-1a: rc=$RC out='$OUT' err='$ERR'"
# Retired markers: never malformed, and editing one never marks its neighbour changed.
B9r="$ROOT/base9r.md"; cp "$BASE" "$B9r"
add_after "$B9r" '`out.csv`.' '- **FR-56** *Retired.* Old text.'
R9r="$ROOT/r9r"; mkrepo "$R9r" "$B9r"
sed -i 's/Old text\./Older text, reworded./' "$R9r/docs/PRD.md"
add_after "$R9r/docs/PRD.md" 'Older text' '- **FR-57** *Retired.*'
lint "$R9r"; lo="$OUT"; lrc="$RC"
delta "$R9r"
[ "$lrc" -eq 0 ] && hasnt "$lo" "id.malformed" && [ -z "$OUT" ] && [ "$RC" -eq 0 ] \
  && ok "[9b] retired-marker lines: no id.malformed; editing one leaves FR-2 unchanged" \
  || bad "[9b] retired: lint rc=$lrc '$lo'; delta rc=$RC '$OUT' err='$ERR'"

echo "[9c] unparseable base → treated as none, never rc 2"
B9c="$ROOT/base9c.md"; cp "$BASE" "$B9c"; printf '%s\n' '```' 'unterminated' >>"$B9c"
R9c="$ROOT/r9c"; mkrepo "$R9c" "$B9c"; cp "$BASE" "$R9c/docs/PRD.md"
lint "$R9c"
{ [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ]; } && has "$OUT" "prd-lint: base unparseable (" \
  && has "$OUT" "); every requirement is new" && has "$OUT" "prd-lint: delta 2 requirements" \
  && ok "[9c] 'prd-lint: base unparseable (…); every requirement is new', rc $RC" \
  || bad "[9c] rc=$RC out='$OUT' err='$ERR'"
delta "$R9c"
[ "$RC" -eq 0 ] && [ "$OUT" = "new${TAB}FR-1"$'\n'"new${TAB}FR-2" ] \
  && ok "[9c] delta treats the unparseable base as none" || bad "[9c] delta rc=$RC out='$OUT' err='$ERR'"

echo "[14] this repo's PRD lints rc 0 against its own integration base"
if [ -r "$REPO/docs/PRD.md" ] && git -C "$REPO" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  pl "$REPO" "tl_prd_lint $(q "$REPO")"
  [ "$RC" -eq 0 ] && has "$OUT" "prd-lint: base " && hasnt "$OUT" " major " \
    && ok "[14] docs/PRD.md → rc 0, no major finding" || bad "[14] rc=$RC out='$OUT' err='$ERR'"
  # The PRD as a whole (no base, not degraded) still holds no duplicate or
  # malformed id and no empty section: retired-marker lines are recognised.
  ( cd "$REPO" && python3 -I -B scripts/lib/prd_lint.py check docs/PRD.md none ) >"$ROOT/o14" 2>&1
  grep -qF 'prd-lint: delta ' "$ROOT/o14" && ! grep -qE 'id\.(duplicate|malformed)|empty section' "$ROOT/o14" \
    && ok "[14] whole PRD: no id.duplicate / id.malformed / empty section (retired lines recognised)" \
    || bad "[14] whole-PRD check: $(head -5 "$ROOT/o14" 2>/dev/null)"
else
  bad "infra: $REPO/docs/PRD.md unreadable or $REPO is not a git repo"
fi

echo "[15] degrade paths: outside git, no integration branch, no commits"
R15="$ROOT/r15"; mkdir -p "$R15/docs"; cp "$BASE" "$R15/docs/PRD.md"
lint "$R15"
[ "$RC" -ne 2 ] && has "$OUT" "prd-lint: no base (not a git work tree); every requirement is new" \
  && has "$OUT" "prd-lint: base none" && has "$OUT" "prd-lint: delta 2 requirements" \
  && ok "[15] outside git → no-base line, still lints (rc $RC)" || bad "[15] no git: rc=$RC out='$OUT' err='$ERR'"
R15b="$ROOT/r15b"; mkdir -p "$R15b/docs"; G -C "$R15b" init -q -b feature
cp "$BASE" "$R15b/docs/PRD.md"; G -C "$R15b" add -A; G -C "$R15b" commit -qm f
add_after "$R15b/docs/PRD.md" '`out.csv`.' "$FR3_OK"
lint "$R15b"
[ "$RC" -eq 0 ] && has "$OUT" "prd-lint: base is HEAD (no integration branch)" \
  && has "$OUT" "prd-lint: delta 1 requirements" \
  && ok "[15] only branch 'feature' → 'base is HEAD (no integration branch)', delta 1" \
  || bad "[15] HEAD: rc=$RC out='$OUT' err='$ERR'"
R15c="$ROOT/r15c"; mkdir -p "$R15c/docs"; G -C "$R15c" init -q; cp "$BASE" "$R15c/docs/PRD.md"
lint "$R15c"
[ "$RC" -ne 2 ] && has "$OUT" "prd-lint: no base (no commits); every requirement is new" \
  && hasnt "$OUT" "base is HEAD" \
  && ok "[15] fresh git init → no-commits line (rc $RC)" || bad "[15] no commits: rc=$RC out='$OUT' err='$ERR'"

echo "[16] a parent heading is not an empty section"
R16="$ROOT/r16"; mkrepo "$R16" -
cat >"$R16/docs/PRD.md" <<'EOF'
# P

## Requirements
### Setup
- **FR-1 Login.** x — Acceptance: `login` prints `ok`.
### Empty
### Next
- **FR-2 Out.** y — Acceptance: `out` prints `ok`.
EOF
lint "$R16"
c="$(printf '%s\n' "$OUT" | grep -c ' placeholder: ')"
n="$(lineof "$R16/docs/PRD.md" '### Empty')"
[ "$c" -eq 1 ] && printf '%s\n' "$OUT" | grep -qE "^docs/PRD\.md:${n} major placeholder: " \
  && ok "[16] ## Requirements → ### Setup: none; ### Empty → ### Next: exactly one" \
  || bad "[16] count=$c out='$OUT' err='$ERR'"

echo "[17] a real git failure is rc 2"
GS="$ROOT/gitstub"; mkdir -p "$GS"; REALGIT="$(command -v git)"
cat >"$GS/git" <<EOF
#!$BASH_BIN
for a in "\$@"; do [ "\$a" = ls-tree ] && { echo "fatal: stub" >&2; exit 128; }; done
exec $(q "$REALGIT") "\$@"
EOF
chmod +x "$GS/git"
PLPATH="$GS:$PATH" lint "$R2"
[ "$RC" -eq 2 ] && has "$ALL" "prd-lint: git ls-tree failed (rc 128)" \
  && ok "[17] ls-tree exits 128 → 'prd-lint: git ls-tree failed (rc 128)', rc 2" || bad "[17] rc=$RC out='$OUT' err='$ERR'"

echo "[19] requirements-section scoping and degraded strictness"
R19="$ROOT/r19"; mkrepo "$R19" "$BASE"
add_after "$R19/docs/PRD.md" '- Linux only.' '- **COVID-19 policy.** Offices may close.'
lint "$R19"
[ "$RC" -eq 0 ] && hasnt "$OUT" "acceptance.missing" && hasnt "$OUT" "COVID-19" \
  && ok "[19] new **COVID-19 policy.** under Constraints → not a requirement" || bad "[19] covid: rc=$RC out='$OUT' err='$ERR'"
delta "$R19"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "[19] … and not in the delta" || bad "[19] covid delta: '$OUT'"
R19b="$ROOT/r19b"; mkrepo "$R19b" "$BASE"; sed -i 's/^## Requirements$/## Wants/' "$R19b/docs/PRD.md"
lint "$R19b"
c="$(printf '%s\n' "$OUT" | grep -c 'major placeholder: no ## Requirements section')"
[ "$RC" -eq 1 ] && [ "$c" -eq 1 ] && ok "[19] no ## Requirements → exactly one major placeholder" \
  || bad "[19] no-req: rc=$RC out='$OUT' err='$ERR'"
R19c="$ROOT/r19c"; mkdir -p "$R19c/docs"; cp "$B2" "$R19c/docs/PRD.md"
lint "$R19c"
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qE "info acceptance\.missing: .*FR-1" \
  && hasnt "$OUT" "major acceptance.missing" \
  && ok "[19] outside git, legacy FR-1 without acceptance → info acceptance.missing, rc 0" \
  || bad "[19] degraded: rc=$RC out='$OUT' err='$ERR'"

echo "[rc2] internal and parse errors"
R20="$ROOT/r20"; mkrepo "$R20" "$BASE"; printf '%s\n' '```' >>"$R20/docs/PRD.md"
lint "$R20"
[ "$RC" -eq 2 ] && has "$ERR" "prd-lint: " && ok "[rc2] unterminated fence in the PRD itself → rc 2 with a prd-lint: line" \
  || bad "[rc2] rc=$RC out='$OUT' err='$ERR'"
pl "$ROOT" "tl_prd_lint"
[ "$RC" -eq 2 ] && has "$ERR" "usage" && ok "[rc2] tl_prd_lint without a repo root → usage, rc 2" \
  || bad "[rc2] usage: rc=$RC err='$ERR'"

echo "[S1] relative sourcing never runs the linted repo's own prd_lint.py"
RS="$ROOT/rs1"; mkdir -p "$RS/docs" "$RS/scripts/lib"; git -C "$RS" init -q -b master
printf '# P\n\n## Requirements\n- **FR-1 A.** x. — Acceptance: `a` prints `b`.\n' > "$RS/docs/PRD.md"
git -C "$RS" add -A; git -C "$RS" -c user.email=t@t.t -c user.name=t commit -qm base
printf 'import sys\nopen(sys.argv[0]+".pwned","w").write("x")\nprint("PLANTED")\n' > "$RS/scripts/lib/prd_lint.py"
LIBREL="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1]))' "$REPO/scripts/lib")"
out="$(cd "$REPO" && env -i HOME="$ROOT" PATH="$PATH" bash -c ". $LIBREL/prd-lint.sh && tl_prd_lint $(printf '%q' "$RS")" 2>&1)"
if [ ! -e "$RS/scripts/lib/prd_lint.py.pwned" ] && ! printf '%s' "$out" | grep -q PLANTED; then
  ok "[S1] relative source path: plugin's prd_lint.py used, planted one never runs"
else bad "[S1] planted prd_lint.py ran: out='$out'"; fi

echo
PASS="$(grep -c '^ok$' "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== prd-lint (TDD 0073): $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

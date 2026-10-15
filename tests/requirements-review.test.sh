#!/usr/bin/env bash
# requirements-review.test.sh — eval for TDD 0073 / FR-102, FR-103, FR-104,
# FR-105, FR-110, FR-87: the /prd-author requirements-review step.
#
# Observation 8: EXTRACTS the first fenced bash block after
# `<!-- tl:prd-lint -->` (skills/prd-author/SKILL.md) and RUNS it the way the
# harness does — a fresh shell, nothing pre-sourced, inputs from env only:
#   env -i HOME=<tmp> PATH=<path> CLAUDE_PLUGIN_ROOT=<repo> TL_REPO=<fixture> bash <block>
# against a temp git repo (`master` holds the base docs/PRD.md).
# Observations 13 and 18 are text checks by necessity: the reviewer and the
# interview are model prose, so the contract is the prompt / skill text (the
# reviewer's behaviour is observed by parent-dispatched fixtures, obs 10–12).
# A missing marker, block or file is a FAIL (L-001), never a skip; every
# negated grep first asserts its file is readable (L-001/L-011); every temp dir
# is trap-cleaned (L-004).
#
# Written red-first. Run: bash tests/requirements-review.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/prd-author/SKILL.md"
AGENT="$REPO/agents/requirements-reviewer.md"
RESULTS=""; ROOT=""
cleanup() { [ -n "$ROOT" ] && rm -rf "$ROOT"; [ -n "$RESULTS" ] && rm -f "$RESULTS"; }
trap cleanup EXIT
RESULTS="$(mktemp)"; export RESULTS
ROOT="$(mktemp -d)"
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
readable() { [ -r "$1" ] && [ -s "$1" ]; }
H="$ROOT/home"; mkdir -p "$H"
BASH_BIN="$(command -v bash)"
TAB="$(printf '\t')"
command -v python3 >/dev/null 2>&1 || bad "infra: python3 not found"
G() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=master -c commit.gpgsign=false "$@"; }

# extract <file> <marker-name> <out> — first ```bash block after `<!-- tl:<name> -->`.
# rc 0 ok | 10 file unreadable | 3 no marker | 4 no block | 5 unclosed | 6 empty.
extract() {
  readable "$1" || return 10
  awk -v M="<!-- tl:$2 -->" '
    !seen && $0 == M                    { seen = 1; next }
    seen && !open && /^```bash[ \t]*$/  { open = 1; next }
    open && /^```[ \t]*$/               { closed = 1; exit }
    open                                { print }
    END { if (!seen) exit 3; if (!open) exit 4; if (!closed) exit 5 }
  ' "$1" >"$3" || return $?
  [ -s "$3" ] || return 6
}

echo "[8] tl:prd-lint block"
BLK="$ROOT/prd-lint.sh"; extract "$SKILL" prd-lint "$BLK"; rc=$?
case "$rc" in
  0)  ok "[8] tl:prd-lint extracted" ;;
  10) bad "infra: $SKILL missing/unreadable/empty"; BLK="" ;;
  3)  bad "[8] marker <!-- tl:prd-lint --> not found in $SKILL"; BLK="" ;;
  4)  bad "[8] no fenced bash block after tl:prd-lint"; BLK="" ;;
  5)  bad "[8] the block after tl:prd-lint is never closed"; BLK="" ;;
  *)  bad "[8] extractor rc=$rc"; BLK="" ;;
esac

# runb <cwd> [VAR=val …] — run the extracted block under env -i; sets OUT ERR RC.
runb() {
  local cwd="$1"; shift
  if [ -z "$BLK" ]; then OUT=""; ERR="no block"; RC=99; return; fi
  ( cd "$cwd" && exec env -i HOME="$H" PATH="$PATH" CLAUDE_PLUGIN_ROOT="$REPO" "$@" \
      "$BASH_BIN" "$BLK" ) >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"
}

# The observation-2 fixture: master holds FR-1 (no acceptance clause, legacy),
# the working tree adds FR-3 with no acceptance clause.
R="$ROOT/r"; mkdir -p "$R/docs"
cat >"$R/docs/PRD.md" <<'EOF'
# Product Requirements: Demo

## Problem & context
People need a demo.

## Requirements
- **FR-1 Login.** The user logs in.
- **FR-2 Export.** The user exports a CSV. — Acceptance: `export` writes `out.csv`.

## Open questions
- None yet.
EOF
G -C "$R" init -q && G -C "$R" add -A && G -C "$R" commit -qm base
printf '%s\n' '- **FR-3 Import.** The user imports a CSV file from disk.' >"$ROOT/fr3"
python3 -I -c 'import sys
p = sys.argv[1]; ls = open(p).read().split("\n")
i = next(n for n, l in enumerate(ls) if "FR-2 Export" in l); ls.insert(i + 1, open(sys.argv[2]).read().rstrip("\n"))
open(p, "w").write("\n".join(ls))' "$R/docs/PRD.md" "$ROOT/fr3"

runb "$R" TL_REPO="$R"
[ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qE '^docs/PRD\.md:[0-9]+ major acceptance\.missing: .*FR-3' \
  && printf '%s\n' "$OUT" | grep -qF 'prd-lint: base master' \
  && printf '%s\n' "$OUT" | grep -qx "new${TAB}FR-3" \
  && ok "[8] obs-2 fixture under env -i → rc 1, the lint findings AND the delta line printed" \
  || bad "[8] rc=$RC out='$OUT' err='$ERR'"
runb "$R"
[ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qF 'TL_REPO' \
  && ok "[8] TL_REPO unset → rc $RC naming TL_REPO" || bad "[8] unset: rc=$RC err='$ERR'"
runb "$R" TL_REPO="$R" CLAUDE_PLUGIN_ROOT="$ROOT/nope"
[ -n "$BLK" ] && [ "$RC" -ne 0 ] && [ -n "$ERR" ] && ok "[8] unresolvable plugin root → fails loud (rc $RC)" \
  || bad "[8] bad root: rc=$RC err='$ERR'"
# Clean fixture: FR-3 gains its acceptance clause → rc 0, delta still printed.
sed -i 's/^- \*\*FR-3 Import\.\*\* The user imports a CSV file from disk\.$/& — Acceptance: `import a.csv` prints `3 rows`./' "$R/docs/PRD.md"
runb "$R" TL_REPO="$R"
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx "new${TAB}FR-3" \
  && printf '%s\n' "$OUT" | grep -qF 'prd-lint: delta 1 requirements, 0 major' \
  && ok "[8] clean delta → rc 0 with the delta line" || bad "[8] clean: rc=$RC out='$OUT' err='$ERR'"

echo "[13] requirements-reviewer contract"
if readable "$AGENT"; then
  fm="$(awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f' "$AGENT")"
  printf '%s\n' "$fm" | grep -qx 'name: requirements-reviewer' && ok "[13] name: requirements-reviewer" || bad "[13] name missing"
  printf '%s\n' "$fm" | grep -qx 'model: inherit' && ok "[13] model: inherit (FR-87)" || bad "[13] model: inherit missing"
  printf '%s\n' "$fm" | grep -qx 'tools: Read, Grep, Glob, Bash' && ok "[13] tools: Read, Grep, Glob, Bash" || bad "[13] tools line"
  for s in 'REQUIREMENTS_REVIEW: PASS' 'REQUIREMENTS_REVIEW: BLOCK <one-line reason>' \
           'R-n <severity> — docs/PRD.md:<line> — <finding>' \
           '- "<finding>" — overridden: <rationale>' \
           'R-n blocker — docs/PRD.md:<line> — override rejected: "<finding>"' \
           '### Non-findings' '<label> — "<quoted candidate finding>" — <why set aside>' \
           'pedantic escalation' 'imaginary architecture' \
           'report-file path given in the dispatch' 'overridden' \
           'necessary' 'unambiguous' 'complete' 'singular' 'feasible' 'verifiable' \
           'product owner' 'implementer' 'tester' 'stakeholder' \
           'Evaluation rubric' 'terminology drift' 'contradiction' 'duplication' \
           'blocker, major, minor or nit' 'Do not spawn'; do
    grep -qF -- "$s" "$AGENT" && ok "[13] contains: $s" || bad "[13] missing: $s"
  done
  last="$(grep -nF 'REQUIREMENTS_REVIEW:' "$AGENT" | wc -l)"
  [ "$last" -ge 2 ] && ok "[13] both verdict tokens present" || bad "[13] verdict tokens: $last"
  # FR-110: no rule dismisses a category of finding.
  if grep -qiE 'synchronous hand-wringing|harmless idempotence|ignore races?|dismiss race|not a real race|single-threaded so no race|idempotent so safe' "$AGENT"; then
    bad "[13] a category-dismissal phrase is present"
  else
    ok "[13] no category-dismissal phrase (file readable)"
  fi
  grep -qiF 'never dismiss' "$AGENT" && ok "[13] states it never dismisses a category by rule" \
    || bad "[13] no-category-dismissal sentence missing"
else
  bad "infra: $AGENT missing/unreadable/empty"
fi

echo "[18] /prd-author skill text"
if readable "$SKILL"; then
  for s in 'functional scope' 'domain and data' 'interaction and flow' 'non-functional qualities' \
           'integrations and dependencies' 'edge cases and failure handling' \
           'constraints and trade-offs' 'terminology' 'completion signals' \
           'coverage: <category>' 'initial <status>; final <status>;' \
           '## Coverage scan' '## Requirements review' \
           '"<finding>" — overridden: <rationale>' \
           'agents/requirements-reviewer.md' 'mktemp' 'never recorded' \
           'Pre-pass unavailable: python3 required' 'REQUIREMENTS_REVIEW: PASS' \
           'no model parameter' 'last line'; do
    grep -qF -- "$s" "$SKILL" && ok "[18] contains: $s" || bad "[18] missing: $s"
  done
  # The review step sits after tl:ui-markers and before the Git phase gate.
  a="$(grep -nxF '<!-- tl:ui-markers -->' "$SKILL" | head -1 | cut -d: -f1)"
  b="$(grep -nxF '<!-- tl:prd-lint -->' "$SKILL" | head -1 | cut -d: -f1)"
  c="$(grep -nx '## Git (phase gate)' "$SKILL" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] \
    && ok "[18] tl:prd-lint sits after tl:ui-markers and before the Git phase gate" \
    || bad "[18] order: ui-markers=$a prd-lint=$b git=$c"
else
  bad "infra: $SKILL missing/unreadable/empty"
fi

echo
PASS="$(grep -c '^ok$' "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== requirements-review (TDD 0073): $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

#!/usr/bin/env bash
# gitignore-helper.test.sh — eval for TDD 0009 / FR-32: pins the contract of
# scripts/lib/gitignore.sh::tl_gitignore_add_line.
#
# Written red-first: scripts/lib/gitignore.sh does not exist before TDD 0009,
# so [A] fails on `bash -n` and the behavioral cases error out.
#
# Contract: ensure the repo-root .gitignore contains an EXACT-match line;
# create the file if absent; idempotent + byte-stable on re-run; effective
# coverage is what matters (validated with `git check-ignore`).
#
# Run: bash tests/gitignore-helper.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib/gitignore.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mkrepo() { local d="$1"; mkdir -p "$d"; git -C "$d" init -q; printf '%s\n' "$d"; }
LINE="docs/tdd/.implement-logs/"

# --- [A] gitignore.sh parses + sources standalone ----------------------------
echo "[A] gitignore.sh parses + sources in isolation"
( bash -n "$LIB" 2>"$ROOT/A.err" \
    && ok "gitignore.sh parses (bash -n)" \
    || bad "gitignore.sh failed bash -n: $(cat "$ROOT/A.err" 2>/dev/null)"
  if bash -c "set -uo pipefail; source \"$LIB\"; type -t tl_gitignore_add_line >/dev/null" 2>"$ROOT/A2.err"; then
    ok "gitignore.sh sources standalone and binds tl_gitignore_add_line"
  else
    bad "gitignore.sh failed to source standalone: $(cat "$ROOT/A2.err" 2>/dev/null)"
  fi
) || true

# --- [B] creates .gitignore when absent and ignores the path -----------------
echo "[B] creates .gitignore from scratch and ignores the path"
( R="$(mkrepo "$ROOT/b")"
  ( cd "$R" && source "$LIB" && tl_gitignore_add_line "$LINE" )
  if [ -f "$R/.gitignore" ] && grep -Fxq "$LINE" "$R/.gitignore"; then
    ok ".gitignore created with the exact line"
  else
    bad ".gitignore missing the exact line after add"
  fi
  if ( cd "$R" && git check-ignore -q docs/tdd/.implement-logs/x.log ); then
    ok "git check-ignore confirms the path is ignored"
  else
    bad "git check-ignore did NOT ignore the path"
  fi
) || true

# --- [C] idempotent + byte-stable on re-run ----------------------------------
echo "[C] re-running leaves .gitignore byte-identical (no duplicate line)"
( R="$(mkrepo "$ROOT/c")"
  ( cd "$R" && source "$LIB" && tl_gitignore_add_line "$LINE" )
  cp "$R/.gitignore" "$ROOT/c.first"
  ( cd "$R" && source "$LIB" && tl_gitignore_add_line "$LINE" )
  if cmp -s "$ROOT/c.first" "$R/.gitignore"; then
    ok ".gitignore byte-identical after a second add"
  else
    bad ".gitignore changed on re-run (not idempotent)"
  fi
  count="$(grep -Fxc "$LINE" "$R/.gitignore")"
  [ "$count" = "1" ] && ok "exact line appears exactly once" \
                     || bad "exact line appears $count times (expected 1)"
) || true

# --- [D] preserves pre-existing content; no merge into a no-newline tail ------
echo "[D] appends cleanly onto an existing newline-terminated .gitignore"
( R="$(mkrepo "$ROOT/d")"
  printf 'node_modules/\n*.tmp\n' > "$R/.gitignore"
  ( cd "$R" && source "$LIB" && tl_gitignore_add_line "$LINE" )
  if grep -Fxq 'node_modules/' "$R/.gitignore" \
     && grep -Fxq '*.tmp' "$R/.gitignore" \
     && grep -Fxq "$LINE" "$R/.gitignore"; then
    ok "existing entries preserved and new line added"
  else
    bad "existing entries clobbered or new line missing"
  fi
) || true

# --- [E] a file with NO trailing newline does not get its last line mangled --
echo "[E] handles an existing .gitignore lacking a trailing newline"
( R="$(mkrepo "$ROOT/e")"
  printf 'build/' > "$R/.gitignore"   # deliberately no trailing newline
  ( cd "$R" && source "$LIB" && tl_gitignore_add_line "$LINE" )
  if grep -Fxq 'build/' "$R/.gitignore" && grep -Fxq "$LINE" "$R/.gitignore"; then
    ok "the prior 'build/' line stayed intact (no 'build/docs/...' merge)"
  else
    bad "the no-newline tail was mangled (got: $(tr '\n' '|' < "$R/.gitignore"))"
  fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== gitignore-helper eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

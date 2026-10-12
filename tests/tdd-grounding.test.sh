#!/usr/bin/env bash
# tdd-grounding.test.sh — eval for TDD 0074 / FR-106, FR-107: tdd-lint's
# workspace grounding (`tl_lint_grounding`, `grounding.missing` /
# `grounding.invalid`), the `md_bullet_path … marked` mode, and the
# deferred-discovery phrases (`placeholder.deferred_discovery`).
#
# Observation points 1–10 of the TDD's Verification plan. The lint runs in a
# clean `env -i` shell against temp git repos whose `master` holds some files
# and a merged TDD, with the new TDD uncommitted in the working tree. A missing
# file is a FAIL (L-001), every negated check first asserts its input is
# non-empty (L-001/L-011), every temp dir is trap-cleaned (L-004).
#
# Written red-first. Run: bash tests/tdd-grounding.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
LINT="$REPO/scripts/lib/tdd-lint.sh"
MD="$REPO/scripts/lib/md.sh"
# The pre-0074 tdd-lint / md.sh live at this commit (TDD 0074's base).
BASE_REV=4f217b3
RESULTS=""; ROOT=""
cleanup() { [ -n "$ROOT" ] && rm -rf "$ROOT"; [ -n "$RESULTS" ] && rm -f "$RESULTS"; }
trap cleanup EXIT
RESULTS="$(mktemp)"; export RESULTS
ROOT="$(mktemp -d)"; ROOT="$(cd "$ROOT" && pwd -P)"
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
q() { printf '%q' "$1"; }
H="$ROOT/home"; mkdir -p "$H"
BASH_BIN="$(command -v bash)"
TAB="$(printf '\t')"
[ -r "$LINT" ] || bad "infra: $LINT missing/unreadable"
[ -r "$MD" ]   || bad "infra: $MD missing/unreadable"
G() { git -c user.name=t -c user.email=t@t -c init.defaultBranch="${GBR:-master}" -c commit.gpgsign=false "$@"; }

# run <dir> '<cmds>' — run <cmds> in a clean shell in <dir>. Sets OUT ERR RC;
# ALL = stdout+stderr. THROUGHLINE_INTEGRATION_BRANCH is never inherited.
run() {
  local d="$1" c="$2"
  ( cd "$d" && exec env -i HOME="$H" PATH="${LPATH:-$PATH}" GIT_CEILING_DIRECTORIES="$ROOT" \
      "$BASH_BIN" -c "$c" ) >"$ROOT/out" 2>"$ROOT/err"
  RC=$?; OUT="$(cat "$ROOT/out")"; ERR="$(cat "$ROOT/err")"; ALL="$OUT"$'\n'"$ERR"
}
lint() { local d="$1"; shift; local a="" x; for x in "$@"; do a="$a $(q "$x")"; done
  run "$d" "bash $(q "$LINT")$a"; }
# has <text> <fixed-string> — non-empty input that contains the string.
has()   { [ -n "$1" ] && printf '%s\n' "$1" | grep -qF -- "$2"; }
# hasnt <text> <fixed-string> — non-empty (readable) input without it.
hasnt() { [ -n "$1" ] && ! printf '%s\n' "$1" | grep -qF -- "$2"; }

# mk_tdd <path> <prose> <touched-bullet>... — a structurally complete TDD.
mk_tdd() {
  local p="$1" prose="$2"; shift 2
  mkdir -p "$(dirname "$p")"
  {
    printf '# TDD 9001: fixture\nStatus: draft\nPRD refs: FR-1\nPRD-rev: deadbee\n\n'
    printf '## Approach\nA small change.\n%s\n\n' "$prose"
    printf '## Verification plan\nRun the CLI and observe exit code 0.\n\n'
    printf '## Requirement traceability\n| PRD | Design |\n|---|---|\n| FR-1 | the change |\n\n'
    printf '## Dependencies considered\nNone.\n\n## Touched files\n'
    local b; for b in "$@"; do printf -- '- %s\n' "$b"; done
    printf '\n## Expected diff size\n- `x` — 10 lines\n\nTotal expected diff: 10 lines across 1 file.\n'
  } >"$p"
}

# mkrepo <dir> — `master` holds scripts/lib/real.sh, docs/ux/screens/login/,
# and a merged TDD (0001) whose Touched files list an unmarked missing path.
mkrepo() {
  local d="$1"
  mkdir -p "$d/scripts/lib" "$d/docs/ux/screens/login"
  G -C "$d" init -q
  echo 'real' >"$d/scripts/lib/real.sh"
  echo '<html></html>' >"$d/docs/ux/screens/login/index.html"
  mk_tdd "$d/docs/tdd/0001-merged.md" "" '`scripts/lib/nope.sh` — merged long ago'
  G -C "$d" add -A && G -C "$d" commit -qm base
}

R="$ROOT/repo"; mkrepo "$R"
NEW="$R/docs/tdd/0002-new.md"

echo "TDD 0074 — tdd-lint grounding + no deferred discovery"

# --- 1. Missing path --------------------------------------------------------
mk_tdd "$NEW" "" '`scripts/lib/nope.sh` — x'
lint "$R" "$NEW"
if [ "$RC" -eq 1 ] && has "$OUT" "major grounding.missing:" \
   && has "$OUT" "scripts/lib/nope.sh" \
   && printf '%s\n' "$OUT" | grep 'grounding.missing' | grep -qF 'master'; then
  ok "obs1: unmarked missing path → rc 1, major grounding.missing naming the path and master"
else bad "obs1: missing path (rc=$RC) out=[$OUT] err=[$ERR]"; fi
lint "$R" docs/tdd/0002-new.md
if [ "$RC" -eq 1 ] && has "$OUT" "grounding.missing"; then
  ok "obs1: same finding with a relative TDD path from the repo root"
else bad "obs1: relative path (rc=$RC) out=[$OUT] err=[$ERR]"; fi

# --- 2. Marked --------------------------------------------------------------
mk_tdd "$NEW" "" '`scripts/lib/nope.sh` (new) — x' 'scripts/lib/bare.sh (new) — bare path'
lint "$R" "$NEW"
if [ "$RC" -eq 0 ] && hasnt "$OUT$ERR." "grounding."; then
  ok "obs2: a path marked (new) (backticked or bare) → no finding"
else bad "obs2: marked (rc=$RC) out=[$OUT] err=[$ERR]"; fi
mk_tdd "$NEW" "" '`scripts/lib/nope.sh` — x (new) after the dash' '`scripts/lib/nope2.sh` (newer) — x'
lint "$R" "$NEW"
if [ "$RC" -eq 1 ] && has "$OUT" "scripts/lib/nope.sh is not on" && has "$OUT" "scripts/lib/nope2.sh is not on"; then
  ok "obs2: (new) after the em-dash, or a non-standalone (newer), is not a mark"
else bad "obs2: mark position (rc=$RC) out=[$OUT] err=[$ERR]"; fi

# --- 3. Existing ------------------------------------------------------------
mk_tdd "$NEW" "" '`scripts/lib/real.sh` — x' '`docs/ux/screens/login/` — a directory'
lint "$R" "$NEW"
if [ "$RC" -eq 0 ] && hasnt "$OUT$ERR." "grounding."; then
  ok "obs3: a file and a directory on master → no finding"
else bad "obs3: existing (rc=$RC) out=[$OUT] err=[$ERR]"; fi
echo wt >"$R/scripts/lib/wt.sh"
mk_tdd "$NEW" "" '`scripts/lib/wt.sh` — only in the working tree'
lint "$R" "$NEW"
if [ "$RC" -eq 1 ] && has "$OUT" "scripts/lib/wt.sh is not on master"; then
  ok "obs3: a working-tree-only unmarked path → finding (checks master, not the disk)"
else bad "obs3: working tree only (rc=$RC) out=[$OUT] err=[$ERR]"; fi
rm -f "$R/scripts/lib/wt.sh"

# --- 4. Go-forward ----------------------------------------------------------
lint "$R" "$R/docs/tdd/0001-merged.md"
if [ "$RC" -eq 0 ] && hasnt "$OUT$ERR." "grounding."; then
  ok "obs4: a TDD already on master is exempt → rc 0, no finding"
else bad "obs4: merged TDD (rc=$RC) out=[$OUT] err=[$ERR]"; fi
mkdir -p "$R/sub"
lint "$R/sub" ../docs/tdd/0001-merged.md
if [ "$RC" -eq 0 ] && hasnt "$OUT$ERR." "grounding."; then
  ok "obs4: exempt also when linted from a subdirectory"
else bad "obs4: merged TDD from subdir (rc=$RC) out=[$OUT] err=[$ERR]"; fi
# A TDD committed on a feature branch only is still new.
F="$ROOT/feat"; mkrepo "$F"
G -C "$F" checkout -qb design
mk_tdd "$F/docs/tdd/0002-new.md" "" '`scripts/lib/nope.sh` — x'
G -C "$F" add -A && G -C "$F" commit -qm design
lint "$F" "$F/docs/tdd/0002-new.md"
if [ "$RC" -eq 1 ] && has "$OUT" "grounding.missing"; then
  ok "obs4: a TDD committed only on a design branch is still checked"
else bad "obs4: design-branch TDD (rc=$RC) out=[$OUT] err=[$ERR]"; fi
# Symlinked dir to the repo: the go-forward rule still finds it merged.
ln -s "$R" "$ROOT/link"
lint "$ROOT" "$ROOT/link/docs/tdd/0001-merged.md"
if [ "$RC" -eq 0 ] && hasnt "$OUT$ERR." "grounding."; then
  ok "obs4: merged TDD reached through a symlinked path stays exempt"
else bad "obs4: symlink (rc=$RC) out=[$OUT] err=[$ERR]"; fi

# --- 5. No integration ref / outside git ------------------------------------
N="$ROOT/noint"; GBR=feature mkrepo "$N"
mk_tdd "$N/docs/tdd/0002-new.md" "" '`scripts/lib/nope.sh` — x'
lint "$N" "$N/docs/tdd/0002-new.md"
if [ "$RC" -eq 1 ] && has "$OUT" "(checked against HEAD: no integration branch)" \
   && has "$OUT" "scripts/lib/nope.sh is not on HEAD"; then
  ok "obs5: no integration branch → HEAD, said in the finding"
else bad "obs5: no integration ref (rc=$RC) out=[$OUT] err=[$ERR]"; fi
O="$ROOT/outside"; mkdir -p "$O"
mk_tdd "$O/0002-new.md" "" '`scripts/lib/nope.sh` — x'
lint "$O" "$O/0002-new.md"
if [ "$RC" -eq 0 ] && has "$ERR" "tdd-lint: grounding skipped: " && has "$ERR" "is not in a git work tree" \
   && hasnt "$OUT." "grounding.missing"; then
  ok "obs5: outside git → rc 0 with the stderr skip line"
else bad "obs5: outside git (rc=$RC) out=[$OUT] err=[$ERR]"; fi

# --- 6. Deferred discovery --------------------------------------------------
mk_tdd "$NEW" "The build will locate the caller during implementation." '`scripts/lib/real.sh` — x'
lint "$R" "$NEW"
if [ "$RC" -eq 1 ] && has "$OUT" "major placeholder.deferred_discovery" && has "$OUT" "locate the caller"; then
  ok "obs6: FR-107 acceptance example → rc 1, deferred_discovery quoting the phrase"
else bad "obs6: deferred discovery (rc=$RC) out=[$OUT] err=[$ERR]"; fi
mk_tdd "$NEW" $'```\nThe build will locate the caller during implementation.\n```' '`scripts/lib/real.sh` — x'
lint "$R" "$NEW"
if [ "$RC" -eq 0 ] && hasnt "$OUT$ERR." "deferred_discovery"; then
  ok "obs6: the phrase inside a fence → no finding"
else bad "obs6: fenced (rc=$RC) out=[$OUT] err=[$ERR]"; fi
mk_tdd "$NEW" 'The doc quotes `locate the caller during implementation` as an example.' '`scripts/lib/real.sh` — x'
lint "$R" "$NEW"
if [ "$RC" -eq 0 ] && hasnt "$OUT$ERR." "deferred_discovery"; then
  ok "obs6: the phrase inside backticks → no finding"
else bad "obs6: backticked (rc=$RC) out=[$OUT] err=[$ERR]"; fi
mk_tdd "$NEW" 'The old list still bans `TBD` even in backticks.' '`scripts/lib/real.sh` — x'
lint "$R" "$NEW"
if [ "$RC" -eq 1 ] && has "$OUT" "placeholder.forbidden_phrase" && hasnt "$OUT" "deferred_discovery"; then
  ok "obs6: an old phrase inside backticks still fires (backtick skip is new-phrases only)"
else bad "obs6: old phrase in backticks (rc=$RC) out=[$OUT] err=[$ERR]"; fi
miss=""
for ph in "find the file" "search for the file" "locate the file" \
          "locate during implementation" "located during implementation" \
          "locate the caller" "search for callers" \
          "determined during implementation" "discover during implementation" \
          "figure out during implementation" "during implementation, find"; do
  up="$(printf '%s' "$ph" | tr '[:lower:]' '[:upper:]')"
  mk_tdd "$NEW" "Then we $up later." '`scripts/lib/real.sh` — x'
  lint "$R" "$NEW"
  { [ "$RC" -eq 1 ] && has "$OUT" "placeholder.deferred_discovery" && has "$OUT" "$ph"; } || miss="$miss [$ph rc=$RC]"
done
if [ -z "$miss" ]; then ok "obs6: every listed phrase fires, case-insensitively"
else bad "obs6: phrases not caught:$miss"; fi

# --- 7. Regression over this repo's TDDs ------------------------------------
B="$ROOT/base"; mkdir -p "$B"
if git -C "$REPO" archive "$BASE_REV" scripts/lib 2>/dev/null | tar -x -C "$B" 2>/dev/null \
   && [ -r "$B/scripts/lib/tdd-lint.sh" ]; then
  BL="$B/scripts/lib/tdd-lint.sh"
  run "$REPO" ". $(q "$REPO/scripts/lib/verdicts.sh") && _tl_integration_ref $(q "$REPO")"
  INTEG="$OUT"
  if [ "$RC" -ne 0 ] || [ -z "$INTEG" ]; then
    bad "obs7: infra: no integration ref resolvable in $REPO"
  else
    n=0; diffs=""; dd=""
    for t in "$REPO"/docs/tdd/0*.md; do
      rel="${t#"$REPO"/}"
      [ -n "$(git -C "$REPO" ls-tree "$INTEG" -- "$rel")" ] || continue
      n=$((n + 1))
      run "$REPO" "bash $(q "$BL") $(q "$rel")"; brc=$RC
      run "$REPO" "bash $(q "$LINT") $(q "$rel")"; nrc=$RC
      [ "$brc" = "$nrc" ] || diffs="$diffs [$rel base=$brc new=$nrc]"
      has "$OUT." "deferred_discovery" && dd="$dd [$rel]"
      has "$OUT." "grounding." && dd="$dd [$rel grounding]"
    done
    if [ "$n" -gt 0 ] && [ -z "$diffs" ] && [ -z "$dd" ]; then
      ok "obs7: $n merged TDDs: identical rc to the base tdd-lint, zero new findings"
    else bad "obs7: regression over $n TDDs: rc diffs:${diffs:- none} new findings:${dd:- none}"; fi
  fi
else
  bad "obs7: infra: cannot extract scripts/lib at $BASE_REV"
fi

# --- 8. The marked mode -----------------------------------------------------
M="$ROOT/m.md"
cat >"$M" <<'EOF'
## Touched files
- `a/one.sh` (new) — created
- `a/two.sh` — changed (new) in the purpose only
- a/three.sh (new) — bare marked
- a/four.sh — bare unmarked
- `a/five.sh` (post) (new) — two annotations
- `a/six.sh` (newer) — not the token
- `a/seven.sh` (new)
- just prose without a path?
```
- `fenced/no.sh` (new) — ignored
```
EOF
expect="a/one.sh${TAB}(new)
a/two.sh${TAB}-
a/three.sh${TAB}(new)
a/four.sh${TAB}-
a/five.sh${TAB}(new)
a/six.sh${TAB}-
a/seven.sh${TAB}(new)
just${TAB}-"
run "$ROOT" ". $(q "$MD") && md_bullet_path $(q "$M") 'Touched files' marked"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$expect" ]; then
  ok "obs8: marked mode prints <path>\\t(new)|- in bullet order"
else bad "obs8: marked mode (rc=$RC) out=[$OUT] expected=[$expect] err=[$ERR]"; fi
if [ -r "$B/scripts/lib/md.sh" ]; then
  pdiff=""
  for t in "$M" "$REPO"/docs/tdd/0*.md; do
    run "$ROOT" ". $(q "$B/scripts/lib/md.sh") && md_bullet_path $(q "$t") 'Touched files' paths"; bo="$OUT"; brc=$RC
    run "$ROOT" ". $(q "$MD") && md_bullet_path $(q "$t") 'Touched files' paths"
    { [ "$bo" = "$OUT" ] && [ "$brc" = "$RC" ]; } || pdiff="$pdiff [$t]"
  done
  if [ -z "$pdiff" ]; then ok "obs8: paths mode byte-identical to the base md.sh on every TDD"
  else bad "obs8: paths mode differs:$pdiff"; fi
else bad "obs8: infra: base md.sh missing"; fi

# --- 9. Helper failure / no commits -----------------------------------------
STUB="$ROOT/stub"; mkdir -p "$STUB"
REALGIT="$(command -v git)"
cat >"$STUB/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = ls-tree ] && exit 128; done
exec $(q "$REALGIT") "\$@"
EOF
chmod +x "$STUB/git"
mk_tdd "$NEW" "" '`scripts/lib/real.sh` — x'
LPATH="$STUB:$PATH" lint "$R" "$NEW"
if [ "$RC" -eq 2 ] && has "$ERR" "tdd-lint: grounding: git ls-tree failed"; then
  ok "obs9: ls-tree failing → rc 2 and a named error, never clean"
else bad "obs9: helper failure (rc=$RC) out=[$OUT] err=[$ERR]"; fi
E="$ROOT/empty"; mkdir -p "$E"; G -C "$E" init -q
mk_tdd "$E/docs/tdd/0001-new.md" "" '`scripts/lib/nope.sh` — x'
lint "$E" "$E/docs/tdd/0001-new.md"
if [ "$RC" -eq 0 ] && has "$ERR" "tdd-lint: grounding skipped: no commits"; then
  ok "obs9: a repo with no commits → rc 0 and the no-commits skip line"
else bad "obs9: no commits (rc=$RC) out=[$OUT] err=[$ERR]"; fi
# verdicts.sh is sourced from the lint's own tree, never the linted repo's.
mkdir -p "$R/scripts/lib"
printf '_tl_integration_ref() { echo EVIL; }\necho EVIL-SOURCED >&2\n' >"$R/scripts/lib/verdicts.sh"
mk_tdd "$NEW" "" '`scripts/lib/nope.sh` — x'
run "$REPO" ". scripts/lib/tdd-lint.sh && cd $(q "$R") && tl_lint_grounding docs/tdd/0002-new.md"
if [ "$RC" -eq 1 ] && has "$OUT" "is not on master" && hasnt "$ALL" "EVIL"; then
  ok "obs9: verdicts.sh comes from the lint's own dir after a cd into the linted repo"
else bad "obs9: lazy source path (rc=$RC) out=[$OUT] err=[$ERR]"; fi
rm -f "$R/scripts/lib/verdicts.sh"

# --- 10. Invalid paths and siblings -----------------------------------------
mk_tdd "$NEW" "" '`../x` (new) — escapes' '`/etc/passwd` (new) — absolute' '`a/../../b` — dotdot' '`a..b/c.sh` (new) — dots in a name'
lint "$R" "$NEW"
nin="$(printf '%s\n' "$OUT" | grep -c 'major grounding.invalid:')"
if [ "$RC" -eq 1 ] && [ "$nin" -eq 3 ] && has "$OUT" "../x" && has "$OUT" "/etc/passwd" \
   && hasnt "$OUT" "a..b/c.sh"; then
  ok "obs10: .. segments and absolute paths → grounding.invalid whatever the mark"
else bad "obs10: invalid (rc=$RC n=$nin) out=[$OUT] err=[$ERR]"; fi
S1="$R/docs/tdd/0003-sib.md"; S2="$R/docs/tdd/0004-sib.md"
mk_tdd "$S1" "" '`scripts/lib/shared.sh` (new) — created by the set'
mk_tdd "$S2" "" '`scripts/lib/shared.sh` (new) — extended by the set' '`scripts/lib/real.sh` — x'
lint "$R" "$S1" "$S2"
if [ "$RC" -eq 0 ] && hasnt "$OUT$ERR." "grounding."; then
  ok "obs10: two new sibling TDDs marking the same file (new) → no findings"
else bad "obs10: siblings (rc=$RC) out=[$OUT] err=[$ERR]"; fi

# --- skill text -------------------------------------------------------------
SK="$REPO/skills/tdd-author/SKILL.md"
if [ -r "$SK" ] && grep -qF '(new) — <purpose>' "$SK" && grep -qF 'grounding.missing' "$SK" \
   && grep -qF 'placeholder.deferred_discovery' "$SK" && grep -qF 'FR-106' "$SK"; then
  ok "skill: tdd-author documents the (new) marker and the two finding codes"
else bad "skill: tdd-author text for (new) / grounding.missing / deferred_discovery missing"; fi

echo "[S2] git pathspec magic is matched literally, never interpreted"
mk_tdd "$NEW" "" '`:/scripts/lib/real.sh` — x' '`:(glob)scripts/lib/*.sh` — y'
lint "$R" "$NEW"
if [ "$RC" -eq 1 ] && has "$OUT" ":/scripts/lib/real.sh is not on master" \
   && has "$OUT" ":(glob)scripts/lib/*.sh is not on master" \
   && ! printf '%s' "$ERR" | grep -qF "git ls-tree failed"; then  # ERR may be empty
  ok "[S2] ':/x' and ':(glob)x' are literal paths → grounding.missing, not a pass or a git failure"
else bad "[S2] pathspec magic (rc=$RC) out=[$OUT] err=[$ERR]"; fi

echo "[S1] tl_lint_ux_citations never sources the linted repo's ux.sh (relative source path)"
US="$ROOT/us1"; mkdir -p "$US/docs/tdd" "$US/scripts/lib"; git -C "$US" init -q -b master
printf '# P\n\n## Requirements\n- **FR-1 [UI] Login.** x. — Acceptance: `a` prints `b`.\n' > "$US/docs/PRD.md"
printf '# TDD 0001: x\nStatus: draft\nPRD refs: FR-1\n\n## Requirement traceability\n| FR-1 | mock waived: reuses the existing login form unchanged |\n' > "$US/docs/tdd/0001-x.md"
printf 'touch "%s/PWNED"\n' "$US" > "$US/scripts/lib/ux.sh"
git -C "$US" add -A; git -C "$US" -c user.email=t@t.t -c user.name=t commit -qm base
LIBREL="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1]))' "$REPO/scripts/lib")"
( cd "$REPO" && env -i HOME="$ROOT" PATH="$PATH" bash -c ". $LIBREL/tdd-lint.sh >/dev/null 2>&1; cd $(printf '%q' "$US") && tl_lint_ux_citations docs/tdd/0001-x.md" >/dev/null 2>&1 )
if [ ! -e "$US/PWNED" ]; then ok "[S1] planted ux.sh in the linted repo never runs"
else bad "[S1] tl_lint_ux_citations sourced the linted repo's scripts/lib/ux.sh"; fi

p="$(grep -c '^ok$' "$RESULTS")"; f="$(grep -c '^fail$' "$RESULTS")"
echo
echo "tdd-grounding: $p passed, $f failed"
[ "$f" -eq 0 ] && [ "$p" -gt 0 ]

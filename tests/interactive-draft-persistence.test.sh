#!/usr/bin/env bash
# interactive-draft-persistence.test.sh — eval for TDD 0012 / FR-46..50:
# pins the contract of scripts/lib/drafts.sh, the transient interview-draft
# persistence layer shared by /prd-author and /tdd-author.
#
# Written red-first: before TDD 0012 lands, scripts/lib/drafts.sh does not exist,
# so [A] fails on `bash -n` and every behavioral case errors out. The
# implementation commit makes them green.
#
# The helper writes ONE JSON object per skill draft under
# ${CLAUDE_PLUGIN_DATA}/<repo-id>/drafts/<skill>.json. Each tl_draft_* function
# is exercised here: init, exists, append_elicit, write_doc, summary, read,
# discard — and the python3 path AND the python3-less bash fallback are both run
# (summary + append), since the design promises the cascade is correct either
# way.
#
# Run: bash tests/interactive-draft-persistence.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib/drafts.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

# A throwaway git repo with an origin remote so <repo-id> is stable.
mkrepo() { # <dir> [remote-url]
  local d="$1" url="${2-}"
  mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" config user.email t@e; git -C "$d" config user.name t
  [ -n "$url" ] && git -C "$d" remote add origin "$url"
  printf '%s\n' "$d"
}

# A PATH dir holding the helper's coreutils deps but NOT python3, so
# `command -v python3` fails and the bash fallback path runs. Mirrors the
# no-jq stub pattern used by build-observability.test.sh.
mk_nopy() { # <dir>
  local d="$1"; mkdir -p "$d"
  local t src
  for t in bash sh env git sha256sum shasum date mktemp sed grep cat mv rm \
           mkdir dirname basename head cut tr cksum sort find tail wc ls; do
    src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$d/$t"
  done
  printf '%s' "$d"
}

# valid_json <file> — exit 0 iff the file parses as JSON (python3 is present in
# the test's own environment even when we hide it from the helper under test).
valid_json() { python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }
# count_elicits <file> — number of interview entries (one "kind": per entry;
# robust because every user quote inside draft_doc/answers is backslash-escaped).
count_elicits() { grep -o '"kind":' "$1" | wc -l | tr -d ' '; }

DATA="$ROOT/data"
R="$(mkrepo "$ROOT/repo" git@github.com:acme/widget.git)"
# Absolute draft path for the prd-author draft in this fixture repo.
dpath() { cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_path \"$1\""; }

# --- [A] drafts.sh parses + sources standalone, binds every helper -----------
echo "[A] drafts.sh parses + sources in isolation and binds the tl_draft_* set"
( bash -n "$LIB" 2>"$ROOT/A.err" \
    && ok "drafts.sh parses (bash -n)" \
    || bad "drafts.sh failed bash -n: $(cat "$ROOT/A.err" 2>/dev/null)"
  fns="tl_draft_path tl_draft_exists tl_draft_summary tl_draft_read tl_draft_append_elicit tl_draft_write_doc tl_draft_discard tl_draft_init"
  chk="set -uo pipefail; source \"$LIB\";"
  for f in $fns; do chk="$chk type -t $f >/dev/null &&"; done
  chk="$chk true"
  if bash -c "$chk" 2>"$ROOT/A2.err"; then
    ok "drafts.sh sources standalone and binds all eight tl_draft_* functions"
  else
    bad "drafts.sh failed to source/bind: $(cat "$ROOT/A2.err" 2>/dev/null)"
  fi
) || true

# --- [B] tl_draft_path / tl_draft_init create the skeleton -------------------
echo "[B] tl_draft_init writes a schema-1 skeleton at the per-skill path"
( P="$(dpath prd-author)"
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_init prd-author" )
  if [ -f "$P" ]; then ok "tl_draft_init created $P"; else bad "no draft at $P"; fi
  valid_json "$P" && ok "skeleton is valid JSON" || bad "skeleton is not valid JSON: $(cat "$P" 2>/dev/null)"
  grep -q '"schema":1' "$P"            && ok "skeleton has schema:1"        || bad "skeleton missing schema:1"
  grep -q '"skill":"prd-author"' "$P"  && ok "skeleton records skill"       || bad "skeleton missing skill"
  grep -q '"interview":\[\]' "$P"      && ok "skeleton has empty interview" || bad "skeleton interview not empty"
  grep -q '"draft_doc":""' "$P"        && ok "skeleton has empty draft_doc" || bad "skeleton draft_doc not empty"
  grep -q '"prd_rev_at_start":null' "$P" && ok "prd-author skeleton prd_rev is null" || bad "prd-author prd_rev not null"
) || true

# --- [C] tl_draft_init records a prd_rev when given one -----------------------
echo "[C] tl_draft_init [prd_rev] records prd_rev_at_start"
( ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_init tdd-author abc1234" )
  P="$(dpath tdd-author)"
  grep -q '"prd_rev_at_start":"abc1234"' "$P" && ok "tdd-author skeleton records prd_rev" \
                                              || bad "tdd-author prd_rev not recorded: $(cat "$P")"
) || true

# --- [D] tl_draft_exists: true for valid JSON, false otherwise ---------------
echo "[D] tl_draft_exists gates on file-present AND parseable"
( ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_discard ghost" )
  if ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_exists ghost" ); then
    bad "tl_draft_exists true for an absent draft"
  else
    ok "tl_draft_exists false for an absent draft"
  fi
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_init prd-author" )
  if ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_exists prd-author" ); then
    ok "tl_draft_exists true after init"
  else
    bad "tl_draft_exists false after init"
  fi
  G="$(dpath garbage)"; printf 'not json at all {' >"$G"
  if ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_exists garbage" ); then
    bad "tl_draft_exists true for an unparseable draft"
  else
    ok "tl_draft_exists false for an unparseable draft"
  fi
) || true

# --- [E] tl_draft_append_elicit appends one entry per call (python3 path) ----
echo "[E] tl_draft_append_elicit appends append-only interview entries"
( ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_init prd-author" )
  P="$(dpath prd-author)"
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c \
      "source \"$LIB\"; tl_draft_append_elicit prd-author question 'Scope check' 'One product or several?' 'One: throughline overlay'" )
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c \
      "source \"$LIB\"; tl_draft_append_elicit prd-author question 'Users' 'Who is the primary user?' 'Devs using Claude Code'" )
  valid_json "$P" && ok "draft remains valid JSON after two appends" || bad "draft corrupted after appends: $(cat "$P")"
  n="$(count_elicits "$P")"
  [ "$n" = "2" ] && ok "two appends -> 2 interview entries" || bad "expected 2 entries, got '$n'"
  grep -q 'throughline overlay' "$P" && ok "first answer present in draft" || bad "first answer missing"
  grep -q 'Devs using Claude Code' "$P" && ok "second answer present in draft" || bad "second answer missing"
) || true

# --- [F] append survives content with JSON-hostile characters ----------------
echo "[F] tl_draft_append_elicit escapes quotes/backslashes/newlines"
( ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_init prd-author" )
  P="$(dpath prd-author)"
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c \
      'source "'"$LIB"'"; tl_draft_append_elicit prd-author decision "Edge" "n/a" "value with \"quotes\", a \\ slash and
a newline"' )
  valid_json "$P" && ok "draft valid JSON after hostile-content append" || bad "hostile content broke JSON: $(cat "$P")"
  [ "$(count_elicits "$P")" = "1" ] && ok "decision entry appended" || bad "decision entry not appended"
) || true

# --- [G] bash fallback (no python3) appends equivalently ----------------------
echo "[G] tl_draft_append_elicit bash fallback (python3 hidden) appends valid JSON"
( NOPY="$(mk_nopy "$ROOT/nopy")"
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c "source \"$LIB\"; tl_draft_init prd-author" )
  P="$(dpath prd-author)"
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c \
      "source \"$LIB\"; tl_draft_append_elicit prd-author question 'H1' 'Q1?' 'A-one'" )
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c \
      "source \"$LIB\"; tl_draft_append_elicit prd-author question 'H2' 'Q2?' 'A-two'" )
  valid_json "$P" && ok "fallback append produced valid JSON" || bad "fallback append broke JSON: $(cat "$P")"
  n="$(count_elicits "$P")"
  [ "$n" = "2" ] && ok "fallback: two appends -> 2 entries" || bad "fallback expected 2 entries, got '$n'"
  grep -q 'A-one' "$P" && grep -q 'A-two' "$P" && ok "fallback answers present" || bad "fallback answers missing"
) || true

# --- [H] tl_draft_write_doc replaces draft_doc (stdin + file, both paths) -----
echo "[H] tl_draft_write_doc rewrites draft_doc atomically"
( ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_init prd-author" )
  P="$(dpath prd-author)"
  printf '# PRD\n\nBody with a "quote" and a \\ slash.\n' | \
    ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_write_doc prd-author -" )
  valid_json "$P" && ok "draft valid JSON after write_doc from stdin" || bad "write_doc(stdin) broke JSON: $(cat "$P")"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "Body with a \"quote\"" in d["draft_doc"] else 1)' "$P" \
    && ok "draft_doc holds the piped body verbatim" || bad "draft_doc body mismatch"
  DOC="$ROOT/doc.md"; printf 'second version\n' >"$DOC"
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_write_doc prd-author \"$DOC\"" )
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["draft_doc"].strip()=="second version" else 1)' "$P" \
    && ok "write_doc from a file replaces the body" || bad "write_doc(file) did not replace body"
  # bash fallback path
  NOPY="$(mk_nopy "$ROOT/nopy2")"
  printf 'fallback body\n' | \
    ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c "source \"$LIB\"; tl_draft_write_doc prd-author -" )
  valid_json "$P" && grep -q 'fallback body' "$P" && ok "write_doc fallback rewrites draft_doc" \
                                                  || bad "write_doc fallback failed: $(cat "$P")"
) || true

# --- [I] tl_draft_summary one-liner (python3 + fallback) ----------------------
echo "[I] tl_draft_summary emits a one-line resume summary"
( ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_init prd-author" )
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c \
      "source \"$LIB\"; tl_draft_append_elicit prd-author question 'H1' 'Q1' 'A1'; tl_draft_append_elicit prd-author question 'H2' 'Q2' 'A2'" )
  s="$(cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_summary prd-author")"
  case "$s" in
    *"2 elicitations"*"skill=prd-author"*"prd_rev=n/a"*) ok "python3 summary: count + skill + prd_rev=n/a ($s)" ;;
    *) bad "python3 summary wrong shape: '$s'" ;;
  esac
  case "$s" in *"started "*"last updated "*) ok "python3 summary names started + last updated" ;; *) bad "summary missing timestamps: '$s'" ;; esac
  # tdd-author with a prd_rev
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_init tdd-author deadbee; tl_draft_append_elicit tdd-author question 'H' 'Q' 'A'" )
  st="$(cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_summary tdd-author")"
  case "$st" in *"1 elicitations"*"skill=tdd-author"*"prd_rev=deadbee"*) ok "tdd-author summary carries prd_rev ($st)" ;; *) bad "tdd-author summary wrong: '$st'" ;; esac
  # bash fallback summary
  NOPY="$(mk_nopy "$ROOT/nopy3")"
  sf="$(cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c "source \"$LIB\"; tl_draft_summary prd-author")"
  case "$sf" in *"2 elicitations"*"skill=prd-author"*"prd_rev=n/a"*) ok "fallback summary: count + skill + prd_rev ($sf)" ;; *) bad "fallback summary wrong: '$sf'" ;; esac
) || true

# --- [J] tl_draft_read prints the whole JSON ----------------------------------
echo "[J] tl_draft_read prints the full draft JSON"
( out="$(cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_read prd-author")"
  case "$out" in *'"schema":1'*'"interview":'*) ok "tl_draft_read prints schema + interview" ;; *) bad "tl_draft_read output wrong: '$out'" ;; esac
) || true

# --- [K] tl_draft_discard removes the file ------------------------------------
echo "[K] tl_draft_discard removes the draft"
( P="$(dpath prd-author)"
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_discard prd-author" )
  [ -f "$P" ] && bad "tl_draft_discard left the file" || ok "tl_draft_discard removed the draft"
  if ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_exists prd-author" ); then
    bad "tl_draft_exists true after discard"
  else
    ok "tl_draft_exists false after discard"
  fi
) || true

# --- [L] FR-50 defense: kind is restricted to question|decision ---------------
echo "[L] tl_draft_append_elicit rejects kinds outside question|decision (FR-50 defense)"
( ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_init tdd-author" )
  set +e
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c \
      "source \"$LIB\"; tl_draft_append_elicit tdd-author verdict 'V' 'V' 'DESIGN_REVIEW: PASS'" ) 2>/dev/null; rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "append rejects an out-of-enum kind (rc=$rc)" || bad "append accepted a forbidden kind"
  P="$(dpath tdd-author)"
  grep -q 'DESIGN_REVIEW' "$P" && bad "a verdict leaked into the draft" || ok "no verdict string in the draft"
) || true

# --- [M] tl_draft_path rejects unsafe skill names (path-traversal defense) ----
echo "[M] tl_draft_path validates the skill name (no traversal / path escape)"
( for badskill in '../escape' 'a/b' '..' '.hidden' '-x' 'a b'; do
    if ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_path \"$badskill\"" ) >/dev/null 2>&1; then
      bad "tl_draft_path accepted unsafe skill '$badskill'"
    else
      ok "tl_draft_path rejected unsafe skill '$badskill'"
    fi
  done
  # the legitimate names still resolve
  if ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_path prd-author" ) >/dev/null 2>&1; then
    ok "tl_draft_path still accepts 'prd-author'"
  else
    bad "tl_draft_path wrongly rejected 'prd-author'"
  fi
) || true

# --- [N] fallback append/write_doc fail loudly instead of corrupting ----------
# A draft whose updated_at is non-numeric (e.g. null) must NOT be silently
# spliced into an invalid number by the python3-less path. The helper fails
# closed and leaves the draft byte-identical.
echo "[N] bash fallback refuses to corrupt a draft with an unextractable updated_at"
( NOPY="$(mk_nopy "$ROOT/nopyN")"
  P="$(dpath prd-author)"
  bSkel='{"schema":1,"skill":"prd-author","started_at":100,"updated_at":null,"prd_rev_at_start":null,"interview":[],"draft_doc":""}'
  printf '%s' "$bSkel" >"$P"
  set +e
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c \
      "source \"$LIB\"; tl_draft_append_elicit prd-author question H Q A" ) 2>/dev/null; rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "fallback append fails loudly on unextractable updated_at (rc=$rc)" \
                  || bad "fallback append returned 0 on a corruptible draft"
  [ "$(cat "$P")" = "$bSkel" ] && ok "append left the draft byte-identical (atomic, no partial write)" \
                               || bad "append mutated the draft: $(cat "$P")"
  printf '%s' "$bSkel" >"$P"
  set +e
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c \
      "source \"$LIB\"; printf 'x' | tl_draft_write_doc prd-author -" ) 2>/dev/null; rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "fallback write_doc fails loudly on unextractable updated_at (rc=$rc)" \
                  || bad "fallback write_doc returned 0 on a corruptible draft"
  [ "$(cat "$P")" = "$bSkel" ] && ok "write_doc left the draft byte-identical" \
                               || bad "write_doc mutated the draft: $(cat "$P")"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== interactive-draft-persistence eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

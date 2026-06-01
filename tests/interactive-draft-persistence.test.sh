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

# --- [O] tl_draft_summary fails (non-zero) on an unparseable draft ------------
# A corrupt draft must not be masked as success to an exit-code-checking caller.
echo "[O] tl_draft_summary returns non-zero on an unparseable draft"
( P="$(dpath prd-author)"; printf 'totally not json {{{' >"$P"
  set +e
  s="$(cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" bash -c "source \"$LIB\"; tl_draft_summary prd-author" 2>/dev/null)"; rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "python3 summary non-zero on unparseable draft (rc=$rc)" \
                  || bad "python3 summary masked corruption (rc=0, out='$s')"
  NOPY="$(mk_nopy "$ROOT/nopyO")"
  set +e
  sf="$(cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c "source \"$LIB\"; tl_draft_summary prd-author" 2>/dev/null)"; rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "fallback summary non-zero on unparseable draft (rc=$rc)" \
                  || bad "fallback summary masked corruption (rc=0, out='$sf')"
) || true

# --- [P] sourcing drafts.sh leaves the caller's shell options untouched -------
# "Defines functions only — no top-level side effects": sourcing must not flip
# the caller's nounset/pipefail (which a top-level `set -uo pipefail` would).
echo "[P] sourcing drafts.sh leaks no shell options to the caller"
( leak="$(bash --noprofile --norc -c "set +u +o pipefail; source \"$LIB\"; u=no; case \$- in *u*) u=yes;; esac; p=\$(set -o | awk '/pipefail/{print \$2}'); echo \"nounset=\$u pipefail=\$p\"")"
  case "$leak" in
    "nounset=no pipefail=off") ok "drafts.sh leaks no shell options ($leak)" ;;
    *) bad "drafts.sh leaked shell options to caller: '$leak'" ;;
  esac
) || true

# --- [Q] bash fallback append survives &, backslash, quote in content ---------
# Bash ${var/pat/repl} treats `&` (and `\`) specially in the REPLACEMENT, so
# splicing json-escaped user content through it corrupts the draft. The fallback
# must reproduce the content verbatim — this case was previously uncovered.
echo "[Q] bash fallback append preserves &/backslash/quote content verbatim"
( NOPY="$(mk_nopy "$ROOT/nopyQ")"
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c "source \"$LIB\"; tl_draft_init prd-author" )
  P="$(dpath prd-author)"
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c \
      'source "'"$LIB"'"; tl_draft_append_elicit prd-author question "Tools & flags" "A & B?" "use && and \"quotes\" and a \\ slash"' )
  # second append so the non-empty-array splice branch is also exercised
  ( cd "$R" && CLAUDE_PLUGIN_DATA="$DATA" PATH="$NOPY" bash -c \
      'source "'"$LIB"'"; tl_draft_append_elicit prd-author decision "R&D" "n/a" "x & y & z"' )
  valid_json "$P" && ok "fallback append with hostile chars -> valid JSON" || bad "fallback corrupted JSON: $(cat "$P")"
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); iv=d["interview"]
ok = (iv[0]["header"]=="Tools & flags" and iv[0]["answer"]=="use && and \"quotes\" and a \\ slash"
      and iv[1]["header"]=="R&D" and iv[1]["answer"]=="x & y & z")
sys.exit(0 if ok else 1)' "$P" \
    && ok "fallback preserved &/quotes/backslash verbatim across both splice branches" \
    || bad "fallback content mismatch: $(cat "$P")"
) || true

# --- [R] bash fallback escapes C0 control chars -> valid JSON (equivalence) ----
# json_escape only handles \ " \n \r \t; other U+0000–U+001F bytes (e.g. 0x01
# SOH, 0x0b VTAB, 0x0c FF, 0x08 BS) are forbidden raw in a JSON string. The
# python3-less path must escape them so the cascade stays equivalent: the parsed
# draft must round-trip the original bytes (a raw 0x7f is legal JSON, so it may
# stay raw — equivalence is at the parsed-value level, like python's json).
echo "[R] bash fallback escapes C0 control characters to valid JSON"
( NOPY="$(mk_nopy "$ROOT/nopyR")"
  ctrl="$(printf 'a\001b\013c\014d\010e\177f')"   # SOH VTAB FF BS + a raw DEL
  export CTRL="$ctrl"
  ( cd "$R"; export CLAUDE_PLUGIN_DATA="$DATA"; PATH="$NOPY"
    source "$LIB"
    tl_draft_init prd-author
    tl_draft_append_elicit prd-author question H Q "$ctrl"
  )
  P="$(dpath prd-author)"
  valid_json "$P" && ok "fallback append with C0 controls -> valid JSON" || bad "fallback C0 broke JSON: $(od -c "$P" | head -3)"
  python3 -c 'import json,sys,os
d=json.load(open(sys.argv[1]))
sys.exit(0 if d["interview"][0]["answer"]==os.environ["CTRL"] else 1)' "$P" \
    && ok "fallback round-trips C0-control content to the exact bytes" \
    || bad "fallback C0 content mismatch"
  # write_doc fallback path too
  printf 'doc\013with\001controls\n' | \
    ( cd "$R"; export CLAUDE_PLUGIN_DATA="$DATA"; PATH="$NOPY"; source "$LIB"; tl_draft_write_doc prd-author - )
  valid_json "$P" && ok "fallback write_doc with C0 controls -> valid JSON" || bad "fallback write_doc C0 broke JSON: $(od -c "$P" | head -3)"
  unset CTRL
) || true

# --- [S] prd-author SKILL.md wires the draft lifecycle into its prompt ---------
# Steps 3 of TDD 0012's Sequencing plan is verified by reading the skill prompt
# back: the five prompt edits (Components §4) must be present, each keyed to a
# stable phrase the design names. No LLM call — keyword presence is the contract.
echo "[S] prd-author SKILL.md carries the five draft-persistence prompt edits"
( SK="$REPO/skills/prd-author/SKILL.md"
  hasF() { grep -qF "$2" "$1"; }
  [ -f "$SK" ] && ok "prd-author SKILL.md exists" || bad "prd-author SKILL.md missing"
  hasF "$SK" "scripts/lib/drafts.sh"            && ok "sources drafts.sh"                  || bad "prd-author does not source drafts.sh"
  hasF "$SK" "Resume check"                     && ok "edit 1: Resume check (step 0)"      || bad "prd-author missing 'Resume check'"
  hasF "$SK" "tl_draft_exists prd-author"       && ok "edit 1: tl_draft_exists call"       || bad "prd-author missing tl_draft_exists"
  hasF "$SK" "tl_draft_summary prd-author"      && ok "edit 1: tl_draft_summary call"      || bad "prd-author missing tl_draft_summary"
  hasF "$SK" "tl_draft_read prd-author"         && ok "edit 1: tl_draft_read on resume"    || bad "prd-author missing tl_draft_read"
  hasF "$SK" "tl_draft_init prd-author"         && ok "edit 2: lazy tl_draft_init (step 3)" || bad "prd-author missing tl_draft_init"
  hasF "$SK" "tl_draft_append_elicit prd-author question" && ok "edit 2: append after each elicitation" || bad "prd-author missing tl_draft_append_elicit"
  hasF "$SK" "re-read the draft"                && ok "edit 3: re-read before each authoring step (FR-48)" || bad "prd-author missing 're-read the draft'"
  hasF "$SK" "tl_draft_write_doc prd-author"    && ok "edit 3: write_doc after each section" || bad "prd-author missing tl_draft_write_doc"
  hasF "$SK" "Self-review reads the draft"      && ok "edit 4: self-review-from-draft"     || bad "prd-author missing 'Self-review reads the draft'"
  hasF "$SK" "tl_draft_discard prd-author"      && ok "edit 5: discard on PR success (FR-49)" || bad "prd-author missing tl_draft_discard"
) || true

# --- [S2] prd-author SKILL.md carries the per-step-review robustness guardrails -
# The per-step review of step 3 found five gaps in the prompt spec; the fixes are
# verified the same way (keyword presence). Each phrase is the stable anchor for
# one finding so a future edit that drops the guardrail trips this gate.
echo "[S2] prd-author SKILL.md carries the five robustness guardrails"
( SK="$REPO/skills/prd-author/SKILL.md"
  hasF() { grep -qF "$2" "$1"; }
  # Finding 1 — unquoted args risk silent elicitation loss (FR-46).
  hasF "$SK" "shell-quoted"        && ok "guard 1: shell-quote each append argument" || bad "prd-author missing shell-quote instruction"
  hasF "$SK" "word-splits"         && ok "guard 1: names the word-split silent-loss failure" || bad "prd-author missing word-split rationale"
  # Finding 2 — tl_draft_exists exit-code ambiguity; file-presence test disambiguates.
  hasF "$SK" '[ -f "$dpath" ]'     && ok "guard 2: file-presence test reaches the unparseable path" || bad "prd-author missing [ -f \$dpath ] disambiguation"
  hasF "$SK" "not parseable"       && ok "guard 2: unparseable-draft warning" || bad "prd-author missing 'not parseable' path"
  # Finding 3 — missing source-failure handler.
  hasF "$SK" "If sourcing fails"   && ok "guard 3: source-failure handler" || bad "prd-author missing source-failure handler"
  # Finding 4 — stored prompt-injection via recovered draft content.
  hasF "$SK" "untrusted data, not instructions" && ok "guard 4: recovered-content trust boundary" || bad "prd-author missing trust-boundary label"
  # Finding 5 — underspecified degraded-mode + mid-interview failure signals.
  hasF "$SK" "degraded mode"             && ok "guard 5: degraded-mode signal" || bad "prd-author missing degraded-mode signal"
  hasF "$SK" "Mid-interview persistence failure" && ok "guard 5: mid-interview failure signal" || bad "prd-author missing mid-interview failure signal"
) || true

# --- [T] tdd-author SKILL.md wires the draft lifecycle into its prompt ----------
# Step 4 of TDD 0012's Sequencing plan: the same five prompt edits as prd-author
# (Components §5), adapted to tdd-author. Verified by keyword presence, no LLM call.
echo "[T] tdd-author SKILL.md carries the five draft-persistence prompt edits"
( SK="$REPO/skills/tdd-author/SKILL.md"
  hasF() { grep -qF "$2" "$1"; }
  [ -f "$SK" ] && ok "tdd-author SKILL.md exists" || bad "tdd-author SKILL.md missing"
  hasF "$SK" "scripts/lib/drafts.sh"            && ok "sources drafts.sh"                  || bad "tdd-author does not source drafts.sh"
  hasF "$SK" "Resume check"                     && ok "edit 1: Resume check (step 0)"      || bad "tdd-author missing 'Resume check'"
  hasF "$SK" "tl_draft_exists tdd-author"       && ok "edit 1: tl_draft_exists call"       || bad "tdd-author missing tl_draft_exists"
  hasF "$SK" "tl_draft_summary tdd-author"      && ok "edit 1: tl_draft_summary call"      || bad "tdd-author missing tl_draft_summary"
  hasF "$SK" "tl_draft_read tdd-author"         && ok "edit 1: tl_draft_read on resume"    || bad "tdd-author missing tl_draft_read"
  hasF "$SK" "tl_draft_init tdd-author"         && ok "edit 2: lazy tl_draft_init (step 5)" || bad "tdd-author missing tl_draft_init"
  hasF "$SK" "tl_draft_append_elicit tdd-author question" && ok "edit 2: append after each elicitation" || bad "tdd-author missing tl_draft_append_elicit"
  hasF "$SK" "re-read the draft"                && ok "edit 3: re-read before each authoring step (FR-48)" || bad "tdd-author missing 're-read the draft'"
  hasF "$SK" "tl_draft_write_doc tdd-author"    && ok "edit 3: write_doc after each section" || bad "tdd-author missing tl_draft_write_doc"
  hasF "$SK" "Self-review reads the draft"      && ok "edit 4: self-review-from-draft"     || bad "tdd-author missing 'Self-review reads the draft'"
  hasF "$SK" "tl_draft_discard tdd-author"      && ok "edit 5: discard on PR success (FR-49)" || bad "tdd-author missing tl_draft_discard"
) || true

# --- [T2] tdd-author SKILL.md carries its two skill-specific tweaks + guardrails -
# Components §5 adds two tdd-author-only behaviors on top of the shared five
# edits: PRD-drift surfaced on resume, and the FR-50 ban on persisting the
# design-reviewer verdict. The five robustness guardrails are carried over too so
# the per-step-review findings cannot recur in the second skill.
echo "[T2] tdd-author SKILL.md carries PRD-drift, FR-50, and the robustness guardrails"
( SK="$REPO/skills/tdd-author/SKILL.md"
  hasF() { grep -qF "$2" "$1"; }
  # Tweak 1 — PRD drift surfaced on resume.
  hasF "$SK" "prd_rev_at_start"                        && ok "tweak 1: records prd_rev_at_start" || bad "tdd-author missing prd_rev_at_start"
  hasF "$SK" "PRD has advanced since this draft was started" && ok "tweak 1: surfaces PRD drift on resume" || bad "tdd-author missing PRD-drift resume line"
  # Tweak 2 — FR-50: design-reviewer verdict never persisted.
  hasF "$SK" "NEVER persisted to the draft"            && ok "tweak 2: FR-50 verdict-never-persisted" || bad "tdd-author missing FR-50 no-persist rule"
  # Carried-over robustness guardrails (same five findings as prd-author).
  hasF "$SK" "shell-quoted"                            && ok "guard 1: shell-quote each append argument" || bad "tdd-author missing shell-quote instruction"
  hasF "$SK" "word-splits"                             && ok "guard 1: names the word-split silent-loss failure" || bad "tdd-author missing word-split rationale"
  hasF "$SK" '[ -f "$dpath" ]'                         && ok "guard 2: file-presence test reaches the unparseable path" || bad "tdd-author missing [ -f \$dpath ] disambiguation"
  hasF "$SK" "not parseable"                           && ok "guard 2: unparseable-draft warning" || bad "tdd-author missing 'not parseable' path"
  hasF "$SK" "If sourcing fails"                       && ok "guard 3: source-failure handler" || bad "tdd-author missing source-failure handler"
  hasF "$SK" "untrusted data, not instructions"        && ok "guard 4: recovered-content trust boundary" || bad "tdd-author missing trust-boundary label"
  hasF "$SK" "degraded mode"                           && ok "guard 5: degraded-mode signal" || bad "tdd-author missing degraded-mode signal"
  hasF "$SK" "Mid-interview persistence failure"       && ok "guard 5: mid-interview failure signal" || bad "tdd-author missing mid-interview failure signal"
) || true

# --- [T3] tdd-author PRD-rev command actually resolves (per-step-review BLOCK) --
# The first cut used `git rev-parse --short HEAD docs/PRD.md`, which treats the
# path as a revision and exits 128 — prd_rev_at_start would be stored empty and
# the PRD-drift tweak (FR-50/tweak-1) would be dead. The command must be the
# path-scoped last-commit form, and it must actually resolve here.
echo "[T3] tdd-author PRD-rev command resolves to a non-empty short SHA"
( SK="$REPO/skills/tdd-author/SKILL.md"
  if grep -qF 'git rev-parse --short HEAD docs/PRD.md' "$SK"; then
    bad "tdd-author still uses the broken 'git rev-parse --short HEAD docs/PRD.md' (exits 128)"
  else
    ok "tdd-author dropped the broken git rev-parse PRD-rev command"
  fi
  grep -qF 'git log -1 --format=%h -- docs/PRD.md' "$SK" \
    && ok "tdd-author uses 'git log -1 --format=%h -- docs/PRD.md' for prd_rev" \
    || bad "tdd-author missing the working path-scoped PRD-rev command"
  rev="$( cd "$REPO" && git log -1 --format=%h -- docs/PRD.md 2>/dev/null )"
  [ -n "$rev" ] && ok "PRD-rev command resolves to non-empty short SHA ($rev)" \
    || bad "PRD-rev command resolved to empty (drift detection would be inoperative)"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== interactive-draft-persistence eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

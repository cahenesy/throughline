#!/usr/bin/env bash
# json.sh — canonical pure-bash JSON helpers (TDD 0050; FR-27, FR-39, FR-46,
# FR-69, FR-72).
#
# THE single source of truth for JSON string escaping, JSON string-array
# building, and the matching quote-aware string-field read across the runner's
# shell libs (state.sh, markers.sh, learnings.sh, drafts.sh, gates.sh). Folds
# bugs A11/A3 (raw C0 controls reached run-state / candidate-learnings JSON)
# and A10/A5 (the naive first-quote fragment read truncated quote-bearing
# values).
#
# Contract (markers.sh minimal-host; interview decision):
#   - dependency-free and dirname-free: pure bash for the writers, pure awk for
#     the reader; NO jq (state.sh's fragment I/O is deliberately jq-optional —
#     TDD 0037), no sourcing of its own, no top-level side effects beyond the
#     include guard (FR-74 sourced-library hygiene: no shell options set, no
#     ambient variables leaked).
#   - idempotently sourceable: the guard below makes a double-source (state.sh
#     + gates.sh + learnings.sh + drafts.sh under one implement.sh) a no-op.
#     _TL_JSON_SOURCED is the persistent guard and is never unset.
[ -n "${_TL_JSON_SOURCED:-}" ] && return 0
_TL_JSON_SOURCED=1

# tl_json_escape <string> — echo the RFC-8259-valid escaped form of <string>
# WITHOUT surrounding quotes. Escapes backslash, double-quote, the five named
# C0 controls to their short escapes (\b \t \n \f \r), and EVERY remaining C0
# control U+0001–U+001F as a \u00XX escape (lowercase hex), so control-char
# values round-trip instead of corrupting the JSON (RFC 8259 §7: controls MUST
# be escaped — the A11/A3 fix). NUL (U+0000) cannot occur — bash strings cannot
# hold it — so it needs no handling. Pure bash: a fixed 26-entry control walk
# via parameter-expansion replacement, no per-byte iteration, no external tool.
tl_json_escape() {
  local s="${1:-}" cc lit
  # Backslash FIRST (so pre-existing backslashes are doubled before any escape
  # sequence below introduces its own), then double-quote.
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\b'/\\b}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\f'/\\f}"
  s="${s//$'\r'/\\r}"
  # Every remaining C0 control (U+0001–U+001F minus the five above) -> \u00XX.
  for cc in 01 02 03 04 05 06 07 0b 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f; do
    printf -v lit '%b' "\\x$cc"
    s="${s//$lit/\\u00$cc}"
  done
  printf '%s' "$s"
}

# tl_json_array <csv> — echo a JSON string array ["a","b",...] from a
# comma-separated <csv>; each element is tl_json_escape'd; empty input -> [].
# No space after commas (the canonical compact form — the callers' cosmetic
# ["a", "b"] vs ["a","b"] split ends here). Empty CSV tokens are skipped
# ("a,,b" -> ["a","b"]), matching every prior open-coded builder. The split is
# pure parameter expansion: no IFS word-splitting (no glob expansion on
# metacharacter-bearing tokens), no external tr.
tl_json_array() {
  local csv="${1:-}" out="" first=1 tok rest
  [ -n "$csv" ] || { printf '[]'; return 0; }
  rest="$csv,"
  while [ -n "$rest" ]; do
    tok="${rest%%,*}"
    rest="${rest#*,}"
    [ -n "$tok" ] || continue
    if [ "$first" -eq 1 ]; then first=0; else out="$out,"; fi
    out="$out\"$(tl_json_escape "$tok")\""
  done
  printf '[%s]' "$out"
}

# tl_json_array_ws <ws-list> — same, for a whitespace-separated list (the
# _json_str_array shape learnings.sh uses). IFS is pinned locally so a caller's
# modified IFS cannot change the split.
tl_json_array_ws() {
  local IFS=$' \t\n'
  local -a items
  read -ra items <<< "${1:-}"
  local out="" first=1 it
  for it in ${items[@]+"${items[@]}"}; do
    [ -n "$it" ] || continue
    if [ "$first" -eq 1 ]; then first=0; else out="$out,"; fi
    out="$out\"$(tl_json_escape "$it")\""
  done
  printf '[%s]' "$out"
}

# tl_json_field <key> — read the JSON text on stdin; echo the UNescaped string
# value of the first `"<key>":` occurrence when its value is a JSON string;
# empty when the key is absent or its value is null (or any non-string). The
# string is consumed quote-aware — the \" \\ \/ \b \f \n \r \t and \u00XX
# escapes are honored and decoded — so an embedded quote does not truncate the
# value (the A10/A5 fix; this is the inverse of tl_json_escape). Pure awk, no
# jq. First-occurrence matching is the top-level field for every fragment read:
# the fragment writer's fixed field order puts each read key before the nested
# findings/cleared_step_log arrays, and an escaped \"key\": inside a stored
# value cannot match the unescaped "key": pattern (its quotes carry
# backslashes). A non-ASCII \uXXXX (>= 0x80, which tl_json_escape never emits;
# raw UTF-8 is stored raw) is kept as its literal escape rather than decoded.
tl_json_field() {
  local k="${1:-}"
  # Identifier-validate the key: it travels into the awk match (via ENVIRON, so
  # no -v escape mangling), and this guards pattern integrity the same way
  # state.sh::_validate_field_name does.
  case "$k" in
    ''|*[!A-Za-z0-9_]*) echo "tl_json_field: invalid key '$k'" >&2; return 1 ;;
  esac
  TL_JSON_KEY="$k" awk '
    function hex2dec(h,    j, d, ch, r) {
      r = 0
      for (j = 1; j <= length(h); j++) {
        ch = tolower(substr(h, j, 1))
        d = index("0123456789abcdef", ch) - 1
        if (d < 0) return -1
        r = r * 16 + d
      }
      return r
    }
    { buf = buf $0 "\n" }
    END {
      key = ENVIRON["TL_JSON_KEY"]
      i = index(buf, "\"" key "\":")
      if (i == 0) exit 0                       # key absent -> empty
      p = i + length(key) + 3
      while (substr(buf, p, 1) ~ /[ \t\n\r]/) p++
      if (substr(buf, p, 1) != "\"") exit 0    # null / non-string -> empty
      p++
      out = ""; n = length(buf)
      while (p <= n) {
        c = substr(buf, p, 1)
        if (c == "\"") break                   # the UNescaped closing quote
        if (c == "\\") {
          e = substr(buf, p + 1, 1)
          if      (e == "n")  out = out "\n"
          else if (e == "t")  out = out "\t"
          else if (e == "r")  out = out "\r"
          else if (e == "b")  out = out "\b"
          else if (e == "f")  out = out "\f"
          else if (e == "\"") out = out "\""
          else if (e == "\\") out = out "\\"
          else if (e == "/")  out = out "/"
          else if (e == "u") {
            hex = substr(buf, p + 2, 4)
            v = hex2dec(hex)
            if (v > 0 && v < 128) out = out sprintf("%c", v)
            else out = out "\\u" hex           # malformed or non-ASCII: keep literal
            p += 4
          }
          else out = out "\\" e                # unknown escape: keep verbatim, never drop bytes
          p += 2
        } else {
          out = out c
          p++
        }
      }
      printf "%s", out
    }
  '
}

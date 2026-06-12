#!/usr/bin/env bash
# json-helper.test.sh — eval for TDD 0050 (canonical JSON escaper + array
# builder + quote-aware reader, scripts/lib/json.sh). FR-27, FR-39, FR-46,
# FR-69, FR-72.
#
# scripts/lib/json.sh is the SINGLE source of truth for pure-bash JSON
# construction (and the matching read) across the runner's shell libs:
#   tl_json_escape   — RFC-8259-complete string escaper (every C0 control)
#   tl_json_array    — CSV → compact JSON string array ["a","b"]
#   tl_json_array_ws — whitespace-separated list → the same array shape
#   tl_json_field    — quote-aware string-field read (stdin); the inverse
#
# Folded bugs covered:
#   A11    — state.sh's json_escape passed raw C0 controls into run-state JSON.
#   A3     — the same gap reached candidate-learnings.json via learnings.sh.
#   A10/A5 — the `[^"]*` fragment read truncated a quote-bearing value at the
#            first embedded escaped quote (and grew a dangling backslash on
#            the next write).
#
# Run: bash tests/json-helper.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JSON="$REPO/scripts/lib/json.sh"

RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# A literal backslash, used to assemble expected escape SEQUENCES (e.g.
# "${BS}u0001" = the six characters backslash-u-0-0-0-1) without writing them inline where
# an editor/tooling layer could collapse them into the raw byte.
BS='\'

# ============================================================================
# §1 tl_json_escape — C0-complete escaping; output parses strictly + round-trips.
# ============================================================================
echo "[esc-c0] tl_json_escape escapes quote/backslash/newline/tab and raw C0 bytes to strictly-valid JSON (Verification §1)"
(
  source "$JSON" 2>/dev/null || { bad "INFRA: could not source json.sh"; exit 0; }
  val="$(printf 'q:" b:\\ nl:\nz tab:\tz one:\001z us:\037z')"
  esc="$(tl_json_escape "$val")"
  obj="{\"x\":\"$esc\"}"
  printf '%s' "$obj" | jq -e . >/dev/null 2>&1 \
    && ok "escaped value embeds in strictly-parsed JSON" \
    || bad "strict parse failed (esc='$esc')"
  [ "$(printf '%s' "$obj" | jq -r '.x')" = "$val" ] \
    && ok "round-trips byte-for-byte through a strict parser" \
    || bad "round-trip mismatch (esc='$esc')"
  case "$esc" in *"${BS}u0001"*) ok 'a raw 0x01 is emitted as the u0001 escape' ;; *) bad "0x01 not u00-escaped (esc='$esc')" ;; esac
  case "$esc" in *"${BS}u001f"*) ok 'a raw 0x1f is emitted as the u001f escape' ;; *) bad "0x1f not u00-escaped (esc='$esc')" ;; esac
)

# ============================================================================
# §3 array builders — byte-exact compact output; [] on empty; escaped elements.
# ============================================================================
echo "[arr-csv] tl_json_array: exact compact output, element escaping, [] on empty (Verification §3)"
(
  source "$JSON" 2>/dev/null || { bad "INFRA: could not source json.sh"; exit 0; }
  [ "$(tl_json_array 'a,b')" = '["a","b"]' ] \
    && ok 'a,b -> ["a","b"] (no inner space)' || bad "a,b wrong: $(tl_json_array 'a,b')"
  [ "$(tl_json_array '')" = '[]' ] \
    && ok 'empty CSV -> []' || bad "empty CSV wrong: $(tl_json_array '')"
  out="$(tl_json_array 'a,b,"c"')"
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 && [ "$(printf '%s' "$out" | jq -r '.[2]')" = '"c"' ] \
    && ok 'a quote-bearing element is escaped, valid, and round-trips' \
    || bad "quote-bearing element wrong (out=$out)"
  [ "$(tl_json_array 'a,,b')" = '["a","b"]' ] \
    && ok 'empty CSV tokens are skipped' || bad "empty-token handling wrong: $(tl_json_array 'a,,b')"
)

echo "[arr-ws] tl_json_array_ws: whitespace-separated list, same compact shape (Verification §3)"
(
  source "$JSON" 2>/dev/null || { bad "INFRA: could not source json.sh"; exit 0; }
  [ "$(tl_json_array_ws 'a b')" = '["a","b"]' ] \
    && ok 'a b -> ["a","b"]' || bad "a b wrong: $(tl_json_array_ws 'a b')"
  [ "$(tl_json_array_ws '')" = '[]' ] \
    && ok 'empty list -> []' || bad "empty list wrong: $(tl_json_array_ws '')"
)

# ============================================================================
# §6 tl_json_field — quote-aware unescaping read; absent/null → empty (A10/A5).
# ============================================================================
echo "[field-read] tl_json_field: an embedded escaped quote does not truncate; escapes decode; absent/null -> empty (Verification §6)"
(
  source "$JSON" 2>/dev/null || { bad "INFRA: could not source json.sh"; exit 0; }
  # The fixture text contains the STORED escape sequences (escaped quote, backslash-n, backslash-u0001),
  # assembled from $BS so they stay literal backslash sequences in this file.
  json="{\"note\":\"gate emitted no verdict: ${BS}\"PASS${BS}\" expected\",\"halt_cause\":null,\"detail\":\"line1${BS}nline2 ${BS}u0001 end\"}"
  got="$(printf '%s' "$json" | tl_json_field note)"
  [ "$got" = 'gate emitted no verdict: "PASS" expected' ] \
    && ok "quote-bearing value reads back whole (no truncation at the embedded quote)" \
    || bad "quote-bearing value truncated/garbled: [$got]"
  got="$(printf '%s' "$json" | tl_json_field detail)"
  want="$(printf 'line1\nline2 \001 end')"
  [ "$got" = "$want" ] \
    && ok 'stored n/u0001 escapes decode back to the original bytes' \
    || bad "escape decode wrong: [$got]"
  got="$(printf '%s' "$json" | tl_json_field halt_cause)"
  [ -z "$got" ] && ok 'a null value reads as empty' || bad "null read non-empty: [$got]"
  got="$(printf '%s' "$json" | tl_json_field absent_key)"
  [ -z "$got" ] && ok 'an absent key reads as empty' || bad "absent key non-empty: [$got]"
)

# ============================================================================
# §2 A11 regression — a raw C0 byte in a fragment free-text field must yield a
# STRICTLY parseable run-state fragment (state.sh's json_escape delegates to
# the canonical C0-complete escaper; pre-fix the byte landed raw and the
# fragment violated RFC 8259 §7).
# ============================================================================
echo "[a11-regression] a raw C0 byte in a fragment note yields a strictly parseable fragment (Verification §2, FR-27)"
(
  D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
  STATE_DIR="$D/state.d"; mkdir -p "$STATE_DIR"
  source "$REPO/scripts/lib/state.sh" 2>/dev/null || { bad "INFRA: could not source state.sh"; exit 0; }
  note="$(printf 'subprocess emitted \001 control')"
  _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 building build 100 100 br "" log "$note" \
    || bad "INFRA: _write_tdd_fragment failed"
  jq -e . "$STATE_DIR/0001-alpha.json" >/dev/null 2>&1 \
    && ok "fragment with a raw 0x01 note parses strictly (A11 fixed)" \
    || bad "fragment JSON invalid (raw control leaked): $(head -c 200 "$STATE_DIR/0001-alpha.json" 2>/dev/null)"
  [ "$(jq -r '.note' "$STATE_DIR/0001-alpha.json" 2>/dev/null)" = "$note" ] \
    && ok "the note round-trips byte-for-byte through a strict parser" \
    || bad "note round-trip mismatch"
)

# ============================================================================
# §2 A3 regression — the same C0 gap reached candidate-learnings.json via the
# learnings.sh write path (finding summaries ride json_escape into the
# fragment, then are re-embedded verbatim into the candidate file). The
# escaper consolidation (step 2) is what flips this; step 4 routes
# _json_str_array through the same canonical lib.
# ============================================================================
echo "[a3-regression] a raw C0 byte in a recurring finding summary yields a strictly parseable candidate-learnings.json (Verification §2, FR-72)"
(
  D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
  STATE_DIR="$D/state.d"; mkdir -p "$STATE_DIR"
  export THROUGHLINE_LEARNING_MIN_OCCURRENCES=2
  source "$REPO/scripts/lib/state.sh"     2>/dev/null || { bad "INFRA: could not source state.sh"; exit 0; }
  source "$REPO/scripts/lib/learnings.sh" 2>/dev/null || { bad "INFRA: could not source learnings.sh"; exit 0; }
  summ="$(printf 'unsafe \001 escaping seen')"
  for slug in 0001-alpha 0002-beta; do
    _write_tdd_fragment "$slug" 1 "docs/tdd/$slug.md" 1 building build 100 100 br "" log "" \
      || bad "INFRA: fragment write failed for $slug"
    _record_finding "$slug" review p1 major false region 10 "unsafe-escaping" "$summ" "evidence line" \
      || bad "INFRA: _record_finding failed for $slug"
  done
  detect_build_learnings "$STATE_DIR" "$D" "$D" >/dev/null 2>&1
  if [ ! -f "$D/candidate-learnings.json" ]; then
    bad "candidate-learnings.json not written (recurring class across 2 TDDs expected)"
  else
    jq -e . "$D/candidate-learnings.json" >/dev/null 2>&1 \
      && ok "candidate-learnings.json with a C0-bearing summary parses strictly (A3 fixed)" \
      || bad "candidate-learnings.json invalid (raw control leaked)"
  fi
)

# ============================================================================
# §6 A10/A5 regression — the PRIMARY reader (_read_fragment_field) must
# round-trip a quote-bearing free-text value: no truncation at the embedded
# quote on read, and no dangling-backslash growth across a set_tdd_state
# carry-forward rewrite.
# ============================================================================
echo "[a10-roundtrip] a quote-bearing halt_cause_detail round-trips through _read_fragment_field and a set_tdd_state carry-forward (Verification §6, FR-39)"
(
  D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
  STATE_DIR="$D/state.d"; mkdir -p "$STATE_DIR"
  source "$REPO/scripts/lib/state.sh" 2>/dev/null || { bad "INFRA: could not source state.sh"; exit 0; }
  detail='gate emitted no verdict: "PASS" expected'
  _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 paused "" 100 100 br "" log note \
    "transient" "" "" "" "gate-unobservable" "" "" "$detail" \
    || bad "INFRA: _write_tdd_fragment failed"
  got="$(_read_fragment_field "$STATE_DIR/0001-alpha.json" halt_cause_detail)"
  [ "$got" = "$detail" ] \
    && ok "halt_cause_detail reads back whole (no truncation at the first quote)" \
    || bad "truncated/garbled read: [$got]"
  # Carry-forward: a paused->paused set_tdd_state rewrite reads every field and
  # rewrites the fragment; the quote-bearing value must survive unchanged.
  set_tdd_state 0001-alpha paused "" "still paused" || bad "INFRA: set_tdd_state failed"
  got2="$(_read_fragment_field "$STATE_DIR/0001-alpha.json" halt_cause_detail)"
  [ "$got2" = "$detail" ] \
    && ok "carry-forward rewrite preserves the full value (no dangling backslash)" \
    || bad "carry-forward corrupted the value: [$got2]"
  jq -e . "$STATE_DIR/0001-alpha.json" >/dev/null 2>&1 \
    && ok "fragment remains strictly valid after the carry-forward" \
    || bad "fragment invalid after carry-forward"
)

# --- report ----------------------------------------------------------------
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo
echo "=== json-helper eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

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
# step 3 — markers.sh delegation: sourcing markers.sh binds json.sh (its
# minimal-host contract intact — the source is dirname-free), and its two
# named one-offs are thin delegates: _tl_csv_to_json_array now emits the
# canonical COMPACT array (the cosmetic ["a", "b"] vs ["a","b"] split ends),
# _tl_json_escape stays C0-correct through the delegation.
# ============================================================================
echo "[markers-delegate] markers.sh sources json.sh; _tl_csv_to_json_array compact; _tl_json_escape C0-safe (Verification §4)"
(
  source "$REPO/scripts/lib/markers.sh" 2>/dev/null || { bad "INFRA: could not source markers.sh"; exit 0; }
  command -v tl_json_escape >/dev/null 2>&1 \
    && ok "sourcing markers.sh binds tl_json_escape (json.sh pulled in)" \
    || bad "tl_json_escape undefined after sourcing markers.sh"
  [ "$(_tl_csv_to_json_array 'a,b')" = '["a","b"]' ] \
    && ok '_tl_csv_to_json_array emits the canonical compact array' \
    || bad "_tl_csv_to_json_array not the compact canonical form: $(_tl_csv_to_json_array 'a,b')"
  val="$(printf 'a\001b')"
  esc="$(_tl_json_escape "$val")"
  obj="{\"x\":\"$esc\"}"
  printf '%s' "$obj" | jq -e . >/dev/null 2>&1 && [ "$(printf '%s' "$obj" | jq -r '.x')" = "$val" ] \
    && ok "_tl_json_escape stays C0-correct through the delegation" \
    || bad "_tl_json_escape delegation broke C0 escaping (esc='$esc')"
)

# ============================================================================
# step 5 — drafts.sh: the post-processing third escaper (_tl_json_escape_full,
# which existed only to paper over json_escape's C0 gap) is DELETED; callers
# use the canonical tl_json_escape directly. The fallback writers' behavior is
# pinned by the interactive-draft-persistence eval (its [R] C0 case).
# ============================================================================
echo "[drafts-canonical] drafts.sh drops its third escaper; tl_json_escape is the one escaper (Verification §5, FR-46)"
(
  source "$REPO/scripts/lib/drafts.sh" 2>/dev/null || { bad "INFRA: could not source drafts.sh"; exit 0; }
  command -v tl_json_escape >/dev/null 2>&1 \
    && ok "sourcing drafts.sh binds tl_json_escape (json.sh in the chain)" \
    || bad "tl_json_escape undefined after sourcing drafts.sh"
  command -v _tl_json_escape_full >/dev/null 2>&1 \
    && bad "_tl_json_escape_full still defined (third escaper not deleted)" \
    || ok "the post-processing third escaper (_tl_json_escape_full) is gone"
)

# ============================================================================
# §4 sourcing-context matrix — live consumers source cleanly and bind the
# canonical escaper; the include guard makes a double-source a no-op.
# ============================================================================
echo "[ctx-matrix] consumers source cleanly in all contexts; double-source is a no-op (Verification §4)"
(
  D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
  if bash "$REPO/scripts/lib/markers.sh" 2>"$D/err" && ! grep -q FATAL "$D/err"; then
    ok "bash markers.sh runs standalone with no FATAL (dirname-free resolve)"
  else
    bad "markers.sh standalone run failed: $(cat "$D/err")"
  fi
  for lib in markers drafts verdicts run-record; do
    bash -c "set -uo pipefail; source '$REPO/scripts/lib/$lib.sh' 2>/dev/null; command -v tl_json_escape >/dev/null" \
      && ok "$lib.sh standalone source binds tl_json_escape" \
      || bad "$lib.sh standalone source does not bind tl_json_escape"
  done
  bash -c "set -uo pipefail; source '$REPO/scripts/lib/drafts.sh'; source '$REPO/scripts/lib/markers.sh'; source '$REPO/scripts/lib/json.sh'; [ \"\$(tl_json_escape ok)\" = ok ]" 2>/dev/null \
    && ok "double-source is a no-op (include guard holds)" \
    || bad "double-source broke the helpers (include guard)"
)

# ============================================================================
# §5 single source of truth — no hand-rolled escaper/array body remains
# outside json.sh.
# ============================================================================
echo "[single-source] no escaper/array copy remains outside json.sh (Verification §5)"
(
  # The backslash-doubling escape body and the C0 control walk live ONLY in json.sh.
  hits="$(grep -rlF -- '//\\/\\\\' "$REPO/scripts" | grep -v 'lib/json.sh' || true)"
  [ -z "$hits" ] && ok "backslash-doubling escaper body only in json.sh" || bad "stray escaper body in: $hits"
  hits="$(grep -rl 'for cc in 01 02' "$REPO/scripts" | grep -v 'lib/json.sh' || true)"
  [ -z "$hits" ] && ok "C0 control walk only in json.sh" || bad "stray C0 walk in: $hits"
  # The deleted third escaper's name appears nowhere in scripts/.
  grep -rq '_tl_json_escape_full' "$REPO/scripts" \
    && bad "_tl_json_escape_full still referenced under scripts/" \
    || ok "the third escaper's name is gone from scripts/"
  # The canonical helpers are DEFINED exactly once, in json.sh.
  defs="$(grep -rn '^tl_json_escape()\|^tl_json_array()\|^tl_json_array_ws()\|^tl_json_field()' "$REPO/scripts" | grep -cv 'lib/json.sh')"
  [ "$defs" -eq 0 ] && ok "tl_json_* defined only in json.sh" || bad "tl_json_* redefined outside json.sh"
  # The old spaced-array join is gone (markers' ['a', 'b'] cosmetic form).
  grep -rqF 'out="$out, "' "$REPO/scripts" \
    && bad "spaced array join still present under scripts/" \
    || ok "no spaced array join remains"
)

# --- report ----------------------------------------------------------------
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo
echo "=== json-helper eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# coverage-map.test.sh — eval for TDD 0044 (per-requirement test-coverage map,
# FR-78; ADR 0004, 0005, 0006).
#
# For each landing TDD the final consolidated review pass emits a
# COVERAGE_MAP_BEGIN..COVERAGE_MAP_END block classifying each in-scope
# requirement as pinned / proposed / justified-no-surface / unverified-gap.
# The runner extracts the block (coverage_map_block), normalizes it with two
# model-independent anti-false-green downgrades (coverage_map_normalize:
# pinned-without-citation shape check + pinned-citation-not-in-diff presence
# check against the runner-derived `git diff --name-only` list), and renders a
# `## Per-requirement coverage` section into the run's report.md
# (write_coverage_report — report-only, advisory, never a flip authority:
# the FR-15 four gates keep sole auto-flip authority per ADR 0005).
#
#   §1 review-prompt.md carries the coverage-map section (block format, status
#      enum, cited-test rule, advisory framing, consolidated-pass-only rule)
#   §2 coverage_map_block: strict between-fences extraction, last block wins,
#      missing block / missing log → empty + rc 0 (non-fatal)
#   §3 coverage_map_normalize: status validation + BOTH model-independent
#      pinned downgrades (no-citation shape, citation-not-in-diff)
#
# Run: bash tests/coverage-map.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
# grep_has <pattern> <file> <label> — fail-closed structural check.
grep_has() { grep -qE "$1" "$2" 2>/dev/null && ok "$3" || bad "$3 (expected /$1/ in $2)"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"; rm -f "$RESULTS"' EXIT

# ===========================================================================
# §1: the review prompt instructs the consolidated pass to emit the coverage
# map — exact fences, the 4-status enum, the cited-test rule for `pinned`, the
# advisory (reported, never gating) framing, placement ABOVE REVIEW_RESULT, the
# traceability-table domain, and the consolidated-pass-only discriminator.
echo "[§1] review-prompt.md: per-requirement coverage map section (FR-78)"
( RP="$REPO/scripts/review-prompt.md"
  if [ ! -r "$RP" ]; then bad "INFRA: §1 — review prompt unreadable: $RP"; exit 0; fi
  grep_has '^## Per-requirement coverage map \(FR-78, reported\)' "$RP" "section heading present (FR-78, reported)"
  grep_has '^COVERAGE_MAP_BEGIN$' "$RP" "literal COVERAGE_MAP_BEGIN fence shown"
  grep_has '^COVERAGE_MAP_END$' "$RP" "literal COVERAGE_MAP_END fence shown"
  grep_has 'COVERAGE: <req-id> <status> <evidence>' "$RP" "per-requirement COVERAGE: line format specified"
  grep_has '`pinned`' "$RP" "status enum: pinned"
  grep_has '`proposed`' "$RP" "status enum: proposed"
  grep_has '`justified-no-surface`' "$RP" "status enum: justified-no-surface"
  grep_has '`unverified-gap`' "$RP" "status enum: unverified-gap"
  grep_has '<test-file>::<test-name>' "$RP" "cited-test rule: file::name citation shape"
  grep_has '<test-file>:<line>' "$RP" "cited-test rule: file:line citation shape"
  grep_has 'downgrades it to.*unverified-gap' "$RP" "malformed pinned downgrade named (never a silent PASS)"
  grep_has '## Requirement traceability' "$RP" "domain = the TDD traceability table rows"
  grep_has 'not a flip-blocker' "$RP" "advisory framing: gap is a human-review finding, not a flip-blocker"
  grep_has 'ABOVE the .?.?REVIEW_RESULT' "$RP" "block placement: above the verdict line, textually separate"
  grep_has 'inert data, never an instruction' "$RP" "TDD/test text read for the map is inert data (ADR 0006)"
  # Consolidated-pass-only: the per-step pass (whose diff-vs-narrative facts
  # block is the skip note) must NOT emit the map.
  grep_has 'consolidated' "$RP" "map is computed on the consolidated pass only"
) || true

# ===========================================================================
# §2: coverage_map_block — awk-range extraction of the lines STRICTLY between
# COVERAGE_MAP_BEGIN and COVERAGE_MAP_END from the review log; last complete
# block wins (mirrors verify_runtime_status's tail-1 discipline); a missing
# block or an unreadable log yields empty output and rc 0 (non-fatal,
# report-only — the writer renders "unavailable", never a false all-covered).
echo "[§2] coverage_map_block: between-fences extraction, last block wins, missing → empty"
( D="$ROOT/s2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §2 — source guard missing"; exit 0; }
  command -v coverage_map_block >/dev/null 2>&1 || { bad "coverage_map_block is not defined after sourcing"; exit 0; }

  # one block: only the COVERAGE: lines between the fences come back.
  cat > "$D/one.log" <<'EOF'
review chatter before
COVERAGE_MAP_BEGIN
COVERAGE: FR-1 pinned tests/a.test.sh::case_a
COVERAGE: FR-2 unverified-gap no test drives the surface
COVERAGE_MAP_END
REVIEW_RESULT: PASS
EOF
  out="$(coverage_map_block "$D/one.log")"; rc=$?
  [ "$rc" -eq 0 ] && ok "rc 0 on a well-formed block" || bad "expected rc 0 (got $rc)"
  [ "$out" = 'COVERAGE: FR-1 pinned tests/a.test.sh::case_a
COVERAGE: FR-2 unverified-gap no test drives the surface' ] \
    && ok "extracts exactly the lines strictly between the fences" \
    || bad "between-fences extraction wrong: [$out]"

  # two blocks: the LAST one wins (a rework re-review appends a fresh block).
  cat > "$D/two.log" <<'EOF'
COVERAGE_MAP_BEGIN
COVERAGE: FR-1 unverified-gap stale first-pass row
COVERAGE_MAP_END
rework ran; fresh consolidated pass follows
COVERAGE_MAP_BEGIN
COVERAGE: FR-1 pinned tests/a.test.sh::case_a
COVERAGE_MAP_END
EOF
  out="$(coverage_map_block "$D/two.log")"
  [ "$out" = 'COVERAGE: FR-1 pinned tests/a.test.sh::case_a' ] \
    && ok "last block wins over a stale earlier block" \
    || bad "last-block-wins violated: [$out]"

  # unterminated trailing block (BEGIN, no END): never emit a partial block —
  # fall back to the last COMPLETE one.
  cat > "$D/unterm.log" <<'EOF'
COVERAGE_MAP_BEGIN
COVERAGE: FR-1 pinned tests/a.test.sh::case_a
COVERAGE_MAP_END
COVERAGE_MAP_BEGIN
COVERAGE: FR-1 proposed truncated mid-stream
EOF
  out="$(coverage_map_block "$D/unterm.log")"
  [ "$out" = 'COVERAGE: FR-1 pinned tests/a.test.sh::case_a' ] \
    && ok "an unterminated block is ignored (last complete block wins)" \
    || bad "unterminated block must not be emitted: [$out]"

  # no block at all → empty output, rc 0.
  printf 'REVIEW_RESULT: PASS\n' > "$D/none.log"
  out="$(coverage_map_block "$D/none.log")"; rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "missing block → empty output, rc 0" || bad "missing block must be empty+rc0 (rc=$rc, out=[$out])"

  # missing log file → empty output, rc 0 (non-fatal).
  out="$(coverage_map_block "$D/does-not-exist.log")"; rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "missing log → empty output, rc 0 (non-fatal)" || bad "missing log must be empty+rc0 (rc=$rc, out=[$out])"
) || true

# ===========================================================================
# §3: coverage_map_normalize — block lines on stdin, the runner-derived scoped
# diff file list as $1. Validates the status token and applies BOTH
# model-independent anti-false-green downgrades: a `pinned` whose evidence does
# not match the <file>::<name> / <file>:<line> citation shape →
# `unverified-gap` (pinned-without-citation); a syntactically valid citation to
# a path NOT in the scoped diff list → `unverified-gap`
# (pinned-citation-not-in-diff). Output is TAB-separated req/status/evidence.
echo "[§3] coverage_map_normalize: status validation + both pinned downgrades"
( D="$ROOT/s3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §3 — source guard missing"; exit 0; }
  command -v coverage_map_normalize >/dev/null 2>&1 || { bad "coverage_map_normalize is not defined after sourcing"; exit 0; }

  DIFF_FILES='scripts/lib/gates.sh
tests/a.test.sh'
  norm() { coverage_map_normalize "$DIFF_FILES"; }
  row()  { awk -F'\t' -v r="$1" '$1 == r { print $2 "\t" $3 }'; }

  out="$(printf '%s\n' \
    'COVERAGE: FR-1 pinned tests/a.test.sh::case_a' \
    'COVERAGE: FR-2 pinned a test will assert this soon' \
    'COVERAGE: FR-3 pinned tests/elsewhere.test.sh::case_x' \
    'COVERAGE: FR-4 justified-no-surface internal refactor; no observable surface (recorded SKIP)' \
    'COVERAGE: FR-5 unverified-gap CLI exit path has no asserting test' \
    'COVERAGE: FR-6 proposed add an eval driving the halt path' \
    'COVERAGE: FR-7 totally-bogus-status whatever' \
    'COVERAGE: FR-8 pinned tests/a.test.sh:42' \
    'COVERAGE: FR-9 pinned tests/elsewhere.test.sh:42' \
    | norm)"; rc=$?
  [ "$rc" -eq 0 ] && ok "rc 0 on a mixed block" || bad "expected rc 0 (got $rc)"

  [ "$(printf '%s\n' "$out" | row FR-1)" = "$(printf 'pinned\ttests/a.test.sh::case_a')" ] \
    && ok "cited-in-diff pinned (file::name) stays pinned with its citation" \
    || bad "FR-1 should stay pinned (got: $(printf '%s\n' "$out" | row FR-1))"
  [ "$(printf '%s\n' "$out" | row FR-8)" = "$(printf 'pinned\ttests/a.test.sh:42')" ] \
    && ok "cited-in-diff pinned (file:line) stays pinned with its citation" \
    || bad "FR-8 should stay pinned (got: $(printf '%s\n' "$out" | row FR-8))"
  printf '%s\n' "$out" | row FR-2 | grep -q "^unverified-gap	pinned-without-citation" \
    && ok "uncited pinned downgrades to unverified-gap (pinned-without-citation)" \
    || bad "FR-2 must downgrade pinned-without-citation (got: $(printf '%s\n' "$out" | row FR-2))"
  printf '%s\n' "$out" | row FR-3 | grep -q "^unverified-gap	pinned-citation-not-in-diff" \
    && ok "cited-but-not-in-diff pinned (file::name) downgrades (pinned-citation-not-in-diff)" \
    || bad "FR-3 must downgrade pinned-citation-not-in-diff (got: $(printf '%s\n' "$out" | row FR-3))"
  printf '%s\n' "$out" | row FR-9 | grep -q "^unverified-gap	pinned-citation-not-in-diff" \
    && ok "cited-but-not-in-diff pinned (file:line) downgrades (pinned-citation-not-in-diff)" \
    || bad "FR-9 must downgrade pinned-citation-not-in-diff (got: $(printf '%s\n' "$out" | row FR-9))"
  [ "$(printf '%s\n' "$out" | row FR-4)" = "$(printf 'justified-no-surface\tinternal refactor; no observable surface (recorded SKIP)')" ] \
    && ok "justified-no-surface passes through carrying its skip reason" \
    || bad "FR-4 must pass through (got: $(printf '%s\n' "$out" | row FR-4))"
  [ "$(printf '%s\n' "$out" | row FR-5)" = "$(printf 'unverified-gap\tCLI exit path has no asserting test')" ] \
    && ok "unverified-gap passes through with its note" \
    || bad "FR-5 must pass through (got: $(printf '%s\n' "$out" | row FR-5))"
  [ "$(printf '%s\n' "$out" | row FR-6)" = "$(printf 'proposed\tadd an eval driving the halt path')" ] \
    && ok "proposed passes through with its note" \
    || bad "FR-6 must pass through (got: $(printf '%s\n' "$out" | row FR-6))"
  printf '%s\n' "$out" | row FR-7 | grep -q "^unverified-gap	invalid-status" \
    && ok "an out-of-enum status resolves to unverified-gap naming the bad token (never silently green)" \
    || bad "FR-7 must surface invalid-status as unverified-gap (got: $(printf '%s\n' "$out" | row FR-7))"

  # non-COVERAGE chatter between the fences is ignored, not parsed.
  out="$(printf '(thinking aloud)\nCOVERAGE: FR-1 proposed note\n' | norm)"
  [ "$(printf '%s\n' "$out" | grep -c .)" = "1" ] \
    && ok "non-COVERAGE lines inside the block are ignored" \
    || bad "only COVERAGE: lines may produce rows (got: [$out])"

  # empty stdin (missing block) → empty output, rc 0.
  out="$(printf '' | norm)"; rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "empty block → empty output, rc 0" || bad "empty block must be empty+rc0 (rc=$rc, out=[$out])"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== coverage-map eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

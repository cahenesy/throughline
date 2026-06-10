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

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== coverage-map eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

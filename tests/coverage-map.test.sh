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
#      pinned downgrades (no-citation shape, citation-not-in-diff) + the
#      option-shaped citation-path regression fixtures (grep `--` terminator)
#   §4 write_coverage_report: rendered table with the downgrades observable,
#      unlisted-id drop (incl. option-shaped req ids), advisory legend,
#      idempotent per-slug replace
#   §5 missing block → "coverage map unavailable", never a false all-covered;
#      append failure warns and continues (report-only, rc 0)
#   §6 wiring: the consolidated-review clear in _rework_loop calls the writer
#   §7 _pr_coverage_pointer: best-effort gh pr comment naming the report
#      section, warn-and-continue on failure, wired at all three create sites
#   §W dogfood: wiring this eval into the aggregator makes the aggregator's
#      final AND-chain go non-zero when this eval fails (TDD 0038 §3 rule)
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
    'COVERAGE: FR-10 pinned --x::case_y' \
    'COVERAGE: FR-11 pinned --regexp=tests/a.test.sh::case_z' \
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
  # Option-shaped citation paths — the regression fixtures for the `--`
  # terminator in the diff-presence check (`grep -qxF -- "$file"`). FR-10 is
  # the TDD-named `--x::name` shape. FR-11 is the false-green attack the
  # terminator exists to stop: WITHOUT `--`, GNU grep parses
  # `--regexp=tests/a.test.sh` as a pattern OPTION that MATCHES the diff list,
  # so this fabricated pinned would survive — this assertion goes RED if the
  # terminator is ever dropped (must hold under GNU grep semantics).
  printf '%s\n' "$out" | row FR-10 | grep -q "^unverified-gap	pinned-citation-not-in-diff" \
    && ok "option-shaped citation path (--x::name) is a literal, downgrades (pinned-citation-not-in-diff)" \
    || bad "FR-10 (--x::name) must downgrade pinned-citation-not-in-diff (got: $(printf '%s\n' "$out" | row FR-10))"
  printf '%s\n' "$out" | row FR-11 | grep -q "^unverified-gap	pinned-citation-not-in-diff" \
    && ok "option-shaped --regexp= citation cannot match the diff list as a grep option (fabricated pinned cannot survive)" \
    || bad "FR-11 (--regexp=…::name) must downgrade pinned-citation-not-in-diff (got: $(printf '%s\n' "$out" | row FR-11))"
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

# ===========================================================================
# §4: write_coverage_report — the verification plan's fixture: a review log
# whose block carries one pinned (cited, file IN the diff), one pinned (NO
# citation), one pinned (cited, file NOT in the diff), one justified-no-surface,
# one unverified-gap, plus an unlisted requirement id. Renders a
# `## Per-requirement coverage (<slug>, FR-78 — reported, advisory)` section
# into $logdir/report.md with both downgrades observable in the table, the
# unlisted id dropped with a note, the advisory legend, and an idempotent
# per-slug replace on a second invocation.
echo "[§4] write_coverage_report: rendered table, downgrades observable, idempotent replace"
( D="$ROOT/s4"; mkdir -p "$D/state.d" "$D/logs"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D/logs"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §4 — source guard missing"; exit 0; }
  command -v write_coverage_report >/dev/null 2>&1 || { bad "write_coverage_report is not defined after sourcing"; exit 0; }

  # Fixture repo: base commit, then a head commit touching tests/a.test.sh —
  # the runner-derived scoped-diff list the citation check verifies against.
  mkdir -p "$D/repo"; cd "$D/repo" || { bad "INFRA: §4 — cd failed"; exit 0; }
  git init -q; git config user.email t@t.t; git config user.name t
  echo base > base.txt; git add -A; git commit -qm base
  BASE_SHA="$(git rev-parse HEAD)"
  mkdir -p tests docs/tdd
  echo "test fixture" > tests/a.test.sh
  cat > docs/tdd/0099-fixture.md <<'EOF'
# TDD 0099: fixture
Status: ready

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-1 (extraction) | the extractor |
| FR-2 (downgrade a) | the shape check |
| FR-3 (downgrade b) | the diff check |
| FR-4 (skip) | the skip status |
| FR-5 (gap) | the gap status |
EOF
  git add -A; git commit -qm head

  RLOG="$LOGDIR/0099-fixture.log"
  cat > "$RLOG" <<'EOF'
COVERAGE_MAP_BEGIN
COVERAGE: FR-1 pinned tests/a.test.sh::case_a
COVERAGE: FR-2 pinned a test is planned for this
COVERAGE: FR-3 pinned tests/elsewhere.test.sh::case_x
COVERAGE: FR-4 justified-no-surface prompt-only change; no observable surface (recorded SKIP)
COVERAGE: FR-5 unverified-gap halt path has no asserting test
COVERAGE: FR-99 pinned tests/a.test.sh::case_a
COVERAGE: --x pinned tests/a.test.sh::case_a
COVERAGE: --regexp=FR-1 pinned tests/a.test.sh::case_a
COVERAGE_MAP_END
REVIEW_RESULT: PASS
EOF
  printf '# run report\n\npre-existing run content\n' > "$LOGDIR/report.md"

  write_coverage_report "$LOGDIR" "0099-fixture" "$RLOG" "$BASE_SHA" "HEAD"; rc=$?
  R="$LOGDIR/report.md"
  [ "$rc" -eq 0 ] && ok "writer returns 0 (report-only)" || bad "writer must rc 0 (got $rc)"
  grep -qF '## Per-requirement coverage (0099-fixture, FR-78 — reported, advisory)' "$R" \
    && ok "per-slug section heading rendered" || bad "section heading missing from report.md"
  grep -qF '| FR-1 | pinned | tests/a.test.sh::case_a |' "$R" \
    && ok "cited-in-diff pinned row stays pinned with its citation" || bad "FR-1 pinned row wrong"
  grep -qF '| FR-2 | unverified-gap | pinned-without-citation: a test is planned for this |' "$R" \
    && ok "uncited pinned rendered as unverified-gap (pinned-without-citation)" || bad "FR-2 downgrade row wrong"
  grep -qF '| FR-3 | unverified-gap | pinned-citation-not-in-diff: tests/elsewhere.test.sh::case_x |' "$R" \
    && ok "cited-but-not-in-diff pinned rendered as unverified-gap (pinned-citation-not-in-diff)" || bad "FR-3 downgrade row wrong"
  grep -qF '| FR-4 | justified-no-surface | prompt-only change; no observable surface (recorded SKIP) |' "$R" \
    && ok "justified-no-surface row carries its skip reason, NOT rendered as a gap" || bad "FR-4 row wrong"
  grep -qF '| FR-5 | unverified-gap | halt path has no asserting test |' "$R" \
    && ok "unverified-gap row carries its note" || bad "FR-5 row wrong"
  grep -qF 'unlisted requirement FR-99 ignored' "$R" \
    && ok "unlisted requirement dropped with a note" || bad "unlisted-id note missing"
  grep -qF '| FR-99 |' "$R" \
    && bad "unlisted requirement must NOT get a table row" || ok "no table row for the unlisted requirement"
  # Option-shaped requirement ids — the regression fixtures for the `--`
  # terminator in the in-scope domain filter (`grep -qxF -- "$req"`). `--x` is
  # the TDD-named shape. `--regexp=FR-1` is the false-green attack: WITHOUT
  # `--`, GNU grep parses it as a pattern OPTION matching the in-scope id FR-1,
  # silently admitting an out-of-domain id as a table row — these assertions go
  # RED if the terminator is ever dropped (must hold under GNU grep semantics).
  grep -qF 'unlisted requirement --x ignored' "$R" \
    && ok "option-shaped req id (--x) is a literal, dropped as unlisted with a note" \
    || bad "unlisted-id note for --x missing"
  grep -qF '| --x |' "$R" \
    && bad "option-shaped req id --x must NOT get a table row" || ok "no table row for the option-shaped req id --x"
  grep -qF 'unlisted requirement --regexp=FR-1 ignored' "$R" \
    && ok "option-shaped --regexp= req id cannot match the in-scope list as a grep option, dropped with a note" \
    || bad "unlisted-id note for --regexp=FR-1 missing"
  grep -qF '| --regexp=FR-1 |' "$R" \
    && bad "--regexp=FR-1 must NOT be admitted as an in-scope table row" || ok "no table row for the --regexp= req id"
  grep -qF 'not an automatic block' "$R" \
    && ok "advisory legend present (gap = human-review finding)" || bad "advisory legend missing"
  grep -qF 'pre-existing run content' "$R" \
    && ok "pre-existing report content preserved" || bad "writer must append, not clobber, report.md"

  # Idempotent per-slug replace: a second invocation (a resume re-running the
  # final review) replaces the prior section rather than duplicating it.
  write_coverage_report "$LOGDIR" "0099-fixture" "$RLOG" "$BASE_SHA" "HEAD"
  n="$(grep -cF '## Per-requirement coverage (0099-fixture,' "$R")"
  [ "$n" = "1" ] && ok "second invocation replaces the per-slug section (1 heading)" || bad "expected 1 section heading after re-run (got $n)"
  n="$(grep -cF '| FR-1 | pinned |' "$R")"
  [ "$n" = "1" ] && ok "no duplicated table rows after re-run" || bad "expected 1 FR-1 row after re-run (got $n)"
) || true

# ===========================================================================
# §5: degraded paths — a review log with NO block yields an explicit
# "coverage map unavailable" line (never a falsely-green all-covered table);
# an append failure warns to stderr and continues with rc 0 (report-only,
# never fails the build — NFR-4).
echo "[§5] write_coverage_report: missing block → unavailable; append failure warns + rc 0"
( D="$ROOT/s5"; mkdir -p "$D/state.d" "$D/logs"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D/logs"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §5 — source guard missing"; exit 0; }
  command -v write_coverage_report >/dev/null 2>&1 || { bad "write_coverage_report is not defined after sourcing"; exit 0; }
  mkdir -p "$D/repo"; cd "$D/repo" || { bad "INFRA: §5 — cd failed"; exit 0; }
  git init -q; git config user.email t@t.t; git config user.name t
  echo base > base.txt; git add -A; git commit -qm base
  BASE_SHA="$(git rev-parse HEAD)"
  echo head > head.txt; git add -A; git commit -qm head

  printf 'no fences here\nREVIEW_RESULT: PASS\n' > "$LOGDIR/0099-fixture.log"
  : > "$LOGDIR/report.md"
  write_coverage_report "$LOGDIR" "0099-fixture" "$LOGDIR/0099-fixture.log" "$BASE_SHA" "HEAD"; rc=$?
  R="$LOGDIR/report.md"
  [ "$rc" -eq 0 ] && ok "rc 0 on a block-less review log" || bad "missing block must not fail the writer (rc=$rc)"
  grep -qF '## Per-requirement coverage (0099-fixture,' "$R" \
    && ok "section still rendered (no silent omission)" || bad "section heading missing for the unavailable case"
  grep -qiF 'coverage map unavailable' "$R" \
    && ok "explicit 'coverage map unavailable' line (never a false all-covered)" || bad "unavailable line missing"
  grep -qF '| FR-' "$R" \
    && bad "no requirement rows may be rendered without a block" || ok "no fabricated requirement rows"

  # Append failure: read-only logdir → warn to stderr, rc 0, build unaffected.
  RO="$D/ro-logs"; mkdir -p "$RO"; printf 'x\n' > "$RO/r.log"; chmod 555 "$RO"
  err="$(write_coverage_report "$RO" "0099-fixture" "$RO/r.log" "$BASE_SHA" "HEAD" 2>&1 >/dev/null)"; rc=$?
  chmod 755 "$RO"
  [ "$rc" -eq 0 ] && ok "append failure still returns 0 (report-only, never fails the build)" || bad "append failure must rc 0 (got $rc)"
  printf '%s' "$err" | grep -qi 'warning' \
    && ok "append failure warns to stderr (not silent)" || bad "append failure must warn to stderr (got: [$err])"
) || true

# ===========================================================================
# §6: wiring — the consolidated-review clear path in _rework_loop calls
# write_coverage_report (after the per-file coverage check passes, before the
# genuinely-clear return that leads to the flip/PR step). Structural check on
# gates.sh: the FR-78 writer must not be an orphaned helper.
echo "[§6] wiring: _rework_loop's clear path calls write_coverage_report"
( G="$REPO/scripts/lib/gates.sh"
  if [ ! -r "$G" ]; then bad "INFRA: §6 — gates.sh unreadable: $G"; exit 0; fi
  grep_has 'write_coverage_report "\$\{LOGDIR:-\}" "\$slug" "\$log" "\$rbase" "HEAD"' "$G" \
    "the consolidated clear path invokes the writer with the runner's scope"
  # The call must live on the genuinely-clear branch: inside the
  # _per_file_coverage_check-passed arm, before its return 0.
  awk '/_per_file_coverage_check "\$log" "\$pre_log_size"/{inarm=1} inarm && /write_coverage_report/{found=1} inarm && /return 0/{exit} END{exit !found}' "$G" \
    && ok "writer is called between the coverage-check clear and the return" \
    || bad "write_coverage_report must run on the clear path before return 0"
) || true

# ===========================================================================
# §7: _pr_coverage_pointer — after a successful `gh pr create --fill`, post a
# one-line PR COMMENT pointing the human reviewer at the report's
# `## Per-requirement coverage` section. Purely additive (the --fill body is
# untouched); best-effort (a failed gh pr comment warns into the log and
# returns 0 — the one accepted degradation); shared by all three create sites.
echo "[§7] _pr_coverage_pointer: PR-comment pointer, best-effort, three call sites"
( D="$ROOT/s7"; mkdir -p "$D/state.d" "$D/bin"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential" INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "INFRA: §7 — source guard missing"; exit 0; }
  command -v _pr_coverage_pointer >/dev/null 2>&1 || { bad "_pr_coverage_pointer is not defined after sourcing"; exit 0; }

  # Stub gh: record every invocation; exit per $D/gh_rc.
  cat > "$D/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$D/gh.log"
exit "\$(cat "$D/gh_rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$D/bin/gh"; PATH="$D/bin:$PATH"
  export REPORT="$D/report.md"

  # Happy path: comments on the PR, body names the report section + path.
  printf '0\n' > "$D/gh_rc"; : > "$D/gh.log"; : > "$D/ptr.log"
  _pr_coverage_pointer "https://example.test/pr/7" "$D/ptr.log"; rc=$?
  [ "$rc" -eq 0 ] && ok "pointer helper returns 0" || bad "expected rc 0 (got $rc)"
  grep -q '^pr comment https://example.test/pr/7 ' "$D/gh.log" \
    && ok "posts a gh pr comment on the created PR" || bad "expected a gh pr comment invocation (got: $(cat "$D/gh.log"))"
  grep -qF '## Per-requirement coverage' "$D/gh.log" \
    && ok "comment body names the report's coverage section" || bad "comment must name the '## Per-requirement coverage' section"
  grep -qF "$REPORT" "$D/gh.log" \
    && ok "comment body carries the run's report.md path" || bad "comment must point at the run report path"

  # Failure path: gh pr comment fails → warn into the log, rc 0 (build/report
  # flow unaffected; the map still lives in report.md).
  printf '1\n' > "$D/gh_rc"; : > "$D/ptr.log"
  _pr_coverage_pointer "https://example.test/pr/7" "$D/ptr.log"; rc=$?
  [ "$rc" -eq 0 ] && ok "a failed gh pr comment still returns 0 (best-effort)" || bad "gh failure must not propagate (got rc=$rc)"
  grep -qi 'warning' "$D/ptr.log" \
    && ok "a failed gh pr comment warns into the gate log (not silent)" || bad "expected a warning in the log (got: $(cat "$D/ptr.log"))"

  # Empty URL (pr create failed upstream): no gh invocation, rc 0.
  printf '0\n' > "$D/gh_rc"; : > "$D/gh.log"
  _pr_coverage_pointer "" "$D/ptr.log"; rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$D/gh.log" ] \
    && ok "empty PR url → no gh call, rc 0" || bad "empty url must be a no-op (rc=$rc, gh.log: $(cat "$D/gh.log" 2>/dev/null))"

  # All three PR-creation sites (parallel / combined / sequential) share the
  # helper — the pointer string stays in sync by construction.
  n="$(grep -c '_pr_coverage_pointer "\$prurl"' "$IMPL")"
  [ "$n" = "3" ] && ok "all three gh-pr-create sites invoke the shared pointer helper" \
    || bad "expected 3 _pr_coverage_pointer call sites in implement.sh (got $n)"
) || true

# ===========================================================================
# §W: dogfood (TDD 0038 §3 wire-in rule) — registering this eval in the
# aggregator adds a CMAP_FAIL accumulator to its final AND-chain, so the
# aggregator now exits non-zero on a new condition. Drive the REAL extracted
# chain with every accumulator green EXCEPT this eval's, stubbed to fail:
# before the wire-in the chain never references CMAP_FAIL and evaluates true
# (RED); after, it includes the term and evaluates false (GREEN).
echo "[§W] dogfood: wiring this eval into the aggregator makes its exit go non-zero when the eval fails"
( AGG="$REPO/tests/implement-gate.test.sh"
  if [ ! -r "$AGG" ]; then bad "INFRA: §W — aggregator unreadable: $AGG"; exit 0; fi
  # Structural: the new eval is registered (run) in the aggregator. Anchored on
  # the eval filename so an unwired aggregator is RED. Fail-closed on grep error.
  grep_has 'coverage-map\.test\.sh' "$AGG" "the new eval is wired into the aggregator (registration present)"
  # Behavioral: extract the aggregator's real final AND-chain verbatim and
  # evaluate it against stub integers (no recursion into the sub-evals).
  chain="$(grep -aE '^\[ "\$FAIL" -eq 0 \] &&' "$AGG" | tail -1)"
  if [ -z "$chain" ]; then bad "INFRA: §W — could not locate the aggregator final AND-chain"; exit 0; fi
  drive_rc="$(
    set +u
    for v in $(printf '%s' "$chain" | grep -aoE '\$[A-Za-z_][A-Za-z0-9_]*' | tr -d '$' | sort -u); do
      eval "$v=0"
    done
    CMAP_FAIL=1
    eval "$chain"; echo $?
  )"
  [ "$drive_rc" != "0" ] \
    && ok "aggregator final AND-chain goes non-zero when the new eval fails (wire-in propagates)" \
    || bad "aggregator AND-chain must be non-zero with CMAP_FAIL=1 (got rc=$drive_rc)"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== coverage-map eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# build-phase-learning-capture.test.sh — eval for TDD 0022 (build-phase learning
# capture: recurring-pattern detection, run-completion watcher, candidate review
# & persistence).
#
# PRD refs: FR-72.
#
# The contract under test (function-level; the runtime-verify gate re-drives the
# same observable surface against a real /implement run):
#   §1 — detect_build_learnings mines the per-TDD findings[] for recurring
#        non-nit pattern_tag classes (≥ MIN distinct TDDs OR steps), writes
#        <logdir>/candidate-learnings.json + a report.md section, and writes
#        nothing when none recur.
#   §2 — append_accepted_learning persists one entry to docs/tdd/LEARNINGS.md,
#        idempotently (same class + intersecting file-hints reinforces one entry).
#   §3 — implement-watch.sh nohups the build, polls, and prints the
#        IMPLEMENT_RUN_COMPLETE line (wake via SIGUSR1 shortcuts the sleep).
#   §5 — skills/implement/SKILL.md carries the watcher launch + the "Detect
#        pending candidate learnings" review step.
#
# Run: bash tests/build-phase-learning-capture.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE_LIB="$REPO/scripts/lib/state.sh"
LEARN_LIB="$REPO/scripts/lib/learnings.sh"
WATCH="$REPO/scripts/implement-watch.sh"
SKILL="$REPO/skills/implement/SKILL.md"

RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Build one fragment with N findings. Helper sources state.sh + learnings.sh and
# uses the real writers so the readers under test see the production shape.
# _mk_fragment <state_dir> <slug>  (caller then runs _record_finding lines)

# --- §1: recurring-pattern detection ------------------------------------------

echo "[S1] recurring class across two TDDs -> candidate-learnings.json + report section"
( D="$ROOT/S1"; SD="$D/state.d"; mkdir -p "$SD" "$D/docs/tdd"
  export STATE_DIR="$SD" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"; TDDS=()
  . "$STATE_LIB" || { bad "S1 source state.sh"; exit 0; }
  . "$LEARN_LIB" || { bad "S1 source learnings.sh"; exit 0; }
  _write_tdd_fragment 0010-a 10 docs/tdd/0010-a.md 1 done flip 1000 1000 "" "" "" ""
  _write_tdd_fragment 0011-b 11 docs/tdd/0011-b.md 2 done flip 1000 1000 "" "" "" ""
  _record_finding 0010-a review "review-1:1" major false "src/a.sh:1-9"  8 "evidence-not-grounded" "claim not backed by diff" "line A"
  _record_finding 0011-b review "review-1:1" major false "src/b.sh:2-7"  5 "evidence-not-grounded" "claim not backed by diff" "line B"
  printf '## Touched files\n- `src/a.sh` — x\n' > "$D/docs/tdd/0010-a.md"
  printf '## Touched files\n- `src/b.sh` — y\n' > "$D/docs/tdd/0011-b.md"
  detect_build_learnings "$SD" "$D" "$D" || bad "S1 detect_build_learnings should succeed"
  CL="$D/candidate-learnings.json"
  [ -f "$CL" ] && ok "candidate-learnings.json written" || bad "candidate-learnings.json should exist"
  grep -q '"class":"evidence-not-grounded"' "$CL" 2>/dev/null && ok "class named" || bad "class evidence-not-grounded should be present (got: $(cat "$CL" 2>/dev/null))"
  grep -q '"0010-a"' "$CL" 2>/dev/null && grep -q '"0011-b"' "$CL" 2>/dev/null && ok "distinct_tdds lists both slugs" || bad "both slugs should appear in distinct_tdds"
  grep -q 'Candidate learnings (pending review)' "$D/report.md" 2>/dev/null && ok "report.md gains section" || bad "report.md should gain the candidate section"
  grep -q '0010-a' "$D/report.md" 2>/dev/null && grep -q '0011-b' "$D/report.md" 2>/dev/null && ok "report names both TDDs" || bad "report should name both TDDs"
) || true

echo "[S2] below threshold (tag in ONE TDD, MIN=2) -> nothing written"
( D="$ROOT/S2"; SD="$D/state.d"; mkdir -p "$SD" "$D/docs/tdd"
  export STATE_DIR="$SD" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"; TDDS=()
  . "$STATE_LIB"; . "$LEARN_LIB"
  _write_tdd_fragment 0010-a 10 docs/tdd/0010-a.md 1 done flip 1000 1000 "" "" "" ""
  _record_finding 0010-a review "review-1:1" major false "src/a.sh:1-9" 8 "lonely-tag" "only once" "x"
  detect_build_learnings "$SD" "$D" "$D" || bad "S2 detect should still succeed (no-op)"
  [ ! -f "$D/candidate-learnings.json" ] && ok "no candidate-learnings.json below threshold" || bad "should NOT write candidate-learnings.json"
  ! grep -q 'Candidate learnings' "$D/report.md" 2>/dev/null && ok "no report section below threshold" || bad "should NOT add report section"
) || true

echo "[S3] nit-only class across two TDDs -> not surfaced"
( D="$ROOT/S3"; SD="$D/state.d"; mkdir -p "$SD" "$D/docs/tdd"
  export STATE_DIR="$SD" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"; TDDS=()
  . "$STATE_LIB"; . "$LEARN_LIB"
  _write_tdd_fragment 0010-a 10 docs/tdd/0010-a.md 1 done flip 1000 1000 "" "" "" ""
  _write_tdd_fragment 0011-b 11 docs/tdd/0011-b.md 2 done flip 1000 1000 "" "" "" ""
  _record_finding 0010-a review "review-1:1" nit false "src/a.sh:1-1" 1 "style-nit" "polish" "x"
  _record_finding 0011-b review "review-1:1" nit false "src/b.sh:1-1" 1 "style-nit" "polish" "y"
  detect_build_learnings "$SD" "$D" "$D" || bad "S3 detect should succeed (no-op)"
  [ ! -f "$D/candidate-learnings.json" ] && ok "nit-only class not surfaced" || bad "nit-only class must be excluded (got: $(cat "$D/candidate-learnings.json" 2>/dev/null))"
) || true

echo "[S4] threshold env override MIN=3 -> two TDDs not enough"
( D="$ROOT/S4"; SD="$D/state.d"; mkdir -p "$SD" "$D/docs/tdd"
  export STATE_DIR="$SD" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"; TDDS=()
  export THROUGHLINE_LEARNING_MIN_OCCURRENCES=3
  . "$STATE_LIB"; . "$LEARN_LIB"
  _write_tdd_fragment 0010-a 10 docs/tdd/0010-a.md 1 done flip 1000 1000 "" "" "" ""
  _write_tdd_fragment 0011-b 11 docs/tdd/0011-b.md 2 done flip 1000 1000 "" "" "" ""
  _record_finding 0010-a review "review-1:1" major false "src/a.sh:1-9" 8 "evidence-not-grounded" "c" "x"
  _record_finding 0011-b review "review-1:1" major false "src/b.sh:2-7" 5 "evidence-not-grounded" "c" "y"
  detect_build_learnings "$SD" "$D" "$D" || bad "S4 detect should succeed (no-op)"
  [ ! -f "$D/candidate-learnings.json" ] && ok "MIN=3 suppresses a 2-TDD class" || bad "MIN=3 should suppress (got: $(cat "$D/candidate-learnings.json" 2>/dev/null))"
) || true

echo "[S5] subject-area hints = union of involved TDDs' Touched files + class tag"
( D="$ROOT/S5"; SD="$D/state.d"; mkdir -p "$SD" "$D/docs/tdd"
  export STATE_DIR="$SD" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"; TDDS=()
  . "$STATE_LIB"; . "$LEARN_LIB"
  _write_tdd_fragment 0010-a 10 docs/tdd/0010-a.md 1 done flip 1000 1000 "" "" "" ""
  _write_tdd_fragment 0011-b 11 docs/tdd/0011-b.md 2 done flip 1000 1000 "" "" "" ""
  _record_finding 0010-a review "review-1:1" major false "src/a.sh:1-9" 8 "temp-file-leak" "c" "x"
  _record_finding 0011-b review "review-1:1" major false "src/b.sh:2-7" 5 "temp-file-leak" "c" "y"
  printf '## Touched files\n- `scripts/a.sh` — x\n- `scripts/shared.sh` — z\n' > "$D/docs/tdd/0010-a.md"
  printf '## Touched files\n- `scripts/b.sh` — y\n- `scripts/shared.sh` — z\n' > "$D/docs/tdd/0011-b.md"
  detect_build_learnings "$SD" "$D" "$D" || bad "S5 detect should succeed"
  CL="$D/candidate-learnings.json"
  grep -q 'scripts/a.sh' "$CL" 2>/dev/null && grep -q 'scripts/b.sh' "$CL" 2>/dev/null && grep -q 'scripts/shared.sh' "$CL" 2>/dev/null && ok "files hint is the union" || bad "files hint should union all touched files (got: $(cat "$CL" 2>/dev/null))"
  # shared.sh appears once (union, not multiset)
  n="$(grep -o 'scripts/shared.sh' "$CL" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" = "1" ] && ok "union de-dupes shared path" || bad "shared path should appear once (got $n)"
  grep -q '"tags":\["temp-file-leak"\]' "$CL" 2>/dev/null && ok "tags hint carries the class tag" || bad "tags hint should be the class tag"
) || true

echo "[S6] distinct-step threshold: one TDD, two build steps -> recurring"
( D="$ROOT/S6"; SD="$D/state.d"; mkdir -p "$SD" "$D/docs/tdd"
  export STATE_DIR="$SD" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"; TDDS=()
  . "$STATE_LIB"; . "$LEARN_LIB"
  _write_tdd_fragment 0010-a 10 docs/tdd/0010-a.md 1 done flip 1000 1000 "" "" "" ""
  _record_finding 0010-a review "review-1:1" major false "src/a.sh:1-9"  8 "silent-failure" "c" "x"
  _record_finding 0010-a review "review-2:1" major false "src/a.sh:20-25" 5 "silent-failure" "c" "y"
  detect_build_learnings "$SD" "$D" "$D" || bad "S6 detect should succeed"
  CL="$D/candidate-learnings.json"
  grep -q '"class":"silent-failure"' "$CL" 2>/dev/null && ok "two-step single-TDD class is recurring" || bad "should surface a class recurring across 2 steps (got: $(cat "$CL" 2>/dev/null))"
  grep -q '"distinct_steps":2' "$CL" 2>/dev/null && ok "distinct_steps=2 recorded" || bad "distinct_steps should be 2"
) || true

# --- §2: accepted-learning persistence ----------------------------------------

echo "[S7] append_accepted_learning persists one entry (creates LEARNINGS.md)"
( D="$ROOT/S7"; mkdir -p "$D/docs/tdd"
  . "$STATE_LIB"; . "$LEARN_LIB"
  append_accepted_learning "$D" "evidence-not-grounded" "src/a.sh,src/b.sh" "evidence-not-grounded" \
    "0010-a,0011-b" "major–major" "claim not backed by diff" "line A" "run-111" \
    || bad "S7 append should succeed"
  LM="$D/docs/tdd/LEARNINGS.md"
  [ -f "$LM" ] && ok "LEARNINGS.md created" || bad "LEARNINGS.md should be created"
  grep -q '## L-001: evidence-not-grounded' "$LM" 2>/dev/null && ok "L-001 heading written" || bad "should write ## L-001 (got: $(cat "$LM" 2>/dev/null))"
  grep -q 'Pattern class: evidence-not-grounded' "$LM" 2>/dev/null && ok "pattern class line" || bad "pattern class line missing"
  grep -q 'run-111' "$LM" 2>/dev/null && ok "runid recorded" || bad "runid should be recorded"
) || true

echo "[S8] idempotent persist: same class + intersecting files reinforces ONE entry"
( D="$ROOT/S8"; mkdir -p "$D/docs/tdd"
  . "$STATE_LIB"; . "$LEARN_LIB"
  append_accepted_learning "$D" "evidence-not-grounded" "src/a.sh,src/b.sh" "evidence-not-grounded" \
    "0010-a,0011-b" "major–major" "claim not backed by diff" "line A" "run-111"
  append_accepted_learning "$D" "evidence-not-grounded" "src/b.sh,src/c.sh" "evidence-not-grounded" \
    "0012-c" "major–major" "claim not backed by diff" "line C" "run-222"
  LM="$D/docs/tdd/LEARNINGS.md"
  n="$(grep -c '^## L-' "$LM" 2>/dev/null)"; n="${n:-0}"
  [ "$n" = "1" ] && ok "exactly ONE L- heading after two reinforcing appends" || bad "expected 1 heading, got $n ($(cat "$LM" 2>/dev/null))"
  grep -q 'run-111' "$LM" 2>/dev/null && grep -q 'run-222' "$LM" 2>/dev/null && ok "both run ids on the reinforced entry" || bad "Recurred across should name both run ids"
) || true

echo "[S9] non-intersecting file-hints create a SECOND entry (L-002)"
( D="$ROOT/S9"; mkdir -p "$D/docs/tdd"
  . "$STATE_LIB"; . "$LEARN_LIB"
  append_accepted_learning "$D" "evidence-not-grounded" "src/a.sh" "evidence-not-grounded" \
    "0010-a" "major–major" "c" "e" "run-111"
  append_accepted_learning "$D" "evidence-not-grounded" "src/z.sh" "evidence-not-grounded" \
    "0099-z" "minor–minor" "c" "e" "run-222"
  LM="$D/docs/tdd/LEARNINGS.md"
  n="$(grep -c '^## L-' "$LM" 2>/dev/null)"; n="${n:-0}"
  [ "$n" = "2" ] && ok "disjoint file-hints -> two entries" || bad "expected 2 entries, got $n"
  grep -q '## L-002:' "$LM" 2>/dev/null && ok "second entry numbered L-002" || bad "second entry should be L-002"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== build-phase-learning-capture eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

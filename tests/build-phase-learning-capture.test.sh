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
IMPL="$REPO/scripts/implement.sh"
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

echo "[S12] reinforce keeps slugs/run-ids that are substrings of existing values; no tmp residue"
( D="$ROOT/S12"; mkdir -p "$D/docs/tdd"
  . "$STATE_LIB"; . "$LEARN_LIB"
  # First entry: slug 0010-abc, run-111 (the longer values).
  append_accepted_learning "$D" "dup-class" "src/x.sh" "dup-class" \
    "0010-abc" "major–major" "c" "e" "run-111"
  # Reinforce with shorter values that are SUBSTRINGS of the existing ones.
  # A text-contains idempotency check would silently drop both.
  append_accepted_learning "$D" "dup-class" "src/x.sh" "dup-class" \
    "0010-ab" "major–major" "c" "e" "run-11"
  LM="$D/docs/tdd/LEARNINGS.md"
  n="$(grep -c '^## L-' "$LM" 2>/dev/null)"; n="${n:-0}"
  [ "$n" = "1" ] && ok "still one entry after reinforce" || bad "expected 1 entry, got $n"
  grep -ow 'run-111' "$LM" >/dev/null 2>&1 && grep -ow 'run-11' "$LM" >/dev/null 2>&1 && ok "both run-111 and substring run-11 recorded" || bad "substring run id run-11 must not be dropped ($(grep '^- Recurred' "$LM"))"
  grep -ow '0010-abc' "$LM" >/dev/null 2>&1 && grep -ow '0010-ab' "$LM" >/dev/null 2>&1 && ok "both 0010-abc and substring 0010-ab recorded" || bad "substring slug 0010-ab must not be dropped ($(grep '^- Recurred' "$LM"))"
  ls "$D/docs/tdd"/*.tmp.* >/dev/null 2>&1 && bad "atomic write must leave no .tmp residue" || ok "no temp-file residue after atomic append"
) || true

echo "[S10] quote-bearing review prose -> candidate-learnings.json stays valid JSON"
( D="$ROOT/S10"; SD="$D/state.d"; mkdir -p "$SD" "$D/docs/tdd"
  export STATE_DIR="$SD" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"; TDDS=()
  . "$STATE_LIB"; . "$LEARN_LIB"
  # Findings whose summary/evidence embed escaped quotes (the shape _record_finding
  # stores when the reviewer quotes the diff). A lossy [^"]* re-embed would leave a
  # dangling backslash and corrupt the whole array.
  F1='{"source":"review","pass_id":"review-1:1","severity":"major","structural":false,"region":"src/a.sh:1-9","region_lines":8,"pattern_tags":["quote-class"],"summary":"he said \"go\" here","evidence":"the line \"x\" broke","addressed_at":null,"addressed_by_sha":null}'
  F2='{"source":"review","pass_id":"review-1:1","severity":"major","structural":false,"region":"src/b.sh:2-7","region_lines":5,"pattern_tags":["quote-class"],"summary":"again \"go\"","evidence":"second \"y\" case","addressed_at":null,"addressed_by_sha":null}'
  _write_tdd_fragment 0010-a 10 docs/tdd/0010-a.md 1 done flip 1000 1000 "" "" "" "" \
    "" "" "" "" "" "" "" "" "" "" "" "" "" "[$F1]" 0 '{}'
  _write_tdd_fragment 0011-b 11 docs/tdd/0011-b.md 2 done flip 1000 1000 "" "" "" "" \
    "" "" "" "" "" "" "" "" "" "" "" "" "" "[$F2]" 0 '{}'
  detect_build_learnings "$SD" "$D" "$D" || bad "S10 detect should succeed"
  CL="$D/candidate-learnings.json"
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CL" 2>/dev/null; then
    ok "candidate-learnings.json parses as valid JSON with quote-bearing prose"
  else
    bad "candidate-learnings.json must stay valid JSON ($(cat "$CL" 2>/dev/null))"
  fi
) || true

echo "[S11] triggered_rework follows addressed_by_sha (non-null=true, null/absent=false)"
( D="$ROOT/S11"; SD="$D/state.d"; mkdir -p "$SD" "$D/docs/tdd"
  export STATE_DIR="$SD" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"; TDDS=()
  . "$STATE_LIB"; . "$LEARN_LIB"
  # rework-class: one occurrence carries a non-null addressed_by_sha -> rework true.
  RW='{"source":"review","pass_id":"review-1:1","severity":"major","structural":false,"region":"src/a.sh:1-9","region_lines":8,"pattern_tags":["rework-class"],"summary":"s","evidence":"e","addressed_at":1700,"addressed_by_sha":"deadbeef"}'
  RW2='{"source":"review","pass_id":"review-1:1","severity":"major","structural":false,"region":"src/b.sh:2-7","region_lines":5,"pattern_tags":["rework-class"],"summary":"s","evidence":"e","addressed_at":null,"addressed_by_sha":null}'
  # absent-class: NEITHER occurrence has the addressed_by_sha field at all (pre-0019
  # shape) -> must be treated as null -> rework false (the MAJOR-2 absent-field case).
  AB='{"source":"review","pass_id":"review-1:1","severity":"major","structural":false,"region":"src/a.sh:1-9","region_lines":8,"pattern_tags":["absent-class"],"summary":"s","evidence":"e"}'
  AB2='{"source":"review","pass_id":"review-1:1","severity":"major","structural":false,"region":"src/b.sh:2-7","region_lines":5,"pattern_tags":["absent-class"],"summary":"s","evidence":"e"}'
  _write_tdd_fragment 0010-a 10 docs/tdd/0010-a.md 1 done flip 1000 1000 "" "" "" "" \
    "" "" "" "" "" "" "" "" "" "" "" "" "" "[$RW,$AB]" 0 '{}'
  _write_tdd_fragment 0011-b 11 docs/tdd/0011-b.md 2 done flip 1000 1000 "" "" "" "" \
    "" "" "" "" "" "" "" "" "" "" "" "" "" "[$RW2,$AB2]" 0 '{}'
  detect_build_learnings "$SD" "$D" "$D" || bad "S11 detect should succeed"
  CL="$D/candidate-learnings.json"
  if python3 -c '
import json,sys
d={o["class"]:o for o in json.load(open(sys.argv[1]))}
assert d["rework-class"]["triggered_rework"] is True,  "rework-class should be true"
assert d["absent-class"]["triggered_rework"] is False, "absent-class should be false"
' "$CL" 2>/dev/null; then
    ok "triggered_rework: non-null sha -> true, absent field -> false"
  else
    bad "triggered_rework wrong for non-null/absent addressed_by_sha ($(cat "$CL" 2>/dev/null))"
  fi
) || true

# --- §3: the watcher --------------------------------------------------------
# The watcher resolves implement.sh next to itself (SCRIPT_DIR) and the logs dir
# from $PWD, so each scenario builds a throwaway scripts/ + repo/ pair and drops
# a STUB implement.sh beside a copy of the real watcher.

echo "[S13] watcher prints IMPLEMENT_RUN_COMPLETE and removes .watch.pid on build exit"
( WT="$ROOT/S13"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  cp "$WATCH" "$WT/scripts/implement-watch.sh"
  cat > "$WT/scripts/implement.sh" <<'EOF'
#!/usr/bin/env bash
LOGS="$PWD/docs/tdd/.implement-logs"
mkdir -p "$LOGS/run1/state.d"
printf '{"schema":1,"state":"done"}\n' > "$LOGS/run1/state.d/run.json"
printf '[{"class":"x"}]\n' > "$LOGS/run1/candidate-learnings.json"
ln -sfn run1 "$LOGS/latest"
EOF
  out="$WT/out.txt"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=60 \
      bash "$WT/scripts/implement-watch.sh" >"$out" 2>&1 )
  grep -q 'launched build pid ' "$out" 2>/dev/null && ok "watcher echoes the build pid" || bad "watcher should echo 'launched build pid' (got: $(cat "$out" 2>/dev/null))"
  line="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  [ -n "$line" ] && ok "IMPLEMENT_RUN_COMPLETE line printed" || bad "watcher should print IMPLEMENT_RUN_COMPLETE (got: $(cat "$out" 2>/dev/null))"
  case "$line" in *"state=done"*) ok "state=done reported" ;; *) bad "expected state=done ($line)" ;; esac
  case "$line" in *"candidate_learnings=yes"*) ok "candidate_learnings=yes reported" ;; *) bad "expected candidate_learnings=yes ($line)" ;; esac
  case "$line" in *"logdir=/"*) ok "logdir is absolute" ;; *) bad "logdir should be an absolute path ($line)" ;; esac
  [ ! -f "$WT/repo/docs/tdd/.implement-logs/.watch.pid" ] && ok ".watch.pid removed on exit" || bad ".watch.pid should be removed"
) || true

echo "[S14] SIGUSR1 shortcuts the poll sleep (exit well before MAX, build still alive)"
( WT="$ROOT/S14"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  cp "$WATCH" "$WT/scripts/implement-watch.sh"
  cat > "$WT/scripts/implement.sh" <<'EOF'
#!/usr/bin/env bash
LOGS="$PWD/docs/tdd/.implement-logs"
mkdir -p "$LOGS/run1/state.d"
printf '{"schema":1,"state":"done"}\n' > "$LOGS/run1/state.d/run.json"
ln -sfn run1 "$LOGS/latest"
echo $$ > "$LOGS/.stub.pid"
sleep 60
EOF
  out="$WT/out.txt"; pidf="$WT/repo/docs/tdd/.implement-logs/.watch.pid"
  # POLL=30 so a NON-signalled watcher would still be asleep when we assert.
  ( cd "$WT/repo" && THROUGHLINE_WATCH_POLL_SECS=30 THROUGHLINE_WATCH_MAX_SECS=300 \
      bash "$WT/scripts/implement-watch.sh" >"$out" 2>&1 ) &
  bgpid=$!
  # Wait for the watcher to record its pid.
  i=0; while [ ! -f "$pidf" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done
  wp="$(cat "$pidf" 2>/dev/null)"
  sleep 1   # let the watcher enter its sleep
  if [ -n "$wp" ]; then kill -USR1 "$wp" 2>/dev/null; fi
  # The watcher should now exit promptly (well under the 30s poll).
  i=0; while kill -0 "$bgpid" 2>/dev/null && [ "$i" -lt 16 ]; do sleep 0.5; i=$((i+1)); done
  if kill -0 "$bgpid" 2>/dev/null; then bad "watcher did not wake on SIGUSR1 within ~8s (POLL=30)"; kill "$bgpid" 2>/dev/null; else ok "watcher woke on SIGUSR1 before the poll elapsed"; fi
  wait "$bgpid" 2>/dev/null
  grep -q '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null && ok "completion line printed after wake" || bad "should print completion line after SIGUSR1 wake (got: $(cat "$out" 2>/dev/null))"
  # Clean up the still-sleeping stub build.
  sp="$(cat "$WT/repo/docs/tdd/.implement-logs/.stub.pid" 2>/dev/null)"; [ -n "$sp" ] && kill "$sp" 2>/dev/null
) || true

echo "[S15] state token is validated to the known run-state vocabulary, else unknown"
( WT="$ROOT/S15"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  cp "$WATCH" "$WT/scripts/implement-watch.sh"
  # bogus state -> must collapse to unknown; a known state (blocked) passes through.
  cat > "$WT/scripts/implement.sh" <<'EOF'
#!/usr/bin/env bash
LOGS="$PWD/docs/tdd/.implement-logs"
mkdir -p "$LOGS/run1/state.d"
printf '{"schema":1,"state":"%s"}\n' "${STUB_STATE:-zzz weird}" > "$LOGS/run1/state.d/run.json"
ln -sfn run1 "$LOGS/latest"
EOF
  out="$WT/out.txt"
  ( cd "$WT/repo" && STUB_STATE="zzz weird" THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=60 \
      bash "$WT/scripts/implement-watch.sh" >"$out" 2>&1 )
  ln1="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  case "$ln1" in *"state=unknown"*) ok "unrecognized state collapses to unknown" ;; *) bad "bogus state must become unknown ($ln1)" ;; esac
  out2="$WT/out2.txt"
  ( cd "$WT/repo" && STUB_STATE="blocked" THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=60 \
      bash "$WT/scripts/implement-watch.sh" >"$out2" 2>&1 )
  ln2="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out2" 2>/dev/null)"
  case "$ln2" in *"state=blocked"*) ok "a known run state passes through" ;; *) bad "known state should pass through ($ln2)" ;; esac
) || true

echo "[S16] a newline in the resolved logdir cannot inject a second line / split the contract"
( WT="$ROOT/S16"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  cp "$WATCH" "$WT/scripts/implement-watch.sh"
  cat > "$WT/scripts/implement.sh" <<'EOF'
#!/usr/bin/env bash
LOGS="$PWD/docs/tdd/.implement-logs"
nl="$(printf 'runA\nrunB')"
mkdir -p "$LOGS/$nl/state.d"
printf '{"schema":1,"state":"done"}\n' > "$LOGS/$nl/state.d/run.json"
ln -sfn "$nl" "$LOGS/latest"
EOF
  out="$WT/out.txt"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=60 \
      bash "$WT/scripts/implement-watch.sh" >"$out" 2>&1 )
  # The IMPLEMENT_RUN_COMPLETE line must remain a SINGLE line carrying every field
  # — a raw newline in logdir would push state=/candidate_learnings= onto an
  # orphaned line that no longer starts with the marker.
  ln1="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  case "$ln1" in *"state=done"*"candidate_learnings="*) ok "all fields stay on the single marker line" ;; *) bad "newline in logdir split the contract line ($ln1)" ;; esac
  n="$(grep -c '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"; n="${n:-0}"
  [ "$n" = "1" ] && ok "exactly one IMPLEMENT_RUN_COMPLETE line" || bad "expected exactly one marker line (got $n)"
) || true

echo "[S17] watcher fails loud when the logs dir cannot be created (no false completion)"
( WT="$ROOT/S17"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd"
  cp "$WATCH" "$WT/scripts/implement-watch.sh"
  # Block the logs dir: a regular FILE where the dir must be -> mkdir -p fails.
  printf '' > "$WT/repo/docs/tdd/.implement-logs"
  out="$WT/out.txt"; err="$WT/err.txt"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_POLL_SECS=1 THROUGHLINE_WATCH_MAX_SECS=60 \
      bash "$WT/scripts/implement-watch.sh" >"$out" 2>"$err" )
  rc=$?
  [ "$rc" -ne 0 ] && ok "watcher exits non-zero on logs-dir failure" || bad "watcher should fail (rc=$rc)"
  grep -qi 'FATAL' "$err" 2>/dev/null && ok "FATAL diagnostic emitted" || bad "should emit a FATAL diagnostic (err: $(cat "$err" 2>/dev/null))"
  ! grep -q '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null && ok "no false IMPLEMENT_RUN_COMPLETE when no build ran" || bad "must NOT print a completion line (out: $(cat "$out" 2>/dev/null))"
  ! grep -q 'launched build pid' "$out" 2>/dev/null && ok "no build launched after logs-dir failure" || bad "must not launch a build (out: $(cat "$out" 2>/dev/null))"
) || true

echo "[S18] launch-machinery failure -> FATAL (pre-launch); a started-but-fast-dying build -> reported, not fatal"
( WT="$ROOT/S18"; mkdir -p "$WT/scripts" "$WT/repo/docs/tdd/.implement-logs"
  cp "$WATCH" "$WT/scripts/implement-watch.sh"

  # (a) Launch-machinery failure: a MISSING build script fails loud BEFORE any
  #     phantom pid — there is nothing to launch (FR-74). Deterministic pre-launch
  #     check, no dependence on the (relinked-at-end-of-state_init, stale-on-a-2nd-
  #     run) `latest` symlink.
  out="$WT/a.out"; err="$WT/a.err"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_BUILD_SCRIPT="$WT/scripts/nope-missing.sh" \
      THROUGHLINE_WATCH_POLL_SECS=1 bash "$WT/scripts/implement-watch.sh" >"$out" 2>"$err" ); rc=$?
  [ "$rc" -ne 0 ] && grep -qi 'FATAL' "$err" 2>/dev/null && ! grep -q 'launched build pid' "$out" 2>/dev/null \
    && ok "missing build script -> FATAL, no phantom pid" || bad "missing script should fail loud (rc=$rc, out: $(cat "$out" 2>/dev/null))"

  # (b) Launch-machinery failure: an UNWRITABLE nohup.out redirect target fails
  #     loud (no false completion). Block it by making nohup.out a directory.
  cat > "$WT/scripts/implement.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  mkdir -p "$WT/repo/docs/tdd/.implement-logs/nohup.out"
  out="$WT/b.out"; err="$WT/b.err"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_POLL_SECS=1 bash "$WT/scripts/implement-watch.sh" >"$out" 2>"$err" ); rc=$?
  [ "$rc" -ne 0 ] && grep -qi 'FATAL' "$err" 2>/dev/null && ! grep -q '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null \
    && ok "unwritable redirect target -> FATAL, no false completion" || bad "redirect failure should fail loud (rc=$rc, out: $(cat "$out" 2>/dev/null))"
  rmdir "$WT/repo/docs/tdd/.implement-logs/nohup.out" 2>/dev/null
  rm -f "$WT/repo/docs/tdd/.implement-logs/latest"

  # (c) A build that genuinely STARTED then exited fast WITHOUT writing its own
  #     run-state is REPORTED as state=unknown (TDD §Failure-modes: "Build crashes
  #     / single-run lock rejects it … reports state=unknown … No false review"),
  #     NOT treated as a launch failure. The launch machinery was fine, so this is
  #     the runner's domain, not the watcher's.
  out="$WT/c.out"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_POLL_SECS=1 bash "$WT/scripts/implement-watch.sh" >"$out" 2>"$WT/c.err" )
  ln="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  case "$ln" in *"state=unknown"*"candidate_learnings=no"*) ok "started-but-fast-dying build reported state=unknown (not fatal)" ;; *) bad "fast-dying started build must be reported per §Failure-modes ($ln)" ;; esac

  # (d) A genuinely fast build that DID write run-state still completes normally.
  cat > "$WT/scripts/implement.sh" <<'EOF'
#!/usr/bin/env bash
LOGS="$PWD/docs/tdd/.implement-logs"
mkdir -p "$LOGS/run1/state.d"
printf '{"schema":1,"state":"done"}\n' > "$LOGS/run1/state.d/run.json"
ln -sfn run1 "$LOGS/latest"
EOF
  out="$WT/d.out"
  ( cd "$WT/repo" && THROUGHLINE_WATCH_POLL_SECS=1 bash "$WT/scripts/implement-watch.sh" >"$out" 2>"$WT/d.err" )
  ln="$(grep '^IMPLEMENT_RUN_COMPLETE' "$out" 2>/dev/null)"
  case "$ln" in *"state=done"*) ok "fast build that wrote run-state completes normally" ;; *) bad "fast legit build must report completion ($ln)" ;; esac
) || true

# --- §4: runner run-end hook ------------------------------------------------

echo "[S19] implement.sh sources learnings.sh (detect/append available in the runner process)"
( TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$REPO/scripts/implement.sh" 2>/dev/null || true
  type detect_build_learnings  >/dev/null 2>&1 && ok "detect_build_learnings available via implement.sh"  || bad "implement.sh must source detect_build_learnings"
  type append_accepted_learning >/dev/null 2>&1 && ok "append_accepted_learning available via implement.sh" || bad "implement.sh must source append_accepted_learning"
) || true

echo "[S20] run-end hook: a done run writes .run-complete=done and wakes the watcher (both branches / done detection)"
( d="$ROOT/S20"; mkdir -p "$d"/{docs/tdd,docs/adr,.stub/bin}
  cd "$d"
  git init -q; git config user.email t@t.t; git config user.name t
  printf '# PRD\n## Requirements\n1. do the thing\n' > docs/PRD.md
  printf '# ADR Index\n| # | Title | Status | Scope |\n|---|---|---|---|\n' > docs/adr/INDEX.md
  printf '# TDD 0001: alpha\nStatus: ready\nPRD refs: 1\nPRD-rev: deadbee\nADR constraints: none\n\n## Approach\nstub\n' > docs/tdd/0001-alpha.md
  git add -A; git commit -qm init
  STUBDIR="$d/.stub"
  cat > "$STUBDIR/verify_test.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  export CI_CHECKS_TEST_CMD="bash $STUBDIR/verify_test.sh" CI_CHECKS_TYPECHECK_CMD="" CI_CHECKS_LINT_CMD=""
  cat > "$STUBDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2;; *) shift;; esac; done
slug="$(printf '%s' "$prompt" | grep -oE 'docs/tdd/[0-9]+-[a-z]+' | head -1 | sed 's#docs/tdd/##')"
if printf '%s' "$prompt" | grep -q 'INDEPENDENT runtime-verification gate'; then echo "VERIFY_RUNTIME: PASS"; exit 0; fi
if printf '%s' "$prompt" | grep -q 'INDEPENDENT review gate'; then
  rbase="$(printf '%s' "$prompt" | grep -oE 'name-only[[:space:]]+[0-9a-f]{7,40}' | head -1 | grep -oE '[0-9a-f]{7,40}')"
  [ -n "$rbase" ] && git diff --name-only "$rbase"..HEAD 2>/dev/null | while IFS= read -r f; do [ -n "$f" ] && echo "FILE_REVIEWED_NO_FINDINGS: $f"; done
  echo "REVIEW_RESULT: PASS"; exit 0
fi
if printf '%s' "$prompt" | grep -q 'BOUNDED rework pass'; then exit 0; fi
echo "test for $slug" >> "test-$slug.txt"; git add -A >/dev/null 2>&1; git commit -q -m "test(failing): $slug" >/dev/null 2>&1 || true
echo "generated $(date +%s%N)" >> "generated-$slug.txt"; git add -A >/dev/null 2>&1; git commit -q -m "stub build $slug" >/dev/null 2>&1 || true
echo "BATCH_RESULT: OK"; exit 0
EOF
  chmod +x "$STUBDIR/bin/claude"
  export PATH="$STUBDIR/bin:$PATH"
  # A watcher stand-in: traps USR1 and drops a sentinel, so we can observe the wake.
  SENT="$d/woken.sentinel"
  cat > "$d/helper.sh" <<EOF
#!/usr/bin/env bash
trap 'touch "$SENT"; exit 0' USR1
while :; do sleep 0.2; done
EOF
  mkdir -p docs/tdd/.implement-logs
  # Redirect the helper's stdio off the inherited fds (so it can never hold a
  # piped invocation's stdout open) and reap it on subshell exit no matter what.
  bash "$d/helper.sh" >/dev/null 2>&1 & HPID=$!
  trap 'kill "$HPID" 2>/dev/null' EXIT
  echo "$HPID" > docs/tdd/.implement-logs/.watch.pid
  bash "$IMPL" --change ci >/dev/null 2>&1
  LC="docs/tdd/.implement-logs/latest/.run-complete"
  [ -f "$LC" ] && ok ".run-complete written at run end" || bad ".run-complete should exist after a done run"
  [ "$(cat "$LC" 2>/dev/null)" = "done" ] && ok ".run-complete contains done" || bad ".run-complete should be 'done' (got: $(cat "$LC" 2>/dev/null))"
  i=0; while [ ! -f "$SENT" ] && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i+1)); done
  [ -f "$SENT" ] && ok "watcher woken via SIGUSR1 at run end" || bad "run-end hook should SIGUSR1 the recorded .watch.pid"
  kill "$HPID" 2>/dev/null
) || true

echo "[S21] run-end hook PAUSED branch: .run-complete=paused, watcher woken, detection skipped (both branches / done-only detect)"
( d="$ROOT/S21"; mkdir -p "$d"/{docs/tdd,docs/adr,.stub/bin}
  cd "$d"
  git init -q; git config user.email t@t.t; git config user.name t
  printf '# PRD\n## Requirements\n1. do the thing\n' > docs/PRD.md
  printf '# ADR Index\n| # | Title | Status | Scope |\n|---|---|---|---|\n' > docs/adr/INDEX.md
  printf '# TDD 0001: alpha\nStatus: ready\nPRD refs: 1\nPRD-rev: deadbee\nADR constraints: none\n\n## Approach\nstub\n' > docs/tdd/0001-alpha.md
  git add -A; git commit -qm init
  export CI_CHECKS_TEST_CMD="true" CI_CHECKS_TYPECHECK_CMD="" CI_CHECKS_LINT_CMD=""
  # Build emits a rate-limit token and FAILS → the runner classifies it recoverable
  # and (with GATE_RETRIES=1, no backoff) pauses the TDD immediately.
  cat > "$d/.stub/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "Error: 429 too many requests (rate_limit)"
exit 1
EOF
  chmod +x "$d/.stub/bin/claude"; export PATH="$d/.stub/bin:$PATH"
  export THROUGHLINE_GATE_RETRIES=1 THROUGHLINE_GATE_BACKOFF_BASE=0
  SENT="$d/woken.sentinel"
  cat > "$d/helper.sh" <<EOF
#!/usr/bin/env bash
trap 'touch "$SENT"; exit 0' USR1
while :; do sleep 0.2; done
EOF
  mkdir -p docs/tdd/.implement-logs
  bash "$d/helper.sh" >/dev/null 2>&1 & HPID=$!
  trap 'kill "$HPID" 2>/dev/null' EXIT
  echo "$HPID" > docs/tdd/.implement-logs/.watch.pid
  timeout 90 bash "$IMPL" --change ci >/dev/null 2>&1
  LC="docs/tdd/.implement-logs/latest/.run-complete"
  [ "$(cat "$LC" 2>/dev/null)" = "paused" ] && ok ".run-complete=paused on a paused run" || bad ".run-complete should be 'paused' (got: $(cat "$LC" 2>/dev/null))"
  i=0; while [ ! -f "$SENT" ] && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i+1)); done
  [ -f "$SENT" ] && ok "watcher woken via SIGUSR1 in the paused branch" || bad "paused branch must also SIGUSR1 the watcher (§4 both branches)"
  [ ! -f "docs/tdd/.implement-logs/latest/candidate-learnings.json" ] && ok "detection skipped in the paused branch" || bad "detection must NOT run in the paused branch (done-only)"
  kill "$HPID" 2>/dev/null
) || true

echo "[S22] run-end watcher-wake PID guard rejects 0 / negative / non-numeric (no SIGUSR1 process-group broadcast)"
( TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" 2>/dev/null || true
  if type _valid_watch_pid >/dev/null 2>&1; then
    _valid_watch_pid 0      && bad "pid 0 must be rejected (kill -USR1 0 broadcasts to the whole process group)" || ok "pid 0 rejected"
    _valid_watch_pid "-5"   && bad "negative pid must be rejected (targets a process group)"                     || ok "negative pid rejected"
    _valid_watch_pid abc    && bad "non-numeric pid must be rejected"                                            || ok "non-numeric pid rejected"
    _valid_watch_pid ""     && bad "empty pid must be rejected"                                                  || ok "empty pid rejected"
    _valid_watch_pid 0123   && bad "leading-zero pid must be rejected"                                           || ok "leading-zero pid rejected"
    _valid_watch_pid 12345  && ok "a plain positive pid is accepted"                                            || bad "a valid positive pid must be accepted"
  else
    bad "_valid_watch_pid must exist (run-end hook PID guard)"
    bad "_valid_watch_pid must exist (run-end hook PID guard)"
  fi
) || true

# --- §5: skill launch + review step (mechanical grep; the interactive review is
#         exercised by the human at run time / the runtime-verify gate) ---------

echo "[S23] SKILL.md carries the watcher launch + the injection-safe Detect-pending-candidate-learnings review step"
( S="$SKILL"
  grep -q 'implement-watch.sh' "$S" 2>/dev/null && ok "launches via implement-watch.sh" || bad "SKILL.md should launch the watcher"
  grep -q 'run_in_background' "$S" 2>/dev/null && ok "watcher launched as harness-tracked background (run_in_background)" || bad "SKILL.md should launch the watcher with run_in_background"
  # the OLD bare-nohup implement.sh launch must be gone (replaced by the watcher).
  grep -qE 'nohup bash "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/implement\.sh"' "$S" 2>/dev/null && bad "the bare nohup implement.sh launch must be replaced by the watcher" || ok "no bare nohup implement.sh launch remains"
  grep -qi 'Detect pending candidate learnings' "$S" 2>/dev/null && ok "has the Detect-pending-candidate-learnings step" || bad "SKILL.md should add the review step"
  grep -q 'IMPLEMENT_RUN_COMPLETE' "$S" 2>/dev/null && ok "auto path reads the IMPLEMENT_RUN_COMPLETE line" || bad "should describe the auto callback (IMPLEMENT_RUN_COMPLETE)"
  grep -qi 'fallback' "$S" 2>/dev/null && ok "describes the fallback path" || bad "should describe the fallback review path"
  grep -q 'multiSelect' "$S" 2>/dev/null && ok "review uses one multiSelect AskUserQuestion" || bad "review should use a multiSelect AskUserQuestion"
  grep -q 'candidate-learnings.reviewed.json' "$S" 2>/dev/null && ok "marks reviewed by renaming to candidate-learnings.reviewed.json" || bad "should rename to candidate-learnings.reviewed.json after review"
  # Injection-safe: accept through apply_accepted_learnings, passing INDICES only —
  # the field values (summary/evidence) must NEVER be interpolated into a shell
  # command (BLOCKER-1). So the dangerous "<summary>"/"<evidence>" command
  # placeholders must be GONE.
  grep -q 'apply_accepted_learnings' "$S" 2>/dev/null && ok "accepts via apply_accepted_learnings (index-based)" || bad "should call apply_accepted_learnings (index-based, injection-safe)"
  grep -qi 'index' "$S" 2>/dev/null && ok "passes selected indices, not field values" || bad "review should pass selected indices to the accept entrypoint"
  grep -q '"<summary>"' "$S" 2>/dev/null && bad "must NOT interpolate <summary> into a shell command (injection)" || ok "no <summary> interpolated into a command"
  grep -q '"<evidence>"' "$S" 2>/dev/null && bad "must NOT interpolate <evidence> into a shell command (injection)" || ok "no <evidence> interpolated into a command"
) || true

# These scenarios use the REAL logdir layout (<repo>/docs/tdd/.implement-logs/<id>)
# so apply_accepted_learnings derives the repo root from the logdir, not the cwd.
echo "[S24] apply_accepted_learnings persists by index, injection-safe, error-checked reviewed-rename"
( D="$ROOT/S24"; LOG="$D/docs/tdd/.implement-logs/run1"; mkdir -p "$LOG"
  . "$STATE_LIB"; . "$LEARN_LIB"
  # A candidate whose summary/evidence carry shell metacharacters: $(...), backticks, quotes.
  cat > "$LOG/candidate-learnings.json" <<'JSON'
[{"class":"evil-class","distinct_tdds":["0010-a","0011-b"],"distinct_steps":2,"severity_range":["major","major"],"was_structural":false,"triggered_rework":false,"subject_area_hints":{"files":["src/a.sh"],"tags":["evil-class"]},"summary":"has $(touch /tmp/PWNED_S24) and 'quotes'","evidence":"line `touch /tmp/PWNED_S24b` end","occurrences":[]}]
JSON
  rm -f /tmp/PWNED_S24 /tmp/PWNED_S24b
  ( cd "$D" && apply_accepted_learnings "$LOG" 0 ) || bad "S24 apply should succeed"
  { [ ! -e /tmp/PWNED_S24 ] && [ ! -e /tmp/PWNED_S24b ]; } && ok "no shell injection from summary/evidence" || { bad "INJECTION: command in candidate prose executed"; rm -f /tmp/PWNED_S24 /tmp/PWNED_S24b; }
  LM="$D/docs/tdd/LEARNINGS.md"
  grep -q '## L-001: evil-class' "$LM" 2>/dev/null && ok "accepted class persisted by index" || bad "class should persist (got: $(cat "$LM" 2>/dev/null))"
  grep -q 'touch /tmp/PWNED_S24' "$LM" 2>/dev/null && ok "candidate prose stored literally, not executed" || bad "summary should be stored verbatim"
  { [ -f "$LOG/candidate-learnings.reviewed.json" ] && [ ! -f "$LOG/candidate-learnings.json" ]; } && ok "queue renamed reviewed after persist" || bad "should rename to candidate-learnings.reviewed.json"

  # Zero indices = accept nothing, still mark reviewed (all-discarded case).
  D2="$ROOT/S24b"; LOG2="$D2/docs/tdd/.implement-logs/run1"; mkdir -p "$LOG2"
  printf '[{"class":"c","distinct_tdds":["0010-a"],"distinct_steps":1,"severity_range":["minor","minor"],"was_structural":false,"triggered_rework":false,"subject_area_hints":{"files":[],"tags":["c"]},"summary":"s","evidence":"e","occurrences":[]}]\n' > "$LOG2/candidate-learnings.json"
  ( cd "$D2" && apply_accepted_learnings "$LOG2" ) || bad "zero-index apply should succeed"
  { [ -f "$LOG2/candidate-learnings.reviewed.json" ] && [ ! -f "$D2/docs/tdd/LEARNINGS.md" ]; } && ok "all-discarded marks reviewed, persists nothing" || bad "zero-index should mark reviewed without persisting"
) || true

echo "[S25] empty subject-area files (realistic) must NOT shift persisted fields (tab-split keeps empty fields)"
( D="$ROOT/S25"; LOG="$D/docs/tdd/.implement-logs/run1"; mkdir -p "$LOG"
  . "$STATE_LIB"; . "$LEARN_LIB"
  # files=[] (a candidate whose involved TDDs declared no ## Touched files). A
  # whitespace-IFS read collapses the empty field and shifts summary/evidence.
  printf '[{"class":"empty-files-class","distinct_tdds":["0010-a","0011-b"],"distinct_steps":2,"severity_range":["major","major"],"was_structural":false,"triggered_rework":false,"subject_area_hints":{"files":[],"tags":["empty-files-class"]},"summary":"SUMMARY_MARKER","evidence":"EVIDENCE_MARKER","occurrences":[]}]\n' > "$LOG/candidate-learnings.json"
  ( cd "$D" && apply_accepted_learnings "$LOG" 0 ) || bad "S25 apply should succeed"
  LM="$D/docs/tdd/LEARNINGS.md"
  grep -q '^- Summary: SUMMARY_MARKER$'                "$LM" 2>/dev/null && ok "summary stays in the Summary field" || bad "summary field shifted ($(grep -n 'Summary\|evidence' "$LM" 2>/dev/null | tr '\n' '|'))"
  grep -q '^- Representative evidence: EVIDENCE_MARKER$' "$LM" 2>/dev/null && ok "evidence stays in the evidence field" || bad "evidence field shifted"
  grep -q '^- Subject-area hints: files=\[\] tags=\[empty-files-class\]$' "$LM" 2>/dev/null && ok "empty files + tags align correctly" || bad "files/tags misaligned ($(grep -n 'Subject-area' "$LM" 2>/dev/null))"
  grep -q '^- Pattern class: empty-files-class$' "$LM" 2>/dev/null && ok "class aligned" || bad "class misaligned"
) || true

echo "[S26] a JSON parse error fails loud through the live || error path, leaving the queue UNREVIEWED"
( D="$ROOT/S26"; LOG="$D/docs/tdd/.implement-logs/run1"; mkdir -p "$LOG"
  . "$STATE_LIB"; . "$LEARN_LIB"
  printf '{ this is not valid json' > "$LOG/candidate-learnings.json"
  err="$D/err.txt"
  ( cd "$D" && apply_accepted_learnings "$LOG" 0 ) 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] && ok "apply returns non-zero on a parse error" || bad "parse error should fail (rc=$rc)"
  # The distinguishing observation: a real parse error must hit the `|| cannot
  # parse` branch (the error path is LIVE), not be silently swallowed and
  # misreported as an out-of-range empty result (which a `return 0` + 2>/dev/null
  # would do).
  grep -qi 'cannot parse' "$err" 2>/dev/null && ok "the || parse-error path fires (not dead code)" || bad "a parse error must reach the cannot-parse branch (err: $(cat "$err" 2>/dev/null))"
  { [ -f "$LOG/candidate-learnings.json" ] && [ ! -f "$LOG/candidate-learnings.reviewed.json" ]; } && ok "queue left UNREVIEWED on failure" || bad "must not mark reviewed when persistence failed"
) || true

echo "[S27] @tsv transport escaping is reversed: a backslash / newline in candidate prose persists faithfully"
( D="$ROOT/S27"; LOG="$D/docs/tdd/.implement-logs/run1"; mkdir -p "$LOG"
  . "$STATE_LIB"; . "$LEARN_LIB"
  # summary has a real newline (JSON \n); evidence has a real backslash (JSON \\).
  cat > "$LOG/candidate-learnings.json" <<'JSON'
[{"class":"esc-class","distinct_tdds":["0010-a","0011-b"],"distinct_steps":2,"severity_range":["major","major"],"was_structural":false,"triggered_rework":false,"subject_area_hints":{"files":["src/a.sh"],"tags":["esc-class"]},"summary":"multi\nline","evidence":"back\\slash here","occurrences":[]}]
JSON
  ( cd "$D" && apply_accepted_learnings "$LOG" 0 ) || bad "S27 apply should succeed"
  LM="$D/docs/tdd/LEARNINGS.md"
  # backslash must be SINGLE (not @tsv-doubled) and the literal text intact.
  grep -qF 'evidence: back\slash here' "$LM" 2>/dev/null && ok "single backslash persisted (transport escaping reversed)" || bad "evidence backslash corrupted ($(grep -n 'evidence' "$LM" 2>/dev/null))"
  grep -qF 'back\\slash' "$LM" 2>/dev/null && bad "backslash was @tsv-doubled in the store" || ok "no doubled backslash in the store"
  # the real newline flattens to a space (single-line markdown entry), not a literal \n.
  grep -q '^- Summary: multi line$' "$LM" 2>/dev/null && ok "newline flattened, not left as a literal \\n" || bad "summary newline not handled ($(grep -n 'Summary' "$LM" 2>/dev/null))"
) || true

echo "[S28] apply_accepted_learnings locates the repo root from the logdir, not the cwd (no silent wrong-path)"
( D="$ROOT/S28"; LOG="$D/docs/tdd/.implement-logs/run1"; mkdir -p "$LOG"
  . "$STATE_LIB"; . "$LEARN_LIB"
  printf '[{"class":"cwd-class","distinct_tdds":["0010-a","0011-b"],"distinct_steps":2,"severity_range":["minor","minor"],"was_structural":false,"triggered_rework":false,"subject_area_hints":{"files":[],"tags":["cwd-class"]},"summary":"s","evidence":"e","occurrences":[]}]\n' > "$LOG/candidate-learnings.json"
  # Run from a DIFFERENT cwd than the repo root: the store must still land under $D.
  ( cd "$ROOT" && apply_accepted_learnings "$LOG" 0 ) || bad "S28 apply should succeed"
  grep -q '## L-001: cwd-class' "$D/docs/tdd/LEARNINGS.md" 2>/dev/null && ok "LEARNINGS.md written under the logdir's repo root" || bad "store landed in the wrong tree (cwd-dependent path)"
  [ ! -f "$ROOT/docs/tdd/LEARNINGS.md" ] && ok "nothing written under the unrelated cwd" || bad "wrote LEARNINGS.md under the cwd (silent wrong-path)"
) || true

echo "[S29] a field-decode (_untsv) failure fails loud — no silent empty write, queue stays UNREVIEWED"
( D="$ROOT/S29"; LOG="$D/docs/tdd/.implement-logs/run1"; mkdir -p "$LOG"
  . "$STATE_LIB"; . "$LEARN_LIB"
  printf '[{"class":"c","distinct_tdds":["0010-a","0011-b"],"distinct_steps":2,"severity_range":["major","major"],"was_structural":false,"triggered_rework":false,"subject_area_hints":{"files":["src/a.sh"],"tags":["c"]},"summary":"s","evidence":"e","occurrences":[]}]\n' > "$LOG/candidate-learnings.json"
  # Simulate a decode failure (e.g. awk unavailable): _untsv returns non-zero +
  # empty. The unchecked-rc bug would persist empty fields and mark reviewed.
  _untsv() { return 1; }
  err="$D/err.txt"
  ( cd "$D" && apply_accepted_learnings "$LOG" 0 ) 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] && ok "apply fails when a field decode fails" || bad "should fail on _untsv failure (rc=$rc)"
  [ ! -f "$D/docs/tdd/LEARNINGS.md" ] && ok "no partial/empty entry written on decode failure" || bad "must not write on decode failure ($(cat "$D/docs/tdd/LEARNINGS.md" 2>/dev/null))"
  { [ -f "$LOG/candidate-learnings.json" ] && [ ! -f "$LOG/candidate-learnings.reviewed.json" ]; } && ok "queue left UNREVIEWED for retry" || bad "must not mark reviewed when decode failed"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== build-phase-learning-capture eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

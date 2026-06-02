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

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== build-phase-learning-capture eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

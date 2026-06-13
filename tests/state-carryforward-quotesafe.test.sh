#!/usr/bin/env bash
# state-carryforward-quotesafe.test.sh — pins the TDD 0051 quote-safe fragment
# read fix (bugs A10/A5; FR-27, FR-39, FR-40, FR-69; ADR 0006).
#
# The per-TDD run-state fragment is mutated by ~13 carry-forward functions across
# state.sh + resume.sh + pause-retry.sh. Each used to read free-text string fields
# (note/path/branch/pr_url/log/status/stage) with an inline
#   sed -n 's/.*"k":"\([^"]*\)".*/\1/p'
# whose `[^"]*` class stops at the first `"` byte — the quote half of a stored
# `\"` escape — so a free-text value containing a double-quote was TRUNCATED on
# read, then the dangling `\` re-escaped to `\\` on the next json_escape write,
# compounding the corruption on every transition. The only live free-text field
# carrying a `"` is `note`. The fix routes every such read through the canonical
# quote-aware reader `_read_fragment_field` (TDD 0050's tl_json_field).
#
# This eval drives the real mutators against a temp STATE_DIR and asserts:
#   §1  a quote-bearing `note` round-trips byte-intact through a state.sh mutator
#       transition (fail-pre/pass-post regression), and quote-free branch/pr_url/
#       log are unchanged.
#
# Run: bash tests/state-carryforward-quotesafe.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# The canonical quote-bearing forensic note from the TDD's Verification §1.
NOTE='gate emitted no verdict: "PASS" expected'
BR='feat/0001-alpha'
PRURL='https://example.test/pr/1?x=1%20y'
LOG='docs/tdd/.implement-logs/run/0001-alpha.log'

echo "[1] state.sh: a quote-bearing note round-trips through set_tdd_state -> set_halt_cause"
( D="$ROOT/1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  F="$D/state.d/0001-alpha.json"
  # Seed a fragment carrying the quote-bearing note + quote-free branch/pr_url/log
  # via the canonical writer (json_escape escapes the note correctly on write —
  # the bug is on the READ side of the carry-forward mutators).
  _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 paused "" \
    1000 1000 "$BR" "$PRURL" "$LOG" "$NOTE" "" "" "" ""
  # Run a state.sh transition that re-writes note from its param (correct write
  # path), then a mutator that READS note off disk and carries it forward — the
  # set_halt_cause read is exactly where the A10/A5 truncation bit pre-fix.
  set_tdd_state 0001-alpha paused "" "$NOTE"
  set_halt_cause 0001-alpha ratelimit
  got_note="$(_read_fragment_field "$F" note)"
  got_branch="$(_read_fragment_field "$F" branch)"
  got_pr="$(_read_fragment_field "$F" pr_url)"
  got_log="$(_read_fragment_field "$F" log)"
  [ "$got_note" = "$NOTE" ] \
    && ok "quote-bearing note round-trips byte-intact (no truncation at the \", no \\\\ compounding)" \
    || bad "note must round-trip intact (got '$got_note', want '$NOTE')"
  [ "$got_branch" = "$BR" ] && ok "quote-free branch unchanged" || bad "branch changed (got '$got_branch')"
  [ "$got_pr" = "$PRURL" ] && ok "quote-free pr_url unchanged" || bad "pr_url changed (got '$got_pr')"
  [ "$got_log" = "$LOG" ] && ok "quote-free log unchanged" || bad "log changed (got '$got_log')"
) || true

echo "[1b] resume.sh: a quote-bearing note survives an _update_paused_cause carry-forward (FR-39/FR-40)"
( D="$ROOT/1b"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  F="$D/state.d/0001-alpha.json"
  _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 paused "" \
    1000 1000 "$BR" "$PRURL" "$LOG" "$NOTE" "" "" "" ""
  # _update_paused_cause reads note off disk and round-trips it via _write_tdd_fragment
  # (it mutates only paused_cause) — the resume.sh read site the A10/A5 truncation bit.
  _update_paused_cause 0001-alpha resume-blocked-branch-divergence
  got_note="$(_read_fragment_field "$F" note)"
  got_branch="$(_read_fragment_field "$F" branch)"
  [ "$got_note" = "$NOTE" ] \
    && ok "note survives _update_paused_cause byte-intact (resume.sh read fixed)" \
    || bad "note must survive _update_paused_cause intact (got '$got_note')"
  [ "$got_branch" = "$BR" ] && ok "resume.sh: quote-free branch unchanged" || bad "branch changed (got '$got_branch')"
  [ "$(_read_fragment_field "$F" paused_cause)" = "resume-blocked-branch-divergence" ] \
    && ok "resume.sh: paused_cause updated as intended" || bad "paused_cause should be updated"
) || true

echo "[1c] pause-retry.sh: a quote-bearing note survives an _append_retry carry-forward (FR-39)"
( D="$ROOT/1c"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  F="$D/state.d/0001-alpha.json"
  _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 building build \
    1000 1000 "$BR" "$PRURL" "$LOG" "$NOTE" "" "" "" ""
  # _append_retry reads note off disk and round-trips it via _write_tdd_fragment
  # while splicing a retries[] entry — the pause-retry.sh read site A10/A5 bit.
  _append_retry 0001-alpha verify-runtime 1 30
  got_note="$(_read_fragment_field "$F" note)"
  got_branch="$(_read_fragment_field "$F" branch)"
  [ "$got_note" = "$NOTE" ] \
    && ok "note survives _append_retry byte-intact (pause-retry.sh read fixed)" \
    || bad "note must survive _append_retry intact (got '$got_note')"
  [ "$got_branch" = "$BR" ] && ok "pause-retry.sh: quote-free branch unchanged" || bad "branch changed (got '$got_branch')"
  grep -q '"gate":"verify-runtime","count":1' "$F" \
    && ok "pause-retry.sh: retries[] entry appended as intended" || bad "retries[] entry should be appended"
) || true

echo "[2] grep invariant: zero inline [^\"]* free-text fragment readers remain in the three carry-forward libs"
( # The inline free-text string-reader signature: sed -n 's/.*"<field>":"\([^"]*\)".*/\1/p'.
  # The `":"` (colon-quote) distinguishes it from the array readers (`":\[`) and the
  # numeric readers (`":\([0-9]`), which are explicitly out of scope and untouched.
  pat='sed -n .s/\.\*"[A-Za-z0-9_]+":"'
  n=0
  for L in "$REPO/scripts/lib/state.sh" "$REPO/scripts/lib/resume.sh" "$REPO/scripts/lib/pause-retry.sh"; do
    # grep -c prints the count on stdout and exits 1 when it is 0; command
    # substitution captures the "0" regardless, so no `|| true` is needed.
    c="$(grep -cE "$pat" "$L" 2>/dev/null)"; n=$(( n + ${c:-0} ))
  done
  [ "$n" -eq 0 ] \
    && ok "no inline [^\"]* free-text fragment reader remains in state.sh/resume.sh/pause-retry.sh" \
    || bad "an inline [^\"]* free-text fragment reader still remains in the three libs (count=$n)"
  # Positive control: the SAME pattern still matches the out-of-scope renderer
  # scripts/status.sh (TDD 0051 §Elephants — its display-only inline reads are a
  # separate concern, deliberately untouched), proving the grep is live so a zero
  # in the libs is a real invariant, not a dead-pattern artifact.
  sc="$(grep -cE "$pat" "$REPO/scripts/status.sh" 2>/dev/null)"
  [ "${sc:-0}" -gt 0 ] \
    && ok "positive control: the reader pattern is live (still matches the out-of-scope status.sh)" \
    || bad "positive control failed: the grep pattern matched nothing in status.sh (pattern may be dead)"
) || true

echo "[3] control-flow: an embedded quote in note does not alter the terminal halt state"
( D="$ROOT/3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # Two fragments identical except the note's embedded quote. The run routes by
  # status / halt_cause / paused_cause / halt_next_actions (all quote-free); a
  # truncation-corrupted note must not perturb those control-flow comparands.
  FQ="$D/state.d/0001-q.json"; FP="$D/state.d/0001-p.json"
  _write_tdd_fragment 0001-q 1 docs/tdd/0001-q.md 1 building build 1000 1000 "$BR" "" "$LOG" "$NOTE" "" "" "" ""
  _write_tdd_fragment 0001-p 1 docs/tdd/0001-p.md 1 building build 1000 1000 "$BR" "" "$LOG" "plain note no quote" "" "" "" ""
  set_halt_cause 0001-q ratelimit
  set_halt_cause 0001-p ratelimit
  sig() { printf '%s|%s|%s|%s' \
    "$(_read_fragment_field "$1" status)" "$(_read_fragment_field "$1" halt_cause)" \
    "$(_read_fragment_field "$1" paused_cause)" "$(_read_fragment_array_csv "$1" halt_next_actions)"; }
  [ "$(sig "$FQ")" = "$(sig "$FP")" ] \
    && ok "embedded quote leaves the terminal control-flow state identical (status/halt_cause/paused_cause/next-actions)" \
    || bad "embedded quote changed the terminal state ('$(sig "$FQ")' vs '$(sig "$FP")')"
) || true

echo "[4] state.sh: the stage null-guard collapse preserves stage:null -> empty (set_tdd_meta)"
( D="$ROOT/4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  F="$D/state.d/0001-alpha.json"
  # Seed a fragment whose stage is the JSON null literal (an empty stage arg makes
  # _write_tdd_fragment emit `"stage":null`). The old code guarded this with
  # `if grep -q '"stage":null' ...; then stage=""`; the collapse relies on
  # _read_fragment_field returning empty for a null/absent field. Pin that the
  # collapsed reader still yields stage="" so set_tdd_meta re-writes `"stage":null`.
  _write_tdd_fragment 0001-alpha 1 docs/tdd/0001-alpha.md 1 building "" \
    1000 1000 "$BR" "" "$LOG" ""
  grep -q '"stage":null' "$F" || { bad "seed precondition: fragment should carry stage:null"; exit 0; }
  set_tdd_meta 0001-alpha branch=feat/keep
  got_stage="$(_read_fragment_field "$F" stage)"
  [ -z "$got_stage" ] \
    && ok "stage:null reads back as empty through the collapsed guard" \
    || bad "stage:null must read back empty (got '$got_stage')"
  grep -q '"stage":null' "$F" \
    && ok "set_tdd_meta re-writes stage:null (empty stage -> JSON null, not \"\" or \"null\")" \
    || bad "set_tdd_meta should preserve the JSON null stage literal"
) || true

# §W: dogfood (TDD 0038 §3 wire-in rule) — registering this eval in the aggregator
# adds an SCQ_FAIL accumulator to its final AND-chain, so the aggregator now exits
# non-zero on a new condition. Drive the REAL extracted chain with every accumulator
# green EXCEPT this eval's, stubbed to fail: before the wire-in the chain never
# references SCQ_FAIL and evaluates true (RED); after, it includes the term and
# evaluates false (GREEN).
echo "[§W] dogfood: wiring this eval into the aggregator makes its exit go non-zero when the eval fails"
( AGG="$REPO/tests/implement-gate.test.sh"
  if [ ! -r "$AGG" ]; then bad "INFRA: §W — aggregator unreadable: $AGG"; exit 0; fi
  # Structural: the new eval is registered (run) in the aggregator. Anchored on the
  # eval filename so an unwired aggregator is RED.
  grep -q 'state-carryforward-quotesafe\.test\.sh' "$AGG" 2>/dev/null \
    && ok "the new eval is wired into the aggregator (registration present)" \
    || bad "the new eval must be registered in the aggregator"
  # Behavioral: extract the aggregator's real final AND-chain verbatim and evaluate
  # it against stub integers (no recursion into the sub-evals).
  chain="$(grep -aE '^\[ "\$FAIL" -eq 0 \] &&' "$AGG" | tail -1)"
  if [ -z "$chain" ]; then bad "INFRA: §W — could not locate the aggregator final AND-chain"; exit 0; fi
  drive_rc="$(
    set +u
    for v in $(printf '%s' "$chain" | grep -aoE '\$[A-Za-z_][A-Za-z0-9_]*' | tr -d '$' | sort -u); do
      eval "$v=0"
    done
    SCQ_FAIL=1
    eval "$chain"; echo $?
  )"
  [ "$drive_rc" != "0" ] \
    && ok "aggregator final AND-chain goes non-zero when the new eval fails (wire-in propagates)" \
    || bad "aggregator AND-chain must be non-zero with SCQ_FAIL=1 (got rc=$drive_rc)"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== state-carryforward-quotesafe eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

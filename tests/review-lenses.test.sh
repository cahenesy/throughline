#!/usr/bin/env bash
# review-lenses.test.sh — eval for TDD 0045 (review-gate intent-conformance +
# policy-shadow lenses; FR-10, FR-15(d), FR-15; ADR 0005, 0006).
#
# Two review lenses sharpen the independent review gate (gate 4) WITHOUT adding
# a gate (ADR 0005) and WITHOUT changing the REVIEW_RESULT: verdict contract:
#
#   §1 intent-conformance lens: for each in-scope FR/ADR constraint (the TDD's
#      `PRD refs` + `ADR constraints`, NOT the whole repo), the reviewer locates
#      the enforcement point in the scoped diff or establishes its provable
#      absence; documented-but-unenforced is a finding; evidence must cite BOTH
#      sides (ADR 0006); severity by behavioral boundary (intent-unenforced);
#      explicit scope guard against out-of-scope blocking.
#   §2 policy-shadow lens: a test asserting an extracted helper in isolation is
#      a finding ONLY when the reviewer can NAME the real enforcement path
#      (<file>:<line> where the framework should call the helper) AND show the
#      test misses it; no concrete gap -> NO finding (grounded, ADR 0006);
#      severity major with pattern_tags [policy-shadow], raised against the
#      test file's region.
#   §3 control: the REVIEW_RESULT: verdict contract is byte-identical to the
#      pinned pre-lens text — the lenses added analyses, they did not alter
#      the verdict block (ADR 0005: no new gate, authority unchanged).
#   §W dogfood: wiring this eval into the aggregator makes the aggregator's
#      final AND-chain go non-zero when this eval fails (TDD 0038 §3 rule)
#
# Observation point per the TDD's verification plan: render the prompt the
# review `claude -p` actually receives via _render_review_prompt (the same path
# the gate uses) and grep the RENDERED output — not the raw template — so a
# placeholder regression cannot hide a missing clause.
#
# Run: bash tests/review-lenses.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# render_prompt — produce the rendered review prompt exactly as the gate does
# (source the runner, call _render_review_prompt with fixture scope args).
# Echoes the rendered prompt; empty output marks an infra failure the sections
# fail-closed on.
render_prompt() {
  local d="$1" out
  mkdir -p "$d/state.d"
  export STATE_DIR="$d/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$d" RTMPL="$REPO/scripts/review-prompt.md"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || return 1
  out="$(_render_review_prompt docs/tdd/0045-x.md base111 head222 "build/ci/0045-x" "")" || return 1
  printf '%s' "$out"
}

# out_has <ERE> <label> — fail-closed grep against the rendered prompt in $OUT.
out_has() { printf '%s\n' "$OUT" | grep -qE "$1" && ok "$2" || bad "$2 (expected /$1/ in rendered prompt)"; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"; rm -f "$RESULTS"' EXIT

# ===========================================================================
# §1: the rendered prompt carries the intent-conformance lens — heading, the
# in-scope constraint-set domain, the documented-but-unenforced rule, the
# both-sides citation rule (ADR 0006), boundary severity with the
# intent-unenforced tag, and the scope guard.
echo "[§1] rendered prompt: intent-conformance lens (FR-10 / FR-15(d))"
( OUT="$(render_prompt "$ROOT/s1")"
  if [ -z "$OUT" ]; then bad "INFRA: §1 — could not render the review prompt"; exit 0; fi
  out_has '^## Lens: intent-conformance \(FR-10 / FR-15\(d\)\)' \
    "lens section heading present"
  out_has 'PRD refs' "domain names the TDD's PRD refs"
  out_has 'ADR constraints' "domain names the TDD's ADR constraints"
  out_has 'NOT every constraint in the repo' \
    "domain excludes repo-wide constraints (in-scope set only)"
  out_has 'enforcement point in the scoped diff|locate its enforcement point' \
    "per-constraint duty: locate the enforcement point"
  out_has 'provable absence|prove its absence' \
    "per-constraint duty: or establish provable absence"
  out_has 'Documented-but-unenforced is a finding' \
    "documented-but-unenforced rule present"
  out_has 'Cite both sides \(ADR 0006\)' \
    "both-sides citation rule present (ADR 0006)"
  out_has 'quote the documenting line' \
    "side 1: verbatim quote of the documenting FR/ADR/TDD line"
  out_has 'name the code location that should enforce it' \
    "side 2: named code location that should enforce it"
  out_has 'Severity by boundary' "boundary-severity rule present"
  out_has 'pattern_tags: \[intent-unenforced\]' \
    "boundary-crossing mismatch tagged intent-unenforced"
  out_has '`blocker`/`major` with' \
    "boundary-crossing mismatch is blocker/major"
  out_has 'redundant-doc mismatch is `minor`' \
    "cosmetic/redundant-doc mismatch is minor"
  out_has 'Scope guard' "scope-guard rule present"
  out_has 'never block a small diff for an unrelated repo-wide constraint' \
    "scope guard: no blocking on unrelated repo-wide constraints"
  # Placement: the lens must come AFTER the Grounding section (so it inherits
  # the grounding rules) and BEFORE the Prior-addressed-patterns section.
  order="$(printf '%s\n' "$OUT" | grep -nE '^## (Grounding|Lens: intent-conformance|Prior addressed patterns)' \
    | sed -E 's/:.*//' | paste -sd' ' -)"
  # shellcheck disable=SC2086 # intentional word-split: $order is "N N N" line numbers
  set -- $order
  if [ "$#" -eq 3 ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ]; then
    ok "lens placed after Grounding and before Prior-addressed-patterns (inherits grounding)"
  else
    bad "lens must sit between Grounding and Prior-addressed-patterns (heading lines: $order)"
  fi
) || true

# ===========================================================================
# §2: the rendered prompt carries the policy-shadow lens — heading, the
# helper-vs-framework-path distinction, the name-the-real-path requirement,
# the no-finding-without-a-concrete-gap rule (the false-positive guard), and
# the severity rule (major, policy-shadow tag, test file's region).
echo "[§2] rendered prompt: policy-shadow lens (FR-15)"
( OUT="$(render_prompt "$ROOT/s2")"
  if [ -z "$OUT" ]; then bad "INFRA: §2 — could not render the review prompt"; exit 0; fi
  out_has '^## Lens: policy-shadow tests \(FR-15\)' \
    "lens section heading present"
  out_has 'framework actually invokes that helper' \
    "duty: check the framework actually invokes the helper on the governed path"
  out_has 'Name the real enforcement path' \
    "name-the-real-path requirement present"
  out_has 'where the framework should call the helper' \
    "the named location is where the framework should call the helper"
  out_has 'without driving the framework entry point' \
    "the shown gap: test calls the helper without driving the framework entry point"
  out_has 'raise NO finding' \
    "no-finding-without-a-concrete-gap rule present (false-positive guard)"
  out_has 'pattern_tags: \[policy-shadow\]' \
    "shadow test for a governance/gate behavior tagged policy-shadow"
  out_has 'is `major` with' \
    "shadow test for a governance/gate behavior is major"
  out_has "against the test file's region" \
    "finding raised against the test file's region"
  # Placement: after the intent-conformance lens, before Prior-addressed-
  # patterns — both lenses sit under the Grounding section's rules.
  order="$(printf '%s\n' "$OUT" | grep -nE '^## (Lens: intent-conformance|Lens: policy-shadow|Prior addressed patterns)' \
    | sed -E 's/:.*//' | paste -sd' ' -)"
  # shellcheck disable=SC2086 # intentional word-split: $order is "N N N" line numbers
  set -- $order
  if [ "$#" -eq 3 ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ]; then
    ok "lens placed after intent-conformance and before Prior-addressed-patterns"
  else
    bad "lens must sit between the intent-conformance lens and Prior-addressed-patterns (heading lines: $order)"
  fi
) || true

# ===========================================================================
# §3: control — the verdict contract is UNCHANGED. The lenses add finding
# categories under the existing severity model; they must not touch the
# `## Verdict` block (ADR 0005: gate authority unchanged, no new gate). Pin
# the whole rendered verdict block byte-for-byte so any drift — accidental or
# "helpful" — turns this control red.
echo "[§3] control: REVIEW_RESULT: verdict contract unchanged by the lenses"
( OUT="$(render_prompt "$ROOT/s3")"
  if [ -z "$OUT" ]; then bad "INFRA: §3 — could not render the review prompt"; exit 0; fi
  verdict="$(printf '%s\n' "$OUT" | sed -n '/^## Verdict$/,$p')"
  expected='## Verdict

Then decide and end your message with EXACTLY one verdict line:
- `REVIEW_RESULT: BLOCK <one-line reason>` — if there is any blocker- or
  major-severity correctness/security finding, OR the change drifts from the TDD
  or an accepted ADR. This stops the runner from marking the TDD implemented.
- `REVIEW_RESULT: PASS` — otherwise. Minor/nit findings do not block; list them
  but pass.

Print the full findings list ABOVE the verdict line. Do not invent issues to
look thorough — "no material findings" is a valid, expected result.'
  if [ "$verdict" = "$expected" ]; then
    ok "rendered ## Verdict block is byte-identical to the pinned pre-lens contract"
  else
    bad "verdict block drifted from the pinned contract (got: [$verdict])"
  fi
  # The verdict block must also be the LAST section — neither lens may trail it.
  printf '%s\n' "$OUT" | sed -n '/^## Verdict$/,$p' | grep -qE '^## Lens:' \
    && bad "a lens section trails the verdict block" \
    || ok "no lens section trails the verdict block"
) || true

# ===========================================================================
# §W: dogfood (TDD 0038 §3 wire-in rule) — registering this eval in the
# aggregator adds an RLNS_FAIL accumulator to its final AND-chain, so the
# aggregator now exits non-zero on a new condition. Drive the REAL extracted
# chain with every accumulator green EXCEPT this eval's, stubbed to fail:
# before the wire-in the chain never references RLNS_FAIL and evaluates true
# (RED); after, it includes the term and evaluates false (GREEN).
echo "[§W] dogfood: wiring this eval into the aggregator makes its exit go non-zero when the eval fails"
( AGG="$REPO/tests/implement-gate.test.sh"
  if [ ! -r "$AGG" ]; then bad "INFRA: §W — aggregator unreadable: $AGG"; exit 0; fi
  # Structural: the new eval is registered (run) in the aggregator. Anchored on
  # the eval filename so an unwired aggregator is RED. Fail-closed on grep error.
  grep -qE 'review-lenses\.test\.sh' "$AGG" \
    && ok "the new eval is wired into the aggregator (registration present)" \
    || bad "the new eval is wired into the aggregator (expected /review-lenses\\.test\\.sh/ in $AGG)"
  # Behavioral: extract the aggregator's real final AND-chain verbatim and
  # evaluate it against stub integers (no recursion into the sub-evals).
  chain="$(grep -aE '^\[ "\$FAIL" -eq 0 \] &&' "$AGG" | tail -1)"
  if [ -z "$chain" ]; then bad "INFRA: §W — could not locate the aggregator final AND-chain"; exit 0; fi
  drive_rc="$(
    set +u
    for v in $(printf '%s' "$chain" | grep -aoE '\$[A-Za-z_][A-Za-z0-9_]*' | tr -d '$' | sort -u); do
      eval "$v=0"
    done
    RLNS_FAIL=1
    eval "$chain"; echo $?
  )"
  [ "$drive_rc" != "0" ] \
    && ok "aggregator final AND-chain goes non-zero when the new eval fails (wire-in propagates)" \
    || bad "aggregator AND-chain must be non-zero with RLNS_FAIL=1 (got rc=$drive_rc)"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== review-lenses eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

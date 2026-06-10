#!/usr/bin/env bash
# tdd-author-redteam.test.sh — eval for TDD 0047 (tdd-author red-team ranking +
# pre-mortem failure-mode taxonomy; FR-76; ADR 0006).
#
# Observable surface per the TDD's Verification plan: the content of
# skills/tdd-author/SKILL.md (the skill text a tdd-author session loads).
# Built incrementally across TDD 0047's Sequencing items:
#   §1 — the Interrogator-discipline section carries the "Red-team ranking"
#        guidance: rank tracked assumptions by impact × likelihood ×
#        cheapness-to-test, phrase each as a falsifiable "fails if ___"
#        clause, surface the top-ranked few first; advisory ordering only —
#        the completion gate is unchanged.
#   §2 — the pre-mortem failure-mode taxonomy: the template note recommends
#        Real risks / Overblown risks / Unspoken risks (elephants) within the
#        existing `## Failure modes & edge cases` section, the step-7a
#        self-review checklist gains the matching line; control: tdd-lint.sh's
#        required-section set is NOT expanded to demand a taxonomy sub-heading
#        (the taxonomy stays advisory).
#   §W — dogfood: the aggregator's final AND-chain goes non-zero when this
#        eval fails (TDD 0038 §3 wire-in rule).
#
# L-001/L-002 guards (matched learnings): SKILL.md existence + readability is
# asserted BEFORE any content grep and fails with an INFRA-prefixed message
# (distinct from a content-failure message); every presence assertion is a
# direct positive `grep -q` (exit 0 = found) — never an inverted `! grep`,
# whose exit-2 on a missing file would read as success.
#
# Run: bash tests/tdd-author-redteam.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/tdd-author/SKILL.md"

command -v grep >/dev/null 2>&1 \
  || { echo "FATAL: INFRA — required tool 'grep' unavailable" >&2; exit 2; }

RESULTS=""
trap 'rm -f "$RESULTS"' EXIT
RESULTS="$(mktemp)" || { echo "FATAL: INFRA — mktemp failed" >&2; exit 2; }
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

# L-002 guard: the observed file must exist and be readable BEFORE any content
# assertion — otherwise every grep below would mis-report an infrastructure
# problem as a content failure.
[ -f "$SKILL" ] \
  || { echo "FATAL: INFRA — SKILL.md not found at $SKILL (infrastructure failure, not a content failure)" >&2; exit 2; }
[ -r "$SKILL" ] \
  || { echo "FATAL: INFRA — SKILL.md not readable at $SKILL (infrastructure failure, not a content failure)" >&2; exit 2; }

# has <literal> <label> — positive presence assertion (L-001: exit 0 = found,
# anything else = FAIL; never inverted, so a read error can never pass).
has() { grep -qF "$1" "$SKILL" && ok "$2" || bad "$2 (expected '$1' in $SKILL)"; }

# ===========================================================================
# §1: the Interrogator-discipline section carries the red-team ranking
# guidance (FR-76; the "fails if ___" falsifiability keeps each ranked
# assumption grounded per ADR 0006).
echo "[§1] red-team ranking guidance in the Interrogator-discipline section (FR-76)"
has 'Red-team ranking' \
  "the 'Red-team ranking' bullet is present"
has 'impact × likelihood × cheapness-to-test' \
  "ranking criteria: impact × likelihood × cheapness-to-test"
has 'fails if ___' \
  "falsifiable 'fails if ___' phrasing required for each ranked assumption"
has 'top-ranked few' \
  "the top-ranked few are surfaced to the user first"
has 'does not change the completion gate' \
  "ranking is advisory ordering — the completion gate is unchanged"

# ===========================================================================
# §2: the pre-mortem failure-mode taxonomy — template note + matching step-7a
# self-review line (FR-76). The taxonomy is advisory structure WITHIN the
# existing `## Failure modes & edge cases` section, never a lint-required
# sub-heading.
echo "[§2] failure-mode taxonomy note + self-review line; tdd-lint set unchanged (FR-76)"
has 'Real risks' \
  "taxonomy note names 'Real risks' (genuine, with mitigations)"
has 'Overblown risks' \
  "taxonomy note names 'Overblown risks' (named and deflated)"
has 'Unspoken risks (elephants)' \
  "taxonomy note names 'Unspoken risks (elephants)' (the failure nobody stated)"
has 'not a required sub-heading' \
  "taxonomy is guidance within the section, not a required sub-heading"
has 'Failure-modes taxonomy' \
  "step-7a self-review checklist gained the 'Failure-modes taxonomy' item"
has 'states why none applies' \
  "self-review line allows the explicit no-unspoken-risk-applies escape"

# Control: tdd-lint.sh's required-section set was NOT expanded — the taxonomy
# stays advisory. Readability is asserted first (L-002), the positive control
# proves we read the lint's real required-section logic, and the absence
# checks use an explicit grep-rc case (exit 1 = correctly absent; exit 0 =
# wrongly demanded; exit >=2 = read error) — never a bare inverted `! grep`
# that would false-pass on a missing file (L-001).
TDD_LINT="$REPO/scripts/lib/tdd-lint.sh"
if [ ! -f "$TDD_LINT" ] || [ ! -r "$TDD_LINT" ]; then
  bad "INFRA: tdd-lint.sh not readable at $TDD_LINT (control check could not run)"
else
  grep -qF '## Verification plan' "$TDD_LINT" \
    && ok "control: tdd-lint.sh still carries its required-section checks" \
    || bad "control: tdd-lint.sh required-section logic not found (wrong file?)"
  for _lit in 'Real risks' 'Overblown' 'Unspoken'; do
    grep -qF "$_lit" "$TDD_LINT"; _rc=$?
    case "$_rc" in
      1) ok  "control: tdd-lint.sh does not demand '$_lit' (taxonomy stays advisory)" ;;
      0) bad "control: tdd-lint.sh must NOT be expanded to demand '$_lit'" ;;
      *) bad "INFRA: control check could not read $TDD_LINT (grep exit $_rc)" ;;
    esac
  done
fi

# ===========================================================================
# §W: dogfood (TDD 0038 §3) — drive the aggregator's REAL extracted final
# AND-chain with this eval's accumulator forced to 1; the chain must go
# non-zero, proving the wire-in propagates a failure of this eval.
echo "[§W] dogfood: wiring this eval into the aggregator makes its exit go non-zero when the eval fails"
( AGG="$REPO/tests/implement-gate.test.sh"
  if [ ! -r "$AGG" ]; then bad "INFRA: §W — aggregator unreadable: $AGG"; exit 0; fi
  grep -qE 'tdd-author-redteam\.test\.sh' "$AGG" \
    && ok "the new eval is wired into the aggregator (registration present)" \
    || bad "the new eval is wired into the aggregator (expected /tdd-author-redteam\\.test\\.sh/ in $AGG)"
  chain="$(grep -aE '^\[ "\$FAIL" -eq 0 \] &&' "$AGG" | tail -1)"
  if [ -z "$chain" ]; then bad "INFRA: §W — could not locate the aggregator final AND-chain"; exit 0; fi
  drive_rc="$(
    set +u
    for v in $(printf '%s' "$chain" | grep -aoE '\$[A-Za-z_][A-Za-z0-9_]*' | tr -d '$' | sort -u); do
      eval "$v=0"
    done
    RTM_FAIL=1
    eval "$chain"; echo $?
  )"
  [ "$drive_rc" != "0" ] \
    && ok "aggregator final AND-chain goes non-zero when the new eval fails (wire-in propagates)" \
    || bad "aggregator AND-chain must be non-zero with RTM_FAIL=1 (got rc=$drive_rc)"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== tdd-author-redteam eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

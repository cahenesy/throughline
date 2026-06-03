#!/usr/bin/env bash
# evaluation-rubric.test.sh — eval for TDD 0029 (evaluation-rubric co-creation).
#
# PRD refs: FR-77.
#
# Built incrementally across TDD 0029's Sequencing items. This file implements the
# MECHANICAL grep surface of the TDD's Verification plan §1–§3:
#   §1 — Rubric-phase block present in BOTH authoring skills: the literal heading
#        "Rubric co-creation (FR-77)", the skeptical-grading-expert posture switch,
#        the strict-ordering precondition (open-assumptions dispositioned first),
#        the table column spec "Criterion | High-quality | Acceptable | Failing",
#        the co-creation flow anchor ("Iterate until approved"), the persistence
#        instruction naming "## Evaluation rubric", the per-skill seed criteria, and
#        the crash-safety draft header ("rubric: ...").
#   §2 — Template line present: each skill's artifact template gains an
#        "## Evaluation rubric" line (anchored on the distinctive parenthetical
#        "co-created success criteria").
#   §3 — Design-reviewer consumption present: grade against EACH rubric row, the
#        failing-grade-is-BLOCK rule, the absence-is-a-finding rule keyed on NEWLY
#        AUTHORED artifacts, and the rubric-vs-standing-criteria precedence rule.
# Plus the per-skill specifics: tdd-author duplicates ONE rubric into EACH TDD of
# the set and its step-7b note tells the design-reviewer a rubric is present.
#
# The §4/§5 behavioral observations (rubric reaches the artifact and the gate cites
# it; the missing-rubric finding) are session-driven and exercised by the
# runtime-verify gate against this TDD's own build — not re-driven here. This file
# is the build-time regression surface (mechanical greps over the three modified
# prompt files), per the TDD's note that §1–§3 are the mechanical regression surface.
#
# Run: bash tests/evaluation-rubric.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PRD_SKILL="$REPO/skills/prd-author/SKILL.md"
# TDD_SKILL (step 2) and REVIEWER (step 3) are declared in the sections that use
# them, so each commit stays free of unused-variable warnings.

# Distinguish an infrastructure failure (a missing tool / unreadable file) from a
# genuine content failure: a missing grep or an empty file would otherwise feed
# every assertion an empty input and mis-report a content problem. Fail fatally up
# front instead (the recurrent false-result-on-infrastructure-failure class).
for _t in grep awk; do
  command -v "$_t" >/dev/null 2>&1 || { echo "FATAL: required tool '$_t' unavailable" >&2; exit 2; }
done

RESULTS="$(mktemp)" || { echo "FATAL: mktemp failed" >&2; exit 2; }
export RESULTS
trap 'rm -f "$RESULTS"' EXIT
ok()  { printf 'ok\n'   >>"$RESULTS" || { echo "FATAL: cannot record result" >&2; exit 2; }; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS" || { echo "FATAL: cannot record result" >&2; exit 2; }; printf '  FAIL — %s\n' "$1"; }

# check_phase <skill-file> <label> <persistence-anchor> <seed1> <seed2> — the §1
# mechanical surface that is identical in shape for both skills (the rubric-phase
# heading, posture switch, precondition, table spec, co-creation flow, persistence,
# and crash-safety draft header). The persistence anchor (the distinctive
# per-skill phrase that proves the rubric is written into the artifact) and the two
# seed-criteria anchors differ per skill, so they are arguments.
check_phase() {  # <file> <label> <persistence-anchor> <seed1> <seed2>
  local f="$1" lbl="$2" persist="$3" seed1="$4" seed2="$5"
  [ -f "$f" ] || { bad "$lbl: SKILL.md not found at $f"; return; }
  [ -r "$f" ] || { bad "$lbl: SKILL.md not readable at $f"; return; }

  # §1 — rubric-phase block present.
  grep -qF 'Rubric co-creation (FR-77)' "$f" \
    && ok "$lbl §1: 'Rubric co-creation (FR-77)' heading present" \
    || bad "$lbl §1: missing the literal 'Rubric co-creation (FR-77)' heading"
  grep -qiF 'skeptical grading expert' "$f" \
    && ok "$lbl §1: skeptical-grading-expert posture switch present" \
    || bad "$lbl §1: missing the skeptical-grading-expert posture switch"
  grep -qiF 'dispositioned' "$f" && grep -qiF 'open-assumptions' "$f" \
    && ok "$lbl §1: strict-ordering precondition (open-assumptions dispositioned first) present" \
    || bad "$lbl §1: missing the strict-ordering precondition (open-assumptions dispositioned first)"
  grep -qF 'Criterion | High-quality | Acceptable | Failing' "$f" \
    && ok "$lbl §1: rubric table column spec present" \
    || bad "$lbl §1: missing the rubric table column spec 'Criterion | High-quality | Acceptable | Failing'"
  grep -qiF 'Iterate until approved' "$f" \
    && ok "$lbl §1: AskUserQuestion co-creation flow anchor ('Iterate until approved') present" \
    || bad "$lbl §1: missing the co-creation flow anchor 'Iterate until approved'"
  grep -qF '## Evaluation rubric' "$f" \
    && ok "$lbl §1: persistence names the '## Evaluation rubric' section" \
    || bad "$lbl §1: persistence must name the '## Evaluation rubric' section"
  grep -qF "$persist" "$f" \
    && ok "$lbl §1: persistence instruction present ('$persist')" \
    || bad "$lbl §1: missing the persistence instruction anchor '$persist'"
  grep -qiF "$seed1" "$f" && grep -qiF "$seed2" "$f" \
    && ok "$lbl §1: seed criteria present ('$seed1', '$seed2')" \
    || bad "$lbl §1: missing seed criteria ('$seed1', '$seed2')"
  grep -qF 'tl_draft_append_elicit' "$f" && grep -qF 'rubric:' "$f" \
    && ok "$lbl §1: crash-safety draft header ('rubric:' via tl_draft_append_elicit) present" \
    || bad "$lbl §1: missing crash-safety draft persistence ('rubric:' header via tl_draft_append_elicit)"

  # §2 — template line present (distinctive 'co-created success criteria' anchor so
  # this does not pass vacuously on the §1 persistence mention of the section name).
  grep -qF 'co-created success criteria' "$f" \
    && ok "$lbl §2: template gained an '## Evaluation rubric' line" \
    || bad "$lbl §2: artifact template must gain an '## Evaluation rubric' line (anchor: 'co-created success criteria')"
}

# --- prd-author (FR-77) -------------------------------------------------------
echo "[prd-author] rubric-phase block + template line (FR-77)"
check_phase "$PRD_SKILL" "prd-author" "Persist the approved rubric" \
  "acceptance-criterion observability" "non-goal explicitness"
# prd-author persists under the fixed draft header 'rubric: PRD'.
grep -qF 'rubric: PRD' "$PRD_SKILL" \
  && ok "prd-author §1: fixed crash-safety header 'rubric: PRD' present" \
  || bad "prd-author §1: missing the fixed crash-safety draft header 'rubric: PRD'"

# --- report -------------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== evaluation-rubric eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

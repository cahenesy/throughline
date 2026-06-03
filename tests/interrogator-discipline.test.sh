#!/usr/bin/env bash
# interrogator-discipline.test.sh — eval for TDD 0028 (interrogator discipline for
# authoring interviews).
#
# PRD refs: FR-75 (prd-author), FR-76 (tdd-author).
#
# Built incrementally across TDD 0028's Sequencing items. This file currently
# implements the MECHANICAL grep surface of the TDD's Verification plan §1–§3:
#   §1 — Interrogator block present: the literal section heading
#        "Interrogator discipline (FR-75/76)", the anti-sycophancy anchor
#        "you are not being helpful", the "OPEN ASSUMPTIONS" tracking anchor, the
#        "resolved:" / "waived:" disposition forms, and the PR-body section name
#        "Open assumptions & waivers".
#   §2 — Completion gate present: the interview is "NOT complete" while any entry
#        lacks a disposition.
#   §3 — Draft integration present: the `assumption:` header-prefix used with
#        `tl_draft_append_elicit`, plus the resume-parse instruction (anchors
#        `tl_draft_read` and "latest entry per header").
# Plus the per-skill specifics: prd-author folds waived items into the PRD's
# `## Open questions`; tdd-author challenges the PRD AND its own decomposition and
# drops the subsumed one-sentence "CHALLENGE the PRD" directive; both gain the
# self-review item.
#
# The §4/§5 behavioral observations (record reaches the PR body; zero-assumptions
# path) are session-driven and exercised by the runtime-verify gate against this
# TDD's own build — not re-driven here. This file is the build-time regression
# surface (mechanical greps over the two SKILL.md files), per the TDD's note that
# §1–§3 are the mechanical regression surface.
#
# Run: bash tests/interrogator-discipline.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PRD_SKILL="$REPO/skills/prd-author/SKILL.md"

# Distinguish an infrastructure failure (a missing tool / unreadable skill) from a
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

# check_common <skill-file> <fr-token> <label> — the §1–§3 mechanical surface that
# is identical for both skills (the interrogator block, completion gate, and draft
# integration). <fr-token> is "FR-75" (prd-author) or "FR-76" (tdd-author): the
# block heading carries it, so the assertion is skill-specific via this argument.
check_common() {  # <file> <fr> <label>
  local f="$1" fr="$2" lbl="$3"
  [ -f "$f" ] || { bad "$lbl: SKILL.md not found at $f"; return; }
  [ -r "$f" ] || { bad "$lbl: SKILL.md not readable at $f"; return; }

  # §1 — interrogator block present.
  grep -qF "Interrogator discipline ($fr)" "$f" \
    && ok "$lbl §1: 'Interrogator discipline ($fr)' heading present" \
    || bad "$lbl §1: missing the literal 'Interrogator discipline ($fr)' heading"
  grep -qF 'you are not being helpful' "$f" \
    && ok "$lbl §1: anti-sycophancy anchor ('you are not being helpful') present" \
    || bad "$lbl §1: missing the verbatim anti-sycophancy anchor 'you are not being helpful'"
  grep -qF 'OPEN ASSUMPTIONS' "$f" \
    && ok "$lbl §1: 'OPEN ASSUMPTIONS' tracking anchor present" \
    || bad "$lbl §1: missing the 'OPEN ASSUMPTIONS' tracking anchor"
  grep -qF 'resolved:' "$f" && grep -qF 'waived:' "$f" \
    && ok "$lbl §1: both 'resolved:' and 'waived:' disposition forms present" \
    || bad "$lbl §1: both 'resolved:' and 'waived:' disposition forms must be named"
  grep -qF 'Open assumptions & waivers' "$f" \
    && ok "$lbl §1: PR-body section name 'Open assumptions & waivers' present" \
    || bad "$lbl §1: missing the PR-body section name 'Open assumptions & waivers'"

  # §2 — completion gate present (anchor "NOT complete").
  grep -qF 'NOT complete' "$f" \
    && ok "$lbl §2: completion gate present ('NOT complete' anchor)" \
    || bad "$lbl §2: missing the completion gate ('NOT complete' while any entry lacks a disposition)"

  # §3 — draft integration: the assumption: header prefix used with the existing
  # tl_draft_append_elicit helper, AND the resume-parse instruction.
  grep -qF 'tl_draft_append_elicit' "$f" && grep -qF 'assumption:' "$f" \
    && ok "$lbl §3: assumption: header-prefix used with tl_draft_append_elicit" \
    || bad "$lbl §3: must persist assumptions via tl_draft_append_elicit with an 'assumption:' header prefix"
  grep -qF 'tl_draft_read' "$f" && grep -qiF 'latest entry per header' "$f" \
    && ok "$lbl §3: resume-parse instruction present (tl_draft_read + latest entry per header)" \
    || bad "$lbl §3: missing the resume-parse instruction (tl_draft_read; latest entry per header is authoritative)"

  # §4 — self-review item naming the open-assumptions record.
  grep -qiF 'Open-assumptions record' "$f" \
    && ok "$lbl §4: self-review checklist gained the open-assumptions-record item" \
    || bad "$lbl §4: self-review checklist must gain an 'Open-assumptions record' item"
}

# --- prd-author (FR-75) -------------------------------------------------------
echo "[prd-author] interrogator block, completion gate, draft integration, self-review (FR-75)"
check_common "$PRD_SKILL" "FR-75" "prd-author"
# prd-author specific: waived items are ALSO folded into the PRD's own
# `## Open questions` section so the artifact records what was deferred.
{ grep -qF 'Open questions' "$PRD_SKILL" && grep -qiF 'waived' "$PRD_SKILL"; } \
  && ok "prd-author: waived items folded into the PRD's ## Open questions section" \
  || bad "prd-author: waived items must ALSO be appended to the PRD's ## Open questions section"

# --- report -------------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== interrogator-discipline eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

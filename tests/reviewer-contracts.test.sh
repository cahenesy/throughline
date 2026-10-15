#!/usr/bin/env bash
# reviewer-contracts.test.sh — eval for TDD 0075 / FR-108, FR-109, FR-110,
# FR-15(d), FR-10, FR-87: the shared reviewer contract.
#
# Observations 1–4b are text checks by necessity: a reviewer is model prose,
# so its contract is the prompt / skill text. Its behaviour is observed by
# parent-dispatched fixture runs (obs 6–8), never here.
#   1  design-reviewer: trace, [unverified], alternatives table, findings line,
#      terminology/duplication passes, Non-findings, METRICS, verdict.
#   2  build-reviewer: frontmatter, inputs, ten rule headings, pre-existing
#      rule (caller/callee clause), FAIL iff rule, REVIEW_RESULT line.
#   3  FR-110 across reviewers + a readable-first negated grep over every
#      prompt file for category-dismissal phrases.
#   4  /build-tdds step 6 records base-sha; step 9 carries the
#      parent-dispatched fixture protocol; step 10 dispatches by
#      agents/build-reviewer.md with no checklist of its own.
#   4b /tdd-author 7b/9 carry trace, tables, METRICS, Non-findings into the
#      design-PR body, holding the report text in-session, never in the draft.
# Every file is asserted readable first, and a missing file is a FAIL (L-001);
# every negated grep first asserts its input is readable (L-011).
#
# Written red-first. Run: bash tests/reviewer-contracts.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DR="$REPO/agents/design-reviewer.md"
BR="$REPO/agents/build-reviewer.md"
UX="$REPO/agents/ux-reviewer.md"
SR="$REPO/agents/security-reviewer.md"
RR="$REPO/agents/requirements-reviewer.md"
IMPL="$REPO/skills/implement/SKILL.md"
TA="$REPO/skills/tdd-author/SKILL.md"
RESULTS=""
cleanup() { [ -n "$RESULTS" ] && rm -f "$RESULTS"; }
trap cleanup EXIT
RESULTS="$(mktemp)"
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
readable() { [ -r "$1" ] && [ -s "$1" ]; }
# norm <file> — the file line-joined with runs of whitespace squeezed, so a
# phrase wrapped across lines still matches.
norm() { tr '\n' ' ' <"$1" | tr -s ' \t' ' '; }
# has <label> <haystack> <needle> — fixed-string containment.
has() { case "$2" in *"$3"*) ok "$1 has '$3'" ;; *) bad "$1 lacks '$3'" ;; esac; }
# section <file> <start-ERE> <end-ERE> — lines from the first start match up
# to (not including) the first end match after it.
section() { awk -v a="$2" -v z="$3" 's && $0 ~ z {exit} $0 ~ a {s=1} s' "$1"; }
# first <file> <fixed> — line number of the first fixed-string match.
first() { grep -nF -m1 -- "$2" "$1" | cut -d: -f1; }

FINDING_TABLE='| Rejected approach | Failure mechanism | Viable alternative | Trade-offs |'
NONFIND_LINE='<label> — "<quoted candidate finding>" — <why set aside>'
NO_DISMISS='race, concurrency, filesystem and security findings are always judged on their merits'
METRICS_LINE='METRICS: traced <a>/<b> requirements; findings blocker=<n> major=<n> minor=<n> nit=<n>'
RULES=(Conformance Deviations Tests Fail-loud Scope Security Trace 'Pre-existing debt' 'Findings and non-findings' Verdict)

# --- obs 1: design-reviewer contract -----------------------------------------
echo "[1] design-reviewer contract (FR-108, FR-110)"
if readable "$DR"; then
  J="$(norm "$DR")"
  for s in '### Simulation trace' '[unverified]' '### Findings' "$FINDING_TABLE" '### Non-findings' \
           "$METRICS_LINE" 'R-n <severity> — <doc:section or file:line> — <finding>' \
           'DESIGN_REVIEW: PASS' 'DESIGN_REVIEW: BLOCK <one-line reason>' \
           'happy, boundary and failure' 'Terminology pass' 'Duplication pass' \
           'cannot be the basis of a PASS' "$NONFIND_LINE" 'pedantic escalation' 'imaginary architecture'; do
    has "[1] design-reviewer" "$J" "$s"
  done
  # Existing passages other evals assert, kept word for word.
  for s in 'Pre-check already ran' 'DESIGN_REVIEW: BLOCK scope-coherence' 'grade on any rubric criterion is a BLOCK' \
           'can never be graded acceptable' 'UX coverage (FR-101)' \
           "You did NOT author this design. You run in a fresh context that is not the author's session; that fresh context is the independence. You may be on the same model as the author."; do
    has "[1] design-reviewer (kept)" "$J" "$s"
  done
  t="$(first "$DR" '### Simulation trace')"; f="$(first "$DR" '### Findings')"
  n="$(first "$DR" '### Non-findings')"; m="$(first "$DR" 'METRICS: traced')"
  v="$(grep -n -- '^- `DESIGN_REVIEW: PASS`' "$DR" | tail -1 | cut -d: -f1)"
  if [ -n "$t" ] && [ -n "$f" ] && [ -n "$n" ] && [ -n "$m" ] && [ -n "$v" ] \
     && [ "$t" -lt "$f" ] && [ "$f" -lt "$n" ] && [ "$n" -lt "$m" ] && [ "$m" -lt "$v" ]; then
    ok "[1] report sections in order: trace ($t) < findings ($f) < non-findings ($n) < METRICS ($m) < verdict ($v)"
  else bad "[1] section order: trace='$t' findings='$f' non-findings='$n' metrics='$m' verdict='$v'"; fi
else bad "[1] infra: $DR missing/unreadable/empty (L-001)"; fi

# --- obs 2: build-reviewer contract ------------------------------------------
echo "[2] build-reviewer contract (FR-109, FR-87)"
if readable "$BR"; then
  head8="$(sed -n '1,8p' "$BR")"
  for s in 'name: build-reviewer' 'tools: Read, Grep, Glob, Bash' 'model: inherit'; do
    printf '%s\n' "$head8" | grep -qxF -- "$s" && ok "[2] frontmatter line '$s'" || bad "[2] frontmatter lacks '$s'"
  done
  J="$(norm "$BR")"
  for r in "${RULES[@]}"; do has "[2] build-reviewer rule heading" "$J" "**$r.**"; done
  for s in 'base-sha' 'implementer' 'runtime-verify report' 'report-file path' 'build worktree' \
           'agents/security-reviewer.md' 'git -C <wt> diff <base-sha>..HEAD' 'git diff -U0 <base-sha>..HEAD' \
           '`pre-existing`' 'caller' 'callee' 'cite the changed line' 'FAIL if and only if' \
           'not labelled `pre-existing`' 'R-n <severity> — <file:line> — <finding>' "$FINDING_TABLE" \
           '### Security' '### Simulation trace' '[unverified]' '### Non-findings' "$NONFIND_LINE" \
           'pedantic escalation' 'imaginary architecture' 'never a FAIL' 'Do not spawn children' \
           'REVIEW_RESULT: PASS' 'REVIEW_RESULT: FAIL' 'merge-base fallback'; do
    has "[2] build-reviewer" "$J" "$s"
  done
  last="$(grep -nE '^ *- `REVIEW_RESULT: (PASS|FAIL)`$' "$BR" | wc -l)"
  [ "$last" -eq 2 ] && ok "[2] both exact REVIEW_RESULT lines are listed" || bad "[2] exact REVIEW_RESULT lines: $last (want 2)"
  hits="$(grep -nEi 'AskUserQuestion|claude -p|grok -p|\bTask tool\b' "$BR")"
  [ -z "$hits" ] && ok "[2] no vendor tool/CLI names (FR-81)" || bad "[2] vendor names: $hits"
else bad "[2] infra: $BR missing/unreadable/empty (L-001)"; fi

# --- obs 3: FR-110 across reviewers ------------------------------------------
echo "[3] FR-110: quote-to-dismiss rule and no category dismissal"
for f in "$DR" "$UX" "$BR" "$RR"; do
  b="$(basename "$f")"
  if readable "$f"; then
    J="$(norm "$f")"
    for s in '### Non-findings' "$NONFIND_LINE" 'pedantic escalation' 'imaginary architecture' "$NO_DISMISS"; do
      has "[3] $b" "$J" "$s"
    done
  else bad "[3] infra: $f missing/unreadable/empty (L-001)"; fi
done
if readable "$UX"; then
  J="$(norm "$UX")"
  has "[3] ux-reviewer.md" "$J" 'R-n <severity> — <file:line or docs/ux path> — <finding>'
  has "[3] ux-reviewer.md (verdict kept)" "$J" 'UX_REVIEW: PASS'
fi
if readable "$SR"; then
  J="$(norm "$SR")"
  has "[3] security-reviewer.md" "$J" 'race, TOCTOU, symlink and path-handling findings are judged on their merits and never dismissed as a category'
else bad "[3] infra: $SR missing/unreadable/empty (L-001)"; fi
# Negated grep over every prompt file: readable first, then case-insensitive.
PHRASES=('synchronous hand-wringing' 'harmless idempotence' 'ignore race' 'ignore races' 'dismiss race'
         'not a real race' 'single-threaded so no race' 'idempotent so safe')
n=0
for f in "$REPO"/agents/*.md; do
  [ -e "$f" ] || continue
  n=$((n + 1))
  if readable "$f"; then
    J="$(norm "$f")"
    lj="$(printf '%s' "$J" | tr '[:upper:]' '[:lower:]')"
    hit=""
    for p in "${PHRASES[@]}"; do case "$lj" in *"$p"*) hit="$hit [$p]" ;; esac; done
    [ -z "$hit" ] && ok "[3] $(basename "$f") has no category-dismissal phrase" \
      || bad "[3] $(basename "$f") dismisses by category:$hit"
  else bad "[3] infra: $f unreadable/empty (L-011)"; fi
done
[ "$n" -ge 5 ] && ok "[3] scanned $n prompt files" || bad "[3] infra: only $n prompt files under agents/"

# --- obs 4: /build-tdds steps 6, 9, 10 ----------------------------------------
echo "[4] /build-tdds steps 6, 9 and 10"
if readable "$IMPL"; then
  S6="$(section "$IMPL" '^## 6\. ' '^## 7\. ' | tr '\n' ' ' | tr -s ' ')"
  S9="$(section "$IMPL" '^## 9\. ' '^## 10\. ' | tr '\n' ' ' | tr -s ' ')"
  S10="$(section "$IMPL" '^## 10\. ' '^## 11\. ' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$S6" ] && [ -n "$S9" ] && [ -n "$S10" ] && ok "[4] steps 6, 9, 10 found" \
    || bad "[4] infra: step sections empty (6='${#S6}' 9='${#S9}' 10='${#S10}')"
  has "[4] step 6" "$S6" 'base-sha=<sha>'
  has "[4] step 6" "$S6" 'git -C "$WT" rev-parse HEAD'
  for s in 'PENDING-PARENT' 'parent-dispatched' 'appends each report' 'makes the verify FAIL'; do
    has "[4] step 9" "$S9" "$s"
  done
  for s in '$(tl_plugin_root)/agents/build-reviewer.md' 'last `base-sha=` line' 'merge-base' 'fallback' \
           'reviewer model=' 'REVIEW_RESULT: (PASS|FAIL)' 'adds nothing' 'must not spawn children'; do
    has "[4] step 10" "$S10" "$s"
  done
  if [ -n "$S10" ]; then
    for r in "${RULES[@]}"; do
      case "$S10" in *"**$r.**"*) bad "[4] step 10 duplicates the build-reviewer rule heading **$r.**" ;;
        *) ok "[4] step 10 has no '**$r.**' rule heading" ;; esac
    done
    for w in Conformance Deviations Fail-loud 'Pre-existing debt'; do
      case "$S10" in *"$w"*) bad "[4] step 10 carries a checklist word '$w'" ;; *) ok "[4] step 10 has no '$w'" ;; esac
    done
    case "$S10" in *'optional `agents/security-reviewer.md` if that file exists'*)
      bad "[4] step 10 still lists the old optional security-reviewer input" ;;
      *) ok "[4] step 10 no longer improvises the reviewer inputs" ;; esac
  fi
else bad "[4] infra: $IMPL missing/unreadable/empty (L-001)"; fi

# --- obs 4b: /tdd-author design-PR body ---------------------------------------
echo "[4b] /tdd-author 7b and 9 carry the critique into the design-PR body"
if readable "$TA"; then
  S7B="$(section "$TA" '^\*\*7b\. ' '^## 8\. ' | tr '\n' ' ' | tr -s ' ')"
  S9="$(section "$TA" '^## 9\. ' '^## 10\. ' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$S7B" ] && [ -n "$S9" ] && ok "[4b] 7b and step 9 found" || bad "[4b] infra: 7b='${#S7B}' 9='${#S9}'"
  for s in 'returned report text' 'in this session' 'never write it to the draft' \
           '### Simulation trace' 'METRICS:' '### Non-findings' 'alternatives table'; do
    has "[4b] 7b" "$S7B" "$s"
  done
  for s in '### Simulation trace` section, verbatim' 'every blocker or major finding with its alternatives table' \
           'the `METRICS:` line' 'the `### Non-findings` section' 'held in this session'; do
    has "[4b] step 9" "$S9" "$s"
  done
  # Kept wording other evals pin.
  J="$(norm "$TA")"
  has "[4b] tdd-author (kept)" "$J" "it runs in a fresh worker that is not this session and inherits this session's model (FR-10); independence is the fresh context, not a distinct model name"
  has "[4b] tdd-author (kept)" "$J" 'rubric is present and co-created'
else bad "[4b] infra: $TA missing/unreadable/empty (L-001)"; fi

echo
# Review R-1: rule 7's "no PASS on an all-[unverified] trace" must route
# through rule 9's FAIL-iff (a major finding), not float as a bare ban.
if readable "$BR"; then
  has "build-reviewer rule 7" "$(norm "$BR")" 'only of `[unverified]` steps is itself a major finding'
fi

# Follow-ups: plugin-internal citations are labelled as such in every
# reviewer prompt that carries them; /tdd-author 7b dispatches by prompt file;
# /prd-author's self-review no longer sends a TBD token to Open questions.
CITE='Citations such as (FR-55) or (ADR 0005) in this prompt refer to the plugin'"'"'s own design records'
for f in "$REPO/agents/design-reviewer.md" "$REPO/agents/build-reviewer.md" "$REPO/agents/requirements-reviewer.md"; do
  if readable "$f"; then has "$(basename "$f") citation note" "$(norm "$f")" "$CITE"; fi
done
TA="$REPO/skills/tdd-author/SKILL.md"
if readable "$TA"; then
  has "tdd-author 7b" "$(norm "$TA")" 'whose instructions are the file `$(tl_plugin_root)/agents/design-reviewer.md`'
  if norm "$TA" | grep -qF 'Spawn the `design-reviewer` subagent'; then bad "tdd-author 7b still names an agent type"
  else ok "tdd-author 7b names no agent type"; fi
fi
PA="$REPO/skills/prd-author/SKILL.md"
if readable "$PA"; then
  has "prd-author self-review" "$(norm "$PA")" 'without the TBD/TODO token'
fi

PASS="$(grep -c '^ok$' "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
echo "=== reviewer-contracts (TDD 0075): $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]

#!/usr/bin/env bash
# plan-classifier.sh — heuristic classifier for a TDD's `## Verification plan`
# (TDD 0013 / FR-52). Pure regex / grep — no LLM.
#
# Echoes `mechanical` or `nontrivial` on stdout. The runtime-verify gate reads
# this to pick a model: mechanical observations (CLI exit codes, log greps, file
# presence, HTTP status codes) run on sonnet; nontrivial plans (browser/UI
# driving, multi-step interactive flows, judgment about ambiguous output) run on
# the build model.
#
# Algorithm:
#   1. Extract lines between `^## Verification plan` and the next `^## ` heading.
#   2. If any nontrivial trigger keyword matches → `nontrivial`.
#   3. Else if any mechanical evidence keyword matches → `mechanical`.
#   4. Default → `nontrivial` (conservative; when in doubt use the build model).

# tl_classify_plan <tdd-path>
tl_classify_plan() {
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "plan-classifier: input not found: $f" >&2
    return 2
  fi
  # Extract just the verification-plan section body (between its heading and
  # the next `^## ` heading). The body, lowercased, is what the keyword
  # checks scan — nothing else in the TDD should influence the classifier.
  #
  # MAJ-3 (review pass 2): check PIPESTATUS for the awk|tr pipeline. An awk
  # crash would otherwise leave body empty and fall through to the
  # conservative "nontrivial" default with rc=0 — which the runner's M3
  # fix then treats as a genuine nontrivial classification, bypassing
  # the "(classifier failed, ...)" log note.
  local body body_rcs
  body="$(awk '
    /^## Verification plan/ { in_sec=1; next }
    /^## / { in_sec=0; next }
    in_sec { print }
  ' "$f" | tr '[:upper:]' '[:lower:]')"
  body_rcs=("${PIPESTATUS[@]}")
  if [ "${body_rcs[0]}" -ne 0 ] || [ "${body_rcs[1]:-0}" -ne 0 ]; then
    echo "plan-classifier: body-extract pipeline failed (awk=${body_rcs[0]} tr=${body_rcs[1]:-0}) on $f" >&2
    return 2
  fi

  # Nontrivial triggers — the bare keyword set the TDD enumerates. Case-
  # insensitive match against the lowercased body. "websocket" covers the
  # protocol-level streaming case; bare "streaming" is intentionally not in
  # this list (a curl + line-count plan is mechanical).
  #
  # MAJ-1 (review pass 2): the UI boundary character class also covers `?`
  # `)` `!`, and the start-anchor allows a preceding `(` so `(UI)` /
  # `the UI?` / `UI!` all match. The narrower form `(^| )ui( |$|[.,:;])`
  # missed those — a plan that drove a UI element with question-mark or
  # closing-paren punctuation got misclassified as mechanical (or fell
  # through to the conservative default for the wrong reason) and
  # ran on sonnet instead of the build model.
  if printf '%s' "$body" | grep -qE 'browser|dom|playwright|selenium|screenshot|interactive|multi-step|multi-turn|judgment|rendered output|websocket|(^| |[(])ui( |$|[.,:;?)!])'; then
    echo nontrivial
    return 0
  fi

  # Mechanical evidence — at least one of these phrases is enough.
  if printf '%s' "$body" | grep -qE 'exit code|exits 0|exit 1|stdout|grep|http 2|http 4|http 5|returns|log line|file exists|\[ -f|cmp|diff|byte-identical|json'; then
    echo mechanical
    return 0
  fi

  # Conservative default: when no obvious signals exist, take the build
  # model. Errs toward correctness over savings.
  echo nontrivial
}

# When invoked directly: classify each TDD passed on the command line.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  if [ "$#" -eq 0 ]; then
    echo "usage: $0 <tdd-path>..." >&2
    exit 2
  fi
  for tdd in "$@"; do
    cls="$(tl_classify_plan "$tdd")"
    printf '%s\t%s\n' "$cls" "$tdd"
  done
fi

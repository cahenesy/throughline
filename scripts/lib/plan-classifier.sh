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

# Source the unified markdown parser (TDD 0055) by its SIBLING path with the
# FATAL-on-missing + dual `return||exit` idiom (correct sourced OR executed;
# `bash plan-classifier.sh <tdd>` runs this file directly). `${BASH_SOURCE[0]%/*}`
# (no dirname) keeps this minimal-host caller safe; md.sh's include guard makes a
# repeat source a no-op. The FATAL prints first, so a missing lib is never silent
# (ADR 0006).
_md_lib="${BASH_SOURCE[0]%/*}/md.sh"
# shellcheck source=scripts/lib/md.sh
{ [ -r "$_md_lib" ] && . "$_md_lib"; } || {
  echo "FATAL: cannot source $_md_lib (partial install or perms)" >&2
  return 1 2>/dev/null || exit 1
}
unset _md_lib

# tl_classify_plan <tdd-path>
tl_classify_plan() {
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "plan-classifier: input not found: $f" >&2
    return 2
  fi
  # Extract just the verification-plan section body via the unified parser
  # (TDD 0055 / reuse #11): md_section_body is FENCE-AWARE (``` AND ~~~), so a
  # fenced `## Verification plan` / nontrivial-keyword example inside another
  # section no longer leaks into the keyword scan and misroutes the model. The
  # body, lowercased, is what the keyword checks scan — nothing else in the TDD
  # should influence the classifier. md_section_body returns 2 + a stderr
  # diagnostic on an awk failure (subsuming this function's prior standalone
  # awk-rc handling); `tr` runs INDEPENDENTLY on the captured string (a
  # deterministic translator that doesn't fail on that stdin), so awk's rc stays
  # directly observable without a PIPESTATUS dance.
  local body body_raw awk_rc
  body_raw="$(md_section_body "$f" "Verification plan")"
  awk_rc=$?
  if [ "$awk_rc" -ne 0 ]; then
    echo "plan-classifier: body-extract failed (rc $awk_rc) on $f" >&2
    return 2
  fi
  body="$(printf '%s' "$body_raw" | tr '[:upper:]' '[:lower:]')"

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
  # MAJ-2 (review pass 4): the dispatcher loop used to discard
  # `tl_classify_plan`'s exit code. An awk crash inside the function
  # left `cls` empty, the dispatcher printed a tab-separated blank line,
  # and the script exited 0 — indistinguishable from a clean
  # classification on this batch CLI path. NFR-4 requires
  # "couldn't classify" to remain distinguishable from "classified
  # successfully" on every observable surface, including this one.
  # Surface failures as: an `error` token in the first column, the
  # function's own stderr (already emitted by BL-2's fix), and a
  # non-zero overall exit code.
  any_err=0
  for tdd in "$@"; do
    cls="$(tl_classify_plan "$tdd")"
    cls_rc=$?
    if [ "$cls_rc" -ne 0 ] || [ -z "$cls" ]; then
      printf 'error\t%s\n' "$tdd"
      any_err=1
    else
      printf '%s\t%s\n' "$cls" "$tdd"
    fi
  done
  exit "$any_err"
fi

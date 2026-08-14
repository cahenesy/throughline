#!/usr/bin/env bash
# models.sh — the one greppable model-id binding site (TDD 0062 / ADR 0009 /
# NFR-3). Product names live ONLY in this file. Prose surfaces speak tiers.
#
#   tl_resolve_models [plan-text]
#     prints: build=<id> review=<id> verify=<id>
#
# Defaults:
#   build  = latest top-tier on this harness
#   review = prior-generation top-tier (author ≠ reviewer)
#   verify = cheaper tier when <plan-text> is only exit-code / file / grep,
#            else the build model
# Overrides: THROUGHLINE_BUILD_MODEL, THROUGHLINE_REVIEW_MODEL,
#            THROUGHLINE_RUNTIME_VERIFY_MODEL
#
# Harness: GROK_PLUGIN_ROOT set → Grok ids; else Claude ids.
# No top-level side effects.

tl_resolve_models() {
  local plan="${1:-}" build review verify cheap
  if [ -n "${GROK_PLUGIN_ROOT:-}" ]; then
    build="${THROUGHLINE_BUILD_MODEL:-grok-4.6}"
    cheap="grok-4.5"
    if [ -n "${THROUGHLINE_REVIEW_MODEL:-}" ]; then
      review="$THROUGHLINE_REVIEW_MODEL"
    else
      review="grok-4.5"
    fi
  else
    build="${THROUGHLINE_BUILD_MODEL:-fable}"
    cheap="sonnet"
    if [ -n "${THROUGHLINE_REVIEW_MODEL:-}" ]; then
      review="$THROUGHLINE_REVIEW_MODEL"
    else
      case "$build" in
        *opus*) review="sonnet" ;;
        *)      review="opus"   ;;
      esac
    fi
  fi
  if [ -n "${THROUGHLINE_RUNTIME_VERIFY_MODEL:-}" ]; then
    verify="$THROUGHLINE_RUNTIME_VERIFY_MODEL"
  else
    case "$plan" in
      *[Ee]xit-code*|*grep*|*file\ exist*|*rc\ 0*|*rc=0*) verify="$cheap" ;;
      '') verify="$cheap" ;;
      *)  verify="$build" ;;
    esac
  fi
  printf 'build=%s review=%s verify=%s\n' "$build" "$review" "$verify"
}

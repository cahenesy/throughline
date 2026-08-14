#!/usr/bin/env bash
# plugin-root.sh — harness-agnostic plugin tree + plugin-data resolver.
#
# TDD 0060 (FR-79, FR-81, FR-34). Sourced by authoring/status skills so they
# do not hard-code CLAUDE_PLUGIN_ROOT. Defines functions only — no top-level
# side effects — so it is safe to source from any context.
#
#   tl_plugin_root  — first of $CLAUDE_PLUGIN_ROOT, $GROK_PLUGIN_ROOT that
#                     names an existing directory. No path probing, no git
#                     lookup. Fail closed (rc 1 + diagnostic) otherwise.
#   tl_plugin_data  — first of $CLAUDE_PLUGIN_DATA, $GROK_PLUGIN_DATA that
#                     is non-empty. Exports THROUGHLINE_PLUGIN_DATA to the
#                     winner. Fail closed otherwise.

# tl_plugin_root — echo the plugin install dir. Returns 1 with a stderr
# diagnostic when neither env var names an existing directory.
tl_plugin_root() {
  local cand
  for cand in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    if [ -n "$cand" ] && [ -d "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  echo "throughline: set CLAUDE_PLUGIN_ROOT or GROK_PLUGIN_ROOT to the plugin install dir" >&2
  return 1
}

# tl_plugin_data — echo the plugin data dir (first set of the two env vars).
# Exports THROUGHLINE_PLUGIN_DATA as that value on success so later helpers
# can read one name. Returns 1 with a stderr diagnostic when both are unset
# or empty. Does not require the path to exist (callers mkdir as needed).
tl_plugin_data() {
  local cand
  for cand in "${CLAUDE_PLUGIN_DATA:-}" "${GROK_PLUGIN_DATA:-}"; do
    if [ -n "$cand" ]; then
      THROUGHLINE_PLUGIN_DATA="$cand"
      export THROUGHLINE_PLUGIN_DATA
      printf '%s\n' "$cand"
      return 0
    fi
  done
  echo "throughline: set CLAUDE_PLUGIN_DATA or GROK_PLUGIN_DATA to the plugin data dir" >&2
  return 1
}

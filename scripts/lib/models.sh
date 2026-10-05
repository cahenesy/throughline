#!/usr/bin/env bash
# models.sh — model roles and parent-model observation (TDD 0064 / ADR 0015 /
# NFR-3: the best cost/performance model for each job, owned by the operator
# through the parent session's model and effort).
#
# Judgment slots (implementer, FR-15(d) reviewer, nontrivial runtime-verify)
# resolve to `inherit`: the worker is dispatched with no model parameter and
# runs on the parent session's model. Pins win (FR-87). Exactly two models are
# named per harness, both maintained bindings on the four lines below: the
# LIGHT tier (mechanical runtime-verify, FR-52, never above the parent) and the
# ESCALATION target (FR-88, used by /build-tdds escalation). Rebinding one when
# a vendor ships a new generation is an implementation change, not an ADR.
# Review independence is a fresh worker, not a distinct model name.
#
# Every model decision is a function here, so no skill re-derives a rule in
# prose. The parent's model is OBSERVED from the harness session artifact
# (tl_parent_model), never taken from the model's self-report.
#
#   tl_model_harness                      claude | grok
#   tl_light_model / tl_escalation_model  the harness binding (escalation:
#                                         THROUGHLINE_ESCALATION_MODEL wins)
#   tl_model_family <id>                  family name (rc 1 on empty id)
#   tl_model_tier <id>                    light | above | unknown
#   tl_parent_model                       parent id; rc 1 + one stderr line
#                                         `tl_parent_model: <reason>`
#   tl_parent_effort                      `<level> env|settings` | `unknown -`
#   tl_fr86_message                       FR-86 warning line, or nothing
#   tl_plan_class [tdd-path]              mechanical | nontrivial
#   tl_resolve_models [tdd] [parent]      build=<v> review=<v> verify=<v>
#   tl_model_sources  [tdd] [parent]      build_src=<s> review_src=<s> verify_src=<s>
#   tl_dispatch_model_arg <value>         dispatch model param; empty = none (0066)
#   tl_model_warnings [tdd] [parent]      light-pin / effort-pin warning lines
#   tl_models_confirm <slug> [tdd] [parent]  /build-tdds queue confirmation
#
# Harness: GROK_PLUGIN_ROOT non-empty → grok; else claude. Sourced, never
# executed: no shell options set; the only top-level effects are sourcing
# plan-classifier.sh and the four binding assignments.

case "${BASH_SOURCE[0]}" in
  */*) _tl_models_pc="${BASH_SOURCE[0]%/*}/plan-classifier.sh" ;;
  *)   _tl_models_pc="./plan-classifier.sh" ;;
esac
# shellcheck source=scripts/lib/plan-classifier.sh
{ [ -r "$_tl_models_pc" ] && . "$_tl_models_pc"; } || {
  echo "FATAL: cannot source $_tl_models_pc (partial install or perms)" >&2
  unset _tl_models_pc
  return 1 2>/dev/null || exit 1
}
unset _tl_models_pc

_TL_CLAUDE_LIGHT=sonnet
_TL_CLAUDE_ESCALATION=fable
_TL_GROK_LIGHT=grok-4.5        # unverified this pass (see Failure modes)
_TL_GROK_ESCALATION=grok-4.6   # unverified this pass

tl_model_harness() {
  if [ -n "${GROK_PLUGIN_ROOT:-}" ]; then printf 'grok\n'; else printf 'claude\n'; fi
}

tl_light_model() {
  if [ "$(tl_model_harness)" = grok ]; then printf '%s\n' "$_TL_GROK_LIGHT"
  else printf '%s\n' "$_TL_CLAUDE_LIGHT"; fi
}

tl_escalation_model() {
  if [ -n "${THROUGHLINE_ESCALATION_MODEL:-}" ]; then
    printf '%s\n' "$THROUGHLINE_ESCALATION_MODEL"
  elif [ "$(tl_model_harness)" = grok ]; then printf '%s\n' "$_TL_GROK_ESCALATION"
  else printf '%s\n' "$_TL_CLAUDE_ESCALATION"; fi
}

# tl_model_family <id> — Claude: the first known family name that is a
# substring of the lowercased id, else the lowercased id. Grok: lowercased id.
tl_model_family() {
  local id f
  [ -n "${1:-}" ] || return 1
  id="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if [ "$(tl_model_harness)" = claude ]; then
    for f in mythos fable opus sonnet haiku; do
      case "$id" in *"$f"*) printf '%s\n' "$f"; return 0 ;; esac
    done
  fi
  printf '%s\n' "$id"
}

# tl_model_tier <id> — `light` when the id is in the light binding's family
# (or, on Claude, the haiku family); `above` otherwise; `unknown` when empty.
# Membership by family name only: no rank table, no live fetch (ADR 0015).
tl_model_tier() {
  local fam
  fam="$(tl_model_family "${1:-}")" || { printf 'unknown\n'; return 0; }
  if [ "$fam" = "$(tl_model_family "$(tl_light_model)")" ]; then
    printf 'light\n'
  elif [ "$(tl_model_harness)" = claude ] && [ "$fam" = haiku ]; then
    printf 'light\n'
  else
    printf 'above\n'
  fi
}

# _tl_tac <file> — the file's lines newest-first (tac; BSD `tail -r`).
_tl_tac() {
  if command -v tac >/dev/null 2>&1; then tac "$1"; else tail -r "$1"; fi
}

# _tl_transcript_model <jsonl> — print the newest assistant `.message.model`
# that is neither empty nor `<synthetic>`. Every line is PARSED as JSON,
# tolerantly (a truncated line is skipped); never a regex on the raw line,
# whose tool_use inputs can carry their own "model" key. rc 3 = no parser.
_tl_transcript_model() {
  if command -v jq >/dev/null 2>&1; then
    _tl_tac "$1" | jq -nRr 'first(inputs | fromjson? | objects
      | select(.type == "assistant") | .message | objects | .model | strings
      | select(. != "" and . != "<synthetic>"))' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    _tl_tac "$1" | python3 -c '
import json, sys
for line in sys.stdin.buffer:
    try:
        d = json.loads(line)
    except Exception:
        continue
    if not isinstance(d, dict) or d.get("type") != "assistant":
        continue
    m = d.get("message")
    v = m.get("model") if isinstance(m, dict) else None
    if isinstance(v, str) and v and v != "<synthetic>":
        print(v)
        break
' 2>/dev/null
  else
    return 3
  fi
  return 0
}

# _tl_json_top_string <file> <key> — print the top-level string field <key>
# of the JSON document <file> (empty when absent / not a string / malformed).
# jq → python3 cascade; rc 3 = no parser.
_tl_json_top_string() {
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k]? | strings' "$1" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2]) if isinstance(d, dict) else None
if isinstance(v, str):
    print(v)
' "$1" "$2" 2>/dev/null
  else
    return 3
  fi
  return 0
}

# _tl_pct_encode <string> — percent-encode every byte outside A-Za-z0-9._~-
# (so `/` → %2F, including the leading slash).
_tl_pct_encode() {
  local LC_ALL=C s="${1:-}" out="" c hex i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out="$out$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out="$out$hex" ;;
    esac
  done
  printf '%s' "$out"
}

# _tl_grok_summary <sessions-dir> <dir> <sid> — print the summary.json path
# for <dir> (percent-encoded) if it exists. Rejects any `..` so the path stays
# under <sessions-dir>.
_tl_grok_summary() {
  local rel
  rel="$(_tl_pct_encode "$2")/$3"
  case "$rel" in *..*) return 1 ;; esac
  [ -f "$1/$rel/summary.json" ] || return 1
  printf '%s\n' "$1/$rel/summary.json"
}

_tl_pm_fail() { printf 'tl_parent_model: %s\n' "$1" >&2; return 1; }

# tl_parent_model — the parent session's model id, observed from the harness
# session artifact. rc 1 (no stdout, one stderr line) when unreadable; an
# unreadable model is reported, never guessed (ADR 0015).
tl_parent_model() {
  local out rc f="" cand top what
  if [ "$(tl_model_harness)" = grok ]; then
    local sid="${GROK_SESSION_ID:-}" base
    [ -n "$sid" ] || { _tl_pm_fail "no session id"; return 1; }
    case "$sid" in *..*) _tl_pm_fail "invalid session id"; return 1 ;; esac
    base="${GROK_HOME:-${HOME:-}/.grok}/sessions"
    f="$(_tl_grok_summary "$base" "$PWD" "$sid")" || {
      top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
      f=""
      [ -z "$top" ] || f="$(_tl_grok_summary "$base" "$top" "$sid")" || f=""
    }
    [ -n "$f" ] || { _tl_pm_fail "summary not found"; return 1; }
    what=summary
    out="$(_tl_json_top_string "$f" current_model_id)" && rc=0 || rc=$?
  else
    local id="${CLAUDE_CODE_SESSION_ID:-}"
    case "$id" in ''|*[!A-Za-z0-9-]*) _tl_pm_fail "no session id"; return 1 ;; esac
    for cand in "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"/projects/*/"$id".jsonl; do
      [ -f "$cand" ] && { f="$cand"; break; }
    done
    [ -n "$f" ] || { _tl_pm_fail "transcript not found"; return 1; }
    what=transcript
    out="$(_tl_transcript_model "$f")" && rc=0 || rc=$?
  fi
  [ "$rc" -ne 3 ] || { _tl_pm_fail "no json parser"; return 1; }
  out="${out%%$'\n'*}"
  [ -n "$out" ] || { _tl_pm_fail "no model in $what"; return 1; }
  printf '%s\n' "$out"
}

# tl_fr86_message — the FR-86 parent-session light-tier check (TDD 0065).
# No args. Parent readable and above the light tier → no output. On the light
# tier → one line naming the id. Unreadable → one line carrying the reason
# from tl_parent_model's `tl_parent_model: <reason>` stderr line (`unknown`
# when it gave none). rc 0 in all three cases; rc 2 + a stderr diagnostic
# only when this library is unusable. /prd-author, /tdd-author and
# /build-tdds run it from one identical `<!-- tl:fr86-check -->` block and
# ask Continue / Stop on a printed line. No network, no capability ranking.
tl_fr86_message() {
  local f out rc id tier line reason=""
  for f in tl_parent_model tl_model_tier; do
    [ "$(type -t "$f")" = function ] || {
      printf 'tl_fr86_message: %s is not defined (models.sh unusable)\n' "$f" >&2
      return 2
    }
  done
  # One call with stderr folded in: on rc 0 the id is the last line (the
  # function's final write); on failure the reason is its own prefixed line,
  # whatever else (a tac/jq complaint) reached stderr before it.
  out="$(tl_parent_model 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    id="${out##*$'\n'}"
    tier="$(tl_model_tier "$id")" || tier=""
    case "$tier" in
      above) return 0 ;;
      light)
        printf 'throughline: parent session model %s is on the light tier; judgment work in this session inherits it. Continue, or stop and change the model.\n' "$id"
        return 0 ;;
      *)
        printf "tl_fr86_message: unexpected tier '%s' for parent model '%s' (models.sh unusable)\n" "$tier" "$id" >&2
        return 2 ;;
    esac
  fi
  while IFS= read -r line; do
    case "$line" in 'tl_parent_model: '*) reason="${line#tl_parent_model: }" ;; esac
  done <<<"$out"
  printf 'throughline: parent session model could not be read (%s). Continue, or stop and change the model.\n' "${reason:-unknown}"
}

# tl_parent_effort — `<level> env` | `<level> settings` | `unknown -`.
# Effort is session-wide on these harnesses; Grok exposes none.
tl_parent_effort() {
  local lvl="" f
  if [ "$(tl_model_harness)" = grok ]; then printf 'unknown -\n'; return 0; fi
  if [ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ]; then
    printf '%s env\n' "$CLAUDE_CODE_EFFORT_LEVEL"; return 0
  fi
  f="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/settings.json"
  if [ -r "$f" ]; then lvl="$(_tl_json_top_string "$f" effortLevel)" || lvl=""; fi
  lvl="${lvl%%$'\n'*}"
  if [ -n "$lvl" ]; then printf '%s settings\n' "$lvl"; else printf 'unknown -\n'; fi
}

# tl_plan_class [tdd-path] — the FR-52 plan class via tl_classify_plan;
# no path or a classifier failure → nontrivial (conservative).
tl_plan_class() {
  local c
  [ -n "${1:-}" ] || { printf 'nontrivial\n'; return 0; }
  c="$(tl_classify_plan "$1")" || c=""
  case "$c" in
    mechanical) printf 'mechanical\n' ;;
    *)          printf 'nontrivial\n' ;;
  esac
}

# _tl_resolve_slot <build|review|verify> [tdd-path] [parent-id] — print
# `<value> <source>`; the one rule both public resolvers share. The source is
# a single token, so callers split on the LAST space.
_tl_resolve_slot() {
  local slot="$1" tdd="${2:-}" parent="${3:-}" pin
  case "$slot" in
    build|review)
      if [ "$slot" = build ]; then pin=THROUGHLINE_BUILD_MODEL; else pin=THROUGHLINE_REVIEW_MODEL; fi
      if [ -n "${!pin:-}" ]; then
        printf '%s pin:%s\n' "${!pin}" "$pin"
      elif [ "$(tl_model_harness)" = claude ] && [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
        # Claude Code applies it to every dispatch without a model: a pin.
        printf '%s pin:CLAUDE_CODE_SUBAGENT_MODEL\n' "$CLAUDE_CODE_SUBAGENT_MODEL"
      else
        printf 'inherit parent\n'
      fi ;;
    verify)
      if [ -n "${THROUGHLINE_RUNTIME_VERIFY_MODEL:-}" ]; then
        printf '%s pin:THROUGHLINE_RUNTIME_VERIFY_MODEL\n' "$THROUGHLINE_RUNTIME_VERIFY_MODEL"
      elif [ "$(tl_plan_class "$tdd")" = nontrivial ]; then
        _tl_resolve_slot build "$tdd" "$parent"
      elif [ "$(tl_model_tier "$parent")" = above ]; then
        printf '%s light\n' "$(tl_light_model)"
      else
        printf 'inherit parent-cap\n'   # light or unknown parent: never above it
      fi ;;
    *) printf '_tl_resolve_slot: unknown slot %s\n' "$slot" >&2; return 2 ;;
  esac
}

# tl_resolve_models [tdd-path] [parent-id] — one line `build=<v> review=<v>
# verify=<v>`; <v> is `inherit` (dispatch with no model) or a model id.
tl_resolve_models() {
  local b r v
  b="$(_tl_resolve_slot build "${1:-}" "${2:-}")"
  r="$(_tl_resolve_slot review "${1:-}" "${2:-}")"
  v="$(_tl_resolve_slot verify "${1:-}" "${2:-}")"
  printf 'build=%s review=%s verify=%s\n' "${b% *}" "${r% *}" "${v% *}"
}

# tl_model_sources [tdd-path] [parent-id] — one line `build_src=<s>
# review_src=<s> verify_src=<s>`; <s> ∈ parent, pin:<ENV-NAME>, light,
# parent-cap.
tl_model_sources() {
  local b r v
  b="$(_tl_resolve_slot build "${1:-}" "${2:-}")"
  r="$(_tl_resolve_slot review "${1:-}" "${2:-}")"
  v="$(_tl_resolve_slot verify "${1:-}" "${2:-}")"
  printf 'build_src=%s review_src=%s verify_src=%s\n' "${b##* }" "${r##* }" "${v##* }"
}

# --- /build-tdds dispatch, warnings, confirmation (TDD 0066 / FR-87) ---------

# tl_dispatch_model_arg <value> — the dispatch `model` parameter for a slot
# value. `inherit` (or empty) → no output: dispatch the worker with NO model
# parameter, so it runs on the parent session's model. Anything else → the
# value, to be passed exactly. rc 0.
tl_dispatch_model_arg() {
  case "${1:-}" in
    ''|inherit) ;;
    *) printf '%s\n' "$1" ;;
  esac
  return 0
}

# _tl_models_resolved [tdd-path] [parent-id] — six lines from the public
# resolvers, in order: build, build_src, review, review_src, verify,
# verify_src. The single place the confirmation and the run record read the
# slots from (TDD 0067 forwards its escalation arg here). Keys are fixed and in
# order; a value is `inherit`, an alias or an id. rc 1 on a malformed line.
_tl_models_resolved() {
  local m s b bs r rs v vs
  m="$(tl_resolve_models "${1:-}" "${2:-}")" || return 1
  s="$(tl_model_sources "${1:-}" "${2:-}")" || return 1
  case "$m" in 'build='*' review='*' verify='*) ;; *) return 1 ;; esac
  case "$s" in 'build_src='*' review_src='*' verify_src='*) ;; *) return 1 ;; esac
  b="${m#build=}";       b="${b%% review=*}"
  r="${m#* review=}";    r="${r%% verify=*}"
  v="${m##* verify=}"
  bs="${s#build_src=}";  bs="${bs%% review_src=*}"
  rs="${s#* review_src=}"; rs="${rs%% verify_src=*}"
  vs="${s##* verify_src=}"
  printf '%s\n' "$b" "$bs" "$r" "$rs" "$v" "$vs"
}

# tl_model_warnings [tdd-path] [parent-id] — zero or more warning lines, in
# order build, review, effort pins (FR-87). A build or review pin whose model
# is on the light tier is honored and warned about; a pin to any other model
# is silent, and so is mechanical verify on the light binding. A per-worker
# effort pin is reported as ignored: effort is session-wide on these
# harnesses. rc 0; rc 1 when the resolvers fail.
tl_model_warnings() {
  local all b bs r rs v vs val src role env
  all="$(_tl_models_resolved "${1:-}" "${2:-}")" || return 1
  { IFS= read -r b; IFS= read -r bs; IFS= read -r r; IFS= read -r rs
    IFS= read -r v; IFS= read -r vs; } <<<"$all"
  for role in implementer reviewer; do
    if [ "$role" = implementer ]; then val="$b" src="$bs"; else val="$r" src="$rs"; fi
    case "$src" in
      pin:*)
        if [ "$(tl_model_tier "$val")" = light ]; then
          printf 'throughline: %s=%s puts the %s on the light tier; continuing\n' \
            "${src#pin:}" "$val" "$role"
        fi ;;
    esac
  done
  for env in THROUGHLINE_BUILD_EFFORT THROUGHLINE_REVIEW_EFFORT THROUGHLINE_RUNTIME_VERIFY_EFFORT; do
    if [ -n "${!env:-}" ]; then
      printf 'throughline: %s=%s ignored: per-worker effort is not supported on this harness (workers run at the session effort)\n' \
        "$env" "${!env}"
    fi
  done
  return 0
}

# _tl_model_shown <value> <parent-shown> — `inherit (<parent>)` or the value.
_tl_model_shown() {
  if [ "$1" = inherit ]; then printf 'inherit (%s)' "$2"; else printf '%s' "$1"; fi
}

# tl_models_confirm <slug> [tdd-path] [parent-id] — the /build-tdds queue
# confirmation for one TDD (FR-87): parent model (`unknown` when unread), the
# session effort and its source, then each worker's model and source. A
# mechanical verify notes that low effort is requested but the session effort
# applies (FR-52; no per-worker effort exists). rc 0; rc 2 without a slug;
# rc 1 when the resolvers fail.
tl_models_confirm() {
  local slug="${1:-}" tdd="${2:-}" parent="${3:-}" p eff cls all b bs r rs v vs vline
  [ -n "$slug" ] || { echo "tl_models_confirm: <slug> required" >&2; return 2; }
  p="${parent:-unknown}"
  eff="$(tl_parent_effort)" || return 1
  cls="$(tl_plan_class "$tdd")" || return 1
  all="$(_tl_models_resolved "$tdd" "$parent")" || return 1
  { IFS= read -r b; IFS= read -r bs; IFS= read -r r; IFS= read -r rs
    IFS= read -r v; IFS= read -r vs; } <<<"$all"
  vline="  runtime-verify ($cls): $(_tl_model_shown "$v" "$p") [$vs]"
  if [ "$cls" = mechanical ]; then
    vline="$vline effort=low requested; session effort applies"
  fi
  printf 'models %s: parent=%s effort=%s (%s; session-wide)\n' "$slug" "$p" "${eff% *}" "${eff##* }"
  printf '  implementer: %s [%s]\n' "$(_tl_model_shown "$b" "$p")" "$bs"
  printf '  reviewer: %s [%s]\n' "$(_tl_model_shown "$r" "$p")" "$rs"
  printf '%s\n' "$vline"
}

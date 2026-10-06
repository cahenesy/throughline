#!/usr/bin/env bash
# escalation-probe.sh — live harness probe for TDD 0067 revision 2 / FR-88 /
# ADR 0016 (Verification plan observation 15). Run ONLY by the runtime-verify
# gate, never by ci-checks: it starts three real headless sessions and spends
# real tokens. Its job is to prove that escalation DETECTION works on the live
# harness, whatever models this account can use.
#
# Each probe runs
#   claude -p --model opus --output-format stream-json --verbose "<prompt>"
# whose prompt dispatches exactly one general-purpose subagent with a stated
# `model` and the prompt `Reply with exactly <nonce>` (a fresh random hex
# string). The probe finds that worker's agent id in the stream, exports
# CLAUDE_CODE_SESSION_ID as the headless child's `session_id` (its
# `system`/`init` event), and runs the real tl_worker_actual_model /
# tl_escalation_verify on the worker transcript the harness wrote:
#   P1  model = tl_escalation_model (THROUGHLINE_ESCALATION_MODEL wins).
#       PASS iff the verdict matches what the transcript shows:
#         answered on the requested family with the nonce → escalated;
#         refused (incl. credits_required) → dispatch error → fell-back;
#         answered by another family → fell-back harness ran <id>.
#   P2  model = claude-nonexistent-0. PASS iff the dispatch is refused with
#       is_error: the signal the fall-back rule relies on.
#   P3  model = opus, the parent's own alias (positive control). PASS iff the
#       agent id is found, tl_worker_actual_model gives a non-empty id, and
#       tl_escalation_verify <id> opus → escalated. This exercises the live
#       transcript reader even when P1 is refused.
#
# Stream shapes read (observed on Claude Code 2.1.289, 2026-10-05):
#   sync   the Agent tool_result (a `user` event, tool_use_id = the Agent
#          tool_use id) carries the reply and `is_error`.
#   async  the tool_result is an ack (`tool_use_result.isAsync`, status
#          `async_launched`, `agentId`); the outcome is the
#          `system`/`task_notification` for that tool_use_id (status
#          completed|failed, summary); the reply is the subagent's own
#          `assistant` events (`parent_tool_use_id` = the Agent id): text and
#          its `SubagentHandback` input.message. The ack's prompt and
#          `task_started` echo the nonce and are never read for it.
# Agent id: the ack's `tool_use_result.agentId`, else `agentId: <id>` in the
# tool_result text, else the `task_started` task_id.
#
# Exit codes:
#   0  all three pass. One line per probe:
#        P<n> requested=<m> actual=<id[,id…]|refused> verdict=<escalated|fell-back>
#   3  `PROBE_BLOCKED: <observation>` — P3's, or an answered P1's, actual
#      model cannot be determined (no agent id, no transcript, no model).
#   1  a classification disagrees with the transcript (or with the stream),
#      the stream is malformed (no Agent dispatch, no session_id, no
#      outcome), a session-wide limit was hit, or no claude / jq. The cause
#      is named on stderr.
# The runtime-verify gate maps 0 → PASS, 3 → BLOCKED, 1 → FAIL.
#
# Env: THROUGHLINE_PROBE_CLAUDE (the claude binary; default `claude` on PATH),
#      THROUGHLINE_PROBE_TIMEOUT (seconds per session; default 600).
# Run: bash tests/live/escalation-probe.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/models.sh
. "$REPO/scripts/lib/models.sh" || { echo "escalation-probe: cannot source models.sh" >&2; exit 1; }
CLAUDE_BIN="${THROUGHLINE_PROBE_CLAUDE:-claude}"
TIMEOUT="${THROUGHLINE_PROBE_TIMEOUT:-600}"
command -v "$CLAUDE_BIN" >/dev/null 2>&1 \
  || { echo "escalation-probe: '$CLAUDE_BIN' not found, so no dispatch can be observed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 \
  || { echo "escalation-probe: jq is required to read the stream-json events" >&2; exit 1; }
SCRATCH="$(mktemp -d)" || { echo "escalation-probe: mktemp -d failed" >&2; exit 1; }
SCRATCH_FROM_MKTEMP=1

# cleanup — on EXIT, also remove the harness project folder its headless
# children created for the scratch dir (TDD 0069 (c)):
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<enc>, <enc> = the physical
# scratch path with every [^A-Za-z0-9] → `-` (the harness's encoding). Removed
# only when $SCRATCH came from mktemp -d, <enc> starts with `-` and has ≥8
# chars, the path has no `..`, and the target is a directory, not a symlink.
# Nothing else under projects/ is touched.
cleanup() {
  local phys enc dir
  if [ "${SCRATCH_FROM_MKTEMP:-0}" = 1 ] && [ -n "${SCRATCH:-}" ] \
     && phys="$(cd -P "$SCRATCH" 2>/dev/null && pwd)"; then
    enc="$(printf '%s' "$phys" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
    dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc"
    case "$enc" in
      -???????*)
        case "$dir" in
          *..*) ;;
          *) if [ -d "$dir" ] && [ ! -L "$dir" ]; then rm -rf -- "$dir"; fi ;;
        esac ;;
    esac
  fi
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

die()     { printf 'escalation-probe: %s\n' "$1" >&2; exit 1; }
blocked() { printf 'PROBE_BLOCKED: %s\n' "$1"; exit 3; }
nonce()   { od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; }
first_line() { printf '%s' "$1" | grep -m 1 . | cut -c1-300; }

# jqp <stream> <program> [jq-options…] — <program> over each event, one per
# line, parsed tolerantly (a truncated or non-JSON line is skipped).
jqp() { local f="$1" prog="$2"; shift 2; jq -R "$@" "fromjson? | objects | $prog" "$f" 2>/dev/null; }

# _diag <stream> <model> <claude-rc> — why no Agent dispatch was found.
_diag() {
  local f="$1" model="$2" rc="$3" apierr others
  apierr="$(jqp "$f" '
      if .type == "assistant" and (.parent_tool_use_id // null) == null and (.error // null) != null then
        "error=\(.error): \([.message.content[]? | objects | select(.type == "text") | .text | strings] | join(" "))"
      elif .type == "result" and .is_error == true then
        "HTTP \(.api_error_status // "?"): \(.result // "" | tostring)"
      else empty end' -r | head -n 1 | cut -c1-300)"
  others="$(jqp "$f" '
      select(.type == "assistant" and (.parent_tool_use_id // null) == null)
      | .message.content[]? | objects
      | select(.type == "tool_use" and (.name == "Agent" or .name == "Task"))
      | (.input.model? // "<none>") | tostring' -r | sort -u | tr '\n' ' ')"
  if [ -n "$apierr" ]; then
    case "$apierr" in
      *rate_limit*|*'HTTP 429'*|*[Ll]imit*)
        printf 'a session-wide limit was hit before any dispatch (%s); rate/usage limit (transient), not a probe verdict' "$apierr" ;;
      *) printf 'the session ended on an API error before any dispatch (%s)' "$apierr" ;;
    esac
  elif [ -n "$others" ]; then
    printf 'the parent dispatched the Agent tool, but not with model "%s" (input.model seen: %s)' "$model" "${others% }"
  else
    printf 'no Agent tool_use in the stream (claude rc=%s)' "$rc"
  fi
}

# run_session <label> <model> — one headless session. Sets SID, AID,
# REFUSED (0|1), CREDITS (0|1), HAS_NONCE (0|1), TEXT (outcome text), and
# SMODELS (non-synthetic subagent message.model values seen in the stream).
# Exits 1 on a malformed stream.
run_session() {
  local label="$1" model="$2" n prompt out id res rc note
  SID=""; AID=""; REFUSED=0; CREDITS=0; HAS_NONCE=0; TEXT=""; SMODELS=""
  n="$(nonce)"
  [ "${#n}" -eq 32 ] || die "cannot generate a nonce"
  prompt="This is a harness probe. Use the Agent tool exactly once: dispatch one general-purpose subagent (subagent_type general-purpose, description probe) with model \"$model\" and the prompt \"Reply with exactly $n\". Pass that model value exactly as written, even if it looks invalid. Do not retry, do not dispatch any other agent, do not use any other tool, and do not repeat the subagent's reply. After the tool returns, reply with the single word done."
  out="$SCRATCH/$label.jsonl"
  if command -v timeout >/dev/null 2>&1; then
    ( cd "$SCRATCH" && exec timeout "$TIMEOUT" "$CLAUDE_BIN" -p --model opus \
        --output-format stream-json --verbose "$prompt" ) >"$out" 2>"$SCRATCH/$label.err"
  else
    ( cd "$SCRATCH" && exec "$CLAUDE_BIN" -p --model opus \
        --output-format stream-json --verbose "$prompt" ) >"$out" 2>"$SCRATCH/$label.err"
  fi
  rc=$?
  # The first top-level Agent tool_use whose input names the stated model.
  id="$(jqp "$out" '
      select(.type == "assistant" and (.parent_tool_use_id // null) == null)
      | .message.content[]? | objects
      | select(.type == "tool_use" and (.name == "Agent" or .name == "Task") and .input.model? == $m)
      | .id | strings' -r --arg m "$model" | head -n 1)"
  [ -n "$id" ] || die "$label ($model): $(_diag "$out" "$model" "$rc")"
  SID="$(jqp "$out" 'select(.type == "system" and .subtype == "init") | .session_id | strings' -r | head -n 1)"
  [ -n "$SID" ] || die "$label ($model): malformed stream: no session_id in the system/init event"
  res="$(jqp "$out" '
      select(.type == "user") | . as $ev
      | .message.content[]? | objects
      | select(.type == "tool_result" and .tool_use_id == $id)
      | (.content | if type == "string" then .
          elif type == "array" then (map(objects | select(.type == "text") | .text | strings) | join("\n"))
          else "" end) as $t
      | { is_error: (.is_error == true), text: $t,
          async: ((($ev.tool_use_result | objects | (.isAsync == true or .status == "async_launched")) // false)
                  or ($t | startswith("Async agent launched"))),
          agent: (($ev.tool_use_result | objects | .agentId | strings) // "") }' -c --arg id "$id" | head -n 1)"
  [ -n "$res" ] || die "$label ($model): malformed stream: no tool_result for the Agent tool_use $id (claude rc=$rc)"
  AID="$(printf '%s' "$res" | jq -r '.agent')"
  [ -n "$AID" ] || AID="$(printf '%s' "$res" | jq -r '.text' | sed -n 's/.*agentId: *\([A-Za-z0-9]*\).*/\1/p' | head -n 1)"
  [ -n "$AID" ] || AID="$(jqp "$out" 'select(.type == "system" and .subtype == "task_started" and .tool_use_id == $id)
      | .task_id | strings' -r --arg id "$id" | head -n 1)"
  SMODELS="$(jqp "$out" '
      select(.type == "assistant" and .parent_tool_use_id == $id)
      | .message.model | strings | select(. != "" and . != "<synthetic>")' -r --arg id "$id" | sort -u | tr '\n' ' ')"
  SMODELS="${SMODELS% }"
  if [ "$(printf '%s' "$res" | jq -r '.async')" = true ]; then
    note="$(jqp "$out" '
        select(.type == "system" and .subtype == "task_notification" and .tool_use_id == $id)
        | { status: (.status // "" | tostring),
            text: ([.summary, .result] | map(strings) | join("\n")) }' -c --arg id "$id" | head -n 1)"
    [ -n "$note" ] || die "$label ($model): malformed stream: the async agent for $id has no task_notification (claude rc=$rc)"
    [ "$(printf '%s' "$note" | jq -r '.status')" = completed ] || REFUSED=1
    TEXT="$(printf '%s' "$note" | jq -r '.text')
$(jqp "$out" '
        select(.type == "assistant" and .parent_tool_use_id == $id)
        | .message.content[]? | objects
        | if .type == "text" then (.text | strings)
          elif .type == "tool_use" and .name == "SubagentHandback" then (.input.message? | strings)
          else empty end' -r --arg id "$id")"
  else
    [ "$(printf '%s' "$res" | jq -r '.is_error')" = true ] && REFUSED=1
    TEXT="$(printf '%s' "$res" | jq -r '.text')"
  fi
  case "$TEXT" in *"$n"*) HAS_NONCE=1 ;; esac
  case "$TEXT" in *credits_required*|*'requires usage credits'*) CREDITS=1 ;; esac
  jqp "$out" 'select(.type == "rate_limit_event") | .rate_limit_info.errorCode? | strings' -r \
    | grep -qx credits_required && CREDITS=1
  return 0
}

# refusal_class <label> — for a refused dispatch: a credits refusal or any
# non-limit error is a dispatch error (fell-back); any other rate/usage limit
# is session-wide (exit 1, never a verdict).
refusal_class() {
  [ "$CREDITS" = 1 ] && return 0
  case "$TEXT" in
    *rate_limit*|*'HTTP 429'*|*[Ll]imit*)
      die "$1: the dispatch was refused by a session-wide limit, not a credits refusal ($(first_line "$TEXT")); rate/usage limit (transient), not a probe verdict" ;;
  esac
  return 0
}

# actual_and_verdict <label> <requested> — for an answered dispatch: read the
# worker transcript with the session's id. Sets ACTUAL (comma-joined) and
# VERDICT (tl_escalation_verify's full line). Exit 3 when the actual model
# cannot be determined; exit 1 when the stream and the transcript disagree,
# or the verdict disagrees with what the transcript shows.
actual_and_verdict() {
  local label="$1" req="$2" ids why m want expect=escalated
  [ -n "$AID" ] || blocked "$label: the Agent dispatch on $req answered, but no agent id was found in the stream, so its actual model cannot be determined"
  ids="$(CLAUDE_CODE_SESSION_ID="$SID" tl_worker_actual_model "$AID" 2>"$SCRATCH/wam.err")" || {
    why="$(sed -n 's/^tl_worker_actual_model: //p' "$SCRATCH/wam.err" | head -n 1)"
    blocked "$label: agent $AID (session $SID) answered, but its actual model cannot be determined (${why:-unknown})"
  }
  [ -n "$ids" ] || blocked "$label: agent $AID: tl_worker_actual_model printed nothing"
  for m in $SMODELS; do
    printf '%s\n' "$ids" | grep -qxF -- "$m" \
      || die "$label: the stream and the transcript disagree: the stream shows $m answering, the transcript of agent $AID shows $(printf '%s' "$ids" | paste -sd, -)"
  done
  want="$(tl_model_family "$req")" || want=""
  while IFS= read -r m; do
    if [ -z "$want" ] || [ "$(tl_model_family "$m")" != "$want" ]; then expect="fell-back harness ran $m"; break; fi
  done <<<"$ids"
  VERDICT="$(CLAUDE_CODE_SESSION_ID="$SID" tl_escalation_verify "$AID" "$req")"
  [ "$VERDICT" = "$expect" ] \
    || die "$label: classification disagrees with the transcript: tl_escalation_verify said '$VERDICT', the transcript shows '$expect'"
  ACTUAL="$(printf '%s' "$ids" | paste -sd, -)"
}

line() { printf '%s requested=%s actual=%s verdict=%s\n' "$1" "$2" "$3" "$4"; }

# P1 — the escalation binding.
P1_MODEL="$(tl_escalation_model)"
run_session p1 "$P1_MODEL"
if [ "$REFUSED" = 1 ]; then
  refusal_class P1
  line P1 "$P1_MODEL" refused fell-back
else
  [ "$HAS_NONCE" = 1 ] || die "P1: the dispatch on $P1_MODEL completed without the nonce in the reply ($(first_line "$TEXT"))"
  actual_and_verdict P1 "$P1_MODEL"
  line P1 "$P1_MODEL" "$ACTUAL" "${VERDICT%% *}"
fi

# P2 — a model that does not exist must be refused.
P2_MODEL=claude-nonexistent-0
run_session p2 "$P2_MODEL"
[ "$REFUSED" = 1 ] \
  || die "P2: a dispatch on $P2_MODEL was not refused (is_error=false; reply: $(first_line "$TEXT")); the fall-back rule cannot rely on a dispatch error"
line P2 "$P2_MODEL" refused fell-back

# P3 — positive control on the parent's own alias.
P3_MODEL=opus
run_session p3 "$P3_MODEL"
if [ "$REFUSED" = 1 ]; then
  refusal_class P3
  die "P3: the positive-control dispatch on $P3_MODEL was refused ($(first_line "$TEXT"))"
fi
actual_and_verdict P3 "$P3_MODEL"
[ "$VERDICT" = escalated ] \
  || die "P3: positive control: tl_escalation_verify $AID $P3_MODEL said '$VERDICT' (actual: $ACTUAL), want escalated"
line P3 "$P3_MODEL" "$ACTUAL" escalated
exit 0

#!/usr/bin/env bash
# escalation-probe.sh — live harness probe for TDD 0067 / FR-88 (Verification
# plan observation 14). Run ONLY by the runtime-verify gate, never by
# ci-checks: it starts two real headless sessions and spends real tokens.
#
# It answers the undocumented question directly (ADR 0015): what does a
# subagent dispatch on a given model do? Each probe runs
#   claude -p --model opus --output-format stream-json --verbose "<prompt>"
# whose prompt dispatches exactly one general-purpose subagent with a stated
# `model` and the prompt `Reply with exactly <nonce>` (<nonce>: a fresh random
# hex string). The verdict reads only what the harness or the subagent
# authors for that Agent tool_use, never the parent model's own text:
#   P1  model = tl_escalation_model (THROUGHLINE_ESCALATION_MODEL wins).
#       PASS iff the outcome carries the nonce, is not an error, and no model
#       seen for the subagent is outside the requested model's family.
#   P2  model = claude-nonexistent-0.
#       PASS iff the outcome is an error or lacks the nonce: the signal the
#       FR-88 fall-back rule relies on.
#
# Two stream shapes are read (observed on Claude Code 2.1.289, 2026-10-05):
#   sync   the Agent tool_result (a `user` event, tool_use_id = the Agent
#          tool_use id) carries the subagent's reply and `is_error`.
#   async  the Agent tool_result is only an ack (`tool_use_result.isAsync`,
#          status `async_launched`, text "Async agent launched ..."). The
#          outcome is then the harness's `system`/`task_notification` event
#          for that tool_use_id (`status` completed|failed|…, `summary`), and
#          the reply is the subagent's own `assistant` events
#          (`parent_tool_use_id` = the Agent tool_use id; `<synthetic>`
#          harness error messages excluded): their text and their
#          `SubagentHandback` tool_use `input.message`. The ack's `prompt`
#          field and the `task_started` event echo the nonce and are never
#          read for it.
#   A non-alias model (P2) is refused synchronously: tool_result is_error,
#   `InputValidationError … expected one of "sonnet"|"opus"|"haiku"|"fable"`.
# Models seen for the subagent: the ack's `resolvedModel`, every non-synthetic
# subagent `message.model`, and any "model sent to the API: <id>" in the
# outcome text.
#
# Exit codes:
#   0  both pass;
#   3  `PROBE_BLOCKED: <observation>` — P1 failed (the escalation binding is
#      unusable on this account), P1 ran on another family (silent
#      substitution), or P2 returned the nonce (the harness silently
#      substituted a model, so a fall-back is undetectable);
#   1  no outcome found for a probe's Agent dispatch (malformed run: no
#      dispatch on the stated model, an ack with no task_notification, or the
#      session ended on an API error such as a rate/usage limit before it
#      dispatched), or no claude / jq. The reason is printed on stderr.
# The runtime-verify gate maps 0 → PASS, 3 → VERIFY_RESULT: BLOCKED (never
# PASS), 1 → FAIL (a rate/usage-limit diagnostic is the FR-41 transient case).
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
  || { echo "escalation-probe: '$CLAUDE_BIN' not found, so no tool_result can be observed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 \
  || { echo "escalation-probe: jq is required to read the stream-json events" >&2; exit 1; }
SCRATCH="$(mktemp -d)" || { echo "escalation-probe: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

nonce() { od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; }

# jqp <stream> <program> [jq-options…] — run <program> over each event of a
# stream file, one event per line, parsed tolerantly (a truncated or non-JSON
# line is skipped, never fatal).
jqp() { local f="$1" prog="$2"; shift 2; jq -R "$@" "fromjson? | objects | $prog" "$f" 2>/dev/null; }

# _diag <stream> <model> <claude-rc> — why no outcome was found, one line.
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
        printf 'the session ended on an API error before an outcome (%s) — a rate/usage limit (transient), not a probe verdict' "$apierr" ;;
      *) printf 'the session ended on an API error before an outcome (%s)' "$apierr" ;;
    esac
  elif [ -n "$others" ]; then
    printf 'the parent dispatched the Agent tool, but not with model "%s" (input.model seen: %s)' "$model" "${others% }"
  else
    printf 'no Agent tool_use in the stream (claude rc=%s)' "$rc"
  fi
}

# run_probe <label> <model> — one headless session. Sets FOUND (0|1), SHAPE
# (sync|async|-), IS_ERROR (true|false), HAS_NONCE (0|1), TEXT (the outcome
# text), SEEN (models seen for the subagent, space-separated) and DIAG (why
# FOUND=0). rc 1 only when no nonce can be generated.
run_probe() {
  local label="$1" model="$2" n prompt out id res rc note sub
  FOUND=0; SHAPE=-; IS_ERROR=false; HAS_NONCE=0; TEXT=""; SEEN=""; DIAG=""
  n="$(nonce)"
  [ "${#n}" -eq 32 ] || { echo "escalation-probe: cannot generate a nonce" >&2; return 1; }
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
  # The first top-level (no parent_tool_use_id) Agent tool_use whose input
  # names the stated model.
  id="$(jqp "$out" '
      select(.type == "assistant" and (.parent_tool_use_id // null) == null)
      | .message.content[]? | objects
      | select(.type == "tool_use" and (.name == "Agent" or .name == "Task") and .input.model? == $m)
      | .id | strings' -r --arg m "$model" | head -n 1)"
  [ -n "$id" ] || { DIAG="$(_diag "$out" "$model" "$rc")"; return 0; }
  # Its tool_result, with the ack markers and the harness's resolved model.
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
          resolved: (($ev.tool_use_result | objects | .resolvedModel | strings) // "") }' -c --arg id "$id" | head -n 1)"
  [ -n "$res" ] || { DIAG="no tool_result for the Agent tool_use $id (claude rc=$rc)"; return 0; }
  SEEN="$(printf '%s' "$res" | jq -r '.resolved')"
  # Models the subagent's own (non-synthetic) messages report.
  sub="$(jqp "$out" '
      select(.type == "assistant" and .parent_tool_use_id == $id)
      | .message.model | strings | select(. != "" and . != "<synthetic>")' -r --arg id "$id" | sort -u | tr '\n' ' ')"
  SEEN="$SEEN $sub"
  if [ "$(printf '%s' "$res" | jq -r '.async')" = true ]; then
    SHAPE=async
    note="$(jqp "$out" '
        select(.type == "system" and .subtype == "task_notification" and .tool_use_id == $id)
        | { status: (.status // "" | tostring),
            text: ([.summary, .result] | map(strings) | join("\n")) }' -c --arg id "$id" | head -n 1)"
    [ -n "$note" ] || { DIAG="the Agent tool_use $id launched an async agent, but no task_notification for it arrived (claude rc=$rc)"; return 0; }
    FOUND=1
    [ "$(printf '%s' "$note" | jq -r '.status')" = completed ] || IS_ERROR=true
    TEXT="$(printf '%s' "$note" | jq -r '.text')"
    # The reply, after the harness's summary: the subagent's own text and its
    # SubagentHandback report (input.message), the channel a completed async
    # agent reports through (the summary then only points at it).
    TEXT="$TEXT
$(jqp "$out" '
        select(.type == "assistant" and .parent_tool_use_id == $id and (.message.model // "") != "<synthetic>")
        | .message.content[]? | objects
        | if .type == "text" then (.text | strings)
          elif .type == "tool_use" and .name == "SubagentHandback" then (.input.message? | strings)
          else empty end' -r --arg id "$id")"
  else
    SHAPE=sync
    FOUND=1
    [ "$(printf '%s' "$res" | jq -r '.is_error')" = true ] && IS_ERROR=true
    TEXT="$(printf '%s' "$res" | jq -r '.text')"
  fi
  case "$TEXT" in *"$n"*) HAS_NONCE=1 ;; esac
  SEEN="$SEEN $(printf '%s' "$TEXT" | grep -oE 'model sent to the API: [A-Za-z0-9._:-]+' | sed 's/.*: //' | tr '\n' ' ')"
  SEEN="$(printf '%s\n' $SEEN | grep -v '^$' | sort -u | tr '\n' ' ')"
  SEEN="${SEEN% }"
  return 0
}

first_line() { printf '%s' "$1" | grep -m 1 . | cut -c1-300; }

# off_family <requested> <seen…> — the seen models outside the requested
# model's family, space-separated (empty when none).
off_family() {
  local want m bad=""
  want="$(tl_model_family "$1")" || return 0
  shift
  for m in "$@"; do
    [ "$(tl_model_family "$m")" = "$want" ] || bad="$bad $m"
  done
  printf '%s' "${bad# }"
}

P1_MODEL="$(tl_escalation_model)"
P2_MODEL=claude-nonexistent-0

run_probe p1 "$P1_MODEL" || exit 1
P1_FOUND=$FOUND P1_SHAPE=$SHAPE P1_ERR=$IS_ERROR P1_NONCE=$HAS_NONCE P1_TEXT="$TEXT" P1_SEEN="$SEEN" P1_DIAG="$DIAG"
run_probe p2 "$P2_MODEL" || exit 1
P2_FOUND=$FOUND P2_SHAPE=$SHAPE P2_ERR=$IS_ERROR P2_NONCE=$HAS_NONCE P2_TEXT="$TEXT" P2_SEEN="$SEEN" P2_DIAG="$DIAG"

printf 'P1 model=%s shape=%s tool_result=%s is_error=%s nonce=%s seen=%s\n' \
  "$P1_MODEL" "$P1_SHAPE" "$P1_FOUND" "$P1_ERR" "$P1_NONCE" "${P1_SEEN:--}"
printf 'P2 model=%s shape=%s tool_result=%s is_error=%s nonce=%s seen=%s\n' \
  "$P2_MODEL" "$P2_SHAPE" "$P2_FOUND" "$P2_ERR" "$P2_NONCE" "${P2_SEEN:--}"

missing=""
[ "$P1_FOUND" = 1 ] || missing="P1"
[ "$P2_FOUND" = 1 ] || missing="${missing:+$missing and }P2"
if [ -n "$missing" ]; then
  echo "escalation-probe: no tool_result for the $missing Agent dispatch on the stated model (malformed run)" >&2
  [ "$P1_FOUND" = 1 ] || echo "escalation-probe: P1 ($P1_MODEL): $P1_DIAG" >&2
  [ "$P2_FOUND" = 1 ] || echo "escalation-probe: P2 ($P2_MODEL): $P2_DIAG" >&2
  for l in p1 p2; do
    [ -s "$SCRATCH/$l.err" ] && { echo "--- $l stderr (tail):" >&2; tail -n 5 "$SCRATCH/$l.err" >&2; }
  done
  exit 1
fi

obs=""
if [ "$P1_NONCE" != 1 ] || [ "$P1_ERR" = true ]; then
  obs="P1: a dispatch on the escalation model $P1_MODEL did not return the nonce cleanly (is_error=$P1_ERR; seen: ${P1_SEEN:--}; result: $(first_line "$P1_TEXT")); the escalation binding is unusable on this account"
fi
# shellcheck disable=SC2086  # SEEN is a space-separated list of model ids
p1_off="$(off_family "$P1_MODEL" $P1_SEEN)"
if [ -n "$p1_off" ]; then
  obs="${obs:+$obs; }P1: dispatched as $P1_MODEL but the subagent ran as $p1_off; the harness silently substituted a model, so an escalation outcome would be recorded falsely"
fi
if [ "$P2_ERR" != true ] && [ "$P2_NONCE" = 1 ]; then
  obs="${obs:+$obs; }P2: a dispatch on $P2_MODEL returned the nonce without an error; the harness silently substituted a model, so a fall-back is undetectable"
fi
if [ -n "$obs" ]; then
  printf 'PROBE_BLOCKED: %s\n' "$obs"
  exit 3
fi
printf 'PROBE_PASS: P1 (%s) returned the nonce on %s; P2 (%s) was refused (is_error=%s) or lacked it (result: %s)\n' \
  "$P1_MODEL" "${P1_SEEN:-an unreported model}" "$P2_MODEL" "$P2_ERR" "$(first_line "$P2_TEXT")"
exit 0

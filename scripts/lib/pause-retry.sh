#!/usr/bin/env bash
# pause-retry.sh — Recoverable-failure classification and paused/retry state transitions.
#
# Extracted from scripts/implement.sh per TDD 0016 (Theme D slice 2/3, FR-69):
# the cohesive cluster that recognizes recoverable failure modes (ratelimit,
# transient, usage-limit), enters/exits the `paused` state, manages per-gate
# retry counts, and anchors the current `claude -p` session pointer. Every
# function here either classifies a failure cause or transitions a TDD between
# active and paused states; record_session_pointer travels with them because it
# is called from the same retry-loop entry points (cohesion over alphabetical
# clustering). Gate-driving and resume orchestration stay in implement.sh (and
# move in slice 3).
#
# This module is SOURCED by implement.sh AFTER lib/state.sh, not executed: it has
# no top-level side effects, and every function calls state.sh helpers
# (_write_tdd_fragment, _read_fragment_field, _read_fragment_array_csv, …) plus
# shares the outer shell's scope for the variables the functions read
# ($STATE_DIR, $THROUGHLINE_GATE_RETRIES, $THROUGHLINE_GATE_BACKOFF_BASE,
# $MODEL, $REVIEW_MODEL, …), which the runner sets before these functions are
# called. Shared scope is deliberate for this dogfood slice, matching lib/state.sh.

# --- recoverable-cause classification (TDD 0011 / FR-41) ----------------------
# A small allowlist + exit-signal table that maps a gate's `claude -p` failure
# to one of: ratelimit, usage-limit, transient, fatal. Stdout determines
# routing; an unmatched stderr buffer falls through to `fatal` (NFR-4 honesty —
# ambiguity is never a false paused). Cases are matched left-to-right; first
# match wins. Pattern source lives inline (single call site; auditability
# matters more than reuse).
_recoverable_patterns() {
  # Echoes one "cause:regex" pair per line. The classifier walks this list in
  # order and applies grep -aiE; first hit wins. Patterns are
  # case-insensitive — claude / network errors arrive in mixed casing.
  cat <<'PATTERNS'
ratelimit:(ratelimit|rate_limit|429 |too[- ]many[- ]requests)
usage-limit:(usage[- ]limit|monthly[- ]limit[- ]reached|quota[- ]exceeded)
transient:(connection[- ]reset|timed[- ]out|EAI_AGAIN|temporary failure|503 |502 |504 |gateway timeout)
PATTERNS
}

# _classify_cause <log> <exit_status>  -> echoes one of
#     ratelimit | usage-limit | transient | fatal
# Inspects:
#   - the redirected log's tail (claude prints recoverable error messages
#     before a non-`end_turn` exit), and
#   - the wait-status signal — SIGTERM (143) is `transient` (host shutdown,
#     orderly kill); SIGKILL (137) is `fatal` (we cannot prove it was not a
#     runaway-process kill).
_classify_cause() {
  local log="$1" rc="$2" line pat cause
  # Signal-based decision first: a SIGTERM is a recoverable shutdown signal;
  # a SIGKILL is unrecoverable (out-of-memory, deliberate hard kill, …) and
  # must NEVER promote to paused (NFR-4).
  case "$rc" in
    137) printf 'fatal\n';     return 0 ;;
    143) printf 'transient\n'; return 0 ;;
  esac
  # Pattern-based stderr classification. Last ~2KB of log is the tail.
  if [ -s "$log" ]; then
    local tail
    tail="$(tail -c 4096 "$log" 2>/dev/null)"
    while IFS=':' read -r cause pat; do
      [ -z "$cause" ] && continue
      if printf '%s' "$tail" | grep -aiqE "$pat"; then
        printf '%s\n' "$cause"; return 0
      fi
    done < <(_recoverable_patterns)
  fi
  printf 'fatal\n'
}

# _enter_paused <slug> <cause> [<gate-name>] [<log>]
# Promote the in-flight TDD to status=paused (TDD 0011 / FR-41). Preserves the
# current stage so resume knows where to re-enter; captures the build branch's
# HEAD at pause time into branch_head_at_pause (used by _resume_from to detect
# divergence). The run-level fragment is re-rolled so the rollup reflects ≥1
# paused TDD. The caller exits cleanly so the detached process terminates
# without producing a FAIL verdict.
_enter_paused() {
  local slug="$1" cause="$2" gate_name="${3:-}" log="${4:-}"
  local f="${STATE_DIR:-}/$slug.json"
  # TDD 0011 / MA-2: do NOT silently swallow a missing state fragment.
  # Without the fragment we cannot record paused state, and a silent rc=0
  # would let the run mis-finalize as "done" while the TDD was actually
  # abandoned mid-gate (NFR-4: never silently lose state). Log and return
  # non-zero so _retry_in_gate can route the caller to FAIL instead of
  # paused.
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: _enter_paused cannot record pause for $slug: state fragment missing ($f)" >&2
    [ -n "$log" ] && printf '\nTHROUGHLINE_PAUSE_FAILED: slug=%s cause=%s gate=%s reason=state-fragment-missing ts=%d\n' \
      "$slug" "$cause" "${gate_name:-}" "$(date +%s)" >> "$log"
    return 1
  fi
  # Preserve everything from the existing fragment; only mutate status,
  # paused_cause, and branch_head_at_pause.
  local n qp path stage sta branch pr_url log_f note
  local gates_csv retries_json now branch_head_now
  n="$(sed -n 's/.*"n":\([0-9]*\).*/\1/p'            "$f" | head -1)"
  qp="$(sed -n 's/.*"queue_pos":\([0-9]*\).*/\1/p'   "$f" | head -1)"
  path="$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  if grep -q '"stage":null' "$f" 2>/dev/null; then stage=""
  else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
  sta="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
  branch="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  pr_url="$(sed -n 's/.*"pr_url":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  log_f="$(sed -n 's/.*"log":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  note="$(sed -n 's/.*"note":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"
  retries_json="$(_read_fragment_raw_array "$f" retries)"
  # Capture the build branch HEAD so resume can detect divergence (TDD 0011
  # failure mode: "Build branch HEAD differs at resume from what gates saw").
  branch_head_now="$(git rev-parse --verify HEAD 2>/dev/null || true)"
  now=$(date +%s)
  # TDD 0011 / iter-4 MAJOR-1: check the fragment-write outcome. If it
  # fails (disk full / perm), do NOT call _write_run_fragment paused —
  # otherwise run.json would say `paused` while the per-TDD fragment
  # still says `building`, and the run would exit cleanly with a
  # falsely consistent appearance. Propagate the failure so
  # _retry_in_gate returns FAIL (rc=1), not paused (rc=2).
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" paused "$stage" \
    "${sta:-$now}" "$now" "$branch" "$pr_url" "$log_f" "${note:-paused ($cause)}" \
    "$cause" "$gates_csv" "$retries_json" "$branch_head_now"; then
    echo "error: _enter_paused: could not write per-TDD fragment for $slug; not promoting to paused" >&2
    return 1
  fi
  # TDD 0018 §Sequencing step 4: record the unified halt_cause via the
  # authoritative setter. The fragment is already durably paused (status +
  # paused_cause written above); set_halt_cause now adds halt_cause +
  # halt_next_actions and re-affirms the IDENTICAL paused_cause for the
  # paused-state cause, proving the dual-write shim before TDD 0019's gate
  # writers adopt set_halt_cause. A setter failure here does not un-pause the
  # TDD (the pause is already recorded) — warn and continue. This is the one
  # migrated TDD-0011 paused_cause write site called for in the TDD.
  set_halt_cause "$slug" "$cause" \
    || echo "warning: _enter_paused: set_halt_cause failed for $slug (cause=$cause); halt_cause not recorded" >&2
  # TDD 0011 / iter-4 MAJOR-2: warn on run.json write failure. The
  # rollup is re-derivable from per-TDD fragments so this is not
  # fatal, but a stale run.json.state misleads any direct consumer.
  _write_run_fragment paused || echo "warning: _enter_paused: run.json not updated to paused for $slug" >&2
  # Best-effort: append a marker to the per-TDD log so a future operator
  # has a clear timestamped paused entry above the resume timestamp.
  if [ -n "$log" ] && [ -w "$(dirname "$log")" ] 2>/dev/null; then
    printf '\nTHROUGHLINE_PAUSED: slug=%s cause=%s gate=%s ts=%d\n' \
      "$slug" "$cause" "${gate_name:-}" "$now" >> "$log"
  fi
}

# _retry_in_gate <gate-fn> <gate-name> <slug> <log> <args...>
# (TDD 0011 / FR-42) — wrap one of the LLM gate calls with bounded
# transient-error retry. Algorithm:
#   for attempt in 1..MAX_RETRIES:
#     run gate-fn "$@"
#     if rc==0:           return 0 (success; gate may proceed)
#     classify the log + rc:
#       cause=fatal → return 1 (fail; do NOT retry; gate halts)
#       cause=ratelimit/usage-limit/transient → record retry, sleep backoff
#   exhausted → _enter_paused; return 2 (caller maps rc=2 to "paused, not
#   flipped", distinct from rc=1 "failed")
# Env knobs: THROUGHLINE_GATE_RETRIES (default 3), THROUGHLINE_GATE_BACKOFF_BASE
# (default 30s). Backoff schedule: BASE * 4^(attempt-1) ⇒ 30, 120, 480s.
_retry_in_gate() {
  local gate_fn="$1" gate_name="$2" slug="$3" log="$4"; shift 4
  local max_retries="${THROUGHLINE_GATE_RETRIES:-3}"
  local backoff_base="${THROUGHLINE_GATE_BACKOFF_BASE:-30}"
  # TDD 0011 / iter-3 MAJOR-3: validate env-var inputs are purely numeric
  # BEFORE they reach bash arithmetic. `$(( $max_retries ))` with an
  # attacker-controlled non-numeric value triggers bash's well-known
  # arithmetic-injection vector (the inner string is evaluated as a bash
  # expression, allowing `a[$(cmd)]`-style command substitution). Fall
  # back to defaults on invalid input + warn so misconfiguration is
  # visible.
  case "$max_retries" in
    ''|*[!0-9]*) echo "warning: THROUGHLINE_GATE_RETRIES='$max_retries' not numeric; falling back to 3" >&2; max_retries=3 ;;
    0) echo "warning: THROUGHLINE_GATE_RETRIES=0 not allowed (would cause immediate paused-with-no-attempt); normalizing to 1" >&2; max_retries=1 ;;
  esac
  # TDD 0011 / iter-5 MAJOR-5: cap the upper bound. backoff_base * 4^(n-1)
  # overflows signed 64-bit around attempt=30, producing negative values
  # that skip the sleep guard. Even before overflow, attempt~20 produces
  # ~8e6 seconds (months) of sleep — unhelpful. 10 retries is a safe upper
  # bound (final backoff is base*4^9 ≈ 70h with default base=30).
  if [ "$max_retries" -gt 10 ] 2>/dev/null; then
    echo "warning: THROUGHLINE_GATE_RETRIES=$max_retries exceeds cap of 10; capping (4^attempt overflows / huge sleeps)" >&2
    max_retries=10
  fi
  case "$backoff_base" in
    ''|*[!0-9]*) echo "warning: THROUGHLINE_GATE_BACKOFF_BASE='$backoff_base' not numeric; falling back to 30" >&2; backoff_base=30 ;;
  esac
  # TDD 0011 / iter-9 SEC-2: cap the backoff base. Without an upper bound,
  # `BACKOFF_BASE=86400` would produce 86400 * 4^2 = ~16-day sleeps on the
  # third attempt, holding the single-run lock and blocking the repo for
  # days. 3600s (1h) base is plenty for any legitimate rate-limit retry.
  if [ "$backoff_base" -gt 3600 ] 2>/dev/null; then
    echo "warning: THROUGHLINE_GATE_BACKOFF_BASE=$backoff_base exceeds cap of 3600s; capping (would hold the single-run lock for many hours)" >&2
    backoff_base=3600
  fi
  local attempt cause rc backoff
  for (( attempt=1; attempt<=max_retries; attempt++ )); do
    "$gate_fn" "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
    cause="$(_classify_cause "$log" "$rc")"
    if [ "$cause" = "fatal" ]; then return 1; fi
    # TDD 0011 / iter-3 MAJOR-1: backoff schedule MUST match the TDD's
    # documented sequence BASE * 4^(attempt-1) on EVERY failed attempt,
    # including the final one before promoting to paused. Previously the
    # last sleep was forced to 0, which meant a rate-limit clearing in
    # under 8 minutes (after the third attempt) produced a spurious
    # paused state. The audit record now reflects the actual upcoming
    # sleep — including the final one — for honesty.
    backoff=$(( backoff_base * (4 ** (attempt - 1)) ))
    # TDD 0011 / iter-9 M-1: on the FINAL attempt the sleep is wasted —
    # no further gate call follows it. Skip it to avoid up to 480s of
    # gratuitous wall-clock delay before writing the paused fragment.
    # Audit the planned backoff still (so the retries[] entry matches the
    # schedule), but use 0 in the actual sleep guard.
    # TDD 0011 / iter-9 SF-1: surface _append_retry failures (otherwise
    # disk-full would silently drop the retry record and break iter-6
    # MA-1's retries-proxy guard).
    _append_retry "$slug" "$gate_name" "$attempt" "$backoff" \
      || echo "warning: _retry_in_gate: retry audit write failed for $slug (attempt $attempt)" >&2
    if [ "$attempt" -lt "$max_retries" ] && [ "$backoff" -gt 0 ]; then
      sleep "$backoff"
    fi
    if [ "$attempt" -ge "$max_retries" ]; then
      # TDD 0011 / MA-2: propagate _enter_paused failure. If we can't
      # record paused state, return FAIL (1) instead of paused (2) so
      # the run-level fragment doesn't roll up to a false `done`.
      if ! _enter_paused "$slug" "$cause" "$gate_name" "$log"; then
        return 1
      fi
      return 2
    fi
  done
  # Defensive: loop should always return inside; if we get here, treat as
  # paused (NFR-4 — never silently lose state). Reached when max_retries
  # is 0 (the loop body never runs); `cause` is unset in that case so
  # fall back to a literal label for the audit.
  if ! _enter_paused "$slug" "${cause:-transient}" "$gate_name" "$log"; then
    return 1
  fi
  return 2
}

# _append_retry <slug> <gate-name> <count> <backoff_s>
# Append one retry record to the per-TDD fragment's retries[] array. Used
# only by _retry_in_gate. Reads the existing fragment, splices a new entry
# into retries[], and rewrites via _write_tdd_fragment so every other field
# is round-tripped unchanged.
_append_retry() {
  local slug="$1" gate_name="$2" count="$3" backoff="$4"
  local f="${STATE_DIR:-}/$slug.json"
  [ -n "$STATE_DIR" ] && [ -f "$f" ] || return 0
  local n qp path status stage sta upd branch pr_url log_f note
  local paused_cause gates_csv retries_json branch_head
  local halt_cause halt_finding halt_actions_csv halt_detail
  n="$(sed -n 's/.*"n":\([0-9]*\).*/\1/p'            "$f" | head -1)"
  qp="$(sed -n 's/.*"queue_pos":\([0-9]*\).*/\1/p'   "$f" | head -1)"
  path="$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  status="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  if grep -q '"stage":null' "$f" 2>/dev/null; then stage=""
  else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
  sta="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
  upd="$(sed -n 's/.*"updated_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
  branch="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  pr_url="$(sed -n 's/.*"pr_url":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  log_f="$(sed -n 's/.*"log":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  note="$(sed -n 's/.*"note":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  paused_cause="$(_read_fragment_field "$f" paused_cause)"
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"
  retries_json="$(_read_fragment_raw_array "$f" retries)"
  branch_head="$(_read_fragment_field "$f" branch_head_at_pause)"
  # TDD 0018: carry any halt metadata forward (a retry audit append must not
  # wipe halt_cause / next-actions if one was already recorded).
  halt_cause="$(_read_fragment_field "$f" halt_cause)"
  halt_finding="$(_read_fragment_field "$f" halt_triggering_finding_ref)"
  halt_actions_csv="$(_read_fragment_array_csv "$f" halt_next_actions)"
  halt_detail="$(_read_fragment_field "$f" halt_cause_detail)"
  local entry new
  entry="{\"gate\":\"$(json_escape "$gate_name")\",\"count\":$count,\"backoff_s\":$backoff}"
  # TDD 0011 / BL-5: validate that retries_json is well-formed before
  # splicing. A truncated array from a torn read (despite tmp+mv atomicity,
  # a reader can race against a partial write window of a long string field
  # somewhere else in the fragment if the runner is ever extended) would
  # otherwise produce invalid JSON: `${retries_json%]}` strips nothing,
  # and the splice yields `[…,{…}]` with no inner closing bracket. The
  # next read returns empty, retries[] silently resets, and the audit trail
  # is lost. Refuse to splice into a non-`]`-terminated array; warn and
  # restart the trail. (The trail is recorded twice in practice: in the
  # log via _retry_in_gate's printf, and in the fragment; the warning
  # ensures the discontinuity is visible.)
  if [ -z "$retries_json" ] || [ "$retries_json" = "[]" ]; then
    new="[$entry]"
  elif [ "${retries_json: -1}" != ']' ]; then
    echo "warning: retries[] for $slug was malformed (no closing ']'); resetting audit trail" >&2
    new="[$entry]"
  else
    # Splice before the closing bracket. The retries entries are flat
    # objects with no nested brackets, so this is unambiguous.
    new="${retries_json%]},$entry]"
  fi
  # TDD 0011 / iter-5 MAJOR-1: propagate write failures so a failed retry-
  # audit append doesn't silently disappear into a stale fragment.
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$(date +%s)}" "$(date +%s)" "$branch" "$pr_url" "$log_f" "$note" \
    "$paused_cause" "$gates_csv" "$new" "$branch_head" \
    "$halt_cause" "$halt_finding" "$halt_actions_csv" "$halt_detail"; then
    echo "error: _append_retry: could not write $slug fragment (retry audit lost)" >&2
    return 1
  fi
}

# record_session_pointer: `claude -p` redirects only its FINAL assistant message
# (the `end_turn` text) to stdout. If a run ends without `end_turn` — turn cap,
# external kill, ratelimit, or the build accidentally pkill'ing its own parent —
# the redirected log is near-empty, and the runner's `FAIL (no BATCH_RESULT;
# see log)` is correct but useless for triage. The full transcript still exists
# at ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl. This helper finds it (newest
# .jsonl in the cwd-encoded project dir, modified at or after the call started)
# and appends a `THROUGHLINE_SESSION:` pointer plus the last few tool calls to
# the log, so a FAIL like that is diagnosable from the log itself.
record_session_pointer() {  # <log> <start-epoch>
  local log="$1" start="$2" enc proj sess
  enc="$(printf '%s' "$PWD" | sed 's|/|-|g')"
  proj="$HOME/.claude/projects/$enc"
  [ -d "$proj" ] || return 0
  sess="$(find "$proj" -maxdepth 1 -name "*.jsonl" -newermt "@$start" -printf '%T@\t%p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -f2)"
  [ -n "$sess" ] || return 0
  {
    echo
    echo "THROUGHLINE_SESSION: $sess"
    if command -v jq >/dev/null 2>&1; then
      echo "Last assistant tool calls (newest last; up to 5):"
      jq -r 'select(.type=="assistant") | .message.content // [] | .[] | select(.type=="tool_use") | "  \(.name)\t\((.input|tostring)[:140])"' \
        "$sess" 2>/dev/null | tail -5
    fi
  } >>"$log"
}

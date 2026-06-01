#!/usr/bin/env bash
# resume.sh — Resume orchestration: re-enter paused runs, decide which gates to
# re-drive, plus the per-TDD gate sequencer and build-branch resolution helpers.
#
# Extracted from scripts/implement.sh per TDD 0017 (Theme D slice 3/3, FR-69):
# the cluster that picks up a paused TDD's persisted state and computes which of
# the four gates still need to run (_resume_gates_var, _update_paused_cause,
# _resume_from), drives the build → test-first → ci-checks.sh → runtime-verify →
# review → flip sequence for a single TDD (gate_one), and resolves a TDD's
# already-built branch on a re-run (built_branch, combined_built_branch).
#
# This module is SOURCED by implement.sh AFTER lib/state.sh, lib/pause-retry.sh,
# AND lib/gates.sh, not executed: gate_one calls the gate executors in gates.sh
# and the resume helpers call state.sh + pause-retry.sh helpers; all are resolved
# at call time, so the module sources standalone (top-level only declares
# functions). It shares the outer shell's scope for the variables the functions
# read ($REBUILD, $BASE, $TDDS, $COMBINED, $RESUME, $INTEGRATION, $STATE_DIR, …),
# which the runner sets before these functions are called. Shared scope is
# deliberate for this dogfood slice, matching lib/state.sh.

# _resume_gates_var <slug> — convert a slug to a shell-safe variable name
# (RESUME_GATES_DONE_<slug-with-non-alnum-replaced>). Used to set a per-TDD
# resume hint without conflicting with shell variable name rules.
_resume_gates_var() {
  printf 'RESUME_GATES_DONE_%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_')"
}

# _update_paused_cause <slug> <new-cause>
# Mutate just the paused_cause field of a paused fragment. Used by
# _resume_from to mark resume-blocked fragments. All other fields are
# round-tripped via _write_tdd_fragment.
_update_paused_cause() {
  local slug="$1" new_cause="$2"
  local f="${STATE_DIR:-}/$slug.json"
  # TDD 0011 / MAJOR-6: fail loudly on missing fragment instead of silent
  # return 0. _update_paused_cause is called only from _resume_from's
  # refuse-to-resume paths where the fragment MUST exist — silently
  # swallowing the absence would let the refusal vanish and the driver
  # fall through to a silent rebuild (mirrors the _enter_paused MA-2 fix).
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    echo "error: _update_paused_cause cannot record cause for $slug: state fragment missing ($f)" >&2
    return 1
  fi
  local n qp path status stage sta branch pr_url log_f note
  local gates_csv retries_json branch_head
  n="$(sed -n 's/.*"n":\([0-9]*\).*/\1/p'            "$f" | head -1)"
  qp="$(sed -n 's/.*"queue_pos":\([0-9]*\).*/\1/p'   "$f" | head -1)"
  path="$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  status="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  if grep -q '"stage":null' "$f" 2>/dev/null; then stage=""
  else stage="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
  sta="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p' "$f" | head -1)"
  branch="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  pr_url="$(sed -n 's/.*"pr_url":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  log_f="$(sed -n 's/.*"log":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  note="$(sed -n 's/.*"note":"\([^"]*\)".*/\1/p'     "$f" | head -1)"
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"
  retries_json="$(_read_fragment_raw_array "$f" retries)"
  branch_head="$(_read_fragment_field "$f" branch_head_at_pause)"
  # TDD 0019: carry the halt metadata and rework telemetry forward — a
  # paused_cause mutation on a refuse-to-resume path must not wipe a recorded
  # halt_cause/next-actions or the rework_log the FR-68 comparison reads.
  local halt_cause halt_finding halt_actions_csv halt_detail
  local rework_attempts rework_log build_attempt
  halt_cause="$(_read_fragment_field "$f" halt_cause)"
  halt_finding="$(_read_fragment_field "$f" halt_triggering_finding_ref)"
  halt_actions_csv="$(_read_fragment_array_csv "$f" halt_next_actions)"
  halt_detail="$(_read_fragment_field "$f" halt_cause_detail)"
  rework_attempts="$(_read_fragment_raw_object "$f" rework_attempts)"
  rework_log="$(_read_fragment_raw_array "$f" rework_log)"
  build_attempt="$(_read_fragment_raw_object "$f" build_attempt)"
  # TDD 0020: carry the cleared-step fields forward (a paused_cause mutation on a
  # refuse-to-resume path must not wipe last_cleared_review_sha / cleared_step_log).
  local last_cleared_sha cleared_step_log
  last_cleared_sha="$(_read_fragment_field "$f" last_cleared_review_sha)"
  cleared_step_log="$(_read_fragment_cleared_log "$f")"
  # TDD 0011 / iter-5 MAJOR-1: propagate write failures.
  if ! _write_tdd_fragment "$slug" "${n:-0}" "$path" "${qp:-0}" "$status" "$stage" \
    "${sta:-$(date +%s)}" "$(date +%s)" "$branch" "$pr_url" "$log_f" "$note" \
    "$new_cause" "$gates_csv" "$retries_json" "$branch_head" \
    "$halt_cause" "$halt_finding" "$halt_actions_csv" "$halt_detail" \
    "$rework_attempts" "$rework_log" "$build_attempt" \
    "$last_cleared_sha" "$cleared_step_log"; then
    echo "error: _update_paused_cause: could not write $slug fragment (cause=$new_cause)" >&2
    return 1
  fi
}

# _resume_from <slug> (TDD 0011 / FR-40; resume mechanism revised by TDD 0024)
# Validate that <slug>'s paused fragment is resumable; if so, set the
# RESUME_GATES_DONE_<slug> variable listing the gates already completed
# (build / test-first / verify / verify-runtime / review). The per-TDD fragment's
# gates_completed array is the SOLE source of truth for EVERY gate, including
# gate 1 (build): its "build" entry is written by gate_one only when the build
# emitted BATCH_RESULT: OK. Partial commits on the branch (test(failing): + feat:
# pairs that landed before an interruption) are NOT a proxy for build completion
# (TDD 0024 / FR-40 revised) and are no longer scanned — a missing "build" entry
# re-runs gate 1 (build_one is idempotent at the prompt level: it reads the
# branch state and either no-ops on completed steps or extends the remaining
# ones). On a refuse-to-resume condition, updates paused_cause to:
#   resume-blocked-branch-divergence
# and leaves the RESUME_GATES_DONE_<slug> variable unset.
_resume_from() {
  local slug="$1" f var
  f="${STATE_DIR:-}/$slug.json"
  # TDD 0011 / iter-4 MAJOR-4: under --resume the fragment MUST exist
  # (state_init's queue-freeze already filtered TDDs without fragments).
  # Returning 0 (success) here would let callers treat the missing
  # fragment as "not paused, proceed normally" — gate_one's own MA-4
  # guard then sets blocked=1, marking ALL downstream sequential TDDs
  # as BLOCKED instead of pausing this one. Refuse with rc=3 so the
  # driver halts cleanly. Outside --resume the helper is harmless to
  # call defensively, so keep the silent-0 path for that case.
  if [ -z "${STATE_DIR:-}" ] || [ ! -f "$f" ]; then
    if [ "${RESUME:-0}" -eq 1 ]; then
      echo "error: _resume_from $slug: state fragment missing under --resume; refusing to proceed" >&2
      return 3
    fi
    return 0
  fi
  var="$(_resume_gates_var "$slug")"
  local fragment_status
  fragment_status="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  if [ "$fragment_status" != "paused" ]; then
    # TDD 0027 §3c / FR-39: a blocked halt whose halt_next_actions begins with a
    # resume action (e.g. rework-scope-exceeded → "resume (retries with stricter
    # scope)") is recoverable. Accept it by flipping the fragment to
    # paused/transient — the exact edit that previously required hand-surgery —
    # then fall through to the same validation a paused fragment runs. Any other
    # non-paused status, and a blocked fragment whose actions are design
    # escalations only, is not resumable: return 0 so the caller proceeds
    # normally.
    local _halt_actions
    _halt_actions="$(sed -n 's/.*\("halt_next_actions":\[[^]]*\]\).*/\1/p' "$f" | head -1)"
    if [ "$fragment_status" = "blocked" ] && printf '%s' "$_halt_actions" | grep -qE '(\[|,)"resume'; then
      local _stage_now
      if grep -q '"stage":null' "$f" 2>/dev/null; then _stage_now=""
      else _stage_now="$(sed -n 's/.*"stage":"\([^"]*\)".*/\1/p' "$f" | head -1)"; fi
      set_tdd_state "$slug" paused "$_stage_now" \
        || echo "warning: _resume_from $slug: could not flip blocked->paused for resume" >&2
      _update_paused_cause "$slug" transient \
        || echo "warning: _resume_from $slug: could not set paused_cause=transient for resume" >&2
    else
      return 0
    fi
  fi

  local branch branch_head_at_pause gates_csv
  branch="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$f" | head -1)"
  branch_head_at_pause="$(_read_fragment_field "$f" branch_head_at_pause)"
  gates_csv="$(_read_fragment_array_csv "$f" gates_completed)"

  # Build-gate completion is read straight from gates_completed (TDD 0024 /
  # FR-40 revised) — there is no commit-history scan. The prior Source-A logic
  # (scan the branch for a `test(failing):` commit, with a combined-mode bypass
  # and a no-merge-base "resume-blocked-build-state-missing" refuse) is removed:
  # partial commits are NOT a proxy for build completion, and "gates_completed
  # is authoritative; if 'build' is absent, re-run gate 1" is correctly safe in
  # every situation the old refuse covered (degraded merge-base evidence,
  # shared combined-mode branches) without needing a refuse-to-resume gate.
  # Re-running gate 1 is safe: build_one is idempotent at the prompt level —
  # it reads the current branch state and either no-ops on already-committed
  # sequencing steps or extends with the remaining ones.

  # Divergence: if the fragment recorded a HEAD SHA at pause time and the
  # current branch ref differs, the branch was rewritten while paused.
  # TDD 0011 / BLOCKER-1+MAJOR-10: resolve via refs/heads/$branch (not the
  # process's HEAD) so the check is correct regardless of CWD. This is
  # what fixes parallel-mode resume — the previous HEAD-based check saw
  # the main repo's HEAD when called outside the subshell.
  if [ -n "$branch_head_at_pause" ] && [ -n "$branch" ]; then
    local current_head
    current_head="$(git rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)"
    if [ -n "$current_head" ] && [ "$current_head" != "$branch_head_at_pause" ]; then
      # TDD 0027 §3b / FR-41: a head difference is not always a rewrite. If the
      # recorded SHA is an ANCESTOR of the current head, the branch merely
      # advanced (commits added, none rewritten) — e.g. the runner was killed
      # after committing but before updating the fragment. That is continuation,
      # not rewrite: accept it, advance branch_head_at_pause to the current head,
      # and fall through to resume. A non-ancestor head (true rewrite, or a
      # deleted/recreated branch where merge-base fails) is refused exactly as
      # before.
      if git merge-base --is-ancestor "$branch_head_at_pause" "$current_head" 2>/dev/null; then
        _update_branch_head_at_pause "$slug" "$current_head" \
          || echo "warning: _resume_from $slug: could not advance branch_head_at_pause after fast-forward" >&2
      else
        # iter-10 M-3: expose cause via global for drivers.
        RESUME_REFUSE_CAUSE="resume-blocked-branch-divergence"
        _update_paused_cause "$slug" "$RESUME_REFUSE_CAUSE" \
          || echo "warning: _resume_from $slug: could not update paused_cause (status.sh may show stale cause)" >&2
        return 3   # see BLOCKER-2
      fi
    fi
  fi

  # All checks pass: the done-list IS the recorded gates_completed, verbatim
  # (TDD 0024 / FR-40 revised). Sequential and combined modes use identical
  # logic — gate 1 appears here only when gates_completed records "build" (i.e.
  # the prior attempt reached BATCH_RESULT: OK). Every gate, including build, is
  # grounded in the explicit run-state record, not an inferred commit pattern.
  local done_list="$gates_csv"
  printf -v "$var" '%s' "$done_list"
  export "${var?}"
}

# gate_one: build -> classify -> test-first -> ci-checks.sh -> runtime-verify ->
# independent review -> flip. Echoes a one-line status; returns 0 ONLY when the
# TDD was flipped to implemented. Every transition publishes status/stage to the
# per-TDD fragment (FR-27) so /implement-status sees the live state.
#
# Status enum: pending → building → verifying → reviewing → done | failed |
# blocked | skipped. Stage enum: build / test-first / verify / verify-runtime /
# review / flip / null. Runtime-verify BLOCKED maps to status=blocked (distinct
# from FAIL per NFR-4) but is NOT a design blocker — only build BATCH_RESULT:
# BLOCKED appends to BLOCKERS.md (see record_blocker).

# gate_one — build → test-first → ci-checks.sh → runtime-verify → review → flip.
# Return codes:
#   0 — TDD flipped to implemented
#   1 — gate failed (existing FAIL/BLOCKED semantics)
#   2 — gate paused (TDD 0011 / FR-41) — drivers MUST stop iterating and not
#       mark downstream as BLOCKED
#
# Resume-aware: when launched with --resume, _resume_from has set
# RESUME_GATES_DONE_<slug> listing the gates already complete; gate_one
# skips those gates. Each successfully-completed gate is recorded into
# gates_completed via set_tdd_state's 5th param (TDD 0011 / FR-40).
gate_one() {  # <tdd> <review-base-ref> <log>
  local tdd="$1" rbase="$2" log="$3" bs rvs slug rrc _retries_json=""
  slug="$(basename "$tdd" .md)"
  # TDD 0019 carry-over fix 4 (TDD 0017 review): STATE_DIR is the resume entry's
  # one hard precondition — state_init sets it unconditionally. An unset
  # STATE_DIR would otherwise expand `${STATE_DIR:-}/$slug.json` to `/$slug.json`
  # (or trip `set -u` in set_tdd_meta) and silently corrupt progress tracking.
  # Fail loud instead so a misconfigured caller halts rather than misclassifies.
  if [ -z "${STATE_DIR:-}" ]; then
    echo "FATAL: gate_one: STATE_DIR unset (state_init must run before any gate)" >&2
    return 1
  fi
  # TDD 0011 / MA-4 belt-and-suspenders: refuse to process a slug whose state
  # fragment is missing. state_init's queue-freeze should have dropped any
  # newly-added TDDs from TDDS on resume, but defending here means a stray
  # call can never produce an untracked build.
  if [ -n "${STATE_DIR:-}" ] && [ ! -f "$STATE_DIR/$slug.json" ]; then
    echo "FAIL (no state fragment for $slug; queue-freeze should have dropped it)" >&2
    return 1
  fi
  set_tdd_meta "$slug" "log=$log"

  local _rkey _resume_done
  _rkey="$(_resume_gates_var "$slug")"
  _resume_done="${!_rkey:-}"
  _is_done() { case ",$_resume_done," in *",$1,"*) return 0;; esac; return 1; }

  # --- Gate 1: build (LLM-driven; retry-eligible) --------------------------
  if _is_done build; then
    : # branch already carries the impl + test(failing): commit; skip
  else
    set_tdd_state "$slug" building build
    _retry_in_gate _build_one_gated build "$slug" "$log" "$tdd" "$log"
    rrc=$?
    # TDD 0011 / BL-1: paused short-circuit MUST run before any BATCH_RESULT
    # scan of the cumulative log. After a retry sequence the log carries
    # earlier attempts' verdict lines; build_status (a tail-1 over the log)
    # can then surface a stale BLOCKED from a prior attempt and re-classify
    # a clean pause as a design blocker, corrupting BLOCKERS.md. Returning
    # 2 here makes the pause terminal for this run; the runtime-verify and
    # review gates already follow the same ordering.
    if [ "$rrc" -eq 2 ]; then
      echo "PAUSED build (see paused_cause in run state)"; return 2; fi
    # TDD 0011 / iter-6 MAJOR-1: when retries occurred, the cumulative
    # log may carry stale verdict lines from prior transient attempts.
    # If `_retry_in_gate` classified the latest attempt fatal AND retries
    # happened, do NOT consult the log's verdict (tail -1 would surface
    # an old BLOCKED from attempt 1 and corrupt BLOCKERS.md). Without
    # retries, the log's latest verdict IS the only verdict and can be
    # trusted. Use the fragment's retries[] count as the proxy.
    _retries_json="$(_read_fragment_raw_array "$STATE_DIR/$slug.json" retries 2>/dev/null)"
    if [ "$rrc" -ne 0 ] && [ -n "$_retries_json" ] && [ "$_retries_json" != "[]" ]; then
      _terminal_state "$slug" failed "" "build gate fatal exit after retries (rc=$rrc)"
      echo "FAIL build (fatal exit after retries; see log)"; return 1
    fi
    bs="$(build_status "$log")"
    case "$bs" in
      *BLOCKED*) record_blocker "$tdd" "${bs#*BLOCKED}"
                 _terminal_state "$slug" blocked "" "build BLOCKED (design):${bs#*BLOCKED}"
                 echo "BLOCKED (design)${bs#*BLOCKED}"; return 1 ;;
    esac
    case "$bs" in
      # TDD 0024 / FR-40 (revised): record build-gate completion explicitly the
      # moment BATCH_RESULT: OK is observed. gates_completed is now the SOLE
      # source of truth for build-gate completion on resume — the 5th param
      # appends "build" to the carried-forward array (same additive contract as
      # test-first / verify / verify-runtime below). A swallowed write would let
      # a later resume re-run a completed build, so surface failures on stderr.
      *OK*) set_tdd_state "$slug" building build "" build \
              || echo "warning: gate_one: could not record build completion for $slug" >&2 ;;
      *) _terminal_state "$slug" failed "" "build did not return OK (${bs:-no BATCH_RESULT})"
         echo "${bs:-FAIL (no BATCH_RESULT; see log)}"; return 1 ;;
    esac
  fi

  # --- Gate 2: test-first + ci-checks.sh (mechanical; never retried) ----------
  if ! _is_done test-first; then
    set_tdd_state "$slug" verifying test-first
    if ! test_first_ok "$rbase" "$log"; then
      _terminal_state "$slug" failed "" "test-first gate: no failing-test-first commit"
      echo "FAIL test-first (no failing-test-first commit and no TEST_FIRST: SKIPPED; not flipped)"; return 1; fi
    # TDD 0011 / iter-9 SF-2: gate-completion writes feed FR-40's
    # resume hint; a swallowed failure would let resume re-run completed
    # gates. Surface failures via stderr.
    set_tdd_state "$slug" verifying test-first "" test-first \
      || echo "warning: gate_one: could not record test-first completion for $slug" >&2
  fi
  if ! _is_done verify; then
    set_tdd_state "$slug" verifying verify
    if ! run_ci_checks "$log"; then
      _terminal_state "$slug" failed "" "ci-checks.sh FAIL (tests/typecheck/lint)"
      echo "FAIL verification (tests/typecheck/lint red; not flipped)"; return 1; fi
    set_tdd_state "$slug" verifying verify "" verify \
      || echo "warning: gate_one: could not record verify completion for $slug" >&2
  fi

  # --- Gate 3: runtime-verify (LLM-driven; retry-eligible) -----------------
  if [ "${THROUGHLINE_REQUIRE_RUNTIME_VERIFY:-1}" = "1" ] && ! _is_done verify-runtime; then
    set_tdd_state "$slug" verifying verify-runtime
    _retry_in_gate _verify_runtime_one_gated verify-runtime "$slug" "$log" "$tdd" "$rbase" "$log"
    rrc=$?
    # TDD 0011 / MAJOR-4: paused short-circuit MUST run before any verdict
    # scan (same as gate 1 / BL-1). A stale `VERIFY_RUNTIME: BLOCKED` line
    # from a transient earlier attempt would otherwise misclassify a fatal
    # failure as status=blocked, violating NFR-4 verdict honesty.
    if [ "$rrc" -eq 2 ]; then
      echo "PAUSED runtime-verify"; return 2; fi
    # TDD 0011 / iter-6 MAJOR-1: only bypass log-verdict scan when retries
    # occurred (cumulative log may carry stale entries). Same proxy as
    # gate 1.
    _retries_json="$(_read_fragment_raw_array "$STATE_DIR/$slug.json" retries 2>/dev/null)"
    if [ "$rrc" -ne 0 ] && [ -n "$_retries_json" ] && [ "$_retries_json" != "[]" ]; then
      _terminal_state "$slug" failed "" "runtime-verify gate fatal exit after retries (rc=$rrc)"
      echo "FAIL runtime-verify (fatal exit after retries; see log)"; return 1
    fi
    rvs="$(verify_runtime_status "$log")"
    case "$rvs" in
      *PASS*|*SKIP*) set_tdd_state "$slug" verifying verify-runtime "" verify-runtime \
                       || echo "warning: gate_one: could not record verify-runtime completion for $slug" >&2 ;;
      *BLOCKED*) _terminal_state "$slug" blocked "" "runtime-verify BLOCKED (couldn't observe)"
                 echo "BLOCKED runtime-verify (couldn't observe)${rvs#*BLOCKED}"; return 1 ;;
      *FAIL*)    _terminal_state "$slug" failed "" "runtime-verify FAIL"
                 echo "FAIL runtime-verify${rvs#*FAIL}"; return 1 ;;
      *) _terminal_state "$slug" failed "" "runtime-verify: no VERIFY_RUNTIME line"
         echo "FAIL runtime-verify (no VERIFY_RUNTIME line; ambiguity is never a false PASS; see log)"; return 1 ;;
    esac
  fi

  # --- Gate 4: review + bounded rework loop (TDD 0019 / FR-61, FR-62) -------
  # Per ADR 0007 a review BLOCK no longer halts on first failure: a halting
  # finding (FR-58) triggers the bounded automatic rework loop in this same
  # invocation. _rework_loop runs the review, and on a halting finding either
  # escalates (structural / budget-exhausted → records halt + BLOCKERS entry +
  # blocked terminal state) or runs one bounded Sonnet rework + mechanical
  # pre-pass and re-reviews — converging or escalating without user input.
  if ! _is_done review; then
    set_tdd_state "$slug" reviewing review
    _rework_loop "$slug" "$tdd" "$rbase" "$log"
    rrc=$?
    case "$rrc" in
      0) set_tdd_state "$slug" reviewing review "" review \
           || echo "warning: gate_one: could not record review completion for $slug" >&2 ;;
      2) echo "PAUSED review"; return 2 ;;
      *) # _rework_loop already recorded the halt cause + BLOCKERS entry +
         # blocked/failed terminal state; surface a one-line verdict for the
         # report from the fragment's recorded cause.
         local _hc; _hc="$(_read_fragment_field "$STATE_DIR/$slug.json" halt_cause 2>/dev/null)"
         if [ -n "$_hc" ]; then echo "BLOCKED review ($_hc)"; else echo "FAIL review (see log)"; fi
         return 1 ;;
    esac
  fi

  set_tdd_state "$slug" reviewing flip
  # TDD 0019 carry-over fix 1: a failed flip commit must halt honestly, not
  # report a false OK. flip_status now returns non-zero on git add/commit
  # failure; mark the TDD failed and do NOT flip.
  if ! flip_status "$tdd" "$log"; then
    _terminal_state "$slug" failed "" "flip commit failed (status NOT flipped; see log)"
    echo "FAIL flip (could not commit the implemented flip; see log)"; return 1
  fi
  _terminal_state "$slug" "done" "" "OK (verified + reviewed)"
  echo "OK (verified + reviewed)"; return 0
}

# --- resume support ------------------------------------------------------------
# The done-signal (Status: implemented) is committed on the build branch, not on
# your BASE, until you merge. These helpers read real branch state so a re-run
# skips work that is done-but-unmerged instead of rebuilding it. --rebuild forces.
built_branch() {  # <tdd> -> echoes the TDD's own build branch if already implemented
  [ "$REBUILD" -eq 1 ] && return 1
  local tdd="$1" slug; slug="$(basename "$tdd" .md)"; local ref
  while IFS= read -r ref; do
    case "$ref" in
      "$BASE"|"origin/$BASE") continue ;;
      */"$slug")
        git show "$ref:$tdd" 2>/dev/null | grep -qE '^Status:[[:space:]]*implemented' \
          && { printf '%s\n' "$ref"; return 0; } ;;
    esac
  done < <(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null)
  return 1
}
combined_built_branch() {  # echoes a branch where EVERY queued TDD is implemented
  [ "$REBUILD" -eq 1 ] && return 1
  local ref tdd ok
  while IFS= read -r ref; do
    case "$ref" in "$BASE"|"origin/$BASE") continue ;; esac
    ok=1
    for tdd in "${TDDS[@]}"; do
      git show "$ref:$tdd" 2>/dev/null | grep -qE '^Status:[[:space:]]*implemented' || { ok=0; break; }
    done
    [ "$ok" -eq 1 ] && { printf '%s\n' "$ref"; return 0; }
  done < <(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null)
  return 1
}

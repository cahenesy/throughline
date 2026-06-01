# TDD 0027: Runner resilience — hung children, unclean exits, resumable halts

Status: implemented
PRD refs: FR-39, FR-41, FR-42, FR-43 (gap-closure); NFR-4
PRD-rev: 5036877
ADR constraints: 0004, 0005, 0006, 0007

## Approach

Four implementation gaps in the run-recovery FR family (FR-39..43), all
discovered in one incident chain while building TDDs 0010/0012, all violating
acceptance criteria of FRs whose covering TDDs are already `implemented`:

1. **Hung child claude calls wedge the runner forever.** Only the build
   coprocess is `timeout`-wrapped ([[0025]]). The five single-shot
   `claude "${args[@]}"` call sites in `scripts/lib/gates.sh` — `build_one`
   (~line 28), `review_one` (~171), `verify_runtime_one` (~267),
   `_run_per_step_review` (~435), `_rework_one` (~860) — have NO timeout. A
   per-step review that hangs (rate-limited mid-call, or its spawned subagent
   hangs) blocks the synchronous caller indefinitely; no watchdog exists to
   fire. Violates FR-42 ("a transient error encountered during a gate is
   retried within the gate a bounded number of times before promoting to a
   paused halt" — an unbounded hang never promotes to anything).

2. **Worktree leak on unclean exit makes the next launch fail.** `kill -9` (or
   any unclean death) skips the EXIT trap that removes the build worktree;
   `scripts/implement.sh` (~line 388) then FATALs on `git worktree add` because
   the path exists. Violates FR-43's acceptance ("after a prior /implement is
   forcibly killed, the next /implement proceeds without manual lock cleanup" —
   the worktree is exactly such manual cleanup).

3. **Halted-but-recoverable states are not resumable without manual state
   surgery.** (a) `status.sh --check-paused` reports only `status=paused`
   fragments, so a `blocked` halt whose `halt_next_actions` includes "resume"
   never surfaces in the `/implement` resume prompt. (b) `resume.sh`'s
   divergence guard refuses whenever `branch_head_at_pause != current_head`,
   even when the branch merely advanced (fast-forward) past the recorded SHA —
   forcing hand-edits of the fragment JSON. Violates FR-39 ("the user decides
   whether to resume or start fresh; the runner does not act silently" — today
   the runner doesn't even offer).

4. **A gate child's exit code can mask its verdict.** `_verify_runtime_one_gated`
   and `_review_one_gated` return the child's non-zero rc BEFORE consulting the
   log for a verdict — so a child that correctly emitted `VERIFY_RUNTIME: FAIL`
   (or `REVIEW_RESULT: BLOCK`) and then exited 1 is classified by exit code
   (fatal/transient) instead of by its honest verdict. Violates NFR-4 (a real
   FAIL verdict must surface as FAIL, not be conflated with "process error").
   This is the same bug shape `_build_one_gated` had pre-[[0025]].

The covering TDDs ([[0024]], [[0025]], [[0018]]) are `implemented` → append-only
→ this is a NEW TDD that extends their surfaces. It supersedes nothing in full:
0024 stays authoritative for resume orchestration, 0025 for the build-coproc
lifecycle, 0018 for the halt enum. This TDD adds the missing robustness on top,
the same extends-not-supersedes relationship [[0026]] has to FR-37.

## Components & interfaces

### 1. Child-call timeout wrapper — `scripts/lib/gates.sh` (gap 1)

A new helper near the top of gates.sh:

```bash
# _claude_call <log> <args...> — run a single-shot claude call under the child
# watchdog. On timeout, GNU `timeout` SIGTERMs the child and ITSELF exits 124 —
# a code _classify_cause's signal arm does NOT handle (it handles the child's
# 137/143, and `timeout` writes no "timed out" text for the log-pattern arm to
# match). So the wrapper does two things on 124: (a) appends an explicit
# `THROUGHLINE_GATE_TIMEOUT: gate child timed out after <N>s (transient)` line
# to the log — which _classify_cause's existing `timed[- ]out` pattern DOES
# match — and (b) returns 124 unchanged so the caller's rc capture still sees
# the timeout distinctly. Belt and suspenders: the log line is the
# classification mechanism; the distinct rc is the triage signal.
# 0/unlimited disables (matching THROUGHLINE_BUILD_TIMEOUT).
_claude_call() {  # <log> <args...>
  local log="$1"; shift
  local to="${THROUGHLINE_GATE_TIMEOUT:-3600}"
  local -a tocmd=()
  case "$to" in 0|unlimited|'') : ;; *[!0-9]*) to=3600; tocmd=(timeout 3600) ;; *) tocmd=(timeout "$to") ;; esac
  "${tocmd[@]}" claude "$@" >>"$log" 2>&1
  local rc=$?
  if [ "$rc" = "124" ]; then
    printf 'THROUGHLINE_GATE_TIMEOUT: gate child timed out after %ss (transient)\n' "$to" >> "$log"
  fi
  return "$rc"
}
```

All five single-shot call sites switch from `claude "${args[@]}" >>"$log" 2>&1`
to `_claude_call "$log" "${args[@]}"`. Their existing `_rc=$?` capture and
return-code semantics are unchanged.

**Why the explicit log line is required (not optional):** `_classify_cause`
(lib/pause-retry.sh ~line 47) decides transient-vs-fatal in two arms — a signal
arm that handles only rc=137 (fatal) and rc=143 (transient), then a log-pattern
arm whose `transient:` regex includes `timed[- ]out`. GNU `timeout` exits 124
(not 143) and writes nothing to the captured log, so WITHOUT the wrapper's
appended line, a gate timeout would fall through both arms to `fatal` — the
exact opposite of the intended self-recovery. The appended line is what routes
124 → transient through the existing pattern arm, with no change to
`_classify_cause` itself. (Alternative — adding a `124) transient` case to
`_classify_cause`'s signal arm — is equally correct; the log-line approach is
chosen because it also leaves a human-readable diagnostic in the gate log,
serving FR-64's one-screen-context goal, and keeps `_classify_cause` untouched.)

On the per-step-review site (`_run_per_step_review`), a timeout means the
verdict-parse falls through to the existing "no REVIEW_RESULT line" branch →
`STEP_REVIEW: BLOCK` → the build reworks or the runner's existing failure path
runs; the runner never wedges.

Default 3600s (1h) per child call: long enough for a large consolidated review
on a slow day, short enough that a wedged run self-recovers the same hour.
Env-overridable per the established knob pattern; recorded in `run.json`'s
config block alongside `rework_config` (one new `gate_timeout` field) so a
timeout-driven halt is reproducible from run-state alone (ADR 0006).

### 2. Worktree reclaim at launch — `scripts/implement.sh` (gap 2)

At the worktree-creation site (~line 388), before `git worktree add --detach`:

```bash
if [ -d "$WORKROOT" ]; then
  # Leftover from an unclean exit (EXIT trap skipped). Reclaim: remove the
  # registration + the directory, then fall through to a fresh add. Build
  # branches (the durable output) live in refs, not in the worktree — removing
  # a stale worktree never discards committed work. Uncommitted edits in a
  # stale worktree are intentionally discarded per the existing non-goal
  # ("Recovering uncommitted edits in a build worktree").
  echo "Reclaiming stale build worktree at $WORKROOT (prior unclean exit)" >>"$REPORT"
  git worktree remove --force "$WORKROOT" >>"$REPORT" 2>&1 || rm -rf "$WORKROOT"
  git worktree prune >>"$REPORT" 2>&1
fi
```

Then the existing `git worktree add` runs against a clean path. The FATAL
branch remains for genuinely unfixable cases (permissions, disk).

### 3. Resumable halted states — `scripts/status.sh` + `scripts/lib/resume.sh` + `skills/implement/SKILL.md` (gap 3)

**The producer already exists — this section adds only consumers.** The halt
enum's action mapping (`_next_actions_for_cause`, `scripts/lib/state.sh` ~line
685, established by [[0018]] §3) already produces blocked states whose
`halt_next_actions` begin with a resume action: **`rework-scope-exceeded` →
`"resume (retries with stricter scope),revise TDD bounds via /tdd-author"`**.
This is a real, observed state — the 0012 build's review-gate halt (2026-06-01,
`PRECHECK_FAIL: rework-scope-exceeded 64 > 60`) produced exactly this fragment,
and resuming it required hand-editing the JSON because nothing downstream
consumed the resume affordance the producer had already written. The other
blocked causes (`structural-finding`, `rework-budget-exhausted`,
`design-escalation`, `external-blocker`) map to design-escalation actions with
no resume prefix, and stay non-resumable — the consumer changes below key on
the action prefix, so the enum's existing semantics ARE the policy; no new
cause values, no producer changes.

**3a. `--check-paused` also reports recoverable blocked fragments.** The scan
loop (status.sh ~line 448) currently skips anything not `status=paused`. Extend:
a fragment with `status=blocked` whose `halt_next_actions` array contains an
entry beginning `resume` is reported with the same one-line format plus a
trailing marker:

```
slug=<slug> gate=<stage> cause=<halt_cause> resumable=blocked
```

Plain paused lines stay exactly as they are (no new field) so existing
consumers parse unchanged; only the new blocked lines carry the marker.

**3b. Divergence guard accepts fast-forward.** In `resume.sh` (~line 149), when
`current_head != branch_head_at_pause`, run one additional check before
refusing:

```bash
if git merge-base --is-ancestor "$branch_head_at_pause" "$current_head" 2>/dev/null; then
  # The branch ADVANCED past the recorded SHA (commits added, none rewritten)
  # — e.g. the runner was killed after committing but before updating the
  # fragment. This is continuation, not rewrite: accept, update the fragment's
  # branch_head_at_pause to current_head, and proceed.
  _update_branch_head_at_pause "$slug" "$current_head" || true
else
  RESUME_REFUSE_CAUSE="resume-blocked-branch-divergence"   # true rewrite: refuse as today
  ...existing refusal...
fi
```

`_update_branch_head_at_pause <slug> <sha>` is a new one-field setter in
`scripts/lib/state.sh`, following the round-trip-the-fragment-mutate-one-field
shape of `_update_paused_cause` (which lives in `resume.sh`; the new setter goes
in `state.sh` because state.sh is sourced before resume.sh and the setter is a
state-write primitive, not resume orchestration).

**3c. Blocked-state resume in the resume path + skill.** `resume.sh`'s
fragment-status gate (~line 124, `[ "$fragment_status" = "paused" ] || return 0`)
extends to also accept `blocked` when `halt_next_actions` contains a
resume-prefixed entry; on acceptance it rewrites status→`paused` /
`paused_cause`→`transient` itself (the exact edit that previously required
hand-surgery), then proceeds through the same validation it runs today.
`skills/implement/SKILL.md`'s "Detect interrupted run" step documents that the
prompt may now offer blocked-but-resumable runs and shows the `resumable=blocked`
marker.

### 4. Verdict-before-exit-code in gate wrappers — `scripts/lib/gates.sh` (gap 4)

`_verify_runtime_one_gated` and `_review_one_gated` reorder: parse the verdict
from the log FIRST; only when no verdict exists does the child's rc decide.

```bash
_verify_runtime_one_gated() {  # <tdd> <rbase> <log>
  local tdd="$1" rbase="$2" log="$3" rvs _rc
  verify_runtime_one "$tdd" "$rbase" "$log"; _rc=$?
  rvs="$(verify_runtime_status "$log")"
  case "$rvs" in
    *PASS*|*SKIP*) return 0 ;;        # honest verdict wins, even if rc!=0
    *FAIL*|*BLOCKED*) return 1 ;;     # honest FAIL is a gate failure, not transient
  esac
  [ "$_rc" -ne 0 ] && return "$_rc"   # no verdict at all → classify by rc
  return 1                            # clean exit, no verdict → NFR-4: resolve to FAIL
}
```

`_review_one_gated` gets the identical reorder with `review_status` /
`REVIEW_RESULT`. (Note: `_build_one_gated` is NOT the model for this shape — it
still checks rc first, which is acceptable there because the build coproc's
verdict-bearing exit is already guaranteed clean by [[0025]]'s stdin-close
lifecycle; its rc≠0 genuinely means no-verdict. The two single-shot wrappers
have no such guarantee, hence the reorder applies to them only. This TDD does
not touch `_build_one_gated`.)

## Data & state

- One new `run.json` config field: `gate_timeout` (snapshotted at launch,
  alongside `rework_config`).
- One new fragment setter: `_update_branch_head_at_pause` (state.sh). No new
  fragment fields, no schema bump — it writes the existing field.
- The `resumable=blocked` marker is output-format only (status.sh stdout); not
  persisted state.

## Sequencing / implementation plan

1. **Child-call timeout wrapper** (`_claude_call` in gates.sh) + switch the five
   single-shot call sites; snapshot `gate_timeout` into run.json config.
2. **Verdict-before-exit-code reorder** in `_verify_runtime_one_gated` and
   `_review_one_gated` (same file as step 1; separate commit).
3. **Worktree reclaim** in implement.sh's worktree-creation site.
4. **Fast-forward divergence acceptance** — `_update_branch_head_at_pause`
   setter in state.sh + the merge-base check in resume.sh.
5. **Blocked-state resume surfacing** — status.sh `--check-paused` extension +
   resume.sh blocked-acceptance + the SKILL.md documentation of the
   `resumable=blocked` marker.

## Failure modes & edge cases

- **`timeout` binary absent (minimal container).** `tocmd` stays empty → calls
  run un-wrapped, exactly today's behavior. Degraded, never broken.
- **A child killed by the gate timeout had already emitted its verdict.** Gap-4's
  reorder makes this benign: the verdict in the log wins; the 124 is ignored.
- **Worktree path exists but is NOT a git worktree (random dir).**
  `git worktree remove --force` fails → the `|| rm -rf` fallback clears it; if
  even that fails (permissions), the existing FATAL fires. Never silently build
  inside an unknown directory.
- **Worktree reclaim races a still-alive prior runner.** Cannot happen through
  the supported path: the single-run lock (FR-18/FR-43) is checked before the
  worktree step, and a live lock-holder blocks the second runner there.
- **Fast-forward check on a branch whose ref was deleted.** `merge-base` fails →
  not an ancestor → existing divergence refusal. Correct: a deleted/recreated
  branch IS a rewrite.
- **A blocked fragment with `halt_next_actions: ["revise TDD bounds via /tdd-author"]`
  only (no resume action).** Not surfaced by 3a, not accepted by 3c — design
  escalations stay human-routed, exactly as [[0018]]/ADR 0007 require.
- **Verdict string appears in the log but only inside the prompt echo (not a
  real verdict).** Pre-existing concern, unchanged by this TDD: the
  `*_status` greps already anchor on line-start sentinels; gap-4 reuses them
  verbatim.
- **Gate timeout fires inside `_rework_one` mid-git-operation.** The rework
  child is killed between `git add` and `git commit` → HEAD unchanged, index
  dirty in the worktree. The rework loop's empty-rework check (`new_head ==
  cleared`) correctly treats this as a failed attempt (no commit landed); the
  next attempt's child starts in the same worktree and its own `git add -A` /
  commit subsumes the stale index. The dirty index is never reviewed (reviews
  diff committed SHAs only, per [[0020]]) and never ships (the pre-pass diffs
  committed ranges). Worst case: attempt N's partial staging is absorbed into
  attempt N+1's commit — acceptable, since attempt N+1's commit is itself
  reviewed before shipping.

## Verification plan

**Observable surface:** the runner's per-TDD gate logs, `status.sh --check-paused`
stdout, `_verify_runtime_one_gated` / `_review_one_gated` / resume-validation
return codes, the run-state fragments, and worktree presence on disk.

**Observation points:**

1. **Hung child self-recovers (gap 1).** Fixture: a stub `claude` that sleeps
   forever (`exec sleep 10000`). With `THROUGHLINE_GATE_TIMEOUT=5`, drive
   `_run_per_step_review`. Expect: the call returns within ~10s (not hung); the
   step-review log exists; the function's stdout is a `STEP_REVIEW: BLOCK ...no
   REVIEW_RESULT...` line (not silence); no process named in the stub remains
   alive afterward.
2. **Timeout knob recorded (gap 1).** Launch a stub run with
   `THROUGHLINE_GATE_TIMEOUT=120`. Expect: `run.json`'s config block contains
   `"gate_timeout":120`.
3. **Stale worktree reclaimed (gap 2).** Fixture: create the worktree path with
   `git worktree add --detach` then kill the creating process so the path
   remains registered. Run the runner's worktree-preparation step. Expect: it
   proceeds (no FATAL); the report contains the "Reclaiming stale build
   worktree" line; the worktree afterward is freshly created at the requested
   base.
4. **Fast-forward resume accepted (gap 3b).** Fixture: a paused fragment whose
   `branch_head_at_pause` is one commit BEHIND the branch ref (append a commit
   after recording). Run resume validation. Expect: no
   `resume-blocked-branch-divergence`; the fragment's `branch_head_at_pause`
   equals the branch head afterward; validation proceeds to the gates list.
5. **True rewrite still refused (gap 3b negative).** Fixture: same but the
   branch is hard-reset to a sibling commit (recorded SHA is NOT an ancestor).
   Expect: `resume-blocked-branch-divergence`, exactly as today.
6. **Resumable blocked surfaced; non-resumable not (gap 3a/3c).** Fixture A: a
   `blocked` fragment with `halt_next_actions:["resume (retries with stricter
   scope)", ...]`. Expect `--check-paused` prints its line with
   `resumable=blocked`, and resume validation accepts it (status flipped to
   paused in the fragment afterward). Fixture B: a `blocked` fragment with only
   a design-escalation action. Expect: not printed, not accepted.
7. **Honest FAIL verdict survives non-zero exit (gap 4).** Fixture: a stub
   `claude` that prints `VERIFY_RUNTIME: FAIL surface produced wrong value` and
   exits 1. Drive `_verify_runtime_one_gated`. Expect: return code 1 (gate
   fail), and the runner's downstream classification is the FAIL pathway (the
   report says FAIL verification), NOT transient/paused. Same fixture shape for
   `_review_one_gated` with `REVIEW_RESULT: BLOCK` + exit 1 → gate fail.
8. **Verdict-less clean exit resolves to FAIL (gap 4 / NFR-4).** Fixture: stub
   `claude` exits 0 printing nothing. Expect: `_verify_runtime_one_gated`
   returns 1 (never a false PASS).

**Expected observations (PASS):** every numbered point yields the cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-42 (transient errors bounded within the gate, then promote to paused — never an unbounded hang) | §1 `_claude_call` timeout on every single-shot child; 124 routes through the existing transient classification. Verification §1, §2. |
| FR-43 (forcible kill ⇒ next run proceeds without manual cleanup) | §2 worktree reclaim (the lock half of FR-43 already works; this closes the worktree half). Verification §3. |
| FR-39 (interrupted runs surfaced with cause; user decides resume/fresh) | §3a blocked-but-resumable surfacing + §3c acceptance — recoverable halts now reach the FR-39 prompt instead of requiring state surgery. Verification §6. |
| FR-41 (recoverable vs fatal causes kept distinct) | §3b fast-forward acceptance keeps "branch advanced" out of the refusal bucket; §4 keeps "honest FAIL" out of the transient bucket. Verification §4, §5, §7. |
| NFR-4 (verdict honesty; ambiguity → FAIL never false PASS) | §4 verdict-before-rc ordering + verdict-less-exit→FAIL. Verification §7, §8. |

No gaps.

## Dependencies considered

No new external dependencies. `timeout` is coreutils, already used by [[0025]]'s
build watchdog; `git merge-base --is-ancestor` is core git, already used by the
rework pre-pass.

Alternatives considered:
- **A supervising watchdog process (a second daemon monitoring the runner)** —
  rejected: adds a process-lifecycle problem to solve a process-lifecycle
  problem; the PRD non-goal "no watchdog or daemon" rules it out, and per-call
  `timeout` achieves the same recovery with zero new moving parts.
- **Trap-based cleanup hardening (more EXIT/INT/TERM traps) instead of
  launch-time reclaim (gap 2)** — rejected as the *primary* fix: traps cannot
  run on `kill -9` by definition. Launch-time reclaim is the only mechanism
  that covers SIGKILL; traps remain as the fast path for clean exits.
- **Auto-resume blocked runs (skip the prompt)** — rejected: FR-39 explicitly
  requires the user to decide; ADR 0007 keeps human-needed halts human-routed.
  This TDD only makes them *offerable*, never auto-resumed.
- **Per-gate timeout values (separate knobs for review/verify/rework)** —
  rejected for now: one knob covers the failure mode; per-gate tuning is
  premature without data showing the gates need different ceilings.

## PRD conflicts surfaced (and resolution)

None. All four gaps are violations of existing acceptance criteria; this TDD
brings the implementation up to what FR-39/41/42/43 and NFR-4 already promise.
No FR text needs to change.

## Decisions to promote (ADR candidates)

None. Every decision here applies existing ADRs (0005: prompt+detection, no
sandbox; 0006: artifacts ground verdicts; 0007: human-needed halts stay
human-routed) to new call sites. Nothing cross-cutting and new.

## Touched files

- `scripts/lib/gates.sh` — `_claude_call` wrapper + five call-site switches (§1); verdict-before-rc reorder in two gate wrappers (§4).
- `scripts/implement.sh` — worktree reclaim before `git worktree add` (§2).
- `scripts/lib/resume.sh` — fast-forward divergence acceptance + blocked-state acceptance (§3b, §3c).
- `scripts/lib/state.sh` — `_update_branch_head_at_pause` setter (§3b).
- `scripts/status.sh` — `--check-paused` resumable-blocked extension (§3a).
- `skills/implement/SKILL.md` — document the `resumable=blocked` marker in the detect-interrupted-run step (§3c).
- `tests/runner-resilience.test.sh` — new eval covering verification §1–§8.
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Total: 8 files touched.

## Expected diff size

- `scripts/lib/gates.sh` — ~45 lines (wrapper ~15, five 1-line call-site switches, two wrapper reorders ~20).
- `scripts/implement.sh` — ~12 lines (reclaim block).
- `scripts/lib/resume.sh` — ~30 lines (fast-forward branch + blocked acceptance).
- `scripts/lib/state.sh` — ~15 lines (one setter).
- `scripts/status.sh` — ~15 lines (blocked-scan extension).
- `skills/implement/SKILL.md` — ~10 lines (marker documentation).
- `tests/runner-resilience.test.sh` — ~220 lines (8 verification points + stubs).
- `tests/implement-gate.test.sh` — ~6 lines (aggregator wire-in).

Total expected diff: ~353 lines across 8 files. No exceptions needed.

# TDD 0011: Detached `/implement` run recovery & restart resilience

Status: implemented; halt-taxonomy aspect superseded by 0018
PRD refs: FR-39, FR-40, FR-41, FR-42, FR-43, FR-44, FR-45 (new)
PRD-rev: 9626a59
ADR constraints: 0003, 0004, 0005

## Approach

Recovery is layered onto the existing four-gate runner (TDD 0005) and run-state
record (TDD 0008); nothing in either is superseded. The runner already writes
per-TDD fragments atomically (TDD 0008 / FR-44 property: ".tmp + mv … reader
sees the old or the new file but never a torn one") and already reclaims a
stale single-run lock when its owner is dead (TDD 0005). This TDD adds three
concerns on top:

1. **Distinguishing recoverable from fatal halts.** Today a `claude -p` that
   exits non-zero with no `BATCH_RESULT` becomes `FAIL`. FR-41 asks us to
   classify a subset of those exits (usage-limit, ratelimit, transient
   network/5xx) as recoverable and route them to a new `paused` state, while
   leaving the existing FAIL pathway intact for everything else. Classification
   is mechanical (stderr allowlist + exit-signal table), conservative per
   NFR-4: a pattern the runner doesn't recognise falls through to `failed`,
   never to a false `paused`.

2. **Gate-level resume.** A `paused` TDD records exactly which of the four
   gates (build / verify.sh / runtime-verify / review) completed. On resume,
   gates that completed are not re-run; the build branch's committed history
   is the source of truth for the build gate's output, so later gates re-run
   against the same on-disk state, not against untrusted in-flight worktree
   edits. The per-TDD fragment carries an explicit `gates_completed` array
   rather than inferring from `stage` — the stage enum's ordering is fragile
   if stages get reordered.

3. **Interrupted-run detection before any build work.** The `/implement`
   skill (which has foreground `AskUserQuestion`) inspects the state record on
   re-invocation, surfaces an interrupted TDD + gate + cause, and waits for
   the user's resume/fresh decision. The detached runner stays headless — it
   never asks a question; the interactive skill is the only stage that does.

The schema-version policy resolved here also closes the PRD's "plugin schema
skew across pause and resume" open question (see Data & state).

## Components & interfaces

### Schema extensions (additive on TDD 0008's `state.d/` shape)

The `status` enum (TDD 0008) gains `paused`; everything else carries forward:

```
status ∈ { pending, building, verifying, reviewing,
           done, failed, blocked, skipped, paused }   ← `paused` is new
stage  ∈ { build, test-first, verify, verify-runtime, review, flip, null }
                                                     unchanged
```

The per-TDD `<slug>.json` fragment gains four additive fields:

| Field | Type | Meaning |
|---|---|---|
| `paused_cause` | `string \| null` | `null` unless `status==paused`. One of: `ratelimit`, `usage-limit`, `transient` (the classifier-emitted causes from `_classify_cause`); `resume-blocked-build-state-missing`, `resume-blocked-branch-missing`, `resume-blocked-branch-divergence` (the resume-path-emitted causes — set by `_resume_from` when it refuses to resume a TDD). Mirrored to `note` for display compatibility with TDD 0008's renderer. The full enum is closed (no other values legal); the resume-blocked subset distinguishes "interrupted" from "interrupted and not resumable" so `/implement-status` can render the right action prompt. |
| `gates_completed` | `string[]` | Subset of `["test-first","verify","verify-runtime","review"]`. Build (gate 1) completion is read from the branch's commit history, not from this array — see FR-40 and the dual-source trust hierarchy below. |
| `retries` | `{ gate: string, count: int, backoff_s: int }[]` | Audit trail of bounded retries (FR-42). Each entry is one attempt the runner classified as transient and retried in-gate. |
| `branch_head_at_pause` | `string \| null` | The build branch's commit SHA at the moment `_enter_paused` ran. `null` for non-paused fragments. Used by `_resume_from` to detect mid-resume worktree divergence (see Failure modes — "Build branch HEAD differs at resume"). |

The run-level `run.json` (TDD 0008) gains:

| Field | Type | Meaning |
|---|---|---|
| `state` | `string` | TDD 0008 declared `running \| done`. Adds `paused`. Set when ≥ 1 per-TDD fragment is `paused` AND no fragment is mid-transition. |
| `pause_started_at` | `int \| null` | Epoch when the run entered paused state, for display only. |

### Schema-version policy (resolves PRD open question)

`run.json`'s `schema: 1` (TDD 0008) is retained. Adding nullable fields and
adding a new enum value to a string field are **additive changes** that
stay at `schema: 1`. The contract:

- **Old reader, new fragment.** A pre-FR-39 reader (TDD 0008's `status.sh`)
  encounters `status: "paused"` and falls through its case to a `default`
  branch that prints the literal status text. It does not misclassify; it
  just renders unfamiliarly. Acceptable for resume across a plugin update
  that landed FR-39..45.
- **New reader, old fragment.** The fragment lacks `paused_cause`,
  `gates_completed`, and `retries`; the FR-45 renderer treats absent fields
  as `null`/`[]` and renders normally. A fragment from before FR-39 cannot
  be in `paused` (the enum value didn't exist), so the recovery code path
  is never reached on these.

**Breaking changes** (removing a field, narrowing an enum, renaming a key)
must bump to `schema: 2` AND change the runner's resume gate: a resuming
`/implement` against `schema != 1` refuses to resume with the message
`paused-run schema X not compatible with this plugin version; resume not
possible (see docs/tdd/0011)` and offers fresh-start. The runner does NOT
attempt migration. (Resolves PRD open question on plugin schema skew.)

### File / module changes

1. **`scripts/implement.sh` (modified).** Five concrete changes:

   - **`_write_tdd_fragment`** gains three trailing parameters
     `<paused_cause> <gates_completed_csv> <retries_json>` and emits them
     in the JSON. Callers that don't need them pass `"" "" "[]"`; that
     keeps existing call sites intact.

   - **`_write_run_fragment <state>`** accepts `paused` in addition to
     `running` and `done`. When called with `paused` it stamps
     `pause_started_at`.

   - **New `_classify_cause <log> <exit_status>` → echoes one of
     `ratelimit | usage-limit | transient | fatal`.** The mechanical
     classifier — a small allowlist read from `_recoverable_patterns()`
     (see #2 below). Stdout determines routing; stderr is logged. NFR-4
     honesty: any unmatched stderr → `fatal`, never `transient` by
     default. Looks at:
     - the `claude -p` redirected log's tail (recoverable error messages
       claude itself emits before non-`end_turn` exit),
     - the wait-status signal (e.g. `SIGTERM` from a host shutdown is
       `transient`; `SIGKILL` is `fatal` because we cannot prove it was
       not a runaway-process kill).

   - **New `_recoverable_patterns()` helper** sources from a single shell
     associative-array literal so the patterns are auditable in one place:
     ```bash
     declare -A RECOVERABLE_PATTERNS=(
       [ratelimit]='(ratelimit|rate_limit|429 |too[- ]many[- ]requests)'
       [usage-limit]='(usage[- ]limit|monthly[- ]limit[- ]reached|quota[- ]exceeded)'
       [transient]='(connection[- ]reset|timed[- ]out|EAI_AGAIN|temporary failure|503 |502 |504 |gateway timeout)'
     )
     ```
     Cases match left-to-right; first match wins; no match → `fatal`.
     (Patterns are case-insensitive via the runner's `grep -aiE`.)

   - **New `_retry_in_gate <gate-fn> <gate-name> <slug> <log> <args…>`
     wrapper** for the four gate functions. Algorithm:
     ```
     for attempt in 1..MAX_RETRIES:   # MAX_RETRIES default 3
       run gate-fn
       if exit==0 OR cause==fatal: return
       backoff = BACKOFF_BASE * (4 ** (attempt-1))   # 30, 120, 480 default
       append to retries[] in fragment
       if attempt < MAX_RETRIES: sleep $backoff   # iter-9 M-1: skip the
         # final-attempt sleep — no further gate call follows it; the
         # ~480s wait before _enter_paused would just be wasted wall time.
         # The audit entry still records the *planned* backoff (so retries[]
         # length matches the schedule), but the actual sleep is bypassed.
     # All retries exhausted: promote to paused (not failed)
     _enter_paused "$slug" "$cause"
     return 2   # caller treats as "paused, not flipped"
     ```
     Env knobs (PRD open question resolved): `THROUGHLINE_GATE_RETRIES`
     (default `3`, hard cap 10), `THROUGHLINE_GATE_BACKOFF_BASE` (default
     `30`s, hard cap 3600s) — both capped to prevent the single-run lock
     being held for unbounded periods on misconfiguration.

   - **New `_enter_paused <slug> <cause>` function.** Writes
     `status=paused`, `paused_cause=<cause>`, leaves `stage` as the
     in-flight stage so resume knows where to re-enter, and
     `_write_run_fragment paused`. The run exits cleanly (rc 0; the lock's
     `EXIT` trap releases) so the detached process terminates without
     producing a FAIL verdict.

2. **`gate_one` (modified).** Three changes:

   - Wrap each `claude -p` call (build, runtime-verify, review) in
     `_retry_in_gate`. The mechanical `verify.sh` gate (no LLM, no
     network) is NOT wrapped — its failures are CI failures, not
     transient.

   - On a successful gate, append the gate name to the fragment's
     `gates_completed` via `set_tdd_state` (new param). The four gate
     names this records are `test-first`, `verify`, `verify-runtime`,
     `review`. (Build completion is detected on resume from the build
     branch's HEAD, not from this array — see FR-40.)

   - On `_retry_in_gate` rc 2 (paused), `gate_one` returns 2 (distinct
     from 1 = failed). The drivers (sequential / combined / parallel) on
     `rc=2`: do NOT mark downstream BLOCKED, do NOT keep building. Stop
     iterating; the paused state is the run's terminal state until
     `/implement` is re-invoked.

3. **New `_resume_from <slug>` function in `scripts/implement.sh`.** Called
   when the runner is launched with `--resume` (new flag). The resume
   decision uses two sources of truth (one for build, one for the later
   gates) with an explicit trust hierarchy, so an implementer is never
   forced to guess on inconsistent state:

   - **Source A — the build branch's commit history.** Authoritative for
     the build gate (gate 1) ONLY. `git log --format=%s "$BASE..HEAD" |
     grep -q '^test(failing)'` is the build-completion signal; the build
     branch's HEAD must also be non-empty. This is the source the resume
     path inspects first, because gates 2-4 cannot meaningfully run
     without gate-1 output committed.
   - **Source B — the per-TDD fragment's `gates_completed` array.**
     Authoritative for gates 2-4 (test-first, verify, verify-runtime,
     review). Each gate's `gate_one` driver appends its own name to
     this array immediately after PASS (via `set_tdd_state`'s new param)
     and BEFORE entering the next gate, so a SIGKILL between gates leaves
     the array consistent with what is on the branch.

   The trust hierarchy when the two sources disagree (which they MUST
   not, except after corruption or external tree manipulation):

   - **A says gate-1 done, B is empty.** This is the expected state
     after a SIGKILL between gate-1 commit and the first `set_tdd_state
     test-first` write — the array's write is atomic but ordered after
     the commit. Trust source A: begin at gate 2. Do NOT require
     `gates_completed` to be non-empty as a precondition. (This is the
     state the runner is in immediately after a clean gate-1 PASS;
     refusing to resume here would force re-running gate 1, which is
     expensive and re-tests the same code.)
   - **A says gate-1 done, B says `test-first` complete but `verify`
     incomplete.** Begin at gate 2 (verify). Drop the implicit
     `test-first` entry as already confirmed; do not re-run it.
   - **A says gate-1 done, B contains gates 2-4.** Begin at the first
     gate in `[test-first, verify, verify-runtime, review]` that is
     NOT in `gates_completed`. (The dual-source state is consistent.)
   - **A says gate-1 NOT done (no `test(failing)` commit or empty
     branch).** Refuse to resume that TDD: write `paused_cause:
     resume-blocked-build-state-missing` and surface it on the next
     status snapshot. The user's options are fresh-start or
     investigate; the runner does not retry gate 1 silently because
     re-running gate 1 against a worktree that may have partial commits
     could double-commit or interleave with the prior attempt.
   - **B claims a gate is complete that A's `branch_head_at_pause`
     comparison says is divergent.** Refuse: write `paused_cause:
     resume-blocked-branch-divergence`. The branch HEAD at pause time
     is compared against the current HEAD; mismatch means external
     manipulation (user committed, force-pushed, rebased) and the
     fragment's gate-completion claims are no longer trustworthy.

   In all "refuse to resume" cases the OTHER TDDs in the queue
   continue normally (sequential halt-on-failure semantics still
   apply only on a real FAIL, not on a refuse-to-resume which is
   handled per-TDD).

4. **`skills/implement/SKILL.md` (modified).** A new "Detect interrupted
   run" step BEFORE the existing `## Prepare` queue confirmation:

   - Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" --check-paused`
     (new flag; see #5). If output is empty, proceed normally.
   - If output names a paused run, surface it via AskUserQuestion with
     options `Resume from <gate> on <slug>` / `Start fresh (discard
     paused state)` / `Cancel`. On Resume → launch with `--resume`. On
     Start fresh → delete the paused fragments (preserves the rest of
     the run dir for forensic value) and proceed. On Cancel → exit
     without launching.
   - The launch line gains `--resume` conditionally:
     ```
     nohup bash "${CLAUDE_PLUGIN_ROOT}/scripts/implement.sh" --resume \
       > docs/tdd/.implement-logs/nohup.out 2>&1 &
     ```

5. **`scripts/status.sh` (modified).** Four changes:

   - Add `paused` to the per-TDD status case in `render_snapshot`. Render
     as `paused` (lowercase, distinct column value).
   - When a TDD is `paused`, also print `paused_cause` after the slug
     column (e.g. `0007  paused (ratelimit)`).
   - In the summary line, add `paused=N` between `skipped` and the
     newline when N>0 (mirrors the existing failed/blocked/skipped
     conditional rendering).
   - On `paused`, after the table append a one-line action prompt:
     `Run /implement to resume from <gate> on <slug>` (FR-45 acceptance).
   - New `--check-paused` flag: scans the active run's state.d/ for any
     fragment with `status==paused`. Prints exactly one machine-parseable
     line per paused TDD (`slug=<slug> gate=<gate> cause=<cause>`) and
     exits 0; prints nothing and exits 0 if none. Used by the skill in
     #4 above.

6. **No new file.** All logic lives in the existing `scripts/implement.sh`
   and `scripts/status.sh`; the patterns table is a shell heredoc inline
   in the runner (auditability matters more than reuse — there is one
   call site).

## Data & state

- The `state.d/` directory remains the single source of truth for the run
  (TDD 0008). This TDD adds three fields to the per-TDD fragment and one
  new enum value to a fragment field; no new directory, no new file.
- **FR-44 (durability):** TDD 0008's `tmp + mv` atomic-write semantics
  already provide this property; this TDD codifies it as a hard
  requirement of the resume path. No code change is required for FR-44
  beyond a test that reads fragments at random points during a run and
  asserts each parses as valid JSON (verification plan, observation 4).
- **FR-43 (stale lock):** TDD 0005's existing lock-reclaim
  (`kill -0 "$(cat "$LOCK")" 2>/dev/null || reclaim`) already satisfies
  the requirement. The test (verification plan, observation 3)
  confirms the property holds; no code change required.

## Sequencing / implementation plan

1. **Schema extensions first** (additive `<slug>.json` fields + `paused`
   in the status enum + `_write_tdd_fragment` signature update). Land
   with the test that reads a fragment with the new fields and confirms
   `status.sh` renders it without crashing on the unfamiliar status
   value.
2. **`_classify_cause` + `_recoverable_patterns`.** Land with the test
   that feeds a fixture stderr buffer containing each pattern and
   asserts the right cause label is echoed (one assertion per pattern).
3. **`_enter_paused` + `_retry_in_gate`.** Land with the test that
   forces each gate to exit transient-then-succeed (single retry),
   transient-throughout (paused), fatal (failed), and asserts the
   fragment's `retries[]` audit + final status in each case.
4. **`gate_one` modifications + `_resume_from`.** Land with the test
   that interrupts a run mid-`verify-runtime`, re-invokes with
   `--resume`, and asserts the per-TDD log between resume timestamp
   and the runtime-verify output contains NO new build or verify.sh
   output (FR-40 acceptance verbatim).
5. **`status.sh` renderer extensions + `--check-paused`.** Land with
   the test that runs `--check-paused` against a state.d/ with one
   paused fragment and confirms the machine-parseable line; runs it
   against state.d/ with no paused fragments and confirms empty
   output.
6. **`skills/implement/SKILL.md` detect step.** This is a prompt edit,
   not code. The implementation step verifies the prompt mentions the
   `--check-paused` invocation and the launch line carries `--resume`
   conditionally.

Order is failure-isolated: each step adds one capability and its test;
if step N's test fails, steps 1..N-1 are unaffected and already
validated.

## Failure modes & edge cases

- **Pattern match in stderr was a false positive** (e.g., a build's test
  output contained the word "ratelimit" describing a feature). The
  classifier looks at the `claude -p` redirected log's tail — that is the
  final assistant message, not the test output. A test-output false
  positive is structurally impossible because tests run inside the build
  via the Bash tool; their stdout is captured by the build, not
  redirected to `claude -p`'s own stdout. Verified empirically in the
  PR #24 post-mortem (TDD 0010 context).
- **Pattern match in stderr was a false negative** (an unmatched
  ratelimit string). The classifier falls through to `fatal`, the run
  becomes `failed`, the user sees a normal FAIL and can re-run
  `/implement` manually. Conservative per NFR-4.
- **Race between `_enter_paused` writing the fragment and the runner's
  exit.** The fragment write is atomic (tmp + mv); the `EXIT` trap fires
  after the fragment is durably on disk. Worst case: a reader between
  the mv and the trap sees status=paused but the lock-PID is still
  alive. The skill's detect step (#4) re-checks lock liveness and
  fragment state together; if lock-alive and fragment=paused, treats it
  as the runner mid-pause and waits 2s then re-checks (capped at 3
  iterations, total 6s) before showing the resume prompt. After cap, if
  still inconsistent, surface as "run state inconsistent — investigate
  state.d/ manually" rather than guessing.
- **Worktree was removed manually between pause and resume.** Resume
  recreates the worktree from the build branch (build branches persist
  in the shared repo per TDD 0005's existing behavior). If the build
  branch was also deleted, resume cannot proceed; fragment is updated
  to `paused_cause: resume-blocked-branch-missing` and the skill
  surfaces fresh-start as the only option.
- **All TDDs paused on the same recoverable cause.** Sequential mode
  pauses at the first failure (the runner exits cleanly). Combined mode
  same. Parallel mode: each subshell pauses independently; the parent
  reaps them all, `_write_run_fragment paused` reflects that ≥1 TDD is
  paused, and resume picks them up per-TDD. The resume order is the
  fragment's queue_pos (TDD 0008's existing order).
- **Resume across a plugin update** that bumps the schema (per the
  policy above). Resume refuses with the documented message; user must
  start fresh. The lost work is at most one TDD's gate state.
- **Resume across a `claude` CLI version change** that altered the
  session-JSONL encoding. FR-36 already handles the helper's silent
  no-op when the encoding scheme doesn't match. Resume is unaffected.
- **Build branch HEAD differs at resume from what gates 2/3/4
  previously saw.** Defensive: the resume path captures the branch
  HEAD into the fragment at pause time (`branch_head_at_pause`, a
  fourth additive field — added to the schema list above) and
  compares on resume. Mismatch → refuse to resume that TDD
  (`paused_cause: resume-blocked-branch-divergence`); the human
  decides whether to fresh-start or investigate. (Adding this field
  to the additive list — see Components above.)
- **New TDDs merged to integration between pause and resume.** Resume
  freezes the queue at its pause-time snapshot: `state_init`'s resume
  branch diffs the current buildable set against the existing
  `state.d/` fragments and *removes* any newly-detected TDDs from the
  in-memory queue, naming each one in the run report
  (`Skipping <slug>: newly-buildable, not in paused queue`). The user
  invokes `/implement` again *after* the resume completes to build
  them via the fresh-run path. `gate_one` carries a belt-and-suspenders
  guard: a slug whose state fragment is missing is refused. Rationale:
  resume's "pick up where you left off" contract stays clean; silently
  growing the queue mid-run would change scope without consent (NFR-4
  honesty). The fresh-run path is the right tool for queue growth — two
  commands, two semantics.

## Verification plan

**Observable surface:** the `state.d/` fragments (per-TDD JSON);
`scripts/status.sh` stdout; the per-TDD log; the `Status: implemented`
flip in the TDD file; the `/implement` skill's interactive prompt text.

**Observation points & expected observations (PASS):**

1. **Interrupted-run detection (FR-39).** Launch
   `bash scripts/implement.sh` on a fixture TDD; while gate 2 is running,
   send the runner PID `SIGTERM`. Re-invoke `/implement` (the skill).
   Observe: the skill calls `status.sh --check-paused`; its output is one
   line `slug=<slug> gate=<gate> cause=transient`; the skill renders an
   AskUserQuestion naming `<slug>` and the gate; no `claude -p` for build
   has been re-invoked before the user's resume/fresh decision is
   captured. (Test: assert the build log's mtime did not change between
   skill start and the user-decision step.)
2. **Gate-level resume (FR-40).** From the paused state above, choose
   Resume. Observe: the per-TDD log between the resume timestamp and the
   runtime-verify verdict contains no new build (`BATCH_RESULT:`) or
   verify.sh (`verify: gate`) output; `git log` on the build branch shows
   the same gate-1 commits as before the interruption, with the
   runtime-verify and review gates' downstream commits (the
   `Status: implemented` flip) appearing only after resume.
3. **Stale lock reclaim (FR-43).** Run `bash scripts/implement.sh`; while
   it runs, `kill -9 $(cat docs/tdd/.implement-logs/.run.lock)`. Re-invoke
   `bash scripts/implement.sh`. Observe: it does not print the
   "Refusing to start a second run" message; it proceeds. Mechanics:
   `SIGKILL` cannot be trapped in bash, so the `EXIT` trap that normally
   `rm -f`s the lock does NOT run. The lock FILE remains on disk
   carrying the dead PID. Re-invocation's lock-check (TDD 0005's
   existing logic — `[ -f "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null`)
   returns false because `kill -0` cannot signal a dead PID; the second
   invocation overwrites the lock with its own PID and proceeds. There
   are no paused fragments for FR-39's detect step to surface (the killed
   runner never reached `_enter_paused`), so the second run starts fresh
   rather than resuming.
   - Negative: while a `bash scripts/implement.sh` is alive, a second
     invocation prints `An /implement run is already in progress` and
     exits non-zero.
4. **Persisted-state durability (FR-44).** Run a build; in a tight loop,
   `for f in docs/tdd/.implement-logs/latest/state.d/*.json; do
   python3 -c "import json; json.load(open('$f'))" || exit 1; done` for
   the run's lifetime. Observe: every iteration exits 0 — never a
   parse error.
5. **Bounded retry (FR-42).** Patch `_retry_in_gate`'s gate-fn to
   stub-fail with stderr containing `429` two times then succeed.
   Observe: the per-TDD log records two retry entries with timestamps
   ~30s and ~120s after the prior; the final gate verdict is a single
   PASS; the per-TDD fragment's `retries[]` array has exactly 2 entries.
6. **Bounded retry exhausts → paused (FR-42).** Same patch but
   stub-fail with `429` for all attempts. Observe: the runner exits 0;
   `status.sh` shows `status: paused`, `paused_cause: ratelimit`;
   `retries[]` has exactly `THROUGHLINE_GATE_RETRIES` entries.
7. **Recoverable-cause classification (FR-41).**
   - Fatal: simulate a gate exit with `BATCH_RESULT: FAIL` and clean
     stderr. Observe: `status: failed`; FR-39's detect step on the next
     `/implement` does NOT prompt resume.
   - Recoverable: simulate a gate exit with stderr `ratelimit_error
     (429)` and no `BATCH_RESULT`. Observe: `status: paused`;
     `paused_cause: ratelimit`; FR-39's detect step prompts resume.
8. **Paused status in the progress view (FR-45).** With a paused run,
   run `bash scripts/status.sh`. Observe: stdout contains the substring
   `paused`; for the paused TDD the row shows the cause label; after
   the table, the line `Run /implement to resume from <gate> on <slug>`
   is printed. On a `failed` run, the word `paused` does not appear in
   stdout.

(Mechanism is the project's — plain shell + `grep` / `python3` here —
delegated, not bundled, per FR-26 / ADR 0004.)

## Requirement traceability

| PRD | Design element |
|---|---|
| FR-39 Interrupted-run detection | `/implement` skill's "Detect interrupted run" step → `status.sh --check-paused` → AskUserQuestion → `--resume` flag on the launch line |
| FR-40 Gate-level resume | `_resume_from` reads `gates_completed` (per-TDD fragment) + build branch HEAD; `gate_one` skips completed gates; `branch_head_at_pause` guards against divergence |
| FR-41 Recoverable-cause classification | `_classify_cause` + `_recoverable_patterns` (allowlist); maps to `paused_cause`; unknown → `fatal` (NFR-4 conservatism) |
| FR-42 Bounded in-gate retry | `_retry_in_gate` wrapper (3 attempts, 30s × 4^(n-1) backoff); `retries[]` audit array in fragment |
| FR-43 Stale single-run lock reclaim | TDD 0005's existing `kill -0 || reclaim` behavior; verification plan observation 3 confirms still satisfied |
| FR-44 Persisted-state durability | TDD 0008's existing `.tmp + mv` atomic-write semantics; verification plan observation 4 confirms the invariant under load; `_write_tdd_fragment` updated to handle new fields atomically |
| FR-45 Paused status in the progress view | `status.sh::render_snapshot` adds `paused` to the status case + summary counter + cause column + resume-instruction trailer |
| NFR-4 (delta) | `_classify_cause` defaults to `fatal` on unmatched patterns (ambiguity is never a false paused/PASS); the four-verdict distinction (PASS/FAIL/BLOCKED/SKIP) is unchanged by adding the orthogonal `paused` lifecycle state |

## Dependencies considered

**No new external dependencies.**

- The pattern allowlist is a bash associative array — no new
  library/runtime.
- The retry/backoff loop is plain bash `sleep`.
- Signal handling uses standard POSIX (`trap`, `kill -0`, wait-status
  bits) — same primitives TDD 0005 already relies on.

Rejected alternatives evaluated:
- **Parse the session JSONL (FR-36 already writes a pointer) for typed
  error events** instead of grepping stderr. Rejected: couples the
  runner to Claude Code's JSONL schema (which Claude Code may evolve),
  adds a parse-on-failure dependency, and the stderr signal is already
  sufficient for the three cause categories the PRD names. The session
  pointer remains useful for human triage (FR-36), but the runner
  doesn't depend on it for classification.
- **Daemon / watchdog that resumes automatically on host reboot.** PRD
  non-goal ("Auto-resuming on host reboot — the user re-invokes
  `/implement`"). Daemon adds a process to manage, conflicts with the
  single-run lock semantics, and the user-re-invokes pattern is the
  PRD-pinned approach.
- **State machine library (e.g., a Python `transitions` wrapper) for
  gate progression.** Rejected: introduces a Python runtime dependency
  in a bash runner; the current `gate_one` linear flow is small enough
  that an in-line state-extension (the `gates_completed` array + the
  paused branch) is more auditable.
- **Automatic schema migration on resume across plugin updates.**
  Rejected: a migration step is itself a place where bugs can corrupt
  state. The "refuse to resume across a schema bump" policy is honest
  (NFR-4) and limits damage to one TDD's progress.
- **A `THROUGHLINE_PAUSE_TTL` envar that auto-expires very old paused
  runs.** Carried forward as a PRD open question; not designed here.

## PRD conflicts surfaced (and resolution)

None. FR-39..45 form an internally consistent set; no conflict with any
`accepted` ADR (0003, 0004, 0005); no conflict with existing
implemented FRs.

The PRD's open question on **plugin schema skew across pause and
resume** is resolved here (additive fields stay at `schema: 1`; breaking
changes bump and refuse resume across the bump). The PRD's open
question on **retry-budget tuning** is resolved here as defaults +
env-configurable. The PRD's open question on **pause TTL** is NOT
resolved here — it is carried forward unchanged; the runtime behavior
this TDD specifies treats every paused run as resumable indefinitely
provided state files exist.

No entries in `docs/tdd/BLOCKERS.md` to resolve (the file does not
exist).

## Decisions to promote (ADR candidates)

**None.**

- The schema-versioning policy (additive stays at v1; breaking bumps and
  refuses resume) is in-scope of FR-44 and the PRD's open question on
  schema skew; recording it in this TDD is sufficient. Promoting it to
  an ADR would not be wrong, but the policy applies only to throughline's
  internal run-state + draft schemas, not to any cross-cutting public
  contract — the ADR slot is not warranted.
- The stderr-pattern-allowlist classification approach extends the
  "govern not bundle" pattern established by ADRs 0003–0005, but on the
  same axis (don't add a sandbox / static-analyzer / JSONL parser as a
  bundled dependency); it does not need its own ADR.
- The "human re-invokes; no daemon" recovery model is already a PRD
  non-goal; no ADR needed.

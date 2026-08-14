# TDD 0025: Build coprocess lifecycle — BATCH_RESULT → stdin close → clean exit — supersedes TDD 0020

Status: superseded by 0062
PRD refs: FR-56, FR-57, FR-59
PRD-rev: c4ac185
ADR constraints: 0003, 0004, 0005, 0006, 0007
Supersedes: 0020

## Approach

Supersedes [[0020]] (continuous in-build review — per-step checkpoints, scoped
diff reading, cross-step learning) to fix two design gaps in 0020's "Build
subprocess protocol" subsection that caused an emitted `BATCH_RESULT: OK` to
be discarded by a transient classification. Observed on the 0009 build (run
`20260530-064216`, 7 `THROUGHLINE_BUILD_HANG` markers) and the 0010 build (run
`20260530-234522`, 3 HANG markers — paused after retry budget exhausted).

The carried-forward design covers FR-56 (continuous review), FR-57 (scoped
reads), FR-59 (cross-step learning) — see TDD 0020 §1 through §5 (sentinel
handshake, per-step review interception, scope-extension, fragment fields,
cross-attempt inheritance) and its verification plan §§1–11. Those sections
remain authoritative.

This TDD changes ONLY 0020's "Build subprocess protocol" subsection:

1. **Stream-json input-mode lifecycle.** `claude -p --input-format stream-json`
   does NOT self-terminate on `end_turn`; it blocks reading stdin for the next
   user-turn JSON until stdin is closed. The runner MUST close the build's
   stdin fd on observing `BATCH_RESULT:` in assistant content so the build
   sees EOF and exits cleanly with rc=0. The drain-to-EOF read loop continues
   until the build's stdout closes naturally.

   The current implementation (`scripts/lib/gates.sh` `_per_step_review_loop`,
   the `*"BATCH_RESULT: "*` inner case) treats `BATCH_RESULT` as a no-op and
   "keeps draining to EOF for the full final turn" — but with no stdin close,
   the build process never terminates. After `THROUGHLINE_BUILD_INTER_EVENT_TIMEOUT`
   (default 600s) the runner's `read -t` watchdog fires, kills the build
   (exit 143), and pause-retry routes the gate to transient. On TDD 0010's
   build log the kill happens within 600s of each `result(end_turn)` event
   carrying `BATCH_RESULT: OK` — three times in a row, then pause.

2. **Synth-OK fallback (codify hotfix 5b9ca23).** When the build process
   exits cleanly (rc=0) without emitting a `BATCH_RESULT` sentinel, AND the
   per-TDD fragment's `last_cleared_review_sha` equals `git rev-parse HEAD`,
   AND `git status --porcelain` is empty, the runner synthesizes
   `BATCH_RESULT: OK (synthesized: ...)` into the gate log and treats the
   build gate as passed. Commit 5b9ca23 added this to `_build_one_gated`
   without capturing it in [[0020]]'s design. Codify it here so a future
   reader / re-implementer sees the failure-path branch explicitly. The
   fallback fires ONLY when `bs` (log grep) is empty — it never overwrites
   an explicit `FAIL` or `BLOCKED`.

3. **RESUME-COMPLETION prompt language (carry hotfix 628b9d7).** Captured as
   evidence of why the structural fix in (1) is necessary even with a
   disciplined prompt: a build that runs `bash tests/...` after emitting
   `BATCH_RESULT: OK` defers the `result` event past the watchdog. The
   prompt-language refinement reduces the likelihood; the lifecycle fix in
   (1) removes the failure mode regardless of model behavior.

## Components & interfaces

### 1. `_per_step_review_loop` stdin-close on BATCH_RESULT — `scripts/lib/gates.sh`

The read loop's inner case branch (matching `_extract_event_text $evt` against
`*"BATCH_RESULT: "*`) closes the runner-side end of the build's stdin pipe
immediately. **Two parent-side write ends must close**: the dup'd
`${build_in}` AND the coproc's original `${BUILD[1]}`. Bash's `coproc`
assigns the pipe's write end to `${BUILD[1]}`; the setup line
`exec {build_in}>&"${BUILD[1]}"` creates a SECOND fd pointing to the same
pipe. EOF on the coproc's stdin requires both parent-side write ends to be
closed — closing only one leaves the other holding the pipe open.

```bash
*"BATCH_RESULT: "*)
  # Stream-json input-mode lifecycle (TDD 0025): claude -p does not self-
  # terminate on end_turn; it blocks reading stdin for the next user turn
  # until EOF. Close BOTH parent-side write ends of the build's stdin pipe
  # — our dup'd ${build_in} AND the coproc's original ${BUILD[1]} — so the
  # build sees EOF and exits cleanly (rc=0). Closing only one leaves the
  # other holding the pipe open, so the build keeps blocking and the
  # inter-event watchdog kills it (143 → transient → pause).
  exec {build_in}>&- 2>/dev/null || true
  exec {BUILD[1]}>&- 2>/dev/null || true
  ;;
```

The case continues to no-op for the rest of the branch (no `break`); the
loop keeps reading until the build's stdout closes naturally.

**Liveness — proof the loop terminates.** The fix only works if the read
loop actually exits after the stdin close. Causal chain:

- (a) Inner case matches → BOTH `exec {build_in}>&-` AND
  `exec {BUILD[1]}>&-` close. With both parent-side write ends closed
  (the dup'd fd + the coproc's original fd), the kernel sees no remaining
  writers on the pipe.
- (b) Kernel propagates EOF on the build's read side. `claude -p
  --input-format stream-json` consumes one JSON event per line on
  stdin and exits on stdin EOF after flushing pending output (per
  [[0020]]'s subprocess subsection); `end_turn` ends a turn, not the
  process — stdin EOF is the only documented process-termination
  signal in this input mode. Since the runner only closes stdin after
  observing `BATCH_RESULT:` (emitted at end-of-turn), stdin is at a
  turn boundary when closed and `claude` exits rc=0.
- (c) `claude`'s exit closes its stdout (the `BUILD[0]` end of the
  coproc pipe). Stderr `2>>"$errlog"` closes too but the runner does
  not read it; not load-bearing for read-loop liveness.
- (d) Runner's next `read -r -t $inter` on `${build_out}` returns
  non-zero with `$REPLY` empty (EOF — distinct from a `>128` timeout).
  `read_rc != 0` → the `[ "$read_rc" -ne 0 ] && break` guard exits the
  loop. `wait $bpid` collects the clean exit. `_build_one_gated`
  greps the log via `build_status`, finds `BATCH_RESULT: OK`, returns 0.

External assumption: `claude -p --input-format stream-json` exits
cleanly on stdin EOF. If that ever fails (a future CLI change makes it
spin), the existing inter-event watchdog still catches it at 600s —
degrading back to today's failure mode without worsening it. Strict
improvement margin: removes the deadlock under correct CLI behavior,
no worse than today under incorrect.

**Match safety — two-stage filter.** The outer case (line ~530) matches
the literal string `BATCH_RESULT: ` anywhere in the raw stream-json
event line `$evt` (so it fires on assistant text, result-event summary
fields, AND prompt-echoing tool-result events). The inner case is the
discriminator: it matches against `_extract_event_text $evt`, whose
existing jq filter extracts ONLY `message.content[]` blocks of
`type=="text"` — the assistant's actual emitted text. Tool-result
echoes have content type `tool_result` (not `text`) → empty extract →
no inner match. Result events lack `message.content` → empty extract →
no inner match. This two-stage outer/inner pattern is the existing
safety mechanism for the peer `STEP_COMMIT` branch; this TDD adds no
new filter logic, it relies on the existing one.

Empirically verified on TDD 0010's build log (run `20260530-234522`,
945 lines): of 18 lines containing `BATCH_RESULT: OK`, exactly three are
in assistant-content events (lines 550, 755, 933 — each immediately
followed by a `result(end_turn)` then a 600s HANG marker); the other 15
are tool-result prompt echoes or result-event summary fields. Only the
three would trigger the stdin-close — when it should fire.

**Risk margin if the schema shifts.** If a future stream-json schema
delivered prompt echoes as `type:"text"` blocks, the inner case could
false-positive on a prompt echo of `BATCH_RESULT: OK`. Consequence
bounded by Failure modes §8: misfire closes stdin a turn early; build
exits cleanly; gate log retains whatever verdict (if any) was emitted.
No deadlock; ceiling is one short-circuited build — strictly better
than today.

### 2. Synth-OK fallback (formal design surface) — `scripts/lib/gates.sh` `_build_one_gated`

The fallback that `_build_one_gated` already ships (since hotfix 5b9ca23)
fires when (a) `build_status` (log grep) returns empty AND (b) the
per-TDD fragment exists with `last_cleared_review_sha` matching
`git rev-parse HEAD` AND (c) `git status --porcelain` is empty. It
appends to the gate log:

```
BATCH_RESULT: OK (synthesized: build exited cleanly without sentinel; \
  last_cleared_review_sha=<sha> == HEAD, working tree clean)
```

and returns 0. This is the existing implementation — no code change
needed for this TDD; it is documented here so the design captures the
structural fallback as part of the protocol-of-record. Future
replacements of `_build_one_gated` MUST preserve this branch under the
stated guard. The guard is grounded in artifacts ([[ADR 0006]]): the
state record + `git status` are the verifiable substrate, not the
author's missing sentinel.

### 3. RESUME-COMPLETION prompt language — `scripts/build-prompt.md`

The build prompt's "Build discipline" → "RESUME-COMPLETION CASE" bullet
OVERRIDES the "Close" section: NO tests, NO ci-checks.sh, NO shellcheck,
NO long-running Bash. Emit `BATCH_RESULT: OK` as the only line and end
the turn. This is the existing prompt (since hotfix 628b9d7) — no
code change needed; documented here so the prompt language is part of
the design-of-record alongside the structural fix in §1.

## Data & state

No new fragment fields. No schema bump. The existing TDD 0020 §4 fields
(`last_cleared_review_sha`, `cleared_step_log`) are read by §2's synth-OK
fallback; they are written only by TDD 0020's per-step review path
(unchanged).

## Sequencing / implementation plan

1. **Modify `_per_step_review_loop`'s BATCH_RESULT inner case** in
   `scripts/lib/gates.sh` to close `${build_in}` with the documented
   `exec` line + comment. Preserve the existing no-op semantics for the
   rest of the branch; the close is the only behavior change.

2. **Add a regression test** under `tests/` that exercises the
   lifecycle: a stub `claude` (a small shell script) emits one
   assistant-content event containing `BATCH_RESULT: OK` followed by a
   `result(end_turn)` event, then blocks reading stdin. Drive
   `_per_step_review_loop` against the stub via `source`-load of
   `scripts/lib/gates.sh` (the existing test-harness pattern). Assert:
   the stub exits within 5 seconds (NOT 600s); the gate log contains
   `BATCH_RESULT: OK` and no `THROUGHLINE_BUILD_HANG`. Wire the new
   test into `tests/implement-gate.test.sh` so ci-checks.sh
   regression-gates it.

3. **Flip TDD 0020's `Status:` line** to `superseded by 0025` in the
   same authoring commit (mechanical text edit, body unchanged per the
   tdd-author append-only rule). Already performed during this TDD's
   authoring; the build does not need to repeat it.

## Failure modes & edge cases

- **Build never emits `BATCH_RESULT` and exits cleanly (rc=0).** Handled
  by §2 synth-OK fallback. Fires only when state grounds the verdict
  (`last_cleared_review_sha == HEAD` AND tree clean).
- **Build never emits `BATCH_RESULT` and exits non-zero.** §2's
  fallback does not fire (no state grounding). `_build_one_gated`
  returns the non-zero rc; pause-retry's `_classify_cause` routes via
  signal class (143 → transient, 137 → fatal). Unchanged from today.
- **Build emits `BATCH_RESULT: FAIL` or `BATCH_RESULT: BLOCKED`.** §1's
  stdin-close still fires (the case matches the prefix, not the
  verdict). The build then exits cleanly. `build_status` greps the
  explicit `FAIL`/`BLOCKED`, which is non-empty, so the synth path's
  `[ -z "$bs" ]` guard skips synthesis. `_build_one_gated` returns 1.
  Explicit failure verdicts preserved correctly.
- **Stdin close raises EBADF (race with another writer).** The
  `2>/dev/null || true` guard swallows it. There is no other writer
  to `${build_in}` in `_per_step_review_loop`'s scope; this case is
  defensive only.
- **Build crashes after the stdin close (segfault, OOM, external
  SIGKILL).** `wait` returns the signal-derived exit code (e.g. 137,
  139); `_classify_cause` routes; existing transient/fatal flow takes
  over. Unchanged from today.
- **Multiple `BATCH_RESULT` lines across turns (model recovers from a
  bad turn and re-emits).** The inner case fires on the first; the
  second close is a no-op under `|| true`. Idempotent.
- **`_extract_event_text` returns the BATCH_RESULT text out of an
  unexpected event type (e.g. a future stream-json schema change).**
  Acceptable false-positive: closing stdin early is safe; the build
  process exits cleanly; the gate log retains whatever BATCH_RESULT it
  contains. The cost of a misfire is one short-circuited build coproc,
  not a deadlock — strictly better than the failure mode this TDD fixes.

## Verification plan

**Observable surface:** the build gate's log
(`<logdir>/<slug>.log`), the runner's exit code from `_per_step_review_loop`
and `_build_one_gated`, the per-TDD fragment's `gates_completed` array,
and the wall-clock duration between the final `result(end_turn)` event
and the runner advancing past the build gate.

**Observation points:**

1. **Lifecycle: BATCH_RESULT → clean exit, no HANG.** Fixture: a stub
   `claude` (shell script on `$PATH` shadow that the test prepends)
   that prints the two stream-json events (`assistant` with
   `message.content[0].text` containing `BATCH_RESULT: OK`, then a
   `result` event with `stop_reason: end_turn` and
   `terminal_reason: completed`) to stdout, then runs
   `while IFS= read -r _line; do :; done` to consume stdin until EOF,
   then `exit 0`. Drive `_build_one_gated` (which calls
   `_per_step_review_loop` internally). Expect: the stub exits within
   5 seconds of emitting the `result` event (measured by `date +%s`
   before driving and after `wait`); the gate log contains one
   `BATCH_RESULT: OK` line in assistant content; the gate log
   contains NO `THROUGHLINE_BUILD_HANG` marker; `_build_one_gated`
   returns 0.

2. **Synth-OK fallback (codification regression).** Fixture: a stub
   `claude` that emits only `system` and `result` events (no assistant
   content), exits rc=0. **Fixture setup mechanism:** seed
   `last_cleared_review_sha` by calling `_record_cleared_step <slug>
   <step-id> <base-sha> <current-HEAD-sha> ""` (the same setter
   [[0020]] §4 names, which atomically writes both the
   `last_cleared_review_sha` field and a `cleared_step_log` entry —
   producing a fragment that matches what an actual cleared per-step
   review would produce). Working tree is clean by default in a fresh
   worktree. Drive `_build_one_gated`. Expect: the gate log gains a
   line beginning `BATCH_RESULT: OK (synthesized:`; `_build_one_gated`
   returns 0.

3. **Synth-OK does NOT fire on stale state.** Fixture: same as (2) but
   seed via `_record_cleared_step` with an SHA other than the current
   HEAD (e.g., the merge-base SHA, plus one additional commit in the
   worktree after seeding so HEAD diverges from the recorded clear).
   Drive `_build_one_gated`. Expect: no synthesized line is appended;
   `_build_one_gated` returns 1.

4. **Synth-OK does NOT fire on dirty tree.** Fixture: same as (2)
   (`_record_cleared_step` seeds `last_cleared_review_sha == HEAD`) but
   create an untracked file in the worktree before driving
   `_build_one_gated` (so `git status --porcelain` is non-empty). Drive
   `_build_one_gated`. Expect: no synthesized line is appended;
   `_build_one_gated` returns 1.

5. **Explicit FAIL is preserved.** Fixture: a stub `claude` that emits
   one `assistant` event whose text contains `BATCH_RESULT: FAIL
   reason-here`, then a `result(end_turn)` event, then exits 0. Drive
   `_build_one_gated` (which calls `_per_step_review_loop` internally
   — verification points 1 and 5 both drive the full composed gate
   entry point, not the inner function in isolation). Inspect the log
   and the return code. Expect: the inner case fires (stdin closed on
   BATCH_RESULT match — visible because the build exits within 5
   seconds rather than hitting the 600s watchdog); the gate log retains
   the FAIL verdict; `_build_one_gated` returns 1; the synth path does
   NOT fire (the guard `[ -z "$bs" ]` is false because `build_status`
   greps the explicit `BATCH_RESULT: FAIL`).

**Expected observations (PASS):** every numbered point above yields the
cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-56 (continuous in-build review, not end-of-build only) | Carried from [[0020]] §1 + §2; the stdin-close in §1 here closes the design gap that allowed the runner to discard an emitted `BATCH_RESULT: OK`. Without it, FR-56's "first finding emitted before half eventual lines" acceptance was reachable but the *gate verdict* was dropped — a regression on 0009 + 0010. Verification §1 falsifies the lifecycle. |
| FR-57 (no re-evaluation of cleared code) | Unchanged. Carried from [[0020]] §3 + §4. |
| FR-59 (cross-step learning within one TDD) | Unchanged. Carried from [[0020]] §3 + §5. |

No gaps.

## Dependencies considered

No new external dependencies. The change is a one-line behavior fix
inside an existing bash function (`exec {build_in}>&-`) plus design
documentation of an already-shipped fallback. The
`_extract_event_text`'s existing `jq` dependency (with pure-bash
fallback) is unchanged.

Alternatives considered:

- **Move BATCH_RESULT detection to the `result` event rather than
  assistant content** — rejected: the `result.result` field can also
  contain stale prompt-instruction text (Read tool result echoes),
  making detection less reliable than assistant message content where
  `_extract_event_text` already filters to `type==text`. The detection
  surface is correct; only the lifecycle response needed fixing.
- **Drop `--input-format stream-json` and use single-shot `claude -p`**
  — rejected: [[0020]]'s per-step review handshake requires multi-turn
  input (the runner writes STEP_REVIEW replies back on stdin). Dropping
  stream-json input would re-collapse to end-of-build review (FR-56
  regression).
- **Kill the build on BATCH_RESULT match (SIGTERM) rather than close
  stdin** — rejected: SIGTERM produces exit 143 which `_classify_cause`
  routes as transient, the exact failure shape this TDD is fixing.
  Clean stdin-close lets the build exit 0 and the runner trust the
  emitted verdict.
- **Shorten the inter-event watchdog from 600s to e.g. 30s** —
  rejected: legitimate steps can stream thinking_tokens slowly; a 30s
  gap between events is achievable on Opus with a hard reasoning
  problem. The watchdog protects against true hangs, not against
  intentional lifecycle progression. Lowering it would make false-hang
  classification more likely, not less.

## PRD conflicts surfaced (and resolution)

None. The PRD's FR-56 requirement is mechanism-agnostic; this TDD
specifies the lifecycle precisely without contradicting any FR/NFR. No
`## Open question` items remain unresolved by this refinement.

## Decisions to promote (ADR candidates)

None. The stream-json lifecycle requirement is local to the build
coprocess; it is not a cross-cutting principle suitable for ADR.
[[ADR 0006]]'s "gate verdicts grounded in verifiable artifacts" already
covers the spirit of why a synthesized verdict is acceptable (the state
record IS the verifiable artifact).

## Scope override

This TDD's body is over the 350-line default `THROUGHLINE_TDD_MAX_LINES`
cap. Justification: the design-critique gate (step 7b first pass)
raised the liveness argument for the stdin-close fix as a BLOCKER —
the chain `stdin-close → build EOF → exit → stdout closes → read EOF →
loop exits` must be traced explicitly, not asserted, in a TDD whose
entire purpose is fixing a deadlock. The proof (§1 "Liveness") plus
the two-stage match-safety argument plus the two captured hotfixes
(synth-OK + RESUME-COMPLETION) co-locate on the build-coprocess
protocol surface; splitting would fragment the lifecycle proof across
multiple TDDs and re-create the BLOCKER. Per FR-53's escape clause:
legitimately-wide design where the proof depth IS the value the
critique demanded.

## Touched files

- `scripts/lib/gates.sh` — modify `_per_step_review_loop`'s BATCH_RESULT inner case to close `${build_in}`.
- `tests/build-coprocess-lifecycle.test.sh` — new regression test exercising verification points 1, 2, 3, 4, 5 (the full plan; each point a labeled subtest).
- `tests/implement-gate.test.sh` — wire the new test into the aggregator so ci-checks regression-gates it.

Total: 3 files touched.

## Expected diff size

- `scripts/lib/gates.sh` — ~10 lines added (one `exec` + ~8 lines of inline comment explaining the stream-json input lifecycle).
- `tests/build-coprocess-lifecycle.test.sh` — ~150 lines added (4 verification-point cases + a small stub `claude` shim).
- `tests/implement-gate.test.sh` — ~5 lines added (the standard one-eval entry pattern).

Total expected diff: ~165 lines across 3 files. No exceptions needed.

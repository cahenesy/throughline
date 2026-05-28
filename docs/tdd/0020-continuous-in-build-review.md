# TDD 0020: Continuous in-build review — per-step checkpoints, scoped diff reading, cross-step learning

Status: draft
PRD refs: FR-56, FR-57, FR-59
PRD-rev: a961955
ADR constraints: 0003, 0004, 0005, 0006, 0007

## Approach

Move the review gate (gate d) from a single end-of-build pass to a sequence
of per-step passes during the build, where the unit of "step" is a numbered
item in the TDD's `## Sequencing / implementation plan` section. Each
per-step pass reads only the diff range since the last *cleared* review pass
on the same TDD, so cleared code is never re-evaluated. After all steps
clear, a final consolidated pass issues the gate's flip-authority verdict
(`REVIEW_RESULT: PASS`) over the union of cleared ranges, preserving
existing TDD 0007's review-gate flip semantics.

Three new pieces of state make the loop falsifiable per FR-70 / ADR 0006
(every gate decision reproducible from artifacts alone):

1. A `last_cleared_review_sha` per-TDD fragment field — the SHA the last
   cleared per-step review pass anchored to.
2. A `cleared_step_log` array per-TDD — one entry per cleared step, recording
   `{ step_id, base_sha, head_sha, pattern_tags[] }`. Anyone re-running
   the review pass on `<base>..<head>` of any cleared entry can verify the
   pass would still clear; anyone counting addressed patterns can verify
   FR-59's cross-step-learning acceptance.
3. A `STEP_COMMIT:` sentinel the build emits at the end of each Sequencing
   item, naming the step ID and the commit SHA. The runner intercepts this
   sentinel between build phases and runs the per-step review pass.

The rework loop (TDD 0019) is the consumer of halting findings — when a
per-step review pass emits a halting finding (per the severity taxonomy
delivered by TDD 0021), the wiring delivered by TDD 0019 takes over. This
TDD's job is to deliver the per-step scaffolding the rework loop runs in.

## Components & interfaces

### 1. `STEP_COMMIT:` sentinel in the build prompt — `skills/implement/SKILL.md` + the build prompt template

The build prompt is extended to instruct the author: at the end of each
numbered Sequencing item, the author MUST:

1. Stage edits to that step's intent.
2. Create a commit whose message starts with `step(<step-id>): ` where
   `<step-id>` is the integer index of the Sequencing item the commit
   completes.
3. Emit a single-line sentinel to stdout: `STEP_COMMIT: <step-id> <sha>`.
4. Block until the runner emits `STEP_REVIEW: PASS` or `STEP_REVIEW: BLOCK`
   on the build's stdin. (The runner uses the existing TDD-0010 stdio
   contract for build/runner communication.)

The build does not start the next Sequencing item until the runner's
verdict is received. On `STEP_REVIEW: BLOCK`, the build enters the
existing rework path (TDD 0019).

### 2. Runner interception — `scripts/lib/gates.sh`

A new function `_per_step_review_loop <slug> <log>` is wired into
`_build_one_gated` (post-TDD-0017). The function reads the build's stdout
line-by-line; on each `STEP_COMMIT: <step-id> <sha>` line:

1. Compute the diff range: from the TDD fragment's
   `last_cleared_review_sha` (or the build's start SHA if no prior
   cleared step) to the new `<sha>`.
2. Spawn a review `claude -p` (same model as the existing review gate —
   Sonnet) with the existing review prompt extended by §3.
3. Parse the review verdict:
   - On `REVIEW_RESULT: PASS`: append a `cleared_step_log` entry; update
     `last_cleared_review_sha`; write `STEP_REVIEW: PASS` to the build
     process's stdin.
   - On `REVIEW_RESULT: BLOCK <finding-summary>`: write `STEP_REVIEW:
     BLOCK <finding-summary>` to the build's stdin and hand off to the
     rework loop (TDD 0019). The build's next response is expected to
     be a rework commit, not the next Sequencing item.

After all step commits clear, the runner runs the existing final
consolidated review pass over the full TDD diff (preserving TDD 0007's
`REVIEW_RESULT: PASS` flip verdict). The consolidated pass scope is
`<build-start-sha>..<HEAD>`; it is allowed to find new issues the
per-step passes missed (a per-step pass may have local-context blind
spots a whole-TDD pass catches). On consolidated-pass BLOCK, the
rework loop runs against the consolidated diff.

### 3. Review prompt scope-extension — review prompt template

The review prompt (`scripts/review-prompt.md`) is extended:

- A new section "Scope of this pass": "You are reviewing the diff
  `git diff {base_sha}..{head_sha}` on the branch `{branch}`. Do not
  comment on code outside this diff range. Code outside the range was
  cleared by a prior pass."
- A new section "Prior addressed patterns" (FR-59): a CSV list of
  `pattern_tag` strings from the TDD's `cleared_step_log[*].pattern_tags`
  is interpolated. The prompt instructs: "Patterns the author has been
  shown and corrected once already, within this TDD's build, are listed
  above. If you see the same categorical pattern recur in this diff,
  cite it explicitly as `FINDING_KIND: recurrent-pattern <tag>` — the
  build should have learned from the prior pass."
- A new instruction on emit: "For each finding you emit, append a
  `pattern_tags: [<tag1>, <tag2>, ...]` line under the finding text.
  Tags are short (≤ 4 words) categorical labels — e.g.,
  `unchecked-fragment-write-return`, `missing-shellcheck-disable-justification`,
  `commit-without-running-tests`. Two different findings with the same
  tag are the same categorical pattern."

The runner reads `pattern_tags` lines from the review output and stores
them on the cleared step's `cleared_step_log` entry. Tag extraction is a
small awk pass; no model call.

### 4. Cleared-step log + last-cleared-SHA — `scripts/lib/state.sh`

Two new fragment fields:

- `last_cleared_review_sha` (string | null) — the head SHA the last
  per-step or consolidated review pass cleared. `null` when no review
  pass has cleared yet.
- `cleared_step_log` (array of objects):
  ```
  { step_id: <int>, base_sha: <sha>, head_sha: <sha>,
    pattern_tags: [<string>], cleared_at: <epoch> }
  ```

Setter: `_record_cleared_step <slug> <step-id> <base-sha> <head-sha> <pattern-tags-csv>`
in `scripts/lib/state.sh`. Updates both fields atomically.

### 5. Reviewer's pattern-tag inheritance across rework attempts

When the rework loop (TDD 0019) runs a rework attempt for a `BLOCK`ing
finding, the next review pass on the same step's diff range receives:

- The finding text the rework attempted to address
- The pattern tags of that finding

The review prompt instructs: "If the rework attempt did not address the
cited finding (the same pattern recurs in the new diff), emit a finding
that explicitly cites the prior attempt's pattern tag. This is a
`recurrent-pattern` finding — the rework loop's TDD-0019 attempt counter
treats it as the next attempt at the same finding."

This is a soft-enforcement nudge in the prompt, not a deterministic
runner-side check. The deterministic check is the per-(gate, step)
attempt counter in TDD 0019 — repeated findings on the same step
exhaust the counter regardless of whether they share a tag.

## Data & state

§4 above. The `cleared_step_log` is bounded (≤ number of Sequencing items
in the TDD, typically ≤ 10); its size is not a concern for fragment size.
Schema-version bumped from TDD 0019's value by one.

## Sequencing / implementation plan

1. **Add fragment fields + setter** in `scripts/lib/state.sh`:
   `last_cleared_review_sha`, `cleared_step_log`, and the
   `_record_cleared_step` setter. Bump schema-version.
2. **Implement `_per_step_review_loop`** in `scripts/lib/gates.sh`. Wire
   into `_build_one_gated` so the build's stdout is scanned for
   `STEP_COMMIT:` sentinels and the stdin receives `STEP_REVIEW:` replies.
3. **Extend the build prompt** in `skills/implement/SKILL.md` and the build
   prompt template with the `step(<step-id>):` commit + `STEP_COMMIT:`
   sentinel + stdin-block protocol from §1.
4. **Extend the review prompt** with the scope, prior-patterns, and
   pattern-tag emission additions from §3.
5. **Run the consolidated final pass** after the per-step loop terminates;
   reuse the existing review-gate path with the consolidated-diff scope.

## Build subprocess protocol (REQUIRED — concrete spec, not deferred)

The build/runner handshake in §1 — build emits `STEP_COMMIT:` to stdout,
blocks on `STEP_REVIEW:` from stdin — requires the build's `claude -p`
invocation to support multi-turn interaction. The current runner
(TDD 0005) invokes `claude -p` in single-shot mode. TDD 0020 changes
this for the build phase specifically. Concrete spec:

### Invocation

```bash
claude -p "$prompt" \
  --input-format stream-json \
  --output-format stream-json \
  --model "${THROUGHLINE_BUILD_MODEL:-opus}" \
  [...existing flags from build_one...]
```

Stream-JSON mode emits one JSON event per line on stdout (message
deltas, tool calls, turn boundaries, errors) and consumes one JSON
event per line on stdin (new user-turn messages). The runner does NOT
parse the model's reasoning text; it greps the same `STEP_COMMIT:` /
`BATCH_RESULT:` / `SELF_REVIEW_BEGIN..END` sentinels out of the
content events.

### Bash subprocess management — coprocess + fd-redirect pattern

The runner uses bash's `coproc` builtin to manage the bidirectional
stdio. Skeleton (lives in `_per_step_review_loop`):

```bash
coproc BUILD { claude -p "$prompt" --input-format stream-json \
                       --output-format stream-json \
                       --model "${THROUGHLINE_BUILD_MODEL:-opus}" \
                       2>>"$LOGDIR/build.err"; }
exec {build_in}>&"${BUILD[1]}"
exec {build_out}<&"${BUILD[0]}"

while IFS= read -r -t 600 evt <&"${build_out}"; do
  # read -t 600: 600s inter-event timeout (Failure paths §2). On
  # timeout, read returns non-zero with $REPLY empty; the loop falls
  # through to the kill + transient-halt path below.
  # mirror raw event to per-TDD log for human + later parsing
  printf '%s\n' "$evt" >> "$log"

  # extract any text content the event contains
  text="$(printf '%s' "$evt" | _extract_event_text)"
  case "$text" in
    *"STEP_COMMIT: "*)
      step_id=$(printf '%s' "$text" | awk '/STEP_COMMIT:/ {print $2}')
      sha=$(printf '%s'     "$text" | awk '/STEP_COMMIT:/ {print $3}')
      verdict=$(_run_per_step_review "$slug" "$step_id" "$sha")
      # send the verdict back as a new user-turn message
      printf '%s\n' "$(_user_turn_json "$verdict")" >&"${build_in}"
      ;;
    *"BATCH_RESULT: "*)
      # final-turn output captured; loop will exit when subprocess closes
      break
      ;;
  esac
done

wait "${BUILD_PID}"
exec {build_in}>&-
exec {build_out}<&-
```

`_extract_event_text` is a small `jq` filter (or pure-bash JSON
extractor if the runner stays jq-free) that pulls the `content[*].text`
field out of a `message` event, returning empty for non-message events.
`_user_turn_json` wraps a string in the stream-JSON shape required for
a user turn (`{"type":"user","message":{"role":"user","content":"…"}}`).

### Turn structure + BATCH_RESULT timing

Each `STEP_COMMIT:` ends a build turn; the runner's STEP_REVIEW reply
starts the next turn. The build's final turn is the one that emits
`BATCH_RESULT:` (and `SELF_REVIEW_BEGIN..END` per TDD 0021 §5, which
appears in the same final turn's content immediately before
`BATCH_RESULT:`). The runner reads the full final turn — drains all
event lines until the subprocess closes its stdout — before dispatching
the consolidated review pass. This guarantees `SELF_REVIEW` is captured
before consolidated-review interpolation runs.

### Failure paths within the protocol

- **Build subprocess dies before any STEP_COMMIT.** `read` exits with
  non-zero; runner detects subprocess close via `wait` exit code; halt
  recorded with a `transient` cause (existing TDD-0011 vocabulary) so
  the existing resume flow takes over.
- **Build emits STEP_COMMIT then never accepts the STEP_REVIEW reply
  (deadlock risk).** The runner's `printf >&"${build_in}"` is
  non-blocking (writes to the kernel pipe buffer); only blocks if the
  buffer fills up (default 64KB on Linux, sufficient for a
  multi-line JSON message). To bound the failure case, the runner sets
  a 600-second alarm after each STEP_REVIEW write; if the next event
  doesn't arrive within the alarm, the build is killed and a
  `transient` halt is recorded.
- **Build's stream-json output contains malformed events.** Each line
  is parsed independently; malformed lines are logged with a `WARNING:
  malformed stream-json event` prefix and skipped. The loop continues.

### Gates that stay single-shot

The runtime-verify, review (per-step + consolidated), and rework gates
retain single-shot invocation. They have no inter-turn dependency; each
runs as its own `claude -p` call. Only the build gate switches to
multi-turn.

### Verification of the protocol itself

The verification plan §1's "sentinel handshake on a clean build" is
the integration test. Additional protocol-specific points are added to
the verification plan: §8 below.

## Failure modes & edge cases

- **Build emits a `STEP_COMMIT:` for a step ID out of order.** The runner
  records the diff range from `last_cleared_review_sha` to the cited SHA
  regardless of step ID; the step ID is informational. Out-of-order step
  IDs are surfaced as a `minor` finding by the reviewer (TDD 0021).
- **Build commits without emitting `STEP_COMMIT:`.** The runner does not
  intercept; the commit ships unreviewed. The final consolidated pass
  catches it. Result: continuous review degrades to end-of-build review
  for that step — same risk as today's behavior. To improve: a future
  TDD could enforce sentinel emission via build prompt hardening; not in
  this round.
- **Per-step review BLOCKs but rework loop is not present (TDD 0019 not
  merged yet).** The runner is wired against the TDD-0019 rework loop;
  if TDD 0019 is reverted, this TDD's per-step BLOCK behavior degrades to
  the existing end-of-build BLOCK behavior (the per-step pass becomes a
  no-op, the build runs to completion, the final consolidated pass
  catches the same finding). This degradation is graceful but loses
  FR-56's "first finding emitted before half the eventual line count
  written" acceptance — the dependency ordering (TDD 0019 first) is
  enforced by the sequencing plan.
- **Step has no commit (the author finished the step's intent without
  any source change — e.g., the step was "review prior step's edits").**
  The author emits `STEP_COMMIT: <step-id> <prior-HEAD-sha>`; the diff
  range is empty; the review pass clears trivially with an empty
  `pattern_tags` set.
- **Cleared-step log grows unbounded across resume cycles.** Resumes
  read the existing log; new clears append. A TDD with 20 build/resume
  cycles ends up with 20+ entries. Acceptable — fragment size remains
  small.
- **`pattern_tags` are inconsistent across reviewer invocations.** Tags
  are model-generated; the same categorical issue may be tagged
  differently across runs. FR-59's acceptance (categorical pattern P
  addressed in step N does not recur in step N+1) is best-effort under
  this design; the reviewer prompt's "recurrent-pattern" instruction is
  the enforcement lever. A future TDD could harden with a small
  controlled tag vocabulary.

## Verification plan

**Observable surface:** the per-TDD fragment's `cleared_step_log` and
`last_cleared_review_sha`, the build's stdout / runner's stdin (sentinel
exchange), and the review log files.

**Observation points:**

1. **Sentinel handshake on a clean build.** Fixture: a 3-step TDD whose
   build emits three `STEP_COMMIT:` sentinels with successive SHAs. Expect:
   the runner emits three `STEP_REVIEW: PASS` lines on the build's stdin;
   the fragment's `cleared_step_log` has three entries with the SHAs in
   order; `last_cleared_review_sha` matches the third entry's `head_sha`.
2. **Scoped diff range observed.** Inspect the review log for the second
   step. Expect: the review prompt's interpolated "Scope of this pass"
   names `base_sha == cleared_step_log[0].head_sha` (i.e., the first
   step's clear point), not the build's start SHA. This is FR-57
   falsifiable.
3. **Pattern tags recorded.** Run a fixture where step 1's review pass
   emits a finding with `pattern_tags: [unchecked-fragment-write-return]`.
   The author addresses it (rework loop, TDD 0019). The fragment's
   `cleared_step_log[0].pattern_tags` ends up `["unchecked-fragment-
   write-return"]` after clear.
4. **Cross-step learning prompt observed.** Inspect step 2's review
   prompt. Expect: "Prior addressed patterns: unchecked-fragment-write-
   return" appears in the prompt text.
5. **FR-56 acceptance (first finding before half of eventual lines
   written).** Fixture: TDD where step 1's natural implementation
   contains the finding. Capture: total eventual TDD diff line count;
   line count at the point step 1's review pass emits its finding.
   Expect: step-1 finding line count < ½ × total eventual line count.
6. **Final consolidated pass runs after all step clears.** Inspect the
   review-log directory; expect one log per cleared step plus one
   final-consolidated log. The consolidated log's prompt scope is
   `build-start-sha..HEAD`.
7. **Sentinel-less build degrades to end-of-build.** Fixture: a build
   that never emits `STEP_COMMIT:`. Expect: no per-step review logs;
   only the final consolidated review log; the build proceeds to
   completion (degraded mode per Failure modes §2).
8. **Protocol-level deadlock recovery.** Fixture: mock build subprocess
   that emits one `STEP_COMMIT:` then ignores its stdin (never reads
   the STEP_REVIEW reply, never emits another event). Expect: runner's
   600-second alarm fires; subprocess killed; halt recorded with
   `transient` cause; resume flow takes over.
9. **Malformed stream-json events tolerated.** Fixture: build emits a
   line of garbage JSON between two valid events. Expect: `WARNING:
   malformed stream-json event` appears in the log; the next valid
   event is processed normally; the run completes successfully.

**Expected observations (PASS):** every numbered point above yields the
cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-56 (continuous in-build review, not end-of-build only) | §1 build prompt sentinel + §2 runner interception loop produces a review pass at each Sequencing-item boundary; verification §5 falsifies the "first finding before half eventual lines" acceptance |
| FR-57 (no re-evaluation of cleared code) | §4 `last_cleared_review_sha` + §3 review-prompt scope-of-this-pass interpolation reads only `git diff <last-cleared>..HEAD`; verification §2 falsifies that the diff range is right |
| FR-59 (cross-step learning within one TDD) | §3 pattern-tag emission + §4 `cleared_step_log[*].pattern_tags` + §3 prior-patterns prompt interpolation + §5 cross-rework-attempt inheritance; verification §3 + §4 falsify the chain |

No gaps.

## Dependencies considered

No new external dependencies. The build/runner stdio protocol uses the
existing TDD-0010 contract; the review pass uses the existing review-gate
infrastructure.

Alternatives considered:
- **Step unit = git commit instead of Sequencing item** — rejected: git
  commits are author-chosen granularity, often too fine (typo-fix
  commits) or too coarse (squash-style). The Sequencing item is the
  design-intent unit and aligns with TDD 0014's split-set heuristic.
- **Per-step review pass on a different model than gate d** — rejected:
  every review pass should produce the same severity classifications;
  using two models risks per-step and consolidated passes disagreeing
  on whether a finding is `major`. NFR-3 already requires reviewer
  diversity vs the author; that's preserved at the gate boundary.

## PRD conflicts surfaced (and resolution)

The PRD's "Step unit for continuous review" Open question is resolved
here: the TDD's `## Sequencing / implementation plan` numbered items are
the step unit. The PRD's "Review scope mechanism" Open question is
resolved here too: runner records `last_cleared_review_sha`; next pass
reads `git diff <last-cleared-sha>..HEAD`. Both resolutions match the
design plan.

## Decisions to promote (ADR candidates)

- **ADR 0006 — Gate verdicts grounded in verifiable artifacts.** This
  TDD's `last_cleared_review_sha` + `cleared_step_log` mechanism is the
  load-bearing example of ADR 0006 in operation: every review verdict
  is reproducible from `git diff` of the recorded SHA range, with no
  need to consult the author's narrative. Promotion confirmed by the
  design plan; high confidence.

## Scope override

This TDD's doc body is over the 350-line default
`THROUGHLINE_TDD_MAX_LINES` cap established by TDD 0014. Justification:
the design-critique gate (TDD 0019 first pass) raised the "Build
subprocess protocol" subsection as a BLOCKER without which the
multi-turn stdio pattern would be too underspecified to implement
without guessing — the concrete bash coprocess + stream-json invocation
spec (~90 lines) is load-bearing for FR-56's mechanism. Trimming would
recreate the BLOCKER. Per FR-53's escape clause: legitimately-wide
design where one subsection (the subprocess protocol) carries
implementation-mandatory specificity.

## Touched files

- `scripts/lib/state.sh` (post-TDD-0015, post-TDD-0019) — fragment
  fields + setter from §4
- `scripts/lib/gates.sh` (post-TDD-0017, post-TDD-0019) —
  `_per_step_review_loop` + wiring into `_build_one_gated`
- `skills/implement/SKILL.md` — build prompt addition from §1
- `scripts/review-prompt.md` — additions from §3

Total: 4 files touched.

## Expected diff size

- `scripts/lib/state.sh` — ~50 lines added
- `scripts/lib/gates.sh` — ~120 lines added (`_per_step_review_loop`
  + sentinel parsing + stdin emission)
- `skills/implement/SKILL.md` — ~40 lines added
- `scripts/review-prompt.md` — ~60 lines added

Total expected diff: ~270 lines across 4 files. No exceptions needed.

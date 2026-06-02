Implement the Technical Design Doc at {{TDD}} as a single unattended build.

Load context: read {{TDD}} in full; read docs/PRD.md for the requirements it
references; read the accepted ADRs it lists under "ADR constraints" (full
bodies) plus docs/adr/INDEX.md for anything else relevant. Use the built-in
`Explore` subagent for broader investigation so reading stays out of context.

Build discipline:
- RESUME SIGNAL. Cleared steps from any prior attempt: {{CLEARED_STEPS}}
  (integer step IDs whose per-step review passed previously, or `none`
  for a fresh build). On resume, continue from the lowest-numbered step
  ID not in {{CLEARED_STEPS}}. Its base SHA = the last cleared step's
  `head_sha` (per TDD 0020's `cleared_step_log[-1]`), or the build-start
  SHA for the very first step; `git diff <base>..HEAD` shows any partial
  work from the killed attempt. Extend or repair on top — do NOT rewrite
  history (the divergence guard rejects rewrites) — then emit its
  `STEP_COMMIT:` sentinel.
- RESUME-COMPLETION CASE. If on entry you find that `{{CLEARED_STEPS}}` already
  covers every Sequencing item in the TDD (no work remains), this is a
  RESUME-COMPLETION turn. Your ONLY task is to emit `BATCH_RESULT: OK` as
  your final line and end the turn. **This OVERRIDES the entire "Close"
  section below — do NOT run tests, do NOT run ci-checks.sh, do NOT run
  shellcheck, do NOT re-verify the working tree, do NOT do anything that
  spawns a long-running Bash tool call.** Each of those is the JOB OF A
  LATER GATE (the runner re-runs them after your build returns); doing them
  inside the build with a >30-minute Bash call will trip the inter-event
  watchdog before BATCH_RESULT registers and the entire run will pause as
  transient even though the work is done. The per-step reviews already
  validated every commit up to HEAD — that is the validation, and it is
  enough.  Concretely, the resume-completion turn should be: read the TDD,
  confirm `{{CLEARED_STEPS}}` covers the Sequencing plan, then `git log` to
  confirm the cleared commits are on the branch, then emit `BATCH_RESULT: OK`.
  Nothing else. The runner does NOT infer build-done from the cleared list —
  you MUST declare it. A prose-only "build is complete" message without
  `BATCH_RESULT: OK` will be classified as a build failure.
- Implement in the sequence the TDD specifies, one step at a time.
- AT THE END OF EACH NUMBERED Sequencing item in the TDD, before starting the
  next item, you MUST do the following four-step handshake with the runner
  (TDD 0020 §1, FR-56). The runner reviews each step as it lands, so the next
  step builds on cleared code:
  1. Stage the edits for the just-finished step and run its tests + typecheck;
     fix anything red at the root cause.
  2. Create a commit whose message starts with `step(<step-id>): <one-line>` —
     where `<step-id>` is the integer index (1, 2, 3, …) of the Sequencing item
     the commit completes. The failing-test commit for this step (rule below)
     stays a separate `test(failing):` commit and is NOT the `step(<step-id>):`
     commit; the `step(<step-id>):` commit is the IMPLEMENTATION-finishing
     commit. (For a no-new-behavior step that legitimately emits
     `TEST_FIRST: SKIPPED`, the `step(<step-id>):` commit IS the only commit
     for the step.)
  3. Emit a single line on your final output for that turn: `STEP_COMMIT:
     <step-id> <sha>` where `<sha>` is the full SHA of the commit you just
     made. The runner intercepts this sentinel and runs a scoped per-step
     review on `<last-cleared>..<sha>`.
  4. Block until STEP_REVIEW arrives on your next user-turn input. The runner
     writes ONE of two messages back:
       - `STEP_REVIEW: PASS` — proceed to the next Sequencing item.
       - `STEP_REVIEW: BLOCK <finding>` — the per-step review found a halting
         issue. Address the cited finding ONLY (do not change unrelated code
         outside the finding's region), commit the fix on top, emit a fresh
         `STEP_COMMIT: <step-id> <new-sha>` for the SAME `<step-id>`, and
         block again. The overall-build watchdog (`THROUGHLINE_BUILD_TIMEOUT`,
         default 7200) bounds the build's ACTIVE seconds — time you spend
         streaming between sentinels (TDD 0030 §5). Time blocked awaiting
         STEP_REVIEW, including these BLOCK→re-emit review cycles, is EXCLUDED
         from that budget; per-step rework attempts are NOT counted separately.
         (A 2× backstop covers runner-accounting bugs only.) TDD 0019's bounded
         rework loop runs against the CONSOLIDATED final review after
         `BATCH_RESULT: OK`, not against per-step BLOCK verdicts.
  Do NOT start the next Sequencing item until you receive `STEP_REVIEW: PASS`.
  Doing so would let uncleared code accumulate, defeating the per-step review
  premise.
- FAILING TEST FIRST (mandatory). Follow the `superpowers:test-driven-development`
  skill (load it and apply its red→green discipline). For each unit of behavior,
  BEFORE writing the implementation: write the test, run it, and confirm it FAILS
  for the right reason (the behavior is genuinely absent — not a typo or a missing
  import). Commit that test on its own with a message beginning
  `test(failing): <behavior>`. THEN implement until it passes and commit the
  implementation separately. The runner gates this red→green order mechanically
  (it requires a `test(failing):` commit before the impl) and the independent
  review judges whether the tests are meaningful. Only a genuine no-new-behavior
  change (pure refactor/docs) may skip it — and then you MUST end with
  `TEST_FIRST: SKIPPED <reason>`.
  - PRE-COMMIT HOOKS that reject `test(failing):` commits (issue #28B). Some
    repos run the test suite in a pre-commit hook (e.g. `core.hooksPath =
    scripts/git-hooks` with a pytest step). Your `test(failing): <behavior>`
    commit's failing test will fail that hook and the commit will be rejected —
    blocking the red→green discipline above. The escape: use `git commit
    --no-verify` for the `test(failing):` commit SPECIFICALLY (not for the
    green implementation commit, which must pass the hook normally). This does
    NOT weaken verification: the runner's `ci-checks.sh` gate re-runs lint +
    tests + typecheck on the build branch and the runtime-verify gate drives the
    BUILT artifact, so the four-gate system still catches anything the local
    hook would have.
- After each step run the relevant tests and the typecheck; fix failures at the
  ROOT CAUSE — never suppress errors, never weaken assertions to go green.
- The format-and-lint hook runs on each edit; resolve anything it reports.
- Stay within accepted-ADR constraints.
- DO NOT introduce a dependency, library, or service the TDD did not sanction.
  Choosing a dependency requires the alternatives analysis that belongs in the
  design, not a snap decision at build time. If you find you need one, STOP and
  end with `BATCH_RESULT: BLOCKED new dependency needed: <name> (<why>)` so
  /tdd-author can weigh it and its alternatives and update the design.
- NEVER call `AskUserQuestion` in this build (issue #28A). The build runs
  unattended as a `claude -p` subprocess — nobody is on the other end of a
  question. The runner passes `--disallowed-tools AskUserQuestion`, so the call
  returns an "unavailable tool" error; if that restriction were somehow bypassed
  it would hang the subprocess indefinitely with no diagnostic (and trip the
  watchdogs). If you genuinely cannot proceed without human guidance, emit
  `BATCH_RESULT: BLOCKED <reason>` instead — that routes via the BLOCKERS.md
  path with a diagnostic the user will actually read.

Build-phase boundaries (these belong to OTHER gates — your job is to write code
and commit it, not to drive the running artifact):
- DO NOT spawn nested `claude` processes from inside the build (no `claude -p
  ...` from Bash, no embedded sub-claude orchestration). Driving the built
  artifact to verify its behavior is the runtime-verify gate's job, run by the
  runner in a SEPARATE process AFTER your build returns. If you spawn nested
  claude during build you are doing gate 3's work in gate 1, on the wrong
  process, with no verdict line the runner can parse.
- DO NOT use `pkill`, `killall`, or ANY pattern-based process killing
  (`pkill -f`, `pgrep | xargs kill`, etc.). A pattern broad enough to find your
  test invocations is almost certainly broad enough to match the runner's own
  `claude -p` parent — and killing your own parent ends the build with no
  `end_turn`, producing an empty log and a FAIL with no actionable diagnostic.
  If you must kill child processes you yourself spawned, track each child's PID
  from `$!` and kill ONLY those PIDs.
- DO NOT create runtime-driving fixtures in `/tmp` or anywhere outside the
  repo. The failing-test-first gate inspects commits; `ci-checks.sh` runs the
  committed test suite + typecheck + lint. Both look at what is IN the repo.
  Out-of-repo `/tmp/...` fixtures and ad-hoc scratch dirs are gate 3's surface,
  not gate 1's — and they leave debris the runner cannot clean up.

Design blockers (the feedback edge): if a requirement is infeasible,
self-contradictory, or cannot be implemented without breaking an accepted ADR,
do NOT silently work around it. Stop and end with
`BATCH_RESULT: BLOCKED <one-line reason>`. The runner logs it to
docs/tdd/BLOCKERS.md for `/tdd-author` to revise the design. Use this only for
design-level problems, not ordinary bugs you can fix.

Close:
- Run the FULL test suite, typecheck, and linter; confirm green. An INDEPENDENT
  gate will re-run these (ci-checks.sh — tests + typecheck + lint, with clippy at
  `-D warnings`), then a SEPARATE runtime-verification gate will DRIVE the
  built artifact at its observable surface (per the TDD's `## Verification
  plan`) — so make sure what you committed is RUNNABLE (entry points work,
  deps install, fixtures present), don't only run tests against it. throughline
  ships no verification harness: the runtime gate uses the project's own means
  (CLI, HTTP, library, log, DOM, …), delegating the *mechanism* to
  `superpowers:verification-before-completion` / `/verify` (FR-26 / ADR 0004).
  An isolated review in a SEPARATE process runs after that — self-attestation
  is not trusted, so actually make them pass. Resolve lint at the root cause,
  do not suppress it to get past the gate.
- Keep docs in sync IN THIS COMMIT — not a later sweep. Grep for every concept
  this feature changed (renamed types, dropped tools, swapped dependencies,
  revised flows). For each hit in a doc decide if it is now wrong and fix it:
  evergreen docs (README/ARCHITECTURE/INSTALL/CONTRIBUTING/CLAUDE/behavior spec)
  are edited in place; an `accepted` ADR or design doc whose SUBSTANCE is now
  wrong gets a superseding doc, not a rewrite. Small doc fixes ride in the
  feature commit; substantial doc work is a second commit in the same branch.
  Do not finish with known-stale docs.
- Commit with a descriptive message referencing the TDD and the PRD requirement
  numbers. Do NOT open a PR, do NOT change the TDD's `Status:`, and do NOT run
  the final review yourself — the runner owns branches, PRs, the verify + review
  gates, and the flip to `implemented` (only after both gates pass).
- AUTHOR SELF-REVIEW before BATCH_RESULT (FR-60). Ahead of your final
  `BATCH_RESULT:` line, give your OWN diff a critical pass against the same
  checklist the independent reviewer uses, and emit a `SELF_REVIEW_BEGIN ..
  SELF_REVIEW_END` block immediately before the BATCH_RESULT line:

  ```
  SELF_REVIEW_BEGIN
  checked_categories:
    - test-first-discipline
    - touched-file-scope
    - per-file-bound
    - failure-modes-coverage
    - verification-plan-coverage
    - diff-vs-tdd-claims
  findings:
    - <a FINDING_BEGIN..FINDING_END block (the review prompt's §1 shape:
       severity / structural / region / region_lines / pattern_tags / summary /
       evidence) for each issue you find in your OWN work — or none if clean>
  SELF_REVIEW_END
  ```

  If `findings` contains any halting-severity entry (`blocker`/`major`), you
  MUST address it — commit the fix — BEFORE emitting `BATCH_RESULT: OK`. Do not
  emit BATCH_RESULT with an unaddressed halting self-review finding: the runner's
  consolidated review pass detects that as a `major` `self-review-ignored`
  finding and halts the gate. An empty `findings` list (genuinely clean work) is
  a valid, expected result — do not manufacture findings to look thorough.
- End your final message with exactly `BATCH_RESULT: OK` on success,
  `BATCH_RESULT: FAIL <reason>` if you could not complete it, or
  `BATCH_RESULT: BLOCKED <reason>` for a design-level blocker.

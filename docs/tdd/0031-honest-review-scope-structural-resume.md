# TDD 0031: Honest consolidated-review scope on resume + revision-resolved structural-halt resume

Status: draft
PRD refs: FR-15, FR-39, FR-40, FR-57 (gap-closure); FR-63, FR-64, FR-67; NFR-4
PRD-rev: bfc8ad6
ADR constraints: 0004, 0005, 0006, 0007

## Approach

Two gaps observed during the recovery of run `20260601-191259` (the project's
first structural-finding halt resolved by a TDD revision — see TDD 0030's
"Build-blocker resolution" note and PR #75). Both are implementation
shortfalls against existing FRs/NFRs; neither requires PRD changes. This TDD
designs against post-[[0030]] code (the inline backstop, `_kill_pid`,
blocked-state resume, and orphan detection all exist).

The observed incident chain:

1. TDD 0030's build halted at the consolidated review gate
   (`structural-finding (b)`). The TDD was revised to resolve the halt
   (PR #73), and the run was resumed by hand-repairing the fragment.
2. On resume, the sequential driver computed the consolidated review's base as
   `git rev-parse HEAD` **at gate-entry time** — which, on a resumed branch,
   is the branch tip itself. The review gate was handed the scope
   `HEAD..HEAD`, a provably empty diff, and returned
   `REVIEW_RESULT: PASS` ("no findings of any severity") — a **vacuous pass**
   (gap A). The TDD was flipped to `implemented` and a PR opened while the
   halting finding (M1) was still unfixed in the code. NFR-4 says ambiguity
   resolves to FAIL, never a false PASS; an empty review scope at the
   consolidated gate is exactly such an ambiguity.
3. The hand-repair itself was necessary because the halt taxonomy maps
   `structural-finding` to next-actions with no resume entry — so neither
   `--check-paused` nor `_resume_from` will touch the blocked fragment, even
   after the TDD revision that resolves the halt has been merged (gap B). The
   designed remedy (revise the TDD) can *validate* the existing built work,
   not only invalidate it; forcing a from-scratch rebuild discards cleared,
   reviewed work, against FR-40's work-preservation intent.

## Components & interfaces

### 1. Honest consolidated-review base — `scripts/lib/gates.sh` + `scripts/implement.sh` (gap A)

`review_one`'s own comment states the design intent: "Consolidated/rework
review scope is `<build-start-base>..HEAD`". The bug is that what the drivers
pass as that base is `git rev-parse HEAD` at gate-entry (implement.sh lines
~390 parallel, ~473 combined, ~554 sequential), which equals the build start
only on a fresh build. On resume it equals the branch tip.

- **New helper `_review_base <fallback-ref>`** (gates.sh, next to `review_one`):
  echo `git merge-base "$fallback_ref" HEAD` when resolvable; on failure
  (no merge base — detached fixture repos, deleted refs) echo the literal
  `<fallback-ref>` unchanged and emit a one-line warning to stderr. The
  merge-base of the stacking base (`$prev` / `$BASE`) and the branch tip IS
  the build start, regardless of how many commits or integration merges the
  branch has accumulated — it is the same value `git rev-parse HEAD` produced
  at fresh-build branch creation.
- **Driver wire-in** (implement.sh, all three sites): replace
  `pre="$(git rev-parse HEAD)"` with `pre="$(_review_base "$prev")"`
  (sequential), `pre="$(_review_base "$BASE")"` (combined, parallel — their
  stacking base is `$BASE`). Fresh builds are unchanged by construction
  (branch tip == merge-base at branch creation); resumed builds get the true
  build start.
- **All `rbase` consumers receive the derived base**, not only `review_one`:
  `test_first_ok` (skipped on resume when already completed) and
  `verify_runtime_one` (uses the base as scope *orientation* for the verify
  prompt, not as a gate boundary). The merge-base is the correct value for
  both — it shows each gate the whole change from build start, which is what
  a fresh build always gave them. No per-gate base differentiation.

### 2. Empty-scope fail-closed — `scripts/lib/gates.sh` (gap A)

Defense in depth behind §1: `review_one` refuses to run a review over an
empty scope. Before rendering the prompt:

- If `git diff --quiet "$base"..HEAD` reports no difference (rc 0), do NOT
  spawn a reviewer. Append
  `THROUGHLINE_REVIEW_SCOPE_EMPTY: review base <sha> equals HEAD — nothing to
  review; failing closed (NFR-4: ambiguity is never a false PASS)` to the gate
  log and return 1 (the existing review-failure return, routed by
  `_rework_loop` / `_retry_in_gate` exactly as a BLOCK verdict with no
  parseable findings — toward halt, never toward flip).
- If the `git diff --quiet` invocation itself fails (rc > 1: bad ref, corrupt
  repo), the same fail-closed path applies with a `git-diff-failed`
  diagnostic — never proceed to a reviewer whose scope is unverifiable
  (ADR 0006: verdicts rest on verifiable artifacts).

A consolidated review gate with nothing to review is always a runner bug (a
build that committed nothing has nothing to flip); failing closed surfaces it
instead of laundering it into a PASS.

### 3. Revision-resolved structural-halt resume — `scripts/lib/state.sh` + `scripts/lib/resume.sh` + `scripts/status.sh` (gap B)

Three coordinated changes make `structural-finding` halts resumable once (and
only once) the resolving TDD revision is merged to integration:

**3a. Taxonomy** (`_next_actions_for_cause`, state.sh ~808):

- `structural-finding` next-actions become:
  `revise TDD via /tdd-author,resume after revision (re-runs the halted gate against the revised declarations),see docs/tdd/BLOCKERS.md`.
  The second entry begins with `resume`, which is the existing machine-readable
  marker both `status.sh --check-paused`'s blocked arm and `_resume_from`'s
  blocked-acceptance arm already key on — no changes needed in either to make
  the halt *visible*; the acceptance *guard* below is the new logic.
- The two refusal outcomes the guard can produce have DIFFERENT lifecycles —
  only one becomes a persisted cause value:
  - **`resume-blocked-tdd-unrevised` — driver-report-only, never persisted.**
    The refusal fires BEFORE `_accept_blocked_as_paused`, so the fragment is
    still `blocked` with `halt_cause=structural-finding` — which remains the
    accurate, FR-63-enumerated state; nothing about the fragment is rewritten.
    The string is carried solely in `RESUME_REFUSE_CAUSE` (the existing global
    the drivers read for their `refuse-to-resume: <cause>` report line). It
    joins NO enum and NO classifier: not `_next_actions_for_cause`, not
    `_is_paused_cause`, not status.sh's mirrors — there is no fragment state
    for them to classify.
  - **`resume-blocked-integration-conflict` — persisted `paused_cause`,
    written via `_update_paused_cause`** (the same call and pattern as the
    existing `resume-blocked-branch-divergence` refusal). It fires AFTER
    `_accept_blocked_as_paused` (fragment already paused/transient), so the
    fragment's paused state is accurate and only its cause is updated. It
    joins, in BOTH state.sh and status.sh's mirror copies:
    - `_next_actions_for_cause` →
      `resolve the integration merge conflict on the build branch manually,then re-run /implement with resume`
    - `_is_paused_cause` → returns 0 (recoverable pause, same disposition as
      the other `resume-blocked-*` causes)
    - status.sh `_halt_is_paused_cause` (~182-198) → same
    - status.sh `_halt_cause_known` (~194-202) → added, so the halt renderer
      emits structured output instead of its raw-render fallback warning

**3b. Halt-time revision fingerprint** (`set_halt_cause`, state.sh): the
derivation lives INSIDE `set_halt_cause` — its 4-argument signature does not
change, and no caller is touched. A new arm in its body: when `$cause` is
`structural-finding`, read the TDD path from the fragment's existing `path`
field (the same sed read the function already uses for other carried-forward
fields), derive `blob="$(git rev-parse HEAD:"$path" 2>/dev/null)"` in the
halt-time cwd (the build worktree), and write the detail field as
`"$detail tdd_rev=$blob"` — the caller's detail string with the token
appended. If the blob cannot be derived (path missing from the branch,
`$blob` empty), the detail is written verbatim with no token and the resume
guard below degrades to accept-with-warning. The fingerprint rides inside the
existing free-text detail field deliberately: it adds no fragment field, no
schema concern, and no change to `_write_tdd_fragment`'s positional signature
(see Dependencies for the rejected alternative).

**3c. Resume acceptance guard + integration merge** (`_resume_from`,
resume.sh): two insertions at precisely specified points in the existing
function body.

1. **Revision guard** — inserted in the blocked-acceptance arm (~134),
   BETWEEN the existing "actions contain a resume entry" check and
   `_accept_blocked_as_paused`. When the blocked fragment's `halt_cause` is
   `structural-finding` (parsed from the fragment, same sed pattern as the
   existing reads): parse `tdd_rev=<sha>` from `halt_cause_detail`; resolve
   the integration branch's current blob for the same TDD path:
   `git rev-parse "$INTEGRATION:<path>"` (INTEGRATION is the ref the runner
   resolved at startup; in scope per the module's shared-outer-scope
   convention, resume.sh header ~17). If both resolve and are EQUAL, the TDD
   has not been revised since the halt — resuming would re-halt identically
   (or worse, vacuously pass before §1/§2). Refuse:
   `RESUME_REFUSE_CAUSE="resume-blocked-tdd-unrevised"`, return 3, and write
   NOTHING to the fragment (it stays blocked/structural-finding — the
   accurate state; see §3a). If the recorded token is absent or either blob
   is unresolvable, log a warning and proceed (degraded acceptance — the
   bounded rework budget limits the damage of a pointless resume).
2. **Integration merge** — inserted at the END of `_resume_from`'s validation
   sequence: after `_accept_blocked_as_paused`, after the existing null-head
   derivation block (~181-200), and after the existing divergence guard
   (~215-245), immediately before the done-list export. This ordering is
   load-bearing: the divergence guard must compare against the halt-time
   head BEFORE the merge moves it. The step runs only when this resume came
   through the structural-finding acceptance (a local flag set in step 1's
   arm): run `git merge --no-edit "$INTEGRATION"` in the worktree so the
   resumed gates (review prompt, rework pre-pass declarations, build prompt
   on any later step) read the REVISED TDD, not the branch's stale copy.
   - On conflict: `git merge --abort`, set
     `RESUME_REFUSE_CAUSE="resume-blocked-integration-conflict"`, persist it
     via `_update_paused_cause` (the fragment is already paused/transient —
     accurate; only its cause is updated, exactly the
     `resume-blocked-branch-divergence` pattern), return 3.
   - On success: advance `branch_head_at_pause` to the post-merge head via
     the existing `_update_branch_head_at_pause` (the same call the 0027
     fast-forward acceptance uses), so the divergence record stays truthful.

A merge performed outside the runner (the manual recipe this TDD obsoletes)
is still accepted by the 0027 ancestor check — both paths stay valid.

### 4. Skill documentation — `skills/implement/SKILL.md`

The "Detect interrupted run" step's `resumable=blocked` parsing gains the
structural-finding case: the resume option's label for a structural-finding
halt reads "Resume <slug> (structural halt; requires the resolving TDD
revision to be merged first)" so the user is told the precondition at
decision time. The two new refusal causes are listed alongside the existing
`resume-blocked-*` causes with their one-line meanings.

## Data & state

- No new fragment fields, no schema bump. The revision fingerprint rides in
  `halt_cause_detail` (free text, already persisted); the two new refusal
  causes are new values of the existing `paused_cause` field (additive enum
  growth, schema 1 per TDD 0011's policy).
- `_review_base` is a pure derivation (no persistence).

## Sequencing / implementation plan

1. **`_review_base` helper + empty-scope fail-closed + driver wire-in**
   (gates.sh §1, §2; implement.sh three `pre=` sites) — gap A complete.
2. **Taxonomy + fingerprint**: structural-finding resume action, the two new
   refusal causes (state.sh + status.sh mirror), `tdd_rev=` recording in
   `set_halt_cause` (state.sh) — gap B detection surface.
3. **Structural resume acceptance**: revision guard + integration merge +
   head advance in `_resume_from` (resume.sh) — gap B acceptance.
4. **Skill docs + aggregator wire-in** (skills/implement/SKILL.md,
   tests/implement-gate.test.sh).

## Failure modes & edge cases

- **Merge-base unresolvable in §1** (fixture repos, deleted stacking base):
  `_review_base` falls back to the passed ref with a warning — the pre-0031
  behavior, never worse.
- **Review scope legitimately empty at a fresh build** (a build that committed
  nothing): §2 fails closed. Correct — `BATCH_RESULT: OK` with zero commits is
  a build failure that the flip must never launder.
- **Fragment's halt_cause_detail has no `tdd_rev=` token** (halt recorded by a
  pre-0031 runner, or blob derivation failed at halt time): the §3c guard
  degrades to accept-with-warning. A pointless resume re-halts within one
  bounded review cycle; nothing is lost.
- **TDD revised but the revision does NOT change the failing declaration**
  (e.g. only prose edits): the guard accepts (blobs differ), the resumed
  review/rework re-runs and re-halts with the same structural finding. The
  loop is bounded: `rework_attempts` are per-fragment and persist across
  resumes, so a second identical halt consumes the remaining FR-65 budget and
  escalates to `rework-budget-exhausted` — which is a non-resumable blocked
  state whose next-actions name a fresh `/implement` after revision. At that
  point the recovery path is the by-the-book rebuild; the resume channel is
  deliberately exhausted.
- **Integration merge conflicts** (§3c): merge aborted, worktree left clean,
  refusal cause names the manual action. The fragment stays paused/transient
  (accurate: the work is resumable once the human resolves the conflict).
- **`structural-finding` halt on a combined-mode branch shared by several
  TDDs**: the merge brings integration into the shared branch once; subsequent
  TDDs' resumes see the merge already present (merge is a no-op). Safe.
- **Parallel mode**: `feat/<slug>` branches get the same acceptance path; the
  merge target is the same integration ref. No mode-specific logic.

## Verification plan

**Observable surface:** the rendered review prompt (its `git diff <base>..`
line), `review_one`'s return code and gate-log lines, `status.sh
--check-paused` stdout, `_resume_from`'s return code + `RESUME_REFUSE_CAUSE`,
the worktree's TDD file content and branch head after an accepted resume, and
fragment fields.

**Observation points:**

1. **Review base is the build start, not gate-entry HEAD (gap A).** Fixture: a
   repo with an integration branch, a build branch with 3 commits, cwd on the
   build branch. Call `_review_base <integration>`. Expect: output equals
   `git merge-base <integration> HEAD`, NOT `git rev-parse HEAD`. Negative
   (fresh-build equivalence): on a branch with zero commits past the fork
   point, output equals HEAD (identical values — no behavior change).
2. **Driver passes the derived base on resume.** Fixture: sequential-driver
   resume context (RESUME=1) over the same repo. Expect: the `pre` handed to
   `gate_one` equals the merge-base, and the rendered review prompt contains
   `git diff <merge-base-sha>..` rather than `git diff <branch-tip-sha>..`.
3. **Empty scope fails closed (gap A).** Call `review_one` with base == HEAD.
   Expect: return code non-zero; gate log contains
   `THROUGHLINE_REVIEW_SCOPE_EMPTY`; no `THROUGHLINE_SESSION:` line appears in
   the gate log after the `THROUGHLINE_REVIEW_SCOPE_EMPTY:` line (the precise
   observable for "no reviewer process was spawned"); the result routes to the
   halt path, not to a flip.
4. **Structural halt records the revision fingerprint (gap B).** Drive
   `set_halt_cause <slug> structural-finding review:1 "(b)"` in a worktree
   whose branch has the TDD committed. Expect: the fragment's
   `halt_cause_detail` ends with ` tdd_rev=<blob>` where `<blob>` equals
   `git rev-parse HEAD:<tdd-path>`.
5. **Structural halt surfaces as resumable (gap B).** Fixture: a blocked
   fragment with `halt_cause=structural-finding` and the new next-actions.
   Run `status.sh --check-paused`. Expect: one line ending
   `resumable=blocked` with `cause=structural-finding`.
6. **Resume refused while the TDD is unrevised.** Fixture: blocked fragment
   with `tdd_rev=<blob>` matching integration's current blob for the path.
   Run `_resume_from`. Expect: return 3,
   `RESUME_REFUSE_CAUSE=resume-blocked-tdd-unrevised`, fragment NOT flipped to
   paused, AND the fragment's `halt_cause`/`halt_cause_detail`/`paused_cause`
   fields are byte-identical to before the call (the refusal persists
   nothing).
7. **Resume accepted after revision + integration merged.** Fixture: same, but
   integration's TDD blob differs from the recorded `tdd_rev`. Expect: return
   0; fragment paused/transient; the worktree's TDD file content equals
   integration's version (the merge happened); `branch_head_at_pause` equals
   the post-merge branch head.
8. **Merge conflict refuses cleanly.** Fixture: integration and the build
   branch carry conflicting edits to the same file. Expect: return 3,
   `RESUME_REFUSE_CAUSE=resume-blocked-integration-conflict`, the fragment's
   `paused_cause` field equals `resume-blocked-integration-conflict`
   (persisted via `_update_paused_cause`), `git status` in the worktree shows
   no in-progress merge (aborted), no conflict markers on disk.
9. **The two refusal outcomes render correctly in status.sh.** Fixture A: the
   point-8 fragment → `status.sh` renders the conflict cause with its
   next-action text (no raw-render fallback warning — `_halt_cause_known`
   covers it). Fixture B: the point-6 fragment → `status.sh` renders the
   unchanged `structural-finding` halt exactly as before the refused resume.

**Expected observations (PASS):** every numbered point yields the cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-15 (review gate is a genuine independent review) + NFR-4 (ambiguity resolves to FAIL, never a false PASS) | §1 honest base derivation + §2 empty-scope fail-closed: the consolidated review can no longer pass on an empty diff. Verification §1–§3. |
| FR-57 (scoped review — no re-evaluation of cleared code) | §1 restores the documented consolidated-review scope (`<build-start-base>..HEAD`); the per-step scoping of TDD 0020 is untouched. Verification §2. |
| FR-39 (interrupted runs surfaced; user decides) | §3a taxonomy: structural-finding halts now appear in `--check-paused` with a resume option instead of being invisible to it. Verification §5. |
| FR-40 (gate-level resume; completed gates not re-run; work preserved) | §3c acceptance: cleared steps and completed gates on the blocked fragment survive the resume verbatim; only the halted gate re-runs — against the revised declarations. Verification §6, §7. |
| FR-63 (every halt cites an enumerated human-needed cause) | §3a: every PERSISTED state stays inside the closed enum — `resume-blocked-integration-conflict` joins it with deterministic next-actions; `resume-blocked-tdd-unrevised` persists nothing (the fragment keeps its enumerated `structural-finding` halt), so no ad-hoc state is ever written. Verification §6, §8, §9. |
| FR-64 (one-screen halt context with next actions) | §3a next-action text names the precondition (revise first) and the manual step (resolve conflict) respectively; §4 documents them in the skill. Verification §5. |
| FR-67 (structural findings escalate to BLOCKED + BLOCKERS.md, never a local sweep) | Unchanged and reaffirmed: the halt still BLOCKs and still writes the BLOCKERS entry. What §3 adds is strictly the *post-revision* recovery path; no rework is attempted on an unrevised design (the §3c guard enforces this mechanically). Verification §4, §6. |

No gaps.

## Dependencies considered

No new external dependencies. `git merge-base`, `git diff --quiet`,
`git rev-parse <ref>:<path>`, and `git merge --no-edit/--abort` are core git,
already used throughout the runner.

Alternatives considered:
- **Fix the review base inside `gate_one` instead of the drivers** — rejected:
  `rbase` also feeds `test_first_ok` and the runtime-verify gate; deriving it
  once at the driver keeps all consumers consistent and keeps `gate_one`'s
  signature/meaning unchanged.
- **Scope the resumed consolidated review to `last_cleared_review_sha..HEAD`**
  (only what per-step reviews never cleared) — rejected: the consolidated
  review's job (per TDD 0020/0024 and `review_one`'s own contract) is the
  whole change as one unit; it is the pass that catches cross-step issues
  (0030's M1 was found in per-step-cleared code). Narrowing it on resume
  would make resumed builds *less* reviewed than fresh ones.
- **A new fragment field for the revision fingerprint** (instead of a
  `tdd_rev=` token in `halt_cause_detail`) — rejected: `_write_tdd_fragment`
  takes ~24 positional arguments; adding one touches every call site and the
  compact-JSON writer for a value only one halt cause needs. The detail field
  is free-text diagnostic context; a parseable-but-optional token there is
  contained and degrades gracefully.
- **Auto-rebasing the build branch onto integration instead of merging** —
  rejected: a rebase rewrites the branch's commits, which the divergence
  guard (FR-41) is explicitly designed to refuse; it would also invalidate
  the recorded `cleared_step_log` SHAs. Merge preserves history and SHAs.
- **Having gates read the TDD from integration instead of the worktree**
  (avoiding the merge entirely) — rejected: the build branch must stay
  self-consistent (its committed TDD is what its code was built against);
  splitting "which TDD copy governs" across gates reintroduces exactly the
  ambiguity ADR 0006 exists to prevent.

## PRD conflicts surfaced (and resolution)

None requiring PRD changes. One pre-existing tension documented: FR-57's
acceptance ("no finding against code a prior pass already approved") is in
tension with the consolidated review's whole-branch scope (established by TDD
0020/0024, reaffirmed here) — 0030's M1 was raised against per-step-cleared
code, and that catch was correct and valuable. This TDD does not change that
behavior; it only fixes the resume case where the consolidated scope
collapsed to empty. If the tension needs resolving, it is a future PRD
clarification (consolidated pass exempt from FR-57), not a code change.

## Decisions to promote (ADR candidates)

None. Both fixes apply existing ADR dispositions (0006 verdict grounding,
0007 bounded rework/halt model) to paths those ADRs already govern. The
"resume requires the resolving revision to be merged first" rule is a natural
consequence of ADR 0005 (the design gate is the sole scope authority) rather
than a new cross-cutting decision.

## Touched files

- `scripts/lib/gates.sh` — `_review_base` helper (§1); empty-scope fail-closed in `review_one` (§2).
- `scripts/implement.sh` — three driver `pre=` sites call `_review_base` (§1).
- `scripts/lib/state.sh` — taxonomy: structural-finding resume action + two new refusal causes; `tdd_rev=` fingerprint in `set_halt_cause` (§3a, §3b).
- `scripts/status.sh` — mirror the two new refusal causes in its paused-cause classifier (§3a).
- `scripts/lib/resume.sh` — structural-resume acceptance: revision guard + integration merge + head advance (§3c).
- `skills/implement/SKILL.md` — document the structural-resume option and the two new refusal causes (§4).
- `tests/honest-review-scope-structural-resume.test.sh` — new eval covering verification §1–§9.
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.

Total: 8 files touched.

## Expected diff size

Estimates carry the 0030 lesson (build actuals ran well above the original
estimates): each is the implementation estimate plus headroom, so the FR-67(b)
cumulative check measures against realistic declarations.

- `scripts/lib/gates.sh` — ~40 lines (`_review_base` ~15; empty-scope guard ~20).
- `scripts/implement.sh` — ~15 lines (three one-line site changes + comments).
- `scripts/lib/state.sh` — ~35 lines (taxonomy entries ~12; fingerprint recording ~20).
- `scripts/status.sh` — ~10 lines (two causes in the mirror classifier).
- `scripts/lib/resume.sh` — ~75 lines (guard ~30; merge + abort + head advance ~40).
- `skills/implement/SKILL.md` — ~15 lines.
- `tests/honest-review-scope-structural-resume.test.sh` — ~420 lines (exception: one comprehensive eval covering 9 verification points with shared repo/worktree fixtures; splitting would duplicate the fixture scaffolding every point reuses).
- `tests/implement-gate.test.sh` — ~6 lines (aggregator wire-in).

Total expected diff: ~616 lines across 8 files. One exception declared inline
(the eval file).

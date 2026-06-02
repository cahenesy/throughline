# TDD 0033: Integration merge on all resume paths — stale-base resumes inherit current integration

Status: draft
PRD refs: FR-40, FR-41, FR-39, FR-15, FR-64, NFR-4
PRD-rev: bfc8ad6
ADR constraints: 0005, 0006, 0007

## Approach

Run 20260601-115311 (TDD 0021's build) exposed a resume-path gap, recorded in
`docs/tdd/BLOCKERS.md` as **stale-base-resume**: a run paused on June 1 was
resumed on June 2 after a separate run had merged TDDs 0027/0030/0031 to
master. The resumed gates re-entered on the branch's June-1 base, so:

- **ci-checks failed on an inherited red** — a test that was broken at the
  branch's merge-base and fixed on master afterward. The gate cannot
  distinguish "the base was already red" from "the build broke it"; the TDD
  was marked FAIL for work it didn't do.
- **Merge conflicts accumulated invisibly** — both the branch and master had
  modified `gates.sh`/`state.sh`; nothing surfaced this until a human inspected
  the eventual PR.
- **Cross-TDD semantic conflicts hid** — test stubs written against the old
  contracts (pre-0021 review-disposition rules, pre-0031 empty-scope rules)
  broke only when the two change sets finally met, with nobody attributable.

The mechanism to fix this already exists: TDD 0031 §3c merges integration into
the build branch on resume — fetch-less, and **only for structural-finding
halts**. This TDD broadens that merge to **every accepted resume** (transient,
orphaned/unclean-exit, recoverable-blocked, structural) and adds a
fetch-with-fallback so the merge is against the remote's current state. The
conflict-refusal contract (`resume-blocked-integration-conflict`, abort, human
resolves) is unchanged and now protects every path.

Effects, by failure class above:
- Inherited reds disappear: resumed gates always run against current
  integration — what ci-checks verifies is what the PR will merge into.
- Textual conflicts surface at **resume time** as an explicit, named refusal
  (FR-64), not at PR time as a surprise.
- Semantic conflicts fail gates **attributably** on the merged state, where the
  bounded rework loop (ADR 0007) can fix them — exactly what a human did
  manually for run 20260601-115311 (commit 5365d7e).

Follows the standalone gap-fix precedent (TDDs 0027, 0030, 0031, 0032): TDD
0031's body stays authoritative for the merge mechanism and the
structural-finding precondition; this TDD owns only the broadened trigger and
the fetch step.

## Components & interfaces

### 1. `_fetch_integration` — new helper in `scripts/lib/resume.sh`

```bash
_fetch_integration() {  # <integration-ref>  -> rc 0 always (fetch is best-effort)
  # "origin/master" → `git fetch origin master`; a ref with no remote prefix
  # (the current-branch fallback from implement.sh's INTEGRATION detection)
  # has nothing to fetch — return 0 silently.
  # On fetch failure (offline, no remote): warn to stderr and return 0 — the
  # merge below proceeds against the local ref (degraded, never worse than the
  # pre-0033 behavior).
}
```

Parsing rule: a ref containing exactly one `/` whose prefix names a configured
remote (`git remote | grep -qxF "<prefix>"`) is split into `<remote> <branch>`
and fetched; anything else (local branch name, detached SHA) is a no-fetch
no-op. The same rule applies unchanged to a `THROUGHLINE_INTEGRATION_BRANCH`
override value: a multi-slash or non-remote-tracking value either fails the
remote-prefix test (no fetch) or attempts a fetch that fails — both degrade to
the warn-and-proceed path, never worse than pre-0033 behavior. The warning text
on failure:
`warning: _fetch_integration: could not fetch <remote> <branch>; merging against the local ref (may be stale)`.

### 2. Broadened merge trigger — `_resume_from` in `scripts/lib/resume.sh`

Current (TDD 0031 §3c):

```bash
if [ "$_resumed_structural" -eq 1 ]; then
  if git merge --no-edit "$INTEGRATION" >/dev/null 2>&1; then
    … advance branch_head_at_pause …
  else
    git merge --abort …
    RESUME_REFUSE_CAUSE="resume-blocked-integration-conflict"
    … return 3
  fi
fi
```

New: the `_resumed_structural` gate is **removed from the merge block** (the
flag itself stays — it still gates the structural-only `tdd-unrevised`
precondition check earlier in the function). The block becomes unconditional
for every resume that reaches it (i.e. has passed the fragment-exists,
status, and divergence-guard checks), preceded by the fetch:

```bash
_fetch_integration "$INTEGRATION"
local _pre_merge_head; _pre_merge_head="$(git rev-parse --verify HEAD 2>/dev/null || true)"
if git merge --no-edit "$INTEGRATION" >/dev/null 2>&1; then
  … existing advance of branch_head_at_pause (unchanged) …
  # New: one observable line distinguishing a real merge from a no-op
  # ("Already up to date" also exits 0 but moves nothing).
  if [ "$(git rev-parse --verify HEAD 2>/dev/null)" != "$_pre_merge_head" ]; then
    echo "resume: merged $INTEGRATION into $branch (head $_pre_merge_head -> $(git rev-parse --short HEAD))" >&2
  else
    echo "resume: integration $INTEGRATION already merged into $branch (no-op)" >&2
  fi
else
  … existing abort + resume-blocked-integration-conflict + return 3 (unchanged) …
fi
```

Placement is unchanged: AFTER the divergence guard (which must compare against
the halt-time head before the merge moves it — TDD 0031's ordering rationale),
BEFORE the done-list export.

### 3. Mid-build resumes — no special casing

When `gates_completed` lacks `build`, the resume re-enters the build gate: the
coprocess spawns on the now-merged branch. No code change beyond §2 is needed:

- The build prompt's RESUME SIGNAL (`{{CLEARED_STEPS}}`) is SHA-independent
  (integer step ids), so cleared steps stay cleared.
- The build prompt's existing instruction — "extend or repair on top — do NOT
  rewrite history" — covers a branch that gained a merge commit.
- The divergence guard accepted the pre-merge head (ancestor check); the merge
  commit lands after the guard, and `branch_head_at_pause` is advanced to the
  post-merge head (§2), so the NEXT pause/resume cycle's guard is also
  consistent.

### 4. Consolidated-review scope after the merge — already correct, pinned by test

TDD 0031's `_review_base` computes `git merge-base <fallback-ref> HEAD`. In the
**non-stacked** modes (parallel/combined, and the first TDD of a sequential
run), the fallback ref passed by the drivers equals the integration ref — so
after this TDD's merge, integration is an ancestor of HEAD and the merge-base
IS the integration head → the consolidated review's scope is exactly "the
build's own work, including any conflict resolutions made in the merge commit,
as it applies on top of current integration". That is the honest scope (ADR
0006). In **stacked sequential** mode, `_review_base` is called with the
previous TDD's branch (`$prev`) and the stacking semantics are unaffected by
the integration merge. No code change; Verification §7 pins the non-stacked
case so a future `_review_base` change cannot silently regress it.

### 5. Documentation — `skills/implement/SKILL.md`

The "Detect interrupted run" section's resume documentation changes:
- The structural-finding option text keeps its precondition (revision must be
  merged) — unchanged.
- The general Resume option text gains one sentence: resuming merges the
  current integration branch into the build branch first (fetching origin when
  possible); a conflict refuses the resume with
  `resume-blocked-integration-conflict` for manual resolution.

## Data & state

- **No fragment-schema change.** `branch_head_at_pause` advancement and
  `paused_cause` mutation on conflict are TDD 0031's existing writes, reused.
- **New stderr/report line** (observable, grep-able): `resume: merged <integration> into <branch> …`.
- **Existing refusal cause reused**: `resume-blocked-integration-conflict` — same
  semantics, now reachable from every resume path. `status.sh` already renders
  it (TDD 0031); no display change.

## Sequencing / implementation plan

1. **`_fetch_integration` helper** in `scripts/lib/resume.sh` + its unit-style
   tests: remote-prefixed ref → fetch invoked (observed via a stub `git` PATH
   shim); local ref → no fetch; fetch failure → warning + rc 0.
2. **Broaden the merge block** in `_resume_from` (remove the
   `_resumed_structural` gate from the merge, add the `_fetch_integration` call
   and the observable merge line) + tests for: transient resume merges,
   orphaned resume merges, conflict → refusal, no-op when integration
   unchanged, `branch_head_at_pause` advanced, structural path regression
   (tdd-unrevised refusal still fires before any merge).
3. **Mid-build resume test**: a fragment whose `gates_completed` is empty →
   resume → the branch contains the integration merge commit BEFORE the build
   gate re-enters (observed via the stub build recording the branch state it
   sees).
4. **Review-scope pin** (§4): after a resume-merge, `_review_base` returns the
   integration head (test asserts equality), so the consolidated review scope
   is the build's own work only.
5. **`skills/implement/SKILL.md` text** (§5) + aggregator wiring of the new
   eval into `tests/implement-gate.test.sh`; full-suite run.

## Failure modes & edge cases

- **Fetch fails (offline, remote gone).** `_fetch_integration` warns and
  returns 0; the merge proceeds against the local ref. Degraded freshness,
  never a refusal — identical to pre-0033 behavior plus a warning.
- **Integration ref is the current branch / a local name** (implement.sh's
  last-resort fallback). Nothing to fetch; the merge is a no-op ("Already up to
  date"). Covered by Verification §3.
- **Merge conflicts.** Existing 0031 contract: abort, persist
  `resume-blocked-integration-conflict`, refuse rc 3. The fragment stays
  paused; the human resolves the conflict manually (merging integration into
  the branch themselves) and re-runs `--resume` — which then sees a clean
  "already up to date" merge and proceeds. Verification §2.
- **The merge brings in changes that break the build's tests (semantic
  conflict).** This is the desired surfacing: ci-checks fails on the MERGED
  state, the failure is attributable to the integration of the two change
  sets, and the bounded rework loop (FR-61/62) attempts the fix. If rework
  exhausts, the existing `rework-budget-exhausted` escalation applies. No new
  handling — the point of the merge is that this failure becomes visible and
  actionable instead of masked.
- **Divergence guard vs. merge ordering.** Unchanged from 0031: guard first
  (against the halt-time head), merge second, advancement third. A rewrite
  (non-ancestor head) still refuses before any merge runs.
- **Repeated pause/resume cycles.** Each resume merges whatever integration
  has gained since the last one; an unchanged integration is a no-op merge.
  `branch_head_at_pause` advances monotonically; no accumulation issue.
- **Structural-finding resumes.** Path unchanged end-to-end: the
  `tdd-unrevised` precondition check still runs first (gated on
  `_resumed_structural`), and its merge now happens in the shared block. A
  structural resume whose revision is unmerged still refuses with
  `resume-blocked-tdd-unrevised` before any merge.
- **Combined-mode shared branch.** As in 0031: a merge already present is a
  git no-op. Multiple TDD fragments resuming on one branch each attempt the
  merge; the first does the work, the rest no-op. Each also calls
  `_fetch_integration` — repeated (or, in parallel mode, concurrent) fetches of
  the same remote ref are harmless; git serializes ref updates.

## Verification plan

Observable surfaces: the build branch's git history (merge commit presence /
absence); the resume's stderr + the fragment's `paused_cause` /
`branch_head_at_pause` fields; `_review_base` stdout.

Observation points (driven by `tests/integration-merge-on-resume.test.sh` with
fixture repos + a stub-`git`-fetch PATH shim, following the fixture pattern of
`tests/honest-review-scope-structural-resume.test.sh`):

1. **Transient resume merges integration.** Fixture: a paused/transient
   fragment, a build branch, and an integration branch that gained a commit
   after the branch forked → `--resume` flow runs `_resume_from` → the branch
   HEAD is a merge commit whose parents are the old branch head and the
   integration head; `branch_head_at_pause` equals the new HEAD.
2. **Conflict refuses with the existing cause.** Fixture: integration and the
   branch both modify the same line of the same file → `_resume_from` returns
   3, `RESUME_REFUSE_CAUSE=resume-blocked-integration-conflict`, the fragment's
   `paused_cause` is updated, and the branch has no merge commit and no
   conflict markers (abort completed).
3. **No-op when integration has not advanced.** Fixture: integration is an
   ancestor of the branch → resume proceeds, no new commit on the branch, rc 0.
4. **Orphaned resume merges.** Same as §1 but the fragment starts
   `status=building` with a dead runner pid (the TDD 0030 orphan shape) →
   accepted resume produces the merge commit.
5. **Mid-build resume merges before the build gate.** Fragment with empty
   `gates_completed` → resume → the stub build invoked by the build gate
   observes a branch that already contains integration's commit.
6. **Fetch behavior.** (a) Integration `origin/master` + a PATH-shimmed `git`
   that records `fetch origin master` was called before `merge`; (b) fetch
   shim exits 1 → the warning line appears on stderr AND the merge still runs;
   (c) integration is a local branch name → no fetch call recorded.
7. **Review scope after merge.** After §1's merge, `_review_base origin/master`
   (or the fixture's integration ref) echoes the integration head SHA.
8. **Structural regression.** A blocked/structural-finding fragment whose
   integration TDD copy is byte-identical to the halt-time fingerprint →
   `--resume` still refuses with `resume-blocked-tdd-unrevised` and the branch
   gains no merge commit.

## Requirement traceability

| Requirement | Design element |
|---|---|
| FR-40 (gate-level resume continues the interrupted run) | §2 — resume still re-enters exactly the gates not in `gates_completed`, now against current integration; the done-list mechanism is untouched |
| FR-39 (interrupted-run detection / resume offer) | Unchanged detection; §5 documents the merge as part of what "Resume" means |
| FR-41 (recoverable vs fatal classification) | §2 — a merge conflict is a persisted, human-routed `resume-blocked-integration-conflict` (recoverable, paused), never a FAIL or a silent proceed |
| FR-15 (ci-checks gate runs the project's tests) | §2/§3 — the gate now runs against the state the PR will actually merge into, so its verdict is about the build's work, not the base's history |
| FR-64 (one-screen halt context naming the next action) | §2 — the conflict refusal names the cause; `status.sh`'s existing rendering of `resume-blocked-integration-conflict` (TDD 0031) covers display |
| NFR-4 (verdict honesty) | §Approach — an inherited base red can no longer be reported as the build's failure; a conflict can no longer hide until PR time |

Gaps: none identified. FR-42's transient retry budget is untouched (the merge
happens once per resume acceptance, outside any gate's retry loop).

## Dependencies considered

No new external dependencies. Internal alternatives evaluated:

- **ci-checks baseline comparison** (run the suite at the merge-base too and
  diff the failure sets, instead of merging) — rejected: roughly doubles
  ci-checks wall-clock per resume, only masks inherited reds (does nothing for
  the conflict-accumulation half of the blocker), and adds a second
  truth-source for "what failed" that NFR-4 would then need to reconcile.
- **Rebase the branch onto integration instead of merging** — rejected: rewrites
  the build's commits, which breaks the divergence guard's ancestor check
  (TDD 0027 §3b), invalidates `cleared_step_log`'s recorded SHAs, and
  contradicts the build prompt's "do NOT rewrite history" contract. TDD 0031
  already chose merge for the structural path for the same reasons.
- **Merge at PR-open time instead of resume time** — rejected: the gates would
  still verify the stale base (the original bug), and a conflict at PR-open
  has no paused state to refuse into — it would need a new halt taxonomy
  entry, vs. zero new causes for resume-time merging.

## PRD conflicts surfaced (and resolution)

- **Resolves BLOCKERS.md `stale-base-resume`** (filed 2026-06-02, run
  20260601-115311 / TDD 0021). The entry's "design wanted" named two options —
  extend the integration merge to all resume paths, or add a staleness check
  that defers to a human. This design takes the first (with fetch), because the
  second leaves the gates running on a base the human then has to merge
  manually anyway (which is exactly the manual remediation the blocker
  documents). The BLOCKERS.md entry is checked off in this design PR.
- **No PRD edit required.** FR-40's "continues the interrupted run" is read as
  "continues the work", not "preserves the stale base byte-for-byte" — the
  per-step review record, branch commits, and gate completions all carry
  forward; only the integration baseline is refreshed.

## Decisions to promote (ADR candidates)

None recommended. The decision "build branches re-integrate against current
integration at every re-entry point" is an extension of TDD 0031's existing
choice, not a new cross-cutting principle; promoting it would duplicate what
0031 + this TDD already record. Revisit only if a third re-entry point (beyond
structural and general resume) appears.

## Touched files

- `scripts/lib/resume.sh` — `_fetch_integration` helper + broadened merge block (§1, §2)
- `skills/implement/SKILL.md` — resume documentation update (§5)
- `tests/integration-merge-on-resume.test.sh` — new eval (§Verification 1–8)
- `tests/implement-gate.test.sh` — aggregator wiring (§5)

## Expected diff size

- `scripts/lib/resume.sh` — 50 lines
- `skills/implement/SKILL.md` — 10 lines
- `tests/integration-merge-on-resume.test.sh` — 260 lines
- `tests/implement-gate.test.sh` — 14 lines

Total expected diff: 334 lines across 4 files.

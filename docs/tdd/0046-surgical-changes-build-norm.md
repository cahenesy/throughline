# TDD 0046: Surgical-changes build norm
Status: draft
PRD refs: FR-66, FR-74
PRD-rev: 0aa1e28
ADR constraints: 0005, 0007, 0008

## Approach
FR-66 bounds rework scope mechanically (per-attempt cap, touched-file set); FR-74
is the build's defensive-norms set. Neither states the *positive* discipline that
keeps a diff minimal: every changed line should trace to the requirement being
built, and the build should not "improve" adjacent code it happened to read. The
gap matters most on the rework path, where ADR 0008 now runs rework on the Opus
build model — more capable, but also more prone to opportunistic refactoring
("wander") that the FR-66 cap bounds in size but does not discourage in intent.

Add a **surgical-changes norm** to the build prompt and echo it on the rework
path. The norm is scoped with an explicit carve-out so it does NOT contradict the
build's already-mandated duties: updating stale docs in the same commit, the
failing-test-first commit, and governance/ADR updates are REQUIRED changes, not
"adjacent improvements". The norm is prompt guidance (ADR 0005: enforcement stays
the FR-66 mechanical cap + the review gate; this adds intent, not a new gate).

## Components & interfaces
- **`scripts/build-prompt.md`** — a new bullet in the "Build discipline" list,
  placed next to the "Keep docs in sync IN THIS COMMIT" bullet so the carve-out
  is read together with the duty it exempts:
  > **Surgical changes.** Every line you change must trace to the requirement
  > you are building. Do not improve, reformat, or refactor adjacent code you
  > only read; match the existing style rather than imposing yours; remove only
  > orphans YOUR change created. Prefer the minimum code that satisfies the
  > requirement — add nothing speculative ("might need it later"). CARVE-OUT:
  > the changes this build is REQUIRED to make are in-scope and never "adjacent"
  > — the failing-test-first commit, same-commit stale-doc updates, and
  > superseding an accepted ADR/design doc the change invalidates. A required
  > change is surgical when it is the minimum that keeps the repo correct, not
  > when it is zero.
- **`scripts/rework-prompt.md`** — echo a one-paragraph form of the norm on the
  rework path, framed for the rework's single-finding scope: the rework fixes
  ONLY the cited finding; it does not touch code outside the finding region
  except where the fix mechanically requires it, and it makes no adjacent
  improvement. This reinforces, in the prompt, the wander bound ADR 0008 relies
  on the FR-66 cap to enforce mechanically.

No interface, sentinel, or verdict change — both files are prompt templates the
runner renders unchanged.

## Data & state
None. Prompt-only change plus a render/grep test.

## Sequencing / implementation plan
1. Add the surgical-changes bullet (with the carve-out) to `build-prompt.md`.
2. Add the rework-path echo paragraph to `rework-prompt.md`.
3. Add `tests/surgical-norm.test.sh` asserting both prompts carry the norm AND
   that the carve-out text is present in `build-prompt.md` (so a future edit
   can't drop the carve-out and reintroduce the doc-update contradiction);
   register it in `tests/implement-gate.test.sh`.

## Failure modes & edge cases
Real risks:
- **Norm read as "change as little as possible, even skip required updates".**
  Mitigated by the explicit carve-out naming the three required change classes;
  the test asserts the carve-out is present so it cannot silently rot.
- **Tension with FR-74 defensive norms** (which sometimes ADD guard code). A
  defensive guard the requirement needs IS traceable to the requirement, so it
  is in-scope under "minimum code that satisfies the requirement"; the norm
  forbids speculative additions, not required robustness.

Overblown risks:
- **The norm meaningfully slowing builds.** It is one prompt bullet; no process
  or gate is added.

Unspoken risks (elephants):
- **Two prompts drifting** (build vs rework wording diverging over time). The
  test asserts the norm token appears in BOTH files, surfacing a future
  one-sided edit.

## Verification plan
- **Observable surface:** the rendered build prompt and the rendered rework
  prompt (the text each `claude -p` receives).
- **Observation point(s):** render `build-prompt.md` via the runner's render
  path and `rework-prompt.md` via `_rework_one`'s template load (sourced in the
  test the same way `tests/implement-gate.test.sh` sources the libs), then
  `grep` each output.
- **Expected observations (PASS):** the build prompt contains the
  surgical-changes norm AND its carve-out clause (the three required-change
  classes named); the rework prompt contains the single-finding-scope echo. A
  control assertion confirms the existing "Keep docs in sync IN THIS COMMIT"
  bullet is still present (the norm did not displace the mandated duty).

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | every in-scope FR/NFR maps to a concrete named design element (sentinel/block/function/report section); gaps called out | all mapped, some terse | an FR untraced or hand-waved |
| Interface concreteness | exact marker/sentinel names, file paths, block format, status-enum values specified | mostly concrete, minor gaps | "emit a coverage block" with no format |
| Anti-false-green rigor | the pinned/proposed/justified-no-surface/unverified-gap distinction has a falsifiable mechanism (pinned requires a cited asserting test) | mechanism present | left to model discretion, no citation rule |
| No-conflict reconciliation | each new norm/lens explicitly reconciles with mandated duties (same-commit stale-doc update; ADR 0005/0006/0008) | reconciled | contradicts an existing instruction |
| Verification-plan actionability | observable surface + observation point + expected observation named (or justified SKIP) | present, somewhat generic | non-actionable — a vague verb instead of a named surface/observation |
| Scope-bound adherence | within body/diff/touched bounds or inline exceptions; estimates padded per the underestimation lesson | within bounds | blows a bound silently |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-66 (rework scope discipline) | rework-prompt echo reinforcing single-finding scope; complements the mechanical cap |
| FR-74 (build defensive norms) | new surgical-changes bullet in `build-prompt.md`'s discipline list, with the carve-out reconciling it against required robustness |
| ADR 0008 (Opus-rework wander risk) | the rework-path echo discourages opportunistic refactoring the FR-66 cap bounds only in size |
| ADR 0005 (no new gate) | prompt guidance only; enforcement stays the FR-66 cap + review gate |

## Dependencies considered
No new dependency — prompt text plus a grep-based render test. Considered
encoding the norm as a mechanical diff-size penalty (rejected: FR-66 already caps
diff size mechanically; the gap is *intent*, which is prompt guidance, not a
second size check — adding one would duplicate FR-66 and risk conflict with the
mandated doc-update duty).

## PRD conflicts surfaced (and resolution)
None. Strengthens FR-66/FR-74 build behavior without changing the PRD.

## Decisions to promote (ADR candidates)
None. Complements ADR 0008 (does not reverse it); the wander mitigation is a
prompt elaboration of decisions already recorded in ADR 0007/0008.

## Touched files
- scripts/build-prompt.md — add the surgical-changes norm bullet with the required-change carve-out
- scripts/rework-prompt.md — echo the single-finding-scope form on the rework path
- tests/surgical-norm.test.sh — assert the norm + carve-out in both prompts; mandated doc-update bullet intact
- tests/implement-gate.test.sh — register the new eval

## Expected diff size
- scripts/build-prompt.md — 35 lines
- scripts/rework-prompt.md — 26 lines
- tests/surgical-norm.test.sh — 112 lines
- tests/implement-gate.test.sh — 10 lines
Total expected diff: 183 lines across 4 files.

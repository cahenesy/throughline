# 0015. Model cost/performance by job (inherit the parent, light tier, escalation on demand)
Status: accepted
Date: 2026-10-05
Scope: workflow / gate-architecture / model-selection
Supersedes: 0014

## Context
The PRD (f6ef178, PR #181) replaced "judgment work defaults to the most
capable model" with "best cost-to-performance model for each job, owned
by the operator through the parent session's model and effort" (NFR-3).
It added escalation to the most capable model on demand (FR-88) and
narrowed FR-86 to a light-tier / unreadable parent check.

ADR 0014 still binds the opposite. It sets unset `build=` and `review=`
to the latest top-tier id, and makes FR-86 a this-turn fetch of vendor
model pages that compares the parent against "most capable". Both are
now non-goals.

Harness facts this decision rests on (Claude Code, 2026-10):
- A subagent dispatched without a `model` parameter runs on the main
  conversation's model. `CLAUDE_CODE_SUBAGENT_MODEL`, if set, overrides
  that.
- Effort is session-wide. There is no per-dispatch effort parameter and
  no documented agent-frontmatter effort field.
- What a dispatch to an unusable model does is undocumented.
- The parent's model id appears as `message.model` in the session
  transcript. That is observed, not documented.

There is no machine-readable capability or cost ranking of model ids.

## Decision
- **Judgment workers inherit the parent.** The implementer, the FR-15(d)
  reviewer, the FR-10 design-reviewer (`model: inherit`), and a
  nontrivial runtime-verify are dispatched with **no model parameter**.
  Pins win: `THROUGHLINE_BUILD_MODEL`, `THROUGHLINE_REVIEW_MODEL`,
  `THROUGHLINE_RUNTIME_VERIFY_MODEL`, and `CLAUDE_CODE_SUBAGENT_MODEL`,
  which is treated as a pin because the harness applies it silently.
  A judgment slot pinned to the light tier warns and continues.
- **Two maintained bindings, one site.** `scripts/lib/models.sh` holds
  the only product names: the **light** tier and the **escalation**
  target, per harness, with an escalation override
  (`THROUGHLINE_ESCALATION_MODEL`).
  - Mechanical runtime-verify uses the light tier, and never a model above
    the parent: a light or unreadable parent means verify inherits.
  - Light-tier membership is decided by model family name. There is no
    rank table and no live fetch.
- **Parent model is observed, not asked.** It is read from the harness
  session artifact: on Claude Code, the transcript `message.model` via
  `CLAUDE_CODE_SESSION_ID`, parsed as JSON; on Grok, `summary.json`
  `current_model_id`. The model's self-report is never used. An
  unreadable model is reported as unreadable and never guessed:
  FR-86 warns and asks, and the run record shows `parent=unknown`.
- **Escalation lives only in `/build-tdds`.** It is triggered by
  `--escalate` / `THROUGHLINE_ESCALATE=1`, or automatically on a resume
  whose halt carries a gate `FAIL` verdict while the TDD blob on the
  integration branch is unchanged (declined with `--no-auto-escalate`).
  - Unpinned judgment slots escalate together.
  - An escalated resume re-runs the implementer on the existing build
    branch with the failed gate's report as input, then re-runs every
    gate.
  - Outcomes are `escalated`, `already-top`, and `fell-back`. Each is
    printed as one line and recorded in the per-TDD sidecar
    `<run>/<slug>.models.json`.
  - A fall-back is detected at dispatch (an error, or no report and no
    commits), never by an inactivity timeout.
- **Effort is the session's.** Workers run at the session effort. The
  run records the effort level and its source. A per-worker effort pin
  is reported as ignored on a harness without per-worker effort.
- **Carried forward from 0014:** review independence is a fresh worker,
  not a different model name. Same-session self-review is still
  forbidden.

## Consequences
- The operator's `/model` choice sets build cost. A parent on the most
  expensive model makes every judgment worker that expensive. The queue
  confirmation shows this before dispatch.
- Rebinding the light or escalation literal when a vendor ships a new
  generation is an implementation change, not an ADR. A stale binding
  affects only escalated runs and light-tier detection.
- TDD 0062's `models.sh` contract (prior-gen review pairing) is
  superseded. The rest of 0062 stands. TDDs 0064–0067 implement this ADR.
- A `failed`/`gate-fail` TDD gets a step-3 **Retry**: the implementer
  fixes on the existing build branch from the failed gate's report, then
  every gate re-runs, escalated when FR-88 applies (TDD 0067). This
  replaces re-entering at the failed gate on unchanged code.
- On Claude Code the dispatch `model` parameter takes family aliases, so
  the bindings and pins are aliases; a full id fails at dispatch.
- The `fell-back` path depends on undocumented harness behavior. TDD
  0067's live probe must demonstrate it, or that build halts `BLOCKED`.
- ADR 0010's "different-model artifact" consequence stays revised, as
  0014 recorded. ADR 0008 has no live caller.

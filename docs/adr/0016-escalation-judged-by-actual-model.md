# 0016. Escalation outcomes are judged by the model that actually ran
Status: accepted
Date: 2026-10-05
Scope: workflow / gate-architecture / model-selection / verification-integrity
Revises: 0015 (its fall-back detection consequence only)

## Context
ADR 0015 says an escalation fall-back is "detected at dispatch (an error,
or no report and no commits), never by an inactivity timeout". PRD FR-88
says the same: "detected when the worker fails to start or is refused".

/build-tdds run 20261005-174458 showed that this is not enough. On
Claude Code, an Agent dispatch with `model: fable` on an account without
Fable credits silently ran `claude-opus-5-5`, with no error, a full
report, and real commits. All six fable-requested workers did this. A
dispatch-only rule would have recorded `escalation=escalated model=fable`
while Opus did the work. That is a false record, which NFR-4 forbids.

The model that actually answered is observable after the fact. It is the
assistant `message.model` in the worker's transcript at
`projects/<proj>/<session>/subagents/agent-<id>.jsonl`. That layout is
observed, not documented.

## Decision
- An escalation outcome is judged by the model that **actually ran**,
  not the model requested.
- After each escalated judgment worker completes, the parent reads the
  worker's transcript.
- **`escalated`** only when every non-synthetic answer came from the
  escalation model's family.
- **`fell-back`** in these cases, each with a reason:
  - a different family answered: `harness ran <id>`;
  - the dispatch was refused, including `credits_required`;
  - there was no report and no work.
- **An actual model that cannot be read counts as `fell-back`**, with
  reason `actual model unverified (<why>)`. The record may under-report
  a real escalation, but never over-reports one.
- Fall-back is still never inferred from an inactivity timeout.
- Detection happens at dispatch **or** after the worker completes. The
  post-completion check is what closes the silent-substitution hole.
- A substituted worker's output is kept; only the record changes. The
  TDD's remaining workers inherit the parent's model.
- The rest of ADR 0015 stands unchanged: inherit-by-default, the light
  and escalation bindings, triggers, sidecar, effort, and fresh-worker
  independence.

## Consequences
- FR-88's wording "detected when the worker fails to start or is
  refused" is narrower than this decision. TDD 0067 surfaces it as a PRD
  conflict, and this ADR resolves it in favour of NFR-4. A later PRD pass
  should widen the FR-88 sentence.
- Escalation honesty depends on an undocumented harness artifact. If the
  layout changes, every escalation records `fell-back … unverified`. The
  record degrades to honest under-reporting, and TDD 0067's live probe
  (positive control) fails or reports BLOCKED, rather than passing.
- A harness with no worker artifact (Grok today) always records
  `fell-back … unverified`. The first escalated worker still runs on the
  escalation model; the record under-reports it.

---
name: review
description: Run a thorough, unbiased code review using isolated subagents (security + correctness), then consolidate findings by severity with a clear verdict. Pass a scope (path or "the diff") or let it default to the current branch's changes. Invoke with /review.
disable-model-invocation: true
---

# Review

Scope: $ARGUMENTS — if empty, review the current branch's changes against its
base (use `git diff` to determine them).

Reviews run in isolated subagent context on purpose: a fresh context is not
biased toward code that was just written, which makes the review sharper.

`/implement` already runs this same review as an automatic gate (in a SEPARATE
process from the build, via `scripts/review-prompt.md`) and will not flip a TDD to
`implemented` unless it returns `REVIEW_RESULT: PASS`. Use `/review` for an
on-demand review — a scope `/implement` did not cover, a re-review after you
address findings, or any branch not produced by the runner.

## Process
1. Determine the scope (files / diff) and which TDD and accepted ADRs govern it.
2. Fan out to subagents, each in its own context:
   - `security-reviewer` — injection, authn/authz, secrets, unsafe handling.
   - `code-reviewer` — correctness, edge cases, error paths, and consistency
     with the governing TDD and accepted ADRs.
3. Consolidate into ONE list ranked by severity (blocker / major / minor / nit),
   each with a file:line reference and a concrete fix.
4. Call out any drift from the governing TDD or any accepted ADR explicitly.
5. End with a verdict: ship / fix-then-ship / needs-rework. Do not invent issues
   to look thorough — "no material findings" is a valid result.

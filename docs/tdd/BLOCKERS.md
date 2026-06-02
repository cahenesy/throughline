# Implementation blockers

> Design-level blockers raised by /implement. Resolve via /tdd-author, then delete the entry.

- [ ] **stale-base-resume** (2026-06-02, runner gap observed on run 20260601-115311 / TDD 0021) —
  Resuming a paused run after the integration branch has advanced builds against a stale base:
  the branch inherits since-fixed test reds (ci-checks cannot distinguish them from build
  regressions) and accumulates merge conflicts with master that surface only at PR time.
  TDD 0031's integration-merge-on-resume covers ONLY structural-finding halts; transient
  resumes re-enter the gates on the stale base unchanged. Design wanted: extend the
  integration merge (with conflict-refusal) to ALL resume paths, or add a base-staleness
  check at resume time that surfaces the divergence for a human decision. Manual remediation
  this time: master merged into the build branch by hand (commit 5365d7e), semantic test-stub
  conflicts resolved, fragment flipped back to paused for gate re-entry.

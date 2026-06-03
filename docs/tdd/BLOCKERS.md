# Implementation blockers

> Design-level blockers raised by /implement. Resolve via /tdd-author, then delete the entry.

- [x] **stale-base-resume** (2026-06-02, runner gap observed on run 20260601-115311 / TDD 0021) — RESOLVED by TDD 0033 (integration merge on all resume paths) —
  Resuming a paused run after the integration branch has advanced builds against a stale base:
  the branch inherits since-fixed test reds (ci-checks cannot distinguish them from build
  regressions) and accumulates merge conflicts with master that surface only at PR time.
  TDD 0031's integration-merge-on-resume covers ONLY structural-finding halts; transient
  resumes re-enter the gates on the stale base unchanged. Design wanted: extend the
  integration merge (with conflict-refusal) to ALL resume paths, or add a base-staleness
  check at resume time that surfaces the divergence for a human decision. Manual remediation
  this time: master merged into the build branch by hand (commit 5365d7e), semantic test-stub
  conflicts resolved, fragment flipped back to paused for gate re-entry.
- [x] **0028-interrogator-discipline.md** (2026-06-03): review:1 structural-finding (b) — PRECHECK_FAIL: structural-finding(b) tests/interrogator-discipline.test.sh 131 > 90 — RESOLVED by in-place revision of TDD 0028 (draft): the eval test legitimately needs ~130 lines (~10 mechanical anchors across both SKILL.mds + the subsumed-directive polarity check), so the ~90 per-file `## Expected diff size` bound was a design-time underestimate, not a code defect. Bumped the eval bound to ~135 (and the two SKILL.md bounds 45→60, the wire-in bound 6→18) to match the build branch's actual sizes, and promoted the `tests/implement-gate.test.sh` aggregator wire-in from a Touched-files-only entry to an explicit `## Sequencing` step so the rebuild does it inline rather than reworking into it. No design substance changed.
- [x] **0028-interrogator-discipline.md** (2026-06-03): review:1 structural-finding (c) — FR-76 rendering instruction is positioned two bullets after `gh pr create`, with no explicit pre-creation mechanism — the assumptions section may not reach the PR body at creation time — RESOLVED by second in-place revision of TDD 0028 (draft): §3 now mandates the "Open assumptions & waivers" section be rendered and assembled INTO the `gh pr create --body` (pre-creation), with the load-bearing ordering called out for both skills' git steps and reflected in Sequencing steps 1–2. The same revision also hardened the eval's mechanical checks against two recurrent build-quality majors surfaced in the same review (`fragile-inversion-pattern`: the subsumed-directive removal check now fails closed on grep exit ≥2 / unreadable file; `weak-structural-assertion`: anchors must be specific to new text, no vacuous match on pre-existing skill content) — see the Verification plan's "Mechanical-check robustness" rules. Eval bound bumped 135→155 and both SKILL.md bounds 60→65 to accommodate.

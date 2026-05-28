# 0006. Gate verdicts grounded in verifiable artifacts, not author self-report
Status: accepted
Date: 2026-05-28
Scope: workflow / gate-architecture / verification-integrity

## Context

The four-gate system (build, verify.sh, runtime-verify, review) issues verdicts
that determine whether a TDD is `implemented`, whether a build halts, whether
rework runs, and whether downstream TDDs in a sequential run proceed. The
diagnosis of TDD 0011 (PR #36) surfaced a mode where these verdicts drifted
from the underlying ground truth: a build's narrative `BATCH_RESULT` summary
claimed a smaller scope than the actual `git diff`; a review pass cleared
findings the author's narrative described without checking the diff that
backed them; the rework loop iterated against the author's self-report rather
than the actual change.

The PRD's FR-70 captures the durable principle: **every gate verdict must be
reproducible from the design + run artifacts alone — `git log`, `git diff`,
the TDD file, and the run-state record — never from the author's narrative
self-report about its own work.** A re-verifier with only those four inputs
must reach the same verdict the gate did.

This is closely related to ADR 0004 ("verification is observation at the
surface, not bundled into the harness") — that ADR governs the *verification
mechanism*; this ADR governs the *evidentiary basis* every gate's verdict
rests on. The two compose: verification observes the surface; every gate
grounds its verdict in the observable artifacts.

Two enforcement approaches were available in principle:

- **Mechanical grounding (sandbox-style).** Refuse to let any gate prompt see
  the author's narrative text at all — strip it from inputs, feed gates only
  the on-disk artifacts. Strong guarantee; high cost (the narrative carries
  useful summarization the human reviewer also reads); reverses TDD 0008's
  decision to surface narrative for human consumption.
- **Prompt-level grounding (instruction with rationale) + meta-finding
  detection.** Write the artifact-grounding rule into every gate prompt as a
  named requirement with its reasoning; have each gate self-apply the rule
  (a finding without a backing artifact quote is itself a finding); detect
  drift after the fact via the run-state record's evidence fields. No
  workflow disruption; matches the "govern, not bundle" posture of ADRs
  0002–0005.

TDDs 0020 + 0021 (continuous review and severity-honest-reporting) implement
the second approach pragmatically: review pass scope is anchored to
`git diff <last-cleared-sha>..HEAD` (a SHA-bound scope no narrative can move),
findings must carry an `evidence` field quoting one of the four artifacts,
diff-vs-narrative discrepancies are a `major` finding, and an author
self-review checks the same artifacts before declaring done. This ADR records
that as a durable architectural principle so it doesn't drift in either
direction.

## Decision

Treat **the evidentiary basis of every gate's verdict** as an artifact-only
discipline, enforced by:

- **Instruction with rationale (prevention).** Every gate prompt
  (`design-reviewer`, the mechanical pre-pass, the in-build review prompt,
  the runtime-verify prompt) carries the artifact-grounding rule as a named
  requirement with its reasoning. Quotes in findings, in verdicts, in
  rework instructions must be verbatim from one of: `git log`, `git diff`,
  the TDD file, or the run-state record at `docs/tdd/.implement-logs/<runid>/`.
  Model-instruction stickiness is much higher when the rule travels with its
  justification.
- **SHA-anchored scopes (mechanical falsifiability).** Review pass scope is
  bounded by recorded SHAs (TDD 0020's `last_cleared_review_sha`); rework
  attempt bounds are computed against the recorded TDD declarations
  (TDD 0019 against TDD 0014's `## Touched files` + `## Expected diff size`);
  halt-cause records cite finding refs that are reproducible from the
  review log. Every verdict-supporting field on the run-state record is
  re-derivable from these four sources.
- **Meta-finding self-application.** Every gate prompt instructs the model
  to apply the rule to its own output: a finding whose evidence is the
  author's narrative alone, without a backing artifact quote, is itself a
  finding. A diff-vs-narrative discrepancy is a `major` finding. The
  reviewer is the first enforcer; the human merge gate is the second.

throughline does NOT strip narrative text from gate inputs, does NOT
introduce a separate "verdict re-verifier" pass, and does NOT enforce
grounding by post-hoc static analysis. Prompt-level instruction +
SHA-anchored mechanical scopes + meta-finding self-application are the
three layers; together they make the discipline observable from
run-state alone.

Rejected alternatives:
- **Strip narrative from all gate inputs.** Loses the narrative's value to
  the human reviewer (who reads BATCH_RESULT to understand intent
  alongside the diff); doubles the gate prompt surface (one with narrative
  for humans, one without for gates); not justified by the available
  evidence (narrative drift is detectable; eliminating it removes a useful
  signal too).
- **Separate verdict re-verifier pass that consumes only artifacts and
  re-issues the gate's verdict from scratch.** Duplicates the gate's work;
  doubles token cost without proportional integrity gain (the meta-finding
  approach catches narrative drift at the same point, cheaper).
- **Post-hoc static analysis of finding text to detect ungrounded
  evidence.** Would require pattern-matching evidence quotes against
  `git diff` text — too brittle to whitespace and line-number drift;
  produces false positives that erode reviewer trust.

## Consequences

- Every gate prompt (`scripts/review-prompt.md`,
  `scripts/build-prompt.md`, `scripts/verify-runtime-prompt.md`, and
  `agents/design-reviewer.md`) carries the artifact-grounding rule as
  required instruction text. They are not optional and not silently
  elidable.
- The run-state record's schema includes `findings[*].evidence`,
  `cleared_step_log[*].{base_sha, head_sha, pattern_tags}`, and the
  halt-cause `halt_triggering_finding_ref` field. Together they make
  any gate verdict reproducible from artifacts (TDDs 0018, 0020, 0021).
- The author's `BATCH_RESULT` narrative carries less verdict authority
  than the actual diff; the review gate's diff-vs-narrative check
  (TDD 0021 / FR-71) makes the discrepancy detectable as a `major`
  finding.
- Author self-review (TDD 0021 / FR-60) applies the same discipline
  pre-emptively: the build runs the reviewer's checklist against its
  own diff before declaring done.
- Complements ADR 0004 ("verification is observation at the surface")
  by applying the same grounded-in-artifacts pattern to gate verdicts;
  composes naturally with ADR 0005 ("gate scope by prompt").
- **Future tightening when warranted.** If narrative drift continues to
  show up in operational data despite prompt-level instruction, a
  future ADR can supersede this one with mechanical evidence-quote
  substring matching against `git diff` text. The current approach is
  the cheaper first move; the data will tell us whether to harden.
- Promoted by TDDs 0020 + 0021; supersedes nothing.

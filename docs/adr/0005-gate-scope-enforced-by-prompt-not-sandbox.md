# 0005. Gate scope enforced by prompt + downstream detection, not sandboxing
Status: accepted
Date: 2026-05-26
Scope: workflow / runner-safety / gate-architecture

## Context

`/implement`'s four gates (build, verify.sh, runtime-verify, review) each have a
distinct scope. The build phase writes code and commits; runtime-verify drives
the built artifact at its observable surface (ADR 0004); the review phase judges
the diff. The PR #24 post-mortem of the TDD 0008 build failure surfaced an
acute version of the scope-policing question: the build claude spent 18 minutes
setting up `/tmp/rp-d` and `/tmp/state-smoke` fixtures, spawned nested `claude
-p` sessions to drive its own implementation, and ran `pkill -f "claude -p
Implement the Technical"` — matching its own parent process and ending the
session with no `end_turn` text. The four-gate system caught the failure (no
`BATCH_RESULT`, branch retained, no flip), but the underlying question was open:
**how do we keep build inside its scope and runtime-verify away from its parent
process going forward?**

Two enforcement approaches were available in principle:

- **Pre-execution policing.** Sandbox the gate's shell (firejail / bubblewrap /
  similar), intercept and filter tool calls before they reach the OS (an MCP
  server in front of the runner), or statically analyze prompts to predict
  violations. Strong guarantees; high cost; OS-specific; a runtime dependency
  in consumer projects.
- **Prompt-level instruction plus downstream gate detection.** Write the
  boundaries into the gate prompts WITH RATIONALE (so the model has the
  *why*, not only the *what*); rely on the existing four-gate verdicts plus
  the new session-pointer visibility (FR-36) to detect after-the-fact and
  refuse the flip. No runtime dependency; matches the "govern, not bundle"
  posture established by ADRs 0002–0004; the design-reviewer's pre-build
  critique adds a third layer (catching TDDs whose verification plans
  inherently require forbidden behavior).

PR #24 implemented the second approach pragmatically in scripts; PR #25
captured it as PRD requirements (FR-37 build-phase boundaries; FR-38
runtime-verify cleanup safety; the non-goal "Sandbox- or static-analysis-
enforced gate boundaries"). This ADR records that as a durable architectural
decision so it doesn't drift in either direction.

This decision sits alongside ADR 0004 (verification is governed, not bundled).
It applies the same "govern, not bundle" pattern to a different surface — gate
scope rather than verification mechanism — and does not reverse anything in
0003 or 0004.

## Decision

Treat **gate scope** as a prompt-level concern, enforced by:

- **Instruction with rationale (prevention).** The build prompt
  (`scripts/build-prompt.md`) and the runtime-verify prompt
  (`scripts/verify-runtime-prompt.md`) carry each boundary as a named
  prohibition with its reasoning. Model-instruction stickiness is much higher
  when constraints travel with their justification; this is the primary
  enforcement.
- **Downstream gate detection.** The four-gate system's existing verdicts plus
  the FR-36 session-pointer visibility detect violations after the fact: a
  build that spawns nested claude or runs `pkill` shows up in its session
  JSONL (now pointed at from the gate log); a build that produces no
  `BATCH_RESULT` fails the build-gate classifier; the review gate sees the
  diff and the test set; the human merge is the final gate.
- **Pre-build design critique.** The `design-reviewer` agent (TDD 0003 /
  FR-10) reads the TDD's verification plan and `BLOCK`s a TDD whose plan
  inherently requires forbidden behavior (e.g., a TDD that needs the build
  phase to spawn nested claude). This catches the issue at design time rather
  than runtime.

throughline does NOT sandbox the build's shell, filter its tool calls
pre-execution, or sit policy in front of process invocations.

Rejected alternatives:
- **Bundle a sandbox (firejail / bubblewrap / similar) into the runner.** Adds
  a runtime dependency, OS-specific (firejail is Linux-only; bubblewrap needs
  user namespaces), and directly contradicts the "delegate mechanism / govern
  not bundle" posture of ADRs 0002–0004. Lock-in costs without proportional
  safety gain over prompt + four-gate detection.
- **Introspect Claude's tool-use stream live to block forbidden calls
  pre-execution.** Would require an MCP server in front of the runner.
  Complex, at the wrong layer, and Claude Code's plugin architecture does not
  currently offer a pre-execution policy hook for tool calls.
- **Statically analyze prompt outputs after the fact to detect violations
  automatically.** The session JSONL approach (FR-36) already surfaces this
  to the human reviewer with full context; an automated post-hoc analyzer
  would duplicate the work without the human's judgment, and the four-gate
  system already catches the failure either way.
- **Treat the boundaries as best-effort guidance only, without a recorded
  decision.** Loses the durable pattern; future contributors may reach for
  a sandbox approach by reflex when the next incident surfaces, re-litigating
  this choice without the post-mortem context.

## Consequences

- The build prompt (`scripts/build-prompt.md`) and runtime-verify prompt
  (`scripts/verify-runtime-prompt.md`) carry their gate-scope boundaries as
  required instruction text with rationale (FR-37, FR-38). They are not
  optional and not silently elidable — `/tdd-author`'s design-reviewer
  treats a TDD that would require violating them as a `BLOCK`.
- Detection is post-hoc by design — a misbehaving gate may produce a failure
  or strange artifact before the four-gate system catches it. The session
  pointer (FR-36) makes those failures immediately diagnosable from the
  per-TDD log rather than requiring a hunt under `~/.claude/projects/`.
- No sandbox/firewall/policy-broker runtime dependency in consumer repos
  (consistent with NFR-5 and ADRs 0002–0004); throughline remains a thin
  governance overlay.
- The design-reviewer's `BLOCK` verdict is the pre-build defense for TDDs
  whose verification approach inherently requires forbidden gate behavior;
  this gives the human one more chance to redesign before the build runs.
- Complements ADR 0004 (verification mechanism is governed, not bundled) by
  applying the same "govern, not bundle" pattern to gate scope.
- **Threat-model assumption (named explicitly).** This decision assumes the
  human merge gate (NFR-1) screens out malicious TDDs before they reach the
  build phase. A hostile actor with merge access could author a TDD whose
  build phase intentionally violates the boundaries (e.g., to exfiltrate
  data or kill other processes), and prompt-only enforcement would not
  prevent it — the four-gate system would only detect the harm after the
  fact via the session JSONL (FR-36). throughline is a human-in-the-loop,
  merge-gated system and does not address this scenario; a compromised
  merge gate is out of scope for this ADR and for the broader gate-safety
  posture.
- Promoted by TDD 0010 (build observability & safety boundaries); supersedes
  nothing.

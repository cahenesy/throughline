# ADR Index

> Only `accepted` ADRs are binding constraints for new TDDs.

| #    | Title                                                  | Status              | Scope                          |
|------|--------------------------------------------------------|---------------------|--------------------------------|
| 0001 | Throughline layers on top of superpowers; it governs, superpowers builds | superseded by 0002  | workflow / plugin-architecture |
| 0002 | Depend on the official plugins and delegate overlapping engineering to them | superseded by 0003 | workflow / plugin-architecture |
| 0003 | Keep security-reviewer in the gate; delegate build + code-review | accepted | workflow / plugin-architecture |
| 0004 | Verification is runtime observation at the surface; governed, not bundled | accepted | workflow / verification |
| 0005 | Gate scope enforced by prompt + downstream detection, not sandboxing | accepted | workflow / runner-safety / gate-architecture |
| 0006 | Gate verdicts grounded in verifiable artifacts, not author self-report | accepted | workflow / gate-architecture / verification-integrity |
| 0007 | Halt model: bounded rework + structural escalation (not first-failure halt) | accepted (rework-model consequence revised by 0008) | workflow / gate-architecture / halt-semantics |
| 0008 | Rework authoring on the build model (author↔reviewer diversity); revises 0007's rework-model consequence | accepted | workflow / gate-architecture / model-diversity |

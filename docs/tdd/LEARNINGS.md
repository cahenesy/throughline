# Build-phase learnings (accepted) — recurring quality patterns mined at run-end (FR-72), advisory context for /tdd-author (FR-73).

## L-001: recurrent-pattern
- Pattern class: recurrent-pattern
- Recurred across: 0028-interrogator-discipline, 0033-integration-merge-on-all-resumes (first observed run 20260603-124616)
- Severity range: minor–major
- Subject-area hints: files=[skills/prd-author/SKILL.md, skills/tdd-author/SKILL.md, tests/interrogator-discipline.test.sh, tests/implement-gate.test.sh, scripts/lib/resume.sh, skills/implement/SKILL.md, tests/integration-merge-on-resume.test.sh] tags=[recurrent-pattern]
- Flags: structural=false rework=false
- Summary: Inverted removal check fires `ok` on grep exit-2 (file-missing) as well as exit-1 (string-absent), producing a false pass when TDD_SKILL is unreadable — a recurrence of the prior-addressed `fragile-inversion-pattern`
- Representative evidence: `grep -qF 'CHALLENGE the PRD:' "$TDD_SKILL" \` `  && bad "tdd-author: the subsumed one-sentence 'CHALLENGE the PRD:' directive must be REMOVED (new block is authoritative)" \` `  || ok "tdd-author: the subsumed one-sentence 'CHALLENGE the PRD:' directive was removed"`

## L-002: misleading-diagnostic
- Pattern class: misleading-diagnostic
- Recurred across: 0028-interrogator-discipline, 0029-evaluation-rubric-cocreation (first observed run 20260603-124616)
- Severity range: minor–minor
- Subject-area hints: files=[skills/prd-author/SKILL.md, skills/tdd-author/SKILL.md, tests/interrogator-discipline.test.sh, tests/implement-gate.test.sh, agents/design-reviewer.md, tests/evaluation-rubric.test.sh] tags=[misleading-diagnostic]
- Flags: structural=false rework=false
- Summary: prd-author-specific compound check runs unconditionally after check_common returns early on missing file, emitting a misleading content-failure bad() instead of the correct infra-failure message
- Representative evidence: `{ grep -qF 'fold every item dispositioned' "$PRD_SKILL" && grep -qF 'Open questions' "$PRD_SKILL"; } \ && ok "prd-author: waived items folded into the PRD's ## Open questions section" \ || bad "prd-author: waived items must ALSO be appended to the PRD's ## Open questions section (anchor: 'fold every item dispositioned')"`

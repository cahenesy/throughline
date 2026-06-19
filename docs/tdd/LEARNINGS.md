# Build-phase learnings (accepted) — recurring quality patterns mined at run-end (FR-72), advisory context for /tdd-author (FR-73).

## L-001: recurrent-pattern
- Pattern class: recurrent-pattern
- Recurred across: 0028-interrogator-discipline, 0033-integration-merge-on-all-resumes, 0038-mechanical-per-step-test-first-enforcement, 0041-bounded-rework-convergence (first observed run 20260603-124616; also run 20260608-195531)
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

## L-003: tdd-drift
- Pattern class: tdd-drift
- Recurred across: 0038-mechanical-per-step-test-first-enforcement, 0041-bounded-rework-convergence (first observed run 20260608-195531)
- Severity range: major–major
- Subject-area hints: files=[scripts/lib/gates.sh, scripts/build-prompt.md, tests/test-first-per-step.test.sh, tests/implement-gate.test.sh, tests/continuous-in-build-review.test.sh, tests/build-defensive-norms.test.sh, tests/step-commit-protocol.test.sh, tests/coproc-verdict-resilience.test.sh, scripts/lib/state.sh, scripts/review-prompt.md, skills/tdd-author/SKILL.md, tests/bounded-rework-convergence.test.sh] tags=[tdd-drift]
- Flags: structural=false rework=false
- Summary: `_tf_sentinel` extracted without `| tail -1`, diverging from the TDD-specified approach and from the step_id/sha extractors, enabling a multi-sentinel bypass
- Representative evidence: TDD §1 lines 100-103 specify: `grep -aoE 'STEP_COMMIT:[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+([[:space:]]+TEST_FIRST_SKIPPED:[^[:space:]]+)?' | tail -1`. Implementation (diff line +979): `_tf_sentinel="$(printf '%s' "$text" | grep '^STEP_COMMIT:[[:space:]]')"` — no `| tail -1`. step_id and sha use `| tail -1` (diff +968-969).

## L-004: test-cleanup
- Pattern class: test-cleanup
- Recurred across: 0049-touched-files-extractor-unify-and-harden (first observed run 20260610-202344)
- Severity range: minor–major
- Subject-area hints: files=[scripts/lib/touched-files.sh, scripts/lib/gates.sh, scripts/lib/tdd-lint.sh, scripts/lib/learnings.sh, tests/bounded-tdd-scope.test.sh] tags=[test-cleanup]
- Flags: structural=false rework=false
- Summary: Two new test cases create temp dirs without trap-cleanup; prior-addressed pattern recurs in same diff that has a correct cleanup example
- Representative evidence: Site 1 — `[extract-forms]` (diff +line, tests/bounded-tdd-scope.test.sh ~line 529): `TMP="$(mktemp -d)"; f="$TMP/forms.md"; make_extract_forms "$f"` — no `trap 'rm -rf "$TMP"' EXIT` before mktemp. Site 2 — `[gates-annotated-membership]` (diff +line, tests/bounded-tdd-scope.test.sh ~line 551): `D="$(mktemp -d)"; cd "$D" 2>/dev/null` — no `trap 'rm -rf "$D"' EXIT`. Counterexample in the SAME diff: `[bounds-single-source]` has `TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT` (diff +line ~line 479). `mktemp-no-cleanup` and `test-cleanup` are both in the build's prior-addressed pattern list. FINDING_KIND: recurrent-pattern mktemp-no-cleanup

## L-005: swallowed-stderr
- Pattern class: swallowed-stderr
- Recurred across: 0049-touched-files-extractor-unify-and-harden (first observed run 20260610-202344)
- Severity range: minor–major
- Subject-area hints: files=[scripts/lib/touched-files.sh, scripts/lib/gates.sh, scripts/lib/tdd-lint.sh, scripts/lib/learnings.sh, tests/bounded-tdd-scope.test.sh] tags=[swallowed-stderr]
- Flags: structural=false rework=false
- Summary: tl_extract_touched_paths does not check awk's exit code; a silently failing awk emits empty output which produces a spurious structural-finding(a) for every changed file
- Representative evidence: `tl_extract_touched_paths() { local f="$1" mode="${2:-paths}"; [ -f "$f" ] || return 0; awk -v MODE="$mode" '...' "$f"; }` — the function's last statement is the awk call with no exit-code capture. The critical consumer `_rework_pre_pass` calls `_rework_touched_files` via command substitution (`set_list="$(_rework_touched_files "$tdd")"`) without checking rc: an awk failure yields `set_list=""` and every changed file fails membership silently. NOTE: this is a pre-existing pattern carried into the centralized function (the predecessor awk bodies in all three callers were also unchecked); it is not a regression but a quality gap that the new single-definition point is now the right place to fix. `check_touched_file_count` in the same file captures `awk_rc` correctly — the new function breaks that convention.

## L-006: intent-unenforced
- Pattern class: intent-unenforced
- Recurred across: 0049-touched-files-extractor-unify-and-harden (first observed run 20260610-202344)
- Severity range: minor–major
- Subject-area hints: files=[scripts/lib/touched-files.sh, scripts/lib/gates.sh, scripts/lib/tdd-lint.sh, scripts/lib/learnings.sh, tests/bounded-tdd-scope.test.sh] tags=[intent-unenforced]
- Flags: structural=false rework=false
- Summary: `unset _tf_lib` is unreachable on the FATAL path in all three host files; TDD states it IS unset after use
- Representative evidence: TDD 0049 § Components: "the `_tf_lib` scratch variable in the per-host sourcing block, which IS unset after use". All three sourcing blocks share the same shape where `unset _tf_lib` follows the closing `}` of the FATAL branch — so `return 1 2>/dev/null || exit 1` (gates.sh:33, learnings.sh:41, tdd-lint.sh:36) exits/unwinds before `unset _tf_lib` (gates.sh:35, learnings.sh:43, tdd-lint.sh:38) is reached. Site 1: `scripts/lib/gates.sh:29-35` (diff). Site 2: `scripts/lib/learnings.sh:37-43` (diff). Site 3: `scripts/lib/tdd-lint.sh:29-38` (diff). FINDING_KIND: binding-rule-sweep

## L-007: after-the-fact-test
- Pattern class: after-the-fact-test
- Recurred across: 0049-touched-files-extractor-unify-and-harden (first observed run 20260610-202344)
- Severity range: minor–major
- Subject-area hints: files=[scripts/lib/touched-files.sh, scripts/lib/gates.sh, scripts/lib/tdd-lint.sh, scripts/lib/learnings.sh, tests/bounded-tdd-scope.test.sh] tags=[after-the-fact-test]
- Flags: structural=false rework=false
- Summary: `[bounds-parser-agreement]` 3-way upgrade written after the 3-way implementation was already complete (no test(failing) commit precedes it)
- Representative evidence: `git log --oneline` shows `37a80e8 step(4): learnings.sh sources touched-files.sh; _touched_files_of_tdd delegates` then `14dda4f step(5): 3-way parser-agreement cross-check + single-source grep` with NO intervening `test(failing):` commit for the 3-way check. After step(4), `_touched_files_of_tdd` already delegated to `tl_extract_touched_paths`, so `[bounds-parser-agreement]`'s 3-way check (tests/bounded-tdd-scope.test.sh:435) would pass immediately when written — the test was written after the implementation.

## L-008: resource-leak
- Pattern class: resource-leak
- Recurred across: 0049-touched-files-extractor-unify-and-harden (first observed run 20260610-202344)
- Severity range: minor–major
- Subject-area hints: files=[scripts/lib/touched-files.sh, scripts/lib/gates.sh, scripts/lib/tdd-lint.sh, scripts/lib/learnings.sh, tests/bounded-tdd-scope.test.sh] tags=[resource-leak]
- Flags: structural=false rework=false
- Summary: `unset _tf_lib` is unreachable on the FATAL error path in all three host libs — TDD states the scratch variable IS unset after use; this invariant is violated on the only path where it would be needed
- Representative evidence: TDD "Components & interfaces": "unlike the `_tf_lib` scratch variable in the per-host sourcing block, which IS unset after use". gates.sh:29–35 (diff): `_tf_lib` set at :29; FATAL block at :31–34 executes `return 1 2>/dev/null || exit 1` — `unset _tf_lib` at :35 is never reached. Identical pattern at learnings.sh:43 and tdd-lint.sh:38. Three sites, same binding invariant.

## L-009: verification-plan-gap
- Pattern class: verification-plan-gap
- Recurred across: 0051-state-fragment-carryforward-refactor (first observed run 20260613-094008)
- Severity range: major–major
- Subject-area hints: files=[scripts/lib/state.sh, scripts/lib/resume.sh, scripts/lib/pause-retry.sh, tests/state-carryforward-quotesafe.test.sh, tests/implement-gate.test.sh, .claude-plugin/plugin.json] tags=[verification-plan-gap]
- Flags: structural=false rework=false
- Summary: §3 does not exercise the _resume_from _rnote control-flow path, contradicting the TDD's stated mitigation that "no control-flow path reads note"
- Representative evidence: TDD 0051 §Failure modes (line 105): "`note` is forensic display text, never a control-flow comparand. Quote-free fields are byte-identical. Mitigated by Verification §1 (quote-free equivalence) + §3 (no control-flow path reads `note`)." Diff scripts/lib/resume.sh (context surrounding the converted line): `_rnote="$(_read_fragment_field "$f" note)"` followed immediately by `if printf '%s' "$_rnote" | grep -q 'ci-checks'` — note IS used as a control-flow comparand in _resume_from's ci-checks recovery arm. Test §3 (lines 134-154) only calls `set_halt_cause` and checks `status|halt_cause|paused_cause|halt_next_actions`; it never drives `_resume_from`, never sets `RECOVER=1`, and never asserts the 'ci-checks' grep classification is quote-stable. Zero references to `_resume_from`, `ci-checks`, or `_rnote` exist in the new test file.

## L-010: intent-unenforced
- Pattern class: intent-unenforced
- Recurred across: 0051-state-fragment-carryforward-refactor (first observed run 20260613-094008)
- Severity range: major–major
- Subject-area hints: files=[scripts/lib/state.sh, scripts/lib/resume.sh, scripts/lib/pause-retry.sh, tests/state-carryforward-quotesafe.test.sh, tests/implement-gate.test.sh, .claude-plugin/plugin.json] tags=[intent-unenforced]
- Flags: structural=false rework=false
- Summary: §3 does not exercise the _resume_from _rnote control-flow path, contradicting the TDD's stated mitigation that "no control-flow path reads note"
- Representative evidence: TDD 0051 §Failure modes (line 105): "`note` is forensic display text, never a control-flow comparand. Quote-free fields are byte-identical. Mitigated by Verification §1 (quote-free equivalence) + §3 (no control-flow path reads `note`)." Diff scripts/lib/resume.sh (context surrounding the converted line): `_rnote="$(_read_fragment_field "$f" note)"` followed immediately by `if printf '%s' "$_rnote" | grep -q 'ci-checks'` — note IS used as a control-flow comparand in _resume_from's ci-checks recovery arm. Test §3 (lines 134-154) only calls `set_halt_cause` and checks `status|halt_cause|paused_cause|halt_next_actions`; it never drives `_resume_from`, never sets `RECOVER=1`, and never asserts the 'ci-checks' grep classification is quote-stable. Zero references to `_resume_from`, `ci-checks`, or `_rnote` exist in the new test file.

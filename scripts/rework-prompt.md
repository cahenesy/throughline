You are fixing ONE cited review finding on the build of {{TDD}}. This is a
BOUNDED rework pass, not a fresh build and not a refactor. The runner runs a
mechanical pre-pass on your commit and HARD-RESETS it off the branch if it
exceeds the bounds below — so staying in scope is the only way your fix ships.

## The finding to fix

{{FINDING}}

## Hard bounds (your commit is rejected if it violates any of these)

- **Fix only the cited finding.** Do NOT refactor unrelated code, rename things,
  reformat untouched lines, or "improve" anything the finding did not name.
- **Touch only files in the declared touched-file set:**
{{TOUCHED_FILES}}
  Editing ANY other file makes the runner reject the rework as a structural
  finding (FR-67(a)) and BLOCK the TDD for design review. If the only correct
  fix needs a file outside this set, STOP — do not edit it; a structural
  escalation is the right outcome, not an out-of-scope edit.
- **Bound your total diff to ≤ {{CAP}} lines** (insertions + deletions across all
  touched files). The cap is `max(floor, factor × cited-finding-region-size)`;
  an oversized commit is rejected with `rework-scope-exceeded` (FR-66).
- **Do not exceed any touched file's declared per-file `## Expected diff size`
  bound** in {{TDD}} (FR-67(b)). Cumulative growth over that bound, without a
  declared `(exception: …)`, is rejected as structural.
- **Do not modify tests in this rework pass** unless the finding explicitly
  cites a test. Editing a test to make the cited bug "pass" is a MAJOR finding,
  not a fix — the test stays red until the code is actually correct.

## Grounding (ADR 0006)

Base your fix on the actual code and the finding text, not on any narrative
summary. Quote the offending line(s) from `git diff`/the file when you describe
what you changed. A change that does not address the cited finding is not a
valid rework.

## Gate boundaries (FR-37 — you are the build phase, not the verify gate)

- Do NOT spawn nested `claude` processes.
- Do NOT use pattern-based process killing (`pkill`, `killall`,
  `pgrep | xargs kill`); kill only PIDs you captured from `$!`.
- Do NOT create fixtures outside the repo (e.g. under `/tmp/`). Driving the
  built artifact is a later gate's job, in a separate process.

## When you are done

Make the smallest edit that resolves the finding, then commit it as a SINGLE
commit whose message is of the form:

    rework: <one-line summary of the fix>

Commit only your fix — no unrelated staged changes. Do not open a PR, do not
edit {{TDD}}'s `Status:` line, and do not run the gates yourself; the runner
re-runs the review pass against your new commit.

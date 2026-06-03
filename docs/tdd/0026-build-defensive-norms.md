# TDD 0026: Build-phase defensive-coding norms

Status: draft
PRD refs: FR-74
PRD-rev: 5036877
ADR constraints: 0004, 0005, 0006, 0007

## Approach

FR-74 asks the build to apply an enumerated set of defensive-coding norms at
generation time, so the build produces guarded code on the first pass instead
of relying on the review gate to catch each instance and the rework loop to fix
it. The norms codify the recurring finding classes the per-step reviewer keeps
raising on Opus-generated builds (silent error-swallowing, leaked temp files,
unsafe escaping, sourced-library hygiene, path-traversal, TOCTOU reads,
hardcoding) — empirically the dominant classes in the `cleared_step_log`
pattern-tag corpus across runs to date.

Two delivery surfaces, both in the existing build/runner machinery (no new
mechanism, no new gate):

1. **A single source-of-truth norms file**, `scripts/build-norms.md`, holding the
   enumerated norm set. It is concatenated into the initial build prompt by the
   existing `_render_build_prompt` (`scripts/lib/gates.sh`) — the build sees the
   norms up front, every build.

2. **A BLOCK-only reinforcement**: when a per-step review returns
   `STEP_REVIEW: BLOCK`, the runner appends a compact norms reminder to the
   reply it writes onto the build's stdin (the `_per_step_review_loop` BLOCK
   reply site). This is reinforcement-at-the-rework-moment, not
   recovery-from-loss: the multi-turn coprocess retains its full context
   (including the initial-prompt norms) across steps (per [[0025]]'s lifecycle),
   so a PASS reply needs no reminder — only the moment a finding was just raised
   and a fix is about to be written benefits from re-stating the norm.

This is consistent with [[ADR 0005]] (gate scope by prompt, not sandbox): the
norms are prompt-level guidance plus the existing downstream detection (the
review gate still independently catches violations). It does not add a
mechanical pre-flight check (that was explicitly deferred). It is additive to
FR-37's build-phase boundaries (which *forbid dangerous actions*); FR-74 *requires
defensive patterns* — adjacent surfaces, no conflict, no supersession.

The norm set is a fixed enumerated list here (per FR-74). A future TDD may
source it dynamically from the accepted-learnings store ([[0023]] / FR-73) once
that store is populated; this TDD's file-based source of truth is the seam that
makes that evolution a content swap, not a structural change.

## Components & interfaces

### 1. `scripts/build-norms.md` (new file)

A standalone markdown fragment — NOT a full prompt, just the norms block. Begins
with a single H2 anchor the runner can extract for reinforcement:

```
## Defensive-coding norms (FR-74)

Apply these to EVERY commit you make, including late commits in a long build:

1. Fail loud. Check every command's return code. No bare `|| true` without a
   one-line justification comment. A sourced helper whose load fails aborts —
   never silently continues with functions undefined.
2. Temp files. Register every temp file in an EXIT trap BEFORE you create it.
3. Safe escaping. Never hand-roll a JSON escaper: use `jq`; if jq is absent,
   `python3`; if neither, fail closed with a clear diagnostic. Never run bash
   pattern substitution (`${v//x/y}`) on an untrusted string — `&` is the
   matched-text reference and corrupts the output. Validate before interpolating
   any external value into `sed`, `eval`, or `bash -c`.
4. Sourced-library hygiene. A sourced library has NO top-level side effects and
   does NOT set shell options (`set -uo pipefail`) at top level — they leak to
   every caller. Declare locals; do not leak ambient variables.
5. Path / trust boundary. Any filesystem path built from an external or
   user-supplied identifier is validated against a literal allowlist or a
   containment check (e.g. `realpath` prefix) before use.
6. Read once. Read mutable external state once into a variable; do not re-read
   the same file/command twice (TOCTOU window + inconsistency).
7. No hardcoding. No hardcoded absolute paths; no non-portable commands.
```

The exact wording above is the design-of-record for the file's content; the
implementer commits it verbatim (modulo trivial typographic fixes). The H2 line
`## Defensive-coding norms (FR-74)` is the extraction anchor for §3 — it MUST be
present and unique in the file.

### 2. Initial-prompt inclusion — `_render_build_prompt` in `scripts/lib/gates.sh`

`_render_build_prompt` currently renders `build-prompt.md` with `{{TDD}}` and
`{{CLEARED_STEPS}}` substituted. Extend it to also substitute a
`{{BUILD_NORMS}}` placeholder with the full contents of `scripts/build-norms.md`,
resolved from the same scripts dir as the template (the existing `tmpl` dirname
resolution). `build-prompt.md` gains a `{{BUILD_NORMS}}` placeholder in a new
short section (§4). Resolution mirrors the existing template-not-found handling:

- Resolve `norms_file` = `<scripts-dir>/build-norms.md` (same dir as `$tmpl`).
- If `norms_file` is missing or unreadable, this is a FATAL render error
  (return 1 with a diagnostic to stderr) — NOT a silent empty substitution. A
  build prompt that silently drops its norms is exactly the failure mode FR-74
  exists to prevent; per norm #1 (fail loud) and the [[0024]] review-rerun-1
  precedent (`_per_step_review_loop` already treats a failed render as FATAL
  rather than spawning `claude -p ""`), the missing-norms case must abort the
  build, not degrade silently.
- Substitute via bash parameter expansion (not `sed`) — the norms text contains
  `&`, `/`, and backslashes that would corrupt a `sed` replacement (this TDD
  must not itself violate norm #3). Read the file into a variable and use
  `${prompt//\{\{BUILD_NORMS\}\}/$norms}`.

Substitution order: `{{TDD}}` (existing `sed`) first, then `{{CLEARED_STEPS}}`
(existing PE), then `{{BUILD_NORMS}}` (new PE) LAST — so the norms text (which
may contain `{{...}}`-like sequences in examples) cannot be re-scanned for
earlier placeholders.

### 3. BLOCK-only reinforcement — `_per_step_review_loop` in `scripts/lib/gates.sh`

At the BLOCK reply site (currently `printf '%s\n' "$(_user_turn_json "$verdict")"
1>&"${build_in}"` after a `STEP_COMMIT` → `_run_per_step_review` returns a
verdict), when the verdict begins `STEP_REVIEW: BLOCK`, append a compact norms
reminder to the message text BEFORE wrapping it as the user turn. PASS verdicts
are sent unchanged.

- A new helper `_build_norms_reminder` echoes a SHORT reminder (not the full
  file): a one-line lead-in plus the seven norm headlines extracted from
  `build-norms.md`'s numbered list. This keeps the per-BLOCK token cost low while
  pointing the build back at the full norms already in its context.
- Extraction (precise): read `build-norms.md`; for each line matching
  `^[0-9]+\. ` under the `## Defensive-coding norms` anchor, emit the **leading
  number plus the text up to and including the first period** — i.e. the short
  label clause (`1. Fail loud.`, `2. Temp files.`, `3. Safe escaping.`, …). This
  is deliberately the terse label, not the full body: the full norms are already
  in the build's retained context, so the reminder's job is to re-point at them by
  name, not re-state them. Multi-line norm bodies (a `^[0-9]+\. ` line whose body
  wraps onto continuation lines) contribute only their first line's
  pre-first-period span; continuation lines (no leading `N. `) are ignored. Pure
  `awk`, no model call. If the file is unreadable at this point (it was present at
  build start or the build would not have launched), emit a generic one-line
  reminder ("re-check the FR-74 defensive-coding norms in your initial prompt")
  rather than failing the in-flight build — the reminder is best-effort
  reinforcement, and the build's context already holds the full norms; aborting a
  live build over a missing reminder would be a worse outcome than a degraded
  reminder. (This asymmetry vs §2 is deliberate: §2 is the build's ONLY exposure
  to the norms and must fail loud; §3 is redundant reinforcement and degrades
  gracefully.)
- The reminder is appended to a SEPARATE message variable, NOT to `$verdict` in
  place. The existing code (`gates.sh` ~538–539) mirrors `$verdict` to the gate
  log (`printf '%s\n' "$verdict" >> "$log"`) and THEN sends `$verdict` to stdin.
  The implementer MUST compute `augmented="$verdict"$'\n'"$(_build_norms_reminder)"`
  (for a BLOCK verdict only) and pass `augmented` to `_user_turn_json` for the
  stdin write, while the log write at line 538 keeps using the bare `$verdict`.
  Mutating `$verdict` before the log write would pollute the gate log with the
  reminder — the log records the reviewer's actual verdict, the reminder rides
  only on the stdin message to the build.

### 4. `build-prompt.md` placeholder

Add a short section to `build-prompt.md` at the **END of the `Build discipline:`
section — immediately before the blank line that precedes the `Close:` heading**
(not at the top of Build discipline, which would push the existing RESUME/step
instructions down). Placing it last in the discipline block keeps it adjacent to
the build's commit workflow it governs, and as the final discipline item before
Close it is the most-recently-read instruction when the build begins committing.
The section introduces the norms and carries the placeholder:

```
Defensive-coding norms (FR-74). The following norms are non-negotiable; apply
them to every commit, including late ones:

{{BUILD_NORMS}}
```

No other build-prompt content changes.

## Data & state

No new fragment fields, no schema bump, no run-state changes. The norms file is
static plugin content; the reminder is computed per BLOCK from that file. Nothing
is persisted to `state.d/`.

## Sequencing / implementation plan

1. **Add `scripts/build-norms.md`** with the §1 content (the H2 anchor + the
   seven numbered norms).
2. **Extend `_render_build_prompt`** (`scripts/lib/gates.sh`) to substitute
   `{{BUILD_NORMS}}` from `build-norms.md`, fail-loud on a missing file, PE
   substitution last (§2). Add the `{{BUILD_NORMS}}` placeholder section to
   `build-prompt.md` (§4).
3. **Add `_build_norms_reminder` + wire the BLOCK-only reinforcement** into
   `_per_step_review_loop`'s BLOCK reply path (§3), degrading gracefully on a
   missing file.

## Failure modes & edge cases

- **`build-norms.md` missing/unreadable at render (§2).** FATAL — `_render_build_prompt`
  returns 1 with a stderr diagnostic; `_per_step_review_loop` already treats a
  failed render as a build-launch abort (no `claude -p ""`). The build never runs
  without its norms.
- **`build-norms.md` missing at reminder time (§3).** Degrade to a generic
  one-line reminder; do NOT abort the in-flight build (the full norms are already
  in its retained context). Distinct from §2 by design.
- **Norms text contains sed-breaking characters.** Handled: `{{BUILD_NORMS}}` is
  substituted by bash PE, not `sed`; substitution happens last so the inserted
  text is never re-scanned (§2).
- **A PASS verdict.** No reminder appended; sent unchanged (the coprocess retains
  the norms; reinforcement is BLOCK-only by design decision).
- **Degraded single-shot build (no STEP_COMMIT sentinels).** §3 never fires (no
  per-step BLOCK path); the build still gets the full norms via §2's initial
  prompt. Graceful.
- **A build that emits no temp file / no JSON / no risky construct.** The norms
  are present but vacuously satisfied; the acceptance check (below) only asserts
  the guarded form WHEN the construct appears.

## Verification plan

**Observable surface:** the rendered build prompt (what `_render_build_prompt`
emits), the message written to the build's stdin on a BLOCK (the
`_user_turn_json` payload), `_render_build_prompt`'s return code, and — for the
FR-74 acceptance itself — the committed diff of a build that exercises a norm.

**Observation points:**

1. **Norms reach the initial prompt.** Call `_render_build_prompt <slug> <tdd>`
   in a fixture with a `build-norms.md` present. Expect: the returned prompt
   contains the literal `## Defensive-coding norms (FR-74)` anchor and all seven
   numbered norm lead-ins; no literal `{{BUILD_NORMS}}` remains; return code 0.
2. **Missing norms file is FATAL at render.** Same fixture with `build-norms.md`
   removed. Expect: `_render_build_prompt` returns non-zero and emits a stderr
   diagnostic naming the missing file; the returned prompt is NOT a partial
   prompt with an unsubstituted/empty placeholder.
3. **Substitution is PE, not sed (no corruption).** Fixture `build-norms.md`
   containing `&`, `/`, and a `{{TDD}}`-like token. Expect: the rendered prompt
   contains those characters verbatim, and the `{{TDD}}`-like token inside the
   norms text is NOT substituted with the TDD path (proves norms are substituted
   last and not re-scanned).
4. **BLOCK reply carries the reminder.** Drive `_per_step_review_loop` (or the
   extracted `_build_norms_reminder` + reply assembly) with a stubbed per-step
   review returning `STEP_REVIEW: BLOCK <finding>`. Expect: the message written
   to the build's stdin contains both the original finding text AND the norm
   headlines; a `STEP_REVIEW: PASS` reply in the same harness contains neither
   (PASS sent unchanged).
5. **Reminder degrades gracefully when the file is gone.** Same as §4 but with
   `build-norms.md` absent at reminder time. Expect: the BLOCK message still goes
   to stdin (build not aborted) and contains a generic one-line norms reminder;
   `_per_step_review_loop` does not return a render-fatal code.
6. **FR-74 acceptance (end-to-end, mechanical).** A fixture eval (no model)
   asserting the wiring that makes the FR-74 acceptance observable: given the
   norms are in the prompt (§1) and reinforced on BLOCK (§4), the contract a real
   build is held to is that a committed diff exercising a norm shows the guarded
   form. This point is verified at the unit level by §1+§4 (the norms are present
   and reinforced); the artifact-surface assertion ("a real build's diff shows
   the guard") is the runtime-verify gate's job against this TDD's own build, not
   a unit test — recorded here so the runtime-verify gate drives it.

**Expected observations (PASS):** every numbered point yields the cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-74 (build-phase defensive-coding norms; enumerated; applied to every commit incl. late ones; observable as guarded form in the committed diff) | §1 enumerated norm file (the seven classes from the FR verbatim) + §2 initial-prompt inclusion (every build, fail-loud if missing) + §4 placeholder + §3 BLOCK-reinforcement (every-commit-incl-late, since rework commits are the late ones). Verification §1–§5 falsify the wiring; §6 + the runtime-verify gate drive the committed-diff acceptance. |

No gaps.

## Dependencies considered

No new external dependencies. Uses the existing `jq`/`python3`/awk already
assumed by the runner, bash PE, and the existing coprocess plumbing.

Alternatives considered:
- **Inline the norms directly in `build-prompt.md`** (no separate file) —
  rejected: §3's BLOCK reminder needs to extract the norm headlines from a
  stable, single source; a dedicated file with a known anchor is a cleaner
  extraction seam than parsing a section out of the larger prompt, and it is the
  seam a future FR-73-sourced version swaps. The marginal cost is one file.
- **Re-inject the full norms on every STEP_REVIEW (PASS and BLOCK)** — rejected
  per the design decision: the multi-turn coprocess retains the initial-prompt
  norms in context across steps ([[0025]]), so PASS-step reinjection pays token
  cost for no reinforcement value. BLOCK is the moment a finding was raised and a
  fix is imminent — the only point where re-statement changes behavior.
- **Add a mechanical pre-flight grep at STEP_COMMIT** (catch norm violations
  deterministically before review) — rejected for THIS TDD: explicitly deferred
  by the project owner; it is a separable enhancement that can be its own TDD if
  the prompt-level norms prove insufficient after measurement.
- **A new gate dedicated to norm enforcement** — rejected: violates [[ADR 0005]]
  (gate scope by prompt + downstream detection, not a new enforcement mechanism);
  the existing review gate already catches violations. FR-74 is about prevention
  at generation time, not a new detection gate.

## PRD conflicts surfaced (and resolution)

None. FR-74 is additive and was authored (PR #63) specifically for this design.
It is the build-side complement to FR-72/FR-73 (design-side); no conflict, and
the cross-reference is stated in both the PRD and §Approach here.

## Decisions to promote (ADR candidates)

None. The norms are prompt-level guidance under the existing [[ADR 0005]]
disposition; no new cross-cutting decision is introduced. The file-as-seam for a
future learnings-sourced version is noted but is not itself an ADR-level
commitment until that work is designed.

## Touched files

- `scripts/build-norms.md` — new: the enumerated FR-74 norm set with the H2 extraction anchor.
- `scripts/build-prompt.md` — add the `{{BUILD_NORMS}}` placeholder section (§4).
- `scripts/lib/gates.sh` — `_render_build_prompt` substitutes `{{BUILD_NORMS}}` (fail-loud); new `_build_norms_reminder` + BLOCK-only wiring in `_per_step_review_loop` (§2, §3).
- `tests/build-defensive-norms.test.sh` — new eval covering verification points §1–§5.
- `tests/implement-gate.test.sh` — wire the new eval into the aggregator.
- `tests/build-coprocess-lifecycle.test.sh` — provide a `build-norms.md` stub in its `setup_repo`: making `build-norms.md` mandatory in `_render_build_prompt` (§2) means any test that stubs `TMPL` into a temp scripts dir must also supply the norms file, or every `_per_step_review_loop` call aborts at render.

Total: 6 files touched.

## Expected diff size

- `scripts/build-norms.md` — ~30 lines added (new file).
- `scripts/build-prompt.md` — ~6 lines added (placeholder section).
- `scripts/lib/gates.sh` — ~45 lines added (`{{BUILD_NORMS}}` substitution + fail-loud guard in `_render_build_prompt`; `_build_norms_reminder` helper; BLOCK-branch wiring).
- `tests/build-defensive-norms.test.sh` — ~140 lines added (new eval, 5 cases + stub).
- `tests/implement-gate.test.sh` — ~6 lines added (aggregator wire-in).
- `tests/build-coprocess-lifecycle.test.sh` — ~9 lines added (`build-norms.md` stub in `setup_repo`).

Total expected diff: ~236 lines across 6 files. No exceptions needed.

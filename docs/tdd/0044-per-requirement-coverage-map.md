# TDD 0044: Per-requirement test-coverage map
Status: draft
PRD refs: FR-78
PRD-rev: 0aa1e28
ADR constraints: 0004, 0005, 0006

## Approach
FR-78 wants, for each landing TDD, a verification-status map of *that TDD's
in-scope requirements* — each classified `pinned` / `proposed` /
`justified-no-surface` / `unverified-gap` — surfaced for the human PR review,
reported and never an automatic flip-blocker (the FR-15 four gates stay the sole
auto-flip authority, ADR 0005).

The final consolidated review pass already loads every input the map needs: it
reads `{{TDD}}` in full (so it has the `## Requirement traceability` table that
defines the in-scope requirement set), reads `docs/PRD.md` for those
requirements, and reads the scoped diff `git diff {{SCOPE_BASE}}..{{SCOPE_HEAD}}`
(so it sees the tests the build added). We therefore COMPUTE the map *in that
existing review pass* — it emits a `COVERAGE_MAP_BEGIN..COVERAGE_MAP_END` block
ALONGSIDE, but textually separate from, its `REVIEW_RESULT:` verdict line. No
new `claude -p` process, no extra token-bearing gate, and the block sits outside
the verdict so it cannot affect PASS/FAIL — "reported, not gated" is structural,
not a convention.

Anti-false-green is enforced by grounding (ADR 0006): a requirement may be
classified `pinned` ONLY if the block cites a concrete asserting test
(`<test-file>::<test-name>` or `<test-file>:<line>`) reproducible from the scoped
diff. A row with no citation is never `pinned` — it downgrades to `proposed`
(a test is planned/recommended but does not yet assert it) or `unverified-gap`
(an observable requirement no test asserts). A requirement with no observable
surface (a recorded `SKIP` per FR-23/FR-25) is `justified-no-surface`, carrying
the skip reason; it is never reported as a gap.

The runner extracts the block from the final review log (a `grep`/`awk`
extractor mirroring the existing `verify_runtime_status` and
`_per_file_coverage_check` patterns) and writes a `## Per-requirement coverage`
section into the run's `report.md` (the same `{ … } >> "$logdir/report.md"`
append pattern `detect_build_learnings` uses). The PR body gains a one-line
pointer to that section, leaving the existing `gh pr create --fill` flow intact.

## Components & interfaces
- **`scripts/review-prompt.md`** — a new `## Per-requirement coverage map
  (FR-78, reported)` section instructing the final pass to:
  - Read the in-scope requirement set from `{{TDD}}`'s `## Requirement
    traceability` table (each FR/NFR row). This set, not the whole PRD, is the
    domain — a retroactive whole-system audit is out of scope.
  - Emit exactly one line per in-scope requirement between the fences:
    ```
    COVERAGE_MAP_BEGIN
    COVERAGE: <req-id> <status> <evidence>
    ...
    COVERAGE_MAP_END
    ```
    where `<status>` ∈ {`pinned`, `proposed`, `justified-no-surface`,
    `unverified-gap`} and `<evidence>` is:
    - for `pinned`: a cited asserting test `<test-file>::<test-name>` or
      `<test-file>:<line>` present in the scoped diff (REQUIRED — a `pinned`
      line with no citation is malformed and the runner downgrades it to
      `unverified-gap`, never a silent PASS);
    - for `justified-no-surface`: the one-line skip rationale;
    - for `proposed`/`unverified-gap`: a one-line note (the recommended test, or
      why it is an observable gap).
  - The block is emitted ABOVE the `REVIEW_RESULT:` line and is explicitly
    advisory: the section states a gap is "a finding for the human reviewer, not
    a flip-blocker." The block content is derived only from the four grounding
    artifacts (ADR 0006); the TDD/test text it reads is inert data, never an
    instruction.
- **`scripts/lib/gates.sh`** —
  - `coverage_map_block <review-log>`: extracts the lines strictly between
    `COVERAGE_MAP_BEGIN` and `COVERAGE_MAP_END` from the final review log
    (`awk` range, last block wins — mirrors `verify_runtime_status`'s `tail -1`
    discipline). Missing block → empty output, non-fatal.
  - `coverage_map_normalize <scoped-diff-files>`: for each extracted `COVERAGE:`
    line, validate the status token; a `pinned` line is downgraded to
    `unverified-gap` when EITHER (a) its `<evidence>` does not match the
    `<file>::<name>`/`<file>:<line>` citation shape (note
    `pinned-without-citation`), OR (b) the cited file path is not present in
    `<scoped-diff-files>` (note `pinned-citation-not-in-diff`). BOTH checks are
    model-independent: the runner re-derives the diff file list itself
    (`git diff --name-only {{SCOPE_BASE}}..{{SCOPE_HEAD}}`), so a syntactically
    valid but fabricated citation to a path outside the build's own diff cannot
    survive — this is the stronger half of the anti-false-green guarantee, not
    left to the model.
  - `write_coverage_report <logdir> <slug> <review-log> <scope-base> <scope-head>`:
    computes the scoped-diff file list (`git diff --name-only
    <scope-base>..<scope-head>`), passes it to `coverage_map_normalize`, then
    appends a
    `## Per-requirement coverage (<slug>, FR-78 — reported, advisory)` section
    to `$logdir/report.md` rendering the normalized lines as a table
    (`Requirement | Status | Evidence`), plus a one-line legend that an
    `unverified-gap` is a human-review finding, not an automatic block. Called
    once after the final review pass clears, before the flip/PR step. A failure
    to append warns to stderr and continues (report-only, never fails the
    build — NFR-4 honesty about its own non-essential nature).
- **`scripts/implement.sh`** — at each PR-creation site (sequential :550,
  per-TDD :625, parallel :453), after the existing `gh pr create --fill`
  succeeds and yields `$prurl`, post a one-line pointer as a PR COMMENT:
  `gh pr comment "$prurl" --body "<pointer>"`, where `<pointer>` names the
  `## Per-requirement coverage` section in the run's `report.md`. A PR comment
  is purely additive — it leaves the `--fill` body untouched, needs no switch to
  `--body`, and keeps the three sites in sync via a shared pointer string. The
  comment is best-effort: a failed `gh pr comment` warns and continues (the map
  still lands in `report.md`; only the PR convenience pointer is lost) — the one
  accepted degradation.

## Data & state
No new persistent state. The map is a derived artifact: it lives in `report.md`
(the run's existing report) and is recomputed on every build/resume from the
review log. It is NOT written into `state.d/*.json` and never gates a status
transition. On a resume that re-runs the final review, the section is
regenerated from the fresh review log (idempotent append: the writer replaces
any prior `## Per-requirement coverage (<slug>` section for the same slug rather
than duplicating).

## Sequencing / implementation plan
1. Add the `## Per-requirement coverage map` section to `review-prompt.md`
   (block format, status enum, cited-test rule, advisory framing).
2. Add `coverage_map_block` + `coverage_map_normalize` extractors to `gates.sh`
   with BOTH downgrades (`pinned-without-citation` shape check +
   `pinned-citation-not-in-diff` diff-presence check against the runner-derived
   `git diff --name-only` list).
3. Add `write_coverage_report` (computing the scoped-diff file list and passing
   it to the normalizer) and call it after the final review clears; wire the
   `report.md` section (idempotent per-slug replace).
4. Add the PR-body pointer helper in `implement.sh` at the three create sites.
5. Add `tests/coverage-map.test.sh` and register it in
   `tests/implement-gate.test.sh`.

## Failure modes & edge cases
Real risks:
- **Model emits `pinned` for a non-asserting test.** Mitigated structurally:
  `coverage_map_normalize` downgrades any `pinned` without a citation shape to
  `unverified-gap`; the citation must be a path present in the scoped diff.
- **Malformed / missing block** (build degraded to single-shot review, or the
  model omitted the fences). `coverage_map_block` returns empty; the report
  section renders "coverage map unavailable for this build" rather than a
  silent omission (NFR-4) — never a false "all covered".
- **Requirement id not in the traceability table.** The domain is exactly the
  table rows; a `COVERAGE:` line for an unknown id is dropped with a note in the
  report ("unlisted requirement <id> ignored").

Overblown risks:
- **Report.md write failure failing the build.** It cannot — the writer is
  report-only and warns-and-continues; the four gates own flip authority.

Unspoken risks (elephants):
- **The map reading as a gate to a human.** Mitigated by the mandatory legend
  line stating it is advisory and by its placement in `report.md` under a
  clearly-"reported" heading, never in the gate-verdict surface.

## Verification plan
- **Observable surface:** the run's `report.md` gains a
  `## Per-requirement coverage (<slug>, FR-78 — reported, advisory)` section,
  and the normalization downgrade is observable in that rendered table.
- **Observation point(s):**
  1. Feed `coverage_map_block` + `write_coverage_report` a fixture review log
     containing a `COVERAGE_MAP_BEGIN..END` block with one `pinned` (cited, file
     IN the fixture diff list), one `pinned` (NO citation), one `pinned` (cited,
     file NOT in the fixture diff list), one `justified-no-surface`, and one
     `unverified-gap` line, against a fixture `report.md`, `report` logdir, and
     a fixture scoped-diff file list.
  2. Run the extractor+writer (the functions are sourced from `gates.sh`, the
     same way `tests/implement-gate.test.sh` sources the lib under test).
- **Expected observations (PASS):**
  - `report.md` contains the `## Per-requirement coverage` heading and a table
    row for each requirement.
  - The cited-in-diff `pinned` row stays `pinned` with its `<file>::<name>`
    evidence; the uncited `pinned` row appears as `unverified-gap` note
    `pinned-without-citation`; the cited-but-not-in-diff `pinned` row appears as
    `unverified-gap` note `pinned-citation-not-in-diff` (both anti-false-green
    downgrades, model-independent).
  - The `justified-no-surface` row carries its skip reason and is NOT rendered
    as a gap.
  - A second invocation replaces (does not duplicate) the per-slug section.
  - Feeding a log with NO block yields a "coverage map unavailable" line, never
    a falsely-green "all covered".

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | every in-scope FR/NFR maps to a concrete named design element (sentinel/block/function/report section); gaps called out | all mapped, some terse | an FR untraced or hand-waved |
| Interface concreteness | exact marker/sentinel names, file paths, block format, status-enum values specified | mostly concrete, minor gaps | "emit a coverage block" with no format |
| Anti-false-green rigor | the pinned/proposed/justified-no-surface/unverified-gap distinction has a falsifiable mechanism (pinned requires a cited asserting test) | mechanism present | left to model discretion, no citation rule |
| No-conflict reconciliation | each new norm/lens explicitly reconciles with mandated duties (same-commit stale-doc update; ADR 0005/0006/0008) | reconciled | contradicts an existing instruction |
| Verification-plan actionability | observable surface + observation point + expected observation named (or justified SKIP) | present, somewhat generic | non-actionable — a vague verb instead of a named surface/observation |
| Scope-bound adherence | within body/diff/touched bounds or inline exceptions; estimates padded per the underestimation lesson | within bounds | blows a bound silently |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-78 (per-requirement map; 4 statuses) | `review-prompt.md` `COVERAGE_MAP` block with the status enum; `coverage_map_block`/`write_coverage_report` in `gates.sh` |
| FR-78 (cannot read falsely-green) | `coverage_map_normalize` downgrade of `pinned`-without-citation → `unverified-gap`; cited-test rule in the prompt |
| FR-78 (justified-SKIP ≠ gap) | `justified-no-surface` status carrying the skip reason; never rendered as a gap |
| FR-78 (reported, not a flip-blocker) | block emitted outside `REVIEW_RESULT:`; report-only writer; mandatory advisory legend (ADR 0005 — gates keep flip authority) |
| FR-78 (per-build scope) | domain = the landing TDD's `## Requirement traceability` rows; unlisted ids dropped |
| FR-78 (surfaced at the PR gate) | `report.md` section + one-line PR-body pointer |

## Dependencies considered
No new dependency. Considered a dedicated coverage `claude -p` pass (rejected:
adds a fifth per-build process and its own token cost for an artifact the review
pass can emit from inputs it already loads) and a runner-only mechanical
classifier without a model (rejected: deciding "this test asserts this
requirement" is a semantic judgment the review model is positioned to make, and
the citation rule keeps it falsifiable). `git`/`awk`/`grep` already present.

## PRD conflicts surfaced (and resolution)
None. FR-78 is additive and explicitly bounded (reported-not-gate, per-build).

## Decisions to promote (ADR candidates)
None. The "reported, not an auto-gate" stance is FR-78's own bounded scope and
is consistent with ADR 0005 (gate-scope authority) and ADR 0006 (artifact
grounding); no durable cross-cutting decision is added.

## Touched files
- scripts/review-prompt.md — emit the `COVERAGE_MAP` block (status enum + cited-test rule, advisory)
- scripts/lib/gates.sh — `coverage_map_block`/`coverage_map_normalize`/`write_coverage_report`; call after final review
- scripts/implement.sh — one-line PR-body pointer at the three `gh pr create` sites
- tests/coverage-map.test.sh — eval for extraction, normalization downgrade, report rendering
- tests/implement-gate.test.sh — register the new eval

## Expected diff size
- scripts/review-prompt.md — 60 lines
- scripts/lib/gates.sh — 95 lines
- scripts/implement.sh — 28 lines
- tests/coverage-map.test.sh — 230 lines
- tests/implement-gate.test.sh — 10 lines
Total expected diff: 423 lines across 5 files.

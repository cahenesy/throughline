# TDD 0063: Soft delegates and coprocess retirement

Status: draft
PRD refs: FR-22, FR-28, FR-30, FR-45, FR-64, FR-83, NFR-5
PRD-rev: 373cd89
ADR constraints: 0010
Supersedes: 0006

## Approach
Install no longer requires Superpowers or pr-review-toolkit. The
`claude -p` runner is not flip authority: `scripts/implement.sh` refuses
to run and tells the operator to use `/build-tdds`. `scripts/status.sh`
reads 0061 `run-record` (or prints "no active run" if the new record is
absent). README describes `/build-tdds` and optional delegates.

Eval files that exist only to prove stream-json / `BATCH_RESULT` /
`STEP_COMMIT` behavior are not rewritten in this TDD (file budget). They
stay in tree but are **not** invoked by `tests/implement-gate.test.sh`
after this TDD. A comment at the top of the aggregator lists them as
retired-with-coprocess.

## Components & interfaces
- `.claude-plugin/plugin.json` — delete the `dependencies` array (or
  leave it empty). Version bump is this TDD's last step.
- `.claude-plugin/marketplace.json` — remove
  `allowCrossMarketplaceDependenciesOn` and any per-plugin
  `dependencies` entries. Plugin still listed as `throughline`.
- `scripts/implement.sh` — replace the runner with a script that prints
  `throughline: scripts/implement.sh is retired; use /build-tdds` on
  stderr and exits 2. It must not spawn `claude` or `grok`.
- `scripts/implement-watch.sh` — same fail-closed (or delete if that is
  fewer lines than stubbing). Prefer stub so old skill text cannot
  silently nohup a missing file.
- `scripts/status.sh` — reads 0061 `run-record` with
  `<repo-root>=$(git rev-parse --show-toplevel)`. No active
  `latest/run.json` → print exactly `no active /build-tdds run` and
  exit 0. Otherwise print, in this order, ≤ 24 lines:
  1. `run <run_id>  <done>/<total>  ~<pct>% (estimate)`
  2. `current <slug>  stage=<status>  gate=<current_gate>`
  3. one line per queued TDD: `<slug> <status> [halt=<cause>]`
  4. `elapsed <updated_at-started_at>`
  5. `log <log_path>` and `pr <pr_url>` if non-empty
  If any TDD is `paused`: include the word `paused`, the `halt_cause`,
  and `re-run /build-tdds to resume` (FR-45). If any TDD is halted
  (`failed`/`blocked`/`paused`): also print `cause <halt_cause>`,
  `finding <evidence or halt_cause>`, `next /build-tdds | /tdd-author`
  (FR-64). Percent is labeled `estimate` and is never 100 until every
  queued TDD is `done`/`failed`/`blocked`/`skipped` (FR-30). No
  pause/resume/cancel verbs.
- `README.md` — replace `/implement` as the build command with
  `/build-tdds`; state Superpowers/pr-review-toolkit are optional.
- `tests/implement-gate.test.sh` — stop sourcing or executing retired
  coprocess evals. Keep calling `tests/plugin-root.test.sh`,
  `tests/verdicts.test.sh`, `tests/run-record.test.sh`,
  `tests/build-tdds-skill.test.sh` when those files exist.
- `docs/tdd/0006-governance-overlay-and-delegation.md` — `Status:
  superseded by 0063` only.

## Data & state
None new. Plugin manifests are install-time only.

## Sequencing / implementation plan
1. Stub `implement.sh` and `implement-watch.sh` (stderr + exit 2).
2. Retarget `status.sh` to `run-record.sh`.
3. Drop hard deps from both plugin manifests.
4. README `/build-tdds` + optional delegates.
5. Aggregator no longer runs coprocess-only evals; registers 0060–0062
   evals.
6. Flip 0006 Status. Bump `plugin.json` version (functional).

## Failure modes & edge cases
- **Real:** someone still runs `bash scripts/implement.sh` from muscle
  memory. Mitigation: exit 2 + explicit `/build-tdds` message (fail
  closed, L-011).
- **Real:** aggregator still listed as `CI_CHECKS_TEST_CMD`. After this
  TDD it must exit 0 without invoking `claude`. Mitigation: step 5.
- **Overblown:** deleting 40 eval files in this TDD. Out of scope;
  unhook them only.
- **Unspoken:** Claude Code users with the plugin already installed
  keep Superpowers from the previous hard dep. Uninstalling throughline
  does not uninstall Superpowers. No migration step.

## Verification plan
- **Surface:** plugin.json, implement.sh rc, README text, aggregator.
- **Observation points:**
  1. `jq -e '(.dependencies|length)==0 or .dependencies==null'
     .claude-plugin/plugin.json` exits 0.
  2. `bash scripts/implement.sh` exits 2; stderr contains
     `/build-tdds`; `ps` during the call shows no `claude`/`grok` child.
  3. `rg -n '^/implement' README.md` matches only historical mentions
     or the bundled-name collision note; the build-command table lists
     `/build-tdds`.
  3b. A fixture `latest/run.json` + one `paused` slug → `status.sh`
     stdout contains `paused`, `estimate`, and `re-run /build-tdds`;
     line count ≤ 24.
  4. `bash tests/implement-gate.test.sh` exits 0 and does not spawn
     `claude -p` (no `claude -p` in the executed script paths after the
     aggregator change).
  5. `docs/tdd/0006-governance-overlay-and-delegation.md` first
     `Status:` line is `superseded by 0063`.
- **PASS:** all five hold.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Traceability | Every in-scope FR/NFR maps to a named component | One compound mapping still checkable | Untraced or hand-waved FR |
| Interface concreteness | Paths, env vars, JSON fields, and command names are literal | One interface described by role not path | "the helper", "appropriate adapter" |
| Alternatives | Each new dep has a named rejected alternative | No new deps; section says why | New dep with empty alternatives |
| Verification plan | Surface + command/observation + PASS values | Observable but a bit indirect | "tests pass" / missing |
| Scope bounds | Touched files ≤8, estimates padded, exceptions declared | One justified exception | Over bound with no exception |
| Naming | Same concept same name across all four TDDs | One alias noted | /implement vs /build-tdds mixed as the required surface |
| Supervisor-free | No TDD requires parsing stream-json or nesting reviewers | Mentions old runner only as deletion target | Designs a coprocess as flip authority |

## Requirement traceability
- FR-22 / FR-83 / ADR 0010 → empty plugin dependencies
- FR-28 / FR-30 / FR-45 / FR-64 → `status.sh` output contract above
- NFR-5 → skills still load from plugin cache; scripts are not copied
  into consumer repos
- Coprocess retirement → implement.sh exit 2 (supports FR-82 by removing
  the old channel)

## Dependencies considered
No new deps. Rejected: keep empty `dependencies` that still name
Superpowers as optional — the Claude plugin schema has no optional tier
(0006 already noted this); absence is the optional encoding.

## PRD conflicts surfaced (and resolution)
None.

## Decisions to promote (ADR candidates)
ADR 0010 already accepted in this design PR.

## Touched files
- `.claude-plugin/plugin.json` — drop hard deps; version bump
- `.claude-plugin/marketplace.json` — drop cross-marketplace deps
- `scripts/implement.sh` — fail-closed stub
- `scripts/implement-watch.sh` — fail-closed stub
- `scripts/status.sh` — read run-record
- `README.md` — `/build-tdds` + optional delegates
- `tests/implement-gate.test.sh` — drop coprocess evals; add 0060–0062
- `docs/tdd/0006-governance-overlay-and-delegation.md` — Status line

## Expected diff size
- `.claude-plugin/plugin.json` — 20 lines
- `.claude-plugin/marketplace.json` — 20 lines
- `scripts/implement.sh` — 40 lines
- `scripts/implement-watch.sh` — 40 lines
- `scripts/status.sh` — 80 lines
- `README.md` — 60 lines
- `tests/implement-gate.test.sh` — 80 lines
- `docs/tdd/0006-governance-overlay-and-delegation.md` — 2 lines
Total expected diff: 342 lines across 8 files.

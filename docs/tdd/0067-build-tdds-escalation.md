# TDD 0067: `/build-tdds` retry and escalation to the most capable model (FR-88)

Status: draft
PRD refs: FR-88, FR-87, FR-15, FR-39, NFR-3, NFR-4
PRD-rev: f6ef178
ADR constraints: 0004, 0005, 0006, 0010, 0011, 0013, 0015, 0016

> **Revision 2 (2026-10-05)** resolves the BLOCKERS.md entry for run
> 20261005-174458. In that run, `fable` was refused headless
> (`credits_required`) and was silently run as `claude-opus-5-5`
> interactively. Outcomes are now judged by the model that actually ran
> (ADR 0016), and the probe now proves detection.

## Approach
FR-88 escalates a TDD's judgment workers to the escalation model
(`tl_escalation_model`, TDD 0064) in two cases:
- **requested:** `--escalate` or `THROUGHLINE_ESCALATE=1`.
- **auto:** a Retry of a TDD that halted on a gate `FAIL`, when its TDD
  file on the integration branch is byte-identical to the halt-time
  copy. The operator declines this with `--no-auto-escalate` or
  `THROUGHLINE_AUTO_ESCALATE=0`.

**Retry.** Step 3 used to resume only non-terminal TDDs, and a gate FAIL
is terminal. It now also offers **Retry** for every `failed`/`gate-fail`
TDD in the latest run. Retry re-dispatches the implementer on the
**existing** build branch, with the failed gate's report as input, then
re-runs every gate from test-first. It runs escalated when FR-88
applies, and on the parent model otherwise. This is a new invocation
triggered by a human, so ADR 0013 holds.

The escalation decision is made per TDD **before** the queue
confirmation and stored in the 0066 sidecar. The confirmation shows it,
and every later block reads it from the sidecar.

**The outcome reflects what ran, not what was asked for.** After each
escalated worker finishes, the parent reads the model that actually
answered from the worker's transcript (`tl_escalation_verify`).
- `escalated`: every answer came from the escalation family.
- `already-top`: the parent is already in that family.
- `fell-back`: the escalation did not hold. The cause is one of a
  dispatch error (including `credits_required`), no report and no work,
  `harness ran <id>`, `actual model unverified (<why>)`, or all judgment
  slots pinned. The TDD's remaining workers then inherit.

A substituted worker's output is kept: the work is valid, and only the
record changes. A fall-back is never inferred from an inactivity
timeout.

Stacks on 0064, 0065, and 0066, all merged.

## Components & interfaces
Every sidecar write goes through 0066's `_tl_models_write`; every value
through `tl_json_escape`.

**`scripts/lib/models.sh`**
- **`tl_resolve_models` / `tl_model_sources`** gain an optional third arg
  `[escalation-model]`.
  - When it is non-empty, every slot whose source would be `parent` uses
    that model, with source `escalation`: build, review, and a
    nontrivial verify.
  - Pins keep their pin. Mechanical verify keeps 0064's rule, plus the
    `pin:CLAUDE_CODE_SUBAGENT_MODEL` arm added in this build.
  - When the arg is absent, the output is byte-identical to 0064's.
- **`tl_escalation_outcome [parent-id] [tdd-path]`** prints
  `<outcome> <model>[ <reason>]`, where `<model>` = `tl_escalation_model`.
  - `fell-back <model> all judgment slots pinned` if no slot has source
    `parent`;
  - else `already-top <model>` if the parent is non-empty and in the same
    family as `<model>`;
  - else `escalated <model>`. An empty parent is never `already-top`.

  rc 0.
- **`tl_escalation_flags <args-text>`** prints
  `requested=<0|1> auto=<0|1>`.
  - `requested=1` iff a whitespace-split token is exactly `--escalate`,
    or `THROUGHLINE_ESCALATE=1`.
  - `auto=0` iff a token is exactly `--no-auto-escalate`, or
    `THROUGHLINE_AUTO_ESCALATE=0`.
  - It never reads `$@`.
- **`tl_models_confirm` / `tl_model_warnings`** (0066) gain
  `[escalation-model] [escalation-outcome]`. The model is forwarded as
  the third resolve arg. When the outcome is `escalated`, the
  confirmation adds `  escalation: escalated model=<m>`.
- **`tl_worker_actual_model <agent-id>`** (new) prints the distinct
  non-`<synthetic>` assistant `message.model` values from that worker's
  transcript, one per line, in order of first appearance.
  - On Claude, the transcript is the first match of
    `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/$CLAUDE_CODE_SESSION_ID/subagents/agent-<agent-id>.jsonl`.
  - Lines are parsed as JSON, never matched with a regex, using the same
    jq `fromjson?` → python3 cascade as `tl_parent_model`.
  - rc 0 when at least one value is found. Otherwise rc 1, nothing on
    stdout, and one stderr line `tl_worker_actual_model: <why>`, where
    `<why>` is one of:
    - `bad agent id` (the id must match `^[A-Za-z0-9]+$`);
    - `no session id`;
    - `bad session id` (it must match `^[A-Za-z0-9-]+$`; the config
      dir is quoted in the glob);
    - `transcript not found`;
    - `no json parser`;
    - `no model in transcript`;
    - `no worker artifact on this harness` (Grok).
- **`tl_escalation_verify <agent-id> <escalation-model>`** (new) prints
  `escalated` or `fell-back <reason>`.
  - `escalated` iff `tl_worker_actual_model` returns rc 0 and **every**
    value has the same `tl_model_family` as `<escalation-model>`.
  - Otherwise `fell-back harness ran <first non-matching id>`.
  - If `tl_worker_actual_model` returns rc 1:
    `fell-back actual model unverified (<why>)`.

  rc 0.

**`scripts/lib/run-record.sh`**
- **`tl_run_set_models`** (0066) gains a 6th arg `[escalation-model]`,
  forwarded to the resolve calls.
- **`tl_run_latest_run <repo>`** prints the basename of the target of
  `docs/tdd/.implement-logs/latest`. rc 1 if `latest` is absent or
  dangling.
- **`tl_run_retry_candidates <repo> <run>`** prints one slug per line for
  each `failed`/`gate-fail` fragment. rc 0 even when there are none;
  rc 2 on an invalid run.
- **`tl_run_failed_report <repo> <run> <slug>`** prints the report path
  of the first gate whose verdict is `FAIL`, in the order test-first,
  ci-checks, runtime-verify, review.
  - Reports are named `<run-dir>/<slug>.<build|ci-checks|verify|review>.txt`;
    test-first maps to `build`.
  - rc 1 if no gate failed or the file is missing.
- **`tl_run_retry_begin <repo> <run> <slug>`**:
  1. copies the failed report to `<report>.prev.txt`;
  2. moves every `*.json` verdict in `tl_verdict_dir` into `retry-<N>/`,
     where `N` is the highest existing number + 1 (reports are never
     moved);
  3. sets the fragment to `building`;
  4. prints `report=<path>` first, then `implementer_report=<prev path>`,
     then the archive dir.

  After it runs, `tl_run_next_gate` returns `test-first`. rc 1 on an io
  error.
- **`tl_run_set_halt_blob <repo> <run> <slug> <tdd-relpath>`** writes
  `halt_tdd_blob` = `git rev-parse <integ>:<tdd-relpath>`, using
  `_tl_integration_ref` from `verdicts.sh`. If the path can't be
  resolved: rc 1, nothing written, and stderr
  `run-record: cannot resolve <tdd-relpath> on <integ>`.
- **`tl_escalation_decide <repo> <run> <slug> <tdd-relpath> <requested> <auto>`**
  prints `requested`, `auto` or `none`:
  - `requested=1` → `requested`;
  - else `auto=0` → `none`;
  - else `auto` iff the fragment is `failed`/`gate-fail`, at least one
    verdict reads `FAIL`, and the sidecar's `halt_tdd_blob` is non-empty
    and equals the current integration blob;
  - else `none`.

  rc 2 on a usage error.
- **`tl_run_set_escalation <repo> <run> <slug> <outcome> <model> [reason]`**
  - `<outcome>` must be `escalated`, `already-top` or `fell-back`;
    anything else is rc 2.
  - Writes the `escalation`, `escalation_model` and `escalation_reason`
    keys.
  - Prints `throughline: <slug> escalation=<outcome> model=<model>`,
    followed by ` reason=<reason>` when a reason is given.
- **`tl_escalation_fellback_check <report-path> <worktree> <base-sha> <worker>`**
  prints `ok` or `fell-back <reason>`:
  - empty or missing report → `fell-back no report`;
  - implementer with an empty report and no commits since `<base-sha>` →
    `fell-back no report, no commits`;
  - implementer with commits but an empty report → `ok`. This is a real
    failure, not a fall-back.

**`skills/implement/SKILL.md`**

Every new block follows 0066's block contract: it sources its own
helpers, recomputes `TL_PARENT`, and takes inputs only from `${VAR:?}`
env vars.
- **Step 1, `<!-- tl:escalation-flags -->`**.
  - Input: `TL_ARGS`, the skill's argument text. Empty is valid; unset
    fails.
  - It prints `tl_escalation_flags "$TL_ARGS"`. The parent passes the
    two values on as `TL_REQUESTED` and `TL_AUTO`.
- **Step 3.**
  - Run `<!-- tl:retry-candidates -->` (input `TL_REPO`). It prints
    `run=<id>` and the candidate slugs from `tl_run_latest_run` and
    `tl_run_retry_candidates`, or nothing when there is no `latest`.
  - Ask the step-3 question if the latest run has non-terminal TDDs
    **or** any slug was printed.
  - The options are Resume, **Retry** and Start fresh.
- **Retry, per slug:**
  1. Reuse `.worktrees/build-tdds-<slug>`, or `git worktree add` it from
     `build/<run>/<slug>`. If the branch is missing, refuse Retry and
     point to Start fresh.
  2. Run the decide block, then `<!-- tl:retry-begin -->` (inputs
     `TL_REPO`, `TL_RUN`, `TL_SLUG`).
  3. Run step 5, then step 7. The implementer prompt is prefixed "A
     previous gate FAILED. Fix what this report found on the existing
     branch; do not start over." and is given `implementer_report`.
  4. Run every gate from 8a.
- **Step 4/5, `<!-- tl:escalation-decide -->`**.
  - Inputs: `TL_REPO`, `TL_RUN`, `TL_SLUG`, `TL_REQUESTED`, `TL_AUTO`.
    It derives `docs/tdd/$TL_SLUG.md` itself.
  - On `requested` or `auto`: run `tl_escalation_outcome`, print
    `trigger=<requested|auto>`, then run `tl_run_set_escalation`.
  - On `none`: do nothing.
- **Steps 5 and 7.** 0066's confirm and record blocks read the sidecar.
  The record block passes `escalation_model` as the 6th arg **only** when
  `escalation` is `escalated`.
- **After each judgment worker of an `escalated` TDD.** The parent has
  the worker's agent id from the Agent tool result. It runs
  `<!-- tl:escalation-verify -->` with inputs `TL_REPO`, `TL_RUN`,
  `TL_SLUG`, `TL_AGENT_ID`, `TL_REPORT`, `TL_WT`, `TL_BASE_SHA` and
  `TL_WORKER`, and takes the first match:
  1. **Transient error** (FR-41): a rate- or usage-limit pattern, or rc
     143/130 → `paused`. The exception is a `credits_required` /
     "requires usage credits" refusal of the escalation model: that is a
     fall-back, not a pause.
  2. **Dispatch error.** The dispatch tool returned an error, or
     `tl_escalation_fellback_check` printed `fell-back`. Record
     `fell-back` with that reason, re-run the record block, and
     re-dispatch the worker with **no model parameter**.
  3. **Otherwise**, run `tl_escalation_verify`.
     - `fell-back`: record it, keep the worker's output, and re-run the
       record block so the TDD's later workers inherit.
     - `escalated`: leave the record unchanged.

  A failed completion notification counts as a dispatch error. The
  outcome recorded last is final. Once the TDD has fallen back, its
  inherited workers are never verified, so they cannot overwrite that
  record.
- **Halt rule.** After `tl_run_set_tdd … failed gate-fail`, run
  `tl_run_set_halt_blob`. If it fails, print its stderr; the halt still
  completes.
- **Usage line.** Add `--escalate` and `--no-auto-escalate`.
- **Wording fix.** The `CLAUDE_CODE_SUBAGENT_MODEL` note now says it
  applies to "every worker dispatched without a model parameter".

**`tests/live/escalation-probe.sh`** is a live probe that runs in the
runtime-verify gate only, never in `ci-checks`. Its job is to prove the
detection works, whatever models the account can use.
- **How it runs:**
  - Two headless sessions:
    `claude -p --model opus --output-format stream-json --verbose`.
  - Each session dispatches one general-purpose subagent with the prompt
    `Reply with exactly <nonce>`.
  - The probe handles both stream shapes: sync (a tool_result) and async
    (a launch acknowledgement followed by a `task_notification`).
  - It finds the worker's agent id in the stream and runs
    `tl_escalation_verify <agent-id> <requested>`.
- **P1:** model = `tl_escalation_model`, overridable with
  `THROUGHLINE_ESCALATION_MODEL`. PASS iff the verdict matches what the
  transcript shows:
  - an answer from the requested family that returns the nonce →
    `escalated`;
  - a refusal, including `credits_required` → dispatch error →
    `fell-back`;
  - an answer from another family → `fell-back harness ran <id>`.
- **P2:** model = `claude-nonexistent-0`. PASS iff the dispatch is
  refused with `is_error`, which is what the fall-back rule relies on.
- **P3 (positive control):** model = `opus`, the parent's own alias.
  PASS iff the agent id is found, `tl_worker_actual_model` returns a
  non-empty id, and `tl_escalation_verify <id> opus` → `escalated`. This
  exercises the live transcript reader even when P1 is refused. If no
  transcript is found: exit 3.
- For each verify call, the probe exports `CLAUDE_CODE_SESSION_ID` as the
  headless child's `session_id` from its `system/init` event.
- **Exit codes:**
  - 0 when all three pass. Prints
    `P<n> requested=<m> actual=<id|refused> verdict=<v>` per probe.
  - 3 with `PROBE_BLOCKED: <observation>` when P3's, or an answered
    P1's, actual model can't be determined.
  - 1 when a classification disagrees with the transcript, the stream is
    malformed, or a session-wide limit was hit (the cause is named).
- Scratch files live in a `mktemp -d` dir that a trap cleans up.

## Data & state
The sidecar keys are declared in 0066. Retry writes `retry-<N>/` and
`<report>.prev.txt`. Worker transcripts are read-only.

## Sequencing / implementation plan
1. `models.sh` — resolve arg, outcome/flags, confirm args, verify arm, actual-model check.
2. `run-record.sh` — 6th arg, latest/candidates/report/retry-begin, halt blob, decide, setter, fallback check.
3. `skills/implement/SKILL.md` — five blocks, Retry, post-worker check, halt blob, usage, wording.
4. `tests/escalation.test.sh`, registered in `tests/implement-gate.test.sh`.
5. `tests/live/escalation-probe.sh`.

## Failure modes & edge cases
**Real risks**
- **Silent substitution.** The harness ran Opus when Fable was requested,
  with no error. Mitigated by `tl_escalation_verify`, which reads the
  model that actually answered. The live reader is proven by P3, and
  substitution classification by obs 11 and 13.
- **Undocumented transcript layout.** The `subagents/agent-<id>.jsonl`
  layout is observed, not documented. If it changes, every escalation
  records `fell-back actual model unverified (transcript not found)`.
  That is honest, and the probe exits 3 rather than passing.
- **Alias-only dispatch.** The dispatch `model` parameter accepts only
  aliases, so a full-id binding fails at dispatch and becomes a
  `fell-back`. A pinned full id fails the normal way.
- **Spec fault mistaken for model fault.** Auto escalation fires only on
  an unchanged TDD blob, and it can be declined. A revert back to the
  same bytes counts as unchanged; this is accepted.

**Overblown risks**
- Redoing finished work. The implementer fixes on the existing branch,
  and test-first sees the old `test(failing):` commit.
- A Mythos parent with a Fable binding records an honest `harness ran`.
  The two are the same tier.

**Unspoken risks**
- **Decide runs before the confirmation.** `escalation=escalated` is
  written before the operator confirms, so stopping at the confirmation
  leaves a stale record. Accepted: the record is per-run and is rewritten
  at dispatch.
- **Stop after `tl:retry-begin`.** The fragment is `building`, so the TDD
  shows as Resume rather than Retry, and auto no longer applies.
  Accepted: the verdicts are kept in `retry-<N>/`, and `--escalate` still
  works.
- **Non-escalated retries change too** (implementer + all gates; chosen in interview).
- **Grok.** There is no worker artifact, so a Grok escalation records
  `fell-back … unverified`. The first worker still runs escalated, so the
  record under-reports.
- **Unknown-family override.** An override outside the known families
  never matches, so it always records `fell-back harness ran …`. Honest.
- **Probe cost.** The probe runs three tiny headless sessions, in the verify gate only.

## Verification plan
- **Surface:** the stdout and rc of the functions, the sidecar, the
  stdout of the extracted blocks, and the probe's exit code and output.
- **Harness:**
  - Functions run under `env -i HOME=<tmp> PATH="$PATH" bash -c '…'`.
  - Each case uses a temp git repo whose integration branch is `master`,
    with one committed TDD (and a mechanical one where needed).
  - The run is built through the real `tl_run_init`, `tl_run_set_tdd` and
    `tl_verdict_write`.
  - Fixture worker transcripts live at
    `<tmp>/.claude/projects/<p>/<sid>/subagents/agent-<id>.jsonl`, with
    `CLAUDE_CODE_SESSION_ID=<sid>` and `CLAUDE_CONFIG_DIR=<tmp>/.claude`
    set.
  - Blocks run with only `TL_*` env vars, and no positional args.
- **Observation points → expected (PASS):**
  1. **Resolution with escalation:**
     - `tl_resolve_models <nontrivial> claude-opus-5-5 fable` →
       `build=fable review=fable verify=fable`, with source `escalation`
       ×3.
     - With `THROUGHLINE_REVIEW_MODEL=opus`, review keeps its pin.
     - A mechanical TDD → `verify=sonnet verify_src=light`.
     - An empty third arg → output byte-equal to the 2-arg form.
     - A light parent, a mechanical TDD and
       `CLAUDE_CODE_SUBAGENT_MODEL=opus` →
       `verify=opus verify_src=pin:CLAUDE_CODE_SUBAGENT_MODEL`.
  2. `tl_escalation_outcome`:
     - opus parent → `escalated fable`;
     - fable parent → `already-top fable`;
     - empty parent → `escalated fable`;
     - build and review pinned, with a mechanical TDD →
       `fell-back fable all judgment slots pinned`.
  3. `tl_escalation_flags`:
     - `--escalate` → `requested=1 auto=1`;
     - `--no-auto-escalate` → `auto=0`;
     - `""` with `THROUGHLINE_AUTO_ESCALATE=0` → `auto=0`;
     - `--escalatex` → `requested=0`.
  4. A fixture that is `failed`/`gate-fail`, with `review.json` at `FAIL`,
     a halt blob, and an unchanged TDD → it is a retry candidate, and
     decide prints `auto`.
  5. As 4, plus an edit to the TDD committed on `master` → `none`.
  6. `none` when the fragment is `blocked`/`design-escalation` (and it is
     not a candidate), when it is `failed` with only PASS verdicts, or
     when there is no halt blob.
  7. As 4 with `auto=0` → `none`. `requested=1` on a clean fragment →
     `requested`.
  8. `tl_run_set_escalation … fell-back x 'dispatch error: "x" \ y'`:
     - the printed line is exact;
     - the sidecar JSON is valid, the reason round-trips, and 0066's keys
       are intact;
     - outcome `maybe` → rc 2.
  9. `tl_escalation_fellback_check`:
     - empty report → `fell-back no report`;
     - implementer with no commits → `fell-back no report, no commits`;
     - implementer with a commit → `ok`;
     - non-empty report → `ok`.
  10. `tl_worker_actual_model`:
      - a fixture with two opus lines, a `<synthetic>` line and a
        truncated line → `claude-opus-5-5`, rc 0;
      - fable then opus → both, in that order;
      - `../x` → rc 1 `bad agent id`;
      - no session id → `no session id`;
      - `a/b` → `bad session id`;
      - no file → `transcript not found`;
      - `GROK_PLUGIN_ROOT` set → `no worker artifact on this harness`.
  11. `tl_escalation_verify <id> fable`:
      - opus-only → `fell-back harness ran claude-opus-5-5`;
      - `tl_escalation_verify <id> opus` with an opus-only transcript →
        `escalated` (alias↔id family match, used by P3);
      - fable-only → `escalated`;
      - fable then opus → `fell-back harness ran claude-opus-5-5`;
      - missing → `fell-back actual model unverified (transcript not found)`.
  12. **Extracted blocks:**
      - `tl:escalation-flags` with `TL_ARGS='--escalate'` →
        `requested=1 auto=1`; `TL_ARGS` unset → rc ≠ 0, naming it;
        `TL_ARGS=''` → `requested=0 auto=1`.
      - `tl:retry-candidates` on an all-terminal fixture with `latest` →
        `run=<id>` and the slug; with no `latest` → nothing, rc 0.
      - `tl:retry-begin` on fixture 4:
        - first line `report=<run-dir>/<slug>.review.txt`;
        - a `.prev.txt` copy exists;
        - `retry-1/` holds the three verdicts;
        - the fragment is `building` and `tl_run_next_gate` →
          `test-first`;
        - a second call → `retry-2/`.
      - `tl_run_failed_report` with all PASS → rc 1; with the report
        deleted → rc 1.
  13. **The blocks chained on fixture 4:**
      - `tl:escalation-decide` with `TL_AUTO=1` and an opus parent
        transcript → `trigger=auto` and
        `escalation=escalated model=fable`, and the sidecar records it.
      - Then 0066's `tl:models-confirm` contains
        `  escalation: escalated model=fable` and
        `implementer: fable [escalation]`.
      - Then `tl:escalation-verify`, with `TL_AGENT_ID` pointing at an
        opus-only worker transcript and a non-empty `TL_REPORT` → the
        sidecar has `escalation=fell-back` with reason
        `harness ran claude-opus-5-5`, and a re-run `tl:models-record`
        shows `implementer: inherit`.
  14. **Text check.** Reason: dispatch-tool behaviour can't be executed
      in a test. `skills/implement/SKILL.md` contains `Retry`,
      `--escalate`, `--no-auto-escalate`, `no model parameter`,
      `transient`, `credits_required` and `tl_escalation_verify`. The
      file is asserted readable first.
  15. **Live probe** (runtime-verify only): run
      `bash tests/live/escalation-probe.sh` once with the default
      binding.
      - Exit 0 → PASS. Each line shows requested, actual and verdict. On
        this account P1 is expected to be refused → `fell-back`, and P3
        must show `actual=claude-opus-…` → `escalated`.
      - Exit 3 → BLOCKED.
      - Exit 1 → FAIL.
- A missing marker or an unreadable file counts as `bad` (L-001, L-011).

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement traceability | Every in-scope FR/NFR (NFR-3, FR-10, FR-15(d), FR-52, FR-86, FR-87, FR-88) maps to a named function, skill step, or run-record field | One mapping indirect but named | An in-scope requirement missing or hand-waved |
| interface concreteness | Every new helper (`tl_resolve_models`, `tl_parent_model`, tier placement, run-record setters) has its signature, stdout format, and return codes pinned | One helper's error return implicit | A reader cannot tell what a helper prints or returns |
| executable verification | Every skill snippet and helper the design adds is run by an eval, not only grepped; missing file / empty output / grep exit 2 is infra-fail, never ok | One check is text-only with a stated reason | A snippet is pinned in prose but never executed (the 0064 failure) |
| alternatives-analysis substance | Each new mechanism names ≥1 concrete rejected alternative with reason (live fetch, rank table, frontmatter effort, rebuild-on-escalate) | One rejection thin | None given |
| verification-plan actionability | Surface, observation points, PASS values named, including the live fell-back probe and its BLOCKED rule | One fixture underspecified | Missing or non-actionable |
| scope-bound adherence | Each TDD ≤8 files, ≤500 body lines; estimates padded; exceptions declared | One justified inline exception | Over a bound with no exception |
| naming consistency | `inherit`, `light`, `escalation`, `escalated`/`already-top`/`fell-back`, `parent=unknown` spelled identically across all four TDDs and ADR 0015 | One synonym | Same concept named two ways |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-88 all judgment workers together | third resolve arg |
| FR-88 (a) request / decline auto | `tl_escalation_flags` |
| FR-88 (b) auto on unchanged-TDD gate FAIL | Retry + `tl_run_set_halt_blob` + `tl_escalation_decide`; obs 4–7 |
| FR-88 resume/recover entry | widened step 3 + Retry; obs 12 |
| FR-88 pins keep their pin | resolution rule; all-pinned → `fell-back`; obs 1–2 |
| FR-88 design-reviewer never escalated | escalation only in `/build-tdds` |
| FR-88 maintained binding + override | `tl_escalation_model` (0064) |
| FR-88 outcome recorded, one line | `tl_run_set_escalation`; obs 8 |
| FR-88 escalated model shown in confirmation | decided before step 5; obs 13 |
| FR-88 outcomes reflect what actually ran | `tl_worker_actual_model` + `tl_escalation_verify` (ADR 0016); obs 10–11, 13; live P3 |
| FR-88 fall-back at dispatch, never by timeout | dispatch error / fallback check / verify; obs 9, 15 |
| FR-88 effort inherited | no effort change (0066) |
| FR-87 pins win | pinned slots keep `pin:<ENV>`; `CLAUDE_CODE_SUBAGENT_MODEL` arm |
| FR-15 all gates on retry | Retry runs from 8a |
| FR-39 interrupted Retry resumes safely | `tl_run_retry_begin` → `test-first`; obs 12 |
| NFR-3 only escalated TDDs go above the parent | `requested`/`auto` only |
| NFR-4 no false record | actual-model check; unverified → `fell-back`; probe BLOCKED/FAIL, never a false PASS |

## Dependencies considered
No new libraries.

For the new mechanism, reading the actual model from the worker
transcript, two alternatives were rejected:
- **Trusting the requested model.** That is the defect this revision
  fixes.
- **Asking the worker to state its model.** That is self-report, not an
  artifact (ADR 0006).

Rejections carried forward from revision 1: a rebuild on escalate
(fix-forward is the practice); re-running only the failed gate;
`--fallback-model` (main session only, and it hides which model ran);
detecting fall-back by timeout; and running `/build-tdds` headless for
the probe (the skill is interactive).

## PRD conflicts surfaced (and resolution)
- **Resume path:** FR-88 assumes one exists after a gate FAIL. Step 3's
  Retry provides it (finding M1).
- **Detection timing:** FR-88 says "detected when the worker fails to
  start or is refused". This design also detects after the worker
  completes, from its transcript, and treats an unverifiable actual
  model as a fall-back. Resolved by **ADR 0016** in favour of NFR-4;
  widening that FR-88 sentence is a candidate for a later PRD pass.
- **BLOCKERS.md, run 20261005-174458:** resolved by revision 2.

## Decisions to promote (ADR candidates)
**ADR 0016** (this PR): escalation outcomes are judged by the model that
actually ran, and an unverifiable model counts as fell-back. It revises
ADR 0015's "detected at dispatch" consequence.

## Touched files
- `scripts/lib/models.sh` — escalation arg, outcome, flags, confirm args, actual-model check, subagent-model verify arm
- `scripts/lib/run-record.sh` — latest run, retry candidates/report/begin, halt blob, decide, escalation setter, fall-back check
- `skills/implement/SKILL.md` — Retry, escalation + verify blocks, confirm/record wiring, halt blob, usage
- `tests/escalation.test.sh` — functions + extracted blocks on a fixture repo
- `tests/implement-gate.test.sh` — register the new eval
- `tests/live/escalation-probe.sh` — live detection probe

## Expected diff size
- `scripts/lib/models.sh` — 240 lines
- `scripts/lib/run-record.sh` — 260 lines
- `skills/implement/SKILL.md` — 280 lines
- `tests/escalation.test.sh` — 950 lines (exception: one cohesive eval over a shared fixture repo; 15 observation points; 779 lines already on the retained branch)
- `tests/implement-gate.test.sh` — 15 lines
- `tests/live/escalation-probe.sh` — 290 lines
Total expected diff: 2035 lines across 6 files.

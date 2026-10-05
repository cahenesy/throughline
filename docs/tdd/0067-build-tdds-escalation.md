# TDD 0067: `/build-tdds` retry and escalation to the most capable model (FR-88)

Status: draft
PRD refs: FR-88, FR-87, FR-15, FR-39, NFR-3, NFR-4
PRD-rev: f6ef178
ADR constraints: 0004, 0005, 0006, 0010, 0011, 0013, 0015

## Approach
FR-88 escalates a TDD's judgment workers to the escalation model
(`tl_escalation_model`, TDD 0064) in two cases:

- **requested:** the operator passes `--escalate` or sets
  `THROUGHLINE_ESCALATE=1` for the run.
- **auto:** a retry of a TDD whose halt carries a gate `FAIL` verdict,
  while its TDD file on the integration branch is byte-identical to the
  halt-time copy. The operator declines it with `--no-auto-escalate` or
  `THROUGHLINE_AUTO_ESCALATE=0`.

**There is no retry path today.** Step 3 resumes only non-terminal
TDDs. A gate `FAIL` halt is `failed`, which is terminal, and a fresh run
re-queues the TDD from scratch on a new branch. So this TDD adds
**Retry** to step 3 for every `failed` / `gate-fail` TDD in the latest
run. Retry:
- re-dispatches the implementer on the **existing** build branch, with
  the failed gate's report as input;
- then re-runs **every** gate from test-first;
- runs on the escalation model when FR-88 applies, and on the parent
  model otherwise.

This replaces "re-enter at the failed gate on unchanged code", which
rarely changes the outcome. It is a new, human-triggered invocation,
so ADR 0013's no-in-invocation-rework rule holds.

The escalation decision is made per TDD **before** the queue
confirmation and stored in the 0066 sidecar. So the confirmation shows
the escalated model before dispatch (FR-87, FR-88), and every later
block reads that TDD's escalation from the sidecar, never from a
run-wide variable.

Each escalation ends in exactly one outcome. It is printed as one line
and recorded in the sidecar:
- `escalated`: the workers ran on the escalation model.
- `already-top`: the parent is already in the escalation family.
- `fell-back`: the escalation model was unusable (dispatch error, or no
  report and no work), or every judgment slot is pinned. The workers
  ran on the parent model or their pins, and the reason is recorded.

A fall-back is never detected by an inactivity timeout.

Stacks on 0064, 0065, 0066.

## Components & interfaces
**`scripts/lib/models.sh`**
- `tl_resolve_models` / `tl_model_sources` gain an optional third arg
  `[escalation-model]`. When non-empty, every slot whose source would be
  `parent` becomes that model with source `escalation` (build, review,
  nontrivial verify). Pins keep their pin. Mechanical verify keeps the
  0064 rule. With the arg absent, output is byte-identical to 0064.
- `tl_escalation_outcome [parent-id] [tdd-path]` prints one line,
  `<outcome> <model>[ <reason>]`, where `<model>` = `tl_escalation_model`.
  Rules, in order:
  - `fell-back <model> all judgment slots pinned` when
    `tl_model_sources <tdd-path> <parent>` has no slot with source
    `parent`;
  - else `already-top <model>` iff the parent is non-empty and its
    `tl_model_family` equals `<model>`'s;
  - else `escalated <model>`.

  An empty (unreadable) parent is never `already-top`. rc 0.
- `tl_escalation_flags <args-text>` prints one line,
  `requested=<0|1> auto=<0|1>`. `<args-text>` is the skill's argument
  string, split on whitespace.
  - `requested=1` iff a token is exactly `--escalate`, or env
    `THROUGHLINE_ESCALATE` is `1`.
  - `auto=0` iff a token is exactly `--no-auto-escalate`, or env
    `THROUGHLINE_AUTO_ESCALATE` is `0`.
  - Default `requested=0 auto=1`. It never reads `$@`. rc 0.
- `tl_models_confirm` / `tl_model_warnings` (0066) gain optional
  `[escalation-model] [escalation-outcome]`. The model is forwarded as
  the third resolve arg. When the outcome is non-empty, the confirmation
  adds the line `  escalation: <outcome> model=<escalation-model>`.

**`scripts/lib/run-record.sh`** (every write goes through 0066's
`_tl_models_write`; values through `tl_json_escape`)
- `tl_run_set_models` (0066) gains an optional 6th arg
  `[escalation-model]`, forwarded as the third resolve arg.
- `tl_run_retry_candidates <repo> <run>` prints one slug per line for
  each `<slug>.json` with `status` `failed` and `halt_cause`
  `gate-fail`. rc 0, including when there are none; rc 2 on an invalid
  run.
- `tl_run_latest_run <repo>` prints the run id that
  `docs/tdd/.implement-logs/latest` points to (the basename of its
  resolved target). rc 1 with no output when `latest` is absent or
  dangling.
- `tl_run_retry_begin <repo> <run> <slug>` starts a Retry cleanly. It
  moves every verdict file in `tl_verdict_dir <repo> <run> <slug>` into
  `<that dir>/retry-<N>/` (`N` = 1 + the highest existing `retry-*`),
  then runs `tl_run_set_tdd <repo> <run> <slug> building`. It prints the
  archive dir. rc 0; rc 1 on an io error, with nothing moved if the
  `mkdir` fails. After it runs, `tl_run_next_gate` returns `test-first`,
  so an interrupted Retry resumes from the first gate, never past gates
  on changed code.
- `tl_run_failed_report <repo> <run> <slug>` prints the report path
  for the first gate, in order test-first, ci-checks, runtime-verify,
  review, whose verdict reads `FAIL`. Report names follow the
  convention the run dir already uses, which this TDD makes explicit
  in the skill: `<run-dir>/<slug>.<build|ci-checks|verify|review>.txt`,
  where test-first maps to `build`. rc 1 with no output when no
  verdict is FAIL or the file is missing. `tl_run_retry_begin` moves
  only the `*.json` verdict files out of the verdict dir; report
  `.txt` files live in the run dir root and are never moved, so the
  path stays valid.
- `tl_run_set_halt_blob <repo> <run> <slug> <tdd-relpath>` writes
  `halt_tdd_blob` = `git -C <repo> rev-parse <integ>:<tdd-relpath>`,
  with `<integ>` = `_tl_integration_ref <repo>` (from `verdicts.sh`, which
  `run-record.sh` already sources at load). If that can't be
  resolved: rc 1, nothing written, stderr
  `run-record: cannot resolve <tdd-relpath> on <integ>`.
- `tl_escalation_decide <repo> <run> <slug> <tdd-relpath> <requested> <auto>`
  prints `requested`, `auto`, or `none`. Rules, in order:
  - `requested=1` → `requested`;
  - else `auto=0` → `none`;
  - else `auto` iff all of these hold:
    - the fragment is `failed` / `gate-fail`;
    - at least one verdict file reads `FAIL`;
    - the sidecar `halt_tdd_blob` is non-empty and equals the current
      integration blob;
  - else `none`.

  rc 0; rc 2 on a usage error.
- `tl_run_set_escalation <repo> <run> <slug> <outcome> <model> [reason]`
  - `<outcome>` must be `escalated|already-top|fell-back`; anything else
    → rc 2.
  - Writes `escalation`, `escalation_model`, and `escalation_reason`.
  - Then prints `throughline: <slug> escalation=<outcome> model=<model>`,
    plus ` reason=<reason>` when a reason was given.
- `tl_escalation_fellback_check <report-path> <worktree> <base-sha> <worker>`
  prints `ok` or `fell-back <reason>`. `<worker>` is
  `implementer|verify|review`.
  - Missing or empty report → `fell-back no report`.
  - Implementer with an empty report **and** an empty
    `git rev-list <base-sha>..HEAD` → `fell-back no report, no commits`.
  - Implementer with commits but an empty report → `ok`. That is a real
    failure, classified by the normal rules.

  rc 0.

**`skills/implement/SKILL.md`** — every new block obeys 0066's block
contract: self-contained, sources its own helpers, recomputes
`TL_PARENT`, and reads inputs from `${VAR:?}` env vars.
- Step 1, block `<!-- tl:escalation-flags -->`:
  - Input `TL_ARGS` is the skill's argument text; the parent sets it
    from the invocation arguments.
  - The block prints `tl_escalation_flags "$TL_ARGS"`.
  - The parent keeps the two values and passes them later as
    `TL_REQUESTED` / `TL_AUTO`.
- Step 3's trigger widens. Step 3 first runs block
  `<!-- tl:retry-candidates -->` (input `TL_REPO` only). The block
  derives the run itself with `tl_run_latest_run "$TL_REPO"`, prints
  `run=<id>` and then one slug per line from `tl_run_retry_candidates`,
  or prints nothing when there is no `latest`.
  - The step-3 question is asked when the latest run has a non-terminal
    TDD **or** the block printed at least one slug. Before this change it
    was asked only for non-terminal TDDs, so an all-`failed` run was
    never offered anything.
  - Options: Resume (non-terminal), **Retry** (the listed slugs), and
    Start fresh.

  Retry for a slug:
  1. Reuse `.worktrees/build-tdds-<slug>` if it exists. Otherwise run
     `git worktree add` from the existing branch `build/<run>/<slug>`.
     If the branch is missing, refuse Retry for that TDD and point to
     Start fresh.
  2. Record the failed gate's report path with `tl_run_failed_report`
     (in the `tl:retry-begin` block, before archiving; it prints
     `report=<path>` first). Run the escalation-decide
     block (below), which reads the halt-time verdicts. Then run block
     `<!-- tl:retry-begin -->` (inputs `TL_REPO`, `TL_RUN`, `TL_SLUG`),
     which calls `tl_run_retry_begin`. Then step 5's confirmation, then
     step 7. The implementer prompt is prefixed with
     "A previous gate FAILED. Fix what this report found on the existing
     branch; do not start over." and given the failed gate's report path
     under the run dir.
  3. Then run every gate from 8a; each one overwrites its verdict file.
- Step 4/5, block `<!-- tl:escalation-decide -->`, once per queued or
  retried TDD. Inputs: `TL_REPO`, `TL_RUN`, `TL_SLUG`, `TL_REQUESTED`,
  `TL_AUTO`. The block derives the repo-relative path
  `docs/tdd/$TL_SLUG.md` itself, which is the form `tl_escalation_decide`
  and `tl_run_set_halt_blob` take, and uses `$TL_REPO/docs/tdd/$TL_SLUG.md`
  for `tl_escalation_outcome`.
  - If `tl_escalation_decide` prints `requested` or `auto`, the block
    runs `tl_escalation_outcome "$TL_PARENT" "$TL_TDD"` and then
    `tl_run_set_escalation` with that outcome, model, and reason. Before
    that line it prints `trigger=<requested|auto>`.
  - If it prints `none`, the block prints nothing and writes nothing.
- Step 5: 0066's `tl:models-confirm` block reads each slug's sidecar
  `escalation` / `escalation_model` (via `tl_run_get_model_field`) and
  passes them to `tl_models_confirm` / `tl_model_warnings`.
- Step 7: 0066's `tl:models-record` block passes the sidecar
  `escalation_model` as the 6th arg **only when** the sidecar
  `escalation` is `escalated`. Dispatch uses that TDD's resolved slots.
- Fall-back (prose), for each judgment worker of a TDD whose sidecar
  `escalation` is `escalated`:
  1. Apply the existing FR-41 transient rule first: a rate/usage-limit
     pattern or rc 143/130 → `paused`, not a fall-back.
  2. Otherwise, if the dispatch tool returned an error, or
     `tl_escalation_fellback_check` prints `fell-back`:
     - run `tl_run_set_escalation … fell-back <model> "<reason>"`, with
       the reason `dispatch error: <first line>` or the check's reason;
     - re-run the `tl:models-record` block (it now passes no
       escalation);
     - re-dispatch the same worker with **no model parameter**.

  `base-sha` is the build-branch HEAD read just before the implementer
  dispatch.
- Halt rule: after `tl_run_set_tdd … failed gate-fail`, run
  `tl_run_set_halt_blob "$TL_REPO" "$TL_RUN" "$TL_SLUG" "docs/tdd/<slug>.md"`.
  If it fails, print its stderr. The halt still completes; auto is then
  unavailable for that TDD.
- Usage line: add `--escalate` and `--no-auto-escalate`.

**`tests/live/escalation-probe.sh`**: a live harness probe, run only by
the runtime-verify worker (not by `ci-checks`). It answers the
undocumented question directly: what does a subagent dispatch on a
given model do?

How it runs:
- Two headless sessions:
  `claude -p --model opus --output-format stream-json --verbose "<prompt>"`.
- Each prompt dispatches exactly one general-purpose subagent with a
  stated `model` and the prompt `Reply with exactly <nonce>`, where
  `<nonce>` is a fresh random hex string.
- The script reads the **tool_result** event for that Agent tool_use.
  It is authored by the harness or subagent, never by the parent model.

The two probes:
- **P1:** `model` = `tl_escalation_model` (the operator may set
  `THROUGHLINE_ESCALATION_MODEL`). PASS iff the tool_result contains
  the nonce and `is_error` is not true.
- **P2:** `model` = `claude-nonexistent-0`. PASS iff the tool_result is
  `is_error: true` or lacks the nonce. That is the signal the fall-back
  rule relies on.

Exit codes:
- 0: both pass.
- 3, printing `PROBE_BLOCKED: <observation>`: P1 failed (the escalation
  binding is unusable on this account, as with Fable in June), or P2
  returned the nonce (the harness silently substituted a model, so the
  fall-back is undetectable).
- 1: no tool_result found (malformed run).

The scratch dir comes from `mktemp -d` and is cleaned up by a trap.

## Data & state
Sidecar keys used: `escalation`, `escalation_model`, `escalation_reason`,
`halt_tdd_blob` (declared in 0066). A Retry overwrites verdict files.
The only other new file is the probe script.

## Sequencing / implementation plan
1. `models.sh`: third resolve arg, `tl_escalation_outcome`,
   `tl_escalation_flags`, confirm/warnings extra args.
2. `run-record.sh`: 6th arg on `tl_run_set_models`,
   `tl_run_retry_candidates`, `tl_run_set_halt_blob`,
   `tl_escalation_decide`, `tl_run_set_escalation`,
   `tl_escalation_fellback_check`.
3. `skills/implement/SKILL.md`: flags, retry-candidates, and
   escalation-decide blocks; the Retry flow; confirm/record wiring;
   fall-back prose; halt blob; usage.
4. `tests/escalation.test.sh` (functions + extracted blocks on a
   fixture repo); register it in `tests/implement-gate.test.sh`; add
   `tests/live/escalation-probe.sh`.

## Failure modes & edge cases
**Real risks**
- **Silent model substitution.** The harness may quietly run a
  different model in place of an unusable one, and nothing local can
  detect that. The probe exists to find out: if P2 returns the nonce,
  this TDD halts `BLOCKED`, not `PASS`.
- **Alias-only dispatch.** On this harness the Agent dispatch `model`
  parameter accepts only family aliases (observed: `sonnet`, `opus`,
  `haiku`, `fable`). A full-id escalation binding or pin fails at
  dispatch. For escalation that is a `fell-back` with the dispatch error
  as the reason, which is honest. For a pin it is the normal worker
  failure (the 0066 failure mode).
- **Spec fault mistaken for a model fault.** Auto fires only on an
  unchanged TDD blob, and the operator can decline it. A TDD edited and
  then reverted byte-for-byte counts as unchanged (accepted).
- **Flaky gate.** A flaky `ci-checks` FAIL followed by an unchanged
  Retry auto-escalates once. The confirmation shows
  `escalation: escalated` before dispatch, and the operator can stop or
  pass `--no-auto-escalate`.
- **Build branch deleted.** Retry refuses that TDD and points to Start
  fresh.

**Overblown risks**
- **Redone work.** The escalated implementer could redo finished work,
  but the prompt says to fix on the existing branch, and test-first
  re-observes the existing `test(failing):` commit from git history.
- **Mythos parent.** A Mythos parent with a Fable binding records
  `escalated` because the family names differ. Both are the same tier,
  so this is harmless.

**Unspoken risks**
- The decide block writes `escalation=escalated` before the operator
  confirms. If the operator then stops, the run's sidecar says
  `escalated` although nothing ran. This is accepted: the sidecar is
  per-run, it is rewritten at dispatch, and the fragment shows nothing
  was dispatched.
- If the operator stops at the confirmation after `tl:retry-begin`,
  the fragment is already `building` and the verdicts are archived.
  The TDD then shows up as Resume rather than Retry, and auto no
  longer applies to it. This is accepted: the halt-time verdicts are
  kept in `retry-<N>/`, and `--escalate` still works.
- **Non-escalated retries change too.** Retry now runs the implementer
  plus all gates, instead of the failed gate alone. That is intended:
  it was chosen in the design interview.
- **Probe cost.** The live probe spends real tokens: two tiny headless
  sessions per verification, in the runtime-verify gate only.

## Verification plan
- **Surface:** stdout/rc of the new functions; sidecar contents; stdout
  of each extracted skill block; the probe's exit code and output.
- **Harness:**
  - Functions run in `env -i HOME=<tmp> PATH="$PATH" bash -c '…'`
    against a temp git repo.
  - The repo has integration branch `master`, one committed TDD, and a
    run initialized through the real `tl_run_init`, `tl_run_set_tdd`,
    and `tl_verdict_write`.
  - Extracted blocks run with only `TL_*` env vars and no positional
    args.
- **Observation points → expected (PASS):**
  1. `tl_resolve_models <nontrivial> claude-opus-5-5 fable` → `build=fable review=fable verify=fable`, with sources `escalation` ×3.
     - With `THROUGHLINE_REVIEW_MODEL=opus` → `review=opus review_src=pin:THROUGHLINE_REVIEW_MODEL`.
     - A mechanical TDD → `verify=sonnet verify_src=light`.
     - An empty third arg → output byte-equal to the two-arg call.
  2. `tl_escalation_outcome`:
     - `claude-opus-5-5 <tdd>` → `escalated fable`;
     - `claude-fable-5-1` → `already-top fable`;
     - an empty parent → `escalated fable`;
     - `THROUGHLINE_BUILD_MODEL=opus THROUGHLINE_REVIEW_MODEL=opus` with a mechanical TDD → `fell-back fable all judgment slots pinned`.
  3. `tl_escalation_flags`:
     - `"--escalate"` → `requested=1 auto=1`;
     - `"--no-auto-escalate"` → `requested=0 auto=0`;
     - `""` with `THROUGHLINE_AUTO_ESCALATE=0` → `auto=0`;
     - `"--escalatex"` → `requested=0`.
  4. A fragment that is `failed`/`gate-fail`, with `review.json` `FAIL`, a recorded halt blob, and the TDD unchanged → `tl_run_retry_candidates` lists the slug, and `tl_escalation_decide` prints `auto`.
  5. As 4, then commit an edit to the TDD on `master` → `none`.
  6. Not auto-escalated:
     - As 4 but the fragment is `blocked`/`design-escalation` → not a retry candidate, and `none`.
     - `failed` with only PASS verdicts → `none`.
     - No halt blob → `none`.
  7. As 4 with `auto=0` → `none`. `requested=1` on a clean fragment → `requested`.
  8. `tl_run_set_escalation … fell-back claude-nonexistent-0 'dispatch error: "x" \ y'` → stdout `throughline: 0099-x escalation=fell-back model=claude-nonexistent-0 reason=dispatch error: "x" \ y`.
     - The sidecar is valid JSON, the reason round-trips, and 0066's `build` key is intact.
     - Outcome `maybe` → rc 2.
  9. `tl_escalation_fellback_check`:
     - empty report → `fell-back no report`;
     - implementer, empty report, no commits → `fell-back no report, no commits`;
     - implementer, a commit, empty report → `ok`;
     - non-empty report → `ok`.
  10. Extracted `tl:escalation-flags` with `TL_ARGS='--escalate'` → stdout `requested=1 auto=1`. Without `TL_ARGS` → rc ≠ 0, naming `TL_ARGS`.
  11. Extracted `tl:retry-candidates` with only `TL_REPO`:
      - fixture 4, made **all-terminal** (every fragment `failed`) and with
        `latest` → its run → prints `run=<id>` and the slug;
      - no `latest` → prints nothing, rc 0.
  11b. `tl_run_retry_begin` on fixture 4, whose verdicts are test-first
       PASS, ci-checks PASS, and review FAIL:
       - the verdict dir now holds only `retry-1/` containing all
         three files;
       - the fragment `status` is `building`;
       - `tl_run_next_gate` → `test-first`.

       A second call → `retry-2/`. Extracting and running
       `tl:retry-begin` gives the same result, and its first line is
       `report=<run-dir>/<slug>.review.txt`.
  11c. `tl_run_failed_report` on fixture 4 → `<run-dir>/<slug>.review.txt`.
       With every verdict PASS → rc 1 and no output. With the FAIL
       verdict's report file deleted → rc 1.
  12. Extracted `tl:escalation-decide` on fixture 4, with `TL_REQUESTED=0 TL_AUTO=1` and a fixture transcript whose parent is `claude-opus-5-5`:
      - stdout contains `trigger=auto` and `escalation=escalated model=fable`, and the sidecar records it;
      - then the extracted 0066 `tl:models-confirm` block for that TDD contains `  escalation: escalated model=fable` and `implementer: fable [escalation]`.
  13. Text check. Stated reason: it covers dispatch-tool behavior and the interactive menu, which an eval cannot execute. `skills/implement/SKILL.md` contains `Retry`, `--escalate`, `--no-auto-escalate`, `no model parameter`, and `transient`, with the file asserted readable first.
  14. **Live probe** (runtime-verify gate only): `bash tests/live/escalation-probe.sh`.
      - Exit 0 → PASS.
      - Exit 3 (`PROBE_BLOCKED`) → `VERIFY_RESULT: BLOCKED`, never PASS.
      - Exit 1 → FAIL.
- A missing marker block or an unreadable file is `bad` (L-001, L-011).

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
| FR-88 all judgment workers together | third resolve arg (build, review, nontrivial verify) |
| FR-88 (a) operator request | `tl_escalation_flags` (`--escalate` / `THROUGHLINE_ESCALATE=1`) |
| FR-88 (b) auto on unchanged-TDD gate FAIL | Retry path + `tl_run_set_halt_blob` + `tl_escalation_decide`; observations 4–7 |
| FR-88 resume or recover entry | widened step 3 + Retry via `tl_run_latest_run` / `tl_run_retry_candidates`; observation 11 |
| FR-39 interrupted Retry resumes safely | `tl_run_retry_begin` archives verdicts → `tl_run_next_gate` = `test-first`; observation 11b |
| FR-88 decline auto | `--no-auto-escalate` / `THROUGHLINE_AUTO_ESCALATE=0` |
| FR-88 pins keep their pin | resolution rule; all-pinned → `fell-back`; observations 1–2 |
| FR-88 design-reviewer never escalated | escalation only in `/build-tdds`; 0064 `model: inherit` |
| FR-88 maintained binding + override | `tl_escalation_model` (0064) |
| FR-88 outcome recorded + one line | `tl_run_set_escalation`; observation 8 |
| FR-88 escalated model in confirmation | decided before step 5; confirm extra args; observation 12 |
| FR-88 already-top | family match; observation 2 |
| FR-88 fall-back at start, not timeout | dispatch error / `tl_escalation_fellback_check`, transient first; probe 14 |
| FR-88 effort inherited | no effort change on escalation (0066 rules) |
| FR-87 pins win over escalation | pinned slots keep `pin:<ENV>` |
| FR-15 all gates on retry | Retry runs every gate from 8a |
| FR-39 resume after interruption | Retry is a resume variant for `failed`/`gate-fail` |
| NFR-3 only escalated TDDs go above the parent | escalation only via `requested`/`auto` |
| NFR-4 | unreadable parent never `already-top`; probe BLOCKED, never PASS |

## Dependencies considered
No new libraries. Rejected alternatives:
- **Rebuild from scratch on escalation.** It discards reviewed work; the
  project's halt-recovery practice is to fix forward on the retained
  branch.
- **Re-run only the failed gate, escalated.** A stronger reviewer
  reading unchanged code rarely changes the verdict.
- **Claude Code `--fallback-model`.** It governs the main session's API
  calls, not subagent dispatch, and would hide which model ran.
- **Fall-back by inactivity timeout.** The June outage cost about 30
  minutes per attempt.
- **A probe that runs `/build-tdds` headless.** The skill asks
  interactive questions (Resume/Retry, confirm queue). Dispatching a
  subagent directly answers the actual unknown.

## PRD conflicts surfaced (and resolution)
FR-88 assumes a resume path exists for a gate-FAIL halt. The thin
`/build-tdds` (TDD 0062) resumes only non-terminal TDDs. Resolved here
with step 3 Retry, which the design interview chose after
design-review finding M1. No PRD edit is needed: FR-88 says "resume or
recover", and Retry is that entry.

## Decisions to promote (ADR candidates)
Covered by ADR 0015 (escalation trigger and outcomes). Retry
(implementer fix plus all gates on the existing branch) is recorded
there as a consequence.

## Touched files
- `scripts/lib/models.sh` — escalation arg, outcome, flags, confirm/warnings args
- `scripts/lib/run-record.sh` — latest run, retry candidates, retry begin, halt blob, decide, escalation setter, fall-back check
- `skills/implement/SKILL.md` — widened step 3, Retry + retry-begin, escalation blocks, confirm/record wiring, fall-back, halt blob, usage
- `tests/escalation.test.sh` — functions + extracted blocks on a fixture repo
- `tests/implement-gate.test.sh` — register the new eval
- `tests/live/escalation-probe.sh` — live subagent-dispatch probe

## Expected diff size
- `scripts/lib/models.sh` — 85 lines
- `scripts/lib/run-record.sh` — 235 lines
- `skills/implement/SKILL.md` — 125 lines
- `tests/escalation.test.sh` — 390 lines (exception: one cohesive eval over a shared fixture repo; 16 observation points)
- `tests/implement-gate.test.sh` — 12 lines
- `tests/live/escalation-probe.sh` — 120 lines
Total expected diff: 937 lines across 6 files.

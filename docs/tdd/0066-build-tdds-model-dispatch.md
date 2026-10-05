# TDD 0066: `/build-tdds` model dispatch, confirmation, and run record

Status: implemented
PRD refs: FR-87, FR-52, FR-15, NFR-3, NFR-4
PRD-rev: f6ef178
ADR constraints: 0004, 0005, 0006, 0010, 0011, 0013, 0015

## Approach
TDD 0064 decides each slot's model (`inherit`, a pin, or the light
binding). This TDD makes `/build-tdds` act on those decisions and show
them:

- The queue confirmation names, per TDD, the parent model, the effort,
  and each worker's model and source before anything is dispatched
  (FR-87).
- `inherit` means the parent dispatches the worker **without** a model
  parameter; anything else is passed as the model.
- Warnings: a judgment slot pinned to the light tier (FR-87); any
  per-worker effort pin (unsupported on this harness, per the PRD open
  question on effort).
- Effort is recorded honestly: workers run at the session effort.
  Mechanical verify records `low requested`, with the session effort
  applied.
- A per-TDD sidecar `<run>/<slug>.models.json` records what was used.
  It is separate from `<slug>.json` because `tl_run_set_tdd` and
  `tl_run_set_pr` rewrite that fragment with a fixed key set and would
  drop new keys (the 0038 carry-forward class).

Every rendering and warning rule is a function in `models.sh` or
`run-record.sh`. The skill calls them from marker-tagged blocks that
the eval extracts and runs.

Stacks on 0064 and 0065. Escalation (FR-88) is TDD 0067, which reuses
this sidecar.

## Components & interfaces
**`scripts/lib/models.sh` additions**

| Function | Args | stdout | rc |
|---|---|---|---|
| `tl_dispatch_model_arg` | `<value>` | empty for `inherit`; otherwise `<value>` | 0 |
| `tl_model_warnings` | `[tdd-path] [parent-id]` | zero or more warning lines (below), in order build, review, effort pins | 0 |
| `tl_models_confirm` | `<slug> [tdd-path] [parent-id]` | the confirmation block (below) | 0 |

TDD 0067 appends optional `[escalation-model] [escalation-outcome]` to
`tl_models_confirm` and `tl_model_warnings`; with them absent the output
is exactly as specified here.

Warning lines (exact text):
- Light pin, for build and review only, when that slot's source is
  `pin:<ENV>` and `tl_model_tier <value>` is `light`:
  `throughline: <ENV>=<value> puts the <implementer|reviewer> on the light tier; continuing`
- Effort pin, for each of `THROUGHLINE_BUILD_EFFORT`,
  `THROUGHLINE_REVIEW_EFFORT`, `THROUGHLINE_RUNTIME_VERIFY_EFFORT` that
  is non-empty:
  `throughline: <ENV>=<value> ignored: per-worker effort is not supported on this harness (workers run at the session effort)`
- A pin to a non-light model emits nothing. A mechanical verify on the
  light binding emits nothing.

Confirmation block (`<p>` = parent id or `unknown`; `<e> <s>` from
`tl_parent_effort`; `<m>` rendered as `inherit (<p>)` when the value is
`inherit`, else the id):
```
models <slug>: parent=<p> effort=<e> (<s>; session-wide)
  implementer: <m> [<build_src>]
  reviewer: <m> [<review_src>]
  runtime-verify (<class>): <m> [<verify_src>]
```
When `<class>` is `mechanical`, the verify line ends with
` effort=low requested; session effort applies`.

**`scripts/lib/run-record.sh` additions** — sidecar
`$logs/<run>/<slug>.models.json`, one JSON object with exactly these
keys (all strings, empty when unset):
`parent, effort, effort_source, build, build_src, build_model, review,
review_src, review_model, verify, verify_src, verify_model, verify_class,
escalation, escalation_model, escalation_reason, halt_tdd_blob`
(17 keys). `<slot>` keeps the dispatch value (`inherit` or an id);
`<slot>_model` is the model that slot actually runs on: the parent id
when the value is `inherit` (or `unknown` when the parent is
unreadable), else the value. Every value is written through the
existing `tl_json_escape`.

| Function | Args | Effect | rc |
|---|---|---|---|
| `_tl_models_write` | `<repo> <run> <slug> <key>=<val>…` | read the existing sidecar (if any), overlay the given keys, write **all 17 keys** atomically via `_tl_run_atomic`; unknown key → rc 2, nothing written | 0 / 1 io / 2 usage |
| `tl_run_set_models` | `<repo> <run> <slug> <tdd-path> [parent-id]` | resolves via `tl_resolve_models`, `tl_model_sources`, `tl_plan_class`, `tl_parent_effort`; writes the model/effort keys and the three `<slot>_model` keys; `parent` = id or `unknown`. TDD 0067 adds an optional 6th arg `[escalation-model]` | as above |
| `tl_run_get_model_field` | `<repo> <run> <slug> <key>` | prints the key's value (`tl_json_field`) | 0; 1 if no sidecar |

Slug and run id are validated with the existing `_tl_valid_slug` /
`_tl_valid_run` before any path is built.

**`skills/implement/SKILL.md` changes**
- **Block contract (every marker block in this skill).** The harness
  runs each Bash call in a fresh shell, so no block may rely on a
  variable or function from an earlier call. Each block starts with the
  0065 block's two source lines (plugin-root, `models.sh`, fail closed)
  plus a third, `run-record.sh`, in the same fail-closed form. 0065's
  identical-bytes rule covers only the `tl:fr86-check` block and computes
  `TL_PARENT="$(tl_parent_model 2>/dev/null)" || TL_PARENT=""` itself.
  Inputs come only from env vars read with `${VAR:?VAR required}` so a
  missing input fails loudly: `TL_REPO` (absolute repo root), `TL_RUN`
  (run id), `TL_SLUG`, `TL_TDD` (TDD path), `TL_QUEUE` (newline-separated
  TDD paths). The skill prose tells the parent to prefix the block with
  `export TL_REPO=… TL_RUN=…` lines carrying the real values; the eval
  supplies them the same way.
- Step 5 (confirm queue): before the structured question, run the
  block tagged `<!-- tl:models-confirm -->`, which loops the queued TDD
  paths and prints `tl_models_confirm <slug> <path> "$TL_PARENT"`
  then `tl_model_warnings <path> "$TL_PARENT"` for each path in
  `TL_QUEUE` (inputs: `TL_QUEUE`). The question shows that output
  verbatim.
- Step 7 (implementer), start: block tagged `<!-- tl:models-record -->`
  (inputs: `TL_REPO`, `TL_RUN`, `TL_SLUG`, `TL_TDD`) runs
  `tl_run_set_models "$TL_REPO" "$TL_RUN" "$TL_SLUG" "$TL_TDD" "$TL_PARENT"`
  and appends `implementer model=<build> (src=<build_src>)` to the
  per-TDD log. Dispatch rule (prose, all three workers): "Model =
  `tl_dispatch_model_arg <slot value>`. If that prints nothing, dispatch
  the worker with **no model parameter** so it inherits this session's
  model. Otherwise pass exactly that string."
- Step 9: append `runtime-verify model=<verify> (plan=<verify_class>)`
  to the per-TDD log before dispatch (FR-52 acceptance).
- Step 10: delete "on the prior-gen top-tier model"; the reviewer uses
  the `review=` slot. Append `reviewer model=<review> (src=<review_src>)`.
- Notes "Models:" bullet: cite ADR 0015; list the pins, the effort-pin
  warning, and the sidecar path.

## Data & state
New file per TDD per run: `docs/tdd/.implement-logs/<run>/<slug>.models.json`
(gitignored with the rest). `<slug>.json` is unchanged. Per-TDD log gains
three `… model=` lines. Env read: the three model pins,
`CLAUDE_CODE_SUBAGENT_MODEL`, the three new effort-pin names.

## Sequencing / implementation plan
1. `models.sh`: `tl_dispatch_model_arg`, `tl_model_warnings`,
   `tl_models_confirm`.
2. `run-record.sh`: `_tl_models_write`, `tl_run_set_models`,
   `tl_run_get_model_field`.
3. `skills/implement/SKILL.md`: block contract, step 5
   `tl:models-confirm` block, step 7 `tl:models-record` block and the
   dispatch rule, step 9/10 log lines, Notes.
4. `tests/model-dispatch.test.sh` (functions + extracted blocks);
   register in `tests/implement-gate.test.sh`. `README.md`: the
   `models.sh` tree comment, the models paragraph, and every
   "different model" review claim (reword to "fresh worker").

## Failure modes & edge cases
**Real risks**
- The parent LLM passes `model: "inherit"` literally instead of
  omitting the parameter. Mitigation: `tl_dispatch_model_arg` returns
  empty for `inherit`, and the prose says "no model parameter". This is
  the one rule an eval can only check as text (stated in the
  verification plan); 0067's live probe observes a real dispatch.
- Sidecar written by two setters (0066 models, 0067 escalation):
  `_tl_models_write` always rewrites all 17 keys from the overlay of
  old + new, so neither setter drops the other's keys (eval
  observation 9).
- Parent unreadable but the operator chose Continue (0065): `parent`
  = `unknown`, mechanical verify `parent-cap` inherit, confirmation says
  `parent=unknown`.

- A pin set to a full model id (`claude-opus-5-5`) where the harness's
  dispatch `model` parameter accepts only aliases (observed: `sonnet`,
  `opus`, `haiku`, `fable`): the dispatch errors and the worker fails
  through the normal rules, with the error visible. The README models
  paragraph states that pins are harness model aliases.

**Overblown risks**
- Effort reported from `settings.json` while the session used
  `/effort`: the confirmation says `(settings; session-wide)`, so it is
  labeled as the saved level.
- `--parallel` mode writes several sidecars at once: one file per slug,
  atomic rename, no shared file.

**Unspoken risks**
- The confirmation is the operator's only cost signal before dispatch.
  A Fable parent silently makes every judgment worker Fable (accepted
  in the PRD); the confirmation must therefore never be skipped. The
  step 5 prose states it is printed even when the queue has one TDD.

## Verification plan
- **Surface:** stdout/rc of the new functions; the sidecar file
  contents; stdout of the two extracted skill blocks; per-TDD log lines.
  Functions run in `env -i HOME=<tmp> PATH="$PATH" bash -c '. models.sh; . run-record.sh; …'`
  against a temp git repo with an initialized run (`tl_run_init`).
- **Observation points → expected (PASS):**
  1. `tl_dispatch_model_arg inherit` → empty; `tl_dispatch_model_arg sonnet` → `sonnet`.
  2. No pins, parent `claude-opus-5-5`, nontrivial fixture TDD, `CLAUDE_CODE_EFFORT_LEVEL=high` → `tl_models_confirm 0099-x <tdd> claude-opus-5-5` prints exactly:
     `models 0099-x: parent=claude-opus-5-5 effort=high (env; session-wide)` / `  implementer: inherit (claude-opus-5-5) [parent]` / `  reviewer: inherit (claude-opus-5-5) [parent]` / `  runtime-verify (nontrivial): inherit (claude-opus-5-5) [parent]`.
  3. Mechanical fixture, same parent → verify line `  runtime-verify (mechanical): sonnet [light] effort=low requested; session effort applies`.
  4. Same TDD started from parent `claude-fable-5-1` → implementer and reviewer lines show `inherit (claude-fable-5-1)` (FR-87 "different model `M2`").
  5. `THROUGHLINE_REVIEW_MODEL=sonnet` → `tl_model_warnings` prints exactly `throughline: THROUGHLINE_REVIEW_MODEL=sonnet puts the reviewer on the light tier; continuing`; `THROUGHLINE_REVIEW_MODEL=opus` → no output.
  6. `THROUGHLINE_BUILD_EFFORT=max` → exactly the effort-ignored line naming `THROUGHLINE_BUILD_EFFORT=max`.
  7. Mechanical verify on the light binding with no pins → `tl_model_warnings` prints nothing.
  8. `tl_run_set_models` (5 args) then `cat <run>/0099-x.models.json` → valid JSON with all 17 keys; `build=inherit`, `build_src=parent`, `build_model=claude-opus-5-5`, `review_model=claude-opus-5-5`, `parent=claude-opus-5-5`, `verify_class` matches the fixture. Same from parent `claude-fable-5-1` → `build_model=claude-fable-5-1` (FR-87 `M2`). Unreadable parent → `parent=unknown`, `build_model=unknown`.
  9. `_tl_models_write … escalation=escalated` after step 8, then `tl_run_set_models` again → both `escalation=escalated` and `build=inherit` present (no key dropped). Unknown key `foo=1` → rc 2 and the file unchanged (sha before = after). A value containing `"` and `\` round-trips through `tl_run_get_model_field` unchanged and the file stays valid JSON.
  10. `tl_run_set_tdd … failed gate-fail` after step 8 → sidecar unchanged (it is a separate file).
  11. Extract the first fenced bash block after `<!-- tl:models-confirm -->` in `skills/implement/SKILL.md` and run it as `env -i HOME=<tmp> PATH="$PATH" CLAUDE_PLUGIN_ROOT=<repo> CLAUDE_CONFIG_DIR=<tmp>/.claude CLAUDE_CODE_SESSION_ID=<sid> TL_QUEUE=<fixture-tdd> bash <extracted.sh>` (no positional args, no pre-sourced functions) → stdout begins `models ` and contains `implementer: inherit`. Without `TL_QUEUE` → rc ≠ 0 and stderr names `TL_QUEUE`. Marker missing or file unreadable → `bad`.
  12. Same harness for `<!-- tl:models-record -->` with `TL_REPO`, `TL_RUN`, `TL_SLUG`, `TL_TDD` → the sidecar exists afterwards and the per-TDD log contains `implementer model=inherit (src=parent)`.
  13. Text check (the one non-executable rule, stated reason: it instructs the harness's dispatch tool): `skills/implement/SKILL.md` contains `no model parameter` and `tl_dispatch_model_arg`, and does not contain `prior-gen` (file-readable precheck first).
- **PASS:** 1–13 hold.

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
| FR-87 judgment workers inherit | dispatch rule (`tl_dispatch_model_arg` → no model parameter) |
| FR-87 pins win | 0064 resolution, shown with `[pin:<ENV>]` |
| FR-87 light-pin warning; non-light pin silent | `tl_model_warnings`; observations 5, 7 |
| FR-87 effort pins | effort-ignored warning (harness has no per-worker effort); observation 6 |
| FR-87 queue confirmation names model + effort | `tl_models_confirm` in the `tl:models-confirm` block; observations 2–4, 11 |
| FR-87 run record | sidecar via `tl_run_set_models`; observations 8–10, 12 |
| FR-52 light tier, low effort, log line | verify line + `effort=low requested`; `runtime-verify model=… (plan=…)` log line |
| FR-15(d) reviewer on the TDD's judgment model | reviewer uses the `review=` slot; prior-gen prose removed |
| NFR-4 honesty | effort labeled with its source; `parent=unknown`; unsupported pins named |
| NFR-3 operator owns cost/performance via the parent | inherit dispatch + confirmation shows the parent's model before dispatch |

## Dependencies considered
No new libraries. Rejected: **add keys to `<slug>.json`** (two existing
writers rewrite it with a fixed key set and would drop them).
Rejected: **an agent definition with an `effort:` frontmatter field
for mechanical verify** (not a documented Claude Code agent field;
silently ignored would make the record lie). Rejected: **pass the
parent's observed id explicitly on every dispatch** instead of
omitting the parameter (breaks when the parent is unreadable; ignores
`CLAUDE_CODE_SUBAGENT_MODEL` semantics already handled as a pin).

## PRD conflicts surfaced (and resolution)
FR-87 says an effort pin "wins". On Claude Code no per-worker effort
exists; the PRD's open question defers the degradation to design.
Resolution: the pin is reported as ignored, by name, every run.

## Decisions to promote (ADR candidates)
Covered by ADR 0015.

## Touched files
- `scripts/lib/models.sh` — dispatch arg, warnings, confirmation rendering
- `scripts/lib/run-record.sh` — models sidecar writer/reader
- `skills/implement/SKILL.md` — confirmation, record, dispatch rule, log lines
- `tests/model-dispatch.test.sh` — functions, sidecar, extracted blocks
- `tests/implement-gate.test.sh` — register the new eval
- `README.md` — models.sh comment, models paragraph, and the five stale "different model" claims (lines ~72, ~126, ~281, ~333, ~449)

## Expected diff size
- `scripts/lib/models.sh` — 95 lines
- `scripts/lib/run-record.sh` — 95 lines
- `skills/implement/SKILL.md` — 70 lines
- `tests/model-dispatch.test.sh` — 290 lines
- `tests/implement-gate.test.sh` — 12 lines
- `README.md` — 45 lines
Total expected diff: 607 lines across 6 files.

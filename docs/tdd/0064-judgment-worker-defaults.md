# TDD 0064: Model roles and parent-model observation

Status: draft
PRD refs: NFR-3, FR-52, FR-87, FR-10, FR-15, FR-50
PRD-rev: f6ef178
ADR constraints: 0004, 0005, 0006, 0010, 0011, 0013, 0015
Supersedes: 0057; 0062 (the `scripts/lib/models.sh` contract only — the rest of 0062 stands)

## Approach
The PRD bar is now best cost/performance per job (NFR-3). throughline no
longer picks the judgment model: judgment slots resolve to `inherit`
(the worker runs on the parent session's model). Only two product names
remain, both maintained bindings in `scripts/lib/models.sh`: the
**light** tier (mechanical runtime-verify, FR-52) and the **escalation**
target (FR-88, consumed by TDD 0067). Pins still win.

This TDD is the shell core the other three TDDs call. It owns every
model decision as an executable function, so a skill never re-derives a
rule in prose (the 0064-rev1 halt: a pinned skill snippet that no eval
ever ran). It also owns observing the parent session's model, because
the FR-52 cap ("light is never above the parent") needs it here, before
TDD 0065's FR-86 check reuses it.

It also flips the FR-10 design-reviewer to `model: inherit` and removes
"different model" wording from `/tdd-author` 7b and `plugin.json`.

Out of scope: FR-86 skill blocks (0065); `/build-tdds` dispatch, queue
confirmation, warnings, run record (0066); escalation (0067).

## Components & interfaces
All functions live in `scripts/lib/models.sh`. No top-level side effects
except the four binding assignments. Product names appear only on these
four lines:
```
_TL_CLAUDE_LIGHT=sonnet
_TL_CLAUDE_ESCALATION=fable
_TL_GROK_LIGHT=grok-4.5        # unverified this pass (see Failure modes)
_TL_GROK_ESCALATION=grok-4.6   # unverified this pass
```
`models.sh` sources `plan-classifier.sh` by sibling path with the repo's
FATAL-on-missing idiom (`{ [ -r "$f" ] && . "$f"; } || { echo FATAL… >&2;
return 1 2>/dev/null || exit 1; }`).

| Function | Args | stdout | rc |
|---|---|---|---|
| `tl_model_harness` | — | `claude` or `grok` (`grok` iff `GROK_PLUGIN_ROOT` non-empty) | 0 |
| `tl_light_model` | — | the harness light binding | 0 |
| `tl_escalation_model` | — | `$THROUGHLINE_ESCALATION_MODEL` if non-empty, else the harness escalation binding | 0 |
| `tl_model_family` | `<id>` | Claude: lowercase id; the first of `mythos fable opus sonnet haiku` that is a substring, else the lowercased id. Grok: lowercased id | 0; empty id → no output, rc 1 |
| `tl_model_tier` | `<id>` | `light` when `tl_model_family <id>` equals `tl_model_family "$(tl_light_model)"`, or (Claude) equals `haiku`; `above` otherwise; `unknown` for an empty id | 0 |
| `tl_parent_model` | — | the parent session's model id, one line | 0 found; 1 unreadable (no stdout; one stderr line `tl_parent_model: <reason>`) |
| `tl_parent_effort` | — | `<level> <source>`: `<level> env` from `CLAUDE_CODE_EFFORT_LEVEL`, else `<level> settings` from `effortLevel` in `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`, else `unknown -`. Grok: `unknown -` | 0 |
| `tl_plan_class` | `[tdd-path]` | `mechanical` or `nontrivial`. Path given → `tl_classify_plan <path>`; classifier rc≠0 or no path → `nontrivial` (conservative) | 0 |
| `tl_resolve_models` | `[tdd-path] [parent-id]` | exactly one line `build=<v> review=<v> verify=<v>`; `<v>` is `inherit` or a model id | 0 |
| `tl_model_sources` | `[tdd-path] [parent-id]` | exactly one line `build_src=<s> review_src=<s> verify_src=<s>`; `<s>` ∈ `parent`, `pin:<ENV-NAME>`, `light`, `parent-cap` | 0 |

**Resolution rules** (`tl_resolve_models` and `tl_model_sources` share
one internal `_tl_resolve_slot <slot> <tdd-path> <parent-id>` that
prints `<value> <source>`, so the two public functions cannot disagree).
TDD 0067 extends the source set with `escalation` (third resolve arg);
with that arg absent the output is exactly as specified here:

| Slot | First non-empty wins |
|---|---|
| build | `THROUGHLINE_BUILD_MODEL` → `pin:THROUGHLINE_BUILD_MODEL`; (Claude only) `CLAUDE_CODE_SUBAGENT_MODEL` → `pin:CLAUDE_CODE_SUBAGENT_MODEL`; else `inherit` / `parent` |
| review | `THROUGHLINE_REVIEW_MODEL` → `pin:THROUGHLINE_REVIEW_MODEL`; (Claude only) `CLAUDE_CODE_SUBAGENT_MODEL`; else `inherit` / `parent` |
| verify | `THROUGHLINE_RUNTIME_VERIFY_MODEL` → `pin:…`; else if `tl_plan_class` is `nontrivial` → the build slot's value and source; else (mechanical) if `tl_model_tier <parent-id>` is `above` → `tl_light_model` / `light`; else (parent `light` or `unknown`) → `inherit` / `parent-cap` |

`CLAUDE_CODE_SUBAGENT_MODEL` is treated as a pin because Claude Code
applies it to every worker dispatched without a model, silently
overriding inheritance. Naming it keeps the run honest. Documented
precedence (code.claude.com/docs/en/sub-agents): per-dispatch `model`
parameter > agent frontmatter `model` > `CLAUDE_CODE_SUBAGENT_MODEL` >
main conversation. So an explicit light or escalation dispatch still
runs on the model named; the env var is a pin only for slots that would
otherwise inherit.

**`tl_parent_model` observation** (moved here from 0065-rev1; no other
source, never the model's self-report):
- Claude: `CLAUDE_CODE_SESSION_ID` must be non-empty and match
  `^[A-Za-z0-9-]+$` (else unreadable: `no session id`). Transcript =
  the first file matching
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/<id>.jsonl` (a glob on
  the session id, so the session's starting cwd does not matter); none
  → `transcript not found`. Read newest-first with `tac`, parse each
  line as JSON tolerantly (jq `fromjson?`; python3 fallback with
  per-line `try`), keep lines whose top-level `type` is `assistant`,
  take `.message.model`, skip empty and `<synthetic>`, print the first.
  Never regex the raw line: an assistant line can carry a tool_use
  input with its own `"model"` key (an Agent dispatch). Neither jq nor
  python3 → `no json parser`. No match → `no model in transcript`.
- Grok: `GROK_SESSION_ID` non-empty, else unreadable. Read
  `${GROK_HOME:-$HOME/.grok}/sessions/<enc>/$GROK_SESSION_ID/summary.json`
  field `current_model_id` (same JSON cascade). `<enc>` = absolute
  `$PWD` percent-encoded including the leading slash; if missing, retry
  with `git rev-parse --show-toplevel`. The resolved path must stay
  under `${GROK_HOME:-$HOME/.grok}/sessions/` (reject any `..`).

**FR-10 design-reviewer.** `agents/design-reviewer.md` frontmatter
`model: inherit` (was `sonnet`). Opening paragraph: "You did NOT author
this design. You run in a fresh context that is not the author's
session; that fresh context is the independence. You may be on the same
model as the author." Delete "deliberately on a different model".

**`/tdd-author` 7b.** Replace "it runs in fresh context on a different
model than you authored in, so it does not share your blind spots" with
"it runs in a fresh worker that is not this session and inherits this
session's model (FR-10); independence is the fresh context, not a
distinct model name".

**`plugin.json` description.** Replace "(different model, fresh
context)" with "(fresh worker, same model allowed)"; replace "on the
latest top-tier model" with "on the parent session's model (escalation
on demand)"; replace "on a DIFFERENT model (the prior generation's top
tier) for reviewer diversity" with "in a fresh worker". Version bump is
build-applied.

## Data & state
No files written. Reads: session transcript or Grok `summary.json`
(read-only), `settings.json` (read-only), the TDD file (via the
classifier). Env read: `GROK_PLUGIN_ROOT`, `GROK_SESSION_ID`,
`GROK_HOME`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CONFIG_DIR`,
`CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_CODE_SUBAGENT_MODEL`,
`THROUGHLINE_{BUILD,REVIEW,RUNTIME_VERIFY,ESCALATION}_MODEL`.

## Sequencing / implementation plan
1. Rewrite `scripts/lib/models.sh`: bindings, the function table,
   `_tl_resolve_slot`, header comment citing ADR 0015 and NFR-3 (no
   "latest top-tier", "prior-gen", or "author ≠ reviewer" text).
2. Add `tests/model-roles.test.sh` with fixture transcripts and
   `summary.json` under a temp `CLAUDE_CONFIG_DIR` / `GROK_HOME`;
   register it in `tests/implement-gate.test.sh`. Update
   `tests/build-tdds-skill.test.sh` [D] to assert the new no-arg line
   `build=inherit review=inherit verify=inherit` with all pins and
   `CLAUDE_CODE_SESSION_ID` unset.
3. `agents/design-reviewer.md` `model: inherit` + prose;
   `skills/tdd-author/SKILL.md` 7b prose; `plugin.json` description.

## Failure modes & edge cases
**Real risks**
- Transcript schema change (undocumented `message.model`). Effect:
  `tl_parent_model` rc 1 → FR-86 warns every run (0065), mechanical
  verify inherits (never above the parent). Honest, not silent.
- Tool_use input carrying a `"model"` key on an assistant line.
  Mitigation: JSON parse, `.message.model` only; eval fixture has an
  Agent dispatch with `"model":"haiku"` in its input after the real
  `message.model`, and the result must be the real one.
- A malformed transcript line aborts a naive jq stream. Mitigation:
  `fromjson?` / per-line `try`; eval fixture includes a truncated line.
- `CLAUDE_CODE_SUBAGENT_MODEL=haiku` set globally: every judgment slot
  becomes `pin:CLAUDE_CODE_SUBAGENT_MODEL` haiku. Visible in the source
  line; 0066 warns (light pin).

**Overblown risks**
- Effort from `settings.json` misses a mid-session `/effort` change.
  The source column says `settings`, so the reader knows it is the saved
  level; per-worker effort is not controllable anyway (0066).
- A Mythos parent is `above` and is family `mythos`, not `fable`;
  escalation would dispatch Fable. Same tier and price; harmless.

**Unspoken risks**
- Grok bindings (`grok-4.5` light, `grok-4.6` escalation) were carried
  forward unverified. A wrong light binding makes Grok mechanical verify
  run on a non-light model, but never above the parent's tier rule.
  Rebinding is a one-line change.
- A brand-new Claude family name (none of `mythos fable opus sonnet
  haiku`) is `above`. If it is actually a cheap model, FR-86 stays quiet
  for it until `tl_model_family` learns the name.

## Verification plan
- **Surface:** stdout and rc of the `models.sh` functions; frontmatter of
  `agents/design-reviewer.md`; text of `skills/tdd-author/SKILL.md` and
  `.claude-plugin/plugin.json`. Every function is **executed** by the
  eval in a clean `env -i HOME=<tmp> PATH="$PATH" bash -c '. models.sh; …'`
  so no caller shell function leaks in. No network.
- **Observation points → expected (PASS):**
  1. No pins, Claude, no tdd-path (plan `nontrivial`): `tl_resolve_models` → `build=inherit review=inherit verify=inherit`; `tl_model_sources` → `build_src=parent review_src=parent verify_src=parent`. (`parent-cap` needs a mechanical plan: observation 3, and a mechanical fixture with an empty parent → `verify=inherit verify_src=parent-cap`.)
  2. Mechanical-plan fixture TDD + parent `claude-opus-5-5` → `verify=sonnet`, `verify_src=light`.
  3. Mechanical-plan fixture + parent `claude-sonnet-5-5` → `verify=inherit`, `verify_src=parent-cap`; parent `claude-haiku-4-5` → same.
  4. Nontrivial-plan fixture (browser/UI keywords) + parent `claude-opus-5-5` → `verify=inherit`, `verify_src=parent`.
  5. `THROUGHLINE_REVIEW_MODEL=sonnet` → `review=sonnet review_src=pin:THROUGHLINE_REVIEW_MODEL`, `build=inherit`.
  6. `CLAUDE_CODE_SUBAGENT_MODEL=haiku` → `build=haiku` and `review=haiku`, both `pin:CLAUDE_CODE_SUBAGENT_MODEL`; with `GROK_PLUGIN_ROOT=/tmp` set it is ignored (`build=inherit`).
  7. `tl_model_tier`: `claude-sonnet-5-5`→`light`, `claude-haiku-4-5`→`light`, `claude-opus-5-5`→`above`, `claude-fable-5-1`→`above`, empty→`unknown`. Grok: `grok-4.5`→`light`, `grok-4.6`→`above`.
  8. `tl_escalation_model` → `fable`; with `THROUGHLINE_ESCALATION_MODEL=x` → `x`; Grok → `grok-4.6`.
  9. `tl_parent_model` with fixture transcript (lines: truncated JSON; a `user` line; assistant `message.model` `claude-opus-5-5` whose content has a tool_use input `{"model":"haiku"}`; a later assistant line with `<synthetic>`) → prints `claude-opus-5-5`, rc 0.
  10. `tl_parent_model` with `CLAUDE_CODE_SESSION_ID` unset → rc 1, stderr contains `no session id`; with id `../x` → rc 1; with no transcript file → rc 1, `transcript not found`.
  11. Grok `summary.json` fixture with `current_model_id: grok-4.6` → prints `grok-4.6`.
  12. `tl_parent_effort` with `CLAUDE_CODE_EFFORT_LEVEL=high` → `high env`; unset with settings `{"effortLevel":"xhigh"}` → `xhigh settings`; neither → `unknown -`.
  13. `grep -c` of product names: `sonnet|fable|grok-4` appear in `scripts/lib/models.sh` only on the four binding lines and the `tl_model_family` name list (count asserted exactly).
  14. `sed -n '1,8p' agents/design-reviewer.md` contains `model: inherit`; `grep -c 'deliberately on a different model\|on a different model than you authored in'` over `agents/design-reviewer.md` and `skills/tdd-author/SKILL.md` totals 0 **and** both files exist and are readable (missing file = infra-fail, L-001).
  15. `jq -r .description .claude-plugin/plugin.json` contains `fresh worker` and does not contain `prior generation` or `DIFFERENT model`.
- Every negated check first asserts the target file is readable and the
  command produced output (L-001, L-011): rc ≥ 2 or empty input → `bad`.

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
| NFR-3 judgment inherits the parent | `_tl_resolve_slot` build/review → `inherit`/`parent` |
| NFR-3 bindings at one site | the four binding lines; observation 13 |
| NFR-3 independence = fresh worker | design-reviewer prose; tdd-author 7b |
| FR-52 light tier, never above parent | verify rule (`light` only when parent tier `above`, else `parent-cap`); `tl_plan_class` via `tl_classify_plan` |
| FR-52 low effort | gap by design: effort is not per-worker on this harness; recorded by 0066 |
| FR-87 inherit + pins win | resolution table; `CLAUDE_CODE_SUBAGENT_MODEL` as a pin |
| FR-87 queue confirmation / warnings / run record | TDD 0066 (consumes `tl_resolve_models`, `tl_model_sources`, `tl_parent_effort`) |
| FR-10 / FR-50 design-reviewer inherits | `model: inherit`; 7b prose |
| FR-15(d) reviewer = implementer's model | review slot resolves like build; escalation in 0067 |
| FR-86 observation | `tl_parent_model`, `tl_model_tier` (check itself in 0065) |
| FR-88 target binding | `tl_escalation_model` (behavior in 0067) |

## Dependencies considered
No new libraries. JSON parsing uses the repo's existing optional
jq → python3 cascade (drafts.sh); neither present → `unreadable`, never
a guess. Rejected: **raw grep of `"model":"…"`** in the transcript (an
Agent tool_use input on the same line carries its own `model` key — the
sentinel-injection class). Rejected: **keep the inline `case` plan
match** in `models.sh` (duplicates and disagrees with
`plan-classifier.sh`, which already defaults conservatively to
`nontrivial`). Rejected: **a numeric rank table** of model ids (NFR-3
non-goal; only light-tier membership is needed). Rejected: **pass the
parent's observed id explicitly instead of `inherit`** (fails when the
parent is unreadable, and defeats an operator's deliberate
`CLAUDE_CODE_SUBAGENT_MODEL`).

## PRD conflicts surfaced (and resolution)
FR-52 / FR-87 require low effort for mechanical verify and per-slot
effort pins. Claude Code subagents expose no per-dispatch or
frontmatter effort; effort is session-wide. Resolved within the PRD's
open question ("effort on harnesses without an effort control"): 0066
records the session effort and warns that effort pins are unsupported.
No PRD edit needed.

## Decisions to promote (ADR candidates)
ADR 0015 (this PR) supersedes ADR 0014: inherit-by-default, light and
escalation bindings at one site, no live discovery, fresh-worker
independence carried forward.

## Touched files
- `scripts/lib/models.sh` — bindings, role resolution, parent observation, tier placement
- `tests/model-roles.test.sh` — executes every models.sh function with fixtures
- `tests/build-tdds-skill.test.sh` — [D] asserts the new no-arg resolve line
- `tests/implement-gate.test.sh` — register the new eval
- `agents/design-reviewer.md` — `model: inherit`; fresh-worker prose
- `skills/tdd-author/SKILL.md` — 7b fresh worker, not different model
- `.claude-plugin/plugin.json` — description + version

## Expected diff size
- `scripts/lib/models.sh` — 190 lines
- `tests/model-roles.test.sh` — 290 lines
- `tests/build-tdds-skill.test.sh` — 12 lines
- `tests/implement-gate.test.sh` — 12 lines
- `agents/design-reviewer.md` — 12 lines
- `skills/tdd-author/SKILL.md` — 10 lines
- `.claude-plugin/plugin.json` — 6 lines
Total expected diff: 532 lines across 7 files.

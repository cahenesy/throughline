# TDD 0064: Judgment-worker defaults and cheaper-pin warning

Status: draft
PRD refs: NFR-3, FR-87, FR-52, FR-10, FR-15, FR-50
PRD-rev: 5dbf968
ADR constraints: 0004, 0005, 0006, 0010, 0011, 0013, 0014
Supersedes: 0057

## Approach
NFR-3 is now capability-by-job, not author≠reviewer-by-name. Unset
defaults put the implementer, the FR-15(d) reviewer, and the FR-10
design-reviewer on the **same** latest top-tier id. Mechanical
runtime-verify stays on the cheaper id (FR-52). A cheaper env pin on
the implementer or reviewer is honored and the **parent** session warns
before dispatch (FR-87). Independence is a **fresh worker**, not a
different model name: `agents/design-reviewer.md` inherits the parent
model.

Carried forward from 0057 / TDD 0062: `scripts/lib/models.sh` is the
only product-name site for **dispatch**. The prior-gen derivation
(`*opus*) review=sonnet` / Grok `review=grok-4.5`) is deleted.

Out of scope (TDD 0065): FR-86 parent-session live-fetch check.

## Components & interfaces
- **`tl_resolve_models` (scripts/lib/models.sh).** Replace the body
  with this exact function (L-003: pin the spec, not a paraphrase):
  ```
  tl_resolve_models() {
    local plan="${1:-}" build review verify cheap
    if [ -n "${GROK_PLUGIN_ROOT:-}" ]; then
      build="${THROUGHLINE_BUILD_MODEL:-grok-4.6}"
      cheap="grok-4.5"
      review="${THROUGHLINE_REVIEW_MODEL:-$build}"
    else
      build="${THROUGHLINE_BUILD_MODEL:-fable}"
      cheap="sonnet"
      review="${THROUGHLINE_REVIEW_MODEL:-$build}"
    fi
    if [ -n "${THROUGHLINE_RUNTIME_VERIFY_MODEL:-}" ]; then
      verify="$THROUGHLINE_RUNTIME_VERIFY_MODEL"
    else
      case "$plan" in
        *[Ee]xit-code*|*grep*|*file\ exist*|*rc\ 0*|*rc=0*) verify="$cheap" ;;
        '') verify="$cheap" ;;
        *)  verify="$build" ;;
      esac
    fi
    printf 'build=%s review=%s verify=%s\n' "$build" "$review" "$verify"
  }
  ```
  Header comments: build = latest top-tier on this harness; review =
  the same id unless `THROUGHLINE_REVIEW_MODEL` is set; verify =
  cheaper tier only when the plan text is mechanical (FR-52), else
  build. No “prior-gen” / “author ≠ reviewer” language remains in this
  file.
- **FR-87 parent warning (`skills/implement/SKILL.md`).** After
  sourcing `models.sh` and before dispatching the implementer or
  reviewer, the parent computes the harness default by resolving with
  the three override env vars unset (so the default literals live only
  in `models.sh`):
  ```
  _tl_def="$(env -u THROUGHLINE_BUILD_MODEL -u THROUGHLINE_REVIEW_MODEL \
    -u THROUGHLINE_RUNTIME_VERIFY_MODEL bash -c \
    '. "$(tl_plugin_root)/scripts/lib/models.sh"; tl_resolve_models')"
  _tl_def_build="${_tl_def#build=}"; _tl_def_build="${_tl_def_build%% *}"
  ```
  If `THROUGHLINE_BUILD_MODEL` is set and is not byte-equal to
  `$_tl_def_build`, print exactly
  `throughline: THROUGHLINE_BUILD_MODEL=<id> differs from the most-capable default; continuing`
  and continue. Same for `THROUGHLINE_REVIEW_MODEL` with
  `THROUGHLINE_REVIEW_MODEL=` in the message. Do **not** emit this
  warning for `THROUGHLINE_RUNTIME_VERIFY_MODEL` (FR-52 cheap default).
  A pin equal to the default literal is silent. A pin of a different
  spelling of the same model (`claude-fable-5` vs `fable`), or a
  newer id, uses the same “differs from” line — no rank table, so the
  warning does not claim “below.” 0065’s live eval does not change
  this dispatch warning.
- **Reviewer spawn prose.** In `skills/implement/SKILL.md` step 10
  and the Notes “Models:” bullet, delete “prior-gen top-tier” and
  retarget the ADR cite from 0009 to 0014. The reviewer uses
  `review=` from `tl_resolve_models` and **must not spawn children**.
  Same-name as the implementer is required when both slots are unset.
  `README.md` still has different-model / prior-gen sentences; that
  sweep is **deferred** (not in this touched set).
- **FR-10 design-reviewer inherit.** `agents/design-reviewer.md`
  frontmatter `model:` becomes `inherit` (not `sonnet`). Opening
  sentence: independent critique in a **fresh worker**; a different
  model name is not required. `skills/tdd-author/SKILL.md` step 7b
  drops “different model than you authored in”; it requires a worker
  that is not the `/tdd-author` parent session (FR-10 acceptance).
- **`.claude-plugin/plugin.json` description.** Replace “different
  model, fresh context” and “DIFFERENT model (the prior generation's
  top tier)” with “fresh worker, most-capable default; same model
  name allowed”. Version bump is build-applied.
- **`docs/tdd/0057-default-model-pairing-rebind.md`.** Status line
  only: `superseded by 0064`. Body unchanged.

## Data & state
No schema change. Overrides still win. Unset-everything is the only
behavioral change: `review=` becomes equal to `build=`.

## Sequencing / implementation plan
1. Replace `tl_resolve_models` with the pinned body; rewrite the file
   header. Eval cases in step 4 for the **new** defaults (not 0057’s).
2. `agents/design-reviewer.md`: `model: inherit` + prose.
3. `skills/implement/SKILL.md`: FR-87 warning + reviewer uses
   `review=` (no prior-gen). `skills/tdd-author/SKILL.md`: 7b
   independence is a fresh worker.
4. Add `tests/model-capability-defaults.test.sh`; register it in
   `tests/implement-gate.test.sh`’s eval loop. Flip 0057 Status.
   Bump `plugin.json` description + version.

## Failure modes & edge cases
- **Real:** operator pins `THROUGHLINE_REVIEW_MODEL=opus` expecting
  the old pairing. Mitigation: pin still wins; FR-87 warning names
  the env var; defaults no longer derive sonnet from opus.
- **Real:** `_tl_def` parse breaks if `tl_resolve_models` ever prints
  more than one line. Mitigation: the function prints exactly one
  `build=… review=… verify=…` line (existing contract).
- **Overblown:** Grok and Claude defaults drifting independently —
  they already do; this TDD only equalizes review to build on each
  harness.
- **Unspoken:** `model: inherit` on Claude Code uses the **parent
  session** model, which may be below the models.sh default if the
  human started `/tdd-author` on Sonnet. That is FR-86’s job (0065),
  not a second pin in the agent file.

## Verification plan
- **Surface:** `tl_resolve_models` stdout; skill-text warning
  instruction; agent frontmatter; plugin description.
- **Observation points:**
  1. `env -u GROK_PLUGIN_ROOT -u THROUGHLINE_BUILD_MODEL -u THROUGHLINE_REVIEW_MODEL -u THROUGHLINE_RUNTIME_VERIFY_MODEL` + source + `tl_resolve_models` → exactly `build=fable review=fable verify=sonnet`.
  2. Same with `GROK_PLUGIN_ROOT=/tmp` → `build=grok-4.6 review=grok-4.6 verify=grok-4.5`.
  3. `THROUGHLINE_REVIEW_MODEL=opus` (Claude unset GROK) → `review=opus`; `build=` still `fable`.
  4. Plan text containing `exit-code` → `verify=` cheap; plan text `Drive the DOM and judge the screenshot` → `verify=` equals `build=`.
  5. `grep -n 'opus\*)' scripts/lib/models.sh` exits 1 (derivation gone).
  6. `sed -n '1,8p' agents/design-reviewer.md` contains `model: inherit` and does not contain `model: sonnet`.
  7. `skills/implement/SKILL.md` contains the exact warning prefix `differs from the most-capable default; continuing` and contains `THROUGHLINE_RUNTIME_VERIFY_MODEL` in a sentence that says that pin does **not** emit this warning.
  8. `skills/tdd-author/SKILL.md` does not contain `different model than you authored`. Missing-file: if the skill path is unreadable, the check is infra-fail (exit 2), not ok (L-001).
  9. `.claude-plugin/plugin.json` description does not contain `prior generation`.
- **PASS:** 1–9 hold. 3 records the weaker reviewer id. No test hits
  the network.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement traceability | Every in-scope FR/NFR maps to a named component or skill step | One mapping is slightly indirect but still named | An in-scope FR/NFR is missing or only hand-waved |
| interface concreteness | models.sh dispatch ids, inherit spawn, live-fetch compare, and warn+ask are specified with inputs/outputs | One interface is slightly implicit but implementable | A reader cannot tell where dispatch ids live vs where FR-86 looks up |
| alternatives-analysis substance | Live official-docs fetch named; static rank map and Models-API recency rejected with reasons | One rejected alternative is thin but present | No rejected alternative, or none considered |
| verification-plan actionability | Observable surface, observation points, and PASS values named | Observations are concrete but one fixture is slightly underspecified | Non-actionable plan, or the section is missing |
| scope-bound adherence | Touched files within bounds; estimates padded; exceptions declared | One justified inline exception | Over bound with no exception, or undeclared files |
| naming consistency | build=/review=/verify=, inherit, unreadable→warn+ask used the same way in both TDDs | One synonym that still refers to the same thing | Same concept named two ways across the set |
| no static rank map | FR-86 compare is a this-turn official-docs fetch; no shipped family/rank table | Fetch sources named; one fallback sentence is slightly loose | A hardcoded fable>opus>sonnet (or similar) table is the compare |

## Requirement traceability
| Requirement | Design element |
|---|---|
| NFR-3 most-capable defaults | `tl_resolve_models` `build=` and `review=` share the latest top-tier literal; design-reviewer `inherit` |
| NFR-3 independence = fresh worker | 7b / step 10 require a separate worker; same name allowed |
| FR-87 | Parent stderr warning when BUILD/REVIEW env ≠ default literal; pin still dispatches |
| FR-52 | `verify=` cheap only for mechanical plan text; nontrivial follows `build=` |
| FR-10 / FR-50 | design-reviewer inherit + tdd-author 7b prose; same-name not a reject |
| FR-15(d) | reviewer uses `review=` (equals `build=` when unset) |
| FR-86 | **gap:** TDD 0065 |

## Dependencies considered
No new libraries. Rejected: keep the `*opus*) review=sonnet` derivation
(contradicts NFR-3). Rejected: pin `model: fable` on
`design-reviewer.md` (second binding site; goes stale). Chosen: inherit
+ single `models.sh` dispatch site.

## PRD conflicts surfaced (and resolution)
ADR 0009 required prior-gen review and blocked this TDD. Resolved by
[[0014]] in this design PR (`Status: superseded by 0014` on 0009).

## Decisions to promote (ADR candidates)
[[0014]] (this PR). Leave ADR 0008; rework is already retired by 0013.

## Touched files
- `scripts/lib/models.sh` — review default equals build; drop derivation
- `agents/design-reviewer.md` — `model: inherit`; independence prose
- `skills/implement/SKILL.md` — FR-87 warning; reviewer uses `review=`
- `skills/tdd-author/SKILL.md` — 7b fresh worker, not different name
- `tests/model-capability-defaults.test.sh` — resolve + inherit + warning anchors
- `tests/implement-gate.test.sh` — register the new eval
- `.claude-plugin/plugin.json` — description + version
- `docs/tdd/0057-default-model-pairing-rebind.md` — Status line only

## Expected diff size
- `scripts/lib/models.sh` — 45 lines
- `agents/design-reviewer.md` — 18 lines
- `skills/implement/SKILL.md` — 55 lines
- `skills/tdd-author/SKILL.md` — 25 lines
- `tests/model-capability-defaults.test.sh` — 145 lines
- `tests/implement-gate.test.sh` — 12 lines
- `.claude-plugin/plugin.json` — 8 lines
- `docs/tdd/0057-default-model-pairing-rebind.md` — 2 lines
Total expected diff: 310 lines across 8 files.

# TDD 0057: Default model pairing rebind — latest top tier builds, prior-gen top tier reviews
Status: implemented
PRD refs: NFR-3 (model diversity, tier-based)
PRD-rev: d7bc491
ADR constraints: 0003, 0008, 0009

## Approach
NFR-3 now names tiers, not products (PRD-rev d7bc491): builds run on the
strongest current-generation model, the review gate on the prior generation's
top tier, with concrete bindings as implementation defaults. This TDD rebinds
those defaults from the opus/sonnet pairing to **fable (build/rework) / opus
(review)** and sweeps the remaining product-name prose to tier language so the
binding lives in exactly one place.

Evidence base — stated honestly: two clean end-to-end runs on the new pairing
(the 0054 rebuild, run 20260611-200724: 5 steps, zero rework, zero halts; and
0056, run 20260611-220255: 5 steps, zero rework, zero halts under adversarial
self-hosting conditions), versus opus-era baselines that needed `--recover` /
structural-revision interventions (0049, 0055). Two runs is a thin base for a
default; the change is acceptable because rollback is one flag away — the
derivation rule maps an explicit `--model opus` build to a `sonnet` review, so
the legacy pairing remains fully reachable and is pinned by an eval case.

**The rework default needs an explicit rebind** (design-critique finding,
this pass): ADR 0008's substance is "rework authors on the BUILD model", but
the implementation snapshotted that as a product literal —
`${THROUGHLINE_REWORK_MODEL:-opus}` is hardcoded at THREE sites (gates.sh
`_rework_one` ~:1689, gates.sh `_rework_loop` telemetry ~:2519, state.sh
`_rework_config_json` ~:358; state.sh's own comment says "The model default
`opus` is the build model"). Left alone, a fable build would rework on opus
while the REVIEW gate also runs opus — rework author and reviewer on the SAME
model, the exact NFR-3 violation ADR 0008 exists to prevent. All three sites
rebind to the build model (Components).

Out of scope, confirmed unaffected: the runtime-verify mechanical tier (FR-52)
keeps its current lower-tier binding in `gates.sh` (`sonnet` for mechanical
plans — nontrivial plans already follow the build model, so they pick up fable
automatically); `_gate_effort` already maps fable → xhigh (build/rework/review)
and high (verify) since PR #149.

## Components & interfaces
- **`resolve_models()` (scripts/implement.sh).** The MODEL / REVIEW_MODEL
  resolution block (currently inline at implement.sh:256-264, inside the
  setup block) moves into a function defined ABOVE the
  `THROUGHLINE_SOURCE_ONLY` guard — the established pattern for units the
  test suite drives in isolation (the file already documents it at lines 96,
  103, 130, 190). The setup block calls `resolve_models` at the same point the
  inline block sat. Pinned semantics (L-003: exact spec, not a paraphrase):
  ```
  resolve_models() {
    [ -z "$MODEL" ] && MODEL="${THROUGHLINE_BUILD_MODEL:-fable}"
    if [ -z "$REVIEW_MODEL" ]; then
      REVIEW_MODEL="${THROUGHLINE_REVIEW_MODEL:-}"
      [ -z "$REVIEW_MODEL" ] && case "$MODEL" in
        *opus*) REVIEW_MODEL="sonnet" ;;
        *)      REVIEW_MODEL="opus"   ;;
      esac
    fi
  }
  ```
  The ONLY behavioral change vs today is the default literal (`opus` →
  `fable`); the derivation rule is byte-identical, which is what preserves
  the rollback property (explicit opus build → sonnet review) and the
  diversity invariant (any non-opus build → opus review). The surrounding
  comment block (implement.sh:251-255) is reworded to tier language: build =
  latest top tier, review = prior-gen top tier, names bound HERE only.
- **skills/implement/SKILL.md (5 sites).** Lines ~390 ("default sonnet vs an
  opus build"), ~399 ("the build model, `opus`, by default"), ~467-468
  ("best model (opus by default)… DIFFERENT model (sonnet by default)"),
  ~473 (runtime-verify heuristic "sonnet for mechanical plans"), and ~478
  ("`THROUGHLINE_REWORK_MODEL` (default `opus`, the build model…)") are reworded
  to tier language ("latest top-tier model", "prior generation's top tier",
  "a cost-efficient lower-tier model"), each pointing at the runner bindings
  rather than naming products.
- **.claude-plugin/plugin.json.** The description's "on the best model
  (opus)" → "on the latest top-tier model" and "a DIFFERENT model (sonnet)"
  → "a DIFFERENT model (the prior generation's top tier)". Version bump
  (build-applied).
- **Rework-default rebind (3 sites, one verbatim expression).** Each of
  gates.sh:1689, gates.sh:2519, and state.sh:358 replaces
  `${THROUGHLINE_REWORK_MODEL:-opus}` with the pinned expression
  `${THROUGHLINE_REWORK_MODEL:-${MODEL:-fable}}` — explicit override wins,
  else the build model (ADR 0008's actual substance), else the latest-tier
  literal for bare contexts where MODEL is unset. The three sites carry the
  IDENTICAL expression by design; a mechanical cross-site agreement check in
  the eval (the TDD 0049 parser-agreement pattern: grep the expression at all
  three sites, fail on any divergence) guards the L-003 drift shape, since a
  shared helper across the two independently-sourced libs would couple their
  load order for two literals. state.sh's stale "`opus` is the build model"
  comment is reworded to tier language.
- **tests/bounded-rework-loop.test.sh (3 expectation sites).** The default-
  model case (~:47) re-pins the resolution chain (unset → fable; MODEL=opus →
  opus; THROUGHLINE_REWORK_MODEL=sonnet → sonnet); the two loop cases
  asserting `"model":"opus"` (~:827, ~:864) set `MODEL=opus` explicitly in
  their case env so they keep testing "rework follows the build model"
  without depending on the default literal.
- **tests/gate-effort.test.sh — new §D "default model resolution".** Drives
  `resolve_models` directly (`THROUGHLINE_SOURCE_ONLY=1 source
  scripts/implement.sh`, then set/unset the inputs per case):
  unset everything → `MODEL=fable REVIEW_MODEL=opus`; `MODEL=opus` →
  `REVIEW_MODEL=sonnet` (rollback pairing); `MODEL=sonnet` →
  `REVIEW_MODEL=opus` (diversity for any non-opus build);
  `THROUGHLINE_BUILD_MODEL=opus` + unset MODEL → `MODEL=opus
  REVIEW_MODEL=sonnet` (env binding wins over default);
  `THROUGHLINE_REVIEW_MODEL=haiku` → `REVIEW_MODEL=haiku` (explicit review
  override wins over derivation). §D also carries the rework-resolution
  cases (unset → fable; MODEL=opus → opus; override wins) and the three-site
  agreement check above. Each case runs in a subshell so env never leaks
  between cases ([[ci-checks-env-leak]] hygiene).

## Data & state
No schema, file-format, or state change. No behavior change for any operator
who passes `--model` / `--review-model` or sets `THROUGHLINE_BUILD_MODEL` /
`THROUGHLINE_REVIEW_MODEL` — only the unset-everything default moves.

## Sequencing / implementation plan
1. Extract `resolve_models()` above the SOURCE_ONLY guard (behavior-identical
   move, default still opus), with the §D eval cases for the CURRENT
   semantics proving the move changed nothing.
2. Flip the default literal to `fable`; update §D's unset-everything case to
   the new expectation (fable/opus) — the failing-test-first red→green for
   the build-default rebind.
3. Rework-default rebind: the pinned expression at the three sites + the §D
   rework-resolution cases + the cross-site agreement check + the three
   bounded-rework-loop expectation updates.
4. Tier-language sweep: implement.sh + state.sh comment blocks, the five
   SKILL.md sites, plugin.json description (+ version bump).

## Failure modes & edge cases
**Real risks.**
- *The fable model id stops resolving on some host/CLI version* → every build
  fails at spawn, loudly (claude exits non-zero; the gate classifies
  transient). Rollback is `THROUGHLINE_BUILD_MODEL=opus` or `--model opus` —
  one knob, no code change. Two production runs on this exact host already
  validate the id.
- *Cost regression* — fable is ~2× opus per token. Observed: the two pilot
  runs spent fewer tokens than comparable opus runs (44.2M vs 85.8M on
  comparable-scale TDDs), with zero recovery round-trips; net dollar spend
  was roughly flat for visibly cleaner runs. The FR-68 token telemetry keeps
  this observable per run.

**Overblown risks.**
- *The `*opus*` derivation arm goes stale* — it is the deliberate rollback
  path, not dead code, and §D pins it.

**Unspoken risks (elephants).**
- *A missed product-literal recreates the ADR 0008 violation silently* — the
  rework-on-opus case this design's critique caught is the template: a
  same-model author/reviewer pair fails NOTHING mechanically (every gate
  still runs), it just quietly voids the diversity property. The cross-site
  agreement check + §D resolution cases turn the known sites into regression
  guards; the residual is any FUTURE site that snapshots a tier as a literal
  — which is why ADR 0009 directs prose to tiers and bindings to named,
  greppable resolution points.
- *Tier language can silently drift from reality* — "prior generation's top
  tier" is only true while opus is one generation behind fable; when the next
  generation ships, the binding (one literal in `resolve_models`) must be
  rebound or the tier claim reads stale in the other direction. That
  rebinding is deliberately a normal TDD/PR (the PRD and ADR 0009 say so);
  the failure mode is a stale default, never a broken run.

## Verification plan
- **Observable surface:** `MODEL` / `REVIEW_MODEL` values after
  `resolve_models` (driven via sourcing implement.sh in source-only mode);
  the gate-effort eval's pass/fail counts on stdout; the prose surfaces
  (SKILL.md, plugin.json) via grep.
- **Observation points (mechanical — `bash tests/gate-effort.test.sh`):**
  1. §D unset-everything → `MODEL=fable`, `REVIEW_MODEL=opus`.
  2. §D `MODEL=opus` → `REVIEW_MODEL=sonnet` (rollback pairing intact).
  3. §D `MODEL=sonnet` → `REVIEW_MODEL=opus`; `THROUGHLINE_BUILD_MODEL=opus`
     → opus/sonnet; `THROUGHLINE_REVIEW_MODEL=haiku` → haiku (override wins).
  4. §D rework chain: unset → rework model fable; `MODEL=opus` → opus;
     `THROUGHLINE_REWORK_MODEL=sonnet` → sonnet. Cross-site agreement: the
     pinned expression appears verbatim at gates.sh:1689/2519 and
     state.sh:358 (grep count == 3, rc-distinct).
  5. `bash tests/bounded-rework-loop.test.sh` → updated expectations green
     (default case asserts the chain; loop cases run with explicit
     MODEL=opus).
  6. Prose sweep: `grep -c 'opus\|sonnet'` over skills/implement/SKILL.md
     model-default sentences returns 0 product names in the five reworded
     sites (anchored on the new tier phrases, rc-distinct file-missing vs
     text-absent); plugin.json description carries "latest top-tier model".
- **Expected observations (PASS):** the values above; the pre-existing
  gate-effort §1-§3 and §W cases stay green; aggregator green via the
  existing GEF registration.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | NFR-3 tier requirement maps to the exact binding sites; FR-52 confirmed unaffected | All refs traced | Any untraced ref |
| Single binding point | Concrete model names ONLY in implement.sh defaults (+ ADR context note); prose surfaces speak tiers | One stray name with justification | Product names re-scattered across prose |
| Rollback preservation | Explicit `--model opus` → sonnet review pinned by an eval case; env overrides untouched | Rollback path stated | Default flip breaks the legacy pairing |
| Evidence honesty | Two-clean-runs evidence base AND its thinness stated plainly | Evidence cited | Overclaimed |
| Verification-plan actionability | Default-resolution eval cases name exact observables | Drivable mechanically | "Tests pass" placeholders |
| Scope-bound adherence | Within bounds, calibrated estimates | Within bounds | Over-bound, no exception |

## Requirement traceability
| Requirement | Design element |
|---|---|
| NFR-3 (tier-based model diversity) | `resolve_models()` binds build = fable (latest top tier), review = opus (prior-gen top tier) with the derivation preserving author≠reviewer for every build model; the rework default rebinds to `${THROUGHLINE_REWORK_MODEL:-${MODEL:-fable}}` at all three sites so rework author ≠ reviewer holds under the new pairing (ADR 0008's substance, previously snapshotted as a product literal); §D pins the pairings, the rollback arm, and the rework chain; prose surfaces speak tiers so the requirement and the bindings can't drift apart silently |
No gaps. ADR 0008 (rework on the build model) is IMPLEMENTED faithfully by
the rework-default rebind (the prior `:-opus` literal was a snapshot of "the
build model" that stopped being true); ADR 0003's review-gate delegation is
untouched. ADR 0009 (authored in this design pass) records the tier principle
and the binding-of-record.

## Dependencies considered
No new dependencies. Rejected alternative for the mechanism: a config file /
env-manifest mapping tiers → names (rejected: a second source of truth for
two literals; the existing flag/env override surface already provides every
needed escape hatch, and `resolve_models()` keeps the binding greppable in
one function).

## PRD conflicts surfaced (and resolution)
None. The prior conflict (NFR-3 naming opus/sonnet as the defaults) was
resolved AHEAD of this TDD by the PRD tier-language pass (PR #156, PRD-rev
d7bc491) — this design implements the tier binding the revised NFR-3 calls
for.

## Decisions to promote (ADR candidates)
**ADR 0009 — approved in this pass's interview:** default model pairing is
tier-based (build = latest top tier, review = prior generation's top tier);
revises ADR 0008's recorded product-name consequences ("Opus by default",
"reserves Sonnet for the review gates only") the same append-only way 0008
revised 0007; records fable/opus as the binding as of 2026-06 and states that
future rebindings are normal implementation changes (TDD/PR), not new ADRs.

## Touched files
- `scripts/implement.sh` — `resolve_models()` extraction above the SOURCE_ONLY guard; default literal opus → fable; tier-language comment
- `scripts/lib/gates.sh` — rework-default expression at the two usage sites (:1689, :2519)
- `scripts/lib/state.sh` — rework-default expression at the config-snapshot site (:358) + tier-language comment
- `skills/implement/SKILL.md` — five model-default prose sites → tier language
- `.claude-plugin/plugin.json` — description tier rewording + version bump
- `tests/gate-effort.test.sh` — §D default-model-resolution cases (build, review, rework chains; rollback pin; cross-site agreement check)
- `tests/bounded-rework-loop.test.sh` — three expectation sites re-pinned to the resolution chain / explicit MODEL=opus

## Expected diff size
- scripts/implement.sh — 50 lines
- scripts/lib/gates.sh — 16 lines
- scripts/lib/state.sh — 12 lines
- skills/implement/SKILL.md — 22 lines
- .claude-plugin/plugin.json — 4 lines
- tests/gate-effort.test.sh — 115 lines
- tests/bounded-rework-loop.test.sh — 50 lines
Total expected diff: 269 lines across 7 files.

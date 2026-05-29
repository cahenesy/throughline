# TDD 0019: Bounded automatic rework loop — model wiring, attempt budget, scope cap, structural escalation, cost telemetry

Status: draft
PRD refs: FR-61, FR-62, FR-65, FR-66, FR-67, FR-68
PRD-rev: a961955
ADR constraints: 0003, 0004, 0005, 0006, 0007

## Approach

When a continuous-review pass (TDD 0020) emits a halting finding (FR-58:
`blocker` or `major`), the runner classifies it as structural-or-fixable and
acts accordingly *within the same `/implement` invocation*. Structural →
BLOCKED with a routed BLOCKERS.md entry. Fixable → bounded rework attempt on
Sonnet (cheaper, less prone to opportunistic refactoring than Opus). Each
rework commit faces a mechanical pre-pass (the scope cap from FR-66 and the
file-set / per-file-bound checks from FR-67). On pre-pass clear, the rework
commit ships and the next review pass runs against the new diff range
(continuous-review scoping from TDD 0020). On exhaustion of the per-gate-
per-step attempt budget, the TDD is BLOCKED with `rework-budget-exhausted`.

Three OR'd structural criteria from FR-67 are checked at different points:

- **(c) reviewer explicitly classifies as structural** — checked
  *predictively*, before any rework attempt, by reading the
  `structural: true` tag on the finding (TDD 0021 adds this tag to the
  reviewer's finding schema). If set, BLOCKED immediately; no rework runs.
- **(a) fix touches files outside declared touched-file set** AND
  **(b) fix exceeds declared per-file bound** — checked *retrospectively*,
  by inspecting the rework commit's diff against the TDD's `## Touched
  files` and `## Expected diff size` declarations (delivered by TDD 0014).
  If either fires, the commit is rejected and BLOCKED.

The "retrospective" choice for (a) and (b) is deliberate: predictive
structural judgments for arbitrary code edits would require a model call
of similar cost to the rework itself, and the data carrying the predictive
answer (TDD declarations + reviewer finding text) doesn't reliably support
the prediction; the rework commit's actual diff is the ground truth. This
is consistent with FR-70 (gate decisions grounded in verifiable artifacts)
and ADR 0006.

Model wiring (the IMPORTANT NEW CONSTRAINT from the design plan):

- **Original build** (gate 1 first attempt) — Opus, unchanged.
- **Rework on gate 1** (any rework attempt after a finding) — Sonnet,
  unchanged across attempts.
- **Review** (gate d, every pass) — Sonnet, unchanged from existing
  behavior.

NFR-3 (model diversity at the gate boundary) is preserved: gate 1's
original-vs-rework split happens within one gate; the gate 1/gate d
boundary still uses different models (Opus/Sonnet original; Sonnet/Sonnet
rework — same model on rework is a known reduction, but NFR-3 only requires
diversity at the *gate* boundary, not at every model invocation).

FR-68 (rework cost < original build cost) is telemetry-only. Each attempt
records per-attempt `token_spend` in the run-state record; no hard
per-attempt cap aborts mid-run. The aggregate enforcement is the
THROUGHLINE_REWORK_MAX attempt count (FR-65).

## Components & interfaces

### 1. Rework loop wiring — `scripts/lib/gates.sh` (post-TDD-0017)

A new function `_rework_one`, called by `_review_one_gated` when the
review pass emits `REVIEW_RESULT: BLOCK` with at least one halting
finding:

```
_rework_one <slug> <log> <finding-ref>
  → spawns claude -p with:
    --model "$THROUGHLINE_REWORK_MODEL"   # default sonnet
    --prompt <rework-prompt-template>     # includes the finding text,
                                           # the TDD's touched-file set,
                                           # the TDD's per-file bounds,
                                           # the FR-66 scope cap
  → commits the resulting edit with message "rework: <finding-summary>"
  → echoes the new HEAD SHA
```

A new function `_rework_pre_pass <slug> <new-head-sha>` runs the
mechanical FR-66 + FR-67(a)+(b) checks against the rework commit's diff
(against the prior cleared SHA from TDD 0020):

- **FR-66 scope cap.** Compute total `git diff <cleared-sha>..<new-head>`
  insertion+deletion line count. Cap = `max(N, K * region_size)` where
  `N = THROUGHLINE_REWORK_SCOPE_FLOOR` (default **60**),
  `K = THROUGHLINE_REWORK_SCOPE_FACTOR` (default **3**), and `region_size`
  is the cited finding's region in lines (from the finding's
  `region_lines` field, set by TDD 0021). If over cap → echo
  `PRECHECK_FAIL: rework-scope-exceeded <actual> > <cap>`; runner records
  `rework-scope-exceeded` cause and routes to BLOCKED.
- **FR-67(a) touched-file scope.** Parse the TDD's `## Touched files`
  section (TDD 0014). For each file in the rework commit's diff, check
  membership. Any file outside the set → echo `PRECHECK_FAIL:
  structural-finding(a) <file-outside-set>`.
- **FR-67(b) per-file bound.** For each file the rework touched, compute
  the file's cumulative-since-start-of-TDD-build line count
  (`git diff <build-start-sha>..<new-head> -- <file>` lines). Compare
  against the TDD's `## Expected diff size` declaration for that file
  (with `(exception: …)` markers honored — files with an exception are
  not bound-checked). Over-bound → echo `PRECHECK_FAIL:
  structural-finding(b) <file> <actual> > <declared>`.

Any `PRECHECK_FAIL` causes the rework commit to be hard-reset off the
build branch (`git reset --hard <prior-cleared-sha>`) and a halt event to
be recorded with the appropriate cause from §TDD 0018's enum.

### 2. Attempt budget — `scripts/lib/gates.sh`

A new helper `_rework_attempt_count <slug> <gate> <step>` reads/increments
the per-(gate, step) attempt counter from the TDD's fragment. The
counter lives in a new fragment field:

```
rework_attempts: {
  "<gate>:<step>": <int>,
  ...
}
```

On each halting finding that does not satisfy FR-67(c) (reviewer-tagged
structural), the runner increments the counter for the current (gate,
step) pair. If the post-increment value exceeds
`THROUGHLINE_REWORK_MAX` (default **3**), the runner BLOCKS the TDD with
cause `rework-budget-exhausted` and routes to BLOCKERS.md.

The `THROUGHLINE_REWORK_MAX` value is recorded once in `run.json` (added
to the run-level configuration snapshot) so the budget at run time is
falsifiable from the run-state record alone.

### 3. Per-attempt token-spend telemetry (FR-68) — `scripts/lib/state.sh` + `scripts/lib/gates.sh`

Each TDD fragment gains a `rework_log` array:

```
rework_log: [
  { "attempt": 1, "gate": "review", "step": 3, "model": "sonnet",
    "token_spend": <int>, "started_at": <epoch>, "finished_at": <epoch>,
    "finding_ref": "<pass-id>:<finding-idx>", "outcome": "shipped" | "rejected:<cause>" },
  ...
]
```

`token_spend` is read from the rework `claude -p` invocation's session JSON
(the SDK writes a per-session token usage summary). A small helper
`_extract_token_spend <session-json-path>` parses it; fallback to `null`
if the field is missing. `null` is acceptable per FR-68 (the requirement is
observability, not enforcement); the acceptance criterion compares numeric
values when present.

The original-build attempt's `token_spend` is also recorded (using the
same `_extract_token_spend` helper on the build session's JSON) on the
TDD fragment as `build_attempt.token_spend`, so the FR-68 acceptance
(rework < original) is comparable from run-state alone.

### 4. Structural escalation routing — `scripts/lib/gates.sh`

When `_rework_pre_pass` returns a `structural-finding(a)`, `(b)`, or the
reviewer's `(c)` tag is observed on the finding pre-rework, the runner:

1. Calls `set_halt_cause <slug> structural-finding <finding-ref>` (TDD
   0018's setter).
2. Calls `record_blocker <slug> "<gate>:<step> <criterion> <details>"` —
   appending a structured entry to `docs/tdd/BLOCKERS.md` whose body
   names the TDD slug, the gate-step pair, the structural criterion
   that fired (a/b/c), and a one-line excerpt of the finding text.
3. Halts forward progress on this TDD; downstream queued TDDs in
   sequential mode are marked downstream-BLOCKED (existing FR-16 +
   TDD 0008 behavior).

### 5. Rework prompt template — new file `scripts/rework-prompt.md`

A small prompt template (not a skill) that `_rework_one` substitutes the
finding text, touched-file set, per-file bounds, and scope cap into. Key
instructions:

- "Fix only the cited finding. Do not refactor unrelated code."
- "Touch only files in the declared touched-file set: [list]. Editing any
  other file will cause the rework to be rejected."
- "Bound your total diff to ≤ {cap} lines (across all touched files). The
  cap is `max({floor}, {factor} × cited-finding-region-size)` =
  {computed-cap} for this finding."
- "Do not modify tests in this rework pass unless the finding explicitly
  cites a test. (Tests modified to mask the cited bug are a major
  finding.)"
- "Commit your edits with a single commit message of the form `rework:
  <one-line summary>`."

The prompt template lives outside the skill prompts (which are subject to
TDD 0014's bounds) because it is a runtime artifact substituted at
build time, not authored once at design time.

### 6. Configuration knobs

New environment variables, with defaults:

| Variable | Default | Meaning |
|---|---|---|
| `THROUGHLINE_REWORK_MODEL` | `sonnet` (resolved to the same alias `THROUGHLINE_REVIEW_MODEL` resolves to in TDD 0013 — current value `claude-sonnet-4-6`) | Model passed to `_rework_one`'s `--model` flag. |
| `THROUGHLINE_REWORK_MAX` | `3` | Per-(gate, step) attempt cap. |
| `THROUGHLINE_REWORK_SCOPE_FLOOR` | `60` | `N` in `max(N, K × region)`. Calibrated from TDD 0011 data (single-fix commits averaged ~30 lines; floor gives 2× headroom). |
| `THROUGHLINE_REWORK_SCOPE_FACTOR` | `3` | `K` in `max(N, K × region)`. Calibrated from TDD 0011 (review findings averaged ~10-line regions; 3× is a tight but not pinching cap). |

All four are recorded in `run.json`'s configuration snapshot so any
halt event citing these values is reproducible from the run-state alone
(ADR 0006).

## Data & state

The per-TDD fragment fields added:

- `rework_attempts` (object, keyed by `"<gate>:<step>"` → int)
- `rework_log` (array of objects per §3)
- `build_attempt.token_spend` (int | null)

The `run.json` configuration snapshot field added:

- `rework_config` (object with the four values from §6)

Schema-version bumped by one from TDD 0018's value.

## Sequencing / implementation plan

1. **Add config knobs + run.json snapshot.** Extend the existing
   config-snapshot code path in `state_init` (or wherever
   `run.json.config` is populated) to include `rework_config`. Add the
   four env-var reads + defaults.
2. **Add fragment schema fields + setters.** Extend `scripts/lib/state.sh`
   with `_extract_token_spend`, `_record_rework_attempt`, and the
   `rework_attempts` increment helper.
3. **Implement `_rework_pre_pass` in `scripts/lib/gates.sh`.** Implement
   the three checks from §1 against a given new-head SHA and the cleared
   SHA from TDD 0020. **TDD 0020 dependency:** this step reads
   `last_cleared_review_sha` from the fragment (TDD 0020 §4 field). When
   building this TDD ahead of TDD 0020, the field is absent; the
   §Failure modes §5 fallback (use the build's start SHA) MUST be wired
   in the same change. Failing to wire the fallback would NullPointer-
   like crash on any rework attempt until TDD 0020 lands.
4. **Implement `_rework_one` in `scripts/lib/gates.sh`.** Spawn the
   rework `claude -p` with the prompt template, model, and resulting
   commit handling.
5. **Wire the loop into `_review_one_gated`.** On `REVIEW_RESULT: BLOCK`
   with halting findings: check FR-67(c) tag → if set, BLOCK; else
   increment attempt count → if over `THROUGHLINE_REWORK_MAX`, BLOCK
   with `rework-budget-exhausted`; else call `_rework_one`; then
   `_rework_pre_pass`; on clear, advance to the next review pass; on
   `PRECHECK_FAIL`, hard-reset and BLOCK with the corresponding cause.
6. **Add the rework-prompt template** at
   `scripts/rework-prompt.md` with the content from §5.
7. **Record the original-build token spend.** Update `build_one` (or its
   gated wrapper in `scripts/lib/gates.sh`) to call
   `_extract_token_spend` on the build session JSON and store the result
   on the fragment.

## Failure modes & edge cases

- **Empty / multi-commit rework.** `_rework_pre_pass` reads the new HEAD
  minus the prior cleared SHA; empty diff records `outcome: empty-diff`
  and still increments the attempt counter; multiple commits are
  evaluated as one diff against the cap.
- **Finding cites multiple regions.** TDD 0021 splits one multi-region
  finding into separate findings, each with its own `region_lines`; the
  rework loop processes one finding at a time.
- **Opportunistic refactoring slips through.** The per-file bound +
  touched-file-set checks reject it as structural. Sonnet's reduced
  refactoring tendency is the rationale for the model choice; the
  structural-rejection check is the safety net.
- **Token-spend extraction fails.** Records `token_spend: null`. FR-68
  acceptance compares numeric values only; nulls fall outside the
  comparison without invalidating other telemetry.
- **Cleared SHA missing.** `_rework_pre_pass` falls back to the build's
  start SHA — degraded mode (bounds checked against full TDD diff) but
  safer than skipping the check.

## Verification plan

**Observable surface:** the TDD fragment's `rework_log`, `rework_attempts`,
the BLOCKERS.md file's append entries, and the `git log` of the build
branch (rework commit subjects + hard-resets).

**Observation points:**

1. **Single fixable finding → rework succeeds → finding resolved.**
   Construct a fixture TDD whose first review pass emits exactly one
   `major` finding with `region_lines: 8`, no `structural: true` tag, on
   a file inside the touched-file set. Run `/implement`. Expect:
   `rework_log` contains one entry with `gate: review`, `attempt: 1`,
   `model: sonnet`, `outcome: shipped`; the next review pass clears.
2. **Reviewer-tagged structural → no rework, BLOCKED.** Fixture where
   the review pass emits a finding with `structural: true`. Expect: no
   `rework_log` entries; fragment `halt_cause: structural-finding`;
   `BLOCKERS.md` has an appended entry naming the TDD, the gate-step
   pair, criterion `(c)`, and finding excerpt.
3. **Oversized rework commit → rejected → BLOCKED.** Fixture where the
   rework model produces a 200-line commit for an 8-line region (cap =
   max(60, 24) = 60). Expect: `rework_log` entry with `outcome:
   rejected:rework-scope-exceeded`; the build branch's HEAD is reset to
   the prior cleared SHA (verified by `git log --oneline -5`); fragment
   `halt_cause: rework-scope-exceeded`.
4. **Rework touches out-of-set file → rejected as structural(a).**
   Fixture where the rework commit edits a file not in the TDD's
   `## Touched files` list. Expect: `rework_log` entry with `outcome:
   rejected:structural-finding(a)`; fragment `halt_cause:
   structural-finding`; BLOCKERS.md entry naming criterion `(a)`.
5. **Rework overshoots per-file bound → structural(b) BLOCKED.** Rework
   adds 80 lines to a file declared at 50 lines (no exception). Expect:
   `outcome: rejected:structural-finding(b)`; BLOCKERS.md entry naming
   criterion `(b)`.
6. **Budget exhaustion → BLOCKED.** Fixture where each rework ships a
   clean commit that fails to resolve the finding. With
   `THROUGHLINE_REWORK_MAX=3`: three `rework_log` entries (`outcome:
   shipped`); the fourth halting finding halts the TDD with `halt_cause:
   rework-budget-exhausted`; `rework_attempts == {"review:<step>": 3}`.
7. **Telemetry + config + model wiring.** Across the fixtures above:
   every `rework_log` entry has `token_spend` (int or null);
   `build_attempt.token_spend` is populated; `run.json.config.rework_config`
   carries the four §6 values; `build_attempt.model == "opus"` and all
   `rework_log[*].model == "sonnet"` (NFR-3 gate-boundary diversity
   preserved).

**Expected observations (PASS):** every numbered observation point above
yields the cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-61 (halting findings trigger in-invocation rework) | §1 `_rework_one` + §5 wiring into `_review_one_gated`; user is not asked to drive between finding and convergence |
| FR-62 (bounded in-invocation automatic rework) | §1 + §2 (attempt cap) + §4 (structural escalation); the loop closes within one `/implement` invocation |
| FR-65 (rework budget bound + design escalation on exceed) | §2 `rework_attempts` + `THROUGHLINE_REWORK_MAX`; on exceed → BLOCKED with `rework-budget-exhausted` cause (from TDD 0018's enum) + BLOCKERS.md entry |
| FR-66 (bounded rework scope per attempt) | §1's `_rework_pre_pass` scope-cap check; cap = `max(60, 3 × region)` defaults; oversized commits rejected, recorded with `rework-scope-exceeded` cause. **Degraded mode pre-TDD-0020:** until TDD 0020 ships `last_cleared_review_sha`, the scope cap runs against the build's start SHA instead of the per-step cleared SHA (per §Failure modes §5). FR-66's full acceptance is met only after both this TDD and TDD 0020 land; this TDD's `_rework_pre_pass` is independently buildable in degraded mode, but the full per-step scope guarantee requires TDD 0020 too. |
| FR-67 (structural-finding escalation, not local sweep) | §1's FR-67(a), (b) retrospective checks + §4's `structural-finding` halt cause + BLOCKERS.md routing; FR-67(c) checked predictively from the reviewer's `structural: true` tag (TDD 0021) |
| FR-68 (rework cost less than original build cost, observable) | §3 `rework_log[*].token_spend` + `build_attempt.token_spend` recorded per FR-27 extension; no hard cap (telemetry-only) |
| Rework-on-Sonnet model wiring (design-plan addendum, preserves NFR-3) | §6 `THROUGHLINE_REWORK_MODEL=sonnet` default; gate 1 first attempt remains Opus (preserving model diversity at the gate-1/gate-d boundary) |

No gaps.

## Dependencies considered

No new external dependencies. Token-spend extraction reads the session
JSON the Claude Code SDK already writes.

Alternatives considered:
- **Predictive structural detection (reviewer estimates fix scope before
  rework runs)** — rejected: accurate prediction needs the data only the
  rework commit produces; retrospective detection on the actual diff is
  cheaper, more accurate, and aligns with ADR 0006.
- **Hard per-attempt token cap aborting mid-rework** — rejected per the
  design plan: the attempt-count cap is the aggregate enforcement; a hard
  cap risks aborting legitimate cases mid-rework.

## PRD conflicts surfaced (and resolution)

The PRD defers "ci-checks.sh / runtime-verify gate participation in the
rework loop" to this TDD. This TDD scopes the rework loop to the review
gate (gate d) only. `ci-checks.sh` failures are not findings in the FR-58
sense and do not trigger FR-61; runtime-verify (gate v) failures continue
to halt the TDD under existing semantics. A future TDD can extend the
rework loop to runtime-verify if cost telemetry from this TDD's
deployment justifies it.

## Decisions to promote (ADR candidates)

- **ADR 0007 — Halt model: bounded rework + structural escalation.** This
  TDD's behavior is the operational expression of ADR 0007's
  disposition. Promotion confirmed by the design plan; high confidence.

## Carry-over findings from TDD 0017 review (folded into scope)

The independent review of TDD 0017 (PR #48) surfaced four MAJOR findings
in code moved verbatim from the pre-extraction `implement.sh`. Per that
TDD's "verbatim move" contract they were not fixed inline. Since this
TDD already touches `scripts/lib/gates.sh` and the rework loop interacts
directly with the affected sites (a flip after rework needs honest exit
codes; the structural-escalation path relies on `record_blocker`), the
fixes fold here. All four are fail-loud / propagate-exit-code patches —
no behavioral semantics change.

1. **`flip_status` swallows git failures (`gates.sh:152-156`).** `git
   add` / `git commit` redirected to log with no exit-code check; a
   failed commit produces a false `OK (verified + reviewed)`. Fix:
   propagate non-zero through `flip_status` → `gate_one` flip site, so
   a flip failure halts honestly rather than appearing as success.
2. **`install_deps` swallows total-failure (`gates.sh:184-187`).**
   When BOTH the frozen-lockfile install AND the plain install fail,
   the final `echo` returns 0 (the echo's exit). Fix: track the
   attempts' exit codes and `return 1` after the diagnostic; callers
   in `implement.sh` already check rc.
3. **`record_blocker` writes to the wrong tree (`gates.sh:158-163`).**
   `${MAINREPO:-$PWD}` falls back to the worktree's `$PWD` in parallel
   mode; blockers land in the worktree's `BLOCKERS.md` (deleted with
   it) instead of the main repo. Fix: drop the fallback and fail-loud
   FATAL if `MAINREPO` is empty (its setting is unconditional in
   `implement.sh` startup).
4. **`STATE_DIR` unset → silent state corruption (`resume.sh:252, :286,
   :339`).** `${STATE_DIR:-}/$slug.json` expands to `/$slug.json` when
   unset; the MA-4 guard at :252 short-circuits on the same condition
   rather than firing. Fix: drop the `:-` fallbacks at all three sites
   and fail-loud FATAL at the resume entry; `STATE_DIR` is set
   unconditionally by `state_init`.

Verification: extend the existing `state-module-sourceability` and
`run-recovery` suites with one fixture per finding (total-install-fail,
flip-fail, MAINREPO-unset, STATE_DIR-unset) confirming the runner halts
non-zero with the expected diagnostic rather than silently passing.

## Scope override

This TDD's doc body is over the 350-line default `THROUGHLINE_TDD_MAX_LINES`
cap established by TDD 0014. Justification: the six FRs in scope (FR-61,
FR-62, FR-65, FR-66, FR-67, FR-68) describe a single coupled mechanism —
the bounded automatic rework loop. Splitting across multiple TDDs would
fragment the loop's wiring (decoupling the loop trigger from its bound
enforcement) or duplicate the mechanism description in each TDD. The
override is recorded here per FR-53's escape clause (legitimately-wide-
but-shallow design; single mechanism with multiple bound-enforcement
clauses). This TDD is also the first user of TDD 0014's override flow,
dogfooding the mechanism.

## Touched files

- `scripts/lib/gates.sh` (post-TDD-0017) — `_rework_one`, `_rework_pre_pass`,
  wiring into `_review_one_gated`, token-spend extraction; plus carry-over
  fixes 1-3 to `flip_status` / `install_deps` / `record_blocker`
- `scripts/lib/resume.sh` (post-TDD-0017) — carry-over fix 4: drop
  `${STATE_DIR:-}` fallbacks at the three resume call sites
- `scripts/lib/state.sh` (post-TDD-0015) — fragment field additions for
  `rework_log` / `rework_attempts` / `build_attempt.token_spend`, plus
  schema-version bump
- `scripts/implement.sh` (post-TDD-0017) — `state_init` extension to write
  `rework_config` into `run.json`
- `scripts/rework-prompt.md` — new file, §5 prompt content
- `skills/implement/SKILL.md` — one paragraph documenting the rework loop's
  user-visible contract (no user prompt during fixable rework; halt only
  on FR-67 / FR-65 exhaustion)
- `tests/run-recovery.test.sh` + `tests/state-module-sourceability.test.sh`
  — one fixture per carry-over finding (total-install-fail, flip-fail,
  MAINREPO-unset, STATE_DIR-unset)

Total: 7 files touched.

## Expected diff size

- `scripts/lib/gates.sh` — ~250 lines added (`_rework_one`,
  `_rework_pre_pass`, wiring, helpers) + ~20 lines for carry-over
  fixes 1-3 (`flip_status` / `install_deps` / `record_blocker`)
  (exception: this file is being delivered by TDD 0017 at ~250
  lines; the additions push it to ~520 — declared wide-but-shallow
  code addition for cohesion: the rework loop belongs alongside the
  other gate executors, splitting it would fragment the
  gate-executor cluster)
- `scripts/lib/resume.sh` — ~10 lines for carry-over fix 4
- `scripts/lib/state.sh` — ~80 lines added
- `scripts/implement.sh` — ~15 lines added (`rework_config` snapshot)
- `scripts/rework-prompt.md` — ~50 lines (new file)
- `skills/implement/SKILL.md` — ~20 lines added
- `tests/run-recovery.test.sh` + `tests/state-module-sourceability.test.sh`
  — ~40 lines added (4 carry-over fixtures)

Total expected diff: ~485 lines across 7 files.

# TDD 0013: Token-spend reduction — mechanical pre-checks + verification-gate model tiering

Status: draft
PRD refs: FR-51, FR-52 (new)
PRD-rev: d766d2d
ADR constraints: 0003, 0004, 0005

> **Pipeline note.** This TDD was authored in the same pass that produced
> TDDs 0011 + 0012, ahead of its covering FRs being landed in the PRD; the
> "preferred resolution path" was then taken — FR-51 and FR-52 were landed
> via a follow-up `/prd-author` pass (PR #33, commit `d766d2d`). The
> traceability gap has been closed; the FR text in `docs/PRD.md` is the
> same substance lifted from this TDD's traceability table. This note is
> retained as a historical pointer; no further action is required.

> **Cross-ref to TDD 0019 (FR-68).** A sibling token-spend reduction
> surface landed in the same design pass as this TDD's deferred build:
> FR-68 (rework-attempt token-spend telemetry) is implemented by
> TDD 0019. The two reductions are independent — this TDD covers the
> design-reviewer pre-pass (FR-51) and the runtime-verify gate's model
> tiering (FR-52); TDD 0019 covers per-attempt token-spend recording
> for the bounded automatic rework loop. Neither overlaps the other's
> mechanism or scope.

## Approach

Two independent reductions in per-flow token spend, neither of which
changes any user-visible behavior of the pipeline:

1. **Mechanical pre-checks before the LLM design-reviewer (FR-51).**
   A plain shell pre-pass runs against the authored TDD set
   inside `/tdd-author` step 7b, BEFORE spawning the
   `design-reviewer` subagent. It detects the structural-gap findings
   the reviewer currently produces — missing `## Verification plan`,
   missing `## Dependencies considered`, missing
   `## Requirement traceability` table, missing frontmatter
   (`Status:`, `PRD refs:`, `PRD-rev:`, `ADR constraints:`), obvious
   placeholder strings (`TBD`, `verify it works`, `tests will pass`,
   `handle errors appropriately`, `the change works as expected`,
   `add validation`, bare `## Section\n##` adjacencies indicating an
   empty section), and untraced FR/NFR (a structural diff between
   the TDD's `PRD refs` line and the requirement-IDs that appear in
   the traceability table). If any structural gap is found, the
   pre-pass surfaces them and the skill BLOCKs locally — the
   reviewer subagent is never invoked. The reviewer continues to run
   when the pre-pass is clean; its remaining work (judgment-driven
   findings like scope coherence, interface vagueness, ADR conflicts)
   is exactly what an LLM is irreplaceable for.

2. **Model tiering for the runtime-verify gate (FR-52).**
   `verify_runtime_one` currently runs on the build model (opus by
   default per the runner's comment: "the gate needs the capability
   to drive the artifact"). For verification plans whose observations
   are mechanical (CLI exit code, log line grep, file presence, HTTP
   status code), opus is overkill. A heuristic — readable from the
   TDD's `## Verification plan` section by the runner before
   spawning `claude -p` — picks `sonnet` for mechanical plans and
   keeps the build model for plans requiring browser/UI driving,
   multi-step interactive flows, or judgment about ambiguous outputs.
   Escape hatch: `THROUGHLINE_RUNTIME_VERIFY_MODEL` env var pins a
   model unconditionally, matching the existing
   `--review-model`/`THROUGHLINE_REVIEW_MODEL` pattern.

Both reductions preserve the four-gate system's correctness contract
(NFR-3 reviewer-diversity, NFR-4 verdict-honesty); neither one
weakens a gate's judgment, both reduce the cost of a clean run.

## Components & interfaces

### FR-51 — Mechanical pre-checks before design-reviewer

1. **`scripts/lib/tdd-lint.sh` (new).** Sourced helper.

   **Unified exit-code contract — applies to every function in this
   file, including the three lints and the aggregate wrapper:**
   - exit `0` — no findings, or only `nit`-severity findings.
   - exit `1` — at least one `major`-severity finding (no
     `blocker`).
   - exit `2` — at least one `blocker`-severity finding (regardless
     of any other findings).
   This is a single, file-wide convention. Each individual lint
   function and `tl_lint_all` follow it identically, so an
   implementer reading any function in isolation gets the same
   contract; the aggregate wrapper does NOT need to parse stdout
   for severity — it computes its exit code as `max(rc of each
   sub-lint)` and stops at the first `2`.

   All four functions emit findings to stdout in the format
   `<file>:<line> <severity> <code>: <msg>` (one per line),
   regardless of exit code. Findings always print; the exit code
   is the routable signal.

   - `tl_lint_structural <tdd-path>` — checks for required sections
     and frontmatter. Specific rules (`grep -q` against the file):
     - blocker `frontmatter.status` — line matching
       `^Status: (draft|ready|implemented)$` exists.
     - blocker `frontmatter.prd_refs` — line matching
       `^PRD refs:` exists.
     - blocker `frontmatter.prd_rev` — line matching `^PRD-rev:`
       exists (or `Supersedes:` is present, in which case PRD-rev is
       optional).
     - blocker `section.approach` — `^## Approach$` exists.
     - blocker `section.verification_plan` — `^## Verification plan$`
       exists.
     - blocker `section.deps_considered` — `^## Dependencies
       considered$` exists.
     - blocker `section.traceability` — `^## Requirement
       traceability$` exists AND the section contains either a
       markdown table (rows starting with `|`) or a definition list
       (lines starting with `- FR-`/`- NFR-`).
     - major `section.empty` — any two consecutive `^## ` headings
       (excluding the file's first `# Title`) with no non-blank,
       non-table-separator content between them. Implementation: a
       single awk pass that tracks the line number of the last `^## `
       heading and the count of non-blank lines since; when a new
       `^## ` arrives with count == 0, emit the finding against the
       previous heading's line.

   - `tl_lint_placeholders <tdd-path>` — `grep -Fi` against an
     allowlist of forbidden phrases:
     ```
     TBD
     verify it works
     verify it is correct
     tests will pass
     the change works as expected
     handle errors appropriately
     handle errors gracefully
     add validation
     to be determined
     to be decided
     ```
     Each match is a `major`-severity finding (not always a true
     gap — "TBD" inside a quoted example is legal — but always
     worth surfacing). Two well-known false-positive patterns
     are silenced: TBD inside a code block (between ` ``` `
     fences) and `<TBD>` inside angle brackets (template
     metasyntax). Implementation: a small awk pass that tracks
     in-fence state.

   - `tl_lint_traced <tdd-path>` — extracts the PRD ref list
     from `^PRD refs:` and the requirement IDs (`FR-\d+` /
     `NFR-\d+`) that appear under the `## Requirement
     traceability` section; emits a `major` finding per ID in
     PRD refs that does not appear in the traceability section.

   - `tl_lint_all <tdd-path-or-glob>` — runs the three lints over
     each TDD in turn. **All three lints always run** to accumulate
     complete findings; there is no early-exit. Exit code per the
     unified contract above: the function tracks the maximum exit
     code returned by any sub-lint and returns that (capped at 2).
     Stdout is the concatenation of each sub-lint's findings,
     prefixed by the lint's name to make sources traceable.

2. **`agents/design-reviewer.md` (modified).** Add a "Pre-check
   already ran" preamble paragraph: "The skill that invokes you
   has already run `scripts/lib/tdd-lint.sh` against this TDD set
   and is invoking you only because the mechanical pre-checks
   were clean (or were waived). Spend your judgment on the
   findings only a model can produce: scope coherence, interface
   vagueness, ADR conflicts, missing alternatives reasoning,
   naming consistency across TDDs. Do NOT re-do the mechanical
   pre-checks. **If, while doing your judgment-driven work, you
   nevertheless notice a structural gap the pre-pass should have
   caught** (e.g., a missing section, an obvious placeholder, an
   untraced requirement), include it in your findings list at
   `nit` severity — never suppress it — and indicate it was
   missed by the pre-pass. This keeps a missed pre-pass pattern
   visible to the human reviewer without re-doing structural
   work on every TDD; do not downgrade or omit such a finding
   silently." This nudges the reviewer toward its irreplaceable
   work without weakening its overall posture.

3. **`skills/tdd-author/SKILL.md` (modified).** In step 7a (Author
   self-review), append: "Before moving to 7b, run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tdd-lint.sh" docs/tdd/<your-set>` and
   address every finding. If `tl_lint_all` exits non-zero, fix the
   findings or record an explicit waiver in the design PR body
   before invoking the design-reviewer in 7b. The design-reviewer
   subagent is NOT invoked when there are unaddressed
   mechanical findings — that would waste tokens on work a
   `grep` already did."

   In step 7b (Independent design critique gate), prepend the
   sub-bullet: "Pre-requisite: `tl_lint_all` exit 0 (or recorded
   waiver). The design-reviewer assumes the pre-pass is clean;
   spawning it on a structurally-broken TDD set is the wrong
   tool for the job and burns tokens."

### FR-52 — Model tiering for the runtime-verify gate

4. **`scripts/lib/plan-classifier.sh` (new).** One function:

   - `tl_classify_plan <tdd-path>` → echoes `mechanical | nontrivial`
     based on the TDD's `## Verification plan` section. Algorithm
     (pure regex/grep — no LLM):
     - Read the lines between `## Verification plan` and the next
       `^## ` heading.
     - If the section contains ANY of: `browser`, `DOM`,
       `Playwright`, `Selenium`, `screenshot`, `interactive`,
       `multi-step`, `multi-turn`, `judgment`, `rendered output`,
       `UI`, `WebSocket` → echo `nontrivial`. (Note: the bare word
       "streaming" is intentionally NOT in this list — a plan that
       verifies a streaming endpoint via log-line grep is mechanical.
       The keyword `WebSocket` covers the protocol-level streaming
       case that actually needs interactive driving; SSE / chunked
       HTTP plans typically observe via `curl` + line-count and
       belong in the mechanical path.)
     - Else if the section contains ALL evidence of mechanical
       observation: at least one of `exit code`, `exits 0`, `exit 1`,
       `stdout`, `grep`, `HTTP 2`, `HTTP 4`, `HTTP 5`, `returns`,
       `log line`, `file exists`, `[ -f`, `cmp`, `diff`,
       `byte-identical`, `JSON` → echo `mechanical`.
     - Default: echo `nontrivial` (conservative — when in doubt, use
       the build model so we don't downgrade an actually-judgment-
       heavy plan).

5. **`scripts/implement.sh::verify_runtime_one` (modified).** Before
   the existing `claude` invocation, classify the plan and pick the
   model:
   ```bash
   verify_runtime_one() {  # <tdd> <base-ref> <log>
     local tdd="$1" base="$2" log="$3" prompt cls vm
     prompt="$(sed -e "s#{{TDD}}#${tdd}#g" -e "s#{{BASE}}#${base}#g" "$RVMTPL")"
     # Model tiering (FR-52). Env override always wins.
     vm="${THROUGHLINE_RUNTIME_VERIFY_MODEL:-}"
     if [ -z "$vm" ]; then
       cls="$(tl_classify_plan "$tdd")"
       case "$cls" in
         mechanical) vm="sonnet" ;;
         *)          vm="$MODEL" ;;
       esac
     fi
     local args=(-p "$prompt" --permission-mode auto)
     [ -n "$vm" ] && args+=(--model "$vm")
     local start; start=$(date +%s)
     claude "${args[@]}" >>"$log" 2>&1
     record_session_pointer "$log" "$start"
   }
   ```
   The function sources `tl_classify_plan` from
   `scripts/lib/plan-classifier.sh`. The log line written by
   `record_session_pointer` carries the model used implicitly via
   the session JSONL pointer; an explicit log line
   `runtime-verify model=$vm (plan=$cls)` is appended just before
   the `claude` call for triage.

6. **`scripts/verify-runtime-prompt.md` (no change).** The prompt
   already says "You are running on the build model deliberately —
   the gate needs the capability to drive the artifact"; that
   sentence is no longer universally true. Replace it with: "You
   are running on a model the runner chose based on the
   verification plan's complexity (mechanical observations →
   sonnet; nontrivial → the build model). Regardless of model, you
   are in a FRESH process, so you are independent of the build's
   own self-report." This is a minor prompt edit, not a re-design.

7. **`scripts/implement.sh` header comment (modified).** The
   "four independent gates" enumeration's gate-3 description today
   says "a SEPARATE `claude -p` process drives the BUILT artifact …
   on the build model (capability to drive the artifact)". Update
   to "on a model the runner tiers based on the verification plan's
   complexity (mechanical observations → sonnet; nontrivial → the
   build model); override via `THROUGHLINE_RUNTIME_VERIFY_MODEL`."

8. **`skills/implement/SKILL.md` "Notes" (modified).** Add a line
   between the existing `THROUGHLINE_REQUIRE_TEST_FIRST` and
   `THROUGHLINE_REQUIRE_RUNTIME_VERIFY` bullets:
   "`THROUGHLINE_RUNTIME_VERIFY_MODEL` pins the runtime-verify
   gate's model unconditionally (default is heuristic: sonnet for
   mechanical plans, build model otherwise)."

## Data & state

This TDD introduces no persistent on-disk state. The only artifacts
it changes:

- `scripts/lib/tdd-lint.sh` (new) and `scripts/lib/plan-classifier.sh`
  (new). Both pure functions, no IO outside reading their input
  files.
- The runner gains a per-gate log line stating the model and plan
  classification used (FR-52). This is observational, not state.

The mechanical pre-pass (FR-51) writes its findings to stdout and
exits non-zero; the skill captures them inline. No findings file is
persisted (the design PR body carries any recorded waivers, per
the existing design-PR template).

## Sequencing / implementation plan

1. **`scripts/lib/tdd-lint.sh` with its three lint functions.** Land
   with a small fixture set under `tests/fixtures/tdds/` (one TDD
   clean, one missing-verification-plan, one with `TBD` outside a
   fence, one with `TBD` inside a fence, one with an untraced FR).
   Each fixture is its own test case asserting the lint script's
   exit code and the substring of its stdout (the unified
   exit-code contract makes stdout the sole findings channel; stderr
   is reserved for runtime errors of the script itself).
2. **`scripts/lib/plan-classifier.sh::tl_classify_plan`.** Land with
   fixture TDDs containing: a CLI exit-code plan (`mechanical`), a
   browser/Playwright plan (`nontrivial`), an HTTP-200-and-body plan
   (`mechanical`), a plan that mixes both (`nontrivial`,
   conservative default), a plan with no obvious markers (`nontrivial`).
3. **`agents/design-reviewer.md` preamble + `skills/tdd-author/SKILL.md`
   step-7a / 7b edits.** Verification by reading the files back
   (mechanical: `grep -q "Pre-check already ran" agents/design-reviewer.md`).
4. **`scripts/implement.sh::verify_runtime_one` modification + header
   comment update + `skills/implement/SKILL.md` notes line.**
   Verification by running the runner against a fixture TDD whose
   plan is mechanical, then against one whose plan is nontrivial,
   and asserting (per-TDD log) the chosen model is `sonnet` then
   `opus`.

The two reductions are independent — step 1-3 (FR-51) and step 4
(FR-52) can land in either order. They share no helper and touch
disjoint surfaces.

## Failure modes & edge cases

- **A genuine `TBD` is in a quoted example in a TDD body** (e.g., a
  TDD describing the design-reviewer's behavior quotes the literal
  string `TBD` as a placeholder it would flag). The placeholder
  lint silences `<TBD>` and TBD-in-fences but not free-text TBD in
  prose. False positives are a `major`-severity finding, not a
  hard block; the TDD author addresses them or records a waiver
  ("the TBD in section §X is a quoted example of the lint
  matching, not an actual placeholder").
- **A TDD set with a mechanical verification plan that the
  classifier mis-labels as nontrivial.** Falls back to the build
  model — no correctness impact, just no token saving for that
  gate. Conservative by design.
- **A TDD set with a nontrivial plan that the classifier mis-
  labels as mechanical.** This is the only correctness risk —
  sonnet may lack the capability to drive a complex artifact (e.g.,
  a Playwright browser flow). The mitigation: NFR-4 honesty
  remains in force at the runtime gate — sonnet emits `FAIL` /
  `BLOCKED` when it can't observe, never a false PASS. So the
  worst case is a wasted gate run that the next iteration fixes
  by either (a) refining the plan's text to include a `nontrivial`
  trigger keyword, or (b) pinning `THROUGHLINE_RUNTIME_VERIFY_MODEL=opus`
  in the env for the run. The classifier's default-nontrivial bias
  makes this rare.
- **The pre-pass exits non-zero on a TDD set where the user wants
  to proceed anyway (e.g., a deliberate `TBD` in a quoted
  example).** The design-PR body's waiver section is the recorded
  override; the skill's step 7b allows proceeding when the
  findings are explicitly waived. This is the existing
  design-reviewer-waiver pattern from FR-10, extended to the
  pre-pass.
- **The pre-pass finds a structural gap the design-reviewer would
  also have caught.** Token saving is correctly realized — the
  skill BLOCKs at step 7a; the user fixes the TDD; on re-run the
  pre-pass is clean and the design-reviewer runs once on a
  TDD set worth reviewing. Net: 1 reviewer invocation instead
  of (gap-fix + reviewer + waste of context on the gap-fixed
  re-review = ~2× sonnet cost saved).
- **The classifier file `scripts/lib/plan-classifier.sh` is
  missing at runtime** (e.g., a manual install that excluded it).
  `verify_runtime_one` should fail safely: if the sourced helper
  isn't present, the function falls back to the unconditional
  `$MODEL` it uses today (logged with `runtime-verify model=$vm
  (classifier missing)`). No correctness regression.
- **Old `tdd-lint.sh` checks vs. a TDD format evolution.** If the
  TDD template gains a new required section (e.g., a future
  `## Token budget` section), the lint allowlist needs updating.
  This is a minor maintenance burden; the test fixtures catch
  the omission immediately.

## Verification plan

**Observable surface:**
- `scripts/lib/tdd-lint.sh` stdout (findings) and exit code.
- `scripts/lib/plan-classifier.sh::tl_classify_plan` stdout
  (`mechanical` / `nontrivial`) and exit code.
- The per-TDD log line `runtime-verify model=$vm (plan=$cls)` in
  `docs/tdd/.implement-logs/<ts>/<slug>.log`.
- The session JSONL pointed at by the FR-36 line in the gate log
  (the `--model` flag is recorded there).
- The contents of `agents/design-reviewer.md`,
  `skills/tdd-author/SKILL.md`, `skills/implement/SKILL.md`,
  `scripts/implement.sh` (greppable).

**Observation points & expected observations (PASS):**

1. **FR-51 pre-pass blocks on missing verification plan.** Run
   `bash scripts/lib/tdd-lint.sh tests/fixtures/tdds/missing-vp.md`.
   Observe: exit code 2 (blocker-severity per the unified contract);
   stdout contains a finding line ending with `section.verification_plan: …`
   (stdout is the sole findings channel — stderr stays clean unless the
   script itself encounters a runtime error such as a missing input file).
2. **FR-51 pre-pass passes clean on a well-formed TDD.** Run
   `bash scripts/lib/tdd-lint.sh docs/tdd/0007-verification-as-observation.md`
   (a known-clean implemented TDD). Observe: exit code 0; stdout empty
   (or contains only `nit`-severity findings).
3. **FR-51 placeholder lint distinguishes prose-TBD from
   fenced-TBD.** Run on a fixture containing both. Observe: only
   the prose-TBD line appears as a `major` finding; the fenced
   line is silent.
4. **FR-51 traceability lint catches untraced FRs.** Run on a
   fixture whose `PRD refs: FR-1, FR-2, FR-3` line is not fully
   reflected in the requirement-traceability table (FR-3 missing).
   Observe: a `major` finding naming `FR-3`.
5. **FR-51 design-reviewer not invoked when lint exits non-zero.**
   Wire `/tdd-author` step 7a to call the lint script (no LLM call
   yet); fixture: a TDD set with a missing-vp file. Observe:
   the skill's transcript contains no `Task` tool call to
   `design-reviewer`; the skill produces a block message naming
   the lint findings.
6. **FR-52 mechanical plan → sonnet.** Run `/implement` against a
   fixture TDD whose verification plan grepped for
   `exit code` / `stdout`. Observe: the per-TDD log contains
   the line `runtime-verify model=sonnet (plan=mechanical)`
   before the `claude` invocation's stderr/stdout.
7. **FR-52 nontrivial plan → build model.** Run `/implement`
   against a fixture TDD whose plan contains `browser` or
   `Playwright`. Observe: log contains
   `runtime-verify model=opus (plan=nontrivial)` (or whatever the
   build model is).
8. **FR-52 env override wins.** Set
   `THROUGHLINE_RUNTIME_VERIFY_MODEL=opus`; run against a
   mechanical-plan TDD. Observe: log contains
   `runtime-verify model=opus`; the classifier's choice is
   ignored.
9. **FR-52 sonnet runtime-verify still honors NFR-4.** Run
   `/implement` on a TDD whose mechanical plan is intentionally
   wrong (e.g., `exit 0` expected but the artifact returns 1).
   Observe: the runtime-verify verdict is `FAIL` (not a false
   PASS); the TDD is not flipped to `implemented`. (Token saving
   is not allowed to relax verdict honesty.)

(Mechanism is the project's — plain shell + `grep` + fixture
files — delegated, not bundled, per FR-26 / ADR 0004.)

## Requirement traceability

| PRD | Design element |
|---|---|
| FR-51 Mechanical pre-pass before LLM design-reviewer | `scripts/lib/tdd-lint.sh` (three lints) + `skills/tdd-author/SKILL.md` step-7a edit invoking it + `agents/design-reviewer.md` preamble acknowledging the pre-pass |
| FR-52 Verification-gate model tiering | `scripts/lib/plan-classifier.sh::tl_classify_plan` + `scripts/implement.sh::verify_runtime_one` model-tiering branch + `scripts/verify-runtime-prompt.md` model-context sentence edit + `skills/implement/SKILL.md` env note |

## Dependencies considered

**No new external dependencies.**

- `tdd-lint.sh` uses `grep`, `awk`, `sed` (POSIX). The `awk` pass
  for code-fence-aware TBD detection is the most complex part;
  it is small enough to inline.
- `plan-classifier.sh` uses `grep` + `sed` only.
- `verify_runtime_one`'s model-tiering reuses the existing
  `--model` flag mechanism (TDD 0005 / NFR-3 already plumbs
  this).

Rejected alternatives evaluated:
- **Use an LLM to do the pre-check** (a small claude-haiku call
  reading the TDD and emitting structured findings). Rejected:
  the structural checks (`grep`-able regex) are deterministic and
  free; an LLM would re-introduce per-invocation cost (smaller
  than sonnet, still nonzero) and bring back the unreliability
  of "did the model actually catch it" without measurable
  benefit. The lint's blast radius is precisely the structural
  gaps a `grep` can find; everything else stays the
  design-reviewer's job.
- **Replace the design-reviewer entirely with the pre-pass.**
  Rejected as a misread of where the LLM reviewer adds value:
  scope coherence, interface vagueness, ADR conflicts, missing
  alternatives reasoning, and naming consistency across TDDs all
  require model judgment. The design-reviewer is what keeps
  throughline from rubber-stamping TDDs that are
  structurally-OK-but-semantically-broken.
- **A bash lint that calls into `jq`/`yq` to parse TDD
  frontmatter strictly.** Rejected: TDD frontmatter is plain
  Markdown lines (not YAML between `---` fences); adding a YAML
  parser would either require rewriting all existing TDDs to YAML
  frontmatter or wrapping the existing format in something
  awkward. The current `^Status:` / `^PRD refs:` regex is good
  enough.
- **Always run runtime-verify on sonnet.** Rejected:
  verification plans that drive a browser, a multi-turn UI, or
  judge ambiguous output need opus capability. NFR-4 honesty
  helps but does not eliminate the cost of a BLOCKED runtime
  verdict followed by a re-run on opus.
- **Always run runtime-verify on the cheapest available
  model (haiku).** Rejected: haiku's tool-use capability is
  weaker for shell/HTTP/JSON inspection workflows; we'd see
  more false BLOCKED verdicts on plans sonnet handles cleanly.
  Sonnet is the right floor for runtime-verify per current
  capability data.
- **Have the LLM design-reviewer itself recognize "this is a
  trivial check I shouldn't do" and short-circuit.** Rejected:
  the reviewer is already loaded with PRD + TDD + ADR context
  before it can decide to short-circuit; the token has been
  spent. The shell pre-pass shifts the decision left to where
  it costs nothing.

## PRD conflicts surfaced (and resolution)

None remaining. This TDD was authored against PRD `9626a59`, which did
not yet contain its covering FRs; a follow-up `/prd-author` pass landed
FR-51 + FR-52 verbatim from the traceability table above (PR #33,
commit `d766d2d`). The traceability is now clean: every FR in the table
exists in `docs/PRD.md`, and the design substance here was not modified
to fit the PRD — the PRD adopted the substance from here. The "Pipeline
note" at the top of this TDD is retained as a historical pointer.

No entries in `docs/tdd/BLOCKERS.md` to resolve (the file does not
exist).

## Decisions to promote (ADR candidates)

**None.**

- The mechanical-pre-check approach extends the "govern not bundle"
  pattern (ADRs 0003–0005) onto a new axis (validation cost),
  using the same shell + regex tooling. The principle is already
  ADR'd at the more general level; this TDD applies it.
- The model-tiering choice is a tuning decision, not a
  cross-cutting architectural one. Embedded in the runner with an
  env-override is the right level of ceremony.
- The "land the PRD requirements before merging the design PR"
  pipeline-order discipline is captured in throughline's existing
  PRD → TDD → implementation order (ADR 0001 superseded by 0003,
  but the principle holds via the PRD-merge-then-design-PR
  sequencing in `/tdd-author` step 9). No new ADR needed; this
  TDD's history (PR #32 followed by PR #33's PRD landing) is a
  concrete instance of that principle being followed after the
  initial out-of-order authoring, not a counterexample to it.

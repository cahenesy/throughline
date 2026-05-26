# TDD 0007: Verification-as-observation across the pipeline

Status: implemented
PRD refs: FR-23, FR-24, FR-25, FR-26 (new); FR-5, FR-8, FR-10, FR-15, FR-22, NFR-4 (verification deltas)
PRD-rev: 962732c
ADR constraints: 0003, 0004

## Approach
Thread one concept — a **verification plan** (observable surface → observation
point(s) → expected observations) — through every phase so verification is governed
from the PRD forward, kept distinct from tests/typechecks, with the *mechanism*
delegated, not bundled. PRD requirements carry observable acceptance criteria
(FR-24); each TDD carries a verification plan (FR-23); the design-critique gate
blocks a missing/non-actionable plan (FR-10); `/implement` adds a fourth gate that
DRIVES the built artifact and confirms the plan's observations hold (FR-25), keeping
`verify.sh` as the separate, mechanical "CI's job" gate. throughline ships no
harness — the runtime gate delegates the *how* to the project +
`superpowers:verification-before-completion` / the `/verify` skill (FR-26).

## Components & interfaces
The verification-plan schema (authoritative; the same shape is referenced by
prd-author, tdd-author, design-reviewer, and the runtime gate):
- **Observable surface** — where the change manifests for a user (human or
  programmatic): CLI stdout/exit code, HTTP status/body, library return value or
  thrown error, log line, file/DB write, DOM/rendered output.
- **Observation point(s)** — the concrete scenario(s) that drive the changed code to
  where it executes: the exact command, request, function call + inputs, or UI action.
- **Expected observations (PASS)** — the specific values/invariants that must hold at
  the surface for the change to count as observed-correct.
- **No observable surface?** — declare `SKIP: <why>` (e.g. a pure internal refactor);
  never omit silently (NFR-4).

1. `skills/tdd-author/SKILL.md` (FR-23, FR-8) — add `## Verification plan` to the TDD
   template (placed after "Failure modes & edge cases", before "Requirement
   traceability"), an authoring step requiring it, and add a planless or
   "verify it works"-style plan to the no-placeholder failure list. The template in
   THIS skill is the one future runs emit, so the section propagates automatically.
2. `skills/prd-author/SKILL.md` (FR-24, FR-5) — Process: every NEW requirement states
   an observable acceptance criterion — phrased as an observation of the artifact's
   surface ("running X prints Y", "GET /z returns 200 with field f"), never "a test
   exists for X". Self-review: add a 5th bullet, "Missing acceptance criterion." Per
   the PRD's own open question, backfilling FR-1–FR-22 is out of scope here.
3. `agents/design-reviewer.md` (FR-10) — add a REQUIRED check, "Verification plan":
   each TDD must name a concrete observable surface, observation point(s), and
   expected observations; a missing or non-actionable plan, or a `SKIP` without a
   justification, is a BLOCK. Add "a missing or non-actionable verification plan" to
   the enumerated BLOCK-verdict conditions.
4. `/implement` runtime-verification gate (FR-25, FR-15, NFR-4):
   - `scripts/verify-runtime-prompt.md` (new) — a `claude -p` prompt, templated like
     `build-prompt.md`/`review-prompt.md` with `{{TDD}}` and `{{BASE}}` (here `{{BASE}}`
     scopes `git diff {{BASE}}..HEAD` purely so the verifier can see WHICH change to
     drive and focus its observation on it — it orients the verifier, it does not gate
     on the diff). It: reads the TDD's `## Verification plan`; drives the built artifact
     to each observation point
     using project-appropriate means, explicitly delegating the *mechanism* to
     `superpowers:verification-before-completion` / the `/verify` skill (NO bundled
     harness, FR-26); confirms each expected observation against the captured output;
     and ends with EXACTLY `VERIFY_RUNTIME: PASS|FAIL|BLOCKED|SKIP <reason>`. Ambiguity
     or no clear observation resolves to FAIL, never a false PASS (NFR-4).
   - `scripts/implement.sh` (modified):
     - `verify_runtime_one() {  # <tdd> <base-ref> <log>` — `sed`-fills the prompt and
       runs `claude -p --permission-mode auto` on `$MODEL` (the build model — the gate
       needs capability to drive the artifact; it is a FRESH process, so it is
       independent of the build's own self-report regardless of model), cwd = the build
       worktree (deps already installed by `install_deps`).
     - `verify_runtime_status() { grep -aoE 'VERIFY_RUNTIME: (PASS|FAIL.*|BLOCKED.*|SKIP.*)' "$1" 2>/dev/null | tail -1; }`
     - In `gate_one`, insert gate (c) BETWEEN `run_verify` (gate b) and `review_one`
       (gate d), behind `THROUGHLINE_REQUIRE_RUNTIME_VERIFY` (default 1, mirroring
       `THROUGHLINE_REQUIRE_TEST_FIRST`): run `verify_runtime_one`; classify
       `verify_runtime_status` — `PASS`/`SKIP` → proceed to review; `FAIL` →
       `echo "FAIL runtime-verify…"; return 1`; `BLOCKED` →
       `echo "BLOCKED runtime-verify (couldn't observe)…"; return 1`; no verdict line →
       treat as FAIL. A not-PASS/SKIP result leaves the TDD un-flipped.
     - Update the file-header comment "three independent gates" → four, and the
       gate-list (1 test-first, 2 verify.sh, 3 runtime-verify, 4 review).
5. Docs sync (in the same commits): `skills/implement/SKILL.md` — three → four gates,
   the runtime gate, the `SKIP`/`BLOCKED` distinction, and `THROUGHLINE_REQUIRE_RUNTIME_VERIFY`;
   `scripts/build-prompt.md` — note that a separate runtime-verification gate will
   drive the artifact, so the build must leave it runnable; the FR-26 boundary
   statement (mechanism delegated, no harness vendored) in the implement skill and the
   verify-runtime prompt.
6. Editorial back-pointers (one line each, **no `Status:` change → no rebuild**) in
   TDDs 0002/0003/0005/0006: "Verification aspects of FR-N now covered by TDD 0007."

## Data & state
- No persistent new state. The runtime gate's evidence is its `claude -p` transcript
  appended to the per-TDD log (`$LOGDIR/<slug>.log`); the verdict is parsed from it,
  exactly as build (`BATCH_RESULT:`) and review (`REVIEW_RESULT:`) already are.
- `scripts/verify.sh` is UNCHANGED — it remains the deterministic, mechanical CI gate
  (tests + typecheck + lint). The runtime gate is a separate `claude -p` process.

## Sequencing / implementation plan
Edit the three authoring/governance surfaces (tdd-author template + step; prd-author
criterion + self-review; design-reviewer check) → add `scripts/verify-runtime-prompt.md`
→ wire `verify_runtime_one`/`verify_runtime_status` into `gate_one` between verify.sh
and review, behind `THROUGHLINE_REQUIRE_RUNTIME_VERIFY` → update the implement skill,
build-prompt, and the header comment → add the four back-pointers. Dogfood: this TDD
itself carries the `## Verification plan` below.

## Failure modes & edge cases
- Artifact can't be driven at all (missing env/tooling) → `VERIFY_RUNTIME: BLOCKED` →
  not flipped, reported as BLOCKED (distinct from FAIL per NFR-4). It is NOT a design
  blocker (not appended to `BLOCKERS.md`) — only a build's own `BATCH_RESULT: BLOCKED`
  is.
- No observable surface (internal refactor) → the plan declares `SKIP` (or the
  verifier emits `VERIFY_RUNTIME: SKIP <why>`) → proceeds, recorded, never silent.
- Verifier is unsure / emits no verdict line → FAIL (ambiguity is never a false PASS).
- `THROUGHLINE_REQUIRE_RUNTIME_VERIFY=0` → the gate is skipped wholesale (documented
  escape hatch, e.g. a batch of pure refactors), exactly like the test-first toggle.
- Sequential halt semantics are unchanged: a not-PASS/SKIP runtime gate halts the run
  and marks downstream TDDs BLOCKED.
- throughline itself has no unit-test framework, so its OWN verification is
  artifact-appropriate shell observation (run the runner against a fixture, inspect
  the log) — see the plan below. `verify.sh` for plugin TDDs needs `VERIFY_ALLOW_EMPTY=1`
  or a shell-based `VERIFY_TEST_CMD`; that is a pre-existing condition, not introduced
  by this design.

## Verification plan
- **Observable surface:** (a) `scripts/implement.sh` runtime behavior — a
  `VERIFY_RUNTIME:` line in the per-TDD log and the `Status: implemented` flip
  happening only after PASS/SKIP; (b) `agents/design-reviewer.md`'s verdict on a
  planless TDD; (c) the presence of `## Verification plan` in the tdd-author template
  and the acceptance-criterion rule in prd-author.
- **Observation points:**
  1. In a scratch git repo with a trivial fixture TDD whose plan has a runnable
     observation, run `bash scripts/implement.sh <fixture> --combined`
     (`VERIFY_ALLOW_EMPTY=1` for verify.sh); `grep -n 'VERIFY_RUNTIME: PASS'` the
     per-TDD log and confirm it appears AFTER `verify: gate PASS` and BEFORE
     `REVIEW_RESULT:`.
  2. Re-run with `THROUGHLINE_REQUIRE_RUNTIME_VERIFY=0`; confirm the flip no longer
     requires a `VERIFY_RUNTIME:` line.
  3. Dispatch the `design-reviewer` agent against a copy of a TDD with its
     `## Verification plan` section deleted; observe `DESIGN_REVIEW: BLOCK`.
  4. `grep -n '## Verification plan' skills/tdd-author/SKILL.md` and
     `grep -n 'acceptance criterion' skills/prd-author/SKILL.md` each return a match.
- **Expected observations (PASS):** the gate ordering test-first → verify.sh →
  verify-runtime → review holds (the `VERIFY_RUNTIME:` line sits between the verify
  and review lines); the env toggle removes the requirement; the design-reviewer
  blocks a planless TDD; both skill texts contain the new content.
- Mechanism is the project's (plain shell + `grep` here) — delegated, not bundled
  (FR-26).

## Requirement traceability
- FR-23 → `## Verification plan` template section + authoring step + no-placeholder
  coverage in tdd-author.
- FR-24 → observable-acceptance-criterion rule + self-review bullet in prd-author
  (new requirements only; backfill deferred per the PRD open question).
- FR-25 → `verify_runtime_one`/`verify_runtime_status` gate (c) in `gate_one`; flip
  only on PASS/SKIP; FAIL/BLOCKED do not flip and are reported as such.
- FR-26 → `verify-runtime-prompt.md` delegates the mechanism to
  `superpowers:verification-before-completion` / `/verify`; no harness vendored;
  boundary notes in the implement skill + prompt.
- FR-5 (delta) → prd-author self-review gains "missing-acceptance-criterion".
- FR-8 (delta) → the TDD template gains the verification plan.
- FR-10 (delta) → design-reviewer BLOCKs a missing/non-actionable plan.
- FR-15 (delta) → three → four gates (runtime verify added; verify.sh reframed as the
  mechanical CI gate, not verification).
- FR-22 (delta) → the verification *mechanism* is added to the delegation set
  (`superpowers:verification-before-completion` / `/verify`) via the FR-26 boundary
  note + the back-pointer in TDD 0006; no harness is vendored.
- NFR-4 (delta) → the runtime gate keeps PASS/FAIL/BLOCKED/SKIP distinct;
  ambiguity → FAIL; SKIP is never silent. (The "progress estimates are labeled as
  estimates" clause of NFR-4 is covered by TDD 0008 / FR-30.)

## Dependencies considered
No new runtime/library dependency. The runtime gate reuses the existing
`claude -p` + prompt-template pattern (as build and review already do) rather than the
rejected alternative of a **bundled verification framework/harness** — that would
contradict FR-26 / ADR 0002–0003 (delegate the mechanism), add lock-in, and could not
generalize across CLI/HTTP/library/DOM artifacts. The verification *mechanism*
delegates to `superpowers:verification-before-completion` / the `/verify` skill, an
already-declared dependency surface. Rejected alternative **"fold runtime verification
into `verify.sh`"**: `verify.sh` is deterministic and model-free (tests + typecheck +
lint); driving an arbitrary artifact and judging observations is agentic — conflating
them would re-erase the CI-vs-verification separation FR-15/FR-25 exist to draw.

## PRD conflicts surfaced (and resolution)
None. FR-24's scope is bounded by the PRD's own open question (no backfill of
FR-1–FR-22), which the design honors. No `BLOCKERS.md` entries to resolve.

## Decisions to promote (ADR candidates)
ADR 0004 (promoted + accepted this round): "Verification is runtime observation at the
surface — governed, not bundled." A durable, cross-cutting decision shaping prd-author,
tdd-author, and `/implement`; it complements ADR 0003 (delegation) and supersedes
nothing.

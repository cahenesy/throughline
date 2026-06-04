# TDD 0032: STEP_COMMIT protocol robustness — integer step-id enforcement, malformed-sentinel fail-loud, self-correcting protocol BLOCK

Status: implemented
PRD refs: FR-51, FR-56, FR-42, FR-41, NFR-4
PRD-rev: bfc8ad6
ADR constraints: 0003, 0004, 0005, 0006, 0007

## Approach

A live `/implement` run (TDD 0021's build, 2026-06-02) deadlocked because the
per-step review protocol has a silent failure mode: the build emitted
`STEP_COMMIT: 5b <sha>` (copying TDD 0021's literal `5b.` sequencing label) and
the runner's sentinel parser — which accepts only integer step ids — extracted
nothing and **did nothing**. The build blocked waiting for `STEP_REVIEW:`, the
runner blocked waiting for the next event, the 600s inter-event watchdog killed
the build, and the kill was classified `transient` (FR-41), burning the FR-42
retry budget on a failure that retrying can never fix.

The protocol contract is already documented (build-prompt.md: "`<step-id>` is
the integer index (1, 2, 3, …) of the Sequencing item"), but nothing enforces
it at any layer. This TDD adds four cheap defense layers, each at the point
where the violation is cheapest to catch:

1. **Authoring (tdd-lint)** — a new FR-51 mechanical check rejects a
   `## Sequencing / implementation plan` whose top-level labels are not exactly
   `1..N` sequential. Catches the violation at design time, before merge.
2. **Build prompt (ordinal fallback)** — the prompt tells the build what to do
   when it encounters a TDD that slipped through with non-integer labels: use
   the item's 1-based ordinal position. Removes the ambiguity that made the
   build copy "5b" literally.
3. **Runner pre-flight (zero-token refusal)** — before spawning the build
   coprocess, the runner runs the same label check; a non-conforming TDD FAILs
   immediately with a clear report line and no tokens spent. Protects TDDs
   merged before this fix that the new lint never saw.
4. **Runtime (fail-loud + self-correction)** — a `STEP_COMMIT:` line that does
   not parse is no longer dropped silently: the runner logs a
   `THROUGHLINE_PROTOCOL_ERROR` diagnostic and replies
   `STEP_REVIEW: BLOCK protocol-error: …` telling the build to re-emit with the
   integer ordinal. Bounded at 2 correction replies per build; exhaustion kills
   the coprocess and routes to the **fatal** pathway (FR-41) — never `transient`,
   never `paused` (NFR-4: a deterministic failure must not masquerade as
   recoverable).

Layers 1–3 make layer 4 nearly unreachable; layer 4 makes the worst case an
honest, attributable FAIL instead of a silent deadlock.

This TDD follows the established gap-fix precedent (TDDs 0027, 0030, 0031):
a standalone TDD extending implemented designs (0013's lint, 0020/0025/0030's
coprocess loop) without superseding them — the prior bodies remain authoritative
for their mechanisms; this TDD owns only the new defensive behavior.

## Components & interfaces

### 1. `tl_lint_sequencing` — new check in `scripts/lib/tdd-lint.sh` (layer 1)

New function, added to `tl_lint_all`'s function list alongside
`tl_lint_structural` / `tl_lint_placeholders` / `tl_lint_traced`:

```bash
tl_lint_sequencing() {  # <tdd-path>
  # Extract top-level numbered labels from `## Sequencing / implementation plan`,
  # ignoring fenced code blocks and indented (nested) list items.
  # Emit a blocker finding unless labels are exactly 1, 2, 3, ..., N.
}
```

Rules (all `blocker` severity, code `sequencing.labels`):
- A top-level item is a line matching `^[0-9]+[a-zA-Z]*\.` at column 0 inside
  the section (section ends at the next `^## ` heading or EOF).
- Lines inside fenced code blocks (``` or ~~~ delimited) are ignored — same
  fence-skipping approach as `tl_lint_placeholders`.
- **Non-integer label** (`5b.`, `3a.`) → finding: `non-integer sequencing label
  '<label>' — the STEP_COMMIT protocol requires integer step ids (1..N)`.
- **Non-sequential labels** (gaps: 1,2,5; duplicates: 1,2,2,3; not starting at
  1) → finding: `sequencing labels must be exactly 1..N sequential (found:
  <list>)`.
- **No sequencing section, or a section with zero numbered items** → no
  finding. A prose-only plan is valid; such a build degrades gracefully to
  end-of-build review (existing behavior, unchanged by this TDD).

Exit code follows the existing `_tl_emit` convention: 2 on blocker, 0 clean.

### 2. Build-prompt ordinal fallback — `scripts/build-prompt.md` (layer 2)

In the step protocol block (the "Create a commit whose message starts with
`step(<step-id>):`" / "Emit … `STEP_COMMIT: <step-id> <sha>`" instructions),
add one rule:

> `<step-id>` MUST be a plain integer. If the TDD's Sequencing list labels an
> item with anything else (e.g. `5b.`, `3a.`), use the item's **1-based ordinal
> position** in the top-level list as `<step-id>` — e.g. a list labeled
> 1, 2, 3, 4, 5, 5b, 6 yields step-ids 1–7, with `5b` → 6 and the final item → 7.

### 3. `_sequencing_labels_ok` — runner pre-flight in `scripts/lib/gates.sh` (layer 3)

New helper, called by `_per_step_review_loop` **before the `coproc BUILD`
spawn** (anywhere between the prompt-render success check and the `coproc`
call):

```bash
_sequencing_labels_ok() {  # <tdd-path>  -> rc 0 ok | rc 1 violation (details on stdout)
  # Mirrors tl_lint_sequencing's extraction awk (the established convention:
  # gates.sh mirrors tdd-lint.sh logic with a cross-reference comment, as the
  # FR-67 structural check already does at gates.sh:868/887).
}
```

On violation, `_per_step_review_loop`:
- appends `THROUGHLINE_PROTOCOL_PREFLIGHT: non-integer sequencing labels in
  <tdd> (<details>); refusing to spawn the build (fatal)` to the build log,
- returns rc 1 **without spawning the coprocess**.

The existing gate plumbing then takes over: `_build_one_gated` propagates the
non-zero rc, `_classify_cause` finds no transient pattern in the log tail and
no signal exit code, and classifies **fatal** → the TDD FAILs with the report
pointing at the log. Zero tokens are spent. (The pre-flight diagnostic must not
contain any token matching `_recoverable_patterns` — verified by Verification
§4.)

### 4. Protocol-error branch — `_per_step_review_loop` read loop in `scripts/lib/gates.sh` (layer 4)

The existing sentinel case (gates.sh `case "$text" in *"STEP_COMMIT: "*)`)
gains an `else` arm. Current shape:

```bash
step_id="$(… grep -aoE 'STEP_COMMIT:[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+' …)"
sha="$(…same…)"
if [ -n "$step_id" ] && [ -n "$sha" ]; then
  … existing per-step review flow (unchanged) …
fi              # ← today: silent fall-through
```

New `else` arm — fires ONLY for a genuine malformed sentinel attempt, never for
template echoes or prose mentions:

```bash
else
  # A real attempt is a line-anchored sentinel with no template placeholder:
  attempt="$(printf '%s' "$text" | grep -a '^STEP_COMMIT:' | grep -av '<' | tail -1)"
  if [ -n "$attempt" ]; then
    _protocol_errors=$((_protocol_errors + 1))
    printf 'THROUGHLINE_PROTOCOL_ERROR: unparseable STEP_COMMIT sentinel (attempt %s/2): %.200s\n' \
      "$_protocol_errors" "$attempt" >> "$log"
    if [ "$_protocol_errors" -le 2 ]; then
      verdict='STEP_REVIEW: BLOCK protocol-error: STEP_COMMIT must be exactly "STEP_COMMIT: <integer-step-index> <full-commit-sha>". <integer-step-index> is the 1-based ordinal of the Sequencing item (a TDD label like "5b" maps to its ordinal position). Re-emit the sentinel for the SAME completed work in that exact format — do not redo the work.'
      printf '%s\n' "$verdict" >> "$log"
      _coproc_write "${build_in}" "$(_user_turn_json "$verdict")" || break
      interval_start=$(date +%s)   # same clock handling as the review-verdict path
    else
      printf 'THROUGHLINE_PROTOCOL_FATAL: build emitted %s unparseable STEP_COMMIT sentinels despite correction; killing build pid %s (protocol-error)\n' \
        "$_protocol_errors" "$bpid" >> "$log"
      kill "$bpid" 2>/dev/null || true
      _protocol_fatal=1
      break
    fi
  fi
  # No real attempt (template echo / prose) → ignore, exactly as today.
fi
```

Post-loop: when `_protocol_fatal=1`, return rc 1 directly. **Insertion point:
after the `_backstop_exceeded` block and before the
`[ "$read_rc" -gt 128 ] && return 143` line** — i.e. after `wait "$bpid"` has
collected the killed coprocess, before both paths that would surface 143 (the
SIGTERM from our own kill) and classify transient. The three kill flags
(`_active_exceeded`, `_backstop_exceeded`, `_protocol_fatal`) are mutually
exclusive by construction (each is set only in its own kill path), so any
ordering among the three checks is correct; last-before-`read_rc` is chosen as
the minimally invasive insertion. Returning 1 with a
`THROUGHLINE_PROTOCOL_FATAL` log line that contains no `_recoverable_patterns`
token makes `_classify_cause` route to **fatal** → FAIL pathway (FR-41),
downstream TDDs marked BLOCKED per FR-16.

Counter scope: `_protocol_errors` and `_protocol_fatal` are loop-local shell
variables (initialized 0 beside the existing `build_active_seconds` locals).
Per-build-attempt by construction — a pause/resume spawns a fresh coprocess and
a fresh counter, which is correct: the budget is "2 corrections per build
attempt", not per TDD lifetime. No fragment-schema change.

### 5. Protocol note — `skills/implement/SKILL.md`

One sentence added to the per-step review paragraph: a malformed `STEP_COMMIT:`
gets a bounded protocol-correction `STEP_REVIEW: BLOCK` reply (2 per build);
exhaustion FAILs the TDD via the fatal pathway — it is never classified
transient.

## Data & state

- **No run-state schema change.** The protocol counter is loop-local (§4).
- **New log markers** (build log, grep-able, used by tests and triage):
  - `THROUGHLINE_PROTOCOL_PREFLIGHT:` — pre-flight refusal (layer 3)
  - `THROUGHLINE_PROTOCOL_ERROR:` — one malformed-sentinel correction (layer 4)
  - `THROUGHLINE_PROTOCOL_FATAL:` — correction budget exhausted (layer 4)
- **New lint finding code**: `sequencing.labels` (blocker), emitted by
  `tl_lint_sequencing` via the existing `_tl_emit` format.

## Sequencing / implementation plan

1. **`tl_lint_sequencing` in `scripts/lib/tdd-lint.sh`**: section/fence-aware
   label extraction + the exactly-1..N rule; wire into `tl_lint_all`. Failing
   tests first: accept 1..N; reject `5b.`; reject gaps/duplicates/not-starting-
   at-1; ignore fenced labels; no finding when the section is absent or has
   zero items.
2. **Build-prompt + SKILL.md text (layers 2 + 5)**: the ordinal fallback rule in
   `scripts/build-prompt.md`; the protocol-correction sentence in
   `skills/implement/SKILL.md`. Failing tests first: grep both files for the
   new rule text.
3. **`_sequencing_labels_ok` pre-flight in `scripts/lib/gates.sh`**: the
   mirrored check + the refuse-before-spawn wiring in `_per_step_review_loop`.
   Failing tests first: a stub TDD with `5b.` labels → no coprocess spawn, log
   carries `THROUGHLINE_PROTOCOL_PREFLIGHT`, gate rc non-zero, classified fatal.
4. **Protocol-error branch in `scripts/lib/gates.sh`**: the `else` arm,
   correction reply, exhaustion kill, post-loop fatal routing. Failing tests
   first: stub coprocess emitting malformed sentinels (§Verification 4–8).
5. **Aggregator wiring**: invoke `tests/step-commit-protocol.test.sh` from
   `tests/implement-gate.test.sh`, following the existing sub-test invocation
   pattern; full-suite run.

## Failure modes & edge cases

- **Template echo false positive.** The build-prompt template text
  `STEP_COMMIT: <step-id> <sha>` appears verbatim in early stream events (the
  build echoing its instructions). The `grep -av '<'` guard excludes any line
  containing `<`, and line-anchoring (`^STEP_COMMIT:`) excludes prose mentions.
  Verification §5 pins this.
- **Build emits a valid sentinel and a malformed line in the same event.** The
  positive extraction wins (the `if` arm runs, the `else` never executes) —
  unchanged from today's behavior for the valid sentinel.
- **Coprocess dies while the correction reply is being written.**
  `_coproc_write` returns non-zero → `break` → the existing post-loop
  classification handles the dead coprocess exactly as it does for
  review-verdict writes (TDD 0030 §1). No new handling needed.
- **Both `_protocol_fatal` and `read_rc > 128`.** Cannot co-occur: the
  protocol-fatal branch `break`s before any further blocking read, and the
  fatal check runs before the `read_rc` check post-loop. Ordering is pinned in
  §4 (fatal check first).
- **TDD with a prose-only (un-numbered) sequencing plan.** Lint: no finding.
  Pre-flight: passes (zero items = conforming). Runtime: such a build never
  emits `STEP_COMMIT:`, degrading to end-of-build review — existing, unchanged.
- **TDD authored before this fix, already merged, with non-integer labels.**
  This is exactly TDD 0021's situation. The pre-flight (layer 3) catches it at
  zero cost; the report names the offending labels so the human fixes the TDD
  (a one-line renumber commit, as was done manually for 0021).
- **`BATCH_RESULT:` malformations are out of scope.** That sentinel has its own
  parsing (`build_status`) and its own missing-sentinel fallback (the
  resume-completion synthesis in `_build_one_gated`); conflating the two
  protocols' error handling would couple unrelated mechanisms. Recorded as a
  known non-goal.
- **Lint check vs. ## Verification plan numbered lists.** The check is scoped
  to the `## Sequencing / implementation plan` section only; numbered lists in
  any other section (verification plans commonly use `8b.`-style labels) are
  not examined.

## Verification plan

Observable surfaces: `tdd-lint.sh` stdout + exit code; the build log written by
`_per_step_review_loop`; the gate return code as classified by
`_classify_cause`; the text of `build-prompt.md` / `SKILL.md`.

Observation points (all mechanical, driven by `tests/step-commit-protocol.test.sh`
with stub TDD fixtures and a stub coprocess command, following the established
fixture pattern in `tests/continuous-in-build-review.test.sh`):

1. **Lint accepts 1..N.** Fixture TDD with labels 1–5 → `tl_lint_sequencing`
   exits 0, no output.
2. **Lint rejects non-integer / non-sequential.** Fixtures: labels containing
   `5b.`; labels 1,2,5; labels 1,2,2; labels starting at 2 → each exits 2 with
   one `blocker sequencing.labels` finding naming the violation.
3. **Lint ignores fences and other sections.** Fixture with `5b.` inside a
   fenced block in the sequencing section, and `8b.` in `## Verification plan`
   → exits 0.
4. **Pre-flight refuses before spawn.** Drive `_per_step_review_loop` against a
   fixture TDD with a `5b.` label and a stub coprocess command that would write
   a marker file if executed → marker file absent, log contains
   `THROUGHLINE_PROTOCOL_PREFLIGHT`, return code non-zero, and
   `_classify_cause <log> <rc>` echoes `fatal`.
5. **No false positive on template echo.** Stub coprocess emits an event whose
   text contains `STEP_COMMIT: <step-id> <sha>` (template form) and a prose
   mention `the STEP_COMMIT: protocol`, then a valid `STEP_COMMIT: 1 <sha>` →
   log contains zero `THROUGHLINE_PROTOCOL_ERROR` lines and exactly one
   per-step review invocation.
6. **Malformed sentinel → correction reply.** Stub coprocess emits
   `STEP_COMMIT: 5b <sha>` then reads its stdin → the runner's reply (captured
   by the stub) is `STEP_REVIEW: BLOCK protocol-error: …`, and the log contains
   `THROUGHLINE_PROTOCOL_ERROR: … (attempt 1/2)`.
7. **Self-correction completes.** Stub emits `STEP_COMMIT: 5b <sha>`, receives
   the BLOCK, then emits `STEP_COMMIT: 6 <sha>` → the per-step review runs
   (stubbed to PASS), the cleared-step record gains step 6, and the loop
   proceeds normally.
8. **Exhaustion → fatal, never transient/paused.** Stub emits three malformed
   sentinels (re-emitting after each correction) → log contains
   `THROUGHLINE_PROTOCOL_FATAL`, the coprocess is killed, the gate returns
   non-zero, `_classify_cause` echoes `fatal` (NOT `transient`), and no
   paused-state fragment write occurs.
9. **Prompt text present.** `build-prompt.md` greps for the ordinal-fallback
   rule (the literal "1-based ordinal"); `skills/implement/SKILL.md` greps for
   the protocol-correction sentence.

## Requirement traceability

| Requirement | Design element |
|---|---|
| FR-51 (mechanical pre-pass detects structural gaps before the LLM reviewer) | §1 `tl_lint_sequencing` — a new structural check in the same pre-pass, same `_tl_emit` blocker format, wired into `tl_lint_all` |
| FR-56 (review runs continuously, per step) | §4 — a malformed sentinel no longer silently skips the per-step review; the correction reply restores the handshake so review runs for every completed step |
| FR-42 (bounded in-gate retry is for transient errors) | §3 + §4 — protocol violations never enter the transient retry path: pre-flight and exhaustion both route to fatal, so FR-42's budget is spent only on genuinely transient causes |
| FR-41 (recoverable vs fatal classification) | §3 + §4 — `THROUGHLINE_PROTOCOL_PREFLIGHT` / `THROUGHLINE_PROTOCOL_FATAL` log lines carry no recoverable-pattern token and the return codes avoid the signal range, so `_classify_cause` routes them to `fatal` deterministically |
| NFR-4 (verdict honesty; ambiguity never resolves to a false positive) | §4 — the unparseable sentinel is surfaced as an explicit logged error and an explicit BLOCK reply, never silently ignored; the terminal state is an honest FAIL, never a resumable pause that cannot succeed |

Gaps: none identified. FR-57/FR-59 (scoped reads, cross-step learning) are
untouched — the correction reply re-enters the existing review flow unchanged.

## Dependencies considered

No new external dependencies (libraries, services, tools). Internal design
alternatives evaluated:

- **Sourcing `tdd-lint.sh` from `gates.sh`** (for the pre-flight check) vs.
  **mirroring the awk logic** — mirroring chosen, consistent with the existing
  FR-67 convention (gates.sh:868/887 already mirror tdd-lint parsers with
  cross-reference comments). Sourcing was rejected because gates.sh is loaded
  in contexts (tests, the runner) where tdd-lint.sh's entry-point dispatch and
  its own sourcing assumptions add fragility for a ~15-line awk block.
- **Supporting non-integer step ids end-to-end** (parser, fragment JSON schema,
  `_cleared_steps_csv`, resume signal) vs. **enforcing integers** — enforcement
  chosen. Step ids are JSON numbers in `cleared_step_log` and a CSV resume
  signal; widening them to strings touches three implemented designs
  (0020/0024/0030) for zero user value, since the ordinal always exists.

## PRD conflicts surfaced (and resolution)

- **FR-51's check enumeration is treated as exemplary, not exhaustive.** FR-51
  lists "missing required sections, missing frontmatter, placeholder strings,
  untraced FR/NFR" as the pre-pass's findings. The sequencing-label check is a
  new structural-gap kind not in that list. Resolution: the FR's intent is
  "mechanical structural gaps are caught before LLM review"; this check is
  squarely that. No PRD edit required.
- **FR-63's halt taxonomy needs no extension.** A build that cannot speak the
  protocol is routed to the existing FAIL pathway (FR-41 fatal), not to a new
  halt cause — the taxonomy's closed set (design-gap / scope / budget /
  external) is preserved.

## Decisions to promote (ADR candidates)

None recommended. The "sentinel protocols fail loudly with bounded
self-correction" principle is a candidate, but it currently has exactly one
instance (STEP_COMMIT); promoting a single-instance pattern to an ADR is
premature. Revisit if a second sentinel protocol (e.g. BATCH_RESULT) adopts the
same shape.

## Touched files

- `scripts/lib/tdd-lint.sh` — `tl_lint_sequencing` + `tl_lint_all` wiring (§1)
- `scripts/build-prompt.md` — ordinal fallback rule (§2)
- `scripts/lib/gates.sh` — `_sequencing_labels_ok` pre-flight + protocol-error
  branch + post-loop fatal routing (§3, §4)
- `skills/implement/SKILL.md` — protocol-correction sentence (§5)
- `tests/step-commit-protocol.test.sh` — new eval (§Verification 1–9)
- `tests/implement-gate.test.sh` — aggregator wiring (§5)

## Expected diff size

- `scripts/lib/tdd-lint.sh` — 55 lines
- `scripts/build-prompt.md` — 8 lines
- `scripts/lib/gates.sh` — 60 lines
- `skills/implement/SKILL.md` — 5 lines
- `tests/step-commit-protocol.test.sh` — 280 lines
- `tests/implement-gate.test.sh` — 14 lines

Total expected diff: 422 lines across 6 files.

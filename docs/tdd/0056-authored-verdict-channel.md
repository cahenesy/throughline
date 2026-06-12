# TDD 0056: Authored-verdict channel — injection-proof build-verdict parsing
Status: draft
PRD refs: NFR-4 (verdict honesty); FR-15 (four-gate flip authority); FR-56 (continuous in-build review / sentinel protocol); FR-69 (self-compliance with Theme A)
PRD-rev: 0aa1e28
ADR constraints: 0005, 0006

## Approach
Resolves the BLOCKERS.md sentinel-injection entry (run 20260611-181309): a
tool_result mirroring `ci-checks.sh` — whose comment contains the literal
`BATCH_RESULT: OK` — both killed the build coproc (the 0053-A16 raw-event arm)
and satisfied `build_status()`'s whole-log substring grep, flipping a
1-of-5-steps build `implemented`. PR #152 hotfixed the kill vector: the
stdin-close lifecycle now fires only on an **authored** verdict — the last
non-empty line of the event's extracted assistant text starts with
`BATCH_RESULT: ` (gates.sh:1306).

Post-hotfix, `build_status()` is safe only by an **implicit four-link invariant
chain**: (1) authored-only stdin close → (2) the coproc can exit rc=0 only
after a verdict was observed → (3) the genuine verdict is therefore the LAST
`BATCH_RESULT:` match in the log → (4) `tail -1` lands on it. No single
mechanism enforces this; the 0053-A16 change is precedent that one refactor to
one link silently re-opens the hole. This TDD replaces the coincidence with one
explicit authority:

- **The loop is the sole verdict observer.** At the moment the authored-verdict
  rule fires (the existing gates.sh:1306 site — already the single observation
  point), the runner ECHOES the observed verdict as a canonical column-0
  marker line: `THROUGHLINE_AUTHORED_VERDICT: <verbatim final line>`.
- **Consumers read only line-anchored markers.** `build_status()` and the
  diff-vs-narrative facts extractor stop substring-grepping the log; they read
  `^THROUGHLINE_AUTHORED_VERDICT: BATCH_RESULT: ` first, falling back to a
  line-anchored `^BATCH_RESULT: ` (bare-line degraded/legacy logs only). A
  mirrored stream-json event is a single line starting with `{` (embedded
  newlines stay JSON-escaped), so NO tool_result, prose, or model output can
  ever produce a column-0 marker — the channel is structurally unforgeable.
- **The synth-OK fallback is removed** (gates.sh:1404-1423). It fabricates a
  `BATCH_RESULT: OK` the model never authored — the least NFR-4-compatible
  lines in the file — and is unreachable post-hotfix: rc=0 requires stdin EOF,
  which the loop now grants only after an authored verdict. The build-prompt's
  RESUME-COMPLETION CASE (re-emit the sentinel) is the belt; a prose-only
  resume completion now ends at the inter-event watchdog as an honest,
  resumable transient.
- **The build prompt pins sentinel placement** (the A16 successor): the
  terminal sentinel MUST be the final line of a plain-text assistant message,
  never inside a tool call, and no non-final message may END with a sentinel
  line. A violation ends at the watchdog (transient), never a false complete.

Surfaces verified NOT exposed (honest no-ops, evidence recorded): the review
and runtime-verify gates spawn `claude -p` in plain-text output (no
`--output-format stream-json` in their arg arrays; only the build coproc at
gates.sh:1044 streams), so their logs never mirror tool_results —
`review_status()` / `verify_runtime_status()` keep their current parse.
`resume.sh` derives resume baselines from the state fragment and branch
commits, not log greps — untouched.

## Components & interfaces
- **Marker write (gates.sh, the `*)` lifecycle arm at ~1296-1320).** Inside the
  existing `case "$_tail_line" in "BATCH_RESULT: "*)` arm, guarded by the same
  `_build_stdin_closed -eq 0` check (so it writes exactly once), BEFORE the fd
  closes:
  `printf 'THROUGHLINE_AUTHORED_VERDICT: %s\n' "$_tail_line" >> "$log"`.
  The marker carries the verdict line verbatim; no normalization at write time.
- **`build_status()` (gates.sh:585).** Pinned replacement (L-003: the exact
  extraction spec, not a paraphrase):
  ```
  build_status() {
    local m
    m="$(grep -a '^THROUGHLINE_AUTHORED_VERDICT: BATCH_RESULT: ' "$1" 2>/dev/null | tail -1)"
    [ -n "$m" ] && { printf '%s\n' "${m#THROUGHLINE_AUTHORED_VERDICT: }"; return 0; }
    grep -aE '^BATCH_RESULT: (OK|FAIL.*|BLOCKED.*)' "$1" 2>/dev/null | tail -1
  }
  ```
  Return shape is unchanged (a `BATCH_RESULT: …` line or empty), so the
  callers' `case … in *OK*)` dispatch is untouched. The fallback is
  line-anchored — it matches bare-line sentinels (the degraded non-JSON path,
  pre-0056 stub logs) and can never match a sentinel inside a mirrored JSON
  event line.
- **Diff-vs-narrative facts extractor (gates.sh:375 + the region locator at
  ~390).** `br` extraction becomes marker-first with the same anchored
  fallback; the narrative-region locator (`grep -an 'BATCH_RESULT:'`) anchors
  to `'^THROUGHLINE_AUTHORED_VERDICT: \|^BATCH_RESULT: '`. Behavior when no
  marker exists (narrative-missing → SKIP) is unchanged.
- **synth-OK removal (gates.sh:1404-1423).** Delete the fallback block in
  `_build_one_gated`; `[ -z "$bs" ]` now falls through to `return 1` (build
  did not return OK), exactly as an explicit no-verdict case should (NFR-4).
  The explanatory comment is replaced by two lines noting the removal and why
  (unreachable post-#152; fabricated verdicts violate NFR-4 / ADR 0006).
- **build-prompt.md placement rules.** In the Close section, immediately
  alongside the existing "End your final message with exactly
  `BATCH_RESULT: OK`" instruction (~line 234 — the primary sentinel
  instruction; the RESUME-COMPLETION CASE at lines 17-35 already mirrors it):
  the terminal sentinel MUST be emitted as the FINAL line of a plain-text
  assistant message — never inside a tool call (Bash echo, Write content,
  commit message), and no other message may end with a line beginning
  `BATCH_RESULT: ` or `STEP_COMMIT: ` (quote such lines mid-message or inside
  fences with trailing prose instead). States the consequence honestly: a
  misplaced sentinel is not observed, and the build ends at the inactivity
  watchdog as a transient.
- **Eval (tests/build-coprocess-lifecycle.test.sh).** New verification points
  on the existing stub harness (§ Verification plan); the suite is already
  registered in the aggregator (BCL term), so no aggregator change.

## Data & state
No schema change, no new files. One new log-line format
(`THROUGHLINE_AUTHORED_VERDICT: `) in the per-TDD gate log, joining the
existing runner-authored column-0 family (`THROUGHLINE_COPROC_DEAD`,
`THROUGHLINE_BUILD_HANG`, `STEP_REVIEW:`). Cross-version resume is safe: a
run whose build gate COMPLETED pre-0056 is resumed via `gates_completed`
(FR-40) without re-parsing the old log; an IN-FLIGHT build gate re-runs from
scratch on resume, producing a fresh log with a marker.

## Sequencing / implementation plan
1. Marker write at the observation point (gates.sh lifecycle arm), with the
   eval case asserting the marker line appears exactly once, at column 0,
   carrying the verbatim verdict.
2. `build_status()` → marker-first anchored read with the pinned fallback;
   eval cases: marker preferred over earlier injected JSON-carried junk; a
   genuine `FAIL` verdict survives a log that ALSO contains injected
   `BATCH_RESULT: OK` junk (the ordering-independence point the implicit
   chain could not guarantee); bare-line fallback still parses a stub/degraded
   log with no marker.
3. Diff-vs-narrative `br` extraction + region locator → marker-first anchored;
   eval case: injected JSON-carried sentinel no longer selected as the
   build-verdict-line fact.
4. Remove the synth-OK fallback; eval case: a clean-exit-no-verdict log (built
   directly against `_build_one_gated` with a stub) yields return 1 and NO
   `synthesized` line in the log.
5. build-prompt.md placement rules; eval greps anchor the new instruction text
   (specific to the new wording, no vacuous match on pre-existing protocol
   text — L-001/L-002 hygiene: every inverted check distinguishes grep exit 1
   from exit ≥2).

## Failure modes & edge cases
**Real risks.**
- *Marker write fails (disk/permissions) while the build is good* →
  `build_status` finds no marker and no bare-line sentinel → build gate
  returns FAIL — a false NEGATIVE, not a false PASS. Acceptable direction
  (NFR-4 prefers it), low likelihood: the marker write uses the same `>>
  "$log"` channel as every other runner write; if that channel is broken the
  run is already failing loudly.
- *Pre-0056 logs re-read by 0056 consumers* (operator re-runs tooling against
  an old logdir): no marker → anchored fallback → bare-line logs parse; JSON-
  carried-only logs return empty → treated as no-verdict. Honest, and no live
  code path re-parses completed old logs (see Data & state).

**Overblown risks.**
- *Performance* — one printf per build and three grep patterns; negligible.
- *Marker collision* — requires a column-0 line in the gate log not written by
  the runner; the mirror writes single-line JSON events and coproc stderr is
  diverted to the sibling `.build.err` file. The `THROUGHLINE_` namespace
  covers the accidental case.

**Unspoken risks (elephants).**
- *The authored-verdict rule itself is now the single discriminator.* A future
  model whose completion style never places the sentinel as a final text line
  would have every build end at the watchdog — builds become un-completable
  (loud, transient, human-visible) rather than falsely complete. The
  placement rule moves into the prompt precisely to make compliance an
  instructed behavior, not a stylistic accident; all ~55 prior builds already
  conform.
- *A build agent ends a NON-final message with a fenced example whose last
  line is a sentinel* (plausible in THIS repo's self-builds authoring eval
  code): the loop closes stdin early → watchdog → transient. The prompt's
  "no non-final message may end with a sentinel line" rule exists for exactly
  this; the consequence is a recoverable pause, never a false complete.

## Verification plan
- **Observable surface:** the per-TDD gate log content (marker line), the
  return value/stdout of `build_status()` and `_diff_vs_narrative_facts`'s
  `build-verdict-line:` fact, `_build_one_gated`'s return code, and the eval
  suite's pass/fail counts on stdout.
- **Observation points (mechanical — the existing stub-claude harness in
  `tests/build-coprocess-lifecycle.test.sh`, run as
  `bash tests/build-coprocess-lifecycle.test.sh`):**
  1. (VP9) Genuine completion stub → log contains exactly one
     `^THROUGHLINE_AUTHORED_VERDICT: BATCH_RESULT: OK` line; `build_status`
     echoes `BATCH_RESULT: OK`.
  2. (VP10) Stub emitting injected tool_result junk (`BATCH_RESULT: OK` inside a
     JSON event) THEN a genuine authored `BATCH_RESULT: FAIL …` →
     `build_status` returns the FAIL line (marker wins; ordering-independent).
  3. (VP11) Stub/degraded log with a bare-line sentinel and no marker →
     `build_status` fallback parses it (compat preserved).
  4. (VP12) Injection-only log (the existing VP6 shape) → `build_status` returns empty;
     `_build_one_gated` returns 1; the log contains NO `synthesized` line
     (synth-OK gone).
  5. (VP13) `_diff_vs_narrative_facts` on a log with injected junk + marker → the
     `build-verdict-line:` fact equals the marker's verdict, not the junk.
  6. (VP14) Prompt-rule anchors: `grep -F` for the new placement-rule sentences in
     `scripts/build-prompt.md`, failing distinctly on file-missing (exit ≥2)
     vs text-absent (exit 1).
- **Expected observations (PASS):** each named value above; the pre-existing
  VP1-VP8 cases stay green (regression guard for the #152 behavior this TDD
  builds on); suite reports 0 failed; aggregator stays green via the existing
  BCL registration.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement traceability | Every PRD ref (NFR-4, FR-15, FR-56, FR-69) maps to a named design element; the blocker entry is explicitly resolved | All refs traced, blocker referenced | Any untraced ref or unresolved blocker linkage |
| Single-authority mechanism | Marker written at exactly ONE site (the loop's observation point); zero substring sentinel greps remain on the build log; consumers grep `^`-anchored only | One writer; a documented anchored fallback path | Two writers, or any surviving substring grep |
| Extraction-spec pinning (L-003) | The marker format and the authored-verdict rule are specified verbatim (exact grep/case patterns) so the build cannot drift from the design | Rule described precisely in prose | "Parse the verdict appropriately"-grade vagueness |
| Honest no-op rationale | Not-exposed surfaces (review/verify status fns, resume.sh) documented with the evidence they are out of scope | Listed as out of scope with brief reason | Silently omitted |
| Verification-plan actionability | Injection, prose, control, marker-preference, synth-OK-removal, and stub-compat cases each name the exact observable + expected value | All major cases drivable mechanically | "Tests pass" placeholders |
| Scope-bound adherence | Within bounds with calibrated (×1.4–1.6) per-file estimates and declared exceptions | Within bounds | Over a bound with no exception |

## Requirement traceability
| Requirement | Design element |
|---|---|
| NFR-4 (verdict honesty) | The gate verdict is the model-authored sentinel, observed once and echoed to an unforgeable channel; synth-OK (a runner-fabricated verdict) removed; no-verdict resolves to FAIL/transient, never PASS |
| FR-15 (four-gate flip authority) | `build_status()` — the build gate's verdict input to the flip — reads only the authored channel (marker-first, anchored fallback) |
| FR-56 (sentinel protocol) | The authored-verdict observation rule and marker format pinned verbatim (Components); prompt-side placement rules complete the protocol's contract |
| FR-69 (self-compliance Theme A) | The runner's own verdict parsing is hardened against content its own builds legitimately produce (sentinel-bearing files in this repo); BLOCKERS.md 0054 entry resolved by this design |
No gaps. ADR 0006 (artifacts-grounded verdicts) is the governing constraint:
the marker is the runner's durable record of the observed artifact; ADR 0005's
gate-architecture scope is respected (no new gate, no sandboxing — detection
stays prompt + downstream check).

## Dependencies considered
No new dependencies — grep/sed/printf and the existing jq-based
`_extract_event_text` already in-tree. Rejected alternative for the mechanism:
per-consumer stream-json re-extraction (each of `build_status`, the narrative
extractor, and any future consumer parsing assistant events itself) — rejected
because N independent parsers is the exact drift shape of learning L-003
(sentinel extractors diverging from the spec and each other); one writer +
anchored readers is strictly simpler and cheaper.

## PRD conflicts surfaced (and resolution)
None. The BLOCKERS.md entry **0054-runner-observability-hardening (2026-06-11,
sentinel injection)** is resolved by this TDD (checked off in the same design
PR): the kill vector was hotfixed in PR #152; this design closes the remaining
implicit-invariant fragility (`build_status` substring grep, narrative-facts
extraction), removes the fabricated-verdict fallback, and pins the prompt-side
placement contract.

## Decisions to promote (ADR candidates)
Considered and declined (bar kept high): "verdict sentinels are authenticated
as authored final-line text + runner-echoed canonical markers" is a durable
mechanism decision, but it currently governs a single channel (the build
coproc). If a second verdict channel ever adopts the marker pattern
(e.g. review/verify logs switching to stream-json), promote it then.

## Touched files
- `scripts/lib/gates.sh` — marker write at the lifecycle arm; `build_status()` anchored rewrite; narrative-facts `br`/locator anchoring; synth-OK removal
- `scripts/build-prompt.md` — sentinel placement rules (final-line plain text; never in tool calls; no non-final message ends with a sentinel line)
- `tests/build-coprocess-lifecycle.test.sh` — verification points VP9-VP14 (marker, preference/ordering, fallback compat, synth-OK removal, narrative fact, prompt anchors)
- `.claude-plugin/plugin.json` — version bump (build-applied)

## Expected diff size
- scripts/lib/gates.sh — 70 lines
- scripts/build-prompt.md — 15 lines
- tests/build-coprocess-lifecycle.test.sh — 190 lines
- .claude-plugin/plugin.json — 2 lines
Total expected diff: 277 lines across 4 files.

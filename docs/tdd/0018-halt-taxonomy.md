# TDD 0018: Halt taxonomy — closed human-needed cause enum, run-state schema extension, one-screen halt context

Status: implemented
PRD refs: FR-63, FR-64
PRD-rev: a961955
ADR constraints: 0003, 0004, 0005, 0007
Supersedes: 0011 (halt-taxonomy aspect only; the recoverable-classification + resume + branch-divergence aspects of 0011 carry forward unchanged)

## Approach

FR-63 asks for a single closed enum of human-needed halt causes spanning every
way an `/implement` run can come to require human attention. TDD 0011 already
established a closed enum of recoverable `paused_cause` values plus
resume-blocked sub-values; this TDD extends that enum's *scope* to cover the
new design-action-required causes Theme C introduces (rework-budget-exhausted,
structural-finding, design-escalation) and the long-standing external-blocker
cause (FR-17). The runtime state field stays as the existing
`running | done | failed | blocked | skipped | paused` vocabulary established
by TDDs 0008 + 0011; the new field — `halt_cause` — unifies the cause
labelling across the `paused` and `blocked` terminal states.

`paused_cause` (from TDD 0011) is kept as a write-time alias for one release
cycle so existing readers (notably the `/implement-status` renderer) do not
break. New writers populate BOTH `paused_cause` (when `status==paused`) and
`halt_cause` (always when a halt event has occurred); the next TDD that touches
state-schema versioning can drop the dual-write.

FR-64's one-screen halt context is a render-layer change to `scripts/status.sh`
(post-TDD-0015 baseline, where state I/O lives in `scripts/lib/state.sh`) and
`skills/implement-status/SKILL.md`. The renderer reads the new `halt_cause`,
the triggering finding reference, and the available next-action options, and
fits them inside 24 lines × 80 columns. The choice of next-action options is
deterministic per cause label (it does not require a model call): each cause
in the closed enum maps to a fixed set of valid next actions.

This TDD does NOT itself wire any rework loop or any new BLOCKERS.md entry
emission — TDD 0019 does that. This TDD owns the vocabulary, the schema, and
the renderer; TDD 0019 owns the writers that produce the new cause values.

## Components & interfaces

### 1. Unified `halt_cause` enum

The closed set of values:

| Value | Status produced | Source |
|---|---|---|
| `ratelimit` | `paused` | TDD 0011 (carried forward) |
| `usage-limit` | `paused` | TDD 0011 (carried forward) |
| `transient` | `paused` | TDD 0011 (carried forward) |
| `resume-blocked-build-state-missing` | `paused` | TDD 0011 (carried forward) |
| `resume-blocked-branch-missing` | `paused` | TDD 0011 (carried forward) |
| `resume-blocked-branch-divergence` | `paused` | TDD 0011 (carried forward) |
| `rework-budget-exhausted` | `blocked` | NEW (TDD 0019 writes; FR-65) |
| `rework-scope-exceeded` | `blocked` | NEW (TDD 0019 writes; FR-66) |
| `structural-finding` | `blocked` | NEW (TDD 0019 writes; FR-67) |
| `design-escalation` | `blocked` | NEW (reserved for future; reviewer-explicit "this needs design reconsideration outside any FR-67 criterion") |
| `external-blocker` | `blocked` | EXISTING FR-17 (formally added to the enum here) |

No other values are legal. The enum is closed at the writer level (every
emitter calls one of the documented setter functions); readers that
encounter an unknown value emit a warning and render the raw string.

### 2. Per-TDD fragment schema extension (FR-27 / FR-44 extension)

The TDD fragment shape (defined by TDD 0008 + extended by TDD 0011) gains:

| Field | Type | Meaning |
|---|---|---|
| `halt_cause` | `string \| null` | One of the enum above when `status` is a halt state (`paused`, `blocked`, `failed`); `null` for active or `done` TDDs. |
| `halt_triggering_finding_ref` | `string \| null` | When `halt_cause` is finding-driven (`structural-finding`, `rework-budget-exhausted`, `rework-scope-exceeded`), a stable reference to the review finding that triggered the halt: `<review-pass-id>:<finding-index>`. `null` for non-finding causes. |
| `halt_next_actions` | `string[]` | Deterministic list of available next-action labels, computed from `halt_cause`. See §3 below. |
| `halt_cause_detail` | `string \| null` | Optional free-form sub-classification of the halt cause for triage, when the enum value alone is too coarse. Examples: `build-overall-timeout` (TDD 0020 watchdog), `build-inter-event-timeout` (TDD 0020 read-t 600). `null` when the enum value is sufficient. Renderers display it under the cause label when present. |

`paused_cause` continues to be written when `status==paused` for backward
compatibility with the TDD 0008/0011 renderer; its value matches
`halt_cause` exactly. Readers should prefer `halt_cause`; a future TDD can
drop the dual-write once all readers are migrated.

### 3. Cause → next-actions mapping (deterministic, no model call)

| Cause | Next-action labels |
|---|---|
| `ratelimit`, `usage-limit`, `transient` | `["resume now (retries the gate)", "wait and resume later"]` |
| `resume-blocked-build-state-missing` | `["abandon paused run", "manual investigation: docs/tdd/.implement-logs/<runid>/"]` |
| `resume-blocked-branch-missing` | `["abandon paused run", "restore branch and resume"]` |
| `resume-blocked-branch-divergence` | `["abandon paused run", "rebase build branch and resume"]` |
| `rework-budget-exhausted` | `["revise TDD via /tdd-author", "fresh /implement after revision"]` |
| `rework-scope-exceeded` | `["resume (retries with stricter scope)", "revise TDD bounds via /tdd-author"]` |
| `structural-finding` | `["revise TDD via /tdd-author", "see docs/tdd/BLOCKERS.md"]` |
| `design-escalation` | `["revise TDD via /tdd-author", "/adr-new if a constraint is being challenged"]` |
| `external-blocker` | `["resolve external dependency", "see docs/tdd/BLOCKERS.md"]` |

Stored verbatim in `halt_next_actions` at halt-event-write time; the
renderer reads them directly.

### 4. Renderer changes — `scripts/status.sh` (post-TDD-0015)

The renderer's "halted run" branch (the code path that fires when the most
recent run's `run.json` has `state` in `{paused, blocked, failed}`) is
rewritten to fit one screen:

```
Run <runid>  •  <state>: <halt_cause>
TDD: <slug>  •  Gate: <gate>  •  Step: <step>
Triggered by: <halt_triggering_finding_ref or short description>

<one-line summary derived from the triggering finding or cause>

Next actions:
  1) <halt_next_actions[0]>
  2) <halt_next_actions[1]>
  [...]

Logs: docs/tdd/.implement-logs/<runid>/
Resume: /implement --resume <runid>     (only when cause is a paused-state value)
```

Total render budget: ≤ 24 lines, ≤ 80 columns. The renderer truncates
finding-summary text and TDD slugs at column boundaries with `...` rather
than wrapping. When the cause's next-action list does not include "resume",
the trailing `Resume:` line is omitted.

### 4b. `--follow` watch-loop hardening — `scripts/status.sh` (addresses issue #30)

While `scripts/status.sh` is open for the §4 rewrite, fix the long-standing
issue #30: the `--follow` mode's `trap 'exit 0' INT TERM` is a no-op when
status.sh is launched as a non-interactive `&` background job (POSIX-1-2017
§2.11 — signals that were ignored on entry to a non-interactive shell cannot
be re-trapped). Two-part fix in the same file:

1. **Widen the trap signal set** from `INT TERM` to `INT TERM HUP QUIT`. HUP
   and QUIT are not inherited as ignored on async fork, so at least one of
   them is always trappable regardless of how status.sh was launched. SIGTERM
   already works; this preserves it.
2. **Add a `--max-seconds N` cap** to the `--follow` loop's argument parser.
   When set, the loop's wall-clock duration is bounded; the loop exits 0 when
   the cap is reached. Optional (default unlimited); intended for CI smoke
   tests and any future scripted use of `--follow`.

The header-comment block of `scripts/status.sh` gains a one-paragraph note
documenting the limitation: "When `--follow` is launched as a background
`&` job from a non-interactive shell, SIGINT is inherited as SIG_IGN and is
silently un-trappable per POSIX-1-2017 §2.11. Use SIGTERM (or SIGHUP/SIGQUIT)
to stop a background `--follow` watch; SIGINT works correctly in the
foreground." The skill's user-facing description in `skills/implement-status/SKILL.md`
gains the same caveat (one sentence) as part of §5.

This sub-section is a small co-located fix; it does NOT modify the halted-run
rendering from §4 and does not interact with the closed halt-cause enum.

### 5. Skill prompt change — `skills/implement-status/SKILL.md`

The skill's user-facing description gains one line documenting the
one-screen contract: "Halted-run rendering fits 24×80 by default. To see
full logs use `cat docs/tdd/.implement-logs/<runid>/REPORT`." And a second
line on the §4b watch-mode caveat: "`--follow` watch mode in a non-interactive
background job: use `kill -TERM` (or `-HUP`/`-QUIT`), not `kill -INT`;
SIGINT is silently un-trappable in that launch mode per POSIX. SIGINT
still works correctly in the foreground." No model-prompted reasoning is
added — the renderer is mechanical.

### 6. Setter functions (in `scripts/lib/state.sh`)

Two new functions, added to the post-TDD-0015 `scripts/lib/state.sh`:

- `set_halt_cause <slug> <cause> [triggering-finding-ref]` — validates
  `<cause>` against the closed enum (returns 1 on unknown value), looks up
  the cause→next-actions mapping, writes `halt_cause`, `halt_triggering_finding_ref`,
  and `halt_next_actions` onto the TDD fragment atomically. If
  `<cause>` is a paused-state cause, also writes `paused_cause` for
  backward compatibility.
- `_next_actions_for_cause <cause>` — internal lookup that returns the
  CSV next-action labels for a given cause. Used by `set_halt_cause`.

TDD 0019's writers call `set_halt_cause` instead of directly editing
fragments.

## Data & state

The on-disk schema additions in §2 are additive. Existing TDD-0008/0011
fragments without the new fields are read with `halt_cause` defaulting from
`paused_cause` (when present) or `null` (when absent). Concrete
backward-compat shim in `_read_fragment_field` (TDD 0015): when asked for
`halt_cause` and the field is missing, fall back to reading `paused_cause`.

Schema-version tracking: TDD 0011 introduced a schema-version field; this
TDD bumps it from whatever 0011 set to the next value, and the renderer's
"new reader, old fragment" path (TDD 0011 §Data) is updated to handle the
new fallback rules.

## Sequencing / implementation plan

1. **Update `scripts/lib/state.sh`** — add the `set_halt_cause` and
   `_next_actions_for_cause` functions; add the closed-enum validation
   array; add the `paused_cause` ↔ `halt_cause` dual-write logic to
   `_write_tdd_fragment`. Bump the schema-version constant.
2. **Update `scripts/status.sh`** — rewrite the halted-run rendering
   branch to read `halt_cause` / `halt_triggering_finding_ref` /
   `halt_next_actions` and produce the one-screen output specified in §4.
   In the same file: widen the `--follow` loop's trap to `INT TERM HUP QUIT`
   and add the optional `--max-seconds N` cap per §4b (addresses issue #30).
3. **Update `skills/implement-status/SKILL.md`** — add the one-line
   contract documentation from §5.
4. **Migrate one existing 0011 cause emission** — change one of TDD 0011's
   existing `paused_cause` write sites in `scripts/lib/pause-retry.sh`
   (post-TDD-0016) to call `set_halt_cause` instead, verifying the dual-write
   produces identical output for paused-state causes. This is the proof
   that the API shim is correct before TDD 0019 lands more writers.

## Failure modes & edge cases

- **Unknown halt_cause encountered by reader.** Renderer emits one warning
  line ("warning: unknown halt_cause '<value>' in fragment <slug> — falling
  back to raw render"), then renders the raw string in the cause position
  and the empty next-action list. Run is not refused.
- **Renderer overflow (cause label + finding ref exceeds 80 cols).** The
  cause and slug fields are short by construction (cause is enum-bounded;
  slugs are kebab-case). The triggering finding's summary text is the only
  long field; it is truncated at column 76 with `...`. The renderer never
  wraps.
- **A halt event occurs but `halt_next_actions` is empty.** The renderer
  emits a `Next actions: (none — see logs for guidance)` placeholder. This
  case should be impossible in practice (the enum maps every cause to a
  non-empty list); it exists as a defensive fallback.
- **A future cause is added to the enum without renderer update.** The
  unknown-value fallback above applies; users can read the raw label and
  consult logs until the renderer catches up.
- **Concurrent paused + blocked across queued TDDs in one run.** The
  run-level `state` field's resolution rule from TDD 0011 ("paused when
  ≥1 paused fragment AND no fragment mid-transition") is extended:
  `blocked` dominates `paused` in the run-level rollup (i.e., if any TDD
  is `blocked`, the run is `blocked`; only-paused TDDs leave the run in
  `paused`). The renderer renders the dominant halt's cause.

## Verification plan

**Observable surface:** the on-disk TDD fragment JSON (the new fields), the
on-disk `run.json`'s rolled-up state, and the stdout of `scripts/status.sh`
when run against a halted-run fixture.

**Observation points:**

1. **Fragment shape after halt-event write.** From a fixture that produces
   a paused-state halt (mock ratelimit on a fixture TDD), inspect the
   resulting `tdd-<slug>.json`. Expect: `halt_cause == "ratelimit"`,
   `paused_cause == "ratelimit"` (dual-write), `halt_next_actions ==
   ["resume now (retries the gate)", "wait and resume later"]`.
2. **Fragment shape after blocked-state halt.** From a fixture that
   triggers a `structural-finding` (driven by TDD 0019 once both TDDs are
   built; for this TDD's verification, use a manual `set_halt_cause`
   invocation from a test script). Expect: `halt_cause ==
   "structural-finding"`, `paused_cause` absent or null,
   `halt_triggering_finding_ref == "<test-supplied-ref>"`,
   `halt_next_actions == ["revise TDD via /tdd-author", "see
   docs/tdd/BLOCKERS.md"]`.
3. **Run-level state rollup.** With a fixture run where TDD A is `paused`
   and TDD B is `blocked`, expect `run.json.state == "blocked"`.
4. **Renderer output fits the budget.** Pipe the renderer's output for the
   halted-run fixture into `awk 'END { print NR }'` (line count) and
   `awk '{ if (length > max) max = length } END { print max }'` (max line
   length). Expect: line count ≤ 24, max column ≤ 80. The output also
   contains the cause label, the triggering finding ref, and each
   next-action option on its own numbered line.
5. **Renderer output for non-paused cause omits the Resume: line.** Run
   the renderer against the `structural-finding` fixture. Expect: no
   `Resume: /implement --resume` line in the output.
6. **Backward-compat read.** Construct a TDD-0011-shape fragment that has
   `paused_cause` but no `halt_cause`. Read it via the updated
   `_read_fragment_field`. Expect: `halt_cause` read returns the
   `paused_cause` value (fallback).
7. **Setter rejects unknown cause.** Call `set_halt_cause foo
   not-in-enum`. Expect: exit code 1, stderr contains a message naming
   the invalid value.
8. **`status.sh --follow` background SIGINT footgun closed (issue #30).**
   Reproducer from issue #30: launch `bash scripts/status.sh --logdir
   <fixture> --follow 1 >/dev/null 2>&1 &`, capture `$!`, send
   `kill -INT $PID`. Pre-fix: process stays alive. Post-fix: process
   still stays alive (SIGINT genuinely is un-trappable in this launch
   mode per POSIX), but `kill -HUP $PID` or `kill -QUIT $PID` now exits
   the loop within 1 second (the watch sleep interval). Additionally,
   `bash scripts/status.sh --logdir <fixture> --follow 1 --max-seconds 2
   >/dev/null 2>&1; echo $?` exits 0 within 2 seconds without any
   external signal.

**Expected observations (PASS):** every numbered observation point above
yields the cited result.

## Requirement traceability

| Requirement | Design element satisfying it |
|---|---|
| FR-63 (closed enum of human-needed halt causes) | §1 enum + §6 `set_halt_cause` enforcement (validates against the closed set; rejects unknown values) |
| FR-64 (one-screen halt context with cause, triggering finding, next actions) | §4 renderer rewrite + §3 deterministic next-actions mapping + §2 schema fields backing the renderer |
| FR-29 (TDD 0008 watch-loop UX; issue #30 hardening) | §4b `--follow` trap widening (`INT TERM HUP QUIT`) + `--max-seconds N` optional cap; not a new FR, this is a co-located robustness fix on the same file §4 already opens |
| Supersession of TDD 0011's halt taxonomy | §1 enum subsumes TDD 0011's `paused_cause` enum; §6 setter is the new authoritative writer; backward-compat shim (`paused_cause` dual-write + reader fallback) preserves existing renderers during the transition |

No gaps. FR-65/66/67 (rework-budget, scope, structural escalation) are
declared in the enum here so the renderer + schema are ready, but their
*writers* are TDD 0019's responsibility — listed in §1's "Source" column.

## Dependencies considered

No new dependencies.

(Alternative considered: **separate `paused_cause` and `blocked_cause`
fields, each its own enum** — rejected: doubles the schema surface and
forces every reader to handle two fields; the unified `halt_cause`
matches FR-63's "single closed enum" wording directly.)

(Alternative considered: **render halt context via a `claude -p` "summarize
the halt" call** — rejected: violates ADR 0006 (gate decisions grounded
in verifiable artifacts only) and ADR 0004 (verification is observation,
not narrative). The renderer is mechanical; the data is on disk.)

## PRD conflicts surfaced (and resolution)

The PRD's mention of `paused` as "sub-category of FR-63's human-needed halt
enum" left ambiguous whether the runtime `status` field should be
unified (single `halted` state with cause sub-discrimination) or stay
split (`paused` vs `blocked` as distinct states with a shared cause
enum). This TDD picks the latter (stay split, share enum), because:

- `paused`'s automatic resume semantics differ materially from `blocked`'s
  human-design-action semantics; collapsing them would erase a meaningful
  runtime distinction users already rely on (`/implement --resume`
  semantics from TDD 0011).
- The PRD's acceptance ("every halt event ... cites a value from a closed
  enum") is met by the shared enum regardless of how many runtime states
  draw from it.

This resolution is documented here rather than escalated to an ADR
because it is local to the halt-taxonomy design, not a cross-cutting
disposition.

## Decisions to promote (ADR candidates)

- **ADR 0007 — Halt model: bounded rework + structural escalation.**
  This TDD authoritatively declares the closed halt-cause enum that ADR
  0007 institutionalizes. TDD 0019 wires the rework + escalation
  behaviors that ADR 0007 also covers. The ADR captures the cross-cutting
  disposition that binds all future gates; the TDDs implement it.
  Confidence: HIGH (per the design plan).

## Scope override

This TDD's doc body sits 15 lines over the 350-line default
`THROUGHLINE_TDD_MAX_LINES` cap after a follow-up revision added §4b
(`scripts/status.sh --follow` trap widening + `--max-seconds` cap;
addresses issue #30). The pre-revision body was 319 lines (under cap);
the §4b addition + verification §8 + traceability + sequencing + touched-
files updates added the deciding ~46 lines. The §4b fix is co-located
with §4 (both touch `scripts/status.sh`); splitting it to a separate
TDD would either fragment the file's edit set across two design PRs or
duplicate the touched-file declaration. The override is recorded per
FR-53's escape clause.

## Touched files

- `scripts/lib/state.sh` (delivered by TDD 0015) — additions per §1, §2, §6
- `scripts/status.sh` (modified by §4) — halted-run rendering rewrite
- `scripts/lib/pause-retry.sh` (delivered by TDD 0016) — one call-site
  migration per §Sequencing step 4
- `skills/implement-status/SKILL.md` — one-line contract documentation per §5

Total: 4 files touched.

## Expected diff size

- `scripts/lib/state.sh` — ~120 lines added (enum array, two new setter
  functions, dual-write logic, schema-version bump)
- `scripts/status.sh` — ~95 lines changed (rewritten halted-run branch
  per §4 + trap widening + `--max-seconds N` parser + header-comment
  documentation block per §4b; net ~+55 lines)
- `scripts/lib/pause-retry.sh` — ~10 lines changed (one call-site migration)
- `skills/implement-status/SKILL.md` — ~3 lines added

Total expected diff: ~220 lines across 4 files. No exceptions needed; each
file is well within the 300-line per-file bound.

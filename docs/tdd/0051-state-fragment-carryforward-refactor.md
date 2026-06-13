# TDD 0051: Quote-safe fragment reads — route mutator inline reads through the canonical reader
Status: implemented
PRD refs: FR-27 (structured run-state record); FR-39 (resume from state); FR-40 (resume baseline); FR-69 (self-compliance with Theme A)
PRD-rev: d7bc491
ADR constraints: 0006

## Approach
This TDD is the **correctness half** of the original 0051. A 2026-06-13 re-survey
of master (post 0050/0057) showed the live A10/A5 carry-forward corruption has
shrunk to a small, surgical surface, so 0051 is narrowed to close it cleanly; the
larger read-all/write-all *maintainability* refactor moves to **[[0058]]** (a
deferred draft).

**The bug (A10/A5).** The per-TDD run-state fragment (`state.d/<slug>.json`) is
mutated by **13 functions** that each open-code a "read every carry-forward field
into locals, override the 1–3 they own, re-write all fields" block. Several of
those reads are inline `sed -n 's/.*"k":"\([^"]*\)".*/\1/p'`. The `[^"]*` class
stops at the first `"` byte — which is the quote half of a stored `\"` escape — so
a free-text value containing a double-quote is **truncated** on read, then the
dangling `\` re-escapes to `\\` on the next `json_escape` write, compounding the
corruption on every transition.

**What 0050 already fixed, and what's left.** 0050 routed the standalone
`_read_fragment_field` through the quote-aware, jq-free `tl_json_field`
(`scripts/lib/json.sh`). In the mutator read-blocks, the important forensic field
`halt_cause_detail` is ALREADY read via `_read_fragment_field` (safe). The
re-survey found the **only genuinely free-text field still read by the vulnerable
inline `[^"]*` sed is `note`** (~12–13 sites, one per mutator read-block); the
other inline `[^"]*` reads are `path`/`branch`/`pr_url`/`log` (quote-free in
practice — git refnames, file paths, percent-encoded URLs) and
`status`/`stage`/`mode`/`change` (closed enums / identifiers). So the live
corruption is `note`, and the rest is a latent class waiting for the next
free-text field added to a read-block.

**The fix.** Convert **every** inline `[^"]*` free-text string read of a fragment
field, across `state.sh` + `resume.sh` + `pause-retry.sh`, to the existing
`_read_fragment_field` wrapper (which the same blocks already use for
`halt_cause_detail`, `paused_cause`, etc.). This (a) closes the live `note`
corruption, (b) eliminates the whole inline-`[^"]*` reader class so a future
free-text field can't reintroduce it, and (c) leaves a clean, greppable invariant.
It is **read-side only** — the write path (`json_escape`/`tl_json_escape`) is
already correct. No new helper, no schema change, no positional-writer change.

## Components & interfaces
No new public interface. The change is a mechanical reader swap at the call sites,
reusing the canonical reader 0050 shipped:

- **`_read_fragment_field <file> <key>`** (`scripts/lib/state.sh`, existing) — the
  quote-aware, unescaping, field-name-validated reader that delegates to
  `tl_json_field` (json.sh). Every converted site becomes
  `key="$(_read_fragment_field "$f" key)"`. Reuse, not redefine — honoring 0050's
  json.sh single-source convention (the `tests/json-helper.test.sh`
  `[single-source]` invariant forbids a new extractor outside json.sh).
- **The 13 mutator read-blocks** (`state.sh`: `state_init`, `set_tdd_state`,
  `set_tdd_meta`, `set_halt_cause`, `_record_cleared_step`,
  `_rewrite_fragment_findings`, `_rewrite_fragment_rework`,
  `_reset_rework_attempts`, `_update_branch_head_at_pause`,
  `_accept_blocked_as_paused`; `resume.sh`: `_update_paused_cause` + the resume
  orchestration reads; `pause-retry.sh`: `_append_retry`, `_enter_paused`) —
  each inline `sed -n 's/.*"<field>":"\([^"]*\)".*/\1/p' … | head -1` for a
  string field is replaced by `_read_fragment_field "$f" <field>`.
- **`stage` null-guard collapse.** Sites read `stage` as
  `if grep -q '"stage":null' "$f"; then stage=""; else stage="$(sed …)"; fi`.
  Because `_read_fragment_field` returns empty for a `null` or absent field (its
  documented contract), this collapses to `stage="$(_read_fragment_field "$f"
  stage)"` with identical semantics — the guard becomes redundant, not removed
  behavior.
- **Out of scope, declared:** the numeric reads (`"n":\([0-9]*\)`,
  `started_at`, `queue_pos`) stay as-is (not `[^"]*`, not free-text); the
  structural array/object readers (`_read_fragment_array_csv`,
  `_read_fragment_raw_array`, `_read_fragment_raw_object`,
  `_read_fragment_cleared_log` — all `[^]]*` bracket matches) stay as-is
  (quote-free by construction); `scripts/status.sh` is the read-only renderer
  (a separate concern with its own inline reads, not a carry-forward-WRITE path)
  and is **not** touched here.

## Data & state
No on-disk schema change, no record-version bump, no migration. The fragment
format is identical; only the read *mechanism* at the call sites changes. A
fragment written before this TDD reads back identically; a value with no JSON
escapes is byte-identical through the new reader (the unescape is the identity on
escape-free input). The single intended output difference: a `note` containing a
`"` now reads back intact instead of truncated.

## Sequencing / implementation plan
1. Convert the inline `[^"]*` free-text fragment reads in `scripts/lib/state.sh`
   (the 10 mutator read-blocks) to `_read_fragment_field`, collapsing each
   `stage` null-guard to a plain safe-reader call.
2. Convert the inline `[^"]*` free-text fragment reads in `scripts/lib/resume.sh`
   (the `_update_paused_cause` carry-forward block + the resume-orchestration
   reads) to `_read_fragment_field`.
3. Convert the inline `[^"]*` free-text fragment reads in
   `scripts/lib/pause-retry.sh` (`_append_retry`, `_enter_paused`) to
   `_read_fragment_field`.
4. Add `tests/state-carryforward-quotesafe.test.sh` (drive the mutators with a
   quote-bearing `note`; assert round-trip integrity + the no-inline-reader grep
   invariant; the `stage:null→empty` regression), then register it in
   `tests/implement-gate.test.sh` (new `SCQ_FAIL` term + AND-chain), red-first
   per the TDD 0038 §3 wire-in rule.

## Failure modes & edge cases
**Real risks.**
- *A converted read changes a value a downstream comparison depends on.* The only
  field whose output changes is a quote-bearing one, and only `note` can carry a
  `"`; `note` is forensic display text, never a control-flow comparand. Quote-free
  fields are byte-identical. Mitigated by Verification §1 (quote-free equivalence)
  + §3 (no control-flow path reads `note`).
- *The `stage` null-guard collapse changes the null/absent path.*
  `_read_fragment_field` returns empty for `null`/absent — the same value the
  guard produced. Mitigated by Verification §4 (a `stage:null` fragment reads back
  `stage=""`).
- *A free-text field is read by an inline `[^"]*` sed somewhere the grep misses.*
  Mitigated by Verification §2, a repo-grep asserting **zero** inline `[^"]*`
  free-text fragment readers remain in the three libs (the falsifiable invariant).

**Overblown risks.**
- *Performance.* `_read_fragment_field` is one awk pass vs the old one-sed-per-
  field; on the write-path mutators (not a hot loop) the delta is immaterial.
- *Schema migration.* None — the on-disk format is unchanged.

**Unspoken risks (elephants).**
- *Declaring "fixed" while the renderer still truncates.* `scripts/status.sh` has
  its own inline readers for the human-facing snapshot. This TDD fixes the
  carry-forward WRITE path (the corruption *source*); the renderer only *displays*
  and never re-writes, so it cannot compound corruption — but a quote-bearing
  `note` could still render truncated in the status view. That is a separate,
  display-only concern, explicitly left to a future status.sh pass rather than
  silently bundled — the boundary is declared, not hidden.

## Verification plan
- **Observable surface:** (a) the bytes of a fragment file after a mutator runs;
  (b) `_read_fragment_field` stdout for a quote-bearing value; (c) a repo-grep
  over the three libs.
- **Observation points (mechanical; `tests/state-carryforward-quotesafe.test.sh`
  sources `state.sh`/`resume.sh`/`pause-retry.sh` via the existing source-guard
  harness):**
  1. Write a fragment whose `note` is `gate emitted no verdict: "PASS" expected`
     and whose `branch`/`pr_url`/`log` are set; run `set_tdd_state` (then
     `set_halt_cause`); read the fragment back and assert `note` is byte-identical
     to the original (no truncation at the `"`, no `\\` compounding) and that
     `branch`/`pr_url`/`log` are unchanged.
  2. Repo-grep `state.sh` + `resume.sh` + `pause-retry.sh`: assert **zero**
     `sed -n 's/.*"<field>":"\([^"]*\)".*/.../p'` free-text string readers remain
     (the array/object `[^]]*` readers and numeric `[0-9]*` reads are explicitly
     excluded from the assertion).
  3. Drive a mutator on a fragment whose `note` holds a `"`, then assert no
     control-flow branch consumed a truncated value (the run still routes by
     `status`/`halt_cause`, which are quote-free) — i.e. the same terminal state
     is reached with and without the embedded quote.
  4. Write a fragment with `"stage":null`, run `set_tdd_meta`, read back: assert
     `stage` is empty (the null-guard-collapse regression).
- **Expected observations (PASS):**
  - §1 **A10/A5 regression** — pre-fix the quote-bearing `note` reads back
    truncated at the first `"`; post-fix it round-trips intact (named
    fail-pre/pass-post).
  - §2 the grep returns no inline free-text reader in the three libs.
  - §3 the embedded quote does not alter the terminal run state.
  - §4 `stage:null → stage=""` preserved.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| A10/A5 closure | Quote-bearing note round-trips byte-intact through a mutator transition, pinned by a fail-pre/pass-post regression | Round-trip asserted | No regression, or note still truncates |
| Single-source reuse | All reads route through tl_json_field/_read_fragment_field (the 0050 convention); no new extractor defined | Reuses the safe reader | A new inline parser or escaper copy is introduced |
| Clean grep invariant | Verification asserts no inline `[^"]*` free-text fragment reader remains in state.sh/resume.sh/pause-retry.sh | Invariant asserted for the converted set | Residual inline free-text reader left unasserted |
| Behavior preservation | Quote-free fields byte-identical; `stage:null`->empty preserved; no control-flow change | Equivalence stated + spot-checked | A quote-free field value or stage-null path changes |
| Verification-plan actionability | Observable surface + exact observation points (fragment bytes after each mutator) + expected values | Surface + points named | Tests-pass placeholder |
| Scope-bound adherence | Within per-file + touched-file bounds (no exception needed for the surgical TDD) | Within bounds | Over a bound without exception |
| 0058 deferral honesty | DEFERRED banner + revival prerequisites + corrected 13-mutator survey; not presented as buildable | Marked deferred | Reads as ready-to-build or carries stale survey |

## Requirement traceability
| Requirement / bug | Design element |
|---|---|
| FR-27 (structured run-state) | the fragment round-trip preserves free-text fields losslessly; schema unchanged |
| FR-39 / FR-40 (resume from state) | `resume.sh`/`pause-retry.sh` carry-forward reads route through the safe reader, so a quote-bearing `note`/cause survives a pause→resume transition |
| ADR 0006 (artifacts grounded) | the forensic `note` the human reviews is no longer silently truncated — the durable record is trustworthy |
| bug A10 / A5 | every inline `[^"]*` free-text fragment read → `_read_fragment_field` (tl_json_field); Verification §1/§2 |
| FR-69 (self-compliance with Theme A) | eliminates the inline-`[^"]*` reader class across the three run-state libs, converging on the single canonical reader |

No gaps. The maintainability reuse (#3 read-all/write-all, #2 counter helpers)
is intentionally **not** in this TDD — it is [[0058]] (deferred).

## Dependencies considered
No new external dependency; no jq on the core path (the reused `tl_json_field` is
pure awk). Chosen: reuse the existing `_read_fragment_field` wrapper. Rejected
alternatives:
- **Define a fresh quote-aware extractor in `state.sh`** — rejected: 0050 made
  `scripts/lib/json.sh` the single source for JSON helpers and ships a
  `[single-source]` eval that fails any `tl_json_*`/escaper definition outside it;
  a new extractor would reintroduce exactly the divergence 0050 removed.
- **Fix only the `note` field (~13 sites)** — rejected: closes today's live bug
  but leaves the inline-`[^"]*` reader class in place, so the next free-text field
  added to a read-block silently reintroduces A10/A5, and the verification grep
  can't assert a clean invariant.
- **Do the full read-all/write-all refactor now** — rejected for THIS TDD: it is
  the biggest/riskiest pending change (a rewrite of the run-state I/O every gate
  depends on) for a purely-internal maintainability payoff; split to [[0058]] so
  the correctness fix ships small and safe.

## PRD conflicts surfaced (and resolution)
None. Refactors the read *mechanism* of an existing requirement (FR-27/39/40);
schema and behavior preserved except the intended quote-safety fix. No ADR
reversed. (The PRD advanced to `d7bc491` via the tier-language pass, which does
not touch this TDD's FR refs; PRD-rev bumped accordingly.)

## Decisions to promote (ADR candidates)
None. Routing reads through an existing canonical reader is an internal
consistency fix, not a durable cross-cutting decision. ADR 0006 governs and is
respected.

## Touched files
- `scripts/lib/state.sh` — convert the 10 mutator blocks' inline `[^"]*` free-text reads to `_read_fragment_field`; collapse the `stage` null-guards (A10/A5).
- `scripts/lib/resume.sh` — convert the `_update_paused_cause` + resume-orchestration inline `[^"]*` free-text reads to `_read_fragment_field`.
- `scripts/lib/pause-retry.sh` — convert the `_append_retry` / `_enter_paused` inline `[^"]*` free-text reads to `_read_fragment_field`.
- `tests/state-carryforward-quotesafe.test.sh` — quote-bearing-note round-trip + no-inline-reader grep invariant + stage:null regression.
- `tests/implement-gate.test.sh` — register the new eval (SCQ_FAIL term + AND-chain), red-first wire-in (TDD 0038 §3).
- `.claude-plugin/plugin.json` — version bump (build-applied).

## Expected diff size
- `scripts/lib/state.sh` — 130 lines (61 inline `[^"]*` string reads × ~1-line swap, plus the stage null-guard collapses; ×1.4 shell-lib). Note: of the 61 converted reads, only the ~8 `note` reads (state_init takes `note` as a parameter, so it has none) produce an OUTPUT change — and only when the value holds a `"`; the other ~53 (path/branch/pr_url/log/status/stage) are byte-identical, converted for the clean grep invariant, not for a value change.
- `scripts/lib/resume.sh` — 35 lines (13 swaps; ×1.4).
- `scripts/lib/pause-retry.sh` — 35 lines (13 swaps; ×1.4).
- `tests/state-carryforward-quotesafe.test.sh` — 180 lines (mutator round-trip + grep invariant + regressions; ×1.6 test).
- `tests/implement-gate.test.sh` — 20 lines (registration block + AND-chain term; ×1.6).
- `.claude-plugin/plugin.json` — 2 lines (version bump).
Total expected diff: ~402 lines across 6 files. All files within the 300-line per-file cap (no exception needed); touched files 6 ≤ 8.

# TDD 0051: state.sh fragment carry-forward — single read-all/write-all + quote-safe parse
Status: draft
PRD refs: FR-27 (structured run-state record); FR-39 (resume from state); FR-40 (resume baseline); FR-69 (self-compliance with Theme A)
PRD-rev: 0aa1e28
ADR constraints: 0006

## Approach
The per-TDD run-state fragment (`state.d/<slug>.json`) is mutated by **nine
functions** that each open-code the same block: read EVERY carry-forward field
into locals, override the 1–3 they own, then call `_write_tdd_fragment` threading
all fields back as positional args (state.sh:688-759, 765-822, 833-876, 889-929,
1017-1087, 1097-1138, 1335-1443; resume.sh:32-87; pause-retry.sh:95-141 — reuse
finding #3). `_write_tdd_fragment` now takes **29 positional parameters**; every
mutator must thread the same 25+ args in the same order, and state.sh:185-190's
own comment records that this forced the `preserve-on-absent` compromise (params
26-29) because "one missed site silently wipes findings."

Worse, every free-text field on that path is read with
`sed -n 's/.*"k":"\([^"]*\)".*/\1/p'`. The `[^"]*` class stops at the first `"`
byte — which is the quote half of a stored `\"` escape — so a `note` or
`halt_cause_detail` containing a double-quote is **silently truncated** on every
carry-forward round-trip, and the dangling `\` is re-escaped to `\\` on the next
write, compounding the corruption (**bugs A10 + A5**; 75 such readers across
state.sh + resume.sh). The control fields (status, the closed halt-cause enum,
SHAs) are quote-free so routing is unaffected — only operator-facing forensic text
is corrupted, but it is corrupted **every** transition.

This TDD replaces the nine copies with a single read-all / write-all pair and a
**quote-aware pure-text parser**, so (1) a new fragment field is added in ONE place
instead of nine, and (2) quote-bearing free text round-trips losslessly. It folds
reuse findings #3 (and the #2 counter RMW that shares the same fragile splice) and
bugs A10/A5.

**The parser must stay jq-free.** state.sh's fragment I/O is deliberately
jq-OPTIONAL (`_extract_token_spend` falls back to `null` when jq is absent — "no
new dependency", TDD 0037 dependency-light). So the fix is a **quote-aware awk
parser** that consumes `\"` escapes correctly, NOT a switch to `jq -r` — the same
correct parser is used whether or not jq exists.

## Components & interfaces
**New canonical reader/writer in state.sh:**
```
_read_fragment_all <file>
    Parse the whole fragment ONCE and populate a well-known set of shell vars
    (a fixed namespace, e.g. FRAG_n / FRAG_status / FRAG_stage / FRAG_note /
    FRAG_halt_cause / FRAG_halt_cause_detail / FRAG_findings_json /
    FRAG_step_block_log_json / FRAG_cleared_step_log_json / ... — one per
    carry-forward field). Scalars and free-text via the quote-aware extractor;
    the raw-object/array fields (findings[], *_log) read verbatim as their JSON
    sub-string (the existing _read_fragment_raw_object/_read_fragment_cleared_log
    behavior, reused). Missing file → all-empty, rc 0 (caller-friendly).
_write_fragment_from_vars <file>
    Serialize the SAME FRAG_* var set back to the fragment via json_escape
    (tl_json_escape post-[[0050]]) for strings and verbatim splice for the
    raw json fields. The single writer; `_write_tdd_fragment`'s 29-positional
    contract is retired (or reduced to a thin shim over from-vars during migration).
```
**Quote-aware extractor** (the A10/A5 fix), used by `_read_fragment_all` AND the
standalone `_read_fragment_field` (state.sh:50):
```
_json_field <file> <key>   # awk: locate "key": then consume a JSON string,
                           # honoring \" \\ \/ \n.. escapes; emit the UNescaped
                           # value. Replaces every `[^"]*` sed reader.
```
**The 9 mutators become read-all → override → write-all:**
```
set_tdd_state(){ _read_fragment_all "$f"; FRAG_status=$1; FRAG_stage=$2; ...; _write_fragment_from_vars "$f"; }
```
Each names only the 1–3 fields it changes; all others survive by construction
(no positional threading, so a "missed arg" can no longer wipe a field). The
resume.sh and pause-retry.sh mutators adopt the same pair.

**`set -u` invariant.** `_write_fragment_from_vars` runs under `set -u`, so the
FRAG_* set MUST be initialized before it is called. The contract: a mutator either
(a) calls `_read_fragment_all` first (the normal read-all → override → write-all
shape, which populates every FRAG_*), or (b) for INITIAL fragment creation where no
file exists yet, calls `_read_fragment_all` on the absent file (which sets every
FRAG_* to empty, rc 0) before overriding the creation fields. `_read_fragment_all`
is thus the single initializer of the namespace; `_write_fragment_from_vars` never
guesses a default and a caller never writes without a prior read-all.

**Counter helpers (reuse #2).** `rework_attempts` / `re_review_attempts` are
maps spliced with a hand-rolled `"$key":[0-9]*` sed in 3 places. Add
`_frag_counter_peek <field> <key>` and `_frag_counter_set <field> <key> <val>`
operating on the FRAG_* map vars, so the splice lives once; the public
peek/bump funcs become wrappers. (Folded here because they share the fragment
round-trip; keeps the counter RMW from re-diverging.)

## Data & state
Same on-disk fragment schema (state.d/<slug>.json) — NO schema change, only the
read/write *mechanism*. The FRAG_* namespace is process-local. Backward
compatibility: a fragment written by the OLD writer reads identically through
`_read_fragment_all` (same keys), and a fragment written by the NEW writer is
byte-equivalent for quote-free values (quote-bearing values now round-trip
correctly instead of truncating — the only intended output difference).

## Sequencing / implementation plan
1. Add `_json_field` (quote-aware extractor) and repoint `_read_fragment_field`
   (state.sh:50) to it; this alone fixes A10/A5 for the standalone reader.
2. Add `_read_fragment_all` + `_write_fragment_from_vars` (FRAG_* namespace),
   reusing the existing raw-object/cleared-log readers for the JSON sub-fields.
3. Migrate the 7 in-file state.sh mutators to read-all → override → write-all;
   reduce `_write_tdd_fragment` to a shim (or retire it) so no caller threads 29
   positionals.
4. Migrate the resume.sh (32-87) and pause-retry.sh (95-141) mutators to the pair.
5. Add `_frag_counter_peek`/`_frag_counter_set`; repoint the rework/re-review
   counter funcs.
6. Update `tests/refactor-state-io.test.sh` (+ any fragment-mutator tests) with
   the carry-forward round-trip + quote-safety regressions; register if new.

## Failure modes & edge cases
**Real risks.**
- *A carry-forward field is silently dropped by the new writer* — the exact
  failure the 29-param hack guarded. Mitigated by Verification §1: a round-trip
  test populating EVERY field (incl findings[], step_block_log, cleared_step_log)
  and asserting each non-mutated field survives byte-identical after each mutator.
  This is the gating regression; the refactor is rejected if any field drops.
- *The quote-aware extractor mis-parses a pathological value* (embedded `\\"`,
  a backslash before the closing quote). Mitigated by Verification §2 adversarial
  cases (`a"b`, `a\`, `a\"b`, trailing `\`).
- *state.sh per-file diff exceeds the 300-line bound.* Declared exception (this is
  a cohesive single-file refactor of the mutator family; splitting it leaves
  callers half-migrated against a changed writer — worse than one large file).

**Overblown risks.**
- *On-disk schema migration.* None — the schema is unchanged; old fragments read
  cleanly. No migration step, no version bump of the record.
- *Performance of one awk parse vs many seds.* `_read_fragment_all` does ONE pass
  where the old code did N sed invocations — strictly fewer processes.

**Unspoken risks (elephants).**
- *A reader OUTSIDE the mutator set still uses the `[^"]*` sed.* status.sh has its
  own inline copies ([[0054]] / A28 territory) and learnings.sh reads slug. This
  TDD fixes the carry-forward WRITE path and `_read_fragment_field`; Verification
  §4 greps state.sh+resume.sh to assert no `[^"]*` free-text reader remains in the
  refactored set, and explicitly notes status.sh's readers are out of scope (owned
  by [[0054]]), so the boundary is declared rather than silently partial.

## Verification plan
- **Observable surface:** (a) a fragment file on disk after a mutator runs — its
  field values; (b) `_read_fragment_field`/`_read_fragment_all` stdout; (c) the
  rework/re-review counter values after peek/set.
- **Observation points (mechanical, `tests/refactor-state-io.test.sh`, sourcing
  state.sh via the existing harness):**
  1. Write a fragment with every carry-forward field populated (status, stage,
     note, halt_cause_detail, branch, pr_url, findings[] with 2 entries,
     step_block_log, cleared_step_log, rework_attempts map). Run EACH mutator in
     turn; after each, read the fragment back and assert every field the mutator
     did NOT target is byte-identical to before.
  2. Set `note` and `halt_cause_detail` to values containing `"` (e.g.
     `gate emitted no verdict: "PASS" expected`), run a state transition, read back
     — assert the full original string (no truncation, no dangling `\`).
  3. `_frag_counter_set rework_attempts review:1 2` then `_frag_counter_peek` → 2;
     bump again → 3; on a fresh fragment peek → 0.
  4. Repo-grep state.sh + resume.sh: no `[^"]*` free-text reader remains in the
     mutator/`_read_fragment_field` set; the writer is `_write_fragment_from_vars`
     only.
- **Expected observations (PASS):**
  - §1 (**carry-forward regression**): pre-refactor a field-drop bug would surface
    as a wiped field; post-refactor every non-targeted field survives byte-identical.
  - §2 (**A10/A5 regression**): pre-fix the quote-bearing note reads back truncated
    at the first `"`; post-fix it round-trips intact. Named fail-pre/pass-post.
  - §3: counters peek/set/bump correctly; empty → 0.
  - §4: single read-all/write-all; no `[^"]*` reader in the refactored set.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Requirement + folded-bug traceability | Every FR-53/54/67 tie-in AND each folded bug (A-id) maps to a named design element | All mapped | Any req or folded bug untraced |
| Folded-bug regression coverage | Each folded bug has a named observation point that fails pre-fix / passes post-fix | Each folded bug has a regression check | A folded bug has no regression observation |
| Single-source-of-truth (refactors) | One canonical helper; all callers verified-thin delegates | Callers delegate; one definition | A divergent copy remains |
| Sourcing + back-compat | New shared lib sources cleanly in all 4 contexts incl markers minimal-host; existing callers/tests unbroken | Sourcing + guard specified | A context unhandled or a caller regressed |
| Verification-plan actionability | Observable surface + exact points + expected values | Surface + points named | placeholder/vague |
| Scope-bound adherence | Within bounds, or a declared/justified exception (state.sh) | Within bounds | Bound blown without exception |
| Naming consistency | Same helper names across all 5 TDDs | Mostly consistent | Same concept named two ways |

## Requirement traceability
| Requirement / bug | Design element |
|---|---|
| FR-27 (structured run-state) | one read-all/write-all pair owns the fragment round-trip; schema unchanged |
| FR-39 / FR-40 (resume from state) | resume.sh mutators adopt the lossless pair (step 4); halt_cause_detail no longer truncated on refuse-to-resume |
| ADR 0006 (artifacts grounded) | forensic note/detail preserved intact, so the human-facing record is trustworthy |
| bug A10 / A5 | `_json_field` quote-aware extractor replaces every `[^"]*` reader; Verification §2 |
| reuse #3 | `_read_fragment_all`/`_write_fragment_from_vars` retire the 9 copies + 29-param writer |
| reuse #2 | `_frag_counter_peek`/`_frag_counter_set` single-source the counter splice |
| FR-69 (self-compliance with Theme A) | collapses 9 duplicated mutator blocks + the 29-param writer, bringing state.sh closer to scope-compliant |

No gaps.

## Dependencies considered
No new external dependency, NO jq on the core path. Chosen: a quote-aware awk
parser + a FRAG_* var-set read-all/write-all. Rejected alternatives:
- **`jq -r '.note'` for the free-text fields** — rejected: state.sh fragment I/O
  is deliberately jq-OPTIONAL (TDD 0037 / `_extract_token_spend` fallback); a hard
  jq dep on the core state path reverses that contract and would strand
  jq-less hosts mid-resume.
- **Keep `_write_tdd_fragment`'s positional contract, just add the quote-aware
  reader** — rejected: fixes A10/A5 but leaves the 9-copy / 29-param duplication
  (reuse #3) that already forced the preserve-on-absent compromise and re-bites on
  every future field.

## PRD conflicts surfaced (and resolution)
None. Refactors the mechanism of an existing requirement (FR-27/39/40); schema and
behavior preserved except the intended quote-safety fix. No ADR reversed.

## Decisions to promote (ADR candidates)
None. An internal read-all/write-all refactor of one module is not a durable
cross-cutting decision. ADR 0006 governs and is respected.

## Touched files
- `scripts/lib/state.sh` — `_json_field` quote-aware extractor; `_read_fragment_all` + `_write_fragment_from_vars`; migrate 7 mutators; retire/shim `_write_tdd_fragment`; `_frag_counter_peek`/`_set` (A10/A5, reuse #3/#2).
- `scripts/lib/resume.sh` — migrate the carry-forward mutator (32-87) to the pair; drop its `[^"]*` readers (A5).
- `scripts/lib/pause-retry.sh` — migrate the mutator (95-141) to the pair.
- `tests/refactor-state-io.test.sh` — carry-forward round-trip + quote-safety + counter regressions.
- `.claude-plugin/plugin.json` — version bump (build-applied housekeeping).

## Expected diff size
- `scripts/lib/state.sh` — 320 lines (exception: cohesive single-file refactor of the fragment-mutator family — `_json_field` + read-all/write-all + 7 mutator migrations + counter helpers; splitting leaves callers half-migrated against a changed writer).
- `scripts/lib/resume.sh` — 60 lines (mutator migration + reader replacement; ×1.4).
- `scripts/lib/pause-retry.sh` — 45 lines (mutator migration; ×1.4).
- `tests/refactor-state-io.test.sh` — 150 lines (round-trip all-fields + quote cases + counters; ×1.6 test).
- `.claude-plugin/plugin.json` — 2 lines (version bump).
Total expected diff: ~577 lines across 5 files. One inline exception declared on `scripts/lib/state.sh` (cohesive refactor over the 300-line per-file cap); all other files well under cap (the `.claude-plugin/plugin.json` bump is a trivial build-applied 1-line change).

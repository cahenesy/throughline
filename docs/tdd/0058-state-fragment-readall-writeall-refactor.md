# TDD 0058: state.sh fragment carry-forward — single read-all/write-all pair (DEFERRED)
Status: draft
PRD refs: FR-27 (structured run-state record); FR-39 (resume from state); FR-40 (resume baseline); FR-69 (self-compliance with Theme A)
PRD-rev: d7bc491
ADR constraints: 0006

## Approach
> **STATUS (2026-06-13): DEFERRED — the maintainability half split out of [[0051]].**
> 0051 shipped the *correctness* fix (route the inline `[^"]*` free-text reads
> through the canonical `tl_json_field` reader, closing A10/A5). This TDD carries
> the *maintainability* refactor: retire the 29-positional `_write_tdd_fragment`
> and the 13 duplicated read/override/write blocks behind a single read-all /
> write-all pair. It is the **biggest/riskiest pending change** — a rewrite of the
> run-state I/O every gate depends on — for a **purely internal** payoff (add a new
> fragment field in ONE place instead of 13). It is held for a dedicated,
> heavily-verified effort, NOT bundled into the small-and-safe sequence.
>
> **REVIVAL PREREQUISITES (read before building):**
> 1. **0051 must land first.** This design assumes the mutator read-blocks already
>    route through `_read_fragment_field`/`tl_json_field` (0051), so `_read_fragment_all`
>    consolidates *safe* reads rather than re-fixing A10/A5. If 0051 has not merged,
>    re-scope to include the correctness fix.
> 2. **Re-survey the line ranges.** The mutator/function line numbers below WILL
>    have shifted; the 2026-06-13 survey found **13** mutators (`state.sh`:
>    `state_init`, `set_tdd_state`, `set_tdd_meta`, `set_halt_cause`,
>    `_record_cleared_step`, `_rewrite_fragment_findings`, `_rewrite_fragment_rework`,
>    `_reset_rework_attempts`, `_update_branch_head_at_pause`,
>    `_accept_blocked_as_paused`; `resume.sh`: `_update_paused_cause`;
>    `pause-retry.sh`: `_append_retry`, `_enter_paused`) and a 29-positional
>    `_write_tdd_fragment`. Re-confirm both before declaring scope.
> 3. **Reuse json.sh, do not define a new extractor.** `tests/json-helper.test.sh`
>    `[single-source]` mechanically fails any `tl_json_*`/escaper definition outside
>    `scripts/lib/json.sh`. `_read_fragment_all` reads scalars via `tl_json_field`
>    and JSON sub-fields via the existing `_read_fragment_raw_object` /
>    `_read_fragment_raw_array` / `_read_fragment_cleared_log` / `_read_fragment_array_csv`.
> 4. **Stamp the PRD-rev** of the revision against the then-current `docs/PRD.md`.
> 5. **Pin the cumulative-field preservation contract.** The current
>    `_write_tdd_fragment` has a deliberate *preserve-on-absent* behavior (params
>    26–29) for the cumulative fields (`findings`, `self_review_count`,
>    `re_review_attempts`, `step_block_log`) — it is what stops a non-owning
>    mutator from wiping them. Under the FRAG_* scheme this is *intended* to be
>    subsumed by "`_read_fragment_all` populates every FRAG_*, so the write
>    re-emits them unchanged" — but that is the single highest-risk behavioral
>    assumption of the refactor. The revival design MUST state explicitly how
>    `_write_fragment_from_vars` handles each cumulative field (re-emit from the
>    FRAG_* read, never a disk-fallback guess) and the all-fields round-trip
>    regression (Verification §1) MUST exercise a non-owning mutator against a
>    populated `findings[]`/`step_block_log` to prove no wipe.
> 6. **Re-point rubric row 1 at revival.** The shared `## Evaluation rubric` row
>    "A10/A5 closure" is satisfied-by-dependency here (0051 owns it), so its
>    "failing" anchor cannot fire for this TDD. At revival, replace row 1 with a
>    "carry-forward all-fields: no non-owning mutator wipes a cumulative field"
>    criterion that reflects THIS TDD's actual new risk.

The per-TDD run-state fragment (`state.d/<slug>.json`) is mutated by **13
functions** that each open-code the same block: read every carry-forward field
into locals, override the 1–3 they own, then call `_write_tdd_fragment` threading
all fields back as positional args. `_write_tdd_fragment` takes **29 positional
parameters**; every mutator must thread the same 25+ args in the same order, and
state.sh's own comment records that this forced the `preserve-on-absent`
compromise because "one missed site silently wipes findings." Adding a fragment
field is a 13-site edit where a single omission silently drops data.

This TDD replaces the 13 copies with a single read-all / write-all pair so a new
fragment field is added in ONE place and no mutator can drop a field by mis-
threading a positional. It folds reuse finding #2 (the `rework_attempts` /
`re_review_attempts` counter splice, hand-rolled in several places).

## Components & interfaces
**New canonical reader/writer in `scripts/lib/state.sh`:**
```
_read_fragment_all <file>
    Parse the fragment ONCE into a fixed FRAG_* shell-var namespace (one per
    carry-forward field: FRAG_n / FRAG_status / FRAG_stage / FRAG_note /
    FRAG_halt_cause / FRAG_halt_cause_detail / FRAG_findings_json /
    FRAG_step_block_log_json / FRAG_cleared_step_log_json / FRAG_rework_attempts /
    FRAG_build_attempt / … ). Scalars/free-text via tl_json_field (json.sh,
    reused); the raw-object/array fields (findings[], *_log, rework_attempts,
    build_attempt) via the existing _read_fragment_raw_object /
    _read_fragment_raw_array / _read_fragment_cleared_log / _read_fragment_array_csv
    readers (reused verbatim). Missing file -> every FRAG_* empty, rc 0.
_write_fragment_from_vars <file>
    Serialize the SAME FRAG_* set back via tl_json_escape (json.sh) for strings
    and verbatim splice for the raw-JSON fields. The single writer; the
    29-positional _write_tdd_fragment is retired (or reduced to a thin shim over
    _write_fragment_from_vars during migration).
```
**The 13 mutators become read-all → override → write-all:**
```
set_tdd_state(){ _read_fragment_all "$f"; FRAG_status=$1; FRAG_stage=$2; …; _write_fragment_from_vars "$f"; }
```
Each names only the 1–3 fields it changes; all others survive by construction (no
positional threading, so a "missed arg" can no longer wipe a field). `resume.sh`
and `pause-retry.sh` mutators adopt the same pair.

**`set -u` invariant.** `_write_fragment_from_vars` runs under `set -u`, so the
FRAG_* set MUST be initialized before it is called. The contract: a mutator
either (a) calls `_read_fragment_all` first (the normal shape, which populates
every FRAG_*), or (b) for INITIAL fragment creation, calls `_read_fragment_all`
on the absent file (which sets every FRAG_* empty, rc 0) before overriding the
creation fields. `_read_fragment_all` is the single initializer of the namespace;
`_write_fragment_from_vars` never guesses a default and a caller never writes
without a prior read-all.

**Counter helpers (reuse #2).** `rework_attempts` / `re_review_attempts` are maps
spliced with a hand-rolled `"$key":[0-9]*` sed in several places. Add
`_frag_counter_peek <field> <key>` and `_frag_counter_set <field> <key> <val>`
operating on the FRAG_* map vars, so the splice lives once and the public
peek/bump funcs become wrappers.

## Data & state
Same on-disk fragment schema (`state.d/<slug>.json`) — NO schema change, only the
read/write *mechanism*. The FRAG_* namespace is process-local. Backward
compatibility: a fragment written by the old writer reads identically through
`_read_fragment_all` (same keys), and a fragment written by the new writer is
byte-equivalent (0051 already made the reads lossless, so there is no remaining
intended output difference — this is a pure mechanism refactor).

## Sequencing / implementation plan
1. Add `_read_fragment_all` + `_write_fragment_from_vars` (FRAG_* namespace),
   reusing `tl_json_field` for scalars and the existing raw-object/array/cleared-log
   readers for the JSON sub-fields.
2. Migrate the 10 in-file `state.sh` mutators to read-all → override → write-all;
   reduce `_write_tdd_fragment` to a shim over `_write_fragment_from_vars` (or
   retire it) so no caller threads 29 positionals.
3. Migrate the `resume.sh` (`_update_paused_cause`) and `pause-retry.sh`
   (`_append_retry`, `_enter_paused`) mutators to the pair.
4. Add `_frag_counter_peek` / `_frag_counter_set`; repoint the rework/re-review
   counter funcs.
5. Add `tests/state-readall-writeall.test.sh`: the carry-forward all-fields
   round-trip regression + counter regressions; register in
   `tests/implement-gate.test.sh` red-first (TDD 0038 §3).

## Failure modes & edge cases
**Real risks.**
- *A carry-forward field is silently dropped by the new writer* — the exact
  failure the 29-param hack guarded. Mitigated by Verification §1: a round-trip
  test populating EVERY field (incl `findings[]`, `step_block_log`,
  `cleared_step_log`, the counter maps) and asserting each non-mutated field
  survives byte-identical after each mutator. This is the gating regression.
- *`state.sh` per-file diff exceeds the 300-line bound.* Declared exception
  (cohesive single-file refactor of the mutator family; splitting leaves callers
  half-migrated against a changed writer).

**Overblown risks.**
- *On-disk schema migration.* None — the schema is unchanged; old fragments read
  cleanly.
- *Performance.* `_read_fragment_all` does ONE pass where the old code did N
  reads — strictly fewer processes.

**Unspoken risks (elephants).**
- *A half-migration window.* If `_write_tdd_fragment` is shimmed rather than
  retired in one step, a mutator left un-migrated would write through the shim
  with stale positionals. Mitigated by migrating every caller in the same change
  and asserting (Verification §3) that no caller threads positionals to a raw
  writer — the shim, if kept, is read-all/write-all internally.

## Verification plan
- **Observable surface:** (a) a fragment file on disk after a mutator runs — its
  field values; (b) `_read_fragment_all` populated FRAG_* values; (c) the
  rework/re-review counter values after peek/set; (d) a repo-grep over the libs.
- **Observation points (mechanical; `tests/state-readall-writeall.test.sh`
  sources `state.sh` via the source-guard harness):**
  1. Write a fragment with every carry-forward field populated (status, stage,
     note, halt_cause_detail, branch, pr_url, findings[] with 2 entries,
     step_block_log, cleared_step_log, rework_attempts map). Run EACH mutator in
     turn; after each, read the fragment back and assert every field the mutator
     did NOT target is byte-identical to before.
  2. `_frag_counter_set rework_attempts review:1 2` → `_frag_counter_peek` → 2;
     bump → 3; on a fresh fragment peek → 0.
  3. Repo-grep `state.sh`/`resume.sh`/`pause-retry.sh`: the single writer is
     `_write_fragment_from_vars` (the 29-positional raw writer is retired or an
     internal shim only); no mutator threads 25+ positionals.
- **Expected observations (PASS):**
  - §1 (**carry-forward regression**): pre-refactor a field-drop bug would surface
    as a wiped field; post-refactor every non-targeted field survives byte-identical.
  - §2: counters peek/set/bump correctly; empty → 0.
  - §3: one read-all/write-all pair; no 29-positional caller remains.

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
| Requirement / reuse | Design element |
|---|---|
| FR-27 (structured run-state) | one read-all/write-all pair owns the fragment round-trip; schema unchanged |
| FR-39 / FR-40 (resume from state) | the `resume.sh`/`pause-retry.sh` mutators adopt the single pair; no carry-forward field can be dropped on a pause→resume transition |
| ADR 0006 (artifacts grounded) | the forensic record round-trips intact through the consolidated writer |
| reuse #3 | `_read_fragment_all` / `_write_fragment_from_vars` retire the 13 duplicated blocks + the 29-positional writer |
| reuse #2 | `_frag_counter_peek` / `_frag_counter_set` single-source the counter splice |
| FR-69 (self-compliance with Theme A) | collapses 13 duplicated mutator blocks + the 29-param writer, bringing `state.sh` closer to scope-compliant |

No gaps. The A10/A5 correctness fix is owned by [[0051]] (this TDD builds on its
safe-reader base).

## Dependencies considered
No new external dependency, NO jq on the core path. Chosen: a FRAG_* read-all/
write-all pair reusing `tl_json_field`/`tl_json_escape` (json.sh) and the existing
raw-object/array readers. Rejected alternatives:
- **`jq -r '.note'` for the free-text fields** — rejected: state.sh fragment I/O
  is deliberately jq-OPTIONAL (TDD 0037 / `_extract_token_spend` fallback); a hard
  jq dep on the core state path reverses that contract and strands jq-less hosts
  mid-resume.
- **Keep `_write_tdd_fragment`'s positional contract** — rejected: leaves the
  13-copy / 29-param duplication (reuse #3) that already forced the
  preserve-on-absent compromise and re-bites on every future field — the entire
  motivation for this TDD.
- **A new extractor in state.sh** — rejected: violates 0050's json.sh single-source
  convention (the `[single-source]` eval); reuse `tl_json_field`.

## PRD conflicts surfaced (and resolution)
None. Refactors the mechanism of an existing requirement (FR-27/39/40); schema and
behavior preserved. No ADR reversed. (PRD advanced to `d7bc491` via the
tier-language pass, which does not touch this TDD's FR refs.)

## Decisions to promote (ADR candidates)
None. An internal read-all/write-all refactor of one module is not a durable
cross-cutting decision. ADR 0006 governs and is respected.

## Touched files
- `scripts/lib/state.sh` — `_read_fragment_all` + `_write_fragment_from_vars`; migrate 10 mutators; retire/shim `_write_tdd_fragment`; `_frag_counter_peek`/`_set` (reuse #3/#2).
- `scripts/lib/resume.sh` — migrate `_update_paused_cause` to the pair.
- `scripts/lib/pause-retry.sh` — migrate `_append_retry` / `_enter_paused` to the pair.
- `tests/state-readall-writeall.test.sh` — carry-forward all-fields round-trip + counter regressions.
- `tests/implement-gate.test.sh` — register the new eval (RWA_FAIL term + AND-chain), red-first wire-in (TDD 0038 §3).
- `.claude-plugin/plugin.json` — version bump (build-applied).

## Expected diff size
- `scripts/lib/state.sh` — 340 lines (exception: cohesive single-file refactor of the fragment-mutator family — read-all/write-all + 10 mutator migrations + counter helpers; splitting leaves callers half-migrated against a changed writer, a worse state than one large file).
- `scripts/lib/resume.sh` — 60 lines (mutator migration; ×1.4).
- `scripts/lib/pause-retry.sh` — 50 lines (two mutator migrations; ×1.4).
- `tests/state-readall-writeall.test.sh` — 200 lines (all-fields round-trip + counters; ×1.6 test).
- `tests/implement-gate.test.sh` — 20 lines (registration + AND-chain; ×1.6).
- `.claude-plugin/plugin.json` — 2 lines (version bump).
Total expected diff: ~672 lines across 6 files. One inline exception declared on `scripts/lib/state.sh` (cohesive refactor over the 300-line per-file cap); all other files within cap; touched files 6 ≤ 8.

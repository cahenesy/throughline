# TDD 0010: Build observability & safety boundaries

Status: draft
PRD refs: FR-36, FR-37, FR-38 (new)
PRD-rev: f73f2b2
ADR constraints: 0003, 0004; (proposes ADR 0005)

## Approach
This TDD has an asymmetric shape: the runtime behavior covering FR-36..38 is
**already implemented** in `scripts/implement.sh` + `scripts/build-prompt.md`
+ `scripts/verify-runtime-prompt.md` (landed in commit 72192b9 / PR #24,
authored before the PRD captured the requirements). The TDD's scope is
therefore **design rationale + verification + tests for the existing
implementation**, not a new implementation. The build phase emits
`TEST_FIRST: SKIPPED no-new-behavior (covered by existing implementation
72192b9 — TDD scope is tests + verification + design record)`; the new tests
in `tests/build-observability.test.sh` exercise the existing implementation
and pass green on the first commit because the implementation already
satisfies them — they are not "failing-test-first" tests in any meaningful
sense, which is exactly why the gate-1 SKIP is the honest verdict. This is
what FR-15(a)'s test-first-SKIPPED escape hatch is for; the four-gate system
still gates flip on the runtime-verify and review gates passing against the
real artifact.

The cross-cutting design principle the existing implementation embodies — that
gate scope is enforced by **prompt instruction plus downstream gate detection**,
not by sandbox or static-analysis — is promoted to ADR 0005, so future TDDs
inherit it.

## Components & interfaces
The three already-landed artifacts, named and located so the verification plan
has concrete observation points.

1. **`scripts/implement.sh::record_session_pointer` (existing, lines ~152–177).**
   Sourced helper called immediately after each `claude -p` invocation in
   `build_one`, `review_one`, and `verify_runtime_one`. Algorithm:
   - Encode `$PWD`: `enc="$(printf '%s' "$PWD" | sed 's|/|-|g')"`.
   - Look in `${HOME}/.claude/projects/$enc` for `.jsonl` files modified at or
     after the call's start epoch; pick the newest.
   - Append to the per-TDD log: a blank line, `THROUGHLINE_SESSION: <abs-path>`,
     and (if `jq` is on PATH) `Last assistant tool calls (newest last; up to 5):`
     followed by `  <Name>\t<input-prefix-140-chars>` lines.
   - Silent no-op (return 0) when the encoded project dir doesn't exist or
     no eligible `.jsonl` is found.
   `start` is captured via `local start; start=$(date +%s)` immediately before
   the `claude` call. The pointer is recorded regardless of the call's exit
   status (so PASS gates also carry a traceable session reference, not only
   failures).

2. **`scripts/build-prompt.md` — "Build-phase boundaries" section (existing,
   inserted between the dependency-no-go and "Design blockers" sections).** Three
   numbered prohibitions, each with its rationale:
   - No spawning nested `claude` processes during build (that's gate 3's job,
     run in a separate process after build returns).
   - No pattern-based process killing (`pkill`, `killall`,
     `pgrep | xargs kill`) — broad patterns match the runner's own `claude -p`
     parent.
   - No runtime-driving fixtures outside the repo (e.g. `/tmp/X`) — those are
     gate 3's surface.
   The rationale travels with each rule so the build claude has the *why*, not
   just the *what*; experience shows model-instruction stickiness is much
   higher when constraints carry their reasoning.

3. **`scripts/verify-runtime-prompt.md` — "Cleanup safety" paragraph (existing,
   inserted before "Print the evidence" closing instruction).** Mandates that
   any background processes spawned to drive the artifact are tracked by PID
   captured from `$!` and killed only by that tracked PID — never `pkill -f
   <pattern>` or `killall`. Same parent-self-kill trap as in build, here
   stated for the gate that *is* allowed to drive the artifact.

### New artifacts this TDD lands (tests + ADR)

4. **`tests/build-observability.test.sh` (new).** Shell-based test suite
   following the existing `tests/implement-gate.test.sh` style (TAP-ish
   ok/fail line per case, final summary). Cases:
   - `record_session_pointer` with a fixture JSONL in the encoded project
     dir writes `THROUGHLINE_SESSION: <expected-path>` to the log.
   - `record_session_pointer` with no fixture (encoded dir absent) is a
     silent no-op (log byte-identical before/after; exit 0).
   - `record_session_pointer` with `jq` removed from PATH (simulate via
     `PATH=/usr/bin env -i`) writes only the pointer line, no tool-call tail.
   - `record_session_pointer` with multiple `.jsonl` files in the encoded
     dir (one older than `start`, one newer) selects the newer one.
   - `scripts/build-prompt.md` contains the literal heading "Build-phase
     boundaries" and the three prohibition keywords (`nested`, `pkill`,
     `/tmp`).
   - `scripts/verify-runtime-prompt.md` contains "Cleanup safety" and `pkill`.

5. **`docs/adr/0005-gate-scope-enforced-by-prompt-not-sandbox.md` (new, via
   `/adr-new`).** Status: `accepted`. Captures the cross-cutting principle
   the existing implementation embodies. Updates `docs/adr/INDEX.md`
   accordingly. See "Decisions to promote" below.

## Data & state
This TDD introduces no persistent state. The only on-disk artifacts it touches:
- The per-TDD gate log (already produced by the runner; this TDD codifies the
  pointer line in its format).
- The session JSONLs at `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` (read
  only; written by Claude Code itself, not by throughline).

## Sequencing / implementation plan
Build phase, in order:

1. **Test-first emission.** End the build with
   `TEST_FIRST: SKIPPED no-new-behavior (covered by existing implementation
   72192b9; TDD 0010 scope is tests + verification + design record)`. The
   runner's gate-1-classify accepts this exact signal per FR-15(a).
2. **Add `tests/build-observability.test.sh`** with the six cases above.
   Each case is its own subshell; failures don't cascade. Total run time
   target: under 5 seconds (fixtures are tiny pre-canned JSONLs in
   `tests/fixtures/`).
3. **Promote ADR 0005** by invoking the `throughline:adr-new` skill (already
   invoked at design time — see "Decisions to promote"). The ADR file +
   `INDEX.md` update ride in this TDD's design PR, so they're already on
   disk when `/implement` runs.
4. **No changes to `scripts/implement.sh`, `scripts/build-prompt.md`, or
   `scripts/verify-runtime-prompt.md`.** Existing impl is correct against
   FR-36..38; this TDD adds only tests + ADR + the design record itself.
5. **Docs sync (in-commit).** Add a one-line mention of TDD 0010 to
   `scripts/implement.sh`'s file-header comment block under the existing
   "four independent gates" enumeration — not new gates, just a pointer
   that gate observability is governed by FR-36 / TDD 0010.

## Failure modes & edge cases
- **Encoded project dir exists but is empty (no `.jsonl`).** `find` returns
  nothing; helper silently exits. No false pointer written. Covered by test
  case 2.
- **Multiple `.jsonl` files in the encoded dir.** Filtered by
  `-newermt "@$start"` then sorted descending by mtime; newest wins. Covered
  by test case 4.
- **`jq` returns an error parsing malformed JSONL.** `2>/dev/null` suppresses
  it; the pointer line still written, tool-call tail omitted. Conservative.
- **`jq` not on PATH.** Pointer line still written; tool-call tail omitted.
  Covered by test case 3.
- **A TDD's verification plan legitimately requires the build to spawn a
  nested Claude process.** This is a real possibility for TDDs about
  agent-orchestration features. The build prompt's FR-37 prohibition would
  block this. Resolution path: the design-reviewer (TDD 0003 / FR-10) catches
  the conflict; the TDD's authoring must either redesign the verification
  approach to avoid nested claude in the build phase (e.g., move it entirely
  to gate 3), or surface as `BLOCKED` per FR-17. This TDD's job is not to
  pre-resolve every such future conflict; the gate is the mechanism.
- **Claude Code upstream changes the project-dir encoding scheme.** Captured
  as a Constraint in PRD ("FR-36 lookup relies on the encoding scheme"); the
  runner's helper would need updating. Test case 1 catches this immediately
  (it would write the wrong path).
- **A run produces a `THROUGHLINE_SESSION:` line pointing at a JSONL that's
  been deleted before the user reads it.** Possible if a developer manually
  cleans `~/.claude/projects/`. The PRD doesn't guarantee JSONL persistence
  beyond Claude Code's own retention; the pointer is best-effort. The
  acceptance criterion ("path resolves to an existing readable JSONL file")
  is evaluated immediately after the gate, not arbitrarily later.
- **`find -newermt "@<epoch>"` is GNU-find-specific; BSD `find` on macOS
  rejects the `@<epoch>` syntax.** The existing `record_session_pointer`
  implementation (in commit 72192b9) uses this construct, so the runner is
  Linux/WSL-first in practice. This TDD is a design record for the existing
  impl, not a portability fix; a future TDD migrating the helper to use a
  POSIX `find -newer <ref-file>` (with a touched marker file) would close
  the gap if/when macOS support becomes a requirement.

## Verification plan
**Observable surface**: per-TDD gate-log file content (greppable, e.g.
`grep -c '^THROUGHLINE_SESSION:' "$log"`); file contents of
`scripts/build-prompt.md` and `scripts/verify-runtime-prompt.md` (greppable);
shell exit code of `tests/build-observability.test.sh`; ADR file existence
and `docs/adr/INDEX.md` listing.

**Observation points & expected observations (PASS)**:
1. Run `bash tests/build-observability.test.sh`. Observe: exit code 0; final
   line matches `=== build-observability eval: <N> passed, 0 failed ===`
   where `<N>` is the number of cases (currently 6).
2. Run `/implement docs/tdd/0010-build-observability-and-safety-boundaries.md`
   in a worktree fixture. After the build gate completes (PASS or FAIL),
   inspect the per-TDD log (`docs/tdd/.implement-logs/<ts>/<slug>.log`):
   `grep -c '^THROUGHLINE_SESSION:' <log>` is exactly `1`, and the path it
   names is an existing readable file.
3. After the FULL `/implement` run (build + verify.sh + runtime-verify +
   review), `grep -c '^THROUGHLINE_SESSION:' <log>` is exactly `3` (one per
   `claude -p` gate: build, runtime-verify, review). Each path resolves.
4. `grep -q '^Build-phase boundaries' scripts/build-prompt.md` exits 0;
   `grep -qE 'nested .*claude' scripts/build-prompt.md` exits 0;
   `grep -q 'pkill' scripts/build-prompt.md` exits 0;
   `grep -q '/tmp' scripts/build-prompt.md` exits 0.
5. `grep -q '^Cleanup safety' scripts/verify-runtime-prompt.md` exits 0;
   `grep -q 'pkill' scripts/verify-runtime-prompt.md` exits 0.
6. `[ -f docs/adr/0005-gate-scope-enforced-by-prompt-not-sandbox.md ]` exits 0;
   `grep -q '0005' docs/adr/INDEX.md` exits 0;
   `grep -q 'accepted' docs/adr/0005-gate-scope-enforced-by-prompt-not-sandbox.md` exits 0.

## Requirement traceability
| PRD | Design element |
|---|---|
| FR-36 Gate-log session pointer | `scripts/implement.sh::record_session_pointer` (existing) called from `build_one` / `review_one` / `verify_runtime_one`; tests case 1–4 in `tests/build-observability.test.sh` |
| FR-37 Build-phase boundaries | `scripts/build-prompt.md` "Build-phase boundaries" section (existing); test case 5 verifies file contents; ADR 0005 promotes the underlying principle (prompt enforcement + downstream detection, no sandboxing) |
| FR-38 Cleanup safety in runtime-verify | `scripts/verify-runtime-prompt.md` "Cleanup safety" paragraph (existing); test case 6 verifies file contents; ADR 0005 also covers |

## Dependencies considered
**No new external dependencies.** The new test suite uses:
- `bash` (already required), `printf`, `grep`, `find`, `sort`, `cut`, `wc`
  (POSIX).
- `jq` (optional; tests degrade gracefully — test case 3 explicitly covers
  the no-`jq` path).
- Test fixtures are committed JSONLs under `tests/fixtures/` (no fixture
  generation at test time, no network).

Rejected alternatives evaluated:
- **A `bats` (Bash Automated Testing System) test suite** instead of the
  existing TAP-ish style in `tests/implement-gate.test.sh`. Rejected:
  introduces a new dev-time dependency, inconsistent with the existing 49
  gate tests, and the existing style is sufficient for the case count.
- **Capturing the FULL session JSONL into the per-TDD log on FAIL** instead
  of the pointer-plus-tail approach. Rejected as PRD non-goal ("Inlining the
  full session JSONL into the per-TDD log"): inlining megabytes per gate
  would bloat logs and obscure the report.

## PRD conflicts surfaced (and resolution)
None. FR-36..38 are internally consistent and consistent with all `accepted`
ADRs. ADR 0005 (proposed here) extends the "govern, not bundle" pattern of
ADR 0004 to gate scope and complements rather than supersedes it.

## Decisions to promote (ADR candidates)
**ADR 0005 — "Gate scope enforced by prompt + downstream detection, not
sandboxing"** (proposed `accepted`).
- *Context*: PR #24's post-mortem of the TDD 0008 build failure surfaced the
  question of how throughline enforces what each gate may or may not do (e.g.,
  build cannot drive the artifact; runtime-verify cannot pkill the parent).
  Two enforcement approaches existed in principle: pre-execution policing
  (sandbox the gate's shell, filter its tool calls) versus prompt-level
  instruction plus downstream gate detection.
- *Decision*: prompt-level instruction (FR-37, FR-38) is the enforcement
  mechanism; the four-gate system's downstream effects (session JSONL
  visibility via FR-36, gate verdicts, commit inspection) are the detection
  mechanism. throughline does NOT sandbox the build's shell, filter its tool
  calls, or sit in front of process invocations with policy.
- *Rejected alternatives* (carried forward into the ADR): bundling a sandbox
  (e.g. firejail, bubblewrap) — adds runtime dependency, OS-specific, and
  contradicts the "delegate mechanism" posture of ADRs 0002–0004;
  introspecting Claude's tool-use stream live to block forbidden calls
  pre-execution — would require an MCP server in front of the runner, complex
  and at the wrong layer.
- *Complements* ADR 0004 (verification mechanism is governed not bundled) by
  applying the same pattern to gate-scope enforcement.
- *Supersedes* nothing.

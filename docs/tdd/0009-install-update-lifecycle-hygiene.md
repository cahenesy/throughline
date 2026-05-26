# TDD 0009: Install/update lifecycle hygiene

Status: draft
PRD refs: FR-31, FR-32, FR-33, FR-34, FR-35 (new)
PRD-rev: f73f2b2
ADR constraints: 0003, 0004

## Approach
Two markers, queried independently, plus a `SessionStart` reconciliation hook
that never launches Claude. The split is the central design choice: **repo state**
(configs, scaffolds, ignore rules) is shared via git and recorded in a committed
marker; **per-developer environment** (installed binaries, package-manager state)
is per-machine and recorded under `${CLAUDE_PLUGIN_DATA}`. One marker can't
answer both — they drift independently and want different reconciliation actions
(silent file edits vs. a visible notice). The post-update hook reads both, the
running plugin version, and a per-release `local_impacting` flag to decide
whether to silently re-apply cheap repo steps and/or print one notice. Bootstrap
becomes mechanically idempotent because re-runs read the repo marker first and
short-circuit steps already recorded as applied. The hook short-circuits via a
single file-stat in repos without the marker, so its session-start cost outside
throughline projects is negligible (NFR-5 spirit; no per-session cost outside
the projects that opt in).

## Components & interfaces

The two-marker model is the authoritative shape — every component reads or
writes against these schemas. Both use a top-level integer `schema` field
(currently `1`), bumped only on a breaking format change.

**Repo-state marker** (`docs/.throughline-bootstrap.json`, committed):
```json
{
  "schema": 1,
  "plugin_version_applied": "3.3.3",
  "language": "shell",
  "repo_steps_applied": ["scaffold", "gitignore", "git_init"],
  "applied_at": "2026-05-26T20:30:00Z"
}
```
`repo_steps_applied` is the closed enumeration `{scaffold, gitignore, linter_config,
test_framework_config, git_init}` — exactly the bootstrap actions whose
on-disk effect is visible to teammates via git.

**Per-developer local marker** (`${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json`, per-machine):
```json
{
  "schema": 1,
  "plugin_version_seen": "3.3.3",
  "local_steps_completed": ["deps_installed"],
  "updated_at": "2026-05-26T20:30:00Z"
}
```
`local_steps_completed` is initially `{deps_installed}` (the worktree-deps-install
step `/implement` already does per FR-20, repurposed as a "the developer has run
this at least once for this repo" signal). Reserved for future per-machine state.

The `<repo-id>` derivation is a pure function:
```
repo_id := sha256_hex_prefix12( git remote get-url origin || abspath(repo_root) )
```
First 12 hex chars (48 bits) — collision-vanishingly-rare across one developer's
repos, short enough for readable paths. The function lives in a shared shell
helper `scripts/lib/repo-id.sh` so bootstrap, the hook, and any future caller
compute the same id.

### File / module changes

1. **`scripts/lib/repo-id.sh` (new).** Sourced helper. Functions:
   - `tl_repo_id` → echoes the 12-hex-char id for `$PWD`'s containing repo
     (`git rev-parse --show-toplevel` first; if not in a repo, exits 1).
     Uses `git remote get-url origin` when present, else absolute toplevel
     path; hashes with `sha256sum`, takes first 12 hex chars.
   - `tl_local_marker_path` → echoes `${CLAUDE_PLUGIN_DATA}/$(tl_repo_id)/local.json`
     (and `mkdir -p` its dir as a side effect when `CLAUDE_PLUGIN_DATA` is
     writable; emits to stderr and returns 1 when not writable).
   The helper handles the no-`sha256sum`/no-`git`/no-`CLAUDE_PLUGIN_DATA`
   degraded cases explicitly so callers can fail closed.

2. **`scripts/lib/markers.sh` (new).** Sourced helper. Functions:
   - `tl_repo_marker_read` → outputs the repo marker JSON or `{}` if absent/malformed.
   - `tl_repo_marker_write <plugin_version> <language> <steps_csv>` →
     writes `docs/.throughline-bootstrap.json` atomically (`.tmp` + `mv`),
     setting `applied_at` to current ISO-8601 UTC.
   - `tl_local_marker_read` / `tl_local_marker_write <plugin_version> <steps_csv>`
     — same shape, against `tl_local_marker_path`.
   - All writes use `printf` with manual JSON escaping for the few string fields
     (no `jq` dependency for *writing*; `jq` remains optional for *reading*
     downstream).

3. **`scripts/lib/gitignore.sh` (new).** Sourced helper. Function:
   - `tl_gitignore_add_line <line>` → if the consumer's `.gitignore` (relative
     to `git rev-parse --show-toplevel`) doesn't already contain an exact-match
     line equal to `<line>` (compared with `grep -Fxq`), append it; create the
     file if absent. Returns 0 in both "added" and "already present" cases.
     Re-running is byte-identical when the line is present.

4. **`skills/bootstrap-project/SKILL.md` (modified).** Add two new steps and a
   re-run contract:
   - **Step before any work**: source `scripts/lib/markers.sh`; read the repo
     marker. If `plugin_version_applied` is set, print
     `already bootstrapped at <plugin_version_applied> (language: <language>)`
     and short-circuit: only re-apply the cheap idempotent steps — the FR-32
     gitignore line and any of the following docs-scaffold files that the
     existing SKILL.md guards with "if absent" and that are now missing:
     `docs/PRD.md` (the stub-with-section-headers form), `docs/adr/INDEX.md`
     (the empty index with header row), `docs/tdd/` (empty directory), and
     `docs/README.md` (the canonical-vs-transient note). If the marker is
     absent or malformed, proceed with the normal greenfield/brownfield flow
     as today.
   - **Step after a successful bootstrap**: source `scripts/lib/gitignore.sh`,
     `tl_gitignore_add_line "docs/tdd/.implement-logs/"`. Then source
     `scripts/lib/markers.sh`, `tl_repo_marker_write <plugin-version>
     <detected-language> <steps-applied-csv>` and `tl_local_marker_write
     <plugin-version> deps_installed`.
   The skill is model-driven; these steps go in its prompt with explicit shell
   commands the model must run, so the markers are not optional.

5. **`hooks/throughline-session-reconcile.sh` (new).** A pure shell script
   registered as `SessionStart`. Flow (in order; any step's failure is silent):
   1. `cd "$(git rev-parse --show-toplevel 2>/dev/null)"` — if not in a git
      repo, exit 0 (no throughline project here).
   2. `[ -f docs/.throughline-bootstrap.json ] || exit 0` — short-circuit; this
      is the per-session-start cost outside throughline projects.
   3. Source the three helpers (above) and read the repo marker.
   4. Read current plugin version from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`
      via `sed` (no `jq` dependency for one field).
   5. **Repo reconcile**: if `plugin_version_applied != current_version`,
      re-apply the cheap idempotent steps (`tl_gitignore_add_line
      "docs/tdd/.implement-logs/"` and any missing docs-scaffold files); write
      the marker with `plugin_version_applied = current_version`. Silent.
   6. **Local notice**: if `tl_local_marker_read | jq -r .plugin_version_seen`
      differs from current AND any release in the gap is flagged local-impacting
      (see point 6 below), print exactly one line to stderr:
      `throughline updated <old>→<new>; run /bootstrap-project to refresh your local toolchain`.
      Then write `plugin_version_seen = current_version`. If `jq` is absent OR
      the releases file is missing/malformed, do NOT print the notice (default
      to "no local action needed"; conservative — better silent than spurious).
   7. Exit 0.

6. **`.claude-plugin/releases.json` (new).** Append-only release-metadata
   manifest, queried by the hook (step 6 above) and editable per release:
   ```json
   [
     { "version": "3.3.4", "local_impacting": false },
     { "version": "3.3.3", "local_impacting": false },
     { "version": "3.3.2", "local_impacting": false },
     { "version": "3.3.1", "local_impacting": false }
   ]
   ```
   A release omitted from the manifest defaults to `local_impacting: false`
   (conservative — never spam without explicit signal). The plugin maintainer
   appends a new entry as part of any release bumping `plugin.json`'s `version`
   that changes local-developer-required setup (a new toolchain dep, an
   incompatible deps bump, a CLI binary added). The current release at this
   TDD's authoring is 3.3.4 (this design PR's bump); none of 3.3.1..3.3.4 are
   local-impacting (they're pure governance/runner changes).

7. **`hooks/hooks.json` (modified).** Register the new hook:
   ```json
   {
     "hooks": {
       "SessionStart": [
         { "hooks": [{ "type": "command",
           "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/throughline-session-reconcile.sh\"" }] }
       ]
     }
   }
   ```
   Existing `PostToolUse` (format-and-lint) entries are preserved.

## Data & state
- **Repo marker** is small (5 JSON fields) and changes only on bootstrap-time
  events (initial bootstrap, repo-marker version reconcile by the hook). Lives
  under `docs/` so it's discoverable next to the design-of-record.
- **Local marker** is per-developer and ephemeral (lives under
  `${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json`). Deleting the repo or moving
  it to a new machine produces a fresh marker on next session-start (the
  `<repo-id>` differs); no migration is performed.
- **Release manifest** is append-only; rewriting an existing entry's
  `local_impacting` flag after release is a bug-fix that doesn't break
  consumers (the worst case is one extra notice; the field's value can only be
  bool).

## Sequencing / implementation plan
1. Land helpers (`scripts/lib/repo-id.sh`, `markers.sh`, `gitignore.sh`) with
   unit tests for each. Pure functions, no IO outside the marker writes; easy
   to test in isolation. Test order: repo-id → gitignore → markers.
2. Wire the helpers into `/bootstrap-project` (skill prompt edit). Test by
   running bootstrap twice on a fresh fixture repo and asserting (a) marker
   created on first run, (b) "already bootstrapped" stdout on second run, (c)
   marker byte-identical between runs.
3. Add `.claude-plugin/releases.json` with the historical entries.
4. Add the SessionStart hook and register it. Test by:
   (a) starting a session in a non-throughline repo → asserting no stderr
   output and no file changes (`stat` before/after);
   (b) starting a session in a marker-bearing repo at the current plugin version
   → asserting no stderr output and no file changes;
   (c) artificially backdating `plugin_version_applied` to an older version and
   starting a session → asserting `.gitignore` reconciled, marker bumped, no
   stderr output (since none of the simulated old→new versions are local-
   impacting);
   (d) marking a release as `local_impacting: true` in a fixture
   `releases.json` and repeating (c) → asserting the notice on stderr exactly
   once.

## Failure modes & edge cases
- **Marker present but malformed JSON.** Bootstrap rebuilds it (warns to
  stdout); the hook treats `tl_repo_marker_read` returning `{}` as "needs
  reconcile" and re-applies the repo steps (idempotent so this is safe).
- **`.gitignore` already contains a glob (`docs/tdd/.implement-logs/*` or
  `docs/tdd/**`).** `tl_gitignore_add_line` checks for the *exact line*
  `docs/tdd/.implement-logs/`. If a glob covers it, the exact line is appended
  anyway — both ignore the path, no harm. The acceptance test uses
  `git check-ignore` (effective coverage) so it passes regardless of which
  line ignored the path.
- **`${CLAUDE_PLUGIN_DATA}` not writable.** `tl_local_marker_path` returns 1;
  bootstrap warns and continues (the repo marker still writes); the hook
  silently skips the local-marker step.
- **No git remote AND non-ASCII repo path.** `sha256sum` operates on bytes;
  any path encodes to a stable id.
- **Hook runs in throughline's OWN repo.** The repo marker will be present
  once we bootstrap the throughline repo at the new version; reconcile applies
  normally. Throughline being its own consumer is by design (eats the dogfood).
- **Release manifest missing / malformed.** Hook treats this as "no release
  is local-impacting" and prints no notice. Conservative: an absent manifest
  is far more common than a real local-impacting release that needs notifying.
- **Concurrent sessions starting.** Both will race to write the local marker.
  Writes are atomic (`.tmp` + `mv`); the loser's write is the final state.
  The repo marker has the same property; concurrent bootstrap runs are
  prevented by FR-18's single-run lock for `/implement` (bootstrap doesn't
  share that lock, but two `/bootstrap-project` invocations are unusual and
  the marker's last-writer-wins semantics are safe).
- **A plugin downgrade** (version applied > current). Treat as a version
  mismatch the same as upgrade: reconcile the repo, bump the marker to the
  current version, no local notice (the manifest only flags `local_impacting`
  going forward; a downgrade is operator-driven, not a notice-worthy event).

## Verification plan
**Observable surface**: file contents (`docs/.throughline-bootstrap.json`,
`.gitignore`, `${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json`,
`.claude-plugin/releases.json`); CLI exit codes (`git check-ignore`); the
SessionStart hook's stdout/stderr.

**Observation points & expected observations (PASS)**:
1. Run `/bootstrap-project` on a fresh empty repo. Observe:
   - `docs/.throughline-bootstrap.json` exists; `plugin_version_applied` equals
     the version read from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`;
     `repo_steps_applied` contains the steps the greenfield path executed.
   - `${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json` exists with
     `plugin_version_seen` equal to the same plugin version and
     `local_steps_completed` containing `"deps_installed"`.
   - `.gitignore` contains a line equal to `docs/tdd/.implement-logs/`.
2. Re-run `/bootstrap-project` on the same repo. Observe:
   - Skill stdout contains `already bootstrapped at <version>`.
   - `docs/.throughline-bootstrap.json` is byte-identical to step 1's output
     (compare with `cmp`).
   - `.gitignore` is byte-identical.
   - No new install or scaffold commands appear in the skill's tool calls.
3. `git check-ignore -q docs/tdd/.implement-logs/anything.log` exits 0;
   `git check-ignore -q docs/tdd/BLOCKERS.md` exits 1;
   `git check-ignore -q docs/.throughline-bootstrap.json` exits 1.
4. Start a Claude Code session in a non-throughline repo (no marker). Observe:
   the hook produces no stderr output and modifies no files (compare
   `find . -newer <pre-mtime>` empty).
5. Backdate `plugin_version_applied` to an older version in the marker, then
   start a Claude Code session in the repo. Observe: marker's
   `plugin_version_applied` now equals the current plugin version; `.gitignore`
   contains the `docs/tdd/.implement-logs/` line; no stderr notice (no local-
   impacting release in the gap).
6. Mark a release as `local_impacting: true` in a fixture `releases.json`,
   backdate the local marker's `plugin_version_seen` past that release, start a
   session. Observe: stderr contains exactly one line matching
   `throughline updated <old>→<new>; run /bootstrap-project to refresh your local toolchain`.
7. Run two parallel `/bootstrap-project` invocations against the same fresh
   repo. Observe: the final state of each marker is the JSON written by one of
   the two (no truncated/corrupted file; `python -m json.tool` parses
   successfully).

## Requirement traceability
| PRD | Design element |
|---|---|
| FR-31 Bootstrap state marker | `docs/.throughline-bootstrap.json` + `scripts/lib/markers.sh` write/read helpers; bootstrap reads on entry to short-circuit, writes on exit |
| FR-32 Consumer-repo .gitignore management | `scripts/lib/gitignore.sh::tl_gitignore_add_line`; called by bootstrap (post-success) and the hook (on repo-marker mismatch) |
| FR-33 Per-developer local-env marker | `${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json`; `<repo-id>` from `scripts/lib/repo-id.sh::tl_repo_id` (sha256-12 of remote URL else abspath); read/write via `markers.sh` |
| FR-34 Post-update reconciliation hook | `hooks/throughline-session-reconcile.sh` + `hooks/hooks.json` SessionStart entry; flow per Components §5 |
| FR-35 Release metadata: local-impacting flag | `.claude-plugin/releases.json`; hook reads to decide on the local notice; default-false on missing/malformed |

## Dependencies considered
**No new external dependencies.** Uses existing tooling:
- `sha256sum` (GNU coreutils, ubiquitous on Linux/WSL) with `shasum -a 256`
  fallback for fresh macOS (BSD environments without Homebrew coreutils).
  `tl_repo_id` tries `sha256sum` first, falls back to `shasum -a 256`,
  finally errors out if neither is present (rare).
- `sed`, `grep`, `printf`, `find`, `mv`, `mkdir` (POSIX).
- `git` (already a hard requirement of the plugin per FR-3, NFR-1).
- `jq` (already optional in the runner per FR-36 / TDD 0010 implementation;
  graceful degradation when absent — only the local notice is gated on `jq`).

Rejected alternatives evaluated:
- **Node `crypto.createHash` for `<repo-id>`** — Rejected: would couple hooks to
  a Node runtime; bootstrap targets multi-language consumer repos where Node
  may not be installed. `sha256sum` is in coreutils, present wherever Bash
  runs.
- **Parsing commit messages for `[local-impacting]` tags instead of
  `releases.json`** — Rejected: requires git history of the *plugin* repo in
  the consumer's local plugin install (the plugin cache doesn't carry git
  history); fragile to commit-message conventions; harder to audit.
- **A single combined marker holding both repo and local state under
  `docs/`** — Rejected: per-developer state in a committed file would
  bounce between developers on every session-start, polluting git history
  and creating spurious diffs. The split is the central design choice this
  TDD enforces.
- **A SessionStart hook that *does* spawn Claude (to auto-rerun
  `/bootstrap-project`)** — Rejected as PRD non-goal: auto-launching a Claude
  process from a hook is heavy, surprising, and depends on Claude being
  available at session start. FR-34 explicitly limits the hook to cheap file
  edits + a notice.

## PRD conflicts surfaced (and resolution)
None. FR-31..35 form an internally consistent set; no conflict with any
`accepted` ADR (0003, 0004) or any existing FR/NFR. The hook's silent file
edits are limited to `.gitignore` and the marker file itself, which are
explicitly in-scope per FR-32 and FR-34; this does not violate NFR-1 (no
auto-merges — the hook never touches git refs).

## Decisions to promote (ADR candidates)
None from this TDD. The two-marker model and the no-Claude-in-hook design are
in-scope of FR-31..35 themselves; both are best documented as PRD requirements
(already done) plus this TDD, not separately as ADRs. (TDD 0010 promotes ADR
0005, which is a cross-cutting principle distinct from this TDD's scope.)

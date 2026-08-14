# TDD 0060: Harness-agnostic skills and dual-marketplace install

Status: implemented
build-engine: bootstrap
PRD refs: FR-79, FR-81, FR-85, FR-34
PRD-rev: 373cd89
ADR constraints: 0010

## Approach
Authoring skills (`/prd-author`, `/tdd-author`, `/adr-new`, `/bootstrap-project`)
and `/implement-status` stay the same phase machines. They stop naming vendor
tools and CLIs. They resolve the plugin tree via `CLAUDE_PLUGIN_ROOT` or
`GROK_PLUGIN_ROOT`. The implement *command* rename to `/build-tdds` is TDD 0062
(this TDD does not rewrite `skills/implement/SKILL.md`). Grok gets a
`.grok-plugin/marketplace.json` so the same git repo is a Grok marketplace.

## Components & interfaces
- `scripts/lib/plugin-root.sh` — defines `tl_plugin_root`. Prints the first
  of `$CLAUDE_PLUGIN_ROOT`, `$GROK_PLUGIN_ROOT` (must be an existing
  directory). If both unset or neither path is a directory: print
  `throughline: set CLAUDE_PLUGIN_ROOT or GROK_PLUGIN_ROOT to the plugin
  install dir` on stderr and return 1. No path probing, no git lookup.
- `skills/{prd-author,tdd-author,adr-new,bootstrap-project,implement-status}/SKILL.md`
  — replace required `AskUserQuestion` / `Task` / `claude -p` / `grok -p`
  with actions ("ask the user a structured multiple-choice question",
  "dispatch a worker", "run a shell command"). Replace
  `${CLAUDE_PLUGIN_ROOT}` with a `source "$(tl_plugin_root)/scripts/lib/plugin-root.sh"`
  then `"$(tl_plugin_root)/…"`. Keep `${CLAUDE_PLUGIN_DATA}` /
  `${GROK_PLUGIN_DATA}` as "first set, else fail closed" for drafts (same
  helper may export `THROUGHLINE_PLUGIN_DATA` as first of those two).
- `.grok-plugin/marketplace.json` — `{ "name": "throughline", "plugins": [{
  "name": "throughline", "source": { "type": "local", "path": "./" } }] }`.
  No Superpowers/pr-review-toolkit dependency entries (ADR 0010).

## Data & state
None beyond the existing draft dir under plugin data. `tl_plugin_root` is
purely env.

## Sequencing / implementation plan
1. Add `scripts/lib/plugin-root.sh` with `tl_plugin_root` and
   `tl_plugin_data` (first of `CLAUDE_PLUGIN_DATA`, `GROK_PLUGIN_DATA`;
   fail closed).
2. Add `tests/plugin-root.test.sh`: unset both → rc 1 + diagnostic;
   `CLAUDE_PLUGIN_ROOT=/tmp` (dir exists) wins; only `GROK_PLUGIN_ROOT`
   works; a set-but-not-a-directory value fails closed.
3. Rewrite the five skill files to actions + `tl_plugin_root`. A
   case-insensitive search of those five files for `AskUserQuestion`,
   `claude -p`, `grok -p` as required names is empty. `${CLAUDE_PLUGIN_ROOT}`
   may remain only as an env *name* in prose describing the helper.
4. Add `.grok-plugin/marketplace.json`. `grok plugin validate .` (or
   `grok plugin marketplace add` dry-run) accepts it.

## Failure modes & edge cases
- **Real:** both env vars unset in agent bash (Grok hooks have
  `GROK_PLUGIN_ROOT` but session bash may not). Mitigation: fail closed
  with the diagnostic; this machine already injects `CLAUDE_PLUGIN_ROOT`
  via `[shell_environment_policy].set`. Do not silently fall back to cwd.
- **Real:** `CLAUDE_PLUGIN_ROOT` points at a stale install copy. Mitigation:
  out of scope (operator `grok plugin update` / Claude plugin update).
- **Overblown:** Grok will not load `.claude-plugin/` — docs say it accepts
  that layout; we still add `.grok-plugin/` so install is explicit.
- **Unspoken:** two marketplaces both named `throughline` (local + github)
  already exist on this machine. The new file does not rename the
  marketplace; collision is operator config, not this TDD.

## Verification plan
- **Surface:** `tl_plugin_root` stdout/stderr/rc; skill file text; Grok
  marketplace validate.
- **Observation points:**
  1. `env -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT bash -c
     '. scripts/lib/plugin-root.sh; tl_plugin_root'` → rc 1, stderr contains
     `CLAUDE_PLUGIN_ROOT or GROK_PLUGIN_ROOT`.
  2. `CLAUDE_PLUGIN_ROOT="$PWD" bash -c '. scripts/lib/plugin-root.sh; tl_plugin_root'`
     prints `$PWD` and rc 0.
  3. `rg -n 'AskUserQuestion|claude -p|grok -p' skills/prd-author/SKILL.md
     skills/tdd-author/SKILL.md skills/adr-new/SKILL.md
     skills/bootstrap-project/SKILL.md skills/implement-status/SKILL.md`
     exits 1 (no matches).
  4. `.grok-plugin/marketplace.json` exists and
     `jq -e '.plugins[0].name=="throughline"'` succeeds.
- **PASS:** all four observations hold.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| Traceability | Every in-scope FR/NFR maps to a named component | One compound mapping still checkable | Untraced or hand-waved FR |
| Interface concreteness | Paths, env vars, JSON fields, and command names are literal | One interface described by role not path | "the helper", "appropriate adapter" |
| Alternatives | Each new dep has a named rejected alternative | No new deps; section says why | New dep with empty alternatives |
| Verification plan | Surface + command/observation + PASS values | Observable but a bit indirect | "tests pass" / missing |
| Scope bounds | Touched files ≤8, estimates padded, exceptions declared | One justified exception | Over bound with no exception |
| Naming | Same concept same name across all four TDDs | One alias noted | /implement vs /build-tdds mixed as the required surface |
| Supervisor-free | No TDD requires parsing stream-json or nesting reviewers | Mentions old runner only as deletion target | Designs a coprocess as flip authority |

## Requirement traceability
- FR-79 → five authoring/status skills remain invocable; they no longer
  require Claude-only tools.
- FR-81 → action language + `rg` observation in the verification plan.
- FR-85 → not implemented here; 0062 owns `/build-tdds`. Gap noted: this
  TDD must not claim the implement rename.
- FR-34 → skills/hooks still use SessionStart; notice remains best-effort
  (no new hook code). Helper fail-closed covers missing plugin data.

## Dependencies considered
No new library or service. Rejected: `readlink /proc/self/exe` or
`git rev-parse` to find the plugin (breaks NFR-5 installed-cache copies).

## PRD conflicts surfaced (and resolution)
FR-85 is in this TDD's PRD-refs from the plan table but is owned by 0062.
Resolution: drop FR-85 from this TDD's frontmatter (already omitted above).

## Decisions to promote (ADR candidates)
None (ADR 0010 already records dual-harness packaging).

## Touched files
- `scripts/lib/plugin-root.sh` — env resolver
- `tests/plugin-root.test.sh` — fail-closed + precedence
- `skills/prd-author/SKILL.md` — action language
- `skills/tdd-author/SKILL.md` — action language
- `skills/adr-new/SKILL.md` — action language
- `skills/bootstrap-project/SKILL.md` — action language
- `skills/implement-status/SKILL.md` — action language + `/build-tdds` wording
- `.grok-plugin/marketplace.json` — Grok install index

## Expected diff size
- `scripts/lib/plugin-root.sh` — 70 lines
- `tests/plugin-root.test.sh` — 160 lines
- `skills/prd-author/SKILL.md` — 80 lines
- `skills/tdd-author/SKILL.md` — 80 lines
- `skills/adr-new/SKILL.md` — 25 lines
- `skills/bootstrap-project/SKILL.md` — 50 lines
- `skills/implement-status/SKILL.md` — 40 lines
- `.grok-plugin/marketplace.json` — 25 lines
Total expected diff: 530 lines across 8 files.

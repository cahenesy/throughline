# TDD 0065: Parent-session model check (FR-86)

Status: draft
PRD refs: FR-86
PRD-rev: 5dbf968
ADR constraints: 0004, 0005, 0006, 0010, 0014

## Approach
`/prd-author`, `/tdd-author`, and `/build-tdds` compare the **parent
session** model to the harness’s current most-capable coding model
**each invoke**. There is no shipped family/rank/alias table.

Observation is a **session artifact** (not self-report). Comparison is
a **this-turn official-docs fetch** (not training memory, not Models
API recency). Cannot observe or cannot fetch/judge → **unreadable** →
the same warn+ask as a weaker session. A session on the fetched
top-tier, or newer, produces no warning.

Stacks on 0064: dispatch ids stay in `models.sh`. This TDD does not
add a second literal and does not change `tl_resolve_models`.

## Components & interfaces
Add the same numbered block to all three skills, immediately after the
existing source/resume preamble and **before** the interview or queue
work (FR-86: before the interview or build proceeds).

**1. Observe** the parent model from the harness session artifact.

- Grok: if `GROK_SESSION_ID` is unset or empty → unreadable. Else
  read `${GROK_HOME:-$HOME/.grok}/sessions/<url-encoded-cwd>/$GROK_SESSION_ID/summary.json`
  field `current_model_id` (string). Missing file, unreadable JSON, or
  empty/absent field → unreadable. `cwd` is `$PWD` first (the session
  cwd the harness actually keys on), then `git rev-parse --show-toplevel`
  if that path is missing. Encoding: percent-encode the absolute path
  including the leading slash (example: `/home/chris/hogv/open-source/throughline`
  → `%2Fhome%2Fchris%2Fhogv%2Fopen-source%2Fthroughline`). Do not
  follow `summary.json` outside `$GROK_HOME/sessions/`.
- Claude: if `CLAUDE_CODE_SESSION_ID` is unset or empty → unreadable.
  Else stream `~/.claude/projects/<encoded-cwd>/$CLAUDE_CODE_SESSION_ID.jsonl`
  (do **not** slurp). Take the last JSON object whose `message.model`
  (or top-level `model`) is a non-empty string **other than**
  `<synthetic>`. Missing file or no such field → unreadable. Encoded
  cwd matches Claude’s project slug: leading `/` → `-`, remaining `/`
  → `-`, `.` → `-` (example: a `.worktrees` path becomes `--worktrees-`).
- No other source. Do not ask the model to name itself.

**2. Fetch official docs this turn** (required; answering from memory
is a defect). Harness pick:

- Claude Code parent: fetch
  `https://platform.claude.com/docs/en/about-claude/models/overview`
  (most-capable widely released coding model) and
  `https://code.claude.com/docs/en/model-config` (aliases `best` /
  `fable` / `opus` / `sonnet` / `haiku`).
- Grok Build parent: fetch
  `https://docs.x.ai/developers/models` (flagship / coding model).

Fetch fail (network, non-200, empty body) → unreadable. Do not fall
back to a cached table or to `models.sh` literals for this compare.

**3. Judge** from the fetched page(s) plus the observed id: is the
observed session weaker than the page’s current most-capable coding
model, equal to it, or newer? Alias resolution is allowed **from the
fetched page** (e.g. `fable` ↔ `claude-fable-5`). Recency-only
(list order / created_at) is forbidden: a post-flagship mid-tier
must still count as weaker.

**4. Warn+ask** (structured Continue / Stop) when the outcome is
**weaker** or **unreadable**. Pinned warning lines:

- weaker:
  `throughline: parent session model <observed> is below the most-capable coding model on this harness (<top> from <url>). Continue, or stop and change the model.`
- unreadable:
  `throughline: parent session model could not be read or the official models page could not be fetched. Continue, or stop and change the model.`

Continue → proceed with the existing skill. Stop → halt; no interview
and no build work. Equal or newer → no warning.

Do **not** insert a rank table (`fable > opus > sonnet`, numeric
`grok-X.Y` compare, or an allowlist of ids) into any skill or script.
The fetched page is the only compare source.

## Data & state
None. No cache file. No env override for the FR-86 bar (the bar is
the page). Dispatch overrides remain 0064 / `models.sh`.

## Sequencing / implementation plan
1. Insert the Observe → Fetch → Judge → Warn+ask block into
   `skills/prd-author/SKILL.md` (after step 0, before step 1).
2. Same block in `skills/tdd-author/SKILL.md` (after step 0, before
   step 1).
3. Same block in `skills/implement/SKILL.md` (after step 1 source,
   before step 2 lock / resume). `/build-tdds` still runs 0064’s
   FR-87 pin warning later; the two warnings are distinct.
4. Add `tests/parent-session-model-check.test.sh`; register it in
   `tests/implement-gate.test.sh`.

## Failure modes & edge cases
- **Real:** a Sonnet parent does the eval from memory and names itself
  top-tier. Mitigation: skill forbids memory; evals assert the fetch
  URLs and the words `this turn` / `not from memory` appear in all
  three skills.
- **Real:** `summary.json` / jsonl path built from cwd is a trust
  boundary. Mitigation: path must stay under the harness sessions
  root; no `..` after encoding.
- **Real:** fetch fail on every airplane / CI skill-eval. Mitigation:
  product path warns+asks (honest). Eval path never hits the network;
  it only greps the skill text (L-011: missing skill file is
  infra-fail, not ok).
- **Overblown:** mid-session `/model` switch leaving a stale
  `current_model_id`. Grok docs say the field is the model in use;
  accept last artifact write as the observation.
- **Unspoken:** FR-86 as written compares to the NFR-3 **binding**.
  This TDD compares to the **live vendor top-tier**. A session on
  our own `models.sh` default will start warning the morning a new
  flagship ships, until 0064’s literals are rebound. That nag is
  the rebind signal, not a second id table.

## Verification plan
- **Surface:** the three skill files (required block + warning
  strings + URLs). No runtime network in CI.
- **Observation points:**
  1. Each of `skills/prd-author/SKILL.md`, `skills/tdd-author/SKILL.md`,
     `skills/implement/SKILL.md` contains `GROK_SESSION_ID`,
     `current_model_id`, `CLAUDE_CODE_SESSION_ID`, the three fetch
     URLs above, `not from memory` (or `this turn`), and both pinned
     warning prefixes (`is below the most-capable coding model` and
     `could not be read or the official models page`).
  2. None of the three contains a rank table: `grep -n 'fable > opus\\|opus > sonnet\\|fable>opus' ` exits 1 on each file.
  3. None of the three tells the parent to proceed silently when the
     model is unreadable (`grep -n 'unreadable' ` matches a warn+ask
     sentence, not a skip).
  4. Missing skill file: the eval’s grep on that path is infra-fail
     (exit ≥2 → `bad`, never `ok`) (L-001).
  5. `scripts/lib/models.sh` is byte-identical to 0064’s pinned
     function (this TDD does not touch it).
- **PASS:** 1–5 hold.

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement traceability | Every in-scope FR/NFR maps to a named component or skill step | One mapping is slightly indirect but still named | An in-scope FR/NFR is missing or only hand-waved |
| interface concreteness | models.sh dispatch ids, inherit spawn, live-fetch compare, and warn+ask are specified with inputs/outputs | One interface is slightly implicit but implementable | A reader cannot tell where dispatch ids live vs where FR-86 looks up |
| alternatives-analysis substance | Live official-docs fetch named; static rank map and Models-API recency rejected with reasons | One rejected alternative is thin but present | No rejected alternative, or none considered |
| verification-plan actionability | Observable surface, observation points, and PASS values named | Observations are concrete but one fixture is slightly underspecified | Non-actionable plan, or the section is missing |
| scope-bound adherence | Touched files within bounds; estimates padded; exceptions declared | One justified inline exception | Over bound with no exception, or undeclared files |
| naming consistency | build=/review=/verify=, inherit, unreadable→warn+ask used the same way in both TDDs | One synonym that still refers to the same thing | Same concept named two ways across the set |
| no static rank map | FR-86 compare is a this-turn official-docs fetch; no shipped family/rank table | Fetch sources named; one fallback sentence is slightly loose | A hardcoded fable>opus>sonnet (or similar) table is the compare |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-86 observe | Session artifact (`current_model_id` / jsonl `message.model`) |
| FR-86 compare | This-turn fetch of the named official URLs; judge weaker/equal/newer from the page |
| FR-86 weaker or unreadable | Pinned warn+ask Continue/Stop before interview or build |
| FR-86 equal or newer | No warning |
| NFR-4 honesty | Unreadable is warn+ask, never silent skip |

## Dependencies considered
No new libraries (skill uses the harness fetch/browse already
available). Rejected: **static family/rank table** in `models.sh`
(goes stale; user-forbidden). Rejected: **Anthropic/xAI Models API
recency** as capability (Sonnet 5 and Opus 5 shipped after Fable 5
and are not more capable). Rejected: **model self-report** of its
own id (not an artifact; FR-70 spirit).

## PRD conflicts surfaced (and resolution)
FR-86’s sentence “compare … to the harness’s latest top-tier binding
(NFR-3)” names the binding as the bar. This TDD uses the **live
vendor top-tier** from the fetched page, which can be newer than
`models.sh`. Resolution (interview): intentional — the nag on a
stale binding is the rebind signal. Recorded in Failure modes.

## Decisions to promote (ADR candidates)
None beyond the 0009 successor already required by 0064.

## Touched files
- `skills/prd-author/SKILL.md` — FR-86 block after resume check
- `skills/tdd-author/SKILL.md` — same block
- `skills/implement/SKILL.md` — same block before lock/queue
- `tests/parent-session-model-check.test.sh` — skill-text eval
- `tests/implement-gate.test.sh` — register the new eval

## Expected diff size
- `skills/prd-author/SKILL.md` — 55 lines
- `skills/tdd-author/SKILL.md` — 55 lines
- `skills/implement/SKILL.md` — 55 lines
- `tests/parent-session-model-check.test.sh` — 150 lines
- `tests/implement-gate.test.sh` — 12 lines
Total expected diff: 327 lines across 5 files.

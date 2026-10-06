---
name: build-tdds
description: Turn features described in the PRD and designed in TDDs into code and tests. Confirms the queue, then sequences one implementer worker, mechanical gates, one runtime-verify worker, and one reviewer worker. Opens a PR per TDD. Never merges. Invoke with /build-tdds.
---

# `/build-tdds`

Interactive parent skill. It sequences workers; it is not a detached
coprocess. Session survival is whatever the harness does.

Usage: `/build-tdds [<tdd-path>] [--combined | --parallel] [--escalate]
[--no-auto-escalate]`. `--escalate` (or `THROUGHLINE_ESCALATE=1`) runs
this run's judgment workers on the escalation model; `--no-auto-escalate`
(or `THROUGHLINE_AUTO_ESCALATE=0`) declines the automatic escalation of a
Retry (FR-88).

## Block contract (every `<!-- tl:… -->` block)

The harness runs each shell call in a fresh shell, so a marker-tagged
block never relies on a variable or function from an earlier call. Run
each block as one shell command. Each block:

- sources its own helpers, fail closed: plugin-root, `models.sh`, and
  `run-record.sh` (except `tl:fr86-check`, whose bytes are shared with
  `/prd-author` and `/tdd-author`);
- computes `TL_PARENT="$(tl_parent_model 2>/dev/null)" || TL_PARENT=""`
  itself when it needs the parent model;
- reads inputs only from env vars, as `${VAR:?VAR required}`, so a
  missing input fails loudly. Prefix the block with `export` lines that
  carry the real values, e.g.
  `export TL_REPO='/abs/repo' TL_RUN='20261005-174458'`.

Inputs: `TL_REPO` (absolute repo root: the human checkout, never the
worktree), `TL_RUN` (run id), `TL_SLUG` (TDD file name without `.md`),
`TL_TDD` (absolute TDD path), `TL_QUEUE` (absolute TDD paths, one per
line), `TL_ARGS` (this skill's argument text; may be empty, so it is read
as `${TL_ARGS?…}`), `TL_REQUESTED` / `TL_AUTO` (the two values the
`tl:escalation-flags` block printed).

Reports: every worker or gate report lives in the run dir root,
`docs/tdd/.implement-logs/<run>/<slug>.<build|ci-checks|verify|review>.txt`
(the implementer's report is `build`, which the test-first gate reads).
The parent creates each one empty before the worker and passes its path.

## 1. Source helpers (fail closed)

Resolve the plugin tree from the first set of `CLAUDE_PLUGIN_ROOT` /
`GROK_PLUGIN_ROOT`, then source helpers. If any source fails, stop.

```
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/verdicts.sh" || exit 1
. "$(tl_plugin_root)/scripts/lib/run-record.sh" || exit 1
. "$(tl_plugin_root)/scripts/lib/models.sh" || exit 1
REPO="$(git rev-parse --show-toplevel)"
```

`REPO` is the human session / integration checkout. Never pass the build worktree path as <repo-root>. Every `tl_verdict_*` and `tl_run_*` call uses `"$REPO"`.

Escalation flags (FR-88): run this block with `TL_ARGS` set to this
skill's argument text (`export TL_ARGS=''` when there are none). Keep the
two printed values; later blocks take them as `TL_REQUESTED` (`requested=`)
and `TL_AUTO` (`auto=`). Non-zero exit → show its stderr and stop.

<!-- tl:escalation-flags -->
```bash
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/models.sh" || { echo "throughline: cannot source models.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/run-record.sh" || { echo "throughline: cannot source run-record.sh" >&2; exit 1; }
: "${TL_ARGS?TL_ARGS required (export TL_ARGS='' when there are no arguments)}"
tl_escalation_flags "$TL_ARGS"
```

## 1a. Parent-session model check (FR-86)

Before the lock and the queue, run this block as one shell command. It
sources its own helpers, so it does not depend on step 1's shell.

<!-- tl:fr86-check -->
```bash
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/models.sh" || { echo "throughline: cannot source models.sh" >&2; exit 1; }
tl_fr86_message
```

If the block printed a line, show that line to the user and ask a
structured question with exactly two options, `Continue` and `Stop`.
`Stop` ends the skill with no interview, no draft init, no lock, and no
queue. `Continue` proceeds. If the block printed nothing, proceed
without asking. If the block exits non-zero, show its stderr and stop
(fail closed).

## 2. Lock (FR-18 / FR-43)

`tl_run_lock "$REPO"`. If held by a live PID → refuse. If held by a dead
PID → `tl_run_lock_reclaim "$REPO"`.

## 3. Resume, Retry, or fresh (FR-39 / FR-40 / FR-88)

First run this block (input `TL_REPO`). It reads `latest` itself and
prints `run=<id>`, then one slug per line for each `failed` /
`gate-fail` TDD of that run (the Retry candidates); it prints nothing when
there is no `latest`. Non-zero exit → show its stderr, unlock, stop.

<!-- tl:retry-candidates -->
```bash
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/models.sh" || { echo "throughline: cannot source models.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/run-record.sh" || { echo "throughline: cannot source run-record.sh" >&2; exit 1; }
: "${TL_REPO:?TL_REPO required}"
tl_run="$(tl_run_latest_run "$TL_REPO")" || exit 0
printf 'run=%s\n' "$tl_run"
tl_run_retry_candidates "$TL_REPO" "$tl_run" || exit 1
```

If `docs/tdd/.implement-logs/latest` has a TDD whose `status` is not
terminal (`done|failed|blocked|skipped`), **or** the block printed at
least one slug:

Ask the user a structured question: **Resume** (the non-terminal TDDs) /
**Retry** (the listed slugs) / **Start fresh**. Offer only the options
that apply.

- **Fresh:** delete `latest` state fragments only (`run.json` and
  `<slug>.json`). Keep logs. Then continue at step 4.
- **Resume:** `g="$(tl_run_next_gate "$REPO" "$run" "$slug")"`. Jump:
  - `test-first` — if the build branch exists **and** has commits beyond
    integration, do **not** re-dispatch the implementer; run step 8
    observe-only. If the branch has no commits beyond integration,
    dispatch the implementer (step 7) with "continue from existing
    branch".
  - `ci-checks` — skip 7–8a; run `ci-checks.sh` only (step 8b).
  - `runtime-verify` — skip 7–8; run step 9 only.
  - `review` — skip 7–9; run step 10 only.
  - `flip` — skip 7–10; run step 11 only.

  Before the first worker a resume dispatches, run the step 7
  `tl:models-record` block: it records the slots against this
  session's parent and prints the dispatch lines.

- **Retry** (FR-88, FR-15), for each listed slug, with `run` = the
  printed run id. Retry is a new, human-triggered invocation, so ADR
  0013's no-in-invocation-rework rule holds.
  1. Worktree: reuse `.worktrees/build-tdds-<slug>` if it exists;
     otherwise `git worktree add .worktrees/build-tdds-<slug>
     build/<run>/<slug>` from that existing branch. If the branch is
     missing, refuse Retry for that TDD and tell the user to Start fresh.
  2. Run the step 5 `tl:escalation-decide` block for the slug **first**:
     it reads the halt-time verdicts. Then run this block (inputs
     `TL_REPO`, `TL_RUN`, `TL_SLUG`). It prints `report=<path>` (the
     failed gate's report, read before archiving; empty when no gate
     verdict FAILed) and saves a copy that step 7's empty
     `<slug>.build.txt` cannot overwrite. Then it archives the halt-time
     verdicts into `retry-<N>/` and sets the TDD `building`, so an
     interrupted Retry resumes from test-first, never past gates on
     changed code. It prints `archive=<dir>` and
     `implementer_report=<copy>`. Non-zero exit → show its stderr,
     unlock, stop.

<!-- tl:retry-begin -->
```bash
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/models.sh" || { echo "throughline: cannot source models.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/run-record.sh" || { echo "throughline: cannot source run-record.sh" >&2; exit 1; }
: "${TL_REPO:?TL_REPO required}" "${TL_RUN:?TL_RUN required}" "${TL_SLUG:?TL_SLUG required}"
tl_report="$(tl_run_failed_report "$TL_REPO" "$TL_RUN" "$TL_SLUG")" || tl_report=""
printf 'report=%s\n' "$tl_report"
tl_copy=""
if [ -n "$tl_report" ]; then tl_copy="${tl_report%.txt}.prev.txt"; cp "$tl_report" "$tl_copy" || exit 1; fi
tl_arch="$(tl_run_retry_begin "$TL_REPO" "$TL_RUN" "$TL_SLUG")" || exit 1
printf 'archive=%s\n' "$tl_arch"
printf 'implementer_report=%s\n' "$tl_copy"
```

  3. Step 5's confirmation (`TL_QUEUE` = `$REPO/docs/tdd/<slug>.md` for
     each retried slug, with `TL_REPO` / `TL_RUN`), then step 7 on the
     existing branch. Prefix the implementer prompt with "A previous
     gate FAILED. Fix what this report found on the existing branch; do
     not start over." and pass the `implementer_report=` path (if it is
     empty, say no gate report exists).
  4. Then run every gate from 8a; each one overwrites its verdict file.
     The verdicts of the failed attempt stay in `retry-<N>/`.

Never treat partial `feat:` commits as build-gate completion. The
test-first verdict file is the only build-complete signal.

## 4. Queue (FR-13, FR-18, FR-84)

Every `docs/tdd/0*.md` on the integration branch whose `Status:` is
`draft` or `ready` and that is not already `implemented` on an unmerged
`build/` branch.

Skip `build-engine: bootstrap` only when
`docs/tdd/.implement-logs/.first-flip-done` does **not** exist (no TDD
on this harness has an `implemented` flip from `/build-tdds` yet). After
that file exists, ignore `build-engine: bootstrap` and queue those TDDs
normally.

Optional argument: a TDD path builds just that one.

`tl_run_init "$REPO" "<run-id>"` if starting fresh. `run-id` is a UTC
timestamp `YYYYMMDD-HHMMSS`. A Retry keeps its run and does not
re-queue.

## 5. Confirm queue + mode

Escalation is decided per TDD **before** the confirmation (FR-88), so
the confirmation shows the escalated model. Run this block once per
queued or retried TDD (inputs `TL_REPO`, `TL_RUN`, `TL_SLUG`,
`TL_REQUESTED`, `TL_AUTO`). When FR-88 applies it prints
`trigger=<requested|auto>` and the one outcome line
`throughline: <slug> escalation=<escalated|already-top|fell-back> model=<model>[ reason=<reason>]`,
recorded in the sidecar; otherwise it prints nothing and writes nothing.
Show any output. Non-zero exit → show its stderr and stop.

<!-- tl:escalation-decide -->
```bash
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/models.sh" || { echo "throughline: cannot source models.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/run-record.sh" || { echo "throughline: cannot source run-record.sh" >&2; exit 1; }
: "${TL_REPO:?TL_REPO required}" "${TL_RUN:?TL_RUN required}" "${TL_SLUG:?TL_SLUG required}"
: "${TL_REQUESTED:?TL_REQUESTED required}" "${TL_AUTO:?TL_AUTO required}"
TL_PARENT="$(tl_parent_model 2>/dev/null)" || TL_PARENT=""
tl_rel="docs/tdd/$TL_SLUG.md"
tl_trigger="$(tl_escalation_decide "$TL_REPO" "$TL_RUN" "$TL_SLUG" "$tl_rel" "$TL_REQUESTED" "$TL_AUTO")" || exit 1
case "$tl_trigger" in
  requested|auto) ;;
  none) exit 0 ;;
  *) echo "throughline: unexpected escalation decision '$tl_trigger'" >&2; exit 1 ;;
esac
tl_out="$(tl_escalation_outcome "$TL_PARENT" "$TL_REPO/$tl_rel")" || exit 1
tl_outcome="${tl_out%% *}"; tl_rest="${tl_out#* }"; tl_model="${tl_rest%% *}"; tl_reason=""
case "$tl_rest" in *' '*) tl_reason="${tl_rest#* }" ;; esac
printf 'trigger=%s\n' "$tl_trigger"
tl_run_set_escalation "$TL_REPO" "$TL_RUN" "$TL_SLUG" "$tl_outcome" "$tl_model" ${tl_reason:+"$tl_reason"} || exit 1
```

Then run this block (input `TL_QUEUE`: every queued TDD path; also
export `TL_REPO` and `TL_RUN` so each TDD's sidecar escalation is shown
and applied — without them it shows no escalation). For
each TDD it prints the `models <slug>:` confirmation (the parent model,
the effort and its source, and each worker's model and source, plus an
`  escalation: <outcome> model=<model>` line when one was decided), then
any warning lines: a judgment slot pinned to the light tier, or an
ignored per-worker effort pin. Run it and show its output even when the
queue has one TDD: it is the operator's only cost signal before
dispatch (FR-87, NFR-3). Warnings do not stop the run. Non-zero exit →
show its stderr and stop.

<!-- tl:models-confirm -->
```bash
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/models.sh" || { echo "throughline: cannot source models.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/run-record.sh" || { echo "throughline: cannot source run-record.sh" >&2; exit 1; }
: "${TL_QUEUE:?TL_QUEUE required}"
TL_PARENT="$(tl_parent_model 2>/dev/null)" || TL_PARENT=""
while IFS= read -r tl_tdd; do
  [ -n "$tl_tdd" ] || continue
  [ -r "$tl_tdd" ] || { echo "throughline: queued TDD not readable: $tl_tdd" >&2; exit 1; }
  tl_slug="${tl_tdd##*/}"; tl_slug="${tl_slug%.md}"
  tl_esc=""; tl_escm=""
  if [ -n "${TL_REPO:-}" ] && [ -n "${TL_RUN:-}" ]; then
    tl_esc="$(tl_run_get_model_field "$TL_REPO" "$TL_RUN" "$tl_slug" escalation 2>/dev/null)" || tl_esc=""
    tl_escm="$(tl_run_get_model_field "$TL_REPO" "$TL_RUN" "$tl_slug" escalation_model 2>/dev/null)" || tl_escm=""
  fi
  tl_models_confirm "$tl_slug" "$tl_tdd" "$TL_PARENT" "$tl_escm" "$tl_esc" || exit 1
  tl_model_warnings "$tl_tdd" "$TL_PARENT" "$tl_escm" "$tl_esc" || exit 1
done <<<"$TL_QUEUE"
```

Then ask a structured question that shows that output verbatim. Modes:

- **sequential** (default) — stack `build/<run>/<slug>` on the previous
  TDD branch; one PR per TDD. Downstream `blocked` on halt (FR-16).
- **`--combined`** — one branch, one PR.
- **`--parallel`** — independent worktrees. A failure affects only that
  TDD.

## 6. Worktree (FR-20)

`git worktree add .worktrees/build-tdds-<slug>` from integration (or
previous sequential HEAD). Install deps unless `THROUGHLINE_SKIP_DEPS=1`.
Call the worktree path `WT`. `REPO` stays the human checkout.

## 7. Implementer worker

First run this block (inputs `TL_REPO`, `TL_RUN`, `TL_SLUG`, `TL_TDD`).
It records the TDD's models in the sidecar
`docs/tdd/.implement-logs/<run>/<slug>.models.json` (resolved on the
sidecar's `escalation_model` only when its `escalation` is `escalated`),
appends (and prints) `implementer model=<build> (src=<build_src>)` to the
per-TDD log `docs/tdd/.implement-logs/<run>/<slug>.log`, then prints one
`dispatch <worker> model=<arg>` line per worker. Non-zero exit → show
its stderr, unlock, **stop**.

<!-- tl:models-record -->
```bash
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/models.sh" || { echo "throughline: cannot source models.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/run-record.sh" || { echo "throughline: cannot source run-record.sh" >&2; exit 1; }
: "${TL_REPO:?TL_REPO required}" "${TL_RUN:?TL_RUN required}" "${TL_SLUG:?TL_SLUG required}" "${TL_TDD:?TL_TDD required}"
TL_PARENT="$(tl_parent_model 2>/dev/null)" || TL_PARENT=""
_tl_get() { tl_run_get_model_field "$TL_REPO" "$TL_RUN" "$TL_SLUG" "$1"; }
tl_escm=""
if [ "$(_tl_get escalation 2>/dev/null)" = escalated ]; then tl_escm="$(_tl_get escalation_model)" || exit 1; fi
tl_run_set_models "$TL_REPO" "$TL_RUN" "$TL_SLUG" "$TL_TDD" "$TL_PARENT" "$tl_escm" || exit 1
tl_b="$(_tl_get build)" && tl_bs="$(_tl_get build_src)" \
  && tl_r="$(_tl_get review)" && tl_v="$(_tl_get verify)" || exit 1
printf 'implementer model=%s (src=%s)\n' "$tl_b" "$tl_bs" \
  | tee -a "$TL_REPO/docs/tdd/.implement-logs/$TL_RUN/$TL_SLUG.log" || exit 1
printf 'dispatch implementer model=%s\n' "$(tl_dispatch_model_arg "$tl_b")"
printf 'dispatch reviewer model=%s\n' "$(tl_dispatch_model_arg "$tl_r")"
printf 'dispatch runtime-verify model=%s\n' "$(tl_dispatch_model_arg "$tl_v")"
```

**Dispatch rule (all three workers).** Model =
`tl_dispatch_model_arg <slot value>`, which the block prints as
`dispatch <worker> model=<arg>`. If that prints nothing (`model=` is
empty), dispatch the worker with **no model parameter** so it inherits
this session's model. Otherwise pass exactly that string. Never pass
`inherit` as a model.

**Escalation check (FR-88, ADR 0016)**, after each judgment worker
(implementer, reviewer, nontrivial runtime-verify) of a TDD whose sidecar
`escalation` is `escalated`. The outcome is judged by the model that
actually ran, not the one requested. Read `base-sha` =
`git -C "$WT" rev-parse HEAD` just before the implementer dispatch. Take
the first rule that matches:
1. **Transient error** (FR-41): a rate- or usage-limit pattern, or rc
   143/130 → `paused`, as for any worker. Exception: a refusal saying the
   escalation model itself is unavailable to this account
   (`credits_required`, `requires usage credits`) is not transient, even
   when it carries `rate_limit` / HTTP 429. It is a dispatch error (rule
   2); pausing would re-dispatch the same refused model on every resume.
2. **Dispatch error.** The dispatch tool returned an error, or the
   worker's completion notification reports it failed (an async worker's
   API error arrives there, not from the dispatch call):
   - run `tl_run_set_escalation "$REPO" "$run" "$slug" fell-back <model> "dispatch error: <first line of the error>"`
     and show the line it prints;
   - re-run the `tl:models-record` block (it now passes no escalation);
   - re-dispatch the same worker with **no model parameter**, on a fresh
     empty report.
3. **Otherwise**, run `tl_escalation_verify` through the block below
   (inputs `TL_REPO`, `TL_RUN`, `TL_SLUG`, `TL_AGENT_ID` = the worker's
   agent id from the dispatch tool result, `TL_REPORT` = its report path,
   `TL_WT`, `TL_BASE_SHA`, `TL_WORKER` = `implementer` | `verify` |
   `review`). It first runs `tl_escalation_fellback_check`; a
   `fell-back` there is the dispatch-error arm of rule 2. Its last line
   is the action:
   - `action=redispatch`: no report and no work. The fall-back is
     recorded; re-run the `tl:models-record` block and re-dispatch the
     worker with **no model parameter**, on a fresh empty report.
   - `action=keep`: another family answered (`harness ran <id>`) or the
     actual model could not be read (`actual model unverified (<why>)`).
     The fall-back is recorded and the worker's output is kept: the work
     is valid, only the record changes. Re-run the `tl:models-record`
     block so the TDD's later workers inherit.
   - `action=none`: the escalation held; the record is unchanged.
   - no output: the TDD is no longer `escalated`, so nothing is checked.

The outcome recorded last is final. Once the TDD has fallen back, its
inherited workers are never verified (the block prints nothing), so they
cannot overwrite that record. A fall-back is never detected by an
inactivity timeout. A check that passes with an empty report is a real
worker failure: apply the normal rules below. Non-zero exit → show its
stderr, unlock, **stop**.

<!-- tl:escalation-verify -->
```bash
_tl_src="${CLAUDE_PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-}}"
. "${_tl_src}/scripts/lib/plugin-root.sh" || { echo "throughline: cannot source plugin-root.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/models.sh" || { echo "throughline: cannot source models.sh" >&2; exit 1; }
. "$(tl_plugin_root)/scripts/lib/run-record.sh" || { echo "throughline: cannot source run-record.sh" >&2; exit 1; }
: "${TL_REPO:?TL_REPO required}" "${TL_RUN:?TL_RUN required}" "${TL_SLUG:?TL_SLUG required}"
: "${TL_AGENT_ID:?TL_AGENT_ID required}" "${TL_REPORT:?TL_REPORT required}" "${TL_WT:?TL_WT required}"
: "${TL_BASE_SHA:?TL_BASE_SHA required}" "${TL_WORKER:?TL_WORKER required}"
_tl_get() { tl_run_get_model_field "$TL_REPO" "$TL_RUN" "$TL_SLUG" "$1"; }
[ "$(_tl_get escalation 2>/dev/null)" = escalated ] || exit 0
tl_m="$(_tl_get escalation_model)" && [ -n "$tl_m" ] || { echo "throughline: no escalation_model for $TL_SLUG" >&2; exit 1; }
tl_chk="$(tl_escalation_fellback_check "$TL_REPORT" "$TL_WT" "$TL_BASE_SHA" "$TL_WORKER")" || exit 1
case "$tl_chk" in
  'fell-back '*)
    tl_run_set_escalation "$TL_REPO" "$TL_RUN" "$TL_SLUG" fell-back "$tl_m" "${tl_chk#fell-back }" || exit 1
    echo 'action=redispatch'; exit 0 ;;
  ok) ;;
  *) echo "throughline: unexpected fall-back check '$tl_chk'" >&2; exit 1 ;;
esac
tl_v="$(tl_escalation_verify "$TL_AGENT_ID" "$tl_m")" || exit 1
case "$tl_v" in
  escalated) echo 'action=none' ;;
  'fell-back '*)
    tl_run_set_escalation "$TL_REPO" "$TL_RUN" "$TL_SLUG" fell-back "$tl_m" "${tl_v#fell-back }" || exit 1
    echo 'action=keep' ;;
  *) echo "throughline: unexpected escalation verdict '$tl_v'" >&2; exit 1 ;;
esac
```

Dispatch **one** implementer worker. It **must not spawn children**.

- Working directory = `$WT`.
- Model = the `dispatch implementer` line (dispatch rule above).
- Prompt: read the TDD + cited PRD FRs + accepted ADRs. Follow
  test-driven-development if that skill is present. Commit on the build
  branch. Do not flip Status. Do not open a PR.
- Parent creates the empty report `<run-dir>/<slug>.build.txt` and
  passes its path. The last line matching `^BUILD_RESULT: (OK|BLOCKED)$`
  is authoritative.

`BLOCKED` → append `docs/tdd/BLOCKERS.md` (FR-17),
`tl_run_set_tdd "$REPO" "$run" "$slug" blocked design-escalation`,
unlock, **stop**.

If worker exit or stderr matches `rate.?limit|usage.?limit|ECONNRESET`
(or rc 143/130) → `tl_run_set_tdd … paused <cause>`, unlock, **stop**
(FR-41). Genuine non-zero without that pattern → `failed` + `gate-fail`,
unlock, **stop**.

Continue only on `BUILD_RESULT: OK`.

## 8. Mechanical gates

Run in `$WT`; write verdicts against `"$REPO"`.

8a. `tl_test_first_observe "$WT"` → `tl_verdict_write "$REPO" "$run"
"$slug" test-first` (`PASS` iff observe rc 0, else `FAIL`). FAIL →
`tl_run_set_tdd … failed gate-fail`, unlock, **stop**.

8b. `bash "$(tl_plugin_root)/scripts/ci-checks.sh"` in `$WT`, with its
stdout and stderr saved to `<run-dir>/<slug>.ci-checks.txt`. Transient
retry (FR-42): re-run up to `THROUGHLINE_TRANSIENT_RETRY` (default 2) if
rc is 143/130 or stderr matches `rate.?limit|usage.?limit|ECONNRESET`.
After retries exhaust on a transient pattern → `paused` (never
`failed`), unlock, **stop**. Non-transient non-zero → write `ci-checks`
`FAIL`, `failed` + `gate-fail`, unlock, **stop**. rc 0 → write
`ci-checks` `PASS`.

## 9. Runtime-verify worker

Dispatch **one** runtime-verify worker (different process/context).
**must not spawn children.** Model = the `dispatch runtime-verify` line
from step 7 (dispatch rule). That slot is resolved from the TDD path
(`tl_resolve_models <tdd-path> <parent>`, not the plan text) and
recorded as the sidecar `verify` / `verify_class` keys. Before dispatch,
append `runtime-verify model=<verify> (plan=<verify_class>)` to the
per-TDD log (FR-52), with both values from the sidecar.

Parent creates the empty report `<run-dir>/<slug>.verify.txt` and
passes its path. Worker drives the TDD verification plan and writes a last line
`^VERIFY_RESULT: (PASS|FAIL|BLOCKED|SKIP)$`. `SKIP` requires a following
`EVIDENCE: <non-empty>` line. Missing token → FAIL. Transient stderr/rc
→ `paused` (FR-41), do not write FAIL. For a nontrivial verify of an
`escalated` TDD, apply the step 7 escalation check first
(`TL_WORKER=verify`).

Parent then `tl_verdict_write "$REPO" "$run" "$slug" runtime-verify`.
FAIL or BLOCKED → halt (`failed`/`blocked`), unlock, **stop**. PASS or
SKIP (with evidence) → continue.

## 10. Reviewer worker

Dispatch **one** reviewer worker. Model = the `dispatch reviewer` line
from step 7 (dispatch rule): the `review=` slot, the implementer's
judgment model unless pinned (FR-15(d)); independence is the fresh
worker. Before dispatch, append
`reviewer model=<review> (src=<review_src>)` to the per-TDD log, with
both values from the sidecar. Read-only. **must not spawn children.**

Inputs: TDD path, `git diff` of the build branch vs integration,
optional `agents/security-reviewer.md` if that file exists.

Parent creates the empty report `<run-dir>/<slug>.review.txt` and
passes its path. Accept the token only as a whole line `^REVIEW_RESULT: (PASS|FAIL)$` (last matching
line wins — not a mid-prose scrape). No such line → FAIL.
For an `escalated` TDD, apply the step 7 escalation check first
(`TL_WORKER=review`).

Parent writes `review.json` via `tl_verdict_write`. FAIL → halt, unlock,
**stop**. PASS → continue.

## 11. Flip + PR (never merge)

`tl_verdict_require_flip "$REPO" "$run" "$slug"` must be 0. Then:

- Flip TDD `Status: implemented` on the **build branch** (not
  integration).
- `gh pr create` (never merge) (NFR-1).
- Write the FR-19 report under the run dir.
- Create `docs/tdd/.implement-logs/.first-flip-done` (empty marker) on
  the first successful flip (FR-84).
- `tl_run_set_tdd "$REPO" "$run" "$slug" done`
- `tl_run_set_pr "$REPO" "$run" "$slug" "<url>"`
- Unlock.

## Halt rule (ADR 0013 / FR-16)

After every terminal outcome: continue to the next step only on
implementer `BUILD_RESULT: OK`; `test-first` PASS; `ci-checks` PASS;
`runtime-verify` PASS or SKIP; `review` PASS. Otherwise:
`tl_run_set_tdd` to `paused` (transient class after FR-42 exhaust:
`ratelimit` / `usage-limit` / `transient`), `blocked`
(`BUILD_RESULT: BLOCKED`, FR-67 `structural-finding`, FR-17
`design-escalation` / `external-blocker`), or `failed` (`gate-fail` for
a non-transient FAIL); unlock; **stop**. Do not dispatch later workers.
In sequential mode, remaining queued TDDs become `blocked`.

After every `tl_run_set_tdd … failed gate-fail`, record the halt-time
TDD blob for FR-88 auto escalation:
`tl_run_set_halt_blob "$REPO" "$run" "$slug" "docs/tdd/<slug>.md"`. If
it fails, show its stderr; the halt still completes, and auto
escalation is then unavailable for that TDD (`--escalate` still works).

## Notes

- Progress snapshot is `/implement-status` (TDD 0063). This skill does
  not render it.
- Integration branch: origin default → `main` → `master`; override
  `THROUGHLINE_INTEGRATION_BRANCH`.
- Models (ADR 0015): judgment workers inherit this session's model
  (dispatched with no model parameter) and run at the session effort;
  mechanical runtime-verify uses the light binding in
  `scripts/lib/models.sh`, never above the parent. Pins, as harness
  model aliases: `THROUGHLINE_BUILD_MODEL`, `THROUGHLINE_REVIEW_MODEL`,
  `THROUGHLINE_RUNTIME_VERIFY_MODEL`, and `CLAUDE_CODE_SUBAGENT_MODEL`
  (every worker dispatched without a model parameter). A judgment slot
  pinned to the light tier warns and continues. `THROUGHLINE_BUILD_EFFORT`, `THROUGHLINE_REVIEW_EFFORT` and
  `THROUGHLINE_RUNTIME_VERIFY_EFFORT` are reported as ignored: there is
  no per-worker effort. Record:
  `docs/tdd/.implement-logs/<run>/<slug>.models.json`.
- Escalation (FR-88, ADR 0015): only `/build-tdds` escalates, per TDD,
  all unpinned judgment slots together, to `tl_escalation_model`
  (override `THROUGHLINE_ESCALATION_MODEL`). Triggers: `--escalate` /
  `THROUGHLINE_ESCALATE=1`, or auto on a Retry whose halt has a gate
  `FAIL` verdict with the TDD unchanged on the integration branch
  (declined by `--no-auto-escalate` / `THROUGHLINE_AUTO_ESCALATE=0`).
  Outcomes `escalated` / `already-top` / `fell-back`, one line each,
  recorded in the sidecar. Effort is unchanged by escalation. ADR 0016:
  the outcome is judged by the model that actually ran (the worker's
  transcript, `tl_escalation_verify`); an unreadable actual model counts
  as `fell-back`.
- Sequential stacked PRs: merge bottom-up; enable auto-delete of head
  branches so GitHub retargets. Or use `--combined`.

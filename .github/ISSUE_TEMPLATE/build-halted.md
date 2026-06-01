---
name: Build halted / failed
about: An /implement run halted, failed a gate, or wedged
title: "[halt] "
labels: build-halt
assignees: ''
---

## What happened

<!-- One or two sentences: which TDD was building, what you expected, what you got. -->

## Halt context

Paste the output of `/implement-status` (or `bash <plugin>/scripts/status.sh`):

```
(paste here)
```

## Run-state record

Attach or paste the per-TDD fragment for the halted TDD (sanitize anything private):

`docs/tdd/.implement-logs/<ts>/state.d/<slug>.json`

```json
(paste here)
```

## Gate log tail

The last ~30 lines of the per-TDD log
(`docs/tdd/.implement-logs/<ts>/<slug>.log`), especially any
`THROUGHLINE_*`, `STEP_REVIEW:`, `BATCH_RESULT:`, or `VERIFY_RUNTIME:` lines:

```
(paste here)
```

## Environment

- throughline version (from `.claude-plugin/plugin.json` or `claude plugin list`):
- Claude Code version (`claude --version`):
- OS / shell:
- Build model / review model (if overridden from defaults):

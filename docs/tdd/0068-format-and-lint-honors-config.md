# TDD 0068: format-and-lint honors the repo's configuration (FR-21, issue #180)

Status: implemented
PRD refs: FR-21, FR-1, FR-2, NFR-4
PRD-rev: f6ef178
ADR constraints: 0004, 0005, 0006, 0010
Supersedes: 0001 (the `format-and-lint` hook component only; 0001's bootstrap design stands)

## Approach
FR-21 says the hook formats then lints edited files "when a linter is
configured (no-op otherwise)" and that failures are "surfaced into the
session for root-cause fixing". TDD 0001 says "no configured linter →
no-op". The shipped hook does neither (issue #180). Reproduced on 3.49.0
with ruff 0.16.10:
- a lint-only ruff config caused a whole-file reformat;
- with no config, `--fix` deleted imports mid-edit;
- a blocking exit 2 put the diagnostics on stdout, so the agent saw only
  a one-line summary.

JS/TS, Rust and Go have the same class of problem.

Rules, for every language:
1. **Discovery starts from the edited file.** It walks up from the file's
   directory to the file's git toplevel, or to `/` when the file isn't in
   a repo. It never starts from `$PWD`.
2. **Lint only when a linter is configured, and report only.** No
   `--fix`. Diagnostics go to **stderr** on failure, with exit 2.
3. **Format only on opt-in.**
   - Python and JS/TS need an explicit formatter config.
   - Rust and Go use the language convention, but only where it can't
     re-create #180: the file is in a git repo, and its committed version
     is already formatter-clean (or the file is new to git).
   - Rust is formatted through stdin, so `rustfmt` never touches child
     modules.
4. **A missing tool or config means exit 0 and nothing written.** The
   exception is a missing jq/python3, which is still a loud exit 2,
   because the hook then can't read its input.

`/bootstrap-project` writes the formatter opt-in on **every** path that
creates a formatter config. The README tells already-bootstrapped Python
repos to add `[tool.ruff.format]`.

## Components & interfaces
`hooks/format-and-lint.sh`. Stdin parsing via jq → python3 is unchanged.
Internal helpers:

- **`_tl_stop_dir <dir>`** prints `git -C <dir> rev-parse --show-toplevel`,
  or `/`.
- **`_tl_find_up <dir> <test-fn>`** walks from `<dir>` up to the stop dir,
  inclusive. It prints the first directory where `<test-fn> <d>` returns
  0, with rc 0. If none match, it prints nothing and returns rc 1.
- **`_tl_json_has_key <package.json> <key>`** tests for a **top-level**
  key: jq `has($k)`, falling back to python3 `k in json.load(f)`. Missing
  file, parse error, or no parser → rc 1. A key that appears only inside
  `devDependencies` does not count.
- **`_tl_local_bin <dir> <tool>`** prints the first
  `node_modules/.bin/<tool>` found walking up from `<dir>`, or returns
  rc 1. This replaces the `npx --no-install … --version` probes: no extra
  process per edit.
- **`_tl_git_state <file>`** prints one of three states:
  - `outside` — not in a git work tree;
  - `new` — in a work tree, but `git cat-file -e HEAD:<rel>` fails. This
    covers untracked, intent-to-add, and unborn-HEAD files.
  - `tracked` — `HEAD:<rel>` exists.

  `<rel>` = `git -C <file dir> rev-parse --show-prefix` + basename, so a
  symlinked directory path cannot mislead it.
- **`_tl_head_clean <file> <check-cmd…>`** returns rc 0 iff
  `_tl_git_state` is `tracked`, and the command — run as
  `git show HEAD:<rel> | (cd <file dir> && <check-cmd>)` — exits 0 with
  **empty stdout**. Any error counts as not-clean.

**Python (`.py`)**
- No ruff on `PATH` → exit 0.
- **Config is per directory, in ruff's precedence:** `ruff.toml`, else
  `.ruff.toml`, else a `pyproject.toml` containing a line matching
  `^\[tool\.ruff[.\]]`, which excludes look-alikes such as
  `[tool.ruffle]`. The first directory upward that has one wins, and the
  chosen file is the only one inspected. A format-only config counts as
  lint-configured too (ruff's default rules), as ruff itself would. No config → exit 0.
- **Format opt-in:** the chosen `pyproject.toml` has `^\[tool\.ruff\.format\]`,
  or the chosen `ruff.toml` / `.ruff.toml` has `^\[format\]`.
  - Then run `ruff format <file>`, output discarded.
  - Dotted top-level forms (`format.quote-style = …`) and `extend =`
    inheritance are not recognised. That fails safe: no formatting.
- **Lint:** `ruff check --no-fix --output-format concise <file> 1>&2`.
  - rc ≠ 0 → exit 2. stderr ends with
    `format-and-lint: ruff reported errors in <file> (diagnostics above). Fix the root cause; do not suppress.`

**JS/TS (`.js .jsx .ts .tsx .mjs .cjs`)**
- **Prettier config:** the first directory upward with `.prettierrc` or
  `.prettierrc.*`, `prettier.config.*`, or a `package.json` where
  `_tl_json_has_key … prettier` is true.
  - If found **and** `_tl_local_bin <that dir> prettier` resolves, run
    `(cd <that dir> && <bin> --write <file>)`, output discarded.
- **ESLint config:** the first directory upward with `eslint.config.*` or
  `.eslintrc*`, or a `package.json` where `_tl_json_has_key … eslintConfig`
  is true.
  - If found **and** `_tl_local_bin <that dir> eslint` resolves, run
    `(cd <that dir> && <bin> <file>) 1>&2`, without `--fix`.
  - rc ≠ 0 → exit 2 with the trailing line, naming eslint.
- A config without the tool installed → no-op. Today that case blocks
  every edit.

**Rust (`.rs`)** — the root is the first directory upward with
`Cargo.toml`. No root → exit 0.
- **Format** requires `rustfmt` on `PATH` and `_tl_git_state` ≠
  `outside`. It runs when the state is `new`, or when
  `_tl_head_clean <file> rustfmt --edition <E> --check` passes.
  1. Run `(cd <file dir> && rustfmt --edition <E> < <file> > <tmp>)`.
  2. If rustfmt exits 0 and `<tmp>` differs from the file, write it back
     with `cat <tmp> > <file>`. This keeps the file's mode and inode.
     Skip formatting entirely when the file is a symlink (`-L`).

  Stdin mode never recurses into `mod` children, and running in the
  file's directory makes `rustfmt.toml` discovery match the file.
  - `<E>` is the root `Cargo.toml`'s `edition = "…"`, default `2021`.
  - `edition.workspace = true` falls back to `2021`. If the style
    differs, `_tl_head_clean` fails and nothing is formatted: it fails
    safe.
- **Lint:** if `cargo` is on `PATH` and the debounce allows, run
  `(cd <root> && cargo clippy --quiet) 1>&2`. rc ≠ 0 → exit 2.

**Go (`.go`)** — the root is the first directory upward with `go.mod`. No
root → exit 0.
- **Format** requires `gofmt` on `PATH` and a state ≠ `outside`. It runs
  when the state is `new`, or when `_tl_head_clean <file> gofmt -l`
  passes. Then run `gofmt -w <file>`, which formats one file only.
  `gofmt -l` reads stdin, exits 0 either way, and prints
  `<standard input>` when unformatted. That is why "clean" means empty
  stdout.
- **Lint** requires `golangci-lint` on `PATH`, a `.golangci.{yml,yaml,toml,json}`
  in the **root or above** (where golangci-lint looks when run from the
  root), and the debounce. Run
  `(cd <root> && golangci-lint run ./<reldir>/...) 1>&2`, where
  `<reldir>` is `.` for the root, which gives `./...`. rc ≠ 0 → exit 2.

**Debounce:** the window and env var are unchanged
(`THROUGHLINE_LINT_DEBOUNCE`, 30s). It is now keyed by the project root,
not `$PWD`.

**`skills/bootstrap-project/SKILL.md`** — the rule applies to **every**
path that writes a formatter config: greenfield, and brownfield "add the
default".
- **Python** `pyproject.toml` gets `[tool.ruff]`, `[tool.ruff.lint]` and
  `[tool.ruff.format]`.
- **JS/TS** gets a `.prettierrc` and an `eslint.config.*`.
- **Rust/Go:** no config is needed.
- The prose describes the hook as: explicit opt-in for Python/JS,
  HEAD-clean convention for Rust/Go, never auto-fix.

**`README.md`** — the hook paragraph, plus an upgrade note: Python repos
bootstrapped before 3.50.0 have lint-only ruff config, so add
`[tool.ruff.format]` to keep formatting.

## Data & state
No new files. The debounce marker is keyed by the project root. Rust
formatting writes a temp file and copies it back with `cat`, which
preserves the file's mode.

## Sequencing / implementation plan
1. `tests/format-and-lint-hook.test.sh` with stub tools, registered in
   `tests/implement-gate.test.sh`.
2. Rewrite `hooks/format-and-lint.sh`: the helpers, then the four
   branches.
3. `skills/bootstrap-project/SKILL.md` (all formatter-writing paths) and
   `README.md` (paragraph and upgrade note).

## Failure modes & edge cases
**Real risks**
- **Previously bootstrapped Python repos stop formatting.** This is the
  issue's own principle (lint config ≠ format opt-in). The README upgrade
  note says how to opt in, and newly bootstrapped repos are covered.
- **Real-tool behaviour could differ from the stubs.** The runtime-verify
  gate installs ruff, gofmt and rustfmt into a scratch directory and runs
  real controls (observation 13). If the install fails, the gate reports
  BLOCKED, never PASS.
- **A Cargo/Go project outside git is never formatted.** There is no HEAD
  to prove the file was clean. This is the safe side of #180.

**Overblown risks**
- **Cost of the extra `git show`.** It adds milliseconds per Rust/Go
  edit, and only when the formatter is installed.
- **Nested projects.** The nearest config wins, which is ruff's own rule.

**Unspoken risks**
- **Lint output now reaches the agent in full.** A large clippy run can
  flood the session. That is the linter's real output; clippy and
  golangci-lint stay debounced.
- **ESLint flat configs are detected by presence only.** A config that
  ignores the file exits 0, which is correct.

## Verification plan
- **Surface:**
  - the hook's rc, stdout and stderr;
  - the edited file's bytes;
  - a call log written by the stub tools.
- **Harness:**
  - Each case runs in a temp git repo, cleaned up by a trap (L-004).
  - The hook gets `{"tool_input":{"file_path":"<abs>"}}` on stdin and
    runs as
    `env -i HOME=<tmp> PATH=<stubdir>:/usr/bin:/bin bash hooks/format-and-lint.sh`,
    started from a directory **unrelated** to the file.
  - Stubs log their argv and cwd to `<tmp>/calls`:
    - `ruff` and `rustfmt` act as formatters and rewrite the file, or
      stdout, to a marker;
    - lint stubs print `STUB-DIAG` to stdout and exit 1 when the file
      contains `BAD`;
    - `gofmt -l` copies real gofmt: rc 0, and prints `<standard input>`
      when its stdin contains `UNCLEAN`;
    - `rustfmt --check` prints a diff and exits 1 on `UNCLEAN`.
  - JS tools are stubbed as `node_modules/.bin/{prettier,eslint}`.
- **Observation points → expected (PASS):**
  1. **No config, Python** → rc 0; `calls` is empty; the file is
     byte-identical; stdout and stderr are empty.
  2. **`[tool.ruff]` plus `[tool.ruff.lint]` only** → only
     `check --no-fix --output-format concise <file>`; the file is
     unchanged; rc 0.
  3. **`[tool.ruff.format]` present** → `format`, then
     `check --no-fix …`; the file is rewritten.
  4. **`ruff.toml` with `[format]` next to a `pyproject.toml` with no
     format section** → formats, because `ruff.toml` wins. The reverse
     (`pyproject.toml` with format plus a `ruff.toml` without it) → no
     format.
  5. **Configured, file contains `BAD`** → rc 2; stderr contains
     `STUB-DIAG` and `(diagnostics above)`; stdout is empty.
  6. **No `--fix`** in `calls` across every case, after asserting `calls`
     is readable.
  7. **JS:**
     - no config → no calls;
     - `.prettierrc` with a local bin → `prettier --write` from the config
       dir;
     - a `package.json` with prettier only in `devDependencies` and no
       config → **no** prettier call;
     - `"prettier": {}` at the top level → a call;
     - an `eslint.config.js` with the bin → `eslint <file>`, no `--fix`;
     - a config without a local bin → rc 0, no call.
  8. **Config above `$PWD`.** The config sits next to the file, and the
     hook runs from an unrelated cwd → still detected (as in case 3).
  9. **Rust:**
     - in `Cargo.toml` + git, a clean tracked `.rs` file → rustfmt
       invoked as stdin mode with `--edition 2021`, cwd = the file's dir;
     - HEAD `UNCLEAN` → no write;
     - a new (untracked) file → formatted;
     - outside git → no rustfmt;
     - a `lib.rs` edit leaves a child `foo.rs` byte-identical;
     - no `Cargo.toml` → no calls.
  10. **Go:**
      - a clean tracked file → `gofmt -w`;
      - HEAD `UNCLEAN` (stub rc 0 plus stdout) → **no** `gofmt -w`,
        proving the guard reads stdout, not rc;
      - no `.golangci.*` → no golangci-lint call;
      - a `.golangci.yml` at the module root → called with `./...` from
        the root;
      - a config only in a subdirectory → not called.
  11. **Bootstrap** (text check; the reason is that it is skill prose an
      eval can't execute): `skills/bootstrap-project/SKILL.md` names
      `[tool.ruff.format]` in both the greenfield and brownfield-add
      paths, with the file asserted readable first.
  12. **Regression:**
      - a fully configured repo (ruff format and lint, prettier and
        eslint) still formats and lints, minus `--fix`;
      - with jq and python3 hidden → rc 2 and the existing "need jq or
        python3" message.
  13. **Real tools** (runtime-verify gate only). The worker installs
      ruff (venv), gofmt (Go tarball) and rustfmt (standalone) into the
      scratchpad; if any install fails → BLOCKED. Then:
      - issue #180 controls with real ruff:
        - `[tool.ruff.format]` with `x=1` → `x = 1`;
        - lint-only (case A) → unchanged, rc 0;
        - no config (cases B and C) → unchanged, imports kept, rc 0;
      - real gofmt:
        - a dirty-HEAD tracked file → untouched;
        - a clean-HEAD file with a new unformatted line → formatted;
      - real rustfmt:
        - the same two cases;
        - plus a `lib.rs` edit leaving a dirty child module untouched.
- Every negated check first asserts that its input exists and is
  non-empty (L-001, L-011).

## Evaluation rubric
| Criterion | High-quality | Acceptable | Failing |
|---|---|---|---|
| requirement traceability | FR-21, FR-18, FR-43, FR-88, FR-41 each map to a named function, hook branch, or skill block | One mapping indirect but named | An in-scope requirement missing |
| interface concreteness | Every new helper (config discovery, tl_session_pid, lock fields, reason block) has args, stdout, rc pinned | One error return implicit | A reader cannot tell what a helper prints or returns |
| executable verification | Hook run via stdin in temp repos with stub tools and real ruff when present; skill blocks extracted and run; negated checks fail closed (L-001/L-011) | One check text-only with stated reason | A behaviour asserted only by grepping text |
| alternatives-analysis substance | Each mechanism names >=1 rejected alternative with reason (PWD discovery, any-ruff-config opt-in, --fix, $PPID lock, env-var reason) | One rejection thin | None |
| verification-plan actionability | Surface, observation points, PASS values named, incl. issue #180 three control cases | One fixture underspecified | Missing or non-actionable |
| scope-bound adherence | Each TDD <=8 files, <=500 body lines; estimates padded; exceptions declared | One justified exception | Over a bound with no exception |
| regression safety | Repos that DID configure tools format/lint as before; a live lock still refuses; existing evals stay green | One regression case only implied | A previously-working configured path is untested or broken |

## Requirement traceability
| Requirement | Design element |
|---|---|
| FR-21 lint only when configured | per-language config discovery; obs 1, 2, 7, 10 |
| FR-21 no-op otherwise | missing tool/config → exit 0, no calls; obs 1, 7, 9 |
| FR-21 failures surfaced for root-cause fixing | stderr diagnostics, exit 2, no `--fix`; obs 5, 6 |
| FR-21 formats then lints | explicit opt-in (py/js); HEAD-clean convention via stdin (rs/go); obs 3, 4, 9, 10, 13 |
| FR-21 debounced | keyed by project root |
| FR-1 / FR-2 bootstrap configures tooling | every formatter-writing path includes the opt-in; obs 11; README upgrade note |
| NFR-4 honest failure | the agent sees the real diagnostics; a missing parser is still loud; real-tool controls or BLOCKED |

## Dependencies considered
No new dependencies.

Rejected:
- **Config discovery from `$PWD`.** That is today's bug.
- **Any ruff config as a format opt-in.** Issue case A.
- **Keeping `--fix`.** It deletes code mid-edit (case B), and FR-21 says
  failures are surfaced for root-cause fixing.
- **A substring grep of `package.json`.** It matches `devDependencies`,
  which would re-create #180.
- **`npx --no-install <tool> --version` probes.** They add one process
  per edit, and `npx` can't tell "missing" from "lint failed". A local
  `node_modules/.bin` lookup is free.
- **`rustfmt <file>`.** It recurses into child modules, so it formats
  lines the agent never touched. Stdin mode doesn't.
- **Formatting Rust/Go outside git.** There is no evidence the file was
  clean, so it is skipped.

## PRD conflicts surfaced (and resolution)
None. The design brings the hook back to FR-21's existing wording;
issue #180 is the trigger. Repos bootstrapped before this change lose
automatic Python formatting. They get an upgrade note rather than a
silent opt-in, because a lint-only config is not a format opt-in.

## Decisions to promote (ADR candidates)
None. This corrects the implementation to match an existing requirement.

## Touched files
- `hooks/format-and-lint.sh` — config discovery from the edited file, opt-in formatting, report-only lint to stderr
- `tests/format-and-lint-hook.test.sh` — stub-tool eval of every branch
- `tests/implement-gate.test.sh` — register the new eval
- `skills/bootstrap-project/SKILL.md` — every formatter-writing path includes the opt-in; hook prose
- `README.md` — hook paragraph and upgrade note

## Expected diff size
- `hooks/format-and-lint.sh` — 240 lines
- `tests/format-and-lint-hook.test.sh` — 420 lines (exception: one cohesive stub-tool eval over four languages and 12 observation points)
- `tests/implement-gate.test.sh` — 12 lines
- `skills/bootstrap-project/SKILL.md` — 30 lines
- `README.md` — 20 lines
Total expected diff: 722 lines across 5 files.

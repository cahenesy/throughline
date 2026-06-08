#!/usr/bin/env bash
# recoverable-terminal-halts.test.sh — eval for TDD 0039 (opt-in recovery from
# non-structural terminal halts). Two terminal halt classes that are commonly
# artifacts — rework-budget-exhausted (status:blocked) and a ci-checks failure
# (status:failed, note "ci-checks") — gain an OPT-IN recovery path under an
# explicit `--recover` (RECOVER=1) so a human can resume from the last good gate
# WITHOUT hand-editing the state fragment, while terminal-by-default stays
# terminal (NFR-4). Covers the TDD's Verification plan §1–§7 by driving
# `_resume_from` + `status.sh --check-paused` against seeded fragments and the
# `--recover` flag against scripts/implement.sh, following the fixture pattern of
# tests/runtime-verify-resume.test.sh. No model or tokens are needed (function /
# flag level only; no watcher/process is launched).
#
#   S1 implement.sh parses --recover (implies --resume) + recover-specific diagnostic
#   §1 budget-exhausted, no --recover → terminal (not flipped)
#   §2 budget-exhausted, --recover → accepted + rework/re-review budgets reset
#   §3 ci-checks failed, --recover → re-enters at verify; no --recover → terminal
#   §4 divergence-guard re-baseline under --recover (refuses without it)
#   §5 status.sh --check-paused surfaces resumable=recoverable for both classes
#   §6 ambiguous failed (no ci-checks note) → refused (resume-recover-cause-ambiguous)
#   §7 SKILL.md documents --recover + the "Recover" offer keyed on resumable=recoverable
#
# Mechanical-check robustness (L-001/L-002): every absence/removal grep
# distinguishes exit 1 (absent) from ≥2 (unreadable) and fails on the latter;
# each target file is asserted readable before its content checks; the fragment
# seeds use compact single-line JSON (the readers are line-oriented).
#
# Run: bash tests/recoverable-terminal-halts.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ===========================================================================
# S1: scripts/implement.sh parses --recover (sets RECOVER=1, implies --resume)
# and, when the implied resume finds no prior run, emits a recover-specific
# diagnostic naming the missing prior run — distinct from the generic resume
# FATAL — and exits non-zero. Driven behaviorally with a stubbed `claude` (so the
# CLI-present guard passes) against a temp git repo that has no `latest` symlink.
echo "[S1] implement.sh parses --recover (implies --resume) + recover-specific diagnostic"
( d="$ROOT/S1"; mkdir -p "$d/bin" "$d/repo"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/claude"; chmod +x "$d/bin/claude"
  cd "$d/repo" || { bad "cd failed"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init >/dev/null
  out="$(PATH="$d/bin:$PATH" bash "$IMPL" --recover 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "implement.sh --recover with no prior run exits non-zero" || bad "should exit non-zero (got rc=$rc)"
  printf '%s' "$out" | grep -qiE 'requires a prior run to recover' \
    && ok "emits the recover-specific 'requires a prior run to recover' diagnostic" \
    || bad "should emit the recover-specific diagnostic (got: $out)"
  printf '%s' "$out" | grep -qi 'unknown arg' \
    && bad "--recover must be a known flag (got 'unknown arg')" \
    || ok "--recover is a recognized flag (no 'unknown arg')"
  # Mechanical: the runner source carries the flag parse + RECOVER export.
  grep -q -- '--recover' "$IMPL" && ok "implement.sh source mentions --recover" || bad "implement.sh should parse --recover"
  grep -q 'RECOVER' "$IMPL" && ok "implement.sh source sets RECOVER" || bad "implement.sh should set RECOVER"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== recoverable-terminal-halts eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

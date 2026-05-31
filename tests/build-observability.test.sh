#!/usr/bin/env bash
# build-observability.test.sh — eval for TDD 0010 / FR-36..38 (build
# observability & safety boundaries).
#
# This suite is a CHARACTERIZATION eval over already-landed behavior, not a
# red-first eval for new code (TDD 0010 is a tests + design-pointer TDD; the
# runtime artifacts landed in commit 72192b9 and were extracted into
# scripts/lib/pause-retry.sh by TDD 0016). Each case exercises the existing
# implementation and is expected to pass green on the first commit — which is
# exactly why the build emits `TEST_FIRST: SKIPPED no-new-behavior` per
# FR-15(a). The value is regression-pinning: it locks the FR-36 gate-log
# session pointer and the FR-37/FR-38 prompt boundaries against silent drift.
#
# Cases (one ok/fail line each):
#   1. record_session_pointer with a fixture JSONL in the cwd-encoded project
#      dir writes the expected THROUGHLINE_SESSION: <path> line (FR-36).
#   2. record_session_pointer with no encoded project dir is a silent no-op:
#      the log is byte-identical before/after and exit status is 0 (FR-36).
#   3. record_session_pointer with `jq` off PATH writes only the pointer line,
#      no tool-call tail (FR-36 graceful degradation).
#   4. record_session_pointer with two JSONLs (one older than `start`, one
#      newer) selects the newer one (FR-36 newest-since-start).
#   5. scripts/build-prompt.md carries the "Build-phase boundaries" heading and
#      the three prohibition keywords nested / pkill / /tmp (FR-37).
#   6. scripts/verify-runtime-prompt.md carries "Cleanup safety" + pkill (FR-38).
#
# Run: bash tests/build-observability.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PR="$REPO/scripts/lib/pause-retry.sh"
BUILD_PROMPT="$REPO/scripts/build-prompt.md"
VERIFY_PROMPT="$REPO/scripts/verify-runtime-prompt.md"
FIXTURE="$REPO/tests/fixtures/build-observability/session.jsonl"

RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# record_session_pointer resolves the session JSONL from $HOME + $PWD via Claude
# Code's project-dir encoding (/a/b -> ~/.claude/projects/-a-b/). We source the
# real helper (top-level only declares functions) and drive it under a
# controlled HOME + cwd whose encoded project dir we populate from the committed
# fixture. `start` is set a few seconds in the past so a freshly-copied fixture
# (mtime ~now) is "at or after" it, matching the live call's capture order.
# shellcheck source=../scripts/lib/pause-retry.sh
. "$PR"

# enc <abs-cwd> -> the Claude-Code-encoded project dir name (slashes -> dashes).
enc() { printf '%s' "$1" | sed 's|/|-|g'; }

echo "[1] record_session_pointer writes the pointer line for a fresh session JSONL"
( home="$ROOT/c1home"; work="$ROOT/c1work"; mkdir -p "$work"
  proj="$home/.claude/projects/$(enc "$work")"; mkdir -p "$proj"
  cp "$FIXTURE" "$proj/session.jsonl"
  log="$ROOT/c1.log"; : >"$log"
  start=$(( $(date +%s) - 5 ))
  ( cd "$work" && HOME="$home" record_session_pointer "$log" "$start" )
  if grep -q "^THROUGHLINE_SESSION: $proj/session.jsonl\$" "$log"; then
    ok "pointer line names the cwd-encoded session JSONL"
  else
    bad "expected 'THROUGHLINE_SESSION: $proj/session.jsonl' in log; got: $(cat "$log")"
  fi
) || true

echo "[2] record_session_pointer is a silent no-op when no encoded project dir exists"
( home="$ROOT/c2home"; work="$ROOT/c2work"; mkdir -p "$work"
  # Deliberately do NOT create $home/.claude/projects/<enc> — nothing to find.
  log="$ROOT/c2.log"; printf 'preexisting log content\n' >"$log"
  start=$(( $(date +%s) - 5 ))
  before="$(cksum <"$log")"
  ( cd "$work" && HOME="$home" record_session_pointer "$log" "$start" ); rc=$?
  after="$(cksum <"$log")"
  if [ "$rc" -eq 0 ] && [ "$before" = "$after" ]; then
    ok "log byte-identical and exit 0 (no false pointer written)"
  else
    bad "expected no-op rc=0 + unchanged log (rc=$rc, before='$before' after='$after')"
  fi
) || true

echo "[3] record_session_pointer omits the tool-call tail when jq is off PATH"
( home="$ROOT/c3home"; work="$ROOT/c3work"; mkdir -p "$work"
  proj="$home/.claude/projects/$(enc "$work")"; mkdir -p "$proj"
  cp "$FIXTURE" "$proj/session.jsonl"
  log="$ROOT/c3.log"; : >"$log"
  start=$(( $(date +%s) - 5 ))
  # A PATH with the helper's coreutils deps but NOT jq, so `command -v jq` fails.
  nojq="$ROOT/nojq"; mkdir -p "$nojq"
  for t in sed find sort head cut tail; do
    src="$(command -v "$t")" && ln -sf "$src" "$nojq/$t"
  done
  ( cd "$work" && HOME="$home" PATH="$nojq" record_session_pointer "$log" "$start" )
  if grep -q "^THROUGHLINE_SESSION: $proj/session.jsonl\$" "$log" \
     && ! grep -q 'Last assistant tool calls' "$log"; then
    ok "pointer line written, tool-call tail omitted without jq"
  else
    bad "expected pointer-only log without jq; got: $(cat "$log")"
  fi
) || true

echo "[4] record_session_pointer selects the newest JSONL written since start"
( home="$ROOT/c4home"; work="$ROOT/c4work"; mkdir -p "$work"
  proj="$home/.claude/projects/$(enc "$work")"; mkdir -p "$proj"
  start=$(( $(date +%s) - 5 ))
  cp "$FIXTURE" "$proj/older.jsonl"; touch -d "@$((start - 100))" "$proj/older.jsonl"
  cp "$FIXTURE" "$proj/newer.jsonl"   # fresh mtime ~now, i.e. after start
  log="$ROOT/c4.log"; : >"$log"
  ( cd "$work" && HOME="$home" record_session_pointer "$log" "$start" )
  if grep -q "^THROUGHLINE_SESSION: $proj/newer.jsonl\$" "$log" \
     && ! grep -q 'older\.jsonl' "$log"; then
    ok "newest-since-start JSONL selected, stale one ignored"
  else
    bad "expected the newer JSONL selected; got: $(cat "$log")"
  fi
) || true

echo "[5] build-prompt.md carries the Build-phase boundaries section + prohibitions"
( if grep -q '^Build-phase boundaries' "$BUILD_PROMPT" \
     && grep -q 'nested'                "$BUILD_PROMPT" \
     && grep -q 'pkill'                 "$BUILD_PROMPT" \
     && grep -q '/tmp'                  "$BUILD_PROMPT"; then
    ok "build-prompt.md states the FR-37 boundaries (nested / pkill / /tmp)"
  else
    bad "build-prompt.md missing the Build-phase boundaries heading or a prohibition keyword"
  fi
) || true

echo "[6] verify-runtime-prompt.md carries the Cleanup safety paragraph"
( if grep -q '^Cleanup safety' "$VERIFY_PROMPT" \
     && grep -q 'pkill'        "$VERIFY_PROMPT"; then
    ok "verify-runtime-prompt.md states the FR-38 cleanup-safety constraint"
  else
    bad "verify-runtime-prompt.md missing the Cleanup safety paragraph or pkill keyword"
  fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== build-observability eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

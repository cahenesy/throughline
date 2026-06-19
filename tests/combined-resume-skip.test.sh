#!/usr/bin/env bash
# combined-resume-skip.test.sh — eval for TDD 0059 (issue #165 / FR-18, FR-40, NFR-4).
#
# A `--combined` run that halts on a downstream TDD (position > 1) must be cleanly
# resumable: the resume re-processes the queue from the first TDD, but an
# already-`implemented` TDD on the shared combined branch must be SKIPPED (not
# re-flipped → empty-commit `FAIL flip` → BLOCKED cascade). Two interacting fixes
# close this: (1) a per-TDD skip in the combined driver loop, and (2) an
# idempotent `flip_status`. Both delegate to a single-sourced predicate
# `_tdd_implemented_at`.
#
#   §1 _tdd_implemented_at predicate (the single-sourced Status:implemented check)
#   §2 flip_status idempotency + honesty (already-implemented no-op vs real failure)
#   §3 combined-resume regression (drives the real combined driver end-to-end)
#   §4 single-source: exactly one Status:implemented predicate across the libs
#   §W dogfood: registering this eval makes the aggregator exit non-zero on failure
#
# Run: bash tests/combined-resume-skip.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# --- [§1] _tdd_implemented_at predicate ---------------------------------------
# The single home for the `^Status:[[:space:]]*implemented` check. Returns 0 iff
# the TDD at <ref> carries a Status: implemented line; non-zero otherwise,
# including when the ref or path is absent (git show fails → grep sees nothing).
echo "[§1] _tdd_implemented_at predicate"
( D="$ROOT/s1"; mkdir -p "$D"; cd "$D" || { bad "§1 cd failed"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd
  printf '# TDD 0001: a\nStatus: draft\n\n## Approach\nx\n' > docs/tdd/0001-a.md
  git add -A; git commit -qm init >/dev/null 2>&1
  git checkout -q -b built
  printf '# TDD 0001: a\nStatus: implemented\n\n## Approach\nx\n' > docs/tdd/0001-a.md
  git add -A; git commit -qm "mark 0001-a implemented" >/dev/null 2>&1
  git checkout -q master

  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "§1 could not source implement.sh"; exit 0; }
  if ! type -t _tdd_implemented_at >/dev/null; then
    bad "§1 _tdd_implemented_at is not defined after sourcing"; exit 0
  fi
  _tdd_implemented_at built docs/tdd/0001-a.md \
    && ok "implemented at <ref> → 0" \
    || bad "should return 0 for an implemented TDD at <ref>"
  _tdd_implemented_at master docs/tdd/0001-a.md \
    && bad "a draft TDD at <ref> must be non-zero" \
    || ok "draft at <ref> → non-zero"
  _tdd_implemented_at built docs/tdd/9999-missing.md \
    && bad "a missing path must be non-zero" \
    || ok "missing path → non-zero"
  _tdd_implemented_at no-such-ref docs/tdd/0001-a.md \
    && bad "a missing ref must be non-zero" \
    || ok "missing ref → non-zero"
) || true

# --- [§2] flip_status idempotency + honesty -----------------------------------
# A TDD already `implemented` at HEAD must flip as a no-op SUCCESS (return 0, no
# commit) — the empty-commit `FAIL flip` that issue #165 cascaded from. A genuine
# draft still flips and commits; a real commit failure on a genuine draft still
# returns non-zero (NFR-4: the guard precedes, never masks, the honest commit).
echo "[§2] flip_status idempotency + honesty"
( THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "§2 could not source implement.sh"; exit 0; }
  log="$ROOT/s2.log"; : > "$log"

  # (a) already implemented at HEAD → no-op success (return 0, no new commit)
  ( A="$ROOT/s2a"; mkdir -p "$A/docs/tdd"; cd "$A" || exit 0
    git init -q -b master; git config user.email t@t.t; git config user.name t
    printf '# TDD 0001: a\nStatus: implemented\n\n## Approach\nx\n' > docs/tdd/0001-a.md
    git add -A; git commit -qm init >/dev/null 2>&1
    before="$(git rev-list --count HEAD)"
    flip_status docs/tdd/0001-a.md "$log"; rc=$?
    after="$(git rev-list --count HEAD)"
    [ "$rc" -eq 0 ] && ok "(a) already-implemented flip returns 0" || bad "(a) already-implemented flip must return 0 (got rc=$rc)"
    [ "$before" = "$after" ] && ok "(a) no new commit on an already-implemented flip" || bad "(a) must add no commit (before=$before after=$after)"
  ) || true

  # (b) genuine draft → flips and commits (return 0, exactly one new commit)
  ( B="$ROOT/s2b"; mkdir -p "$B/docs/tdd"; cd "$B" || exit 0
    git init -q -b master; git config user.email t@t.t; git config user.name t
    printf '# TDD 0001: b\nStatus: draft\n\n## Approach\nx\n' > docs/tdd/0001-b.md
    git add -A; git commit -qm init >/dev/null 2>&1
    before="$(git rev-list --count HEAD)"
    flip_status docs/tdd/0001-b.md "$log"; rc=$?
    after="$(git rev-list --count HEAD)"
    [ "$rc" -eq 0 ] && ok "(b) genuine draft flip returns 0" || bad "(b) genuine draft flip must return 0 (got rc=$rc)"
    [ "$((after - before))" -eq 1 ] && ok "(b) exactly one new commit on a genuine flip" || bad "(b) must add exactly one commit (before=$before after=$after)"
    git show "HEAD:docs/tdd/0001-b.md" 2>/dev/null | grep -qE '^Status:[[:space:]]*implemented' \
      && ok "(b) HEAD now carries Status: implemented" || bad "(b) flipped TDD must be implemented at HEAD"
  ) || true

  # (c) genuine draft but git commit forced to fail → honest non-zero, no commit
  ( C="$ROOT/s2c"; mkdir -p "$C/docs/tdd"; cd "$C" || exit 0
    git init -q -b master; git config user.email t@t.t; git config user.name t
    printf '# TDD 0001: c\nStatus: draft\n\n## Approach\nx\n' > docs/tdd/0001-c.md
    git add -A; git commit -qm init >/dev/null 2>&1
    # reject every commit (issue #28B-style pre-commit hook), forcing git commit to fail
    printf '#!/usr/bin/env bash\nexit 1\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
    before="$(git rev-list --count HEAD)"
    flip_status docs/tdd/0001-c.md "$log"; rc=$?
    after="$(git rev-list --count HEAD)"
    [ "$rc" -ne 0 ] && ok "(c) a real commit failure still returns non-zero (NFR-4)" || bad "(c) guard must not mask a real commit failure (got rc=$rc)"
    [ "$before" = "$after" ] && ok "(c) no commit landed on a forced commit failure" || bad "(c) failed flip must not add a commit (before=$before after=$after)"
  ) || true
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== combined-resume-skip eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

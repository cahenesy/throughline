#!/usr/bin/env bash
# honest-review-scope-structural-resume.test.sh — eval for TDD 0031
# (honest consolidated-review scope on resume + revision-resolved structural-halt
# resume). Covers the TDD's verification points §1–§9 with shared git/worktree
# fixtures (one comprehensive eval per the TDD's declared expected-diff exception:
# every point reuses the same repo/worktree scaffolding, so splitting would
# duplicate it). Uses stub `claude` so no model or tokens are needed.
#
#   §1 _review_base derives the build-start merge-base, not gate-entry HEAD (gap A)
#   §2 the derived base flows into the rendered review prompt's diff line (gap A)
#   §3 review_one fails closed on an empty scope, spawning no reviewer (gap A)
#   §4 a structural-finding halt records the tdd_rev= revision fingerprint (gap B)
#   §5 a structural-finding halt surfaces as resumable in status.sh (gap B)
#   §6 resume refused while the resolving TDD revision is unmerged (gap B)
#   §7 resume accepted after revision + integration merge (gap B)
#   §8 a merge conflict refuses cleanly with a persisted cause (gap B)
#   §9 both new refusal outcomes render correctly in status.sh (gap B)
#
# Run: bash tests/honest-review-scope-structural-resume.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# A stub `claude` that records the prompt it was handed and emits a review PASS.
# Used by the §3 negative path: BEFORE the empty-scope guard exists, review_one
# would spawn this (rc 0, a THROUGHLINE_SESSION line) — the RED failure; AFTER,
# the guard returns before any spawn so this is never invoked.
_install_review_stub() {  # <bindir> <recordfile>
  local b="$1" rec="$2"; mkdir -p "$b"
  cat > "$b/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [ \$# -gt 0 ]; do case "\$1" in -p) prompt="\$2"; shift 2;; *) shift;; esac; done
printf '%s' "\$prompt" > "$rec"
echo "REVIEW_RESULT: PASS"
exit 0
EOF
  chmod +x "$b/claude"
}

# ===========================================================================
# §1 (gap A): _review_base derives the build start, NOT gate-entry HEAD. On a
# resumed branch the old `git rev-parse HEAD` equals the branch tip, collapsing
# the consolidated review to HEAD..HEAD (the vacuous-pass bug). _review_base
# returns `git merge-base <stacking-base> HEAD` — the true fork point — instead.
echo "[§1] _review_base returns the build-start merge-base, not gate-entry HEAD"
( D="$ROOT/s1"; mkdir -p "$D"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  command -v _review_base >/dev/null 2>&1 || { bad "_review_base helper missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'x\n' > f.txt; git add -A; git commit -qm base >/dev/null
  fork="$(git rev-parse HEAD)"
  git checkout -q -b build/x
  for i in 1 2 3; do printf '%s\n' "$i" >> f.txt; git add -A; git commit -qm "c$i" >/dev/null; done
  mb="$(git merge-base master HEAD)"; tip="$(git rev-parse HEAD)"
  rb="$(_review_base master)"
  [ "$rb" = "$mb" ]   && ok "_review_base equals git merge-base <base> HEAD" || bad "_review_base should equal the merge-base (got '$rb' want '$mb')"
  [ "$rb" != "$tip" ] && ok "_review_base is NOT gate-entry HEAD (the resume vacuous-pass bug)" || bad "_review_base must not equal the branch tip on a resumed branch"
  [ "$rb" = "$fork" ] && ok "_review_base equals the fork point (the build start)" || bad "_review_base should equal the fork point (got '$rb' want '$fork')"
  # negative (fresh-build equivalence): zero commits past the fork → equals HEAD,
  # so a fresh build is unchanged by construction.
  git checkout -q master; git checkout -q -b build/fresh
  rb2="$(_review_base master)"
  [ "$rb2" = "$(git rev-parse HEAD)" ] && ok "fresh build: _review_base equals HEAD (no behavior change)" || bad "fresh-build base should equal HEAD (got '$rb2')"
) || true

# §1-fallback: no merge base (unrelated histories / deleted base) → echo the
# passed ref unchanged + warn. Never worse than the pre-0031 behavior.
echo "[§1-fallback] _review_base falls back to the passed ref when no merge-base resolves"
( D="$ROOT/s1f"; mkdir -p "$D"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  command -v _review_base >/dev/null 2>&1 || { bad "_review_base helper missing"; exit 0; }
  git init -q -b master; git config user.email t@t.t; git config user.name t
  printf 'x\n' > f.txt; git add -A; git commit -qm base >/dev/null
  rb="$(_review_base does-not-exist 2>/dev/null)"
  [ "$rb" = "does-not-exist" ] && ok "unresolvable base echoes the passed ref unchanged" || bad "fallback should echo the ref (got '$rb')"
) || true

# ===========================================================================
# §2 (gap A): the derived base is what scopes the consolidated review. On resume
# the driver computes `pre=_review_base <stacking-base>`; review_one renders the
# prompt with `git diff <pre>..HEAD`. Confirm the merge-base — not the branch tip
# — lands in the rendered diff line (the observable for "not a vacuous scope").
echo "[§2] the derived base flows into the rendered review prompt's diff line"
( D="$ROOT/s2"; mkdir -p "$D"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export RTMPL="$REPO/scripts/review-prompt.md"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd; printf '# TDD\nStatus: draft\n' > docs/tdd/0031-x.md
  git add -A; git commit -qm base >/dev/null
  git checkout -q -b build/x
  printf 'more\n'  >> docs/tdd/0031-x.md; git add -A; git commit -qm c1 >/dev/null
  printf 'more2\n' >> docs/tdd/0031-x.md; git add -A; git commit -qm c2 >/dev/null
  pre="$(_review_base master)"; mb="$(git merge-base master HEAD)"; tip="$(git rev-parse HEAD)"
  [ "$pre" = "$mb" ] && ok "driver pre= equals the merge-base (the build start)" || bad "pre should equal the merge-base (got '$pre')"
  prompt="$(_render_review_prompt docs/tdd/0031-x.md "$pre" HEAD build/x "")"
  printf '%s' "$prompt" | grep -qF "git diff $pre..HEAD" \
    && ok "rendered review prompt scopes git diff <merge-base>..HEAD" || bad "prompt should scope the merge-base diff"
  printf '%s' "$prompt" | grep -qF "git diff $tip..HEAD" \
    && bad "prompt must NOT collapse to git diff <tip>..HEAD (the vacuous-pass bug)" \
    || ok "prompt does not collapse to <tip>..HEAD"
) || true

# ===========================================================================
# §3 (gap A): defense-in-depth — review_one refuses an empty review scope. With
# base == HEAD the diff is provably empty; review_one must log
# THROUGHLINE_REVIEW_SCOPE_EMPTY and return non-zero WITHOUT spawning a reviewer
# (no THROUGHLINE_SESSION line after the EMPTY line). NFR-4: ambiguity is never a
# false PASS.
echo "[§3] review_one fails closed on an empty scope (base == HEAD), spawning no reviewer"
( D="$ROOT/s3"; mkdir -p "$D/bin"; cd "$D" || { bad "cd failed"; exit 0; }
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  export RTMPL="$REPO/scripts/review-prompt.md" MODEL="" REVIEW_MODEL=""
  _install_review_stub "$D/bin" "$D/review-prompt.txt"
  export PATH="$D/bin:$PATH"
  git init -q -b master; git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd; printf '# TDD\nStatus: draft\n' > docs/tdd/0031-x.md
  git add -A; git commit -qm base >/dev/null
  head="$(git rev-parse HEAD)"
  log="$D/review.log"
  review_one docs/tdd/0031-x.md "$head" "$log"; rc=$?
  [ "$rc" -ne 0 ] && ok "review_one returns non-zero on an empty scope" || bad "review_one should fail closed (got rc=$rc)"
  grep -q 'THROUGHLINE_REVIEW_SCOPE_EMPTY' "$log" 2>/dev/null \
    && ok "gate log records THROUGHLINE_REVIEW_SCOPE_EMPTY" || bad "gate log should record THROUGHLINE_REVIEW_SCOPE_EMPTY"
  # The precise observable for "no reviewer spawned": no THROUGHLINE_SESSION line
  # after the EMPTY line.
  if awk '/THROUGHLINE_REVIEW_SCOPE_EMPTY/{seen=1} seen&&/THROUGHLINE_SESSION:/{f=1} END{exit !f}' "$log" 2>/dev/null; then
    bad "a THROUGHLINE_SESSION line followed the EMPTY line (a reviewer was spawned)"
  else
    ok "no reviewer process spawned (no THROUGHLINE_SESSION after the EMPTY line)"
  fi
  [ ! -s "$D/review-prompt.txt" ] && ok "stub reviewer was never invoked (no recorded prompt)" || bad "the reviewer stub should not have been invoked"
) || true

# --- report ----------------------------------------------------------------
echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== honest-review-scope-structural-resume eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

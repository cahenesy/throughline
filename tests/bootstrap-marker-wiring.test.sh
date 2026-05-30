#!/usr/bin/env bash
# bootstrap-marker-wiring.test.sh — eval for TDD 0009 / FR-31 + FR-32 + FR-33:
# pins the wiring the /bootstrap-project skill prompt MUST carry so the two
# markers and the .gitignore entry are not optional.
#
# The skill is model-driven, so two things are guarded here:
#   - a prose CONTRACT (cases [A]-[E]): the prompt keeps sourcing the helpers,
#     calling the write helpers, documenting the byte-stable short-circuit, and
#     recording markers on BOTH the greenfield and brownfield paths; and
#   - the documented procedure actually RUNS (case [F]): the fenced "On
#     completion" shell block is extracted, its placeholders filled, and
#     executed against a throwaway git repo — proving the commands the skill
#     tells the model to run really do produce the repo marker, the local
#     marker, and the .gitignore entry. This is behavior, not just string
#     presence; it would be red if the block were missing or broken.
#
# It does NOT drive Claude — the live end-to-end bootstrap behavior is covered
# by the runtime-verify gate; the unit helpers are covered by repo-id/gitignore/
# markers .test.sh.
#
# Written red-first against the reverted baseline (no step-2 wiring): every case
# fails until the wiring is (re-)added. Run: bash tests/bootstrap-marker-wiring.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/bootstrap-project/SKILL.md"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

has()  { grep -Fq "$1" "$SKILL"; }   # fixed-string presence
hasre(){ grep -Eiq "$1" "$SKILL"; }  # case-insensitive regex presence
mkrepo() { local d="$1"; mkdir -p "$d"; git -C "$d" init -q; printf '%s\n' "$d"; }

# Print the first fenced ```bash block that contains tl_repo_marker_write.
extract_completion_block() {
  awk '
    /^```bash$/ { inblk=1; buf=""; next }
    /^```$/     { if (inblk) { if (buf ~ /tl_repo_marker_write/) { printf "%s", buf; exit } inblk=0; buf="" } next }
    inblk       { buf = buf $0 "\n" }
  ' "$SKILL"
}

# --- [A] the skill sources all three helpers ---------------------------------
echo "[A] skill sources the three lib helpers"
for lib in repo-id.sh markers.sh gitignore.sh; do
  if has "scripts/lib/$lib"; then ok "sources $lib"; else bad "does not source $lib"; fi
done

# --- [B] the skill calls each marker/gitignore helper ------------------------
echo "[B] skill invokes the read + write helpers"
for fn in tl_repo_marker_read tl_repo_marker_write tl_local_marker_write tl_gitignore_add_line; do
  if has "$fn"; then ok "calls $fn"; else bad "never calls $fn"; fi
done

# --- [C] Step 0 short-circuit prints the FR-31 'already bootstrapped' line ----
echo "[C] Step 0 documents the byte-stable short-circuit"
has "already bootstrapped at" && ok "prints 'already bootstrapped at ...'" \
                              || bad "missing the 'already bootstrapped at' short-circuit line"
hasre "byte-identical|do not rewrite the marker|never rewrit" \
  && ok "states the marker must stay byte-identical on re-run" \
  || bad "does not state the re-run marker must stay byte-identical"

# --- [D] the FR-32 ignore line is the exact implement-logs path --------------
echo "[D] the gitignore entry is docs/tdd/.implement-logs/"
has 'docs/tdd/.implement-logs/' && ok "references docs/tdd/.implement-logs/" \
                                || bad "missing docs/tdd/.implement-logs/ ignore entry"

# --- [E] marker recording is wired for BOTH greenfield AND brownfield --------
echo "[E] completion recording covers the brownfield path, not just greenfield"
if grep -Eiq '^#+ +brownfield' "$SKILL" \
   && awk '
       /^#+ +[Bb]rownfield/{inbf=1}
       inbf && /record the bootstrap markers|tl_repo_marker_write|On completion/{found=1}
       /^#+ /{ if (seen && !/[Bb]rownfield/) inbf=0 } {seen=1}
       END{exit !found}
     ' "$SKILL"; then
  ok "a brownfield completion section ties brownfield -> record markers"
else
  bad "no brownfield completion instruction records the markers (greenfield-only drift)"
fi

# --- [F] the documented completion block actually writes both markers --------
echo "[F] the 'On completion' shell block runs and produces both markers + ignore"
( blk="$(extract_completion_block)"
  if [ -z "$blk" ]; then
    bad "no completion bash block (with tl_repo_marker_write) found in the skill"
  else
    R="$(mkrepo "$ROOT/f")"; DATA="$ROOT/f-data"
    blk="${blk//<language>/shell}"; blk="${blk//<steps-csv>/scaffold}"
    printf '%s' "$blk" > "$ROOT/f.sh"
    ( cd "$R" && CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PLUGIN_DATA="$DATA" bash "$ROOT/f.sh" ) >/dev/null 2>&1
    ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO/.claude-plugin/plugin.json" | head -n1)"
    f="$R/docs/.throughline-bootstrap.json"
    if [ -f "$f" ] && [ "$(jq -r '.plugin_version_applied' "$f" 2>/dev/null)" = "$ver" ]; then
      ok "running the block wrote the repo marker at the current plugin version"
    else
      bad "the block did not write a correct repo marker (ver=$ver)"
    fi
    grep -Fxq 'docs/tdd/.implement-logs/' "$R/.gitignore" 2>/dev/null \
      && ok "running the block added the .gitignore entry" \
      || bad "the block did not add the .gitignore entry"
    id="$(cd "$R" && bash -c "source '$REPO/scripts/lib/repo-id.sh'; tl_repo_id")"
    [ -f "$DATA/$id/local.json" ] \
      && ok "running the block wrote the per-developer local marker" \
      || bad "the block did not write the local marker"
  fi
) || true

# --- [G] an empty plugin version must NOT write a corrupt repo marker --------
# A failed `sed` (or a versionless plugin.json) yields ver="". Writing the marker
# with plugin_version_applied="" is silent corruption: Step 0 reads the field as
# empty and never short-circuits, so re-runs re-bootstrap forever.
echo "[G] a missing/empty plugin version does not corrupt the repo marker"
( blk="$(extract_completion_block)"
  if [ -z "$blk" ]; then
    bad "[G] no completion block to run"
  else
    R="$(mkrepo "$ROOT/g")"; DATA="$ROOT/g-data"
    blk="${blk//<language>/shell}"; blk="${blk//<steps-csv>/scaffold}"
    printf '%s' "$blk" > "$ROOT/g.sh"
    # Fake plugin root whose plugin.json carries NO version field -> ver="".
    FAKE="$ROOT/g-plugin"; mkdir -p "$FAKE/.claude-plugin"
    cp -r "$REPO/scripts" "$FAKE/scripts"
    printf '{ "name": "throughline" }\n' > "$FAKE/.claude-plugin/plugin.json"
    ( cd "$R" && CLAUDE_PLUGIN_ROOT="$FAKE" CLAUDE_PLUGIN_DATA="$DATA" bash "$ROOT/g.sh" ) >/dev/null 2>&1
    f="$R/docs/.throughline-bootstrap.json"
    applied="$(jq -r '.plugin_version_applied // empty' "$f" 2>/dev/null)"
    if [ ! -f "$f" ] || [ -n "$applied" ]; then
      ok "no marker written with an empty plugin_version_applied (Step 0 short-circuit stays intact)"
    else
      bad "wrote a corrupt marker (empty plugin_version_applied) — Step 0 would never short-circuit"
    fi
  fi
) || true

# --- [H] an unwritable local-marker path must not abort the completion block -
# TDD 0009 failure modes: when ${CLAUDE_PLUGIN_DATA} is unwritable the local
# write fails but the committed repo marker (the source of truth) must still
# land and bootstrap must continue. Run under `set -e` so a missing `|| true`
# guard on tl_local_marker_write surfaces as a non-zero block exit.
echo "[H] tl_local_marker_write failure does not abort the completion block"
( blk="$(extract_completion_block)"
  if [ -z "$blk" ]; then
    bad "[H] no completion block to run"
  else
    R="$(mkrepo "$ROOT/h")"
    blk="${blk//<language>/shell}"; blk="${blk//<steps-csv>/scaffold}"
    { printf 'set -e\n'; printf '%s' "$blk"; } > "$ROOT/h.sh"
    # CLAUDE_PLUGIN_DATA="" forces tl_local_marker_path (and the write) to fail.
    if ( cd "$R" && CLAUDE_PLUGIN_ROOT="$REPO" CLAUDE_PLUGIN_DATA="" bash "$ROOT/h.sh" ) >/dev/null 2>&1; then
      hexit=0; else hexit=1; fi
    f="$R/docs/.throughline-bootstrap.json"
    if [ "$hexit" -eq 0 ] && [ -f "$f" ]; then
      ok "block exits 0 and still wrote the repo marker despite an unwritable local path"
    else
      bad "an unwritable local-marker path aborted the block (missing '|| true' guard); exit=$hexit"
    fi
  fi
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== bootstrap-marker-wiring eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

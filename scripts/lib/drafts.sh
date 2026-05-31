#!/usr/bin/env bash
# drafts.sh — transient interview-draft persistence for /prd-author + /tdd-author.
#
# TDD 0012 (FR-46..50). Sourced by the prd-author / tdd-author skill prompts so
# both share one draft mechanism. Defines functions only — no top-level side
# effects — so it is safe to source from any context.
#
# A draft is a SINGLE JSON object per skill at
#   ${CLAUDE_PLUGIN_DATA}/<repo-id>/drafts/<skill>.json
# (per-developer, per-machine, never tracked by git — the path lives outside the
# repo). Shape, schema 1:
#   {"schema":1,"skill":"prd-author","started_at":<epoch>,"updated_at":<epoch>,
#    "prd_rev_at_start":<"sha"|null>,"interview":[{...}],"draft_doc":"<text>"}
# The serialization is a deterministic single line with a FIXED field order
# (draft_doc always last). Two structural markers — `"interview":[` and the
# unescaped `,"draft_doc":` that closes it — let the python3-less bash fallback
# splice without a JSON parser: every user-supplied quote inside an answer or
# draft_doc is backslash-escaped by json_escape, so neither marker can appear
# inside user content.
#
# Reuses TDD 0009's tl_drafts_dir/tl_repo_id (scripts/lib/repo-id.sh) and TDD
# 0015's json_escape (scripts/lib/state.sh) — sourced once here so the runner
# and the skills share one escaper without duplicating it. No new dependency:
# python3 is OPTIONAL (jq→python3→bash cascade, same as the runner); mkdir, mv,
# printf, grep, sed, rm, date are POSIX.
set -uo pipefail

_TL_DRAFTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/repo-id.sh
. "${_TL_DRAFTS_LIB_DIR}/repo-id.sh"
# shellcheck source=scripts/lib/state.sh
. "${_TL_DRAFTS_LIB_DIR}/state.sh"

# Current draft schema. Additive fields stay at 1 (same policy as TDD 0011 for
# run-state); a breaking change bumps this and the skill refuses to resume an
# incompatible draft.
TL_DRAFT_SCHEMA=1

_tl_draft_now() { date +%s; }

# tl_draft_path <skill-name> — echo the absolute draft path for this skill.
# Propagates tl_drafts_dir's fail-closed behavior (unset/unwritable
# CLAUDE_PLUGIN_DATA, no repo id).
tl_draft_path() {
  local skill="${1:?tl_draft_path: skill name required}"
  local dir
  dir="$(tl_drafts_dir)" || return 1
  printf '%s/%s.json' "$dir" "$skill"
}

# tl_draft_exists <skill-name> — exit 0 iff the draft file exists AND parses as
# JSON (structural sanity, not a schema check — the skill judges schema compat
# on resume). python3 json.load when available, else a `grep -q '"schema"'`
# heuristic.
tl_draft_exists() {
  local p
  p="$(tl_draft_path "$1")" || return 1
  [ -f "$p" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$p" >/dev/null 2>&1
  else
    grep -q '"schema"' "$p" 2>/dev/null
  fi
}

# tl_draft_init <skill-name> [prd_rev] — write a fresh schema-1 skeleton
# atomically (tmp + mv). prd_rev (the PRD short-SHA tdd-author designs against)
# is recorded as a JSON string; omitted → null (prd-author always passes none).
# Called LAZILY by the skill immediately before the first append, never at the
# resume-detect step — so a session killed before the first elicitation leaves
# no orphaned draft (FR-46 negative acceptance).
tl_draft_init() {
  local skill="${1:?tl_draft_init: skill name required}" prd="${2:-}"
  local p now prd_field tmp
  p="$(tl_draft_path "$skill")" || return 1
  now="$(_tl_draft_now)"
  if [ -n "$prd" ]; then prd_field="\"$(json_escape "$prd")\""; else prd_field="null"; fi
  tmp="$(mktemp "${p}.XXXXXX")" || return 1
  printf '{"schema":%s,"skill":"%s","started_at":%s,"updated_at":%s,"prd_rev_at_start":%s,"interview":[],"draft_doc":""}' \
    "$TL_DRAFT_SCHEMA" "$(json_escape "$skill")" "$now" "$now" "$prd_field" >"$tmp" \
    || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$p"
}

# tl_draft_read <skill-name> — print the entire draft JSON to stdout for the
# skill to rehydrate state.
tl_draft_read() {
  local p
  p="$(tl_draft_path "$1")" || return 1
  [ -f "$p" ] || { echo "tl_draft_read: no draft at $p" >&2; return 1; }
  cat "$p"
}

# tl_draft_append_elicit <skill-name> <kind> <header> <question> <answer>
# — atomically append one entry to interview[] with the current epoch as ts and
# bump updated_at. <kind> is restricted to the literals `question` / `decision`
# (FR-50 defense-in-depth: there is no path to record a reviewer verdict).
# python3 when available, else a bash JSON-builder using json_escape.
tl_draft_append_elicit() {
  local skill="${1:?tl_draft_append_elicit: skill required}" kind="${2:-}" \
        header="${3:-}" question="${4:-}" answer="${5:-}"
  case "$kind" in
    question|decision) ;;
    *) echo "tl_draft_append_elicit: kind must be 'question' or 'decision', got '$kind'" >&2; return 1 ;;
  esac
  local p now tmp rc
  p="$(tl_draft_path "$skill")" || return 1
  [ -f "$p" ] || { echo "tl_draft_append_elicit: no draft at $p (call tl_draft_init first)" >&2; return 1; }
  now="$(_tl_draft_now)"
  tmp="$(mktemp "${p}.XXXXXX")" || return 1
  if command -v python3 >/dev/null 2>&1; then
    TL_NOW="$now" TL_K="$kind" TL_H="$header" TL_Q="$question" TL_A="$answer" \
      python3 - "$p" "$tmp" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    d = json.load(fh)
now = int(os.environ["TL_NOW"])
d.setdefault("interview", []).append({
    "ts": now,
    "kind": os.environ["TL_K"],
    "header": os.environ["TL_H"],
    "question": os.environ["TL_Q"],
    "answer": os.environ["TL_A"],
})
d["updated_at"] = now
with open(dst, "w") as fh:
    json.dump(d, fh, separators=(",", ":"))
PY
    rc=$?
  else
    local obj old content
    obj="$(printf '{"ts":%s,"kind":"%s","header":"%s","question":"%s","answer":"%s"}' \
      "$now" "$(json_escape "$kind")" "$(json_escape "$header")" \
      "$(json_escape "$question")" "$(json_escape "$answer")")"
    old="$(sed -n 's/.*"updated_at":\([0-9]*\).*/\1/p' "$p" | head -1)"
    content="$(cat "$p")"
    content="${content/\"updated_at\":$old/\"updated_at\":$now}"
    if [[ "$content" == *'"interview":[]'* ]]; then
      content="${content/\"interview\":[]/\"interview\":[$obj]}"
    else
      content="${content/],\"draft_doc\":/,$obj],\"draft_doc\":}"
    fi
    printf '%s' "$content" >"$tmp"; rc=$?
  fi
  [ "${rc:-1}" -eq 0 ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$p"
}

# tl_draft_write_doc <skill-name> <doc-path|-> — replace draft_doc with the
# contents of the file (or stdin when `-`), atomically, and bump updated_at.
# Called after each authoring sub-step; the on-disk draft_doc is the
# compaction-survival source of truth (FR-48).
tl_draft_write_doc() {
  local skill="${1:?tl_draft_write_doc: skill required}" src="${2:?tl_draft_write_doc: doc path or - required}"
  local p now doc tmp rc
  p="$(tl_draft_path "$skill")" || return 1
  [ -f "$p" ] || { echo "tl_draft_write_doc: no draft at $p (call tl_draft_init first)" >&2; return 1; }
  if [ "$src" = "-" ]; then doc="$(cat)"; else doc="$(cat "$src")" || return 1; fi
  now="$(_tl_draft_now)"
  tmp="$(mktemp "${p}.XXXXXX")" || return 1
  if command -v python3 >/dev/null 2>&1; then
    TL_NOW="$now" TL_DOC="$doc" python3 - "$p" "$tmp" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    d = json.load(fh)
d["draft_doc"] = os.environ["TL_DOC"]
d["updated_at"] = int(os.environ["TL_NOW"])
with open(dst, "w") as fh:
    json.dump(d, fh, separators=(",", ":"))
PY
    rc=$?
  else
    local old content prefix esc
    esc="$(json_escape "$doc")"
    old="$(sed -n 's/.*"updated_at":\([0-9]*\).*/\1/p' "$p" | head -1)"
    content="$(cat "$p")"
    content="${content/\"updated_at\":$old/\"updated_at\":$now}"
    # draft_doc is the LAST field: strip from its structural marker to EOF, then
    # re-append the new value. The marker is unescaped only here.
    prefix="${content%%,\"draft_doc\":*}"
    content="${prefix},\"draft_doc\":\"${esc}\"}"
    printf '%s' "$content" >"$tmp"; rc=$?
  fi
  [ "${rc:-1}" -eq 0 ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$p"
}

# tl_draft_summary <skill-name> — echo a one-line resume summary:
#   <count> elicitations, started <iso8601>, last updated <iso8601> (skill=<skill>, prd_rev=<sha|n/a>)
# python3 when available, else a grep/sed fallback (lossy but never wrong:
# missing fields render <unknown>).
tl_draft_summary() {
  local p
  p="$(tl_draft_path "$1")" || return 1
  [ -f "$p" ] || { echo "tl_draft_summary: no draft at $p" >&2; return 1; }
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$p" <<'PY'
import json, sys, datetime
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    print("<unparseable draft>"); sys.exit(0)
def iso(ts):
    try:
        return datetime.datetime.fromtimestamp(int(ts), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return "<unknown>"
n = len(d.get("interview") or [])
skill = d.get("skill") or "<unknown>"
prd = d.get("prd_rev_at_start") or "n/a"
print(f"{n} elicitations, started {iso(d.get('started_at'))}, last updated {iso(d.get('updated_at'))} (skill={skill}, prd_rev={prd})")
PY
  else
    local n started updated skill prd
    # One "kind": per interview entry; user quotes are escaped so this never
    # over-counts from draft_doc/answer content.
    n="$(grep -o '"kind":' "$p" | wc -l | tr -d ' ')"; n="${n:-0}"
    started="$(sed -n 's/.*"started_at":\([0-9]*\).*/\1/p' "$p" | head -1)"
    updated="$(sed -n 's/.*"updated_at":\([0-9]*\).*/\1/p' "$p" | head -1)"
    skill="$(sed -n 's/.*"skill":"\([^"]*\)".*/\1/p' "$p" | head -1)"; skill="${skill:-<unknown>}"
    if grep -q '"prd_rev_at_start":null' "$p" 2>/dev/null; then
      prd="n/a"
    else
      prd="$(sed -n 's/.*"prd_rev_at_start":"\([^"]*\)".*/\1/p' "$p" | head -1)"; prd="${prd:-n/a}"
    fi
    _tl_iso() { [ -n "$1" ] && date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "<unknown>"; }
    printf '%s elicitations, started %s, last updated %s (skill=%s, prd_rev=%s)\n' \
      "$n" "$(_tl_iso "$started")" "$(_tl_iso "$updated")" "$skill" "$prd"
  fi
}

# tl_draft_discard <skill-name> — rm -f the draft. Called on PR-creation success
# (FR-49) and on the user's "discard and start fresh" choice (FR-47). rm -f so a
# discard with no draft present is a no-op success.
tl_draft_discard() {
  local p
  p="$(tl_draft_path "$1")" || return 1
  rm -f "$p"
}

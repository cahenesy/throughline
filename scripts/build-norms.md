## Defensive-coding norms (FR-74)

Apply these to EVERY commit you make, including late commits in a long build:

1. Fail loud. Check every command's return code. No bare `|| true` without a
   one-line justification comment. A sourced helper whose load fails aborts —
   never silently continues with functions undefined.
2. Temp files. Register every temp file in an EXIT trap BEFORE you create it.
3. Safe escaping. Never hand-roll a JSON escaper: use `jq`; if jq is absent,
   `python3`; if neither, fail closed with a clear diagnostic. Never run bash
   pattern substitution (`${v//x/y}`) on an untrusted string — `&` is the
   matched-text reference and corrupts the output. Validate before interpolating
   any external value into `sed`, `eval`, or `bash -c`.
4. Sourced-library hygiene. A sourced library has NO top-level side effects and
   does NOT set shell options (`set -uo pipefail`) at top level — they leak to
   every caller. Declare locals; do not leak ambient variables.
5. Path / trust boundary. Any filesystem path built from an external or
   user-supplied identifier is validated against a literal allowlist or a
   containment check (e.g. `realpath` prefix) before use.
6. Read once. Read mutable external state once into a variable; do not re-read
   the same file/command twice (TOCTOU window + inconsistency).
7. No hardcoding. No hardcoded absolute paths; no non-portable commands.

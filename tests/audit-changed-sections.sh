#!/usr/bin/env bash
#
# audit-changed-sections.sh: run, on its own, every suite section a push touched
# (claude-config#105).
#
# The suite's sections are independent: 73 of 73 run alone, and the one real dependency left is
# declared with a `# needs:` comment. That is a property somebody has to keep true, and the moment
# it stops being true is the moment somebody writes a NEW section that quietly reads a fixture an
# earlier one built. The full suite cannot notice, because it runs everything in order and the
# fixture is always there.
#
# So this runs each changed section by itself, which is the only run in which a missing prerequisite
# shows up. It is scoped to the diff deliberately: a push that does not touch the suite costs
# nothing, and a push that adds or edits a section pays for exactly that section.
#
# Usage: audit-changed-sections.sh <base-ref>
#
# Exit 0 = every changed section ran alone and passed, or there was nothing to do (which is said in
# those words rather than reported as a clean audit). Exit 1 = a changed section cannot run alone.
# Exit 2 = the suite changed but no section could be derived from the diff, which is a failure
# rather than a pass: an empty answer here is indistinguishable from having checked everything
# (LESSONS.md L98), and it is worded differently from a legitimate nothing-to-do (L11).
set -uo pipefail

SUITE="${AUDIT_SUITE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-claude-sync.sh}"
BASE="${1:-}"
[ -n "$BASE" ] || { echo "usage: audit-changed-sections.sh <base-ref>" >&2; exit 2; }
[ -f "$SUITE" ] || { echo "audit-changed-sections: no suite to read at $SUITE" >&2; exit 2; }

_root="$(git rev-parse --show-toplevel 2>/dev/null)" || _root=""
[ -n "$_root" ] || { echo "audit-changed-sections: not inside a git repository, so there is no diff to scope to." >&2; exit 2; }
ROOT="$(cd "$_root" && pwd -P)"
SUITE_ABS="$(cd "$(dirname "$SUITE")" && pwd -P)/$(basename "$SUITE")"
REL="${SUITE_ABS#$ROOT/}"

if git diff --quiet "$BASE" -- "$REL" 2>/dev/null; then
  echo "audit-changed-sections: $REL is unchanged against $BASE, so no section needed running on its own. The full suite still runs."
  exit 0
fi

# The changed lines, on the NEW side. A hunk that only REMOVES lines has a count of zero there, and
# that is exactly how a derivation quietly comes back empty, so a deletion is attributed to the
# position it happened at rather than dropped. split()'s return value is used rather than
# length(array), which is not portable across awk implementations.
changed="$(git diff --unified=0 "$BASE" -- "$REL" | awk '
  /^@@/ {
    k = split($3, p, ",")
    s = substr(p[1], 2) + 0
    n = (k > 1) ? p[2] + 0 : 1
    if (n == 0) { print s; next }
    for (i = 0; i < n; i++) print s + i
  }')"

# The section spans come from the SUITE, by asking it, rather than from a second derivation here.
# Two implementations of "where do the sections start and what are they called" drift, and this is
# the worse half to have drift: it is what decides whether a changed section can stand on its own,
# so a wrong answer scopes the audit to the wrong sections while still reporting a clean run
# (claude-config#114).
#
# They also have to come from the file's own headings rather than from line numbers recorded
# anywhere, because a diff moves every line below an insertion.
headings="$(SECTION_LIST=1 bash "$SUITE" 2>/dev/null || true)"
if [ -z "${headings%%[[:space:]]}" ] || ! printf '%s' "$headings" | grep -q '[0-9]'; then
  echo "audit-changed-sections: $REL listed no sections, so no changed line can be attributed to one. Refusing rather than treating the whole diff as preamble, which would report a clean audit of nothing." >&2
  exit 2
fi

preamble=0
titles=""
while IFS= read -r _ln; do
  case "$_ln" in ''|*[!0-9]*) continue ;; esac
  _t="$(printf '%s\n' "$headings" | awk -F'\t' -v L="$_ln" '{ if ($1 + 0 <= L + 0) last=$2 } END { print last }')"
  if [ -z "$_t" ]; then preamble=1; continue; fi
  titles="$titles$_t
"
done <<CHANGED
$changed
CHANGED

if [ -z "${titles//[[:space:]]/}" ]; then
  if [ "$preamble" -eq 1 ]; then
    echo "audit-changed-sections: the change is in the preamble, which every section runs anyway, so running one section at a time proves nothing extra here. The full suite covers it."
    exit 0
  fi
  echo "audit-changed-sections: $REL changed against $BASE, but no section could be derived from that diff. Refusing to report a clean audit, because an empty answer here reads exactly like having checked everything." >&2
  exit 2
fi

n=0; bad=""
while IFS= read -r _t; do
  [ -n "$_t" ] || continue
  n=$((n + 1))
  echo ""
  echo "audit-changed-sections: running only $_t"
  if ! SECTION_ONLY="$_t" bash "$SUITE"; then
    bad="$bad$_t
"
  fi
done <<TITLES
$(printf '%s' "$titles" | sort -u)
TITLES

if [ -n "${bad//[[:space:]]/}" ]; then
  echo "" >&2
  echo "audit-changed-sections: these changed sections do not run on their own:" >&2
  printf '%s' "$bad" | sed 's/^/  /' >&2
  echo "Give the section its own fixture, or add a '# needs:' line naming the section it depends on. Running it alone is the only run where a missing prerequisite shows up at all." >&2
  exit 1
fi

echo ""
echo "audit-changed-sections: audited $n section(s) changed against $BASE, and each one ran on its own and passed."
exit 0

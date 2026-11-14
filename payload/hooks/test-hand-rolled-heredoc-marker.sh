#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/
# No shell, Python or awk file reads a heredoc's end marker with a pattern of its own; every one
# reads it through lib/shell-words.py (claude-config#2080, L613). The scan is
# lib/hand-rolled-heredoc-marker.py, whose docstring says what it looks for and why.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/lib/hand-rolled-heredoc-marker.py"
# The checkout, found by the one shared test (lib/checkout-root.sh, claude-config#1567).
ROOT="${HEREDOC_MARKER_ROOT:-$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)" | sed '2,$s/^/  /'; fi; }

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-hand-rolled-heredoc-marker: $DIR/.. is not the payload of a claude-config checkout, so there were no files of this repository to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its files, and $DIR/.. is not the payload of a claude-config checkout"
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/heredoc-marker.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-hand-rolled-heredoc-marker: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The two brackets are written apart, so no line of this suite holds the shape the scan looks for.
_H='<''<'
T="$TMPROOT/tree"
mkdir -p "$T/lib" "$T/mods"
# One planted copy for each way the nine were written: a Python pattern, a Python pattern inside a
# shell file, an awk match, and a hook installed without its extension.
printf 'import re\nOP = re.compile(r"%s(-?)\\s*([\x27\\"]?)([A-Za-z_]\\w*)\\2")\n' "$_H" > "$T/lib/own.py"
printf '#!/usr/bin/env bash\npython3 - "$f" %sPY\nimport re\nHD = re.compile(r"%s-?\\s*[\x27\\"]?(\\w+)")\nPY\n' "$_H" "$_H" > "$T/own-embedded.sh"
printf '{ if (match($0, /%s-?[\x27"]?[A-Za-z_]/)) hd = 1 }\n' "$_H" > "$T/own.awk"
printf '#!/bin/bash\nm=$(printf %%s "$l" | grep -o "%s[[:alpha:]]*")\n' "$_H" > "$T/own-noext"
# What is not a copy: a here string's pattern, a heredoc that reads no marker, and a mod's
# TypeScript, which tools/check-mod-shared-parts.sh judges.
printf 'tally(c, "%s<[[:space:]]*\\\\$[A-Za-z_]")\n' "$_H" > "$T/clean-herestring.sh"
printf 'cat %sEOF\nword\nEOF\n' "$_H" > "$T/clean-heredoc.sh"
printf 'const m = /%s(\\w+)/.exec(line)\n' "$_H" > "$T/mods/own.ts"
LIST="lib/own.py
own-embedded.sh
own.awk
own-noext
clean-herestring.sh
clean-heredoc.sh
mods/own.ts"
out="$(printf '%s\n' "$LIST" | python3 "$SCAN" --root "$T" 2>"$TMPROOT/err")"; rc=$?
[ "$rc" -eq 1 ] && check "#2080 a tree holding a hand written marker reader fails the scan" ok \
  || check "#2080 a tree holding a hand written marker reader fails the scan" "exit=$rc out=$out"
for f in lib/own.py:2 own-embedded.sh:4 own.awk:1 own-noext:2; do
  case "$out" in *"$f: "*) check "#2080 and names $f" ok ;; *) check "#2080 and names $f" "$out" ;; esac
done
for f in clean-herestring.sh clean-heredoc.sh mods/own.ts; do
  case "$out" in *"$f:"*) check "#2080 and does not name $f" "$out" ;; *) check "#2080 and does not name $f" ok ;; esac
done
grep -q 'lib/shell-words.py' "$TMPROOT/err" && check "#2080 and says to read the marker through lib/shell-words.py" ok \
  || check "#2080 and says to read the marker through lib/shell-words.py" "$(cat "$TMPROOT/err")"

# A list naming nothing it reads is not a clean tree (L98).
out="$(printf 'mods/own.ts\n' | python3 "$SCAN" --root "$T" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && check "#2080 a list naming no file it reads is refused, not passed" ok \
  || check "#2080 a list naming no file it reads is refused, not passed" "exit=$rc out=$out"
out="$(printf 'clean-heredoc.sh\nclean-herestring.sh\n' | python3 "$SCAN" --root "$T" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && check "#2080 a tree with no copy passes" ok || check "#2080 a tree with no copy passes" "exit=$rc out=$out"

# The whole tree.
FILES="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null || true)"
[ -n "$FILES" ] && check "the files to judge were listed" ok \
  || check "the files to judge were listed" "lib/repo-files.sh gave nothing for $ROOT, so nothing below was read"
found="$(printf '%s\n' "$FILES" | python3 "$SCAN" --root "$ROOT" 2>&1)"; found_rc=$?
[ "$found_rc" -eq 0 ] && check "#2080 no file in this repository reads a heredoc's end marker with a pattern of its own" ok \
  || check "#2080 no file in this repository reads a heredoc's end marker with a pattern of its own" "exit=$found_rc
$found"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

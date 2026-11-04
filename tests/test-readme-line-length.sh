#!/usr/bin/env bash
# No line of README.md is over 200 characters (claude-config#2131).
#
# The mods table was reflowed in #2123 and held by test-readme-mods-table.sh. The rest of the README
# still carried 85 lines over 200 characters (measured on 2026-11-04), mostly rows of markdown
# pipe tables, which cannot wrap. Such a line is one unit to a diff, so a
# two word edit shows (and is reviewed, and merges, and conflicts) as a whole row. This suite holds
# the whole file to the same limit, and is seen to fail on a fixture holding one long line (L1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
README="$ROOT/README.md"
LIMIT=200
pass=0
fail=0

long_lines() {   # $1 = file -> prints "line N is M characters" for each line over the limit
  awk -v limit="$LIMIT" 'length > limit { printf "line %d is %d characters\n", NR, length }' "$1"
}

if [ ! -f "$README" ]; then
  echo "FAIL: README.md is missing at $README"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The check can see a long line, and passes a line exactly at the limit.
printf 'short\n%0201d\n' 0 > "$tmp/over"
printf 'short\n%0200d\n' 0 > "$tmp/at"
if [ "$(long_lines "$tmp/over")" = "line 2 is 201 characters" ]; then
  pass=$((pass + 1)); echo "PASS: the check fires on a line one character over"
else
  fail=$((fail + 1)); echo "FAIL: the check does not fire on a line one character over"
fi
if [ -z "$(long_lines "$tmp/at")" ]; then
  pass=$((pass + 1)); echo "PASS: the check passes a line exactly at the limit"
else
  fail=$((fail + 1)); echo "FAIL: the check fires on a line exactly at the limit"
fi

over="$(long_lines "$README")"
count="$(printf '%s' "$over" | grep -c . || true)"
if [ -z "$over" ]; then
  pass=$((pass + 1)); echo "PASS: no line of README.md is over $LIMIT characters"
else
  fail=$((fail + 1))
  echo "FAIL: $count lines of README.md are over $LIMIT characters, first five:"
  printf '%s\n' "$over" | awk 'NR <= 5'
fi

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

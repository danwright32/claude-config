#!/usr/bin/env bash
# README.md's mods table keeps short lines and the shape its resolver reads (claude-config#2108).
#
# Each row of the table was one markdown line, up to 29,507 characters, so a two line README edit
# added about 136 KB to the lessons review's diff, and three rows were cut short on GitHub by a pipe
# inside a code span. The table is now an HTML table whose cells are markdown paragraphs wrapped at
# 100 characters, the shape payload/hooks/lib/readme-rows-merge.py reads and writes (its docstring
# draws it). What is held here, each part seen to fail on the old README before the change (L1):
#   1. The real README's mods table parses with the resolver's own reader (mods_table), so the
#      file and the merge helper agree on one shape, and every row has three cells.
#   2. No line of the table, from <table> to </table>, is longer than 200 characters, and the check
#      that says so is seen to fire on a fixture holding one long line.
#   3. Every row is exactly what render_row writes for its cells, so a row hand edited into another
#      shape (an unwrapped cell, a missing blank line) is caught here, not in a later merge.
#   4. A markdown pipe table is refused by the reader, so a row pasted in the old shape fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
README="$ROOT/README.md"
RESOLVER="$ROOT/payload/hooks/lib/readme-rows-merge.py"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not on PATH, so the mods table cannot be read"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# The checks run in one python process, which prints a PASS or FAIL line per check. Its output goes
# to a file rather than through $( ): bash 3.2 misreads a quoted heredoc holding an apostrophe there.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 - "$RESOLVER" "$README" > "$tmp/out" 2>&1 <<'PY'
import importlib.util, re, sys

resolver_path, readme_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("readme_rows_merge", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)

LIMIT = 200


def report(ok, name):
    print(("PASS: " if ok else "FAIL: ") + name)


def table_span(lines):
    """The index range of the mods table, from its <table> line to its </table> line."""
    h = [i for i, l in enumerate(lines) if l == rr.HEADER]
    if len(h) != 1:
        return None
    start = max(i for i in range(h[0]) if lines[i] == "<table>")
    end = next(i for i in range(h[0], len(lines)) if lines[i] == "</table>")
    return start, end + 1


def long_lines(lines, span):
    return [(i + 1, len(lines[i])) for i in range(*span) if len(lines[i]) > LIMIT]


lines = open(readme_path, encoding="utf-8").read().split("\n")

# 1. The real table parses with the resolver's reader.
rows = None
try:
    first, end, rows = rr.mods_table(lines, "README.md")
    report(True, "README.md's mods table parses with the resolver's reader")
except rr.NotHandled as e:
    report(False, "README.md's mods table parses with the resolver's reader: %s" % e)

if rows is not None:
    report(len(rows) >= 20, "the table holds every mod (%d rows read, at least 20 expected)" % len(rows))
    bad = [r[0] for r in rows if len(r[1]) != len(rr.COLUMNS)]
    report(not bad, "every row has %d cells%s" % (len(rr.COLUMNS), (": not " + ", ".join(bad)) if bad else ""))
    bad = [r[0] for r in rows if not re.match(r"#\d+\b", r[1][2])]
    report(not bad, "every row's Issue cell begins with an issue number%s" % ((": not " + ", ".join(bad)) if bad else ""))

# 2. No table line is over the limit, and the check can see one that is.
span = table_span(lines)
report(span is not None, "the table sits between a <table> and a </table> line")
if span is not None:
    over = long_lines(lines, span)
    report(not over, "no line of the table is over %d characters%s" % (
        LIMIT, (": " + ", ".join("line %d is %d" % o for o in over[:5])) if over else ""))
fixture = ["<table>", "<thead>", rr.HEADER, "</thead>", "<tbody>", "x" * (LIMIT + 1), "</tbody>", "</table>"]
report(long_lines(fixture, table_span(fixture)) == [(6, LIMIT + 1)],
       "the line limit check fires on a table line one character over")

# 3. Every row is exactly what render_row writes for its cells.
if rows is not None:
    drift = []
    for key, cells, cell_lines, row_lines in rows:
        if rr.render_row(cells) != row_lines:
            drift.append(key)
    report(not drift, "every row is written as render_row writes it%s" % ((": not " + ", ".join(drift)) if drift else ""))
    # and the check sees a row whose description was left on one long line
    key, cells, cell_lines, row_lines = max(rows, key=lambda r: len(r[1][1]))
    joined = row_lines[:]
    d0 = joined.index(cell_lines[1][0])
    joined[d0:d0 + len(cell_lines[1])] = [cells[1]]
    report(len(cell_lines[1]) > 1 and rr.render_row(cells) != joined,
           "the render check fires on a row whose description is one unwrapped line")

# 4. A markdown pipe table is refused.
pipe = ["| Mod | What it does | Issue |", "| --- | --- | --- |", "| `a` | does a | #1 |"]
try:
    rr.mods_table(pipe, "a pipe table")
    report(False, "a markdown pipe table is refused by the reader")
except rr.NotHandled:
    report(True, "a markdown pipe table is refused by the reader")
PY
code=$?
out="$(cat "$tmp/out")"
printf '%s\n' "$out" | grep -E '^FAIL: '
pass="$(printf '%s\n' "$out" | grep -c -E '^PASS: ')"
fail="$(printf '%s\n' "$out" | grep -c -E '^FAIL: ')"
if [ "$code" -ne 0 ]; then
  printf '%s\n' "$out" | tail -5
  echo "FAIL: the checks crashed (they exited $code)"
  fail=$((fail + 1))
fi
if [ "$pass" -lt 10 ]; then
  echo "FAIL: only $pass checks passed of the 10 this suite runs, so some never ran"
  fail=$((fail + 1))
fi
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

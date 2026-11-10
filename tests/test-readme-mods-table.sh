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
#   3. Every cell's lines are ones the resolver could write: within 100 characters where they can
#      be broken, none after the first able to start a markdown block, none ending in a backslash.
#      Not a fresh wrap, since a cell merged line by line keeps the lines each side wrote.
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
python3 -B - "$RESOLVER" "$README" > "$tmp/out" 2>&1 <<'PY'
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

# 3. Every cell's lines are ones the resolver could have written. Not a fresh wrap of the cell: a
# cell the resolver merged line by line keeps the lines each side wrote. What matters is that each
# line is within WIDTH where it can be broken, that no line after a cell's first could start a
# block of its own (a list, a heading, a fence), and that none ends in a backslash (a hard break).
def bad_lines(cell_lines):
    out = []
    for n, line in enumerate(cell_lines):
        if len(line) > rr.WIDTH and len(rr.wrap(line)) > 1:
            out.append("a line of %d characters that could be broken" % len(line))
        if n > 0 and not rr.line_may_start(line):
            out.append("a line starting %r, which could begin a block" % line[:12])
        if line.endswith("\\"):
            out.append("a line ending in a backslash")
    return out


if rows is not None:
    drift = ["%s (%s)" % (r[0], b[0]) for r in rows for b in [sum((bad_lines(cl) for cl in r[2]), [])] if b]
    report(not drift, "every cell's lines are within %d where breakable and start no block%s" % (
        rr.WIDTH, (": not " + ", ".join(drift)) if drift else ""))
    # and the check sees a description left on one long line, and a line that would start a list
    key, cells, cell_lines, row_lines = max(rows, key=lambda r: len(r[1][1]))
    report(len(cell_lines[1]) > 1 and bad_lines([cells[1]]) and bad_lines(["text", "- a list item"]),
           "the line check fires on an unwrapped description and on a line starting a list")
    # but passes a cell laid out as a line merge leaves it: a line split short of the full width
    first = cell_lines[1][0]
    cut = rr.wrap(first, width=len(first) // 2)
    merged = cut + cell_lines[1][1:]
    report(len(cut) > 1 and merged != rr.wrap(cells[1]) and not bad_lines(merged),
           "the line check passes a description split short, as a line merge leaves it")

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
if [ "$pass" -lt 11 ]; then
  echo "FAIL: only $pass checks passed of the 11 this suite runs, so some never ran"
  fail=$((fail + 1))
fi
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

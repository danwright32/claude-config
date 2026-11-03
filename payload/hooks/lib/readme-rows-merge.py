#!/usr/bin/env python3
"""Resolve a README.md conflict confined to rows of its mods table (claude-config#1867).

    readme-rows-merge.py <repo>

<repo> is a work tree in the middle of a merge with README.md in conflict. The three versions are
read from the index (stage 1 the base, 2 ours, 3 theirs), never from the conflicted file, so how
the caller's git draws its conflict markers does not matter. When every conflicted hunk is a run
of rows of the mods table, and every row resolves by the rules below, README.md is written with
the result. Otherwise nothing is written.

Exits (L1033, a crash exits 1, so 1 never means anything here):
    0   resolved: README.md written
    10  not a case this handles: nothing written, the reason is the last line printed
    2   could not read: a stage missing, git failing, or text that is not UTF-8

WHY. Two pull requests touching one mod meet in its row, and the issue number list at its end
meets every time two of them add a number. On 2026-10-28 that stopped #1819, #1835 (twice), #1850
and #1852 in the merge helper, about an hour each. The rules here are the ones a scratch resolver
applied to about ten such conflicts that day, each checked by hand afterwards and all correct.

THE TABLE'S SHAPE (#2108). Until then each row was one markdown table line of up to 29 KB, so a
two line README edit added about 136 KB to the lessons review's diff. It is now an HTML table whose
every cell is a markdown paragraph on lines of its own, wrapped at WIDTH:

    <tr><td>
    (blank)
    `name`
    (blank)
    </td><td>
    (blank)
    the description, on as many lines as it takes
    (blank)
    </td><td>
    (blank)
    #605, #611
    (blank)
    </td></tr>

with the rows between "<tbody>" and "</tbody>" under the header row HEADER. The blank lines are
what make GitHub read each cell as markdown (inside raw HTML it is read as text), and a cell holds
one paragraph, so it has no blank line of its own. A pipe needs no escape anywhere in it, inside a
code span or out, which the markdown table did need: three rows were cut short on GitHub by one.
render_row writes this shape, and tests/test-readme-mods-table.sh holds README.md to it.

HOW. Each version is read as rows of cells (a cell's lines joined by spaces), and git merge-file
runs over the three with each row flattened to one line, so a conflict anywhere in a row is a
conflict of that whole row, as it was when a row was a line. THE RULES, for each conflicted hunk:
  - both sides of the hunk are rows of the mods table, with the same keys in the same order, and
    the hunk lies inside that table in the merged file; anything else is not handled;
  - per row, compared with the base's row of the same key: the same on both sides is kept; changed
    on one side only takes that side; changed on both is merged cell by cell, each cell as for rows
    when it is the same on both sides or changed on one side only, and otherwise first by its
    lines (git merge-file over the cell's lines, which keeps the lines both sides wrote when they
    edited different ones), and failing that word by word: git merge-file over the three versions
    split into words, where a word conflict is resolved only when
      - it is in the Issue cell and each side of it is a run of issue numbers: the union of every
        number the three name, in number order (so a number one side removed in that same spot
        comes back, as the scratch resolver did; a person reads the diff of the update);
      - or both sides inserted text at the same place and one side's insertion begins with the
        other's: the longer is kept;
    a row whose cell count differs from the table's in any version, or a word conflict of any other
    shape, is not handled.
A row the merge leaves equal to one side's is written as that side wrote it; any other row is
written by render_row, with each cell that equals one side's kept as that side's lines.

THE RESULT IS CHECKED before it is written (L631): no conflict marker line, the mods table read
back from the written text holding exactly the union of both sides' keys once each, every row with
the cells the merge produced, the cell count it has on each side, and every resolved row with the
table's.

CALIBRATED on the real conflicts of 2026-10-28 (17 row merges the scratch resolver recorded): this
gave its result on every one it resolved and refused the two it refused. Real Issue cells are not
tidy lists ("#607 to #609, #605, ..."), which is why the issue rule works on the conflicting run of
numbers and not on the whole cell.
"""
import os
import re
import subprocess
import sys
import tempfile

RESOLVED, NOT_HANDLED, UNREAD = 0, 10, 2

HEADER = "<tr><th>Mod</th><th>What it does</th><th>Issue</th></tr>"
COLUMNS = ["Mod", "What it does", "Issue"]
ROW_OPEN, CELL_NEXT, ROW_CLOSE = "<tr><td>", "</td><td>", "</td></tr>"
KEY = re.compile(r"^`([^`]+)`$")
ISSUE_RUN = re.compile(r"^(#\d+,?\s*)+$")
# A cell's lines are wrapped at this width, the width of the README's prose.
WIDTH = 100
# A flattened row: ROW_MARK, then its cells joined by CELL_SEP. Neither character is in any README.
ROW_MARK, CELL_SEP = "\x1e", "\x1f"
# Markers far longer than git's seven, so no line of the README can be taken for one.
MARK = 31
OPEN, BASE_MARK, SEP, CLOSE = "<" * MARK, "|" * MARK, "=" * MARK, ">" * MARK
ANY_MARKER = re.compile(r"^(<{7}|>{7}|\|{7}|={7})")


class NotHandled(Exception):
    pass


class Unread(Exception):
    pass


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    if r.returncode != 0:
        raise Unread("git %s: %s" % (" ".join(args), r.stderr.decode("utf-8", "replace").strip()))
    return r.stdout


def text(raw, what):
    try:
        # Strict, and refused by name below (#1923): this text is merged and written back as the
        # README, so a stand in for a byte would change the file rather than read it.
        return raw.decode("utf-8", "strict")
    except UnicodeDecodeError:
        raise Unread("%s is not UTF-8" % what)


def merge_file(ours, base, theirs, diff3=False):
    """git merge-file over three texts; returns (number of conflicts, merged text)."""
    with tempfile.TemporaryDirectory(prefix="readme-rows-") as d:
        paths = []
        for name, body in (("ours", ours), ("base", base), ("theirs", theirs)):
            p = os.path.join(d, name)
            with open(p, "w", encoding="utf-8", newline="", errors="replace") as f:
                f.write(body)
            paths.append(p)
        cmd = ["git", "merge-file", "-p", "--marker-size=%d" % MARK, "-L", "ours", "-L", "base", "-L", "theirs"]
        if diff3:
            cmd.append("--diff3")
        r = subprocess.run(cmd + paths, capture_output=True)
    # A count of conflicts, or a negative number (255 and the like) when merge-file itself failed.
    if r.returncode > 127:
        raise Unread("git merge-file failed: %s" % r.stderr.decode("utf-8", "replace").strip())
    return r.returncode, text(r.stdout, "git merge-file's output")


# ---- the table's shape ---------------------------------------------------------------------------

def line_may_start(rest):
    """Whether a wrapped line may begin with rest. Inside a paragraph a line beginning with a list
    marker, a heading, a quote, a fence, an HTML tag, or a run of = or - would start a block of its
    own, or turn the paragraph above into a heading, so a break is made only before text that
    cannot: a letter, a digit that is not a list number, an issue reference, a code span or an
    opening bracket or quote."""
    c = rest[0]
    if c.isalpha() or c in "(\"'":
        return True
    if c.isdigit():
        return not re.match(r"\d{1,9}[.)](\s|$)", rest)
    if c == "#":
        return bool(re.match(r"#\d", rest))
    if c == "`":
        return not rest.startswith("```")
    return False


def wrap(cell, width=WIDTH):
    """A cell's text as lines of at most width where it can be broken, broken only at a single
    space after which a line may start (line_may_start) and never after a backslash, which would
    make the break a hard one. Joined with spaces the lines give the text back exactly."""
    breaks = [i for i in range(1, len(cell) - 1)
              if cell[i] == " " and cell[i - 1] not in " \\" and cell[i + 1] != " " and line_may_start(cell[i + 1:])]
    lines, start = [], 0
    while len(cell) - start > width:
        fit = [b for b in breaks if start < b <= start + width]
        later = [b for b in breaks if b > start]
        b = fit[-1] if fit else (later[0] if later else None)
        if b is None:
            break
        lines.append(cell[start:b])
        start = b + 1
    lines.append(cell[start:])
    return lines


def render_row(cells, keep=()):
    """A row's lines in the table's shape. keep is a list of (cells, cell lines) from versions
    already written: a cell equal to one of theirs keeps the lines it was written with."""
    out = [ROW_OPEN]
    for n, cell in enumerate(cells):
        if cell.strip() == "" or "\n" in cell:
            raise NotHandled("a row would be written with an empty cell")
        lines = next((kl[n] for kc, kl in keep if n < len(kc) and n < len(kl) and kc[n] == cell and kl[n]), None) or wrap(cell)
        out += ([""] if n == 0 else ["", CELL_NEXT, ""]) + lines
    return out + ["", ROW_CLOSE]


def mods_table(lines, what):
    """The mods table of a whole file's lines: (first, end, rows), where lines[first:end] are its
    rows and each row is (key, cells, cell lines, row lines)."""
    at = [i for i, l in enumerate(lines) if l == HEADER]
    if len(at) != 1:
        raise NotHandled("%s has %d mods table headers, not one" % (what, len(at)))
    h = at[0]
    if lines[h + 1:h + 3] != ["</thead>", "<tbody>"]:
        raise NotHandled("%s's mods table header is not followed by </thead> and <tbody>" % what)
    rows, i = [], h + 3
    while i < len(lines) and lines[i] != "</tbody>":
        start = i
        if lines[i] != ROW_OPEN:
            raise NotHandled("%s's mods table holds a line that is not a row: %s" % (what, lines[i][:80]))
        cells, cell_lines = [], []
        while True:
            if lines[i + 1:i + 2] != [""]:
                raise NotHandled("%s's mods table has a cell that does not open with a blank line, line %d" % (what, i + 2))
            j = i + 2
            while j < len(lines) and lines[j].strip() != "":
                j += 1
            body = [l.strip() for l in lines[i + 2:j]]
            if not body:
                raise NotHandled("%s's mods table has an empty cell, line %d" % (what, i + 3))
            if lines[j + 1:j + 2] not in ([CELL_NEXT], [ROW_CLOSE]):
                raise NotHandled("%s's mods table has a cell that does not close with a blank line and </td>, line %d" % (what, j + 2))
            cells.append(" ".join(body))
            cell_lines.append(body)
            i = j + 1
            if lines[i] == ROW_CLOSE:
                break
        m = KEY.match(cells[0])
        if not m:
            raise NotHandled("%s has a mods table row whose first cell is not a mod's name: %s" % (what, cells[0][:80]))
        rows.append((m.group(1), cells, cell_lines, lines[start:i + 1]))
        i += 1
    if i >= len(lines):
        raise NotHandled("%s's mods table has no </tbody>" % what)
    keys = [r[0] for r in rows]
    if len(set(keys)) != len(keys):
        raise NotHandled("%s names a mod twice in its mods table" % what)
    return h + 3, i, rows


def flat(row_cells):
    return ROW_MARK + CELL_SEP.join(row_cells)


def flatten(whole, what):
    """A version as (text with each row of the mods table on one line, rows by key)."""
    if ROW_MARK in whole or CELL_SEP in whole:
        raise NotHandled("%s holds a control character this uses to mark rows" % what)
    lines = whole.split("\n")
    first, end, rows = mods_table(lines, what)
    flat_lines = lines[:first] + [flat(r[1]) for r in rows] + lines[end:]
    return "\n".join(flat_lines), {r[0]: r for r in rows}


# ---- the merge -----------------------------------------------------------------------------------

def parse(merged):
    """Merged text as a list of ("line", text) and ("hunk", ours lines, theirs lines)."""
    lines, out, i = merged.split("\n"), [], 0
    while i < len(lines):
        if lines[i] == OPEN + " ours":
            try:
                j = lines.index(SEP, i)
                k = lines.index(CLOSE + " theirs", j)
            except ValueError:
                raise Unread("an unterminated conflict in git merge-file's output")
            out.append(("hunk", lines[i + 1:j], lines[j + 1:k]))
            i = k + 1
        else:
            out.append(("line", lines[i]))
            i += 1
    return out


def check_hunks_in_table(segments):
    """Every hunk must lie inside the mods table of the merged file."""
    heads = [n for n, s in enumerate(segments) if s[0] == "line" and s[1] == HEADER]
    if any(s[0] == "hunk" and (HEADER in s[1] or HEADER in s[2]) for s in segments) or len(heads) != 1:
        raise NotHandled("README.md's conflict is not only rows of its mods table: the table's header is in conflict or not there once")
    start = heads[0] + 3
    end = start
    while end < len(segments):
        s = segments[end]
        if s[0] == "line" and not s[1].startswith(ROW_MARK):
            break
        end += 1
    for n, s in enumerate(segments):
        if s[0] == "hunk" and not (start <= n < end):
            raise NotHandled("README.md's conflict is not only rows of its mods table: a hunk lies outside it")


def issue_union(so, sb, st):
    """A word conflict inside the Issue cell where each side is a run of issue numbers: every
    number any of the three versions names, once each, in number order, as the scratch resolver
    did on 2026-10-28. Keeps our side's surrounding spaces and its trailing comma, which both sides
    must agree on."""
    if not (ISSUE_RUN.match(so.strip()) and ISSUE_RUN.match(st.strip()) and (sb.strip() == "" or ISSUE_RUN.match(sb.strip()))):
        return None
    comma = so.rstrip().endswith(",")
    if comma != st.rstrip().endswith(","):
        return None
    nums = []
    for s in (sb, so, st):
        for x in re.findall(r"#\d+", s):
            if x not in nums:
                nums.append(x)
    nums.sort(key=lambda x: int(x[1:]))
    lead = re.match(r"^\s*", so).group(0)
    trail = re.search(r"\s*$", so).group(0)
    return lead + ", ".join(nums) + ("," if comma else "") + trail


def word_merge(base, ours, theirs, where, issues=False):
    """Merge one cell's text word by word; with issues, a conflict of issue number runs is unioned."""
    split = lambda s: "\n".join(re.findall(r"\S+|\s+", s)) + "\n"
    _, merged = merge_file(split(ours), split(base), split(theirs), diff3=True)
    lines, res, n = merged.split("\n"), [], 0
    while n < len(lines):
        if lines[n] == OPEN + " ours":
            try:
                m1 = lines.index(BASE_MARK + " base", n)
                m2 = lines.index(SEP, m1)
                m3 = lines.index(CLOSE + " theirs", m2)
            except ValueError:
                raise Unread("an unterminated word conflict in git merge-file's output")
            so, sb, st = ("".join(lines[a + 1:z]) for a, z in ((n, m1), (m1, m2), (m2, m3)))
            union = issue_union(so, sb, st) if issues else None
            if union is not None:
                res.append(union)
            elif sb.strip() == "" and st and so.startswith(st):
                res.append(so)
            elif sb.strip() == "" and so and st.startswith(so):
                res.append(st)
            else:
                raise NotHandled("%s: both sides changed the same words (%r and %r), which needs a person" % (where, so.strip(), st.strip()))
            n = m3 + 1
        else:
            res.append(lines[n])
            n += 1
    return "".join(res)


def line_merge(base, ours, theirs):
    """Merge one cell's lines; the merged lines when git merges them cleanly, else None."""
    conflicts, merged = merge_file(*("\n".join(x) + "\n" for x in (ours, base, theirs)))
    if conflicts:
        return None
    lines = merged.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines if lines and all(l.strip() for l in lines) else None


def merge_row(key, base, ours, theirs, issue_col, report):
    """Each of base, ours and theirs is a row as mods_table reads it (base may be None). Returns
    the merged cells, and the cell lines already written for any cell merged by its lines."""
    if ours[1] == theirs[1]:
        report.append("%s: the same on both sides" % key)
        return ours[1], []
    if base is None:
        raise NotHandled("%s: a row both sides added differently, which needs a person" % key)
    if ours[1] == base[1]:
        report.append("%s: took main's change (the branch left it alone)" % key)
        return theirs[1], []
    if theirs[1] == base[1]:
        report.append("%s: took the branch's change (main left it alone)" % key)
        return ours[1], []
    cb, co, ct = base[1], ours[1], theirs[1]
    if not (len(cb) == len(co) == len(ct) == len(COLUMNS)):
        raise NotHandled("%s: its number of cells changed, which needs a person" % key)
    out, how, written = [], [], [None] * len(COLUMNS)
    for i, (b, o, t) in enumerate(zip(cb, co, ct)):
        if o == t:
            out.append(o)
        elif o == b:
            out.append(t)
        elif t == b:
            out.append(o)
        else:
            lines = line_merge(base[2][i], ours[2][i], theirs[2][i])
            if lines is not None:
                written[i] = lines
                out.append(" ".join(lines))
                how.append("its lines merged")
            elif i == issue_col:
                out.append(word_merge(b, o, t, key, issues=True))
                how.append("its issue numbers merged")
            else:
                out.append(word_merge(b, o, t, key))
                how.append("its words merged")
    report.append("%s: both sides changed it, %s" % (key, " and ".join(how) or "cell by cell"))
    return out, [(out, [w if w is not None else [] for w in written])] if any(written) else []


def unflatten(flat_lines, ours_rows, theirs_rows, merged_keep):
    """Flattened merged lines back in the table's shape: a row equal to one side's as that side
    wrote it, any other through render_row."""
    out = []
    for line in flat_lines:
        if not line.startswith(ROW_MARK):
            out.append(line)
            continue
        cells = line[len(ROW_MARK):].split(CELL_SEP)
        key = KEY.match(cells[0]).group(1) if KEY.match(cells[0]) else None
        side = next((rows[key] for rows in (ours_rows, theirs_rows) if key in rows and rows[key][1] == cells), None)
        if side is not None:
            out += side[3]
            continue
        keep = [(r[1], r[2]) for rows in (ours_rows, theirs_rows) if key in rows for r in [rows[key]]]
        out += render_row(cells, merged_keep.get(key, []) + keep)
    return out


def check_structure(result, ours_rows, theirs_rows, resolved):
    """The written file's shape (L631), before anything is written. resolved maps each resolved
    key to the cells the merge produced."""
    lines = result.split("\n")
    marked = [l for l in lines if ANY_MARKER.match(l)]
    if marked:
        raise NotHandled("the result still holds a conflict marker line: %s" % marked[0][:80])
    _, _, rows = mods_table(lines, "the result")
    want = set(ours_rows) | set(theirs_rows)
    got = [r[0] for r in rows]
    if len(got) != len(want) or set(got) != want:
        raise NotHandled("the result's mods table holds %d rows where both sides together name %d mods" % (len(got), len(want)))
    for k, cells, _, _ in rows:
        for side in (ours_rows, theirs_rows):
            if k in side and len(cells) != len(side[k][1]):
                raise NotHandled("%s: the result's row has %d cells where a side's has %d" % (k, len(cells), len(side[k][1])))
        if k in resolved:
            if len(cells) != len(COLUMNS):
                raise NotHandled("%s: the resolved row has %d cells where the table has %d" % (k, len(cells), len(COLUMNS)))
            if cells != resolved[k]:
                raise NotHandled("%s: the resolved row does not read back as the cells it was merged to" % k)


def resolve(repo):
    base = text(git(repo, "show", ":1:README.md"), "the base README.md")
    ours = text(git(repo, "show", ":2:README.md"), "our README.md")
    theirs = text(git(repo, "show", ":3:README.md"), "their README.md")
    base_flat, base_rows = flatten(base, "the base README.md")
    ours_flat, ours_rows = flatten(ours, "our README.md")
    theirs_flat, theirs_rows = flatten(theirs, "their README.md")
    issue_col = COLUMNS.index("Issue")
    conflicts, merged = merge_file(ours_flat, base_flat, theirs_flat)
    if conflicts == 0:
        raise NotHandled("README.md merges cleanly here, so there is nothing for this to resolve")
    segments = parse(merged)
    check_hunks_in_table(segments)
    out, report, resolved, merged_keep = [], [], {}, {}
    for s in segments:
        if s[0] == "line":
            out.append(s[1])
            continue
        o, t = s[1], s[2]
        if not o or not all(l.startswith(ROW_MARK) for l in o + t):
            raise NotHandled("README.md's conflict is not only rows of its mods table: a hunk holds other lines")
        ocells = [l[len(ROW_MARK):].split(CELL_SEP) for l in o]
        tcells = [l[len(ROW_MARK):].split(CELL_SEP) for l in t]
        okeys = [KEY.match(c[0]).group(1) if KEY.match(c[0]) else None for c in ocells]
        tkeys = [KEY.match(c[0]).group(1) if KEY.match(c[0]) else None for c in tcells]
        if okeys != tkeys or None in okeys:
            raise NotHandled("a hunk of the mods table holds different rows on each side (%s against %s), which needs a person" % (", ".join(map(str, okeys)), ", ".join(map(str, tkeys))))
        for key, oc, tc in zip(okeys, ocells, tcells):
            if key not in ours_rows or key not in theirs_rows or ours_rows[key][1] != oc or theirs_rows[key][1] != tc:
                raise NotHandled("%s: a conflicted line is not that mod's row in the mods table" % key)
            cells, keep = merge_row(key, base_rows.get(key), ours_rows[key], theirs_rows[key], issue_col, report)
            out.append(flat(cells))
            resolved[key] = cells
            merged_keep[key] = keep
    result = "\n".join(unflatten(out, ours_rows, theirs_rows, merged_keep))
    check_structure(result, ours_rows, theirs_rows, resolved)
    with open(os.path.join(repo, "README.md"), "w", encoding="utf-8", newline="", errors="replace") as f:
        f.write(result)
    return report


def main(argv):
    if len(argv) != 2:
        print("usage: readme-rows-merge.py <repo in the middle of a merge>", file=sys.stderr)
        return UNREAD
    try:
        report = resolve(argv[1])
    except Unread as e:
        print("could not read: %s" % e)
        return UNREAD
    except NotHandled as e:
        print("not handled: %s" % e)
        return NOT_HANDLED
    for line in report:
        print(line)
    print("resolved %d row(s) of README.md's mods table" % len(report))
    return RESOLVED


if __name__ == "__main__":
    sys.exit(main(sys.argv))

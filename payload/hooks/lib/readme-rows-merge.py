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

WHY. Each mod's description is one long line keyed by "| `name` |", so two pull requests touching
one mod conflict on that line, and the issue number list at its end conflicts every time. On
2026-10-28 that stopped #1819, #1835 (twice), #1850 and #1852 in the merge helper, about an hour
each. The rules here are the ones a scratch resolver applied to about ten such conflicts that day,
each checked by hand afterwards and all correct.

THE RULES, for each conflicted hunk:
  - both sides of the hunk are rows of the mods table (the table under the header
    "| Mod | What it does | Issue |"), with the same keys in the same order, and the hunk lies inside
    that table in the merged file; anything else is not handled;
  - per row, compared with the base's row of the same key: the same on both sides is kept; changed
    on one side only takes that side; changed on both is merged cell by cell (cells split on the
    pipes outside code spans, see cells), each cell as for rows when it is the same on both sides
    or changed on one side only, and otherwise word by word: git merge-file over the three versions
    split into words, where a word conflict is resolved only when
      - it is in the Issue cell and each side of it is a run of issue numbers: the union of every
        number the three name, in number order (so a number one side removed in that same spot
        comes back, as the scratch resolver did; a person reads the diff of the update);
      - or both sides inserted text at the same place and one side's insertion begins with the
        other's: the longer is kept;
    a row whose cell count differs from the table's in any version, or a word conflict of any other
    shape, is not handled.

THE RESULT IS CHECKED before it is written (L631): no conflict marker line, the mods table holding
exactly the union of both sides' keys once each, every row with the cell count it has on each side,
and every resolved row with the table's.

CALIBRATED on the real conflicts of 2026-10-28 (17 row merges the scratch resolver recorded): this
gives its result on every one it resolved and refuses the two it refused. Real Issue cells are not
tidy lists ("#607 to #609, #605, ..."), which is why the issue rule works on the conflicting run of
numbers and not on the whole cell.
"""
import os
import re
import subprocess
import sys
import tempfile

RESOLVED, NOT_HANDLED, UNREAD = 0, 10, 2

HEADER = "| Mod | What it does | Issue |"
KEY = re.compile(r"^\| `([^`]+)` \|")
ISSUE_RUN = re.compile(r"^(#\d+,?\s*)+$")
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
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Unread("%s is not UTF-8" % what)


def merge_file(ours, base, theirs, diff3=False):
    """git merge-file over three texts; returns (number of conflicts, merged text)."""
    with tempfile.TemporaryDirectory(prefix="readme-rows-") as d:
        paths = []
        for name, body in (("ours", ours), ("base", base), ("theirs", theirs)):
            p = os.path.join(d, name)
            with open(p, "w", encoding="utf-8", newline="") as f:
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


def cells(row):
    """A row's cells, split on every | that is neither escaped with a backslash nor inside a code
    span. Joined with | they give the row back exactly.

    Code spans count because the real rows put pipes inside them: on 2026-10-29 the mod-kit row
    held 7 pieces split on every |, design-round-guard 15 and scope-modes 6, and every one of the 22
    rows held exactly the table's 5 once code spans were skipped."""
    out, start, i, n = [], 0, 0, len(row)
    while i < n:
        c = row[i]
        if c == "\\":
            i += 2
            continue
        if c == "`":
            j = i
            while j < n and row[j] == "`":
                j += 1
            run = row[i:j]
            close = re.compile(r"(?<!`)%s(?!`)" % re.escape(run)).search(row, j)
            i = close.end() if close else j
            continue
        if c == "|":
            out.append(row[start:i])
            start = i + 1
        i += 1
    out.append(row[start:])
    return out


def mods_table(lines, what):
    """The mods table's rows as an ordered list of (key, line), from a whole file's lines."""
    at = [i for i, l in enumerate(lines) if l == HEADER]
    if len(at) != 1:
        raise NotHandled("%s has %d mods table headers, not one" % (what, len(at)))
    rows, i = [], at[0] + 2
    while i < len(lines) and lines[i].startswith("| "):
        m = KEY.match(lines[i])
        if not m:
            raise NotHandled("%s has a mods table row with no key: %s" % (what, lines[i][:80]))
        rows.append((m.group(1), lines[i]))
        i += 1
    keys = [k for k, _ in rows]
    if len(set(keys)) != len(keys):
        raise NotHandled("%s names a mod twice in its mods table" % what)
    return rows


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
    start = heads[0]
    end = start + 2
    while end < len(segments):
        s = segments[end]
        if s[0] == "line" and not s[1].startswith("| "):
            break
        end += 1
    for n, s in enumerate(segments):
        if s[0] == "hunk" and not (start + 2 <= n < end):
            raise NotHandled("README.md's conflict is not only rows of its mods table: a hunk lies outside it")


def issue_union(so, sb, st):
    """A word conflict inside the Issue cell where each side is a run of issue numbers: every
    number any version names, first seen first, then in number order, as the scratch resolver did
    on 2026-10-28. Keeps our side's surrounding spaces and its trailing comma, which both sides
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


def merge_row(key, base, ours, theirs, issue_col, report):
    if ours == theirs:
        report.append("%s: the same on both sides" % key)
        return ours
    if base is None:
        raise NotHandled("%s: a row both sides added differently, which needs a person" % key)
    if ours == base:
        report.append("%s: took main's change (the branch left it alone)" % key)
        return theirs
    if theirs == base:
        report.append("%s: took the branch's change (main left it alone)" % key)
        return ours
    cb, co, ct = cells(base), cells(ours), cells(theirs)
    if not (len(cb) == len(co) == len(ct) == len(cells(HEADER))):
        raise NotHandled("%s: its number of cells changed, which needs a person" % key)
    out, how = [], []
    for i, (b, o, t) in enumerate(zip(cb, co, ct)):
        if o == t:
            out.append(o)
        elif o == b:
            out.append(t)
        elif t == b:
            out.append(o)
        elif i == issue_col:
            out.append(word_merge(b, o, t, key, issues=True))
            how.append("its issue numbers merged")
        else:
            out.append(word_merge(b, o, t, key))
            how.append("its words merged")
    report.append("%s: both sides changed it, %s" % (key, " and ".join(how) or "cell by cell"))
    return "|".join(out)


def check_structure(result, ours_rows, theirs_rows, resolved):
    """The written file's shape (L631), before anything is written."""
    lines = result.split("\n")
    marked = [l for l in lines if ANY_MARKER.match(l)]
    if marked:
        raise NotHandled("the result still holds a conflict marker line: %s" % marked[0][:80])
    rows = mods_table(lines, "the result")
    want = {k for k, _ in ours_rows} | {k for k, _ in theirs_rows}
    got = [k for k, _ in rows]
    if len(got) != len(want) or set(got) != want:
        raise NotHandled("the result's mods table holds %d rows where both sides together name %d mods" % (len(got), len(want)))
    sides = (dict(ours_rows), dict(theirs_rows))
    for k, line in rows:
        n = len(cells(line))
        for side in sides:
            if k in side and len(cells(side[k])) != n:
                raise NotHandled("%s: the result's row has %d cells where a side's has %d" % (k, n, len(cells(side[k]))))
        if k in resolved and n != len(cells(HEADER)):
            raise NotHandled("%s: the resolved row has %d cells where the table has %d" % (k, n, len(cells(HEADER))))


def resolve(repo):
    base = text(git(repo, "show", ":1:README.md"), "the base README.md")
    ours = text(git(repo, "show", ":2:README.md"), "our README.md")
    theirs = text(git(repo, "show", ":3:README.md"), "their README.md")
    base_rows = dict(mods_table(base.split("\n"), "the base README.md"))
    ours_rows = mods_table(ours.split("\n"), "our README.md")
    theirs_rows = mods_table(theirs.split("\n"), "their README.md")
    issue_col = [c.strip() for c in cells(HEADER)].index("Issue")
    conflicts, merged = merge_file(ours, base, theirs)
    if conflicts == 0:
        raise NotHandled("README.md merges cleanly here, so there is nothing for this to resolve")
    segments = parse(merged)
    check_hunks_in_table(segments)
    ours_lines, theirs_lines = dict(ours_rows), dict(theirs_rows)
    out, report, resolved = [], [], set()
    for s in segments:
        if s[0] == "line":
            out.append(s[1])
            continue
        o, t = s[1], s[2]
        ok, tk = [KEY.match(l) for l in o], [KEY.match(l) for l in t]
        if not o or not all(ok) or not all(tk):
            raise NotHandled("README.md's conflict is not only rows of its mods table: a hunk holds other lines")
        okeys, tkeys = [m.group(1) for m in ok], [m.group(1) for m in tk]
        if okeys != tkeys:
            raise NotHandled("a hunk of the mods table holds different rows on each side (%s against %s), which needs a person" % (", ".join(okeys), ", ".join(tkeys)))
        for key, ol, tl in zip(okeys, o, t):
            if ours_lines.get(key) != ol or theirs_lines.get(key) != tl:
                raise NotHandled("%s: a conflicted line is not that mod's row in the mods table" % key)
            out.append(merge_row(key, base_rows.get(key), ol, tl, issue_col, report))
            resolved.add(key)
    result = "\n".join(out)
    check_structure(result, ours_rows, theirs_rows, resolved)
    with open(os.path.join(repo, "README.md"), "w", encoding="utf-8", newline="") as f:
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

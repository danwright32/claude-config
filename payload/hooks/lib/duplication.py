#!/usr/bin/env python3
"""Duplicated code in a source tree, and what a push ADDS to it (claude-config#428).

    duplication.py scan <tree> [--files-from FILE]
    duplication.py compare <base tree> <pushed tree>

`scan` prints every duplicate group in one tree as JSON, for measuring and for the suite. `compare`
prints the groups the PUSHED tree has that the BASE tree does not, in the words a person reads, and
exits 1 when there are any, 0 when there are none, 2 when a tree could not be read. The hook
(check-duplication.sh) only ever runs `compare`, so the verdict is a comparison and never a stored
baseline: existing duplication never fails a push, and there is no state file to go stale.

Two shapes, because the 2026-09-18 review of Slate found two kinds of copy:

  block   WINDOW_LINES consecutive non-trivial lines whose normalized text appears in BLOCK_COPIES
          or more places (the same day header cell written into two table components). The window's
          combined length must reach WINDOW_CHARS, so two long identical lines count and two short
          ones do not.
  line    one normalized line of at least LINE_CHARS characters appearing LINE_COPIES or more times
          (the same button class string hand written at several sites in one component).

A line is normalized by stripping it, collapsing runs of whitespace, and blanking every `${...}`
template interpolation to `${}`, because the review's class strings differ only in the variable
appended at the end and a detector that saw the variable saw eleven different lines. Trivial lines
(shorter than MIN_LINE_CHARS, only brackets and punctuation, imports, comments including the body
of a block comment) are dropped from the sequence before windows are cut, so `});` between two
copied lines does not hide them and a license header does not count as a copy.

"New" is decided per KEY (a hash of the normalized content) by COUNT, not by presence: a group is
reported when the pushed tree holds MORE copies of that content than the base did. That is what lets
a third copy of a block the base already held twice be caught, while a rename that moves both copies
is not. The cost, stated so nobody rediscovers it: editing every copy of an existing duplicate the
same way produces content the base never held, so it is reported as new, and the remedy is the one
L613 asks for anyway, one shared thing instead of N edited copies.

What it skips, and why: test files (a fixture is copied on purpose), snapshots, lockfiles, generated
and build output, `.d.ts`, files over SIZE_CAP, and anything that is not a code extension. Source
roots are found from the tree itself (`SOURCE_ROOTS`, whichever exist); with none the caller skips
out loud (L98).

The thresholds are gated at REPORT time, never at scan time: `scan_tree` records every candidate,
and `is_group` decides. That is what lets one scan be measured at several settings, and it is how
the numbers in check-duplication.sh's header were produced against Slate main fc7397d7 on
2026-09-18. No dependencies beyond the standard library, on purpose.
"""
import hashlib
import json
import os
import re
import sys

SOURCE_ROOTS = ("src", "app", "lib", "components", "worker", "scripts")

# The thresholds. Each is measured, not guessed; the measurement is in the hook header.
MIN_LINE_CHARS = 20     # shorter lines are trivial and dropped from the sequence
WINDOW_LINES = 2        # a block is judged on windows of this many non-trivial lines
WINDOW_CHARS = 160      # whose combined normalized length is at least this
BLOCK_COPIES = 2        # a block window is a duplicate from this many occurrences
LINE_CHARS = 100        # a single line counts as a copy only from this length
LINE_COPIES = 2         # and only when it appears at least this many times
SIZE_CAP = 256 * 1024   # bytes; a file past this is generated or vendored, not written

CODE_EXT = {
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".sh", ".bash", ".zsh", ".css", ".scss",
    ".sql", ".go", ".rb", ".swift", ".kt", ".java", ".rs", ".vue", ".svelte", ".php", ".cs",
}
SKIP_DIRS = {
    "node_modules", ".next", ".open-next", "dist", "build", "coverage", ".git", "vendor",
    "__tests__", "__snapshots__", "__fixtures__", "fixtures", "snapshots", "generated",
    "__generated__", "__mocks__",
}

_WS = re.compile(r"\s+")
_INTERP = re.compile(r"\$\{[^{}]*\}")
_PUNCT_ONLY = re.compile(r"""^[\s\[\]{}()<>/;,.:'"`=+\-*&|!?\\%]*$""")
_SKIP_LINE = re.compile(
    r"""^(import\b|export\s+(\*|\{[^}]*\})\s+from\b|\}\s*from\s|//|\{?/\*|\*|#|"use (client|server)")"""
)


def is_skipped_file(rel):
    """True for a file the detector deliberately does not read. `rel` uses forward slashes."""
    parts = rel.split("/")
    base = parts[-1]
    if any(p in SKIP_DIRS for p in parts[:-1]):
        return True
    _, ext = os.path.splitext(base)
    if ext not in CODE_EXT:
        return True
    if base.startswith("test-") or base.startswith("test_"):
        return True
    if ".test." in base or ".spec." in base or ".stories." in base:
        return True
    if base.endswith("_test.go") or base.endswith("_test.py") or base.endswith("_spec.rb"):
        return True
    if base.endswith(".d.ts") or ".generated." in base or base.endswith(".min.js"):
        return True
    if base.endswith(".lock") or base.endswith("-lock.json") or base.endswith(".snap"):
        return True
    return False


def normalize(line):
    s = _WS.sub(" ", line.strip())
    prev = None
    while prev != s:
        prev, s = s, _INTERP.sub("${}", s)
    return s


def is_trivial(norm):
    if len(norm) < MIN_LINE_CHARS:
        return True
    if _PUNCT_ONLY.match(norm):
        return True
    if _SKIP_LINE.match(norm):
        return True
    return False


def significant_lines(text):
    """[(line number, normalized text)] for the lines that take part in the comparison.

    The body of a `/* ... */` block comment is dropped along with its opening line: the review's
    tree carries the same five line JSX comment in five admin pages, and prose copied on purpose is
    not the copy this looks for. Only the start of a line is judged, so a `/*` inside a string on a
    code line does not swallow the rest of the file."""
    out = []
    in_block = False
    for i, raw in enumerate(text.split("\n"), 1):
        norm = normalize(raw)
        if in_block:
            if "*/" in norm:
                in_block = False
            continue
        if norm.startswith("/*") or norm.startswith("{/*"):
            if "*/" not in norm:
                in_block = True
            continue
        if not is_trivial(norm):
            out.append((i, norm))
    return out


def _key(kind, text):
    return kind + ":" + hashlib.sha1(text.encode("utf-8")).hexdigest()[:20]


def iter_files(tree, files_from=None):
    """Relative paths under `tree` to read, in sorted order. `files_from` is an explicit list
    (one relative path per line) and, when given, replaces the walk: the hook hands the working tree
    over that way so an ignored file, and nothing outside the source roots, is read."""
    rels = []
    if files_from is not None:
        for line in files_from.read().split("\n"):
            rel = line.strip().replace(os.sep, "/")
            if rel and not is_skipped_file(rel):
                rels.append(rel)
        return sorted(set(rels))
    for root in SOURCE_ROOTS:
        top = os.path.join(tree, root)
        if not os.path.isdir(top):
            continue
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for fn in filenames:
                rel = os.path.relpath(os.path.join(dirpath, fn), tree).replace(os.sep, "/")
                if not is_skipped_file(rel):
                    rels.append(rel)
    return sorted(rels)


def present_roots(tree):
    return [r for r in SOURCE_ROOTS if os.path.isdir(os.path.join(tree, r))]


def read_text(path):
    try:
        if os.path.getsize(path) > SIZE_CAP:
            return None
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    if b"\x00" in data:
        return None
    return data.decode("utf-8", "replace")


def scan_tree(tree, files_from=None):
    """Every occurrence of every candidate key in one tree, before any threshold is applied.

    Returns (occurrences, files_read) where occurrences is
      {key: {"kind": "line"|"block", "text": [normalized lines], "at": [(rel, first, last, idx)]}}
    `idx` is the window's position in the file's sequence of significant lines, so a run of
    adjacent windows can be chained back into one block when it is reported."""
    occ = {}
    files_read = 0
    for rel in iter_files(tree, files_from):
        text = read_text(os.path.join(tree, rel))
        if text is None:
            continue
        files_read += 1
        sig = significant_lines(text)
        for idx, (ln, norm) in enumerate(sig):
            k = _key("line", norm)
            e = occ.setdefault(k, {"kind": "line", "text": [norm], "at": []})
            e["at"].append((rel, ln, ln, idx))
            if idx + WINDOW_LINES <= len(sig):
                win = sig[idx: idx + WINDOW_LINES]
                joined = "\n".join(n for _, n in win)
                k = _key("block", joined)
                e = occ.setdefault(k, {"kind": "block", "text": [n for _, n in win], "at": []})
                e["at"].append((rel, win[0][0], win[-1][0], idx))
    return occ, files_read


def is_group(entry, line_chars=None, line_copies=None, window_chars=None, block_copies=None):
    """Does this key, at this count, count as a duplicate group? The keyword arguments exist so a
    measurement can ask at another setting; the hook always asks at the module's."""
    n = len(entry["at"])
    if entry["kind"] == "line":
        return (len(entry["text"][0]) >= (line_chars or LINE_CHARS)
                and n >= (line_copies or LINE_COPIES))
    return (sum(len(t) for t in entry["text"]) >= (window_chars or WINDOW_CHARS)
            and n >= (block_copies or BLOCK_COPIES))


def groups(occ, **thresholds):
    return {k: e for k, e in occ.items() if is_group(e, **thresholds)}


def new_groups(base_occ, pushed_occ, **thresholds):
    """The keys whose copy count GREW, among those that are groups in the pushed tree."""
    out = {}
    for k, e in pushed_occ.items():
        if not is_group(e, **thresholds):
            continue
        before = len(base_occ.get(k, {"at": []})["at"])
        if len(e["at"]) > before:
            out[k] = (e, before)
    return out


def _merge_block_runs(new):
    """Adjacent new block windows with the SAME occurrence set are one finding, not one per window.

    Two identical 6 line blocks are five overlapping 2 line windows; naming five findings for one
    copy would make the message five times longer than the fault. Windows are chained while every
    occurrence steps forward together into another new window with the same number of copies."""
    starts = {}
    for k, (e, _before) in new.items():
        if e["kind"] == "block":
            for rel, _first, _last, idx in e["at"]:
                starts[(rel, idx)] = k
    consumed = set()
    runs = []
    for k in sorted(new, key=lambda kk: sorted(new[kk][0]["at"])):
        e, before = new[k]
        if e["kind"] != "block" or k in consumed:
            continue
        consumed.add(k)
        ats = sorted(e["at"])
        text = list(e["text"])
        while True:
            nxt = {starts.get((rel, idx + 1)) for rel, _f, _l, idx in ats}
            if len(nxt) != 1:
                break
            nk = nxt.pop()
            if nk is None or nk in consumed:
                break
            ne = new[nk][0]
            if len(ne["at"]) != len(ats):
                break
            consumed.add(nk)
            text.append(ne["text"][-1])
            ends = {(r, i): l for r, _f, l, i in ne["at"]}
            ats = [(rel, first, ends[(rel, idx + 1)], idx + 1) for rel, first, _l, idx in ats]
        runs.append({"kind": "block", "text": text,
                     "at": [(r, f, l) for r, f, l, _i in ats], "before": before})
    return runs


def findings(base_occ, pushed_occ, **thresholds):
    """The new groups as a list of dicts, blocks merged into runs, lines as they are, ordered by
    how many copies they have, most first."""
    new = new_groups(base_occ, pushed_occ, **thresholds)
    out = _merge_block_runs(new)
    # A line finding whose every site lies inside a reported block is the same copy said twice
    # (seen on Slate 2cddc905: the block's first line was also named on its own), so it is dropped.
    # A line copied somewhere OUTSIDE any block keeps its own finding, because that site is news.
    spans = [(r, f, l) for b in out for r, f, l in b["at"]]

    def inside_block(rel, line):
        return any(r == rel and f <= line <= l for r, f, l in spans)

    for k, (e, before) in new.items():
        if e["kind"] == "line":
            sites = sorted((r, f, l) for r, f, l, _i in e["at"])
            if all(inside_block(r, f) for r, f, _l in sites):
                continue
            out.append({"kind": "line", "text": list(e["text"]), "at": sites, "before": before})
    out.sort(key=lambda f: (-len(f["at"]), f["at"][0]))
    return out


def format_findings(found, limit=12):
    lines = []
    for i, f in enumerate(found[:limit], 1):
        n = len(f["at"])
        if f["kind"] == "block":
            what = "the same %d line block" % len(f["text"])
        else:
            what = "the same line"
        was = "the base had %d" % f["before"] if f["before"] else "the base had none"
        lines.append("  %d. %d copies of %s (%s):" % (i, n, what, was))
        for rel, first, last in f["at"][:8]:
            where = "%s:%d" % (rel, first) if first == last else "%s:%d-%d" % (rel, first, last)
            lines.append("       %s" % where)
        if n > 8:
            lines.append("       ... and %d more" % (n - 8))
        for t in f["text"][:4]:
            lines.append("       | %s" % (t[:140] + (" ..." if len(t) > 140 else "")))
        if len(f["text"]) > 4:
            lines.append("       | ... %d more lines" % (len(f["text"]) - 4))
    if len(found) > limit:
        lines.append("  ... and %d more groups" % (len(found) - limit))
    return "\n".join(lines)


def _open_list(path):
    if path is None:
        return None
    if path == "-":
        return sys.stdin
    return open(path, "r", encoding="utf-8")


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().split("\n")[0], file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "scan":
        tree = argv[2] if len(argv) > 2 else None
        files_from = None
        if "--files-from" in argv:
            files_from = _open_list(argv[argv.index("--files-from") + 1])
        if not tree or not os.path.isdir(tree):
            print("duplication.py: no such tree: %r" % tree, file=sys.stderr)
            return 2
        occ, files_read = scan_tree(tree, files_from)
        gs = groups(occ)
        print(json.dumps({
            "files": files_read,
            "roots": present_roots(tree),
            "groups": [
                {"key": k, "kind": e["kind"], "copies": len(e["at"]), "text": e["text"],
                 "at": sorted([r, f, l] for r, f, l, _i in e["at"])}
                for k, e in sorted(gs.items(), key=lambda kv: (-len(kv[1]["at"]), kv[0]))
            ],
        }, indent=1))
        return 0
    if cmd == "roots":
        # Top level names on stdin (one per line, as `git ls-tree --name-only` prints them); prints
        # the ones that are source roots, in SOURCE_ROOTS order. The hook asks this rather than
        # holding its own copy of the list, so the roots it archives are the roots this reads.
        names = {line.strip() for line in sys.stdin.read().split("\n")}
        for r in SOURCE_ROOTS:
            if r in names:
                print(r)
        return 0
    if cmd == "root-names":
        print(", ".join(SOURCE_ROOTS))
        return 0
    if cmd == "compare":
        if len(argv) < 4:
            print("duplication.py compare <base tree> <pushed tree>", file=sys.stderr)
            return 2
        base, pushed = argv[2], argv[3]
        for t in (base, pushed):
            if not os.path.isdir(t):
                print("duplication.py: no such tree: %r" % t, file=sys.stderr)
                return 2
        base_occ, _ = scan_tree(base)
        pushed_occ, files_read = scan_tree(pushed)
        found = findings(base_occ, pushed_occ)
        print("files=%d roots=%s groups=%d new=%d" % (
            files_read, ",".join(present_roots(pushed)) or "-", len(groups(pushed_occ)), len(found)))
        if found:
            print(format_findings(found))
            return 1
        return 0
    print("duplication.py: unknown command %r" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

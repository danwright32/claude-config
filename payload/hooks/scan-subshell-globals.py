#!/usr/bin/env python3
"""Functions that answer into a global every caller reads in a subshell (claude-config#372).

lesson_index_entry_cap recorded "this hook exists but carries no cap" in a shared variable, while
every call site read the function through a command substitution. That is a subshell, so the
assignment was discarded on return and the warning it fed could never fire, with the code setting
it reading as entirely correct. The tests caught it; inspection would not have.

WHAT IT LOOKS FOR: a shell function that assigns a name it has not declared `local`, where EVERY
call site reads it through `$(...)` or backticks. A function also called plainly somewhere is not
condemned: answering into a global is a legitimate design when the caller is in the same shell, and
this repo has such functions on purpose (lesson_band_locked is one, and its comment says why).

The remedy in each case is to answer in the RETURN VALUE instead.

An env prefix (`VAR=value cmd`) is not an assignment to anything and is not counted: it is the
commonest line shape in these suites and counting it reported 35 functions of which 27 were that.
A line inside a heredoc is not shell at all and is skipped for the same reason.

Measured over this repo on 2026-09-11: 8 functions flagged, of which one was a real defect
(tip_payload_dir's caller could never see TIP_PAYLOAD_DIR, so the scratch directory holding the
whole shared payload was never removed) and the rest were a missing `local` on a private variable,
which leaks outward rather than losing the answer. So a finding is a prompt to read, and the
baseline records the reason each surviving one was accepted (L233).

A RATCHET rather than a gate on the whole backlog: the count may not grow, and a count that is no
longer real has to come down, or a number nobody has to tighten becomes a permanent allowance
(L182).
"""
import argparse
import os
import re
import shlex
import sys

FN_DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
DECLARED = re.compile(r"^\s*(local|declare|typeset|export|readonly)\s+(.*)$")
ASSIGN_TOKEN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")
HEREDOC = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")


def assignments_on(line):
    """Names this line assigns as SHELL VARIABLES.

    A line of nothing but assignments assigns them. A line where a command follows assigns
    nothing: `CLAUDE_HOME=x bash prog` sets a variable in the child's environment and leaves this
    shell untouched, and treating it as an assignment is what made the first measurement of this
    scan four times too large.
    """
    s = line.strip()
    if not s or s.startswith("#"):
        return []
    try:
        toks = shlex.split(s, posix=True)
    except ValueError:
        return []
    names = []
    for t in toks:
        if ASSIGN_TOKEN.match(t):
            names.append(t.split("=", 1)[0].split("[")[0].rstrip("+"))
        else:
            return []
    return names


def functions_in(lines):
    """-> [(name, first line, body lines)], skipping heredoc bodies, which are not shell."""
    out = []
    i = 0
    while i < len(lines):
        m = FN_DEF.match(lines[i])
        if not m:
            i += 1
            continue
        depth = lines[i].count("{") - lines[i].count("}")
        body = []
        j = i + 1
        heredoc_end = None
        while j < len(lines) and depth > 0:
            line = lines[j]
            if heredoc_end is not None:
                if line.strip() == heredoc_end:
                    heredoc_end = None
                j += 1
                continue
            hm = HEREDOC.search(line)
            if hm:
                heredoc_end = hm.group(1)
                depth += line.count("{") - line.count("}")
                j += 1
                continue
            body.append(line)
            depth += line.count("{") - line.count("}")
            j += 1
        out.append((m.group(1), i + 1, body))
        i = j
    return out


def scan_file(path):
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except OSError as e:
        # A file this cannot OPEN is not a file with nothing in it. Returning "nothing judged, no
        # findings" makes an unreadable file indistinguishable from a clean one, and the count it
        # feeds is the whole verdict (L10, L11, L215). Reported and counted as a finding, so a
        # tree that has become unreadable fails rather than quietly shrinking what is scanned.
        print("  %s: could not be read (%s), so nothing in it was judged" % (path, e), file=sys.stderr)
        return 0, [(0, "UNREADABLE", ["the file could not be read"])]
    considered = 0
    found = []
    for name, at, body in functions_in(lines):
        declared = set()
        globals_set = set()
        for b in body:
            dm = DECLARED.match(b)
            if dm:
                for tok in dm.group(2).split():
                    declared.add(tok.split("=")[0])
                continue
            for nm in assignments_on(b):
                if nm not in declared:
                    globals_set.add(nm)
        if not globals_set:
            continue
        considered += 1
        word = re.escape(name)
        calls = [l for k, l in enumerate(lines)
                 if re.search(r"(^|[^A-Za-z0-9_])" + word + r"([^A-Za-z0-9_(]|$)", l)
                 and not FN_DEF.match(l) and not l.strip().startswith("#")]
        if not calls:
            continue
        captured = [l for l in calls
                    if re.search(r"\$\([^)]*\b" + word + r"\b", l) or re.search(r"`[^`]*\b" + word + r"\b", l)]
        if len(captured) == len(calls):
            found.append((at, name, sorted(globals_set)))
    return considered, found


def read_baseline(path):
    counts = {}
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return None
    for line in text.split("\n"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.rsplit(":", 1)
        if len(parts) != 2 or not parts[1].strip().isdigit():
            continue
        counts[parts[0].strip()] = int(parts[1])
    return counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--baseline", default=None)
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    baseline_path = args.baseline or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "subshell-globals.txt")

    files = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "__pycache__")]
        for nm in names:
            if nm.endswith(".sh") or nm == "claude-sync":
                files.append(os.path.join(base, nm))
    files.sort()
    if not files:
        print("scan-subshell-globals: found no shell sources under %s, so nothing was scanned."
              % root, file=sys.stderr)
        return 2

    considered = 0
    now = {}
    detail = {}
    for f in files:
        c, found = scan_file(f)
        considered += c
        if found:
            rel = os.path.relpath(f, root)
            now[rel] = len(found)
            detail[rel] = found

    base = read_baseline(baseline_path)
    if base is None:
        print("scan-subshell-globals: no baseline at %s, so there is nothing to compare against "
              "and nothing was verified." % baseline_path, file=sys.stderr)
        return 2

    print("scan-subshell-globals: %d function(s) that set a name they did not declare, across "
          "%d file(s); %d of them are read only through a subshell."
          % (considered, len(files), sum(now.values())))
    for rel in sorted(detail):
        for at, name, names in detail[rel]:
            if name == "UNREADABLE":
                print("  %s  could not be read, so nothing in it was judged" % rel)
            else:
                print("  %s:%d  %s sets %s" % (rel, at, name, ", ".join(names)))

    grew = [(r, base.get(r, 0), c) for r, c in sorted(now.items()) if c > base.get(r, 0)]
    shrank = [(r, base[r], now.get(r, 0)) for r in sorted(base) if base[r] > now.get(r, 0)]
    rc = 0
    if grew:
        print("\nFAIL: a file has gained a function that answers into a global while every caller "
              "reads it in a subshell, where that assignment is discarded on return. Answer in the "
              "return value instead.")
        for r, b, c in grew:
            print("  %s: %d, was %d" % (r, c, b))
        rc = 1
    if shrank:
        print("\nFAIL: the baseline claims findings a file no longer has, so a number here is "
              "stale. Lower it in the same change.")
        for r, b, c in shrank:
            print("  %s: %d, baseline says %d" % (r, c, b))
        rc = 1
    if rc == 0:
        print("scan-subshell-globals: every finding is one the baseline already records.")
    return rc


if __name__ == "__main__":
    sys.exit(main())

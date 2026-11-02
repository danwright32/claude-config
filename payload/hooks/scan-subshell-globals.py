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

Where a function begins and ends is read through lib/shell_code_lines.py, the reader the other
whole tree scans share, in one pass per file (L297): braces are counted only on the shell's own
code, never inside a quoted string, a comment or a heredoc, and a function is found only where its
definition is code. Before that, a `{` inside a python3 -c string left a function open to the end
of the file, and every assignment after it was charged to that function (claude-config#2063). A
brace in a bracket expression is not counted either (claude-config#2068).

What a function's body assigns is read through lib/shell-words.py commands(), the one reading of a
command the gates share, over the body whole (claude-config#2076). Read a line at a time by shlex,
an assignment followed by a comment, one with quotes nested in its `$( )`, the first line of one
running over several lines, one mid line and one on the line defining the function were never
judged. Only a command this shell runs is judged, so nothing in a pipeline, a subshell group, a
substitution or the background is. A body the reader cannot read is listed on every run with its
file, line and reason, and the count is said, zero too; it does not fail the scan on its own.

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
import importlib.util
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/lib")
import ratchet  # noqa: E402  the one rule a count based ratchet applies (claude-config#377)
from shell_code_lines import brace_depth, read_lines  # noqa: E402  the one reader of shell quoting (#2063)

# The one reading of a command, lib/shell-words.py, loaded by its path beside this file as
# gh_issue_scan.py loads it (claude-config#2076). READER_ERROR is None once it loads, else what went
# wrong, and then main refuses: this keeps no reading of its own to fall back on, since one that
# misread an assignment would report a tree it never judged as clean.
READER_ERROR = None
try:
    _spec = importlib.util.spec_from_file_location(
        "shell_words", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "shell-words.py"))
    _sw = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_sw)
    commands, split_assignments, Unreadable = _sw.commands, _sw.split, _sw.Unreadable
    RESERVED, command_words = _sw.RESERVED, _sw.command_words
except Exception as e:  # noqa: BLE001  missing, or failing to load: either way there is no reader
    READER_ERROR = "%s: %s" % (type(e).__name__, e)

FN_DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
DECLARES = {"local", "declare", "typeset", "export", "readonly"}
# An assignment word's name, as the shell allows it: `n=`, `n+=`, `arr[i]=`, `arr[i]+=`. The value
# after it is read by shell-words split(), which knows quotes and $( ) nesting but takes only `n=`.
ASSIGN_WORD = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?=")


def assigned_names(text):
    """Names one simple command assigns as SHELL VARIABLES, or [] when a command follows them.

    A command of nothing but assignments assigns them. One where a command follows assigns nothing:
    `CLAUDE_HOME=x bash prog` sets a variable in the child's environment and leaves this shell
    untouched, and treating it as an assignment is what made the first measurement of this scan four
    times too large. Each value is read by shell-words split(), so a value holding a comment's `#`,
    quotes nested in a `$( )`, spaces in a `$(( ))` or a line break is one value, as the shell reads
    it (claude-config#2076); `+=` and a subscript are read here, since split() takes `n=` alone.
    """
    names, s = [], text.lstrip()
    while True:
        m = ASSIGN_WORD.match(s)
        if not m:
            break
        one, s = split_assignments(m.group(1) + "=" + s[m.end():])
        names.extend(a.split("=", 1)[0] for a in one)
    return names if names and not s.strip() else []


def declared_names(rest):
    """Names a declaration's words declare: `local a b=1 -r c` declares a, b and c.

    Each word is cut at `=` and at `[`, so `n=0` and `arr[1]=x` declare `n` and `arr`, and option
    words like `-a` declare nothing. The words inside `( )` are VALUES, an array's members or a
    substitution's command, never names, so `list=(two LEAKED)` declares list alone (lessons review
    of #1103). Innermost groups first, until none is left.
    """
    while True:
        bare = re.sub(r"\([^()]*\)", "", rest)
        if bare == rest:
            break
        rest = bare
    names = []
    for w in command_words(rest):
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", w)
        if m and not w.startswith("-"):
            names.append(m.group(0))
    return names


def functions_in(lines):
    """-> [(name, first line, body)]: each function's bounds, found by counting its braces, and the
    text of its body, from just past the `{` that opens it to the end of the line that closes it.

    Only braces that are the shell's own are counted (claude-config#2063). One literal `{` inside the
    Python of a `python3 -c` string in ps_payload_text made this read the function as running to the
    end of lib/push-scope.sh and report 23 globals it never touches, and a `}` in a string ends one
    early, so a global set below it is never seen. So the braces are counted in each line's code
    alone, as the one shared reader of shell quoting gives it (lib/shell_code_lines.py): single,
    double and $'...' quoted text, comments and escapes left out, and a heredoc's body neither
    counted nor searched for a function. Read in one walk over the file (L297).

    Nor is a brace in a bracket expression (claude-config#2068): the `{` in mt_is_interpreter's case
    label `'$'[A-Za-z_{]*)` in lib/merge-target.sh left it open for the 1890 lines to the end of the
    file, so no function below it was ever found or judged.

    The body is the text as written, quotes, comments and heredocs included, since function_globals
    reads it as the shell does, whole (claude-config#2076). It begins on the defining line, so
    `remember(){ ... || keep="${keep:+$keep` is read from its first command, where a body read from
    the next line began inside that string and judged none of it.
    """
    read = list(read_lines("\n".join(lines)))
    out = []
    i = 0
    while i < len(read):
        _, line, kind, bare, _ = read[i]
        m = FN_DEF.match(line) if kind == "code" else None
        if not m:
            i += 1
            continue
        depth = brace_depth(bare)
        j = i + 1
        while j < len(read) and depth > 0:
            _, _, kind, bare, _ = read[j]
            if kind in ("code", "quoted"):
                depth += brace_depth(bare)
            j += 1
        out.append((m.group(1), i + 1, "\n".join([line[m.end():]] + lines[i + 1:j]) + "\n"))
        i = j
    return out


def unreadable_reason(e, body, at):
    """What the reader could not close in a function body defined on line `at`, in words."""
    if e.at is None:
        return "a substitution, group or heredoc opened in it never closes"
    return "the quote opened on line %d never closes" % (at + body.count("\n", 0, e.at))


def function_globals(lines):
    """-> [(name, first line, the names it sets without declaring them, why it was unreadable)], one
    for every function. A function whose body shell-words cannot read has None for its names and the
    reader's reason beside it, so the caller can say so; every other has None for the reason.

    Every simple command of the body is read by shell-words commands() (claude-config#2076), the
    one reading of a command the gates share, which knows quotes, $( ) nesting, comments and
    heredocs. Read a line at a time by shlex, an assignment followed by a comment, one holding
    quotes nested in a `$( )`, the first line of one running over several lines, and any not at the
    start of its line (after `&&`, after `then`) were never judged at all.

    Only a command this shell runs is judged: one inside a `$( )`, a backquote or a `( )` group runs
    in a subshell, and so does every member of a pipeline and a command sent to the background, so
    what they set is gone when they end. A reserved word opening a compound command (`then`, `do`,
    `{`) is looked past, as command_words looks past it. A line of a heredoc, or of a `sh -c '...'`
    or `python3 -c '...'` program, is inside one command's text and is never a command here.
    """
    out = []
    for name, at, body in functions_in(lines):
        parts = []
        try:
            cmds = commands(body, parts=parts)
        except Unreadable as e:
            out.append((name, at, None, unreadable_reason(e, body, at)))
            continue
        declared, globals_set = set(), set()
        piped = False
        for (_, text), p in zip(cmds, parts):
            if len(p["scope"]) != 1:
                continue
            in_pipeline, piped = piped or p["how"] == "|", p["how"] == "|"
            if in_pipeline or p["how"] == "&":
                continue
            words = text.split(None, 1)
            while words and words[0] in RESERVED:
                words = words[1].split(None, 1) if len(words) > 1 else []
            if not words:
                continue
            if words[0] in DECLARES:
                declared.update(declared_names(words[1] if len(words) > 1 else ""))
                continue
            for nm in assigned_names(" ".join(words)):
                if nm not in declared:
                    globals_set.add(nm)
        out.append((name, at, globals_set, None))
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
        return 0, [(0, "UNREADABLE", ["the file could not be read"])], []
    considered = 0
    found = []
    unread = []
    for name, at, globals_set, why in function_globals(lines):
        if why is not None:
            unread.append((at, name, why))
            continue
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
    return considered, found, unread


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--baseline", default=None)
    args = ap.parse_args()
    if READER_ERROR is not None:
        print("scan-subshell-globals: the command reader lib/shell-words.py could not be loaded (%s), "
              "so no assignment could be read and nothing was judged." % READER_ERROR, file=sys.stderr)
        return 2
    root = os.path.abspath(args.root)
    baseline_path = args.baseline or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "subshell-globals.txt")

    # Paths are keyed from the checkout, never from --root, so one tree gives one verdict
    # whichever folder of it was named (claude-config#443).
    keyed_from = ratchet.anchor(root)

    files = []
    for base, dirs, names in os.walk(root):
        # A nested checkout is a SECOND COPY of the same tree, so a default recursive walk counts its
        # files as though they were this repository's own (L234). Measured 2026-09-19 with two
        # worktrees open under .claude/worktrees: 166 shell files became 498, every count here
        # roughly tripled, and this ratchet went red on a tree nobody had changed. That is what
        # made `claude-sync recheck` record the same installed config as broken from one checkout
        # and healthy from another (claude-config#504).
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "__pycache__", "worktrees")]
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
    unread = []
    for f in files:
        c, found, cannot = scan_file(f)
        considered += c
        rel = os.path.relpath(f, keyed_from).replace(os.sep, "/")
        if found:
            now[rel] = len(found)
            detail[rel] = found
        unread.extend((rel, at, name, why) for at, name, why in cannot)

    try:
        base = ratchet.read_baseline(open(baseline_path, encoding="utf-8", errors="replace").read())
    except OSError:
        base = None
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
    # A body the command reader cannot read is listed on every run, never skipped in silence, and
    # the count is said when it is zero too, so a run that judged everything says so (#2076). It
    # does not fail the scan: the limit is the reader's, and the shell may read the code fine.
    print("scan-subshell-globals: the command reader could not read %d function bod%s, so %s not judged%s"
          % (len(unread), "y" if len(unread) == 1 else "ies", "it was" if len(unread) == 1 else "they were",
             ":" if unread else "."))
    for rel, at, name, why in unread:
        print("  %s:%d  %s: %s" % (rel, at, name, why))

    base, outside = ratchet.within(base, root, keyed_from)
    if outside:
        print("%s: %d baseline entr%s outside %s, so not judged: %s"
              % ("scan-subshell-globals", len(outside), "y lies" if len(outside) == 1 else "ies lie",
                 root, ", ".join(outside)))
    grown, stale = ratchet.verdict(base, now)
    rc = 0
    if grown:
        print("\nFAIL: a file has gained a function that answers into a global while every caller "
              "reads it in a subshell, where that assignment is discarded on return. Answer in the "
              "return value instead.")
        for r, b, c in grown:
            print("  %s: %d, was %d" % (r, c, b))
        rc = 1
    if stale:
        print("\nFAIL: the baseline claims findings a file no longer has, so a number here is "
              "stale. Lower it in the same change.")
        for r, b, c in stale:
            print("  %s: %d, baseline says %d" % (r, c, b))
        rc = 1
    if rc == 0:
        print("scan-subshell-globals: every finding is one the baseline already records.")
    return rc


if __name__ == "__main__":
    sys.exit(main())

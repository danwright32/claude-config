#!/usr/bin/env bash
# What the flattened form hides is a SECOND READING, never written into the first
# (lib/shell-words.py flattened() and second_reading(), claude-config#3739).
#
# A command after a heredoc's opener on its line, or split across a backslash and a line break in
# a wrapper's string or inside backquotes, was hidden from every hook reading the flattened form.
# The reader writes the command again so that form shows it. Joined into one text with the old
# one, each changed how a hook read the other, so the two are kept apart: a hook judges the old
# text alone, as it always did, and then the rewritten one in a run of its own.
#
# What this suite holds, for every text of a family of made up commands:
#   B1  the first reading is the text a hook was handed before any second reading existed, byte
#       for byte (worked out here by a copy of how it was made then);
#   B2  a second reading is read to its end, names a command the first does not, and is no part
#       of the first, nor the first of it;
#   A4  the rewrite of opener lines made in one pass gives what one line at a time gives.
# And, row by row, that the commands the rewrite exists to show are shown, in the folder they run
# in, and that a string no shell reads is left as typed.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW="$DIR/lib/shell-words.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/flatten-adds.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

echo "the flattened form: what it hides is a second reading, never written into the first (claude-config#3739)"

# One line for each check: "ok<TAB>description" or "FAIL<TAB>description<TAB>why".
python3 -B - "$SW" > "$T/rows.tsv" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("shell_words", sys.argv[1])
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)

BREAK = "; "
J = "\\\n"
# The << of every opener below is put together when this runs, so no text of this file is a
# heredoc's opener line to anything that reads the file's strings as they are written: a case
# written out in full, or as a sum of strings, is a text the drafts gate reads and cannot follow
# (a heredoc on one line), and no session could then run this suite by name
# (test-slack-drafts-comment-start.sh holds every suite of the reader to that).
LT = "<"
LL = LT * 2
PUSH = "git push"


ROWS = [0]


def row(what, why=""):
    what = what.replace("\t", " ").replace("\n", " ")
    why = why.replace("\t", " ").replace("\n", "\\n")
    ROWS[0] += 1
    sys.stdout.write(("FAIL\t%s\t%s\n" % (what, why)) if why else ("ok\t%s\n" % what))


def old_text(s):
    """What a hook was handed before any second reading existed: the plain flattening, or the
    join of #3470. A copy of how flattened() was written then, so B1 is held against it and not
    against the function under test."""
    plain = s.replace("\n", BREAK)
    if J not in s:
        return plain
    joined, unsure = [], []
    try:
        sw.commands(s, unsure=unsure, joined=joined)
    except sw.Unreadable:
        return plain
    if [m for m in unsure if not sw.split_operator(s, m[0])] or not joined:
        return plain
    kept, at = [], 0
    for i in sorted(set(joined)):
        kept.append(s[at:i])
        at = i + 2
    kept.append(s[at:])
    joint = "".join(kept).replace("\n", BREAK)
    was, now = sw._named(plain), sw._named(joint)
    if was is None or now is None:
        return plain
    if not sw._named_more(was, now):
        return joint
    if not sw._named_more(now, was):
        return plain
    both = joint + BREAK + plain
    held_ = sw._named(both)
    either = {k: max(was.get(k, 0), now.get(k, 0)) for k in set(was) | set(now)}
    return both if held_ is not None and not sw._named_more(either, held_) else plain


def held(text):
    """A count of every record read mode gives a hook for a flattened text, each with every field
    it prints but the blanks in front of the command's text."""
    out, _ = sw.read(text)
    count = {}
    for line in out.split("\x1e"):
        if line:
            f = line.split("\x1c")
            f[1] = f[1].lstrip()
            key = "\x1c".join(f)
            count[key] = count.get(key, 0) + 1
    return count


def named(text):
    """(folder, tool, subcommand, arguments) of each git, gh or rtk command a flattened text's
    reading gives a hook; nothing for no text."""
    if text is None:
        return []
    out, _ = sw.read(text)
    found = []
    for line in out.split("\x1e"):
        if line:
            f = line.split("\x1c")
            tool = f[7].split("\x1d")
            if tool[0]:
                found.append((f[0], tool[0], tool[1] if len(tool) > 1 else "", tool[3].replace("\x1f", " ") if len(tool) > 3 else ""))
    return found


def faults(cmd):
    """Why the two readings of cmd break B1 or B2; nothing where they hold them, and None where
    there is no second reading and the first holds B1."""
    was, first, second = old_text(cmd), sw.flattened(cmd), sw.second_reading(cmd)
    if first != was:
        return "B1: the first reading is %r, and the text a hook was always handed is %r" % (first, was)
    if second is None:
        return None
    if second in first or first in second:
        return "B2: one reading is written into the other: first %r, second %r" % (first, second)
    if sw._records(second, "", 0, fields=False)[1]:
        return "B2: the second reading %r is one only the crude cut reads" % second
    before, after = held(first), held(second)
    if not [k for k, n in after.items() if n > before.get(k, 0)]:
        return "B2: the second reading %r names nothing the first, %r, does not" % (second, first)
    return ""


def one_line_at_a_time(s):
    """The slow way to the text opener_lines() gives: the first rewrite the reading finds, then
    the whole text read again, with no limit. The oracle for A4."""
    text = s
    while True:
        met = []
        try:
            sw.commands(text, lines=met, typed=True)
        except sw.Unreadable:
            pass
        rewritten = None
        for k, (kind, i, n) in enumerate(met):
            if kind != "after":
                continue
            ends = next((e for e in met[k + 1:] if e[0] != "after"), None)
            if ends is None:
                continue
            if ends[0] in ("end", "open"):
                rewritten = text
                for at in sorted(ends[2], reverse=True):
                    rewritten = rewritten[:at] + LL + LT + rewritten[at + (3 if rewritten.startswith(LL + "-", at) else 2):]
            else:
                start, end = ends[2][0][0], ends[2][n - 1][1]
                rewritten = text[:i] + text[start:end] + "\n" + text[i + len(BREAK):start] + text[end:]
            break
        if rewritten is None:
            return text if text != s else None
        text = rewritten


# ---- the family ----------------------------------------------------------------------------
FRONTS = ["", "cd a; ", PUSH + " origin main; ", "echo 'q" + J + "r'; "]
BACKS = ["", "\nls", "; SKIP_X=1", "\nSKIP_X=1 true", " # note", "\ncd b; " + PUSH, "\ntrue \\", "\ncat " + LL + "E\\"]
SHAPES = [
    "cat " + LL + "EOF; %s\nbody\nEOF",
    "cat " + LL + "'EOF'; %s\nbody\nEOF",
    "cat " + LL + "-EOF; %s\n\tbody\n\tEOF",
    "cat " + LL + "A " + LL + "B; %s\none\nA\ntwo\nB",
    "cat " + LL + "A; cat " + LL + "B; %s\none\nA\ntwo\nB",
    "cat " + LL + "EOF; cd b; %s\nbody\nEOF",
    "cat " + LL + "EOF; %s; EOF",
    "cat " + LL + "EOF; %s; EOF\n",
    "x=$(cat " + LL + "EOF; %s\nbody\nEOF\n)",
    "( cat " + LL + "EOF; %s\nbody\nEOF\n)",
    "cat " + LL + "EOF; echo a\n$(cat " + LL + "X; %s\nin\nX\n)\nEOF",
    "bash -c 'cat " + LL + "EOF; %s\nbody\nEOF'",
    "bash -c 'cat " + LL + "EOF; %s; EOF'",
    "bash -c 'true # c" + J + "%s'",
    "bash -c 'true # c" + J + "%s; l" + J + "s'",
    "bash -c 'cat " + LL + "\\E\nx" + J + "E\n%s\ncat " + LL + "\\E\nE\nl" + J + "s'",
    "bash -c 'true; %s'",
    "eval 'true; %s'",
    "sh -c \"true; %s\"",
    "bash -c 'bash -c \"true # c" + J + "%s\"'",
    "x=`true; %s`",
    "echo \"`true; %s`\"",
    "echo 'x %s y'",
    "git commit -m 'x %s y'",
    "ssh host 'true; %s'",
]
ACTS = [
    PUSH, "git " + J + "push", "gi" + J + "t push origin main", PUSH + " origin " + J + "main", "git add -A",
    "git \\" + J + "push", "git \\\\" + J + "push", "git \\\\\\" + J + "push", "git \\\\\\\\" + J + "push",
    "SKIP_" + J + "X=1 " + PUSH, "SKIP_X=" + J + "1 " + PUSH, "SKIP_X" + J + "=1 " + PUSH, "SKIP_X=1" + J + " " + PUSH,
    "SKIP_" + J + "Y_" + J + "X=1 true", "SKIP_X=1 " + PUSH, "A=" + J + "b " + PUSH, "echo SKIP_" + J + "X=1",
    "gh pr " + J + "create --fill", "git status",
]
family = [front + shape % act + back for front in FRONTS for shape in SHAPES for act in ACTS for back in BACKS]
broken, seconds, differ = "", 0, ""
for cmd in family:
    try:
        why = faults(cmd)
    except Exception as e:  # a crash is a fault of the text that caused it, never a pass
        why = "the reader raised %s: %s" % (type(e).__name__, e)
    if why and not broken:
        broken = "%r: %s" % (cmd, why)
    seconds += why is not None
    if LL in cmd and not differ and sw.opener_lines(cmd) != one_line_at_a_time(cmd):
        differ = "%r: one pass gave %r, one line at a time %r" % (cmd, sw.opener_lines(cmd), one_line_at_a_time(cmd))
row("B1 and B2: over the family of %d texts, the first reading is the text a hook was always handed, and a second reading is read to its end, names a command the first does not and is never written into it" % len(family), broken)
row("A4: over the same family, opener lines rewritten in one pass are what one line at a time gives", differ)
row("the family is not read as holding nothing throughout: at least a third of it has a second reading",
    "" if seconds * 3 >= len(family) else "only %d of %d texts have a second reading" % (seconds, len(family)))

# ---- row by row ------------------------------------------------------------------------------
def shows(what, cmd, want, where="second"):
    """The reading named (first, second, or either) of cmd names want, a (folder, tool,
    subcommand, arguments)."""
    first, second = sw.flattened(cmd), sw.second_reading(cmd)
    got = {"first": named(first), "second": named(second), "either": named(first) + named(second)}[where]
    row(what, "" if want in got else "wanted %r among %r, from first %r and second %r" % (want, got, first, second))


def hides(what, cmd, tool, sub):
    """Neither reading of cmd names a command of that tool and subcommand."""
    first, second = sw.flattened(cmd), sw.second_reading(cmd)
    got = [g for g in named(first) + named(second) if g[1] == tool and g[2] == sub]
    row(what, "" if not got else "it names %r, from first %r and second %r" % (got, first, second))


def readings_are(what, cmd, first, second):
    got = (sw.flattened(cmd), sw.second_reading(cmd))
    row(what, "" if got == (first, second) else "got first %r and second %r, wanted %r and %r" % (got[0], got[1], first, second))


def one_reading(what, cmd):
    readings_are(what, cmd, old_text(cmd), None)


# A pair the string's own shell keeps is not taken out.
shows("a push on the line after a comment that ends in a backslash, in a wrapper's string, is named by both readings",
      "bash -c 'true # c" + J + PUSH + " origin main --force; gi" + J + "t push origin feature; l" + J + "s'", ("", "git", "push", "origin main --force"))
shows("the first among them, as it always was", "bash -c 'true # c" + J + PUSH + " origin main --force; gi" + J + "t push origin feature; l" + J + "s'",
      ("", "git", "push", "origin main --force"), "first")
shows("and the second names the push the join puts together", "bash -c 'true # c" + J + PUSH + " origin main --force; gi" + J + "t push origin feature; l" + J + "s'",
      ("", "git", "push", "origin feature"))
shows("an add of everything after such a comment is still named", "bash -c 'true # c" + J + "git add -A; gi" + J + "t add f; l" + J + "s'", ("", "git", "add", "-A"))
shows("a push after a quoted heredoc's body that holds the pair is still named",
      "bash -c 'cat " + LL + "\\E\nx" + J + "E\n" + PUSH + " origin main\ncat " + LL + "\\E\nE\ngi" + J + "t push origin feature'", ("", "git", "push", "origin main"))
readings_are("a pair that ends a comment in a wrapper's string stays in the second reading",
             "bash -c 'true # c" + J + PUSH + "; l" + J + "s'", "bash -c 'true # c\\; " + PUSH + "; l\\; s'", "bash -c 'true # c\\; " + PUSH + "; ls'")
shows("a push whose refspec stands across the pair in a wrapper's string is named with that refspec",
      "bash -c '" + PUSH + " origin " + J + "main'", ("", "git", "push", "origin main"))
# No skip word is put together, and a string no shell reads is left as typed.
one_reading("a commit message holding the pair, with nothing else to rewrite, has no second reading", "git commit -m 'a" + J + "b' && " + PUSH)
one_reading("nor has an argument of echo holding the pair", "echo 'gi" + J + "t push'")
one_reading("nor a string ssh hands another machine", "ssh host 'gi" + J + "t push'")
readings_are("an argument of echo is left as typed beside a wrapper's string that is rewritten",
             "echo 'x SKIP_X" + J + "=1 y'; bash -c 'l" + J + "s'", "echo 'x SKIP_X\\; =1 y'; bash -c 'l\\; s'", "echo 'x SKIP_X\\; =1 y'; bash -c 'ls'")
readings_are("an argument of echo holding the very text a wrapper beside it is handed is left as typed too",
             "echo 'l" + J + "s'; bash -c 'l" + J + "s'", "echo 'l\\; s'; bash -c 'l\\; s'", "echo 'l\\; s'; bash -c 'ls'")
readings_are("and so is one after the wrapper, and one in a substitution among the wrapper's own words",
             "bash -c 'l" + J + "s' $(echo 'l" + J + "s'); echo 'l" + J + "s'",
             "bash -c 'l\\; s' $(echo 'l\\; s'); echo 'l\\; s'", "bash -c 'ls' $(echo 'l\\; s'); echo 'l\\; s'")
for cmd in ("a; b && c | d\ne || f", "bash -c 'l" + J + "s'; echo \"q", "x=$(a; b) ; `c; d`", ""):
    pieces = sw._crude_pieces(cmd)
    row("the crude cut's pieces with where they stand are the pieces the crude cut gives: %r" % cmd,
        "" if sorted(t for _, _, _, cut in pieces for _, t in cut) == sorted(t for _, t in sw.crude_commands(cmd))
        and all(cmd[a:b] == cut[0][1] for a, b, _, cut in pieces) else "got %r, and the crude cut gives %r" % (pieces, sw.crude_commands(cmd)))
readings_are("where a join in a wrapper's string would put a skip word together the pair is written after the word",
             "bash -c 'true; SKIP_" + J + "X=1 " + PUSH + "'", "bash -c 'true; SKIP_\\; X=1 " + PUSH + "'", "bash -c 'true; SKIP_X=1\\;  " + PUSH + "'")
shows("and the push behind that word is named", "bash -c 'true; SKIP_" + J + "X=1 " + PUSH + "'", ("", "git", "push", ""))
readings_are("the same inside backquotes", "x=`true; SKIP_" + J + "X=1 " + PUSH + "`", "x=`true; SKIP_\\; X=1 " + PUSH + "`", "x=`true; SKIP_X=1\\;  " + PUSH + "`")
readings_are("a NAME=1 word a moved body leaves where the second reading ends is in that reading alone: the first is the text it always was",
             PUSH + "; cat " + LL + "EOF; ls; SKIP_X=1\nbody\nEOF", PUSH + "; cat " + LL + "EOF; ls; SKIP_X=1; body; EOF", PUSH + "; cat " + LL + "EOF; body; EOF; ls; SKIP_X=1")
# Inside backquotes, by how many backslashes stand before the line break.
for n, joins in ((1, True), (2, True), (3, True), (4, False), (5, False), (6, False), (7, False)):
    cmd = "x=`git " + "\\" * n + "\npush`"
    if joins:
        shows("inside backquotes a push across %d backslash(es) and a line break is named" % n, cmd, ("", "git", "push", ""))
    else:
        hides("inside backquotes %d backslashes and a line break make no push (four start a new command, more leave the word a backslash)" % n, cmd, "git", "push")
hides("after three backslashes a separator that starts the next line is escaped in the second reading",
      "x=`echo a \\\\" + J + "; true`", "git", "push")
readings_are("three backslashes and a line break leave one backslash, which escapes the next line's first letter",
             "x=`git \\\\" + J + "push`", "x=`git \\\\\\; push`", "x=`git \\push`")
# Behind a relative cd: each reading starts from the folder the command starts in.
shows("a push after an opener, behind a relative cd and a cd on the opener's line, is named in the folder it runs in",
      "cd a; cat " + LL + "EOF; cd b; " + PUSH + " origin main\nbody\nEOF\nls", ("a/b", "git", "push", "origin main"))
readings_are("there neither reading is written after the other, so each starts from the folder the command starts in",
             "cd a; cat " + LL + "EOF; cd b; " + PUSH + "\nbody\nEOF\nls", "cd a; cat " + LL + "EOF; cd b; " + PUSH + "; body; EOF; ls", "cd a; cat " + LL + "EOF; body; EOF; cd b; " + PUSH + "; ls")
shows("a push on a line after the heredoc is named by the second reading in the folder a cd on the opener's line moves to",
      "cd a; cat " + LL + "EOF; cd b\nbody\nEOF\n" + PUSH, ("a/b", "git", "push", ""))
shows("and by the first in the folder it always read it in", "cd a; cat " + LL + "EOF; cd b\nbody\nEOF\n" + PUSH, ("a", "git", "push", ""), "first")
hides_first = [g for g in named(sw.flattened("cd a; cat " + LL + "EOF; cd b\nbody\nEOF\n" + PUSH)) if g[0] == "a/b"]
row("and the first reading names nothing in the folder only the second reads, so a cd the second holds chooses no folder for the first", "" if not hides_first else "the first reading names %r" % (hides_first,))
shows("a push split across the pair in a wrapper's string behind a relative cd is named in its folder",
      "cd a; bash -c 'cd b; gi" + J + "t push'", ("a/b", "git", "push", ""))
# The issue's own shapes.
readings_are("the first reading is the old text, and the second the command with its body moved up",
             "cat " + LL + "EOF; " + PUSH + "\nbody\nEOF", "cat " + LL + "EOF; " + PUSH + "; body; EOF", "cat " + LL + "EOF; body; EOF; " + PUSH)
readings_are("a heredoc on a command of one line is written again as the here string it amounts to",
             "cat " + LL + "EOF; " + PUSH + "; EOF", "cat " + LL + "EOF; " + PUSH + "; EOF", "cat " + LL + "<EOF; " + PUSH + "; EOF")
readings_are("a push across the pair in a wrapper's string is the second reading's", "bash -c 'git " + J + "push'", "bash -c 'git \\; push'", "bash -c 'git push'")
# A commit only the second reading names is no commit to a hook judging the first.
commit = "bash -c 'git com" + J + "mit -m x'; " + PUSH
row("a commit written across the pair in a wrapper's string is named by the second reading alone, so it moves no range for the push the first names",
    "" if [g for g in named(sw.second_reading(commit)) if g[2] == "commit"] and not [g for g in named(sw.flattened(commit)) if g[2] == "commit"]
    else "first %r, second %r" % (named(sw.flattened(commit)), named(sw.second_reading(commit))))
# A backslash that ends the text ends each reading, and nothing is written after either.
readings_are("a backslash that ends the text ends each reading, with nothing after it to escape",
             "cat " + LL + "EOF; " + PUSH + "\nbody\nEOF\ntrue \\", "cat " + LL + "EOF; " + PUSH + "; body; EOF; true \\", "cat " + LL + "EOF; body; EOF; " + PUSH + "; true \\")
shows("the push after an opener in a text that ends in a backslash is named", "cat " + LL + "EOF; " + PUSH + "\nbody\nEOF\ntrue \\", ("", "git", "push", ""))
shows("and so is one across the pair in a wrapper's string in such a text", "bash -c 'git " + J + "push'\ntrue \\", ("", "git", "push", ""))
shows("and one inside backquotes in a text that ends in an opener and a backslash", "x=`git " + J + "push`\n; cat " + LL + "E\\", ("", "git", "push", ""))
shows("a push across the pair in a string eval reads is named", "eval 'git " + J + "push'", ("", "git", "push", ""))
shows("a push across the pair in a string bash -c reads under sudo is named", "sudo -u dan bash -c 'cd /r && gi" + J + "t push'", ("/r", "git", "push", ""))
shows("a push across the pair in a wrapper's string inside a substitution is named", "x=$(bash -c 'gi" + J + "t push')", ("", "git", "push", ""))
shows("a push across the pair inside backquotes in a wrapper's string is named", "bash -c 'x=`gi" + J + "t push`'", ("", "git", "push", ""))
shows("a pull request creation after an opener is named", "cat " + LL + "EOF; gh pr create --fill\nbody\nEOF", ("", "gh", "pr", "--fill"))
# However many lines with an opener there are, and however many separators one such line holds.
many = "".join("cat " + LL + "E; true\nx\nE\n" for _ in range(200))
shows("a push after the opener on the two hundred and first such line is named", many + "cat " + LL + "EOF; " + PUSH + "\nbody\nEOF", ("", "git", "push", ""))
deep = "".join("cat " + LL + "E%d; " % k for k in range(sw.OPENER_LINE_LIMIT + 6)) + PUSH + "".join("\nb\nE%d" % k for k in range(sw.OPENER_LINE_LIMIT + 6))
got = sw.opener_lines(deep)
row("a line with more separators after openers than the reader reads the text again for is given as far as it was rewritten, never as nothing",
    "" if got is not None and got != deep else "opener_lines gave %r" % (got,))
# Ordinary commands have one reading, the one they always had.
for what, cmd in (
        ("a heredoc commit with nothing after its opener", "git commit -F - " + LL + "EOF\na message; with a separator\nEOF\n" + PUSH),
        ("a plain chain", "git add f && git commit -m x && " + PUSH),
        ("a push across the pair outside any quote", "git " + J + "push origin main"),
        ("a here string", "cat " + LL + "<EOF; " + PUSH),
        ("a shift in arithmetic", "echo $((1" + LL + "2)); git status"),
        ("a comment after an opener", "cat " + LL + "EOF; # note\nbody\nEOF"),
        ("a text only the crude cut reads", "cat " + LL + "EOF; " + PUSH + "\nbody\nEOF\n( echo")):
    one_reading("control: %s has one reading, the text it always was" % what, cmd)


# The two modes a hook's library asks, as it asks them: a payload on standard input.
def payload_modes(cmd):
    text = json.dumps({"tool_input": {"command": cmd}, "cwd": "/w"})
    return sw.flattened_payload(text), sw.second_payload(text)


first, second = payload_modes("cat " + LL + "EOF; " + PUSH + "\nbody\nEOF")
row("for a command after an opener the flatten mode hands over nothing, since the text holds no pair and the first reading is the other readers' to make as they always did",
    "" if first is None else "it printed %r" % (first,))
row("and the second mode hands over the second reading, then the separator and the folder",
    "" if second == "cat " + LL + "EOF; body; EOF; " + PUSH + "\x1f/w" else "it printed %r" % (second,))
first, second = payload_modes("bash -c 'git " + J + "push'")
row("for a pair in a wrapper's string the flatten mode hands over the text as it always was",
    "" if first == "bash -c 'git \\; push'\x1f/w" else "it printed %r" % (first,))
row("and the second mode the string as its shell reads it", "" if second == "bash -c 'git push'\x1f/w" else "it printed %r" % (second,))
first, second = payload_modes("git commit -F - " + LL + "EOF\na message\nEOF\n" + PUSH)
row("for a heredoc with nothing after its opener both modes hand over nothing", "" if (first, second) == (None, None) else "they printed %r and %r" % (first, second))
row("a payload that is no JSON has no second reading", "" if sw.second_payload("not json " + LL + "EOF; x\n") is None else "it printed one")
sys.stdout.write("end\t%d\n" % ROWS[0])
PY
py_rc=$?
check "the python comparison ran to its end" "$([ "$py_rc" -eq 0 ] && echo ok || echo "it exited $py_rc")"

# A run that compared nothing, or stopped part way, must not read as a pass: the comparison says
# last how many rows it wrote, and that many must have been read here.
rows_read=0
rows_written=""
while IFS=$'\t' read -r verdict what why; do
  case "$verdict" in
    ok) rows_read=$((rows_read + 1)); check "$what" ok ;;
    FAIL) rows_read=$((rows_read + 1)); check "$what" "$why" ;;
    end) rows_written="$what" ;;
    *) check "a row of the comparison is one this suite reads" "got: $verdict" ;;
  esac
done < "$T/rows.tsv"
if [ -n "$rows_written" ] && [ "$rows_written" -gt 0 ] 2>/dev/null && [ "$rows_read" -eq "$rows_written" ]; then
  check "every row the comparison wrote was read" ok
else
  check "every row the comparison wrote was read" "read $rows_read rows, and the comparison says it wrote [${rows_written:-nothing}]"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

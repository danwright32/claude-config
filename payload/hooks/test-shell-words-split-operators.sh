#!/usr/bin/env bash
# An operator that a backslash and a line break split, as the shared command reader
# (lib/shell-words.py commands()) reads it, against the shells themselves (claude-config#3504).
#
# A shell takes a backslash and the line break after it out of a text before it reads words, so
# two characters either side of the pair can make one operator: a dollar sign, the pair and a
# parenthesis is a command substitution in bash, sh and dash wherever it stands, and in zsh
# outside double quotes; a less than sign, the pair and another opens a heredoc. The reader went
# past the pair and read the two characters apart, so the substitution's command was never listed
# and the heredoc never seen, and no gate that reads commands through the reader was shown what
# the shell ran. The shells do not agree with each other on these (zsh and ksh join fewer than
# bash does), so no one reading is every shell's: the reader names the operator in `unsure` for a
# caller that asks, which the Slack drafts gate refuses as a check it could not make.
#
# Each text holds a marker command (touch ran). Every shell found on this machine (bash, sh, dash,
# zsh and ksh) runs each text in an empty throwaway directory, where nothing but echo, true, false,
# cat, the colon command and that touch ever runs, and the reader is asked for its reading.
# THE PROPERTY: wherever a shell runs the marker, the reader lists it, says it cannot read the
# text, or names a line as one it is not sure of. The controls hold the other side: a backslash
# and line break that split no operator are never named, so nothing was fixed by doubting every
# continued line.
#
# The same for a reader that takes a heredoc's marker from heredoc_openers one line at a time: a
# marker whose line ends in a backslash is joined to the next line by every shell, so the word on
# that line is not the marker, and the opener is left out and given to `cut` rather than read as
# a marker that ends in a backslash, which no line of the body can be.
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
SCAN="$DIR/lib/unwaited-children.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/split-operators.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

echo "the command reader: an operator a backslash and a line break split is named (claude-config#3504)"

# One line for each check: "ok<TAB>description" or "FAIL<TAB>description<TAB>why".
python3 -B - "$SW" "$T" "$SCAN" > "$T/rows.tsv" <<'PY'
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

sw_path, scratch, scan_path = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("shell_words", sw_path)
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)

J = "\\\n"  # a backslash and a line break
LT = "<"    # written apart, so no line of this file holds a heredoc opener it does not mean

# A split operator the reader must name: (description, the text before it, its two characters,
# the text after it). The text is the first character, the pair, the second character.
NAMED = [
    ("$( in double quotes", 'echo "', "$(", 'touch ran)"\n'),
    ("$( outside quotes", "echo ", "$(", "touch ran)\n"),
    ("$( in the body of an unquoted heredoc", "cat " + LT + LT + "E\n", "$(", "touch ran)\nE\n"),
    ("$( in backquotes", "echo `echo ", "$(", "touch ran)`\n"),
    ("$( in backquotes, in double quotes", 'echo `echo "', "$(", 'touch ran)"`\n'),
    ("$( in a ${ }", "echo ${x:-", "$(", "touch ran)}\n"),
    ("$( in a $(( ))", "echo $((1 + ", "$(", "touch ran; echo 1)))\n"),
    ("$( in an array", "x=(a ", "$(", "touch ran))\n"),
    ("$( in double quotes in a $( )", 'echo "$(echo "', "$(", 'touch ran)")"\n'),
    ("$( where zsh ends the quotes early", 'echo "', "$(", 'echo " ; touch ran ; echo ")"\n'),
    ("${ in double quotes", 'echo "', "${", "x:-'}\" ; touch ran #'}\"\n"),
    ("$' outside quotes", "echo ", "$'", "a\\' b' ; touch ran #'\n"),
    ("$(( split after its $", "echo ", "$(", "(1+1)) ; touch ran\n"),
    ("$(( split after its $(", "echo $", "((", "1+1)) ; touch ran\n"),
    ("the )) of a $(( ))", "echo $((1+1", "))", " ; touch ran\n"),
    ("the (( of an arithmetic command", "", "((", "1+1)) ; touch ran\n"),
    ("a heredoc's two brackets, an apostrophe in its body", "cat ", LT + LT, "E\n'\nE\ntouch ran #'\n"),
    ("a heredoc's two brackets", "cat ", LT + LT, "E\necho body\nE\ntouch ran\n"),
    ("a here string's first two brackets", "cat ", LT + LT, LT + "E\ntouch ran\nE\n"),
    ("a here string's last two brackets", "cat " + LT, LT + LT, "E\ntouch ran\nE\n"),
    ("a process substitution read from", "cat ", LT + "(", "touch ran)\n"),
    ("a process substitution written to", "echo a ", ">(", "touch ran; cat >/dev/null)\n"),
    ("an array's =(, a comment in it", "x", "=(", "a # it's\n b); touch ran #'\n"),
    ("&&", "false ", "&&", " touch ran\n"),
    ("||", "true ", "||", " touch ran\n"),
    ("a pipe's |&", "echo x ", "|&", " cat ; touch ran\n"),
    ("the ;; of a case branch", "case y in x) : ", ";;", " y) touch ran ;; esac\n"),
    ("the ;& of a case branch", "case x in x) : ", ";&", " y) touch ran ;; esac\n"),
    (">&", "echo x ", ">&", "2 ; touch ran\n"),
    (">>", "echo x ", ">>", "f ; touch ran\n"),
    (">|", "echo x ", ">|", "f ; touch ran\n"),
    ("&>", "echo x ", "&>", "f ; touch ran\n"),
    (LT + "&", "touch ran ", LT + "&", "0\n"),
    (LT + ">", "touch ran ", LT + ">", "f\n"),
]
# The same split over two pairs, and inside backquotes where two backslashes end the line: the
# backquotes read the first, and the text they hand on holds one backslash and the line break.
NAMED_AS = [
    ("$( in double quotes, split by two pairs", 'echo "$' + J + J + '(touch ran)"\n', (6, 12)),
    ("$( in backquotes in double quotes, after two backslashes",
     'echo `echo "$\\\\\n(touch ran)"`\n', (12, 17)),
]

# A backslash and a line break that split no operator: (description, text, the reading wanted).
CONTROLS = [
    ("an escaped $ before the pair", 'echo "\\$' + J + '(touch ran)"\n', "not listed"),
    ("the pair in single quotes", "echo '$" + J + "(touch ran)'\n", "not listed"),
    ("the pair in the body of a quoted heredoc", "cat " + LT + LT + "'E'\n$" + J + "(touch ran)\nE\n", "not listed"),
    ("a backslash that ends a comment", "true # $" + J + "(touch ran)\n", "listed"),
    ("two backslashes before the line break", 'echo "$\\\\\n(touch ran)"\n', "not listed"),
    ("a line continued after a space", "echo a " + J + "  b; touch ran\n", "listed"),
    ("a line continued after &&", "true && " + J + "touch ran\n", "listed"),
    ("a line continued after &&, no space", "true &&" + J + "touch ran\n", "listed"),
    ("a line continued after a pipe", "echo a |" + J + " cat; touch ran\n", "listed"),
    ("a line continued after a ;", "echo a;" + J + "touch ran\n", "listed"),
    ("a line continued mid word", "echo a" + J + "b; touch ran\n", "listed"),
    ("two brackets split in double quotes", 'echo "a ' + LT + J + LT + ' b"; touch ran\n', "listed"),
    ("&& split in double quotes", 'echo "a &' + J + '& b"; touch ran\n', "listed"),
    (";; split in double quotes", 'echo "a ;' + J + '; b"; touch ran\n', "listed"),
    ("a $ and a name", "echo $" + J + "HOME; touch ran\n", "listed"),
    ("a $ and an apostrophe in double quotes", 'echo "$' + J + "'a'\"; touch ran\n", "listed"),
    ("a ) inside a $(( )) and its ))", "echo $((1+(2)" + J + ")); touch ran\n", "listed"),
    ("the ) of a $( ) and the ) of the one around it", "x=$(echo $(echo a)" + J + "); touch ran\n", "listed"),
    ("a heredoc with nothing split", "cat " + LT + LT + "E\nbody\nE\ntouch ran\n", "listed"),
    ("a continued line in an unquoted heredoc's body", "cat " + LT + LT + "E\na " + J + "b\nE\ntouch ran\n", "listed"),
    ("nothing split at all", 'echo "$(touch ran)"\n', "listed"),
]

SHELLS = {"bash": ["bash", "--noprofile", "--norc", "-c"], "sh": ["sh", "-c"], "dash": ["dash", "-c"],
          "zsh": ["zsh", "-f", "-c"], "ksh": ["ksh", "-c"]}
HAVE = [name for name in SHELLS if shutil.which(name)]


def runs(shell, text):
    d = tempfile.mkdtemp(prefix="run-", dir=scratch)
    try:
        subprocess.run(SHELLS[shell] + [text], cwd=d, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20,
                       env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": d})
        return os.path.exists(os.path.join(d, "ran"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def reading(text):
    """(what a caller that asks is told, the operators and lines named)."""
    marks = []
    try:
        cut = sw.commands(text, unsure=marks)
    except sw.Unreadable:
        return ("unsure" if marks else "unreadable"), marks
    if marks:
        return "unsure", marks
    # A command continued from the line before still holds the pair, which the shell takes out.
    return ("listed" if any(sw.join_continuations(t).strip() == "touch ran" for _, t in cut) else "not listed"), marks


def say(ok, what, why=""):
    print("ok\t" + what if ok else "FAIL\t" + what + "\t" + why)


def shown(text):
    return text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")


print("shells\t" + " ".join(HAVE))

ran_named = 0
rows = [(name, before + op[0] + J + op[1] + after, (len(before), len(before) + 4)) for name, before, op, after in NAMED]
for name, text, mark in rows + NAMED_AS:
    ran = [shell for shell in HAVE if runs(shell, text)]
    ran_named += bool(ran)
    got, marks = reading(text)
    say(not (ran and got == "not listed"),
        "#3504 a command a shell runs is never left out: %s, split" % name,
        "%s ran the marker and the reader left it out: [%s]" % (" and ".join(ran), shown(text)))
    say(got == "unsure" and mark in marks, "#3504 the split operator is named: %s" % name,
        "the reader said %s and named %r, wanted %r named: [%s]" % (got, marks, mark, shown(text)))
    say(bool(getattr(sw, "split_operator", None)) and bool(sw.split_operator(text, mark[0])),
        "#3504 split_operator says the name is a split operator's: %s" % name,
        "it did not, at %d in [%s]" % (mark[0], shown(text)))
for name, text, want in CONTROLS:
    ran = [shell for shell in HAVE if runs(shell, text)]
    got, marks = reading(text)
    say(not (ran and got == "not listed"),
        "#3504 a command a shell runs is never left out: %s" % name,
        "%s ran the marker and the reader left it out: [%s]" % (" and ".join(ran), shown(text)))
    say(got == want and marks == [], "#3504 the control: nothing is named for %s" % name,
        "the reader said %s and named %r, wanted %s and nothing named: [%s]" % (got, marks, want, shown(text)))
# A run in which no shell ran any marker compared nothing.
print("ran\t%d" % ran_named)

# What split_operator says of a place in a text: the two characters the pair splits, or "".
ask = getattr(sw, "split_operator", None)
for text, at, want in [('echo "$' + J + '(a)"', 6, "$("), ("cat " + LT + J + LT + "E", 4, LT + LT),
                       ("a &" + J + J + "& b", 2, "&&"), ("echo $" + J + "HOME", 5, ""),
                       ('echo "$(a)"', 6, ""), ("echo a " + J + "b", 6, ""), ("echo $", 5, "")]:
    got = ask(text, at) if ask else None
    say(got == want, "#3504 split_operator gives %r at %d of [%s]" % (want, at, shown(text)), "gave %r" % (got,))

# A caller that does not ask is given the reading it always was: other gates read through the
# reader, and what a split operator means to each is that gate's to decide.
for text, want in [('echo "$' + J + '(touch ran)"\n', ['echo "$' + J + '(touch ran)"']),
                   ("false &" + J + "& touch ran\n", ["false", J, "touch ran"]),
                   ("cat " + LT + J + LT + "E\necho body\nE\ntouch ran\n",
                    ["cat " + LT + J + LT + "E", "echo body", "E", "touch ran"])]:
    got = [t.strip(" ") for _, t in sw.commands(text)]
    say([g for g in got if g] == want, "#3504 a caller that does not ask is given the reading it always was: [%s]" % shown(text),
        "commands gave %r, wanted %r" % (got, want))

# The push hooks read a command flattened, and flattened() joins what the shell joins: a split $(
# is written whole there, so the push inside it is read. Naming the operator must not send that
# reading back to the plain flattening, which reads the push as text.
for text, want in [('echo "$' + J + '(git push)"', 'echo "$(git push)"'),
                   ("echo $" + J + "(git push)", "echo $(git push)")]:
    got = sw.flattened(text)
    say(got == want, "#3504 flattened() still writes a split $( whole: [%s]" % shown(text), "gave %r, wanted %r" % (got, want))

# A backslash that is the LAST character of a text joins nothing: there is no line after it, and
# bash and zsh run such a text as they run it without the backslash. Read as a join, a text that
# ends in a heredoc opener and a backslash was a heredoc named in `unsure`, so flattened() gave its
# plain form, in which the push is no push (review of pull request 3797).
for text, want in [("git" + J + " push origin main; cat " + LT + LT + "E\\", "git push origin main; cat " + LT + LT + "E\\"),
                   ("git" + J + " push --force origin main " + LT + LT + "E\\", "git push --force origin main " + LT + LT + "E\\"),
                   ("echo ok &&" + J + "git push origin main; cat " + LT + LT + "E\\",
                    "echo ok &&git push origin main; cat " + LT + LT + "E\\"),
                   ("git" + J + " push origin main; cat " + LT + LT + '"E"\\', "git push origin main; cat " + LT + LT + '"E"\\')]:
    got = sw.flattened(text)
    named = sw._named(got) or {}
    say(got == want and ("", "git", "push") in named,
        "#3504 flattened() names the push in a text that ends in a heredoc opener and a backslash: [%s]" % shown(text),
        "gave %r, which names %r; wanted %r" % (got, sorted(named), want))
    say(reading(text) == ("not listed", []),
        "#3504 a backslash that ends the text joins nothing, so no heredoc is named: [%s]" % shown(text),
        "the reader named %r" % (reading(text)[1],))


# A heredoc's marker, read one line at a time (heredoc_openers).
def line_scan(text):
    """The lines a reader that takes each heredoc's marker from heredoc_openers, a line at a time,
    reads as code: every line that is no heredoc's body or closing line."""
    code, waiting = [], []
    for line in text.split("\n"):
        if waiting:
            strip, marker = waiting[0]
            if (line.lstrip("\t") if strip else line) == marker:
                waiting.pop(0)
            continue
        code.append(line)
        waiting.extend((op[2], op[1]) for op in sw.heredoc_openers(line))
    return code


OPEN = "cat " + LT + LT
LINE_ROWS = [
    ("a marker joined to the next line", OPEN + "E" + J + "x\necho body\nEx\ntouch ran\n"),
    ("a marker on the line after its brackets", OPEN + J + "E\necho body\nE\ntouch ran\n"),
    ("a marker joined inside its double quotes", OPEN + '"E' + J + 'x"\necho body\nEx\ntouch ran\n'),
    ("a marker joined to an empty line", OPEN + "E" + J + "\necho body\nE\ntouch ran\n"),
    ("the control: a marker with nothing joined", OPEN + "E\necho body\nE\ntouch ran\n"),
    ("the control: a marker that ends in an escaped backslash", OPEN + "E\\\\\necho body\nE\\\ntouch ran\n"),
]
for name, text in LINE_ROWS:
    ran = [shell for shell in HAVE if runs(shell, text)]
    code = line_scan(text)
    say(not ran or "touch ran" in code,
        "#3504 a line a shell runs is never read as a heredoc's body, a line at a time: %s" % name,
        "%s ran the marker and the line reader took it for body text, reading only %r: [%s]"
        % (" and ".join(ran), code, shown(text)))
    if name.startswith("the control"):
        say("echo body" not in code, "#3504 %s still has its body left out" % name, "read %r" % (code,))


def openers(line, **more):
    cut = []
    try:
        return sw.heredoc_openers(line, cut=cut, **more), cut
    except TypeError as e:  # a reader with no `cut` to give
        return "heredoc_openers takes no cut (%s)" % e, cut


for line, want, want_cut in [
        (OPEN + "E\\", [], [(4, 8)]),
        (OPEN + "\\", [], [(4, 7)]),
        ("a " + LT + LT + "A && cat " + LT + LT + "B\\", [(2, "A", False, False, 5)], [(13, 17)]),
        # Double quotes that never close on the line are no opener, as they never were, and the
        # scan goes on: that pair of brackets is as often inside a string, and the opener after
        # it is real (review of pull request 3797; bash and zsh open the heredoc on this line).
        (OPEN + '"E\\', [], []),
        ('echo "a ' + LT + LT + ' b" | cat ' + LT + LT + "EOF | tr a b \\", [(20, "EOF", False, False, 25)], []),
        ("a " + LT + LT + '"A ' + LT + LT + "B c\\", [(7, "B", False, False, 10)], []),
        # A cut opener's word runs to the end of the line, so nothing follows it: brackets inside
        # its quotes open nothing.
        (OPEN + "'A " + LT + LT + "B 'C\\", [], [(4, 16)]),
        (OPEN + "E\\\\", [(4, "E\\", False, True, 9)], []),
        (OPEN + "\\E", [(4, "E", False, True, 8)], []),
        (OPEN + "E", [(4, "E", False, False, 7)], []),
        ("echo $((1" + LT + LT + "2)) \\", [], [])]:
    got, cut = openers(line)
    say(got == want and cut == want_cut,
        "#3504 heredoc_openers on the one line [%s] gives %r and cuts %r" % (shown(line), want, want_cut),
        "gave %r and cut %r" % (got, cut))
# Handed the whole text, the opener is read as every shell reads it: the two lines joined.
for text, want in [(OPEN + "E" + J + "x\nbody\nEx\n", [(4, "Ex", False, False, 10)]),
                   (OPEN + J + "E\nbody\nE\n", [(4, "E", False, False, 9)]),
                   (OPEN + "E\\\\\nbody\nE\\\n", [(4, "E\\", False, True, 9)]),
                   # A whole text that ends in a backslash: it joins nothing, so the opener is the
                   # one it always was, and one behind double quotes that never close is still given.
                   (OPEN + "E\\", [(4, "E\\", False, False, 8)]),
                   ("echo '" + LT + LT + "\"' ; cat " + LT + LT + "E\n$1\nE\necho done \\", [(17, "E", False, False, 20)]),
                   # Read joined, the marker is the quoted words on the next line and the brackets
                   # inside them open nothing. Read as it was before, they open an unquoted heredoc.
                   # A gate that asks whether any heredoc expands its body is given both.
                   (OPEN + J + " 'a " + LT + LT + "E b'\n$1\nE\n",
                    [(4, "a " + LT + LT + "E b", False, True, 18), (12, "E", False, False, 15)])]:
    got, cut = openers(text, marker_start=False)
    say(got == want and cut == [], "#3504 heredoc_openers on the whole text [%s] gives %r" % (shown(text), want),
        "gave %r and cut %r" % (got, cut))

# ---- the family: a text that ends in a backslash (review of pull request 3797) -------------------
# Every text this suite reads above and every text of the review, each followed by a heredoc
# opener, a quote that never closes, an operator or nothing, and each of those ended four ways: as
# written, with a backslash, with two, and with a backslash and line break and then a backslash.
# THE PROPERTY: a backslash that is the last character of a text is read as any other last
# character of a word is. Each text that ends in one is read beside its twin, the same text with a
# Q in the backslash's place, and the two readings must be one, the Q written back: the commands,
# for a caller that asks and one that does not, the lines named, and the heredocs a whole text
# opens. So must flattened() be where the text ends in a heredoc opener and the backslash, the
# shape that hid a push; after other tails flattened() weighs what the last word names, a Q is a
# program's name where a backslash is none, and the twin says nothing. That is the reading the
# reader gave before it named split operators: on its copy at f0c2aba6fd no text of the family
# differs from its twin in any of these (measured 2026-11-27).
# Read one line at a time the last backslash does join, to a line the reader was not handed, so
# there the last line's openers are its twin's without the one whose word runs to that backslash.
REVIEW_TEXTS = [
    "git" + J + " push origin main",
    "git" + J + " push --force origin main",
    "echo ok &&" + J + "git push origin main",
    'echo "a ' + LT + LT + ' b" | cat ' + LT + LT + "EOF | tr a b ",
    "echo '" + LT + LT + "\"' ; cat " + LT + LT + "E\n$1\nE\necho done ",
    "sh -c 'echo quiet'",
    OPEN + J + "-E\nbody\nE\n",
    OPEN + J + LT + " f\n",
    OPEN + "E &" + J + "& x\nbody\nE\n",
    OPEN + "E$" + J + "(\n",
    'echo "\\\\$' + J + '(touch ran)"\n',
    "echo a\\\r\n(touch ran)\n",
    'psql -c "select 1" &' + J + "& echo done",
    OPEN + J + " 'a " + LT + LT + "E b'\n$1\nE\n",
]
BASES = ([text for _, text, _ in rows + NAMED_AS + CONTROLS] + [text for _, text in LINE_ROWS]
         + ['echo "$' + J + '(git push)"', "echo $" + J + "(git push)", "a " + LT + LT + "A && cat " + LT + LT + "B",
            OPEN + "\\E", "echo $((1" + LT + LT + "2)) "] + REVIEW_TEXTS)
OPENER_TAILS = ["; cat " + LT + LT + "E", " " + LT + LT + "E", "; cat " + LT + LT + '"E"', "; cat " + LT + LT + "'E'",
                "; cat " + LT + LT + "-E", "; cat " + LT + LT + " E", "; cat " + LT + LT, "; cat " + LT + LT + " ",
                "; cat " + LT + LT + '"E', "; cat " + LT + LT + "'E", "; cat " + LT + LT + "$'E",
                "; cat " + LT + LT + "E | tr a b ", '; echo "a ' + LT + LT + ' b" | cat ' + LT + LT + "EOF | tr a b "]
TAILS = [""] + OPENER_TAILS + [' "a', " 'a", ' "', " $(echo ", " `echo ", " &&", " ||", " |", " ;", " &", " " + LT, " >",
                               " $", " $(", " ((", " ;;", " #", " a"]
ENDS = ["", "\\", "\\\\", J + "\\", "\\\n"]
FAMILY, seen, after_opener = [], set(), set()
for base in BASES:
    for stem in sorted({base, base.rstrip("\n")}, key=len, reverse=True):
        for tail in TAILS:
            for end in ENDS:
                if stem + tail + end not in seen:
                    seen.add(stem + tail + end)
                    FAMILY.append(stem + tail + end)
                if tail in OPENER_TAILS:
                    after_opener.add(stem + tail + end)
# For reading the same family with another copy of the reader (the one on main, say): the texts
# are written to the file SPLIT_FAMILY_OUT names, as JSON, when it is set.
if os.environ.get("SPLIT_FAMILY_OUT"):
    import json
    with open(os.environ["SPLIT_FAMILY_OUT"], "w") as f:
        json.dump(FAMILY, f)


def back(x):
    """x with each Q written back as the backslash it stood for."""
    if isinstance(x, str):
        return x.replace("Q", "\\")
    return type(x)(back(y) for y in x) if isinstance(x, (list, tuple)) else x


def read_both(text):
    """(the commands for a caller that does not ask, for one that asks, the lines named)."""
    marks = []
    try:
        asked = sw.commands(text, unsure=marks)
    except sw.Unreadable:
        asked = "unreadable"
    try:
        return sw.commands(text), asked, marks
    except sw.Unreadable:
        return "unreadable", asked, marks


def whole(text):
    return sw.heredoc_openers(text, marker_start=False)


def last_line(text):
    """(the last line's openers read alone, what was cut), and the same as its twin's say they
    should be: without the opener whose word runs to the last backslash. Where another backslash
    escapes the last one it joins nothing, and all that is asked is that nothing is cut."""
    line = text.rsplit("\n", 1)[-1]
    got = openers(line)
    if (len(line) - len(line.rstrip("\\"))) % 2 == 0:
        return got, (got[0], [])
    twin = [(op[0], back(op[1])) + op[2:] for op in sw.heredoc_openers(line[:-1] + "Q")]
    return got, ([op for op in twin if op[4] < len(line)], [(op[0], len(line)) for op in twin if op[4] == len(line)])


ended = [text for text in FAMILY if text.endswith("\\") and "Q" not in text]
FLAT = "flattened(), where the text ends in a heredoc opener and the backslash"
wrong = {"the commands": [], "the lines named": [], FLAT: [], "the heredocs of the whole text": [],
         "the heredocs of the last line": []}
opener_ended = 0
for text in ended:
    twin = text[:-1] + "Q"
    plain, asked, marks = read_both(text)
    plain_q, asked_q, marks_q = read_both(twin)
    if (plain, asked) != (back(plain_q), back(asked_q)):
        wrong["the commands"].append((text, "%r and %r, its twin's %r and %r" % (plain, asked, back(plain_q), back(asked_q))))
    if marks != marks_q:
        wrong["the lines named"].append((text, "%r, its twin's %r" % (marks, marks_q)))
    if text in after_opener:
        opener_ended += 1
        flat, flat_q = sw.flattened(text), back(sw.flattened(twin))
        if flat != flat_q:
            wrong[FLAT].append((text, "%r, its twin's %r" % (flat, flat_q)))
    if whole(text) != back(whole(twin)):
        wrong["the heredocs of the whole text"].append((text, "%r, its twin's %r" % (whole(text), back(whole(twin)))))
    got, want = last_line(text)
    if got != want:
        wrong["the heredocs of the last line"].append((text, "%r and cut %r, wanted %r and cut %r" % (got + want)))
for what in sorted(wrong):
    say(not wrong[what], "#3504 a backslash that ends a text is read as any other last character: %s, "
        "in each of the family's %d texts that end in one" % (what, len(ended)),
        "%d texts differ from their twin, the first [%s]: %s"
        % (len(wrong[what]), shown(wrong[what][0][0]) if wrong[what] else "", wrong[what][0][1] if wrong[what] else ""))
# A family that was never made compared nothing: the texts made, the ones read beside a twin, and
# of those the ones that end in a heredoc opener, whose flattened form was read too.
print("family\t%d %d %d" % (len(FAMILY), len(ended), opener_ended))

# The heredoc-markers mode prints no row for an opener it cut, as for a marker holding a line
# break: a scan written in awk then reads the lines after as code, never as a body with no end.
p = subprocess.run([sys.executable, "-B", sw_path, "heredoc-markers"], stdout=subprocess.PIPE, timeout=20,
                   input=(OPEN + "E" + J + "x\nbody\nEx\n" + OPEN + "F\nb\nF\n").encode())
say(p.stdout.decode() == "5\tF\n", "#3504 heredoc-markers prints no row for a marker joined to the next line",
    "printed %r" % p.stdout.decode())

# lib/unwaited-children.py walks a file a line at a time with a walk of its own. It took the
# marker for E and a backslash, which no line is, so everything after was body and no site read.
site = "while read -r l; do echo \"$l\"; done " + LT + " " + LT + "(find .)\n"
for name, text, want_rc, want_at in [
        ("joined.sh", OPEN + "E" + J + "x\nbody\nEx\n" + site, 1, "joined.sh:5:"),
        ("plain.sh", OPEN + "E\n" + site + "E\n", 0, "")]:
    with open(os.path.join(scratch, name), "w") as f:
        f.write(text)
    p = subprocess.run([sys.executable, "-B", scan_path, "--root", scratch], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=60, input=(name + "\n").encode())
    out = p.stdout.decode()
    say(p.returncode == want_rc and (out.startswith(want_at) if want_at else not out.strip()),
        "#3504 the unwaited children scan reads the site %s" % ("after a heredoc whose marker is joined to the next line"
                                                             if want_rc else "in a heredoc's body as text, as it did"),
        "exit %d, printed %r" % (p.returncode, out))
PY
rc=$?
[ "$rc" -eq 0 ] || check "the comparison ran to its end" "python3 exited $rc"

SHELLS_READ=""
RAN_NAMED=0
FAMILY_READ="0 0 0"
while IFS=$'\t' read -r verdict what why; do
  case "$verdict" in
    ok) check "$what" ok ;;
    FAIL) check "$what" "$why" ;;
    shells) SHELLS_READ="$what" ;;
    ran) RAN_NAMED="$what" ;;
    family) FAMILY_READ="$what" ;;
    *) check "a row of the comparison is one this suite reads" "got: $verdict" ;;
  esac
done < "$T/rows.tsv"

case " $SHELLS_READ " in
  *" bash "*) check "the texts were run by this machine's bash" ok ;;
  *) check "the texts were run by this machine's bash" "no bash was found, so no row was measured against a shell" ;;
esac
for shell in sh dash zsh ksh; do
  case " $SHELLS_READ " in
    *" $shell "*) ;;
    *) echo "SUITE-PART-UNMEASURED what $shell does with each text, because there is no $shell on this machine" ;;
  esac
done
# A run in which the shells ran no marker compared the reader with nothing.
[ "$RAN_NAMED" -ge 15 ] && check "a shell here ran the marker of the split texts" ok \
  || check "a shell here ran the marker of the split texts" "a shell ran the marker in only $RAN_NAMED of the 36 texts that split an operator, where 15 or more were wanted"
# A family that was never made, or of which no text ended in a backslash, was read beside nothing.
FAMILY_MADE="${FAMILY_READ%% *}"
FAMILY_OPENER="${FAMILY_READ##* }"
FAMILY_ENDED="${FAMILY_READ#* }"
FAMILY_ENDED="${FAMILY_ENDED%% *}"
echo "the family: ${FAMILY_MADE:-0} texts, ${FAMILY_ENDED:-0} that end in a backslash read beside a twin, ${FAMILY_OPENER:-0} of those after a heredoc opener"
[ "${FAMILY_MADE:-0}" -ge 24000 ] && [ "${FAMILY_ENDED:-0}" -ge 14000 ] && [ "${FAMILY_OPENER:-0}" -ge 5900 ] \
  && check "the family of texts that end in a backslash was read" ok \
  || check "the family of texts that end in a backslash was read" "it held ${FAMILY_MADE:-0} texts, ${FAMILY_ENDED:-0} of them read beside a twin and ${FAMILY_OPENER:-0} of those ending in a heredoc opener, where 24,320, 14,592 and 5,928 were wanted"
# A run that compared nothing must not read as a pass.
[ "$pass" -ge 190 ] || check "the comparison checked its rows" "only $pass checks passed, of the 210 or so the tables make"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]

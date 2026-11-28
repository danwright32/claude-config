#!/usr/bin/env bash
# The flattened form the push hooks read only ever ADDS to what a hook was handed before
# (lib/shell-words.py flattened(), claude-config#3739).
#
# A command after a heredoc's opener on its line, or split across a backslash and a line break in
# a wrapper's string or inside backquotes, was hidden from every hook reading the flattened form.
# The reader rewrites the command so that form shows it. The rewritten text alone can hide a
# command the old text names (a comment ending in a backslash in a wrapper's string swallows the
# next line once the pair is taken out) and can put a skip word together from two halves no shell
# joins, so it is only ever handed over beside the old text.
#
# What this suite holds, for every text of a family of made up commands:
#   A1  the text a hook was handed before is in the new text whole, at its start or at its end;
#   A2  every command the old text's reading gives a hook, the new text's reading gives too, with
#       the same folder, text and wrapper, as many times;
#   A3  the new text holds no NAME=1 word (what ps_has_override matches) the old text lacks;
#   A4  the rewrite of opener lines made in one pass gives what one line at a time gives.
# And, row by row, that the commands the rewrite exists to show are shown, in the folder they run
# in, and that a string no shell reads is left as typed.
# The old text is worked out here by the part of the reader that made it before the rewrite
# existed (_pairs_joined); the count over recorded commands compares against main's own reader.
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

echo "the flattened form: the rewritten command is added to the old text, never put in its place (claude-config#3739)"

# One line for each check: "ok<TAB>description" or "FAIL<TAB>description<TAB>why".
python3 -B - "$SW" > "$T/rows.tsv" <<'PY'
import importlib.util
import re
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
# ps_has_override's pattern for any name, [[:space:]] read as ASCII alone and as Unicode has it.
SKIPS = (re.compile(r"(?:^|(?<=[ \t\n\r\f\v;&|]))([A-Za-z_][A-Za-z0-9_]*)=1(?=[ \t\n\r\f\v]|\Z)"),
         re.compile(r"(?:^|(?<=[\s;&|]))([A-Za-z_][A-Za-z0-9_]*)=1(?=\s|\Z)"))


ROWS = [0]


def row(what, why=""):
    what = what.replace("\t", " ").replace("\n", " ")
    why = why.replace("\t", " ").replace("\n", "\\n")
    ROWS[0] += 1
    sys.stdout.write(("FAIL\t%s\t%s\n" % (what, why)) if why else ("ok\t%s\n" % what))


def old_text(cmd):
    """What a hook was handed before the rewrite: the plain flattening, or the join of #3470."""
    plain = cmd.replace("\n", BREAK)
    return sw._pairs_joined(cmd, plain)[1] if J in cmd else plain


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
    reading gives a hook."""
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
    """Why the text handed over for cmd breaks A1, A2 or A3; nothing where it holds them, and
    None where it is the old text itself."""
    was, now = old_text(cmd), sw.flattened(cmd)
    if now == was:
        return None
    if not (now.startswith(was + BREAK) or now.endswith(BREAK + was)):
        return "A1: the old text %r is not whole at either end of %r" % (was, now)
    after = held(now)
    lost = [k for k, n in held(was).items() if n > after.get(k, 0)]
    if lost:
        return "A2: %r is no longer read from %r" % (lost[0].split("\x1c")[1], now)
    for pattern in SKIPS:
        extra = set(pattern.findall(now)) - set(pattern.findall(was))
        if extra:
            return "A3: %s=1 is a skip word in %r and in nothing a hook was handed before" % (sorted(extra)[0], now)
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
broken, changed, differ = "", 0, ""
for cmd in family:
    try:
        why = faults(cmd)
    except Exception as e:  # a crash is a fault of the text that caused it, never a pass
        why = "the reader raised %s: %s" % (type(e).__name__, e)
    if why and not broken:
        broken = "%r: %s" % (cmd, why)
    changed += why is not None
    if LL in cmd and not differ and sw.opener_lines(cmd) != one_line_at_a_time(cmd):
        differ = "%r: one pass gave %r, one line at a time %r" % (cmd, sw.opener_lines(cmd), one_line_at_a_time(cmd))
row("A1 to A3: over the family of %d texts, the old text is whole in the new one, every command it gave is still given, and no skip word is new" % len(family), broken)
row("A4: over the same family, opener lines rewritten in one pass are what one line at a time gives", differ)
row("the family is not read as unchanged throughout: the rewrite adds to at least a third of it",
    "" if changed * 3 >= len(family) else "only %d of %d texts were handed over changed" % (changed, len(family)))

# ---- row by row ------------------------------------------------------------------------------
def shows(what, cmd, want):
    """The text handed over for cmd names want, a (folder, tool, subcommand, arguments)."""
    got = named(sw.flattened(cmd))
    row(what, "" if want in got else "wanted %r among %r, from %r" % (want, got, sw.flattened(cmd)))


def hides(what, cmd, tool, sub):
    """The text handed over for cmd names no command of that tool and subcommand."""
    got = [g for g in named(sw.flattened(cmd)) if g[1] == tool and g[2] == sub]
    row(what, "" if not got else "it names %r, from %r" % (got, sw.flattened(cmd)))


def text_is(what, cmd, want):
    got = sw.flattened(cmd)
    row(what, "" if got == want else "got %r, wanted %r" % (got, want))


def unchanged(what, cmd):
    text_is(what, cmd, old_text(cmd))


# A pair the string's own shell keeps is not taken out.
shows("a push on the line after a comment that ends in a backslash, in a wrapper's string, is still named",
      "bash -c 'true # c" + J + PUSH + " origin main --force; gi" + J + "t push origin feature; l" + J + "s'", ("", "git", "push", "origin main --force"))
shows("and so is the push the join does put together", "bash -c 'true # c" + J + PUSH + " origin main --force; gi" + J + "t push origin feature; l" + J + "s'",
      ("", "git", "push", "origin feature"))
shows("an add of everything after such a comment is still named", "bash -c 'true # c" + J + "git add -A; gi" + J + "t add f; l" + J + "s'", ("", "git", "add", "-A"))
shows("a push after a quoted heredoc's body that holds the pair is still named",
      "bash -c 'cat " + LL + "\\E\nx" + J + "E\n" + PUSH + " origin main\ncat " + LL + "\\E\nE\ngi" + J + "t push origin feature'", ("", "git", "push", "origin main"))
text_is("a pair that ends a comment in a wrapper's string stays in the rewritten command",
        "bash -c 'true # c" + J + PUSH + "; l" + J + "s'", "bash -c 'true # c\\; " + PUSH + "; ls' ; bash -c 'true # c\\; " + PUSH + "; l\\; s'")
shows("a push whose refspec stands across the pair in a wrapper's string is named with that refspec",
      "bash -c '" + PUSH + " origin " + J + "main'", ("", "git", "push", "origin main"))
# No skip word is put together, and a string no shell reads is left as typed.
unchanged("a commit message holding the pair, with nothing else to rewrite, is handed over as it always was", "git commit -m 'a" + J + "b' && " + PUSH)
unchanged("an argument of echo holding the pair is handed over as it always was", "echo 'gi" + J + "t push'")
unchanged("a string ssh hands another machine is handed over as it always was", "ssh host 'gi" + J + "t push'")
text_is("an argument of echo is left as typed beside a wrapper's string that is rewritten",
        "echo 'x SKIP_X" + J + "=1 y'; bash -c 'l" + J + "s'", "echo 'x SKIP_X\\; =1 y'; bash -c 'ls' ; echo 'x SKIP_X\\; =1 y'; bash -c 'l\\; s'")
text_is("an argument of echo holding the very text a wrapper beside it is handed is left as typed too",
        "echo 'l" + J + "s'; bash -c 'l" + J + "s'", "echo 'l\\; s'; bash -c 'ls' ; echo 'l\\; s'; bash -c 'l\\; s'")
text_is("and so is one after the wrapper, and one in a substitution among the wrapper's own words",
        "bash -c 'l" + J + "s' $(echo 'l" + J + "s'); echo 'l" + J + "s'",
        "bash -c 'ls' $(echo 'l\\; s'); echo 'l\\; s' ; bash -c 'l\\; s' $(echo 'l\\; s'); echo 'l\\; s'")
for cmd in ("a; b && c | d\ne || f", "bash -c 'l" + J + "s'; echo \"q", "x=$(a; b) ; `c; d`", ""):
    pieces = sw._crude_pieces(cmd)
    row("the crude cut's pieces with where they stand are the pieces the crude cut gives: %r" % cmd,
        "" if sorted(t for _, _, _, cut in pieces for _, t in cut) == sorted(t for _, t in sw.crude_commands(cmd))
        and all(cmd[a:b] == cut[0][1] for a, b, _, cut in pieces) else "got %r, and the crude cut gives %r" % (pieces, sw.crude_commands(cmd)))
text_is("where a join in a wrapper's string would put a skip word together the pair is written after the word",
        "bash -c 'true; SKIP_" + J + "X=1 " + PUSH + "'", "bash -c 'true; SKIP_X=1\\;  " + PUSH + "' ; bash -c 'true; SKIP_\\; X=1 " + PUSH + "'")
shows("and the push behind that word is named", "bash -c 'true; SKIP_" + J + "X=1 " + PUSH + "'", ("", "git", "push", ""))
text_is("the same inside backquotes", "x=`true; SKIP_" + J + "X=1 " + PUSH + "`", "x=`true; SKIP_X=1\\;  " + PUSH + "` ; x=`true; SKIP_\\; X=1 " + PUSH + "`")
text_is("a NAME=1 word a moved body leaves at the end of the rewritten command has no blank written after it, which would make a skip word of it",
        PUSH + "; cat " + LL + "EOF; ls; SKIP_X=1\nbody\nEOF", PUSH + "; cat " + LL + "EOF; body; EOF; ls; SKIP_X=1; " + PUSH + "; cat " + LL + "EOF; ls; SKIP_X=1; body; EOF")
skip = SKIPS[0].findall(sw.flattened("cat " + LL + "EOF; SKIP_X=1 " + PUSH + "\nbody\nEOF"))
row("control: a skip word typed whole in front of a push after an opener is one, as it was before", "" if "SKIP_X" in skip else "it is none in the text handed over")
# Inside backquotes, by how many backslashes stand before the line break.
for n, joins in ((1, True), (2, True), (3, True), (4, False), (5, False), (6, False), (7, False)):
    cmd = "x=`git " + "\\" * n + "\npush`"
    if joins:
        shows("inside backquotes a push across %d backslash(es) and a line break is named" % n, cmd, ("", "git", "push", ""))
    else:
        hides("inside backquotes %d backslashes and a line break make no push (four start a new command, more leave the word a backslash)" % n, cmd, "git", "push")
hides("after three backslashes a separator that starts the next line is escaped in the rewritten command",
      "x=`echo a \\\\" + J + "; true`", "git", "push")
text_is("three backslashes and a line break leave one backslash, which escapes the next line's first letter",
        "x=`git \\\\" + J + "push`", "x=`git \\push` ; x=`git \\\\\\; push`")
# Behind a relative cd.
shows("a push after an opener, behind a relative cd and a cd on the opener's line, is named in the folder it runs in",
      "cd a; cat " + LL + "EOF; cd b; " + PUSH + " origin main\nbody\nEOF\nls", ("a/b", "git", "push", "origin main"))
text_is("there the rewritten command stands inside a subshell, and the old text follows from the folder it always started in",
        "cd a; cat " + LL + "EOF; cd b; " + PUSH + "\nbody\nEOF\nls", "( cd a; cat " + LL + "EOF; body; EOF; cd b; " + PUSH + "; ls ; ); cd a; cat " + LL + "EOF; cd b; " + PUSH + "; body; EOF; ls")
shows("a push on a line after the heredoc is named in the folder a cd on the opener's line moves to",
      "cd a; cat " + LL + "EOF; cd b\nbody\nEOF\n" + PUSH, ("a/b", "git", "push", ""))
shows("and in the folder the old text read it in, which is kept", "cd a; cat " + LL + "EOF; cd b\nbody\nEOF\n" + PUSH, ("a", "git", "push", ""))
shows("a push split across the pair in a wrapper's string behind a relative cd is named in its folder",
      "cd a; bash -c 'cd b; gi" + J + "t push'", ("a/b", "git", "push", ""))
# The issue's own shapes, the old text last.
text_is("the command with its body moved up comes first, then a blank, and the old text last and whole",
        "cat " + LL + "EOF; " + PUSH + "\nbody\nEOF", "cat " + LL + "EOF; body; EOF; " + PUSH + " ; cat " + LL + "EOF; " + PUSH + "; body; EOF")
text_is("a heredoc on a command of one line is written again as the here string it amounts to",
        "cat " + LL + "EOF; " + PUSH + "; EOF", "cat " + LL + "<EOF; " + PUSH + "; EOF ; cat " + LL + "EOF; " + PUSH + "; EOF")
text_is("a push across the pair in a wrapper's string stands before the old text", "bash -c 'git " + J + "push'", "bash -c 'git push' ; bash -c 'git \\; push'")
# A backslash that ends the text: written after the old text, the rewritten command would start
# behind an escaped separator, and the old text's last command would be read as one it never was.
text_is("a backslash that ends the text ends the old text here too, and the blank keeps the one that ends the rewritten command off the separator",
        "cat " + LL + "EOF; " + PUSH + "\nbody\nEOF\ntrue \\", "cat " + LL + "EOF; body; EOF; " + PUSH + "; true \\ ; cat " + LL + "EOF; " + PUSH + "; body; EOF; true \\")
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
# Ordinary commands are handed over as they always were.
for what, cmd in (
        ("a heredoc commit with nothing after its opener", "git commit -F - " + LL + "EOF\na message; with a separator\nEOF\n" + PUSH),
        ("a plain chain", "git add f && git commit -m x && " + PUSH),
        ("a push across the pair outside any quote", "git " + J + "push origin main"),
        ("a here string", "cat " + LL + "<EOF; " + PUSH),
        ("a shift in arithmetic", "echo $((1" + LL + "2)); git status"),
        ("a comment after an opener", "cat " + LL + "EOF; # note\nbody\nEOF"),
        ("a text only the crude cut reads", "cat " + LL + "EOF; " + PUSH + "\nbody\nEOF\n( echo")):
    unchanged("control: %s is handed over as it always was" % what, cmd)
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

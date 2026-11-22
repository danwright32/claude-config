#!/usr/bin/env bash
# Where a comment starts, as the shared command reader (lib/shell-words.py commands()) decides it,
# against the shells themselves (claude-config#3464).
#
# The reader took a # for a comment whenever the character before it was white space, a separator or
# a parenthesis. The shell starts a comment only where a WORD starts: not after a space, a ; or a
# parenthesis that a backslash escapes, not after the ) closing a $( ), a <( ) or a $(( )), which is
# still inside its word, and not on a line a backslash joined to a word. Read as a comment there,
# the rest of the line was nobody's text, so a command after a ; on that line was never given to any
# gate that reads commands through the reader, while the shell ran it.
#
# Each row is a text built around one #, holding a marker command (touch ran) placed so that whether
# the shell runs it depends on whether that # starts a comment: in a `same` text the marker follows
# the # on its line, and runs only where the # starts none; in a `next` text it is on the line after
# a comment holding an apostrophe, and runs only where the # does start one. This machine's bash,
# and its zsh where there is one, run each text in an empty throwaway directory (nothing but echo,
# true, cat and that touch is ever run), and the reader is asked whether it lists the marker as a
# command of its own. THE PROPERTY: wherever a shell runs the marker, the reader lists it, says it
# cannot read the text, or names the # line as one it is not sure of (its `unsure`, which the Slack
# drafts gate refuses as a check it could not make). The controls hold the other side: a real
# comment is still left out and never named, so nothing was fixed by doubting every #.
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

T="$(mktemp -d "${TMPDIR:-/tmp}/comment-start.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

echo "the command reader: a # starts a comment only where the shell starts one (claude-config#3464)"

# One line for each check: "ok<TAB>description" or "FAIL<TAB>description<TAB>why".
python3 -B - "$SW" "$T" > "$T/rows.tsv" <<'PY'
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

sw_path, scratch = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("shell_words", sw_path)
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)

# (description, the text up to the #, how the text is closed where the prefix opened something)
PREFIXES = [
    ("a space before it", "echo a ", ""),
    ("mid word (a#b)", "echo a", ""),
    ("an escaped space before it", "echo a\\ ", ""),
    ("an escaped backslash, then a space", "echo a\\\\ ", ""),
    ("three backslashes, then a space", "echo a\\\\\\ ", ""),
    ("an escaped tab before it", "echo a\\\t", ""),
    ("a ; before it", "echo a;", ""),
    ("an escaped ; before it", "echo a\\;", ""),
    ("an escaped & before it", "echo a\\&", ""),
    ("an escaped | before it", "echo a\\|", ""),
    ("an escaped ( before it", "echo a\\(", ""),
    ("an escaped ) before it", "echo a\\)", ""),
    ("escaped itself", "echo a \\", ""),
    ("after &&", "true &&", ""),
    ("after a pipe", "echo a |", ""),
    ("after a backgrounding &", "true &", ""),
    ("right after a $( )", "echo $(echo b)", ""),
    ("a space after a $( )", "echo $(echo b) ", ""),
    ("right after a backquote", "echo `echo b`", ""),
    ("right after a <( )", "cat <(echo b)", ""),
    ("right after a $(( ))", "echo $((1))", ""),
    ("right after an arithmetic command", "((1))", ""),
    ("right after a subshell", "(echo a)", ""),
    ("at the start of a subshell", "(", ")"),
    ("at the start of a $( )", "echo $(", ")"),
    ("at the start of a <( )", "cat <(", ")"),
    ("after double quotes", 'echo "a"', ""),
    ("after single quotes", "echo 'a'", ""),
    ("after a ${ }", "echo ${x}", ""),
    ("after a $ ($#)", "echo $", ""),
    ("a line joined mid word", "echo a\\\n", ""),
    ("a line joined after a space", "echo a \\\n", ""),
    ("a line joined after an escaped space", "echo a\\ \\\n", ""),
    ("two lines joined mid word", "echo a\\\n\\\n", ""),
    ("two lines joined after a space", "echo a \\\n\\\n", ""),
    ("a line joined at the start of the text", "\\\n", ""),
    ("a line joined after a ;", "echo a;\\\n", ""),
    ("a line joined after an escaped ;", "echo a\\;\\\n", ""),
    ("a line joined after a $( )", "echo $(echo b)\\\n", ""),
    ("at the start of the text", "", ""),
    ("at the start of a line", "echo a\n", ""),
    ("right after an array", "x=(a b)", ""),
    ("in an array, after a space", "x=(a ", ")"),
    ("at the start of an array", "x=(", ")"),
    ("in an array, after an escaped space", "x=(a\\ ", ")"),
    ("in an array, mid word", "x=(a", ")"),
    ("in an array, on a line joined mid word", "x=(a\\\n", ")"),
    ("right after a function's ( )", "f()", "{ :; }"),
    ("right after a case pattern", "case a in a)", ";; esac"),
    ("after a | in a case pattern", "case a in b|", "a) ;; esac"),
    ("after a redirection", "echo a >/dev/null", ""),
    ("after a here string", "cat <<<a ", ""),
    ("after then", "if true; then ", "fi"),
    ("after a {", "{ ", "}"),
    ("in a $( ) in double quotes, after an escaped space", 'echo "$(echo a\\ ', ')"'),
    ("in a $( ) in double quotes, after a space", 'echo "$(echo a ', ')"'),
    ("in backquotes, after a space", "echo `echo a ", "`"),
    ("in backquotes, after an escaped space", "echo `echo a\\ ", "`"),
    ("in backquotes, after two backslashes and a space", "echo `echo a\\\\ ", "`"),
    ("in backquotes, after four backslashes and a space", "echo `echo a\\\\\\\\ ", "`"),
    ("in backquotes, on a line joined mid word", "echo `echo a\\\n", "`"),
]
# Texts written out whole: (description, kind, text).
WHOLE = [
    ("in double quotes", "same", 'echo "a # c"; touch ran\n'),
    ("in single quotes", "same", "echo 'a # c'; touch ran\n"),
    ("in a $'...' string", "same", "echo $'a # c'; touch ran\n"),
    ("in a ${#x}", "same", "echo ${#x}; touch ran\n"),
    # Whatever the rest of the line holds, the line is named.
    ("an escaped space before it, the rest of the line a whole string", "same", "echo a\\ # 'x'; touch ran\necho done\n"),
    ("an escaped space before it, the rest of the line opening a string", "open", "echo a\\ # 'x\ntouch ran\n'\n"),
    ("an escaped space before it, the line joined to the next", "open", "echo a\\ # c \\\ntouch ran\n"),
    ("an escaped space before it, the rest of the line opening a heredoc", "open", "echo a\\ # <<E\ntouch ran\nE\n"),
    ("an escaped space before it, the rest of the line holding a cd", "open", "echo a\\ # c; cd .\ntouch ran\n"),
    ("an escaped space before it, the rest of the line closing a subshell", "open", "(echo a\\ # c )\ntouch ran\n"),
    ("in backquotes closed on a later line, after a space", "same", "echo `echo a # c; touch ran\n`\n"),
    ("in backquotes closed on a later line, after a space", "next", "echo `echo a # it's\ntouch ran\n`\necho 'x'\n"),
    ("in backquotes closed on a later line, after an escaped space", "same", "echo `echo a\\ # c; touch ran\n`\n"),
    ("in backquotes closed on a later line, after an escaped space", "next", "echo `echo a\\ # it's\ntouch ran\n`\necho 'x'\n"),
    ("in backquotes closed on a later line, after two backslashes and a space", "same", "echo `echo a\\\\ # c; touch ran\n`\n"),
    ("in backquotes closed on a later line, after two backslashes and a space", "next", "echo `echo a\\\\ # it's\ntouch ran\n`\necho 'x'\n"),
    ("in a heredoc body's $( ), after an escaped space", "same", "cat <<E\n$(echo a\\ # c; touch ran\n)\nE\n"),
    ("in a heredoc body's $( ), after a space", "same", "cat <<E\n$(echo a # c; touch ran\n)\nE\n"),
    ("in a heredoc body's $( ), after a space", "next", "cat <<E\n$(echo a # it's\ntouch ran\n)\nE\necho 'x'\n"),
    ("in a heredoc body's $( ), after two backslashes and a space", "same", "cat <<E\n$(echo a\\\\ # c; touch ran\n)\nE\n"),
    ("in a heredoc body's $( ), after two backslashes and a space", "next", "cat <<E\n$(echo a\\\\ # it's\ntouch ran\n)\nE\necho 'x'\n"),
]
# The controls: a real comment, which the reader must go on leaving out (`same`: the marker on its
# line is listed by nobody) and reading past (`next`: the marker on the next line is listed).
REAL = {"a space before it", "an escaped backslash, then a space", "a ; before it", "after &&",
        "after a pipe", "after a backgrounding &", "a space after a $( )", "right after a subshell",
        "at the start of a subshell", "at the start of a $( )", "a line joined after a space",
        "two lines joined after a space", "a line joined at the start of the text",
        "a line joined after a ;", "at the start of the text", "at the start of a line",
        "right after a case pattern", "after a here string", "after then", "after a {",
        "in a $( ) in double quotes, after a space", "in backquotes, after a space",
        "in backquotes closed on a later line, after a space",
        "right after an arithmetic command"}
# A # the shell reads inside a word (`same`: the shell runs the marker after the ;). Where the
# reader always read it as text, the marker is listed (PLAIN). Where it took the # for a comment,
# it still does, and names the line as one it is not sure of.
WORD = {"mid word (a#b)", "an escaped space before it", "three backslashes, then a space",
        "an escaped tab before it", "an escaped ; before it", "an escaped & before it",
        "an escaped | before it", "an escaped ( before it", "an escaped ) before it",
        "escaped itself", "right after a $( )", "right after a backquote", "right after a <( )",
        "right after a $(( ))", "after double quotes", "after single quotes", "after a ${ }",
        "after a $ ($#)", "a line joined mid word", "a line joined after an escaped space",
        "two lines joined mid word", "a line joined after an escaped ;", "a line joined after a $( )",
        "in double quotes", "in single quotes",
        "in a $'...' string", "in a ${#x}",
        "an escaped space before it, the rest of the line a whole string"}
PLAIN = {"mid word (a#b)", "escaped itself", "right after a backquote", "after double quotes",
         "after single quotes", "after a ${ }", "after a $ ($#)", "in double quotes", "in single quotes",
         "in a $'...' string", "in a ${#x}"}
# Where the reader must name the line as one it is not sure of, as (description, kind): bash reads a # right
# after an array's ) inside the word and zsh as a comment; and bash ends backquotes at the next
# backquote whether or not a comment stands before it, so a comment with one after it on its line
# does not run to the line's end.
UNSURE = {("right after an array", "same"), ("right after an array", "next"),
          ("in backquotes, after a space", "same")}


def texts(prefix, close):
    if close:
        yield "same", prefix + "# c " + close + "; touch ran\n" + close + "\n"
        yield "next", prefix + "# it's\ntouch ran\n" + close + "\necho 'x'\n"
    else:
        yield "same", prefix + "# c; touch ran\necho done\n"
        yield "next", prefix + "# it's\ntouch ran\necho 'x'\n"


SHELLS = {"bash": ["bash", "--noprofile", "--norc", "-c"], "zsh": ["zsh", "-f", "-c"]}
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
    marks = []
    try:
        cut = sw.commands(text, unsure=marks)
    except sw.Unreadable:
        # A # read as a comment can hide the ) or the quote that closes something, so the line is
        # named before the reading gives up, and a caller looks at the names either way.
        return "unsure" if marks else "unreadable"
    if marks:
        return "unsure"
    return "listed" if any(t.strip() == "touch ran" for _, t in cut) else "not listed"


def say(ok, what, why=""):
    print("ok\t" + what if ok else "FAIL\t" + what + "\t" + why)


# A caller that does not ask is given the commands it was always given: other gates read through
# the reader, and what a line the reader is not sure of means to each is that gate's to decide.
asked, unasked = [], sw.commands("echo a\\ # c; touch ran\necho done\n")
sw.commands("echo a\\ # c; touch ran\necho done\n", unsure=asked)
say([t.strip() for _, t in unasked] == ["echo a\\", "echo done"] and asked == [(8, 22)],
    "#3464 the reading itself is unchanged, and the line is named only to a caller that asks",
    "commands gave %r and named %r" % (unasked, asked))
real = []
sw.commands("echo a # c; touch ran\necho done\n", comments=real)
say(real == [(7, 21)], "#3464 a comment the shell starts too is given to comments", "named %r" % (real,))

rows = [(name, kind, text) for name, prefix, close in PREFIXES for kind, text in texts(prefix, close)]
rows += WHOLE
print("shells\t" + " ".join(HAVE))
for name, kind, text in rows:
    got = reading(text)
    ran = [shell for shell in HAVE if runs(shell, text)]
    shown = text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
    say(not (ran and got == "not listed"),
        "#3464 a command the shell runs is never left out: a # %s (%s)" % (name, kind),
        "%s ran the marker and the reader left it out: [%s]" % (" and ".join(ran), shown))
    if name in REAL and (name, kind) not in UNSURE:
        want = "not listed" if kind == "same" else "listed"
        say(got == want, "#3464 the control: a real comment is still one: a # %s (%s)" % (name, kind),
            "the reader said %s, wanted %s: [%s]" % (got, want, shown))
    if name in WORD and kind == "same":
        want = "listed" if name in PLAIN else "unsure"
        say(got == want, "#3464 a # the shell reads inside a word hides nothing: a # %s" % name,
            "the reader said %s, wanted %s: [%s]" % (got, want, shown))
    if (name, kind) in UNSURE or kind == "open":
        say(got == "unsure", "#3464 where it cannot be told the line is named: a # %s (%s)" % (name, kind),
            "the reader said %s, wanted unsure: [%s]" % (got, shown))
PY
rc=$?
[ "$rc" -eq 0 ] || check "the comparison ran to its end" "python3 exited $rc"

SHELLS_READ=""
while IFS=$'\t' read -r verdict what why; do
  case "$verdict" in
    ok) check "$what" ok ;;
    FAIL) check "$what" "$why" ;;
    shells) SHELLS_READ="$what" ;;
    *) check "a row of the comparison is one this suite reads" "got: $verdict" ;;
  esac
done < "$T/rows.tsv"

case " $SHELLS_READ " in
  *" bash "*) check "the texts were run by this machine's bash" ok ;;
  *) check "the texts were run by this machine's bash" "no bash was found, so no row was measured against a shell" ;;
esac
case " $SHELLS_READ " in
  *" zsh "*) ;;
  *) echo "UNMEASURED: there is no zsh on this machine, so each text was run by bash alone." ;;
esac
# A run that compared nothing must not read as a pass.
[ "$pass" -ge 150 ] || check "the comparison checked its rows" "only $pass checks passed, of the 210 or so the table makes"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# The crude fallback reader (lib/shell-words.py crude_commands()) lists a command written inside a
# substitution or a subshell (claude-config#3473).
#
# When the shared command reader cannot read a text it raises Unreadable, and its callers judge the
# crude cut in its place: the text cut at every separator. That cut did not look inside a $( ), a
# pair of backquotes, a <( ), a >( ) or a subshell, so in a text the reader could not read (one with
# a quote left open on another line) `x=$(git push origin main)` gave a gate no git command at all,
# and `(git push)` gave it the subcommand `push)`, which no gate matching a subcommand by its name
# matches. The fallback runs exactly where the text is hardest to read, which is where a gate most
# needs a sound answer.
#
# What this suite holds (the pull request's "Must always be true"):
#   R1  a command inside any of those is handed on as a command of its own, with its own words;
#   R2  every record the crude cut gave before it still gives, same text, same directory, same
#       order, and before anything it adds, so no gate is handed less than it was and a gate that
#       reads the records in order reaches the old ones first;
#   R3  a text the reader can read never reaches the crude reader.
# Each R1 row first proves the reader cannot read its text: a row the reader could read would pass
# without the crude reader ever being asked (L246).
#
# claude-config#3786 adds four shapes the cut still read past, each run by the shells of this
# machine beside the reader: a command after a single ampersand, a cd inside a subshell or a $( )
# that governs what follows it there, a command after coproc, and one inside ${ cmd; }. R2 holds
# for them against the cut as #3473 left it: every record it gave is still given.
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

T="$(mktemp -d "${TMPDIR:-/tmp}/crude-inner.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

echo "the crude reader: a command inside a substitution or a subshell is listed (claude-config#3473)"

# One line for each check: "ok<TAB>description" or "FAIL<TAB>description<TAB>why".
python3 -B - "$SW" "$T" > "$T/rows.tsv" <<'PY'
import collections
import importlib.util
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

sw_path, scratch = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("shell_words", sw_path)
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)


def row(what, why=""):
    what = what.replace("\t", " ").replace("\n", " ")
    why = why.replace("\t", " ").replace("\n", "\\n")
    sys.stdout.write(("FAIL\t%s\t%s\n" % (what, why)) if why else ("ok\t%s\n" % what))


def unreadable(text):
    try:
        sw.commands(text)
    except sw.Unreadable:
        return True
    return False


def pushes(records):
    """The (subcommand, arguments) of each git command among _records' records."""
    out = []
    for rec in records:
        parts = rec[5].split("\x1d")
        if parts[0] == "git":
            out.append((parts[1] if len(parts) > 1 else "", parts[3] if len(parts) > 3 else ""))
    return out


# A quote left open on a later line: what makes the reader give the text up.
OPEN = "\necho 'never closed"
PUSH = ("push", "origin\x1fmain")

# ---- R1: each place a command can be written inside another -------------------------------------
INSIDE = [
    ("a $( ) setting a variable", "x=$(git push origin main)"),
    ("a $( ) among a command's words", "echo $(git push origin main) done"),
    ("a $( ) inside double quotes", 'echo "now $(git push origin main)"'),
    ("backquotes setting a variable", "x=`git push origin main`"),
    ("backquotes among a command's words", "echo `git push origin main` done"),
    ("a <( )", "cat <(git push origin main)"),
    ("a >( )", "tee >(git push origin main)"),
    ("a zsh =( )", "cat =(git push origin main)"),
    ("a subshell, the parentheses glued on", "(git push origin main)"),
    ("a subshell, the parentheses spaced", "( git push origin main )"),
    ("a subshell, after a cd in it", "(cd /tmp/x && git push origin main)"),
    ("a subshell sent to a file", "(git push origin main) > /tmp/out.log"),
    ("the last command of a $( )", "x=$(cd /tmp/x; git push origin main)"),
    ("the first command of a $( )", "x=$(git push origin main; echo done)"),
    ("backquotes inside a $( )", 'echo "$(echo `git push origin main`)"'),
    ("a $( ) inside a subshell", "(echo $(git push origin main))"),
    ("a subshell inside a $( )", "x=$( (git push origin main) )"),
    ("a $( ) inside a ${ }", "echo ${x:-$(git push origin main)}"),
    ("a case arm on its pattern's line", "case $x in\n  a) git push origin main ;;\nesac"),
]
for what, text in INSIDE:
    text += OPEN
    if not unreadable(text):
        row("%s: the reader cannot read the text, so the crude reader is what answers" % what,
            "commands() read it, so this row measured nothing about the crude reader")
        continue
    records, crude = sw._records(text, "", 0)
    got = pushes(records)
    row("%s: the push is listed with its own words" % what,
        "" if crude and PUSH in got else "crude=%r, git commands read: %r" % (crude, got))
    every = [t.strip() for _, t, _, _, _ in sw.every_command(text)]
    row("%s: every_command hands it on too" % what,
        "" if "git push origin main" in every else "texts: %r" % (every,))

# The issue's second measurement by itself: the subcommand came back as `push)`.
text = "(git push)" + OPEN
got = pushes(sw._records(text, "", 0)[0]) if unreadable(text) else None
row("a subshell holding only `git push`: the subcommand is `push`, no parenthesis on it",
    "" if got is not None and ("push", "") in got else "git commands read: %r" % (got,))

# A string a wrapper runs is read the same way when it is the part that cannot be read.
text = "bash -c 'x=$(git push origin main)\necho \"never closed'"
records, crude = sw._records(text, "", 0)
inner = [r for r in records if r[6] == 1]
row("a wrapper's string the reader cannot read: the push inside its $( ) is listed",
    "" if not crude and PUSH in pushes(inner) else "crude=%r inner git commands: %r" % (crude, pushes(inner)))

# The two modes a shell caller reads, each exit 3 with the push among the records.
text = "x=$(git push origin main)" + OPEN
for mode in ("read", "commands"):
    p = subprocess.run([sys.executable, "-B", sw_path, mode], input=text.encode(), stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE)
    recs = [r for r in p.stdout.decode().split("\x1e") if r.strip("\n")]
    if mode == "read":
        found = any(r.split("\x1c")[7].startswith("git\x1dpush\x1d") for r in recs if r.count("\x1c") >= 7)
    else:
        found = any(r.split("\x1f", 1)[-1].strip() == "git push origin main" for r in recs)
    row("the `%s` mode: exit 3 and the push inside the $( ) among its records" % mode,
        "" if p.returncode == 3 and found else "exit %d, %d records, push found: %r" % (p.returncode, len(recs), found))

# ---- controls: what must not change -------------------------------------------------------------
# The head of a command that holds a substitution is not listed a second time: the record for the
# whole command already is that command, and a gate that counts commands must not count it twice.
text = "git push origin main $(echo x)" + OPEN
got = pushes(sw._records(text, "", 0)[0]) if unreadable(text) else None
row("a command holding a substitution is listed once, not once more for its head",
    "" if got is not None and len([g for g in got if g[0] == "push"]) == 1 else "git commands read: %r" % (got,))

# A backquote is not told as opening or closing: the cut splits a pair of them that holds a
# separator, and then the first backquote of a piece closes. So what stands before a backquote is
# always listed, and a command holding a pair of them is given twice. Both halves are held here, so
# neither is traded for the other without a row failing.
text = "x=`cd /tmp/x; git push origin main`" + OPEN
got = pushes(sw._records(text, "", 0)[0]) if unreadable(text) else None
row("the last command inside backquotes, cut from its opener by a separator, is listed with its own words",
    "" if got is not None and PUSH in got else "git commands read: %r" % (got,))
text = "git push origin main `date`" + OPEN
got = pushes(sw._records(text, "", 0)[0]) if unreadable(text) else None
row("a command holding backquotes is given whole and once more up to the first backquote",
    "" if got is not None and sorted(got) == sorted([PUSH, ("push", "origin\x1fmain\x1f`date`")])
    else "git commands read: %r" % (got,))

# A text holding no parenthesis and no backquote is cut exactly as it always was.
text = "cd /tmp/a && git status; echo b | cat" + OPEN
want = [("", "cd /tmp/a "), ("/tmp/a", " git status"), ("/tmp/a", " echo b "), ("/tmp/a", " cat"),
        ("/tmp/a", "echo 'never closed")]
got = sw.crude_commands(text)
row("a text with no parenthesis and no backquote is cut as it always was",
    "" if got == want else "got %r" % (got,))

# Nothing blank is listed.
got = sw.crude_commands("() `` $( ) ( )" + OPEN)
row("an empty pair of parentheses or backquotes lists no blank command",
    "" if all(t.strip() for _, t in got) else "got %r" % (got,))

# A cd inside a substitution moves no command outside it: the push stays where it was read before.
text = "cd /tmp/a\nx=$(cd /tmp/b && ls)\ngit push origin main" + OPEN
dirs = [r[0] for r in sw._records(text, "", 0)[0] if r[5].startswith("git\x1dpush")]
row("a cd inside a substitution leaves the directory of the commands after it alone",
    "" if dirs == ["/tmp/a"] else "the push was read in %r" % (dirs,))


# ---- a parenthesis written straight after a name starts no command -------------------------------
# No shell runs what stands in a parenthesis glued to a name. Measured 2026-11-26, each text run by
# bash, zsh, dash and sh in an empty folder: `open(touch x)`, `f(touch x)`, `x=1(touch x)`,
# `$x(touch x)` and `cat = open(touch x).read()` made no file in any of them. The words that only
# open or continue a compound command are the exception (RESERVED): bash, dash and sh ran
# `if(touch x); then :; fi`, and the same glued to then, else, elif, do, while and until, and bash
# and sh after time.
#
# Listing what follows such a parenthesis made a gate say what nothing measured (L11). The pull
# request's checks found it: a script feeding python3 a heredoc holding `cat = open("$1").read()`,
# with a quote left open after it, had `"$1"` listed as a command of its own, and the Slack drafts
# gate refused it as a script that "runs a command named by its arguments ($1)". It runs none.
def texts(text):
    """Each command the crude reader hands on for a text the reader cannot read, as it is written."""
    if not unreadable(text):
        return None
    return [t.strip() for _, t, _, _, _ in sw.every_command(text)]


text = 'python3 <<EOF\necho = 1\ncat = open("$1").read()\nEOF' + OPEN
got = texts(text)
row("a heredoc's Python calling open(\"$1\"): no command named by $1 is listed",
    "" if got is not None and '"$1"' not in got else "commands handed on: %r" % (got,))
for what, line in (("a name", "open(touch x)"), ("an assignment", "x=1(touch x)"),
                   ("a variable", "$x(touch x)"), ("a dotted name", "os.path.join(touch x)")):
    got = texts(line + OPEN)
    row("a parenthesis glued to %s, `%s`: what follows it is no command" % (what, line),
        "" if got is not None and "touch x" not in got else "commands handed on: %r" % (got,))

# The other side, so the rule above cannot be widened to every glued parenthesis without a row
# failing: after a reserved word, after a function's `()`, and with no name before it, the
# parenthesis opens a subshell and its command is listed.
for what, line in (
    ("if", "if(git push origin main); then :; fi"),
    ("then", "if true; then(git push origin main); fi"),
    ("else", "if false; then :; else(git push origin main); fi"),
    ("elif", "if false; then :; elif(git push origin main); then :; fi"),
    ("do", "for i in 1; do(git push origin main); done"),
    ("while", "while(git push origin main); do :; done"),
    ("until", "until(git push origin main); do :; done"),
    ("time", "time(git push origin main)"),
    ("a function's ()", "deploy()(git push origin main)"),
):
    text = line + OPEN
    got = pushes(sw._records(text, "", 0)[0]) if unreadable(text) else None
    row("a parenthesis glued to %s, `%s`: the push in it is listed with its own words" % (what, line),
        "" if got is not None and PUSH in got else "git commands read: %r" % (got,))
for line in ('( "$1" )', '("$1")', 'if("$1"); then :; fi'):
    got = texts(line + OPEN)
    row("a subshell that runs the first argument, `%s`: a command named by $1 is listed" % line,
        "" if got is not None and '"$1"' in got else "commands handed on: %r" % (got,))
# A closing parenthesis ends a command whatever opened it: the parenthesis glued to a name inside
# a quoted word does not take the `)` that closes the substitution around it.
text = 'x=$(git push origin "a(b")' + OPEN
got = pushes(sw._records(text, "", 0)[0]) if unreadable(text) else None
row("a $( ) whose last word holds a parenthesis glued to a name: the push is listed, its last word whole",
    "" if got is not None and ("push", "origin\x1fa(b") in got else "git commands read: %r" % (got,))

# ---- four more shapes: a single &, a cd inside a nest, coproc and ${ cmd; } (claude-config#3786) ----
# Each text is run by the shells of this machine in an empty throwaway directory, where nothing but
# mkdir, cd, touch, true, echo, sleep and wait can run, and the reader is asked about the same text
# with a quote left open after it and `git push origin main` where the shell was given the marker.
# The marker is `touch ran` where the command runs in the folder the text starts in, and
# `touch ../ran` where it runs after a `cd d`: either way a file named ran at the top says the
# command ran, and ran where the row says it does.
#
# bash here is /bin/bash, 3.2 on a Mac, which has no coproc and no ${ cmd; }. zsh 5.9 has coproc
# and ksh 93 has ${ cmd; }, so those rows are measured by the shell that reads them, and a row no
# shell on this machine reads says so on a SUITE-PART-UNMEASURED line (L411).
SHELLS = {"bash": ["/bin/bash", "--noprofile", "--norc", "-c"], "zsh": ["zsh", "-f", "-c"],
          "sh": ["sh", "-c"], "dash": ["dash", "-c"], "ksh": ["ksh", "-c"]}
HAVE = [name for name in SHELLS if shutil.which(SHELLS[name][0])]
print("shells\t" + " ".join(HAVE))


def cut_before(s, cwd=""):
    """The crude cut as it was before claude-config#3473, word for word: the pieces, and the
    reference for R2."""
    out, old = [], None
    for text in re.split(r"&&|\|\||;|\||\n", s):
        if text.strip():
            out.append((cwd, text))
            target = sw.cd_target(text)
            if target is not None:
                cwd, old = sw.moved(cwd, old, target)
    return out


def ran(shell, text):
    """Whether the shell, given the text in an empty folder, left a file named ran at its top."""
    d = tempfile.mkdtemp(prefix="run-", dir=scratch)
    try:
        subprocess.run(SHELLS[shell] + [text], cwd=d, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=20,
                       env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": d})
        return os.path.exists(os.path.join(d, "ran"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def pushes_in(records):
    """The (directory, subcommand, arguments) of each git command among _records' records."""
    out = []
    for rec in records:
        parts = rec[5].split("\x1d")
        if parts[0] == "git":
            out.append((rec[0], parts[1] if len(parts) > 1 else "", parts[3] if len(parts) > 3 else ""))
    return out


EVERY = None           # every shell here reads the text
NEWER = ()             # only a bash newer than 3.2 reads it, and this machine may have none
# (what, the text with %s where the command stands, the shells that read it, the directory it runs in)
MORE = [
    # a: a command after a single ampersand
    ("after a backgrounding &", "sleep 0 & %s", EVERY, ""),
    ("after a & glued to both words", "sleep 0&%s", EVERY, ""),
    ("after two of them", "true & true & %s", EVERY, ""),
    ("after a & inside a $( )", "x=$(true & %s)", EVERY, ""),
    ("after a & inside a subshell", "(true & %s)", EVERY, ""),
    ("before a &, with its own words", "%s & wait", EVERY, ""),
    ("after &! with a space", "true &! %s", EVERY, ""),
    ("after zsh's &! glued to it", "true &!%s", ("zsh",), ""),
    ("after |&", "true |& %s", ("zsh", "ksh"), ""),
    ("after the file of a &>, which dash and ksh read as a & and a >", "echo a &> out %s", ("dash", "ksh"), ""),
    ("after the file of a &>>, read the same way", "echo a &>> out %s", ("dash", "ksh"), ""),
    # b: a cd inside a subshell or a substitution governs what follows it there, and nothing outside
    ("after a cd in a subshell", "mkdir d; (cd d && %s)", EVERY, "d"),
    ("after a cd in a subshell, more after it", "mkdir d; (cd d && %s && true)", EVERY, "d"),
    ("after a cd in a $( )", "mkdir d; x=$(cd d; %s)", EVERY, "d"),
    ("after a cd in backquotes", "mkdir d; x=`cd d; %s`", EVERY, "d"),
    ("after a cd that follows a &", "mkdir d; true & cd d; %s", EVERY, "d"),
    ("after a cd in a case arm", "mkdir d; case a in a) cd d;; esac; %s", EVERY, "d"),
    ("after a subshell that held a cd", "mkdir d; (cd d); %s", EVERY, ""),
    ("after a $( ) that held a cd between two commands", "mkdir d; x=$(true; cd d; true); %s", EVERY, ""),
    ("after a cd sent to the background", "mkdir d; cd d & %s", EVERY, ""),
    ("after a cd in a list sent to the background, as bash, sh, dash and ksh run it", "mkdir d; cd d && true & %s",
     ("bash", "sh", "dash", "ksh"), ""),
    ("after a cd before a &>, as dash and ksh run it", "mkdir d; cd d &> /dev/null; %s", ("dash", "ksh"), ""),
    # c: a command after coproc
    ("after coproc", "coproc %s; wait", ("zsh",), ""),
    ("in braces after coproc", "coproc { %s; }; wait", ("zsh",), ""),
    ("in a subshell after coproc", "coproc (%s); wait", ("zsh",), ""),
    ("in braces after coproc and a name", "coproc X { %s; }; wait", NEWER, ""),
    ("in a subshell after coproc and a name", "coproc X (%s); wait", NEWER, ""),
    ("in a parenthesis glued to coproc", "coproc(%s); wait", NEWER, ""),
    # d: a command inside ${ cmd; }
    ("in a ${ } among a command's words", "echo ${ %s; }", ("ksh",), ""),
    ("in a ${ } setting a variable", "x=${ %s; }", ("ksh",), ""),
    ("in a ${ } inside double quotes", 'echo "${ %s; }"', ("ksh",), ""),
    ("in a ${ } opened with a tab", "echo ${\t%s; }", ("ksh",), ""),
    ("after a cd in a ${ }, which moves the shell", "mkdir d; x=${ cd d; }; %s", ("ksh",), "d"),
]
measured = 0
for what, shape, readers, where in MORE:
    marker = shape % ("touch ../ran" if where else "touch ran")
    text = shape % "git push origin main" + OPEN
    if not unreadable(text):
        row("#3786 %s: the reader cannot read the text, so the crude reader is what answers" % what,
            "commands() read it, so this row measured nothing about the crude reader")
        continue
    got = pushes_in(sw._records(text, "", 0)[0])
    row("#3786 %s: the push is listed with its own words, in the folder it runs in (%r)" % (what, where),
        "" if (where, "push", "origin\x1fmain") in got else "git commands read: %r" % (got,))
    # Past the `!`, the `{` or the redirect that may stand before it, which every caller looks past.
    every = [(d, sw.program_field(t)[0].strip()) for d, t, _, _, _ in sw.every_command(text)]
    row("#3786 %s: every_command hands it on too" % what,
        "" if (where, "git push origin main") in every else "commands: %r" % (every,))
    asked_of = [s for s in HAVE if readers is EVERY or s in readers]
    if not asked_of:
        print("unmeasured\twhat a shell does with [%s] (%s), because no shell on this machine reads it: %s"
              % (marker.replace("\t", "\\t").replace("\n", "\\n"), what,
                 "it takes a bash newer than 3.2" if readers is NEWER else "it takes " + " or ".join(readers)))
        continue
    lazy = [s for s in asked_of if not ran(s, marker)]
    measured += 1
    row("#3786 %s: %s ran the command there" % (what, " and ".join(asked_of)),
        "" if not lazy else "%s did not: [%s]" % (" and ".join(lazy), marker))
# A run in which no shell ran anything compared the reader with nothing.
print("ran\t%d" % measured)

# The other side of the single ampersand: where it is half of a redirect no command starts, in any
# shell here, and the cut adds nothing to what it gave before. `>&` and `<&`, with a number, a
# file name, a descriptor or a dash after them, are every such spelling: the & is written straight
# after the angle bracket. Each is run with the marker's words after it, which a shell that read a
# command there would run.
for what, shape in (
    ("2>&1", "echo a 2>&1 %s"),
    (">&2", "echo a >&2 %s"),
    ("1>&2", "echo a 1>&2 %s"),
    (">& and a file", "echo a >& out %s"),
    ("<&0", "echo a <&0 %s"),
    ("2>&-", "echo a 2>&- %s"),
    (">&- on a cd", "cd . >&- 2>&1 %s"),
    ("2>&1 glued to the words around it", "echo a2>&1b %s"),
):
    marker = shape % "touch ran"
    wrong = [s for s in HAVE if ran(s, marker)]
    row("#3786 the redirect %s: no shell here runs the words after it" % what,
        "" if not wrong else "%s ran them: [%s]" % (" and ".join(wrong), marker))
    text = shape % "git push origin main" + OPEN
    row("#3786 the redirect %s: the cut is what it was, nothing is listed at the &" % what,
        "" if unreadable(text) and sw.crude_commands(text) == cut_before(text)
        else "got %r" % (sw.crude_commands(text),))
# `&>` is the one spelling the shells here do not agree on: bash, zsh and sh take a redirect, and
# dash and ksh send the command to the background and run what follows the file name (the two rows
# for it above). So the cut is made there, and what it lists where nothing follows the file name,
# the way it is nearly always written, is a redirect that names no program.
for line in ("make &> build.log", "make &>> build.log", "make &>/dev/null"):
    text = line + OPEN
    added = [t for _, t in sw.crude_commands(text)[len(cut_before(text)):]]
    programs = [sw.program_field(t)[0].strip() for t in added]
    row("#3786 `%s`: what the cut lists after the & names no program" % line,
        "" if unreadable(text) and programs == ["make", ""] else "listed %r, programs %r" % (added, programs))
for marker in ("echo a &> out touch ran", "echo a &>> out touch ran"):
    wrong = [s for s in HAVE if s in ("bash", "zsh", "sh") and ran(s, marker)]
    row("#3786 `%s`: bash, zsh and sh take the &> for a redirect and run nothing after it" % marker,
        "" if not wrong else "%s ran the words after it" % " and ".join(wrong))
# A cd inside a nest moves nothing outside it, and each record the cut gave is still given where it
# was: the push after `(cd d)` is read in the folder the text starts in, and after a cd in the
# middle of a $( ) it is read there as well as in the folder that cd named, which is where the cut
# always read it.
text = "x=$(true; cd /tmp/b; true)\ngit push origin main" + OPEN
got = pushes_in(sw._records(text, "/tmp/a", 0)[0]) if unreadable(text) else None
row("#3786 after a $( ) holding a cd, the push is read in the folder before it and still in the one the cut gave",
    "" if got is not None and sorted(got) == [("/tmp/a", "push", "origin\x1fmain"), ("/tmp/b", "push", "origin\x1fmain")]
    else "git commands read: %r" % (got,))
# The words `coproc` and `${` inside other words open nothing.
for line in ("echo mycoproc git push origin main", "echo coproc=1 x", "echo ${x} ${y:-z}", "echo my-coproc x"):
    text = line + OPEN
    row("#3786 `%s`: nothing is listed that the cut did not give" % line,
        "" if unreadable(text) and sw.crude_commands(text) == cut_before(text) else "got %r" % (sw.crude_commands(text),))

# ---- R3: a text the reader can read never reaches the crude reader -------------------------------
asked = []
real = sw.crude_commands


def spy(s, cwd=""):
    asked.append(s)
    return real(s, cwd)


sw.crude_commands = spy
for what, text in INSIDE:
    del asked[:]
    records, crude = sw._records(text, "", 0)
    row("%s, in a text the reader can read: the crude reader is never asked" % what,
        "" if not crude and not asked else "crude=%r, asked %d times" % (crude, len(asked)))
sw.crude_commands = real


# ---- R2: every record the cut gave before, it still gives ----------------------------------------
def kept_first(before, after):
    """Whether after starts with before: the same records, in the same order, ahead of anything
    added. A caller that reads the records in order and stops at the first one that settles its
    question then reaches every old record before a new one."""
    return after[:len(before)] == before


# How a text begins is asked of its first command (lib/unknown-program.py's holds_command), so the
# command found inside the first piece must not come before that piece.
got = sw.crude_commands("x=$(mytool y); node x.js" + OPEN)
row("the commands found inside a piece come after every piece of the cut",
    "" if [t for _, t in got] == ["x=$(mytool y)", " node x.js", "echo 'never closed", "mytool y"]
    else "got %r" % (got,))


def cut_3473(s, cwd=""):
    """The crude cut as claude-config#3473 left it, word for word: the pieces, then what stands
    after each opener, closer and backquote of each, in the piece's directory. The reference for
    claude-config#3786's one direction: every record this gave is still given, as many times."""
    edge = re.compile(r"\$\(|[<>=]\(|\(|\)|`")

    def after_a_name(text, at):
        i = at
        while i > 0 and text[i - 1].isascii() and (text[i - 1].isalnum() or text[i - 1] == "_"):
            i -= 1
        return i < at and text[i:at] not in sw.RESERVED

    def inner(text):
        out, at, first = [], 0, True
        for m in edge.finditer(text):
            if m.group() == "(" and after_a_name(text, m.start()):
                continue
            part = text[at:m.start()]
            if part.strip() and (not first or m.group() in (")", "`")):
                out.append(part)
            at, first = m.end(), False
        if not first and text[at:].strip():
            out.append(text[at:])
        return out

    out, found, old = [], [], None
    for text in re.split(r"&&|\|\||;|\||\n", s):
        if text.strip():
            found.extend((cwd, part) for part in inner(text))
            out.append((cwd, text))
            target = sw.cd_target(text)
            if target is not None:
                cwd, old = sw.moved(cwd, old, target)
    return out + found


rng = random.Random(3473)
BITS = ["git push origin main", "echo a", "cd /tmp/a", "cd b", "x=", "(", ")", "$(", "`", "<(", ">(", " ",
        " && ", " || ", "; ", " | ", "\n", '"', "'", "\\", "case x in a)", ";;", "{ ", "}", "#", "$((", "))",
        " & ", "&", "coproc ", "coproc(", "${ ", "${", " &> out", " 2>&1", " >&2", "|& ", "&!", "!"]
lost = strangers = more = fewer = 0
first_lost = first_stranger = first_fewer = ""
TEXTS = 3000
for _ in range(TEXTS):
    text = "".join(rng.choice(BITS) for _ in range(rng.randint(1, 14)))
    before, after = cut_before(text), sw.crude_commands(text)
    gone = collections.Counter(cut_3473(text)) - collections.Counter(after)
    if gone:
        fewer += 1
        first_fewer = first_fewer or "%r is no longer given for %r" % (sorted(gone)[0], text)
    if not kept_first(before, after):
        lost += 1
        first_lost = first_lost or repr(text)
    if any(t not in text for _, t in after):
        strangers += 1
        first_stranger = first_stranger or repr(text)
    if len(after) > len(before):
        more += 1
row("over %d made up texts, the old cut is given first and whole, each record in its directory and order" % TEXTS,
    "" if not lost else "%d texts lost a record or gave a new one ahead of an old one, the first: %s" % (lost, first_lost))
row("#3786 over the same texts, every record the cut gave before this change it still gives, in the same directory, as many times",
    "" if not fewer else "%d texts lost a record, the first: %s" % (fewer, first_fewer))
row("over the same texts, every record's text is written in the text it was cut from",
    "" if not strangers else "%d texts gave a text not written in them, the first: %s" % (strangers, first_stranger))
# Without this the two rows above would pass on a reader that lists nothing new.
row("the made up texts reach the new listing (some text is given more records than before)",
    "" if more >= TEXTS // 10 else "only %d of %d texts were given more records" % (more, TEXTS))


# ---- R1 as a property: the crude reader against the reader itself --------------------------------
# A nest of substitutions and subshells the reader CAN read, built whole so every opener closes.
# Each simple command the reader lists in it (one holding no separator, parenthesis or backquote) the
# crude reader must list too, a command before or after a backgrounding & among them
# (claude-config#3786). No quote, comment or heredoc is made: the crude cut reads those differently
# by design and they are not this property's subject.
SIMPLE = ["git push origin main", "echo a", "ls -la", "git status", "true"]
SEPS = [" && ", " || ", "; ", " | ", "\n", " & ", "&"]


def nest(depth, ticks):
    parts = []
    for _ in range(rng.randint(1, 3)):
        kind = rng.randint(0, 6) if depth < 3 else 0
        if kind == 1:
            parts.append("(" + nest(depth + 1, ticks) + ")")
        elif kind == 2:
            parts.append("echo $(" + nest(depth + 1, ticks) + ")")
        elif kind == 3 and ticks:
            parts.append("x=`" + nest(depth + 1, False) + "`")
        elif kind == 4:
            parts.append("cat <(" + nest(depth + 1, ticks) + ")")
        elif kind == 5:
            parts.append("tee >(" + nest(depth + 1, ticks) + ")")
        else:
            parts.append(rng.choice(SIMPLE))
    out = parts[0]
    for p in parts[1:]:
        out += rng.choice(SEPS) + p
    return out


EDGE = re.compile(r"[()`;|\n&]")
missed = measured = leaves = nested = 0
first_missed = ""
NESTS = 1500
for _ in range(NESTS):
    text = nest(0, True)
    try:
        listed = sw.commands(text)
    except sw.Unreadable:
        continue
    measured += 1
    simple = set(t.strip() for _, t in listed if t.strip() and not EDGE.search(t))
    crude = set(t.strip() for _, t in sw.crude_commands(text))
    leaves += len(simple)
    if "(" in text or "`" in text:
        nested += 1
    gone = sorted(simple - crude)
    if gone:
        missed += 1
        first_missed = first_missed or "%r in %r" % (gone[0], text)
row("over %d made up nests, each simple command the reader lists the crude reader lists too" % NESTS,
    "" if not missed else "%d nests held a command the crude reader did not list, the first: %s" % (missed, first_missed))
# A run that read none of them, or none with anything nested, compared nothing.
row("the made up nests were read and held nested commands",
    "" if measured >= NESTS * 9 // 10 and nested >= NESTS // 2 and leaves >= NESTS
    else "read %d of %d, %d nested, %d simple commands" % (measured, NESTS, nested, leaves))
PY
py_rc=$?
check "the python comparison ran to its end" "$([ "$py_rc" -eq 0 ] && echo ok || echo "it exited $py_rc")"

SHELLS_READ=""
RAN_MORE=0
while IFS=$'\t' read -r verdict what why; do
  case "$verdict" in
    ok) check "$what" ok ;;
    FAIL) check "$what" "$why" ;;
    shells) SHELLS_READ="$what" ;;
    ran) RAN_MORE="$what" ;;
    unmeasured) echo "SUITE-PART-UNMEASURED $what" ;;
    *) check "a row of the comparison is one this suite reads" "got: $verdict" ;;
  esac
done < "$T/rows.tsv"

# The shells the #3786 rows were run by. bash is /bin/bash; a machine without one of the others
# says which rows it could not measure, on the rows' own lines above and here for the shell.
case " $SHELLS_READ " in
  *" bash "*) check "the #3786 texts were run by this machine's /bin/bash" ok ;;
  *) check "the #3786 texts were run by this machine's /bin/bash" "there is no /bin/bash, so no row was measured against it" ;;
esac
for shell in zsh sh dash ksh; do
  case " $SHELLS_READ " in
    *" $shell "*) ;;
    *) echo "SUITE-PART-UNMEASURED what $shell does with each #3786 text, because there is no $shell on this machine" ;;
  esac
done
# A run in which the shells ran next to nothing compared the reader with nothing.
[ "$RAN_MORE" -ge 20 ] && check "the shells here ran the commands of the #3786 texts" ok \
  || check "the shells here ran the commands of the #3786 texts" "a shell ran the command in only $RAN_MORE of the 33 texts, where 20 or more were wanted"

# A run that compared nothing must not read as a pass.
[ "$pass" -ge 150 ] || check "the comparison checked its rows" "only $pass checks passed, of the 190 or so the table makes"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]

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
python3 -B - "$SW" > "$T/rows.tsv" <<'PY'
import importlib.util
import random
import re
import subprocess
import sys

sw_path = sys.argv[1]
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
def cut_before(s, cwd=""):
    """The crude cut as it was before claude-config#3473, word for word: the reference for R2."""
    out, old = [], None
    for text in re.split(r"&&|\|\||;|\||\n", s):
        if text.strip():
            out.append((cwd, text))
            target = sw.cd_target(text)
            if target is not None:
                cwd, old = sw.moved(cwd, old, target)
    return out


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


rng = random.Random(3473)
BITS = ["git push origin main", "echo a", "cd /tmp/a", "cd b", "x=", "(", ")", "$(", "`", "<(", ">(", " ",
        " && ", " || ", "; ", " | ", "\n", '"', "'", "\\", "case x in a)", ";;", "{ ", "}", "#", "$((", "))"]
lost = strangers = more = 0
first_lost = first_stranger = ""
TEXTS = 3000
for _ in range(TEXTS):
    text = "".join(rng.choice(BITS) for _ in range(rng.randint(1, 14)))
    before, after = cut_before(text), sw.crude_commands(text)
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
row("over the same texts, every record's text is written in the text it was cut from",
    "" if not strangers else "%d texts gave a text not written in them, the first: %s" % (strangers, first_stranger))
# Without this the two rows above would pass on a reader that lists nothing new.
row("the made up texts reach the new listing (some text is given more records than before)",
    "" if more >= TEXTS // 10 else "only %d of %d texts were given more records" % (more, TEXTS))


# ---- R1 as a property: the crude reader against the reader itself --------------------------------
# A nest of substitutions and subshells the reader CAN read, built whole so every opener closes.
# Each simple command the reader lists in it (one holding no separator, parenthesis or backquote) the
# crude reader must list too. No quote, comment, heredoc or backgrounding & is made: the crude cut
# reads those differently by design and they are not this property's subject.
SIMPLE = ["git push origin main", "echo a", "ls -la", "git status", "true"]
SEPS = [" && ", " || ", "; ", " | ", "\n"]


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


EDGE = re.compile(r"[()`;|\n]|&&")
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

while IFS=$'\t' read -r verdict what why; do
  case "$verdict" in
    ok) check "$what" ok ;;
    FAIL) check "$what" "$why" ;;
    *) check "a row of the comparison is one this suite reads" "got: $verdict" ;;
  esac
done < "$T/rows.tsv"

# A run that compared nothing must not read as a pass.
[ "$pass" -ge 60 ] || check "the comparison checked its rows" "only $pass checks passed, of the 70 or so the table makes"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]

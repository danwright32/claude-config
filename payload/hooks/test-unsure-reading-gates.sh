#!/usr/bin/env bash
# Tests that four gates judge a Bash command by the reading the shared reader gives a caller that
# asks which lines it is unsure of (claude-config#3472, the second group): check-zsh-builtins.sh,
# check-screenshot-window.sh, temp-worktree-gate.sh, and pr-review-gate.sh's refusal of a command
# that can write the lessons review's read records (lib/review-record-writes.py).
#
# Each read a command through lib/shell-words.py without asking. The reader took a # for a comment
# by a rule the shell does not follow, so a command on the rest of that line was left out of what
# the gate judged: 18 shapes, measured against bash and zsh for claude-config#3464 (they are
# test-shell-words-comment-start.sh's). The reader reads on where every shell does, and names the
# line where it cannot tell, a heredoc it cannot find the end of (#3492, #3566) and an operator a
# backslash and a line break split (#3504), but only for a caller that asks. Reproduced here
# against each unchanged gate: the command the gate exists to refuse, written behind each shape,
# was not refused.
#
# What must hold for each gate:
#   - the command it refuses, behind each of the 18 shapes, is refused: in the gate's own words
#     where every shell reads the # inside a word (the reader reads on), and as a command the gate
#     could not check, in the sentence for the mark, where the reader names the line;
#   - a # between backquotes that close on its line, the commonest named line, is refused in a
#     sentence of its own, and written as that sentence says the command is read and passes;
#   - the same command in plain sight is refused in the words it always was (the control);
#   - a command the gate has nothing against, behind the same shape, passes (the quiet twin),
#     except behind a line the reader names, which the gate cannot check whatever stands there;
#   - a real comment and an ordinary heredoc hide nothing and pass as they did;
#   - what the gate refused by the reading it always made, it still refuses, where the asked
#     reading finds nothing (the # opens a heredoc that holds the command as text);
#   - beside a library folder that lacks lib/unsure-reading.py, lib/db-write-calls.py (where the
#     rule lives), or a reader that can be asked, the gate refuses no less than it did.
#
# Every command here is only ever text in a payload handed to a gate: nothing a case names runs.
# The only programs started are the gates, python3, and git asked by temp-worktree-gate.sh which
# repository a folder that does not exist belongs to. Every path and name is invented.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

GATE_FILES=(check-zsh-builtins.sh zsh_builtin_gate.py check-screenshot-window.sh screenshot_window_gate.py temp-worktree-gate.sh pr-review-gate.sh)
missing=""
for f in "${GATE_FILES[@]}" lib/unsure-reading.py lib/db-write-calls.py lib/shell-words.py lib/temp-worktree.py lib/review-record-writes.py; do
  [ -f "$DIR/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
  echo "FAIL: test-unsure-reading-gates: missing beside this suite:$missing"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/state" "$WORK/phases"

# Three copies of the gates with every library beside them, each then made to lack one thing, so
# the absence is written here where it can be read: the door the gates ask through, the library the
# rule lives in, and a reader that can be asked (its commands() takes no `unsure`: every use of the
# name is renamed, which leaves a reader that reads as it does and cannot be asked).
copy_hooks() {   # copy_hooks <dest>
  mkdir -p "$1/lib"
  local f
  for f in "${GATE_FILES[@]}"; do cp "$DIR/$f" "$1/"; done
  find "$DIR/lib" -mindepth 1 -maxdepth 1 ! -name __pycache__ -exec cp -R {} "$1/lib/" \;
  find "$1/lib" -name __pycache__ -prune -exec rm -rf {} +
}
copy_hooks "$WORK/nohelp" && rm -f "$WORK/nohelp/lib/unsure-reading.py"
copy_hooks "$WORK/norule" && rm -f "$WORK/norule/lib/db-write-calls.py"
copy_hooks "$WORK/oldreader"
renamed="$(python3 -B - "$WORK/oldreader/lib/shell-words.py" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
t, n = re.subn(r"(?<![A-Za-z0-9_])unsure(?![A-Za-z0-9_])", "unsure_not_asked", s)
open(p, "w").write(t)
print(n)
PY
)"
# A rename that matched nothing would leave a reader that CAN be asked, and its cases would prove
# nothing of one that cannot (L100). The count is read by the one test of a number above zero
# (lib/whole-number.sh), into a name of its own so that the failure can still quote what came back.
. "$DIR/lib/whole-number.sh"
if renamed_count="$(whole_above_zero "$renamed")" && [ -n "$renamed_count" ]; then
  check "#3472 the stand in for a reader that cannot be asked was made" ok
else
  check "#3472 the stand in for a reader that cannot be asked was made" "the rename found ${renamed:-nothing} to change"
fi

cat > "$WORK/cases.py" <<'PY'
import importlib.util, json, os, subprocess, sys, types

DIR, WORK = sys.argv[1], sys.argv[2]
NOHELP, NORULE, OLD = (os.path.join(WORK, n) for n in ("nohelp", "norule", "oldreader"))
ENV = dict(os.environ, HOME=os.path.join(WORK, "home"), SHELL="/bin/zsh",
           AI_REVIEW_STATE_DIR=os.path.join(WORK, "state"), MWR_PHASE_DIR=os.path.join(WORK, "phases"))
for name in ("CLAUDE_HOME", "ALLOW_TEMP_WORKTREE", "SKIP_PR_REVIEW", "PYTHONDONTWRITEBYTECODE"):
    ENV.pop(name, None)
# A repository path that is under no temp folder. Nothing is made there: the gate only reads it.
REPO = "/opt/work/apps/proj"


class Gate:
    def __init__(self, key, name, wrapper, hidden, own, quiet, cwd, unchecked):
        self.key, self.name, self.wrapper, self.hidden, self.own = key, name, wrapper, hidden, own
        self.quiet, self.cwd, self.unchecked = quiet, cwd, unchecked


# For each gate: a command it refuses (hidden), the words of that refusal when the command is read
# (own), a command it reaches its judge on and has nothing against (quiet), and the words of its
# refusal of a command it could not check (unchecked).
GATES = (
    Gate("zsh", "check-zsh-builtins.sh", "check-zsh-builtins.sh", "log show --last 1m",
         ("BLOCKED: this command runs log with an argument", "/usr/bin/log show"),
         "git log --oneline -3", WORK,
         ("BLOCKED: whether this command runs zsh's log builtin", "could not be checked")),
    Gate("shot", "check-screenshot-window.sh", "check-screenshot-window.sh", "screencapture -x shot.png",
         ("BLOCKED: this command runs screencapture with no -l naming one window",),
         "screencapture -l 4242 shot.png", WORK,
         ("BLOCKED: whether this command runs screencapture on more than one window", "could not be checked")),
    Gate("tree", "temp-worktree-gate.sh", "temp-worktree-gate.sh", "git worktree add /tmp/wt-3472 -b fix/x",
         ("REFUSED (temp-worktree-gate.sh):", "puts the worktree at /tmp/wt-3472, under a temp folder"),
         "git worktree list", REPO,
         ("REFUSED (temp-worktree-gate.sh): this call places a git worktree, and", "where it goes could not be read")),
    Gate("records", "pr-review-gate.sh (the review's read records)", "pr-review-gate.sh", "ar_readkeys_issue 12 x.txt",
         ("Refused: this command runs ar_readkeys_issue, one of the functions that write or reach those records",
          "only the lessons review's own gates write"),
         "grep -n ar_readkeys_issue notes.txt", WORK,
         ("Refused: this command names those records, and whether it writes them could not be told",
          "only the lessons review's own gates write")),
)
# The review's records check refuses any command naming a record beside a process substitution, and
# a name inside a $( ) word, by the reading it always made. Those shapes are refused before and
# after, in these words, whatever stands behind them.
PROCESS = ("Refused: this command names those records beside a process substitution",)
INSIDE = ("Refused: this command holds a name of those records inside something that runs it",)
UNSPLIT = ("Refused: this command holds a name of those records in text that cannot be read",)
# Two more shapes a gate refuses by the reading it always made, in its own words, whatever stands
# behind them (each seen against the unchanged gate): a heredoc fed to sh, and for the records
# check a name in a heredoc the shell expands.
ALREADY = {
    ("tree", "split"): ("REFUSED (temp-worktree-gate.sh): this call places a git worktree, and it hands a string to a shell that cannot be read",),
    ("records", "split"): ("Refused: this command names those records beside sh, which runs commands no gate can read",),
    ("records", "one line"): ("Refused: this command names those records in a heredoc the shell expands",),
}

# The 18 shapes that hide a command from a caller that does not ask (claude-config#3464): the text
# up to the #, and what follows it up to the hidden command. In the first 17 every shell reads the
# # inside a word and runs the rest of the line. In the last, bash does and zsh does not, so the
# reader names the line.
READ_ON = (
    ("an escaped space", "echo a\\ ", "# c; "),
    ("three backslashes and a space", "echo a\\\\\\ ", "# c; "),
    ("an escaped tab", "echo a\\\t", "# c; "),
    ("an escaped ;", "echo a\\;", "# c; "),
    ("an escaped &", "echo a\\&", "# c; "),
    ("an escaped |", "echo a\\|", "# c; "),
    ("an escaped (", "echo a\\(", "# c; "),
    ("an escaped )", "echo a\\)", "# c; "),
    ("a $( ) right before it", "echo $(echo b)", "# c; "),
    ("a <( ) right before it", "cat <(echo b)", "# c; "),
    ("a $(( )) right before it", "echo $((1))", "# c; "),
    ("a line joined mid word", "echo a\\\n", "# c; "),
    ("a line joined after an escaped space", "echo a\\ \\\n", "# c; "),
    ("two lines joined mid word", "echo a\\\n\\\n", "# c; "),
    ("a line joined after an escaped ;", "echo a\\;\\\n", "# c; "),
    ("a line joined after a $( )", "echo $(echo b)\\\n", "# c; "),
    ("an escaped space, the rest of the line holding a whole string", "echo a\\ ", "# 'x'; "),
)
NAMED = (("an array right before it", "x=(a b)", "# c; "),)
# What each mark's refusal says that no other mark's does, and how it says to write the command.
SAYS = {
    "comment": "holds a # the shared reader cannot tell from a comment",
    "close": "opens a heredoc the shared reader cannot find the end of",
    "joined": "on a line that ends in a backslash before the heredoc's end marker is whole",
    "split": "whose end marker is quoted and holds a line break",
    "dollar": "whose end marker holds a dollar quote",
    "one line": "opens a heredoc in a text with no line break",
    "split operator": "holds an operator that a backslash and a line break split",
    "backquotes": "holds a # with a backquote before it and another after it on its line",
}
HOW = {
    "backquotes": "write a backslash before each of them or put the text in single quotes",
    "comment": "Write that # inside quotes, or put the comment on a line of its own",
    "close": "End the heredoc with its marker alone on a line that follows no backslash",
    "joined": "Write the << and its whole end marker on one line",
    "split": "Write the end marker as one word on the line that opens the heredoc",
    "dollar": "Write the end marker as a plain word",
    "one line": "Put the heredoc's body and its end marker on lines of their own",
    "split operator": "Write the operator's two characters together on one line",
}
ISSUE = "claude-config#3472"
# What the refusal for a # between backquotes said before it had a sentence of its own, neither of
# them true of that # (it stands after a space, and is already inside double quotes).
UNTRUE_OF_BACKQUOTES = ("a backslash or a closing parenthesis stands right before it", "Write that # inside quotes")


def behind(hidden):
    """(the mark, the shape, a command, whether the hidden command stands in a $( ) word) for every
    heredoc the reader names: in each, some shell runs hidden, and the reader's own reading shows
    no such command (the shapes are test-db-write-ask-unsure-line.sh's)."""
    quoted = "echo '$(" + hidden + ")'"
    return (
        ("close", "a heredoc whose marker stands right after a body line that ends in a backslash",
         "cat <<E\nx\\\nE\n" + quoted + "\nE\n", True),
        ("close", "a heredoc that no line ends, with a $( ) after it", "cat <<E\nx\n" + quoted + "\n", True),
        ("joined", "a heredoc whose opener line ends in a backslash", "cat <<E\\\nOF\nx\nE\n" + quoted + "\nEOF\n", True),
        ("split", "a heredoc whose quoted marker holds a line break", "sh <<'E\nF'\n: '\nE\nF\n' ; " + hidden + "\n: '\n", False),
        ("dollar", "a heredoc whose marker holds a dollar quote", "cat <<$'E'\nx\n$E\n" + hidden + "\nE\n", False),
        ("one line", "a heredoc typed on one line", "cat <<E; " + hidden + "; E", False),
    )


def fire(gate, command, hooks=DIR):
    d = {"session_id": "s1", "hook_event_name": "PreToolUse", "cwd": gate.cwd, "tool_name": "Bash",
         "tool_input": {"command": command, "description": "d"}}
    p = subprocess.run(["bash", os.path.join(hooks, gate.wrapper)], input=json.dumps(d).encode(),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV, cwd=WORK, timeout=300)
    return p.returncode, " ".join((p.stderr.decode("utf-8", "replace") + p.stdout.decode("utf-8", "replace")).split())


rows = []


def refused(gate, label, command, words, without=(), hooks=DIR):
    rc, out = fire(gate, command, hooks)
    ok = rc == 2 and all(w in out for w in words) and not any(w in out for w in without)
    rows.append(("ok" if ok else "wanted a refusal holding %r and not %r, got exit %d: %s" % (words, without, rc, out[:500]),
                 "%s: %s" % (gate.name, label)))


def allowed(gate, label, command, hooks=DIR):
    rc, out = fire(gate, command, hooks)
    rows.append(("ok" if rc == 0 and not out else "wanted it passed with nothing said, got exit %d: %s" % (rc, out[:500]),
                 "%s: %s" % (gate.name, label)))


def unchecked(gate, mark):
    return gate.unchecked + (SAYS[mark], HOW[mark], ISSUE)


for g in GATES:
    # ---- 1. the command the gate refuses, behind each of the 18 shapes ----------------------------
    for shape, before, after in READ_ON:
        own = PROCESS if g.key == "records" and "<(" in before else g.own
        refused(g, "its command on the line of a # after %s is refused, in the gate's own words" % shape,
                before + after + g.hidden + "\necho done\n", own, (ISSUE,))
        # The control: the same command in plain sight, on a line of its own.
        refused(g, "(control) its command in plain sight after %s is refused in the words it always was" % shape,
                before + "\n" + g.hidden + "\necho done\n", own, (ISSUE,))
        # The quiet twin: a command the gate has nothing against, behind the same shape.
        if g.key == "records" and "<(" in before:
            refused(g, "(as before) a command it has nothing against behind a # after %s is refused for the process substitution" % shape,
                    before + after + g.quiet + "\necho done\n", PROCESS, (ISSUE,))
        else:
            allowed(g, "(quiet twin) a command it has nothing against on the line of a # after %s passes" % shape,
                    before + after + g.quiet + "\necho done\n")
    for shape, before, after in NAMED:
        refused(g, "its command on the line of a # after %s is refused as a command it could not check" % shape,
                before + after + g.hidden + "\necho done\n", unchecked(g, "comment"))
        refused(g, "(control) its command in plain sight after %s is refused in the words it always was" % shape,
                before + "\n" + g.hidden + "\necho done\n", g.own, (ISSUE,))
        if g.key == "tree":
            # It refuses an unread command only when it names a worktree being placed.
            allowed(g, "(quiet twin) a command that places no worktree on the line of a # after %s passes" % shape,
                    before + after + g.quiet + "\necho done\n")
        else:
            refused(g, "(the cost) a command it has nothing against on the line of a # after %s is refused, since the line could not be read" % shape,
                    before + after + g.quiet + "\necho done\n", unchecked(g, "comment"))

    # ---- 2. every heredoc the reader names --------------------------------------------------------
    for mark, shape, command, in_word in behind(g.hidden):
        if g.key == "records" and in_word:
            refused(g, "(as before) its command behind %s is refused for the name inside a $( ) word" % shape, command, INSIDE)
        elif (g.key, mark) in ALREADY:
            refused(g, "(as before) its command behind %s is refused in the words it always was" % shape, command, ALREADY[(g.key, mark)])
        else:
            refused(g, "its command behind %s is refused as a command it could not check, in the words for that mark" % shape,
                    command, unchecked(g, mark), tuple(SAYS[m] for m in SAYS if m != mark))
    for mark, shape, command, in_word in behind(g.quiet):
        if mark not in ("close", "one line") or shape.endswith("after it"):
            continue
        if g.key == "tree":
            allowed(g, "(quiet twin) a command that places no worktree behind %s passes" % shape, command)
        elif g.key == "records" and in_word:
            refused(g, "(as before) a command it has nothing against behind %s is refused for the name inside a $( ) word" % shape,
                    command, INSIDE)
        elif (g.key, mark) in ALREADY:
            refused(g, "(as before) a command it has nothing against behind %s is refused in the words it always was" % shape,
                    command, ALREADY[(g.key, mark)])
        else:
            refused(g, "(the cost) a command it has nothing against behind %s is refused, since the heredoc could not be read" % shape,
                    command, unchecked(g, mark))

    # ---- 2b. a # between backquotes ---------------------------------------------------------------
    # The commonest way to meet a named line: backquotes written as text in a double quoted message,
    # with a # after a space between them. The reader reads a comment from the # to the end of the
    # line, bash ends the backquotes at the next backquote, and the reader names the line. The
    # refusal said a backslash or a closing parenthesis stood before the #, and to write the # inside
    # quotes: neither was true of a # that stands after a space, inside double quotes.
    reach = "git worktree add .claude/worktrees/wt-3472 -b fix/x" if g.key == "tree" else g.quiet
    others = tuple(SAYS[m] for m in SAYS if m != "backquotes") + UNTRUE_OF_BACKQUOTES
    # The reading the gate always made reaches the end of this text (line 2 closes what line 1 left
    # open), so the command after it is judged, and passes, by that reading.
    ticks = 'echo "run `date # now` here"\n: `"\n' + reach + "\n"
    if g.key == "records":
        # The records check refuses this text by the reading it always made (it cannot split the two
        # lines into words), so its words for this mark are not seen through this gate.
        refused(g, "(as before) a command it has nothing against after a line holding a # between backquotes is refused in the words it always was",
                ticks, UNSPLIT, (ISSUE,))
    else:
        refused(g, "(the cost) a command it has nothing against after a line holding a # between backquotes is refused, in the words for that mark",
                ticks, unchecked(g, "backquotes"), others)
    # Written as the refusal says, the same text is read and the command passes.
    allowed(g, "(the advice) with a backslash before each backquote, the same command passes",
            'echo "run \\`date # now\\` here"\n' + reach + "\n")
    allowed(g, "(the advice) with the text in single quotes, the same command passes",
            "echo 'run `date # now` here'\n" + reach + "\n")
    allowed(g, "(the advice) with the comment on a line of its own between backquotes that run a command, the same command passes",
            "x=`date\n# now\n`\n" + reach + "\n")
    if g.key in ("zsh", "shot"):
        # On one line the reading gives up, and the gate's crude reading has nothing against the text.
        said = "git log # all" if g.key == "zsh" else "./setup.sh # once"
        refused(g, "(the cost) a message that quotes a line with a # between backquotes is refused, in the words for that mark",
                'gh pr comment 5 --body "run `' + said + '` here"', unchecked(g, "backquotes"), others)
        allowed(g, "(the advice) the same message with a backslash before each backquote passes",
                'gh pr comment 5 --body "run \\`' + said + '\\` here"')
        allowed(g, "(the advice) the same message in single quotes passes",
                "gh pr comment 5 --body 'run `" + said + "` here'")

    # ---- 3. what hides nothing passes as it did ---------------------------------------------------
    allowed(g, "(control) its command in a real comment passes", "echo a # c; " + g.hidden + "\necho done\n")
    allowed(g, "(control) its command as the text of a quoted heredoc fed to cat passes", "cat <<'E'\n" + g.hidden + "\nE\necho done\n")
    allowed(g, "(control) a command it has nothing against passes", g.quiet + "\n")
    allowed(g, "(control) a command it has nothing against after an ordinary heredoc and a comment passes",
            "cat <<E\nplain words\nE\n" + g.quiet + " # a note\n")

    # ---- 4. what the reading it always made refuses, it still refuses -----------------------------
    # Every shell reads this # inside its word, so the << after it opens a heredoc and the command
    # is its text: the asked reading finds no command. The reading the gate always made takes the #
    # for a comment and finds one. Refusing by either keeps the gate from refusing less than it did:
    # three of the four would pass this command by the asked reading alone, and the records check
    # would refuse it in other words (a name in a heredoc the shell expands), which this case
    # rejects as well, since it asks for the words the gate always used.
    refused(g, "(control) its command on the line after a # that the shells read as text opening a heredoc is still refused",
            "echo a\\ # <<E\n" + g.hidden + "\nE\n", g.own, (ISSUE,))

    # ---- 5. beside a library folder that lacks a part ---------------------------------------------
    HID = "echo a\\ # c; " + g.hidden + "\necho done\n"
    for hooks, what, names in ((NOHELP, "with no lib/unsure-reading.py", "unsure-reading.py"),
                               (NORULE, "with no lib/db-write-calls.py", "db-write-calls.py"),
                               (OLD, "beside a reader that cannot be asked", "cannot say which lines it is unsure of")):
        refused(g, "%s, its command in plain sight is refused in the words it always was" % what,
                "echo a\n" + g.hidden + "\n", g.own, (ISSUE,), hooks)
        degraded = {"zsh": ("BLOCKED: this command seems to run log with an argument, and it could not be read word by word", names),
                    "shot": ("BLOCKED: this command seems to run screencapture, and it could not be read word by word", names),
                    "tree": ("REFUSED (temp-worktree-gate.sh): this call places a git worktree, and", names),
                    "records": ("Refused: this command names those records", names, "only the lessons review's own gates write")}[g.key]
        refused(g, "%s, its command on the line of a # after an escaped space is refused, never passed" % what, HID, degraded, (), hooks)

# ---- 6. an operator that a backslash and a line break split -----------------------------------------


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    lib = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lib)
    return lib


sys.dont_write_bytecode = True
door = load("door", os.path.join(DIR, "lib", "unsure-reading.py"))
sw = load("sw", os.path.join(DIR, "lib", "shell-words.py"))
facts = []


def fact(label, ok, got=""):
    facts.append(("ok" if ok else "got %s" % (str(got)[:400],), label))


# A stand in reader that names one mark, as the reader does once it names split operators (pull
# request 3797): the door's own part is only which words are said of that mark.
def stand_in(split):
    reader = types.ModuleType("stand_in_reader")

    def commands(s, cwd="", unsure=None):
        if unsure is not None and "$\\\n(" in s:
            unsure.append((s.index("$\\\n("), s.index("$\\\n(") + 4))
        return [("", s)]

    reader.commands = commands
    reader.every_command = lambda s, cwd="": [(d, t, "", "", 0) for d, t in reader.commands(s, cwd)]
    if split:
        reader.split_operator = lambda s, at: "$(" if s.startswith("$\\\n(", at) else ""
    return reader


TEXT = "echo one\necho $\\\n(printf x)\n"
for split in (True, False):
    reader = stand_in(split)
    plain = reader.commands
    got, fault = door.asked(reader, lambda: reader.every_command(TEXT))
    kind = getattr(fault, "kind", None)
    if split:
        fact("the door says of a mark the reader's split_operator() owns that an operator was split, naming it and its line",
             got is None and kind == "split operator" and SAYS["split operator"] in str(fault) and "`$(`" in str(fault)
             and "`echo $\\`" in str(fault) and HOW["split operator"] in door.told(fault) and ISSUE in door.told(fault),
             (got, kind, fault))
    else:
        fact("(control) beside a reader with no split_operator() the door says only that the line is one the reader is unsure of",
             got is None and kind == "line" and SAYS["split operator"] not in str(fault), (got, kind, fault))
    fact("the stand in reader reads as it did after the door asked (split_operator %s)" % ("there" if split else "absent"),
         reader.commands is plain, reader.commands)
    got, fault = door.asked(reader, lambda: reader.every_command("echo one\n"))
    fact("(control) a command with no mark is the reading itself and no fault (split_operator %s)" % ("there" if split else "absent"),
         fault is None and got == [("", "echo one\n", "", "", 0)], (got, fault))

# The real reader: what the door hands back is the database write check's own answer.
reads_as = sw.commands
got, fault = door.asked(sw, lambda: sw.every_command("echo a\necho b\n"))
fact("(control) a plain command read through the door is the reader's own reading and no fault",
     fault is None and got == sw.every_command("echo a\necho b\n"), (got, fault))
got, fault = door.asked(sw, lambda: sw.every_command("x=(a b)# c; printf done\n"))
fact("a # the reader cannot tell from a comment comes back from the door as that fault, with how to write it",
     got is None and getattr(fault, "kind", None) == "comment" and SAYS["comment"] in str(fault)
     and HOW["comment"] in door.told(fault), (got, fault))
got, fault = door.asked(sw, lambda: sw.every_command("echo a\\ # c; printf done\n"))
fact("a # every shell reads inside a word comes back as the reading that reads on, and no fault",
     fault is None and any(r[1].strip() == "printf done" for r in got or ()), (got, fault))
MESSAGE = 'gh pr comment 5 --body "run `git log # all` here"'
got, fault = door.asked(sw, lambda: sw.every_command(MESSAGE))
fact("a # between backquotes comes back from the door as that fault, naming its line, with how to write it and none of the words untrue of it",
     got is None and getattr(fault, "kind", None) == "backquotes" and SAYS["backquotes"] in str(fault)
     and "`" + MESSAGE + "`" in str(fault) and HOW["backquotes"] in door.told(fault) and ISSUE in door.told(fault)
     and not any(w in door.told(fault) for w in UNTRUE_OF_BACKQUOTES), (got, getattr(fault, "kind", None), fault))
# The same sentence is not given to a # the reader names for another reason, backquotes on its line
# or not: after a ) the reader cannot place, and after a backslash where the reading then gives up.
got, fault = door.asked(sw, lambda: sw.every_command("echo `date`; x=(a b)# see `date`\nprintf done\n"))
fact("(control) a # right after an array's ) keeps the words for a # the reader cannot tell from a comment, backquotes on its line or not",
     got is None and getattr(fault, "kind", None) == "comment" and SAYS["backquotes"] not in str(fault), (got, fault))
got, fault = door.asked(sw, lambda: sw.every_command('echo `date` a\\ # `x "y\n'))
fact("(control) a # after an escaped space, past which the text cannot be read, keeps its own words, backquotes on its line or not",
     got is None and getattr(fault, "kind", None) == "unread" and SAYS["backquotes"] not in str(fault)
     and UNTRUE_OF_BACKQUOTES[0] in str(fault), (got, fault))
got, fault = door.asked(sw, lambda: sw.every_command("echo `echo a # c\n`\nprintf done\n"))
fact("(control) a comment between backquotes that close on a later line is read, and no fault",
     fault is None and any(r[1].strip() == "printf done" for r in got or ()), (got, fault))
fact("the reader reads as it did after the door asked", sw.commands is reads_as, sw.commands)


# A reader that names split operators and cannot be asked. The rule library checks that a reader
# can be asked before it reads through it; the door's own wrapper took `unsure`, so beside such a
# reader that check passed and the reader then failed with a TypeError where the answer is that it
# cannot be asked.
def not_asked():
    reader = types.ModuleType("stand_in_reader_not_asked")

    def commands(s, cwd=""):
        return [("", s)]

    reader.commands = commands
    reader.every_command = lambda s, cwd="": [(d, t, "", "", 0) for d, t in reader.commands(s, cwd)]
    reader.split_operator = lambda s, at: ""
    return reader


reader = not_asked()
plain = reader.commands
label = "beside a reader that has split_operator() and cannot be asked, the door answers that it cannot be asked, and hands back no reading"
try:
    got, fault = door.asked(reader, lambda: reader.every_command(TEXT))
    fact(label, got is None and fault is not None and getattr(fault, "kind", None) is None
         and "cannot say which lines it is unsure of" in str(fault), (got, fault))
except Exception as e:
    fact(label, False, repr(e))
fact("that reader reads as it did after the door asked", reader.commands is plain, reader.commands)
try:
    lone = load("lone_door", os.path.join(NORULE, "lib", "unsure-reading.py"))
    lone_sw = load("lone_sw", os.path.join(NORULE, "lib", "shell-words.py"))
    try:
        lone.asked(lone_sw, lambda: 1)
        fact("with no lib/db-write-calls.py the door raises CannotLoad, naming the file", False, "it answered")
    except lone.CannotLoad as e:
        fact("with no lib/db-write-calls.py the door raises CannotLoad, naming the file", "db-write-calls.py" in str(e), e)
except Exception as e:
    fact("with no lib/db-write-calls.py the door raises CannotLoad, naming the file", False, repr(e))

for verdict, label in rows + facts:
    print("%s\t%s" % (verdict, label))
print("ran\t%d" % (len(rows) + len(facts)))

# Through the gates, with the reader beside this suite, which names such an operator.
if callable(getattr(sw, "split_operator", None)):
    extra = len(rows)
    for g in GATES:
        own = INSIDE if g.key == "records" else None
        command = "echo $\\\n(" + g.hidden + ")\necho done\n"
        if own:
            refused(g, "(as before) its command in a $( ) that a backslash and a line break split is refused for the name inside it", command, own)
        else:
            refused(g, "its command in a $( ) that a backslash and a line break split is refused as a command it could not check",
                    command, unchecked(g, "split operator"), (SAYS["comment"],))
    for verdict, label in rows[extra:]:
        print("%s\t%s" % (verdict, label))
    print("split\t%d" % (len(rows) - extra))
else:
    print("split\tunmeasured")
PY
rows="$(python3 -B "$WORK/cases.py" "$DIR" "$WORK" 2>&1)"
ran=""
split=""
while IFS=$'\t' read -r verdict label; do
  if [ "$verdict" = "ran" ]; then ran="$label"; continue; fi
  if [ "$verdict" = "split" ]; then split="$label"; continue; fi
  if [ -n "$label" ]; then check "#3472 $label" "$verdict"; elif [ -n "$verdict" ]; then check "#3472 the cases program said something that is not a case" "${verdict:0:300}"; fi
done <<< "$rows"
# A program that stopped early checks nothing and would read as a pass (L288).
WANT_RAN=331
[ "$ran" = "$WANT_RAN" ] && check "#3472 all $WANT_RAN cases ran" ok || check "#3472 all $WANT_RAN cases ran" "ran: ${ran:-none}; ${rows: -300}"
# The reader names an operator that a backslash and a line break split since claude-config#3504.
# Beside a reader from before it no gate can be handed one, and that is said, never counted as a
# pass (L411).
case "$split" in
  4) check "#3472 the four split operator cases ran through the gates" ok ;;
  unmeasured) echo "SUITE-PART-UNMEASURED whether each gate refuses a command behind an operator that a backslash and a line break split, because lib/shell-words.py beside this suite has no split_operator() (it arrives with claude-config#3504)" ;;
  *) check "#3472 the four split operator cases ran through the gates" "ran: ${split:-none}" ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

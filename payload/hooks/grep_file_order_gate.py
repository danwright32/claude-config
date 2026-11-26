"""The judge for check-grep-file-order.sh (claude-config#3546): does a Bash command run grep, as the
Bash tool's own shell runs it, with -h over more than one file?

In a Claude Code Bash call grep is not /usr/bin/grep: it is a shell function from Claude Code's shell
snapshot that runs its built in ugrep, and ugrep searches several files at once, so their matches
come out in whichever order the files finish. With -h no file name is printed, so a reader mapping
the lines back to the files by position gets the wrong mapping with no error.

Measured 2026-11-26 on the personal MacBook, in the Bash tool: `grep -h result big small1 small2` was
out of argument order in 10 of 10 runs, and three one line files in 3 of 5. `command grep` kept the
order in 5 of 5, and so did `-J1` and `--jobs=1` (one job) in 5 of 5 each. The function also runs
behind an assignment, noglob, nocorrect and exec, quoted or backslashed, in a subshell, a substitution
and eval. A child shell (bash -c, zsh -c, a script) has no such function, and command, env, a full
path, xargs, timeout and find -exec all run the real binary.

Reads the hook payload on stdin. Exits 0 to pass, 3 to refuse, and 4 when the command could not be
read word by word (printing why), for the wrapper's crude reading to decide.
"""
import importlib.util
import json
import os
import re
import sys

# Loading lib/shell-words.py must leave no bytecode beside it in lib/ (claude-config#2080).
sys.dont_write_bytecode = True
HOOKS = os.path.dirname(os.path.abspath(__file__))

# Precommand words the Bash tool's shell still resolves grep through as its function (measured for
# noglob, nocorrect and exec; time and - are zsh's own and run the next word the same way).
STILL_FUNCTION = {"noglob", "nocorrect", "exec", "time", "-"}
# ugrep's short options that take a value, glued (-m1) or as the next word (-m 1). Every other letter
# in a cluster is a flag on its own.
SHORT_VALUED = set("efABCmdDJKNMOtg")
# Long options that take a value as the next word when written without "=".
LONG_VALUED = {"regexp", "file", "after-context", "before-context", "context", "max-count",
               "directories", "devices", "jobs", "range", "neg-regexp", "file-magic", "file-extension",
               "file-type", "glob", "include", "exclude", "include-dir", "exclude-dir", "label",
               "encoding", "color", "colour"}
# Options that name the pattern, so every positional word after them is a file.
PATTERN_SHORT = set("ef")
PATTERN_LONG = {"regexp", "file"}
# A word the shell may expand into several files: a glob or a brace list.
SEVERAL = re.compile(r"[*?[]|\{[^}]*,[^}]*\}")


def say(text, code):
    sys.stdout.buffer.write(text.encode("utf-8", "replace"))
    sys.exit(code)


try:
    _spec = importlib.util.spec_from_file_location("shell_words", os.path.join(HOOKS, "lib", "shell-words.py"))
    sw = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(sw)
except Exception:
    say(os.path.join(HOOKS, "lib", "shell-words.py") + ", the reader of the command, could not be loaded"
        " (reinstall the hooks with claude-sync pull)", 4)


def _past_redirections(words):
    """words without its redirections: a bare operator (`>`) takes the word after it as its target."""
    kept, k = [], 0
    while k < len(words):
        m = sw.REDIRECT_WORD.match(words[k])
        if m:
            k += 1 if m.group(1) else 2
            continue
        kept.append(words[k])
        k += 1
    return kept


def grep_args(words):
    """The arguments of grep when a command's words run the Bash tool's grep function, else None.
    Assignments, redirections and the precommand words that still reach the function are passed
    over; any other first word (a path, command, env, xargs, timeout) means the real binary runs."""
    words = _past_redirections(words)
    i = 0
    while i < len(words) and (sw.ASSIGNMENT.match(words[i]) or words[i] in STILL_FUNCTION):
        i += 1
    if i >= len(words) or words[i] != "grep":
        return None
    return words[i + 1:]


def unordered(words):
    """True when grep, as the Bash tool's shell runs it, drops file names (-h, last of -h and -H
    winning) over more than one file (two named, or one word the shell may expand into several),
    unless ugrep is held to one job."""
    args = grep_args(words)
    if args is None:
        return False
    no_names = False
    one_job = False
    pattern_named = False
    positional = []
    k = 0
    while k < len(args):
        w = args[k]
        k += 1
        if w == "--":
            positional.extend(args[k:])
            break
        if w.startswith("--") and len(w) > 2:
            name, eq, value = w[2:].partition("=")
            if name in LONG_VALUED and not eq:
                value = args[k] if k < len(args) else ""
                k += 1
            if name == "no-filename":
                no_names = True
            elif name == "with-filename":
                no_names = False
            elif name == "jobs":
                one_job = value == "1"
            if name in PATTERN_LONG:
                pattern_named = True
            continue
        if w.startswith("-") and len(w) > 1:
            j = 1
            while j < len(w):
                c = w[j]
                j += 1
                if c in SHORT_VALUED:
                    value = w[j:]
                    if not value:
                        value = args[k] if k < len(args) else ""
                        k += 1
                    if c == "J":
                        one_job = value == "1"
                    if c in PATTERN_SHORT:
                        pattern_named = True
                    break
                if c == "h":
                    no_names = True
                elif c == "H":
                    no_names = False
            continue
        positional.append(w)
    if not no_names or one_job:
        return False
    files = positional if pattern_named else positional[1:]
    return len(files) > 1 or any(SEVERAL.search(f) for f in files)


def main():
    raw = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    try:
        data = json.loads(raw)
    except ValueError:
        say("it could not read the hook payload (it is not JSON)", 4)
    # The one rule for a gate with its own reader (lib/push-scope.sh ps_payload_unread,
    # claude-config#2057): not an object, a tool input that is not an object, or a command that is not
    # text cannot be read as a call, so the wrapper's crude reading of every word in it decides.
    unread = "it could not read the hook payload as a call (JSON without the command as text where it belongs)"
    if not isinstance(data, dict):
        say(unread, 4)
    if data.get("tool_name") != "Bash":
        sys.exit(0)
    ti = data.get("tool_input")
    if ti is not None and not isinstance(ti, dict):
        say(unread, 4)
    command = (ti or {}).get("command")
    if command is not None and not isinstance(command, str):
        say(unread, 4)
    if not command:
        sys.exit(0)
    try:
        records = sw.every_command(command)
    except Exception:
        say(os.path.join(HOOKS, "lib", "shell-words.py") + " could not read the command", 4)
    # own[d] says whether the commands d wrappers deep run in the Bash tool's own shell, the one that
    # holds the function. eval runs its string there; every other wrapper (bash -c, zsh -c, find
    # -exec, a script) starts a process with no such function.
    own = [True]
    for _, text, wrapper, _, depth in records:
        del own[depth + 1:]
        here = own[depth] if depth < len(own) else False
        if here and unordered(sw.command_words(text)):
            sys.exit(3)
        if wrapper:
            own.append(here and wrapper == "eval")
    sys.exit(0)


if __name__ == "__main__":
    main()

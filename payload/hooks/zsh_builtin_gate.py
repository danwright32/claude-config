"""The judge for check-zsh-builtins.sh (claude-config#2200): does a Bash command run one of zsh's
builtins that shadows a macOS program, with an argument, in a shell that is zsh?

It also refuses, in zsh, a command assigning a lowercase name zsh ties to an uppercase twin, path to
PATH above all, which replaces the command search path (claude-config#2347).

Reads the hook payload on stdin. Exits 0 to pass, 3 to refuse log (printing the fix, the full path
and the first argument), 5 to refuse a tied name being assigned (printing the name and its twin), and
4 when the command could not be read word by word (printing why), for the wrapper's crude reading to
decide.

Measured with zsh 5.9 on 2026-11-04: the builtin still runs behind builtin, noglob, nocorrect, -,
exec and time, and when the name is quoted or backslashed; the program runs behind command and env.
"""
import importlib.util
import json
import os
import re
import sys

# Loading lib/shell-words.py must leave no bytecode beside it in lib/ (claude-config#2080).
sys.dont_write_bytecode = True
HOOKS = os.path.dirname(os.path.abspath(__file__))

# zsh builtins that shadow a program a command means to run, and that program's full path.
SHADOWED = {"log": "/usr/bin/log"}
# Precommand modifiers zsh still resolves the next word through as a builtin (measured).
STILL_BUILTIN = {"builtin", "noglob", "nocorrect", "-", "exec", "time"}

# Lowercase arrays zsh ties to an uppercase twin (claude-config#2347): assigning path replaces PATH,
# so every later command in the call fails with "command not found". bash ties none of them.
TIED = {"path": "PATH", "cdpath": "CDPATH", "fpath": "FPATH", "manpath": "MANPATH",
        "module_path": "MODULE_PATH"}
# A word assigning a variable: name=, name+=, name[i]= or name[i]+=.
NAME_SET = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)(?:\[[^]]*\])?\+?=")
# Builtins whose arguments name variables they declare or set, with or without a value.
DECLARERS = {"local", "export", "typeset", "declare", "readonly", "integer", "float", "private"}
# Builtins that store what they read into the variables their arguments name.
READERS = {"read", "vared", "getopts"}
# Loops that set the names between the keyword and `in` (or the short form's opening parenthesis).
LOOPS = {"for", "foreach", "select"}
# A function header in front of the first command of its body: `f() {`, `f () {`, `function f {`.
FUNCTION_HEAD = re.compile(r"[^\s()]+\(\)\Z")


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


def shadowed(words):
    """(name, args) when a command's words, as zsh reads them, run a shadowing builtin with at least
    one argument, else None. Assignments, redirections and the modifiers that still resolve to the
    builtin are passed over; any other first word (a path, command, env, sudo, nohup, xargs) means
    the name is not the command, or the program runs."""
    words = _past_redirections(words)
    i = 0
    while i < len(words) and (sw.ASSIGNMENT.match(words[i]) or words[i] in STILL_BUILTIN):
        i += 1
    if i >= len(words) or words[i] not in SHADOWED:
        return None
    args = words[i + 1:]
    return (words[i], args) if args else None


def _past_function_head(words):
    """words without a function header in front of its body's first command: the reader gives
    `f() { local path=/x` as one command, whose own words start after the brace."""
    if words[:1] == ["function"] and len(words) > 1:
        i = 3 if words[2:3] == ["()"] else 2
    elif words and FUNCTION_HEAD.match(words[0]):
        i = 1
    elif words[1:2] == ["()"]:
        i = 2
    else:
        return words
    while i < len(words) and words[i] in sw.RESERVED:
        i += 1
    return words[i:]


def tied_assignment(words):
    """The tied name a command's words, as zsh reads them, assign (claude-config#2347), else None:
    an assignment in front of the command or standing alone, a loop's names, the names a declaring
    builtin declares, the variables read, vared, getopts and print -v store into, and unset. Reading
    $path, path as an argument, and env path=x (the child's environment, not the shell's) are not
    assignments."""
    words = _past_redirections(_past_function_head(words))
    i = 0
    while i < len(words):
        m = NAME_SET.match(words[i])
        if m and m.group(1) in TIED:
            return m.group(1)
        if not (m or words[i] in STILL_BUILTIN):
            break
        i += 1
    if i >= len(words):
        return None
    head, args = words[i], words[i + 1:]
    named = []
    if head in LOOPS:
        for w in args:
            if w == "in" or w.startswith("("):
                break
            named.append(w)
    elif head in DECLARERS:
        # -p only prints the names it is given, so with it only a name given a value is assigned.
        printing = any(w[:1] == "-" and "p" in w for w in args)
        named = [w.split("=", 1)[0].split("[", 1)[0].rstrip("+") for w in args
                 if w[:1] not in "-+" and ("=" in w or not printing)]
    elif head in READERS:
        named = [w.split("?", 1)[0] for w in args]
    elif head in ("print", "printf"):
        named = [args[k + 1] for k in range(len(args) - 1) if args[k] == "-v"]
    elif head == "unset" and not any(w.startswith("-") and "f" in w for w in args):
        named = args
    return next((w for w in named if w in TIED), None)


def shell_of(outer, wrapper):
    """The shell a wrapper's inner commands run in, given the shell the wrapper itself runs in."""
    if wrapper == "eval":
        return outer
    head = wrapper.split()[0] if wrapper else ""
    return head if head in sw.SHELLS else None


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
    # shells[d] is the shell running the commands d wrappers deep; the Bash tool's own comes first.
    shells = [os.path.basename(os.environ.get("SHELL", "")) or "zsh"]
    for _, text, wrapper, _, depth in records:
        del shells[depth + 1:]
        here = shells[depth] if depth < len(shells) else None
        if here == "zsh":
            words = sw.command_words(text)
            found = shadowed(words)
            if found:
                name, args = found
                say(" ".join([SHADOWED[name], args[0]]), 3)
            tied = tied_assignment(words)
            if tied:
                say(tied + " " + TIED[tied], 5)
        if wrapper and wrapper not in ("direct", "source"):
            shells.append(shell_of(here, wrapper))
    sys.exit(0)


if __name__ == "__main__":
    main()

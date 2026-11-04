"""The judge for check-zsh-builtins.sh (claude-config#2200): does a Bash command run one of zsh's
builtins that shadows a macOS program, with an argument, in a shell that is zsh?

Reads the hook payload on stdin. Exits 0 to pass, 3 to refuse (printing the fix, the full path and
the first argument), and 4 when the command could not be read word by word (printing why), for the
wrapper's crude reading to decide.

Measured with zsh 5.9 on 2026-11-04: the builtin still runs behind builtin, noglob, nocorrect, -,
exec and time, and when the name is quoted or backslashed; the program runs behind command and env.
"""
import importlib.util
import json
import os
import sys

HOOKS = os.path.dirname(os.path.abspath(__file__))

# zsh builtins that shadow a program a command means to run, and that program's full path.
SHADOWED = {"log": "/usr/bin/log"}
# Precommand modifiers zsh still resolves the next word through as a builtin (measured).
STILL_BUILTIN = {"builtin", "noglob", "nocorrect", "-", "exec", "time"}


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
            found = shadowed(sw.command_words(text))
            if found:
                name, args = found
                say(" ".join([SHADOWED[name], args[0]]), 3)
        if wrapper and wrapper not in ("direct", "source"):
            shells.append(shell_of(here, wrapper))
    sys.exit(0)


if __name__ == "__main__":
    main()

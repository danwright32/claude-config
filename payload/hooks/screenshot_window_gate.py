"""The judge for check-screenshot-window.sh (claude-config#2908): does a Bash command run screencapture
on anything wider than one window named by its id?

Reads the hook payload on stdin. Exits 0 to pass, 3 to refuse (printing what the capture would take),
and 4 when the command could not be read word by word (printing why), for the wrapper's crude reading
to decide.

Every command the line runs is read by lib/shell-words.py, the reading every gate shares: after a cd,
in a chain, a pipe, a subshell or a substitution, behind assignments, redirections and the runners it
passes over (env, sudo, command, exec, nohup, timeout, time, rtk proxy, xargs), inside bash -c, zsh
-c and eval, and in a script file the command runs. The name is compared without its folder and in
any case, since the Mac's file system finds /usr/sbin/screencapture as ScreenCapture too.

The options are read as screencapture's getopt reads them (its manual page, macOS 26): letters may be
clustered, a letter taking a value takes the rest of its word or the next word, and reading stops at
-- or at the first word that is not an option, so a -l after the file name is a file name.
"""
import importlib.util
import json
import os
import sys

# Loading lib/shell-words.py must leave no bytecode beside it in lib/ (claude-config#2080).
sys.dont_write_bytecode = True
HOOKS = os.path.dirname(os.path.abspath(__file__))

NAME = "screencapture"
# The letters that take a value (screencapture's manual page).
VALUED = set("BDGJRTVlt")
# The letters that capture more than the one window -l names, or wait for a person's click, or both,
# so they are refused even beside -l. What each does, in the words of the refusal.
WIDER = {
    "R": "a rectangle of the screen (-R), which holds whatever is on screen there",
    "S": "the screen instead of the window (-S)",
    "D": "a whole display (-D)",
    "p": "whatever the screenshot settings say (-p), which ignores the file and the window",
    "v": "a video of the screen (-v)",
    "V": "a video of the screen (-V)",
    "i": "an interactive selection (-i), which waits for a click from a person who may not be there and can take any part of the screen",
    "s": "an interactive selection (-s), which waits for a click from a person who may not be there and can take any part of the screen",
    "w": "an interactive window selection (-w), which waits for a click from a person who may not be there and takes whichever window is clicked",
    "W": "an interactive selection (-W), which waits for a click from a person who may not be there and can take any part of the screen",
    "J": "an interactive selection (-J), which waits for a click from a person who may not be there and can take any part of the screen",
    "U": "an interactive selection (-U), which waits for a click from a person who may not be there and can take any part of the screen",
    "u": "the screenshot window (-u), which ignores the file and waits for a person",
}


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


def options(args):
    """The (letter, value) pairs screencapture reads from its arguments, value None when a letter that
    takes one has none. A redirection is the shell's and is passed over with its target."""
    out, k = [], 0
    while k < len(args):
        w = args[k]
        m = sw.REDIRECT_WORD.match(w)
        if m:
            k += 1 if m.group(1) else 2
            continue
        if w == "--" or not w.startswith("-") or w == "-":
            break
        if w.startswith("--"):
            # No long options exist; read as no evidence of a window, and stop.
            break
        letters = w[1:]
        for j, ch in enumerate(letters):
            if ch in VALUED:
                value = letters[j + 1:]
                if not value:
                    k += 1
                    value = args[k] if k < len(args) else None
                out.append((ch, value))
                break
            out.append((ch, ""))
        k += 1
    return out


def verdict(args, through_xargs):
    """What a screencapture with these written arguments would take beyond one window, else None."""
    if not args:
        if through_xargs:
            return "with words xargs adds that nobody wrote, so what it captures cannot be told"
        return None  # with no arguments it prints its usage and captures nothing
    if args in (["-h"], ["--help"]):
        return None
    flags = options(args)
    for ch, _ in flags:
        if ch in WIDER:
            return "and would capture " + WIDER[ch]
    windows = [v for ch, v in flags if ch == "l"]
    if not windows:
        return "with no -l naming one window, so it captures the whole screen"
    if any(not v for v in windows):
        return "with -l but no window id after it"
    return None


def main():
    raw = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    try:
        data = json.loads(raw)
    except ValueError:
        say("it could not read the hook payload (it is not JSON)", 4)
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
    cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else ""
    try:
        records = sw.every_command(command, cwd, [])
    except Exception:
        say(os.path.join(HOOKS, "lib", "shell-words.py") + " could not read the command", 4)
    for _, text, _, _, _ in records:
        passed = []
        rest, _ = sw.command_rest(text, passed)
        words = sw.command_words(rest)
        if not words or words[0].split("/")[-1].lower() != NAME:
            continue
        why = verdict(words[1:], any(name == "xargs" for name, _ in passed))
        if why:
            say(why, 3)
    sys.exit(0)


if __name__ == "__main__":
    main()

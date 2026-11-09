#!/usr/bin/env python3
"""temp-worktree.py: whether a call puts a git worktree under a temp folder a restart empties, the
reader behind temp-worktree-gate.sh (claude-config#2528).

    temp-worktree.py bash <cwd>    stdin: one command line
    temp-worktree.py enter <cwd>   stdin: the path EnterWorktree was given

Exit 10: nothing to refuse. Exit 0: printed the refusal (the gate puts its own name in front).
Exit 3: printed why the command cannot be read, for a command that names a worktree; the gate
refuses it, since a path nobody can know may be a temp one (L42, L490). Any other exit is a crash,
and the gate then judges by the call's own words, refusing one that names a worktree add or move.

WHERE A TEMP FOLDER IS. /tmp and /var/folders, each with and without the /private macOS puts in
front, which is where a restart empties: on 2026-11-09 one emptied /private/tmp and took an agent's
worktree holding an uncommitted fix. /var/tmp is kept across a restart, so it is not one. A path is
judged both as written, made absolute and normalised, and with every folder of it that exists
resolved, so a symbolic link into /tmp counts. A path that begins with $TMPDIR, $TMP, $TEMP or
$TEMPDIR, braced or with a default, is in one whatever the variable holds.

WHAT IS JUDGED. `git worktree add`'s path (its first word that is not an option or an option's
value) and `git worktree move`'s new path, read by lib/shell-words.py as every gate reads a command:
behind rtk, env, a cd or a `bash -c` string, with git's -C folders composed and a relative path taken
from wherever the command runs. Any other worktree command (list, remove, prune, lock) passes.

WHAT CANNOT BE READ, and is refused: a path holding any other variable or a substitution, a relative
path after `cd -`, a command line only the crude cut can read, and a wrapper whose string cannot be
read, each only when the command names a worktree at all.

A REPOSITORY ALREADY IN A TEMP FOLDER loses nothing more by its worktree being there, so a worktree
of one passes. The repository is the folder git names for `rev-parse --git-common-dir` from where the
command runs (the main checkout's, from a linked worktree), or that folder itself when git finds
none, and the suggested path is its .claude/worktrees/<the name asked for>.
"""
import importlib.util
import os
import re
import subprocess
import sys

# Loading shell-words.py would otherwise leave a __pycache__ in lib/, which is the synced payload.
sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("shell_words", os.path.join(_here, "shell-words.py"))
sw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sw)

TEMP_ROOTS = ("/tmp", "/private/tmp", "/var/folders", "/private/var/folders")
TEMP_VARIABLE = re.compile(r"^\$(\{)?(TMPDIR|TMP|TEMP|TEMPDIR)(?(1)(:?[-=+?][^}]*)?\}|(?![A-Za-z0-9_]))")
HOME_VARIABLE = re.compile(r"^\$(\{HOME\}|HOME(?![A-Za-z0-9_]))")
PWD_VARIABLE = re.compile(r"^\$(\{PWD\}|PWD(?![A-Za-z0-9_]))")
# git worktree add's options that take a value, short and long; a long one may be any prefix git
# reads as it.
ADD_SHORT_VALUED = set("bB")
ADD_LONG_VALUED = ("--reason",)
WHY_LITERAL = ("write the worktree's path literally, so where it goes can be read before it runs")


class Unread(Exception):
    pass


def under(path, root):
    return path == root or path.startswith(root + "/")


def in_temp(path):
    return any(under(path, r) for r in TEMP_ROOTS)


def resolved(path):
    """The path with every folder of it that exists resolved through symbolic links."""
    head, tail = path, []
    while head not in ("/", "") and not os.path.exists(head):
        head, t = os.path.split(head)
        tail.insert(0, t)
    try:
        real = os.path.realpath(head or "/")
    except OSError:
        return path
    return os.path.normpath(os.path.join(real, *tail)) if tail else real


def temp_path(path):
    return in_temp(path) or in_temp(resolved(path))


def absolute(word, base):
    """The word as an absolute normalised path, base being where it is read from; Unread when it
    cannot be known. A word beginning with a temp variable is returned as /tmp/<the rest>."""
    m = TEMP_VARIABLE.match(word)
    if m:
        rest = word[m.end():]
        if "$" in rest or "`" in rest:
            raise Unread("its path %s holds a variable or a substitution; %s" % (word, WHY_LITERAL))
        return os.path.normpath("/tmp/" + rest.lstrip("/"))
    m = HOME_VARIABLE.match(word)
    if m:
        word = os.path.expanduser("~") + word[m.end():]
    m = PWD_VARIABLE.match(word)
    if m:
        word = (base or ".") + word[m.end():]
    if word.startswith("~"):
        word = os.path.expanduser(word)
    if "$" in word or "`" in word:
        raise Unread("its path %s holds a variable or a substitution; %s" % (word, WHY_LITERAL))
    if word.startswith("/"):
        return os.path.normpath(word)
    if not base or base == "-" or not base.startswith("/"):
        raise Unread("its path %s is relative to a folder that cannot be told; %s" % (word, WHY_LITERAL))
    return os.path.normpath(os.path.join(base, word))


def compose(base, front):
    """The folder git runs in: base with each -C in git's own options applied in order."""
    i = 0
    while i < len(front):
        w = front[i]
        if w == "-C" and i + 1 < len(front):
            v = front[i + 1]
            if "$" in v or "`" in v:
                raise Unread("its git -C folder %s holds a variable or a substitution" % v)
            if v.startswith("~"):
                v = os.path.expanduser(v)
            if v.startswith("/"):
                base = os.path.normpath(v)
            elif base and base != "-" and base.startswith("/"):
                base = os.path.normpath(os.path.join(base, v))
            else:
                base = "-"
            i += 2
            continue
        i += 2 if w in sw.GIT_VALUED else 1
    return base


def _positionals(after, short_valued, long_valued):
    out = []
    i, done = 0, False
    while i < len(after):
        w = after[i]
        if not done and w == "--":
            done = True
        elif not done and w.startswith("--"):
            name = w.split("=", 1)[0]
            if "=" not in w and any(len(name) >= 5 and o.startswith(name) for o in long_valued):
                i += 1
        elif not done and w.startswith("-") and len(w) > 1:
            letters = w[1:]
            for k, ch in enumerate(letters):
                if ch in short_valued:
                    if k == len(letters) - 1:
                        i += 1
                    break
        else:
            out.append(w)
        i += 1
    return out


def worktree_paths(sub_after):
    """(action, the path words it places a worktree at) for git worktree's words after `worktree`."""
    if not sub_after:
        return "", []
    action, rest = sub_after[0], sub_after[1:]
    if action == "add":
        pos = _positionals(rest, ADD_SHORT_VALUED, ADD_LONG_VALUED)
        return action, pos[:1]
    if action == "move":
        pos = _positionals(rest, set(), ())
        return action, pos[1:2]
    return action, []


def repository(base):
    """The folder of the repository a command run in base belongs to, or None when git finds none."""
    if not base or base == "-" or not base.startswith("/"):
        return None
    try:
        r = subprocess.run(["git", "-C", base, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                           capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    out = (r.stdout or "").strip().split("\n")[0] if r.returncode == 0 else ""
    if not out.startswith("/"):
        return None
    out = os.path.normpath(out)
    return os.path.dirname(out) if os.path.basename(out) == ".git" else out


def judge(path, base, said):
    """The refusal for a worktree at path from a command run in base, or None."""
    if not temp_path(path):
        return None
    repo = repository(base) or (base if base and base.startswith("/") else None)
    if repo and temp_path(repo):
        return None
    name = os.path.basename(path.rstrip("/")) or "worktree"
    where = (repo or "<the repository>") + "/.claude/worktrees/" + name
    return ("%s puts the worktree at %s, under a temp folder a restart empties (on 2026-11-09 a "
            "restart emptied /private/tmp and took an agent's worktree holding an uncommitted fix, "
            "claude-config#2528). Put it in the repository's .claude/worktrees/ folder instead: %s. "
            "If this worktree really is throwaway, for this one command: ALLOW_TEMP_WORKTREE=1 "
            "<the same command>." % (said, path, where))


def bash(s, cwd):
    if "worktree" not in s:
        return None
    try:
        records, crude = sw._records(s, cwd, 0)
    except Exception as e:
        raise Unread("the shell reader could not read it (%s)" % e)
    if crude:
        raise Unread("only a crude cut can read it (a quote that never closes, or the like)")
    for d, text, wrap, rest, _assigns, _field, _depth in records:
        why = wrap.partition("\x1d")[2]
        if why and "worktree" in text:
            raise Unread("it hands a string to a shell that cannot be read: %s" % why)
        words = sw.command_words(rest)
        reading = sw.git_read(words)
        if reading is None:
            head = words[0] if words else ""
            if head[:1] in ("$", "`") and "worktree" in text:
                raise Unread("its command is a variable or a substitution, known only as it runs")
            continue
        sub, front, after = reading
        if sub != "worktree":
            continue
        action, places = worktree_paths(after)
        if not places:
            continue
        base = compose(d or cwd, front)
        path = absolute(places[0], base)
        first = text.strip().split("\n")[0]
        said = judge(path, base, "`%s` (git worktree %s)" % (first, action))
        if said:
            return said
    return None


def enter(path, cwd):
    if not path:
        return None
    full = absolute(path, cwd)
    return judge(full, cwd, "EnterWorktree with path %s" % path)


def main(argv):
    if len(argv) != 3 or argv[1] not in ("bash", "enter"):
        sys.stderr.write("usage: temp-worktree.py bash|enter <cwd>\n")
        return 2
    text = sys.stdin.buffer.read().decode("utf-8", "replace")
    try:
        said = bash(text, argv[2]) if argv[1] == "bash" else enter(text.strip("\n"), argv[2])
    except Unread as e:
        sys.stdout.write(str(e))
        return 3
    if said is None:
        return 10
    sys.stdout.write(said)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

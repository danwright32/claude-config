#!/usr/bin/env python3
"""web-guidance-pin.py: the pinned version of the web guidance tool and every question asked of it
(claude-config#3565).

The tool is the npm package of Google Chrome's Modern Web Guidance, which the rule file tells every
session to run with npx before designing anything for the web. npx downloads and runs whatever the
command names, so the command names one version, read before it was pinned, and that version has
ONE home: the file beside this one, named after the package with -version after it. Every reader
takes it from here.

  web-guidance-pin.py pin
      the pinned version, exit 0; exit 1 with the reason when the file is missing or its version
      line is not a plain x.y.z.
  web-guidance-pin.py scan <root>
      every place in the files git sees under <root> (tracked, and untracked but not ignored) that
      names the package with @latest, with no version on a command that runs it, or with a version
      other than the pin, one per line as "<path>:<line>: <what>", exit 1 when there is any, exit 0
      when there is none, exit 2 when the files could not be listed.
  web-guidance-pin.py judge          stdin: a whole command
      refuses (prints why, exit 0) a command that runs the package with any version but the pin, or
      with none; prints nothing, exit 10, when it runs no other version. Read by lib/shell-words.py,
      the reading every gate uses, so a run behind env, rtk, a cd or a `bash -c` string counts, and
      words that only mention the package (a grep, a commit message) do not. Exit 3 when the
      command could not be read.
  web-guidance-pin.py behind <registry answer file> <now, epoch seconds> <minimum age, days>
      the newest release newer than the pin that is at least that old when the answer was read,
      as "<version> <publish time>", exit 0; nothing, exit 10, when there is none. The answer is
      what `npm view <package> time --json` prints. Exit 1 with the reason when it is not that: not
      JSON, not a map of versions to times, or not listing the pin itself, since an answer that
      cannot be read must never read as up to date.

The package name is written in two halves throughout, so this file never names the package in the
form the scan looks for.
"""
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys

NAME = "modern-web-" + "guidance"
HERE = os.path.dirname(os.path.abspath(__file__))
PIN_FILE = os.path.join(HERE, NAME + "-version")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def read_pin():
    try:
        with open(PIN_FILE, "rb") as f:
            text = f.read().decode("utf-8", "replace")
    except OSError as e:
        raise SystemExit("web-guidance-pin.py: the pin file %s could not be read (%s)" % (PIN_FILE, e.strerror))
    lines = [l.strip() for l in text.splitlines() if l.strip() and not l.lstrip().startswith("#")]
    if len(lines) != 1 or not VERSION.match(lines[0]):
        raise SystemExit("web-guidance-pin.py: the pin file %s must hold exactly one version line, x.y.z, and holds %r"
                         % (PIN_FILE, lines))
    return lines[0]


def key(v):
    return tuple(int(p) for p in v.split("."))


# ---------------------------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------------------------
# The package as a word of its own: not inside a longer name (the -src repository, the -version
# file) and not a folder in a path (a plugin cache), then an optional @ and what follows it.
MENTION = re.compile(r"(?<![\w/.-])" + re.escape(NAME) + r"(?![\w-])(@[^\s\"'`)*,;\]]*)?")
# What, written in front of a bare mention on the same line, runs it: so `npx -y <name>` with no
# version is a finding, while the plugin's name in a sentence is not.
RUNNER = re.compile(r"(?:\bnpx|\bbunx|\bpnpm\s+dlx|\byarn\s+dlx|\bnpm\s+(?:exec|x|i|install|add))(?:\s+-\S+)*\s+$")


def scan_text(path, text, pin):
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        for m in MENTION.finditer(line):
            at = m.group(1)
            if at is None:
                if RUNNER.search(line[:m.start()]):
                    out.append("%s:%d: runs it with no version, so npx takes the newest release" % (path, n))
                continue
            got = at[1:]
            if got == pin:
                continue
            if got == "latest":
                out.append("%s:%d: names @latest, so npx takes the newest release" % (path, n))
            else:
                out.append("%s:%d: names version %r, and the pin is %s" % (path, n, got, pin))
    return out


def scan(root, pin):
    try:
        listed = subprocess.run(["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        sys.stderr.write("web-guidance-pin.py: git could not list the files under %s (%s)\n" % (root, e))
        return 2
    found = []
    needle = NAME.encode()
    for rel in sorted(set(p for p in listed.decode("utf-8", "replace").split("\0") if p)):
        try:
            with open(os.path.join(root, rel), "rb") as f:
                raw = f.read()
        except OSError:
            continue  # listed but gone (deleted and not staged): nothing there to name it
        if needle not in raw or b"\0" in raw:
            continue
        found += scan_text(rel, raw.decode("utf-8", "replace"), pin)
    for line in found:
        print(line)
    return 1 if found else 0


# ---------------------------------------------------------------------------------------------
# judge
# ---------------------------------------------------------------------------------------------
def load_shell_words():
    sys.dont_write_bytecode = True  # no __pycache__ in lib/, which is the synced payload
    spec = importlib.util.spec_from_file_location("shell_words", os.path.join(HERE, "shell-words.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def runs_package(words):
    """The package words of a command that runs one, or [] when the command runs nothing."""
    w = list(words)
    # Past what only stands in front of a command: rtk, env with its assignments, sudo, command.
    while w and (w[0] in ("rtk", "sudo", "command", "env", "exec", "nohup", "time") or ASSIGN.match(w[0])):
        w = w[1:]
    if not w:
        return []
    name = os.path.basename(w[0])
    sub = w[1] if len(w) > 1 else ""
    if not (name in ("npx", "bunx")
            or (name == "npm" and sub in ("exec", "x", "i", "install", "add"))
            or (name in ("pnpm", "yarn") and sub == "dlx")):
        return []
    specs = []
    for i, word in enumerate(w[1:], 1):
        value = word
        for flag in ("--package=", "-p="):
            if word.startswith(flag):
                value = word[len(flag):]
        if value == NAME or value.startswith(NAME + "@"):
            specs.append(value)
    return specs


def judge(cmd, pin):
    sw = load_shell_words()
    try:
        records, _ = sw.read(cmd)
    except Exception as e:  # a reader crash is an unread command, never a pass
        sys.stderr.write("web-guidance-pin.py: lib/shell-words.py could not read the command (%s)\n" % e)
        return 3
    bad = []
    for rec in records.split("\x1e"):
        if not rec:
            continue
        fields = rec.split("\x1c")
        rest = fields[5] if len(fields) > 5 else fields[1]
        for spec in runs_package(sw.command_words(rest)):
            if spec != NAME + "@" + pin:
                bad.append(spec)
    if not bad:
        return 10
    print("this command runs %s, and only the pinned version, %s@%s, is run here (claude-config#3565). "
          "Run it as: DISABLE_TELEMETRY=1 npx -y %s@%s search \"<2 to 5 word query>\", then the same "
          "prefix with retrieve \"<id>\". A newer release is moved to by a pull request that changes "
          "hooks/lib/%s-version, after reading npm diff between the two versions."
          % (", ".join(sorted(set(bad))), NAME, pin, NAME, pin, NAME))
    return 0


# ---------------------------------------------------------------------------------------------
# behind
# ---------------------------------------------------------------------------------------------
def parse_time(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def behind(path, now, min_days, pin):
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8", "replace"))
    except (OSError, ValueError) as e:
        raise SystemExit("the registry answer could not be read as JSON (%s)" % e)
    if not isinstance(data, dict):
        raise SystemExit("the registry answer is not a map of versions to publish times")
    if pin not in data:
        raise SystemExit("the registry answer does not list the pinned version %s, so it is not an answer "
                         "about this package, or %s was unpublished" % (pin, pin))
    best = None
    for v, t in data.items():
        if not VERSION.match(v) or key(v) <= key(pin) or not isinstance(t, str):
            continue
        try:
            published = parse_time(t)
        except ValueError:
            raise SystemExit("the registry answer gives %s the publish time %r, which is not a time" % (v, t))
        if now - published >= min_days * 86400 and (best is None or key(v) > key(best[0])):
            best = (v, t)
    if best is None:
        return 10
    print("%s %s" % best)
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    verb = argv[1]
    pin = read_pin()
    if verb == "pin":
        print(pin)
        return 0
    if verb == "scan" and len(argv) == 3:
        return scan(argv[2], pin)
    if verb == "judge":
        return judge(sys.stdin.buffer.read().decode("utf-8", "replace"), pin)
    if verb == "behind" and len(argv) == 5:
        return behind(argv[2], int(argv[3]), int(argv[4]), pin)
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

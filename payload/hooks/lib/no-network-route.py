#!/usr/bin/env python3
"""The one route the Slack drafts gate gives a command it would refuse: run it under the installed
no network wrapper (claude-config#3173).

The gate refuses a command whose files reach code able to post, and that stopped one test file
being run on its own although its test posts nothing (measured on #3173 and #3143). The wrapper,
no-network-run.sh beside the gate, runs a command inside a macOS sandbox that denies every network
operation, so what runs under it cannot post whatever it is. Dan decided on 2026-11-18, on #3173:
"Yes, any command". The gate passes a command run under the installed wrapper without reading what
runs under it. That reverses the 2026-11-16 decision on #3028 that reviewers get no sanctioned
route past the gate.

THE RULE, which is all this file adds (Judge.no_network_run). The gate does not read what runs
under the wrapper, so the rule holds only where the shell of the call itself starts the installed
wrapper, once, and hands it words the shell does nothing with. One command passes when every one
of these holds, and is judged exactly as before when any does not:

  * It is a command of the call's own line: not a line of a script file, not a string another
    program runs (`bash -c`), not inside a substitution. A program can run either again and again.
  * Nothing in the call comes before it but `cd` to a folder written out (`cd /x/y && ...`). Any
    other command could change what the wrapper's path starts (a function or an alias of that
    name; zsh runs a function named by a path, measured 2026-11-19) or open a connection the
    command then inherits, which the sandbox does not close (test-no-network-run.sh, "held"). And
    a loop, a function, a subshell or a second wrapper run all have something before them, so the
    wrapper's path is started once in a call: a second start would be of whatever the first run
    left at that path, since the sandbox does not stop a command writing a file.
  * The shell itself starts the wrapper: the wrapper is the command's first word, past only `!`,
    `time`, `if` and `{`. With a variable assignment or a redirection in front, or a program that
    runs the words after it, such as env, sudo, timeout, xargs or nohup, the rule does not apply:
    each changes what starts the wrapper or what it starts in, so each goes AFTER the wrapper,
    where nothing can reach the network.
  * That first word is the wrapper's path written out: absolute, with no variable, substitution,
    pattern, brace, tilde or escape in it, bare or inside one pair of quotes. A path the gate would
    have to work out is one it can work out differently from the shell.
  * The path's real path is the installed wrapper's, and no earlier command of this call wrote,
    moved, linked, built or changed that file: the same test /nudge is let through by
    (is_installed), so a link that resolves to the installed wrapper passes as one resolving to the
    installed nudge.py does, and a copy anywhere else does not.
  * A word follows it, the command to run, and every word after the wrapper is one the shell hands
    on as it stands (WORDS): plain characters and `*` and `?`, text in single quotes, text in
    double quotes, and a variable by its name alone (`$NAME`, `${NAME}`). Anything the shell would
    work out or run itself happens before the wrapper starts and outside the sandbox: a command
    substitution, backticks, a process substitution, a here document, a brace, a tilde, a
    backslash, `${NAME:-...}`, and in zsh the code in a pattern's `(e:...:)` and a `${(e)NAME}`.
    A redirection writes or reads a file written out, or joins the two outputs (`> out.txt 2>&1`);
    none names /dev/tcp or /dev/udp, which bash opens as a connection, outside the sandbox.
    Whatever does not fit goes inside single quotes, behind a program that reads it under the
    wrapper (`... bash -c '...'`).

WHAT A PASS LEAVES BEHIND (under_no_network). The sandbox takes the network away and nothing else,
so the command can write any file, and the gate has not read what it ran. From a pass to the end
of that call every file is one an unread program may have written: a later command of the call
that runs a file, the installed nudge.py and the wrapper itself included, is refused as one whose
text cannot be read, through the same record a write to a path that cannot be worked out leaves
(made_unknown, claude-config#2721). Everything else on the line is judged as it always was: a
command after it, the other side of a pipe, a redirection's file.

WHAT A PASS DOES NOT MEAN. The gate has not read what runs under the wrapper; it has checked which
program is started. What that program does not cover is in no-network-run.sh: a hand off to
something already running outside the sandbox, without the network. And the rule goes by the
wrapper's path, as the /nudge rule does: a command the gate allows, in an earlier call or one
running at the same moment, can replace the file at that path, as it can the gate's own files.

It also holds the sentence a refusal gains so the route is named where it is needed (route_note).
"""
import os
import re

# The wrapper's file name, beside the gate.
WRAPPER = "no-network-run.sh"
# The characters a path may be written with: bare, and inside one pair of quotes (a space too).
_BARE = r"[A-Za-z0-9_@%+=:,./-]"
_INSIDE = r"[A-Za-z0-9_@%+=:,./ -]"
# The wrapper's path as the first word: (bare), ('quoted') or ("quoted"), then white space.
FIRST = re.compile(r"(?:(/" + _BARE + r"*)|'(/" + _INSIDE + r"*)'|\"(/" + _INSIDE + r"*)\")(?=[ \t])")
# A variable by its name alone. Not $NAME[...], which zsh reads as a subscript and works out.
_NAME = r"[A-Za-z_][A-Za-z0-9_]*"
_VAR = r"\$(?:\{" + _NAME + r"\}|" + _NAME + r"(?![\[(A-Za-z0-9_]))"
# One word the shell hands on as it stands: plain characters, * and ?, 'text', "text" holding no
# backtick and no $ but a variable's, and a variable.
_WORD = (r"(?:[A-Za-z0-9_@%+=:,./*?-]|'[^']*'|\"(?:[^\"\\$`]|\\[\\\"$`]|" + _VAR + r")*\"|" + _VAR + r")+")
# A file written out, for a redirection or a cd.
_FILE = r"(?:" + _BARE + r"+|'" + _INSIDE + r"*'|\"" + _INSIDE + r"*\")"
# A redirection: one output joined to the other, or a file written to or read.
_REDIRECT = r"(?:[12]?>&[12]|(?:[012]?(?:>>|>|<)|&>>?)[ \t]*" + _FILE + r")"
# What follows the wrapper's path: the command's first word, then words and redirections.
WORDS = re.compile(r"[ \t]+" + _WORD + r"(?:[ \t]+(?:" + _REDIRECT + r"|" + _WORD + r"))*[ \t]*")
# What may come before the wrapper's command in the call: nothing, or folders changed into.
FRONT = re.compile(r"(?:\s*cd[ \t]+(?!-)" + _FILE + r"[ \t]*(?:&&|;|\n))*\s*")
# The shell's own words that may stand in front of the wrapper in its command. Not then, do, while
# or until: each has a command before it or runs its command again.
HEAD = frozenset({"!", "time", "-p", "--", "if", "{"})
# A file name bash opens as a connection.
DEV_NET = re.compile(r"/dev/(?:tcp|udp)\b")
# What a refusal reads like when a file's imports are what reach the code that posts.
IMPORTS = ", which imports "
# What a later file of the call is said to have been written by, where one may have been.
UNDER = "the command run under the no network wrapper"


def make(here):
    """The Judge's base for the route. here is the folder the gate is installed in."""

    class NoNetworkRoute:
        def installed_wrapper(self):
            """The installed wrapper's real path, or None where there is none beside the gate."""
            path = os.path.join(here, WRAPPER)
            return os.path.realpath(path) if os.path.isfile(path) else None

        def is_installed(self, real, installed):
            """Whether real, a real path, is the installed file a rule lets through by where it is
            (installed, None where it is not there), untouched by this call: nothing an earlier
            command of the call wrote, copied, moved, linked or may have changed. The one test for
            /nudge (Dan, 2026-11-05) and for the no network wrapper."""
            return bool(installed) and real == installed and not self.made_from(real)

        def no_network_run(self, text, depth):
            """Whether one command, as written, is a command run under the installed no network
            wrapper (THE RULE above). depth is the walk's: 0 for the call's own line. Asked of
            every command, so the cheap answers come first: the words record() already read, then
            the path, and only for the wrapper itself the rest."""
            if not self.no_network:
                return False
            rest, assigns = self.rest_of(text)
            rest = rest.strip()
            if assigns or rest[:1] not in ("/", "'", '"'):
                return False
            first = FIRST.match(rest)
            if not first:
                return False
            real = os.path.realpath(first.group(1) or first.group(2) or first.group(3))
            if real != self.no_network:
                return False
            # Its words, and what stands in front of it in its own command.
            if not WORDS.fullmatch(rest, first.end()) or DEV_NET.search(rest):
                return False
            own = text.strip()
            if not own.endswith(rest) or any(w not in HEAD for w in own[:len(own) - len(rest)].split()):
                return False
            passed = []
            self.sw.command_rest(text, passed)
            if passed or not self.sw.alone(rest):
                return False
            # Where it is in the call: on the call's own line, as it is written there, after
            # nothing but a cd.
            at = self.shell.get("at")
            if depth != 0 or not self.shell.get("outer") or at is None:
                return False
            line = self.shell.get("text") or ""
            while at < len(line) and line[at].isspace():
                at += 1  # the reader's place for a command after && is the white space before it
            if not line.startswith(own, at) or not FRONT.fullmatch(line, 0, at):
                return False
            if self.made_built and (self.built_from(real) or self.native_unlisted(real)):
                return False
            return self.is_installed(real, self.no_network)

        def under_no_network(self, text, depth):
            """judge()'s question of one command: whether it is run under the installed wrapper
            and so is not read. A yes also leaves the record of what the gate did not read (WHAT A
            PASS LEAVES BEHIND above): every file is, from here to the end of the call, one whose
            text cannot be worked out."""
            if not self.no_network_run(text, depth):
                return False
            self.made_unknown.append(("*", UNDER))
            return True

        def route_note(self, reason):
            """The sentence a refusal gains when a file's imports are what reach code that posts: the
            route by which a test or a check can still be run. "" for any other refusal, and where
            no wrapper is installed, since a route that is not there must not be named (L111)."""
            if not self.no_network or IMPORTS not in reason:
                return ""
            return (" If the command is a test or a check that is meant to post nothing, run it again under the "
                    "no network wrapper, which this gate lets through because what runs under it has no network "
                    f"access at all. Make it a call of its own, and write {self.no_network} as the first word of "
                    "the command that runs the file: only a cd to a folder written out may come before it, "
                    "anything else (a program such as timeout, or env NAME=value) goes after it, in plain or "
                    "quoted words, and nothing else in that call may run a file (Dan, 2026-11-18, "
                    "claude-config#3173).")

    return NoNetworkRoute

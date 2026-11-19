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

THE RULE, which is all this file adds (Judge.no_network_run). One command passes when every one of
these holds, and is judged exactly as before when any does not:

  * Its own text, read alone, is exactly one command (the shared reader's alone()). So it holds no
    command substitution, backticks or process substitution, each of which the shell runs BEFORE the
    wrapper and outside the sandbox, and it is not a line the reader could only cut crudely.
  * The shell itself starts the wrapper: the wrapper is the command's first word, past only the
    shell's reserved words, such as then, do and time. With a variable assignment in front, or a
    program that runs the words after it, such as env, sudo, timeout, xargs or nohup, the rule does
    not apply: each changes what starts the wrapper or what it starts in, so each goes AFTER the
    wrapper, where nothing can reach the network.
  * That first word is the wrapper's path written out: absolute, with no variable, substitution,
    pattern, brace, tilde or escape in it, bare or inside one pair of quotes. A path the gate would
    have to work out is one it can work out differently from the shell.
  * The path's real path is the installed wrapper's, and no earlier command of this call wrote,
    moved, linked, built or changed that file: the same test /nudge is let through by
    (is_installed), so a link that resolves to the installed wrapper passes as one resolving to the
    installed nudge.py does, and a copy anywhere else does not.
  * A word follows it: the command to run.

Everything else on the line is judged as it always was: a command before or after it, the other
side of a pipe, a redirection's file. The commands inside a `bash -c` string and the lines of a
script file are each a command, so the wrapper passes there as it does on the line itself.

WHAT A PASS DOES NOT MEAN. The gate has not read what runs under the wrapper; it has checked which
program is started. What that program does not cover is in no-network-run.sh: a hand off to
something already running outside the sandbox, without the network.

It also holds the sentence a refusal gains so the route is named where it is needed (route_note).
"""
import os
import re

# The wrapper's file name, beside the gate.
WRAPPER = "no-network-run.sh"
# The characters its path may be written with: bare, and inside one pair of quotes (a space too).
BARE = re.compile(r"/[A-Za-z0-9_@%+=:,./-]*")
QUOTED = re.compile(r"/[A-Za-z0-9_@%+=:,./ -]*")
# What a refusal reads like when a file's imports are what reach the code that posts.
IMPORTS = ", which imports "


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

        def no_network_run(self, text):
            """Whether one command, as written, is a command run under the installed no network
            wrapper (THE RULE above). Asked of every command, so the cheap answers come first: the
            words record() already read, then the path, and only for the wrapper itself a second
            reading of the text."""
            if not self.no_network:
                return False
            rest, assigns = self.rest_of(text)
            rest = rest.strip()
            if assigns or rest[:1] not in ("/", "'", '"'):
                return False
            toks = self.sh_tokens(self.sw.join_continuations(rest))
            if len(toks) < 2 or toks[0][0] != "word" or toks[1][0] != "word":
                return False
            raw = toks[0][1]
            if len(raw) > 1 and raw[0] == raw[-1] and raw[0] in "'\"":
                raw = raw[1:-1]
                if not QUOTED.fullmatch(raw):
                    return False
            elif not BARE.fullmatch(raw):
                return False
            real = os.path.realpath(raw)
            if real != self.no_network:
                return False
            passed = []
            self.sw.command_rest(text, passed)
            if passed or not self.sw.alone(rest):
                return False
            if self.made_built and (self.built_from(real) or self.native_unlisted(real)):
                return False
            return self.is_installed(real, self.no_network)

        def route_note(self, reason):
            """The sentence a refusal gains when a file's imports are what reach code that posts: the
            route by which a test or a check can still be run. "" for any other refusal, and where
            no wrapper is installed, since a route that is not there must not be named (L111)."""
            if not self.no_network or IMPORTS not in reason:
                return ""
            return (" If the command is a test or a check that is meant to post nothing, run it again under the "
                    "no network wrapper, which this gate lets through because what runs under it has no network "
                    f"access at all: write {self.no_network} as the first word of the command that runs the file, "
                    "with any variable or other program after it and nothing before it (Dan, 2026-11-18, "
                    "claude-config#3173).")

    return NoNetworkRoute

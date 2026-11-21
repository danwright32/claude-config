#!/usr/bin/env python3
"""The one route the Slack drafts gate gives a command it would refuse: run it under the installed
no network wrapper (claude-config#3173).

The gate refuses a command whose files reach code able to post, and that stopped one test file
being run on its own although its test posts nothing (measured on #3173 and #3143). The wrapper,
no-network-run.sh beside the gate, runs a command inside a macOS sandbox that denies every network
operation, so what runs under it cannot use the network while it runs there, whatever it is. Dan
decided on 2026-11-18, on #3173: "Yes, any command". The gate passes a command run under the
installed wrapper without reading what runs under it. That reverses the 2026-11-16 decision on
#3028 that reviewers get no sanctioned route past the gate.

THE RULE, which is all this file adds (Judge.no_network_run). The gate does not read what runs
under the wrapper, so the rule is no wider than this: the shell of the call starts the installed
wrapper, by its real path, and everything the call runs is under it. A call passes when every one
of these holds, and is judged exactly as before when any does not:

  * The wrapper's command is the WHOLE call (CALL), on the call's own line: not a line of a script
    file, not a string another program runs, not inside a substitution. One thing may stand in
    front of it, `cd <a folder written out> &&`, and nothing may follow it: no `;`, `&&`, `||`,
    `|` or `&`, no second line, no comment. What ran under the wrapper is unread and can write any
    file, and the gate does not read everything a later command starts as a file: a package
    script, a program found by its bare name in a folder on the PATH, a git hook, a Makefile
    (the review of 2026-11-19). The other side of a pipe can wait for those writes. So a filter
    or a second step goes INSIDE the wrapped command, behind `sh -c '...'`, where it has no
    network either.
  * Nothing else stands in front of it: no other command, which could change what the wrapper's
    path starts (a function or an alias of that name; zsh runs a function named by a path,
    measured 2026-11-19) or open a connection the command then inherits, which the sandbox does
    not close (test-no-network-run.sh, "held"); no variable assignment or redirection; no program
    that runs the words after it; and no word of the shell's own, not `time`, `!`, `{`, `if`,
    `then`, `do`, `coproc`, `noglob`, `command`, `builtin`, `exec` or `nocorrect`. zsh runs
    `time -p <words>` as a program named -p, and bash opens a redirection on a group or an if
    before it runs what is inside (both in the review of 2026-11-19). Each of those goes AFTER
    the wrapper, where nothing can reach the network.
  * Every character of the call is printable ASCII, a tab or a newline (ODD), and the only white
    space between words is a space or a tab. Python's strip, isspace and \\s take a no break
    space, a line separator, a form feed, a vertical tab and a carriage return as white space,
    and zsh and bash keep each inside the word, so with one in front of the wrapper's path the
    shell starts a file of another name in the folder the call is in. The rule reads no character
    it would have to know the class of, inside quotes included.
  * The first word is the wrapper's path written out (CALL's path): absolute, with no variable,
    substitution, pattern, brace, tilde or escape in it, bare or inside one pair of quotes, and
    ending in a file's name. A path the gate would have to work out is one it can work out
    differently from the shell.
  * The path's real path is the installed wrapper's: the same test /nudge is let through by
    (is_installed), so a link that resolves to the installed wrapper passes as one resolving to
    the installed nudge.py does, and a copy anywhere else does not.
  * A word follows it, the command to run, and every word after the wrapper is one the shell hands
    on as it stands (_WORD): plain characters and `*` and `?`, text in single quotes, text in
    double quotes, and a variable by its name alone (`$NAME`, `${NAME}`). Anything the shell would
    work out or run itself happens before the wrapper starts and outside the sandbox: a command
    substitution, backticks, a process substitution, a here document, a brace, a tilde, a
    backslash, `${NAME:-...}`, and in zsh the code in a pattern's `(e:...:)` and a `${(e)NAME}`.
    Whatever does not fit goes inside single quotes, behind a program that reads it under the
    wrapper (`... sh -c '...'`).
  * A redirection after the wrapper's words is one of these and no other (_REDIRECT): the
    command's output or its errors written or added to a file written out (`> f`, `>> f`, `1> f`,
    `2> f`, `2>> f`), its input read from one (`< f`), and one output joined to the other
    (`2>&1`, `1>&2`, `>&2`). The shell opens that file before the wrapper starts and does nothing
    else. Not `&>` or `&>>` (bash 3.2, the one macOS ships, reads `cmd &>> f` as `cmd &` and a
    second command), not `>|`, `<>`, a descriptor past 2, a closed one, a here string, a target
    with a variable or a pattern in it, or a name holding /dev/tcp or /dev/udp, which bash opens
    as a connection, outside the sandbox.

The shared reader is asked as well, and has to agree: that the command it cut at that place is the
wrapper's and no other, with no assignment and no program read past in front, alone in its text.
It can only turn a call away. The rule itself reads the call's text and nothing the reader made of
it, so a reading of the reader's that differs from the shell's cannot widen it.

WHAT A PASS LEAVES BEHIND (under_no_network). The sandbox takes the network away and nothing else,
so the command can write any file, and the gate has not read what it ran. A pass leaves the record
of that: from then on every file is one an unread program may have written, through the same
record a write to a path that cannot be worked out leaves (made_unknown, claude-config#2721). No
call can reach it today, since nothing may follow the wrapper's command. It is kept so that the
rule cannot be widened to let something follow without that something being refused, and it and
the check that this call has not written the wrapper's file (is_installed) are each asked on their
own by the suite, of one Judge handed two lines.

WHAT A PASS DOES NOT MEAN. The gate has not read what runs under the wrapper; it has checked which
program is started and that nothing else is. The route stops code from using the network while it
runs under the wrapper, which is what makes an accidental post from a test impossible. Since #3288
the wrapper also refuses the hand offs it names, where a program outside the sandbox would act for
the code: starting open, osascript, launchctl, crontab or shortcuts, and the requests to have
something opened, to send an Apple event to another app and to have launchd make a job. It does
not contain code written to get out: the sandbox allows every file write, so such code can leave
something behind that a later call reads without this gate reading it (a shell startup file, a
tool's config file, a program in a folder on the PATH the user can write, the wrapper's own file,
a file in a folder launchd reads at the next login), or reach a hand off the wrapper's rules do
not name (a service found by its name that acts for its caller in a way no rule there names).
no-network-run.sh says the same of itself, with what was measured.

It also holds the sentence a refusal gains so the route is named where it is needed (route_note).
"""
import os
import re

# The wrapper's file name, beside the gate.
WRAPPER = "no-network-run.sh"
# The characters a path may be written with: bare, and inside one pair of quotes (a space too).
_BARE = r"[A-Za-z0-9_@%+=:,./-]"
_INSIDE = r"[A-Za-z0-9_@%+=:,./ -]"
# The wrapper's path as the first word: (bare), ('quoted') or ("quoted").
_PATH = r"(?:(?P<bare>/" + _BARE + r"*)|'(?P<single>/" + _INSIDE + r"*)'|\"(?P<double>/" + _INSIDE + r"*)\")"
# A variable by its name alone. Not $NAME[...], which zsh reads as a subscript and works out.
_NAME = r"[A-Za-z_][A-Za-z0-9_]*"
_VAR = r"\$(?:\{" + _NAME + r"\}|" + _NAME + r"(?![\[(A-Za-z0-9_]))"
# One word the shell hands on as it stands: plain characters, * and ?, 'text', "text" holding no
# backtick and no $ but a variable's, and a variable.
_WORD = (r"(?:[A-Za-z0-9_@%+=:,./*?-]|'[^']*'|\"(?:[^\"\\$`]|\\[\\\"$`]|" + _VAR + r")*\"|" + _VAR + r")+")
# A file written out, for a redirection or a cd.
_FILE = r"(?:" + _BARE + r"+|'" + _INSIDE + r"*'|\"" + _INSIDE + r"*\")"
# A redirection: one output joined to the other, output or errors written or added to a file, or
# input read from one. No other form (THE RULE above names the ones left out and why).
_REDIRECT = r"(?:[12]?>&[12]|(?:[12]?>>?|<)[ \t]*" + _FILE + r")"
# The whole call: one cd to a folder written out and && at most, the wrapper's path, the command's
# first word, then words and redirections, and nothing after. Only a space and a tab part words,
# and a newline may stand at either end or inside quotes.
CALL = re.compile(
    r"[ \t\n]*(?:cd[ \t]+(?!-)" + _FILE + r"[ \t]*&&[ \t]*)?"
    r"(?P<run>" + _PATH + r"[ \t]+" + _WORD + r"(?:[ \t]+(?:" + _REDIRECT + r"|" + _WORD + r"))*)"
    r"[ \t\n]*")
# Any character the rule does not read: all but printable ASCII, a tab and a newline.
ODD = re.compile(r"[^\x20-\x7e\t\n]")
# The white space the rule reads, for the places a text is trimmed. Never str.strip() bare, which
# takes every character Python calls white space.
BLANK = " \t\n"
# A file name bash opens as a connection.
DEV_NET = re.compile(r"/dev/(?:tcp|udp)\b")
# What a refusal reads like when a file's imports are what reach the code that posts.
IMPORTS = ", which imports "
# What a later file is said to have been written by, where one may have been.
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

        def no_network_call(self):
            """The call's own line read as THE RULE reads it: CALL's match where the whole of it is
            the wrapper's command behind one cd at most, else None. Worked out once for a line,
            from its text alone, since every command of the line asks."""
            got = self.shell.get("no_network_call")
            if got is None:
                line = self.shell.get("text") or ""
                found = None if ODD.search(line) or DEV_NET.search(line) else CALL.fullmatch(line)
                got = self.shell["no_network_call"] = found or False
            return got or None

        def no_network_run(self, text, depth):
            """Whether one command, as written, is a command run under the installed no network
            wrapper (THE RULE above). depth is the walk's: 0 for the call's own line. Asked of
            every command, so the cheap answers come first."""
            if not self.no_network or depth != 0 or not self.shell.get("outer"):
                return False
            at = self.shell.get("at")
            call = self.no_network_call() if at is not None else None
            if not call:
                return False
            # This command is the wrapper's, at the place the call has it and as it is written there.
            line, run = call.string, call.group("run")
            while at < len(line) and line[at] in BLANK:
                at += 1  # the reader's place for a command after && is the white space before it
            if at != call.start("run") or text.strip(BLANK) != run:
                return False
            # And the shared reader reads it so too: no assignment, no program read past, one command.
            passed = []
            rest, assigns = self.sw.command_rest(text, passed)
            if assigns or passed or rest.strip(BLANK) != run or not self.sw.alone(run):
                return False
            written = call.group("bare") or call.group("single") or call.group("double")
            if os.path.basename(written) in ("", ".", ".."):
                return False  # no file's name at its end: the shell could not start it
            real = os.path.realpath(written)
            if self.made_built and (self.built_from(real) or self.native_unlisted(real)):
                return False  # a build this call ran writes it
            return self.is_installed(real, self.no_network)

        def under_no_network(self, text, depth):
            """judge()'s question of one command: whether it is run under the installed wrapper
            and so is not read. A yes also leaves the record of what the gate did not read (WHAT A
            PASS LEAVES BEHIND above): every file is, from then on, one whose text cannot be
            worked out."""
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
                    "access at all. Make it a call of its own that holds that one command and nothing else: write "
                    f"{self.no_network} as the first word of the command that runs the file, with nothing before "
                    "it but `cd <the folder> &&`, and nothing after the command's own words but its output sent "
                    "to a file (`> out.txt 2>&1`): no pipe, no second command, no second line. Anything else (a "
                    "program such as timeout, env NAME=value, a filter for the output) goes after the wrapper as "
                    "part of the command it runs, in plain or quoted words, for example behind sh -c '...' (Dan, "
                    "2026-11-18, claude-config#3173).")

    return NoNetworkRoute

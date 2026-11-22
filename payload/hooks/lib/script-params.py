"""A script's own $0 and $1..., for the path of a file it sources (claude-config#3395).

A file sourced by a path the gate cannot work out is refused unread (#2538). Counted on one Mac's
records for #3218 (2026-11-08 to 11-21), that refusal fired 59 times, and none of the 59 posted.
Put through the gate as it stood on 2026-11-22, most of the shapes behind them already passed (the
folder idiom on BASH_SOURCE, a path set in one variable from another). Two did not, and both are
values the gate can know for certain from the command that runs the script:

  * `D="$(cd "$(dirname "$0")" && pwd)"` then `. "$D/lib/x.sh"`. A script's $0 is the word that ran
    it, and the gate already took it so where the source line itself held $0 (#2913). The walk of
    the script's variables (sh_walk) did not, so the same path through a variable was not worked
    out.
  * `. "$1"` and `. "$1/lib/x.sh"` in a script the command hands the word to (`bash probe.sh
    lib/x.sh`).

They are taken up only where a sourced path needs them. A script is read as it always was, its
variables walked without its $0 and no command of it given its $1, until a source or . command of
it names a path that reading cannot work out: the place where the gate has refused the script
unread since #2538. Only there (source_word_choices, reads_more) is the script's text walked once
more with its $0 (script_zero) and its $1... (script_param), and the source word worked out with
them (source_word_params). From that command on the script's variables are the ones that walk
found, for every command, so a variable the sourced file sets, or one built from $0, is known to
the commands after it. Nothing before that command is read again.

So a script with no such source command is read exactly as before, and the first form of this
change, which gave the values to every script, is why: a script that only hands its $1 on to a
program (`python3 - "$1"`) is judged by the rule for a script handed a file, which that form
replaced with a reading of the file the word names, and five cases of the gate's own suite went
red (three scripts newly refused, two refusals worded for the wrong cause; 2026-11-22). A script
that does reach this reading is one the gate refused before it, so nothing it finds there refuses a
script that passed.

Each value is given only where it is certain, and anything else is left as it was, refused:

  * $0 in the walk only for a text bash or dash reads. In bash and dash a sourced file's $0 is the
    script that sourced it (which the gate carries, next_zero), and a function's $0 is the
    script's. In zsh a sourced file's $0 is that file and a function's is the function, and in ksh
    a function's can be the function, so there the walk is told nothing. A file sourced from the
    command line has the session's shell's $0, which is not known either.
  * $1... only for a file that is run, by `script words`, or by a shell handed the script with no
    option but -e, -u, -x, -v and -n, after nothing but NAME=value words, env, command, exec, nohup
    and time: xargs, find -exec and the like add or replace words. A word that cannot be worked
    out leaves it and every one after it unknown. A sourced file is given none: it shares the
    caller's, which the caller may have changed.
  * $1... only where the command that runs the script is one of its text's own commands
    (shell["outer"]): the gate keeps one place for a command and for everything a string it hands
    another program runs, so a script run from inside such a string would be read with the words
    of the command around it.
  * $1... only before the first place in the script's text that could change them or stand for
    another value: shift, set with an operand, eval, a sourced file (which shares them and may do
    either), a function (whose $1 is its own argument) or a loop (whose later turns follow a shift
    written after it). Comments are left out; a word in a string still counts, which only refuses
    more.
  * $1... in the script's own commands only for the word of a source or . command, and only for
    one of the text's own commands. Every other command keeps the rule for a script handed a file.

What such a script reads depends on its parameters, so one read once and found clean is found so
again only for the same ones (script_reads_by, in script()'s key): `bash p.sh calm.sh; bash p.sh
posts.sh` reads p.sh twice. The words are worked out only for a script that has reached this
reading once (param_scripts), which is every script whose reading can depend on them; working
them out for every script read cost a search of the caller's commands each time.

slack_drafts_only_gate.py loads this file and gives its Judge the class make() returns as a base, so
the methods use the Judge's own state (shell, unfollowed) and readers (parsed, sh_tokens,
sh_strip_openers, sh_word, sh_source_var, sh_source_choices, sh_source_target, unworked_path,
sh_ctx_known, sw).
"""
import os
import re

# Words whose text before a command means the script's parameters may no longer be the command
# line's, or may stand for a function's or a later turn of a loop's (module docstring).
PARAMS_END = re.compile(
    r"(?<![\w./$-])(shift|eval|source|for|while|until|select|function)(?![\w.-])"
    r"|(?<![\w./$-])(set)(?:[ \t]+[-+](?:[A-Za-z]*o[ \t]+\w+|[A-Za-z]*[A-Za-np-z](?![A-Za-z])))*"
    r"[ \t]+(?:--|[^-+\s;&|#)])"
    r"|(\(\s*\))"
    r"|(?:^|[;&|({!]|\bthen|\belse|\bdo)[ \t]*(\.)[ \t]+\S", re.M)
COMMENT = re.compile(r"(?m)(^|\s)#.*$")
# The shells whose $0 is the script's everywhere in a text they read (module docstring).
ZERO_SHELLS = ("bash", "dash")
SHELL_OPTIONS = re.compile(r"-[euxvn]+")
# What may stand in front of the script or its shell: programs that run the words after them as
# they are (the gate's own list for a `bash -c` string, Judge.SH_POS_LAUNCHERS).
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*=")
BUILT = re.compile(r"[$`]")


def params_end(text):
    """(the offset in text of the first word that ends what is certain about its parameters, or
    len(text) where there is none; whether that word is a source or . command, whose own words are
    read before the file it names can change anything). Comments are blanked, each offset kept."""
    plain = COMMENT.sub(lambda m: m.group(1) + " " * (len(m.group(0)) - len(m.group(1))), text)
    first, sources = len(text), False
    for m in PARAMS_END.finditer(plain):
        k = next(k for k in range(1, 5) if m.group(k) is not None)
        if m.start(k) < first:
            first, sources = m.start(k), m.group(k) in (".", "source")
    return first, sources


def make(shells, sh_redirect, unknown_dir):
    """The Judge's base for the rule. shells is the gate's set of shell names, sh_redirect its
    pattern for a redirection's operator, unknown_dir its word for a directory that is not certain."""

    class ScriptParams:
        # For the script about to be read, set by script(): (its real path, the word that runs it,
        # or None for a sourced file). line() moves it to the script's shell["ran"].
        next_ran = None

        def param_scripts(self):
            """The real paths of the scripts whose reading reached their $0 or $1... (reads_more)."""
            got = self.__dict__.get("_param_scripts")
            if got is None:
                got = self.__dict__["_param_scripts"] = set()
            return got

        def source_word_choices(self, text, d):
            """For the source or . command being judged: (sh_source_choices' reading of it, the
            refusal where its path cannot be worked out). Where the reading the gate always made
            refuses it, and the script's own $0 and $1... have not been taken up yet, they are
            (reads_more), and the command is read once more with them."""
            ctx = self.shell
            ctx["sourcing"] = True
            try:
                while True:
                    choices = self.sh_source_choices(text, d)
                    if not (choices and choices[0][1]):
                        return choices, None
                    raw = self.sh_source_target(text)
                    if raw and not BUILT.search(raw):
                        return choices, None  # a literal path, which the caller reads where it runs
                    noted = len(self.unfollowed)
                    reason = self.unworked_path(text, 1, d, "sources")
                    if reason is None or not self.reads_more():
                        return choices, reason
                    del self.unfollowed[noted:]  # that refusal is not given: the command is read again
            finally:
                ctx["sourcing"] = False

        def reads_more(self):
            """Take up the $0 and $1... of the script being read, for the rest of its reading: True
            where that was done now, False where it already was or the text is not a script's that
            script() read. Asked only where the gate would otherwise refuse the script unread."""
            ctx = self.shell
            ran = ctx.get("ran")
            if not ran or ctx.get("full"):
                return False
            real, word = ran
            ctx["full"] = True
            self.param_scripts().add(real)
            ctx["params"] = None if word is None else self.script_params(ctx.get("parent"), word)
            if ctx["known"] is not None:
                # The walk of its variables, made once more with them, for this command and every
                # one after it.
                ctx["known"] = None
                self.sh_ctx_known()
            return True

        def source_word_params(self):
            """For sh_source_var, while the word of a source or . command is worked out
            (source_word_choices): [$0, $1, ...] of the script being read where they are certain
            for that command, else None."""
            ctx = self.shell
            if not (ctx.get("sourcing") and ctx.get("full") and ctx.get("outer")):
                return None
            return self.params_at(ctx, ctx.get("at"))

        def script_param(self, n, s, at):
            """For sh_walk, for a word of the command at offset at of the text s: the value of $n, a
            digit or more, where it is certain, else None."""
            if n == "0":
                return self.script_zero(s)
            ctx = self.shell
            params = self.params_at(ctx, at) if ctx.get("full") and s == ctx["text"] else None
            return params[int(n)] if params and int(n) < len(params) else None

        def script_walk_key(self, s):
            """For sh_known's key: what a walk of s reads beyond its text, its $0 and its $1...."""
            ctx = self.shell
            params = ctx.get("params") if ctx.get("full") and s == ctx["text"] else None
            return self.script_zero(s), tuple(params) if params else None

        @staticmethod
        def params_at(ctx, at):
            """[$0, $1, ...] of the text ctx holds, where they are certainly still what the command
            line gave for a command at offset at: before the first word that could change them, or
            at it where that word is the source command itself."""
            params = ctx.get("params")
            if not params or at is None:
                return None
            if "params_end" not in ctx:
                ctx["params_end"] = params_end(ctx["text"])
            end, sources = ctx["params_end"]
            return params if at < end or (at == end and sources) else None

        def script_zero(self, s):
            """For sh_walk's look and sh_known's key: the $0 of the text s, where s is the text being
            read, its reading has taken its $0 up (reads_more) and bash or dash reads it; None
            otherwise."""
            ctx = self.shell
            if not ctx.get("full") or s != ctx["text"] or ctx.get("program") not in ZERO_SHELLS:
                return None
            return ctx.get("zero")

        def script_params(self, ctx, word):
            """[$0, $1, ...] for the script the word names, run by the command being read in the text
            ctx holds, each worked out from that command, with None for the first word that cannot
            be and nothing after it; None where that command is not one of the text's own, or not
            one of the forms in the module docstring."""
            at = ctx.get("at") if ctx else None
            if at is None or not ctx.get("outer"):
                return None
            try:
                parts = self.parsed(ctx["text"], ctx["cwd"])[1]
            except self.sw.Unreadable:
                return None
            part = next((p for p in parts if p["start"] == at), None)
            if part is None:
                return None
            text = self.sw.join_continuations(ctx["text"][part["start"]:part["end"]]).strip()
            toks, raw, i = self.sh_tokens(self.sh_strip_openers(text)), [], 0
            while i < len(toks):
                kind, t = toks[i]
                if kind == "op":
                    if not sh_redirect.fullmatch(t):
                        break
                    i += 2
                    continue
                raw.append(t)
                i += 1

            def value(w):
                # The caller's own variables, as its commands see them at that command. The shell
                # being read is the caller's while script() asks and the script's while reads_more
                # does, so the caller's is put in place for the reading.
                saved, self.shell = self.shell, ctx
                try:
                    v, splits = self.sh_word(w, unknown_dir, self.sh_source_var, ctx["script"], False)
                finally:
                    self.shell = saved
                return None if splits else v

            k, env = 0, False
            while k < len(raw):
                if raw[k] in self.SH_POS_LAUNCHERS:
                    env = raw[k] == "env"
                elif env and raw[k] == "-u" and k + 1 < len(raw):
                    k += 1  # env -u NAME takes the name after it
                elif not (ASSIGNMENT.match(raw[k]) or (env and raw[k] == "-i")):
                    break
                k += 1
            if k >= len(raw):
                return None
            if value(raw[k]) != word:
                if os.path.basename(raw[k].strip("'\"")) not in shells:
                    return None
                k += 1
                while k < len(raw) and SHELL_OPTIONS.fullmatch(raw[k]):
                    k += 1
                if k >= len(raw) or value(raw[k]) != word:
                    return None
            out = [word]
            for w in raw[k + 1:]:
                v = value(w)
                out.append(v)
                if v is None:
                    break
            return out

        def script_reads_by(self, word, sourced, real):
            """For script()'s key: what the reading of this script depends on beyond its text, the
            caller's $0 for a sourced file, and for one that is run and has reached its $1... once
            (param_scripts), the words this command hands it."""
            if sourced:
                return self.shell.get("zero")
            if real not in self.param_scripts():
                return None
            params = self.script_params(self.shell, word)
            return ("handed", None if params is None else tuple(params))

    return ScriptParams

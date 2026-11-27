"""Code a command loads without naming it as a script, for the Slack drafts gate (claude-config#2912,
#2977, #2978).

Before these, four routes ran a file the gate never read:

  * A PHP include (#2978): `php -r 'include "post.php";'` passed with post.php naming an endpoint,
    with -i in front too. Each include, include_once, require and require_once is now followed as a
    JavaScript or Python import is (php_includes), in code given by -r, -B, -R or -E and in a PHP
    script, and one whose path is not a literal string is refused, since the gate cannot tell what
    it names.
  * NODE_OPTIONS (#2912): node loads every --require, --import and loader it names before anything
    else, so `NODE_OPTIONS='--require ./post.mjs' node -e 1` ran post.mjs unread. Each file its value
    names is now read as code, whatever program the command runs, since any of them can start node
    (node_options).
  * A name perl's <> opens as a command (#2912): perl opens each name it is handed with the two
    argument open, which runs a name starting or ending in | as a command. Such a name was judged
    only where a file naming an endpoint was also handed to the code, and never where a glob the
    shell expands named it. Each is now judged as a command line (perl_pipe_names), and where perl
    opens what it is handed, a name built by a substitution, backquotes or a brace expansion is
    refused, as what it becomes cannot be seen, and one from a variable the gate cannot work out is
    refused with the #2683 switch on, as a file run by such a path is.
  * A file with a NUL in its first line run by zsh or dash (#2977): bash, sh and ksh refuse to run
    it, so #2892 only searched it for an endpoint, but zsh and dash run it. It is now read as the
    shell running it reads it (nul_reading).

And one more since (claude-config#3600): input run after the code a program was given. `node -i -e
CODE < post.js` and `perl -d -e CODE < post.pl` go on to run what they are fed once the code ends,
and none of it was read (input_after_code).

And the files an interpreter loads as it starts because the command sets a variable that names
them (claude-config#3675). Measured on 2026-11-25 with stand in scripts that only wrote a marker
file, one run of each shape (python 3.14.4 and 3.9.6, ruby 2.6.10, perl 5.34.1, bash 3.2.57, zsh
5.9, dash, ksh, node 22.22.2, bun): each ran the extra file, and the gate allowed each where that
file posts, since it read only the quiet script the command names.

  * `PYTHONPATH=dir python3 quiet.py` imports dir/sitecustomize.py and dir/usercustomize.py (a
    package folder of either name too), from any entry of the value; not with -S, -E or -I.
    `PYTHONUSERBASE=dir` has it run usercustomize and the import lines of each .pth file in
    dir/lib/python/site-packages, and `HOME=dir` the same in the user site folder under dir.
  * `RUBYOPT=-r./mod ruby quiet.rb` loads mod.rb; `RUBYOPT=-rmod` loads it from a folder RUBYLIB,
    an -I inside RUBYOPT or an -I on ruby's command line names. `RUBYLIB=dir ruby quiet.rb` loads
    dir/rubygems.rb in place of ruby's own.
  * `PERL5OPT=-MMod perl quiet.pl` loads Mod.pm from a folder PERL5LIB or an -I names (-m, and
    -d:Name for Devel/Name.pm, the same). `PERL5LIB=dir perl -d quiet.pl` loads dir/perl5db.pl in
    place of perl's own debugger.
  * `BASH_ENV=file bash quiet.sh` runs file first (bash, and a script run by its path whose first
    line names bash; not sh, bash --posix or bash -p). `ENV=file` does for sh, dash and ksh given
    -i. `ZDOTDIR=dir zsh quiet.sh` runs dir/.zshenv (and .zprofile, .zshrc, .zlogin given -l or
    -i; not with -f), and `HOME=dir` the same files, bash's .bashrc and .bash_profile, .profile
    and .kshrc for a shell given -i or -l. (.bash_login is read from HOME too, as the file bash
    -l runs where there is no .bash_profile; that one was not measured.)
  * `BUN_OPTIONS='--preload ./mod.js' bun quiet.js` loads mod.js, and
    `NODE_REPL_EXTERNAL_MODULE=./mod.js node -i` runs it.
  * `node -- -x.js`: node looks for a main file named with a leading dash in the folders NODE_PATH
    names, in .node_modules and .node_libraries under HOME, and in lib/node beside its own
    folder, never in the folder it runs in (node_dash_main).

startup_loads reads each wherever a command sets one, whatever program it runs, so more is read
than runs (-S, -E, -f, --posix and a shell given no -i are not looked for). A value the gate
cannot work out is refused as unread where the command is typed (startup_unread).

WHAT THAT DOES NOT COVER. A value the session's own environment holds and the command did not
set. A HOME or NODE_PATH the gate cannot work out, and a PYTHONPATH or ENV it cannot work out in
front of any program but python3 or a shell, which pass as before. PYTHONHOME, PYTHONBREAKPOINT
(python3 imports the module it names where the script calls breakpoint()), PERL5DB (code perl -d
runs), a module of ruby's or perl's own shadowed through RUBYLIB or PERL5LIB other than
rubygems.rb and perl5db.pl, DYLD_INSERT_LIBRARIES, and bash functions handed in through the
environment. LUA_INIT and TCL_LIBRARY (lua 5.5 and tclsh ran the file each names): the gate reads
no lua or tcl program at all, so `lua posts.lua` passes with or without them.

slack_drafts_only_gate.py loads this file and gives its Judge the class make() returns as a base, as
it does lib/program-runs.py's, so the methods use the Judge's own readers (line, script, sh_value,
sh_word_end, sh_cwd, is_file, content, made, shell, unfollow).
"""
import glob
import os
import re

# One PHP token the include reading must step over, or a name: a string (an unclosed one runs to the
# end), a comment (a // or # one ends at a line break or at ?>, which also ends the code), the tag
# that ends the code, the start of a heredoc, or a word.
PHP_LEX = re.compile(r"""'(?:[^'\\]|\\.)*'?|"(?:[^"\\]|\\.)*"?|/\*.*?(?:\*/|\Z)|(?://|\#(?!\[))(?:[^\n?]|\?(?!>))*"""
                     r"""|\?>|<<<|([A-Za-z_]\w*)""", re.S)
PHP_WORD = re.compile(r"([A-Za-z_]\w*)")
# What follows <<<: the label of a heredoc, or a nowdoc's in single quotes, ending its line.
PHP_DOC_LABEL = re.compile(r"""[ \t]*(["']?)([A-Za-z_]\w*)\1[ \t]*\r?\n""")
PHP_INCLUDES = frozenset({"include", "include_once", "require", "require_once"})
# The one shape of include whose path is certain: a single string with no variable and no escape in
# it (a single quoted one may hold \' and \\), bracketed or not, ending the statement or expression.
_PHP_STRING = r"""'(?:[^'\\]|\\['\\])*'|"[^"\\$]*\""""
PHP_LITERAL = re.compile(rf"""\s*(?:\(\s*({_PHP_STRING})\s*\)|({_PHP_STRING}))\s*(?=[;),]|\?>|\Z)""")
PHP_OPEN = re.compile(r"<\?(?:php\b|=)?", re.I)
PHP_CODE_OPTIONS = ("-r", "-B", "-R", "-E")
PHP_BANG = re.compile(r"^#!.*\bphp\b")
# What a name given to perl's <> must look like for the two argument open to run it as a command.
PERL_PIPE = re.compile(r"^\s*\||\|\s*$")
# perl code that reads the names it is handed through <>'s two argument open: <> (never <<>>, whose
# three argument open runs nothing), <ARGV>, readline(ARGV), eof() and the like; $ARGV and @ARGV are
# only the name and the list (#2912).
PERL_READS_HANDED = re.compile(r"(?<!<)<\s*(?:ARGV\s*)?>(?!>)|(?<![$@\w])ARGV\b|\beof\s*\(\s*\)")
# A brace expansion bash makes of an unquoted word, {a,b} or {1..3}, which hands perl names the gate
# does not see written (#2912).
PERL_BRACE = re.compile(r"\{[^{}\s]*(?:,|\.\.)[^{}\s]*\}")
# A variable's own value, which a command adding to it keeps (NODE_OPTIONS="$NODE_OPTIONS ...").
NODE_SELF = re.compile(r"\$\{NODE_OPTIONS\}|\$NODE_OPTIONS(?!\w)")
# One assignment of NODE_OPTIONS among a command's leading assignments.
NODE_ASSIGN = re.compile(r"(?<![\w$])NODE_OPTIONS\+?=")
# Each word of NODE_OPTIONS, which node splits at white space outside double quotes.
NODE_WORD = re.compile(r'"([^"]*)"|(\S+)')
# The variables whose value has an interpreter load a file as it starts (startup_loads,
# claude-config#3675), each with how a refusal names the file it loads ("the file F, which ...") and
# how one names a value the gate cannot work out ("it sets V, ...").
STARTUP_WHAT = {
    "PYTHONPATH": ("which PYTHONPATH has python3 import as it starts",
                   "whose folders python3 imports sitecustomize and usercustomize from as it starts"),
    "PYTHONUSERBASE": ("which PYTHONUSERBASE has python3 run as it starts",
                       "whose user site folder python3 runs usercustomize and each .pth file from as it starts"),
    "RUBYOPT": ("which RUBYOPT has ruby load before the script it is given",
                "whose libraries ruby loads before the script it is given"),
    "RUBYLIB": ("which RUBYLIB has ruby load as it starts, in place of its own",
                "whose folders ruby loads rubygems.rb and the libraries RUBYOPT names from"),
    "PERL5OPT": ("which PERL5OPT has perl load before the script it is given",
                 "whose modules perl loads before the script it is given"),
    "PERL5LIB": ("which PERL5LIB has perl load when it is given -d, in place of its own",
                 "whose folders perl loads its debugger and the modules PERL5OPT names from"),
    "BASH_ENV": ("which BASH_ENV has bash run before the script it is given",
                 "the file bash runs before the script it is given"),
    "ENV": ("which ENV has sh, dash and ksh run first when they are given -i",
            "the file sh, dash and ksh run first when they are given -i"),
    "ZDOTDIR": ("which ZDOTDIR has zsh run as it starts", "the folder zsh runs its start up files from"),
    "HOME": ("which HOME has a shell or python3 run as it starts",
             "the folder a shell and python3 run their start up files from"),
    "BUN_OPTIONS": ("which BUN_OPTIONS has bun load before the script it is given",
                    "whose files bun loads before the script it is given"),
    "NODE_REPL_EXTERNAL_MODULE": ("which NODE_REPL_EXTERNAL_MODULE has node run in place of its own prompt",
                                  "the file node runs in place of its own prompt"),
    "NODE_PATH": ("which NODE_PATH has node look in", "the folders node looks in for a main file handed after --"),
}
# One assignment of any of them among a command's words, the builtins whose words are assignments,
# and the quick test for a text that may hold one.
STARTUP_ASSIGN = re.compile(r"(%s)\+?=(.*)\Z" % "|".join(STARTUP_WHAT), re.S)
STARTUP_QUICK = re.compile(r"(?:%s)\+?=" % "|".join(STARTUP_WHAT))
STARTUP_SETTERS = frozenset({"export", "declare", "typeset", "local", "readonly"})
# The ones whose value is a list, where the variable's own value inside it is the session's.
STARTUP_LISTS = frozenset({"PYTHONPATH", "RUBYLIB", "PERL5LIB", "NODE_PATH", "RUBYOPT", "PERL5OPT", "BUN_OPTIONS"})
# The ones a value the gate cannot work out is refused for where the command is typed
# (startup_unread): PYTHONPATH and ENV only in front of the interpreter itself, HOME and NODE_PATH
# never.
STARTUP_STRICT = frozenset(STARTUP_WHAT) - {"HOME", "NODE_PATH"}
STARTUP_FILLS = re.compile(r"[$`]")
# The ones whose value is one file, with the shell that runs it or its language (the Judge's
# script()).
STARTUP_FILES = {"BASH_ENV": ("bash", None), "ENV": ("sh", None), "NODE_REPL_EXTERNAL_MODULE": (False, "js")}
# The files of fixed names an interpreter loads from a folder one of them names, each with the
# shell that runs it or its language. Measured 2026-11-25 with stand in files that only wrote a
# marker: python3 3.14.4 and 3.9.6 imported sitecustomize and usercustomize, as a module or a
# package, from any PYTHONPATH entry; ruby 2.6.10 loaded rubygems.rb from a RUBYLIB folder in place
# of its own; perl 5.34.1 given -d loaded perl5db.pl from a PERL5LIB folder in place of its own;
# zsh 5.9 ran .zshenv from ZDOTDIR, or from HOME with no ZDOTDIR, and .zprofile, .zshrc and .zlogin
# given -l or -i; bash 3.2.57 ran .bashrc given -i and .bash_profile given -l; sh, dash and ksh ran
# .profile given -l, and ksh .kshrc given -i.
STARTUP_CUSTOMIZE = ("sitecustomize.py", "sitecustomize/__init__.py", "usercustomize.py", "usercustomize/__init__.py")
_ZSH_FILES = tuple((name, "zsh", None) for name in (".zshenv", ".zprofile", ".zshrc", ".zlogin"))
STARTUP_FOLDER_FILES = {
    "PYTHONPATH": tuple((name, False, "py") for name in STARTUP_CUSTOMIZE),
    "RUBYLIB": (("rubygems.rb", False, None),),
    "PERL5LIB": (("perl5db.pl", False, None),),
    "ZDOTDIR": _ZSH_FILES,
    "HOME": _ZSH_FILES + ((".bashrc", "bash", None), (".bash_profile", "bash", None), (".bash_login", "bash", None),
                          (".profile", "sh", None), (".kshrc", "ksh", None)),
}
# Where the Python user site folder is under a folder one of them names, as a pattern: python3
# ran usercustomize and each .pth file's import lines from PYTHONUSERBASE's
# lib/python/site-packages, and 3.14.4 from HOME's Library/Python/3.14/lib/python/site-packages
# (measured 2026-11-25; the .local form is the one Python uses off macOS).
STARTUP_USER_SITES = {
    "PYTHONUSERBASE": (os.path.join("lib", "python*", "site-packages"),),
    "HOME": (os.path.join("Library", "Python", "*", "lib", "python", "site-packages"),
             os.path.join(".local", "lib", "python*", "site-packages")),
}
# An option that has a program given code go on to run its input as code once that code ends
# (input_after_code, claude-config#3600), by the program's name: the words that are the option for
# node, and for perl a run of letters holding d before any letter that takes the rest of its word
# (-d, -de, -wd, -d:Trace; never -Mdiagnostics, whose d is part of -M's value).
INPUT_AFTER_CODE = {
    "node": re.compile(r"-i|--interactive"),
    "nodejs": re.compile(r"-i|--interactive"),
    "perl": re.compile(r"-[^-CDEFIMVeimx\W]*d.*", re.S),
}
# The shells that refuse to run a file with a NUL in its first line ("cannot execute binary file",
# measured 2026-11-14 with /bin/bash 3.2, /bin/sh, which runs bash, and /bin/ksh). zsh 5.9 and
# /bin/dash run it. A file run by its path with no #! is refused by the kernel and then by bash, zsh
# and dash alike ("exec format error"), so it is read as bash's.
NUL_REFUSERS = frozenset({"bash", "ksh"})


def make(shell_bang, assign, marker, unknown_dir, max_depth, runs_refused):
    """The base class for the gate's Judge (module docstring). shell_bang is its SHELL_BANG, assign its
    CURL_ASSIGN (an assignment at a command's start, past export, env and the like), marker its
    MARKER, unknown_dir its SH_UNKNOWN_DIR, max_depth its MAX_DEPTH and runs_refused its
    unworked_paths_refused, the #2683 switch."""

    class CodeLoaders:
        # ---- PHP includes (#2978) -----------------------------------------------------------------

        @staticmethod
        def php_codes(words):
            """The code each of php's code options is given (-r, -B, -R and -E, separate or glued), in
            the order written: php runs -B's before the input, -R's for each line and -E's after."""
            out, k = [], 1
            while k < len(words):
                w = words[k]
                if w in PHP_CODE_OPTIONS and k + 1 < len(words):
                    out.append(words[k + 1])
                    k += 2
                    continue
                if w[:2] in PHP_CODE_OPTIONS and len(w) > 2:
                    out.append(w[2:])
                k += 1
            return out

        @staticmethod
        def php_lang(first):
            """"php" for a script whose #! names php, else None."""
            return "php" if PHP_BANG.match(first) else None

        def php_includes(self, text, cur_dir, root, tagged):
            """(the include as written, the files it runs, False where it names a file that is not
            there, or "path" where its path is not a literal) for each include in PHP code. tagged is
            True for a file, whose code is only what is inside <?php ... ?>, the rest page text it
            prints; code given inline is code throughout.

            PHP looks for a path with no folder in it on its include path ("." first, the folder it
            runs in, root) and then in the including file's own folder (cur_dir); one starting ./ or
            ../ is from the folder it runs in alone; a path from / is itself. Each place it may be is
            followed, so a file found in either is read. An include whose path is assembled when it
            runs (a variable, a concatenation, __DIR__, an escape in a double quoted string) cannot be
            followed, and is refused rather than passed (the issue's decision). A word include inside
            a string or a comment is not one, nor is a variable, method or namespaced name spelt so."""
            code, i, n, heredoc = not tagged, 0, len(text), False
            doc_end = n
            while i < n:
                if not code:
                    m = PHP_OPEN.search(text, i)
                    if not m:
                        return
                    code, i = True, m.end()
                    continue
                # A heredoc's text can run code ({${...}}), so up to its closing label every word in
                # it is a token, no quote starts a string that could hide an include and no ?> ends
                # the code (an apostrophe in its text would otherwise swallow the rest); past the
                # label the code is read as before. One whose end cannot be found reads so to the end.
                m = PHP_WORD.search(text, i, doc_end) if heredoc else PHP_LEX.search(text, i)
                if heredoc and not m:
                    heredoc, i, doc_end = False, doc_end, n
                    continue
                if not m:
                    return
                i = m.end()
                tok = m.group(0)
                if tok == "<<<":
                    label = PHP_DOC_LABEL.match(text, i)
                    close = label and re.compile(r"^[ \t]*%s(?!\w)" % label.group(2), re.M).search(text, label.end())
                    if close and label.group(1) == "'":
                        i = close.end()  # a nowdoc's text is never code
                        continue
                    heredoc, doc_end = True, close.end() if close else n
                    continue
                if tok == "?>" or (tok[:1] in "/#" and not tok.startswith("/*") and text.startswith("?>", i)):
                    if not heredoc:
                        code = False
                    continue
                word = m.group(1)
                if not word or word.lower() not in PHP_INCLUDES:
                    continue
                before = text[max(0, m.start() - 2):m.start()]
                if before.endswith(("$", "\\")) or before in ("->", "::"):
                    continue  # a variable, a namespaced name or a method, not the statement
                lit = PHP_LITERAL.match(text, i)
                if not lit:
                    end = text.find(";", i)
                    yield f"{word}{text[i:end if end >= 0 else n].rstrip()}", "path"
                    continue
                raw = lit.group(1) or lit.group(2)
                path = raw[1:-1]
                if raw[0] == "'":
                    path = path.replace("\\'", "'").replace("\\\\", "\\")
                yield f"{word} {raw}", self.php_places(path, cur_dir, root)

        def php_places(self, path, cur_dir, root):
            """The files an include of path may run, by their real paths, or False where it is in
            none of the places PHP looks (php_includes)."""
            if path.startswith("/"):
                places = [path]
            elif path.startswith(("./", "../")) or path in (".", ".."):
                places = [os.path.join(root, path)]
            else:
                places = [os.path.join(root, path), os.path.join(cur_dir, path)]
            found = []
            for place in places:
                if self.is_file(place) and os.path.realpath(place) not in found:
                    found.append(os.path.realpath(place))
            return found or False

        # ---- NODE_OPTIONS (#2912) ------------------------------------------------------------------

        def node_options(self, text, d, depth):
            """The reason a command that sets NODE_OPTIONS loads a module that posts, or None. Every
            word of the value that is not an option, and the value glued to any option with =, is read
            as a module node may load (--require, --import, --loader and whatever loader node adds
            next), as JavaScript; a word naming no file is a package or a builtin, which is not ours to
            read. The session's own value, kept by `NODE_OPTIONS="$NODE_OPTIONS ..."`, loads the same
            for every node call, which the gate does not read either. A value the gate cannot work out
            is refused as not checked. Read wherever the command sets it, its own prefix, export, env
            or a plain assignment, whatever program the command runs."""
            if "NODE_OPTIONS" not in text:
                return None
            # Every assignment is read: the shell and env keep the last of `env NODE_OPTIONS=a
            # NODE_OPTIONS=b node`, which one search reached only through the pattern's greedy repeat
            # (measured 2026-11-14), so reading each one stops that depending on the pattern's shape,
            # and an earlier one node never gets costs only a refusal.
            # The assignment pattern ends at one NODE_OPTIONS= of a command's prefix, its assignments
            # before it included, so every NODE_OPTIONS= in what it matched is one of them.
            starts = [k.end() for m in re.finditer(assign % r"NODE_OPTIONS\+?", text, re.M)
                      for k in NODE_ASSIGN.finditer(text, m.start(), m.end())]
            for at in starts:
                raw = NODE_SELF.sub("", text[at:self.sh_word_end(text, at)])
                value = self.sh_value(raw, d) if raw else ""
                if value is None:
                    return self.unfollow("it sets NODE_OPTIONS, the modules node loads before any code it runs, to "
                                         "a value the gate cannot work out, so it cannot see what that loads")
                for quoted, plain in NODE_WORD.findall(value):
                    w = quoted or plain
                    if w.startswith("-"):
                        w = w.partition("=")[2]
                    if not w:
                        continue
                    names = len(self.held_names())
                    reason = self.script(w, d, depth, False, "js", f"the module {w}, which NODE_OPTIONS has node load,")
                    if reason:
                        return reason
                    if len(self.held_names()) > names:
                        # It shares a process with whatever node runs, which can read what it leaves on
                        # the global object, and that code is judged apart from it, so a name it holds
                        # only as data is refused as before (#2913, lessons review at 73967ea).
                        where, name = self.held_names()[names]
                        return (f"{where.rstrip(',')}, which posts to Slack (it names {name}, held there only as data, but "
                                "NODE_OPTIONS has node load it beside code judged apart from it, which can send it)")
            return None

        # ---- Files an interpreter loads as it starts, by a variable the command sets (#3675) -------

        def startup_kept(self):
            """The values of the start up variables set so far in this call by export, by a
            declaration or by a plain assignment, by variable, in the order they were read: a
            command from there on runs with them (startup_loads)."""
            got = self.__dict__.get("_startup_kept")
            if got is None:
                got = self.__dict__["_startup_kept"] = {}
            return got

        def startup_loads(self, text, d, depth):
            """The reason a command that sets one of the start up variables (STARTUP_WHAT) has the
            interpreter it starts load a file that posts, or None (module docstring,
            claude-config#3675). Read wherever the command sets one, in its own prefix, by
            export, env and their kin, or as a plain assignment, and whatever program it runs,
            since any of them can start the interpreter (as node_options reads NODE_OPTIONS).
            The assignments are the command's own, as the shared reader gives them, so the same
            text inside a quoted word of another command is none.

            What a value names by itself is read where it is set (startup_set). What depends on
            two settings, or on the program's own words, is read by each command that runs a
            program, with the values its own prefix gives and those set before it in this call
            (startup_kept): the library RUBYOPT names is found through RUBYLIB or an -I, the
            module PERL5OPT names through PERL5LIB or an -I, and the main file node is handed
            after -- through NODE_PATH and HOME (startup_options, node_dash_main).

            A value holding something the shell fills in is worked out where the gate can, the
            variable's own value left out of a list (it is the session's, which a command
            adding to it keeps). One the gate cannot work out is refused as unread where the
            command is typed, and left as it was in a script on disk: always for the variables
            that exist to load code, and for the ones set for many other reasons only in front
            of the interpreter itself (STARTUP_STRICT, startup_unread). The session's own
            value, which the command did not set, is not read."""
            kept = self.__dict__.get("_startup_kept")
            dashed = "--" in text and "node" in text
            if not kept and not dashed and not STARTUP_QUICK.search(text):
                return None
            rest, assigns = self.rest_of(text)
            words = self.words_of(rest)
            runs = bool(words) and words[0] not in STARTUP_SETTERS
            # The reader gives each leading assignment on a line of its own, its quotes taken off.
            pairs = [a for a in assigns.split("\n") if a] + ([] if runs or not words else words[1:])
            own = {}
            for m in filter(None, map(STARTUP_ASSIGN.match, pairs)):
                var, value = m.group(1), m.group(2)
                if var in STARTUP_LISTS:
                    value = re.sub(r"\$\{%s\}|\$%s(?!\w)" % (var, var), "", value)
                if STARTUP_FILLS.search(value):
                    value = self.sh_value('"%s"' % value.replace("\\", "\\\\").replace('"', '\\"'), d)
                if value is None:
                    reason = self.startup_unread(var, words)
                    if reason:
                        return reason
                else:
                    reason = self.startup_set(var, value, d, depth)
                    if reason:
                        return reason
                (own if runs else self.startup_kept()).setdefault(var, []).append(value)
            if not runs:
                return None
            kept = self.__dict__.get("_startup_kept") or {}

            def values(var):
                return own.get(var, []) + kept.get(var, [])

            return self.startup_options(words, values, d, depth) or (
                self.node_dash_main(words, values, d, depth) if dashed else None)

        def startup_unread(self, var, words):
            """The refusal of a start up variable set to a value the gate cannot work out, where
            the command is typed, or None: in a script on disk, and for a variable set for many
            other reasons anywhere but in front of the interpreter that reads it (PYTHONPATH in
            front of python3, ENV in front of a shell). HOME and NODE_PATH are never refused
            here: of the 27 recorded commands that set HOME, 16 held something the shell fills
            in (counted 2026-11-25 over 61,293 recorded commands)."""
            name = os.path.basename(words[0]) if words else ""
            if var == "PYTHONPATH" and not self.py_cmd.get("interp"):
                return None
            if var == "ENV" and self.family(name) != "shell":
                return None
            if var not in STARTUP_STRICT:
                return None
            return self.unread_typed(
                f"it sets {var}, {STARTUP_WHAT[var][1]}, to a value the gate cannot work out, so what "
                "that loads is not read and whether it posts cannot be checked (claude-config#3675). Write the "
                f"value of {var} out in the command")

        def startup_set(self, var, value, d, depth):
            """The reason a file one start up variable's value names by itself posts, or None:
            the file BASH_ENV, ENV or NODE_REPL_EXTERNAL_MODULE names, each file BUN_OPTIONS
            names, and the files of fixed names in the folders the others name
            (STARTUP_FOLDER_FILES), each read as the interpreter that loads it reads it."""
            if not value:
                return None
            if var == "HOME" and os.path.realpath(self.resolve(value, d)) == os.path.realpath(os.environ.get("HOME") or "/"):
                return None  # the session's own, which loads the same with nothing set
            what = STARTUP_WHAT[var][0] + ","
            if var in STARTUP_FILES:
                shell_hint, lang = STARTUP_FILES[var]
                return self.script(value, d, depth, shell_hint, lang, f"the file {value}, {what}")
            if var == "BUN_OPTIONS":
                for quoted, plain in NODE_WORD.findall(value):
                    w = quoted or plain
                    if w.startswith("-"):
                        w = w.partition("=")[2]
                    reason = w and self.script(w, d, depth, False, "js", f"the file {w}, {what}")
                    if reason:
                        return reason
                return None
            folders = value.split(os.pathsep) if var in STARTUP_LISTS else [value]
            for folder in filter(None, folders):
                for name, shell_hint, lang in STARTUP_FOLDER_FILES.get(var, ()):
                    path = os.path.join(folder, name)
                    reason = self.script(path, d, depth, shell_hint, lang, f"the file {path}, {what}")
                    if reason:
                        return reason
                for pattern in STARTUP_USER_SITES.get(var, ()):
                    for site in sorted(glob.glob(os.path.join(glob.escape(self.resolve(folder, d)), pattern))):
                        reason = self.startup_user_site(site, what, d, depth)
                        if reason:
                            return reason
            return None

        def startup_user_site(self, site, what, d, depth):
            """The reason a Python user site folder holds something python3 runs as it starts
            that posts, or None: usercustomize or sitecustomize, as a module or a package, and
            the import lines of each .pth file, which site.py runs (measured 2026-11-25)."""
            for name in STARTUP_CUSTOMIZE:
                path = os.path.join(site, name)
                reason = self.script(path, d, depth, False, "py", f"the file {path}, {what}")
                if reason:
                    return reason
            for pth in sorted(glob.glob(os.path.join(glob.escape(site), "*.pth"))):
                try:
                    lines = self.content(pth).decode("utf-8", "replace").split("\n")
                except OSError:
                    continue
                body = "\n".join(line for line in lines if line.startswith(("import ", "import\t")))
                if not body:
                    continue
                label = f"the file {pth}, whose import lines python3 runs as it starts and {what}"
                hit = marker.search(body)
                if hit:
                    return f"{label} posts to Slack (it names {hit.group(0)})"
                reason = self.imports(label, pth, site, body, "py")
                if reason:
                    return reason
            return None

        def startup_options(self, words, values, d, depth):
            """The reason a library RUBYOPT names or a module PERL5OPT names posts, or None, for
            one command that runs a program: values(var) are the values of a variable the
            command runs with. Each is looked for where ruby or perl looks first: a path as it
            is written (ruby's -r./x), else the folders an -I inside the value names, those of
            RUBYLIB or PERL5LIB, and those an -I among the program's own words names. One found
            in none of those is ruby's or perl's own or an installed one, which is not ours to
            read. perl's -d has it load perl5db.pl from the same folders, and -d:Name
            Devel/Name.pm."""
            name = os.path.basename(words[0])
            for var, prog, libs in (("RUBYOPT", "ruby", "RUBYLIB"), ("PERL5OPT", "perl", "PERL5LIB")):
                wanted, folders = [], []
                for value in filter(None, values(var)):
                    got = self.ruby_opt_names(value) if prog == "ruby" else self.perl_opt_names(value)
                    wanted += got[0]
                    folders += got[1]
                if not wanted:
                    continue
                for value in filter(None, values(libs)):
                    folders += [f for f in value.split(os.pathsep) if f]
                if name == prog:
                    for k, w in enumerate(words[1:], 1):
                        if w == "-I" and k + 1 < len(words):
                            folders.append(words[k + 1])
                        elif w.startswith("-I") and len(w) > 2:
                            folders.append(w[2:])
                if any(STARTUP_FILLS.search(f) for f in folders):
                    reason = self.unread_typed(
                        f"it sets {var}, {STARTUP_WHAT[var][1]}, and names a folder to look in that the "
                        "gate cannot work out, so what that loads is not read and whether it posts cannot be "
                        "checked (claude-config#3675). Write the folder out in the command")
                    if reason:
                        return reason
                what = STARTUP_WHAT[var][0] + ","
                for lib in wanted:
                    if prog == "ruby" and lib.startswith(("./", "../", "/", "~")):
                        tries = [lib, lib + ".rb"]
                    else:
                        tries = [os.path.join(f, t) for f in folders for t in ((lib, lib + ".rb") if prog == "ruby" else (lib,))]
                    for path in tries:
                        reason = self.script(path, d, depth, False, None, f"the file {path}, {what}")
                        if reason:
                            return reason
            return None

        @staticmethod
        def ruby_opt_names(value):
            """(the libraries, the folders) a RUBYOPT value names: -rNAME or -r NAME, and -IDIR
            or -I DIR, which ruby reads from it as from its command line (measured 2026-11-25,
            ruby 2.6.10)."""
            libs, folders, toks = [], [], value.split()
            k = 0
            while k < len(toks):
                t = toks[k]
                for letter, into in (("-r", libs), ("-I", folders)):
                    if t == letter and k + 1 < len(toks):
                        k += 1
                        into.append(toks[k])
                    elif t.startswith(letter) and len(t) > 2:
                        into.append(t[2:])
                k += 1
            return libs, folders

        @staticmethod
        def perl_opt_names(value):
            """(the files, the folders) a PERL5OPT value names: -MName and -mName (Name.pm, with
            :: or ' for a folder, past a leading - and before any =arguments), -d:Name
            (Devel/Name.pm), -d alone (perl5db.pl), and -IDIR. A letter that takes no value may
            stand in front in the same word (-wMName); perl takes no space after -M (measured
            2026-11-25, perl 5.34.1: "Missing argument to -M")."""
            files, folders = [], []
            for t in value.split():
                if not t.startswith("-"):
                    continue
                for k in range(1, len(t)):
                    c, after = t[k], t[k + 1:]
                    if c in "Mm":
                        mod = re.split(r"[=\s]", after.lstrip("-"), 1)[0]
                        if mod:
                            files.append(re.sub(r"::|'", "/", mod) + ".pm")
                        break
                    if c == "I":
                        if after:
                            folders.append(after)
                        break
                    if c == "d":
                        mod = re.match(r"t?:([\w:']+)", after)
                        files.append("Devel/" + re.sub(r"::|'", "/", mod.group(1)) + ".pm" if mod else "perl5db.pl")
                        break
                    if c in "CDFilx0":
                        break  # the rest of the word is this letter's value
            return files, folders

        def node_dash_main(self, words, values, d, depth):
            """The reason the main file node finds for a name starting with a dash, handed after
            --, posts, or None (claude-config#3675). Measured 2026-11-25 with node 22.22.2 and
            stand in files that only wrote a marker: `node -- -x.js` ran no -x.js in the folder
            it ran in and none under node_modules there or above ("Cannot find module
            '-x.js'"). A main file whose name starts with a dash is not made a path, so node
            looks for it only where it looks for a package given no folder to start from: each
            folder NODE_PATH names (the command's, else the session's), then .node_modules and
            .node_libraries in HOME, then lib/node beside the folder its own program is in; as
            a file, with an extension added, or as a folder by its package.json or index. Each
            of those found is read as JavaScript. The gate's reading of a file of that name in
            the folder itself (dash_named in lib/program-runs.py, #3600) is left as it is,
            which refuses a file node would not run and never passes one it would."""
            if len(words) < 3 or os.path.basename(words[0]) not in ("node", "nodejs") or "--" not in words:
                return None
            name = self.operands(words)[0]
            if not name or name == "-" or not name.startswith("-") or words[words.index("--") + 1:][:1] != [name]:
                return None
            here = os.path.abspath(d or os.getcwd())
            paths, homes = values("NODE_PATH"), values("HOME")
            if any(v is None for v in paths + homes):
                reason = self.unread_typed(
                    f"node looks for {name} in the folders NODE_PATH names and under HOME, and this command sets "
                    "one of those to a value the gate cannot work out, so the file node runs is not read and "
                    "whether it posts cannot be checked (claude-config#3675). Write the value out in the command")
                if reason:
                    return reason
            # Every value set is read, the command's own and those set before it: more than the
            # one node gets, which costs only a refusal. With none set, the session's.
            paths = [v for v in paths if v] or [os.environ.get("NODE_PATH") or ""]
            homes = [v for v in homes if v] or [os.environ.get("HOME") or ""]
            places = [(os.path.join(here, p), "a folder NODE_PATH names")
                      for path in paths for p in path.split(os.pathsep) if p]
            for home in filter(None, homes):
                home = os.path.join(here, home)
                places += [(os.path.join(home, ".node_modules"), ".node_modules in HOME"),
                           (os.path.join(home, ".node_libraries"), ".node_libraries in HOME")]
            for folder in os.environ.get("PATH", "").split(os.pathsep):
                program = os.path.join(folder, os.path.basename(words[0]))
                if folder and os.path.isfile(program):
                    prefix = os.path.dirname(os.path.dirname(os.path.realpath(program)))
                    places.append((os.path.join(prefix, "lib", "node"), "lib/node beside the folder node itself is in"))
                    break
            for folder, place in places:
                found = self.resolve_import("./" + name, folder)
                reason = found and self.script(
                    found, d, depth, False, "js",
                    f"the file {found}, which node runs for {name} after -- (it looks in {place}, never in the "
                    "folder it runs in),")
                if reason:
                    return reason
            return None

        # ---- Input run after the code a program was given (#3600) ----------------------------------

        @staticmethod
        def input_after_code(name, options, read):
            """The reason a program given code by an option goes on to run input that posts, or
            None (claude-config#3600). Measured 2026-11-25 with stand in scripts that only wrote
            a marker: `node -i -e 1 < post.js` (node 22.22.2) ran the lines of post.js, with -i
            or --interactive before the code or after it, and with -p; `perl -d -e 1 < post.pl`
            and `perl -de 1` (perl 5.34.1) ran those of post.pl, the debugger reading its
            commands from the input where there is no terminal. Without the option neither ran
            its input, and the gate read none of it for either. ruby (2.6.10) has no such
            option: `ruby -e 1 < post.rb` and `ruby -e 1 - < post.rb` ran nothing fed.

            options are the program's words but the code itself, and read the gate's reading of
            what the command is fed on its input as code the program runs (its input_script).
            A word after -- is the code's argument and is not an option."""
            asks = INPUT_AFTER_CODE.get(name)
            if asks is None:
                return None
            for w in options:
                if w == "--":
                    break
                if asks.fullmatch(w):
                    reason = read()
                    return reason and (f"{name} is given {w}, so once the code it was given ends it goes on to "
                                       f"run what it reads on its input (claude-config#3600): {reason}")
            return None

        # ---- A name perl's <> runs as a command (#2912) --------------------------------------------

        def shell_names(self, word, d):
            """The names the shell hands a program for word: each name a glob in it matches on disk or
            in a file written earlier in this command, in the folder it is read from, or the word
            itself where it holds no glob or matches nothing (bash hands an unmatched glob on as
            written)."""
            if not glob.has_magic(word):
                return [word]
            base = d or os.getcwd()
            names = []
            for found in glob.glob(os.path.join(glob.escape(base), word)):  # a [ or * in the folder is literal
                if os.path.isabs(word):
                    names.append(found)
                else:
                    rel = os.path.relpath(found, base)
                    names.append("./" + rel if word.startswith("./") else rel)
            folder = os.path.realpath(os.path.join(base, os.path.dirname(word)))
            pattern = _glob_regex(os.path.basename(word))
            for made in self.made:
                if os.path.dirname(made) == folder and re.fullmatch(pattern, os.path.basename(made)):
                    names.append(os.path.join(os.path.dirname(word), os.path.basename(made)))
            return names or [word]

        def perl_opens_handed(self, words, skip):
            """Whether perl opens the names it is handed with <>'s two argument open: a switch -n, -p,
            -i, -a or -F (alone or in a cluster, before any letter that takes the rest of it), code that
            reads <>, <ARGV>, readline(ARGV) or eof() (never <<>>, whose open runs nothing), or code
            the gate is not given here (a script file, or its input), which may do either."""
            if not skip:
                return True
            for w in words[1:]:
                if w in skip:
                    break  # the code: what follows is handed to it
                if not w.startswith("-") or w.startswith("--"):
                    continue
                i = 1
                while i < len(w):
                    ch = w[i]
                    if ch in "npiaF":
                        return True  # -a implies -n, and -F implies -a (perl 5.20 on)
                    if ch == "0":
                        # -0 takes only octal digits, or x and hex ones, and the cluster goes on past
                        # them: -0777ne is -0777 then -n (lessons review at 1b81a0c).
                        i += 1
                        if i < len(w) and w[i] in "xX":
                            i += 1
                            while i < len(w) and w[i] in "0123456789abcdefABCDEF":
                                i += 1
                        else:
                            while i < len(w) and w[i] in "01234567":
                                i += 1
                        continue
                    if ch in "eEMmIxdDC":
                        break  # takes the rest of the word as its value
                    i += 1
            return any(PERL_READS_HANDED.search(code) for code in skip)

        def perl_pipe_names(self, words, skip, d, depth, text=None):
            """The reason a name perl is handed, which its <> opens as a command (a name starting or
            ending in |, two argument open), runs a command that posts, or None. Each word but the
            switches and the code (skip), and each name a glob in one expands to, is looked at, and
            the command such a name holds is judged as a command line. Where perl opens what it is
            handed (perl_opens_handed), a word the gate cannot work out, built from a substitution,
            backquotes or a brace expansion, is refused, as the name it becomes cannot be seen (#2912,
            the lessons review of #3010 at 73967ea: `perl -ne print "$(printf 'bash post.sh|')"`
            passed); one built only from a variable it does not know is refused with the #2683 switch
            on, as a file run by such a path is. text is the command as written."""
            raws = self.raw_words(text) if text is not None else None
            if raws is not None and self.perl_opens_handed(words, skip):
                # A word whose only unknown is a variable names a file the gate cannot read, as
                # `bash "$X/a.sh"` runs one, so it is refused only with the #2683 switch on (runs_refused,
                # pinned off in the gate suite). One the command builds itself, by a substitution,
                # backquotes or a brace expansion, is refused whatever the switch says.
                def built_here(r):
                    return bool(re.search(r"\$\(|`", r) or
                                PERL_BRACE.search(re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", "", r)))
                if len(raws) != len(words):
                    built = [r for r in raws[1:] if re.search(r"[$`{]", r) and (runs_refused() or built_here(r))]
                    if built:
                        return self.unfollow(f"perl opens the names it is handed with <>, which runs one starting "
                                             f"or ending in | as a command, and is handed {built[0]}, whose name the "
                                             "gate cannot line up with what it reads")
                else:
                    for w, r in zip(words[1:], raws[1:]):
                        if w in skip or w.startswith("-"):
                            continue
                        why = None
                        if re.search(r"[$`]", r):
                            v, splits = self.sh_word(r, self.sh_cwd(d), self.sh_source_var, self.shell["script"], False)
                            if (v is None or splits) and (runs_refused() or built_here(r)):
                                why = "built from what the gate cannot work out"
                        if why is None and PERL_BRACE.search(re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", "", r)):
                            why = "a brace expansion"
                        if why:
                            return self.unfollow(f"perl opens the names it is handed with <>, which runs one starting or "
                                                 f"ending in | as a command, and is handed {r}, {why}, so the name it "
                                                 "opens cannot be seen")
            for w in words[1:]:
                if w in skip or w.startswith("-"):
                    continue
                for name in self.shell_names(w, d):
                    if not PERL_PIPE.search(name):
                        continue
                    cmd = name.strip().strip("|").strip()
                    if not cmd:
                        continue
                    if depth >= max_depth:
                        # A name can hold the command that names it ("perl -ne print *|", which *
                        # matches), so the reading stops where the gate's other nesting does.
                        return self.unfollow(f"perl's <> opens {name!r} as a command nested deeper than "
                                             "the gate reads")
                    try:
                        inner = self.line(cmd, d, depth + 1, cmd)
                    except self.sw.Unreadable:
                        inner = self.unfollow(f"perl's <> opens {name!r} as a command the gate cannot read")
                    if inner:
                        return f"perl's <> opens {name!r} as a command, and that command posts: {inner}"
            return None

        # ---- A file with a NUL in its first line (#2977) ------------------------------------------

        def reading_shell(self, shell_hint, sourced, first):
            """The shell that reads a script as commands, as a name, or None where it cannot be told: a
            sourced file is read by the shell reading the text that sources it, which for the command
            line itself is the session's own, perhaps zsh; a file a shell is handed by that shell;
            one run by its path by the shell its #! names, and with no #! by the kernel, which runs a
            file with a NUL in its first line nowhere (read as bash's). sh is the shell /bin/sh runs."""
            if sourced:
                name = self.shell.get("program")
            elif isinstance(shell_hint, str):
                name = shell_hint
            else:
                m = shell_bang.match(first)
                name = (m.group(1) or "") + "sh" if m else "bash"
            if name == "sh":
                for link in ("/private/var/select/sh", "/bin/sh"):
                    if os.path.islink(link):
                        return os.path.basename(os.path.realpath(link))
                return None
            return name

        def nul_reading(self, word, real, d, depth, label, prog, sourced):
            """script_body() for a shell script holding a NUL in its first line, read as prog reads it
            (reading_shell), or False where prog refuses to run it and #2892's reading stands. dash
            drops each NUL and runs the rest, so the file is read with them dropped. zsh keeps a NUL
            inside its word, and a program's name ends there, so the file is read with them dropped for
            a script it runs that posts, and otherwise refused as one whose commands cannot be worked
            out; so is a file whose shell cannot be told. bash sourcing it runs the text before its
            first NUL and ksh refuses it whole (measured 2026-11-14); both are read as bash is, the
            text before the first NUL read as commands and the whole still searched for an endpoint,
            which for ksh only refuses more."""
            if prog in NUL_REFUSERS and not sourced:
                return False
            data = self.content(real)
            text = data.split(b"\0", 1)[0] if prog in NUL_REFUSERS else data.replace(b"\0", b"")
            text = text.decode("utf-8", "replace")
            try:
                self.next_script, self.next_on_disk = word, True
                # Its $0, as any script's (script_body, #2913): the word that ran it, or for a file
                # that is sourced the script that ran. Left unset, a cd built from $0 was not followed,
                # and what the file sourced after it was read from another folder (claude-config#3020).
                self.next_zero = self.shell.get("zero") if sourced else word
                self.next_cwd_known = self.sh_cwd(d) != unknown_dir
                self.next_program = prog
                inner = self.line(text, d, depth + 1, text)
            except self.sw.Unreadable:
                inner = None
            if inner:
                return f"{label} runs a command that posts: {inner}"
            hit = marker.search(data.replace(b"\0", b"").decode("utf-8", "replace"))
            if hit:
                return f"{label} posts to Slack (it names {hit.group(0)})"
            if prog in NUL_REFUSERS or prog == "dash":
                return None
            shell = prog or "the shell running it, which may be the session's own zsh,"
            return self.unfollow(f"{label} holds a NUL byte in its first line, and {shell} runs it keeping the NUL "
                                 "inside a word, where it ends a program's name, so the commands it runs cannot be "
                                 "worked out (claude-config#2977)")

    return CodeLoaders


def _glob_regex(pattern):
    """A regular expression matching a name as the shell's glob pattern does: * any run, ? one
    character, [...] a set; a name starting with . is matched only by a pattern starting with one."""
    out, i = [], 0
    if not pattern.startswith("."):
        out.append(r"(?!\.)")
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            out.append(".*")
        elif c == "?":
            out.append(".")
        elif c == "[":
            j = pattern.find("]", i + 2)
            if j < 0:
                out.append(re.escape(c))
            else:
                body = pattern[i + 1:j]
                out.append("[" + ("^" + body[1:] if body[:1] in "!^" else body).replace("\\", "\\\\") + "]")
                i = j
        else:
            out.append(re.escape(c))
        i += 1
    return "".join(out)

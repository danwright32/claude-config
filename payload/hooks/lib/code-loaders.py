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
    shell expands named it. Each is now judged as a command line (perl_pipe_names).
  * A file with a NUL in its first line run by zsh or dash (#2977): bash, sh and ksh refuse to run
    it, so #2892 only searched it for an endpoint, but zsh and dash run it. It is now read as the
    shell running it reads it (nul_reading).

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
# A variable's own value, which a command adding to it keeps (NODE_OPTIONS="$NODE_OPTIONS ...").
NODE_SELF = re.compile(r"\$\{NODE_OPTIONS\}|\$NODE_OPTIONS(?!\w)")
# One assignment of NODE_OPTIONS among a command's leading assignments.
NODE_ASSIGN = re.compile(r"(?<![\w$])NODE_OPTIONS\+?=")
# Each word of NODE_OPTIONS, which node splits at white space outside double quotes.
NODE_WORD = re.compile(r'"([^"]*)"|(\S+)')
# The shells that refuse to run a file with a NUL in its first line ("cannot execute binary file",
# measured 2026-11-14 with /bin/bash 3.2, /bin/sh, which runs bash, and /bin/ksh). zsh 5.9 and
# /bin/dash run it. A file run by its path with no #! is refused by the kernel and then by bash, zsh
# and dash alike ("exec format error"), so it is read as bash's.
NUL_REFUSERS = frozenset({"bash", "ksh"})


def make(shell_bang, assign, marker, unknown_dir):
    """The base class for the gate's Judge (module docstring). shell_bang is its SHELL_BANG, assign its
    CURL_ASSIGN (an assignment at a command's start, past export, env and the like), marker its
    MARKER and unknown_dir its SH_UNKNOWN_DIR."""

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
            while i < n:
                if not code:
                    m = PHP_OPEN.search(text, i)
                    if not m:
                        return
                    code, i = True, m.end()
                    continue
                # Past a heredoc its text is not told from code: from there on every word is a
                # token, no quote starts a string that could hide an include, and no ?> ends the
                # code (an apostrophe in the heredoc's text would otherwise swallow the rest).
                m = (PHP_WORD if heredoc else PHP_LEX).search(text, i)
                if not m:
                    return
                i = m.end()
                tok = m.group(0)
                if tok == "<<<":
                    heredoc = True
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
                    reason = self.script(w, d, depth, False, "js", f"the module {w}, which NODE_OPTIONS has node load,")
                    if reason:
                        return reason
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

        def perl_pipe_names(self, words, skip, d, depth):
            """The reason a name perl is handed, which its <> opens as a command (a name starting or
            ending in |, two argument open), runs a command that posts, or None. Each word but the
            switches and the code (skip), and each name a glob in one expands to, is looked at, and
            the command such a name holds is judged as a command line."""
            for w in words[1:]:
                if w in skip or w.startswith("-"):
                    continue
                for name in self.shell_names(w, d):
                    if not PERL_PIPE.search(name):
                        continue
                    cmd = name.strip().strip("|").strip()
                    if not cmd:
                        continue
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

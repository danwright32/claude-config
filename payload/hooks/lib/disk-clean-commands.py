#!/usr/bin/env python3
"""disk-clean-commands.py: every command a shell script calls, read from its source (claude-config#1804).

    disk-clean-commands.py --core "<names>" --stubs "<names>" --seams "<VAR=stub ...>" \
        --roots "<dir per line>" -- <file>...

The static half of the disk-clean test harness (lib/disk-clean-harness.sh, dc_check_commands). A
test that only RUNS a script sees the commands on the paths it happened to take, so a branch no
fixture reaches could call anything; this reads every line instead, taken or not.

Prints one line per command call, tab separated: kind, name, file:line, detail. Kinds:
  builtin   a bash builtin or keyword
  function  a function defined in one of the files read
  core      on --core, a real tool the harness links in
  stub      on --stubs, a tool every harness instance replaces with a stub
  seam      a call through "$VAR" where VAR=stub is on --seams and that stub is on --stubs
  follow    a file sourced or run with bash, found by name in the caller's folder or --roots and read too
  fail      anything else, with the reason: not stubbed, called by its full path, through a variable
            that is no seam, a script that sets PATH, `command -p`, `env -i`, a shell reading code
            from standard input, a file it cannot find, and any file it cannot read as bash
Exit 0 when nothing failed, 1 when something did, 2 on a usage error.

Why not lib/shell-words.py: that reads ONE typed command line. Measured 2026-10-27 on
hooks/derived-data-sweep.sh, it reported `fi`, `}`, `*)` and `start_sweep()` as commands, because a
script's compound statements (case patterns, function bodies, heredocs) are not what it is for.

What it follows of bash: quotes ('', "", $''), backslashes, comments, line continuations, $( ),
backticks, <( ) and >( ), ${ } (skipped, its own $( ) read), $(( )) and (( )) (skipped), heredocs
(bodies skipped), case patterns, for and select word lists, [[ ]], function definitions in both
spellings, array assignments, redirections, and the commands that run another command: xargs, env,
command, exec, nohup, nice, time, builtin, find -exec, bash/sh -c, eval and trap. Not followed: a
$( ) inside $(( )), and the inside of sudo (a stub, so what it would run never runs).
"""

import bisect
import os
import re
import sys

BUILTINS = set("""
. : [ alias bg bind break builtin caller cd command compgen complete continue declare dirs disown
echo enable eval exec exit export false fc fg getopts hash help history jobs kill let local logout
popd printf pushd pwd read readonly return set shift shopt source suspend test times trap true type
typeset ulimit umask unalias unset wait
""".split())
RESERVED_START = {'!', '{', 'then', 'do', 'else', 'elif', 'if', 'while', 'until'}
RESERVED_CLOSE = {'}', 'fi', 'done'}
ASSIGN_RE = re.compile(r'^[A-Za-z_][A-Za-z_0-9]*(\[[^]]*\])?\+?=')
PATH_ASSIGN_RE = re.compile(r'^PATH\+?=')
VAR_CMD_RE = re.compile(r'^"?\$(\{)?([A-Za-z_][A-Za-z_0-9]*)(?(1)(:?[-=+?][^}]*)?\})"?$')
METACHARS = set(' \t\n;&|()<>')
REDIR_RE = re.compile(r'[0-9]*(<<<|<<-|<<|<>|<&|>&|>>|>\||<(?!\()|>(?!\())')
SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh'}
SHEBANG_SHELL_RE = re.compile(r'^#!\s*(\S*/)?(env\s+)?(ba|z|da|k)?sh(\s|$)')

MSG_PATH = 'called by its path, which no stub on PATH can stand in for'
MSG_VAR = 'called through a variable the harness does not point at a stub'
MSG_EXPANSION = 'a command name built from an expansion, which the check cannot resolve'
MSG_SETS_PATH = 'sets PATH, which would reach real tools around every stub'
MSG_COMMAND_P = 'command -p searches the system default PATH around every stub'
MSG_ENV_I = 'env -i clears PATH, so the command it runs is found on the system default PATH'
MSG_STDIN = 'a shell reading code from standard input, which the check cannot read'
MSG_NOT_FOUND = 'runs or sources a file the check cannot find, so its commands cannot be listed'
MSG_UNSTUBBED = 'neither stubbed nor a core tool'


class ParseError(Exception):
    def __init__(self, pos, msg):
        super().__init__(msg)
        self.pos = pos


class Tok:
    __slots__ = ('kind', 'text', 'pos', 'end')

    def __init__(self, kind, text, pos, end):
        self.kind, self.text, self.pos, self.end = kind, text, pos, end


def dequote(raw):
    """One layer of shell quoting removed; expansions are left as written."""
    out, i, n = [], 0, len(raw)
    while i < n:
        c = raw[i]
        if c == '\\' and i + 1 < n:
            out.append(raw[i + 1]); i += 2
        elif c == "'":
            j = raw.find("'", i + 1)
            j = n if j < 0 else j
            out.append(raw[i + 1:j]); i = j + 1
        elif c == '$' and raw.startswith("$'", i):
            j = i + 2
            while j < n and raw[j] != "'":
                j += 2 if raw[j] == '\\' else 1
            out.append(raw[i + 2:j]); i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and raw[j] != '"':
                if raw[j] == '\\' and j + 1 < n and raw[j + 1] in '"\\$`':
                    out.append(raw[j + 1]); j += 2
                else:
                    out.append(raw[j]); j += 1
            i = j + 1
        else:
            out.append(c); i += 1
    return ''.join(out)


class Parser:
    """Reads one piece of bash text, recording the command calls it makes into `sink`."""

    def __init__(self, text, sink, line_of):
        self.t = text
        self.n = len(text)
        self.sink = sink          # the Scanner, which records calls and functions
        self.line_of = line_of    # position in self.t -> line in the file
        self.heredocs = []        # (delimiter, strip tabs) waiting for the next newline

    # ---- lexing ----

    def skip_blank(self, i):
        while i < self.n:
            c = self.t[i]
            if c in ' \t':
                i += 1
            elif c == '\\' and i + 1 < self.n and self.t[i + 1] == '\n':
                i += 2
            else:
                break
        return i

    def lex(self, i):
        i = self.skip_blank(i)
        t, n = self.t, self.n
        if i >= n:
            return Tok('eof', '', i, i)
        c = t[i]
        if c == '#':
            j = t.find('\n', i)
            j = n if j < 0 else j
            return self.lex(j) if j < n else Tok('eof', '', n, n)
        if c == '\n':
            return Tok('op', '\n', i, i + 1)
        for op in (';;&', ';;', ';&', '&&', '||', '|&', '&>>', '&>'):
            if t.startswith(op, i):
                return Tok('redir' if op.startswith('&>') else 'op', op, i, i + len(op))
        if c in ';&|()':
            return Tok('op', c, i, i + 1)
        m = REDIR_RE.match(t, i)
        if m:
            return Tok('redir', m.group(1), i, m.end())
        end = self.lex_word(i)
        return Tok('word', t[i:end], i, end)

    def lex_word(self, i):
        t, n = self.t, self.n
        start = i
        while i < n:
            c = t[i]
            if c in '<>' and i + 1 < n and t[i + 1] == '(' and i == start:
                i = self.parse(i + 2, stop_paren=True)
                continue
            if c in METACHARS:
                if c == '(' and ASSIGN_RE.match(t[start:i]) and t[start:i].endswith('='):
                    i = self.parse_array(i + 1)
                    continue
                break
            if c == '\\':
                i += 2
            elif c == "'":
                j = t.find("'", i + 1)
                if j < 0:
                    raise ParseError(i, 'a single quote that is never closed')
                i = j + 1
            elif c == '"':
                i = self.lex_double(i + 1)
            elif c == '`':
                i = self.lex_backtick(i)
            elif c == '$':
                i = self.lex_dollar(i)
            else:
                i += 1
        if i == start:
            raise ParseError(i, 'unexpected character %r' % t[i])
        return i

    def lex_double(self, i):
        t, n = self.t, self.n
        while i < n:
            c = t[i]
            if c == '\\':
                i += 2
            elif c == '"':
                return i + 1
            elif c == '`':
                i = self.lex_backtick(i)
            elif c == '$':
                i = self.lex_dollar(i)
            else:
                i += 1
        raise ParseError(i, 'a double quote that is never closed')

    def lex_dollar(self, i):
        t = self.t
        if t.startswith('$((', i):
            return self.skip_arith(i + 3)
        if t.startswith('$(', i):
            return self.parse(i + 2, stop_paren=True)
        if t.startswith('${', i):
            return self.lex_brace(i + 2)
        if t.startswith("$'", i):
            j = i + 2
            while j < self.n and t[j] != "'":
                j += 2 if t[j] == '\\' else 1
            if j >= self.n:
                raise ParseError(i, "a $' quote that is never closed")
            return j + 1
        return i + 1

    def lex_brace(self, i):
        t, n, depth = self.t, self.n, 1
        while i < n:
            c = t[i]
            if c == '\\':
                i += 2
            elif c == "'":
                j = t.find("'", i + 1)
                i = n if j < 0 else j + 1
            elif c == '"':
                i = self.lex_double(i + 1)
            elif c == '`':
                i = self.lex_backtick(i)
            elif c == '$':
                i = self.lex_dollar(i)
            elif c == '{':
                depth += 1; i += 1
            elif c == '}':
                depth -= 1; i += 1
                if depth == 0:
                    return i
            else:
                i += 1
        raise ParseError(i, 'a ${ that is never closed')

    def lex_backtick(self, i):
        t, n = self.t, self.n
        j = i + 1
        body = []
        while j < n and t[j] != '`':
            if t[j] == '\\' and j + 1 < n and t[j + 1] in '`$\\':
                body.append(t[j + 1]); j += 2
            else:
                body.append(t[j]); j += 1
        if j >= n:
            raise ParseError(i, 'a backquote that is never closed')
        line = self.line_of(i)
        self.sink.scan_text(''.join(body), lambda _p, line=line: line)
        return j + 1

    def skip_arith(self, i):
        t, n, depth = self.t, self.n, 2
        while i < n:
            c = t[i]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        raise ParseError(i, 'an arithmetic (( that is never closed')

    def parse_array(self, i):
        """The words of name=( ... ): not commands, but their substitutions are."""
        while True:
            tok = self.lex(i)
            if tok.kind == 'eof':
                raise ParseError(i, 'an array ( that is never closed')
            i = tok.end
            if tok.kind == 'op' and tok.text == ')':
                return i
            if tok.kind == 'op' and tok.text == '\n':
                i = self.skip_heredocs(i)

    def skip_heredocs(self, i):
        t, n = self.t, self.n
        for delim, strip in self.heredocs:
            while True:
                if i >= n:
                    raise ParseError(i, 'a heredoc whose %s line never comes' % delim)
                j = t.find('\n', i)
                j = n if j < 0 else j
                line = t[i:j]
                if strip:
                    line = line.lstrip('\t')
                i = j + 1
                if line == delim:
                    break
        self.heredocs = []
        return min(i, n)

    # ---- parsing ----

    def parse(self, i, stop_paren=False):
        """Reads commands from i. With stop_paren, until the ) that closes a $( or <( and returns
        the position after it; otherwise to the end of the text."""
        words = []          # the simple command being read: list of Tok
        cmd_start = True
        cases = []          # one entry per open case: 'subject', 'in', 'pattern' or 'body'
        depth = 0           # ( subshells opened in this parse
        mode = None         # 'for' (skipping a word list until do) or '[['
        redir = None        # the redirection whose target word comes next
        fname = False       # the word after `function` is a function's name

        def finish():
            if words:
                self.sink.command([w.text for w in words], self.line_of(words[0].pos))
                del words[:]

        while True:
            tok = self.lex(i)
            i = tok.end
            k, x = tok.kind, tok.text
            if k == 'eof':
                finish()
                if stop_paren:
                    raise ParseError(tok.pos, 'a $( or <( that is never closed')
                if cases or depth or mode:
                    raise ParseError(tok.pos, 'the text ends inside a case, a ( or a [[ / for')
                return i
            if redir is not None:
                if k != 'word':
                    raise ParseError(tok.pos, 'a redirection with no target')
                if redir in ('<<', '<<-'):
                    self.heredocs.append((dequote(x), redir == '<<-'))
                redir = None
                continue
            if k == 'redir':
                redir = x
                continue
            if k == 'op' and x == '\n':
                if not (cases and cases[-1] in ('subject', 'in', 'pattern')):
                    finish()
                i = self.skip_heredocs(i)
                if mode == 'for':
                    cmd_start = True
                elif not cases or cases[-1] == 'body':
                    cmd_start = True
                continue
            if fname:
                fname = False
                if k == 'word':
                    self.sink.function(x)
                    nxt = self.lex(i)
                    if nxt.kind == 'op' and nxt.text == '(':
                        close = self.lex(nxt.end)
                        if close.kind == 'op' and close.text == ')':
                            i = close.end
                    cmd_start = True
                    continue
            if cases and cases[-1] in ('subject', 'in'):
                if k == 'word' and cases[-1] == 'subject':
                    cases[-1] = 'in'
                elif k == 'word' and x == 'in':
                    cases[-1] = 'pattern'
                else:
                    raise ParseError(tok.pos, 'a case with no in')
                continue
            if cases and cases[-1] == 'pattern':
                if k == 'word' and x == 'esac':
                    cases.pop(); cmd_start = False
                elif k == 'op' and x == ')':
                    cases[-1] = 'body'; cmd_start = True
                elif k == 'word' or (k == 'op' and x in '(|'):
                    pass
                else:
                    raise ParseError(tok.pos, 'unexpected %r in a case pattern' % x)
                continue
            if mode == 'for':
                if k == 'word' and x == 'do' and cmd_start:
                    mode = None
                elif k == 'op' and x == ';':
                    cmd_start = True
                elif k == 'op' and x == '(' and self.t.startswith('(', i):
                    i = self.skip_arith(i + 1)
                else:
                    cmd_start = False
                continue
            if mode == '[[':
                if k == 'word' and x == ']]':
                    mode = None
                continue
            if k == 'op':
                if x in (';', '&', '&&', '||', '|', '|&'):
                    finish(); cmd_start = True
                elif x in (';;', ';&', ';;&'):
                    finish()
                    if not (cases and cases[-1] == 'body'):
                        raise ParseError(tok.pos, '%s outside a case' % x)
                    cases[-1] = 'pattern'
                elif x == '(':
                    if cmd_start and self.t.startswith('(', i):
                        i = self.skip_arith(i + 1); cmd_start = False
                    elif cmd_start:
                        depth += 1
                    elif len(words) == 1:
                        close = self.lex(i)
                        if close.kind == 'op' and close.text == ')':
                            self.sink.function(words[0].text)
                            del words[:]
                            i = close.end; cmd_start = True
                        else:
                            raise ParseError(tok.pos, 'unexpected (')
                    else:
                        raise ParseError(tok.pos, 'unexpected (')
                elif x == ')':
                    finish()
                    if depth:
                        depth -= 1; cmd_start = False
                    elif stop_paren:
                        if cases or mode:
                            raise ParseError(tok.pos, 'a $( closed inside a case or [[')
                        return i
                    else:
                        raise ParseError(tok.pos, 'unexpected )')
                continue
            # a word. A closer straight after a closer (`fi }`, `fi done`) is still a closer.
            if not cmd_start and not words and (x in RESERVED_CLOSE or x == 'esac'):
                if x == 'esac':
                    if not (cases and cases[-1] == 'body'):
                        raise ParseError(tok.pos, 'esac outside a case')
                    cases.pop()
                continue
            if cmd_start:
                if ASSIGN_RE.match(x):
                    if PATH_ASSIGN_RE.match(x):
                        self.sink.fail('PATH', self.line_of(tok.pos), MSG_SETS_PATH)
                    continue
                if x in RESERVED_START:
                    continue
                if x == 'time':
                    nxt = self.lex(i)
                    if nxt.kind == 'word' and nxt.text == '-p':
                        i = nxt.end
                    continue
                if x in RESERVED_CLOSE:
                    cmd_start = False
                    continue
                if x == 'esac' and cases and cases[-1] == 'body':
                    cases.pop(); cmd_start = False
                    continue
                if x == 'case':
                    cases.append('subject')
                    continue
                if x in ('for', 'select'):
                    mode = 'for'; cmd_start = False
                    continue
                if x == '[[':
                    mode = '[['
                    continue
                if x == 'function':
                    fname = True
                    continue
                words.append(tok); cmd_start = False
            else:
                words.append(tok)


class Scanner:
    def __init__(self, core, stubs, seams, roots):
        self.core, self.stubs, self.seams, self.roots = core, stubs, seams, roots
        self.records = []        # (kind, name, file, line, detail) before functions are known
        self.functions = set()
        self.queue, self.seen = [], set()
        self.file = None

    # ---- what a parser reports ----

    def function(self, name):
        self.functions.add(dequote(name))

    def fail(self, name, line, detail):
        self.records.append(('fail', name, self.file, line, detail))

    def note(self, kind, name, line, detail=''):
        self.records.append((kind, name, self.file, line, detail))

    def scan_text(self, text, line_of):
        Parser(text, self, line_of).parse(0)

    def command(self, raws, line):
        """One simple command, its words as written, leading assignments already removed."""
        if not raws:
            return
        name_raw, args = raws[0], raws[1:]
        name = dequote(name_raw)
        if name in ('export', 'local', 'declare', 'typeset', 'readonly'):
            for a in args:
                if PATH_ASSIGN_RE.match(dequote(a)):
                    self.fail('PATH', line, MSG_SETS_PATH)
        if name == 'unset' and 'PATH' in [dequote(a) for a in args]:
            self.fail('PATH', line, MSG_SETS_PATH)
        self.classify(name_raw, name, line)
        self.runner(name, [dequote(a) for a in args], args, line)

    def classify(self, raw, name, line):
        if name.endswith('.sh') and ('/' in name or '$' in raw):
            self.follow(name, line)
            return
        if '$' in raw or '`' in raw:
            m = VAR_CMD_RE.match(raw)
            if m:
                self.note('var', m.group(2), line)
            else:
                self.fail(name, line, MSG_EXPANSION)
            return
        if '/' in name:
            self.fail(name, line, MSG_PATH)
            return
        self.note('name', name, line)

    def runner(self, name, args, raws, line):
        """The commands a command runs: its own arguments read again as a command or as code."""
        def rest_from(k):
            if k < len(raws):
                self.command(raws[k:], line)

        if name == 'xargs':
            k = 0
            while k < len(args) and args[k].startswith('-'):
                k += 2 if args[k] in ('-I', '-J', '-L', '-n', '-P', '-R', '-S', '-s', '-E') else 1
            rest_from(k)
        elif name == 'env':
            k = 0
            while k < len(args):
                a = args[k]
                if a in ('-i', '-', '-P', '-S') or a.startswith('-S') or a.startswith('-P'):
                    self.fail('env', line, MSG_ENV_I if a in ('-i', '-') else MSG_SETS_PATH)
                    k += 1
                elif a == '-u':
                    if k + 1 < len(args) and args[k + 1] == 'PATH':
                        self.fail('PATH', line, MSG_SETS_PATH)
                    k += 2
                elif a.startswith('-'):
                    k += 1
                elif ASSIGN_RE.match(a):
                    if PATH_ASSIGN_RE.match(a):
                        self.fail('PATH', line, MSG_SETS_PATH)
                    k += 1
                else:
                    break
            rest_from(k)
        elif name == 'command':
            k = 0
            while k < len(args) and args[k].startswith('-'):
                if 'p' in args[k]:
                    self.fail('command', line, MSG_COMMAND_P)
                if 'v' in args[k] or 'V' in args[k]:
                    return
                k += 1
            rest_from(k)
        elif name in ('exec', 'nohup', 'time', 'builtin'):
            k = 0
            while k < len(args) and args[k].startswith('-'):
                k += 2 if (name == 'exec' and args[k] == '-a') else 1
            rest_from(k)
        elif name == 'nice':
            k = 0
            while k < len(args) and args[k].startswith('-'):
                k += 2 if args[k] == '-n' else 1
            rest_from(k)
        elif name == 'find':
            k = 0
            while k < len(args):
                if args[k] in ('-exec', '-execdir', '-ok', '-okdir'):
                    j = k + 1
                    while j < len(args) and args[j] not in (';', '+'):
                        j += 1
                    if k + 1 < j:
                        self.command(raws[k + 1:j], line)
                    k = j
                k += 1
        elif name in SHELLS:
            k, code = 0, False
            while k < len(args) and args[k].startswith('-') or (k < len(args) and args[k].startswith('+')):
                a = args[k]
                if a == '-c':
                    code = True
                elif 's' in a and not a.startswith('--'):
                    self.fail(name, line, MSG_STDIN)
                    return
                k += 2 if a in ('-o', '+o', '-O', '+O') else 1
            if k >= len(args):
                self.fail(name, line, MSG_STDIN)
            elif code:
                self.scan_text(args[k], lambda _p: line)
            else:
                if args[k].endswith('.sh'):
                    self.follow(args[k], line)
                else:
                    self.fail(args[k], line, MSG_NOT_FOUND)
        elif name == 'eval':
            if args:
                self.scan_text(' '.join(args), lambda _p: line)
        elif name == 'trap':
            a = list(args)
            if a and a[0] == '--':
                a = a[1:]
            if a and a[0] not in ('-', '-p', '-l'):
                self.scan_text(a[0], lambda _p: line)
        elif name in ('.', 'source'):
            if args:
                if args[0].endswith('.sh') or '/' in args[0]:
                    self.follow(args[0], line)
                else:
                    self.fail(args[0], line, MSG_NOT_FOUND)

    # ---- files ----

    def follow(self, word, line):
        base = word.rsplit('/', 1)[-1]
        if '$' in base or not base:
            self.fail(word, line, MSG_NOT_FOUND)
            return
        dirs = [os.path.dirname(self.file)] + self.roots
        found = []
        for d in dirs:
            p = os.path.join(d, base)
            if os.path.isfile(p):
                rp = os.path.realpath(p)
                if rp not in found:
                    found.append(rp)
                if d == dirs[0]:
                    break
        if not found:
            self.fail(word, line, MSG_NOT_FOUND)
            return
        if len(found) > 1 and found[0] != os.path.realpath(os.path.join(dirs[0], base)):
            self.fail(word, line, 'its name matches more than one file (%s), so which one runs is unclear' % ', '.join(found))
            return
        self.note('follow', base, line, found[0])
        self.enqueue(found[0])

    def enqueue(self, path):
        rp = os.path.realpath(path)
        if rp not in self.seen:
            self.seen.add(rp)
            self.queue.append(path)

    def scan_file(self, path):
        self.file = path
        try:
            with open(path, encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError as e:
            self.fail(os.path.basename(path), 1, 'cannot be read: %s' % e)
            return
        first = text.split('\n', 1)[0]
        if first.startswith('#!'):
            if not SHEBANG_SHELL_RE.match(first):
                self.fail(os.path.basename(path), 1, 'not a shell script (%s), so the check cannot read its commands' % first)
                return
        elif not path.endswith('.sh'):
            self.fail(os.path.basename(path), 1, 'not a shell script (no #! line and no .sh name), so the check cannot read its commands')
            return
        starts = [0] + [m.end() for m in re.finditer('\n', text)]

        def line_of(pos):
            return bisect.bisect_right(starts, pos)
        try:
            Parser(text, self, line_of).parse(0)
        except ParseError as e:
            self.fail(os.path.basename(path), line_of(e.pos), 'could not be read as bash: %s' % e)
        except RecursionError:
            self.fail(os.path.basename(path), 1, 'could not be read as bash: nested too deeply')

    def run(self, files):
        for f in files:
            self.enqueue(f)
        while self.queue:
            self.scan_file(self.queue.pop(0))
        out, failed = [], False
        for kind, name, path, line, detail in self.records:
            where = '%s:%d' % (path, line)
            if kind == 'name':
                if name in self.functions:
                    kind = 'function'
                elif name in BUILTINS:
                    kind = 'builtin'
                elif name in self.stubs:
                    kind = 'stub'
                elif name in self.core:
                    kind = 'core'
                else:
                    kind, detail = 'fail', '%s is %s' % (name, MSG_UNSTUBBED)
            elif kind == 'var':
                stub = self.seams.get(name)
                if stub is None:
                    kind, detail = 'fail', '$%s is %s' % (name, MSG_VAR)
                elif stub not in self.stubs:
                    kind, detail = 'fail', 'the seam %s points at %s, which is not on the stub list' % (name, stub)
                else:
                    kind, detail = 'seam', stub
            if kind == 'fail':
                failed = True
            out.append('\t'.join((kind, name, where, detail)))
        sys.stdout.write(''.join(line + '\n' for line in out))
        return 1 if failed else 0


def main(argv):
    opts = {'--core': '', '--stubs': '', '--seams': '', '--roots': ''}
    i = 0
    while i < len(argv) and argv[i] != '--':
        if argv[i] in opts and i + 1 < len(argv):
            opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            sys.stderr.write('disk-clean-commands.py: unknown argument %r\n' % argv[i])
            return 2
    files = argv[i + 1:]
    if not files:
        sys.stderr.write('disk-clean-commands.py: no files to read\n')
        return 2
    seams = {}
    for pair in opts['--seams'].split():
        var, _, stub = pair.partition('=')
        seams[var] = stub
    roots = [r for r in opts['--roots'].split('\n') if r]
    scanner = Scanner(set(opts['--core'].split()), set(opts['--stubs'].split()), seams, roots)
    return scanner.run(files)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

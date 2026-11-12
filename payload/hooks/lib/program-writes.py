"""The files a program writes by name, for the Slack drafts gate (claude-config#2772).

The gate notes every file a command writes, so that a script written and then run in the same command
is judged by what was written (claude-config#2525, #2721). Before #2772 it followed only the shell's
own writes (a redirection, tee, a copy, a download), so a program writing a file it names was not
followed: `python3 -c "open('run.sh','w')..." && bash run.sh`, `sed -i ... run.sh`, `dd of=run.sh`,
`tar -xf a.tar && bash a.sh`, each ran a script the gate read as it was on disk before the command.

  * dd, with nothing but if=, of= and a block size, is followed by what it copies (note_dd).
  * An archive that tar or unzip unpacks, read from disk with Python's tarfile and zipfile, is
    followed member by member: each file it unpacks is judged by what the member holds. One that
    cannot be read (from a pipe, written earlier in the command, renamed as it unpacks, past
    MAX_MEMBERS or MAX_UNPACKED) leaves every file under the folder it unpacks into unreadable.
  * Code a program is given (python3 -c, node -e, a heredoc fed to python3 -, a sed or awk program)
    that is seen unable to do more than read and write files can write only what it holds and the
    files it reads, so a file it names or edits in place (sed -i) is judged as the code, those files
    and what was there before, and an endpoint the code names is a refusal (code_names). Editing a
    script and running it is the everyday case this keeps: 82 of the 135 false refusals in the first
    replay of 3 days of this Mac's commands (2026-11-12) were a sed -i or a python3 heredoc edit.
  * Any other program that names a file may write it, so the file is unreadable from then on and
    running it is refused: a word naming it, the part of a word after an `=` (of=, --output=), or
    code that can fetch or run something (or perl and ruby code, which the gate does not read) and
    names it. Code that cannot be read at all (`python3 -c "$CODE"`, code piped from a download) may
    write any file. A data file a program only may have written is still read as it is on disk when
    it is handed to a script (the gate's data rule, #2362), or every analysis that names its input
    twice would be refused.
  * NON_WRITERS never write a file they are handed, and naming a file and then running it is
    everyday with them (`chmod +x run.sh && ./run.sh`), so their words are not read as writes; nor
    are git's subcommands that leave the working tree as it is (GIT_READS), the files handed to a
    script on disk (whose writes the gate leaves alone, as it does a shell script's), or a sed or
    awk program's input files unless it edits them in place.

A file noted here is "maybe" written, so a refusal says it may be written, never that it was (L11).
Only in text this call wrote itself: a script on disk is read by the gate before it runs, and its
writes are outside what the gate answers, as for written-paths.py (note_unreadable).

slack_drafts_only_gate.py loads this file and gives its Judge the class make() returns as a base, so
the methods use the Judge's own state (made, made_maybe, made_code, shell) and readers (operands,
note_file, note_output, pieces_of, unknown_patterns, resolve, made_from).
"""
import fnmatch
import os
import re
import tarfile
import zipfile

NON_WRITERS = frozenset({
    "cd", "pushd", "popd", "chmod", "chown", "chgrp", "chflags", "xattr", "touch", "ls", "stat", "file",
    "wc", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "ag", "diff", "cmp", "comm",
    "md5", "md5sum", "shasum", "sha1sum", "sha256sum", "cksum", "test", "[", "[[", "which", "type",
    "hash", "readlink", "realpath", "basename", "dirname", "shellcheck", "sleep", "mkdir", "rmdir",
    "rm", "unlink", "true", "false", ":", "export", "unset", "set", "local", "declare", "typeset",
    "readonly", "kill", "pkill", "wait", "source", ".", "exit", "return", "shift", "cut", "tr", "nl",
    "column", "jq", "strings", "od", "hexdump", "du", "df", "date", "ps", "pgrep", "lsof", "codesign",
    "spctl", "open", "timeout", "gtimeout", "time", "nohup", "nice", "caffeinate", "echo", "printf",
    # the shell's own words, which the gate's reader can hand over as a command's name
    "for", "select", "case", "esac", "in", "while", "until", "if", "then", "elif", "else", "fi", "do",
    "done", "function", "{", "}", "!", "]]", "let", "read", "getopts", "alias", "builtin", "command",
    "exec", "eval", "trap", "ulimit", "umask", "shopt", "setopt"})
GIT_READS = frozenset({
    "status", "diff", "log", "show", "add", "commit", "push", "fetch", "blame", "grep", "ls-files",
    "rev-parse", "branch", "tag", "remote", "config", "describe", "shortlog", "rev-list", "merge-base",
    "cat-file", "ls-tree", "ls-remote", "check-ignore", "check-attr", "diff-tree", "diff-index",
    "name-rev", "reflog", "help", "version", "var", "count-objects", "fsck", "gc", "notes"})
# Programs that copy into the folder or file their last word names.
DIR_COPIERS = frozenset({"rsync", "ditto", "scp", "sftp", "rclone"})
TARS = frozenset({"tar", "gtar", "bsdtar"})
# tar's short options that take a value, BSD's and GNU's, so the value is never read as a mode.
TAR_VALUED = "bCfsTXI"
# Other unpackers, whose members are not read: everything under the folder they run in is unreadable.
UNPACKERS = frozenset({"cpio", "pax", "7z", "7za", "7zz", "jar"})
DECOMPRESSORS = frozenset({"gunzip", "bunzip2", "unxz", "unzstd", "uncompress", "unlzma", "unlz4"})
COMPRESSORS = frozenset({"gzip", "pigz", "bzip2", "xz", "zstd", "lzma", "lz4"})
COMPRESSED = re.compile(r"\.(gz|tgz|bz2|xz|zst|Z|lzma|lz4)$")
SEDS = frozenset({"sed", "gsed"})
MAX_MEMBERS = 2000
MAX_UNPACKED = 8 * 1024 * 1024
# The files a sed program writes (w, W, the w flag of s) and an awk program prints into (> and >>).
# Read liberally: a name taken from elsewhere in the program only reads one more file as the program.
SED_WRITES = re.compile(r"(?:^|[;\n{}0-9$/])\s*[wW]\s+([^\s;}'\"]+)")
AWK_WRITES = re.compile(r">>?\s*\"([^\"]+)\"|>>?\s*([^\s;}'\"()]+)")
# Perl or Ruby code that can fetch, run or load something, or names a module or file handle at all.
PERL_ACTS = re.compile(r"`|%x|\b(system|exec|qx|open|popen|sysopen|require|use|do|eval|fork|socket|syscall|"
                       r"readpipe|spawn|load|pipe|IO|Net|URI|LWP|HTTP|Socket|Kernel|Process|File|Dir|"
                       r"ENV|STDIN|ARGV|readline|getc|binmode)\b")
# A word that is nothing but one expansion: code given this way cannot be read at all.
WHOLE_EXPANSION = re.compile(r'"?(\$\{?\w+\}?|\$\(.*\)|`.*`)"?', re.S)


def glob_escape(s):
    return re.sub(r"([*?\[])", r"[\1]", s)


def literal_word(raw):
    """The text of a shell word that expands nothing, its quotes and escapes taken away, or None where
    it holds an expansion ($, a backquote) or unquoted space or glob. The gate's own reader gives up on
    some escapes inside double quotes (`"s/x/\\${A}/"`, measured 2026-11-12), so code written with them
    is read here rather than left unreadable."""
    out, i, n, dq = [], 0, len(raw), False
    while i < n:
        c = raw[i]
        if c == "'" and not dq:
            j = raw.find("'", i + 1)
            if j < 0:
                return None
            out.append(raw[i + 1:j])
            i = j + 1
            continue
        if c == '"':
            dq = not dq
        elif c == "\\":
            if i + 1 >= n:
                return None
            nxt = raw[i + 1]
            out.append(nxt if (not dq or nxt in '$`"\\') else "\\" + nxt)
            i += 2
            continue
        elif c in "$`" or (not dq and (c.isspace() or c in "*?[]{}~;&|<>()")):
            return None
        else:
            out.append(c)
        i += 1
    return None if dq else "".join(out)


def file_shaped(path):
    """Whether a path a program may write counts as a file: one on disk, or a name with an extension
    (run.sh). Anything else it names (a subcommand, an owner/repo, a lesson number, a folder since
    deleted) made into a file was read as one by every later command handed that word: about 40 of
    the 135 false refusals in the first replay of 3 days of this Mac's commands (2026-11-12)."""
    return os.path.lexists(path) or re.search(r".\.\w+$", os.path.basename(path)) is not None


def names_file(text, base):
    """Whether code text names a file called base: not inside a longer name (run.sh.bak, xrun.sh)."""
    return bool(base) and re.search(r"(?<![\w.-])" + re.escape(base) + r"(?![\w-]|\.\w)", text) is not None


def make(interpreter, shells, awks, senders):
    """The base class for the gate's Judge. interpreter is its INTERPRETER pattern, shells its SHELLS,
    awks its AWKS and senders its SENDERS, whose downloads it notes itself."""

    class ProgramWrites:
        def note_program(self, name, args, vals, d, stdin):
            """note_writes for a program that is not a copier, printf, echo, cat or tee: the files it
            may write. Returns what it prints, as pieces, or None where that is not known."""
            if self.shell.get("on_disk") or name in NON_WRITERS or name in senders:
                return None
            if name == "dd":
                return self.note_dd(args, vals, d, stdin)
            # git's subcommand by the shared reader, never by word position (test-gh-reader.sh).
            found = self.sw.git_read([v if v is not None else a for a, v in zip(args, vals)])
            if found and found[0] in GIT_READS:
                return None
            if name in TARS or name == "unzip":
                self.note_unpack(name, args, vals, d)
            elif name in UNPACKERS:
                self.note_tree(".", ".", d, name)
            elif name in DIR_COPIERS:
                ops = [(a, v) for a, v in zip(args[1:], vals[1:]) if v is None or not v.startswith("-")]
                if ops:
                    self.note_tree(*ops[-1], d, name)
            elif name in DECOMPRESSORS or (name in COMPRESSORS and self.decompresses(vals)):
                for a, v in zip(args[1:], vals[1:]):
                    if v and not v.startswith("-") and COMPRESSED.search(v):
                        stem = COMPRESSED.sub("", v) + (".tar" if v.endswith(".tgz") else "")
                        self.note_named(stem, stem, d, name)
            elif interpreter.match(name) or name in shells:
                self.note_runner(name, args, vals, d, stdin)
            elif name in SEDS:
                self.note_sed(args, vals, d)
            elif name in awks:
                self.note_awk(args, vals, d)
            else:
                for a, v in zip(args[1:], vals[1:]):
                    self.note_named(a, v, d, name)
            return None

        def program_guesses(self, path, real):
            """For made_from: what the programs of this call may have written path with, as pieces:
            the code that names it and the files that code names where the code is followed, and an
            unreadable ("maybe") piece for a folder unpacked or copied into, or code not followed."""
            if not file_shaped(real):
                return []
            out = [("maybe", None, label) for pat, label in self.made_maybe
                   if fnmatch.fnmatchcase(real, pat) or fnmatch.fnmatchcase(path, pat)]
            bases = {os.path.basename(path), os.path.basename(real)}
            for text, label, d, follow, inputs, writes in self.made_code:
                if any(names_file(writes, b) for b in bases):
                    out += self.code_pieces(text, label, d, real, inputs) if follow else [("maybe", None, label)]
            return out

        def code_names(self, path, marker):
            """For script(): the endpoint the code that edits path names, as (the program, the
            match), or None. The code is not the script: a sed program puts its text inside the
            script, so reading the two together as commands cannot see an endpoint it inserts."""
            for kind, value, label in self.made_from(path) or ():
                if kind == "code":
                    hit = marker.search(value)
                    if hit:
                        return label[len("the code "):-len(" is given")], hit.group(0)
            return None

        def note_named(self, raw, value, d, label, strict=False):
            """A word naming a file the program may write: the file, and what follows an `=` in it. A
            word that cannot be worked out counts only where strict (a file edited in place), as the
            patterns written-paths.py gives it, since any program's arguments hold variables."""
            if value is None:
                if strict:
                    for pat in self.unknown_patterns(raw, d):
                        self.made_maybe.append((pat, label))
                return
            for p in [value] + ([value.split("=", 1)[1]] if "=" in value else []):
                if not p or p.startswith("-") or "\n" in p or len(p) > 1024 or p.startswith("/dev/"):
                    continue
                where = self.resolve(p, d)
                if os.path.isdir(where):
                    continue  # a folder is not a file the command could run
                if not file_shaped(where):
                    continue
                self.note_file(p, d, [("maybe", None, label)], append=True)

        def note_tree(self, raw, value, d, label):
            """A file or folder written whole: it, and every file under it, may be written."""
            if value is None:
                for pat in self.unknown_patterns(raw, d, copier=True):
                    self.made_maybe.append((pat, label))
                return
            real = os.path.realpath(self.resolve(value, d))
            self.made_maybe.append((glob_escape(real.rstrip("/")) + "/*", label))
            if not os.path.isdir(real):
                self.note_file(value, d, [("maybe", None, label)], append=True)

        def note_code(self, raw, value, label, d, lang):
            """Code a program is given (lang "py", "js", "sed", "awk" or another): a file it names may
            be written, and code that cannot be read at all may write any file. Code seen unable to do
            more than read and write files (no request, no command run, acts_inline with writes off,
            and any sed program) can only write what it holds and the files it names, so a file it
            names is read as those (code_pieces); other code leaves the file unreadable."""
            if value is None and WHOLE_EXPANSION.fullmatch(raw.strip()):
                self.made_maybe.append(("*", label))
                return
            if value is None:
                value = literal_word(raw)
            text = value if value is not None else raw
            if value is None:
                follow = False  # code with parts that cannot be worked out
            elif lang == "sed":
                follow = True
            elif lang == "awk":
                follow = not re.search(r"\bsystem\b|\|", text)
            elif lang in ("py", "js"):
                follow = not self.acts_inline(text, self.resolve(".", d), lang, writes=False)
            elif lang in ("perl", "ruby"):
                # Not read for what it does, so followed only where it holds none of the ways either
                # can fetch, run or load anything: a substitution, the everyday perl -pi -e edit.
                follow = not PERL_ACTS.search(text)
            else:
                follow = False
            # The text naming the files the code can write: all of it for a program that opens files
            # by any name, only the targets of w and of print > for sed and awk, whose replacement
            # text names files it never writes (`sed -i 's/a.tsv/b.tsv/' run.sh` writes run.sh).
            if lang == "sed":
                writes = " ".join(m for m in SED_WRITES.findall(text))
            elif lang == "awk":
                writes = " ".join(a or b for a, b in AWK_WRITES.findall(text))
            else:
                writes = text
            self.made_code.append((text, label, d, follow, (), writes))

        def code_inputs(self, start, d, values):
            """Give the code noted since start the files its program reads besides the ones it names:
            sed's and awk's input files, the arguments python3 -c is handed."""
            paths = tuple(os.path.realpath(self.resolve(v, d)) for v in values
                          if v and not v.startswith("-") and len(v) < 1024)
            self.made_code[start:] = [c[:4] + (paths,) + c[5:] for c in self.made_code[start:]]

        def code_pieces(self, text, label, d, real, inputs=()):
            """What a file that code names may hold once the code ran: the code itself, holding
            every literal it can write, each file it names that is there to read (sed's r, a copy's
            source), and the files its program reads (inputs). The file's own text is added by
            content(), as for any write."""
            # Kind "code": searched for an endpoint (code_names), never read as the script's own
            # lines, since sed or Python read as shell commands is noise that can refuse anything.
            out = [("code", text, f"the code {label} is given")]
            names = set(re.findall(r"""(['"])([^'"\n]{1,512})\1""", text))
            words = {w for _, w in names} | set(re.findall(r"[^\s'\";(),\0]{1,512}", text))
            words = {w for w in words if "\0" not in w}
            paths = [(os.path.realpath(self.resolve(w, d)), w) for w in sorted(words)]
            for path, w in [(p, os.path.basename(p)) for p in inputs] + paths:
                if path != real and os.path.isfile(path) and not any(p[1] == path for p in out):
                    out.append(("file", path, w))
                if len(out) > 32:
                    break
            return out

        @staticmethod
        def decompresses(vals):
            if any(v in ("-c", "--stdout", "--to-stdout") for v in vals[1:]):
                return False
            return any(v and (v in ("-d", "--decompress", "--uncompress") or re.fullmatch(r"-[a-zA-Z]*d[a-zA-Z]*", v))
                       for v in vals[1:])

        def note_dd(self, args, vals, d, stdin):
            """dd: of= is written with what if= holds (or its input), where nothing else changes it."""
            src, dst_raw, dst, other = None, None, None, False
            for a, v in zip(args[1:], vals[1:]):
                if v is None:
                    if a.startswith("of="):
                        dst_raw, dst = a, None
                    elif not re.match(r"(if|bs|ibs|obs|status)=", a):
                        other = True  # may be of= itself
                        self.made_maybe.append(("*", "dd"))
                    other = other or a.startswith("if=")
                    continue
                key, eq, val = v.partition("=")
                if not eq:
                    other = True
                elif key == "if":
                    src = val
                elif key == "of":
                    dst_raw, dst = a, val
                elif key not in ("bs", "ibs", "obs", "status"):
                    other = True  # skip, seek, count, conv: not the whole source as it is
            pieces = None if other else (self.pieces_of(src, d) if src else stdin)
            if dst_raw is not None:
                # Added to, never replacing, what an earlier write left there: this change only
                # tightens the gate, so a file main read as unreadable stays so (#2772).
                self.note_output(dst_raw, dst, d, pieces, "dd", append=True)
            return None  # what it prints is not worked out, as before #2772

        def note_edited(self, raw, value, d, label, codes, strict=True):
            """A file a program edits with the code it was given (sed -i, gawk -i inplace, a file
            handed to python3 -c): read as that code and the files it names where every piece of it
            is followed (note_code), else unreadable. A word that cannot be worked out counts only
            where strict (sed -i's own operands): a function's "$1" handed to python3 -c read as any
            file at all refused every command after it in the replay."""
            if value is None:
                for pat in self.unknown_patterns(raw, d) if strict else ():
                    self.made_maybe.append((pat, label))
                return
            if not codes or not all(c[3] for c in codes):
                self.note_named(raw, value, d, label)
                return
            real = os.path.realpath(self.resolve(value, d))
            pieces = [p for text, lab, cd, _, ins, _ in codes for p in self.code_pieces(text, lab, cd, real, ins)]
            self.note_file(value, d, pieces, append=True)

        def note_runner(self, name, args, vals, d, stdin):
            """A shell or interpreter: the words after the script or code it runs are files it may
            write, as are files its code names. A shell's -c string is read as commands by the gate
            itself, and a script on disk is outside what this follows, so the files it is handed are
            unreadable."""
            words = [v if v is not None else a for a, v in zip(args, vals)]
            op, inline, _ = self.operands(words)
            lang, start = self.family(name), len(self.made_code)
            if inline:
                if name in shells:
                    return
                at = len(inline[0]) + 2
                if at < len(args):
                    self.note_code(args[at], vals[at], name, d, lang)
                rest = range(at + 1, len(args))
            elif op and op != "-":
                # A script on disk: what it writes is outside what the gate follows, as a shell
                # script's own writes are (module docstring). Reading its arguments as written
                # refused every `python3 trace.py x.sh; python3 dbg.py x.sh` in the replay.
                return
            else:
                rest = range(words.index("-", 1) + 1, len(args)) if op == "-" else range(0)
                for kind, value, _ in (stdin or ()) if name not in shells else ():
                    if kind == "text":
                        self.note_code(value, value, name, d, lang)
                    elif kind == "unknown":
                        self.made_maybe.append(("*", name))
            self.code_inputs(start, d, [vals[k] for k in rest])
            codes = self.made_code[start:]
            for k in rest:
                if vals[k] is not None and vals[k].startswith("-"):
                    continue
                if codes:
                    self.note_edited(args[k], vals[k], d, name, codes, strict=False)
                else:
                    self.note_named(args[k], vals[k], d, name)

        def note_sed(self, args, vals, d):
            """sed: its program may write a file it names (w), and with -i it edits its input files."""
            scripts, files, inplace, given, k = [], [], False, False, 1
            start, from_file = len(self.made_code), False
            while k < len(vals):
                v = vals[k]
                if v in ("-e", "--expression"):
                    scripts.append(k + 1)
                    k += 2
                    continue
                if v and v.startswith("--expression="):
                    self.note_code(v, v[len("--expression="):], "sed", d, "sed")
                    given = True
                elif v in ("-f", "--file"):
                    given = from_file = True
                    k += 2
                    continue
                elif v and (v in ("-i", "-I", "--in-place") or v.startswith("--in-place=")
                            or re.fullmatch(r"-[EnrsuzlE]*[iI]\S*", v)):
                    inplace = True
                    nxt = vals[k + 1] if k + 1 < len(vals) else None
                    if v in ("-i", "-I") and nxt is not None and (nxt == "" or re.fullmatch(r"\.[\w.~-]*", nxt)):
                        k += 1  # BSD's backup suffix
                elif v and v.startswith("-") and v != "-":
                    pass
                else:
                    files.append(k)
                k += 1
            if not scripts and not given and files:
                scripts.append(files.pop(0))
            for k in scripts:
                if k < len(args):
                    self.note_code(args[k], vals[k], "sed", d, "sed")
            self.code_inputs(start, d, [vals[k] for k in files])
            codes = [] if from_file else self.made_code[start:]  # a program in a file is not read
            if inplace:
                for k in files:
                    self.note_edited(args[k], vals[k], d, "sed", codes)

        def note_awk(self, args, vals, d):
            """awk: its program may write a file it names (print >), and gawk -i inplace edits its input."""
            program, files, inplace, given, k = None, [], False, False, 1
            start = len(self.made_code)
            while k < len(vals):
                v = vals[k] or ""
                if v in ("-F", "-v"):
                    k += 2
                    continue
                if v in ("-f", "--file"):
                    given = True
                    k += 2
                    continue
                if v in ("-i", "--include"):
                    inplace = inplace or (vals[k + 1] if k + 1 < len(vals) else "") == "inplace"
                    k += 2
                    continue
                if v in ("-iinplace", "--include=inplace"):
                    inplace = True
                elif v.startswith("-") and v != "-":
                    pass
                elif program is None and not given:
                    program = k
                else:
                    files.append(k)
                k += 1
            if program is not None:
                self.note_code(args[program], vals[program], "awk", d, "awk")
                self.code_inputs(start, d, [vals[k] for k in files])
            if inplace:
                for k in files:
                    self.note_edited(args[k], vals[k], d, "awk", [] if given else self.made_code[start:])

        def note_unpack(self, name, args, vals, d):
            """tar or unzip unpacking an archive: each member by what it holds where the archive can be
            read, else every file under the folder it unpacks into."""
            if name == "unzip":
                found = self.unzip_words(args, vals)
            else:
                found = self.tar_words(args, vals)
            if found is None:
                return  # lists, tests or unpacks to its output: writes no file
            archive, dest_raw, dest, renames = found
            members = None
            if archive and dest is not None and not renames:
                path = os.path.realpath(self.resolve(archive, d))
                if not self.made_from(path) and os.path.isfile(path):
                    members = self.read_members(path, name)
            if members is None:
                self.note_tree(dest_raw, dest, d, f"{name}, which unpacks it")
                return
            root = self.resolve(dest, d)
            for member, data in members:
                target = os.path.join(root, member)
                if data is None:
                    self.note_file(target, d, [("maybe", None, f"{name}, which unpacks it")], append=True)
                else:
                    self.note_file(target, d, [("text", data, f"{member} in {archive}")], append=True)

        @staticmethod
        def read_members(path, name):
            """[(member path, its text, or None for a link or other special member)] of an archive,
            or None where it cannot be read whole within the limits, or a member would land outside
            the folder (an absolute path or ..)."""
            out, total = [], 0
            try:
                if name == "unzip":
                    with zipfile.ZipFile(path) as z:
                        infos = z.infolist()
                        if len(infos) > MAX_MEMBERS:
                            return None
                        for i in infos:
                            if i.is_dir():
                                continue
                            total += i.file_size
                            if total > MAX_UNPACKED:
                                return None
                            out.append((i.filename, z.read(i).decode("utf-8", "replace")))
                else:
                    with tarfile.open(path, "r:*") as t:
                        for k, m in enumerate(t):
                            if k >= MAX_MEMBERS:
                                return None
                            if m.isdir():
                                continue
                            if not m.isfile():
                                out.append((m.name, None))
                                continue
                            total += m.size
                            if total > MAX_UNPACKED:
                                return None
                            f = t.extractfile(m)
                            out.append((m.name, f.read().decode("utf-8", "replace") if f else ""))
            except (OSError, tarfile.TarError, zipfile.BadZipFile, EOFError, ValueError, RuntimeError):
                return None
            for member, _ in out:
                if os.path.isabs(member) or ".." in member.replace("\\", "/").split("/"):
                    return None
            return out

        @staticmethod
        def tar_words(args, vals):
            """(the archive, the -C word and its value, whether names change as they unpack) for tar
            extracting to files, None for any other mode. The archive is None for one read from its
            input or a word that cannot be worked out."""
            extract, stdout, renames = False, False, False
            archive, dest_raw, dest = None, ".", "."
            k, n = 1, len(vals)

            def value(j, rest):
                return (rest, rest, j) if rest else ((args[j + 1], vals[j + 1], j + 1) if j + 1 < n else ("", "", j))

            while k < n:
                v = vals[k]
                if v is None:
                    k += 1
                    continue
                if v.startswith("--"):
                    key, eq, val = v.partition("=")
                    if key in ("--extract", "--get"):
                        extract = True
                    elif key == "--to-stdout":
                        stdout = True
                    elif key in ("--strip-components", "--transform", "--xform", "--absolute-names", "-s"):
                        renames = True
                    if key in ("--file", "--directory") or (key in ("--strip-components", "--transform", "--xform")
                                                            and not eq):
                        raw, val2, k = value(k, val) if eq else value(k, "")
                        if key == "--file":
                            archive = val2
                        elif key == "--directory":
                            dest_raw, dest = raw, val2
                    k += 1
                    continue
                bundled = k == 1 and not v.startswith("-")
                if v.startswith("-") or bundled:
                    letters = v.lstrip("-")
                    owed = []
                    for j, c in enumerate(letters):
                        if c == "x":
                            extract = True
                        elif c == "O":
                            stdout = True
                        elif c in "Ps":
                            renames = True
                        if c in TAR_VALUED:
                            if bundled:
                                owed.append(c)
                                continue
                            raw, val, k = value(k, letters[j + 1:])
                            if c == "f":
                                archive = val
                            elif c == "C":
                                dest_raw, dest = raw, val
                            break
                    for c in owed:  # tar xfC a.tar dir: the values follow in the letters' order
                        raw, val, k = value(k, "")
                        if c == "f":
                            archive = val
                        elif c == "C":
                            dest_raw, dest = raw, val
                k += 1
            if not extract or stdout:
                return None
            if archive in ("-", ""):
                archive = None
            return archive, dest_raw, dest, renames

        @staticmethod
        def unzip_words(args, vals):
            """tar_words for unzip: None where it lists, tests or prints (-l, -t, -p, -c, -Z, -z)."""
            archive, dest_raw, dest, renames, k = None, ".", ".", False, 1
            while k < len(vals):
                v = vals[k]
                if v is not None and v.startswith("-"):
                    if v == "-d":
                        if k + 1 < len(vals):
                            dest_raw, dest = args[k + 1], vals[k + 1]
                        k += 2
                        continue
                    if v == "-x":
                        break  # the rest are names left out
                    if re.search(r"[ltpcZz]", v[1:]):
                        return None
                    renames = renames or "j" in v
                elif archive is None:
                    archive = v if v is not None else ""
                k += 1
            return (archive or None), dest_raw, dest, renames

    return ProgramWrites

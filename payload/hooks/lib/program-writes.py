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
  * A git checkout, switch, hard reset, merge, pull, rebase, cherry pick, revert, stash, new linked
    worktree or clone writes tracked files it does not name (GIT_TREE_WRITERS, claude-config#2827,
    #2844): each file it writes is read as git holds it, beside what is on disk, asked of git (note_git,
    git_guesses). A pull's ref, and a remote branch a git fetch earlier in the command fetched, is
    fetched first into a scratch repository, so what the fetch brings is
    read (git_fetch); a clone of anything but a local repository is a download, and unreadable.
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
import lzma
import os
import re
import tarfile
import zipfile
import zlib

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
# git's subcommands that write tracked files the command does not name, from a ref the repository
# holds (claude-config#2827), and for each the options whose value is the next word, so the value is
# never read as the ref. "tree" writes every file the ref holds; "diff" the files the ref changed
# since it parted from HEAD; "commit" the files the commit itself changed.
GIT_TREE_WRITERS = {
    "checkout": ("tree", {"-b", "-B", "--orphan", "--conflict"}),
    "switch": ("tree", {"-c", "-C", "--create", "--force-create", "--orphan", "--conflict"}),
    "reset": ("tree", set()),
    "merge": ("diff", {"-m", "-F", "-s", "-X", "--strategy", "--strategy-option", "--file", "--into-name"}),
    "pull": ("diff", {"-s", "-X", "--strategy", "--strategy-option", "--depth", "-j", "--jobs", "-o",
                      "--server-option", "--upload-pack"}),
    "rebase": ("diff", {"-s", "-X", "--strategy", "--strategy-option", "-x", "--exec", "--onto"}),
    "cherry-pick": ("commit", {"-m", "--mainline", "-X", "--strategy", "--strategy-option"}),
    # claude-config#2844: a revert writes what the commit's parent held; a stash pop or apply what the
    # stash holds, and a stash push what HEAD holds; a new linked worktree and a clone every file the
    # ref holds, in the folder they make.
    "revert": ("revert", {"-m", "--mainline", "-X", "--strategy", "--strategy-option", "-s", "--cleanup"}),
    "stash": ("stash", {"-m", "--message", "--pathspec-from-file"}),
    "worktree": ("tree", {"-b", "-B", "--reason"}),
    "clone": ("tree", {"-o", "--origin", "-b", "--branch", "-u", "--upload-pack", "--reference",
                       "--reference-if-able", "--separate-git-dir", "--depth", "--shallow-since",
                       "--shallow-exclude", "-c", "--config", "--server-option", "-j", "--jobs", "--template",
                       "--filter", "--bundle-uri", "--ref-format", "--revision"}),
}
# A word naming a git revision that bash leaves as it is, though the gate's reader does not work it out:
# a reflog entry (stash@{1}, HEAD@{2}, @{-1}; bash expands braces only around a comma or ..) or an
# ancestor (HEAD~2, main^; bash expands a tilde only at the start of a word).
GIT_REV_WORD = re.compile(r"(?!~)(?:[\w./~^:+-]|@\{[\w.:-]*\}|@)+")
# How long a pull's fetch may take, well inside the gate's own 11 second budget (git_fetch).
FETCH_TIMEOUT = 4
# A git operation already under way: it takes no ref.
GIT_UNDER_WAY = frozenset({"--abort", "--continue", "--skip", "--quit", "--edit-todo", "--show-current-patch"})
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
SED_WRITES = re.compile(r"(?:^|[;\n{}0-9$]|/[gpIiMme0-9]*)\s*[wW]\s+([^\s;}'\"]+)")
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
            if found and found[0] == "fetch":
                self.note_fetch([v if v is not None else "\0" for v in vals[1:]])
            if found and found[0] in GIT_READS:
                return None
            if found and found[0] in GIT_TREE_WRITERS:
                # A revision bash leaves as written (GIT_REV_WORD) is read as written.
                self.note_git([v if v is not None else a if GIT_REV_WORD.fullmatch(a) else "\0"
                               for a, v in zip(args[1:], vals[1:])], d)
            # A compiler's outputs, read as their sources when run (lib/program-runs.py, #2844). A build
            # whose outputs are all known writes nothing else a command runs, so the files it names
            # are not marked as ones it may write (Dan chose this on 2026-11-12, #2844: an esbuild
            # --outfile= and a bun build were refused however quiet what they built).
            if self.note_build(name, vals, d):
                return None
            if name in TARS or name == "unzip":
                self.note_unpack(name, args, vals, d)
            elif name in UNPACKERS:
                self.note_tree(".", ".", d, name)
            elif name in DIR_COPIERS:
                ops = [(a, v) for a, v in zip(args[1:], vals[1:]) if v is None or not v.startswith("-")]
                if ops:
                    self.note_tree(*ops[-1], d, name)
            elif (name in DECOMPRESSORS or name in COMPRESSORS) and \
                    self.decompresses(vals + (["-d"] if name in DECOMPRESSORS else [])):
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

        def note_fetch(self, words):
            """A git fetch: the remotes whose branches a later checkout, switch, reset, merge, rebase
            or cherry pick in this call reads as the fetch leaves them (note_git, git_fetch), "*" for
            every remote (--all, or no remote named, whose default the gate does not work out). Dan
            chose this on 2026-11-12 (#2844): `git fetch && git checkout origin/x && bash run.sh`
            read origin/x as last fetched."""
            sub, front, after = self.sw.git_path(list(words))
            valued = {"--depth", "--deepen", "--shallow-since", "--shallow-exclude", "-j", "--jobs",
                      "--upload-pack", "-o", "--server-option", "--negotiation-tip", "--refmap", "--filter",
                      "--recurse-submodules-default"}
            positional, k, every = [], 0, False
            while k < len(after):
                w = after[k]
                if w == "--":
                    positional += after[k + 1:]
                    break
                if w.startswith("-"):
                    every = every or w == "--all"
                    k += 2 if w in valued else 1
                    continue
                positional.append(w)
                k += 1
            remote = "*" if every or not positional or "\0" in positional[0] else positional[0]
            self.git_fetched.add(remote)

        def note_git(self, words, d):
            """A git subcommand that writes tracked files without naming them (GIT_TREE_WRITERS,
            claude-config#2827, #2844): each file the ref holds (a checkout, a switch, a hard reset, a
            stash push, a new linked worktree, a clone), or changed (a merge, a pull, a rebase, a cherry
            pick, a revert, a stash pop or apply), is read as git leaves it, beside what is on disk
            (git_guesses). Before #2827 it was read only as it was on disk before the command, so
            `git checkout feature && bash run.sh` ran feature's run.sh unread; before #2844 the same
            held for a revert, a stash, a worktree and a clone.

            Marking every tracked file unreadable instead (#2827's open question) would refuse
            `git pull && bash any.sh`, the everyday shape, whatever the pull brings; reading what the
            ref holds refuses only a file whose incoming text posts. A ref is read as the repository
            holds it before the command runs, except a pull's, and a remote branch a git fetch earlier in
            the command fetched (fetched_ref), each fetched into a scratch
            repository first, so what the fetch brings is read (git_fetch); a clone of a local
            repository is read there, and a clone of anything else is downloaded, so every file under
            the folder it makes is unreadable, as a download's is. A ref that names nothing, a word
            that cannot be worked out and a directory that is not a repository leave the files as
            they are on disk, as before; a file the command names is noted as before (note_named), so
            nothing refused before passes."""
            words = list(words)
            sub, front, after = self.sw.git_path(words)
            mode, valued = GIT_TREE_WRITERS[sub]
            where = self.resolve(".", d)
            k = 0
            while k < len(front):
                if front[k] == "-C" and k + 1 < len(front):
                    if "\0" in front[k + 1]:
                        return
                    where = os.path.join(where, os.path.expanduser(front[k + 1]))
                    k += 2
                    continue
                if front[k].split("=", 1)[0] in ("--git-dir", "--work-tree"):
                    return  # a repository set apart from the folder: not worked out here
                k += 1
            positional, onto, flags, values, k = [], [], set(), {}, 0
            while k < len(after):
                w = after[k]
                if w == "--":
                    if sub in ("checkout", "reset", "switch"):
                        return  # paths follow: those are named, and noted as before
                    positional += after[k + 1:]
                    break
                if w.startswith("-") and w != "-":
                    key = w.split("=", 1)[0]
                    flags.add(key)
                    takes = key in valued and "=" not in w
                    value = w.split("=", 1)[1] if "=" in w else (after[k + 1] if takes and k + 1 < len(after) else "\0")
                    values[key] = value
                    if key == "--onto":
                        onto.append(w.split("=", 1)[1] if "=" in w else (after[k + 1] if k + 1 < len(after) else "\0"))
                    k += 2 if takes else 1
                    continue
                positional.append(w)
                k += 1
            if flags & GIT_UNDER_WAY:
                return
            refs = []  # (the ref to read, as the refusal names it)
            entry = {}  # what each entry this command notes holds beyond its ref
            if sub == "checkout":
                if len(positional) != 1:
                    return  # none: a new branch at HEAD; more: a ref and the paths it writes, named
                refs = [positional[0]]
            elif sub == "switch":
                refs = positional[:1]
            elif sub == "reset":
                if not flags & {"--hard", "--merge", "--keep"} or len(positional) > 1:
                    return  # the working tree is left as it is, or paths are named
                refs = positional[:1] or ["HEAD"]
            elif sub == "merge":
                refs = positional or ["@{upstream}"]
            elif sub == "pull":
                if not positional:
                    refs, entry["fetch"] = ["@{upstream}"], (None, None)
                else:
                    specs = [s.split(":", 1)[0].lstrip("+") for s in positional[1:]]
                    specs = [s[len("refs/heads/"):] if s.startswith("refs/heads/") else s for s in specs]
                    if positional[0] == ".":
                        refs = specs
                    else:
                        for s in specs or [None]:
                            self.made_git.append(self.git_entry(where, f"{positional[0]}/{s}" if s else "@{upstream}",
                                                                mode, f"git {sub} {positional[0]}" + (f" {s}" if s else ""),
                                                                fetch=(positional[0], s)))
                        return
            elif sub == "rebase":
                refs = onto + (positional[:1] or ["@{upstream}"])
            elif sub == "cherry-pick":
                refs = [r for r in positional if ".." not in r and not r.startswith("^")]
            elif sub == "revert":
                refs = [r for r in positional if ".." not in r and not r.startswith("^")]
                parent = values.get("-m") or values.get("--mainline") or "1"
                entry["parent"] = parent if parent.isdigit() else "1"
            elif sub == "stash":
                action, rest = (positional[0], positional[1:]) if positional else ("push", [])
                if action in ("pop", "apply"):
                    ref = rest[0] if rest else "stash@{0}"
                    refs = [f"stash@{{{ref}}}" if ref.isdigit() else ref]
                elif action == "branch":
                    ref = rest[1] if len(rest) > 1 else "stash@{0}"
                    ref = f"stash@{{{ref}}}" if ref.isdigit() else ref
                    self.made_git.append(self.git_entry(where, ref + "^1", "tree", "git stash branch"))
                    refs = [ref]
                elif action in ("push", "save"):
                    # The tracked files go back to what HEAD holds (with --keep-index, what the index
                    # holds, which HEAD's text over-reads rather than misses).
                    self.made_git.append(self.git_entry(where, "HEAD", "tree", "git stash"))
                    return
                else:
                    return  # list, show, drop, clear, create, store: the working tree is left as it is
            elif sub == "worktree":
                if not positional or positional[0] != "add" or len(positional) < 2:
                    return
                if flags & {"--no-checkout", "--orphan"} or "\0" in positional[1]:
                    return  # nothing checked out, or a folder that cannot be worked out
                at = os.path.join(where, os.path.expanduser(positional[1]))
                new = values.get("-b") or values.get("-B")
                if len(positional) > 2:
                    specs = [positional[2]]
                elif new or "--detach" in flags:
                    specs = ["HEAD"]
                else:
                    # Named after its folder: that branch where it exists, a new one at HEAD where not.
                    specs = ["refs/heads/" + os.path.basename(os.path.normpath(at)), "HEAD"]
                self.made_git.append(self.git_entry(where, specs, "tree", f"git worktree add {positional[1]}", at=at))
                return
            elif sub == "clone":
                if flags & {"-n", "--no-checkout", "--bare", "--mirror"} or not positional:
                    return
                repo = positional[0]
                folder = positional[1] if len(positional) > 1 else self.clone_folder(repo)
                if not folder or "\0" in repo or "\0" in folder:
                    return
                at = os.path.join(where, os.path.expanduser(folder))
                local = repo[len("file://"):] if repo.startswith("file://") else repo
                local = os.path.join(where, os.path.expanduser(local))
                if re.match(r"[A-Za-z][\w+.-]*://", repo) and not repo.startswith("file://") or not os.path.isdir(local):
                    # A remote: what the clone writes is downloaded, so it cannot be read, as a download's
                    # file is not (note_unreadable).
                    real = os.path.realpath(at)
                    self.made_unknown.append((glob_escape(real.rstrip("/")) + "/*", "git clone, which downloads it"))
                    return
                branch = values.get("-b") or values.get("--branch") or values.get("--revision")
                spec = branch if branch and "\0" not in branch else "HEAD"
                self.made_git.append(self.git_entry(local, spec, "tree", f"git clone {repo}", at=at))
                return
            for ref in refs:
                if not ref or "\0" in ref:
                    continue
                # Asked of git only once a later command reads a file (git_guesses), so a pull that
                # runs nothing after it costs no git call.
                label = f"git {sub} {ref}" if ref in positional or ref in onto else f"git {sub}"
                if sub == "stash":
                    label = f"git stash {positional[0] if positional else 'push'}" + (f" {positional[1]}" if len(positional) > 1 else "")
                fetched = self.fetched_ref(ref) if "fetch" not in entry else None
                self.made_git.append(self.git_entry(where, "@{-1}" if ref == "-" else ref, mode, label,
                                                    **dict(entry, fetch=fetched) if fetched else entry))

        def fetched_ref(self, ref):
            """(the remote, its branch) where ref names a remote branch a git fetch earlier in this call
            fetched (note_fetch), so it is read as that fetch leaves it; None otherwise."""
            name = ref[len("refs/remotes/"):] if ref.startswith("refs/remotes/") else ref
            if "/" not in name or not self.git_fetched:
                return None
            remote, branch = name.split("/", 1)
            if remote not in self.git_fetched and "*" not in self.git_fetched or not branch:
                return None
            return remote, "refs/heads/" + branch

        @staticmethod
        def git_entry(where, spec, mode, label, at=None, fetch=None, parent=None):
            """One note_git entry: the folder git is asked in, the ref (or refs, the first that names a
            commit) whose files are read, how its files are listed (git_names), the name a refusal gives
            it, the folder its files land in where that is not the repository's own (a new worktree, a
            clone), and for a pull what to fetch, for a revert which parent it goes back to."""
            return {"where": where, "spec": spec, "mode": mode, "label": label, "root": None, "sha": None,
                    "names": None, "blobs": {}, "at": os.path.realpath(at) if at else None, "fetch": fetch,
                    "parent": parent, "git": None, "head": None}

        @staticmethod
        def clone_folder(repo):
            """The folder git clone makes when it is not named: the repository's last name, past any
            trailing slash, /.git and .git, as git guesses it."""
            name = repo.rstrip("/")
            if name.endswith("/.git"):
                name = name[:-len("/.git")]
            name = re.split(r"[/:]", name)[-1]
            for suffix in (".git", ".bundle"):
                if name.endswith(suffix):
                    name = name[:-len(suffix)]
            return name or None

        def git_resolve(self, e):
            """The repository and commit a note_git entry reads, asked of git on first use: root and
            sha stay empty ("") where the folder is not a repository or the ref names no commit. git is
            the folder later questions are asked in: the repository, or the scratch one a pull's fetch
            lands in. head is the commit HEAD names, which a pull, merge or rebase diffs against."""
            out = self.git_out(e["where"], ["rev-parse", "--show-toplevel"])
            e["root"] = os.path.realpath(out.decode("utf-8", "replace").strip()) if out else ""
            e["git"] = e["root"]
            if not e["root"] and e["at"]:
                # A clone of a bare repository, whose folder has no working tree to name.
                bare = self.git_out(e["where"], ["rev-parse", "--is-bare-repository"])
                e["git"] = e["where"] if bare and bare.strip() == b"true" else ""
            if not e["git"]:
                e["sha"] = ""
                return
            head = self.git_out(e["git"], ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
            e["head"] = head.decode("utf-8", "replace").strip() if head else ""
            fetched = self.git_fetch(e) if e["fetch"] else None
            e["sha"] = ""
            if fetched:
                e["git"], e["sha"] = fetched
            for spec in [] if fetched else e["spec"] if isinstance(e["spec"], list) else [e["spec"]]:
                sha = self.git_out(e["git"], ["rev-parse", "--verify", "--quiet", "--end-of-options",
                                              spec + "^{commit}"])
                if sha:
                    e["sha"] = sha.decode("utf-8", "replace").strip()
                    break
            if e["sha"] and e["mode"] == "revert":
                parent = self.git_out(e["git"], ["rev-parse", "--verify", "--quiet",
                                                 f"{e['sha']}^{e['parent'] or '1'}"])
                e["parent_sha"] = parent.decode("utf-8", "replace").strip() if parent else ""
                if not e["parent_sha"]:
                    e["sha"] = ""  # a root commit: its revert deletes files, writing none

        def git_fetch(self, e):
            """(the scratch repository, the commit) a pull's fetch brings, fetched there rather than in
            the repository itself, or None where it cannot be (no upstream, a remote that answers no,
            past FETCH_TIMEOUT), when the ref as last fetched is read instead, as before #2844. The
            scratch repository borrows the repository's objects (alternates), so only what is new is
            fetched, and nothing in the repository changes: no ref, no FETCH_HEAD, no object."""
            import atexit
            import shutil
            import tempfile
            remote, ref = e["fetch"]
            root = e["root"]
            if remote is None or ref is None:
                # No refspec: the branch the current one tracks, as git pull merges it (with a remote
                # named, only where the current branch tracks a branch of that remote).
                cur = self.git_out(root, ["symbolic-ref", "-q", "--short", "HEAD"])
                cur = cur.decode("utf-8", "replace").strip() if cur else ""
                if not cur:
                    return None
                tracked = self.git_out(root, ["config", f"branch.{cur}.remote"])
                tracked = tracked.decode("utf-8", "replace").strip() if tracked else ""
                if remote is not None and remote != tracked:
                    return None
                remote = tracked
                ref = self.git_out(root, ["config", f"branch.{cur}.merge"])
                ref = ref.decode("utf-8", "replace").strip() if ref else ""
            if not remote or remote == "." or not ref or "\0" in remote + ref:
                return None
            url = self.git_out(root, ["remote", "get-url", "--", remote])
            if url:
                url = url.decode("utf-8", "replace").strip()
            elif re.match(r"[A-Za-z][\w+.-]*://|[^/]+:", remote) or os.path.exists(os.path.join(root, remote)):
                url = remote
            else:
                return None  # names no remote: a local branch with a slash in its name (feature/x)
            if not re.match(r"[A-Za-z][\w+.-]*://|[^/]+:", url) and os.path.exists(os.path.join(root, url)):
                url = os.path.realpath(os.path.join(root, url))
            common = self.git_out(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
            if not common:
                return None
            scratch = tempfile.mkdtemp(prefix="slack-gate-pull.")
            atexit.register(shutil.rmtree, scratch, True)
            if self.git_out(scratch, ["init", "-q", "--bare"]) is None:
                return None
            try:
                with open(os.path.join(scratch, "objects", "info", "alternates"), "w") as f:
                    f.write(os.path.join(common.decode("utf-8", "replace").strip(), "objects") + "\n")
            except OSError:
                return None
            if self.git_out(scratch, ["fetch", "-q", "--no-tags", "--", url, f"+{ref}:refs/pull"],
                            timeout=FETCH_TIMEOUT) is None:
                return None
            sha = self.git_out(scratch, ["rev-parse", "--verify", "--quiet", "refs/pull^{commit}"])
            return (scratch, sha.decode("utf-8", "replace").strip()) if sha else None

        @staticmethod
        def git_out(where, args, timeout=5):
            """git's output for a git command run in where, or None where it fails. The session's GIT_
            variables are left out, so a hook run inside a git operation reads the repository the
            command names, not the one git set for the hook; and git never stops to ask for a
            password (a fetch that would ask fails instead)."""
            import subprocess  # here, not at the top: only a git command that writes tracked files needs it
            env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
            env.update(GIT_TERMINAL_PROMPT="0", GIT_SSH_COMMAND="ssh -o BatchMode=yes", GCM_INTERACTIVE="never")
            try:
                p = subprocess.run(["git", "-C", where] + args, capture_output=True, env=env, timeout=timeout,
                                   stdin=subprocess.DEVNULL)
            except (OSError, ValueError, subprocess.SubprocessError):
                return None  # ValueError: a word that could not be worked out, held as a NUL
            return p.stdout if p.returncode == 0 else None

        def git_names(self, e):
            """{each file a note_git entry writes, relative to where it lands: the object git_guesses
            reads it from}. "tree" writes every file the commit holds; "diff" those it changed since it
            parted from HEAD; "commit" those the commit changed; "revert" those too, as its parent held
            them; "stash" those the stash changed from its base, and the untracked files it holds."""
            sha, mode = e["sha"], e["mode"]

            def listed(args, at):
                out = self.git_out(e["git"], args)
                names = set(out.decode("utf-8", "replace").split("\0")) - {""} if out else set()
                return {n: f"{at}:{n}" for n in names}
            if mode == "tree":
                return listed(["ls-tree", "-r", "-z", "--name-only", sha], sha)
            if mode == "diff":
                if not e["head"]:
                    return {}
                return listed(["diff", "--name-only", "-z", "--no-renames", f"{e['head']}...{sha}"], sha)
            if mode == "commit":
                return listed(["diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "--root", sha], sha)
            if mode == "revert":
                return listed(["diff-tree", "--name-only", "-r", "-z", "--no-renames", e["parent_sha"], sha],
                              e["parent_sha"])
            names = listed(["diff", "--name-only", "-z", "--no-renames", f"{sha}^1", sha], sha)
            untracked = self.git_out(e["git"], ["rev-parse", "--verify", "--quiet", f"{sha}^3"])
            if untracked:
                names.update(listed(["ls-tree", "-r", "-z", "--name-only", f"{sha}^3"], f"{sha}^3"))
            return names

        def git_guesses(self, real):
            """For made_from: the text each git command noted by note_git leaves in the file at real,
            as ("text", it, label) pieces, where the command writes that file and git holds it other
            than it is on disk. The files a command writes, and each one's text, are asked of git once."""
            out = []
            for e in self.made_git:
                if e["sha"] is None:
                    self.git_resolve(e)
                at = e["at"] or e["root"]
                if not e["sha"] or not at or not real.startswith(at + os.sep):
                    continue
                rel = real[len(at) + 1:]
                if e["names"] is None:
                    e["names"] = self.git_names(e)
                obj = e["names"].get(rel)
                if obj is None:
                    continue
                if rel not in e["blobs"]:
                    blob = self.git_out(e["git"], ["cat-file", "blob", obj])
                    try:
                        with open(real, "rb") as f:
                            same = blob is not None and f.read(len(blob) + 1) == blob
                    except OSError:
                        same = False
                    e["blobs"][rel] = None if blob is None or same else blob.decode("utf-8", "replace")
                if e["blobs"][rel] is not None:
                    out.append(("text", e["blobs"][rel], f"{rel} as {e['label']} leaves it"))
            return out

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
            if any(v and (v in ("--stdout", "--to-stdout") or re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", v))
                   for v in vals[1:]):
                return False  # -c, alone or bundled (gzip -dc): to its output, no file written
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
            except (OSError, tarfile.TarError, zipfile.BadZipFile, EOFError, ValueError, RuntimeError,
                    zlib.error, lzma.LZMAError, NotImplementedError):
                return None  # a corrupt or unsupported archive: every file it unpacks into is unreadable
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
            """tar_words for unzip: None where it lists, tests or prints (-l, -t, -p, -c, -Z, -z). The
            names after -x are members left out, up to the next option: `unzip a.zip -x n -d sub`
            unpacks into sub, which was read as unpacking under `.` (claude-config#2827)."""
            archive, dest_raw, dest, renames, k = None, ".", ".", False, 1
            excluding = False
            while k < len(vals):
                v = vals[k]
                if excluding and not (v is not None and v.startswith("-")):
                    k += 1
                    continue
                excluding = False
                if v is not None and v.startswith("-"):
                    if v == "-d":
                        if k + 1 < len(vals):
                            dest_raw, dest = args[k + 1], vals[k + 1]
                        k += 2
                        continue
                    if v.startswith("-d"):  # the folder glued on, -dsub
                        dest_raw, dest = v[2:], v[2:]
                        k += 1
                        continue
                    if v == "-x":
                        excluding = True  # names left out follow, up to the next option
                        k += 1
                        continue
                    if re.search(r"[ltpcZz]", v[1:]):
                        return None
                    renames = renames or "j" in v
                elif archive is None:
                    archive = v if v is not None else ""
                k += 1
            return (archive or None), dest_raw, dest, renames

    return ProgramWrites


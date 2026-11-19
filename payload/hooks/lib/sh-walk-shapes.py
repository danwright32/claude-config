"""Three shapes the Slack drafts gate's walk of a script's variables (Judge.sh_walk) could not follow,
for the gate (claude-config#2912).

Since #2911 a file sourced by a path the walk cannot work out is refused unread, and these three
shapes were refused that way however quiet the files they named:

  * A for loop over words written out, sourcing a path built from its name
    (`for f in a.sh b.sh; do . "$LIB/$f"; done`, tools/load-window.sh before #2911). The walk took
    the loop's name as unknown. Each value is now tried in turn (sh_for_loops, sh_source_each): the
    walk reads every file the loop sources, and the gate judges each of them. A word that is not
    written out (a glob, a variable, a substitution), a body that binds the name itself, or a sourced
    file that binds it leaves the path unknown, and it is refused as before.
  * NAME="$NAME" cmd inside a function, which sets NAME for that one command, was read as the
    function binding NAME, so a call to the function left NAME unknown (sh_one_command_sets, the
    count the walk already used for such assignments outside function bodies).
  * A call of a function of the script that evaluates its argument (`ev() { eval "$1"; }`) ended the
    walk, so every variable past it was unknown: a sourced path was then refused, and a file RUN by
    such a path (behind the #2683 switch, off) passed unread, a file that posts included. The
    function is now read as lib/hang-wait.sh's hang_wait is (sh_evaluator): a call whose argument is
    written out (in double quotes too, with every $, ` and " escaped) is followed as though written
    in its place, and what it evaluates is judged as a command line, so `ev "bash post.sh"` is
    refused as the post it is, through hang_wait too, where before it passed (sh_eval_text_reason).
    A call whose argument the gate cannot read still ends the walk: a sourced path past it is
    refused, and a file run past it stays behind the #2683 switch, which the gate suite pins for
    exactly this shape (Dan, 2026-11-10: "measure first").

slack_drafts_only_gate.py loads this file and gives its Judge the class make() returns as a base, as
it does lib/code-loaders.py's, so the methods use the Judge's own readers (rest_of, words_of,
raw_words, sh_tokens, sh_literal_word, sh_strip_openers, sh_binds, sh_source_word,
sh_source_target, sh_source_var, sh_cwd, sh_ctx_known, sh_eval_call, line, shell, unfollow, sw).

Since claude-config#3020 it also reads text handed to eval, to a shell's -c or to a function that
evaluates its argument through a variable or a substitution (handed_text_reason, with the comment
above it), using the Judge's sh_value, sh_word_end, pieces_of and pieces_reason as well.

Since claude-config#3213 it reads a process substitution a program is handed as the file it runs
(handed_procs), using the Judge's parsed, operands, proc_runs and pieces_reason.

Since claude-config#3229 it finds what a program that runs its input is handed by the text around
it, a pipe into the group, loop, subshell, substitution or string it is in or a file that is given
(held_input, with the comment above it), using the Judge's parsed, sh_struct_of, redirections,
written_redirs, input_redirs, stdin_of, sh_value, sh_prints and rest_of.
"""
import os
import re

# The most paths one source command is worked out to, across the values of the loops around it: past
# it the path is taken as unknown, and refused, rather than read once for each.
MAX_CHOICES = 64
# A word that is one substitution printing one file's text (text_of_file): $(cat F) or $(< F), or
# either in backquotes, the whole of the word, in double quotes or not. F is read as one shell word.
FILE_TEXT = re.compile(r'("?)(?:\$\(\s*(?:cat\s+|<\s*)([^()`]+?)\s*\)|`\s*(?:cat\s+|<\s*)([^()`]+?)\s*`)\1')
# A word that is one variable or positional parameter and nothing else, in double quotes or not.
LONE_NAME = re.compile(r'"?\$\{?([A-Za-z_]\w*|[0-9])\}?"?')
# The plain word a process substitution is written as while a command's words are read
# (handed_procs, claude-config#3213), by its place among those of the command, and how one is found.
PROC_WORD = "__gate_process_substitution_%d__"
PROC_MARK = re.compile(r"__gate_process_substitution_(\d+)__")
# Where a program's input comes from, as a refusal words it, when it is handed by what is written
# around the program and that could not be worked out (held_input, claude-config#3229).
HELD_FEED = "what feeds the group, loop, function, string or substitution it is in"
# What may stand between a pipe and the first command of what it feeds, read backwards from that
# command with the white space taken off (sh_pipe_into): the ( or { that opens a subshell or a group,
# and a word that opens or carries on a compound command.
PIPE_LEAD = re.compile(r"(?:(?<![\w$.-])(?:if|while|until|time)|[!({])\Z")
# The most texts inside one another held_feed reads, a subshell or a substitution each being read
# as a text of its own: past it the input is not worked out, and refused.
MAX_HELD = 8

# The shapes judge_unread_shapes reads (claude-config#3251). A command holding none of these is
# none of them.
UNREAD_HINT = re.compile(r"[$`\\]|/dev/|/proc/|xargs")
# A command's first word that names a shell: the variable a shell keeps its own path or name in
# (group 1; $0 only in a typed command), or a lookup of a program's path (groups 2 and 3).
SHELL_NAMED = re.compile(
    r'"?(?:\$\{?(SHELL|BASH|ZSH_NAME|0)(?![A-Za-z0-9_])(?::?-[^}]*)?\}?'
    r'|\$\(\s*(?:which|command\s+-v|type\s+-[pP])\s+([\w.+-]+)\s*\)'
    r'|`\s*(?:which|command\s+-v|type\s+-[pP])\s+([\w.+-]+)\s*`)"?(?=[\s;&|<>]|\Z)')
SHELL_NAMES = {"SHELL": ("bash", "zsh"), "0": ("bash", "zsh"), "BASH": ("bash",), "ZSH_NAME": ("zsh",)}
# A path that names a program's own input, or another descriptor it holds (group 1 or 2).
STDIN_PATH = re.compile(r"/dev/stdin|/dev/fd/(\d+)|/proc/self/fd/(\d+)")
# A first word that is one variable, an array's every element included, and one that is one command
# substitution and nothing else.
LONE_VAR = re.compile(r'"?\$\{?([A-Za-z_]\w*)(?:\[[@*]\])?\}?"?')
LONE_SUBST = re.compile(r'"?(?:\$\((?!\()[\s\S]*\)|`[^`]*`)"?')
# A command that fills variables from its input: the builtin, then its words up to what ends it.
READS = re.compile(r"(?:^|(?<=[\s;&|({]))(read|mapfile|readarray)(?=\s)([^;&|\n(){}]*)")
# xargs' options that take a value, glued or as the next word (as the shared reader's RUNNERS has
# them), and a backslash in front of a $ or a backquote.
XARGS_VALUED = "EIJLnPRSsad"
XARGS_LONGS = ("--arg-file", "--delimiter", "--max-args", "--max-procs", "--max-chars", "--process-slot-var",
               "--max-lines", "--eof")
ESCAPED_SUBST = re.compile(r"\\[$`]")
# Programs a package manager or a launcher is: run by xargs with nothing after them, the input
# names the script or the package.
XARGS_NAMED = {"npm", "pnpm", "yarn", "npx", "pnpx", "bunx"}


def make(sh_special, sh_param, unknown_dir=None):
    """The base class for the gate's Judge (module docstring). sh_special is its SH_SPECIAL, the
    builtins an assignment in front of lasts past, sh_param its SH_PARAM, and unknown_dir its
    SH_UNKNOWN_DIR."""

    class ShWalkShapes:
        def sh_one_command_sets(self, heads, funcs):
            """{NAME: how many times NAME=value stands in front of a command in heads}, counting only a
            command that is not a special builtin nor a function of the text (funcs), which run with
            it set: for any other it is set for that command alone, so it binds nothing that lasts.
            heads are the commands with the keywords that open a block taken off, so the first
            command of a function's body (`run() { LIB="$LIB" env`) is read as the command it is."""
            temp = {}
            for t in heads:
                rest_t, assigns = self.rest_of(t)
                words = self.words_of(rest_t)
                if words and words[0] not in sh_special and words[0] not in funcs:
                    for a in assigns.split("\n"):
                        n = a.split("=", 1)[0]
                        if a.strip() and re.fullmatch(r"[A-Za-z_]\w*", n):
                            temp[n] = temp.get(n, 0) + 1
            return temp

        def sh_for_loops(self, s, items, blocks):
            """Each loop of blocks written `for NAME in WORD...`, every word written out whole (quoted
            or plain, no glob, brace, tilde or expansion), whose body never binds NAME: (open, close,
            NAME, the words' values, where the loop starts, where it ends). The body is everything
            after the header to the done."""
            out = []
            for blk in blocks or ():
                if blk["kind"] != "loop" or blk["close"] is None:
                    continue
                o, c = blk["open"], blk["close"]
                head = self.sh_strip_openers(items[o][0][1])
                m = re.match(r"for\s+([A-Za-z_]\w*)\s+in(?=\s|$)", head)
                if not m:
                    continue
                toks = self.sh_tokens(head[m.end():])
                if toks and toks[-1] == ("op", ";"):
                    toks = toks[:-1]
                values = [self.sh_literal_word(raw) if kind == "word" else None for kind, raw in toks]
                if any(v is None for v in values):
                    continue
                body = s[items[o][1]["end"]:items[c][1]["end"]]
                if self.sh_binds(m.group(1), body):
                    continue
                out.append((o, c, m.group(1), values, items[o][1]["start"], items[c][1]["end"]))
            return out

        def sh_source_each(self, text, wd, var, script, loops, at):
            """The paths a source or . command reads, worked out once for each value of every loop of
            loops (sh_for_loops) around offset at whose name the path uses: a list of words, empty for
            a loop over no words, or None where any of them cannot be worked out, or there are more
            than MAX_CHOICES. var gives every other name's value, as sh_source_word takes it."""
            raw = self.sh_source_target(text) or ""
            used = {(a or b).split(":", 1)[0].split("%", 1)[0].split("#", 1)[0] for a, b in sh_param.findall(raw)}
            around = {}
            for o, c, name, values, start, end in loops:
                if start <= at < end and name in used:
                    around[name] = values  # an inner loop over the same name is the one that holds
            if not around:
                return None
            names = sorted(around)
            total = 1
            for n in names:
                total *= len(around[n])
            if total > MAX_CHOICES:
                return None
            # Every pick of one value per name, built by hand: an import of itertools would be one more
            # module the judgement cache must classify (test-judgement-cache.sh).
            picks = [{}]
            for n in names:
                picks = [{**p, n: v} for p in picks for v in around[n]]
            out = []
            for pick in picks:
                v, bad = self.sh_source_word(text, wd, lambda n, pick=pick: pick[n] if n in pick else var(n), script)
                if bad or v is None:
                    return None
                out.append(v)
            return out

        def sh_source_choices(self, text, d):
            """For the source or . command being judged: [(path, False)] for each file it reads, worked
            out from the script's variables, and from each value of a for loop around it that the
            walk of its variables followed (sh_walk's "each"); else [(None, True)] where its path
            cannot be worked out, or [(None, False)] for no path at all."""
            wd, script = self.sh_cwd(d), self.shell["script"]
            v, bad = self.sh_source_word(text, wd, self.sh_source_var, script)
            at = self.shell["at"]
            if not bad or at is None:
                return [(v, bad)]
            got = self.sh_source_each(text, wd, self.sh_source_var, script,
                                      self.sh_ctx_known().get("each", ()), at)
            return [(None, True)] if got is None else [(w, False) for w in got]

        def sh_eval_text_reason(self, text, d, depth):
            """The reason a call of a function that evaluates its argument in the caller's shell posts,
            judging each argument it evaluates, written out, as a command line; or None. The functions
            are the ones the walk of the text's variables found (its own, and those of the files it
            sources), each with the positions of the arguments it evaluates."""
            evals = self.shell["known"].get("evals") if self.shell.get("known") else None
            # Asked of every command: one that holds none of the names calls none of them, and is
            # passed over before its openers are cut (#2918).
            if not evals or not any(f in text for f in evals):
                return None
            head = self.sh_strip_openers(text)
            lits = self.sh_eval_call(head, evals)
            if lits is False:
                # A plain call with an argument that is not written out: read where the gate can read
                # it, and refused where it cannot (handed_text_reason, claude-config#3020).
                for raw in self.sh_eval_call(head, evals, raw=True) or ():
                    reason = self.handed_text_reason("a function that evaluates its argument", [raw], d, depth)
                    if reason:
                        return reason
                return None
            for lit in lits or ():
                try:
                    inner = self.line(lit, d, depth + 1, lit)
                except self.sw.Unreadable:
                    inner = self.unfollow(f"it evaluates {lit!r}, which the gate cannot read")
                if inner:
                    return f"{text.strip()[:120]} evaluates {lit!r} in this shell, and that posts: {inner}"
            return None

        # ---- Text handed to eval, a shell's -c or an evaluating function (claude-config#3020) --------
        # `X="$(cat cmd.txt)"; eval "$X"` ran a file's text with the file never read, and so did
        # `eval "$(cat cmd.txt)"`, `bash -c "$(cat cmd.txt)"` and a call of a function that evaluates
        # its argument, where the same text fed to a shell's input (`bash <<< "$(cat cmd.txt)"`,
        # claude-config#2887) was read. One reading now serves all of them (text_of_file, which the
        # here string reading uses too). Text handed through a variable or a substitution is:
        #   * judged as a command line where every word of it has a value the gate works out
        #     (`X='bash post.sh'; eval "$X"` passed);
        #   * read as the file it is where it is one file's text: $(cat F), $(< F) or the same in
        #     backquotes, straight or through a variable the text sets once from it, F worked out as
        #     any path is, and what an earlier command made F from counted (pieces_of);
        #   * and otherwise text the gate cannot read: a program's output, a variable set nowhere,
        #     a file whose path cannot be worked out. In the command itself that is refused, as input
        #     a shell reads that cannot be read is (fed_reason). Inside a script on disk, and in any
        #     string such a script evaluates, it is left as it was, whatever the #2683 switch says:
        #     the gate suite pins that for the string an eval runs (2026-11-12), and refusing it there
        #     would refuse 19 more of this repository's 563 tracked shell scripts (measured
        #     2026-11-15 by judging `bash <file>` for each with that refusal behind the switch, 201
        #     refused to 220, lib/issue-spool.sh's test seam and tools/prove-it-fails.sh among them).
        #     As shipped, none is newly refused (5 before and after, the same five).
        # Text written out, in single quotes too, is not handed text: its commands are read where they
        # are. A redirection on the command is the shell's and no word of the text.
        # A positional parameter is what a function or a script was handed: judged at each call of a
        # function the walk found to evaluate it (sh_eval_text_reason), and for a script on disk
        # where the script is handed something (the gate's acts reading).

        def text_of_file(self, raw, d):
            """For a raw word that is one substitution printing one file's text ($(cat F), $(< F), or
            either in backquotes, in double quotes or not): what the file holds, as pieces (pieces_of),
            or an unreadable piece where F cannot be worked out. None for any other word."""
            m = FILE_TEXT.fullmatch(raw or "")
            if not m:
                return None
            toks = self.sh_tokens((m.group(2) if m.group(2) is not None else m.group(3)).strip())
            if len(toks) != 1 or toks[0][0] != "word":
                return None
            path = self.sh_value(toks[0][1], d)
            if path is None or (not os.path.isabs(path) and self.sh_cwd(d) == unknown_dir):
                return [("unknown", None, f"the file {toks[0][1]}, whose path the gate cannot work out")]
            return self.pieces_of(path, d)

        def sh_set_from(self, name):
            """The value the text being read gives NAME, as written, where it sets it exactly once
            before the command being judged, by a plain NAME=value, and binds it no other way before
            then; else None."""
            at, text = self.shell.get("at"), self.shell.get("text") or ""
            if at is None:
                return None
            before = text[:at]
            found = list(re.finditer(r"(?:^|(?<=[\s;&|({]))" + re.escape(name) + r"=", before))
            if len(found) != 1 or self.sh_binds(name, before, 1):
                return None
            start = found[0].end()
            return before[start:self.sh_word_end(before, start)]

        def handed_text_reason(self, name, raws, d, depth):
            """The reason the text name (eval, a shell's -c, a function that evaluates its argument)
            is handed posts, or cannot be read, or None (the comment above). raws are the words of
            the text as written."""
            plain, k = [], 0
            while k < len(raws):
                # A redirection is the shell's, never a word of the text (as the Judge's operands reads it).
                m = self.sw.REDIRECT_WORD.match(raws[k])
                if m:
                    k += 1 if m.group(1) else 2
                    continue
                plain.append(raws[k])
                k += 1
            raws = plain[1:] if plain[:1] == ["--"] else plain
            if all(self.sh_literal_word(r) is not None for r in raws):
                # Written out, in single quotes too, where a $ is the text's own: its commands are
                # read where they are, with the positional parameters the shell is given.
                return None
            values = [self.sh_value(r, d) for r in raws]
            in_script = self.sh_in_script()
            pieces = None
            if all(v is not None for v in values):
                pieces = [("text", " ".join(values) + "\n", "")]
            elif len(raws) == 1:
                lone = LONE_NAME.fullmatch(raws[0])
                if lone and lone.group(1).isdigit():
                    evals = self.sh_ctx_known().get("evals") or {}
                    if in_script or any(int(lone.group(1)) in ns for ns in evals.values()):
                        return None  # what it was handed, judged where it is handed (the comment above)
                pieces = self.text_of_file((self.sh_set_from(lone.group(1)) or "") if lone else raws[0], d)
            if in_script:
                # A script's own: what can be read is, and the rest is left as it was (the comment above).
                pieces = [p for p in pieces or () if p[0] != "unknown"]
                if not pieces:
                    return None
            shown = " ".join(raws)[:120]

            def unread(came):
                return (f"{name} is handed {shown}, text the gate cannot read before the command runs{came}, so "
                        "whether it posts cannot be checked. Write the commands out, or put them in a script "
                        "and run that")

            if pieces is None:
                return self.unfollow(unread(""))
            return self.pieces_reason(name, pieces, d, depth, True, None, "runs the text it is handed",
                                      "runs commands from the text it is handed", unread)

        def handed_procs(self, name, text, past, d, depth):
            """The reason a process substitution the program name is handed as the file it runs
            posts, or cannot be read, or None (claude-config#3213). `bash <(cat post.sh)`, `source
            <(cat post.sh)`, `bash < <(cat post.sh)`, `python3 <(cat post.py)`, zsh's `zsh =(cat
            post.sh)` and `curl -K <(cat curlrc)` each passed on 2026-11-18: the program runs what
            the commands inside print, and no word of the command names a file to read.

            Which programs, and which of their words, is the Judge's proc_runs: one written where
            the script goes, or before it, is read; one after the script or after code given by an
            option is an argument, data to the script, and left as a pipe into that script is. past
            is how many words judge() stepped over for a launcher. What one prints is what line()
            kept for it (shell "procs_here"): the output of its one command where the gate works
            that out, as it does for a pipe, a file by what it holds and text as the commands or
            code it is. Anything else, more than one command inside, a program whose output the
            gate does not read, a command a wrapper's string holds, is unread and refused, except
            in a script on disk or the text one evaluates, where what cannot be read is left as it
            is for a pipe there (handed_text_reason's rule)."""
            if "<(" not in text and "=(" not in text:
                return None
            how = self.proc_runs(name)
            if how is None:
                return None
            try:
                tops = [p for p in self.parsed(text, "")[1] if p["scope"] == (0,)]
            except self.sw.Unreadable:
                return None
            if len(tops) != 1:
                return None
            spans = sorted((a, b) for a, b, _ in tops[0]["inner"] if text.startswith(("<(", "=("), a))
            if not spans:
                return None
            # The command with each one written as a single plain word, so the program's words are
            # read as they are for any other command.
            flat, at = [], 0
            for n, (a, b) in enumerate(spans):
                flat += [text[at:a], PROC_WORD % n]
                at = b
            words = self.words_of(self.rest_of("".join(flat) + text[at:])[0])[past:]
            if len(words) < 2:
                return None
            slot, shell_hint, lang = how
            if slot == "first":
                run = words[1:2]
            elif slot == "config":
                run = [w for k, w in enumerate(words) if k and (
                    re.match(r"--config=|-[A-Za-z]*K", w) or re.fullmatch(r"--config|-[A-Za-z]*K", words[k - 1]))]
            else:
                operand, inline, _ = self.operands(words)
                if inline:
                    run = inline[0]
                elif operand and operand != "-":
                    # The script's place is the first word at which the Judge's own reading finds
                    # it, never a search of the words for its text: `-o` holds `o`, so in `bash -o
                    # <(cat post.sh) o` the search stopped at the option and the substitution, its
                    # value, was left out of what is read; and a word equal to the script can be an
                    # earlier option's value or a later argument. With no place found, every word
                    # is read.
                    k = next((k for k in range(1, len(words)) if self.operands(words[:k + 1])[0] == operand), None)
                    if k is None:
                        run = words[1:]
                    else:
                        run = words[1:k + 1] if PROC_MARK.search(operand) else words[1:k]
                else:
                    run = words[1:]
            held = self.shell.get("procs_here")
            if held is None or len(held) != len(spans) or any(text[a:b] != t for (a, b), (t, _) in zip(spans, held)):
                held = [(None, None)] * len(spans)  # not the command line() is reading: nothing kept
            in_script = self.sh_in_script()
            for n in sorted({int(n) for w in run for n in PROC_MARK.findall(w)}):
                if n >= len(spans):
                    continue
                pieces = held[n][1]
                if pieces is None:
                    pieces = [("unknown", None, "")]
                if in_script:
                    pieces = [p for p in pieces if p[0] != "unknown"]
                shown = text[spans[n][0]:spans[n][1]][:120]

                def unread(came, shown=shown):
                    return (f"{name} is handed {shown}, and what the commands inside it print cannot be read "
                            f"before the command runs{came}, so whether it posts cannot be checked. Hand it the "
                            "file by name, or write the commands out")

                verb = "reads its request from what" if slot == "config" else "runs what"
                what = "what" if slot == "config" else "the commands" if shell_hint else "the code"
                reason = self.pieces_reason(name, pieces, d, depth, shell_hint, lang, f"{verb} {shown} prints",
                                            f"{verb.rsplit(' ', 1)[0]} {what} {shown} prints", unread)
                if reason:
                    return reason
            return None

        def sh_in_script(self):
            """Whether the text being read is a script on disk, or text one evaluates: a string its
            eval, its shell's -c or a function of it runs, however many deep, by the texts that run
            this one (the Judge's line keeps each as the parent of the text it runs)."""
            sh = self.shell
            while sh:
                if sh.get("on_disk"):
                    return True
                sh = sh.get("parent")
            return False

        # What the text around a program hands it as its input (claude-config#3229). A shell or an
        # interpreter given no script, and no pipe or file of its own, reads whatever the shell
        # around it is reading: measured 2026-11-18 in bash 3.2.57 and zsh 5.9, `cat F | (true;
        # bash)`, `cat F | { true; bash; }`, `cat F | while true; do bash; break; done`, `{ bash; }
        # < F`, `cat F | bash -c bash`, `bash -c 'cat F | bash'` and `cat F | echo $(bash)` (bash
        # only) each ran F's text. The gate asked only whether a pipe stood right before the
        # program's own name, so each passed where `cat F | bash` is refused. held_input finds what
        # feeds the nearest thing around the program that is fed, and fed_pieces reads it as the
        # program's own input is read.

        @staticmethod
        def held_unknown(label=HELD_FEED):
            return [("unknown", None, label)]

        def sh_given(self, d, text, start, whole):
            """What the redirections of one command's text give it as its input, as pieces, or None
            where it has none: a file, a here string or a heredoc, read as stdin_of reads the
            command being judged. start is where the command is in the text line() is reading, so
            its words are worked out with the variables as they stand there; None for a command of
            a wrapper's string, read where the wrapper is."""
            redirs = self.input_redirs(text)
            if not redirs:
                return None
            saved = self.shell.get("at")
            if start is not None:
                self.shell["at"] = start
            try:
                pieces = self.stdin_of(d, text, whole, redirs, own=False)
            finally:
                self.shell["at"] = saved
            return self.held_unknown() if pieces is None else pieces

        def sh_printed(self, d, text, start, whole):
            """What one command sends down the pipe after it, as pieces: exactly its words or the
            files it names for printf, echo and cat (the Judge's sh_prints), and one unreadable
            piece named after the program for anything else, a process substitution among its
            words, or an output sent somewhere else. start as sh_given takes it."""
            args, redirs, odd = self.redirections(text)
            saved = self.shell.get("at")
            if start is not None:
                self.shell["at"] = start
            try:
                vals = [self.sh_value(a, d) for a in args]
                name = os.path.basename(vals[0]) if vals and vals[0] is not None else None
                while name in ("builtin", "command") and len(vals) > 1 and not args[1].startswith("-"):
                    args, vals = args[1:], vals[1:]
                    name = os.path.basename(vals[0]) if vals[0] is not None else None
                out = None
                if not odd and name and not any(re.fullmatch(r"(?:1|&)?(?:>>|>\||>&|>)", op) for op, _ in redirs):
                    out = self.sh_prints(name, args, vals, d, self.stdin_of(d, text, whole, redirs, own=False))
            finally:
                self.shell["at"] = saved
            return self.held_unknown(name or "a command") if out is None else out

        def sh_pipe_into(self, s, items, x, base, whole):
            """What a pipe feeds the command, group or subshell starting at x in s, as pieces, or
            None where no pipe stands before it. The pipe is looked for past the ( or { and the
            words that open a compound command, since the first command of `cat F | { (bash); }`
            and of `cat F | time (bash)` starts after them. What it carries is what the command
            ending at the pipe prints (sh_printed); where a group or a subshell ends there, that is
            not worked out. items are s's commands as parsed gives them, base where s starts in
            the text line() is reading (None for a wrapper's string)."""
            end = x
            while True:
                while end and s[end - 1].isspace():
                    end -= 1
                m = PIPE_LEAD.search(s, max(0, end - 8), end)
                if not m:
                    break
                end = m.start()
            if s.endswith("|&", 0, end):
                pipe = end - 2
            elif s.endswith("|", 0, end) and not s.endswith("||", 0, end):
                pipe = end - 1
            else:
                return None
            feeder = None
            for (fd, ft), fp in items:
                if fp["how"] == "|" and fp["end"] <= pipe and (feeder is None or fp["end"] > feeder[2]["end"]):
                    feeder = (fd, ft, fp)
            if feeder is None or s[feeder[2]["end"]:pipe].strip():
                return self.held_unknown()
            fd, ft, fp = feeder
            return self.sh_printed(fd, ft, None if base is None else base + fp["start"], whole)

        def held_calls(self, s, cwd, items, b, base, whole, hops, seen):
            """What the body of the function b (a block of the Judge's sh_struct) is handed as its
            input, as pieces that always end with one unreadable piece. A function's body reads
            what each call of it is given, and every way a function can be called is not worked
            out (a name held in a variable, `"$@"`, a trap, a file that sources this one), so the
            answer is never that nothing feeds it: typed, a program that runs its input in a
            function body is refused as unread, as it was. But an unreadable piece is left alone in
            a script on disk, so that piece alone let a script on disk hand its function a script
            that posts (`f() { bash; }` then `cat post.sh | f`, measured 2026-11-18: exit 0). So
            before it come the pieces that can be read: the file, here string or heredoc written
            on the function's definition (`f() { bash; } < post.sh`), and for each command of s
            outside the body whose first word is the function's name, what that call is given, the
            pipe into it, or what is around it (held_feed: a group, a subshell, an if, another
            function that calls it). Each function's calls are read once for one program (seen,
            the functions already read, by their text and where they open): functions that call
            each other end there, and a script of many functions calling many others is not read
            once for every path through them. items, base and whole as held_feed takes them."""
            def placed(x):
                return None if base is None else base + x

            def readable(got):
                return [piece for piece in got or () if piece[0] != "unknown"]

            if (s, b["open"]) in seen:
                return self.held_unknown()
            seen.add((s, b["open"]))
            (cd, ct), cp = items[b["close"]]
            pieces = readable(self.sh_given(cd, ct, placed(cp["start"]), whole))
            name = b.get("name")
            for j, ((jd, jt), jp) in enumerate(items) if name and hops < MAX_HELD else ():
                if b["open"] <= j <= b["close"]:
                    continue
                words = self.written_redirs(jt)[0]
                while words and re.fullmatch(r"[A-Za-z_]\w*\+?=.*", words[0], re.S):
                    words = words[1:]
                if not words or words[0] != name:
                    continue
                got = self.sh_given(jd, jt, placed(jp["start"]), whole)
                if got is None:
                    got = self.sh_pipe_into(s, items, jp["start"], base, whole)
                if got is None:
                    got = self.held_feed(s, cwd, j, base, whole, hops + 1, seen)
                pieces += readable(got)
            return pieces + self.held_unknown()

        def held_feed(self, s, cwd, k, base, whole, hops=0, seen=None):
            """What the text s hands its command k (by its place in parsed's order) as its input,
            from what is written around the command, as pieces, or None where nothing there feeds
            it. Nearest first: the subshell or command substitution it is in, read as a text of its
            own and then by the file its closing ) is given, the pipe into it, or for a
            substitution what feeds the command holding it; then each group, loop, if or case
            around that (the Judge's sh_struct), by the file its closing word is given or the pipe
            into its opening one; then an `exec < file` earlier in s, which gives every later
            command that file. A function's body is fed by whatever calls it: what its calls in s
            are given where that can be read, and always one unreadable piece (held_calls). A
            structure that cannot be read is one unreadable piece. base is where s starts in the
            text line() is reading, None for a wrapper's string."""
            cmds, parts = self.parsed(s, cwd)
            items = list(zip(cmds, parts))
            p = parts[k]
            lo_i = hi_i = k
            seen = set() if seen is None else seen

            def placed(x):
                return None if base is None else base + x

            if len(p["scope"]) > 1:
                frame = p["scope"][1]
                while lo_i and len(parts[lo_i - 1]["scope"]) > 1 and parts[lo_i - 1]["scope"][1] == frame:
                    lo_i -= 1
                while hi_i + 1 < len(parts) and len(parts[hi_i + 1]["scope"]) > 1 and parts[hi_i + 1]["scope"][1] == frame:
                    hi_i += 1
                lo = min(q["start"] for q in parts[lo_i:hi_i + 1])
                hi = max(q["end"] for q in parts[lo_i:hi_i + 1])
                o = lo - 1
                while o >= 0 and s[o].isspace():
                    o -= 1
                if o < 0 or s[o] not in "(`" or hops >= MAX_HELD:
                    return self.held_unknown()
                inner = s[o + 1:hi]
                ik = next((j for j, q in enumerate(self.parsed(inner, cmds[k][0])[1])
                           if q["start"] == p["start"] - o - 1 and q["end"] == p["end"] - o - 1), None)
                if ik is None:
                    return self.held_unknown()
                got = self.held_feed(inner, cmds[k][0], ik, placed(o + 1), whole, hops + 1, seen)
                if got is not None:
                    return got
                after = next((j for j in range(hi_i + 1, len(parts)) if len(parts[j]["scope"]) == 1), None)
                if s[o] == "`" or s[o - 1:o] == "$":
                    # A command substitution reads what the command it is written in reads.
                    if after is None or not any(a <= o and hi <= b for a, b, _ in parts[after]["inner"]):
                        return self.held_unknown()
                    got = self.sh_given(cmds[after][0], cmds[after][1], placed(parts[after]["start"]), whole)
                    if got is None:
                        got = self.sh_pipe_into(s, items, parts[after]["start"], base, whole)
                    if got is not None:
                        return got
                    lo_i = hi_i = after
                elif s[o - 1:o] in ("<", ">", "="):
                    return self.held_unknown()  # a process substitution, whose input is not worked out (#3213)
                else:
                    # A subshell: the redirections written straight after its ), then the pipe into it.
                    region = s[hi:parts[after]["start"] if after is not None else len(s)]
                    m = re.match(r"[\s;&]*\)", region)
                    if not m:
                        return self.held_unknown()
                    if after is not None and m.end() == len(region):
                        got = self.sh_given(cmds[after][0], cmds[after][1], placed(parts[after]["start"]), whole)
                        if got is not None:
                            return got
                    got = self.sh_pipe_into(s, items, o, base, whole)
                    if got is not None:
                        return got
            struct = self.sh_struct_of(s, cwd, items)
            if struct is None or any(b["close"] is None for b in struct[1]):
                return self.held_unknown()
            around = [(b["open"], n, b) for n, b in enumerate(struct[1]) if b["open"] <= lo_i and hi_i < b["close"]]
            for _, _, b in sorted(around, key=lambda x: x[:2], reverse=True):
                if b["kind"] == "func":
                    return self.held_calls(s, cwd, items, b, base, whole, hops, seen)
                got = self.sh_given(cmds[b["close"]][0], cmds[b["close"]][1], placed(parts[b["close"]]["start"]), whole)
                if got is None:
                    got = self.sh_pipe_into(s, items, parts[b["open"]]["start"], base, whole)
                if got is not None:
                    return got
            if "exec" in s:
                for j in range(lo_i - 1, -1, -1):
                    if "exec" in cmds[j][1] and self.written_redirs(cmds[j][1])[0] == ["exec"]:
                        got = self.sh_given(cmds[j][0], cmds[j][1], placed(parts[j]["start"]), whole)
                        if got is not None:
                            return got
            return None

        def held_input(self, whole):
            """What a program that runs its input, given no pipe or file of its own, is handed by
            what is written around it, as pieces fed_pieces reads as it reads the program's own, or
            None where nothing around it feeds it (claude-config#3229). The command is the one
            line() is reading (shell "where"). For a command of a string a wrapper runs (a shell's
            -c, eval, find -exec), innermost string first: the pipe before it in the string, what
            is around it there (held_feed), then what the wrapper itself is given, a file or a
            pipe, or handed by what is around the wrapper. For a command of the text itself: what
            is around it (held_feed). Anything of this that cannot be read is one unreadable piece,
            refused as a pipe the gate cannot read is."""
            where = self.shell.get("where")
            if not where:
                return None
            k, wraps = where
            s, cwd = self.shell["text"], self.shell["cwd"]
            try:
                for i in range(len(wraps) - 1, -1, -1):
                    _, wtext, wd, n = wraps[i]
                    found = self.sw.wrapped(self.rest_of(wtext)[0])
                    string = found[1] if found else None
                    if string is None:
                        return self.held_unknown()
                    cmds, parts = self.parsed(string, wd)
                    if not 0 <= n < len(parts):
                        return self.held_unknown()
                    if i < len(wraps) - 1:
                        got = self.sh_given(wraps[i + 1][2], wraps[i + 1][1], None, string)
                        if got is not None:
                            return got
                    got = self.sh_pipe_into(string, list(zip(cmds, parts)), parts[n]["start"], None, string)
                    if got is None:
                        got = self.held_feed(string, wd, n, None, string)
                    if got is not None:
                        return got
                if wraps:
                    got = self.sh_given(wraps[0][2], wraps[0][1], self.shell.get("at"), whole)
                    if got is not None:
                        return got
                    if k is None:
                        return self.held_unknown()
                    cmds, parts = self.parsed(s, cwd)
                    got = self.sh_pipe_into(s, list(zip(cmds, parts)), parts[k]["start"], 0, whole)
                    if got is not None:
                        return got
                return None if k is None else self.held_feed(s, cwd, k, 0, whole)
            except self.sw.Unreadable:
                return self.held_unknown()

        # A shell, its code or its script named another way (claude-config#3251, the shapes #3229
        # left open). Each passed on 2026-11-18 with a file that posts: `$SHELL posts`, `cat posts.sh
        # | bash /dev/stdin`, `cat posts.sh | { read -r l; $l; }`, `cat posts.sh | xargs -0 bash -c`
        # and `bash -c "echo \$(bash posts.sh)"`. judge_unread_shapes is one more reading of a
        # command, after the Judge's own, so it can refuse a command those let through and never
        # the reverse. What it cannot read is refused where typed and left alone in a script on
        # disk, as an unread feed is.

        def judge_unread_shapes(self, d, text, wrapper, depth, whole):
            """The reason one command posts by one of those shapes, or None."""
            if not UNREAD_HINT.search(text) or self.reshaping >= 4:
                return None
            rest = self.sw.join_continuations(self.rest_of(text)[0])
            self.reshaping += 1
            try:
                return (self.named_shell(d, text, rest, depth, whole)
                        or self.stdin_named(d, text, rest, depth, whole)
                        or self.line_run(d, text, rest, depth, whole)
                        or self.xargs_built(d, text, rest, depth, whole)
                        or self.escaped_string(d, text, rest, depth))
            finally:
                self.reshaping -= 1

        reshaping = 0  # how many of these readings are inside one another
        reads_memo = {}  # the read commands of each text, for read_feed (one Judge runs in a process)

        def inner_line(self, s, d, depth):
            """line() for a text one of these readings puts together, read as typed or as a script
            on disk's own as the command it comes from is; the reason it posts, or None, or that it
            is too deep to read."""
            if depth >= self.pkg_max_depth:
                return self.unread_typed(f"a command is put together more than {self.pkg_max_depth} texts deep, "
                                         "which is not read, so whether it posts cannot be checked")
            self.next_on_disk = self.sh_in_script()
            try:
                return self.line(s, d, depth + 1, s)
            except self.sw.Unreadable:
                return self.unread_typed(f"the command {s[:80]} cannot be read as commands, so whether it "
                                         "posts cannot be checked")
            finally:
                self.next_on_disk = False

        def rejudge(self, d, new, text, depth, whole):
            """The reason the command new posts, or None: text with its program written as the
            program it is, judged as that program is. A string a shell is handed there is read as
            a command line here, since the reader gave its commands to nobody under the name as
            written (as judge_unglued reads one); what feeds the command is found by text."""
            wrapper, string, why = self.sw.wrapped(self.rest_of(new)[0]) or ("", None, "")
            if string is not None and not why:
                inner = self.inner_line(string, d, depth)
                if inner:
                    return f"{wrapper} runs a string, one of whose commands posts: {inner}"
            return self.judge_written(d, new, wrapper, why, depth, whole, text) or self.judge_unglued(d, new, depth, whole)

        def named_shell(self, d, text, rest, depth, whole):
            """The reason a command whose program is $SHELL, $BASH, $ZSH_NAME, $0 where typed, or a
            lookup of a program's path (`$(which bash)`), posts, or None: judged as that program
            given the same words. $SHELL and $0 name whichever shell the person uses, so they are
            judged as bash and as zsh, which read a file with a NUL in its first line differently."""
            m = SHELL_NAMED.match(rest)
            if not m:
                return None
            if m.group(1):
                if m.group(1) == "0" and self.sh_in_script():
                    return None  # a script's own name, which runs the script again
                names = SHELL_NAMES[m.group(1)]
            else:
                names = (m.group(2) or m.group(3),)
            for name in names:
                reason = self.rejudge(d, name + rest[m.end():], text, depth, whole)
                if reason:
                    return f"{m.group(0)} is the program {name}: {reason}"
            return None

        def stdin_named(self, d, text, rest, depth, whole):
            """The reason a shell, an interpreter, source or . handed a path that names its own
            input (/dev/stdin, /dev/fd/0, /proc/self/fd/0) as the file it runs posts, or None: judged
            as the program reading its input (`bash -s`, `python3 -`), so what feeds it is read as
            its script is. Another descriptor (/dev/fd/3) is read where the same command opens it
            from a file (`3< file`), and is unread anywhere else."""
            if not STDIN_PATH.search(rest):
                return None
            words = self.words_of(rest)
            name = os.path.basename(words[0]) if words else ""
            sourced = name in ("source", ".")
            fam = None if sourced else self.family(name)
            if not sourced and not fam:
                return None
            operand = (words[1] if len(words) > 1 else None) if sourced else self.operands(words)[0]
            m = STDIN_PATH.fullmatch(operand or "")
            if not m:
                return None
            fd = m.group(1) or m.group(2) or "0"
            new = rest
            if fd != "0":
                opened = re.search(r"(?<![\w$/.-])" + fd + r"<(?![<&>])", rest)
                if not opened:
                    return self.unread_typed(
                        f"{name} runs {operand}, a descriptor this command does not open from a file, so what "
                        "it holds cannot be read and whether it posts cannot be checked. Hand it the file by name")
                new = rest[:opened.start()] + rest[opened.start() + len(fd):]
            at = new.find(operand)
            new = ("sh -s" if sourced else new[:at] + ("-s" if fam == "shell" else "-")) + new[at + len(operand):]
            reason = self.rejudge(d, new, text, depth, whole)
            return f"{name} is handed its input as the file {operand}: {reason}" if reason else None

        def line_run(self, d, text, rest, depth, whole):
            """The reason a command that is text read from somewhere else posts, or None: one named
            by a variable that read, mapfile or readarray fills earlier in the text, which runs the
            line that was read, and one that is a whole command substitution, which runs what the
            substitution prints (`$(cat F)` runs F's text). What was read is judged as commands: the
            file the read is given, or what feeds the command, as a shell's input is read."""
            ticked = re.match(r'"?`[^`]*`"?(?=[\s;&|<>]|\Z)', rest)
            first = ticked.group(0) if ticked else rest[:self.sh_word_end(rest, 0)]
            if not first or SHELL_NAMED.match(rest):
                return None
            shown = first[:60]

            def unread(came):
                return (f"the command {shown} is text read as the command runs{came}, which cannot be read "
                        "before it runs, so whether it posts cannot be checked. Write the command out")

            var = LONE_VAR.fullmatch(first)
            if var:
                pieces = self.read_feed(var.group(1), d, text, whole)
                if pieces is None:
                    return None
            elif LONE_SUBST.fullmatch(first):
                pieces = self.text_of_file(first, d) or [("unknown", None, "a command substitution")]
            else:
                return None
            return self.pieces_reason(f"the command {shown}", pieces, d, depth, True, None,
                                      "is text read from a file, which it runs",
                                      "is text that was read, run as commands", unread)

        def read_feed(self, name, d, text, whole):
            """What the read, mapfile or readarray that fills the variable name reads, as pieces, or
            None where the text being read has none before this command or nothing feeds it. Its
            own file or here string where it has one; else what feeds this command, which stands
            in the same group or loop in every form measured; else, where the text holds a pipe or
            an input at all, one unreadable piece."""
            s, at = self.shell.get("text") or "", self.shell.get("at")
            # Each text's reads are found once: a large script asks this of every command it names
            # by a variable.
            reads = self.reads_memo.get(s)
            if reads is None:
                if len(self.reads_memo) > 64:
                    self.reads_memo.clear()
                reads = self.reads_memo[s] = [
                    (m, frozenset(re.findall(r"[A-Za-z_]\w*", m.group(2).split("<", 1)[0])))
                    for m in READS.finditer(s)] if "read" in s or "mapfile" in s else []
            found = None
            for m, names in reads:
                if name in names and (at is None or m.start(1) < at):
                    found = m
            if found is None:
                return None
            got = self.sh_given(d, found.group(0), found.start(1), whole)
            if got is None:
                got = self.fed_pieces(d, text, whole)
            if got is None or got is False:
                got = self.held_unknown("what the read before it reads") if re.search(r"\||<", s) else None
            return got

        def xargs_built(self, d, text, rest, depth, whole):
            """The reason a shell, an interpreter, a package manager or a launcher run by xargs
            posts through what xargs reads, or None. xargs adds the words of its input to the end
            of the command, or with -I, -J or -i puts each line where the command writes the mark,
            so the input can be the shell's code (`xargs -0 bash -c`, `xargs -I{} sh -c '{}'`) or
            name the script it runs (`xargs bash`). Where what feeds xargs can be read (fed_pieces)
            each command it puts together is judged as a line. Where it cannot, the typed command is
            refused only when the input is the code or names what runs; a script written in the
            command and handed words nobody can read is judged as before, as any command handed a
            word of unknown value is."""
            if "xargs" not in text:
                return None
            passed = []
            self.sw.command_rest(text, passed)
            if not any(os.path.basename(n) == "xargs" for n, _ in passed):
                return None
            words = self.words_of(rest)
            name = os.path.basename(words[0]) if words else ""
            fam = self.family(name)
            if not fam and name not in XARGS_NAMED:
                return None
            try:
                toks = self.sw.shell_split(self.sw.join_continuations(text))
            except ValueError:
                return None
            k = next((i for i, t in enumerate(toks) if os.path.basename(t) == "xargs"), None)
            if k is None:
                return None
            marks, nul, per_item, arg_file, i = [], False, False, None, k + 1
            while i < len(toks) and toks[i].startswith("-") and len(toks[i]) > 1:
                t = toks[i]
                i += 1
                if t == "--":
                    break
                if t.startswith("--"):
                    opt, eq, val = t.partition("=")
                    if not eq and opt in XARGS_LONGS and i < len(toks):
                        val = toks[i]
                        i += 1
                    if opt == "--replace":
                        marks.append(val or "{}")
                    nul = nul or opt == "--null"
                    per_item = per_item or opt in ("--max-args", "--max-lines")
                    arg_file = val if opt == "--arg-file" else arg_file
                    continue
                for j in range(1, len(t)):
                    c = t[j]
                    if c in XARGS_VALUED:
                        val = t[j + 1:]
                        if not val and i < len(toks):
                            val = toks[i]
                            i += 1
                        if c in "IJ":
                            marks.append(val)
                        per_item = per_item or c in "nL"
                        arg_file = val if c == "a" else arg_file
                        break
                    if c == "i":
                        marks.append(t[j + 1:] or "{}")
                        break
                    nul = nul or c == "0"
            marks = [m for m in marks if m]

            def marked(w):
                return any(m in w for m in marks)

            # Whether the input is the code or names what runs.
            if fam:
                operand, inline, _ = self.operands(words)
                if inline and inline[1]:
                    need = marked(inline[1])
                elif inline or operand is None or operand == "-":  # -c with no code after it, or no script
                    need = not marks or any(marked(w) for w in words[1:])
                else:
                    need = marked(operand)
            else:
                plain = [w for w in words[1:] if not w.startswith("-")]
                need = any(marked(w) for w in words[1:]) or (not marks and all(
                    w in ("run", "run-script", "exec", "x", "dlx") for w in plain))
            pieces = self.pieces_of(arg_file, d) if arg_file else self.fed_pieces(d, text, whole)
            if pieces is False:
                return None  # nothing in the command feeds it
            data, came = [], None
            for kind, value, label in pieces or [("unknown", None, "")]:
                if kind == "text":
                    data.append(value or "")
                elif kind == "file":
                    try:
                        data.append(self.content(value).decode("utf-8", "replace"))
                    except OSError:
                        came = label or value
                else:
                    came = label or "a command the gate does not read"
            if came is None:
                data = "".join(data)
                if nul:
                    items = [x for x in data.split("\0") if x.strip()]
                elif marks:
                    items = [x.strip() for x in data.split("\n") if x.strip()]
                else:
                    try:
                        items = self.sw.shell_split(data)
                    except ValueError:
                        items = data.split()
                if len(items) > MAX_CHOICES:
                    came = f"more than {MAX_CHOICES} words or lines"
            if came is not None:
                if not need:
                    return None
                return self.unread_typed(
                    f"xargs puts what it reads on its input into what {name} runs, and that input, which comes "
                    f"from {came}, cannot be read, so whether it posts cannot be checked. Hand {name} the "
                    "script by name, or write the command out")
            if marks:
                runs = [[self.xargs_marked(w, marks, item) for w in words] for item in items]
            else:
                runs = [words + items] + ([words + [item] for item in items] if per_item and len(items) > 1 else [])
            for run in runs:
                inner = self.inner_line(" ".join(self.sh_quoted(w) for w in run), d, depth)
                if inner:
                    return f"xargs runs {name} with what it reads on its input: {inner}"
            return None

        @staticmethod
        def xargs_marked(word, marks, item):
            for m in marks:
                word = word.replace(m, item)
            return word

        @staticmethod
        def sh_quoted(word):
            """word as one word of a command line, in single quotes where it needs them."""
            if word and re.fullmatch(r"[\w@%+=:,./-]+", word):
                return word
            return "'" + word.replace("'", "'\"'\"'") + "'"

        @staticmethod
        def sh_inner_value(raw):
            """One word as written, as the shell hands it on: quotes taken off, and inside double
            quotes or bare a backslash taken off what it escapes, so `"echo \\$(x)"` is `echo $(x)`.
            A variable or a substitution stays as written."""
            out, i, n = [], 0, len(raw)
            while i < n:
                c = raw[i]
                if c == "'":
                    j = raw.find("'", i + 1)
                    j = n if j < 0 else j
                    out.append(raw[i + 1:j])
                    i = j + 1
                elif c == '"':
                    i += 1
                    while i < n and raw[i] != '"':
                        if raw[i] == "\\" and i + 1 < n and raw[i + 1] in '$`"\\\n':
                            out.append("" if raw[i + 1] == "\n" else raw[i + 1])
                            i += 2
                        else:
                            out.append(raw[i])
                            i += 1
                    i += 1
                elif c == "\\" and i + 1 < n:
                    out.append("" if raw[i + 1] == "\n" else raw[i + 1])
                    i += 2
                else:
                    out.append(c)
                    i += 1
            return "".join(out)

        def escaped_string(self, d, text, rest, depth):
            """The reason a string handed to a shell's -c or to eval posts once the backslashes the
            outer shell takes off are off, or None. In `bash -c "echo \\$(bash post.sh)"` the inner
            shell is handed `echo $(bash post.sh)` and runs post.sh. The shared reader keeps the
            backslash, so the substitution is text to every other reading. Only a string holding a
            backslash in front of a $ or a backquote is read again."""
            if not ESCAPED_SUBST.search(text):
                return None
            found = self.sw.wrapped(rest)
            if not found or found[1] is None:
                return None
            raws = self.raw_words(text)
            if found[0] == "eval":
                code = [r for r in raws[1:] if r != "--"]
            elif found[0].endswith(" -c"):
                inline = self.operands(raws)[1] if raws else None
                code = [inline[1]] if inline else []
            else:
                return None
            if not any(ESCAPED_SUBST.search(r) for r in code):
                return None
            value = " ".join(self.sh_inner_value(r) for r in code)
            if value == found[1]:
                return None
            inner = self.inner_line(value, d, depth)
            return (f"{found[0]} runs a string whose substitution is written with a backslash, which the shell "
                    f"it is handed to runs: {inner}") if inner else None

    return ShWalkShapes

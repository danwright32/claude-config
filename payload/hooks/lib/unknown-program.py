#!/usr/bin/env python3
"""The words written after a program the Slack drafts gate does not know, judged as a command
(claude-config#3277).

The gate reads a command by its program's name: a shell, an interpreter, a launcher, a package
manager, a sender, and past the runners the shared reader knows (env, time, nice, xargs and the
rest of its RUNNERS). A program it has no rule for was a command that runs nothing, so the words
after it were never read: asked on 2026-11-18, the installed gate refused `node --test
test/notify.test.js`, a test file whose imports reach code able to post, and allowed the same
words after `op run --`, after `dotenv --` and after `sandbox-exec -f <profile>` by bare name and
by its /usr/bin path. The first two load secrets into the environment and then run the file. A
request sent by curl to the posting endpoint passed the same way.

THE RULE (Judge.judge_behind_unknown), one more reading of a command after the ones there were, so
it can refuse a command those let through and never the reverse:

  * The command's program, past any runner the reader reads past, is one the gate does not read by
    its name and does not know to be unable to run the words it is handed. That second question is
    the one a shell script's own commands are already asked (Judge.sh_command_acts), and it is
    asked here through that same code, never a second list (L96, L370): echo, grep, cat and the
    rest of SH_INERT by bare name or from a system folder, a git subcommand that only reads, find
    with no -exec, awk whose program runs nothing, and a script the gate reads and sees unable to
    act on what it is handed are known. Every other program is not: op, dotenv, sandbox-exec,
    docker, a program named by a variable, a script that runs its arguments. No list of programs
    that run their words is kept, because a program missing from one would pass.
  * A function the text being read defines is asked the question a script on disk is asked
    (shell_acts), of its body (function_acts, claude-config#3304): one whose body runs what it
    is handed ("$@", eval, a shell's -c), or hands it to a program or to another function of
    the text not seen to be unable to act on it, is not known, and one that only prints, tests
    or stores it is. Until #3304 every such function was known, because the words this
    repository's gate suite hands its own functions as plain labels (`run_slow python`, `f2854
    curl "<a write>"`), read as commands, refused that suite (measured 2026-11-19); that left
    `run() { "$@"; }; run <a refused command>` allowed. A body the gate cannot find or read
    (`f() ( ... )`, a text whose blocks do not pair up) is not known. Only the words after the
    function are read: a body that builds the command from a part of them (`$1 --test x`) is
    read where it stands, with its arguments unknown, as before.
  * A word after it is the name of a program the gate reads by its name (judged_by_name), or of a
    runner the reader reads past, bare, by a path or in quotes. From that word on, the words are
    judged as the command they would be if the program ran them (Judge.judge, and a string a
    shell among them is handed as a command line of its own), fed what feeds the command they
    are written in, since a program the unknown one runs reads the input that one was given
    (`cat post.py | op run -- python3`). A word that names a file is not such a start: read
    that way, `git add scripts/post.sh` and `sed -n 1,5p scripts/post.sh` would each be a run
    of the script. That leaves `op run -- ./post.sh` open.
  * A word after it written as one quoted string, alone or as an option's value (`hyperfine
    'node --test x.js'`, `tmux send-keys '...'`, `--prepare='...'`; never a quoted string glued
    to more, which is what a line of JSON read as a command holds) and holding white space
    is read as a command line of its own (inner_line) where one of its commands, as the
    shared reader cuts them, starts with such a name past its assignments (holds_command,
    claude-config#3304). Until then the whole word had to name a program, so a command in
    quotes was never read. A sentence that only mentions a program starts with another word
    and is not read, which is what keeps a commit message out: `git commit -m '<exactly a
    refused command>'` is refused, git commit being a program the gate does not know to be
    unable to run its words, and `git commit -m 'refuse <that command> behind a helper'` is
    not. The word must also begin like a command line: its first command starts with a program
    the gate knows (one it reads by name, a runner, or one it knows to be unable to run its
    words), which a sed script, an awk program or a filter does not, though cut at its | marks
    one can hold a piece that starts with a program's name (`sed -i 's|^python3 a|python3 b|'
    file`). Left open by that: a quoted word whose command starts with a second program the gate
    does not know (`hyperfine 'op run -- node x.js'`, `hyperfine 'mytool && node x.js'`), and
    one the reader cannot cut. Behind a
    function, such a word is read only where the body does something with what it is handed
    as the words of a command (function_acts's as_words); a body that only pipes it into a
    program's input is left as it was, and so is `f() { echo "$1" | bash; }`.
  * Where a redirection is glued to one of those words (`node --test test/notify.test.js>out.txt`)
    the words are judged again with a space each side of it, as judge_unglued does for a glued
    name: before claude-config#3252 the shared reader split words on white space alone, so the
    file was a word naming no file. Since #3252 the reader takes a glued redirection off the
    word in the readings it gives, so behind a script that runs its words the older rule now
    refuses the glued form itself; claude-config#3322 then took every redirection out of the
    words the reader hands for a gh or git command, and this reading stays for the words read here.
  * The reader's wrappers (a shell's -c, eval, find -exec, watch, script, parallel) hand their
    command to the walk already, so a command that is one is left to that reading.

WHAT IT COSTS. A program that does not run its words and is not known to be unable to (git add,
sed, docker ps) is refused when the words after it happen to spell a command the gate refuses
(`sed -n /x/p node post.js` reads as node run on post.js). Only the words as a command decide it:
where they are no refused command nothing changes. Of the 43,432 distinct commands sessions ran on
the personal MacBook in the 30 days to 2026-11-19, 403 hold such a word as typed, by a count of
their text alone: after ps (`-o command`), which (`which node`) and top in all but about 70, none
of which spells a refused command. The gate's own verdict on each was not taken: the installed
gate refused the script that asks it (the pull request says what was and was not measured).

The reading of a function's body and of a quoted word (claude-config#3304) was counted with the
gate's own verdict: each of the 62,780 distinct commands in the personal MacBook's session records
on 2026-11-21, judged in process by main's gate and by this one in the folder it ran in. None was
newly refused and none newly allowed (62,318 allowed by both, 462 refused by both). Before a
quoted word had to begin like a command line, four of 62,307 were newly refused: three sed scripts
and one awk program. `git commit -m '<exactly a refused command>'` is refused, and no past command
was one. The work MacBook's records were not counted.

More than MAX_STARTS words that could each start a command, or be a command line of their own,
are not all read: a typed command is
refused as unread there, and a script on disk is left alone, as an unread feed is. The same holds
past MAX_NESTED of these readings inside one another, so that a reading of a reading ends. Only a
string a shell runs adds one (`op run -- bash -c 'op run -- bash -c "op run -- bash -c \\"op run --
node x.js\\""'`): the words one reading judges as a command are not read by the rule again, since
each word of them that could start a command is a start of that first reading's own, however many
programs stand between (`op run -- env A=1 op run -- env A=1 op run -- node x.js` is one reading).
Until the lessons review of 2026-11-19 the cap returned nothing, and the fourth program's words
were allowed unread.
"""
import os
import re

# How many words of one command are each read as the start of a command, and how many of these
# readings may stand inside one another (a string a shell runs that holds a second unknown program).
MAX_STARTS = 6
MAX_NESTED = 3
# A pattern nothing matches: no word of a typed command is "what the script was handed".
NOTHING = re.compile(r"(?!)")
# The words every refusal of this rule says of the program, after its name. The rule's suite tells
# this rule's refusals from another rule's by them alone, so a refusal worded without them is one
# the suite cannot see (claude-config#3304: the nesting limit's wording was one).
NOT_KNOWN = "is not a program the gate knows to be unable to run the words after it"
# White space, which a word that could be a command line of its own holds, and what stands between
# the names in one (white space, quotes and the shell's operators).
WHITE = re.compile(r"\s")
BETWEEN = re.compile(r"[\s;&|(){}<>\"'`]+")
# A word that is one quoted string and nothing else, bare or as the value of an option (--name=).
OPTION = re.compile(r"^--?[\w-]+=")
ONE_QUOTED = re.compile(r"(?s)(?:--?[\w-]+=)?(\$?'[^']*'|\"(?:[^\"\\]|\\.)*\")")
# A redirection that writes the file named after it.
WRITES_TO = re.compile(r"\d*(?:>>|>\||&>>|&>|>)")


def make(judged_by_name, sh_redirect):
    """The Judge's base for the rule. judged_by_name is the gate's own answer to whether it reads a
    program by its name, and sh_redirect its pattern for a redirection's operator."""

    class UnknownProgram:
        behind = 0  # how many of these readings are inside one another
        suffix = None  # the words the reading around this one is judging as a command (judge_as_run)
        starts_memo = {}  # {a word: whether it can start a command the gate reads}, one Judge a process
        funcs_memo = {}  # {a text: the names of the functions it defines}
        bodies_memo = {}  # {(a text, its folder): function_bodies's answer}
        # {(a text, its folder, a function's name, whether only words count): function_acts's answer}
        acts_memo = {}
        lines_memo = {}  # {(a word, the folder, the text being read): holds_command's answer}

        def starts_command(self, word):
            """Whether a word, as the program gets it, names a program the gate reads by its name
            or a runner the reader reads past: the first word of a command the gate can judge."""
            got = self.starts_memo.get(word)
            if got is None:
                name = os.path.basename(word)
                got = self.starts_memo[word] = bool(name) and (judged_by_name(name) or name in self.sw.RUNNERS)
            return got

        def holds_command(self, word, d, depth):
            """Whether one word that holds white space, as the program gets it, is a command line
            one of whose commands starts with a program the gate reads by its name or a runner
            (`hyperfine 'node --test x.js'`, claude-config#3304): the shared reader cuts it into
            commands as it cuts any text, and each one's first word past its assignments is asked
            starts_command. A commit message or a sentence that only mentions such a program
            starts with another word and is not one. A word the reader cannot cut is left as it
            was. Most words hold no white space, and most that do hold no such name anywhere, so
            those are answered before anything is cut.

            The word must also BEGIN like a command line: the first of its commands that has a
            program starts with one the gate knows, which is one it reads by its name, a runner,
            or one it knows to be unable to run its words (may_run_its_words: cd, export, echo).
            Text in another language does not begin so, and cut at its | marks it can hold a
            piece that starts with a program's name: of the 62,307 past commands counted on
            2026-11-21, the four the first build newly refused were three sed scripts
            (`sed -i '27s|^python3 a|python3 b|' file`, an edit of a file) and one awk program.
            Left open by that: a command line in quotes whose first command starts with a
            program the gate does not know (`hyperfine 'mytool && node x.js'`)."""
            if not WHITE.search(word):
                return False
            key = (word, d, self.shell.get("text") or "")  # the text's functions answer for a first word too
            got = self.lines_memo.get(key)
            if got is None:
                got = False
                if any(self.starts_command(t) for t in BETWEEN.split(word) if t):
                    try:
                        records = self.sw.every_command(word, d)
                    except self.sw.Unreadable:
                        records = ()
                    begun = False
                    for record in records:
                        words = self.words_of(self.rest_of(record[1])[0])
                        if not words:
                            continue  # assignments alone (`A=1; node x.js`), which begin nothing
                        starts = self.starts_command(words[0])
                        if not begun:
                            begun = True
                            if not starts and self.may_run_its_words(words, d, depth):
                                break  # it begins with a program the gate does not know
                        if starts:
                            got = True
                            break
                if len(self.lines_memo) > 512:
                    self.lines_memo.clear()
                self.lines_memo[key] = got
            return got

        def may_run_its_words(self, words, d, depth):
            """Whether the program of a command is one the gate does not know to be unable to run
            the words it is handed: sh_command_acts's answer for a command handed something in its
            words, which is how a shell script's own commands are asked. A function the text being
            read defines is asked through its body (function_acts), and the answer is then how
            the body acts, as a phrase, for the refusal to say."""
            text = self.shell.get("text") or ""
            defined = self.funcs_memo.get(text)
            if defined is None:
                if len(self.funcs_memo) > 64:
                    self.funcs_memo.clear()
                defined = self.funcs_memo[text] = frozenset(self.sh_funcs(text))
            if "/" not in words[0] and words[0] in defined:
                why = self.function_acts(words[0], text, d, depth, ())
                if why and not any(self.starts_command(w) for w in words[1:]) and \
                        not self.function_acts(words[0], text, d, depth, (), True):
                    return None  # only a quoted word could be a command, and the body only pipes it on
                return why
            cmd ={"words": words, "docs": None, "fed": False, "takes": True, "expands": False, "block": False,
                   "env": lambda: None}
            return bool(self.sh_command_acts(cmd, NOTHING, defined, d, depth))

        def function_bodies(self, text, d):
            """{a function's name: the text of each body text gives it}, or None where the gate's
            reading of text's blocks (sh_struct) finds no structure: keywords that do not pair up, or
            a body that is not a { } group (`f() ( ... )`)."""
            key = (text, d)
            if key not in self.bodies_memo:
                if len(self.bodies_memo) > 64:
                    self.bodies_memo.clear()
                out = None
                try:
                    cmds, parts = self.parsed(text, d)
                except self.sw.Unreadable:
                    cmds = None
                if cmds is not None:
                    items = list(zip(cmds, parts))
                    struct = self.sh_struct_of(text, d, items)
                    if struct:
                        out = {}
                        for blk in struct[1]:
                            if blk["kind"] == "func" and blk["close"] is not None and blk.get("name"):
                                a, b = items[blk["open"]][1]["start"], items[blk["close"]][1]["end"]
                                out.setdefault(blk["name"], []).append(text[a:b])
                self.bodies_memo[key] = out
            return self.bodies_memo[key]

        @staticmethod
        def handed_names_outputs(words, handed):
            """Whether what a function was handed stands, in the words that close a loop or block
            of its body, only in the name of a file the block writes: `} > "$dir/$1.sh"` feeds the
            block nothing, where `done < "$1"` feeds it the file. Asked only of a function's body
            (shell_acts's around), so a script on disk is read as it was."""
            return all(WRITES_TO.fullmatch(words[k - 1]) for k in range(1, len(words)) if handed.search(words[k]))

        def function_acts(self, name, text, d, depth, seen, as_words=False):
            """How a function text defines acts on the words it is handed, as a phrase, or None where
            the gate reads its body and sees it unable to: the question a script on disk is asked
            (shell_acts), asked of the body, with a function of text the body hands them to asked
            the same (claude-config#3304). A body the gate cannot find or read is not known to be
            unable, as a script it cannot read is not. as_words asks only what the body does with
            them as words of a command (a program's arguments, the code of an eval or a shell's
            -c, the command's own name), which is what decides whether one quoted word is a
            command line the function runs: a body that only pipes what it is handed into a
            program's input hands that program text to read, and this repository's gate suites
            do exactly that with each command they ask the gate about."""
            if name in seen:
                return None  # a function that hands them back to itself runs nothing by that alone
            if len(seen) >= MAX_NESTED:
                return f"hands them through more than {MAX_NESTED} functions, more than the gate reads"
            key = (text, d, name, as_words)
            if not seen and key in self.acts_memo:
                return self.acts_memo[key]
            bodies = self.function_bodies(text, d)
            if bodies is None or not bodies.get(name):
                why = "has a body the gate could not read"
            else:
                names = frozenset(bodies)
                asked = (names, lambda other: self.function_acts(other, text, d, depth, seen + (name,), as_words),
                         as_words)
                why = None
                for body in bodies[name]:
                    why = self.shell_acts(body, d, False, depth + 1, asked)
                    if why:
                        break
            if not seen:
                if len(self.acts_memo) > 256:
                    self.acts_memo.clear()
                self.acts_memo[key] = why
            return why

        def word_value(self, raw):
            """One raw word as the program gets it, quotes removed, or None where it is not one word."""
            try:
                got = self.sw.shell_split(raw)
            except ValueError:
                return None
            return got[0] if len(got) == 1 else None

        def judge_behind_unknown(self, d, text, wrapper, depth, whole, fed_by):
            """The reason a command posts through the words after a program the gate does not
            know, or None (THE RULE above). Asked of every command, so the cheap answers come
            first: most commands hold no word that could start another. fed_by is the command as
            the text being read wrote it, text itself unless text is already such words: a
            program run by the unknown one reads the input that one was given, so what feeds
            the words is looked for under the command they were written in (`run_slow python`,
            a function handed a name in this repository's own suite, is fed nothing, where the
            lone word `python` is written on many of that suite's lines)."""
            if wrapper not in ("", "direct") or text is self.suffix:
                # The words an enclosing reading is judging as a command: each word of them that
                # could start one is a start of that reading's own, so they are read there.
                return None
            rest = self.rest_of(text)[0]
            words = self.words_of(rest)
            if len(words) < 2 or not any(self.starts_command(w) or self.holds_command(OPTION.sub("", w, 1), d, depth)
                                         for w in words[1:]):
                return None
            name = os.path.basename(words[0])
            runs = None if judged_by_name(name) else self.may_run_its_words(words, d, depth)
            if not runs:
                return None
            # A function's refusal says what its body does with the words, which is why they are read.
            unknown = f"{words[0]} is a function that {runs}, so it" if isinstance(runs, str) else words[0]
            joined = self.sw.join_continuations(rest)
            toks = self.sh_tokens(joined)
            places, at, end = [], 0, len(toks)
            for k, (kind, raw) in enumerate(toks):
                if kind == "op" and not sh_redirect.fullmatch(raw):
                    end = k  # one command's words end at an operator that is not a redirection
                    break
                at = joined.find(raw, at)  # only white space stands between one word and the next
                places.append(at)
                at += len(raw)
            starts = [k for k in range(1, end) if toks[k][0] == "word" and toks[k - 1][0] == "word"
                      and self.starts_command(self.word_value(toks[k][1]) or "")]
            # Only a word written as one quoted string, alone or as an option's value: a quoted
            # string glued to more (`"curl ..."}}`, a line of JSON read as a command) is no word
            # a program is handed as its command, and read as one a transcript sourced by a
            # script was refused as posting for a command it only quotes.
            lines = [v for k in range(1, end) if toks[k][0] == "word" and toks[k - 1][0] == "word"
                     for m in (ONE_QUOTED.fullmatch(toks[k][1]),) if m
                     for v in (self.word_value(m.group(1)),) if v and self.holds_command(v, d, depth)]
            if lines and isinstance(runs, str) and not self.function_acts(
                    words[0], self.shell.get("text") or "", d, depth, (), True):
                lines = []  # a function whose body only pipes what it is handed on (function_acts)
            if not starts and not lines:
                return None
            # Every refusal of this rule opens with these words (NOT_KNOWN), so one test of a
            # refusal's text says whether this rule gave it (claude-config#3304).
            unknown += " " + NOT_KNOWN
            if self.behind >= MAX_NESTED:
                # Asked only here, once there are words to read: an unread cap that says nothing
                # allows what stands past it (the lessons review of this branch, 2026-11-19).
                return self.unread_typed(
                    f"{unknown}, and they could start a command {MAX_NESTED} such readings inside one another, "
                    "more than the gate reads, so whether the command posts cannot be checked")
            if len(starts) + len(lines) > MAX_STARTS:
                return self.unread_typed(
                    f"{unknown}, and {len(starts) + len(lines)} of them could each start a command, more than "
                    f"the {MAX_STARTS} the gate reads, so whether the command posts cannot be checked")
            last = places[end - 1] + len(toks[end - 1][1]) if end else 0
            noted = len(self.unfollowed)
            self.behind += 1
            try:
                for k in starts:
                    written = joined[places[k]:last]
                    spaced = " ".join(raw for _, raw in toks[k:end])
                    for new in (written, spaced) if spaced.split() != written.split() else (written,):
                        inner = self.judge_as_run(d, new, depth, whole, fed_by)
                        if not inner:
                            continue
                        if self.sh_in_script() and any(u in inner for u in self.unfollowed[noted:]):
                            # In a script on disk only a finding that something posts stands, as for
                            # the unread shapes (judge_unread_shapes): these words are read without
                            # the script's own reading of its variables around them.
                            del self.unfollowed[noted:]
                            continue
                        return f"{unknown}, so they are read as a command it runs: {inner}"
                for line in lines:
                    inner = self.inner_line(line, d, depth)
                    if not inner:
                        continue
                    if self.sh_in_script() and any(u in inner for u in self.unfollowed[noted:]):
                        del self.unfollowed[noted:]  # as above: only a finding that something posts stands
                        continue
                    return (f"{unknown}, and one of them is a command line of its own, read as one it "
                            f"runs: {inner}")
            finally:
                self.behind -= 1
            return None

        def judge_as_run(self, d, new, depth, whole, fed_by):
            """The reason the command new posts, or None: judged as any command is (Judge.judge),
            fed what feeds the command it was written in, and a string a shell in it is handed
            read as a command line, since the reader gave that string's commands to nobody (as
            rejudge reads one)."""
            wrapper, string, why = self.sw.wrapped(self.rest_of(new)[0]) or ("", None, "")
            if string is not None and not why:
                inner = self.inner_line(string, d, depth)
                if inner:
                    return f"{wrapper} runs a string, one of whose commands posts: {inner}"
            was, self.suffix = self.suffix, new
            try:
                return self.judge(d, new, wrapper, why, depth, whole, fed_by)
            finally:
                self.suffix = was

    return UnknownProgram
